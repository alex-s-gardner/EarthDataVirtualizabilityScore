"""
Stage 3: open every sampled granule with VirtualiZarr and record the facts that decide
virtualizability.

VirtualiZarr's parsers are the oracle: they emit the `ManifestStore` a real virtual dataset is built
from, so a chunk shape recorded here is the one a reader would actually see, and a parser refusal is
itself the answer. The refusal's exception type names the blocking feature.

NASA's protected buckets reject direct S3 outside us-west-2, so access is over authenticated HTTPS:
an `obstore` `HTTPStore` carrying an Earthdata Login bearer token, which follows the redirect to the
presigned host and drops the token there. Manifest paths therefore hold durable NASA HTTPS URLs.

Reads `results/granule_sample.json`, writes one `results/probe/<short_name>.json` per collection so
stage 4 never needs the network.
"""

from __future__ import annotations

import json
import multiprocessing as mp
import signal
import sys
import tempfile
import time
import traceback
import warnings
from pathlib import Path
from statistics import median
from urllib.parse import urlsplit

warnings.filterwarnings("ignore")

import earthaccess
from obspec_utils.readers import BlockStoreReader
from obstore.store import HTTPStore, LocalStore
from virtualizarr.parsers import HDF4Parser, HDFParser, NetCDF3Parser
from virtualizarr.registry import ObjectStoreRegistry

sys.path.insert(0, str(Path(__file__).resolve().parent))
import vz_shims

RESULTS = Path(__file__).resolve().parent.parent / "results"
PROBE_DIR = RESULTS / "probe"

# Formats outside every VirtualiZarr parser. Recorded as a hard blocker rather than skipped, because
# "no parser reads this" is a virtualizability finding.
NO_PARSER = {"ASCII", "HGT", "SHAPEFILE", "CSV", "PDF", "PNG", "JPEG", "KML", "KMZ", "BINARY"}

# Granules per collection whose coordinate values are read. Two is what comparing grid origins
# between granules requires, and each additional one costs several seconds of redirect latency. The
# two are taken from opposite ends of the sample, which stage 2 orders by time: comparing the earliest
# granule against the latest is what makes the grid comparison able to see a producer changing the
# grid mid-record, which comparing two granules of the same epoch cannot.
COORD_GRANULES = 2

# Attributes that carry grid definition or CF decoding, the only ones stage 4 compares across
# granules. Everything else is dropped to keep the probe artifacts small.
GRID_ATTRS = (
    "crs_wkt", "spatial_ref", "GeoTransform", "grid_mapping", "grid_mapping_name", "proj4",
    "esri_pe_string", "latitude_of_projection_origin", "longitude_of_central_meridian",
    "straight_vertical_longitude_from_pole", "standard_parallel", "false_easting", "false_northing",
    "semi_major_axis", "inverse_flattening",
)
CF_ATTRS = ("scale_factor", "add_offset", "_FillValue", "units", "missing_value", "calendar")


class LoggingReader(BlockStoreReader):
    """
    `BlockStoreReader` that records which blocks it fetched from the network.

    Each entry in `fetched` is a block index actually requested, cache hits excluded, so the log
    counts real get-requests. That count is the operational meaning of "consolidated metadata": a
    cloud-optimized granule exposes its whole chunk index in a few leading blocks, while a poorly
    laid out one forces the reader to walk the file.
    """

    #: Populated per instance; the factory below hands the list back to the caller.
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.fetched: list[int] = []

    def _get_blocks(self, block_indices):
        self.fetched.extend(i for i in block_indices if i not in self._cache)
        return super()._get_blocks(block_indices)


def logging_factory(log: list[int]):
    """
    Reader factory for a VirtualiZarr parser that appends fetched block indices to `log`.
    """

    def factory(store, path, **kwargs):
        r = LoggingReader(store, path, **kwargs)
        r.fetched = log
        return r

    return factory


def locality(fetched: list[int], file_bytes: int, block_size: int = 1 << 20) -> dict:
    """
    Summarize a block-fetch log into metadata-layout statistics.

    `leading_fraction` is the share of fetched blocks lying in the first 5% of the file: near 1.0
    means the chunk index is consolidated at the front and reachable in one contiguous range
    request. `contiguous_runs` counts maximal runs of adjacent blocks, so a value of 1 means the
    reader touched a single unbroken region.
    """
    if not fetched:
        return {"n_blocks": 0, "leading_fraction": None, "contiguous_runs": 0, "span_fraction": None}
    n_blocks_total = max(file_bytes // block_size, 1)
    head = max(int(n_blocks_total * 0.05), 1)
    uniq = sorted(set(fetched))
    runs = 1 + sum(1 for a, b in zip(uniq, uniq[1:]) if b != a + 1)
    return {
        "n_blocks": len(uniq),
        "n_fetches": len(fetched),
        "leading_fraction": sum(1 for i in uniq if i < head) / len(uniq),
        "contiguous_runs": runs,
        "span_fraction": (uniq[-1] - uniq[0] + 1) / n_blocks_total,
    }


def _store(url: str, token: str) -> tuple[str, str, HTTPStore]:
    """
    Root URL, object path, and an authenticated store for one granule URL.
    """
    sp = urlsplit(url)
    root = f"{sp.scheme}://{sp.netloc}"
    opts = {"default_headers": {"Authorization": f"Bearer {token}"}}
    return root, sp.path.lstrip("/"), HTTPStore(root, client_options=opts)


def _walk(group, prefix=""):
    """
    Yield `(path, ManifestArray)` for every array in a `ManifestGroup` hierarchy.

    Hierarchical HDF5 products keep their arrays in subgroups, so a flat read of the root group
    reports nothing; the whole tree has to be walked.
    """
    for name, arr in group.arrays.items():
        yield prefix + name, arr
    for name, sub in group.groups.items():
        yield from _walk(sub, prefix + name + "/")


def _subset(attrs, keys) -> dict:
    """
    The entries of `attrs` under `keys`, coerced to JSON-safe scalars.
    """
    out = {}
    for k in keys:
        if k not in attrs:
            continue
        v = attrs[k]
        out[k] = v if isinstance(v, (str, int, float, bool, type(None))) else str(v)
    return out


def arrays_from_store(ms) -> list[dict]:
    """
    Per-array layout for every array in a `ManifestStore`.

    `chunk_bytes_median` comes from the manifest's stored byte lengths, which is the amount one
    get-request moves, not the decompressed size.
    """
    out = []
    for name, a in _walk(ms._group):
        md = a.metadata
        grid = md.chunk_grid
        chunk_shape = tuple(getattr(grid, "chunk_shape", ()) or ())
        lengths = [int(x) for x in a.manifest._lengths.ravel() if x]
        attrs = dict(md.attributes)
        out.append({
            "name": name,
            "shape": [int(x) for x in md.shape],
            "chunks": [int(x) for x in chunk_shape],
            "dtype": str(md.data_type.to_native_dtype()),
            "codecs": [type(c).__name__ for c in md.codecs],
            "dims": list(md.dimension_names) if md.dimension_names else None,
            "n_chunks": len(lengths),
            "chunk_bytes_median": int(median(lengths)) if lengths else None,
            "chunk_bytes_max": max(lengths) if lengths else None,
            "cf": _subset(attrs, CF_ATTRS),
            "grid": _subset(attrs, GRID_ATTRS),
        })
    return out


def tiff_crs(page) -> str:
    """
    A GeoTIFF page's coordinate reference system, as a string that is equal for equal systems.

    `ProjectedCSTypeGeoKey` holds an EPSG code, except when it is 32767 ("user-defined") and the
    projection is named by `ProjectionGeoKey` instead; HLS writes the latter form. Tiepoint eastings
    and northings are only comparable between granules of the same system, so a grid comparison that
    ignores this subtracts coordinates of different UTM zones.
    """
    gt = page.geotiff_tags or {}
    code = gt.get("ProjectedCSTypeGeoKey")
    if code is not None and int(code) != 32767:
        return f"EPSG:{int(code)}"
    proj = gt.get("ProjectionGeoKey")
    if proj is not None:
        return f"ProjectionGeoKey:{int(proj)}"
    return str(gt.get("GTCitationGeoKey") or gt.get("GeogCitationGeoKey") or "")


def arrays_from_tiff(store, path: str, log: list[int]) -> tuple[list[dict], dict]:
    """
    Per-array layout for a (Cloud-Optimized) GeoTIFF, read from its TIFF tags.

    VirtualiZarr 2.7.3 ships no TIFF parser, so the tile offsets and byte counts that a manifest
    needs are taken straight from `TileOffsets`/`TileByteCounts`. Each TIFF page becomes one array;
    page 0 is full resolution and later pages are overviews, which is why a COG reports several
    arrays of the same variable at different sizes.
    """
    import tifffile

    reader = LoggingReader(store, path)
    reader.fetched = log
    out, grid = [], {}
    with tifffile.TiffFile(reader) as tf:
        for i, p in enumerate(tf.pages):
            counts = [int(c) for c in p.databytecounts if c]
            if i == 0:
                tie = p.tags.get("ModelTiepointTag")
                scale = p.tags.get("ModelPixelScaleTag")
                grid = {
                    "tiepoint": [float(x) for x in tie.value] if tie else None,
                    "pixel_scale": [float(x) for x in scale.value] if scale else None,
                    "crs": tiff_crs(p),
                    "photometric": str(p.photometric),
                    "planarconfig": str(p.planarconfig),
                }
            out.append({
                "name": "band" if i == 0 else f"overview{i}",
                "overview": i > 0,
                "shape": [int(x) for x in p.shape],
                "chunks": [int(p.tilelength), int(p.tilewidth)] if p.is_tiled else None,
                "dtype": str(p.dtype),
                "codecs": [str(p.compression)],
                "dims": None,
                "n_chunks": len(counts),
                "chunk_bytes_median": int(median(counts)) if counts else None,
                "chunk_bytes_max": max(counts) if counts else None,
                "tiled": bool(p.is_tiled),
                "cf": {},
                "grid": {},
            })
    return out, grid


# Names of one-dimensional arrays read for their values, to turn grid alignment from an inference
# about dimension sizes into a measured comparison of grid origin and spacing.
COORD_NAMES = ("lat", "latitude", "lon", "longitude", "x", "y", "time",
               "XDim", "YDim", "nlat", "nlon")

# Ceiling on coordinate arrays read per granule. A grid needs two; the cap stops a product that
# repeats coordinates per beam or per band from dominating the run.
MAX_COORD_ARRAYS = 6


def coordinates(ms, arrays: list[dict]) -> dict:
    """
    Origin, spacing, and extent of each one-dimensional coordinate array.

    A `ManifestStore` is a Zarr store, so the coordinate values are read through the same manifest
    and authenticated transport as everything else. Grid alignment between two granules is then a
    comparison of measured numbers rather than of dimension sizes, which cannot distinguish two
    grids of equal size offset by half a cell.
    """
    import zarr

    out = {}
    for a in arrays:
        name = a["name"]
        leaf = name.rsplit("/", 1)[-1]
        if leaf not in COORD_NAMES or len(a["shape"]) != 1 or a["shape"][0] < 2:
            continue
        # A gridded product defines its grid once, at or near the root. Deeply nested coordinates
        # belong to swath geometry, where there is no grid to compare and one array exists per beam.
        if name.count("/") > 1 or len(out) >= MAX_COORD_ARRAYS:
            continue
        try:
            arr = zarr.open_array(store=ms, path=name, mode="r", zarr_format=3)
            first, second, last = float(arr[0]), float(arr[1]), float(arr[-1])
        except Exception as exc:  # noqa: BLE001 - an unreadable coordinate is recorded, not fatal
            out[name] = {"error": f"{type(exc).__name__}: {str(exc)[:80]}"}
            continue
        out[name] = {"n": a["shape"][0], "first": first, "step": second - first, "last": last}
    return out


def sniff(store, path: str) -> str:
    """
    The container format of one object, from its first bytes.

    CMR's declared format is not specific enough to choose a parser: "HDF-EOS" covers both
    HDF-EOS2, which is HDF4 underneath, and HDF-EOS5, which is HDF5, and the two need different
    parsers. One eight-byte read settles it.
    """
    import obstore

    head = bytes(obstore.get_range(store, path, start=0, end=8))
    if head.startswith(b"\x89HDF\r\n\x1a\n"):
        return "hdf5"
    if head.startswith(b"\x0e\x03\x13\x01"):
        return "hdf4"
    if head[:3] == b"CDF":
        return "netcdf3"
    if head[:4] in (b"II*\x00", b"MM\x00*", b"II+\x00", b"MM\x00+"):
        return "tiff"
    return "unknown"


def parser_for(kind: str, log: list[int], token: str):
    """
    The VirtualiZarr parser for a sniffed container format, or `None` for TIFF, which is read from
    its tags instead.

    The HDF4 and netCDF-3 parsers reach the network through kerchunk's fsspec backend rather than
    the object-store registry, so they are handed Earthdata Login credentials separately. They also
    bypass the instrumented reader, which is why locality goes unmeasured for those formats.
    `trust_env` must be off: fsspec otherwise picks up `~/.netrc` and sends basic auth alongside the
    bearer token, and Earthdata Login rejects the request.

    Raises `ValueError` for a container no parser reads.
    """
    fsspec_opts = {"storage_options": {"client_kwargs": {
        "headers": {"Authorization": f"Bearer {token}"}, "trust_env": False}}}

    if kind == "tiff":
        return None
    if kind == "hdf4":
        return HDF4Parser(reader_options=fsspec_opts)
    if kind == "netcdf3":
        return NetCDF3Parser(reader_options=fsspec_opts)
    if kind == "hdf5":
        return HDFParser(reader_factory=logging_factory(log))
    raise ValueError(f"unrecognized container format (first bytes match no known signature)")


# Formats whose parser reaches the network through kerchunk's fsspec backend. Those readers issue
# many small reads, and every read on NASA's authenticated HTTPS path pays a multi-second Earthdata
# Login redirect, so the granule is copied to disk once and parsed locally instead. Chunk offsets are
# positions within the file and do not depend on how the file was read, so the layout recorded is
# identical.
DOWNLOAD_FIRST = ("hdf4",)

# Granules above this size are not copied to disk; their layout goes unrecorded rather than spending
# the bandwidth.
DOWNLOAD_CAP = 800 * 1024 * 1024


def fetch_to_disk(store, path: str, dest: Path) -> None:
    """
    Stream one object to a local file.
    """
    import obstore

    result = obstore.get(store, path)
    with dest.open("wb") as fh:
        for chunk in result.stream():
            fh.write(bytes(chunk))


# Wall-clock budget for one granule. A product whose chunk index needs thousands of small reads can
# take longer than this over authenticated HTTPS, where every read pays an Earthdata Login redirect;
# the budget bounds the run and records how far the reader got instead of stalling on it.
GRANULE_DEADLINE = 480


#: Path prefixes rewritten out of a recorded traceback, longest first so the more specific wins.
_PATH_PREFIXES = sorted(
    ((str(RESULTS.parent / ".venv"), "<env>"), (str(RESULTS.parent), "<repo>"), (sys.prefix, "<env>")),
    key=lambda pair: -len(pair[0]))


def relative_paths(text: str) -> str:
    """
    A traceback with this machine's absolute paths replaced by placeholders.

    A recorded traceback names the reader that refused a granule, which is the finding; where that
    reader happens to live on the machine that ran the probe is not, and writing it into a published
    artifact leaks the operator's home directory for no gain.
    """
    for prefix, name in _PATH_PREFIXES:
        text = text.replace(prefix, name)
    return text


class ProbeTimeout(Exception):
    """
    Raised when one granule exceeds `GRANULE_DEADLINE`.
    """


def _deadline(seconds: int):
    """
    Context manager raising `ProbeTimeout` after `seconds`.
    """
    from contextlib import contextmanager

    @contextmanager
    def cm():
        def fire(signum, frame):
            raise ProbeTimeout(
                f"exceeded the {seconds} s probe budget for one granule")

        previous = signal.signal(signal.SIGALRM, fire)
        signal.setitimer(signal.ITIMER_REAL, seconds)
        try:
            yield
        finally:
            signal.setitimer(signal.ITIMER_REAL, 0)
            signal.signal(signal.SIGALRM, previous)

    return cm()


def _read_layout(rec: dict, url: str, token: str, log: list[int], read_coords: bool) -> None:
    """
    Fill `rec` with one granule's container format, array layout, and grid attributes.
    """
    root, path, st = _store(url, token)
    rec["file_bytes"] = int(st.head(path)["size"])
    rec["dmrpp"] = _has_dmrpp(st, path)

    kind = sniff(st, path)
    rec["container"] = kind
    # The container is read from the object's own first bytes before a format is ruled out, so a
    # collection graded on "no parser reads this" is graded on what the file is rather than on what
    # CMR's format field says it is.
    if kind == "unknown" and rec["declared_format"].split("+")[0].upper() in NO_PARSER:
        raise ValueError(f"no VirtualiZarr parser reads {rec['declared_format']}")
    parser = parser_for(kind, log, token)

    if parser is None:
        rec["vars"], rec["tiff_grid"] = arrays_from_tiff(st, path, log)
        return

    if kind in DOWNLOAD_FIRST:
        if rec["file_bytes"] > DOWNLOAD_CAP:
            raise ValueError(
                f"granule is {rec['file_bytes'] / 1e6:.0f} MB; above the "
                f"{DOWNLOAD_CAP / 1e6:.0f} MB copy-to-disk limit for kerchunk-backed parsers")
        rec["parsed_locally"] = True
        with tempfile.TemporaryDirectory() as tmp:
            local = Path(tmp) / Path(path).name
            fetch_to_disk(st, path, local)
            ms = parser(local.as_uri(), ObjectStoreRegistry({"file://": LocalStore()}))
            _record_store(rec, ms, read_coords)
        return

    ms = parser(url, ObjectStoreRegistry({root: st}))
    _record_store(rec, ms, read_coords)


def _record_store(rec: dict, ms, read_coords: bool) -> None:
    """
    Copy a `ManifestStore`'s array layout, root attributes, and optionally coordinates into `rec`.
    """
    rec["vars"] = arrays_from_store(ms)
    rec["root_attrs"] = _subset(dict(ms._group.metadata.attributes), GRID_ATTRS)
    if read_coords:
        rec["coords"] = coordinates(ms, rec["vars"])


def probe_granule(gran: dict, fmt: str, token: str, read_coords: bool = False) -> dict:
    """
    Record one granule's layout, or the reason it cannot be virtualized.

    `read_coords` additionally reads coordinate values, which costs one range request per coordinate
    array. Every request through NASA's authenticated HTTPS path pays an Earthdata Login redirect
    chain of a few seconds, so the caller enables this for only as many granules as the grid
    comparison needs.

    Never raises: a failure is a result, and the exception type is what classifies the blocker. A
    granule that exceeds the probe budget still reports the blocks its reader had fetched, which is
    the measurement that made it slow.
    """
    url = gran["url"]
    rec = {"granule_ur": gran["granule_ur"], "url": url, "orbit": gran.get("orbit", ""),
           "declared_format": fmt}

    t0 = time.time()
    log: list[int] = []
    try:
        with _deadline(GRANULE_DEADLINE):
            _read_layout(rec, url, token, log, read_coords)
        rec["ok"] = True
        rec["locality"] = locality(log, rec["file_bytes"])
    except Exception as exc:  # noqa: BLE001 - the exception type is the finding
        rec.update(ok=False, error_type=type(exc).__name__, error=str(exc)[:400],
                   traceback_tail=relative_paths(traceback.format_exc())[-300:])
        if log and rec.get("file_bytes"):
            rec["locality"] = locality(log, rec["file_bytes"])
    rec["seconds"] = round(time.time() - t0, 1)
    return rec


# Grace period the parent allows past `GRANULE_DEADLINE` before killing the child outright.
KILL_GRACE = 90


def _probe_child(out_path: str, gran: dict, fmt: str, token: str, read_coords: bool) -> None:
    """
    Probe one granule in a child process and write the record to `out_path` as JSON.
    """
    vz_shims.install()
    Path(out_path).write_text(json.dumps(probe_granule(gran, fmt, token, read_coords)))


def probe_granule_bounded(gran: dict, fmt: str, token: str, read_coords: bool) -> dict:
    """
    Probe one granule under a wall-clock bound the parent can always enforce.

    `probe_granule`'s own deadline is a signal handler, which CPython can only run between bytecodes
    in the main thread; a reader blocked inside a native call that has released the GIL does not see
    it. Running the probe in a child process the parent kills makes the bound unconditional. The
    record — including the block-fetch log that measures metadata locality — survives whenever the
    in-process deadline fires first, and is lost only when the child had to be killed.
    """
    t0 = time.time()
    rec = {"granule_ur": gran["granule_ur"], "url": gran["url"], "orbit": gran.get("orbit", "")}
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "rec.json"
        proc = mp.Process(target=_probe_child,
                          args=(str(path), gran, fmt, token, read_coords), daemon=True)
        proc.start()
        proc.join(GRANULE_DEADLINE + KILL_GRACE)
        if proc.is_alive():
            proc.kill()
            proc.join(10)
            rec.update(ok=False, error_type="ProbeTimeout", seconds=round(time.time() - t0, 1),
                       error=f"reader did not return within {GRANULE_DEADLINE + KILL_GRACE} s and "
                             "was blocked inside a single request, so no partial fetch log survives")
            return rec
        if path.exists():
            return json.loads(path.read_text())
    rec.update(ok=False, error_type="ProbeCrash", seconds=round(time.time() - t0, 1),
               error=f"child process exited with code {proc.exitcode} before writing a record")
    return rec


def probe_collection(entry: dict, token: str) -> list[dict]:
    """
    Probe a collection's sampled granules, abandoning the collection after the first timeout.

    Granules of one collection are written by the same producer, so a chunk index that exhausts
    `GRANULE_DEADLINE` on one granule exhausts it on the rest; the remaining granules are recorded as
    unattempted rather than spending another budget each to confirm it.
    """
    fmt = entry["format"]
    probes = []
    grans = entry["granules"]
    # Opposite ends of a time-ordered sample, so the grid comparison spans the record.
    coord_at = set(list(range(len(grans)))[:COORD_GRANULES // 2] +
                   list(range(len(grans)))[-(COORD_GRANULES - COORD_GRANULES // 2):])
    for j, g in enumerate(grans):
        if any(p.get("error_type") == "ProbeTimeout" for p in probes):
            probes.append({
                "granule_ur": g["granule_ur"], "url": g["url"], "orbit": g.get("orbit", ""),
                "ok": False, "attempted": False, "error_type": "ProbeTimeout",
                "error": "not attempted: an earlier granule of this collection exceeded the "
                         f"{GRANULE_DEADLINE} s probe budget",
            })
            continue
        probes.append(probe_granule_bounded(g, fmt, token, read_coords=(j in coord_at)))
    return probes


def _has_dmrpp(store, path: str) -> bool:
    """
    Whether NASA publishes a DMR++ sidecar beside the granule.

    A DMR++ is an OPeNDAP-generated chunk manifest, so its presence means the archive already holds
    the byte offsets a virtual store needs.
    """
    try:
        return bool(store.head(path + ".dmrpp")["size"])
    except Exception:  # noqa: BLE001 - absence is the normal case
        return False


def main() -> int:
    sample = json.loads((RESULTS / "granule_sample.json").read_text())
    PROBE_DIR.mkdir(parents=True, exist_ok=True)

    shims = vz_shims.install()
    print(f"shims: {shims}", flush=True)

    earthaccess.login(strategy="netrc")
    token = earthaccess.__auth__.token["access_token"]

    only = sys.argv[1:]
    unknown = sorted(set(only) - set(sample))
    if unknown:
        raise SystemExit(f"not in results/granule_sample.json: {unknown}")
    names = [n for n in sorted(sample) if not only or n in only]

    for i, short_name in enumerate(names, 1):
        out_path = PROBE_DIR / f"{short_name}.json"
        # An existing artifact is kept only when resuming the whole run; naming a collection on the
        # command line means re-probing it, so a stale artifact must not silently satisfy the request.
        if out_path.exists() and not only:
            continue
        entry = sample[short_name]
        print(f"[{i}/{len(names)}] {short_name} ({entry['format']})", flush=True)
        probes = probe_collection(entry, token)
        out_path.write_text(json.dumps(
            {**{k: v for k, v in entry.items() if k != "granules"},
             "short_name": short_name, "shims": shims, "probes": probes}, indent=1))
        errs = sorted({p["error_type"] for p in probes if not p["ok"]})
        n_ok = sum(p["ok"] for p in probes)
        shapes = {tuple(v["chunks"] or []) for p in probes if p["ok"] for v in p["vars"]}
        print(f"      {n_ok}/{len(probes)} opened, {len(shapes)} distinct chunk shapes"
              + (f"  errors={errs}" if errs else ""), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
