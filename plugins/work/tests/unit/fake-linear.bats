#!/usr/bin/env bats
# U13 — the captured Linear response shapes, and the two boundaries the
# curl-substitute fixture enforces.
#
# The fixture stands in for curl rather than for the API, because the claim
# worth testing is about the INVOCATION: KTD9 says the credential travels on
# stdin via `--config -` and never on argv. Only something in curl's position
# can see argv and fail the run.
#
# These tests exist ahead of U5's client for one reason. Twice in this build a
# fixture was more permissive than the thing it stood in for, and each time the
# gap swallowed a real defect that seven reviewers and the whole suite missed.
# A fixture whose guards are unasserted is the same bet again. When U5 lands it
# consumes this file's shapes; until then this keeps them from rotting silently.

bats_require_minimum_version 1.5.0

setup() {
    FIXTURE="${BATS_TEST_DIRNAME}/../fixtures/fake-linear.sh"
    FAKE_LINEAR_RECORD_DIR="$(mktemp -d)"
    export FAKE_LINEAR_RECORD_DIR
    # Assembled at runtime: written whole it is a credential shape the repo's
    # own secret scan refuses to have in the tree.
    KEYLIKE="lin_api""_FAKEFAKEFAKEFAKEFAKE"
}

teardown() {
    [ -n "${FAKE_LINEAR_RECORD_DIR:-}" ] && rm -rf "$FAKE_LINEAR_RECORD_DIR"
}

# Reads one JSON field out of the fixture's stdout. python3 rather than jq:
# jq is not guaranteed on the box, and these assertions are the reason the
# file exists.
jfield() { python3 -c "$1"; }

@test "the credential on stdin is accepted and recorded as arriving there" {
    run --separate-stderr bash -c \
        "printf 'header = \"Authorization: %s\"\n' '$KEYLIKE' \
         | FAKE_LINEAR_MODE=found_child bash '$FIXTURE' --config - -X POST --data '{\"query\":\"{issue{id}}\"}'"
    [ "$status" -eq 0 ]
    [ "$(tail -1 "$FAKE_LINEAR_RECORD_DIR/auth_on_stdin")" = "yes" ]
}

@test "the credential on argv is refused with 98 -- KTD9's invariant" {
    run bash -c \
        "printf '' | FAKE_LINEAR_MODE=found_child bash '$FIXTURE' -H 'Authorization: $KEYLIKE' --data '{}'"
    [ "$status" -eq 98 ]
}

# Both guards started as enumerations of the ONE form each was tested with,
# which is default-allow: `-u <key>:`, a key in the request body, `--json`,
# `--data-binary` and `--data=<x>` all walked through exit 0. An allowlist never
# closes a class. Both now scan every argument and refuse on the credential
# shape or the `mutation` keyword wherever it appears.
@test "the credential is refused in argv in EVERY form, not only -H" {
    for form in "-u ${KEYLIKE}:" \
                "--header Authorization: ${KEYLIKE}" \
                "-H Authorization: ${KEYLIKE}"; do
        run bash -c "printf '' | FAKE_LINEAR_MODE=found_child bash '$FIXTURE' $form --data '{}'"
        [ "$status" -eq 98 ]
    done
    # and in the request body, where no header name appears at all
    run bash -c "printf '' | FAKE_LINEAR_MODE=found_child bash '$FIXTURE' --data '{\"apiKey\":\"${KEYLIKE}\"}'"
    [ "$status" -eq 98 ]
}

@test "a mutation is refused through EVERY data flag, not only --data" {
    for flag in "--data" "--data-raw" "--data-binary" "--json" "-d"; do
        run bash -c "printf '' | FAKE_LINEAR_MODE=found_child bash '$FIXTURE' $flag '{\"query\":\"mutation{x}\"}'"
        [ "$status" -eq 97 ]
    done
    # and in the --flag=value form, which is not a separate argument at all
    run bash -c "printf '' | FAKE_LINEAR_MODE=found_child bash '$FIXTURE' '--data={\"query\":\"mutation{x}\"}'"
    [ "$status" -eq 97 ]
}

@test "a child issue carries a non-null parent" {
    run bash -c "printf '' | FAKE_LINEAR_MODE=found_child bash '$FIXTURE' --data '{}'"
    [ "$status" -eq 0 ]
    result="$(printf '%s' "$output" | jfield \
        'import sys,json;print(json.load(sys.stdin)["data"]["issue"]["parent"]["identifier"])')"
    [ "$result" = "WEB-2870" ]
}

# The parent case is not the child case minus a field. parent is explicitly
# null and labels.nodes is an empty array rather than absent -- a reader that
# treats "no parent" and "no labels" as missing keys passes on one and breaks
# on the other.
@test "a parent issue has parent null and an empty labels array" {
    run bash -c "printf '' | FAKE_LINEAR_MODE=found_parent bash '$FIXTURE' --data '{}'"
    [ "$status" -eq 0 ]
    result="$(printf '%s' "$output" | jfield \
        'import sys,json;d=json.load(sys.stdin)["data"]["issue"];print(d["parent"],len(d["labels"]["nodes"]))')"
    [ "$result" = "None 0" ]
}

# The trap U5 would otherwise walk into. "No issue came back" arrives in three
# incompatible shapes, and `.data.issue == null` recognises none of them.
@test "not_found sets data to null beside errors, rather than nulling the issue" {
    run bash -c "printf '' | FAKE_LINEAR_MODE=not_found bash '$FIXTURE' --data '{}'"
    result="$(printf '%s' "$output" | jfield \
        'import sys,json;d=json.load(sys.stdin);print("data" in d, d["data"] is None, len(d["errors"]))')"
    [ "$result" = "True True 1" ]
}

@test "auth_error omits the data key entirely" {
    run bash -c "printf '' | FAKE_LINEAR_MODE=auth_error bash '$FIXTURE' --data '{}'"
    result="$(printf '%s' "$output" | jfield \
        'import sys,json;print("data" in json.load(sys.stdin))')"
    [ "$result" = "False" ]
}

@test "validation_error also omits the data key" {
    run bash -c "printf '' | FAKE_LINEAR_MODE=validation_error bash '$FIXTURE' --data '{}'"
    result="$(printf '%s' "$output" | jfield \
        'import sys,json;d=json.load(sys.stdin);print("data" in d, d["errors"][0]["extensions"]["code"])')"
    [ "$result" = "False GRAPHQL_VALIDATION_FAILED" ]
}

@test "a mutation is refused with 97 unless the test permits it -- R30's boundary" {
    run bash -c \
        "printf '' | FAKE_LINEAR_MODE=found_child bash '$FIXTURE' --data '{\"query\":\"mutation { issueUpdate }\"}'"
    [ "$status" -eq 97 ]
}

@test "a permitted mutation is answered" {
    run bash -c \
        "printf '' | FAKE_LINEAR_ALLOW_MUTATION=1 FAKE_LINEAR_MODE=found_child bash '$FIXTURE' --data '{\"query\":\"mutation { issueUpdate }\"}'"
    [ "$status" -eq 0 ]
}

# The rate-limit headers are on every response, not only on a 429, so a client
# can watch its own budget without ever being throttled.
@test "the rate-limit headers appear only when curl was asked for headers" {
    run bash -c "printf '' | FAKE_LINEAR_MODE=found_child bash '$FIXTURE' -i --data '{}'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"x-ratelimit-requests-limit: 2500"* ]]

    run bash -c "printf '' | FAKE_LINEAR_MODE=found_child bash '$FIXTURE' --data '{}'"
    [ "$status" -eq 0 ]
    [[ "$output" != *"x-ratelimit-requests-limit"* ]]
}

# An unknown mode must not answer with an empty body, which a caller would read
# as a successful empty response.
@test "an unknown mode fails loudly instead of answering empty" {
    # --separate-stderr because the point is that STDOUT stays empty while the
    # complaint goes to stderr. Merged, a loud failure and a silent empty
    # response are indistinguishable, which is the case this test exists for.
    run --separate-stderr bash -c "printf '' | FAKE_LINEAR_MODE=nonsense bash '$FIXTURE' --data '{}'"
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    [[ "$stderr" == *"unknown FAKE_LINEAR_MODE"* ]]
}

# Three non-JSON answers a real endpoint gives and a naive parser treats alike.
@test "http_500, empty_body and malformed_json are each distinguishable" {
    run bash -c "printf '' | FAKE_LINEAR_MODE=http_500 bash '$FIXTURE' --data '{}'"
    [[ "$output" == *"Internal Server Error"* ]]

    run bash -c "printf '' | FAKE_LINEAR_MODE=empty_body bash '$FIXTURE' --data '{}'"
    [ -z "$output" ]

    run bash -c "printf '' | FAKE_LINEAR_MODE=malformed_json bash '$FIXTURE' --data '{}'"
    [ "$output" = '{"data":{"issue":' ]
}
