#!/usr/bin/env bash
#
# reflect-run.sh — the mechanical half of a /reflect run, in one command.
#
# The skill's passes split cleanly in two. The JUDGMENT passes (what was learned,
# what to save, what merges into what, whether a worktree's leftovers matter) stay
# with the agent. The MECHANICAL passes are the same shell every time, and hand-
# writing them per run produced a 40-line blob in the transcript on every /reflect —
# which is what this replaces.
#
# It performs: pass 2 mechanics (last_used bumps + MEMORY_USE.log), trigger manifest
# recompile, pass 6 (index render + lint), pass 7 (durable doc capture), pass 8
# (qmd reconcile + index + embed), pass 9 SCAN, and pass 10 (the REFLECT.log line).
#
# WHAT IT WILL NOT DO — pass 9 scans and never removes. Removing a worktree is
# destructive and needs the judgment this script deliberately does not have (is that
# untracked file the only copy?), so the scan reports state and the agent decides.
#
# EVERY COUNT IS AN OBSERVED EFFECT, never a step that ran. `updated` counts files
# whose bytes changed, `captured` counts files whose bytes differ from the store copy,
# `index_tightened` is 1 only when MEMORY.md actually changed. `embedded` is copied
# VERBATIM out of the reconciler's own summary and is never recomputed here — it is
# `0` or the literal `unknown`, and inferring it from an exit code is the exact defect
# this plugin was fixed for (see docs/solutions/logic-errors/
# a-tally-keyed-on-exit-status-reports-work-that-never-happened.md).
#
# Usage:
#   reflect-run.sh --trigger manual \
#                  --applied "mem_a mem_b" \
#                  --saved 1 --merged 0 --retired 0 --compounded 1 \
#                  --triggers-declared 1 --triggers-pruned 0 \
#                  --capture-from /path/to/worktree \
#                  --scan-worktrees /Users/you/projects/foo
#
# Overrides for tests (all default to the live locations):
#   REFLECT_MEMORY_DIR, REFLECT_DOC_STORE, REFLECT_RUN_NO_RECONCILE=1
#
# Prints a compact `key=value` report on stdout, ending with the REFLECT.log line it
# appended. Exit non-zero only if the memory dir is unusable — every pass is
# best-effort so one failure cannot starve the rest.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
_proj_slug="-${HOME#/}"; _proj_slug="${_proj_slug%/}"; _proj_slug="${_proj_slug//\//-}"
MEMORY_DIR="${REFLECT_MEMORY_DIR:-$CLAUDE_HOME/projects/$_proj_slug/memory}"
DOC_STORE="${REFLECT_DOC_STORE:-$CLAUDE_HOME/doc-store}"

TRIGGER="manual"
APPLIED=""
SAVED=0; MERGED=0; RETIRED=0; COMPOUNDED=0
TRIG_DECL=0; TRIG_PRUNED=0
SESSION_ID="${CLAUDE_SESSION_ID:-unknown}"
CAPTURE_FROM=()
SCAN_ROOTS=()

die() { echo "reflect-run: $1" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --trigger)            TRIGGER="${2:-}"; shift 2 ;;
    --applied)            APPLIED="${2:-}"; shift 2 ;;
    --saved)              SAVED="${2:-0}"; shift 2 ;;
    --merged)             MERGED="${2:-0}"; shift 2 ;;
    --retired)            RETIRED="${2:-0}"; shift 2 ;;
    --compounded)         COMPOUNDED="${2:-0}"; shift 2 ;;
    --triggers-declared)  TRIG_DECL="${2:-0}"; shift 2 ;;
    --triggers-pruned)    TRIG_PRUNED="${2:-0}"; shift 2 ;;
    --session-id)         SESSION_ID="${2:-unknown}"; shift 2 ;;
    --capture-from)       CAPTURE_FROM+=("${2:-}"); shift 2 ;;
    --scan-worktrees)     SCAN_ROOTS+=("${2:-}"); shift 2 ;;
    -h|--help)            sed -n '2,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)                    die "unknown argument: $1" ;;
  esac
done

[ -d "$MEMORY_DIR" ] || die "memory dir not found: $MEMORY_DIR"

# The counted fields must be numeric before they reach the summary: a stray word
# here would print a plausible-looking tally that no longer means what it says.
for pair in "saved:$SAVED" "merged:$MERGED" "retired:$RETIRED" "compounded:$COMPOUNDED" \
            "triggers-declared:$TRIG_DECL" "triggers-pruned:$TRIG_PRUNED"; do
  case "${pair#*:}" in
    ''|*[!0-9]*) die "--${pair%%:*} must be a non-negative integer, got '${pair#*:}'" ;;
  esac
done

# ---------------------------------------------------------------- pass 2 (mechanics)
TS="$(date -Iseconds 2>/dev/null || date +%Y-%m-%dT%H:%M:%S%z)"
TODAY="$(date +%Y-%m-%d)"
UPDATED=0
MISSING=""

for mem in $APPLIED; do
  f="$MEMORY_DIR/${mem%.md}.md"
  if [ ! -f "$f" ]; then
    MISSING="$MISSING $mem"
    continue
  fi
  before_sum="$(cksum < "$f")"
  MEM_FILE="$f" TODAY="$TODAY" python3 - <<'PY'
import os, re, sys
p = os.environ["MEM_FILE"]; today = os.environ["TODAY"]
s = open(p, encoding="utf-8").read()
if re.search(r'^last_used:.*$', s, re.M):
    s2 = re.sub(r'^last_used:.*$', f'last_used: {today}', s, count=1, flags=re.M)
else:
    # Insert INSIDE the frontmatter, before its closing fence — a last_used line
    # dropped into the body is invisible to the activation reader.
    end = s.find('\n---', 3)
    s2 = s if end == -1 else s[:end] + f'\nlast_used: {today}' + s[end:]
if s2 != s:
    open(p, 'w', encoding="utf-8").write(s2)
PY
  after_sum="$(cksum < "$f")"
  if [ "$before_sum" != "$after_sum" ]; then
    UPDATED=$((UPDATED + 1))
  fi
  # The use log records every application, including the no-op rewrite where
  # last_used was already today — the count of applications is the activation
  # signal, and dropping same-day repeats would understate a memory used twice.
  echo "$TS $mem applied [session:$SESSION_ID] [reflect-run]" >> "$MEMORY_DIR/MEMORY_USE.log"
done
[ -n "$MISSING" ] && echo "reflect-run: no such memory:$MISSING" >&2

if [ -f "$HERE/scoped-memory/triggers.py" ]; then
  python3 "$HERE/scoped-memory/triggers.py" compile >/dev/null 2>&1 \
    || echo "reflect-run: trigger recompile failed (non-fatal)" >&2
fi

# ------------------------------------------------------------------------- pass 6
INDEX="$MEMORY_DIR/MEMORY.md"
INDEX_TIGHTENED=0
LINT_OK=unknown
if [ -f "$INDEX" ] && [ -f "$HERE/memory-index-render.py" ]; then
  idx_before="$(cksum < "$INDEX")"
  python3 "$HERE/memory-index-render.py" >/dev/null 2>&1 \
    || echo "reflect-run: index render failed (non-fatal)" >&2
  [ "$(cksum < "$INDEX")" != "$idx_before" ] && INDEX_TIGHTENED=1
fi
if [ -f "$HERE/memory-index-lint.sh" ]; then
  if bash "$HERE/memory-index-lint.sh" >/dev/null 2>&1; then LINT_OK=yes; else LINT_OK=no; fi
fi

# ------------------------------------------------------------------------- pass 7
# Durable = brainstorms, handoffs, docs/solutions. Plans, reviews and working notes
# are ephemeral by design and age out with their worktree.
CAPTURED=0
capture_file() {
  local src="$1" dest="$2"
  [ -f "$src" ] || return 0
  if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  # `cp` is aliased to `cp -i` in this operator's shell, which turns an overwrite
  # into a silent no-op; `/bin/cp` bypasses the alias.
  /bin/cp -f "$src" "$dest" && CAPTURED=$((CAPTURED + 1))
}

for src_root in ${CAPTURE_FROM+"${CAPTURE_FROM[@]}"}; do
  [ -d "$src_root" ] || { echo "reflect-run: capture path not found: $src_root" >&2; continue; }
  # Two names disambiguate a handoff, because every repo has exactly one
  # docs/handoff.md and they would otherwise overwrite each other in one flat store.
  wt_name="$(basename "$src_root")"
  repo_name="$(basename "$(dirname "$src_root")")"
  [ "$repo_name" = "worktrees" ] && repo_name="$(basename "$(dirname "$(dirname "$src_root")")")"

  while IFS= read -r f; do
    capture_file "$f" "$DOC_STORE/solutions/$(basename "$f")"
  done < <(find "$src_root/docs/solutions" -type f -name '*.md' 2>/dev/null)

  while IFS= read -r f; do
    capture_file "$f" "$DOC_STORE/brainstorms/$(basename "$f")"
  done < <(find "$src_root/docs/brainstorms" -type f -name '*.md' 2>/dev/null)

  while IFS= read -r f; do
    capture_file "$f" "$DOC_STORE/handoffs/${repo_name}-${wt_name}-$(basename "$f")"
  done < <(find "$src_root/docs" -maxdepth 1 -type f -name '*handoff*.md' 2>/dev/null)
done

# ------------------------------------------------------------------------- pass 8
# `embedded` is whatever the reconciler printed. Parsing its summary is the point:
# this script has no way to observe an embed and must not invent a number.
EMBEDDED=skipped
if [ "${REFLECT_RUN_NO_RECONCILE:-0}" != "1" ] && [ -f "$HERE/qmd-reconcile-collections.sh" ]; then
  if rec_out="$(bash "$HERE/qmd-reconcile-collections.sh" 2>&1)"; then
    :
  else
    echo "reflect-run: reconcile exited non-zero (non-fatal)" >&2
  fi
  rec_line="$(printf '%s\n' "$rec_out" | grep 'qmd-reconcile: done' | tail -1)"
  case "$rec_line" in
    *embedded=*) EMBEDDED="$(printf '%s' "$rec_line" | sed -n 's/.*embedded=\([^ )]*\).*/\1/p')" ;;
    # No summary line means the reconciler never got far enough to report — which is
    # not the same as an embed that observed no work, and must not print as `0`.
    *)           EMBEDDED=unknown; echo "reflect-run: reconciler printed no summary" >&2 ;;
  esac
fi

# --------------------------------------------------------------- pass 9 (scan only)
WT_REPORT=""
WT_MERGED_CLEAN=0
for root in ${SCAN_ROOTS+"${SCAN_ROOTS[@]}"}; do
  [ -d "$root" ] || continue
  while IFS= read -r wt; do
    [ -d "$wt" ] || continue
    branch="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
    dirty=clean
    [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ] && dirty=DIRTY
    pr=none
    if command -v gh >/dev/null 2>&1 && [ "$branch" != "HEAD" ] && [ "$branch" != "?" ]; then
      # Run gh from inside the worktree so it resolves the repo itself — `--repo`
      # wants OWNER/REPO, not the remote URL `git remote get-url` hands back.
      pr="$(cd "$wt" && gh pr view "$branch" --json state -q .state 2>/dev/null)" || pr=none
      [ -z "$pr" ] && pr=none
    fi
    WT_REPORT="$WT_REPORT
  $wt branch=$branch state=$dirty pr=$pr"
    [ "$pr" = "MERGED" ] && [ "$dirty" = "clean" ] && WT_MERGED_CLEAN=$((WT_MERGED_CLEAN + 1))
  done < <(git -C "$root" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')
done

# ------------------------------------------------------------------------ pass 10
LOG_LINE="$TS $TRIGGER updated=$UPDATED saved=$SAVED merged=$MERGED retired=$RETIRED compounded=$COMPOUNDED index_tightened=$INDEX_TIGHTENED captured=$CAPTURED embedded=$EMBEDDED worktrees_removed=0 triggers_declared=$TRIG_DECL triggers_pruned=$TRIG_PRUNED"
echo "$LOG_LINE" >> "$MEMORY_DIR/REFLECT.log"

echo "updated=$UPDATED captured=$CAPTURED index_tightened=$INDEX_TIGHTENED lint=$LINT_OK embedded=$EMBEDDED"
[ -n "$MISSING" ] && echo "missing_memories:$MISSING"
if [ -n "$WT_REPORT" ]; then
  echo "worktrees (scan only — nothing removed; DIRTY + MERGED needs your call):$WT_REPORT"
  echo "worktrees_merged_and_clean=$WT_MERGED_CLEAN"
fi
echo "logged: $LOG_LINE"
