#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
HOOKS="${AUTO_ROOT}/.claude/hooks"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
check() { if [ "$1" = "$2" ]; then pass; else fail "expected [$1] got [$2]"; fi; }

echo "programme-hooks.test.sh"

WORK="$(mktemp -d -t auto-prog-hooks.XXXXXX)"
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

for v in $(env | sed -n 's/^\(HERDR_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
unset CLAUDE_CODE_SESSION_ID

FAKEBIN="${WORK}/bin"
mkdir -p "$FAKEBIN"
cat > "${FAKEBIN}/herdr" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_HERDR_LOG:-/dev/null}"
if [ "$1 $2" = "pane get" ]; then
  pane="${FAKE_HERDR_PANE:-$3}"
  printf '{"id":"cli:pane:get","result":{"pane":{"pane_id":"%s","workspace_id":"%s","terminal_id":"term_%s","tab_id":"w2:t1"}},"type":"pane_info"}\n' \
    "$pane" "${pane%%:*}" "${pane##*:}"
fi
exit 0
EOF
chmod +x "${FAKEBIN}/herdr"
export PATH="${FAKEBIN}:${PATH}"
export FAKE_HERDR_LOG="${WORK}/herdr.log"
: > "$FAKE_HERDR_LOG"

MARKER_PY="${WORK}/marker-python"
cat > "$MARKER_PY" <<EOF
#!/usr/bin/env bash
touch "${WORK}/python-ran"
exit 0
EOF
chmod +x "$MARKER_PY"

export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
printf 'export FIXTURE_TOKEN="fixture-value-9f8e7d"\n' > "$CLAUDE_AUTO_SECRETS_FILE"
NOREPO="${WORK}/norepo"
mkdir -p "$NOREPO"

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
ph = load_lib_module("programme_home")
pj = load_lib_module("programme_journal")
reg = load_lib_module("session_registry")
args = sys.argv[2:]
$(cat)
PYEOF
}

session_start() {
  local sid="$1" pane="$2" entry="${3:-cli}"
  ( cd "$NOREPO" && HERDR_ENV=1 HERDR_PANE_ID="$pane" HERDR_WORKSPACE_ID="${pane%%:*}" \
    CLAUDE_CODE_ENTRYPOINT="$entry" \
    bash "${HOOKS}/on-session-start.sh" <<< "{\"session_id\":\"$sid\",\"source\":\"startup\",\"cwd\":\"$NOREPO\"}" )
}

prompt_hook() {
  local sid="$1" text="$2"
  local payload
  payload="$("$PY" -c 'import json,sys; print(json.dumps({"session_id": sys.argv[1], "prompt": sys.argv[2], "hook_event_name": "UserPromptSubmit"}))' "$sid" "$text")"
  ( cd "$NOREPO" && HERDR_PANE_ID="${PROMPT_PANE:-}" HERDR_WORKSPACE_ID="${PROMPT_WS:-}" \
    bash "${HOOKS}/on-user-prompt.sh" <<< "$payload" )
}

action_hook_in() {
  local dir="$1" sid="$2" cmd="$3"
  local payload
  payload="$("$PY" -c 'import json,sys; print(json.dumps({"session_id": sys.argv[1], "tool_name": "Bash", "tool_input": {"command": sys.argv[2]}}))' "$sid" "$cmd")"
  ( cd "$dir" && HERDR_WORKSPACE_ID="${ACTION_WS:-}" bash "${HOOKS}/on-pretooluse-action.sh" <<< "$payload" )
}

action_hook() { action_hook_in "$NOREPO" "$@"; }

journal_kinds() {
  run_py "$1" <<'EOF'
print(" ".join(r["kind"] for r in pj.read(args[0])))
EOF
}

it "with no herdr env, SessionStart writes nothing and runs no Python before the presence gate"
( cd "$NOREPO" && CLAUDE_AUTO_PYTHON3="$MARKER_PY" bash "${HOOKS}/on-session-start.sh" <<< '{"session_id":"s0"}' )
if [ ! -e "${WORK}/python-ran" ] && [ ! -e "${CLAUDE_AUTO_DATA_DIR}/sessions" ]; then pass; else fail "python ran or registry written"; fi

it "a machine with no leases: the prompt shim runs no Python"
rm -f "${WORK}/python-ran"
OUT="$( cd "$NOREPO" && CLAUDE_AUTO_PYTHON3="$MARKER_PY" bash "${HOOKS}/on-user-prompt.sh" <<< '{"session_id":"s0","prompt":"hi"}' )"
if [ ! -e "${WORK}/python-ran" ] && [ -z "$OUT" ]; then pass; else fail "python ran or output: $OUT"; fi

it "a machine with no leases and no repo: the action shim runs no Python"
rm -f "${WORK}/python-ran"
( cd "$NOREPO" && CLAUDE_AUTO_PYTHON3="$MARKER_PY" bash "${HOOKS}/on-pretooluse-action.sh" <<< '{"session_id":"s0","tool_input":{"command":"ls"}}' )
if [ ! -e "${WORK}/python-ran" ]; then pass; else fail "python ran"; fi

it "under the test harness with no data dir, SessionStart skips the registry"
rm -f "${WORK}/python-ran"
( cd "$NOREPO" && unset CLAUDE_AUTO_DATA_DIR && CLAUDE_AUTO_TEST_HARNESS=1 HERDR_PANE_ID="w2:p1" \
  CLAUDE_AUTO_PYTHON3="$MARKER_PY" bash "${HOOKS}/on-session-start.sh" <<< '{"session_id":"s0"}' )
if [ ! -e "${WORK}/python-ran" ]; then pass; else fail "registry ran without a test data dir"; fi

it "SessionStart where env says p26 and pane get says p31 records p31"
FAKE_HERDR_PANE="w2:p31" session_start sess-pm "w2:p26" >/dev/null
OUT="$(run_py <<'EOF'
e = reg.lookup("sess-pm")
print(e["pane_id"], e["env_pane"], e["interactive"], e["workspace"], e["server"])
EOF
)"
check "w2:p31 w2:p26 True w2 default" "$OUT"

it "an interactive SessionStart reports the session to herdr"
if grep -q -- "pane report-agent-session --source auto --agent claude --agent-session-id sess-pm --session-start-source startup w2:p31" "$FAKE_HERDR_LOG"; then pass; else fail "log: $(cat "$FAKE_HERDR_LOG")"; fi

it "SessionStart prints nothing from the registry"
OUT="$(FAKE_HERDR_PANE="w2:p31" session_start sess-pm "w2:p31")"
check "" "$OUT"

it "a headless child in a worker pane is marked headless and not reported"
: > "$FAKE_HERDR_LOG"
FAKE_HERDR_PANE="w2:p50" session_start sess-child "w2:p50" sdk-cli >/dev/null
OUT="$(run_py <<'EOF'
rows = reg.read_space("default", "w2")
print([r["interactive"] for r in rows if r["session_id"] == "sess-child"], reg.lookup("sess-child"))
EOF
)"
if [ "$OUT" = "[False] None" ] && ! grep -q report-agent-session "$FAKE_HERDR_LOG"; then pass; else fail "got $OUT / $(cat "$FAKE_HERDR_LOG")"; fi

it "the registry keeps the last 50 lines per pane"
for i in $(seq 1 55); do FAKE_HERDR_PANE="w2:p60" session_start "sess-loop-$i" "w2:p60" sdk-cli >/dev/null; done
OUT="$(run_py <<'EOF'
rows = reg.read_space("default", "w2")
loop = [r for r in rows if r["pane_id"] == "w2:p60"]
print(len(loop), loop[-1]["session_id"], any(r["pane_id"] == "w2:p31" for r in rows))
EOF
)"
check "50 sess-loop-55 True" "$OUT"

it "the registry file is 0600 in a 0700 folder"
OUT="$(stat -f '%Lp' "${CLAUDE_AUTO_DATA_DIR}/sessions/default.w2.jsonl") $(stat -f '%Lp' "${CLAUDE_AUTO_DATA_DIR}/sessions")"
check "600 700" "$OUT"

RUN="$(run_py <<'EOF'
out = ph.create_programme(["w2"], "sess-pm")
print(out["run"])
EOF
)"

it "a prompt in the driving session is journaled with a new id and origin typed"
OUT="$(prompt_hook sess-pm "please adopt the merge rule")"
ROW="$(run_py "$RUN" <<'EOF'
r = [x for x in pj.read(args[0]) if x["kind"] == "prompt"][-1]
print(r["prompt_id"], r["payload"]["origin"], r["payload"]["text"], r["session_id"])
EOF
)"
PID="${ROW%% *}"
case "$ROW" in "p"*" typed please adopt the merge rule sess-pm") pass ;; *) fail "row: $ROW" ;; esac

it "the hook's additionalContext names the same id and origin it journaled"
CTX="$(printf '%s' "$OUT" | "$PY" -c '
import json, sys
d = json.load(sys.stdin)["hookSpecificOutput"]
body = d["additionalContext"].split("\n")
data = json.loads(body[2])
print(d["hookEventName"], body[0], body[-1], data["prompt_id"], data["origin"])')"
check "UserPromptSubmit <auto-data> </auto-data> ${PID} typed" "$CTX"

it "the same prompt in another session in the same cwd appends nothing"
BEFORE="$(journal_kinds "$RUN")"
OUT="$(prompt_hook sess-fork "please adopt the merge rule")"
AFTER="$(journal_kinds "$RUN")"
if [ "$BEFORE" = "$AFTER" ] && [ -z "$OUT" ]; then pass; else fail "before [$BEFORE] after [$AFTER] out [$OUT]"; fi

it "a prompt containing a secrets-file value is journaled with [redacted]"
prompt_hook sess-pm "the key is fixture-value-9f8e7d ok" >/dev/null
OUT="$(run_py "$RUN" <<'EOF'
r = [x for x in pj.read(args[0]) if x["kind"] == "prompt"][-1]
print(r["payload"]["text"])
EOF
)"
check "the key is [redacted] ok" "$OUT"
if grep -q "fixture-value-9f8e7d" "${CLAUDE_AUTO_DATA_DIR}/programmes/${RUN}/journal.jsonl"; then
  it "the secret value never reaches the journal file"; fail "secret found in journal"
fi

it "a prompt matching an armed cron prompt is classified cron"
run_py "$RUN" <<'EOF' >/dev/null
core = load_lib_module("run_record_core")
home = ph.home_path(args[0])
def mutate(rec):
    rec["programme"]["watchers"]["cadence"] = {"prompt": "  sweep the   programme now "}
core._with_locked_run_record(home, args[0], mutate)
EOF
prompt_hook sess-pm "sweep the programme now" >/dev/null
OUT="$(run_py "$RUN" <<'EOF'
r = [x for x in pj.read(args[0]) if x["kind"] == "prompt"][-1]
print(r["payload"]["origin"])
EOF
)"
check "cron" "$OUT"

it "/auto:programme-takeover typed in a new session in w2 is journaled as a takeover request in w2's home"
FAKE_HERDR_PANE="w2:p40" session_start sess-new "w2:p40" >/dev/null
OUT="$(prompt_hook sess-new "/auto:programme-takeover")"
ROW="$(run_py "$RUN" <<'EOF'
r = pj.read(args[0])[-1]
print(r["kind"], r["session_id"], r["payload"]["space"], r["payload"]["driving"])
EOF
)"
if [ "$ROW" = "takeover_request sess-new default.w2 False" ] && [ -z "$OUT" ]; then pass; else fail "row [$ROW] out [$OUT]"; fi

it "an end request typed in the driving session cites its captured prompt"
prompt_hook sess-pm "/auto:programme-end all finished" >/dev/null
OUT="$(run_py "$RUN" <<'EOF'
rows = pj.read(args[0])
req, prompt = rows[-1], rows[-2]
print(req["kind"], req["payload"]["driving"], req.get("cites") == [prompt["prompt_id"]], prompt["kind"])
EOF
)"
check "end_request True True prompt" "$OUT"

it "a request from a session with no registry line falls back to the herdr env space"
OUT="$(PROMPT_PANE="w2:p77" PROMPT_WS="w2" prompt_hook sess-unknown "/auto:programme-handover sess-x")"
ROW="$(run_py "$RUN" <<'EOF'
r = pj.read(args[0])[-1]
print(r["kind"], r["session_id"])
EOF
)"
check "handover_request sess-unknown" "$ROW"

it "a worker session sending herdr agent prompt to the PM's pane is denied and journaled"
OUT="$(action_hook sess-worker 'herdr agent prompt w2:p31 "adopt rule"')"
DEC="$(printf '%s' "$OUT" | "$PY" -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["permissionDecision"])' 2>/dev/null)"
ROW="$(run_py "$RUN" <<'EOF'
r = pj.read(args[0])[-1]
print(r["kind"], r["session_id"], r["payload"]["target"], r["payload"]["verb"])
EOF
)"
if [ "$DEC" = "deny" ] && [ "$ROW" = "blocked_driver_send sess-worker w2:p31 agent prompt" ]; then pass; else fail "dec [$DEC] row [$ROW] out [$OUT]"; fi

it "the same command to a worker pane is allowed"
OUT="$(action_hook sess-worker 'herdr agent prompt w2:p50 "adopt rule"')"
check "" "$OUT"

it "pane send-text, pane send-keys, pane run and agent send-keys to the PM's pane are denied"
ALL=1
for c in 'herdr pane send-text w2:p31 hi' 'herdr pane send-keys w2:p31 enter' 'herdr pane run w2:p31 ls' \
         'herdr agent send-keys w2:p31 esc' 'cd /tmp && herdr --session default pane send-text w2:p31 hi' \
         '"$HERDR_BIN_PATH" agent prompt term_p31 go' '/opt/bin/herdr agent prompt w2:p31 go'; do
  OUT="$(action_hook sess-worker "$c")"
  case "$OUT" in *'"deny"'*) ;; *) ALL=0; echo "      not denied: $c" ;; esac
done
check "1" "$ALL"

it "a send to the PM's pane inside a quoted shell -c script is denied and journaled"
ALL=1
for c in "bash -c 'herdr agent prompt w2:p31 hi'" 'sh -c "herdr pane send-text w2:p31 x"' \
         "env FOO=1 bash -c 'herdr agent prompt w2:p31 hi'" "zsh -lc 'cd /tmp; herdr pane run w2:p31 ls'" \
         "dash -c \"sh -c 'herdr agent prompt w2:p31 hi'\"" "/bin/bash -ec 'herdr agent send-keys w2:p31 esc'"; do
  OUT="$(action_hook sess-worker "$c")"
  ROW="$(run_py "$RUN" <<'EOF'
r = pj.read(args[0])[-1]
print(r["kind"], r["payload"]["target"])
EOF
)"
  case "$OUT" in *'"deny"'*) ;; *) ALL=0; echo "      not denied: $c" ;; esac
  [ "$ROW" = "blocked_driver_send w2:p31" ] || { ALL=0; echo "      not journaled: $c ($ROW)"; }
  run_py "$RUN" <<'EOF' >/dev/null
pj.append(args[0], "rules_acked", "sess-test", {})
EOF
done
check "1" "$ALL"

it "the same shell -c wrappers sending to a worker pane are allowed"
OUT="$(action_hook sess-worker "bash -c 'herdr agent prompt w2:p50 hi'")$(action_hook sess-worker 'sh -c "herdr pane send-text w2:p50 x"')"
check "" "$OUT"

it "a read-only herdr command naming the PM's pane is allowed"
OUT="$(action_hook sess-worker 'herdr pane get w2:p31')"
check "" "$OUT"

it "the journaled command is redacted"
action_hook sess-worker 'herdr pane send-text w2:p31 fixture-value-9f8e7d' >/dev/null
if grep -q "fixture-value-9f8e7d" "${CLAUDE_AUTO_DATA_DIR}/programmes/${RUN}/journal.jsonl"; then fail "secret in journal"; else pass; fi

it "a bare pane suffix is denied only from the driver's workspace"
OUT1="$(ACTION_WS=w2 action_hook sess-worker 'herdr agent prompt p31 go')"
OUT2="$(ACTION_WS=w3 action_hook sess-worker 'herdr agent prompt p31 go')"
case "$OUT1" in *'"deny"'*) check "" "$OUT2" ;; *) fail "w2 bare suffix not denied: $OUT1" ;; esac

it "a send to the driver's pane combined with a destructive command still pauses the task run"
TASKREPO="${WORK}/taskrepo"
mkdir -p "${TASKREPO}/.claude/auto"
run_py "$TASKREPO" <<'EOF' >/dev/null
core = load_lib_module("run_record_core")
core.init_run_record(args[0], "task-run", backend="native", steps=[], driving_session_id="sess-worker")
EOF
OUT="$(action_hook_in "$TASKREPO" sess-worker "herdr pane send-text w2:p31 x && git push --force")"
DRV="$(run_py "$TASKREPO" <<'EOF'
core = load_lib_module("run_record_core")
print(core.read_run_record(args[0], "task-run")["loop"]["driver"])
EOF
)"
case "$OUT" in *'RUN PAUSED'*'"deny"'*) check "manual" "$DRV" ;; *) fail "out [$OUT] driver [$DRV]" ;; esac

it "the caller helper is false for a session that is only in agent_session_ids"
OUT="$(run_py <<'EOF'
rec = {"driving_session_id": "sess-pm", "agent_session_ids": ["sess-sub"]}
os.environ["CLAUDE_CODE_SESSION_ID"] = "sess-sub"
a = reg.caller_drives(rec)
os.environ["CLAUDE_CODE_SESSION_ID"] = "sess-pm"
b = reg.caller_drives(rec)
c = reg.caller_drives(rec, session_id="sess-sub")
print(a, b, c)
EOF
)"
check "False True False" "$OUT"

it "a lease written by a newer auto holds nothing: no capture, no deny"
LEASE="${CLAUDE_AUTO_DATA_DIR}/programmes/leases/default.w2.json"
cp "$LEASE" "${WORK}/lease.bak"
"$PY" - "$LEASE" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1])); d["programme_format"] = 99
json.dump(d, open(sys.argv[1], "w"))
EOF
BEFORE="$(journal_kinds "$RUN")"
OUT1="$(prompt_hook sess-pm "hello")"
OUT2="$(action_hook sess-worker 'herdr agent prompt w2:p31 go')"
AFTER="$(journal_kinds "$RUN")"
if [ -z "$OUT1$OUT2" ] && [ "$BEFORE" = "$AFTER" ]; then pass; else fail "out [$OUT1$OUT2]"; fi
/bin/cp -f "${WORK}/lease.bak" "$LEASE"

it "after the programme ends, sends to the old driver pane are allowed"
run_py "$RUN" <<'EOF' >/dev/null
ph.end_programme(args[0], "test")
EOF
OUT="$(action_hook sess-worker 'herdr agent prompt w2:p31 go')"
check "" "$OUT"

it "the data dir is a file: every hook exits 0 with no output"
export CLAUDE_AUTO_DATA_DIR="${WORK}/datafile"
: > "$CLAUDE_AUTO_DATA_DIR"
OUT="$(prompt_hook sess-pm hi; action_hook sess-worker 'herdr agent prompt w2:p31 go'; FAKE_HERDR_PANE=w2:p31 session_start sess-pm w2:p31)"
RC=$?
check "0:" "${RC}:${OUT}"

it "the data dir is unreadable: the prompt hook exits 0 with no output"
export CLAUDE_AUTO_DATA_DIR="${WORK}/locked"
mkdir -p "${CLAUDE_AUTO_DATA_DIR}/programmes/leases"
: > "${CLAUDE_AUTO_DATA_DIR}/programmes/leases/default.w2.json"
chmod 000 "$CLAUDE_AUTO_DATA_DIR"
OUT="$(prompt_hook sess-pm hi)"
RC=$?
chmod 700 "$CLAUDE_AUTO_DATA_DIR"
check "0:" "${RC}:${OUT}"

it "the data dir is missing: the Python prompt hook exits 0 with no output"
export CLAUDE_AUTO_DATA_DIR="${WORK}/missing"
OUT="$(printf '{"session_id":"sess-pm","prompt":"/auto:programme-end"}' | "$PY" "${AUTO_ROOT}/lib/on-user-prompt.py")"
RC=$?
check "0:" "${RC}:${OUT}"

it "hooks.json wires UserPromptSubmit to the prompt shim with a timeout"
OUT="$("$PY" - "${HOOKS}/hooks.json" <<'EOF'
import json, sys
h = json.load(open(sys.argv[1]))["hooks"]["UserPromptSubmit"][0]["hooks"][0]
print("on-user-prompt.sh" in h["command"], 0 < h["timeout"] <= 10)
EOF
)"
check "True True" "$OUT"

it "the shims and programme_home agree on the default data dir"
DEF="$(sed -n 's/^DEFAULT_DATA_DIR = "~\/\(.*\)"$/\1/p' "${AUTO_ROOT}/lib/programme_home.py")"
N=0
for s in on-user-prompt.sh on-pretooluse-action.sh; do grep -qF "\${HOME:-}/${DEF}" "${HOOKS}/$s" && N=$((N + 1)); done
check "2" "$N"

echo ""
echo "programme-hooks.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
