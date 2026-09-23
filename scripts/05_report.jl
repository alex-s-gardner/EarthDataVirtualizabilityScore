"""
Stage 5: render the ranked table and its method notes.

Reads `results/virtualizability.csv` and writes `README.md`, which is the report. Runs offline.
"""

using CSV, DataFrames, Dates, Statistics

const RESULTS = joinpath(@__DIR__, "..", "results")

"""
    shown_grade(g) -> String

A grade as the report displays it. `A` carries a star: an archive that virtualizes as it stands is
the outcome the criteria ask a producer for, and the table is where a reader looks for it. `F*` is
escaped so Markdown renders the asterisk rather than reading it as emphasis.
"""
shown_grade(g) = g == "A" ? "A ⭐" : g == "F*" ? "F\\*" : String(g)

"""
    md_table(df, cols; headers) -> String

A GitHub-flavored Markdown table of `cols` from `df`.
"""
function md_table(df, cols; headers)
    io = IOBuffer()
    println(io, "| " * join(headers, " | ") * " |")
    println(io, "|" * join(fill("---", length(cols)), "|") * "|")
    for r in eachrow(df)
        cells = map(cols) do c
            v = r[c]
            v isa AbstractFloat && return isnan(v) ? "—" : string(v)
            s = string(v)
            s = replace(s, "|" => "\\|")
            isempty(s) ? "—" : s
        end
        println(io, "| " * join(cells, " | ") * " |")
    end
    return String(take!(io))
end

"""
    sampling_note(df) -> String

The sample size actually achieved, stated as counts rather than as the intended design.
"""
function sampling_note(df)
    per = sort(unique(df.n_sampled))
    counts = join(["$(count(==(n), df.n_sampled)) collections at $n" for n in per], ", ")
    note = "$(sum(df.n_sampled)) granules across $(nrow(df)) collections ($counts)."
    abandoned = sum(df.n_sampled) - sum(df.n_attempted)
    abandoned > 0 && (note *= " $abandoned of those were not opened: a collection is abandoned " *
                              "after its first granule exhausts the probe budget, since granules " *
                              "written by one producer share a chunk index layout.")
    return note
end

"""
    inventory_date() -> String

The date `results/inventory.csv` was written, which is the moment its granule counts describe.
"""
inventory_date() = Dates.format(Dates.unix2datetime(mtime(joinpath(RESULTS, "inventory.csv"))),
                                "yyyy-mm-dd")

"""
    orbit_note(df) -> String

What the sample achieved on orbit direction, stated from the directions actually recorded.

Ascending and descending granules of one product share a projection but not a chunk origin, so a
sample that draws only one direction cannot see that case at all.
"""
function orbit_note(df)
    have = filter(r -> !ismissing(r.orbit_dirs) && !isempty(String(r.orbit_dirs)), df)
    both = filter(r -> occursin("/", String(r.orbit_dirs)), have)
    nrow(have) == 0 && return "CMR records " *
        "`SpatialExtent.HorizontalSpatialDomain.Orbit.StartDirection` for no collection in this set, " *
        "so the ascending-versus-descending case — the same projection with a different chunk " *
        "origin — is not covered."
    names = join(sort(String.(have.short_name)), ", ")
    nrow(both) == 0 && return "The sampler also asks for granules of the opposite orbit direction, " *
        "but CMR records `SpatialExtent.HorizontalSpatialDomain.Orbit.StartDirection` for only " *
        "$(nrow(have)) collection$(nrow(have) == 1 ? "" : "s") here ($names), and every granule it " *
        "returned for $(nrow(have) == 1 ? "that collection" : "those collections") carries the same " *
        "direction. The ascending-versus-descending case — the same projection with a different " *
        "chunk origin — is therefore not covered by this sample. Where a product has that property " *
        "it appears only as a grid or chunk mismatch, and only if the sampled granules happen to " *
        "straddle the two directions; `SPL2SMP_E`'s granule names show that its sample did."
    return "The sample spans both orbit directions for " *
        "$(join(sort(String.(both.short_name)), ", ")), which is where a shared projection with a " *
        "different chunk origin can appear."
end

"""
    partial_h2_example(df) -> String

A collection where smaller variables carry a different chunk shape while the largest does not, quoted
from its own H2 evidence.

The case is worth showing because the grade turns on which variable offends, and naming one in prose
would go stale the moment a wider sample implicates a different one.
"""
function partial_h2_example(df)
    rows = filter(r -> occursin("differs for smaller variables", String(r.chunk_evidence)), df)
    nrow(rows) == 0 && return ""
    r = first(sort(rows, :short_name))
    return " `$(r.short_name)` is the second case: $(r.chunk_evidence)."
end

"""
    hdf4_note(df) -> String

How the HDF4 path fared across the collections that use it, counted from their verdicts.

Readability there varies by producer rather than by format, so the split between collections it reads
and collections it does not is the thing to state, and it has to be counted rather than recalled: a
collection added to `CANDIDATES` changes it.
"""
function hdf4_note(df)
    fam = filter(r -> occursin(r"HDF4|HDF-EOS2|^HDF-EOS$", String(r.format)), df)
    nrow(fam) == 0 && return "No collection in this set is distributed in an HDF4-generation container."
    refused = filter(r -> occursin("parser refused", String(r.blocker)), fam)
    empty_store = filter(r -> occursin("no arrays", String(r.blocker)), fam)
    read_ok = nrow(fam) - nrow(refused) - nrow(empty_store)
    kinds = unique([m.match for m in
                    (match(r"(cannot read the HDF-EOS2 vgroup|dimension-name list|UTF-8)",
                           String(r.blocker)) for r in eachrow(refused)) if !isnothing(m)])
    note = "of the $(nrow(fam)) collections sampled in an HDF4-generation container, " *
           "$read_ok yield arrays on every granule opened, $(nrow(refused)) raise on every granule " *
           "in $(length(kinds)) distinct way$(length(kinds) == 1 ? "" : "s")"
    n = nrow(empty_store)
    n > 0 && (note *= ", and $n ($(join(sort(String.(empty_store.short_name)), ", "))) " *
        "$(n == 1 ? "returns" : "return") a store holding no arrays at all, which is a failure the " *
        "call's own return value does not report")
    return note * "."
end

const CRITERIA = """
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
"""

function build_report()
    path = joinpath(RESULTS, "virtualizability.csv")
    isfile(path) || error("$path missing; run scripts/04_score.jl first")
    df = CSV.read(path, DataFrame)
    # Every Grade column renders `grade_shown`; `grade` stays the bare letter the sort and the
    # empty-grade check read.
    df.grade_shown = map(shown_grade, df.grade)

    io = IOBuffer()
    println(io, "# EarthDataVirtualizabilityScore\n")
    println(io, """
    $(nrow(df)) NASA Earthdata collections graded on whether their archives can be read as lazy, cloud-native
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
    single cube would actually hold. Nine criteria are then evaluated per collection, each reduced to a
    verdict with the evidence that settled it. The grade follows the order a user hits them in: no
    parser reads the format, then bytes that would have to be rewritten, then a risk that reads without
    error and returns wrong values, then what a read costs. Each criterion below states what it requires
    and what evidence settles it; `results/virtualizability.csv` carries every verdict with its evidence
    in its own column, and `results/probe/` holds the per-granule measurements all of them derive from.

    ## Ranking\n""")
    println(io, md_table(df,
        [:grade_shown, :sensor, :short_name, :level, :format, :daac, :s3_region,
         :consolidated_md, :grid_aligned, :chunk_aligned, :time_dim,
         :chunk_shape, :chunk_mb, :n_granules, :volume_tb, :dmrpp, :blocker];
        headers = ["Grade", "Sensor", "Product", "Level", "Format", "DAAC", "S3 region",
                   "Consolidated md", "Grid aligned", "Chunk aligned", "Time dim",
                   "Chunk shape", "Chunk MB", "Granules", "Volume TB", "DMR++", "Deciding criterion"]))

    println(io, "\n## Grades\n")
    println(io, """
    - **A ⭐** — virtualizable as is: parses, one chunk shape for every variable across granules, no
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
    - **F\\*** — the layout could not be read, and the archive is not what stopped it. Stage 6 found
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
    """)
    empty_grades = [g for g in ["A", "B", "C", "D", "F*", "F", "U"] if !(g in df.grade)]
    isempty(empty_grades) ||
        println(io, "No collection in this set graded $(join(empty_grades, " or ")).\n")

    println(io, "\n## Criteria\n")
    println(io, CRITERIA)

    println(io, "\n## Writing an archive that virtualizes\n")
    println(io, """
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
    - **Declare time as a dimension the data arrays are laid out on** (T), rather than a coordinate
      variable no data array uses, so a cube reads its time axis instead of manufacturing one.
    - **Keep `scale_factor`, `add_offset`, and `_FillValue` identical across granules** (S1). A
      disagreement is dropped silently and the first granule's encoding is applied to every chunk, so
      the cube reads without error and returns wrong values.
    - **Write the chunk index contiguously**, near the front of the file (P-md), so a reader reaches all
      of it in one range request instead of one per scattered region.
    - **Size chunks for a latency-bound read** (P-sz): a few MB of stored bytes each, and few enough of
      them that a full read is tens of requests rather than thousands.
    - **Write a container a chunk manifest can describe** (H0, H1): HDF5, netCDF-4, COG, or Zarr
      itself. A numeric variable's `_FillValue` has to be a number, and each axis takes one dimension
      scale.

    An archive that meets these is a datacube over its whole record at the cost of a manifest, without
    changing a byte of what it already distributes.
    """)

    println(io, "\n## The rows nothing could be read from\n")
    unread = filter(r -> r.grade in ("F*", "F", "U"), df)
    println(io, """
    No collection graded `F` or `U` lacks a cube. Each is a series of time-stamped arrays in its own
    catalog record, and the grade says only that no chunk manifest can be written over the bytes as
    they are distributed. The axes below come from each collection's CMR record — level, title,
    granule cadence, temporal extent — rather than from a measurement, because what the grade reports
    is that nothing could be read. Every collection graded `F` or `U` carries one, and stage 4 fails
    if a new one arrives without it.
    """)
    println(io, md_table(unread, [:grade_shown, :short_name, :format, :cube_axes, :record_span];
                         headers = ["Grade", "Product", "Format", "Cube its record describes",
                                    "Record"]))
    println(io, """

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
    """)

    println(io, "\n## How each column was measured\n")
    println(io, """
    **Sampling.** $(sampling_note(df)) Granules are chosen adversarially rather than at random: the
    two earliest in the record, the two latest, and four spread evenly through the interior. The ends
    expose a producer changing chunk shape or CF attributes mid-mission; the interior draws expose a
    change that was made and later reverted, which the two ends agree across, and a swath length that
    varies by orbit rather than by era. $(orbit_note(df))

    A sample can refute stability but cannot establish it, and the two grades are therefore not
    equally strong. A `D` or `F` rests on a counterexample: one pair of granules that disagree, or
    one refusal that names a feature. An `A` or `B` rests on the absence of a counterexample in at
    most $(maximum(df.n_sampled)) granules out of up to tens of millions, so it states that no blocker
    appeared in the sample, not that none exists. The design cuts the other way too: spanning the ends
    of the record makes this the sample most likely to straddle a mid-mission format change, so a
    collection graded `D` because its 2002 granules differ from its 2026 granules may virtualize
    cleanly over any recent span. The grade is a property of the whole record, not of an arbitrary
    subset of it.

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
    is a `B`.$(partial_h2_example(df)) A sample drawn from one part of the record can miss that
    difference entirely, which is what the interior draws and the two ends are for.

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

    **Granules.** CMR's hit count for the collection, as of $(inventory_date()). A collection still
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

    **Tool defects separated from data properties.** A grade describes the archive, so one VirtualiZarr
    defect is corrected before probing: `_extract_attrs` compares a converted attribute against
    `"DIMENSION_SCALE"` without checking it is still a scalar, which raises `ValueError` on any granule
    carrying an attribute of two or more fixed-length strings and aborts the whole file. The probe
    installs a corrected version, in `scripts/vz_shims.py`, through which ICESat-2 `ATL03` reads.

    The HDF4 path, which VirtualiZarr delegates to kerchunk, reads some of NASA's HDF-EOS2 holdings and
    not others: $(hdf4_note(df)) A parser that reports success and produces no chunk manifest is graded
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
    """)

    println(io, "\n## Sample comparability\n")
    pinned = filter(r -> !ismissing(r.pinned_to) && !isempty(String(r.pinned_to)), df)
    mixed = filter(r -> !ismissing(r.sample_differs) && !isempty(String(r.sample_differs)), df)
    println(io, """
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
    $(nrow(pinned)) collections are narrowed this way. Their grades describe a cube over one value of
    the partition across the full time record — for a tiled product, a cube per tile, which is the
    only cube its grid admits.
    """)
    if nrow(pinned) > 0
        println(io, md_table(pinned, [:grade_shown, :short_name, :pinned_to, :n_sampled];
                             headers = ["Grade", "Product", "Narrowed to", "Granules"]))
        println(io, """

        Each pattern is checked against CMR before use: it matches a non-empty subset whose earliest
        and latest granules still span the collection's record. `ATL15` and `SRTMGL1` are the
        exceptions and match one granule each, which is a property of the product — both publish one
        file per configuration or per tile and have no time series within one — so their cross-granule
        criteria report that nothing was comparable rather than comparing files no cube would hold.
        CMR matches a pattern against a granule's producer ID as well as its UR, and the two differ:
        SWOT gives its `Basic` and `WindWave` files one producer ID, so each returned UR is checked
        against the pattern before the sample is drawn.
        """)
    end
    println(io, """
    The remaining differences are counted by a mechanical check: it takes the tokens of each sampled
    granule's filename, collapses the timestamps, and reports whatever tokens the granules do not have
    in common. $(nrow(mixed)) collections still differ, and each difference is one the sample keeps on
    purpose — a counter that is the time step, or a change the archive really contains and a cube
    really has to span.
    """)
    if nrow(mixed) > 0
        println(io, md_table(mixed, [:grade_shown, :short_name, :sample_differs, :difference_kept_because];
                             headers = ["Grade", "Product", "Granules differ in", "Kept because"]))
    end

    println(io, "\n## Coverage\n")
    partial = filter(r -> r.n_probed < r.n_sampled, df)
    println(io, "$(nrow(df)) collections, $(sum(df.n_sampled)) granules opened or attempted.")
    if nrow(partial) > 0
        println(io, "\nCollections where not every sampled granule opened:\n")
        println(io, md_table(partial, [:short_name, :n_probed, :n_attempted, :n_sampled, :unopened];
                             headers = ["Product", "Opened", "Attempted", "Sampled", "Reason"]))
    end

    if isfile(joinpath(RESULTS, "verification.md"))
        println(io, "\n## Verification\n")
        println(io, """
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
        """)
        println(io, "[`results/verification.md`](results/verification.md) holds what each check " *
                    "actually read and returned.\n")
    end

    println(io, "\n## Deploy\n")
    println(io, """
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
    | `.venv/bin/python scripts/verify_endtoend.py` | yes | builds virtual stores and checks the grades against them |

    Stage 3 takes hours: every request pays an Earthdata Login redirect. Stages 2 and 3 accept a list
    of collection short names to redo only those, merging into the existing sample and artifacts, which
    is how a single collection is re-measured without repeating the run.

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
    """)

    out = joinpath(dirname(RESULTS), "README.md")
    write(out, String(take!(io)))
    println("README.md written ($(nrow(df)) rows)")
end

build_report()
