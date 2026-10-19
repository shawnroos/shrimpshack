#!/usr/bin/env bash
# auto PermissionDenied / PostToolUse / PostToolUseFailure hook: journal auto-mode
# denials and gh runs for a programme's in-scope sessions.
#
# Gate: no lease file means no programme on this machine, so the hook exits here
# without starting Python. Post-tool events fire on every Bash call, so they also
# exit here unless stdin holds a gh token. Prints nothing; always exits 0.

set -uo pipefail

__cd_leases="${CLAUDE_AUTO_DATA_DIR:-${HOME:-}/.claude/plugins/data/auto-shrimpshack}/programmes/leases"
__cd_any=0
for __cd_f in "${__cd_leases}"/*.json; do
  [ -e "$__cd_f" ] && __cd_any=1
  break
done
[ "$__cd_any" = 1 ] || exit 0

__cd_stdin_json=""
if [ ! -t 0 ]; then
  __cd_stdin_json="$(cat 2>/dev/null || true)"
fi

if [[ $__cd_stdin_json != *'"PermissionDenied"'* ]]; then
  __cd_gh='(^|[^A-Za-z0-9_.-]|\\[nt])gh([[:space:]]|\\[nt]|$)'
  [[ $__cd_stdin_json =~ $__cd_gh ]] || exit 0
fi

PYTHON3="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  CLAUDE_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

exec "$PYTHON3" "${CLAUDE_PLUGIN_ROOT}/lib/on-permission-event.py" <<< "$__cd_stdin_json" >/dev/null 2>&1 || true

exit 0
