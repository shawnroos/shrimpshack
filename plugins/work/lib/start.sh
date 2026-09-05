#!/usr/bin/env bash
# Starting work: from a ticket, or from nothing. Sourced, never executed.
#
# THE GAP THIS FILLS. Binding assumed a worktree already existed, which covers
# one row of a two-by-two and not the common one:
#
#                  ticket exists        no ticket
#   worktree       bind (U7)            create the issue from position (U7)
#   no worktree    START FROM TICKET    START FROM NOTHING
#
# The bottom row is how work usually begins -- you pick something off the board,
# or you have an idea -- and neither had a path.
#
# STARTING FROM A TICKET WRITES NOTHING TO LINEAR. It reads the issue, creates a
# local worktree, and records a local binding. That matters: it works before the
# credential rotation and before any worktree is in the write allowlist, so the
# common motion is available immediately and cannot damage a board.
#
# BINDING ON CREATION IS NOT A GUESS. You named the ticket; that IS the
# confirmation, and the skill carrying it cannot be invoked by the model. Same
# reasoning as U10: the act of creating the worktree from an issue is the
# statement of what it is for.

HERDR_LINEAR_BRANCH_PREFIX="${HERDR_LINEAR_BRANCH_PREFIX:-feature}"

HERDR_LINEAR_START_OK=0
HERDR_LINEAR_START_REFUSED=1
HERDR_LINEAR_START_EXISTS=2
HERDR_LINEAR_START_UNAVAILABLE=3
HERDR_LINEAR_START_FAILED=4

# Linear supplies a branch name per issue -- `web-3318-ai-tools-drawer-is-blank`.
# Prefixing it with the repository's own convention gives a branch that carries
# the identifier, so branch matching finds this worktree forever after. Most
# branches here do NOT carry one (`feat/single-command-router`), which is why
# matching reached under a fifth of worktrees; every worktree started this way
# is self-identifying by construction.
herdr_linear::start_branch_name() {
    local resp="$1" prefix="${2:-$HERDR_LINEAR_BRANCH_PREFIX}" bn
    bn="$(printf '%s' "$resp" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["issue"].get("branchName") or "")' 2>/dev/null)"
    [ -n "$bn" ] || return 1
    # Linear's own value is already slug-shaped, but it is still tracker-supplied
    # text on its way to becoming a branch and a path.
    bn="$(herdr_linear::slug "$bn" 80)" || return 1
    printf '%s/%s' "$prefix" "$bn"
}

# A short, human directory name -- `cue-read`, `wcs-paper` -- not the full
# ticket slug. That is what every worktree here is called.
herdr_linear::start_default_name() {
    local resp="$1" title
    title="$(printf '%s' "$resp" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["issue"].get("title") or "")' 2>/dev/null)"
    [ -n "$title" ] || return 1
    printf '%s' "$title" \
        | tr '[:upper:]' '[:lower:]' \
        | tr -c 'a-z0-9' '-' \
        | sed -E 's/-+/-/g; s/^-+//; s/-+$//' \
        | cut -c1-40 \
        | sed -E 's/-[^-]*$//; s/-+$//'
}

herdr_linear::_worktree_root() { printf '%s/worktrees' "$(herdr_linear::slate_root)"; }

# herdr_linear::start_from_issue <identifier> [worktree-name] [branch-prefix]
#
# Prints the worktree path on success.
herdr_linear::start_from_issue() {
    local ident="${1:-}" name="${2:-}" prefix="${3:-$HERDR_LINEAR_BRANCH_PREFIX}"
    local resp branch path root nonce

    [ -n "$ident" ] || return "$HERDR_LINEAR_START_REFUSED"

    # The issue must exist. A worktree created for a typo'd identifier is worse
    # than a refusal: it looks like work and is bound to nothing.
    resp="$(herdr_linear::fetch_issue "$ident")"
    case $? in
        0) ;;
        2) printf 'no such issue: %s\n' "$ident" >&2; return "$HERDR_LINEAR_START_REFUSED" ;;
        *) return "$HERDR_LINEAR_START_UNAVAILABLE" ;;
    esac

    branch="$(herdr_linear::start_branch_name "$resp" "$prefix")" || return "$HERDR_LINEAR_START_FAILED"
    [ -n "$name" ] || name="$(herdr_linear::start_default_name "$resp")" || return "$HERDR_LINEAR_START_FAILED"
    name="$(herdr_linear::slug "$name" 60)" || return "$HERDR_LINEAR_START_REFUSED"

    root="$(herdr_linear::_worktree_root)"
    path="$root/$name"

    # Never adopt a directory that is already there. It may be someone's live
    # work, and binding it to this issue would silently re-home it.
    if [ -e "$path" ]; then
        printf 'already exists: %s\n' "$path" >&2
        return "$HERDR_LINEAR_START_EXISTS"
    fi

    # The directory has to exist before it can be resolved: contains() only
    # accepts a real directory, deliberately, so that a symlink to a file or a
    # dangling link cannot pass. Creating the worktrees root first and checking
    # it afterwards keeps that guarantee -- and the check still earns its place,
    # because a Slate root that is itself a symlink somewhere unexpected is
    # caught here rather than after a worktree has been made in it.
    mkdir -p "$root" 2>/dev/null
    herdr_linear::contains "$root" || {
        printf 'the worktree root is not inside the Slate root\n' >&2
        return "$HERDR_LINEAR_START_REFUSED"
    }
    # BOTH streams. `git worktree add` prints "Preparing worktree ..." on
    # STDOUT, which silencing only stderr leaves prepended to the path this
    # function returns -- so every caller got a path with a sentence in front
    # of it, and `[ -d "$result" ]` was false for a directory that existed.
    "${HERDR_LINEAR_GIT_BIN:-git}" -C "$(herdr_linear::slate_root)" \
        worktree add -b "$branch" "$path" >/dev/null 2>&1 \
        || return "$HERDR_LINEAR_START_FAILED"

    # Bound on creation. Naming the ticket is the confirmation.
    nonce="$(herdr_linear::binding_propose "$path" "$ident")" || return "$HERDR_LINEAR_START_FAILED"
    herdr_linear::binding_confirm "$path" "$ident" "$nonce" || return "$HERDR_LINEAR_START_FAILED"

    printf '%s' "$path"
    return "$HERDR_LINEAR_START_OK"
}

# herdr_linear::start_new <title> <description-file> <team-key> [worktree-name]
#
# Nothing exists yet. Creates the issue, then the worktree bound to it.
#
# This one DOES write to Linear, so it is shadow-gated like every other write --
# and the shadow path deliberately creates no worktree either, because a
# worktree bound to an issue that was never filed is a dangling reference.
herdr_linear::start_new() {
    local title="${1:-}" descfile="${2:-}" team="${3:-}" name="${4:-}"
    local body resp ident

    [ -n "$title" ] && [ -n "$team" ] || return "$HERDR_LINEAR_START_REFUSED"
    [ -r "$descfile" ] || return "$HERDR_LINEAR_START_REFUSED"
    # The description is held to the same bar as any other, before an issue
    # exists to carry a bad one.
    herdr_linear::description_validate "$descfile" || return "$HERDR_LINEAR_START_REFUSED"

    if ! herdr_linear::_start_writes_enabled; then
        herdr_linear::_shadow_log "SHADOW would create issue \"$title\" on team $team, and a worktree for it"
        printf 'shadow: would create "%s" on %s\n' "$title" "$team"
        return "$HERDR_LINEAR_START_OK"
    fi

    body="$(python3 -c '
import sys, json
q = ("mutation($t:String!,$d:String!,$team:String!){"
     "issueCreate(input:{title:$t,description:$d,teamId:$team})"
     "{success issue{id identifier branchName title}}}")
print(json.dumps({"query": q, "variables": {
    "t": sys.argv[1], "d": open(sys.argv[2]).read(), "team": sys.argv[3]}}))
' "$title" "$descfile" "$team")" || return "$HERDR_LINEAR_START_FAILED"

    resp="$(herdr_linear::query "$body")" || return "$HERDR_LINEAR_START_FAILED"
    ident="$(printf '%s' "$resp" | python3 -c '
import sys, json
try:
    p = json.load(sys.stdin)["data"]["issueCreate"]
    if p.get("success") is not True: sys.exit(1)
    sys.stdout.write((p.get("issue") or {}).get("identifier", ""))
except Exception:
    sys.exit(1)
')" || return "$HERDR_LINEAR_START_FAILED"
    [ -n "$ident" ] || return "$HERDR_LINEAR_START_FAILED"

    herdr_linear::start_from_issue "$ident" "$name"
}

# Creating an issue is a write, and writes are opt-in per worktree. There is no
# worktree yet, so this asks whether the ALLOWLIST has anything in it at all --
# a deliberately conservative reading of "writes are enabled here".
herdr_linear::_start_writes_enabled() {
    [ -s "${HERDR_LINEAR_WRITE_ALLOWLIST:-$HOME/.claude/work/write-enabled}" ]
}
