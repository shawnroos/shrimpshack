#!/usr/bin/env bash
# auto unit test: the PM's workflow design path (R17, R3, KTD13) — workflow_design.py and its gate on
# set-contract --workflow.
#
# A refusal assertion pins the refusal CODE and a phrase of its message, and checks the worker run records and
# the programme record did not move: a missing check also exits non-zero, so a bare exit code proves nothing.
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

echo "worker-workflow-design.test.sh"

WORK="$(mktemp -d -t auto-wfdesign.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export HOME="${WORK}/home"
mkdir -p "$HOME"
export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_AUTO_MACHINE="studio"
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
WF="${REPO}/.claude/auto/workflows"
mkdir -p "$WF"
export T_REPO="$REPO"

STEP='{"id":"%s","phase":"work","depends_on":[],"invokes":{"backend_op":"review"%s}}'
wf() { printf '{"name":"%s","version":"1","phase_order":["work"],"terminal_phase":"work"%s,"steps":[%s]}' "$1" "$2" "$3"; }
step() { printf "$STEP" "$1" "$2"; }
wf rb-alpha "" "$(step A1 "")" > "${WF}/rb-alpha.json"
wf rb-beta "" "$(step B1 "")" > "${WF}/rb-beta.json"
wf rb-gamma "" "$(step G1 "")" > "${WF}/rb-gamma.json"
wf rb-bad "" '{"id":"X1","phase":"work","depends_on":["nowhere"],"invokes":{"backend_op":"review"}}' > "${WF}/rb-bad.json"
wf rb-grant ',"authority":{"product_scope":{"mode":"act","asks":"pm"}}' "$(step X1 "")" > "${WF}/rb-grant.json"
wf rb-nested "" "$(step X1 ',"autonomy":"act","product_scope":"act"')" > "${WF}/rb-nested.json"

run_py() {
  "$PY" - "$AUTO_ROOT" "$REPO" "$@" <<PYEOF 2>&1
import hashlib, json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
sys.path.insert(0, os.path.join(sys.argv[1], "tests", "helpers"))
from _bootstrap import load_lib_module
ph = load_lib_module("programme_home")
core = load_lib_module("run_record_core")
wc = load_lib_module("worker_contract")
dispatcher = load_lib_module("dispatcher")
pulse = load_lib_module("pulse")
rb = load_lib_module("worker_rebake")
wd = load_lib_module("workflow_design")
from programme_records import load
REPO = sys.argv[2]
RUN = os.environ.get("T_RUN", "")
args = sys.argv[3:]
def rec(run):
    return core.read_run_record(REPO, run)
def frozen():
    body = json.dumps([load(RUN)["programme"], rec("wrun"), rec("wrun2")], sort_keys=True, default=str)
    return hashlib.sha256(body.encode()).hexdigest()
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
jq_py() {
  "$PY" -c "import json,sys; d=json.loads(sys.stdin.read()); print(json.dumps($1, sort_keys=True))" <<< "$OUT" 2>&1
}
frozen() { run_py <<'EOF'
print(frozen())
EOF
}
refuses() {
  local code="$1" phrase="$2" before="$3"
  it "refused ($code): exit 1, names the cause, no traceback"
  if [ "$CODE" = 1 ]; then case "$OUT" in *"refused ($code)"*"$phrase"*) pass ;; *) fail "expected [refused ($code)] naming [$phrase], got [$OUT]" ;; esac; else fail "exit $CODE: $OUT"; fi
  it "refused ($code): both run records and the programme record unchanged"
  check "$before" "$(frozen)"
}
contract_of() { run_py "$1" <<'EOF'
b = rec(args[0])["contract"]
print(json.dumps({"workflow": b["workflow"], "version": b["version"], "pending": b.get("pending_versions", [])}, sort_keys=True))
EOF
}

echo "── setup ──"

RUN="$(run_py <<'EOF'
run = ph.create_programme(["w2"], "sess-pm")["run"]
BAR = {"internal": ["steps_terminal"], "external": []}
AUTH = {"technical_approach": {"mode": "act", "asks": "pm"}}
def make_worker(run_id, session):
    core.init_run_record(REPO, run_id, backend="ce", loop_phase="work", phase_order=["work"], terminal_phase="work",
                         driving_session_id=session, workflow={"name": "rb-alpha", "source_tier": "workspace"},
                         steps=[{"id": "U1"}, {"id": "U2"}, {"id": "U3"}])
    def put(r):
        block = wc.new_contract(set_by="sess-pm", authority=AUTH, done_bar=BAR, workflow="rb-alpha", fan_out_cap=2)
        block["applied_version"] = 1
        r["contract"] = wc.validate(block)
    core._with_locked_run_record(REPO, run_id, put)
make_worker("wrun", "sess-w")
make_worker("wrun2", "sess-w2")
def seed(r):
    prog = r["programme"]
    prog["remit"]["repos"] = [{"path": REPO}]
    for key, owner, run_id in (("linear:AI-1", "sess-w", "wrun"), ("linear:AI-2", "sess-w2", "wrun2")):
        item = ph.new_item(key, "Item " + key)
        item["owner"] = {"session_id": owner}
        item["repo"] = REPO
        item["auto_run"] = {"state": "bound", "run_id": run_id, "path": REPO, "plan": "docs/plans/x.md",
                            "session_id": owner, "contract": None}
        prog["items"][key] = item
core._with_locked_run_record(ph.home_path(run), run, seed)
dispatcher.dispatch_batch(REPO, "wrun", ["U1", "U2"], 2, launch_fn=lambda uid, attempt: None)
print(run)
EOF
)"
export T_RUN="$RUN"
case "$RUN" in prog-*) pass ;; *) fail "programme setup failed: $RUN" ;; esac

echo "── a contract may name only a workflow that resolves and validates ──"

BEFORE="$(frozen)"
prog set-contract --item linear:AI-1 --run "$RUN" --workflow rb-nope
refuses unknown_workflow "cannot be used" "$BEFORE"
prog set-contract --item linear:AI-1 --run "$RUN" --workflow rb-bad
refuses rejected_workflow "rejected by the validator" "$BEFORE"

echo "── a workflow cannot grant authority ──"

prog set-contract --item linear:AI-1 --run "$RUN" --workflow rb-grant
refuses rejected_workflow "unknown top-level field: 'authority'" "$BEFORE"
prog set-contract --item linear:AI-1 --run "$RUN" --workflow rb-nested
refuses workflow_authority "carries authority keys ['steps[0].invokes.autonomy', 'steps[0].invokes.product_scope']" "$BEFORE"
it "the refusal sends the PM to the contract's own authority verb"
has "set authority with set-contract --authority" "$OUT"

it "the vocabulary is derived from the contract: every mode, asks value and decision kind is a refused key"
check '[true, true, true, true]' "$(run_py <<'EOF'
kinds = set(load_lib_module("programme_decisions").DECISION_KINDS)
print(json.dumps([{"act_and_tell", "propose", "never", "act", "pm", "shawn"} <= wd.AUTHORITY_KEYS,
                  kinds <= wd.AUTHORITY_KEYS,
                  {"authority", "autonomy", "asks", "allow"} <= wd.AUTHORITY_KEYS
                  and wd.authority_keys_in({"decision": 1}) == ["decision"],
                  wd.authority_keys_in({"steps": [{"id": "U1", "invokes": {"backend_op": "review"}}]}) == []]))
EOF
)"

echo "── the design-time check on a draft file ──"

OUT="$("$PY" "${AUTO_ROOT}/lib/workflow_design.py" check "${WF}/rb-beta.json" 2>&1)"; CODE=$?
it "a clean draft passes the check"
check "0|ok" "${CODE}|${OUT}"
OUT="$("$PY" "${AUTO_ROOT}/lib/workflow_design.py" check "${WF}/rb-grant.json" 2>&1)"; CODE=$?
it "a draft with an authority key fails the check, exit 1, naming the key"
has "refused: workflow 'rb-grant' carries authority keys ['authority', 'authority.product_scope'" "${OUT}"
check 1 "$CODE"
OUT="$("$PY" "${AUTO_ROOT}/lib/workflow_design.py" check "${WF}/rb-bad.json" 2>&1)"; CODE=$?
it "a draft the validator rejects fails the check, exit 1"
check 1 "$CODE"

echo "── workflow_change as propose: the change waits on Shawn ──"

printf '{"autonomy": {"workflow_change": {"level": "propose"}}}' > "$CLAUDE_AUTO_PERSONAL_PROTOCOL"
BEFORE="$(frozen)"
RUN_BEFORE="$(contract_of wrun)"
prog set-contract --item linear:AI-1 --run "$RUN" --workflow rb-beta
it "propose: the result is waiting_on_shawn, nothing written, and the exit is 0"
check '0|["waiting_on_shawn", false, "rb-beta"]' "${CODE}|$(jq_py '[d["state"], d["written"], d["workflow"]]')"
it "propose: the worker's contract did not move (workflow, version and pending list)"
check "$RUN_BEFORE" "$(contract_of wrun)"
it "propose: the item is handed to Shawn with a workflow_change ask that carries the change digest"
check '["handed", "workflow_change", true]' "$(run_py <<'EOF'
item = load(RUN)["programme"]["items"]["linear:AI-1"]
print(json.dumps([item["state"], item["handed"]["kind"], any(e.startswith("workflow ") for e in item["handed"]["evidence"])]))
EOF
)"
ASK="$(run_py <<'EOF'
print(load(RUN)["programme"]["items"]["linear:AI-1"]["handed"]["id"])
EOF
)"
BEFORE="$(frozen)"
prog set-contract --item linear:AI-1 --run "$RUN" --workflow rb-beta
refuses item_handed "already waits on Shawn" "$BEFORE"
run_py <<'EOF'
def answer(r):
    item = r["programme"]["items"]["linear:AI-1"]
    item["state"] = "open"
    item["handed"]["answered"] = {"at": core.now_iso(), "choice": "ship", "prompt_id": "p1", "decision_id": "d1"}
core._with_locked_run_record(ph.home_path(RUN), RUN, answer)
EOF
prog set-contract --item linear:AI-1 --run "$RUN" --workflow rb-gamma --approved "$ASK"
it "propose: Shawn's approval of rb-beta does not open the gate for a different workflow"
check '["waiting_on_shawn", false]' "$(jq_py '[d["state"], d["written"]]')"
it "propose: the mismatched approval left the contract as it was"
check "$RUN_BEFORE" "$(contract_of wrun)"
run_py <<'EOF'
def reopen(r):
    item = r["programme"]["items"]["linear:AI-1"]
    item["state"] = "open"
    item["handed"]["answered"] = {"at": core.now_iso(), "choice": "ship", "prompt_id": "p2", "decision_id": "d2"}
core._with_locked_run_record(ph.home_path(RUN), RUN, reopen)
EOF
ASK="$(run_py <<'EOF'
print(load(RUN)["programme"]["items"]["linear:AI-1"]["handed"]["id"])
EOF
)"
prog set-contract --item linear:AI-1 --run "$RUN" --workflow rb-beta --approved "$ASK"
it "propose: an ask Shawn shipped for a different workflow (rb-gamma) does not open the gate for rb-beta"
check '["waiting_on_shawn", false]' "$(jq_py '[d["state"], d["written"]]')"
run_py <<'EOF'
def reopen(r):
    item = r["programme"]["items"]["linear:AI-1"]
    item["state"] = "open"
    item["handed"]["answered"] = {"at": core.now_iso(), "choice": "ship", "prompt_id": "p3", "decision_id": "d3"}
core._with_locked_run_record(ph.home_path(RUN), RUN, reopen)
EOF
ASK="$(run_py <<'EOF'
print(load(RUN)["programme"]["items"]["linear:AI-1"]["handed"]["id"])
EOF
)"
prog set-contract --item linear:AI-1 --run "$RUN" --workflow rb-beta --approved "ask-not-the-handed-one"
it "propose: an ask id that is not the handed ask does not open the gate"
check '["waiting_on_shawn", false]' "$(jq_py '[d["state"], d["written"]]')"
run_py <<'EOF'
def hold(r):
    item = r["programme"]["items"]["linear:AI-1"]
    item["state"] = "open"
    item["handed"]["answered"] = {"at": core.now_iso(), "choice": "hold", "prompt_id": "p4", "decision_id": "d4"}
core._with_locked_run_record(ph.home_path(RUN), RUN, hold)
EOF
ASK="$(run_py <<'EOF'
print(load(RUN)["programme"]["items"]["linear:AI-1"]["handed"]["id"])
EOF
)"
prog set-contract --item linear:AI-1 --run "$RUN" --workflow rb-beta --approved "$ASK"
it "propose: an answer that is not a ship does not open the gate"
check '["waiting_on_shawn", false]' "$(jq_py '[d["state"], d["written"]]')"
run_py <<'EOF'
def reopen(r):
    item = r["programme"]["items"]["linear:AI-1"]
    item["state"] = "open"
    item["handed"]["answered"] = {"at": core.now_iso(), "choice": "ship", "prompt_id": "p5", "decision_id": "d5"}
core._with_locked_run_record(ph.home_path(RUN), RUN, reopen)
EOF
ASK="$(run_py <<'EOF'
print(load(RUN)["programme"]["items"]["linear:AI-1"]["handed"]["id"])
EOF
)"
prog set-contract --item linear:AI-1 --run "$RUN" --workflow rb-beta --approved "$ASK"
it "propose: the change Shawn shipped lands when the PM comes back with the ask id"
check '0|{"pending": [{"bite": "step", "version": 2}], "version": 2, "workflow": "rb-beta"}' "${CODE}|$(contract_of wrun)"

echo "── workflow_change as never ──"

printf '{"autonomy": {"workflow_change": {"level": "never"}}}' > "$CLAUDE_AUTO_PERSONAL_PROTOCOL"
BEFORE="$(frozen)"
prog set-contract --item linear:AI-2 --run "$RUN" --workflow rb-beta
refuses authority_never "workflow_change is never" "$BEFORE"

echo "── workflow_change as act_and_tell: the second item in the same repo names the same workflow ──"

printf '{"autonomy": {"workflow_change": {"level": "act_and_tell"}}}' > "$CLAUDE_AUTO_PERSONAL_PROTOCOL"
prog set-contract --item linear:AI-2 --run "$RUN" --workflow rb-beta
it "act_and_tell: the second item's contract names the repo-tier workflow and the result carries a tell"
check '0|{"pending": [{"bite": "step", "version": 2}], "version": 2, "workflow": "rb-beta"}' "${CODE}|$(contract_of wrun2)"
check 'Changed the workflow of linear:AI-2 from rb-alpha to rb-beta.' "$(jq_py 'd["tell"]' | tr -d '"')"
it "the name resolves to the repo tier for both items"
check '"workspace"' "$(run_py <<'EOF'
print(json.dumps(load_lib_module("workflows").resolve("rb-beta", REPO)[1]))
EOF
)"
rm -f "$CLAUDE_AUTO_PERSONAL_PROTOCOL"

echo "── workflow_change as act: the gate proceeds with no tell ──"

prog set-contract --item linear:AI-2 --run "$RUN" --workflow rb-alpha
it "with no protocol file the level is act_and_tell, so a change carries a tell"
check 'true' "$(jq_py '"tell" in d' | tr 'A-Z' 'a-z')"
it "act: gate returns neither a waiting result nor a tell"
check '[null, null]' "$(run_py <<'PYX'
record = core.read_run_record(ph.home_path(RUN), RUN)
state = record["programme"]["items"]["linear:AI-2"]["auto_run"]
real = wc.effective_authority
wc.effective_authority = lambda *a, **k: {"mode": "act", "asks": "pm", "reason": "authority"}
try:
    print(json.dumps(list(wd.gate(record, RUN, "linear:AI-2", state, "rb-gamma"))))
finally:
    wc.effective_authority = real
PYX
)"
it "naming the workflow the contract already has is not a change: the gate reads no authority, even never"
check '[null, null]' "$(run_py <<'PYX'
record = core.read_run_record(ph.home_path(RUN), RUN)
state = record["programme"]["items"]["linear:AI-2"]["auto_run"]
real = wc.effective_authority
wc.effective_authority = lambda *a, **k: {"mode": "never", "asks": "pm", "reason": "authority"}
try:
    print(json.dumps(list(wd.gate(record, RUN, "linear:AI-2", state, wc.contract_of(core.read_run_record(REPO, "wrun2"))["workflow"]))))
finally:
    wc.effective_authority = real
PYX
)"

echo "── the run re-bakes onto the named workflow at the step boundary ──"

OUT="$(run_py <<'EOF'
pulse.dispatch_pulse(REPO, "wrun")
before = {"state": rb.state(rec("wrun"))["state"], "name": rec("wrun")["workflow"]["name"]}
res = dispatcher.dispatch_batch(REPO, "wrun", ["U3"], 2, launch_fn=lambda uid, attempt: None)
r = rec("wrun")
print(json.dumps({"before": before, "after": r["workflow"], "state": rb.state(r)["state"],
                  "skipped": {s["id"]: s["skip_reason"] for s in r["steps"] if s["state"] == "terminal-skip"},
                  "added": sorted(s["id"] for s in r["steps"] if s["id"].endswith("-v2")),
                  "applied": r["contract"]["applied_version"]}, sort_keys=True))
EOF
)"
it "the pulse alone does not re-bake: the change waits for its step boundary"
has '"before": {"name": "rb-alpha", "state": "waiting"}' "$OUT"
it "the wave that applies the change re-bakes onto the repo-tier workflow and stamps the baked version"
has '"after": {"baked_from_contract_version": 2, "name": "rb-beta", "source_tier": "workspace"}' "$OUT"
has '"added": ["B1-v2"]' "$OUT"
has '"skipped": {"U3": "workflow replaced v2"}' "$OUT"
has '"state": "current"' "$OUT"

echo "── the matching goal doc comes from write-goal, not from this module ──"

prog write-goal linear:AI-1 --run "$RUN" --outcome "the beta workflow's review step passes"
it "write-goal creates the goal doc for the run the workflow was named on"
check "0|yes" "${CODE}|$([ -f "${REPO}/.claude/auto/goals/wrun.md" ] && echo yes || echo no)"
it "the goal doc is stamped by goal_doc: header carries the goal version, contract version and run"
check "<!-- goal-version: 1; contract-version: 3; run: wrun -->" "$(head -1 "${REPO}/.claude/auto/goals/wrun.md")"
it "workflow_design.py has no goal-doc writer: no goals directory, no goal header and no file write"
check "0" "$(grep -c -E "goal-version|GOALS_DIR|goals|_atomic_write|open\(.*\"w\"" "${AUTO_ROOT}/lib/workflow_design.py")"
it "set-contract passes the workflow through workflow_design.gate, the one place the change authority is read"
check "1" "$(grep -c "workflow_design.gate(" "${AUTO_ROOT}/lib/worker_contract_write.py")"

it "no command crashed with a traceback"
check "" "$CRASHES"

echo ""
echo "worker-workflow-design.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
