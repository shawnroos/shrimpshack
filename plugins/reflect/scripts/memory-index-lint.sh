#!/usr/bin/env bash
#
# memory-index-lint.sh — guard MEMORY.md against the Claude Code load-cutoff.
#
# The platform truncates the auto-loaded index at ~25 KB AND ~200 lines, dropping
# the tail silently. This lint HARD-FAILS (exit 1) when either budget is
# exceeded, so the truncation bug can never silently return. It also reports
# entry<->body PARITY drift (index links with no body file, body files with no
# index entry) as warnings; pass --strict to make parity drift fail too.
#
#   MEMORY_INDEX   path to the index   (default ~/.claude/projects/-Users-shawnroos/memory/MEMORY.md)
#   MEMORY_DIR     dir holding bodies  (default: dirname of MEMORY_INDEX)
#   MAX_BYTES      default 25600
#   MAX_LINES      default 200
#   --strict       parity drift also exits non-zero

set -euo pipefail

STRICT=0
[ "${1:-}" = "--strict" ] && STRICT=1

# Derive the project-store slug from $HOME (e.g. /Users/jane -> -Users-jane) so
# the default isn't pinned to one user's path.
_proj_slug="-${HOME#/}"; _proj_slug="${_proj_slug%/}"; _proj_slug="${_proj_slug//\//-}"
DEFAULT_INDEX="$HOME/.claude/projects/$_proj_slug/memory/MEMORY.md"
INDEX="${MEMORY_INDEX:-$DEFAULT_INDEX}"
DIR="${MEMORY_DIR:-$(dirname "$INDEX")}"
MAX_BYTES="${MAX_BYTES:-25600}"
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
bodies = {f for f in os.listdir(d) if f.endswith(".md") and f != "MEMORY.md"}
dead = sorted(t for t in links if t not in bodies)
orphan = sorted(f for f in bodies if f not in links)

if dead:
    print(f"  {'FAIL' if strict else 'WARN'}: {len(dead)} index link(s) with no body file: {dead[:5]}",
          file=sys.stderr)
    if strict:
        fail = True
if orphan:
    print(f"  {'FAIL' if strict else 'WARN'}: {len(orphan)} body file(s) with no index entry: {orphan[:5]}",
          file=sys.stderr)
    if strict:
        fail = True
if not dead and not orphan:
    print(f"  OK: parity clean ({len(links)} entries == {len(bodies)} bodies)")

sys.exit(1 if fail else 0)
PY
