"""
Corrections to VirtualiZarr 2.7.3 applied before probing, so that a tool defect is not mistaken for
a property of the data.

A parser refusal is normally the answer — it names a feature the archival file uses that a Zarr
chunk manifest cannot express. A crash on input the parser is meant to handle is not of that kind,
and leaving it in place would report a dataset as unvirtualizable when the obstruction is a fixable
line of Python. `ACTIVE` names the shims installed, so the report can state which rows depended on
one.

A shim is only admissible when it cannot change the layout that gets recorded. The `KeyError` raised
by kerchunk's HDF4 backend at `hdf4.py:213` is deliberately left unshimmed for that reason: it comes
from the branch that reads an array's data-block references, so skipping it would yield arrays
declaring dimensions but no chunks — a wrong answer in place of a failed one.
"""

from __future__ import annotations

ACTIVE: list[str] = []


def patch_hdf5_string_array_attrs() -> None:
    """
    Let `HDFParser` read a granule holding a multi-element string attribute.

    `_extract_attrs` converts a fixed-length-string attribute to a string array and then tests it
    against `"DIMENSION_SCALE"`. For an attribute of two or more strings that comparison is
    elementwise, and its array result raises `ValueError` where a bool is required. The test belongs
    only on values that are still scalar strings after conversion. Attribute values are recorded
    exactly as upstream records them.
    """
    import numpy as np
    from virtualizarr.parsers.hdf import hdf as _hdf

    hidden = {
        "REFERENCE_LIST", "CLASS", "DIMENSION_LIST", "NAME", "_Netcdf4Dimid",
        "_Netcdf4Coordinates", "_nc3_strict", "_NCProperties",
    }

    def _extract_attrs(h5obj):
        import h5py

        attrs = {}
        for n, v in h5obj.attrs.items():
            if n in hidden:
                continue
            if isinstance(v, bytes):
                v = v.decode("utf-8") or " "
            elif isinstance(v, (np.ndarray, np.number, np.bool_)):
                if v.dtype.kind == "S":
                    v = v.astype(str)
                if np.size(v) == 1:
                    v = np.asarray(v).flatten()[0]
                    if isinstance(v, (np.ndarray, np.number, np.bool_)):
                        v = v.tolist()
                    elif isinstance(v, np.str_):
                        v = str(v)
                else:
                    v = np.asarray(v).tolist()
            elif isinstance(v, h5py._hl.base.Empty):
                v = ""
            if isinstance(v, str) and v == "DIMENSION_SCALE":
                continue
            attrs[n] = v
        return attrs

    _hdf._extract_attrs = _extract_attrs
    ACTIVE.append("hdf5-string-array-attrs")


def install() -> list[str]:
    """
    Apply every shim and return their names.
    """
    patch_hdf5_string_array_attrs()
    return list(ACTIVE)
