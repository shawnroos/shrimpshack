#!/usr/bin/env bash
# auto PreToolUse hook: the tracker, settings, behaviours and send guards for a
# programme, and the agreed limit no-destructive-commands. Each needs a lease, so a
# session with no lease starts no Python, and an ordinary Bash command starts none either.
#
# rel-001: presence-gate first; ALWAYS exit 0 at the process level; heavy work
# exec'd into Python. Mirrors .claude/hooks/on-stop.sh.

set -uo pipefail

# Lease gate (runs in every session, repo or not): a lease file means a programme
# holds a space, and the guards in Python apply.
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

# Python's live checks are the send check and the destructive limit on Bash, the tracker guard on
# Linear MCP calls, the settings and behaviours guards and the writes a limit protects.
# Any other call starts no Python.
__cd_settings=0
# Case-insensitive: the macOS file system treats Settings.local.json as the same file.
shopt -s nocasematch
if [[ $__cd_stdin_json == *settings.local.json* ]]; then
  __cd_settings=1
fi
if [[ $__cd_stdin_json == *behaviours* || $__cd_stdin_json == *behaviour-files* ]]; then
  __cd_settings=1
fi
# What a limited session may not write. Python decides; this keeps other calls from starting it.
if [[ $__cd_stdin_json == *programmes* || $__cd_stdin_json == *plugins/cache* \
   || $__cd_stdin_json == *"$CLAUDE_PLUGIN_ROOT"* \
   || $__cd_stdin_json == *disableAllHooks* || $__cd_stdin_json == *allowManagedHooksOnly* \
   || $__cd_stdin_json == *CLAUDE_AUTO_DATA_DIR* ]]; then
  __cd_settings=1
fi
shopt -u nocasematch
[[ $__cd_stdin_json == *'"Bash"'* || $__cd_stdin_json == *'"mcp__'*[Ll]inear* ]] \
  || [ "$__cd_settings" = 1 ] || exit 0
# Edit and MultiEdit are matched only for the guards named above.
__cd_edit='"tool_name"[[:space:]]*:[[:space:]]*"(Multi)?Edit"'
if [ "$__cd_settings" = 0 ] && [[ $__cd_stdin_json =~ $__cd_edit ]]; then
  exit 0
fi

# True when a Bash call's text could match a guard: a loose superset of two tests in Python.
#  - send_guard._mentions_host strips what _HIDING_CHARS names and decodes $'..' before it looks for a
#    host binary, so a hidden name must match here too. Any $'..' goes to Python undecoded.
#  - on-pretooluse-action._DESTRUCTIVE_PATTERNS, on the decoded text. The JSON here writes a tab or a
#    newline as \t or \n, so a pattern's words are matched apart, with anything between.
# tests/integration/check-settings.test.sh fails if a host or a pattern is added without this.
__cd_hosts='herdr|rex|osascript|stubhost'
__cd_destructive='push.*-f|reset.*--hard|(checkout|restore).*\.|clean.*-.*f|branch.*-d|rm.*-(rf|fr)|npm.*publish|gh.*(release.*(create|delete)|repo.*delete|pr.*merge.*--admin)'
__cd_could_match() {
  # bash 3.2's pattern substitution is quadratic: 2 KB takes 0.5 s, and the hook is killed at 10 s.
  # Past this size starting Python is the cheaper test.
  [ "${#__cd_stdin_json}" -le 1500 ] || return 0
  local input="${__cd_stdin_json#*\"tool_input\"}" plain status=1
  [[ $input != *"\$'"* ]] || return 0
  # The JSON of a backslash-newline, which the shell joins away.
  plain="${input//\\\\\\n/}"
  plain="${plain//\$\\\"/}"
  plain="${plain//[\"\'\\]/}"
  shopt -s nocasematch
  if [[ $plain =~ $__cd_hosts || $input =~ $__cd_destructive ]]; then status=0; fi
  shopt -u nocasematch
  return "$status"
}
if [ "$__cd_settings" = 0 ] && [[ $__cd_stdin_json == *'"Bash"'* && $__cd_stdin_json != *'"mcp__'*[Ll]inear* ]] \
  && ! __cd_could_match; then
  exit 0
fi

# Hand off ALL decision logic to Python. `|| true` keeps the PROCESS exit 0 (rel-001).
exec "$PYTHON3" "${CLAUDE_PLUGIN_ROOT}/lib/on-pretooluse-action.py" <<< "$__cd_stdin_json" || true

exit 0
