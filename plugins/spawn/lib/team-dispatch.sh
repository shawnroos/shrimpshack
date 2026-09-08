#!/usr/bin/env bash
# Stating a roster and putting a round in flight.
#
# The team file is read ONCE, at the first dispatch, and copied into the record; a later round reads its roster back out of that record, never the caller's file again. Which round it is comes from whether the record exists, not from which flags were passed.
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
# spawn::ceiling_grantable, so a member's `allow` is refused HERE, before a
# launcher is ever invoked — bg-agent's own grant check runs in its detached
# supervisor, after it has already answered this caller with a handle.
if ! declare -F spawn::ceiling_grantable >/dev/null 2>&1; then
    # shellcheck source=./ceilings.sh
    . "$SCRIPT_DIR/ceilings.sh"
fi

# The per-member flags attach to the most recent --member, so a member is
# declared and described in one place on the command line.
roster_parse() {
    local mode="attached" mc=2 mr=3 tc=0 tc_stated="" last=-1
    MODE=""; MAX_CONC=""; MAX_ROUNDS=""; TOKEN_CEILING=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --run-id) RUN_ID="${2:-}"; shift 2 || shift ;;
            --run-dir) RUN_DIR="${2:-}"; shift 2 || shift ;;
            --mode) mode="${2:-}"; shift 2 || shift ;;
            --max-concurrent) mc="${2:-}"; shift 2 || shift ;;
            --max-rounds) mr="${2:-}"; shift 2 || shift ;;
            --token-ceiling) tc="${2:-}"; tc_stated="--token-ceiling"; shift 2 || shift ;;
            --member)
                M_NAMES+=("${2:-}"); M_ALIASES+=(""); M_CONTRACTS+=("")
                M_SKILLS+=(""); M_WORKTREES+=(""); M_ALLOWS+=("")
                last=$(( last + 1 )); shift 2 || shift ;;
            --alias|--contract|--skill|--worktree|--allow)
                [ "$last" -ge 0 ] || { SPAWN_TEAM_ERROR="usage"
                    spawn::team_fail "$1 was given before any --member, so it belongs to nobody"; }
                case "$1" in
                    --alias) M_ALIASES[$last]="${2:-}" ;;
                    --contract) M_CONTRACTS[$last]="${2:-}" ;;
                    --worktree) M_WORKTREES[$last]="${2:-}" ;;
                    --skill) M_SKILLS[$last]="${M_SKILLS[$last]} ${2:-}" ;;
                    --allow) M_ALLOWS[$last]="${M_ALLOWS[$last]} ${2:-}" ;;
                esac
                shift 2 || shift ;;
            *)
                usage
                SPAWN_TEAM_ERROR="usage"
                spawn::team_fail "unexpected argument: $1" ;;
        esac
    done
    MODE="$mode"; MAX_CONC="$mc"; MAX_ROUNDS="$mr"; TOKEN_CEILING="$tc"
    team_ceiling_ok "$tc_stated" "$tc"
    [ -n "$RUN_ID" ] || { SPAWN_TEAM_ERROR="usage"; spawn::team_fail "--run-id is required"; }
    spawn::team_name_ok "$RUN_ID" || { SPAWN_TEAM_ERROR="usage"
        spawn::team_fail "--run-id is a directory component and failed the grammar: $RUN_ID"; }
    [ "$last" -ge 0 ] || { SPAWN_TEAM_ERROR="usage"; spawn::team_fail "a team needs at least one --member"; }
}

# The cause on the ROW, in the same four-key shape team_record_failure writes on
# the probe side: an operator reads one object per member, whichever layer wrote
# it. `detail` is the launcher's own sentence, taken from where bg-agent puts it
# — top level of its refusal, not under `.result` as a finished job's is. A
# launch that never started has no child and nothing degraded, so those two are
# null on this path by fact rather than by omission.
team_record_launch_failure() {  # <name> <error> <bg-agent refusal json|"">
    local name="$1" error="$2" out="$3" obj
    obj="$(printf '%s' "${out:-null}" | jq -c --arg e "$error" '
        (if type == "object" then . else {} end)
        | {error:$e, detail:(.detail // null),
           child_exit_code:null, degraded_reasons:null}' 2>/dev/null)"
    [ -n "$obj" ] || obj="$(jq -nc --arg e "$error" \
        '{error:$e, detail:null, child_exit_code:null, degraded_reasons:null}')"
    spawn::team_member_set "$RUN_DIR" "$name" failure "$obj" \
        || say "team: '$name' was not launched ($error) and the cause could not be recorded"
}

# Creates each member's checkout and writes its provisional row, in roster
# order. Members whose checkout could not be made are left in TEAM_UNPLACED, and
# their M_WORKTREES entry is emptied — a launch reads that array, and an empty
# entry is the one thing that keeps a member with no checkout out of a round.
team_place_members() {  # <run-dir>
    local dir="$1" i=0 name worktree
    TEAM_UNPLACED=""
    while [ "$i" -lt "${#M_NAMES[@]}" ]; do
        name="${M_NAMES[$i]}"
        worktree="${M_WORKTREES[$i]}"
        if [ -z "$worktree" ]; then
            worktree="$(spawn::team_worktree_create "$DRIVER" "$WT_ROOT" "$RUN_ID" "$name")" || worktree=""
        elif ! spawn::team_worktree_create "$DRIVER" "$WT_ROOT" "$RUN_ID" "$name" "$worktree" >/dev/null; then
            worktree=""
        fi
        M_WORKTREES[$i]="$worktree"
        # The row is written whatever happened, and it is written `pending` with
        # a null handle: a handle does not exist until a launcher returns one,
        # and a launch can fail without ever producing one.
        spawn::team_member_add "$dir" "$name" "${M_ALIASES[$i]}" "$worktree" \
            "${M_CONTRACTS[$i]}" "${M_SKILLS[$i]# }" "${M_ALLOWS[$i]# }" \
            || spawn::team_fail "member '$name' could not be recorded"
        if [ -z "$worktree" ]; then
            TEAM_UNPLACED="$TEAM_UNPLACED $name"
            # BEFORE the state, for the reader that catches the run between the
            # two writes: nobody may see `launch_failed` with no findable cause.
            team_record_launch_failure "$name" worktree_failed ""
            spawn::team_member_set "$dir" "$name" launch_state launch_failed \
                || spawn::team_fail "member '$name' could not be marked launch_failed"
        fi
        i=$(( i + 1 ))
    done
}

do_roster() {
    need_jq
    roster_parse "$@"

    local i name failed=""
    team_context
    [ -n "$RUN_DIR" ] || RUN_DIR="$DRIVER/.spawn/teams/$RUN_ID"

    i=0
    while [ "$i" -lt "${#M_NAMES[@]}" ]; do
        name="${M_NAMES[$i]}"
        spawn::team_name_ok "$name" || { SPAWN_TEAM_ERROR="member_name_invalid"
            spawn::team_fail "member name failed the grammar: $name"; }
        # R3, checked BEFORE anything is created: an explicit placement that
        # resolves to the driver's own toplevel is refused, not relocated.
        if [ -n "${M_WORKTREES[$i]}" ] && [ -d "${M_WORKTREES[$i]}" ]; then
            if [ "$(spawn::team_toplevel "${M_WORKTREES[$i]}" 2>/dev/null)" = "$DRIVER" ]; then
                SPAWN_TEAM_ERROR="driver_worktree"
                spawn::team_fail "member '$name' was placed in the driver's own worktree: $DRIVER"
            fi
        fi
        i=$(( i + 1 ))
    done

    spawn::team_record_new "$RUN_DIR" "$RUN_ID" "$MODE" "$MAX_CONC" "$MAX_ROUNDS" "$TOKEN_CEILING" \
        || spawn::team_fail "the run record for $RUN_ID could not be created"
    spawn::team_git_exclude "$DRIVER" "$WT_ROOT"
    team_place_members "$RUN_DIR"
    failed="$TEAM_UNPLACED"

    local rec obj err="null" rem="null" code=0
    rec="$(spawn::team_record_read "$RUN_DIR")" || spawn::team_fail "the run record could not be read back"
    if [ -n "$failed" ]; then
        err='"worktree_failed"'; code="$EX_UPSTREAM"
        rem="$(remedy_for worktree_failed)"
    fi
    obj="$(printf '%s' "$rec" | jq -c --arg id "$RUN_ID" --arg d "$RUN_DIR" \
        --arg f "${failed# }" --arg r "$rem" --argjson e "$err" --argjson c "$code" \
        "$(spawn::envelope_jq plugin)"' + {
          ok: ($e == null), error: $e, exit_code: $c,
          remedy: (if $e == null then null else $r end),
          detail: (if $e == null then null
                   else ("no worktree could be created for: " + $f) end),
          run_id: $id, run_dir: $d, removed: null, mode: .mode,
          team_file: null, round: null, dispatched: null,
          pending: ([ .members[] | select(.launch_state == "pending"
                                          or .launch_state == "retry_pending") ] | length),
          members: [ .members[] | {name, alias, worktree, launch_state, handle,
                                   skills, allow, grants, failure,
                                   error: (.failure.error // null)} ]}')" \
        || { SPAWN_TEAM_ERROR="record_malformed"; spawn::team_fail "the roster could not be encoded"; }
    emit "$obj" || { SPAWN_TEAM_ERROR="record_malformed"; spawn::team_fail "the roster encoded to nothing"; }
    exit "$code"
}

dispatch_parse() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --team-file) TEAM_FILE="${2:-}"; shift 2 || shift ;;
            --run-id) RUN_ID="${2:-}"; shift 2 || shift ;;
            --run-dir) RUN_DIR="${2:-}"; shift 2 || shift ;;
            --mode) F_MODE="${2:-}"; shift 2 || shift ;;
            --max-concurrent) F_CONC="${2:-}"; shift 2 || shift ;;
            --max-rounds) F_ROUNDS="${2:-}"; shift 2 || shift ;;
            --token-ceiling) F_CEILING="${2:-}"; shift 2 || shift ;;
            *)
                usage
                SPAWN_TEAM_ERROR="usage"
                spawn::team_fail "unexpected argument: $1" ;;
        esac
    done
    # A team file states a NEW run; a run id continues an existing one. One of
    # the two is required and they are not interchangeable — passing the file
    # again for a later round would re-create the record and destroy the round
    # ledger, which is what made a second dispatch wipe a run.
    [ -n "$TEAM_FILE" ] || [ -n "$RUN_ID" ] || { SPAWN_TEAM_ERROR="usage"
        spawn::team_fail "--team-file states a new team, or --run-id continues an existing run; one is required"; }
}

# A whole number, or the caller is told which bound they wrote wrong.
team_bound_ok() {   # <flag-name> <value>
    case "$2" in
        ''|*[!0-9]*) SPAWN_TEAM_ERROR="usage"
            spawn::team_fail "$1 takes a whole number of members, rounds or tokens, and was given '$2'" ;;
    esac
}

# KTD20 — 0 is the record's sentinel for "no bound", and it is NOT a ceiling a
# caller may state. Stated, it would fire before the first round: the run would
# dispatch nobody and report a finished team, which is the failure R19's "no
# default" exists to avoid rather than to hide. So absent stays absent and
# stated-zero is refused, at both boundaries a value can arrive from.
team_ceiling_ok() {     # <stated: flag name, or empty> <value>
    [ -n "$1" ] || return 0
    [ "$2" = "0" ] || return 0
    SPAWN_TEAM_ERROR="token_ceiling_zero"
    spawn::team_fail "$1 was given 0, and a run that may cross no tokens at all dispatches nobody"
}

# Reads the team file into the roster arrays and the effective bounds. Every
# refusal here happens before anything is created, which is what makes R31's
# "and no worktree exists afterwards" a property of the code rather than of the
# order somebody happened to write the calls in.
team_file_load() {  # <path>
    local f="$1" name alias contract skills seen=""
    [ -f "$f" ] && [ -r "$f" ] || { SPAWN_TEAM_ERROR="team_file_unreadable"
        spawn::team_fail "no readable team file at $f"; }
    # -s, so two concatenated objects are as refusable as an array: `jq type` on
    # a stream answers for the FIRST value and says nothing about the rest.
    jq -se 'length == 1 and (.[0] | type == "object")' "$f" >/dev/null 2>&1 \
        || { SPAWN_TEAM_ERROR="team_file_malformed"
             spawn::team_fail "the team file is not one JSON object: $f"; }
    jq -e '(.members | type) == "array" and (.members | length) > 0' "$f" >/dev/null 2>&1 \
        || { SPAWN_TEAM_ERROR="team_file_empty"
             spawn::team_fail "the team file names no members: $f"; }
    if jq -e 'any(.members[]; has("worktree") or has("cwd") or has("path"))' "$f" >/dev/null 2>&1; then
        SPAWN_TEAM_ERROR="member_path_forbidden"
        spawn::team_fail "a member in $f names its own path, and placement is not the team file's to choose"
    fi
    # NAME IS CHECKED HERE, NOT LEFT TO THE GRAMMAR LATER. The rows are read as
    # tab-separated fields, and an absent `.name` renders as an empty LEADING
    # field — tab is IFS whitespace, so the run of tabs collapses and every
    # value shifts one place left: the alias becomes the name, the contract
    # becomes the alias. Measured before this check: a member with no name was
    # placed at `<root>/<run-id>/<its alias>` and bg-agent was invoked with the
    # contract path as its `--alias`, so a worktree existed before anything
    # refused — breaking the refuse-before-create property this function's own
    # header claims and member_incomplete's remedy states.
    if jq -e 'any(.members[]; ((.name // "") == "") or ((.alias // "") == "")
                              or ((.contract // "") == ""))' "$f" >/dev/null 2>&1; then
        SPAWN_TEAM_ERROR="member_incomplete"
        spawn::team_fail "a member in $f has no name, no alias or no contract"
    fi

    MODE="$(jq -r '.mode // "attached"' "$f" 2>/dev/null)"
    MAX_CONC="$(jq -r '.bounds.max_concurrent // empty' "$f" 2>/dev/null)"
    MAX_ROUNDS="$(jq -r '.bounds.max_rounds // empty' "$f" 2>/dev/null)"
    # A stated 0 and an omitted key must stay DIFFERENT here (KTD20), and `//`
    # keeps them apart: only null and false are falsy in jq, so `0 // empty` is
    # 0. `stated` is what carries that distinction on to the refusal.
    local stated=""
    TOKEN_CEILING="$(jq -r '.bounds.token_ceiling // empty' "$f" 2>/dev/null)"
    [ -n "$TOKEN_CEILING" ] && stated="token_ceiling in the team file"
    [ -n "$F_MODE" ] && MODE="$F_MODE"
    [ -n "$F_CONC" ] && MAX_CONC="$F_CONC"
    [ -n "$F_ROUNDS" ] && MAX_ROUNDS="$F_ROUNDS"
    [ -n "$F_CEILING" ] && { TOKEN_CEILING="$F_CEILING"; stated="--token-ceiling"; }
    # KTD9 — the bound is the caller's. These are the values a team file that
    # states none inherits, not a limit compiled into the surface.
    [ -n "$MAX_CONC" ] || MAX_CONC=2
    [ -n "$MAX_ROUNDS" ] || MAX_ROUNDS=3
    [ -n "$TOKEN_CEILING" ] || TOKEN_CEILING=0
    team_bound_ok --max-concurrent "$MAX_CONC"
    team_bound_ok --max-rounds "$MAX_ROUNDS"
    team_bound_ok --token-ceiling "$TOKEN_CEILING"
    team_ceiling_ok "$stated" "$TOKEN_CEILING"
    [ "$MAX_CONC" -gt 0 ] || { SPAWN_TEAM_ERROR="usage"
        spawn::team_fail "--max-concurrent 0 would dispatch nobody and report a round"; }

    # Line-per-field, the one idiom this file uses for the job. The validator
    # above already refuses an empty name, alias or contract, so a shift cannot
    # reach here — but that made this loop's safety depend on a check in another
    # function, and the trap is documented twice in this file precisely because
    # it is invisible at the call site.
    while IFS= read -r name; do
        IFS= read -r alias || break
        IFS= read -r contract || break
        IFS= read -r skills || break
        IFS= read -r allow || break
        spawn::team_name_ok "$name" || { SPAWN_TEAM_ERROR="member_name_invalid"
            spawn::team_fail "member name failed the grammar: $name"; }
        case " $seen " in
            *" $name "*) SPAWN_TEAM_ERROR="member_duplicate"
                spawn::team_fail "two members in $f are named '$name'" ;;
        esac
        seen="$seen $name"
        M_NAMES+=("$name"); M_ALIASES+=("$alias"); M_CONTRACTS+=("$contract")
        M_SKILLS+=("$skills"); M_WORKTREES+=(""); M_ALLOWS+=("$allow")
    done < <(jq -r '.members[] | (.name, .alias, .contract,
                                 ((.skills // []) | join(" ")),
                                 ((.allow // []) | join(" ")))' "$f" 2>/dev/null)
    [ "${#M_NAMES[@]}" -gt 0 ] || { SPAWN_TEAM_ERROR="team_file_malformed"
        spawn::team_fail "no member in $f could be read as a name, an alias and a contract"; }
}

# One attempt, one member. bg-agent's stdout is CAPTURED: it answers with its
# own JSON object, and stdout here belongs to this surface's one object.
# Returns 0 when the member is dispatched — the caller counts those against the
# concurrency maximum, so a refused launch never spends a slot it is not using.
team_launch_member() {  # <index> <round>
    local i="$1" round="$2" name="${M_NAMES[$i]}" out rc handle err s a bad=""
    local args=()
    for s in ${M_SKILLS[$i]}; do args+=(--skill "$s"); done
    # Checked HERE, against the same predicate bg-agent's own ceiling uses
    # (spawn::ceiling_grantable), rather than left to bg-agent alone: its grant
    # check runs in the DETACHED supervisor, after the launcher has already
    # answered this caller with a handle — so a bad --allow would read
    # `dispatched` here for the whole window before the job failed on its own,
    # and never as `launch_failed`. `grant_refused` is checked before ANY
    # --allow is forwarded, so a refused member never reaches bg-agent at all.
    for a in ${M_ALLOWS[$i]}; do
        spawn::ceiling_grantable "$a" || { bad="$a"; break; }
    done
    if [ -n "$bad" ]; then
        out="$(jq -nc --arg e grant_refused --arg d \
            "'$bad' is not a tool this surface may grant to a team member" \
            '{error:$e, detail:$d}')"
        rc=1
    else
        for a in ${M_ALLOWS[$i]}; do args+=(--allow "$a"); done
        out="$(bash "$BG_AGENT" --alias "${M_ALIASES[$i]}" --contract "${M_CONTRACTS[$i]}" \
            --cwd "${M_WORKTREES[$i]}" ${args[@]+"${args[@]}"} 2>/dev/null)"
        rc=$?
    fi
    handle="$(printf '%s' "$out" | jq -r '.handle // empty' 2>/dev/null)"
    if [ "$rc" -eq 0 ] && [ -n "$handle" ]; then
        # The handle is written BEFORE the state, because the record layer takes
        # one field at a time: a reader catching the run between the two writes
        # must never see a member claiming `dispatched` with no way to find the
        # job it is claiming.
        spawn::team_member_set "$RUN_DIR" "$name" handle "$handle" \
            || spawn::team_fail "member '$name' was launched and its handle could not be recorded"
        spawn::team_member_set "$RUN_DIR" "$name" round "$round" \
            || spawn::team_fail "member '$name' was launched and its round could not be recorded"
        spawn::team_member_set "$RUN_DIR" "$name" started_at "$(now_utc)" \
            || spawn::team_fail "member '$name' was launched and its start time could not be recorded"
        spawn::team_member_set "$RUN_DIR" "$name" launch_state dispatched \
            || spawn::team_fail "member '$name' was launched and could not be marked dispatched"
        return 0
    fi
    # R5 — the member is recorded failed and the round goes on. The launcher's
    # own error value is kept rather than reduced to "it failed": the caller's
    # next move for job_already_running is not their next move for
    # contract_invalid.
    err="$(printf '%s' "$out" | jq -r '.error // empty' 2>/dev/null)"
    [ -n "$err" ] || err="launch_failed"
    # The round is recorded BEFORE the state, and on this path as much as on the
    # success path above: a member whose launch was ATTEMPTED in round N belongs
    # to round N. Left null, a round whose launches ALL failed has no assigned
    # members at all, and the chokepoint's round tally — which needs at least
    # one member before it will call a round finished — holds it `running` for
    # ever. The advance then answers `waiting` on a round nothing can finish.
    spawn::team_member_set "$RUN_DIR" "$name" round "$round" \
        || spawn::team_fail "member '$name' failed to launch and its round could not be recorded"
    # The cause goes on the ROW, and before the state for the same reason the
    # round does. TEAM_LAUNCH_ERRS dies with this process; the record is what a
    # caller still has after it.
    team_record_launch_failure "$name" "$err" "$out"
    spawn::team_member_set "$RUN_DIR" "$name" launch_state launch_failed \
        || spawn::team_fail "member '$name' failed to launch and could not be marked launch_failed"
    TEAM_LAUNCH_ERRS="$(printf '%s' "$TEAM_LAUNCH_ERRS" | jq -c --arg n "$name" --arg e "$err" '.[$n] = $e')"
    say "team: member '$name' was not launched: $err"
    return 1
}

# A LATER ROUND IS DISPATCHED FROM THE RECORD, NEVER FROM THE TEAM FILE AGAIN.
# The caller states the team once (KTD22); re-reading their file here would let
# an edit between rounds move a target mid-run, which is the whole reason the
# file is copied at dispatch. So the roster for round N+1 is the members the
# record still calls `pending`, with the alias, contract and skills the record
# already holds, and the bounds come from the record too.
#
# Members already dispatched are NOT re-placed: their checkouts exist, and
# `git worktree add` over an existing path fails, which is what made re-passing
# --team-file destroy a run rather than continue it.
team_round_load() {     # <run-dir>
    local rec name alias contract skills
    rec="$(spawn::team_record_read "$1")" || spawn::team_fail "the run record could not be read"
    MODE="$(printf '%s' "$rec" | jq -r '.mode')"
    MAX_CONC="$(printf '%s' "$rec" | jq -r '.bounds.max_concurrent')"
    MAX_ROUNDS="$(printf '%s' "$rec" | jq -r '.bounds.max_rounds')"
    TOKEN_CEILING="$(printf '%s' "$rec" | jq -r '.bounds.token_ceiling')"
    # THE CHECKOUT COMES FROM THE RECORD, and round 2 places nothing. Round 1
    # already created a worktree for EVERY member, not only the ones it had
    # concurrency for — so a pending member's checkout exists and its row is
    # already written. Re-placing would fail on the existing path, and re-adding
    # the row is refused as a duplicate name, which is what a first attempt at
    # this did.
    #
    # One field per line, not @tsv: an empty field between tabs collapses,
    # because tab is IFS whitespace.
    #
    # `$fields` is a COMMAND SUBSTITUTION, and $() strips EVERY trailing
    # newline, not one — so a stream whose last projected value is the empty
    # string loses that whole line, and the read loop breaks one field short
    # on exactly that member. `.worktree` stays LAST for this reason: a placed
    # member's worktree is never empty, so it is the one field here that can
    # never trigger it. `allow` sits before it rather than after, on purpose —
    # measured by putting it last first: an unallowed member (the common case)
    # then read as `M_NAMES=()`, and every round-2 member vanished.
    local fields n
    M_NAMES=(); M_ALIASES=(); M_CONTRACTS=(); M_SKILLS=(); M_WORKTREES=(); M_ALLOWS=()
    fields="$(printf '%s' "$rec" | jq -r '.members[]
        | select(.launch_state == "pending" or .launch_state == "retry_pending")
        | (.name, .alias, .contract, ((.skills // []) | join(" ")),
           ((.allow // []) | join(" ")), .worktree)' 2>/dev/null)"
    n=0
    while IFS= read -r name; do
        IFS= read -r alias || break
        IFS= read -r contract || break
        IFS= read -r skills || break
        IFS= read -r allow || break
        IFS= read -r worktree || break
        [ -n "$name" ] || continue
        M_NAMES+=("$name"); M_ALIASES+=("$alias"); M_CONTRACTS+=("$contract")
        M_SKILLS+=("$skills"); M_WORKTREES+=("$worktree"); M_ALLOWS+=("$allow")
        n=$(( n + 1 ))
    done <<EOF
$fields
EOF
}

do_dispatch() {
    need_jq
    dispatch_parse "$@"

    # WHICH ROUND THIS IS, is decided by whether the RECORD exists — not by
    # which flags were passed. Naming a run id for a NEW run is legitimate and
    # every round-1 caller does it, so the flags alone cannot tell the two
    # apart; the record can.
    local existing=""
    if [ -n "$RUN_ID" ]; then
        team_context
        [ -n "$RUN_DIR" ] || RUN_DIR="$DRIVER/.spawn/teams/$RUN_ID"
        [ -f "$(spawn::team_record_path "$RUN_DIR")" ] && existing=yes
    fi

    # Re-stating the team over a live run would re-create the record and destroy
    # its round ledger. Refuse before anything is touched.
    if [ -n "$existing" ] && [ -n "$TEAM_FILE" ]; then
        SPAWN_TEAM_ERROR="usage"
        spawn::team_fail "run $RUN_ID already exists; continue it with --run-id alone, or choose a new run id"
    fi

    # A run id naming no run says so. Without this it falls through to the
    # team-file path with an empty path and reports "no readable team file at ",
    # which describes an argument the caller never passed.
    if [ -z "$existing" ] && [ -z "$TEAM_FILE" ]; then
        SPAWN_TEAM_ERROR="record_missing"
        spawn::team_fail "no run record for $RUN_ID at $RUN_DIR; --team-file starts a new run"
    fi

    # ROUND N+1: the record is the roster.
    if [ -n "$existing" ]; then
        team_round_load "$RUN_DIR"
        TEAM_FILE_COPY="$RUN_DIR/team-file.json"
        # Nothing left to dispatch is not an error, and it is not a round. A
        # round opened here would sit at `running` with no members assigned,
        # which is the shape that hangs a driver for ever.
        # `usage`, not a new error class: `roster_exhausted` already means
        # something in this surface — it is a derived STOP REASON — and giving
        # one name two meanings across the record and the envelope is how a
        # caller ends up branching on the wrong one.
        [ "${#M_NAMES[@]}" -gt 0 ] || { SPAWN_TEAM_ERROR="usage"
            spawn::team_fail "every member of $RUN_ID has already been dispatched; advance reports the run's stop reasons"; }
        team_revalidate_placements
        do_dispatch_round
        return 0
    fi

    team_file_load "$TEAM_FILE"

    [ -n "$RUN_ID" ] || RUN_ID="$(jq -r '.run_id // empty' "$TEAM_FILE" 2>/dev/null)"
    [ -n "$RUN_ID" ] || RUN_ID="t$(date -u '+%Y%m%d%H%M%S')-$$"
    spawn::team_name_ok "$RUN_ID" || { SPAWN_TEAM_ERROR="usage"
        spawn::team_fail "the run id is a directory component and failed the grammar: $RUN_ID"; }

    team_context
    [ -n "$RUN_DIR" ] || RUN_DIR="$DRIVER/.spawn/teams/$RUN_ID"

    # R31, before the record and before any checkout. Single-round arms no
    # driver, so a roster it cannot finish in one round is not clamped — there
    # would be nothing left able to advance the remainder.
    if [ "$MODE" = "single-round" ] && [ "${#M_NAMES[@]}" -gt "$MAX_CONC" ]; then
        SPAWN_TEAM_ERROR="roster_exceeds_round"
        spawn::team_fail "single-round was given ${#M_NAMES[@]} members and a concurrency maximum of $MAX_CONC"
    fi

    spawn::team_record_new "$RUN_DIR" "$RUN_ID" "$MODE" "$MAX_CONC" "$MAX_ROUNDS" "$TOKEN_CEILING" \
        || spawn::team_fail "the run record for $RUN_ID could not be created"

    # KTD22 — the run reads its OWN copy from here on, so editing the file the
    # caller wrote cannot move a target mid-run. `cat`, not `cp`: cp is aliased
    # interactive on some operators' boxes and silently declines to overwrite.
    TEAM_FILE_COPY="$RUN_DIR/team-file.json"
    cat "$TEAM_FILE" > "$TEAM_FILE_COPY" 2>/dev/null || { SPAWN_TEAM_ERROR="record_unwritable"
        spawn::team_fail "the team file could not be copied into $RUN_DIR"; }

    spawn::team_git_exclude "$DRIVER" "$WT_ROOT"
    team_place_members "$RUN_DIR"
    # R12. A fresh run that placed NOBODY made a root and put nothing in it, and
    # teardown is operator-invoked — so without this the empty directory sits in
    # the same namespace as real worktrees until somebody notices it. Dispatch
    # knows the root it made; it does not need the record to name it. `rmdir`
    # inside the prune refuses a root anything else is using.
    local k=0 placed=""
    while [ "$k" -lt "${#M_WORKTREES[@]}" ]; do
        [ -n "${M_WORKTREES[$k]}" ] && { placed=yes; break; }
        k=$(( k + 1 ))
    done
    [ -n "$placed" ] || spawn::team_run_root_prune "$WT_ROOT/$RUN_ID" "$RUN_ID" || :
    do_dispatch_round
}

# The half both rounds share: place whatever is unplaced, open a round, launch
# up to the concurrency maximum, and report without waiting. Round 1 arrives
# here after the record is created and the team file copied; round N+1 arrives
# with the roster read back out of the record.
# Round N+1 places nothing: the rows and the checkouts already exist. What it
# must still do is CHECK them — a member whose recorded worktree has since gone
# is treated exactly as an unplaced one rather than launched with an empty
# --cwd, which bg-agent reads as the CALLING process's directory and which has
# already been measured to make a member claim the driver's own checkout.
team_revalidate_placements() {
    local j=0
    TEAM_UNPLACED=""
    while [ "$j" -lt "${#M_NAMES[@]}" ]; do
        if [ -z "${M_WORKTREES[$j]}" ] || [ ! -d "${M_WORKTREES[$j]}" ]; then
            M_WORKTREES[$j]=""
            TEAM_UNPLACED="$TEAM_UNPLACED ${M_NAMES[$j]}"
            team_record_launch_failure "${M_NAMES[$j]}" worktree_failed ""
            spawn::team_member_set "$RUN_DIR" "${M_NAMES[$j]}" launch_state launch_failed \
                || spawn::team_fail "member '${M_NAMES[$j]}' could not be marked launch_failed"
        fi
        j=$(( j + 1 ))
    done
}

do_dispatch_round() {
    local name
    for name in $TEAM_UNPLACED; do
        TEAM_LAUNCH_ERRS="$(printf '%s' "$TEAM_LAUNCH_ERRS" | jq -c --arg n "$name" '.[$n] = "worktree_failed"')"
    done

    spawn::team_round_open "$RUN_DIR" || spawn::team_fail "a round could not be opened for $RUN_ID"
    local round
    round="$(spawn::team_record_read "$RUN_DIR" | jq -r '.rounds | length')" \
        || spawn::team_fail "the run record could not be read back after opening a round"

    local i=0 live=0
    while [ "$i" -lt "${#M_NAMES[@]}" ]; do
        [ "$live" -lt "$MAX_CONC" ] || break
        if [ -n "${M_WORKTREES[$i]}" ]; then
            team_launch_member "$i" "$round" && live=$(( live + 1 ))
        else
            # Placement already marked this member launch_failed, before any
            # round existed. It still belongs to the round it was reached in —
            # the same reason team_launch_member records the round on its own
            # failure path, and the case where NO member got a checkout is the
            # one that would otherwise leave an empty round running for ever.
            spawn::team_member_set "$RUN_DIR" "${M_NAMES[$i]}" round "$round" \
                || spawn::team_fail "member '${M_NAMES[$i]}' has no checkout and its round could not be recorded"
        fi
        i=$(( i + 1 ))
    done

    # KTD17 — nothing is awaited. Every member dispatched above is running
    # behind its own detached supervisor, and this process is done with them.
    local rec obj err="null" rem="null" code=0 bad
    rec="$(spawn::team_record_read "$RUN_DIR")" || spawn::team_fail "the run record could not be read back"
    bad="$(printf '%s' "$TEAM_LAUNCH_ERRS" | jq -r 'keys | join(" ")')"
    if [ -n "$bad" ]; then
        code="$EX_UPSTREAM"
        # A member with no checkout never reached a launcher, so reporting
        # launch_failed hands the caller launch_failed's remedy — "its launcher
        # refused it" — when the real fix is to free the path or tear the run
        # down. The two causes share exit 5 and are told apart only here; the
        # per-member error already carries the truth either way.
        if printf '%s' "$TEAM_LAUNCH_ERRS" | jq -e '[.[]] | all(. == "worktree_failed")' >/dev/null 2>&1; then
            err='"worktree_failed"'; rem="$(remedy_for worktree_failed)"
        else
            err='"launch_failed"'; rem="$(remedy_for launch_failed)"
        fi
    fi
    obj="$(printf '%s' "$rec" | jq -c --arg id "$RUN_ID" --arg d "$RUN_DIR" \
        --arg tf "$TEAM_FILE_COPY" --arg f "$bad" --arg r "$rem" \
        --argjson le "$TEAM_LAUNCH_ERRS" --argjson rd "$round" \
        --argjson e "$err" --argjson c "$code" \
        "$(spawn::envelope_jq plugin)"' + {
          ok: ($e == null), error: $e, exit_code: $c,
          remedy: (if $e == null then null else $r end),
          detail: (if $e == null then null
                   else ("these members were not launched: " + $f) end),
          run_id: $id, run_dir: $d, team_file: $tf, mode: .mode, round: $rd,
          removed: null,
          dispatched: ([ .members[] | select(.launch_state == "dispatched") ] | length),
          pending: ([ .members[] | select(.launch_state == "pending"
                                          or .launch_state == "retry_pending") ] | length),
          # The recorded cause first, the in-process accumulator only as a
          # fallback for a launch whose record write did not land. $le holds
          # the launches of THIS process alone, so a member that failed in an
          # earlier round read as error:null beside a non-null failure (KTD2).
          # No apostrophes here: this jq program is a single-quoted shell
          # string, and one would close it.
          members: [ .members[] | {name, alias, worktree, launch_state, handle,
                                   round, skills, allow, grants, failure,
                                   error: (.failure.error // $le[.name] // null)} ]}')" \
        || { SPAWN_TEAM_ERROR="record_malformed"; spawn::team_fail "the round could not be encoded"; }
    emit "$obj" || { SPAWN_TEAM_ERROR="record_malformed"; spawn::team_fail "the round encoded to nothing"; }
    exit "$code"
}
