#!/usr/bin/env bash
# U6 integration test: lib/post-write-reload.sh — reload-prompt helper.
#
# Covers the DEGRADED R5 shape (Phase 0 Spike D): the default path PRINTS a
# visible /reload-plugins notice for the user to run; it does NOT auto-reload.
# Also covers the inert auto path's guard + failure handling via mocks so the
# upgrade path is test-pinned before it ever ships live.
#
# Scenarios:
#   Happy (degraded default) — prints notice containing /reload-plugins,
#     returns 0, audit records event=mode_reload_prompt outcome=ok
#   Edge — mode name with control/escape bytes is sanitized in the notice
#   Future-path: auto guard OFF by default — with no AUTO env the print
#     path fires (no "Reloading plugins" emission)
#   Future-path: AUTO=1 + mock ok — returns 0, audit outcome=ok
#   Future-path: AUTO=1 + mock fail — returns non-zero, audit outcome=reload_fail,
#     prints recovery message
#
# Output format expected by tests/run.sh:
#   <basename>: N passed, M failed

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/tests/helpers/test-helpers.sh"

claude_modes_test::setup
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/lib/post-write-reload.sh"

AUDIT_LOG="${HOME}/.claude/modes/.audit.log"

# Reset HOME-state (incl. the audit log) between scenarios.
__reset_home_state() {
  rm -rf "${HOME}/.claude"
  mkdir -m 0700 -p "${HOME}/.claude/modes"
}

# Check the audit log's LAST line is event=<event> carrying <needle>.
__audit_last_has() {
  local event="$1"
  local needle="$2"
  local last
  last=$(tail -n 1 "$AUDIT_LOG" 2>/dev/null)
  case "$last" in
    *"event=${event}"*"${needle}"*) return 0 ;;
    *) return 1 ;;
  esac
}

# ──────────────────────────────────────────────────────────────────────────
# Happy: degraded default path
# ──────────────────────────────────────────────────────────────────────────
__reset_home_state

# Notices now go to STDERR (side-effect-notice convention, write-mode-yaml.sh) —
# capture 2>&1 so the assertions still see the notice text.
claude_modes_test::it "happy: degraded default prints a notice and returns 0"
out=$(claude_modes::post_write_reload "delivery" "added figma plugin" 2>&1)
rc=$?
claude_modes_test::assert_eq "0" "$rc"

claude_modes_test::it "happy: notice contains the literal /reload-plugins command"
claude_modes_test::assert_contains "$out" "/reload-plugins"

claude_modes_test::it "happy: notice names the mode and the delta summary"
claude_modes_test::assert_contains "$out" "delivery"
claude_modes_test::assert_contains "$out" "added figma plugin"

# Channel discipline (cli-readiness P2): the notice is a side-effect instruction,
# not return data — it MUST go to stderr so a caller capturing stdout gets clean
# output. Capture the two streams SEPARATELY so a regression that moves the notice
# back to stdout is caught (a 2>&1 capture would mask it).
claude_modes_test::it "happy: notice goes to stderr, stdout stays empty"
__pwr_stdout=$(claude_modes::post_write_reload "delivery" "added figma plugin" 2>/dev/null)
__pwr_stderr=$(claude_modes::post_write_reload "delivery" "added figma plugin" 2>&1 >/dev/null)
claude_modes_test::assert_eq "" "$__pwr_stdout"
claude_modes_test::assert_contains "$__pwr_stderr" "/reload-plugins"

claude_modes_test::it "happy: notice does NOT claim an auto reload happened"
case "$out" in
  *"Reloading plugins"*) claude_modes_test::fail "degraded path must not emit 'Reloading plugins'; got: $out" ;;
  *) claude_modes_test::pass ;;
esac

# THE load-bearing audit assertion — if this is absent, the deliberate-fail
# probe (breaking the audit call) would pass vacuously.
claude_modes_test::it "happy: audit log records event=mode_reload_prompt outcome=ok"
if __audit_last_has "mode_reload_prompt" "outcome=ok"; then
  claude_modes_test::pass
else
  claude_modes_test::fail "audit last line missing mode_reload_prompt+outcome=ok: $(tail -n 1 "$AUDIT_LOG" 2>&1)"
fi

claude_modes_test::it "happy: audit log records the mode name"
if __audit_last_has "mode_reload_prompt" "mode=delivery"; then
  claude_modes_test::pass
else
  claude_modes_test::fail "audit last line missing mode=delivery: $(tail -n 1 "$AUDIT_LOG" 2>&1)"
fi

# ──────────────────────────────────────────────────────────────────────────
# Edge: mode name with control/escape bytes is sanitized in the notice.
# sanitize_for_display strips Cc (control, incl. ESC) + Cf (format) chars —
# NOT shell metacharacters. So we plant an ESC + a DEL (both Cc-class) and
# assert they do NOT appear raw in the printed notice.
# ──────────────────────────────────────────────────────────────────────────
__reset_home_state

claude_modes_test::it "edge: control/escape bytes in mode name are stripped from the notice"
# $'\x1b' = ESC (Cc), $'\x7f' = DEL (Cc). Embed both in the mode name.
evil_name=$'ev\x1bil\x7fmode'
out=$(claude_modes::post_write_reload "$evil_name" "delta" 2>&1)
rc=$?
# No raw ESC byte in the printed notice.
case "$out" in
  *$'\x1b'*) claude_modes_test::fail "raw ESC leaked into notice" ;;
  *$'\x7f'*) claude_modes_test::fail "raw DEL leaked into notice" ;;
  *) claude_modes_test::pass ;;
esac

claude_modes_test::it "edge: sanitized name keeps the printable letters"
# The printable residue 'evilmode' (control chars removed) should remain.
claude_modes_test::assert_contains "$out" "evilmode"

claude_modes_test::it "edge: sanitized path still returns 0 and still prints /reload-plugins"
claude_modes_test::assert_eq "0" "$rc"
claude_modes_test::assert_contains "$out" "/reload-plugins"

# ──────────────────────────────────────────────────────────────────────────
# Future-path: the auto guard is OFF by default — even with a mock present,
# the print path fires unless CLAUDE_MODES_AUTO_RELOAD=1 is set explicitly.
# ──────────────────────────────────────────────────────────────────────────
__reset_home_state

claude_modes_test::it "auto-guard-default: CLAUDE_MODES_TEST_RELOAD=ok WITHOUT AUTO=1 still uses the print path"
# Mock says "ok" but the auto guard is off → must NOT take the auto branch.
out=$(CLAUDE_MODES_TEST_RELOAD=ok claude_modes::post_write_reload "delivery" "delta" 2>&1)
rc=$?
claude_modes_test::assert_eq "0" "$rc"
claude_modes_test::assert_contains "$out" "/reload-plugins"
case "$out" in
  *"Reloading plugins"*) claude_modes_test::fail "auto branch fired despite AUTO guard being off" ;;
  *) claude_modes_test::pass ;;
esac

# ──────────────────────────────────────────────────────────────────────────
# Future-path: AUTO=1 + mock ok → returns 0, audit outcome=ok, emits the
# auto "Reloading plugins" notice (not the degraded prompt).
# ──────────────────────────────────────────────────────────────────────────
__reset_home_state

claude_modes_test::it "auto-ok: AUTO=1 + mock ok returns 0"
out=$(CLAUDE_MODES_AUTO_RELOAD=1 CLAUDE_MODES_TEST_RELOAD=ok \
  claude_modes::post_write_reload "delivery" "delta" 2>&1)
rc=$?
claude_modes_test::assert_eq "0" "$rc"

claude_modes_test::it "auto-ok: emits the auto reload notice"
claude_modes_test::assert_contains "$out" "Reloading plugins"

claude_modes_test::it "auto-ok: audit records outcome=ok"
if __audit_last_has "mode_reload_prompt" "outcome=ok"; then
  claude_modes_test::pass
else
  claude_modes_test::fail "audit last line: $(tail -n 1 "$AUDIT_LOG" 2>&1)"
fi

# ──────────────────────────────────────────────────────────────────────────
# Future-path: AUTO=1 + mock fail → returns non-zero, audit outcome=reload_fail,
# prints a recovery message. Does NOT revert anything (nothing to revert here).
# ──────────────────────────────────────────────────────────────────────────
__reset_home_state

claude_modes_test::it "auto-fail: AUTO=1 + mock fail returns non-zero"
out=$(CLAUDE_MODES_AUTO_RELOAD=1 CLAUDE_MODES_TEST_RELOAD=fail \
  claude_modes::post_write_reload "delivery" "delta" 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
  claude_modes_test::pass
else
  claude_modes_test::fail "expected non-zero rc on reload fail; got 0. out: $out"
fi

claude_modes_test::it "auto-fail: prints a recovery message naming /reload-plugins"
claude_modes_test::assert_contains "$out" "/reload-plugins"

claude_modes_test::it "auto-fail: recovery message reassures the YAML is up to date"
claude_modes_test::assert_contains "$out" "YAML is up to date"

claude_modes_test::it "auto-fail: audit records outcome=reload_fail"
if __audit_last_has "mode_reload_prompt" "outcome=reload_fail"; then
  claude_modes_test::pass
else
  claude_modes_test::fail "audit last line: $(tail -n 1 "$AUDIT_LOG" 2>&1)"
fi

# ──────────────────────────────────────────────────────────────────────────
# Future-path: AUTO=1 with NO mock at all → treated as fail (production has no
# real emission mechanism yet; silently faking success would hide the upgrade).
# ──────────────────────────────────────────────────────────────────────────
__reset_home_state

claude_modes_test::it "auto-no-mock: AUTO=1 with no CLAUDE_MODES_TEST_RELOAD defaults to fail (non-zero)"
out=$(CLAUDE_MODES_AUTO_RELOAD=1 claude_modes::post_write_reload "delivery" "delta" 2>&1)
rc=$?
if [ "$rc" -ne 0 ] && __audit_last_has "mode_reload_prompt" "outcome=reload_fail"; then
  claude_modes_test::pass
else
  claude_modes_test::fail "expected non-zero + reload_fail audit; rc=$rc audit=$(tail -n 1 "$AUDIT_LOG" 2>&1)"
fi

# ──────────────────────────────────────────────────────────────────────────
# Teardown + summary.

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
