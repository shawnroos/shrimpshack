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
status = {"1": "async_launched", "0": "completed", "flag-only": "completed"}[bg]
print(json.dumps({"session_id": sid, "hook_event_name": "PostToolUse", "tool_name": "Agent",
                  "tool_input": {"description": desc, "prompt": prompt, "subagent_type": kind,
                                 "run_in_background": bg != "0"},
                  "tool_response": {"status": status, "agentId": agent}}))
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

it "hooks.json wires PostToolUse Agent|Task and SubagentStop to the worker hook, async"
check "True True" "$("$PY" - "${AUTO_ROOT}/.claude/hooks/hooks.json" <<'EOF'
import json, sys
h = json.load(open(sys.argv[1]))["hooks"]
def wired(entries, matcher):
    return any(e.get("matcher") == matcher and any("on-subagent-worker.sh" in x["command"] and x.get("async") is True
                                                    for x in e["hooks"]) for e in entries)
print(wired(h.get("PostToolUse", []), "Agent|Task"), wired(h.get("SubagentStop", []), None))
EOF
)"

it "no lease on the machine: the hook runs no Python"
MARKER="${WORK}/marker-python"
printf '#!/usr/bin/env bash\ntouch "%s/python-ran"\n' "$WORK" > "$MARKER"; chmod +x "$MARKER"
payload sess-pm "AI-1 / x" "" coder a1 1 2>/dev/null | CLAUDE_AUTO_PYTHON3="$MARKER" bash "$HOOK"
if [ ! -e "${WORK}/python-ran" ]; then pass; else fail "python ran"; fi

RUN="$(run_py <<'EOF'
print(ph.create_programme(["w2"], "sess-pm")["run"])
EOF
)"

it "an issue key as the label records a linear item with the coder's done rule, silently"
OUT="$(payload sess-pm "AI-1234 / Fix the reframe crop" "Build the fix." coder agentaaa1 1 \
  | "$PY" "${AUTO_ROOT}/lib/on-subagent-worker.py" 2>&1)"
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

it "an issue key as the label records a linear item for an investigator"
start sess-pm "WEB-77 / Investigate the crop jump" "Read the logs." investigator agentbbb2 1
check "waiting investigator fix_only Investigate the crop jump" \
  "$(item linear:WEB-77 state) $(item linear:WEB-77 who) $(item linear:WEB-77 kinds) $(item linear:WEB-77 title)"

it "any other label records a study item"
start sess-pm "Cue timing / why waits grow" "Look into it." planner agentccc3 1
check "waiting fix_only why waits grow" \
  "$(item study:cue-timing-why-waits-grow state) $(item study:cue-timing-why-waits-grow kinds) $(item study:cue-timing-why-waits-grow title)"

it "a description without the label / title shape records nothing, key or not"
BEFORE="$(item_count)"
start sess-pm "Hook facts for Agent tool" "Read the docs." general-purpose agentddd4 1
start sess-pm "AI-321 Fix the crop" "x" coder agentkkk1 1
start sess-pm "GPT-5.6 cross-model pass" "x" coder agentkkk2 1
check "$BEFORE absent" "$(item_count) $(item linear:AI-321 state)"

it "a label that only starts with a key-like token is a study label"
start sess-pm "UTF-8 decode / fix" "x" coder agentkkk3 1
check "absent waiting" "$(item linear:UTF-8 state) $(item study:utf-8-decode-fix state)"

it "a foreground agent records nothing"
start sess-pm "AI-555 / Quick look" "x" coder agenteee5 0
check "absent" "$(item linear:AI-555 state)"

it "a foreground result wins over a run_in_background flag"
start sess-pm "AI-559 / Quick look" "x" coder agenteee6 flag-only
check "absent" "$(item linear:AI-559 state)"

it "item_for: two long descriptions that share a prefix get different study ids"
check "2 True" "$(run_py <<'EOF'
mod = load_lib_module("on-subagent-worker")
head = "Cue timing / " + "why the waits grow under load and what the queue does " * 2
a, b = mod.item_for(head + "first")[0], mod.item_for(head + "second")[0]
print(len({a, b}), all(len(i) <= 70 for i in (a, b)))
EOF
)"

it "a start whose result carries no agentId records nothing and journals the start step"
"$PY" -c 'import json; print(json.dumps({"session_id": "sess-pm", "hook_event_name": "PostToolUse", "tool_name": "Agent", "tool_input": {"description": "AI-560 / x", "subagent_type": "coder"}, "tool_response": {"status": "async_launched"}}))' \
  | bash "$HOOK"
check "absent start" "$(item linear:AI-560 state) $(run_py "$RUN" <<'EOF'
print(" ".join(r["payload"]["step"] for r in pj.read(args[0])
               if r["kind"] == "subagent_record_failed" and r["payload"]["item"] == "linear:AI-560"))
EOF
)"

it "a stop from an auto reader agent writes no journal row"
printf '{"session_id":"sess-pm","hook_event_name":"SubagentStop","agent_id":"reader1","agent_type":"auto:programme-status-reader"}' | bash "$HOOK"
check "0" "$(run_py "$RUN" <<'EOF'
print(sum(1 for r in pj.read(args[0]) if r["kind"] == "subagent_stopped" and r["payload"]["agent"] == "reader1"))
EOF
)"

it "a stop that lands before the start is recorded still puts the item on the PM"
stop_agent sess-pm agentrace1
start sess-pm "AI-777 / Fast agent" "x" coder agentrace1 1
check "waiting pm pm" "$(item linear:AI-777 state) $(item linear:AI-777 who) $(item linear:AI-777 reporter)"

it "a stop from a session that does not drive the programme changes nothing"
start sess-pm "AI-778 / Slow agent" "x" coder agentslow1 1
stop_agent sess-other agentslow1
check "coder agentslow1" "$(item linear:AI-778 who) $(item linear:AI-778 reporter)"

it "a stop leaves an item that no longer waits on the agent untouched"
run_py "$RUN" <<'EOF' >/dev/null
import subprocess
subprocess.run([sys.executable, os.path.join(sys.argv[1], "lib", "programme.py"), "set-waiting", "linear:AI-778",
                "--clear", "--run", args[0]], env=dict(os.environ, CLAUDE_CODE_SESSION_ID="sess-pm"), check=True)
EOF
stop_agent sess-pm agentslow1
check "open None" "$(item linear:AI-778 state) $(item linear:AI-778 who)"

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
check "waiting pm pm investigator" \
  "$(item linear:AI-1234 state) $(item linear:AI-1234 who) $(item linear:AI-1234 reporter) $(item linear:WEB-77 who)"

it "the other items still wait on their own agents"
check "investigator planner" "$(item linear:WEB-77 who) $(item study:cue-timing-why-waits-grow who)"

it "a failed verb is journaled and the hook stays silent"
touch "${CLAUDE_AUTO_DATA_DIR}/programmes/${RUN}/$(run_py <<'EOF'
print(ph.COMPACT_FLAG)
EOF
)"
OUT="$(start sess-pm "AI-900 / After compaction" "x" coder agentjjj0 1)"
check "absent" "$OUT$(item linear:AI-900 state)"
it "  the journal names the failed step and item"
check "add-item linear:AI-900" "$(run_py "$RUN" <<'EOF'
rows = [r for r in pj.read(args[0]) if r["kind"] == "subagent_record_failed" and r["payload"]["item"] == "linear:AI-900"]
print(" ".join(f"{r['payload']['step']} {r['payload']['item']}" for r in rows))
EOF
)"

echo
echo "  ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
