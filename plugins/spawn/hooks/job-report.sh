#!/usr/bin/env bash
# job-report.sh — UserPromptSubmit hook. Announce bg-agent jobs that reached a
# terminal state since the last time anyone was told, then never announce them
# again.
#
# WHY THIS EXISTS
# ---------------
# commands/bg-agent.md promised "a notification when it reaches a terminal
# state". bg-agent.sh's own comment said the opposite — "There is no channel to
# push a notification down ... the completion signal IS this record" — so the
# promise was a pull dressed as a push, and the record sat unread.
#
# Measured cost, 2026-08-12: three jobs died on this machine in three separate
# worktrees, all of them on the token bug, and nobody found out. One was an
# adversarial review of a PR that then merged without it. The surface built for
# "nobody is watching" had no way to say what happened while nobody watched.
#
# This is the channel. Not a push either — a prompt is a poll — but it fires on
# the next thing the user does IN THAT WORKTREE, which is when the answer is
# actually useful, and it fires exactly once per job.
#
# WHAT IT MAY AND MAY NOT SAY
# ---------------------------
# ONLY fields the supervisor MEASURED: terminal_state, deliverables_satisfied,
# the alias, the handle, permission-denial count. NEVER `narrative`.
#
# That is not tidiness. `narrative` is prose written by a third-party model and
# the record marks it `untrusted-third-party-model-output`. Injecting it into the
# user's conversation would hand that model a direct line into this session —
# the plugin spends real effort keeping trusted and untrusted apart everywhere
# else, and a notification channel that laundered one into the other would undo
# it. A reader who wants the prose can open the record; the path is printed.
#
# FAIL-OPEN, ALWAYS
# -----------------
# A prompt must never be blocked or delayed by this. Every failure path exits 0
# with no output: no git, no jq, no worktree, an unreadable record, a
# non-writable marker. The cost of a missed announcement is one unread job; the
# cost of a broken prompt is the user's session.

set -uo pipefail

# Announce-once marker. Written INSIDE the job dir so it travels with the job and
# is removed with it. A job whose marker cannot be written is still announced —
# once per prompt, which is noisy but never silent. Silence is the failure this
# hook exists to remove, so it is the one outcome not traded for tidiness.
MARKER=".reported"

emit_nothing() { exit 0; }

command -v git  >/dev/null 2>&1 || emit_nothing
command -v jq   >/dev/null 2>&1 || emit_nothing

# The worktree the user is actually in. `--show-toplevel` resolves a worktree to
# ITS OWN root, not the parent repo, which is what scopes this to the jobs the
# user could plausibly care about right now.
WORKTREE="$(git rev-parse --show-toplevel 2>/dev/null)" || emit_nothing
[ -n "${WORKTREE:-}" ] || emit_nothing

JOB_ROOT="${SPAWN_JOB_ROOT_OVERRIDE:-$WORKTREE/.spawn}"
[ -d "$JOB_ROOT" ] || emit_nothing

LINES=""
COUNT=0
ANNOUNCED=()

# Bounds. This runs synchronously on EVERY prompt, so unbounded work here is a
# denial of service against the user's own session. A field is truncated rather
# than dropped so a long value cannot hide the state next to it.
MAX_JOBS="${SPAWN_REPORT_MAX_JOBS:-20}"
MAX_FIELD=120

# Emitted values must survive being printed into a terminal AND into prompt
# context. sanitize_for_display is the plugin's one answer to the first; the
# second needs the newline and angle-bracket strip, because a value carrying a
# newline or a closing tag could forge structure around itself.
clean() {
    printf '%s' "$1" \
        | tr -d '\000-\010\013\014\016-\037\177' \
        | tr '\n\r' '  ' \
        | tr -d '<>' \
        | cut -c1-"$MAX_FIELD"
}

for dir in "$JOB_ROOT"/job-*; do
    [ "$COUNT" -lt "$MAX_JOBS" ] || break
    [ -d "$dir" ] || continue
    [ -f "$dir/result.json" ] || continue      # still running, or never got that far
    [ -f "$dir/$MARKER" ] && continue          # already announced

    # One jq pass, and it must not fail the hook. A record this cannot parse is
    # skipped, not guessed at.
    line="$(jq -r '
        [ (.job.job_id // .job_id // "?"),
          (.terminal_state // "?"),
          (if (.deliverables_satisfied // false) then "deliverables present" else "NO deliverables" end),
          (.alias // "?"),
          ((.permission_denials // []) | length | tostring)
        ] | @tsv' "$dir/result.json" 2>/dev/null)" || continue
    [ -n "$line" ] || continue

    IFS=$'\t' read -r handle state deliv alias denials <<< "$line"

    # NOT marked here. Nothing is printed inside this loop — the lines accumulate
    # and go out in one write after it — so marking here would let one failure
    # after the loop (a signal, a closed stdout, a full disk) bury EVERY job it
    # had already marked, silently and permanently. Marking follows the write.

    extra=""
    [ "${denials:-0}" != "0" ] && extra=" · ${denials} tool call(s) refused by its ceiling"

    LINES="$LINES
  - $(clean "$handle") on $(clean "$alias"): $(clean "$state"), ${deliv}${extra}
    record: $(clean "$dir")/result.json"
    ANNOUNCED+=("$dir")
    COUNT=$((COUNT + 1))
done

[ "$COUNT" -gt 0 ] || emit_nothing

# Raw stdout is the UserPromptSubmit injection channel (seeded-recall.sh's
# precedent in this marketplace). Tagged so a reader can see where it came from.
printf '<spawn-jobs source="job-report" count="%s">\n' "$COUNT" || exit 0
printf 'Background job(s) in this worktree reached a terminal state since you were last told.\n'
printf 'These are the SUPERVISOR'"'"'S measurements, not the model'"'"'s account of itself.\n'
printf 'A job with NO deliverables is not done however its narrative reads; open the record for its prose.\n'
printf '%s\n' "$LINES"
printf '</spawn-jobs>\n' || exit 0

# Marked only now, after the announcement is on stdout AND the write is known to
# have succeeded. Ignoring the write's status would mark a job whose text went
# nowhere — closed or broken stdout is exactly that case, measured — and a job
# marked-but-unannounced is silent forever, which is the failure this exists to
# remove. `exit 0` because a hook must never fail a prompt, even when it could
# not deliver. A failure before this
# point re-announces on the next prompt — noisy, which is recoverable; the other
# order is silent, which is the exact failure this hook exists to remove.
for dir in "${ANNOUNCED[@]}"; do
    : > "$dir/$MARKER" 2>/dev/null || true
done
exit 0
