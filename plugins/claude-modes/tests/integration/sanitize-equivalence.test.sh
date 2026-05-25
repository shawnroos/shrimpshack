#!/usr/bin/env bash
# Cross-language parity: lib/sanitize.sh (claude_modes::sanitize_for_display)
# and lib/sanitize.py (sanitize_for_display) MUST strip the same characters.
#
# The terminal-escape defense is implemented twice — once per language — because
# the bash lint is structurally Python-blind and vice versa. Their parity was
# DOCUMENTED but not enforced (round-8 TG-01). A one-sided edit, or a unicodedata
# category difference between Python versions, would silently diverge the two
# defenses — exactly the audit-doc-lie failure class (a claimed-but-unverified
# invariant). This test makes the parity a CI-enforced invariant: feed identical
# adversarial payloads to both and assert byte-for-byte identical output.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/tests/helpers/test-helpers.sh"
claude_modes_test::setup

PY="${CLAUDE_MODES_PYTHON3:-/usr/bin/python3}"
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/lib/sanitize.sh"

# Run the Python sanitizer on argv[1].
__py_sanitize() {
  "$PY" -c "
import sys, os
sys.path.insert(0, os.path.join('${PLUGIN_ROOT}', 'lib'))
from sanitize import sanitize_for_display
sys.stdout.write(sanitize_for_display(sys.argv[1]))
" "$1"
}

# Adversarial payloads exercising the Cc + Cf strip surface. Each is a printf
# escape so the bytes are literal. We compare bash-out vs py-out byte-for-byte.
# (printf '\xNN' emits the raw byte; UTF-8 multibyte for U+202E etc.)
__check_parity() {
  local label="$1" payload="$2"
  local bash_out py_out
  bash_out=$(claude_modes::sanitize_for_display "$payload")
  py_out=$(__py_sanitize "$payload")
  claude_modes_test::it "sanitize parity: ${label}"
  if [ "$bash_out" = "$py_out" ]; then
    claude_modes_test::pass
  else
    claude_modes_test::fail "DIVERGENCE — bash=[$(printf '%s' "$bash_out" | cat -v)] py=[$(printf '%s' "$py_out" | cat -v)]"
  fi
}

__check_parity "ESC (C0 control)"        "$(printf 'safe\x1bmid')"
__check_parity "BEL + CR + NUL-adjacent" "$(printf 'a\x07b\rc')"
__check_parity "OSC-2 title sequence"    "$(printf 'x\x1b]2;HACKED\x07y')"
__check_parity "CSI clear-line"          "$(printf 'p\x1b[2Kq')"
__check_parity "U+202E bidi override (Cf)" "$(printf 'safe\xe2\x80\xaednp.gp')"
__check_parity "U+200B zero-width space (Cf)" "$(printf 'a\xe2\x80\x8bb')"
__check_parity "U+200E LTR mark (Cf)"    "$(printf 'l\xe2\x80\x8em')"
__check_parity "plain ASCII (no strip)"  "my-command.md"
__check_parity "legitimate unicode kept (é, 日)" "café-日本.md"
__check_parity "mixed: ESC + bidi + plain" "$(printf 'cmd\x1b[1m\xe2\x80\xae.md')"
__check_parity "empty string"            ""

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
