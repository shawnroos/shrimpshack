#!/usr/bin/env bash
# PreCompact: flags each programme the compacting session drives, so its write
# verbs wait for `programme.py rules --ack`. Programmes live outside repos, so
# the only gate is a lease file; with none, no Python runs. Always exits 0 and
# never blocks compaction.

set -uo pipefail

__cd_leases="${CLAUDE_AUTO_DATA_DIR:-${HOME:-}/.claude/plugins/data/auto-shrimpshack}/programmes/leases"
__cd_any_lease=0
for __cd_f in "${__cd_leases}"/*.json; do
  [ -e "$__cd_f" ] && __cd_any_lease=1
  break
done
[ "$__cd_any_lease" = 1 ] || exit 0

PYTHON3="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  CLAUDE_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

__cd_stdin_json=""
if [ ! -t 0 ]; then
  __cd_stdin_json="$(cat 2>/dev/null || true)"
fi

"$PYTHON3" "${CLAUDE_PLUGIN_ROOT}/lib/on-pre-compact.py" <<< "$__cd_stdin_json" >/dev/null 2>&1
exit 0
