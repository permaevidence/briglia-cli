"""Narrow r4 migration: ownerless exhaustion stops before a forced-final request.

The actual owned-loop replacement is required on both protocols by
active_turn_compaction_test.py. All unaffected lifecycle bytes remain frozen.
"""
import copy
from prune_lifecycle_migration import verify_migration as verify_r3


def verify_migration(expected, actual, compare):
    restored = copy.deepcopy(actual)
    compare({"ownerRequired": True}, actual["observations"]["loop-exhausted"], "r4.ownerless")
    restored["observations"]["loop-exhausted"] = expected["observations"]["loop-exhausted"]
    first = next(c for c in expected["captures"] if c["fixture"] == "loop-exhausted-0")
    compare(first, next(c for c in actual["captures"] if c["fixture"] == "loop-exhausted-0"), "r4.firstRequest")
    if any(c["fixture"] == "loop-exhausted-1" for c in actual["captures"]):
        raise RuntimeError("r4: ownerless exhaustion sent a forced-final request")
    missing = next(c for c in expected["captures"] if c["fixture"] == "loop-exhausted-1")
    offset = next(i for i, c in enumerate(restored["captures"]) if c["fixture"] == "loop-exhausted-0") + 1
    restored["captures"].insert(offset, missing)
    verify_r3(expected, restored, compare)
