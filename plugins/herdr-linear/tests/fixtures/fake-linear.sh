#!/usr/bin/env bash
# fake-linear.sh — stand-in for curl against the Linear GraphQL API.
#
# WHY IT STANDS IN FOR curl, NOT FOR THE API
# KTD9 says the credential reaches the request on stdin, through `curl
# --config -`, and never on argv. That is an invariant about the INVOCATION,
# so only something sitting where curl sits can assert it. A fixture that
# merely returned canned JSON would leave the one security claim U5 makes
# untested. This exits 98 the moment an Authorization value appears in argv.
#
# RESPONSE SHAPES: CAPTURED, NOT IMAGINED
# Every body below except FAKE_LINEAR_MODE=rate_limited was captured from
# api.linear.app on 2026-09-04 and then had its ids, titles and URLs replaced
# with same-shaped synthetic values. The shapes are the point, and three of
# them disagree in a way a hand-written fixture would have smoothed over:
#
#   found          {"data":{"issue":{...}}}
#   not_found      {"errors":[...],"data":null}     <- data present AND null
#   auth_error     {"errors":[...]}                 <- no data key at all
#   validation     {"errors":[...]}                 <- no data key at all
#
# So a client testing `.data.issue == null` to mean "no such issue" is wrong
# twice over: not_found nulls the whole data object, and auth_error omits it.
# Branch on errors[] first, then on data.
#
# rate_limited is the one constructed body. Linear's limit is 2500 req/hr and
# 3,000,000 complexity/hr, reported on EVERY response in the headers below; it
# could not be provoked read-only without spending the hour's budget, so the
# 429 body follows the documented form and is labelled here as unverified.
#
# Environment:
#   FAKE_LINEAR_MODE         found_child | found_parent | not_found |
#                            auth_error | validation_error | rate_limited |
#                            http_500 | empty_body | malformed_json
#                            (default: found_child)
#   FAKE_LINEAR_RECORD_DIR   where the argv/stdin record lands
#   FAKE_LINEAR_ALLOW_MUTATION  set to 1 to permit a GraphQL mutation;
#                            unset, a mutation exits 97 without answering
#
# Exit codes distinguish the two boundary breaks from an ordinary HTTP answer:
#   98  the credential appeared in argv          (KTD9 broken)
#   97  a mutation was sent without permission   (R30 broken)

set -u

record_dir="${FAKE_LINEAR_RECORD_DIR:-${TMPDIR:-/tmp}/fake-linear-record}"
mkdir -p "$record_dir" 2>/dev/null || true

# --- boundary 1: the credential must never be on argv -------------------
# Checked against the argv this process actually received, before anything
# else runs, so a violation cannot be masked by a later success.
# The credential SHAPE is what is refused, wherever it appears. An earlier
# version required "authorization:" and the key in the same argument, which let
# `-u <key>:` and a key inside --data through with exit 0 -- an allowlist of the
# one form it had been tested with. A leak does not have to look like a header.
for arg in "$@"; do
    case "$arg" in
        *lin_api_*|*lin_oauth_*|*sk-ant-*|*"Bearer lin_"*)
            printf 'fake-linear: credential shape in argv (arg redacted)\n' >&2
            exit 98
            ;;
    esac
done

printf '%s\n' "$*" >> "$record_dir/argv"

# --- read the curl config from stdin ------------------------------------
# `--config -` is the whole point; drain stdin so the caller's write cannot
# block on a full pipe, and record whether an Authorization header arrived.
stdin_config=""
if [ ! -t 0 ]; then
    stdin_config="$(cat)"
fi
case "$stdin_config" in
    *[Aa]uthorization*) printf 'yes\n' >> "$record_dir/auth_on_stdin" ;;
    *)                  printf 'no\n'  >> "$record_dir/auth_on_stdin" ;;
esac

# --- boundary 2: no mutation unless the test asked for one ---------------
body=""
want_data=0
for arg in "$@"; do
    if [ "$want_data" = 1 ]; then body="$arg"; want_data=0; continue; fi
    case "$arg" in
        --data|--data-raw|-d) want_data=1 ;;
    esac
done
printf '%s\n' "$body" >> "$record_dir/bodies"

# Scored against ALL of argv, not the extracted body. The extraction only knows
# --data/-d/--data-raw as separate arguments, so --data-binary, --json and
# --data=<value> yielded an empty body and passed. A GraphQL mutation cannot be
# written without the keyword, so a substring test over argv cannot be evaded;
# a read query carrying the word "mutation" in a string is refused too, which is
# the right direction for a guard whose whole job is to fail closed.
case "$*" in
    *mutation*)
        if [ "${FAKE_LINEAR_ALLOW_MUTATION:-0}" != 1 ]; then
            printf 'fake-linear: unpermitted mutation\n' >&2
            exit 97
        fi
        ;;
esac

# --- headers ------------------------------------------------------------
# Emitted only when the caller asked for them, exactly as curl behaves. The
# rate-limit values are the real header names and real limits, captured live.
emit_headers() {
    local status="$1"
    printf 'HTTP/2 %s \r\n' "$status"
    printf 'content-type: application/json; charset=utf-8\r\n'
    printf 'x-complexity: 1\r\n'
    printf 'x-ratelimit-complexity-limit: 3000000\r\n'
    printf 'x-ratelimit-complexity-remaining: 2999999\r\n'
    printf 'x-ratelimit-complexity-reset: 1788557938785\r\n'
    printf 'x-ratelimit-requests-limit: 2500\r\n'
    printf 'x-ratelimit-requests-remaining: 2499\r\n'
    printf 'x-ratelimit-requests-reset: 1788557938785\r\n'
    printf '\r\n'
}

wants_headers=0
for arg in "$@"; do
    case "$arg" in
        -i|--include|-D|--dump-header) wants_headers=1 ;;
    esac
done

# --- bodies -------------------------------------------------------------
found_child() {
    cat <<'JSON'
{"data":{"issue":{"id":"11111111-1111-4111-8111-111111111111","identifier":"WEB-3318","title":"AI Tools drawer is blank when a still-processing layer is selected","url":"https://linear.app/example/issue/WEB-3318/ai-tools-drawer-is-blank","branchName":"web-3318-ai-tools-drawer-is-blank-when-a-still-processing-layer-is","updatedAt":"2026-09-04T15:55:10.206Z","priority":0,"state":{"id":"22222222-2222-4222-8222-222222222222","name":"Backlog","type":"backlog"},"parent":{"id":"33333333-3333-4333-8333-333333333333","identifier":"WEB-2870","title":"Tool: Detach Foreground"},"project":{"id":"44444444-4444-4444-8444-444444444444","name":"AI Canvas Tools"},"team":{"id":"55555555-5555-4555-8555-555555555555","key":"WEB","name":"Web Creation"},"assignee":{"id":"66666666-6666-4666-8666-666666666666","name":"Example User"},"labels":{"nodes":[{"id":"77777777-7777-4777-8777-777777777777","name":"Bug"}]}}}}
JSON
}

# The parent case is not the child case with a field removed: parent is
# explicitly null, labels.nodes is an empty array rather than absent, and
# priority is non-zero. Each of those is a real distinction a reader can trip on.
found_parent() {
    cat <<'JSON'
{"data":{"issue":{"id":"33333333-3333-4333-8333-333333333333","identifier":"WEB-2870","title":"Tool: Detach Foreground","url":"https://linear.app/example/issue/WEB-2870/tool-detach-foreground","branchName":"web-2870-tool-detach-foreground","updatedAt":"2026-09-04T18:11:48.336Z","priority":3,"state":{"id":"88888888-8888-4888-8888-888888888888","name":"Dev Done","type":"started"},"parent":null,"project":{"id":"44444444-4444-4444-8444-444444444444","name":"AI Canvas Tools"},"team":{"id":"55555555-5555-4555-8555-555555555555","key":"WEB","name":"Web Creation"},"assignee":{"id":"66666666-6666-4666-8666-666666666666","name":"Example User"},"labels":{"nodes":[]}}}}
JSON
}

not_found() {
    cat <<'JSON'
{"errors":[{"message":"Entity not found: Issue","path":["issue"],"locations":[{"line":1,"column":9}],"extensions":{"type":"invalid input","code":"INPUT_ERROR","statusCode":400,"userError":true,"userPresentableMessage":"Could not find referenced Issue."}}],"data":null}
JSON
}

auth_error() {
    cat <<'JSON'
{"errors":[{"message":"Authentication required, not authenticated","extensions":{"type":"authentication error","code":"AUTHENTICATION_ERROR","statusCode":401,"userError":true,"userPresentableMessage":"You need to authenticate to access this operation.","meta":{},"http":{"status":401}}}]}
JSON
}

validation_error() {
    cat <<'JSON'
{"errors":[{"message":"Cannot query field \"nosuchfield\" on type \"Issue\".","locations":[{"line":1,"column":27}],"extensions":{"http":{"status":400,"headers":{}},"code":"GRAPHQL_VALIDATION_FAILED","type":"graphql error","userError":true}}]}
JSON
}

# UNVERIFIED SHAPE — see the header note. Follows Linear's documented 429.
rate_limited() {
    cat <<'JSON'
{"errors":[{"message":"Rate limit exceeded","extensions":{"type":"ratelimited","code":"RATELIMITED","statusCode":429,"userError":true,"userPresentableMessage":"You have exceeded the rate limit."}}]}
JSON
}

status=200
case "${FAKE_LINEAR_MODE:-found_child}" in
    found_child)      [ "$wants_headers" = 1 ] && emit_headers 200; found_child ;;
    found_parent)     [ "$wants_headers" = 1 ] && emit_headers 200; found_parent ;;
    not_found)        [ "$wants_headers" = 1 ] && emit_headers 400; not_found ;;
    auth_error)       [ "$wants_headers" = 1 ] && emit_headers 401; auth_error ;;
    validation_error) [ "$wants_headers" = 1 ] && emit_headers 400; validation_error ;;
    rate_limited)     [ "$wants_headers" = 1 ] && emit_headers 429; rate_limited ;;
    http_500)         [ "$wants_headers" = 1 ] && emit_headers 500; printf '%s' '<html>Internal Server Error</html>' ;;
    empty_body)       [ "$wants_headers" = 1 ] && emit_headers 200 ;;
    malformed_json)   [ "$wants_headers" = 1 ] && emit_headers 200; printf '%s' '{"data":{"issue":' ;;
    *)
        printf 'fake-linear: unknown FAKE_LINEAR_MODE: %s\n' "${FAKE_LINEAR_MODE:-}" >&2
        exit 2
        ;;
esac

exit 0
