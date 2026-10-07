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

__cd_stdin_json=""
if [ ! -t 0 ]; then
  __cd_stdin_json="$(cat 2>/dev/null || true)"
fi

# Python acts only for a session some lease names, so a session id that no lease
# file contains ends the hook here. Anything the shell cannot read exactly (no id,
# two ids, unusual characters, a \u escape) still goes to Python.
__cd_named=1
__cd_after_sid="${__cd_stdin_json#*\"session_id\"}"
if [[ $__cd_stdin_json != *\\u* && $__cd_after_sid != *\"session_id\"* \
      && $__cd_stdin_json =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([A-Za-z0-9._-]+)\" ]]; then
  grep -qsF -- "\"${BASH_REMATCH[1]}\"" "${__cd_leases}"/*.json
  [ $? = 1 ] && __cd_named=0
fi
# Takeover, handover and end requests are journaled from any session.
[ "$__cd_named" = 1 ] || [[ $__cd_stdin_json == *auto:programme-* ]] || exit 0

"$PYTHON3" "${CLAUDE_PLUGIN_ROOT}/lib/on-user-prompt.py" <<< "$__cd_stdin_json" 2>/dev/null

exit 0
