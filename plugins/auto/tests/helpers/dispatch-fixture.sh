# Sourced by the U6 dispatch/recovery tests: a programme home plus fake herdr and spinoff.
# No real herdr, spinoff or tracker ever runs: PATH puts the fakes first and every call is logged.
# Needs AUTO_ROOT, PY and WORK set by the caller.

PROG="${AUTO_ROOT}/lib/programme.py"
PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
check() { if [ "$1" = "$2" ]; then pass; else fail "expected [$1] got [$2]"; fi; }
has() { case "$2" in *"$1"*) pass ;; *) fail "expected to find [$1] in [$2]" ;; esac; }
lacks() { case "$2" in *"$1"*) fail "did not expect [$1] in [$2]" ;; *) pass ;; esac; }

export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_MACHINE="studio"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_CODE_SESSION_ID="sess-pm"
export CLAUDE_AUTO_SOURCE_TIMEOUT="2"
export CLAUDE_AUTO_WORKER_WAIT="1"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
export CLAUDE_AUTO_TEST_HARNESS=1
unset HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_BIN_PATH HERDR_ENV CLAUDE_AUTO_REPO LINEAR_API_KEY 2>/dev/null || true
: > "$CLAUDE_AUTO_SECRETS_FILE"

FAKES="${WORK}/fakes"
CALLS="${WORK}/calls.log"
SNAP="${WORK}/snapshot.json"
mkdir -p "$FAKES"
: > "$CALLS"
export CALLS SNAP PY WORK

cat > "${FAKES}/herdr" <<'EOF'
#!/bin/bash
printf 'herdr %s\n' "$*" >> "$CALLS"
case "$1 ${2:-}" in
  "status server") echo "status: running" ;;
  "api snapshot") cat "$SNAP" ;;
  "agent list")
    "$PY" -c 'import json,sys; s=json.load(open(sys.argv[1]))["result"]["snapshot"]; print(json.dumps({"id":"1","result":{"type":"agent_list","agents":s["agents"]}}))' "$SNAP" ;;
  "agent prompt") exit "${FAKE_PROMPT_EXIT:-0}" ;;
esac
exit 0
EOF

cat > "${FAKES}/spinoff" <<'EOF'
#!/bin/bash
printf 'spinoff %s\n' "$*" >> "$CALLS"
sid=""
while [ $# -gt 0 ]; do
  [ "$1" = "--session-id" ] && sid="$2"
  shift
done
echo "  herdr agent pane: w2:p40 (launched with the brief)"
[ -n "${FAKE_SPINOFF_AGENT:-}" ] && "$PY" "${WORK}/add_agent.py" "$SNAP" "$sid"
exit "${FAKE_SPINOFF_EXIT:-0}"
EOF
chmod +x "${FAKES}"/*
export PATH="${FAKES}:${PATH}"

cat > "${WORK}/add_agent.py" <<'EOF'
import json, sys
path, sid = sys.argv[1], sys.argv[2]
doc = json.load(open(path))
snap = doc["result"]["snapshot"]
pane = {"pane_id": "w2:p40", "tab_id": "w2:t1", "workspace_id": "w2", "terminal_id": "term_p40",
        "agent": "claude", "agent_status": "idle", "cwd": "/tmp", "label": "worker",
        "terminal_title_stripped": "worker",
        "agent_session": {"source": "auto", "agent": "claude", "kind": "id", "value": sid}}
snap["panes"] = [p for p in snap["panes"] if p["pane_id"] != "w2:p40"] + [pane]
snap["agents"] = [p for p in snap["agents"] if p["pane_id"] != "w2:p40"] + [pane]
json.dump(doc, open(path, "w"))
EOF

# write_snapshot [base|reused]: the PM pane and one worker pane (w2:p30, session sess-w1).
write_snapshot() {
  "$PY" - "$SNAP" "${1:-base}" <<'PYEOF'
import json, sys
path, variant = sys.argv[1:3]
def sess(value):
    return {"source": "auto", "agent": "claude", "kind": "id", "value": value}
def pane(pid, **kw):
    out = {"pane_id": pid, "tab_id": "w2:t1", "workspace_id": "w2", "terminal_id": "term_" + pid.split(":")[1],
           "agent": "claude", "agent_status": "idle", "cwd": "/tmp", "label": None,
           "terminal_title_stripped": None, "agent_session": None}
    out.update(kw)
    return out
panes = [pane("w2:p10", label="PM", agent_session=sess("sess-pm")),
         pane("w2:p30", agent_session=sess("sess-w1"))]
if variant == "reused":
    panes[1]["terminal_id"] = "term_new"
doc = {"id": "1", "result": {"type": "snapshot", "snapshot": {
    "workspaces": [{"workspace_id": "w2", "label": "Ai Editor"}],
    "tabs": [{"tab_id": "w2:t1", "workspace_id": "w2", "label": "Work"}],
    "panes": panes, "agents": [p for p in panes if p["agent"]]}}}
json.dump(doc, open(path, "w"))
PYEOF
}

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
sys.path.insert(0, os.path.join(sys.argv[1], "tests", "helpers"))
sys.path.insert(0, os.path.join(sys.argv[1], "tests", "fixtures"))
from _bootstrap import load_lib_module
from programme_prompts import append_prompt as fixture_prompt
ph = load_lib_module("programme_home")
pj = load_lib_module("programme_journal")
core = load_lib_module("run_record_core")
pr = load_lib_module("programme_recovery")
args = sys.argv[2:]
def record(run):
    return core.read_run_record(ph.home_path(run), run)
$(cat)
PYEOF
}

new_programme() {
  run_py "$1" "${2:-sess-pm}" <<'EOF'
print(ph.create_programme([args[0]], args[1])["run"])
EOF
}

OUT=""
CODE=0
CRASHES=""
prog() {
  OUT="$("$PY" "$PROG" "$@" 2>&1)"
  CODE=$?
  case "$OUT" in *Traceback*) CRASHES="${CRASHES}$* | " ;; esac
}
# pyget '<json>' '<python expression over d>' — the first JSON object line of the text
pyget() {
  "$PY" - "$1" "$2" <<'EOF' 2>&1
import json, sys
text, expr = sys.argv[1], sys.argv[2]
start = text.find("{")
d = json.JSONDecoder().raw_decode(text[start:])[0] if start >= 0 else None
v = eval(expr)
print(v if isinstance(v, str) else json.dumps(v, sort_keys=True))
EOF
}
calls_of() { grep -c "^$1" "$CALLS" 2>/dev/null || true; }
field() {
  run_py "$1" "$2" <<'EOF'
run, expr = args
prog = record(run)["programme"]
items = prog["items"]
ops = prog.get("operations") or {}
v = eval(expr)
print(v if isinstance(v, str) else json.dumps(v, sort_keys=True))
EOF
}
unreconciled() {
  run_py "$1" <<'EOF'
print(json.dumps(sorted(u["attempt"] for u in pr.unreconciled_for(args[0]))))
EOF
}
revision() {
  run_py "$1" <<'EOF'
print(load_lib_module("programme_authority").snapshot(args[0])["revision"])
EOF
}
end_programme() {
  run_py "$1" <<'EOF'
ph.end_programme(args[0], "ended_by_shawn")
print("ended")
EOF
}
# move_owner <run> <from> <to>: the lifecycle's own takeover/handover commit.
move_owner() {
  run_py "$1" "$2" "$3" <<'EOF'
run, old, new = args
load_lib_module("programme_lifecycle")._move(run, new, "handed_over", old, lambda moved, rec: {})
print("moved")
EOF
}
# bg <outfile> "<env assignments>" <programme.py args...>: run a dispatcher in the background.
bg() {
  local out="$1" hatch="$2"
  shift 2
  # shellcheck disable=SC2086 # the assignments are deliberately split into words
  env $hatch "$PY" "$PROG" "$@" > "$out" 2>&1 &
  BG=$!
}
wait_for() {
  local i
  for i in $(seq 1 150); do
    grep -q "$2" "$1" 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}
resume() { touch "${CLAUDE_AUTO_DATA_DIR}/programmes/$1/.test-resume-dispatch"; }

# use_host_fake <host>: replace that host's fake in FAKES with the fixture-backed one (host-fakes.sh).
use_host_fake() {
  . "${AUTO_ROOT}/tests/helpers/host-fakes.sh"
  host_fake_install "$1" "$FAKES"
}
