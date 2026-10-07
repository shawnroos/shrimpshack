#!/usr/bin/env bash
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

echo "programme-verbs.test.sh"

WORK="$(mktemp -d -t auto-programme-verbs.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_MACHINE="studio"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_CODE_SESSION_ID="sess-pm"
unset HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH CLAUDE_AUTO_REPO 2>/dev/null || true
printf 'export DEMO_TOKEN=hunter2secretvalue\n' > "$CLAUDE_AUTO_SECRETS_FILE"

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
ph = load_lib_module("programme_home")
pj = load_lib_module("programme_journal")
core = load_lib_module("run_record_core")
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
HOME_DIR="${CLAUDE_AUTO_DATA_DIR}/programmes/${RUN}"

prompt() {
  run_py "$RUN" "$1" "$2" <<'EOF'
run, origin, text = args
print(pj.append_prompt(run, "sess-pm", text, origin)["prompt_id"])
EOF
}

field() {
  run_py "$RUN" "$1" <<'EOF'
run, expr = args
rec = record(run)
prog = rec["programme"]
print(json.dumps(eval(expr), sort_keys=True))
EOF
}

edit() {
  run_py "$RUN" "$1" <<'EOF'
run, expr = args
home = ph.home_path(run)
path = core.run_record_path(home, run)
with open(path) as fh:
    rec = json.load(fh)
exec(expr)
with open(path, "w") as fh:
    json.dump(rec, fh)
EOF
}

journal_kinds() {
  run_py "$RUN" <<'EOF'
print(" ".join(row["kind"] for row in pj.read(args[0])))
EOF
}

OUT=""
CODE=0
prog() {
  OUT="$("$PY" "$PROG" "$@" 2>&1)"
  CODE=$?
}

it "describe lists exactly the programme verbs"
DESC="$("$PY" "$PROG" describe 2>/dev/null)"
VERBS="$("$PY" -c 'import json,sys; print(" ".join(sorted(json.load(sys.stdin)["verbs"])))' <<< "$DESC" 2>&1)"
check "accept-agreement add-item adopt-autonomy adopt-check adopt-rule alias-item amend-term answer-handed beat check-deliverable claim close-instruction describe drop-item end expire hand-item handover mark-read merge-item prompt-item propose-agreement propose-rule queue record-instruction record-tested-build reopen-item rules set-now set-source set-waiting start start-worker status sweep takeover validate watcher-beat" "$VERBS"

P_TYPED="$(prompt typed 'stop rule: only when done, stop only when everything is done')"
P_CRON="$(prompt cron 'wake up and sweep the space')"

it "amend-term with an unknown prompt id is refused"
prog amend-term stop_rule only_when_done --prompt p000000
check 1 "$CODE"
it "the unknown-prompt refusal writes nothing"
check '"nothing_it_can_act_on"' "$(field 'prog["agreement"]["terms"]["stop_rule"]["value"]')"
it "the unknown-prompt refusal journals nothing"
lacks term_amended "$(journal_kinds)"

it "amend-term citing a cron prompt is refused"
prog amend-term stop_rule only_when_done --prompt "$P_CRON"
check 1 "$CODE"
has "typed" "$OUT"

P_OTHER="$(run_py "$RUN" <<'EOF'
print(pj.append_prompt(args[0], "sess-other", "stop only when done", "typed")["prompt_id"])
EOF
)"
it "amend-term citing a typed prompt from another session is refused"
prog amend-term stop_rule only_when_done --prompt "$P_OTHER"
check 1 "$CODE"
has "driving session" "$OUT"

it "amend-term from a stranger session is refused"
CLAUDE_CODE_SESSION_ID="sess-stranger" prog amend-term stop_rule only_when_done --prompt "$P_TYPED" --run "$RUN"
check 1 "$CODE"

it "amend-term from a sub-agent session in agent_session_ids is refused"
edit 'rec["agent_session_ids"] = ["sess-sub"]'
CLAUDE_CODE_SESSION_ID="sess-sub" prog amend-term stop_rule only_when_done --prompt "$P_TYPED" --run "$RUN"
check 1 "$CODE"
it "the refused callers left the term unchanged"
check '"nothing_it_can_act_on"' "$(field 'prog["agreement"]["terms"]["stop_rule"]["value"]')"

it "amend-term citing a typed prompt that does not name the new value is refused"
P_VAGUE="$(prompt typed 'change the stop rule')"
prog amend-term stop_rule only_when_done --prompt "$P_VAGUE"
check 1 "$CODE"
has "only_when_done" "$OUT"
it "amend-term citing a typed prompt that does not name the term is refused"
prog amend-term stop_rule only_when_done --prompt "$(prompt typed 'only when done please')"
check 1 "$CODE"
has "stop_rule" "$OUT"
check '"nothing_it_can_act_on"' "$(field 'prog["agreement"]["terms"]["stop_rule"]["value"]')"

it "amend-term with a typed prompt changes the term"
prog amend-term stop_rule only_when_done --prompt "$P_TYPED" --why "the argument wording"
check 0 "$CODE"
check '"only_when_done"' "$(field 'prog["agreement"]["terms"]["stop_rule"]["value"]')"
it "the term records the quote from the journal, not the argument"
check '"stop rule: only when done, stop only when everything is done"' "$(field 'prog["agreement"]["terms"]["stop_rule"]["quote"]')"
it "the journal entry quotes the prompt and cites it"
GOT="$(run_py "$RUN" "$P_TYPED" <<'EOF'
run, pid = args
row = [r for r in pj.read(run) if r["kind"] == "term_amended"][-1]
print(row["payload"]["quote"] + "|" + ",".join(row.get("cites") or []))
EOF
)"
check "stop rule: only when done, stop only when everything is done|${P_TYPED}" "$GOT"

it "the cited prompt survives pruning while the uncited cron prompt goes"
GOT="$(run_py "$RUN" "$P_TYPED" "$P_CRON" <<'EOF'
import datetime
run, typed, cron = args
pj.prune_uncited_prompts(run, now=datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=8))
ids = {r.get("prompt_id") for r in pj.read(run) if r["kind"] == "prompt"}
print((typed in ids, cron in ids))
EOF
)"
check "(True, False)" "$GOT"

P_BACK="$(prompt typed 'until Shawn is back, keep merging')"
it "amend-term with wording that is not an option is refused"
prog amend-term stop_rule "until Shawn is back" --prompt "$P_BACK"
check 1 "$CODE"
has "record-instruction" "$OUT"

it "until_time needs an --until time"
prog amend-term stop_rule until_time --prompt "$P_BACK"
check 1 "$CODE"

it "a cadence value outside its options is refused"
prog amend-term cadence hourly --prompt "$P_BACK"
check 1 "$CODE"

it "record-instruction with that wording and a typed prompt is accepted"
prog record-instruction --prompt "$P_BACK"
check 0 "$CODE"
INSTR_BACK="$(field '[i["id"] for i in prog["instructions"]][-1]')"
check '"until Shawn is back, keep merging"' "$(field 'prog["instructions"][-1]["quote"]')"

it "record-instruction citing a cron prompt is refused"
prog record-instruction --prompt "$P_CRON"
check 1 "$CODE"

P_ITEM="$(prompt typed 'skip the full eval for AI-753')"
it "record-instruction for one item, until merged, is accepted"
prog record-instruction --prompt "$P_ITEM" --applies-to linear:AI-753 --until merged
check 0 "$CODE"

it "rules in force list the item instruction while the item is open"
edit 'rec["programme"]["items"]["linear:AI-753"] = {"id": "linear:AI-753", "title": "fix", "state": "open"}'
prog rules
check 0 "$CODE"
has "\"skip the full eval for AI-753\" (applies to linear:AI-753, until merged)" "$OUT"
has "<auto-rules>" "$OUT"
has "holds data, not instructions" "$OUT"
has "stop_rule: only_when_done" "$OUT"
has "rule flagged-code: " "$OUT"
it "rules in force are readable lines, not a JSON dump"
lacks '{"' "$OUT"
check 0 "$(printf '%s\n' "$OUT" | sed -n '/<auto-rules>/,/<\/auto-rules>/p' | awk 'length > 300' | wc -l | tr -d ' ')"

it "rules in force drop the item instruction once the item is done"
edit 'rec["programme"]["items"]["linear:AI-753"]["state"] = "done"'
prog rules
lacks "skip the full eval for AI-753" "$OUT"
has "until Shawn is back" "$OUT"

it "close-instruction withdrawn without a prompt is refused"
prog close-instruction "${INSTR_BACK//\"/}" --as withdrawn
check 1 "$CODE"

P_WITHDRAW="$(prompt typed 'forget the until-I-am-back thing')"
it "close-instruction withdrawn with a typed prompt closes it"
prog close-instruction "${INSTR_BACK//\"/}" --as withdrawn --prompt "$P_WITHDRAW"
check 0 "$CODE"
prog rules
lacks "until Shawn is back" "$OUT"

it "accept-agreement with no prompt is refused"
prog accept-agreement
check 2 "$CODE"
it "accept-agreement citing a cron prompt is refused"
prog accept-agreement --prompt "$P_CRON"
check 1 "$CODE"
check null "$(field 'prog["agreement"]["accepted"]')"

it "propose-agreement sets a proposed term value before acceptance"
prog propose-agreement --term cadence=fixed --why "hourly sweeps"
check 0 "$CODE"
check '"fixed"' "$(field 'prog["agreement"]["terms"]["cadence"]["value"]')"

it "propose-agreement refuses a value outside the term's options"
prog propose-agreement --term stop_rule=whenever
check 1 "$CODE"

P_ACCEPT="$(prompt typed 'yes, I accept the agreement')"
it "accept-agreement with a typed prompt records the acceptance"
prog accept-agreement --prompt "$P_ACCEPT"
check 0 "$CODE"
check "\"${P_ACCEPT}\"" "$(field 'prog["agreement"]["accepted"]["prompt_id"]')"
check '"yes, I accept the agreement"' "$(field 'prog["agreement"]["accepted"]["quote"]')"

it "propose-agreement is refused once the agreement is accepted"
prog propose-agreement --term cadence=on_change
check 1 "$CODE"

touch "${HOME_DIR}/.compact-flag"
P_AFTER="$(prompt typed 'stop rule never_stop, keep going')"
it "a write verb is refused while the compact flag is set"
prog amend-term stop_rule never_stop --prompt "$P_AFTER"
check 1 "$CODE"
it "the refusal prints the rules-in-force block"
has "<auto-rules" "$OUT"
has "only_when_done" "$OUT"
check '"only_when_done"' "$(field 'prog["agreement"]["terms"]["stop_rule"]["value"]')"

it "rules --ack from a stranger session is refused"
CLAUDE_CODE_SESSION_ID="sess-stranger" prog rules --ack --run "$RUN"
check 1 "$CODE"
check yes "$([ -e "${HOME_DIR}/.compact-flag" ] && echo yes || echo no)"

it "rules --ack clears the compact flag"
prog rules --ack
check 0 "$CODE"
check no "$([ -e "${HOME_DIR}/.compact-flag" ] && echo yes || echo no)"

it "after rules --ack the write verb is accepted"
prog amend-term stop_rule never_stop --prompt "$P_AFTER"
check 0 "$CODE"
check '"never_stop"' "$(field 'prog["agreement"]["terms"]["stop_rule"]["value"]')"

RULE_JSON='{"id":"docs-verified","applies_when":{"change_kinds":["evals_or_docs"]},"requires":["merged"],"evidence_bar":{"merged":"merged at the gate"},"caveat":"","autonomy":"act_and_tell","added_by":"pm","added_at":"2026-10-06T10:00:00Z","why":"docs need a merge"}'

it "propose-rule refuses a rule missing a required field"
prog propose-rule '{"id":"half-rule"}'
check 1 "$CODE"

it "propose-rule records a valid proposal"
prog propose-rule "$RULE_JSON"
check 0 "$CODE"
check '["docs-verified"]' "$(field '[r["id"] for r in prog["proposed_rules"]]')"

it "adopt-rule citing a cron prompt is refused and writes no personal file"
prog adopt-rule docs-verified --prompt "$P_CRON"
check 1 "$CODE"
check no "$([ -e "$CLAUDE_AUTO_PERSONAL_PROTOCOL" ] && echo yes || echo no)"

it "adopt-rule citing a typed prompt that does not name the rule is refused"
prog adopt-rule docs-verified --prompt "$(prompt typed 'yes, adopt that rule')"
check 1 "$CODE"
has "docs-verified" "$OUT"
check no "$([ -e "$CLAUDE_AUTO_PERSONAL_PROTOCOL" ] && echo yes || echo no)"

P_ADOPT="$(prompt typed 'yes adopt docs-verified, token hunter2secretvalue')"
it "adopt-rule with a typed prompt writes the personal file"
prog adopt-rule docs-verified --prompt "$P_ADOPT"
check 0 "$CODE"
check yes "$([ -f "$CLAUDE_AUTO_PERSONAL_PROTOCOL" ] && echo yes || echo no)"

it "the adopted rule carries a redacted quote, the machine and a content hash"
GOT="$(run_py "$RUN" "$P_ADOPT" <<'EOF'
run, pid = args
pp = load_lib_module("programme_protocol")
with open(os.environ["CLAUDE_AUTO_PERSONAL_PROTOCOL"]) as fh:
    doc = json.load(fh)
rule = [r for r in doc["rules"] if r["id"] == "docs-verified"][0]
a = rule["adoption"]
print("hunter2" in a["quote"], "[redacted]" in a["quote"], a["machine"], a["hash"] == pp.content_hash(rule), a["prompt_id"] == pid, a["run_id"] == run)
EOF
)"
check "False True studio True True True" "$GOT"

it "the personal file write left no temp file behind"
check "protocol.json" "$(ls -A "$(dirname "$CLAUDE_AUTO_PERSONAL_PROTOCOL")" | tr '\n' ' ' | sed 's/ $//')"

it "the adopted rule loads from the personal layer with the journal lookup"
GOT="$(run_py <<'EOF'
prog = load_lib_module("programme")
pp = load_lib_module("programme_protocol")
loaded = pp.load(prompt_lookup=prog.prompt_lookup)
rule = loaded["rules"].get("docs-verified")
print(rule and rule["layer"], [r["id"] for r in loaded["rejected"]])
EOF
)"
check "personal []" "$GOT"

it "adopt-rule removes the proposal and rules in force list the rule"
check '[]' "$(field '[r["id"] for r in prog["proposed_rules"]]')"
prog rules
has "docs-verified" "$OUT"

it "adopt-rule for an id with no proposal is refused"
prog adopt-rule no-such-rule --prompt "$P_ADOPT"
check 1 "$CODE"

load_personal() {
  run_py "$1" <<'EOF'
prog = load_lib_module("programme")
pp = load_lib_module("programme_protocol")
loaded = pp.load(prompt_lookup=prog.prompt_lookup)
print(json.dumps(eval(args[0]), sort_keys=True))
EOF
}

personal_doc() {
  run_py "$1" <<'EOF'
path = os.environ["CLAUDE_AUTO_PERSONAL_PROTOCOL"]
with open(path) as fh:
    doc = json.load(fh)
exec(args[0])
with open(path, "w") as fh:
    json.dump(doc, fh)
EOF
}

it "adopt-autonomy without a typed prompt is refused and writes nothing"
BEFORE="$(cat "$CLAUDE_AUTO_PERSONAL_PROTOCOL")"
prog adopt-autonomy prod_deploy never --prompt "$P_CRON"
check "1" "$CODE"
check "$BEFORE" "$(cat "$CLAUDE_AUTO_PERSONAL_PROTOCOL")"
prog adopt-autonomy prod_deploy never
check "1" "$CODE"

it "adopt-autonomy refuses an unknown level and a bad action"
P_AUTO="$(prompt typed 'yes, set prod deploy to never')"
prog adopt-autonomy prod_deploy sometimes --prompt "$P_AUTO"
check "1" "$CODE"
prog adopt-autonomy 'Bad Action' never --prompt "$P_AUTO"
check "1" "$CODE"

it "adopt-autonomy citing a typed prompt that does not name the action and level is refused"
prog adopt-autonomy prod_deploy never --prompt "$(prompt typed 'yes, never deploy prod')"
check 1 "$CODE"
has "prod_deploy" "$OUT"
prog adopt-autonomy prod_deploy never --prompt "$(prompt typed 'yes, prod_deploy')"
check 1 "$CODE"
has "never" "$OUT"

it "adopt-autonomy narrowing a level loads from the personal layer"
prog adopt-autonomy prod_deploy never --prompt "$P_AUTO"
check "0" "$CODE"
check '["never", "personal", []]' "$(load_personal '[loaded["autonomy"]["prod_deploy"]["level"], loaded["autonomy"]["prod_deploy"]["layer"], [r["id"] for r in loaded["rejected"]]]')"

it "adopt-autonomy journals an approval record with entry kind and hash"
GOT="$(run_py "$RUN" "$P_AUTO" <<'EOF'
run, pid = args
pp = load_lib_module("programme_protocol")
row = [r for r in pj.read(run) if r["kind"] == "rule_adopted"][-1]
doc = json.load(open(os.environ["CLAUDE_AUTO_PERSONAL_PROTOCOL"]))
entry = doc["autonomy"]["prod_deploy"]
p = row["payload"]
print(p["entry"], p["action"], p["level"], p["hash"] == entry["adoption"]["hash"] == pp.content_hash(entry), row["cites"] == [pid], p["prompt_id"] == pid)
EOF
)"
check "autonomy prod_deploy never True True True" "$GOT"

it "adopt-autonomy widening a level without --widening is refused and writes nothing"
BEFORE="$(cat "$CLAUDE_AUTO_PERSONAL_PROTOCOL")"
prog adopt-autonomy merge_around_gate act --prompt "$(prompt typed 'widen merge around gate to act')"
check "1" "$CODE"
has "--widening" "$OUT"
check "$BEFORE" "$(cat "$CLAUDE_AUTO_PERSONAL_PROTOCOL")"

it "adopt-autonomy --widening citing a prompt without the word widen is refused"
prog adopt-autonomy merge_around_gate act --widening --prompt "$(prompt typed 'merge around gate: act')"
check 1 "$CODE"
has "widen" "$OUT"

it "adopt-autonomy widening with --widening loads"
prog adopt-autonomy merge_around_gate act --widening --prompt "$(prompt typed 'yes, widen merge_around_gate to act')"
check "0" "$CODE"
check '["act", "personal"]' "$(load_personal '[loaded["autonomy"]["merge_around_gate"][k] for k in ("level", "layer")]')"

it "an autonomy entry written by hand with a recomputed hash does not load"
personal_doc '
pp = load_lib_module("programme_protocol")
forged = {"level": "act"}
adoption = dict(doc["autonomy"]["prod_deploy"]["adoption"])
adoption["hash"] = pp.content_hash(forged)
adoption["widening"] = True
forged["adoption"] = adoption
doc["autonomy"]["full_release"] = forged
'
check '["propose", "plugin", [["full_release", "adoption_unverified"]]]' "$(load_personal '[loaded["autonomy"]["full_release"]["level"], loaded["autonomy"]["full_release"]["layer"], [[r["id"], r["reason"]] for r in loaded["rejected"]]]')"
personal_doc 'del doc["autonomy"]["full_release"]'

LOOKUP_ARGV='["trace-cli","show","{id}"]'
it "adopt-check without a typed prompt is refused"
prog adopt-check acme/web verified.lookup "$LOOKUP_ARGV" --prompt "$P_CRON"
check "1" "$CODE"

it "adopt-check refuses an unknown check key, a bad argv and an unknown placeholder"
P_CHECK="$(prompt typed 'yes, adopt the verified lookup for acme/web')"
prog adopt-check acme/web verified.other "$LOOKUP_ARGV" --prompt "$P_CHECK"
check "1" "$CODE"
prog adopt-check acme/web verified.lookup '[]' --prompt "$P_CHECK"
check "1" "$CODE"
prog adopt-check acme/web verified.lookup '["trace-cli","{token}"]' --prompt "$P_CHECK"
check "1" "$CODE"
prog adopt-check acme/web verified.lookup 'not json' --prompt "$P_CHECK"
check "1" "$CODE"

it "adopt-check citing a typed prompt that does not name the check or the repo is refused"
prog adopt-check acme/web verified.lookup "$LOOKUP_ARGV" --prompt "$(prompt typed 'yes, adopt the trace lookup for acme/web')"
check 1 "$CODE"
has "verified.lookup" "$OUT"
prog adopt-check acme/web verified.lookup "$LOOKUP_ARGV" --prompt "$(prompt typed 'yes, adopt verified.lookup')"
check 1 "$CODE"
has "acme/web" "$OUT"
check '[]' "$(load_personal 'sorted(loaded["checks"])')"

it "adopt-check writes the check under its repo and it loads"
prog adopt-check acme/web verified.lookup "$LOOKUP_ARGV" --prompt "$P_CHECK"
check "0" "$CODE"
check '[["trace-cli", "show", "{id}"], "personal", []]' "$(load_personal '[loaded["checks"]["acme/web"]["verified.lookup"][k] for k in ("argv", "layer")] + [[r["id"] for r in loaded["rejected"]]]')"

it "adopt-check journals an approval record with entry kind, repo, check and hash"
GOT="$(run_py "$RUN" "$P_CHECK" <<'EOF'
run, pid = args
row = [r for r in pj.read(run) if r["kind"] == "rule_adopted"][-1]
doc = json.load(open(os.environ["CLAUDE_AUTO_PERSONAL_PROTOCOL"]))
p = row["payload"]
print(p["entry"], p["repo"], p["check"], p["hash"] == doc["checks"]["acme/web"]["verified.lookup"]["adoption"]["hash"], row["cites"] == [pid])
EOF
)"
check "check acme/web verified.lookup True True" "$GOT"

it "an adopted check whose argv is edited afterwards does not load"
personal_doc 'doc["checks"]["acme/web"]["verified.lookup"]["argv"] = ["evil", "{id}"]'
check '[false, [["acme/web:verified.lookup", "adoption_unverified"]]]' "$(load_personal '["verified.lookup" in loaded["checks"].get("acme/web", {}), [[r["id"], r["reason"]] for r in loaded["rejected"]]]')"
personal_doc 'doc["checks"]["acme/web"]["verified.lookup"]["argv"] = ["trace-cli", "show", "{id}"]'

it "a check under a new repo with a recomputed hash and a real prompt does not load"
personal_doc '
pp = load_lib_module("programme_protocol")
entry = {"argv": ["evil-cli", "{id}"]}
adoption = dict(doc["checks"]["acme/web"]["verified.lookup"]["adoption"])
adoption["hash"] = pp.content_hash(entry)
entry["adoption"] = adoption
doc["checks"]["acme/api"] = {"verified.lookup": entry}
'
check '[false, [["acme/api:verified.lookup", "adoption_unverified"]]]' "$(load_personal '["acme/api" in loaded["checks"], [[r["id"], r["reason"]] for r in loaded["rejected"]]]')"
personal_doc 'del doc["checks"]["acme/api"]'

it "the personal file keeps the adopted rule, autonomy entries and check together"
check '[["docs-verified"], ["merge_around_gate", "prod_deploy"], ["acme/web"]]' "$(load_personal '[sorted(r for r, v in loaded["rules"].items() if v["layer"] == "personal"), sorted(a for a, v in loaded["autonomy"].items() if v["layer"] == "personal"), sorted(loaded["checks"])]')"

it "each approval journals its own kind"
GOT="$(journal_kinds)"
for kind in term_amended instruction_recorded instruction_closed agreement_proposed agreement_accepted rule_proposed rule_adopted rules_acked; do
  case "$GOT" in *"$kind"*) : ;; *) GOT="missing:${kind}" ;; esac
done
lacks "missing:" "$GOT"

it "status shows a personal rule and autonomy entry adopted on another machine as adopted there"
personal_doc '
pp = load_lib_module("programme_protocol")
rule = dict(doc["rules"][0])
rule.update(id="laptop-docs", autonomy="propose")
rule.pop("adoption")
gate = {"level": "propose"}
for entry in (rule, gate):
    entry["adoption"] = dict(doc["rules"][0]["adoption"], machine="laptop", hash=pp.content_hash(entry))
doc["rules"].append(rule)
doc["autonomy"]["merge_at_gate"] = gate
'
prog status
has "rule laptop-docs: propose, requires merged, adopted on laptop" "$OUT"
has "autonomy merge_at_gate: propose, adopted on laptop" "$OUT"
lacks "docs-verified: act_and_tell, requires merged, adopted on" "$OUT"
personal_doc 'doc["rules"] = [r for r in doc["rules"] if r["id"] != "laptop-docs"]; del doc["autonomy"]["merge_at_gate"]'

it "rules without --run and with no lease for the session is refused"
CLAUDE_CODE_SESSION_ID="sess-nobody" prog rules
check 1 "$CODE"
has "--run" "$OUT"

it "an unknown verb exits 2 and points at describe"
prog no-such-verb
check 2 "$CODE"
has "describe" "$OUT"

echo ""
echo "programme-verbs.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
