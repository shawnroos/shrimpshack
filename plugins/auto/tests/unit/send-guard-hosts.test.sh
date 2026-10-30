#!/usr/bin/env bash
# auto unit test: the send-guard, the start gate and typed takeover hold on every terminal host (R12, R13, R21).
#
# The guard asks each host module what a send looks like (KTD8) and reads the PM's pane from registry rows,
# never from a host variable (KTD3). The stub host stands in for Rex and Ghostty where a real binary is absent.

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

echo "send-guard-hosts.test.sh"

WORK="$(mktemp -d -t auto-send-guard.XXXXXX)"
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
LEASES="${CLAUDE_AUTO_DATA_DIR}/programmes/leases"

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

# row <host> <server> <workspace> <session> <pane> <terminal>: a SessionStart row the host proved.
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

# programme <host> <server> <workspace> <pm session>: prints the run id.
programme() {
  AUTO_TEST_HOST=stub py "$@" <<PYEOF
$HEAD_PY
host, server, workspace, sid = args
space = workspace if host == "herdr" else (server, workspace, host)
print(ph.create_programme([space], sid)["run"])
PYEOF
}

row herdr default w2 pm-herdr w2:p31 term_p31
RUN_HERDR="$(programme herdr default w2 pm-herdr)"
row stub srv win-1 pm-stub stub-pm stub-term
RUN_STUB="$(programme stub srv win-1 pm-stub)"
row rex srv s1 pm-rex rex-blk-7 rex-term-7
RUN_REX="$(programme rex srv s1 pm-rex)"
row ghostty srv g1 pm-ghostty ghost-term-9 ghost-tty-9
RUN_GHOSTTY="$(programme ghostty srv g1 pm-ghostty)"
row herdr default w2 sess-worker w2:p50 term_p50
row herdr default w2 sess-peer77 w2:p77 term_p77
row stub srv win-1 sess-stub-other stub-other stub-other-term
row rex srv s1 sess-rex-other rex-blk-8 rex-term-8

# hook <session> <command> [VAR=value ...]: the PreToolUse output for a Bash command.
hook() {
  local payload
  payload="$("$PY" -c 'import json,sys; print(json.dumps({"session_id": sys.argv[1], "tool_name": "Bash", "tool_input": {"command": sys.argv[2]}}))' "$1" "$2")"
  ( cd "$NOREPO" && env "${@:3}" bash "${HOOKS}/on-pretooluse-action.sh" <<< "$payload" )
}
is_deny() { case "$1" in *'"deny"'*) return 0 ;; esac; return 1; }
verdict() { if is_deny "$1"; then echo deny; else echo allow; fi; }

NL=$'\n'
# wrap <command>: fills FORMS and FORM_NAMES with every way to run the command from a shell.
wrap() {
  local s="$1"
  FORM_NAMES=(plain bash-c sh-c eval heredoc heredoc-stray-quote here-string dollar-paren backticks nested env-bash-lc)
  FORMS=("$s"
         "bash -c '$s'"
         "sh -c \"$s\""
         "eval '$s'"
         "bash <<EOF${NL}$s${NL}EOF"
         "cat <<'EOF' | bash${NL}echo don't${NL}$s${NL}EOF"
         "bash <<< '$s'"
         "echo \"\$($s)\""
         "echo \`$s\`"
         "bash -c \"eval '$s'\""
         "env X=1 bash -lc '$s'")
}

# every_form <sender> <send command> <deny|allow> [VAR=value ...]: one check over every wrapper form.
every_form() {
  local sender="$1" send="$2" want="$3" i out bad=""
  wrap "$send"
  for i in "${!FORMS[@]}"; do
    out="$(hook "$sender" "${FORMS[$i]}" "${@:4}")"
    if is_deny "$out"; then [ "$want" = deny ] || bad="$bad ${FORM_NAMES[$i]}(denied)"
    else [ "$want" = allow ] || bad="$bad ${FORM_NAMES[$i]}(allowed)"; fi
  done
  check "" "$bad"
}

HERDR_SEND='herdr agent prompt w2:p31 go'
HERDR_ELSEWHERE='herdr agent prompt w2:p77 go'
STUB_SEND='stubhost send stub-pm go'
STUB_ELSEWHERE='stubhost send stub-other go'
STUB_ENV=(AUTO_TEST_HOST=stub)

echo "send-guard-hosts: a send into the PM's pane is blocked in every wrapper form"
it "herdr: another session, every form"
every_form sess-worker "$HERDR_SEND" deny
it "herdr: the PM typing into its own pane, every form"
every_form pm-herdr "$HERDR_SEND" deny
it "stub host: another session, every form"
every_form sess-worker "$STUB_SEND" deny "${STUB_ENV[@]}"
it "stub host: the PM typing into its own pane, every form"
every_form pm-stub "$STUB_SEND" deny "${STUB_ENV[@]}"
it "stub host: a send naming the PM's terminal id, every form"
every_form pm-stub 'stubhost type stub-term go' deny "${STUB_ENV[@]}"
it "rex default-deny: any rex call naming the PM's block, every form (PM sender)"
every_form pm-rex 'rex send rex-blk-7 go' deny
it "rex default-deny: any rex call naming the PM's block, every form (other session)"
every_form sess-worker 'rex api send rex-blk-7 go' deny
it "ghostty default-deny: an osascript naming the PM's terminal, every form (PM sender)"
every_form pm-ghostty 'osascript -e tell-ghostty-input-text-to-ghost-term-9' deny

echo "send-guard-hosts: a send to another pane stays allowed"
it "herdr: the PM's sends to other panes, every form"
every_form pm-herdr "$HERDR_ELSEWHERE" allow
it "herdr: a worker's sends to other panes, every form"
every_form sess-worker "$HERDR_ELSEWHERE" allow
it "stub host: the PM's sends to other panes, every form"
every_form pm-stub "$STUB_ELSEWHERE" allow "${STUB_ENV[@]}"
it "stub host: a worker's sends to other panes, every form"
every_form sess-worker "$STUB_ELSEWHERE" allow "${STUB_ENV[@]}"
it "rex: a send to another block, every form"
every_form sess-worker 'rex send -b rex-blk-8 go' allow
it "a PM reading its own pane is allowed"
check "allow" "$(verdict "$(hook pm-herdr 'herdr pane get w2:p31')")"
it "another session naming the PM's pane in a read is denied"
check "deny" "$(verdict "$(hook sess-worker 'herdr pane get w2:p31')")"

echo "send-guard-hosts: AE6 on the stub host"
OUT="$(hook sess-worker "$STUB_SEND" "${STUB_ENV[@]}")"
it "a stub-host session sending into the PM's pane is denied"
if is_deny "$OUT"; then pass; else fail "$OUT"; fi
it "the attempt is journaled with the host verb and the target"
ROW="$(py "$RUN_STUB" <<PYEOF
$HEAD_PY
r = [x for x in pj.read(args[0]) if x["kind"] == "blocked_driver_send"][-1]
print(r["kind"], r["session_id"], r["payload"]["verb"], r["payload"]["target"])
PYEOF
)"
check "blocked_driver_send sess-worker send stub-pm" "$ROW"

echo "send-guard-hosts: a host variable is not evidence (KTD3)"
FAKES=(HERDR_ENV=0 HERDR_PANE_ID=w9:p9 HERDR_WORKSPACE_ID=w9 HERDR_SOCKET_PATH=/nonexistent/herdr.sock
       REX_SESSION=fake REX_BLOCK_ID=fake-blk GHOSTTY_RESOURCES_DIR=/x TERM_PROGRAM=ghostty
       CLAUDE_AUTO_TEST_HOST=stub)
it "herdr: another session, fake host variables, every form"
every_form sess-worker "$HERDR_SEND" deny "${FAKES[@]}"
it "herdr: the PM itself, fake host variables, every form"
every_form pm-herdr "$HERDR_SEND" deny "${FAKES[@]}"
it "stub: another session, fake host variables, every form"
every_form sess-worker "$STUB_SEND" deny "${STUB_ENV[@]}" "${FAKES[@]}"
it "stub: the PM itself, fake host variables, every form"
every_form pm-stub "$STUB_SEND" deny "${STUB_ENV[@]}" "${FAKES[@]}"
it "rex and ghostty: fake host variables, every form"
every_form pm-rex 'rex send rex-blk-7 go' deny "${FAKES[@]}"
every_form pm-ghostty 'osascript -e tell-ghostty-input-text-to-ghost-term-9' deny "${FAKES[@]}"
it "a bare pane suffix from a session the registry puts in the PM's workspace is denied whatever HERDR_WORKSPACE_ID says"
row herdr default w2 sess-peer w2:p60 term_p60
check "deny" "$(verdict "$(hook sess-peer 'herdr agent prompt p31 go' HERDR_WORKSPACE_ID=w3)")"
it "a bare pane suffix from a session the registry puts in another workspace is allowed when that pane is proven another session's"
row herdr default w3 sess-far w3:p60 term_far
row herdr default w3 sess-far-peer w3:p31 term_far_peer
check "allow" "$(verdict "$(hook sess-far 'herdr agent prompt p31 go' HERDR_WORKSPACE_ID=w2)")"
it "a stub driver is guarded only while AUTO_TEST_HOST selects the stub host module, and a lookalike variable does not select it"
check "allow" "$(verdict "$(hook pm-stub "$STUB_SEND" CLAUDE_AUTO_TEST_HOST=stub)")"

echo "send-guard-hosts: R21, start and become-pm refuse when the host cannot find the session's pane"
STUBVARS=()
as_stub() {
  local sid="$1"; shift
  OUT="$(env CLAUDE_CODE_SESSION_ID="$sid" AUTO_TEST_HOST=stub ${STUBVARS[@]+"${STUBVARS[@]}"} "$PY" "$PROG" "$@" 2>&1)"
  CODE=$?
}
lease_count() { ls "$LEASES" | grep -vc '^\.'; }
LEASES_BEFORE="$(lease_count)"
it "AE7: start from a stub session with no pane refuses and names the fix"
as_stub sess-lone start
check "1" "$CODE"
has "cannot identify this session's stub terminal pane" "$OUT"
has "set AUTO_TEST_STUB_PANE" "$OUT"
it "the refused start wrote no lease"
check "$LEASES_BEFORE" "$(lease_count)"
it "become-pm refuses the same way and says so in its step"
as_stub sess-lone become-pm
has '"step": "refused"' "$OUT"
has "cannot identify this session's stub terminal pane" "$OUT"
it "start in a herdr session with no pane variable and no registry row still refuses"
OUT="$(env CLAUDE_CODE_SESSION_ID=sess-nowhere "$PY" "$PROG" start 2>&1)"; CODE=$?
check "1" "$CODE"
it "control: a stub session whose pane the host finds starts"
row stub srv win-s sess-s stub-s stub-s-term
STUBVARS=(AUTO_TEST_STUB_PANE=stub-s AUTO_TEST_STUB_SERVER=srv AUTO_TEST_STUB_WORKSPACE=win-s)
as_stub sess-s start
check "0" "$CODE"
has '"kind": "programme_started"' "$OUT"

echo "send-guard-hosts: typed takeover moves the lease only on host evidence (R13, AE3)"
SEQ="${WORK}/presence-seq"
N=0
CASE_RUN="" CASE_PM="" CASE_TAKER=""
# fresh_case: a stub-space programme with its own PM and a second session in the same space.
fresh_case() {
  N=$((N + 1))
  CASE_PM="pm-c$N"; CASE_TAKER="taker-c$N"
  local ws="win-c$N"
  row stub srv "$ws" "$CASE_PM" "stub-pm-c$N" "stub-pm-c$N-term"
  row stub srv "$ws" "$CASE_TAKER" "stub-tk-c$N" "stub-tk-c$N-term"
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

# pick_works <host answer>: the exact-label pick, then the takeover citing it, with the host answering $1 throughout.
pick_works() {
  local p
  p="$(pick "Approve takeover --replace $CASE_PM")"
  printf '%s\n%s\n%s\n' "$1" "$1" "$1" > "$SEQ"
  takeover_as --prompt "$p"
}

fresh_case
typed '/auto:programme-takeover'
it "setup: the typed request was journaled for the taker"
has "takeover_request $CASE_TAKER" "$(py "$CASE_RUN" <<PYEOF
$HEAD_PY
print(" ".join(r["kind"] + " " + str(r["session_id"]) for r in pj.read(args[0])))
PYEOF
)"
it "host says present: a plain typed takeover is refused and the PM keeps the programme"
printf 'present\npresent\n' > "$SEQ"
takeover_as
check "1 $CASE_PM" "$CODE $(driver)"
it "host says unknown: a plain typed takeover is refused and the PM keeps the programme"
printf 'unknown\nunknown\n' > "$SEQ"
takeover_as
check "1 $CASE_PM" "$CODE $(driver)"
it "the unknown refusal does not claim the PM is gone"
lacks "driver_gone" "$OUT"
it "host says present: the exact-label pick takes the programme"
pick_works present
check "0 $CASE_TAKER" "$CODE $(driver)"

fresh_case
typed '/auto:programme-takeover'
it "host says unknown: the exact-label pick takes the programme"
pick_works unknown
check "0 $CASE_TAKER" "$CODE $(driver)"

fresh_case
typed '/auto:programme-takeover'
it "host says gone: the exact-label pick takes the programme"
pick_works gone
check "0 $CASE_TAKER" "$CODE $(driver)"

fresh_case
typed '/auto:programme-takeover'
it "host says gone: a plain typed takeover moves the lease"
printf 'gone\ngone\n' > "$SEQ"
takeover_as
check "0 $CASE_TAKER" "$CODE $(driver)"

fresh_case
typed '/auto:programme-takeover'
it "race: the PM is gone when first read and back under the lease lock, so the move is refused"
printf 'gone\npresent\n' > "$SEQ"
takeover_as
check "1 $CASE_PM" "$CODE $(driver)"
it "race: the refusal says the PM was seen again"
has "seen again" "$OUT"
it "race: a host that keeps saying gone still moves the lease"
printf 'gone\ngone\n' > "$SEQ"
takeover_as
check "0 $CASE_TAKER" "$CODE $(driver)"

echo ""
echo "send-guard-hosts.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
