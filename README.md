# EarthDataVirtualizabilityScore

64 NASA Earthdata collections ranked by whether their archives can be served as lazy Zarr
datacubes **without duplicating bytes**. Every verdict is measured by opening granule files, not
read from the catalog.

## Purpose

Cloud storage changed how data is read. Block storage exposed files on a disk; object storage puts
each object — data, its metadata, and an identifier — in a flat space with no folders. It scales
massively and cheaply, but it is latency-bound: the number of get-requests, not the bandwidth,
usually sets how fast a read completes.

Formats built for that paradigm — [Zarr](https://zarr-specs.readthedocs.io/en/latest/v3/core/index.html),
[VirtualiZarr](https://github.com/zarr-developers/VirtualiZarr),
[kerchunk](https://github.com/fsspec/kerchunk), [Icechunk](https://github.com/earth-mover/icechunk) —
abstract files away, mapping chunks into dimensioned arrays that tools like Xarray and Zarrs.jl
read lazily. A virtual store does this without copying anything: it maps each Zarr chunk key to a
`(url, offset, length)` triple in the original granule and fetches it with an HTTP range request.

The roadblock is the raw data. For an archive to be virtualizable as it stands it needs
consolidated metadata, one grid, and chunks that align in space. Meet all three and a lazy datacube
over the whole archive costs nothing but the manifest. Satellite data usually fails the third: a
product can be perfectly grid-aligned and still not chunk-aligned, because the image edges move
with every pass — a swath whose length varies by orbit puts a partial chunk in the middle of the
concatenated array, and ascending and descending passes can share a grid exactly while sharing no
chunk origin. This ranking measures which of NASA's major archives clear that bar.

## Method

Whether an archive can be presented as a lazy datacube is a property of how its granules were
written, not of the catalog. CMR publishes no chunk shapes, and its gridded-resolution field is
absent for most of these collections, so the deciding columns cannot come from metadata.

Every column below except format, DAAC, region, granule count, and level is therefore measured by
opening granule files with VirtualiZarr's own parsers, which are what a real virtual store is built
from — and a parser's refusal is itself an answer, since the exception names the feature that stops
a chunk manifest being written. Even the two collections whose CMR format field names a container no
VirtualiZarr parser reads — `ASCII` and `HGT` — are checked against the granule's own first bytes
before that field is acted on, so a format ruled out here is ruled out on what the file is rather
than on what the catalog calls it.

Each collection is sampled at both ends of its record, narrowed first to one series of granules a
single cube would actually hold. Each criterion below states what it requires and what evidence
settles it; `results/virtualizability.csv` carries every verdict with its evidence in its own
column, and `results/probe/` holds the per-granule measurements all of them derive from.

## Ranking

| Grade | Sensor | Product | Level | Format | DAAC | S3 region | Consolidated md | Grid aligned | Chunk aligned | Time dim | Chunk shape | Chunk MB | Granules | Volume TB | DMR++ | Deciding criterion |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| A | AVHRR | AVHRR_OI-NCEI-L4-GLOB-v2.1 | L4 | netCDF-4 | NASA/JPL/PODAAC | us-west-2 | yes | yes | yes | yes | 1×720×1440 | 0.67 | 3915 | 0.004 | yes | no blocker |
| A | GLDAS (model) | GLDAS_NOAH025_3H | L4 | NetCDF | NASA/GSFC/SED/ESD/TISL/GESDISC | us-west-2 | partial | yes | yes | yes | 1×600×1440 | 0.453 | 77423 | 1.604 | yes | no blocker |
| A | GPM/DPR+GMI | GPM_3IMERGDF | L3 | NetCDF | NASA/GSFC/SED/ESD/TISL/GESDISC | us-west-2 | partial | yes | yes | yes | 1×3600×900 | 2.622 | 10135 | 0.303 | yes | no blocker |
| A | GPM/DPR+GMI | GPM_3IMERGHH | L3 | HDF5 | NASA/GSFC/SED/ESD/TISL/GESDISC | us-west-2 | partial | yes | yes | yes | 1×145×1800 | 0.052 | 486480 | 3.851 | yes | no blocker |
| A | GRACE | TELLUS_GRAC_L3_JPL_RL06_LND_v04 | L3 | netCDF-4 | NASA/JPL/PODAAC | us-west-2 | yes | yes | yes | yes | 1×180×360 | 0.518 | 163 | 0.0 | yes | no blocker |
| A | NLDAS (model) | NLDAS_FORA0125_H | L4 | NetCDF | NASA/GSFC/SED/ESD/TISL/GESDISC | us-west-2 | yes | yes | yes | yes | 1×224×464 | 0.092 | 418259 | 0.738 | yes | no blocker |
| A | multi-sensor (OSTIA) | OSTIA-UKMO-L4-GLOB-REP-v2.0 | L4 | netCDF-4 | NASA/JPL/PODAAC | us-west-2 | yes | yes | yes | yes | 1×1200×2400 | 1.229 | 15340 | 0.245 | yes | no blocker |
| B | CERES | CERES_EBAF-TOA | L4 | netCDF-3 | NASA/LARC/SD/ASDC | us-west-2 | — | yes | yes | yes | 1×180×360 | 0.259 | 2 | 0.002 | no | P-md: not measured (parser bypasses the instrumented reader) |
| B | Daymet (model) | Daymet_Daily_V4R1_2129 | L4 | netCDF-4 | ORNL_DAAC | us-west-2 | partial | yes | yes | yes | 1×231×364 | 0.026 | 1176 | 0.012 | yes | P-sz: tmin: median stored chunk 0.026 MB in 365 chunks — latency-bound |
| B | ICESat-2/ATLAS | ATL15 | L3 | netCDF-4 | NASA NSIDC DAAC | us-west-2 | no | — | — | yes | 44×112×132 | 0.963 | 80 | 0.008 | no | H2: no data array appears in two opened granules; H3: no data array appears in two opened granules; G: coordinates read for one granule only, so no cross-granule comparison — measured delta_h/x/delta_h/y/tile_stats/x/tile_stats/y on 1 granules; step 10000.0; P-md: median 29 blocks in 21 runs, 3% leading |
| B | ISS/ECOSTRESS | ECO_L2T_LSTE | L2 | COG | LP DAAC | us-west-2 | yes | yes | yes | no | 512×512 | 0.002 | 3934771 | 7.611 | no | T: file declares no dimension names; P-sz: band: median stored chunk 0.002 MB in 16 chunks — latency-bound |
| B | ISS/EMIT | EMITL1BRAD | L1B | netCDF-4 | LP DAAC | us-west-2 | partial | no | — | no | 1280×1242×11 | 69.949 | 8923 | 0.971 | yes | H2: chunk shape differs for smaller variables (2 of 4 variables — location/glt_x: [1890, 2062] vs [1890, 2070] vs [952, 1101] vs [951, 1105]); obs is stable, so a cube over it is available; T: no time dimension |
| B | ISS/EMIT | EMITL2ARFL | L2A | netCDF-4 | LP DAAC | us-west-2 | partial | no | — | no | 1280×1242×285 | 1812.326 | 8755 | 16.43 | yes | H2: chunk shape differs for smaller variables (2 of 8 variables — location/glt_x: [1890, 2062] vs [1890, 2070] vs [952, 1101] vs [951, 1105]); reflectance is stable, so a cube over it is available; T: no time dimension |
| B | ISS/GEDI | GEDI02_A | L2A | HDF5 | LP DAAC | us-west-2 | no | no | — | partial | 596×13 | 0.0 | 96864 | 3.096 | no | H2: no data array appears in two opened granules; H3: no data array appears in two opened granules; T: time variable "beam0000/delta_time" but no time dimension; P-md: median 128 blocks in 22 runs, 7% leading; P-sz: BEAM0010/rh: median stored chunk 0.0 MB in 128 chunks — latency-bound |
| B | Landsat 8-9/OLI | HLSL30 | L3 | COG | LP DAAC | us-west-2 | yes | partial | yes | no | 256×256 | 0.057 | 16032812 | 313.955 | no | G: 2 projections across 2 tile origins (EPSG:32659, ProjectionGeoKey:16059) — one grid per tile, each internally on a 30 m lattice; T: file declares no dimension names |
| B | NISAR/L-SAR | NISAR_L2_GCOV_PROVISIONAL_V1 | L2 | CSV+HDF5+KML+PDF+PNG+XML+YAML | ASF | us-west-2 | partial | yes | yes | partial | 512×512 | 0.526 | 120156 | 849.191 | no | T: time variable "science/lsar/gcov/metadata/attitude/time" but no time dimension |
| B | NISAR/L-SAR | NISAR_L2_GSLC_PROVISIONAL_V1 | L2 | CSV+HDF5+KML+PDF+PNG+XML+YAML | ASF | us-west-2 | partial | yes | yes | partial | 512×512 | 1.003 | 119395 | 2655.13 | no | T: time variable "science/lsar/gslc/metadata/attitude/time" but no time dimension |
| B | NISAR/L-SAR | NISAR_L2_GUNW_PROVISIONAL_V1 | L2 | CSV+HDF5+KML+PDF+PNG+XML+YAML | ASF | us-west-2 | partial | yes | yes | partial | 512×512 | 0.009 | 66606 | 89.816 | no | T: time variable "science/lsar/gunw/metadata/attitude/reference/time" but no time dimension; P-sz: science/LSAR/GUNW/grids/frequencyA/wrappedInterferogram/HH/wrappedInterferogram: median stored chunk 0.009 MB in 1056 chunks — latency-bound |
| B | NISAR/L-SAR | NISAR_L3_SME2_PROVISIONAL_V1 | L3 | HDF5+XML+YAML | ASF | us-west-2 | yes | yes | yes | no | 512×512 | 0.007 | 76624 | 8.436 | no | T: no time dimension; P-sz: science/LSAR/SME2/grids/algorithmCandidates/DSG/algorithmParameterBeta: median stored chunk 0.007 MB in 16 chunks — latency-bound |
| B | PACE/OCI | PACE_OCI_L3M_BGC | L3 | netCDF-4 | NASA/GSFC/SED/ESD/GCDC/OB.DAAC | us-west-2 | partial | yes | yes | no | 16×1024 | 0.003 | 2000 | 0.082 | no | T: no time dimension; P-sz: carbon_phyto: median stored chunk 0.003 MB in 2430 chunks — latency-bound |
| B | SMAP/L-band radiometer | SMAP_JPL_L3_SSS_CAP_MONTHLY_V5 | L3 | netCDF-4 | NASA/JPL/PODAAC | us-west-2 | partial | yes | yes | partial | 720×1440 | 1.115 | 135 | 0.001 | yes | T: "time" is a time coordinate, but no data array is laid out on it, so a time axis has to be added when the store is built |
| B | SMAP/L-band radiometer | SPL3SMP | L3 | HDF5 | NASA NSIDC DAAC | us-west-2 | partial | — | — | partial | 1×964×3 | 0.001 | 4108 | 0.13 | yes | G: no projection attribute or spatial coordinate array reached the probe, so the grid is unmeasured, not absent; T: time variable "soil_moisture_retrieval_data_am/tb_time_seconds" but no time dimension; P-sz: Soil_Moisture_Retrieval_Data_AM/landcover_class_fraction: median stored chunk 0.001 MB in 406 chunks — latency-bound |
| B | SMAP/L-band radiometer | SPL4SMGP | L4 | HDF5 | NASA NSIDC DAAC | us-west-2 | no | yes | yes | partial | 1624×3856 | 1.455 | 33528 | 4.968 | yes | T: time variable "time" but no time dimension; P-md: median 32 blocks in 28 runs, 9% leading |
| B | SWOT/KaRIn | SWOT_L2_HR_Raster_2.0 | L2 | netCDF-4 | NASA/JPL/PODAAC | us-west-2 | no | yes | yes | partial | 518×518 | 0.281 | 1556453 | 78.075 | no | T: time variable "illumination_time" but no time dimension; P-md: median 32 blocks in 16 runs, 3% leading |
| B | Sentinel-1/C-SAR (OPERA) | OPERA_L2_RTC-S1_V1 | L2 | GeoTIFF+HDF5+XML | ASF | us-west-2 | yes | yes | yes | no | 512×512 | 0.044 | 74657047 | 508.18 | no | T: file declares no dimension names; P-sz: band: median stored chunk 0.044 MB in 28 chunks — latency-bound |
| B | Sentinel-1/C-SAR (OPERA) | OPERA_L3_DSWX-HLS_V1 | L3 | COG | NASA/JPL/PODAAC | us-west-2 | yes | yes | yes | no | 512×512 | 0.001 | 20930812 | 3.054 | no | T: file declares no dimension names; P-sz: band: median stored chunk 0.001 MB in 64 chunks — latency-bound |
| B | Sentinel-2/MSI | HLSS30 | L3 | COG | LP DAAC | us-west-2 | yes | yes | yes | no | 256×256 | 0.001 | 21959038 | 7.627 | no | T: file declares no dimension names; P-sz: band: median stored chunk 0.001 MB in 225 chunks — latency-bound |
| B | Suomi-NPP/VIIRS | VNP02MOD | L1B | netCDF-4 | NASA/GSFC/SED/ESD/HBSL/BISB/LAADS | us-west-2 | no | no | — | partial | 16×3200 | 0.041 | 1267247 | 86.525 | no | H2: chunk shape differs for smaller variables (2 of 42 variables — number_of_lines: [3248] vs [3232]); observation_data/M13 is stable, so a cube over it is available; T: time variable "scan_line_attributes/ev_mid_time" but no time dimension; P-md: median 36 blocks in 17 runs, 8% leading; P-sz: observation_data/M13: median stored chunk 0.041 MB in 202 chunks — latency-bound |
| B | TEMPO | TEMPO_NO2_L3 | L3 | netCDF-4 | NASA/LARC/SD/ASDC | us-west-2 | no | yes | yes | yes | 1×738×1938 | 1.068 | 17074 | 12.662 | yes | P-md: median 50 blocks in 46 runs, 4% leading |
| B | Terra+Aqua/MODIS | MCD43A3 | L3 | HDF-EOS2 | LP DAAC | us-west-2 | — | — | — | no | 100×2400 | 0.218 | 2981668 | 291.993 | no | P-md: not measured (parser bypasses the instrumented reader); G: no projection attribute or spatial coordinate array reached the probe, so the grid is unmeasured, not absent; T: no time dimension |
| B | Terra/MODIS | MOD021KM | L1B | NetCDF-4 | NASA/GSFC/SED/ESD/HBSL/BISB/LAADS | us-west-2 | partial | no | — | no | 6×2030×1354 | 17.82 | 2757014 | 164.393 | no | T: no time dimension |
| B | Terra/MODIS | MOD10A1 | L3 | HDF-EOS2 | NASA NSIDC DAAC | us-west-2 | — | — | — | no | 2400×2400 | — | 2927249 | 21.037 | no | H2: one chunk shape per variable across 7 variables in 4 granules, but each granule is one chunk spanning its whole array, which pins the cube's chunk shape to these exact dimensions, and the grid went unmeasured, so whether every granule carries these dimensions is unestablished rather than observed; P-sz: NDSI: no stored chunk length the format could produce, so the parser did not record one; P-md: not measured (parser bypasses the instrumented reader); G: no projection attribute or spatial coordinate array reached the probe, so the grid is unmeasured, not absent; T: no time dimension |
| B | Terra/MODIS | MOD11A1 | L3 | HDF-EOS2 | LP DAAC | us-west-2 | — | — | — | no | 1200×1200 | 0.78 | 3044695 | 11.149 | yes | H2: one chunk shape per variable across 12 variables in 4 granules, but each granule is one chunk spanning its whole array, which pins the cube's chunk shape to these exact dimensions, and the grid went unmeasured, so whether every granule carries these dimensions is unestablished rather than observed; P-md: not measured (parser bypasses the instrumented reader); G: no projection attribute or spatial coordinate array reached the probe, so the grid is unmeasured, not absent; T: "day_view_time_x" is declared by one array only, so it is a per-array name rather than a shared time dimension |
| B | Terra/MODIS | MOD13Q1 | L3 | HDF-EOS2 | LP DAAC | us-west-2 | — | — | — | no | 1×4800 | 0.006 | 177776 | 38.462 | yes | P-md: not measured (parser bypasses the instrumented reader); G: no projection attribute or spatial coordinate array reached the probe, so the grid is unmeasured, not absent; T: no time dimension; P-sz: 250m 16 days EVI: median stored chunk 0.006 MB in 4800 chunks — latency-bound |
| B | multi-sensor (ITS_LIVE) | NSIDC-0776 | L3 | netCDF-4 | NASA NSIDC DAAC | us-west-2 | partial | yes | yes | no | 1500×1500 | 0.224 | 546 | 0.065 | no | T: no time dimension |
| B | multi-sensor (MUR SST) | MUR-JPL-L4-GLOB-v4.1 | L4 | netCDF-4 | NASA/JPL/PODAAC | us-west-2 | no | yes | yes | yes | 1×1023×2047 | 0.989 | 8878 | 4.886 | yes | H2: chunk shape differs for smaller variables (2 of 6 variables — mask: [1, 1447, 2895] vs [1, 1023, 2047]); analysed_sst is stable, so a cube over it is available; P-md: median 21 blocks in 16 runs, 7% leading; S1: units differ but no attribute that changes a decoded value does, so the cube is mislabelled rather than wrong — sea_ice_fraction.units: fraction (between 0 and 1) vs ∅ |
| D | Aqua/MODIS | MODISA_L3m_CHL | L3 | netCDF-4 | NASA/GSFC/SED/ESD/GCDC/OB.DAAC | us-west-2 | partial | yes | no | no | 44×87 | 0.0 | 27028 | 0.288 | no | H2: chunk shape differs across granules (1 of 2 variables — chlor_a: [44, 87] vs [16, 1024]) |
| D | Aura/OMI | OMDOAO3 | L2 | netCDF-4 | NASA/GSFC/SED/ESD/TISL/GESDISC | us-west-2 | yes | no | no | yes | 1×1644×60 | 0.229 | 113357 | 1.107 | yes | H2: chunk shape differs across granules (52 of 57 variables — PRODUCT/SUPPORT_DATA/DETAILED_RESULTS/air_mass_factor: [1, 1644, 60] vs [1, 1643, 60] vs [1, 1494, 60]) |
| D | CERES | CERES_EBAF | L4 | netCDF-4 | NASA/LARC/SD/ASDC | us-west-2 | no | yes | no | yes | 104×60×120 | 1.432 | 3 | 0.006 | yes | H2: chunk shape differs across granules (123 of 248 variables — cldarea_total_daynight_mon: [104, 60, 120] vs [105, 60, 120]) |
| D | GPM/DPR | GPM_2ADPR | L2 | NetCDF | NASA/GSFC/SED/ESD/TISL/GESDISC | us-west-2 | no | no | no | no | 15×49×176×2 | 0.448 | 70448 | 26.899 | yes | H3: interior partial chunk on concatenation (274 of 274 variables) — FS/PRE/zFactorMeasured dim 1: size 7925 not a multiple of chunk 15 |
| D | ICESat-2/ATLAS | ATL03 | L2A | HDF5 | NASA NSIDC DAAC | us-west-2 | yes | no | no | yes | 100000 | 0.458 | 583529 | 413.627 | yes | H3: interior partial chunk on concatenation (560 of 1007 variables) — gt3r/heights/lat_ph dim 1: size 6227159 not a multiple of chunk 100000 |
| D | ICESat-2/ATLAS | ATL06 | L3 | HDF5 | NASA NSIDC DAAC | us-west-2 | yes | — | no | yes | 10000×748 | 0.339 | 438157 | 18.378 | yes | H3: interior partial chunk on concatenation (488 of 551 variables) — gt3l/residual_histogram/count dim 1: size 491 not a multiple of chunk 10000 |
| D | ISS/GEDI | GEDI02_B | L2B | HDF5 | LP DAAC | us-west-2 | partial | no | no | partial | 14200 | 0.006 | 96872 | 5.306 | no | H3: interior partial chunk on concatenation (112 of 1664 variables) — BEAM1000/rx_processing/pgap_theta_z_a10 dim 1: size 45160 not a multiple of chunk 14200 |
| D | MetOp-A/ASCAT | ASCATA-L2-Coastal | L2 | netCDF-4 | NASA/JPL/PODAAC | us-west-2 | yes | no | no | partial | 3251×82 | 0.17 | 57983 | 0.158 | yes | H2: chunk shape differs across granules (9 of 9 variables — bs_distance: [3251, 82] vs [3258, 82] vs [3264, 82]) |
| D | NISAR/L-SAR | NISAR_L1_RSLC_PROVISIONAL_V1 | L1 | CSV+HDF5+KML+PDF+PNG+XML+YAML | ASF | us-west-2 | yes | no | no | partial | 512×512 | 0.989 | 121710 | 3169.88 | no | H3: granule extents differ on two or more axes (6 of 11 variables), so the granules are different regions rather than slices of one array — science/LSAR/RSLC/swaths/frequencyA/HH: 36480×52783 vs 53200×52968 vs 54720×52970 vs 54720×52967 |
| D | PACE/OCI | PACE_OCI_L2_AOP | L2 | netCDF-4 | NASA/GSFC/SED/ESD/GCDC/OB.DAAC | us-west-2 | no | no | no | partial | 32×256×40 | 0.05 | 120491 | 28.902 | no | H3: interior partial chunk on concatenation (20 of 31 variables) — geophysical_data/Rrs dim 1: size 1709 not a multiple of chunk 32 |
| D | SMAP/L-band radiometer | SPL2SMP_E | L2 | HDF5 | NASA NSIDC DAAC | us-west-2 | partial | no | no | partial | 269166 | 1.283 | 120087 | 3.197 | no | H2: chunk shape differs across granules (92 of 92 variables — Soil_Moisture_Retrieval_Data/tb_time_seconds: [269166] vs [268969] vs [267218] vs [268835]) |
| D | SWOT/KaRIn | SWOT_L2_HR_PIXC_2.0 | L2 | netCDF-4 | NASA/JPL/PODAAC | us-west-2 | partial | no | no | partial | 402169 | 0.006 | 2996378 | 105.709 | yes | H2: chunk shape differs across granules (83 of 83 variables — pixel_cloud/illumination_time: [402169] vs [410854] vs [384517] vs [386222]) |
| D | SWOT/KaRIn | SWOT_L2_LR_SSH_2.0 | L2 | netCDF-4 | NASA/JPL/PODAAC | us-west-2 | partial | no | no | partial | 9865×69 | 0.924 | 90959 | 0.911 | yes | H2: chunk shape differs across granules (23 of 23 variables — geoid: [9865, 69] vs [9866, 69]) |
| D | Suomi-NPP/VIIRS | VIIRSN_L3m_CHL | L3 | netCDF-4 | NASA/GSFC/SED/ESD/GCDC/OB.DAAC | us-west-2 | partial | yes | no | no | 44×87 | 0.001 | 13910 | 0.238 | no | H2: chunk shape differs across granules (1 of 2 variables — chlor_a: [44, 87] vs [16, 1024]) |
| D | TEMPO | TEMPO_NO2_L2 | L2 | netCDF-4 | NASA/LARC/SD/ASDC | us-west-2 | no | no | no | partial | 123×128×72 | 0.237 | 123089 | 17.318 | yes | H2: chunk shape differs across granules (40 of 41 variables — support_data/gas_profile: [123, 128, 72] vs [128, 128, 72]) |
| F | Aqua/AIRS | AIRS2RET | L2 | HDF-EOS | NASA/GSFC/SED/ESD/TISL/GESDISC | us-west-2 | — | — | — | — | — | — | 2072654 | — | yes | H0: parser refused all 4 granules opened: HDF4 backend cannot read the HDF-EOS2 vgroup holding the data-block references |
| F | Aqua/MODIS | MYD04_L2 | L2 | HDF-EOS | NASA/GSFC/SED/ESD/HBSL/BISB/LAADS | us-west-2 | — | — | — | — | — | — | 1365731 | — | no | H0: parser refused all 4 granules opened: HDF4 backend derived a dimension-name list of the wrong length for the array's rank |
| F | Aqua/MODIS+CERES | CER_SSF1deg-Day_Aqua-MODIS | L3 | HDF4 | NASA/LARC/SD/ASDC | us-west-2 | — | — | — | — | — | — | 278 | — | no | H0: parser refused all 3 granules opened: HDF4 backend failed decoding a vgroup name as UTF-8 |
| F | CALIPSO/CALIOP | CAL_LID_L1-Standard-V4-51 | L1B | HDF4 | NASA/LARC/SD/ASDC | us-west-2 | — | — | — | — | — | — | 162326 | — | no | H0: parser refused all 4 granules opened: HDF4 backend failed decoding a vgroup name as UTF-8 |
| F | GRACE-FO | GRACEFO_L2_JPL_MONTHLY_0063 | L2 | ASCII | NASA/JPL/PODAAC | us-west-2 | — | — | — | — | — | — | 576 | — | no | H0: parser refused all 4 granules opened: no VirtualiZarr parser reads ASCII |
| F | ICESat-2/ATLAS | ATL11 | L3 | HDF5 | NASA NSIDC DAAC | us-west-2 | no | — | — | — | — | — | 8105 | — | no | H0: parser refused all 4 granules opened: file attaches several dimension scales to one axis; a Zarr array names each axis once |
| F | Shuttle/SRTM | SRTMGL1 | L3 | HGT | LP DAAC | us-west-2 | — | — | — | — | — | — | 14297 | — | no | H0: parser refused all 1 granules opened: no VirtualiZarr parser reads HGT |
| F | Suomi-NPP/VIIRS | VNP09GA | L2G | HDF-EOS5 | LP DAAC | us-west-2 | no | — | — | — | — | — | 1999495 | — | yes | H0: parser refused all 4 granules opened: file stores a string _FillValue on a numeric variable; Zarr requires a number |
| F | Terra/MISR | MIL2TCST | L2 | HDF-EOS2 | NASA/LARC/SD/ASDC | us-west-2 | — | no | — | no | — | — | 176026 | 12.247 | no | H0: parser accepted all 4 granules but returned a store with no arrays, so no chunk manifest can be written |
| F | Terra/MODIS | MOD09GA | L2G | HDF-EOS2 | LP DAAC | us-west-2 | — | — | — | — | — | — | 3071812 | — | no | H0: parser refused all 4 granules opened: HDF4 backend cannot read the HDF-EOS2 vgroup holding the data-block references |
| F | Terra/MODIS | MOD35_L2 | L2 | HDF-EOS | NASA/GSFC/SED/ESD/HBSL/BISB/LAADS | us-west-2 | — | — | — | — | — | — | 2756851 | — | no | H0: parser refused all 4 granules opened: HDF4 backend derived a dimension-name list of the wrong length for the array's rank |
| U | MERRA-2 (model) | M2I3NPASM | L4 | NetCDF | NASA/GSFC/SED/ESD/TISL/GESDISC | us-west-2 | no | — | — | — | — | — | 17015 | — | yes | H0: no granule's layout was read: 1 of 4 exhausted the probe budget, 3 not attempted; nothing refused the file itself |
| U | MERRA-2 (model) | M2T1NXSLV | L4 | NetCDF | NASA/GSFC/SED/ESD/TISL/GESDISC | us-west-2 | no | — | — | — | — | — | 17015 | — | yes | H0: no granule's layout was read: 1 of 4 exhausted the probe budget, 3 not attempted; nothing refused the file itself |


## Grades

- **A** — virtualizable as is: parses, one chunk shape for every variable across granules, no
  interior partial chunk, one grid, a shared time dimension, and metadata locality and chunk size
  both measured and adequate.
- **B** — virtualizable but inefficient or partial: some variables carry a different chunk shape
  while the largest does not, so a cube over part of the product is available; or scattered
  metadata, small chunks, one grid per tile rather than one grid, or no in-file time dimension;
  or a criterion `A` requires that this probe could not measure.
- **C** — virtualizable with a correctness risk: an attribute a CF decoder reads disagrees across
  granules (S1), one granule's length is not a multiple of its chunk so concatenation depends on
  that granule being last in the record (H3), or only some granules parse.
- **D** — not virtualizable without rewriting bytes: the largest variable's chunk shape differs
  across granules (H2), concatenation would place a partial chunk in the array interior (H3), or
  the granules differ in extent on two or more axes and so are not slices of one array.
- **F** — the layout could not be read: no parser accepts the data, a parser refused every granule
  it opened and named the feature that stopped it, or a parser accepted every granule and returned
  a store holding no arrays, which yields no chunk manifest.

A `B` lists every reason the collection fell short of `A`, not the first one found: most of these
rows fall short on more than one criterion, and which of them a reader cares about depends on what
they intend to build.
- **U** — not measured. Every sampled granule exhausted the probe's wall-clock budget, which
  bounds reads over authenticated HTTPS from outside `us-west-2` where each request pays an
  Earthdata Login redirect. That is a limit of this measurement path, not a property of the
  archive, so these collections are unranked rather than ranked last.

No collection in this set graded C.


## Criteria

| ID | Requirement | Why it blocks | Source |
|---|---|---|---|
| H0 | The parser must accept the file. | A refusal names an unsupported feature — an HDF5 filter, a variable-length string, a structured dtype. Nothing downstream is possible. | [VirtualiZarr releases](https://virtualizarr.readthedocs.io/en/latest/about/releases.html) |
| H1 | Every chunk of an array must decode to the same shape. | A Zarr v3 regular chunk grid has exactly one chunk shape. The `rectilinear` variable-chunk grid is a registered extension, not core, and VirtualiZarr does not implement it. | [Zarr v3 core](https://zarr-specs.readthedocs.io/en/latest/v3/core/index.html), [rectilinear extension](https://github.com/zarr-developers/zarr-extensions/tree/main/chunk-grids/rectilinear) |
| H2 | All source files must share one internal chunk shape per variable. | Two granules chunked differently cannot be one array. A granule stored as a single chunk spanning its whole array pins the cube's chunk shape to that granule's exact dimensions, so agreement across a sample establishes H2 for the archive only where the granules also sit on one measured grid; without that, agreement is reported as `partial` rather than as a pass, since a swath whose length varies by orbit satisfies it in a few granules and fails it overall. | [VirtualiZarr usage](https://virtualizarr.readthedocs.io/en/latest/how_to/usage.html) |
| H3 | Concatenating on an axis requires `size % chunk == 0` for every file but the last. | Otherwise a short chunk lands in the array interior, which H1 forbids. This is the satellite swath failure mode. | [issue #1078](https://github.com/zarr-developers/VirtualiZarr/issues/1078) |
| S1 | The CF attributes a decoder reads (`scale_factor`, `add_offset`, `_FillValue`) must agree across files. | A mismatch is dropped silently and the first file's encoding is applied to every chunk, so the cube reads without error and returns wrong values. An attribute compares by the value a decoder would use, so an absent `scale_factor` equals a stated 1 and an absent `add_offset` equals a stated 0. A `units` difference alone mislabels the cube without changing a value, and is reported as `partial`. | [issue #1004](https://github.com/zarr-developers/VirtualiZarr/issues/1004) |
| P-md | A reader should reach the whole chunk index in a few contiguous ranges. | Object-store reads are latency-bound, so scattered metadata costs one get-request per region before any data is read. Consolidated metadata is not part of Zarr v3 core; here it is a property of the **source** file. | [Zarr v3 core](https://zarr-specs.readthedocs.io/en/latest/v3/core/index.html) |
| P-sz | Reading an array should not cost one get-request per useful amount of data. | Two measurements set that cost: how many chunks the array is divided into, which fixes how many requests a full read takes, and how many bytes each stored chunk holds, which fixes whether a request is worth its latency. An array held in a handful of chunks is read in a handful of requests however well it compresses, so a small stored chunk counts against a product only where the array is also divided into many of them. | — |
| G | Granules should share one CRS, one pixel size, and a common lattice. | Different projections or a fractional origin offset mean the granules are not cells of one array, whatever their nominal resolution. Chunk alignment is positional and so depends on this: without a shared grid there is no array for the chunks to tile. | — |
| T | Time should be a dimension inside the file, shared by the data arrays. | Without one, the time coordinate has to be manufactured when the store is built rather than read. A dimension only one array declares is not a time axis the data is laid out on: it is either a time coordinate the data variables do not use, or, on the HDF4 path, a name the reader derived for that one array. | — |


## How each column was measured

**Sampling.** 246 granules across 64 collections (2 collections at 1, 2 collections at 2, 60 collections at 4). 8 of those were not opened: a collection is abandoned after its first granule exhausts the probe budget, since granules written by one producer share a chunk index layout. Granules are chosen adversarially rather than at random: the
two earliest in the record and the two latest, which is what exposes a producer changing chunk
shape or CF attributes mid-mission. The sample spans both orbit directions for MIL2TCST, which is where a shared projection with a different chunk origin can appear.

Four granules can refute stability but cannot establish it, and the two grades are therefore not
equally strong. A `D` or `F` rests on a counterexample: one pair of granules that disagree, or
one refusal that names a feature. An `A` or `B` rests on the absence of a counterexample in four
granules out of up to tens of millions, so it states that no blocker appeared in the sample, not
that none exists. The early-and-late design cuts the other way too: it is the sample most likely
to straddle a mid-mission format change, so a collection graded `D` because its 2002 granules
differ from its 2026 granules may virtualize cleanly over any recent span. The grade is a property
of the whole record, not of an arbitrary subset of it.

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
records 16 bytes for a 2400×2400 chunk. Where the recorded lengths are plausible but small, they
are reported as measured: `MCD43A3`'s 489-byte chunks are within what DEFLATE can do to a
100×2400 array that is almost entirely fill, and the number then describes the sampled tiles,
which are mostly empty, as much as the chunking.

**Grid aligned.** For GeoTIFF, from `ModelPixelScaleTag`, `ModelTiepointTag`, and the CRS GeoKey:
one origin in one CRS means one grid, several origins on a common lattice within one CRS mean one
grid at different extents, and a fractional offset means no shared grid. Origins are compared only
within a CRS. An easting and northing mean the same thing only in the same coordinate system, and
the MGRS-tiled products carry a different UTM zone per tile — `ECO_L2T_LSTE`'s four sampled
granules span EPSG:32641, 32642, and 32710 — so differencing their northings would subtract
coordinates that share no datum. Granules spanning several zones are reported as one grid per
tile: a cube per tile, not one cube over the archive. This separates two cases that look alike in
the catalog — `OPERA_L3_DSWX-HLS_V1`'s sampled granules all sit in EPSG:32656 on one 30 m lattice,
while `HLSL30`'s span three projections. The CRS is read from `ProjectedCSTypeGeoKey`, or from
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

**Which variables the criteria are evaluated on.** H2, H3, and S1 are evaluated on every array
that holds measured data and appears in at least two opened granules — not on a fixed-size slice
of the largest. Coordinate and index arrays are excluded, matched on the final path component
against a list of unambiguous names: a cube takes its coordinates from the combined index, so a
`lat` array chunked differently in two granules does not stop those granules forming a cube, and
grading on one would report a blocker where none exists. GeoTIFF overview levels are excluded as
pyramid levels rather than variables, and arrays whose dtype has no fixed width — variable-length
and structured types, whose elements do not live in the chunk — are excluded because their size
cannot be compared. `virtualizability.csv` carries `headline_var`, `n_data_vars`, and
`n_comparable_vars` so the set each verdict was computed over is recoverable.

The offender count in the deciding-criterion column is therefore a count out of the whole product,
and it separates two cases the grade alone does not. Where the largest variable offends, no cube
is available over the product's principal array, which is a `D`. Where smaller variables offend
and the largest does not, a cube over the largest is available and the rest need rewriting, which
is a `B`. `MUR-JPL-L4-GLOB-v4.1` is the second case and shows why the early/late sample matters:
`analysed_sst` carries one chunk shape across the whole record, while `mask` is chunked
1×1447×2895 in 2002 and 1×1023×2047 in 2026. Sampling only recent granules would have graded the
collection clean.

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

**Granules.** CMR's hit count for the collection, as of 2026-09-22. A collection still
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

**Tooling.** VirtualiZarr 2.7.3, obstore 0.11.1, Zarr v3. VirtualiZarr supersedes kerchunk as
the interface, and its HDF5, DMR++, and Zarr parsers are native; its HDF4 and netCDF-3 parsers
still delegate to kerchunk internally, so kerchunk remains a dependency for those legacy formats.
VirtualiZarr 2.7.3 ships no TIFF parser, so GeoTIFF tile offsets and byte counts are read
directly from `TileOffsets` and `TileByteCounts`.

**Tool defects separated from data properties.** A grade should describe the archive, so one
VirtualiZarr defect is corrected before probing: `_extract_attrs` compares a converted attribute
against `"DIMENSION_SCALE"` without checking it is still a scalar, which raises `ValueError` on
any granule carrying an attribute of two or more fixed-length strings and aborts the whole file.
The probe installs a corrected version, in `scripts/vz_shims.py`. Without it, ICESat-2 ATL03
reads as unparseable when its
layout is in fact readable.

The remaining failures are left in place because no correction is available that does not risk a
wrong answer. The HDF4 path, which VirtualiZarr delegates to kerchunk, reads some of NASA's
HDF-EOS2 holdings and not others: of the eleven HDF4-container collections sampled, four yield
arrays on every granule, six raise on every granule in three distinct ways, and one —
`MIL2TCST` — returns a store holding no arrays at all on every granule, which is a failure the
call's own return value does not report. A parser that reports success and produces no chunk
manifest is graded as a failure to read the layout, since nothing downstream can be built from an
empty store. `MOD09GA` and `AIRS2RET` fail at
`hdf4.py:213`, where `_descend_vg` indexes the parsed `SD` tag's `data` field unconditionally;
that field holds the data-block references, so skipping the vgroup would produce arrays declaring
dimensions but no chunks. `MOD35_L2` and `MYD04_L2` fail because the backend derives a
dimension-name list whose length does not match the array's rank. The two ASDC HDF4 products fail
decoding a vgroup name as UTF-8. So HDF-EOS2 is not uniformly unreadable — readability varies by
producer, which means a grade here has to be measured per collection rather than inferred from
the format field.

Two refusals are properties of the files themselves. A granule that attaches more than one
dimension scale to a single axis is refused because a Zarr array names each axis once, which is
what excludes ICESat-2 `ATL11`. A granule that stores a string `_FillValue` on a numeric variable
is refused because Zarr's fill value is typed, which is what excludes `VNP09GA`.


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
30 collections are narrowed this way. Their grades describe a cube over one value of
the partition across the full time record — for a tiled product, a cube per tile, which is the
only cube its grid admits.

| Grade | Product | Narrowed to | Granules |
|---|---|---|---|
| B | Daymet_Daily_V4R1_2129 | the Puerto Rico region, tmin variable | 4 |
| B | ATL15 | region A1, monthly, 10 km | 1 |
| B | ECO_L2T_LSTE | MGRS tile 41SPS | 4 |
| B | HLSL30 | MGRS tile T59WNT | 4 |
| B | NISAR_L2_GCOV_PROVISIONAL_V1 | track 004 ascending, frame 018, DHDH polarization | 4 |
| B | NISAR_L2_GSLC_PROVISIONAL_V1 | track 004 ascending, frame 018, DHDH polarization | 4 |
| B | NISAR_L2_GUNW_PROVISIONAL_V1 | track 036 ascending, frame 163, across cycle pairs | 4 |
| B | NISAR_L3_SME2_PROVISIONAL_V1 | track 004 ascending, frame 018, DHDH polarization | 4 |
| B | PACE_OCI_L3M_BGC | daily composite at 4 km | 4 |
| B | SWOT_L2_HR_Raster_2.0 | 100 m raster, UTM zone 10T, pass 013, scene 114F — a calibration-orbit scene, so the sample covers 2023 alone | 4 |
| B | OPERA_L2_RTC-S1_V1 | track 063, burst 133239, subswath IW1 | 4 |
| B | OPERA_L3_DSWX-HLS_V1 | MGRS tile T56LPN | 4 |
| B | HLSS30 | MGRS tile T55JFH | 4 |
| B | MCD43A3 | sinusoidal tile h08v05 | 4 |
| B | MOD10A1 | sinusoidal tile h08v05 | 4 |
| B | MOD11A1 | sinusoidal tile h08v05 | 4 |
| B | MOD13Q1 | sinusoidal tile h08v05 | 4 |
| B | NSIDC-0776 | RGI region 03A | 4 |
| D | MODISA_L3m_CHL | daily composite at 4 km | 4 |
| D | NISAR_L1_RSLC_PROVISIONAL_V1 | track 004 ascending, frame 018, DHDH polarization | 4 |
| D | SPL2SMP_E | ascending half-orbits | 4 |
| D | SWOT_L2_HR_PIXC_2.0 | pass 166, tile 299L | 4 |
| D | SWOT_L2_LR_SSH_2.0 | the Basic product file | 4 |
| D | VIIRSN_L3m_CHL | daily composite at 4 km | 4 |
| D | TEMPO_NO2_L2 | mirror step G01 of each scan | 4 |
| F | GRACEFO_L2_JPL_MONTHLY_0063 | the GSM gravity-field product, solution BA01 | 4 |
| F | SRTMGL1 | the 1° tile at 0°N 13°E | 1 |
| F | VNP09GA | sinusoidal tile h08v05 | 4 |
| F | MIL2TCST | orbital path 020 | 4 |
| F | MOD09GA | sinusoidal tile h08v05 | 4 |


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
in common. 14 collections still differ, and each difference is one the sample keeps on
purpose — a counter that is the time step, or a change the archive really contains and a cube
really has to span.

| Grade | Product | Granules differ in | Kept because |
|---|---|---|---|
| B | GEDI02_A | O01753, O37238, T01683, T09057 | the orbit and track numbers index position along the record, not a partition |
| B | NISAR_L2_GCOV_PROVISIONAL_V1 | F, N, P | the mode and frame-coverage flags differ between acquisitions of one frame, which the fixed frame grid absorbs; the frame itself is pinned |
| B | NISAR_L2_GSLC_PROVISIONAL_V1 | F, N, P | the mode and frame-coverage flags differ between acquisitions of one frame, which the fixed frame grid absorbs; the frame itself is pinned |
| B | NISAR_L3_SME2_PROVISIONAL_V1 | F, N, P | the mode and frame-coverage flags differ between acquisitions of one frame, which the fixed frame grid absorbs; the frame itself is pinned |
| B | SPL4SMGP | Vv8010, Vv8011 | the two processing versions are both part of the record, and whether a cube spans a version change is the question rather than a nuisance to remove |
| B | OPERA_L2_RTC-S1_V1 | S1A, S1C | a burst is imaged by whichever Sentinel-1 satellite is overhead, so the platform changes within one cube by construction |
| B | OPERA_L3_DSWX-HLS_V1 | S2A, S2B | the product fuses Sentinel-2 and Landsat, so the platform changes within one cube by construction |
| B | TEMPO_NO2_L3 | S001, S002, S003, S004 | the scan number is the time step; every scan is the same CONUS grid |
| D | GEDI02_B | O01753, O37238, T01683, T09057 | the orbit and track numbers index position along the record, not a partition |
| D | NISAR_L1_RSLC_PROVISIONAL_V1 | F, N, P | the mode and frame-coverage flags differ between acquisitions of one frame, which the fixed frame grid absorbs; the frame itself is pinned |
| D | SWOT_L2_LR_SSH_2.0 | PGC0, PIC2 | the two processing versions are both part of the record; the product file is pinned |
| D | TEMPO_NO2_L2 | S001G01, S002G01, S003G01, S004G01 | the scan number is the time step; the mirror step within a scan is pinned |
| F | CAL_LID_L1-Standard-V4-51 | #ZD, #ZN | day and night granules are both part of the record |
| F | MIL2TCST | F06, F07, F08 | the three product versions are all part of the record; the orbital path is pinned |


## Coverage

64 collections, 246 granules opened or attempted.

Collections where not every sampled granule opened:

| Product | Opened | Attempted | Sampled | Reason |
|---|---|---|---|---|
| GEDI02_A | 1 | 2 | 4 | chunk index could not be read within the probe budget — exceeded the 480 s probe budget for one granule; not attempted: an earlier granule exhausted the probe budget |
| GEDI02_B | 3 | 4 | 4 | chunk index could not be read within the probe budget — exceeded the 480 s probe budget for one granule |
| AIRS2RET | 0 | 4 | 4 | HDF4 backend cannot read the HDF-EOS2 vgroup holding the data-block references |
| MYD04_L2 | 0 | 4 | 4 | HDF4 backend derived a dimension-name list of the wrong length for the array's rank |
| CER_SSF1deg-Day_Aqua-MODIS | 0 | 4 | 4 | HDF4 backend failed decoding a vgroup name as UTF-8; probe limit, not a data property — granule is 897 MB; above the 839 MB copy-to-disk limit for kerchunk-backed parsers |
| CAL_LID_L1-Standard-V4-51 | 0 | 4 | 4 | HDF4 backend failed decoding a vgroup name as UTF-8 |
| GRACEFO_L2_JPL_MONTHLY_0063 | 0 | 4 | 4 | no VirtualiZarr parser reads ASCII |
| ATL11 | 0 | 4 | 4 | file attaches several dimension scales to one axis; a Zarr array names each axis once |
| SRTMGL1 | 0 | 1 | 1 | no VirtualiZarr parser reads HGT |
| VNP09GA | 0 | 4 | 4 | file stores a string _FillValue on a numeric variable; Zarr requires a number |
| MOD09GA | 0 | 4 | 4 | HDF4 backend cannot read the HDF-EOS2 vgroup holding the data-block references |
| MOD35_L2 | 0 | 4 | 4 | HDF4 backend derived a dimension-name list of the wrong length for the array's rank |
| M2I3NPASM | 0 | 1 | 4 | chunk index could not be read within the probe budget — exceeded the 480 s probe budget for one granule; not attempted: an earlier granule exhausted the probe budget |
| M2T1NXSLV | 0 | 1 | 4 | chunk index could not be read within the probe budget — exceeded the 480 s probe budget for one granule; not attempted: an earlier granule exhausted the probe budget |


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

For the second, each hard blocker gets its own control, and a control counts only when
VirtualiZarr's refusal names the same obstruction the criterion does — a collection that
refuses for an unrelated reason would make the grade right about the outcome by accident. H3
is exercised on a product whose swath length is not a multiple of its chunk length, and H2 on
a pair of granules that agree on the shape of every variable they share, so that differing
chunk shape is the only difference left and the refusal can only be about it.

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
| `.venv/bin/python scripts/verify_endtoend.py` | yes | builds virtual stores and checks the grades against them |

Stage 3 takes hours: every request pays an Earthdata Login redirect. Stages 2 and 3 accept a list
of collection short names to redo only those, merging into the existing sample and artifacts, which
is how a single collection is re-measured without repeating the run.

Because `results/probe/` is committed, stages 4 and 5 reproduce this file offline from a clone —
no credentials and no network. Adding a collection means adding a `Candidate` to `src/datasets.jl`,
and a collection partitioned by anything other than time also needs an entry in
`src/partitions.jl`.

This file is generated by stage 5 from `results/virtualizability.csv`. Edit the stage, not the
file.

