#!/usr/bin/env bash
# Creating work: an issue, a sub-issue, or a project. Sourced, never executed.
#
# EVERY VERB HERE ENDS IN A PLACE TO WORK. Filing a ticket and then separately
# making somewhere to work on it is two acts that always happen together, so
# they are one command: the issue is created, a worktree is made and bound to
# it, and a pane is opened in that worktree.
#
# EXCEPT WHEN YOU ARE ALREADY STANDING IN IT. `new_issue_here` files the ticket
# and binds the worktree it was asked from, because a second worktree there
# leaves the one you are in bound to nothing and the new one empty.
#
# WHERE THE CONTEXT COMES FROM. The readers live in lib/context.sh; this file
# only writes. `_file_issue` is everything the three filing verbs share and it
# ends at the tracker, printing the identifier and nothing else. What each verb
# does with that identifier -- a worktree and a pane, or the worktree you are
# standing in -- is its own tail, and its own output shape.
#
# ALL THREE WRITE TO LINEAR, so all three are shadow-gated. In shadow mode
# NOTHING local is created either -- no worktree, no pane, no workspace. A
# worktree bound to an issue that was never filed is a dangling reference, and a
# herdr workspace bound to a project that does not exist is worse, because it
# looks like a place to work.

# No lib sources another, and the resolver is what decides which team an issue
# is filed into: undefined, `context` is 127 and the `||` branch below reads it
# as no context at all.
command -v herdr_linear::context >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/context-filter.sh"

HERDR_LINEAR_CREATE_OK=0
HERDR_LINEAR_CREATE_REFUSED=1
HERDR_LINEAR_CREATE_NO_CONTEXT=2
HERDR_LINEAR_CREATE_SHADOW=3
HERDR_LINEAR_CREATE_FAILED=4
# The remote object exists but the local half of the verb did not finish. Kept
# apart from FAILED because the two demand opposite next moves: FAILED means
# nothing was filed, PARTIAL means something was and is now unattended.
HERDR_LINEAR_CREATE_PARTIAL=5

# herdr_linear::new_issue <worktree> <title> <descfile> [workspace-id]
#
# A new issue in the current project, and a session to work it in.
herdr_linear::new_issue() {
    herdr_linear::_issue_with_session "$1" "$2" "$3" "" "${4:-}"
}

# herdr_linear::new_sub_issue <worktree> <title> <descfile> [workspace-id]
#
# The same, parented to the issue this worktree is bound to. Refuses when the
# worktree is not bound: a sub-issue with no parent is just an issue, and
# silently filing one is not what was asked for.
herdr_linear::new_sub_issue() {
    local wt="${1:-}" parent
    parent="$(herdr_linear::binding_identifier "$wt" 2>/dev/null)" || parent=""
    if [ -z "$parent" ]; then
        printf 'this worktree is not bound to an issue, so there is no parent for a sub-issue\n' >&2
        return "$HERDR_LINEAR_CREATE_NO_CONTEXT"
    fi
    herdr_linear::_issue_with_session "$1" "$2" "$3" "$parent" "${4:-}"
}

# herdr_linear::new_issue_here <worktree> <title> <descfile> [workspace-id]
#
# R12. The same issue, bound to the worktree it was asked from. No second
# worktree, and no pane -- you are already in the one this is for, so the third
# output field is empty.
#
# It takes no worktree NAME, because it makes no worktree to name.
herdr_linear::new_issue_here() {
    local wt="${1:-}" bound ident nonce

    # Decided BEFORE anything is filed, which is why it is here and not inside
    # the shared body: found out afterwards, a worktree that cannot be bound
    # turns a refusal into a partial -- a real issue, and nowhere this verb is
    # willing to put it.
    bound="$(herdr_linear::binding_identifier "$wt" 2>/dev/null)" || bound=""
    if [ -n "$bound" ]; then
        printf 'this worktree is already bound to %s. Rebinding it would re-home that work, so which of a rebind, a sub-issue of %s, or an issue in its own worktree you meant is a choice, not a fact.\n' \
            "$bound" "$bound" >&2
        return "$HERDR_LINEAR_CREATE_REFUSED"
    fi

    ident="$(herdr_linear::_file_issue "$wt" "${2:-}" "${3:-}" "" "${4:-}")" || return $?

    # Bound in place. Asking for the ticket FROM this worktree is the statement
    # of what it is for -- the same reasoning start_from_issue binds on, where
    # naming the ticket is the confirmation.
    nonce="$(herdr_linear::binding_propose "$wt" "$ident")" && \
        herdr_linear::binding_confirm "$wt" "$ident" "$nonce" || {
        printf 'created %s, but could not bind this worktree to it: run /work:bind %s\n' "$ident" "$ident" >&2
        return "$HERDR_LINEAR_CREATE_PARTIAL"
    }
    printf '%s\t%s\t' "$ident" "$wt"
    return "$HERDR_LINEAR_CREATE_OK"
}

# The tail `new_issue` and `new_sub_issue` share: the issue, then somewhere to
# work it. Prints `IDENTIFIER<TAB>WORKTREE<TAB>PANE`.
herdr_linear::_issue_with_session() {
    local wt="${1:-}" ident path pane

    # Here and not in _file_issue: an issue filed into the current worktree names
    # nothing, so it must not be refused for a scheme it never renders.
    herdr_linear::usable_schemes open || return "$HERDR_LINEAR_CREATE_REFUSED"

    ident="$(herdr_linear::_file_issue "$wt" "${2:-}" "${3:-}" "${4:-}" "${5:-}")" || return $?

    # A failure here leaves a real issue with no worktree, which is recoverable
    # by hand -- so it is reported, not rolled back. Deleting a freshly filed
    # ticket to tidy up would be worse.
    path="$(herdr_linear::start_from_issue "$ident" "" "$wt")" || {
        printf 'created %s, but could not make a worktree for it: run /work:start %s\n' "$ident" "$ident" >&2
        return "$HERDR_LINEAR_CREATE_PARTIAL"
    }

    # R8. `open` is what this path does when the switch is unset, which is what
    # it has always done. Only `false` withholds the session here.
    pane="$(herdr_linear::place_session "$path" open)" || pane=""
    printf '%s\t%s\t%s' "$ident" "$path" "$pane"
    return "$HERDR_LINEAR_CREATE_OK"
}

# herdr_linear::new_issue_outside <worktree> <title> <descfile> <team> [project]
#
# An issue filed into a team the context does not cover, which is allowed once
# the person has named the target and confirmed. It stops at the tracker: no
# worktree, no binding, and no pane, so nothing local is recorded outside the
# context. The surface holding it wears the `UNBOUND:` prefix instead, which is
# what makes the deliberate case visible and the accidental one catchable.
#
# The write question is unchanged -- it is answered per worktree, for the team
# and project this names, through the one gate `_file_issue` already passes.
herdr_linear::new_issue_outside() {
    local wt="${1:-}" title="${2:-}" descfile="${3:-}" team="${4:-}" project="${5:-}"
    if [ -z "$team" ]; then
        printf 'filing outside the context needs the team named; nothing was filed\n' >&2
        return "$HERDR_LINEAR_CREATE_REFUSED"
    fi
    herdr_linear::_file_issue "$wt" "$title" "$descfile" "" "" "$team" "$project"
}

# herdr_linear::_file_issue <worktree> <title> <descfile> <parent> [workspace-id] [team] [project]
#
# Everything the three filing verbs share, ending at the tracker. STDOUT CARRIES
# THE IDENTIFIER AND NOTHING ELSE -- every message here goes to stderr, because
# a stray line would prepend a sentence to what the caller reads back as an
# identifier.
#
# <team> and <project> are the named target of a deliberate write outside the
# context. Given, they replace the resolved pair WHOLE: carrying the context's
# project into another team's issue would file it into a project that team may
# not even be on.
herdr_linear::_file_issue() {
    local wt="${1:-}" title="${2:-}" descfile="${3:-}" parent="${4:-}" ws="${5:-}"
    local named_team="${6:-}" named_project="${7:-}"
    local ctx fields project team body resp ident parent_id

    [ -n "$title" ] || return "$HERDR_LINEAR_CREATE_REFUSED"
    [ -r "$descfile" ] || return "$HERDR_LINEAR_CREATE_REFUSED"
    # Strict, not lenient: this description was composed fresh from the
    # template, so a missing spine means the template was abandoned halfway.
    herdr_linear::description_validate "$descfile" strict || return "$HERDR_LINEAR_CREATE_REFUSED"

    if [ -n "$named_team" ]; then
        team="$named_team"
        project="$named_project"
    else
        ctx="$(herdr_linear::context "$wt" "$ws")"
        fields="$(herdr_linear::context_fields "$ctx" project_id team_id)"
        project="$(printf '%s' "$fields" | cut -f1)"
        team="$(printf '%s' "$fields" | cut -f2)"
    fi

    if [ -z "$team" ]; then
        herdr_linear::no_team_reason "$project" >&2
        return "$HERDR_LINEAR_CREATE_NO_CONTEXT"
    fi

    if ! herdr_linear::consent_gate "$wt" "$team" "$project" \
        "create issue \"$title\" (team $team, project ${project:-none}${parent:+, parent $parent}) and a session for it"; then
        # stderr, because stdout carries the identifier.
        printf 'shadow: would create "%s"%s\n' "$title" "${parent:+ under $parent}" >&2
        return "$HERDR_LINEAR_CREATE_SHADOW"
    fi

    # The parent is given as an identifier; issueCreate wants its id.
    parent_id=""
    if [ -n "$parent" ]; then
        parent_id="$(herdr_linear::fetch_issue "$parent" 2>/dev/null \
            | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["issue"]["id"])' 2>/dev/null)" || parent_id=""
        [ -n "$parent_id" ] || return "$HERDR_LINEAR_CREATE_FAILED"
    fi

    body="$(python3 -c '
import sys, json
title, path, team, project, parent = sys.argv[1:6]
inp = {"title": title, "description": open(path).read(), "teamId": team}
if project: inp["projectId"] = project
if parent:  inp["parentId"] = parent
q = ("mutation($i:IssueCreateInput!){issueCreate(input:$i)"
     "{success issue{identifier}}}")
print(json.dumps({"query": q, "variables": {"i": inp}}))
' "$title" "$descfile" "$team" "$project" "$parent_id")" || return "$HERDR_LINEAR_CREATE_FAILED"

    resp="$(herdr_linear::query "$body")" || return "$HERDR_LINEAR_CREATE_FAILED"
    ident="$(printf '%s' "$resp" | python3 -c '
import sys, json
try:
    p = json.load(sys.stdin)["data"]["issueCreate"]
    if p.get("success") is not True: sys.exit(1)
    sys.stdout.write((p.get("issue") or {}).get("identifier", ""))
except Exception:
    sys.exit(1)
')" || return "$HERDR_LINEAR_CREATE_FAILED"
    [ -n "$ident" ] || return "$HERDR_LINEAR_CREATE_FAILED"

    # created_children IS the write boundary: an issue this plugin filed is one
    # it may later write to. A failure here fails CLOSED -- the child simply
    # stays unwritable -- so it must not stop the session from being made.
    if [ -n "$parent" ]; then
        herdr_linear::binding_add_child "$wt" "$ident" >/dev/null 2>&1 || true
    fi

    printf '%s' "$ident"
    return "$HERDR_LINEAR_CREATE_OK"
}

# herdr_linear::new_project <name> <content-file> <team-id> [workspace-label] [from-dir]
#
# A Linear project and the herdr workspace that is its space, bound together.
#
# This verb makes no worktree of its own, so <from-dir> is how it knows which
# project it is being run from: the write gate below is read for that project's
# worktrees root.
herdr_linear::new_project() {
    local name="${1:-}" contentfile="${2:-}" team="${3:-}" label="${4:-$1}"
    local from="${5:-$PWD}"
    local body resp pid bin ws nonce rc

    [ -n "$name" ] && [ -n "$team" ] || return "$HERDR_LINEAR_CREATE_REFUSED"
    [ -r "$contentfile" ] || return "$HERDR_LINEAR_CREATE_REFUSED"

    # This verb ends in a space bound to the new project, and a level may only
    # narrow the one above it. Asked BEFORE the tracker write, because a refusal
    # afterwards leaves a real Linear project nobody asked for; asked of the team
    # rather than of the project, because the project does not exist yet and the
    # team it is created on is the only team it will have.
    herdr_linear::context_allows team "$team"; rc=$?
    if [ "$rc" -eq "$HERDR_LINEAR_CONTEXT_OUTSIDE" ]; then
        printf 'this session is declared as team %s, so a project on team %s would bind its space outside the session. Declare the other team first, or create the project from a session of it.\n' \
            "$(herdr_linear::session_team)" "$team" >&2
        return "$HERDR_LINEAR_CREATE_REFUSED"
    fi

    # A project names a team and no project of its own, so the answer that
    # covers it is the team-scoped one, recorded for the directory the session
    # is standing in -- which has no binding and needs none.
    if ! herdr_linear::consent_gate "$from" "$team" "" \
        "create project \"$name\" on team $team, and a herdr workspace for it"; then
        printf 'shadow: would create project "%s"\n' "$name"
        return "$HERDR_LINEAR_CREATE_SHADOW"
    fi

    body="$(python3 -c '
import sys, json
name, path, team = sys.argv[1:4]
q = ("mutation($i:ProjectCreateInput!){projectCreate(input:$i)"
     "{success project{id name url}}}")
print(json.dumps({"query": q, "variables": {
    "i": {"name": name, "teamIds": [team], "content": open(path).read()}}}))
' "$name" "$contentfile" "$team")" || return "$HERDR_LINEAR_CREATE_FAILED"

    resp="$(herdr_linear::query "$body")" || return "$HERDR_LINEAR_CREATE_FAILED"
    pid="$(printf '%s' "$resp" | python3 -c '
import sys, json
try:
    p = json.load(sys.stdin)["data"]["projectCreate"]
    if p.get("success") is not True: sys.exit(1)
    sys.stdout.write((p.get("project") or {}).get("id", ""))
except Exception:
    sys.exit(1)
')" || return "$HERDR_LINEAR_CREATE_FAILED"
    [ -n "$pid" ] || return "$HERDR_LINEAR_CREATE_FAILED"

    # The space. Without herdr the project still exists and is usable, so this
    # reports rather than failing the whole verb.
    herdr_linear::probe || {
        printf 'created project %s, but the herdr server is not reachable so no space was made\n' "$pid" >&2
        return "$HERDR_LINEAR_CREATE_PARTIAL"
    }
    bin="$(herdr_linear::bin)"
    ws="$("$bin" workspace create --label "$label" --no-focus 2>/dev/null \
        | herdr_linear::json "result.workspace.workspace_id")"
    [ -n "$ws" ] || {
        printf 'created project %s, but the workspace could not be made\n' "$pid" >&2
        return "$HERDR_LINEAR_CREATE_PARTIAL"
    }

    # Bound on creation: making the space FROM the project is the statement that
    # they are the same thing.
    nonce="$(herdr_linear::workspace_propose "$ws" "$pid")" && \
        herdr_linear::workspace_confirm "$ws" "$pid" "$nonce" "$team" || {
        printf 'created project %s and workspace %s, but could not bind them\n' "$pid" "$ws" >&2
        return "$HERDR_LINEAR_CREATE_PARTIAL"
    }

    printf '%s\t%s' "$pid" "$ws"
    return "$HERDR_LINEAR_CREATE_OK"
}
