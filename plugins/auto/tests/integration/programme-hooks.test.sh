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
  ( cd "$NOREPO" && HERDR_PANE_ID="${PROMPT_PANE:-}" HERDR_WORKSPACE_ID="${PROMPT_WS:-}" \
    "$PY" "${AUTO_ROOT}/tests/fixtures/programme_prompts.py" "$AUTO_ROOT" "$sid" "$text" )
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

it "a machine with no leases and no repo: a Bash command naming a pane id runs no Python"
rm -f "${WORK}/python-ran"
( cd "$NOREPO" && CLAUDE_AUTO_PYTHON3="$MARKER_PY" bash "${HOOKS}/on-pretooluse-action.sh" <<< '{"session_id":"s0","tool_name":"Bash","tool_input":{"command":"eval herdr agent prompt w2:p31 go"}}' )
if [ ! -e "${WORK}/python-ran" ]; then pass; else fail "python ran"; fi

it "a machine with no leases: the permission shim runs no Python for a denial or a gh run"
rm -f "${WORK}/python-ran"
OUT="$( cd "$NOREPO" && CLAUDE_AUTO_PYTHON3="$MARKER_PY" bash "${HOOKS}/on-permission-event.sh" <<< '{"session_id":"s0","hook_event_name":"PermissionDenied","tool_name":"Bash","tool_input":{"command":"gh pr merge 1"},"reason":"[Merge Without Review] no"}'
        CLAUDE_AUTO_PYTHON3="$MARKER_PY" bash "${HOOKS}/on-permission-event.sh" <<< '{"session_id":"s0","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"gh pr checks 1"}}' )"
RC=$?
if [ ! -e "${WORK}/python-ran" ] && [ "${RC}:${OUT}" = "0:" ]; then pass; else fail "python ran or rc/out ${RC}:${OUT}"; fi

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

it "a driving prompt is captured unknown until its appended source row verifies typed"
OUT="$(prompt_hook sess-pm "please adopt the merge rule")"
ROW="$(run_py "$RUN" <<'EOF'
r = [x for x in pj.read(args[0]) if x["kind"] == "prompt"][-1]
print(r["prompt_id"], pj.prompt_origin(r), r["payload"]["text"], r["session_id"])
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
check "UserPromptSubmit <auto-data> </auto-data> ${PID} unknown" "$CTX"

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

HIDDEN_FORMS=(
  'echo `herdr pane send-text PANE hi`'
  "eval 'herdr pane send-text PANE hi'"
  "echo 'herdr pane run PANE ls' | bash"
  "bash -s <<< 'herdr pane run PANE ls'"
  "python3 -c \"import os; os.system('herdr pane send-text PANE hi')\""
  "ksh -c 'herdr agent prompt PANE hi'"
  "fish -c 'herdr agent prompt PANE hi'"
  "h''erdr pane send-text PANE hi"
  'her\dr pane send-text PANE hi'
  "H=herdr; \$H agent prompt PANE go"
)

it "a send to the PM's pane hidden from the parser is denied and journaled"
ALL=1
for form in "${HIDDEN_FORMS[@]}" "herdr pane send-text w2:p3''1 hi" "eval \"herdr agent prompt w2:p3''1 go\"" 'echo w2:p\31' "eval 'herdr agent prompt term_p31 go'"; do
  c="${form//PANE/w2:p31}"
  OUT="$(action_hook sess-worker "$c")"
  ROW="$(run_py "$RUN" <<'EOF'
r = pj.read(args[0])[-1]
print(r["kind"], r["session_id"])
EOF
)"
  case "$OUT" in *'"deny"'*) ;; *) ALL=0; echo "      not denied: $c" ;; esac
  [ "$ROW" = "blocked_driver_send sess-worker" ] || { ALL=0; echo "      not journaled: $c ($ROW)"; }
  run_py "$RUN" <<'EOF' >/dev/null
pj.append(args[0], "rules_acked", "sess-test", {})
EOF
done
check "1" "$ALL"

it "the same hidden forms sending to a worker pane are allowed"
ALL=1
for form in "${HIDDEN_FORMS[@]}" "herdr agent prompt w2:p310 go" "herdr agent prompt term_p311 go"; do
  c="${form//PANE/w2:p50}"
  OUT="$(action_hook sess-worker "$c")"
  [ -z "$OUT" ] || { ALL=0; echo "      not allowed: $c ($OUT)"; }
done
check "1" "$ALL"

ANSI_FORMS=(
  "herdr pane send-text w2:\$'p31' hi"
  "herdr pane send-text \$'\\x77'2:p31 hi"
  "herdr pane send-text \$'\\167'2:p31 hi"
  "herdr pane send-text \$'w2:\\u0070'31 hi"
  "herdr pane send-text \$\"w2:p31\" hi"
  "herdr pane send-text w2:\$\"p31\" hi"
)

it "a command naming the PM's pane with \$'..' quoting is denied"
ALL=1
for c in "${ANSI_FORMS[@]}" "echo w2:\$'p31'" "herdr pane get \$'\\x77'2:p31"; do
  OUT="$(action_hook sess-worker "$c")"
  case "$OUT" in *'"deny"'*) ;; *) ALL=0; echo "      not denied: $c" ;; esac
done
check "1" "$ALL"

it "the driving session is denied a \$'..' spelled send into its own pane"
ALL=1
for c in "${ANSI_FORMS[@]}"; do
  OUT="$(action_hook sess-pm "${c/pane send-text/agent prompt}")"
  case "$OUT" in *'"deny"'*) ;; *) ALL=0; echo "      not denied: $c" ;; esac
done
check "1" "$ALL"

it "the same \$'..' forms naming a worker pane are allowed"
ALL=1
for c in "${ANSI_FORMS[@]}"; do
  c="${c//p31/p50}"
  c="${c//\'31/\'50}"
  OUT="$(action_hook sess-worker "$c")"
  [ -z "$OUT" ] || { ALL=0; echo "      not allowed: $c ($OUT)"; }
done
check "1" "$ALL"

it "the driving session may name its own pane in a command that sends nothing"
OUT="$(action_hook sess-pm 'herdr pane get w2:p31')$(action_hook sess-pm 'echo "driver is w2:p31"')"
check "" "$OUT"

it "the driving session is still denied a parsed send into its own pane"
OUT="$(action_hook sess-pm 'herdr agent prompt w2:p31 "adopt rule"')"
case "$OUT" in *'"deny"'*) pass ;; *) fail "not denied: $OUT" ;; esac

it "a read-only herdr command naming the PM's pane from another session is denied"
OUT="$(action_hook sess-worker 'herdr pane get w2:p31')"
ROW="$(run_py "$RUN" <<'EOF'
r = pj.read(args[0])[-1]
print(r["kind"], r["payload"]["verb"], r["payload"]["target"])
EOF
)"
case "$OUT" in *'"deny"'*) check "blocked_driver_send None w2:p31" "$ROW" ;; *) fail "not denied: $OUT" ;; esac

it "with a lease and no repo, a Bash command naming the PM's pane reaches Python"
rm -f "${WORK}/python-ran"
( cd "$NOREPO" && CLAUDE_AUTO_PYTHON3="$MARKER_PY" bash "${HOOKS}/on-pretooluse-action.sh" <<< '{"session_id":"s0","tool_name":"Bash","tool_input":{"command":"echo w2:p31"}}' )
if [ -e "${WORK}/python-ran" ]; then pass; else fail "python did not run"; fi

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

it "an expired lease still guards the driver's pane from other sessions"
STAMP="$(run_py "$RUN" <<'EOF'
core = load_lib_module("run_record_core")
seen = {}
def age(rec):
    seen["old"] = json.dumps([rec["programme"].get("created_at"), rec["programme"]["agreement"].get("accepted")])
    rec["programme"]["agreement"]["accepted"] = None
    rec["programme"]["created_at"] = "2000-01-01T00:00:00Z"
core._with_locked_run_record(ph.home_path(args[0]), args[0], age)
lease = dict(ph.iter_leases())["default.w2"]
print(ph.lease_status(lease), seen["old"])
EOF
)"
OUT="$(action_hook sess-worker 'herdr agent prompt w2:p31 go')"
ROW="$(run_py "$RUN" <<'EOF'
r = pj.read(args[0])[-1]
print(r["kind"], r["session_id"])
EOF
)"
case "$STAMP $OUT" in "expired "*'"deny"'*) check "blocked_driver_send sess-worker" "$ROW" ;; *) fail "status/out [$STAMP $OUT]" ;; esac
run_py "$RUN" "${STAMP#expired }" <<'EOF' >/dev/null
core = load_lib_module("run_record_core")
def restore(rec):
    rec["programme"]["created_at"], rec["programme"]["agreement"]["accepted"] = json.loads(args[1])
core._with_locked_run_record(ph.home_path(args[0]), args[0], restore)
EOF

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

session_start_tp() {
  local sid="$1" pane="$2" tp="$3"
  ( cd "$NOREPO" && HERDR_ENV=1 HERDR_PANE_ID="$pane" HERDR_WORKSPACE_ID="${pane%%:*}" CLAUDE_CODE_ENTRYPOINT=cli \
    bash "${HOOKS}/on-session-start.sh" <<< "{\"session_id\":\"$sid\",\"source\":\"startup\",\"cwd\":\"$NOREPO\",\"transcript_path\":\"$tp\"}" ) >/dev/null
}

perm_payload() {
  "$PY" - "$@" <<'EOF'
import json, sys
event, sid, tool, tool_input = sys.argv[1], sys.argv[2], sys.argv[3], json.loads(sys.argv[4])
extra = json.loads(sys.argv[5]) if len(sys.argv) > 5 else {}
payload = {"session_id": sid, "transcript_path": "/forged/by/payload.jsonl", "cwd": "/srv/repo",
           "permission_mode": "auto", "hook_event_name": event, "tool_name": tool,
           "tool_input": tool_input, "tool_use_id": "toolu_01ABC"}
payload.update(extra)
print(json.dumps(payload))
EOF
}

PERM_OUTS=""
perm_hook() {
  local out
  out="$( cd "$NOREPO" && bash "${HOOKS}/on-permission-event.sh" <<< "$1" )"
  PERM_OUTS="${PERM_OUTS}${out}"
}

bash_denial() { perm_payload PermissionDenied "$1" Bash "$(printf '%s' "$2" | "$PY" -c 'import json,sys; print(json.dumps({"command": sys.stdin.read(), "description": "d"}))')" "{\"reason\": $(printf '%s' "$3" | "$PY" -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}"; }
bash_ran() {
  local extra="${4:-}"
  [ -n "$extra" ] || extra='{}'
  perm_payload "$1" "$2" Bash "$(printf '%s' "$3" | "$PY" -c 'import json,sys; print(json.dumps({"command": sys.stdin.read()}))')" "$extra"
}

last_row() {
  run_py "$1" <<'EOF'
r = pj.read(args[0])[-1]
print(json.dumps({"kind": r["kind"], "session_id": r["session_id"], "payload": r["payload"]}, sort_keys=True))
EOF
}

row_field() { local row="$1"; shift; printf '%s' "$row" | "$PY" -c 'import json,sys; d=json.load(sys.stdin); print(*[d["payload"].get(k) if k != "kind" else d["kind"] for k in sys.argv[1:]])' "$@"; }

set_proposals() {
  run_py "$1" "$2" <<'EOF' >/dev/null
core = load_lib_module("run_record_core")
def mutate(rec):
    rec["programme"]["permission_proposals"] = json.loads(args[1])
core._with_locked_run_record(ph.home_path(args[0]), args[0], mutate)
EOF
}

TRANSCRIPTS="${WORK}/transcripts"
mkdir -p "$TRANSCRIPTS"
printf '0123456789' > "${TRANSCRIPTS}/sess-own.jsonl"
DEST="${WORK}/mainrepo"
OTHER="${WORK}/otherrepo"
mkdir -p "${DEST}/.claude" "${OTHER}/.claude"
for s in sess-pm5:p1 sess-own:p2 sess-done:p3 sess-idle:p4 sess-listed:p5; do
  FAKE_HERDR_PANE="w5:${s#*:}" session_start_tp "${s%%:*}" "w5:${s#*:}" "${TRANSCRIPTS}/${s%%:*}.jsonl"
done
RUN5="$(run_py <<'EOF'
print(ph.create_programme(["w5"], "sess-pm5")["run"])
EOF
)"
run_py "$RUN5" <<'EOF' >/dev/null
core = load_lib_module("run_record_core")
def mutate(rec):
    rec["programme"]["items"] = {
        "linear:AI-1": {"id": "linear:AI-1", "title": "waits on Shawn", "state": "waiting",
                        "owner": {"session_id": "sess-own", "pane": "w5:p2"}},
        "linear:AI-2": {"id": "linear:AI-2", "title": "finished", "state": "done",
                        "owner": {"session_id": "sess-done", "pane": "w5:p3"}},
        "linear:AI-3": {"id": "linear:AI-3", "title": "listed", "state": "open",
                        "owner": {"session_id": "sess-other"},
                        "sessions": [{"session_id": "sess-listed"}]},
    }
core._with_locked_run_record(ph.home_path(args[0]), args[0], mutate)
EOF

it "SessionStart records the payload's transcript_path on the session's registry row"
OUT="$(run_py <<'EOF'
print(reg.lookup("sess-own")["transcript_path"])
EOF
)"
check "${TRANSCRIPTS}/sess-own.jsonl" "$OUT"

it "the fixture's items and proposals survive a record write"
set_proposals "$RUN5" "[{\"id\": \"pp1\", \"state\": \"open\", \"destination\": \"${DEST}\"}]"
OUT="$(run_py "$RUN5" <<'EOF'
core = load_lib_module("run_record_core")
p = core.read_run_record(ph.home_path(args[0]), args[0])["programme"]
print(sorted(p["items"]), [x["id"] for x in p["permission_proposals"]])
EOF
)"
check "['linear:AI-1', 'linear:AI-2', 'linear:AI-3'] ['pp1']" "$OUT"

it "a classifier denial from an item owner writes one permission_denied row with layer classifier and the item id"
BEFORE="$(journal_kinds "$RUN5" | wc -w | tr -d ' ')"
perm_hook "$(bash_denial sess-own 'gh pr merge 12 --squash' '[Merge Without Review] merging without review is not allowed')"
AFTER="$(journal_kinds "$RUN5" | wc -w | tr -d ' ')"
ROW="$(last_row "$RUN5")"
check "1 permission_denied classifier ['linear:AI-1'] Bash gh pr merge 12 --squash toolu_01ABC PermissionDenied" \
  "$((AFTER - BEFORE)) $(row_field "$ROW" kind layer item_ids tool command tool_use_id event)"

it "the row's transcript path comes from the registry, with its byte length, never from the payload"
check "${TRANSCRIPTS}/sess-own.jsonl 10" "$(row_field "$ROW" transcript_path transcript_bytes)"
if grep -q "/forged/by/payload" "${CLAUDE_AUTO_DATA_DIR}/programmes/${RUN5}/journal.jsonl"; then
  it "the payload's transcript path never reaches the journal"; fail "payload transcript path journaled"
fi

it "the reason is cleaned and capped at 300"
perm_hook "$(bash_denial sess-own 'gh pr merge 13' "[Merge Without Review] $(printf 'x%.0s' $(seq 1 400))")"
OUT="$(row_field "$(last_row "$RUN5")" reason | "$PY" -c 'import sys; print(len(sys.stdin.read().rstrip("\n")))')"
check "300" "$OUT"

it "no-verdict, unavailable and other reasons map to their layers"
OUT=""
for reason in "Auto mode could not evaluate this action" "Classifier unavailable" "something else denied this"; do
  perm_hook "$(bash_denial sess-pm5 'gh pr checks 3' "$reason")"
  OUT="$OUT $(row_field "$(last_row "$RUN5")" layer)"
done
check " classifier_no_verdict classifier_unavailable unknown" "$OUT"

it "the driving session's denial carries no item ids"
check "[] sess-pm5" "$(row_field "$(last_row "$RUN5")" item_ids) $(last_row "$RUN5" | "$PY" -c 'import json,sys; print(json.load(sys.stdin)["session_id"])')"

it "a listed session of an open item is journaled"
perm_hook "$(bash_denial sess-listed 'gh run view 9' '[Something] no')"
check "permission_denied ['linear:AI-3']" "$(row_field "$(last_row "$RUN5")" kind item_ids)"

it "a session that owns no item and does not drive writes nothing"
BEFORE="$(journal_kinds "$RUN5")"
perm_hook "$(bash_denial sess-idle 'gh pr merge 1' '[Merge Without Review] no')"
check "$BEFORE" "$(journal_kinds "$RUN5")"

it "the owner of a done item writes nothing"
perm_hook "$(bash_denial sess-done 'gh pr merge 1' '[Merge Without Review] no')"
check "$BEFORE" "$(journal_kinds "$RUN5")"

it "a command with a ghp_ token or TOKEN=value is stored redacted"
perm_hook "$(bash_denial sess-own "gh api -H 'Authorization: token ghp_abcdefghijklmnopqrstuvwxyz0123456789' /user" '[X] no')"
perm_hook "$(bash_denial sess-own 'TOKEN=abc123xyz gh pr merge 2' '[X] no')"
J="${CLAUDE_AUTO_DATA_DIR}/programmes/${RUN5}/journal.jsonl"
if grep -q 'ghp_abcdefghij\|abc123xyz' "$J"; then fail "token in journal"; else
  check "TOKEN=[redacted] gh pr merge 2" "$(row_field "$(last_row "$RUN5")" command)"; fi

it "a Write denial stores no file content and an MCP denial stores no arguments"
perm_hook "$(perm_payload PermissionDenied sess-own Write '{"file_path": "/srv/repo/x.txt", "content": "WRITE-BODY-77"}' '{"reason": "[X] no"}')"
W="$(last_row "$RUN5")"
perm_hook "$(perm_payload PermissionDenied sess-own mcp__linear__save_issue '{"body": "MCP-ARG-88"}' '{"reason": "[X] no"}')"
M="$(last_row "$RUN5")"
if grep -q 'WRITE-BODY-77\|MCP-ARG-88\|/srv/repo/x.txt' "$J"; then fail "tool input journaled"; else
  check "permission_denied Write None permission_denied mcp__linear__save_issue None" \
    "$(row_field "$W" kind tool command) $(row_field "$M" kind tool command)"; fi

it "malformed JSON on stdin: exit 0, no row, empty output"
BEFORE="$(journal_kinds "$RUN5")"
OUT="$( cd "$NOREPO" && bash "${HOOKS}/on-permission-event.sh" <<< '{"session_id":"sess-own","hook_event_name":"PermissionDenied", gh' )"
RC=$?
check "0: $BEFORE" "${RC}:${OUT} $(journal_kinds "$RUN5")"

it "with an unresolved proposal, a failed gh pr checks from the owner writes permission_tool_ran"
perm_hook "$(bash_ran PostToolUseFailure sess-own 'gh pr checks 12' '{"error": "Exit code 8 SECRET-OUT-1 ghp_zyxwvutsrqponmlkjihgfedcba9876543210", "is_interrupt": false}')"
ROW="$(last_row "$RUN5")"
check "permission_tool_ran gh pr checks 12 toolu_01ABC PostToolUseFailure ${TRANSCRIPTS}/sess-own.jsonl ['linear:AI-1']" \
  "$(row_field "$ROW" kind command tool_use_id event transcript_path item_ids)"

it "a successful gh run stores no part of tool_response"
perm_hook "$(bash_ran PostToolUse sess-own '/usr/local/bin/gh pr view 12' '{"tool_response": {"stdout": "RESP-OUT-2 ghp_zyxwvutsrqponmlkjihgfedcba9876543210", "stderr": ""}}')"
if grep -q 'SECRET-OUT-1\|RESP-OUT-2\|ghp_zyx' "$J"; then fail "command output journaled"; else
  check "permission_tool_ran PostToolUse" "$(row_field "$(last_row "$RUN5")" kind event)"; fi

it "a gh run from a session outside scope writes nothing"
BEFORE="$(journal_kinds "$RUN5")"
perm_hook "$(bash_ran PostToolUse sess-idle 'gh pr checks 12')"
perm_hook "$(bash_ran PostToolUse sess-done 'gh pr checks 12')"
check "$BEFORE" "$(journal_kinds "$RUN5")"

it "a Bash run without gh writes nothing even when stdin mentions gh elsewhere"
perm_hook "$(bash_ran PostToolUse sess-own 'echo high; ls ./gh/dir' '{"cwd": "/tmp/ghost"}')"
check "$BEFORE" "$(journal_kinds "$RUN5")"

it "a PostToolUse for ls writes nothing and starts no Python"
rm -f "${WORK}/python-ran"
OUT="$( cd "$NOREPO" && CLAUDE_AUTO_PYTHON3="$MARKER_PY" bash "${HOOKS}/on-permission-event.sh" <<< "$(bash_ran PostToolUse sess-own 'ls -la' "{\"cwd\": \"$NOREPO\"}")" )"
if [ ! -e "${WORK}/python-ran" ] && [ -z "$OUT" ]; then pass; else fail "python ran or out [$OUT]"; fi

it "with a lease, a denial reaches Python"
rm -f "${WORK}/python-ran"
( cd "$NOREPO" && CLAUDE_AUTO_PYTHON3="$MARKER_PY" bash "${HOOKS}/on-permission-event.sh" <<< "$(bash_denial sess-own 'ls' '[X] no')" )
if [ -e "${WORK}/python-ran" ]; then pass; else fail "python did not run"; fi

it "with every proposal resolved, or none at all, a gh run writes nothing"
set_proposals "$RUN5" "[{\"id\": \"pp1\", \"state\": \"resolved\", \"destination\": \"${DEST}\"}]"
perm_hook "$(bash_ran PostToolUseFailure sess-own 'gh pr checks 12')"
A="$(journal_kinds "$RUN5")"
run_py "$RUN5" <<'EOF' >/dev/null
core = load_lib_module("run_record_core")
def mutate(rec):
    rec["programme"].pop("permission_proposals", None)
core._with_locked_run_record(ph.home_path(args[0]), args[0], mutate)
EOF
perm_hook "$(bash_ran PostToolUseFailure sess-own 'gh pr checks 12')"
check "$BEFORE $BEFORE" "$A $(journal_kinds "$RUN5")"

it "a denial is journaled with no proposals at all"
perm_hook "$(bash_denial sess-own 'gh pr merge 4' '[X] no')"
check "permission_denied" "$(row_field "$(last_row "$RUN5")" kind)"

it "hook output is always empty and never says retry"
case "$PERM_OUTS" in *retry*) fail "retry in output" ;; *) check "" "$PERM_OUTS" ;; esac

file_call() {
  local dir="$1" sid="$2" tool="$3" input="$4"
  local payload
  payload="$("$PY" -c 'import json,sys; print(json.dumps({"session_id": sys.argv[1], "hook_event_name": "PreToolUse", "cwd": sys.argv[2], "tool_name": sys.argv[3], "tool_input": json.loads(sys.argv[4])}))' "$sid" "$dir" "$tool" "$input")"
  ( cd "$dir" && bash "${HOOKS}/on-pretooluse-action.sh" <<< "$payload" )
}

SETTINGS="${DEST}/.claude/settings.local.json"
GUARDED_CALLS=(
  "Edit|{\"file_path\": \"${SETTINGS}\", \"old_string\": \"a\", \"new_string\": \"b\"}"
  "MultiEdit|{\"file_path\": \"${SETTINGS}\", \"edits\": []}"
  "Write|{\"file_path\": \"${SETTINGS}\", \"content\": \"{}\"}"
  "Write|{\"file_path\": \".claude/settings.local.json\", \"content\": \"{}\"}"
  "Bash|{\"command\": \"echo '{}' > .claude/settings.local.json\"}"
)

it "with a proposal for the repository, an owner's Edit, MultiEdit, Write and echo into its settings.local.json are refused and journaled"
set_proposals "$RUN5" "[{\"id\": \"pp1\", \"state\": \"open\", \"destination\": \"${DEST}\"}]"
ALL=1
for call in "${GUARDED_CALLS[@]}"; do
  OUT="$(file_call "$DEST" sess-own "${call%%|*}" "${call#*|}")"
  ROW="$(last_row "$RUN5")"
  case "$OUT" in *'"deny"'*) ;; *) ALL=0; echo "      not denied: $call ($OUT)" ;; esac
  [ "$(row_field "$ROW" kind tool)" = "blocked_settings_write ${call%%|*}" ] || { ALL=0; echo "      not journaled: $call ($ROW)"; }
done
[ -d "${DEST}/.claude/auto" ] && { ALL=0; echo "      the destination has .claude/auto"; }
check "1" "$ALL"

it "the driving session is refused too, and a resolved proposal still guards"
set_proposals "$RUN5" "[{\"id\": \"pp1\", \"state\": \"resolved\", \"destination\": \"${DEST}\"}]"
OUT="$(file_call "$DEST" sess-pm5 Edit "{\"file_path\": \"${SETTINGS}\", \"old_string\": \"a\", \"new_string\": \"b\"}")"
case "$OUT" in *'"deny"'*) pass ;; *) fail "not denied: $OUT" ;; esac
set_proposals "$RUN5" "[{\"id\": \"pp1\", \"state\": \"open\", \"destination\": \"${DEST}\"}]"

it "the same calls from a session with no item and no driving role are not refused"
OUT=""
for call in "${GUARDED_CALLS[@]}"; do OUT="${OUT}$(file_call "$DEST" sess-idle "${call%%|*}" "${call#*|}")"; done
check "" "$OUT"

it "an owner's edit of settings.json, of a look-alike name, or of a repository with no proposal is not refused"
OUT="$(file_call "$DEST" sess-own Edit "{\"file_path\": \"${DEST}/.claude/settings.json\", \"old_string\": \"a\", \"new_string\": \"b\"}")"
OUT="${OUT}$(file_call "$DEST" sess-own Write "{\"file_path\": \"${SETTINGS}.bak\", \"content\": \"{}\"}")"
OUT="${OUT}$(file_call "$OTHER" sess-own Edit "{\"file_path\": \"${OTHER}/.claude/settings.local.json\", \"old_string\": \"a\", \"new_string\": \"b\"}")"
OUT="${OUT}$(file_call "$OTHER" sess-own Bash "{\"command\": \"echo '{}' > .claude/settings.local.json\"}")"
check "" "$OUT"

it "an Edit of an ordinary file in an auto repository starts no Python"
rm -f "${WORK}/python-ran"
( cd "$TASKREPO" && CLAUDE_AUTO_PYTHON3="$MARKER_PY" bash "${HOOKS}/on-pretooluse-action.sh" <<< "{\"session_id\":\"sess-own\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"${TASKREPO}/a.txt\"}}" )
if [ ! -e "${WORK}/python-ran" ]; then pass; else fail "python ran"; fi

it "an Edit of settings.local.json in an auto repository reaches Python"
rm -f "${WORK}/python-ran"
( cd "$TASKREPO" && CLAUDE_AUTO_PYTHON3="$MARKER_PY" bash "${HOOKS}/on-pretooluse-action.sh" <<< "{\"session_id\":\"sess-own\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"${TASKREPO}/.claude/settings.local.json\"}}" )
if [ -e "${WORK}/python-ran" ]; then pass; else fail "python did not run"; fi

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
for s in on-user-prompt.sh on-pretooluse-action.sh on-permission-event.sh; do grep -qF "\${HOME:-}/${DEF}" "${HOOKS}/$s" && N=$((N + 1)); done
check "3" "$N"

it "hooks.json wires the three permission events to one shim and guards Edit and MultiEdit"
OUT="$("$PY" - "${HOOKS}/hooks.json" <<'EOF'
import json, re, sys
h = json.load(open(sys.argv[1]))["hooks"]
out = []
for event, matcher in (("PermissionDenied", None), ("PostToolUse", "Bash"), ("PostToolUseFailure", "Bash")):
    entry = h[event][0]
    hook = entry["hooks"][0]
    out.append("on-permission-event.sh" in hook["command"] and 0 < hook["timeout"] <= 10
               and entry.get("matcher") == matcher)
action = [e for e in h["PreToolUse"] if "on-pretooluse-action.sh" in e["hooks"][0]["command"]][0]
out.append(all(re.fullmatch(action["matcher"], t) is not None for t in ("Bash", "Write", "Edit", "MultiEdit")))
out.append(re.fullmatch(action["matcher"], "Read") is None)
print(*out)
EOF
)"
check "True True True True True" "$OUT"

echo ""
echo "programme-hooks.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
