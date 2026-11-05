PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
PROG="${AUTO_ROOT}/tests/fixtures/prog_offered.py"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
check() { if [ "$1" = "$2" ]; then pass; else fail "expected [$1] got [$2]"; fi; }
has() { case "$2" in *"$1"*) pass ;; *) fail "expected to find [$1] in [$2]" ;; esac; }
lacks() { case "$2" in *"$1"*) fail "did not expect [$1] in [$2]" ;; *) pass ;; esac; }

WORK="$(mktemp -d -t auto-programme-sources.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_MACHINE="studio"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_CODE_SESSION_ID="sess-pm"
export CLAUDE_AUTO_SOURCE_TIMEOUT="2"
export CLAUDE_AUTO_WORKER_WAIT="1"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
EMPTY_SHIPPED="${WORK}/files/shipped-empty"
EMPTY_PERSONAL="${WORK}/files/personal-empty"
mkdir -p "$EMPTY_SHIPPED" "$EMPTY_PERSONAL"
export CLAUDE_AUTO_SHIPPED_BEHAVIOURS_DIR="$EMPTY_SHIPPED"
export CLAUDE_AUTO_BEHAVIOURS_DIR="$EMPTY_PERSONAL"
unset HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_BIN_PATH HERDR_ENV CLAUDE_AUTO_REPO LINEAR_API_KEY 2>/dev/null || true
: > "$CLAUDE_AUTO_SECRETS_FILE"

FAKES="${WORK}/fakes"
CALLS="${WORK}/calls.log"
SNAP="${WORK}/snapshot.json"
mkdir -p "$FAKES"
export CALLS SNAP PY

cat > "${FAKES}/herdr" <<'EOF'
#!/bin/bash
printf 'herdr %s\n' "$*" >> "$CALLS"
case "$1 ${2:-}" in
  "status server")
    [ -n "${FAKE_HERDR_DOWN:-}" ] && exit 1
    echo "status: running"; echo "version: 0.9.3" ;;
  "api snapshot")
    [ -n "${FAKE_HERDR_SLEEP:-}" ] && sleep "$FAKE_HERDR_SLEEP"
    cat "$SNAP" ;;
  "agent list")
    "$PY" -c 'import json,sys; s=json.load(open(sys.argv[1]))["result"]["snapshot"]; print(json.dumps({"id":"1","result":{"type":"agent_list","agents":s["agents"]}}))' "$SNAP" ;;
  "agent prompt")
    exit "${FAKE_PROMPT_EXIT:-0}" ;;
esac
exit 0
EOF

cat > "${FAKES}/board" <<'EOF'
#!/bin/bash
printf 'board %s\n' "$*" >> "$CALLS"
if [ -n "${FAKE_BOARD_JSON:-}" ]; then cat "$FAKE_BOARD_JSON"; exit 0; fi
if [ -n "${FAKE_BOARD_OUTAGE:-}" ]; then echo "board: linear request failed: connection reset" >&2; exit 2; fi
echo '{"error":{"code":7,"message":"plugin op unsupported: work plugin 0.6.1 has no bin/work-snapshot.sh"}}'
exit 1
EOF

cat > "${FAKES}/curl" <<'EOF'
#!/bin/bash
printf 'curl %s\n' "$*" >> "$CALLS"
cat > "${CALLS}.curlconfig"
[ -n "${FAKE_CURL_EXIT:-}" ] && exit "$FAKE_CURL_EXIT"
cat "$FAKE_LINEAR_JSON"
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
if [ -n "${FAKE_SPINOFF_AGENT:-}" ]; then
  "$PY" - "$SNAP" "$sid" <<'PYEOF'
import json, sys
path, sid = sys.argv[1], sys.argv[2]
doc = json.load(open(path))
snap = doc["result"]["snapshot"]
pane = {"pane_id": "w2:p40", "tab_id": "w2:t3", "workspace_id": "w2", "terminal_id": "term_p40",
        "agent": "claude", "agent_status": "idle", "cwd": "/tmp", "label": "worker",
        "terminal_title_stripped": "worker",
        "agent_session": {"source": "auto", "agent": "claude", "kind": "id", "value": sid}}
snap["panes"].append(pane)
snap["agents"].append(pane)
json.dump(doc, open(path, "w"))
PYEOF
fi
exit "${FAKE_SPINOFF_EXIT:-0}"
EOF
chmod +x "${FAKES}"/*
export PATH="${FAKES}:${PATH}"

REPO_BRANCH="${WORK}/wt/ai-753"
mkdir -p "$REPO_BRANCH"
( cd "$REPO_BRANCH" && git init -q && git checkout -q -b ai-753-shot-kinds ) || echo "git setup failed"
PLAIN_DIR="${WORK}/wt/plain"
mkdir -p "$PLAIN_DIR"

write_snapshot() {
  "$PY" - "$SNAP" "$REPO_BRANCH" "$PLAIN_DIR" "$1" <<'PYEOF'
import json, sys
path, branch_dir, plain_dir, variant = sys.argv[1:5]
def pane(pid, **kw):
    out = {"pane_id": pid, "tab_id": "w2:t1", "workspace_id": pid.split(":")[0],
           "terminal_id": "term_" + pid.split(":")[1], "agent": None, "agent_status": "unknown",
           "cwd": plain_dir, "label": None, "terminal_title_stripped": None, "agent_session": None}
    out.update(kw)
    return out
def sess(value):
    return {"source": "auto", "agent": "claude", "kind": "id", "value": value}
panes = [
    pane("w2:p1", label="Sidebar"),
    pane("w2:p2"),
    pane("w2:p10", agent="claude", agent_status="idle", label="PM", agent_session=sess("sess-pm")),
    pane("w2:p11", agent="claude", agent_status="idle", label="Linear: AI Editor"),
    pane("w2:p30", agent="claude", agent_status="working", cwd=branch_dir,
         terminal_title_stripped="Shot kinds \x1b]0;evil\x07\x1b[31mred\x1b[0m"),
    pane("w2:p31", agent="claude", agent_status="idle", terminal_title_stripped="Claude Code"),
    pane("w9:p5", agent="claude", agent_status="idle", cwd=branch_dir),
]
if variant == "fork":
    panes[4]["agent_session"] = sess("sess-fork")
if variant == "owned":
    panes[4]["agent_session"] = sess("sess-w1")
if variant == "exited":
    panes[5]["agent"] = None
if variant == "utf":
    panes[5]["terminal_title_stripped"] = "fix UTF-8 parsing"
if variant == "reused":
    panes[5]["terminal_id"] = "term_new"
agents = [p for p in panes if p["agent"]]
doc = {"id": "1", "result": {"type": "snapshot", "snapshot": {
    "workspaces": [{"workspace_id": "w2", "label": "Ai Editor"}, {"workspace_id": "w9", "label": "Other"}],
    "tabs": [{"tab_id": "w2:t1", "workspace_id": "w2", "label": "Work"}],
    "panes": panes, "agents": agents}}}
json.dump(doc, open(path, "w"))
PYEOF
}

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
ph = load_lib_module("programme_home")
pj = load_lib_module("programme_journal")
core = load_lib_module("run_record_core")
args = sys.argv[2:]
def record(run):
    return core.read_run_record(ph.home_path(run), run)
$(cat)
PYEOF
}

RUN="$(run_py <<'EOF'
print(ph.create_programme(["w2"], "sess-pm")["run"])
EOF
)"
HOME_DIR="${CLAUDE_AUTO_DATA_DIR}/programmes/${RUN}"

field() {
  run_py "$RUN" "$1" <<'EOF'
run, expr = args
rec = record(run)
prog = rec["programme"]
items = prog["items"]
print(json.dumps(eval(expr), sort_keys=True))
EOF
}

journal_last() {
  run_py "$RUN" "$1" <<'EOF'
rows = [r for r in pj.read(args[0]) if r["kind"] == args[1]]
print(json.dumps(rows[-1] if rows else None, sort_keys=True))
EOF
}

journal_count() {
  run_py "$RUN" "$1" <<'EOF'
print(len([r for r in pj.read(args[0]) if r["kind"] == args[1]]))
EOF
}

source_count() {
  run_py "$RUN" "$1" <<'EOF'
print(len([r for r in pj.read(args[0]) if r["kind"] == "source_changed" and r["payload"]["source"] == args[1]]))
EOF
}

registry_line() {
  run_py "$@" <<'EOF'
sid, pane, terminal = args
folder = os.path.join(os.environ["CLAUDE_AUTO_DATA_DIR"], "sessions")
os.makedirs(folder, exist_ok=True)
row = {"at": "2026-10-07T09:00:00Z", "session_id": sid, "pane_id": pane, "terminal_id": terminal,
       "server": "default", "workspace": "w2", "interactive": True, "cwd": "/tmp/" + sid}
with open(os.path.join(folder, "default.w2.jsonl"), "a") as fh:
    fh.write(json.dumps(row) + "\n")
EOF
}

jq_py() {
  "$PY" -c "import json,sys; d=json.loads(sys.stdin.read()); print(json.dumps($1, sort_keys=True))" <<< "$OUT" 2>&1
}

OUT=""
CODE=0
CRASHES=""
prog() {
  OUT="$("$PY" "$PROG" "$@" 2>&1)"
  CODE=$?
  case "$OUT" in *Traceback*) CRASHES="${CRASHES}$* | " ;; esac
}
calls() { cat "$CALLS" 2>/dev/null; }

seed_behaviours() {
  run_py "$RUN" "$1" <<'EOF' >/dev/null
run, spec = args
def body(rec):
    rec["programme"] = ph.normalize_programme(rec["programme"])
    rec["programme"]["behaviours"] = [b for b in rec["programme"]["behaviours"] if b["id"] not in {e["id"] for e in json.loads(spec)}]
    rec["programme"]["behaviours"] += json.loads(spec)
core._with_locked_run_record(ph.home_path(run), run, body)
EOF
}
