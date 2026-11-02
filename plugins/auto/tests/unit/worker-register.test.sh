#!/usr/bin/env bash
# auto unit test: the start path and run registration for a contracted worker (start-worker --contract,
# register-run, the launch modes and the item states launched / bound / launch-blocked).
#
# Every refusal assertion pins the refusal CODE or a phrase of the message and checks that the stored
# state did not move: a missing verb also exits non-zero, so a bare exit code proves nothing.
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

echo "worker-register.test.sh"

WORK="$(mktemp -d -t auto-worker-register.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_MACHINE="studio"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_CODE_SESSION_ID="sess-pm"
export CLAUDE_AUTO_WORKER_WAIT="1"
export CLAUDE_AUTO_REGISTER_WINDOW="0"
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
sid=""; kick=""
while [ $# -gt 0 ]; do
  [ "$1" = "--session-id" ] && sid="$2"
  [ "$1" = "--kickoff-file" ] && kick="$2"
  shift
done
[ -n "$kick" ] && cp "$kick" "${CALLS}.kickoff.$(date +%s%N)"
echo "  herdr agent pane: w2:p40 (launched with the brief)"
if [ -z "${FAKE_SPINOFF_NO_AGENT:-}" ]; then
  "$PY" - "$SNAP" "$sid" <<'PYEOF'
import json, sys
path, sid = sys.argv[1], sys.argv[2]
doc = json.load(open(path))
snap = doc["result"]["snapshot"]
pane = {"pane_id": "w2:p40", "tab_id": "w2:t3", "workspace_id": "w2", "terminal_id": "term_p40",
        "agent": "claude", "agent_status": "idle", "cwd": "/tmp", "label": "worker",
        "terminal_title_stripped": "worker",
        "agent_session": {"source": "auto", "agent": "claude", "kind": "id", "value": sid}}
snap["panes"] = [p for p in snap["panes"] if p["pane_id"] != "w2:p40"] + [pane]
snap["agents"] = [p for p in snap["agents"] if p["pane_id"] != "w2:p40"] + [pane]
json.dump(doc, open(path, "w"))
PYEOF
fi
exit "${FAKE_SPINOFF_EXIT:-0}"
EOF
chmod +x "${FAKES}"/*
export PATH="${FAKES}:${PATH}"

cat > "$SNAP" <<'EOF'
{"id": "1", "result": {"type": "snapshot", "snapshot": {
  "workspaces": [{"workspace_id": "w2", "label": "Ai Editor"}],
  "tabs": [{"tab_id": "w2:t1", "workspace_id": "w2", "label": "Work"}],
  "panes": [], "agents": []}}}
EOF

REPO_A="${WORK}/repo-a"
REPO_OUT="${WORK}/repo-out"
mkdir -p "${REPO_A}/.claude/auto" "${REPO_OUT}/.claude/auto"
HANDOFF="${WORK}/handoff.md"
printf '# handoff\nbuild the thing\n' > "$HANDOFF"
CONTRACT="${WORK}/contract.json"
cat > "$CONTRACT" <<'EOF'
{"authority": {"technical_approach": {"mode": "act", "asks": "pm"}, "product_scope": {"mode": "never", "asks": "shawn"}},
 "done_bar": {"internal": ["steps_terminal"], "external": ["pr_merged"]},
 "workflow": "a2", "fan_out_cap": 3}
EOF

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import copy, json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
sys.path.insert(0, os.path.join(sys.argv[1], "tests", "helpers"))
from _bootstrap import load_lib_module
ph = load_lib_module("programme_home")
pj = load_lib_module("programme_journal")
core = load_lib_module("run_record_core")
wc = load_lib_module("worker_contract")
args = sys.argv[2:]
def record(run):
    return core.read_run_record(ph.home_path(run), run)
$(cat)
PYEOF
}

RUN="$(run_py <<'EOF'
print(ph.create_programme(["w2"], "sess-pm")["run"])
EOF
)"

field() {
  run_py "$RUN" "$1" <<'EOF'
run, expr = args
prog = record(run)["programme"]
items = prog["items"]
print(json.dumps(eval(expr), sort_keys=True))
EOF
}

edit() {
  run_py "$RUN" "$1" "$2" <<'EOF'
from programme_records import edit
run, expr, extra = args
edit(run, expr, {"X": extra, "REPO_A": os.environ["REPO_A"], "REPO_OUT": os.environ["REPO_OUT"]})
EOF
}
export REPO_A REPO_OUT

journal_last() {
  run_py "$RUN" "$1" <<'EOF'
rows = [r for r in pj.read(args[0]) if r["kind"] == args[1]]
print(json.dumps(rows[-1] if rows else None, sort_keys=True))
EOF
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
calls() { cat "$CALLS" 2>/dev/null; }
jq_py() {
  "$PY" -c "import json,sys; d=json.loads(sys.stdin.read()); print(json.dumps($1, sort_keys=True))" <<< "$OUT" 2>&1
}
last_start_sid() { grep '^spinoff ' "$CALLS" | tail -1 | sed -E 's/.*--session-id ([^ ]+).*/\1/'; }

edit 'prog["remit"]["repos"] = [{"path": REPO_A}]' ""
prog add-item linear:AI-700 --title "Plain item"
prog add-item linear:AI-701 --title "Contract item"
prog add-item linear:AI-702 --title "Blocked item"
prog add-item linear:AI-703 --title "Other item"
prog add-item linear:AI-704 --title "Second mode fails"
prog add-item linear:AI-705 --title "Hand started"
prog add-item linear:AI-706 --title "Bad contract"

mkrun() {
  run_py "$1" "$2" "$3" "${4:-}" <<'EOF'
repo, run, sid, nostamp = args
core.init_run_record(repo, run, backend="native", driving_session_id=sid)
if nostamp:
    core._with_locked_run_record(repo, run, lambda rec: rec.pop("contract_capable", None))
EOF
}

governed() {
  run_py "$RUN" <<'EOF'
import hashlib
run = args[0]
rows = [r for r in pj.read(run)]
print(hashlib.sha256(json.dumps([record(run), rows], sort_keys=True, default=str).encode()).hexdigest())
EOF
}

run_field() {
  run_py "$1" "$2" "$3" <<'EOF'
repo, run, expr = args
rec = core.read_run_record(repo, run)
print(json.dumps(eval(expr), sort_keys=True))
EOF
}

refuses() {
  local code="$1" phrase="$2" before="$3"
  it "refused ($code): exit 1, names the cause, no traceback"
  if [ "$CODE" = 1 ]; then case "$OUT" in *"refused ($code)"*"$phrase"*) pass ;; *) fail "expected [refused ($code)] naming [$phrase], got [$OUT]" ;; esac; else fail "exit $CODE: $OUT"; fi
  it "refused ($code): nothing in the programme record or journal changed"
  check "$before" "$(governed)"
}

echo "── contract-less start-worker is unchanged (golden) ──"

: > "$CALLS"
prog start-worker linear:AI-700 -- --name plain --handoff "$HANDOFF" --target tab
it "a start with no contract exits 0"
check 0 "$CODE"
PLAIN_SID="$(last_start_sid)"
it "spinoff gets exactly the caller's arguments plus the minted session id, and no kickoff override"
check "spinoff --name plain --handoff ${HANDOFF} --target tab --session-id ${PLAIN_SID}" "$(grep '^spinoff ' "$CALLS")"
it "the emitted receipt carries exactly the pre-existing keys"
check '["attempt", "behaviour_ids", "behaviours_held_back", "decision_ids", "item", "kind", "late", "ok", "operation_state", "outcome", "output_tail", "pane", "reason", "restrictions", "run", "session_id", "spinoff_exit", "started", "terminal_id"]' "$(jq_py 'sorted(d.keys())')"
it "the starts entry carries exactly the pre-existing keys, with no launch mode"
check '["at", "attempt", "ok", "pane", "reason", "session_id", "spinoff_exit", "terminal_id"]' "$(field 'sorted(items["linear:AI-700"]["starts"][-1].keys())')"
it "the item gains no auto_run block"
check 'false' "$(field '"auto_run" in items["linear:AI-700"]')"
it "the owner is set as before"
check "[\"w2:p40\", \"term_p40\", \"${PLAIN_SID}\"]" "$(field '[items["linear:AI-700"]["owner"][k] for k in ("pane", "terminal_id", "session_id")]')"
it "no crash so far"
check "" "$CRASHES"

spin_count() { grep -c '^spinoff ' "$CALLS"; }
auto_run() { field "(lambda a: $1)(items[\"$2\"][\"auto_run\"])"; }

echo "── start-worker with a contract: the item is launched ──"

: > "$CALLS"
prog start-worker linear:AI-701 --contract "$CONTRACT" --plan docs/plans/x.md -- --name contract --handoff "$HANDOFF" --target tab
it "a contracted start exits 0"
check 0 "$CODE"
C_SID="$(last_start_sid)"
SPIN="$(grep '^spinoff ' "$CALLS" | tail -1)"
KICK="$(printf '%s' "$SPIN" | sed -E 's/.*--kickoff-file ([^ ]+).*/\1/')"
BRIEF="$(printf '%s' "$SPIN" | sed -E 's/.*--handoff ([^ ]+).*/\1/')"
it "the first launch mode kicks off with exactly /auto <plan>"
check "/auto docs/plans/x.md" "$(cat "$KICK")"
it "the receipt names launch mode 1"
check 1 "$(jq_py 'd["launch_mode"]')"
it "the item is launched with version 1 of the contract, mode 1, attempt count 1 and the minted session"
check "[\"launched\", 1, 1, \"${C_SID}\", 1]" "$(auto_run '[a["state"], a["attempts"], a["mode"], a["session_id"], a["contract"]["version"]]' linear:AI-701)"
it "the seed carries the PM as setter, the chosen authority kinds, the done bar and the cap"
check '["sess-pm", ["product_scope", "technical_approach"], ["pr_merged"], "a2", 3]' "$(auto_run '[a["contract"]["set_by"], sorted(a["contract"]["authority"]), a["contract"]["done_bar"]["external"], a["contract"]["workflow"], a["contract"]["fan_out_cap"]]' linear:AI-701)"
it "the starts entry records the launch mode"
check 1 "$(field 'items["linear:AI-701"]["starts"][-1]["mode"]')"
it "the owner is the minted session"
check "\"${C_SID}\"" "$(field 'items["linear:AI-701"]["owner"]["session_id"]')"
it "the brief copy tells the worker how to register"
has "register-run --run ${RUN} --item linear:AI-701" "$(cat "$BRIEF")"
for word in authority never propose product_scope technical_approach done_bar act_and_tell; do
  it "no authority wording in the kickoff or the brief: $word"
  case "$(cat "$KICK" "$BRIEF")" in *"$word"*) fail "found [$word]" ;; *) pass ;; esac
done
it "a contracted start from a session that does not drive the programme is refused and writes nothing"
BEFORE="$(governed)"
as sess-other start-worker linear:AI-706 --contract "$CONTRACT" --plan docs/plans/z.md -- --name nope --handoff "$HANDOFF" --target tab
check "1 false" "$CODE $(field '"auto_run" in items["linear:AI-706"]')"
it "that refusal never reached spinoff"
check 1 "$(spin_count)"

echo "── a bad contract file launches nothing ──"

printf '{"authority": {}, "done_bar": {"internal": ["steps_terminal"], "external": []}, "workflow": "a2"}\n' > "${WORK}/bad-keys.json"
printf '{"authority": {"made_up_kind": {"mode": "act", "asks": "pm"}}, "done_bar": {"internal": ["steps_terminal"], "external": []}, "workflow": "a2", "fan_out_cap": 2}\n' > "${WORK}/bad-kind.json"
BEFORE="$(governed)"
prog start-worker linear:AI-706 --contract "${WORK}/bad-keys.json" --plan p.md -- --name bad --handoff "$HANDOFF" --target tab
refuses bad_contract_file "needs exactly the keys" "$BEFORE"
prog start-worker linear:AI-706 --contract "${WORK}/bad-kind.json" --plan p.md -- --name bad --handoff "$HANDOFF" --target tab
refuses unknown_kind "made_up_kind" "$BEFORE"
prog start-worker linear:AI-706 --contract "$CONTRACT" -- --name bad --handoff "$HANDOFF" --target tab
it "a contract with no plan is a usage error"
check "2" "$CODE"
prog start-worker linear:AI-706 --plan p.md -- --name bad --handoff "$HANDOFF" --target tab
it "a plan with no contract is a usage error"
check "2" "$CODE"
it "none of those reached spinoff"
check 1 "$(spin_count)"

echo "── register-run refusals ──"

mkrun "$REPO_A" run-w1 "$C_SID"
mkrun "$REPO_A" run-bad sess-x
mkrun "$REPO_A" run-old "$C_SID" nostamp
mkrun "$REPO_OUT" run-out "$C_SID"
REG=(register-run --run "$RUN" --item linear:AI-701)

BEFORE="$(governed)"
as sess-other "${REG[@]}" --auto-run run-w1 --repo "$REPO_A"
refuses not_owner "is not the item's owner session" "$BEFORE"
OUT="$(env -u CLAUDE_CODE_SESSION_ID "$PY" "$PROG" "${REG[@]}" --auto-run run-w1 --repo "$REPO_A" 2>&1)"; CODE=$?
refuses no_session "CLAUDE_CODE_SESSION_ID is unset" "$BEFORE"
as "$C_SID" "${REG[@]}" --auto-run run-bad --repo "$REPO_A"
refuses session_mismatch "run record session sess-x is not the item's owner session ${C_SID}" "$BEFORE"
as "$C_SID" "${REG[@]}" --auto-run run-out --repo "$REPO_OUT"
refuses outside_remit "is outside the programme's remit repos" "$BEFORE"
as "$C_SID" "${REG[@]}" --auto-run run-missing --repo "$REPO_A"
refuses no_record "no run record 'run-missing'" "$BEFORE"
as "$C_SID" "${REG[@]}" --auto-run run-old --repo "$REPO_A"
refuses predates_contracts "run predates contracts" "$BEFORE"
edit 'items["linear:AI-703"]["auto_run"] = {"state": "bound", "run_id": "run-w1", "path": REPO_A, "contract": None}' ""
BEFORE="$(governed)"
as "$C_SID" "${REG[@]}" --auto-run run-w1 --repo "$REPO_A"
refuses bound_elsewhere "run run-w1 is already bound to item linear:AI-703" "$BEFORE"
edit 'items["linear:AI-703"].pop("auto_run")' ""
it "every refusal left the item launched"
check '"launched"' "$(auto_run 'a["state"]' linear:AI-701)"
it "every refusal left the worker's run record without a contract"
check 'false' "$(run_field "$REPO_A" run-w1 '"contract" in rec')"
it "none of the refusals crashed"
check "" "$CRASHES"

echo "── register-run by the owner binds the item ──"

as "$C_SID" "${REG[@]}" --auto-run run-w1 --repo "$REPO_A"
it "the owner's registration exits 0"
check 0 "$CODE"
it "the item is bound to the run and the repo path that holds its record"
check "[\"bound\", \"run-w1\", true]" "$(field '(lambda a: [a["state"], a["run_id"], a["path"] == os.path.realpath(os.environ["REPO_A"])])(items["linear:AI-701"]["auto_run"])')"
it "the run record holds version 1 of the contract with nothing applied yet, and keeps its stamp"
check '[1, 0, "a2", true]' "$(run_field "$REPO_A" run-w1 '[rec["contract"]["version"], rec["contract"]["applied_version"], rec["contract"]["workflow"], rec["contract_capable"]]')"
it "the copy is the seed, key for key"
check "$(auto_run 'a["contract"]' linear:AI-701)" "$(run_field "$REPO_A" run-w1 'rec["contract"]')"
it "the worker's first pulse reads a contract it has not applied"
check '{"applied_version": 0, "authority_kinds": ["product_scope", "technical_approach"], "stale": true, "state": "contract", "version": 1}' "$(run_field "$REPO_A" run-w1 'load_lib_module("worker_contract").reading(rec)' 2>&1 | head -1)"
it "the registration is recorded in the item history"
check 'true' "$(field 'any(h.get("kind") == "run_bound" for h in items["linear:AI-701"]["history"])')"
it "the receipt says the contract was copied"
check 'true' "$(jq_py 'd["contract_copied"]')"

BEFORE="$(governed)"
as "$C_SID" "${REG[@]}" --auto-run run-w1 --repo "$REPO_A"
refuses already_bound "already has a bound run (run-w1); one item is one run" "$BEFORE"
mkrun "$REPO_A" run-w1b "$C_SID"
BEFORE="$(governed)"
as "$C_SID" "${REG[@]}" --auto-run run-w1b --repo "$REPO_A"
refuses already_bound "one item is one run" "$BEFORE"

echo "── a crash between the run-record copy and the bind ──"

prog start-worker linear:AI-703 --contract "$CONTRACT" --plan docs/plans/c.md -- --name crash --handoff "$HANDOFF" --target tab
SID3="$(last_start_sid)"
mkrun "$REPO_A" run-w3 "$SID3"
it "the crash item starts launched"
check '"launched"' "$(auto_run 'a["state"]' linear:AI-703)"
run_py "$RUN" "$SID3" <<'EOF'
os.environ["CLAUDE_CODE_SESSION_ID"] = args[1]
prog = load_lib_module("programme")
wr = load_lib_module("worker_register")
def boom(*a, **k):
    raise OSError("simulated crash after the copy")
wr._bind = boom
try:
    prog._cli(["register-run", "--run", args[0], "--item", "linear:AI-703", "--auto-run", "run-w3", "--repo", os.environ["REPO_A"]])
except BaseException as exc:
    print("crashed", type(exc).__name__)
EOF
it "the copy landed in the run record"
check '1' "$(run_field "$REPO_A" run-w3 'rec["contract"]["version"]')"
it "the item is still launched, not bound"
check '["launched", null]' "$(auto_run '[a["state"], a["run_id"]]' linear:AI-703)"
COPY_BEFORE="$(run_field "$REPO_A" run-w3 'rec["contract"]')"
as "$SID3" register-run --run "$RUN" --item linear:AI-703 --auto-run run-w3 --repo "$REPO_A"
it "running register-run again completes the bind"
check '[0, "bound", "run-w3"]' "[$CODE, $(auto_run '[a["state"], a["run_id"]]' linear:AI-703 | sed -E 's/^\[|\]$//g')]"
it "the second run copied nothing, so there is no duplicate"
check 'false' "$(jq_py 'd["contract_copied"]')"
it "the contract in the run record is unchanged"
check "$COPY_BEFORE" "$(run_field "$REPO_A" run-w3 'rec["contract"]')"

echo "── a hand-started run binds with no contract ──"

edit 'items["linear:AI-705"]["owner"]["session_id"] = "sess-hand"' ""
mkrun "$REPO_A" run-hand sess-hand
as sess-hand register-run --run "$RUN" --item linear:AI-705 --auto-run run-hand --repo "$REPO_A"
it "the owner of a hand-driven item can bind its run"
check 0 "$CODE"
it "the item is bound and holds no contract; the run record gets none"
check '["bound", null, false]' "[$(auto_run '[a["state"], a["contract"]]' linear:AI-705 | sed -E 's/^\[|\]$//g'), $(run_field "$REPO_A" run-hand '"contract" in rec')]"
it "the receipt says nothing was copied"
check 'false' "$(jq_py 'd["contract_copied"]')"

echo "── launch modes and launch-blocked ──"

: > "$CALLS"
CLAUDE_AUTO_REGISTER_WINDOW=3600 prog start-worker linear:AI-702 --contract "$CONTRACT" --plan docs/plans/y.md -- --name modes --handoff "$HANDOFF" --target tab
it "mode 1 launches"
check "0 1" "$CODE $(spin_count)"
S1="$(last_start_sid)"
BEFORE="$(governed)"
CLAUDE_AUTO_REGISTER_WINDOW=3600 prog start-worker linear:AI-702 --contract "$CONTRACT" --plan docs/plans/y.md -- --name modes --handoff "$HANDOFF" --target tab
refuses within_window "registration window" "$BEFORE"
it "a second launch inside the window never reached spinoff"
check 1 "$(spin_count)"
prog start-worker linear:AI-702 --contract "$CONTRACT" --plan docs/plans/y.md -- --name modes --handoff "$HANDOFF" --target tab
it "after the window the PM restarts once, in mode 2"
check "0 2" "$CODE $(spin_count)"
S2="$(last_start_sid)"
KICK2="$(grep '^spinoff ' "$CALLS" | tail -1 | sed -E 's/.*--kickoff-file ([^ ]+).*/\1/')"
it "the fallback kickoff tells the worker to run /auto as its first action, and how to register"
has "Your first action is to run /auto docs/plans/y.md" "$(cat "$KICK2")"
has "register-run --run ${RUN} --item linear:AI-702" "$(cat "$KICK2")"
it "the fallback kickoff does not tell the worker to wait for direction"
lacks "wait for my direction" "$(cat "$KICK2")"
it "the starts entries record modes 1 then 2, and the count is 2 on the new session"
check "[[1, 2], 2, \"${S2}\"]" "$(field '(lambda i: [[s.get("mode") for s in i["starts"]], i["auto_run"]["attempts"], i["auto_run"]["session_id"]])(items["linear:AI-702"])')"
it "the seed contract survives the relaunch unchanged"
check 1 "$(auto_run 'a["contract"]["version"]' linear:AI-702)"

mkrun "$REPO_A" run-s1 "$S1"
BEFORE="$(governed)"
as "$S1" register-run --run "$RUN" --item linear:AI-702 --auto-run run-s1 --repo "$REPO_A"
refuses not_owner "is not the item's owner session ${S2}" "$BEFORE"

prog start-worker linear:AI-702 --contract "$CONTRACT" --plan docs/plans/y.md -- --name modes --handoff "$HANDOFF" --target tab
it "a third start is refused, naming both failed modes and Shawn"
has "refused (launch_blocked): both launch modes failed for item 'linear:AI-702'; the choice returns to Shawn" "$OUT"
it "after two modes a restarted PM does not launch a third time"
check "1 2" "$CODE $(spin_count)"
it "the item reads launch-blocked, persisted"
check '"launch-blocked"' "$(auto_run 'a["state"]' linear:AI-702)"
BEFORE="$(governed)"
prog start-worker linear:AI-702 --contract "$CONTRACT" --plan docs/plans/y.md -- --name modes --handoff "$HANDOFF" --target tab
refuses launch_blocked "both launch modes failed" "$BEFORE"
mkrun "$REPO_A" run-s2 "$S2"
as "$S2" register-run --run "$RUN" --item linear:AI-702 --auto-run run-s2 --repo "$REPO_A"
it "a launch-blocked item refuses registration"
has "refused (launch_blocked)" "$OUT"

echo "── a failed second mode blocks at once ──"

prog start-worker linear:AI-704 --contract "$CONTRACT" --plan docs/plans/f.md -- --name fail --handoff "$HANDOFF" --target tab
it "mode 1 launches"
check 0 "$CODE"
FAKE_SPINOFF_EXIT=1 prog start-worker linear:AI-704 --contract "$CONTRACT" --plan docs/plans/f.md -- --name fail --handoff "$HANDOFF" --target tab
it "mode 2 fails"
check 1 "$CODE"
it "the failed second mode left the item launch-blocked with a failed mode-2 start"
check '["launch-blocked", 2, false]' "$(field '(lambda i: [i["auto_run"]["state"], i["starts"][-1]["mode"], i["starts"][-1]["ok"]])(items["linear:AI-704"])')"
BEFORE="$(governed)"
COUNT="$(spin_count)"
prog start-worker linear:AI-704 --contract "$CONTRACT" --plan docs/plans/f.md -- --name fail --handoff "$HANDOFF" --target tab
refuses launch_blocked "choice returns to Shawn" "$BEFORE"
it "the blocked item never reached spinoff again"
check "$COUNT" "$(spin_count)"

it "no register-run or start-worker refusal crashed"
check "" "$CRASHES"

echo "worker-register.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
