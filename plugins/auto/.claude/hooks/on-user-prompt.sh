#!/usr/bin/env bash
# auto UserPromptSubmit hook: capture prompts typed into a programme's driving
# session, and takeover/handover/end requests from any session.
#
# Gate: an empty or missing leases folder means no programme on this machine,
# so the hook exits here without starting Python. Always exits 0.

set -uo pipefail

__cd_leases="${CLAUDE_AUTO_DATA_DIR:-${HOME:-}/.claude/plugins/data/auto-shrimpshack}/programmes/leases"
__cd_any=0
for __cd_f in "${__cd_leases}"/*.json; do
  [ -e "$__cd_f" ] && __cd_any=1
  break
done
[ "$__cd_any" = 1 ] || exit 0

PYTHON3="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  CLAUDE_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

"$PYTHON3" "${CLAUDE_PLUGIN_ROOT}/lib/on-user-prompt.py" 2>/dev/null

exit 0
