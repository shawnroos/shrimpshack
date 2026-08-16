#!/usr/bin/env bash
#
# reflect_run_test.sh — tests for scripts/reflect-run.sh, the mechanical half of
# a /reflect run.
#
# Its own file rather than more lines in harness.sh, which is already ~1350 and
# was flagged for exactly this in review. harness.sh invokes it the same way it
# invokes the python runners: two checks, exit code plus a non-empty tally.
#
# EVERYTHING runs against fixtures under a temp root — REFLECT_MEMORY_DIR,
# REFLECT_DOC_STORE, and REFLECT_RUN_NO_RECONCILE=1. The operator's live memory
# dir, live MEMORY.md and live qmd config are never touched.
#
# The assertions are deliberately about OBSERVED EFFECTS: what the frontmatter
# says afterward, which files exist in the store, what the summary line reports.
# Asserting that the script exited 0 would restate the defect this plugin was
# fixed for last week.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RR="$REPO/scripts/reflect-run.sh"
PASS=0; FAIL=0
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/reflect-run-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

ok()   { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL - $1" >&2; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

TODAY="$(date +%Y-%m-%d)"

# resolve_last_used <file> — the date the ACTIVATION READER would resolve.
# It deliberately reuses memory_activation.py's own regex rather than a
# hand-rolled grep: the defect this file exists to catch is precisely a write
# that satisfies a narrower pattern than the reader's, so a narrower assertion
# here would pass over the bug in the same way the bug passed over itself.
resolve_last_used() {
  python3 - "$1" <<'PY'
import re, sys
s = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r'^\s*last_used\s*:\s*(\d{4}-\d{2}-\d{2})', s, re.M)
print(m.group(1) if m else "NONE")
PY
}

count_last_used() { grep -c 'last_used' "$1" || true; }

# ------------------------------------------------------------ fixture builder
new_store() {
  local d="$1"
  rm -rf "$d"; mkdir -p "$d/mem" "$d/store"
  printf '# Memory Index\n\n- [nested](nested.md) — n\n' > "$d/mem/MEMORY.md"

  # Three frontmatter shapes. The NESTED one is the case that matters and the
  # one the live store overwhelmingly uses: the field sits indented inside the
  # `metadata:` block, so a writer anchored at column zero appends a second
  # field instead of updating this one.
  cat > "$d/mem/nested.md" <<'EOF'
---
name: nested
metadata:
  type: feedback
  last_used: 2020-01-01
---
body
EOF
  cat > "$d/mem/toplevel.md" <<'EOF'
---
name: toplevel
last_used: 2020-01-01
metadata:
  type: feedback
---
body
EOF
  cat > "$d/mem/absent.md" <<'EOF'
---
name: absent
metadata:
  type: feedback
---
body
EOF
  # Already current: proves `updated` counts a CHANGED file, not a file visited.
  cat > "$d/mem/current.md" <<EOF
---
name: current
metadata:
  type: feedback
  last_used: $TODAY
---
body
EOF
}

run_rr() {
  local d="$1"; shift
  REFLECT_MEMORY_DIR="$d/mem" REFLECT_DOC_STORE="$d/store" REFLECT_RUN_NO_RECONCILE=1 \
    bash "$RR" "$@" 2>"$d/err.txt"
}

# ============================================================ last_used writes
echo "== last_used: written where the activation reader looks =="
D="$ROOT/a"; new_store "$D"
OUT="$(run_rr "$D" --applied "nested toplevel absent current" --session-id TESTSID)"

# The nested case is the regression guard. Reverting the writer to an
# unindented `^last_used:` match leaves this file resolving 2020-01-01 while
# the run still reports success — mutation-verified, and the reason this
# assertion reads the resolved value rather than the file's byte count.
check "nested metadata.last_used is UPDATED in place, not shadowed" \
  '[ "$(resolve_last_used "$D/mem/nested.md")" = "$TODAY" ]'
check "top-level last_used is updated in place" \
  '[ "$(resolve_last_used "$D/mem/toplevel.md")" = "$TODAY" ]'
check "a memory with no last_used gets one the reader can see" \
  '[ "$(resolve_last_used "$D/mem/absent.md")" = "$TODAY" ]'

# One field per file. A second field is the silent-no-op signature: the file
# looks freshly bumped to a human reading the bottom of the frontmatter while
# the reader keeps resolving the stale one above it.
check "nested memory carries exactly ONE last_used field afterward" \
  '[ "$(count_last_used "$D/mem/nested.md")" = "1" ]'
check "top-level memory carries exactly ONE last_used field afterward" \
  '[ "$(count_last_used "$D/mem/toplevel.md")" = "1" ]'
check "absent-field memory carries exactly ONE last_used field afterward" \
  '[ "$(count_last_used "$D/mem/absent.md")" = "1" ]'

check "the inserted field lands INSIDE the frontmatter, not in the body" \
  'python3 -c "
import sys
s=open(\"$D/mem/absent.md\").read().split(chr(10))
end=[i for i,l in enumerate(s) if l.strip()==\"---\"][1]
sys.exit(0 if any(\"last_used\" in l for l in s[:end]) else 1)"'

echo "== observed-effect counting =="
# `current` was already today: it is applied and logged, but nothing changed on
# disk, so it must not be counted. A tally that counts memories VISITED would
# report 4 here.
check "updated counts only files whose bytes changed (3 of 4 applied)" \
  'echo "$OUT" | grep -q "updated=3"'
check "every applied memory is logged, including the unchanged one" \
  '[ "$(grep -c applied "$D/mem/MEMORY_USE.log")" = "4" ]'
check "the use log carries the session id" \
  'grep -q "session:TESTSID" "$D/mem/MEMORY_USE.log"'

echo "== a memory named in --applied that does not exist =="
D2="$ROOT/b"; new_store "$D2"
OUT2="$(run_rr "$D2" --applied "nested no_such_memory")"
check "a missing memory is named, not silently dropped" \
  'echo "$OUT2" | grep -q "missing_memories:.*no_such_memory"'
check "a missing memory does not stop the memories around it" \
  '[ "$(resolve_last_used "$D2/mem/nested.md")" = "$TODAY" ]'
check "a missing memory is not counted as updated" \
  'echo "$OUT2" | grep -q "updated=1"'
# A phantom log line would inflate the activation of a memory that does not
# exist, and would survive a later save under that name.
check "a missing memory writes no use-log line" \
  '! grep -q no_such_memory "$D2/mem/MEMORY_USE.log"'

echo "== document capture =="
D3="$ROOT/c"; new_store "$D3"
mkdir -p "$D3/wt/docs/solutions/logic-errors" "$D3/wt/docs/brainstorms" "$D3/wt/docs/plans"
echo solution  > "$D3/wt/docs/solutions/logic-errors/thing.md"
echo brainstorm> "$D3/wt/docs/brainstorms/idea.md"
echo handoff   > "$D3/wt/docs/handoff.md"
echo plan      > "$D3/wt/docs/plans/plan.md"
OUT3="$(run_rr "$D3" --capture-from "$D3/wt")"
check "a durable solution doc is captured" '[ -f "$D3/store/solutions/thing.md" ]'
check "a brainstorm is captured"           '[ -f "$D3/store/brainstorms/idea.md" ]'
check "a handoff is captured"              'ls "$D3/store/handoffs/"*handoff.md >/dev/null 2>&1'
# Plans age out with their worktree by design; capturing them would fill the
# store with superseded drafts.
check "an ephemeral plan is NOT captured" \
  '! find "$D3/store" -name plan.md | grep -q .'
check "captured counts the three durable docs" 'echo "$OUT3" | grep -q "captured=3"'

# Re-running must not re-count identical files: `captured` is "files that
# differed", not "files considered", and a store that reports 3 every run tells
# you nothing about whether anything new arrived.
OUT3B="$(run_rr "$D3" --capture-from "$D3/wt")"
check "an unchanged doc is not re-captured on a second run" \
  'echo "$OUT3B" | grep -q "captured=0"'
echo changed > "$D3/wt/docs/solutions/logic-errors/thing.md"
OUT3C="$(run_rr "$D3" --capture-from "$D3/wt")"
check "an EDITED doc is re-captured" 'echo "$OUT3C" | grep -q "captured=1"'
check "the store copy actually holds the new bytes" \
  'grep -q changed "$D3/store/solutions/thing.md"'

echo "== embedded= is passed through, never derived =="
# The reconciler is the only thing that can observe an embed. These stubs prove
# the runner REPORTS what it was told: a reconciler that says `unknown` must not
# be smoothed into a number, and one that dies without printing a summary must
# not read as a clean zero.
D4="$ROOT/d"; new_store "$D4"
STUBDIR="$D4/stub"; mkdir -p "$STUBDIR"
make_stub() { printf '#!/bin/sh\n%s\n' "$1" > "$STUBDIR/qmd-reconcile-collections.sh"; }

RRSTUB="$D4/reflect-run.sh"
# Run the real script from a directory whose sibling scripts are stubs, so the
# reconcile call resolves to the stub without editing the script under test.
cp "$RR" "$RRSTUB"
: > "$STUBDIR/x"; cp "$RRSTUB" "$STUBDIR/reflect-run.sh"

make_stub 'echo "qmd-reconcile: done (created=0 existing=5 embedded=unknown failed=0)"'
OUT4="$(REFLECT_MEMORY_DIR="$D4/mem" REFLECT_DOC_STORE="$D4/store" bash "$STUBDIR/reflect-run.sh" 2>/dev/null)"
check "embedded=unknown is reported verbatim" 'echo "$OUT4" | grep -q "embedded=unknown"'

make_stub 'echo "qmd-reconcile: done (created=0 existing=5 embedded=0 failed=0)"'
OUT5="$(REFLECT_MEMORY_DIR="$D4/mem" REFLECT_DOC_STORE="$D4/store" bash "$STUBDIR/reflect-run.sh" 2>/dev/null)"
check "embedded=0 is reported verbatim" 'echo "$OUT5" | grep -q "embedded=0"'

# Exit zero with no summary is the false-clean shape: the command ran, so an
# exit-code-driven tally would print 0 — meaning "nothing to embed" when it
# actually means "we never found out".
make_stub 'exit 0'
OUT6="$(REFLECT_MEMORY_DIR="$D4/mem" REFLECT_DOC_STORE="$D4/store" bash "$STUBDIR/reflect-run.sh" 2>/dev/null)"
check "a silent exit-0 reconciler yields unknown, never a false clean 0" \
  'echo "$OUT6" | grep -q "embedded=unknown"'

make_stub 'echo "boom" >&2; exit 3'
OUT7="$(REFLECT_MEMORY_DIR="$D4/mem" REFLECT_DOC_STORE="$D4/store" bash "$STUBDIR/reflect-run.sh" 2>/dev/null)"
check "a FAILING reconciler yields unknown and does not abort the run" \
  'echo "$OUT7" | grep -q "embedded=unknown" && echo "$OUT7" | grep -q "logged:"'

echo "== the REFLECT.log line =="
check "one log line was appended per run" \
  '[ "$(wc -l < "$D/mem/REFLECT.log")" -ge 1 ]'
check "the log line carries every field a parser expects" \
  'grep -q "updated=.* saved=.* merged=.* retired=.* compounded=.* index_tightened=.* captured=.* embedded=.* worktrees_removed=.* triggers_declared=.* triggers_pruned=" "$D/mem/REFLECT.log"'
# The runner scans; it never removes. Emitting anything else here would claim a
# destructive action nobody took.
check "worktrees_removed is always 0 — the runner never removes one" \
  'grep -q "worktrees_removed=0" "$D/mem/REFLECT.log"'
check "the passed-through judgment counts appear as given" \
  'echo "$OUT2" | grep -q "logged:.*saved=0.*compounded=0"'

D5="$ROOT/e"; new_store "$D5"
OUT8="$(run_rr "$D5" --trigger PR_event --saved 2 --merged 1 --retired 3 --compounded 1 \
  --triggers-declared 4 --triggers-pruned 5)"
check "judgment counts are recorded exactly as the agent reported them" \
  'echo "$OUT8" | grep -q "saved=2 merged=1 retired=3 compounded=1" && echo "$OUT8" | grep -q "triggers_declared=4 triggers_pruned=5"'
check "the trigger name is recorded" 'echo "$OUT8" | grep -q "PR_event"'

echo "== argument validation =="
D6="$ROOT/f"; new_store "$D6"
run_rr "$D6" --saved notanumber >/dev/null 2>&1; VRC=$?
check "a non-numeric count is rejected instead of printed as a tally" '[ "$VRC" != "0" ]'
REFLECT_MEMORY_DIR="$ROOT/nope" REFLECT_DOC_STORE="$D6/store" REFLECT_RUN_NO_RECONCILE=1 \
  bash "$RR" >/dev/null 2>&1; MRC=$?
check "a missing memory dir is a hard error, not a silent empty run" '[ "$MRC" != "0" ]'

echo
echo "reflect_run_test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
