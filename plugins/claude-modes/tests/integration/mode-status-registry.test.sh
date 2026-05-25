#!/usr/bin/env bash
# U12 integration: /mode:status + /mode:registry + mode-author skill.
#
# Coverage:
#   - /mode:status with no active mode (Claude Mode baseline)
#   - /mode:status with active mode (per-branch pointer + .last-active-mode fallback)
#   - /mode:status with _repo.yaml present (tier 4 visible)
#   - /mode:status with cascade-meta sidecar present
#   - /mode:status carries the R23 drift-deferral message
#   - /mode:registry with no modes
#   - /mode:registry with 3 modes (_global excluded, real modes listed)
#   - /mode:registry --new surfaces the mode-author skill pointer
#   - mode-author SKILL.md carries the "hooks live in" redirect
#
# Pattern follows tests/integration/cascade-disable-block.test.sh:
#   - HOME isolation via test-helpers.sh
#   - Real bash sourcing of lib/status.sh and lib/registry.sh
#   - Capture stdout into a variable, assert with contains/eq

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/tests/helpers/test-helpers.sh"

# ─── Helpers shared across test groups ────────────────────────────────

__seed_global_yaml() {
  mkdir -p "${HOME}/.claude/modes"
  cat > "${HOME}/.claude/modes/_global.yaml" <<EOF
schema_version: 2
name: _global
description: Always-active baseline.
mechanism:
  enabledPlugins:
    "claude-modes@local-dev": true
EOF
  chmod 0600 "${HOME}/.claude/modes/_global.yaml"
}

__seed_mode_delivery() {
  cat > "${HOME}/.claude/modes/delivery.yaml" <<EOF
schema_version: 2
name: delivery
description: |
  Delivery mode for the shipping phase.
mechanism:
  enabledPlugins:
    "compound-engineering@market": true
  user_catalog:
    commands:
      - foo.md
    agents: []
philosophy: |
  Quality is non-negotiable.
constraints:
  - tests pass
EOF
  chmod 0600 "${HOME}/.claude/modes/delivery.yaml"
}

__seed_mode_discovery() {
  cat > "${HOME}/.claude/modes/discovery.yaml" <<EOF
schema_version: 2
name: discovery
description: Discovery mode for exploration.
mechanism:
  enabledPlugins: {}
  user_catalog:
    commands: []
    agents: []
philosophy: |
  Sprawl is by design.
EOF
  chmod 0600 "${HOME}/.claude/modes/discovery.yaml"
}

__seed_mode_minimal() {
  # No prose layer; tests prose-detection.
  cat > "${HOME}/.claude/modes/minimal.yaml" <<EOF
schema_version: 2
name: minimal
description: minimal mode with no prose layer.
mechanism:
  enabledPlugins: {}
EOF
  chmod 0600 "${HOME}/.claude/modes/minimal.yaml"
}

__make_repo() {
  local repo="$1"
  mkdir -p "$repo"
  ( cd "$repo" && git init -q -b main >/dev/null 2>&1 \
    && git config user.email "test@test" \
    && git config user.name "test" )
}

# ──────────────────────────────────────────────────────────────────────
# Group A: /mode:status
# ──────────────────────────────────────────────────────────────────────

claude_modes_test::setup
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/lib/status.sh"

# Test 1: no active mode (Claude Mode), no repo
claude_modes_test::it "status: no active mode reports 'no modes active' header"
__seed_global_yaml
output=$( cd "$HOME" && claude_modes::status 2>&1 )
claude_modes_test::assert_contains "$output" "no modes active"

claude_modes_test::it "status: tier 1 ~/.claude/settings.json is listed (always)"
# tier 1 path is mentioned regardless of whether the file exists in sandbox
claude_modes_test::assert_contains "$output" "${HOME}/.claude/settings.json"

claude_modes_test::it "status: tier 2 ~/.claude/modes/_global.yaml is listed and contributed"
claude_modes_test::assert_contains "$output" "Tier 2 [contributed]"

claude_modes_test::it "status: drift-deferred message present"
claude_modes_test::assert_contains "$output" "Drift detection deferred to V2.1"

claude_modes_test::teardown

# Test 2: active mode via .last-active-mode fallback, in a repo
claude_modes_test::setup
. "${PLUGIN_ROOT}/lib/status.sh"

__seed_global_yaml
__seed_mode_delivery
REPO="${HOME}/repo-active"
__make_repo "$REPO"
printf 'delivery' > "${HOME}/.claude/modes/.last-active-mode"

claude_modes_test::it "status: active mode read from .last-active-mode fallback"
output=$( cd "$REPO" && claude_modes::status 2>&1 )
claude_modes_test::assert_contains "$output" "Active mode: delivery"

claude_modes_test::it "status: tier 3 delivery.yaml is contributed when active mode set"
claude_modes_test::assert_contains "$output" "Tier 3 [contributed]"

claude_modes_test::it "status: tier 3 path mentions delivery.yaml"
claude_modes_test::assert_contains "$output" "delivery.yaml"

claude_modes_test::teardown

# Test 3: tier 4 _repo.yaml present
claude_modes_test::setup
. "${PLUGIN_ROOT}/lib/status.sh"

__seed_global_yaml
__seed_mode_delivery
REPO="${HOME}/repo-with-tier4"
__make_repo "$REPO"
printf 'delivery' > "${HOME}/.claude/modes/.last-active-mode"
mkdir -p "${REPO}/.claude/modes"
cat > "${REPO}/.claude/modes/_repo.yaml" <<EOF
schema_version: 2
name: _repo
description: repo baseline
mechanism:
  enabledPlugins:
    "repo-specific@local": true
EOF
chmod 0600 "${REPO}/.claude/modes/_repo.yaml"

# agent-native re-review fix: presence != contribution. With _repo.yaml on
# disk but NO cascade run (no sidecar), tier-4 was never merged → status must
# show [not contributed], NOT a false [contributed] based on file existence.
claude_modes_test::it "status: tier 4 _repo.yaml present but no cascade → [not contributed]"
output=$( cd "$REPO" && claude_modes::status 2>&1 )
claude_modes_test::assert_contains "$output" "Tier 4 [not contributed]"

claude_modes_test::it "status: tier 4 path mentions _repo.yaml"
claude_modes_test::assert_contains "$output" "_repo.yaml"

# When the sidecar's source_modes DOES list _repo.yaml (cascade merged it),
# status must show [contributed] — ground truth is the sidecar, not the file.
claude_modes_test::it "status: tier 4 [contributed] when sidecar source_modes lists _repo.yaml"
mkdir -p "${REPO}/.claude"
printf '{"enabledPlugins":{}}' > "${REPO}/.claude/settings.local.json"
cat > "${REPO}/.claude/modes/.cascade-meta.json" <<'EOF'
{
  "tool": "claude-modes",
  "version": "2.0",
  "fingerprint": "deadbeef",
  "compiled_at": "2026-05-21T00:00:00Z",
  "source_modes": ["_global.yaml", "delivery", "_repo.yaml"]
}
EOF
chmod 0600 "${REPO}/.claude/modes/.cascade-meta.json"
output=$( cd "$REPO" && claude_modes::status 2>&1 )
claude_modes_test::assert_contains "$output" "Tier 4 [contributed]"

claude_modes_test::teardown

# Test 4: cascade-meta sidecar present
claude_modes_test::setup
. "${PLUGIN_ROOT}/lib/status.sh"

__seed_global_yaml
__seed_mode_delivery
REPO="${HOME}/repo-with-meta"
__make_repo "$REPO"
printf 'delivery' > "${HOME}/.claude/modes/.last-active-mode"

# Pre-populate settings.local.json + cascade-meta sidecar.
mkdir -p "${REPO}/.claude/modes"
cat > "${REPO}/.claude/settings.local.json" <<'EOF'
{
  "enabledPlugins": {
    "claude-modes@local-dev": true,
    "compound-engineering@market": true
  }
}
EOF
chmod 0600 "${REPO}/.claude/settings.local.json"

cat > "${REPO}/.claude/modes/.cascade-meta.json" <<'EOF'
{
  "tool": "claude-modes",
  "version": "2.0",
  "fingerprint": "abc123",
  "compiled_at": "2026-05-18T12:00:00Z",
  "source_modes": ["_global.yaml", "delivery"]
}
EOF
chmod 0600 "${REPO}/.claude/modes/.cascade-meta.json"

claude_modes_test::it "status: sidecar path is included in output"
output=$( cd "$REPO" && claude_modes::status 2>&1 )
claude_modes_test::assert_contains "$output" ".cascade-meta.json"

claude_modes_test::it "status: compiled plugin catalog is rendered"
claude_modes_test::assert_contains "$output" "compound-engineering@market"

claude_modes_test::it "status: settings.local.json path is included"
claude_modes_test::assert_contains "$output" "settings.local.json"

claude_modes_test::teardown

# Test 5: per-branch pointer takes precedence over .last-active-mode
claude_modes_test::setup
. "${PLUGIN_ROOT}/lib/status.sh"

__seed_global_yaml
__seed_mode_delivery
__seed_mode_discovery
REPO="${HOME}/repo-perbranch"
__make_repo "$REPO"

# Per-branch pointer says discovery; fallback says delivery.
mkdir -p "${REPO}/.claude/modes"
# Default init branch is "main".
printf 'discovery' > "${REPO}/.claude/modes/main.mode"
printf 'delivery'  > "${HOME}/.claude/modes/.last-active-mode"

claude_modes_test::it "status: per-branch pointer beats user-global fallback"
output=$( cd "$REPO" && claude_modes::status 2>&1 )
claude_modes_test::assert_contains "$output" "Active mode: discovery"

claude_modes_test::teardown

# ──────────────────────────────────────────────────────────────────────
# Group B: /mode:registry
# ──────────────────────────────────────────────────────────────────────

# Test 6: empty modes dir
claude_modes_test::setup
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/lib/registry.sh"

claude_modes_test::it "registry: empty modes dir reports 'No modes defined'"
output=$( claude_modes::registry 2>&1 )
claude_modes_test::assert_contains "$output" "No modes defined"

claude_modes_test::teardown

# Test 7: three modes (delivery, discovery, minimal) plus _global.yaml.
# _global must NOT appear as a listed mode.
claude_modes_test::setup
. "${PLUGIN_ROOT}/lib/registry.sh"

__seed_global_yaml
__seed_mode_delivery
__seed_mode_discovery
__seed_mode_minimal

claude_modes_test::it "registry: lists all three real modes"
output=$( claude_modes::registry 2>&1 )
claude_modes_test::assert_contains "$output" "delivery"

claude_modes_test::it "registry: discovery is listed"
claude_modes_test::assert_contains "$output" "discovery"

claude_modes_test::it "registry: minimal is listed"
claude_modes_test::assert_contains "$output" "minimal"

claude_modes_test::it "registry: _global.yaml is excluded from mode list"
# _global appears only in description/header text — not as a mode entry.
# Verify by checking it doesn't appear with the "- _global" bullet prefix.
case "$output" in
  *"- _global"*) claude_modes_test::fail "_global should be excluded from registry listing" ;;
  *) claude_modes_test::pass ;;
esac

claude_modes_test::it "registry: 3 modes total reported in header"
claude_modes_test::assert_contains "$output" "Modes (3):"

claude_modes_test::it "registry: schema_version surfaced for delivery"
claude_modes_test::assert_contains "$output" "schema_version:  2"

claude_modes_test::it "registry: enabledPlugins count surfaced (delivery has 1)"
claude_modes_test::assert_contains "$output" "enabledPlugins:  1"

claude_modes_test::it "registry: user_catalog count surfaced"
claude_modes_test::assert_contains "$output" "user_catalog:"

claude_modes_test::it "registry: prose layer presence flagged"
claude_modes_test::assert_contains "$output" "prose layer:     yes"

claude_modes_test::it "registry: minimal mode flagged as having no prose"
claude_modes_test::assert_contains "$output" "prose layer:     no"

claude_modes_test::teardown

# Test 8: --new flag surfaces the mode-author skill pointer
claude_modes_test::setup
. "${PLUGIN_ROOT}/lib/registry.sh"
__seed_global_yaml

claude_modes_test::it "registry --new: surfaces mode-author skill instructions"
output=$( claude_modes::registry --new 2>&1 )
claude_modes_test::assert_contains "$output" "mode-author skill"

claude_modes_test::it "registry --new: surfaces SKILL.md path"
claude_modes_test::assert_contains "$output" "SKILL.md"

claude_modes_test::teardown

# ──────────────────────────────────────────────────────────────────────
# Group C: mode-author skill cascade-awareness redirect
# ──────────────────────────────────────────────────────────────────────

# The skill itself is conversational; we can only assert the SKILL.md
# content carries the literal redirect text the cascade-awareness phase
# is supposed to emit.

claude_modes_test::it "mode-author SKILL.md: contains 'hooks live in' redirect"
SKILL="${PLUGIN_ROOT}/.claude/skills/mode-author/SKILL.md"
if [ -f "$SKILL" ] && grep -q "hooks live in" "$SKILL"; then
  claude_modes_test::pass
else
  claude_modes_test::fail "expected 'hooks live in' redirect text in $SKILL"
fi

claude_modes_test::it "mode-author SKILL.md: mentions _global.yaml as hooks home"
if grep -q "_global.yaml" "$SKILL"; then
  claude_modes_test::pass
else
  claude_modes_test::fail "expected _global.yaml mention in $SKILL"
fi

claude_modes_test::it "mode-author SKILL.md: mentions _repo.yaml as hooks home"
if grep -q "_repo.yaml" "$SKILL"; then
  claude_modes_test::pass
else
  claude_modes_test::fail "expected _repo.yaml mention in $SKILL"
fi

claude_modes_test::it "mode-author SKILL.md: notes R28 rejection at write time"
if grep -q "R28" "$SKILL"; then
  claude_modes_test::pass
else
  claude_modes_test::fail "expected R28 invariant mention in $SKILL"
fi

claude_modes_test::it "mode-author SKILL.md: declares schema_version 2"
if grep -q "schema_version: 2" "$SKILL"; then
  claude_modes_test::pass
else
  claude_modes_test::fail "expected schema_version: 2 in $SKILL"
fi

# api-contract re-review: the anti-patterns section must NOT tell users to
# put hooks in _global.yaml/_repo.yaml (the cascade silently drops them).
# It must redirect to settings.json. Guards the L2 fix against regression.
claude_modes_test::it "mode-author SKILL.md anti-patterns: redirects hooks to settings.json, not _global/_repo.yaml"
# Extract the Anti-patterns section (from its header to the next ## header).
anti=$(awk '/^## Anti-patterns/{f=1} f{print} /^## /{if(f && !/^## Anti-patterns/) exit}' "$SKILL")
if printf '%s' "$anti" | grep -q "settings.json" \
   && ! printf '%s' "$anti" | grep -qE "Use \`_global\.yaml\`|Use \`_repo\.yaml\`"; then
  claude_modes_test::pass
else
  claude_modes_test::fail "anti-patterns section should redirect hooks to settings.json, not _global/_repo.yaml"
fi

# ──────────────────────────────────────────────────────────────────────
# Exit
# ──────────────────────────────────────────────────────────────────────


echo ""
printf '%s: %d passed, %d failed\n' \
  "$(basename "${BASH_SOURCE[0]}")" \
  "${CLAUDE_MODES_TEST_PASS_COUNT}" \
  "${CLAUDE_MODES_TEST_FAIL_COUNT}"

if [ "${CLAUDE_MODES_TEST_FAIL_COUNT}" -gt 0 ]; then
  exit 1
fi
exit 0
