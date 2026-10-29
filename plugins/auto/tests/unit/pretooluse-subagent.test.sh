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

WORK="$(mktemp -d -t auto-pretooluse-subagent.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_MACHINE="studio"
unset HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_BIN_PATH CLAUDE_AUTO_REPO 2>/dev/null || true
"$PY" - "$AUTO_ROOT" <<'EOF' >/dev/null
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
load_lib_module("programme_home").create_programme(["w2"], "sess-pm")
EOF

decision() {
  local agent="$1" cmd="$2" sid="${3:-sess-pm}"
  "$PY" - "$agent" "$cmd" "$sid" <<'EOF' | CLAUDE_PLUGIN_ROOT="$AUTO_ROOT" bash "$HOOK" | "$PY" -c 'import json,sys; t=sys.stdin.read().strip(); print(json.loads(t)["hookSpecificOutput"]["permissionDecision"] if t else "allow")'
import json, sys
agent, cmd, sid = sys.argv[1:4]
d = {"session_id": sid, "hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {"command": cmd}}
if agent:
    d["agent_id"] = agent
    d["agent_type"] = "auto:programme-status-reader"
print(json.dumps(d))
EOF
}

HOME_DIR="$("$PY" - "$AUTO_ROOT" <<'EOF'
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
print(load_lib_module("programme_home").driven_runs("sess-pm")[0]["home"])
EOF
)"

tool_decision() {
  local agent="$1" tool="$2" path="$3" sid="${4:-sess-pm}" kind="${5:-auto:programme-status-reader}"
  "$PY" - "$agent" "$tool" "$path" "$sid" "$kind" <<'EOF' | CLAUDE_PLUGIN_ROOT="$AUTO_ROOT" bash "$HOOK" | "$PY" -c 'import json,sys; t=sys.stdin.read().strip(); print(json.loads(t)["hookSpecificOutput"]["permissionDecision"] if t else "allow")'
import json, sys
agent, tool, path, sid, kind = sys.argv[1:6]
key = "notebook_path" if tool == "NotebookEdit" else "file_path"
d = {"session_id": sid, "hook_event_name": "PreToolUse", "tool_name": tool, "tool_input": {key: path, "content": "x"}}
if agent:
    d["agent_id"] = agent
    d["agent_type"] = kind
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
it "a write verb hidden after a read in a compound command is denied"
check deny "$(decision a1 "$P status --json --run prog-1 && $P validate --run prog-1")"
it "programme.py called directly with a write verb is denied"
check deny "$(decision a1 "/usr/bin/python3 /x/lib/programme.py tracker-synced --item i --state merged")"
it "a write verb wrapped in bash -c is denied"
check deny "$(decision a1 "bash -c '$P drop-item herdr:w2/p7G --reason x'")"
it "inline python that imports the programme CLI is denied"
check deny "$(decision a1 "python3 -c 'import sys; sys.path.insert(0, \"/x/lib\"); import programme; programme._cli([\"ask-shown\", \"i\"])'")"
it "a heredoc python script that loads programme modules is denied"
check deny "$(decision a1 "python3 - <<EOF
from _bootstrap import load_lib_module
load_lib_module('programme_asks')
EOF")"
it "eval of a programme write is denied"
check deny "$(decision a1 "eval \"$P hand-item x\"")"
it "eval of a gh write is denied"
check deny "$(decision a1 "eval 'gh api -X PATCH repos/o/r/issues/1 -f state=closed'")"
it "a verb after a flag is denied, so a reordered write cannot pass as a read"
check deny "$(decision a1 "$P --run prog-1 answer-handed x")"

it "a sub-agent running gh pr merge is denied"
check deny "$(decision a1 "gh pr merge 12 --squash --repo o/r")"
it "gh pr merge after a global --repo flag is denied"
check deny "$(decision a1 "gh --repo o/r pr merge 5")"
it "a quoted gh pr merge is denied"
check deny "$(decision a1 "\"gh\" pr merge 5")"
it "gh api PUT to a merge endpoint is denied"
check deny "$(decision a1 "gh api -X PUT repos/o/r/pulls/5/merge")"
it "gh pr comment is denied"
check deny "$(decision a1 "gh pr comment 5 --body hi")"
it "gh api with a body and no GET is denied"
check deny "$(decision a1 "gh api repos/o/r/issues/5/comments -f body=hi")"

it "a sub-agent reading status is allowed"
check allow "$(decision a1 "$P status --json --run prog-1")"
it "a sub-agent reading the inbox is allowed"
check allow "$(decision a1 "$P inbox --run prog-1")"
it "a sub-agent reading merge readiness without a pin is allowed"
check allow "$(decision a1 "$P check-mergeable o/r#1 --run prog-1")"
it "a sub-agent reading the rules in force is allowed"
check allow "$(decision a1 "$P rules --run prog-1")"
it "a sub-agent reading the rules with no run flag is allowed"
check allow "$(decision a1 "$P rules")"
it "a sub-agent acknowledging the rules is denied"
check deny "$(decision a1 "$P rules --ack --run prog-1")"
it "an acknowledgement after --run is denied"
check deny "$(decision a1 "$P rules --run prog-1 --ack")"
it "an acknowledgement with a context digest is denied"
check deny "$(decision a1 "$P rules --ack --context abc")"
it "rules plus any extra flag is denied, so only the plain read passes"
check deny "$(decision a1 "$P rules --run prog-1 --anything")"
it "a write verb hidden after the rules read is denied"
check deny "$(decision a1 "$P rules --run prog-1 && $P beat --run prog-1")"
it "an echo redirect into a programme path is denied"
check deny "$(decision a1 "echo DIGEST-DONE >> /x/programmes/prog-1/sweep-digest.md")"
it "the journal tail is allowed"
check allow "$(decision a1 "tail -n 200 /x/programmes/prog-1/journal.jsonl")"
it "cat redirected into the journal is denied"
check deny "$(decision a1 "cat > /x/programmes/prog-1/journal.jsonl <<'EOF'
{\"kind\": \"working_now\"}
EOF")"
it "cat appending to the claims file is denied"
check deny "$(decision a1 "cat >> /x/programmes/prog-1/claims.jsonl <<'EOF'
x
EOF")"
it "cat writing the digest through Bash is denied, the digest goes through the Write tool"
check deny "$(decision a1 "cat > /x/programmes/prog-1/sweep-digest.md <<'EOF'
x
EOF")"
it "an unspaced redirect into a programme file is denied"
check deny "$(decision a1 "grep x /x/lib/programme.py>/x/programmes/prog-1/claims.jsonl")"
it "an unspaced append is denied"
check deny "$(decision a1 "cat /x/lib/programme.py>>/x/programmes/prog-1/journal.jsonl")"
it "grep redirected to /dev/null is allowed"
check allow "$(decision a1 "grep -n x /x/programmes/prog-1/journal.jsonl > /dev/null")"
it "stderr sent to /dev/null is allowed"
check allow "$(decision a1 "grep -n x /x/programmes/prog-1/journal.jsonl 2>/dev/null")"
it "a write verb on the line after a viewer is denied, a newline starts a new command"
check deny "$(decision a1 "cat /x/lib/programme.py
$P beat --run prog-1")"
it "gh pr merge on the line after ls is denied"
check deny "$(decision a1 "ls
gh pr merge 1")"
it "text that looks like a heredoc opener does not hide the next line"
check deny "$(decision a1 "echo \"<<'EOF'\"
$P beat --run prog-1
EOF")"
it "a comment that looks like a heredoc opener does not hide the next line"
check deny "$(decision a1 "echo hi # <<'EOF'
$P beat --run prog-1
EOF")"
it "a here-string does not hide the next line"
check deny "$(decision a1 "cat <<<'EOF'
$P beat --run prog-1")"
it "process substitution running a write verb is denied"
check deny "$(decision a1 "cat <($P beat --run prog-1)")"
it "an environment prefix on a viewer naming programme code is denied"
check deny "$(decision a1 "LESSOPEN='|programme.sh merge 1' less /x/lib/programme.py")"
it "git grep -O, which runs a pager command, is denied"
check deny "$(decision a1 "git grep -O'programme.sh merge 1' x")"
it "rg --pre, which runs a command, is denied"
check deny "$(decision a1 "rg --pre sh x /x/programmes/prog-1/journal.jsonl")"
it "git log --output writes a file and is denied"
check deny "$(decision a1 "git log --output=/x/programmes/prog-1/journal.jsonl -- lib/programme.py")"
it "a command substitution in a read verb's argument is denied"
check deny "$(decision a1 "$P rules --run \$(rm\${IFS}/x/programmes/prog-1/journal.jsonl)")"
it "a command substitution in a status argument is denied"
check deny "$(decision a1 "$P status --json --run \$(rm\${IFS}/tmp/q)")"
it "backticks in a read verb's argument are denied"
check deny "$(decision a1 "$P status --json --run \`rm /tmp/q\`")"
it "a variable expansion in a read verb's argument is denied"
check deny "$(decision a1 "$P status --json --run prog-1\${IFS}x")"
it "the plugin root variable in the programme.sh path is allowed"
check allow "$(decision a1 'bash "${CLAUDE_PLUGIN_ROOT}/lib/programme.sh" status --json --run prog-1')"
it "rules with a flag as the run value is denied, not left to the parser"
check deny "$(decision a1 "$P rules --run --ack")"
it "the packager's journal reads are allowed"
check allow "$(decision a1 "wc -l /x/programmes/prog-1/journal.jsonl")"
check allow "$(decision a1 "grep -n '\"kind\": *\"working_now\"' /x/programmes/prog-1/journal.jsonl | tail -n 1")"
check allow "$(decision a1 "tail -n +12 /x/programmes/prog-1/journal.jsonl | head -n 301")"
it "a read verb redirected into a programme file is denied"
check deny "$(decision a1 "$P status --json --run prog-1 >/x/programmes/prog-1/state.json")"
it "a read verb with its stderr appended to a file is denied"
check deny "$(decision a1 "$P status --json --run prog-1 2>>/x/programmes/prog-1/journal.jsonl")"
it "a read verb redirected to /dev/null is allowed"
check allow "$(decision a1 "$P status --json --run prog-1 > /dev/null")"
it "a backslash-newline inside a word does not hide programme.sh"
check deny "$(decision a1 'bash "/x/plugins/auto/lib/pro\
gramme.sh" beat --run prog-1')"
it "a read verb wrapped in bash -c is allowed"
check allow "$(decision a1 "bash -c '$P status --json --run prog-1'")"
it "gh pr view and a GET gh api are allowed"
check allow "$(decision a1 "gh pr view 12 --json state && gh api repos/o/r/pulls/5")"
it "cat, grep and git diff of programme source are allowed"
check allow "$(decision a1 "cat lib/programme.py; grep -n def lib/programme.py; git diff -- lib/programme.py")"
it "an unrelated command is allowed"
check allow "$(decision a1 "ls -la && echo done")"

it "the PM itself (no agent_id) running answer-handed is allowed"
check allow "$(decision "" "$P answer-handed herdr:w2/p7G --choice ship --prompt p1")"
it "a sub-agent of a session that drives no programme is not this hook's business"
check allow "$(decision a1 "python3 -c 'import programme; programme._cli([\"hand-item\"])'" sess-other)"
it "a sub-agent of a session that drives no programme may run auto's own tests"
check allow "$(decision a1 "bash tests/unit/programme-items.test.sh" sess-other)"
it "a sub-agent command that cannot be parsed but names programme code is denied"
check deny "$(decision a1 "$P status \"unterminated")"

it "a sub-agent writing the digest file in its programme home is allowed"
check allow "$(tool_decision a1 Write "${HOME_DIR}/sweep-digest.md")"
it "a sub-agent writing the journal is denied"
check deny "$(tool_decision a1 Write "${HOME_DIR}/journal.jsonl")"
it "a sub-agent writing the claims file is denied"
check deny "$(tool_decision a1 Write "${HOME_DIR}/claims.jsonl")"
it "a name that only starts like the digest is denied"
check deny "$(tool_decision a1 Write "${HOME_DIR}/sweep-digest.md.bak")"
it "a path that climbs back out of the home folder is judged by where it lands"
check deny "$(tool_decision a1 Write "${HOME_DIR}/sub/../journal.jsonl")"
it "the digest name resolving to another programme's home is denied"
check deny "$(tool_decision a1 Write "${HOME_DIR}/../prog-other/sweep-digest.md")"
ln -s "${HOME_DIR}/journal.jsonl" "${HOME_DIR}/sweep-digest.md"
it "a digest name that is a symlink to the journal is denied"
check deny "$(tool_decision a1 Write "${HOME_DIR}/sweep-digest.md")"
rm -f "${HOME_DIR}/sweep-digest.md"
it "Edit of the journal by a sub-agent is denied"
check deny "$(tool_decision a1 Edit "${HOME_DIR}/journal.jsonl")"
it "NotebookEdit inside the home folder is denied"
check deny "$(tool_decision a1 NotebookEdit "${HOME_DIR}/n.ipynb")"
it "a sub-agent writing outside any programme home is not this hook's business"
check allow "$(tool_decision a1 Write "${WORK}/scratch.txt")"
it "the PM itself (no agent_id) writing the journal path is not this hook's business"
check allow "$(tool_decision "" Write "${HOME_DIR}/journal.jsonl")"
it "a sub-agent of a session that drives no programme is not this hook's business"
check allow "$(tool_decision a1 Write "${HOME_DIR}/journal.jsonl" sess-other)"

it "a different-case spelling of the programmes folder is the same folder on macOS and is denied"
UPPER_HOME="$(printf '%s' "${HOME_DIR}" | sed 's#/programmes/#/PROGRAMMES/#')"
check deny "$(tool_decision a1 Write "${UPPER_HOME}/journal.jsonl")"

PACKER=auto:programme-sweep-packager
it "the packager writing its digest is allowed"
check allow "$(tool_decision a1 Write "${HOME_DIR}/sweep-digest.md" sess-pm "$PACKER")"
it "the packager writing a file outside any programme home is denied, its only write is the digest"
check deny "$(tool_decision a1 Write "${WORK}/scratch.txt" sess-pm "$PACKER")"
it "the packager writing the journal is denied"
check deny "$(tool_decision a1 Write "${HOME_DIR}/journal.jsonl" sess-pm "$PACKER")"
it "the packager editing the digest with Edit is denied unless it is the digest path"
check deny "$(tool_decision a1 Edit "${WORK}/scratch.txt" sess-pm "$PACKER")"
it "a packager-typed agent of a session that drives no programme is not this hook's business"
check allow "$(tool_decision a1 Write "${WORK}/scratch.txt" sess-other "$PACKER")"
it "a plugin-namespaced packager type is still matched by its name"
check deny "$(tool_decision a1 Write "${WORK}/x.txt" sess-pm "programme-sweep-packager")"
it "hooks.json runs the guard for Bash, Write, Edit, MultiEdit and NotebookEdit and not for Read"
check "ok" "$("$PY" - "$AUTO_ROOT" <<'EOF'
import json, re, sys
hooks = json.load(open(sys.argv[1] + "/.claude/hooks/hooks.json"))["hooks"]["PreToolUse"]
entry = next(e for e in hooks if any("on-pretooluse-subagent.sh" in h["command"] for h in e["hooks"]))
hit = lambda tool: re.fullmatch(entry["matcher"], tool) is not None
print("ok" if all(hit(t) for t in ("Bash", "Write", "Edit", "MultiEdit", "NotebookEdit")) and not hit("Read") else "bad matcher: " + entry["matcher"])
EOF
)"

echo "pretooluse-subagent.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
