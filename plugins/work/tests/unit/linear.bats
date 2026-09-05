#!/usr/bin/env bats
# U5 — the Linear client.
#
# No test here touches the live Linear API. The network goes through
# tests/fixtures/fake-linear.sh, which stands in for curl and exits 98 if a
# credential shape ever appears in argv, and the Keychain through
# fake-security.sh.

bats_require_minimum_version 1.5.0

setup() {
    LIB="${BATS_TEST_DIRNAME}/../../lib"
    FIX="${BATS_TEST_DIRNAME}/../fixtures"
    WORK="$(mktemp -d)"

    export HERDR_LINEAR_CURL_BIN="$FIX/fake-linear.sh"
    export HERDR_LINEAR_SECURITY_BIN="$FIX/fake-security.sh"
    export FAKE_SECURITY_STORE_DIR="$WORK/keychain"
    export FAKE_LINEAR_RECORD_DIR="$WORK/linear-record"
    export LINEAR_CACHE_DIR="$WORK/cache"
    export LINEAR_SECRETS_FILE="$WORK/secrets"
    export HERDR_LINEAR_STORE_DIR="$WORK/store"
    export HERDR_LINEAR_PIN_DIR="$WORK/pin"
    export HERDR_LINEAR_RETRY_BASE_MS=1
    mkdir -p "$FAKE_LINEAR_RECORD_DIR" "$LINEAR_CACHE_DIR"

    KEYLIKE="lin_api""_CLIENTCLIENTCLIENTCL"
    printf 'LINEAR_API_KEY=%s\n' "$KEYLIKE" > "$LINEAR_SECRETS_FILE"

    # shellcheck source=/dev/null
    . "$LIB/secrets.sh"; . "$LIB/binding.sh"; . "$LIB/linear.sh"

    WT="$WORK/wt"; mkdir -p "$WT"
    git -C "$WT" init -q -b feature/web-2870-detach
    git -C "$WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
}

teardown() { [ -n "${WORK:-}" ] && rm -rf "$WORK"; }

api_calls() { [ -f "$FAKE_LINEAR_RECORD_DIR/bodies" ] && wc -l < "$FAKE_LINEAR_RECORD_DIR/bodies" | tr -d ' ' || echo 0; }

bind_to() {
    local id="$1" nonce
    nonce="$(herdr_linear::binding_propose "$WT" "$id")"
    herdr_linear::binding_confirm "$WT" "$id" "$nonce"
}

cache_issue() {   # cache_issue <id> <fetchedAt>
    printf '{"id":"%s","title":"Cached Title","project":"Cached Project","status":"In Progress","fetchedAt":"%s"}\n' \
        "$1" "$2" > "$LINEAR_CACHE_DIR/$1.json"
}

# ------------------------------------------------------ branch matching (AE1)

@test "AE1: hyphenated, unhyphenated, and no-identifier branches" {
    run herdr_linear::branch_identifier "feature/web-3124-analysis-tiers"
    [ "$output" = "WEB-3124" ]
    run herdr_linear::branch_identifier "task/web3045-placeholder"
    [ "$output" = "WEB-3045" ]
    run herdr_linear::branch_identifier "rehome-sprawl"
    [ "$status" -ne 0 ]
}

# The greedy split this closes had TWO sites -- the match and the normaliser --
# and each one alone turns web3045 into WEB304-5, a different issue that may
# well exist. A single-site fix here reads green on the hyphenated case.
@test "an unhyphenated identifier is not split at the wrong place" {
    for b in "task/web3045-placeholder" "web3045" "fix/WEB3045-thing"; do
        run herdr_linear::branch_identifier "$b"
        [ "$output" = "WEB-3045" ]
    done
}

@test "a team key containing a digit still matches when hyphenated" {
    run herdr_linear::branch_identifier "feature/x2-14-thing"
    [ "$output" = "X2-14" ]
}

# Whatever the matcher returns must always BE an identifier. Note this asserts
# the PROPERTY, not the guard: lib/linear.sh's output check is unreachable given
# the current matcher, so mutating that check away leaves this test green. The
# property is still worth pinning -- it is what would break first if either
# pattern changed.
@test "whatever the matcher returns is always a well-formed identifier" {
    for b in "feature/ab12cd34-thing" "feature/xyz123456789" "task/web3045-y" "feature/x2-14-z"; do
        run herdr_linear::branch_identifier "$b"
        [ "$status" -eq 0 ]
        [[ "$output" =~ ^[A-Z][A-Z0-9]{0,7}-[0-9]{1,6}$ ]]
    done
}

@test "a branch with no identifier shape matches nothing" {
    for b in main develop herdr-linear-plugin release/2026; do
        run herdr_linear::branch_identifier "$b"
        [ "$status" -ne 0 ]
    done
}

# ------------------------------------------------------------- the credential

@test "no fragment of the credential reaches argv, and it arrives on stdin" {
    export FAKE_LINEAR_MODE=found_parent; run herdr_linear::fetch_issue WEB-2870
    [ "$status" -eq 0 ]
    [ "$(tail -1 "$FAKE_LINEAR_RECORD_DIR/auth_on_stdin")" = "yes" ]
    run grep -c "$KEYLIKE" "$FAKE_LINEAR_RECORD_DIR/argv"
    [ "$output" = "0" ]
}

@test "the Keychain is preferred over the plaintext copy" {
    printf '%s\n%s\n' "kc-$KEYLIKE" "kc-$KEYLIKE" \
        | "$HERDR_LINEAR_SECURITY_BIN" add-generic-password -a linear-api-key -s work-linear -U -w >/dev/null 2>&1
    run herdr_linear::credential
    [ "$status" -eq 0 ]
    [ "$output" = "kc-$KEYLIKE" ]
}

@test "with no credential anywhere the client reports auth failure, not unavailable" {
    rm -f "$LINEAR_SECRETS_FILE"
    export FAKE_LINEAR_MODE=found_parent; run herdr_linear::fetch_issue WEB-2870
    [ "$status" -eq 3 ]
}

# ----------------------------------------------------------- cache and context

# KTD5: identity from the cache, parent and team always from the API. The saving
# is one field-set, not one call -- so exactly one API call still happens.
@test "a fresh cache entry supplies identity while the parent still comes from the API" {
    cache_issue WEB-3318 "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    export FAKE_LINEAR_MODE=found_child; run herdr_linear::issue_context WEB-3318
    [ "$status" -eq 0 ]
    got="$(printf '%s' "$output" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["identity_from_cache"],d["title"],"|",d["parent"])')"
    [ "$got" = "True Cached Title | WEB-2870" ]
    [ "$(api_calls)" = "1" ]
}

@test "a cache entry past the freshness bound is a miss, and identity comes from the API" {
    cache_issue WEB-3318 "2020-01-01T00:00:00Z"
    export FAKE_LINEAR_MODE=found_child; run herdr_linear::issue_context WEB-3318
    [ "$status" -eq 0 ]
    got="$(printf '%s' "$output" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["identity_from_cache"],d["title"])')"
    [ "$got" = "False AI Tools drawer is blank when a still-processing layer is selected" ]
}

# The parent is typically someone else's issue, so it is never in a cache keyed
# on issues assigned to this user. It must come from the API every time.
@test "a parent absent from the cache is still fetched" {
    cache_issue WEB-3318 "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    [ ! -f "$LINEAR_CACHE_DIR/WEB-2870.json" ]
    export FAKE_LINEAR_MODE=found_child; run herdr_linear::issue_context WEB-3318
    got="$(printf '%s' "$output" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["parent"],d["parent_title"])')"
    [ "$got" = "WEB-2870 Tool: Detach Foreground" ]
}

@test "an issue with no parent reports an empty parent rather than failing" {
    export FAKE_LINEAR_MODE=found_parent; run herdr_linear::issue_context WEB-2870
    [ "$status" -eq 0 ]
    got="$(printf '%s' "$output" | python3 -c 'import sys,json;print(repr(json.load(sys.stdin)["parent"]))')"
    [ "$got" = "''" ]
}

# ------------------------------------------------------- unavailability (R14)

@test "an unreachable Linear returns unavailable rather than blocking" {
    export HERDR_LINEAR_CURL_BIN=/bin/false; run herdr_linear::fetch_issue WEB-2870
    [ "$status" -eq 1 ]
}

@test "a malformed body is unavailable, not a successful empty answer" {
    export FAKE_LINEAR_MODE=malformed_json; run herdr_linear::fetch_issue WEB-2870
    [ "$status" -eq 1 ]
}

@test "an empty body is unavailable" {
    export FAKE_LINEAR_MODE=empty_body; run herdr_linear::fetch_issue WEB-2870
    [ "$status" -eq 1 ]
}

@test "a missing issue is not-found, which is a different answer from unavailable" {
    export FAKE_LINEAR_MODE=not_found; run herdr_linear::fetch_issue WEB-999999
    [ "$status" -eq 2 ]
}

# ------------------------------------------------------------- rate limiting

@test "a rate-limited call backs off and retries before giving up" {
    export HERDR_LINEAR_RETRY_MAX=3; export FAKE_LINEAR_MODE=rate_limited; run herdr_linear::fetch_issue WEB-2870
    [ "$status" -eq 4 ]
    [ "$(api_calls)" = "3" ]
}

# Retrying a validation error or a refused credential only delays the failure --
# the answer is identical every time.
@test "an authentication error is not retried" {
    export FAKE_LINEAR_MODE=auth_error; run herdr_linear::fetch_issue WEB-2870
    [ "$status" -eq 3 ]
    [ "$(api_calls)" = "1" ]
}

# --------------------------------------------------- the stale-write guard (KTD7)

@test "updatedAt moving within the pass refuses the write" {
    opening="2026-09-04T18:11:48.336Z"
    export FAKE_LINEAR_MODE=found_parent_moved; run herdr_linear::guard_unchanged WEB-2870 "$opening"
    [ "$status" -eq 5 ]
}

@test "updatedAt stable within the pass allows the write" {
    opening="2026-09-04T18:11:48.336Z"
    export FAKE_LINEAR_MODE=found_parent; run herdr_linear::guard_unchanged WEB-2870 "$opening"
    [ "$status" -eq 0 ]
}

# The trap KTD7 exists to avoid. Linear's own GitHub integration moves these
# issues between sessions, so comparing against a value stored in an EARLIER
# session would abort every write permanently and silently. The guard takes its
# opening value from this pass, so a value from last week is simply irrelevant.
@test "a value stored in an earlier session does not block a write that is stable in this pass" {
    stale_from_last_session="2026-01-01T00:00:00Z"
    opening="$(export FAKE_LINEAR_MODE=found_parent; herdr_linear::issue_updated_at WEB-2870)"
    [ "$opening" != "$stale_from_last_session" ]
    export FAKE_LINEAR_MODE=found_parent; run herdr_linear::guard_unchanged WEB-2870 "$opening"
    [ "$status" -eq 0 ]
}

@test "the guard refuses when it cannot read the current value at all" {
    export HERDR_LINEAR_CURL_BIN=/bin/false; run herdr_linear::guard_unchanged WEB-2870 "anything"
    [ "$status" -ne 0 ]
}

# ------------------------------------------------------- the write bound (R30)

@test "the bound issue may be written to" {
    bind_to WEB-2870
    run herdr_linear::write_allowed "$WT" WEB-2870
    [ "$status" -eq 0 ]
}

@test "a recorded child may be written to" {
    bind_to WEB-2870
    herdr_linear::binding_add_child "$WT" WEB-5001
    run herdr_linear::write_allowed "$WT" WEB-5001
    [ "$status" -eq 0 ]
}

# R30's real threat. Linear will happily report a child the plugin never
# created, and anyone who can re-parent an issue could put it there. The
# writable set therefore comes from the binding record and never from Linear.
@test "an issue Linear reports as a child, but the record does not list, is refused" {
    bind_to WEB-2870
    # found_child's fixture says WEB-3318's parent IS the bound issue.
    export FAKE_LINEAR_MODE=found_child; run herdr_linear::fetch_issue WEB-3318
    [ "$status" -eq 0 ]
    run herdr_linear::write_allowed "$WT" WEB-3318
    [ "$status" -eq 5 ]
}

@test "an unrelated issue is refused" {
    bind_to WEB-2870
    run herdr_linear::write_allowed "$WT" WEB-9999
    [ "$status" -eq 5 ]
}

# Only Bound permits an automatic write. proposed, misplaced and stale are
# reported and wait for a person.
@test "a worktree that is only proposed cannot be written from" {
    herdr_linear::binding_propose "$WT" WEB-2870 >/dev/null
    run herdr_linear::write_allowed "$WT" WEB-2870
    [ "$status" -eq 5 ]
}

# The earlier "only proposed" test does not isolate the state check: a proposed
# record also has an empty issue_identifier, so it is refused by the identifier
# comparison whether or not the state is examined. Removing the state check left
# that test green. Misplaced and stale DO carry the identifier, so they are what
# actually exercises it -- only Bound permits an automatic write.
@test "a misplaced or stale worktree cannot be written from even though it still names the issue" {
    for st in misplaced stale; do
        bind_to WEB-2870
        herdr_linear::binding_set_state "$WT" "$st"
        run herdr_linear::binding_identifier "$WT"
        [ "$output" = "WEB-2870" ]
        run herdr_linear::write_allowed "$WT" WEB-2870
        [ "$status" -eq 5 ]
    done
}

@test "an unbound worktree cannot be written from" {
    run herdr_linear::write_allowed "$WT" WEB-2870
    [ "$status" -eq 5 ]
}

@test "a bound worktree whose branch changed cannot be written from" {
    bind_to WEB-2870
    git -C "$WT" checkout -q -b somewhere-else
    run herdr_linear::write_allowed "$WT" WEB-2870
    [ "$status" -eq 5 ]
}

# ---------------------------------------------------------------- slugs (R28)

@test "a dangerous title is rejected rather than repaired" {
    run herdr_linear::slug -- "--rf"
    [ "$status" -ne 0 ]
    run herdr_linear::slug ".."
    [ "$status" -ne 0 ]
    run herdr_linear::slug "."
    [ "$status" -ne 0 ]
    run herdr_linear::slug ".hidden"
    [ "$status" -ne 0 ]
    run herdr_linear::slug "   "
    [ "$status" -ne 0 ]
    run herdr_linear::slug ""
    [ "$status" -ne 0 ]
}

@test "an ordinary title slugs to safe characters only" {
    run herdr_linear::slug "Tool: Detach Foreground"
    [ "$output" = "Tool-Detach-Foreground" ]
    run herdr_linear::slug 'a/b\c;d$(e)`f`'
    [[ "$output" =~ ^[A-Za-z0-9._-]+$ ]]
}

@test "a slug is capped in length" {
    long="$(python3 -c 'print("a"*500)')"
    run herdr_linear::slug "$long" 60
    [ "${#output}" -le 60 ]
}
