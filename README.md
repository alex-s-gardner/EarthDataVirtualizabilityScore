# EarthDataVirtualizabilityScore

86 NASA Earthdata collections graded on whether their archives can be read as lazy, cloud-native
datacubes **without duplicating a single byte**. Every grade is measured by opening granule files,
not read from the catalog.

## Why virtualization matters

Most Earth observation data still reaches an analyst as files. You search a catalog, resolve the
query to a list of granules, download them or ask a service to subset them, and reassemble them
locally into the array you wanted in the first place. Every one of those steps needs a server, and
the server sets the limit: it meters throughput, it goes down, and it stands between the user and
bytes that already sit in a cloud object store.

Virtualization removes the steps without moving the data. Formats built for object storage —
[Zarr](https://zarr-specs.readthedocs.io/en/latest/v3/core/index.html) and the tools that write
virtual stores over files that already exist,
[VirtualiZarr](https://github.com/zarr-developers/VirtualiZarr),
[kerchunk](https://github.com/fsspec/kerchunk),
[Icechunk](https://github.com/earth-mover/icechunk) — present an archive as one dimensioned array,
indexed by longitude, latitude, time, and band. A virtual store holds no data at all: it maps each
chunk of that array to a `(url, offset, length)` triple inside an original granule and fetches it
with one HTTP range request. Nothing is copied and nothing is rewritten. The files stay exactly as
they are, and a client — Xarray, Zarrs.jl, anything that speaks Zarr — opens the whole archive as
a single lazy array.

For whoever uses the data, that changes four things:

- **The file disappears.** No granule lists, no filename conventions, no mosaicking. A query is a
  slice: this box, these dates, this variable.
- **Reads are lazy and dimensioned.** A 30-year time series at one point costs a handful of range
  requests, not a download of 30 years of global grids.
- **No server in the middle.** The client reads the object store directly, so access scales with
  the object store rather than with a service's capacity, and there is no service to fund or
  operate.
- **One manifest, not a second copy.** A chunk manifest holds tens of bytes per chunk of data it
  describes, so virtualizing an archive costs the manifest and nothing else.

None of this is available by default, because virtualizability is decided at write time. A virtual
store can only describe an array the bytes already form: one chunk shape per variable, granules
that tile one grid, chunk boundaries that line up when granules are stacked, time declared as a
dimension. Those requirements are not demanding, and no amount of catalog metadata can supply them
afterward — a chunk shape, a grid origin, and a fill value are chosen once, inside a production
system, and they decide whether every future user of the product needs a server or none.

The requirement missed most often is chunk alignment, which is not the same as grid alignment: a
product can sit perfectly on a common grid and still not be chunk-aligned, because the image edges
move with every pass. A swath whose length varies by orbit puts a partial chunk in the middle of
the concatenated array, and ascending and descending passes can share a grid exactly while sharing
no chunk origin.

This benchmark measures which of NASA's major archives clear that bar as they stand, and names the
byte-level property that stops the rest.

## Method

Virtualizability is a property of how an archive's granules were written, not of its catalog
record. CMR publishes no chunk shapes, and its gridded-resolution field is absent for most of these
collections, so the deciding columns cannot come from metadata.

Every column below except format, DAAC, region, granule count, and level is therefore measured by
opening granule files with VirtualiZarr's own parsers, which are what a real virtual store is built
from — and a parser's refusal is itself a measurement, since the exception names the feature that
stops a chunk manifest being written. The two collections whose CMR format field names a container
no VirtualiZarr parser reads — `ASCII` and `HGT` — are checked against the granule's own first
bytes before that field is acted on, so a format ruled out here is ruled out on what the file is
rather than on what the catalog calls it.

Each collection is sampled at both ends of its record, narrowed first to one series of granules a
single cube would actually hold. Each criterion below is then evaluated per collection and reduced
to a verdict with the evidence that settled it. The grade follows the order a user hits them in: no
parser reads the format, then bytes that would have to be rewritten, then a risk that reads without
error and returns wrong values, then what a read costs. Each criterion states what it requires
and what evidence settles it; `results/virtualizability.csv` carries every verdict with its evidence
in its own column, and `results/probe/` holds the per-granule measurements all of them derive from.

NASA IMPACT runs a
[companion survey](https://nasa-impact.github.io/virtual-zarr-coverage/) over the same question
with the opposite shape: it enumerates every cloud-hosted CMR collection and records how far each
granule gets through VirtualiZarr's own call sequence — parser, then `xarray.Dataset`, then
`xarray.DataTree` — classifying each failure into a taxonomy its maintainers can work through. It
covers breadth and the readers; this benchmark covers depth and the archives, measuring the
byte-level properties that decide whether granules a parser accepts can also be one array, and
ordering collections by which of those they fail. The two answer adjacent questions: theirs is
closest to "what does the tooling read today", this one to "what would a cube over the record
require".

## Ranking

The table is wider than a page. Scroll it sideways to reach the remaining columns — chunk shape and size, granule count, archive volume, DMR++ availability, and the deciding criterion, which names the measurement behind the grade.

| Grade | Sensor | Product | Level | Format | DAAC | S3 region | Consolidated md | Grid aligned | Chunk aligned | Time dim | Chunk shape | Chunk MB | Granules | Volume TB | DMR++ | Deciding criterion |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| A ⭐ | AVHRR | AVHRR_OI-NCEI-L4-GLOB-v2.1 | L4 | netCDF-4 | NASA/JPL/PODAAC | us-west-2 | yes | yes | yes | yes | 1×720×1440 | 0.668 | 3915 | 0.004 | yes | no blocker |
| A ⭐ | GLDAS (model) | GLDAS_NOAH025_3H | L4 | NetCDF | NASA/GSFC/SED/ESD/TISL/GESDISC | us-west-2 | yes | yes | yes | yes | 1×600×1440 | 0.526 | 77423 | 1.518 | yes | no blocker |
| A ⭐ | GPM/DPR+GMI | GPM_3IMERGDF | L3 | NetCDF | NASA/GSFC/SED/ESD/TISL/GESDISC | us-west-2 | yes | yes | yes | yes | 1×3600×900 | 3.136 | 10135 | 0.307 | yes | no blocker |
| A ⭐ | GPM/DPR+GMI | GPM_3IMERGHH | L3 | HDF5 | NASA/GSFC/SED/ESD/TISL/GESDISC | us-west-2 | partial | yes | yes | yes | 1×145×1800 | 0.052 | 486480 | 3.851 | yes | no blocker |
| A ⭐ | GRACE | TELLUS_GRAC_L3_JPL_RL06_LND_v04 | L3 | netCDF-4 | NASA/JPL/PODAAC | us-west-2 | yes | yes | yes | yes | 1×180×360 | 0.518 | 163 | 0.0 | yes | no blocker |
| A ⭐ | GRACE-FO | TELLUS_GRFO_L3_JPL_RL06.3_LND_v04 | L3 | netCDF-4 | NASA/JPL/PODAAC | us-west-2 | yes | yes | yes | yes | 1×180×360 | 0.518 | 96 | 0.0 | yes | no blocker |
| A ⭐ | NLDAS (model) | NLDAS_FORA0125_H | L4 | NetCDF | NASA/GSFC/SED/ESD/TISL/GESDISC | us-west-2 | yes | yes | yes | yes | 1×224×464 | 0.111 | 418272 | 0.742 | yes | no blocker |
| A ⭐ | multi-sensor (OSTIA) | OSTIA-UKMO-L4-GLOB-REP-v2.0 | L4 | netCDF-4 | NASA/JPL/PODAAC | us-west-2 | yes | yes | yes | yes | 1×1200×2400 | 1.171 | 15340 | 0.246 | yes | no blocker |
| B | CERES | CERES_EBAF-TOA | L4 | netCDF-3 | NASA/LARC/SD/ASDC | us-west-2 | — | yes | yes | yes | 1×180×360 | 0.259 | 2 | 0.002 | no | P-md: not measured (parser bypasses the instrumented reader) |
| B | GCOM-W1/AMSR2 | AU_SI12 | L3 | ASCII+HDF-EOS5 | NASA NSIDC DAAC | us-west-2 | partial | yes | yes | no | 896×608 | 2.179 | 8177 | 1.079 | no | T: no time dimension |
| B | ICESat-2/ATLAS | ATL14 | L3 | netCDF-4 | NASA NSIDC DAAC | us-west-2 | no | — | — | no | 2491×1401 | 0.859 | 6 | 0.009 | no | H2: no data array appears in two opened granules; H3: no data array appears in two opened granules; H4: no data array appears in two opened granules; H5: no data array appears in two opened granules; V: fewer than two granules opened; G: coordinates read for one granule only, so no cross-granule comparison — measured tile_stats/x/tile_stats/y/x/y on 1 granules; step 40000.0; T: no time dimension; P-md: median 15 blocks in 13 runs, 27% leading |
| B | ICESat-2/ATLAS | ATL15 | L3 | netCDF-4 | NASA NSIDC DAAC | us-west-2 | partial | — | — | yes | 88×136×76 | 1.186 | 48 | 0.001 | no | H2: no data array appears in two opened granules; H3: no data array appears in two opened granules; H4: no data array appears in two opened granules; H5: no data array appears in two opened granules; V: fewer than two granules opened; G: coordinates read for one granule only, so no cross-granule comparison — measured delta_h/x/delta_h/y/tile_stats/x/tile_stats/y on 1 granules; step 20000.0 |
| B | ISS/ECOSTRESS | ECO_L2T_LSTE | L2 | COG | LP DAAC | us-west-2 | yes | yes | yes | no | 512×512 | 0.002 | 3936594 | 7.615 | no | T: file declares no dimension names; P-sz: band: median stored chunk 0.002 MB in 16 chunks — latency-bound |
| B | Landsat 8-9/OLI | HLSL30 | L3 | COG | LP DAAC | us-west-2 | yes | partial | yes | no | 256×256 | 0.08 | 16038148 | 264.726 | no | G: 2 projections across 2 tile origins (EPSG:32659, ProjectionGeoKey:16059) — one grid per tile, each internally on a 30 m lattice; T: file declares no dimension names |
| B | NISAR/L-SAR | NISAR_L2_GCOV_PROVISIONAL_V1 | L2 | CSV+HDF5+KML+PDF+PNG+XML+YAML | ASF | us-west-2 | partial | yes | yes | partial | 512×512 | 0.632 | 120883 | 865.99 | no | T: time variable "science/lsar/gcov/metadata/attitude/time" but no time dimension |
| B | NISAR/L-SAR | NISAR_L2_GSLC_PROVISIONAL_V1 | L2 | CSV+HDF5+KML+PDF+PNG+XML+YAML | ASF | us-west-2 | partial | yes | yes | partial | 512×512 | 1.002 | 120004 | 2705.668 | no | T: time variable "science/lsar/gslc/metadata/attitude/time" but no time dimension |
| B | NISAR/L-SAR | NISAR_L2_GUNW_PROVISIONAL_V1 | L2 | CSV+HDF5+KML+PDF+PNG+XML+YAML | ASF | us-west-2 | partial | yes | yes | partial | 512×512 | 0.009 | 67026 | 90.382 | no | T: time variable "science/lsar/gunw/metadata/attitude/reference/time" but no time dimension; P-sz: science/LSAR/GUNW/grids/frequencyA/wrappedInterferogram/HH/wrappedInterferogram: median stored chunk 0.009 MB in 1056 chunks — latency-bound |
| B | NISAR/L-SAR | NISAR_L3_SME2_PROVISIONAL_V1 | L3 | HDF5+XML+YAML | ASF | us-west-2 | yes | yes | yes | no | 512×512 | 0.007 | 77089 | 9.943 | no | V: 16 of 43 data arrays are absent from at least one of the 8 granules opened — science/LSAR/SME2/grids/algorithmCandidates/PMI/dielectricConstant appears in 5, while science/LSAR/SME2/grids/algorithmCandidates/DSG/algorithmParameterBeta spans the sample, so a cube over it is available; T: no time dimension; P-sz: science/LSAR/SME2/grids/algorithmCandidates/DSG/algorithmParameterBeta: median stored chunk 0.007 MB in 16 chunks — latency-bound |
| B | NOAA-20/VIIRS | VJ102MOD | L1B | NetCDF-4 | NASA/GSFC/SED/ESD/HBSL/BISB/LAADS | us-west-2 | no | no | — | partial | 16×3200 | 0.033 | 759981 | 51.246 | no | H2: chunk shape differs for smaller variables (2 of 63 variables — number_of_lines: [3232] vs [3216]); observation_data/M13 is stable, so a cube over it is available; V: 26 of 63 data arrays are absent from at least one of the 8 granules opened — observation_data/M01 appears in 3, while observation_data/M13 spans the sample, so a cube over it is available; T: time variable "scan_line_attributes/ev_mid_time" but no time dimension; P-md: median 36 blocks in 18 runs, 8% leading; P-sz: observation_data/M13: median stored chunk 0.033 MB in 202 chunks — latency-bound |
| B | PACE/OCI | PACE_OCI_L3M_BGC | L3 | netCDF-4 | NASA/GSFC/SED/ESD/GCDC/OB.DAAC | us-west-2 | partial | yes | yes | no | 16×1024 | 0.003 | 2000 | 0.083 | no | T: no time dimension; P-sz: carbon_phyto: median stored chunk 0.003 MB in 2430 chunks — latency-bound |
| B | SMAP/L-band radiometer | SMAP_JPL_L3_SSS_CAP_MONTHLY_V5 | L3 | netCDF-4 | NASA/JPL/PODAAC | us-west-2 | partial | yes | yes | partial | 720×1440 | 1.145 | 135 | 0.002 | yes | T: "time" is a time coordinate, but no data array is laid out on it, so a time axis has to be added when the store is built |
| B | SMAP/L-band radiometer | SPL3SMP | L3 | HDF5 | NASA NSIDC DAAC | us-west-2 | partial | — | — | partial | 1×964×3 | 0.001 | 4109 | 0.134 | yes | G: no projection attribute or spatial coordinate array reached the probe, so the grid is unmeasured, not absent; T: time variable "soil_moisture_retrieval_data_am/tb_time_seconds" but no time dimension; P-sz: Soil_Moisture_Retrieval_Data_AM/landcover_class_fraction: median stored chunk 0.001 MB in 406 chunks — latency-bound |
| B | SMAP/L-band radiometer | SPL4CMDL | L4 | HDF5 | NASA NSIDC DAAC | us-west-2 | no | yes | yes | no | 162×385 | 0.006 | 4186 | 0.593 | yes | T: no time dimension; P-md: median 82 blocks in 28 runs, 2% leading; P-sz: EC/emult_mean: median stored chunk 0.006 MB in 121 chunks — latency-bound |
| B | SMAP/L-band radiometer | SPL4SMGP | L4 | HDF5 | NASA NSIDC DAAC | us-west-2 | no | yes | yes | partial | 1624×3856 | 1.648 | 33536 | 5.016 | yes | T: time variable "time" but no time dimension; P-md: median 32 blocks in 28 runs, 9% leading |
| B | SWOT/KaRIn | SWOT_L2_HR_Raster_2.0 | L2 | netCDF-4 | NASA/JPL/PODAAC | us-west-2 | no | yes | yes | partial | 518×518 | 0.281 | 1556453 | 78.075 | no | T: time variable "illumination_time" but no time dimension; P-md: median 32 blocks in 16 runs, 3% leading |
| B | Sentinel-1/C-SAR (OPERA) | OPERA_L2_CSLC-S1_V1 | L2 | HDF5+XML | ASF | us-west-2 | no | no | — | partial | 128×128 | 0.0 | 8533508 | 2111.416 | no | T: time variable "identification/processing_date_time" but no time dimension; P-md: median 143 blocks in 56 runs, 5% leading; P-sz: data/VV: median stored chunk 0.0 MB in 5890 chunks — latency-bound |
| B | Sentinel-1/C-SAR (OPERA) | OPERA_L2_RTC-S1_V1 | L2 | GeoTIFF+HDF5+XML | ASF | us-west-2 | yes | yes | yes | no | 512×512 | 0.044 | 74659040 | 510.688 | no | T: file declares no dimension names; P-sz: band: median stored chunk 0.044 MB in 28 chunks — latency-bound |
| B | Sentinel-1/C-SAR (OPERA) | OPERA_L3_DSWX-HLS_V1 | L3 | COG | NASA/JPL/PODAAC | us-west-2 | yes | yes | yes | no | 512×512 | 0.001 | 20931984 | 3.96 | no | T: file declares no dimension names; P-sz: band: median stored chunk 0.001 MB in 64 chunks — latency-bound |
| B | Sentinel-2/MSI | HLSS30 | L3 | COG | LP DAAC | us-west-2 | yes | yes | yes | no | 256×256 | 0.012 | 21964203 | 122.691 | no | T: file declares no dimension names; P-sz: band: median stored chunk 0.012 MB in 225 chunks — latency-bound |
| B | Suomi-NPP/VIIRS | VNP02MOD | L1B | netCDF-4 | NASA/GSFC/SED/ESD/HBSL/BISB/LAADS | us-west-2 | no | no | — | partial | 16×3200 | 0.037 | 1267267 | 82.888 | no | H2: chunk shape differs for smaller variables (2 of 42 variables — number_of_lines: [3248] vs [3232]); observation_data/M13 is stable, so a cube over it is available; V: 5 of 42 data arrays are absent from at least one of the 8 granules opened — number_of_M13_LUT_values appears in 5, while observation_data/M13 spans the sample, so a cube over it is available; T: time variable "scan_line_attributes/ev_mid_time" but no time dimension; P-md: median 36 blocks in 16 runs, 8% leading; P-sz: observation_data/M13: median stored chunk 0.037 MB in 202 chunks — latency-bound |
| B | TEMPO | TEMPO_HCHO_L3 | L3 | netCDF-4 | NASA/LARC/SD/ASDC | us-west-2 | no | yes | yes | yes | 1×738×1938 | 0.949 | 17078 | 6.896 | yes | P-md: median 30 blocks in 27 runs, 7% leading |
| B | TEMPO | TEMPO_NO2_L3 | L3 | netCDF-4 | NASA/LARC/SD/ASDC | us-west-2 | no | yes | yes | yes | 1×738×1938 | 0.52 | 17080 | 12.22 | yes | P-md: median 51 blocks in 46 runs, 4% leading |
| B | Terra+Aqua/MODIS | MCD12Q1 | L3 | HDF-EOS2 | LP DAAC | us-west-2 | — | — | — | no | 2400×2400 | 0.752 | 7560 | 0.102 | yes | H2: one chunk shape per variable across 13 variables in 8 granules, but each granule is one chunk spanning its whole array, which pins the cube's chunk shape to these exact dimensions, and the grid went unmeasured, so whether every granule carries these dimensions is unestablished rather than observed; P-md: not measured (parser bypasses the instrumented reader); G: no projection attribute or spatial coordinate array reached the probe, so the grid is unmeasured, not absent; T: no time dimension |
| B | Terra+Aqua/MODIS | MCD43A3 | L3 | HDF-EOS2 | LP DAAC | us-west-2 | — | — | — | no | 100×2400 | 0.209 | 2981668 | 290.696 | no | P-md: not measured (parser bypasses the instrumented reader); G: no projection attribute or spatial coordinate array reached the probe, so the grid is unmeasured, not absent; T: no time dimension |
| B | Terra/ASTER | AST_L1T | L1T | COG | LP DAAC | us-west-2 | yes | no | — | no | 512×512 | 0.1 | 4866926 | 2.805 | no | T: file declares no dimension names |
| B | Terra/MODIS | MOD021KM | L1B | NetCDF-4 | NASA/GSFC/SED/ESD/HBSL/BISB/LAADS | us-west-2 | partial | no | — | no | 6×2030×1354 | 19.592 | 2757062 | 273.44 | no | T: no time dimension |
| B | Terra/MODIS | MOD10A1 | L3 | HDF-EOS2 | NASA NSIDC DAAC | us-west-2 | — | — | — | no | 2400×2400 | — | 2927249 | 20.635 | no | H2: one chunk shape per variable across 7 variables in 8 granules, but each granule is one chunk spanning its whole array, which pins the cube's chunk shape to these exact dimensions, and the grid went unmeasured, so whether every granule carries these dimensions is unestablished rather than observed; P-sz: NDSI: no stored chunk length the format could produce, so the parser did not record one; P-md: not measured (parser bypasses the instrumented reader); G: no projection attribute or spatial coordinate array reached the probe, so the grid is unmeasured, not absent; T: no time dimension |
| B | Terra/MODIS | MOD11A1 | L3 | HDF-EOS2 | LP DAAC | us-west-2 | — | — | — | no | 1200×1200 | 0.845 | 3044695 | 16.722 | yes | H2: one chunk shape per variable across 12 variables in 8 granules, but each granule is one chunk spanning its whole array, which pins the cube's chunk shape to these exact dimensions, and the grid went unmeasured, so whether every granule carries these dimensions is unestablished rather than observed; P-md: not measured (parser bypasses the instrumented reader); G: no projection attribute or spatial coordinate array reached the probe, so the grid is unmeasured, not absent; T: "day_view_time_x" is declared by one array only, so it is a per-array name rather than a shared time dimension |
| B | Terra/MODIS | MOD13Q1 | L3 | HDF-EOS2 | LP DAAC | us-west-2 | — | — | — | no | 1×4800 | 0.006 | 177776 | 39.126 | yes | P-md: not measured (parser bypasses the instrumented reader); G: no projection attribute or spatial coordinate array reached the probe, so the grid is unmeasured, not absent; T: no time dimension; P-sz: 250m 16 days EVI: median stored chunk 0.006 MB in 4800 chunks — latency-bound |
| B | multi-sensor (ITS_LIVE) | NSIDC-0776 | L3 | netCDF-4 | NASA NSIDC DAAC | us-west-2 | partial | yes | yes | no | 1500×1500 | 0.199 | 546 | 0.106 | no | V: 16 of 25 data arrays are absent from at least one of the 8 granules opened — dt_max appears in 1, while count spans the sample, so a cube over it is available; T: no time dimension |
| B | multi-sensor (MUR SST) | MUR-JPL-L4-GLOB-v4.1 | L4 | netCDF-4 | NASA/JPL/PODAAC | us-west-2 | no | yes | yes | yes | 1×1023×2047 | 1.004 | 8878 | 3.268 | yes | H2: chunk shape differs for smaller variables (3 of 6 variables — dt_1km_data: [1, 1447, 2895] vs [1, 1023, 2047]); analysed_sst is stable, so a cube over it is available; V: 2 of 6 data arrays are absent from at least one of the 8 granules opened — sst_anomaly appears in 3, while analysed_sst spans the sample, so a cube over it is available; P-md: median 17 blocks in 12 runs, 6% leading; S1: units differ but no attribute that changes a decoded value does, so the cube is mislabelled rather than wrong — sea_ice_fraction.units: fraction (between 0 and 1) vs ∅ |
| B | multi-sensor (passive microwave) | NSIDC-0051 | L3 | PNG+netCDF-4 | NASA NSIDC DAAC | us-west-2 | yes | yes | yes | yes | 1×448×304 | 0.026 | 35600 | 0.003 | no | V: no data array appears in every granule, so no single array spans the sampled record — 4 of 4 data arrays are absent from at least one of the 8 granules opened — F08_ICECON appears in 1 |
| C | MERRA-2 (model) | M2T1NXSLV | L4 | NetCDF | NASA/GSFC/SED/ESD/TISL/GESDISC | us-west-2 | no | — | — | yes | 1×91×144 | 0.023 | 17015 | 7.066 | yes | S1: the time axis counts from a different epoch in different granules, so the combined axis decodes every granule against the first one's — time.units: 4 distinct epochs, minutes since 1980-01-01 00:30:00 through minutes since 2017-05-19 00:30:00 |
| D | Aqua/MODIS | MODISA_L3m_CHL | L3 | netCDF-4 | NASA/GSFC/SED/ESD/GCDC/OB.DAAC | us-west-2 | partial | yes | no | no | 44×87 | 0.0 | 27028 | 0.35 | no | H2: chunk shape differs across granules (1 of 2 variables — chlor_a: [44, 87] vs [16, 1024]) |
| D | Aura/MLS | ML2O3_NRT | L2 | HDF-EOS5 | NASA/GSFC/SED/ESD/TISL/GESDISC | us-west-2 | yes | no | no | yes | 43×55 | 0.0 | 630 | 0.0 | yes | H2: chunk shape differs across granules (28 of 32 variables — HDFEOS/SWATHS/O3/Data Fields/L2gpPrecision: [43, 55] vs [42, 55]) |
| D | Aura/OMI | OMDOAO3 | L2 | netCDF-4 | NASA/GSFC/SED/ESD/TISL/GESDISC | us-west-2 | yes | no | no | yes | 1×1644×60 | 0.229 | 113361 | 1.137 | yes | H2: chunk shape differs across granules (52 of 57 variables — PRODUCT/SUPPORT_DATA/DETAILED_RESULTS/air_mass_factor: [1, 1644, 60] vs [1, 1494, 60] vs [1, 1643, 60] vs [1, 1626, 60]) |
| D | CERES | CERES_EBAF | L4 | netCDF-4 | NASA/LARC/SD/ASDC | us-west-2 | no | yes | no | yes | 104×60×120 | 1.432 | 3 | 0.006 | yes | H2: chunk shape differs across granules (123 of 248 variables — cldarea_total_daynight_mon: [104, 60, 120] vs [105, 60, 120]) |
| D | CYGNSS | CYGNSS_NOAA_L2_SWSP_25KM_V1.2 | L2 | netCDF-4 | NASA/JPL/PODAAC | us-west-2 | partial | no | no | partial | 64258×9 | 0.003 | 3387 | 0.039 | yes | H2: chunk shape differs across granules (26 of 26 variables — ddm_channel: [64258, 9] vs [78675, 9] vs [102937, 7] vs [96456, 9] vs [77326, 9] vs [94166, 13] vs [85561, 13] vs [86024, 13]) |
| D | Daymet (model) | Daymet_Daily_V4R1_2129 | L4 | netCDF-4 | ORNL_DAAC | us-west-2 | yes | yes | yes | yes | 1×231×364 | 0.023 | 1176 | 0.011 | yes | H5: codec chain differs across granules (1 of 1 variables — tmin: BytesCodec+Zlib vs BytesCodec+Shuffle+Zlib) |
| D | GPM/DPR | GPM_2ADPR | L2 | NetCDF | NASA/GSFC/SED/ESD/TISL/GESDISC | us-west-2 | no | no | no | no | 15×49×176×2 | 0.483 | 70448 | 26.825 | yes | H3: interior partial chunk on concatenation (274 of 274 variables) — FS/PRE/zFactorMeasured dim 1: size 7925 not a multiple of chunk 15 |
| D | ICESat-2/ATLAS | ATL03 | L2A | HDF5 | NASA NSIDC DAAC | us-west-2 | yes | no | no | yes | 100000 | 0.413 | 583529 | 442.997 | yes | H3: interior partial chunk on concatenation (560 of 1007 variables) — gt1l/heights/lat_ph dim 1: size 9287489 not a multiple of chunk 100000 |
| D | ICESat-2/ATLAS | ATL06 | L3 | HDF5 | NASA NSIDC DAAC | us-west-2 | yes | — | no | yes | 10000×748 | 0.445 | 438157 | 25.729 | yes | H3: interior partial chunk on concatenation (488 of 551 variables) — gt1l/residual_histogram/count dim 1: size 213 not a multiple of chunk 10000 |
| D | ICESat-2/ATLAS | ATL08 | L3 | HDF5 | NASA NSIDC DAAC | us-west-2 | yes | no | no | yes | 100000 | 0.006 | 430404 | 23.468 | yes | H3: interior partial chunk on concatenation (567 of 705 variables) — gt1l/signal_photons/classed_pc_indx dim 1: size 9048 not a multiple of chunk 100000 |
| D | ISS/EMIT | EMITL1BRAD | L1B | netCDF-4 | LP DAAC | us-west-2 | partial | no | no | no | 1280×1242×11 | 69.949 | 12208 | 1.327 | yes | H2: chunk shape differs across granules (4 of 4 variables — obs: [1280, 1242, 11] vs [1952, 1242, 11]) |
| D | ISS/EMIT | EMITL2ARFL | L2A | netCDF-4 | LP DAAC | us-west-2 | partial | no | no | no | 1280×1242×285 | 1812.326 | 11155 | 20.933 | yes | H2: chunk shape differs across granules (6 of 8 variables — reflectance: [1280, 1242, 285] vs [1952, 1242, 285]) |
| D | ISS/GEDI | GEDI02_A | L2A | HDF5 | LP DAAC | us-west-2 | no | no | no | partial | 3012×4 | 0.003 | 96864 | 68.192 | no | H2: chunk shape differs across granules (2512 of 3368 variables — BEAM0011/rh: [3012, 4] vs [2141, 7] vs [5231, 4] vs [1417, 7] vs [1349, 7] vs [1532, 7] vs [2535, 4]) |
| D | ISS/GEDI | GEDI02_B | L2B | HDF5 | LP DAAC | us-west-2 | partial | no | no | partial | 128×101 | 0.002 | 96872 | 24.114 | no | H3: interior partial chunk on concatenation (112 of 1664 variables) — BEAM0101/rch dim 1: size 14025 not a multiple of chunk 128 |
| D | MetOp-A/ASCAT | ASCATA-L2-Coastal | L2 | netCDF-4 | NASA/JPL/PODAAC | us-west-2 | yes | no | no | partial | 3251×82 | 0.259 | 57983 | 0.195 | yes | H2: chunk shape differs across granules (9 of 9 variables — bs_distance: [3251, 82] vs [3258, 82] vs [3163, 82] vs [3264, 82] vs [3168, 82]) |
| D | NISAR/L-SAR | NISAR_L1_RSLC_PROVISIONAL_V1 | L1 | CSV+HDF5+KML+PDF+PNG+XML+YAML | ASF | us-west-2 | yes | no | no | partial | 512×512 | 0.989 | 122304 | 3230.236 | no | H3: granule extents differ on two or more axes (6 of 11 variables), so the granules are different regions rather than slices of one array — science/LSAR/RSLC/swaths/frequencyA/HH: 36480×52783 vs 53200×52968 vs 54720×52969 vs 54720×52967 vs 54720×52975 vs 54720×52968 vs 54720×52970 |
| D | OCO-2 | OCO2_L2_Lite_FP | L2 | NetCDF | NASA/GSFC/SED/ESD/TISL/GESDISC | us-west-2 | partial | no | no | partial | 73270×10 | 0.939 | 921 | 0.054 | yes | H2: chunk shape differs across granules (121 of 125 variables — co2_profile_apriori: [73270, 10] vs [72502, 10] vs [81101, 10] vs [69573, 10] vs [37333, 20]) |
| D | PACE/OCI | PACE_OCI_L2_AOP | L2 | netCDF-4 | NASA/GSFC/SED/ESD/GCDC/OB.DAAC | us-west-2 | no | no | no | partial | 32×256×40 | 0.001 | 120491 | 5.894 | no | H2: chunk shape differs across granules (20 of 31 variables — geophysical_data/Rrs: [32, 256, 40] vs [29, 256, 40]) |
| D | SMAP/L-band radiometer | SPL2SMP_E | L2 | HDF5 | NASA NSIDC DAAC | us-west-2 | partial | no | no | partial | 269166 | 1.241 | 120110 | 3.178 | no | H2: chunk shape differs across granules (92 of 92 variables — Soil_Moisture_Retrieval_Data/tb_time_seconds: [269166] vs [268969] vs [267807] vs [267703] vs [266832] vs [267498] vs [267069] vs [254897]) |
| D | SWOT/KaRIn | SWOT_L2_HR_PIXC_2.0 | L2 | netCDF-4 | NASA/JPL/PODAAC | us-west-2 | partial | no | no | partial | 402169 | 0.005 | 2996378 | 107.599 | yes | H2: chunk shape differs across granules (83 of 83 variables — pixel_cloud/illumination_time: [402169] vs [410854] vs [417002] vs [384517] vs [386222]) |
| D | SWOT/KaRIn | SWOT_L2_LR_SSH_2.0 | L2 | netCDF-4 | NASA/JPL/PODAAC | us-west-2 | partial | no | no | partial | 9865×69 | 0.931 | 90959 | 0.936 | yes | H2: chunk shape differs across granules (23 of 23 variables — geoid: [9865, 69] vs [9866, 69]) |
| D | Sentinel-6/Poseidon-4 | JASON_CS_S6A_L3_ALT_LR_OST_NTC_G01 | L3 | netCDF-4 | NASA/JPL/PODAAC | us-west-2 | yes | no | no | yes | 47530 | 0.0 | 861 | 0.0 | yes | H2: chunk shape differs across granules (9 of 9 variables — cycle: [47530] vs [48175] vs [48958] vs [49077] vs [50179] vs [53363]) |
| D | Suomi-NPP/OMPS | OMPS_NPP_NMTO3_L3_DAILY | L3 | HDF5 | NASA/GSFC/SED/ESD/TISL/GESDISC | us-west-2 | yes | — | — | no | 180×360 | 0.197 | 5085 | 0.013 | yes | H5: codec chain differs across granules (8 of 8 variables — ColumnAmountO3: BytesCodec vs BytesCodec+Zlib) |
| D | Suomi-NPP/VIIRS | VIIRSN_L3m_CHL | L3 | netCDF-4 | NASA/GSFC/SED/ESD/GCDC/OB.DAAC | us-west-2 | partial | yes | no | no | 44×87 | 0.0 | 13910 | 0.219 | no | H2: chunk shape differs across granules (1 of 2 variables — chlor_a: [44, 87] vs [512, 1024] vs [16, 1024]) |
| D | TEMPO | TEMPO_NO2_L2 | L2 | netCDF-4 | NASA/LARC/SD/ASDC | us-west-2 | no | no | no | partial | 123×128×72 | 0.141 | 123143 | 16.502 | yes | H2: chunk shape differs across granules (40 of 41 variables — support_data/gas_profile: [123, 128, 72] vs [128, 128, 72] vs [127, 128, 72]) |
| D | Terra/MOPITT | MOP02T | L2 | HDF-EOS5 | NASA/LARC/SD/ASDC | us-west-2 | no | no | no | yes | 500×10×10 | 0.135 | 8410 | 3.831 | yes | H3: interior partial chunk on concatenation (36 of 53 variables) — HDFEOS/SWATHS/MOP02/Data Fields/MeasurementErrorCovarianceMatrix dim 1: size 251953 not a multiple of chunk 500 |
| D | multi-sensor (OSCAR) | OSCAR_L4_OC_NRT_V2.0 | L4 | netCDF-4 | NASA/JPL/PODAAC | us-west-2 | partial | yes | no | yes | 1×720×360 | 2.074 | 2071 | 0.069 | yes | H2: chunk shape differs across granules (4 of 4 variables — u: [1, 720, 360] vs [1, 1440, 719]) |
| F\* | Aqua/AIRS | AIRS2RET | L2 | HDF-EOS | NASA/GSFC/SED/ESD/TISL/GESDISC | us-west-2 | — | — | — | — | — | — | 2072895 | — | yes | H0: parser refused all 8 granules opened: HDF4 backend cannot read the HDF-EOS2 vgroup holding the data-block references; reader gap: the file carries 152 whole-array compressed blocks, 11 contiguous blocks coded DEFLATE, and the descriptor it stopped on (SD ref 7) is not extended, so the file states that block's offset and length outright |
| F\* | Aqua/AIRS | AIRS3STD | L3 | HDF-EOS | NASA/GSFC/SED/ESD/TISL/GESDISC | us-west-2 | — | — | — | — | — | — | 8706 | — | yes | H0: parser refused all 8 granules opened: HDF4 backend cannot read the HDF-EOS2 vgroup holding the data-block references; reader gap: the file carries 400 whole-array compressed blocks, 40 contiguous blocks coded DEFLATE, and the descriptor it stopped on (SD ref 279) is not extended, so the file states that block's offset and length outright |
| F\* | Aqua/MODIS | MYD04_L2 | L2 | HDF-EOS | NASA/GSFC/SED/ESD/HBSL/BISB/LAADS | us-west-2 | — | — | — | — | — | — | 1365758 | — | no | H0: parser refused all 8 granules opened: HDF4 backend derived a dimension-name list of the wrong length for the array's rank; reader gap: the file carries 72 whole-array compressed blocks coded DEFLATE |
| F\* | Aqua/MODIS+CERES | CER_SSF1deg-Day_Aqua-MODIS | L3 | HDF4 | NASA/LARC/SD/ASDC | us-west-2 | — | — | — | — | — | — | 278 | — | no | H0: parser refused all 3 granules opened: HDF4 backend failed decoding a vgroup name as UTF-8; reader gap: the file carries 81 whole-array compressed blocks, 4 contiguous blocks coded DEFLATE |
| F\* | CERES | CER_SYN1deg-1Hour_Terra-Aqua-NOAA20 | L3 | HDF4 | NASA/LARC/SD/ASDC | us-west-2 | — | — | — | — | — | — | 9343 | — | no | H0: parser refused all 8 granules opened: HDF4 backend failed decoding a vgroup name as UTF-8; reader gap: the file carries 145 whole-array compressed blocks, 7 contiguous blocks coded DEFLATE |
| F\* | Terra/MISR | MIL2TCST | L2 | HDF-EOS2 | NASA/LARC/SD/ASDC | us-west-2 | — | no | — | no | — | — | 176026 | 13.683 | no | H0: parser accepted all 8 granules but returned a store with no arrays, so no chunk manifest can be written; reader gap: the file carries 24480 chunk byte ranges coded DEFLATE and NONE |
| F\* | Terra/MODIS | MOD09GA | L2G | HDF-EOS2 | LP DAAC | us-west-2 | — | — | — | — | — | — | 3071812 | — | no | H0: parser refused all 8 granules opened: HDF4 backend cannot read the HDF-EOS2 vgroup holding the data-block references; reader gap: the file carries 2207 chunk byte ranges, 2 contiguous blocks coded DEFLATE, and the descriptor it stopped on (SD ref 213) is not extended, so the file states that block's offset and length outright |
| F\* | Terra/MODIS | MOD35_L2 | L2 | HDF-EOS | NASA/GSFC/SED/ESD/HBSL/BISB/LAADS | us-west-2 | — | — | — | — | — | — | 2756923 | — | no | H0: parser refused all 8 granules opened: HDF4 backend derived a dimension-name list of the wrong length for the array's rank; reader gap: the file carries 9 whole-array compressed blocks coded DEFLATE |
| F | CALIPSO/CALIOP | CAL_LID_L1-Standard-V4-51 | L1B | HDF4 | NASA/LARC/SD/ASDC | us-west-2 | — | — | — | — | — | — | 162326 | — | no | H0: parser refused all 8 granules opened: HDF4 backend failed decoding a vgroup name as UTF-8; undetermined: every scientific-data element defers its blocks to a LINKED list, which this probe does not follow, so whether the blocks are addressable is unmeasured rather than ruled out |
| F | GRACE-FO | GRACEFO_L2_JPL_MONTHLY_0063 | L2 | ASCII | NASA/JPL/PODAAC | us-west-2 | — | — | — | — | — | — | 576 | — | no | H0: parser refused all 8 granules opened: no VirtualiZarr parser reads ASCII; file: the granule is text, which carries no byte offsets to index |
| F | ICESat-2/ATLAS | ATL11 | L3 | HDF5 | NASA NSIDC DAAC | us-west-2 | no | — | — | — | — | — | 8105 | — | no | H0: parser refused all 4 granules opened: file attaches several dimension scales to one axis; a Zarr array names each axis once; file: 6 of 179 arrays attach 2 dimension scales to one axis (pt1/ref_surf/poly_coeffs axis 1) |
| F | ISS/GEDI | GEDI_L4A_AGB_Density_V3_2508 | L3 | HDF5 | ORNL_DAAC | us-west-2 | no | — | — | — | — | — | 96275 | — | yes | H0: parser refused all 8 granules opened: array carries a dtype Zarr cannot express — Zarr data type resolution from object failed. Attempted to resolve a z; file: 5 of 509 arrays carry a dtype with no fixed element width, whose values live outside any chunk (ANCILLARY/model_data, ANCILLARY/pft_lut) |
| F | Shuttle/SRTM | SRTMGL1 | L3 | HGT | LP DAAC | us-west-2 | — | — | — | — | — | — | 14297 | — | no | H0: parser refused all 1 granules opened: no VirtualiZarr parser reads HGT; file: the archive's members are deflated, so no chunk boundary exists inside one to point a range request at |
| F | Suomi-NPP/VIIRS | VNP09GA | L2G | HDF-EOS5 | LP DAAC | us-west-2 | no | — | — | — | — | — | 1999495 | — | yes | H0: parser refused all 8 granules opened: file stores a string _FillValue on a numeric variable; Zarr requires a number; file: 14 of 67 arrays store a _FillValue a Zarr array cannot hold — a string on a numeric dtype on uint8 (HDFEOS/GRIDS/VIIRS_Grid_1km_2D/Data Fields/SurfReflect_QF1_1) |
| F | Suomi-NPP/VIIRS | VNP13A1 | L3 | HDF-EOS5 | LP DAAC | us-west-2 | no | — | — | — | — | — | 191413 | — | yes | H0: parser refused all 8 granules opened: file stores an array _FillValue on a numeric variable; a Zarr fill value is scalar; file: 4 of 22 arrays store a _FillValue a Zarr array cannot hold — 2 values rather than one on int16 (HDFEOS/GRIDS/VIIRS_Grid_16Day_VI_500m/Data Fields/500 m 16 days EVI) |
| U | MERRA-2 (model) | M2I3NPASM | L4 | NetCDF | NASA/GSFC/SED/ESD/TISL/GESDISC | us-west-2 | no | — | — | — | — | — | 17015 | — | yes | H0: no granule's layout was read: 1 of 8 exhausted the probe budget, 7 not attempted; nothing refused the file itself |


## Grades

- **A ⭐** — virtualizable as is: parses, one chunk shape, one data type, and one codec chain for
  every variable across granules, every granule carrying the same arrays, no interior partial
  chunk, one grid, a shared time dimension, CF attributes in agreement, and metadata locality and
  chunk size both measured and adequate.
- **B** — virtualizable but inefficient or partial: some variables carry a different chunk shape,
  data type, or codec chain while the principal one does not, so a cube over part of the product is
  available; or a variable is missing from some granules; or scattered metadata, small chunks, one
  grid per tile rather than one grid, or no in-file time dimension; or a criterion `A` requires that
  this probe could not measure.
- **C** — virtualizable with a correctness risk: an attribute a CF decoder reads disagrees across
  granules (S1), one granule's length is not a multiple of its chunk so concatenation depends on
  that granule being last in the record (H3), or only some granules parse.
- **D** — not virtualizable without rewriting bytes: the principal variable's chunk shape (H2),
  data type (H4), or codec chain (H5) differs across granules, concatenation would place a partial
  chunk in the array interior (H3), or the granules differ in extent on two or more axes and so are
  not slices of one array.
- **F\*** — the layout could not be read, and the archive is not what stopped it. Stage 6 found
  the file already carrying the byte ranges a chunk manifest is made of, under a codec Zarr can
  decode, so nothing here asks the producer for a change: the gap is in the readers.
- **F** — the layout could not be read, and the archive is where the obstruction was found: an
  encoding Zarr cannot express, a codec it has no decoder for, or one compressed stream with no
  chunk boundary inside it. A row whose diagnosis settled neither question says so in its
  deciding-criterion column rather than being read as either.
- **U** — not measured. Every sampled granule exhausted the probe's wall-clock budget, which
  bounds reads over authenticated HTTPS from outside `us-west-2` where each request pays an
  Earthdata Login redirect. That is a limit of this measurement path, not a property of the
  archive, so these collections are unranked rather than ranked last.

A `B` lists every reason the collection fell short of `A`, not the first one found: most of these
rows fall short on more than one criterion, and which of them a reader cares about depends on what
they intend to build.


## Criteria

| ID | Requirement | Why it blocks | Source |
|---|---|---|---|
| H0 | The parser must accept the file. | A refusal names an unsupported feature — an HDF5 filter, a variable-length string, a structured dtype. Nothing downstream is possible. | [VirtualiZarr releases](https://virtualizarr.readthedocs.io/en/latest/about/releases.html) |
| H1 | Every chunk of an array must decode to the same shape. | A Zarr v3 regular chunk grid has exactly one chunk shape. The `rectilinear` variable-chunk grid is a registered extension, not core, and VirtualiZarr does not implement it. | [Zarr v3 core](https://zarr-specs.readthedocs.io/en/latest/v3/core/index.html), [rectilinear extension](https://github.com/zarr-developers/zarr-extensions/tree/main/chunk-grids/rectilinear) |
| H2 | All source files must share one internal chunk shape per variable. | Two granules chunked differently cannot be one array. A granule stored as a single chunk spanning its whole array pins the cube's chunk shape to that granule's exact dimensions, so agreement across a sample establishes H2 for the archive only where the granules also sit on one measured grid; without that, agreement is reported as `partial` rather than as a pass, since a swath whose length varies by orbit satisfies it in a few granules and fails it overall. | [VirtualiZarr usage](https://virtualizarr.readthedocs.io/en/latest/how_to/usage.html) |
| H3 | Concatenating on an axis requires `size % chunk == 0` for every file but the last. | Otherwise a short chunk lands in the array interior, which H1 forbids. This is the satellite swath failure mode. | [issue #1078](https://github.com/zarr-developers/VirtualiZarr/issues/1078) |
| H4 | All source files must store each variable in one data type. | A Zarr array declares one data type for the whole array, so a variable written as packed integers in one granule and as floats in another cannot be one array however its chunks are shaped. | [Zarr v3 core](https://zarr-specs.readthedocs.io/en/latest/v3/core/index.html) |
| H5 | All source files must store each variable under one codec chain. | A Zarr array declares one codec chain and decodes every chunk with it, so chunks compressed differently cannot belong to one array. Turning compression on, or adding a shuffle filter, partway through a record splits the archive into two cubes at that point. | [Zarr v3 core](https://zarr-specs.readthedocs.io/en/latest/v3/core/index.html) |
| V | Every file should carry the same set of data arrays. | A Zarr array serves its fill value wherever no chunk is mapped, so this does not stop a store being built: it makes the cube hold a variable over part of its record and nothing over the rest. Where the product renames its measurement per platform, no single array spans the record and a user assembling the full series has to combine several. | — |
| S1 | The CF attributes a decoder reads (`scale_factor`, `add_offset`, `_FillValue`, and `units` on a time axis) must agree across files. | A mismatch is dropped silently and the first file's encoding is applied to every chunk, so the cube reads without error and returns wrong values. An attribute compares by the value a decoder would use, so an absent `scale_factor` equals a stated 1 and an absent `add_offset` equals a stated 0. On a data variable a `units` difference alone mislabels the cube without changing a value, and is reported as `partial`; on a time axis `units` carries the epoch the stored numbers count from, so a difference there moves every date the combined axis decodes to. | [issue #1004](https://github.com/zarr-developers/VirtualiZarr/issues/1004) |
| P-md | A reader should reach the whole chunk index in a few contiguous ranges. | Object-store reads are latency-bound, so scattered metadata costs one get-request per region before any data is read. Consolidated metadata is not part of Zarr v3 core; here it is a property of the **source** file. | [Zarr v3 core](https://zarr-specs.readthedocs.io/en/latest/v3/core/index.html) |
| P-sz | Reading an array should not cost one get-request per useful amount of data. | Two measurements set that cost: how many chunks the array is divided into, which fixes how many requests a full read takes, and how many bytes each stored chunk holds, which fixes whether a request is worth its latency. An array held in a handful of chunks is read in a handful of requests however well it compresses, so a small stored chunk counts against a product only where the array is also divided into many of them. | — |
| G | Granules should share one CRS, one pixel size, and a common lattice. | Different projections or a fractional origin offset mean the granules are not cells of one array, whatever their nominal resolution. Chunk alignment is positional and so depends on this: without a shared grid there is no array for the chunks to tile. | — |
| T | Time should be a dimension inside the file, shared by the data arrays. | Without one, the time coordinate has to be manufactured when the store is built rather than read. A dimension only one array declares is not a time axis the data is laid out on: it is either a time coordinate the data variables do not use, or, on the HDF4 path, a name the reader derived for that one array. | — |


## Where the blockers fall

A grade names the criterion that decided one collection. Counted the other way round, the same
verdicts say which property stops the most archives — which is the question for whoever is deciding
what to change. Every collection is counted once per criterion, so a row that fell short on four
criteria appears in four of these lines. `unsettled` is a criterion this probe could not evaluate
for that collection, most often because no granule opened.

| Criterion | Requirement | Held | Partial | Failed | Unsettled |
|---|---|---|---|---|---|
| H0 | the parser accepts the file | 70 | 0 | 15 | 1 |
| H2 | one chunk shape per variable across granules | 40 | 10 | 18 | 18 |
| H3 | no interior partial chunk on concatenation | 60 | 0 | 8 | 18 |
| H4 | one data type per variable across granules | 67 | 0 | 1 | 18 |
| H5 | one codec chain per variable across granules | 66 | 0 | 2 | 18 |
| V | every granule carries the same arrays | 59 | 8 | 1 | 18 |
| S1 | CF decoding attributes agree across granules | 63 | 2 | 3 | 18 |
| P-md | the chunk index is reachable in a few ranges | 25 | 22 | 22 | 17 |
| P-sz | a read costs few enough requests | 31 | 16 | 22 | 17 |
| G | granules share one grid | 33 | 1 | 26 | 26 |
| T | time is a dimension the data arrays share | 25 | 21 | 25 | 15 |


And by DAAC, since an archive is written by one and a grade is an instruction to whoever writes it.
`unread` counts the `F`, `F*`, and `U` rows together: no layout was read, so no criterion below H0
was reached.

| DAAC | Collections | A | B | C | D | Unread |
|---|---|---|---|---|---|---|
| LP DAAC | 16 | 0 | 8 | 0 | 4 | 4 |
| NASA/JPL/PODAAC | 15 | 4 | 4 | 0 | 6 | 1 |
| NASA NSIDC DAAC | 14 | 0 | 9 | 0 | 4 | 1 |
| NASA/GSFC/SED/ESD/TISL/GESDISC | 13 | 4 | 0 | 1 | 5 | 3 |
| NASA/LARC/SD/ASDC | 10 | 0 | 3 | 0 | 3 | 4 |
| ASF | 7 | 0 | 6 | 0 | 1 | 0 |
| NASA/GSFC/SED/ESD/HBSL/BISB/LAADS | 5 | 0 | 3 | 0 | 0 | 2 |
| NASA/GSFC/SED/ESD/GCDC/OB.DAAC | 4 | 0 | 1 | 0 | 3 | 0 |
| ORNL_DAAC | 2 | 0 | 0 | 0 | 1 | 1 |


## Writing an archive that virtualizes

Every grade in the table follows from decisions made when the granules were written, and each one
has a cheap alternative that a virtual store can describe:

- **Use one chunk shape per variable for the life of the product** (H2). A processing version that
  rechunks splits the archive into two cubes that cannot be read as one, and the change is
  invisible until someone tries to stack across it.
- **Make the granule length a multiple of the chunk length** on the axis granules stack on, or pad
  every granule to a fixed extent (H3). Variable-length swaths fail this by construction; where the
  producer also stores the whole array as one chunk, the varying length becomes a varying chunk
  shape and the collection fails H2 instead.
- **Put every granule on one grid** — one CRS, one pixel size, one lattice (G). Origins may differ
  by a whole number of cells, which is the same grid at a different extent, but not by a fraction
  of one. A product that changes projection per tile yields a cube per tile rather than one cube
  over the archive.
- **Keep the data type and the codec chain fixed for the life of the product** (H4, H5). Switching
  a variable from packed integers to floats, turning compression on, or adding a shuffle filter
  each split the archive into two cubes at the release that changed it, as surely as rechunking
  does and with nothing in the catalog to show it.
- **Keep the set of variables the same across granules** (V), and give a measurement one name for
  the life of the product rather than one name per platform. A variable some granules omit leaves
  the cube holding it over part of the record; a measurement renamed per platform leaves no array
  spanning the record at all.
- **Declare time as a dimension the data arrays are laid out on** (T), rather than a coordinate
  variable no data array uses, so a cube reads its time axis instead of manufacturing one.
- **Keep `scale_factor`, `add_offset`, and `_FillValue` identical across granules** (S1), and state
  a time axis against one epoch for the whole product rather than against each granule's own start.
  A disagreement is dropped silently and the first granule's encoding is applied to every chunk, so
  the cube reads without error and returns wrong values or wrong dates.
- **Write the chunk index contiguously**, near the front of the file (P-md), so a reader reaches all
  of it in one range request instead of one per scattered region.
- **Size chunks for a latency-bound read** (P-sz): a few MB of stored bytes each, and few enough of
  them that a full read is tens of requests rather than thousands.
- **Write a container a chunk manifest can describe** (H0, H1): HDF5, netCDF-4, COG, or Zarr
  itself. A numeric variable's `_FillValue` has to be a number, and each axis takes one dimension
  scale.

An archive that meets these is a datacube over its whole record at the cost of a manifest, without
changing a byte of what it already distributes.


## The rows nothing could be read from

No collection graded `F` or `U` lacks a cube. Each is a series of time-stamped arrays in its own
catalog record, and the grade says only that no chunk manifest can be written over the bytes as
they are distributed. The axes below come from each collection's CMR record — level, title,
granule cadence, temporal extent — rather than from a measurement, because what the grade reports
is that nothing could be read. Every collection graded `F` or `U` carries one, and stage 4 fails
if a new one arrives without it.

| Grade | Product | Format | Cube its record describes | Record |
|---|---|---|---|---|
| F\* | AIRS2RET | HDF-EOS | time × along-track scan × cross-track footprint, one granule per 6-minute retrieval | 2002-08-30 to present |
| F\* | AIRS3STD | HDF-EOS | time × latitude × longitude on a global 1° grid, daily | 2002-08-31 to present |
| F\* | MYD04_L2 | HDF-EOS | time × along-track × across-track, one granule per 5-minute swath | 2002-07-04 to present |
| F\* | CER_SSF1deg-Day_Aqua-MODIS | HDF4 | time × latitude × longitude on a global 1° grid, daily | 2002-07-01 to present |
| F\* | CER_SYN1deg-1Hour_Terra-Aqua-NOAA20 | HDF4 | time × latitude × longitude on a global 1° grid, hourly | 2000-03-01 to present |
| F\* | MIL2TCST | HDF-EOS2 | time × along-track × across-track per orbital path | 1999-12-18 to present |
| F\* | MOD09GA | HDF-EOS2 | time × y × x per sinusoidal tile, one granule per tile per day | 2000-02-24 to present |
| F\* | MOD35_L2 | HDF-EOS | time × along-track × across-track, one granule per 5-minute swath | 2000-02-24 to present |
| F | CAL_LID_L1-Standard-V4-51 | HDF4 | time × along-track profile × altitude, one granule per orbit segment | 2006-06-12 to 2023-06-30 |
| F | GRACEFO_L2_JPL_MONTHLY_0063 | ASCII | time × spherical-harmonic degree × order, monthly — the one record here with no spatial axis | 2018-05-22 to present |
| F | ATL11 | HDF5 | reference point × cycle, a land-ice height time series per region | 2019-03-29 to present |
| F | GEDI_L4A_AGB_Density_V3_2508 | HDF5 | shot × beam along one orbit, a footprint-level biomass record rather than a grid | 2019-04-04 to present |
| F | SRTMGL1 | HGT | y × x on a global 1 arc-second lattice tiled at 1°, and no time axis: the record is one 11-day mission | 2000-02-11 to 2000-02-21 |
| F | VNP09GA | HDF-EOS5 | time × y × x per sinusoidal tile, one granule per tile per day | 2012-01-17 to present |
| F | VNP13A1 | HDF-EOS5 | time × y × x per sinusoidal tile at 500 m, one 16-day composite per granule | 2012-01-17 to present |
| U | M2I3NPASM | NetCDF | time × pressure level × latitude × longitude, 3-hourly, one granule per day | 1980-01-01 to present |


Which of `F` and `F*` a row carries is settled by reading the file, not by reading the exception.
Stage 6 re-opens one granule per distinct refusal and records what the file holds at that point: an
`F*` archive was found already carrying the byte ranges a manifest is made of, under a codec Zarr
can decode, so nothing in it needs rewriting and the gap is in the readers. An `F` archive was
found holding something Zarr cannot express — a string fill value on a numeric array, several
dimension scales on one axis, a codec with no Zarr decoder, or one compressed stream with no chunk
boundary inside it. The deciding-criterion column of the ranking carries that finding per row, and
`results/diagnose/` holds the census it reduces from.

An `F*` is the cheapest row in the table to move, because moving it asks nothing of the producer.
An `F` asks for one specific change, and the finding names it. Neither is readable with the tooling
measured here, which is why both sort below `D`. And a container change alone does not make a cube:
the rewritten archive still has to meet H2 and H3 — one chunk shape per variable, and a granule
length that divides by it — which for the swath products here is an open question rather than a
formality, since it is what most of the `D` rows fail on.

The `U` rows refused nothing: they exhausted the probe's wall-clock budget, so no diagnosis
applies to them.

Where stage 6 traced a refusal to particular arrays, stage 3 re-opens the granule asking the parser
to leave exactly those out, which tests whether a user could route around the obstruction today by
excluding a few arrays. It does not work for any of the classes found here: `ATL11`'s multiply
attached dimension scales, `GEDI_L4A_AGB_Density_V3_2508`'s object dtypes, and `VNP13A1`'s array
fill values all raise the identical error with the offending arrays named in `drop_variables`,
because this VirtualiZarr builds and validates every array's metadata before the exclusion list is
applied. So the exclusion is not a workaround, and the grades stand: the refusals are properties of
the granule and this reader, not of how the call was made. For `VNP13A1` it would not have helped
regardless — the four arrays carrying the unencodable fill value are the vegetation indices the
product exists to distribute.


## Cross-referenced against the companion survey

NASA IMPACT's [virtual-zarr-coverage survey](https://nasa-impact.github.io/virtual-zarr-coverage/)
sorts a failed attempt into one of 22 failure buckets, and its maintainers add a bucket when a
recurring error turns up unclassified. Running that same classifier over the refusals recorded here
is therefore a way to state this benchmark's findings in their terms — and to say which of them
that vocabulary has no entry for yet. Of the 14 collections a reader refused here,
3 fall under `DECODE_ERROR`, and the
rest classify as `OTHER`. Refusals bounded by this probe rather than by a reader meeting the file —
its wall-clock budget, its ceiling on copying a file to disk, a request that failed in transport —
are left out: they are limits of this measurement, not classes of failure.

The classes below are what a survey at this depth adds to that taxonomy. Numbers in a message are
collapsed, so one row is one class of failure rather than one granule.

| Unnamed failure | Granules | Collections |
|---|---|---|
| KeyError: 'data' | 24 | AIRS2RET, AIRS3STD, MOD09GA |
| ValueError: `dimension_names` and `shape` need to have the same number of dimensions. | 16 | MOD35_L2, MYD04_L2 |
| ValueError: Zarr data type resolution from object failed. Attempted to resolve a zarr data type from a numpy "Ob | 8 | GEDI_L4A_AGB_Density_V3_2508 |
| ValueError: no VirtualiZarr parser reads ASCII | 8 | GRACEFO_L2_JPL_MONTHLY_0063 |
| TypeError: Failed to encode fill_value: expected int or float for dtype uintN, got str | 8 | VNP09GA |
| TypeError: Failed to encode fill_value: expected int or float for dtype intN, got list | 8 | VNP13A1 |
| ValueError: /ptN/ref_surf/poly_coeffs has N dimension scales attached to dimension #N; require exactly N | 4 | ATL11 |
| ValueError: no VirtualiZarr parser reads HGT | 1 | SRTMGL1 |


Two of those are this benchmark's own wording for a container no parser reads, which their
`NO_PARSER` bucket already covers in substance. The rest are not phrasing differences: the HDF4
vgroup and dimension-name failures, the object dtype, the two unencodable fill values, and the
multiply-attached dimension scale are the obstructions the `F` and `F*` rows rest on, and none of
them appears in a taxonomy seeded before a survey had reached NASA's HDF4-generation holdings.
Their `COMPOUND_DTYPE` and `UNDEFINED_FILL_VALUE` buckets are close to two of them, but match on
message patterns these do not produce.

`results/buckets.json` carries the per-collection labels, and the classifier itself is vendored in
`vendor/nasa_impact_taxonomy.py` under its Apache-2.0 license rather than imported, because
reaching it through the package pulls in an unpinned VirtualiZarr and this benchmark pins that
version deliberately.


## How each column was measured

**Sampling.** 619 granules across 86 collections (3 collections at 1, 2 collections at 2, 5 collections at 4, 4 collections at 5, 1 collections at 6, 2 collections at 7, 69 collections at 8). 7 of those were not opened: a collection is abandoned after its first granule exhausts the probe budget, since granules written by one producer share a chunk index layout. Granules are chosen adversarially rather than at random: the
two earliest in the record, the two latest, and four spread evenly through the interior. The ends
expose a producer changing chunk shape or CF attributes mid-mission; the interior draws expose a
change that was made and later reverted, which the two ends agree across, and a swath length that
varies by orbit rather than by era. The sample spans both orbit directions for MIL2TCST, which is where a shared projection with a different chunk origin can appear.

A sample can refute stability but cannot establish it, and the two grades are therefore not
equally strong. A `D` or `F` rests on a counterexample: one pair of granules that disagree, or
one refusal that names a feature. An `A` or `B` rests on the absence of a counterexample in at
most 8 granules out of up to tens of millions, so it states that no blocker
appeared in the sample, not that none exists. The design cuts the other way too: spanning the ends
of the record makes this the sample most likely to straddle a mid-mission format change, so a
collection graded `D` because its 2002 granules differ from its 2026 granules may virtualize
cleanly over any recent span. The grade is a property of the whole record, not of an arbitrary
subset of it.

Ordering by observation time, which is what a user slices a cube by, leaves one case it cannot
separate on its own: a reprocessing campaign rewrites granules at production time, so an archive
that carried two layouts until the campaign ran presents one recent layout on every granule
whatever its observation date, and H2, H4, H5, and S1 then agree across a record that was
heterogeneous. So every sampled granule carries the date CMR last revised it, which says whether a
sample that agrees was agreeing across production epochs or within one.
71 of the 85 samples with a recorded revision date span more than a single day of revisions, so their cross-granule agreement was tested against granules written at different times. 14 do not, and 3 of those hold the top grade — `GPM_3IMERGDF`, `GPM_3IMERGHH`, `TELLUS_GRAC_L3_JPL_RL06_LND_v04`. For those the record is uniform as it stands rather than shown to have been uniform throughout, which is the weaker of the two claims and the one that grade rests on. CMR returned no revision date for `CERES_EBAF`, whose sampled granule URs its lookup did not match.

Recording the date is not the same as sampling on it. The granules here were drawn by observation
time, and stage 2 additionally draws the oldest and newest revision in the archive — placing a
superseded layout and the current one in one sample by construction rather than by luck — but that
draw changes which granules the grades rest on, so it takes effect at the next full re-sample rather
than being backfilled onto this one.

**Access.** NASA's protected buckets reject direct S3 from outside `us-west-2`, confirmed here
with both `obstore` and `boto3` against valid DAAC credentials. Reads therefore go over
authenticated HTTPS through an `obstore` `HTTPStore` carrying an Earthdata Login bearer token,
which follows the redirect to the presigned host and drops the token there. Manifest paths hold
durable NASA HTTPS URLs rather than presigned URLs, which expire.

**Consolidated metadata.** VirtualiZarr's HDF5 reader is instrumented to log every 1 MiB block it
actually fetches. The table reports the median number of distinct blocks and how many contiguous
runs they form: one run near the front of the file means the chunk index costs a single range
request. The HDF4 and netCDF-3 parsers reach the network through kerchunk's fsspec backend rather
than the object store, so they bypass the instrumented reader and their locality reads `—`.

**Chunk size.** The stored length of a chunk comes from the manifest, which is what a get-request
would move. A recorded length is used only when the format could have produced it: DEFLATE cannot
compress by more than 1032:1, so a zlib-coded chunk whose recorded length is below the
uncompressed chunk size divided by that bound is not a chunk length, and P-sz reads `—` rather
than reporting a chunk of that size. This excludes `MOD10A1`, where the kerchunk HDF4 backend
records 16 bytes for a zlib-coded 2400×2400 chunk. Where a recorded length is plausible it is
reported as measured however small it is, and for a tiled product that number describes the
sampled tile as much as the chunking: a tile that is mostly fill compresses further than a full
one.

**Grid aligned.** For GeoTIFF, from `ModelPixelScaleTag`, `ModelTiepointTag`, and the CRS GeoKey:
one origin in one CRS means one grid, several origins on a common lattice within one CRS mean one
grid at different extents, and a fractional offset means no shared grid. Origins are compared only
within a CRS. An easting and northing mean the same thing only in the same coordinate system, and
an MGRS-tiled product carries a different UTM zone per tile, so differencing northings across
tiles would subtract coordinates that share no datum. Granules spanning several zones are reported
as one grid per tile: a cube per tile, not one cube over the archive. That separates two cases the
catalog states alike — granules that share one projection on one lattice, and granules carrying a
projection each, which `HLSL30` does across its sampled tiles. The CRS is read from `ProjectedCSTypeGeoKey`, or from
`ProjectionGeoKey` where that key is 32767 ("user-defined"), which is how HLS writes its older
granules. For HDF5 and netCDF, the spatial coordinate arrays are read through the
manifest and their origin, spacing, and length compared between granules — a regular
latitude/longitude grid carries no `grid_mapping` attribute, since CF treats it as implicit, so
the common gridded case cannot be settled from attributes. Comparing measured values also
separates two cases that a comparison of dimension sizes cannot: an origin differing by a whole
number of cells, which is the same lattice at a different extent, and an origin offset by a
fraction of a cell, which is not one grid at all. Projection attributes are used where no
coordinate array is readable. Absence of both on an L1 or L2 product is reported as swath
geometry, where geolocation is a per-pixel array and there is no grid to align. Absence of both on
a gridded product is reported as unmeasured rather than as no grid: the HDF-EOS2 path does not
surface `StructMetadata`, and a CRS held in a metadata subgroup is outside the attributes read
here, so the MODIS sinusoidal tiles and `SPL3SMP`'s EASE-Grid 2.0 are grids this probe cannot see
rather than grids that are missing. The unmeasured cell does not separate those from a product that
has no grid to find: `ATL06` is L3 in the catalog but follows a ground track, so its geolocation is
per-segment and the honest reading there is that no grid exists. Telling the two apart takes
product knowledge rather than a measurement, so the column claims neither.

**Which variables the criteria are evaluated on.** H2, H3, H4, H5, and S1 are evaluated on every
array that holds measured data and appears in at least two opened granules — not on a fixed-size
slice of the largest. Coordinate and index arrays are excluded, matched on the final path component
against a list of unambiguous names: a cube takes its coordinates from the combined index, so a
`lat` array chunked differently in two granules does not stop those granules forming a cube, and
grading on one would report a blocker where none exists. GeoTIFF overview levels are excluded as
pyramid levels rather than variables, and arrays whose dtype has no fixed width — variable-length
and structured types, whose elements do not live in the chunk — are excluded because their size
cannot be compared. `virtualizability.csv` carries `headline_var`, `n_data_vars`,
`n_comparable_vars`, and `n_universal_vars` so the set each verdict was computed over is
recoverable.

The **principal variable** is the one those verdicts turn on and the one the chunk-shape and
chunk-size columns describe: the largest array that appears in at least two opened granules. It is
not simply the largest array, because a chunk shape read from an array only one granule carries
describes something no cube contains. For `NSIDC-0051` that is the difference between `F08_ICECON`, which fewer than two of the opened granules carry, and `F13_ICECON`, which they share.

The offender count in the deciding-criterion column is therefore a count out of the whole product,
and it separates two cases the grade alone does not. Where the principal variable offends, no cube
is available over the product's principal array, which is a `D`. Where smaller variables offend
and it does not, a cube over it is available and the rest need rewriting, which
is a `B`. `GEDI02_B` is the second case: chunk shape differs for smaller variables (1472 of 1664 variables — BEAM0101/geolocation/elevation_bin0_a1: [14025] vs [14200]); BEAM0101/rch is stable, so a cube over it is available. A sample drawn from one part of the record can miss that
difference entirely, which is what the interior draws and the two ends are for.

**Data type and codec chain.** Both are read per array per granule from the chunk manifest the
parser built, and compared across granules exactly as chunk shape is. A Zarr array declares one
data type and one codec chain and applies them to every chunk, so either changing mid-record blocks
a single array as firmly as a rechunk does, and neither is visible in the catalog. These are the
quietest of the hard blockers: nothing about a granule read on its own reveals them, and they
surface only when granules from far apart in the record are compared. 1 collection (ASCATA-L2-Coastal) changes the data type of its principal variable, and 2 (Daymet_Daily_V4R1_2129, OMPS_NPP_NMTO3_L3_DAILY) change their codec chain.

**What the readers do with the store (M).** Building a chunk manifest and opening it as an
`xarray` object are separate steps, and a hierarchical granule can pass the first and fail the
second: `xarray` refuses to flatten groups whose dimensions disagree, while the same store opens as
a `DataTree`. Stage 3 records `to_virtual_dataset` and `to_virtual_datatree` separately, both with
`loadable_variables=[]` so neither reads a chunk. Of the stores built here, 61 open as a flat `Dataset`, 4 as neither, and 21 are unrecorded.

This one is deliberately not part of the grade, and the column `xarray_opens` carries it instead. It
measures the readers rather than the archive, which is the same line the `F`/`F*` split draws: a
store that holds a chunk manifest can be committed to a virtual store whatever today's `xarray`
makes of it, so a collection is not marked down here for a flattening rule that may change in the
next release. It is recorded because the distinction it draws — nothing reads this granule, against
only a flat reader cannot read it — is one a user has to know and the grade alone does not carry.

**Shared variables.** A variable absent from some granules does not stop a store being built — a
Zarr array serves its fill value wherever no chunk is mapped — so V is reported as a shortfall
rather than a blocker. It separates three cases: every granule carrying every array; a variable
added or dropped partway through the record, which leaves the cube holding it over part of the
record; and a product that renames its measurement per platform, where no array spans the record at
all and a user wanting the full series has to combine several. 8 collections are missing at least one array from at least one granule, and 1 (NSIDC-0051) shares no array across the granules sampled at all.

**Chunk aligned.** Alignment is positional, so it presupposes a grid for the chunks to be
positioned on. Two properties are measured — chunk shape identical across granules (H2), and
`size % chunk == 0` along whichever dimension varies between granules (H3), that dimension being
taken as the concatenation axis since it is the axis a user would stack on — and both are
necessary without being sufficient. Granules in different projections can agree on chunk shape
exactly while sharing no array for those chunks to fill, so this column reads `yes` only where a
grid was also established, and `—` where H2 and H3 hold but the grid did not. A failure of H2 or
H3 is reported whatever the grid, since either rules out a single array on its own. The H2 and H3
results are carried separately in `virtualizability.csv` as `chunk_shape_stable` and `concat_ok`,
so the `—` rows do not hide a measurement.

H3 is evaluated only on variables whose chunk shape is already stable, since a variable failing H2
has no single chunk grid for an alignment to be measured against. Because the criterion exempts
the last file in the record, one offending granule is consistent with that granule being last and
is reported as a risk (`C`) rather than a blocker; two or more put a short chunk in the array
interior and block concatenation (`D`). A variable whose length differs on two or more axes is not
a stack of slices at all — the granules cover different extents — and is reported as that rather
than as a partial chunk.

**Granules.** CMR's hit count for the collection, as of 2026-09-23. A collection still
ingesting has grown since; `verification.md` measures that drift for three of them.

**Volume.** Median size of the sampled object times the collection's CMR granule count — an
estimate, not a published figure. For a collection that distributes several files per granule the
sample pins one of them, so the figure covers that one asset rather than the whole granule:
`HLSL30`'s 15 bands per scene make its archive roughly an order of magnitude larger than the
column shows, and the same holds for `HLSS30`, `ECO_L2T_LSTE`, and `OPERA_L2_RTC-S1_V1`. The
column is comparable across single-file collections and a lower bound on the rest.

**DMR++.** Whether NASA publishes a `.dmrpp` sidecar beside the granule. A DMR++ is an
OPeNDAP-generated chunk manifest, so its presence means the archive already holds the byte
offsets a virtual store needs. VirtualiZarr's `DMRPPParser` returned an empty store for the
sidecars tested here, so the column records availability, not a working shortcut.

**Tooling.** virtualizarr 2.7.3, zarr 3.4.0, xarray 2026.7.0, obstore 0.11.1, kerchunk 0.2.10, numcodecs 0.17.0, icechunk 2.2.2, cftime 1.6.5, read from `requirements.txt`. A grade is a property of the
archive as this stack reads it, so which stack matters: VirtualiZarr supersedes kerchunk as the
interface, and its HDF5, DMR++, and Zarr parsers are native, while its HDF4 and netCDF-3 parsers
still delegate to kerchunk internally, so kerchunk remains a dependency for those legacy formats.
This VirtualiZarr ships no TIFF parser, so GeoTIFF tile offsets and byte counts are read directly
from `TileOffsets` and `TileByteCounts`. The `F*` rows in particular are a statement about these
versions rather than about the archives, so re-running against a later VirtualiZarr is how one is
shown to have moved.

**Which granules these numbers describe.** `results/granule_sample.json` names every granule stage
3 opened; its SHA-256 begins `6d7fe38a9147cc40`. A later run is comparable with this one only
where that digest matches, since a grade rests on the specific granules compared rather than on the
collection as a whole.

**Tool defects separated from data properties.** A grade describes the archive, so one VirtualiZarr
defect is corrected before probing: `_extract_attrs` compares a converted attribute against
`"DIMENSION_SCALE"` without checking it is still a scalar, which raises `ValueError` on any granule
carrying an attribute of two or more fixed-length strings and aborts the whole file. The probe
installs a corrected version, in `scripts/vz_shims.py`, through which ICESat-2 `ATL03` reads.

The HDF4 path, which VirtualiZarr delegates to kerchunk, reads some of NASA's HDF-EOS2 holdings and
not others: of the 14 collections sampled in an HDF4-generation container, 5 yield arrays on every granule opened, 8 raise on every granule in 3 distinct ways, and 1 (MIL2TCST) returns a store holding no arrays at all, which is a failure the call's own return value does not report. A parser that reports success and produces no chunk manifest is graded
as a failure to read the layout, since nothing downstream can be built from an empty store. So
HDF-EOS2 is not uniformly unreadable — readability varies by producer, which is why a grade here is
measured per collection rather than inferred from the format field.

Where a refusal came from is a separate question from what the file holds, and stage 6 answers it
per collection rather than per format: `_descend_vg` indexes a scientific-data descriptor's `data`
field unconditionally, and that field is set only for a descriptor the file marks extended, so a
contiguous one stops the walk even though the descriptor carries its own offset and length. That is
the finding behind every `F*` row. The refusals kept as properties of the files themselves are the
ones stage 6 traced to something Zarr cannot express: several dimension scales on one axis, which a
Zarr array cannot name once, and a string `_FillValue` on a numeric variable, which a typed Zarr
fill value cannot hold.


## Sample comparability

A criterion that compares two granules answers a question about one cube only if both granules
would belong to that cube. Many NASA collections are partitioned by something other than time — by
variable, band, tile, resolution, subswath, orbit direction, or processing version — and a sample
drawn without holding that partition fixed makes H2 and H3 compare arrays a user would never
stack, so the difference they find belongs to the sample rather than to the archive.

Two mechanisms narrow the sample. Where a granule exposes the partition as a choice of object, one
file per band or per polarization, stage 2 takes the asset the most granules offer. Where the
partition is the granule itself, stage 2 restricts the CMR query with a
`readable_granule_name` pattern before drawing the ends of the record, so the early-and-late
contrast is taken within the narrowed series rather than across the whole collection.
35 collections are narrowed this way. Their grades describe a cube over one value of
the partition across the full time record — for a tiled product, a cube per tile, which is the
only cube its grid admits.

| Grade | Product | Narrowed to | Granules |
|---|---|---|---|
| B | ATL14 | Greenland, 100 m | 1 |
| B | ATL15 | Greenland, monthly, 20 km | 1 |
| B | ECO_L2T_LSTE | MGRS tile 41SPS | 4 |
| B | HLSL30 | MGRS tile T59WNT | 8 |
| B | NISAR_L2_GCOV_PROVISIONAL_V1 | track 004 ascending, frame 018, DHDH polarization | 8 |
| B | NISAR_L2_GSLC_PROVISIONAL_V1 | track 004 ascending, frame 018, DHDH polarization | 8 |
| B | NISAR_L2_GUNW_PROVISIONAL_V1 | track 036 ascending, frame 163, across cycle pairs | 4 |
| B | NISAR_L3_SME2_PROVISIONAL_V1 | track 004 ascending, frame 018, DHDH polarization | 8 |
| B | PACE_OCI_L3M_BGC | daily composite at 4 km | 8 |
| B | SWOT_L2_HR_Raster_2.0 | 100 m raster, UTM zone 10T, pass 013, scene 114F — a calibration-orbit scene, so the sample covers 2023 alone | 4 |
| B | OPERA_L2_CSLC-S1_V1 | track 151, burst 322284, subswath IW1 | 8 |
| B | OPERA_L2_RTC-S1_V1 | track 063, burst 133239, subswath IW1 | 8 |
| B | OPERA_L3_DSWX-HLS_V1 | MGRS tile T56LPN | 7 |
| B | HLSS30 | MGRS tile T55JFH | 8 |
| B | MCD12Q1 | sinusoidal tile h08v05 | 8 |
| B | MCD43A3 | sinusoidal tile h08v05 | 8 |
| B | MOD10A1 | sinusoidal tile h08v05 | 8 |
| B | MOD11A1 | sinusoidal tile h08v05 | 8 |
| B | MOD13Q1 | sinusoidal tile h08v05 | 8 |
| B | NSIDC-0776 | RGI region 03A | 8 |
| B | NSIDC-0051 | the northern hemisphere at 25 km | 8 |
| D | MODISA_L3m_CHL | daily composite at 4 km | 8 |
| D | Daymet_Daily_V4R1_2129 | the Puerto Rico region, tmin variable | 8 |
| D | NISAR_L1_RSLC_PROVISIONAL_V1 | track 004 ascending, frame 018, DHDH polarization | 8 |
| D | SPL2SMP_E | ascending half-orbits | 8 |
| D | SWOT_L2_HR_PIXC_2.0 | pass 166, tile 299L | 5 |
| D | SWOT_L2_LR_SSH_2.0 | the Basic product file | 7 |
| D | VIIRSN_L3m_CHL | daily composite at 4 km | 8 |
| D | TEMPO_NO2_L2 | mirror step G01 of each scan | 8 |
| F\* | MIL2TCST | orbital path 020 | 8 |
| F\* | MOD09GA | sinusoidal tile h08v05 | 8 |
| F | GRACEFO_L2_JPL_MONTHLY_0063 | the GSM gravity-field product, solution BA01 | 8 |
| F | SRTMGL1 | the 1° tile at 0°N 13°E | 1 |
| F | VNP09GA | sinusoidal tile h08v05 | 8 |
| F | VNP13A1 | sinusoidal tile h08v05 | 8 |


Each pattern is checked against CMR before use: it matches a non-empty subset whose earliest
and latest granules still span the collection's record. `ATL15` and `SRTMGL1` are the
exceptions and match one granule each, which is a property of the product — both publish one
file per configuration or per tile and have no time series within one — so their cross-granule
criteria report that nothing was comparable rather than comparing files no cube would hold.
CMR matches a pattern against a granule's producer ID as well as its UR, and the two differ:
SWOT gives its `Basic` and `WindWave` files one producer ID, so each returned UR is checked
against the pattern before the sample is drawn.

The remaining differences are counted by a mechanical check: it takes the tokens of each sampled
granule's filename, collapses the timestamps, and reports whatever tokens the granules do not have
in common. 19 collections still differ, and each difference is one the sample keeps on
purpose — a counter that is the time step, or a change the archive really contains and a cube
really has to span.

| Grade | Product | Granules differ in | Kept because |
|---|---|---|---|
| B | AU_SI12 | U2, UE | the collection unifies AMSR-E and AMSR2 on one 12.5 km grid, so the instrument changes within one cube by construction |
| B | NISAR_L2_GCOV_PROVISIONAL_V1 | F, N, P | the mode and frame-coverage flags differ between acquisitions of one frame, which the fixed frame grid absorbs; the frame itself is pinned |
| B | NISAR_L2_GSLC_PROVISIONAL_V1 | F, N, P | the mode and frame-coverage flags differ between acquisitions of one frame, which the fixed frame grid absorbs; the frame itself is pinned |
| B | NISAR_L3_SME2_PROVISIONAL_V1 | F, N, P | the mode and frame-coverage flags differ between acquisitions of one frame, which the fixed frame grid absorbs; the frame itself is pinned |
| B | SPL4CMDL | Vv8020, Vv8040, Vv8041 | the three processing versions are all part of the record, and whether a cube spans a version change is the question rather than a nuisance to remove |
| B | SPL4SMGP | Vv8010, Vv8011 | the two processing versions are both part of the record, and whether a cube spans a version change is the question rather than a nuisance to remove |
| B | OPERA_L2_RTC-S1_V1 | S1A, S1C | a burst is imaged by whichever Sentinel-1 satellite is overhead, so the platform changes within one cube by construction |
| B | OPERA_L3_DSWX-HLS_V1 | S2A, S2B | the product fuses Sentinel-2 and Landsat, so the platform changes within one cube by construction |
| B | TEMPO_HCHO_L3 | S001, S002, S011, S012, S015, S030 | the scan number is the time step; every scan is the same CONUS grid |
| B | TEMPO_NO2_L3 | S001, S002, S011, S012, S015, S030 | the scan number is the time step; every scan is the same CONUS grid |
| B | AST_L1T | TIR, VNIR | ASTER writes one file per subsystem and not every scene carries both, and the scenes are different places rather than slices of one array, so no narrowing makes them one cube |
| D | GEDI02_A | O01753, O10210, O18667, O30423, O35579, O37238, T00000, T01683, T02099, T06561, T09057, T09842 | the orbit and track numbers index position along the record, not a partition |
| D | GEDI02_B | O01753, O10210, O18667, O30423, O35579, O37238, T00000, T01683, T02099, T06561, T09057, T09842 | the orbit and track numbers index position along the record, not a partition |
| D | NISAR_L1_RSLC_PROVISIONAL_V1 | F, N, P | the mode and frame-coverage flags differ between acquisitions of one frame, which the fixed frame grid absorbs; the frame itself is pinned |
| D | SWOT_L2_LR_SSH_2.0 | PGC0, PIC0, PIC2 | the two processing versions are both part of the record; the product file is pinned |
| D | TEMPO_NO2_L2 | S001G01, S002G01, S011G01, S012G01, S016G01, S031G01 | the scan number is the time step; the mirror step within a scan is pinned |
| F\* | MIL2TCST | F06, F07, F08 | the three product versions are all part of the record; the orbital path is pinned |
| F | CAL_LID_L1-Standard-V4-51 | #ZD, #ZN | day and night granules are both part of the record |
| F | GEDI_L4A_AGB_Density_V3_2508 | O01753, O10210, O18667, O30423, O35579, O37238, T00000, T01683, T02099, T06561, T09057, T09842 | the orbit and track numbers index position along the record, not a partition |


## Coverage

86 collections, 619 granules opened or attempted.

Collections where not every sampled granule opened:

| Product | Opened | Attempted | Sampled | Reason |
|---|---|---|---|---|
| OPERA_L2_CSLC-S1_V1 | 2 | 8 | 8 | request failed in transport, so this granule's layout is unmeasured |
| OPERA_L2_RTC-S1_V1 | 6 | 8 | 8 | request failed in transport, so this granule's layout is unmeasured |
| M2T1NXSLV | 4 | 8 | 8 | request failed in transport, so this granule's layout is unmeasured |
| ML2O3_NRT | 2 | 4 | 4 | request failed in transport, so this granule's layout is unmeasured |
| AIRS2RET | 0 | 8 | 8 | HDF4 backend cannot read the HDF-EOS2 vgroup holding the data-block references |
| AIRS3STD | 0 | 8 | 8 | HDF4 backend cannot read the HDF-EOS2 vgroup holding the data-block references |
| MYD04_L2 | 0 | 8 | 8 | HDF4 backend derived a dimension-name list of the wrong length for the array's rank |
| CER_SSF1deg-Day_Aqua-MODIS | 0 | 8 | 8 | HDF4 backend failed decoding a vgroup name as UTF-8; probe limit, not a data property — granule is 927 MB; above the 839 MB copy-to-disk limit for kerchunk-backed parsers; probe limit, not a data property — granule is 914 MB; above the 839 MB copy-to-disk limit for kerchunk-backed parsers; probe limit, not a data property — granule is 898 MB; above the 839 MB copy-to-disk limit for kerchunk-backed parsers; probe limit, not a data property — granule is 884 MB; above the 839 MB copy-to-disk limit for kerchunk-backed parsers; probe limit, not a data property — granule is 897 MB; above the 839 MB copy-to-disk limit for kerchunk-backed parsers |
| CER_SYN1deg-1Hour_Terra-Aqua-NOAA20 | 0 | 8 | 8 | HDF4 backend failed decoding a vgroup name as UTF-8 |
| MOD09GA | 0 | 8 | 8 | HDF4 backend cannot read the HDF-EOS2 vgroup holding the data-block references |
| MOD35_L2 | 0 | 8 | 8 | HDF4 backend derived a dimension-name list of the wrong length for the array's rank |
| CAL_LID_L1-Standard-V4-51 | 0 | 8 | 8 | HDF4 backend failed decoding a vgroup name as UTF-8 |
| GRACEFO_L2_JPL_MONTHLY_0063 | 0 | 8 | 8 | no VirtualiZarr parser reads ASCII |
| ATL11 | 0 | 4 | 4 | file attaches several dimension scales to one axis; a Zarr array names each axis once |
| GEDI_L4A_AGB_Density_V3_2508 | 0 | 8 | 8 | array carries a dtype Zarr cannot express — Zarr data type resolution from object failed. Attempted to resolve a z |
| SRTMGL1 | 0 | 1 | 1 | no VirtualiZarr parser reads HGT |
| VNP09GA | 0 | 8 | 8 | file stores a string _FillValue on a numeric variable; Zarr requires a number |
| VNP13A1 | 0 | 8 | 8 | file stores an array _FillValue on a numeric variable; a Zarr fill value is scalar |
| M2I3NPASM | 0 | 1 | 8 | chunk index could not be read within the probe budget — exceeded the 1800 s probe budget for one granule; not attempted: an earlier granule exhausted the probe budget |


## Verification

The grades rest on two claims: that a chunk manifest built from these measurements serves the
archival bytes unchanged, and that a row graded D is blocked by the criterion its deciding
column names. `verification.md` tests both directly.

For the first, it combines granules of a top-graded collection into one virtual dataset, reads
slices of the combination that fall in different source granules, and compares them against
the same slices read from those granules with `h5py`; it commits the same manifest to an
Icechunk repository, reopens it, and reads a slice back out; and it fetches one
`(url, offset, length)` triple by hand and reverses the codec chain to confirm the bytes
decode to the declared chunk shape.

For the second, a control counts only when VirtualiZarr's refusal names the same obstruction
the criterion does — a collection that refuses for an unrelated reason would make the grade
right about the outcome by accident. H3 is exercised on a product whose swath length is not a
multiple of its chunk length, and H2 on a pair of granules that agree on the shape of every
variable they share, so that differing chunk shape is the only difference left and the refusal
can only be about it.

H4 and H5 block a `D` on the same footing as H2 and have no control yet. Both rest on the
same property of Zarr that H2 does — one array declares one chunk grid, one data type, and one
codec chain — and both are read from the same manifest H2's shapes come from, so the
measurement is the one already demonstrated; what is untested is that VirtualiZarr refuses a
combination differing only in data type or only in codec chain. The candidates are ASCATA-L2-Coastal, Daymet_Daily_V4R1_2129, OMPS_NPP_NMTO3_L3_DAILY — the collections whose verdicts turn on one of the two.

[`results/verification.md`](results/verification.md) holds what each check actually read and returned.


## Deploy

Stages 1 to 3 and the verification read NASA's protected buckets, which reject direct S3 from
outside `us-west-2`, so access is over authenticated HTTPS carrying an Earthdata Login bearer
token. You need [Earthdata Login](https://urs.earthdata.nasa.gov/) credentials in `~/.netrc`. No
credential is stored in this repository.

```sh
julia --project=. -e 'import Pkg; Pkg.instantiate()'
python -m venv .venv && .venv/bin/pip install -r requirements.txt
```

`requirements.txt` pins the Python side at the versions these results were produced with. On the
Julia side, `EarthData` resolves from a public fork pinned to a commit rather than from the
registry, because the registered release does not export `data_urls`, `granule_size`, or the UMM
schema modules that stages 1 and 2 use.

| Stage | Network | What it does |
|---|---|---|
| `julia --project=. scripts/01_inventory.jl` | yes | resolves each dataset to a cloud-hosted CMR collection |
| `julia --project=. scripts/02_sample.jl` | yes | draws granules from both ends of the record, narrowed to one comparable series |
| `.venv/bin/python scripts/03_probe.py` | yes | opens every sampled granule and records its layout |
| `julia --project=. scripts/04_score.jl` | no | reduces the measurements to a verdict per criterion and a grade |
| `julia --project=. scripts/05_report.jl` | no | regenerates this file |
| `.venv/bin/python scripts/06_diagnose.py` | yes | re-reads every granule a parser refused and records what the file holds there |
| `.venv/bin/python scripts/07_buckets.py` | no | labels each refusal with the companion survey's failure bucket |
| `.venv/bin/python scripts/verify_endtoend.py` | yes | builds virtual stores and checks the grades against them |
| `julia --project=. test/runtests.jl` | no | exercises every branch of the criteria against constructed probe records |
| `.venv/bin/python test/test_probe_cache.py` | no | checks the range cache serves the same bytes the network would |

Stage 3 caches the byte ranges it reads under `.probe_cache/`, keyed by granule URL. The probe reads
a granule's chunk index rather than its data — a median of a few 1 MiB blocks against granules whose
median size is close to a gigabyte — so caching ranges holds about 15 GiB for a full sample where
caching the granules whole would hold 530 GB. The cache sits below the instrumented block reader, so
a block the reader had to fetch is still counted whether the bytes came from disk or from NASA, and
`P-md` measures the granule rather than what this machine happens to hold. Deleting the directory
costs time on the next run and changes no measurement.

The grades are produced by `src/criteria.jl` rather than read off a measurement, so that file has a
test per branch: each criterion is a pure function of one collection's probe records, and
`test/runtests.jl` builds the records that reach every verdict it can return, including the
precedence `grade` applies among them. A criterion changed without a test changed is a grade that
can move with nothing to catch it.

Stage 3 takes hours: every request pays an Earthdata Login redirect. Stages 2 and 3 accept a list
of collection short names to redo only those, merging into the existing sample and artifacts, which
is how a single collection is re-measured without repeating the run. Stage 3 records the digest of
the granule URLs it opened and re-probes a collection whose sample has moved since, so a changed
sample cannot be scored against measurements taken on different granules.

Re-drawing the sample invalidates every probe artifact, so `scripts/02_sample.jl --revisions-only`
exists to record when the granules already sampled were last written without drawing new ones: one
CMR query per collection, and nothing downstream is invalidated. Stage 2 bounds each CMR granule
search rather than waiting indefinitely — CMR answers a collection search in well under a second and
a granule search in anything from that to minutes, and a stage issuing hundreds of them cannot stall
on one.

Because `results/probe/` is committed, stages 4 and 5 reproduce this file offline from a clone —
no credentials and no network. Adding a collection means adding a `Candidate` to `src/datasets.jl`;
a collection partitioned by anything other than time also needs an entry in `src/partitions.jl`,
and one whose layout could not be read needs a `CUBE_AXES` entry in `src/structure.jl` stating
what a cube over its record would be indexed by. Stage 4 errors rather than emit an `F` or `U`
row without one, so the question of whether a grade reports a container choice or an absence of
structure is asked of every collection.

This file is generated by stage 5 from `results/virtualizability.csv`. Edit the stage, not the
file.

## Issues

If you would like a dataset added, a new criterion measured, or you dispute the reasoning behind a
score, please [file an issue](https://github.com/alex-s-gardner/EarthDataVirtualizabilityScore/issues).

A score here is disputable on the evidence. Every verdict names the measurement that produced it:
the `*_evidence` columns of `results/virtualizability.csv` carry the reasoning per criterion, and
`results/probe/` holds the per-granule records those reduce from. An issue that points at one of
those settles fastest.

Counterexamples are especially useful. A `D` or `F` rests on a granule pair that disagree or a
refusal that names a feature, so it is hard to overturn without showing the measurement wrong. An
`A` or `B` only says no blocker appeared in the granules sampled, so a granule this sample missed
that breaks one changes the grade.

