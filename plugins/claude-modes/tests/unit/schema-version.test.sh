#!/usr/bin/env bash
# U3 unit test: validate_schema_version + write-mode-yaml R28 enforcement.
#
# Test scenarios:
#   1. validate_schema_version accepts schema_version: 2
#   2. validate_schema_version rejects schema_version: 1 with V1-archive message
#   3. validate_schema_version rejects schema_version: 3 (unknown future)
#   4. validate_schema_version rejects missing schema_version
#   5. yaml.safe_load rejects YAMLError without crashing
#   6. write_mode_yaml accepts a valid V2 mode YAML
#   7. write_mode_yaml refuses a mode YAML with hooks under mechanism (R28)
#   8. write_mode_yaml refuses target outside ~/.claude/modes or <repo>/.claude/modes
#   9. write_mode_yaml is atomic (no tmp files left on disk after write)

set -uo pipefail

# Resolve plugin root and source helpers.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/tests/helpers/test-helpers.sh"

claude_modes_test::setup

# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/lib/mode-yaml.sh"
. "${PLUGIN_ROOT}/lib/write-mode-yaml.sh"

# ─── Scenario 1: validate_schema_version accepts 2 ─────────────────
claude_modes_test::it "validate_schema_version accepts schema_version: 2"
yaml_v2="${HOME}/.claude/modes/test-v2.yaml"
mkdir -p "$(dirname "$yaml_v2")"
cat > "$yaml_v2" <<EOF
schema_version: 2
name: test-v2
mechanism:
  enabledPlugins:
    "claude-modes@local-dev": true
EOF
if claude_modes::validate_schema_version "$yaml_v2" 2>/dev/null; then
  claude_modes_test::pass
else
  claude_modes_test::fail "expected exit 0 on schema_version: 2"
fi

# ─── Scenario 2: rejects schema_version: 1 with V1-archive message ─
claude_modes_test::it "validate_schema_version rejects schema_version: 1 with archive message"
yaml_v1="${HOME}/.claude/modes/test-v1.yaml"
cat > "$yaml_v1" <<EOF
schema_version: 1
name: test-v1
EOF
err=$(claude_modes::validate_schema_version "$yaml_v1" 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && echo "$err" | grep -qE "V1 mode|schema_version=1"; then
  claude_modes_test::pass
else
  claude_modes_test::fail "expected non-zero exit + 'V1 mode YAML' in stderr; got rc=$rc, stderr=$err"
fi

# ─── Scenario 3: rejects schema_version: 3 (unknown) ───────────────
claude_modes_test::it "validate_schema_version rejects unknown schema_version"
yaml_v3="${HOME}/.claude/modes/test-v3.yaml"
cat > "$yaml_v3" <<EOF
schema_version: 3
name: test-v3
EOF
err=$(claude_modes::validate_schema_version "$yaml_v3" 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && echo "$err" | grep -qE "schema_version=3"; then
  claude_modes_test::pass
else
  claude_modes_test::fail "expected non-zero + schema_version=3 in stderr; got rc=$rc, stderr=$err"
fi

# ─── Scenario 4: rejects missing schema_version ────────────────────
claude_modes_test::it "validate_schema_version rejects missing schema_version"
yaml_missing="${HOME}/.claude/modes/test-missing.yaml"
cat > "$yaml_missing" <<EOF
name: test-missing
EOF
err=$(claude_modes::validate_schema_version "$yaml_missing" 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && echo "$err" | grep -q "missing schema_version"; then
  claude_modes_test::pass
else
  claude_modes_test::fail "expected non-zero + 'missing schema_version'; got rc=$rc, stderr=$err"
fi

# ─── Scenario 5: yaml.safe_load rejects YAMLError gracefully ───────
claude_modes_test::it "validate_schema_version handles malformed YAML"
yaml_bad="${HOME}/.claude/modes/test-bad.yaml"
# Unclosed quote — guaranteed parse error.
printf 'schema_version: 2\nname: "unterminated\n' > "$yaml_bad"
err=$(claude_modes::validate_schema_version "$yaml_bad" 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && echo "$err" | grep -q "parse error"; then
  claude_modes_test::pass
else
  claude_modes_test::fail "expected non-zero + 'parse error'; got rc=$rc, stderr=$err"
fi

# ─── Scenario 6: write_mode_yaml accepts a valid V2 mode YAML ──────
claude_modes_test::it "write_mode_yaml accepts a well-formed V2 mode YAML"
out_path="${HOME}/.claude/modes/test-write-good.yaml"
content=$(cat <<EOF
schema_version: 2
name: test-write-good
description: |
  A valid V2 mode for testing.
mechanism:
  enabledPlugins:
    "claude-modes@local-dev": true
  user_catalog:
    commands: []
    agents: []
EOF
)
if claude_modes::write_mode_yaml "$out_path" "$content" 2>/dev/null; then
  if [ -f "$out_path" ]; then
    perms=$(stat -f '%A' "$out_path" 2>/dev/null || stat -c '%a' "$out_path" 2>/dev/null)
    if [ "$perms" = "600" ]; then
      claude_modes_test::pass
    else
      claude_modes_test::fail "file written but perms=$perms, expected 600"
    fi
  else
    claude_modes_test::fail "write reported success but file does not exist"
  fi
else
  claude_modes_test::fail "expected exit 0 for valid mode YAML"
fi

# ─── Scenario 7: R28 — refuse mode YAML with hooks ─────────────────
claude_modes_test::it "write_mode_yaml refuses tier-3 mode YAML with mechanism.hooks (R28)"
out_path="${HOME}/.claude/modes/test-write-hooks.yaml"
content=$(cat <<EOF
schema_version: 2
name: test-write-hooks
mechanism:
  enabledPlugins:
    "claude-modes@local-dev": true
  hooks:
    PreToolUse:
      - command: "echo evil"
EOF
)
err=$(claude_modes::write_mode_yaml "$out_path" "$content" 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && echo "$err" | grep -q "R28"; then
  if [ ! -f "$out_path" ]; then
    claude_modes_test::pass
  else
    claude_modes_test::fail "R28 rejected but file was still written"
  fi
else
  claude_modes_test::fail "expected non-zero + 'R28' in stderr; got rc=$rc, stderr=$err"
fi

# api-contract re-review: the R28 error must redirect users to the CORRECT
# hooks location (settings.json / hooks.json), NOT to _global.yaml/_repo.yaml
# (where the cascade silently drops hooks). Guards against the message
# regressing to the misleading guidance.
claude_modes_test::it "R28 error message redirects to settings.json, not _global/_repo.yaml"
if echo "$err" | grep -q "settings.json" \
   && ! echo "$err" | grep -qE "hooks belong in _global\.yaml|hooks belong in.*_repo\.yaml"; then
  claude_modes_test::pass
else
  claude_modes_test::fail "R28 message should point to settings.json, not _global/_repo.yaml: $err"
fi

# ─── Scenario 8: refuse target outside allowed dirs ────────────────
claude_modes_test::it "write_mode_yaml refuses target outside ~/.claude/modes"
out_path="${HOME}/somewhere-else/random.yaml"
mkdir -p "$(dirname "$out_path")"
content=$(cat <<EOF
schema_version: 2
name: random
mechanism:
  enabledPlugins: {}
EOF
)
err=$(claude_modes::write_mode_yaml "$out_path" "$content" 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && echo "$err" | grep -qE "not under.*modes"; then
  if [ ! -f "$out_path" ]; then
    claude_modes_test::pass
  else
    claude_modes_test::fail "path-safety rejected but file was still written"
  fi
else
  claude_modes_test::fail "expected non-zero + 'not under' message; got rc=$rc, stderr=$err"
fi

# ─── Scenario 9: atomic write — no tmp files left ──────────────────
claude_modes_test::it "write_mode_yaml leaves no .write-mode-yaml.XXXXXX tmp files"
# Run a write that should succeed; verify no tmp files remain.
out_path="${HOME}/.claude/modes/test-atomic.yaml"
content=$(cat <<EOF
schema_version: 2
name: test-atomic
mechanism:
  enabledPlugins:
    "claude-modes@local-dev": true
EOF
)
claude_modes::write_mode_yaml "$out_path" "$content" >/dev/null 2>&1
leftover_tmps=$(find "${HOME}/.claude/modes" -maxdepth 1 -name '.write-mode-yaml.*' 2>/dev/null | wc -l | tr -d '[:space:]')
if [ "$leftover_tmps" = "0" ]; then
  claude_modes_test::pass
else
  claude_modes_test::fail "found $leftover_tmps leftover .write-mode-yaml.* tmp files"
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
