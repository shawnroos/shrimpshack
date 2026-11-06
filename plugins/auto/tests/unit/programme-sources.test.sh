#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "programme-sources.test.sh"

. "${AUTO_ROOT}/tests/helpers/programme-sources-setup.sh"

write_snapshot base
registry_line sess-ghost w2:p77 term_p77
registry_line sess-stale w2:p31 term_gone

it "describe lists the source verbs"
DESC="$("$PY" "$PROG" describe 2>/dev/null)"
VERBS="$("$PY" -c 'import json,sys; print(" ".join(sorted(json.load(sys.stdin)["verbs"])))' <<< "$DESC" 2>&1)"
for verb in sweep start-worker prompt-item; do
  case " $VERBS " in *" $verb "*) ;; *) VERBS="MISSING:$verb $VERBS" ;; esac
done
lacks "MISSING:" "$VERBS"

: > "$CALLS"
prog sweep
it "sweep exits 0"
check 0 "$CODE"
it "sweep proposes exactly the two worker panes"
check '[["herdr:w2/p31", "adopt"], ["linear:AI-753", "adopt"]]' "$(jq_py 'sorted([p["item"], p["action"]] for p in d["proposals"])')"
it "the branch names the issue"
check '["branch"]' "$(jq_py '[p["signals"] for p in d["proposals"] if p["item"] == "linear:AI-753"][0]')"
it "shells, the PM pane and the tracker pane are skipped with a reason"
check '[["w2:p1", "shell"], ["w2:p10", "pm"], ["w2:p11", "tracker"], ["w2:p2", "shell"]]' "$(jq_py 'sorted([s["pane"], s["why"]] for s in d["skipped"])')"
it "a pane outside the remit is never read as remit work"
check '[]' "$(jq_py '[p["pane_id"] for p in d["panes"] if p["pane_id"] == "w9:p5"] + [p["pane"] for p in d["proposals"] if p["pane"] == "w9:p5"]')"
it "a pane outside the remit is listed in the domain"
check '["w9:p5"]' "$(jq_py '[p["pane"] for p in d["domain"]]')"
it "remit panes carry an order, working last"
check '["w2:p31", "w2:p30"]' "$(jq_py '[o["pane"] for o in d["order"]]')"
it "a pane whose folder is gone is flagged, never repo_out_of_remit"
check '[]' "$(jq_py '[s for s in d["skipped"] if s["why"] == "repo_out_of_remit"]')"
it "pane titles are stripped of escape sequences"
check '"Shot kinds red"' "$(jq_py '[p["title"] for p in d["panes"] if p["pane_id"] == "w2:p30"][0]')"
it "no escape sequence reaches the output"
lacks "u001b" "$OUT"
it "an escape sequence's payload is stripped with it"
lacks "evil" "$OUT"
it "a registry line naming a pane absent from the snapshot is ignored"
lacks "sess-ghost" "$OUT"
it "a registry line whose terminal changed is ignored"
lacks "sess-stale" "$OUT"
it "a pane with no reported session and no registry line is session unknown"
check '[null, null]' "$(jq_py '[[p["owner"]["session_id"], p["owner"]["source"]] for p in d["panes"] if p["pane_id"] == "w2:p31"][0]')"
it "the snapshot's agent session is the owner"
check '["sess-pm", "snapshot"]' "$(jq_py '[[p["owner"]["session_id"], p["owner"]["source"]] for p in d["panes"] if p["pane_id"] == "w2:p10"][0]')"
it "every tracker provider failing marks the tracker down with each provider's reason"
check '[true, null]' "$(jq_py '[d["sources"]["tracker"]["unavailable"], d["sources"]["tracker"]["provider"]]')"
has "board: w2: plugin op unsupported" "$(jq_py 'd["sources"]["tracker"]["reason"]')"
it "with no Linear key the linear-api provider is tried too, and issues stay unverified"
check '[["board", "unsupported"], ["linear-api", "unavailable"]]' "$(jq_py '[[t["provider"], t["state"]] for t in d["sources"]["tracker"]["tried"]]')"
it "a provider that could not answer named issues leaves the tracker an outage"
check '"unavailable"' "$(jq_py 'd["sources"]["tracker"]["state"]')"
it "herdr is available"
check 'false' "$(jq_py 'd["sources"]["herdr"]["unavailable"]')"
it "sweep writes nothing to the journal"
check 0 "$(journal_count source_changed)"
it "sweep calls herdr snapshot once, bounded behind a probe"
check '2' "$(grep -cE '^herdr (status server|api snapshot)' "$CALLS")"
it "a missing snapshot op is unsupported for that provider, not an outage"
check '"unsupported"' "$(jq_py 'd["sources"]["tracker"]["tried"][0]["state"]')"
it "herdr answering is available"
check '"available"' "$(jq_py 'd["sources"]["herdr"]["state"]')"
export FAKE_BOARD_OUTAGE=1
prog sweep
unset FAKE_BOARD_OUTAGE
it "a supported provider command that fails is an outage"
check '["unavailable", true]' "$(jq_py '[d["sources"]["tracker"]["tried"][0]["state"], d["sources"]["tracker"]["unavailable"]]')"
mkdir -p "${WORK}/nopath"
PATH="${WORK}/nopath" prog sweep
it "herdr and every tracker provider missing from PATH are unsupported"
check '["unsupported", "unsupported"]' "$(jq_py '[d["sources"]["herdr"]["state"], d["sources"]["tracker"]["state"]]')"

registry_line sess-w2 w2:p31 term_p31
prog sweep
it "a registry line for a live pane with the same terminal gives the owner"
check '["sess-w2", "registry"]' "$(jq_py '[[p["owner"]["session_id"], p["owner"]["source"]] for p in d["panes"] if p["pane_id"] == "w2:p31"][0]')"

export LINEAR_API_KEY="lin_api_FAKEKEYFAKEKEYFAKEKEY1234"
export FAKE_LINEAR_JSON="${WORK}/linear.json"
printf '%s' '{"data":{"i0":{"identifier":"AI-753","title":"Shot kinds \u001b[2Jwipe","url":"https://linear.app/x/AI-753","state":{"name":"In Progress","type":"started"}}}}' > "$FAKE_LINEAR_JSON"
: > "$CALLS"
write_snapshot utf
prog sweep
write_snapshot base
it "a failing first provider falls back to the next, and the output names the one that answered"
check '"linear-api"' "$(jq_py 'd["sources"]["tracker"]["provider"]')"
it "the tracker is available through the fallback"
check '[false, "available"]' "$(jq_py '[d["sources"]["tracker"]["unavailable"], d["sources"]["tracker"]["state"]]')"
it "each issue names the provider that answered"
check '"linear-api"' "$(jq_py 'd["issues"]["AI-753"]["source"]')"
it "the issue title from Linear is sanitized"
check '"Shot kinds wipe"' "$(jq_py 'd["issues"]["AI-753"]["title"]')"
it "the Linear key never appears in a command line"
lacks "FAKEKEY" "$(calls)"
it "the Linear key goes to curl on stdin"
has "Authorization: lin_api_FAKEKEY" "$(cat "${CALLS}.curlconfig")"
it "Linear is asked about every named issue"
has 'UTF-8' "$(cat "${CALLS}.curlconfig")"
it "a name Linear does not know is not proposed as an issue"
check '["herdr:w2/p31", "linear:AI-753"]' "$(jq_py 'sorted(p["item"] for p in d["proposals"])')"

export FAKE_CURL_EXIT=7
prog sweep
it "a failing fallback read leaves the tracker unavailable, with no provider"
check '[true, null]' "$(jq_py '[d["sources"]["tracker"]["unavailable"], d["sources"]["tracker"]["provider"]]')"
unset FAKE_CURL_EXIT
it "curl missing from PATH makes Linear unsupported"
check 'unsupported' "$(PATH="${WORK}/nopath" "$PY" -c 'import sys; sys.path.insert(0, sys.argv[1]); from _bootstrap import load_lib_module; print(load_lib_module("programme_tracker").read_linear(["AI-753"])["state"])' "${AUTO_ROOT}/lib" 2>&1)"
it "a failing curl leaves Linear an outage"
check 'unavailable' "$(FAKE_CURL_EXIT=7 "$PY" -c 'import sys; sys.path.insert(0, sys.argv[1]); from _bootstrap import load_lib_module; print(load_lib_module("programme_tracker").read_linear(["AI-753"])["state"])' "${AUTO_ROOT}/lib" 2>&1)"

export FAKE_BOARD_JSON="${WORK}/board.json"
cat > "$FAKE_BOARD_JSON" <<'EOF'
{"project":{"name":"Ai Editor"},"groups":[{"key":"started","label":"In Progress","issues":["AI-753","AI-760"]}],
 "issues":{"AI-753":{"identifier":"AI-753","title":"Shot kinds","state":{"name":"In Progress","type":"started"},"bindings":[]},
           "AI-760":{"identifier":"AI-760","title":"Bound by the board","state":{"name":"Todo","type":"unstarted"},"bindings":[{"tab":"w2:t1","panes":["w2:p31"]}]}},
 "pane_status":{}}
EOF
: > "$CALLS"
prog sweep
it "the first provider answering is the tracker's provider"
check '"board"' "$(jq_py 'd["sources"]["tracker"]["provider"]')"
it "later providers are not read when the first answers"
lacks "curl" "$(calls)"
it "a tracker binding names the issue of an otherwise issueless pane"
check '[["linear:AI-753", ["branch"]], ["linear:AI-760", ["tracker"]]]' "$(jq_py 'sorted([p["item"], p["signals"]] for p in d["proposals"])')"
unset FAKE_BOARD_JSON LINEAR_API_KEY

export FAKE_HERDR_SLEEP=5
export CLAUDE_AUTO_SOURCE_TIMEOUT="0.5"
START_S=$SECONDS
prog sweep
it "a herdr timeout returns within the bound"
check 1 "$(( SECONDS - START_S < 4 ? 1 : 0 ))"
it "herdr timing out flags it unavailable"
check 'true' "$(jq_py 'd["sources"]["herdr"]["unavailable"]')"
it "an unavailable herdr gives no pane list rather than an empty one"
check '[null, null]' "$(jq_py '[d["panes"], d["proposals"]]')"
it "the reason names the timeout"
has "timed out" "$(jq_py 'd["sources"]["herdr"]["reason"]')"
unset FAKE_HERDR_SLEEP
export CLAUDE_AUTO_SOURCE_TIMEOUT="2"

export FAKE_HERDR_DOWN=1
prog sweep --record-sources
it "sweep --record-sources records a source going unavailable"
check 0 "$CODE"
it "the herdr source is recorded unavailable"
check 'true' "$(field 'prog["sources"]["herdr"]["unavailable_since"] is not None')"
it "the change is journaled through set-source"
check 1 "$(source_count herdr)"
it "the failing tracker is recorded in the same sweep"
check 1 "$(source_count tracker)"
it "a tracker with only unsupported providers is recorded as unsupported, with no outage"
check '[true, null]' "$(field '[prog["sources"]["tracker"]["unsupported_since"] is not None, prog["sources"]["tracker"]["unavailable_since"]]')"
prog sweep --record-sources
it "an unchanged source is not recorded again"
check 1 "$(source_count herdr)"
unset FAKE_HERDR_DOWN
export FAKE_BOARD_OUTAGE=1
prog sweep --record-sources
unset FAKE_BOARD_OUTAGE
it "a real tracker outage after unsupported is recorded as an outage"
check '[null, true]' "$(field '[prog["sources"]["tracker"]["unsupported_since"], prog["sources"]["tracker"]["unavailable_since"] is not None]')"
check 2 "$(source_count tracker)"
prog sweep --record-sources
it "herdr coming back is recorded"
check 'null' "$(field 'prog["sources"]["herdr"]["unavailable_since"]')"

CLAUDE_CODE_SESSION_ID=sess-other prog sweep --record-sources
it "another session cannot record sources"
check 1 "$CODE"

prog add-item linear:AI-753 --title "Shot kinds"
prog add-item herdr:w2/p31 --title "issueless pane"

: > "$CALLS"
prog sweep
it "an existing item is reported as known, not adopted again"
check '"known"' "$(jq_py '[p["action"] for p in d["proposals"] if p["item"] == "linear:AI-753"][0]')"

: > "$CALLS"
prog start-worker linear:AI-753 -- --name shot-kinds --handoff /tmp/h.md --target tab
it "start-worker where spinoff exits 0 but no agent appears fails"
check 1 "$CODE"
SID_FAILED="$(grep '^spinoff ' "$CALLS" | sed -E 's/.*--session-id ([^ ]+).*/\1/')"
it "spinoff got a minted lowercase uuid"
check 1 "$(printf '%s' "$SID_FAILED" | grep -cE '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')"
it "the caller's spinoff arguments pass through"
has "--name shot-kinds --handoff /tmp/h.md --target tab" "$(calls)"
it "the item records the failed start"
check "[false, \"${SID_FAILED}\"]" "$(field '[items["linear:AI-753"]["starts"][-1]["ok"], items["linear:AI-753"]["starts"][-1]["session_id"]]')"
it "a failed start does not set the owner"
check 'null' "$(field 'items["linear:AI-753"]["owner"]["session_id"]')"
it "the failed start is journaled"
has "no agent" "$(journal_last worker_start_failed)"
ATTEMPT_FAILED="$(jq_py 'd["attempt"]' | tr -d '"')"
it "a launch with no agent appearing stays uncertain, not failed"
check '"uncertain"' "$(jq_py 'd["operation_state"]')"

: > "$CALLS"
FAKE_SPINOFF_AGENT=1 prog start-worker linear:AI-753 -- --name shot-kinds --handoff /tmp/h.md
it "a second start while the first launch is uncertain is refused by default"
check 1 "$CODE"
it "the refusal names the uncertain attempt"
has "$ATTEMPT_FAILED" "$OUT"
it "the refused retry never calls spinoff"
lacks "spinoff" "$(calls)"

: > "$CALLS"
FAKE_SPINOFF_AGENT=1 prog start-worker linear:AI-753 --despite "$ATTEMPT_FAILED" -- --name shot-kinds --handoff /tmp/h.md
it "start-worker succeeds when the agent appears"
check 0 "$CODE"
SID_OK="$(grep '^spinoff ' "$CALLS" | sed -E 's/.*--session-id ([^ ]+).*/\1/')"
it "the owner is the new pane, its terminal and the minted session"
check "[\"w2:p40\", \"term_p40\", \"${SID_OK}\"]" "$(field '[items["linear:AI-753"]["owner"][k] for k in ("pane", "terminal_id", "session_id")]')"
it "the start is verified with herdr agent list"
has "herdr agent list" "$(calls)"
it "the successful start is journaled"
has "$SID_OK" "$(journal_last worker_started)"
it "each start mints a new session id"
check 1 "$([ "$SID_OK" != "$SID_FAILED" ] && echo 1 || echo 0)"

: > "$CALLS"
prog start-worker linear:AI-753 -- --name x --session-id 0b9f2c4e-7a1d-4e5b-9c3f-2d8e6a1b4c70
it "start-worker refuses a caller-supplied --session-id"
check 1 "$CODE"
prog start-worker linear:AI-999 -- --name x
it "start-worker refuses an unknown item"
check 1 "$CODE"
CLAUDE_CODE_SESSION_ID=sess-other prog start-worker linear:AI-753 -- --name x
it "start-worker refuses a session that does not drive the programme"
check 1 "$CODE"
it "refused starts never call spinoff"
lacks "spinoff" "$(calls)"

write_snapshot fork
prog add-item linear:AI-753 --pane w2:p30 --terminal-id term_p30 --session sess-w1
: > "$CALLS"
prog prompt-item linear:AI-753 "please rebase"
it "prompt-item refuses when the pane reports a different session than the owner"
check 1 "$CODE"
it "the owner mismatch is journaled"
has "sess-fork" "$(journal_last prompt_refused)"
it "nothing is sent on an owner mismatch"
lacks "agent prompt" "$(calls)"

write_snapshot owned
: > "$CALLS"
prog prompt-item linear:AI-753 $'please \x1b[2Jrebase\x07 now'
it "prompt-item sends when the reported session is the owner"
check 0 "$CODE"
it "the prompt goes to the recorded pane, with escape sequences stripped"
has "herdr agent prompt w2:p30 please rebase now" "$(calls)"
it "no raw escape byte reaches herdr"
lacks $'\x1b' "$(calls)"
it "the send is journaled"
has '"sent": true' "$(journal_last prompt_sent)"
it "a confirmed owner is not session unknown"
check 'false' "$(jq_py 'd["session_unknown"]')"

prog add-item herdr:w2/p31 --pane w2:p31 --terminal-id term_p31
rm -f "${CLAUDE_AUTO_DATA_DIR}/sessions/default.w2.jsonl"
write_snapshot base
: > "$CALLS"
prog prompt-item herdr:w2/p31 "status?"
it "prompt-item to a pane with no registry entry and no reported session is sent"
check 0 "$CODE"
it "that send is marked session unknown"
check 'true' "$(jq_py 'd["session_unknown"]')"
it "the journal marks it session unknown"
has '"session_unknown": true' "$(journal_last prompt_sent)"

write_snapshot exited
: > "$CALLS"
prog prompt-item herdr:w2/p31 "status?"
it "prompt-item refuses a pane whose agent has exited"
check 1 "$CODE"
it "nothing is typed into the shell"
lacks "agent prompt" "$(calls)"
it "the exited agent refusal is journaled"
has "no live agent" "$(journal_last prompt_refused)"

write_snapshot reused
prog prompt-item herdr:w2/p31 "status?"
it "prompt-item refuses a pane whose terminal changed"
check 1 "$CODE"
has "terminal" "$(journal_last prompt_refused)"

write_snapshot base
prog add-item linear:AI-770 --title "pm pane" --pane w2:p10
: > "$CALLS"
prog prompt-item linear:AI-770 "hello me"
it "prompt-item to the PM's own pane is refused"
check 1 "$CODE"
it "the driver refusal is journaled"
has "driver" "$(journal_last prompt_refused)"
it "nothing is sent to the PM's pane"
lacks "agent prompt" "$(calls)"

registry_line sess-pm w2:p12 term_p12
prog add-item linear:AI-771 --title "pm pane by registry" --pane w2:p12
prog prompt-item linear:AI-771 "hello me"
it "a driver pane known only from the registry is refused"
check 1 "$CODE"
it "it is refused as the driver's pane"
has "driver" "$(journal_last prompt_refused)"

prog add-item linear:AI-772 --title "tracker pane" --pane w2:p11
prog prompt-item linear:AI-772 "hello tracker"
it "prompt-item to a tracker pane is refused"
check 1 "$CODE"

prog add-item linear:AI-773 --title "no pane"
prog prompt-item linear:AI-773 "hello"
it "prompt-item refuses an item with no pane"
check 1 "$CODE"

FAKE_PROMPT_EXIT=1 prog prompt-item herdr:w2/p31 "status?"
it "a failed herdr send exits non-zero"
check 1 "$CODE"
it "a failed send is journaled as not sent"
has '"sent": false' "$(journal_last prompt_sent)"

touch "${HOME_DIR}/.compact-flag"
: > "$CALLS"
prog prompt-item herdr:w2/p31 "status?"
it "prompt-item obeys the compact flag"
check 1 "$CODE"
it "nothing is sent while the compact flag is set"
lacks "agent prompt" "$(calls)"
rm -f "${HOME_DIR}/.compact-flag"

CLAUDE_CODE_SESSION_ID=sess-other prog prompt-item herdr:w2/p31 "status?"
it "prompt-item refuses a session that does not drive the programme"
check 1 "$CODE"

seed_decision() {
  run_py "$RUN" "$1" "${2:-shawn}" <<'EOF'
run, why, by = args
pd = load_lib_module("programme_decisions")
out = {}
def body(rec):
    rec["programme"] = ph.normalize_programme(rec["programme"])
    out["id"] = pd.add_decision(rec["programme"], kind="product_scope", by=by, item="programme", why=why)["id"]
core._with_locked_run_record(ph.home_path(run), run, body)
print(out["id"])
EOF
}
DEC="$(seed_decision "Export stays PNG only this release")"
SENT_BEFORE="$(journal_count prompt_sent)"

: > "$CALLS"
prog prompt-item herdr:w2/p31 "carry on" --decision d000000
it "prompt-item refuses an unknown decision id"
check 1 "$CODE"
has "unknown decision" "$OUT"
it "nothing is sent for an unknown decision id"
lacks "agent prompt" "$(calls)"
check "$SENT_BEFORE" "$(journal_count prompt_sent)"

: > "$CALLS"
prog prompt-item herdr:w2/p31 "carry on" --decision "$DEC"
it "prompt-item with a decision sends"
check 0 "$CODE"
it "the prompt carries the decision text"
has "Export stays PNG only this release" "$(calls)"
it "the prompt names who decided"
has "(product_scope, decided by shawn)" "$(calls)"
it "the prompt carries the reopen clause"
has "stop and state that evidence" "$(calls)"
it "the prompt_sent row carries the decision ids"
check "[\"${DEC}\"]" "$(journal_last prompt_sent | "$PY" -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["payload"]["decision_ids"]))')"

DEC_PM="$(seed_decision "Crop helper stays as is" pm)"
: > "$CALLS"
prog prompt-item herdr:w2/p31 "carry on" --decision "$DEC_PM"
it "a PM decision reads as decided by pm in the prompt"
has "(product_scope, decided by pm)" "$(calls)"

LONG="$("$PY" -c 'print("x" * 3990)')"
: > "$CALLS"
prog prompt-item herdr:w2/p31 "$LONG" --decision "$DEC"
it "prompt-item refuses when the decision text pushes the prompt over the cap"
check 1 "$CODE"
has "4000" "$OUT"
it "nothing is sent over the cap"
lacks "agent prompt" "$(calls)"

: > "$CALLS"
prog prompt-item herdr:w2/p31 "build it" --restriction "source only" --source pm_choice
it "prompt-item with a pm_choice restriction sends"
check 0 "$CODE"
it "the restriction is recorded on the item with its source"
check '["source only", "pm_choice"]' "$(field '[items["herdr:w2/p31"]["restrictions"][-1][k] for k in ("text", "source")]')"
it "the prompt names the restriction and its source"
has "source only (source: pm_choice)" "$(calls)"
it "the prompt_sent row carries the restriction"
has '"source": "pm_choice"' "$(journal_last prompt_sent)"

: > "$CALLS"
prog prompt-item herdr:w2/p31 "build it" --restriction "no deploys"
it "a restriction without a source refuses"
check 2 "$CODE"
has "--source" "$OUT"
prog prompt-item herdr:w2/p31 "build it" --restriction "no deploys" --source vibes
it "a restriction with an unknown source refuses"
check 2 "$CODE"
it "nothing is sent for a refused restriction"
lacks "agent prompt" "$(calls)"
check 1 "$(field 'len(items["herdr:w2/p31"]["restrictions"])')"

# Main's launch tests above leave an uncertain launch on AI-753, which refuses a new one by design.
prog add-item linear:AI-790 --title "Shot kinds brief"
BRIEF="${WORK}/brief.md"
printf 'Build shot kinds.\n' > "$BRIEF"
: > "$CALLS"
prog start-worker linear:AI-790 --decision "$DEC" -- --name shot-kinds --target tab
it "start-worker with a decision refuses without --handoff"
check 2 "$CODE"
has "--handoff" "$OUT"
prog start-worker linear:AI-790 --decision d000000 -- --name shot-kinds --handoff "$BRIEF"
it "start-worker refuses an unknown decision id"
check 1 "$CODE"
prog start-worker linear:AI-790 --restriction "no deploys" -- --name shot-kinds --handoff "$BRIEF"
it "start-worker refuses a restriction without a source"
check 2 "$CODE"
it "refused decision starts never call spinoff"
lacks "spinoff" "$(calls)"

: > "$CALLS"
FAKE_SPINOFF_AGENT=1 prog start-worker linear:AI-790 --decision "$DEC" --restriction "source only" --source pm_choice \
  -- --name shot-kinds --handoff "$BRIEF"
it "start-worker with a decision and --handoff starts"
check 0 "$CODE"
PASSED="$(grep '^spinoff ' "$CALLS" | sed -E 's/.*--handoff ([^ ]+).*/\1/')"
it "spinoff gets a copy in the programme home, not the original"
has "${HOME_DIR}/" "$PASSED"
it "the copy carries the original brief, the decision text and the reopen clause"
COPY="$(cat "$PASSED" 2>/dev/null)"
has "Build shot kinds." "$COPY"
has "Export stays PNG only this release" "$COPY"
has "stop and state that evidence" "$COPY"
it "the copy carries the restriction with its source"
has "source only (source: pm_choice)" "$COPY"
it "the original brief is unchanged"
check "Build shot kinds." "$(cat "$BRIEF")"
it "the restriction is recorded on the started item"
check '["source only", "pm_choice"]' "$(field '[items["linear:AI-790"]["restrictions"][-1][k] for k in ("text", "source")]')"
it "the worker_started row carries the decision ids"
has "$DEC" "$(journal_last worker_started)"
run_py "$RUN" <<'EOF' >/dev/null
def body(rec):
    rec["programme"].setdefault("context", {})["decisions"] = {"crop-scope": [
        {"rev": 1, "scope": "crop only", "reason": "Shawn wants crop first", "limits": ["no export work"],
         "applies_to": ["programme"], "requirements": [], "state": "accepted"}]}
core._with_locked_run_record(ph.home_path(args[0]), args[0], body)
EOF
prog add-item linear:AI-791 --title "Crop brief"
: > "$CALLS"
FAKE_SPINOFF_AGENT=1 prog start-worker linear:AI-791 --decision crop-scope -- --name crop --handoff "$BRIEF"
it "start-worker takes a decision record id and quotes its revision and limits"
check 0 "$CODE"
COPY="$(cat "$(grep '^spinoff ' "$CALLS" | sed -E 's/.*--handoff ([^ ]+).*/\1/')" 2>/dev/null)"
has "decision:crop-scope@1 (decision record): crop only; reason: Shawn wants crop first; limits: no export work" "$COPY"
prog prompt-item herdr:w2/p31 "carry on" --decision no-such-record
it "a decision id in neither the log nor the decision records refuses"
check 1 "$CODE"
has "no accepted decision record" "$OUT"

run_py "$RUN" <<'EOF' >/dev/null
def ruling(effect, kind, applies_to, scope, state="accepted", legacy=None):
    return [{"rev": 1, "state": state, "kind": kind, "effect": effect, "legacy": legacy, "applies_to": applies_to,
             "until": None, "scope": scope, "reason": "Shawn said so", "quote": scope, "limits": [], "requirements": []}]
def body(rec):
    decisions = rec["programme"]["context"]["decisions"]
    decisions["r-grant"] = ruling("grant", "dependency_bump", ["linear:AI-792"], "bump minor deps freely")
    decisions["r-hold"] = ruling("restrict", "merge_around_gate", ["linear:AI-792"], "never merge around CI")
    decisions["r-call"] = ruling("decided", "product_call", ["programme"], "PNG export only")
    decisions["r-other"] = ruling("grant", "dependency_bump", ["linear:AI-790"], "another item's grant")
    decisions["r-shut"] = ruling("restrict", "prod_deploy", ["linear:AI-792"], "closed hold", state="closed")
    decisions["i0legacy"] = ruling("decided", None, ["linear:AI-792"], "keep PRs small", legacy="instruction")
core._with_locked_run_record(ph.home_path(args[0]), args[0], body)
EOF
prog add-item linear:AI-792 --title "Rulings brief"
: > "$CALLS"
FAKE_SPINOFF_AGENT=1 prog start-worker linear:AI-792 --decision "$DEC" -- --name rulings --handoff "$BRIEF"
it "start-worker's brief lists the item's grant, restrict and decided Rulings beside the decision-log row"
check 0 "$CODE"
COPY="$(cat "$(grep '^spinoff ' "$CALLS" | sed -E 's/.*--handoff ([^ ]+).*/\1/')" 2>/dev/null)"
has "Settled decisions this work carries:" "$COPY"
has "Export stays PNG only this release" "$COPY"
has "- ruling:r-grant (dependency_bump, grant): bump minor deps freely; reason: Shawn said so" "$COPY"
has "- ruling:r-hold (merge_around_gate, restrict): never merge around CI" "$COPY"
has "- ruling:r-call (product_call, decided): PNG export only" "$COPY"
has "- ruling:i0legacy (legacy instruction, decided): keep PRs small" "$COPY"
it "the brief leaves out another item's Ruling and a closed one"
lacks "another item's grant" "$COPY"
lacks "closed hold" "$COPY"

: > "$CALLS"
FAKE_SPINOFF_AGENT=1 prog start-worker linear:AI-792 --decision r-hold -- --name rulings2 --handoff "$BRIEF"
it "a Ruling passed with --decision reads as a Ruling, once"
COPY="$(cat "$(grep '^spinoff ' "$CALLS" | sed -E 's/.*--handoff ([^ ]+).*/\1/')" 2>/dev/null)"
check "0 1" "$CODE $(printf '%s\n' "$COPY" | grep -c 'ruling:r-hold')"
lacks "(decision record)" "$COPY"

run_py "$RUN" <<'EOF' >/dev/null
def body(rec):
    decisions = rec["programme"]["context"]["decisions"]
    for rid in [r for r in decisions if r.startswith("r-") or r == "i0legacy"]:
        del decisions[rid]
    decisions["r-narrow"] = [{"rev": 1, "state": "accepted", "kind": "tool_choice", "effect": "grant", "legacy": None,
                              "applies_to": ["linear:AI-792"], "until": None, "scope": "PM picks tools",
                              "reason": "Shawn said so", "quote": "tools are yours", "limits": [], "requirements": [],
                              "baseline": "act"}]
core._with_locked_run_record(ph.home_path(args[0]), args[0], body)
EOF
mkdir -p "$(dirname "$CLAUDE_AUTO_PERSONAL_PROTOCOL")"
printf '{"autonomy": {"tool_choice": {"level": "propose"}}}' > "$CLAUDE_AUTO_PERSONAL_PROTOCOL"
: > "$CALLS"
FAKE_SPINOFF_AGENT=1 prog start-worker linear:AI-792 -- --name narrowed --handoff "$BRIEF"
it "a grant whose kind Authority now holds narrower than its baseline reaches the brief as conflicted, not settled"
COPY="$(cat "$(grep '^spinoff ' "$CALLS" | sed -E 's/.*--handoff ([^ ]+).*/\1/')" 2>/dev/null)"
check 0 "$CODE"
has "ruling:r-narrow" "$COPY"
has "conflicted: wait for Shawn" "$COPY"
lacks "Settled decisions this work carries:" "$COPY"
lacks "stop and state that evidence" "$COPY"
: > "$CALLS"
FAKE_SPINOFF_AGENT=1 prog start-worker linear:AI-792 --decision r-narrow -- --name narrowed2 --handoff "$BRIEF"
it "the same grant cited with --decision is conflicted too"
COPY="$(cat "$(grep '^spinoff ' "$CALLS" | sed -E 's/.*--handoff ([^ ]+).*/\1/')" 2>/dev/null)"
check "0 1" "$CODE $(printf '%s\n' "$COPY" | grep -c 'ruling:r-narrow')"
has "conflicted: wait for Shawn" "$COPY"
lacks "stop and state that evidence" "$COPY"

run_py "$RUN" <<'EOF' >/dev/null
def body(rec):
    decisions = rec["programme"]["context"]["decisions"]
    decisions["r-keep"] = [{"rev": 1, "state": "accepted", "kind": "merge_around_gate", "effect": "restrict",
                            "legacy": None, "applies_to": ["linear:AI-792"], "until": None, "scope": "never merge around CI",
                            "reason": "Shawn said so", "quote": "never merge around CI", "limits": [], "requirements": []}]
    decisions["r-gone"] = [{"rev": 1, "state": "accepted", "kind": "dependency_bump", "effect": "grant", "legacy": None,
                            "applies_to": ["linear:AI-792"], "until": "2000-01-01T00:00:00Z", "scope": "bump deps until 2000",
                            "reason": "Shawn said so", "quote": "bump deps", "limits": [], "requirements": [],
                            "baseline": "act"}]
core._with_locked_run_record(ph.home_path(args[0]), args[0], body)
EOF
: > "$CALLS"
FAKE_SPINOFF_AGENT=1 prog start-worker linear:AI-792 -- --name mixed --handoff "$BRIEF"
it "a brief with one settled and one conflicted Ruling lists each under its own heading"
COPY="$(cat "$(grep '^spinoff ' "$CALLS" | sed -E 's/.*--handoff ([^ ]+).*/\1/')" 2>/dev/null)"
SETTLED="$(printf '%s\n' "$COPY" | sed -n '/^Settled decisions this work carries:/,/^Rulings Authority now holds narrower/p')"
CONFLICTED="$(printf '%s\n' "$COPY" | sed -n '/^Rulings Authority now holds narrower/,$p')"
check "0 1 0 0 1" "$CODE $(printf '%s\n' "$SETTLED" | grep -c 'ruling:r-keep') $(printf '%s\n' "$SETTLED" | grep -c 'ruling:r-narrow') $(printf '%s\n' "$CONFLICTED" | grep -c 'ruling:r-keep') $(printf '%s\n' "$CONFLICTED" | grep -c 'ruling:r-narrow')"
: > "$CALLS"
FAKE_SPINOFF_AGENT=1 prog start-worker linear:AI-792 --decision r-gone -- --name expired --handoff "$BRIEF"
it "start-worker refuses a --decision naming a Ruling past its end date, so it never reaches the brief as settled"
check "nonzero " "$([ "$CODE" -ne 0 ] && echo nonzero) $(grep -c '^spinoff ' "$CALLS" | sed 's/^0$//')"
has "r-gone" "$OUT"
run_py "$RUN" <<'EOF' >/dev/null
def body(rec):
    for rid in ("r-keep", "r-gone"):
        del rec["programme"]["context"]["decisions"][rid]
core._with_locked_run_record(ph.home_path(args[0]), args[0], body)
EOF
rm -f "$CLAUDE_AUTO_PERSONAL_PROTOCOL"

prog add-item linear:AI-793 --title "No handoff"
: > "$CALLS"
FAKE_SPINOFF_AGENT=1 prog start-worker linear:AI-793 -- --name plain --target tab
it "start-worker with no handoff still starts when programme-wide Rulings exist"
check 0 "$CODE"
write_snapshot base

seed_behaviours '[{"id": "bpm", "layer": "programme", "applies_to": "workers", "state": "active", "at": "2026-01-01T00:00:00Z",
  "when": {"text": "the item changes the editor", "checks": [{"text": "the item is an editor change", "by": "pm"}]},
  "do": ["run the editor smoke test"]},
 {"id": "bpmself", "layer": "programme", "applies_to": "pm", "state": "active", "at": "2026-01-01T00:00:00Z",
  "when": {"text": "always", "checks": []}, "do": ["post a tracker note"]}]'

prog add-item linear:AI-792 --title "No behaviour matches"
: > "$CALLS"
FAKE_SPINOFF_AGENT=1 prog start-worker linear:AI-792 -- --name plain --target tab
it "start-worker with only a PM-checked behaviour the PM did not name needs no --handoff, as today"
check 0 "$CODE"
lacks "--handoff" "$(grep '^spinoff ' "$CALLS")"
it "that start records no behaviour delivery and names the held-back behaviour"
check "null" "$(field 'items["linear:AI-792"].get("behaviour_deliveries")')"
has '"behaviours_held_back": ["bpm"]' "$OUT"

SHIP_DIR="${WORK}/files/ship"
PERS_DIR="${WORK}/files/pers"
mkdir -p "$SHIP_DIR" "$PERS_DIR"
export CLAUDE_AUTO_SHIPPED_BEHAVIOURS_DIR="$SHIP_DIR"
export CLAUDE_AUTO_BEHAVIOURS_DIR="$PERS_DIR"
printf -- '---\nwhen: the work changes UI\ntrigger: start\nskills: slate-editor-testing\nformats: a short list\ncomms: say it plainly\n---\nDo:\n- browser-verify the change\n' > "${SHIP_DIR}/shipui.md"

write_snapshot base
prog add-item linear:AI-880 --title "Shipped default, plain start"
: > "$CALLS"
FAKE_SPINOFF_AGENT=1 prog start-worker linear:AI-880 -- --name shipplain --target tab
it "KTD12: a plain start-worker still starts when the only behaviour in force is a shipped one"
check 0 "$CODE"
lacks "--handoff" "$(grep '^spinoff ' "$CALLS")"
it "that start records only a not_briefed delivery (never brief) and carries no behaviour id"
check '["not_briefed"]' "$(field '[d["reason"] for d in items["linear:AI-880"].get("behaviour_deliveries") or []]')"
has '"behaviour_ids": []' "$OUT"

write_snapshot base
prog add-item linear:AI-881 --title "Shipped default, with handoff"
: > "$CALLS"
FAKE_SPINOFF_AGENT=1 prog start-worker linear:AI-881 -- --name shipbrief --handoff "$BRIEF"
it "a shipped start-trigger file appears in the brief block when --handoff is given"
check 0 "$CODE"
COPY="$(cat "$(grep '^spinoff ' "$CALLS" | tail -1 | sed -E 's/.*--handoff ([^ ]+).*/\1/')" 2>/dev/null)"
has "- shipui: when the work changes UI" "$COPY"
it "R10: the brief line carries the file's skills, formats and comms"
has "skills: slate-editor-testing" "$COPY"
has "formats: a short list" "$COPY"
has "comms: say it plainly" "$COPY"
it "the shipped brief delivery is recorded on the item"
check '[["shipui", "brief", "start-worker"]]' "$(field '[[d["id"], d["reason"], d["via"]] for d in items["linear:AI-881"]["behaviour_deliveries"]]')"

write_snapshot base
printf -- '---\nwhen: the work edits docs\n---\nDo:\n- spell check\n' > "${PERS_DIR}/mydocs.md"
prog add-item linear:AI-882 --title "Personal file, plain start"
: > "$CALLS"
prog start-worker linear:AI-882 -- --name perplain --target tab
it "KTD12: a personal-file behaviour in force still needs --handoff"
check 2 "$CODE"
has "needs --handoff" "$OUT"
lacks "spinoff" "$(calls)"
rm -f "${PERS_DIR}/mydocs.md"

write_snapshot base
printf -- '---\nwhen: the work edits docs\nchecks:\n  - pm: the item is a docs change\n---\nDo:\n- spell check\n' > "${PERS_DIR}/pmdocs.md"
prog add-item linear:AI-883 --title "PM-check-only personal file"
: > "$CALLS"
FAKE_SPINOFF_AGENT=1 prog start-worker linear:AI-883 -- --name pmcheck --handoff "$BRIEF"
it "a PM-check-only file stays out of the worker brief unless it is named"
check 0 "$CODE"
COPY="$(cat "$(grep '^spinoff ' "$CALLS" | tail -1 | sed -E 's/.*--handoff ([^ ]+).*/\1/')" 2>/dev/null)"
lacks "- pmdocs:" "$COPY"
prog add-item linear:AI-884 --title "PM-check-only personal file named"
write_snapshot base
: > "$CALLS"
FAKE_SPINOFF_AGENT=1 prog start-worker linear:AI-884 --behaviour pmdocs -- --name pmnamed --handoff "$BRIEF"
it "a PM-check-only file joins the worker brief when named with --behaviour"
check 0 "$CODE"
COPY="$(cat "$(grep '^spinoff ' "$CALLS" | tail -1 | sed -E 's/.*--handoff ([^ ]+).*/\1/')" 2>/dev/null)"
has "- pmdocs: when the work edits docs" "$COPY"
rm -f "${PERS_DIR}/pmdocs.md" "${SHIP_DIR}/shipui.md"
export CLAUDE_AUTO_SHIPPED_BEHAVIOURS_DIR="$EMPTY_SHIPPED"
export CLAUDE_AUTO_BEHAVIOURS_DIR="$EMPTY_PERSONAL"

prog add-item linear:AI-800 --title "limited"
prog add-item linear:AI-801 --title "limited, no handoff"
prog add-item linear:AI-802 --title "free"
run_py "$RUN" <<'EOF' >/dev/null
def mutate(rec):
    prog = rec["programme"]
    on = {"no-destructive-commands": {"state": "on"}}
    prog["items"]["linear:AI-800"]["check_settings"] = prog["items"]["linear:AI-801"]["check_settings"] = on
    prog["items"]["linear:AI-802"]["check_settings"] = {"no-settings-writes": {"state": "off"}}
    prog["check_settings"] = {"no-settings-writes": {"state": "on"}}
core._with_locked_run_record(ph.home_path(args[0]), args[0], mutate)
EOF
: > "$CALLS"
FAKE_SPINOFF_AGENT=1 prog start-worker linear:AI-800 -- --name limited --handoff "$BRIEF"
it "a worker started with a limit: the start succeeds"
check 0 "$CODE"
COPY="$(cat "$(grep '^spinoff ' "$CALLS" | tail -1 | sed -E 's/.*--handoff ([^ ]+).*/\1/')" 2>/dev/null)"
it "the brief names each limit in force, from the item and from the programme, and says how to lift it"
has "Limits on this work:" "$COPY"
has "no-destructive-commands" "$COPY"
has "no-settings-writes" "$COPY"
has "the PM sees the refusal" "$COPY"
it "the journal row names the same limits"
has "no-destructive-commands" "$(journal_last worker_started)"
has "no-settings-writes" "$(journal_last worker_started)"
: > "$CALLS"
FAKE_SPINOFF_AGENT=1 prog start-worker linear:AI-801 -- --name limited2 --target tab
it "a start with no handoff is not refused for a limit, and its output tells the PM the limits went unbriefed"
check 0 "$CODE"
has "no-destructive-commands" "$(journal_last worker_started)"
has "limits_not_briefed" "$OUT"
: > "$CALLS"
FAKE_SPINOFF_AGENT=1 prog start-worker linear:AI-802 -- --name free --handoff "$BRIEF"
COPY="$(cat "$(grep '^spinoff ' "$CALLS" | tail -1 | sed -E 's/.*--handoff ([^ ]+).*/\1/')" 2>/dev/null)"
it "a worker with no limit in force gets no limits section, and an item off beats the programme on"
check 0 "$CODE"
case "$COPY" in *"Limits on this work"*) fail "limits section in: $COPY" ;; *) pass ;; esac

run_py "$RUN" <<'EOF2' >/dev/null
def mutate(rec):
    rec["programme"]["items"]["herdr:w2/p31"]["check_settings"] = {"no-destructive-commands": {"state": "on"}}
core._with_locked_run_record(ph.home_path(args[0]), args[0], mutate)
EOF2
write_snapshot base
: > "$CALLS"
prog prompt-item herdr:w2/p31 "the limit is now on"
it "a plain prompt-item to an item with a limit on carries the limit lines"
check 0 "$CODE"
has "Limits on this work:" "$(calls)"
has "no-destructive-commands" "$(calls)"

it "no command crashed with a traceback"
# programme-sources-behaviours.test.sh counts this check's pass; here a crash still fails the file.
[ -z "$CRASHES" ] || fail "expected [] got [$CRASHES]"

echo ""
echo "programme-sources.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
