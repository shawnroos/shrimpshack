#!/usr/bin/env bash
# agent-native-001 integration: PostToolUse adopt-skip writes an untagged-file
# session marker so the AGENT (not just the human via /dev/tty) can discover
# the untagged file and adopt it.
#
# Contract:
#   - Skip (non-interactive): marker created at
#     ~/.claude/modes/.sessions/<session_id>.untagged-files naming the file +
#     the /mode:adopt command, AND the file stays a regular file.
#   - Adopt (ASSUME_YES): NO marker (the file was adopted, nothing untagged).
#   - Two skips in one session: BOTH entries accumulate in one marker.
#   - The marker is self-describing (carries its own header), because
#     inject-prose.sh cats it verbatim with no header of its own.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/tests/helpers/test-helpers.sh"

claude_modes_test::setup

PY="${CLAUDE_MODES_PYTHON3}"
POSTWRITE_HOOK="${PLUGIN_ROOT}/scripts/on-post-tool-use.sh"

# Event JSON WITH a known session_id (so the marker path is deterministic).
__make_event_sid() {
  "$PY" - "$1" "$2" <<'PYEOF'
import sys, json
fp = sys.argv[1]
sid = sys.argv[2]
print(json.dumps({
    "tool_name": "Write",
    "tool_input": {"file_path": fp},
    "tool_response": {},
    "session_id": sid,
}))
PYEOF
}

__seed_delivery_mode() {
  mkdir -p "${HOME}/.claude/modes"
  cat > "${HOME}/.claude/modes/delivery.yaml" <<EOF
schema_version: 2
name: delivery
mechanism:
  enabledPlugins:
    "delivery-plugin@market": true
EOF
  chmod 0600 "${HOME}/.claude/modes/delivery.yaml"
  printf 'delivery' > "${HOME}/.claude/modes/.last-active-mode"
  chmod 0600 "${HOME}/.claude/modes/.last-active-mode"
  mkdir -p "${HOME}/.claude/commands"
}

SID="sess-untagged-001"
MARKER="${HOME}/.claude/modes/.sessions/${SID}.untagged-files"

# ──────────────────────────────────────────────────────────────────────
__seed_delivery_mode

# ─── Scenario 1: non-interactive skip writes a marker ─────────────────
printf '# foo\n' > "${HOME}/.claude/commands/foo.md"
event=$(__make_event_sid "${HOME}/.claude/commands/foo.md" "$SID")
out=$(printf '%s' "$event" | CLAUDE_NON_INTERACTIVE=1 bash "$POSTWRITE_HOOK" 2>&1)

claude_modes_test::it "non-interactive skip: untagged-files marker created"
claude_modes_test::assert_file_exists "$MARKER"

claude_modes_test::it "non-interactive skip: marker names the file + adopt command"
mc=$(cat "$MARKER" 2>/dev/null)
if printf '%s' "$mc" | grep -q "foo.md" \
   && printf '%s' "$mc" | grep -q "/mode:adopt"; then
  claude_modes_test::pass
else
  claude_modes_test::fail "marker missing file or adopt cmd: ${mc}"
fi

claude_modes_test::it "non-interactive skip: marker is self-describing (has header)"
if printf '%s' "$mc" | grep -q "Untagged files written this session"; then
  claude_modes_test::pass
else
  claude_modes_test::fail "marker has no header: ${mc}"
fi

claude_modes_test::it "non-interactive skip: foo.md stays a regular file"
if [ -L "${HOME}/.claude/commands/foo.md" ]; then
  claude_modes_test::fail "foo.md became a symlink (was adopted, not skipped)"
else
  claude_modes_test::pass
fi

# ─── Scenario 2: second skip accumulates into the same marker ─────────
printf '# baz\n' > "${HOME}/.claude/commands/baz.md"
event2=$(__make_event_sid "${HOME}/.claude/commands/baz.md" "$SID")
printf '%s' "$event2" | CLAUDE_NON_INTERACTIVE=1 bash "$POSTWRITE_HOOK" >/dev/null 2>&1

claude_modes_test::it "second skip: both foo.md AND baz.md in one marker"
mc2=$(cat "$MARKER" 2>/dev/null)
if printf '%s' "$mc2" | grep -q "foo.md" && printf '%s' "$mc2" | grep -q "baz.md"; then
  claude_modes_test::pass
else
  claude_modes_test::fail "marker missing one of the two files: ${mc2}"
fi

claude_modes_test::it "second skip: header written exactly once"
header_count=$(grep -c "Untagged files written this session" "$MARKER" 2>/dev/null || echo 0)
claude_modes_test::assert_eq "1" "$header_count"

# ─── Scenario 3: adopt (ASSUME_YES) writes NO marker ──────────────────
SID3="sess-untagged-adopt"
MARKER3="${HOME}/.claude/modes/.sessions/${SID3}.untagged-files"
printf '# qux\n' > "${HOME}/.claude/commands/qux.md"
event3=$(__make_event_sid "${HOME}/.claude/commands/qux.md" "$SID3")
printf '%s' "$event3" \
  | CLAUDE_NON_INTERACTIVE=0 CLAUDE_MODES_ADOPT_ASSUME_YES=1 \
    bash "$POSTWRITE_HOOK" >/dev/null 2>&1

claude_modes_test::it "adopt (ASSUME_YES): NO untagged marker (file was adopted)"
claude_modes_test::assert_file_absent "$MARKER3"

# ─── C0: SessionStart 7-day marker pruner ─────────────────────────────
# A stale marker (>7 days old) must be deleted by on-session-start.sh; a
# fresh one must survive. Guards the pruner inject-prose.sh:28 refers to.
SESS_DIR="${HOME}/.claude/modes/.sessions"
mkdir -p "$SESS_DIR"
STALE="${SESS_DIR}/sess-ancient.untagged-files"
FRESH="${SESS_DIR}/sess-recent.untagged-files"
printf 'old\n' > "$STALE"
printf 'new\n' > "$FRESH"
# Backdate the stale marker 10 days (touch -t YYYYMMDDhhmm).
touch -t "$(date -v-10d '+%Y%m%d%H%M' 2>/dev/null || date -d '10 days ago' '+%Y%m%d%H%M')" "$STALE"

# Invoke SessionStart (it runs the pruner before exec'ing reconcile; we only
# need the pruner to fire, so feed an empty event and ignore exec downstream).
printf '{}' | bash "${PLUGIN_ROOT}/scripts/on-session-start.sh" >/dev/null 2>&1 || true

claude_modes_test::it "C0 pruner: stale (>7d) marker deleted"
claude_modes_test::assert_file_absent "$STALE"

claude_modes_test::it "C0 pruner: fresh marker preserved"
claude_modes_test::assert_file_exists "$FRESH"

# ──────────────────────────────────────────────────────────────────────
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
