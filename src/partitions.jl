"""
How each collection that is partitioned by something other than time is narrowed to one comparable
series of granules.

H2, H3, and S1 compare granules against each other, so they answer a question about one datacube only
when every granule sampled would belong to that cube. A collection partitioned by tile, band,
variable, resolution, subswath, or product type offers granules that no user would stack, and a
sample drawn without narrowing to one value of that partition measures the partition instead of the
archive.

Each entry gives a CMR `readable_granule_name` pattern and states what the pattern holds fixed. The
grade a pinned collection receives describes a cube over that one value across the whole time record —
for a tiled product, a cube per tile, which is the only cube its grid admits anyway.

Collections whose granule names differ only in a counter that *is* their time step are absent by
design: narrowing them would discard the time axis the criteria exist to test.
"""

"""
    Partition

One collection's narrowing: the CMR `readable_granule_name` pattern and what it holds fixed.
"""
struct Partition
    pattern::String
    pins::String
end

"""
    PARTITIONS

The pattern each partitioned collection is narrowed by, keyed by short name.

Patterns are validated against CMR before use: each matches a non-empty subset whose earliest and
latest granules still span the collection's record, so narrowing costs the early-and-late contrast
nothing. Two collections are exceptions and match exactly one granule, which is a property of the
product rather than of the pattern — `ATL15` and `SRTMGL1` publish one file per configuration or per
tile and have no time series within one, so their cross-granule criteria are correctly reported as
unmeasurable rather than computed across files a user would never stack.
"""
const PARTITIONS = Dict(
    # MODIS and VIIRS land products on the sinusoidal grid: one tile is one cube.
    "MOD09GA" => Partition("*h08v05*", "sinusoidal tile h08v05"),
    "MOD10A1" => Partition("*h08v05*", "sinusoidal tile h08v05"),
    "MOD11A1" => Partition("*h08v05*", "sinusoidal tile h08v05"),
    "MOD13Q1" => Partition("*h08v05*", "sinusoidal tile h08v05"),
    "MCD43A3" => Partition("*h08v05*", "sinusoidal tile h08v05"),
    "VNP09GA" => Partition("*h08v05*", "sinusoidal tile h08v05"),

    # MGRS-tiled optical products: one tile is one grid, so one tile is one cube.
    "HLSL30" => Partition("HLS.L30.T59WNT.*", "MGRS tile T59WNT"),
    "HLSS30" => Partition("HLS.S30.T55JFH.*", "MGRS tile T55JFH"),
    "ECO_L2T_LSTE" => Partition("*_41SPS_*", "MGRS tile 41SPS"),
    "OPERA_L3_DSWX-HLS_V1" => Partition("*T56LPN*", "MGRS tile T56LPN"),

    # A Sentinel-1 burst is the unit that repeats; track and subswath alone still move the footprint.
    "OPERA_L2_RTC-S1_V1" => Partition("*T063-133239-IW1*", "track 063, burst 133239, subswath IW1"),

    # Ocean-color L3: the collection holds several grid resolutions and several composite periods.
    "MODISA_L3m_CHL" => Partition("*.L3m.DAY.CHL.chlor_a.4km*", "daily composite at 4 km"),
    "VIIRSN_L3m_CHL" => Partition("*.L3m.DAY.CHL.chlor_a.4km*", "daily composite at 4 km"),
    "PACE_OCI_L3M_BGC" => Partition("*.L3m.DAY.BGC.*4km*", "daily composite at 4 km"),

    # SWOT: one raster resolution and one repeating scene; one of two product files.
    # No scene survives SWOT's move off the 1-day calibration orbit, so pinning one to make the
    # granules comparable confines the sample to the era that scene was imaged in.
    "SWOT_L2_HR_Raster_2.0" =>
        Partition("SWOT_L2_HR_Raster_100m_UTM10T_N_x_x_x_*_013_114F_*",
                  "100 m raster, UTM zone 10T, pass 013, scene 114F — a calibration-orbit scene, " *
                  "so the sample covers 2023 alone"),
    "SWOT_L2_LR_SSH_2.0" => Partition("SWOT_L2_LR_SSH_Basic_*", "the Basic product file"),

    # One glacier region of the ITS_LIVE mosaics.
    "NSIDC-0776" => Partition("NSIDC-0776_RGI03A_*", "RGI region 03A"),

    # Daymet publishes one file per region, variable, and year.
    "Daymet_Daily_V4R1_2129" =>
        Partition("*daymet_v4_daily_pr_tmin_*", "the Puerto Rico region, tmin variable"),

    # GRACE-FO ships the gravity field and three de-aliasing products in one collection.
    "GRACEFO_L2_JPL_MONTHLY_0063" =>
        Partition("GSM-2_*_GRFO_JPLEM_BA01_*", "the GSM gravity-field product, solution BA01"),

    # A MISR path is the repeating ground track.
    "MIL2TCST" => Partition("*_P020_*", "orbital path 020"),

    # Ascending and descending half-orbits carry the same projection with a different chunk origin.
    "SPL2SMP_E" => Partition("*_A_*", "ascending half-orbits"),

    # A TEMPO scan is split into granules by mirror step; one step is one latitude band.
    "TEMPO_NO2_L2" => Partition("*G01.nc", "mirror step G01 of each scan"),

    # One cumulative file per region, period, and resolution: no time series exists within one.
    "ATL15" => Partition("ATL15_A1_*_1mo_10km_*", "region A1, monthly, 10 km"),

    # One file per 1° tile of a single-epoch DEM.
    "SRTMGL1" => Partition("N00E013*", "the 1° tile at 0°N 13°E"),
)

"""
    DIFFERENCES_KEPT

Name differences deliberately left in a sample, with the reason for keeping them.

A difference is kept when narrowing it away would remove the thing the criteria are meant to test: a
counter that is the time step, or a change the archive really contains and a cube really has to span.
Recorded here so that a granule name still varying is a decision rather than an omission. A
collection can appear both here and in `PARTITIONS` — one difference narrowed, another kept.
"""
const DIFFERENCES_KEPT = Dict(
    "TEMPO_NO2_L3" => "the scan number is the time step; every scan is the same CONUS grid",
    "TEMPO_NO2_L2" => "the scan number is the time step; the mirror step within a scan is pinned",
    "GEDI02_A" => "the orbit and track numbers index position along the record, not a partition",
    "GEDI02_B" => "the orbit and track numbers index position along the record, not a partition",
    "CAL_LID_L1-Standard-V4-51" =>
        "day and night granules are both part of the record",
    "SPL4SMGP" =>
        "the two processing versions are both part of the record, and whether a cube spans a " *
        "version change is the question rather than a nuisance to remove",
    "SWOT_L2_LR_SSH_2.0" =>
        "the two processing versions are both part of the record; the product file is pinned",
    "MIL2TCST" =>
        "the three product versions are all part of the record; the orbital path is pinned",
    "OPERA_L2_RTC-S1_V1" =>
        "a burst is imaged by whichever Sentinel-1 satellite is overhead, so the platform changes " *
        "within one cube by construction",
    "OPERA_L3_DSWX-HLS_V1" =>
        "the product fuses Sentinel-2 and Landsat, so the platform changes within one cube by " *
        "construction",
)

"""
    partition_for(short_name) -> Union{Partition,Nothing}

The narrowing for one collection, or `nothing` where its granules need none.
"""
partition_for(short_name) = get(PARTITIONS, String(short_name), nothing)
