#!/usr/bin/env python3
# claude-modes V2 U7: structured key-by-key diff between two JSON files.
#
# maint-2 / STATUS: NOT YET WIRED IN. No production caller today; the
#   /mode:status drift display that would consume this is deferred to V2.1
#   (lib/status.sh "Drift detection deferred to V2.1"). Kept (correct +
#   unit-tested) as the ready implementation for that feature.
#
# SCOPE (informational only, once wired):
#   Surfaces "we noticed your settings.json differs from the pristine
#   snapshot in these ways" for forensic clarity. It is NOT a deletion
#   gate — the sidecar fingerprint in <repo>/.claude/modes/.cascade-meta.json
#   is the canonical deletion gate (see plan U7 section).
#
# Output format:
#   - One line per top-level key that differs, in deterministic order.
#   - "+ <key>"  = key present in current but absent in pristine.
#   - "- <key>"  = key absent in current but present in pristine.
#   - "~ <key>"  = key present in both, values differ.
#   - Empty stdout if files are byte-identical or have identical top-level
#     structure (NOTE: only top-level keys are diffed; this is intentionally
#     shallow to keep the output skimmable).
#
# Argv contract (no shell interpolation; values come via argv):
#   drift-diff.py <pristine_path> <current_path>
#
# Exit codes:
#   0 = success (regardless of whether files differ)
#   2 = one of the files is missing
#   3 = one of the files is unparseable JSON

import json
import os
import sys
from typing import Any


def _load(path: str) -> dict:
    if not os.path.exists(path):
        sys.stderr.write(f"drift-diff: file missing: {path}\n")
        sys.exit(2)
    try:
        with open(path, "r") as f:
            text = f.read()
        if not text.strip():
            return {}
        data = json.loads(text)
    except json.JSONDecodeError as e:
        sys.stderr.write(f"drift-diff: not valid JSON: {path}: {e}\n")
        sys.exit(3)
    except OSError as e:
        sys.stderr.write(f"drift-diff: I/O error: {path}: {e}\n")
        sys.exit(3)
    if not isinstance(data, dict):
        # Top-level non-object isn't something we know how to diff
        # key-by-key. Treat as opaque.
        sys.stderr.write(f"drift-diff: top-level not an object: {path}\n")
        sys.exit(3)
    return data


def _diff(pristine: dict, current: dict) -> list:
    """Return list of lines describing top-level key differences.

    Only top-level keys are compared. Value comparison is shallow:
    two values are "equal" iff their JSON serializations match. This
    keeps the helper deterministic and avoids worrying about dict-key
    order for nested structures.
    """
    lines: list = []
    all_keys = sorted(set(pristine.keys()) | set(current.keys()))
    for k in all_keys:
        in_p = k in pristine
        in_c = k in current
        if in_p and not in_c:
            lines.append(f"- {k}")
        elif in_c and not in_p:
            lines.append(f"+ {k}")
        else:
            # Both present — compare by JSON serialization.
            pv = json.dumps(pristine.get(k), sort_keys=True)
            cv = json.dumps(current.get(k), sort_keys=True)
            if pv != cv:
                lines.append(f"~ {k}")
    return lines


def main() -> int:
    if len(sys.argv) != 3:
        sys.stderr.write(
            "drift-diff.py: usage: drift-diff.py <pristine_path> <current_path>\n"
        )
        return 2
    pristine_path = sys.argv[1]
    current_path = sys.argv[2]

    pristine = _load(pristine_path)
    current = _load(current_path)

    for line in _diff(pristine, current):
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
