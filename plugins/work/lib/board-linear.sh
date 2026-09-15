#!/usr/bin/env bash
# The board's Linear reads, its one field write, and completing a ticket.
# Sourced, never executed. Transport is lib/linear.sh `herdr_linear::query`.
#
# WHY A SEPARATE SELECTION SET (KTD10)
# HERDR_LINEAR_ISSUE_FIELDS is read by every existing verb. The board needs
# milestone, cycle and label groups on top of it; widening that string changes
# every read the plugin makes.
#
# WHY THE READ REPORTS COMPLETENESS (KTD9)
# Only a read that finished every page may decide a ticket left the view. A
# partial read still prints what it got, flagged incomplete, and keeps no cursor
# to resume from: a resumed read mixes two moments of Linear into one view.

command -v herdr_linear::query >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/linear.sh"
command -v herdr_linear::board_consent_covers >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/board-store.sh"

HERDR_LINEAR_BOARD_PAGE_SIZE="${HERDR_LINEAR_BOARD_PAGE_SIZE:-50}"
# A cursor that never advances must not spin; 100 pages of 50 is a board no
# person reads.
HERDR_LINEAR_BOARD_MAX_PAGES="${HERDR_LINEAR_BOARD_MAX_PAGES:-100}"

# Outside linear.sh's 0-5, so a caller can tell these from a transport answer.
HERDR_LINEAR_BOARD_READ_PARTIAL=6    # stopped at the page cap or on an unreadable page
HERDR_LINEAR_BOARD_WRITE_REJECTED=7  # Linear answered, and success was not true
HERDR_LINEAR_BOARD_WRITE_SHADOW=8    # the board consent gate refused; logged, nothing sent

HERDR_LINEAR_BOARD_ISSUE_FIELDS='id identifier title updatedAt state { id name type } team { id key } project { id name } projectMilestone { id name } cycle { id } assignee { id name } priority parent { id identifier } labels { nodes { id name parent { id name } } }'

# The program is passed with -c, not on a heredoc: a heredoc takes stdin, and
# the answer verbs read the response from stdin.
HERDR_LINEAR_BOARD_LINEAR_PY="$(cat <<'PYEOF'
import json, os, re, sys

CONTROL = re.compile(r"[\x00-\x1f\x7f-\x9f]")
STATE_TYPES = ("triage", "backlog", "unstarted", "started", "completed", "canceled")
STRING_KEYS = ("team", "project", "milestone", "cycle", "assignee", "state", "parent", "label")
FILTER_KEYS = STRING_KEYS + ("state-type", "state-type-not", "priority")
IDENTIFIER = re.compile(r"^([A-Za-z][A-Za-z0-9]{0,9})-([0-9]{1,9})$")
NULLABLE = ("assigneeId", "projectId", "projectMilestoneId", "cycleId", "parentId")
FIELDS = NULLABLE + ("stateId", "teamId", "priority", "labelGroup")
NONE = "--none"


class Refusal(Exception):
    pass


def shown(v):
    t = json.dumps(v, ensure_ascii=True)
    return t if len(t) <= 80 else t[:77] + "..."


def text(v, where):
    if not isinstance(v, str) or v == "" or CONTROL.search(v):
        raise Refusal("%s holds %s; a value is a non-empty string without control characters" % (where, shown(v)))
    return v


def id_or(field, values):
    return {"or": [{"id": {"in": values}}, {field: {"in": values}}]}


def clause(key, raw):
    values = raw if isinstance(raw, list) else [raw]
    where = "filter key %s" % shown(key)
    if isinstance(raw, list) and not raw:
        raise Refusal("%s is an empty list" % where)
    if key == "priority":
        for p in values:
            if isinstance(p, bool) or not isinstance(p, int) or not 0 <= p <= 4:
                raise Refusal("%s holds %s; a priority is an integer from 0 to 4" % (where, shown(p)))
        return [{"priority": {"in": values}}]
    values = [text(v, where) for v in values]
    if key in ("state-type", "state-type-not"):
        for v in values:
            if v not in STATE_TYPES:
                raise Refusal("%s holds %s; a state type is one of %s" % (where, shown(v), ", ".join(STATE_TYPES)))
        return [{"state": {"type": {"in" if key == "state-type" else "nin": values}}}]
    # A value names the entity by its Linear id or by the handle a person reads
    # on the board. Ids are UUIDs, so the two never collide.
    if key == "team":
        return [{"team": {"or": [{"id": {"in": values}}, {"key": {"in": values}}, {"name": {"in": values}}]}}]
    if key == "project":
        return [{"project": id_or("name", values)}]
    if key == "milestone":
        return [{"projectMilestone": id_or("name", values)}]
    if key == "cycle":
        return [{"cycle": id_or("name", values)}]
    if key == "state":
        return [{"state": id_or("name", values)}]
    if key == "label":
        return [{"labels": {"some": id_or("name", values)}}]
    if key == "assignee":
        alts = []
        if "me" in values:
            alts.append({"isMe": {"eq": True}})
        rest = [v for v in values if v != "me"]
        if rest:
            alts += [{"id": {"in": rest}}, {"name": {"in": rest}},
                     {"displayName": {"in": rest}}, {"email": {"in": rest}}]
        return [{"assignee": alts[0] if len(alts) == 1 else {"or": alts}}]
    if key == "parent":
        # IssueFilter has no identifier comparator; an identifier is a team key
        # and a number.
        alts = []
        ids = [v for v in values if not IDENTIFIER.match(v)]
        if ids:
            alts.append({"id": {"in": ids}})
        for v in values:
            m = IDENTIFIER.match(v)
            if m:
                alts.append({"and": [{"team": {"key": {"eq": m.group(1).upper()}}},
                                     {"number": {"eq": int(m.group(2))}}]})
        return [{"parent": {"or": alts}}]
    raise Refusal("unknown filter key %s" % shown(key))


def issues_body(filter_json, first, after):
    try:
        flt = json.loads(filter_json)
    except ValueError:
        raise Refusal("the filter is not valid JSON")
    if not isinstance(flt, dict) or not flt:
        raise Refusal("the filter is not a non-empty JSON object")
    for k in flt:
        if k not in FILTER_KEYS:
            raise Refusal("unknown filter key %s; allowed: %s" % (shown(k), ", ".join(FILTER_KEYS)))
    clauses = []
    for k in FILTER_KEYS:
        if k in flt:
            clauses += clause(k, flt[k])
    q = ("query BoardIssues($f:IssueFilter,$n:Int,$a:String){issues(first:$n,after:$a,filter:$f){"
         "nodes{%s} pageInfo{hasNextPage endCursor}}}" % os.environ["HERDR_LINEAR_BOARD_ISSUE_FIELDS"])
    return {"query": q, "variables": {"f": {"and": clauses}, "n": first, "a": after or None}}


def write_body(issue, field, value, removed):
    text(issue, "the issue id")
    if field not in FIELDS:
        raise Refusal("field %s is not a board write; allowed: %s" % (shown(field), ", ".join(FIELDS)))
    if field == "labelGroup":
        inp = {}
        if value != NONE:
            inp["addedLabelIds"] = [text(value, "the label to add")]
        if removed is None:
            raise Refusal("a label-group write names the label to remove, or %s" % NONE)
        if removed != NONE:
            inp["removedLabelIds"] = [text(removed, "the label to remove")]
        if not inp:
            raise Refusal("a label-group write that adds and removes nothing is not a write")
    elif field == "priority":
        if value == NONE:
            value = "0"
        if not re.fullmatch(r"[0-4]", value or ""):
            raise Refusal("priority %s is not an integer from 0 to 4" % shown(value))
        inp = {"priority": int(value)}
    elif value == NONE:
        if field not in NULLABLE:
            raise Refusal("%s cannot be cleared; every ticket has one" % field)
        inp = {field: None}
    else:
        inp = {field: text(value, field)}
    q = "mutation BoardFieldWrite($id:String!,$input:IssueUpdateInput!){issueUpdate(id:$id,input:$input){success}}"
    return {"query": q, "variables": {"id": issue, "input": inp}}


def main():
    verb, args = sys.argv[1], sys.argv[2:]
    try:
        if verb == "issues-body":
            print(json.dumps(issues_body(args[0], int(args[1]), args[2] if len(args) > 2 else "")))
            return 0
        if verb == "write-body":
            if len(args) < 3:
                raise Refusal("a board write names an issue id, a field and a value or --none")
            print(json.dumps(write_body(args[0], args[1], args[2], args[3] if len(args) > 3 else None)))
            return 0
    except Refusal as r:
        sys.stderr.write("board Linear call refused: %s; nothing was sent\n" % r)
        return 5
    if verb == "page":
        # stdin: one page's answer. stdout: nodes JSON, then hasNextPage, then cursor.
        try:
            conn = json.load(sys.stdin)["data"]["issues"]
            nodes, info = conn["nodes"], conn["pageInfo"]
            assert isinstance(nodes, list)
        except Exception:
            return 1
        print(json.dumps(nodes))
        print("1" if info.get("hasNextPage") is True else "0")
        print(info.get("endCursor") or "")
        return 0
    if verb == "success":
        try:
            ok = json.load(sys.stdin)["data"]["issueUpdate"]["success"]
        except Exception:
            return 1
        return 0 if ok is True else 1
    if verb == "first-state":
        try:
            states = json.load(sys.stdin)["data"]["team"]["states"]["nodes"]
        except Exception:
            return 1
        cands = [s for s in states if s.get("type") == args[0]
                 and isinstance(s.get("position"), (int, float)) and s.get("id")]
        if not cands:
            return 2
        sys.stdout.write(min(cands, key=lambda s: s["position"])["id"])
        return 0
    if verb == "result":
        # argv: complete flag, then one file per page of nodes.
        tickets = []
        for path in args[1:]:
            with open(path) as fh:
                tickets += json.load(fh)
        print(json.dumps({"complete": args[0] == "1", "tickets": tickets}))
        return 0
    return 5


sys.exit(main())
PYEOF
)"

# herdr_linear::_board_linear_py <verb> [args...]
# Every value arrives as an argument or on stdin, never spliced into code.
herdr_linear::_board_linear_py() {
    HERDR_LINEAR_BOARD_ISSUE_FIELDS="$HERDR_LINEAR_BOARD_ISSUE_FIELDS" \
        python3 -c "$HERDR_LINEAR_BOARD_LINEAR_PY" "$@"
}

# herdr_linear::board_issues <filter-json>
#
# Reads every ticket the resolved filter from `board_mapping_for`
# matches. Always prints {"complete": bool, "tickets": [...]}.
# Exit 0 only when every page was read. Otherwise the tickets read so far are
# printed with complete false, and the exit is the failing page's linear.sh code
# (UNAVAILABLE, NOT_FOUND, AUTH, RATELIMITED), BOARD_READ_PARTIAL for a page cap
# or an unreadable page, or REFUSED for a filter key outside the contract, in
# which case nothing was sent.
herdr_linear::board_issues() {
    local filter="${1-}" body resp rc parsed more cursor="" pages=0 complete=0 tmp
    tmp="$(mktemp -d)" || return "$HERDR_LINEAR_UNAVAILABLE"
    rc="$HERDR_LINEAR_BOARD_READ_PARTIAL"
    while [ "$pages" -lt "$HERDR_LINEAR_BOARD_MAX_PAGES" ]; do
        body="$(herdr_linear::_board_linear_py issues-body "$filter" "$HERDR_LINEAR_BOARD_PAGE_SIZE" "$cursor")" \
            || { rc="$HERDR_LINEAR_REFUSED"; break; }
        resp="$(herdr_linear::query "$body")" || { rc=$?; break; }
        parsed="$(printf '%s' "$resp" | herdr_linear::_board_linear_py page)" \
            || { rc="$HERDR_LINEAR_BOARD_READ_PARTIAL"; break; }
        pages=$((pages + 1))
        sed -n 1p <<< "$parsed" > "$tmp/$(printf '%06d' "$pages")"
        more="$(sed -n 2p <<< "$parsed")"
        if [ "$more" != 1 ]; then complete=1; rc=0; break; fi
        cursor="$(sed -n 3p <<< "$parsed")"
        # A next page with no cursor would re-read page one forever.
        [ -n "$cursor" ] || { rc="$HERDR_LINEAR_BOARD_READ_PARTIAL"; break; }
    done
    herdr_linear::_board_linear_py result "$complete" "$tmp"/[0-9]* 2>/dev/null \
        || herdr_linear::_board_linear_py result 0
    rm -rf "$tmp"
    return "$rc"
}

# herdr_linear::board_write_field <issue-id> <field> <value|--none> [<removed-label-id|--none>]
#
# CALLERS MUST PASS THE BOARD CONSENT GATE FIRST. This helper sends the write it
# is given; it does not check shadow mode, consent or the board's write bound
# (KTD8). Calling it without that gate writes Linear with shadow mode on.
#
# <field> is stateId, assigneeId, projectId, projectMilestoneId, cycleId,
# priority, parentId, teamId or labelGroup. --none is the "No <level>" target:
# an explicit null on a nullable field, priority 0, and refused for stateId and
# teamId. labelGroup takes the label to add and the ticket's current label in
# that group, either one --none; it sends addedLabelIds/removedLabelIds, never
# labelIds, so a concurrent label edit elsewhere is not overwritten.
# Exit 0 when Linear answered success true; REFUSED before any request for an
# empty string, unknown field or bad value; BOARD_WRITE_REJECTED when success
# was not true; otherwise the linear.sh transport code.
herdr_linear::board_write_field() {
    local body resp rc
    body="$(herdr_linear::_board_linear_py write-body "$@")" || return "$HERDR_LINEAR_REFUSED"
    resp="$(herdr_linear::query "$body")"; rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    printf '%s' "$resp" | herdr_linear::_board_linear_py success \
        || return "$HERDR_LINEAR_BOARD_WRITE_REJECTED"
    return "$HERDR_LINEAR_OK"
}

herdr_linear::_board_first_state() {
    local team="${1-}" type="$2" body resp rc
    [ -n "$team" ] || return "$HERDR_LINEAR_REFUSED"
    body="$(python3 -c '
import sys, json
q = "query BoardTeamStates($id:String!){team(id:$id){states{nodes{id name type position}}}}"
print(json.dumps({"query": q, "variables": {"id": sys.argv[1]}}))
' "$team")" || return "$HERDR_LINEAR_UNAVAILABLE"
    resp="$(herdr_linear::query "$body")"; rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    printf '%s' "$resp" | herdr_linear::_board_linear_py first-state "$type"; rc=$?
    case "$rc" in
        0) return "$HERDR_LINEAR_OK" ;;
        2) return "$HERDR_LINEAR_NOT_FOUND" ;;
        *) return "$HERDR_LINEAR_UNAVAILABLE" ;;
    esac
}

# herdr_linear::board_first_unstarted_state <team-id>
# Prints the id of the team's unstarted state with the lowest position (R34).
# NOT_FOUND when the team has none; REFUSED for an empty team id.
herdr_linear::board_first_unstarted_state() {
    herdr_linear::_board_first_state "${1-}" unstarted
}

# herdr_linear::board_completed_state <team-id>
# The same lookup for the team's completed state.
herdr_linear::board_completed_state() {
    herdr_linear::_board_first_state "${1-}" completed
}

# herdr_linear::board_complete_gate <space> <issue-id> <completed-state-id>
#   0  the space consented to state writes and the ticket is in the last
#      complete filter read
#   1  refused; exactly one shadow log line names every failed fact
#
# Not board_consent_gate: that gate also requires the target to be a group the
# board rendered, which protects a move whose value comes from the layout. A
# completion's value is looked up by the plugin, and most boards render no
# completed group, so that bound would refuse completion everywhere (R28).
herdr_linear::board_complete_gate() {
    local space="${1-}" issue="${2-}" completed="${3-}" consented=1 sync line
    herdr_linear::board_consent_covers "$space" state && consented=0
    sync="$(herdr_linear::board_sync_state 2>/dev/null)" || sync=""
    line="$(printf '%s' "$sync" | python3 -c '
import json, sys
consented, space, issue, completed = sys.argv[1:5]
reasons = []
if consented != "0":
    reasons.append("no consent for state writes in this space")
try:
    rec = json.load(sys.stdin)
    assert isinstance(rec, dict) and rec.get("last_complete_sync_at")
except Exception:
    reasons.append("no complete filter read is recorded")
else:
    if not issue or issue not in (rec.get("members") or []):
        reasons.append("ticket is not in the last complete filter read")
if not reasons:
    sys.exit(0)
sys.stdout.write("SHADOW board would complete %s (state %s) in %s: %s" % (
    json.dumps(issue), json.dumps(completed), json.dumps(space), "; ".join(reasons)))
sys.exit(1)
' "$consented" "$space" "$issue" "$completed")" && return 0
    [ -n "$line" ] || line="SHADOW board would complete a ticket: the gate could not evaluate its facts"
    herdr_linear::_shadow_log "$line"
    return 1
}

# herdr_linear::board_complete <space> <issue-id> <team-id>
#
# R28. Moves a board ticket to its team's completed state. It needs no worktree:
# the write is keyed by issue id and allowed by board_complete_gate, not by a
# binding's consent record.
# Exit 0 written; BOARD_WRITE_SHADOW when the gate refused (one shadow log line,
# nothing sent); NOT_FOUND when the team has no completed state; otherwise
# board_write_field's code.
herdr_linear::board_complete() {
    local space="${1-}" issue="${2-}" team="${3-}" completed rc
    completed="$(herdr_linear::board_completed_state "$team")" || return $?
    herdr_linear::board_complete_gate "$space" "$issue" "$completed" \
        || return "$HERDR_LINEAR_BOARD_WRITE_SHADOW"
    herdr_linear::board_write_field "$issue" stateId "$completed"; rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    # The write happened; a store that cannot record it must not report a failed write.
    herdr_linear::board_record_linear_write >/dev/null 2>&1 || true
    return "$HERDR_LINEAR_OK"
}
