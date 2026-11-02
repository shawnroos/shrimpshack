#!/usr/bin/env bash
# auto unit test: the PM's progress read of a contracted worker (contract-status), the done check that never
# trusts the worker's record, the quiet-sweep verdict, and the pulse guidance follow-ups (effective authority,
# PM answers read before the engine trims them).
#
# Every assertion pins a value and the presence of the key it reads. The status verb must make no pane call, so
# a fake herdr logs any call and the test asserts the log stays empty.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
PROG="${AUTO_ROOT}/lib/programme.py"
HOOK="${AUTO_ROOT}/.claude/hooks/on-pretooluse-subagent.sh"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
check() { if [ "$1" = "$2" ]; then pass; else fail "expected [$1] got [$2]"; fi; }
has() { case "$2" in *"$1"*) pass ;; *) fail "expected to find [$1] in [$2]" ;; esac; }
lacks() { case "$2" in *"$1"*) fail "did not expect [$1] in [$2]" ;; *) pass ;; esac; }

echo "worker-contract-status.test.sh"

WORK="$(mktemp -d -t auto-wc-status.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_AUTO_MACHINE="studio"
export CLAUDE_AUTO_TEST_HARNESS="1"
export CLAUDE_CODE_SESSION_ID="sess-pm"
unset HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_BIN_PATH HERDR_ENV CLAUDE_AUTO_REPO LINEAR_API_KEY 2>/dev/null || true
: > "$CLAUDE_AUTO_SECRETS_FILE"

FAKES="${WORK}/fakes"
CALLS="${WORK}/calls.log"
mkdir -p "$FAKES"
: > "$CALLS"
export CALLS
printf '#!/bin/bash\nprintf "herdr %%s\\n" "$*" >> "$CALLS"\nexit 1\n' > "${FAKES}/herdr"
printf '#!/bin/bash\nprintf "tmux %%s\\n" "$*" >> "$CALLS"\nexit 1\n' > "${FAKES}/tmux"
chmod +x "${FAKES}"/*
export PATH="${FAKES}:${PATH}"

REPO_A="${WORK}/repo-a"
mkdir -p "${REPO_A}/.claude/auto"
export REPO_A

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import datetime, json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
sys.path.insert(0, os.path.join(sys.argv[1], "tests", "helpers"))
from _bootstrap import load_lib_module
import contract_records as cr
from programme_records import edit as pedit
ph = load_lib_module("programme_home")
pj = load_lib_module("programme_journal")
core = load_lib_module("run_record_core")
wc = load_lib_module("worker_contract")
wq = load_lib_module("worker_question")
st = load_lib_module("worker_contract_status")
apply_mod = load_lib_module("worker_contract_apply")
REPO = os.environ["REPO_A"]
args = sys.argv[2:]
def rec(run):
    return core.read_run_record(REPO, run)
def rpath(run):
    return core.run_record_path(REPO, run)
$(cat)
PYEOF
}

RUN="$(run_py <<'EOF'
print(ph.create_programme(["w2"], "sess-pm")["run"])
EOF
)"

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

edit() {
  run_py "$RUN" "$1" "${2:-}" <<'EOF'
run, expr, extra = args
pedit(run, expr, {"X": extra, "REPO": REPO, "json": json})
EOF
}

mk() {
  run_py "$1" "$2" "$3" <<'EOF'
run, n, external = args
core.init_run_record(REPO, run, backend="ce", steps=[{"id": f"U{i}"} for i in range(1, int(n) + 1)], loop_phase="work")
if external != "none":
    bar = {"internal": ["steps_terminal"], "external": json.loads(external)}
    block = wc.new_contract(set_by="sess-pm", authority=cr.AUTHORITY, done_bar=bar, workflow="a2", fan_out_cap=2)
    core._with_locked_run_record(REPO, run, lambda r: r.__setitem__("contract", wc.validate(block)))
EOF
}

poke() {
  run_py "$1" "$2" <<'EOF'
run, patch = args
path = rpath(run)
before = os.stat(path)
doc = json.load(open(path))
doc.update(json.loads(patch))
json.dump(doc, open(path, "w"))
os.utime(path, ns=(before.st_atime_ns, before.st_mtime_ns))
EOF
}

why_of() {
  prog sweep-inputs --run "$RUN" "$@"
  jq_py 'd["why"]'
}

bound_to() {
  edit "items[\"$1\"][\"auto_run\"] = {\"state\": \"bound\", \"run_id\": X, \"path\": REPO, \"contract\": None}" "$2"
}

for n in 800:Done-claim 801:Hand-driven 802:No-block 803:Moved 804:Internal-only 806:Guidance 807:Unbound-guidance; do
  prog add-item "linear:AI-${n%%:*}" --title "${n#*:}" --run "$RUN"
done

mk w-claim 2 '["pr_merged"]'
mk w-plain 2 none
mk w-in 2 '[]'
mk w-ci 2 '["pr_merged", "ci_green"]'
bound_to linear:AI-800 w-claim
bound_to linear:AI-801 w-plain
bound_to linear:AI-803 w-gone
bound_to linear:AI-804 w-in
edit 'items["linear:AI-800"]["deliverables"] = {}' ""
poke w-claim '{"exit_predicate_result": {"met": true, "blockers": 7, "majors": 0, "minors": 0, "gaps_open": 0, "all_steps_terminal": true}}'
poke w-in '{"exit_predicate_result": {"met": true, "blockers": 0, "majors": 0, "minors": 0, "gaps_open": 0, "all_steps_terminal": true}}'

echo "── status reads the record, not the pane ──"

prog contract-status linear:AI-800 --run "$RUN"
it "status exits 0 and names the worker's contract state"
check '[0, "contract"]' "$(jq_py '[0, d["items"]["linear:AI-800"]["state"]]')"
it "the cached exit predicate comes back as stored (blockers 7 is not what a recompute of two pending steps gives)"
check '[true, 7]' "$(jq_py '[d["items"]["linear:AI-800"]["exit_predicate"]["met"], d["items"]["linear:AI-800"]["exit_predicate"]["blockers"]]')"
it "the record on disk still holds the cached value: the read did not recompute or write it"
check '7' "$(run_py w-claim <<'EOF'
print(json.load(open(rpath(args[0])))["exit_predicate_result"]["blockers"])
EOF
)"
it "status carries step counts, the last beat, and the contract version fields"
check '[2, "pending", true, 1, 0, true]' "$(jq_py '(lambda s: [s["steps"]["total"], list(s["steps"]["by_state"])[0], bool(s["last_beat_at"]), s["version"], s["applied_version"], s["stale"]])(d["items"]["linear:AI-800"])')"
it "pending versions list is present and empty before any change"
check '[]' "$(jq_py 'd["items"]["linear:AI-800"]["pending_versions"]')"
it "no pane was called"
check "" "$(cat "$CALLS")"

it "the applied version and stale state are computed at read time: a pending change reads stale"
run_py <<'EOF'
cr.request_change(REPO, "w-claim", "pulse")
EOF
prog contract-status linear:AI-800 --run "$RUN"
check '[2, 0, true, [{"bite": "pulse", "version": 2}]]' "$(jq_py '(lambda s: [s["version"], s["applied_version"], s["stale"], s["pending_versions"]])(d["items"]["linear:AI-800"])')"
run_py <<'EOF'
def settle(r):
    r["contract"]["applied_version"] = r["contract"]["version"]
    r["contract"]["pending_versions"] = []
core._with_locked_run_record(REPO, "w-claim", settle)
EOF
poke w-claim '{"exit_predicate_result": {"met": true, "blockers": 7, "majors": 0, "minors": 0, "gaps_open": 0, "all_steps_terminal": true}}'
prog contract-status linear:AI-800 --run "$RUN"
it "once the engine records the version as applied, the item reads not stale"
check '[2, 2, false]' "$(jq_py '(lambda s: [s["version"], s["applied_version"], s["stale"]])(d["items"]["linear:AI-800"])')"

echo "── AE3: a done claim is not evidence ──"

it "the predicate is met and the worker claims done, but the PR evidence is unconfirmed: the item does not count as done"
check '[true, false, ["pr_merged"], ["external_evidence_unverified"]]' "$(jq_py '(lambda s: [s["exit_predicate"]["met"], s["counts_as_done"], s["unverified_external"], s["done_blocked_by"]])(d["items"]["linear:AI-800"])')"
edit 'items["linear:AI-800"]["deliverables"]["merged"] = {"result": "refuted", "ref": "o/r#1"}' ""
prog contract-status linear:AI-800 --run "$RUN"
it "a refuted merged deliverable still leaves the evidence kind unverified"
check '[false, ["pr_merged"]]' "$(jq_py '(lambda s: [s["counts_as_done"], s["unverified_external"]])(d["items"]["linear:AI-800"])')"
edit 'items["linear:AI-800"]["deliverables"]["merged"] = {"result": "confirmed", "ref": "o/r#1"}' ""
prog contract-status linear:AI-800 --run "$RUN"
it "once the PM's own checker confirms the merge the item counts as done"
check '[true, [], []]' "$(jq_py '(lambda s: [s["counts_as_done"], s["unverified_external"], s["done_blocked_by"]])(d["items"]["linear:AI-800"])')"
poke w-claim '{"exit_predicate_result": {"met": false, "blockers": 1, "majors": 0, "minors": 0, "gaps_open": 0, "all_steps_terminal": false}}'
prog contract-status linear:AI-800 --run "$RUN"
it "confirmed evidence does not finish an item whose cached predicate is not met"
check '[false, ["exit_predicate_not_met"]]' "$(jq_py '(lambda s: [s["counts_as_done"], s["done_blocked_by"]])(d["items"]["linear:AI-800"])')"
prog contract-status linear:AI-804 --run "$RUN"
it "a done bar with no external kind counts as done on the cached predicate alone"
check '[true, []]' "$(jq_py '(lambda s: [s["counts_as_done"], s["unverified_external"]])(d["items"]["linear:AI-804"])')"
it "a kind the done bar names that nothing backs stays unverified; ci_green rides on the same merged deliverable"
check '[["pr_merged", "ci_green"]]' "$(run_py w-ci <<'EOF'
item = {"deliverables": {}}
print(json.dumps([st.unverified_external(item, rec("w-ci")["contract"])]))
EOF
)"

echo "── no contract and unresolvable ──"

prog contract-status linear:AI-802 --run "$RUN"
it "an item with no auto_run block reads 'no contract' and exits 0"
check '[0, "no contract", false]' "$(jq_py '[0, d["items"]["linear:AI-802"]["state"], d["items"]["linear:AI-802"]["counts_as_done"]]')"
prog contract-status linear:AI-801 --run "$RUN"
it "a hand-started bound run whose record has no contract reads 'no contract', not an error"
check '[0, "no contract", "w-plain"]' "$(jq_py '[0, d["items"]["linear:AI-801"]["state"], d["items"]["linear:AI-801"]["run_id"]]')"
prog contract-status linear:AI-803 --run "$RUN"
it "a missing record reads 'unresolvable' with its cause, never a crash"
check '[0, "unresolvable", false, true]' "$(jq_py '(lambda s: [0, s["state"], s["counts_as_done"], "RunRecord" in s["why"]])(d["items"]["linear:AI-803"])')"
mv "${REPO_A}" "${REPO_A}-moved"
prog contract-status linear:AI-804 --run "$RUN"
it "a record whose repo moved reads 'unresolvable'"
check '"unresolvable"' "$(jq_py 'd["items"]["linear:AI-804"]["state"]')"
mv "${REPO_A}-moved" "${REPO_A}"
it "neither case called a pane"
check "" "$(cat "$CALLS")"
prog contract-status --run "$RUN"
it "with no item argument the verb lists the items that have an auto_run block and no others"
check '["linear:AI-800", "linear:AI-801", "linear:AI-803", "linear:AI-804"]' "$(jq_py 'sorted(d["items"])')"
prog contract-status linear:AI-999 --run "$RUN"
it "an unknown item is a refusal, not a traceback"
check "1" "$CODE"
it "no verb crashed so far"
check "" "$CRASHES"

echo "── the verb is on the read list on purpose ──"

it "describe marks contract-status as a read verb"
prog describe
check 'true' "$(jq_py 'd["verbs"]["contract-status"]["reads"]')"
sub_decision() {
  "$PY" - "$1" <<'EOF' | CLAUDE_PLUGIN_ROOT="$AUTO_ROOT" bash "$HOOK" | "$PY" -c 'import json,sys; t=sys.stdin.read().strip(); print(json.loads(t)["hookSpecificOutput"]["permissionDecision"] if t else "allow")'
import json, sys
d = {"session_id": "sess-pm", "hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {"command": sys.argv[1]},
     "agent_id": "a1", "agent_type": "auto:programme-status-reader"}
print(json.dumps(d))
EOF
}
P='bash "/x/plugins/auto/lib/programme.sh"'
it "a sub-agent may read contract-status"
check allow "$(sub_decision "$P contract-status --run prog-1")"
it "a sub-agent still may not run a write verb"
check deny "$(sub_decision "$P mark-read 3 --run prog-1")"

echo "── the quiet sweep ──"

edit 'for i in items.values(): i["state"] = "dropped"' ""
prog watcher-beat remit --process-id $$ --run "$RUN"
prog watcher-beat cron --task-id c1 --kind cron --prompt sweep --run "$RUN"
prog set-now idle --run "$RUN"
prog sweep-inputs --save --run "$RUN"
it "the first look at a contracted item reads contract_changed and commits what it saw"
has "contract_changed" "$(jq_py 'd["why"]')"
SEEN="$(find "${CLAUDE_AUTO_DATA_DIR}" -name contract-seen.json | head -1)"
it "the committed look is a file in the programme home"
check "1" "$(test -f "$SEEN" && echo 1 || echo 0)"
it "the committed look holds a fingerprint with state and version for each contracted item, and none for a hand-driven one"
check '[["linear:AI-800", "linear:AI-803", "linear:AI-804"], 2, "contract"]' "$("$PY" -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps([sorted(d), d["linear:AI-800"]["version"], d["linear:AI-800"]["state"]]))' "$SEEN")"
it "a repeat sweep with no change in version, beat, mtime or questions adds no contract reason and reads unchanged"
check '[]' "$(why_of)"
prog sweep-inputs --run "$RUN"
it "the verdict itself is unchanged"
check '"unchanged"' "$(jq_py 'd["verdict"]')"
it "the changed list is present and empty"
check '[]' "$(jq_py 'd["contracts"]["changed"]')"

run_py <<'EOF'
os.utime(rpath("w-in"), ns=(1, 1))
EOF
it "a changed record mtime alone wakes the sweep"
check '["contract_changed"]' "$(why_of)"
prog sweep-inputs --run "$RUN"
it "the changed list names the item"
check '["linear:AI-804"]' "$(jq_py 'd["contracts"]["changed"]')"
prog sweep-inputs --save --run "$RUN"
it "after the look is committed the same state reads quiet again"
check '[]' "$(why_of)"

poke w-in '{"loop": {"driver": "self", "last_beat_at": "2030-01-01T00:00:00Z"}}'
it "a new last beat alone wakes the sweep (mtime pinned)"
check '["contract_changed"]' "$(why_of)"
prog sweep-inputs --save --run "$RUN"

run_py <<'EOF'
path = rpath("w-in")
before = os.stat(path)
doc = json.load(open(path))
doc["contract"]["version"] += 1
json.dump(doc, open(path, "w"))
os.utime(path, ns=(before.st_atime_ns, before.st_mtime_ns))
EOF
it "a new contract version alone wakes the sweep (mtime and beat pinned)"
check '["contract_changed"]' "$(why_of)"
prog sweep-inputs --save --run "$RUN"
it "and reads quiet once committed"
check '[]' "$(why_of)"

echo "── worker questions wake the sweep ──"

run_py "$RUN" <<'EOF'
asked = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=2)
worker = {"run_id": "w-in", "session_id": "sess-worker", "repo": REPO}
parsed = {"text": "Should the export also support CSV", "options": ["yes", "no"]}
decision = {"route": "pm", "kind": "product_scope", "label": None, "mode": "propose", "asks": "pm",
            "safe_default": False, "reason": "authority"}
wq.record_question(args[0], "linear:AI-804", worker, parsed, decision, now=asked)
EOF
QID="$(run_py "$RUN" <<'EOF'
print(wq.open_questions(args[0])[0]["qid"])
EOF
)"
prog sweep-inputs --save --run "$RUN"
it "a new open question changes the contracted item's look and arrives as an unread claim"
has "contract_changed" "$(jq_py 'd["why"]')"
NEXT="$(jq_py 'd["next_offset"]' | tr -d '"')"
prog mark-read --offset "$NEXT" --run "$RUN"
prog set-now idle --run "$RUN"
it "with version, beat and mtime unchanged and the claim read, a question past its limit still wakes the sweep"
check '["worker_question_due"]' "$(why_of)"
prog sweep-inputs --run "$RUN"
it "the contract look is unchanged, so the wake comes from the limit alone"
check '[]' "$(jq_py 'd["contracts"]["changed"]')"
it "the due list names the question and the status shows its count and past-limit flag"
check "[[\"${QID}\"], 1, true]" "$(jq_py '[d["contracts"]["due"], d["contracts"]["items"]["linear:AI-804"]["open_questions"], d["contracts"]["fingerprints"]["linear:AI-804"]["open"] == 1 and True]')"
prog contract-status linear:AI-804 --run "$RUN"
it "contract-status reports the open count, the oldest question's time and its age"
check '[1, true, true]' "$(jq_py '(lambda q: [q["open"], bool(q["oldest_at"]), q["oldest_age_seconds"] > 3600])(d["items"]["linear:AI-804"]["questions"])')"
run_py "$RUN" "$QID" <<'EOF'
pj.append(args[0], wq.ESCALATED_KIND, "sess-pm", {"qid": args[1], "item": "linear:AI-804", "joined": False})
EOF
prog set-now idle --run "$RUN"
it "once the question is escalated it stops waking the sweep"
check '[]' "$(why_of)"

echo "── pulse guidance: effective authority and PM answers ──"

mk pg 1 '[]'
mk pg-free 1 '[]'
bound_to linear:AI-806 pg
run_py <<'EOF'
def add(r):
    wq.append_pending(r["contract"], bite="pulse", set_by="sess-pm",
                      extra={"answer": {"question_id": "qabc123", "text": "use the wrapper", "by": "pm"}})
    wc.validate(r["contract"])
core._with_locked_run_record(REPO, "pg", add)
core._with_locked_run_record(REPO, "pg-free", lambda r: wq.append_pending(
    r["contract"], bite="pulse", set_by="sess-pm", extra={"answer": {"question_id": "qfree99", "text": "free answer", "by": "pm"}}))
EOF
it "the extras read before the pulse carry the pending PM answer"
check '[["qabc123"], true]' "$(run_py <<'EOF'
ex = st.guidance_extras(REPO, "pg", rec("pg"))
print(json.dumps([[a["question_id"] for a in ex["answers"]], "effective" in ex]))
EOF
)"
OUT="$(run_py <<'EOF'
pulse = load_lib_module("pulse")
r = pulse.dispatch_pulse(REPO, "pg")
c = rec("pg")["contract"]
print(json.dumps({"guidance": r["operator_guidance"], "pending": c["pending_versions"], "applied": c["applied_version"],
                  "version": c["version"]}, sort_keys=True))
EOF
)"
it "the pulse shows the PM's answer in the guidance before the engine trims the entry"
has "PM answer to question qabc123: use the wrapper" "$OUT"
it "the engine still applied and trimmed the entry"
has '"pending": []' "$OUT"
it "the guidance shows EFFECTIVE authority: a protected kind reads never, asks shawn, whatever the contract stores"
has "Effective authority:" "$OUT"
has "prod_deploy=never (asks shawn)" "$OUT"
OUT="$(run_py <<'EOF'
pulse = load_lib_module("pulse")
r = pulse.dispatch_pulse(REPO, "pg")
print(r["operator_guidance"])
EOF
)"
it "the answer is shown once: the next pulse's guidance does not repeat it"
lacks "PM answer to question" "$OUT"
OUT="$(run_py <<'EOF'
pulse = load_lib_module("pulse")
r = pulse.dispatch_pulse(REPO, "pg-free")
print(r["operator_guidance"])
EOF
)"
it "a run no programme item is bound to still shows the answer and falls back to the stored authority"
has "PM answer to question qfree99: free answer" "$OUT"
has "Authority: " "$OUT"
lacks "Effective authority" "$OUT"
it "a run with no contract gets neither"
check "False" "$(run_py <<'EOF'
mk = core.init_run_record(REPO, "plain-run", backend="ce", steps=[{"id": "U1"}], loop_phase="work")
pulse = load_lib_module("pulse")
r = pulse.dispatch_pulse(REPO, "plain-run")
print("PM CONTRACT" in (r.get("operator_guidance") or ""))
EOF
)"

echo "── driver skill and docs ──"

it "the driver skill tells the driver to pass repo_root and to register a programme worker's run"
has "register-run" "$(tr -s ' \n' ' ' < "${AUTO_ROOT}/skills/auto/SKILL.md")"
has "Pass \`repo_root=\`" "$(tr -s ' \n' ' ' < "${AUTO_ROOT}/skills/auto/SKILL.md")"
it "the sweep skill points to the contract-progress reference, which names the verb"
has "references/worker-contracts.md" "$(cat "${AUTO_ROOT}/skills/programme-sweep/SKILL.md")"
has "P contract-status" "$(cat "${AUTO_ROOT}/skills/programme-sweep/references/worker-contracts.md")"
it "the verb is documented in the tool-surface contract"
has "**Contract status**: \`contract-status\`" "$(cat "${AUTO_ROOT}/docs/contracts/agent-tool-surface.md")"
it "the new module is under the file size budget"
check "1" "$([ "$(wc -l < "${AUTO_ROOT}/lib/worker_contract_status.py")" -lt 1000 ] && echo 1 || echo 0)"
it "no verb crashed in the whole run"
check "" "$CRASHES"

echo "worker-contract-status.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
