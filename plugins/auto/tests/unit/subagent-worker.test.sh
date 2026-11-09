#!/usr/bin/env bash
# The Agent PostToolUse and SubagentStop hook: a PM's background sub-agent becomes a worker item through the
# verbs, and the item waits on the PM once the agent stops.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
HOOK="${AUTO_ROOT}/.claude/hooks/on-subagent-worker.sh"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
check() { if [ "$1" = "$2" ]; then pass; else fail "expected [$1] got [$2]"; fi; }

echo "subagent-worker.test.sh"

WORK="$(mktemp -d -t auto-subagent-worker.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_AUTO_TEST_HARNESS=1
unset CLAUDE_CODE_SESSION_ID HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH CLAUDE_AUTO_REPO 2>/dev/null || true
: > "$CLAUDE_AUTO_SECRETS_FILE"

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
ph = load_lib_module("programme_home")
pj = load_lib_module("programme_journal")
args = sys.argv[2:]
$(cat)
PYEOF
}

payload() {
  "$PY" -c '
import json, sys
sid, desc, prompt, kind, agent, bg = sys.argv[1:7]
print(json.dumps({"session_id": sid, "hook_event_name": "PostToolUse", "tool_name": "Agent",
                  "tool_input": {"description": desc, "prompt": prompt, "subagent_type": kind,
                                 "run_in_background": bg == "1"},
                  "tool_response": {"status": "async_launched" if bg == "1" else "completed", "agentId": agent}}))
' "$@"
}

start() { payload "$@" | bash "$HOOK"; }
stop_agent() { printf '{"session_id":"%s","hook_event_name":"SubagentStop","agent_id":"%s","agent_type":"coder"}' "$1" "$2" | bash "$HOOK"; }

item() {
  run_py "$RUN" "$1" "$2" <<'EOF'
record, _ = ph.read_programme(args[0])
item = (record.get("programme") or {}).get("items", {}).get(args[1])
if item is None:
    print("absent")
else:
    value = {"state": item.get("state"), "title": item.get("title"),
             "kinds": ",".join(item.get("change_kinds") or []) or "-",
             "who": (item.get("waiting_on") or {}).get("who"),
             "reporter": (item.get("waiting_on") or {}).get("reporter")}
    print(value[args[2]])
EOF
}

item_count() {
  run_py "$RUN" <<'EOF'
record, _ = ph.read_programme(args[0])
print(len((record.get("programme") or {}).get("items") or {}))
EOF
}

journal_kinds() {
  run_py "$RUN" <<'EOF'
print(" ".join(r["kind"] for r in pj.read(args[0])))
EOF
}

it "no lease on the machine: the hook runs no Python"
MARKER="${WORK}/marker-python"
printf '#!/usr/bin/env bash\ntouch "%s/python-ran"\n' "$WORK" > "$MARKER"; chmod +x "$MARKER"
payload sess-pm "AI-1 / x" "" coder a1 1 2>/dev/null | CLAUDE_AUTO_PYTHON3="$MARKER" bash "$HOOK"
if [ ! -e "${WORK}/python-ran" ]; then pass; else fail "python ran"; fi

RUN="$(run_py <<'EOF'
print(ph.create_programme(["w2"], "sess-pm")["run"])
EOF
)"

it "a key at the start of the description records a linear item with the coder's done rule"
OUT="$(start sess-pm "AI-1234 / Fix the reframe crop" "Build the fix." coder agentaaa1 1)"
check "" "$OUT"
it "  the item waits on the coder, reported by the agent"
check "waiting coder agentaaa1 flagged_code Fix the reframe crop" \
  "$(item linear:AI-1234 state) $(item linear:AI-1234 who) $(item linear:AI-1234 reporter) $(item linear:AI-1234 kinds) $(item linear:AI-1234 title)"

it "the Stop predicate has nothing to say about the recorded item"
REASONS="$(run_py "$RUN" <<'EOF'
pred = load_lib_module("programme_predicate")
record, _ = ph.read_programme(args[0])
floor = pred.compute(record, inbox_size=0)["actionable_reasons"]
print(sorted({r["kind"] for r in floor if r.get("item") == "linear:AI-1234"}))
EOF
)"
check "[]" "$REASONS"

it "a key only in the prompt's first line records a linear item titled by the description"
start sess-pm "Investigate the crop jump" $'Ticket: WEB-77\nRead the logs.' investigator agentbbb2 1
check "waiting investigator fix_only Investigate the crop jump" \
  "$(item linear:WEB-77 state) $(item linear:WEB-77 who) $(item linear:WEB-77 kinds) $(item linear:WEB-77 title)"

it "a label / title description with no key records a study item"
start sess-pm "Cue timing / why waits grow" "Look into it." planner agentccc3 1
check "waiting fix_only why waits grow" \
  "$(item study:cue-timing-why-waits-grow state) $(item study:cue-timing-why-waits-grow kinds) $(item study:cue-timing-why-waits-grow title)"

it "no key and no label / title shape records nothing"
BEFORE="$(item_count)"
start sess-pm "Hook facts for Agent tool" "Read the docs." general-purpose agentddd4 1
check "$BEFORE" "$(item_count)"

it "a foreground agent records nothing"
start sess-pm "AI-555 / Quick look" "x" coder agenteee5 0
check "absent" "$(item linear:AI-555 state)"

it "an auto reader agent records nothing"
start sess-pm "AI-556 / status" "x" auto:programme-status-reader agentfff6 1
check "absent" "$(item linear:AI-556 state)"

it "a session that does not drive the programme records nothing"
start sess-other "AI-557 / Fix" "x" coder agentggg7 1
check "absent" "$(item linear:AI-557 state)"

it "a sub-agent's own Agent call records nothing"
payload sess-pm "AI-558 / Fix" "x" coder agenthhh8 1 \
  | "$PY" -c 'import json,sys; d=json.load(sys.stdin); d["agent_id"]="parent1"; print(json.dumps(d))' | bash "$HOOK"
check "absent" "$(item linear:AI-558 state)"

it "an existing item keeps its kind and moves its wait to the new agent"
start sess-pm "AI-1234 / Review the fix" "x" tester agentiii9 1
check "flagged_code tester agentiii9 Fix the reframe crop" \
  "$(item linear:AI-1234 kinds) $(item linear:AI-1234 who) $(item linear:AI-1234 reporter) $(item linear:AI-1234 title)"

it "the agent stopping puts the item on the PM for review, never done"
OUT="$(stop_agent sess-pm agentiii9)"
check " waiting pm pm" "$OUT $(item linear:AI-1234 state) $(item linear:AI-1234 who) $(item linear:AI-1234 reporter)"

it "a stop from an agent the item no longer waits on changes nothing"
stop_agent sess-pm agentaaa1
check "waiting pm pm" "$(item linear:AI-1234 state) $(item linear:AI-1234 who) $(item linear:AI-1234 reporter)"

it "the other items still wait on their own agents"
check "investigator planner" "$(item linear:WEB-77 who) $(item study:cue-timing-why-waits-grow who)"

it "a failed verb is journaled and the hook stays silent"
touch "${CLAUDE_AUTO_DATA_DIR}/programmes/${RUN}/$(run_py <<'EOF'
print(ph.COMPACT_FLAG)
EOF
)"
OUT="$(start sess-pm "AI-900 / After compaction" "x" coder agentjjj0 1)"
check "absent" "$OUT$(item linear:AI-900 state)"
it "  the journal names the failed step"
case "$(journal_kinds)" in *subagent_record_failed*) pass ;; *) fail "no subagent_record_failed row" ;; esac

echo
echo "  ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
