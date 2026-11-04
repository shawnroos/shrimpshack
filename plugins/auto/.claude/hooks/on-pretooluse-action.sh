#!/usr/bin/env bash
# auto PreToolUse hook: the tracker, settings, behaviours and send guards for a
# programme. Each needs a lease, so a session with no lease starts no Python.
#
# The destructive check in lib/on-pretooluse-action.py is off by default, so a
# destructive command is not refused and does not pause a run.
#
# rel-001: presence-gate first; ALWAYS exit 0 at the process level; heavy work
# exec'd into Python. Mirrors .claude/hooks/on-stop.sh.

set -uo pipefail

# Finds repo_root for Python's dormant destructive check. It gates nothing here.
__cd_find_repo() {
  local dir="${PWD}"
  while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    if [ -d "${dir}/.claude/auto" ]; then
      printf '%s' "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

# Lease gate (runs in every session, repo or not): a lease file means a programme
# holds a space, and the guards in Python apply.
__cd_leases="${CLAUDE_AUTO_DATA_DIR:-${HOME:-}/.claude/plugins/data/auto-shrimpshack}/programmes/leases"
__cd_any_lease=0
for __cd_f in "${__cd_leases}"/*.json; do
  [ -e "$__cd_f" ] && __cd_any_lease=1
  break
done

[ "$__cd_any_lease" = 1 ] || exit 0

__cd_repo="$(__cd_find_repo)" || __cd_repo=""
if [ -n "$__cd_repo" ] && [ ! -d "${__cd_repo}/.claude/auto" ]; then
  __cd_repo=""
fi

PYTHON3="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  CLAUDE_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

__cd_stdin_json=""
if [ ! -t 0 ]; then
  __cd_stdin_json="$(cat 2>/dev/null || true)"
fi

# Python's live checks are the send check on Bash, the tracker guard on Linear
# MCP calls and the settings and behaviours guards. Any other call starts no Python.
__cd_settings=0
# Case-insensitive: the macOS file system treats Settings.local.json as the same file.
shopt -s nocasematch
if [[ $__cd_stdin_json == *settings.local.json* ]]; then
  __cd_settings=1
fi
if [[ $__cd_stdin_json == *behaviours* || $__cd_stdin_json == *behaviour-files* ]]; then
  __cd_settings=1
fi
shopt -u nocasematch
[[ $__cd_stdin_json == *'"Bash"'* || $__cd_stdin_json == *'"mcp__'*[Ll]inear* ]] \
  || [ "$__cd_settings" = 1 ] || exit 0
# Edit and MultiEdit are matched only for the settings guard.
__cd_edit='"tool_name"[[:space:]]*:[[:space:]]*"(Multi)?Edit"'
if [ "$__cd_settings" = 0 ] && [[ $__cd_stdin_json =~ $__cd_edit ]]; then
  exit 0
fi

# Hand off ALL decision logic to Python. `|| true` keeps the PROCESS exit 0 (rel-001).
exec "$PYTHON3" "${CLAUDE_PLUGIN_ROOT}/lib/on-pretooluse-action.py" "$__cd_repo" <<< "$__cd_stdin_json" || true

exit 0
