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
# credential rotation and before anybody has answered the write question, so the
# common motion is available immediately and cannot damage a board.
#
# BINDING ON CREATION IS NOT A GUESS. You named the ticket; that IS the
# confirmation, and the skill carrying it cannot be invoked by the model. Same
# reasoning as U10: the act of creating the worktree from an issue is the
# statement of what it is for.

# `-` and not `:-`. KTD1 trades the branch and the directory being one identical
# string away for the repository's prefix convention, and says setting this seam
# empty gets the identical form back with no code change. `:-` collapses an
# explicitly empty value into the default, which makes that claim false.
HERDR_LINEAR_BRANCH_PREFIX="${HERDR_LINEAR_BRANCH_PREFIX-feature}"

# No lib sources another, and ground.sh sources sanitize.sh AFTER this file:
# without this the call below is 127, which its `||` branch reads as a refusal.
command -v herdr_linear::is_safe_identifier >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/sanitize.sh"
command -v herdr_linear::scope_repos >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/repos.sh"

HERDR_LINEAR_START_OK=0
HERDR_LINEAR_START_REFUSED=1
HERDR_LINEAR_START_EXISTS=2
HERDR_LINEAR_START_UNAVAILABLE=3
HERDR_LINEAR_START_FAILED=4
HERDR_LINEAR_START_SHADOW=5
# KTD7. The repository is a choice, not a fact: the reason is on stderr, nothing
# was created, and the retry carries the answer.
HERDR_LINEAR_START_ASK=6

# R3, KTD2. `<IDENTIFIER>-<title-slug>`, identifier first and its case kept, so
# the directory says which ticket it is. Linear's own branchName is lowercase, so
# a name derived from it could not lead with an uppercase identifier -- the two
# strings are composed here instead.
herdr_linear::start_worktree_name() {
    local resp="$1" ident title slug
    ident="$(printf '%s' "$resp" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["issue"].get("identifier") or "")' 2>/dev/null)"
    title="$(printf '%s' "$resp" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["issue"].get("title") or "")' 2>/dev/null)"
    [ -n "$ident" ] && [ -n "$title" ] || return 1
    herdr_linear::is_safe_identifier "$ident" || return 1
    slug="$(printf '%s' "$title" \
        | tr '[:upper:]' '[:lower:]' \
        | tr -c 'a-z0-9' '-' \
        | sed -E 's/-+/-/g; s/^-+//; s/-+$//')"
    # The 40-character cut can sever a word in half, so the severed remnant is
    # dropped -- but only when the cut actually happened. Trimming
    # unconditionally cost every short title its last word. The cut is on the
    # TITLE, so the identifier the name leads with can never be severed.
    if [ "${#slug}" -gt 40 ]; then
        slug="$(printf '%s' "$slug" | cut -c1-40 | sed -E 's/-[^-]*$//; s/-+$//')"
    fi
    [ -n "$slug" ] || return 1
    herdr_linear::slug "$ident-$slug" 60
}

# KTD1. The branch is the directory name behind the repository's prefix
# convention, so the identifier appears in both and branch matching finds this
# worktree forever after. An empty prefix makes the two strings identical, which
# is what makes trading the identical-string form away safe.
herdr_linear::start_branch_name() {
    local resp="$1" prefix="${2-$HERDR_LINEAR_BRANCH_PREFIX}" name
    name="$(herdr_linear::start_worktree_name "$resp")" || return 1
    [ -n "$prefix" ] || { printf '%s' "$name"; return 0; }
    printf '%s/%s' "$prefix" "$name"
}

# R5a, KTD3. Prints `<typed-key><TAB><team-key><TAB><segment>`. The key is typed
# so a project id and a team id can never collide in one filename space, and the
# team key comes back alongside the project key because an answer is recorded
# under both -- without it a team-keyed answer is invisible to every issue in
# that team that later gains a project.
herdr_linear::start_scope() {
    local resp="$1" fields pid pname tid tkey key team_key segment
    fields="$(printf '%s' "$resp" | python3 -c '
import sys, json
i = json.load(sys.stdin)["data"]["issue"]
p = i.get("project") or {}
t = i.get("team") or {}
sys.stdout.write("\t".join([p.get("id") or "", p.get("name") or "",
                            t.get("id") or "", t.get("key") or ""]))
' 2>/dev/null)" || return 1
    pid="$(printf '%s' "$fields" | cut -f1)"
    pname="$(printf '%s' "$fields" | cut -f2)"
    tid="$(printf '%s' "$fields" | cut -f3)"
    tkey="$(printf '%s' "$fields" | cut -f4)"

    [ -n "$tid" ] && [ -n "$tkey" ] || return 1
    # Both halves of the key become a filename under the store.
    herdr_linear::is_safe_identifier "$tid" || return 1
    team_key="team-$tid"

    if [ -n "$pid" ]; then
        herdr_linear::is_safe_identifier "$pid" || return 1
        key="project-$pid"
        segment="$(herdr_linear::slug "$pname" 60)" || return 1
        segment="$(printf '%s' "$segment" | tr '[:upper:]' '[:lower:]')"
    else
        key="$team_key"
        segment="$(printf '%s' "$tkey" | tr '[:upper:]' '[:lower:]')"
        herdr_linear::is_safe_identifier "$segment" || return 1
    fi
    printf '%s\t%s\t%s\n' "$key" "$team_key" "$segment"
}

# herdr_linear::start_from_issue <identifier> [branch-prefix] [from-dir] [repository]
#
# Prints the worktree path on success, and nothing else on stdout.
#
# R1. The path is `<worktrees-root>/<org>/<scope>/<name>`, every segment read
# from the issue. <from-dir> is accepted and derives nothing: it used to decide
# both the path and the repository, and the tests pass it to prove it no
# longer can.
#
# R5-R8. <repository> is the answer to the repository question, as an absolute
# path. Without one, the repository is read from the scope's record: one is
# stated and used, several or none return START_ASK and create nothing.
#
# R14. There is no name parameter. A supplied name can drop the identifier, and
# the identifier leading the directory is what KTD1 leans on when it lets the
# branch and the directory differ.
herdr_linear::start_from_issue() {
    local ident="${1:-}" prefix="${2:-$HERDR_LINEAR_BRANCH_PREFIX}"
    local answer="${4:-}"
    local resp branch name scope key team_key segment org usable path
    local repo candidates source nonce existing git="${HERDR_LINEAR_GIT_BIN:-git}"

    [ -n "$ident" ] || return "$HERDR_LINEAR_START_REFUSED"

    # R7a. Resolving a relative answer would let the caller's directory decide
    # the repository again.
    case "$answer" in
        ''|/*) ;;
        *) printf 'the repository must be an absolute path, not %s\n' "$answer" >&2
           return "$HERDR_LINEAR_START_REFUSED" ;;
    esac

    # R13. Before anything is read or made: under an overlapping root the
    # delete-safety promise is false, so there is nothing safe to do.
    usable="$(herdr_linear::worktrees_root_usable)"
    if [ "$usable" != usable ]; then
        printf 'refusing to create a worktree: %s\n' "$usable" >&2
        return "$HERDR_LINEAR_START_REFUSED"
    fi

    # The issue must exist. A worktree created for a typo'd identifier is worse
    # than a refusal: it looks like work and is bound to nothing.
    resp="$(herdr_linear::fetch_issue "$ident")"
    case $? in
        0) ;;
        2) printf 'no such issue: %s\n' "$ident" >&2; return "$HERDR_LINEAR_START_REFUSED" ;;
        *) return "$HERDR_LINEAR_START_UNAVAILABLE" ;;
    esac

    branch="$(herdr_linear::start_branch_name "$resp" "$prefix")" || return "$HERDR_LINEAR_START_FAILED"
    name="$(herdr_linear::start_worktree_name "$resp")" || return "$HERDR_LINEAR_START_FAILED"
    scope="$(herdr_linear::start_scope "$resp")" || return "$HERDR_LINEAR_START_FAILED"
    key="$(printf '%s' "$scope" | cut -f1)"
    team_key="$(printf '%s' "$scope" | cut -f2)"
    segment="$(printf '%s' "$scope" | cut -f3)"
    # An empty organisation would put two workspaces in one directory.
    org="$(herdr_linear::organization_key)" || return "$HERDR_LINEAR_START_FAILED"

    path="$(herdr_linear::worktrees_root)/$org/$segment/$name"

    # Never adopt a directory that is already there -- it may be someone's live
    # work, and binding it to this issue would silently re-home it. The one
    # exception is this issue's OWN worktree: the path is deterministic, so a
    # flat refusal leaves a worktree whose binding failed unbindable by script
    # forever, and the documented "just run /work:start again" recovery
    # impossible.
    #
    # Before the repository is resolved: this issue's own worktree already
    # names its repository, and a retry must not be asked a question about it.
    if [ -e "$path" ]; then
        # git's own answer, not a `.git` entry: anything can hold one of those,
        # and binding it would claim a restart that did not happen.
        if [ ! -d "$path" ] \
            || [ "$("$git" -C "$path" rev-parse --show-toplevel 2>/dev/null)" != "$(cd "$path" && pwd -P)" ]; then
            printf 'already exists: %s\n' "$path" >&2
            return "$HERDR_LINEAR_START_EXISTS"
        fi
        existing="$(herdr_linear::binding_identifier "$path" 2>/dev/null)" || existing=""
        if [ -n "$existing" ] && [ "$existing" != "$ident" ]; then
            printf 'already exists and belongs to %s: %s\n' "$existing" "$path" >&2
            return "$HERDR_LINEAR_START_EXISTS"
        fi
        if [ "$existing" = "$ident" ] \
            && [ "$(herdr_linear::binding_state "$path" 2>/dev/null)" = "bound" ]; then
            printf '%s' "$path"
            return "$HERDR_LINEAR_START_OK"
        fi
        nonce="$(herdr_linear::binding_propose "$path" "$ident")" || return "$HERDR_LINEAR_START_FAILED"
        herdr_linear::binding_confirm "$path" "$ident" "$nonce" || return "$HERDR_LINEAR_START_FAILED"
        printf '%s' "$path"
        return "$HERDR_LINEAR_START_OK"
    fi

    if [ -n "$answer" ]; then
        if ! "$git" -C "$answer" rev-parse --git-dir >/dev/null 2>&1; then
            printf 'not a git repository: %s\n' "$answer" >&2
            return "$HERDR_LINEAR_START_REFUSED"
        fi
        # R8. Recorded before anything is made, under both keys, so the
        # question is never asked twice for this scope.
        herdr_linear::record_scope_repo "$answer" "$key" "$team_key" \
            || return "$HERDR_LINEAR_START_FAILED"
        repo="$(cd "$answer" && pwd -P)"
    else
        # A record that cannot be read is not an empty one: asking would record
        # a second answer beside the one already on disk.
        candidates="$(herdr_linear::scope_repos "$key" "$team_key")" || {
            printf 'the repository record for this scope could not be read\n' >&2
            return "$HERDR_LINEAR_START_FAILED"
        }
        repo="$(printf '%s' "$candidates" | herdr_linear::the_only_line)"
        if [ -z "$repo" ]; then
            herdr_linear::no_repo_reason "$key" "$team_key" >&2
            return "$HERDR_LINEAR_START_ASK"
        fi
        # A repository that moved is asked about again, not failed on.
        if [ ! -d "$repo" ]; then
            printf 'the only repository recorded for this scope is not there any more: %s. Ask which repository to use, then pass it back as an absolute path.\n' "$repo" >&2
            return "$HERDR_LINEAR_START_ASK"
        fi
        source="$(herdr_linear::scope_repo_source "$key" "$team_key")"
        # R6. stderr, because stdout is the path alone.
        printf 'repository %s: the only repository recorded for this scope, read from %s\n' \
            "$repo" "$source" >&2
    fi

    mkdir -p "${path%/*}" 2>/dev/null
    # KTD10. The branch lives in the repository and outlives a deleted
    # worktree, and git keeps a registration for the removed path. Without the
    # prune and the reuse, `add -b` refuses and the restart fails with nothing
    # printed.
    "$git" -C "$repo" worktree prune >/dev/null 2>&1
    # BOTH streams. `git worktree add` prints "Preparing worktree ..." on
    # STDOUT, which silencing only stderr leaves prepended to the path this
    # function returns -- so every caller got a path with a sentence in front
    # of it, and `[ -d "$result" ]` was false for a directory that existed.
    if "$git" -C "$repo" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
        "$git" -C "$repo" worktree add "$path" "$branch" >/dev/null 2>&1 \
            || return "$HERDR_LINEAR_START_FAILED"
    else
        "$git" -C "$repo" worktree add -b "$branch" "$path" >/dev/null 2>&1 \
            || return "$HERDR_LINEAR_START_FAILED"
    fi

    # Bound on creation. Naming the ticket is the confirmation.
    nonce="$(herdr_linear::binding_propose "$path" "$ident")" || return "$HERDR_LINEAR_START_FAILED"
    herdr_linear::binding_confirm "$path" "$ident" "$nonce" || return "$HERDR_LINEAR_START_FAILED"

    printf '%s' "$path"
    return "$HERDR_LINEAR_START_OK"
}

# herdr_linear::start_new <title> <description-file> <team-key> [from-dir] [repository]
#
# Nothing exists yet. Creates the issue, then the worktree bound to it.
# <repository> is passed through to start_from_issue as the answer to the
# repository question.
#
# This one DOES write to Linear, so it is shadow-gated like every other write --
# and the shadow path deliberately creates no worktree either, because a
# worktree bound to an issue that was never filed is a dangling reference.
herdr_linear::start_new() {
    local title="${1:-}" descfile="${2:-}" team="${3:-}"
    local from="${4:-$PWD}" answer="${5:-}"
    local body resp ident path rc

    [ -n "$title" ] && [ -n "$team" ] || return "$HERDR_LINEAR_START_REFUSED"
    # R7a, checked here as well: start_from_issue would refuse it only after
    # the issue had been filed.
    case "$answer" in
        ''|/*) ;;
        *) printf 'the repository must be an absolute path, not %s\n' "$answer" >&2
           return "$HERDR_LINEAR_START_REFUSED" ;;
    esac
    [ -r "$descfile" ] || return "$HERDR_LINEAR_START_REFUSED"
    # Strict, not lenient: this description was composed fresh from the
    # template, so a missing spine means the template was abandoned halfway.
    herdr_linear::description_validate "$descfile" strict || return "$HERDR_LINEAR_START_REFUSED"

    if ! herdr_linear::consent_gate "$from" "$team" "" \
        "create issue \"$title\" on team $team, and a worktree for it"; then
        # stderr, because stdout carries the worktree path.
        printf 'shadow: would create "%s" on %s\n' "$title" "$team" >&2
        return "$HERDR_LINEAR_START_SHADOW"
    fi

    body="$(python3 -c '
import sys, json
q = ("mutation($t:String!,$d:String!,$team:String!){"
     "issueCreate(input:{title:$t,description:$d,teamId:$team})"
     "{success issue{identifier}}}")
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

    # The identifier must survive a worktree failure -- it is what the caller
    # types to retry, and start_from_issue's own stderr never names it.
    path="$(herdr_linear::start_from_issue "$ident" "" "$from" "$answer")"; rc=$?
    # KTD7. The issue is real by now. Collapsing the question into a flat
    # failure leaves a ticket, no worktree, and nothing to answer.
    if [ "$rc" -eq "$HERDR_LINEAR_START_ASK" ]; then
        printf 'created %s; its worktree waits on the repository question: run /work:start %s with the answer\n' "$ident" "$ident" >&2
        return "$HERDR_LINEAR_START_ASK"
    fi
    if [ "$rc" -ne 0 ]; then
        printf 'created %s, but could not make a worktree for it: run /work:start %s\n' "$ident" "$ident" >&2
        return "$HERDR_LINEAR_START_FAILED"
    fi
    printf '%s' "$path"
    return "$HERDR_LINEAR_START_OK"
}

