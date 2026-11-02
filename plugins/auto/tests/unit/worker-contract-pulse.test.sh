#!/usr/bin/env bash
# auto unit test: the engine side of a worker's PM-set contract — the pulse applies "pulse" bites, the wave
# and the dispatch prompt apply "step" bites, dispatch_batch clamps to the contract cap, and a record with no
# contract behaves as before.
#
# Every assertion pins a value and the presence of the key it reads: an absent `contract` key and an empty
# `pending_versions` list must read differently.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
ON_STOP="${AUTO_ROOT}/lib/on-stop.py"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
check() { if [ "$1" = "$2" ]; then pass; else fail "expected [$1] got [$2]"; fi; }
has() { case "$2" in *"$1"*) pass ;; *) fail "expected to find [$1] in [$2]" ;; esac; }
lacks() { case "$2" in *"$1"*) fail "did not expect [$1] in [$2]" ;; *) pass ;; esac; }

echo "worker-contract-pulse.test.sh"

WORK="$(mktemp -d -t auto-wc-pulse.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_AUTO_MACHINE="studio"
unset CLAUDE_CODE_SESSION_ID CLAUDE_AUTO_REPO HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH 2>/dev/null || true
: > "$CLAUDE_AUTO_SECRETS_FILE"
REPO="${WORK}/repo"
mkdir -p "${REPO}/.claude/auto"

run_py() {
  "$PY" - "$AUTO_ROOT" "$REPO" "$@" <<PYEOF 2>&1
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
sys.path.insert(0, os.path.join(sys.argv[1], "tests", "helpers"))
from _bootstrap import load_lib_module
import contract_records as cr
core = load_lib_module("run_record_core")
dispatcher = load_lib_module("dispatcher")
pulse = load_lib_module("pulse")
dp = load_lib_module("dispatch_prompt")
apply_mod = load_lib_module("worker_contract_apply")
REPO = sys.argv[2]
args = sys.argv[3:]
def new_run(run, n, contract=True, **kw):
    core.init_run_record(REPO, run, backend="ce", steps=[{"id": f"U{i}"} for i in range(1, n + 1)],
                         loop_phase="work", **kw)
    if contract:
        cr.add_contract(REPO, run, **({"cap": 3, "applied": 1}))
def rec(run):
    return core.read_run_record(REPO, run)
def states(run):
    return {s["id"]: s["state"] for s in rec(run)["steps"]}
def launcher(log):
    return lambda uid, attempt: log.append(uid)
$(cat)
PYEOF
}

echo "── pulse start ──"

it "AE1: a narrowed authority with bite pulse is applied at the next pulse and shown in the guidance"
OUT="$(run_py <<'EOF'
new_run("ae1", 2)
cr.request_change(REPO, "ae1", "pulse", authority={"technical_approach": {"mode": "act", "asks": "pm"},
                                                  "product_scope": {"mode": "propose", "asks": "shawn"}})
before = rec("ae1")["contract"]
r = pulse.dispatch_pulse(REPO, "ae1")
c = rec("ae1")["contract"]
print(json.dumps({"before_applied": before["applied_version"], "before_pending": before["pending_versions"],
                  "applied": c["applied_version"], "has_pending_key": "pending_versions" in c, "pending": c["pending_versions"],
                  "guidance": r["operator_guidance"]}, sort_keys=True))
EOF
)"
has '"applied": 2' "$OUT"
has '"before_applied": 1' "$OUT"
has '"has_pending_key": true' "$OUT"
has '"pending": []' "$OUT"
has "PM CONTRACT v2 (applied v2)" "$OUT"
has "product_scope=propose (asks shawn)" "$OUT"
has "Done bar: internal steps_terminal; external none." "$OUT"

it "a pulse with a fresh contract at version 1 records applied_version 1"
OUT="$(run_py <<'EOF'
new_run("fresh", 1)
cr.add_contract(REPO, "fresh", applied=0)
pulse.dispatch_pulse(REPO, "fresh")
print(rec("fresh")["contract"]["applied_version"])
EOF
)"
check "1" "$OUT"

it "a step-boundary entry is not applied at the next pulse"
OUT="$(run_py <<'EOF'
new_run("stepbite", 2)
cr.request_change(REPO, "stepbite", "step", fan_out_cap=1)
pulse.dispatch_pulse(REPO, "stepbite")
c = rec("stepbite")["contract"]
print(json.dumps({"applied": c["applied_version"], "pending": c["pending_versions"]}, sort_keys=True))
EOF
)"
check '{"applied": 1, "pending": [{"bite": "step", "version": 2}]}' "$OUT"

it "the same step-boundary entry is applied at the next wave, and that wave obeys the new cap"
OUT="$(run_py <<'EOF'
new_run("stepwave", 3)
cr.request_change(REPO, "stepwave", "step", fan_out_cap=1)
pulse.dispatch_pulse(REPO, "stepwave")
log = []
res = dispatcher.dispatch_batch(REPO, "stepwave", ["U1", "U2", "U3"], 16, launch_fn=launcher(log))
c = rec("stepwave")["contract"]
print(json.dumps({"applied": c["applied_version"], "pending": c["pending_versions"], "launched": log,
                  "results": res}, sort_keys=True))
EOF
)"
has '"applied": 2' "$OUT"
has '"pending": []' "$OUT"
has '"launched": ["U1"]' "$OUT"
has '"rejected:over-cap"' "$OUT"

it "a pulse entry stays pending at a wave and the applied version does not pass it"
OUT="$(run_py <<'EOF'
new_run("mixed", 2)
cr.request_change(REPO, "mixed", "pulse", workflow="a4")
cr.request_change(REPO, "mixed", "step", fan_out_cap=2)
dispatcher.dispatch_batch(REPO, "mixed", ["U1"], 1, launch_fn=launcher([]))
c = rec("mixed")["contract"]
print(json.dumps({"applied": c["applied_version"], "pending": c["pending_versions"]}, sort_keys=True))
pulse.dispatch_pulse(REPO, "mixed")
c = rec("mixed")["contract"]
print(json.dumps({"applied": c["applied_version"], "pending": c["pending_versions"]}, sort_keys=True))
EOF
)"
check '{"applied": 1, "pending": [{"bite": "pulse", "version": 2}]}' "$(echo "$OUT" | sed -n 1p)"
check '{"applied": 3, "pending": []}' "$(echo "$OUT" | sed -n 2p)"

echo "── wave clamp ──"

it "a cap of 2 with five ready steps dispatches two and leaves three pending"
OUT="$(run_py <<'EOF'
new_run("cap2", 5)
cr.request_change(REPO, "cap2", "step", fan_out_cap=2)
log = []
ready = dispatcher.ready_steps(REPO, "cap2")
dispatcher.dispatch_batch(REPO, "cap2", ready, len(ready), launch_fn=launcher(log))
print(json.dumps({"ready": len(ready), "launched": log, "states": states("cap2")}, sort_keys=True))
EOF
)"
has '"ready": 5' "$OUT"
has '"launched": ["U1", "U2"]' "$OUT"
has '"U3": "pending"' "$OUT"

it "an agent-chosen wave size of 4 is clamped to the cap of 2"
OUT="$(run_py <<'EOF'
new_run("agent4", 5)
cr.request_change(REPO, "agent4", "step", fan_out_cap=2)
log = []
res = dispatcher.dispatch_batch(REPO, "agent4", ["U1", "U2", "U3", "U4", "U5"], 4, launch_fn=launcher(log))
print(json.dumps({"launched": log, "over": [r for r in res if r[1] == "rejected:over-cap"]}, sort_keys=True))
EOF
)"
has '"launched": ["U1", "U2"]' "$OUT"
has '"U3", "rejected:over-cap"' "$OUT"

it "an agent-chosen wave size below the cap still wins"
OUT="$(run_py <<'EOF'
new_run("below", 4)
log = []
dispatcher.dispatch_batch(REPO, "below", ["U1", "U2", "U3", "U4"], 1, launch_fn=launcher(log))
print(json.dumps(log))
EOF
)"
check '["U1"]' "$OUT"

it "lowering the cap to 1 leaves two in-flight steps running; only the next wave is clamped"
OUT="$(run_py <<'EOF'
new_run("lower", 5)
dispatcher.dispatch_batch(REPO, "lower", ["U1", "U2"], 2, launch_fn=launcher([]))
cr.request_change(REPO, "lower", "step", fan_out_cap=1)
log = []
dispatcher.dispatch_batch(REPO, "lower", ["U3", "U4", "U5"], 16, launch_fn=launcher(log))
st = states("lower")
print(json.dumps({"launched": log, "inflight": [st["U1"], st["U2"]], "attempts": [s["attempt"] for s in rec("lower")["steps"][:2]],
                  "new": st["U3"], "left": [st["U4"], st["U5"]]}, sort_keys=True))
EOF
)"
check '{"attempts": [1, 1], "inflight": ["dispatched", "dispatched"], "launched": ["U3"], "left": ["pending", "pending"], "new": "dispatched"}' "$OUT"

echo "── no contract ──"

it "a record with no contract dispatches exactly as before and gains no contract key"
OUT="$(run_py <<'EOF'
new_run("plain", 5, contract=False)
log = []
res = dispatcher.dispatch_batch(REPO, "plain", ["U1", "U2", "U3", "U4", "U5"], 4, launch_fn=launcher(log))
pulse.dispatch_pulse(REPO, "plain")
r = rec("plain")
print(json.dumps({"launched": log, "has_contract": "contract" in r, "last": res[-1]}, sort_keys=True))
EOF
)"
check '{"has_contract": false, "last": ["U5", "rejected:over-cap"], "launched": ["U1", "U2", "U3", "U4"]}' "$OUT"

it "a contract with nothing to apply is not rewritten by a pulse-start or wave read"
OUT="$(run_py <<'EOF'
new_run("quiet", 2)
path = core.run_record_path(REPO, "quiet")
before = os.stat(path).st_mtime_ns
apply_mod.apply_at_pulse(REPO, "quiet")
dispatcher.dispatch_batch(REPO, "quiet", ["U1"], 0, launch_fn=launcher([]))
print(os.stat(path).st_mtime_ns == before)
EOF
)"
check "True" "$OUT"

it "a no-contract pulse intent carries no contract text and the dispatch prompt is unchanged"
OUT="$(run_py <<'EOF'
new_run("plain2", 2, contract=False)
r = pulse.dispatch_pulse(REPO, "plain2")
same = dp.build_dispatch_prompt("plain2", "U1", 1, goal="g") == dp.build_dispatch_prompt("plain2", "U1", 1, goal="g", repo_root=REPO)
print(json.dumps({"guided": "PM CONTRACT" in (r.get("operator_guidance") or ""), "same_prompt": same}, sort_keys=True))
EOF
)"
check '{"guided": false, "same_prompt": true}' "$OUT"

echo "── dispatch prompt ──"

it "build_dispatch_prompt applies step bites and carries the contract and done bar"
OUT="$(run_py <<'EOF'
new_run("prompt", 2)
cr.request_change(REPO, "prompt", "step", fan_out_cap=1)
text = dp.build_dispatch_prompt("prompt", "U1", 1, goal="g", repo_root=REPO)
c = rec("prompt")["contract"]
print(json.dumps({"applied": c["applied_version"], "pending": c["pending_versions"], "has_block": "PM CONTRACT v2 (applied v2)" in text,
                  "cap": "fan-out cap 1 subagents per wave" in text, "bar": "Done bar: internal steps_terminal" in text}, sort_keys=True))
EOF
)"
check '{"applied": 2, "bar": true, "cap": true, "has_block": true, "pending": []}' "$OUT"

it "the guidance prefers a supplied effective authority map over the stored modes"
OUT="$(run_py <<'EOF'
new_run("eff", 1)
text = apply_mod.append_guidance("base", rec("eff"), {"product_scope": {"mode": "never", "asks": "shawn"}})
print(text)
EOF
)"
has "Effective authority: product_scope=never (asks shawn)." "$OUT"
has "base" "$OUT"

echo "── no session id ──"

it "a step-boundary read with no session id applies the entry"
OUT="$(env -u CLAUDE_CODE_SESSION_ID "$PY" - "$AUTO_ROOT" "$REPO" <<'EOF' 2>&1
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
sys.path.insert(0, os.path.join(sys.argv[1], "tests", "helpers"))
from _bootstrap import load_lib_module
import contract_records as cr
core = load_lib_module("run_record_core")
dispatcher = load_lib_module("dispatcher")
repo = sys.argv[2]
core.init_run_record(repo, "nosid", backend="ce", steps=[{"id": "U1"}, {"id": "U2"}], loop_phase="work")
cr.add_contract(repo, "nosid", applied=1)
cr.request_change(repo, "nosid", "step", fan_out_cap=1)
log = []
dispatcher.dispatch_batch(repo, "nosid", ["U1", "U2"], 5, launch_fn=lambda u, a: log.append(u))
print(json.dumps({"launched": log, "applied": core.read_run_record(repo, "nosid")["contract"]["applied_version"]}, sort_keys=True))
EOF
)"
check '{"applied": 2, "launched": ["U1"]}' "$OUT"

stop_verdict() {
  local sid="$1" payload
  if [ -n "$sid" ]; then payload="{\"session_id\": \"${sid}\"}"; else payload="{}"; fi
  local out
  out="$( cd "$REPO" && "$PY" "$ON_STOP" "$REPO" <<< "$payload" 2>/dev/null )" || true
  if printf '%s' "$out" | grep -q '"decision":[[:space:]]*"block"'; then echo block; elif [ -z "$(printf '%s' "$out" | tr -d '[:space:]')" ]; then echo allow; else echo "other:$out"; fi
}

SR="${WORK}/stoprepo"
mkdir -p "${SR}/.claude/auto"
"$PY" - "$AUTO_ROOT" "$SR" <<'EOF'
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
sys.path.insert(0, os.path.join(sys.argv[1], "tests", "helpers"))
from _bootstrap import load_lib_module
import contract_records as cr
core = load_lib_module("run_record_core")
repo = sys.argv[2]
core.init_run_record(repo, "held", backend="ce", steps=[{"id": "U1"}], loop_phase="work", driving_session_id="sess-A")
cr.add_contract(repo, "held", applied=1)
load_lib_module("run_record").set_loop(repo, "held", driver="self", beat=True)
EOF
REPO="$SR"

it "a stop from the driving session is held on a contracted run"
check "block" "$(stop_verdict sess-A)"

it "a stop with no session id is still held on a contracted run"
check "block" "$(stop_verdict "")"

it "a stop from another session is allowed, so the hold is the session scope and not a blanket block"
check "allow" "$(stop_verdict sess-Z)"

echo "── size ──"

it "dispatch_batch gains exactly one line of contract code and the size-budget lint passes"
check "1" "$(grep -c 'worker_contract_apply' "${AUTO_ROOT}/lib/dispatcher.py")"
SB="$(bash "${AUTO_ROOT}/tests/unit/size-budget.test.sh" 2>&1)"
has "dispatcher.py:dispatch_batch:140" "$(grep 'dispatcher.py:dispatch_batch' "${AUTO_ROOT}/tests/unit/size-budget.test.sh")"
case "$SB" in *"dispatch_batch"*) fail "size-budget names dispatch_batch: $(printf '%s' "$SB" | grep 'dispatch_batch' | head -2)" ;; *) pass ;; esac
case "$SB" in *"lib/dispatcher.py"*|*"lib/pulse.py"*|*"lib/pulse_guidance.py"*|*"lib/dispatch_prompt.py"*|*"lib/worker_contract_apply.py"*) fail "size-budget names a file this unit changed" ;; *) pass ;; esac

echo ""
echo "worker-contract-pulse.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
