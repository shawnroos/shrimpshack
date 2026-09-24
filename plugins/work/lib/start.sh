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
command -v herdr_linear::scheme_name >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/schemes.sh"
command -v herdr_linear::description_validate >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/description.sh"

HERDR_LINEAR_START_OK=0
HERDR_LINEAR_START_REFUSED=1
HERDR_LINEAR_START_EXISTS=2
HERDR_LINEAR_START_UNAVAILABLE=3
HERDR_LINEAR_START_FAILED=4
HERDR_LINEAR_START_SHADOW=5
# KTD7. The repository is a choice, not a fact: the reason is on stderr, nothing
# was created, and the retry carries the answer.
HERDR_LINEAR_START_ASK=6

# ------------------------------------------------------- the session switch
#
# R8. Whether work opens a session is a setting rather than a property of which
# command was used. The two paths disagree today -- filing a new issue always
# opens one, starting from a ticket never does -- so a single boolean cannot
# keep both: a default of off silently stops the filing path, and a default of
# on silently starts the other. The switch is TRI-STATE. Unset leaves each path
# exactly as it behaves today, false withholds a session on both, true opens one
# on both.
#
# `:-` and not `-`, unlike the branch prefix above. An empty prefix MEANS
# something -- no prefix -- so there the two states have to stay apart. An empty
# switch names no answer, so it can only mean the switch was not chosen; that is
# the reading lib/schemes.sh gives every scheme setting for the same reason.

# Prints `true`, `false`, or `unset`.
herdr_linear::session_switch() {
    local want="${HERDR_LINEAR_OPEN_SESSION:-}" shown
    case "$want" in
        true|false) printf '%s' "$want"; return 0 ;;
        '')         printf 'unset'; return 0 ;;
    esac
    # A typo that quietly means "as it was" is the failure lib/schemes.sh
    # refuses for naming, so it is said out loud. It does not stop the work:
    # by the time this is read the issue and the worktree are already real.
    if herdr_linear::is_safe_identifier "$want"; then shown="$want"; else shown='(unprintable)'; fi
    printf 'HERDR_LINEAR_OPEN_SESSION is %s, which is neither true nor false; this path keeps its own behaviour\n' \
        "$shown" >&2
    printf 'unset'
}

# herdr_linear::session_wanted <default: open|none>
#
# 0 when the switch, or <default> when it is unset, asks for a session.
herdr_linear::session_wanted() {
    case "$(herdr_linear::session_switch)" in
        true)  return 0 ;;
        false) return 1 ;;
        *)     [ "${1:-none}" = open ] ;;
    esac
}

# herdr_linear::usable_schemes <default: open|none>
#
# Whether every scheme this path will render is one the plugin knows. The tab is
# rendered only when a session opens, so a path that opens none is not refused
# for a tab scheme it never uses.
herdr_linear::usable_schemes() {
    if herdr_linear::session_wanted "${1:-none}" 2>/dev/null; then
        herdr_linear::schemes_usable worktree branch tab
    else
        herdr_linear::schemes_usable worktree branch
    fi
}

# herdr_linear::place_session <worktree-path> <default: open|none>
#
# The session the switch asks for, or nothing at all. <default> is what this
# path does when the switch is unset: the filing path opens one, the start path
# does not.
#
# Prints the pane id when a session was opened and nothing otherwise. A session
# that could not be opened is REPORTED, never fatal -- the worktree is what the
# calling verb is for, and it is made and bound before this is reached.
herdr_linear::place_session() {
    local path="${1:-}" fallback="${2:-none}" pane rc
    herdr_linear::session_wanted "$fallback" || return 0

    # lib/herdr-write.sh is where the open lives, and no lib sources another:
    # unsourced, the call below would be 127, which a `||` branch reads as a
    # session that was considered and declined rather than one never attempted.
    command -v herdr_linear::open_session >/dev/null 2>&1 || {
        printf 'a session was asked for, but lib/herdr-write.sh is not sourced, so no session was opened\n' >&2
        return 1
    }

    # stderr is left open: when the space is a choice, the question is there and
    # nowhere else.
    pane="$(herdr_linear::open_session "$path")"; rc=$?
    [ "$rc" -eq 0 ] || {
        printf 'the worktree is made and bound, but no session was opened for it\n' >&2
        return "$rc"
    }
    printf '%s' "$pane"
}

# R3, KTD2. The name leads with the identifier in its own case, so the directory
# says which ticket it is. Linear's own branchName is lowercase, so a name
# derived from it could not -- which is why the plugin renders its own.
#
# R5. Neither of these composes a name any more. They extract what the resolver
# needs from the response their callers already hold and ask for the name by
# kind, so changing a scheme changes both of them together.

herdr_linear::_start_issue_field() {
    printf '%s' "$1" | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["issue"].get(sys.argv[1]) or "")' "$2" 2>/dev/null
}

# Refuses SILENTLY, as it always has. A caller reads this as "this ticket cannot
# be named"; the resolver's own refusals still reach stderr, and these two
# guards are what keep an unreadable response from becoming one of them.
herdr_linear::start_worktree_name() {
    local resp="$1" ident title
    ident="$(herdr_linear::_start_issue_field "$resp" identifier)"
    title="$(herdr_linear::_start_issue_field "$resp" title)"
    [ -n "$ident" ] && [ -n "$title" ] || return 1
    herdr_linear::is_safe_identifier "$ident" || return 1
    herdr_linear::scheme_name worktree "$ident" "$title"
}

# KTD1. The branch is the directory name behind the repository's prefix
# convention, so the identifier appears in both and branch matching finds this
# worktree forever after. An empty prefix makes the two strings identical, which
# is what makes trading the identical-string form away safe.
#
# The prefix is passed to the resolver EXPLICITLY, empty value and all: the
# resolver spells it `${4-...}`, so an explicit empty survives where a defaulted
# one would collapse back to `feature`. Asking for the branch rather than
# prefixing the worktree name is what makes the no-prefix branch scheme
# reachable at all.
herdr_linear::start_branch_name() {
    local resp="$1" prefix="${2-$HERDR_LINEAR_BRANCH_PREFIX}" ident title
    ident="$(herdr_linear::_start_issue_field "$resp" identifier)"
    title="$(herdr_linear::_start_issue_field "$resp" title)"
    [ -n "$ident" ] && [ -n "$title" ] || return 1
    herdr_linear::is_safe_identifier "$ident" || return 1
    herdr_linear::scheme_name branch "$ident" "$title" "$prefix"
}

# R5a, KTD3. Prints `<typed-key><TAB><team-key><TAB><segment><TAB><pair-key>`.
# The key is typed so a project id and a team id can never collide in one
# filename space. All three keys come back because a repository is decided by
# the project and the team TOGETHER: the pair key is what an answer is recorded
# under, and the two plain keys are read-only fallbacks for the records the
# earlier rule wrote. With no project there is no pair, and the pair key is the
# team key -- a degenerate `team-x.team-x` would be a second name for a record
# the team key already holds.
herdr_linear::start_scope() {
    local resp="$1" fields pid pname tid tkey key team_key pair_key segment
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

    pair_key="$team_key"

    if [ -n "$pid" ]; then
        herdr_linear::is_safe_identifier "$pid" || return 1
        key="project-$pid"
        # The pair key's own composer owns the dot guard now (KTD3 in
        # repos.sh); this is the one caller that needs to say why out loud
        # before refusing, because it is about to WRITE under that key.
        pair_key="$(herdr_linear::pair_key "$pid" "$tid")" || {
            printf 'a Linear id carrying a dot cannot be keyed: %s / %s\n' "$pid" "$tid" >&2
            return 1
        }
        # Composed like the title, not slugged: slug() refuses a leading
        # non-alphanumeric, and project names start with emoji and brackets.
        segment="$(printf '%s' "$pname" \
            | tr '[:upper:]' '[:lower:]' \
            | tr -c 'a-z0-9' '-' \
            | sed -E 's/-+/-/g; s/^-+//; s/-+$//' \
            | cut -c1-60 | sed -E 's/-+$//')"
        herdr_linear::is_safe_identifier "$segment" \
            || segment="$(printf '%s' "$tkey" | tr '[:upper:]' '[:lower:]')"
        herdr_linear::is_safe_identifier "$segment" || return 1
    else
        key="$team_key"
        segment="$(printf '%s' "$tkey" | tr '[:upper:]' '[:lower:]')"
        herdr_linear::is_safe_identifier "$segment" || return 1
    fi
    printf '%s\t%s\t%s\t%s\n' "$key" "$team_key" "$segment" "$pair_key"
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
    local resp branch name scope key team_key pair_key segment org usable path current
    local repo candidates source nonce existing top git="${HERDR_LINEAR_GIT_BIN:-git}"

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

    # Refused, not failed: the table's failure promises a worktree or binding that
    # went wrong, and a scheme that cannot render has made neither.
    herdr_linear::usable_schemes none || return "$HERDR_LINEAR_START_REFUSED"

    # The issue must exist. A worktree created for a typo'd identifier is worse
    # than a refusal: it looks like work and is bound to nothing.
    resp="$(herdr_linear::fetch_issue "$ident")"
    case $? in
        0) ;;
        2) printf 'no such issue: %s\n' "$ident" >&2; return "$HERDR_LINEAR_START_REFUSED" ;;
        *) return "$HERDR_LINEAR_START_UNAVAILABLE" ;;
    esac

    branch="$(herdr_linear::start_branch_name "$resp" "$prefix")" || return "$HERDR_LINEAR_START_REFUSED"
    name="$(herdr_linear::start_worktree_name "$resp")" || return "$HERDR_LINEAR_START_REFUSED"
    scope="$(herdr_linear::start_scope "$resp")" || return "$HERDR_LINEAR_START_FAILED"
    key="$(printf '%s' "$scope" | cut -f1)"
    team_key="$(printf '%s' "$scope" | cut -f2)"
    segment="$(printf '%s' "$scope" | cut -f3)"
    pair_key="$(printf '%s' "$scope" | cut -f4)"
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
        top="$("$git" -C "$path" rev-parse --show-toplevel 2>/dev/null)" || top=""
        if [ ! -d "$path" ] || [ -z "$top" ] || [ "$top" != "$(cd "$path" 2>/dev/null && pwd -P)" ]; then
            printf 'already exists: %s\n' "$path" >&2
            return "$HERDR_LINEAR_START_EXISTS"
        fi
        existing="$(herdr_linear::binding_identifier "$path" 2>/dev/null)" || existing=""
        if [ -n "$existing" ] && [ "$existing" != "$ident" ]; then
            printf 'already exists and belongs to %s: %s\n' "$existing" "$path" >&2
            return "$HERDR_LINEAR_START_EXISTS"
        fi
        # The recovery above covers a binding that failed partway, on the branch
        # this issue made. A worktree someone has since moved to another branch
        # is not that: it may be live work on something else.
        current="$("$git" -C "$path" symbolic-ref --quiet --short HEAD 2>/dev/null)" || current=""
        if [ "$current" != "$branch" ]; then
            printf 'already exists on %s, not %s: %s\n' "${current:-a detached HEAD}" "$branch" "$path" >&2
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
        # Recorded before anything is made, and under the PAIR key alone. The
        # project key would answer for every other team unasked; the team key
        # would accumulate one entry per project it works in, and `add` never
        # shrinks a set, so that scope would ask on every start for ever.
        herdr_linear::record_scope_repo "$answer" "$pair_key" \
            || return "$HERDR_LINEAR_START_FAILED"
        repo="$(cd "$answer" && pwd -P)"
    else
        # Pair key FIRST, then team, then project, and bound once so the three
        # readers below cannot drift apart: the first key holding anything
        # answers, so a pair that has decided must never reach a fallback. The
        # keys coincide when the issue has no project, and naming one twice
        # would report the same record as two.
        local -a scope_keys=("$pair_key")
        if [ "$team_key" != "$pair_key" ]; then scope_keys+=("$team_key"); fi
        if [ "$key" != "$pair_key" ] && [ "$key" != "$team_key" ]; then
            scope_keys+=("$key")
        fi
        # A record that cannot be read is not an empty one: asking would record
        # a second answer beside the one already on disk.
        candidates="$(herdr_linear::scope_repos "${scope_keys[@]}")" || {
            printf 'the repository record for this scope could not be read\n' >&2
            return "$HERDR_LINEAR_START_FAILED"
        }
        repo="$(printf '%s' "$candidates" | herdr_linear::the_only_line)"
        if [ -z "$repo" ]; then
            herdr_linear::no_repo_reason "${scope_keys[@]}" >&2
            return "$HERDR_LINEAR_START_ASK"
        fi
        # A repository that moved is asked about again, not failed on.
        if [ ! -d "$repo" ]; then
            printf 'the only repository recorded for this scope is not there any more: %s. Ask which repository to use, then pass it back as an absolute path.\n' "$repo" >&2
            return "$HERDR_LINEAR_START_ASK"
        fi
        source="$(herdr_linear::scope_repo_source "${scope_keys[@]}")"
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
    # Before filing: filed first, a scheme that cannot render leaves a real ticket
    # that no retry can start.
    herdr_linear::usable_schemes none || return "$HERDR_LINEAR_START_REFUSED"

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

