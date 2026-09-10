#!/usr/bin/env bash
# Where am I: the readers that answer, and never write. Sourced, never executed.
#
# CONTEXT IS DERIVED, NOT ASKED FOR. "In the current project" means the project
# of the issue this worktree is bound to, or the project the herdr workspace is
# bound to. Asking which team and which project every time is how a command
# stops being worth typing.
#
# NOTHING HERE REFUSES. A signal that blocks cannot be weighed against anything
# else, so an unreadable fact comes back empty or as a named value the caller
# decides on.
#
# The context blob is JSON, read back by `herdr_linear::context_fields`, and its
# keys are `issue_context`'s keys for the same facts. Two shapes for one concept
# is what made a caller bridge them by hand.

# herdr_linear::current_context <worktree> [workspace-id]
#
# JSON carrying `project_id`, `team_id`, `team_name` and `identifier` for
# whatever can be determined. A caller decides which of them it actually needs
# and reads them with `herdr_linear::context_fields`.
herdr_linear::current_context() {
    local wt="${1:-}" ws="${2:-}" ident resp project team team_name="" line=""

    ident="$(herdr_linear::binding_identifier "$wt" 2>/dev/null)" || ident=""
    if [ -n "$ident" ]; then
        resp="$(herdr_linear::fetch_issue "$ident" 2>/dev/null)" || resp=""
        if [ -n "$resp" ]; then
            project="$(printf '%s' "$resp" | python3 -c 'import sys,json;print((json.load(sys.stdin)["data"]["issue"].get("project") or {}).get("id",""))' 2>/dev/null)"
            team="$(printf '%s' "$resp" | python3 -c 'import sys,json;print((json.load(sys.stdin)["data"]["issue"].get("team") or {}).get("id",""))' 2>/dev/null)"
            team_name="$(printf '%s' "$resp" | python3 -c 'import sys,json;print((json.load(sys.stdin)["data"]["issue"].get("team") or {}).get("name",""))' 2>/dev/null)"
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
        line="$(herdr_linear::project_team "$project" 2>/dev/null)" || line=""
        team="$(printf '%s' "$line" | cut -f1)"
        team_name="$(printf '%s' "$line" | cut -f2)"
    fi

    python3 -c '
import sys, json
project, team, team_name, ident = sys.argv[1:5]
print(json.dumps({"project_id": project, "team_id": team,
                  "team_name": team_name, "identifier": ident}))
' "$project" "$team" "$team_name" "$ident"
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
# The project's ONLY team as `<id><TAB><name>`, or nothing. Several teams print
# nothing and succeed: "cannot tell" is the answer, not an error to be reported
# at a caller that would then have to distinguish it from a network failure.
#
# This verb is the single owner of the exactly-one-team rule R13 states. Both
# fields come off the one line, so the id and the name cannot disagree.
herdr_linear::project_team() {
    local lines
    lines="$(herdr_linear::project_teams "${1:-}")" || return 1
    [ "$(printf '%s' "$lines" | grep -c .)" -eq 1 ] || return 0
    printf '%s' "$lines" | head -n1
}

# Why the team could not be derived, said so the reader can act on it. A project
# spanning several teams is a QUESTION, not a dead end, so name every candidate:
# "cannot tell which team" alone leaves the reader to go find out which exist.
herdr_linear::no_team_reason() {
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
