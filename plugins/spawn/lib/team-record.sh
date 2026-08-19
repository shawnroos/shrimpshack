#!/usr/bin/env bash
# team-record.sh — the one file a team run lives in, and the one function that
# writes it (KTD18). Every derived fact is recomputed inside that function
# immediately before the write, so no reader can observe a stale one and no
# reader recomputes one.
#
# Sourced, never executed: the envelope and the exit code belong to the surface
# that consumes this. A refusal here sets SPAWN_TEAM_ERROR to its error value
# and returns non-zero; the caller maps that onto the frozen enum. Calling
# common.sh's `die` from here would emit an envelope on behalf of a surface that
# has not declared its own null fields, and its default emit_error reads globals
# a bare consumer never set.

set -uo pipefail

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=./sanitize.sh
. "$SCRIPT_DIR/sanitize.sh"
if ! declare -F say >/dev/null 2>&1; then
    # shellcheck source=./common.sh
    . "$SCRIPT_DIR/common.sh"
fi

SPAWN_TEAM_SCHEMA="spawn.team/v1"
SPAWN_TEAM_ERROR=""

# KTD18's recomputation, as one jq program run inside the chokepoint and
# nowhere else. `closed_at` is the one field that remembers: a timestamp is an
# observation, not a derivation, so it is stamped on the write that first sees
# the round finished and kept from then on. Everything else here is a pure
# function of the member rows, which is why no reader may hold a copy.
#
# A null token count is NOT summed as zero — it raises `unknown`, and the
# unknown flag is what a stop decision reads. A silently partial sum reads as a
# small bill and would let a run past its ceiling with nothing to show for it.
# But a member whose launch failed is zero BY CONSTRUCTION, not an absent
# measurement: counting it unknown halted a whole run on one failed worktree.
#
# `stop_reasons` is a LIST evaluated as independent conditions, never a chain
# (R21). Two of them are true at the same write whenever a run's last round is
# also the one that crosses the ceiling, and a chain reporting the first
# condition it checks reads as correct on every run where exactly one fires.
#
# `roster_exhausted` rides that same list but is deliberately kept OUT of
# `continue` and `dispatch_allowed`: it is not a bound, it is the run finishing
# its work, and `complete` is the field that tells those two apart. A reader
# branching on `continue` alone would treat a run out of rounds and a run that
# finished as the same event.
#
# `complete` asks whether EVERY member is terminal, not whether any is still
# pending. A member in flight is not pending either, so the pending form
# answers true in the middle of a live round. Nor is it "no bound fired": a
# roster that empties on its last permitted round has finished its work, and
# the reasons list already says which bounds were touched on the way.
SPAWN_TEAM_DERIVE_JQ='
def is_done: (.outcome != null) or (.launch_state == "launch_failed");
def usage_missing: (.launch_state != "launch_failed" and is_done
                    and ((.tokens.input == null) or (.tokens.output == null)));
def spent: ((.tokens.input // 0) + (.tokens.output // 0));
def tally($ms): if ($ms | length) == 0 then "pending"
  elif ($ms | map(is_done) | all | not) then "pending"
  elif ($ms | map(.outcome == "done") | all) then "pass"
  elif ($ms | map(.outcome == "done") | any) then "mixed"
  else "fail" end;
. as $rec
| ($rec.members) as $ms
# The participants of a round are the union of the live rows holding that ordinal
# and the RETIRED ATTEMPTS holding it (KTD7). A rotation clears the live row, so
# a chokepoint reading live rows alone deletes a member from its own closed
# round: a mixed round re-reads as pass, and a round whose every member was
# retried flips back to running with closed_at nulled, which parks advance at
# waiting for ever.
#
# An attempt entry carries no launch_state of its own, and is_done is not
# rewritten to know about attempts. So the synthesis states the fact an attempt
# already IS: it is retired, therefore terminal. An entry with no outcome
# produced nothing and is zero BY CONSTRUCTION, which is exactly what
# launch_failed means to the arithmetic below; an entry with an outcome is
# measured on the ordinary terms.
| ($ms | map(. as $m | (.attempts // [])[]
             | . + {name: $m.name,
                    launch_state: (if .outcome == null
                                   then "launch_failed" else "retired" end)})) as $hist
| ($ms + $hist) as $all
| .rounds |= [ .[] as $r
    | ($all | map(select(.round == $r.ordinal))) as $rm
    | (if ($rm | length) > 0 and ($rm | map(is_done) | all)
       then "finished" else "running" end) as $st
    | $r
      + {state: $st,
         closed_at: (if $st == "finished" then ($r.closed_at // $now) else null end),
         verdict: (if $st == "finished" then tally($rm) else null end),
         members: ($rm | map(.name)),
         tokens: {input: ($rm | map(.tokens.input // 0) | add // 0),
                  output: ($rm | map(.tokens.output // 0) | add // 0),
                  total: ($rm | map(spent) | add // 0),
                  unknown: ($rm | map(usage_missing) | any)}} ]
# TOKEN ACCOUNTING READS THE UNION; ROSTER ACCOUNTING READS THE LIVE ROWS
# (KTD8). A retry that returned the retired spend to zero would let a retry loop
# spend past the ceiling for ever.
| ($all | map(spent) | add // 0) as $used
| ($all | map(usage_missing) | any) as $unk
| (.rounds | length) as $ru
| (.bounds.max_rounds) as $mr
| (.bounds.token_ceiling) as $tc
| ($ms | map(select(.launch_state == "dispatched" and .outcome == null)) | length) as $live
| ($all | map(select(usage_missing)) | length) as $unm
# $meas counts members that actually REPORTED a count. A launch_failed member is
# correctly not `usage_missing` — it never ran, so its zero is a fact — but it
# reported nothing either, so counting it here made `unenforceable` unreachable
# the moment one worktree failed: a team whose only real usage was unmeasured
# would call its ceiling `within` and print the full budget as remaining.
| ($all | map(select(is_done and (usage_missing | not)
                     and (.launch_state != "launch_failed"))) | length) as $meas
| ([ (if $ru >= $mr then "round_max_reached" else empty end),
     (if ($tc > 0 and $used >= $tc) then "token_ceiling_reached" else empty end),
     (if ($unk and $tc > 0) then "usage_unknown" else empty end) ]) as $hit
# retry_pending is a ROSTER state, not a finished one: a member waiting for its
# next attempt is undispatched work, so the roster is not exhausted and dispatch
# is still allowed for it.
| (($ms | length) > 0
   and (($ms | map(.launch_state == "pending" or .launch_state == "retry_pending")
             | any) | not)) as $done_roster
# A record with NO members stops, and must say why. Without this it reports
# `stop` with an empty reasons list — R21 asks that every reason a run stopped
# be named, and "none of them" reads as a surface that forgot rather than a
# roster that was never populated. Only reachable in the window between the
# record being created and its first member row, which a crash can leave behind.
| ($hit + (if $done_roster then ["roster_exhausted"] else [] end)
        + (if ($ms | length) == 0 then ["roster_empty"] else [] end)) as $stops
| (.rounds | map(select(.state == "running")) | last) as $act
| .derived = {
    verdict: tally($ms),
    continue: (($hit | length) == 0),
    active_round: (if $act == null then null else $act.ordinal end),
    active_round_state: (if $act == null then null else $act.state end),
    dispatch_allowed: (($hit | length) == 0 and $act == null
                       and ($ms | map(.launch_state == "pending"
                                      or .launch_state == "retry_pending") | any)),
    stop_reasons: $stops,
    complete: (($ms | length) > 0 and ($ms | map(is_done) | all)),
    ceiling_state: (if $tc <= 0 then "none"
                    elif ($unm > 0 and $meas == 0) then "unenforceable"
                    elif $used >= $tc then "reached"
                    else "within" end),
    usage_unknown: $unk,
    members_unmeasured: $unm,
    tokens_used: $used,
    members_total: ($ms | length),
    members_terminal: ($ms | map(select(is_done)) | length),
    members_running: $live,
    bounds: {rounds_used: $ru,
             rounds_remaining: (if $mr - $ru > 0 then $mr - $ru else 0 end),
             tokens_used: $used,
             tokens_remaining: (if $tc > 0
                                then (if $tc - $used > 0 then $tc - $used else 0 end)
                                else null end),
             concurrency_used: $live,
             concurrency_limit: .bounds.max_concurrent}}
'

spawn::team_record_path() { printf '%s/team.json' "$1"; }

# A truncated or malformed file prints NOTHING and returns non-zero, rather than
# a partial record — the reading jobs.sh gives a half-written status file.
spawn::team_record_read() {
    local f
    f="$(spawn::team_record_path "$1")"
    [ -f "$f" ] || { SPAWN_TEAM_ERROR="record_missing"; return 1; }
    jq -ec --arg s "$SPAWN_TEAM_SCHEMA" \
        'select(type == "object" and .schema == $s and (.members | type) == "array")' \
        "$f" 2>/dev/null && return 0
    SPAWN_TEAM_ERROR="record_malformed"
    return 1
}

# THE CHOKEPOINT (KTD18). $2 carries the RAW facts only; the derived ones are
# computed here, immediately before the write, and nowhere else. Temp-then-mv so
# a reader catching the write mid-flight sees the OLD record whole.
spawn::team_record_write() {
    local dir="$1" raw="$2" f tmp now
    f="$(spawn::team_record_path "$dir")"
    now="$(now_utc)"
    tmp="$dir/.team.$$"
    printf '%s' "$raw" | jq -c --arg now "$now" "$SPAWN_TEAM_DERIVE_JQ" > "$tmp" 2>/dev/null || {
        rm -f "$tmp" 2>/dev/null
        SPAWN_TEAM_ERROR="record_unwritable"
        say "team record: refused to write a record the encoder could not build"
        return 1
    }
    mv "$tmp" "$f" 2>/dev/null || {
        rm -f "$tmp" 2>/dev/null
        SPAWN_TEAM_ERROR="record_unwritable"
        say "team record: could not place the record at $f"
        return 1
    }
    return 0
}

spawn::team_record_new() {
    local dir="$1" run_id="$2" mode="$3" max_conc="$4" max_rounds="$5" ceiling="$6" raw
    mkdir -p "$dir" 2>/dev/null || {
        SPAWN_TEAM_ERROR="record_unwritable"
        say "team record: cannot create the run directory"
        return 1
    }
    raw="$(jq -nc --arg s "$SPAWN_TEAM_SCHEMA" --arg id "$run_id" --arg m "$mode" \
        --arg at "$(now_utc)" --argjson mc "$max_conc" --argjson mr "$max_rounds" \
        --argjson tc "$ceiling" \
        '{schema:$s, run_id:$id, mode:$m, created_at:$at,
          bounds:{max_concurrent:$mc, max_rounds:$mr, token_ceiling:$tc},
          rounds:[], members:[]}')" || {
        SPAWN_TEAM_ERROR="usage"
        say "team record: the run's bounds are not numbers"
        return 1
    }
    spawn::team_record_write "$dir" "$raw"
}

spawn::team_member_add() {
    local dir="$1" name="$2" alias="$3" worktree="$4" contract="$5" skills="${6:-}" cur raw
    cur="$(spawn::team_record_read "$dir")" || return 1
    if printf '%s' "$cur" | jq -e --arg n "$name" 'any(.members[]; .name == $n)' >/dev/null 2>&1; then
        SPAWN_TEAM_ERROR="member_duplicate"
        say "team record: a member named '$name' is already in this run"
        return 1
    fi
    raw="$(printf '%s' "$cur" | jq -c --arg n "$name" --arg a "$alias" --arg w "$worktree" \
        --arg c "$contract" --arg sk "$skills" \
        '.members += [{name:$n, alias:$a, worktree:$w, contract:$c,
                       skills:($sk | split(" ") | map(select(length > 0))),
                       launch_state:"pending", handle:null, round:null,
                       started_at:null, outcome:null, failure:null, attempts:[],
                       tokens:{input:null, output:null}}]')" || {
        SPAWN_TEAM_ERROR="record_unwritable"
        say "team record: could not encode the member row for '$name'"
        return 1
    }
    spawn::team_record_write "$dir" "$raw"
}

spawn::team_member_set() {
    local dir="$1" name="$2" fld="$3" value="$4" cur raw
    case "$fld" in
        launch_state|handle|round|started_at|outcome|tokens_input|tokens_output) ;;
        failure|attempts) ;;
        *)
            SPAWN_TEAM_ERROR="field_unknown"
            say "team record: '$fld' is not a writable member field"
            return 1 ;;
    esac
    cur="$(spawn::team_record_read "$dir")" || return 1
    if ! printf '%s' "$cur" | jq -e --arg n "$name" 'any(.members[]; .name == $n)' >/dev/null 2>&1; then
        SPAWN_TEAM_ERROR="member_unknown"
        say "team record: this run has no member named '$name'"
        return 1
    fi
    raw="$(printf '%s' "$cur" | jq -c --arg n "$name" --arg f "$fld" --arg v "$value" '
        def val: if $v == "null" then null
                 elif ($f | test("^(round|tokens_)")) then ($v | tonumber)
                 else $v end;
        .members |= map(
          if .name != $n then .
          elif $f == "tokens_input" then .tokens.input = val
          elif $f == "tokens_output" then .tokens.output = val
          elif ($f == "failure" or $f == "attempts") then .[$f] = ($v | fromjson)
          else .[$f] = val end)')" || {
        SPAWN_TEAM_ERROR="usage"
        say "team record: '$value' is not a valid value for '$fld'"
        return 1
    }
    spawn::team_record_write "$dir" "$raw"
}

spawn::team_round_open() {
    local dir="$1" cur raw
    cur="$(spawn::team_record_read "$dir")" || return 1
    raw="$(printf '%s' "$cur" | jq -c --arg at "$(now_utc)" \
        '.rounds += [{ordinal:((.rounds | length) + 1), opened_at:$at, closed_at:null}]')" || {
        SPAWN_TEAM_ERROR="record_unwritable"
        say "team record: could not open a round"
        return 1
    }
    spawn::team_record_write "$dir" "$raw"
}

# Rotate one member's failed attempt out of its live row (KTD6, KTD7, R8, R9).
#
# ONE read-modify-write, never a sequence of spawn::team_member_set calls. Each
# of those is its own write, and a rotation spread over six of them is visible
# half-applied: between the outcome being nulled and launch_state flipping, the
# member matches an advance probe select — dispatched with a null outcome —
# while holding a null handle, so the advance answers handle_unknown and writes
# an outcome into the middle of the rotation. The member then sits at
# retry_pending with a non-null outcome, which reads as done and never closes
# its round. The same window against the ceiling counts the retired spend twice.
#
# alias, contract, skills and worktree SURVIVE: a later round places nothing and
# relaunches from the checkout the record already names.
spawn::team_member_rotate() {
    local dir="$1" name="$2" cur raw
    cur="$(spawn::team_record_read "$dir")" || return 1
    if ! printf '%s' "$cur" | jq -e --arg n "$name" 'any(.members[]; .name == $n)' >/dev/null 2>&1; then
        SPAWN_TEAM_ERROR="member_unknown"
        say "team record: this run has no member named '$name'"
        return 1
    fi
    raw="$(printf '%s' "$cur" | jq -c --arg n "$name" '
        .members |= map(
          if .name != $n then .
          else . + {attempts: ((.attempts // [])
                       + [{round: .round, handle: .handle, outcome: .outcome,
                           failure: .failure, tokens: .tokens}]),
                    launch_state: "retry_pending",
                    handle: null, outcome: null, started_at: null,
                    round: null, failure: null,
                    tokens: {input: null, output: null}}
          end)')" || {
        SPAWN_TEAM_ERROR="record_unwritable"
        say "team record: could not rotate the member row for '$name'"
        return 1
    }
    spawn::team_record_write "$dir" "$raw"
}
