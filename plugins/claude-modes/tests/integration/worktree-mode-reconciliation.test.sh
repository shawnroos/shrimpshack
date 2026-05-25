#!/usr/bin/env bash
# U9 integration test: lib/reconcile-symlinks.py + scripts/on-session-start.sh
#
# Coverage:
#   1. Same-mode same-repo (fast path): symlinks already correct → no rebuild,
#      no toast, audit outcome=fast-path.
#   2. Different-mode same-repo: branch's recorded intent differs from current
#      live symlinks → rebuild fires, divergence toast marker emitted, audit
#      outcome=diverge-toast.
#   3. No per-branch record falls back to .last-active-mode.
#   4. Detached HEAD → branch_slug=detached-<short-sha>.
#   5. No git repo (cwd=/tmp) → outcome=no-repo OR no-mode (depending on
#      whether a global last-active-mode is set); exits 0.
#   6. flock contention with timeout: two concurrent invocations against the
#      same repo; second blocks then either completes or times out cleanly.
#   7. Hook never propagates errors: malformed YAML / unset HOME → still exits 0.
#   8. Slugify parity: Python slugify matches bash lib/validate-mode-name.sh.
#
# All tests run under claude_modes_test::setup to isolate $HOME.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/tests/helpers/test-helpers.sh"

PYTHON3="${CLAUDE_MODES_PYTHON3:-/usr/bin/python3}"
RECONCILE="${PLUGIN_ROOT}/lib/reconcile-symlinks.py"

# ──────────────────────────────────────────────────────────────────────────
# Helpers.

# Seed user-catalog staging files and a mode YAML referencing them.
# Args:
#   $1 = mode name (e.g., delivery)
#   $2 = comma-separated commands list (or "")
#   $3 = comma-separated agents list (or "")
# Side effect: writes ~/.claude/modes/<name>.yaml, creates staging files.
_seed_mode() {
  local mode="$1"
  local commands_csv="$2"
  local agents_csv="$3"

  local commands_staging="${HOME}/.claude/modes/.user-catalog/commands"
  local agents_staging="${HOME}/.claude/modes/.user-catalog/agents"
  mkdir -p "$commands_staging" "$agents_staging"

  local yaml="${HOME}/.claude/modes/${mode}.yaml"
  {
    printf 'schema_version: 2\n'
    printf 'name: %s\n' "$mode"
    printf 'mechanism:\n'
    printf '  enabledPlugins:\n'
    printf '    "claude-modes@local-dev": true\n'
    printf '  user_catalog:\n'
    printf '    commands:\n'
    if [ -n "$commands_csv" ]; then
      local IFS=','
      for entry in $commands_csv; do
        printf '      - %s\n' "$entry"
        echo "content of $entry" > "${commands_staging}/${entry}"
      done
    else
      printf '      []\n'
    fi
    printf '    agents:\n'
    if [ -n "$agents_csv" ]; then
      local IFS=','
      for entry in $agents_csv; do
        printf '      - %s\n' "$entry"
        echo "content of $entry" > "${agents_staging}/${entry}"
      done
    else
      printf '      []\n'
    fi
  } > "$yaml"
}

# Create symlinks in live commands/agents pointing to staging for entries
# in csv (so we can fake "the live state already reflects mode X").
# Args:
#   $1 = "commands" or "agents"
#   $2 = csv of basenames
_seed_live_symlinks() {
  local kind="$1"
  local csv="$2"
  local staging="${HOME}/.claude/modes/.user-catalog/${kind}"
  local live="${HOME}/.claude/${kind}"
  mkdir -p "$live"
  [ -z "$csv" ] && return 0
  local IFS=','
  for entry in $csv; do
    ln -sf "${staging}/${entry}" "${live}/${entry}"
  done
}

# Get the most-recent session_reconcile audit line.
_last_audit_line() {
  grep -F "event=session_reconcile" "${HOME}/.claude/modes/.audit.log" 2>/dev/null | tail -1
}

# Initialize a small git repo at $1 with at least one commit. Configures
# user.email / user.name locally to avoid global-config dependence.
_init_repo() {
  local repo="$1"
  mkdir -p "$repo"
  ( cd "$repo" && git init -q -b main >/dev/null 2>&1 \
    && git config user.email "test@example.com" \
    && git config user.name "Test User" \
    && echo "seed" > seed.txt \
    && git add seed.txt \
    && git commit -qm "init" >/dev/null 2>&1 )
}

# Write a per-branch .mode file. Args: repo, slug, mode-content
_write_branch_mode() {
  local repo="$1"
  local slug="$2"
  local content="$3"
  mkdir -p "${repo}/.claude/modes"
  printf '%s' "$content" > "${repo}/.claude/modes/${slug}.mode"
}

# Reset state between scenarios: blow away modes/sessions/audit AND any
# previously-created repoA. (Per-branch .mode files live INSIDE the repo,
# so leaving the repo behind leaks state across scenarios.) Keep $HOME.
_reset_state() {
  rm -rf "${HOME}/.claude/modes"
  rm -rf "${HOME}/.claude/commands"
  rm -rf "${HOME}/.claude/agents"
  rm -rf "${HOME}/repoA"
  mkdir -m 0700 -p "${HOME}/.claude/modes"
}

# ──────────────────────────────────────────────────────────────────────────
# Setup once.

claude_modes_test::setup

# ═══════════════════════════════════════════════════════════════════
# Scenario 0: Slugify parity (bash vs Python)
# ═══════════════════════════════════════════════════════════════════

claude_modes_test::it "slugify parity: feature/foo"
bash_slug=$(bash "${PLUGIN_ROOT}/lib/validate-mode-name.sh" slugify-branch "feature/foo")
py_slug=$("$PYTHON3" -c "
import sys, os
sys.path.insert(0, '${PLUGIN_ROOT}/lib')
import importlib.util
spec = importlib.util.spec_from_file_location('r', '${RECONCILE}')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m._slugify_branch('feature/foo'))
")
claude_modes_test::assert_eq "$bash_slug" "$py_slug"

claude_modes_test::it "slugify parity: detached-abc1234"
bash_slug=$(bash "${PLUGIN_ROOT}/lib/validate-mode-name.sh" slugify-branch "detached-abc1234")
py_slug=$("$PYTHON3" -c "
import sys
sys.path.insert(0, '${PLUGIN_ROOT}/lib')
import importlib.util
spec = importlib.util.spec_from_file_location('r', '${RECONCILE}')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m._slugify_branch('detached-abc1234'))
")
claude_modes_test::assert_eq "$bash_slug" "$py_slug"

claude_modes_test::it "slugify parity: feat/with//slashes"
bash_slug=$(bash "${PLUGIN_ROOT}/lib/validate-mode-name.sh" slugify-branch "feat/with//slashes")
py_slug=$("$PYTHON3" -c "
import sys
sys.path.insert(0, '${PLUGIN_ROOT}/lib')
import importlib.util
spec = importlib.util.spec_from_file_location('r', '${RECONCILE}')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m._slugify_branch('feat/with//slashes'))
")
claude_modes_test::assert_eq "$bash_slug" "$py_slug"

# ═══════════════════════════════════════════════════════════════════
# Scenario 1: same-mode same-repo (fast path)
# ═══════════════════════════════════════════════════════════════════

_reset_state
_seed_mode "delivery" "good.md,bar.md" "reviewer.md"

REPO_A="${HOME}/repoA"
_init_repo "$REPO_A"
_write_branch_mode "$REPO_A" "main" "delivery"

# Pre-populate live symlinks so they ALREADY match delivery's manifest.
_seed_live_symlinks "commands" "good.md,bar.md"
_seed_live_symlinks "agents" "reviewer.md"

# Snapshot stat output for an after-comparison.
SNAP_BEFORE=$(ls -la "${HOME}/.claude/commands" "${HOME}/.claude/agents" 2>/dev/null | sort)

claude_modes_test::it "fast path: reconcile exits 0 when symlinks already match"
( cd "$REPO_A" && "$PYTHON3" "$RECONCILE" < /dev/null )
claude_modes_test::assert_eq "0" "$?"

claude_modes_test::it "fast path: audit log records outcome=fast-path"
last=$(_last_audit_line)
claude_modes_test::assert_contains "$last" "outcome=fast-path"

claude_modes_test::it "fast path: audit log records mode=delivery"
last=$(_last_audit_line)
claude_modes_test::assert_contains "$last" "mode=delivery"

claude_modes_test::it "fast path: audit log records branch_slug=main"
last=$(_last_audit_line)
claude_modes_test::assert_contains "$last" "branch_slug=main"

claude_modes_test::it "fast path: no symlinks were modified"
SNAP_AFTER=$(ls -la "${HOME}/.claude/commands" "${HOME}/.claude/agents" 2>/dev/null | sort)
if [ "$SNAP_BEFORE" = "$SNAP_AFTER" ]; then
  claude_modes_test::pass
else
  claude_modes_test::fail "symlink stats changed during a fast-path run"
fi

claude_modes_test::it "fast path: no divergence-toast marker was written"
toast_count=$(find "${HOME}/.claude/modes/.sessions" -name '*.divergence-toast' 2>/dev/null | wc -l | tr -d ' ')
claude_modes_test::assert_eq "0" "$toast_count"

# ═══════════════════════════════════════════════════════════════════
# Scenario 2: different-mode same-repo (rebuild + divergence toast)
# ═══════════════════════════════════════════════════════════════════

_reset_state
_seed_mode "delivery" "good.md,bar.md" "reviewer.md"
_seed_mode "discovery" "good.md" ""

REPO_A="${HOME}/repoA"
_init_repo "$REPO_A"
_write_branch_mode "$REPO_A" "main" "discovery"

# Pre-populate live symlinks reflecting DELIVERY's manifest (drift).
_seed_live_symlinks "commands" "good.md,bar.md"
_seed_live_symlinks "agents" "reviewer.md"

claude_modes_test::it "divergence: reconcile exits 0 when modes diverge"
( cd "$REPO_A" && "$PYTHON3" "$RECONCILE" < /dev/null )
claude_modes_test::assert_eq "0" "$?"

claude_modes_test::it "divergence: bar.md symlink is removed (discovery doesn't include it)"
if [ ! -L "${HOME}/.claude/commands/bar.md" ] && [ ! -e "${HOME}/.claude/commands/bar.md" ]; then
  claude_modes_test::pass
else
  claude_modes_test::fail "bar.md should have been removed by discovery rebuild"
fi

claude_modes_test::it "divergence: good.md symlink survives (discovery does include it)"
if [ -L "${HOME}/.claude/commands/good.md" ]; then
  claude_modes_test::pass
else
  claude_modes_test::fail "good.md should remain after discovery rebuild"
fi

claude_modes_test::it "divergence: reviewer.md agent removed (discovery has agents: [])"
if [ ! -L "${HOME}/.claude/agents/reviewer.md" ] && [ ! -e "${HOME}/.claude/agents/reviewer.md" ]; then
  claude_modes_test::pass
else
  claude_modes_test::fail "reviewer.md should have been removed by discovery rebuild"
fi

claude_modes_test::it "divergence: audit log records outcome=diverge-toast"
last=$(_last_audit_line)
claude_modes_test::assert_contains "$last" "outcome=diverge-toast"

claude_modes_test::it "divergence: divergence-toast marker file exists"
toast_count=$(find "${HOME}/.claude/modes/.sessions" -name '*.divergence-toast' 2>/dev/null | wc -l | tr -d ' ')
if [ "$toast_count" -ge 1 ]; then
  claude_modes_test::pass
else
  claude_modes_test::fail "expected at least one .divergence-toast marker"
fi

claude_modes_test::it "divergence: marker mentions intended mode + found mode"
toast=$(find "${HOME}/.claude/modes/.sessions" -name '*.divergence-toast' 2>/dev/null | head -1)
contents=$(cat "$toast" 2>/dev/null)
if printf '%s' "$contents" | grep -q "discovery" && printf '%s' "$contents" | grep -q "delivery"; then
  claude_modes_test::pass
else
  claude_modes_test::fail "marker contents missing 'discovery' or 'delivery': $contents"
fi

claude_modes_test::it "divergence: marker file mode is 0600"
toast=$(find "${HOME}/.claude/modes/.sessions" -name '*.divergence-toast' 2>/dev/null | head -1)
perms=$(stat -f "%Lp" "$toast" 2>/dev/null || stat -c "%a" "$toast" 2>/dev/null)
claude_modes_test::assert_eq "600" "$perms"

# ═══════════════════════════════════════════════════════════════════
# Scenario 3: no per-branch record → fall back to .last-active-mode
# ═══════════════════════════════════════════════════════════════════

_reset_state
_seed_mode "delivery" "good.md" ""

REPO_A="${HOME}/repoA"
_init_repo "$REPO_A"
# No .mode file written. Set user-global last-active-mode instead.
printf 'delivery' > "${HOME}/.claude/modes/.last-active-mode"

claude_modes_test::it "fallback: reconcile exits 0 with no .mode file (uses last-active-mode)"
( cd "$REPO_A" && "$PYTHON3" "$RECONCILE" < /dev/null )
claude_modes_test::assert_eq "0" "$?"

claude_modes_test::it "fallback: audit log records mode=delivery (from fallback)"
last=$(_last_audit_line)
claude_modes_test::assert_contains "$last" "mode=delivery"

claude_modes_test::it "fallback: rebuild created good.md symlink"
if [ -L "${HOME}/.claude/commands/good.md" ]; then
  claude_modes_test::pass
else
  claude_modes_test::fail "expected good.md symlink after fallback rebuild"
fi

# ═══════════════════════════════════════════════════════════════════
# Scenario 3b: no per-branch record AND no last-active-mode → no-mode
# ═══════════════════════════════════════════════════════════════════

_reset_state
REPO_A="${HOME}/repoA"
_init_repo "$REPO_A"

claude_modes_test::it "no-mode: reconcile exits 0 when neither .mode nor .last-active-mode exists"
( cd "$REPO_A" && "$PYTHON3" "$RECONCILE" < /dev/null )
claude_modes_test::assert_eq "0" "$?"

claude_modes_test::it "no-mode: audit log records outcome=no-mode"
last=$(_last_audit_line)
claude_modes_test::assert_contains "$last" "outcome=no-mode"

# ═══════════════════════════════════════════════════════════════════
# Scenario 4: detached HEAD → branch_slug=detached-<short-sha>
# ═══════════════════════════════════════════════════════════════════

_reset_state
_seed_mode "delivery" "good.md" ""

REPO_A="${HOME}/repoA"
_init_repo "$REPO_A"
( cd "$REPO_A" && git checkout --detach HEAD >/dev/null 2>&1 )
SHORT_SHA=$(cd "$REPO_A" && git rev-parse --short HEAD)

# Write the .mode file using the detached-<sha> slug.
_write_branch_mode "$REPO_A" "detached-${SHORT_SHA}" "delivery"

claude_modes_test::it "detached HEAD: reconcile exits 0"
( cd "$REPO_A" && "$PYTHON3" "$RECONCILE" < /dev/null )
claude_modes_test::assert_eq "0" "$?"

claude_modes_test::it "detached HEAD: audit log records branch_slug=detached-<short-sha>"
last=$(_last_audit_line)
claude_modes_test::assert_contains "$last" "branch_slug=detached-${SHORT_SHA}"

# ═══════════════════════════════════════════════════════════════════
# Scenario 5: no git repo (cwd=/tmp)
# ═══════════════════════════════════════════════════════════════════

_reset_state

claude_modes_test::it "no-repo: reconcile exits 0 from non-git cwd"
( cd /tmp && "$PYTHON3" "$RECONCILE" < /dev/null )
claude_modes_test::assert_eq "0" "$?"

claude_modes_test::it "no-repo: audit log records outcome=no-repo"
last=$(_last_audit_line)
claude_modes_test::assert_contains "$last" "outcome=no-repo"

# ═══════════════════════════════════════════════════════════════════
# Scenario 6: flock contention with timeout
# ═══════════════════════════════════════════════════════════════════

_reset_state
_seed_mode "delivery" "good.md,bar.md" ""

REPO_A="${HOME}/repoA"
_init_repo "$REPO_A"
_write_branch_mode "$REPO_A" "main" "delivery"
# Force a rebuild path (live symlinks don't match) so the lock is actually held.
# Plant ONE pre-existing symlink so the no-op fast path misses; the rebuild
# must add bar.md.
_seed_live_symlinks "commands" "good.md"

claude_modes_test::it "contention: second invocation acquires lock after first releases"
# First runs with a 0.5s in-lock sleep — gives the second a chance to contend.
# Second has timeout budget of 3s (well above 0.5s), so it should succeed.
(
  cd "$REPO_A"
  CLAUDE_MODES_RECONCILE_SLEEP_INSIDE_LOCK=0.5 "$PYTHON3" "$RECONCILE" < /dev/null &
  PID1=$!
  # Tiny delay so the first reliably wins the lock probe.
  sleep 0.1
  "$PYTHON3" "$RECONCILE" < /dev/null
  RC2=$?
  wait $PID1
  RC1=$?
  exit $(( RC1 + RC2 ))
)
claude_modes_test::assert_eq "0" "$?"

# Examine the audit log: at least one outcome=rebuilt and at least one
# outcome=fast-path OR rebuilt are expected (the second saw the first's
# work after waiting and either re-ran a fast path, or rebuilt again).
claude_modes_test::it "contention: both invocations recorded outcomes"
n=$(grep -c "event=session_reconcile" "${HOME}/.claude/modes/.audit.log" 2>/dev/null || echo 0)
if [ "$n" -ge 2 ]; then
  claude_modes_test::pass
else
  claude_modes_test::fail "expected ≥ 2 audit lines, got $n"
fi

# Forced timeout: hold the lock longer than the reconciler's 3s budget so
# the contending invocation must hit the alarm path and audit outcome=timeout.
claude_modes_test::it "contention: timeout path emits outcome=timeout"
# Plant a stale state again so the second would otherwise try to rebuild.
_seed_live_symlinks "commands" "good.md"
rm -f "${HOME}/.claude/commands/bar.md"
(
  cd "$REPO_A"
  CLAUDE_MODES_RECONCILE_SLEEP_INSIDE_LOCK=4 "$PYTHON3" "$RECONCILE" < /dev/null &
  PID1=$!
  sleep 0.2
  "$PYTHON3" "$RECONCILE" < /dev/null
  wait $PID1
)
# The second invocation should have given up around T+3s with outcome=timeout.
if grep -F "event=session_reconcile" "${HOME}/.claude/modes/.audit.log" 2>/dev/null | tail -2 | grep -q "outcome=timeout"; then
  claude_modes_test::pass
else
  # Show the last 2 audit lines for diagnostic.
  diag=$(grep -F "event=session_reconcile" "${HOME}/.claude/modes/.audit.log" 2>/dev/null | tail -2 | tr '\n' '|')
  claude_modes_test::fail "expected outcome=timeout in recent audit; got: $diag"
fi

# ═══════════════════════════════════════════════════════════════════
# Scenario 7: hook never propagates errors (malformed YAML / weird envs)
# ═══════════════════════════════════════════════════════════════════

_reset_state
REPO_A="${HOME}/repoA"
_init_repo "$REPO_A"

# Write a totally broken mode YAML and point the branch at it.
broken_yaml="${HOME}/.claude/modes/broken.yaml"
mkdir -p "$(dirname "$broken_yaml")"
cat > "$broken_yaml" <<'EOF'
schema_version: 2
name: broken
mechanism:
  user_catalog:
    commands: ["unterminated
EOF
_write_branch_mode "$REPO_A" "main" "broken"

claude_modes_test::it "rel-001: broken YAML still exits 0"
( cd "$REPO_A" && "$PYTHON3" "$RECONCILE" < /dev/null )
claude_modes_test::assert_eq "0" "$?"

claude_modes_test::it "rel-001: junk JSON on stdin still exits 0"
( cd "$REPO_A" && printf '{not valid json' | "$PYTHON3" "$RECONCILE" )
claude_modes_test::assert_eq "0" "$?"

claude_modes_test::it "rel-001: missing mode YAML still exits 0"
_reset_state
REPO_A="${HOME}/repoA"
_init_repo "$REPO_A"
_write_branch_mode "$REPO_A" "main" "ghost-mode-that-does-not-exist"
( cd "$REPO_A" && "$PYTHON3" "$RECONCILE" < /dev/null )
claude_modes_test::assert_eq "0" "$?"

claude_modes_test::it "rel-001: missing YAML audits outcome=no-yaml"
last=$(_last_audit_line)
claude_modes_test::assert_contains "$last" "outcome=no-yaml"

# ═══════════════════════════════════════════════════════════════════
# Scenario 7b: session_id parity with inject-prose.sh — the divergence
# toast filename MUST use the harness's session_id (not ppid fallback)
# when JSON {"session_id": "..."} is piped on stdin, or inject-prose.sh
# will never consume the marker.
# ═══════════════════════════════════════════════════════════════════

_reset_state
_seed_mode "delivery" "good.md,bar.md" "reviewer.md"
_seed_mode "discovery" "good.md" ""

REPO_A="${HOME}/repoA"
_init_repo "$REPO_A"
_write_branch_mode "$REPO_A" "main" "discovery"
# Symlinks reflect delivery → divergence path will fire and write a toast.
_seed_live_symlinks "commands" "good.md,bar.md"
_seed_live_symlinks "agents" "reviewer.md"

claude_modes_test::it "session_id parity: stdin JSON sets toast filename"
KNOWN_SID="test-sid-42abcdef"
( cd "$REPO_A" && printf '{"session_id": "%s", "hook_event_name": "SessionStart"}' \
    "$KNOWN_SID" | "$PYTHON3" "$RECONCILE" )
claude_modes_test::assert_eq "0" "$?"

claude_modes_test::it "session_id parity: marker named <sid>.divergence-toast"
expected_marker="${HOME}/.claude/modes/.sessions/${KNOWN_SID}.divergence-toast"
if [ -f "$expected_marker" ]; then
  claude_modes_test::pass
else
  diag=$(ls "${HOME}/.claude/modes/.sessions" 2>/dev/null | tr '\n' ' ')
  claude_modes_test::fail "expected $expected_marker; sessions/ contains: $diag"
fi

# ═══════════════════════════════════════════════════════════════════
# Scenario 7c: .last-active-mode == "claude" (no-modes-active baseline)
# ═══════════════════════════════════════════════════════════════════

_reset_state
# Seed user-catalog staging files (so day-zero manifest is non-empty).
mkdir -p "${HOME}/.claude/modes/.user-catalog/commands"
echo "x" > "${HOME}/.claude/modes/.user-catalog/commands/foo.md"

REPO_A="${HOME}/repoA"
_init_repo "$REPO_A"
# No .mode file. Set user-global last-active-mode to the reserved alias.
printf 'claude' > "${HOME}/.claude/modes/.last-active-mode"

claude_modes_test::it "claude-mode alias: reconcile exits 0 with 'claude' last-active"
( cd "$REPO_A" && "$PYTHON3" "$RECONCILE" < /dev/null )
claude_modes_test::assert_eq "0" "$?"

claude_modes_test::it "claude-mode alias: day-zero rebuild created foo.md symlink"
if [ -L "${HOME}/.claude/commands/foo.md" ]; then
  claude_modes_test::pass
else
  claude_modes_test::fail "expected foo.md symlink (day-zero manifest)"
fi

# ═══════════════════════════════════════════════════════════════════
# Scenario 8: shim → orchestrator integration
# ═══════════════════════════════════════════════════════════════════

_reset_state
_seed_mode "delivery" "good.md" ""
REPO_A="${HOME}/repoA"
_init_repo "$REPO_A"
_write_branch_mode "$REPO_A" "main" "delivery"

claude_modes_test::it "shim: scripts/on-session-start.sh dispatches to reconcile"
( cd "$REPO_A" && bash "${PLUGIN_ROOT}/scripts/on-session-start.sh" < /dev/null )
claude_modes_test::assert_eq "0" "$?"

claude_modes_test::it "shim: rebuild created good.md symlink"
if [ -L "${HOME}/.claude/commands/good.md" ]; then
  claude_modes_test::pass
else
  claude_modes_test::fail "expected good.md symlink after shim-driven reconcile"
fi

claude_modes_test::it "shim: contract anchor written to .session-start.log"
if [ -f "${HOME}/.claude/modes/.session-start.log" ] && \
   grep -q "claude-modes v2: SessionStart reconciler" "${HOME}/.claude/modes/.session-start.log"; then
  claude_modes_test::pass
else
  claude_modes_test::fail ".session-start.log missing or contract anchor absent"
fi

# ═══════════════════════════════════════════════════════════════════
# Scenario 9: shim with no modes/ dir is silent + fast.
# ═══════════════════════════════════════════════════════════════════

# Removing ~/.claude/modes simulates a freshly-uninstalled state.
rm -rf "${HOME}/.claude/modes"
claude_modes_test::it "presence-gate: shim exits 0 silently when ~/.claude/modes absent"
( cd /tmp && bash "${PLUGIN_ROOT}/scripts/on-session-start.sh" < /dev/null )
claude_modes_test::assert_eq "0" "$?"

# ──────────────────────────────────────────────────────────────────────────
claude_modes_test::teardown

printf '%s: %d passed, %d failed\n' \
  "$(basename "$0")" \
  "$CLAUDE_MODES_TEST_PASS_COUNT" \
  "$CLAUDE_MODES_TEST_FAIL_COUNT"
[ "$CLAUDE_MODES_TEST_FAIL_COUNT" -eq 0 ]
