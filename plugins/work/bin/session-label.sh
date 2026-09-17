#!/usr/bin/env bash
# The tab bar label: this session's bound scope, or `unbound` (KTD7). herdr runs
# it on the server of the session it labels, and runs it often, so it reads only
# the local record and never Linear. A server with no session shows nothing.
set -u
LIB="${BASH_SOURCE[0]%/*}/../lib"
for f in sanitize.sh session.sh binding.sh session-binding.sh; do
    . "$LIB/$f" 2>/dev/null || exit 0
done
herdr_linear::session_name >/dev/null 2>&1 || exit 0
scope="$(herdr_linear::session_scope 2>/dev/null)" || { printf 'unbound'; exit 0; }
printf '%s' "$scope" | cut -f3 | python3 -c '
import re, sys
print(re.sub(r"[\x00-\x1f\x7f-\x9f]", "", sys.stdin.read()).strip()[:40], end="")'
