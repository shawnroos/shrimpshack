#!/usr/bin/env bash
#
# apply-memory-protocol.sh <artifact.md> — replace the "## Memory Protocol"
# section in CLAUDE.md with the version carried in the artifact. Idempotent,
# backs up before editing, and conservative: if the section boundary is ambiguous
# (zero or many "## Memory Protocol" headings) it skips with a warning rather than
# risk mangling the file.
#
#   CLAUDE_MD   target file (default ~/.claude/CLAUDE.md)
#
# Exit 0 = applied or already-applied; 2 = skipped (ambiguous, apply by hand);
# 1 = hard error.

set -uo pipefail

ARTIFACT="${1:?usage: apply-memory-protocol.sh <artifact.md>}"
TARGET="${CLAUDE_MD:-$HOME/.claude/CLAUDE.md}"

ARTIFACT="$ARTIFACT" TARGET="$TARGET" python3 <<'PY'
import os, re, sys, shutil, tempfile

artifact = os.environ["ARTIFACT"]
target = os.environ["TARGET"]

art = open(artifact, encoding="utf-8").read()
m = re.search(r"(^## Memory Protocol\b.*)", art, re.S | re.M)
if not m:
    print("apply-memory-protocol: artifact has no '## Memory Protocol' section", file=sys.stderr)
    sys.exit(1)
new_section = m.group(1).rstrip() + "\n"

if not os.path.exists(target):
    print(f"apply-memory-protocol: target not found: {target}", file=sys.stderr)
    sys.exit(1)
doc = open(target, encoding="utf-8").read()

# Idempotency sentinel — a phrase unique to the new section.
if "QMD is the recall layer" in doc:
    print("apply-memory-protocol: already applied — no change")
    sys.exit(0)

# The existing section runs from its "## Memory Protocol" heading to the next
# top-level "## " heading (or EOF). Scan line-by-line tracking fenced code blocks
# so a "## " line *inside* a ``` fence is never mistaken for a heading/boundary
# (mistaking it truncates the splice and corrupts the file). Require exactly one
# real heading to splice safely.
lines = doc.splitlines(keepends=True)
fence_re = re.compile(r"^\s*(```|~~~)")
heading_re = re.compile(r"^## Memory Protocol\b")

in_fence = False
heads = []
for i, ln in enumerate(lines):
    if fence_re.match(ln):
        in_fence = not in_fence
        continue
    if not in_fence and heading_re.match(ln):
        heads.append(i)
# Unbalanced fences (still open at EOF) make section boundaries undecidable — a
# stray fence could hide a real heading. Skip rather than risk deleting content.
if in_fence:
    print(f"apply-memory-protocol: unbalanced code fence in {target} — skipping, apply by hand",
          file=sys.stderr)
    sys.exit(2)
if len(heads) != 1:
    print(f"apply-memory-protocol: found {len(heads)} '## Memory Protocol' heading(s) "
          f"in {target} — skipping, apply by hand", file=sys.stderr)
    sys.exit(2)

# Fences are balanced (checked above), so a single forward scan starting outside a
# fence (the state entering the heading) finds the next real '## ' boundary without
# the two-scan asymmetry that could over-consume the tail.
hstart = heads[0]
in_fence = False
hend = len(lines)
for j in range(hstart + 1, len(lines)):
    if fence_re.match(lines[j]):
        in_fence = not in_fence
        continue
    if not in_fence and lines[j].startswith("## "):
        hend = j
        break

start = sum(len(x) for x in lines[:hstart])
end = sum(len(x) for x in lines[:hend])
tail = doc[end:]
updated = doc[:start] + new_section.rstrip() + "\n\n" + tail.lstrip("\n")
updated = updated.rstrip() + "\n"

shutil.copy2(target, target + ".bak")
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(target) or ".", suffix=".tmp")
with os.fdopen(fd, "w", encoding="utf-8") as f:
    f.write(updated)
os.replace(tmp, target)
print(f"apply-memory-protocol: updated {target} (backup {target}.bak)")
PY
