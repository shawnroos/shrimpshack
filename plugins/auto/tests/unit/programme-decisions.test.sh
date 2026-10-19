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

echo "programme-decisions.test.sh"

WORK="$(mktemp -d -t auto-programme-decisions.XXXXXX)"
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

journal_count() {
  run_py "$RUN" "$1" <<'EOF'
print(sum(1 for row in pj.read(args[0]) if row["kind"] == args[1]))
EOF
}

journal_last() {
  run_py "$RUN" "$1" <<'EOF'
rows = [row for row in pj.read(args[0]) if row["kind"] == args[1]]
print(json.dumps(rows[-1] if rows else None, sort_keys=True))
EOF
}

finished_count() {
  run_py "$RUN" <<'EOF'
pp = load_lib_module("programme_predicate")
print(pp.compute(record(args[0]))["items"]["finished"])
EOF
}

OUT=""
CODE=0
prog() {
  OUT="$("$PY" "$PROG" "$@" 2>&1)"
  CODE=$?
}

decision_count() { field 'len(prog["decisions"])'; }

it "the decision kinds cover every plugin autonomy action plus the denied-operation kind"
check "[] True" "$(run_py <<'EOF'
pd = load_lib_module("programme_decisions")
pp = load_lib_module("programme_protocol")
print(sorted(set(pp.plugin_layer()["autonomy"]) - set(pd.DECISION_KINDS)), "denied_operation" in pd.DECISION_KINDS)
EOF
)"

it "a new programme starts with an empty decisions list"
check "[]" "$(field 'prog["decisions"]')"

prog add-item linear:AI-1 --title "Crop default" --kind fix_only
prog add-item linear:AI-2 --title "Which crop?" --kind product_question
prog add-item linear:AI-3 --title "Another product call" --kind product_question
prog add-item linear:AI-4 --title "Ask me" --kind fix_only

it "record-decision --silent writes a decision with an id"
prog record-decision linear:AI-1 --kind technical_approach --silent --why "smaller diff, same outcome"
check 0 "$CODE"
check '["linear:AI-1", "technical_approach", true, null, "pm", "smaller diff, same outcome", true]' \
  "$(field '[prog["decisions"][0][k] for k in ("item", "kind", "silent", "term", "by", "why")] + [bool(__import__("re").fullmatch(r"d[0-9a-f]{6}", prog["decisions"][0]["id"]))]')"
it "record-decision journals pm_decided carrying the decision id"
check "true" "$(run_py "$RUN" <<'EOF'
rows = [r for r in pj.read(args[0]) if r["kind"] == "pm_decided"]
rec = record(args[0])
print(json.dumps(len(rows) == 1 and rows[0]["payload"]["decision_id"] == rec["programme"]["decisions"][0]["id"]))
EOF
)"
it "record-decision prints the decision id"
has '"decision_id": "d' "$OUT"

it "record-decision on the programme as a whole records target programme"
prog record-decision programme --kind work_sequencing --term cadence --why "the cadence term says hourly"
check '["programme", "cadence", false]' "$(field '[prog["decisions"][-1][k] for k in ("item", "term", "silent")]')"

it "an unknown kind refuses with the known kinds"
BEFORE="$(decision_count)"
prog record-decision linear:AI-1 --kind vibes --silent --why x
check 1 "$CODE"
has "unknown decision kind 'vibes'" "$OUT"
it "the unknown-kind refusal writes no decision"
check "$BEFORE" "$(decision_count)"
it "the unknown-kind refusal journals nothing"
check 2 "$(journal_count pm_decided)"

for kind in unknown agreement; do
  it "the record-only kind ${kind} is refused as input"
  prog record-decision linear:AI-1 --kind "$kind" --silent --why x
  check "1 unknown decision kind" "$CODE $(printf '%s' "$OUT" | grep -o 'unknown decision kind' | head -1)"
done

it "record-decision with neither --term nor --silent refuses"
prog record-decision linear:AI-1 --kind tool_choice --why x
check "2 exactly one of" "$CODE $(printf '%s' "$OUT" | grep -o 'exactly one of' | head -1)"
it "record-decision with both --term and --silent refuses"
prog record-decision linear:AI-1 --kind tool_choice --silent --term cadence --why x
check "2 exactly one of" "$CODE $(printf '%s' "$OUT" | grep -o 'exactly one of' | head -1)"
it "record-decision without --why refuses"
prog record-decision linear:AI-1 --kind tool_choice --silent
check "2 --why" "$CODE $(printf '%s' "$OUT" | grep -o -- '--why' | head -1)"
it "record-decision with a term id holding spaces refuses"
prog record-decision linear:AI-1 --kind tool_choice --term "two words" --why x
check 1 "$CODE"
it "record-decision on an unknown item refuses"
prog record-decision linear:AI-99 --kind tool_choice --silent --why x
check "1 no item" "$CODE $(printf '%s' "$OUT" | grep -o 'no item' | head -1)"
it "record-decision on a bad target refuses"
prog record-decision "not an id" --kind tool_choice --silent --why x
check 1 "$CODE"
it "none of the refusals wrote a decision"
check "$BEFORE" "$(decision_count)"

it "record-decision from a session that does not drive the programme is refused"
CLAUDE_CODE_SESSION_ID="sess-stranger" prog record-decision linear:AI-1 --kind tool_choice --silent --why x --run "$RUN"
check "1 driving session" "$CODE $(printf '%s' "$OUT" | grep -o 'driving session' | head -1)"

it "hand-item without --kind refuses"
prog hand-item linear:AI-4 --question "Ship it?"
check "2 --kind" "$CODE $(printf '%s' "$OUT" | grep -o -- '--kind' | head -1)"
it "the refused hand leaves the item open"
check '"open"' "$(field 'prog["items"]["linear:AI-4"]["state"]')"
it "hand-item with an unknown kind refuses"
prog hand-item linear:AI-4 --question "Ship it?" --kind vibes
check "1 unknown decision kind" "$CODE $(printf '%s' "$OUT" | grep -o 'unknown decision kind' | head -1)"

it "hand-item with a kind records an ask that carries the kind and an id"
prog hand-item linear:AI-4 --question "Ship it?" --kind product_scope
check '["product_scope", true, null]' \
  "$(field '[prog["items"]["linear:AI-4"]["handed"]["kind"], bool(__import__("re").fullmatch(r"a[0-9a-f]{6}", prog["items"]["linear:AI-4"]["handed"]["id"])), prog["items"]["linear:AI-4"]["handed"]["answered"]]')"
it "the item_handed journal entry carries the ask id and kind"
has '"ask_kind": "product_scope"' "$(journal_last item_handed)"
it "the view's decision for Shawn names the ask kind"
prog status --json
has '"ask_kind": "product_scope"' "$OUT"

it "status --json shows the ask id on the handed item and on its row for Shawn"
ASK="$(field 'prog["items"]["linear:AI-4"]["handed"]["id"]')"
check "${ASK} ${ASK}" "$("$PY" -c 'import json,sys; m=json.load(sys.stdin)["model"]; i=[x for x in m["items"] if x["id"]=="linear:AI-4"][0]; d=[x for x in m["decisions_for_shawn"] if x.get("item")=="linear:AI-4"][0]; print(json.dumps(i.get("ask_id")), json.dumps(d.get("ask_id")))' <<< "$OUT")"
it "the text status names the ask id beside the question"
prog status
has "linear:AI-4 (ask $(printf '%s' "$ASK" | tr -d '"')): Ship it?" "$OUT"

it "answer-handed writes a Shawn decision linked to the ask id"
P_SHIP="$(prompt typed 'ship AI-4')"
prog answer-handed linear:AI-4 --choice ship --prompt "$P_SHIP"
check 0 "$CODE"
check "[${ASK}, \"product_scope\", \"shawn\", \"ship\", \"${P_SHIP}\", \"linear:AI-4\"]" \
  "$(field '[prog["decisions"][-1][k] for k in ("ask", "kind", "by", "choice", "prompt_id", "item")]')"
it "the answer on the ask points back to the decision"
check "true" "$(field 'prog["items"]["linear:AI-4"]["handed"]["answered"]["decision_id"] == prog["decisions"][-1]["id"]')"
it "the handed_answered journal entry carries the decision id"
has "$(field 'prog["decisions"][-1]["id"]' | tr -d '"')" "$(journal_last handed_answered)"
it "status --terms shows the ask an answer replies to"
prog status --terms --json
has "\"ask\": ${ASK}" "$OUT"
prog status --terms
has "(ask $(printf '%s' "$ASK" | tr -d '"'))" "$OUT"

it "accept-agreement writes a Shawn decision of kind agreement"
P_ACCEPT="$(prompt typed 'yes, accept the agreement')"
prog accept-agreement --prompt "$P_ACCEPT"
check 0 "$CODE"
check "[\"agreement\", \"shawn\", \"programme\", \"${P_ACCEPT}\"]" \
  "$(field '[prog["decisions"][-1][k] for k in ("kind", "by", "item", "prompt_id")]')"
it "the agreement_accepted journal entry carries the decision id"
has "$(field 'prog["decisions"][-1]["id"]' | tr -d '"')" "$(journal_last agreement_accepted)"

it "accept-agreement stamps the contract version"
check 1 "$(field 'prog["agreement"]["contract_version"]')"
edit 'rec["programme"]["agreement"].pop("contract_version")'

it "on an unstamped programme record-decision on a product question refuses"
BEFORE="$(decision_count)"
prog record-decision linear:AI-2 --kind product_call --silent --why "obvious"
check "1 hand-item" "$CODE $(printf '%s' "$OUT" | grep -o 'hand-item' | head -1)"
it "the unstamped refusal leaves the item open and writes no decision"
check "\"open\" ${BEFORE}" "$(field 'prog["items"]["linear:AI-2"]["state"]') $(decision_count)"
it "the unstamped product question still needs hand-item"
prog hand-item linear:AI-2 --question "Which crop?" --kind product_call
check '0 "handed"' "$CODE $(field 'prog["items"]["linear:AI-2"]["state"]')"

edit 'rec["programme"]["agreement"]["contract_version"] = 1'
FIN_BEFORE="$(finished_count)"
it "on a stamped programme record-decision closes a product question as decided"
prog record-decision linear:AI-3 --kind product_call --silent --why "the terms are silent and it does not change acceptance"
check '0 "decided"' "$CODE $(field 'prog["items"]["linear:AI-3"]["state"]')"
it "the decided item counts as finished for the stop predicate"
check "$((FIN_BEFORE + 1))" "$(finished_count)"
it "the decision records the decided outcome"
check '"decided"' "$(field 'prog["decisions"][-1]["outcome"]')"
it "the decided item does not need Shawn in the view"
prog status --json
check "decided False" "$("$PY" -c 'import json,sys; v=json.load(sys.stdin); i=[x for x in v["model"]["items"] if x["id"]=="linear:AI-3"][0]; print(i["effective_state"], i["needs_shawn"])' <<< "$OUT")"
it "the text status renders a decided item"
prog status
check "0 0" "$CODE $(printf '%s' "$OUT" | grep -c 'Traceback\|view refresh failed')"
has "linear:AI-3  decided" "$OUT"
it "a decided item is not handed again"
prog hand-item linear:AI-3 --question "again?" --kind product_call
check 1 "$CODE"
it "a decided item is not re-matched by add-item"
prog add-item linear:AI-3 --kind fix_only
check 1 "$CODE"
it "a second decision on a decided product question refuses"
prog record-decision linear:AI-3 --kind product_call --silent --why "again"
check "1 decided" "$CODE $(printf '%s' "$OUT" | grep -o 'decided' | head -1)"
it "on a stamped programme a decision on another item leaves its state alone"
prog record-decision linear:AI-1 --kind tool_choice --silent --why x
check '0 "open"' "$CODE $(field 'prog["items"]["linear:AI-1"]["state"]')"

it "deciding a product question that also carries a code change re-matches the code change and stays open"
prog add-item linear:AI-5 --title "Pick and build" --kind product_question --kind fix_only
prog record-decision linear:AI-5 --kind product_call --silent --why "the terms are silent"
check '0 "open" ["fix-only"] "decided"' \
  "$CODE $(field 'prog["items"]["linear:AI-5"]["state"]') $(field 'prog["items"]["linear:AI-5"]["matched_rule"]') $(field 'prog["decisions"][-1]["outcome"]')"

prog add-item linear:AI-6 --title "Product ask" --kind product_question
it "on a stamped programme a non-product kind on a product question records and leaves the item open"
prog record-decision linear:AI-6 --kind tool_choice --silent --why "use the existing crop helper"
check '0 "open" ["product-question"] ["product_question"] null' \
  "$CODE $(field 'prog["items"]["linear:AI-6"]["state"]') $(field 'prog["items"]["linear:AI-6"]["matched_rule"]') $(field 'prog["items"]["linear:AI-6"]["change_kinds"]') $(field 'prog["decisions"][-1]["outcome"]')"

for kind in prod_deploy full_release spend_over_cap merge_around_gate eval_waiver denied_operation; do
  it "the PM cannot record a ${kind} choice itself and is pointed at hand-item"
  BEFORE="$(decision_count)"
  JBEFORE="$(journal_count pm_decided)"
  prog record-decision programme --kind "$kind" --silent --why "tests passed"
  check "1 hand-item ${BEFORE} ${JBEFORE}" \
    "$CODE $(printf '%s' "$OUT" | grep -o 'hand-item' | head -1) $(decision_count) $(journal_count pm_decided)"
done
it "an act-level kind still records"
prog record-decision programme --kind merge_at_gate --silent --why "gate is green"
check '0 "merge_at_gate"' "$CODE $(field 'prog["decisions"][-1]["kind"]')"

edit 'rec["programme"]["agreement"].pop("contract_version")'
prog add-item linear:AI-7 --title "Unstamped product ask" --kind product_question
it "on an unstamped programme a non-product kind on a product question records without refusing"
prog record-decision linear:AI-7 --kind tool_choice --silent --why "use the existing crop helper"
check '0 "open" ["product-question"]' \
  "$CODE $(field 'prog["items"]["linear:AI-7"]["state"]') $(field 'prog["items"]["linear:AI-7"]["matched_rule"]')"
edit 'rec["programme"]["agreement"]["contract_version"] = 1'

edit 'rec["programme"].pop("decisions"); rec["programme"]["items"]["linear:AI-1"].update(state="handed", handed={"at": "2026-10-01T00:00:00Z", "question": "old ask?", "answered": None})'
it "a record written before decisions existed loads with an empty decisions list"
prog status --json
check 0 "$CODE"
it "an old ask reads as kind unknown"
has '"ask_kind": "unknown"' "$OUT"
it "answering an old ask records a decision of kind unknown with no ask id"
P_SHIP1="$(prompt typed 'ship AI-1')"
prog answer-handed linear:AI-1 --choice ship --prompt "$P_SHIP1"
check '0 ["unknown", null]' "$CODE $(field '[prog["decisions"][-1]["kind"], prog["decisions"][-1]["ask"]]')"

echo ""
echo "programme-decisions.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
