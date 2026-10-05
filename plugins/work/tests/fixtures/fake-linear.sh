#!/usr/bin/env bash
# fake-linear.sh — stand-in for curl when bin/migrate-credential.sh verifies a key.
#
# It stands in for curl rather than for the API because the claim worth testing
# is about the invocation: the credential reaches the request on stdin, through
# `curl --config -`, and never on argv, where any process running as this user
# can read it. Only something sitting where curl sits can see argv, so this
# exits 98 the moment a credential shape appears there.
#
# The two bodies were captured from the real Linear GraphQL endpoint on
# 2026-09-04, with the id and name replaced by same-shaped synthetic values.
# An authentication failure carries errors[] and no data key at all.
#
# Environment:
#   FAKE_LINEAR_MODE         viewer | auth_error  (default: viewer)
#   FAKE_LINEAR_RECORD_DIR   where the argv/stdin record lands
#
# Exit codes:
#   98  the credential appeared in argv
#   97  a GraphQL mutation was sent; verifying a key never writes
#   2   an unknown FAKE_LINEAR_MODE

set -u

record_dir="${FAKE_LINEAR_RECORD_DIR:-${TMPDIR:-/tmp}/fake-linear-record}"
mkdir -p "$record_dir" 2>/dev/null || true

# Checked before anything else runs, so a later success cannot mask it. The
# credential shape is refused wherever it appears: `-u <key>:` and a key inside
# --data leak as surely as a header does.
for arg in "$@"; do
    case "$arg" in
        *lin_api_*|*lin_oauth_*|*sk-ant-*|*"Bearer lin_"*)
            printf 'fake-linear: credential shape in argv (arg redacted)\n' >&2
            exit 98
            ;;
    esac
done

printf '%s\n' "$*" >> "$record_dir/argv"

# Drained so the caller's write cannot block on a full pipe.
stdin_config=""
if [ ! -t 0 ]; then
    stdin_config="$(cat)"
fi
case "$stdin_config" in
    *[Aa]uthorization*) printf 'yes\n' >> "$record_dir/auth_on_stdin" ;;
    *)                  printf 'no\n'  >> "$record_dir/auth_on_stdin" ;;
esac

case "$*" in
    *mutation*)
        printf 'fake-linear: a mutation was sent\n' >&2
        exit 97
        ;;
esac

case "${FAKE_LINEAR_MODE:-viewer}" in
    viewer)
        printf '%s\n' '{"data":{"viewer":{"id":"66666666-6666-4666-8666-666666666666","name":"Example User"}}}'
        ;;
    auth_error)
        printf '%s\n' '{"errors":[{"message":"Authentication required, not authenticated","extensions":{"type":"authentication error","code":"AUTHENTICATION_ERROR","statusCode":401,"userError":true,"userPresentableMessage":"You need to authenticate to access this operation.","meta":{},"http":{"status":401}}}]}'
        ;;
    *)
        printf 'fake-linear: unknown FAKE_LINEAR_MODE %s\n' "${FAKE_LINEAR_MODE}" >&2
        exit 2
        ;;
esac
