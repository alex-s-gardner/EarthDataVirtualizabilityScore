"""
Evaluation of the virtualizability criteria against the stage 3 probe artifacts.

Each criterion reduces the per-granule measurements for one collection to a verdict plus the
evidence that produced it, so every cell of the final table can be traced to a measured number.
Criterion IDs match the table in `results/report.md`.
"""

using Statistics

"""
    NAMED_ITEMSIZE

Bytes per element for dtype spellings that name the type rather than its width.
"""
const NAMED_ITEMSIZE = Dict(
    "int8" => 1, "uint8" => 1, "bool" => 1,
    "int16" => 2, "uint16" => 2, "float16" => 2,
    "int32" => 4, "uint32" => 4, "float32" => 4,
    "int64" => 8, "uint64" => 8, "float64" => 8,
    "complex64" => 8, "complex128" => 16,
)

"""
    CODE_ITEMSIZE

Bytes per element for numpy type codes, byte-order prefix already stripped.
"""
const CODE_ITEMSIZE = Dict(
    "f2" => 2, "f4" => 4, "f8" => 8,
    "i1" => 1, "i2" => 2, "i4" => 4, "i8" => 8,
    "u1" => 1, "u2" => 2, "u4" => 4, "u8" => 8,
    "b1" => 1, "c8" => 8, "c16" => 16,
)

"""
    itemsize(dtype) -> Union{Int,Nothing}

Bytes per element for the dtype strings the probe records, or `nothing` when the type has no fixed
width.

A byte-order prefix does not change the width, so it is stripped; `S<n>` is a fixed-length byte
string of `n` bytes. `nothing` covers the variable-length and structured dtypes, whose elements do
not live in the chunk at all, and returning it keeps such an array out of the size ranking instead
of assigning it a width it does not have.
"""
function itemsize(dtype)
    s = String(dtype)
    haskey(NAMED_ITEMSIZE, lowercase(s)) && return NAMED_ITEMSIZE[lowercase(s)]
    code = lstrip(s, ['>', '<', '|', '='])
    haskey(CODE_ITEMSIZE, code) && return CODE_ITEMSIZE[code]
    m = match(r"^S(\d+)$", code)
    isnothing(m) || return parse(Int, m[1])
    return nothing
end

"""
    COORD_LEAVES

Array names that hold a coordinate, an index, or a grid definition rather than measured data.

A cube is built over the science variables; its coordinates come from the combined index, so a
coordinate array chunked differently in two granules does not stop those granules forming a cube.
Matching is on the final path component and only on names that are unambiguous, since a name like
`height` or `depth` is a coordinate in one product and the measurement in another.
"""
const COORD_LEAVES = Set([
    "lat", "latitude", "lon", "longitude", "x", "y", "xdim", "ydim",
    "time", "delta_time", "time_bnds", "time_bounds",
    "lat_bnds", "lon_bnds", "lat_bounds", "lon_bounds",
    "latitude_bnds", "longitude_bnds", "latitude_bounds", "longitude_bounds",
    "cell_lat", "cell_lon", "cell_row", "cell_column",
    "xcoordinates", "ycoordinates", "crs", "spatial_ref",
    "lev", "level", "nv", "bnds", "vertices", "wavelength", "fwhm",
    "yearday", "dayofyear", "day_of_year", "doy",
])

"""
    is_metadata(name) -> Bool

Whether an array sits in a group the producer set aside for metadata.

An orbit state vector or a processing record is not an array a cube is built over, and comparing its
chunk shape between granules answers no question about the science variables.
"""
is_metadata(name) = any(p -> lowercase(p) == "metadata", split(String(name), "/")[1:end-1])

"""
    LOCATING_ATTRS

Grid attributes that fix where a grid sits or how large its cells are.

`GeoTransform` gives an origin and a cell size outright; the projection parameters place the
projection's own origin. The remaining grid attributes the probe records — `crs_wkt`, `spatial_ref`,
`proj4`, `grid_mapping`, and the ellipsoid figures — name a coordinate system without locating
anything in it.
"""
const LOCATING_ATTRS = Set([
    "GeoTransform", "false_easting", "false_northing", "standard_parallel",
    "latitude_of_projection_origin", "longitude_of_central_meridian",
    "straight_vertical_longitude_from_pole",
])

"""
    SWATH_LEVELS

Processing levels whose geolocation is a per-pixel array rather than a grid.
"""
const SWATH_LEVELS = ("L1", "L1A", "L1B", "L2", "L2A", "L2B", "L2G")

"""
    Verdict

One criterion's outcome: a `status` symbol, a human-readable `note` naming the measured evidence,
and the criterion `id`.

`:unmeasured` is distinct from `:unknown`: it marks a criterion the probe was prevented from
evaluating, where `:unknown` marks one the recorded measurements do not settle.
"""
struct Verdict
    id::String
    status::Symbol
    note::String
end

ok(v::Verdict) = v.status === :yes

"""
    opened(probes) -> Vector

The probe records whose parser call succeeded.
"""
opened(probes) = [p for p in probes if get(p, :ok, false)]

"""
    rsplit_leaf(name) -> String

The final path component of a possibly nested array name.
"""
rsplit_leaf(name) = String(last(split(String(name), "/")))

"""
    is_coordinate(name) -> Bool

Whether an array name denotes a coordinate, index, or grid-definition array.
"""
is_coordinate(name) = lowercase(rsplit_leaf(name)) in COORD_LEAVES

"""
    fixed_string(dtype) -> Bool

Whether a dtype is a fixed-length byte string.

A byte-string array holds labels — a UTC timestamp, a version, a status word — and its size is set by
the declared string width rather than by how much data it carries, so ranking it against a numeric
array by uncompressed size puts it above the science variables it annotates.
"""
fixed_string(dtype) = !isnothing(match(r"^S\d+$", lstrip(String(dtype), ['>', '<', '|', '='])))

"""
    array_bytes(v) -> Union{Int,Nothing}

Uncompressed size of one array, or `nothing` when the array is not measured data of fixed width.
"""
function array_bytes(v)
    sh = something(v.shape, Int[])
    isempty(sh) && return nothing
    fixed_string(v.dtype) && return nothing
    w = itemsize(v.dtype)
    isnothing(w) && return nothing
    return prod(sh) * w
end

"""
    science_vars(probes) -> Tuple{Vector{String},Dict{String,Vector{Any}}}

The measured-data arrays of a collection, largest first, and their per-granule records.

Criteria are evaluated over every such array rather than over a fixed-size slice of the ranking, so
a count of offenders is a count out of the whole product and does not depend on where a cutoff falls
among arrays of equal size. Coordinate arrays, GeoTIFF overview levels, and arrays whose dtype has
no fixed width are excluded: none of them is data a cube is built over. Ties in size are broken by
name so the ranking, and therefore the variable the table reports, is fixed by the data rather than
by dictionary order.
"""
function science_vars(probes)
    sizes = Dict{String,Int}()
    recs = Dict{String,Vector{Any}}()
    for p in opened(probes), v in p.vars
        get(v, :overview, false) && continue
        (is_coordinate(v.name) || is_metadata(v.name)) && continue
        n = array_bytes(v)
        isnothing(n) && continue
        name = String(v.name)
        sizes[name] = max(get(sizes, name, 0), n)
        push!(get!(recs, name, []), v)
    end
    ranked = sort!(collect(keys(sizes)); by = n -> (-sizes[n], n))
    return ranked, recs
end

"""
    comparable(ranked, recs) -> Vector{String}

The arrays present in at least two opened granules, which are the ones a cross-granule criterion can
be evaluated on.
"""
comparable(ranked, recs) = [n for n in ranked if length(get(recs, n, [])) >= 2]

"""
    chunks_of(v) -> Vector{Int}

An array's internal chunk shape, or its full shape where the array is stored contiguously.

A contiguous array is one chunk covering the whole array, which is the shape a chunk manifest
records for it, so reporting the full shape keeps it comparable with a chunked granule of the same
variable.
"""
function chunks_of(v)
    c = something(v.chunks, Int[])
    return isempty(c) ? something(v.shape, Int[]) : c
end

"""
    transport_failure(probe) -> Bool

Whether a granule failed in the network rather than in the file.

A dropped connection or a refused request says nothing about how the granule was written, so it is
excluded from the parse verdict instead of being graded as a blocking feature.
"""
function transport_failure(probe)
    get(probe, :ok, false) && return false
    et = String(get(probe, :error_type, ""))
    m = String(get(probe, :error, ""))
    return et in ("GenericError", "ConnectionError", "TimeoutError") ||
           occursin("Generic HTTP error", m) || occursin("error sending request", m)
end

"""
    budget_exhausted(probe) -> Bool

Whether a granule's layout went unread because the probe's wall-clock budget ran out.

The budget bounds reads over authenticated HTTPS from outside `us-west-2`, where every request pays
an Earthdata Login redirect, so exhausting it is a property of the access path used here and not of
the granule. The blocks the reader did fetch before the budget expired are still a lower bound on
what the chunk index costs.
"""
function budget_exhausted(probe)
    (get(probe, :ok, false) || !get(probe, :attempted, true)) && return false
    return String(get(probe, :error_type, "")) in ("ProbeTimeout", "ProbeCrash")
end

"""
    attempted(probe) -> Bool

Whether the probe opened, or tried to open, this granule.
"""
attempted(probe) = get(probe, :attempted, true)

"""
    unmeasured(probe) -> Bool

Whether a granule's layout went unread for a reason outside the granule.

Covers a network failure, the probe's own ceiling on how large a file it will copy to disk for the
kerchunk-backed parsers, and the wall-clock budget. None is evidence about the archive, so counting
any of them as a refusal would claim a file property was observed where nothing was.
"""
function unmeasured(probe)
    get(probe, :ok, false) && return false
    return transport_failure(probe) || budget_exhausted(probe) || !attempted(probe) ||
           occursin("copy-to-disk limit", String(get(probe, :error, "")))
end

"""
    classify_refusal(error_type, message) -> String

A refusal message rewritten as the obstruction it represents.

Whether the obstruction lies in the file or in the reader changes what can be done about it, and the
raw exception text does not say which, so the recognized cases name it explicitly. An unrecognized
message is passed through rather than guessed at.
"""
function classify_refusal(error_type, message)
    m = String(message)
    error_type == "ProbeTimeout" &&
        return "chunk index could not be read within the probe budget — " * m
    error_type == "ProbeCrash" &&
        return "reader process died reading the chunk index — " * m
    error_type == "UnicodeDecodeError" &&
        return "HDF4 backend failed decoding a vgroup name as UTF-8"
    occursin("dimension scales attached", m) &&
        return "file attaches several dimension scales to one axis; a Zarr array names each axis once"
    occursin("KeyError", String(error_type)) && occursin("data", m) &&
        return "HDF4 backend cannot read the HDF-EOS2 vgroup holding the data-block references"
    occursin("fill_value", m) &&
        return "file stores a string _FillValue on a numeric variable; Zarr requires a number"
    occursin("same number of dimensions", m) &&
        return "HDF4 backend derived a dimension-name list of the wrong length for the array's rank"
    occursin("copy-to-disk limit", m) && return "probe limit, not a data property — " * m
    occursin("unrecognized container format", m) &&
        return "first bytes match no container signature the probe recognizes"
    occursin("Hdf5FeatureNotSupported", String(error_type)) &&
        return "HDF5 filter has no Zarr codec equivalent — " * first(m, 80)
    error_type == "NoParser" && return m
    occursin("no VirtualiZarr parser reads", m) && return m
    occursin("variable-length", m) &&
        return "variable-length data lives in the HDF5 global heap, outside any chunk"
    return "$(error_type): " * first(m, 90)
end

"""
    parse_verdict(probes) -> Verdict

Criterion H0: whether the VirtualiZarr parser accepted every granule it opened.

A refusal is decisive — the exception names the feature that stops a chunk manifest being written —
so this gates every criterion that depends on having read the file. Granules the probe never
attempted, and granules it abandoned on its own wall-clock budget, are counted separately: neither
is a refusal, and reporting them as one would attribute a limit of the measurement to the archive.
"""
function parse_verdict(probes)
    isempty(probes) && return Verdict("H0", :unmeasured, "no granules sampled")
    good = opened(probes)
    bad = [p for p in probes if !get(p, :ok, false) && !unmeasured(p)]
    n = length(good) + length(bad)
    n_budget = count(budget_exhausted, probes)
    n_skipped = count(p -> !attempted(p), probes)

    if isempty(good) && isempty(bad)
        n_budget > 0 && return Verdict("H0", :unmeasured,
                                       "no granule's layout was read: $n_budget of " *
                                       "$(length(probes)) exhausted the probe budget" *
                                       (n_skipped > 0 ? ", $n_skipped not attempted" : "") *
                                       "; nothing refused the file itself")
        return Verdict("H0", :unmeasured,
                       "no granule's layout was read; nothing refused the file itself")
    end

    why = isempty(bad) ? String[] :
          unique([classify_refusal(get(p, :error_type, "?"), get(p, :error, "")) for p in bad])
    isempty(good) && return Verdict("H0", :no, "parser refused all $n granules opened: " * first(why))

    # An empty store is not a read layout: a parser that returns no arrays yields no chunk manifest,
    # so there is nothing for a virtual store to serve however cleanly the call returned.
    all(p -> isempty(p.vars), good) &&
        return Verdict("H0", :no, "parser accepted all $(length(good)) granules but returned a " *
                                  "store with no arrays, so no chunk manifest can be written")

    isempty(bad) && return Verdict("H0", :yes, "$(length(good))/$n opened")
    return Verdict("H0", :partial, "$(length(good))/$n opened; " * first(why))
end

"""
    unopened_reason(probes) -> String

The distinct reasons the sampled granules that did not open failed.

A sample can fall short for a reason unrelated to the collection's grade — a request that failed in
transport says nothing about how the granule was written — so coverage needs its own explanation
rather than reusing the deciding criterion.
"""
function unopened_reason(probes)
    why = String[]
    for p in probes
        get(p, :ok, false) && continue
        if !attempted(p)
            push!(why, "not attempted: an earlier granule exhausted the probe budget")
        elseif transport_failure(p)
            push!(why, "request failed in transport, so this granule's layout is unmeasured")
        else
            push!(why, classify_refusal(get(p, :error_type, "?"), get(p, :error, "")))
        end
    end
    return join(unique(why), "; ")
end

"""
    chunk_stability(probes, ranked, recs) -> Verdict

Criterion H2: whether every opened granule uses the same internal chunk shape for each variable.

A variable chunked differently in different granules cannot be one Zarr array, because a Zarr v3
regular chunk grid has a single chunk shape. The verdict turns on the largest variable, which is the
array a user of the cube meets: when it is stable, a cube over it is available whatever the smaller
variables do, and the offender count says how much of the rest needs rewriting.
"""
function chunk_stability(probes, ranked, recs, grid)
    isempty(opened(probes)) && return Verdict("H2", :unmeasured, "no granule opened")
    cmp = comparable(ranked, recs)
    isempty(cmp) && return Verdict("H2", :unmeasured,
                                   "no data array appears in two opened granules")
    shapes_of(n) = unique([chunks_of(v) for v in recs[n]])
    offenders = [n for n in cmp if length(shapes_of(n)) > 1]
    if isempty(offenders)
        ev = "one chunk shape per variable across $(length(cmp)) variables in " *
             "$(length(opened(probes))) granules"
        # A granule stored as a single chunk spanning its whole array pins the cube's chunk shape to
        # that granule's exact dimensions, so H2 holds only while every granule in the archive shares
        # them. On a grid that is a property of the grid; on a swath, length varies with the orbit and
        # a sample of a few granules can agree by chance while the archive does not.
        whole = all(v -> chunks_of(v) == something(v.shape, Int[]), recs[first(cmp)])
        if whole && grid.status !== :yes
            why = grid.status === :no ?
                  "no grid holds these granules, so the length varies with the orbit and a few " *
                  "granules can agree by chance where the archive does not" :
                  "the grid went unmeasured, so whether every granule carries these dimensions is " *
                  "unestablished rather than observed"
            return Verdict("H2", :partial, ev * ", but each granule is one chunk spanning its whole " *
                                           "array, which pins the cube's chunk shape to these exact " *
                                           "dimensions, and " * why)
        end
        return Verdict("H2", :yes, ev)
    end
    worst = first(offenders)
    ev = "$(length(offenders)) of $(length(cmp)) variables — $worst: " *
         join(string.(shapes_of(worst)), " vs ")
    first(cmp) in offenders && return Verdict("H2", :no, "chunk shape differs across granules ($ev)")
    return Verdict("H2", :partial, "chunk shape differs for smaller variables ($ev); " *
                                   "$(first(cmp)) is stable, so a cube over it is available")
end

"""
    concat_alignment(probes, ranked, recs) -> Verdict

Criteria H1/H3: whether granules can be concatenated without producing an interior partial chunk.

Applies only to variables whose chunk shape is stable, since a variable failing H2 has no single
chunk grid for an alignment to be measured against. The concatenation axis is the dimension whose
length differs across granules; a variable whose length differs on two or more axes is not a stack
of slices at all but a set of different extents, which is reported as such. Along one varying axis,
every granule but the last must satisfy `size % chunk == 0`, so a single offending granule is
consistent with that granule being the last in the record and is reported as a risk rather than a
blocker; two or more put a short chunk in the array interior, which a Zarr v3 regular chunk grid
cannot express.
"""
function concat_alignment(probes, ranked, recs)
    isempty(opened(probes)) && return Verdict("H3", :unmeasured, "no granule opened")
    cmp = comparable(ranked, recs)
    isempty(cmp) && return Verdict("H3", :unmeasured,
                                   "no data array appears in two opened granules")

    blockers, risks, extents = String[], String[], String[]
    n_off = Set{String}()
    varying = false
    for name in cmp
        vs = recs[name]
        shapes = [something(v.shape, Int[]) for v in vs]
        chunks = unique([chunks_of(v) for v in vs])
        length(chunks) == 1 || continue
        chunk = first(chunks)
        (any(isempty, shapes) || isempty(chunk)) && continue
        ndim = length(chunk)
        all(s -> length(s) == ndim, shapes) || continue

        vary = [d for d in 1:ndim if length(unique([s[d] for s in shapes])) > 1]
        isempty(vary) && continue
        varying = true
        if length(vary) >= 2
            push!(extents, "$name: " * join([join(s, "×") for s in unique(shapes)], " vs "))
            push!(n_off, name)
            continue
        end
        d = first(vary)
        lens = [s[d] for s in shapes]
        off = [l for l in lens if l % chunk[d] != 0]
        isempty(off) && continue
        push!(n_off, name)
        msg = "$name dim $d: size $(first(off)) not a multiple of chunk $(chunk[d])"
        push!(length(off) >= 2 ? blockers : risks, msg)
    end

    if !isempty(extents)
        return Verdict("H3", :no, "granule extents differ on two or more axes " *
                                  "($(length(n_off)) of $(length(cmp)) variables), so the granules " *
                                  "are different regions rather than slices of one array — " *
                                  first(extents))
    end
    if !isempty(blockers)
        return Verdict("H3", :no, "interior partial chunk on concatenation " *
                                  "($(length(n_off)) of $(length(cmp)) variables) — " * first(blockers))
    end
    if !isempty(risks)
        return Verdict("H3", :partial, "one granule's length is not a multiple of the chunk, which " *
                                       "blocks concatenation unless it is the last in the record — " *
                                       first(risks))
    end
    varying && return Verdict("H3", :yes, "varying axis lengths are whole multiples of the chunk")
    return Verdict("H3", :yes, "granule shapes identical; concatenates on a new or length-one axis")
end

"""
    metadata_locality(probes) -> Verdict

Criterion P-md: whether a reader can reach the whole chunk index without walking the file.

Measured as the number of distinct 1 MiB blocks the parser fetched and how many contiguous runs they
formed. One run near the start of the file means the metadata is effectively consolidated and costs
a single range request; many scattered runs mean one get-request per region.

A granule whose parse failed still counts: the blocks its reader had fetched are a lower bound on
what the chunk index costs, and for a granule abandoned on the probe budget that bound is the
finding.
"""
function metadata_locality(probes)
    locs = [p.locality for p in probes
            if haskey(p, :locality) && !isnothing(p.locality) && get(p.locality, :n_blocks, 0) > 0]
    isempty(locs) && return Verdict("P-md", :unmeasured,
                                    "not measured (parser bypasses the instrumented reader)")
    blocks = median([l.n_blocks for l in locs])
    runs = median([l.contiguous_runs for l in locs])
    lead = median([something(l.leading_fraction, 0.0) for l in locs])
    ev = "median $(round(Int, blocks)) blocks in $(round(Int, runs)) runs, " *
         "$(round(Int, 100lead))% leading"
    isempty(opened(probes)) && return Verdict("P-md", :no, ev * "; index still unread when abandoned")
    runs <= 2 && blocks <= 4 && return Verdict("P-md", :yes, ev)
    runs <= 8 && return Verdict("P-md", :partial, ev)
    return Verdict("P-md", :no, ev)
end

"""
    shared_dims(probes) -> Dict{String,Int}

How many distinct arrays declare each dimension name.

A dimension that orders a cube is shared by the arrays laid out on it. The kerchunk HDF4 backend
synthesizes a private pair of dimension names per array instead, so a count of one means the name is
an artifact of that backend rather than a dimension of the product.
"""
function shared_dims(probes)
    users = Dict{String,Set{String}}()
    for p in opened(probes), v in p.vars
        isnothing(v.dims) && continue
        for d in v.dims
            push!(get!(users, lowercase(String(d)), Set{String}()), String(v.name))
        end
    end
    return Dict(k => length(v) for (k, v) in users)
end

"""
    time_named(name) -> Bool

Whether a dimension name denotes time.

Matched on whole `_`-separated tokens so that a name merely containing the letters, such as
`day_view_time_x`, is judged on its tokens rather than on a substring.
"""
function time_named(name)
    toks = split(lowercase(String(name)), r"[^a-z0-9]+"; keepempty = false)
    return any(t -> t in ("time", "times") || !isnothing(match(r"^n?times?\d*$", t)), toks)
end

"""
    canonical_time(name) -> Bool

Whether a dimension name is one of the plain spellings CF uses for a time axis.

A name a product chose for its time axis is short and unqualified; a compound name such as
`day_view_time_x` is a name the HDF4 backend derived from one array, and the distinction decides
whether an unshared dimension is a time coordinate the data is not laid out on or an artifact of
the reader.
"""
canonical_time(name) = !isnothing(match(r"^(n_?)?times?\d*$", lowercase(String(name))))

"""
    time_dimension(probes) -> Verdict

Criterion T: whether time is a dimension inside the file rather than only a filename field.

A file-internal time dimension is what lets granules stack into a cube directly; without one the
time coordinate has to be manufactured when the virtual store is built. A qualifying dimension is
shared by at least two arrays: a time axis the data is laid out on orders more than one array, while
the HDF4 backend derives a private dimension name per array that no other array shares.
"""
function time_dimension(probes)
    good = opened(probes)
    isempty(good) && return Verdict("T", :unmeasured, "no granule opened")
    users = shared_dims(good)
    n_arrays = sum(length([v for v in p.vars if !isnothing(v.dims)]) for p in good; init = 0)

    shared = sort([d for (d, n) in users if time_named(d) && (n >= 2 || n_arrays <= 1)])
    isempty(shared) || return Verdict("T", :yes, "dimension \"$(first(shared))\"")

    lone = sort([d for (d, n) in users if time_named(d)])
    own = filter(canonical_time, lone)
    isempty(own) ||
        return Verdict("T", :partial, "\"$(first(own))\" is a time coordinate, but no data array is " *
                                      "laid out on it, so a time axis has to be added when the " *
                                      "store is built")
    isempty(lone) ||
        return Verdict("T", :no, "\"$(first(lone))\" is declared by one array only, so it is a " *
                                 "per-array name rather than a shared time dimension")

    varnames = sort([lowercase(String(v.name)) for p in good for v in p.vars if time_named(v.name)])
    isempty(varnames) || return Verdict("T", :partial,
                                        "time variable \"$(first(varnames))\" but no time dimension")
    isempty(users) && return Verdict("T", :no, "file declares no dimension names")
    return Verdict("T", :no, "no time dimension")
end

"""
    varying_extent(probes, ranked, recs) -> Union{Verdict,Nothing}

A grid verdict when one variable spans a whole-number-multiple different number of cells between
granules, or `nothing` when no such variable exists.

Two granules of the same grid hold the same number of cells along each spatial axis. An axis whose
length doubles between granules is a coarser rendering of the same region, not a different extent of
one lattice, so the granules do not stack into a single array.
"""
function varying_extent(probes, ranked, recs)
    length(opened(probes)) < 2 && return nothing
    for name in comparable(ranked, recs)
        shapes = unique([something(v.shape, Int[]) for v in recs[name]])
        length(shapes) < 2 && continue
        length(unique(length.(shapes))) == 1 || continue
        a, b = shapes[1], shapes[2]
        ratios = [max(x, y) / min(x, y) for (x, y) in zip(a, b) if min(x, y) > 0 && x != y]
        isempty(ratios) && continue
        all(r -> abs(r - round(r)) < 1e-9 && r >= 2, ratios) || continue
        return Verdict("G", :no, "$name spans $(join(a, "×")) in one granule and " *
                                 "$(join(b, "×")) in another — the collection mixes resolutions")
    end
    return nothing
end

"""
    tiff_lattice(tiffs, px) -> Verdict

Whether GeoTIFF granules of `px`-metre pixels share one grid, from their CRS and tiepoint origins.

An easting and northing only mean the same thing in the same coordinate system, so origins are
compared within a CRS and never across one: the UTM tiles NASA distributes as MGRS products carry a
different zone per tile, and subtracting their northings would compare distances that share no datum.
Granules in several zones are one grid per tile — a cube per tile, not one cube over the archive.
"""
function tiff_lattice(tiffs, px)
    by_crs = Dict{String,Vector{Vector{Float64}}}()
    for t in tiffs
        tie = something(get(t, :tiepoint, nothing), Float64[])
        length(tie) >= 5 || continue
        push!(get!(by_crs, String(something(get(t, :crs, ""), "")), Vector{Float64}[]), tie[4:5])
    end
    isempty(by_crs) && return Verdict("G", :unknown, "no tiepoint recorded")
    haskey(by_crs, "") && return Verdict("G", :unknown,
                                         "granule declares no CRS, so origins are not comparable")

    offenders = String[]
    for (crs, origins) in by_crs
        os = unique(origins)
        length(os) < 2 && continue
        offs = [o .- first(os) for o in os]
        all(o -> all(x -> abs(rem(x, px, RoundNearest)) < 1e-6, o), offs) ||
            push!(offenders, "$crs: $(length(os)) origins off a common $(px) m lattice")
    end
    isempty(offenders) || return Verdict("G", :no, first(offenders))

    n_origin = sum(length(unique(v)) for v in values(by_crs))
    if length(by_crs) > 1
        return Verdict("G", :partial, "$(length(by_crs)) projections across $(n_origin) tile " *
                                      "origins ($(join(sort(collect(keys(by_crs))), ", "))) — " *
                                      "one grid per tile, each internally on a $(px) m lattice")
    end
    crs = first(keys(by_crs))
    n_origin == 1 && return Verdict("G", :yes, "one origin in $crs, $(px) m pixel")
    return Verdict("G", :partial, "one CRS ($crs) and one $(px) m lattice, $(n_origin) tile " *
                                  "extents — same grid, different extent")
end

"""
    grid_verdict(probes, level, ranked, recs) -> Verdict

Whether the opened granules share one spatial grid.

Three distinct outcomes matter and are reported separately: a single grid shared by every granule;
one projection per tile, so a cube is possible per tile but not across the archive; and no grid at
all, which is the normal case for L1/L2 swath data whose geolocation is a per-pixel coordinate array.
"""
function grid_verdict(probes, level, ranked, recs)
    good = opened(probes)
    isempty(good) && return Verdict("G", :unmeasured, "no granule opened")

    tiffs = [p.tiff_grid for p in good if haskey(p, :tiff_grid) && !isnothing(p.tiff_grid)]
    if !isempty(tiffs)
        scales = unique([something(t.pixel_scale, Float64[]) for t in tiffs])
        length(scales) > 1 && return Verdict("G", :no, "pixel size differs: $(scales)")
        px = first(first(scales))
        return tiff_lattice(tiffs, px)
    end

    # Coordinate values are read for only some granules, so a resolution change elsewhere in the
    # record would not reach `coordinate_grid`. Differing spatial extents for one variable settle the
    # question without them: granules of one grid hold the same number of cells per axis.
    resized = varying_extent(probes, ranked, recs)
    isnothing(resized) || return resized

    coord_v = coordinate_grid(good)
    isnothing(coord_v) || return coord_v

    gridded = Dict{String,Set{String}}()
    for p in good, v in p.vars, (k, val) in pairs(v.grid)
        push!(get!(gridded, String(k), Set{String}()), string(val))
    end
    for p in good, (k, val) in pairs(get(p, :root_attrs, (;)))
        push!(get!(gridded, String(k), Set{String}()), string(val))
    end
    # A grid needs an origin and a cell size. An attribute that only names a coordinate reference
    # system or its datum supplies neither, so granules agreeing on one have agreed on the meaning of
    # their coordinates and not on sharing a lattice — which a swath product does too.
    locating = filter(k -> k in LOCATING_ATTRS, keys(gridded))
    isempty(locating) && !isempty(gridded) &&
        return Verdict("G", something(level, "") in SWATH_LEVELS ? :no : :unknown,
                       (something(level, "") in SWATH_LEVELS ?
                        "swath geometry: " : "grid unmeasured: ") *
                       "granules agree on " * join(sort(collect(keys(gridded))), ",") *
                       ", which names a coordinate system without giving an origin or cell size")

    if isempty(gridded)
        lv = something(level, "")
        # A swath product has no grid by construction, which is a measured property. A gridded product
        # that reached this branch has one the probe could not see — the HDF-EOS2 path does not surface
        # `StructMetadata`, and a CRS held in a metadata subgroup is outside the attributes read here —
        # so the grid is unmeasured rather than absent, and claiming otherwise would invent a finding.
        lv in SWATH_LEVELS &&
            return Verdict("G", :no, "swath geometry: no projected grid, geolocation is a per-pixel array")
        return Verdict("G", :unknown, "no projection attribute or spatial coordinate array reached " *
                                      "the probe, so the grid is unmeasured, not absent")
    end
    varying = [k for (k, s) in gridded if length(s) > 1]
    isempty(varying) && return Verdict("G", :yes,
                                       "shared grid attributes (" * join(sort(collect(keys(gridded))), ",") * ")")
    return Verdict("G", :no, "grid attributes differ across granules: " * join(sort(varying), ","))
end

"""
    coordinate_grid(good) -> Union{Verdict,Nothing}

Grid verdict from measured spatial coordinate values, or `nothing` when none were read.

A regular latitude/longitude grid carries no `grid_mapping` attribute — CF treats it as implicit —
so the common gridded case has to be settled from the coordinates themselves. Comparing the measured
origin and spacing also catches two granules whose grids have equal dimensions but are offset by a
fraction of a cell, which a comparison of dimension sizes cannot see.
"""
function coordinate_grid(good)
    spatial = ("lat", "latitude", "lon", "longitude", "x", "y", "xdim", "ydim")
    per = Dict{String,Vector{Any}}()
    for p in good
        cs = get(p, :coords, nothing)
        isnothing(cs) && continue
        for (name, c) in pairs(cs)
            haskey(c, :first) || continue
            lowercase(rsplit_leaf(name)) in spatial || continue
            push!(get!(per, String(name), []), c)
        end
    end
    isempty(per) && return nothing

    axes_seen = sort(collect(keys(per)))
    n_compared = maximum(length.(values(per)))
    mismatched = String[]
    for (name, cs) in per
        length(cs) < 2 && continue
        origins = unique([round(c.first; digits = 9) for c in cs])
        steps = unique([round(c.step; digits = 9) for c in cs])
        counts = unique([c.n for c in cs])
        if length(steps) > 1
            push!(mismatched, "$name spacing $(join(steps, " vs "))")
        elseif length(counts) > 1
            push!(mismatched, "$name length $(join(counts, " vs "))")
        elseif length(origins) > 1
            step = first(steps)
            offs = [abs((o - first(origins)) / step) for o in origins]
            frac = [abs(o - round(o)) for o in offs]
            push!(mismatched, all(f -> f < 1e-4, frac) ?
                              "$name origin differs by a whole number of cells ($(join(origins, " vs ")))" :
                              "$name origin offset by a fraction of a cell ($(join(origins, " vs ")))")
        end
    end

    ex = first(values(per)) |> first
    desc = "measured " * join(axes_seen, "/") * " on $n_compared granules; " *
           "step $(round(ex.step; digits = 6))"
    n_compared < 2 && return Verdict("G", :unknown,
                                     "coordinates read for one granule only, so no cross-granule " *
                                     "comparison — " * desc)
    isempty(mismatched) && return Verdict("G", :yes, "identical grid across granules — " * desc)
    if all(m -> occursin("whole number of cells", m), mismatched)
        return Verdict("G", :partial, "same lattice, different extent — " * first(mismatched))
    end
    return Verdict("G", :no, "grids differ — " * first(mismatched))
end

"""
    CF_DEFAULT

The value a CF decoder assumes when an attribute is absent.

`scale_factor` of 1 and `add_offset` of 0 are the identity transform, so a granule that omits them
decodes identically to one that states them. Comparing raw presence instead would report a
difference where the decoded values agree.
"""
const CF_DEFAULT = Dict(:scale_factor => "1.0", :add_offset => "0.0")

"""
    cf_value(v, key) -> String

One CF attribute of one array, normalized so that equal decoding compares equal.

An absent attribute takes its CF default where one exists, and a numeric value is compared as a
number so that `1` and `1.0` are one value.
"""
function cf_value(v, key)
    raw = get(v.cf, key, nothing)
    isnothing(raw) && return get(CF_DEFAULT, key, "∅")
    x = tryparse(Float64, string(raw))
    return isnothing(x) ? string(raw) : string(x)
end

"""
    cf_stability(probes, ranked, recs) -> Verdict

Criterion S1: whether CF decoding attributes agree across granules.

A mismatch is the quiet failure: VirtualiZarr drops the conflicting attribute and applies the first
granule's encoding to every chunk, so the cube reads without error and returns wrong values. Only a
difference in what a decoder would compute counts, so an absent `scale_factor` compares equal to a
stated 1.
"""
function cf_stability(probes, ranked, recs)
    isempty(opened(probes)) && return Verdict("S1", :unmeasured, "no granule opened")
    cmp = comparable(ranked, recs)
    isempty(cmp) && return Verdict("S1", :unmeasured,
                                   "no data array appears in two opened granules")
    decoding, labelling = String[], String[]
    for name in cmp, key in (:scale_factor, :add_offset, :_FillValue, :units)
        vals = unique([cf_value(v, key) for v in recs[name]])
        length(vals) > 1 || continue
        push!(key === :units ? labelling : decoding, "$name.$key: " * join(vals, " vs "))
    end
    isempty(decoding) ||
        return Verdict("S1", :no, "attributes that change decoded values differ — " * first(decoding))
    isempty(labelling) ||
        return Verdict("S1", :partial, "units differ but no attribute that changes a decoded value " *
                                       "does, so the cube is mislabelled rather than wrong — " *
                                       first(labelling))
    return Verdict("S1", :yes, "CF attributes agree across $(length(cmp)) variables")
end

"""
    DEFLATE_MAX_RATIO

The largest compression ratio a DEFLATE stream can achieve.

A stored length below `uncompressed / DEFLATE_MAX_RATIO` is not a compressed chunk, so a manifest
reporting one is not reporting a chunk length. The bound is a property of the format, which is what
makes it usable as a check on the measurement.
"""
const DEFLATE_MAX_RATIO = 1032

"""
    stored_bytes(v) -> Union{Int,Nothing}

The median stored length of one array's chunks, or `nothing` when the recorded length cannot be a
chunk length.

The kerchunk HDF4 backend records a length that is not the data block's for some products, and an
implausible value there would otherwise be read as a tiny chunk and graded as latency-bound. A
zlib-coded chunk is checked against the format's maximum compression ratio; a value below it is
discarded as unmeasured rather than reported.
"""
function stored_bytes(v)
    b = get(v, :chunk_bytes_median, nothing)
    (isnothing(b) || b <= 0) && return nothing
    w = itemsize(v.dtype)
    isnothing(w) && return b
    chunk = chunks_of(v)
    isempty(chunk) && return b
    codecs = String.(something(get(v, :codecs, nothing), String[]))
    any(c -> occursin("Zlib", c) || occursin("Deflate", c), codecs) || return b
    return b * DEFLATE_MAX_RATIO < prod(chunk) * w ? nothing : b
end

"""
    chunk_size_verdict(probes, ranked, recs) -> Verdict

Criterion P-sz: whether reading the cube's largest variable costs one get-request per useful amount
of data.

Two things set that cost and they are measured separately: how many chunks the array is divided
into, which fixes how many requests a full read takes, and how many bytes each stored chunk holds,
which fixes whether a request is worth its latency. An array held in a handful of chunks is read in
a handful of requests however well it compresses, so a small stored chunk is only latency-bound when
the array is also divided into many of them.
"""
function chunk_size_verdict(probes, ranked, recs)
    isempty(opened(probes)) && return Verdict("P-sz", :unmeasured, "no granule opened")
    isempty(ranked) && return Verdict("P-sz", :unmeasured, "no data array recorded")
    name = first(ranked)
    vs = get(recs, name, [])
    sizes = [b for b in stored_bytes.(vs) if !isnothing(b)]
    isempty(sizes) && return Verdict("P-sz", :unmeasured,
                                     "$name: no stored chunk length the format could produce, so " *
                                     "the parser did not record one")
    m = median(sizes)
    nch = median([get(v, :n_chunks, 1) for v in vs])
    mb = round(m / 1e6; digits = 3)
    ev = "$name: median stored chunk $(mb) MB in $(round(Int, nch)) chunks"
    m >= 500_000 && return Verdict("P-sz", :yes, ev)
    m >= 50_000 && return Verdict("P-sz", :partial, ev)
    nch <= 4 && return Verdict("P-sz", :yes, ev * " — whole array in one request")
    return Verdict("P-sz", :no, ev * " — latency-bound")
end

"""
    grade(vs) -> Tuple{String,String}

An A–F grade for one collection, or `U` where the probe could not measure it, and the criterion that
decided it.

The ordering is by what a user hits first: a parser refusal or a format with no parser makes
virtualization impossible; inconsistent chunk shapes or an interior partial chunk make it impossible
without rewriting bytes; silently inconsistent CF attributes make it dangerous; scattered metadata
and tiny chunks make it merely slow. `A` claims measured properties, so a criterion the probe could
not evaluate keeps a collection out of it rather than passing by default.
"""
function grade(vs)
    vs.parse.status === :unmeasured && return ("U", "$(vs.parse.id): $(vs.parse.note)")
    vs.parse.status === :no && return ("F", "$(vs.parse.id): $(vs.parse.note)")
    vs.chunks.status === :no && return ("D", "$(vs.chunks.id): $(vs.chunks.note)")
    vs.concat.status === :no && return ("D", "$(vs.concat.id): $(vs.concat.note)")
    vs.cf.status === :no && return ("C", "$(vs.cf.id): $(vs.cf.note)")
    vs.concat.status === :partial && return ("C", "$(vs.concat.id): $(vs.concat.note)")
    vs.parse.status === :partial && return ("C", "$(vs.parse.id): $(vs.parse.note)")

    measured = vs.locality.status in (:yes, :partial) && vs.size.status in (:yes, :partial)
    if vs.grid.status === :yes && measured && vs.time.status === :yes && vs.chunks.status === :yes
        return ("A", "no blocker")
    end

    # Every reason the collection fell short of A is reported, in a fixed order: which variables cannot
    # enter the cube, then what could not be measured, then what reading it costs. Picking one would
    # hide the others, and for most of these collections more than one applies.
    reasons = String[]
    say(v) = push!(reasons, "$(v.id): $(v.note)")
    vs.chunks.status === :partial && say(vs.chunks)
    vs.chunks.status === :unmeasured && say(vs.chunks)
    vs.concat.status === :unmeasured && say(vs.concat)
    vs.size.status === :unmeasured && say(vs.size)
    vs.locality.status === :unmeasured && say(vs.locality)
    vs.grid.status in (:partial, :unknown, :unmeasured) && say(vs.grid)
    vs.time.status !== :yes && say(vs.time)
    vs.locality.status === :no && say(vs.locality)
    vs.size.status === :no && say(vs.size)
    vs.cf.status === :partial && say(vs.cf)
    isempty(reasons) && say(vs.grid)
    return ("B", join(reasons, "; "))
end

"""
    assess(rec) -> NamedTuple

Every criterion verdict plus the derived grade for one collection's probe record.
"""
function assess(rec)
    probes = rec.probes
    ranked, recs = science_vars(probes)
    # H2 reads the grid verdict: whether a single whole-array chunk is safe depends on whether the
    # granules sit on one grid, so the grid is settled first.
    grid = grid_verdict(probes, get(rec, :level, ""), ranked, recs)
    vs = (
        parse = parse_verdict(probes),
        chunks = chunk_stability(probes, ranked, recs, grid),
        concat = concat_alignment(probes, ranked, recs),
        locality = metadata_locality(probes),
        time = time_dimension(probes),
        grid = grid,
        cf = cf_stability(probes, ranked, recs),
        size = chunk_size_verdict(probes, ranked, recs),
    )
    g, blocker = grade(vs)
    return (; vs..., grade = g, blocker, main_vars = ranked,
            n_comparable = length(comparable(ranked, recs)), records = recs)
end
