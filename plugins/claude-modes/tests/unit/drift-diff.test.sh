#!/usr/bin/env bash
# U7 unit test: lib/drift-diff.sh + lib/drift-diff.py
#
# drift-diff is informational, NOT load-bearing for U7's deletion gate.
# These tests cover the structured-diff output only — they do NOT test
# anything about rm or settings.local.json deletion (that's the sidecar
# fingerprint gate's job, exercised by the integration tests).
#
# Scenarios:
#   1. Two identical JSON files → empty diff output, exit 0.
#   2. One top-level key changed → "~ <key>" line, exit 0.
#   3. One top-level key added in current → "+ <key>" line, exit 0.
#   4. One top-level key removed from current → "- <key>" line, exit 0.
#   5. Mixed: combined add/remove/change → three lines in sorted order.
#   6. Missing pristine file → exit 2.
#   7. Invalid JSON in current → exit 3.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/tests/helpers/test-helpers.sh"
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/lib/drift-diff.sh"

claude_modes_test::setup

WORK="${HOME}/drift-work"
mkdir -p "$WORK"

# Helper: write JSON to a file.
_write_json() {
  local path="$1"
  local content="$2"
  printf '%s' "$content" > "$path"
}

# ─── Scenario 1: identical files → empty diff ──────────────────────────
claude_modes_test::it "drift-diff: identical files produce empty output"
_write_json "${WORK}/p.json" '{"a": 1, "b": "two"}'
_write_json "${WORK}/c.json" '{"a": 1, "b": "two"}'
out=$(claude_modes::drift_diff "${WORK}/p.json" "${WORK}/c.json" 2>/dev/null)
rc=$?
claude_modes_test::assert_eq "0" "$rc"

claude_modes_test::it "drift-diff: identical files - output is empty string"
claude_modes_test::assert_eq "" "$out"

# ─── Scenario 2: one value changed ─────────────────────────────────────
claude_modes_test::it "drift-diff: one changed value emits a ~ line"
_write_json "${WORK}/p.json" '{"a": 1, "b": "two"}'
_write_json "${WORK}/c.json" '{"a": 1, "b": "TWO"}'
out=$(claude_modes::drift_diff "${WORK}/p.json" "${WORK}/c.json" 2>/dev/null)
claude_modes_test::assert_eq "~ b" "$out"

# ─── Scenario 3: new key added in current ──────────────────────────────
claude_modes_test::it "drift-diff: added key emits a + line"
_write_json "${WORK}/p.json" '{"a": 1}'
_write_json "${WORK}/c.json" '{"a": 1, "newkey": "value"}'
out=$(claude_modes::drift_diff "${WORK}/p.json" "${WORK}/c.json" 2>/dev/null)
claude_modes_test::assert_eq "+ newkey" "$out"

# ─── Scenario 4: key removed from current ──────────────────────────────
claude_modes_test::it "drift-diff: removed key emits a - line"
_write_json "${WORK}/p.json" '{"a": 1, "gonekey": true}'
_write_json "${WORK}/c.json" '{"a": 1}'
out=$(claude_modes::drift_diff "${WORK}/p.json" "${WORK}/c.json" 2>/dev/null)
claude_modes_test::assert_eq "- gonekey" "$out"

# ─── Scenario 5: mixed add/remove/change in sorted order ───────────────
claude_modes_test::it "drift-diff: mixed diff emits sorted lines"
_write_json "${WORK}/p.json" '{"alpha": 1, "beta": 2, "gamma": 3}'
_write_json "${WORK}/c.json" '{"alpha": 1, "beta": 22, "delta": 4}'
out=$(claude_modes::drift_diff "${WORK}/p.json" "${WORK}/c.json" 2>/dev/null)
# Sorted keys: alpha (same, no line), beta (changed → ~), delta (added → +), gamma (removed → -)
expected=$'~ beta\n+ delta\n- gamma'
claude_modes_test::assert_eq "$expected" "$out"

# ─── Scenario 6: missing pristine file → exit 2 ────────────────────────
claude_modes_test::it "drift-diff: missing pristine exits 2"
rm -f "${WORK}/missing.json"
if claude_modes::drift_diff "${WORK}/missing.json" "${WORK}/c.json" >/dev/null 2>&1; then
  claude_modes_test::fail "expected non-zero exit for missing file"
else
  rc=$?
  claude_modes_test::assert_eq "2" "$rc"
fi

# ─── Scenario 7: invalid JSON in current → exit 3 ──────────────────────
claude_modes_test::it "drift-diff: invalid JSON exits 3"
_write_json "${WORK}/p.json" '{"a": 1}'
_write_json "${WORK}/c.json" '{this is not json}'
if claude_modes::drift_diff "${WORK}/p.json" "${WORK}/c.json" >/dev/null 2>&1; then
  claude_modes_test::fail "expected non-zero exit for invalid JSON"
else
  rc=$?
  claude_modes_test::assert_eq "3" "$rc"
fi

claude_modes_test::teardown

printf '\n%s: %d passed, %d failed\n' \
  "drift-diff.test.sh" \
  "$CLAUDE_MODES_TEST_PASS_COUNT" \
  "$CLAUDE_MODES_TEST_FAIL_COUNT"

if [ "${CLAUDE_MODES_TEST_FAIL_COUNT}" -gt 0 ]; then
  exit 1
fi
exit 0
