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
  "pane get")
    pane="$3"
    [ "${pane##*:}" = pGHOST ] && exit 1
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
register sess-h w2:p77 term_p77
typed sess-h '/auto:programme-takeover --replace PM' >/dev/null
as sess-h takeover
check "0 sess-h" "$CODE $(driver_of "$RUN")"
snapshot "w2:p77|PM|sess-h|term_p77" "w2:p31|scratch|sess-w2|term_p31"
typed sess-g '/auto:programme-takeover' >/dev/null
set_beat "$RUN" 3
as sess-g takeover
check "1 sess-h" "$CODE $(driver_of "$RUN")"

as_in() {
  local ws="$1" sid="$2"; shift 2
  OUT="$(as_pane "$sid" "$ws" "$PY" "$PROG" "$@" 2>&1)"
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

# A picker answered in a session that is not the PM, journaled by the real PostToolUse hook.
# A fourth argument pre-fills the answer in the tool input.
pick() {
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

# A typed prompt from a session that is not the PM, journaled hours_ago with a verifiable transcript.
ask() {
  ( cd "$NOREPO" && "$PY" - "$AUTO_ROOT" "$RUN" "$@" <<'PYEOF'
import datetime, json, os, sys
root, run, sid, text, hours = sys.argv[1:]
sys.path.insert(0, os.path.join(root, "lib"))
sys.path.insert(0, os.path.join(root, "tests", "fixtures"))
import programme_prompts
from _bootstrap import load_lib_module
_, source, path, row = programme_prompts.fixture(text, sid)
now = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=float(hours))
entry = load_lib_module("programme_journal").append_prompt(run, sid, text, "typed", now=now, source=source,
                                                            driving=False)
path.write_text(json.dumps(row) + "\n")
print(entry["prompt_id"])
PYEOF
  )
}

# An accepted Claude Code suggestion from a session that is not the PM, journaled now.
suggested() {
  ( cd "$NOREPO" && "$PY" - "$AUTO_ROOT" "$RUN" "$@" <<'PYEOF'
import json, os, sys
root, run, sid, text = sys.argv[1:]
sys.path.insert(0, os.path.join(root, "lib"))
sys.path.insert(0, os.path.join(root, "tests", "fixtures"))
import programme_prompts
from _bootstrap import load_lib_module
_, source, path, row = programme_prompts.fixture(text, sid, "suggestion_accepted")
entry = load_lib_module("programme_journal").append_prompt(run, sid, text, "typed", source=source, driving=False)
path.write_text(json.dumps(row) + "\n")
print(entry["prompt_id"])
PYEOF
  )
}

D="$(driver_of "$RUN")"
register "$D" w2:p80 term_p80
snapshot "w2:p80|PM|${D}|term_p80" "w2:p31|scratch|sess-w2|term_p31"
set_beat "$RUN" 0
LABEL="Approve takeover --replace $D"

it "approval-label takeover --replace prints the exact label the pick route checks"
as sess-p approval-label takeover --replace "$D"
check "0 $LABEL" "$CODE $OUT"

it "a pick answering the other option is refused, and its fix offers the takeover picker"
P="$(pick sess-p "Keep the current PM")"
as sess-p takeover --prompt "$P"
check "1 $D" "$CODE $(driver_of "$RUN")"
has "does not approve this takeover" "$OUT"
has "fix: run \`programme.sh approval-label takeover --replace $D\`" "$OUT"
has "then rerun \`programme.sh takeover --prompt <pick id>\`" "$OUT"

it "a pre-filled pick of the takeover label is refused"
P="$(pick sess-p "$LABEL" prefilled)"
as sess-p takeover --prompt "$P"
check "1 $D" "$CODE $(driver_of "$RUN")"
has "is not a verified" "$OUT"

it "a pick made in another session is refused"
P="$(pick sess-q "$LABEL")"
as sess-p takeover --prompt "$P"
check "1 $D" "$CODE $(driver_of "$RUN")"
has "was not given in this session" "$OUT"

it "a typed ask cannot replace a PM herdr shows live; it needs the pick"
A="$(ask sess-p "be the PM" 0)"
as sess-p takeover --prompt "$A"
check "1 $D" "$CODE $(driver_of "$RUN")"
has "needs a pick of '$LABEL'" "$OUT"

it "a pick of the exact label, marked recommended, replaces the live PM"
P="$(pick sess-p "$LABEL (Recommended)")"
as sess-p takeover --prompt "$P"
check "0 sess-p" "$CODE $(driver_of "$RUN")"
ENTRY="$(last_entry "$RUN" taken_over)"
has '"reason": "replaced"' "$ENTRY"
has '"request": null' "$ENTRY"
has "\"prompt_id\": \"$P\"" "$ENTRY"
has "\"from_session\": \"$D\"" "$ENTRY"
case "$ENTRY" in *unrequested*) fail "a picked replace is not unrequested" ;; *) pass ;; esac

it "the same pick cited again, after another session became PM, is refused"
register sess-p w2:p81 term_p81
snapshot "w2:p81|New PM|sess-p|term_p81" "w2:p31|scratch|sess-w2|term_p31"
P2="$(pick sess-u "Approve takeover --replace sess-p")"
typed sess-t '/auto:programme-takeover --replace sess-p' >/dev/null
as sess-t takeover --replace sess-p
check "0 sess-t" "$CODE $(driver_of "$RUN")"
as sess-p takeover --prompt "$P"
check "1 sess-t" "$CODE $(driver_of "$RUN")"
has "before the current PM took the programme" "$OUT"

it "a pick naming the PM before the last takeover is refused; its fix asks for a pick naming the PM now"
as sess-u takeover --prompt "$P2"
check "1 sess-t" "$CODE $(driver_of "$RUN")"
has "fix: run \`programme.sh approval-label takeover --replace sess-t\`" "$OUT"

register sess-t w2:p85 term_p85
snapshot "w2:p85|PM|sess-t|term_p85" "w2:p31|scratch|sess-w2|term_p31"
set_beat "$RUN" 3

it "an orphaned lease whose PM herdr still shows needs the pick route"
A="$(ask sess-k "be the PM" 0)"
as sess-k takeover --prompt "$A"
check "1 sess-t" "$CODE $(driver_of "$RUN")"
has "needs a pick" "$OUT"

snapshot "w2:p31|scratch|sess-w2|term_p31"
LABEL_T="Approve takeover --replace sess-t"

it "a session in the space only by HERDR env, with no registry row and no pane herdr can prove, cannot take over a stopped PM"
P="$(pick sess-n "$LABEL_T")"
OUT="$(CLAUDE_CODE_SESSION_ID=sess-n HERDR_PANE_ID=w2:pGHOST HERDR_WORKSPACE_ID=w2 "$PY" "$PROG" takeover --prompt "$P" 2>&1)"; CODE=$?
check "1 sess-t" "$CODE $(driver_of "$RUN")"
has "cannot identify this session's herdr terminal pane" "$OUT"
has "fix: run Claude from a pane or window that the terminal host can identify" "$OUT"

register sess-k w2:p86 term_p86

it "an orphaned lease and no prompt of this session's is refused"
as sess-k takeover --prompt p000000
check "1 sess-t" "$CODE $(driver_of "$RUN")"
has "no prompt 'p000000'" "$OUT"

it "an orphaned lease: Shawn's typed ask is refused; a stopped PM still needs the pick"
A="$(ask sess-k "be the PM" 0)"
as sess-k takeover --prompt "$A"
check "1 sess-t" "$CODE $(driver_of "$RUN")"
has "the PM stopped; replacing it still needs a pick of '$LABEL_T'" "$OUT"
it "the refusal's fix offers the takeover picker, not become-pm"
has "fix: run \`programme.sh approval-label takeover --replace sess-t\`" "$OUT"

it "an orphaned lease: an accepted suggestion is refused"
S="$(suggested sess-k "yes, take over as PM")"
as sess-k takeover --prompt "$S"
check "1 sess-t" "$CODE $(driver_of "$RUN")"
has "needs a pick of '$LABEL_T'" "$OUT"

it "an orphaned lease: a pick of the option that keeps the current PM is refused"
P="$(pick sess-k "Keep the current PM")"
as sess-k takeover --prompt "$P"
check "1 sess-t" "$CODE $(driver_of "$RUN")"
has "does not approve this takeover" "$OUT"

it "an orphaned lease: a pick made in another session is refused"
register sess-j w2:p87 term_p87
P="$(pick sess-j "$LABEL_T")"
as sess-k takeover --prompt "$P"
check "1 sess-t" "$CODE $(driver_of "$RUN")"
has "was not given in this session" "$OUT"

it "an ask from a session outside the lease's space is refused"
A="$(ask sess-w9 "be the PM" 0)"
as_in w9 sess-w9 takeover --prompt "$A" --run "$RUN"
check "1 sess-t" "$CODE $(driver_of "$RUN")"
has "not in the programme's space" "$OUT"

P="$(pick sess-k "$LABEL_T")"

it "a lease whose status did not come from a readable run record is refused, not read as orphaned"
LEASE_FILE="${CLAUDE_AUTO_DATA_DIR}/programmes/leases/default.w2.json"
cp -f "$LEASE_FILE" "${WORK}/lease.bak"
"$PY" -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["home"]="/nonexistent/home"; json.dump(d, open(p, "w"))' "$LEASE_FILE"
as sess-k takeover --prompt "$P"
check "1 sess-t" "$CODE $(driver_of "$RUN")"
has "run record could not be read" "$OUT"
cp -f "${WORK}/lease.bak" "$LEASE_FILE"

it "an orphaned lease: Shawn's pick of the exact label moves the lease, as orphaned"
as sess-k takeover --prompt "$P"
check "0 sess-k" "$CODE $(driver_of "$RUN")"
ENTRY="$(last_entry "$RUN" taken_over)"
has '"reason": "orphaned"' "$ENTRY"
has '"request": null' "$ENTRY"
has '"origin": "picked"' "$ENTRY"
has "\"prompt_id\": \"$P\"" "$ENTRY"
case "$ENTRY" in *unrequested*) fail "a picked takeover is not unrequested" ;; *) pass ;; esac

register sess-k w2:p90 term_p90
register sess-m w2:p91 term_p91
set_beat "$RUN" 0.05
LABEL_K="Approve takeover --replace sess-k"

it "a PM herdr shows gone: Shawn's typed ask is refused"
A="$(ask sess-m "take over as PM" 0)"
as sess-m takeover --prompt "$A"
check "1 sess-k" "$CODE $(driver_of "$RUN")"
has "the PM stopped; replacing it still needs a pick of '$LABEL_K'" "$OUT"

it "a PM herdr shows gone: an accepted suggestion is refused"
S="$(suggested sess-m "yes, take over as PM")"
as sess-m takeover --prompt "$S"
check "1 sess-k" "$CODE $(driver_of "$RUN")"
has "needs a pick of '$LABEL_K'" "$OUT"

it "a PM herdr shows gone: a pick of the option that keeps the current PM is refused"
P="$(pick sess-m "Keep the current PM")"
as sess-m takeover --prompt "$P"
check "1 sess-k" "$CODE $(driver_of "$RUN")"
has "does not approve this takeover" "$OUT"

it "a PM herdr shows gone is replaced on Shawn's pick of the exact label, as driver_gone"
P="$(pick sess-m "$LABEL_K")"
as sess-m takeover --prompt "$P"
check "0 sess-m" "$CODE $(driver_of "$RUN")"
ENTRY="$(last_entry "$RUN" taken_over)"
has '"reason": "driver_gone"' "$ENTRY"
has '"request": null' "$ENTRY"
has '"origin": "picked"' "$ENTRY"
has '"pane_in_snapshot": false' "$ENTRY"

echo
echo "programme-takeover.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
