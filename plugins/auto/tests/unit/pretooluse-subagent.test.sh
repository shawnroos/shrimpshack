#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
HOOK="${AUTO_ROOT}/.claude/hooks/on-pretooluse-subagent.sh"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
check() { if [ "$1" = "$2" ]; then pass; else fail "expected [$1] got [$2]"; fi; }

echo "pretooluse-subagent.test.sh"

decision() {
  local agent="$1" cmd="$2"
  "$PY" - "$agent" "$cmd" <<'EOF' | CLAUDE_PLUGIN_ROOT="$AUTO_ROOT" bash "$HOOK" | "$PY" -c 'import json,sys; t=sys.stdin.read().strip(); print(json.loads(t)["hookSpecificOutput"]["permissionDecision"] if t else "allow")'
import json, sys
agent, cmd = sys.argv[1], sys.argv[2]
d = {"session_id": "sess-pm", "hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {"command": cmd}}
if agent:
    d["agent_id"] = agent
    d["agent_type"] = "auto:programme-status-reader"
print(json.dumps(d))
EOF
}

P='bash "/x/plugins/auto/lib/programme.sh"'

it "a sub-agent running answer-handed is denied"
check deny "$(decision a1 "$P answer-handed herdr:w2/p7G --choice ship --prompt p1")"
it "a sub-agent running hand-item is denied"
check deny "$(decision a1 "$P hand-item herdr:w2/p7G --question x")"
it "a sub-agent running mark-read is denied"
check deny "$(decision a1 "$P mark-read 3 --run prog-1")"
it "a sub-agent pinning a merge head is denied"
check deny "$(decision a1 "$P check-mergeable o/r#1 --pin linear:AI-1 --run prog-1")"
it "a sub-agent running gh pr merge is denied"
check deny "$(decision a1 "gh pr merge 12 --squash --repo o/r")"
it "a write verb hidden after a read in a compound command is denied"
check deny "$(decision a1 "$P status --json --run prog-1 && $P validate --run prog-1")"
it "programme.py called directly with a write verb is denied"
check deny "$(decision a1 "/usr/bin/python3 /x/lib/programme.py tracker-synced --item i --state merged")"
it "a sub-agent reading status is allowed"
check allow "$(decision a1 "$P status --json --run prog-1")"
it "a sub-agent reading the inbox is allowed"
check allow "$(decision a1 "$P inbox --run prog-1")"
it "a sub-agent reading merge readiness without a pin is allowed"
check allow "$(decision a1 "$P check-mergeable o/r#1 --run prog-1")"
it "a sub-agent's unrelated command is allowed"
check allow "$(decision a1 "gh pr view 12 --json state")"
it "the PM itself (no agent_id) running answer-handed is allowed"
check allow "$(decision "" "$P answer-handed herdr:w2/p7G --choice ship --prompt p1")"
it "the PM itself running gh pr merge is not this hook's business"
check allow "$(decision "" "gh pr merge 12 --squash")"
it "a sub-agent command that cannot be parsed but names the programme CLI is denied"
check deny "$(decision a1 "$P status \"unterminated")"

echo "pretooluse-subagent.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
