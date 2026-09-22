"""
Stage 5: render the ranked table and its method notes.

Reads `results/virtualizability.csv` and writes `README.md`, which is the report. Runs offline.
"""

using CSV, DataFrames, Dates, Statistics

const RESULTS = joinpath(@__DIR__, "..", "results")

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

    io = IOBuffer()
    println(io, "# EarthDataVirtualizabilityScore\n")
    println(io, """
    $(nrow(df)) NASA Earthdata collections ranked by whether their archives can be served as lazy Zarr
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

    ## Ranking\n""")
    println(io, md_table(df,
        [:grade, :sensor, :short_name, :level, :format, :daac, :s3_region,
         :consolidated_md, :grid_aligned, :chunk_aligned, :time_dim,
         :chunk_shape, :chunk_mb, :n_granules, :volume_tb, :dmrpp, :blocker];
        headers = ["Grade", "Sensor", "Product", "Level", "Format", "DAAC", "S3 region",
                   "Consolidated md", "Grid aligned", "Chunk aligned", "Time dim",
                   "Chunk shape", "Chunk MB", "Granules", "Volume TB", "DMR++", "Deciding criterion"]))

    println(io, "\n## Grades\n")
    println(io, """
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
    """)
    empty_grades = [g for g in ["A", "B", "C", "D", "F", "U"] if !(g in df.grade)]
    isempty(empty_grades) ||
        println(io, "No collection in this set graded $(join(empty_grades, " or ")).\n")

    println(io, "\n## Criteria\n")
    println(io, CRITERIA)

    println(io, "\n## How each column was measured\n")
    println(io, """
    **Sampling.** $(sampling_note(df)) Granules are chosen adversarially rather than at random: the
    two earliest in the record and the two latest, which is what exposes a producer changing chunk
    shape or CF attributes mid-mission. $(orbit_note(df))

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
        println(io, md_table(pinned, [:grade, :short_name, :pinned_to, :n_sampled];
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
        println(io, md_table(mixed, [:grade, :short_name, :sample_differs, :difference_kept_because];
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
    that breaks one is a real finding — two collections here have moved between grades on exactly that.
    """)

    out = joinpath(dirname(RESULTS), "README.md")
    write(out, String(take!(io)))
    println("README.md written ($(nrow(df)) rows)")
end

build_report()
