#!/usr/bin/env bash
#
# memory-index-lint.sh — guard MEMORY.md against the Claude Code load-cutoff.
#
# The Claude Code binary auto-loads MEMORY.md and nags ("approaching the read
# limit") once the index reaches 80% of its byte cap, truncating the tail past
# the cap. Verified against the binary (v2.1.x): byte cap ≈ 24.4 KB, warn
# fraction yEm = 0.8 (nag at ≈ 19.5 KB), and the binary's own suggested compact
# target is 0.7 × cap ≈ 17.1 KB. This lint targets that 17.1 KB compact point so
# a passing lint guarantees the nag NEVER fires (it sits below the 0.8 trigger).
#
# The index is the activation-ranked hot tier (memory-index-render.py): cold
# memories live on disk + QMD but are intentionally absent from MEMORY.md, so a
# body file with no index entry is EXPECTED, not drift. Parity therefore only
# flags DEAD links (index entries with no body file); orphan bodies are normal.
#
#   MEMORY_INDEX   path to the index   (default ~/.claude/projects/-Users-shawnroos/memory/MEMORY.md)
#   MEMORY_DIR     dir holding bodies  (default: dirname of MEMORY_INDEX)
#   MAX_BYTES      default 17408 (17 KiB, under the 17.1 KB native compact target)
#   MAX_LINES      default 200
#   --strict       accepted for compatibility; dead links now always fail and cold
#                  bodies are never drift, so it no longer changes the verdict

set -euo pipefail

STRICT=0
[ "${1:-}" = "--strict" ] && STRICT=1

# Derive the project-store slug from $HOME (e.g. /Users/jane -> -Users-jane) so
# the default isn't pinned to one user's path.
_proj_slug="-${HOME#/}"; _proj_slug="${_proj_slug%/}"; _proj_slug="${_proj_slug//\//-}"
DEFAULT_INDEX="$HOME/.claude/projects/$_proj_slug/memory/MEMORY.md"
INDEX="${MEMORY_INDEX:-$DEFAULT_INDEX}"
DIR="${MEMORY_DIR:-$(dirname "$INDEX")}"
MAX_BYTES="${MAX_BYTES:-17408}"
MAX_LINES="${MAX_LINES:-200}"

if [ ! -f "$INDEX" ]; then
  echo "memory-index-lint: index not found: $INDEX" >&2
  exit 2
fi

STRICT="$STRICT" MEMORY_INDEX="$INDEX" MEMORY_DIR="$DIR" \
MAX_BYTES="$MAX_BYTES" MAX_LINES="$MAX_LINES" python3 <<'PY'
import os, re, sys

index = os.environ["MEMORY_INDEX"]
d = os.environ["MEMORY_DIR"]
max_bytes = int(os.environ["MAX_BYTES"])
max_lines = int(os.environ["MAX_LINES"])
strict = os.environ["STRICT"] == "1"

text = open(index, encoding="utf-8").read()
nbytes = len(text.encode("utf-8"))
nlines = text.count("\n") + (0 if text.endswith("\n") or text == "" else 1)

fail = False

print(f"memory-index-lint: {nbytes} bytes (max {max_bytes}), {nlines} lines (max {max_lines})")
if nbytes >= max_bytes:
    print(f"  FAIL: index is {nbytes} bytes — at/over the {max_bytes} load budget", file=sys.stderr)
    fail = True
if nlines > max_lines:
    print(f"  FAIL: index is {nlines} lines — over the {max_lines} load budget", file=sys.stderr)
    fail = True

# Parity: link targets vs body files. Take the FIRST link on each bullet line (the
# pointer), matching the migrator's BULLET_RE — a `](x.md)` embedded later inside a
# hook description is not a pointer and must not count as a link target.
bullet_link = re.compile(r"^\s*-\s+(?:See\s+)?\[[^\]]*\]\(([^)]+\.md)\)")
links = set()
for ln in text.splitlines():
    m = bullet_link.match(ln)
    if m:
        links.add(m.group(1))
# Recursive, and store-relative: index targets for scoped memories are
# `_scope/<slug>/name.md`, so a flat listdir reports every one of them as a dead
# link the moment a scoped memory goes hot. Mirrors corpus.iter_bodies' walk.
bodies = set()
for root, dirs, files in os.walk(d):
    dirs[:] = [x for x in dirs if not x.startswith(".")]
    for f in files:
        if not f.endswith(".md") or f.startswith("."):
            continue
        rel = os.path.relpath(os.path.join(root, f), d)
        if rel == "MEMORY.md":
            continue
        bodies.add(rel)
dead = sorted(t for t in links if t not in bodies)
# Cold memories (body present, no index entry) are EXPECTED under the projection
# model — the index is the budget-truncated hot tier, not every body. So orphans
# are informational only and never fail; only DEAD links (entry -> missing body)
# indicate real drift.
cold = sorted(f for f in bodies if f not in links)

if dead:
    # Always fail on dead links: the render is the canonical MEMORY.md writer and
    # produces a parity-clean index by construction, so an entry pointing at a
    # missing body is genuine drift (a hand-edit or a lost file), not noise.
    print(f"  FAIL: {len(dead)} index link(s) with no body file: {dead[:5]}",
          file=sys.stderr)
    fail = True
if cold:
    print(f"  info: {len(cold)} cold memorie(s) on disk but not in the hot index "
          f"(expected under the projection model)")
if not dead:
    print(f"  OK: no dead links ({len(links)} hot entries, {len(cold)} cold bodies)")

sys.exit(1 if fail else 0)
PY
