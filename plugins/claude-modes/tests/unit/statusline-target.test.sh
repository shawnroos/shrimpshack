#!/usr/bin/env bash
# maint-3 unit: shared statusLine target-command extractor.
#
# Locks the parser that was previously triplicated across
# statusline-dispatcher.sh, install-statusline.sh, uninstall-statusline.sh.
# Now a single lib/statusline-target.sh; this test guards its behavior so a
# future change can't silently break the (formerly comment-coupled) callers.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/tests/helpers/test-helpers.sh"
claude_modes_test::setup

# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/lib/statusline-target.sh"

__write_settings() {
  printf '%s' "$1" > "${HOME}/settings.json"
}
SF="${HOME}/settings.json"

# ─── extracts a `bash ~/x.sh` style command ───────────────────────────
claude_modes_test::it "extracts script token from 'bash ~/.claude/sl.sh'"
__write_settings '{"statusLine":{"type":"command","command":"bash ~/.claude/sl.sh"}}'
out=$(claude_modes::statusline_extract_command_path "$SF"); rc=$?
claude_modes_test::assert_eq "0" "$rc"
claude_modes_test::assert_eq "~/.claude/sl.sh" "$out"

# ─── extracts an absolute path with no .sh suffix (has '/') ────────────
claude_modes_test::it "extracts '/usr/local/bin/sl' (slash, no .sh)"
__write_settings '{"statusLine":{"command":"/usr/local/bin/sl --flag"}}'
out=$(claude_modes::statusline_extract_command_path "$SF"); rc=$?
claude_modes_test::assert_eq "0" "$rc"
claude_modes_test::assert_eq "/usr/local/bin/sl" "$out"

# ─── rc=1 when settings file missing ──────────────────────────────────
claude_modes_test::it "returns 1 when settings.json absent"
rm -f "$SF"
claude_modes::statusline_extract_command_path "$SF" >/dev/null 2>&1
claude_modes_test::assert_eq "1" "$?"

# ─── rc=1 when no statusLine block ─────────────────────────────────────
claude_modes_test::it "returns 1 when no statusLine block"
__write_settings '{"enabledPlugins":{"x@y":true}}'
claude_modes::statusline_extract_command_path "$SF" >/dev/null 2>&1
claude_modes_test::assert_eq "1" "$?"

# ─── rc=1 when command has no script-like token ───────────────────────
claude_modes_test::it "returns 1 when command is a bare word (no .sh, no /)"
__write_settings '{"statusLine":{"command":"echo hi"}}'
claude_modes::statusline_extract_command_path "$SF" >/dev/null 2>&1
claude_modes_test::assert_eq "1" "$?"

# ─── rc=1 on malformed JSON (parse error swallowed → no token) ─────────
claude_modes_test::it "returns 1 on malformed JSON"
__write_settings '{not valid json'
claude_modes::statusline_extract_command_path "$SF" >/dev/null 2>&1
claude_modes_test::assert_eq "1" "$?"

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
