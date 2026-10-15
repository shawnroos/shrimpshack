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

echo "programme-items.test.sh"

WORK="$(mktemp -d -t auto-programme-items.XXXXXX)"
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
  upper="$(printf '%s' "$tool" | tr '[:lower:]' '[:upper:]')"
  cat > "${FAKES}/${tool}" <<EOF
#!/bin/sh
printf '%s %s\n' "${tool}" "\$*" >> "${CALLS}"
exit "\${FAKE_${upper}_EXIT:-0}"
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
items = prog["items"]
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
items = rec["programme"]["items"]
exec(expr)
with open(path, "w") as fh:
    json.dump(rec, fh)
EOF
}

journal_last() {
  run_py "$RUN" "$1" <<'EOF'
rows = [r for r in pj.read(args[0]) if r["kind"] == args[1]]
print(json.dumps(rows[-1] if rows else None, sort_keys=True))
EOF
}

journal_count() {
  run_py "$RUN" "$1" <<'EOF'
print(len([r for r in pj.read(args[0]) if r["kind"] == args[1]]))
EOF
}

predicate() {
  run_py "$RUN" "$1" <<'EOF'
pp = load_lib_module("programme_predicate")
rec = record(args[0])
size = int(args[1]) if args[1] != "-" else None
print(json.dumps(pp.compute(rec, inbox_size=size), sort_keys=True))
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

P_TYPED="$(prompt typed 'drop AI-801, we are not doing that')"
P_VAGUE="$(prompt typed 'drop it, we are not doing that')"
P_CRON="$(prompt cron 'wake up and sweep the space')"

it "describe lists the item, wait, inbox and working-model verbs"
DESC="$("$PY" "$PROG" describe 2>/dev/null)"
VERBS="$("$PY" -c 'import json,sys; print(" ".join(sorted(json.load(sys.stdin)["verbs"])))' <<< "$DESC" 2>&1)"
for verb in add-item alias-item merge-item drop-item reopen-item set-waiting watcher-beat hand-item answer-handed claim set-now queue mark-read record-tested-build set-source; do
  case " $VERBS " in *" $verb "*) ;; *) VERBS="MISSING:$verb $VERBS" ;; esac
done
lacks "MISSING:" "$VERBS"

it "no verb sets an item done"
lacks "set-done" "$VERBS"

it "add-item stores the matched rule and unknown deliverables"
prog add-item linear:AI-800 --title "Fix the crop" --kind fix_only
check 0 "$CODE"
it "the matched rule is the fix-only rule"
check '["fix-only"]' "$(field 'items["linear:AI-800"]["matched_rule"]')"
it "each required deliverable starts unknown"
check '{"merged": "unknown", "recorded": "unknown", "verified": "unknown"}' "$(field '{k: v["result"] for k, v in items["linear:AI-800"]["deliverables"].items()}')"
it "add-item is journaled"
has '"linear:AI-800"' "$(journal_last item_added)"

it "add-item with no kinds leaves the item unmatched and open"
prog add-item herdr:w2/p26 --title "pane with no issue" --pane w2/p26 --session sess-w1
check '[null, "open", {}]' "$(field '[items["herdr:w2/p26"]["matched_rule"], items["herdr:w2/p26"]["state"], items["herdr:w2/p26"]["deliverables"]]')"
it "add-item records the owner and the session"
check '["w2/p26", "sess-w1"]' "$(field '[items["herdr:w2/p26"]["owner"]["pane"], items["herdr:w2/p26"]["sessions"][0]["session_id"]]')"

it "add-item sanitizes escape sequences out of the title"
prog add-item linear:AI-801 --title $'Clean \x1b[31mred\x1b[0m title\x07' --kind fix_only
check '"Clean red title"' "$(field 'items["linear:AI-801"]["title"]')"

it "an item id containing .. is refused"
prog add-item 'herdr:../../etc' --title x
check 1 "$CODE"
it "an item id containing a newline is refused"
prog add-item $'linear:AI-1\n' --title x
check 1 "$CODE"
it "an item id with an escape sequence is refused"
prog add-item $'linear:AI-1\x1b[0m' --title x
check 1 "$CODE"
it "an item id without a source is refused"
prog add-item AI-1 --title x
check 1 "$CODE"
it "refused ids write no item"
check 3 "$(field 'len(items)')"

it "an unknown change kind is refused"
prog add-item linear:AI-900 --title x --kind made_up
check 1 "$CODE"

edit 'items["herdr:w2/p26"]["deliverables"] = {"merged": {"result": "confirmed", "sha": "abc"}}; items["linear:AI-800"]["sessions"] = [{"session_id": "sess-w0", "pane": "w2/p20"}]'
edit 'rec["programme"]["working_model"]["queue"] = [{"id": "q1", "action": "start_worker", "item": "herdr:w2/p26"}]'

it "alias-item onto an existing item merges them"
prog alias-item herdr:w2/p26 linear:AI-800
check 0 "$CODE"
it "the old id is gone and kept as an alias"
check '[false, ["herdr:w2/p26"]]' "$(field '["herdr:w2/p26" in items, items["linear:AI-800"]["aliases"]]')"
it "sessions are combined"
check '["sess-w0", "sess-w1"]' "$(field 'sorted(s["session_id"] for s in items["linear:AI-800"]["sessions"])')"
it "evidence is combined and confirmed evidence wins"
check '"confirmed"' "$(field 'items["linear:AI-800"]["deliverables"]["merged"]["result"]')"
it "queue references follow the new id"
check '"linear:AI-800"' "$(field 'prog["working_model"]["queue"][0]["item"]')"
it "the merge is journaled"
has '"herdr:w2/p26"' "$(journal_last item_aliased)"

it "an alias id resolves to its item"
prog set-now "checking the crop fix" --item herdr:w2/p26
check '"linear:AI-800"' "$(field 'prog["working_model"]["doing"]["item"]')"

it "alias-item onto a new id renames the item"
prog add-item herdr:w2/p27 --title "another pane"
prog alias-item herdr:w2/p27 linear:AI-802
check '[false, true, ["herdr:w2/p27"]]' "$(field '["herdr:w2/p27" in items, "linear:AI-802" in items, items["linear:AI-802"]["aliases"]]')"

it "merge-item folds one item into another"
prog add-item gh:web-app#17 --title "PR 17" --session sess-w3
prog merge-item gh:web-app#17 linear:AI-801
check '[false, ["gh:web-app#17"]]' "$(field '["gh:web-app#17" in items, items["linear:AI-801"]["aliases"]]')"
it "merge-item of an item into itself is refused"
prog merge-item linear:AI-801 linear:AI-801
check 1 "$CODE"

it "drop-item on an issue-backed item with an open deliverable and no prompt is refused"
prog drop-item linear:AI-801 --reason "not needed"
check 1 "$CODE"
it "the refused drop leaves the item open"
check '"open"' "$(field 'items["linear:AI-801"]["state"]')"
it "drop-item with a cron prompt is refused"
prog drop-item linear:AI-801 --reason "not needed" --prompt "$P_CRON"
check 1 "$CODE"

it "drop-item on a herdr item with a reason is allowed"
prog add-item herdr:w2/p30 --title "scratch pane"
prog drop-item herdr:w2/p30 --reason "scratch pane, nothing to ship"
check '["dropped", "scratch pane, nothing to ship"]' "$(field '[items["herdr:w2/p30"]["state"], items["herdr:w2/p30"]["dropped_reason"]]')"
it "the drop is journaled"
has '"herdr:w2/p30"' "$(journal_last item_dropped)"
it "drop-item without a reason is a usage error"
prog drop-item herdr:w2/p27
check 2 "$CODE"

it "drop-item citing a typed prompt that does not name the item is refused"
prog drop-item linear:AI-801 --reason "Shawn dropped it" --prompt "$P_VAGUE"
check "1 open" "$CODE $(field 'items["linear:AI-801"]["state"]' | tr -d '"')"
has "AI-801" "$OUT"

it "drop-item on an issue-backed item with a typed prompt is allowed"
prog drop-item linear:AI-801 --reason "Shawn dropped it" --prompt "$P_TYPED"
check '"dropped"' "$(field 'items["linear:AI-801"]["state"]')"
it "the drop cites the prompt"
has "\"cites\": [\"${P_TYPED}\"]" "$(journal_last item_dropped)"

it "reopen-item on a dropped item with no prompt is refused"
prog reopen-item linear:AI-801
check "1 typed prompt" "$CODE $(printf '%s' "$OUT" | grep -o 'typed prompt' | head -1)"
it "reopen-item citing a typed prompt that names another item is refused"
P_OTHER_ITEM="$(prompt typed 'reopen AI-802')"
prog reopen-item linear:AI-801 --prompt "$P_OTHER_ITEM"
check "1 dropped" "$CODE $(field 'items["linear:AI-801"]["state"]' | tr -d '"')"

it "reopen-item with a typed prompt reopens the dropped item"
prog reopen-item linear:AI-801 --prompt "$P_TYPED"
check '["open", null]' "$(field '[items["linear:AI-801"]["state"], items["linear:AI-801"]["dropped_reason"]]')"
it "reopen-item on an item that is not dropped is refused"
prog reopen-item linear:AI-801 --prompt "$P_TYPED"
check 1 "$CODE"

it "set-waiting with a watcher records the wait and the watcher"
prog set-waiting linear:AI-800 --who ci --watcher w-ci --process-id 4242
check '["waiting", "ci", "w-ci", "4242", "linear:AI-800"]' "$(field '[items["linear:AI-800"]["state"], items["linear:AI-800"]["waiting_on"]["who"], items["linear:AI-800"]["waiting_on"]["watcher"], prog["watchers"]["w-ci"]["process_id"], prog["watchers"]["w-ci"]["item"]]')"
edit 'rec["programme"]["watchers"]["w-ci"]["last_beat_at"] = "2020-01-01T00:00:00Z"'
it "a stale watcher leaves the wait unwatched"
has '"unwatched_wait"' "$(predicate -)"
it "watcher-beat updates the heartbeat"
prog watcher-beat w-ci
lacks '2020-01-01' "$(field 'prog["watchers"]["w-ci"]["last_beat_at"]')"
it "a fresh heartbeat makes the wait watched"
lacks '"unwatched_wait"' "$(predicate -)"
it "watcher-beat does not journal"
check 0 "$(journal_count watcher_beat 2>/dev/null || echo 0)"
it "a beat for an unknown watcher is refused"
prog watcher-beat w-nobody
check 1 "$CODE"
it "watcher-beat with a process id registers a programme-level watcher"
prog watcher-beat w-sweep --process-id 99
check '"99"' "$(field 'prog["watchers"]["w-sweep"]["process_id"]')"
it "a watcher id that is not a safe name is refused"
prog watcher-beat '../w' --process-id 1
check 1 "$CODE"
it "a task id registered with the cron prompt is a cron watcher"
prog watcher-beat w-cron --task-id c-1 --prompt "Run the programme sweep."
check '"cron"' "$(field 'prog["watchers"]["w-cron"]["kind"]')"
it "a task id with no prompt is a Monitor watcher"
prog watcher-beat w-mon --task-id bh1i1vbv7
check '"monitor"' "$(field 'prog["watchers"]["w-mon"]["kind"]')"
it "--kind names the watcher kind outright"
prog watcher-beat w-mon2 --task-id t-2 --kind cron
check '"cron"' "$(field 'prog["watchers"]["w-mon2"]["kind"]')"
it "a beat with no task id keeps the recorded kind"
prog watcher-beat w-mon
check '"monitor"' "$(field 'prog["watchers"]["w-mon"]["kind"]')"
it "a process-only watcher records no task kind"
check 'null' "$(field 'prog["watchers"]["w-sweep"].get("kind")')"
it "an unknown --kind is refused"
prog watcher-beat w-bad --task-id t-3 --kind daemon
check 1 "$CODE"
it "set-waiting with a Monitor task id records a Monitor watcher"
prog set-waiting linear:AI-800 --who ci --watcher w-ci2 --task-id m-4
check '"monitor"' "$(field 'prog["watchers"]["w-ci2"]["kind"]')"

it "set-waiting --clear returns the item to open"
prog set-waiting linear:AI-800 --clear
check '["open", null]' "$(field '[items["linear:AI-800"]["state"], items["linear:AI-800"]["waiting_on"]]')"

it "set-waiting on a blocker records the kind and trace id"
prog set-waiting linear:AI-802 --who team-infra --reporter team-infra --blocker --trace-id tr-77
check '["blocker", "tr-77", "team-infra"]' "$(field '[items["linear:AI-802"]["waiting_on"]["kind"], items["linear:AI-802"]["waiting_on"]["trace_id"], items["linear:AI-802"]["waiting_on"]["reporter"]]')"
it "set-waiting without --who is a usage error"
prog set-waiting linear:AI-802
check 2 "$CODE"

it "claim from a worker session with a structured payload is appended"
CLAUDE_CODE_SESSION_ID="sess-w1" prog claim --run "$RUN" --item linear:AI-800 --deliverable merged --ref 'gh:web-app#17'
check 0 "$CODE"
it "the claims inbox holds one line with the claim fields"
check '["linear:AI-800", "merged", "gh:web-app#17", "sess-w1"]' "$(run_py "$HOME_DIR" <<'EOF'
rows = [json.loads(l) for l in open(os.path.join(args[0], "claims.jsonl"))]
p = rows[0]["payload"]
print(json.dumps([p["item"], p["deliverable"], p["ref"], rows[0]["session_id"]]))
EOF
)"
it "a claim never touches the deliverable"
check '"unknown"' "$(field 'items["linear:AI-800"]["deliverables"]["verified"]["result"]')"
it "a claim through an alias names the canonical item"
CLAUDE_CODE_SESSION_ID="sess-w1" prog claim --run "$RUN" --item herdr:w2/p26 --deliverable verified --ref job-123
has '"linear:AI-800"' "$(tail -1 "${HOME_DIR}/claims.jsonl")"
it "claim with free text only is refused"
CLAUDE_CODE_SESSION_ID="sess-w1" prog claim --run "$RUN" "I finished the merge, all good"
check 2 "$CODE"
it "claim with a free-text reference is refused"
CLAUDE_CODE_SESSION_ID="sess-w1" prog claim --run "$RUN" --item linear:AI-800 --deliverable merged --ref "I merged it"
check 1 "$CODE"
it "claim for an unknown deliverable is refused"
CLAUDE_CODE_SESSION_ID="sess-w1" prog claim --run "$RUN" --item linear:AI-800 --deliverable shipped --ref x1
check 1 "$CODE"
it "claim for an unknown item is refused"
CLAUDE_CODE_SESSION_ID="sess-w1" prog claim --run "$RUN" --item linear:AI-999 --deliverable merged --ref x1
check 1 "$CODE"
it "a claim reference has escape sequences stripped"
CLAUDE_CODE_SESSION_ID="sess-w1" prog claim --run "$RUN" --item linear:AI-800 --deliverable recorded --ref $'abc\x1b[2Jdef'
has '"ref": "abcdef"' "$(tail -1 "${HOME_DIR}/claims.jsonl")"
it "refused claims append nothing"
check 3 "$(wc -l < "${HOME_DIR}/claims.jsonl" | tr -d ' ')"

it "unread claims refuse the stop"
has '"unread_claim"' "$(predicate 3)"
it "mark-read moves the inbox offset to the claim count"
prog mark-read
check 3 "$(field 'prog["inbox_offset"]')"
it "read claims no longer refuse the stop"
lacks '"unread_claim"' "$(predicate 3)"
it "mark-read past the inbox size is refused"
prog mark-read --offset 9
check 1 "$CODE"

it "add-item on an existing item re-matches it"
prog add-item linear:AI-802 --kind fix_only
check '["fix-only"]' "$(field 'items["linear:AI-802"]["matched_rule"]')"
it "the re-match is journaled as an update"
has '"linear:AI-802"' "$(journal_last item_updated)"

: > "$CALLS"
it "hand-item notifies once through the tracker mark"
prog hand-item linear:AI-802 --question "Ship the new crop now or hold for design?"
check '"handed"' "$(field 'items["linear:AI-802"]["state"]')"
it "the tracker provider was called and herdr was not"
check "board" "$(cut -d' ' -f1 "$CALLS" | sort -u | tr '\n' ' ' | sed 's/ $//')"
it "the hand is journaled with the tracker exit status"
check '[0, null]' "$("$PY" -c 'import json,sys; p=json.loads(sys.stdin.read())["payload"]["notify"]; print(json.dumps([p["tracker"], p["herdr"]]))' <<< "$(journal_last item_handed)")"
it "hand-item on an already handed item is refused and notifies nothing"
: > "$CALLS"
prog hand-item linear:AI-802 --question "again?"
check "1 0" "$CODE $(wc -l < "$CALLS" | tr -d ' ')"

it "hand-item when the tracker mark fails falls back to a herdr notification"
: > "$CALLS"
prog add-item linear:AI-803 --title "Product call" --kind product_question
FAKE_BOARD_EXIT=3 prog hand-item linear:AI-803 --question "Which crop default?"
check "board herdr" "$(cut -d' ' -f1 "$CALLS" | tr '\n' ' ' | sed 's/ $//')"
it "the journal records both exit statuses"
check '[3, 0]' "$("$PY" -c 'import json,sys; p=json.loads(sys.stdin.read())["payload"]["notify"]; print(json.dumps([p["tracker"], p["herdr"]]))' <<< "$(journal_last item_handed)")"
it "the herdr notification names the question"
has "Which crop default?" "$(cat "$CALLS")"

it "hand-item on a herdr item skips the tracker"
: > "$CALLS"
prog add-item herdr:w2/p40 --title "pane"
prog hand-item herdr:w2/p40 --question "Keep this pane?"
check "herdr" "$(cut -d' ' -f1 "$CALLS" | tr '\n' ' ' | sed 's/ $//')"

it "answer-handed without a prompt is refused"
prog answer-handed linear:AI-802 --choice ship
check "1 typed prompt" "$CODE $(printf '%s' "$OUT" | grep -o 'typed prompt' | head -1)"
it "answer-handed with a cron prompt is refused"
prog answer-handed linear:AI-802 --choice ship --prompt "$P_CRON"
check 1 "$CODE"
P_VAGUE_SHIP="$(prompt typed 'ship it')"
it "answer-handed citing a typed prompt that does not name the item is refused"
prog answer-handed linear:AI-802 --choice ship --prompt "$P_VAGUE_SHIP"
check "1 handed" "$CODE $(field 'items["linear:AI-802"]["state"]' | tr -d '"')"
has "AI-802" "$OUT"

P_SHIP="$(prompt typed 'ship ai 802')"
it "answer-handed choosing ship reopens the item"
prog answer-handed linear:AI-802 --choice ship --prompt "$P_SHIP"
check '"open"' "$(field 'items["linear:AI-802"]["state"]')"
it "the reopened item carries the deliverables its rule implies"
check '[["fix-only"], ["merged", "recorded", "verified"]]' "$(field '[items["linear:AI-802"]["matched_rule"], sorted(items["linear:AI-802"]["deliverables"])]')"
it "the answer cites the prompt"
has "\"cites\": [\"${P_SHIP}\"]" "$(journal_last handed_answered)"
it "answer-handed on an item that is not handed is refused"
prog answer-handed linear:AI-802 --choice ship --prompt "$P_SHIP"
check 1 "$CODE"
it "answer-handed ship on a product question without a new kind is refused"
P_SHIP3="$(prompt typed 'ship AI-803 as flagged code')"
prog answer-handed linear:AI-803 --choice ship --prompt "$P_SHIP3"
check 1 "$CODE"
it "answer-handed ship with a new kind matches that rule"
prog answer-handed linear:AI-803 --choice ship --kind flagged_code --prompt "$P_SHIP3"
check '[["flagged-code"], "open"]' "$(field '[items["linear:AI-803"]["matched_rule"], items["linear:AI-803"]["state"]]')"
it "answer-handed choosing decline drops the item"
prog answer-handed herdr:w2/p40 --choice decline --prompt "$(prompt typed 'decline the w2/p40 pane')"
check '"dropped"' "$(field 'items["herdr:w2/p40"]["state"]')"

it "record-tested-build stores the shasum"
SHA="0123456789abcdef0123456789abcdef01234567"
prog record-tested-build linear:AI-800 --shasum "$SHA" --package @slate/crop --version 1.2.3
check "[\"${SHA}\", \"@slate/crop\", \"1.2.3\"]" "$(field '[items["linear:AI-800"]["tested_build"][k] for k in ("shasum", "package", "version")]')"
it "record-tested-build is journaled"
has "$SHA" "$(journal_last tested_build_recorded)"
it "a malformed shasum is refused"
prog record-tested-build linear:AI-800 --shasum "not-a-sha"
check 1 "$CODE"

it "queue adds a worker start in the shape the predicate reads"
prog queue --action start_worker --item linear:AI-803 --why "needs a worker"
check '["start_worker", "linear:AI-803"]' "$(field '[prog["working_model"]["queue"][-1]["action"], prog["working_model"]["queue"][-1]["item"]]')"
QID="$(field 'prog["working_model"]["queue"][-1]["id"]' | tr -d '"')"
it "queue --remove takes the entry off"
prog queue --remove "$QID"
check 0 "$(field 'len([e for e in prog["working_model"]["queue"] if e.get("id") == "'"$QID"'"])')"
it "set-now --clear empties what the PM is doing"
prog set-now --clear
check 'null' "$(field 'prog["working_model"]["doing"]')"

it "set-source --unavailable records the outage time"
prog set-source tracker --unavailable
has 'T' "$(field 'prog["sources"]["tracker"]["unavailable_since"]')"
it "a source outage refuses the stop"
has '"source_unavailable"' "$(predicate -)"
it "set-source --available clears it"
prog set-source tracker --available
check 'null' "$(field 'prog["sources"]["tracker"]["unavailable_since"]')"
it "set-source --unsupported marks the source unusable here and ends the outage"
prog set-source tracker --unavailable
prog set-source tracker --unsupported
check '[true, null]' "$(field '[prog["sources"]["tracker"]["unsupported_since"] is not None, prog["sources"]["tracker"]["unavailable_since"]]')"
it "an unsupported source does not hold the stop"
lacks '"source_unavailable"' "$(predicate -)"
it "set-source --unavailable after --unsupported is a real outage again"
prog set-source tracker --unavailable
check '[null, true]' "$(field '[prog["sources"]["tracker"]["unsupported_since"], prog["sources"]["tracker"]["unavailable_since"] is not None]')"
it "set-source --available clears both states"
prog set-source tracker --unsupported
prog set-source tracker --available
check '[null, null]' "$(field '[prog["sources"]["tracker"]["unsupported_since"], prog["sources"]["tracker"]["unavailable_since"]]')"
it "set-source with two states is refused"
prog set-source tracker --unsupported --available
check 2 "$CODE"
it "an unknown source is refused"
prog set-source jira --unavailable
check 2 "$CODE"
it "the old board source name is refused"
prog set-source board --available
check 2 "$CODE"
it "the old linear source name is refused"
prog set-source linear --available
check 2 "$CODE"
it "set-source tracker --provider records the provider that answered"
prog set-source tracker --available --provider linear-api
check '"linear-api"' "$(field 'prog["sources"]["tracker"]["provider"]')"
it "a tracker going down clears its provider"
prog set-source tracker --unavailable
check 'null' "$(field 'prog["sources"]["tracker"]["provider"]')"
prog set-source tracker --available
it "--provider on a source other than tracker is refused"
prog set-source tasks --available --provider board
check 2 "$CODE"
it "set-source takes tasks and plans"
prog set-source tasks --available
prog set-source plans --available
check '[true, true]' "$(field '["tasks" in prog["sources"], "plans" in prog["sources"]]')"

for verb_args in "add-item linear:AI-950 --title x" "alias-item linear:AI-803 linear:AI-951" "drop-item herdr:w2/p27 --reason x" "set-waiting linear:AI-800 --who ci" "watcher-beat w-ci" "hand-item linear:AI-800 --question q" "set-now x" "queue --action sweep" "mark-read" "record-tested-build linear:AI-800 --shasum ${SHA}" "set-source herdr --unavailable"; do
  it "a non-driving session is refused: ${verb_args%% *}"
  CLAUDE_CODE_SESSION_ID="sess-stranger" prog $verb_args --run "$RUN"
  check "1 driving session" "$CODE $(printf '%s' "$OUT" | grep -o 'driving session' | head -1)"
done

touch "${HOME_DIR}/.compact-flag"
it "a write verb refuses while the compact flag is set"
prog add-item linear:AI-960 --title x
check 1 "$CODE"
it "the refusal prints the rules in force"
has "<auto-rules>" "$OUT"
it "claim is exempt from the compact flag"
CLAUDE_CODE_SESSION_ID="sess-w1" prog claim --run "$RUN" --item linear:AI-800 --deliverable merged --ref sha-1
check 0 "$CODE"
it "watcher-beat is exempt from the compact flag"
prog watcher-beat w-ci
check 0 "$CODE"
rm -f "${HOME_DIR}/.compact-flag"

edit 'rec["programme"]["ended"] = {"at": "2026-10-06T00:00:00Z", "reason": "test"}'
it "claim on an ended programme is refused"
CLAUDE_CODE_SESSION_ID="sess-w1" prog claim --run "$RUN" --item linear:AI-800 --deliverable merged --ref sha-2
check 1 "$CODE"
edit 'rec["programme"]["ended"] = None'

it "no item ever reached a stored done state"
check '[]' "$(field 'sorted(k for k, v in items.items() if v["state"] == "done")')"

it "the sanitizer strips escapes and control characters and caps length"
check '["ab c", 10, true, null]' "$(run_py <<'EOF'
ps = load_lib_module("programme_sanitize")
print(json.dumps([ps.clean("a\x1b]0;title\x07b\n c\x00"), len(ps.clean("x" * 50, cap=10)), ps.wrap("<x>").startswith("<auto-external>\\u003cx"), ps.token("two words")]))
EOF
)"

it "no verb call crashed with a traceback"
check "" "$CRASHES"

echo ""
echo "programme-items.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
