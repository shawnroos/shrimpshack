#!/usr/bin/env bash
# auto U7 SessionStart hook: resurrection / handoff surfacing.
#
# A self-paced ScheduleWakeup pulse chain does NOT survive a full session exit
# (in-session only; durable cron is denied by cmux). No work is lost — the
# run-record is durable on disk and each background agent self-writes its verdict
# atomically — but the lost re-arm leaves a run "orphaned" (no live driver).
# This hook SURFACES resumable runs at the start of a fresh session so the
# operator can `/auto-resume` them. It SURFACES ONLY — it never auto-runs
# (auto-resume is U8, spike-gated).
#
# For each <repo>/.claude/auto/*.json:
#   * loop_phase == "done"                          -> skip.
#   * loop_phase == "handoff" AND handoff_paused == true  -> handoff-specific hint
#     (plan complete; awaiting work confirmation). Checked BEFORE the time-based
#     orphan branch (schema §5 I-3 — handoff is the INTENTIONAL orphan).
#   * else if loop.driver == "manual" OR loop.last_beat_at older than GRACE
#     (4200s; the pulse chain died with a prior session) -> resume hint.
#
# rel-001: presence-gate first; ALWAYS exit 0 (never block session start).
# Heavy work exec'd into Python. Mirrors claude-modes/scripts/on-session-start.sh.

set -uo pipefail

PYTHON3="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  CLAUDE_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

__cd_stdin_json=""
if [ ! -t 0 ]; then
  __cd_stdin_json="$(cat 2>/dev/null || true)"
fi

# Session registry: runs in every herdr pane, before the presence gate, because
# a programme's sessions live in any repo or none. Its stdout must stay silent:
# SessionStart output becomes session context. Under the test harness it runs
# only with a test data dir, or a suite run inside herdr would report test
# sessions to the real herdr and write the real registry.
if [ -n "${HERDR_PANE_ID:-}" ] && { [ -z "${CLAUDE_AUTO_TEST_HARNESS:-}" ] || [ -n "${CLAUDE_AUTO_DATA_DIR:-}" ]; }; then
  "$PYTHON3" "${CLAUDE_PLUGIN_ROOT}/lib/session_registry.py" record <<< "$__cd_stdin_json" >/dev/null 2>&1
fi

# ─── Presence gate (walk up from cwd for a <repo>/.claude/auto dir) ──────
# auto is REPO-scoped. git is NOT an engine dependency, so we walk up
# the tree rather than shelling to git rev-parse (which would hard-fail on a
# non-git checkout). Fast no-op exit 0 when the walk fails and no lease exists.
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

# Programme gate: a lease file means a programme exists, and its driving session
# gets the rules in force back, from any cwd.
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

if [ -z "$__cd_repo" ]; then
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
  [ "$__cd_named" = 1 ] || exit 0
fi

# Hand off the per-run-record scan + GRACE/orphan/handoff classification to Python
# (which imports run_record.py's is_orphaned + GRACE_SECONDS — never hardcoded).
# It prints surfacing lines on stdout; the harness shows them to the operator.
# `|| true` belt-and-braces so an exec/python failure cannot propagate non-zero.
exec "$PYTHON3" "${CLAUDE_PLUGIN_ROOT}/lib/on-session-start.py" "$__cd_repo" <<< "$__cd_stdin_json" || true

# If exec returned (it shouldn't), defensive exit-0.
exit 0
