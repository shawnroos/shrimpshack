#!/usr/bin/env bash
# U10 integration test: R25 UserPromptSubmit prose-injection hook.
#
# Test scenarios:
#   1. Happy path — first prompt with active mode set: emits valid JSON with
#      additionalContext containing "Active mode: <name>" header AND prose
#      (philosophy / constraints).
#   2. Subsequent prompt, same session — header suppressed (marker debounce),
#      but prose body still present.
#   3. No active mode set anywhere — exit 0, empty stdout.
#   4. PROSE_INJECTION_DISABLED=1 — exit 0 immediately, empty stdout.
#   5. Empty session_id in event — script falls back to ppid-<pid> for the
#      injected marker filename, still emits prose.
#   6. Pending divergence-toast marker for session — appears in additionalContext,
#      marker file is removed (one-shot consumption).
#   7. Malformed mode YAML — hook still exits 0 (rel-001), no crash.
#
# Output format expected by tests/run.sh:
#   <basename>: N passed, M failed   (or "<basename> results: ...")

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/tests/helpers/test-helpers.sh"

claude_modes_test::setup

# The hook shim looks up CLAUDE_PLUGIN_ROOT; under direct test invocation
# it isn't set by the harness, so export it explicitly. This makes the
# shim resolve lib/inject-prose.sh under the real plugin tree.
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

HOOK="${PLUGIN_ROOT}/scripts/on-prompt-submit.sh"

# Helper: run the hook with a JSON event piped on stdin; capture stdout.
# Args are key=value pairs that become a JSON object.
__run_hook() {
  local payload="$1"
  printf '%s' "$payload" | bash "$HOOK"
}

# Helper: build a JSON event with arbitrary fields. Uses python for safe escaping.
__make_event() {
  "$CLAUDE_MODES_PYTHON3" - "$@" <<'PYEOF'
import sys, json
d = {}
for kv in sys.argv[1:]:
    k, _, v = kv.partition("=")
    d[k] = v
print(json.dumps(d))
PYEOF
}

# Seed a "delivery" mode YAML for the happy-path tests.
__seed_delivery_mode() {
  cat > "${HOME}/.claude/modes/delivery.yaml" <<'YAML'
schema_version: 2
name: delivery
description: |
  Delivery mode for happy-path tests.
philosophy: |
  Ship the thing. Resist scope creep.
scope: |
  Active feature branches only.
lens: |
  Quality bar: it works for the next person who reads it.
constraints:
  - "Do not refactor adjacent code."
  - "Tests for the slice you're shipping; not the rest of the file."
mechanism:
  enabledPlugins:
    "claude-modes@local-dev": true
YAML
  printf 'delivery' > "${HOME}/.claude/modes/.last-active-mode"
}

# Helper: extract the prose body from the hook's emitted JSON. Returns empty
# if the output is not valid JSON or has no additionalContext field.
#
# Output contract is {"hookSpecificOutput": {"hookEventName": "UserPromptSubmit",
# "additionalContext": "<prose>"}} — see scripts/on-prompt-submit.sh and
# lib/inject-prose.sh. The OLD contract (pre-fix) was {"additionalContext": ...},
# which the harness rendered as a USER-VISIBLE warning instead of suppressing
# into a system-reminder. additionalContext is the documented key for hidden
# context injection (see Claude Code Hooks reference).
__extract_additional_context() {
  local stdout="$1"
  "$CLAUDE_MODES_PYTHON3" - "$stdout" <<'PYEOF' 2>/dev/null || true
import sys, json
raw = sys.argv[1]
if not raw.strip():
    sys.exit(0)
try:
    obj = json.loads(raw)
except Exception:
    sys.exit(0)
hso = obj.get("hookSpecificOutput") or {}
if not isinstance(hso, dict):
    sys.exit(0)
v = hso.get("additionalContext")
if v is None:
    sys.exit(0)
sys.stdout.write(v)
PYEOF
}

# ──────────────────────────────────────────────────────────────────────────
# Scenario 1: Happy path — first prompt, active mode set.
# ──────────────────────────────────────────────────────────────────────────
claude_modes_test::it "first prompt with active mode emits header + prose"
__seed_delivery_mode
event=$(__make_event "session_id=sess-1" "prompt=hello there")
out=$(__run_hook "$event")
rc=$?

# Always exits 0 (rel-001).
claude_modes_test::it "first prompt: hook exit code is 0"
claude_modes_test::assert_eq "0" "$rc"

# Stdout is a single line of valid JSON.
claude_modes_test::it "first prompt: stdout parses as JSON with additionalContext"
sm=$(__extract_additional_context "$out")
if [ -n "$sm" ]; then
  claude_modes_test::pass
else
  claude_modes_test::fail "no additionalContext extracted from: '${out}'"
fi

# additionalContext contains "Active mode: delivery".
claude_modes_test::it "first prompt: additionalContext contains 'Active mode: delivery'"
claude_modes_test::assert_contains "$sm" "Active mode: delivery"

# additionalContext contains the philosophy prose.
claude_modes_test::it "first prompt: additionalContext contains delivery philosophy"
claude_modes_test::assert_contains "$sm" "Ship the thing"

# additionalContext contains constraints.
claude_modes_test::it "first prompt: additionalContext contains constraints bullet"
claude_modes_test::assert_contains "$sm" "Do not refactor adjacent code."

# Injected marker file exists for session.
claude_modes_test::it "first prompt: .injected marker created for sess-1"
claude_modes_test::assert_file_exists "${HOME}/.claude/modes/.sessions/sess-1.injected"

# ──────────────────────────────────────────────────────────────────────────
# Scenario 2: Subsequent prompt, same session — header suppressed.
# ──────────────────────────────────────────────────────────────────────────
claude_modes_test::it "second prompt: header is suppressed (marker debounce)"
event=$(__make_event "session_id=sess-1" "prompt=another thing")
out2=$(__run_hook "$event")
sm2=$(__extract_additional_context "$out2")
case "$sm2" in
  *"Active mode:"*)
    claude_modes_test::fail "expected NO 'Active mode:' header on 2nd prompt, got: '${sm2}'"
    ;;
  *)
    claude_modes_test::pass
    ;;
esac

claude_modes_test::it "second prompt: prose body still present"
claude_modes_test::assert_contains "$sm2" "Ship the thing"

# ──────────────────────────────────────────────────────────────────────────
# Scenario 3: No active mode anywhere → exit 0 with empty stdout.
# ──────────────────────────────────────────────────────────────────────────
claude_modes_test::it "no active mode: empty stdout, exit 0"
rm -f "${HOME}/.claude/modes/.last-active-mode"
rm -rf "${HOME}/.claude/modes/.sessions"
event=$(__make_event "session_id=sess-none" "prompt=hello")
out3=$(__run_hook "$event")
rc3=$?
if [ "$rc3" = "0" ] && [ -z "$out3" ]; then
  claude_modes_test::pass
else
  claude_modes_test::fail "expected rc=0 + empty stdout; got rc=${rc3}, stdout='${out3}'"
fi

# ──────────────────────────────────────────────────────────────────────────
# Scenario 4: PROSE_INJECTION_DISABLED=1 → exit 0 immediately, no read.
# ──────────────────────────────────────────────────────────────────────────
claude_modes_test::it "PROSE_INJECTION_DISABLED=1: exit 0, no output"
# Re-seed the delivery mode so we can prove the disable flag short-circuits
# BEFORE the YAML is read (no marker file should be created).
__seed_delivery_mode
rm -rf "${HOME}/.claude/modes/.sessions"
event=$(__make_event "session_id=sess-disable" "prompt=hello")
# Env var must apply to bash, not just to printf. Use a subshell.
out4=$(printf '%s' "$event" | PROSE_INJECTION_DISABLED=1 bash "$HOOK")
rc4=$?
if [ "$rc4" = "0" ] && [ -z "$out4" ]; then
  claude_modes_test::pass
else
  claude_modes_test::fail "expected rc=0 + empty stdout; got rc=${rc4}, stdout='${out4}'"
fi

claude_modes_test::it "PROSE_INJECTION_DISABLED=1: no .injected marker created"
claude_modes_test::assert_file_absent "${HOME}/.claude/modes/.sessions/sess-disable.injected"

# ──────────────────────────────────────────────────────────────────────────
# Scenario 5: Empty session_id → fall back to ppid-<pid> marker.
# ──────────────────────────────────────────────────────────────────────────
claude_modes_test::it "empty session_id: still emits prose"
__seed_delivery_mode
rm -rf "${HOME}/.claude/modes/.sessions"
event=$(__make_event "session_id=" "prompt=x")
out5=$(__run_hook "$event")
sm5=$(__extract_additional_context "$out5")
claude_modes_test::assert_contains "$sm5" "Ship the thing"

claude_modes_test::it "empty session_id: creates a ppid-* marker"
# Expect exactly one ppid-*.injected file in the sessions dir.
count=$(find "${HOME}/.claude/modes/.sessions" -maxdepth 1 -name 'ppid-*.injected' 2>/dev/null | wc -l | tr -d '[:space:]')
claude_modes_test::assert_eq "1" "$count"

# ──────────────────────────────────────────────────────────────────────────
# Scenario 6: Pending divergence-toast marker is included AND consumed.
# ──────────────────────────────────────────────────────────────────────────
claude_modes_test::it "divergence-toast marker is included in additionalContext"
__seed_delivery_mode
rm -rf "${HOME}/.claude/modes/.sessions"
mkdir -m 0700 -p "${HOME}/.claude/modes/.sessions"
printf 'diverge text' > "${HOME}/.claude/modes/.sessions/sess-2.divergence-toast"
event=$(__make_event "session_id=sess-2" "prompt=hi")
out6=$(__run_hook "$event")
sm6=$(__extract_additional_context "$out6")
claude_modes_test::assert_contains "$sm6" "diverge text"

claude_modes_test::it "divergence-toast marker is removed after consumption"
claude_modes_test::assert_file_absent "${HOME}/.claude/modes/.sessions/sess-2.divergence-toast"

# ──────────────────────────────────────────────────────────────────────────
# Scenario 7: Malformed mode YAML — hook still exits 0 (rel-001).
# ──────────────────────────────────────────────────────────────────────────
claude_modes_test::it "malformed mode YAML: hook exits 0, no crash"
# Seed an active-mode pointer to a YAML with an unterminated quote.
printf 'broken' > "${HOME}/.claude/modes/.last-active-mode"
printf 'schema_version: 2\nname: "unterminated\n' > "${HOME}/.claude/modes/broken.yaml"
rm -rf "${HOME}/.claude/modes/.sessions"
event=$(__make_event "session_id=sess-broken" "prompt=hi")
out7=$(__run_hook "$event" 2>/dev/null)
rc7=$?
claude_modes_test::assert_eq "0" "$rc7"

# Stdout may be empty (mode YAML failed to validate, no markers pending),
# but must not be a partial / invalid JSON object.
claude_modes_test::it "malformed mode YAML: stdout is empty or valid JSON"
if [ -z "$out7" ]; then
  claude_modes_test::pass
else
  # If non-empty, it MUST parse as JSON.
  if "$CLAUDE_MODES_PYTHON3" -c 'import sys, json; json.loads(sys.argv[1])' "$out7" >/dev/null 2>&1; then
    claude_modes_test::pass
  else
    claude_modes_test::fail "non-empty stdout that is not valid JSON: '${out7}'"
  fi
fi

# ──────────────────────────────────────────────────────────────────────────
# Teardown + summary.

claude_modes_test::teardown

# Summary in the format tests/run.sh expects.
echo ""
printf '%s: %d passed, %d failed\n' \
  "$(basename "${BASH_SOURCE[0]}")" \
  "${CLAUDE_MODES_TEST_PASS_COUNT}" \
  "${CLAUDE_MODES_TEST_FAIL_COUNT}"

if [ "${CLAUDE_MODES_TEST_FAIL_COUNT}" -gt 0 ]; then
  exit 1
fi
exit 0
