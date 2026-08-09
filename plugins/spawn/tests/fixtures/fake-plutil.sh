#!/usr/bin/env bash
# fake-plutil.sh — recording stand-in for /usr/bin/plutil (U3 step 6, R28).
#
# It RECORDS every invocation and then DELEGATES to the real binary. Recording
# is what makes "the plist was read through plutil, not text-parsed" assertable;
# delegating is what keeps the conversions real — a hand-rolled fake would
# happily "convert" a binary plist the real tool would reject, and the whole
# reason setup goes through plutil is that a LaunchAgent plist is as likely to
# be binary as XML.
#
# Records APPEND, never truncate: a single supervisor run reads several plists
# and then writes one, and the assertions run across all of those invocations.
#
# Environment:
#   FAKE_PLUTIL_RECORD  file the argv lines are appended to
#                       (default: $TMPDIR/fake-plutil-argv)
#   FAKE_PLUTIL_REAL    the real binary to delegate to (default: /usr/bin/plutil)
#   FAKE_PLUTIL_FAIL    when set, every invocation exits 1 without delegating —
#                       the "this plist cannot be represented" path
set -uo pipefail

RECORD="${FAKE_PLUTIL_RECORD:-${TMPDIR:-/tmp}/fake-plutil-argv}"
REAL="${FAKE_PLUTIL_REAL:-/usr/bin/plutil}"

printf '%s\n' "$*" >> "$RECORD"

if [ -n "${FAKE_PLUTIL_FAIL:-}" ]; then
    exit 1
fi

exec "$REAL" "$@"
