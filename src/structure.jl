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
)
