#!/usr/bin/env bash
# auto PostToolUse (Agent) and SubagentStop hook: record a programme PM's background sub-agent as a worker
# item, and put the item back on the PM when the agent stops. Silent; always exits 0.
#
# Gate: an empty or missing leases folder means no programme on this machine, so the hook exits without
# starting Python.

set -uo pipefail

__sw_leases="${CLAUDE_AUTO_DATA_DIR:-${HOME:-}/.claude/plugins/data/auto-shrimpshack}/programmes/leases"
__sw_files=()
for __sw_f in "${__sw_leases}"/*.json; do
  [ -e "$__sw_f" ] && __sw_files+=("$__sw_f")
done
[ "${#__sw_files[@]}" -gt 0 ] || exit 0

__sw_stdin=""
if [ ! -t 0 ]; then
  __sw_stdin="$(cat 2>/dev/null || true)"
fi
PYTHON3="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  CLAUDE_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

"$PYTHON3" "${CLAUDE_PLUGIN_ROOT}/lib/on-subagent-worker.py" <<< "$__sw_stdin" >/dev/null 2>&1
exit 0
