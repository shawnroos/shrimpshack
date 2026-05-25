#!/usr/bin/env bash
# U8 unit test: lib/symlink-validate.py (R7 realpath path-traversal check).
#
# Scenarios:
#   1. Accept happy path: regular relative filename `foo.md`
#   2. Reject relative traversal: `../../.ssh/id_rsa`
#   3. Reject absolute attack:    `/etc/passwd`
#   4. Reject mid-path traversal: `commands/../../etc/passwd`
#   5. Reject symlink escape: entry names a real symlink inside the
#      staging dir whose target is /etc/passwd; realpath follows it →
#      rejected.
#   6. Reject empty entry (defensive: would resolve to staging dir itself)
#   7. Reject argv-arity errors (exit code 2)
#   8. Reject prefix-confusion: target is `.user-catalog` but entry
#      resolves to `.user-catalog2/...` (the os.sep boundary check).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/tests/helpers/test-helpers.sh"

claude_modes_test::setup

VALIDATOR="${PLUGIN_ROOT}/lib/symlink-validate.py"

# Build a representative staging dir under the isolated HOME.
STAGING="${HOME}/.claude/modes/.user-catalog/commands"
mkdir -p "$STAGING"

# Drop a benign file we can validate the happy path against.
echo "ok" > "${STAGING}/foo.md"

# ─── Scenario 1: happy path ────────────────────────────────────────
claude_modes_test::it "accepts a regular relative filename (foo.md)"
out=$("$CLAUDE_MODES_PYTHON3" "$VALIDATOR" "$STAGING" "foo.md" 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
  # Stdout should be the resolved path; sanity-check it ends in /foo.md
  case "$out" in
    */foo.md) claude_modes_test::pass ;;
    *) claude_modes_test::fail "expected resolved path ending in /foo.md, got: $out" ;;
  esac
else
  claude_modes_test::fail "expected exit 0 for foo.md; rc=$rc, stderr=$out"
fi

# ─── Scenario 2: relative traversal ────────────────────────────────
claude_modes_test::it "rejects '../../.ssh/id_rsa' with R7 message"
err=$("$CLAUDE_MODES_PYTHON3" "$VALIDATOR" "$STAGING" "../../.ssh/id_rsa" 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && echo "$err" | grep -q "R7"; then
  claude_modes_test::pass
else
  claude_modes_test::fail "expected non-zero + 'R7' message; rc=$rc, err=$err"
fi

# ─── Scenario 3: absolute attack ───────────────────────────────────
claude_modes_test::it "rejects absolute path '/etc/passwd' with R7 message"
err=$("$CLAUDE_MODES_PYTHON3" "$VALIDATOR" "$STAGING" "/etc/passwd" 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && echo "$err" | grep -q "R7"; then
  claude_modes_test::pass
else
  claude_modes_test::fail "expected non-zero + 'R7' for /etc/passwd; rc=$rc, err=$err"
fi

# ─── Scenario 4: mid-path traversal ────────────────────────────────
claude_modes_test::it "rejects 'commands/../../etc/passwd' (realpath resolves the escape)"
err=$("$CLAUDE_MODES_PYTHON3" "$VALIDATOR" "$STAGING" "commands/../../etc/passwd" 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && echo "$err" | grep -q "R7"; then
  claude_modes_test::pass
else
  claude_modes_test::fail "expected non-zero + 'R7' for mid-path traversal; rc=$rc, err=$err"
fi

# ─── Scenario 5: planted symlink inside staging escapes the dir ────
claude_modes_test::it "rejects entry naming an in-staging symlink whose target is /etc/passwd"
# Plant a symlink directly in the commands/ staging dir pointing OUTSIDE.
ln -s "/etc/passwd" "${STAGING}/escape.md"
err=$("$CLAUDE_MODES_PYTHON3" "$VALIDATOR" "$STAGING" "escape.md" 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && echo "$err" | grep -q "R7"; then
  claude_modes_test::pass
else
  claude_modes_test::fail "expected non-zero + 'R7' for symlink-in-staging escape; rc=$rc, err=$err"
fi
rm -f "${STAGING}/escape.md"

# ─── Scenario 6: empty entry ───────────────────────────────────────
claude_modes_test::it "rejects empty entry string"
err=$("$CLAUDE_MODES_PYTHON3" "$VALIDATOR" "$STAGING" "" 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && echo "$err" | grep -q "R7"; then
  claude_modes_test::pass
else
  claude_modes_test::fail "expected non-zero + 'R7' for empty entry; rc=$rc, err=$err"
fi

# ─── Scenario 7: argv arity ────────────────────────────────────────
claude_modes_test::it "exits 2 on missing entry argument"
err=$("$CLAUDE_MODES_PYTHON3" "$VALIDATOR" "$STAGING" 2>&1)
rc=$?
if [ "$rc" -eq 2 ]; then
  claude_modes_test::pass
else
  claude_modes_test::fail "expected exit 2 for missing argv; rc=$rc, err=$err"
fi

# ─── Scenario 8: prefix-confusion boundary ─────────────────────────
# If we accept a target_dir "X" and entry "../Xbar/foo.md", the
# resolved path becomes ".../Xbar/foo.md" which has the same string
# prefix as X. The trailing-os.sep check must reject this.
claude_modes_test::it "rejects prefix-confusion: target=X, entry resolves to Xbar/...
"
PARENT_STAGING="${HOME}/.claude/modes/.user-catalog/commands"
SIBLING_DIR="${HOME}/.claude/modes/.user-catalog/commandsbar"
mkdir -p "$SIBLING_DIR"
echo "sibling" > "${SIBLING_DIR}/foo.md"
err=$("$CLAUDE_MODES_PYTHON3" "$VALIDATOR" "$PARENT_STAGING" "../commandsbar/foo.md" 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && echo "$err" | grep -q "R7"; then
  claude_modes_test::pass
else
  claude_modes_test::fail "expected non-zero + 'R7' for prefix-confusion; rc=$rc, err=$err"
fi

claude_modes_test::teardown

# Print a summary line in the runner's expected format and propagate rc.
printf '%s: %d passed, %d failed\n' \
  "$(basename "$0")" \
  "$CLAUDE_MODES_TEST_PASS_COUNT" \
  "$CLAUDE_MODES_TEST_FAIL_COUNT"
[ "$CLAUDE_MODES_TEST_FAIL_COUNT" -eq 0 ]
