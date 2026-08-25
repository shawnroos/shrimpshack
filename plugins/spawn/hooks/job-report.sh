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
#
# THIS COMPOSES ON THE CHOKEPOINT RATHER THAN REIMPLEMENTING IT. A `tr` byte
# range strips C0 controls and stops there: a Unicode bidi override (U+202E)
# is multi-byte and survives it, and this line is printed straight into the
# user's prompt context, where reversed text is exactly the trick that matters.
# sanitize.sh strips those; this file used to carry its own weaker copy while
# the comment above already claimed sanitize_for_display was the answer.
#
# Sourced unconditionally and cheaply — 101 lines, no dependencies of its own —
# because the alternative was reaching it only through the lazy team-lib load,
# which means a worktree with plain jobs and no team runs never had it at all.
# Fail open, like everything else here: if it cannot be sourced the fallback
# below is the old behaviour rather than a broken prompt.
SPAWN_LIB_DIR="${SPAWN_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" 2>/dev/null && pwd)}"
if [ -n "$SPAWN_LIB_DIR" ] && [ -f "$SPAWN_LIB_DIR/sanitize.sh" ]; then
    # shellcheck source=../lib/sanitize.sh
    . "$SPAWN_LIB_DIR/sanitize.sh" 2>/dev/null || true
fi

clean() {
    local v="$1"
    if declare -F spawn::sanitize_for_display >/dev/null 2>&1; then
        v="$(spawn::sanitize_for_display "$v")"
    fi
    printf '%s' "$v" \
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
          ((.permission_denials // []) | length | tostring),
          ((.grants // []) | join(","))
        ] | @tsv' "$dir/result.json" 2>/dev/null)" || continue
    [ -n "$line" ] || continue

    IFS=$'\t' read -r handle state deliv alias denials grants <<< "$line"

    # NOT marked here. Nothing is printed inside this loop — the lines accumulate
    # and go out in one write after it — so marking here would let one failure
    # after the loop (a signal, a closed stdout, a full disk) bury EVERY job it
    # had already marked, silently and permanently. Marking follows the write.

    extra=""
    [ "${denials:-0}" != "0" ] && extra=" · ${denials} tool call(s) refused by its ceiling"
    # A granted job is named as such. Bash especially: a reader scanning these
    # lines should not have to open the record to learn which jobs held a shell.
    [ -n "${grants:-}" ] && extra="$extra · GRANTED $(clean "$grants")"

    LINES="$LINES
  - $(clean "$handle") on $(clean "$alias"): $(clean "$state"), ${deliv}${extra}
    record: $(clean "$dir")/result.json"
    ANNOUNCED+=("$dir")
    COUNT=$((COUNT + 1))
done

# ---------------------------------------------------------------------------
# TEAM RUNS (U11, U8). A team's members run in SIBLING worktrees, so no member's
# own result.json ever reaches the driver's hook — the loop above cannot see
# them and never will. The run record is what announces, and it announces two
# different ways:
#
#   in-flight (U11)  NEVER marked. A run still going is still news next prompt,
#                    and a marked one would speak once and then go quiet for
#                    exactly the hour the caller wanted it for.
#   terminal  (U8)   marked, once per RUN — not once per member, which is what a
#                    per-member channel would have given.
#
# TERMINAL IS NOT `complete` ALONE. A run stopped by a bound with members that
# were never dispatched leaves `complete` false forever; keyed on it, such a run
# would print an in-flight line every prompt until the directory was deleted and
# would never report the stop reason the announcement exists to carry.
#
# `members_running` is a RECORD field, so a member whose process died but whose
# outcome has not been written keeps the run in flight until an `advance` writes
# it. That is deliberate: this hook never writes the record, and a second
# opinion about who is finished is how two surfaces drift apart.
TEAM_ROOT="$JOB_ROOT/teams"
TEAM_LINES=""
TEAM_COUNT=0
TEAM_MARK=()

# Bounds, for the reason MAX_JOBS exists one bound up, but tighter: rendering a
# run PROBES each member in a subprocess, and the hook's whole budget is the
# five-second timeout in hooks.json. Over the bound it prints nothing rather
# than running long — silence is the designed failure mode here.
MAX_RUNS="${SPAWN_REPORT_MAX_RUNS:-4}"
MAX_MEMBERS="${SPAWN_REPORT_MAX_MEMBERS:-12}"

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" 2>/dev/null && pwd)" || LIB_DIR=""
TEAM_LIB=""

# Sourced LAZILY, and only once a record has actually been found: a prompt in a
# worktree that has never run a team must not pay for the whole record layer.
team_lib_load() {
    [ -z "$TEAM_LIB" ] || return 0
    [ -n "$LIB_DIR" ] || return 1
    [ -f "$LIB_DIR/team-record.sh" ] && [ -f "$LIB_DIR/team-view.sh" ] || return 1
    SCRIPT_DIR="$LIB_DIR"
    JOBS_SH="$LIB_DIR/jobs.sh"
    # BEFORE THE SOURCE, and that is the whole point: team-view.sh reads this
    # into TEAM_VIEW_LIMIT at source time, so setting it afterwards is inert and
    # the renderer keeps its own default. Pinned to this hook's bound so the cap
    # cannot drop members underneath the counts — a truncated roster would read
    # as a smaller team rather than as a truncated one.
    SPAWN_TEAM_VIEW_LIMIT="$MAX_MEMBERS"
    export SPAWN_TEAM_VIEW_LIMIT
    # shellcheck source=../lib/team-record.sh
    . "$LIB_DIR/team-record.sh" 2>/dev/null || return 1
    # shellcheck source=../lib/team-view.sh
    . "$LIB_DIR/team-view.sh" 2>/dev/null || return 1
    TEAM_LIB=1
    return 0
}

if [ -d "$TEAM_ROOT" ]; then
    for rd in "$TEAM_ROOT"/*; do
        [ "$TEAM_COUNT" -lt "$MAX_RUNS" ] || break
        [ -d "$rd" ] || continue
        [ -f "$rd/team.json" ] || continue
        team_lib_load || break
        # The record layer's own validation, not a second opinion: a truncated
        # or wrong-schema file is skipped, exactly as every other reader skips it.
        rec="$(spawn::team_record_read "$rd" 2>/dev/null)" || continue
        [ -n "$rec" ] || continue

        if printf '%s' "$rec" | jq -e '
                (.derived.complete == true)
                or (((.derived.stop_reasons // []) | length) > 0
                    and (.derived.members_running == 0)
                    and (.derived.active_round == null))' >/dev/null 2>&1; then
            [ -f "$rd/$MARKER" ] && continue
            tsv="$(printf '%s' "$rec" | jq -r '
                [ (.run_id // "?"),
                  (.derived.verdict // "?"),
                  ([ .members[]
                     | (.outcome // (if .launch_state == "launch_failed"
                                     then "launch_failed" else "unresolved" end)) ]
                   | group_by(.) | map("\(.[0]) \(length)") | join(", ")),
                  "\(.derived.members_terminal)/\(.derived.members_total)",
                  ((.derived.stop_reasons // []) | join(", "))
                ] | @tsv' 2>/dev/null)" || continue
            [ -n "$tsv" ] || continue
            {
                read -r run_id; read -r verdict; read -r counts
                read -r term;   read -r stops
            } <<EOF
$(printf '%s' "$tsv" | tr '\t' '\n')
EOF
            [ -n "${stops:-}" ] || stops="none"
            TEAM_LINES="$TEAM_LINES
  DONE $(clean "$run_id"): verdict $(clean "$verdict") · $(clean "$counts") · $(clean "$term") terminal · stopped: $(clean "$stops") · record: $(clean "$rd")/team.json"
            TEAM_MARK[${#TEAM_MARK[@]}]="$rd"
            TEAM_COUNT=$((TEAM_COUNT + 1))
            continue
        fi

        # THE BOUND IS CHECKED BEFORE THE FIRST PROBE, not after: the cost this
        # is protecting against is the probing itself, and a bound applied to
        # the rendered result would already have paid it.
        n="$(printf '%s' "$rec" | jq -r '.members | length' 2>/dev/null)"
        case "$n" in ''|*[!0-9]*) continue ;; esac
        [ "$n" -le "$MAX_MEMBERS" ] || continue

        TEAM_VIEW_JSON=""
        team_view "$rec" 2>/dev/null
        [ -n "$TEAM_VIEW_JSON" ] || continue

        tsv="$(printf '%s' "$rec" | jq -r --argjson v "$TEAM_VIEW_JSON" '
            [ (.run_id // "?"),
              "\(.derived.bounds.rounds_used)/\(.bounds.max_rounds)",
              ([ $v.members[].state ] | group_by(.) | map("\(.[0]) \(length)") | join(", ")),
              "\([ $v.members[].progress.changed ] | add // 0)/\([ $v.members[].progress.paths ] | add // 0)",
              (($v.members_unmeasured // 0) | tostring),
              ((try ((now - (.created_at | fromdateiso8601)) | floor) catch 0) | tostring)
            ] | @tsv' 2>/dev/null)" || continue
        [ -n "$tsv" ] || continue
        # ONE FIELD PER LINE, not @tsv into `read`. Tab is an IFS *whitespace*
        # character, so a run of tabs collapses to one delimiter and every field
        # after an empty one shifts left. `states` is "" for a zero-member
        # record, which would render the elapsed seconds in the unmeasured slot.
        {
            read -r run_id; read -r rounds; read -r states
            read -r prog;   read -r unmeas; read -r elapsed
        } <<EOF
$(printf '%s' "$tsv" | tr '\t' '\n')
EOF

        # NOT marked, and there is no marker write anywhere on this branch. See
        # the block comment above: this line is the whole point of the unit.
        TEAM_LINES="$TEAM_LINES
  LIVE $(clean "$run_id"): round $(clean "$rounds") · $(clean "$states") · $(clean "$prog") paths changed · $(clean "$unmeas") unmeasured · $(clean "$elapsed")s elapsed · record: $(clean "$rd")/team.json"
        TEAM_COUNT=$((TEAM_COUNT + 1))
    done
fi

[ "$COUNT" -gt 0 ] || [ "$TEAM_COUNT" -gt 0 ] || emit_nothing

# Raw stdout is the UserPromptSubmit injection channel (seeded-recall.sh's
# precedent in this marketplace). Tagged so a reader can see where it came from.
if [ "$COUNT" -gt 0 ]; then
printf '<spawn-jobs source="job-report" count="%s">\n' "$COUNT" || exit 0
printf 'Background job(s) in this worktree reached a terminal state since you were last told.\n'
printf 'These are the SUPERVISOR'"'"'S measurements, not the model'"'"'s account of itself.\n'
printf 'A job with NO deliverables is not done however its narrative reads; open the record for its prose.\n'
printf '%s\n' "$LINES"
printf '</spawn-jobs>\n' || exit 0
fi

# Its own block, and its own tag. A team run is not a job in this worktree — its
# members are elsewhere — so folding it into the block above would say the
# opposite of what is true about where the work is.
if [ "$TEAM_COUNT" -gt 0 ]; then
printf '<spawn-team source="job-report" runs="%s">\n' "$TEAM_COUNT" || exit 0
printf 'Team run(s) recorded in this worktree. LIVE repeats while the run is going; DONE is said once.\n'
printf 'Measured fields only: resolved member states, progress against the pre-run baseline, the record'"'"'s own counts.\n'
printf '%s\n' "$TEAM_LINES"
printf '</spawn-team>\n' || exit 0
fi

# Marked only now, after the announcement is on stdout AND the write is known to
# have succeeded. Ignoring the write's status would mark a job whose text went
# nowhere — closed or broken stdout is exactly that case, measured — and a job
# marked-but-unannounced is silent forever, which is the failure this exists to
# remove. `exit 0` because a hook must never fail a prompt, even when it could
# not deliver. A failure before this
# point re-announces on the next prompt — noisy, which is recoverable; the other
# order is silent, which is the exact failure this hook exists to remove.
# The length guard is not tidiness: expanding an EMPTY array under `set -u` is a
# fatal unbound-variable error on bash 3.2, and this loop became reachable with
# no jobs the moment a team line alone could carry the emit.
if [ "${#ANNOUNCED[@]}" -gt 0 ]; then
    for dir in "${ANNOUNCED[@]}"; do
        : > "$dir/$MARKER" 2>/dev/null || true
    done
fi
if [ "${#TEAM_MARK[@]}" -gt 0 ]; then
    for dir in "${TEAM_MARK[@]}"; do
        : > "$dir/$MARKER" 2>/dev/null || true
    done
fi
exit 0
