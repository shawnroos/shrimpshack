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
    # One resolver, not two. This derived the absolute common dir with its own
    # copy of spawn::team_common_dir's normalization, and that normalization is
    # what teardown's path-shape guard resolves against — a guard a mutation
    # already proved could delete another repository's `.git`. Two copies of the
    # rule that decides what a path IS, one of them load-bearing for deletion,
    # is the drift worth removing.
    local common primary
    common="$(spawn::team_common_dir "${1:-.}")" || return 1
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
# The returned path is default-denied to `<common>/worktrees/<id>`, AND the
# registration must point back at the worktree being torn down.
#
# THE SHAPE ALONE IS NOT ENOUGH, and this is the second time this guard has been
# reached from an angle it did not cover. `git rev-parse --git-dir` reads the
# member's own `.git`, which in a linked worktree is a FILE holding one line —
# `gitdir: <path>` — and a running member can write to its own checkout. The
# first route pointed that line at another REPOSITORY's main `.git`; the shape
# check refuses it, because there `common` and `admin` are the same directory.
# It does NOT refuse a SIBLING LINKED WORKTREE's registration, which has exactly
# the sanctioned shape — so a member could name another live session's worktree
# and have teardown deregister it, killing a checkout this run never created.
# Measured on a throwaway repo: the victim's index, HEAD, refs and reflog were
# removed and its `git status` became "not a repository".
#
# So the answer is not trusted for WHICH worktree it belongs to. Git writes a
# `gitdir` file inside the registration pointing back at the checkout's `.git`;
# that file lives under the common git dir, where the ceiling denies the member
# write access. Requiring it to point back at the worktree we are tearing down
# makes the member's own `.git` unable to choose the target.
spawn::team_admin_dir() {
    local wt="$1" common admin back back_wt real_wt
    common="$(spawn::team_common_dir "$wt")" || return 1
    admin="$(cd "$wt" 2>/dev/null && git rev-parse --git-dir 2>/dev/null)" || return 1
    case "$admin" in /*) : ;; *) admin="$wt/$admin" ;; esac
    case "$admin" in
        "$common"/worktrees/?*) : ;;
        *) return 1 ;;
    esac
    # BOTH sides are resolved before comparing. git writes the physical path
    # into `gitdir`, and a caller may hold a logical one — on macOS /var is a
    # symlink to /private/var, so an unresolved comparison refuses the honest
    # case while still refusing the hostile one, which reads as "the guard
    # works" and silently disables teardown.
    back="$(cat "$admin/gitdir" 2>/dev/null)" || return 1
    back_wt="${back%/.git}"
    [ "$back_wt" != "$back" ] || return 1
    back_wt="$(cd "$back_wt" 2>/dev/null && pwd -P)" || return 1
    real_wt="$(cd "$wt" 2>/dev/null && pwd -P)" || return 1
    [ "$back_wt" = "$real_wt" ] || return 1
    printf '%s' "$admin"
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
team.sh advance  --run-id <id> | --run-dir <dir>
team.sh status   --run-id <id> | --run-dir <dir>
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
                M_SKILLS+=(""); M_WORKTREES+=("")
                last=$(( last + 1 )); shift 2 || shift ;;
            --alias|--contract|--skill|--worktree)
                [ "$last" -ge 0 ] || { SPAWN_TEAM_ERROR="usage"
                    spawn::team_fail "$1 was given before any --member, so it belongs to nobody"; }
                case "$1" in
                    --alias) M_ALIASES[$last]="${2:-}" ;;
                    --contract) M_CONTRACTS[$last]="${2:-}" ;;
                    --worktree) M_WORKTREES[$last]="${2:-}" ;;
                    --skill) M_SKILLS[$last]="${M_SKILLS[$last]} ${2:-}" ;;
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
    # The round is recorded BEFORE the state, and on this path as much as on the
    # success path above: a member whose launch was ATTEMPTED in round N belongs
    # to round N. Left null, a round whose launches ALL failed has no assigned
    # members at all, and the chokepoint's round tally — which needs at least
    # one member before it will call a round finished — holds it `running` for
    # ever. The advance then answers `waiting` on a round nothing can finish.
    spawn::team_member_set "$RUN_DIR" "$name" round "$round" \
        || spawn::team_fail "member '$name' failed to launch and its round could not be recorded"
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
    local fields n
    M_NAMES=(); M_ALIASES=(); M_CONTRACTS=(); M_SKILLS=(); M_WORKTREES=()
    fields="$(printf '%s' "$rec" | jq -r '.members[] | select(.launch_state == "pending")
        | (.name, .alias, .contract, ((.skills // []) | join(" ")), .worktree)' 2>/dev/null)"
    n=0
    while IFS= read -r name; do
        IFS= read -r alias || break
        IFS= read -r contract || break
        IFS= read -r skills || break
        IFS= read -r worktree || break
        [ -n "$name" ] || continue
        M_NAMES+=("$name"); M_ALIASES+=("$alias"); M_CONTRACTS+=("$contract")
        M_SKILLS+=("$skills"); M_WORKTREES+=("$worktree")
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
        do_dispatch_round skip-placement
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

    do_dispatch_round
}

# The half both rounds share: place whatever is unplaced, open a round, launch
# up to the concurrency maximum, and report without waiting. Round 1 arrives
# here after the record is created and the team file copied; round N+1 arrives
# with the roster read back out of the record.
do_dispatch_round() {   # [skip-placement]
    if [ "${1:-}" != "skip-placement" ]; then
        spawn::team_git_exclude "$DRIVER" "$WT_ROOT"
        team_place_members "$RUN_DIR"
    else
        # Round N+1: the rows and the checkouts already exist. A member whose
        # recorded worktree has since gone is treated exactly as an unplaced one
        # rather than silently launched with an empty --cwd, which bg-agent
        # reads as the CALLING process's directory.
        local j=0
        TEAM_UNPLACED=""
        while [ "$j" -lt "${#M_NAMES[@]}" ]; do
            if [ -z "${M_WORKTREES[$j]}" ] || [ ! -d "${M_WORKTREES[$j]}" ]; then
                M_WORKTREES[$j]=""
                TEAM_UNPLACED="$TEAM_UNPLACED ${M_NAMES[$j]}"
                spawn::team_member_set "$RUN_DIR" "${M_NAMES[$j]}" launch_state launch_failed \
                    || spawn::team_fail "member '${M_NAMES[$j]}' could not be marked launch_failed"
            fi
            j=$(( j + 1 ))
        done
    fi

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
          pending: ([ .members[] | select(.launch_state == "pending") ] | length),
          members: [ .members[] | {name, alias, worktree, launch_state, handle,
                                   skills, error: ($le[.name] // null)} ]}')" \
        || { SPAWN_TEAM_ERROR="record_malformed"; spawn::team_fail "the round could not be encoded"; }
    emit "$obj" || { SPAWN_TEAM_ERROR="record_malformed"; spawn::team_fail "the round encoded to nothing"; }
    exit "$code"
}

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
