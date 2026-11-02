#!/usr/bin/env bash
# auto unit test: the workflow re-bake (worker_rebake.py) — a contracted run's remaining steps are replaced when
# the applied contract names a new workflow, at the step boundary and never earlier, in one locked write.
#
# Every assertion pins a value and the presence of the key it reads: an absent baked-version stamp and a stamp of 0
# must read differently, and a skipped step must carry its reason text.
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

echo "worker-rebake.test.sh"

WORK="$(mktemp -d -t auto-wrebake.XXXXXX)"
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

printf '%s' '{"name":"rb-alpha","version":"1","phase_order":["work"],"terminal_phase":"work","steps":[{"id":"A1","phase":"work","depends_on":[],"invokes":{"backend_op":"review"}},{"id":"A2","phase":"work","depends_on":["A1"],"invokes":{"backend_op":"review"}}]}' > "${WF}/rb-alpha.json"
printf '%s' '{"name":"rb-beta","version":"1","phase_order":["work"],"terminal_phase":"work","steps":[{"id":"B1","phase":"work","depends_on":[],"invokes":{"backend_op":"review"}},{"id":"B2","phase":"work","depends_on":["B1"],"invokes":{"backend_op":"review"}}]}' > "${WF}/rb-beta.json"
printf '%s' '{"name":"rb-gamma","version":"1","phase_order":["work"],"terminal_phase":"work","steps":[{"id":"G1","phase":"work","depends_on":[],"invokes":{"backend_op":"review"}}]}' > "${WF}/rb-gamma.json"
printf '%s' '{"name":"rb-bad","version":"1","phase_order":["work"],"terminal_phase":"work","steps":[{"id":"X1","phase":"work","depends_on":["nowhere"],"invokes":{"backend_op":"review"}}]}' > "${WF}/rb-bad.json"
printf '%s' '{"name":"rb-grant","version":"1","phase_order":["work"],"terminal_phase":"work","authority":{"product_scope":{"mode":"act","asks":"pm"}},"steps":[{"id":"X1","phase":"work","depends_on":[],"invokes":{"backend_op":"review"}}]}' > "${WF}/rb-grant.json"
printf '%s' '{"name":"rb-plan","version":"1","phase_order":["plan","handoff","work"],"terminal_phase":"work","phase_transitions":[],"steps":[{"id":"P1","phase":"plan","depends_on":[],"invokes":{"backend_op":"plan"}}]}' > "${WF}/rb-plan.json"

run_py() {
  "$PY" - "$AUTO_ROOT" "$REPO" "$@" <<PYEOF 2>&1
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
sys.path.insert(0, os.path.join(sys.argv[1], "tests", "helpers"))
from _bootstrap import load_lib_module
import contract_records as cr
core = load_lib_module("run_record_core")
mut = load_lib_module("run_record_mutators")
dispatcher = load_lib_module("dispatcher")
pulse = load_lib_module("pulse")
rb = load_lib_module("worker_rebake")
wc = load_lib_module("worker_contract")
REPO = sys.argv[2]
args = sys.argv[3:]
def new_run(run, flow="rb-alpha", cap=1, applied=1):
    core.init_run_record(REPO, run, backend="ce", loop_phase="work", phase_order=["work"], terminal_phase="work",
                         workflow={"name": flow, "source_tier": "workspace"},
                         steps=[{"id": "U1"}, {"id": "U2"}, {"id": "U3"}])
    cr.add_contract(REPO, run, cap=cap, applied=applied, workflow=flow)
def rec(run):
    return core.read_run_record(REPO, run)
def states(run):
    return {s["id"]: s["state"] for s in rec(run)["steps"]}
def reasons(run):
    return {s["id"]: s["skip_reason"] for s in rec(run)["steps"] if s["state"] == "terminal-skip"}
def baked(run):
    return rec(run)["workflow"]
def launcher(log):
    return lambda uid, attempt: log.append(uid)
$(cat)
PYEOF
}

echo "── AE2: the step boundary ──"

OUT="$(run_py <<'EOF'
new_run("ae2", cap=2)
dispatcher.dispatch_batch(REPO, "ae2", ["U1", "U2"], 2, launch_fn=launcher([]))
mut.record_verdict(REPO, "ae2", "U1", [{"severity": "minor", "note": "kept finding"}])
cr.request_change(REPO, "ae2", "step", workflow="rb-beta")
pulse.dispatch_pulse(REPO, "ae2")
print(json.dumps({"stage": "after-pulse", "states": states("ae2"), "baked": baked("ae2"), "state": rb.state(rec("ae2"))["state"]}, sort_keys=True))
res = dispatcher.dispatch_batch(REPO, "ae2", ["U3"], 2, launch_fn=launcher([]))
r = rec("ae2")
u1 = [s for s in r["steps"] if s["id"] == "U1"][0]
print(json.dumps({"stage": "after-wave", "states": states("ae2"), "reasons": reasons("ae2"), "baked": baked("ae2"),
                  "u1_findings": u1["findings"], "res": res, "applied": r["contract"]["applied_version"],
                  "state": rb.state(r)["state"]}, sort_keys=True))
EOF
)"
A_PULSE="$(printf '%s\n' "$OUT" | grep after-pulse)"
A_WAVE="$(printf '%s\n' "$OUT" | grep after-wave)"
it "a workflow change waiting for its step boundary is not re-baked at the pulse"
has '"state": "waiting"' "$A_PULSE"
has '"baked": {"name": "rb-alpha", "source_tier": "workspace"}' "$A_PULSE"
has '"U3": "pending"' "$A_PULSE"
lacks "rb-beta" "$(printf '%s' "$A_PULSE" | sed 's/"state": "waiting"//')"
it "the wave that applies the change re-bakes: pending old steps are skipped with the reason text"
has '"reasons": {"U3": "workflow replaced v2"}' "$A_WAVE"
it "the new workflow's steps carry the contract version and start pending"
has '"B1-v2": "pending"' "$A_WAVE"
has '"B2-v2": "pending"' "$A_WAVE"
it "the baked-version stamp and workflow name are written"
has '"baked": {"baked_from_contract_version": 2, "name": "rb-beta", "source_tier": "workspace"}' "$A_WAVE"
it "the dispatched step and its recorded finding are untouched"
has '"U2": "dispatched"' "$A_WAVE"
has '"U1": "verdict-returned"' "$A_WAVE"
has '"u1_findings": [{"note": "kept finding", "severity": "minor"}]' "$A_WAVE"
it "the old step the wave was asked to dispatch is rejected as skipped"
has '["U3", "rejected:not-pending(terminal-skip)"]' "$A_WAVE"
it "the applied contract version and re-bake state read current afterwards"
has '"applied": 2' "$A_WAVE"
has '"state": "current"' "$A_WAVE"

echo "── a finished step, then the next step comes from the new workflow ──"

OUT="$(run_py <<'EOF'
new_run("next")
dispatcher.dispatch_batch(REPO, "next", ["U1"], 1, launch_fn=launcher([]))
mut.record_verdict(REPO, "next", "U1", [])
cr.request_change(REPO, "next", "step", workflow="rb-beta")
log = []
res = dispatcher.dispatch_batch(REPO, "next", ["U2", "B1-v2"], 1, launch_fn=launcher(log))
print(json.dumps({"launched": log, "res": res, "states": states("next")}, sort_keys=True))
EOF
)"
it "after the boundary the same wave dispatches the new workflow's first step and rejects the old pending step"
has '"launched": ["B1-v2"]' "$OUT"
has '["U2", "rejected:not-pending(terminal-skip)"]' "$OUT"
has '"B1-v2": "dispatched"' "$OUT"
has '"B2-v2": "pending"' "$OUT"
has '"U1": "verdict-returned"' "$OUT"

echo "── crash between the contract write and the re-bake ──"

OUT="$(run_py <<'EOF'
new_run("crash")
cr.request_change(REPO, "crash", "pulse", workflow="rb-beta")
# the pulse bite lands (applied v2) but the process dies before the re-bake runs
core._with_locked_run_record(REPO, "crash", lambda r: r["contract"].update(applied_version=2, pending_versions=[]))
before = rec("crash")
print(json.dumps({"stage": "crashed", "state": rb.state(before), "states": states("crash"), "baked": baked("crash")}, sort_keys=True))
pulse.dispatch_pulse(REPO, "crash")
once = rec("crash")
ids_once = [s["id"] for s in once["steps"]]
pulse.dispatch_pulse(REPO, "crash")
twice = rec("crash")
print(json.dumps({"stage": "recovered", "ids_once": ids_once, "ids_twice": [s["id"] for s in twice["steps"]],
                  "baked": twice["workflow"], "state": rb.state(twice)["state"], "reasons": reasons("crash")}, sort_keys=True))
EOF
)"
CRASHED="$(printf '%s\n' "$OUT" | grep '"stage": "crashed"')"
RECOVERED="$(printf '%s\n' "$OUT" | grep '"stage": "recovered"')"
it "a contract write with no re-bake leaves a detectable needs-re-bake state"
has '"state": "needs-re-bake"' "$CRASHED"
has '"baked_from_contract_version": 1' "$CRASHED"
has '"U2": "pending"' "$CRASHED"
it "the next pulse completes the re-bake exactly once"
has '"ids_once": ["U1", "U2", "U3", "B1-v2", "B2-v2"]' "$RECOVERED"
has '"ids_twice": ["U1", "U2", "U3", "B1-v2", "B2-v2"]' "$RECOVERED"
it "the stamp is written and the state reads current"
has '"baked": {"baked_from_contract_version": 2, "name": "rb-beta", "source_tier": "workspace"}' "$RECOVERED"
has '"state": "current"' "$RECOVERED"
it "the pulse's skipped steps carry the reason"
has '"reasons": {"U1": "workflow replaced v2", "U2": "workflow replaced v2", "U3": "workflow replaced v2"}' "$RECOVERED"

echo "── coalescing and no-ops ──"

OUT="$(run_py <<'EOF'
new_run("coal")
cr.request_change(REPO, "coal", "step", workflow="rb-beta")
cr.request_change(REPO, "coal", "step", workflow="rb-gamma")
pulse.dispatch_pulse(REPO, "coal")
mid = {"states": states("coal"), "state": rb.state(rec("coal"))["state"]}
dispatcher.dispatch_batch(REPO, "coal", [], 1, launch_fn=launcher([]))
r = rec("coal")
print(json.dumps({"mid": mid, "ids": [s["id"] for s in r["steps"]], "baked": r["workflow"], "applied": r["contract"]["applied_version"],
                  "reasons": reasons("coal")}, sort_keys=True))
EOF
)"
it "two workflow changes before the boundary coalesce into the latest, baked at the last version"
has '"ids": ["U1", "U2", "U3", "G1-v3"]' "$OUT"
has '"baked_from_contract_version": 3' "$OUT"
has '"name": "rb-gamma"' "$OUT"
lacks "B1-v2" "$OUT"
it "nothing was re-baked while both changes waited"
has '"mid": {"state": "waiting", "states": {"U1": "pending", "U2": "pending", "U3": "pending"}}' "$OUT"
OUT="$(run_py <<'EOF'
new_run("same")
cr.request_change(REPO, "same", "step", workflow="rb-beta")
cr.request_change(REPO, "same", "step", workflow="rb-alpha")
dispatcher.dispatch_batch(REPO, "same", [], 1, launch_fn=launcher([]))
r = rec("same")
print(json.dumps({"ids": [s["id"] for s in r["steps"]], "baked": r["workflow"], "applied": r["contract"]["applied_version"]}, sort_keys=True))
EOF
)"
it "a change that returns to the run's own workflow before the boundary re-bakes nothing"
has '"ids": ["U1", "U2", "U3"]' "$OUT"
has '"baked": {"name": "rb-alpha", "source_tier": "workspace"}' "$OUT"
has '"applied": 3' "$OUT"
OUT="$(run_py <<'EOF'
new_run("later")
cr.request_change(REPO, "later", "pulse", workflow="rb-beta")
cr.request_change(REPO, "later", "step", workflow="rb-gamma")
pulse.dispatch_pulse(REPO, "later")
r = rec("later")
print(json.dumps({"stage": "pulse", "applied": r["contract"]["applied_version"], "pending": r["contract"]["pending_versions"],
                  "ids": [s["id"] for s in r["steps"]], "baked": r["workflow"]["name"]}, sort_keys=True))
dispatcher.dispatch_batch(REPO, "later", [], 1, launch_fn=launcher([]))
r = rec("later")
print(json.dumps({"stage": "wave", "ids": [s["id"] for s in r["steps"]], "baked": r["workflow"]}, sort_keys=True))
new_run("seedmismatch", flow="rb-alpha")
core._with_locked_run_record(REPO, "seedmismatch", lambda r: r["contract"].update(workflow="rb-beta"))
pulse.dispatch_pulse(REPO, "seedmismatch")
print(json.dumps({"stage": "seed", "ids": [s["id"] for s in rec("seedmismatch")["steps"]], "baked": baked("seedmismatch")}, sort_keys=True))
new_run("finished")
cr.request_change(REPO, "finished", "pulse", workflow="rb-beta")
core._with_locked_run_record(REPO, "finished", lambda r: r.update(loop_phase="done"))
pulse.dispatch_pulse(REPO, "finished")
print(json.dumps({"stage": "done", "ids": [s["id"] for s in rec("finished")["steps"]], "baked": baked("finished")}, sort_keys=True))
EOF
)"
it "a pulse-bite workflow change is not baked while a later change is still pending"
has '{"applied": 2, "baked": "rb-alpha", "ids": ["U1", "U2", "U3"], "pending": [{"bite": "step", "version": 3}], "stage": "pulse"}' "$OUT"
it "the later change is baked at its own boundary, not the earlier one"
has '"ids": ["U1", "U2", "U3", "G1-v3"], "stage": "wave"' "$OUT"
it "a run whose own workflow differs from the seed contract's is not re-baked at version 1"
has '"stage": "seed"' "$OUT"
has '"ids": ["U1", "U2", "U3"], "stage": "seed"' "$OUT"
it "a finished run is never re-baked"
has '"ids": ["U1", "U2", "U3"], "stage": "done"' "$OUT"
has '"baked": {"name": "rb-alpha", "source_tier": "workspace"}, "ids": ["U1", "U2", "U3"], "stage": "done"' "$OUT"
OUT="$(run_py <<'EOF'
new_run("nochange", applied=1)
cr.request_change(REPO, "nochange", "pulse", fan_out_cap=2)
pulse.dispatch_pulse(REPO, "nochange")
print(json.dumps({"ids": [s["id"] for s in rec("nochange")["steps"]], "baked": baked("nochange"), "state": rb.state(rec("nochange"))["state"]}, sort_keys=True))
core.init_run_record(REPO, "plain", backend="ce", loop_phase="work", steps=[{"id": "U1"}])
print(json.dumps({"plain": rb.state(rec("plain")), "complete": rb.complete(REPO, "plain")}, sort_keys=True))
EOF
)"
it "a contract change that is not a workflow change leaves the steps and the stamp alone"
has '"ids": ["U1", "U2", "U3"]' "$OUT"
has '"baked": {"name": "rb-alpha", "source_tier": "workspace"}' "$OUT"
has '"state": "current"' "$OUT"
it "a record with no contract reads no_contract and re-bakes nothing"
has '"plain": {"state": "no_contract"}' "$OUT"
has '"complete": {"rebaked": false, "state": "no_contract"}' "$OUT"

echo "── refusals ──"

OUT="$(run_py <<'EOF'
def attempt(name, record=None):
    try:
        rb.check_workflow(name, REPO, record)
        return "accepted"
    except wc.ContractError as exc:
        return exc.code
print(json.dumps({"unknown": attempt("rb-nope"), "bad": attempt("rb-bad"), "grant": attempt("rb-grant"),
                  "good": attempt("rb-beta"), "traversal": attempt("../etc/x")}, sort_keys=True))
new_run("phase")
print(json.dumps({"empty": attempt("rb-plan", rec("phase")), "ok": attempt("rb-beta", rec("phase"))}, sort_keys=True))
EOF
)"
it "an unknown workflow name is refused with unknown_workflow"
has '"unknown": "unknown_workflow"' "$OUT"
has '"traversal": "unknown_workflow"' "$OUT"
it "a workflow the validator rejects is refused with rejected_workflow"
has '"bad": "rejected_workflow"' "$OUT"
it "a workflow file carrying authority keys is rejected, so a workflow cannot grant authority"
has '"grant": "rejected_workflow"' "$OUT"
it "a valid workflow is accepted"
has '"good": "accepted"' "$OUT"
it "a workflow with no step in the run's remaining phases is refused"
has '"empty": "empty_workflow"' "$OUT"
has '"ok": "accepted"' "$OUT"

OUT="$(run_py <<'EOF'
new_run("blocked")
cr.request_change(REPO, "blocked", "pulse", workflow="rb-plan")
pulse.dispatch_pulse(REPO, "blocked")
r = rec("blocked")
res = rb.complete(REPO, "blocked")
print(json.dumps({"states": states("blocked"), "baked": r["workflow"], "complete_state": res["state"], "why": res.get("why", "")}, sort_keys=True))
EOF
)"
it "a workflow that cannot be baked leaves the run as it was and reads re-bake-blocked"
has '"complete_state": "re-bake-blocked"' "$OUT"
has '"U2": "pending"' "$OUT"
has '"baked": {"name": "rb-alpha", "source_tier": "workspace"}' "$OUT"
has "nothing would remain" "$OUT"

echo "── set-contract refuses at write time ──"

RUN="$(run_py <<'EOF'
ph = load_lib_module("programme_home")
run = ph.create_programme(["w2"], "sess-pm")["run"]
AUTH = {"technical_approach": {"mode": "act", "asks": "pm"}}
BAR = {"internal": ["steps_terminal"], "external": []}
new_run("wrun")
core._with_locked_run_record(REPO, "wrun", lambda r: r.update(contract_capable=True, driving_session_id="sess-w"))
def seed(rec):
    prog = rec["programme"]
    prog["remit"]["repos"] = [{"path": REPO}]
    item = ph.new_item("linear:AI-1", "Item")
    item["owner"] = {"session_id": "sess-w"}
    item["repo"] = REPO
    item["auto_run"] = {"state": "bound", "run_id": "wrun", "path": REPO, "session_id": "sess-w", "contract": None, "mode": 1, "attempts": 1}
    prog["items"]["linear:AI-1"] = item
core._with_locked_run_record(ph.home_path(run), run, seed)
print(run)
EOF
)"
export T_RUN="$RUN"
OUT=""
CODE=0
prog() {
  OUT="$("$PY" "$PROG" "$@" 2>&1)"
  CODE=$?
}
before="$(run_py <<'EOF'
print(rec("wrun")["contract"]["version"])
EOF
)"
prog set-contract --run "$RUN" --item linear:AI-1 --workflow rb-nope
it "set-contract refuses an unknown workflow name and the contract version does not move"
has "refused (unknown_workflow)" "$OUT"
check "$before" "$(run_py <<'EOF'
print(rec("wrun")["contract"]["version"])
EOF
)"
prog set-contract --run "$RUN" --item linear:AI-1 --workflow rb-bad
it "set-contract refuses a workflow the validator rejects"
has "refused (rejected_workflow)" "$OUT"
prog set-contract --run "$RUN" --item linear:AI-1 --workflow rb-beta
it "set-contract accepts a resolvable, valid workflow and queues the change"
has '"ok": true' "$OUT"
check "rb-beta" "$(run_py <<'EOF'
print(rec("wrun")["contract"]["workflow"])
EOF
)"

echo "worker-rebake.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
