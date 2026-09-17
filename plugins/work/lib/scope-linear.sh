#!/usr/bin/env bash
# Linear reads for a session's scope: the candidates a session can bind to, and
# whether a project or an issue lies inside a bound scope (KTD4). Sourced, never
# executed. Read-only: nothing here sends a mutation.
#
# Membership answers are inside (0), outside (1) or unknown (2), printed and
# returned. Unknown is any answer Linear did not give, and callers must treat it
# as neither: it never marks work outside a session and never refuses a binding.

command -v herdr_linear::is_safe_identifier >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/sanitize.sh"
command -v herdr_linear::query >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/linear.sh"

HERDR_LINEAR_SCOPE_INSIDE=0
HERDR_LINEAR_SCOPE_OUTSIDE=1
HERDR_LINEAR_SCOPE_UNKNOWN=2

herdr_linear::_membership_answer() {
    case "$1" in
        "$HERDR_LINEAR_SCOPE_INSIDE") printf 'inside' ;;
        "$HERDR_LINEAR_SCOPE_OUTSIDE") printf 'outside' ;;
        *) printf 'unknown'; return "$HERDR_LINEAR_SCOPE_UNKNOWN" ;;
    esac
    return "$1"
}

# One read per operation and id. Cached only when HL_SCOPE_CACHE_DIR
# is set, which a sync does for its own run: membership can change in Linear,
# and a cache that outlives the sync would keep answering the old relation.
herdr_linear::_membership_read() {
    local op="$1" id="$2" query="$3" body resp cache=""
    herdr_linear::is_safe_identifier "$id" || return 1
    if [ -n "${HL_SCOPE_CACHE_DIR:-}" ]; then
        cache="$HL_SCOPE_CACHE_DIR/$op-$id.json"
        [ -f "$cache" ] && { cat "$cache"; return 0; }
    fi
    body="$(python3 -c 'import json,sys; print(json.dumps({"query": sys.argv[1], "variables": {"id": sys.argv[2]}}))' "$query" "$id")"
    resp="$(herdr_linear::query "$body")" || return 1
    if [ -n "$cache" ]; then
        mkdir -p "$HL_SCOPE_CACHE_DIR" 2>/dev/null \
            && chmod 700 "$HL_SCOPE_CACHE_DIR" 2>/dev/null \
            && printf '%s' "$resp" > "$cache"
    fi
    printf '%s' "$resp"
}

# The membership rule, in one place for projects and issues. Reads the response
# on stdin; argv: <kind> <scope id> <project|issue>.
HERDR_LINEAR_SCOPE_PY="$(cat <<'PYEOF'
import json, sys
kind, scope, what = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    data = json.load(sys.stdin)["data"]
    node = data[what]
except Exception:
    sys.exit(2)
if not isinstance(node, dict):
    sys.exit(2)

def ids(conn):
    if not isinstance(conn, dict) or not isinstance(conn.get("nodes"), list):
        raise ValueError
    return {n.get("id") for n in conn["nodes"] if isinstance(n, dict)}

try:
    if what == "project":
        if kind == "team":
            sys.exit(0 if scope in ids(node.get("teams")) else 1)
        if kind == "initiative":
            sys.exit(0 if scope in ids(node.get("initiatives")) else 1)
    else:
        project = node.get("project")
        if kind == "team":
            team = node.get("team")
            if not isinstance(team, dict):
                sys.exit(2)
            sys.exit(0 if team.get("id") == scope else 1)
        if project is None:
            sys.exit(1)
        if not isinstance(project, dict):
            sys.exit(2)
        if kind == "project":
            sys.exit(0 if project.get("id") == scope else 1)
        if kind == "initiative":
            sys.exit(0 if scope in ids(project.get("initiatives")) else 1)
except ValueError:
    sys.exit(2)
sys.exit(2)
PYEOF
)"

# herdr_linear::scope_contains_project <kind> <scope id> <project id>
herdr_linear::scope_contains_project() {
    local kind="${1:-}" scope="${2:-}" project="${3:-}" resp
    herdr_linear::is_safe_identifier "$scope" && herdr_linear::is_safe_identifier "$project" \
        || { herdr_linear::_membership_answer 2; return; }
    case "$kind" in
        organization) herdr_linear::_membership_answer "$HERDR_LINEAR_SCOPE_INSIDE"; return ;;
        project) [ "$scope" = "$project" ]; herdr_linear::_membership_answer $?; return ;;
        team|initiative) ;;
        *) herdr_linear::_membership_answer 2; return ;;
    esac
    resp="$(herdr_linear::_membership_read project "$project" \
        'query ScopeProject($id: String!) { project(id: $id) { id teams { nodes { id } } initiatives { nodes { id } } } }')" \
        || { herdr_linear::_membership_answer 2; return; }
    printf '%s' "$resp" | python3 -c "$HERDR_LINEAR_SCOPE_PY" "$kind" "$scope" project
    herdr_linear::_membership_answer $?
}

# herdr_linear::scope_contains_issue <kind> <scope id> <issue identifier or id>
herdr_linear::scope_contains_issue() {
    local kind="${1:-}" scope="${2:-}" issue="${3:-}" resp
    herdr_linear::is_safe_identifier "$scope" && herdr_linear::is_safe_identifier "$issue" \
        || { herdr_linear::_membership_answer 2; return; }
    case "$kind" in
        organization) herdr_linear::_membership_answer "$HERDR_LINEAR_SCOPE_INSIDE"; return ;;
        team|project|initiative) ;;
        *) herdr_linear::_membership_answer 2; return ;;
    esac
    resp="$(herdr_linear::_membership_read issue "$issue" \
        'query ScopeIssue($id: String!) { issue(id: $id) { id team { id } project { id initiatives { nodes { id } } } } }')" \
        || { herdr_linear::_membership_answer 2; return; }
    printf '%s' "$resp" | python3 -c "$HERDR_LINEAR_SCOPE_PY" "$kind" "$scope" issue
    herdr_linear::_membership_answer $?
}

# herdr_linear::scope_contains_milestone <kind> <scope id> <milestone id>
# A milestone belongs to one project; only a project scope is answered.
herdr_linear::scope_contains_milestone() {
    local kind="${1:-}" scope="${2:-}" milestone="${3:-}" resp
    herdr_linear::is_safe_identifier "$scope" && herdr_linear::is_safe_identifier "$milestone" \
        || { herdr_linear::_membership_answer 2; return; }
    case "$kind" in
        organization) herdr_linear::_membership_answer "$HERDR_LINEAR_SCOPE_INSIDE"; return ;;
        project) ;;
        *) herdr_linear::_membership_answer 2; return ;;
    esac
    resp="$(herdr_linear::_membership_read milestone "$milestone" \
        'query ScopeMilestone($id: String!) { projectMilestone(id: $id) { id project { id } } }')" \
        || { herdr_linear::_membership_answer 2; return; }
    printf '%s' "$resp" | python3 -c '
import json, sys
try:
    p = json.load(sys.stdin)["data"]["projectMilestone"]["project"]["id"]
except Exception:
    sys.exit(2)
sys.exit(0 if p == sys.argv[1] else 1)
' "$scope"
    herdr_linear::_membership_answer $?
}

# herdr_linear::scope_candidates <kind>
# One line per candidate: kind, id and display name, tab-separated. A read that
# failed prints nothing and fails, so an empty list always means none exist.
herdr_linear::scope_candidates() {
    local kind="${1:-}" q resp
    case "$kind" in
        organization) q='query ScopeOrganization { organization { id name } }' ;;
        team)         q='query ScopeTeams { teams(first: 250) { nodes { id key name } } }' ;;
        project)      q='query ScopeProjects { projects(first: 250) { nodes { id name } } }' ;;
        initiative)   q='query ScopeInitiatives { initiatives(first: 250) { nodes { id name } } }' ;;
        *) return 1 ;;
    esac
    resp="$(herdr_linear::query "$(python3 -c 'import json,sys; print(json.dumps({"query": sys.argv[1]}))' "$q")")" || return 1
    printf '%s' "$resp" | python3 -c '
import json, re, sys
kind = sys.argv[1]
clean = lambda s: re.sub(r"[\x00-\x1f\x7f-\x9f]", " ", str(s or "")).strip()
try:
    data = json.load(sys.stdin)["data"]
    if kind == "organization":
        nodes = [data["organization"]]
    else:
        nodes = data[kind + "s"]["nodes"]
    if not isinstance(nodes, list) or not all(isinstance(n, dict) for n in nodes):
        raise ValueError
except Exception:
    sys.exit(1)
out = []
for n in nodes:
    ident = str(n.get("id") or "")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", ident):
        continue
    name = clean(n.get("name"))
    if kind == "team" and n.get("key"):
        name = clean(n["key"]) + " " + name
    out.append("%s\t%s\t%s" % (kind, ident, name))
print("\n".join(out))
' "$kind"
}
