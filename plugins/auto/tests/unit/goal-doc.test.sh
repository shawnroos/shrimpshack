#!/usr/bin/env bash
# auto unit test: lib/goal_doc.py, the PM's write-goal and goal-status verbs (R16, AE7, AE9, KTD10).
#
# A refusal assertion pins the refusal CODE and a phrase of its message, and checks the goal file bytes, the
# worker's run record and the programme record did not move: a missing verb also exits non-zero, so a bare
# exit code proves nothing.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
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

echo "goal-doc.test.sh"

WORK="$(mktemp -d -t auto-goal-doc.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_MACHINE="studio"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_CODE_SESSION_ID="sess-pm"
unset HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_BIN_PATH CLAUDE_AUTO_REPO 2>/dev/null || true
: > "$CLAUDE_AUTO_SECRETS_FILE"
mkdir -p "${WORK}/personal"

FAKES="${WORK}/fakes"
mkdir -p "$FAKES"
for tool in board herdr; do
  printf '#!/bin/sh\nexit 0\n' > "${FAKES}/${tool}"
  chmod +x "${FAKES}/${tool}"
done
export PATH="${FAKES}:${PATH}"

REPO="${WORK}/repo"
OTHER="${WORK}/other"
PLAIN="${WORK}/plain"
mkdir -p "${REPO}/.claude/auto" "${OTHER}/.claude/auto" "${PLAIN}/.claude/auto"
export T_REPO="$REPO" T_OTHER="$OTHER" T_PLAIN="$PLAIN"
GOAL="${REPO}/.claude/auto/goals/wrun.md"

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import json, os, sys, hashlib
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
sys.path.insert(0, os.path.join(sys.argv[1], "tests", "helpers"))
from _bootstrap import load_lib_module
wc = load_lib_module("worker_contract")
gd = load_lib_module("goal_doc")
ph = load_lib_module("programme_home")
pj = load_lib_module("programme_journal")
core = load_lib_module("run_record_core")
from programme_records import edit, load
ROOT = sys.argv[1]
args = sys.argv[2:]
REPO, OTHER, PLAIN = os.environ["T_REPO"], os.environ["T_OTHER"], os.environ["T_PLAIN"]
RUN = os.environ.get("T_RUN", "")
def wrec(repo=REPO, run="wrun"):
    return core.read_run_record(repo, run)
def sha(path):
    try:
        return hashlib.sha256(open(path, "rb").read()).hexdigest()
    except OSError:
        return "absent"
def frozen():
    prog = json.dumps(load(RUN)["programme"], sort_keys=True, default=str)
    return hashlib.sha256((prog + json.dumps(wrec(), sort_keys=True, default=str)
                           + sha(os.path.join(REPO, ".claude/auto/goals/wrun.md"))).encode()).hexdigest()
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
frozen() { run_py <<'EOF'
print(frozen())
EOF
}
wfield() { run_py "$1" <<'EOF'
rec = wrec()
b = rec["contract"]
print(json.dumps(eval(args[0]), sort_keys=True))
EOF
}
refuses() {
  local code="$1" phrase="$2" before="$3"
  it "refused ($code): exit 1, names the cause, no traceback"
  if [ "$CODE" = 1 ]; then case "$OUT" in *"refused ($code)"*"$phrase"*) pass ;; *) fail "expected [refused ($code)] naming [$phrase], got [$OUT]" ;; esac; else fail "exit $CODE: $OUT"; fi
  it "refused ($code): goal file, worker record and programme record unchanged"
  check "$before" "$(frozen)"
}

echo "── setup ──"

RUN="$(run_py <<'EOF'
import importlib.util
spec = importlib.util.spec_from_file_location("run_record", os.path.join(ROOT, "lib", "run_record.py"))
rr = importlib.util.module_from_spec(spec); spec.loader.exec_module(rr)
run = ph.create_programme(["w2"], "sess-pm")["run"]
def make_worker(repo, run_id, session, contract):
    rr.init_run_record(repo, run_id, backend="ce", loop_phase="work", steps=[{"id": "U1", "state": "pending"}])
    def put(rec):
        rec["driving_session_id"] = session
        if contract is not None:
            rec["contract"] = contract
    core._with_locked_run_record(repo, run_id, put)
def contract():
    return wc.new_contract(set_by="sess-pm", authority={"technical_approach": {"mode": "act", "asks": "pm"}},
                           workflow="a2", fan_out_cap=2,
                           done_bar={"internal": ["steps_terminal"], "external": ["pr_merged"]})
make_worker(REPO, "wrun", "sess-w", contract())
make_worker(OTHER, "orun", "sess-x", contract())
make_worker(PLAIN, "prun", "sess-p", None)
def seed(rec):
    prog = rec["programme"]
    def bound(key, title, session, repo, run_id, plan="docs/plans/x.md", state="bound"):
        item = ph.new_item(key, title)
        item["owner"] = {"session_id": session}
        item["repo"] = repo
        item["auto_run"] = {"state": state, "run_id": run_id, "path": repo, "plan": plan, "session_id": session,
                            "contract": None}
        prog["items"][key] = item
    bound("linear:AI-1", "Worker item", "sess-w", REPO, "wrun")
    bound("linear:AI-2", "Outside the remit", "sess-x", OTHER, "orun")
    bound("linear:AI-3", "No contract", "sess-p", PLAIN, "prun")
    bound("linear:AI-4", "Launched only", "sess-l", REPO, None, state="launched")
    prog["remit"]["repos"] = [{"path": REPO}, {"path": PLAIN}]
core._with_locked_run_record(ph.home_path(run), run, seed)
print(run)
EOF
)"
export T_RUN="$RUN"
case "$RUN" in prog-*) pass ;; *) fail "programme setup failed: $RUN" ;; esac

echo "── generation ──"

it "write-goal is a registered programme verb"
prog describe
has "write-goal" "$OUT"

prog write-goal linear:AI-1 --run "$RUN" --outcome "a circle can be drawn and survives a reload" --outcome "the suite exits 0" --out-of-scope "the mobile layout"
it "the first write exits 0 and reports a created goal doc"
check '[0, "created", true, 1]' "$([ "$CODE" = 0 ] && echo "[0, $(jq_py '[d["mode"], d["written"], d["goal_version"]]' | tr -d '[]')]" || echo "[$CODE, $OUT]")"
it "the goal doc is a Markdown file under goals/ named for the run"
check "yes" "$([ -f "$GOAL" ] && echo yes || echo no)"
it "goals/ holds no JSON file, so no sweep can read a goal doc as a run record"
check "" "$(ls "${REPO}/.claude/auto/goals" | grep -c '\.json$' | grep -v '^0$')"
it "the run-record sweep yields the run record only"
check '["wrun"]' "$(run_py <<'EOF'
b = load_lib_module("_bootstrap")
print(json.dumps([r for r, _ in b.iter_worktree_run_records(REPO)]))
EOF
)"
it "the header carries the goal version, the contract version and the run"
check "<!-- goal-version: 1; contract-version: 2; run: wrun -->" "$(head -1 "$GOAL")"
BODY="$(cat "$GOAL")"
it "the doc leads with auto's exit predicate and inlines the outcomes the PM gave"
has "This goal is met when auto's exit predicate holds: every step in the plan is implemented and reviewed" "$BODY"
has "- a circle can be drawn and survives a reload" "$BODY"
it "the plan comes from the item's registered run, and the title from the plan"
has "Source plan: \`docs/plans/x.md\`" "$BODY"
has "# Goal: x" "$BODY"
it "external evidence stays out of the criteria: it is named on the out-of-scope line"
has "the PR merge, which the PM verifies outside this goal" "$BODY"
lacks "- the PR" "$BODY"
it "the contract records the goal version, and the engine-stamped bound version stays 0"
check '[1, 0, 2]' "$(wfield '[b["goal_version"], b.get("goal_bound_version", 0), b["version"]]')"
it "the write queued one pending entry for the new contract version, biting at the step boundary by default"
check '[{"bite": "step", "version": 2}]' "$(wfield 'b["pending_versions"]')"
it "goal-status reads the doc as current"
prog goal-status linear:AI-1 --run "$RUN"
check '["current", 2]' "$(jq_py '[d["state"], d["doc_contract_version"]]')"

echo "── AE7: a human-only step in the done bar ──"

run_py <<'EOF'
def add(rec):
    rec["steps"].append({"id": "U2", "state": "pending",
                         "verification": [{"id": "owner-signoff", "type": "human", "prompt": "Ship it?"}]})
core._with_locked_run_record(REPO, "wrun", add)
EOF
BEFORE="$(frozen)"
prog write-goal linear:AI-1 --run "$RUN" --outcome "x"
refuses human_only_step "U2 (human checkpoint owner-signoff)" "$BEFORE"
it "the refusal says why: the goal could never be met"
has "could never be met" "$OUT"
prog write-goal linear:AI-1 --run "$RUN" --done-internal gaps_closed --done-external none
it "a done bar without steps_terminal does not include that step, so it is accepted"
check 0 "$CODE"
run_py <<'EOF'
def clear(rec):
    for s in rec["steps"]:
        if s["id"] == "U2":
            s["state"] = "terminal-skip"
core._with_locked_run_record(REPO, "wrun", clear)
def reset(rec):
    rec["contract"]["done_bar"] = {"internal": ["steps_terminal"], "external": ["pr_merged"]}
core._with_locked_run_record(REPO, "wrun", reset)
EOF
prog write-goal linear:AI-1 --run "$RUN" --outcome "x"
it "a human step that is already terminal no longer blocks generation"
check 0 "$CODE"
BEFORE="$(frozen)"
prog write-goal linear:AI-1 --run "$RUN" --manual-step "click through the checkout flow in the UI" --done-internal gaps_closed
refuses human_only_step "click through the checkout flow in the UI" "$BEFORE"

echo "── guards: who may write, and where ──"

BEFORE="$(frozen)"
as sess-w write-goal linear:AI-1 --run "$RUN" --outcome "worker edit"
refuses not_driving "only the programme's driving session" "$BEFORE"

as sess-nobody write-goal linear:AI-1 --run "$RUN" --outcome "stranger"
refuses not_driving "only the programme's driving session" "$BEFORE"

prog write-goal linear:AI-2 --run "$RUN" --outcome "outside"
refuses outside_remit "is not in the programme's remit" "$BEFORE"

prog write-goal linear:AI-4 --run "$RUN" --outcome "launched"
refuses not_bound "no bound Auto run" "$BEFORE"

prog write-goal linear:AI-3 --run "$RUN" --outcome "plain"
refuses no_contract "no contract" "$BEFORE"

prog write-goal linear:AI-1 --run "$RUN" --bite later
refuses bad_bite "--bite must be one of" "$BEFORE"

prog write-goal linear:AI-1 --run "$RUN" --done-internal vibes
refuses bad_done_bar "names 'vibes'" "$BEFORE"

it "the check repeats inside the run-record lock: a lease lost between the first check and the write is refused"
OUT="$(run_py "$RUN" <<'EOF'
calls = {"n": 0}
real = wc.guard
def flaky(*a, **kw):
    calls["n"] += 1
    if calls["n"] >= 2:
        raise wc.ContractError("this session no longer holds the programme's lease; a handover or takeover moved write authority", "lease_lost")
    return real(*a, **kw)
wc.guard = flaky
before = frozen()
try:
    gd.write_goal(args[0], "linear:AI-1", {"outcome": ["late"]}, caller="sess-pm")
    print("WROTE")
except wc.ContractError as e:
    print(e.code, before == frozen(), calls["n"])
EOF
)"
check "lease_lost True 2" "$OUT"

it "a run that is done is refused and names the follow-up run"
run_py <<'EOF'
load_lib_module("run_record").set_loop(REPO, "wrun", loop_phase="done", driver="manual")
EOF
BEFORE="$(frozen)"
prog write-goal linear:AI-1 --run "$RUN" --outcome "late"
refuses run_done "start a follow-up run" "$BEFORE"
run_py <<'EOF'
load_lib_module("run_record").set_loop(REPO, "wrun", loop_phase="work", driver="self")
EOF

echo "── subagents ──"

it "a sub-agent's write-goal call is denied by the hook, and a read verb is not"
OUT="$("$PY" - "$AUTO_ROOT" <<'EOF'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("hook", sys.argv[1] + "/lib/on-pretooluse-subagent.py")
hook = importlib.util.module_from_spec(spec); spec.loader.exec_module(hook)
def call(cmd):
    event = json.dumps({"session_id": "sess-pm", "agent_id": "a1", "tool_name": "Bash", "tool_input": {"command": cmd}})
    return hook.decide(event, drives=lambda s: True)
denied = call("programme.sh write-goal linear:AI-1 --run prog-x --outcome y")
ok = call("programme.sh status --run prog-x")
print(bool(denied), ok is None)
EOF
)"
check "True True" "$OUT"

echo "── AE9: amendment under each goal_amend authority ──"

prog write-goal linear:AI-1 --run "$RUN" --outcome "first"
printf '{"autonomy": {"goal_amend": {"level": "propose"}}}' > "$CLAUDE_AUTO_PERSONAL_PROTOCOL"
SHA_GOAL="$(cat "$GOAL" | shasum)"
CONTRACT_BEFORE="$(wfield 'b')"
prog write-goal linear:AI-1 --run "$RUN" --outcome "second"
it "propose: the amendment waits on Shawn and writes nothing"
check '["waiting_on_shawn", false]' "$(jq_py '[d["state"], d["written"]]')"
it "propose: the goal file is byte-identical and the contract did not move"
check "${SHA_GOAL}|${CONTRACT_BEFORE}" "$(cat "$GOAL" | shasum)|$(wfield 'b')"
it "propose: the item is handed to Shawn with a goal_amend ask that carries the amendment"
check '["handed", "goal_amend", true]' "$(run_py <<'EOF'
item = load(RUN)["programme"]["items"]["linear:AI-1"]
print(json.dumps([item["state"], item["handed"]["kind"], any(e.startswith("amendment ") for e in item["handed"]["evidence"])]))
EOF
)"
ASK="$(run_py <<'EOF'
print(load(RUN)["programme"]["items"]["linear:AI-1"]["handed"]["id"])
EOF
)"
BEFORE="$(frozen)"
prog write-goal linear:AI-1 --run "$RUN" --outcome "second"
refuses item_handed "already waits on Shawn" "$BEFORE"
run_py <<'EOF'
def answer(rec):
    item = rec["programme"]["items"]["linear:AI-1"]
    item["state"] = "open"
    item["handed"]["answered"] = {"at": core.now_iso(), "choice": "ship", "prompt_id": "p1", "decision_id": "d1"}
core._with_locked_run_record(ph.home_path(RUN), RUN, answer)
EOF
prog write-goal linear:AI-1 --run "$RUN" --outcome "different from what Shawn saw" --approved "$ASK"
it "propose: an approval for a different amendment does not open the gate"
check '["waiting_on_shawn", false]' "$(jq_py '[d["state"], d["written"]]')"
it "propose: nothing written by the mismatched approval"
check "${SHA_GOAL}" "$(cat "$GOAL" | shasum)"
run_py <<'EOF'
core._with_locked_run_record(ph.home_path(RUN), RUN, lambda rec: rec["programme"]["items"]["linear:AI-1"].update(state="open"))
EOF
prog write-goal linear:AI-1 --run "$RUN" --outcome "second"
run_py <<'EOF'
def reopen(rec):
    item = rec["programme"]["items"]["linear:AI-1"]
    item["state"] = "open"
    item["handed"]["answered"] = {"at": core.now_iso(), "choice": "ship", "prompt_id": "p2", "decision_id": "d2"}
core._with_locked_run_record(ph.home_path(RUN), RUN, reopen)
EOF
ASK="$(run_py <<'EOF'
print(load(RUN)["programme"]["items"]["linear:AI-1"]["handed"]["id"])
EOF
)"
prog write-goal linear:AI-1 --run "$RUN" --outcome "second" --approved "$ASK"
it "propose: the amendment Shawn shipped lands when the PM comes back with the ask id"
check '[true, "amended"]' "$(jq_py '[d["written"], d["mode"]]')"
rm -f "$CLAUDE_AUTO_PERSONAL_PROTOCOL"

printf '{"autonomy": {"goal_amend": {"level": "never"}}}' > "$CLAUDE_AUTO_PERSONAL_PROTOCOL"
BEFORE="$(frozen)"
prog write-goal linear:AI-1 --run "$RUN" --outcome "third"
refuses authority_never "goal_amend is never" "$BEFORE"
rm -f "$CLAUDE_AUTO_PERSONAL_PROTOCOL"

SHA_GOAL="$(cat "$GOAL" | shasum)"
VERSION_BEFORE="$(wfield 'b["goal_version"]')"
prog write-goal linear:AI-1 --run "$RUN" --outcome "an act-and-tell outcome"
it "act_and_tell (the default): the amendment lands in place and the goal version rises by one"
check "[true, \"amended\", true, $((VERSION_BEFORE + 1))]" "$(jq_py '[d["written"], d["mode"], d["told"], d["goal_version"]]')"
it "act_and_tell: the file changed and holds the new outcome"
has "an act-and-tell outcome" "$(cat "$GOAL")"
it "act_and_tell: the header carries the new goal version"
has "goal-version: $((VERSION_BEFORE + 1));" "$(head -1 "$GOAL")"
it "act_and_tell: the report line names the amendment, and the journal row carries it for the next report"
has "Amended the goal doc of linear:AI-1" "$(jq_py 'd["tell"]')"
check "[true, \"linear:AI-1\"]" "$(run_py "$RUN" <<'EOF'
rows = [r for r in pj.read(args[0]) if r["kind"] == "goal_written" and (r["payload"] or {}).get("told")]
print(json.dumps([bool(rows and rows[-1]["payload"]["tell"]), rows[-1]["payload"]["item"]]))
EOF
)"

echo "── a done-bar change moves the goal doc and the contract in one version ──"

V_BEFORE="$(wfield 'b["version"]')"
prog write-goal linear:AI-1 --run "$RUN" --done-internal steps_terminal,gaps_closed --done-external none --bite pulse
it "the done bar on the contract changed and the version rose by exactly one"
check "[{\"external\": [], \"internal\": [\"steps_terminal\", \"gaps_closed\"]}, $((V_BEFORE + 1))]" "$(wfield '[b["done_bar"], b["version"]]')"
it "the goal doc states the new done bar and names the same contract version"
has "no plan gap remains open" "$(cat "$GOAL")"
has "contract-version: $((V_BEFORE + 1));" "$(head -1 "$GOAL")"
it "the pending entry for that version bites where the PM chose"
check "{\"bite\": \"pulse\", \"version\": $((V_BEFORE + 1))}" "$(wfield 'b["pending_versions"][-1]')"
it "the goal doc no longer lists the dropped external evidence"
lacks "the PM verifies outside" "$(cat "$GOAL")"

echo "── goal-stale is computed at read time ──"

prog goal-status linear:AI-1 --run "$RUN"
it "a goal doc written at the contract version reads current"
check '"current"' "$(jq_py 'd["state"]')"
run_py <<'EOF'
sys.path.insert(0, os.path.join(ROOT, "tests", "helpers"))
import contract_records
contract_records.request_change(REPO, "wrun", "step", fan_out_cap=5)
EOF
prog goal-status linear:AI-1 --run "$RUN"
it "a contract change that does not touch the goal doc leaves it behind: goal-stale"
check '["goal-stale", 1]' "$(jq_py '[d["state"], d["contract_version"] - d["doc_contract_version"]]')"
it "goal-stale is never stored on the contract or in the goal doc"
lacks "goal-stale" "$(wfield 'b'; cat "$GOAL")"
prog write-goal linear:AI-1 --run "$RUN" --outcome "refreshed"
prog goal-status linear:AI-1 --run "$RUN"
it "amending the goal doc brings it back to current"
check '"current"' "$(jq_py 'd["state"]')"

echo "── the contract block shape ──"

it "goal_bound_version may not pass goal_version, and both are integers"
OUT="$(run_py <<'EOF'
b = wc.new_contract(set_by="s", authority={}, done_bar={"internal": ["steps_terminal"], "external": []}, workflow="a2", fan_out_cap=1)
def attempt(**kw):
    try:
        wc.validate(dict(b, **kw))
        return "ok"
    except wc.ContractError as e:
        return e.code
print(json.dumps([attempt(goal_version=2, goal_bound_version=2), attempt(goal_version=1, goal_bound_version=2),
                  attempt(goal_version="1"), attempt(goal_version=-1)]))
EOF
)"
check '["ok", "bad_goal", "bad_goal", "bad_goal"]' "$OUT"

it "no command above crashed"
check "" "$CRASHES"

echo ""
echo "goal-doc.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
