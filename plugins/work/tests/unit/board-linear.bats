#!/usr/bin/env bats

load setup_common

# U4 — the board's Linear reads and its one field write.
#
# No Linear object is created or modified here. fake-linear.sh refuses every
# mutation with exit 97 unless a test sets FAKE_LINEAR_ALLOW_MUTATION=1, and
# only the write tests do.

bats_require_minimum_version 1.5.0

setup() {
    ROOT="${BATS_TEST_DIRNAME}/../.."
    FIX="${BATS_TEST_DIRNAME}/../fixtures"
    WORK="$(mktemp -d)"

    export HERDR_LINEAR_CURL_BIN="$FIX/fake-linear.sh"
    export HERDR_LINEAR_SECURITY_BIN="$FIX/fake-security.sh"
    export FAKE_SECURITY_STORE_DIR="$WORK/kc"
    export FAKE_LINEAR_RECORD_DIR="$WORK/rec"
    export LINEAR_SECRETS_FILE="$WORK/secrets"
    export HERDR_LINEAR_RETRY_MAX=1
    mkdir -p "$WORK/rec"
    printf 'LINEAR_API_KEY=%s\n' "lin_api""_BOARDBOARDBOARDBOARD" > "$LINEAR_SECRETS_FILE"

    # shellcheck source=/dev/null
    for f in sanitize.sh secrets.sh linear.sh board-linear.sh; do . "$ROOT/lib/$f"; done

    FILTER='{"team":["WEB","acme-api"],"assignee":"me","priority":[1,2],"state-type-not":["triage","backlog"]}'
}

teardown() { [ -n "${WORK:-}" ] && rm -rf "$WORK"; }

bodies_named() {
    local n; n="$(grep -c "$1" "$FAKE_LINEAR_RECORD_DIR/bodies" 2>/dev/null)" || n=0
    printf '%s' "${n:-0}"
}

# Prints the last recorded body carrying $1, as JSON.
last_body() { grep "$1" "$FAKE_LINEAR_RECORD_DIR/bodies" | tail -1; }

# ----------------------------------------------------------------- the read

@test "a three-page result returns every ticket and the complete flag set" {
    export FAKE_LINEAR_BOARD_PAGES=3
    run --separate-stderr herdr_linear::board_issues "$FILTER"
    [ "$status" -eq 0 ]
    [ "$(bodies_named BoardIssues)" -eq 3 ]
    printf '%s' "$output" | python3 -c '
import sys, json
d = json.load(sys.stdin)
assert d["complete"] is True, d
ids = [t["identifier"] for t in d["tickets"]]
assert ids == ["WEB-5001", "WEB-5002", "WEB-5003", "WEB-5004", "WEB-5005", "WEB-5006"], ids
assert "cursor" not in d and "endCursor" not in json.dumps(d), d
t = d["tickets"][0]
for k in ("id", "identifier", "title", "state", "team", "project", "projectMilestone",
          "cycle", "assignee", "priority", "parent", "labels"):
    assert k in t, k
assert t["labels"]["nodes"][0]["parent"]["name"] == "Type", t
'
}

@test "a rate limit on page two returns the first page with the complete flag unset" {
    export FAKE_LINEAR_BOARD_PAGES=3 FAKE_LINEAR_BOARD_FAIL_AT=2
    run --separate-stderr herdr_linear::board_issues "$FILTER"
    [ "$status" -eq "$HERDR_LINEAR_RATELIMITED" ]
    printf '%s' "$output" | python3 -c '
import sys, json
d = json.load(sys.stdin)
assert d["complete"] is False, d
assert [t["identifier"] for t in d["tickets"]] == ["WEB-5001", "WEB-5002"], d
'
    [ "$(bodies_named BoardIssues)" -eq 2 ]
}

@test "an unreadable page two returns the first page with the complete flag unset" {
    export FAKE_LINEAR_BOARD_PAGES=3 FAKE_LINEAR_BOARD_FAIL_AT=2 FAKE_LINEAR_BOARD_FAIL_MODE=no_connection
    run --separate-stderr herdr_linear::board_issues "$FILTER"
    [ "$status" -eq "$HERDR_LINEAR_BOARD_READ_PARTIAL" ]
    printf '%s' "$output" | python3 -c '
import sys, json
d = json.load(sys.stdin)
assert d["complete"] is False, d
assert [t["identifier"] for t in d["tickets"]] == ["WEB-5001", "WEB-5002"], d
'
}

@test "an error on the first page reports nothing read and the complete flag unset" {
    export FAKE_LINEAR_BOARD_PAGES=2 FAKE_LINEAR_BOARD_FAIL_AT=1 FAKE_LINEAR_BOARD_FAIL_MODE=auth_error
    run --separate-stderr herdr_linear::board_issues "$FILTER"
    [ "$status" -eq "$HERDR_LINEAR_AUTH" ]
    printf '%s' "$output" | python3 -c '
import sys, json
d = json.load(sys.stdin)
assert d == {"complete": False, "tickets": []}, d
'
}

@test "a cursor that never advances stops at the page cap with the complete flag unset" {
    export FAKE_LINEAR_BOARD_CURSOR=stuck HERDR_LINEAR_BOARD_MAX_PAGES=4
    run --separate-stderr herdr_linear::board_issues "$FILTER"
    [ "$status" -eq "$HERDR_LINEAR_BOARD_READ_PARTIAL" ]
    printf '%s' "$output" | python3 -c '
import sys, json
assert json.load(sys.stdin)["complete"] is False
'
    [ "$(bodies_named BoardIssues)" -eq 4 ]
}

@test "the request body carries an explicit first and the filter keys from the configuration" {
    export HERDR_LINEAR_BOARD_PAGE_SIZE=25
    run --separate-stderr herdr_linear::board_issues \
        '{"team":["WEB","acme-api"],"project":"AI Canvas Tools","milestone":"M1","cycle":"c-1","assignee":"me","state":"Todo","parent":"WEB-2870","label":["Bug"],"state-type":["unstarted","started"],"priority":[1,2],"state-type-not":["triage","backlog"]}'
    [ "$status" -eq 0 ]
    last_body BoardIssues | python3 -c '
import sys, json
b = json.load(sys.stdin)
v = b["variables"]
assert v["n"] == 25, v
assert "a" in v and v["a"] is None, v
assert "first:$n" in b["query"] and "after:$a" in b["query"], b["query"]
clauses = v["f"]["and"]
flat = json.dumps(clauses)
keys = set()
for c in clauses:
    keys.update(c.keys())
for k in ("team", "project", "projectMilestone", "cycle", "assignee", "state", "parent", "labels", "priority"):
    assert k in keys, (k, keys)
assert {"assignee": {"isMe": {"eq": True}}} in clauses, clauses
assert {"priority": {"in": [1, 2]}} in clauses, clauses
assert {"state": {"type": {"in": ["unstarted", "started"]}}} in clauses, clauses
assert {"state": {"type": {"nin": ["triage", "backlog"]}}} in clauses, clauses
team = [c for c in clauses if "team" in c][0]["team"]
assert {"key": {"in": ["WEB", "acme-api"]}} in team["or"], team
parent = [c for c in clauses if "parent" in c][0]["parent"]
assert {"and": [{"team": {"key": {"eq": "WEB"}}}, {"number": {"eq": 2870}}]} in parent["or"], parent
'
}

@test "a filter key outside the resolved filter contract is refused before any request" {
    run --separate-stderr herdr_linear::board_issues '{"team":"WEB","estimate":3}'
    [ "$status" -eq "$HERDR_LINEAR_REFUSED" ]
    [[ "$stderr" == *'"estimate"'* ]]
    [ "$(bodies_named BoardIssues)" -eq 0 ]
}

@test "a filter holding an empty string is refused before any request" {
    run --separate-stderr herdr_linear::board_issues '{"team":["WEB",""]}'
    [ "$status" -eq "$HERDR_LINEAR_REFUSED" ]
    [ "$(bodies_named BoardIssues)" -eq 0 ]
}

# ---------------------------------------------------------------- the write

@test "a label-group write sends addedLabelIds and removedLabelIds and never labelIds" {
    export FAKE_LINEAR_ALLOW_MUTATION=1
    run --separate-stderr herdr_linear::board_write_field "issue-uuid-1" labelGroup "lbl-new" "lbl-old"
    [ "$status" -eq 0 ]
    last_body issueUpdate | python3 -c '
import sys, json
b = json.load(sys.stdin)
i = b["variables"]["input"]
assert i == {"addedLabelIds": ["lbl-new"], "removedLabelIds": ["lbl-old"]}, i
assert b["variables"]["id"] == "issue-uuid-1", b
assert "labelIds" not in i
'
}

@test "moving a ticket to No <group> removes only its current label" {
    export FAKE_LINEAR_ALLOW_MUTATION=1
    run --separate-stderr herdr_linear::board_write_field "issue-uuid-1" labelGroup --none "lbl-old"
    [ "$status" -eq 0 ]
    last_body issueUpdate | python3 -c '
import sys, json
i = json.load(sys.stdin)["variables"]["input"]
assert i == {"removedLabelIds": ["lbl-old"]}, i
'
}

@test "a No <level> target on a nullable field sends an explicit null" {
    export FAKE_LINEAR_ALLOW_MUTATION=1
    run --separate-stderr herdr_linear::board_write_field "issue-uuid-1" projectId --none
    [ "$status" -eq 0 ]
    last_body issueUpdate | python3 -c '
import sys, json
i = json.load(sys.stdin)["variables"]["input"]
assert "projectId" in i and i["projectId"] is None, i
assert list(i) == ["projectId"], i
'
}

@test "a No <level> target on state or team is refused before any request" {
    export FAKE_LINEAR_ALLOW_MUTATION=1
    for field in stateId teamId; do
        run --separate-stderr herdr_linear::board_write_field "issue-uuid-1" "$field" --none
        [ "$status" -eq "$HERDR_LINEAR_REFUSED" ]
    done
    [ "$(bodies_named issueUpdate)" -eq 0 ]
}

@test "No priority is written as priority 0" {
    export FAKE_LINEAR_ALLOW_MUTATION=1
    run --separate-stderr herdr_linear::board_write_field "issue-uuid-1" priority --none
    [ "$status" -eq 0 ]
    last_body issueUpdate | python3 -c '
import sys, json
i = json.load(sys.stdin)["variables"]["input"]
assert i == {"priority": 0}, i
'
}

@test "a set value is sent under its field name" {
    export FAKE_LINEAR_ALLOW_MUTATION=1
    run --separate-stderr herdr_linear::board_write_field "issue-uuid-1" assigneeId "user-uuid-2"
    [ "$status" -eq 0 ]
    last_body issueUpdate | python3 -c '
import sys, json
i = json.load(sys.stdin)["variables"]["input"]
assert i == {"assigneeId": "user-uuid-2"}, i
'
}

# FAKE_LINEAR_ALLOW_MUTATION stays unset: a request that got through would come
# back as 97, which the lib reports as UNAVAILABLE, never as REFUSED.
@test "an empty target value is refused before any request is sent" {
    run --separate-stderr herdr_linear::board_write_field "issue-uuid-1" assigneeId ""
    [ "$status" -eq "$HERDR_LINEAR_REFUSED" ]
    run --separate-stderr herdr_linear::board_write_field "issue-uuid-1" labelGroup "" "lbl-old"
    [ "$status" -eq "$HERDR_LINEAR_REFUSED" ]
    run --separate-stderr herdr_linear::board_write_field "" assigneeId "user-uuid-2"
    [ "$status" -eq "$HERDR_LINEAR_REFUSED" ]
    [ "$(bodies_named issueUpdate)" -eq 0 ]
}

@test "an unknown field, a bad priority and an empty label swap are refused before any request" {
    run --separate-stderr herdr_linear::board_write_field "issue-uuid-1" labelIds "lbl-new"
    [ "$status" -eq "$HERDR_LINEAR_REFUSED" ]
    run --separate-stderr herdr_linear::board_write_field "issue-uuid-1" priority 7
    [ "$status" -eq "$HERDR_LINEAR_REFUSED" ]
    run --separate-stderr herdr_linear::board_write_field "issue-uuid-1" labelGroup --none --none
    [ "$status" -eq "$HERDR_LINEAR_REFUSED" ]
    [ "$(bodies_named issueUpdate)" -eq 0 ]
}

@test "a response with success false is reported as a failed write" {
    export FAKE_LINEAR_ALLOW_MUTATION=1 FAKE_LINEAR_MUTATION_RESULT=fail
    run --separate-stderr herdr_linear::board_write_field "issue-uuid-1" cycleId "cycle-uuid-3"
    [ "$status" -eq "$HERDR_LINEAR_BOARD_WRITE_REJECTED" ]
    [ "$(bodies_named issueUpdate)" -eq 1 ]
}

# ------------------------------------------------------ first unstarted state

@test "the first-unstarted-state lookup picks the lowest-position unstarted state" {
    run --separate-stderr herdr_linear::board_first_unstarted_state "55555555-5555-4555-8555-555555555555"
    [ "$status" -eq 0 ]
    [ "$output" = "st-ready" ]
    last_body BoardTeamStates | python3 -c '
import sys, json
b = json.load(sys.stdin)
assert b["variables"]["id"] == "55555555-5555-4555-8555-555555555555", b
assert "position" in b["query"], b
'
}

@test "a team with no unstarted state answers not found" {
    export FAKE_LINEAR_BOARD_STATES=none
    run --separate-stderr herdr_linear::board_first_unstarted_state "55555555-5555-4555-8555-555555555555"
    [ "$status" -eq "$HERDR_LINEAR_NOT_FOUND" ]
    [ -z "$output" ]
}
