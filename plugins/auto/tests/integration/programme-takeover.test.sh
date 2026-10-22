#!/usr/bin/env bash
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

echo "programme-takeover.test.sh"

WORK="$(mktemp -d -t auto-programme-takeover.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

for v in $(env | sed -n 's/^\(HERDR_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
unset CLAUDE_CODE_SESSION_ID CLAUDE_AUTO_REPO LINEAR_API_KEY CLAUDE_CODE_ENTRYPOINT 2>/dev/null || true
export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_MACHINE="studio"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_AUTO_SOURCE_TIMEOUT="2"
: > "$CLAUDE_AUTO_SECRETS_FILE"
NOREPO="${WORK}/norepo"
mkdir -p "$NOREPO"

FAKES="${WORK}/fakes"
SNAP="${WORK}/snapshot.json"
DOWN="${WORK}/herdr-down"
mkdir -p "$FAKES"
export SNAP DOWN PY

cat > "${FAKES}/herdr" <<'EOF'
#!/bin/bash
case "$1 ${2:-}" in
  "status server") if [ -e "$DOWN" ]; then echo "status: stopped"; else echo "status: running"; fi ;;
  "api snapshot") cat "$SNAP" ;;
esac
exit 0
EOF
chmod +x "${FAKES}/herdr"
export PATH="${FAKES}:${PATH}"

# panes: "<pane>|<label>|<session or empty>|<terminal>" ...
snapshot() {
  "$PY" - "$SNAP" "$@" <<'PYEOF'
import json, sys
panes = []
for spec in sys.argv[2:]:
    pid, label, sess, term = spec.split("|")
    panes.append({"pane_id": pid, "tab_id": "w2:t1", "workspace_id": "w2", "terminal_id": term,
                  "agent": "claude", "agent_status": "idle", "cwd": "/tmp", "label": label,
                  "agent_session": {"source": "auto", "agent": "claude", "kind": "id", "value": sess} if sess else None})
doc = {"id": "1", "result": {"type": "snapshot", "snapshot": {
    "workspaces": [{"workspace_id": "w2", "label": "Ai Editor"}],
    "tabs": [{"tab_id": "w2:t1", "workspace_id": "w2", "label": "Work"}],
    "panes": panes, "agents": panes}}}
json.dump(doc, open(sys.argv[1], "w"))
PYEOF
}

register() {
  "$PY" - "$AUTO_ROOT" "$1" "$2" "$3" "${4:-w2}" <<'PYEOF'
import os, sys, time
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
sr = load_lib_module("session_registry")
sid, pane, term, ws = sys.argv[2:]
time.sleep(1.1)
sr._append(sr.registry_path("default", ws), {
    "at": load_lib_module("run_record_core").now_iso(), "session_id": sid, "pane_id": pane,
    "terminal_id": term, "tab_id": ws + ":t1", "server": "default", "workspace": ws, "interactive": True})
PYEOF
}

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
ph = load_lib_module("programme_home")
pj = load_lib_module("programme_journal")
args = sys.argv[2:]
sys.path.insert(0, os.path.join(sys.argv[1], "tests", "helpers"))
import programme_records
$(cat)
PYEOF
}

OUT=""
CODE=0
as() {
  local sid="$1"; shift
  OUT="$(CLAUDE_CODE_SESSION_ID="$sid" HERDR_WORKSPACE_ID=w2 "$PY" "$PROG" "$@" 2>&1)"
  CODE=$?
}

typed() {
  ( cd "$NOREPO" && HERDR_WORKSPACE_ID=w2 "$PY" "${AUTO_ROOT}/tests/fixtures/programme_prompts.py" "$AUTO_ROOT" "$1" "$2" 2>/dev/null )
}

# A prompt the runtime did not mark as typed by a human: no transcript source (a background
# event or SDK prompt), or a transcript row from a peer session.
untyped() {
  local sid="$1" text="$2" kind="$3"
  ( cd "$NOREPO" && HERDR_WORKSPACE_ID=w2 "$PY" - "$AUTO_ROOT" "$sid" "$text" "$kind" <<'PYEOF'
import json, os, subprocess, sys
root, sid, text, kind = sys.argv[1:]
sys.path.insert(0, os.path.join(root, "lib"))
sys.path.insert(0, os.path.join(root, "tests", "fixtures"))
import programme_prompts
payload, _, path, row = programme_prompts.fixture(text, sid)
if kind == "background":
    payload.pop("transcript_path")
subprocess.run(["bash", os.path.join(root, ".claude/hooks/on-user-prompt.sh")],
               input=json.dumps(payload), text=True, capture_output=True)
if kind == "peer":
    row.update(origin={"kind": "peer"}, turnOrigin="peer")
path.write_text(json.dumps(row) + "\n")
PYEOF
  )
}

driver_of() {
  run_py "$1" <<'EOF'
print(programme_records.load(args[0]).get("driving_session_id"))
EOF
}

last_entry() {
  run_py "$1" "$2" <<'EOF'
rows = [r for r in pj.read(args[0]) if r["kind"] == args[1]]
print(json.dumps(rows[-1] if rows else None, sort_keys=True))
EOF
}

snapshot "w2:p10|PM|sess-pm|term_p10" "w2:p31|scratch|sess-w2|term_p31"
register sess-pm w2:p10 term_p10

as sess-pm start
RUN="$("$PY" -c 'import json,sys; print(json.loads(sys.stdin.read().splitlines()[0])["run"])' <<< "$OUT")"
as sess-pm propose-agreement
P_ACCEPT="$("$PY" -c '
import json, re, sys
ctx = json.loads(sys.stdin.read())["hookSpecificOutput"]["additionalContext"]
print(json.loads(re.search(r"\{.*\}", ctx).group(0))["prompt_id"])' <<< "$(typed sess-pm 'yes, run it on those terms')")"
as sess-pm accept-agreement --prompt "$P_ACCEPT"

it "setup: the programme is accepted and its lease is live"
check "0 live" "$CODE $(run_py <<'EOF'
print(ph.lease_status(ph.read_lease(ph.lease_path("default", "w2"))))
EOF
)"

it "a plain takeover while the PM pane is open is refused"
typed sess-b '/auto:programme-takeover' >/dev/null
as sess-b takeover
check "1 sess-pm" "$CODE $(driver_of "$RUN")"

it "the refusal names the PM by its pane and tab name"
has 'the PM in pane "PM" in tab "Work" (w2:p10)' "$OUT"

it "the refusal gives the exact reply that replaces it, and what happens either way"
has "To replace it, type: /auto:programme-takeover --replace sess-pm " "$OUT"
has "that PM's next programme write is refused" "$OUT"
has "If you type nothing, that PM keeps driving" "$OUT"

it "the refusal is journaled with the reply"
has "--replace sess-pm" "$(last_entry "$RUN" request_refused)"

it "a replace naming another pane is refused and says so"
typed sess-b '/auto:programme-takeover --replace scratch' >/dev/null
as sess-b takeover --replace scratch
check "1 sess-pm" "$CODE $(driver_of "$RUN")"
has "--replace scratch does not name the current PM" "$OUT"

it "herdr unreachable is not proof the PM is gone, even with its pane missing"
snapshot "w2:p31|scratch|sess-w2|term_p31"
touch "$DOWN"
as sess-b takeover
check "1 sess-pm" "$CODE $(driver_of "$RUN")"
has "herdr could not be read" "$OUT"
rm -f "$DOWN"

it "an open pane on the same terminal that reports no session is not proof either"
snapshot "w2:p10|PM||term_p10"
as sess-b takeover
check "1 sess-pm" "$CODE $(driver_of "$RUN")"
has "does not say which session it runs" "$OUT"

it "a PM pane moved under a new id, same terminal, is not proof it is gone"
snapshot "w2:p77|PM||term_p10"
as sess-b takeover
check "1 sess-pm" "$CODE $(driver_of "$RUN")"
has "pane w2:p77 is still open" "$OUT"

it "with the PM gone, a background-event takeover request is refused"
snapshot "w2:p31|scratch|sess-w2|term_p31"
untyped sess-x '/auto:programme-takeover' background
as sess-x takeover
check "1 sess-pm" "$CODE $(driver_of "$RUN")"
has "no typed takeover request" "$OUT"

it "with the PM gone, a peer-message takeover request is refused"
untyped sess-y '/auto:programme-takeover' peer
as sess-y takeover
check "1 sess-pm" "$CODE $(driver_of "$RUN")"
has "no typed takeover request" "$OUT"

it "with the PM present, an untyped --replace naming it is refused"
snapshot "w2:p10|PM|sess-pm|term_p10"
untyped sess-x '/auto:programme-takeover --replace PM' background
as sess-x takeover --replace PM
check "1 sess-pm" "$CODE $(driver_of "$RUN")"
has "no typed takeover request" "$OUT"

it "a --replace the agent adds without Shawn typing it is refused"
as sess-b takeover --replace PM
check "1 sess-pm" "$CODE $(driver_of "$RUN")"

it "a typed --replace naming the live PM's pane takes over at once"
typed sess-c '/auto:programme-takeover --replace PM' >/dev/null
as sess-c takeover --replace PM
check "0 sess-c" "$CODE $(driver_of "$RUN")"
has 'Took over from the PM in pane "PM" in tab "Work" (w2:p10)' "$OUT"

it "the replace is journaled with its reason and evidence"
ENTRY="$(last_entry "$RUN" taken_over)"
has '"reason": "replaced"' "$ENTRY"
has '"replace_name": "PM"' "$ENTRY"
has '"from_session": "sess-pm"' "$ENTRY"
has '"session_reported": "sess-pm"' "$ENTRY"

it "the replaced PM's next write is refused"
as sess-pm set-now "still sweeping"
check "1" "$CODE"
has "no programme lease names this session" "$OUT"
as sess-pm set-now "still sweeping" --run "$RUN"
check "1" "$CODE"
has "only the programme's driving session" "$OUT"

it "the replaced PM's beat is refused"
as sess-pm beat --run "$RUN"
check "1" "$CODE"
has "only the programme's driving session" "$OUT"

it "the replace request cannot be used twice"
register sess-pm2 w2:p12 term_p12
snapshot "w2:p12|PM 2|sess-pm2|term_p12" "w2:p40|New PM|sess-c|term_p40"
as sess-c takeover
check "1" "$CODE"
has "already holds the lease" "$OUT"

it "a request typed against an earlier PM does not displace a later one"
register sess-c w2:p40 term_p40
snapshot "w2:p31|scratch|sess-w2|term_p31"
as sess-b takeover
check "1 sess-c" "$CODE $(driver_of "$RUN")"
has "no typed takeover request" "$OUT"

it "a typed takeover succeeds at once when the PM's pane is closed"
typed sess-d '/auto:programme-takeover' >/dev/null
as sess-d takeover
check "0 sess-d" "$CODE $(driver_of "$RUN")"
has "pane w2:p40 that ran the driving session is closed" "$OUT"

it "the dead-driver takeover is journaled with its reason and evidence"
ENTRY="$(last_entry "$RUN" taken_over)"
has '"reason": "driver_gone"' "$ENTRY"
has '"pane_in_snapshot": false' "$ENTRY"
has '"herdr_reachable": true' "$ENTRY"
has '"from_session": "sess-c"' "$ENTRY"

it "a typed takeover succeeds when the PM's pane now runs another session"
register sess-d w2:p50 term_p50
snapshot "w2:p50|PM|sess-other|term_p50"
typed sess-e '/auto:programme-takeover' >/dev/null
as sess-e takeover
check "0 sess-e" "$CODE $(driver_of "$RUN")"
has '"reason": "driver_gone"' "$(last_entry "$RUN" taken_over)"

it "a PM that resumed in another workspace is not proven gone by its old pane closing"
register sess-e w2:p60 term_p60
register sess-e w3:p90 term_p90 w3
snapshot "w2:p31|scratch|sess-w2|term_p31" "w3:p90|PM||term_p90"
typed sess-f '/auto:programme-takeover' >/dev/null
as sess-f takeover
check "1 sess-e" "$CODE $(driver_of "$RUN")"
has "pane w3:p90 is still open" "$OUT"

set_beat() {
  run_py "$1" "$2" <<'EOF'
import datetime
rec = programme_records.load(args[0])
t = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=float(args[1]))
rec["loop"]["last_beat_at"] = t.strftime("%Y-%m-%dT%H:%M:%SZ")
programme_records.save(args[0], rec)
EOF
}

it "a request typed while an earlier PM was orphaned does not take over from a later one"
set_beat "$RUN" 3
typed sess-g '/auto:programme-takeover' >/dev/null
set_beat "$RUN" 0
as sess-g takeover
check "1 sess-e" "$CODE $(driver_of "$RUN")"
typed sess-h '/auto:programme-takeover --replace PM' >/dev/null
as sess-h takeover
check "0 sess-h" "$CODE $(driver_of "$RUN")"
typed sess-g '/auto:programme-takeover' >/dev/null
set_beat "$RUN" 3
as sess-g takeover
check "1 sess-h" "$CODE $(driver_of "$RUN")"

as_in() {
  local ws="$1" sid="$2"; shift 2
  OUT="$(CLAUDE_CODE_SESSION_ID="$sid" HERDR_WORKSPACE_ID="$ws" "$PY" "$PROG" "$@" 2>&1)"
  CODE=$?
}

typed_in() {
  ( cd "$NOREPO" && HERDR_WORKSPACE_ID="$1" "$PY" "${AUTO_ROOT}/tests/fixtures/programme_prompts.py" "$AUTO_ROOT" "$2" "$3" 2>/dev/null )
}

set_beat "$RUN" 0
CUR="$(driver_of "$RUN")"
register "$CUR" w2:p70 term_p70
register sess-w5 w5:p1 term_w5 w5
snapshot "w2:p70|PM|${CUR}|term_p70" "w2:p31|scratch|sess-w2|term_p31"

it "a plain takeover from another workspace is refused and names the session-id route"
typed_in w5 sess-w5 '/auto:programme-takeover' >/dev/null
as_in w5 sess-w5 takeover
check "1 $CUR" "$CODE $(driver_of "$RUN")"
has "no programme holds default.w5" "$OUT"
has "--replace <session id>" "$OUT"

it "a replace from another workspace naming a session that drives nothing is refused"
typed_in w5 sess-w5 '/auto:programme-takeover --replace sess-nobody' >/dev/null
as_in w5 sess-w5 takeover --replace sess-nobody
check "1 $CUR" "$CODE $(driver_of "$RUN")"

it "a typed replace naming the live PM's session id takes over from another workspace"
typed_in w5 sess-w5 "/auto:programme-takeover --replace $CUR" >/dev/null
as_in w5 sess-w5 takeover --replace "$CUR"
check "0 sess-w5" "$CODE $(driver_of "$RUN")"

it "the cross-workspace request was journaled under the PM's programme"
has "--replace $CUR" "$(last_entry "$RUN" takeover_request)"

echo
echo "programme-takeover.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
