"""
Granule filename analysis shared by the sampling and scoring stages.

A collection's granules follow one naming template, so the tokens two granule names do not have in
common name whatever distinguishes the files: a band, a variable, a tile, a resolution, a subswath.
Stage 2 uses that to pick the same asset from every granule; stage 4 uses it to report what a sample
failed to hold fixed.
"""

"""
    TIMESTAMP_DIGITS

How many digits a filename token needs before it is read as a timestamp rather than as a label.

NASA granule names spell timestamps in many layouts — `20260630`, `2004m1001t002513`,
`G20140141015` — and what they share is a long run of digits, while a label that identifies contents
carries few: `B09`, `h15v16`, `4km`.
"""
const TIMESTAMP_DIGITS = 6

"""
    filename_of(url) -> String

The filename an object URL ends in, query string removed.
"""
filename_of(url) = first(split(last(split(String(url), "/")), "?"))

"""
    TIMESTAMP_FORMS

Datetime spellings whose own separators are the same characters that separate filename tokens.

`2006-06-12T00-53-43ZN` splits on `-` into pieces too short to recognize as a timestamp, so the whole
span is collapsed before the name is tokenized; otherwise the minutes and seconds read as labels that
distinguish one granule from another. The placeholder carries no digits, so a flag appended to the
last field — CALIPSO writes `ZD` or `ZN` for day and night there — survives as a label.
"""
const TIMESTAMP_FORMS = [
    r"\d{4}-\d{2}-\d{2}[Tt]\d{2}-\d{2}-\d{2}",
    r"\d{4}-\d{2}-\d{2}[Tt]\d{2}:\d{2}:\d{2}",
    r"\d{4}-\d{2}-\d{2}",
]

"""
    name_tokens(url) -> Vector{String}

The `.`, `_`, and `-` separated tokens of a granule's filename, timestamps collapsed first.
"""
function name_tokens(url)
    base = filename_of(url)
    for re in TIMESTAMP_FORMS
        base = replace(base, re => "#")
    end
    return String.(split(base, r"[._\-]+"; keepempty = false))
end

"""
    timestamp_token(tok) -> Bool

Whether a filename token carries a timestamp rather than naming the file's contents.
"""
timestamp_token(tok) = count(isdigit, tok) >= TIMESTAMP_DIGITS || !isnothing(tryparse(Int, tok))

"""
    content_tokens(url) -> Set{String}

The tokens of a granule's filename that identify what the file holds, timestamps excluded.
"""
content_tokens(url) = Set(t for t in name_tokens(url) if !timestamp_token(t))

"""
    asset_keys(candidates) -> Dict{String,String}

An identifier for each of one granule's data objects, mapped to its URL.

What identifies an asset is whatever distinguishes it from the granule's *other* assets: the tokens a
candidate carries that its siblings do not. Anything the siblings share describes the granule — its
tile, its timestamp, its version — and using that would make two granules of one band look like
different assets merely because they cover different tiles. A granule offering a single object has
one asset whose key is empty, since nothing distinguishes it.
"""
function asset_keys(candidates)
    cands = String.(candidates)
    toks = content_tokens.(cands)
    shared = length(toks) == 1 ? first(toks) : reduce(intersect, toks)
    out = Dict{String,String}()
    for (u, t) in zip(cands, toks)
        out[join(sort(collect(setdiff(t, shared))), "+")] = u
    end
    return out
end
