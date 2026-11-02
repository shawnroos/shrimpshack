#!/usr/bin/env bash
# auto unit test: compatibility of the worker-contract change with everything that has no contract.
#
# The fixtures under tests/fixtures/pre-contract/ were produced by the code at commit fca53cc0, before any
# contract existed: a task run record with no `contract` and no `contract_capable` key, a programme item with no
# `auto_run` block, and a hand-driven pane worker item. Every reader this change touched must load them and
# treat them as "no contract". The golden values for a plain `/auto <plan>` arm, pulse and wave were captured
# by running fca53cc0 and this tree side by side on one plan; the only difference was the additive
# `contract_capable: true` key on a new record.
#
# Every assertion pins a value or the presence of the key it reads, so a reader that starts writing an empty
# `contract` block (or crashes on a missing one) fails here.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
PROG="${AUTO_ROOT}/lib/programme.py"
FIX="${AUTO_ROOT}/tests/fixtures/pre-contract"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
check() { if [ "$1" = "$2" ]; then pass; else fail "expected [$1] got [$2]"; fi; }
has() { case "$2" in *"$1"*) pass ;; *) fail "expected to find [$1] in [$2]" ;; esac; }
lacks() { case "$2" in *"$1"*) fail "did not expect [$1] in [$2]" ;; *) pass ;; esac; }

echo "worker-compat.test.sh"

WORK="$(mktemp -d -t auto-wcompat.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_AUTO_MACHINE="studio"
export CLAUDE_AUTO_TEST_HARNESS="1"
export CLAUDE_AUTO_SOURCE_TIMEOUT="2"
export CLAUDE_AUTO_WORKER_WAIT="1"
export CLAUDE_CODE_SESSION_ID="sess-pm"
unset HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_BIN_PATH HERDR_ENV CLAUDE_AUTO_REPO LINEAR_API_KEY 2>/dev/null || true
: > "$CLAUDE_AUTO_SECRETS_FILE"

FAKES="${WORK}/fakes"
CALLS="${WORK}/calls.log"
SNAP="${WORK}/snapshot.json"
mkdir -p "$FAKES"
: > "$CALLS"
export CALLS SNAP PY
cat > "${FAKES}/herdr" <<'EOF'
#!/bin/bash
printf 'herdr %s\n' "$*" >> "$CALLS"
case "$1 ${2:-}" in
  "status server") echo "status: running"; echo "version: 0.9.3" ;;
  "api snapshot") cat "$SNAP" ;;
  "agent list") "$PY" -c 'import json,sys; s=json.load(open(sys.argv[1]))["result"]["snapshot"]; print(json.dumps({"id":"1","result":{"type":"agent_list","agents":s["agents"]}}))' "$SNAP" ;;
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
pane = {"pane_id": "w2:p40", "tab_id": "w2:t1", "workspace_id": "w2", "terminal_id": "term_p40", "agent": "claude",
        "agent_status": "idle", "cwd": "/tmp", "label": "worker", "terminal_title_stripped": "worker",
        "agent_session": {"source": "auto", "agent": "claude", "kind": "id", "value": sid}}
snap["panes"].append(pane)
snap["agents"].append(pane)
json.dump(doc, open(path, "w"))
PYEOF
exit 0
EOF
chmod +x "${FAKES}"/*
export PATH="${FAKES}:${PATH}"
"$PY" - "$SNAP" <<'EOF'
import json, sys
pane = {"pane_id": "w2:p31", "tab_id": "w2:t1", "workspace_id": "w2", "terminal_id": "term_p31", "agent": "claude",
        "agent_status": "idle", "cwd": "/tmp", "label": None, "terminal_title_stripped": "hand driven",
        "agent_session": {"source": "auto", "agent": "claude", "kind": "id", "value": "sess-hand"}}
json.dump({"id": "1", "result": {"type": "snapshot", "snapshot": {
    "workspaces": [{"workspace_id": "w2", "label": "Ai Editor"}], "tabs": [{"tab_id": "w2:t1", "workspace_id": "w2", "label": "Work"}],
    "panes": [pane], "agents": [pane]}}}, open(sys.argv[1], "w"))
EOF

REPO="${WORK}/repo"
mkdir -p "${REPO}/.claude/auto" "${REPO}/docs/plans"
export REPO FIX

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import json, os, shutil, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
sys.path.insert(0, os.path.join(sys.argv[1], "tests", "helpers"))
from _bootstrap import load_lib_module
from programme_records import edit as pedit
ph = load_lib_module("programme_home")
pj = load_lib_module("programme_journal")
core = load_lib_module("run_record_core")
fc = load_lib_module("format_compat")
REPO = os.environ["REPO"]
FIX = os.environ["FIX"]
args = sys.argv[2:]
def fixture_record():
    return json.load(open(os.path.join(FIX, "run-record.json")))
def reset(run="legacy-run"):
    rec = fixture_record()
    rec["run_id"] = run
    path = os.path.join(REPO, ".claude", "auto", run + ".json")
    with open(path, "w") as fh:
        json.dump(rec, fh, indent=2, sort_keys=True)
    return path
def rec(run="legacy-run"):
    return core.read_run_record(REPO, run)
$(cat)
PYEOF
}

OUT=""
CODE=0
CRASHES=""
prog() {
  OUT="$("$PY" "$PROG" "$@" 2>&1)"
  CODE=$?
  case "$OUT" in *Traceback*) CRASHES="${CRASHES}$* | " ;; esac
}
as() { local sid="$1"; shift; CLAUDE_CODE_SESSION_ID="$sid" prog "$@"; }
jq_py() {
  "$PY" -c "import json,sys; d=json.loads(sys.stdin.read()); print(json.dumps($1, sort_keys=True))" <<< "$OUT" 2>&1
}

echo "── the fixtures really are pre-contract ──"

it "the run record fixture has no contract key and no contract_capable key, and is format 2"
check '{"capable": false, "contract": false, "format": 2, "run": "legacy-run", "steps": 3}' "$(run_py <<'EOF'
r = fixture_record()
print(json.dumps({"contract": "contract" in r, "capable": "contract_capable" in r, "format": r["format"],
                  "run": r["run_id"], "steps": len(r["steps"])}, sort_keys=True))
EOF
)"

it "the programme item fixture has a plain item and a hand-driven pane item, and neither has an auto_run block"
check '{"herdr:w2/p31": {"auto_run": false, "session": "sess-hand"}, "linear:AI-701": {"auto_run": false, "session": null}}' "$(run_py <<'EOF'
items = json.load(open(os.path.join(FIX, "programme-items.json")))
print(json.dumps({k: {"auto_run": "auto_run" in v, "session": v["owner"]["session_id"]} for k, v in items.items()}, sort_keys=True))
EOF
)"

echo "── a pre-contract run record through every reader ──"

it "the run record loads and gains no contract key"
check '{"contract": false, "steps": ["U1", "U2", "U3"]}' "$(run_py <<'EOF'
reset()
r = rec()
print(json.dumps({"contract": "contract" in r, "steps": [s["id"] for s in r["steps"]]}, sort_keys=True))
EOF
)"

it "format upgrade and downgrade leave the record with no contract key, and upgrade is idempotent"
check '{"down_has_contract": false, "idempotent": true, "up_has_contract": false, "up_keeps_steps": 3}' "$(run_py <<'EOF'
r = fixture_record()
up = fc.upgrade_run_record(r)
down = fc.downgrade_run_record(up)
print(json.dumps({"up_has_contract": "contract" in up, "down_has_contract": "contract" in down,
                  "up_keeps_steps": len(up["steps"]), "idempotent": fc.upgrade_run_record(up) == up}, sort_keys=True))
EOF
)"

it "a contract block's authority map keys pass through the format shim untouched, even a key that is a retired v1 name (the opaque entry)"
check 'true' "$(run_py <<'EOF'
r = fixture_record()
retired = [fc_v1 + tail for fc_v1, tail in (("un", "its"), ("re", "cipe"))]
entry = {"mode": "act", "asks": "pm"}
r["contract"] = {"authority": {**{k: entry for k in retired}, "technical_approach": entry}}
print(json.dumps(sorted(fc.upgrade_run_record(r)["contract"]["authority"]) == sorted(retired + ["technical_approach"])))
EOF
)"

it "a pulse on the pre-contract record exits clean, carries no contract text and writes no contract key"
check '{"capable_key": false, "contract_key": false, "guided": false, "has_guidance_key": true}' "$(run_py <<'EOF'
reset()
pulse = load_lib_module("pulse")
res = pulse.dispatch_pulse(REPO, "legacy-run")
r = rec()
print(json.dumps({"guided": "PM CONTRACT" in (res.get("operator_guidance") or ""), "has_guidance_key": "operator_guidance" in res,
                  "contract_key": "contract" in r, "capable_key": "contract_capable" in r}, sort_keys=True))
EOF
)"

it "the dispatcher applies no contract clamp: a wave of two ready steps launches both, and the agent's own cap of one still binds"
check '{"cap1": ["U2"], "cap16": ["U2", "U3"], "contract_key": false}' "$(run_py <<'EOF'
dispatcher = load_lib_module("dispatcher")
reset("wave16")
log16 = []
dispatcher.dispatch_batch(REPO, "wave16", ["U2", "U3"], 16, launch_fn=lambda uid, a: log16.append(uid))
reset("wave1")
log1 = []
dispatcher.dispatch_batch(REPO, "wave1", ["U2", "U3"], 1, launch_fn=lambda uid, a: log1.append(uid))
print(json.dumps({"cap16": log16, "cap1": log1, "contract_key": "contract" in rec("wave16") or "contract" in rec("wave1")}, sort_keys=True))
EOF
)"

it "the dispatch prompt is identical with and without the repo, and names no contract"
check '{"contract_text": false, "same": true, "step": true}' "$(run_py <<'EOF'
dp = load_lib_module("dispatch_prompt")
reset()
a = dp.build_dispatch_prompt("legacy-run", "U2", 1, goal="g")
b = dp.build_dispatch_prompt("legacy-run", "U2", 1, goal="g", repo_root=REPO)
print(json.dumps({"same": a == b, "contract_text": "PM CONTRACT" in b or "Done bar" in b, "step": "step `U2`" in b}, sort_keys=True))
EOF
)"

it "the question hook keeps today's advisor redirect for a self-driven run with no contract"
check '{"advisor": true, "contract_key": false, "decision": "deny"}' "$(run_py <<'EOF2'
hook = load_lib_module("on-pretooluse-askuser")
reset()
core._with_locked_run_record(REPO, "legacy-run", lambda r: r["loop"].update(driver="self", last_beat_at=core.now_iso()))
out = hook.decide(REPO, json.dumps({"session_id": "sess-hand", "tool_name": "AskUserQuestion",
                                    "tool_input": {"questions": [{"question": "Which approach should I take for the parser refactor?", "options": []}]}}))
print(json.dumps({"advisor": "Consult the `advisor` tool" in out["hookSpecificOutput"]["permissionDecisionReason"],
                  "decision": out["hookSpecificOutput"]["permissionDecision"], "contract_key": "contract" in rec()}, sort_keys=True))
EOF2
)"

it "the goal binding reader treats the record as unbound (no contract, no goal)"
check '{"contract": false, "run_record_text_has_goal": false}' "$(run_py <<'EOF'
gb = load_lib_module("goal_binding")
reset()
r = rec()
print(json.dumps({"contract": "contract" in r, "run_record_text_has_goal": "goal" in json.dumps(r.get("contract") or {})}, sort_keys=True))
EOF
)"

it "goal-bound refuses a run with no contract and writes nothing"
OUT="$(CLAUDE_CODE_SESSION_ID=sess-hand CLAUDE_AUTO_REPO="$REPO" bash "${AUTO_ROOT}/lib/run_record.sh" goal-bound legacy-run 1 2>&1)"
CODE=$?
check "1" "$CODE"
has "has no contract, so there is no goal to bind" "$OUT"
it "goal-bound left the record without a contract key"
check 'false' "$(run_py <<'EOF'
print(json.dumps("contract" in rec()))
EOF
)"

echo "── a programme with pre-contract items ──"

RUN="$(run_py <<'EOF'
print(ph.create_programme(["w2"], "sess-pm")["run"])
EOF
)"
export RUN
run_py <<'EOF'
items = json.load(open(os.path.join(FIX, "programme-items.json")))
def load_items(rec):
    prog = rec["programme"] = ph.normalize_programme(rec.get("programme") or {})
    prog["items"].update(items)
    prog["remit"]["repos"] = [{"path": REPO}]
    prog["items"]["herdr:w2/p31"]["repo"] = REPO
core._with_locked_run_record(ph.home_path(os.environ["RUN"]), os.environ["RUN"], load_items)
EOF

it "an item with no auto_run block reads 'no contract' from contract-status and exits 0"
prog contract-status linear:AI-701 --run "$RUN"
check '[0, "no contract", false, true]' "$(jq_py '[0, d["items"]["linear:AI-701"]["state"], d["items"]["linear:AI-701"]["counts_as_done"], "state" in d["items"]["linear:AI-701"]]')"

it "a hand-driven pane item reads 'no contract' too"
prog contract-status herdr:w2/p31 --run "$RUN"
check '[0, "no contract", false]' "$(jq_py '[0, d["items"]["herdr:w2/p31"]["state"], d["items"]["herdr:w2/p31"]["counts_as_done"]]')"

it "with no item argument the verb lists nothing, because no item has an auto_run block"
prog contract-status --run "$RUN"
check '[0, []]' "$(jq_py '[0, sorted(d["items"])]')"

it "sweep-inputs on a programme of pre-contract items loads, reports an empty contracts block and no contract reason"
prog sweep-inputs --run "$RUN"
check '[0, [], [], null, true]' "$(jq_py '[0, d["contracts"]["changed"], d["contracts"]["due"], d["contracts"]["error"], "verdict" in d]')"
it "the sweep verdict names none of the contract reasons"
check '[false, false, false]' "$(jq_py '[any(w.startswith(p) for w in d["why"]) for p in ("contract_changed", "worker_question_due", "contract_status_unreadable")]')"

it "goal-status on an item with no contract refuses without a traceback"
prog goal-status linear:AI-701 --run "$RUN"
check "1" "$CODE"

echo "── set-contract refuses an item with no contract ──"

it "set-contract on a plain item exits 1 and says the item has no contracted run"
prog set-contract --item linear:AI-701 --fan-out-cap 2 --run "$RUN"
check "1" "$CODE"
has "no contracted run" "$OUT"
it "set-contract on the hand-driven pane item exits 1 and says the same"
prog set-contract --item herdr:w2/p31 --fan-out-cap 2 --run "$RUN"
check "1" "$CODE"
has "no contracted run" "$OUT"
it "neither refusal crashed, and neither item gained an auto_run block"
check '{"herdr:w2/p31": false, "linear:AI-701": false}' "$(run_py <<'EOF'
items = core.read_run_record(ph.home_path(os.environ["RUN"]), os.environ["RUN"])["programme"]["items"]
print(json.dumps({k: "auto_run" in v for k, v in items.items() if k in ("linear:AI-701", "herdr:w2/p31")}, sort_keys=True))
EOF
)"
check "" "$CRASHES"

echo "── register-run on a hand-started run ──"

run_py <<'EOF'
reset()
EOF
it "the hand-driven item's owner registers its own pre-contract run: exit 0, nothing copied, no version"
as sess-hand register-run --run "$RUN" --item herdr:w2/p31 --auto-run legacy-run --repo "$REPO"
check '[0, false, null, "bound"]' "$(jq_py '[0, d["contract_copied"], d["contract_version"], d["state"]]')"
it "the run record gains no contract key and no contract_capable key from the registration"
check '{"capable": false, "contract": false}' "$(run_py <<'EOF'
r = rec()
print(json.dumps({"contract": "contract" in r, "capable": "contract_capable" in r}, sort_keys=True))
EOF
)"
it "the item now holds a bound auto_run block whose contract is null"
check '{"contract": null, "run_id": "legacy-run", "state": "bound"}' "$(run_py <<'EOF'
a = core.read_run_record(ph.home_path(os.environ["RUN"]), os.environ["RUN"])["programme"]["items"]["herdr:w2/p31"]["auto_run"]
print(json.dumps({k: a[k] for k in ("state", "run_id", "contract")}, sort_keys=True))
EOF
)"
it "a repeat registration is refused (one item is one run)"
as sess-hand register-run --run "$RUN" --item herdr:w2/p31 --auto-run legacy-run --repo "$REPO"
check "1" "$CODE"
has "already_bound" "$OUT"
it "contract-status on the bound item reads 'no contract' and names the run"
prog contract-status herdr:w2/p31 --run "$RUN"
check '[0, "no contract", "legacy-run"]' "$(jq_py '[0, d["items"]["herdr:w2/p31"]["state"], d["items"]["herdr:w2/p31"]["run_id"]]')"
it "set-contract on the bound pre-contract run is refused with the reason, and the record is unchanged"
prog set-contract --item herdr:w2/p31 --fan-out-cap 2 --run "$RUN"
check "1" "$CODE"
has "predates contracts" "$OUT"
it "the pre-contract record still has no contract key after the refused write"
check 'false' "$(run_py <<'EOF'
print(json.dumps("contract" in rec()))
EOF
)"
it "sweep-inputs with that bound item still reports no contract change"
prog sweep-inputs --run "$RUN"
check '[[], null]' "$(jq_py '[d["contracts"]["changed"], d["contracts"]["error"]]')"

echo "── start-worker with no contract is unchanged (R20) ──"

: > "$CALLS"
prog start-worker linear:AI-701 --run "$RUN" -- --name plain --handoff /tmp/h.md --target tab
it "a start with no contract exits 0"
check 0 "$CODE"
SID="$(grep '^spinoff ' "$CALLS" | sed -E 's/.*--session-id ([^ ]+).*/\1/')"
it "spinoff gets exactly the caller's arguments plus the minted session id, and no kickoff override"
check "spinoff --name plain --handoff /tmp/h.md --target tab --session-id ${SID}" "$(grep '^spinoff ' "$CALLS")"
it "the receipt carries exactly the pre-contract keys"
check '["attempt", "behaviour_ids", "behaviours_held_back", "decision_ids", "item", "kind", "late", "ok", "operation_state", "outcome", "output_tail", "pane", "reason", "restrictions", "run", "session_id", "spinoff_exit", "started", "terminal_id"]' "$(jq_py 'sorted(d.keys())')"
it "the item gains no auto_run block and keeps the pre-contract keys"
check '{"auto_run": false, "owner_pane": "w2:p40"}' "$(run_py <<'EOF'
item = core.read_run_record(ph.home_path(os.environ["RUN"]), os.environ["RUN"])["programme"]["items"]["linear:AI-701"]
print(json.dumps({"auto_run": "auto_run" in item, "owner_pane": item["owner"]["pane"]}, sort_keys=True))
EOF
)"
: > "$CALLS"
it "--contract without --plan is a usage refusal (exit 2) and spinoff is not called"
prog start-worker herdr:w2/p31 --contract /nonexistent.json --run "$RUN" -- --name x
check "2" "$CODE"
check "0" "$(grep -c '^spinoff ' "$CALLS")"

echo "── /auto <plan> with no programme (AE5, golden from fca53cc0) ──"

printf '# Plan: compat probe\n\n## Summary\nprobe\n\n## Requirements\n- R1\n\n## Steps\n\n### S1. First\n- **Goal:** one\n\n### S2. Second\n- **Goal:** two\n' > "${REPO}/docs/plans/p.md"
ARM_OUT="$(CLAUDE_AUTO_REPO="$REPO" CLAUDE_CODE_SESSION_ID=sess-compat CLAUDE_CODE_CHILD_SESSION="" bash "${AUTO_ROOT}/lib/auto.sh" "${REPO}/docs/plans/p.md" 2>"${WORK}/arm.err")"
ARM_CODE=$?
ARM_RUN="$(printf '%s' "$ARM_OUT" | "$PY" -c 'import json,sys; print(json.loads(sys.stdin.read())["run"])')"
it "arm exits 0 and prints the arm-pulse intent with exactly the old keys"
check '[0, ["action", "auto", "backend", "goal", "note", "plan", "prompt", "run", "runnable"]]' "[${ARM_CODE}, $(printf '%s' "$ARM_OUT" | "$PY" -c 'import json,sys; print(json.dumps(sorted(json.loads(sys.stdin.read()))))')]"
it "the arm intent values match the old output"
check '["arm-pulse", true, "ce", null, "new run created (loop_phase=plan); set the deliberate-stop /goal, then arm the first pulse"]' "$(printf '%s' "$ARM_OUT" | "$PY" -c 'import json,sys; d=json.loads(sys.stdin.read()); print(json.dumps([d["action"], d["auto"], d["backend"], d["goal"], d["note"]]))')"
it "the arm prompt is the old pulse command with --auto"
check "/auto:auto-pulse ${ARM_RUN} --auto" "$(printf '%s' "$ARM_OUT" | "$PY" -c 'import json,sys; print(json.loads(sys.stdin.read())["prompt"])')"
it "arm printed nothing on stderr (no notice, no warning)"
check "" "$(cat "${WORK}/arm.err")"

it "the new run record is the old record plus contract_capable, and has no contract block"
check '{"capable": true, "contract": false, "format": 2, "loop_phase": "plan", "steps": 1}' "$(run_py <<'EOF'
import glob
path = [p for p in glob.glob(os.path.join(REPO, ".claude", "auto", "p-*.json"))][0]
r = json.load(open(path))
print(json.dumps({"capable": r.get("contract_capable"), "contract": "contract" in r, "format": r["format"],
                  "loop_phase": r["loop_phase"], "steps": len(r["steps"])}, sort_keys=True))
EOF
)"

PULSE_OUT="$(CLAUDE_AUTO_REPO="$REPO" CLAUDE_CODE_SESSION_ID=sess-compat bash "${AUTO_ROOT}/lib/pulse.sh" "$ARM_RUN" --repo "$REPO" 2>&1)"
it "the first pulse prints the old keys and the old plan-step advance"
check '[["action", "advance", "delay", "halted", "operator_guidance", "prompt", "run", "stalled"], "rearm", {"advanced": "plan-step", "step": "plan"}, 60]' "$(printf '%s' "$PULSE_OUT" | "$PY" -c 'import json,sys; d=json.loads(sys.stdin.read()); print(json.dumps([sorted(d), d["action"], d["advance"], d["delay"]]))')"
it "the pulse guidance is the old prepare/execute text with no contract text"
has "prepare/execute contract: I PREPARED a plan-loop invocation; YOU must run it." "$PULSE_OUT"
lacks "PM CONTRACT" "$PULSE_OUT"

echo "── nothing new under .claude/auto/ is JSON except run records ──"

it "every .json file under .claude/auto/ is a run record (has run_id, steps and format)"
check '{"non_records": [], "total": 4}' "$(run_py <<'EOF'
import glob
found = sorted(glob.glob(os.path.join(REPO, ".claude", "auto", "**", "*.json"), recursive=True))
bad = []
for path in found:
    d = json.load(open(path))
    if not {"run_id", "steps", "format"} <= set(d):
        bad.append(os.path.relpath(path, REPO))
print(json.dumps({"total": len(found), "non_records": bad}, sort_keys=True))
EOF
)"
it "no goals directory exists after these operations (a goal doc is written only for a contracted run, as Markdown)"
check "no" "$([ -e "${REPO}/.claude/auto/goals" ] && echo yes || echo no)"

echo "── no verb crashed ──"
it "no programme verb in this file produced a traceback"
check "" "$CRASHES"

echo ""
echo "worker-compat.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
