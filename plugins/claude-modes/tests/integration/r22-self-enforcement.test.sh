#!/usr/bin/env bash
# U4 integration: AE5 — R22 self-enforcement.
#
# Scenarios:
#   1. Mode YAML where neither tier_2 nor tier_3 has claude-modes in
#      enabledPlugins → cascade exits non-zero with error containing
#      "claude-modes" + "every mode".
#   2. Mode YAML where tier_3 omits claude-modes but tier_2 has it →
#      cascade proceeds successfully (tier-2 contribution satisfies R22).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/tests/helpers/test-helpers.sh"

claude_modes_test::setup
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/lib/cascade-engine.sh"

ID="claude-modes@local-dev"

REPO="${HOME}/r"
mkdir -p "$REPO"
( cd "$REPO" && git init -q -b main >/dev/null 2>&1 \
  && git config user.email "test@test" \
  && git config user.name "test" )

mkdir -p "${HOME}/.claude/modes"

# ─── Scenario 1: neither tier has claude-modes → R22 violation ──────
claude_modes_test::it "AE5: R22 violation — cascade exits non-zero with named error"
cat > "${HOME}/.claude/modes/_global.yaml" <<'EOF'
schema_version: 2
name: _global
mechanism:
  enabledPlugins:
    "B@market": true
EOF

cat > "${HOME}/.claude/modes/badmode.yaml" <<'EOF'
schema_version: 2
name: badmode
mechanism:
  enabledPlugins:
    "X@market": true
EOF

err=$(claude_modes::cascade_compile "badmode" "$REPO" 2>&1)
rc=$?
# Must be non-zero AND contain both "claude-modes" and "every mode"
if [ "$rc" -ne 0 ] && echo "$err" | grep -q "claude-modes" && echo "$err" | grep -q "every mode"; then
  # The cascade must NOT have written the file
  if [ ! -f "${REPO}/.claude/settings.local.json" ]; then
    claude_modes_test::pass
  else
    claude_modes_test::fail "R22 violation but settings.local.json was written"
  fi
else
  claude_modes_test::fail "expected non-zero + 'claude-modes' + 'every mode'; got rc=$rc, stderr=$err"
fi

# ─── Scenario 2: tier 2 carries claude-modes; tier 3 omits → OK ─────
claude_modes_test::it "AE5: tier 2 satisfies R22 even when tier 3 omits claude-modes"
cat > "${HOME}/.claude/modes/_global.yaml" <<EOF
schema_version: 2
name: _global
mechanism:
  enabledPlugins:
    "${ID}": true
EOF

cat > "${HOME}/.claude/modes/quiet.yaml" <<'EOF'
schema_version: 2
name: quiet
mechanism:
  enabledPlugins:
    "X@market": true
EOF

if claude_modes::cascade_compile "quiet" "$REPO" >/dev/null 2>&1; then
  claude_modes_test::assert_file_exists "${REPO}/.claude/settings.local.json"
else
  claude_modes_test::fail "cascade should have proceeded since tier 2 carries claude-modes"
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
