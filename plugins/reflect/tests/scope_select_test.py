#!/usr/bin/env python3
"""Deterministic tests for scope.select_scoped (plan 003 U4 selection logic).

Runs the partition against synthetic qmd-format results (the real mangled-path
shape) so the boost/suppress behavior is proven without a live qmd search. Exits
non-zero with a message on the first failure.
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts", "scoped-memory"))
import scope  # noqa: E402

RESULTS = [
    {"file": "qmd://cm/g1.md", "score": 0.9},                         # global
    {"file": "qmd://cm/scope/Users-x-slate/c1.md", "score": 0.5},     # current (mangled path)
    {"file": "qmd://cm/scope/Users-x-acme/s1.md", "score": 0.8},      # sibling
    {"file": "qmd://cm/g2.md", "score": 0.4},                         # global
]
CUR = "-Users-x-slate"
fails = []


def ok(cond, msg):
    if not cond:
        fails.append(msg)


# In-repo: current-repo memory is added FIRST (front-and-center), both globals
# present (not displaced), sibling suppressed.
sel = scope.select_scoped(RESULTS, CUR, 3)
files = [r["file"] for r in sel]
ok(files and files[0] == "qmd://cm/scope/Users-x-slate/c1.md", "current-repo not front")
ok("qmd://cm/g1.md" in files and "qmd://cm/g2.md" in files, "a global was displaced")
ok(not any("acme" in f for f in files), "sibling repo not suppressed")
ok(sum(1 for f in files if "scope/" not in f) == 2, "global slot count != 2")

# repo_floor gates the extra (0.5 < 0.7 -> current dropped).
flo = scope.select_scoped(RESULTS, CUR, 3, repo_floor=0.7)
ok(not any("Users-x-slate" in r["file"] for r in flo), "repo_floor did not gate the extra")

# Below the floor still keeps globals.
ok(sum(1 for r in flo if "scope/" not in r["file"]) == 2, "globals lost when extra gated")

# Outside any repo (global session): scoped memories suppressed, globals only.
glob = scope.select_scoped(RESULTS, "global", 3)
ok(not any("scope/" in r["file"] for r in glob), "scoped memory leaked into a home session")
ok(len(glob) == 2, "home session should return the 2 globals")

# k=1: still adds the extra alongside the single global slot (K+1 = 2 total).
one = scope.select_scoped(RESULTS, CUR, 1)
ok(len(one) == 2 and one[0]["file"].endswith("c1.md"), "K+1 shape wrong at k=1")

if fails:
    print("FAIL: " + "; ".join(fails))
    sys.exit(1)
print("ok: select_scoped (in-repo boost, no-displacement, floor gate, home suppression, k+1)")
