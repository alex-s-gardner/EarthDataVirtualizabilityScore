"""
Stage 6: record the file-side cause of every granule stage 3 could not open.

A refusal recorded in `results/probe/` names where a reader stopped. That is enough to grade the
collection and not enough to say whether the obstruction is in the archive or in the reader: a
`KeyError` inside an HDF4 backend reads the same either way. This stage re-reads only the granules
recorded as failures and describes what the file holds at the point of refusal — a fill value's
actual type, how many dimension scales an axis carries, whether a data block's offset and length are
already in the file's descriptor table, whether a zip member is stored or deflated.

Reads `results/probe/*.json`, writes `results/diagnose/<short_name>.json`. Reads the granule over
the same authenticated HTTPS path stage 3 uses.

Command-line arguments restrict the run to the named collections.
"""

from __future__ import annotations

import importlib
import json
import sys
import tempfile
import traceback
import warnings
import zipfile
from pathlib import Path

warnings.filterwarnings("ignore")

import earthaccess
import h5py
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
# Stage 3 owns the format sniffer, the authenticated store, and the streaming download. Importing it
# keeps one definition of the access path, so a diagnosis reads the byte stream the probe read.
probe = importlib.import_module("03_probe")

RESULTS = Path(__file__).resolve().parent.parent / "results"
PROBE_DIR = RESULTS / "probe"
OUT_DIR = RESULTS / "diagnose"

# Largest granule copied to disk for diagnosis. A file above this is left undiagnosed rather than
# spending the bandwidth, since the refusals seen here do not depend on granule size.
SIZE_CAP = 2 * 1024**3

# Failures that are properties of the measurement rather than of the file, matched on the message
# stage 3 recorded. Diagnosing one would describe a granule that was never refused: the first three
# are the probe's own ceilings, and the last two are the access path refusing to serve the object at
# all, which no reading of the file explains.
PROBE_LIMITS = ("probe budget", "copy-to-disk limit", "not attempted",
                "Range request not supported", "lacked the necessary privileges")


def is_refusal(p: dict) -> bool:
    """
    Whether a probe record is a granule no chunk manifest came out of, as opposed to one the probe
    never finished.

    A parser that returns a store holding no arrays counts: it reported success and produced nothing
    to build a manifest from, which is the case where the file's own structure is what needs stating.
    """
    if not p.get("attempted", True):
        return False
    if p.get("ok"):
        return not p.get("vars")
    return not any(s in str(p.get("error", "")) for s in PROBE_LIMITS)


def representatives(probes: list[dict]) -> list[dict]:
    """
    One refused granule per distinct error, which is the unit a diagnosis is about.

    Granules of one collection written by one producer fail the same way, so a second granule with
    the same exception and message adds a repeat rather than a cause. A collection failing two
    different ways yields two representatives.
    """
    seen: dict[tuple, dict] = {}
    for p in probes:
        if not is_refusal(p):
            continue
        key = (p.get("error_type") or "no arrays returned", str(p.get("error"))[:200])
        if key in seen:
            seen[key]["n_like_this"] += 1
        else:
            seen[key] = {**p, "n_like_this": 1}
    return list(seen.values())


def hdf5_findings(path: Path) -> dict:
    """
    What an HDF5 or HDF-EOS5 file holds that a Zarr chunk manifest cannot describe.

    Each check is run over the whole file rather than aimed at the recorded exception, so a second
    obstruction behind the first one is recorded too.
    """
    out = {
        "unencodable_fill_values": [], "multi_scale_axes": [], "unfixed_dtypes": [],
        "filters": {}, "n_datasets": 0, "n_groups": 0,
    }
    with h5py.File(path, "r") as f:
        def visit(name, obj):
            if isinstance(obj, h5py.Group):
                out["n_groups"] += 1
                return
            out["n_datasets"] += 1

            # A Zarr fill value is one value of the array's own dtype, so a string and an array both
            # fail to encode, and which of the two it is decides what a producer would change.
            fill = obj.attrs.get("_FillValue")
            if fill is not None:
                arr = np.asarray(fill)
                reason = ("a string on a numeric dtype" if arr.dtype.kind in ("S", "U", "O")
                          else f"{arr.size} values rather than one" if arr.size != 1 else None)
                if reason is not None:
                    out["unencodable_fill_values"].append({
                        "dataset": name, "dtype": str(obj.dtype), "reason": reason,
                        "fill_value": str(arr.ravel()[:4])[:80],
                    })

            # A Zarr array names each axis once, so an axis carrying two dimension scales has no
            # single name to take.
            dl = obj.attrs.get("DIMENSION_LIST")
            if dl is not None:
                for axis, refs in enumerate(dl):
                    n = len(refs) if hasattr(refs, "__len__") else 1
                    if n > 1:
                        names = []
                        for r in refs[:8]:
                            try:
                                names.append(f[r].name)
                            except Exception as e:
                                names.append(f"<unresolved: {type(e).__name__}>")
                        out["multi_scale_axes"].append({
                            "dataset": name, "axis": axis, "n_scales": n, "scales": names,
                        })

            if obj.dtype.kind == "O" or obj.dtype.fields is not None:
                out["unfixed_dtypes"].append({"dataset": name, "dtype": str(obj.dtype)})

            for fid in (getattr(obj, "_filters", None) or {}):
                out["filters"][str(fid)] = out["filters"].get(str(fid), 0) + 1

        f.visititems(visit)
    return out


def hdf4_findings(path: Path) -> dict:
    """
    Whether an HDF4 file's data blocks are already addressable, stated from its descriptor table.

    Every HDF4 data descriptor carries the offset and length of its block. A scientific-data tag that
    is not marked extended therefore names a contiguous block whose position the file states outright,
    and a chunk manifest needs nothing further; an extended tag defers to a chunk table, a linked
    block list, or a compression header, and its type is what says which. Recording that census
    separates a file holding no addressable block from a backend that stopped before reading one.

    `sd_decoder_registered` is the other half of that separation. The backend derives a data reference
    for an extended element only, so where it is false, every contiguous element in the census above
    is one the reader has no path to, whatever the file states. A sample of those elements is recorded
    with the offset and length the file gives them.
    """
    from kerchunk.hdf4 import HDF4ToZarr, comp, decoders, spec

    h = HDF4ToZarr(str(path))
    h.f = open(path, "rb")
    try:
        magic = h.f.read(4)
        if magic != b"\x0e\x03\x13\x01":
            return {"error": f"not an HDF4 file: first bytes {magic!r}"}
        h.tags = {}
        while True:
            ddh = h.read_ddh()
            for _ in range(ddh["ndd"]):
                ident, info = h.read_dd()
                h.tags[ident] = info
            if ddh["next"] == 0:
                break
            h.f.seek(ddh["next"])

        census: dict[str, int] = {}
        for tag, _ in h.tags:
            census[str(tag)] = census.get(str(tag), 0) + 1

        sd = {"total": 0, "contiguous": 0, "extended": 0, "extension_types": {}, "decode_errors": {},
              "sd_decoder_registered": "SD" in decoders, "contiguous_sample": [],
              "compressed_elements": {"codecs": {}},
              "chunked_elements": {"decoded": 0, "failed": {}, "total_chunks": 0, "codecs": {},
                                   "chunk_sample": []}}
        for (tag, ref), info in h.tags.items():
            if tag != "SD":
                continue
            sd["total"] += 1
            if not info["extended"]:
                sd["contiguous"] += 1
                if len(sd["contiguous_sample"]) < 4:
                    sd["contiguous_sample"].append({"ref": ref, "offset": info["offset"],
                                                    "length": info["length"]})
                continue
            sd["extended"] += 1
            try:
                h.f.seek(info["offset"])
                kind = spec[h.read_int(2)]
            except Exception as e:  # the extension header itself is what could not be read
                sd["decode_errors"][type(e).__name__] = sd["decode_errors"].get(
                    type(e).__name__, 0) + 1
                continue
            sd["extension_types"][kind] = sd["extension_types"].get(kind, 0) + 1

            if kind == "COMP":
                # The compression scheme sits two fields past the data reference. A scheme Zarr has
                # no codec for is a property of the file: the element is one stream nothing can
                # decode a chunk out of.
                try:
                    h.f.seek(info["offset"] + 12)
                    scheme = comp.get(h.read_int(2), "unrecognized")
                except Exception:
                    scheme = "unreadable"
                cs = sd["compressed_elements"]["codecs"]
                cs[scheme] = cs.get(scheme, 0) + 1
            elif kind == "CHUNKED":
                # A chunk table holds one row per chunk, each naming a block. Decoding it is the
                # direct test of whether the file already carries per-chunk byte ranges.
                ce = sd["chunked_elements"]
                try:
                    rows = [r for r in (h._dec("SD", ref).get("data") or [])
                            if isinstance(r, list) and len(r) >= 3]
                    ce["decoded"] += 1
                    ce["total_chunks"] += len(rows)
                    for r in rows:
                        codec = r[3] if len(r) > 3 else "NONE"
                        ce["codecs"][codec] = ce["codecs"].get(codec, 0) + 1
                    if rows and len(ce["chunk_sample"]) < 3:
                        ce["chunk_sample"].append(
                            {"index": rows[0][0], "offset": rows[0][1], "length": rows[0][2]})
                except Exception as e:
                    ce["failed"][type(e).__name__] = ce["failed"].get(type(e).__name__, 0) + 1
        return {"tag_census": census, "scientific_data_tags": sd,
                "refusal_site": hdf4_refusal_site(path)}
    finally:
        h.f.close()


def hdf4_refusal_site(path: Path) -> dict:
    """
    Which descriptor the HDF4 backend was indexing when it raised, read from the raised frame.

    The census above says what the file holds; this says what the reader was looking at when it
    stopped, so the two can be compared instead of one standing in for the other. `extended` is the
    file's own mark on that descriptor: an extended element defers its blocks to a chunk table or
    compression header, while a contiguous one carries its offset and length in the descriptor itself.
    """
    from kerchunk.hdf4 import HDF4ToZarr

    h = HDF4ToZarr(str(path))
    try:
        h.translate()
        return {"raised": False}
    except Exception as e:
        site = {"raised": True, "error_type": type(e).__name__, "error": str(e)[:200]}
        tb = e.__traceback__
        while tb:
            frame = tb.tb_frame
            if frame.f_code.co_name == "_descend_vg":
                t, r = frame.f_locals.get("t"), frame.f_locals.get("r")
                if t is not None:
                    info = h.tags.get((t, r), {})
                    site["indexing"] = {
                        "tag": str(t), "ref": r, "extended": info.get("extended"),
                        "offset": info.get("offset"), "length": info.get("length"),
                        "keys_present": sorted(str(k) for k in info),
                    }
            tb = tb.tb_next
        return site


def zip_findings(path: Path) -> dict:
    """
    Whether a zipped granule's members are stored or deflated.

    A stored member is a byte range of the archive, which a chunk manifest can point at; a deflated
    member is one stream with no boundary inside it, so no range request lands on a chunk.
    """
    with zipfile.ZipFile(path) as z:
        members = [{
            "name": i.filename, "compress_type": i.compress_type,
            "stored": i.compress_type == zipfile.ZIP_STORED,
            "compress_size": i.compress_size, "file_size": i.file_size,
            "header_offset": i.header_offset,
        } for i in z.infolist()[:32]]
    return {"members": members, "all_stored": all(m["stored"] for m in members)}


def text_findings(path: Path) -> dict:
    """
    The record structure of a text granule: the first lines and whether their lengths are fixed.

    A fixed-width text record is still not addressable as a chunk — a Zarr chunk is a byte range of
    encoded array data — so this records what the file is rather than a path to virtualizing it.
    """
    lines = []
    with path.open("rb") as fh:
        for _ in range(12):
            line = fh.readline()
            if not line:
                break
            lines.append(line.rstrip(b"\r\n"))
    widths = sorted({len(line) for line in lines})
    return {"first_lines": [line[:100].decode("utf-8", "replace") for line in lines[:4]],
            "line_widths": widths, "fixed_width": len(widths) == 1}


def diagnose_granule(gran: dict, token: str) -> dict:
    """
    File-side findings for one refused granule, dispatched on what the first bytes say it is.
    """
    url = gran["url"]
    out = {"url": url, "error_type": gran.get("error_type"), "error": gran.get("error"),
           "n_like_this": gran.get("n_like_this", 1)}
    root, path, store = probe._store(url, token)
    kind = probe.sniff(store, path)
    if kind == "unknown":
        kind = "zip" if url.endswith(".zip") else "text"
    out["container"] = kind

    size = gran.get("file_bytes")
    if size and size > SIZE_CAP:
        out["skipped"] = f"granule is {size / 1e6:.0f} MB; above the {SIZE_CAP / 1e6:.0f} MB " \
                         "copy-to-disk limit for diagnosis"
        return out

    with tempfile.TemporaryDirectory() as tmp:
        local = Path(tmp) / Path(path).name
        probe.fetch_to_disk(store, path, local)
        out["local_bytes"] = local.stat().st_size
        table = {"hdf5": hdf5_findings, "hdf4": hdf4_findings,
                 "zip": zip_findings, "text": text_findings}
        fn = table.get(kind)
        if fn is None:
            out["skipped"] = f"no diagnosis defined for container {kind}"
            return out
        try:
            out["findings"] = fn(local)
        except Exception as e:
            out["findings_error"] = f"{type(e).__name__}: {e}"
            out["findings_traceback"] = probe.relative_paths(traceback.format_exc())[-1200:]
    return out


def main() -> int:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    only = sys.argv[1:]

    artifacts = sorted(p for p in PROBE_DIR.glob("*.json"))
    if not artifacts:
        raise SystemExit(f"no probe artifacts in {PROBE_DIR}; run scripts/03_probe.py first")
    unknown = sorted(set(only) - {p.stem for p in artifacts})
    if unknown:
        raise SystemExit(f"no probe artifact for: {unknown}")

    earthaccess.login(strategy="netrc")
    token = earthaccess.__auth__.token["access_token"]

    todo = []
    for p in artifacts:
        if only and p.stem not in only:
            continue
        rec = json.loads(p.read_text())
        reps = representatives(rec["probes"])
        reps and todo.append((p.stem, rec, reps))

    print(f"{len(todo)} collections with a refused granule", flush=True)
    for i, (short_name, rec, reps) in enumerate(todo, 1):
        print(f"[{i}/{len(todo)}] {short_name} ({rec.get('format')}): {len(reps)} distinct error"
              f"{'' if len(reps) == 1 else 's'}", flush=True)
        results = []
        for gran in reps:
            # One granule that cannot be reached must not cost the other seventeen collections their
            # diagnosis, so the failure is recorded against that granule and the run continues.
            try:
                d = diagnose_granule(gran, token)
            except Exception as e:
                d = {"url": gran.get("url"), "error_type": gran.get("error_type"),
                     "error": gran.get("error"), "container": "unread",
                     "diagnosis_error": f"{type(e).__name__}: {e}"[:300]}
            results.append(d)
            head = (d.get("diagnosis_error") or d.get("skipped")
                    or d.get("findings_error") or "diagnosed")
            print(f"      {d['container']}: {head}", flush=True)
        (OUT_DIR / f"{short_name}.json").write_text(json.dumps(
            {"short_name": short_name, "format": rec.get("format"), "diagnoses": results}, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
