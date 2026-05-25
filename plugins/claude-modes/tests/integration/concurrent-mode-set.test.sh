#!/usr/bin/env bash
# testing-002 / adv-009 integration: concurrent /mode:set serialization.
#
# Two (or more) concurrent /mode:set invocations against the same repo +
# user-global state must NOT corrupt the catalog. Without the adv-009 flock
# around the whole set_mode critical section, both invocations pass the R26
# sentinel and both mutate ~/.claude (cascade_compile + symlink_rebuild +
# .last-active-mode + per-branch .mode), interleaving into torn state.
#
# Consistency contract after concurrent set-mode races settle:
#   - .last-active-mode contains exactly ONE of the racing targets (a clean,
#     fully-written value — never empty, never a concatenation of two).
#   - <repo>/.claude/modes/<branch>.mode contains exactly ONE valid target.
#   - The per-branch .mode and .last-active-mode agree (both name the SAME
#     winner) — divergence means two writers half-committed.
#   - settings.local.json is valid JSON whose enabledPlugins match the
#     winning mode's tier-3 (not a half-merged mix of both modes' plugins).
#   - No leftover .mode-set.in-progress sentinel.
#
# Deliberate-fail discipline (per feedback_new_tests_need_deliberate_fail_smoke_check):
#   With the lock in place, the racers serialize so fast you cannot tell the
#   lock did anything. So this file ALSO runs the same race with the lock
#   neutered (CLAUDE_MODES_TEST_NO_LOCK=1) across many iterations and asserts
#   that torn state is OBSERVABLE there. If the no-lock path never tears, the
#   test is not actually exercising the race and the locked-path "pass" is
#   meaningless — so we fail loudly in that case.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/tests/helpers/test-helpers.sh"

claude_modes_test::setup

PY="${CLAUDE_MODES_PYTHON3}"
ID="claude-modes@local-dev"

# ──────────────────────────────────────────────────────────────────────
# Scaffolding.

__seed_modes_dir() {
  mkdir -p "${HOME}/.claude/modes"

  cat > "${HOME}/.claude/modes/_global.yaml" <<EOF
schema_version: 2
name: _global
mechanism:
  enabledPlugins:
    "${ID}": true
    "baseline@market": true
EOF
  chmod 0600 "${HOME}/.claude/modes/_global.yaml"

  cat > "${HOME}/.claude/modes/delivery.yaml" <<EOF
schema_version: 2
name: delivery
mechanism:
  enabledPlugins:
    "delivery-plugin@market": true
EOF
  chmod 0600 "${HOME}/.claude/modes/delivery.yaml"

  cat > "${HOME}/.claude/modes/discovery.yaml" <<EOF
schema_version: 2
name: discovery
mechanism:
  enabledPlugins:
    "discovery-plugin@market": true
EOF
  chmod 0600 "${HOME}/.claude/modes/discovery.yaml"
}

__make_repo() {
  local path="$1"
  mkdir -p "$path"
  (
    cd "$path"
    git init -q -b main >/dev/null 2>&1
    git config user.email "test@test"
    git config user.name "test"
    : > .gitkeep
    git add .gitkeep
    git commit -q -m "init" --allow-empty
  )
}

__reset_state() {
  local repo="$1"
  rm -f "${HOME}/.claude/modes/.last-active-mode" \
        "${HOME}/.claude/modes/.mode-set.in-progress" 2>/dev/null
  rm -f "${repo}/.claude/modes/main.mode" \
        "${repo}/.claude/settings.local.json" \
        "${repo}/.claude/modes/.cascade-meta.json" 2>/dev/null
}

# Read a single-line state file with whitespace stripped (empty if absent).
__read_state() {
  local path="$1"
  [ -f "$path" ] || { printf ''; return; }
  tr -d '[:space:]' < "$path" 2>/dev/null
}

# Validate settings.local.json is parseable JSON; print sorted enabledPlugins
# keys, or "INVALID_JSON" if it doesn't parse.
__settings_keys_or_invalid() {
  local path="$1"
  [ -f "$path" ] || { printf 'ABSENT'; return; }
  "$PY" -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("INVALID_JSON"); sys.exit(0)
ep = d.get("enabledPlugins") or {}
print(",".join(sorted(ep.keys())))
' "$path"
}

# Race N set-mode processes (alternating delivery/discovery) against one repo.
# Honors CLAUDE_MODES_TEST_NO_LOCK if exported by the caller.
__race_set_modes() {
  local repo="$1"
  local pids=()
  local i mode
  for i in 1 2 3 4 5 6; do
    if [ $((i % 2)) -eq 0 ]; then mode="delivery"; else mode="discovery"; fi
    ( cd "$repo" && bash "${PLUGIN_ROOT}/lib/set-mode.sh" "$mode" >/dev/null 2>&1 ) &
    pids+=("$!")
  done
  for p in "${pids[@]}"; do wait "$p"; done
}

# Return 0 if the post-race state is CONSISTENT, 1 if torn.
# Torn = empty/invalid state, disagreeing per-branch vs global pointer,
# invalid settings JSON, half-merged plugin set, or leftover sentinel.
__state_is_consistent() {
  local repo="$1"
  local global per_branch keys sentinel

  global=$(__read_state "${HOME}/.claude/modes/.last-active-mode")
  per_branch=$(__read_state "${repo}/.claude/modes/main.mode")
  sentinel=$(__read_state "${HOME}/.claude/modes/.mode-set.in-progress")
  keys=$(__settings_keys_or_invalid "${repo}/.claude/settings.local.json")

  # Sentinel must be cleared.
  [ -z "$sentinel" ] || return 1
  # Both pointers must name a real racing target.
  case "$global" in delivery|discovery) ;; *) return 1 ;; esac
  case "$per_branch" in delivery|discovery) ;; *) return 1 ;; esac
  # The two pointers must AGREE.
  [ "$global" = "$per_branch" ] || return 1
  # settings.local.json must be valid JSON matching the winner's plugin set
  # exactly (baseline + claude-modes + the ONE winning mode's plugin).
  local expected
  if [ "$global" = "delivery" ]; then
    expected="baseline@market,${ID},delivery-plugin@market"
  else
    expected="baseline@market,${ID},discovery-plugin@market"
  fi
  [ "$keys" = "$expected" ] || return 1
  return 0
}

# ──────────────────────────────────────────────────────────────────────
# Part 1 — LOCKED path: every race must settle to consistent state.
# ──────────────────────────────────────────────────────────────────────

__seed_modes_dir
REPO="${HOME}/repo-race"
__make_repo "$REPO"

LOCKED_ITERS=8
locked_torn=0
for iter in $(seq 1 "$LOCKED_ITERS"); do
  __reset_state "$REPO"
  __race_set_modes "$REPO"
  if ! __state_is_consistent "$REPO"; then
    locked_torn=$((locked_torn + 1))
  fi
done

claude_modes_test::it "locked: ${LOCKED_ITERS} concurrent set-mode races all settle to consistent state"
claude_modes_test::assert_eq "0" "$locked_torn"

# ──────────────────────────────────────────────────────────────────────
# Part 2 — DELIBERATE-FAIL: with the lock neutered, torn state must be
# observable. If it never tears, the race isn't being exercised and Part 1's
# pass is meaningless — so a clean no-lock run is itself a test failure.
# ──────────────────────────────────────────────────────────────────────

NO_LOCK_ITERS=20
no_lock_torn=0
for iter in $(seq 1 "$NO_LOCK_ITERS"); do
  __reset_state "$REPO"
  CLAUDE_MODES_TEST_NO_LOCK=1 __race_set_modes "$REPO"
  if ! __state_is_consistent "$REPO"; then
    no_lock_torn=$((no_lock_torn + 1))
  fi
done

claude_modes_test::it "deliberate-fail: lock-disabled races produce observable torn state (>=1 of ${NO_LOCK_ITERS})"
if [ "$no_lock_torn" -ge 1 ]; then
  claude_modes_test::pass
else
  claude_modes_test::fail "lock-disabled races never tore state across ${NO_LOCK_ITERS} iters — the race is not being exercised, so the locked-path pass is not meaningful"
fi

# ─── Fence: TEST_NO_LOCK must never be ENABLED by production code ─────
# The escape hatch is read in cascade-engine.sh and set=1 only by THIS test.
# If any file under lib/ or scripts/ ever sets it to 1, the serialization
# flock is silently disabled in production (sec/adversarial re-review P3).
# This grep-fence makes that a test failure.
claude_modes_test::it "fence: no production file sets CLAUDE_MODES_TEST_NO_LOCK=1"
__offenders=$(grep -rlE "CLAUDE_MODES_TEST_NO_LOCK[[:space:]]*=[[:space:]]*[\"']?1" \
  "${PLUGIN_ROOT}/lib" "${PLUGIN_ROOT}/scripts" 2>/dev/null || true)
if [ -z "$__offenders" ]; then
  claude_modes_test::pass
else
  claude_modes_test::fail "production code enables the test-only lock bypass: ${__offenders}"
fi

# ──────────────────────────────────────────────────────────────────────
# Teardown + summary (format tests/run.sh greps for; fail suite on red).

claude_modes_test::teardown

echo ""
printf '%s: %d passed, %d failed\n' \
  "$(basename "${BASH_SOURCE[0]}")" \
  "${CLAUDE_MODES_TEST_PASS_COUNT}" \
  "${CLAUDE_MODES_TEST_FAIL_COUNT}"

if [ "${CLAUDE_MODES_TEST_FAIL_COUNT}" -gt 0 ]; then
  exit 1
fi
exit 0
