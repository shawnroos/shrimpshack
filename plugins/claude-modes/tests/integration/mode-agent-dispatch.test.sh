#!/usr/bin/env bash
# U7 STRUCTURAL test: agents/mode.md contract elements.
#
# HONEST FRAMING: a bash test cannot dispatch a plugin agent via the Task tool
# (that's a model-only action) and cannot observe how the harness routes
# subagent_type. So this test does NOT verify real dispatch. It verifies the
# agent FILE carries the contract elements its system prompt must contain — the
# things that, if missing, would make the agent behave wrong when the model DOES
# dispatch it. Real dispatch + @mode routing are covered by the post-ship spikes
# (docs/spikes/2026-05-23-phase0-spike-results.md, Spikes B & C — user verifies
# in a fresh session). The backing lib chain is covered by
# mode-edit-end-to-end.test.sh.
#
# Output format expected by tests/run.sh:
#   <basename>: N passed, M failed

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/tests/helpers/test-helpers.sh"

claude_modes_test::setup

AGENT="${PLUGIN_ROOT}/agents/mode.md"
PY="$CLAUDE_MODES_PYTHON3"

# ── File exists at the plugin-root location (Phase 0 Spike A) ────────────────
claude_modes_test::it "agent file exists at agents/mode.md (plugin root, not .claude/agents/)"
claude_modes_test::assert_file_exists "$AGENT"
claude_modes_test::it ".claude/agents/mode.md does NOT exist (wrong layout)"
claude_modes_test::assert_file_absent "${PLUGIN_ROOT}/.claude/agents/mode.md"

# ── Frontmatter parses; name == mode; description present ────────────────────
claude_modes_test::it "frontmatter: name is 'mode'"
name=$("$PY" - "$AGENT" <<'PYEOF'
import sys, re
text = open(sys.argv[1]).read()
m = re.match(r'^---\n(.*?)\n---\n', text, re.S)
fm = m.group(1) if m else ""
import yaml
data = yaml.safe_load(fm) or {}
print(data.get("name", ""))
PYEOF
)
claude_modes_test::assert_eq "mode" "$name"

claude_modes_test::it "frontmatter: description present and non-trivial"
desc=$("$PY" - "$AGENT" <<'PYEOF'
import sys, re, yaml
text = open(sys.argv[1]).read()
m = re.match(r'^---\n(.*?)\n---\n', text, re.S)
data = yaml.safe_load(m.group(1)) if m else {}
print(len((data or {}).get("description", "") or ""))
PYEOF
)
claude_modes_test::assert_true "[ \"$desc\" -gt 60 ]"

# ── Contract elements in the body ───────────────────────────────────────────
body=$(cat "$AGENT")

claude_modes_test::it "body: ToolSearch AskUserQuestion preload block present"
case "$body" in *"select:AskUserQuestion"*) claude_modes_test::pass ;;
  *) claude_modes_test::fail "missing ToolSearch select:AskUserQuestion preload" ;; esac

claude_modes_test::it "body: uses canonical resolver lib/active-mode.sh"
case "$body" in *"lib/active-mode.sh"*) claude_modes_test::pass ;;
  *) claude_modes_test::fail "missing lib/active-mode.sh reference" ;; esac

claude_modes_test::it "body: does NOT instruct reading .last-active-mode directly as the resolver"
# It may MENTION .last-active-mode in the 'never read it directly' warning; assert
# the warning is present (the anti-pattern is named), which is the safe signal.
case "$body" in *"Never read"*".last-active-mode"*|*"never read"*".last-active-mode"*) claude_modes_test::pass ;;
  *) claude_modes_test::fail "missing the .last-active-mode anti-pattern warning" ;; esac

claude_modes_test::it "body: R28 redirect contains the literal phrase 'hooks live in'"
case "$body" in *"hooks live in"*) claude_modes_test::pass ;;
  *) claude_modes_test::fail "missing literal 'hooks live in' (R28 redirect)" ;; esac

claude_modes_test::it "body: mode-suggester redirect names /mode:suggester"
case "$body" in *"/mode:suggester"*) claude_modes_test::pass ;;
  *) claude_modes_test::fail "missing /mode:suggester redirect" ;; esac

claude_modes_test::it "body: pins PRINT-the-redirect (not sub-dispatch mode-suggester)"
case "$body" in *"Never dispatch mode-suggester"*|*"do not dispatch mode-suggester"*|*"not"*"sub-task"*) claude_modes_test::pass ;;
  *) claude_modes_test::fail "missing the no-sub-dispatch anti-pattern for mode-suggester" ;; esac

claude_modes_test::it "body: references the orchestrators (mode-add.sh / mode-drop.sh)"
case "$body" in *"lib/mode-add.sh"*) claude_modes_test::pass ;;
  *) claude_modes_test::fail "missing lib/mode-add.sh orchestrator reference" ;; esac

claude_modes_test::it "body: names the namespaced subagent type claude-modes:mode"
case "$body" in *"claude-modes:mode"*) claude_modes_test::pass ;;
  *) claude_modes_test::fail "missing the namespaced subagent_type claude-modes:mode" ;; esac

claude_modes_test::teardown

printf '%s: %d passed, %d failed\n' \
  "$(basename "$0")" \
  "$CLAUDE_MODES_TEST_PASS_COUNT" \
  "$CLAUDE_MODES_TEST_FAIL_COUNT"
[ "$CLAUDE_MODES_TEST_FAIL_COUNT" -eq 0 ]
