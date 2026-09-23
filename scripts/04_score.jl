"""
Stage 4: apply the virtualizability criteria to the stage 3 probe artifacts.

Reads every `results/probe/*.json`, joins each to its catalog row from `results/inventory.csv`, and
writes `results/virtualizability.csv` ranked best-first. Runs offline.
"""

using JSON3, CSV, DataFrames, Statistics

include(joinpath(@__DIR__, "..", "src", "naming.jl"))
include(joinpath(@__DIR__, "..", "src", "partitions.jl"))
include(joinpath(@__DIR__, "..", "src", "structure.jl"))
include(joinpath(@__DIR__, "..", "src", "criteria.jl"))

const RESULTS = joinpath(@__DIR__, "..", "results")
const PROBE = joinpath(RESULTS, "probe")

"""
    GRADE_ORDER

Sort key for grades, best first. `F*` sorts above `F`: neither is readable by the tooling measured
here, but an `F*` archive already holds the byte ranges a manifest is made of, so it is the closer of
the two to a cube. `U` sorts last: it is not a worse archive than `F` but an unmeasured one.
"""
const GRADE_ORDER = Dict("A" => 1, "B" => 2, "C" => 3, "D" => 4, "F*" => 5, "F" => 6, "U" => 7)

"""
    status_cell(v::Verdict) -> String

A verdict rendered for the table: yes, no, partial, or an em dash when the criterion was not
settled.
"""
status_cell(v::Verdict) = v.status === :yes ? "yes" :
                          v.status === :no ? "no" :
                          v.status === :partial ? "partial" : "—"

"""
    chunk_cell(a) -> String

Chunk alignment as one cell: whether the granules' chunks tile one array.

Alignment is positional, so it presupposes a grid for the chunks to be positioned on. Consistent chunk
shapes (H2) and a divisible concatenation axis (H3) are necessary but say nothing on their own about
where a chunk sits: granules in different projections can agree on chunk shape exactly while sharing
no array for those chunks to fill. So `yes` requires a grid as well, and a collection whose grid went
unmeasured reads `—` with the H2 and H3 results kept in their own columns. A failure of H2 or H3 is
reported whatever the grid, since it rules out one array by itself.
"""
function chunk_cell(a)
    (a.chunks.status === :no || a.concat.status === :no) && return "no"
    (a.chunks.status in (:unknown, :unmeasured) ||
     a.concat.status in (:unknown, :unmeasured)) && return "—"
    return a.grid.status in (:yes, :partial) ? "yes" : "—"
end

"""
    headline_chunk(a) -> Tuple{String,Float64}

Chunk shape and median stored chunk size in MB for the largest variable, which is the layout a user
of the cube actually meets.

The size is the median across granules of the same variable P-sz judges, so the column and the
deciding criterion report one number rather than two statistics of different variables. It is `NaN`
where the recorded length could not be a chunk length, which is the same test P-sz applies.
"""
function headline_chunk(a)
    isempty(a.main_vars) && return ("—", NaN)
    vs = get(a.records, first(a.main_vars), [])
    isempty(vs) && return ("—", NaN)
    chunk = chunks_of(first(vs))
    sizes = [b for b in stored_bytes.(vs) if !isnothing(b)]
    return (isempty(chunk) ? "contiguous" : join(string.(chunk), "×"),
            isempty(sizes) ? NaN : median(sizes) / 1e6)
end

"""
    sample_consistency(rec) -> String

How the sampled granules differ from each other beyond their timestamps, or `""` when they differ
only there.

A criterion comparing two granules answers a question about one cube only when both granules would
belong to that cube. Where a collection is partitioned by variable, band, tile, resolution, or
subswath, a sample drawn without pinning that partition compares files a user would never stack, so
the difference is reported next to the grade it produced rather than left for the reader to infer
from the granule names.

The comparison is mechanical and does not judge which differences matter: for a product whose
granule name encodes its time step as a counter rather than a date, the counter shows up here, and
reading it as a partition is the reader's job.
"""
function sample_consistency(rec)
    urls = [String(p.url) for p in rec.probes if haskey(p, :url)]
    length(urls) < 2 && return ""
    sets = content_tokens.(urls)
    shared = reduce(intersect, sets)
    differing = sort(collect(reduce(union, sets) |> s -> setdiff(s, shared)))
    return join(differing, ", ")
end

"""
    volume_tb(rec) -> Float64

Archive volume in TB, estimated as the median sampled granule size times the collection's granule
count.
"""
function volume_tb(rec, ngranules)
    szs = [p.file_bytes for p in opened(rec.probes) if haskey(p, :file_bytes)]
    (isempty(szs) || ngranules <= 0) && return NaN
    return median(szs) * ngranules / 1e12
end

function score_all()
    inv = CSV.read(joinpath(RESULTS, "inventory.csv"), DataFrame)
    byname = Dict(row.short_name => row for row in eachrow(inv))

    files = sort(filter(f -> endswith(f, ".json"), readdir(PROBE)))
    isempty(files) && error("no probe artifacts in $PROBE; run scripts/03_probe.py first")

    rows = NamedTuple[]
    for f in files
        rec = JSON3.read(read(joinpath(PROBE, f), String))
        sn = String(rec.short_name)
        haskey(byname, sn) || error("probe artifact $f has no inventory row for \"$sn\"")
        cat = byname[sn]
        a = assess(rec)
        # A grade of F or U reports that nothing was read, which leaves open whether the collection
        # has a cube at all. That question is answered from the catalog record, and it is answered for
        # every such collection or not at all.
        a.grade in ("F", "U") && !haskey(CUBE_AXES, sn) &&
            error("$sn graded $(a.grade) with no CUBE_AXES entry: add one in src/structure.jl " *
                  "stating what a cube over its record would be indexed by, or the report cannot " *
                  "say whether the grade is a container choice or an absence of structure")

        # An F whose blocks stage 6 found addressable is an F*: the archive holds what a manifest
        # needs and no reader here reaches it, which asks nothing of the producer.
        grade, blocker = a.grade, a.blocker
        if grade == "F"
            gap = reader_gap(sn)
            if isnothing(gap)
                fb = something(file_blocker(sn), diagnosis_open(sn), nothing)
                isnothing(fb) || (blocker = "$blocker; $fb")
            else
                (grade, blocker) = ("F*", "$blocker; $gap")
            end
        end
        shape, chunkmb = headline_chunk(a)
        dmrpp = any(get(p, :dmrpp, false) for p in rec.probes)

        push!(rows, (
            grade,
            sensor = cat.sensor,
            short_name = sn,
            level = cat.level,
            format = cat.format,
            daac = cat.daac,
            s3_region = coalesce(cat.s3_region, ""),
            consolidated_md = status_cell(a.locality),
            grid_aligned = status_cell(a.grid),
            chunk_aligned = chunk_cell(a),
            time_dim = status_cell(a.time),
            chunk_shape = shape,
            chunk_mb = round(chunkmb; digits = 3),
            n_granules = cat.granules,
            volume_tb = round(volume_tb(rec, cat.granules); digits = 3),
            dmrpp = dmrpp ? "yes" : "no",
            blocker,
            chunk_shape_stable = status_cell(a.chunks),
            concat_ok = status_cell(a.concat),
            cf_stable = status_cell(a.cf),
            headline_var = isempty(a.main_vars) ? "" : first(a.main_vars),
            n_data_vars = length(a.main_vars),
            n_comparable_vars = a.n_comparable,
            chunk_evidence = a.chunks.note,
            concat_evidence = a.concat.note,
            md_evidence = a.locality.note,
            grid_evidence = a.grid.note,
            size_evidence = a.size.note,
            time_evidence = a.time.note,
            sample_differs = sample_consistency(rec),
            pinned_to = (p = partition_for(sn); isnothing(p) ? "" : p.pins),
            difference_kept_because = get(DIFFERENCES_KEPT, sn, ""),
            cube_axes = get(CUBE_AXES, sn, ""),
            record_span = "$(cat.time_begin) to $(coalesce(cat.time_end, "present"))",
            orbit_dirs = join(sort(unique(filter(!isempty,
                                                 [String(get(p, :orbit, "")) for p in rec.probes]))), "/"),
            n_probed = length(opened(rec.probes)),
            n_attempted = count(p -> get(p, :attempted, true), rec.probes),
            n_sampled = length(rec.probes),
            unopened = unopened_reason(rec.probes),
        ))
    end

    df = DataFrame(rows)
    sort!(df, [order(:grade; by = g -> GRADE_ORDER[g]), :sensor, :short_name])
    CSV.write(joinpath(RESULTS, "virtualizability.csv"), df)

    println("$(nrow(df)) collections scored -> results/virtualizability.csv")
    for g in sort(collect(keys(GRADE_ORDER)); by = k -> GRADE_ORDER[k])
        n = count(==(g), df.grade)
        n > 0 && println("  $g: $n")
    end
    return df
end

score_all()
