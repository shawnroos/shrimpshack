#!/usr/bin/env bash
# U11 integration test: R20 new-file adoption (three paths).
#
# Covers AE6 a/b/c plus edges:
#   AE6a — manual /mode:adopt
#   AE6b — PostToolUse Y branch (using CLAUDE_MODES_ADOPT_ASSUME_YES=1
#          test-only override; see note in scripts/on-post-tool-use.sh
#          about /dev/tty being unreliably scriptable from `read`)
#   AE6c — non-interactive default N (no prompt, no FS change, audit_skip)
#   + temp-file filter (.tmp-foo.md → no prompt)
#   + already-adopted (idempotent no-op + clear message)
#   + path-traversal arg to /mode:adopt (R7 refusal)
#   + SessionStart-scan first-run (baseline only, no marker)
#   + SessionStart-scan detects new file (marker written)
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

ADOPT_LIB="${PLUGIN_ROOT}/lib/adopt-file.sh"
POSTWRITE_HOOK="${PLUGIN_ROOT}/scripts/on-post-tool-use.sh"
SESSIONSTART_HOOK="${PLUGIN_ROOT}/scripts/on-session-start.sh"

# Seed a minimal delivery mode YAML + active-mode pointer + staging dirs.
__seed_delivery_mode() {
  mkdir -p "${HOME}/.claude/modes/.user-catalog/commands" \
           "${HOME}/.claude/modes/.user-catalog/agents" \
           "${HOME}/.claude/commands" \
           "${HOME}/.claude/agents"
  cat > "${HOME}/.claude/modes/delivery.yaml" <<'YAML'
schema_version: 2
name: delivery
description: U11 test fixture
philosophy: |
  Ship it.
mechanism:
  enabledPlugins:
    "claude-modes@local-dev": true
  user_catalog:
    commands: []
    agents: []
YAML
  chmod 0600 "${HOME}/.claude/modes/delivery.yaml"
  printf 'delivery' > "${HOME}/.claude/modes/.last-active-mode"
}

# Reset HOME-state between scenarios (keeps PYTHONPATH leak from helpers).
__reset_home_state() {
  rm -rf "${HOME}/.claude"
  mkdir -m 0700 -p "${HOME}/.claude/modes"
}

# Build a PostToolUse event JSON object.
__make_event() {
  "$CLAUDE_MODES_PYTHON3" - "$@" <<'PYEOF'
import sys, json
file_path = sys.argv[1]
d = {"tool_name": "Write",
     "tool_input": {"file_path": file_path},
     "tool_response": {}}
print(json.dumps(d))
PYEOF
}

# Check whether the audit log's last line is an event of a given name
# with a given key=val. Returns 0 if matched, 1 if not.
__audit_last_has() {
  local event="$1"
  local needle="$2"
  local last
  last=$(tail -n 1 "${HOME}/.claude/modes/.audit.log" 2>/dev/null)
  case "$last" in
    *"event=${event}"*"${needle}"*) return 0 ;;
    *) return 1 ;;
  esac
}

# ──────────────────────────────────────────────────────────────────────────
# AE6a — manual /mode:adopt
# ──────────────────────────────────────────────────────────────────────────
__reset_home_state
__seed_delivery_mode

claude_modes_test::it "AE6a: setup seeds delivery mode + commands/strict-deploy.md"
printf '# strict deploy\n' > "${HOME}/.claude/commands/strict-deploy.md"
content_sha_before=$("$CLAUDE_MODES_PYTHON3" -c \
  "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" \
  "${HOME}/.claude/commands/strict-deploy.md")
claude_modes_test::assert_file_exists "${HOME}/.claude/commands/strict-deploy.md"

claude_modes_test::it "AE6a: adopt-file.sh succeeds on basename arg"
adopt_out=$(bash "$ADOPT_LIB" "strict-deploy.md" 2>&1)
adopt_rc=$?
claude_modes_test::assert_eq "0" "$adopt_rc"

claude_modes_test::it "AE6a: live path is now a symlink"
if [ -L "${HOME}/.claude/commands/strict-deploy.md" ]; then
  claude_modes_test::pass
else
  claude_modes_test::fail "expected symlink at live path; got: $(ls -la "${HOME}/.claude/commands/strict-deploy.md" 2>&1)"
fi

claude_modes_test::it "AE6a: staging file content sha matches pre-adopt sha"
content_sha_after=$("$CLAUDE_MODES_PYTHON3" -c \
  "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" \
  "${HOME}/.claude/modes/.user-catalog/commands/strict-deploy.md")
claude_modes_test::assert_eq "$content_sha_before" "$content_sha_after"

claude_modes_test::it "AE6a: delivery.yaml user_catalog.commands now contains strict-deploy.md"
manifest=$(bash "${PLUGIN_ROOT}/lib/mode-yaml.sh" user-catalog \
  "${HOME}/.claude/modes/delivery.yaml" commands)
claude_modes_test::assert_contains "$manifest" "strict-deploy.md"

claude_modes_test::it "AE6a: audit log records adopt event with source=manual"
if __audit_last_has "adopt" "source=manual"; then
  claude_modes_test::pass
else
  claude_modes_test::fail "audit log last line missing adopt+source=manual: $(tail -1 ${HOME}/.claude/modes/.audit.log 2>&1)"
fi

# ──────────────────────────────────────────────────────────────────────────
# AE6b — PostToolUse Y branch (test-mode auto-yes)
# ──────────────────────────────────────────────────────────────────────────
__reset_home_state
__seed_delivery_mode

claude_modes_test::it "AE6b: setup seeds delivery mode + writes foo.md"
printf '# foo\n' > "${HOME}/.claude/commands/foo.md"
claude_modes_test::assert_file_exists "${HOME}/.claude/commands/foo.md"

claude_modes_test::it "AE6b: PostToolUse hook with ASSUME_YES adopts the file"
event=$(__make_event "${HOME}/.claude/commands/foo.md")
# Force interactivity AND auto-yes. CLAUDE_NON_INTERACTIVE=0 says "treat as
# interactive" overriding the non-TTY stdin; CLAUDE_MODES_ADOPT_ASSUME_YES=1
# skips the /dev/tty read (which isn't scriptable from a test).
out=$(printf '%s' "$event" \
  | CLAUDE_NON_INTERACTIVE=0 CLAUDE_MODES_ADOPT_ASSUME_YES=1 \
    bash "$POSTWRITE_HOOK" 2>&1)
rc=$?
claude_modes_test::assert_eq "0" "$rc"

claude_modes_test::it "AE6b: foo.md is now a symlink"
if [ -L "${HOME}/.claude/commands/foo.md" ]; then
  claude_modes_test::pass
else
  claude_modes_test::fail "expected symlink at live path; output was: $out"
fi

claude_modes_test::it "AE6b: delivery.yaml manifest now contains foo.md"
manifest=$(bash "${PLUGIN_ROOT}/lib/mode-yaml.sh" user-catalog \
  "${HOME}/.claude/modes/delivery.yaml" commands)
claude_modes_test::assert_contains "$manifest" "foo.md"

claude_modes_test::it "AE6b: audit records source=post-tool-use"
if __audit_last_has "adopt" "source=post-tool-use"; then
  claude_modes_test::pass
else
  claude_modes_test::fail "audit last line: $(tail -1 ${HOME}/.claude/modes/.audit.log 2>&1)"
fi

# ──────────────────────────────────────────────────────────────────────────
# AE6c — non-interactive default N
# ──────────────────────────────────────────────────────────────────────────
__reset_home_state
__seed_delivery_mode

claude_modes_test::it "AE6c: setup seeds delivery mode + writes bar.md"
printf '# bar\n' > "${HOME}/.claude/commands/bar.md"

claude_modes_test::it "AE6c: PostToolUse hook with NON_INTERACTIVE=1 does NOT prompt"
event=$(__make_event "${HOME}/.claude/commands/bar.md")
out=$(printf '%s' "$event" \
  | CLAUDE_NON_INTERACTIVE=1 bash "$POSTWRITE_HOOK" 2>&1)
rc=$?
claude_modes_test::assert_eq "0" "$rc"

claude_modes_test::it "AE6c: bar.md remains a regular file (no symlink)"
if [ -L "${HOME}/.claude/commands/bar.md" ]; then
  claude_modes_test::fail "expected regular file; got symlink"
else
  claude_modes_test::pass
fi

claude_modes_test::it "AE6c: audit records adopt_skip with reason=non-interactive"
if __audit_last_has "adopt_skip" "reason=non-interactive"; then
  claude_modes_test::pass
else
  claude_modes_test::fail "audit last line: $(tail -1 ${HOME}/.claude/modes/.audit.log 2>&1)"
fi

# ──────────────────────────────────────────────────────────────────────────
# Temp-file filter — .tmp-* path
# ──────────────────────────────────────────────────────────────────────────
__reset_home_state
__seed_delivery_mode

claude_modes_test::it "temp-file filter: writes to .tmp-foo.md → hook is silent no-op"
printf '# tmp\n' > "${HOME}/.claude/commands/.tmp-foo.md"
event=$(__make_event "${HOME}/.claude/commands/.tmp-foo.md")
out=$(printf '%s' "$event" \
  | CLAUDE_NON_INTERACTIVE=0 CLAUDE_MODES_ADOPT_ASSUME_YES=1 \
    bash "$POSTWRITE_HOOK" 2>&1)
rc=$?
claude_modes_test::assert_eq "0" "$rc"

claude_modes_test::it "temp-file filter: .tmp-foo.md is still a regular file"
if [ -L "${HOME}/.claude/commands/.tmp-foo.md" ]; then
  claude_modes_test::fail "expected regular file; .tmp- exclusion failed"
else
  claude_modes_test::pass
fi

# ──────────────────────────────────────────────────────────────────────────
# Already-adopted — /mode:adopt on a file that's already a symlink into
# .user-catalog/ exits cleanly with a clear message and no FS changes.
# ──────────────────────────────────────────────────────────────────────────
__reset_home_state
__seed_delivery_mode

claude_modes_test::it "already-adopted: setup adopts baz.md once"
printf '# baz\n' > "${HOME}/.claude/commands/baz.md"
bash "$ADOPT_LIB" "baz.md" >/dev/null 2>&1

claude_modes_test::it "already-adopted: re-adopting reports already managed (rc=0)"
out=$(bash "$ADOPT_LIB" "baz.md" 2>&1)
rc=$?
claude_modes_test::assert_eq "0" "$rc"
claude_modes_test::assert_contains "$out" "already managed by mode 'delivery'"

claude_modes_test::it "already-adopted: symlink target is unchanged"
target=$(readlink "${HOME}/.claude/commands/baz.md")
case "$target" in
  */modes/.user-catalog/commands/baz.md) claude_modes_test::pass ;;
  *) claude_modes_test::fail "unexpected symlink target: $target" ;;
esac

# ──────────────────────────────────────────────────────────────────────────
# Half-adopted repair (round-7 correctness P1) — a prior adopt ran steps 6-7
# (mv + symlink) but step 8 (manifest write) failed/was interrupted: the file
# is staged + symlinked but recorded in NO mode manifest. Re-running adopt must
# COMPLETE the manifest recording, not return 0 silently (which would let the
# next symlink_rebuild delete the orphan symlink and strand the file).
# ──────────────────────────────────────────────────────────────────────────
__reset_home_state
__seed_delivery_mode

claude_modes_test::it "half-adopted: adopt qux.md, then simulate step-8 failure (strip manifest entry)"
printf '# qux\n' > "${HOME}/.claude/commands/qux.md"
bash "$ADOPT_LIB" "qux.md" >/dev/null 2>&1
# Confirm it landed in the manifest, then strip it to simulate the half-state:
# rewrite delivery.yaml WITHOUT the qux.md user_catalog entry while leaving the
# staged file + symlink in place.
__cm_delivery="${HOME}/.claude/modes/delivery.yaml"
if grep -q 'qux.md' "$__cm_delivery"; then
  grep -v 'qux.md' "$__cm_delivery" > "${__cm_delivery}.tmp" && mv "${__cm_delivery}.tmp" "$__cm_delivery"
  claude_modes_test::pass
else
  claude_modes_test::fail "precondition failed: qux.md not in manifest after first adopt"
fi

claude_modes_test::it "half-adopted: symlink + staged file still present (half-state)"
if [ -L "${HOME}/.claude/commands/qux.md" ] && [ -f "${HOME}/.claude/modes/.user-catalog/commands/qux.md" ]; then
  claude_modes_test::pass
else
  claude_modes_test::fail "half-state setup wrong: symlink or staged file missing"
fi

claude_modes_test::it "half-adopted: re-running adopt REPAIRS the manifest (rc=0, not silent already-staged)"
out=$(bash "$ADOPT_LIB" "qux.md" 2>&1)
rc=$?
claude_modes_test::assert_eq "0" "$rc"
claude_modes_test::assert_contains "$out" "half-adopted"

claude_modes_test::it "half-adopted: manifest now records qux.md again (file no longer strandable)"
manifest=$(bash "${PLUGIN_ROOT}/lib/mode-yaml.sh" user-catalog "$__cm_delivery" commands)
claude_modes_test::assert_contains "$manifest" "qux.md"

# ──────────────────────────────────────────────────────────────────────────
# Reconcile-first half-state recovery (round-8 adversarial P1, the NATURAL
# ordering): adopt stages+symlinks a file, step-8 manifest write fails, THEN
# symlink_rebuild (every SessionStart) deletes the orphaned live symlink before
# the user re-runs adopt. The file is now in staging only, gone from the live
# dir. Re-running /mode:adopt must RECOVER it (re-create symlink + record
# manifest), not report "not found" and leave it stranded.
# ──────────────────────────────────────────────────────────────────────────
__reset_home_state
__seed_delivery_mode

claude_modes_test::it "reconcile-first: adopt zog.md, strip manifest, then reconcile DELETES the orphan live symlink"
printf '# zog\n' > "${HOME}/.claude/commands/zog.md"
bash "$ADOPT_LIB" "zog.md" >/dev/null 2>&1
__cm_delivery="${HOME}/.claude/modes/delivery.yaml"
# Simulate step-8 failure: strip the manifest entry (leave symlink + staged file).
grep -v 'zog.md' "$__cm_delivery" > "${__cm_delivery}.tmp" && command mv -f "${__cm_delivery}.tmp" "$__cm_delivery"
# Reconcile for the active mode (what SessionStart does) — deletes the orphan.
( . "${PLUGIN_ROOT}/lib/symlink-rebuild.sh"; claude_modes::symlink_rebuild "$__cm_delivery" ) >/dev/null 2>&1
if [ ! -L "${HOME}/.claude/commands/zog.md" ] && [ -f "${HOME}/.claude/modes/.user-catalog/commands/zog.md" ]; then
  claude_modes_test::pass   # live symlink gone, staged file orphaned — the P1 precondition
else
  claude_modes_test::fail "expected orphaned state: live symlink deleted + staged file present"
fi

claude_modes_test::it "reconcile-first: re-running adopt RECOVERS the orphan (rc=0, not 'not found')"
out=$(bash "$ADOPT_LIB" "zog.md" 2>&1)
rc=$?
claude_modes_test::assert_eq "0" "$rc"
claude_modes_test::assert_contains "$out" "recovered orphaned"

claude_modes_test::it "reconcile-first: live symlink re-created + manifest re-records zog.md"
manifest=$(bash "${PLUGIN_ROOT}/lib/mode-yaml.sh" user-catalog "$__cm_delivery" commands)
if [ -L "${HOME}/.claude/commands/zog.md" ] && printf '%s' "$manifest" | grep -Fxq "zog.md"; then
  claude_modes_test::pass
else
  claude_modes_test::fail "recovery incomplete: symlink=$([ -L "${HOME}/.claude/commands/zog.md" ] && echo yes||echo no) manifest=[$manifest]"
fi

# ──────────────────────────────────────────────────────────────────────────
# round-8 P2: a BROKEN plugin-owned symlink (staging target deleted) must NOT
# be "repaired" into a false manifest entry. adopt must refuse + report.
# ──────────────────────────────────────────────────────────────────────────
__reset_home_state
__seed_delivery_mode

claude_modes_test::it "broken-symlink: adopt dang.md, then DELETE the staged target (dangling symlink)"
printf '# dang\n' > "${HOME}/.claude/commands/dang.md"
bash "$ADOPT_LIB" "dang.md" >/dev/null 2>&1
# Delete the staging target so the live symlink dangles.
rm -f "${HOME}/.claude/modes/.user-catalog/commands/dang.md"
if [ -L "${HOME}/.claude/commands/dang.md" ] && [ ! -e "${HOME}/.claude/commands/dang.md" ]; then
  claude_modes_test::pass   # dangling symlink: link present, target gone
else
  claude_modes_test::fail "expected a dangling symlink (link present, target gone)"
fi

claude_modes_test::it "broken-symlink: re-adopt via PATH-shaped arg REFUSES (rc!=0) + writes NO false manifest entry"
__cm_delivery="${HOME}/.claude/modes/delivery.yaml"
# Strip any prior manifest entry to make a false-write detectable.
grep -v 'dang.md' "$__cm_delivery" > "${__cm_delivery}.tmp" && command mv -f "${__cm_delivery}.tmp" "$__cm_delivery"
# Use the PATH-shaped arg form (absolute path) — the pure-basename form is
# already rejected earlier by the `[ -e ]` probe, so it never reaches the
# dangling-symlink guard. The path form DOES reach it; this is what exercises
# the fix (verified via deliberate-fail: removing the guard makes this regress).
out=$(bash "$ADOPT_LIB" "${HOME}/.claude/commands/dang.md" 2>&1)
rc=$?
manifest=$(bash "${PLUGIN_ROOT}/lib/mode-yaml.sh" user-catalog "$__cm_delivery" commands)
if [ "$rc" -ne 0 ] && ! printf '%s' "$manifest" | grep -Fxq "dang.md"; then
  claude_modes_test::pass
else
  claude_modes_test::fail "expected refusal (rc!=0) + NO manifest entry; rc=$rc manifest=[$manifest] out=[$out]"
fi

# ──────────────────────────────────────────────────────────────────────────
# round-8/9: when a COMPETING mode YAML fails to parse, the claimant landscape
# is uncertain — orphan recovery / half-state repair must REFUSE rather than
# double-record. find_mode_of_record returns rc 2 (uncertain).
# ──────────────────────────────────────────────────────────────────────────
__reset_home_state
__seed_delivery_mode

claude_modes_test::it "malformed-claimant: find_mode_of_record returns rc 2 when a competing YAML is unparseable"
# Seed a half-state orphan (staged, no live symlink, not in any manifest), then
# corrupt a SECOND mode YAML so the claimant landscape is uncertain.
printf '# wob\n' > "${HOME}/.claude/commands/wob.md"
bash "$ADOPT_LIB" "wob.md" >/dev/null 2>&1
__cm_delivery="${HOME}/.claude/modes/delivery.yaml"
grep -v 'wob.md' "$__cm_delivery" > "${__cm_delivery}.tmp" && command mv -f "${__cm_delivery}.tmp" "$__cm_delivery"
( . "${PLUGIN_ROOT}/lib/symlink-rebuild.sh"; claude_modes::symlink_rebuild "$__cm_delivery" ) >/dev/null 2>&1
# Plant a malformed competing mode YAML.
printf 'schema_version: 2\nname: broke\nmechanism:\n  enabledPlugins: {{{ not yaml\n' > "${HOME}/.claude/modes/broke.yaml"
# find_mode_of_record for wob.md must report uncertainty (rc 2).
( . "${PLUGIN_ROOT}/lib/adopt-file.sh" 2>/dev/null
  __claude_modes::adopt_find_mode_of_record "commands" "wob.md" >/dev/null 2>&1
  exit $? )
fmr_rc=$?
claude_modes_test::assert_eq "2" "$fmr_rc"

claude_modes_test::it "malformed-claimant: re-adopt REFUSES to recover (rc!=0) when claimant landscape is uncertain"
out=$(bash "$ADOPT_LIB" "wob.md" 2>&1)
rc=$?
manifest=$(bash "${PLUGIN_ROOT}/lib/mode-yaml.sh" user-catalog "$__cm_delivery" commands 2>/dev/null)
if [ "$rc" -ne 0 ] && ! printf '%s' "$manifest" | grep -Fxq "wob.md"; then
  claude_modes_test::pass
else
  claude_modes_test::fail "expected refusal (rc!=0) + no recovery; rc=$rc manifest=[$manifest] out=[$out]"
fi

# ──────────────────────────────────────────────────────────────────────────
# Path-traversal arg to /mode:adopt
# ──────────────────────────────────────────────────────────────────────────
__reset_home_state
__seed_delivery_mode

claude_modes_test::it "path-traversal arg: ../../../etc/passwd is refused"
out=$(bash "$ADOPT_LIB" "../../../etc/passwd" 2>&1)
rc=$?
# Non-zero exit + clear message; path is NOT under our managed dirs.
if [ "$rc" != "0" ]; then
  claude_modes_test::pass
else
  claude_modes_test::fail "expected non-zero exit; got rc=0, out: $out"
fi

claude_modes_test::it "path-traversal arg: error mentions managed directories"
claude_modes_test::assert_contains "$out" "~/.claude/commands/ or ~/.claude/agents/"

# Absolute path traversal — pass /etc/passwd literally.
claude_modes_test::it "path-traversal arg: absolute /etc/passwd is refused"
out=$(bash "$ADOPT_LIB" "/etc/passwd" 2>&1)
rc=$?
if [ "$rc" != "0" ]; then
  claude_modes_test::pass
else
  claude_modes_test::fail "expected non-zero exit; got rc=0, out: $out"
fi

# ──────────────────────────────────────────────────────────────────────────
# SessionStart-scan first-run
# ──────────────────────────────────────────────────────────────────────────
__reset_home_state
__seed_delivery_mode

claude_modes_test::it "session-scan first-run: empty staging, no snapshot, no marker"
# Pre-condition: no .last-file-scan.json exists.
[ ! -f "${HOME}/.claude/modes/.last-file-scan.json" ]
# Run the session-start hook. The script will exec the reconcile-symlinks
# script if it exists; for the scan test we just need the U11 block to run
# before that, and the exec to NOT crash the scan output. We assert by
# checking snapshot creation rather than relying on exit code.
# round-7 fix: the writer derives the session key from the stdin event JSON's
# `session_id` field (matching every consumer), NOT the CLAUDE_SESSION_ID env.
out=$(printf '%s' '{"session_id":"sess-first"}' | bash "$SESSIONSTART_HOOK" 2>&1) || true

claude_modes_test::it "session-scan first-run: snapshot file is created"
claude_modes_test::assert_file_exists "${HOME}/.claude/modes/.last-file-scan.json"

claude_modes_test::it "session-scan first-run: NO untagged-files marker created"
claude_modes_test::assert_file_absent \
  "${HOME}/.claude/modes/.sessions/sess-first.untagged-files"

# ──────────────────────────────────────────────────────────────────────────
# SessionStart-scan detects new file
# ──────────────────────────────────────────────────────────────────────────
__reset_home_state
__seed_delivery_mode

claude_modes_test::it "session-scan detect: setup writes a.md and runs first-scan baseline"
printf '# a\n' > "${HOME}/.claude/commands/a.md"
printf '%s' '{"session_id":"sess-baseline"}' | bash "$SESSIONSTART_HOOK" >/dev/null 2>&1 || true
claude_modes_test::assert_file_exists "${HOME}/.claude/modes/.last-file-scan.json"

claude_modes_test::it "session-scan detect: writing c.md after baseline, run again"
printf '# c\n' > "${HOME}/.claude/commands/c.md"
printf '%s' '{"session_id":"sess-second"}' | bash "$SESSIONSTART_HOOK" >/dev/null 2>&1 || true

claude_modes_test::it "session-scan detect: marker file exists for sess-second"
claude_modes_test::assert_file_exists \
  "${HOME}/.claude/modes/.sessions/sess-second.untagged-files"

claude_modes_test::it "session-scan detect: marker references c.md"
marker_content=$(cat "${HOME}/.claude/modes/.sessions/sess-second.untagged-files" 2>/dev/null)
claude_modes_test::assert_contains "$marker_content" "c.md"

claude_modes_test::it "session-scan detect: marker does NOT reference a.md (baseline)"
case "$marker_content" in
  *"a.md"*) claude_modes_test::fail "marker should not include a.md (in baseline)" ;;
  *)        claude_modes_test::pass ;;
esac

claude_modes_test::it "session-scan detect: snapshot now includes both a.md and c.md"
snap=$(cat "${HOME}/.claude/modes/.last-file-scan.json")
claude_modes_test::assert_contains "$snap" "a.md"
case "$snap" in
  *"c.md"*) claude_modes_test::pass ;;
  *)        claude_modes_test::fail "snapshot should include c.md after second scan" ;;
esac

# round-7 CROSS-SEAM regression (correctness P1): prove the marker the WRITER
# created under the stdin-JSON session_id is found by a CONSUMER reading the
# SAME session_id. Before the fix the writer keyed off the CLAUDE_SESSION_ID env
# while the consumer keyed off stdin-JSON session_id → the toast was silently
# never delivered. inject-prose.sh takes the event JSON as a tmpfile arg; if it
# finds the sess-second marker it injects the new-file toast referencing c.md.
claude_modes_test::it "session-scan CROSS-SEAM: inject-prose (consumer) reads the marker the writer created under sess-second"
__cm_evt=$(mktemp "${TMPDIR:-/tmp}/cm-evt.XXXXXX")
printf '%s' '{"session_id":"sess-second","prompt":"go"}' > "$__cm_evt"
__cm_inject_out=$(bash "${PLUGIN_ROOT}/lib/inject-prose.sh" "$__cm_evt" 2>/dev/null || true)
rm -f "$__cm_evt"
claude_modes_test::assert_contains "$__cm_inject_out" "c.md"

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
