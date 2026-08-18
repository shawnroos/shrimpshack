#!/usr/bin/env bash
# One advance of a run, and the intent a driver acts on.
#
# Waiting is re-entry, not blocking: this probes what is in flight, writes what it learned, re-reads, and prints one of four intents. It never dispatches and never schedules — the wake-up call belongs to the model, so the pacing judgement is computed here as data instead.
#
# Sourced by team.sh, never executed. The envelope, the exit code and the
# remedy table live there; a refusal here sets SPAWN_TEAM_ERROR and the surface
# maps it onto the frozen enum.
#
# sanitize.sh is sourced HERE rather than relied on transitively: escapes.bats'
# raw-sink lint walks each lib file's own source edges, so a fragment that
# reaches a terminal print through an unnamed dependency is exactly what it
# exists to catch.

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=./sanitize.sh
. "$SCRIPT_DIR/sanitize.sh"
if ! declare -F say >/dev/null 2>&1; then
    # shellcheck source=./common.sh
    . "$SCRIPT_DIR/common.sh"
fi

advance_parse() {
    team_run_parse advance "$@"
}

# The child's own deadline, and the same default ceilings.sh reads for it. Kept
# in step by hand: a delay paced against a deadline the child is not running on
# would wake the driver on a clock nothing else in the run keeps.
team_child_deadline() {
    local d="${SPAWN_BG_TIMEOUT:-900}"
    case "$d" in ''|*[!0-9]*) d=900 ;; esac
    [ "$d" -gt 0 ] || d=900
    printf '%s' "$d"
}

# An ISO-8601 UTC stamp as epoch seconds. BOTH date dialects, for the reason
# jobs-view.sh's file_mtime states about stat: macOS wants `-j -f`, GNU wants
# `-d`, and a helper that knew one would answer the empty string on the other
# box — here that would silently become a wrong delay rather than no delay.
team_epoch_of() {
    local ts="$1" e
    e="$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" '+%s' 2>/dev/null)" \
        || e="$(date -u -d "$ts" '+%s' 2>/dev/null)" || return 1
    case "$e" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s' "$e"
}

# How long the driver sleeps before re-entering, for a `waiting` intent alone.
#
# A QUARTER of what the round has left, floored at 60 and capped at 3600. Tuned,
# not derived: the quarter is what makes the wake-ups bunch toward the end of a
# round instead of spacing evenly across it, so a round that just opened is
# probed less often than one about to resolve. Raise the divisor and a long
# round costs wake-ups that learn nothing; lower it and the run finds out late.
#
# An unreadable `opened_at` yields the FLOOR, not the cap: a broken record
# should wake the driver sooner, never park it for an hour.
team_wait_delay() {     # <opened_at>
    local opened="${1:-}" dl start now rem d
    dl="$(team_child_deadline)"
    start="$(team_epoch_of "$opened")" || { printf '60'; return 0; }
    now="$(date -u '+%s')"
    rem=$(( dl - (now - start) ))
    [ "$rem" -gt 0 ] || rem=0
    d=$(( rem / 4 ))
    [ "$d" -lt 60 ] && d=60
    [ "$d" -gt 3600 ] && d=3600
    printf '%s' "$d"
}

# ---------------------------------------------------------------------------
# The run lock. mkdir is the atomic primitive jobs.sh uses, for the reason it
# gives: there is no flock(1) on macOS. Deliberately NOT that lock and
# deliberately not sourced from it — jobs.sh's is per worktree and is held by a
# job for its whole life, this one is per RUN and is held for exactly one
# read-probe-write-print. Same argument as handle.sh's pid_still_is_job, which
# duplicates the record layer's probe rather than sharing it.
#
# Atomic rename already stops a torn record. It does NOT stop two re-entries
# both reading the same record and the second overwriting the first's advance,
# which is the whole reason this exists.
# ---------------------------------------------------------------------------
team_lock_holder() {
    local p
    p="$(tr -dc '0-9' < "$ADVANCE_LOCK/pid" 2>/dev/null)"
    [ -n "$p" ] || return 1
    printf '%s' "$p"
}

# `mv` then remove, never a bare `rm -rf`: read-then-rm-then-mkdir lets a second
# breaker delete the directory the first breaker has already re-created and is
# working under, and both then believe they hold it.
team_lock_break() {
    mv "$ADVANCE_LOCK" "$ADVANCE_LOCK.stale.$$" 2>/dev/null \
        && rm -rf "$ADVANCE_LOCK.stale.$$" 2>/dev/null
}

# 0 when this process holds the lock, 1 when a live advance does.
team_lock_take() {
    local holder
    if ! mkdir "$ADVANCE_LOCK" 2>/dev/null; then
        if holder="$(team_lock_holder)" && kill -0 "$holder" 2>/dev/null; then
            return 1
        fi
        # A lock with no holder written yet is either a claimant caught between
        # its mkdir and its write — microseconds — or a process killed in that
        # window. Breaking it on sight would let the second re-entry through the
        # door the first is still walking through, so age decides, exactly as it
        # does for a pid-less job lock.
        if [ -z "$holder" ] && [ -n "$(find "$ADVANCE_LOCK" -maxdepth 0 -mmin -1 2>/dev/null)" ]; then
            return 1
        fi
        say "team: breaking an advance lock whose holder is gone"
        team_lock_break
        mkdir "$ADVANCE_LOCK" 2>/dev/null || return 1
    fi
    printf '%s\n' "$$" > "$ADVANCE_LOCK/pid" 2>/dev/null
    ADVANCE_HELD=true
    return 0
}

team_lock_release() {
    [ "$ADVANCE_HELD" = true ] || return 0
    ADVANCE_HELD=false
    team_lock_break
}

team_probe_row() {      # <name> <state> <outcome-json> <error>
    TEAM_PROBES="$(printf '%s' "$TEAM_PROBES" | jq -c --arg n "$1" --arg s "$2" \
        --argjson o "$3" --arg e "$4" \
        '. + [{name:$n, state:$s, outcome:$o,
               error:(if $e == "" then null else $e end)}]')"
}

# The counts U12 captured, lifted out of the member's own result record and
# into the run's (R20, R30). This is the ONLY thing that feeds the token total
# the ceiling is read against — without it the total sits at zero and the bound
# is advisory while presenting as active.
#
# WRITTEN BEFORE THE OUTCOME, and for the same reason team_launch_member writes
# the handle before the state: each set is its own recompute-and-write, so an
# outcome landing first leaves a record holding a TERMINAL member with no
# counts — which is exactly the shape `usage_unknown` fires on, and a reader
# catching the run between the two writes would see a run stopped as unmeasured
# on a member that was measured.
#
# A non-numeric count is not written at all rather than written null. Absent is
# already the field's initial value, and an absence must never overwrite a
# measurement that is already there.
team_record_usage() {   # <name> <handle.sh result object>
    local name="$1" res="$2" fld path v
    for fld in input output; do
        case "$fld" in
            input) path='.result.usage.input_tokens' ;;
            output) path='.result.usage.output_tokens' ;;
        esac
        v="$(printf '%s' "$res" | jq -r "$path | numbers // empty" 2>/dev/null)"
        [ -n "$v" ] || continue
        spawn::team_member_set "$RUN_DIR" "$name" "tokens_$fld" "$v" \
            || say "team: '$name' reported its $fld tokens and they could not be recorded"
    done
}

# Why a member did not come back with work, written to its own row. The cause is
# ONE object so a reader cannot get the verdict and the reason from two places
# and find them disagreeing; the response's `error` is a projection of
# `.error` here, taken from the same call (KTD2).
#
# Only facts this plugin established: `detail` and `degraded_reasons` are the
# SUPERVISOR's own words about what it measured. The child's `narrative` is
# excluded on purpose — it is the model's account of itself, and the team layer
# never forwards that as a cause (KTD3).
#
# An absent sub-field is null and never "" or 0: a reader that cannot tell an
# unmeasured exit code from a zero one reports a clean exit on a job nobody
# measured (KTD4). jq's `//` keeps a real 0 and a real [] because both are
# truthy there.
#
# WRITTEN BEFORE THE OUTCOME, for the same reason team_record_usage is: each set
# is its own recompute-and-write, so an outcome landing first leaves a reader
# catching the run between the two writes looking at a TERMINAL member with no
# cause — the exact shape this unit exists to remove.
team_record_failure() {  # <name> <error> <handle.sh result object|"">
    local name="$1" error="$2" res="$3" obj
    obj="$(printf '%s' "${res:-null}" | jq -c --arg e "$error" '
        (if type == "object" then (.result // {}) else {} end)
        | {error:$e,
           detail:(.detail // null),
           child_exit_code:(.child_exit_code // null),
           degraded_reasons:(.degraded_reasons // null)}' 2>/dev/null)"
    [ -n "$obj" ] || obj="$(jq -nc --arg e "$error" \
        '{error:$e, detail:null, child_exit_code:null, degraded_reasons:null}')"
    spawn::team_member_set "$RUN_DIR" "$name" failure "$obj" \
        || say "team: '$name' failed with $error and the cause could not be recorded"
}

# One member, probed in ITS OWN worktree, and its outcome recorded if it has
# reached one. The three answers handle.sh gives are kept apart: handle_unknown
# and handle_expired ride the member's row as errors, and a `state` of failed is
# a SUCCESSFUL answer that is recorded like any other terminal state.
team_probe_member() {   # <name> <handle> <worktree>
    local name="$1" handle="$2" wt="$3" out state err res outcome
    # An empty --cwd is not an empty argument to jobs.sh: resolve_worktree falls
    # back to $PWD, so the probe would answer about the DRIVER's own checkout —
    # the shape U4 measured on bg-agent's --cwd, where a member took the
    # driver's one-job lock. A member with no checkout is reported, never
    # probed.
    if [ -z "$wt" ] || [ ! -d "$wt" ]; then
        # The cause goes on the row as well as into the response. The member's
        # own outcome is left alone: a missing checkout is not an outcome the
        # supervisor reported.
        team_record_failure "$name" "worktree_missing" ""
        team_probe_row "$name" "unknown" null "worktree_missing"
        return 0
    fi
    out="$(bash "$JOBS_SH" state --handle "$handle" --cwd "$wt" 2>/dev/null)"
    state="$(printf '%s' "$out" | jq -r '.job.state // empty' 2>/dev/null)"
    if [ -z "$state" ]; then
        err="$(printf '%s' "$out" | jq -r '.error // empty' 2>/dev/null)"
        [ -n "$err" ] || err="handle_unknown"
        # Terminal, because nothing can ever answer for this member again. Left
        # non-terminal it would hold its round open for ever, and R6 concludes a
        # round only when every member in it is terminal.
        team_record_failure "$name" "$err" ""
        spawn::team_member_set "$RUN_DIR" "$name" outcome failed \
            || say "team: '$name' answered $err and its outcome could not be recorded"
        team_probe_row "$name" "failed" '"failed"' "$err"
        return 0
    fi
    if ! is_terminal "$state"; then
        team_probe_row "$name" "$state" null ""
        return 0
    fi
    err=""; outcome="$state"
    res="$(bash "$HANDLE_SH" result --handle "$handle" --cwd "$wt" 2>/dev/null)"
    if [ "$(printf '%s' "$res" | jq -r '.ok // false' 2>/dev/null)" = "true" ]; then
        outcome="$(printf '%s' "$res" | jq -r '.terminal_state // empty' 2>/dev/null)"
        [ -n "$outcome" ] || outcome="$state"
        team_record_usage "$name" "$res"
    else
        # handle_expired and result_missing say the job ran and its record is no
        # longer readable — which is not the same as no answer. The probe's own
        # state stands as the outcome and the refusal rides the row.
        err="$(printf '%s' "$res" | jq -r '.error // empty' 2>/dev/null)"
    fi
    # THE GATE. One condition on the OUTCOME, never a branch per known cause:
    # an enumerated list of the causes we happen to know today is how the next
    # one falls out silently, which is the defect this unit closes.
    if [ "$outcome" != "done" ] || [ -n "$err" ]; then
        err="${err:-$outcome}"
        team_record_failure "$name" "$err" "$res"
    fi
    spawn::team_member_set "$RUN_DIR" "$name" outcome "$outcome" \
        || say "team: '$name' reached $outcome and it could not be recorded"
    team_probe_row "$name" "$state" "$(printf '%s' "$outcome" | jq -R .)" "$err"
}

# The intent, as one JSON object. `delay` is added on `waiting` ALONE — the
# driver schedules it verbatim, and no other intent has anything to schedule.
team_emit_intent() {    # <record> <intent> <reasons-json> <delay|""> <detail>
    local rec="$1" intent="$2" reasons="$3" delay="$4" detail="$5" obj
    obj="$(printf '%s' "$rec" | jq -c --arg id "$RUN_ID" --arg d "$RUN_DIR" \
        --arg i "$intent" --arg dt "$detail" --arg dl "$delay" \
        --argjson rs "$reasons" --argjson ms "$TEAM_PROBES" \
        "$(spawn::envelope_jq plugin)"' + {
          ok:true, error:null, remedy:null, exit_code:0,
          detail:(if $dt == "" then null else $dt end),
          run_id:$id, run_dir:$d, intent:$i, reasons:$rs, mode:.mode,
          complete:.derived.complete,
          ceiling_state:.derived.ceiling_state,
          members_unmeasured:.derived.members_unmeasured,
          round:(if (.rounds | length) == 0 then null else (.rounds | last | .ordinal) end),
          round_state:(if (.rounds | length) == 0 then null else (.rounds | last | .state) end),
          team_file:null, removed:null,
          dispatched:([ .members[] | select(.launch_state == "dispatched") ] | length),
          pending:([ .members[] | select(.launch_state == "pending") ] | length),
          members:$ms}
        + (if $dl == "" then {} else {delay:($dl | tonumber)} end)')" \
        || { SPAWN_TEAM_ERROR="record_malformed"; spawn::team_fail "the intent could not be encoded"; }
    emit "$obj" || { SPAWN_TEAM_ERROR="record_malformed"; spawn::team_fail "the intent encoded to nothing"; }
    exit "$EX_OK"
}

do_advance() {
    need_jq
    advance_parse "$@"
    team_context
    [ -n "$RUN_DIR" ] || RUN_DIR="$DRIVER/.spawn/teams/$RUN_ID"
    ADVANCE_LOCK="$RUN_DIR/advance.lock"

    local rec
    if ! rec="$(spawn::team_record_read "$RUN_DIR")"; then
        spawn::team_record_refusal "$RUN_DIR"
        spawn::team_fail "no readable run record at $RUN_DIR"
    fi
    [ -n "$RUN_ID" ] || RUN_ID="$(printf '%s' "$rec" | jq -r '.run_id')"

    team_lock_take \
        || team_emit_intent "$rec" noop '[]' "" "another advance holds this run's lock"

    local name handle wt
    while IFS=$'\037' read -r name handle wt; do
        [ -n "$name" ] || continue
        team_probe_member "$name" "$handle" "$wt"
    done < <(printf '%s' "$rec" | jq -r '
        .members[] | select(.launch_state == "dispatched" and .outcome == null)
        | [.name, (.handle // ""), (.worktree // "")] | @tsv' | tr '\t' '\037')

    # WRITE, THEN RE-READ, on every advance and not only on one that changed a
    # member. The derived block is recomputed at the write and nowhere else
    # (KTD18), so an advance that decided without writing would be deciding on a
    # derivation some earlier process computed. And the advance that records the
    # last member's outcome is the advance whose write closes the round, so the
    # record read before the probe would answer `waiting` for a round this call
    # itself finished.
    rec="$(spawn::team_record_read "$RUN_DIR")" \
        && spawn::team_record_write "$RUN_DIR" "$rec" \
        && rec="$(spawn::team_record_read "$RUN_DIR")" || {
        team_lock_release
        SPAWN_TEAM_ERROR="record_unwritable"
        spawn::team_fail "the run record could not be advanced at $RUN_DIR"
    }

    # ROUND STATE FIRST, ROSTER STATE SECOND (R32). Every fact below is read
    # from the chokepoint's `derived` block, never recomputed here — that is
    # KTD18, and a second copy of the arithmetic is exactly the drift it exists
    # to prevent.
    local intent reasons='[]' delay="" opened
    if [ "$(printf '%s' "$rec" | jq -r '.derived.active_round != null')" = "true" ]; then
        intent="waiting"
        opened="$(printf '%s' "$rec" | jq -r '.rounds | map(select(.state == "running")) | last | .opened_at // ""')"
        delay="$(team_wait_delay "$opened")"
    elif [ "$(printf '%s' "$rec" | jq -r '.derived.dispatch_allowed')" = "true" ]; then
        intent="continue"
    else
        intent="stop"
        # Read whole, not appended to. `roster_exhausted` is derived at the
        # chokepoint with every other reason (KTD18): assembled here it was a
        # second copy of the arithmetic, and the surface's copy and the
        # record's could disagree about why the same run stopped.
        reasons="$(printf '%s' "$rec" | jq -c '.derived.stop_reasons')"
    fi

    # The record was written by the probe above, before anything is printed: a
    # crash between the two leaves a consistent record whose missing successor
    # the driver can detect, where the reverse order leaves an intent the run
    # record does not back.
    team_lock_release
    team_emit_intent "$rec" "$intent" "$reasons" "$delay" ""
}
