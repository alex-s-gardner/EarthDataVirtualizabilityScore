# EarthDataVirtualizabilityScore

Ranks NASA Earthdata collections by whether their archives can be served as lazy Zarr datacubes
**without duplicating bytes**.

**[results/report.md](results/report.md)** is the output: 58 collections graded A–F, each with the
criterion that decided it and the measurement behind it. **[results/verification.md](results/verification.md)**
tests the grades by building real virtual stores over the archive.

## Why this is a question about the bytes

Cloud storage changed how data is read. Block storage exposed files on a disk; object storage puts
each object — data, its metadata, and an identifier — in a flat space with no folders. It scales
massively and cheaply, but it is latency-bound: the number of get-requests, not the bandwidth,
usually sets how fast a read completes.

Formats built for that paradigm — [Zarr](https://zarr-specs.readthedocs.io/en/latest/v3/core/index.html),
[VirtualiZarr](https://github.com/zarr-developers/VirtualiZarr),
[kerchunk](https://github.com/fsspec/kerchunk), [Icechunk](https://github.com/earth-mover/icechunk) —
abstract files away, mapping chunks into dimensioned arrays that tools like Xarray and Zarrs.jl read
lazily. A virtual store does this without copying anything: it maps each Zarr chunk key to a
`(url, offset, length)` triple in the original granule and fetches it with an HTTP range request.

The roadblock is the raw data. For an archive to be virtualizable as it stands it needs consolidated
metadata, one grid, and chunks that align in space. Meet all three and a lazy datacube over the whole
archive costs nothing but the manifest.

Satellite data usually fails the third. A product can be perfectly grid-aligned and still not
chunk-aligned, because the image edges move with every pass: a swath whose length varies by orbit
puts a partial chunk in the middle of the concatenated array, and ascending and descending passes can
share a grid exactly while sharing no chunk origin. Whether that happens is a property of how the
granules were written, and the catalog does not record it — CMR publishes no chunk shapes at all. So
every deciding column here is measured by opening granule files with VirtualiZarr's own parsers,
which are what a real virtual store is built from, and a parser's refusal is itself an answer.

## What the table reports

One row per collection: sensor, product, level, format, DAAC, S3 region, then the four columns that
decide the grade — **consolidated metadata**, **grid aligned**, **chunk aligned**, and **time as a
dimension** — followed by the chunk shape and stored chunk size a user of the cube would meet,
granule count, estimated volume, whether NASA publishes a DMR++ sidecar, and the criterion that
decided the grade. `results/virtualizability.csv` carries the same rows with the underlying evidence
for each verdict in its own column.

## Grades

| | |
|---|---|
| **A** | virtualizable as is |
| **B** | virtualizable but inefficient or partial |
| **C** | virtualizable with a correctness risk |
| **D** | not virtualizable without rewriting bytes |
| **F** | the layout could not be read |
| **U** | not measured — the probe could not reach the chunk index from outside `us-west-2` |

Four granules per collection can refute stability but cannot establish it, so `D` and `F` rest on a
counterexample while `A` and `B` state that no blocker appeared in the sample. `results/report.md`
sets out that asymmetry, and the criteria, in full.

## Pipeline

| Stage | Needs network | What it does |
|---|---|---|
| `scripts/01_inventory.jl` | yes | resolves each dataset to a cloud-hosted CMR collection |
| `scripts/02_sample.jl` | yes | draws granules from both ends of the record, narrowed to one comparable series where a collection is partitioned by something other than time |
| `scripts/03_probe.py` | yes | opens every sampled granule and records its chunk layout, grid, CF attributes, and metadata locality |
| `scripts/04_score.jl` | no | reduces the measurements to a per-criterion verdict and a grade |
| `scripts/05_report.jl` | no | renders `results/report.md` |
| `scripts/verify_endtoend.py` | yes | builds virtual stores and checks the grades against them |

`results/probe/` holds the per-granule measurements every verdict derives from, so stages 4 and 5
reproduce the report offline from this repository alone.

The criteria live in `src/criteria.jl`, one function per criterion, each stating what it requires and
what evidence settles it. `src/partitions.jl` records how each partitioned collection is narrowed to
one comparable series, and why the differences left in a sample are left there.

## Running it

Stages 1–3 and the verification read NASA's protected buckets, which reject direct S3 from outside
`us-west-2`, so access is over authenticated HTTPS with an Earthdata Login bearer token. You need
[Earthdata Login](https://urs.earthdata.nasa.gov/) credentials in `~/.netrc`; no credential is stored
in this repository.

```sh
julia --project=. -e 'import Pkg; Pkg.instantiate()'
python -m venv .venv && .venv/bin/pip install -r requirements.txt

julia --project=. scripts/01_inventory.jl
julia --project=. scripts/02_sample.jl
.venv/bin/python scripts/03_probe.py          # hours: every request pays a login redirect
julia --project=. scripts/04_score.jl
julia --project=. scripts/05_report.jl
```

Stages 2 and 3 take a list of collection short names to redo only those, merging into the existing
sample and artifacts.

## Tooling

VirtualiZarr 2.7.3, obstore 0.11.1, Zarr v3, Icechunk 2.2.2; `requirements.txt` pins the rest.
VirtualiZarr's HDF5, DMR++, and Zarr parsers are native; its HDF4 and netCDF-3 parsers delegate to
kerchunk, and which of NASA's HDF-EOS2 holdings those accept varies by producer, so it is measured
per collection rather than inferred from the format field. VirtualiZarr 2.7.3 ships no TIFF parser,
so GeoTIFF tile offsets are read from `TileOffsets` and `TileByteCounts` directly.

The Julia dependency `EarthData` resolves from a public fork pinned to the commit the recorded
results were produced with; the registered release does not export everything stages 1 and 2 use.

One VirtualiZarr defect is corrected before probing, in `scripts/vz_shims.py`, so that a grade
describes the archive rather than the reader. `results/report.md` explains which, and which remaining
reader failures are left in place because no correction is available that does not risk a wrong
answer.
