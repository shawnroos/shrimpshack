#!/usr/bin/env bash
# team.sh — the team surface: a roster of named members, each in its own git
# worktree, and a teardown that removes exactly what the record names.
#
#   team.sh roster   --run-id <id> --member <name> --alias <a> --contract <c>
#                    [--skill <s>]... [--worktree <path>] [--member ...]
#   team.sh dispatch --team-file <path> [--run-id <id>] [bounds]
#   team.sh advance  --run-id <id> | --run-dir <dir>
#   team.sh teardown --run-dir <dir>
#   team.sh --describe
#
# WHY A WORKTREE PER MEMBER (R2)
# ------------------------------
# jobs.sh takes a one-job-per-worktree lock rooted at `<worktree>/.spawn`. Two
# members sharing a worktree would contend for that lock, and the second would
# be refused `job_already_running` — so the roster gives each member its own
# checkout rather than teaching the lock about teams.
#
# WHY THE DRIVER'S OWN WORKTREE IS REFUSED (R3)
# ---------------------------------------------
# A member placed in the driver's worktree takes that lock out from under the
# driver, and a member's writes then land in the tree the driver is reading its
# own record from. The check compares RESOLVED TOPLEVELS, not path prefixes:
# the normal layout nests the worktrees directory INSIDE the primary checkout,
# so a prefix test would refuse the default placement.
#
# WHY THE RECORD IS THE TEARDOWN MANIFEST
# ---------------------------------------
# `spawn::skill_unprovision` reads a manifest rather than globbing its
# destination, and this is the same argument one layer up: a glob of the run
# root would also remove a worktree somebody created beside it. KTD18 already
# gives the run one file, so that file is the manifest — a second one is a
# second thing to drift.
#
# THIS FILE OWNS THE ENVELOPE. team-record.sh deliberately does not: it sets
# SPAWN_TEAM_ERROR and returns non-zero, and the mapping onto the frozen exit
# enum lives here, at the surface, in spawn::team_code_for.

set -uo pipefail

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck source=./sanitize.sh
. "$SCRIPT_DIR/sanitize.sh"
if ! declare -F say >/dev/null 2>&1; then
    # shellcheck source=./common.sh
    . "$SCRIPT_DIR/common.sh"
fi
# shellcheck source=./team-record.sh
. "$SCRIPT_DIR/team-record.sh"
# shellcheck source=./team-worktree.sh
. "$SCRIPT_DIR/team-worktree.sh"
# shellcheck source=./team-dispatch.sh
. "$SCRIPT_DIR/team-dispatch.sh"
# shellcheck source=./team-advance.sh
. "$SCRIPT_DIR/team-advance.sh"
# shellcheck source=./team-view.sh
. "$SCRIPT_DIR/team-view.sh"

EX_OK=0
EX_USAGE=2
EX_UPSTREAM=5

# The launcher this surface shells out to. Sibling in this directory, resolved
# the same way team-record.sh is: a team member IS a bg-agent job.
BG_AGENT="$SCRIPT_DIR/bg-agent.sh"

EMITTED=0
HELP_REQUESTED=false
ALIAS=""

RUN_ID=""
RUN_DIR=""

# ---------------------------------------------------------------------------
# R12 — this surface's vocabulary, keyed on the enum and falling through to the
# shared table. Every value team-record.sh can set has an entry here, because
# this file is the only place those refusals become something a caller reads.
# ---------------------------------------------------------------------------
remedy_for() {
    case "$1" in
        worktree_failed)
            printf 'The member has no checkout, so it cannot be dispatched; the rest of the roster is intact and its worktrees exist. Read `detail` for what git said — a path already in use and a full disk are the two that happen. Free the path named there (`git worktree list` shows what holds it) or run `teardown` on the run id, then call again. Retrying unchanged repeats the same failure.' ;;
        driver_worktree)
            printf 'A member may not run in the worktree the driver is running in: they would contend for the one-job-per-worktree lock and write into the tree the driver reads its own record from. Drop the --worktree flag and let the roster place the member, or name a path that is not this checkout.' ;;
        member_duplicate)
            printf 'Two members in one run share a name, and the run reports members by name — so one of them would be unaddressable. Rename one and call again; nothing was left behind for the duplicate.' ;;
        member_name_invalid)
            printf 'A member name becomes a directory under the run root and is later the only thing teardown removes, so it must match [A-Za-z0-9][A-Za-z0-9._-]* with no dot run. Rename the member named in `detail` and call again.' ;;
        member_unknown)
            printf 'This run has no member by that name. Read `members` in the run record for the names it does have.' ;;
        field_unknown)
            printf 'A caller tried to write a member field the record does not accept. The record takes only the fields it derives nothing from — a derived value has no setter, because it is recomputed at the write. This is a bug in the surface rather than in the invocation: report it with the field name in `detail`.' ;;
        record_missing|record_malformed)
            printf 'The run record is absent or unreadable, so nothing can be said about this run — including what it created. Check the run directory named in `detail`; if the record is gone, any worktrees the run made must be removed with `git worktree remove` by hand, because nothing else knows their names.' ;;
        record_unwritable)
            printf 'The run record could not be written, so the run was not started rather than started unrecorded. Check the run directory named in `detail` is writable and call again.' ;;
        launch_failed)
            printf 'A member named in `members` has no job: its launcher refused it, and that member carries the launcher error value that says why. The rest of the round went ahead. Read that value, fix that member, and advance the run; the members that did start are unaffected and nothing needs relaunching.' ;;
        team_file_unreadable)
            printf 'The team is stated in one file this surface reads, and there is nothing readable at the path in `detail`. Give --team-file a path to a file this process can read.' ;;
        team_file_malformed)
            printf 'A team file is ONE JSON object — not an array, not two objects, not a fragment. Fix the file named in `detail` so `jq -e "type == \"object\""` answers true, then call again.' ;;
        team_file_empty)
            printf 'The team file has no members, and a run with nobody in it would report success having done nothing. Add a `members` array with at least one entry naming a name, an alias and a contract.' ;;
        member_incomplete)
            printf 'Every member carries its own alias and its own contract, because that is what a member IS here. The member named in `detail` is missing one of them. Add it and call again; nothing was created.' ;;
        member_path_forbidden)
            printf 'A team file does not choose where a member runs. Placement belongs to this surface — a member outside `<root>/<run-id>/<name>` is one teardown will never remove, and the team file is an ordinary file anything on the box can write. Drop the path key from the member named in `detail`; the run will place it.' ;;
        token_ceiling_zero)
            printf 'A token ceiling of zero stops the run before its first round, so it would dispatch nobody and report a finished team. There is no default ceiling: for a run with no token bound, leave --token-ceiling off entirely and drop token_ceiling from the bounds object in the team file. For a run with one, give a positive number. Nothing was created.' ;;
        roster_exceeds_round)
            printf 'Single-round mode dispatches once and arms nothing to advance the rest, so a roster bigger than one round would leave the remainder pending forever. Nothing was created. Either raise --max-concurrent to cover the whole roster, or run the team in attached or unattended mode, which advances over successive rounds.' ;;
        *) spawn::remedy_for "$1" ;;
    esac
}

# Null-valued data fields, so all three encoder tiers describe the same shape.
emit_error() { spawn::emit_error plugin "run_id run_dir members removed team_file mode round round_state intent reasons complete ceiling_state members_unmeasured dispatched pending diagram listed omitted" "$@"; }

# The frozen enum (0 ok · 2 usage · 3 unreachable · 4 alias · 5 upstream ·
# 6 deadline · 7 auth) takes no new member, so a new failure class is a new
# `error` VALUE mapped onto an existing code here.
#
# worktree_failed maps to 5 rather than 2 on bg-agent's precedent: its
# `launch_failed` — the same class, launch machinery that is ours and that
# failed for a reason the caller did not commit in their argv — is declared at
# exit_code 5 in that script's own error table. Everything else this surface
# can refuse IS the caller's invocation or their run directory, which is 2.
spawn::team_code_for() {
    case "$1" in
        worktree_failed|launch_failed) printf '%s' "$EX_UPSTREAM" ;;
        *) printf '%s' "$EX_USAGE" ;;
    esac
}

# Fail with whatever team-record.sh (or a local step) left in SPAWN_TEAM_ERROR.
spawn::team_fail() {
    local err="${SPAWN_TEAM_ERROR:-internal}" code
    code="$(spawn::team_code_for "$err")"
    printf '✗ %s\n' "$(spawn::sanitize_for_display "$*")" >&2
    emit_error "$code" "$err" "$*"
    exit "$code"
}

# Set the refusal a failed record read MEANT. The reader sets it itself, but it
# runs in a command substitution and that subshell's SPAWN_TEAM_ERROR never
# reaches the caller — which reported `internal`, whose remedy tells a human
# this is a plugin bug. The remedy table is keyed on the error value, so a wrong
# value here is wrong recovery guidance, not a cosmetic mislabel.
spawn::team_record_refusal() {  # <run-dir>
    if [ -f "$(spawn::team_record_path "$1")" ]; then
        SPAWN_TEAM_ERROR="record_malformed"
    else
        SPAWN_TEAM_ERROR="record_missing"
    fi
}

# ---------------------------------------------------------------------------
# Grammar. A member name becomes a path component under the run root AND is the
# only thing teardown consents to remove, so it is closed by construction.
# Default-deny on the character set, not a blocklist of what has bitten.
# ---------------------------------------------------------------------------
spawn::team_name_ok() {
    local n="${1:-}"
    [ -n "$n" ] || return 1
    case "$n" in
        .|..|*/*|*..*) return 1 ;;
    esac
    printf '%s' "$n" | grep -qE '^[A-Za-z0-9][A-Za-z0-9._-]*$'
}


# ---------------------------------------------------------------------------
# Verbs
# ---------------------------------------------------------------------------
usage() {
    cat >&2 <<'USAGE'
team.sh roster   --run-id <id> [--run-dir <dir>] [--mode attached|unattended]
                 [--max-concurrent N] [--max-rounds N] [--token-ceiling N]
                 --member <name> --alias <alias> --contract <path>
                 [--skill <name>]... [--worktree <path>]
                 [--member <name> ...]
team.sh dispatch --team-file <path> [--run-id <id>] [--run-dir <dir>]
                 [--mode single-round|attached|unattended]
                 [--max-concurrent N] [--max-rounds N] [--token-ceiling N]
team.sh advance  --run-id <id> | --run-dir <dir>
team.sh status   --run-id <id> | --run-dir <dir>
team.sh teardown --run-dir <dir>
team.sh --describe
USAGE
}

# Parallel indexed arrays, not a map: bash 3.2 has no associative array, and
# the roster's ORDER is meaningful anyway — U4 dispatches in roster order.
M_NAMES=(); M_ALIASES=(); M_CONTRACTS=(); M_SKILLS=(); M_WORKTREES=()


# The driver's own checkout and where member worktrees belong. Both verbs that
# create anything resolve them the same way, before they create anything.
team_context() {
    DRIVER="$(spawn::team_toplevel .)" || { SPAWN_TEAM_ERROR="usage"
        spawn::team_fail "this is not a git checkout, and a member is placed relative to one"; }
    WT_ROOT="$(spawn::team_worktree_root "$DRIVER")" || { SPAWN_TEAM_ERROR="usage"
        spawn::team_fail "could not resolve where member worktrees belong"; }
}


# ---------------------------------------------------------------------------
# dispatch — one round, then exit (R1, R4, R5, R31, R33, KTD9, KTD17, KTD22)
# ---------------------------------------------------------------------------
TEAM_FILE=""
TEAM_FILE_COPY=""
TEAM_LAUNCH_ERRS='{}'
F_MODE=""; F_CONC=""; F_ROUNDS=""; F_CEILING=""


# ---------------------------------------------------------------------------
# advance — one advance of the run, and an intent the driver acts on
# (R28, R10, R6, R32, R26, KTD4, KTD19)
#
# This verb NEVER dispatches and NEVER schedules. Dispatch is U4's; scheduling
# is the driver's, because `ScheduleWakeup` is a model tool no script can call.
# What lives here is the judgment — which intent, and how long to wait — so that
# it is testable code rather than a skill's prose.
#
# WAITING IS RE-ENTRY, NOT BLOCKING (KTD4). Every fact is read from disk on
# every call; nothing is carried in an environment or an argument, and no
# conversation context is consulted. One smallest-useful advance per wake-up.
# ---------------------------------------------------------------------------
JOBS_SH="$SCRIPT_DIR/jobs.sh"
HANDLE_SH="$SCRIPT_DIR/handle.sh"
JOB_TERMINAL_STATES="done degraded failed cancelled"
ADVANCE_LOCK=""
ADVANCE_HELD=false
TEAM_PROBES='[]'

# The run-selecting flags, parsed once. Four verbs took exactly this pair and
# wrote the loop out four times; the copies had already drifted — teardown was
# missing --run-id entirely, which is why the one command the skill told a
# driver to run was refused as an unexpected argument.
#
# $1 is what the verb calls itself in its own refusal, so a caller who omits
# both flags is told which verb wanted them.
team_run_parse() {      # <verb> <args...>
    local verb="$1"; shift
    while [ $# -gt 0 ]; do
        case "$1" in
            --run-id) RUN_ID="${2:-}"; shift 2 || shift ;;
            --run-dir) RUN_DIR="${2:-}"; shift 2 || shift ;;
            *)
                usage
                SPAWN_TEAM_ERROR="usage"
                spawn::team_fail "unexpected argument: $1" ;;
        esac
    done
    [ -n "$RUN_ID" ] || [ -n "$RUN_DIR" ] || { SPAWN_TEAM_ERROR="usage"
        spawn::team_fail "$verb takes the run id dispatch returned, or --run-dir"; }
    if [ -n "$RUN_ID" ]; then
        spawn::team_name_ok "$RUN_ID" || { SPAWN_TEAM_ERROR="usage"
            spawn::team_fail "the run id is a directory component and failed the grammar: $RUN_ID"; }
    fi
}


# ---------------------------------------------------------------------------
# status — what every member is doing, probed at the moment of asking (U10)
#
# READS ONLY. `advance` is the verb that probes AND records; asking a question
# must not move a run, and a status that wrote would make two people looking at
# the same run race each other over its record. The rendering itself lives in
# team-view.sh — this is the argument-parsing and the envelope, nothing else.
# ---------------------------------------------------------------------------
do_status() {
    need_jq
    team_run_parse status "$@"
    team_context
    [ -n "$RUN_DIR" ] || RUN_DIR="$DRIVER/.spawn/teams/$RUN_ID"

    local rec obj
    if ! rec="$(spawn::team_record_read "$RUN_DIR")"; then
        spawn::team_record_refusal "$RUN_DIR"
        spawn::team_fail "no readable run record at $RUN_DIR"
    fi
    [ -n "$RUN_ID" ] || RUN_ID="$(printf '%s' "$rec" | jq -r '.run_id')"

    team_view "$rec"
    [ -n "$TEAM_VIEW_JSON" ] || { SPAWN_TEAM_ERROR="record_malformed"
        spawn::team_fail "the run at $RUN_DIR could not be rendered"; }

    obj="$(printf '%s' "$rec" | jq -c --arg id "$RUN_ID" --arg d "$RUN_DIR" \
        --argjson v "$TEAM_VIEW_JSON" \
        "$(spawn::envelope_jq plugin)"' + {
          ok:true, error:null, remedy:null, detail:null, exit_code:0,
          response_kind:"team-status",
          run_id:$id, run_dir:$d, mode:.mode,
          round:(if (.rounds | length) == 0 then null else (.rounds | last | .ordinal) end),
          round_state:(if (.rounds | length) == 0 then null else (.rounds | last | .state) end),
          team_file:null, removed:null, intent:null, reasons:null,
          dispatched:([ .members[] | select(.launch_state == "dispatched") ] | length),
          pending:([ .members[] | select(.launch_state == "pending") ] | length)}
        + $v')" \
        || { SPAWN_TEAM_ERROR="record_malformed"; spawn::team_fail "the status could not be encoded"; }
    emit "$obj" || { SPAWN_TEAM_ERROR="record_malformed"; spawn::team_fail "the status encoded to nothing"; }
    exit "$EX_OK"
}

do_teardown() {
    need_jq
    # KTD22 — every verb after dispatch takes the run id. teardown took only
    # --run-dir, so the one command the skill and the command file both told a
    # driver to run was refused as an unexpected argument.
    team_run_parse teardown "$@"
    if [ -z "$RUN_DIR" ]; then
        team_context
        RUN_DIR="$DRIVER/.spawn/teams/$RUN_ID"
    fi

    local rec removed obj
    if ! rec="$(spawn::team_record_read "$RUN_DIR")"; then
        spawn::team_record_refusal "$RUN_DIR"
        spawn::team_fail "no readable run record at $RUN_DIR"
    fi
    removed="$(spawn::team_teardown "$RUN_DIR")" \
        || spawn::team_fail "teardown could not complete for the run at $RUN_DIR"

    obj="$(printf '%s' "$rec" | jq -c --arg d "$RUN_DIR" --arg rm "$removed" \
        "$(spawn::envelope_jq plugin)"' + {
          ok: true, error: null, remedy: null, detail: null, exit_code: 0,
          run_id: .run_id, run_dir: $d,
          removed: ($rm | split("\n") | map(select(length > 0))),
          members: [ .members[] | {name, worktree} ]}')" \
        || { SPAWN_TEAM_ERROR="record_malformed"; spawn::team_fail "the teardown report could not be encoded"; }
    emit "$obj" || { SPAWN_TEAM_ERROR="record_malformed"; spawn::team_fail "the teardown report encoded to nothing"; }
    exit 0
}

# The contract as data. A caller WRITES the team file, so its shape is part of
# the contract and not a thing to be inferred from an example.
do_describe() {
    need_jq
    emit "$(jq -nc "$(spawn::envelope_jq plugin)"' + {
      ok:true, error:null, remedy:null, exit_code:0,
      response_kind:"describe",
      surface:"team.sh",
      summary:"Runs a team: a set of named members, each in its own worktree on its own alias against its own contract. `dispatch` starts one round and returns a roster immediately; `teardown` removes exactly the checkouts the run record names. The team travels as one file and every verb after dispatch takes the run id.",
      verbs:[
        {name:"roster",   note:"place members and write their provisional rows; dispatches nothing"},
        {name:"dispatch", note:"one round, then exit — up to the concurrency maximum, in roster order, and no waiting"},
        {name:"advance",  note:"one advance of the run: probe every member in flight, record what finished, and print an intent. Dispatches nothing and schedules nothing"},
        {name:"status",   note:"what every member is doing, probed at the moment of asking: resolved state, elapsed, a per-path deliverable checklist, token usage or `unknown`, and the last line of its own job log — plus a mermaid diagram of the round ledger built from those same rows. Reads only: it writes nothing and moves no run"},
        {name:"teardown", note:"remove the worktrees the run record names, and only those"}
      ],
      response_fields:[
        {name:"schema",             always:true,  note:"the version of this contract"},
        {name:"ok",                 always:true,  note:"boolean; agrees with exit_code"},
        {name:"error",              always:true,  note:"enum value or null, never prose"},
        {name:"remedy",             always:true,  note:"what to do about it; null only on success"},
        {name:"detail",             always:true,  note:"human-readable diagnostic; the only prose field"},
        {name:"content_trust",      always:true,  note:"how far the payload may be trusted"},
        {name:"content_notice",     always:true,  note:"the rule that follows from content_trust"},
        {name:"exit_code",          always:true,  note:"the process exit status, restated in the data"},
        {name:"run_id",             always:false, note:"names the run; every verb after dispatch takes it"},
        {name:"run_dir",            always:false, note:"where the one run record lives"},
        {name:"members",            always:false, note:"one row per member, by name, in roster order"},
        {name:"members[].usage",    always:false, values:["measured","unknown"],
                                    note:"whether this member’s token counts were read from the CLI’s own result envelope. `unknown` is not zero: a running member has spent tokens nobody has counted, and treating it as zero is how a ceiling fails to fire"},
        {name:"removed",            always:false, note:"teardown only: the worktrees removed, by member name"},
        {name:"team_file",          always:false, note:"the copy taken at dispatch, not the caller’s original"},
        {name:"mode",               always:false, note:"single-round | attached | unattended"},
        {name:"round",              always:false, note:"the round this answer is about"},
        {name:"round_state",        always:false, note:"whether that round is still open"},
        {name:"intent",             always:false, note:"advance only: continue | waiting | stop | noop. Act on the word, never on prose"},
        {name:"reasons",            always:false, note:"advance only: every stop condition that fired, listed — two firing together are both named, and a run stopped by a bound has not finished its work"},
        {name:"complete",           always:false, note:"whether the roster is exhausted; false while any member is never-dispatched"},
        {name:"ceiling_state",      always:false, note:"where the run stands against its token ceiling, or null when it has none"},
        {name:"members_unmeasured", always:false, note:"how many members carry `unknown` usage. A ceiling read against a roster with unmeasured members is a floor, not a total"},
        {name:"dispatched",         always:false, note:"members launched by this call"},
        {name:"pending",            always:false, note:"members the concurrency maximum held back for a later round"},
        {name:"diagram",            always:false, note:"status only: a mermaid rendering of the round ledger, built from the same rows"},
        {name:"listed",             always:false, note:"how many members this answer reports"},
        {name:"omitted",            always:false, note:"how many it left out"},
        {name:"help_requested",     always:false, note:"true only for --help; present on every error response"}
      ],
      flags:[
        {name:"--team-file",      value:"file", required:true,  default:null, note:"the team, as one JSON object; copied into the run directory at dispatch so a later edit cannot move the target"},
        {name:"--run-id",         value:"id",   required:false, default:"the team file’s run_id, or a minted one", note:"names the run; every verb after dispatch takes this instead of re-stating the team"},
        {name:"--run-dir",        value:"dir",  required:false, default:"<checkout>/.spawn/teams/<run-id>", note:"where the one run record lives"},
        {name:"--mode",           value:"name", required:false, default:"the team file’s mode, else attached", note:"single-round | attached | unattended; single-round refuses a roster larger than the concurrency maximum, because it arms nothing that could advance the remainder"},
        {name:"--max-concurrent", value:"N",    required:false, default:2, note:"members dispatched in one round; a larger roster CLAMPS and the rest stay pending for the next round. Overrides the team file"},
        {name:"--max-rounds",     value:"N",    required:false, default:3, note:"rounds this run may open. Overrides the team file"},
        {name:"--token-ceiling",  value:"N",    required:false, default:null, note:"tokens the whole team may use before the run stops between rounds. There is NO default: leave it off for a run with no token bound. 0 is refused. Nothing is applied to any single call. Overrides the team file"},
        {name:"--describe",       value:null,   required:false, default:null, note:"this document; exit 0; needs no gateway and no config"}
      ],
      team_file_fields:[
        {name:"mode",    required:false, note:"single-round | attached | unattended; a --mode flag overrides it"},
        {name:"bounds",  required:false, note:"an object of max_concurrent, max_rounds and token_ceiling; each is overridden by the flag of the same name"},
        {name:"members", required:true,  note:"one entry per member, dispatched in the order written",
         member_fields:[
           {name:"name",     required:true,  note:"the name every response reports this member by, and the only thing teardown consents to remove; [A-Za-z0-9][A-Za-z0-9._-]* with no dot run"},
           {name:"alias",    required:true,  note:"the gateway alias this member runs on"},
           {name:"contract", required:true,  note:"path to that member’s own contract file, handed to bg-agent unread"},
           {name:"skills",   required:false, note:"names of the skills this member is to have, and no other member gets them"}
         ]}
      ],
      modes:[
        {name:"single-round", note:"dispatch once and arm nothing; a roster larger than the concurrency maximum is refused, because nothing would advance the remainder"},
        {name:"attached",     note:"a driver runs another round while the roster still holds never-dispatched members, and stops when it does not"},
        {name:"unattended",   note:"the same round-by-round advance as attached, with nobody watching it between rounds"}
      ],
      intents:[
        {name:"waiting",  delay:"seconds, clamped to [60, 3600]", note:"a member of the active round is still in flight. No dispatch may follow this, so the concurrency maximum bounds members IN FLIGHT rather than members per call. The driver sleeps `delay` and re-enters"},
        {name:"continue", delay:null, note:"the active round has closed, members are still undispatched, and no bound is crossed — the driver dispatches the next round"},
        {name:"stop",     delay:null, note:"a bound fired or the roster is exhausted; `reasons` lists every one that did"},
        {name:"noop",     delay:null, note:"a live advance holds this run’s lock; the record was read for this answer and left unchanged"}
      ],
      exit_codes:[
        {code:0, error:null,            meaning:"the round was dispatched; it says nothing about any member’s outcome"},
        {code:2, error:"usage",         meaning:"a caller mistake or a refusal — branch on error, never on prose"},
        {code:5, error:"launch_failed", meaning:"at least one member was not launched; the rest of the round went ahead and the record says which"}
      ],
      error_values:[
        {value:"team_file_unreadable",  exit_code:2, note:"nothing readable at --team-file"},
        {value:"team_file_malformed",   exit_code:2, note:"the team file is not exactly one JSON object"},
        {value:"team_file_empty",       exit_code:2, note:"the team file names no members"},
        {value:"member_incomplete",     exit_code:2, note:"a member has no alias or no contract"},
        {value:"member_duplicate",      exit_code:2, note:"two members share a name, and a run reports members by name"},
        {value:"member_name_invalid",   exit_code:2, note:"a member name is not a safe directory component"},
        {value:"member_path_forbidden", exit_code:2, note:"a member names its own path; placement belongs to this surface"},
        {value:"roster_exceeds_round",  exit_code:2, note:"single-round was given more members than one round can hold; nothing was created"},
        {value:"driver_worktree",       exit_code:2, note:"a member was placed in the driver’s own checkout"},
        {value:"worktree_failed",       exit_code:5, note:"a member has no checkout; the rest of the roster is intact"},
        {value:"launch_failed",         exit_code:5, note:"a member’s launcher refused it; that member carries the launcher’s own error value"}
      ],
      notes:[
        "dispatch returns while the round is in flight. Nothing here waits, polls or reaps: each member runs behind the supervisor bg-agent detaches for it, and the run record is how the round is read afterwards.",
        "A roster larger than the concurrency maximum is not an error outside single-round mode. The extra members stay pending and the response says how many.",
        "advance prints its intent as data and never schedules its own next run. Scheduling is the driver’s action, and `delay` is on the waiting intent alone — no other intent carries one and no reader should look for one."
      ]
    }')" || { SPAWN_TEAM_ERROR="record_malformed"; spawn::team_fail "the describe object could not be encoded"; }
    exit "$EX_OK"
}

main() {
    local verb="${1:-}"
    [ $# -gt 0 ] && shift
    case "$verb" in
        roster) do_roster "$@" ;;
        dispatch) do_dispatch "$@" ;;
        advance) do_advance "$@" ;;
        status) do_status "$@" ;;
        teardown) do_teardown "$@" ;;
        --describe) do_describe ;;
        -h|--help)
            HELP_REQUESTED=true
            usage
            SPAWN_TEAM_ERROR="usage"
            spawn::team_fail "no verb given: this surface answers 'roster', 'dispatch', 'advance', 'status' and 'teardown'" ;;
        *)
            usage
            SPAWN_TEAM_ERROR="usage"
            spawn::team_fail "unknown verb — this surface answers 'roster', 'dispatch', 'advance', 'status' and 'teardown'" ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
