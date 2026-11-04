#!/usr/bin/env bash
# auto unit test: lib/worker_contract.py — the contract block, its validator, effective authority
# clamped at read time, read-time staleness, and the shared write guard.
#
# Every refusal assertion pins the refusal CODE and a phrase of the message, never "non-zero": a
# missing function also fails, and only the specific code proves the intended branch fired.
# Key presence is asserted beside values: an absent `contract` key and an empty authority map must
# read differently.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
check() { if [ "$1" = "$2" ]; then pass; else fail "expected [$1] got [$2]"; fi; }
has() { case "$2" in *"$1"*) pass ;; *) fail "expected to find [$1] in [$2]" ;; esac; }
refused() { case "$3" in "$1|"*"$2"*) pass ;; *) fail "expected refusal [$1] naming [$2], got [$3]" ;; esac; }

echo "worker-contract.test.sh"

WORK="$(mktemp -d -t auto-worker-contract.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_MACHINE="studio"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_CODE_SESSION_ID="sess-pm"
unset HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_BIN_PATH CLAUDE_AUTO_REPO 2>/dev/null || true
: > "$CLAUDE_AUTO_SECRETS_FILE"

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import copy, json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
sys.path.insert(0, os.path.join(sys.argv[1], "tests", "helpers"))
from _bootstrap import load_lib_module
wc = load_lib_module("worker_contract")
ph = load_lib_module("programme_home")
pd = load_lib_module("programme_decisions")
core = load_lib_module("run_record_core")
args = sys.argv[2:]
NOW = "2026-11-02T00:00:00Z"
ITEM = "linear:AI-1"
BASE = dict(
    set_by="sess-pm", workflow="a2", fan_out_cap=3,
    authority={"technical_approach": {"mode": "act", "asks": "pm"}, "product_scope": {"mode": "propose", "asks": "shawn"}},
    done_bar={"internal": ["steps_terminal", "gaps_closed"], "external": ["pr_merged", "ci_green"]})
def mk(**over):
    spec = dict(BASE)
    spec.update(over)
    return wc.new_contract(**spec)
def refusal(fn):
    try:
        fn()
    except wc.ContractError as exc:
        return f"{exc.code}|{exc}"
    return "accepted|"
def table(level):
    return lambda kind: level
def no_rulings(kind):
    return []
def restrict(kind):
    return [{"id": "r1", "kind": kind, "effect": "restrict", "items": [ITEM], "until": "", "baseline": None}]
def eff(contract, kind, level="act", rulings=no_rulings, accepted=True):
    return wc.effective_authority(contract, kind, item=ITEM, level_of=table(level), rulings_of=rulings, now=NOW,
                                  accepted=accepted)
$(cat)
PYEOF
}

echo "── block shape and validator ──"

it "a contract with all four parts validates and carries the engine-written keys"
OUT="$(run_py <<'EOF'
block = mk()
print(json.dumps({"keys": sorted(block), "pending": block["pending_versions"], "applied": block["applied_version"],
                  "version": block["version"], "valid": wc.validate(block) == block}, sort_keys=True))
EOF
)"
check '{"applied": 0, "keys": ["applied_version", "authority", "done_bar", "fan_out_cap", "pending_versions", "set_at", "set_by", "version", "workflow"], "pending": [], "valid": true, "version": 1}' "$OUT"

it "an unknown decision kind is refused and the refusal names the kind"
OUT="$(run_py <<'EOF'
print(refusal(lambda: mk(authority={"ship_it_anyway": {"mode": "act", "asks": "pm"}})))
EOF
)"
refused "unknown_kind" "'ship_it_anyway'" "$OUT"

it "the two new decision kinds are accepted in an authority map"
OUT="$(run_py <<'EOF'
print(refusal(lambda: mk(authority={"goal_amend": {"mode": "propose", "asks": "pm"},
                                    "workflow_change": {"mode": "act_and_tell", "asks": "pm"}})))
EOF
)"
check "accepted|" "$OUT"

it "an authority entry with an unknown mode, an unknown asks or an extra key is refused by name"
OUT="$(run_py <<'EOF'
print(refusal(lambda: mk(authority={"tool_choice": {"mode": "sometimes", "asks": "pm"}})))
print(refusal(lambda: mk(authority={"tool_choice": {"mode": "act", "asks": "nobody"}})))
print(refusal(lambda: mk(authority={"tool_choice": {"mode": "act", "asks": "pm", "why": "x"}})))
EOF
)"
refused "bad_authority" "unknown mode 'sometimes'" "$(echo "$OUT" | sed -n 1p)"
refused "bad_authority" "unknown asks 'nobody'" "$(echo "$OUT" | sed -n 2p)"
refused "bad_authority" "exactly the keys mode and asks" "$(echo "$OUT" | sed -n 3p)"

it "a done bar naming an input the exit predicate does not compute is refused, internal and external"
OUT="$(run_py <<'EOF'
print(refusal(lambda: mk(done_bar={"internal": ["vibes_good"], "external": []})))
print(refusal(lambda: mk(done_bar={"internal": ["steps_terminal"], "external": ["deploy_green"]})))
print(refusal(lambda: mk(done_bar={"internal": [], "external": ["pr_merged"]})))
print(refusal(lambda: mk(done_bar={"internal": ["steps_terminal", "steps_terminal"], "external": []})))
print(refusal(lambda: mk(done_bar={"internal": ["steps_terminal"]})))
EOF
)"
refused "bad_done_bar" "'vibes_good', which the exit predicate does not compute" "$(echo "$OUT" | sed -n 1p)"
refused "bad_done_bar" "external names 'deploy_green'" "$(echo "$OUT" | sed -n 2p)"
refused "bad_done_bar" "at least one exit-predicate input" "$(echo "$OUT" | sed -n 3p)"
refused "bad_done_bar" "repeats a name" "$(echo "$OUT" | sed -n 4p)"
refused "bad_done_bar" "exactly the keys internal and external" "$(echo "$OUT" | sed -n 5p)"

it "a fan-out cap below 1, a non-integer cap and a bool cap are refused; 1 is accepted"
OUT="$(run_py <<'EOF'
for cap in (0, -3, "2", 2.5, True):
    print(refusal(lambda cap=cap: mk(fan_out_cap=cap)))
print(refusal(lambda: mk(fan_out_cap=1)))
EOF
)"
for n in 1 2 3 4 5; do refused "bad_cap" "must be an integer of at least 1" "$(echo "$OUT" | sed -n ${n}p)"; done
check "accepted|" "$(echo "$OUT" | sed -n 6p)"

it "a bad version, workflow name, applied_version, pending entry, unknown key and missing key are each refused by code"
OUT="$(run_py <<'EOF'
good = mk()
def with_(**over):
    block = copy.deepcopy(good)
    block.update(over)
    return lambda: wc.validate(block)
print(refusal(with_(version=0)))
print(refusal(with_(workflow="Not A Name")))
print(refusal(with_(applied_version=5)))
print(refusal(with_(pending_versions=[{"version": 2, "bite": "whenever"}])))
print(refusal(with_(surprise=1)))
missing = copy.deepcopy(good)
del missing["fan_out_cap"]
print(refusal(lambda: wc.validate(missing)))
print(refusal(lambda: wc.validate(["not", "a", "map"])))
EOF
)"
refused "bad_version" "must be an integer of at least 1" "$(echo "$OUT" | sed -n 1p)"
refused "bad_workflow" "'Not A Name' is not a workflow name" "$(echo "$OUT" | sed -n 2p)"
refused "bad_applied" "applied_version 5" "$(echo "$OUT" | sed -n 3p)"
refused "bad_pending" "needs an integer version and a bite" "$(echo "$OUT" | sed -n 4p)"
refused "bad_shape" "unknown keys ['surprise']" "$(echo "$OUT" | sed -n 5p)"
refused "bad_shape" "missing ['fan_out_cap']" "$(echo "$OUT" | sed -n 6p)"
refused "bad_shape" "must be a map" "$(echo "$OUT" | sed -n 7p)"

echo "── absent contract, empty authority, staleness ──"

it "no contract key reads as no_contract; an empty authority map reads as a contract with no kinds"
OUT="$(run_py <<'EOF'
absent = {"run_id": "w"}
empty = {"run_id": "w", "contract": mk(authority={})}
print(json.dumps({
    "absent_has_key": "contract" in absent, "absent_reading": wc.reading(absent), "absent_block": wc.contract_of(absent),
    "empty_has_key": "contract" in empty, "empty_state": wc.reading(empty)["state"],
    "empty_kinds": wc.reading(empty)["authority_kinds"], "empty_authority_present": "authority" in empty["contract"],
}, sort_keys=True))
EOF
)"
check '{"absent_block": null, "absent_has_key": false, "absent_reading": {"state": "no_contract"}, "empty_authority_present": true, "empty_has_key": true, "empty_kinds": [], "empty_state": "contract"}' "$OUT"

it "a contract key that is not a map is refused, not read as no contract"
OUT="$(run_py <<'EOF'
print(refusal(lambda: wc.reading({"contract": None})))
EOF
)"
refused "bad_shape" "not a map" "$OUT"

it "a contract at version 4 with applied_version 2 reads stale, and no stale flag is stored"
OUT="$(run_py <<'EOF'
block = mk(version=4)
block["applied_version"] = 2
record = {"contract": block}
before = copy.deepcopy(record)
r = wc.reading(record)
current = copy.deepcopy(block)
current["applied_version"] = 4
print(json.dumps({"stale": r["stale"], "applied": r["applied_version"], "version": r["version"],
                  "record_unchanged": record == before, "no_stale_key": "stale" not in block and "stale" not in record,
                  "current_not_stale": wc.reading({"contract": current})["stale"]}, sort_keys=True))
EOF
)"
check '{"applied": 2, "current_not_stale": false, "no_stale_key": true, "record_unchanged": true, "stale": true, "version": 4}' "$OUT"

echo "── effective authority ──"

it "a worker authority of act on prod_deploy reads back as never with asks shawn"
OUT="$(run_py <<'EOF'
contract = mk(authority={"prod_deploy": {"mode": "act", "asks": "pm"}})
print(json.dumps(eff(contract, "prod_deploy"), sort_keys=True))
EOF
)"
check '{"asks": "shawn", "clamped": true, "kind": "prod_deploy", "mode": "never", "reason": "protected", "source": "contract"}' "$OUT"

it "every protected kind reads never and shawn whatever the contract and the table say"
OUT="$(run_py <<'EOF'
contract = mk(authority={k: {"mode": "act", "asks": "pm"} for k in pd.PROTECTED_KINDS})
print(json.dumps([[eff(contract, k)["mode"], eff(contract, k)["asks"], eff(mk(authority={}), k)["mode"]] for k in pd.PROTECTED_KINDS]))
EOF
)"
check '[["never", "shawn", "never"], ["never", "shawn", "never"], ["never", "shawn", "never"], ["never", "shawn", "never"], ["never", "shawn", "never"]]' "$OUT"

it "a Ruling that tightens a kind after the contract was written changes the effective authority with no rewrite"
OUT="$(run_py <<'EOF'
contract = mk(authority={"technical_approach": {"mode": "act", "asks": "pm"}})
stored = copy.deepcopy(contract)
before = eff(contract, "technical_approach")
after = eff(contract, "technical_approach", rulings=restrict)
print(json.dumps({"before": [before["mode"], before["asks"]], "after": [after["mode"], after["asks"], after["reason"], after["clamped"]],
                  "contract_unchanged": contract == stored}, sort_keys=True))
EOF
)"
check '{"after": ["propose", "shawn", "restrict", true], "before": ["act", "pm"], "contract_unchanged": true}' "$OUT"

it "the contract can narrow below the table but never widen past it"
OUT="$(run_py <<'EOF'
def row(stored, level):
    e = eff(mk(authority={"tool_choice": stored}), "tool_choice", level=level)
    return [e["mode"], e["asks"], e["clamped"]]
print(json.dumps({
    "narrow": row({"mode": "propose", "asks": "pm"}, "act"),
    "never_narrow": row({"mode": "never", "asks": "pm"}, "act"),
    "widen_past_tell": row({"mode": "act", "asks": "pm"}, "act_and_tell"),
    "widen_past_propose": row({"mode": "act", "asks": "pm"}, "propose"),
    "widen_past_never": row({"mode": "act_and_tell", "asks": "pm"}, "never"),
    "equal": row({"mode": "act_and_tell", "asks": "pm"}, "act_and_tell"),
}, sort_keys=True))
EOF
)"
check '{"equal": ["act_and_tell", "pm", false], "narrow": ["propose", "pm", false], "never_narrow": ["never", "pm", false], "widen_past_never": ["never", "shawn", true], "widen_past_propose": ["propose", "shawn", true], "widen_past_tell": ["act_and_tell", "pm", true]}' "$OUT"

it "a kind the contract does not mention reads from the programme table, and a missing table level is default-deny"
OUT="$(run_py <<'EOF'
contract = mk(authority={})
a = eff(contract, "tool_choice", level="act")
b = eff(contract, "tool_choice", level="propose")
c = wc.effective_authority(contract, "tool_choice", item=ITEM, level_of=lambda kind: None, rulings_of=no_rulings, now=NOW)
print(json.dumps({"a": [a["mode"], a["asks"], a["source"]], "b": [b["mode"], b["asks"], b["source"]],
                  "c": [c["mode"], c["asks"]]}, sort_keys=True))
EOF
)"
check '{"a": ["act", "pm", "programme"], "b": ["propose", "shawn", "programme"], "c": ["propose", "shawn"]}' "$OUT"

it "an unaccepted agreement holds product_scope at propose whatever the contract says"
OUT="$(run_py <<'EOF'
e = eff(mk(authority={"product_scope": {"mode": "act", "asks": "pm"}}), "product_scope", accepted=False)
print(json.dumps([e["mode"], e["asks"], e["reason"]]))
EOF
)"
check '["propose", "shawn", "unaccepted"]' "$OUT"

it "effective authority refuses a kind outside the closed list"
OUT="$(run_py <<'EOF'
try:
    eff(mk(), "ship_it_anyway")
    print("accepted")
except pd.DecisionError as exc:
    print("refused", exc)
EOF
)"
has "refused unknown decision kind 'ship_it_anyway'" "$OUT"

it "goal_amend and workflow_change join the closed list with an act_and_tell default; the map covers every kind"
RUN="$(run_py <<'EOF'
print(ph.create_programme(["w2"], "sess-pm")["run"])
EOF
)"
OUT="$(run_py "$RUN" <<'EOF'
pp = load_lib_module("programme_protocol")
levels = pp.load()["autonomy"]
programme = ph.normalize_programme(core.read_run_record(ph.home_path(args[0]), args[0])["programme"])
inputs = wc.programme_inputs(programme, ITEM, now=NOW)
full = wc.effective_map(mk(authority={}), **inputs)
print(json.dumps({
    "in_list": [k in pd.DECISION_KINDS for k in ("goal_amend", "workflow_change")],
    "table": [levels["goal_amend"]["level"], levels["workflow_change"]["level"]],
    "effective": [[full[k]["mode"], full[k]["asks"]] for k in ("goal_amend", "workflow_change")],
    "covers_all": sorted(full) == sorted(pd.DECISION_KINDS),
}, sort_keys=True))
EOF
)"
check '{"covers_all": true, "effective": [["act_and_tell", "pm"], ["act_and_tell", "pm"]], "in_list": [true, true], "table": ["act_and_tell", "act_and_tell"]}' "$OUT"

it "programme inputs read the live table and Rulings: a real restrict Ruling on the record tightens the kind"
OUT="$(run_py "$RUN" <<'EOF'
run = args[0]
rec = core.read_run_record(ph.home_path(run), run)
programme = ph.normalize_programme(rec["programme"])
contract = mk(authority={"technical_approach": {"mode": "act", "asks": "pm"}})
base = wc.effective_authority(contract, "technical_approach", **wc.programme_inputs(programme, ITEM, now=NOW))
programme["context"] = {"decisions": {"r-restrict": [{
    "rev": 1, "state": "accepted", "kind": "technical_approach", "effect": "restrict", "applies_to": [ITEM],
    "until": None, "baseline": None, "quote": "q", "source": "typed"}]}}
tight = wc.effective_authority(contract, "technical_approach", **wc.programme_inputs(programme, ITEM, now=NOW))
print(json.dumps({"base": [base["mode"], base["asks"]], "tight": [tight["mode"], tight["asks"], tight["reason"]]}))
EOF
)"
check '{"base": ["act", "pm"], "tight": ["propose", "shawn", "restrict"]}' "$OUT"

echo "── write guard ──"

SPACE_OF="def space_of(sid):
    return (ph.DEFAULT_SERVER, 'w2') if sid == 'sess-w' else None"

it "the guard passes the driving session with the lease for a worker in a remit space, and returns the record"
OUT="$(run_py "$RUN" <<EOF
$SPACE_OF
rec = wc.guard(args[0], "sess-w", caller="sess-pm", space_of=space_of)
print(rec["run_id"] == args[0], rec["driving_session_id"])
EOF
)"
check "True sess-pm" "$OUT"

it "the guard refuses a caller that is not the driving session, naming driving session"
OUT="$(run_py "$RUN" <<EOF
$SPACE_OF
print(refusal(lambda: wc.guard(args[0], "sess-w", caller="sess-other", space_of=space_of)))
EOF
)"
refused "not_driving" "only the programme's driving session may write a worker's contract" "$OUT"

it "the guard refuses a caller with no session id"
OUT="$(run_py "$RUN" <<EOF
$SPACE_OF
os.environ.pop("CLAUDE_CODE_SESSION_ID", None)
print(refusal(lambda: wc.guard(args[0], "sess-w", space_of=space_of)))
EOF
)"
refused "no_session" "CLAUDE_CODE_SESSION_ID is unset" "$OUT"

it "the guard refuses a worker outside the remit, naming the worker session"
OUT="$(run_py "$RUN" <<EOF
$SPACE_OF
print(refusal(lambda: wc.guard(args[0], "sess-out", caller="sess-pm", space_of=space_of)))
print(refusal(lambda: wc.guard(args[0], None, caller="sess-pm", space_of=space_of)))
EOF
)"
refused "outside_remit" "worker session 'sess-out' is not in the programme's remit" "$(echo "$OUT" | sed -n 1p)"
refused "outside_remit" "worker session None is not in the programme's remit" "$(echo "$OUT" | sed -n 2p)"

it "a worker whose item sits on a remit repo is in the remit even with no registry row for its space"
OUT="$(run_py "$RUN" <<EOF
$SPACE_OF
sys.path.insert(0, os.path.join(sys.argv[1], "tests", "helpers"))
from programme_records import edit
run = args[0]
before = refusal(lambda: wc.guard(run, "sess-item", caller="sess-pm", space_of=space_of))
repo = os.path.join(os.environ["CLAUDE_AUTO_DATA_DIR"], "repo-a")
os.makedirs(repo, exist_ok=True)
edit(run, 'prog["remit"]["repos"] = [{"path": P}]; prog["items"]["linear:AI-9"] = {"owner": {"session_id": "sess-item"}, "sessions": [], "repo": P}', {"P": repo})
after = refusal(lambda: wc.guard(run, "sess-item", caller="sess-pm", space_of=space_of))
elsewhere = refusal(lambda: wc.guard(run, "sess-stranger", caller="sess-pm", space_of=space_of))
print(before.split("|")[0], after, elsewhere.split("|")[0])
EOF
)"
check "outside_remit accepted| outside_remit" "$OUT"

it "the guard refuses a driving session whose lease moved, with its own lease message"
OUT="$(run_py "$RUN" <<EOF
$SPACE_OF
path = ph.lease_path(*ph.parse_space("w2"))
original = open(path).read()
lease = json.loads(original)
lease["session_id"] = "sess-new"
open(path, "w").write(json.dumps(lease))
try:
    print(refusal(lambda: wc.guard(args[0], "sess-w", caller="sess-pm", space_of=space_of)))
finally:
    open(path, "w").write(original)
print(refusal(lambda: wc.guard(args[0], "sess-w", caller="sess-pm", space_of=space_of)))
EOF
)"
refused "lease_lost" "no longer holds the programme's lease" "$(echo "$OUT" | sed -n 1p)"
check "accepted|" "$(echo "$OUT" | sed -n 2p)"

it "the guard runs inside the programme run-record lock, and a takeover between the two calls is refused"
OUT="$(run_py "$RUN" <<EOF
$SPACE_OF
sys.path.insert(0, os.path.join(sys.argv[1], "tests", "helpers"))
from programme_records import edit
run = args[0]
home = ph.home_path(run)
seen = {}
core._with_locked_run_record(home, run, lambda rec: seen.update(first=refusal(lambda: wc.guard(run, "sess-w", caller="sess-pm", space_of=space_of))))
edit(run, 'rec["driving_session_id"] = "sess-takeover"', {})
core._with_locked_run_record(home, run, lambda rec: seen.update(second=refusal(lambda: wc.guard(run, "sess-w", caller="sess-pm", space_of=space_of))))
print(seen["first"])
print(seen["second"])
EOF
)"
check "accepted|" "$(echo "$OUT" | sed -n 1p)"
refused "not_driving" "only the programme's driving session" "$(echo "$OUT" | sed -n 2p)"

it "a failed hand-item is a hand_failed refusal, not a crash"
OUT="$(run_py "$RUN" <<EOF
import types
real = wc.subprocess.run
wc.subprocess.run = lambda *a, **k: types.SimpleNamespace(returncode=1, stderr="boom", stdout="")
try:
    print(refusal(lambda: wc.hand_item("run-x", "linear:AI-1", kind="goal_amend", question="q", if_nothing="n")))
finally:
    wc.subprocess.run = real
EOF
)"
refused "hand_failed" "hand-item failed: boom" "$OUT"

it "RegisterError, QuestionError and GoalError are ContractErrors, so the one refusals wrapper catches all three"
OUT="$(run_py "$RUN" <<EOF
from _bootstrap import load_lib_module
print([issubclass(load_lib_module(m).__dict__[c], wc.ContractError)
       for m, c in (("worker_register", "RegisterError"), ("worker_question", "QuestionError"), ("goal_doc", "GoalError"))])
EOF
)"
check "[True, True, True]" "$OUT"

echo ""
echo "worker-contract.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
