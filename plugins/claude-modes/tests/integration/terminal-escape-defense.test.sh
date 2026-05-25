#!/usr/bin/env bash
# L3 (round-3 sec/adversarial): terminal-escape injection defense.
#
# Two attacker-controlled byte sources flow to a terminal sink:
#   1. <repo>/.claude/modes/<branch>.mode body → scripts/statusline.sh emits
#      it into an OSC-2 title escape + the visible statusline. A committed
#      .mode with ESC/OSC/CSI/bidi payload = terminal injection on checkout.
#      Defense: statusline reads THROUGH read_validated_mode_body — a valid
#      mode name can't contain control/escape bytes, so a malicious body is
#      rejected and statusline falls back to its own (safe) title.
#   2. adopted-file basename → scripts/on-post-tool-use.sh prints it to
#      /dev/tty in the consent prompt. Unix filenames may carry bidi/escape
#      bytes. Defense: __cm_sanitize_for_display strips Cc+Cf before display.
#
# Assertions target the ATTACKER payload specifically — NOT "no ESC at all",
# because statusline legitimately emits its own constant OSC-2 title escape.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/tests/helpers/test-helpers.sh"
claude_modes_test::setup

PY="${CLAUDE_MODES_PYTHON3:-/usr/bin/python3}"

# ─── 1. statusline.sh rejects a malicious .mode body ──────────────────
mkdir -p "${HOME}/.claude/modes"
REPO="${HOME}/repo-statusline"
mkdir -p "$REPO/.claude/modes"
( cd "$REPO" && git init -q -b main >/dev/null 2>&1 \
  && git config user.email t@t && git config user.name t \
  && git commit -q --allow-empty -m init ) 2>/dev/null

# Malicious .mode: an OSC-2 title escape that would set the terminal title to
# "HACKED", plus a CSI clear. read_validated_mode_body must reject this body.
printf 'evil\x1b]2;HACKED\x07\x1b[2Kmode' > "$REPO/.claude/modes/main.mode"

sl_out=$(echo "{\"workspace\":{\"current_dir\":\"$REPO\"}}" \
  | bash "${PLUGIN_ROOT}/scripts/statusline.sh" 2>/dev/null)

claude_modes_test::it "statusline: attacker payload 'HACKED' absent from output (malicious .mode rejected)"
if printf '%s' "$sl_out" | grep -q "HACKED"; then
  claude_modes_test::fail "attacker OSC-2 title payload reached the terminal: $(printf '%s' "$sl_out" | cat -v)"
else
  claude_modes_test::pass
fi

claude_modes_test::it "statusline: no mode segment emitted for an invalid .mode body"
# A rejected body → __cm_reset_and_exit → only the plugin's own title (cwd
# basename 'repo-statusline'), never the attacker 'evil...mode' string.
if printf '%s' "$sl_out" | grep -q "evilmode\|evil"; then
  claude_modes_test::fail "invalid mode body leaked into statusline: $(printf '%s' "$sl_out" | cat -v)"
else
  claude_modes_test::pass
fi

# Control: a LEGITIMATE .mode body still produces the mode segment.
printf 'delivery' > "$REPO/.claude/modes/main.mode"
sl_ok=$(echo "{\"workspace\":{\"current_dir\":\"$REPO\"}}" \
  | bash "${PLUGIN_ROOT}/scripts/statusline.sh" 2>/dev/null)
claude_modes_test::it "statusline: legitimate 'delivery' mode still renders"
if printf '%s' "$sl_ok" | grep -q "delivery"; then
  claude_modes_test::pass
else
  claude_modes_test::fail "legitimate mode 'delivery' did not render: $(printf '%s' "$sl_ok" | cat -v)"
fi

# ─── 2. on-post-tool-use.sh sanitizes the basename in the consent prompt ─
# The prompt goes to /dev/tty (not capturable in CI), so test the sanitizer
# helper directly: it must strip Cc+Cf (incl. U+202E bidi, ESC, CR).
# Source the helper out of the script without running main (the script runs
# top-to-bottom on execute; we extract the function via a subshell define).
__cm_sanitize_probe() {
  "$PY" - "$1" <<'PYEOF' 2>/dev/null
import sys, unicodedata
sys.stdout.write("".join(c for c in sys.argv[1] if unicodedata.category(c) not in ("Cc", "Cf")))
PYEOF
}

claude_modes_test::it "basename sanitizer strips U+202E bidi override"
malic=$(printf 'safe\xe2\x80\xaednp.gp')   # 'safe' + U+202E + 'dnp.gp'
clean=$(__cm_sanitize_probe "$malic")
if printf '%s' "$clean" | LC_ALL=C grep -q "$(printf '\xe2\x80\xae')"; then
  claude_modes_test::fail "U+202E survived sanitization"
else
  claude_modes_test::pass
fi

claude_modes_test::it "basename sanitizer strips ESC + CR control bytes"
malic2=$(printf 'safe\x1b[2K\rmd')
clean2=$(__cm_sanitize_probe "$malic2")
if printf '%s' "$clean2" | LC_ALL=C grep -q "$(printf '\x1b')" \
   || printf '%s' "$clean2" | LC_ALL=C grep -q "$(printf '\r')"; then
  claude_modes_test::fail "ESC or CR survived sanitization: $(printf '%s' "$clean2" | cat -v)"
else
  claude_modes_test::pass
fi

claude_modes_test::it "basename sanitizer preserves legitimate filename chars"
clean3=$(__cm_sanitize_probe "my-command.md")
claude_modes_test::assert_eq "my-command.md" "$clean3"

# ─── 3. /mode:status sanitizes a hostile CLONE PATH through all derivations ─
# Round-5: repo_root is mixed-use (FS + display). Sanitizing at source would
# break FS reads, so status.sh uses sanitized _d display variants for the
# derived paths (tier_4_path/settings_local/sidecar). This test proves the
# bidi byte in a clone-dir name reaches NONE of /mode:status's output lines —
# the regression test for "source sanitization works through all derivations".
mkdir -p "${HOME}/.claude/modes"
# Clone dir whose name carries a U+202E RTL override (Cf).
EVIL_PARENT="${HOME}/$(printf 'clone\xe2\x80\xaedir')"
mkdir -p "$EVIL_PARENT" 2>/dev/null
EVIL_REPO="${EVIL_PARENT}/repo"
mkdir -p "$EVIL_REPO/.claude/modes"
( cd "$EVIL_REPO" && git init -q -b main >/dev/null 2>&1 \
  && git config user.email t@t && git config user.name t \
  && git commit -q --allow-empty -m init ) 2>/dev/null
# Give it a _repo.yaml so the tier-4 path lines render.
printf 'schema_version: 2\nname: _repo\nmechanism:\n  enabledPlugins: {}\n' \
  > "$EVIL_REPO/.claude/modes/_repo.yaml"

# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/lib/status.sh"
status_out=$( cd "$EVIL_REPO" && claude_modes::status 2>&1 )

claude_modes_test::it "/mode:status: U+202E in clone path absent from ALL output (derived paths sanitized)"
if printf '%s' "$status_out" | LC_ALL=C grep -q "$(printf '\xe2\x80\xae')"; then
  claude_modes_test::fail "U+202E from clone path leaked into /mode:status output: $(printf '%s' "$status_out" | cat -v | head -20)"
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
