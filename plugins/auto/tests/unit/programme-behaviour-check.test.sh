#!/usr/bin/env bash
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
lacks() { case "$2" in *"$1"*) fail "did not expect [$1] in [$2]" ;; *) pass ;; esac; }

echo "programme-behaviour-check.test.sh"

WORK="$(mktemp -d -t auto-behaviour-check.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_CARRYOVER_STORE="${WORK}/personal/carryover.json"
export CLAUDE_AUTO_MACHINE="studio"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_CODE_SESSION_ID="sess-pm"
unset CLAUDE_AUTO_BEHAVIOURS_STORE HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_BIN_PATH CLAUDE_AUTO_REPO 2>/dev/null || true
: > "$CLAUDE_AUTO_SECRETS_FILE"
export CLAUDE_AUTO_BEHAVIOURS_STORE="${WORK}/stores/behaviours.json"

ALPHA="${WORK}/repos/alpha"
mkdir -p "$ALPHA"
export ALPHA WORK

# The wording below is the shape of the two live behaviours in the programme that prompted this check.
WORKER_DONE_WHEN="a worker session has completed the work it was started for: its item's PR is merged and its pane is idle"
SWEEP_WHEN="every sweep, for each session in the remit"

py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import hashlib, json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
sys.path.insert(0, os.path.join(sys.argv[1], 'tests', 'fixtures'))
from programme_prompts import append_prompt as fixture_prompt
ph = load_lib_module("programme_home")
core = load_lib_module("run_record_core")
pb = load_lib_module("programme_behaviours")
pj = load_lib_module("programme_journal")
args = sys.argv[2:]
ALPHA = os.environ["ALPHA"]
def beh(bid, layer="programme", **kw):
    entry = {"id": bid, "layer": layer, "applies_to": "both", "state": "active",
             "when": {"text": "when the work is a bug", "checks": []}, "do": ["reproduce it first"]}
    if layer == "repo":
        entry["repo_key"] = "acme/alpha"
    entry.update(kw)
    return entry
def worker_done(**kw):
    return beh("b51850c", applies_to="both",
               when={"text": "$WORKER_DONE_WHEN", "checks": [], "trigger": "merge"},
               do=["reflect first: write down what you learned (memory, docs, handoff notes) and say what is left, if anything",
                   "then stop; the PM closes the pane once you have stopped"],
               dont=["do not take new work outside your original remit; the PM starts a fresh session with its own handoff instead"],
               stop="the pane is closed", **kw)
def sweep(**kw):
    return beh("bc3f80d", applies_to="pm", when={"text": "$SWEEP_WHEN", "checks": []},
               do=["read each session in the remit and unblock it: answer its question, give it direction, send the next step",
                   "decide trivial questions yourself and tell the session what you decided"],
               dont=["do not wait for Shawn or ask him about trivial questions",
                     "do not stop at a report when a session can be moved forward"],
               stop="Shawn is asked only when the issue is a significant change in scope or direction", **kw)
$(cat)
PYEOF
}

it "the live pair: the new retire-a-worker behaviour lists the sweep behaviour, for a stated reason"
OUT="$(py <<'EOF'
pbc = load_lib_module("programme_behaviour_check")
rows = pbc.check(worker_done(), [sweep()])
print(json.dumps([[r["ref"], [x["reason"] for x in r["reasons"]]] for r in rows]))
EOF
)"
has '"bc3f80d"' "$OUT"
has 'instruction_touches_situation' "$OUT"

it "a listed behaviour carries both sides' do, dont and stop lines for the PM to read"
OUT="$(py <<'EOF'
pbc = load_lib_module("programme_behaviour_check")
row = pbc.check(worker_done(), [sweep()])[0]
print(json.dumps(sorted(row["lines"])), len(row["lines"]["do"]), len(row["lines"]["dont"]), bool(row["lines"]["stop"]))
EOF
)"
check '["do", "dont", "stop"] 2 2 True' "$OUT"

it "one shared when word is not a reason: the old noise case lists nothing"
OUT="$(py <<'EOF'
pbc = load_lib_module("programme_behaviour_check")
a = beh("n1", when={"text": "a bug report comes in", "checks": []}, do=["label it"])
b = beh("n2", when={"text": "the work is a bug", "checks": []}, do=["reproduce it first"])
print(len(pbc.check(a, [b])))
EOF
)"
check "0" "$OUT"

it "two shared when words are a reason"
OUT="$(py <<'EOF'
pbc = load_lib_module("programme_behaviour_check")
a = beh("n1", when={"text": "a customer bug report comes in", "checks": []}, do=["label it"])
b = beh("n2", when={"text": "the customer sends a bug", "checks": []}, do=["reproduce it first"])
print([x["reason"] for x in pbc.check(a, [b])[0]["reasons"]])
EOF
)"
has 'shared_when' "$OUT"

it "repo behaviours in different repos are never listed against each other"
OUT="$(py <<'EOF'
pbc = load_lib_module("programme_behaviour_check")
a = beh("r1", "repo", repo_key="acme/alpha", when={"text": "a customer bug report comes in", "checks": []})
b = beh("r2", "repo", repo_key="acme/beta", when={"text": "a customer bug report comes in", "checks": []})
print(len(pbc.check(a, [b])))
EOF
)"
check "0" "$OUT"

it "a workers-only and a pm-only behaviour are never listed against each other"
OUT="$(py <<'EOF'
pbc = load_lib_module("programme_behaviour_check")
a = beh("w1", applies_to="workers", when={"text": "a customer bug report comes in", "checks": []})
b = beh("p1", applies_to="pm", when={"text": "a customer bug report comes in", "checks": []})
print(len(pbc.check(a, [b])))
EOF
)"
check "0" "$OUT"

it "a do line equal to another behaviour's dont line is flagged as a possible compromise"
OUT="$(py <<'EOF'
pbc = load_lib_module("programme_behaviour_check")
a = beh("n1", do=["Close the pane at once"], when={"text": "an unrelated situation here", "checks": []})
b = beh("n2", dont=["close the pane at once."], when={"text": "something else entirely", "checks": []}, do=["x"])
row = pbc.check(a, [b])[0]
print(row["flag"], [x["reason"] for x in row["reasons"]])
EOF
)"
has 'may_contradict' "$OUT"
has 'equal_do_dont' "$OUT"

it "a tool one behaviour names and the other forbids in dont is listed and flagged"
OUT="$(py <<'EOF'
pbc = load_lib_module("programme_behaviour_check")
a = beh("n1", tools=["Linear MCP"], when={"text": "an unrelated situation here", "checks": []})
b = beh("n2", dont=["do not use the Linear MCP for issues"], when={"text": "something else entirely", "checks": []}, do=["x"])
row = pbc.check(a, [b])[0]
print(row["flag"], [x["reason"] for x in row["reasons"]])
EOF
)"
has 'may_contradict' "$OUT"
has 'tool_forbidden_in_dont' "$OUT"

it "the same explicit trigger and a shared named tool are each a reason"
OUT="$(py <<'EOF'
pbc = load_lib_module("programme_behaviour_check")
a = beh("n1", tools=["agent-browser"], when={"text": "alpha situation", "checks": [], "trigger": "merge"})
b = beh("n2", tools=["agent-browser"], when={"text": "beta situation", "checks": [], "trigger": "merge"})
print(sorted(x["reason"] for x in pbc.check(a, [b])[0]["reasons"]))
EOF
)"
check "['same_trigger', 'shared_tool']" "$OUT"

it "a retired or proposed behaviour is not listed, and the entry itself is never listed against itself"
OUT="$(py <<'EOF'
pbc = load_lib_module("programme_behaviour_check")
a = worker_done()
print(len(pbc.check(a, [sweep(state="retired"), sweep(state="proposed"), a])))
EOF
)"
check "0" "$OUT"

SNAP='snap = {
  "agreement": {"terms": {
    "cadence": {"value": "on_change", "seconds": 3600},
    "remit": {"value": "space"},
    "stop_rule": {"value": "nothing_it_can_act_on"},
    "tools_of_record": {"value": ["tracker", "tasks", "plans"]}}},
  "rulings": [{"id": "r1", "effect": "restrict", "kind": "tool_choice", "quote": "tool choice is Shawn only", "applies_to": []},
              {"id": "r2", "effect": "grant", "kind": "work_sequencing", "quote": "you decide the order", "applies_to": []}],
  "autonomy": [{"action": "file_issue", "level": "propose", "layer": "personal"},
               {"action": "eval_waiver", "level": "act", "layer": "personal"}],
  "rules": [{"id": "fix-only", "layer": "personal", "requires": ["merged", "verified", "recorded"]},
            {"id": "plugin-release", "layer": "plugin", "requires": ["merged", "released"]}],
  "operating_contract": {"version": 1, "escalations": [], "protected": [],
    "project_terms": [{"id": "t1", "area": "browser", "value": "Never use the Playwright MCP; use agent-browser", "reserved": False},
                      {"id": "t2", "area": "implementation", "value": "Use the compound-engineering pipeline", "reserved": False}]}}'

it "the sweep behaviour references the cadence and remit terms, with no contradiction flag"
OUT="$(py <<EOF
pcc = load_lib_module("programme_contract_check")
$SNAP
rows = pcc.check(sweep(), snap)
print(json.dumps({r["ref"]: r.get("flag") for r in rows}))
EOF
)"
has '"term:cadence": null' "$OUT"
has '"term:remit": null' "$OUT"
lacks 'may_contradict' "$OUT"

it "the operating contract line is never printed as a row"
OUT="$(py <<EOF
pcc = load_lib_module("programme_contract_check")
$SNAP
print([r["ref"] for r in pcc.check(sweep(), snap)])
EOF
)"
lacks 'contract' "$OUT"

it "a tool the preferred-tool text forbids gives a may-contradict row; the tool it recommends gives a plain reference"
OUT="$(py <<EOF
pcc = load_lib_module("programme_contract_check")
$SNAP
bad = {r["ref"]: r.get("flag") for r in pcc.check(beh("n1", tools=["Playwright MCP"]), snap)}
good = {r["ref"]: r.get("flag") for r in pcc.check(beh("n2", tools=["agent-browser"]), snap)}
print(json.dumps([bad, good]))
EOF
)"
has '[{"tool:t1": "may_contradict"}, {"tool:t1": null}]' "$OUT"

it "a do line that touches a kind a restrict Ruling reserves is flagged; a grant Ruling is only a reference"
OUT="$(py <<EOF
pcc = load_lib_module("programme_contract_check")
$SNAP
rows = {r["ref"]: r.get("flag") for r in pcc.check(beh("n1", do=["decide the tool choice for each job", "decide the work sequencing"]), snap)}
print(json.dumps(rows))
EOF
)"
has '"ruling:r1": "may_contradict"' "$OUT"
has '"ruling:r2": null' "$OUT"

it "a do line that touches an action whose Authority level is stricter than act is flagged; a level of act is not"
OUT="$(py <<EOF
pcc = load_lib_module("programme_contract_check")
$SNAP
rows = {r["ref"]: r.get("flag") for r in pcc.check(beh("n1", do=["file issue for each finding", "grant an eval waiver"]), snap)}
print(json.dumps(rows))
EOF
)"
has '"authority:file_issue": "may_contradict"' "$OUT"
lacks 'authority:eval_waiver' "$OUT"

it "a do line naming a deliverable lists the Done standards that require it, grouped by deliverable"
OUT="$(py <<EOF
pcc = load_lib_module("programme_contract_check")
$SNAP
rows = pcc.check(beh("n1", do=["release the package once it is verified"]), snap)
print(json.dumps({r["ref"]: [r.get("flag"), r.get("ids")] for r in rows if r["kind"] == "done"}))
EOF
)"
has '"done:verified": [null, ["fix-only"]]' "$OUT"
has '"done:released": [null, ["plugin-release"]]' "$OUT"

it "a do line that skips a deliverable a Done standard requires is flagged"
OUT="$(py <<EOF
pcc = load_lib_module("programme_contract_check")
$SNAP
rows = {r["ref"]: r.get("flag") for r in pcc.check(beh("n1", do=["skip verification when the change is small"]), snap)}
print(json.dumps(rows))
EOF
)"
has '"done:verified": "may_contradict"' "$OUT"

it "a stop line is a plain stop-rule row; it is flagged only when it shares two words with the stop-rule text"
OUT="$(py <<EOF
pcc = load_lib_module("programme_contract_check")
$SNAP
plain = {r["ref"]: r.get("flag") for r in pcc.check(beh("n1", stop="the pane is closed"), snap)}
close = {r["ref"]: r.get("flag") for r in pcc.check(beh("n2", stop="nothing it can act on is left"), snap)}
print(json.dumps([plain.get("term:stop_rule", "absent"), close.get("term:stop_rule", "absent")]))
EOF
)"
check '[null, "may_contradict"]' "$OUT"

it "a snapshot with no operating contract still checks the agreement terms and does not fail"
OUT="$(py <<EOF
pcc = load_lib_module("programme_contract_check")
$SNAP
snap.pop("operating_contract")
print(sorted(r["ref"] for r in pcc.check(sweep(), snap)))
EOF
)"
has 'term:cadence' "$OUT"

PROG="${AUTO_ROOT}/lib/programme.py"
OUT=""
CODE=0
prog() { OUT="$("$PY" "$PROG" "$@" 2>&1)"; CODE=$?; }
jfield() { "$PY" -c 'import json,sys; d=json.loads(sys.argv[1].splitlines()[-1]); print(eval(sys.argv[2]))' "$1" "$2" 2>&1; }
new_run() {
  py <<'EOF'
run = ph.create_programme(["w1"], "sess-pm")["run"]
def mutate(rec):
    prog = rec["programme"]
    prog["remit"]["repos"] = [{"path": ALPHA, "github": "acme/alpha"}]
    prog["behaviours"] = [sweep()]
core._with_locked_run_record(ph.home_path(run), run, mutate)
print(run)
EOF
}
tprompt() {
  py "$1" "$2" <<'EOF'
print(fixture_prompt(args[0], "sess-pm", args[1], "typed")["prompt_id"])
EOF
}
state() {
  py "$1" "$2" <<'EOF'
rec = core.read_run_record(ph.home_path(args[0]), args[0])
prog = rec["programme"]
print(eval(args[1]))
EOF
}

RUN="$(new_run)"
P1="$(tprompt "$RUN" "when a worker is finished, reflect, stop, and close it")"

it "check-behaviour prints both results for the live pair and writes nothing"
BEFORE="$(state "$RUN" "len(prog['behaviours'])")"
prog check-behaviour --run "$RUN" --when "$WORKER_DONE_WHEN" --trigger merge --do "then stop; the PM closes the pane once you have stopped" \
  --dont "do not take new work outside your original remit"
check 0 "$CODE"
has 'bc3f80d' "$OUT"
has 'instruction_touches_situation' "$OUT"
check "$BEFORE" "$(state "$RUN" "len(prog['behaviours'])")"

it "check-behaviour needs no typed prompt and journals nothing"
check "0" "$(state "$RUN" "sum(1 for r in pj.read(args[0]) if r['kind'] == 'behaviour_recorded')")"

it "check-behaviour names the reasons it checked and says opposite meaning is not detected"
prog check-behaviour --run "$RUN" --when "a wholly unrelated moment" --do "water the plants"
has 'opposite meaning is not detected' "$OUT"
has 'same_trigger' "$OUT"

it "check-behaviour still refuses a do line that names a protected escalation"
prog check-behaviour --run "$RUN" --when "a release is ready" --do "deploy to production"
check 1 "$CODE"
has 'protected' "$OUT"

it "record-behaviour prints the behaviour and contract results with the checks and the undo line"
prog record-behaviour --run "$RUN" --prompt "$P1" --when "$WORKER_DONE_WHEN" --trigger merge \
  --pm-check "the item's PR is merged" --do "then stop; the PM closes the pane once you have stopped" \
  --dont "do not take new work outside your original remit"
check 0 "$CODE"
BID="$(jfield "$OUT" 'd["behaviour"]')"
has 'bc3f80d' "$OUT"
has 'undo' "$OUT"
has '"contract"' "$OUT"
has 'opposite meaning is not detected' "$OUT"

it "the journaled row keeps ids and reasons but not the side-by-side lines"
check "True" "$(state "$RUN" "all('lines' not in json.dumps(r.get('payload', {})) for r in pj.read(args[0]) if r['kind'] == 'behaviour_recorded')")"

it "recording succeeds with unanswered items, and the output counts them"
check "True" "$(jfield "$OUT" 'd["unanswered"] >= 1')"

it "--relates-to and --unrelated store the answer on the entry and lower the unanswered count"
P2="$(tprompt "$RUN" "always read the reflection before closing a worker")"
prog record-behaviour --run "$RUN" --prompt "$P2" --when "$WORKER_DONE_WHEN" --trigger merge \
  --do "then stop; the PM closes the pane once you have stopped" --dont "do not take new work outside your original remit" \
  --relates-to bc3f80d --unrelated "term:cadence=cadence is about sweeps not workers"
check 0 "$CODE"
BID2="$(jfield "$OUT" 'd["behaviour"]')"
check "['bc3f80d']" "$(state "$RUN" "[b for b in prog['behaviours'] if b['id'] == '$BID2'][0]['relates_to']")"
check "True" "$(state "$RUN" "[b for b in prog['behaviours'] if b['id'] == '$BID2'][0]['unrelated'][0]['id'] == 'term:cadence'")"

it "--unrelated without a reason is refused"
prog record-behaviour --run "$RUN" --prompt "$P2" --when "$WORKER_DONE_WHEN" --do "stop" --unrelated "bc3f80d"
check 1 "$CODE"

it "--relates-to an id that is not in the result is refused"
prog record-behaviour --run "$RUN" --prompt "$P2" --when "$WORKER_DONE_WHEN" --do "stop" --relates-to "pnope"
check 1 "$CODE"

it "--from-proposal accepts --relates-to and runs the same check"
prog propose-behaviour --run "$RUN" --when "$WORKER_DONE_WHEN" --do "then stop; the PM closes the pane once you have stopped"
PB="$(jfield "$OUT" 'd["behaviour"]')"
P3="$(tprompt "$RUN" "apply $PB")"
prog record-behaviour --run "$RUN" --from-proposal "$PB" --prompt "$P3" --relates-to bc3f80d
check 0 "$CODE"
check "['bc3f80d']" "$(state "$RUN" "[b for b in prog['behaviours'] if b['id'] == '$PB'][0]['relates_to']")"
has "$BID" "$OUT"

it "the recorded entry's overrides and history are not changed by the check"
check "[]" "$(state "$RUN" "[b for b in prog['behaviours'] if b['id'] == '$BID'][0].get('overrides', [])")"
check "['recorded']" "$(state "$RUN" "[h['event'] for h in [b for b in prog['behaviours'] if b['id'] == '$BID'][0]['history']]")"

it "a do line naming a production deploy is still refused when recording"
prog record-behaviour --run "$RUN" --prompt "$P1" --when "a release is ready" --do "deploy to production"
check 1 "$CODE"
has 'protected_escalation' "$OUT"

it "check-behaviour prints each listed behaviour's lines"
prog check-behaviour --run "$RUN" --when "$WORKER_DONE_WHEN" --do "then stop; the PM closes the pane once you have stopped" \
  --dont "do not take new work outside your original remit"
CHECK_N="$(jfield "$OUT" 'd["unanswered"]')"
check "2" "$(jfield "$OUT" 'len([r for r in d["behaviours"] if r["ref"] == "bc3f80d"][0]["lines"]["do"])')"

it "record-behaviour leaves the lines out, marks an answered row, and lowers the unanswered count by one"
P4="$(tprompt "$RUN" "when a worker is finished, close its pane")"
prog record-behaviour --run "$RUN" --prompt "$P4" --when "$WORKER_DONE_WHEN" --do "then stop; the PM closes the pane once you have stopped" \
  --dont "do not take new work outside your original remit" --relates-to bc3f80d
check "False" "$(jfield "$OUT" '"lines" in [r for r in d["behaviours"] if r["ref"] == "bc3f80d"][0]')"
check "True" "$(jfield "$OUT" '[r for r in d["behaviours"] if r["ref"] == "bc3f80d"][0]["answered"]')"
check "$((CHECK_N - 1))" "$(jfield "$OUT" 'd["unanswered"]')"

it "check-behaviour changes no journal row"
BEFORE="$(state "$RUN" "len(pj.read(args[0]))")"
prog check-behaviour --run "$RUN" --when "a wholly unrelated moment" --do "water the plants"
check "$BEFORE" "$(state "$RUN" "len(pj.read(args[0]))")"

it "a refused --relates-to records no behaviour"
BEFORE="$(state "$RUN" "[len(prog['behaviours']), [r['kind'] for r in pj.read(args[0])].count('behaviour_recorded')]")"
prog record-behaviour --run "$RUN" --prompt "$P4" --when "a wholly unrelated moment" --do "water the plants" --relates-to pnope
check 1 "$CODE"
check "$BEFORE" "$(state "$RUN" "[len(prog['behaviours']), [r['kind'] for r in pj.read(args[0])].count('behaviour_recorded')]")"

it "describe lists check-behaviour as a read verb"
check "True" "$("$PY" -c 'import json,sys; print(json.load(sys.stdin)["verbs"]["check-behaviour"].get("reads"))' <<< "$("$PY" "$PROG" describe 2>/dev/null)")"

it "check-behaviour accepts --from-proposal and --conflicts-with, and refuses an unknown id"
prog propose-behaviour --run "$RUN" --when "$WORKER_DONE_WHEN" --do "then stop; the PM closes the pane once you have stopped"
PB2="$(jfield "$OUT" 'd["behaviour"]')"
prog check-behaviour --run "$RUN" --from-proposal "$PB2" --conflicts-with bc3f80d
check 0 "$CODE"
has "behaviour_checked" "$OUT"
prog check-behaviour --run "$RUN" --from-proposal "$PB2" --conflicts-with pnope
check 1 "$CODE"
prog check-behaviour --run "$RUN" --from-proposal pnope
check 1 "$CODE"

it "a do line touching an action the plugin default reserves lists an Authority row, flagged"
prog check-behaviour --run "$RUN" --when "a blocker sits in another team's repo" --do "fix other team code when it blocks us"
check "may_contradict" "$(jfield "$OUT" '[r for r in d["contract"] if r["ref"] == "authority:fix_other_team_code"][0]["flag"]')"

it "a dont line that forbids a skip does not flag the Done standard it agrees with"
OUT="$(py <<EOF
pcc = load_lib_module("programme_contract_check")
$SNAP
rows = {r["ref"]: r.get("flag") for r in pcc.check(beh("n1", dont=["skip verification when the change is small"]), snap)}
print(json.dumps(rows))
EOF
)"
has '"done:verified": null' "$OUT"

it "a contracted negation flags the tool it forbids; a clause negating another tool does not flag the one it endorses"
OUT="$(py <<EOF
pcc = load_lib_module("programme_contract_check")
$SNAP
snap["operating_contract"]["project_terms"] = [
    {"id": "t3", "area": "figma", "value": "Don't use figma for specs", "reserved": False},
    {"id": "t4", "area": "browser", "value": "Use agent-browser (never playwright)", "reserved": False}]
flags = lambda tool: {r["ref"]: r.get("flag") for r in pcc.check(beh("n1", tools=[tool]), snap)}
print(json.dumps([flags("figma"), flags("agent-browser"), flags("playwright")]))
EOF
)"
check '[{"tool:t3": "may_contradict"}, {"tool:t4": null}, {"tool:t4": "may_contradict"}]' "$OUT"

it "a tool of record the behaviour names gives a plain term row"
OUT="$(py <<EOF
pcc = load_lib_module("programme_contract_check")
$SNAP
print(json.dumps({r["ref"]: [r.get("flag"), r["reasons"][0]["reason"]] for r in pcc.check(beh("n1", tools=["tracker"]), snap)}))
EOF
)"
check '{"term:tools_of_record": [null, "names_tool"]}' "$OUT"

it "a stored relates_to or unrelated entry with the wrong shape is rejected as bad_value"
OUT="$(py <<'EOF'
good = beh("g1", relates_to=["bc3f80d", "term:cadence"], unrelated=[{"id": "ruling:r1", "reason": "different job"}])
bad = [beh("b1", relates_to=["Bad Id"]), beh("b2", relates_to="bc3f80d"), beh("b3", unrelated=[{"id": "x"}]),
       beh("b4", unrelated=[{"id": "x", "reason": " "}]), beh("b5", unrelated="x")]
print(pb.verdict(good, allow_adoption=False)["ok"], [pb.verdict(b, allow_adoption=False)["reason"] for b in bad])
EOF
)"
check "True ['bad_value', 'bad_value', 'bad_value', 'bad_value', 'bad_value']" "$OUT"

echo ""
echo "programme-behaviour-check.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
