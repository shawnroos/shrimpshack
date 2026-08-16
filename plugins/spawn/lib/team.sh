#!/usr/bin/env bash
# team.sh — the team surface: a roster of named members, each in its own git
# worktree, and a teardown that removes exactly what the record names.
#
#   team.sh roster   --run-id <id> --member <name> --alias <a> --contract <c>
#                    [--skill <s>]... [--worktree <path>] [--member ...]
#   team.sh dispatch --team-file <path> [--run-id <id>] [bounds]
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
        roster_exceeds_round)
            printf 'Single-round mode dispatches once and arms nothing to advance the rest, so a roster bigger than one round would leave the remainder pending forever. Nothing was created. Either raise --max-concurrent to cover the whole roster, or run the team in attached or unattended mode, which advances over successive rounds.' ;;
        *) spawn::remedy_for "$1" ;;
    esac
}

# Null-valued data fields, so all three encoder tiers describe the same shape.
emit_error() { spawn::emit_error plugin "run_id run_dir members removed team_file mode round dispatched pending" "$@"; }

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

# The physically resolved toplevel of a checkout, or nothing.
spawn::team_toplevel() {
    local d="${1:-.}" top
    top="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)" || return 1
    (cd "$top" 2>/dev/null && pwd -P)
}

# Where member worktrees are placed: siblings under the project's worktrees/
# directory, in a per-run subdirectory. Placement is load-bearing — the driver's
# own `git status`, U7's snapshot and teardown all read it.
#
# The override is not a convenience knob: the derived default points at the real
# `worktrees/` of whatever repo the caller is standing in, which is where other
# people's live checkouts are.
spawn::team_worktree_root() {
    if [ -n "${SPAWN_TEAM_WORKTREE_ROOT:-}" ]; then
        printf '%s' "$SPAWN_TEAM_WORKTREE_ROOT"
        return 0
    fi
    local common primary
    common="$(git -C "${1:-.}" rev-parse --git-common-dir 2>/dev/null)" || return 1
    case "$common" in /*) : ;; *) common="$(cd "${1:-.}" && cd "$(dirname "$common")" && pwd -P)/$(basename "$common")" ;; esac
    primary="$(dirname "$common")"
    printf '%s/worktrees' "$primary"
}

# spawn::team_worktree_create <driver> <root> <run-id> <name> [explicit-path]
#
# Prints the member's worktree path. git's own output is CAPTURED rather than
# left to run: it writes the created path to stdout, and stdout here belongs to
# the one JSON object.
spawn::team_worktree_create() {
    local driver="$1" root="$2" run_id="$3" name="$4" dest="${5:-}" out
    [ -n "$dest" ] || dest="$root/$run_id/$name"
    mkdir -p "$(dirname "$dest")" 2>/dev/null || {
        SPAWN_TEAM_ERROR="worktree_failed"
        say "team: could not make room for member '$name' at $dest"
        return 1
    }
    out="$(git -C "$driver" worktree add --detach "$dest" HEAD 2>&1)" || {
        SPAWN_TEAM_ERROR="worktree_failed"
        say "team: git refused a worktree for member '$name': $out"
        return 1
    }
    printf '%s' "$dest"
}

# The repository a worktree belongs to, resolved from the worktree itself so
# teardown does not need the driver's cwd to still be what it was at roster.
spawn::team_common_dir() {
    local wt="$1" common
    common="$(cd "$wt" 2>/dev/null && git rev-parse --git-common-dir 2>/dev/null)" || return 1
    case "$common" in
        /*) : ;;
        *) common="$(cd "$wt" && cd "$(dirname "$common")" 2>/dev/null && pwd -P)/$(basename "$common")" ;;
    esac
    printf '%s' "$common"
}

# spawn::team_admin_dir <worktree> — that ONE worktree's registration directory
# under the common git dir, or nothing.
#
# This is what makes deregistration a per-path operation. `git worktree prune`
# is the obvious tool and is the wrong one: it is repository-wide, so it
# deregisters EVERY worktree in the repo whose directory is missing at that
# moment — including other sessions' live checkouts caught mid-move or on a
# stalled mount. That failure is silent on both sides: prune says nothing, and
# the session whose worktree was deregistered finds out later. Measured on a
# throwaway repo: one prune deregistered a sibling this run never touched.
#
# The returned path is default-denied to `<common>/worktrees/<id>`, so a
# `--git-dir` answer from a repo shape this does not understand removes nothing.
spawn::team_admin_dir() {
    local wt="$1" common admin
    common="$(spawn::team_common_dir "$wt")" || return 1
    admin="$(cd "$wt" 2>/dev/null && git rev-parse --git-dir 2>/dev/null)" || return 1
    case "$admin" in /*) : ;; *) admin="$wt/$admin" ;; esac
    case "$admin" in
        "$common"/worktrees/?*) printf '%s' "$admin" ;;
        *) return 1 ;;
    esac
}

spawn::team_primary_of() {
    local common
    common="$(spawn::team_common_dir "$1")" || return 1
    dirname "$common"
}

# spawn::team_teardown <run-dir> — remove exactly the worktrees the record
# names, one path per line on stdout.
#
# DEFAULT-DENY ON THE PATH, and the destination is never globbed. A member's
# path is removed only when it resolves to `<something>/<run-id>/<member-name>`
# — the shape the roster creates — so a run root shared with a checkout somebody
# made beside it cannot lose that checkout to this function. That is
# `spawn::skill_unprovision`'s argument one layer up, where the thing at risk is
# a worktree holding uncommitted work rather than a copied skill.
spawn::team_teardown() {
    local dir="$1" rec run_id name wt real primary admin
    rec="$(spawn::team_record_read "$dir")" || return 1
    run_id="$(printf '%s' "$rec" | jq -r '.run_id')"
    while IFS='	' read -r name wt; do
        [ -n "$wt" ] || continue
        real="$(cd "$(dirname "$wt")" 2>/dev/null && pwd -P)/$(basename "$wt")" || continue
        [ "$(basename "$real")" = "$name" ] || continue
        [ "$(basename "$(dirname "$real")")" = "$run_id" ] || continue
        primary="$(spawn::team_primary_of "$real")" || continue
        # Read BEFORE the removal: once the directory is gone there is nothing
        # left to resolve the registration from.
        admin="$(spawn::team_admin_dir "$real")" || admin=""
        if ! git -C "$primary" worktree remove --force "$real" >/dev/null 2>&1; then
            # git refuses a LOCKED worktree even under --force, and the member's
            # files still sit there. Left behind, the next run of the same id
            # cannot place that member at all. The tree and then that one
            # registration — never a repository-wide prune (see
            # spawn::team_admin_dir).
            rm -rf "$real" 2>/dev/null || continue
            [ -n "$admin" ] && rm -rf "$admin" 2>/dev/null
        fi
        printf '%s\n' "$real"
    done < <(printf '%s' "$rec" | jq -r '.members[] | [.name, .worktree] | @tsv')
    return 0
}

# Keep the run's worktrees out of the primary checkout's `git status`. They are
# only visible there when the root sits inside the repo — the layout this
# plugin's own tree uses — so the relative path is computed rather than assumed,
# and nothing is written when it does not.
#
# The exclude lives in the COMMON git dir: a linked worktree's own git dir is
# `.git/worktrees/<name>`, and git reads info/exclude from the common one.
spawn::team_git_exclude() {
    local repo="$1" root="$2" top common rel line
    top="$(spawn::team_toplevel "$repo")" || return 0
    case "$root" in
        "$top"/*) rel="${root#"$top"/}" ;;
        *) return 0 ;;
    esac
    common="$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null)" || return 0
    case "$common" in /*) : ;; *) common="$top/$common" ;; esac
    line="/$rel/"
    mkdir -p "$common/info" 2>/dev/null || return 0
    grep -qxF "$line" "$common/info/exclude" 2>/dev/null && return 0
    printf '\n# added by spawn: worktrees for a team run\n%s\n' "$line" \
        >> "$common/info/exclude" 2>/dev/null
    return 0
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
team.sh teardown --run-dir <dir>
team.sh --describe
USAGE
}

# Parallel indexed arrays, not a map: bash 3.2 has no associative array, and
# the roster's ORDER is meaningful anyway — U4 dispatches in roster order.
M_NAMES=(); M_ALIASES=(); M_CONTRACTS=(); M_SKILLS=(); M_WORKTREES=()

# The per-member flags attach to the most recent --member, so a member is
# declared and described in one place on the command line.
roster_parse() {
    local mode="attached" mc=2 mr=3 tc=0 last=-1
    MODE=""; MAX_CONC=""; MAX_ROUNDS=""; TOKEN_CEILING=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --run-id) RUN_ID="${2:-}"; shift 2 ;;
            --run-dir) RUN_DIR="${2:-}"; shift 2 ;;
            --mode) mode="${2:-}"; shift 2 ;;
            --max-concurrent) mc="${2:-}"; shift 2 ;;
            --max-rounds) mr="${2:-}"; shift 2 ;;
            --token-ceiling) tc="${2:-}"; shift 2 ;;
            --member)
                M_NAMES+=("${2:-}"); M_ALIASES+=(""); M_CONTRACTS+=("")
                M_SKILLS+=(""); M_WORKTREES+=("")
                last=$(( last + 1 )); shift 2 ;;
            --alias|--contract|--skill|--worktree)
                [ "$last" -ge 0 ] || { SPAWN_TEAM_ERROR="usage"
                    spawn::team_fail "$1 was given before any --member, so it belongs to nobody"; }
                case "$1" in
                    --alias) M_ALIASES[$last]="${2:-}" ;;
                    --contract) M_CONTRACTS[$last]="${2:-}" ;;
                    --worktree) M_WORKTREES[$last]="${2:-}" ;;
                    --skill) M_SKILLS[$last]="${M_SKILLS[$last]} ${2:-}" ;;
                esac
                shift 2 ;;
            *)
                usage
                SPAWN_TEAM_ERROR="usage"
                spawn::team_fail "unexpected argument: $1" ;;
        esac
    done
    MODE="$mode"; MAX_CONC="$mc"; MAX_ROUNDS="$mr"; TOKEN_CEILING="$tc"
    [ -n "$RUN_ID" ] || { SPAWN_TEAM_ERROR="usage"; spawn::team_fail "--run-id is required"; }
    spawn::team_name_ok "$RUN_ID" || { SPAWN_TEAM_ERROR="usage"
        spawn::team_fail "--run-id is a directory component and failed the grammar: $RUN_ID"; }
    [ "$last" -ge 0 ] || { SPAWN_TEAM_ERROR="usage"; spawn::team_fail "a team needs at least one --member"; }
}

# The driver's own checkout and where member worktrees belong. Both verbs that
# create anything resolve them the same way, before they create anything.
team_context() {
    DRIVER="$(spawn::team_toplevel .)" || { SPAWN_TEAM_ERROR="usage"
        spawn::team_fail "this is not a git checkout, and a member is placed relative to one"; }
    WT_ROOT="$(spawn::team_worktree_root "$DRIVER")" || { SPAWN_TEAM_ERROR="usage"
        spawn::team_fail "could not resolve where member worktrees belong"; }
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
            "${M_CONTRACTS[$i]}" "${M_SKILLS[$i]# }" \
            || spawn::team_fail "member '$name' could not be recorded"
        if [ -z "$worktree" ]; then
            TEAM_UNPLACED="$TEAM_UNPLACED $name"
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
          pending: ([ .members[] | select(.launch_state == "pending") ] | length),
          members: [ .members[] | {name, alias, worktree, launch_state, handle,
                                   skills, error: (if .launch_state == "launch_failed"
                                                   then "worktree_failed" else null end)} ]}')" \
        || { SPAWN_TEAM_ERROR="record_malformed"; spawn::team_fail "the roster could not be encoded"; }
    emit "$obj" || { SPAWN_TEAM_ERROR="record_malformed"; spawn::team_fail "the roster encoded to nothing"; }
    exit "$code"
}

# ---------------------------------------------------------------------------
# dispatch — one round, then exit (R1, R4, R5, R31, R33, KTD9, KTD17, KTD22)
# ---------------------------------------------------------------------------
TEAM_FILE=""
TEAM_FILE_COPY=""
TEAM_LAUNCH_ERRS='{}'
F_MODE=""; F_CONC=""; F_ROUNDS=""; F_CEILING=""

dispatch_parse() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --team-file) TEAM_FILE="${2:-}"; shift 2 ;;
            --run-id) RUN_ID="${2:-}"; shift 2 ;;
            --run-dir) RUN_DIR="${2:-}"; shift 2 ;;
            --mode) F_MODE="${2:-}"; shift 2 ;;
            --max-concurrent) F_CONC="${2:-}"; shift 2 ;;
            --max-rounds) F_ROUNDS="${2:-}"; shift 2 ;;
            --token-ceiling) F_CEILING="${2:-}"; shift 2 ;;
            *)
                usage
                SPAWN_TEAM_ERROR="usage"
                spawn::team_fail "unexpected argument: $1" ;;
        esac
    done
    [ -n "$TEAM_FILE" ] || { SPAWN_TEAM_ERROR="usage"
        spawn::team_fail "--team-file is required: the team is stated in one file the caller writes"; }
}

# A whole number, or the caller is told which bound they wrote wrong.
team_bound_ok() {   # <flag-name> <value>
    case "$2" in
        ''|*[!0-9]*) SPAWN_TEAM_ERROR="usage"
            spawn::team_fail "$1 takes a whole number of members, rounds or tokens, and was given '$2'" ;;
    esac
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
    if jq -e 'any(.members[]; ((.alias // "") == "") or ((.contract // "") == ""))' "$f" >/dev/null 2>&1; then
        SPAWN_TEAM_ERROR="member_incomplete"
        spawn::team_fail "a member in $f has no alias or no contract"
    fi

    MODE="$(jq -r '.mode // "attached"' "$f" 2>/dev/null)"
    MAX_CONC="$(jq -r '.bounds.max_concurrent // empty' "$f" 2>/dev/null)"
    MAX_ROUNDS="$(jq -r '.bounds.max_rounds // empty' "$f" 2>/dev/null)"
    TOKEN_CEILING="$(jq -r '.bounds.token_ceiling // empty' "$f" 2>/dev/null)"
    [ -n "$F_MODE" ] && MODE="$F_MODE"
    [ -n "$F_CONC" ] && MAX_CONC="$F_CONC"
    [ -n "$F_ROUNDS" ] && MAX_ROUNDS="$F_ROUNDS"
    [ -n "$F_CEILING" ] && TOKEN_CEILING="$F_CEILING"
    # KTD9 — the bound is the caller's. These are the values a team file that
    # states none inherits, not a limit compiled into the surface.
    [ -n "$MAX_CONC" ] || MAX_CONC=2
    [ -n "$MAX_ROUNDS" ] || MAX_ROUNDS=3
    [ -n "$TOKEN_CEILING" ] || TOKEN_CEILING=0
    team_bound_ok --max-concurrent "$MAX_CONC"
    team_bound_ok --max-rounds "$MAX_ROUNDS"
    team_bound_ok --token-ceiling "$TOKEN_CEILING"
    [ "$MAX_CONC" -gt 0 ] || { SPAWN_TEAM_ERROR="usage"
        spawn::team_fail "--max-concurrent 0 would dispatch nobody and report a round"; }

    while IFS='	' read -r name alias contract skills; do
        spawn::team_name_ok "$name" || { SPAWN_TEAM_ERROR="member_name_invalid"
            spawn::team_fail "member name failed the grammar: $name"; }
        case " $seen " in
            *" $name "*) SPAWN_TEAM_ERROR="member_duplicate"
                spawn::team_fail "two members in $f are named '$name'" ;;
        esac
        seen="$seen $name"
        M_NAMES+=("$name"); M_ALIASES+=("$alias"); M_CONTRACTS+=("$contract")
        M_SKILLS+=("$skills"); M_WORKTREES+=("")
    done < <(jq -r '.members[] | [.name, .alias, .contract,
                                 ((.skills // []) | join(" "))] | @tsv' "$f" 2>/dev/null)
    [ "${#M_NAMES[@]}" -gt 0 ] || { SPAWN_TEAM_ERROR="team_file_malformed"
        spawn::team_fail "no member in $f could be read as a name, an alias and a contract"; }
}

# One attempt, one member. bg-agent's stdout is CAPTURED: it answers with its
# own JSON object, and stdout here belongs to this surface's one object.
# Returns 0 when the member is dispatched — the caller counts those against the
# concurrency maximum, so a refused launch never spends a slot it is not using.
team_launch_member() {  # <index> <round>
    local i="$1" round="$2" name="${M_NAMES[$i]}" out rc handle err s
    local args=()
    for s in ${M_SKILLS[$i]}; do args+=(--skill "$s"); done
    out="$(bash "$BG_AGENT" --alias "${M_ALIASES[$i]}" --contract "${M_CONTRACTS[$i]}" \
        --cwd "${M_WORKTREES[$i]}" ${args[@]+"${args[@]}"} 2>/dev/null)"
    rc=$?
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
    spawn::team_member_set "$RUN_DIR" "$name" launch_state launch_failed \
        || spawn::team_fail "member '$name' failed to launch and could not be marked launch_failed"
    TEAM_LAUNCH_ERRS="$(printf '%s' "$TEAM_LAUNCH_ERRS" | jq -c --arg n "$name" --arg e "$err" '.[$n] = $e')"
    say "team: member '$name' was not launched: $err"
    return 1
}

do_dispatch() {
    need_jq
    dispatch_parse "$@"
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
        fi
        i=$(( i + 1 ))
    done

    # KTD17 — nothing is awaited. Every member dispatched above is running
    # behind its own detached supervisor, and this process is done with them.
    local rec obj err="null" rem="null" code=0 bad
    rec="$(spawn::team_record_read "$RUN_DIR")" || spawn::team_fail "the run record could not be read back"
    bad="$(printf '%s' "$TEAM_LAUNCH_ERRS" | jq -r 'keys | join(" ")')"
    if [ -n "$bad" ]; then
        err='"launch_failed"'; code="$EX_UPSTREAM"
        rem="$(remedy_for launch_failed)"
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
          pending: ([ .members[] | select(.launch_state == "pending") ] | length),
          members: [ .members[] | {name, alias, worktree, launch_state, handle,
                                   skills, error: ($le[.name] // null)} ]}')" \
        || { SPAWN_TEAM_ERROR="record_malformed"; spawn::team_fail "the round could not be encoded"; }
    emit "$obj" || { SPAWN_TEAM_ERROR="record_malformed"; spawn::team_fail "the round encoded to nothing"; }
    exit "$code"
}

do_teardown() {
    need_jq
    while [ $# -gt 0 ]; do
        case "$1" in
            --run-dir) RUN_DIR="${2:-}"; shift 2 ;;
            *) usage; SPAWN_TEAM_ERROR="usage"; spawn::team_fail "unexpected argument: $1" ;;
        esac
    done
    [ -n "$RUN_DIR" ] || { SPAWN_TEAM_ERROR="usage"; spawn::team_fail "--run-dir is required"; }

    local rec removed obj
    rec="$(spawn::team_record_read "$RUN_DIR")" \
        || spawn::team_fail "no readable run record at $RUN_DIR"
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
        {name:"teardown", note:"remove the worktrees the run record names, and only those"}
      ],
      flags:[
        {name:"--team-file",      value:"file", required:true,  default:null, note:"the team, as one JSON object; copied into the run directory at dispatch so a later edit cannot move the target"},
        {name:"--run-id",         value:"id",   required:false, default:"the team file’s run_id, or a minted one", note:"names the run; every verb after dispatch takes this instead of re-stating the team"},
        {name:"--run-dir",        value:"dir",  required:false, default:"<checkout>/.spawn/teams/<run-id>", note:"where the one run record lives"},
        {name:"--mode",           value:"name", required:false, default:"the team file’s mode, else attached", note:"single-round | attached | unattended; single-round refuses a roster larger than the concurrency maximum, because it arms nothing that could advance the remainder"},
        {name:"--max-concurrent", value:"N",    required:false, default:2, note:"members dispatched in one round; a larger roster CLAMPS and the rest stay pending for the next round. Overrides the team file"},
        {name:"--max-rounds",     value:"N",    required:false, default:3, note:"rounds this run may open. Overrides the team file"},
        {name:"--token-ceiling",  value:"N",    required:false, default:0, note:"tokens the run may spend, 0 for none. Overrides the team file"},
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
        "A roster larger than the concurrency maximum is not an error outside single-round mode. The extra members stay pending and the response says how many."
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
        teardown) do_teardown "$@" ;;
        --describe) do_describe ;;
        -h|--help)
            HELP_REQUESTED=true
            usage
            SPAWN_TEAM_ERROR="usage"
            spawn::team_fail "no verb given: this surface answers 'roster', 'dispatch' and 'teardown'" ;;
        *)
            usage
            SPAWN_TEAM_ERROR="usage"
            spawn::team_fail "unknown verb — this surface answers 'roster', 'dispatch' and 'teardown'" ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
