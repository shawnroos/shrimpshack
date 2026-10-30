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
row ghostty srv g1 sess-other-term OTHER-ID /dev/ttys018

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
it "a notification piped in is denied: the script source is stdin"
check deny "$(verdict "$(hook sess-worker "echo 'display notification \"hi\"' | osascript")")"
it "a heredoc notification is denied for the same reason"
check deny "$(verdict "$(hook sess-worker "osascript <<'EOF'${NL}display notification \"hi\"${NL}EOF")")"
it "a send to one other literal terminal id"
check allow "$(verdict "$(hook sess-worker "osascript -e 'tell application \"Ghostty\" to input text \"x\" to terminal id \"OTHER-ID\"'")")"
it "auto's own list script, which the PM may run"
LISTCMD="$("$PY" -c 'import sys,os; sys.path.insert(0, os.path.join(sys.argv[1], "lib")); from _bootstrap import load_lib_module; print("osascript -e " + __import__("shlex").quote(load_lib_module("host_ghostty").LIST_SCRIPT))' "$AUTO_ROOT")"
check allow "$(verdict "$(hook pm-ghostty "$LISTCMD")")"
it "the list script with a send appended is denied"
check deny "$(verdict "$(hook sess-worker "$LISTCMD -e 'tell application \"Ghostty\" to input text \"x\" to current terminal'")")"


echo "review-fixes: round 2, every unlisted osascript is denied for a session that is not the PM"
PMID_A="${T1%-*}-"; PMID_B="${T1##*-}"
CONCAT="osascript -e 'tell application \"Ghostty\" to input text \"x\" to terminal id \"${PMID_A}\" & \"${PMID_B}\"'"
VARIABLE="osascript -e 'set v to \"${PMID_A}\" & \"${PMID_B}\"${NL}tell application \"Ghostty\" to input text \"x\" to terminal id v'"
VAR_PIPE="echo 'tell application \"Ghostty\" to input text \"x\" to terminal id v' | osascript"
PREFIX="osascript -e 'tell application \"Ghostty\" to input text \"x\" to terminal id \"${T1%%-*}\"'"
SMODE="echo 'tell application \"Ghostty\" to input text \"x\" to terminal id \"${T1}\"' | osascript -s o"
SMODE_H="echo 'tell application \"Ghostty\" to input text \"x\" to terminal id \"v\"' | osascript -s h"
JXA_CAT="osascript -l JavaScript -e 'Application(\"Gho\"+\"stty\").focusedTerminal().inputText(\"x\")'"
NAMESPLIT="osascript -e 'tell application (\"Gho\" & \"stty\") to input text \"x\" to selected terminal'"
SELECTED="osascript -e 'tell application \"Ghostty\" to input text \"x\" to selected terminal'"
CONT="osascript -e 'tell application \"Ghostty\" to input ¬${NL}text \"x\" to terminal id \"${PMID_A}\" & \"${PMID_B}\"'"
FILEARG="osascript /tmp/auto-review-fixes-missing.scpt"
REDIR="osascript < /tmp/auto-review-fixes-missing.scpt"
FILE_E="osascript -e 'display notification \"hi\"' /tmp/auto-review-fixes-missing.scpt"
NEWLINE_TAIL="osascript -e 'tell application \"Ghostty\" to input text \"x\" to terminal id \"OTHER\" -- c${NL}tell application \"Ghostty\" to input text \"y\" to terminal id v'"
for name in CONCAT VARIABLE VAR_PIPE PREFIX SMODE SMODE_H JXA_CAT NAMESPLIT SELECTED CONT FILEARG REDIR FILE_E NEWLINE_TAIL; do
  it "$name is denied"
  check deny "$(verdict "$(hook sess-worker "${!name}")")"
done
it "the concatenated id is also denied inside a heredoc to bash"
check deny "$(verdict "$(hook sess-worker "bash <<EOF${NL}$CONCAT${NL}EOF")")"
it "the denial names the reason and the fix"
OUT="$(hook sess-worker "$FILEARG")"
has "cannot prove is not aimed at pane" "$OUT"
has "Fix: send only to a literal pane id" "$OUT"
has "run osascript only with -e" "$OUT"
it "the denial is journaled"
has "blocked_driver_send" "$(py "$RUN_GHOSTTY" <<PYEOF
$HEAD_PY
print(" ".join(r["kind"] for r in pj.read(args[0])))
PYEOF
)"
it "auto's own list script through -e is allowed for a worker"
check allow "$(verdict "$(hook sess-worker "$LISTCMD")")"
it "a notification through -e that never says Ghostty is allowed"
check allow "$(verdict "$(hook sess-worker "osascript -e 'display notification \"hi\" with title \"auto\"'")")"
it "a read-only Ghostty script is denied for a worker (accepted: it cannot be proven a read)"
check deny "$(verdict "$(hook sess-worker "osascript -e 'tell application \"Ghostty\" to count windows'")")"
it "the PM may run an osascript that mentions Ghostty without naming its own pane"
check allow "$(verdict "$(hook pm-ghostty "osascript -e 'tell application \"Ghostty\" to count windows'")")"
it "a send to one other literal terminal id stays allowed for a worker"
check allow "$(verdict "$(hook sess-worker "osascript -e 'tell application \"Ghostty\" to input text \"x\" to terminal id \"OTHER-ID\"'")")"

# ---------------------------------------------------------------- one own_pane shape on every host (round 3)
echo "review-fixes: the herdr session row is built from herdr's own_pane answer"
HFAKE="${WORK}/hfake"
mkdir -p "$HFAKE"
cat > "${HFAKE}/herdr" <<'EOF'
#!/bin/bash
[ "$1 $2" = "pane get" ] && echo '{"result":{"pane":{"pane_id":"w9:p3","workspace_id":"w9","terminal_id":"term-3","tab_id":"tab-1"}}}'
exit 0
EOF
chmod +x "${HFAKE}/herdr"
herdr_row() { # herdr_row <PATH> <extra env...>
  local path="$1"; shift
  env PATH="$path" HERDR_ENV=1 "$@" "$PY" - "$AUTO_ROOT" <<PYEOF
$HEAD_PY
e = sr.record_session({"session_id": "sess-h", "source": "startup", "cwd": "/x"}, dict(os.environ))
print(json.dumps(e and {k: e.get(k) for k in ("pane_id", "env_pane", "terminal_id", "tab_id", "server", "workspace", "host", "resolved")}, sort_keys=True))
PYEOF
}
it "a moved pane: herdr's answer wins over the stale HERDR_PANE_ID"
check '{"env_pane": "w9:p0", "host": "herdr", "pane_id": "w9:p3", "resolved": "herdr", "server": "default", "tab_id": "tab-1", "terminal_id": "term-3", "workspace": "w9"}' "$(herdr_row "${HFAKE}:/usr/bin:/bin" HERDR_PANE_ID=w9:p0)"
it "herdr unreachable: the environment is the fallback and the workspace comes from the pane id"
check '{"env_pane": "w7:p1", "host": "herdr", "pane_id": "w7:p1", "resolved": "env", "server": "default", "tab_id": null, "terminal_id": null, "workspace": "w7"}' "$(herdr_row "/usr/bin:/bin" HERDR_PANE_ID=w7:p1)"
it "a herdr session with no pane variable records nothing and does not raise"
check "null" "$(herdr_row "/usr/bin:/bin")"

# ---------------------------------------------------------------- spaces are three long in memory, herdr stays unmarked on disk (round 3)
echo "review-fixes: Space is always three long and the herdr lease files are unchanged"
spaces_out() {
  AUTO_TEST_HOST=stub py <<PYEOF
$HEAD_PY
for spec in ("w1", "srvx.w1", ("srvx", "w1"), ("srvx", "w1", "herdr"), {"server": "srvx", "workspace": "w1"}, "rex--s--b", ("s", "b", "rex")):
    print(len(ph.parse_space(spec)), end=" ")
print()
run = ph.create_programme([("sp-srv", "sp-w1"), ("sp-srv", "sp-w1", "herdr"), ("sp-srv", "sp-w2", "rex")], "pm-spaces")["run"]
print(sorted(f for f in os.listdir(ph.leases_dir()) if f.startswith("sp-srv") or f.startswith("rex--sp-srv")))
print(json.dumps(json.load(open(os.path.join(ph.leases_dir(), "sp-srv.sp-w1.json"))), sort_keys=True).replace(run, "RUN").replace(ph.home_path(run), "HOME"))
print(json.load(open(os.path.join(ph.leases_dir(), "rex--sp-srv--sp-w2.json")))["host"])
lease = json.load(open(os.path.join(ph.leases_dir(), "sp-srv.sp-w1.json")))
os.unlink(os.path.join(ph.leases_dir(), "sp-srv.sp-w1.json"))
ph.write_lease(lease, run, lease["home"], "pm-spaces-2", lease["created_at"])
again = json.load(open(os.path.join(ph.leases_dir(), "sp-srv.sp-w1.json")))
print(again["session_id"], "host" in again, again["created_at"] == lease["created_at"])
PYEOF
}
OUT="$(spaces_out)"
it "every spec form parses to three parts"
check "3 3 3 3 3 3 3" "$(echo "$OUT" | sed -n 1p | sed 's/ $//')"
it "the herdr spec written two ways is one lease file; rex gets its host-qualified file"
check "['rex--sp-srv--sp-w2.json', 'sp-srv.sp-w1.json']" "$(echo "$OUT" | sed -n 2p)"
it "the herdr lease file has no host field and the usual keys"
has '"server": "sp-srv"' "$(echo "$OUT" | sed -n 3p)"
lacks '"host"' "$(echo "$OUT" | sed -n 3p)"
it "the rex lease file names its host"
check "rex" "$(echo "$OUT" | sed -n 4p)"
it "write_lease from a lease dict rewrites the same herdr file with no host field"
check "pm-spaces-2 False True" "$(echo "$OUT" | sed -n 5p)"

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

echo "review-fixes: a stored row is not proof once the host's command is gone (AE4 with a stale row)"
row rex srv s-stale sess-rex-stale rex-blk-9 rex-term-9
row herdr default w6 sess-herdr-stale w6:p9 term_p9
LEASES_BEFORE="$(ls "${CLAUDE_AUTO_DATA_DIR}/programmes/leases" | grep -vc '^\.')"
OUT="$(env PATH="/usr/bin:/bin" CLAUDE_CODE_SESSION_ID=sess-rex-stale REX_SESSION=s-stale REX_BLOCK=rex-blk-9 "$PY" "$PROG" start 2>&1)"; CODE=$?
it "rex: a registry row, but no rex on PATH: start refuses and names the install step"
check "1" "$CODE"
has "install Rex and put its rex command on PATH" "$OUT"
it "rex: become-pm refuses the same way"
OUT="$(env PATH="/usr/bin:/bin" CLAUDE_CODE_SESSION_ID=sess-rex-stale REX_SESSION=s-stale REX_BLOCK=rex-blk-9 "$PY" "$PROG" become-pm 2>&1)"
has "not on PATH" "$OUT"
OUT="$(env PATH="/usr/bin:/bin" CLAUDE_CODE_SESSION_ID=sess-herdr-stale HERDR_PANE_ID=w6:p9 HERDR_WORKSPACE_ID=w6 "$PY" "$PROG" start 2>&1)"; CODE=$?
it "herdr: a registry row, but no herdr on PATH: start refuses"
check "1" "$CODE"
has "the herdr command is not on PATH" "$OUT"
it "herdr: the environment alone is not a pane (herdr cannot answer pane get)"
OUT="$(env PATH="/usr/bin:/bin" CLAUDE_CODE_SESSION_ID=sess-env-only HERDR_PANE_ID=w6:p9 HERDR_WORKSPACE_ID=w6 "$PY" "$PROG" start 2>&1)"; CODE=$?
check "1" "$CODE"
it "none of the refused starts wrote a lease"
check "$LEASES_BEFORE" "$(ls "${CLAUDE_AUTO_DATA_DIR}/programmes/leases" | grep -vc '^\.')"

echo "review-fixes: HERDR variables stand in for no registry row (B)"
row herdr default w2 pm-herdr-b w2:p31 term_p31
programme herdr default w2 pm-herdr-b >/dev/null
it "a bare pane suffix from a sender with no row is denied whatever HERDR_WORKSPACE_ID says"
check deny "$(verdict "$(hook sess-no-row 'herdr agent prompt p31 go' HERDR_WORKSPACE_ID=w3)")"
check deny "$(verdict "$(hook sess-no-row 'herdr agent prompt p31 go' HERDR_WORKSPACE_ID=w2)")"
it "a sender whose row puts it in another workspace is still allowed"
row herdr default w3 sess-far-b w3:p60 term_far
row herdr default w3 sess-far-peer-b w3:p31 term_far_peer
check allow "$(verdict "$(hook sess-far-b 'herdr agent prompt p31 go' HERDR_WORKSPACE_ID=w2)")"
it "space_of_session ignores the environment and answers from the registry only"
OUT="$(env HERDR_PANE_ID=w2:p31 HERDR_WORKSPACE_ID=w2 "$PY" - "$AUTO_ROOT" <<PYEOF
$HEAD_PY
print(sr.space_of_session("sess-no-row"), sr.space_of_session("sess-far-b"))
PYEOF
)"
check "None ('default', 'w3')" "$OUT"

# ---------------------------------------------------------------- one default-deny policy for every host (round 4, D)
echo "review-fixes: a session that drives no programme may only send to a literal pane the registry proves is another session's"
row herdr default w2 sess-peer77-d w2:p77 term_p77
row rex srv s-rx pm-rex-d rex-blk-D1 rex-term-D1
programme rex srv s-rx pm-rex-d >/dev/null
row rex srv s-rx sess-rex-o rex-blk-O1 rex-term-O1
row stub srv win-d pm-stub-d stub-pm-d stub-pm-d-term
programme stub srv win-d pm-stub-d >/dev/null
row stub srv win-d sess-stub-o stub-o-d stub-o-d-term
denied() { # denied <family> <command>: a worker's command is denied and the PM's own session is not asked
  it "$1"
  check deny "$(verdict "$(hook sess-worker "$2" AUTO_TEST_HOST=stub)")"
}
allowed() {
  it "$1"
  check allow "$(verdict "$(hook sess-worker "$2" AUTO_TEST_HOST=stub)")"
}
echo "review-fixes: herdr"
allowed "a literal pane another session ran in is allowed" 'herdr agent prompt w2:p77 go'
allowed "pane send-text and pane run to that pane are allowed" 'herdr pane send-text w2:p77 hi'
denied "a literal pane no session ran in is denied" 'herdr agent prompt w2:p88 go'
denied "target from a variable" 'herdr agent prompt $P go'
denied "target from a variable set on the same line" 'P=w2:p77; herdr agent prompt $P go'
denied "target from a command substitution" 'herdr agent prompt $(echo w2:p77) go'
denied "target from backticks" 'herdr agent prompt `echo w2:p77` go'
denied "target read from a file" 'herdr agent prompt @/tmp/target go'
denied "a glob in the target" 'herdr agent prompt w2:p7* go'
denied "no target at all" 'herdr agent prompt'
denied "an unknown verb on the herdr command" 'herdr agent frobnicate w2:p77'
denied "agent start with no literal pane" 'herdr agent start'
denied "a remote machine option" 'herdr --machine other agent prompt w2:p77 go'
denied "the command word is a variable" '$H agent prompt w2:p77 go'
denied "the command word is a variable behind env" 'env H=herdr $H agent prompt w2:p77 go'
denied "the command word is a substitution" '$(command -v herdr) agent prompt w2:p77 go'
denied "the command word is a variable inside bash -c" "bash -c '\$H agent prompt w2:p77 go'"
allowed "pane list is a read" 'herdr pane list'
allowed "agent list and status are reads" 'herdr agent list; herdr status server'
echo "review-fixes: tty devices"
denied "a redirect into a tty device" 'echo hi > /dev/ttys016'
denied "an append into a tty device" 'echo hi >> /dev/ttys016'
denied "tee into a tty device" 'echo hi | tee /dev/ttys016'
denied "a tty device built at run time" 'echo hi > /dev/tty$N'
denied "a tty device behind bash -c" "bash -c 'echo hi > /dev/ttys016'"
allowed "the worker's own controlling terminal" 'echo hi > /dev/tty'
allowed "naming a tty device that is no driver's" 'ls /dev/ttys099'
echo "review-fixes: Rex"
allowed "a literal block another session ran in is allowed" 'rex send -b rex-blk-O1 go'
allowed "split on that block is allowed" 'rex split -b rex-blk-O1'
allowed "reads stay allowed" 'rex session ls --json'
denied "a block no session ran in" 'rex send -b rex-blk-X9 go'
denied "send-key to an unknown block" 'rex send-key -b rex-blk-X9 enter'
denied "block from a variable" 'rex send -b $B go'
denied "block from a substitution" 'rex send -b "$(echo rex-blk-O1)" go'
denied "block with the equals form from a variable" 'rex send --block=$B go'
denied "no block option" 'rex send go'
denied "an unknown verb on the rex command, no block" 'rex frobnicate'
denied "an unknown verb aimed at an unproven block" 'rex frobnicate -b rex-blk-X9'
denied "api call" 'rex api call -s s-rx session.view'
denied "run with no block" 'rex run ls'
denied "the command word is a variable" '$R send -b rex-blk-O1 go'
echo "review-fixes: stub host and the generic unknown verb"
allowed "a stub send to a pane another session ran in" 'stubhost send stub-o-d go'
denied "a stub send to an unproven pane" 'stubhost send stub-nobody go'
denied "an unknown verb on a host command" 'stubhost frobnicate stub-o-d'
denied "a host command with no verb" 'stubhost'
allowed "a host list is a read" 'stubhost list'
denied "the stub command word is a variable" '$S send stub-o-d go'
echo "review-fixes: the PM keeps today's behaviour"
it "the PM may send to a worker pane"
check allow "$(verdict "$(hook pm-herdr-b 'herdr agent prompt w2:p77 go')")"
it "the PM may send with a runtime-built target (no regression)"
check allow "$(verdict "$(hook pm-herdr-b 'herdr agent prompt $P go')")"
it "the PM may not type into its own pane"
check deny "$(verdict "$(hook pm-herdr-b 'herdr agent prompt w2:p31 go')")"
it "the PM of another programme is not held to the allow-list"
check allow "$(verdict "$(hook pm-rex-d 'herdr agent prompt $P go')")"

echo "review-fixes: the allow-list never raises, because a hook error fails open"
it "odd and hostile command text goes through every host's classifier without an exception"
OUT="$(AUTO_TEST_HOST=stub "$PY" - "$AUTO_ROOT" <<'PYEOF' 2>&1
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
sg = load_lib_module("send_guard")
cmds = ["", " ", "herdr", "herdr agent", "herdr --session", "herdr --machine", "$", "$(", "`", "'", '"', ">", "< <", "<<", "rex -b", "rex send -b", "rex --block=",
        "osascript", "osascript -e", "osascript -l", "osascript -", "$H", "$H agent", "$H $H $H", "env", "env X=1", "exec", "x=1", "( herdr agent prompt",
        "herdr agent prompt )", "stubhost", "stubhost send", "bash -c", "eval", "a;b;c", "herdr agent prompt p1 p2 p3 " * 80, "$(" * 50]
bad = []
for c in cmds:
    try:
        sg.host_sends(c, ["pane-x", "term-x"], proven=lambda t: False)
        sg.host_sends(c, ["pane-x", "term-x"])
    except Exception as exc:
        bad.append((c[:20], type(exc).__name__))
print(bad)
PYEOF
)"
check "[]" "$OUT"

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
