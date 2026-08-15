#!/usr/bin/env bash
# team.sh — the team surface: a roster of named members, each in its own git
# worktree, and a teardown that removes exactly what the record names.
#
#   team.sh roster   --run-id <id> --member <name> --alias <a> --contract <c>
#                    [--skill <s>]... [--worktree <path>] [--member ...]
#   team.sh teardown --run-dir <dir>
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
        *) spawn::remedy_for "$1" ;;
    esac
}

# Null-valued data fields, so all three encoder tiers describe the same shape.
emit_error() { spawn::emit_error plugin "run_id run_dir members removed" "$@"; }

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
        worktree_failed) printf '%s' "$EX_UPSTREAM" ;;
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
team.sh teardown --run-dir <dir>
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

do_roster() {
    need_jq
    roster_parse "$@"

    local driver root i name failed="" worktree
    driver="$(spawn::team_toplevel .)" || { SPAWN_TEAM_ERROR="usage"
        spawn::team_fail "this is not a git checkout, and a member is placed relative to one"; }
    root="$(spawn::team_worktree_root "$driver")" || { SPAWN_TEAM_ERROR="usage"
        spawn::team_fail "could not resolve where member worktrees belong"; }
    [ -n "$RUN_DIR" ] || RUN_DIR="$driver/.spawn/teams/$RUN_ID"

    i=0
    while [ "$i" -lt "${#M_NAMES[@]}" ]; do
        name="${M_NAMES[$i]}"
        spawn::team_name_ok "$name" || { SPAWN_TEAM_ERROR="member_name_invalid"
            spawn::team_fail "member name failed the grammar: $name"; }
        # R3, checked BEFORE anything is created: an explicit placement that
        # resolves to the driver's own toplevel is refused, not relocated.
        worktree="${M_WORKTREES[$i]}"
        if [ -n "$worktree" ] && [ -d "$worktree" ]; then
            if [ "$(spawn::team_toplevel "$worktree" 2>/dev/null)" = "$driver" ]; then
                SPAWN_TEAM_ERROR="driver_worktree"
                spawn::team_fail "member '$name' was placed in the driver's own worktree: $driver"
            fi
        fi
        i=$(( i + 1 ))
    done

    spawn::team_record_new "$RUN_DIR" "$RUN_ID" "$MODE" "$MAX_CONC" "$MAX_ROUNDS" "$TOKEN_CEILING" \
        || spawn::team_fail "the run record for $RUN_ID could not be created"
    spawn::team_git_exclude "$driver" "$root"

    i=0
    while [ "$i" -lt "${#M_NAMES[@]}" ]; do
        name="${M_NAMES[$i]}"
        worktree="${M_WORKTREES[$i]}"
        if [ -z "$worktree" ]; then
            worktree="$(spawn::team_worktree_create "$driver" "$root" "$RUN_ID" "$name")" || worktree=""
        elif ! spawn::team_worktree_create "$driver" "$root" "$RUN_ID" "$name" "$worktree" >/dev/null; then
            worktree=""
        fi
        # The row is written whatever happened, and it is written `pending` with
        # a null handle: a handle does not exist until U4's launcher returns
        # one, and a launch can fail without ever producing one.
        spawn::team_member_add "$RUN_DIR" "$name" "${M_ALIASES[$i]}" "$worktree" \
            "${M_CONTRACTS[$i]}" "${M_SKILLS[$i]# }" \
            || spawn::team_fail "member '$name' could not be recorded"
        if [ -z "$worktree" ]; then
            failed="$failed $name"
            spawn::team_member_set "$RUN_DIR" "$name" launch_state launch_failed \
                || spawn::team_fail "member '$name' could not be marked launch_failed"
        fi
        i=$(( i + 1 ))
    done

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
          run_id: $id, run_dir: $d, removed: null,
          members: [ .members[] | {name, alias, worktree, launch_state, handle,
                                   skills, error: (if .launch_state == "launch_failed"
                                                   then "worktree_failed" else null end)} ]}')" \
        || { SPAWN_TEAM_ERROR="record_malformed"; spawn::team_fail "the roster could not be encoded"; }
    emit "$obj" || { SPAWN_TEAM_ERROR="record_malformed"; spawn::team_fail "the roster encoded to nothing"; }
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

main() {
    local verb="${1:-}"
    [ $# -gt 0 ] && shift
    case "$verb" in
        roster) do_roster "$@" ;;
        teardown) do_teardown "$@" ;;
        -h|--help)
            HELP_REQUESTED=true
            usage
            SPAWN_TEAM_ERROR="usage"
            spawn::team_fail "no verb given: this surface answers 'roster' and 'teardown'" ;;
        *)
            usage
            SPAWN_TEAM_ERROR="usage"
            spawn::team_fail "unknown verb — this surface answers 'roster' and 'teardown'" ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
