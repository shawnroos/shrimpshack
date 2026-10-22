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
sys.path.insert(0, os.path.join(sys.argv[1], 'tests', 'fixtures'))
from programme_prompts import append_prompt as fixture_prompt
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
print(fixture_prompt(run, "sess-pm", text, origin)["prompt_id"])
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
core._with_locked_run_record(ph.home_path(run), run, lambda rec: exec(expr, {"rec": rec}))
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

it "log-decision --silent writes a decision with an id"
prog log-decision linear:AI-1 --kind technical_approach --silent --why "smaller diff, same outcome"
check 0 "$CODE"
check '["linear:AI-1", "technical_approach", true, null, "pm", "smaller diff, same outcome", true]' \
  "$(field '[prog["decisions"][0][k] for k in ("item", "kind", "silent", "term", "by", "why")] + [bool(__import__("re").fullmatch(r"d[0-9a-f]{6}", prog["decisions"][0]["id"]))]')"
it "log-decision journals pm_decided carrying the decision id"
check "true" "$(run_py "$RUN" <<'EOF'
rows = [r for r in pj.read(args[0]) if r["kind"] == "pm_decided"]
rec = record(args[0])
print(json.dumps(len(rows) == 1 and rows[0]["payload"]["decision_id"] == rec["programme"]["decisions"][0]["id"]))
EOF
)"
it "log-decision prints the decision id"
has '"decision_id": "d' "$OUT"

it "log-decision on the programme as a whole records target programme"
prog log-decision programme --kind work_sequencing --term cadence --why "the cadence term says hourly"
check '["programme", "cadence", false]' "$(field '[prog["decisions"][-1][k] for k in ("item", "term", "silent")]')"

it "an unknown kind refuses with the known kinds"
BEFORE="$(decision_count)"
prog log-decision linear:AI-1 --kind vibes --silent --why x
check 1 "$CODE"
has "unknown decision kind 'vibes'" "$OUT"
it "the unknown-kind refusal writes no decision"
check "$BEFORE" "$(decision_count)"
it "the unknown-kind refusal journals nothing"
check 2 "$(journal_count pm_decided)"

for kind in unknown agreement; do
  it "the record-only kind ${kind} is refused as input"
  prog log-decision linear:AI-1 --kind "$kind" --silent --why x
  check "1 unknown decision kind" "$CODE $(printf '%s' "$OUT" | grep -o 'unknown decision kind' | head -1)"
done

it "log-decision with neither --term nor --silent refuses"
prog log-decision linear:AI-1 --kind tool_choice --why x
check "2 exactly one of" "$CODE $(printf '%s' "$OUT" | grep -o 'exactly one of' | head -1)"
it "log-decision with both --term and --silent refuses"
prog log-decision linear:AI-1 --kind tool_choice --silent --term cadence --why x
check "2 exactly one of" "$CODE $(printf '%s' "$OUT" | grep -o 'exactly one of' | head -1)"
it "log-decision without --why refuses"
prog log-decision linear:AI-1 --kind tool_choice --silent
check "2 --why" "$CODE $(printf '%s' "$OUT" | grep -o -- '--why' | head -1)"
it "log-decision with a term id holding spaces refuses"
prog log-decision linear:AI-1 --kind tool_choice --term "two words" --why x
check 1 "$CODE"
it "log-decision on an unknown item refuses"
prog log-decision linear:AI-99 --kind tool_choice --silent --why x
check "1 no item" "$CODE $(printf '%s' "$OUT" | grep -o 'no item' | head -1)"
it "log-decision on a bad target refuses"
prog log-decision "not an id" --kind tool_choice --silent --why x
check 1 "$CODE"
it "none of the refusals wrote a decision"
check "$BEFORE" "$(decision_count)"

it "log-decision from a session that does not drive the programme is refused"
CLAUDE_CODE_SESSION_ID="sess-stranger" prog log-decision linear:AI-1 --kind tool_choice --silent --why x --run "$RUN"
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
it "status --agreement shows the ask an answer replies to"
prog status --agreement --json
has "\"ask\": ${ASK}" "$OUT"
prog status --agreement
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

it "on an unstamped programme log-decision on a product question refuses"
BEFORE="$(decision_count)"
prog log-decision linear:AI-2 --kind product_call --silent --why "obvious"
check "1 hand-item" "$CODE $(printf '%s' "$OUT" | grep -o 'hand-item' | head -1)"
it "the unstamped refusal leaves the item open and writes no decision"
check "\"open\" ${BEFORE}" "$(field 'prog["items"]["linear:AI-2"]["state"]') $(decision_count)"
it "the unstamped product question still needs hand-item"
prog hand-item linear:AI-2 --question "Which crop?" --kind product_call
check '0 "handed"' "$CODE $(field 'prog["items"]["linear:AI-2"]["state"]')"
for kind in product_call product_scope; do
  it "on an unstamped programme a programme-level ${kind} is refused and writes no decision"
  BEFORE="$(decision_count)"
  prog log-decision programme --kind "$kind" --silent --why "obvious"
  check "1 hand-item ${BEFORE}" "$CODE $(printf '%s' "$OUT" | grep -o 'hand-item' | head -1) $(decision_count)"
done

edit 'rec["programme"]["agreement"]["contract_version"] = 1'
FIN_BEFORE="$(finished_count)"
it "on a stamped programme log-decision closes a product question as decided"
prog log-decision linear:AI-3 --kind product_call --silent --why "the terms are silent and it does not change acceptance"
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
prog log-decision linear:AI-3 --kind product_call --silent --why "again"
check "1 decided" "$CODE $(printf '%s' "$OUT" | grep -o 'decided' | head -1)"
it "on a stamped programme a decision on another item leaves its state alone"
prog log-decision linear:AI-1 --kind tool_choice --silent --why x
check '0 "open"' "$CODE $(field 'prog["items"]["linear:AI-1"]["state"]')"

it "deciding a product question that also carries a code change re-matches the code change and stays open"
prog add-item linear:AI-5 --title "Pick and build" --kind product_question --kind fix_only
prog log-decision linear:AI-5 --kind product_call --silent --why "the terms are silent"
check '0 "open" ["fix-only"] "decided"' \
  "$CODE $(field 'prog["items"]["linear:AI-5"]["state"]') $(field 'prog["items"]["linear:AI-5"]["matched_rule"]') $(field 'prog["decisions"][-1]["outcome"]')"

prog add-item linear:AI-6 --title "Product ask" --kind product_question
it "on a stamped programme a non-product kind on a product question records and leaves the item open"
prog log-decision linear:AI-6 --kind tool_choice --silent --why "use the existing crop helper"
check '0 "open" ["product-question"] ["product_question"] null' \
  "$CODE $(field 'prog["items"]["linear:AI-6"]["state"]') $(field 'prog["items"]["linear:AI-6"]["matched_rule"]') $(field 'prog["items"]["linear:AI-6"]["change_kinds"]') $(field 'prog["decisions"][-1]["outcome"]')"

for kind in prod_deploy full_release spend_over_cap merge_around_gate eval_waiver denied_operation; do
  it "the PM cannot record a ${kind} choice itself and is pointed at hand-item"
  BEFORE="$(decision_count)"
  JBEFORE="$(journal_count pm_decided)"
  prog log-decision programme --kind "$kind" --silent --why "tests passed"
  check "1 hand-item ${BEFORE} ${JBEFORE}" \
    "$CODE $(printf '%s' "$OUT" | grep -o 'hand-item' | head -1) $(decision_count) $(journal_count pm_decided)"
done
it "an act-level kind still records"
prog log-decision programme --kind merge_at_gate --silent --why "gate is green"
check '0 "merge_at_gate"' "$CODE $(field 'prog["decisions"][-1]["kind"]')"

edit 'rec["programme"]["agreement"].pop("contract_version")'
prog add-item linear:AI-7 --title "Unstamped product ask" --kind product_question
it "on an unstamped programme a non-product kind on a product question records without refusing"
prog log-decision linear:AI-7 --kind tool_choice --silent --why "use the existing crop helper"
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

for kind in technical_approach work_sequencing worker_coordination tool_choice optimisation_depth product_scope acceptance; do
  it "the newly listed kind ${kind} is still PM-decidable by default"
  prog log-decision programme --kind "$kind" --silent --why "default authority"
  check "0 \"${kind}\"" "$CODE $(field 'prog["decisions"][-1]["kind"]')"
done

# publish <name> <tool_choice level>: a clone whose default branch carries a project layer for tool_choice.
publish() {
  local seed="${WORK}/seed-$1" bare="${WORK}/bare-$1.git" clone="${WORK}/clone-$1"
  mkdir -p "${seed}/.claude"
  printf '{"autonomy": {"tool_choice": {"level": "%s"}}}' "$2" > "${seed}/.claude/auto-protocol.json"
  git -C "$seed" init -q -b main
  git -C "$seed" add -A
  git -C "$seed" -c user.name=t -c user.email=t@t commit -q -m seed
  git clone -q --bare "$seed" "$bare"
  git clone -q "$bare" "$clone"
  printf '%s' "$clone"
}
REPO_ACT="$(publish act act)"
REPO_PROPOSE="$(publish propose propose)"
P_REMIT="$(prompt typed "add repos ${REPO_ACT} and ${REPO_PROPOSE}")"
OUT="$(printf '{"repos": [{"path": "%s"}, {"path": "%s"}]}' "$REPO_ACT" "$REPO_PROPOSE" \
  | "$PY" "$PROG" set-remit --prompt "$P_REMIT" 2>&1)"
it "the remit takes two repos whose project layers set tool_choice to act and to propose"
check "2" "$(field 'len(prog["remit"]["repos"])')"

prog add-item linear:AI-20 --title "On the propose repo" --kind fix_only --repo "$REPO_PROPOSE"
prog add-item linear:AI-21 --title "On the act repo" --kind fix_only --repo "$REPO_ACT"
prog add-item linear:AI-22 --title "No repo" --kind fix_only

it "a project-layer propose on the item's repo refuses a PM decision with no repo flag"
BEFORE="$(decision_count)"
prog log-decision linear:AI-20 --kind tool_choice --silent --why "use the helper"
check "1 hand-item ${BEFORE}" "$CODE $(printf '%s' "$OUT" | grep -o 'hand-item' | head -1) $(decision_count)"
it "an item on the act repo reads only its own repo's layer and records"
prog log-decision linear:AI-21 --kind tool_choice --silent --why "use the helper"
check '0 "linear:AI-21"' "$CODE $(field 'prog["decisions"][-1]["item"]')"
it "an item with no recorded repo is refused when one remit repo sets the kind to propose"
prog log-decision linear:AI-22 --kind tool_choice --silent --why "use the helper"
check "1 hand-item" "$CODE $(printf '%s' "$OUT" | grep -o 'hand-item' | head -1)"
it "a programme-level decision uses the narrowest level across remit repos"
prog log-decision programme --kind tool_choice --silent --why "use the helper"
check "1 hand-item" "$CODE $(printf '%s' "$OUT" | grep -o 'hand-item' | head -1)"
it "log-decision no longer takes --repo as the source of the project layer"
prog log-decision linear:AI-20 --kind tool_choice --silent --why x --repo "$REPO_ACT"
check "2 unknown option --repo" "$CODE $(printf '%s' "$OUT" | grep -o 'unknown option --repo' | head -1)"

P_GRANT="$(prompt typed 'r-tools: you pick the tools for linear:AI-21 yourself')"
prog record-ruling r-tools --kind tool_choice --effect grant --scope "PM picks tools" \
  --applies-to linear:AI-21 --prompt "$P_GRANT"
it "a grant Ruling on tool_choice records with the act baseline of the item's repo"
check "0" "$CODE"
P_NARROW="$(prompt typed 'set tool_choice to propose')"
prog adopt-autonomy tool_choice propose --prompt "$P_NARROW"
it "Covers AE6. with personal Authority narrowed to propose, log-decision on the granted item is refused as a conflict"
BEFORE="$(decision_count)"
prog log-decision linear:AI-21 --kind tool_choice --silent --why "use the helper"
check "1 (conflict) hand-item ${BEFORE}" \
  "$CODE $(printf '%s' "$OUT" | grep -o '(conflict)' | head -1) $(printf '%s' "$OUT" | grep -o 'hand-item' | head -1) $(decision_count)"
rm -f "$CLAUDE_AUTO_PERSONAL_PROTOCOL"

it "the who-decides gate has exactly one caller in shipped code"
check "1" "$(grep -rnE '(^|[^_a-zA-Z.])who_decides\(|\.who_decides\(' "${AUTO_ROOT}/lib" "${AUTO_ROOT}/hooks" 2>/dev/null \
  | grep -v 'def who_decides' | wc -l | tr -d ' ')"
it "programme_decisions reads no autonomy map: the Authority level arrives as plain data"
check "0" "$(grep -cE '"autonomy"' "${AUTO_ROOT}/lib/programme_decisions.py")"
it "no other shipped module looks up a kind in the merged autonomy map to gate a decision"
check "programme_rulings.py" "$(grep -lE '\[\"autonomy\"\]\.get\(kind\)|get\(\"autonomy\"\).*\.get\(kind\)' "${AUTO_ROOT}"/lib/*.py | xargs -n1 basename | sort | tr '\n' ' ' | sed 's/ $//')"

# The who-decides gate, called with plain data. MUTATE patches one branch out in-process.
gate() {
  MUTATE="${MUTATE:-}" run_py "$@" <<'EOF'
pd = load_lib_module("programme_decisions")
mutate = os.environ.get("MUTATE")
if mutate == "protected":
    pd._protected = lambda kind: False
elif mutate == "restrict":
    pd._restricting = lambda rulings: []
NOW = "2026-10-22T12:00:00Z"
def ruling(effect, kind, until=None, baseline="act", items=("linear:AI-1",), rid="r1"):
    return {"id": rid, "effect": effect, "kind": kind, "items": list(items), "until": until,
            "baseline": baseline}
def scenarios(kind):
    return {
        "none": [],
        "decided": [ruling("decided", kind)],
        "grant": [ruling("grant", kind)],
        "restrict": [ruling("restrict", kind)],
        "expired-grant": [ruling("grant", kind, until="2026-10-01T00:00:00Z")],
        "grant+restrict": [ruling("grant", kind), ruling("restrict", kind, rid="r2")],
    }
mode = args[0]
if mode == "table":
    for kind in pd.DECISION_KINDS:
        for name, rulings in scenarios(kind).items():
            v = pd.who_decides(kind, "linear:AI-1", level="act", rulings=rulings, now=NOW, accepted=True)
            print(kind, name, v["decider"], v["reason"])
else:
    kind, level, accepted, spec = args[1], args[2], args[3] == "1", json.loads(args[4])
    v = pd.who_decides(kind, "linear:AI-1", level=None if level == "-" else level,
                       rulings=[ruling(**r) for r in spec], now=NOW, accepted=accepted)
    print(v["decider"], v["level"] or "-", v["reason"], v["conflict"])
EOF
}

expected_row() {
  local kind="$1" scenario="$2" protected="$3"
  if [ "$protected" = 1 ]; then echo "$kind $scenario shawn protected"; return; fi
  case "$scenario" in
    restrict|grant+restrict) echo "$kind $scenario shawn restrict" ;;
    grant) echo "$kind $scenario pm grant" ;;
    *) echo "$kind $scenario pm authority" ;;
  esac
}

KINDS="$(run_py <<'EOF'
pd = load_lib_module("programme_decisions")
print(" ".join(pd.DECISION_KINDS))
EOF
)"
PROTECTED=" prod_deploy full_release spend_over_cap merge_around_gate denied_operation "
SCENARIOS="none decided grant restrict expired-grant grant+restrict"

it "the protected kinds are exactly the five decision kinds no layer or Ruling can hand to the PM"
check "['denied_operation', 'full_release', 'merge_around_gate', 'prod_deploy', 'spend_over_cap'] True" "$(run_py <<'EOF'
pd = load_lib_module("programme_decisions")
print(sorted(pd.PROTECTED_KINDS), set(pd.PROTECTED_KINDS) <= set(pd.DECISION_KINDS))
EOF
)"

it "the truth table covers 20 decision kinds"
check 20 "$(printf '%s\n' $KINDS | wc -l | tr -d ' ')"

table_mismatches() {
  local got="$1" kind scenario prot
  for kind in $KINDS; do
    case "$PROTECTED" in *" $kind "*) prot=1 ;; *) prot=0 ;; esac
    for scenario in $SCENARIOS; do
      printf '%s\n' "$got" | grep -F -x -q -- "$(expected_row "$kind" "$scenario" "$prot")" \
        || printf '%s %s\n' "$kind" "$scenario"
    done
  done
}

TABLE="$(gate table)"
for kind in $KINDS; do
  case "$PROTECTED" in *" $kind "*) label="protected" ;; *) label="not protected" ;; esac
  it "truth table: ${kind} (${label}) under no Ruling, decided, grant, restrict, expired grant, grant plus restrict"
  check "" "$(table_mismatches "$TABLE" | grep "^${kind} ")"
done

it "mutation: with the protected check patched out exactly the protected rows fail"
check "$(for k in $PROTECTED; do for s in $SCENARIOS; do echo "$k $s"; done; done | sort)" \
  "$(table_mismatches "$(MUTATE=protected gate table)" | sort)"
it "mutation: with the restrict branch patched out exactly the unprotected restrict rows fail"
check "$(for k in $KINDS; do case "$PROTECTED" in *" $k "*) ;; *) echo "$k restrict"; echo "$k grant+restrict" ;; esac; done | sort)" \
  "$(table_mismatches "$(MUTATE=restrict gate table)" | sort)"

for kind in product_call product_scope; do
  it "${kind} on an unaccepted programme stays with Shawn even with a grant Ruling"
  check "shawn propose unaccepted False" "$(gate one "$kind" act 0 "[{\"effect\":\"grant\",\"kind\":\"$kind\"}]")"
  it "${kind} on an accepted programme follows Authority"
  check "shawn propose authority False" "$(gate one "$kind" propose 1 '[]')"
done
it "default Authority (act) on an accepted programme makes product_call PM-decidable"
check "pm act authority False" "$(gate one product_call act 1 '[]')"
it "a non-product kind on an unaccepted programme follows Authority"
check "pm act authority False" "$(gate one tool_choice act 0 '[]')"

it "AE3: an act level on prod_deploy from any Authority layer still returns Shawn decides"
check "shawn never protected False" "$(gate one prod_deploy act 1 '[]')"
it "AE4: a grant Ruling on prod_deploy still returns Shawn decides"
check "shawn never protected False" "$(gate one prod_deploy act 1 '[{"effect":"grant","kind":"prod_deploy"}]')"

it "a grant whose kind Authority now holds at propose returns the narrower level and a conflict"
check "shawn propose conflict True" "$(gate one tool_choice propose 1 '[{"effect":"grant","kind":"tool_choice","baseline":"act"}]')"
it "a grant whose kind Authority now holds at act_and_tell leaves the PM deciding at act_and_tell with a conflict"
check "pm act_and_tell conflict True" "$(gate one tool_choice act_and_tell 1 '[{"effect":"grant","kind":"tool_choice","baseline":"act"}]')"
it "a grant made while Authority was already at propose returns PM decides, not a conflict"
check "pm act grant False" "$(gate one tool_choice propose 1 '[{"effect":"grant","kind":"tool_choice","baseline":"propose"}]')"
it "an expired grant behaves as no Ruling"
check "shawn propose authority False" "$(gate one tool_choice propose 1 '[{"effect":"grant","kind":"tool_choice","until":"2026-10-01T00:00:00Z"}]')"
it "a grant whose end date is the current time has expired"
check "shawn propose authority False" "$(gate one tool_choice propose 1 '[{"effect":"grant","kind":"tool_choice","until":"2026-10-22T12:00:00Z"}]')"
it "a grant with a later end date still applies"
check "pm act grant False" "$(gate one tool_choice act 1 '[{"effect":"grant","kind":"tool_choice","until":"2026-11-01T00:00:00Z"}]')"
it "an end date the gate cannot read refuses and names the Ruling"
has "Ruling 'r1' has an end date the gate cannot read" "$(gate one tool_choice act 1 '[{"effect":"restrict","kind":"tool_choice","until":"next week"}]')"
it "a grant plus a restrict on the same item and kind returns Shawn decides"
check "shawn propose restrict False" "$(gate one tool_choice act 1 '[{"effect":"grant","kind":"tool_choice"},{"effect":"restrict","kind":"tool_choice","rid":"r2"}]')"
it "a decided Ruling alone falls through to the Authority level"
check "shawn propose authority False" "$(gate one tool_choice propose 1 '[{"effect":"decided","kind":"tool_choice"}]')"
it "a Ruling for another item does not apply"
check "shawn propose authority False" "$(gate one tool_choice propose 1 '[{"effect":"grant","kind":"tool_choice","items":["linear:AI-2"]}]')"
it "a Ruling for another kind does not apply"
check "pm act authority False" "$(gate one tool_choice act 1 '[{"effect":"restrict","kind":"work_sequencing"}]')"
it "act_and_tell Authority lets the PM decide at that level"
check "pm act_and_tell authority False" "$(gate one tool_choice act_and_tell 1 '[]')"
it "never Authority keeps the kind with Shawn"
check "shawn never authority False" "$(gate one tool_choice never 1 '[]')"
it "a kind with no Authority level lets the PM decide, as log-decision does today"
check "pm - authority False" "$(gate one tool_choice - 1 '[]')"
it "an unknown kind refuses"
has "unknown decision kind" "$(gate one no_such_kind act 1 '[]')"
it "the refusal keeps the hand-item message shape"
check "kind 'prod_deploy' stays with Shawn (protected); the PM does not record it as its own: use hand-item" "$(run_py <<'EOF'
pd = load_lib_module("programme_decisions")
v = pd.who_decides("prod_deploy", "linear:AI-1", level="act", rulings=[], now="2026-10-22T12:00:00Z", accepted=True)
print(pd.refusal("prod_deploy", v))
EOF
)"

echo ""
echo "programme-decisions.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
