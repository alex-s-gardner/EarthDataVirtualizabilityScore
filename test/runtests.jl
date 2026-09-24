"""
Tests for the criteria in `src/criteria.jl`, which reduce the stage 3 measurements to the grades the
report publishes.

Every criterion is a pure function of one collection's probe records, so each branch is exercised
against a record built here rather than against a granule. A branch with no test is a grade that can
change without anything failing.
"""

using Test

include(joinpath(@__DIR__, "..", "src", "criteria.jl"))

"""
    pvar(name; kwargs...) -> NamedTuple

One array's probe record, with the fields the criteria read and defaults that pass every criterion.
"""
pvar(name; shape = [10, 20], chunks = [5, 20], dtype = "float32",
     codecs = ["BytesCodec", "Zlib"], dims = ["y", "x"], cf = (;), grid = (;),
     n_chunks = 4, chunk_bytes_median = 1_000_000, overview = false) =
    (; name, shape, chunks, dtype, codecs, dims, cf, grid, n_chunks, chunk_bytes_median, overview)

"""
    probe(vars; kwargs...) -> NamedTuple

One granule's probe record.
"""
probe(vars; ok = true, attempted = true, error_type = "", error = "", locality = nothing,
      coords = nothing, root_attrs = (;), url = "https://example/g.nc") =
    (; ok, attempted, error_type, error, vars, locality, coords, root_attrs, url)

"""
    refusal(error_type, error) -> NamedTuple

A granule the parser refused.
"""
refusal(error_type, error) = probe([]; ok = false, error_type, error)

"""
    verdicts(; kwargs...) -> NamedTuple

The criterion verdicts `grade` reads, every one passing unless overridden.
"""
function verdicts(; kwargs...)
    base = (parse = Verdict("H0", :yes, ""), chunks = Verdict("H2", :yes, ""),
            concat = Verdict("H3", :yes, ""), dtypes = Verdict("H4", :yes, ""),
            codecs = Verdict("H5", :yes, ""), vars = Verdict("V", :yes, ""),
            locality = Verdict("P-md", :yes, ""), time = Verdict("T", :yes, ""),
            grid = Verdict("G", :yes, ""), cf = Verdict("S1", :yes, ""),
            size = Verdict("P-sz", :yes, ""))
    return merge(base, NamedTuple(kwargs))
end

"""
    sci(probes) -> Tuple

`science_vars` of a probe list, as the criteria call it.
"""
sci(probes) = science_vars(probes)

@testset "criteria" begin

@testset "dtype widths" begin
    @test itemsize("float32") == 4
    @test itemsize(">f4") == 4
    @test itemsize("|S27") == 27
    @test itemsize("int8") == 1
    @test isnothing(itemsize("StringDType()"))
    @test isnothing(itemsize("[('a', '<i4')]"))
    @test fixed_string("|S27")
    @test !fixed_string("float32")
    # A byte-string array is sized by its declared width rather than by the data it carries.
    @test isnothing(array_bytes(pvar("label"; dtype = "|S27")))
    @test isnothing(array_bytes(pvar("v"; shape = Int[])))
    @test array_bytes(pvar("v"; shape = [10, 20], dtype = "float32")) == 800
end

@testset "which arrays a criterion sees" begin
    @test is_coordinate("lat")
    @test is_coordinate("Grid/time")
    @test !is_coordinate("temperature")
    @test is_metadata("science/LSAR/metadata/attitude/time")
    @test !is_metadata("science/metadata")   # the array itself, not a group it sits under
    @test rsplit_leaf("a/b/c") == "c"

    p = probe([pvar("big"; shape = [100, 100]), pvar("small"; shape = [10, 10]),
               pvar("lat"; shape = [1000, 1000]), pvar("metadata/orbit"; shape = [1000, 1000]),
               pvar("pyramid"; shape = [1000, 1000], overview = true),
               pvar("vlen"; shape = [1000, 1000], dtype = "StringDType()")])
    ranked, recs = sci([p])
    @test ranked == ["big", "small"]
    @test keys(recs) |> collect |> sort == ["big", "small"]
end

@testset "comparable, universal, principal" begin
    a = probe([pvar("shared"; shape = [100, 100]), pvar("only_a"; shape = [200, 200])])
    b = probe([pvar("shared"; shape = [100, 100])])
    ranked, recs = sci([a, b])
    @test ranked == ["only_a", "shared"]          # largest first
    @test comparable(ranked, recs) == ["shared"]
    @test universal([a, b], ranked, recs) == ["shared"]
    # The principal variable is the largest the granules share, not the largest overall: a chunk shape
    # read from an array one granule carries describes nothing the cube holds.
    @test principal([a, b], ranked, recs) == "shared"
    # With nothing shared there is no cross-granule measurement, so the largest array stands in.
    c = probe([pvar("only_c"; shape = [50, 50])])
    ranked2, recs2 = sci([a, c])
    @test principal([a, c], ranked2, recs2) == "only_a"
    @test isnothing(principal([probe([])], String[], Dict{String,Vector{Any}}()))
end

@testset "H0 parse" begin
    @test parse_verdict([]).status === :unmeasured
    @test parse_verdict([probe([pvar("v")])]).status === :yes
    @test parse_verdict([refusal("ValueError", "boom")]).status === :no
    @test parse_verdict([probe([pvar("v")]), refusal("ValueError", "boom")]).status === :partial

    # A store with no arrays yields no chunk manifest however cleanly the call returned.
    empty_store = parse_verdict([probe([]), probe([])])
    @test empty_store.status === :no
    @test occursin("no arrays", empty_store.note)

    # Failures outside the file are not refusals: they say nothing about how the granule was written.
    transport = probe([]; ok = false, error_type = "ConnectionError", error = "error sending request")
    @test parse_verdict([probe([pvar("v")]), transport]).status === :yes
    @test transport_failure(transport)
    @test !transport_failure(probe([pvar("v")]))

    budget = probe([]; ok = false, error_type = "ProbeTimeout", error = "exceeded budget")
    @test budget_exhausted(budget)
    v = parse_verdict([budget, probe([]; ok = false, attempted = false, error_type = "ProbeTimeout")])
    @test v.status === :unmeasured
    @test occursin("exhausted the probe budget", v.note)
    @test occursin("nothing refused the file itself", v.note)

    toobig = probe([]; ok = false, error_type = "SizeLimit",
                   error = "granule is 927 MB; above the 839 MB copy-to-disk limit")
    @test unmeasured(toobig)

    # A run long enough to outlive its Earthdata Login token must not record every granule after that
    # moment as a file the reader refused.
    expired = probe([]; ok = false, error_type = "UnauthenticatedError",
                    error = "The operation lacked valid authentication credentials for path x")
    @test transport_failure(expired)
    @test parse_verdict([probe([pvar("v")]), expired]).status === :yes
    denied = probe([]; ok = false, error_type = "PermissionDeniedError",
                   error = "The operation lacked the necessary privileges")
    @test transport_failure(denied)
end

@testset "refusals named as obstructions" begin
    @test occursin("UTF-8", classify_refusal("UnicodeDecodeError", "x"))
    @test occursin("names each axis once",
                   classify_refusal("ValueError", "2 dimension scales attached to axis 1"))
    @test occursin("vgroup holding the data-block references",
                   classify_refusal("KeyError", "'data'"))
    @test occursin("scalar", classify_refusal("TypeError", "fill_value expected float, got list"))
    @test occursin("requires a number", classify_refusal("TypeError", "fill_value must be numeric"))
    @test occursin("dtype Zarr cannot express",
                   classify_refusal("ValueError", "data type resolution from object failed"))
    @test occursin("wrong length for the array's rank",
                   classify_refusal("ValueError", "dims must have same number of dimensions"))
    @test occursin("global heap", classify_refusal("ValueError", "variable-length data found"))
    @test classify_refusal("NoParser", "no VirtualiZarr parser reads HGT") ==
          "no VirtualiZarr parser reads HGT"
    # An unrecognized message is passed through rather than guessed at.
    @test occursin("SomeError", classify_refusal("SomeError", "a novel complaint"))
end

@testset "H2 chunk shape" begin
    yes_grid = Verdict("G", :yes, "")
    same = [probe([pvar("v"; chunks = [5, 20])]), probe([pvar("v"; chunks = [5, 20])])]
    r, c = sci(same)
    @test chunk_stability(same, r, c, yes_grid).status === :yes

    diff = [probe([pvar("v"; chunks = [5, 20])]), probe([pvar("v"; chunks = [4, 20])])]
    r, c = sci(diff)
    v = chunk_stability(diff, r, c, yes_grid)
    @test v.status === :no
    @test occursin("differs across granules", v.note)

    # The largest variable decides: where it is stable a cube over it is available.
    mixed = [probe([pvar("big"; shape = [100, 100], chunks = [50, 100]),
                    pvar("small"; shape = [10, 10], chunks = [5, 10])]),
             probe([pvar("big"; shape = [100, 100], chunks = [50, 100]),
                    pvar("small"; shape = [10, 10], chunks = [2, 10])])]
    r, c = sci(mixed)
    v = chunk_stability(mixed, r, c, yes_grid)
    @test v.status === :partial
    @test occursin("smaller variables", v.note)

    @test chunk_stability([refusal("E", "x")], String[],
                          Dict{String,Vector{Any}}(), yes_grid).status === :unmeasured
    lone = [probe([pvar("v")])]
    r, c = sci(lone)
    @test chunk_stability(lone, r, c, yes_grid).status === :unmeasured

    # One chunk spanning the whole array pins the cube's shape to that granule's dimensions, so
    # agreement establishes H2 only where a grid holds the granules.
    whole = [probe([pvar("v"; shape = [10, 20], chunks = [10, 20])]),
             probe([pvar("v"; shape = [10, 20], chunks = [10, 20])])]
    r, c = sci(whole)
    @test chunk_stability(whole, r, c, yes_grid).status === :yes
    v = chunk_stability(whole, r, c, Verdict("G", :unknown, ""))
    @test v.status === :partial
    @test occursin("unestablished", v.note)
    v = chunk_stability(whole, r, c, Verdict("G", :no, ""))
    @test v.status === :partial
    @test occursin("varies with the orbit", v.note)
end

@testset "H3 concatenation" begin
    identical = [probe([pvar("v"; shape = [10, 20], chunks = [5, 20])]),
                 probe([pvar("v"; shape = [10, 20], chunks = [5, 20])])]
    r, c = sci(identical)
    v = concat_alignment(identical, r, c)
    @test v.status === :yes
    @test occursin("new or length-one axis", v.note)

    aligned = [probe([pvar("v"; shape = [10, 20], chunks = [5, 20])]),
               probe([pvar("v"; shape = [15, 20], chunks = [5, 20])])]
    r, c = sci(aligned)
    @test concat_alignment(aligned, r, c).status === :yes

    # One offending granule is consistent with it being the last in the record.
    one_off = [probe([pvar("v"; shape = [10, 20], chunks = [5, 20])]),
               probe([pvar("v"; shape = [12, 20], chunks = [5, 20])])]
    r, c = sci(one_off)
    v = concat_alignment(one_off, r, c)
    @test v.status === :partial
    @test occursin("unless it is the last", v.note)

    two_off = [probe([pvar("v"; shape = [10, 20], chunks = [5, 20])]),
               probe([pvar("v"; shape = [12, 20], chunks = [5, 20])]),
               probe([pvar("v"; shape = [13, 20], chunks = [5, 20])])]
    r, c = sci(two_off)
    v = concat_alignment(two_off, r, c)
    @test v.status === :no
    @test occursin("interior partial chunk", v.note)

    # Differing on two axes means different regions rather than slices of one array.
    regions = [probe([pvar("v"; shape = [10, 20], chunks = [5, 5])]),
               probe([pvar("v"; shape = [15, 25], chunks = [5, 5])])]
    r, c = sci(regions)
    v = concat_alignment(regions, r, c)
    @test v.status === :no
    @test occursin("different regions", v.note)

    # A variable failing H2 has no single chunk grid to measure an alignment against.
    unstable = [probe([pvar("v"; shape = [10, 20], chunks = [5, 20])]),
                probe([pvar("v"; shape = [12, 20], chunks = [4, 20])])]
    r, c = sci(unstable)
    @test concat_alignment(unstable, r, c).status === :yes
end

@testset "H4 dtype" begin
    same = [probe([pvar("v"; dtype = "float32")]), probe([pvar("v"; dtype = "float32")])]
    r, c = sci(same)
    @test dtype_stability(same, r, c).status === :yes

    packed = [probe([pvar("v"; dtype = "float32")]), probe([pvar("v"; dtype = "int16")])]
    r, c = sci(packed)
    v = dtype_stability(packed, r, c)
    @test v.status === :no
    @test occursin("float32 vs int16", v.note)

    mixed = [probe([pvar("big"; shape = [100, 100], dtype = "float32"),
                    pvar("small"; shape = [10, 10], dtype = "float32")]),
             probe([pvar("big"; shape = [100, 100], dtype = "float32"),
                    pvar("small"; shape = [10, 10], dtype = "int16")])]
    r, c = sci(mixed)
    @test dtype_stability(mixed, r, c).status === :partial

    @test dtype_stability([refusal("E", "x")], String[],
                          Dict{String,Vector{Any}}()).status === :unmeasured
end

@testset "H5 codec chain" begin
    same = [probe([pvar("v"; codecs = ["BytesCodec", "Zlib"])]),
            probe([pvar("v"; codecs = ["BytesCodec", "Zlib"])])]
    r, c = sci(same)
    @test codec_stability(same, r, c).status === :yes

    shuffled = [probe([pvar("v"; codecs = ["BytesCodec", "Zlib"])]),
                probe([pvar("v"; codecs = ["BytesCodec", "Shuffle", "Zlib"])])]
    r, c = sci(shuffled)
    v = codec_stability(shuffled, r, c)
    @test v.status === :no
    @test occursin("BytesCodec+Zlib vs BytesCodec+Shuffle+Zlib", v.note)

    turned_on = [probe([pvar("v"; codecs = ["BytesCodec"])]),
                 probe([pvar("v"; codecs = ["BytesCodec", "Zlib"])])]
    r, c = sci(turned_on)
    @test codec_stability(turned_on, r, c).status === :no

    mixed = [probe([pvar("big"; shape = [100, 100], codecs = ["BytesCodec"]),
                    pvar("small"; shape = [10, 10], codecs = ["BytesCodec"])]),
             probe([pvar("big"; shape = [100, 100], codecs = ["BytesCodec"]),
                    pvar("small"; shape = [10, 10], codecs = ["BytesCodec", "Zlib"])])]
    r, c = sci(mixed)
    @test codec_stability(mixed, r, c).status === :partial

    # An unrecorded chain is an absence, not a difference.
    unrecorded = [probe([pvar("v"; codecs = String[])]), probe([pvar("v"; codecs = String[])])]
    r, c = sci(unrecorded)
    @test codec_stability(unrecorded, r, c).status === :unmeasured
end

@testset "V variable coverage" begin
    both = [probe([pvar("a"), pvar("b")]), probe([pvar("a"), pvar("b")])]
    r, c = sci(both)
    @test variable_coverage(both, r, c).status === :yes

    added = [probe([pvar("big"; shape = [100, 100])]),
             probe([pvar("big"; shape = [100, 100]), pvar("late"; shape = [10, 10])])]
    r, c = sci(added)
    v = variable_coverage(added, r, c)
    @test v.status === :partial
    @test occursin("late appears in 1", v.note)
    @test occursin("big spans the sample", v.note)

    # A product that renames its measurement per platform shares no array across the record.
    renamed = [probe([pvar("F08_ICECON")]), probe([pvar("F17_ICECON")])]
    r, c = sci(renamed)
    v = variable_coverage(renamed, r, c)
    @test v.status === :no
    @test occursin("no single array spans", v.note)

    @test variable_coverage([probe([pvar("a")])], ["a"],
                            Dict{String,Vector{Any}}("a" => [pvar("a")])).status === :unmeasured
end

@testset "M materialization" begin
    def(ds, dt) = (; dataset = (; ok = ds), datatree = (; ok = dt))
    flat = [probe([pvar("v")]; ), probe([pvar("v")])]
    flat = [merge(p, (; materialize = def(true, true))) for p in flat]
    v = materializes(flat)
    @test v.status === :yes
    @test occursin("every one of 2", v.note)

    # A hierarchical granule xarray will not flatten still opens as a tree.
    tree = [merge(probe([pvar("v")]),
                  (; materialize = (; dataset = (; ok = false,
                                                 error = "conflicting sizes for dimension 'y'"),
                                    datatree = (; ok = true))))]
    v = materializes(tree)
    @test v.status === :partial
    @test occursin("readable as a tree", v.note)
    @test occursin("conflicting sizes", v.note)

    neither = [merge(probe([pvar("v")]),
                     (; materialize = (; dataset = (; ok = false, error = "boom"),
                                       datatree = (; ok = false, error = "boom"))))]
    v = materializes(neither)
    @test v.status === :no
    @test occursin("neither an xarray Dataset nor a DataTree", v.note)

    mixed = [merge(probe([pvar("v")]), (; materialize = def(true, true))),
             merge(probe([pvar("v")]), (; materialize = def(false, false)))]
    @test materializes(mixed).status === :partial

    # Artifacts recorded before this measurement existed report an absence, not a failure.
    @test materializes([probe([pvar("v")])]).status === :unmeasured
    @test materializes([refusal("E", "x")]).status === :unmeasured

    # M is a property of the readers, so it does not enter the grade.
    @test first(grade(verdicts())) == "A"
end

@testset "P-md metadata locality" begin
    near(n, runs, lead) = probe([pvar("v")];
                                locality = (; n_blocks = n, contiguous_runs = runs,
                                            leading_fraction = lead))
    @test metadata_locality([near(2, 1, 0.9)]).status === :yes
    @test metadata_locality([near(40, 5, 0.2)]).status === :partial
    @test metadata_locality([near(300, 40, 0.05)]).status === :no
    @test metadata_locality([probe([pvar("v")])]).status === :unmeasured

    # Blocks fetched before a granule was abandoned are a lower bound on what the index costs.
    abandoned = probe([]; ok = false, error_type = "ProbeTimeout", error = "budget",
                      locality = (; n_blocks = 90, contiguous_runs = 30, leading_fraction = 0.1))
    v = metadata_locality([abandoned])
    @test v.status === :no
    @test occursin("still unread when abandoned", v.note)
end

@testset "T time dimension" begin
    shared = [probe([pvar("a"; dims = ["time", "x"]), pvar("b"; dims = ["time", "x"])])]
    v = time_dimension(shared)
    @test v.status === :yes
    @test occursin("time", v.note)

    # A canonical name no data array is laid out on is a coordinate, not an axis.
    coord_only = [probe([pvar("a"; dims = ["y", "x"]), pvar("b"; dims = ["y", "x"]),
                         pvar("t"; dims = ["time"])])]
    v = time_dimension(coord_only)
    @test v.status === :partial
    @test occursin("no data array is laid out on it", v.note)

    # A compound name one array declares is a name the reader derived for that array.
    derived = [probe([pvar("a"; dims = ["day_view_time_x"]), pvar("b"; dims = ["y", "x"]),
                      pvar("c"; dims = ["y", "x"])])]
    v = time_dimension(derived)
    @test v.status === :no
    @test occursin("per-array name", v.note)

    novar = [probe([pvar("a"; dims = ["y", "x"]), pvar("b"; dims = ["y", "x"])])]
    @test time_dimension(novar).status === :no

    named_var = [probe([pvar("a"; dims = ["y", "x"]), pvar("ev_mid_time"; dims = ["y", "x"])])]
    v = time_dimension(named_var)
    @test v.status === :partial
    @test occursin("no time dimension", v.note)

    nodims = [probe([pvar("a"; dims = nothing)])]
    v = time_dimension(nodims)
    @test v.status === :no
    @test occursin("no dimension names", v.note)

    @test time_dimension([refusal("E", "x")]).status === :unmeasured
    @test time_named("time")
    @test time_named("ev_mid_time")
    @test !time_named("timeliness")
    @test canonical_time("time")
    @test !canonical_time("day_view_time_x")
end

@testset "S1 CF attributes" begin
    agree = [probe([pvar("v"; cf = (; scale_factor = 2, units = "K"))]),
             probe([pvar("v"; cf = (; scale_factor = 2.0, units = "K"))])]
    r, c = sci(agree)
    @test cf_stability(agree, r, c).status === :yes

    # An absent attribute takes its CF default, so it compares equal to a stated identity.
    implied = [probe([pvar("v"; cf = (;))]), probe([pvar("v"; cf = (; scale_factor = 1))])]
    r, c = sci(implied)
    @test cf_stability(implied, r, c).status === :yes

    scaled = [probe([pvar("v"; cf = (; scale_factor = 1))]),
              probe([pvar("v"; cf = (; scale_factor = 2))])]
    r, c = sci(scaled)
    v = cf_stability(scaled, r, c)
    @test v.status === :no
    @test occursin("change decoded values", v.note)

    labelled = [probe([pvar("v"; cf = (; units = "K"))]),
                probe([pvar("v"; cf = (; units = "degC"))])]
    r, c = sci(labelled)
    v = cf_stability(labelled, r, c)
    @test v.status === :partial
    @test occursin("mislabelled rather than wrong", v.note)

    # On a time axis `units` carries the epoch, so a difference moves every date.
    epochs = [probe([pvar("v"), pvar("time"; dims = ["time"],
                                     cf = (; units = "minutes since 1980-01-01"))]),
              probe([pvar("v"), pvar("time"; dims = ["time"],
                                     cf = (; units = "minutes since 1980-01-02"))])]
    r, c = sci(epochs)
    v = cf_stability(epochs, r, c)
    @test v.status === :no
    @test occursin("different epoch", v.note)
    @test occursin("2 distinct epochs", v.note)

    # A timestamp in a metadata group is not the axis a cube is ordered by.
    orbit = [probe([pvar("v"), pvar("science/metadata/attitude/time";
                                    cf = (; units = "seconds since 2025-10-29"))]),
             probe([pvar("v"), pvar("science/metadata/attitude/time";
                                    cf = (; units = "seconds since 2025-11-22"))])]
    r, c = sci(orbit)
    @test cf_stability(orbit, r, c).status === :yes
end

@testset "P-sz chunk size" begin
    big = [probe([pvar("v"; chunk_bytes_median = 2_000_000, n_chunks = 100)])]
    r, c = sci(big)
    @test chunk_size_verdict(big, r, c).status === :yes

    mid = [probe([pvar("v"; chunk_bytes_median = 100_000, n_chunks = 100)])]
    r, c = sci(mid)
    @test chunk_size_verdict(mid, r, c).status === :partial

    # A small chunk only costs a request per useful read where the array has many of them.
    few = [probe([pvar("v"; chunk_bytes_median = 1_000, n_chunks = 3)])]
    r, c = sci(few)
    v = chunk_size_verdict(few, r, c)
    @test v.status === :yes
    @test occursin("one request", v.note)

    many = [probe([pvar("v"; chunk_bytes_median = 1_000, n_chunks = 500)])]
    r, c = sci(many)
    v = chunk_size_verdict(many, r, c)
    @test v.status === :no
    @test occursin("latency-bound", v.note)

    # DEFLATE cannot compress past 1032:1, so a shorter recorded length is not a chunk length.
    impossible = pvar("v"; shape = [2400, 2400], chunks = [2400, 2400], dtype = "float32",
                      codecs = ["BytesCodec", "Zlib"], chunk_bytes_median = 16)
    @test isnothing(stored_bytes(impossible))
    plausible = pvar("v"; shape = [100, 100], chunks = [100, 100], dtype = "float32",
                     codecs = ["BytesCodec", "Zlib"], chunk_bytes_median = 1_000)
    @test stored_bytes(plausible) == 1_000
    # Without a compressing codec the recorded length stands as measured.
    raw = pvar("v"; codecs = ["BytesCodec"], chunk_bytes_median = 8)
    @test stored_bytes(raw) == 8

    nolength = [probe([pvar("v"; shape = [2400, 2400], chunks = [2400, 2400],
                             codecs = ["BytesCodec", "Zlib"], chunk_bytes_median = 16)])]
    r, c = sci(nolength)
    v = chunk_size_verdict(nolength, r, c)
    @test v.status === :unmeasured
    @test occursin("the format could produce", v.note)
end

@testset "G grid" begin
    coord(first_, step, n) = (; first = first_, step, n)
    same = [probe([pvar("v")]; coords = (; lon = coord(0.0, 0.25, 100),
                                         lat = coord(-90.0, 0.25, 100))),
            probe([pvar("v")]; coords = (; lon = coord(0.0, 0.25, 100),
                                         lat = coord(-90.0, 0.25, 100)))]
    v = coordinate_grid(same)
    @test v.status === :yes
    @test occursin("identical grid", v.note)

    # An origin differing by a whole number of cells is the same lattice at a different extent.
    shifted = [probe([pvar("v")]; coords = (; lon = coord(0.0, 0.25, 100))),
               probe([pvar("v")]; coords = (; lon = coord(2.5, 0.25, 100)))]
    v = coordinate_grid(shifted)
    @test v.status === :partial
    @test occursin("different extent", v.note)

    # A fraction of a cell is not one grid at all.
    offset = [probe([pvar("v")]; coords = (; lon = coord(0.0, 0.25, 100))),
              probe([pvar("v")]; coords = (; lon = coord(0.1, 0.25, 100)))]
    v = coordinate_grid(offset)
    @test v.status === :no
    @test occursin("fraction of a cell", v.note)

    spacing = [probe([pvar("v")]; coords = (; lon = coord(0.0, 0.25, 100))),
               probe([pvar("v")]; coords = (; lon = coord(0.0, 0.5, 100)))]
    v = coordinate_grid(spacing)
    @test v.status === :no
    @test occursin("spacing", v.note)

    lone = [probe([pvar("v")]; coords = (; lon = coord(0.0, 0.25, 100)))]
    v = coordinate_grid(lone)
    @test v.status === :unknown
    @test occursin("one granule only", v.note)
    @test isnothing(coordinate_grid([probe([pvar("v")])]))

    # Absence of any grid evidence is swath geometry on an L2 product and unmeasured on a grid.
    bare = [probe([pvar("v")])]
    r, c = sci(bare)
    @test grid_verdict(bare, "L2", r, c).status === :no
    @test occursin("swath geometry", grid_verdict(bare, "L2", r, c).note)
    v = grid_verdict(bare, "L3", r, c)
    @test v.status === :unknown
    @test occursin("unmeasured, not absent", v.note)

    # An attribute naming a coordinate system supplies neither an origin nor a cell size.
    named = [probe([pvar("v"; grid = (; crs_wkt = "PROJCS[...]"))]),
             probe([pvar("v"; grid = (; crs_wkt = "PROJCS[...]"))])]
    r, c = sci(named)
    @test grid_verdict(named, "L3", r, c).status === :unknown
    located = [probe([pvar("v"; grid = (; GeoTransform = "0 30 0 0 0 -30"))]),
               probe([pvar("v"; grid = (; GeoTransform = "0 30 0 0 0 -30"))])]
    r, c = sci(located)
    @test grid_verdict(located, "L3", r, c).status === :yes
    differing = [probe([pvar("v"; grid = (; GeoTransform = "0 30 0 0 0 -30"))]),
                 probe([pvar("v"; grid = (; GeoTransform = "9 30 0 0 0 -30"))])]
    r, c = sci(differing)
    @test grid_verdict(differing, "L3", r, c).status === :no

    # An axis whose length doubles between granules is a coarser rendering, not another extent.
    resized = [probe([pvar("v"; shape = [100, 100])]), probe([pvar("v"; shape = [200, 200])])]
    r, c = sci(resized)
    v = varying_extent(resized, r, c)
    @test !isnothing(v)
    @test v.status === :no
    @test occursin("mixes resolutions", v.note)
    @test isnothing(varying_extent(same, sci(same)...))
end

@testset "G GeoTIFF lattice" begin
    tile(crs, x, y) = (; crs, tiepoint = [0.0, 0.0, 0.0, x, y], pixel_scale = [30.0, 30.0])
    @test tiff_lattice([tile("EPSG:32610", 300.0, 900.0)], 30.0).status === :yes
    # Origins on a common lattice within one CRS are one grid at different extents.
    v = tiff_lattice([tile("EPSG:32610", 300.0, 900.0), tile("EPSG:32610", 360.0, 960.0)], 30.0)
    @test v.status === :partial
    @test occursin("different extent", v.note)
    # A fractional offset is not a shared lattice.
    v = tiff_lattice([tile("EPSG:32610", 300.0, 900.0), tile("EPSG:32610", 305.0, 900.0)], 30.0)
    @test v.status === :no
    @test occursin("off a common", v.note)
    # Eastings mean the same thing only within one CRS, so several zones are one grid per tile.
    v = tiff_lattice([tile("EPSG:32610", 300.0, 900.0), tile("EPSG:32659", 300.0, 900.0)], 30.0)
    @test v.status === :partial
    @test occursin("one grid per tile", v.note)
    @test tiff_lattice([tile("", 300.0, 900.0)], 30.0).status === :unknown
    @test tiff_lattice([(; crs = "EPSG:32610", tiepoint = Float64[])], 30.0).status === :unknown
end

@testset "grade ordering" begin
    @test grade(verdicts()) == ("A", "no blocker")

    @test first(grade(verdicts(parse = Verdict("H0", :unmeasured, "budget")))) == "U"
    @test first(grade(verdicts(parse = Verdict("H0", :no, "refused")))) == "F"
    @test first(grade(verdicts(chunks = Verdict("H2", :no, "x")))) == "D"
    @test first(grade(verdicts(dtypes = Verdict("H4", :no, "x")))) == "D"
    @test first(grade(verdicts(codecs = Verdict("H5", :no, "x")))) == "D"
    @test first(grade(verdicts(concat = Verdict("H3", :no, "x")))) == "D"
    @test first(grade(verdicts(cf = Verdict("S1", :no, "x")))) == "C"
    @test first(grade(verdicts(concat = Verdict("H3", :partial, "x")))) == "C"
    @test first(grade(verdicts(parse = Verdict("H0", :partial, "x")))) == "C"

    # A refusal outranks every layout finding: nothing downstream can be measured.
    @test first(grade(verdicts(parse = Verdict("H0", :no, "refused"),
                               chunks = Verdict("H2", :no, "x")))) == "F"
    # Rewriting bytes outranks a correctness risk.
    @test first(grade(verdicts(chunks = Verdict("H2", :no, "x"),
                               cf = Verdict("S1", :no, "y")))) == "D"

    # `A` claims measured properties, so an unmeasured criterion keeps a collection out of it.
    for k in (:chunks, :dtypes, :codecs, :vars, :locality, :size, :grid, :time)
        id = getproperty(verdicts(), k).id
        @test first(grade(verdicts(; k => Verdict(id, :unmeasured, "not measured")))) == "B"
    end
    @test first(grade(verdicts(grid = Verdict("G", :partial, "per tile")))) == "B"
    @test first(grade(verdicts(vars = Verdict("V", :no, "nothing shared")))) == "B"
    @test first(grade(verdicts(time = Verdict("T", :no, "none")))) == "B"
    @test first(grade(verdicts(locality = Verdict("P-md", :no, "scattered")))) == "B"
    @test first(grade(verdicts(size = Verdict("P-sz", :no, "tiny")))) == "B"
    @test first(grade(verdicts(cf = Verdict("S1", :partial, "units")))) == "B"
    # Scattered metadata is still a measurement, so it does not bar the grade by absence.
    @test first(grade(verdicts(locality = Verdict("P-md", :partial, "few runs")))) == "A"

    # A `B` states every reason it fell short, not the first one found.
    _, why = grade(verdicts(time = Verdict("T", :no, "no time dimension"),
                            locality = Verdict("P-md", :no, "scattered"),
                            size = Verdict("P-sz", :no, "latency-bound")))
    @test occursin("T: no time dimension", why)
    @test occursin("P-md: scattered", why)
    @test occursin("P-sz: latency-bound", why)
end

@testset "assess end to end" begin
    clean = [probe([pvar("v"; dims = ["time", "y"], grid = (; GeoTransform = "0 30 0 0 0 -30")),
                    pvar("w"; dims = ["time", "y"], grid = (; GeoTransform = "0 30 0 0 0 -30"))];
                   locality = (; n_blocks = 2, contiguous_runs = 1, leading_fraction = 0.95)),
             probe([pvar("v"; dims = ["time", "y"], grid = (; GeoTransform = "0 30 0 0 0 -30")),
                    pvar("w"; dims = ["time", "y"], grid = (; GeoTransform = "0 30 0 0 0 -30"))];
                   locality = (; n_blocks = 2, contiguous_runs = 1, leading_fraction = 0.95))]
    a = assess((; probes = clean, level = "L3"))
    @test a.grade == "A"
    @test a.blocker == "no blocker"
    @test a.principal == "v"
    @test a.n_comparable == 2
    @test a.n_universal == 2

    # One codec change is enough to take the same collection out of reach without rewriting bytes.
    rechunked = deepcopy(clean)
    broken = [rechunked[1],
              probe([pvar("v"; dims = ["time", "y"], codecs = ["BytesCodec"],
                          grid = (; GeoTransform = "0 30 0 0 0 -30")),
                     pvar("w"; dims = ["time", "y"], grid = (; GeoTransform = "0 30 0 0 0 -30"))];
                    locality = (; n_blocks = 2, contiguous_runs = 1, leading_fraction = 0.95))]
    b = assess((; probes = broken, level = "L3"))
    @test b.grade == "D"
    @test occursin("H5", b.blocker)

    refused = assess((; probes = [refusal("ValueError", "no parser")], level = "L3"))
    @test refused.grade == "F"
    @test isnothing(refused.principal)
end

end
