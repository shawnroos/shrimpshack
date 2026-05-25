#!/usr/bin/env bash
# U4 integration: AE8 — cross-repo filesystem isolation.
#
# Scenario (filesystem-only verification per scope-guardian note):
#   Two tmpdir repos under isolated $HOME. Run cascade in repoA with
#   mode=delivery, in repoB with mode=discovery. Assert:
#     - <repoA>/.claude/settings.local.json exists
#     - <repoB>/.claude/settings.local.json exists
#     - The two files have different content
#     - Neither file references the other's mode
#
# NOT testing: live Claude session per-repo cascade application. That's
# handled by Claude Code's native settings cascade.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/tests/helpers/test-helpers.sh"

claude_modes_test::setup
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/lib/cascade-engine.sh"

PY="${CLAUDE_MODES_PYTHON3}"
ID="claude-modes@local-dev"

# Tier 2: shared baseline carrying claude-modes.
mkdir -p "${HOME}/.claude/modes"
cat > "${HOME}/.claude/modes/_global.yaml" <<EOF
schema_version: 2
name: _global
mechanism:
  enabledPlugins:
    "${ID}": true
EOF

# Tier 3: delivery + discovery, each adds a unique plugin.
cat > "${HOME}/.claude/modes/delivery.yaml" <<EOF
schema_version: 2
name: delivery
mechanism:
  enabledPlugins:
    "delivery-plugin@market": true
EOF

cat > "${HOME}/.claude/modes/discovery.yaml" <<EOF
schema_version: 2
name: discovery
mechanism:
  enabledPlugins:
    "discovery-plugin@market": true
EOF

# Create two repos.
REPO_A="${HOME}/repoA"
REPO_B="${HOME}/repoB"
mkdir -p "$REPO_A" "$REPO_B"
for r in "$REPO_A" "$REPO_B"; do
  ( cd "$r" && git init -q -b main >/dev/null 2>&1 \
    && git config user.email "test@test" \
    && git config user.name "test" )
done

# ─── Run cascade in each repo with distinct mode ────────────────────
claude_modes_test::it "AE8: cascade in repoA(delivery) writes own settings.local.json"
if claude_modes::cascade_compile "delivery" "$REPO_A" >/dev/null 2>&1; then
  claude_modes_test::assert_file_exists "${REPO_A}/.claude/settings.local.json"
else
  claude_modes_test::fail "cascade_compile failed for repoA"
fi

claude_modes_test::it "AE8: cascade in repoB(discovery) writes own settings.local.json"
if claude_modes::cascade_compile "discovery" "$REPO_B" >/dev/null 2>&1; then
  claude_modes_test::assert_file_exists "${REPO_B}/.claude/settings.local.json"
else
  claude_modes_test::fail "cascade_compile failed for repoB"
fi

# ─── Content distinctness ──────────────────────────────────────────
claude_modes_test::it "AE8: repoA and repoB settings.local.json differ"
hashA=$("$PY" -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "${REPO_A}/.claude/settings.local.json")
hashB=$("$PY" -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "${REPO_B}/.claude/settings.local.json")
claude_modes_test::assert_ne "$hashA" "$hashB"

# ─── repoA file does NOT reference discovery plugin ─────────────────
claude_modes_test::it "AE8: repoA settings.local.json does not mention discovery-plugin"
if grep -q "discovery-plugin" "${REPO_A}/.claude/settings.local.json"; then
  claude_modes_test::fail "repoA references discovery-plugin (cross-repo leak)"
else
  claude_modes_test::pass
fi

claude_modes_test::it "AE8: repoB settings.local.json does not mention delivery-plugin"
if grep -q "delivery-plugin" "${REPO_B}/.claude/settings.local.json"; then
  claude_modes_test::fail "repoB references delivery-plugin (cross-repo leak)"
else
  claude_modes_test::pass
fi

# ─── repoA has delivery-plugin; repoB has discovery-plugin ──────────
claude_modes_test::it "AE8: repoA enabledPlugins contains delivery-plugin"
if grep -q "delivery-plugin" "${REPO_A}/.claude/settings.local.json"; then
  claude_modes_test::pass
else
  claude_modes_test::fail "repoA missing delivery-plugin"
fi

claude_modes_test::it "AE8: repoB enabledPlugins contains discovery-plugin"
if grep -q "discovery-plugin" "${REPO_B}/.claude/settings.local.json"; then
  claude_modes_test::pass
else
  claude_modes_test::fail "repoB missing discovery-plugin"
fi

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
