#!/usr/bin/env bash
# Worktree and branch removal (KTD12). Sourced, never executed.
#
# The only destructive verb the board has. A worktree goes only when it is
# clean, delivered and unused, and only on a person's answer to a pending
# remove-worktree question: the verb applies that answer itself through U5's
# nonce and precondition check, so a caller cannot skip it. Banned from hooks.

command -v herdr_linear::_resolve >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/contain.sh"
command -v herdr_linear::board_question_answer >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/board-store.sh"

HERDR_LINEAR_REMOVE_OK=0
HERDR_LINEAR_REMOVE_KEPT=1
HERDR_LINEAR_REMOVE_REFUSED=2
HERDR_LINEAR_REMOVE_FAILED=3

HERDR_LINEAR_REMOVE_KIND=remove-worktree
# Ignored directories a build or install recreates. Any other ignored entry (a
# local .env, notes, a scratch database) keeps the worktree: git status does not
# show ignored files, and git worktree remove deletes them without asking.
HERDR_LINEAR_REMOVE_REGENERABLE="node_modules/ dist/ build/ .next/ target/ .venv/ __pycache__/ coverage/"

herdr_linear::_rm_git() { "${HERDR_LINEAR_GIT_BIN:-git}" -C "$1" --no-optional-locks "${@:2}" 2>/dev/null; }

herdr_linear::_rm_refuse() {
    printf 'refused: %s\n' "$1" >&2
    return "$HERDR_LINEAR_REMOVE_REFUSED"
}

herdr_linear::_rm_keep() {
    printf 'kept: %s\n' "$1" >&2
    return "$HERDR_LINEAR_REMOVE_KEPT"
}

# Prints the resolved worktree path, or refuses.
herdr_linear::_rm_target() {
    local path="${1:-}" resolved root top gitdir common usable
    usable="$(herdr_linear::worktrees_root_usable)"
    [ "$usable" = usable ] || { herdr_linear::_rm_refuse "$usable"; return; }
    resolved="$(herdr_linear::_resolve "$path")" \
        || { herdr_linear::_rm_refuse "that path is not a directory"; return; }
    root="$(herdr_linear::_resolve "$(herdr_linear::worktrees_root)")" \
        || { herdr_linear::_rm_refuse "the worktrees root does not exist"; return; }
    case "$resolved" in
        "$root"/*) ;;
        *) herdr_linear::_rm_refuse "that path is not inside the worktrees root ($root)"; return ;;
    esac
    top="$(herdr_linear::_rm_git "$resolved" rev-parse --show-toplevel)" \
        || { herdr_linear::_rm_refuse "that path is not a git worktree"; return; }
    top="$(herdr_linear::_resolve "$top")" || { herdr_linear::_rm_refuse "that path is not a git worktree"; return; }
    [ "$top" = "$resolved" ] \
        || { herdr_linear::_rm_refuse "that path is inside a worktree, not the worktree itself"; return; }
    gitdir="$(herdr_linear::_rm_git "$resolved" rev-parse --path-format=absolute --git-dir)"
    common="$(herdr_linear::_rm_git "$resolved" rev-parse --path-format=absolute --git-common-dir)"
    [ -n "$gitdir" ] && [ -n "$common" ] \
        || { herdr_linear::_rm_refuse "the repository of that worktree cannot be read"; return; }
    [ "$gitdir" != "$common" ] \
        || { herdr_linear::_rm_refuse "that path is a main checkout, not a linked worktree"; return; }
    printf '%s' "$resolved"
}

# herdr_linear::worktree_remove_key <worktree> -> the pending question key.
herdr_linear::worktree_remove_key() {
    local resolved
    resolved="$(herdr_linear::_rm_target "${1:-}")" || return
    printf 'remove-worktree-%s' "$(printf '%s' "$resolved" | shasum | cut -c1-16)"
}

# herdr_linear::worktree_remove_preconditions <worktree> -> canonical JSON.
herdr_linear::worktree_remove_preconditions() {
    local resolved branch head
    resolved="$(herdr_linear::_rm_target "${1:-}")" || return
    branch="$(herdr_linear::_rm_git "$resolved" symbolic-ref --quiet --short HEAD)" || branch=""
    head="$(herdr_linear::_rm_git "$resolved" rev-parse --verify HEAD)" \
        || { herdr_linear::_rm_refuse "that worktree has no commit to read"; return; }
    HL_WT="$resolved" HL_BRANCH="$branch" HL_HEAD="$head" python3 -c '
import json, os
print(json.dumps({"worktree": os.environ["HL_WT"], "branch": os.environ["HL_BRANCH"],
                  "head": os.environ["HL_HEAD"]}, sort_keys=True, separators=(",", ":")), end="")'
}

# herdr_linear::worktree_remove_propose <worktree> -> prints the nonce.
herdr_linear::worktree_remove_propose() {
    local key pre
    key="$(herdr_linear::worktree_remove_key "${1:-}")" || return
    pre="$(herdr_linear::worktree_remove_preconditions "${1:-}")" || return
    herdr_linear::board_question_propose "$key" "$HERDR_LINEAR_REMOVE_KIND" "$pre"
}

# herdr_linear::_rm_delivered <dir> <commit> <branch> -> 0 when delivered.
# Prints why not. Remote-tracking refs are not trusted: a branch deleted on the
# remote without merging still has its stale tracking ref locally, and reading
# that as delivered loses every commit on it. Only a live ls-remote counts.
herdr_linear::_rm_delivered() {
    local dir="$1" commit="$2" branch="$3" remote refs sha unreachable="" state="" head=""
    for remote in $(herdr_linear::_rm_git "$dir" remote); do
        if ! refs="$(herdr_linear::_rm_git "$dir" ls-remote --heads --tags "$remote")"; then
            unreachable="$unreachable $remote"
            continue
        fi
        while read -r sha _; do
            [ -n "$sha" ] || continue
            herdr_linear::_rm_git "$dir" merge-base --is-ancestor "$commit" "$sha" && return 0
        done <<<"$refs"
    done

    if [ -n "$branch" ] && command -v "${HERDR_LINEAR_GH_BIN:-gh}" >/dev/null 2>&1; then
        read -r state head < <(cd "$dir" 2>/dev/null \
            && "${HERDR_LINEAR_GH_BIN:-gh}" pr view "$branch" --json state,headRefOid \
                -q '.state + " " + .headRefOid' 2>/dev/null)
        # A squash merge leaves no ancestor on any remote, so the pull request's
        # recorded head stands in for it; a commit made after the merge is not
        # under that head and is not delivered.
        if [ "$state" = MERGED ] && [ -n "$head" ] \
            && { [ "$head" = "$commit" ] || herdr_linear::_rm_git "$dir" merge-base --is-ancestor "$commit" "$head"; }; then
            return 0
        fi
    fi

    if [ -n "$unreachable" ]; then
        printf 'its commits are on no reachable remote (could not reach:%s) and in no merged pull request' "$unreachable"
    else
        printf 'its commits are on no remote and in no merged pull request'
    fi
    return 1
}

# herdr_linear::_rm_in_use <resolved-worktree> -> 0 when a process is inside it,
# printing which. A process whose working directory cannot be resolved counts,
# and so does a lister that fails: either could be the one inside.
herdr_linear::_rm_in_use() {
    local wt="$1" out line pid="" have_path=1 cwd resolved
    out="$("${HERDR_LINEAR_LSOF_BIN:-lsof}" -d cwd -Fpn 2>/dev/null)" || {
        printf 'the process list could not be read'
        return 0
    }
    [ -n "$out" ] || { printf 'the process list could not be read'; return 0; }
    while IFS= read -r line; do
        case "$line" in
            p*)
                if [ -n "$pid" ] && [ "$have_path" -eq 0 ]; then
                    printf 'process %s has a working directory that cannot be resolved' "$pid"
                    return 0
                fi
                pid="${line#p}"; have_path=0 ;;
            n*)
                have_path=1
                cwd="${line#n}"
                resolved="$(herdr_linear::_resolve "$cwd")" || {
                    printf 'process %s has a working directory that cannot be resolved' "$pid"
                    return 0
                }
                if herdr_linear::_under "$resolved" "$wt"; then
                    printf 'process %s is running inside it' "$pid"
                    return 0
                fi ;;
        esac
    done <<<"$out"
    if [ -n "$pid" ] && [ "$have_path" -eq 0 ]; then
        printf 'process %s has a working directory that cannot be resolved' "$pid"
        return 0
    fi
    return 1
}

# herdr_linear::worktree_remove <worktree> <nonce>
# 0 removed (stdout says whether the branch went too); 1 kept, reason on stderr;
# 2 refused; 3 git could not remove it.
herdr_linear::worktree_remove() {
    local path="${1:-}" nonce="${2:-}" resolved key pre branch head main dirty ignored why rc
    resolved="$(herdr_linear::_rm_target "$path")" || return
    [ -n "$nonce" ] || { herdr_linear::_rm_refuse "removing a worktree needs the nonce of an answered question"; return; }
    key="$(herdr_linear::worktree_remove_key "$resolved")" || return
    pre="$(herdr_linear::worktree_remove_preconditions "$resolved")" || return

    local q kind
    q="$(herdr_linear::board_question "$key" 2>/dev/null)" \
        || { herdr_linear::_rm_refuse "there is no pending question to remove this worktree"; return; }
    kind="$(HL_Q="$q" python3 -c 'import json,os; print(json.loads(os.environ["HL_Q"]).get("kind",""), end="")' 2>/dev/null)"
    [ "$kind" = "$HERDR_LINEAR_REMOVE_KIND" ] \
        || { herdr_linear::_rm_refuse "the pending question for this worktree is not a removal question"; return; }
    herdr_linear::board_question_answer "$key" "$nonce" "$pre" || {
        rc=$?
        [ "$rc" -eq "$HERDR_LINEAR_BOARD_LOCKED" ] && return "$HERDR_LINEAR_REMOVE_FAILED"
        herdr_linear::_rm_refuse "the removal question was not answered with this nonce and these preconditions"
        return
    }

    branch="$(printf '%s' "$pre" | python3 -c 'import json,sys; print(json.load(sys.stdin)["branch"], end="")')"
    head="$(printf '%s' "$pre" | python3 -c 'import json,sys; print(json.load(sys.stdin)["head"], end="")')"

    dirty="$(herdr_linear::_rm_git "$resolved" status --porcelain --untracked-files=all)" \
        || { herdr_linear::_rm_keep "its status cannot be read"; return; }
    [ -z "$dirty" ] || { herdr_linear::_rm_keep "it has uncommitted changes"; return; }
    ignored="$(herdr_linear::_rm_git "$resolved" ls-files --others --ignored --exclude-standard --directory)" \
        || { herdr_linear::_rm_keep "its ignored files cannot be listed"; return; }
    ignored="$(printf '%s\n' "$ignored" | HL_KEEP="$HERDR_LINEAR_REMOVE_REGENERABLE" python3 -c '
import os, sys
keep = os.environ["HL_KEEP"].split()
left = [l for l in sys.stdin.read().splitlines() if l and not any(l == k or l.startswith(k) or ("/" + k) in ("/" + l) for k in keep)]
print(", ".join(left[:3]) + (" and %d more" % (len(left) - 3) if len(left) > 3 else ""), end="")')"
    [ -z "$ignored" ] || { herdr_linear::_rm_keep "it holds ignored local files git would delete: $ignored"; return; }
    why="$(herdr_linear::_rm_delivered "$resolved" "$head" "$branch")" \
        || { herdr_linear::_rm_keep "$why"; return; }
    why="$(herdr_linear::_rm_in_use "$resolved")" && { herdr_linear::_rm_keep "$why"; return; }

    main="$(herdr_linear::_rm_git "$resolved" rev-parse --path-format=absolute --git-common-dir)"
    main="${main%/.git}"
    herdr_linear::_rm_git "$main" worktree remove "$resolved" || {
        printf 'failed: git would not remove the worktree\n' >&2
        return "$HERDR_LINEAR_REMOVE_FAILED"
    }

    if [ -z "$branch" ]; then
        printf 'removed the worktree; it had no branch\n'
        return 0
    fi
    head="$(herdr_linear::_rm_git "$main" rev-parse --verify "refs/heads/$branch")" || {
        printf 'removed the worktree; branch %s was already gone\n' "$branch"
        return 0
    }
    if why="$(herdr_linear::_rm_delivered "$main" "$head" "$branch")" \
        && herdr_linear::_rm_git "$main" branch -D "$branch" >/dev/null; then
        printf 'removed the worktree and branch %s\n' "$branch"
    else
        printf 'removed the worktree; kept branch %s: %s\n' "$branch" "${why:-git would not delete it}"
    fi
    return 0
}
