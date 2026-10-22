#!/usr/bin/env bash
# auto PostToolUse hook (AskUserQuestion): journal a picker answer given in a
# programme's driving session.
#
# Gate: an empty or missing leases folder, or a session id no lease names, means
# this session drives no programme, so the hook exits without starting Python.
# Always exits 0.

set -uo pipefail

__cd_leases="${CLAUDE_AUTO_DATA_DIR:-${HOME:-}/.claude/plugins/data/auto-shrimpshack}/programmes/leases"
__cd_files=()
for __cd_f in "${__cd_leases}"/*.json; do
  [ -e "$__cd_f" ] && __cd_files+=("$__cd_f")
done
[ "${#__cd_files[@]}" -gt 0 ] || exit 0

PYTHON3="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  CLAUDE_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

__cd_stdin_json=""
if [ ! -t 0 ]; then
  __cd_stdin_json="$(cat 2>/dev/null || true)"
fi

# Anything the shell cannot read exactly (no id, two ids, unusual characters, a \u escape) still goes to Python.
__cd_after_sid="${__cd_stdin_json#*\"session_id\"}"
if [[ $__cd_stdin_json != *\\u* && $__cd_after_sid != *\"session_id\"* \
      && $__cd_stdin_json =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([A-Za-z0-9._-]+)\" ]]; then
  grep -qsF -- "\"${BASH_REMATCH[1]}\"" "${__cd_files[@]}"
  [ $? = 1 ] && exit 0
fi

"$PYTHON3" "${CLAUDE_PLUGIN_ROOT}/lib/on-posttooluse-askuser.py" <<< "$__cd_stdin_json" 2>/dev/null

exit 0
