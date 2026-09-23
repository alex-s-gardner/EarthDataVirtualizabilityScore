"""
Curated list of major NASA datasets to assess for virtualizability, and the CMR lookup that
resolves each to a concrete cloud-hosted collection.

Every entry must resolve. An entry that CMR cannot match is an error, not a row to drop: a silent
drop would make the ranking look more complete than it is.
"""

using EarthData

"""
    Candidate

One dataset to assess.

`short_name` is matched against CMR exactly. When it is `nothing`, `keyword` is used for a
free-text CMR search instead and the first cloud-hosted match whose short name contains
`expect` is taken.
"""
struct Candidate
    sensor::String
    short_name::Union{String,Nothing}
    keyword::Union{String,Nothing}
    expect::Union{String,Nothing}
end

Candidate(sensor, short_name) = Candidate(sensor, short_name, nothing, nothing)

"""
    CANDIDATES

Major NASA products spanning DAAC, sensor, and processing level. Short names carrying a `keyword`
instead are resolved at run time by [`resolve`](@ref).
"""
const CANDIDATES = [
    # NSIDC — cryosphere
    Candidate("ICESat-2/ATLAS", "ATL03")
    Candidate("ICESat-2/ATLAS", "ATL06")
    Candidate("ICESat-2/ATLAS", "ATL11")
    Candidate("ICESat-2/ATLAS", "ATL15")
    Candidate("Terra/MODIS", "MOD10A1")
    Candidate("SMAP/L-band radiometer", "SPL3SMP")
    Candidate("SMAP/L-band radiometer", "SPL4SMGP")
    Candidate("SMAP/L-band radiometer", "SPL2SMP_E")
    Candidate("SMAP/L-band radiometer", "SPL4CMDL")
    Candidate("multi-sensor (ITS_LIVE)", "NSIDC-0776")
    Candidate("ICESat-2/ATLAS", "ATL08")
    Candidate("ICESat-2/ATLAS", "ATL14")
    Candidate("GCOM-W1/AMSR2", "AU_SI12")
    Candidate("multi-sensor (passive microwave)", "NSIDC-0051")

    # LP DAAC — land
    Candidate("Terra/MODIS", "MOD09GA")
    Candidate("Terra+Aqua/MODIS", "MCD43A3")
    Candidate("Terra/MODIS", "MOD11A1")
    Candidate("Terra/MODIS", "MOD13Q1")
    Candidate("Suomi-NPP/VIIRS", "VNP09GA")
    Candidate("Landsat 8-9/OLI", "HLSL30")
    Candidate("Sentinel-2/MSI", "HLSS30")
    Candidate("ISS/EMIT", "EMITL2ARFL")
    Candidate("ISS/EMIT", "EMITL1BRAD")
    Candidate("ISS/GEDI", "GEDI02_A")
    Candidate("ISS/GEDI", "GEDI02_B")
    Candidate("Shuttle/SRTM", "SRTMGL1")
    Candidate("ISS/ECOSTRESS", "ECO_L2T_LSTE")
    Candidate("Terra+Aqua/MODIS", "MCD12Q1")
    Candidate("Suomi-NPP/VIIRS", "VNP13A1")
    Candidate("Terra/ASTER", nothing, "ASTER L1T radiance at sensor", "AST_L1T")

    # GES DISC — atmosphere and reanalysis
    Candidate("GPM/DPR+GMI", "GPM_3IMERGHH")
    Candidate("GPM/DPR+GMI", "GPM_3IMERGDF")
    Candidate("GPM/DPR", "GPM_2ADPR")
    Candidate("MERRA-2 (model)", "M2T1NXSLV")
    Candidate("MERRA-2 (model)", "M2I3NPASM")
    Candidate("Aqua/AIRS", "AIRS2RET")
    Candidate("Aura/OMI", "OMDOAO3")
    Candidate("NLDAS (model)", "NLDAS_FORA0125_H")
    Candidate("GLDAS (model)", "GLDAS_NOAH025_3H")
    Candidate("OCO-2", "OCO2_L2_Lite_FP")
    Candidate("Aqua/AIRS", nothing, "AIRS Level 3 daily standard physical retrieval", "AIRS3STD")
    Candidate("Suomi-NPP/OMPS", nothing, "OMPS Nadir Mapper total column ozone", "NMTO3")
    Candidate("Aura/MLS", nothing, "MLS Level 2 ozone mixing ratio", "ML2O3")

    # PO.DAAC — ocean and hydrology
    Candidate("multi-sensor (MUR SST)", "MUR-JPL-L4-GLOB-v4.1")
    Candidate("SWOT/KaRIn", "SWOT_L2_LR_SSH_2.0")
    Candidate("SWOT/KaRIn", "SWOT_L2_HR_Raster_2.0")
    Candidate("multi-sensor (OSTIA)", "OSTIA-UKMO-L4-GLOB-REP-v2.0")
    Candidate("AVHRR", "AVHRR_OI-NCEI-L4-GLOB-v2.1")
    Candidate("MetOp-A/ASCAT", "ASCATA-L2-Coastal")
    Candidate("SMAP/L-band radiometer", "SMAP_JPL_L3_SSS_CAP_MONTHLY_V5")
    Candidate("GRACE", "TELLUS_GRAC_L3_JPL_RL06_LND_v04")
    Candidate("GRACE-FO", nothing, "GRACE-FO monthly mass", "GRACEFO_L2")
    Candidate("Sentinel-1/C-SAR (OPERA)", "OPERA_L3_DSWX-HLS_V1")
    Candidate("Sentinel-6/Poseidon-4", nothing,
              "Sentinel-6A Michael Freilich Level 2 low resolution sea surface height", "S6A")
    Candidate("CYGNSS", nothing, "CYGNSS Level 3 ocean surface wind speed", "CYGNSS")
    Candidate("multi-sensor (OSCAR)", nothing, "OSCAR ocean surface current", "OSCAR")
    Candidate("GRACE-FO", "TELLUS_GRFO_L3_JPL_RL06.3_LND_v04")

    # ASDC — aerosol, cloud, radiation, air quality
    Candidate("CERES", "CERES_EBAF")
    Candidate("CERES", "CERES_EBAF-TOA")
    Candidate("Aqua/MODIS+CERES", "CER_SSF1deg-Day_Aqua-MODIS")
    Candidate("CALIPSO/CALIOP", "CAL_LID_L1-Standard-V4-51")
    Candidate("TEMPO", "TEMPO_NO2_L2")
    Candidate("TEMPO", "TEMPO_NO2_L3")
    Candidate("TEMPO", "TEMPO_HCHO_L3")
    Candidate("Terra/MISR", nothing, "MISR level 2 cloud", "MIL2")
    Candidate("Terra/MOPITT", nothing, "MOPITT derived CO retrievals", "MOP02")
    Candidate("CERES", "CER_SYN1deg-1Hour_Terra-Aqua-NOAA20")

    # OB.DAAC — ocean color
    Candidate("PACE/OCI", "PACE_OCI_L2_AOP")
    Candidate("PACE/OCI", "PACE_OCI_L3M_BGC")
    Candidate("Aqua/MODIS", "MODISA_L3m_CHL")
    Candidate("Suomi-NPP/VIIRS", "VIIRSN_L3m_CHL")

    # LAADS — L1B radiance and L2 atmosphere
    Candidate("Terra/MODIS", "MOD021KM")
    Candidate("Suomi-NPP/VIIRS", "VNP02MOD")
    Candidate("Terra/MODIS", "MOD35_L2")
    Candidate("Aqua/MODIS", "MYD04_L2")
    Candidate("NOAA-20/VIIRS", "VJ102MOD")

    # ASF and ORNL
    Candidate("Sentinel-1/C-SAR (OPERA)", "OPERA_L2_RTC-S1_V1")
    Candidate("Sentinel-1/C-SAR (OPERA)", nothing,
              "OPERA coregistered single look complex Sentinel-1", "CSLC")
    Candidate("Daymet (model)", "Daymet_Daily_V4R1_2129")
    Candidate("ISS/GEDI", nothing, "GEDI L4A aboveground biomass density", "GEDI_L4A")

    # NISAR — a mission whose products were specified for cloud access from the start, so its
    # layouts are the interesting comparison against archives that predate object storage.
    Candidate("NISAR/L-SAR", "NISAR_L1_RSLC_PROVISIONAL_V1")
    Candidate("NISAR/L-SAR", "NISAR_L2_GSLC_PROVISIONAL_V1")
    Candidate("NISAR/L-SAR", "NISAR_L2_GCOV_PROVISIONAL_V1")
    Candidate("NISAR/L-SAR", "NISAR_L2_GUNW_PROVISIONAL_V1")
    Candidate("NISAR/L-SAR", "NISAR_L3_SME2_PROVISIONAL_V1")

    # SWOT's pixel cloud is per-pixel water returns rather than a raster, which is a geometry none
    # of the other SWOT products here exercises.
    Candidate("SWOT/KaRIn", "SWOT_L2_HR_PIXC_2.0")
]

"""
    resolve(c::Candidate) -> EarthData.CollectionSchema.UMM_C

Return the cloud-hosted CMR collection for `c`, preferring the most recently revised version.

Throws if nothing matches, so an unresolvable dataset surfaces instead of vanishing from the
ranking.
"""
function resolve(c::Candidate)
    if !isnothing(c.short_name)
        cc = collections(; short_name=c.short_name, cloud_hosted=true, page_size=20)
        isempty(cc) && error("no cloud-hosted CMR collection for short_name=\"$(c.short_name)\"")
        return last(sort(cc; by=v -> something(v.Version, "")))
    end

    cc = collections(; keyword=c.keyword, cloud_hosted=true, page_size=100)
    isempty(cc) && error("no cloud-hosted CMR collection for keyword=\"$(c.keyword)\"")
    hits = filter(v -> occursin(c.expect, v.ShortName), cc)
    isempty(hits) && error(
        "keyword=\"$(c.keyword)\" matched $(length(cc)) collections, none with a short name " *
        "containing \"$(c.expect)\"; closest were: " *
        join(first.(getproperty.(cc[1:min(5, end)], :ShortName)), ", ")
    )
    return last(sort(hits; by=v -> (v.ShortName, something(v.Version, ""))))
end
