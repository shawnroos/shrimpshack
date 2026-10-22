#!/usr/bin/env bash
# Scoped decisions and requirement-linked acceptance (U3): every scenario runs through
# the programme CLI, `status --json`, and the Stop hook's decide().
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

echo "programme-context.test.sh"

WORK="$(mktemp -d -t auto-programme-context.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_MACHINE="studio"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_CODE_SESSION_ID="sess-pm"
export CLAUDE_AUTO_TEST_HARNESS=1
export CLAUDE_AUTO_SPINOFF_TIMEOUT=2
unset HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_BIN_PATH CLAUDE_AUTO_REPO 2>/dev/null || true
: > "$CLAUDE_AUTO_SECRETS_FILE"

FAKES="${WORK}/fakes"
CALLS="${WORK}/calls.log"
mkdir -p "$FAKES"
for tool in board herdr spinoff; do
  code=0; [ "$tool" = spinoff ] && code=3
  cat > "${FAKES}/${tool}" <<EOF
#!/bin/sh
printf '%s %s\n' "${tool}" "\$*" >> "${CALLS}"
exit ${code}
EOF
  chmod +x "${FAKES}/${tool}"
done
export PATH="${FAKES}:${PATH}"
: > "$CALLS"

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
sys.path.insert(0, os.path.join(sys.argv[1], "tests", "helpers"))
sys.path.insert(0, os.path.join(sys.argv[1], "tests", "fixtures"))
from _bootstrap import load_lib_module
from programme_prompts import append_prompt as fixture_prompt
ph = load_lib_module("programme_home")
pj = load_lib_module("programme_journal")
core = load_lib_module("run_record_core")
import programme_records
args = sys.argv[2:]
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
print(fixture_prompt(run, "sess-pm", text, origin)["prompt_id"])
EOF
}

edit() {
  run_py "$RUN" "$1" <<'EOF'
programme_records.edit(args[0], args[1], globals())
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

# jq-free JSON field read: pyget '<json>' '<python expression over d>'
pyget() {
  "$PY" -c 'import json,sys; d=json.loads(sys.argv[1]); print(json.dumps(eval(sys.argv[2]), sort_keys=True) if not isinstance(eval(sys.argv[2]), str) else eval(sys.argv[2]))' "$1" "$2" 2>&1
}

status_json() { "$PY" "$PROG" status --run "$RUN" --json 2>&1; }
req_state() { pyget "$(status_json)" "{r['id']: r['state'] for r in d['model']['acceptance']['requirements']}['$1']"; }
req_checks() { pyget "$(status_json)" "[c['result'] for r in d['model']['acceptance']['requirements'] if r['id'] == '$1' for c in r['checks']]"; }

stop_decide() {
  "$PY" - "$AUTO_ROOT" <<'EOF' 2>&1
import importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location("on_stop", os.path.join(sys.argv[1], "lib", "on-stop.py"))
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
out = mod.decide("", json.dumps({"session_id": "sess-pm"})) or {"decision": "allow"}
print(json.dumps(out, sort_keys=True))
EOF
}

predicate() {
  run_py "$RUN" <<'EOF'
pp = load_lib_module("programme_predicate")
rec = programme_records.load(args[0])
print(json.dumps(pp.compute(rec, inbox_size=pj.claims_count(args[0])), sort_keys=True))
EOF
}

# ── fixture: three items under the fix-only protocol rule ──────────────────
for item in herdr:browser-e2e herdr:linux-probe herdr:docs-page; do
  prog add-item "$item" --title "$item" --kind fix_only --run "$RUN"
done
NOW_EXPR='core.now_iso()'

AUTONOMY_BEFORE="$("$PY" "$PROG" status --run "$RUN" --json 2>&1)"
P_DEC="$(prompt typed 'record decision d-browser: ship the browser fix, no prod flag changes')"

it "record-decision with a typed prompt that names it records accepted revision 1"
prog record-decision d-browser --scope "ship the browser fix" --reason "customers hit the broken flow" \
  --limit "no prod flag changes" --applies-to herdr:browser-e2e --prompt "$P_DEC" --run "$RUN"
check "0 accepted 1" "$CODE $(pyget "$OUT" 'd["state"]') $(pyget "$OUT" 'd["rev"]')"

it "the decision revision records its source class"
SRC="$(pyget "$OUT" 'd["source"]')"
has '"class": "human_input"' "$SRC"
it "  ... and origin_verified is true: the transcript shows a human typed the prompt"
has '"origin_verified": true' "$SRC"

it "assign-item binds the item to the in-force decision revision"
prog assign-item herdr:browser-e2e --decision-id d-browser --run "$RUN"
check "0 d-browser 1" "$CODE $(pyget "$OUT" 'd["decision_id"]') $(pyget "$OUT" 'd["rev"]')"

P_REQ="$(prompt typed 'requirement r-browser: the browser flow passes its runtime check')"
it "define-requirement links the requirement to a protocol deliverable check of the item"
prog define-requirement r-browser --text "the browser flow passes at runtime" \
  --check herdr:browser-e2e=verified --decision-id d-browser --prompt "$P_REQ" --run "$RUN"
check "0 accepted" "$CODE $(pyget "$OUT" 'd["state"]')"

it "a check on a deliverable the protocol does not require of the item refuses"
P_BAD="$(prompt typed 'requirement r-flag: flagged')"
prog define-requirement r-flag --text "flag on" --check herdr:browser-e2e=flagged --prompt "$P_BAD" --run "$RUN"
check "1" "$CODE"
has "not a deliverable" "$OUT"

# ── Scenario 1 / AE2: a replacement PM restores unchanged decisions without old chat ──
it "AE2: with every export removed, a different session reads the assignment packet from the authority"
rm -f "${HOME_DIR}/.claude/auto/${RUN}.json" "${HOME_DIR}/views/view.json"
PACKET="$(CLAUDE_CODE_SESSION_ID=sess-replacement "$PY" "$PROG" context --item herdr:browser-e2e --run "$RUN" 2>&1)"
check "ship the browser fix|customers hit the broken flow|[\"no prod flag changes\"]" \
  "$(pyget "$PACKET" 'd["decision_revision"]["scope"]')|$(pyget "$PACKET" 'd["decision_revision"]["reason"]')|$(pyget "$PACKET" 'd["decision_revision"]["limits"]')"
it "AE2: the packet names the bound revision, the requirement and its check"
check "1|r-browser|[\"herdr:browser-e2e=verified\"]" \
  "$(pyget "$PACKET" 'd["assignment"]["rev"]')|$(pyget "$PACKET" 'd["requirements"][0]["id"]')|$(pyget "$PACKET" 'd["requirements"][0]["checks"]')"
it "AE2: the packet carries the committed store revision it was rendered from"
REV="$(pyget "$PACKET" 'd["revision"]')"
case "$REV" in ''|*[!0-9]*) fail "revision not a number: $REV" ;; *) pass ;; esac
it "AE2: the packet says it is context, not approval"
has "not approval" "$(pyget "$PACKET" 'd["authority"]')"

it "AE2: re-recording the unchanged decision makes no new revision and asks for no acceptance"
prog record-decision d-browser --scope "ship the browser fix" --reason "customers hit the broken flow" \
  --limit "no prod flag changes" --applies-to herdr:browser-e2e --run "$RUN"
check "0 true 1" "$CODE $(pyget "$OUT" 'd["unchanged"]') $(pyget "$OUT" 'd["rev"]')"
it "AE2: no decision for Shawn asks to accept d-browser again"
lacks "d-browser" "$(pyget "$(status_json)" 'd["model"]["decisions_for_shawn"]')"

it "R16: a decision with a limit does not widen the autonomy in force"
check "$(pyget "$AUTONOMY_BEFORE" 'd["model"]["rules_in_force"]["autonomy"]')" \
  "$(pyget "$(status_json)" 'd["model"]["rules_in_force"]["autonomy"]')"

# ── Scenario 2: materially wider work waits for acceptance of the delta ─────
P_DOCS="$(prompt typed 'record decision d-docs for docs-page')"
prog record-decision d-docs --scope "fix the docs page" --reason "stale install steps" \
  --applies-to herdr:docs-page --prompt "$P_DOCS" --run "$RUN"
prog assign-item herdr:docs-page --decision-id d-docs --run "$RUN"

it "a wider revision of d-docs stays pending even with a typed prompt, and names its delta"
P_WIDE="$(prompt typed 'widen d-docs to linux-probe too')"
prog record-decision d-docs --scope "fix the docs page" --reason "stale install steps" \
  --applies-to herdr:docs-page --applies-to herdr:linux-probe --prompt "$P_WIDE" --run "$RUN"
check "0 pending_acceptance 2 [\"herdr:linux-probe\"]" \
  "$CODE $(pyget "$OUT" 'd["state"]') $(pyget "$OUT" 'd["rev"]') $(pyget "$OUT" 'd["delta"]["added"]')"

it "a kind-less decision's delta lists the added target as what the accepting prompt must name"
check "[\"herdr:linux-probe\"]" "$(pyget "$("$PY" "$PROG" context --run "$RUN" 2>&1)" "d['decisions']['d-docs']['pending']['delta']['added']")"

it "the context view reads the decision as active while its wider revision waits"
check "active" "$(pyget "$("$PY" "$PROG" context --run "$RUN" 2>&1)" "d['decisions']['d-docs']['state']")"

it "work on the widened target waits: assign-item refuses until the delta is accepted"
prog assign-item herdr:linux-probe --decision-id d-docs --run "$RUN"
check "1" "$CODE"
has "waits for acceptance" "$OUT"

it "the prior decision stays in force while the delta is pending"
D="$(CLAUDE_CODE_SESSION_ID=sess-other "$PY" "$PROG" context --run "$RUN" 2>&1)"
check "1 [\"herdr:docs-page\"]" "$(pyget "$D" 'd["decisions"]["d-docs"]["in_force"]["rev"]') $(pyget "$D" 'd["decisions"]["d-docs"]["in_force"]["applies_to"]')"

it "the pending delta is a decision for Shawn"
has "d-docs" "$(pyget "$(status_json)" 'd["model"]["decisions_for_shawn"]')"

it "accept-context refuses a prompt that names the decision but not the added target"
P_HALF="$(prompt typed 'accept d-docs')"
prog accept-context d-docs --prompt "$P_HALF" --run "$RUN"
check "1" "$CODE"
has "linux-probe" "$OUT"

it "accept-context refuses a prompt that is not typed"
P_CRON="$(prompt cron 'accept d-docs with linux-probe')"
prog accept-context d-docs --prompt "$P_CRON" --run "$RUN"
check "1" "$CODE"
has "not typed" "$OUT"

it "accept-context refuses a prompt imported from a legacy journal"
P_LEGACY="$(run_py "$RUN" <<'EOF'
pa = load_lib_module("programme_authority")
ps = load_lib_module("programme_store")
row = pj.entry("prompt", "sess-pm", {"text": "accept d-docs with linux-probe", "origin": "typed"}, prompt_id="plegacy1")
event = {"kind": "legacy_import", "payload": {"channel": pa.HISTORY, "journal": [row], "claims": [], "gaps": []}}
def body():
    with pa._open(args[0]) as store:
        head = ps.head(store)
        pa.commit(store, args[0], "test-legacy-1", head["revision"], head["state"], event, pa.LEGACY)
pa._locked(ph.home_path(args[0]), args[0], body)
print("plegacy1")
EOF
)"
prog accept-context d-docs --prompt "$P_LEGACY" --run "$RUN"
check "1" "$CODE"
has "legacy" "$OUT"

it "accept-context refuses a prompt the hook journaled as unknown, though its text names the delta"
P_UNKNOWN="$(prompt unknown 'accept d-docs widened to linux-probe')"
prog accept-context d-docs --prompt "$P_UNKNOWN" --run "$RUN"
check "1" "$CODE"
has "human source unverified" "$OUT"

it "accept-context refuses a typed-labelled prompt with no source record (an old journal row)"
P_BARE="$(run_py "$RUN" <<'EOF'
print(pj.append_prompt(args[0], "sess-pm", "accept d-docs widened to linux-probe", "typed")["prompt_id"])
EOF
)"
prog accept-context d-docs --prompt "$P_BARE" --run "$RUN"
check "1" "$CODE"
has "human source unverified" "$OUT"

it "a verified prompt row stamped legacy_import reads unknown to every approval check"
P_LEGACY_SRC="$(run_py "$RUN" <<'EOF'
from programme_prompts import fixture
_, source, path, transcript_row = fixture("accept d-docs widened to linux-probe", "sess-pm")
path.write_text(json.dumps(transcript_row) + "\n")
pa = load_lib_module("programme_authority")
ps = load_lib_module("programme_store")
row = pj.entry("prompt", "sess-pm", {"text": "accept d-docs widened to linux-probe", "origin": "unknown",
                                     "source": source}, prompt_id="plegsrc1")
event = {"kind": "legacy_import", "payload": {"channel": pa.HISTORY, "journal": [row], "claims": [], "gaps": []}}
def body():
    with pa._open(args[0]) as store:
        head = ps.head(store)
        pa.commit(store, args[0], "test-legacy-src", head["revision"], head["state"], event, pa.LEGACY)
pa._locked(ph.home_path(args[0]), args[0], body)
stored = pj.find_prompt(args[0], "plegsrc1")
print(load_lib_module("programme_prompt_source").origin(row), stored.get("provenance"), pj.prompt_origin(stored),
      load_lib_module("programme").prompt_lookup(args[0], "plegsrc1")["origin"])
EOF
)"
check "typed legacy_import unknown unknown" "$P_LEGACY_SRC"
prog accept-context d-docs --prompt plegsrc1 --run "$RUN"
check "1" "$CODE"
has "legacy" "$OUT"

it "accepting the delta with a prompt naming it makes revision 2 in force and supersedes revision 1"
P_FULL="$(prompt typed 'accept d-docs widened to linux-probe')"
prog accept-context d-docs --prompt "$P_FULL" --run "$RUN"
D="$(CLAUDE_CODE_SESSION_ID=sess-other "$PY" "$PROG" context --run "$RUN" 2>&1)"
check "0 2 2" "$CODE $(pyget "$D" 'd["decisions"]["d-docs"]["in_force"]["rev"]') $(pyget "$D" 'd["decisions"]["d-docs"]["revisions"][0]["superseded_by"]')"
it "  ... the acceptance records origin_verified true from the fixture-verified prompt"
check "true" "$(pyget "$D" 'd["decisions"]["d-docs"]["revisions"][1]["accepted"]["origin_verified"]')"
it "  ... revision 1 keeps its original scope (the record is immutable)"
check "[\"herdr:docs-page\"]" "$(pyget "$D" 'd["decisions"]["d-docs"]["revisions"][0]["applies_to"]')"

it "the earlier assignment stays bound to revision 1 and the packet links the supersession"
PK="$(CLAUDE_CODE_SESSION_ID=sess-other "$PY" "$PROG" context --item herdr:docs-page --run "$RUN" 2>&1)"
check "1 2" "$(pyget "$PK" 'd["assignment"]["rev"]') $(pyget "$PK" 'd["assignment"]["superseded_by"]')"

it "history never broadens: after a merge, an item whose canonical id is out of scope is refused"
prog add-item herdr:extra --title extra --kind fix_only --run "$RUN"
prog merge-item herdr:browser-e2e herdr:extra --run "$RUN" >/dev/null
prog assign-item herdr:extra --decision-id d-browser --run "$RUN"
check "1" "$CODE"
has "outside the scope" "$OUT"
# undo the merge fixture so later scenarios keep the browser item
edit 'items["herdr:browser-e2e"] = dict(items["herdr:extra"], id="herdr:browser-e2e", aliases=[]); items.pop("herdr:extra")'

# ── Scenario 3 / AE7: unrelated open work cannot gate satisfied browser acceptance ──
edit "items['herdr:browser-e2e']['deliverables']['verified'] = {'result': 'confirmed', 'checked_at': ${NOW_EXPR}}"
prog set-waiting herdr:linux-probe --who team:linux --blocker --serves "the linux investigation" \
  --evidence "trace t-linux-1" --unblocks-when "team linux reports the kernel owner" --trace-id t-linux-1 --run "$RUN"

it "AE7: browser acceptance is satisfied while the Linux investigation is open and waiting"
check "satisfied" "$(req_state r-browser)"
it "AE7: the open Linux investigation is a follow-up, not an acceptance requirement"
has "herdr:linux-probe" "$(pyget "$(status_json)" 'd["model"]["acceptance"]["followups"]')"
it "AE7: a satisfied requirement does not make the programme done"
check "False" "$(pyget "$(status_json)" 'str(d["model"]["programme"]["done"])')"

# ── Scenario 4: a real dependency names requirement/check, evidence and unblock condition ──
it "raise-blocker without --evidence refuses"
prog raise-blocker b1 --requirement r-browser --check herdr:browser-e2e=verified \
  --dependency herdr:linux-probe --unblock "the kernel fix lands" --run "$RUN"
check "1" "$CODE"
has "missing --evidence" "$OUT"
it "raise-blocker without --unblock refuses"
prog raise-blocker b1 --requirement r-browser --check herdr:browser-e2e=verified \
  --dependency herdr:linux-probe --evidence trace:t-linux-1 --run "$RUN"
check "1" "$CODE"
has "missing --unblock" "$OUT"
it "raise-blocker naming a check the requirement does not have refuses"
prog raise-blocker b1 --requirement r-browser --check herdr:browser-e2e=merged \
  --dependency herdr:linux-probe --evidence trace:t-linux-1 --unblock "the kernel fix lands" --run "$RUN"
check "1" "$CODE"
has "is not a check of requirement" "$OUT"
it "raise-blocker naming an unknown requirement refuses"
prog raise-blocker b1 --requirement r-nope --check herdr:browser-e2e=verified \
  --dependency herdr:linux-probe --evidence trace:t-linux-1 --unblock "the kernel fix lands" --run "$RUN"
check "1" "$CODE"
has "no accepted requirement" "$OUT"
it "raise-blocker naming an unknown dependency item refuses"
prog raise-blocker b1 --requirement r-browser --check herdr:browser-e2e=verified \
  --dependency herdr:ghost --evidence trace:t-linux-1 --unblock "the kernel fix lands" --run "$RUN"
check "1" "$CODE"
has "no item 'herdr:ghost'" "$OUT"
it "AE7: no refused blocker gated browser acceptance"
check "satisfied" "$(req_state r-browser)"

it "a fully linked blocker gates the requirement it names"
prog raise-blocker b1 --requirement r-browser --check herdr:browser-e2e=verified \
  --dependency herdr:linux-probe --evidence trace:t-linux-1 --unblock "the kernel fix lands" --run "$RUN"
check "0 blocked" "$CODE $(req_state r-browser)"
it "  ... and status names its requirement, check, evidence and unblock condition"
B="$(pyget "$(status_json)" '[b for b in d["model"]["acceptance"]["blockers"] if b["id"] == "b1"][0]')"
check "r-browser|herdr:browser-e2e=verified|trace:t-linux-1|the kernel fix lands" \
  "$(pyget "$B" 'd["requirement"]')|$(pyget "$B" 'd["check"]')|$(pyget "$B" 'd["evidence"]')|$(pyget "$B" 'd["unblock"]')"
it "clearing the blocker restores satisfied acceptance"
prog clear-blocker b1 --why "kernel fix landed" --run "$RUN"
check "0 satisfied" "$CODE $(req_state r-browser)"

# ── Scenario 5: a safety pause blocks unsafe continuation independently of acceptance ──
it "pause records an active data-loss pause on the docs item and escalates it"
: > "$CALLS"
prog pause s1 --risk data_loss --reason "the migration may drop rows" --item herdr:docs-page --run "$RUN"
check "0 active" "$CODE $(pyget "$OUT" 'd["state"]')"
has "herdr notification" "$(cat "$CALLS")"

it "start-worker refuses a paused item before it looks for spinoff"
: > "$CALLS"
prog start-worker herdr:docs-page --run "$RUN" -- --plan x
check "1" "$CODE"
has "safety pause s1" "$OUT"
it "  ... and spinoff never ran"
lacks "spinoff" "$(cat "$CALLS")"
it "prompt-item refuses a paused item"
prog prompt-item herdr:docs-page "continue the migration" --run "$RUN"
check "1" "$CODE"
has "safety pause s1" "$OUT"

it "the pause is a decision for Shawn and shows in status"
has "s1" "$(pyget "$(status_json)" 'd["model"]["decisions_for_shawn"]')"
has "s1" "$(pyget "$(status_json)" 'd["model"]["acceptance"]["safety_pauses"]')"

it "a pause on the browser item leaves the satisfied requirement satisfied"
prog pause s2 --risk safety --reason "a prod write path is exposed" --item herdr:browser-e2e --run "$RUN"
check "satisfied" "$(req_state r-browser)"
it "a satisfied requirement does not lift the pause or admit a worker"
prog start-worker herdr:browser-e2e --run "$RUN" -- --plan x
check "1" "$CODE"
has "safety pause s2" "$OUT"

it "lift-pause needs a typed prompt that names the pause"
P_LIFT_BAD="$(prompt typed 'lift the pause')"
prog lift-pause s2 --prompt "$P_LIFT_BAD" --run "$RUN"
check "1" "$CODE"
has "does not name" "$OUT"
P_LIFT="$(prompt typed 'lift pause s2, the write path is closed')"
prog lift-pause s2 --prompt "$P_LIFT" --run "$RUN"
check "0" "$CODE"

it "Stop names an active pause in its reasons"
REASON="$(pyget "$(stop_decide)" 'd.get("reason", "")')"
has "safety_pause s1" "$REASON"

# ── Scenario 6: not-run, stale, unknown and refuted never become confirmed ──
P_RL="$(prompt typed 'requirement r-linux: the linux probe is verified')"
prog define-requirement r-linux --text "the linux probe is verified" --check herdr:linux-probe=verified \
  --prompt "$P_RL" --run "$RUN"

it "a check with no observation reads not_run"
check '["not_run"]' "$(req_checks r-linux)"
it "an observed unknown reads unknown"
edit "items['herdr:linux-probe']['deliverables']['verified'] = {'result': 'unknown', 'checked_at': ${NOW_EXPR}}"
check '["unknown"]' "$(req_checks r-linux)"
it "a confirmation observed before the requirement revision was accepted reads stale"
edit "items['herdr:linux-probe']['deliverables']['verified'] = {'result': 'confirmed', 'checked_at': '2020-01-01T00:00:00Z'}"
check '["stale"] unsatisfied' "$(req_checks r-linux) $(req_state r-linux)"
it "a refuted check reads refuted"
edit "items['herdr:linux-probe']['deliverables']['verified'] = {'result': 'refuted', 'checked_at': ${NOW_EXPR}}"
check '["refuted"] unsatisfied' "$(req_checks r-linux) $(req_state r-linux)"

it "the evidence-check test hatch makes the item done but never accepts the requirement"
check "unsatisfied" "$(CLAUDE_AUTO_TEST_NO_EVIDENCE_CHECK=1 req_state r-linux)"

it "a restored export claiming confirmed evidence is ignored: the authority still reads refuted"
run_py "$RUN" <<'EOF' >/dev/null
rec = programme_records.load(args[0])
rec["programme"]["items"]["herdr:linux-probe"]["deliverables"]["verified"] = {"result": "confirmed", "checked_at": core.now_iso()}
path = os.path.join(ph.home_path(args[0]), ".claude", "auto", args[0] + ".json")
os.makedirs(os.path.dirname(path), exist_ok=True)
json.dump(rec, open(path, "w"))
EOF
check '["refuted"]' "$(req_checks r-linux)"
it "  ... and the restore-packet read reports refuted too"
PK="$(CLAUDE_CODE_SESSION_ID=sess-replacement "$PY" "$PROG" context --item herdr:linux-probe --run "$RUN" 2>&1)"
has '"refuted"' "$(pyget "$PK" 'd["acceptance"]')"

# ── Scenario 7 / AE8: a denial stays visible and requirements stay unchanged ──
REQS_BEFORE="$(pyget "$(CLAUDE_CODE_SESSION_ID=sess-x "$PY" "$PROG" context --run "$RUN" 2>&1)" 'd["requirements"]')"
it "AE8: record-denial keeps the tool's refusal"
prog record-denial --tool Bash --action start_worker --reason "permission denied for spinoff" --item herdr:linux-probe --run "$RUN"
check "0" "$CODE"
it "AE8: the requirements are byte-identical after the denial"
REQS_AFTER="$(pyget "$(CLAUDE_CODE_SESSION_ID=sess-x "$PY" "$PROG" context --run "$RUN" 2>&1)" 'd["requirements"]')"
check "$REQS_BEFORE" "$REQS_AFTER"
it "AE8: the denial is visible in status and in the item's packet"
has "permission denied for spinoff" "$(pyget "$(status_json)" 'd["model"]["acceptance"]["denials"]')"
PK="$(CLAUDE_CODE_SESSION_ID=sess-replacement "$PY" "$PROG" context --item herdr:linux-probe --run "$RUN" 2>&1)"
has "permission denied for spinoff" "$(pyget "$PK" 'd["denials"]')"
it "AE8: the denial binds: start-worker on that item refuses instead of routing around it"
prog start-worker herdr:linux-probe --run "$RUN" -- --plan x
check "1" "$CODE"
has "denied" "$OUT"
it "AE8: the denial does not turn the requirement into a satisfied or waived one"
check "unsatisfied" "$(req_state r-linux)"

# ── Scenario 8: acceptance, follow-ups and stop eligibility stay distinct ──
it "Stop holds: r-browser is satisfied but the follow-up Linux work is open"
SD="$(stop_decide)"
check "block" "$(pyget "$SD" 'd["decision"]')"
it "  ... and status reports r-browser satisfied at the same time"
check "satisfied" "$(req_state r-browser)"
it "the predicate keeps acceptance out of the stop reasons"
P="$(predicate)"
lacks "requirement" "$(pyget "$P" '[r["kind"] for r in d["reasons"]]')"
it "the predicate output carries acceptance separately from done and may_stop"
check "False False" "$(pyget "$P" 'str(d["done"])') $(pyget "$P" 'str(d["may_stop"])')"

# ── Scenario 9: handed/dropped work does not accept; policies keep separate effects ──
prog hand-item herdr:linux-probe --question "linux needs a kernel owner" --kind product_scope --run "$RUN"
prog drop-item herdr:docs-page --reason "superseded by the new docs site" --run "$RUN"
edit "items['herdr:browser-e2e']['deliverables'] = {n: {'result': 'confirmed', 'checked_at': ${NOW_EXPR}} for n in items['herdr:browser-e2e']['deliverables']}"
it "with every item finished, the programme is done but r-linux is not accepted"
S="$(status_json)"
check "True unsatisfied" "$(pyget "$S" 'str(d["model"]["programme"]["done"])') $(req_state r-linux)"
it "the outcomes report completed, handed and dropped work separately"
check '["herdr:browser-e2e"]|["herdr:linux-probe"]|["herdr:docs-page"]' \
  "$(pyget "$S" 'd["model"]["acceptance"]["outcomes"]["completed"]')|$(pyget "$S" 'd["model"]["acceptance"]["outcomes"]["handed"]')|$(pyget "$S" 'd["model"]["acceptance"]["outcomes"]["dropped"]')"

P_SR="$(prompt typed 'amend stop_rule only_when_done')"
prog amend-term stop_rule only_when_done --prompt "$P_SR" --run "$RUN"
it "only-when-done keeps its effect: done allows the stop although r-linux is unsatisfied"
check "allow" "$(pyget "$(stop_decide)" 'd["decision"]')"

P_NS="$(prompt typed 'amend stop_rule never_stop')"
prog amend-term stop_rule never_stop --prompt "$P_NS" --run "$RUN"
it "never-stop keeps its effect: satisfied acceptance does not release it"
check "block" "$(pyget "$(stop_decide)" 'd["decision"]')"

P_NC="$(prompt typed 'amend stop_rule nothing_it_can_act_on')"
prog amend-term stop_rule nothing_it_can_act_on --prompt "$P_NC" --run "$RUN"
prog claim --run "$RUN" --item herdr:browser-e2e --deliverable verified --ref pr-77 >/dev/null
it "unread claims keep their effect: Stop holds on them while r-browser is satisfied"
SD="$(stop_decide)"
check "block satisfied" "$(pyget "$SD" 'd["decision"]') $(req_state r-browser)"
has "unread_claim" "$(pyget "$SD" 'd["reason"]')"

it "a malformed context block holds the stop instead of reading as a corrupt (skipped) programme"
prog mark-read --run "$RUN" >/dev/null
edit 'prog["context"] = {"requirements": "garbage"}'
P="$(predicate)"
has "corrupt_context" "$(pyget "$P" '[r["kind"] for r in d["reasons"]]')"
check "block" "$(pyget "$(stop_decide)" 'd["decision"]')"

it "describe lists the context verbs"
DESC="$("$PY" "$PROG" describe 2>/dev/null)"
VERBS="$("$PY" -c 'import json,sys; print(" ".join(sorted(json.load(sys.stdin)["verbs"])))' <<< "$DESC" 2>&1)"
for verb in record-decision record-ruling close-ruling define-requirement accept-context assign-item raise-blocker clear-blocker pause lift-pause record-denial context; do
  case " $VERBS " in *" $verb "*) ;; *) VERBS="MISSING:$verb $VERBS" ;; esac
done
lacks "MISSING:" "$VERBS"

it "no verb crashed with a traceback"
check "" "$CRASHES"

echo
echo "programme-context.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
