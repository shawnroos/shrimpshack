#!/usr/bin/env bash
# Fenced external dispatch across crashes, end and ownership moves (U6). Each dispatcher runs as a
# real process, paused at a named point by a test hatch, while end, handover or a kill happens.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
WORK="$(mktemp -d -t auto-dispatch-recovery.XXXXXX)"
BG=""
trap '[ -n "$BG" ] && kill -9 "$BG" 2>/dev/null; rm -rf "$WORK"' EXIT
. "${AUTO_ROOT}/tests/helpers/dispatch-fixture.sh"

echo "programme-dispatch-recovery.test.sh"

write_snapshot base
fresh() {
  RUN="$(new_programme "$1")"
  HOME_DIR="${CLAUDE_AUTO_DATA_DIR}/programmes/${RUN}"
  prog add-item linear:AI-1 --title "worker item" --run "$RUN"
  prog add-item linear:AI-2 --title "prompted item" --pane w2:p30 --terminal-id term_p30 --session sess-w1 --run "$RUN"
}
OUTF="${WORK}/bg.out"

# Scenario 2: kill after the launch, before its receipt; recovery never launches again.
fresh w2
: > "$CALLS"
bg "$OUTF" "FAKE_SPINOFF_AGENT=1 CLAUDE_AUTO_TEST_DISPATCH_PAUSE_AFTER_INVOKE=1" start-worker linear:AI-1 --run "$RUN" -- --name w1
wait_for "$OUTF" "paused:dispatch_after_invoke"
it "the dispatcher reached the point after the launch"
check 0 $?
kill -9 "$BG"; wait "$BG" 2>/dev/null; BG=""
ATTEMPT="$(field "$RUN" 'sorted(ops)[0]')"
it "the killed launch is still admitted"
check "admitted" "$(field "$RUN" "ops['${ATTEMPT}']['state']")"
it "the admitted launch blocks the archive"
check "[\"${ATTEMPT}\"]" "$(unreconciled "$RUN")"
prog start-worker linear:AI-1 --run "$RUN" -- --name w1
it "a retry after the crash is refused"
check 1 "$CODE"
it "the refusal names the unreconciled attempt"
has "$ATTEMPT" "$OUT"
prog reconcile-operations --run "$RUN"
it "reconcile finds the launched session and settles it"
check "completed" "$(field "$RUN" "ops['${ATTEMPT}']['state']")"
it "the current owner gets the reconciled worker"
check "[\"w2:p40\", \"term_p40\"]" "$(field "$RUN" "[items['linear:AI-1']['owner'][k] for k in ('pane', 'terminal_id')]")"
it "the worker's session is the one minted before the launch"
check "$(field "$RUN" "ops['${ATTEMPT}']['target']['session_id']")" "$(field "$RUN" "items['linear:AI-1']['owner']['session_id']")"
it "spinoff ran exactly once across crash, retry and reconcile"
check 1 "$(calls_of spinoff)"
it "nothing is left unreconciled"
check "[]" "$(unreconciled "$RUN")"

prog add-item linear:AI-3 --title "lost response" --run "$RUN"
: > "$CALLS"
FAKE_SPINOFF_AGENT=1 prog start-worker linear:AI-3 --op lost-1 --run "$RUN" -- --name w3
FIRST="$(pyget "$OUT" 'd["attempt"]')"
FAKE_SPINOFF_AGENT=1 prog start-worker linear:AI-3 --op lost-1 --run "$RUN" -- --name w3
it "a retry with the same --op replays the settled launch"
check "true completed ${FIRST}" "$(pyget "$OUT" 'd["replayed"]') $(pyget "$OUT" 'd["operation_state"]') $(pyget "$OUT" 'd["attempt"]')"
it "the replay launches nothing new"
check 1 "$(calls_of spinoff)"

: > "$CALLS"
bg "$OUTF" CLAUDE_AUTO_TEST_DISPATCH_PAUSE_AFTER_INVOKE=1 prompt-item linear:AI-2 "please rebase" --run "$RUN"
wait_for "$OUTF" "paused:dispatch_after_invoke"
kill -9 "$BG"; wait "$BG" 2>/dev/null; BG=""
SEND="$(field "$RUN" "[k for k, o in ops.items() if o['kind'] == 'send'][0]")"
prog prompt-item linear:AI-2 "please rebase" --run "$RUN"
it "a prompt retry after the crash is refused"
check 1 "$CODE"
prog reconcile-operations --run "$RUN"
it "a sent prompt with no receipt stays uncertain after reconcile"
check "uncertain" "$(field "$RUN" "ops['${SEND}']['state']")"
it "the prompt was typed into the pane exactly once"
check 1 "$(calls_of 'herdr agent prompt')"
prog prompt-item linear:AI-2 "please rebase" --despite "$SEND" --run "$RUN"
it "an explicit --despite sends a new prompt"
check 0 "$CODE"
it "--despite does not settle the earlier uncertain prompt"
check "[\"${SEND}\"]" "$(unreconciled "$RUN")"

# Focus budget: a held start leaves no launch record, --despite focus overrides, a hand-started worker counts.
limit() {
  local pid
  pid="$(run_py "$RUN" "focus budget limited $*" <<'PYEOF'
run, text = args
print(fixture_prompt(run, "sess-pm", text, "typed")["prompt_id"])
PYEOF
)"
  prog amend-term focus_budget limited "$@" --prompt "$pid" --run "$RUN"
}
write_snapshot base
prog add-item linear:AI-61 --title "focus item" --run "$RUN"
limit --points 5
OPS0="$(field "$RUN" "len(ops)")"
: > "$CALLS"
prog start-worker linear:AI-61 --run "$RUN" -- --name w1
it "an unsized item is held while a point limit is set"
check 1 "$CODE"
has "unsized" "$OUT"
it "the held start admitted no launch and ran no spinoff"
check "[${OPS0}, 0]" "$(field "$RUN" "[len(ops), $(calls_of spinoff)]")"
it "the hold survives the raised refusal"
check 'true' "$(field "$RUN" "bool(items['linear:AI-61']['held'])")"
FAKE_SPINOFF_AGENT=1 prog start-worker linear:AI-61 --run "$RUN" --despite focus -- --name w1
it "--despite focus starts the held item and clears the hold"
check "0 null" "${CODE} $(field "$RUN" "items['linear:AI-61']['held']")"
it "the override is recorded on the launch"
check '[["focus"]]' "$(field "$RUN" "[o['despite'] for o in ops.values() if o['item'] == 'linear:AI-61']")"
write_snapshot base
prog add-item linear:AI-9 --title "late" --size small --run "$RUN"
limit --points none --agents 1
prog start-worker linear:AI-9 --run "$RUN" -- --name w9
it "a worker already running in the snapshot uses up the agent limit"
check 1 "$CODE"
has "agents at limit: 1 of 1" "$OUT"

# Scenario 4: end at each point between intent, admission and dispatch.
fresh w4
: > "$CALLS"
bg "$OUTF" CLAUDE_AUTO_TEST_DISPATCH_PAUSE_BEFORE_ADMISSION=1 start-worker linear:AI-1 --run "$RUN" -- --name w1
wait_for "$OUTF" "paused:dispatch_before_admission"
end_programme "$RUN" >/dev/null
resume "$RUN"; wait "$BG"; C=$?; BG=""
it "end before admission: the dispatcher refuses"
check 1 "$C"
it "end before admission: no operation is admitted"
check "{}" "$(field "$RUN" 'ops')"
it "end before admission: spinoff never runs"
check 0 "$(calls_of spinoff)"

fresh w5
: > "$CALLS"
bg "$OUTF" CLAUDE_AUTO_TEST_DISPATCH_PAUSE_AFTER_ADMISSION=1 start-worker linear:AI-1 --run "$RUN" -- --name w1
wait_for "$OUTF" "paused:dispatch_after_admission"
end_programme "$RUN" >/dev/null
resume "$RUN"; wait "$BG"; C=$?; BG=""
ATTEMPT="$(field "$RUN" 'sorted(ops)[0]')"
it "end after admission: the dispatcher refuses before the launch"
check 1 "$C"
it "end after admission: spinoff never runs"
check 0 "$(calls_of spinoff)"
it "end after admission: the admission is settled as not executed"
check "not_executed" "$(field "$RUN" "ops['${ATTEMPT}']['state']")"
it "end after admission: nothing is left unaccounted"
check "[]" "$(unreconciled "$RUN")"

# Scenario 7: pause right before the launch, commit end, resume.
fresh w6
: > "$CALLS"
bg "$OUTF" "FAKE_SPINOFF_AGENT=1 CLAUDE_AUTO_TEST_DISPATCH_PAUSE_BEFORE_INVOKE=1" start-worker linear:AI-1 --run "$RUN" -- --name w1
wait_for "$OUTF" "paused:dispatch_before_invoke"
end_programme "$RUN" >/dev/null
ATTEMPT="$(field "$RUN" 'sorted(ops)[0]')"
it "while the admitted launch is paused after end, it blocks the archive"
check "[\"${ATTEMPT}\"]" "$(unreconciled "$RUN")"
resume "$RUN"; wait "$BG"; BG=""
it "a launch already past its recheck still runs after end"
check 1 "$(calls_of spinoff)"
it "its receipt is kept as a late fact"
check "[\"completed\", false]" "$(field "$RUN" "[ops['${ATTEMPT}']['state'], ops['${ATTEMPT}']['receipt']['authority_current']]")"
it "the late launch does not make the worker the item's owner after end"
check "null" "$(field "$RUN" "items['linear:AI-1']['owner']['session_id']")"
it "the late launch keeps the worker's pane on the operation"
check "w2:p40" "$(field "$RUN" "ops['${ATTEMPT}']['receipt']['facts']['pane']")"
it "once its receipt is kept, the late launch no longer blocks the archive"
check "[]" "$(unreconciled "$RUN")"
prog start-worker linear:AI-1 --run "$RUN" -- --name w2
it "after end no new launch is admitted"
check 1 "$CODE"

fresh w8
: > "$CALLS"
bg "$OUTF" "FAKE_SPINOFF_AGENT=1 CLAUDE_AUTO_TEST_DISPATCH_PAUSE_BEFORE_INVOKE=1 CLAUDE_AUTO_TEST_DISPATCH_PAUSE_AFTER_INVOKE=1" \
  start-worker linear:AI-1 --run "$RUN" -- --name w1
wait_for "$OUTF" "paused:dispatch_before_invoke"
end_programme "$RUN" >/dev/null
resume "$RUN"
wait_for "$OUTF" "paused:dispatch_after_invoke"
kill -9 "$BG"; wait "$BG" 2>/dev/null; BG=""
ATTEMPT="$(field "$RUN" 'sorted(ops)[0]')"
it "end, then a crash after the launch: the admission is still tracked"
check "admitted" "$(field "$RUN" "ops['${ATTEMPT}']['state']")"
it "it blocks the archive until reconciled"
check "[\"${ATTEMPT}\"]" "$(unreconciled "$RUN")"
prog reconcile-operations --run "$RUN"
it "the driving session reconciles after end"
check 0 "$CODE"
it "the reconciled late launch is completed"
check "completed" "$(field "$RUN" "ops['${ATTEMPT}']['state']")"
it "reconciliation after end restores no ownership"
check "null" "$(field "$RUN" "items['linear:AI-1']['owner']['session_id']")"
it "nothing is left unreconciled after reconcile"
check "[]" "$(unreconciled "$RUN")"
it "the crashed launch ran exactly once"
check 1 "$(calls_of spinoff)"

# Scenario 5: stale authority, a reused terminal, and a wrong digest refuse.
fresh w9
: > "$CALLS"
bg "$OUTF" CLAUDE_AUTO_TEST_DISPATCH_PAUSE_BEFORE_ADMISSION=1 start-worker linear:AI-1 --run "$RUN" -- --name w1
wait_for "$OUTF" "paused:dispatch_before_admission"
move_owner "$RUN" sess-pm sess-b >/dev/null
move_owner "$RUN" sess-b sess-pm >/dev/null
resume "$RUN"; wait "$BG"; C=$?; BG=""
it "a dispatcher whose ownership epoch moved is refused even in the same session"
check 1 "$C"
it "the refusal names the stale epoch"
has "epoch" "$(cat "$OUTF")"
it "the stale dispatcher admitted nothing and launched nothing"
check "{} 0" "$(field "$RUN" 'ops') $(calls_of spinoff)"

: > "$CALLS"
bg "$OUTF" CLAUDE_AUTO_TEST_DISPATCH_PAUSE_AFTER_ADMISSION=1 prompt-item linear:AI-2 "status?" --run "$RUN"
wait_for "$OUTF" "paused:dispatch_after_admission"
write_snapshot reused
resume "$RUN"; wait "$BG"; C=$?; BG=""
SEND="$(field "$RUN" "[k for k, o in ops.items() if o['kind'] == 'send'][0]")"
it "a terminal reused between admission and send refuses the send"
check 1 "$C"
it "nothing was typed into the reused terminal"
check 0 "$(calls_of 'herdr agent prompt')"
it "the refused send is settled as not executed"
check "not_executed" "$(field "$RUN" "ops['${SEND}']['state']")"
write_snapshot base

: > "$CALLS"
bg "$OUTF" CLAUDE_AUTO_TEST_DISPATCH_PAUSE_AFTER_ADMISSION=1 start-worker linear:AI-1 --run "$RUN" -- --name w1
wait_for "$OUTF" "paused:dispatch_after_admission"
move_owner "$RUN" sess-pm sess-b >/dev/null
resume "$RUN"; wait "$BG"; C=$?; BG=""
LAUNCH="$(field "$RUN" "[k for k, o in ops.items() if o['kind'] == 'launch'][0]")"
it "ownership moved after admission: the launch is refused before spinoff"
check "1 0" "$C $(calls_of spinoff)"
it "the stale admission is settled as not executed"
check "not_executed" "$(field "$RUN" "ops['${LAUNCH}']['state']")"
it "a stale dispatcher changed no ownership"
check "null" "$(field "$RUN" "items['linear:AI-1']['owner']['session_id']")"
it "a receipt with the wrong digest for that admission is refused"
check "wrong_digest" "$(run_py "$RUN" "$LAUNCH" <<'EOF'
try:
    pr.record_receipt(args[0], args[1], digest="sha256:" + "f" * 64, target={}, outcome="completed", source="t")
    print("accepted")
except pr.DispatchError as exc:
    print(exc.code)
EOF
)"

it "no command crashed with a traceback"
check "" "$CRASHES"
it "no background dispatcher crashed with a traceback"
lacks "Traceback" "$(cat "$OUTF" 2>/dev/null)"

echo ""
echo "programme-dispatch-recovery.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
