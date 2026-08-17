#!/usr/bin/env bash
# The git-worktree lifecycle for a team run: where a member's checkout goes, how it is created, and how it is removed.
#
# THIS FILE OWNS THE DELETION PATH, which is why it is its own file. Every guard here was earned: a repository-wide `git worktree prune` that deregistered a sibling this run never touched, a `.git` FILE a running member can rewrite to name another repository, and the same trick aimed at another live worktree's registration. Read the comments at spawn::team_admin_dir and spawn::team_teardown before changing either — both document measurements, not opinions.
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
    # ONE FIELD PER LINE. This is the function that DELETES directories, and it
    # was the last place still reading @tsv into `read`: tab is IFS whitespace,
    # so a run of tabs collapses and a member with an empty name or worktree
    # shifts the pair — the next member's name arriving as this one's worktree.
    # It was safe only because the `[ -n "$wt" ]` guard below happened to absorb
    # the shifted case, and safe-by-accident is the wrong property for the one
    # loop whose next step resolves a path for removal. The same trap is
    # documented twice elsewhere in this file.
    while IFS= read -r name; do
        IFS= read -r wt || break
        [ -n "$name" ] || continue
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
    done < <(printf '%s' "$rec" | jq -r '.members[] | (.name, (.worktree // ""))')
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
