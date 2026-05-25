#!/usr/bin/env bash
# U5 integration test: /mode:drop orchestrator (lib/mode-drop.sh, a thin
# delegate to the shared edit machinery in lib/mode-add.sh).
#
# Drop semantics differ from add: a plugin drop is a cascade-subtraction into
# disable.enabledPlugins. The headline drop-specific guard is R22 — dropping
# claude-modes itself is refused. Exit-code language is identical to /mode:add.
#
# Output format expected by tests/run.sh:
#   <basename>: N passed, M failed

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/tests/helpers/test-helpers.sh"

claude_modes_test::setup
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
export CLAUDE_MODES_CANONICAL_ID="claude-modes@local-dev"

DROP_LIB="${PLUGIN_ROOT}/lib/mode-drop.sh"
MODES_DIR="${HOME}/.claude/modes"
PY="$CLAUDE_MODES_PYTHON3"

# Seed an active mode that already enables a droppable plugin (so the cascade
# has something to subtract) plus the required claude-modes self-presence.
__seed_design_mode() {
  mkdir -p "$MODES_DIR"
  cat > "${MODES_DIR}/design.yaml" <<'YAML'
schema_version: 2
name: design
description: |
  Visual and UI work mode.
philosophy: |
  Optimize for design tools.
mechanism:
  enabledPlugins:
    "claude-modes@local-dev": true
    "figma@every-marketplace": true
  user_catalog:
    commands: []
    agents: []
YAML
  chmod 0600 "${MODES_DIR}/design.yaml"
  printf 'design' > "${MODES_DIR}/.last-active-mode"
}

__seed_installed() {
  mkdir -p "${HOME}/.claude/plugins"
  cat > "${HOME}/.claude/plugins/installed_plugins.json" <<JSON
{"plugins": {
  "figma@every-marketplace": [{"scope": "user", "installPath": "/fake/a"}],
  "claude-modes@local-dev": [{"scope": "user", "installPath": "/fake/cm"}]
}}
JSON
}

__reset() { rm -rf "${HOME}/.claude"; mkdir -m 0700 -p "$MODES_DIR"; }

__in_disable() {
  "$PY" - "$1" "$2" <<'PYEOF'
import sys, yaml
data = yaml.safe_load(open(sys.argv[1])) or {}
dis = (data.get("disable") or {}).get("enabledPlugins") or []
print("True" if sys.argv[2] in dis else "False")
PYEOF
}

__audit_has() { grep -q "$1" "${MODES_DIR}/.audit.log" 2>/dev/null; }

# Batch-4 Finding 3: the FQN-shortcut path is fail-CLOSED — a direct FQN op
# REQUIRES the current YAML hash as the snapshot (the re-invoke/power-user path
# must prove the YAML is unchanged or refuse). Helper to read it.
__snap() { bash "${PLUGIN_ROOT}/lib/mode-yaml.sh" sha256 "${MODES_DIR}/design.yaml"; }

# ── Happy: drop a plugin → added to disable.enabledPlugins ───────────────────
__reset; __seed_design_mode; __seed_installed
claude_modes_test::it "happy: drop a plugin (with snapshot) → exit 0"
out=$(bash "$DROP_LIB" "figma@every-marketplace" "$(__snap)" 2>/dev/null); rc=$?
claude_modes_test::assert_eq "0" "$rc"
claude_modes_test::it "  ... plugin now in disable.enabledPlugins"
claude_modes_test::assert_eq "True" "$(__in_disable "${MODES_DIR}/design.yaml" "figma@every-marketplace")"

# ── Idempotent: drop again → still exit 0, still present once ────────────────
# Re-snapshot: the first drop mutated the YAML, so the prior hash is now stale.
claude_modes_test::it "idempotent: drop an already-disabled plugin → exit 0"
out=$(bash "$DROP_LIB" "figma@every-marketplace" "$(__snap)" 2>/dev/null); rc=$?
claude_modes_test::assert_eq "0" "$rc"

# ── R22: dropping claude-modes itself is refused ────────────────────────────
__reset; __seed_design_mode; __seed_installed
claude_modes_test::it "R22: drop claude-modes@local-dev → exit 1"
out=$(bash "$DROP_LIB" "claude-modes@local-dev" "$(__snap)" 2>&1); rc=$?
claude_modes_test::assert_eq "1" "$rc"
claude_modes_test::it "  ... R22 message surfaced"
claude_modes_test::assert_contains "$out" "R22"
claude_modes_test::it "  ... YAML unchanged (claude-modes NOT in disable)"
claude_modes_test::assert_eq "False" "$(__in_disable "${MODES_DIR}/design.yaml" "claude-modes@local-dev")"

# ── R22 defense-in-depth: a stale claude-modes@* marketplace is also refused ─
__reset; __seed_design_mode; __seed_installed
claude_modes_test::it "R22 glob: drop claude-modes@stale-mkt → exit 1"
out=$(bash "$DROP_LIB" "claude-modes@stale-mkt" "$(__snap)" 2>&1); rc=$?
claude_modes_test::assert_eq "1" "$rc"

# ── Usage: no arg ───────────────────────────────────────────────────────────
__reset; __seed_design_mode
claude_modes_test::it "usage: no arg → exit 2"
bash "$DROP_LIB" >/dev/null 2>&1; rc=$?
claude_modes_test::assert_eq "2" "$rc"

# ── No active mode ──────────────────────────────────────────────────────────
__reset; __seed_installed
claude_modes_test::it "no-active-mode: refuse → exit 1"
out=$(bash "$DROP_LIB" "figma@every-marketplace" 2>&1); rc=$?
claude_modes_test::assert_eq "1" "$rc"

claude_modes_test::teardown

printf '%s: %d passed, %d failed\n' \
  "$(basename "$0")" \
  "$CLAUDE_MODES_TEST_PASS_COUNT" \
  "$CLAUDE_MODES_TEST_FAIL_COUNT"
[ "$CLAUDE_MODES_TEST_FAIL_COUNT" -eq 0 ]
