"""
Stage 2: pick the granules that will be opened in stage 3.

Sampling is adversarial rather than random: chunk misalignment shows up when granules that a user
would want in one datacube differ from each other, so the sample deliberately pairs granules that
are adjacent in time, on opposite orbit directions, and years apart, and spreads further draws
through the interior of the record, where a change that was later reverted lives.

Writes `results/granule_sample.json`.
"""

using EarthData, DataFrames, CSV, JSON3, Dates, HTTP

include(joinpath(@__DIR__, "..", "src", "naming.jl"))
include(joinpath(@__DIR__, "..", "src", "partitions.jl"))

const RESULTS = joinpath(@__DIR__, "..", "results")
const N_PER_PAIR = 2

"""
    orbit_direction(g) -> String

`"A"`, `"D"`, or `""` for a granule's orbit start direction.

Present only for swath products; gridded and model output carry no orbit record.
"""
function orbit_direction(g)
    se = g.SpatialExtent
    isnothing(se) && return ""
    hsd = se.HorizontalSpatialDomain
    isnothing(hsd) && return ""
    orbit = hasproperty(hsd, :Orbit) ? hsd.Orbit : nothing
    isnothing(orbit) && return ""
    d = something(orbit.StartDirection, "")
    return isempty(d) ? "" : uppercase(first(d))
end

"""
    begin_time(g) -> String

Granule start time as an ISO string, or `""` when absent.
"""
function begin_time(g)
    te = g.TemporalExtent
    isnothing(te) && return ""
    if !isnothing(te.RangeDateTime)
        return something(te.RangeDateTime.BeginningDateTime, "")
    end
    return something(te.SingleDateTime, "")
end

"""
    SIDECAR

Extensions of files distributed alongside a science granule — browse imagery and detached metadata.

CMR lists these under the same `GET DATA` relation as the granule itself, so a first-match pick can
select a JPEG in place of the data file and turn a readable product into an unrecognized container.
"""
const SIDECAR = r"\.(jpg|jpeg|png|gif|xml|txt|met|hdr|cmr\.json)$"i

"""
    describe(g) -> Union{NamedTuple,Nothing}

Flatten a granule to the fields stage 3 needs, or `nothing` when it exposes no HTTPS data URL.

Every candidate HTTPS URL is kept, not just the first: a granule that distributes one file per band
or per subswath lists them all under the same relation, and which one is the right choice depends on
what the other granules of the sample offer.

Only HTTPS is recorded: NASA restricts direct S3 access to in-region clients, while the
HTTPS + Earthdata Login path works from anywhere.
"""
function describe(g)
    https = filter(u -> !occursin(SIDECAR, u), data_urls(g; scheme=:https))
    isempty(https) && return nothing
    s3 = urls(g; scheme=:s3, type="GET DATA VIA DIRECT ACCESS")
    return (
        granule_ur = g.GranuleUR,
        candidates = String.(https),
        url = String(first(https)),
        s3 = isempty(s3) ? "" : first(s3),
        begin_time = begin_time(g),
        orbit = orbit_direction(g),
        size_mb = something(granule_size(g), -1) / 1e6,
    )
end

"""
    pin_asset(picked) -> Vector{NamedTuple}

Choose one asset per granule so that every granule of the sample contributes the same kind of file.

A granule that distributes one file per band, polarization, or subswath offers several data URLs, and
taking the first of each leaves the sample comparing a band of one scene against a different band of
another — a difference in chunk shape then says nothing about whether the archive can be one cube.
The asset the most granules offer is chosen, and a granule that does not offer it keeps its first
candidate, since dropping the granule would shrink the sample without making it comparable.

This pins a partition only where the granule exposes it as a choice of object. A collection
partitioned at the granule level — one granule per variable, per tile, or per resolution — needs that
pinned in the CMR query instead, and stage 4 reports where the sample did not hold it fixed.
"""
function pin_asset(picked)
    keyed = [asset_keys(d.candidates) for d in picked]
    counts = Dict{String,Int}()
    for ks in keyed, k in keys(ks)
        counts[k] = get(counts, k, 0) + 1
    end
    isempty(counts) && return picked
    best = first(sort!(collect(keys(counts)); by = k -> (-counts[k], k)))
    return [haskey(ks, best) ? merge(d, (; url = ks[best])) : d
            for (d, ks) in zip(picked, keyed)]
end

"""
    glob_regex(pattern) -> Regex

A `*`-globbed granule-name pattern as an anchored regular expression.

Every character but `*` is matched literally, so the `.` that separates fields in most NASA granule
names cannot stand for any character.
"""
glob_regex(pattern) =
    Regex("^" * join([p == "*" ? ".*" : "\\Q" * p * "\\E"
                      for p in split(String(pattern), r"(?=\*)|(?<=\*)"; keepempty = false)]) * "\$")

# Granules requested per pattern query beyond the number kept, leaving room to discard the ones CMR
# returns whose UR does not match.
const OVERSAMPLE = 4

"""
    matching_urs(short_name, version, pattern, sort_key, n) -> Vector{String}

The URs of the first `n` granules whose UR matches `pattern`, in `sort_key` order.

CMR treats `*` in a granule name as a literal unless `options[readable_granule_name][pattern]` is
set, and that parameter is not a field of `EarthData.GranuleRequest`, so the pattern search is issued
directly. Only the URs are taken from it; the granule records themselves come back through
`EarthData.granules`, which resolves them by exact UR.

`readable_granule_name` matches a granule's producer ID as well as its UR, and the two differ: SWOT
gives its `Basic` and `WindWave` files one producer ID, so a pattern naming one of them returns both.
Each returned UR is therefore checked against the pattern here, which is the field the sample is
narrowed on.
"""
function matching_urs(short_name, version, pattern, sort_key, n; temporal = nothing)
    query = ["page_size" => string(OVERSAMPLE * n), "short_name" => short_name,
             "version" => version, "sort_key" => sort_key]
    isnothing(pattern) || append!(query, ["readable_granule_name" => pattern,
                                          "options[readable_granule_name][pattern]" => "true"])
    isnothing(temporal) || push!(query, "temporal" => temporal)
    r = HTTP.get("https://cmr.earthdata.nasa.gov/search/granules.umm_json";
                 query, status_exception = true)
    urs = String[String(it.umm.GranuleUR) for it in JSON3.read(r.body).items]
    isnothing(pattern) && return first(urs, n)
    re = glob_regex(pattern)
    return first(filter(u -> occursin(re, u), urs), n)
end

# Granules drawn from the interior of the record, in addition to the pairs at each end. A producer
# that changed chunk shape mid-mission and changed it back is invisible to the ends alone, and an
# interior granule is also where a swath length that varies by orbit shows up as an interior partial
# chunk rather than a trailing one.
const N_INTERIOR = 4

"""
    interior_windows(t0, t1, n) -> Vector{String}

`n` CMR `temporal` ranges covering the interior of a record, each one slice of `(t1 - t0) / (n + 1)`.

A window is a whole slice rather than a single day so that a collection publishing monthly, or
publishing in campaigns, still has granules inside it. The ends of the record are excluded: the pairs
drawn there already cover them.
"""
function interior_windows(t0::Date, t1::Date, n)
    days = Dates.value(t1 - t0)
    days > n + 1 || return String[]
    edge(i) = t0 + Day(round(Int, days * i / (n + 1)))
    return ["$(edge(i))T00:00:00Z,$(edge(i + 1))T00:00:00Z" for i in 1:n]
end

"""
    ends_of_record(short_name, version, part) -> Vector{String}

The URs at both ends of the record for the granules a partition admits.

The pattern narrows the collection to one comparable series; taking the earliest and latest of *that
series* keeps the early-and-late contrast the sample depends on, which selecting first and then
narrowing would lose.
"""
function ends_of_record(short_name, version, part)
    urs = String[]
    for sort_key in ("start_date", "-start_date")
        append!(urs, matching_urs(short_name, version, part.pattern, sort_key, N_PER_PAIR))
    end
    return unique(urs)
end

"""
    sample_granules(short_name, version, t0, t1) -> Vector

Up to eight granules for one collection: two adjacent at the start of the record, two from late in
it, four spread through its interior, and two of the opposite orbit direction where the product
records one.

The early/late split exposes producer changes to chunking or CF attributes; the interior draws expose
a change that was made and later reverted, which the ends agree across; the orbit split exposes
ascending/descending grids that share a projection but not a chunk origin. `t0` and `t1` bound the
record the interior is drawn from. Granules are returned in record order so that a stage reading only
the first few, or only the first and last, gets a defined subset rather than whichever ones a
dictionary happened to yield first.

A collection listed in `PARTITIONS` is narrowed to one comparable series first, and every granule —
the ends and the interior alike — is drawn from that series, so the granules compared are ones a
single cube would hold.
"""
function sample_granules(short_name, version, t0::Date, t1::Date)
    picked = Dict{String,NamedTuple}()
    add!(gs) = for g in gs
        d = describe(g)
        isnothing(d) || (picked[d.granule_ur] = d)
    end
    resolve!(urs) = isempty(urs) ||
        add!(granules(; short_name, version, granule_ur = unique(urs), page_size = length(urs)))

    part = partition_for(short_name)
    pattern = isnothing(part) ? nothing : part.pattern

    # Interior of the record, one granule per slice, taken within the partition where there is one.
    interior = String[]
    for window in interior_windows(t0, t1, N_INTERIOR)
        append!(interior, matching_urs(short_name, version, pattern, "start_date", 1;
                                      temporal = window))
    end

    if !isnothing(part)
        urs = ends_of_record(short_name, version, part)
        isempty(urs) && error("partition pattern \"$(part.pattern)\" matched no granule of " *
                              "$short_name $version; the pattern is stale")
        resolve!(vcat(urs, interior))
        ordered = sort!(collect(values(picked)); by = d -> (d.begin_time, d.granule_ur))
        return pin_asset(ordered)
    end

    common = (; short_name, version)

    # Earliest granules: adjacent in time, so their shared edges must line up.
    early = granules(; common..., sort_key="start_date", page_size=N_PER_PAIR)
    add!(early)

    # Latest granules: catches reprocessing that changed chunk shape or scale/offset mid-record.
    late = granules(; common..., sort_key="-start_date", page_size=N_PER_PAIR)
    add!(late)

    resolve!(interior)

    # Opposite orbit direction, when the product records one.
    dirs = unique(filter(!isempty, [d.orbit for d in values(picked)]))
    if length(dirs) == 1
        more = granules(; common..., sort_key="start_date", page_size=40)
        others = filter(g -> orbit_direction(g) ∉ ("", first(dirs)), more)
        add!(first(others, N_PER_PAIR))
    end

    ordered = sort!(collect(values(picked)); by = d -> (d.begin_time, d.granule_ur))
    return pin_asset(ordered)
end

"""
    build_sample()

Write `results/granule_sample.json` for every collection in the inventory.

Command-line arguments restrict the run to the named collections and merge them into the existing
sample, so one collection can be re-sampled without re-searching, or disturbing, the rest.
"""
function build_sample()
    inv = CSV.read(joinpath(RESULTS, "inventory.csv"), DataFrame)
    path = joinpath(RESULTS, "granule_sample.json")
    only = ARGS
    out = Dict{String,Any}()
    if !isempty(only)
        isfile(path) || error("$path missing; run without arguments to build the full sample first")
        out = copy(JSON3.read(read(path, String), Dict{String,Any}))
        rows = [r for r in eachrow(inv) if r.short_name in only]
        length(rows) == length(only) ||
            error("no inventory row for: $(setdiff(only, [r.short_name for r in rows]))")
        inv = DataFrame(rows)
    end

    for row in eachrow(inv)
        # A collection still ingesting carries `present` as its end date; the interior is drawn from
        # the record as it stands today.
        t1 = (ismissing(row.time_end) || row.time_end == "present") ? today() : Date(row.time_end)
        gs = try
            sample_granules(row.short_name, string(row.version), row.time_begin, t1)
        catch e
            @warn "granule search failed" row.short_name exception = e
            NamedTuple[]
        end
        out[row.short_name] = Dict(
            "sensor" => row.sensor,
            "version" => string(row.version),
            "level" => row.level,
            "format" => row.format,
            "daac" => row.daac,
            "granules" => gs,
        )
        dirs = join(unique(filter(!isempty, [g.orbit for g in gs])), "/")
        println("  $(rpad(row.short_name, 32)) $(length(gs)) granules $(isempty(dirs) ? "" : "[$dirs]")")
    end

    empties = [k for (k, v) in out if isempty(v["granules"])]
    isempty(empties) || @warn "collections with no usable HTTPS granule URL" empties

    open(path, "w") do io
        JSON3.pretty(io, out)
    end
    total = sum(length(v["granules"]) for v in values(out))
    println("\n$total granules across $(length(out)) collections -> results/granule_sample.json")
end

build_sample()
