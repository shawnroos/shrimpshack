#!/usr/bin/env bash
# Creating work: an issue, a sub-issue, or a project. Sourced, never executed.
#
# EVERY VERB HERE ENDS IN A SESSION. Filing a ticket and then separately making
# somewhere to work on it is two acts that always happen together, so they are
# one command: the issue is created, a worktree is made and bound to it, and a
# pane is opened in that worktree.
#
# CONTEXT IS DERIVED, NOT ASKED FOR. "In the current project" means the project
# of the issue this worktree is bound to, or the project the herdr workspace is
# bound to. Asking which team and which project every time is how a command
# stops being worth typing.
#
# ALL THREE WRITE TO LINEAR, so all three are shadow-gated. In shadow mode
# NOTHING local is created either -- no worktree, no pane, no workspace. A
# worktree bound to an issue that was never filed is a dangling reference, and a
# herdr workspace bound to a project that does not exist is worse, because it
# looks like a place to work.

HERDR_LINEAR_CREATE_OK=0
HERDR_LINEAR_CREATE_REFUSED=1
HERDR_LINEAR_CREATE_NO_CONTEXT=2
HERDR_LINEAR_CREATE_SHADOW=3
HERDR_LINEAR_CREATE_FAILED=4
# The remote object exists but the local half of the verb did not finish. Kept
# apart from FAILED because the two demand opposite next moves: FAILED means
# nothing was filed, PARTIAL means something was and is now unattended.
HERDR_LINEAR_CREATE_PARTIAL=5

# herdr_linear::current_context <worktree> [workspace-id]
#
# Prints `project=<id>`, `team=<id>` and `issue=<identifier>` for whatever can
# be determined. A caller decides which of them it actually needs.
herdr_linear::current_context() {
    local wt="${1:-}" ws="${2:-}" ident resp project team

    ident="$(herdr_linear::binding_identifier "$wt" 2>/dev/null)" || ident=""
    if [ -n "$ident" ]; then
        resp="$(herdr_linear::fetch_issue "$ident" 2>/dev/null)" || resp=""
        if [ -n "$resp" ]; then
            project="$(printf '%s' "$resp" | python3 -c 'import sys,json;print((json.load(sys.stdin)["data"]["issue"].get("project") or {}).get("id",""))' 2>/dev/null)"
            team="$(printf '%s' "$resp" | python3 -c 'import sys,json;print((json.load(sys.stdin)["data"]["issue"].get("team") or {}).get("id",""))' 2>/dev/null)"
        fi
    fi

    # A bound workspace answers the project when this worktree cannot -- which
    # is the case for the very first issue in a new space.
    if [ -z "$project" ] && [ -n "$ws" ]; then
        if [ "$(herdr_linear::workspace_state "$ws" 2>/dev/null)" = "bound" ]; then
            project="$(herdr_linear::workspace_project "$ws" 2>/dev/null)" || project=""
        fi
    fi

    # A project answers the team when no bound issue can -- the first issue in a
    # new space. ONLY when the project has exactly one team: a project spanning
    # several has no single right answer, and picking one files work into a team
    # nobody chose. The caller asks instead, and names the candidates.
    if [ -z "$team" ] && [ -n "$project" ]; then
        team="$(herdr_linear::project_team "$project" 2>/dev/null)" || team=""
    fi

    printf 'project=%s\nteam=%s\nissue=%s\n' "$project" "$team" "$ident"
}

# herdr_linear::scope_signals <worktree> [workspace-id]
#
# R7. Two signals, printed as `key=value`: whether the path sits under a known
# projects root, and which Linear project the worktree maps to. It never
# refuses -- a signal that blocks cannot be weighed against anything else.
#
# `unknown` is not `negative`. A worktree whose issue could not be fetched is
# not out of scope; it is unread. current_context cannot make that distinction
# because it swallows the fetch failure into an empty project, so the fetch
# exit is read here instead.
herdr_linear::scope_signals() {
    local wt="${1:-}" ws="${2:-}"
    printf 'path=%s\nproject=%s\n' \
        "$(herdr_linear::path_signal "$wt")" \
        "$(herdr_linear::_scope_project "$wt" "$ws")"
}

herdr_linear::_scope_project() {
    local wt="$1" ws="$2" ident resp project rc
    ident="$(herdr_linear::binding_identifier "$wt" 2>/dev/null)" || ident=""
    if [ -n "$ident" ]; then
        resp="$(herdr_linear::fetch_issue "$ident" 2>/dev/null)"; rc=$?
        case "$rc" in
            0) project="$(printf '%s' "$resp" | python3 -c 'import sys,json;print((json.load(sys.stdin)["data"]["issue"].get("project") or {}).get("id",""))' 2>/dev/null)" ;;
            "$HERDR_LINEAR_NOT_FOUND") project="" ;;
            *) printf 'unknown'; return 0 ;;
        esac
        [ -n "$project" ] && { printf '%s' "$project"; return 0; }
    fi

    if [ -n "$ws" ] && [ "$(herdr_linear::workspace_state "$ws" 2>/dev/null)" = "bound" ]; then
        project="$(herdr_linear::workspace_project "$ws" 2>/dev/null)" || project=""
        [ -n "$project" ] && { printf '%s' "$project"; return 0; }
    fi

    printf 'negative'
}

# herdr_linear::project_teams <project-id>
#
# Every team on the project, one `<id><TAB><name>` line each. A project with no
# teams prints nothing and succeeds; only a transport or shape failure returns
# non-zero, so a caller can tell "no teams" from "could not ask".
herdr_linear::project_teams() {
    local pid="${1:-}" body resp
    [ -n "$pid" ] || return 1
    body="$(python3 -c '
import sys, json
q = "query($id:String!){project(id:$id){teams(first:50){nodes{id name}}}}"
print(json.dumps({"query": q, "variables": {"id": sys.argv[1]}}))
' "$pid")" || return 1
    resp="$(herdr_linear::query "$body")" || return 1
    printf '%s' "$resp" | python3 -c '
import sys, json
try:
    nodes = json.load(sys.stdin)["data"]["project"]["teams"]["nodes"]
except Exception:
    sys.exit(1)
for n in nodes:
    sys.stdout.write("%s\t%s\n" % (n.get("id", ""), n.get("name", "")))
'
}

# herdr_linear::project_team <project-id>
#
# The id of the project's ONLY team, or nothing. Several teams print nothing and
# succeed: "cannot tell" is the answer, not an error to be reported at a caller
# that would then have to distinguish it from a network failure.
herdr_linear::project_team() {
    local lines
    lines="$(herdr_linear::project_teams "${1:-}")" || return 1
    [ "$(printf '%s' "$lines" | grep -c .)" -eq 1 ] || return 0
    printf '%s' "$lines" | head -n1 | cut -f1
}

herdr_linear::_ctx_field() { printf '%s' "$1" | sed -n "s/^$2=//p"; }

# herdr_linear::new_issue <worktree> <title> <descfile> [workspace-id] [name]
#
# A new issue in the current project, and a session to work it in.
herdr_linear::new_issue() {
    herdr_linear::_create_issue "$1" "$2" "$3" "" "${4:-}" "${5:-}"
}

# herdr_linear::new_sub_issue <worktree> <title> <descfile> [workspace-id] [name]
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
    herdr_linear::_create_issue "$1" "$2" "$3" "$parent" "${4:-}" "${5:-}"
}

# Why the team could not be derived, said so the reader can act on it. A project
# spanning several teams is a QUESTION, not a dead end, so name every candidate:
# "cannot tell which team" alone leaves the reader to go find out which exist.
herdr_linear::_no_team_reason() {
    local project="${1:-}" teams=""
    if [ -n "$project" ]; then
        teams="$(herdr_linear::project_teams "$project" 2>/dev/null)" || teams=""
    fi
    if [ "$(printf '%s' "$teams" | grep -c .)" -gt 1 ]; then
        printf 'this project spans several teams, so which one this belongs to is a choice, not a fact. Ask, then name one of:\n'
        printf '%s' "$teams" | grep . | while IFS=$'\t' read -r id name; do
            printf '  %s (%s)\n' "$name" "$id"
        done
        return 0
    fi
    if [ -n "$project" ]; then
        printf 'this project has no team, so there is nothing to file against. Add a team to the project first.\n'
        return 0
    fi
    printf 'cannot tell which team this belongs to. Bind this worktree, or bind the workspace to a project first.\n'
}

herdr_linear::_create_issue() {
    local wt="${1:-}" title="${2:-}" descfile="${3:-}" parent="${4:-}" ws="${5:-}" name="${6:-}"
    local ctx project team body resp ident path pane parent_id

    [ -n "$title" ] || return "$HERDR_LINEAR_CREATE_REFUSED"
    [ -r "$descfile" ] || return "$HERDR_LINEAR_CREATE_REFUSED"
    # Strict, not lenient: this description was composed fresh from the
    # template, so a missing spine means the template was abandoned halfway.
    herdr_linear::description_validate "$descfile" strict || return "$HERDR_LINEAR_CREATE_REFUSED"

    ctx="$(herdr_linear::current_context "$wt" "$ws")"
    project="$(herdr_linear::_ctx_field "$ctx" project)"
    team="$(herdr_linear::_ctx_field "$ctx" team)"

    if [ -z "$team" ]; then
        herdr_linear::_no_team_reason "$project" >&2
        return "$HERDR_LINEAR_CREATE_NO_CONTEXT"
    fi

    if ! herdr_linear::consent_ok "$wt" "$team" "$project"; then
        herdr_linear::_shadow_log "SHADOW would create issue \"$title\" (team $team, project ${project:-none}${parent:+, parent $parent}) and a session for it"
        printf 'shadow: would create "%s"%s\n' "$title" "${parent:+ under $parent}"
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
     "{success issue{id identifier branchName title}}}")
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

    # The session. A failure here leaves a real issue with no worktree, which is
    # recoverable by hand -- so it is reported, not rolled back. Deleting a
    # freshly filed ticket to tidy up would be worse.
    path="$(herdr_linear::start_from_issue "$ident" "$name" "" "$wt")" || {
        printf 'created %s, but could not make a worktree for it: run /work:start %s\n' "$ident" "$ident" >&2
        return "$HERDR_LINEAR_CREATE_PARTIAL"
    }

    pane="$(herdr_linear::open_session "$path" 2>/dev/null)" || pane=""
    printf '%s\t%s\t%s' "$ident" "$path" "$pane"
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
    local body resp pid bin ws nonce

    [ -n "$name" ] && [ -n "$team" ] || return "$HERDR_LINEAR_CREATE_REFUSED"
    [ -r "$contentfile" ] || return "$HERDR_LINEAR_CREATE_REFUSED"

    # A project names a team and no project of its own, so the answer that
    # covers it is the team-scoped one, recorded for the directory the session
    # is standing in -- which has no binding and needs none.
    if ! herdr_linear::consent_ok "$from" "$team" ""; then
        herdr_linear::_shadow_log "SHADOW would create project \"$name\" on team $team, and a herdr workspace for it"
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
        herdr_linear::workspace_confirm "$ws" "$pid" "$nonce" || {
        printf 'created project %s and workspace %s, but could not bind them\n' "$pid" "$ws" >&2
        return "$HERDR_LINEAR_CREATE_PARTIAL"
    }

    printf '%s\t%s' "$pid" "$ws"
    return "$HERDR_LINEAR_CREATE_OK"
}
