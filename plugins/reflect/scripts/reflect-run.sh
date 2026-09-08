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

# ------------------------------------------------------- crash-safe reporting
# Passes 3-10 are best-effort, and the report plus the REFLECT.log line used to
# be written only after the last of them finished. A run that died mid-flight
# left a zero-byte report and no log line at all, so the counts had to be
# rebuilt by hand. Reproduced: SIGHUP 0.05s in gives report_bytes=0 and no
# REFLECT.log file. SIGKILL is still unrecoverable — nothing can trap it.
#
# The sentinels are `unknown`, never 0. A pass that never ran must not read the
# same as a pass that ran and found nothing — the distinction this script
# already insists on for `embedded` and `retro_captured`. Each pass overwrites
# its own sentinel when it reaches it, so on a partial run the fields still
# reading `unknown` are exactly the passes that did not happen.
INDEX_TIGHTENED=unknown
LINT_OK=unknown
CAPTURED=unknown
EMBEDDED=unknown
WT_REPORT=""
WT_MERGED_CLEAN=unknown
RETRO_CAPTURED=unknown
RETRO_OPEN=0
RETRO_OPEN_THRESHOLD="${REFLECT_RETRO_OPEN_THRESHOLD:-10}"

_REPORT_EMITTED=0

_reflect_report() {
  [ "$_REPORT_EMITTED" = 1 ] && return 0
  _REPORT_EMITTED=1
  _note=""
  [ "$1" != complete ] && _note=" status=partial died=$1"

  LOG_LINE="$TS $TRIGGER updated=$UPDATED saved=$SAVED merged=$MERGED retired=$RETIRED compounded=$COMPOUNDED index_tightened=$INDEX_TIGHTENED captured=$CAPTURED embedded=$EMBEDDED worktrees_removed=0 triggers_declared=$TRIG_DECL triggers_pruned=$TRIG_PRUNED retro_captured=$RETRO_CAPTURED$_note"
  echo "$LOG_LINE" >> "$MEMORY_DIR/REFLECT.log"

  echo "updated=$UPDATED captured=$CAPTURED index_tightened=$INDEX_TIGHTENED lint=$LINT_OK embedded=$EMBEDDED"
  [ "$RETRO_OPEN" -ge "$RETRO_OPEN_THRESHOLD" ] && echo "retro backlog: $RETRO_OPEN open - /reflect:reflect-retro"
  [ -n "$MISSING" ] && echo "missing_memories:$MISSING"
  if [ -n "$WT_REPORT" ]; then
    echo "worktrees (scan only — nothing removed; DIRTY + MERGED needs your call):$WT_REPORT"
    echo "worktrees_merged_and_clean=$WT_MERGED_CLEAN"
  fi
  echo "logged: $LOG_LINE"
  # The real line is down; the write-ahead copy would now be a duplicate that the
  # next run promotes as a phantom death.
  rm -f "$INFLIGHT" "$INFLIGHT.tmp" 2>/dev/null
  return 0
}

# The trap alone is not enough, and this was measured rather than assumed.
# Bash does not run a trap while it is blocked on a FOREGROUND child: signalled
# 1s into a 10s child, the report came out 10.3s later, once the child returned.
# The real failure this fixes went past 120s, which means it was inside a slow
# child (qmd embed) the whole time — so the trap would have been queued behind
# however long that child had left, and a process-group teardown kills it first.
# SIGKILL was never trappable at any point.
#
# So the counts are also written ahead, to a per-PID sidecar updated at each pass
# boundary. Nothing can stop a write that already happened. The next run promotes
# any sidecar whose process is gone into REFLECT.log, which is how an untrappable
# death still leaves a record instead of a hole.
#
# Per-PID because two runs can overlap: a shared filename would let one run
# report the other's live progress as a death.
INFLIGHT="$MEMORY_DIR/.reflect-run.$$.inflight"

_reflect_checkpoint() {
  # Same field order as the real line, so a promoted sidecar parses identically.
  printf '%s\n' "$TS $TRIGGER updated=$UPDATED saved=$SAVED merged=$MERGED retired=$RETIRED compounded=$COMPOUNDED index_tightened=$INDEX_TIGHTENED captured=$CAPTURED embedded=$EMBEDDED worktrees_removed=0 triggers_declared=$TRIG_DECL triggers_pruned=$TRIG_PRUNED retro_captured=$RETRO_CAPTURED" \
    > "$INFLIGHT.tmp" 2>/dev/null \
    && mv -f "$INFLIGHT.tmp" "$INFLIGHT" 2>/dev/null
  # mv -f, never a bare mv: mv is aliased interactive in this operator's shell and
  # a bare one would prompt into a dead terminal and silently leave a stale file.
  return 0
}

# Promote the leavings of any run that died without reaching its trap. `kill -0`
# is the liveness test: a sidecar whose PID still exists belongs to a run that is
# still going, and must be left alone.
_reflect_recover() {
  local f pid
  for f in "$MEMORY_DIR"/.reflect-run.*.inflight; do
    [ -e "$f" ] || continue
    pid="${f##*/.reflect-run.}"; pid="${pid%.inflight}"
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    [ "$pid" = "$$" ] && continue
    kill -0 "$pid" 2>/dev/null && continue
    printf '%s status=partial died=untrapped\n' "$(cat "$f" 2>/dev/null)" \
      >> "$MEMORY_DIR/REFLECT.log" 2>/dev/null
    rm -f "$f" 2>/dev/null
  done
  return 0
}

# Each signal trap re-raises after reporting, so the exit status still says the
# run was killed rather than claiming a clean finish.
trap '_reflect_report SIGHUP;  trap - HUP;  kill -HUP  $$' HUP
trap '_reflect_report SIGTERM; trap - TERM; kill -TERM $$' TERM
trap '_reflect_report SIGINT;  trap - INT;  kill -INT  $$' INT
trap '_rc=$?; if [ "$_rc" = 0 ]; then _reflect_report complete; else _reflect_report "exit_$_rc"; fi' EXIT

_reflect_recover
_reflect_checkpoint

for mem in $APPLIED; do
  f="$MEMORY_DIR/${mem%.md}.md"
  if [ ! -f "$f" ]; then
    MISSING="$MISSING $mem"
    continue
  fi
  before_sum="$(cksum < "$f")"
  MEM_FILE="$f" TODAY="$TODAY" python3 - <<'PY'
import os, re
p = os.environ["MEM_FILE"]; today = os.environ["TODAY"]
s = open(p, encoding="utf-8").read()

# This pattern MUST stay identical to memory_activation.py's _DATE_RE: it is
# whitespace-tolerant and first-match-wins, so the field it reads is often the
# INDENTED one inside the `metadata:` block. Matching only an unindented
# `^last_used:` appends a second, lower line that the reader never looks at — the
# bump then runs, exits 0, and changes no activation at all.
FIELD = re.compile(r'^([ \t]*)last_used[ \t]*:[ \t]*\S.*$', re.M)

m = FIELD.search(s)
if m:
    s2 = s[:m.start()] + f'{m.group(1)}last_used: {today}' + s[m.end():]
else:
    # No field anywhere: insert INSIDE the frontmatter, before its closing fence.
    # A last_used line dropped into the body is invisible to the reader.
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

_reflect_checkpoint
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

_reflect_checkpoint
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

_reflect_checkpoint
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

_reflect_checkpoint
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

# ------------------------------------------------------------- retro backlog counts
# Observed off disk, never passed in. A before/after snapshot here would always
# read zero: the agent writes retro items during pass 2 judgment, which finishes
# before this script is invoked. retro.py owns the window instead.
# `unknown`, never a smoothed 0. Collapsing a broken counts() into "0" makes a
# permanently broken tally indistinguishable from a permanently clean store —
# the same defect this script already refuses for `embedded`.
RETRO_COUNTS="$(python3 "$HERE/retro.py" counts "$MEMORY_DIR" 2>/dev/null)" || RETRO_COUNTS=""
RETRO_CAPTURED=unknown
RETRO_OPEN=0
case "$RETRO_COUNTS" in
  *[0-9]" "*[0-9]*)
    _cap="${RETRO_COUNTS%% *}"; _opn="${RETRO_COUNTS##* }"
    case "$_cap$_opn" in
      *[!0-9]*) ;;
      *) RETRO_CAPTURED="$_cap"; RETRO_OPEN="$_opn" ;;
    esac
    ;;
esac

# R13. Measured: the vent bar yields about two items a week, so ten open items is
# roughly five weeks of un-worked backlog - the point at which it earns a line.
# Below it the summary stays silent; a backlog that nags at three items gets muted.

_reflect_checkpoint
# ------------------------------------------------------------------------ pass 10
# The EXIT trap emits it. Reaching here just means the status is `complete`.
_reflect_report complete
