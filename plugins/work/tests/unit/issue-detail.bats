#!/usr/bin/env bats

load setup_common

# bin/work-issue.sh -- one issue in full, for the board's issue page.
#
# Nothing here reaches Linear. The curl stand-in answers the detail query from
# tests/fixtures/fake-linear.sh, pruned to the fields the query selected.

bats_require_minimum_version 1.5.0

setup() {
    ROOT="${BATS_TEST_DIRNAME}/../.."
    FIX="${BATS_TEST_DIRNAME}/../fixtures"
    WORK="$(mktemp -d)"
    export HERDR_LINEAR_STORE_DIR="$WORK/store"
    export HERDR_LINEAR_PIN_DIR="$WORK/pin"
    export HERDR_LINEAR_CURL_BIN="$FIX/fake-linear.sh"
    export HERDR_LINEAR_SECURITY_BIN="$FIX/fake-security.sh"
    export FAKE_SECURITY_STORE_DIR="$WORK/kc"
    export FAKE_LINEAR_RECORD_DIR="$WORK/rec"
    export LINEAR_CACHE_DIR="$WORK/cache"
    export LINEAR_SECRETS_FILE="$WORK/secrets"
    export HERDR_LINEAR_RETRY_BASE_MS=1
    mkdir -p "$WORK/rec" "$WORK/cache"
    printf 'LINEAR_API_KEY=%s\n' "lin_api""_ISSUEISSUEISSUEISSUE" > "$LINEAR_SECRETS_FILE"
}

teardown() { [ -n "${WORK:-}" ] && rm -rf "$WORK"; }

field() {   # field <json> <python-expression over `d`>
    printf '%s' "$1" | python3 -c "import sys,json;d=json.load(sys.stdin);print($2)"
}

@test "a full issue carries every section the page shows" {
    run -0 "$ROOT/bin/work-issue.sh" WEB-3318
    [ "$(field "$output" 'd["status"]')" = ok ]
    [ "$(field "$output" 'd["schema"]')" = 1 ]
    [ "$(field "$output" 'd["issue"]["identifier"]')" = WEB-3318 ]
    [ "$(field "$output" 'd["issue"]["estimate"]')" = 3 ]
    [ "$(field "$output" 'd["issue"]["due_date"]')" = 2026-09-30 ]
    [ "$(field "$output" 'd["issue"]["milestone"]["name"]')" = M2 ]
    [ "$(field "$output" 'd["issue"]["cycle"]["name"]')" = "Cycle 14" ]
    [ "$(field "$output" 'len(d["issue"]["children"])')" = 2 ]
    [ "$(field "$output" 'len(d["issue"]["comments"])')" = 2 ]
    [[ "$(field "$output" 'd["issue"]["description"]')" == *"## What happens"* ]]
}

# R9 -- every linked row opens its own page, so each needs the identifier, title
# and status the page's header shows. The parent is the one that has to merge two
# selections to get there, so it is asserted by name.
@test "every linked issue row carries identifier, title and status" {
    run -0 "$ROOT/bin/work-issue.sh" WEB-3318
    local rows='[d["issue"]["parent"]] + d["issue"]["children"] + [r["issue"] for r in d["issue"]["relations"]]'
    [ "$(field "$output" "all(r.get(k) for r in $rows for k in (\"id\", \"identifier\", \"title\"))")" = True ]
    [ "$(field "$output" "all((r.get(\"state\") or {}).get(\"name\") for r in $rows)")" = True ]
}

# Linear draws both directions of a relation on one page, so both are read; the
# direction is what tells "blocks" from "blocked by".
@test "relations carry both directions" {
    run -0 "$ROOT/bin/work-issue.sh" WEB-3318
    [ "$(field "$output" 'sorted(r["direction"] for r in d["issue"]["relations"])')" = "['inward', 'outward']" ]
}

@test "a comment reply names its parent comment" {
    run -0 "$ROOT/bin/work-issue.sh" WEB-3318
    [ "$(field "$output" 'd["issue"]["comments"][0]["parent_id"]')" = None ]
    [ "$(field "$output" 'd["issue"]["comments"][1]["parent_id"]')" = cm1 ]
}

# A history row Linear returns for a field the board does not show has nothing
# the page could phrase; keeping it would print a blank timeline entry.
@test "history keeps only rows that changed something the page shows" {
    run -0 "$ROOT/bin/work-issue.sh" WEB-3318
    [ "$(field "$output" 'len(d["issue"]["history"])')" = 2 ]
    [ "$(field "$output" 'd["issue"]["history"][0]["to_state"]')" = "In Progress" ]
    [ "$(field "$output" 'd["issue"]["history"][1]["added_labels"]')" = "['Bug']" ]
}

# R4 -- the board draws an empty marker for a property with no value, so an
# absent one must arrive as null, never as an error or a missing key.
@test "an issue with nothing set prints nulls, not an error" {
    FAKE_LINEAR_DETAIL=bare run -0 "$ROOT/bin/work-issue.sh" WEB-3318
    [ "$(field "$output" 'd["status"]')" = ok ]
    for key in description due_date estimate milestone cycle parent; do
        [ "$(field "$output" "d[\"issue\"][\"$key\"]")" = None ]
    done
    for key in children relations comments history labels; do
        [ "$(field "$output" "d[\"issue\"][\"$key\"]")" = "[]" ]
    done
}

# R8a -- the read is one Linear call whatever the thread length, so what did not
# fit is named rather than drained.
@test "a connection past its page cap reports partial and names what was cut" {
    FAKE_LINEAR_DETAIL=partial run -0 "$ROOT/bin/work-issue.sh" WEB-3318
    [ "$(field "$output" 'd["status"]')" = partial ]
    [ "$(field "$output" 'sorted(d["truncated"])')" = "['children', 'comments', 'history', 'relations']" ]
    [[ "$(field "$output" 'd["message"]')" == *"the rest is in Linear"* ]]
}

# R8a -- the page cap exists so the read stays one call whatever the thread
# length; a drained connection would make a busy issue cost many.
@test "the whole read is a single Linear call" {
    run -0 "$ROOT/bin/work-issue.sh" WEB-3318
    [ "$(wc -l < "$WORK/rec/bodies" | tr -d ' ')" = 1 ]
}

@test "a refused argument exits 2 with nothing on stdout" {
    run -2 "$ROOT/bin/work-issue.sh" "../etc/passwd"
    [ -z "$output" ]
    run -2 "$ROOT/bin/work-issue.sh" ""
    [ -z "$output" ]
    run -2 "$ROOT/bin/work-issue.sh" "-oProxyCommand=x"
    [ -z "$output" ]
}

@test "no credential is unavailable, not a crash" {
    rm -f "$LINEAR_SECRETS_FILE"
    run -0 "$ROOT/bin/work-issue.sh" WEB-3318
    [ "$(field "$output" 'd["status"]')" = unavailable ]
    [ "$(field "$output" 'd["issue"]')" = None ]
    [[ "$(field "$output" 'd["message"]')" == *"no Linear credential"* ]]
}

@test "Linear refusing the credential is named as such" {
    FAKE_LINEAR_MODE=auth_error run -0 "$ROOT/bin/work-issue.sh" WEB-3318
    [ "$(field "$output" 'd["status"]')" = unavailable ]
    [ "$(field "$output" 'd["issue"]')" = None ]
}

@test "an unreachable Linear is named as such" {
    FAKE_LINEAR_OUTAGE=http_500 run -0 "$ROOT/bin/work-issue.sh" WEB-3318
    [ "$(field "$output" 'd["status"]')" = unavailable ]
    [ "$(field "$output" 'd["issue"]')" = None ]
}

# The board reads this document out of a pipe; a display-control character in a
# comment body would reach a terminal that renders it.
@test "display controls are stripped from every string in the document" {
    run -0 "$ROOT/bin/work-issue.sh" WEB-3318
    ! printf '%s' "$output" | grep -q "$(printf '\033')"
    ! printf '%s' "$output" | grep -q "$(printf '\342\200\256')"
}
