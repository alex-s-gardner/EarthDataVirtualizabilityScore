"""
On-disk memoization of the byte ranges stage 3 reads over NASA's authenticated HTTPS path.

Every request on that path pays an Earthdata Login redirect of a few seconds, and the probe reads only
a granule's chunk index — a median of a handful of 1 MiB blocks per granule, against granules whose
median size is close to a gigabyte. Caching the ranges rather than the granules therefore holds what
the probe actually touches: about 15 GiB for a full sample, against 530 GB for the same granules whole.

The cache sits below the block reader, wrapping the store the reader was handed. A block the reader
had to go outside its own in-memory cache for is still counted as fetched whether or not this cache
served it, so `P-md` measures the granule's layout and not what this machine happens to hold.
"""

from __future__ import annotations

import json
import os
from hashlib import sha256
from pathlib import Path

#: Cache root. Overridden with `NASA_VZ_PROBE_CACHE` to put it on another volume.
CACHE_ROOT = Path(os.environ.get(
    "NASA_VZ_PROBE_CACHE", Path(__file__).resolve().parent.parent / ".probe_cache"))


def url_key(url: str) -> str:
    """
    The cache directory name for one granule URL.

    NASA granule URLs are stable for a given granule, so the URL identifies the bytes.
    """
    return sha256(url.encode()).hexdigest()[:32]


class RangeCache:
    """
    Byte ranges of one object, stored one file per range.

    A range is keyed by its start and length, which is exact rather than approximate: the block reader
    asks for aligned blocks of a fixed size, so a hit serves precisely the bytes that were stored.
    """

    def __init__(self, url: str, root: Path = CACHE_ROOT):
        self.dir = root / url_key(url) / "ranges"
        self.hits = 0
        self.misses = 0

    def _path(self, start: int, length: int) -> Path:
        return self.dir / f"{start}_{length}"

    def get(self, start: int, length: int) -> bytes | None:
        path = self._path(start, length)
        try:
            data = path.read_bytes()
        except OSError:
            self.misses += 1
            return None
        # A short read means a write was interrupted. Treating it as a miss re-fetches the range
        # rather than handing a truncated block to a parser, which would be read as a malformed file.
        if len(data) != length:
            self.misses += 1
            return None
        self.hits += 1
        return data

    def put(self, start: int, length: int, data: bytes) -> None:
        if len(data) != length:
            return
        try:
            self.dir.mkdir(parents=True, exist_ok=True)
            path = self._path(start, length)
            tmp = path.with_suffix(".tmp")
            tmp.write_bytes(data)
            tmp.replace(path)
        except OSError:
            # A cache that cannot be written is a slow run, not a wrong one.
            pass


class CachingStore:
    """
    An obspec store that serves ranges from `RangeCache` and fetches the rest from `inner`.

    Implements the subset of the protocol `BlockStoreReader` requires — `head`, `get`, `get_range`,
    and `get_ranges` — by delegation, so the reader's own logic is untouched.
    """

    def __init__(self, inner, url: str, root: Path = CACHE_ROOT):
        self._inner = inner
        self._cache = RangeCache(url, root)

    @property
    def stats(self) -> dict:
        return {"hits": self._cache.hits, "misses": self._cache.misses}

    def head(self, path: str):
        return self._inner.head(path)

    def get(self, path: str, **kwargs):
        return self._inner.get(path, **kwargs)

    def get_range(self, path: str, *, start: int, end: int | None = None,
                  length: int | None = None):
        if length is None:
            length = (end - start) if end is not None else None
        if length is None:
            return self._inner.get_range(path, start=start, end=end)
        hit = self._cache.get(start, length)
        if hit is not None:
            return hit
        data = bytes(self._inner.get_range(path, start=start, length=length))
        self._cache.put(start, length, data)
        return data

    def get_ranges(self, path: str, *, starts, lengths):
        starts = list(starts)
        lengths = list(lengths)
        out: list[bytes | None] = [self._cache.get(s, n) for s, n in zip(starts, lengths)]
        missing = [i for i, v in enumerate(out) if v is None]
        if missing:
            fetched = self._inner.get_ranges(path,
                                             starts=[starts[i] for i in missing],
                                             lengths=[lengths[i] for i in missing])
            for i, data in zip(missing, fetched):
                data = bytes(data)
                out[i] = data
                self._cache.put(starts[i], lengths[i], data)
        return out


class MetaCache:
    """
    The three per-granule facts stage 3 reads before it opens anything: object size, whether a DMR++
    sidecar exists, and the container format its first bytes name.

    Each costs its own request and none changes for a given granule, so they are memoized together in
    one small JSON file per granule.
    """

    def __init__(self, url: str, root: Path = CACHE_ROOT):
        self.path = root / url_key(url) / "meta.json"
        try:
            self.data = json.loads(self.path.read_text())
        except (OSError, ValueError):
            self.data = {}

    def get(self, key: str):
        return self.data.get(key)

    def put(self, key: str, value) -> None:
        self.data[key] = value
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.path.with_suffix(".tmp")
            tmp.write_text(json.dumps(self.data))
            tmp.replace(self.path)
        except OSError:
            pass


#: Free bytes the cache will not encroach on. A whole granule is kept only to make a later re-probe of
#: the kerchunk-backed formats cheap, which is never worth filling the volume the run itself needs.
FREE_SPACE_FLOOR = 20 * 1024**3


def room_for(nbytes: int, root: Path = CACHE_ROOT) -> bool:
    """
    Whether the cache can take `nbytes` and still leave `FREE_SPACE_FLOOR` free.

    Returns `False` when the free space cannot be determined, so an unreadable volume means the probe
    reads the granule without keeping it rather than risking the run on a guess.
    """
    import shutil

    probe = root if root.exists() else root.parent
    try:
        free = shutil.disk_usage(probe).free
    except OSError:
        return False
    return free - nbytes > FREE_SPACE_FLOOR


def file_cache_path(url: str, root: Path = CACHE_ROOT) -> Path:
    """
    Where a whole granule is kept for the parsers that must read it from a local file.

    The HDF4 and netCDF-3 parsers reach the network through kerchunk's fsspec backend and issue many
    small reads, so stage 3 copies those granules to disk before parsing. Keeping the copy makes a
    re-probe of those collections free rather than another full download.
    """
    return root / url_key(url) / "granule"


def cache_size_bytes(root: Path = CACHE_ROOT) -> int:
    """
    Total bytes held in the cache.
    """
    if not root.exists():
        return 0
    return sum(p.stat().st_size for p in root.rglob("*") if p.is_file())
