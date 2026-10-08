#!/usr/bin/env bash
# auto U7 Stop hook: the engine's OWN deliberate-stop guard.
#
# WHY THIS EXISTS (U9 spike — docs/research/native-goal-mechanism-spike.md):
#   Native `/goal` is a CLOSED, model-judged continuation loop with NO external
#   predicate handoff — the engine CANNOT feed it the run-record result. So
#   auto ships its OWN thin Stop hook. This is NOT optional. Its
#   verdict is DETERMINISTIC and engine-owned (read from the run-record's I-1-fresh
#   `exit_predicate_result`), consistent with Shawn's
#   `feedback_deterministic_over_probabilistic_v1` preference.
#
# BLOCK MECHANISM (per U9 §4.2 + ralph-loop/hooks/stop-hook.sh:179-188):
#   To BLOCK a stop, emit `{"decision":"block","reason":"..."}` on stdout and
#   exit 0. This is the binary's `p.preventContinuation` gate, INDEPENDENT of
#   the native goal loop (U9 §2 — the two gates coexist). The U9 doc names exit-2
#   as an alternative, but the codebase convention (ralph-loop) is decision-JSON
#   + exit-0; we match that. "Always exit 0" (rel-001) is about the EXIT CODE,
#   not the decision — blocking-via-decision and exit-0 are not in conflict.
#
# LOOP-SAFETY (the infinite-block trap):
#   Claude Code RE-FIRES Stop after a block; the re-fire carries
#   `stop_hook_active: true`. If we unconditionally blocked we'd build a loop the
#   user cannot escape. So: if `stop_hook_active == true` we ALLOW the stop
#   (exit 0, no decision) regardless of predicate — surfacing a one-line warning
#   via systemMessage. The deterministic gate fires ONCE per stop attempt.
#
# ACTIVE-RUN POLICY:
#   Only the stopping session's own runs count: a task run holds its
#   driving_session_id, a batch holds its host_session_id, and a programme holds
#   the session its lease and record name. A task run or batch that records no
#   session holds every session in the repo. A held run blocks while
#   `exit_predicate_result.met == false` (programmes: while may_stop is false).
#
# READS THE RUN_RECORD LOCK-FREE: the atomic-rename invariant gives a consistent
# snapshot; no flock => no contention with a slow writer => trivially under any
# hook timeout (the 10s cmux budget).
#
# rel-001: presence-gate first; ALWAYS exit 0 at the process level. Heavy work
# exec'd into Python. Mirrors claude-modes/scripts/on-session-start.sh.

set -uo pipefail

# ─── Presence gate (walk up from cwd for a <repo>/.claude/auto dir) ──────
# auto is REPO-scoped (not user-global like claude-modes). The hook
# fires with a cwd we don't fully control; git is NOT an engine dependency, so
# we walk up the directory tree looking for .claude/auto/ rather than
# shelling to git rev-parse (which would hard-fail on a non-git checkout —
# a rel-001 violation). The moment the walk fails, fast no-op exit 0.
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
# programme holds a herdr space, and its driving session's stop is checked.
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

# CLAUDE_PLUGIN_ROOT is set by the harness at hook-invocation time. Defensive
# fallback: derive from this script's location (.claude/hooks/ -> plugin root).
if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  CLAUDE_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

# Capture the Stop event JSON from stdin ONCE (the `stop_hook_active` field
# lives here). `[ ! -t 0 ]` mirrors claude-modes' isatty guard so an interactive
# invocation does not hang on cat.
__cd_stdin_json=""
if [ ! -t 0 ]; then
  __cd_stdin_json="$(cat 2>/dev/null || true)"
fi

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

# Hand off ALL decision logic to Python (consistent snapshot read + loop-safety
# + decision JSON). `|| true` belt-and-braces so even an exec/python failure
# cannot propagate non-zero to the harness.
exec "$PYTHON3" "${CLAUDE_PLUGIN_ROOT}/lib/on-stop.py" "$__cd_repo" <<< "$__cd_stdin_json" || true

# If exec returned (it shouldn't), defensive exit-0.
exit 0
