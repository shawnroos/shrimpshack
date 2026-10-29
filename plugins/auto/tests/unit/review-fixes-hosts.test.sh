#!/usr/bin/env bash
# auto unit test: the code-review fixes for the off-herdr hosts. Ghostty send-guard bypasses, the start and
# takeover pane gates, RefusedHost in the sweep/launch/send paths, and half-sent prompts.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
PROG="${AUTO_ROOT}/lib/programme.py"
HOOKS="${AUTO_ROOT}/.claude/hooks"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
check() { if [ "$1" = "$2" ]; then pass; else fail "expected [$1] got [$2]"; fi; }
has() { case "$2" in *"$1"*) pass ;; *) fail "expected to find [$1] in [$2]" ;; esac; }
lacks() { case "$2" in *"$1"*) fail "did not expect [$1] in [$2]" ;; *) pass ;; esac; }

echo "review-fixes-hosts.test.sh"

WORK="$(mktemp -d -t auto-review-fixes.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

for v in $(env | grep -oE '^(HERDR|REX|GHOSTTY|AUTO_TEST)_[A-Z_]*'); do unset "$v"; done
unset CMUX_WORKSPACE_ID TERM_PROGRAM CLAUDE_CODE_SESSION_ID CLAUDE_CODE_ENTRYPOINT CLAUDE_AUTO_REPO 2>/dev/null || true
export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_TEST_HARNESS=1
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_AUTO_SOURCE_TIMEOUT=2
: > "$CLAUDE_AUTO_SECRETS_FILE"
NOREPO="${WORK}/norepo"
mkdir -p "$NOREPO"

HEAD_PY='import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
ph = load_lib_module("programme_home")
pj = load_lib_module("programme_journal")
sr = load_lib_module("session_registry")
rc = load_lib_module("run_record_core")
args = sys.argv[2:]
'
py() { "$PY" - "$AUTO_ROOT" "$@" 2>&1; }

row() {
  AUTO_TEST_HOST=stub py "$@" <<PYEOF
$HEAD_PY
host, server, workspace, sid, pane, term = args
entry = {"at": rc.now_iso(), "session_id": sid, "pane_id": pane, "terminal_id": term, "server": server,
         "workspace": workspace, "interactive": True, "resolved": host}
if host != "herdr":
    entry["host"] = host
sr._append(sr.registry_path(server, workspace, host), entry)
PYEOF
}

programme() {
  AUTO_ROOT_UNUSED=1 AUTO_TEST_HOST=stub py "$@" <<PYEOF
$HEAD_PY
host, server, workspace, sid = args
print(ph.create_programme([(server, workspace, host)], sid)["run"])
PYEOF
}

# ---------------------------------------------------------------- Ghostty send-guard (findings 1 and 6)
T1=3F2A9C10-7B6E-4D55-8A21-0C9E1B7D4A01
TTY1=/dev/ttys016
row ghostty srv g1 pm-ghostty "$T1" "$TTY1"
RUN_GHOSTTY="$(programme ghostty srv g1 pm-ghostty)"
row ghostty srv g1 sess-worker 3F2A9C10-7B6E-4D55-8A21-0C9E1B7D4A02 /dev/ttys017

hook() {
  local payload
  payload="$("$PY" -c 'import json,sys; print(json.dumps({"session_id": sys.argv[1], "tool_name": "Bash", "tool_input": {"command": sys.argv[2]}}))' "$1" "$2")"
  ( cd "$NOREPO" && env "${@:3}" bash "${HOOKS}/on-pretooluse-action.sh" <<< "$payload" )
}
verdict() { case "$1" in *'"deny"'*) echo deny ;; *) echo allow ;; esac; }
NL=$'\n'
JXA="osascript -l JavaScript -e 'const G=Application(\"Ghostty\"); G.inputText(\"hi\",{to:G.windows[0].tabs[0].terminals[0]})'"
SPACED="osascript -e 'tell application \"Ghostty\" to input   text \"x\" to current terminal'"
SYSEV="osascript -e 'tell application \"System Events\" to keystroke \"x\"'"
SENDKEY="osascript -e 'tell application \"Ghostty\" to send key \"enter\" to (terminal of tab 1 of window 1)'"
UNLISTED="osascript -e 'tell application \"Ghostty\" to input text \"x\" to current terminal'"
HEREDOC="osascript <<'EOF'${NL}tell application \"Ghostty\" to input text \"x\" to focused terminal of selected tab of front window${NL}EOF"
PIPE="echo 'tell application \"Ghostty\" to input text \"x\" to terminal 1' | osascript"
JXA_PIPE="echo 'Application(\"Ghostty\").inputText(\"x\")' | osascript -l JavaScript"

echo "review-fixes: Ghostty sends that name no id are denied (finding 1)"
for name in JXA SPACED SYSEV SENDKEY UNLISTED; do
  it "$name is denied for another session"
  check deny "$(verdict "$(hook sess-worker "${!name}")")"
done
it "the JXA form is denied inside a heredoc to bash as well"
check deny "$(verdict "$(hook sess-worker "bash <<EOF${NL}$JXA${NL}EOF")")"

echo "review-fixes: Ghostty scripts on stdin are denied (finding 6)"
it "heredoc into osascript"
check deny "$(verdict "$(hook sess-worker "$HEREDOC")")"
it "heredoc into osascript inside bash -c"
check deny "$(verdict "$(hook sess-worker "bash <<EOF${NL}$HEREDOC${NL}EOF")")"
it "echo piped into osascript"
check deny "$(verdict "$(hook sess-worker "$PIPE")")"
it "echo piped into osascript -l JavaScript"
check deny "$(verdict "$(hook sess-worker "$JXA_PIPE")")"

echo "review-fixes: harmless osascript stays allowed"
it "a notification through -e"
check allow "$(verdict "$(hook sess-worker "osascript -e 'display notification \"hi\"'")")"
it "a notification piped in"
check allow "$(verdict "$(hook sess-worker "echo 'display notification \"hi\"' | osascript")")"
it "a heredoc notification"
check allow "$(verdict "$(hook sess-worker "osascript <<'EOF'${NL}display notification \"hi\"${NL}EOF")")"
it "a send to one other literal terminal id"
check allow "$(verdict "$(hook sess-worker "osascript -e 'tell application \"Ghostty\" to input text \"x\" to terminal id \"OTHER-ID\"'")")"
it "auto's own list script, which the PM may run"
LISTCMD="$("$PY" -c 'import sys,os; sys.path.insert(0, os.path.join(sys.argv[1], "lib")); from _bootstrap import load_lib_module; print("osascript -e " + __import__("shlex").quote(load_lib_module("host_ghostty").LIST_SCRIPT))' "$AUTO_ROOT")"
check allow "$(verdict "$(hook pm-ghostty "$LISTCMD")")"
it "the list script with a send appended is denied"
check deny "$(verdict "$(hook sess-worker "$LISTCMD -e 'tell application \"Ghostty\" to input text \"x\" to current terminal'")")"

# ---------------------------------------------------------------- start and takeover pane gates (findings 2 and 3)
as_stub() {
  local sid="$1"; shift
  OUT="$(env CLAUDE_CODE_SESSION_ID="$sid" AUTO_TEST_HOST=stub ${STUBVARS[@]+"${STUBVARS[@]}"} "$PY" "$PROG" "$@" 2>&1)"
  CODE=$?
}
driver_panes() {
  py <<PYEOF
$HEAD_PY
print(sorted(d["pane_id"] for d in sr.driver_panes()))
PYEOF
}

echo "review-fixes: a live pane proof is recorded, so the guard covers the PM (finding 2)"
STUBVARS=(AUTO_TEST_STUB_PANE=stub-live AUTO_TEST_STUB_SERVER=srv AUTO_TEST_STUB_WORKSPACE=win-live)
it "row missing, live own_pane succeeds: start works"
as_stub sess-live start
check "0" "$CODE"
it "driver_panes() now returns the PM's pane"
has "stub-live" "$(driver_panes)"
it "the recorded row is the one the host proved"
has "stub-live" "$(py <<PYEOF
$HEAD_PY
print((sr.lookup("sess-live", include_headless=True) or {}).get("pane_id"))
PYEOF
)"
STUBVARS=()

echo "review-fixes: takeover refuses a taker whose pane the host cannot identify (finding 3)"
SEQ="${WORK}/presence-seq"
N=0
CASE_RUN="" CASE_PM="" CASE_TAKER=""
fresh_case() {
  N=$((N + 1))
  CASE_PM="pm-r$N"; CASE_TAKER="taker-r$N"
  local ws="win-r$N"
  row stub srv "$ws" "$CASE_PM" "stub-pm-r$N" "stub-pm-r$N-term"
  CASE_RUN="$(programme stub srv "$ws" "$CASE_PM")"
}
takeover_as() {
  OUT="$(env CLAUDE_CODE_SESSION_ID="$CASE_TAKER" AUTO_TEST_HOST=stub AUTO_TEST_STUB_PRESENCE_SEQ="$SEQ" "$PY" "$PROG" takeover "$@" 2>&1)"
  CODE=$?
}
typed() {
  ( cd "$NOREPO" && AUTO_TEST_HOST=stub "$PY" "${AUTO_ROOT}/tests/fixtures/programme_prompts.py" "$AUTO_ROOT" "$CASE_TAKER" "$1" >/dev/null 2>&1 )
}
driver() {
  py "$CASE_RUN" <<PYEOF
$HEAD_PY
print(ph._read_record(args[0]).get("driving_session_id"))
PYEOF
}
pick() {
  ( cd "$NOREPO" && AUTO_TEST_HOST=stub "$PY" - "$AUTO_ROOT" "$WORK" "$CASE_TAKER" "$1" <<'PYEOF'
import json, os, pathlib, re, subprocess, sys, uuid
root, work, sid, answer = sys.argv[1:5]
rows = [json.loads(line) for line in (pathlib.Path(root) / "tests/fixtures/askuser_transcript.jsonl").read_text().splitlines()]
asked, result = rows[0], rows[1]
question = "Who should drive the programme?"
tool_use_id = "toolu_" + uuid.uuid4().hex[:12]
tool_input = {"questions": [{"question": question, "header": "PM", "multiSelect": False,
                             "options": [{"label": answer, "description": "Move the lease here."},
                                         {"label": "Keep the current PM", "description": "Change nothing."}]}]}
asked["sessionId"] = sid
asked["message"]["content"][0].update(id=tool_use_id, input=tool_input)
response = {"questions": [{"question": question}], "answers": {question: answer}, "annotations": {}}
result.update(sessionId=sid, toolUseResult=response)
result["message"]["content"][0]["tool_use_id"] = tool_use_id
path = pathlib.Path(work) / "picks" / uuid.uuid4().hex / (sid + ".jsonl")
path.parent.mkdir(parents=True)
path.write_text(json.dumps(asked) + "\n")
payload = {"session_id": sid, "transcript_path": str(path), "cwd": os.getcwd(), "hook_event_name": "PostToolUse",
           "tool_name": "AskUserQuestion", "tool_use_id": tool_use_id, "tool_input": tool_input,
           "tool_response": response}
out = subprocess.run(["bash", os.path.join(root, ".claude/hooks/on-posttooluse-askuser.sh")],
                     input=json.dumps(payload), text=True, capture_output=True)
with path.open("a") as stream:
    stream.write(json.dumps(result) + "\n")
context = json.loads(out.stdout)["hookSpecificOutput"]["additionalContext"] if out.stdout else ""
found = re.search(r"(\{.*\})\n</auto-data>", context)
print(json.loads(found.group(1))["prompt_id"] if found else "none")
PYEOF
  )
}

fresh_case
typed '/auto:programme-takeover'
printf 'gone\ngone\n' > "$SEQ"
it "typed takeover from a stub session with no pane and no row is refused"
takeover_as --run "$CASE_RUN"
check "1 $CASE_PM" "$CODE $(driver)"
it "the refusal names the missing pane"
has "cannot identify this session's stub terminal pane" "$OUT"

fresh_case
typed '/auto:programme-takeover'
PROMPT="$(pick "Approve takeover --replace $CASE_PM")"
printf 'present\npresent\npresent\n' > "$SEQ"
it "the exact-label pick from a taker with no pane is refused too"
takeover_as --run "$CASE_RUN" --prompt "$PROMPT"
check "1 $CASE_PM" "$CODE $(driver)"
it "the pick refusal names the missing pane"
has "cannot identify this session's stub terminal pane" "$OUT"

# ---------------------------------------------------------------- RefusedHost in the source paths (finding 4)
echo "review-fixes: a refused host does not crash the sweep, launch or send paths (finding 4)"
BOTH=(HERDR_PANE_ID=w1:2 REX_SESSION=s)
refused_py() {
  env "${BOTH[@]}" "$PY" - "$AUTO_ROOT" <<'PYEOF' 2>&1
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
src = load_lib_module("programme_sources")
th = load_lib_module("terminal_host")
print("host", type(th.current()).__name__, th.current().installed())
print("state", src._herdr_state(None))
out = src.launch_worker("/bin/true", [])
print("launch", out["ok"], out["outcome"], bool(out["reason"]))


class Host:
    class ProgrammeError(Exception):
        pass

    def _emit(self, payload):
        print("emit", payload["ok"])


settled = {}
src._settled = lambda host, run, home, op, kind, payload, outcome, assign=None: settled.update(outcome=outcome, payload=payload) or {"state": "x"}
src.check_target = lambda owner, record: {"ok": True, "pane": "p1", "reported": None, "reason": None,
                                          "session_unknown": False, "owner_source": "t"}
src.programme_context.unsafe_reason = lambda *a, **k: None
src.programme_recovery.admit = lambda *a, **k: {"replayed": False, "attempt": 1}
src.programme_recovery.recheck = lambda *a, **k: None
src.programme_recovery.pause = lambda *a, **k: None
src.programme_recovery.canonical_sha = lambda t: "d"
src.programme_recovery.owner_epoch = lambda p: 0
code = src.send_to_item(Host(), {}, ("r", "h", {}, "s"), {"items": {"k": {"owner": {"session_id": "w"}}}}, "k", "hello")
print("send", code, settled["outcome"], settled["payload"]["sent"], bool(settled["payload"]["error"]))
PYEOF
}
OUT="$(refused_py)"
it "RefusedHost answers installed() False"
has "host RefusedHost False" "$OUT"
it "a refused host reads as unsupported, not an AttributeError"
has "state unsupported" "$OUT"
it "launch_worker reports not_executed with a reason"
has "launch False not_executed True" "$OUT"
it "send_to_item records the refused send as not sent and not executed"
has "send 1 not_executed False True" "$OUT"
it "no traceback"
lacks "Traceback" "$OUT"

# ---------------------------------------------------------------- half-sent prompts (finding 7)
echo "review-fixes: text typed but Enter failed is uncertain, not a plain failure (finding 7)"
FAKES="${WORK}/fakes"
mkdir -p "$FAKES"
cat > "${FAKES}/rex" <<'EOF'
#!/bin/bash
[ "$1" = "send-key" ] && exit 4
exit 0
EOF
cat > "${FAKES}/osascript" <<'EOF'
#!/bin/bash
echo "partial=text-typed"
exit 0
EOF
chmod +x "${FAKES}/rex" "${FAKES}/osascript"
half() {
  env PATH="${FAKES}:${PATH}" "$PY" - "$AUTO_ROOT" "$1" <<'PYEOF' 2>&1
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
src = load_lib_module("programme_sources")
th = load_lib_module("terminal_host")
r = th.host_named(sys.argv[2]).send_prompt("blk-1", "go")
sent = r.value
ok = r.ok and sent["ran"] and sent["code"] == 0
print(r.status, "typed", sent.get("text_typed"), src._send_outcome(sent, ok))
PYEOF
}
it "rex: send succeeds, send-key exits non-zero: outcome is uncertain"
has "refuse typed True uncertain" "$(half rex)"
it "ghostty: input text lands, send key fails: outcome is uncertain"
has "refuse typed True uncertain" "$(half ghostty)"

echo ""
echo "review-fixes-hosts.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
