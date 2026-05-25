#!/usr/bin/env bash
# U9 + later: perf measurements for the SessionStart reconciliation path.
#
# What this measures:
#   1. flock-acquire latency under no contention (target <50ms cold cache).
#   2. No-op fast-path total latency when symlinks already match (target <50ms).
#   3. End-to-end SessionStart reconcile completion (HARD GATE: must be <5s,
#      the SessionStart budget — per plan U9 timeout strategy).
#
# Soft vs hard gates:
#   - Soft (informational only): items 1 + 2 printed to perf-baseline.txt for
#     human eyeball. We do NOT fail the test on Python startup or filesystem
#     variance across machines.
#   - Hard gate: item 3 must complete in <5s, else FAIL — this is the
#     SessionStart budget anchor and represents user-visible regression risk.
#
# Output: appended to tests/perf-baseline.txt (NOT overwritten — historical
# baselines are useful diff context). Each line tags the measurement type +
# date + median + sample count.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/tests/helpers/test-helpers.sh"

PYTHON3="${CLAUDE_MODES_PYTHON3:-/usr/bin/python3}"
RECONCILE="${PLUGIN_ROOT}/lib/reconcile-symlinks.py"
BASELINE_FILE="${PLUGIN_ROOT}/tests/perf-baseline.txt"

SAMPLES=20  # bounded — perf tests should be quick.

# Median (50th percentile) of a space-separated list of integer ms values.
_median_ms() {
  local nums="$1"
  local n
  # shellcheck disable=SC2086
  n=$(printf '%s\n' $nums | wc -l | tr -d ' ')
  [ "$n" -lt 1 ] && { echo "0"; return; }
  # shellcheck disable=SC2086
  printf '%s\n' $nums | sort -n | awk -v n="$n" 'NR==int((n+1)/2){print; exit}'
}

# Time a command in milliseconds. Uses Python for sub-second precision so
# we don't depend on /usr/bin/time -p (which is POSIX-spec but not
# universally available with the same format).
_time_ms() {
  "$PYTHON3" -c "
import subprocess, time, sys
t0 = time.perf_counter()
subprocess.run(['bash', '-c', sys.argv[1]],
               stdout=subprocess.DEVNULL,
               stderr=subprocess.DEVNULL)
t1 = time.perf_counter()
print(int((t1 - t0) * 1000))
" "$1"
}

claude_modes_test::setup

# ──────────────────────────────────────────────────────────────────────────
# Set up a stable target scenario: mode delivery active, live symlinks
# already correct (so subsequent runs all hit the fast path).

mkdir -p "${HOME}/.claude/modes/.user-catalog/commands"
mkdir -p "${HOME}/.claude/modes/.user-catalog/agents"
mkdir -p "${HOME}/.claude/commands"
mkdir -p "${HOME}/.claude/agents"

echo "body" > "${HOME}/.claude/modes/.user-catalog/commands/good.md"
echo "body" > "${HOME}/.claude/modes/.user-catalog/commands/bar.md"
echo "body" > "${HOME}/.claude/modes/.user-catalog/agents/reviewer.md"

cat > "${HOME}/.claude/modes/delivery.yaml" <<'EOF'
schema_version: 2
name: delivery
mechanism:
  enabledPlugins:
    "claude-modes@local-dev": true
  user_catalog:
    commands:
      - good.md
      - bar.md
    agents:
      - reviewer.md
EOF

REPO="${HOME}/repoA"
mkdir -p "$REPO"
( cd "$REPO" \
    && git init -q -b main \
    && git config user.email "test@example.com" \
    && git config user.name "Test User" \
    && echo seed > seed.txt \
    && git add seed.txt \
    && git commit -qm init >/dev/null 2>&1 )
mkdir -p "${REPO}/.claude/modes"
printf 'delivery' > "${REPO}/.claude/modes/main.mode"

# Pre-create live symlinks so the first reconcile hits the fast path.
ln -sf "${HOME}/.claude/modes/.user-catalog/commands/good.md" "${HOME}/.claude/commands/good.md"
ln -sf "${HOME}/.claude/modes/.user-catalog/commands/bar.md"  "${HOME}/.claude/commands/bar.md"
ln -sf "${HOME}/.claude/modes/.user-catalog/agents/reviewer.md" "${HOME}/.claude/agents/reviewer.md"

# Warm the OS page cache once — the first run otherwise measures filesystem
# cold-start, not the hook path itself.
( cd "$REPO" && "$PYTHON3" "$RECONCILE" < /dev/null ) >/dev/null 2>&1

# ──────────────────────────────────────────────────────────────────────────
# Measurement 1 + 2: end-to-end fast-path latency.
# (This is the measurement that matters most — it's what most invocations
# will actually do.) flock-acquire is a sub-step of this; we report the
# total as both because separating them precisely requires instrumenting
# the orchestrator with timing hooks, which adds noise.

CMD="cd '$REPO' && '$PYTHON3' '$RECONCILE' < /dev/null"

samples_fast=""
for _ in $(seq 1 "$SAMPLES"); do
  ms=$(_time_ms "$CMD")
  samples_fast="${samples_fast} ${ms}"
done

median_fast=$(_median_ms "$samples_fast")

# ──────────────────────────────────────────────────────────────────────────
# Measurement 3: hard-gate end-to-end SessionStart shim (which exec's into
# the orchestrator). This is the user-visible budget. Must be <5000ms.

SHIM="${PLUGIN_ROOT}/scripts/on-session-start.sh"
SHIM_CMD="cd '$REPO' && bash '$SHIM' < /dev/null"

samples_shim=""
for _ in $(seq 1 "$SAMPLES"); do
  ms=$(_time_ms "$SHIM_CMD")
  samples_shim="${samples_shim} ${ms}"
done

median_shim=$(_median_ms "$samples_shim")

# Worst-case among shim samples (more conservative gate than median).
max_shim=$(printf '%s\n' $samples_shim | sort -n | tail -1)

# ──────────────────────────────────────────────────────────────────────────
# Persist baseline (append, not overwrite — historical diff is useful).

{
  printf '# u9 perf %s on %s — samples=%d\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$(uname -s -r)" "$SAMPLES"
  printf 'u9-reconcile-fast-path-median-ms | %s | %d\n' "$median_fast" "$SAMPLES"
  printf 'u9-shim-end-to-end-median-ms     | %s | %d\n' "$median_shim" "$SAMPLES"
  printf 'u9-shim-end-to-end-max-ms        | %s | %d\n' "$max_shim" "$SAMPLES"
} >> "$BASELINE_FILE"

# ──────────────────────────────────────────────────────────────────────────
# Assertions: only the SessionStart budget is hard-gated.

claude_modes_test::it "perf: fast-path median ${median_fast}ms recorded (informational, no gate)"
claude_modes_test::pass

claude_modes_test::it "perf: shim median ${median_shim}ms recorded (informational, no gate)"
claude_modes_test::pass

claude_modes_test::it "perf: SessionStart shim worst-case (${max_shim}ms) under 5000ms budget"
if [ "$max_shim" -lt 5000 ]; then
  claude_modes_test::pass
else
  claude_modes_test::fail "max_shim=${max_shim}ms exceeds 5000ms SessionStart budget"
fi

claude_modes_test::teardown

printf '%s: %d passed, %d failed\n' \
  "$(basename "$0")" \
  "$CLAUDE_MODES_TEST_PASS_COUNT" \
  "$CLAUDE_MODES_TEST_FAIL_COUNT"
[ "$CLAUDE_MODES_TEST_FAIL_COUNT" -eq 0 ]
