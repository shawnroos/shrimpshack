#!/usr/bin/env bash
# U7 LOAD-BEARING end-to-end test: the lib chain the mode agent drives.
#
# The agent's own model-dispatch isn't bash-testable, so this test exercises
# the BACKING chain the agent orchestrates end to end, against a realistic
# active mode (prose layer + mechanism):
#
#   resolve_candidate <query>           (U2)
#     → mode-add.sh <fqn>               (U5 orchestrator: drift-check + lock)
#       → apply_delta <mode> add-plugin (U3: mutate + R22 + atomic write)
#       → post_write_reload             (U6: reload prompt)
#
# Asserts: the plugin lands, the PROSE LAYER survives the reserialization, the
# audit log records mode_edit_accept, and the reload prompt is emitted. This is
# the composition proof — the per-unit tests prove each link; this proves the
# chain.
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

ADD_LIB="${PLUGIN_ROOT}/lib/mode-add.sh"
MODES_DIR="${HOME}/.claude/modes"
PY="$CLAUDE_MODES_PYTHON3"

# Realistic active mode: prose layer (description/philosophy/scope/lens/
# constraints) + mechanism. This is what a real user mode looks like, and what
# the agent will edit — the reserialization MUST preserve it.
__seed_realistic_mode() {
  mkdir -p "$MODES_DIR"
  cat > "${MODES_DIR}/design.yaml" <<'YAML'
schema_version: 2
name: design
description: |
  Visual and UI work mode.
philosophy: |
  Optimize for design tools and visual output; reject analytical detours.
scope: |
  When shaping interfaces or the presentation of information.
lens: |
  Treat every task as a design problem first.
constraints:
  - Avoid code-heavy work that isn't in service of a visual outcome.
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

# An installable candidate the resolver can find.
__seed_candidate() {
  mkdir -p "${HOME}/.claude/plugins"
  cat > "${HOME}/.claude/plugins/installed_plugins.json" <<'JSON'
{"plugins": {"slack@every-marketplace": [{"scope": "user", "installPath": "/fake/slack"}]}}
JSON
}

__reset() { rm -rf "${HOME}/.claude"; mkdir -m 0700 -p "$MODES_DIR"; }

__yq() {
  "$PY" - "$1" "$2" <<'PYEOF'
import sys, yaml
data = yaml.safe_load(open(sys.argv[1])) or {}
ns = {"data": data}
print(eval(sys.argv[2], {}, ns))
PYEOF
}

# ── End-to-end: agent's add chain ───────────────────────────────────────────
__reset; __seed_realistic_mode; __seed_candidate
M="${MODES_DIR}/design.yaml"

claude_modes_test::it "e2e: agent's add chain (resolve→mode-add→apply→reload) exits 0"
out=$(bash "$ADD_LIB" "slack" 2>&1); rc=$?
claude_modes_test::assert_eq "0" "$rc"

claude_modes_test::it "e2e: target plugin landed in mechanism.enabledPlugins"
claude_modes_test::assert_eq "True" "$(__yq "$M" "'slack@every-marketplace' in data['mechanism']['enabledPlugins']")"

claude_modes_test::it "e2e: pre-existing plugin (figma) still present"
claude_modes_test::assert_eq "True" "$(__yq "$M" "'figma@every-marketplace' in data['mechanism']['enabledPlugins']")"

claude_modes_test::it "e2e: claude-modes self-presence preserved (R22)"
claude_modes_test::assert_eq "True" "$(__yq "$M" "'claude-modes@local-dev' in data['mechanism']['enabledPlugins']")"

# Prose-layer survival across the agent's edit chain.
claude_modes_test::it "e2e: philosophy survived the agent's edit"
claude_modes_test::assert_eq "True" "$(__yq "$M" "'design tools' in (data.get('philosophy') or '')")"
claude_modes_test::it "e2e: scope survived"
claude_modes_test::assert_eq "True" "$(__yq "$M" "'presentation of information' in (data.get('scope') or '')")"
claude_modes_test::it "e2e: lens survived"
claude_modes_test::assert_eq "True" "$(__yq "$M" "'design problem first' in (data.get('lens') or '')")"
claude_modes_test::it "e2e: constraints survived"
claude_modes_test::assert_eq "True" "$(__yq "$M" "len(data.get('constraints') or []) == 1")"

claude_modes_test::it "e2e: audit log records mode_edit_accept"
if grep -q "mode_edit_accept" "${MODES_DIR}/.audit.log"; then claude_modes_test::pass
else claude_modes_test::fail "no mode_edit_accept in audit log"; fi

claude_modes_test::it "e2e: reload prompt emitted (names /reload-plugins)"
case "$out" in *"/reload-plugins"*) claude_modes_test::pass ;;
  *) claude_modes_test::fail "reload prompt not emitted: $out" ;; esac

claude_modes_test::teardown

printf '%s: %d passed, %d failed\n' \
  "$(basename "$0")" \
  "$CLAUDE_MODES_TEST_PASS_COUNT" \
  "$CLAUDE_MODES_TEST_FAIL_COUNT"
[ "$CLAUDE_MODES_TEST_FAIL_COUNT" -eq 0 ]
