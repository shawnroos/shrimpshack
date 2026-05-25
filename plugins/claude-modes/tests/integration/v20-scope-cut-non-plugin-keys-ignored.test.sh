#!/usr/bin/env bash
# U4 integration: V2.0 scope cut — cascade silently ignores non-plugin-owned keys.
#
# V2.0 contract (per plan §393): PLUGIN_OWNED_KEYS_V2 = ["enabledPlugins"]
# only. Mode YAMLs may declare env, permissions, hooks, mcpServers under
# `mechanism:` (or any other path) but the cascade engine MUST silently
# drop them — they do NOT appear in settings.local.json.
#
# Why: /reload-plugins hot-reloads only the plugin layer; including other
# keys in the cascade would mislead users into thinking they apply on
# /reload-plugins when they actually require a new session.
#
# Note: We use _global.yaml (tier 2) to carry hooks/env/permissions/
# mcpServers because write-mode-yaml.sh refuses tier-3 mode YAMLs that
# carry mechanism.hooks (R28 first line of defense). Tier 2 is the legal
# home for hooks per the V2 architecture. The test asserts the same
# cascade-engine ignore behavior regardless of which tier carried them.

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

REPO="${HOME}/scope-cut-repo"
mkdir -p "$REPO"
( cd "$REPO" && git init -q -b main >/dev/null 2>&1 \
  && git config user.email "test@test" \
  && git config user.name "test" )

mkdir -p "${HOME}/.claude/modes"

# Tier 2: _global.yaml carries enabledPlugins AND env, permissions, hooks,
# mcpServers — all of the V2.0 deferred keys. The cascade engine should
# only flow enabledPlugins to settings.local.json.
cat > "${HOME}/.claude/modes/_global.yaml" <<EOF
schema_version: 2
name: _global
mechanism:
  enabledPlugins:
    "${ID}": true
    "A@market": true
  env:
    MY_ENV_VAR: "should-not-appear"
  permissions:
    allow:
      - "Bash(echo:*)"
  mcpServers:
    fake-server:
      command: "echo"
  hooks:
    PreToolUse:
      - command: "echo from-global-hook"
EOF

# Tier 3: mode YAML — only enabledPlugins (write-mode-yaml.sh refuses
# tier-3 with mechanism.hooks per R28; we write raw to keep the test
# focused on the cascade engine's ignore behavior at tier 2).
cat > "${HOME}/.claude/modes/scoped.yaml" <<'EOF'
schema_version: 2
name: scoped
mechanism:
  enabledPlugins:
    "B@market": true
EOF

# Run the cascade.
claude_modes_test::it "V2.0 scope cut: cascade succeeds with hooks/env/permissions/mcpServers in tier 2"
if claude_modes::cascade_compile "scoped" "$REPO" >/dev/null 2>&1; then
  claude_modes_test::pass
else
  claude_modes_test::fail "cascade exited non-zero"
fi

target="${REPO}/.claude/settings.local.json"

# ─── enabledPlugins IS in settings.local.json ───────────────────────
claude_modes_test::it "V2.0: settings.local.json contains enabledPlugins"
if [ -f "$target" ]; then
  has=$("$PY" -c 'import json,sys; print("yes" if "enabledPlugins" in json.load(open(sys.argv[1])) else "no")' "$target")
  claude_modes_test::assert_eq "yes" "$has"
else
  claude_modes_test::fail "settings.local.json not written"
fi

# ─── env, permissions, hooks, mcpServers are NOT in settings.local.json ─
for k in env permissions hooks mcpServers; do
  claude_modes_test::it "V2.0: settings.local.json does NOT contain '$k'"
  if [ -f "$target" ]; then
    has=$("$PY" -c 'import json,sys; print("yes" if "'"$k"'" in json.load(open(sys.argv[1])) else "no")' "$target")
    claude_modes_test::assert_eq "no" "$has"
  else
    claude_modes_test::fail "settings.local.json missing"
  fi
done

# ─── Specifically: MY_ENV_VAR not present anywhere in the file ──────
claude_modes_test::it "V2.0: MY_ENV_VAR not present anywhere in settings.local.json"
if grep -q "MY_ENV_VAR" "$target" 2>/dev/null; then
  claude_modes_test::fail "MY_ENV_VAR leaked into settings.local.json"
else
  claude_modes_test::pass
fi

# ─── Specifically: from-global-hook not present anywhere in the file ───
claude_modes_test::it "V2.0: from-global-hook not present anywhere in settings.local.json"
if grep -q "from-global-hook" "$target" 2>/dev/null; then
  claude_modes_test::fail "global hook command leaked into settings.local.json"
else
  claude_modes_test::pass
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
