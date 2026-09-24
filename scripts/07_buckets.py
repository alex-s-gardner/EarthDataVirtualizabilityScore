"""
Stage 7: label every refusal stage 3 recorded with NASA IMPACT's failure bucket. Runs offline.

The [virtual-zarr-coverage survey](https://nasa-impact.github.io/virtual-zarr-coverage/) classifies a
failed virtualization attempt into one of 22 buckets, which is the vocabulary its maintainers
prioritize VirtualiZarr work from. Labelling this benchmark's refusals with the same function makes
the two surveys comparable row by row, and says which of the failures found here that vocabulary does
not yet name — a bucket of `OTHER` is a class of failure their taxonomy has no entry for, which is the
form their own "adding a new bucket" workflow asks for a contribution in.

Reads `results/probe/*.json`, writes `results/buckets.json`.
"""

from __future__ import annotations

import json
import sys
from collections import Counter
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
RESULTS = REPO / "results"
sys.path.insert(0, str(REPO / "vendor"))

from nasa_impact_taxonomy import classify  # noqa: E402 - path set above


def refusals(probes: list[dict]) -> list[tuple[str, str]]:
    """
    The `(error_type, error_message)` pair of every granule that did not open.
    """
    return [(str(p.get("error_type") or ""), str(p.get("error") or ""))
            for p in probes if not p.get("ok")]


#: Error types raised by this probe's own bounds rather than by a reader meeting the file.
_OURS_BY_TYPE = {"ProbeTimeout", "ProbeCrash", "GenericError", "ConnectionError", "TimeoutError",
                 "PermissionDeniedError", "NotSupportedError"}

#: Message fragments marking the same thing where the type does not.
_OURS_BY_MESSAGE = ("copy-to-disk limit", "Range request not supported", "error sending request",
                    "Generic HTTP error")


def ours(error_type: str, message: str) -> bool:
    """
    Whether a refusal is a limit of this measurement rather than a reader refusing a file.

    A wall-clock budget, a ceiling on how large a file this probe will copy to disk, and a request
    that failed in transport say nothing about the granule, so none of them is a class of failure
    another survey's taxonomy is missing. Counting them as one would report this probe's own bounds as
    a gap in somebody else's vocabulary.
    """
    return error_type in _OURS_BY_TYPE or any(f in message for f in _OURS_BY_MESSAGE)


def collapse(message: str) -> str:
    """
    A message with its numbers replaced, so one class of failure is one entry.

    Sizes, array indices, and dimension lengths vary per granule while naming the same obstruction.
    """
    import re

    return re.sub(r"\d+", "N", message)[:100]


def main() -> int:
    out: dict[str, dict] = {}
    per_bucket: Counter[str] = Counter()
    unnamed: Counter[str] = Counter()
    unnamed_where: dict[str, set[str]] = {}

    for path in sorted((RESULTS / "probe").glob("*.json")):
        doc = json.loads(path.read_text())
        sn = doc["short_name"]
        # Only a reader meeting the file is a virtualization failure another taxonomy could name.
        pairs = [(et, msg) for et, msg in refusals(doc["probes"]) if not ours(et, msg)]
        if not pairs:
            continue
        labelled = [(et, msg, str(classify(et, msg))) for et, msg in pairs]
        buckets = sorted({b for _, _, b in labelled})
        for b in buckets:
            per_bucket[b] += 1
        for et, msg, b in labelled:
            if b == "OTHER":
                key = f"{et}: {collapse(msg)}"
                unnamed[key] += 1
                unnamed_where.setdefault(key, set()).add(sn)
        out[sn] = {
            "buckets": buckets,
            "n_refused": len(pairs),
            "example": {"error_type": labelled[0][0], "error": labelled[0][1][:200],
                        "bucket": labelled[0][2]},
        }

    (RESULTS / "buckets.json").write_text(json.dumps({
        "source": "NASA-IMPACT/virtual-zarr-coverage@65c8cec src/vzc/core/taxonomy.py",
        "note": "Refusals bounded by this probe rather than by a reader meeting the file are "
                "excluded; they are limits of this measurement, not classes of failure.",
        "collections": out,
        "collections_per_bucket": dict(per_bucket.most_common()),
        "unnamed": [{"error": k, "n_granules": n,
                     "collections": sorted(unnamed_where[k])} for k, n in unnamed.most_common()],
    }, indent=1))

    named = sum(n for b, n in per_bucket.items() if b != "OTHER")
    print(f"{len(out)} collections refused by a reader -> results/buckets.json")
    print(f"  bucketed by their taxonomy: {named} collections; "
          f"unnamed classes: {len(unnamed)}")
    for b, n in per_bucket.most_common():
        print(f"    {b}: {n}")
    print("  classes their taxonomy has no entry for:")
    for k, n in unnamed.most_common():
        print(f"    {n:3} granules  {k[:96]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
