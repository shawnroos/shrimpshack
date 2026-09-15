#!/usr/bin/env bats

load setup_common

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

# argv is not the only diagnostic sink the credential can reach. Bash traces
# AFTER expansion, so a brace-function caller of the resolver puts the value
# into the xtrace stream even though the resolver itself suppresses tracing --
# and bin/linear-cache-refresh.sh runs detached, where that stream lands
# somewhere nobody is watching.
@test "no fragment of the credential reaches the xtrace stream" {
    export FAKE_LINEAR_MODE=found_parent
    trace="$WORK/xtrace"
    (
        exec 9>"$trace"
        BASH_XTRACEFD=9
        set -x
        herdr_linear::fetch_issue WEB-2870 >/dev/null 2>&1
        set +x
    )
    # A trace of a call that never reached the credential is green for the
    # wrong reason, so prove the request actually went out with the key on
    # stdin before believing the absence.
    [ "$(tail -1 "$FAKE_LINEAR_RECORD_DIR/auth_on_stdin")" = "yes" ]
    run grep -c "$KEYLIKE" "$trace"
    [ "$output" = "0" ]
}

@test "the refresh script does not put the credential in its xtrace stream" {
    export FAKE_LINEAR_MODE=found_parent
    trace="$WORK/xtrace-refresh"
    bash -x "${BATS_TEST_DIRNAME}/../../bin/linear-cache-refresh.sh" WEB-2870 \
        >/dev/null 2>"$trace"
    [ "$(tail -1 "$FAKE_LINEAR_RECORD_DIR/auth_on_stdin")" = "yes" ]
    run grep -c "$KEYLIKE" "$trace"
    [ "$output" = "0" ]
}

# The refresh script NAMES FILES after whatever the tracker calls an issue. That
# is a write outside the cache, not a read of one, and no fixture had the shape
# to reach it: the hostile mode carries its payload in the title.
@test "the refresh script does not name a cache file outside the cache" {
    export FAKE_LINEAR_MODE=traversal_identifier
    run bash "${BATS_TEST_DIRNAME}/../../bin/linear-cache-refresh.sh" WEB-2870
    [ ! -e "$LINEAR_CACHE_DIR/../escaped.json" ]

    # The positive control: an ordinary identifier is still written.
    export FAKE_LINEAR_MODE=found_parent
    run bash "${BATS_TEST_DIRNAME}/../../bin/linear-cache-refresh.sh" WEB-2870
    [ -f "$LINEAR_CACHE_DIR/WEB-2870.json" ]
}

@test "the Keychain is preferred over the plaintext copy" {
    printf '%s\n%s\n' "kc-$KEYLIKE" "kc-$KEYLIKE" \
        | "$HERDR_LINEAR_SECURITY_BIN" add-generic-password -a linear-api-key -s work-linear -U -w >/dev/null 2>&1
    run herdr_linear::credential
    [ "$status" -eq 0 ]
    [ "$output" = "kc-$KEYLIKE" ]
}

# migrate-credential.sh reports this marker back to the operator. The hooks
# reach Linear through the library and never through the refresh script, so
# without a write here the migration reads as finished while every hook is
# still on the plaintext copy.
@test "a library call served from the plaintext copy records the fallback" {
    marker="$LINEAR_CACHE_DIR/_plaintext_fallback_used"
    rm -f "$marker"
    export FAKE_LINEAR_MODE=found_parent
    run herdr_linear::fetch_issue WEB-2870
    [ "$status" -eq 0 ]
    [ -s "$marker" ]
}

@test "a library call served from the Keychain records no fallback" {
    printf '%s\n%s\n' "kc-$KEYLIKE" "kc-$KEYLIKE" \
        | "$HERDR_LINEAR_SECURITY_BIN" add-generic-password -a linear-api-key -s work-linear -U -w >/dev/null 2>&1
    marker="$LINEAR_CACHE_DIR/_plaintext_fallback_used"
    rm -f "$marker"
    export FAKE_LINEAR_MODE=found_parent
    run herdr_linear::fetch_issue WEB-2870
    [ "$status" -eq 0 ]
    [ ! -e "$marker" ]
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

# The cache key is a path segment. A tracker-authored identifier that is not a
# safe one reaches this function, so the refusal has to be here and not only at
# whatever put the value in the record.
@test "a cache key that escapes the cache directory is refused, not followed" {
    printf '{"id":"OUTSIDE","title":"Attacker Title","project":"Evil","status":"x","fetchedAt":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$WORK/outside.json"
    run herdr_linear::cache_read "../outside"
    [ "$status" -eq 1 ]
    [ -z "$output" ]

    # The positive control. Without it a validator that refuses everything --
    # or one that is undefined and returns 127 -- reads as a pass above.
    cache_issue WEB-3318 "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    run herdr_linear::cache_read WEB-3318
    [ "$status" -eq 0 ]
    printf '%s' "$output" | grep -qF 'Cached Title'
}

# Sourced ALONE, in a shell that has loaded nothing else. Every other test here
# sources binding.sh first, which pulls sanitize.sh in, so they cannot tell a
# working guard from a missing one: an undefined validator returns 127 and the
# refusal above stays green for the wrong reason.
@test "linear.sh sourced on its own still has the validator its cache key needs" {
    run bash -c '. "$1"; command -v herdr_linear::is_safe_identifier' _ "$LIB/linear.sh"
    [ "$status" -eq 0 ]

    printf '{"id":"OUTSIDE","fetchedAt":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$WORK/outside.json"
    run bash -c '. "$1"; HERDR_LINEAR_CACHE_DIR="$2"; herdr_linear::cache_read ../outside' \
        _ "$LIB/linear.sh" "$LINEAR_CACHE_DIR"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
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

# -------------------------------------------------------- the organisation (R1)

@test "the organisation reader returns the workspace URL key" {
    run herdr_linear::organization_key
    [ "$status" -eq 0 ]
    [ "$output" = "acme" ]
}

# The org is the first path segment. An empty answer must be a refusal, not an
# empty segment that collapses two directories into one.
@test "an organisation the API cannot name returns nothing and does not crash" {
    export FAKE_LINEAR_ORGANIZATION=empty
    run --separate-stderr herdr_linear::organization_key
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "an unreachable Linear leaves the organisation unanswered" {
    export HERDR_LINEAR_CURL_BIN=/bin/false
    run --separate-stderr herdr_linear::organization_key
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

# ----------------------------------------------------------- the views (U3)
#
# Every listing goes through the fake's `$filter:IssueFilter` arm, which
# applies the REQUEST's filter to its pool: a client that dropped or rewrote
# its filter would get the wrong issues, not the same ones.

PROJECT=44444444-4444-4444-8444-444444444444
VIEW=cccccccc-cccc-4ccc-8ccc-cccccccccccc

identifiers() { python3 -c 'import sys,json;print(",".join(n["identifier"] for n in json.load(sys.stdin)["nodes"]))'; }

refute_match() {   # refute_match <grep-args...> -- fails when grep MATCHES
    if grep "$@"; then
        printf 'refute_match: unexpectedly matched: %s\n' "$*" >&2
        return 1
    fi
}

@test "project_issues lists the project's issues in nodes, never a teams shape, never a canceled one" {
    run --separate-stderr herdr_linear::project_issues "$PROJECT"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | identifiers)" = "WEB-3318,WEB-3317,WEB-3312" ]
    refute_match -qF '"teams"' <<<"$output"
    refute_match -qF 'project(id:' "$FAKE_LINEAR_RECORD_DIR/bodies"
    [ "$(printf '%s' "$output" | python3 -c 'import sys,json;print(json.load(sys.stdin)["truncated"])')" = "False" ]
}

@test "view_issues with a filter that excludes completed issues yields no completed issue" {
    export FAKE_LINEAR_ISSUES=completed
    filter='{"and":[{"project":{"id":{"in":["'"$PROJECT"'"]}}},{"state":{"type":{"nin":["completed","canceled"]}}}]}'
    run --separate-stderr herdr_linear::view_issues "$filter"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | identifiers)" = "WEB-3318,WEB-3317,WEB-3312" ]
    # The positive control: the same pool with no state clause carries the
    # Done issue, so the exclusion above is the filter's doing.
    run --separate-stderr herdr_linear::view_issues '{"and":[{"project":{"id":{"in":["'"$PROJECT"'"]}}}]}'
    [ "$(printf '%s' "$output" | identifiers)" = "WEB-3318,WEB-3317,WEB-3312,WEB-3300,WEB-3303" ]
}

@test "view_issues passes the view's filter through unchanged" {
    filter='{"and":[{"project":{"id":{"in":["'"$PROJECT"'"]}}},{"priority":{"in":[1,2,3]}},{"assignee":{"or":[{"isMe":{"eq":true}}]}}]}'
    run --separate-stderr herdr_linear::view_issues "$filter"
    [ "$status" -eq 0 ]
    sent="$(head -1 "$FAKE_LINEAR_RECORD_DIR/bodies" | python3 -c 'import sys,json;print(json.dumps(json.load(sys.stdin)["variables"]["filter"],sort_keys=True))')"
    want="$(printf '%s' "$filter" | python3 -c 'import sys,json;print(json.dumps(json.load(sys.stdin),sort_keys=True))')"
    [ "$sent" = "$want" ]
}

@test "view_issues refuses a filter that is not a JSON object, and sends nothing" {
    run --separate-stderr herdr_linear::view_issues '["not","a","filter"]'
    [ "$status" -eq 5 ]
    [ -z "$output" ]
    [ ! -e "$FAKE_LINEAR_RECORD_DIR/bodies" ]
}

@test "view_issues pages through every node of a multi-page connection" {
    export FAKE_LINEAR_ISSUES=paged
    run --separate-stderr herdr_linear::project_issues "$PROJECT"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | identifiers)" = "WEB-3318,WEB-3317,WEB-3312" ]
    [ "$(api_calls)" = "2" ]
    second="$(tail -1 "$FAKE_LINEAR_RECORD_DIR/bodies" | python3 -c 'import sys,json;print(json.load(sys.stdin)["variables"].get("after",""))')"
    [ "$second" = "c1" ]
    [ "$(printf '%s' "$output" | python3 -c 'import sys,json;print(json.load(sys.stdin)["truncated"])')" = "False" ]
}

@test "a connection that never ends stops at the page cap and is marked truncated" {
    export FAKE_LINEAR_ISSUES=capped HERDR_LINEAR_VIEW_PAGE_MAX=2
    run --separate-stderr herdr_linear::project_issues "$PROJECT"
    [ "$status" -eq 0 ]
    [ "$(api_calls)" = "2" ]
    [ "$(printf '%s' "$output" | python3 -c 'import sys,json;print(json.load(sys.stdin)["truncated"])')" = "True" ]
}

@test "an unreachable Linear leaves a listing unavailable, with nothing on stdout" {
    export HERDR_LINEAR_CURL_BIN=/bin/false
    run --separate-stderr herdr_linear::project_issues "$PROJECT"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

# KTD12. Kept: an Issue view whose filter names the project by id, under the
# `and` wrapper the UI saves, bare with eq, or in a two-project list. Dropped:
# another project, a Project-model view, an archived one, and a `project`
# clause that carries no id.
@test "project_views keeps only live Issue views whose filter names the project" {
    export FAKE_LINEAR_VIEWS=many
    run --separate-stderr herdr_linear::project_views "$PROJECT"
    [ "$status" -eq 0 ]
    ids="$(printf '%s\n' "$output" | cut -f1 | sort | tr '\n' ' ')"
    [ "$ids" = "c2c2c2c2-c2c2-4c2c-8c2c-c2c2c2c2c2c2 c3c3c3c3-c3c3-4c3c-8c3c-c3c3c3c3c3c3 cccccccc-cccc-4ccc-8ccc-cccccccccccc " ]
    [ "$(printf '%s\n' "$output" | grep -c .)" = "3" ]
    [ "$(printf '%s\n' "$output" | head -1 | cut -f2)" = "Canvas board" ]
}

@test "project_views with no views at all answers nothing and succeeds" {
    export FAKE_LINEAR_VIEWS=none
    run --separate-stderr herdr_linear::project_views "$PROJECT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "view_read returns id, name, filter and the board layout" {
    run --separate-stderr herdr_linear::view_read "$VIEW"
    [ "$status" -eq 0 ]
    result="$(printf '%s' "$output" | python3 -c '
import sys,json;d=json.load(sys.stdin)
print(d["id"], d["name"], d["archived"], d["layout"]["grouping"], ",".join(d["layout"]["column_order"]), ",".join(d["layout"]["hidden"]), "and" in d["filter"])')"
    [ "$result" = "$VIEW Canvas board False workflowState st-backlog,st-todo,st-prog,st-devdone,st-done,st-cancel st-cancel True" ]
}

# Linear answers null, not [], for the two column lists on a view whose
# columns were never arranged (captured 2026-09-14).
@test "view_read turns null column lists into empty ones" {
    export FAKE_LINEAR_VIEW_PREFS=unarranged
    run --separate-stderr herdr_linear::view_read "$VIEW"
    [ "$status" -eq 0 ]
    result="$(printf '%s' "$output" | python3 -c 'import sys,json;l=json.load(sys.stdin)["layout"];print(l["column_order"], l["hidden"])')"
    [ "$result" = "[] []" ]
}

@test "view_read on an archived view returns the archived marker and succeeds" {
    export FAKE_LINEAR_VIEW_ARCHIVED=1
    run --separate-stderr herdr_linear::view_read "$VIEW"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | python3 -c 'import sys,json;print(json.load(sys.stdin)["archived"])')" = "True" ]
}

@test "view_read on an unknown id is not-found, with nothing on stdout" {
    export FAKE_LINEAR_VIEW_MISSING=1
    run --separate-stderr herdr_linear::view_read 00000000-0000-4000-8000-000000000000
    [ "$status" -eq 2 ]
    [ -z "$output" ]
}

@test "view_create without permission is refused by the fixture and sends no second mutation" {
    run --separate-stderr herdr_linear::view_create "$PROJECT" "Canvas board"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [ "$(api_calls)" = "1" ]
    refute_match -qF 'viewPreferencesCreate' "$FAKE_LINEAR_RECORD_DIR/bodies"
}

@test "view_create sends the create and then the board preferences, and prints the id" {
    export FAKE_LINEAR_ALLOW_MUTATION=1
    run --separate-stderr herdr_linear::view_create "$PROJECT" "Canvas board"
    [ "$status" -eq 0 ]
    [ "$output" = "$VIEW" ]
    [ "$(api_calls)" = "2" ]
    # The input shapes introspection confirmed (tests/probe/customviews-transcript.md):
    # CustomViewCreateInput carries no modelName; ViewPreferencesCreateInput
    # needs viewType, and preferences is a plain JSON object.
    first="$(head -1 "$FAKE_LINEAR_RECORD_DIR/bodies" | python3 -c 'import sys,json;i=json.load(sys.stdin)["variables"]["i"];print(sorted(i), i["shared"], i["filterData"]["project"]["id"]["in"][0])')"
    [ "$first" = "['filterData', 'name', 'shared'] False $PROJECT" ]
    second="$(tail -1 "$FAKE_LINEAR_RECORD_DIR/bodies" | python3 -c 'import sys,json;i=json.load(sys.stdin)["variables"]["i"];print(i["type"], i["viewType"], i["customViewId"], i["preferences"]["layout"], i["preferences"]["issueGrouping"])')"
    [ "$second" = "user customView $VIEW board workflowState" ]
}

# The view exists the moment the first mutation succeeds. A caller that only
# saw "failed" would have no id to record, and an unrecorded view is one
# nobody can find to delete.
@test "view_create still prints the id when only the preferences fail, under its own code" {
    export FAKE_LINEAR_ALLOW_MUTATION=1 FAKE_LINEAR_MUTATION_RESULT=prefs_fail
    run --separate-stderr herdr_linear::view_create "$PROJECT" "Canvas board"
    [ "$status" -eq 6 ]
    [ "$output" = "$VIEW" ]
}

@test "view_create whose create reports success:false prints nothing and stops" {
    export FAKE_LINEAR_ALLOW_MUTATION=1 FAKE_LINEAR_MUTATION_RESULT=fail
    run --separate-stderr herdr_linear::view_create "$PROJECT" "Canvas board"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [ "$(api_calls)" = "1" ]
}

@test "the credential reaches the listing and view reads on stdin, never argv" {
    herdr_linear::project_issues "$PROJECT" >/dev/null
    herdr_linear::project_views "$PROJECT" >/dev/null
    herdr_linear::view_read "$VIEW" >/dev/null
    [ "$(api_calls)" = "3" ]
    [ "$(sort -u "$FAKE_LINEAR_RECORD_DIR/auth_on_stdin")" = "yes" ]
    run grep -c "$KEYLIKE" "$FAKE_LINEAR_RECORD_DIR/argv"
    [ "$output" = "0" ]
}
