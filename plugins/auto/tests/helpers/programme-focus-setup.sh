PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
PROG="${AUTO_ROOT}/tests/fixtures/prog_offered.py"
REAL_PROG="${AUTO_ROOT}/lib/programme.py"
opick() { "$PY" "${AUTO_ROOT}/tests/fixtures/offer_pick.py" "$@"; }

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
check() { if [ "$1" = "$2" ]; then pass; else fail "expected [$1] got [$2]"; fi; }
has() { case "$2" in *"$1"*) pass ;; *) fail "expected to find [$1] in [$2]" ;; esac; }
WORK="$(mktemp -d -t auto-programme-focus.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_MACHINE="studio"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_CODE_SESSION_ID="sess-pm"
unset HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_BIN_PATH CLAUDE_AUTO_REPO 2>/dev/null || true
: > "$CLAUDE_AUTO_SECRETS_FILE"

FAKES="${WORK}/fakes"
mkdir -p "$FAKES"
printf '#!/bin/sh\nexit 0\n' > "${FAKES}/board"
CALLS="${WORK}/calls.log"
SNAP="${WORK}/snapshot.json"
: > "$CALLS"
export CALLS SNAP PY CLAUDE_AUTO_TEST_HARNESS=1 CLAUDE_AUTO_SOURCE_TIMEOUT=2 CLAUDE_AUTO_WORKER_WAIT=1
cat > "${FAKES}/herdr" <<'FEOF'
#!/bin/bash
printf 'herdr %s\n' "$*" >> "$CALLS"
case "$1 ${2:-}" in
  "status server")
    [ -n "${FAKE_HERDR_DOWN:-}" ] && exit 1
    echo "status: running" ;;
  "api snapshot") cat "$SNAP" ;;
  "agent list")
    "$PY" -c 'import json,sys; s=json.load(open(sys.argv[1]))["result"]["snapshot"]; print(json.dumps({"id":"1","result":{"type":"agent_list","agents":s["agents"]}}))' "$SNAP" ;;
esac
exit 0
FEOF
cat > "${FAKES}/spinoff" <<'FEOF'
#!/bin/bash
printf 'spinoff %s\n' "$*" >> "$CALLS"
sid=""
while [ $# -gt 0 ]; do
  [ "$1" = "--session-id" ] && sid="$2"
  shift
done
echo "  herdr agent pane: w2:p40 (launched with the brief)"
"$PY" - "$SNAP" "$sid" <<'PYEOF'
import json, sys
path, sid = sys.argv[1:3]
doc = json.load(open(path))
snap = doc["result"]["snapshot"]
pane = {"pane_id": "w2:p40", "tab_id": "w2:t1", "workspace_id": "w2", "terminal_id": "term_p40",
        "agent": "claude", "agent_status": "idle", "cwd": "/tmp", "label": "worker",
        "terminal_title_stripped": "worker",
        "agent_session": {"source": "auto", "agent": "claude", "kind": "id", "value": sid}}
snap["panes"] = [p for p in snap["panes"] if p["pane_id"] != "w2:p40"] + [pane]
snap["agents"] = [p for p in snap["agents"] if p["pane_id"] != "w2:p40"] + [pane]
json.dump(doc, open(path, "w"))
PYEOF
FEOF
chmod +x "${FAKES}"/*
export PATH="${FAKES}:${PATH}"

snapshot() {
  "$PY" - "$SNAP" "$@" <<'PYEOF'
import json, sys
path, specs = sys.argv[1], sys.argv[2:]
def pane(pid, agent, label=None, sess=None):
    return {"pane_id": pid, "tab_id": "w2:t1", "workspace_id": "w2", "terminal_id": "term_" + pid.split(":")[1],
            "agent": agent, "agent_status": "idle" if agent else None, "cwd": "/tmp", "label": label,
            "terminal_title_stripped": None,
            "agent_session": {"source": "auto", "agent": "claude", "kind": "id", "value": sess} if sess else None}
panes = [pane("w2:p10", "claude", "PM", "sess-pm")]
for spec in specs:
    pid, kind = spec.split(":", 2)[:2]
    pid = "w2:" + pid
    panes.append(pane(pid, "claude" if kind == "agent" else None, None, "sess-" + pid.split(":")[1] if kind == "agent" else None))
doc = {"id": "1", "result": {"type": "snapshot", "snapshot": {
    "workspaces": [{"workspace_id": "w2", "label": "Ai Editor"}],
    "tabs": [{"tab_id": "w2:t1", "workspace_id": "w2", "label": "Work"}],
    "panes": panes, "agents": [p for p in panes if p["agent"]]}}}
json.dump(doc, open(path, "w"))
PYEOF
}
snapshot

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
sys.path.insert(0, os.path.join(sys.argv[1], 'tests', 'fixtures'))
from programme_prompts import append_prompt as fixture_prompt
ph = load_lib_module("programme_home")
pj = load_lib_module("programme_journal")
core = load_lib_module("run_record_core")
args = sys.argv[2:]
def record(run):
    return core.read_run_record(ph.home_path(run), run)
$(cat)
PYEOF
}

RUN="$(run_py w2 <<'EOF'
print(ph.create_programme([args[0]], "sess-pm")["run"])
EOF
)"

prompt() {
  run_py "$RUN" "$1" "$2" <<'EOF'
run, origin, text = args
print(fixture_prompt(run, "sess-pm", text, origin)["prompt_id"])
EOF
}

field() {
  run_py "$RUN" "$1" <<'EOF'
run, expr = args
prog = record(run)["programme"]
print(json.dumps(eval(expr), sort_keys=True))
EOF
}

OUT=""
CODE=0
prog() {
  OUT="$("$PY" "$PROG" "$@" 2>&1)"
  CODE=$?
}

NS="mem:g"
mk() {
  local id="$1" size="$2" pane="${3:-}"
  local args=(add-item "${NS}${id}" --title "g${id}" --run "$RUN")
  [ -n "$size" ] && args+=(--size "$size")
  [ -n "$pane" ] && args+=(--pane "w2:${pane}" --terminal-id "term_${pane}" --session "sess-${pane}")
  prog "${args[@]}"
  [ "$CODE" -eq 0 ] || echo "mk failed: $OUT"
}
drop() { prog drop-item "${NS}$1" --reason "test cleanup" --run "$RUN"; }
start() { FAKE_HERDR_DOWN="${DOWN:-}" prog start-worker "${NS}$1" "${@:2}" --run "$RUN" -- --name "w$1"; }
spins() { grep -c '^spinoff' "$CALLS"; }
nops() { run_py "$RUN" <<'EOF2'
pr = load_lib_module("programme_recovery")
print(len(pr.operations(record(args[0])["programme"])))
EOF2
}
gitem() { field "prog['items']['${NS}$1']['$2']"; }
limit() {
  local p; p="$(prompt typed "focus budget $*")"
  prog amend-term focus_budget "$@" --prompt "$p"
  [ "$CODE" -eq 0 ] || echo "limit failed: $OUT"
}

PICKS="${WORK}/transcripts"
mkdir -p "$PICKS"
pickit() {
  run_py "${2:-$RUN}" "$1" "$PICKS" <<'EOF2'
import copy, pathlib, uuid
ps = load_lib_module("programme_pick_source")
fx = [json.loads(l) for l in open(os.path.join(sys.argv[1], "tests/fixtures/askuser_transcript.jsonl"))]
ASK, ANSWER = fx[0], fx[1]
run, answer, folder = args
sid, tid, q = "sess-pm", "toolu_" + uuid.uuid4().hex[:10], "Swap or queue?"
questions = [{"question": q, "header": "Setup", "multiSelect": False,
              "options": [{"label": answer, "description": ""}, {"label": "other", "description": ""}]}]
if answer.startswith("Approve "):
    import subprocess
    made = subprocess.run([sys.executable, os.path.join(sys.argv[1], "lib/programme.py"), "offer", "focus",
                           "--command", answer[len("Approve "):], "--run", run], capture_output=True, text=True)
    with open(os.path.join(folder, "..", "offered.log"), "a") as log:
        log.write("offered\n" if made.returncode == 0 else "refused: " + answer + ": " + made.stderr.replace("\n", " ") + "\n")
    if made.returncode == 0:
        printed = json.loads(made.stdout)
        questions = printed["input"]["questions"]
        q = questions[0]["question"]
        answer = next(o["label"] for o in questions[0]["options"] if o["label"] != printed["decline"])
answers = {q: answer}
from registered_transcript import register
path = register(sid, pathlib.Path(folder) / (sid + ".jsonl"))
ask = copy.deepcopy(ASK); ask.update(uuid="a-" + tid, sessionId=sid)
ask["message"]["content"][0].update(id=tid, input={"questions": questions})
res = copy.deepcopy(ANSWER)
res.update(uuid="u-" + tid, sessionId=sid, sourceToolAssistantUUID="a-" + tid,
           toolUseResult={"questions": [{"question": q}], "answers": answers,
                          "annotations": {q: {"notes": os.environ["PICK_NOTE"]}} if os.environ.get("PICK_NOTE") else {}})
res["message"]["content"][0].update(tool_use_id=tid)
with path.open("a") as stream:
    stream.write(json.dumps(ask) + "\n" + json.dumps(res) + "\n")
source = ps.capture({"transcript_path": str(path), "session_id": sid, "tool_use_id": tid,
                     "tool_response": {"answers": answers}})
print(pj.append_prompt(run, sid, ps.summary(answers), "unknown", source=source)["prompt_id"])
EOF2
}
swap_label() { printf 'Approve swap-item %s %s' "${NS}$1" "${NS}$2"; }
override_label() { printf 'Approve override-focus %s' "${NS}$1"; }
approve_override() { prog override-focus "${NS}$1" --prompt "$(pickit "$(override_label "$1")")" --run "$RUN"; }
