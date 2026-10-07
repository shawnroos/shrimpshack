#!/usr/bin/env bash
# auto U4 PreToolUse hook (destructive-action backstop): the deterministic
# irreversible-operation gate over Bash/Write.
#
# WHY THIS EXISTS (KTD-4/5):
#   The AskUserQuestion gate only intercepts decisions to *ask*, never decisions
#   to *act*. This second hook matches Bash command / Write content against the
#   CLAUDE.md-anchored destructive set (push --force, reset --hard, checkout .,
#   restore ., clean -f / git clean -fdx, branch -D, rm -rf, known publish
#   endpoints) and, under the SAME live-run + session_id gate, escalates via the
#   pause handoff — independent of any question. This gives the "irreversible/
#   destructive" boundary a real enforcement mechanism rather than prose the
#   agent might ignore.
#
# FAILS CLOSED (the action backstop's asymmetry vs the question gate — KTD-4):
#   on a confirmed destructive command for a confirmed live run, the hook PAUSES
#   the run (driver=manual + blocked_on) UNCONDITIONALLY — even if the deny
#   contract is unavailable. It never degrades to silent-allow on a destructive
#   match. The write happens in the sibling lib/*.py; this wrapper still always
#   exits 0 at the process level (the halt is on the run-record, not the exit code).
#
# rel-001: presence-gate first; ALWAYS exit 0 at the process level; heavy work
# exec'd into Python. Mirrors .claude/hooks/on-stop.sh.

set -uo pipefail

# ─── Presence gate (walk up from cwd for a <repo>/.claude/auto dir) ──────
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

# Programme gate (runs in every session, repo or not): a lease file means a
# programme holds a herdr space, and herdr sends to its driver's pane are checked.
__cd_leases="${CLAUDE_AUTO_DATA_DIR:-${HOME:-}/.claude/plugins/data/auto-shrimpshack}/programmes/leases"
__cd_any_lease=0
for __cd_f in "${__cd_leases}"/*.json; do
  [ -e "$__cd_f" ] && __cd_any_lease=1
  break
done

__cd_repo="$(__cd_find_repo)" || __cd_repo=""
if [ -n "$__cd_repo" ] && [ ! -d "${__cd_repo}/.claude/auto" ]; then
  __cd_repo=""
fi
[ -n "$__cd_repo" ] || [ "$__cd_any_lease" = 1 ] || exit 0

PYTHON3="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  CLAUDE_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

__cd_stdin_json=""
if [ ! -t 0 ]; then
  __cd_stdin_json="$(cat 2>/dev/null || true)"
fi

# Outside a repo the only check is the driver-pane send check, which needs
# "herdr" in the command; a \u escape could hide it, so that goes to Python too.
if [ -z "$__cd_repo" ]; then
  shopt -s nocasematch
  [[ $__cd_stdin_json == *herdr* || $__cd_stdin_json == *\\u* ]] || exit 0
  shopt -u nocasematch
fi

# Hand off ALL decision logic to Python. `|| true` keeps the PROCESS exit 0
# (rel-001); the fail-closed halt is recorded on the RUN_RECORD inside the .py, not
# via a non-zero exit code.
exec "$PYTHON3" "${CLAUDE_PLUGIN_ROOT}/lib/on-pretooluse-action.py" "$__cd_repo" <<< "$__cd_stdin_json" || true

exit 0
