"""
What a datacube over an unreadable collection would be indexed by.

A collection whose layout no parser could read still has a shape in its catalog record: a processing
level, a granule cadence, and a temporal extent. Those settle whether the grade reports a container
that cannot be indexed or data that has no cube in it, which the criteria themselves cannot
distinguish, since they need a parsed file to say anything at all.

Entries are read from CMR — level, title, granule cadence, temporal extent — and not from a
measurement. Every collection graded `F` needs one; stage 4 errors if it is missing.
"""

"""
    CUBE_AXES

Axes a cube over each unparseable collection would carry, and the geometry they come from.
"""
const CUBE_AXES = Dict(
    "AIRS2RET" => "time × along-track scan × cross-track footprint, one granule per 6-minute " *
                  "retrieval",
    "MYD04_L2" => "time × along-track × across-track, one granule per 5-minute swath",
    "MOD35_L2" => "time × along-track × across-track, one granule per 5-minute swath",
    "MOD09GA" => "time × y × x per sinusoidal tile, one granule per tile per day",
    "VNP09GA" => "time × y × x per sinusoidal tile, one granule per tile per day",
    "CER_SSF1deg-Day_Aqua-MODIS" => "time × latitude × longitude on a global 1° grid, daily",
    "CAL_LID_L1-Standard-V4-51" => "time × along-track profile × altitude, one granule per orbit " *
                                   "segment",
    "MIL2TCST" => "time × along-track × across-track per orbital path",
    "ATL11" => "reference point × cycle, a land-ice height time series per region",
    "SRTMGL1" => "y × x on a global 1 arc-second lattice tiled at 1°, and no time axis: the record " *
                 "is one 11-day mission",
    "GRACEFO_L2_JPL_MONTHLY_0063" => "time × spherical-harmonic degree × order, monthly — the one " *
                                     "record here with no spatial axis",
    "M2T1NXSLV" => "time × latitude × longitude, hourly single-level fields, one granule per day",
    "M2I3NPASM" => "time × pressure level × latitude × longitude, 3-hourly, one granule per day",
    "AIRS3STD" => "time × latitude × longitude on a global 1° grid, daily",
    "CER_SYN1deg-1Hour_Terra-Aqua-NOAA20" =>
        "time × latitude × longitude on a global 1° grid, hourly",
    "MCD12Q1" => "time × y × x per sinusoidal tile at 500 m, one granule per tile per year",
    "VNP13A1" => "time × y × x per sinusoidal tile at 500 m, one 16-day composite per granule",
    "MOP02T" => "time × along-track retrieval × pressure level, one granule per day",
    "ML2O3_NRT" => "time × profile × pressure level, one granule per orbit segment",
    "OMPS_NPP_NMTO3_L3_DAILY" => "time × latitude × longitude on a global 1° grid, daily",
    "AU_SI12" => "time × y × x on the 12.5 km polar stereographic grids of both hemispheres, daily",
    "NSIDC-0051" => "time × y × x on one hemisphere's polar stereographic grid, daily",
    "GEDI_L4A_AGB_Density_V3_2508" =>
        "shot × beam along one orbit, a footprint-level biomass record rather than a grid",
    "AST_L1T" =>
        "y × x per scene, and no cube over the archive: the scenes are acquisitions at different " *
        "places rather than slices of one array",
)

# Codecs a Zarr chunk manifest can decode a stored block with. A block coded any other way is one
# stream nothing can take a chunk out of, which is a property of the file rather than of the reader.
const ZARR_CODECS = ("DEFLATE", "NONE")

# HDF5 filters a Zarr codec chain reproduces. A filter outside this set leaves a stored chunk that a
# Zarr reader cannot decode, which no manifest fixes.
const ZARR_FILTERS = ("gzip", "shuffle", "fletcher32", "zstd", "blosc")

const DIAGNOSE = joinpath(@__DIR__, "..", "results", "diagnose")

"""
    reader_gap(short_name) -> Union{Nothing,String}

Why a refused collection's bytes are already addressable, or `nothing` where they are not.

A refusal says a reader stopped. It does not say whether the file holds the byte ranges a chunk
manifest is made of, and the two call for opposite things: an archive whose blocks are addressable
and whose encoding Zarr can express needs no change from its producer, while one storing a string
fill value, several dimension scales on an axis, a codec Zarr has no decoder for, or a single
compressed stream does. Stage 6 records which, and this reduces that record to the sentence the
grade rests on.

Returns `nothing` when no diagnosis exists, so a collection is never credited with a property that
was not measured.
"""
function reader_gap(short_name)
    path = joinpath(DIAGNOSE, "$short_name.json")
    isfile(path) || return nothing
    rec = JSON3.read(read(path, String))
    reasons = String[]
    for d in rec.diagnoses
        f = get(d, :findings, nothing)
        isnothing(f) && return nothing
        c = String(get(d, :container, ""))
        if c == "hdf5"
            isempty(f.unencodable_fill_values) || return nothing
            isempty(f.multi_scale_axes) || return nothing
            isempty(f.unfixed_dtypes) || return nothing
            filters = sort(String.(collect(keys(f.filters))))
            all(k in ZARR_FILTERS for k in filters) || return nothing
            push!(reasons, "every one of $(f.n_datasets) arrays is stored under a filter a Zarr " *
                           "codec chain reproduces" *
                           (isempty(filters) ? "" : " ($(join(filters, ", ")))"))
        elseif c == "hdf4"
            sd = f.scientific_data_tags
            codecs = sort(String.(union(keys(sd.chunked_elements.codecs),
                                       keys(sd.compressed_elements.codecs))))
            all(k in ZARR_CODECS for k in codecs) || return nothing
            nchunks = sd.chunked_elements.total_chunks
            ncomp = sum(values(sd.compressed_elements.codecs); init = 0)
            counted = String[]
            nchunks > 0 && push!(counted, "$nchunks chunk byte ranges")
            ncomp > 0 && push!(counted, "$ncomp whole-array compressed blocks")
            sd.contiguous > 0 && push!(counted, "$(sd.contiguous) contiguous blocks")
            isempty(counted) && return nothing
            coded = isempty(codecs) ? "" : " coded $(join(codecs, " and "))"
            site = get(f, :refusal_site, nothing)
            stopped = if !isnothing(site) && get(site, :raised, false) && haskey(site, :indexing)
                ix = site.indexing
                ix.extended === false ?
                    ", and the descriptor it stopped on ($(ix.tag) ref $(ix.ref)) is not extended, " *
                    "so the file states that block's offset and length outright" : ""
            else
                ""
            end
            push!(reasons, "the file carries $(join(counted, ", "))$coded$stopped")
        elseif c == "zip"
            f.all_stored || return nothing
            push!(reasons, "every zip member is stored rather than deflated, so each is a byte " *
                           "range of the archive")
        else
            return nothing
        end
    end
    isempty(reasons) && return nothing
    return "reader gap: " * join(unique(reasons), "; ")
end

"""
    diagnosis_open(short_name) -> Union{Nothing,String}

What a diagnosis left undetermined, where it established neither that the blocks are addressable nor
that the file holds something Zarr cannot express.

Absence of evidence is not evidence: without this, a collection stage 6 could not resolve would read
as one whose bytes were found unaddressable. The HDF4 linked-block list is the case that arises here —
its blocks are named by a list stage 6 does not follow, so nothing about addressability is settled.
"""
function diagnosis_open(short_name)
    path = joinpath(DIAGNOSE, "$short_name.json")
    isfile(path) || return nothing
    rec = JSON3.read(read(path, String))
    for d in rec.diagnoses
        f = get(d, :findings, nothing)
        isnothing(f) && continue
        String(get(d, :container, "")) == "hdf4" || continue
        sd = f.scientific_data_tags
        types = sort(String.(collect(keys(sd.extension_types))))
        sd.chunked_elements.total_chunks == 0 && isempty(sd.compressed_elements.codecs) &&
            sd.contiguous == 0 && !isempty(types) &&
            return "undetermined: every scientific-data element defers its blocks to a " *
                   "$(join(types, " or ")) list, which this probe does not follow, so whether the " *
                   "blocks are addressable is unmeasured rather than ruled out"
    end
    return nothing
end

"""
    file_blocker(short_name) -> Union{Nothing,String}

What stage 6 found in the file that a chunk manifest cannot describe, or `nothing` where it found no
such thing or was not run.

This is the other half of [`reader_gap`](@ref): the sentence a producer would act on, counted over the
arrays it applies to so that a blocker on a handful of auxiliary arrays is not read as one over the
whole product.
"""
function file_blocker(short_name)
    path = joinpath(DIAGNOSE, "$short_name.json")
    isfile(path) || return nothing
    rec = JSON3.read(read(path, String))
    out = String[]
    for d in rec.diagnoses
        f = get(d, :findings, nothing)
        isnothing(f) && continue
        c = String(get(d, :container, ""))
        if c == "hdf5"
            if !isempty(f.unencodable_fill_values)
                v = first(f.unencodable_fill_values)
                push!(out, "$(length(f.unencodable_fill_values)) of $(f.n_datasets) arrays store a " *
                           "_FillValue a Zarr array cannot hold — $(v.reason) on " *
                           "$(v.dtype) ($(v.dataset))")
            end
            if !isempty(f.multi_scale_axes)
                a = first(f.multi_scale_axes)
                push!(out, "$(length(f.multi_scale_axes)) of $(f.n_datasets) arrays attach " *
                           "$(a.n_scales) dimension scales to one axis ($(a.dataset) axis $(a.axis))")
            end
            if !isempty(f.unfixed_dtypes)
                names = join(String.([v.dataset for v in first(f.unfixed_dtypes, 2)]), ", ")
                push!(out, "$(length(f.unfixed_dtypes)) of $(f.n_datasets) arrays carry a dtype " *
                           "with no fixed element width, whose values live outside any chunk " *
                           "($names)")
            end
        elseif c == "hdf4"
            sd = f.scientific_data_tags
            bad = [String(k) for k in union(keys(sd.chunked_elements.codecs),
                                            keys(sd.compressed_elements.codecs))
                   if !(String(k) in ZARR_CODECS)]
            isempty(bad) ||
                push!(out, "blocks are coded $(join(sort(bad), ", ")), which Zarr has no decoder for")
        elseif c == "zip"
            f.all_stored ||
                push!(out, "the archive's members are deflated, so no chunk boundary exists inside " *
                           "one to point a range request at")
        elseif c == "text"
            push!(out, "the granule is text, which carries no byte offsets to index")
        end
    end
    isempty(out) && return nothing
    return "file: " * join(unique(out), "; ")
end
