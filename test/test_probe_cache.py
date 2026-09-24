"""
Tests for the stage 3 range cache, run against a local store so no network or credential is needed.

The cache sits between a VirtualiZarr parser's block reader and the object store, so what it has to
guarantee is that the bytes a reader sees are identical with and without it, and that a block the
reader had to fetch is still counted as fetched when the cache served it — otherwise the cache would
change the `P-md` measurement rather than only its cost.

Run: `.venv/bin/python test/test_probe_cache.py`
"""

from __future__ import annotations

import shutil
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

from obspec_utils.readers import BlockStoreReader
from obstore.store import LocalStore

from probe_cache import CachingStore, MetaCache, RangeCache, cache_size_bytes, url_key

BLOCK = 1 << 20


def make_file(d: Path, n_blocks: int = 4) -> tuple[Path, bytes]:
    """A file of `n_blocks` distinguishable 1 MiB blocks, plus a short final block."""
    body = b"".join(bytes([i]) * BLOCK for i in range(n_blocks)) + b"tail"
    path = d / "granule.bin"
    path.write_bytes(body)
    return path, body


def test_reader_sees_identical_bytes(tmp: Path, cache_root: Path) -> None:
    path, body = make_file(tmp)
    store = LocalStore(str(tmp))
    url = "https://example.test/granule.bin"

    plain = BlockStoreReader(store, path.name)
    plain.seek(BLOCK - 8)
    want = plain.read(32)

    cached = BlockStoreReader(CachingStore(store, url, root=cache_root), path.name)
    cached.seek(BLOCK - 8)
    got = cached.read(32)
    assert got == want, (got[:8], want[:8])
    # A read spanning the last, short block must come back the same length.
    cached.seek(len(body) - 10)
    assert cached.read(64) == body[-10:]
    print("  reader sees identical bytes through the cache")


def test_second_read_is_served_from_disk(tmp: Path, cache_root: Path) -> None:
    path, body = make_file(tmp)
    store = LocalStore(str(tmp))
    url = "https://example.test/second.bin"

    warm = CachingStore(store, url, root=cache_root)
    r1 = BlockStoreReader(warm, path.name)
    r1.seek(0)
    first = r1.read(3 * BLOCK)
    assert warm.stats["misses"] > 0, warm.stats
    assert warm.stats["hits"] == 0, warm.stats

    reuse = CachingStore(store, url, root=cache_root)
    r2 = BlockStoreReader(reuse, path.name)
    r2.seek(0)
    assert r2.read(3 * BLOCK) == first
    assert reuse.stats["hits"] > 0, reuse.stats
    assert reuse.stats["misses"] == 0, reuse.stats
    print(f"  second read served from disk ({reuse.stats['hits']} hits, 0 misses)")


def test_truncated_range_is_a_miss(tmp: Path, cache_root: Path) -> None:
    """A partially written range must be re-fetched, never handed to a parser as a short block."""
    url = "https://example.test/torn.bin"
    cache = RangeCache(url, root=cache_root)
    cache.put(0, BLOCK, b"x" * BLOCK)
    assert cache.get(0, BLOCK) == b"x" * BLOCK
    (cache.dir / f"0_{BLOCK}").write_bytes(b"x" * 10)
    assert cache.get(0, BLOCK) is None
    # A length that does not match the data is not stored at all.
    cache.put(BLOCK, BLOCK, b"short")
    assert cache.get(BLOCK, BLOCK) is None
    print("  a torn or short range reads as a miss")


def test_meta_cache_round_trip(cache_root: Path) -> None:
    url = "https://example.test/meta.bin"
    m = MetaCache(url, root=cache_root)
    assert m.get("container") is None
    m.put("container", "hdf5")
    m.put("file_bytes", 1234)
    m.put("dmrpp", False)
    again = MetaCache(url, root=cache_root)
    assert again.get("container") == "hdf5"
    assert again.get("file_bytes") == 1234
    # False must survive as False rather than as an absence.
    assert again.get("dmrpp") is False
    print("  metadata cache round-trips, including a false value")


def test_free_space_floor(cache_root: Path) -> None:
    """A whole-granule copy is a convenience; the run it would crowd out is not."""
    from probe_cache import FREE_SPACE_FLOOR, room_for

    assert room_for(0, cache_root) in (True, False)      # answers without raising
    # Nothing fits when the request alone exceeds the volume.
    assert not room_for(1 << 62, cache_root)
    # An unreadable location is treated as no room rather than as unlimited room.
    assert not room_for(1, Path("/nonexistent-volume-xyz/cache"))
    assert FREE_SPACE_FLOOR > 0
    print("  free-space floor refuses a copy it cannot afford")


def test_keys_are_url_specific() -> None:
    assert url_key("https://a/x") != url_key("https://a/y")
    assert url_key("https://a/x") == url_key("https://a/x")
    print("  cache keys are per-URL and stable")


def main() -> int:
    tmp = Path(tempfile.mkdtemp())
    cache_root = tmp / "cache"
    try:
        test_reader_sees_identical_bytes(tmp, cache_root)
        test_second_read_is_served_from_disk(tmp, cache_root)
        test_truncated_range_is_a_miss(tmp, cache_root)
        test_meta_cache_round_trip(cache_root)
        test_free_space_floor(cache_root)
        test_keys_are_url_specific()
        print(f"  cache held {cache_size_bytes(cache_root) / 1e6:.1f} MB across these tests")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("probe cache: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
