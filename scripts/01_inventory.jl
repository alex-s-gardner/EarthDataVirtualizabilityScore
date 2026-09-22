"""
Stage 1: resolve the curated dataset list against CMR and record the catalog-level facts.

Writes `results/inventory.csv`. Columns that CMR cannot answer (chunk shape, grid and chunk
alignment, metadata locality) are measured later from the granule files themselves.
"""

using EarthData, DataFrames, CSV, HTTP, JSON3, Dates

include(joinpath(@__DIR__, "..", "src", "datasets.jl"))

const RESULTS = joinpath(@__DIR__, "..", "results")

"""
    cmr_hits(; kwargs...) -> Int

Total number of CMR matches for a query, read from the `CMR-Hits` response header.

EarthData.jl returns only the `umm` block of each record, so the hit count is not available through
it; this reads the header directly.
"""
function cmr_hits(endpoint::AbstractString; kwargs...)
    query = ["page_size" => "0", (string(k) => string(v) for (k, v) in kwargs)...]
    r = HTTP.get("https://cmr.earthdata.nasa.gov/search/$endpoint"; query, status_exception=true)
    h = HTTP.header(r, "CMR-Hits", "")
    isempty(h) && error("CMR returned no CMR-Hits header for $endpoint $(kwargs)")
    return parse(Int, h)
end

"""
    formats(c) -> String

Native file formats declared for a collection.

Reads both `FileDistributionInformation` and `FileArchiveInformation`: GES DISC populates only the
latter, so checking distribution alone reports no format for a large part of the archive.
"""
function formats(c)
    adi = c.ArchiveAndDistributionInformation
    isnothing(adi) && return ""
    out = Set{String}()
    for field in (:FileDistributionInformation, :FileArchiveInformation)
        entries = hasproperty(adi, field) ? getproperty(adi, field) : nothing
        isnothing(entries) && continue
        for e in entries
            f = get(e, :Format, get(e, "Format", nothing))
            isnothing(f) || push!(out, String(f))
        end
    end
    return join(sort(collect(out)), "+")
end

"""
    archiver(c) -> String

Short name of the data center that archives a collection, falling back to the first listed center
when no entry carries the `ARCHIVER` role.
"""
function archiver(c)
    dcs = c.DataCenters
    (isnothing(dcs) || isempty(dcs)) && return ""
    for dc in dcs
        roles = something(dc.Roles, String[])
        any(r -> occursin("ARCHIVER", uppercase(r)), roles) && return dc.ShortName
    end
    return first(dcs).ShortName
end

"""
    temporal_span(c) -> Tuple{String,String}

Begin and end of a collection's temporal extent as ISO date strings; the end is `"present"` for
ongoing collections.
"""
function temporal_span(c)
    tes = c.TemporalExtents
    (isnothing(tes) || isempty(tes)) && return ("", "")
    for te in tes
        rdt = te.RangeDateTimes
        (isnothing(rdt) || isempty(rdt)) && continue
        r = first(rdt)
        stop = something(te.EndsAtPresentFlag, false) ? "present" :
               first(split(something(r.EndingDateTime, ""), "T"))
        return (first(split(something(r.BeginningDateTime, ""), "T")), stop)
    end
    return ("", "")
end

"""
    instrument(c) -> String

Platform/instrument pairs declared for a collection, joined for display.
"""
function instrument(c)
    ps = c.Platforms
    (isnothing(ps) || isempty(ps)) && return ""
    parts = String[]
    for p in ps
        instr = something(p.Instruments, [])
        if isempty(instr)
            push!(parts, p.ShortName)
        else
            for i in instr
                push!(parts, "$(p.ShortName)/$(i.ShortName)")
            end
        end
    end
    return join(unique(parts), ",")
end

"""
    s3_target(c) -> Tuple{String,String}

S3 bucket prefix and AWS region a collection is distributed from, or empty strings when the
collection carries no direct-distribution record.
"""
function s3_target(c)
    ddi = c.DirectDistributionInformation
    isnothing(ddi) && return ("", "")
    buckets = something(ddi.S3BucketAndObjectPrefixNames, String[])
    return (isempty(buckets) ? "" : first(buckets), something(ddi.Region, ""))
end

function build_inventory()
    rows = NamedTuple[]
    failures = String[]

    for cand in CANDIDATES
        label = something(cand.short_name, cand.keyword)
        c = try
            resolve(cand)
        catch e
            push!(failures, "$label: $(sprint(showerror, e))")
            continue
        end

        bucket, region = s3_target(c)
        t0, t1 = temporal_span(c)
        ngran = try
            cmr_hits("granules"; short_name=c.ShortName, version=c.Version)
        catch
            -1
        end

        push!(rows, (
            sensor = cand.sensor,
            short_name = c.ShortName,
            version = something(c.Version, ""),
            level = "L" * something(isnothing(c.ProcessingLevel) ? nothing : c.ProcessingLevel.Id, "?"),
            format = formats(c),
            daac = archiver(c),
            s3_bucket = bucket,
            s3_region = region,
            instrument = instrument(c),
            granules = ngran,
            time_begin = t0,
            time_end = t1,
            entry_title = something(c.EntryTitle, ""),
        ))
        println("  ok  $(rpad(c.ShortName, 34)) $(rpad(rows[end].level, 5)) $(rows[end].format)")
    end

    if !isempty(failures)
        @error "unresolved candidates" failures
        error("$(length(failures)) of $(length(CANDIDATES)) candidates did not resolve; " *
              "fix src/datasets.jl rather than proceeding with an incomplete ranking")
    end

    df = DataFrame(rows)
    mkpath(RESULTS)
    CSV.write(joinpath(RESULTS, "inventory.csv"), df)
    println("\n$(nrow(df)) collections -> results/inventory.csv")
    return df
end

build_inventory()
