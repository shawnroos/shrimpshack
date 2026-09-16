#!/usr/bin/env bats

load setup_common

# U8 — bin/work-projects.sh, the Linear projects the person is a member of.
#
# The fake applies the request's own membership filter to a pool that holds a
# project the person is not a member of, so a client that dropped the filter
# lists it and the AE5 test turns red.

bats_require_minimum_version 1.5.0

setup() {
    ROOT="${BATS_TEST_DIRNAME}/../.."
    BIN="$ROOT/bin/work-projects.sh"
    FIX="${BATS_TEST_DIRNAME}/../fixtures"
    WORK="$(cd "$(mktemp -d)" && pwd -P)"

    export HERDR_LINEAR_CURL_BIN="$FIX/fake-linear.sh"
    export FAKE_LINEAR_RECORD_DIR="$WORK/rec"
    export LINEAR_CACHE_DIR="$WORK/cache"
    export LINEAR_SECRETS_FILE="$WORK/secrets"
    export HERDR_LINEAR_RETRY_BASE_MS=1
    mkdir -p "$FAKE_LINEAR_RECORD_DIR" "$LINEAR_CACHE_DIR"
    printf 'LINEAR_API_KEY=%s\n' "lin_api""_PROJPROJPROJPROJPROJ" > "$LINEAR_SECRETS_FILE"

    NOT_MEMBER=99999999-9999-4999-8999-999999999999
}

teardown() { [ -n "${WORK:-}" ] && rm -rf "$WORK"; }

field() {   # field <python-expression over d> -- reads $output as JSON
    printf '%s' "$output" | python3 -c "import sys,json;d=json.load(sys.stdin);print($1)"
}

@test "the person's projects list ids, names and team keys, and a project they are not a member of is absent" {
    run --separate-stderr bash "$BIN"
    [ "$status" -eq 0 ]
    [ "$(field 'd["status"]')" = ok ]
    [ "$(field 'json.dumps(d["rows"], sort_keys=True)')" = '[{"id": "44444444-4444-4444-8444-444444444444", "name": "Example Project Alpha", "team_key": "EXA"}, {"id": "a1a1a1a1-a1a1-4a1a-8a1a-a1a1a1a1a1a1", "name": "Example Project Beta", "team_key": "EXB"}, {"id": "b2b2b2b2-b2b2-4b2b-8b2b-b2b2b2b2b2b2", "name": "Example Project Gamma", "team_key": null}]' ]
    [[ "$output" != *"$NOT_MEMBER"* ]]
}

@test "a second page is followed" {
    FAKE_LINEAR_PROJECTS=paged run --separate-stderr bash "$BIN"
    [ "$status" -eq 0 ]
    [ "$(field 'd["status"]')" = ok ]
    [ "$(field 'len(d["rows"])')" = 3 ]
    [ "$(wc -l < "$FAKE_LINEAR_RECORD_DIR/bodies" | tr -d ' ')" = 2 ]
}

@test "the page cap reports partial and keeps the rows it read" {
    FAKE_LINEAR_PROJECTS=capped HERDR_LINEAR_VIEW_PAGE_MAX=2 run --separate-stderr bash "$BIN"
    [ "$status" -eq 0 ]
    [ "$(field 'd["status"]')" = partial ]
    [ "$(field 'len(d["rows"]) > 0')" = True ]
    [ -n "$(field 'd["message"] or ""')" ]
    [ "$(wc -l < "$FAKE_LINEAR_RECORD_DIR/bodies" | tr -d ' ')" = 2 ]
}

@test "no memberships is ok with no rows, not a failure" {
    FAKE_LINEAR_PROJECTS=empty run --separate-stderr bash "$BIN"
    [ "$status" -eq 0 ]
    [ "$(field 'd["status"], d["rows"], d["message"]')" = "ok [] None" ]
}

@test "a missing credential reports unavailable rather than an empty list, and sends nothing" {
    rm -f "$LINEAR_SECRETS_FILE"
    run --separate-stderr bash "$BIN"
    [ "$status" -eq 0 ]
    [ "$(field 'd["status"], d["rows"]')" = "unavailable []" ]
    [[ "$(field 'd["message"]')" == *credential* ]]
    [ ! -e "$FAKE_LINEAR_RECORD_DIR/bodies" ]
}

@test "a refused credential is distinguished from an unreachable API" {
    FAKE_LINEAR_OUTAGE=auth_error run --separate-stderr bash "$BIN"
    [ "$status" -eq 0 ]
    [ "$(field 'd["status"], d["rows"]')" = "unavailable []" ]
    refused="$(field 'd["message"]')"
    FAKE_LINEAR_OUTAGE=http_500 run --separate-stderr bash "$BIN"
    [ "$status" -eq 0 ]
    [ "$(field 'd["status"], d["rows"]')" = "unavailable []" ]
    unreachable="$(field 'd["message"]')"
    [[ "$refused" == *refused* ]]
    [[ "$unreachable" == *reach* ]]
    [ "$refused" != "$unreachable" ]
}

@test "a project name carrying a newline, an escape or a bidi override is sanitised" {
    FAKE_LINEAR_PROJECTS=hostile run --separate-stderr bash "$BIN"
    [ "$status" -eq 0 ]
    [ "$(field 'd["status"]')" = ok ]
    [ "$(field 'any(c in r["name"] for r in d["rows"] for c in "\n\r\t\x1b\u202e\u2028")')" = False ]
    [ "$(field '[r["name"] for r in d["rows"]]')" = "['Example Project[31m Alpha']" ]
}

@test "the credential reaches curl on stdin and the request carries the membership filter" {
    run --separate-stderr bash "$BIN"
    [ "$status" -eq 0 ]
    grep -qx yes "$FAKE_LINEAR_RECORD_DIR/auth_on_stdin"
    [ "$(grep -c 'lin_api_' "$FAKE_LINEAR_RECORD_DIR/argv")" -eq 0 ]
    python3 -c '
import sys, json
b = json.loads(open(sys.argv[1]).readline())
assert "$filter:ProjectFilter" in b["query"], b["query"]
assert b["variables"]["filter"] == {"members": {"some": {"isMe": {"eq": True}}}}, b["variables"]
' "$FAKE_LINEAR_RECORD_DIR/bodies"
}

@test "an argument is refused with 2 and nothing on stdout" {
    run --separate-stderr bash "$BIN" extra
    [ "$status" -eq 2 ]
    [ -z "$output" ]
}

@test "the committed shapes file passes the secret and brand scans and carries no id or address" {
    local shapes="$ROOT/tests/probe/projects-shapes.md"
    [ -s "$shapes" ]
    # shellcheck source=/dev/null
    . "$ROOT/tests/run-tests.sh"
    scan_paths "$shapes"
    [ "$(grep -cE "$BRAND_PATTERN" "$shapes")" -eq 0 ]
    [ "$(grep -ciE '[0-9a-f]{8}-[0-9a-f]{4}-|@[a-z0-9-]+\.[a-z]|lin_api' "$shapes")" -eq 0 ]
}
