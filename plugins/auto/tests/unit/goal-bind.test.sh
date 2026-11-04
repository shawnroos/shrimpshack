#!/usr/bin/env bash
# auto unit test: the goal binding path (R16, R5, R10; KTD10) — the pulse's bind and rebind instructions, the
# worker's goal-bound report, and the Stop hook holding on the exit predicate whatever the goal's state.
#
# Every assertion pins a value and the presence of the key it reads. The instruction tags are counted, not
# searched for, so "exactly one rebind" and "no bind" are different results.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
ON_STOP="${AUTO_ROOT}/lib/on-stop.py"
RUN_RECORD="${AUTO_ROOT}/lib/run_record.py"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
check() { if [ "$1" = "$2" ]; then pass; else fail "expected [$1] got [$2]"; fi; }
has() { case "$2" in *"$1"*) pass ;; *) fail "expected to find [$1] in [$2]" ;; esac; }

echo "goal-bind.test.sh"

WORK="$(mktemp -d -t auto-goal-bind.XXXXXX)"
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
pulse = load_lib_module("pulse")
gb = load_lib_module("goal_binding")
gd = load_lib_module("goal_doc")
REPO = sys.argv[2]
def rec(run):
    return core.read_run_record(REPO, run)
def new_run(run, goal_version=0, bound=0, doc=True, doc_contract=None, session="sess-W"):
    core.init_run_record(REPO, run, backend="ce", steps=[{"id": "U1"}, {"id": "U2"}], loop_phase="work",
                         driving_session_id=session)
    cr.add_contract(REPO, run, applied=1)
    if goal_version:
        def mutate(r):
            r["contract"]["goal_version"] = goal_version
            r["contract"]["goal_bound_version"] = bound
        core._with_locked_run_record(REPO, run, mutate)
    if doc and goal_version:
        path = gd.goal_path(REPO, run)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(gd.render(title="t", plan=None, done_bar={"internal": ["steps_terminal"], "external": []},
                               outcomes=[], out_of_scope=[], goal_version=goal_version,
                               contract_version=rec(run)["contract"]["version"] if doc_contract is None else doc_contract, run_id=run))
def guidance(run):
    return pulse.dispatch_pulse(REPO, run)["operator_guidance"]
def tags(text):
    return {"bind": text.count("GOAL BIND:"), "rebind": text.count("GOAL REBIND:")}
$(cat)
PYEOF
}

goal_bound() {
  local sid="$1" run="$2" version="$3"
  if [ -n "$sid" ]; then
    ( cd "$REPO" && CLAUDE_CODE_SESSION_ID="$sid" "$PY" "$RUN_RECORD" goal-bound "$run" "$version" 2>&1 )
  else
    ( cd "$REPO" && env -u CLAUDE_CODE_SESSION_ID "$PY" "$RUN_RECORD" goal-bound "$run" "$version" 2>&1 )
  fi
}

bound_of() {
  run_py <<EOF
print(rec("$1")["contract"].get("goal_bound_version", "absent"))
EOF
}

echo "── first pulse ──"

it "a contract with a goal doc gets exactly one bind instruction naming the doc path and the report command"
OUT="$(run_py <<'EOF'
new_run("withdoc", goal_version=1)
text = guidance("withdoc")
print(json.dumps({"tags": tags(text), "path": f"/goal {gd.goal_path(REPO, 'withdoc')}" in text,
                  "report": "run_record.sh\" goal-bound withdoc 1" in text, "rule": "exit predicate still decides done" in text},
                 sort_keys=True))
EOF
)"
check '{"path": true, "report": true, "rule": true, "tags": {"bind": 1, "rebind": 0}}' "$OUT"

it "a contract with no goal doc gets no bind or rebind instruction"
OUT="$(run_py <<'EOF'
new_run("nodoc")
text = guidance("nodoc")
print(json.dumps({"tags": tags(text), "has_contract_text": "PM CONTRACT" in text}, sort_keys=True))
EOF
)"
check '{"has_contract_text": true, "tags": {"bind": 0, "rebind": 0}}' "$OUT"

it "a goal version with no doc file on disk gets no instruction"
OUT="$(run_py <<'EOF'
new_run("nofile", goal_version=1, doc=False)
print(json.dumps(tags(guidance("nofile")), sort_keys=True))
EOF
)"
check '{"bind": 0, "rebind": 0}' "$OUT"

it "a doc file the contract never versioned (goal version 0) gets no instruction"
OUT="$(run_py <<'EOF'
new_run("stray")
path = gd.goal_path(REPO, "stray")
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w", encoding="utf-8") as fh:
    fh.write(gd.render(title="t", plan=None, done_bar={"internal": ["steps_terminal"], "external": []},
                       outcomes=[], out_of_scope=[], goal_version=1, contract_version=1, run_id="stray"))
print(json.dumps({"file": os.path.exists(path), "state": gd.reading(REPO, "stray")["state"], "tags": tags(guidance("stray"))}, sort_keys=True))
EOF
)"
check '{"file": true, "state": "current", "tags": {"bind": 0, "rebind": 0}}' "$OUT"

it "a run with no contract gets no instruction and the same guidance as before"
OUT="$(run_py <<'EOF'
core.init_run_record(REPO, "plain", backend="ce", steps=[{"id": "U1"}], loop_phase="work")
text = guidance("plain")
print(json.dumps({"tags": tags(text), "has_contract_key": "contract" in rec("plain"), "goal_word": "/goal" in text}, sort_keys=True))
EOF
)"
check '{"goal_word": false, "has_contract_key": false, "tags": {"bind": 0, "rebind": 0}}' "$OUT"

it "once the worker reports the version bound, the next pulse carries no instruction"
OUT="$(run_py <<'EOF'
new_run("bound1", goal_version=1, bound=1)
print(json.dumps(tags(guidance("bound1")), sort_keys=True))
EOF
)"
check '{"bind": 0, "rebind": 0}' "$OUT"

echo "── amendment ──"

it "rebind mode: an amendment adds exactly one rebind instruction naming both versions, and no bind"
OUT="$(run_py <<'EOF'
new_run("amend", goal_version=2, bound=1)
text = guidance("amend")
print(json.dumps({"mode": gb.REREAD_MODE, "tags": tags(text), "versions": "v2, you bound v1" in text,
                  "path": f"re-run `/goal {gd.goal_path(REPO, 'amend')}`" in text,
                  "report": "goal-bound amend 2" in text, "boundary": "At the next step boundary" in text}, sort_keys=True))
EOF
)"
check '{"boundary": true, "mode": "rebind", "path": true, "report": true, "tags": {"bind": 0, "rebind": 1}, "versions": true}' "$OUT"

it "bind-once mode: an amendment adds no rebind instruction, through the pulse"
OUT="$(run_py <<'EOF'
gb.REREAD_MODE = gb.MODE_BIND_ONCE
new_run("amend1", goal_version=2, bound=1)
print(json.dumps(tags(guidance("amend1")), sort_keys=True))
EOF
)"
check '{"bind": 0, "rebind": 0}' "$OUT"

it "bind-once mode still asks for the first bind"
OUT="$(run_py <<'EOF'
gb.REREAD_MODE = gb.MODE_BIND_ONCE
new_run("first1", goal_version=1)
print(json.dumps(tags(guidance("first1")), sort_keys=True))
EOF
)"
check '{"bind": 1, "rebind": 0}' "$OUT"

it "the mode constants hold the probe outcome: rebind is the default and the two modes differ"
OUT="$(run_py <<'EOF'
print(json.dumps({"default": gb.REREAD_MODE, "rebind": gb.MODE_REBIND, "once": gb.MODE_BIND_ONCE}, sort_keys=True))
EOF
)"
check '{"default": "rebind", "once": "bind-once", "rebind": "rebind"}' "$OUT"

it "a goal-stale doc (older contract version) still gets the bind instruction"
OUT="$(run_py <<'EOF'
new_run("stalebind", goal_version=1)
cr.request_change(REPO, "stalebind", "step", fan_out_cap=1)
print(json.dumps({"state": gd.reading(REPO, "stalebind")["state"], "tags": tags(guidance("stalebind"))}, sort_keys=True))
EOF
)"
check '{"state": "goal-stale", "tags": {"bind": 1, "rebind": 0}}' "$OUT"

echo "── goal-bound ──"

it "the run's own session records the version it bound, and the next pulse drops the bind line"
run_py <<'EOF' >/dev/null
new_run("rep", goal_version=2)
EOF
OUT="$(goal_bound sess-W rep 1)"
has '"goal_bound_version": 1' "$OUT"
check "1" "$(bound_of rep)"

it "after the report the next pulse asks for the rebind, not the bind"
OUT="$(run_py <<'EOF'
print(json.dumps(tags(guidance("rep")), sort_keys=True))
EOF
)"
check '{"bind": 0, "rebind": 1}' "$OUT"

it "reporting the amended version clears the instruction"
goal_bound sess-W rep 2 >/dev/null
check "2" "$(bound_of rep)"
OUT="$(run_py <<'EOF'
print(json.dumps(tags(guidance("rep")), sort_keys=True))
EOF
)"
check '{"bind": 0, "rebind": 0}' "$OUT"

it "a lower version never moves the bound version down"
OUT="$(goal_bound sess-W rep 1)"
has '"goal_bound_version": 2' "$OUT"
check "2" "$(bound_of rep)"

it "another session is refused and the record is unchanged"
run_py <<'EOF' >/dev/null
new_run("other", goal_version=2, bound=1)
EOF
OUT="$(goal_bound sess-Z other 2)"
has "only the run's own session may report a goal bound" "$OUT"
check "1" "$(bound_of other)"

it "a call with no session id is refused and the record is unchanged"
OUT="$(goal_bound "" other 2)"
has "goal-bound needs CLAUDE_CODE_SESSION_ID" "$OUT"
check "1" "$(bound_of other)"

it "a version above the goal version is refused and the record is unchanged"
OUT="$(goal_bound sess-W other 3)"
has "is not between 1 and the contract's goal version 2" "$OUT"
check "1" "$(bound_of other)"

it "version 0 and a non-integer are refused"
OUT="$(goal_bound sess-W other 0)"
has "is not between 1 and the contract's goal version 2" "$OUT"
OUT="$(goal_bound sess-W other two)"
has "goal version must be an integer" "$OUT"

it "a run with no contract is refused"
run_py <<'EOF' >/dev/null
core.init_run_record(REPO, "bare", backend="ce", steps=[{"id": "U1"}], loop_phase="work", driving_session_id="sess-W")
EOF
OUT="$(goal_bound sess-W bare 1)"
has "has no contract, so there is no goal to bind" "$OUT"

it "goal-bound is a registered run-record verb that describe lists"
OUT="$("$PY" "$RUN_RECORD" describe 2>&1)"
has '"goal-bound"' "$OUT"

echo "── stop hook ──"

stop_verdict() {
  local sid="$1" payload out
  payload="{\"session_id\": \"${sid}\"}"
  out="$( cd "$REPO" && "$PY" "$ON_STOP" "$REPO" <<< "$payload" 2>/dev/null )" || true
  if printf '%s' "$out" | grep -q '"decision":[[:space:]]*"block"'; then echo block; elif [ -z "$(printf '%s' "$out" | tr -d '[:space:]')" ]; then echo allow; else echo "other:$out"; fi
}

SR="${WORK}/stoprepo"
mkdir -p "${SR}/.claude/auto"
REPO="$SR"
run_py <<'EOF' >/dev/null
for run, gv, bound, doc_contract in (("unbound", 1, 0, None), ("stale", 2, 1, 0), ("bound", 1, 1, None)):
    new_run(run, goal_version=gv, bound=bound, doc_contract=doc_contract, session="sess-" + run)
    load_lib_module("run_record").set_loop(REPO, run, driver="self", beat=True)
EOF

it "goal unbound: the driving session's stop is held on the exit predicate"
check "block" "$(stop_verdict sess-unbound)"

it "goal stale and out of date with the contract: the stop is held on the exit predicate"
OUT="$(run_py <<'EOF'
print(gd.reading(REPO, "stale")["state"])
EOF
)"
check "goal-stale" "$OUT"
check "block" "$(stop_verdict sess-stale)"

it "goal bound but steps still open: the stop is held, so a bound goal is not trusted for done"
check "block" "$(stop_verdict sess-bound)"

it "goal unbound but the exit predicate met: the stop is allowed, so the predicate and not the goal decides"
run_py <<'EOF' >/dev/null
new_run("met", goal_version=1, bound=0, session="sess-met")
load_lib_module("run_record").set_loop(REPO, "met", driver="self", beat=True)
rr = load_lib_module("run_record")
for step in ("U1", "U2"):
    rr.transition(REPO, "met", step, "dispatched")
    rr.record_verdict(REPO, "met", step, [])
EOF
check "allow" "$(stop_verdict sess-met)"

it "the hold is the session scope: another session's stop is allowed"
check "allow" "$(stop_verdict sess-elsewhere)"

echo ""
echo "goal-bind.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
