#!/usr/bin/env bash
# auto unit test: handover-contract carries an item's contract to a new run (R18).
#
# Every refusal assertion pins the refusal CODE and checks that the old run record bytes and the item's
# auto_run block did not move: a missing verb also exits non-zero, so a bare exit code proves nothing.
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

echo "worker-handover.test.sh"

WORK="$(mktemp -d -t auto-worker-handover.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_MACHINE="studio"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
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
REPO_OUT="${WORK}/repo-out"
mkdir -p "${REPO}/.claude/auto" "${REPO_OUT}/.claude/auto"
export T_REPO="$REPO" T_OUT="$REPO_OUT"

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import hashlib, json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
sys.path.insert(0, os.path.join(sys.argv[1], "tests", "helpers"))
from _bootstrap import load_lib_module
ph = load_lib_module("programme_home")
pj = load_lib_module("programme_journal")
core = load_lib_module("run_record_core")
wc = load_lib_module("worker_contract")
wh = load_lib_module("worker_handover")
wcw = load_lib_module("worker_contract_write")
wa = load_lib_module("worker_contract_apply")
wr = load_lib_module("worker_register")
ROOT = sys.argv[1]
args = sys.argv[2:]
REPO, OUT_REPO = os.environ["T_REPO"], os.environ["T_OUT"]
RUN = os.environ.get("T_RUN", "")
def rec_hash(repo, run):
    return hashlib.sha256(json.dumps(core.read_run_record(repo, run), sort_keys=True, default=str).encode()).hexdigest()
def kind_count(kind):
    return len([r for r in pj.read(RUN) if r["kind"] == kind])
def space_of(session):
    return None
def item_state(key):
    prog = core.read_run_record(ph.home_path(RUN), RUN)["programme"]
    return prog["items"][key].get("auto_run")
def phase(repo, run):
    return (core.read_run_record(repo, run).get("loop") or {}).get("phase")
def open_runs(key):
    state = item_state(key) or {}
    if state.get("state") == "bound" and phase(state["path"], state["run_id"]) != "done":
        return [state["run_id"]]
    return []
$(cat)
PYEOF
}

echo "── setup ──"

RUN="$(run_py <<'EOF'
run = ph.create_programme(["w2"], "sess-pm")["run"]
AUTH = {"technical_approach": {"mode": "act", "asks": "pm"}, "product_scope": {"mode": "never", "asks": "shawn"}}
BAR = {"internal": ["steps_terminal", "gaps_closed"], "external": ["pr_merged"]}
def make_worker(repo, run_id, session, *, stamp=True, done=False):
    core.init_run_record(repo, run_id, backend="native", driving_session_id=session)
    def put(rec):
        if stamp:
            rec["contract"] = wc.new_contract(set_by="sess-pm", authority=AUTH, done_bar=BAR, workflow="a2", fan_out_cap=3)
        else:
            rec.pop("contract_capable", None)
        if done:
            rec.setdefault("loop", {})["phase"] = "done"
    core._with_locked_run_record(repo, run_id, put)
make_worker(REPO, "wrun", "sess-w")
make_worker(REPO, "wold", "sess-old", stamp=False)
make_worker(REPO, "wdone", "sess-done", done=True)
make_worker(OUT_REPO, "wout", "sess-x")
make_worker(REPO, "wcrash", "sess-c")
def item(key, owner, repo, auto_run):
    body = ph.new_item(key, "Item " + key)
    body["owner"] = {"session_id": owner}
    body["repo"] = repo
    if auto_run is not None:
        body["auto_run"] = auto_run
    return body
def bound(run_id, repo, owner):
    return {"state": "bound", "run_id": run_id, "path": repo, "session_id": owner, "contract": None, "mode": 1, "attempts": 1}
seed = wc.new_contract(set_by="sess-pm", authority=AUTH, done_bar=BAR, workflow="a2", fan_out_cap=3)
launched = {"state": "launched", "run_id": None, "path": None, "session_id": "sess-l", "contract": seed, "mode": 1, "attempts": 1,
            "plan": "p.md", "launched_at": core.now_iso(), "last_start_ok": True, "bound_at": None}
def seed_items(rec):
    prog = rec["programme"]
    prog["remit"]["repos"] = [{"path": REPO}]
    prog["items"]["linear:AI-1"] = item("linear:AI-1", "sess-w", REPO, bound("wrun", REPO, "sess-w"))
    prog["items"]["linear:AI-2"] = item("linear:AI-2", "sess-l", REPO, launched)
    prog["items"]["linear:AI-3"] = item("linear:AI-3", "sess-x", OUT_REPO, bound("wout", OUT_REPO, "sess-x"))
    prog["items"]["linear:AI-4"] = item("linear:AI-4", "sess-done", REPO, bound("wdone", REPO, "sess-done"))
    prog["items"]["linear:AI-5"] = item("linear:AI-5", "sess-old", REPO, bound("wold", REPO, "sess-old"))
    prog["items"]["linear:AI-6"] = item("linear:AI-6", "sess-n", REPO, None)
    prog["items"]["linear:AI-7"] = item("linear:AI-7", "sess-c", REPO, bound("wcrash", REPO, "sess-c"))
core._with_locked_run_record(ph.home_path(run), run, seed_items)
print(run)
EOF
)"
export T_RUN="$RUN"
case "$RUN" in prog-*) pass ;; *) fail "programme setup failed: $RUN" ;; esac

OUT=""
CODE=0
CRASHES=""
prog() {
  OUT="$("$PY" "$PROG" "$@" 2>&1)"
  CODE=$?
  case "$OUT" in *Traceback*) CRASHES="${CRASHES}$* | " ;; esac
}
as() { local sid="$1"; shift; CLAUDE_CODE_SESSION_ID="$sid" prog "$@"; }
HC=(handover-contract --run "$RUN")

snap() {
  run_py "$1" "$2" "$3" <<'EOF'
repo, run, key = args
print(rec_hash(repo, run), json.dumps(item_state(key), sort_keys=True, default=str))
EOF
}
rows() { run_py "$1" <<'EOF'
print(kind_count(args[0]))
EOF
}
expr() { run_py "$1" "$2" <<'EOF'
print(json.dumps(eval(args[1]), sort_keys=True))
EOF
}

refuses() {
  local code="$1" before="$2" repo="$3" run="$4" key="$5" handovers_before="$6"
  it "refused ($code): exit 1, names the cause, no traceback"
  if [ "$CODE" = 1 ]; then case "$OUT" in *"refused ($code)"*) pass ;; *) fail "expected [refused ($code)], got [$OUT]" ;; esac; else fail "exit $CODE: $OUT"; fi
  it "refused ($code): the old run record and the item's auto_run block did not change"
  check "$before" "$(snap "$repo" "$run" "$key")"
  it "refused ($code): no contract_handover row was journaled"
  check "$handovers_before" "$(rows contract_handover)"
}

echo "── queue two pending changes on the bound run ──"

prog set-contract --run "$RUN" --item linear:AI-1 --workflow a4
it "set-contract queued a step change"
check 0 "$CODE"
prog set-contract --run "$RUN" --item linear:AI-1 --authority technical_approach=never:pm --bite pulse
it "set-contract queued a pulse change"
check 0 "$CODE"
it "the old contract is at version 3 with two pending entries"
check '[3,[{"bite":"step","version":2},{"bite":"pulse","version":3}]]' "$(run_py <<'EOF'
c = core.read_run_record(REPO, "wrun")["contract"]
print(json.dumps([c["version"], c["pending_versions"]], separators=(",", ":"), sort_keys=True))
EOF
)"

echo "── the hand-over ──"

it "before the hand-over the item has one open run"
check '["wrun"]' "$(run_py <<'EOF'
print(json.dumps(open_runs("linear:AI-1")))
EOF
)"
as sess-pm "${HC[@]}" --item linear:AI-1
it "handover-contract exits 0"
check 0 "$CODE"
it "the receipt carries exactly the documented keys"
check '["from_path", "from_run", "item", "journaled", "kind", "next", "ok", "pending", "run", "state", "version"]' "$("$PY" -c 'import json,sys; print(json.dumps(sorted(json.loads(sys.stdin.read()).keys())))' <<< "$OUT")"
it "the item went back to launched with no run pointer and records where it came from"
check '["launched", null, null, "wrun", 1, 0]' "$(run_py <<'EOF'
s = item_state("linear:AI-1")
print(json.dumps([s["state"], s["run_id"], s["path"], s["handed_over_from"]["run_id"], s["mode"], s["attempts"]]))
EOF
)"
it "the new seed is the old version plus one with the same authority, done bar, workflow and cap"
check '[4, true, true, "a4", 3, "sess-pm"]' "$(run_py <<'EOF'
new = item_state("linear:AI-1")["contract"]
old = core.read_run_record(REPO, "wrun")["contract"]
print(json.dumps([new["version"], new["authority"] == old["authority"], new["done_bar"] == old["done_bar"],
                  new["workflow"], new["fan_out_cap"], new["set_by"]]))
EOF
)"
it "the new seed validates and its authority has the narrowed technical_approach"
check '"never"' "$(run_py <<'EOF'
new = item_state("linear:AI-1")["contract"]
wc.validate(new)
print(json.dumps(new["authority"]["technical_approach"]["mode"]))
EOF
)"
it "every pending entry is bound at the pulse, plus one for the new version, and nothing is applied yet"
check '[[{"bite":"pulse","version":2},{"bite":"pulse","version":3},{"bite":"pulse","version":4}],0]' "$(run_py <<'EOF'
new = item_state("linear:AI-1")["contract"]
print(json.dumps([new["pending_versions"], new["applied_version"]], separators=(",", ":"), sort_keys=True))
EOF
)"
it "the old run is closed (phase done) and keeps its own contract unchanged at version 3"
check '["done", 3]' "$(run_py <<'EOF'
print(json.dumps([phase(REPO, "wrun"), core.read_run_record(REPO, "wrun")["contract"]["version"]]))
EOF
)"
it "after the hand-over no bound open run remains for the item"
check '[]' "$(run_py <<'EOF'
print(json.dumps(open_runs("linear:AI-1")))
EOF
)"
it "one contract_handover row names the item, the old run and the new version"
check '[1, ["linear:AI-1", "wrun", 4]]' "$(run_py <<'EOF'
rows = [r for r in pj.read(RUN) if r["kind"] == "contract_handover"]
p = rows[-1]["payload"]
print(json.dumps([len(rows), [p["item"], p["from_run"], p["version"]]]))
EOF
)"
it "the item's history records the hand-over"
check 'run_handover' "$(run_py <<'EOF'
prog = core.read_run_record(ph.home_path(RUN), RUN)["programme"]
print(prog["items"]["linear:AI-1"]["history"][-1]["kind"])
EOF
)"
it "start-worker's relaunch check accepts the handed-over item (launched, no attempts)"
check '"ok"' "$(run_py <<'EOF'
state = item_state("linear:AI-1")
wr._refuse_relaunch(RUN, ph.home_path(RUN), "linear:AI-1", state, int(state.get("attempts") or 0))
print(json.dumps("ok"))
EOF
)"

echo "── the old run refuses contract writes ──"

it "a stale call that still aims at the closed run is refused as run_done and its bytes do not change"
check '["run_done", true]' "$(run_py <<'EOF'
before = rec_hash(REPO, "wrun")
state = {"state": "bound", "run_id": "wrun", "path": REPO}
try:
    wcw._edit_run(RUN, "linear:AI-1", state, "sess-w", {"fan_out_cap": 5}, None, "sess-pm", space_of, None)
    print(json.dumps(["no refusal", False]))
except wc.ContractError as exc:
    print(json.dumps([exc.code, rec_hash(REPO, "wrun") == before]))
EOF
)"
prog set-contract --run "$RUN" --item linear:AI-1 --fan-out-cap 5
it "set-contract now edits the new seed, not the old run"
check '["launched", 5]' "$(expr x '[item_state("linear:AI-1")["state"], item_state("linear:AI-1")["contract"]["fan_out_cap"]]')"
it "the old run's cap is still 3"
check 3 "$(expr x 'core.read_run_record(REPO, "wrun")["contract"]["fan_out_cap"]')"
it "set-contract on the seed bumped its version to 5"
check 5 "$(expr x 'item_state("linear:AI-1")["contract"]["version"]')"

echo "── a pending change binds at the new run's first pulse ──"

run_py <<'EOF'
core.init_run_record(REPO, "wnew", backend="native", driving_session_id="sess-w2")
def own(rec):
    rec["programme"]["items"]["linear:AI-1"]["owner"] = {"session_id": "sess-w2"}
core._with_locked_run_record(ph.home_path(RUN), RUN, own)
EOF
as sess-w2 register-run --run "$RUN" --item linear:AI-1 --auto-run wnew --repo "$REPO"
it "the new worker registers the run"
check 0 "$CODE"
it "register-run copied the handed-over contract (version 5)"
has '"contract_version": 5' "$OUT"
it "the new run record carries the contract with the three handed-over pending entries unapplied before its first pulse"
check '[5, 0, 3]' "$(expr x '[core.read_run_record(REPO, "wnew")["contract"]["version"], core.read_run_record(REPO, "wnew")["contract"]["applied_version"], len(core.read_run_record(REPO, "wnew")["contract"]["pending_versions"])]')"
it "the item is bound to the new run"
check '["bound", "wnew"]' "$(expr x '[item_state("linear:AI-1")["state"], item_state("linear:AI-1")["run_id"]]')"
it "the first pulse applies every entry: applied version reaches 5 and none remain pending"
check '[5, []]' "$(run_py <<'EOF'
wa.apply_at_pulse(REPO, "wnew")
c = core.read_run_record(REPO, "wnew")["contract"]
print(json.dumps([c["applied_version"], c["pending_versions"]]))
EOF
)"
it "the old run is still closed and the only open run for the item is the new one"
check '["done", ["wnew"]]' "$(expr x '[phase(REPO, "wrun"), open_runs("linear:AI-1")]')"

echo "── one write: no state with two open runs, including a crash between the steps ──"

it "AI-7 starts with one open run"
check '["wcrash"]' "$(expr x 'open_runs("linear:AI-7")')"
CRASH_OUT="$(run_py <<'EOF'
seen = []
real = wh._move_pointer
def spy(*a, **k):
    seen.append([phase(REPO, "wcrash"), item_state("linear:AI-7")["state"], open_runs("linear:AI-7")])
    raise RuntimeError("simulated crash before the pointer move")
wh._move_pointer = spy
try:
    wh.handover(RUN, "linear:AI-7", caller="sess-pm", space_of=space_of)
except RuntimeError:
    pass
print(json.dumps([seen, item_state("linear:AI-7")["state"], item_state("linear:AI-7")["run_id"], open_runs("linear:AI-7"), phase(REPO, "wcrash")]))
EOF
)"
it "at the crash point the old run is already closed and the item still points at it, so zero open runs"
check '[[["done","bound",[]]],"bound","wcrash",[],"done"]' "$(printf '%s' "$CRASH_OUT" | tr -d ' ')"
prog set-contract --run "$RUN" --item linear:AI-7 --fan-out-cap 2
it "after the crash a contract write on the half-moved item is refused as run_done"
has "refused (run_done)" "$OUT"
as sess-pm "${HC[@]}" --item linear:AI-7
it "the repeat call finishes the move"
check 0 "$CODE"
it "the repeat produced version 2 exactly once and the item is launched"
check '["launched", 2, 1]' "$(expr x '[item_state("linear:AI-7")["state"], item_state("linear:AI-7")["contract"]["version"], len([r for r in pj.read(RUN) if r["kind"] == "contract_handover" and r["payload"]["item"] == "linear:AI-7"])]')"
it "no spy-free state of the happy path ever showed two open runs: the pointer move saw a closed old run"
check '[[["done","bound",[]]]]' "$(run_py <<'EOF'
core.init_run_record(REPO, "wspy", backend="native", driving_session_id="sess-s")
def put(rec):
    rec["contract"] = wc.new_contract(set_by="sess-pm", authority={"technical_approach": {"mode": "act", "asks": "pm"}},
                                      done_bar={"internal": ["steps_terminal"], "external": []}, workflow="a2", fan_out_cap=2)
core._with_locked_run_record(REPO, "wspy", put)
def add(rec):
    body = ph.new_item("linear:AI-9", "Item 9")
    body["owner"] = {"session_id": "sess-s"}
    body["repo"] = REPO
    body["auto_run"] = {"state": "bound", "run_id": "wspy", "path": REPO, "session_id": "sess-s", "contract": None, "mode": 1, "attempts": 1}
    rec["programme"]["items"]["linear:AI-9"] = body
core._with_locked_run_record(ph.home_path(RUN), RUN, add)
seen = []
real = wh._move_pointer
def spy(*a, **k):
    seen.append([phase(REPO, "wspy"), item_state("linear:AI-9")["state"], open_runs("linear:AI-9")])
    return real(*a, **k)
wh._move_pointer = spy
wh.handover(RUN, "linear:AI-9", caller="sess-pm", space_of=space_of)
print(json.dumps([seen], separators=(",", ":")))
EOF
)"

echo "── the hand-over of a done run starts the follow-up ──"

as sess-pm "${HC[@]}" --item linear:AI-4
it "an item whose run is already done is handed over (the follow-up path)"
check 0 "$CODE"
it "the follow-up seed is version 2 and the item is launched"
check '["launched", 2]' "$(expr x '[item_state("linear:AI-4")["state"], item_state("linear:AI-4")["contract"]["version"]]')"

echo "── refusals ──"

HO="$(rows contract_handover)"
REF_BEFORE="$(rows request_refused)"

B1="$(snap "$REPO" wcrash linear:AI-7)"
as sess-pm "${HC[@]}" --item linear:AI-7
refuses not_bound "$B1" "$REPO" wcrash linear:AI-7 "$HO"
it "refused (not_bound): a refusal row was journaled naming the verb"
check "$((REF_BEFORE + 1))" "$(rows request_refused)"

B2="$(snap "$REPO" wrun linear:AI-1)"
as sess-pm "${HC[@]}" --item linear:AI-2
refuses not_bound "$B2" "$REPO" wrun linear:AI-1 "$HO"

as sess-pm "${HC[@]}" --item linear:AI-6
it "an item with no contracted run is refused as no_contract_run"
has "refused (no_contract_run)" "$OUT"

B3="$(snap "$REPO_OUT" wout linear:AI-3)"
as sess-pm "${HC[@]}" --item linear:AI-3
refuses outside_remit "$B3" "$REPO_OUT" wout linear:AI-3 "$HO"

B4="$(snap "$REPO" wold linear:AI-5)"
as sess-pm "${HC[@]}" --item linear:AI-5
refuses predates_contracts "$B4" "$REPO" wold linear:AI-5 "$HO"
it "refused (predates_contracts): the run was not closed"
check 'null' "$(expr x 'phase(REPO, "wold")')"

echo "── a non-PM caller is refused ──"

run_py <<'EOF'
core.init_run_record(REPO, "wguard", backend="native", driving_session_id="sess-g")
def put(rec):
    rec["contract"] = wc.new_contract(set_by="sess-pm", authority={"technical_approach": {"mode": "act", "asks": "pm"}},
                                      done_bar={"internal": ["steps_terminal"], "external": []}, workflow="a2", fan_out_cap=2)
core._with_locked_run_record(REPO, "wguard", put)
def add(rec):
    body = ph.new_item("linear:AI-10", "Item 10")
    body["owner"] = {"session_id": "sess-g"}
    body["repo"] = REPO
    body["auto_run"] = {"state": "bound", "run_id": "wguard", "path": REPO, "session_id": "sess-g", "contract": None, "mode": 1, "attempts": 1}
    rec["programme"]["items"]["linear:AI-10"] = body
core._with_locked_run_record(ph.home_path(RUN), RUN, add)
EOF
B5="$(snap "$REPO" wguard linear:AI-10)"
as sess-g "${HC[@]}" --item linear:AI-10
refuses not_driving "$B5" "$REPO" wguard linear:AI-10 "$HO"
it "the worker's own session cannot close its run or move the pointer"
check 'null' "$(expr x 'phase(REPO, "wguard")')"
as sess-nobody "${HC[@]}" --item linear:AI-10
refuses not_driving "$B5" "$REPO" wguard linear:AI-10 "$HO"

it "the guard also runs inside the run-record lock: a non-PM caller reaching the close step changes nothing"
check '["not_driving", true]' "$(run_py <<'EOF'
before = rec_hash(REPO, "wguard")
try:
    wh._close_old(RUN, REPO, "wguard", "sess-g", "sess-g", space_of)
    print(json.dumps(["no refusal", False]))
except wc.ContractError as exc:
    print(json.dumps([exc.code, rec_hash(REPO, "wguard") == before]))
EOF
)"
it "the guard also runs inside the programme write: a non-PM caller reaching the pointer move changes nothing"
check '["not_driving", true]' "$(run_py <<'EOF'
before = json.dumps(item_state("linear:AI-10"), sort_keys=True)
seed = wh.next_seed(core.read_run_record(REPO, "wguard")["contract"], "sess-pm")
try:
    wh._move_pointer(RUN, ph.home_path(RUN), "linear:AI-10", REPO, "wguard", "sess-g", seed, "sess-g", space_of)
    print(json.dumps(["no refusal", False]))
except wc.ContractError as exc:
    print(json.dumps([exc.code, json.dumps(item_state("linear:AI-10"), sort_keys=True) == before]))
EOF
)"
it "the pointer move refuses when the item no longer holds the bound run it closed"
check '["state_changed", true]' "$(run_py <<'EOF'
before = json.dumps(item_state("linear:AI-2"), sort_keys=True)
seed = wh.next_seed(core.read_run_record(REPO, "wguard")["contract"], "sess-pm")
try:
    wh._move_pointer(RUN, ph.home_path(RUN), "linear:AI-2", REPO, "wguard", "sess-l", seed, "sess-pm", space_of)
    print(json.dumps(["no refusal", False]))
except wc.ContractError as exc:
    print(json.dumps([exc.code, json.dumps(item_state("linear:AI-2"), sort_keys=True) == before]))
EOF
)"

echo "── run/session mismatch, compacted context, applied version ──"

run_py <<'EOF'
core.init_run_record(REPO, "wmis", backend="native", driving_session_id="sess-z")
def put(rec):
    rec["contract"] = wc.new_contract(set_by="sess-pm", authority={"technical_approach": {"mode": "act", "asks": "pm"}},
                                      done_bar={"internal": ["steps_terminal"], "external": []}, workflow="a2", fan_out_cap=2)
core._with_locked_run_record(REPO, "wmis", put)
def add(rec):
    body = ph.new_item("linear:AI-11", "Item 11")
    body["owner"] = {"session_id": "sess-m"}
    body["repo"] = REPO
    body["auto_run"] = {"state": "bound", "run_id": "wmis", "path": REPO, "session_id": "sess-m", "contract": None, "mode": 1, "attempts": 1}
    rec["programme"]["items"]["linear:AI-11"] = body
core._with_locked_run_record(ph.home_path(RUN), RUN, add)
EOF
B6="$(snap "$REPO" wmis linear:AI-11)"
as sess-pm "${HC[@]}" --item linear:AI-11
refuses session_mismatch "$B6" "$REPO" wmis linear:AI-11 "$HO"
it "refused (session_mismatch): the run was not closed"
check 'null' "$(expr x 'phase(REPO, "wmis")')"

run_py <<'EOF'
open(os.path.join(ph.home_path(RUN), ph.COMPACT_FLAG), "w").close()
EOF
B7="$(snap "$REPO" wguard linear:AI-10)"
as sess-pm "${HC[@]}" --item linear:AI-10
refuses compacted "$B7" "$REPO" wguard linear:AI-10 "$HO"
run_py <<'EOF'
os.remove(os.path.join(ph.home_path(RUN), ph.COMPACT_FLAG))
EOF

it "the new seed starts with applied version 0 even when the old contract had applied versions"
check '[0, [{"bite": "pulse", "version": 4}], 4]' "$(run_py <<'EOF'
old = wc.new_contract(set_by="sess-pm", authority={}, done_bar={"internal": ["steps_terminal"], "external": []}, workflow="a2", fan_out_cap=2, version=3)
old["applied_version"] = 3
seed = wh.next_seed(old, "sess-pm")
print(json.dumps([seed["applied_version"], seed["pending_versions"], seed["version"]], sort_keys=True))
EOF
)"
it "a pending PM answer survives the hand-over and is rebound to the pulse"
check '[{"answer": {"by": "pm", "question_id": "q1", "text": "yes"}, "bite": "pulse", "version": 3}, {"bite": "pulse", "version": 4}]' "$(run_py <<'EOF'
old = wc.new_contract(set_by="sess-pm", authority={}, done_bar={"internal": ["steps_terminal"], "external": []}, workflow="a2", fan_out_cap=2, version=3)
old["pending_versions"] = [{"version": 3, "bite": "step", "answer": {"question_id": "q1", "text": "yes", "by": "pm"}}]
print(json.dumps(wh.next_seed(old, "sess-pm")["pending_versions"], sort_keys=True))
EOF
)"

it "no verb crashed"
check "" "$CRASHES"

echo "worker-handover.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
