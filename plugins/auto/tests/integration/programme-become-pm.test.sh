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

echo "programme-become-pm.test.sh"

WORK="$(mktemp -d -t auto-programme-become-pm.XXXXXX)"
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
  "pane get")
    pane="$3"
    printf '{"id":"cli:pane:get","result":{"pane":{"pane_id":"%s","workspace_id":"%s","terminal_id":"term_%s","tab_id":"w2:t1"}},"type":"pane_info"}\n' \
      "$pane" "${pane%%:*}" "${pane##*:}" ;;
esac
exit 0
EOF
chmod +x "${FAKES}/herdr"
export PATH="${FAKES}:${PATH}"
. "${AUTO_ROOT}/tests/helpers/herdr-pane.sh"

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
  OUT="$(as_pane "$sid" w2 "$PY" "$PROG" "$@" 2>&1)"
  CODE=$?
}

typed() {
  register_session "$1" w2 >/dev/null
  ( cd "$NOREPO" && HERDR_WORKSPACE_ID=w2 "$PY" "${AUTO_ROOT}/tests/fixtures/programme_prompts.py" "$AUTO_ROOT" "$1" "$2" 2>/dev/null )
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

prompts_of() {
  run_py "$1" "$2" <<'EOF'
print(len([r for r in pj.read(args[0]) if r["kind"] == "prompt" and r.get("session_id") == args[1]]))
EOF
}

field() { "$PY" -c 'import json,sys; print(json.loads(sys.stdin.read().splitlines()[0]).get(sys.argv[1]))' "$1" <<< "$OUT"; }

# The space lease and everything in the programme home, hashed: become-pm must leave them byte-identical.
state_hash() {
  ( cat "${CLAUDE_AUTO_DATA_DIR}/programmes/leases/default.w2.json"
    run_py "$1" <<'EOF'
import hashlib, os
home = ph.home_path(args[0])
for root, _, files in sorted(os.walk(home)):
    for name in sorted(files):
        path = os.path.join(root, name)
        print(path, hashlib.sha256(open(path, "rb").read()).hexdigest())
EOF
  ) | shasum | cut -d' ' -f1
}

set_beat() {
  run_py "$1" "$2" <<'EOF'
import datetime
rec = programme_records.load(args[0])
t = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=float(args[1]))
rec["loop"]["last_beat_at"] = t.strftime("%Y-%m-%dT%H:%M:%SZ")
programme_records.save(args[0], rec)
EOF
}

# A picker answered in a session that is not the PM, journaled by the real PostToolUse hook.
# A fourth argument pre-fills the answer in the tool input.
pick() {
  register_session "$1" w2 >/dev/null
  ( cd "$NOREPO" && HERDR_WORKSPACE_ID=w2 "$PY" - "$AUTO_ROOT" "$WORK" "$@" <<'PYEOF'
import json, os, pathlib, re, subprocess, sys, uuid
root, work, sid, answer = sys.argv[1:5]
rows = [json.loads(line) for line in (pathlib.Path(root) / "tests/fixtures/askuser_transcript.jsonl").read_text().splitlines()]
asked, result = rows[0], rows[1]
question = "Who should drive the programme?"
tool_use_id = "toolu_" + uuid.uuid4().hex[:12]
tool_input = {"questions": [{"question": question, "header": "PM", "multiSelect": False,
                             "options": [{"label": answer, "description": "Move the lease here."},
                                         {"label": "Keep the current PM", "description": "Change nothing."}]}]}
if len(sys.argv) > 5:
    tool_input["answers"] = {question: answer}
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

snapshot "w2:p10|PM|sess-pm|term_p10" "w2:p31|scratch|sess-w2|term_p31" "w2:p40|PM|sess-b|term_p40"
register sess-pm w2:p10 term_p10
register sess-b w2:p40 term_p40

it "no lease in the space: become-pm names start"
as sess-pm become-pm
check "0 start" "$CODE $(field step)"
has "/auto:programme" "$OUT"
if [ -e "${CLAUDE_AUTO_DATA_DIR}/programmes/leases/default.w2.json" ]; then fail "become-pm took a lease"; else pass; fi

it "outside a herdr pane: become-pm refuses with step refused and a fix"
OUT="$(CLAUDE_CODE_SESSION_ID=sess-nowhere "$PY" "$PROG" become-pm 2>&1)"; CODE=$?
check "1 refused" "$CODE $(field step)"
has "cannot identify this session's herdr terminal pane" "$OUT"
has "fix: run Claude from a herdr pane" "$OUT"

as sess-pm start
RUN="$(field run)"
as sess-pm propose-agreement
P_ACCEPT="$("$PY" -c '
import json, re, sys
ctx = json.loads(sys.stdin.read())["hookSpecificOutput"]["additionalContext"]
print(json.loads(re.search(r"\{.*\}", ctx).group(0))["prompt_id"])' <<< "$(typed sess-pm 'yes, run it on those terms')")"
as sess-pm accept-agreement --prompt "$P_ACCEPT"
LABEL="Approve takeover --replace sess-pm"
BEFORE="$(state_hash "$RUN")"

it "the caller drives: become-pm names already-pm"
as sess-pm become-pm
check "0 already-pm $RUN" "$CODE $(field step) $(field run)"

it "a live PM held by another session: become-pm names ask-shawn with the exact label and command"
as sess-b become-pm
check "0 ask-shawn" "$CODE $(field step)"
check "$LABEL" "$(field label)"
check "programme.sh takeover --prompt <pick id>" "$(field command)"
has "AskUserQuestion picker" "$OUT"
has "recommended option" "$OUT"
has "decline option" "$OUT"

it "a live PM: another session's typed prompt is not journaled"
typed sess-b "take over as PM" >/dev/null
check "0" "$(prompts_of "$RUN" sess-b)"

it "become-pm writes nothing: the journal, run record and lease are byte-identical"
check "$BEFORE" "$(state_hash "$RUN")"

it "the ask-shawn route works: a pick of the printed label, cited as printed, moves the lease"
P="$(pick sess-b "$LABEL (Recommended)")"
as sess-b become-pm
CMD="$(field command)"
CMD="${CMD#programme.sh }"
read -ra PARTS <<< "${CMD/<pick id>/$P}"
as sess-b "${PARTS[@]}"
check "0 sess-b" "$CODE $(driver_of "$RUN")"

it "AE7: the replaced PM's next write refuses with the become-pm fix"
as sess-pm beat --run "$RUN"
check "1" "$CODE"
has "fix: programme.sh become-pm" "$OUT"

it "AE7: become-pm tells the replaced PM to stand down, without messaging Shawn"
BEFORE="$(state_hash "$RUN")"
as sess-pm become-pm
check "0 stand-down" "$CODE $(field step)"
has "CronDelete" "$OUT"
has "Do not message Shawn" "$OUT"
check "$BEFORE" "$(state_hash "$RUN")"

register sess-b w2:p40 term_p40
snapshot "w2:p31|scratch|sess-w2|term_p31"
set_beat "$RUN" 0

it "a live lease whose driver herdr shows gone: become-pm names ask-shawn with the exact label"
as sess-c become-pm
check "0 ask-shawn gone Approve takeover --replace sess-b" "$CODE $(field step) $(field presence) $(field label)"

snapshot "w2:p40|PM|sess-b|term_p40" "w2:p31|scratch|sess-w2|term_p31"
set_beat "$RUN" 3

it "an orphaned lease whose PM herdr still shows: become-pm names ask-shawn"
as sess-c become-pm
check "0 ask-shawn Approve takeover --replace sess-b" "$CODE $(field step) $(field label)"

snapshot "w2:p31|scratch|sess-w2|term_p31"
register sess-c w2:p45 term_p45

it "an orphaned lease: become-pm names ask-shawn with the exact label, and writes nothing"
BEFORE="$(state_hash "$RUN")"
as sess-c become-pm
check "0 ask-shawn orphaned Approve takeover --replace sess-b" "$CODE $(field step) $(field lease_status) $(field label)"
check "programme.sh takeover --prompt <pick id>" "$(field command)"
has "AskUserQuestion picker" "$OUT"
check "$BEFORE" "$(state_hash "$RUN")"

it "an orphaned lease: another session's typed prompt is not journaled, so it cannot be cited"
CTX="$(typed sess-c "take over as PM")"
check "" "$CTX"
check "0" "$(prompts_of "$RUN" sess-c)"

it "a refused takeover's fix is the takeover picker, not become-pm"
as sess-c takeover --prompt p000000
check "1 sess-b" "$CODE $(driver_of "$RUN")"
FIX="$(printf '%s\n' "$OUT" | sed -n 's/^fix: //p' | tail -n 1)"
case "$FIX" in "programme.sh become-pm"*) fail "the fix loops back to become-pm: $FIX" ;; *) pass ;; esac
it "following that fix prints the label become-pm printed"
LABEL_CMD="$(printf '%s' "$FIX" | sed -n 's/^run `programme.sh \([^`]*\)`.*/\1/p')"
read -ra PARTS <<< "$LABEL_CMD"
as sess-c "${PARTS[@]}"
check "0 Approve takeover --replace sess-b" "$CODE $OUT"

it "the ask-shawn route works for a stopped PM: a pick of the label, through the real hook, moves the lease"
P="$(pick sess-c "Approve takeover --replace sess-b (Recommended)")"
as sess-c become-pm
CMD="$(field command)"
CMD="${CMD#programme.sh }"
read -ra PARTS <<< "${CMD/<pick id>/$P}"
as sess-c "${PARTS[@]}"
check "0 sess-c" "$CODE $(driver_of "$RUN")"
ENTRY="$(last_entry "$RUN" taken_over)"
has '"reason": "orphaned"' "$ENTRY"
has '"request": null' "$ENTRY"
has "\"prompt_id\": \"$P\"" "$ENTRY"
case "$ENTRY" in *unrequested*) fail "a picked takeover is not unrequested" ;; *) pass ;; esac

it "once this session drives, the same pick cannot serve an approval gate other than takeover"
as sess-c rules --ack
as sess-c adopt-rule r1 --prompt "$P"
check "1" "$CODE"
has "before this session drove the programme" "$OUT"

snapshot "w2:p45|New PM|sess-c|term_p45" "w2:p31|scratch|sess-w2|term_p31"

it "the PM it replaced is told to stand down while its successor is live"
as sess-b become-pm
check "0 stand-down" "$CODE $(field step)"
it "the stand-down line says how to find the wake-ups to cancel"
has "CronList" "$OUT"
has "TaskStop each Monitor task id" "$OUT"

snapshot "w2:p31|scratch|sess-w2|term_p31"
set_beat "$RUN" 3

it "a former PM whose successor went orphaned gets ask-shawn, not stand-down"
as sess-b become-pm
check "0 ask-shawn Approve takeover --replace sess-c" "$CODE $(field step) $(field label)"

it "an unreadable run record: become-pm refuses with step refused and a fix"
LEASE_FILE="${CLAUDE_AUTO_DATA_DIR}/programmes/leases/default.w2.json"
cp -f "$LEASE_FILE" "${WORK}/lease.bak"
"$PY" -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["home"]="/nonexistent/home"; json.dump(d, open(p, "w"))' "$LEASE_FILE"
as sess-d become-pm
check "1 refused" "$CODE $(field step)"
has "run record could not be read" "$OUT"
has "fix: " "$OUT"
cp -f "${WORK}/lease.bak" "$LEASE_FILE"

echo
echo "programme-become-pm.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
