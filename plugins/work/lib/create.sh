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
#
# A BOARD TARGET (KTD18). The filing verbs take an optional group from the board:
# {level kind: Linear id, or null for a "No <level>" group}, the shape
# lib/board-plan.sh renders. Its fields and the team's first unstarted state go
# into the one create call, so the ticket lands where it was put and does not
# fall into a triage state the board filter excludes (R34).

command -v herdr_linear::board_first_unstarted_state >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/board-linear.sh"

HERDR_LINEAR_CREATE_OK=0
HERDR_LINEAR_CREATE_REFUSED=1
HERDR_LINEAR_CREATE_NO_CONTEXT=2
HERDR_LINEAR_CREATE_SHADOW=3
HERDR_LINEAR_CREATE_FAILED=4
# The remote object exists but the local half of the verb did not finish. Kept
# apart from FAILED because the two demand opposite next moves: FAILED means
# nothing was filed, PARTIAL means something was and is now unattended.
HERDR_LINEAR_CREATE_PARTIAL=5

# herdr_linear::new_issue <worktree> <title> <descfile> [workspace-id] [board-target-json]
#
# A new issue in the current project, and a session to work it in.
herdr_linear::new_issue() {
    herdr_linear::_issue_with_session "$1" "$2" "$3" "" "${4:-}" "${5:-}"
}

# herdr_linear::new_sub_issue <worktree> <title> <descfile> [workspace-id] [board-target-json]
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
    herdr_linear::_issue_with_session "$1" "$2" "$3" "$parent" "${4:-}" "${5:-}"
}

# herdr_linear::new_issue_here <worktree> <title> <descfile> [workspace-id] [board-target-json]
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

    ident="$(herdr_linear::_file_issue "$wt" "${2:-}" "${3:-}" "" "${4:-}" "${5:-}")" || return $?

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

    ident="$(herdr_linear::_file_issue "$wt" "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}")" || return $?

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

# herdr_linear::_file_issue <worktree> <title> <descfile> <parent> [workspace-id] [board-target-json]
#
# Everything the three filing verbs share, ending at the tracker. STDOUT CARRIES
# THE IDENTIFIER AND NOTHING ELSE -- every message here goes to stderr, because
# a stray line would prepend a sentence to what the caller reads back as an
# identifier.
herdr_linear::_file_issue() {
    local wt="${1:-}" title="${2:-}" descfile="${3:-}" parent="${4:-}" ws="${5:-}" target="${6:-}"
    local ctx fields project team body resp ident parent_id target_input="" state_id=""

    [ -n "$title" ] || return "$HERDR_LINEAR_CREATE_REFUSED"
    [ -r "$descfile" ] || return "$HERDR_LINEAR_CREATE_REFUSED"
    # Strict, not lenient: this description was composed fresh from the
    # template, so a missing spine means the template was abandoned halfway.
    herdr_linear::description_validate "$descfile" strict || return "$HERDR_LINEAR_CREATE_REFUSED"

    if [ -n "$target" ]; then
        target_input="$(herdr_linear::_create_target_input "$target" "$parent")" \
            || return "$HERDR_LINEAR_CREATE_REFUSED"
    fi

    ctx="$(herdr_linear::current_context "$wt" "$ws")"
    fields="$(herdr_linear::context_fields "$ctx" project_id team_id)"
    project="$(printf '%s' "$fields" | cut -f1)"
    team="$(printf '%s' "$fields" | cut -f2)"

    # The group's team and project are the ones the ticket is filed into, so they
    # are the ones the consent question has to have named.
    if [ -n "$target_input" ]; then
        fields="$(printf '%s' "$target_input" | python3 -c '
import sys, json
t = json.load(sys.stdin)
team, project = sys.argv[1:3]
team = t["set"].get("teamId", team)
project = "" if "projectId" in t["unset"] else t["set"].get("projectId", project)
sys.stdout.write("%s\t%s" % (team, project))
' "$team" "$project")" || return "$HERDR_LINEAR_CREATE_FAILED"
        team="$(printf '%s' "$fields" | cut -f1)"
        project="$(printf '%s' "$fields" | cut -f2)"
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

    if [ -n "$target_input" ] && ! printf '%s' "$target_input" | python3 -c '
import sys, json
sys.exit(0 if "stateId" in json.load(sys.stdin)["set"] else 1)'; then
        state_id="$(herdr_linear::board_first_unstarted_state "$team")" || {
            printf 'team %s has no unstarted state to file a board ticket into; nothing was filed\n' "$team" >&2
            return "$HERDR_LINEAR_CREATE_FAILED"
        }
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
title, path, team, project, parent, target, state = sys.argv[1:8]
inp = {"title": title, "description": open(path).read(), "teamId": team}
if project: inp["projectId"] = project
if parent:  inp["parentId"] = parent
if target:
    inp.update(json.loads(target)["set"])
    if state: inp["stateId"] = state
q = ("mutation($i:IssueCreateInput!){issueCreate(input:$i)"
     "{success issue{identifier}}}")
print(json.dumps({"query": q, "variables": {"i": inp}}))
' "$title" "$descfile" "$team" "$project" "$parent_id" "$target_input" "$state_id")" || return "$HERDR_LINEAR_CREATE_FAILED"

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
    # Any new ticket can match a board filter, so the board is behind until the
    # next sync reads it; a store that cannot say so must not fail a filed ticket.
    herdr_linear::board_record_linear_write >/dev/null 2>&1 || true

    printf '%s' "$ident"
    return "$HERDR_LINEAR_CREATE_OK"
}

# herdr_linear::_create_target_input <board-target-json> [parent-identifier]
#
# Prints {"set": {IssueCreateInput key: value}, "unset": [keys]}. A null group
# leaves its key out of the create call and out of what context would have set;
# an empty string is refused, because Linear reads it as a value. REFUSED, with
# the reason on stderr, before anything is read or filed.
herdr_linear::_create_target_input() {
    python3 -c '
import json, re, sys

KEYS = {"team": "teamId", "project": "projectId", "milestone": "projectMilestoneId",
        "cycle": "cycleId", "assignee": "assigneeId", "state": "stateId",
        "priority": "priority", "parent": "parentId", "sub-ticket": "parentId"}
CONTROL = re.compile(r"[\x00-\x1f\x7f-\x9f]")

def refuse(why):
    sys.stderr.write("board target refused: %s; nothing was filed\n" % why)
    sys.exit(1)

try:
    groups = json.loads(sys.argv[1])
except ValueError:
    refuse("the target is not valid JSON")
if not isinstance(groups, dict):
    refuse("the target is not a JSON object")
bound_parent = sys.argv[2]
out, unset, labels = {}, [], []
for kind, value in sorted(groups.items()):
    if kind == "ticket":
        refuse("a ticket group is the ticket itself, not somewhere to file one")
    if kind not in KEYS and not kind.startswith("label-group:"):
        refuse("unknown level kind %s" % json.dumps(kind))
    if value is not None and (not isinstance(value, str) or value == "" or CONTROL.search(value)):
        refuse("%s holds %s; a group value is a non-empty string or null" % (kind, json.dumps(value)))
    if kind.startswith("label-group:"):
        if value is not None:
            labels.append(value)
        continue
    key = KEYS[kind]
    if value is None:
        if kind in ("team", "state"):
            refuse("every ticket has a %s, so there is no No %s group to file into" % (kind, kind))
        if key not in out:
            unset.append(key)
        continue
    if kind == "priority":
        if not re.fullmatch(r"[1-4]", value):
            refuse("priority %s is not 1 to 4" % json.dumps(value))
        value = int(value)
    if key in out and out[key] != value:
        refuse("parent and sub-ticket name different parents")
    if key in unset:
        unset.remove(key)
    out[key] = value
if bound_parent and ("parentId" in out or "parentId" in unset):
    refuse("the target names a parent group and this sub-issue is already parented to %s" % bound_parent)
if labels:
    out["labelIds"] = labels
print(json.dumps({"set": out, "unset": sorted(set(unset))}))
' "${1-}" "${2-}"
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
        herdr_linear::workspace_confirm "$ws" "$pid" "$nonce" || {
        printf 'created project %s and workspace %s, but could not bind them\n' "$pid" "$ws" >&2
        return "$HERDR_LINEAR_CREATE_PARTIAL"
    }

    printf '%s\t%s' "$pid" "$ws"
    return "$HERDR_LINEAR_CREATE_OK"
}
