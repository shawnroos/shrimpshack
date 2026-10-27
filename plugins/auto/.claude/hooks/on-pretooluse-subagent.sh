#!/usr/bin/env bash
# rel-001: always exit 0; a hook failure must never block the main session's tools.

set -uo pipefail

PYTHON3="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  CLAUDE_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

__sa_stdin=""
if [ ! -t 0 ]; then
  __sa_stdin="$(cat 2>/dev/null || true)"
fi
# Only a sub-agent's call carries agent_id; the main session pays one string test.
[[ $__sa_stdin == *'"agent_id"'* ]] || exit 0

"$PYTHON3" "${CLAUDE_PLUGIN_ROOT}/lib/on-pretooluse-subagent.py" <<< "$__sa_stdin" || true
exit 0
