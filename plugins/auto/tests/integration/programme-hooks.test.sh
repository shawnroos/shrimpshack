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
it "the secret value never reaches the journal file or the authority"
if grep -rqa "fixture-value-9f8e7d" "${CLAUDE_AUTO_DATA_DIR}/programmes/${RUN}"; then fail "secret found in the programme home"; else pass; fi

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

verb_pm() {
  CLAUDE_CODE_SESSION_ID=sess-pm run_py "$@" <<'EOF'
sys.exit(load_lib_module("programme")._cli(args))
EOF
}
programme_field() {
  run_py "$RUN" "$1" <<'EOF'
prog = load_lib_module("run_record_core").read_run_record(ph.home_path(args[0]), args[0])["programme"]
print(eval(args[1]))
EOF
}
latest_prompt() {
  run_py "$RUN" <<'EOF'
print([x for x in pj.read(args[0]) if x["kind"] == "prompt"][-1]["prompt_id"])
EOF
}
set_cadence_prompt() {
  run_py "$RUN" "$1" <<'EOF' >/dev/null
core = load_lib_module("run_record_core")
def mutate(rec):
    rec["programme"]["watchers"]["cadence"] = {"prompt": args[1]}
core._with_locked_run_record(ph.home_path(args[0]), args[0], mutate)
EOF
}
verb_pm add-item linear:AI-7 --title "Crop approach" --kind fix_only --run "$RUN" >/dev/null
verb_pm hand-item linear:AI-7 --question "Crop on the client or the server?" --kind technical_approach --run "$RUN" >/dev/null
ASK="$(programme_field 'prog["items"]["linear:AI-7"]["handed"]["id"]')"

it "the same correction text journaled as cron records no Ruling"
set_cadence_prompt "that didn't need me"
prompt_hook sess-pm "that didn't need me" >/dev/null
OUT="$(verb_pm record-ruling r-crop --effect grant --scope "crop approach is the PM's" --replies-to "$ASK" --prompt "$(latest_prompt)" --run "$RUN")"
check "False is not typed" "$(programme_field '"r-crop" in ((prog.get("context") or {}).get("decisions") or {})') $(printf '%s' "$OUT" | grep -o 'is not typed' | head -1)"
set_cadence_prompt "sweep the programme now"

it "a typed prompt fed through the prompt hook lets a correcting Ruling hand the kind to the PM"
prompt_hook sess-pm "that didn't need me" >/dev/null
verb_pm record-ruling r-crop --effect grant --scope "crop approach is the PM's" --replies-to "$ASK" --prompt "$(latest_prompt)" --run "$RUN" >/dev/null
check "technical_approach grant accepted that didn't need me" \
  "$(programme_field '" ".join(str(prog["context"]["decisions"]["r-crop"][-1][k]) for k in ("kind", "effect", "state", "quote"))')"

it "/auto:programme-takeover typed in a new session in w2 is journaled as a takeover request in w2's home"
FAKE_HERDR_PANE="w2:p40" session_start sess-new "w2:p40" >/dev/null
OUT="$(prompt_hook sess-new "/auto:programme-takeover")"
ROW="$(run_py "$RUN" <<'EOF'
r = pj.read(args[0])[-1]
print(r["kind"], r["session_id"], r["payload"]["space"], r["payload"]["driving"])
EOF
)"
if [ "$ROW" = "takeover_request sess-new default.w2 False" ] && [ -z "$OUT" ]; then pass; else fail "row [$ROW] out [$OUT]"; fi

askuser_hook() {
  local hook="$1" sid="$2" tool_use_id="$3" prefill="${4:-}"
  local payload
  payload="$("$PY" - "$AUTO_ROOT" "$WORK" "$sid" "$tool_use_id" "$prefill" <<'PYEOF'
import json, pathlib, sys
root, work, sid, tool_use_id, prefill = sys.argv[1:]
ask = json.loads((pathlib.Path(root) / "tests/fixtures/askuser_transcript.jsonl").read_text().splitlines()[0])
ask["message"]["content"][0]["id"] = tool_use_id
path = pathlib.Path(work) / (sid + ".jsonl")
with path.open("a") as stream:
    stream.write(json.dumps(dict(ask, sessionId=sid)) + "\n")
asked = ask["message"]["content"][0]["input"]
answers = {asked["questions"][0]["question"]: asked["questions"][0]["options"][0]["label"]}
print(json.dumps({"session_id": sid, "transcript_path": str(path), "tool_name": "AskUserQuestion",
                  "tool_use_id": tool_use_id, "tool_input": dict(asked, answers=answers) if prefill else asked,
                  "tool_response": {"answers": answers}}))
PYEOF
)"
  ( cd "$NOREPO" && bash "${HOOKS}/${hook}" <<< "$payload" )
}

it "a registered session in w2 that does not drive journals its pick with driving false"
OUT="$(askuser_hook on-posttooluse-askuser.sh sess-new toolu_new)"
ROW="$(run_py "$RUN" <<'EOF'
r = [x for x in pj.read(args[0]) if x["kind"] == "prompt"][-1]
print(r["session_id"], r["payload"]["origin"], r["payload"].get("driving"), r["payload"]["source"]["tool_use_id"])
EOF
)"
check "sess-new unknown False toolu_new" "$ROW"

it "the same non-driving session may not pre-fill a picker"
OUT="$(askuser_hook on-pretooluse-askuser.sh sess-new toolu_new2 prefill)"
check "deny" "$(printf '%s' "$OUT" | "$PY" -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["permissionDecision"])' 2>/dev/null)"

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
if grep -rqa "fixture-value-9f8e7d" "${CLAUDE_AUTO_DATA_DIR}/programmes/${RUN}"; then fail "secret in the programme home"; else pass; fi

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
  "Write|{\"file_path\": \"${DEST}/.claude/SETTINGS.local.json\", \"content\": \"{}\"}"
  "Bash|{\"command\": \"echo x >> \\\"\$GUARD_ROOT/.claude/settings.local.json\\\"\"}"
)
export GUARD_ROOT="$DEST"

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

it "a listed session of an open item is refused too"
OUT="$(file_call "$DEST" sess-listed Edit "{\"file_path\": \"${SETTINGS}\", \"old_string\": \"a\", \"new_string\": \"b\"}")"
case "$OUT" in *'"deny"'*) pass ;; *) fail "not denied: $OUT" ;; esac

# The hook timeout in hooks.json is 10 s; the 9 s cap keeps a hung hook from hanging the suite.
timed_call() {
  local res
  res="$("$PY" - "$HOOKS" "$@" <<'EOF'
import json, subprocess, sys, time
hooks, cwd, sid, tool, tool_input = sys.argv[1:6]
payload = json.dumps({"session_id": sid, "hook_event_name": "PreToolUse", "cwd": cwd,
                      "tool_name": tool, "tool_input": json.loads(tool_input)})
start = time.time()
try:
    p = subprocess.run(["bash", hooks + "/on-pretooluse-action.sh"], input=payload, cwd=cwd,
                       capture_output=True, text=True, timeout=9)
    rc, out = p.returncode, p.stdout.strip()
except subprocess.TimeoutExpired:
    rc, out = "timeout", ""
print(f"{rc} {time.time() - start:.1f}")
print(out)
EOF
)"
  RC="$(printf '%s\n' "$res" | head -1 | cut -d' ' -f1)"
  ELAPSED="$(printf '%s\n' "$res" | head -1 | cut -d' ' -f2)"
  OUT="$(printf '%s\n' "$res" | tail -n +2)"
}

start_writer_paused_at() {
  WRITER_OUT="${WORK}/writer-$1.out"
  : > "$WRITER_OUT"
  env CLAUDE_AUTO_TEST_HARNESS=1 "CLAUDE_AUTO_TEST_STORE_PAUSE_$1=1" "$PY" - "$AUTO_ROOT" "$RUN5" > "$WRITER_OUT" 2>&1 <<'EOF' &
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
ph = load_lib_module("programme_home")
core = load_lib_module("run_record_core")
core._with_locked_run_record(ph.home_path(sys.argv[2]), sys.argv[2], lambda rec: rec.setdefault("hold_probe", 1))
EOF
  WRITER_PID=$!
  for _ in $(seq 1 100); do grep -q '^paused:' "$WRITER_OUT" && return 0; "$PY" -c 'import time; time.sleep(0.1)'; done
  return 1
}

[ -f "${CLAUDE_AUTO_DATA_DIR}/programmes/${RUN5}/programme.db" ] || echo "      fixture: ${RUN5} is not store-backed"
for point in BEFORE_COMMIT AFTER_COMMIT; do
  it "while a writer holds the programme store ($point), an owner's settings write is still denied within 3 s"
  start_writer_paused_at "$point" || fail "the writer never paused: $(head -c 200 "$WRITER_OUT")"
  timed_call "$DEST" sess-own Edit "{\"file_path\": \"${SETTINGS}\", \"old_string\": \"a\", \"new_string\": \"b\"}"
  kill "$WRITER_PID" 2>/dev/null; wait "$WRITER_PID" 2>/dev/null
  case "$OUT" in
    *'"deny"'*) "$PY" -c 'import sys; sys.exit(0 if float(sys.argv[1]) < 3 and sys.argv[2] == "0" else 1)' "$ELAPSED" "$RC" \
                  && pass || fail "rc $RC, denied after ${ELAPSED}s" ;;
    *) fail "rc $RC, no deny after ${ELAPSED}s (writer: $(head -c 200 "$WRITER_OUT")): $OUT" ;;
  esac
done

start_store_lock() {
  LOCKER_OUT="${WORK}/locker.out"
  : > "$LOCKER_OUT"
  "$PY" - "${CLAUDE_AUTO_DATA_DIR}/programmes/${1:-$RUN5}/programme.db" > "$LOCKER_OUT" 2>&1 <<'EOF' &
import sqlite3, sys, time
conn = sqlite3.connect(sys.argv[1], isolation_level=None)
conn.execute("BEGIN EXCLUSIVE")
print("locked", flush=True)
time.sleep(60)
EOF
  LOCKER_PID=$!
  for _ in $(seq 1 100); do grep -q '^locked' "$LOCKER_OUT" && return 0; "$PY" -c 'import time; time.sleep(0.1)'; done
  return 1
}

it "while the programme store cannot be read, the driver's, an owner's and any space session's settings writes (through a symlinked .claude too) and a send to the driver's pane are denied within 3 s"
start_store_lock || fail "the store was never locked: $(head -c 200 "$LOCKER_OUT")"
timed_call "$DEST" sess-own Edit "{\"file_path\": \"${SETTINGS}\", \"old_string\": \"a\", \"new_string\": \"b\"}"
OWN="$OUT|$RC|$ELAPSED"
timed_call "$DEST" sess-pm5 Bash "{\"command\": \"echo '{}' > .claude/settings.local.json\"}"
PM="$OUT|$RC|$ELAPSED"
timed_call "$DEST" sess-idle Write "{\"file_path\": \"${OTHER}/.claude/settings.local.json\", \"content\": \"{}\"}"
IDLE="$OUT|$RC|$ELAPSED"
mkdir -p "${WORK}/realclaude" "${WORK}/linkrepo"
ln -sfn "${WORK}/realclaude" "${WORK}/linkrepo/.claude"
timed_call "$DEST" sess-own Write "{\"file_path\": \"${WORK}/linkrepo/.claude/settings.local.json\", \"content\": \"{}\"}"
LINKED="$OUT|$RC|$ELAPSED"
timed_call "$DEST" sess-own Edit "{\"file_path\": \"${DEST}/.claude/settings.json\", \"old_string\": \"a\", \"new_string\": \"b\"}"
PLAIN="$OUT"
timed_call "$NOREPO" sess-own Bash "{\"command\": \"herdr agent prompt w5:p1 go\"}"
SEND="$OUT|$RC|$ELAPSED"
kill "$LOCKER_PID" 2>/dev/null; wait "$LOCKER_PID" 2>/dev/null
"$PY" - "$OWN" "$PM" "$IDLE" "$SEND" "$LINKED" "$PLAIN" <<'EOF' && pass || fail "own [$OWN] pm [$PM] idle [$IDLE] send [$SEND] linked [$LINKED] settings.json [$PLAIN]"
import sys
def ok_(a):
    out, rc, elapsed = a.rsplit("|", 2)
    return '"deny"' in out and rc == "0" and float(elapsed) < 3
sys.exit(0 if all(ok_(a) for a in sys.argv[1:6]) and sys.argv[6] == "" else 1)
EOF

it "a programme over many spaces with its store held still denies the driver's settings write within 3 s"
RUN6="$(run_py <<'EOF'
print(ph.create_programme([f"w{n}" for n in range(60, 76)], "sess-pm6")["run"])
EOF
)"
start_store_lock "$RUN6" || fail "the store was never locked: $(head -c 200 "$LOCKER_OUT")"
timed_call "$NOREPO" sess-pm6 Bash "{\"command\": \"echo '{}' > ${DEST}/.claude/settings.local.json\"}"
kill "$LOCKER_PID" 2>/dev/null; wait "$LOCKER_PID" 2>/dev/null
case "$OUT" in
  *'"deny"'*) "$PY" -c 'import sys; sys.exit(0 if float(sys.argv[1]) < 3 and sys.argv[2] == "0" else 1)' "$ELAPSED" "$RC" \
                && pass || fail "rc $RC, denied after ${ELAPSED}s" ;;
  *) fail "rc $RC, no deny after ${ELAPSED}s: $OUT" ;;
esac
run_py "$RUN6" <<'EOF' >/dev/null
ph.end_programme(args[0], "test")
EOF

it "when the programme home cannot be read at all, the driver's settings write is denied"
chmod 000 "${CLAUDE_AUTO_DATA_DIR}/programmes/${RUN5}"
timed_call "$DEST" sess-pm5 Edit "{\"file_path\": \"${SETTINGS}\", \"old_string\": \"a\", \"new_string\": \"b\"}"
chmod 700 "${CLAUDE_AUTO_DATA_DIR}/programmes/${RUN5}"
case "$OUT" in *'"deny"'*) pass ;; *) fail "rc $RC after ${ELAPSED}s, not denied: $OUT" ;; esac

it "the same calls from a session with no item and no driving role, or owning only a done item, are not refused"
OUT=""
for call in "${GUARDED_CALLS[@]}"; do OUT="${OUT}$(file_call "$DEST" sess-idle "${call%%|*}" "${call#*|}")"; done
for call in "${GUARDED_CALLS[@]}"; do OUT="${OUT}$(file_call "$DEST" sess-done "${call%%|*}" "${call#*|}")"; done
check "" "$OUT"

it "malformed JSON on stdin: the action hook exits 0 with no output"
OUT="$( cd "$DEST" && bash "${HOOKS}/on-pretooluse-action.sh" <<< '{"session_id":"sess-own","tool_name":"Edit", settings.local.json' )"
check "0:" "$?:${OUT}"

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
for s in on-user-prompt.sh on-pretooluse-action.sh; do grep -qF "\${HOME:-}/${DEF}" "${HOOKS}/$s" && N=$((N + 1)); done
check "2" "$N"

it "hooks.json registers no per-call permission hooks and guards Edit and MultiEdit"
OUT="$("$PY" - "${HOOKS}/hooks.json" <<'EOF'
import json, re, sys
h = json.load(open(sys.argv[1]))["hooks"]
out = [not any(e in h for e in ("PermissionDenied", "PostToolUseFailure"))
       and all(e["matcher"] == "AskUserQuestion" for e in h.get("PostToolUse", []))]
action = [e for e in h["PreToolUse"] if "on-pretooluse-action.sh" in e["hooks"][0]["command"]][0]
out.append(all(re.fullmatch(action["matcher"], t) is not None for t in ("Bash", "Write", "Edit", "MultiEdit")))
out.append(re.fullmatch(action["matcher"], "Read") is None)
print(*out)
EOF
)"
check "True True True" "$OUT"

# ── carry-over offer before the stop ──────────────────────────────────────
stop_hook() {
  ( cd "$NOREPO" && bash "${HOOKS}/on-stop.sh" <<< "{\"session_id\":\"$1\",\"stop_hook_active\":false}" 2>/dev/null )
}
CARRY_RUN="$(run_py <<'EOF'
print(ph.create_programme(["w8"], "sess-carry")["run"])
EOF
)"
it "with nothing to act on and no Ruling, the Stop hook lets the PM stop"
check "" "$(stop_hook sess-carry)"
prompt_hook sess-carry "pw: worker coordination across the programme is yours" >/dev/null
P_CARRY="$(run_py "$CARRY_RUN" <<'EOF'
print([x for x in pj.read(args[0]) if x["kind"] == "prompt"][-1]["prompt_id"])
EOF
)"
CLAUDE_CODE_SESSION_ID=sess-carry run_py record-ruling pw --kind worker_coordination --effect grant \
  --scope "PM coordinates workers" --prompt "$P_CARRY" --run "$CARRY_RUN" <<'EOF' >/dev/null
sys.exit(load_lib_module("programme")._cli(args))
EOF
it "an active Ruling never offered for carry-over holds the stop and names the verb that makes the offer"
OUT="$(stop_hook sess-carry)"
case "$OUT" in *'"decision": "block"'*carry-rulings*|*'"decision":"block"'*carry-rulings*) pass ;; *) fail "got [$OUT]" ;; esac
it "once carry-rulings makes the offer, the Stop hook lets the PM stop with no answer from Shawn"
CLAUDE_CODE_SESSION_ID=sess-carry run_py carry-rulings --run "$CARRY_RUN" <<'EOF' >/dev/null
sys.exit(load_lib_module("programme")._cli(args))
EOF
check "" "$(stop_hook sess-carry)"

echo ""
echo "programme-hooks.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
