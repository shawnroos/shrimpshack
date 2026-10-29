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

echo "programme-asks.test.sh"

WORK="$(mktemp -d -t auto-programme-asks.XXXXXX)"
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
CALLS="${WORK}/calls.log"
mkdir -p "$FAKES"
for tool in board herdr; do
  cat > "${FAKES}/${tool}" <<EOF
#!/bin/sh
printf '%s %s\n' "${tool}" "\$*" >> "${CALLS}"
exit 0
EOF
  chmod +x "${FAKES}/${tool}"
done
export PATH="${FAKES}:${PATH}"
: > "$CALLS"

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
VIEW="${CLAUDE_AUTO_DATA_DIR}/programmes/${RUN}/views/view.json"

prompt_at() {
  run_py "$RUN" "$1" "$2" <<'EOF'
import datetime
run, minutes, text = args
when = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(minutes=int(minutes))
print(fixture_prompt(run, "sess-pm", text, "typed", now=when)["prompt_id"])
EOF
}

field() {
  run_py "$RUN" "$1" <<'EOF'
run, expr = args
items = record(run)["programme"]["items"]
print(json.dumps(eval(expr), sort_keys=True))
EOF
}

edit() {
  run_py "$RUN" "$1" <<'EOF'
run, expr = args
sys.path.insert(0, os.path.join(sys.argv[1], "tests", "helpers"))
import programme_records
programme_records.edit(run, expr, globals())
EOF
}

journal_count() {
  run_py "$RUN" "$1" <<'EOF'
print(len([r for r in pj.read(args[0]) if r["kind"] == args[1]]))
EOF
}

view_q() {
  "$PY" - "$VIEW" "$1" <<'EOF'
import json, sys
v = json.load(open(sys.argv[1]))
asks = {a["item"]: a for a in v.get("asks") or []}
print(json.dumps(eval(sys.argv[2]), sort_keys=True))
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
ask() { field "items[\"$1\"][\"handed\"]$2"; }
run_brief() {
  run_py "$RUN" "$1" <<'EOF'
import types
ps = load_lib_module("programme_sources")
try:
    ps._brief_tail(types.SimpleNamespace(ProgrammeError=RuntimeError), record(args[0])["programme"], None, [args[1]], [])
    print("listed")
except RuntimeError as exc:
    print("refused " + ("voided" if "voided" in str(exc) else str(exc)))
EOF
}
fp() { ask "$1" '["fingerprint"]' | tr -d '"'; }

A="linear:AI-901"
prog add-item "$A" --title "Crop default" --kind fix_only
it "hand-item takes structured fields"
prog hand-item "$A" --kind merge_at_gate --question "Merge PR #12 (Crop default) into main?" \
  --option "ship | merges PR #12 into main | 10 minutes of CI on main" \
  --option "decline | closes the PR | the crop fix waits a week" \
  --if-nothing "the PR stays open and the issue stays in review" \
  --recommend "ship" --recommend-why "all required checks passed and review approved" \
  --risk "the flag default is not verified on prod" \
  --evidence "merge state CLEAN" --evidence "review APPROVED" \
  --pr-url "https://github.com/org/repo/pull/12" --pr-title "Crop default" \
  --issue-url "https://linear.app/org/issue/AI-901" --issue-title "Crop default" \
  --readiness "abc123def4567890"
check 0 "$CODE"
it "the record keeps every structured field"
check '[[["ship", "merges PR #12 into main", "10 minutes of CI on main"], ["decline", "closes the PR", "the crop fix waits a week"]], "the PR stays open and the issue stays in review", "ship", "all required checks passed and review approved", ["the flag default is not verified on prod"], ["merge state CLEAN", "review APPROVED"], {"title": "Crop default", "url": "https://github.com/org/repo/pull/12"}, {"title": "Crop default", "url": "https://linear.app/org/issue/AI-901"}, "abc123def4567890"]' \
  "$(field "[[[o['label'], o['effect'], o['cost']] for o in items['$A']['handed']['options']]] + [items['$A']['handed'][k] for k in ('if_nothing', 'recommendation', 'recommendation_why', 'risks', 'evidence', 'pr', 'issue', 'readiness')]")"
it "the ask carries a 16-hex fingerprint, facts_at equal to at, no shown mark and no superseded answers"
check '[16, true, null, []]' "$(field "[len(items['$A']['handed']['fingerprint']), items['$A']['handed']['facts_at'] == items['$A']['handed']['at'], items['$A']['handed']['shown'], items['$A']['handed']['superseded_answers']]")"
it "the ask stores the exact replies, by the item's unique title"
check '{"decline": "decline Crop default", "ship": "ship Crop default"}' "$(ask "$A" '["replies"]')"
it "hand-item prints the fingerprint and the replies"
has "\"fingerprint\": \"$(fp "$A")\"" "$OUT"
has '"ship": "ship Crop default"' "$OUT"

it "the view's asks entry carries every field"
check '["open", "Crop default (linear:AI-901)", 2, "ship", "all required checks passed and review approved", "the PR stays open and the issue stays in review", ["the flag default is not verified on prod"], 2, "https://github.com/org/repo/pull/12", "https://linear.app/org/issue/AI-901", "abc123def4567890", true, null, false, "ship Crop default"]' \
  "$(view_q "[asks['$A'][k] for k in ('status', 'name')] + [len(asks['$A']['options']), asks['$A']['recommendation'], asks['$A']['recommendation_why'], asks['$A']['if_nothing'], asks['$A']['risks'], len(asks['$A']['evidence']), asks['$A']['pr']['url'], asks['$A']['issue']['url'], asks['$A']['readiness'], asks['$A']['facts_at'] == asks['$A']['at'], asks['$A']['shown'], asks['$A']['shown_current'], asks['$A']['replies']['ship']]")"
it "the view entry stores timestamps and no computed age"
lacks '"age' "$(view_q "asks['$A']")"
it "the view keeps view_format 3"
check 3 "$(view_q 'v["view_format"]')"

it "the Decisions for Shawn rows show the options, recommendation, if-nothing outcome and reply"
ROWS="$("$PY" "$PROG" status 2>&1)"
has "Crop default (linear:AI-901)" "$ROWS"
has "option ship: merges PR #12 into main (cost: 10 minutes of CI on main)" "$ROWS"
has "recommend ship: all required checks passed and review approved" "$ROWS"
has "if nothing: the PR stays open and the issue stays in review" "$ROWS"
has "reply: \"ship Crop default\" or \"decline Crop default\"" "$ROWS"

it "the herdr notification title names the item by name and id"
: > "$CALLS"
prog add-item herdr:w2-p40 --title "Pane cleanup"
prog hand-item herdr:w2-p40 --question "Keep this pane?" --kind product_call
has "auto: Pane cleanup (herdr:w2-p40) needs you" "$(cat "$CALLS")"

L="linear:AI-902"
prog add-item "$L" --title "Long ask" --kind fix_only
EFFECT="$(printf 'e%.0s' $(seq 1 400))"
NOTHING="$(printf 'n%.0s' $(seq 1 500))"
WHY="$(printf 'w%.0s' $(seq 1 500))"
EVID="$(printf 'v%.0s' $(seq 1 400))"
it "a 1800-character ask across fields is stored whole"
prog hand-item "$L" --kind product_call --question "Long?" --option "ship | ${EFFECT}" \
  --if-nothing "$NOTHING" --recommend ship --recommend-why "$WHY" --evidence "$EVID"
check '[0, 400, null, 500, 500, 400]' "[$CODE, $(field "[len(items['$L']['handed']['options'][0]['effect']), items['$L']['handed']['options'][0]['cost'], len(items['$L']['handed']['if_nothing']), len(items['$L']['handed']['recommendation_why']), len(items['$L']['handed']['evidence'][0])]" | tr -d '[]')]"
it "no decision detail row for the long ask is cut by the view"
check "0" "$(view_q 'sum(1 for d in v["model"]["decisions_for_shawn"] if d.get("item") == "'"$L"'" for line in d.get("details") or [] if line.endswith("…") or line.endswith("..."))')"
it "the long ask's view rows still carry every field's full text"
check "\"True True True\"" "$(view_q '" ".join(str(any(x in line for d in v["model"]["decisions_for_shawn"] if d.get("item") == "'"$L"'" for line in d.get("details") or [])) for x in ("e" * 400, "n" * 500, "w" * 500))')"
it "a field over its own cap is refused, not cut"
prog add-item linear:AI-903 --title "Too long" --kind fix_only
prog hand-item linear:AI-903 --kind product_call --question "Long?" --if-nothing "${NOTHING}x"
check "2 open" "$CODE $(field 'items["linear:AI-903"]["state"]' | tr -d '"')"
has "--if-nothing" "$OUT"
it "an option without an effect is refused"
prog hand-item linear:AI-903 --kind product_call --question "Q?" --option "ship"
check "2 open" "$CODE $(field 'items["linear:AI-903"]["state"]' | tr -d '"')"

FP1="$(fp "$A")"
it "ask-shown with a fingerprint that is not current is refused"
prog ask-shown "$A" --fingerprint 0000000000000000
check '1 null' "$CODE $(ask "$A" '["shown"]')"
it "ask-shown with the current fingerprint records it"
prog ask-shown "$A" --fingerprint "$FP1"
check "0 \"${FP1}\"" "$CODE $(ask "$A" '["shown"]["fingerprint"]')"
it "the view marks the posted ask as current"
check true "$(view_q "asks['$A']['shown_current']")"
it "ask-shown is journaled"
check 1 "$(journal_count ask_shown)"

edit "prog['items']['$A']['handed']['facts_at'] = '2026-01-01T00:00:00Z'"
it "update-ask with the same facts leaves the fingerprint and facts_at unchanged (AE2)"
prog update-ask "$A" --evidence "merge state CLEAN" --evidence "review APPROVED"
check "0 ${FP1} \"2026-01-01T00:00:00Z\"" "$CODE $(fp "$A") $(ask "$A" '["facts_at"]')"
has '"changed": false' "$OUT"
it "update-ask with the same facts writes no journal row"
check 0 "$(journal_count ask_updated)"
it "the view still marks the ask as shown"
check true "$(view_q "asks['$A']['shown_current']")"
it "update-ask with a changed check outcome changes the fingerprint and moves facts_at"
prog update-ask "$A" --evidence "merge state BLOCKED" --evidence "required check build FAILURE"
FP2="$(fp "$A")"
check "0 changed moved" "$CODE $([ "$FP2" != "$FP1" ] && echo changed) $([ "$(ask "$A" '["facts_at"]')" != '"2026-01-01T00:00:00Z"' ] && echo moved)"
it "update-ask keeps the fields it was not given"
check '"ship"' "$(ask "$A" '["recommendation"]')"
it "the view shows the shown fingerprint as stale"
check "false \"${FP1}\" \"${FP2}\"" "$(view_q "asks['$A']['shown_current']") $(view_q "asks['$A']['shown']['fingerprint']") $(view_q "asks['$A']['fingerprint']")"
it "update-ask with no fact is a usage error"
prog update-ask "$A"
check 2 "$CODE"
it "update-ask on an item with no ask is refused"
prog update-ask linear:AI-903 --evidence "x"
check 1 "$CODE"

it "ask-relayed before answer-handed is refused"
prog ask-relayed "$A"
check 1 "$CODE"
has "answer-handed" "$OUT"

it "a name reply typed before the ask's current facts is refused"
edit "prog['items']['$A']['handed']['facts_at'] = '2099-01-01T00:00:00Z'"
prog answer-handed "$A" --choice ship --prompt "$(prompt_at 0 'ship Crop default')"
check "1 handed" "$CODE $(field "items['$A']['state']" | tr -d '"')"
has "before the ask's current facts" "$OUT"
edit "prog['items']['$A']['handed']['facts_at'] = '2026-01-01T00:00:00Z'"

it "answer-handed by the stored reply records the answer"
prog answer-handed "$A" --choice ship --prompt "$(prompt_at 1 'ship Crop default')"
check "0 open" "$CODE $(field "items['$A']['state']" | tr -d '"')"
DEC1="$(ask "$A" '["answered"]["decision_id"]' | tr -d '"')"
it "the view lists the answered, unrelayed ask so the sweep can relay it"
check '["answered", "ship", null]' "$(view_q "[asks['$A']['status'], asks['$A']['answered']['choice'], asks['$A']['answered'].get('relayed_at')]")"

it "update-ask with a changed readiness voids the unrelayed answer (AE12)"
prog update-ask "$A" --readiness "ffff000011112222"
check "0 handed null" "$CODE $(field "items['$A']['state']" | tr -d '"') $(ask "$A" '["answered"]')"
it "the voided answer is kept under superseded_answers"
check "[1, \"${DEC1}\", \"ship\"]" "$(field "[len(items['$A']['handed']['superseded_answers']), items['$A']['handed']['superseded_answers'][0]['decision_id'], items['$A']['handed']['superseded_answers'][0]['choice']]")"
it "the void is journaled as ask_answer_voided"
check 1 "$(journal_count ask_answer_voided)"
it "the voided decision is marked"
check true "$(field "bool([d for d in record(run)['programme']['decisions'] if d['id'] == '${DEC1}'][0].get('voided_at'))")"
it "the view lists the ask as open again"
check '"open"' "$(view_q "asks['$A']['status']")"
it "a second typed answer records"
prog answer-handed "$A" --choice ship --prompt "$(prompt_at 2 'ship Crop default')"
check "0 open" "$CODE $(field "items['$A']['state']" | tr -d '"')"

it "a worker brief that cites the voided decision is refused, not listed as settled"
check "refused voided" "$(run_brief "$DEC1")"

it "update-ask never voids an answer on an item that has finished"
edit "prog['items']['$A']['state'] = 'done'"
prog update-ask "$A" --readiness "aaaa000011112222"
check "1 done" "$CODE $(field "items['$A']['state']" | tr -d '"')"
has "reopen" "$OUT"
edit "prog['items']['$A']['state'] = 'open'"

it "ask-relayed after answer-handed records relayed_at"
prog ask-relayed "$A"
check "0 true" "$CODE $(field "bool(items['$A']['handed']['answered'].get('relayed_at'))")"
it "ask-relayed is journaled"
check 1 "$(journal_count ask_relayed)"
it "a second ask-relayed is refused"
prog ask-relayed "$A"
check 1 "$CODE"
it "the view no longer lists a relayed ask"
check false "$(view_q "'$A' in asks")"
it "update-ask on a relayed ask is refused"
prog update-ask "$A" --readiness "0000111122223333"
check "1 open" "$CODE $(field "items['$A']['state']" | tr -d '"')"

B="linear:AI-910"
prog add-item "$B" --title "Flag rollout plan" --kind fix_only
prog hand-item "$B" --kind product_call --question "Roll out?"
it "a unique title gives a name reply"
check '"ship Flag rollout plan"' "$(ask "$B" '["replies"]["ship"]')"
it "a second item with the same title switches the first ask's reply to its id"
prog add-item linear:AI-911 --title "Flag rollout plan" --kind fix_only
check '"ship linear:AI-910"' "$(ask "$B" '["replies"]["ship"]')"
it "the view shows the id reply too"
check '"decline linear:AI-910"' "$(view_q "asks['$B']['replies']['decline']")"

it "an answered decline voided by update-ask returns the item to handed"
D="linear:AI-920"
prog add-item "$D" --title "Decline path" --kind fix_only
prog hand-item "$D" --kind product_call --question "Do it?"
prog answer-handed "$D" --choice decline --prompt "$(prompt_at 1 'decline Decline path')"
prog update-ask "$D" --risk "new fact"
check "0 handed null" "$CODE $(field "items['$D']['state']" | tr -d '"') $(field "items['$D'].get('dropped_reason')")"

it "describe lists the ask verbs"
DESC="$("$PY" "$PROG" describe 2>&1)"
has '"update-ask"' "$DESC"
has '"ask-shown"' "$DESC"
has '"ask-relayed"' "$DESC"

it "no verb call crashed with a traceback"
check "" "$CRASHES"

echo ""
echo "programme-asks.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
