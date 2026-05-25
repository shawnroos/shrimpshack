#!/usr/bin/env bash
# U8 integration test: end-to-end claude_modes::symlink_rebuild flow.
#
# Scenarios:
#   1. Attack case (atomic fail-safely): manifest containing one valid
#      entry plus one R7 attack entry → rebuild fails, ZERO symlinks
#      created, ZERO removed. The valid entry is NOT partially applied.
#   2. Happy path: manifest with only valid entries → all symlinks
#      created, all point under .user-catalog/, sha256 of dereferenced
#      content matches the staging file.
#   3. Alien-symlink preservation: a pre-existing symlink in
#      ~/.claude/commands/ that points at $HOME/vault/external.md
#      (NOT under .user-catalog/) is left untouched after rebuild.
#   4. Sticky-mode reset / "Claude Mode" (empty mode_yaml_path):
#      after a restrictive mode leaves only foo.md symlinked, calling
#      symlink_rebuild with no mode arg restores symlinks for every
#      file in the staging dir.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/tests/helpers/test-helpers.sh"

# Helper: sha256 of file contents (resolves symlinks naturally — `cat`
# follows them). Echoes the hash on stdout.
_sha256_of_file_contents() {
  "$CLAUDE_MODES_PYTHON3" -c "
import hashlib, sys
with open(sys.argv[1], 'rb') as f:
    print(hashlib.sha256(f.read()).hexdigest())
" "$1"
}

# Helper: rebuild plugin globals between sub-scenarios. Each subscenario
# uses its own freshly-isolated HOME so we can run claude_modes_test::
# setup once at top, do everything in there, and tear down at end. The
# library is sourced once.

claude_modes_test::setup

# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/lib/symlink-rebuild.sh"

USER_CATALOG="${HOME}/.claude/modes/.user-catalog"
COMMANDS_STAGING="${USER_CATALOG}/commands"
AGENTS_STAGING="${USER_CATALOG}/agents"
COMMANDS_LIVE="${HOME}/.claude/commands"
AGENTS_LIVE="${HOME}/.claude/agents"

mkdir -p "$COMMANDS_STAGING" "$AGENTS_STAGING" "$COMMANDS_LIVE" "$AGENTS_LIVE"

# ═══════════════════════════════════════════════════════════════════
# Scenario 1: Attack case (atomic fail-safely)
# ═══════════════════════════════════════════════════════════════════

# Seed staging with a valid file.
echo "good content" > "${COMMANDS_STAGING}/good.md"

# Write a mode YAML containing one valid entry + one attack entry.
ATTACK_YAML="${HOME}/.claude/modes/attack.yaml"
mkdir -p "$(dirname "$ATTACK_YAML")"
cat > "$ATTACK_YAML" <<'EOF'
schema_version: 2
name: attack
mechanism:
  enabledPlugins:
    "claude-modes@local-dev": true
  user_catalog:
    commands:
      - good.md
      - "../../.ssh/id_rsa"
    agents: []
EOF

# Verify the schema validator likes the YAML before we use it (sanity
# — otherwise a YAML-parse failure would mask the real assertion).
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/lib/mode-yaml.sh"
if ! claude_modes::validate_schema_version "$ATTACK_YAML" >/dev/null 2>&1; then
  echo "TEST SETUP FAILED: attack.yaml not schema-valid" >&2
  exit 99
fi

claude_modes_test::it "attack manifest → rebuild fails non-zero"
err=$(claude_modes::symlink_rebuild "$ATTACK_YAML" 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
  claude_modes_test::pass
else
  claude_modes_test::fail "expected non-zero exit; rc=$rc, stderr=$err"
fi

claude_modes_test::it "attack manifest → stderr mentions R7"
if echo "$err" | grep -q "R7"; then
  claude_modes_test::pass
else
  claude_modes_test::fail "expected 'R7' in stderr; got: $err"
fi

claude_modes_test::it "attack manifest → no symlink for the attack entry created"
# The attack entry is "../../.ssh/id_rsa"; the live symlink would have
# been ${COMMANDS_LIVE}/../../.ssh/id_rsa. Check both that no .ssh
# directory got created under HOME and that no `id_rsa` symlink exists
# anywhere unexpected.
if [ ! -e "${HOME}/.ssh/id_rsa" ] && [ ! -L "${HOME}/.ssh/id_rsa" ]; then
  claude_modes_test::pass
else
  claude_modes_test::fail "attack entry created an .ssh/id_rsa entry under HOME"
fi

claude_modes_test::it "attack manifest → atomic fail (valid 'good.md' also NOT created)"
if [ ! -L "${COMMANDS_LIVE}/good.md" ] && [ ! -e "${COMMANDS_LIVE}/good.md" ]; then
  claude_modes_test::pass
else
  claude_modes_test::fail "valid entry was partially applied before attack rejection"
fi

# ═══════════════════════════════════════════════════════════════════
# Scenario 2: Happy path with sha256 verification
# ═══════════════════════════════════════════════════════════════════

# Seed staging with content we can hash. (good.md already exists.)
echo "bar content" > "${COMMANDS_STAGING}/bar.md"
echo "agent body" > "${AGENTS_STAGING}/reviewer.md"

GOOD_YAML="${HOME}/.claude/modes/delivery.yaml"
cat > "$GOOD_YAML" <<'EOF'
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

claude_modes_test::it "happy-path manifest → rebuild succeeds"
if claude_modes::symlink_rebuild "$GOOD_YAML" 2>/dev/null; then
  claude_modes_test::pass
else
  claude_modes_test::fail "expected exit 0 for happy path"
fi

claude_modes_test::it "happy-path → ~/.claude/commands/good.md is a symlink"
if [ -L "${COMMANDS_LIVE}/good.md" ]; then
  claude_modes_test::pass
else
  claude_modes_test::fail "expected symlink at ${COMMANDS_LIVE}/good.md"
fi

claude_modes_test::it "happy-path → ~/.claude/commands/bar.md is a symlink"
if [ -L "${COMMANDS_LIVE}/bar.md" ]; then
  claude_modes_test::pass
else
  claude_modes_test::fail "expected symlink at ${COMMANDS_LIVE}/bar.md"
fi

claude_modes_test::it "happy-path → ~/.claude/agents/reviewer.md is a symlink"
if [ -L "${AGENTS_LIVE}/reviewer.md" ]; then
  claude_modes_test::pass
else
  claude_modes_test::fail "expected symlink at ${AGENTS_LIVE}/reviewer.md"
fi

claude_modes_test::it "happy-path → good.md sha256 matches staging file"
live_hash=$(_sha256_of_file_contents "${COMMANDS_LIVE}/good.md")
staging_hash=$(_sha256_of_file_contents "${COMMANDS_STAGING}/good.md")
if [ "$live_hash" = "$staging_hash" ]; then
  claude_modes_test::pass
else
  claude_modes_test::fail "live=${live_hash} staging=${staging_hash}"
fi

claude_modes_test::it "happy-path → bar.md sha256 matches staging file"
live_hash=$(_sha256_of_file_contents "${COMMANDS_LIVE}/bar.md")
staging_hash=$(_sha256_of_file_contents "${COMMANDS_STAGING}/bar.md")
if [ "$live_hash" = "$staging_hash" ]; then
  claude_modes_test::pass
else
  claude_modes_test::fail "live=${live_hash} staging=${staging_hash}"
fi

claude_modes_test::it "happy-path → reviewer.md sha256 matches staging file"
live_hash=$(_sha256_of_file_contents "${AGENTS_LIVE}/reviewer.md")
staging_hash=$(_sha256_of_file_contents "${AGENTS_STAGING}/reviewer.md")
if [ "$live_hash" = "$staging_hash" ]; then
  claude_modes_test::pass
else
  claude_modes_test::fail "live=${live_hash} staging=${staging_hash}"
fi

# ═══════════════════════════════════════════════════════════════════
# Scenario 3: Alien-symlink preservation
# ═══════════════════════════════════════════════════════════════════

# Plant an alien symlink in the live dir BEFORE another rebuild.
mkdir -p "${HOME}/vault"
echo "external content" > "${HOME}/vault/external.md"
ln -s "${HOME}/vault/external.md" "${COMMANDS_LIVE}/external.md"

# Sanity: it should already be a symlink NOT under .user-catalog/.
if [ ! -L "${COMMANDS_LIVE}/external.md" ]; then
  echo "TEST SETUP FAILED: alien symlink not planted" >&2
  exit 99
fi

# Rebuild with the same delivery.yaml manifest — external.md is NOT
# in the manifest and is NOT a plugin-owned symlink, so it must be
# preserved untouched.
claude_modes_test::it "alien-preservation → rebuild succeeds with alien present"
if claude_modes::symlink_rebuild "$GOOD_YAML" 2>/dev/null; then
  claude_modes_test::pass
else
  claude_modes_test::fail "expected exit 0"
fi

claude_modes_test::it "alien-preservation → external.md symlink survives rebuild"
if [ -L "${COMMANDS_LIVE}/external.md" ]; then
  claude_modes_test::pass
else
  claude_modes_test::fail "alien symlink was deleted by rebuild"
fi

claude_modes_test::it "alien-preservation → external.md still points at vault"
alien_target=$("$CLAUDE_MODES_PYTHON3" -c \
  'import os,sys; print(os.path.realpath(sys.argv[1]))' \
  "${COMMANDS_LIVE}/external.md")
case "$alien_target" in
  *"/vault/external.md") claude_modes_test::pass ;;
  *) claude_modes_test::fail "alien target changed: $alien_target" ;;
esac

claude_modes_test::it "alien-preservation → plugin-owned bar.md/good.md still present"
if [ -L "${COMMANDS_LIVE}/good.md" ] && [ -L "${COMMANDS_LIVE}/bar.md" ]; then
  claude_modes_test::pass
else
  claude_modes_test::fail "plugin-owned symlinks lost during second rebuild"
fi

# ═══════════════════════════════════════════════════════════════════
# Scenario 4: Sticky-mode reset / "Claude Mode" (empty manifest)
# ═══════════════════════════════════════════════════════════════════

# Restrict to only good.md, removing bar.md from the live set.
RESTRICTIVE_YAML="${HOME}/.claude/modes/writing.yaml"
cat > "$RESTRICTIVE_YAML" <<'EOF'
schema_version: 2
name: writing
mechanism:
  enabledPlugins:
    "claude-modes@local-dev": true
  user_catalog:
    commands:
      - good.md
    agents: []
EOF

claude_modes_test::it "sticky-reset setup → restrictive rebuild removes bar.md"
if claude_modes::symlink_rebuild "$RESTRICTIVE_YAML" 2>/dev/null; then
  if [ ! -L "${COMMANDS_LIVE}/bar.md" ]; then
    claude_modes_test::pass
  else
    claude_modes_test::fail "bar.md should have been removed by restrictive rebuild"
  fi
else
  claude_modes_test::fail "restrictive rebuild failed"
fi

claude_modes_test::it "sticky-reset setup → restrictive rebuild also removes reviewer.md"
# The writing.yaml has agents: [] so reviewer.md should be gone.
if [ ! -L "${AGENTS_LIVE}/reviewer.md" ]; then
  claude_modes_test::pass
else
  claude_modes_test::fail "reviewer.md should have been removed (writing.yaml has agents: [])"
fi

claude_modes_test::it "sticky-reset → empty mode_yaml_path restores all staging files"
if claude_modes::symlink_rebuild "" 2>/dev/null; then
  # All staging files should now be symlinked back.
  if [ -L "${COMMANDS_LIVE}/good.md" ] && [ -L "${COMMANDS_LIVE}/bar.md" ] && [ -L "${AGENTS_LIVE}/reviewer.md" ]; then
    claude_modes_test::pass
  else
    claude_modes_test::fail "expected good.md, bar.md, reviewer.md all symlinked after Claude-Mode rebuild"
  fi
else
  claude_modes_test::fail "Claude-Mode (empty arg) rebuild failed"
fi

claude_modes_test::it "sticky-reset → alien external.md STILL preserved through Claude-Mode rebuild"
if [ -L "${COMMANDS_LIVE}/external.md" ]; then
  alien_target=$("$CLAUDE_MODES_PYTHON3" -c \
    'import os,sys; print(os.path.realpath(sys.argv[1]))' \
    "${COMMANDS_LIVE}/external.md")
  case "$alien_target" in
    *"/vault/external.md") claude_modes_test::pass ;;
    *) claude_modes_test::fail "alien target changed during Claude-Mode rebuild: $alien_target" ;;
  esac
else
  claude_modes_test::fail "alien external.md was lost during Claude-Mode rebuild"
fi

# ═══════════════════════════════════════════════════════════════════
# Scenario 5: U4 — R30 _repo.yaml symlink refusal in cascade engine.
# ═══════════════════════════════════════════════════════════════════
# (R7 above covers user-catalog symlink-rebuild; this section verifies
# the U4 cascade engine's separate R30 protection on tier-4 reads.)

# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/lib/cascade-engine.sh"

# Seed _global.yaml so R22 is satisfied for U4 cascade calls.
cat > "${HOME}/.claude/modes/_global.yaml" <<'EOF'
schema_version: 2
name: _global
mechanism:
  enabledPlugins:
    "claude-modes@local-dev": true
EOF

# A simple mode YAML for the cascade to use as tier 3.
cat > "${HOME}/.claude/modes/cascade-test-mode.yaml" <<'EOF'
schema_version: 2
name: cascade-test-mode
mechanism:
  enabledPlugins:
    "Z@market": true
EOF

CASCADE_REPO="${HOME}/cascade-r30-repo"
mkdir -p "${CASCADE_REPO}/.claude/modes"
( cd "$CASCADE_REPO" && git init -q -b main >/dev/null 2>&1 \
  && git config user.email "test@test" \
  && git config user.name "test" )

# ─── Sub-scenario 5a: planted _repo.yaml symlink → cascade fails ────
PLANT="${HOME}/cascade-attacker-payload.yaml"
cat > "$PLANT" <<'EOF'
schema_version: 2
name: _repo
mechanism:
  enabledPlugins:
    "attacker-plugin@evil": true
EOF
ln -sf "$PLANT" "${CASCADE_REPO}/.claude/modes/_repo.yaml"

claude_modes_test::it "U4 R30: planted _repo.yaml symlink → cascade fails (no settings.local.json)"
echo "y" > "${HOME}/.cascade-r30-reply"
err=$(CLAUDE_MODES_TRUST_PROMPT_INPUT="${HOME}/.cascade-r30-reply" \
  claude_modes::cascade_compile "cascade-test-mode" "$CASCADE_REPO" 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && echo "$err" | grep -q "R30"; then
  if [ ! -f "${CASCADE_REPO}/.claude/settings.local.json" ]; then
    claude_modes_test::pass
  else
    claude_modes_test::fail "R30 rejected but settings.local.json was still written"
  fi
else
  claude_modes_test::fail "expected non-zero + 'R30'; got rc=$rc, stderr=$err"
fi

# Clean up the symlink for sub-scenario 5b.
rm -f "${CASCADE_REPO}/.claude/modes/_repo.yaml"

# ─── Sub-scenario 5b: regular _repo.yaml file → cascade proceeds ────
cat > "${CASCADE_REPO}/.claude/modes/_repo.yaml" <<'EOF'
schema_version: 2
name: _repo
mechanism:
  enabledPlugins:
    "tier4-plugin@market": true
EOF

claude_modes_test::it "U4 R30: real _repo.yaml regular file → cascade proceeds"
echo "y" > "${HOME}/.cascade-r30-reply"
if CLAUDE_MODES_TRUST_PROMPT_INPUT="${HOME}/.cascade-r30-reply" \
    claude_modes::cascade_compile "cascade-test-mode" "$CASCADE_REPO" >/dev/null 2>&1; then
  if [ -f "${CASCADE_REPO}/.claude/settings.local.json" ] \
     && grep -q "tier4-plugin" "${CASCADE_REPO}/.claude/settings.local.json"; then
    claude_modes_test::pass
  else
    claude_modes_test::fail "cascade succeeded but tier4-plugin missing from settings.local.json"
  fi
else
  claude_modes_test::fail "cascade exited non-zero on regular _repo.yaml"
fi

claude_modes_test::teardown

# Summary line in the runner's expected format + propagate rc.
printf '%s: %d passed, %d failed\n' \
  "$(basename "$0")" \
  "$CLAUDE_MODES_TEST_PASS_COUNT" \
  "$CLAUDE_MODES_TEST_FAIL_COUNT"
[ "$CLAUDE_MODES_TEST_FAIL_COUNT" -eq 0 ]
