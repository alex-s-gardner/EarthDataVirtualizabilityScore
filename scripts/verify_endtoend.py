"""
Verification of the ranking by building real virtual stores, not by re-reading catalog metadata.

Five independent checks, written to `results/verification.md`:

1. Positive control — combine several granules of a top-graded collection into one virtual dataset,
   read a slice of it that spans two source granules, and compare the values against the same slices
   read directly from those granules with `h5py`. Equal values prove the chunk manifest's byte
   offsets and its file assignment are both right, which is what makes a grade mean anything.
2. Icechunk round-trip — persist the virtual references, reopen them, and read values back out,
   which is the form a durable virtual datacube would actually take.
3. Hand-checked chunk — fetch exactly one `(url, offset, length)` triple, reverse the declared codec
   chain, and confirm the result is the size the declared chunk shape implies.
4. Negative control — attempt the same combination on a collection graded D, along the axis whose
   length varies, and confirm it fails for the criterion the table names.
5. Catalog cross-check — compare the stage 1 granule counts against `earthaccess`.

A combined virtual dataset holds `ManifestArray`s, which carry layout but serve no values, so reading
one back requires writing it out first. Both routes out are exercised: kerchunk references read
through an authenticated `ReferenceFileSystem`, and an Icechunk repository whose virtual chunk
container carries the bearer token on its store configuration.
"""

from __future__ import annotations

import csv
import itertools
import json
import math
import sys
import traceback
import warnings
import zlib
from pathlib import Path
from urllib.parse import urlsplit

warnings.filterwarnings("ignore")

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import vz_shims

RESULTS = Path(__file__).resolve().parent.parent / "results"

#: Granules combined by the positive and negative controls.
N_GRANULES = 4


def store_for(url: str, token: str):
    """
    Root URL, object path, and an authenticated `HTTPStore` for one granule URL.
    """
    from obstore.store import HTTPStore

    sp = urlsplit(url)
    root = f"{sp.scheme}://{sp.netloc}"
    opts = {"default_headers": {"Authorization": f"Bearer {token}"}}
    return root, sp.path.lstrip("/"), HTTPStore(root, client_options=opts)


def fsspec_opts(token: str) -> dict:
    """
    `aiohttp` session arguments that let fsspec reach NASA's authenticated HTTPS endpoints.

    `trust_env` must be off: fsspec otherwise reads `~/.netrc` and sends basic auth alongside the
    bearer token, which Earthdata Login rejects.
    """
    return {"headers": {"Authorization": f"Bearer {token}"}, "trust_env": False}


def split_group(name: str) -> tuple[str | None, str]:
    """
    The group holding an array and the array's own name.

    A parser opens one group at a time, so a variable inside a hierarchy has to be reached by naming
    its group; hierarchical products otherwise present an empty root.
    """
    if "/" not in name:
        return None, name
    group, leaf = name.rsplit("/", 1)
    return group, leaf


def load(short_name: str) -> dict:
    return json.loads((RESULTS / "probe" / f"{short_name}.json").read_text())


def opened(rec) -> list[dict]:
    return [p for p in rec["probes"] if p.get("ok")]


# Phrases each criterion predicts in a refusal. A criterion is only confirmed when the tool's own
# message names the same obstruction the score attributed the grade to; anything else is a refusal for
# an unrelated reason and is reported as unconfirmed rather than counted as a pass.
EXPECTED_REFUSAL = {
    "H3": ("not evenly divisible", "partial chunk"),
    "H2": ("inconsistent chunk shapes",),
    "G": ("do not line up", "conflicting sizes", "cannot align"),
}


def criterion_of(blocker: str) -> str:
    """
    The criterion ID a deciding-criterion string names, or `""` when it names none.
    """
    return blocker.split(":", 1)[0].strip() if ":" in blocker else ""


def pick(rows, grades, container="hdf5", criterion=None):
    """
    The first scored collection whose grade is in `grades` and whose probed granules are `container`.

    `criterion` additionally requires the row's deciding criterion to be the one named, so a check can
    target the specific obstruction it knows how to exercise.
    """
    for r in rows:
        if r["grade"] not in grades:
            continue
        if criterion is not None and criterion_of(r["blocker"]) != criterion:
            continue
        if not (RESULTS / "probe" / f"{r['short_name']}.json").exists():
            continue
        rec = load(r["short_name"])
        good = opened(rec)
        if len(good) >= 2 and container in {p.get("container") for p in good}:
            return r, rec
    return None


def largest_var(rec, min_ndim=1):
    """
    Name and record of the largest non-overview array of at least `min_ndim` dimensions.
    """
    best = None
    for p in opened(rec):
        for v in p["vars"]:
            sh = v.get("shape") or []
            if len(sh) < min_ndim or v.get("overview") or not v.get("chunks"):
                continue
            n = int(np.prod(sh))
            if best is None or n > best[0]:
                best = (n, v["name"], v)
    return (best[1], best[2]) if best else (None, None)


def var_in(probe, name):
    for v in probe["vars"]:
        if v["name"] == name:
            return v
    return None


def consistent_urls(rec, name, n):
    """
    URLs of up to `n` granules that agree on the chunk shape of `name`.

    A collection that rechunked mid-record still has eras that are internally consistent, and a
    combination is only meaningful within one of them.
    """
    groups: dict[tuple, list[str]] = {}
    for p in opened(rec):
        v = var_in(p, name)
        if v:
            groups.setdefault(tuple(v["chunks"] or ()), []).append(p["url"])
    if not groups:
        return []
    return max(groups.values(), key=len)[:n]


def varying_axis(rec, name):
    """
    Index of the dimension of `name` whose length differs across granules, or `None`.
    """
    shapes = [tuple(v["shape"]) for p in opened(rec) if (v := var_in(p, name))]
    if len(shapes) < 2 or len({len(s) for s in shapes}) != 1:
        return None
    for d in range(len(shapes[0])):
        if len({s[d] for s in shapes}) > 1:
            return d
    return None


def interior_block(shape, size=4):
    """
    A small slice near the middle of `shape`, avoiding the edge chunks that every product trims.
    """
    out = []
    for n in shape:
        if n <= 1:
            out.append(slice(0, 1))
        else:
            start = max(n // 2 - size // 2, 0)
            out.append(slice(start, min(start + size, n)))
    return tuple(out)


def reference_group(refs, token):
    """
    A readable Zarr group over a kerchunk reference set, authenticated to NASA.
    """
    import zarr
    from fsspec.implementations.asyn_wrapper import AsyncFileSystemWrapper
    from fsspec.implementations.reference import ReferenceFileSystem

    fs = ReferenceFileSystem(fo=refs, remote_protocol="https",
                             remote_options={"client_kwargs": fsspec_opts(token)})
    store = zarr.storage.FsspecStore(AsyncFileSystemWrapper(fs), path="/")
    return zarr.open_group(store=store, mode="r", zarr_format=2)


def h5_read(url, var, sl, token):
    """
    One slice of one variable, read straight from the archival granule.
    """
    import fsspec
    import h5py

    fs = fsspec.filesystem("https", client_kwargs=fsspec_opts(token))
    with fs.open(url, "rb") as fh, h5py.File(fh, "r") as h5:
        return h5[var][sl]


def check_positive(row, rec, token, out):
    """
    Combine granules, read the combination, and compare it against the source granules.
    """
    from virtualizarr import open_virtual_mfdataset
    from virtualizarr.parsers import HDFParser
    from virtualizarr.registry import ObjectStoreRegistry

    var, vrec = largest_var(rec, min_ndim=2)
    group, leaf = split_group(var)
    urls = consistent_urls(rec, var, N_GRANULES)
    out.append(f"Variable `{var}`: shape {vrec['shape']}, chunks {vrec['chunks']}, "
               f"codecs {vrec['codecs']}.\n")
    out.append(f"Combining {len(urls)} granules"
               + (f", group `{group}`" if group else "") + ":\n")
    for u in urls:
        out.append(f"- `{u.rsplit('/', 1)[-1]}`")
    out.append("")

    root, _, st = store_for(urls[0], token)
    reg = ObjectStoreRegistry({root: st})
    concat_dim = "time" if group is None else (vrec.get("dims") or ["time"])[0]
    vds = open_virtual_mfdataset(
        urls, registry=reg, parser=HDFParser(group=group), combine="nested",
        concat_dim=concat_dim, coords="minimal", data_vars="minimal", compat="override")
    out.append(f"Combined virtual dataset on `{concat_dim}`: dims {dict(vds.sizes)}, "
               f"{vds.vz.nrefs()} chunk references, {vds.vz.nbytes} bytes of manifest.\n")

    refs = vds.vz.to_kerchunk(format="dict")
    g = reference_group(refs, token)
    arr = g[leaf]
    out.append(f"Read back through the manifest as `{leaf}`: shape {arr.shape}, "
               f"chunks {arr.chunks}.\n")

    # Compare a block from the first and last granule's slabs, so the check covers file assignment
    # and not only byte offsets within one file.
    per = arr.shape[0] // len(urls)
    rows = []
    for i, u in enumerate((urls[0], urls[-1])):
        t = 0 if i == 0 else arr.shape[0] - 1
        sl = interior_block(arr.shape[1:])
        via_manifest = np.asarray(arr[(t,) + sl])
        via_h5py = np.asarray(h5_read(u, var, (0,) + sl, token))
        same = np.array_equal(via_manifest, via_h5py)
        rows.append(same)
        out.append(f"Index `[{t}]` ↦ `{u.rsplit('/', 1)[-1]}`, slice {sl}: "
                   f"**{'identical' if same else 'MISMATCH'}**")
        out.append("```")
        out.append(f"via manifest : {via_manifest.ravel()[:6]}")
        out.append(f"via h5py     : {via_h5py.ravel()[:6]}")
        out.append("```")
    out.append("")
    out.append(f"**Positive control {'passes' if all(rows) else 'FAILS'}** — "
               f"{'the combined cube serves the archival bytes unchanged.' if all(rows) else 'see above.'}\n")
    return vds, var, urls, all(rows)


def check_icechunk(vds, var, urls, token, out):
    """
    Persist the virtual references to Icechunk, reopen them, and read values back.

    The bearer token goes on the virtual chunk container's store configuration rather than into
    `authorize_virtual_chunk_access`, whose `Credentials.HttpAccess` takes no arguments.
    """
    import shutil

    import icechunk as ic
    import xarray as xr

    repo_dir = RESULTS / "verify_repo"
    if repo_dir.exists():
        shutil.rmtree(repo_dir)

    prefix = urls[0][: urls[0].index("/", 8) + 1]
    cfg = ic.RepositoryConfig.default()
    cfg.set_virtual_chunk_container(ic.VirtualChunkContainer(
        prefix, ic.http_store(headers={"Authorization": f"Bearer {token}"})))
    repo = ic.Repository.create(
        ic.local_filesystem_storage(str(repo_dir)), config=cfg,
        authorize_virtual_chunk_access={prefix: ic.credentials.Credentials.HttpAccess()})

    session = repo.writable_session("main")
    vds.vz.to_icechunk(session.store)
    snap = session.commit("virtual references to NASA granules")
    out.append(f"Virtual chunk container `{prefix}` carrying the Earthdata Login token; "
               f"committed snapshot `{snap}`.")

    reopened = xr.open_zarr(repo.readonly_session("main").store, consolidated=False,
                            zarr_format=3, mask_and_scale=False)
    leaf = split_group(var)[1]
    out.append(f"Reopened: dims {dict(reopened.sizes)}, "
               f"{len(reopened.data_vars)} data variables.\n")

    sl = interior_block(reopened[leaf].shape[1:])
    via_repo = np.asarray(reopened[leaf][(0,) + sl])
    via_h5py = np.asarray(h5_read(urls[0], var, (0,) + sl, token))
    same = np.array_equal(via_repo, via_h5py)
    out.append(f"Slice {sl} of index `[0]` read out of the repository: "
               f"**{'identical to the source granule' if same else 'MISMATCH'}**")
    out.append("```")
    out.append(f"via icechunk : {via_repo.ravel()[:6]}")
    out.append(f"via h5py     : {via_h5py.ravel()[:6]}")
    out.append("```\n")
    out.append("So an Icechunk repository can serve a NASA archive it does not hold: the chunk "
               "manifest and metadata are the only bytes stored locally, and each read resolves to "
               "a range request against the original granule. The token belongs on the container's "
               "store configuration — `Credentials.HttpAccess` takes no arguments and cannot carry "
               "one.\n")
    return same


def check_hand_chunk(rec, token, out):
    """
    Fetch one chunk by its manifest triple and reverse its codec chain.
    """
    import numcodecs
    import obstore
    from virtualizarr.parsers import HDFParser
    from virtualizarr.registry import ObjectStoreRegistry

    url = opened(rec)[0]["url"]
    root, _, st = store_for(url, token)
    ms = HDFParser()(url, ObjectStoreRegistry({root: st}))

    def walk(group, prefix=""):
        for n, a in group.arrays.items():
            yield prefix + n, a
        for n, s in group.groups.items():
            yield from walk(s, prefix + n + "/")

    arrays = dict(walk(ms._group))
    name = max(arrays, key=lambda n: int(np.prod(arrays[n].metadata.shape or (0,))))
    md = arrays[name].metadata
    entry = next(iter(arrays[name].manifest.dict().values()))
    chunk_shape = tuple(md.chunk_grid.chunk_shape)
    dtype = md.data_type.to_native_dtype()
    codecs = [type(c).__name__ for c in md.codecs]

    _, epath, est = store_for(entry["path"], token)
    raw = bytes(obstore.get_range(est, epath, start=entry["offset"], length=entry["length"]))

    buf = raw
    for codec in reversed(md.codecs):
        kind = type(codec).__name__
        if kind == "Zlib":
            buf = zlib.decompress(buf)
        elif kind == "Shuffle":
            buf = numcodecs.Shuffle(elementsize=dtype.itemsize).decode(buf)

    expect = int(np.prod(chunk_shape)) * dtype.itemsize
    ok = len(buf) == expect
    out.append(f"`{name}`, chunk `{next(iter(arrays[name].manifest.dict()))}`: "
               f"offset {entry['offset']}, length {entry['length']}.")
    out.append(f"Declared chunk shape {chunk_shape}, dtype `{dtype}`, codecs {codecs}.\n")
    out.append(f"Fetched {len(raw)} bytes; decoded to {len(buf)}; the declared chunk shape implies "
               f"{expect}. **{'match' if ok else 'MISMATCH'}**\n")
    if ok:
        out.append("```")
        out.append(f"first values: {np.frombuffer(buf, dtype=dtype)[:6]}")
        out.append("```\n")
    if md.shape and chunk_shape and any(c > s for c, s in zip(chunk_shape, md.shape)):
        out.append(f"The chunk is larger than the array it belongs to ({chunk_shape} against "
                   f"{tuple(md.shape)}), so the stored chunk is padded and only part of it holds "
                   "data. Two such granules cannot be concatenated along that axis under a regular "
                   "chunk grid.\n")
    return ok


def check_negative(rows, token, out, criterion=None):
    """
    Confirm a collection graded D fails combination for the reason the table gives.

    The refusal has to name the same obstruction the row does. A collection that refuses for an
    unrelated reason is recorded as unconfirmed: the grade would then be right about the outcome by
    accident, which is not evidence that the criterion measures what it claims.
    """
    from virtualizarr import open_virtual_mfdataset
    from virtualizarr.parsers import HDFParser
    from virtualizarr.registry import ObjectStoreRegistry

    got = pick(rows, {"D"}, criterion=criterion)
    if got is None:
        out.append(f"No collection graded D on {criterion or 'any criterion'} has readable HDF5 "
                   "granules; skipped.\n")
        return None
    row, rec = got
    var, vrec = largest_var(rec, min_ndim=1)
    group, leaf = split_group(var)
    axis = varying_axis(rec, var)
    urls = [p["url"] for p in opened(rec)][:N_GRANULES]

    out.append(f"`{row['short_name']}` is graded {row['grade']}.\n")
    out.append(f"> {row['blocker']}\n")
    if axis is None:
        out.append(f"No dimension of `{var}` varies across the sampled granules, so the table's "
                   "axis cannot be exercised here; recording that rather than inventing one.\n")
        return None
    dims = vrec.get("dims") or []
    dim = dims[axis] if axis < len(dims) else f"dim_{axis}"
    shapes = sorted({tuple(v["shape"]) for p in opened(rec) if (v := var_in(p, var))})
    out.append(f"`{var}` has chunks {vrec['chunks']} and shapes {shapes} — dimension {axis} "
               f"(`{dim}`) varies. Combining along it should fail.\n")
    if group:
        out.append(f"Opening group `{group}`, since a parser presents one group at a time and this "
                   "product's arrays are nested.\n")

    root, _, st = store_for(urls[0], token)
    reg = ObjectStoreRegistry({root: st})
    try:
        vds = open_virtual_mfdataset(
            urls, registry=reg, parser=HDFParser(group=group), combine="nested", concat_dim=dim,
            coords="minimal", data_vars="minimal", compat="override")
        out.append(f"Combination succeeded: dims {dict(vds.sizes)}. Writing the manifest out is the "
                   "next place the misalignment can surface, so that is attempted too.\n")
        try:
            refs = vds.vz.to_kerchunk(format="dict")
            out.append(f"Writing the manifest also succeeded ({len(refs.get('refs', refs))} "
                       "references). The grade claims this collection cannot be concatenated on "
                       "this axis, and nothing here refused it — recorded as a disagreement to "
                       "resolve, not a pass.\n")
            return False
        except Exception as exc:  # noqa: BLE001 - the failure is the expected result
            return _report_refusal(out, row, exc, "Writing the manifest failed")
    except Exception as exc:  # noqa: BLE001 - the failure is the expected result
        return _report_refusal(out, row, exc, "Combination failed")


def _report_refusal(out, row, exc, what: str) -> bool:
    """
    Record a refusal and whether its wording names the criterion the row was graded on.
    """
    crit = criterion_of(row["blocker"])
    msg = str(exc)
    out.append(f"{what}:\n")
    out.append("```")
    out.append(f"{type(exc).__name__}: {msg[:600]}")
    out.append("```\n")
    phrases = EXPECTED_REFUSAL.get(crit)
    if phrases is None:
        out.append(f"No refusal wording is predicted for criterion {crit or '(none)'}, so this "
                   "confirms only that the collection cannot be combined.\n")
        return None
    hit = next((p for p in phrases if p in msg), None)
    if hit is None:
        out.append(f"The row was graded on {crit}, but the refusal names none of the obstructions "
                   f"{crit} predicts ({', '.join(phrases)}). The collection is indeed not "
                   "combinable, but this is not evidence that the criterion measured the cause.\n")
        return False
    out.append(f"The refusal names the obstruction {crit} predicts (“{hit}”), so the "
               "criterion and the tool agree on the cause, not merely the outcome.\n")
    return True


def h2_candidate(rows):
    """
    A collection graded D on H2 where chunk shape alone differs, with the variable and granule URLs.

    H2's claim is that two granules chunked differently cannot be one array. Isolating it needs a pair
    of granules that agree on the shape of *every* variable they share, so chunk shape is the only
    difference left in the file. Where any shape differs, the arrays fail to align before a chunk
    shape is ever compared, and the resulting refusal is about the alignment instead.
    """
    for r in rows:
        if r["grade"] != "D" or criterion_of(r["blocker"]) != "H2":
            continue
        if not (RESULTS / "probe" / f"{r['short_name']}.json").exists():
            continue
        good = [p for p in opened(load(r["short_name"])) if p.get("container") == "hdf5"]
        for p, q in itertools.combinations(good, 2):
            common = {v["name"] for v in p["vars"]} & {v["name"] for v in q["vars"]}
            pairs = [(var_in(p, n), var_in(q, n)) for n in sorted(common)]
            if not pairs or any(tuple(a["shape"]) != tuple(b["shape"]) for a, b in pairs):
                continue
            differing = [(a, b) for a, b in pairs
                         if a["chunks"] and b["chunks"] and tuple(a["chunks"]) != tuple(b["chunks"])]
            if differing:
                a, b = max(differing, key=lambda ab: math.prod(ab[0]["shape"]))
                return r, a["name"], [a, b], [p["url"], q["url"]]
    return None


def check_h2(rows, token, out):
    """
    Confirm a collection graded D on H2 is refused for differing chunk shapes.
    """
    from virtualizarr import open_virtual_mfdataset
    from virtualizarr.parsers import HDFParser
    from virtualizarr.registry import ObjectStoreRegistry

    got = h2_candidate(rows)
    if got is None:
        out.append("No collection graded D on H2 has two readable HDF5 granules holding one variable "
                   "at the same shape with different chunk shapes, so H2 cannot be isolated from the "
                   "shape mismatches that accompany it here.\n")
        return None
    row, var, recs, urls = got
    group, _ = split_group(var)

    out.append(f"`{row['short_name']}` is graded {row['grade']}.\n")
    out.append(f"> {row['blocker']}\n")
    out.append(f"These two granules agree on the shape of every variable they share, so chunk shape "
               f"is the only difference between them. `{var}` has shape "
               f"{tuple(recs[0]['shape'])} in both, chunked "
               f"{tuple(recs[0]['chunks'])} in one and {tuple(recs[1]['chunks'])} in the other.\n")
    for u in urls:
        out.append(f"- `{u.rsplit('/', 1)[-1]}`")
    out.append("")

    root, _, st = store_for(urls[0], token)
    reg = ObjectStoreRegistry({root: st})
    try:
        # Concatenating over a new dimension forbids data_vars="minimal": every variable has to be
        # stacked, which is exactly what brings the two chunk shapes into one array.
        vds = open_virtual_mfdataset(
            urls, registry=reg, parser=HDFParser(group=group), combine="nested",
            concat_dim="granule", coords="minimal", data_vars="all", compat="override")
        out.append(f"Combination succeeded: dims {dict(vds.sizes)}. The grade claims these granules "
                   "cannot be one array and nothing refused it — recorded as a disagreement to "
                   "resolve, not a pass.\n")
        return False
    except Exception as exc:  # noqa: BLE001 - the failure is the expected result
        return _report_refusal(out, row, exc, "Combination failed")


def cmr_hits(short_name: str, version: str) -> int:
    """
    Total CMR matches for one collection's granules, read from the `CMR-Hits` response header.

    The same request stage 1 issues, so the comparison below tests the counting method rather than
    re-implementing it.
    """
    import requests

    r = requests.get("https://cmr.earthdata.nasa.gov/search/granules",
                     params={"page_size": "0", "short_name": short_name, "version": version},
                     timeout=60)
    r.raise_for_status()
    return int(r.headers["CMR-Hits"])


def check_catalog(out):
    """
    Compare two independent live readings of the same granule count, and measure how far the recorded
    inventory has drifted from them.

    Both readings are taken now: an archive that is still ingesting grows between any two moments, so
    comparing a stored count against a live one measures the file's age rather than whether the
    counting method is right. The stored count is reported alongside as drift, which is the quantity
    the granule and volume columns of the ranking actually carry.
    """
    import datetime as dt

    import earthaccess

    inv_path = RESULTS / "inventory.csv"
    taken = dt.datetime.fromtimestamp(inv_path.stat().st_mtime).isoformat(timespec="minutes")
    out.append("`CMR-Hits` read directly and `earthaccess` counting the same query, both now. "
               f"`inventory.csv` was written {taken}, and an archive still ingesting grows between "
               "then and now, so its stored count is reported as drift rather than as a "
               "disagreement.\n")
    inv = {r["short_name"]: r for r in csv.DictReader(inv_path.open())}
    out.append("| Product | Version | CMR-Hits | earthaccess | Agree | Recorded | Drift since |")
    out.append("|---|---|---|---|---|---|---|")
    for sn in ("ATL06", "MUR-JPL-L4-GLOB-v4.1", "HLSL30"):
        r = inv.get(sn)
        if r is None:
            out.append(f"| {sn} | — | — | — | — | not in inventory | — |")
            continue
        live = cmr_hits(sn, r["version"])
        got = earthaccess.DataGranules().short_name(sn).version(r["version"]).hits()
        drift = live - int(r["granules"])
        out.append(f"| {sn} | {r['version']} | {live} | {got} | "
                   f"{'yes' if got == live else 'no'} | {r['granules']} | "
                   f"{drift:+d} |")
    out.append("")


def section(out, heading, fn):
    """
    Write one check's heading, run it, and record a traceback in place of a result if it raises.
    """
    out.append(f"## {heading}\n")
    try:
        return fn()
    except Exception:  # noqa: BLE001 - a failed check is reported, not swallowed
        out.append("Check did not complete:\n")
        out.append("```")
        out.append(traceback.format_exc()[-1200:])
        out.append("```\n")
        return None


def main() -> int:
    import earthaccess

    vz_shims.install()
    earthaccess.login(strategy="netrc")
    token = earthaccess.__auth__.token["access_token"]

    rows = list(csv.DictReader((RESULTS / "virtualizability.csv").open()))
    out = ["# Verification\n",
           "Every check below builds or reads a real virtual store over NASA granules; none rest "
           "on catalog metadata.\n"]

    best = pick(rows, {"A", "B"})
    if best is None:
        out.append("No collection graded A or B has readable HDF5 granules, so there is nothing to "
                   "run a positive control on.\n")
    else:
        row, rec = best
        head = f"1. Positive control — `{row['short_name']}`, graded {row['grade']}"
        got = section(out, head, lambda: check_positive(row, rec, token, out))
        if got:
            vds, var, urls, _ = got
            section(out, "2. Icechunk round-trip",
                    lambda: check_icechunk(vds, var, urls, token, out))
        section(out, "3. Hand-checked chunk", lambda: check_hand_chunk(rec, token, out))

    # Both hard blockers get their own control: H3 is the interior-partial-chunk case and H2 the
    # differing-chunk-shape case, and a criterion is only demonstrated by a collection it decided.
    section(out, "4. Negative control — H3, interior partial chunk",
            lambda: check_negative(rows, token, out, criterion="H3"))
    section(out, "5. Negative control — H2, chunk shape differs across granules",
            lambda: check_h2(rows, token, out))
    section(out, "6. Catalog cross-check", lambda: check_catalog(out))

    (RESULTS / "verification.md").write_text("\n".join(out) + "\n")
    print("wrote results/verification.md")
    return 0


if __name__ == "__main__":
    sys.exit(main())
