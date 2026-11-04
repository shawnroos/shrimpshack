#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
PROG="${AUTO_ROOT}/lib/programme.py"
REAL_SHIPPED="${AUTO_ROOT}/behaviours"
SKILL="${AUTO_ROOT}/skills/programme-sweep/SKILL.md"
SENTENCE="Record before any long background wait: send your claim first."

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
check() { if [ "$1" = "$2" ]; then pass; else fail "expected [$1] got [$2]"; fi; }
has() { case "$2" in *"$1"*) pass ;; *) fail "expected to find [$1] in [$2]" ;; esac; }
lacks() { case "$2" in *"$1"*) fail "did not expect [$1] in [$2]" ;; *) pass ;; esac; }

echo "programme-default-behaviours.test.sh"

WORK="$(mktemp -d -t auto-default-behaviours.XXXXXX)"
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
PERSONAL="${WORK}/files/personal"
mkdir -p "$EMPTY_SHIPPED" "$PERSONAL"
export CLAUDE_AUTO_SHIPPED_BEHAVIOURS_DIR="$REAL_SHIPPED"
export CLAUDE_AUTO_BEHAVIOURS_DIR="$PERSONAL"
export CLAUDE_AUTO_BEHAVIOURS_STORE="${WORK}/files/store"
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
  "status server") echo "status: running"; echo "version: 0.9.3" ;;
  "api snapshot") cat "$SNAP" ;;
  "agent list")
    "$PY" -c 'import json,sys; s=json.load(open(sys.argv[1]))["result"]["snapshot"]; print(json.dumps({"id":"1","result":{"type":"agent_list","agents":s["agents"]}}))' "$SNAP" ;;
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
exit 0
EOF
chmod +x "${FAKES}"/*
export PATH="${FAKES}:${PATH}"

write_snapshot() {
  "$PY" - "$SNAP" <<'PYEOF'
import json, sys
def pane(pid, **kw):
    out = {"pane_id": pid, "tab_id": "w2:t1", "workspace_id": "w2",
           "terminal_id": "term_" + pid.split(":")[1], "agent": None, "agent_status": "unknown",
           "cwd": "/tmp", "label": None, "terminal_title_stripped": None, "agent_session": None}
    out.update(kw)
    return out
panes = [pane("w2:p10", agent="claude", agent_status="idle", label="PM",
              agent_session={"source": "auto", "agent": "claude", "kind": "id", "value": "sess-pm"})]
agents = [p for p in panes if p["agent"]]
doc = {"id": "1", "result": {"type": "snapshot", "snapshot": {
    "workspaces": [{"workspace_id": "w2", "label": "Ai Editor"}],
    "tabs": [{"tab_id": "w2:t1", "workspace_id": "w2", "label": "Work"}],
    "panes": panes, "agents": agents}}}
json.dump(doc, open(sys.argv[1], "w"))
PYEOF
}

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
ph = load_lib_module("programme_home")
args = sys.argv[2:]
$(cat)
PYEOF
}

RUN="$(run_py <<'EOF'
print(ph.create_programme(["w2"], "sess-pm")["run"])
EOF
)"

OUT=""
CODE=0
prog() {
  OUT="$("$PY" "$PROG" "$@" 2>&1)"
  CODE=$?
}
calls() { cat "$CALLS" 2>/dev/null; }

BRIEF="${WORK}/brief.md"
printf '# Brief\nBuild the thing.\n' > "$BRIEF"

start_brief() {
  write_snapshot
  : > "$CALLS"
  FAKE_ID="$1"
  prog add-item "linear:${FAKE_ID}" --title "Default behaviours"
  prog start-worker "linear:${FAKE_ID}" -- --name "w-${FAKE_ID}" --handoff "$BRIEF"
  cat "$(grep '^spinoff ' "$CALLS" | tail -1 | sed -E 's/.*--handoff ([^ ]+).*/\1/')" 2>/dev/null
}

it "the start brief for a worker with a handoff carries the shipped record-before-wait sentence"
COPY="$(start_brief AI-701)"
has "$SENTENCE" "$COPY"

it "the start brief carries the never-prompt and Auto-limit refusal clauses with the claim command filled in"
has "Never prompt the PM's pane." "$COPY"
has "Report with bash ${AUTO_ROOT}/lib/programme.sh claim --run ${RUN} --item linear:AI-701 --deliverable <name> --ref <ref>." "$COPY"
has "Do not run it again and do not try another tool, wrapper or worker for it." "$COPY"
has "an Auto limit (not Claude Code) refuses a command" "$COPY"
lacks "{claim_command}" "$COPY"

it "prompt-item --standing sends the same clauses to a running worker, and without the flag it sends none"
start_brief AI-710 >/dev/null
: > "$CALLS"
prog prompt-item linear:AI-710 "PM: carry on."
PLAIN_CODE="$CODE"
PLAIN_CALLS="$(calls)"
: > "$CALLS"
prog prompt-item linear:AI-710 "PM: carry on, second note." --standing
check "0 0" "$PLAIN_CODE $CODE"
lacks "Never prompt the PM's pane." "$PLAIN_CALLS"
has "Never prompt the PM's pane." "$(calls)"
has "Report with bash ${AUTO_ROOT}/lib/programme.sh claim --run ${RUN} --item linear:AI-710 --deliverable <name> --ref <ref>." "$(calls)"
has "$SENTENCE" "$(calls)"

it "a behaviour file with a placeholder the loader does not fill is refused"
BADPH="${WORK}/files/badph"
mkdir -p "$BADPH"
printf -- '---\nwhen: a worker reports\ntrigger: start\napplies_to: workers\n---\nDo:\n- Report with {claim_comand}.\n' > "${BADPH}/typo.md"
check "typo:bad_value" "$(run_py "$BADPH" <<'EOF'
pf = load_lib_module("programme_behaviour_files")
r = pf.load_files(shipped_dir=args[0], personal_dir=os.environ["CLAUDE_AUTO_BEHAVIOURS_DIR"])
print(",".join("%s:%s" % (x["id"], x["reason"]) for x in r["rejected"]))
EOF
)"

it "the shipped file loads with zero rejections"
LOADED="$(run_py "$REAL_SHIPPED" <<'EOF'
pf = load_lib_module("programme_behaviour_files")
r = pf.load_files(shipped_dir=args[0], personal_dir=os.environ["CLAUDE_AUTO_BEHAVIOURS_DIR"])
by = {e["id"]: e for e in r["entries"]}
e = by.get("record-before-long-wait", {})
print(json.dumps({"rejected": len(r["rejected"]), "do": e.get("do"), "trigger": e.get("when", {}).get("trigger"),
                  "applies_to": e.get("applies_to"), "layer": e.get("layer")}, sort_keys=True))
EOF
)"
check "{\"applies_to\": \"workers\", \"do\": [\"${SENTENCE}\"], \"layer\": \"shipped\", \"rejected\": 0, \"trigger\": \"start\"}" "$LOADED"

it "the shipped file holds no protected escalation (no skills, tools or agents)"
check "[]" "$(run_py "$REAL_SHIPPED" <<'EOF'
pf = load_lib_module("programme_behaviour_files")
r = pf.load_files(shipped_dir=args[0], personal_dir=os.environ["CLAUDE_AUTO_BEHAVIOURS_DIR"])
e = [x for x in r["entries"] if x["id"] == "record-before-long-wait"][0]
print(json.dumps([k for k in ("skills", "tools", "agents") if e.get(k)]))
EOF
)"

it "the three worker clauses live only in the shipped files: the sweep skill and the resume command no longer type them"
RESUME="${AUTO_ROOT}/commands/programme-resume.md"
check "0 0 0" "$(for s in "$SENTENCE" "Never prompt the PM's pane" "do not run it again"; do cat "$SKILL" "$RESUME" | grep -cF -- "$s"; done | tr '\n' ' ' | sed 's/ $//')"

it "mutation check: with an empty shipped folder the same start brief lacks the sentence"
export CLAUDE_AUTO_SHIPPED_BEHAVIOURS_DIR="$EMPTY_SHIPPED"
COPY="$(start_brief AI-702)"
lacks "$SENTENCE" "$COPY"
export CLAUDE_AUTO_SHIPPED_BEHAVIOURS_DIR="$REAL_SHIPPED"

it "KTD12: a plain start-worker with no handoff still starts with only the shipped rule in force"
write_snapshot
: > "$CALLS"
prog add-item linear:AI-703 --title "Plain start"
prog start-worker linear:AI-703 -- --name plain --target tab
check 0 "$CODE"
lacks "--handoff" "$(grep '^spinoff ' "$CALLS")"

it "KTD12: after a plain start the shipped start rule is answered as not_briefed, so due lists nothing for that item"
check "not_briefed|0" "$(run_py "$RUN" <<'EOF'
core = load_lib_module("run_record_core")
bd = load_lib_module("programme_behaviours_due")
rec = core.read_run_record(ph.home_path(args[0]), args[0])
item = rec["programme"]["items"]["linear:AI-703"]
reasons = ",".join(d["reason"] for d in item["behaviour_deliveries"] if d["id"] == "record-before-long-wait")
due = bd.due(rec, args[0])
print(reasons + "|" + str(sum(1 for r in due["rows"] if r["item"] == "linear:AI-703")))
EOF
)"

it "KTD12: a start with a handoff still records brief, and due lists nothing for it either"
check "brief|0" "$(run_py "$RUN" <<'EOF'
core = load_lib_module("run_record_core")
bd = load_lib_module("programme_behaviours_due")
rec = core.read_run_record(ph.home_path(args[0]), args[0])
item = rec["programme"]["items"]["linear:AI-701"]
reasons = ",".join(d["reason"] for d in item["behaviour_deliveries"] if d["id"] == "record-before-long-wait")
due = bd.due(rec, args[0])
print(reasons + "|" + str(sum(1 for r in due["rows"] if r["item"] == "linear:AI-701")))
EOF
)"

echo
printf "programme-default-behaviours.test.sh: %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
