# Verification

Every check below builds or reads a real virtual store over NASA granules; none rest on catalog metadata.

## 1. Positive control — `AVHRR_OI-NCEI-L4-GLOB-v2.1`, graded A

Variable `analysed_sst`: shape [1, 720, 1440], chunks [1, 720, 1440], codecs ['BytesCodec', 'Shuffle', 'Zlib'].

Combining 4 granules:

- `20160101120000-NCEI-L4_GHRSST-SSTblend-AVHRR_OI-GLOB-v02.0-fv02.1.nc`
- `20160102120000-NCEI-L4_GHRSST-SSTblend-AVHRR_OI-GLOB-v02.0-fv02.1.nc`
- `20260920120000-NCEI-L4_GHRSST-SSTblend-AVHRR_OI-GLOB-v02.0-fv02.1.nc`
- `20260921120000-NCEI-L4_GHRSST-SSTblend-AVHRR_OI-GLOB-v02.0-fv02.1.nc`

Combined virtual dataset on `time`: dims {'lat': 720, 'nv': 2, 'lon': 1440, 'time': 4}, 18 chunk references, 9248 bytes of manifest.

Read back through the manifest as `analysed_sst`: shape (4, 720, 1440), chunks (1, 720, 1440).

Index `[0]` ↦ `20160101120000-NCEI-L4_GHRSST-SSTblend-AVHRR_OI-GLOB-v02.0-fv02.1.nc`, slice (slice(358, 362, None), slice(718, 722, None)): **identical**
```
via manifest : [2904 2899 2907 2899 2913 2916]
via h5py     : [2904 2899 2907 2899 2913 2916]
```
Index `[3]` ↦ `20260921120000-NCEI-L4_GHRSST-SSTblend-AVHRR_OI-GLOB-v02.0-fv02.1.nc`, slice (slice(358, 362, None), slice(718, 722, None)): **identical**
```
via manifest : [2595 2602 2605 2602 2618 2626]
via h5py     : [2595 2602 2605 2602 2618 2626]
```

**Positive control passes** — the combined cube serves the archival bytes unchanged.

## 2. Icechunk round-trip

Virtual chunk container `https://archive.podaac.earthdata.nasa.gov/` carrying the Earthdata Login token; committed snapshot `8KW7XGGSSJY24HCAXK2G`.
Reopened: dims {'time': 4, 'lat': 720, 'lon': 1440, 'nv': 2}, 6 data variables.

Slice (slice(358, 362, None), slice(718, 722, None)) of index `[0]` read out of the repository: **identical to the source granule**
```
via icechunk : [2904 2899 2907 2899 2913 2916]
via h5py     : [2904 2899 2907 2899 2913 2916]
```

So an Icechunk repository can serve a NASA archive it does not hold: the chunk manifest and metadata are the only bytes stored locally, and each read resolves to a range request against the original granule. The token belongs on the container's store configuration — `Credentials.HttpAccess` takes no arguments and cannot carry one.

## 3. Hand-checked chunk

`analysed_sst`, chunk `0.0.0`: offset 79777, length 676986.
Declared chunk shape (1, 720, 1440), dtype `int16`, codecs ['BytesCodec', 'Shuffle', 'Zlib'].

Fetched 676986 bytes; decoded to 2073600; the declared chunk shape implies 2073600. **match**

```
first values: [-32768 -32768 -32768 -32768 -32768 -32768]
```

## 4. Negative control — H3, interior partial chunk

`GPM_2ADPR` is graded D.

> H3: interior partial chunk on concatenation (274 of 274 variables) — FS/PRE/zFactorMeasured dim 1: size 7925 not a multiple of chunk 15

`FS/PRE/zFactorMeasured` has chunks [15, 49, 176, 2] and shapes [(7925, 49, 176, 2), (7989, 49, 176, 2), (7990, 49, 176, 2)] — dimension 0 (`nscan`) varies. Combining along it should fail.

Opening group `FS/PRE`, since a parser presents one group at a time and this product's arrays are nested.

Combination failed:

```
ValueError: Cannot concatenate arrays with partial chunks because only regular chunk grids are currently supported. Concat input 0 has array length 7925 along the concatenation axis which is not evenly divisible by chunk length 5000.
```

The refusal names the obstruction H3 predicts (“not evenly divisible”), so the criterion and the tool agree on the cause, not merely the outcome.

## 5. Negative control — H2, chunk shape differs across granules

`MODISA_L3m_CHL` is graded D.

> H2: chunk shape differs across granules (1 of 2 variables — chlor_a: [44, 87] vs [16, 1024])

These two granules agree on the shape of every variable they share, so chunk shape is the only difference between them. `chlor_a` has shape (4320, 8640) in both, chunked (44, 87) in one and (16, 1024) in the other.

- `AQUA_MODIS.20020704.L3m.DAY.CHL.chlor_a.4km.nc`
- `AQUA_MODIS.20260529.L3m.DAY.CHL.chlor_a.4km.nc`

Combination failed:

```
ValueError: Cannot concatenate arrays with inconsistent chunk shapes: (1, 16, 1024) vs (1, 44, 87) .Requires ZEP003 (Variable-length Chunks).
```

The refusal names the obstruction H2 predicts (“inconsistent chunk shapes”), so the criterion and the tool agree on the cause, not merely the outcome.

## 6. Catalog cross-check

`CMR-Hits` read directly and `earthaccess` counting the same query, both now. `inventory.csv` was written 2026-09-22T10:47, and an archive still ingesting grows between then and now, so its stored count is reported as drift rather than as a disagreement.

| Product | Version | CMR-Hits | earthaccess | Agree | Recorded | Drift since |
|---|---|---|---|---|---|---|
| ATL06 | 007 | 438157 | 438157 | yes | 438157 | +0 |
| MUR-JPL-L4-GLOB-v4.1 | 4.1 | 8878 | 8878 | yes | 8878 | +0 |
| HLSL30 | 2.0 | 16032812 | 16032812 | yes | 16032812 | +0 |

