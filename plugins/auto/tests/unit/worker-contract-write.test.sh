#!/usr/bin/env bash
# auto unit test: the PM-only contract write (set-contract) and the worker-question verbs (open-worker-questions,
# escalate-worker-questions, answer-worker-question).
#
# Every refusal assertion pins the refusal CODE or a phrase of the message and checks that the worker's run
# record bytes did not move: a missing verb also exits non-zero, so a bare exit code proves nothing.
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

echo "worker-contract-write.test.sh"

WORK="$(mktemp -d -t auto-worker-contract-write.XXXXXX)"
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
$(cat)
PYEOF
}

echo "── setup ──"

RUN="$(run_py <<'EOF'
run = ph.create_programme(["w2"], "sess-pm")["run"]
AUTH = {"technical_approach": {"mode": "act", "asks": "pm"}, "product_scope": {"mode": "never", "asks": "shawn"}}
BAR = {"internal": ["steps_terminal"], "external": ["pr_merged"]}
def make_worker(repo, run_id, session, *, stamp=True, done=False, contract=True):
    core.init_run_record(repo, run_id, backend="native", driving_session_id=session)
    def put(rec):
        if contract:
            rec["contract"] = wc.new_contract(set_by="sess-pm", authority=AUTH, done_bar=BAR, workflow="a2", fan_out_cap=3)
        if not stamp:
            rec.pop("contract_capable", None)
        if done:
            rec.setdefault("loop", {})["phase"] = "done"
    core._with_locked_run_record(repo, run_id, put)
make_worker(REPO, "wrun", "sess-w")
make_worker(REPO, "wold", "sess-old", stamp=False)
make_worker(REPO, "wdone", "sess-done", done=True)
make_worker(OUT_REPO, "wout", "sess-x")
make_worker(REPO, "wmis", "sess-z")
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
    prog["items"]["linear:AI-2"] = item("linear:AI-2", "sess-x", OUT_REPO, bound("wout", OUT_REPO, "sess-x"))
    prog["items"]["linear:AI-3"] = item("linear:AI-3", "sess-old", REPO, bound("wold", REPO, "sess-old"))
    prog["items"]["linear:AI-4"] = item("linear:AI-4", "sess-done", REPO, bound("wdone", REPO, "sess-done"))
    prog["items"]["linear:AI-5"] = item("linear:AI-5", "sess-l", REPO, launched)
    prog["items"]["linear:AI-6"] = item("linear:AI-6", "sess-n", REPO, None)
    prog["items"]["linear:AI-7"] = item("linear:AI-7", "sess-b", REPO, dict(launched, state="launch-blocked"))
    prog["items"]["linear:AI-8"] = item("linear:AI-8", "sess-m", REPO, bound("wmis", REPO, "sess-m"))
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
SC=(set-contract --run "$RUN")

contract_field() {
  run_py "$1" "$2" "$3" <<'EOF'
repo, run, expr = args
rec = core.read_run_record(repo, run)
c = rec["contract"]
print(json.dumps(eval(expr), sort_keys=True))
EOF
}
joined() { printf '%s|%s' "$CODE" "$1"; }
run_hash() { run_py "$1" "$2" <<'EOF'
print(rec_hash({"REPO": REPO, "OUT": OUT_REPO}[args[0]], args[1]))
EOF
}

refuses() {
  local code="$1" phrase="$2" before_hash="$3" repo_name="$4" run_name="$5" refusals_before="$6"
  it "refused ($code): exit 1, names the cause, no traceback"
  if [ "$CODE" = 1 ]; then case "$OUT" in *"refused ($code)"*"$phrase"*) pass ;; *) fail "expected [refused ($code)] naming [$phrase], got [$OUT]" ;; esac; else fail "exit $CODE: $OUT"; fi
  it "refused ($code): the worker's run record bytes did not change"
  check "$before_hash" "$(run_hash "$repo_name" "$run_name")"
  it "refused ($code): exactly one new refusal row and no new contract_set row"
  check "[$((${refusals_before% *} + 1)), ${refusals_before#* }]" "$(run_py <<'EOF'
print(json.dumps([kind_count("request_refused"), kind_count("contract_set")]))
EOF
)"
}
refusal_rows() { run_py <<'EOF'
print(kind_count("request_refused"), kind_count("contract_set"))
EOF
}
set_rows() { run_py <<'EOF'
print(kind_count("contract_set"))
EOF
}

echo "── narrowing authority with bite pulse ──"

prog "${SC[@]}" --item linear:AI-1 --authority technical_approach=never:pm --bite pulse
it "the narrowing exits 0"
check 0 "$CODE"
it "the receipt carries exactly the documented keys"
check '["auto_run", "bite", "fields", "item", "journaled", "kind", "ok", "queued", "run", "version", "via"]' "$("$PY" -c 'import json,sys; print(json.dumps(sorted(json.loads(sys.stdin.read()).keys())))' <<< "$OUT")"
it "the version rose by one and the authority entry changed"
check '[2, "never", "sess-pm"]' "$(contract_field "$REPO" wrun '[c["version"], c["authority"]["technical_approach"]["mode"], c["set_by"]]')"
it "exactly one pending_versions entry exists, version 2, bite pulse"
check '[{"bite": "pulse", "version": 2}]' "$(contract_field "$REPO" wrun 'c["pending_versions"]')"
it "the applied version did not move (only the engine writes it)"
check 0 "$(contract_field "$REPO" wrun 'c["applied_version"]')"
it "exactly one contract_set journal row, naming the item, version and bite"
check '[1, ["linear:AI-1", 2, "pulse"]]' "$(run_py <<'EOF'
rows = [r for r in pj.read(RUN) if r["kind"] == "contract_set"]
p = rows[-1]["payload"]
print(json.dumps([len(rows), [p["item"], p["version"], p["bite"]]]))
EOF
)"

echo "── default bite points ──"

prog "${SC[@]}" --item linear:AI-1 --authority acceptance=never:pm
it "narrowing with no bite given binds at the pulse"
check '[3, "pulse"]' "$(contract_field "$REPO" wrun '[c["version"], c["pending_versions"][-1]["bite"]]')"
prog "${SC[@]}" --item linear:AI-1 --workflow a4
it "a workflow change with no bite given binds at the step boundary"
check '[4, "step", "a4"]' "$(contract_field "$REPO" wrun '[c["version"], c["pending_versions"][-1]["bite"], c["workflow"]]')"
prog "${SC[@]}" --item linear:AI-1 --fan-out-cap 2
it "a fan-out cap change with no bite given binds at the step boundary"
check '[5, "step", 2]' "$(contract_field "$REPO" wrun '[c["version"], c["pending_versions"][-1]["bite"], c["fan_out_cap"]]')"
prog "${SC[@]}" --item linear:AI-1 --done-external none --done-internal steps_terminal,gaps_closed
it "a done bar change with no bite given binds at the step boundary"
check '[6, "step", [], ["steps_terminal", "gaps_closed"]]' "$(contract_field "$REPO" wrun '[c["version"], c["pending_versions"][-1]["bite"], c["done_bar"]["external"], c["done_bar"]["internal"]]')"
prog "${SC[@]}" --item linear:AI-1 --authority technical_approach=act:pm
it "widening back up to the table with no bite given binds at the step boundary"
check '[7, "step", "act"]' "$(contract_field "$REPO" wrun '[c["version"], c["pending_versions"][-1]["bite"], c["authority"]["technical_approach"]["mode"]]')"
prog "${SC[@]}" --item linear:AI-1 --authority work_sequencing=never:pm --workflow a2
it "a narrowing mixed with a workflow change binds at the pulse, the earlier of the two"
check '[8, "pulse"]' "$(contract_field "$REPO" wrun '[c["version"], c["pending_versions"][-1]["bite"]]')"
prog "${SC[@]}" --item linear:AI-1 --authority work_sequencing=never:pm
it "restating the same mode is not a narrowing and binds at the step boundary"
check '[9, "step"]' "$(contract_field "$REPO" wrun '[c["version"], c["pending_versions"][-1]["bite"]]')"
prog "${SC[@]}" --item linear:AI-1 --drop-authority work_sequencing
it "dropping an authority entry returns the kind to the programme table and binds at the step boundary"
check '[10, "step", false]' "$(contract_field "$REPO" wrun '[c["version"], c["pending_versions"][-1]["bite"], "work_sequencing" in c["authority"]]')"
it "every accepted change left exactly one pending entry and one contract_set row"
check '[10, 9]' "$(run_py <<'EOF'
c = core.read_run_record(REPO, "wrun")["contract"]
print(json.dumps([len(c["pending_versions"]) + 1, kind_count("contract_set")]))
EOF
)"

echo "── the driving session and the lease ──"

BEFORE="$(run_hash REPO wrun)"; RB="$(refusal_rows)"
as sess-w "${SC[@]}" --item linear:AI-1 --authority technical_approach=act:pm
refuses not_driving "only the programme's driving session may write a worker's contract" "$BEFORE" REPO wrun "$RB"
BEFORE="$(run_hash REPO wrun)"; RB="$(refusal_rows)"
as sess-stranger "${SC[@]}" --item linear:AI-1 --workflow a4
refuses not_driving "only the programme's driving session may write a worker's contract" "$BEFORE" REPO wrun "$RB"

it "a lease that moves between the first check and the record lock refuses inside the lock and changes nothing"
OUT="$(run_py <<'EOF'
wcw = load_lib_module("worker_contract_write")
path = ph.lease_path(*ph.parse_space("w2"))
original = open(path).read()
real, hits = core._with_locked_run_record, []
def moving(*a, **k):
    hits.append(1)
    lease = json.loads(original)
    lease["session_id"] = "sess-new"
    open(path, "w").write(json.dumps(lease))
    return real(*a, **k)
before = rec_hash(REPO, "wrun")
sets = kind_count("contract_set")
core._with_locked_run_record = moving
try:
    wcw.set_contract(RUN, "linear:AI-1", {"workflow": "a4"}, caller="sess-pm", space_of=space_of)
    verdict = "accepted"
except wc.ContractError as exc:
    verdict = exc.code
finally:
    core._with_locked_run_record = real
    open(path, "w").write(original)
print(json.dumps({"verdict": verdict, "lock_taken": bool(hits), "unchanged": before == rec_hash(REPO, "wrun"),
                  "no_row": sets == kind_count("contract_set")}, sort_keys=True))
EOF
)"
check '{"lock_taken": true, "no_row": true, "unchanged": true, "verdict": "lease_lost"}' "$OUT"

it "a lease that moves between the first check and the programme write refuses a launched change inside the write and leaves the seed alone"
OUT="$(run_py <<'EOF'
wcw = load_lib_module("worker_contract_write")
path = ph.lease_path(*ph.parse_space("w2"))
original = open(path).read()
real, hits = wcw.programme_authority.write, []
def moving(*a, **k):
    hits.append(1)
    lease = json.loads(original)
    lease["session_id"] = "sess-new"
    open(path, "w").write(json.dumps(lease))
    return real(*a, **k)
wcw.programme_authority.write = moving
try:
    wcw.set_contract(RUN, "linear:AI-5", {"workflow": "a4"}, caller="sess-pm", space_of=space_of)
    verdict = "accepted"
except wc.ContractError as exc:
    verdict = exc.code
finally:
    wcw.programme_authority.write = real
    open(path, "w").write(original)
seed = core.read_run_record(ph.home_path(RUN), RUN)["programme"]["items"]["linear:AI-5"]["auto_run"]["contract"]
print(json.dumps({"verdict": verdict, "write_taken": bool(hits), "seed_version": seed["version"]}, sort_keys=True))
EOF
)"
check '{"seed_version": 1, "verdict": "lease_lost", "write_taken": true}' "$OUT"

it "a caller that is not the driving session is refused before the run-record lock is ever taken"
OUT="$(run_py <<'EOF'
wcw = load_lib_module("worker_contract_write")
real, hits = core._with_locked_run_record, []
def counting(*a, **k):
    hits.append(1)
    return real(*a, **k)
core._with_locked_run_record = counting
try:
    wcw.set_contract(RUN, "linear:AI-1", {"workflow": "a4"}, caller="sess-w", space_of=space_of)
    verdict = "accepted"
except wc.ContractError as exc:
    verdict = exc.code
finally:
    core._with_locked_run_record = real
print(json.dumps({"verdict": verdict, "locks": len(hits)}, sort_keys=True))
EOF
)"
check '{"locks": 0, "verdict": "not_driving"}' "$OUT"

it "the driving session works again once the lease is restored"
prog "${SC[@]}" --item linear:AI-1 --workflow a2
check 0 "$CODE"

echo "── the remit ──"

BEFORE="$(run_hash OUT wout)"; RB="$(refusal_rows)"
prog "${SC[@]}" --item linear:AI-2 --authority technical_approach=never:pm
refuses outside_remit "is not in the programme's remit" "$BEFORE" OUT wout "$RB"

echo "── widening is capped at the Authority table and Rulings ──"

BEFORE="$(run_hash REPO wrun)"; RB="$(refusal_rows)"
prog "${SC[@]}" --item linear:AI-1 --authority product_scope=act:pm
refuses widens_authority "'product_scope' cannot go to 'act'" "$BEFORE" REPO wrun "$RB"
it "the refusal names the ceiling the table allows"
has "'propose'" "$OUT"
BEFORE="$(run_hash REPO wrun)"; RB="$(refusal_rows)"
prog "${SC[@]}" --item linear:AI-1 --authority prod_deploy=propose:pm
refuses widens_authority "'prod_deploy' cannot go to 'propose'" "$BEFORE" REPO wrun "$RB"
BEFORE="$(run_hash REPO wrun)"; RB="$(refusal_rows)"
prog "${SC[@]}" --item linear:AI-1 --authority technical_approach=act:pm --authority acceptance=act:pm --authority goal_amend=act:pm --authority product_call=act:pm
refuses widens_authority "'goal_amend' cannot go to 'act'" "$BEFORE" REPO wrun "$RB"
it "a refused multi-kind change applied none of its kinds"
check '"never"' "$(contract_field "$REPO" wrun 'c["authority"]["acceptance"]["mode"]')"
prog "${SC[@]}" --item linear:AI-1 --authority product_scope=propose:shawn
it "widening up to the table's level is accepted"
check '0|"propose"' "$(joined "$(contract_field "$REPO" wrun 'c["authority"]["product_scope"]["mode"]')")"
prog "${SC[@]}" --item linear:AI-1 --authority product_scope=never:shawn
it "narrowing is accepted"
check '0|"never"' "$(joined "$(contract_field "$REPO" wrun 'c["authority"]["product_scope"]["mode"]')")"

echo "── a done run, a run that predates contracts, and shape refusals ──"

BEFORE="$(run_hash REPO wdone)"; RB="$(refusal_rows)"
prog "${SC[@]}" --item linear:AI-4 --workflow a4
refuses run_done "start a follow-up run" "$BEFORE" REPO wdone "$RB"
it "the done refusal names the item and the done run"
has "linear:AI-4" "$OUT"
BEFORE="$(run_hash REPO wold)"; RB="$(refusal_rows)"
prog "${SC[@]}" --item linear:AI-3 --workflow a4
refuses predates_contracts "run predates contracts" "$BEFORE" REPO wold "$RB"

BEFORE="$(run_hash REPO wrun)"; RB="$(refusal_rows)"
prog "${SC[@]}" --item linear:AI-1 --authority made_up_kind=act:pm
refuses unknown_kind "made_up_kind" "$BEFORE" REPO wrun "$RB"
BEFORE="$(run_hash REPO wrun)"; RB="$(refusal_rows)"
prog "${SC[@]}" --item linear:AI-1 --authority technical_approach=sometimes:pm
refuses bad_authority "unknown mode 'sometimes'" "$BEFORE" REPO wrun "$RB"
BEFORE="$(run_hash REPO wrun)"; RB="$(refusal_rows)"
prog "${SC[@]}" --item linear:AI-1 --fan-out-cap 0
refuses bad_cap "must be an integer of at least 1" "$BEFORE" REPO wrun "$RB"
BEFORE="$(run_hash REPO wrun)"; RB="$(refusal_rows)"
prog "${SC[@]}" --item linear:AI-1 --workflow a4 --bite later
refuses bad_bite "bite 'later'" "$BEFORE" REPO wrun "$RB"
BEFORE="$(run_hash REPO wrun)"; RB="$(refusal_rows)"
prog "${SC[@]}" --item linear:AI-1 --drop-authority prod_deploy
refuses no_such_entry "no entry for 'prod_deploy'" "$BEFORE" REPO wrun "$RB"
BEFORE="$(run_hash REPO wrun)"; RB="$(refusal_rows)"
prog "${SC[@]}" --item linear:AI-6 --workflow a4
refuses no_contract_run "has no contracted run" "$BEFORE" REPO wrun "$RB"
BEFORE="$(run_hash REPO wrun)"; RB="$(refusal_rows)"
prog "${SC[@]}" --item linear:AI-7 --workflow a4
refuses launch_blocked "launch-blocked" "$BEFORE" REPO wrun "$RB"
BEFORE="$(run_hash REPO wmis)"; RB="$(refusal_rows)"
prog "${SC[@]}" --item linear:AI-8 --workflow a4
refuses session_mismatch "is not the item's owner session sess-m" "$BEFORE" REPO wmis "$RB"
prog "${SC[@]}" --item linear:AI-1
it "a call that changes nothing is a usage error"
check 2 "$CODE"
prog "${SC[@]}" --item linear:AI-1 --fan-out-cap many
it "a non-numeric cap is a usage error"
check 2 "$CODE"

echo "── a programme that ended, or whose context was compacted ──"

HOME_DIR="$(run_py <<'EOF'
print(ph.home_path(RUN))
EOF
)"
: > "${HOME_DIR}/.compact-flag"
BEFORE="$(run_hash REPO wrun)"; RB="$(refusal_rows)"
prog "${SC[@]}" --item linear:AI-1 --workflow a4
refuses compacted "rules --ack" "$BEFORE" REPO wrun "$RB"
rm -f "${HOME_DIR}/.compact-flag"
run_py <<'EOF'
core._with_locked_run_record(ph.home_path(RUN), RUN, lambda rec: rec["programme"].__setitem__("ended", {"at": core.now_iso()}))
EOF
BEFORE="$(run_hash REPO wrun)"; RB="$(refusal_rows)"
prog "${SC[@]}" --item linear:AI-1 --workflow a4
refuses ended "the programme has ended" "$BEFORE" REPO wrun "$RB"
run_py <<'EOF'
core._with_locked_run_record(ph.home_path(RUN), RUN, lambda rec: rec["programme"].pop("ended", None))
EOF

echo "── a change while the item is launched edits the seed ──"

BEFORE_SETS="$(set_rows)"
prog "${SC[@]}" --item linear:AI-5 --authority technical_approach=never:pm
it "the launched change exits 0 and reports the seed as the target"
check '0|["seed", 2, false]' "$(joined "$("$PY" -c 'import json,sys; d=json.loads(sys.stdin.read()); print(json.dumps([d["via"], d["version"], d["queued"]]))' <<< "$OUT")")"
it "the item's seed holds version 2 and the new authority, with no pending entry"
check '[2, "never", [], 0]' "$(run_py <<'EOF'
c = core.read_run_record(ph.home_path(RUN), RUN)["programme"]["items"]["linear:AI-5"]["auto_run"]["contract"]
print(json.dumps([c["version"], c["authority"]["technical_approach"]["mode"], c["pending_versions"], c["applied_version"]]))
EOF
)"
it "the launched change journaled one contract_set row"
check "$((BEFORE_SETS + 1))" "$(set_rows)"
prog "${SC[@]}" --item linear:AI-5 --fan-out-cap 4
it "a second launched change bumps the seed again"
check '[3, 4]' "$(run_py <<'EOF'
c = core.read_run_record(ph.home_path(RUN), RUN)["programme"]["items"]["linear:AI-5"]["auto_run"]["contract"]
print(json.dumps([c["version"], c["fan_out_cap"]]))
EOF
)"
it "a launched change that widens beyond the table is refused and leaves the seed alone"
prog "${SC[@]}" --item linear:AI-5 --authority prod_deploy=propose:pm
check '1|3' "$(joined "$(run_py <<'EOF'
print(core.read_run_record(ph.home_path(RUN), RUN)["programme"]["items"]["linear:AI-5"]["auto_run"]["contract"]["version"])
EOF
)")"
run_py <<'EOF'
core.init_run_record(REPO, "lrun", backend="native", driving_session_id="sess-l")
EOF
as sess-l register-run --run "$RUN" --item linear:AI-5 --auto-run lrun --repo "$REPO"
it "register-run then copies the edited seed's version into the run record"
check '0|[3, 4, "never"]' "$(joined "$(contract_field "$REPO" lrun '[c["version"], c["fan_out_cap"], c["authority"]["technical_approach"]["mode"]]')")"
prog "${SC[@]}" --item linear:AI-5 --authority technical_approach=act:pm
it "once the item is bound the same change goes to the run record with a pending entry"
check '0|[4, "step"]' "$(joined "$(contract_field "$REPO" lrun '[c["version"], c["pending_versions"][-1]["bite"]]')")"

echo "── a launched item that turns bound between the first check and the lock ──"

it "the change is refused inside the programme write when the item is no longer launched"
OUT="$(run_py <<'EOF'
wcw = load_lib_module("worker_contract_write")
def reg(rec):
    item = rec["programme"]["items"]["linear:AI-7"]
    item["auto_run"] = dict(item["auto_run"], state="launched", session_id="sess-b")
core._with_locked_run_record(ph.home_path(RUN), RUN, reg)
authority = load_lib_module("programme_authority")
real, flipped = authority.write, []
def racing(home, run_id, change, *a, **k):
    if not flipped:
        flipped.append(1)
        def flip(rec):
            rec["programme"]["items"]["linear:AI-7"]["auto_run"]["state"] = "bound"
        core._with_locked_run_record(ph.home_path(RUN), RUN, flip)
    return real(home, run_id, change, *a, **k)
wcw.programme_authority.write = racing
try:
    wcw.set_contract(RUN, "linear:AI-7", {"workflow": "a4"}, caller="sess-pm", space_of=space_of)
    verdict = "accepted"
except wc.ContractError as exc:
    verdict = exc.code
finally:
    wcw.programme_authority.write = real
seed = core.read_run_record(ph.home_path(RUN), RUN)["programme"]["items"]["linear:AI-7"]["auto_run"]["contract"]
print(json.dumps({"verdict": verdict, "seed_version": seed["version"]}, sort_keys=True))
EOF
)"
check '{"seed_version": 1, "verdict": "state_changed"}' "$OUT"

echo "── the verb is not a read verb and no picker answer approves it ──"

it "set-contract and the question verbs are in neither READ_VERBS nor PICK_VERBS"
check '{"pick": [], "read": []}' "$(run_py <<'EOF'
import importlib.util
spec = importlib.util.spec_from_file_location("hook", os.path.join(ROOT, "lib", "on-pretooluse-subagent.py"))
hook = importlib.util.module_from_spec(spec); spec.loader.exec_module(hook)
approval = load_lib_module("programme_approval")
verbs = ("set-contract", "open-worker-questions", "escalate-worker-questions", "answer-worker-question")
print(json.dumps({"read": [v for v in verbs if v in hook.READ_VERBS], "pick": [v for v in verbs if v in approval.PICK_VERBS]}, sort_keys=True))
EOF
)"

echo "── the worker-question verbs ──"

prog describe
it "describe lists the new verbs"
check '[]' "$(printf '%s' "$OUT" | "$PY" -c 'import json,sys; v=json.loads(sys.stdin.read())["verbs"]; print(json.dumps([n for n in ("set-contract","open-worker-questions","escalate-worker-questions","answer-worker-question") if n not in v]))')"
QID="$(run_py <<'EOF'
wq = load_lib_module("worker_question")
parsed = wq.read_input({"questions": [{"question": "Which approach should the parser refactor take?", "header": "Q", "options": [{"label": "A", "description": "a"}]}]})
decision = {"route": "pm", "kind": "technical_approach", "label": None, "mode": "never", "asks": "pm", "safe_default": False, "reason": "authority"}
worker = {"run_id": "wrun", "session_id": "sess-w", "repo": REPO}
print(wq.record_question(RUN, "linear:AI-1", worker, parsed, decision)["qid"])
EOF
)"
prog open-worker-questions --run "$RUN"
it "open-worker-questions lists the open question as JSON"
check '0|true' "$(joined "$(printf '%s' "$OUT" | "$PY" -c 'import json,sys; d=json.loads(sys.stdin.read()); print(json.dumps(any(q["qid"] == sys.argv[1] for q in d["questions"])))' "$QID")")"
as sess-w answer-worker-question --run "$RUN" --question "$QID" --text "Use the existing parser."
it "a worker session cannot answer its own question"
check 1 "$CODE"
has "only the programme's driving session may write a worker's contract" "$OUT"
as sess-w escalate-worker-questions --run "$RUN"
it "a worker session cannot escalate"
check 1 "$CODE"
has "only the programme's driving session may escalate or answer a worker question" "$OUT"
prog answer-worker-question --run "$RUN" --question qnothing --text "x"
it "an unknown question is refused with its code"
has "refused (unknown_question)" "$OUT"
prog answer-worker-question --run "$RUN" --question "$QID" --text "Use the existing parser."
it "the PM's answer exits 0 and lands as a pending entry on the worker's contract"
check '0|true' "$(joined "$(contract_field "$REPO" wrun 'any(e.get("answer", {}).get("question_id") == "'"$QID"'" for e in c["pending_versions"])')")"
prog answer-worker-question --run "$RUN" --question "$QID" --text "again"
it "answering twice is refused with its code"
has "refused (already_answered)" "$OUT"
prog escalate-worker-questions --run "$RUN"
it "escalate-worker-questions exits 0 with nothing due"
check '0|[]' "$(joined "$(printf '%s' "$OUT" | "$PY" -c 'import json,sys; print(json.dumps(json.loads(sys.stdin.read())["escalated"]))')")"

echo "── the refusal catch ──"

it "programme.py exits 1 without a traceback for a ContractError or a QuestionError that no verb converted"
OUT="$(run_py <<'EOF'
prog = load_lib_module("programme")
wq = load_lib_module("worker_question")
def contract_refusal(argv):
    raise wc.ContractError("probe contract refusal", "probe")
def question_refusal(argv):
    raise wq.QuestionError("probe question refusal", "probe")
prog._VERBS["probe-contract"] = prog._Verb(contract_refusal, "")
prog._VERBS["probe-question"] = prog._Verb(question_refusal, "")
print(json.dumps([prog._cli(["probe-contract"]), prog._cli(["probe-question"])]))
EOF
)"
has '[1, 1]' "$OUT"
lacks Traceback "$OUT"

it "a ContractError or QuestionError raised inside a prompt-approved write is journaled as one refusal and still propagates"
OUT="$(run_py <<'EOF'
sys.path.insert(0, os.path.join(ROOT, "tests", "fixtures"))
from programme_prompts import append_prompt
prog = load_lib_module("programme")
wq = load_lib_module("worker_question")
pid = append_prompt(RUN, "sess-pm", "approve the probe", "typed")["prompt_id"]
def contract_change(programme, prompt, rec):
    raise wc.ContractError("probe contract refusal", "probe")
def question_change(programme, prompt, rec):
    raise wq.QuestionError("probe question refusal", "probe")
out = []
for change in (contract_change, question_change):
    before = kind_count("approval_refused")
    try:
        prog._write({"run": RUN}, change, "probe", prompt_id=pid, verb="probe")
        out.append("returned")
    except (wc.ContractError, wq.QuestionError):
        out.append(kind_count("approval_refused") - before)
print(json.dumps(out))
EOF
)"
check '[1, 1]' "$OUT"

it "no verb crashed"
check "" "$CRASHES"

echo "worker-contract-write.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
