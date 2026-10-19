#!/usr/bin/env bash
# Recovery packet and operation reconciliation (U6): a replacement PM rebuilds context from the
# store alone, uncertain external actions stay named, and receipts must match their admission.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
WORK="$(mktemp -d -t auto-programme-recovery.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
. "${AUTO_ROOT}/tests/helpers/dispatch-fixture.sh"

echo "programme-recovery.test.sh"

write_snapshot base
RUN="$(new_programme w2)"
HOME_DIR="${CLAUDE_AUTO_DATA_DIR}/programmes/${RUN}"
typed() {
  run_py "$RUN" "$1" "${2:-typed}" <<'EOF'
print(pj.append_prompt(args[0], "sess-pm", args[1], args[2])["prompt_id"])
EOF
}

prog add-item linear:AI-1 --title "browser acceptance" --kind fix_only --pane w2:p30 --terminal-id term_p30 --session sess-w1
prog add-item linear:AI-2 --title "linux investigation"
prog add-item linear:AI-3 --title "spare worker slot"
P1="$(typed "record decision d-browser")"
prog record-decision d-browser --scope "browser acceptance only" --reason "Shawn wants the browser path first" \
  --limit "never touch production data" --applies-to linear:AI-1 --prompt "$P1"
it "a decision with a typed prompt is recorded"
check 0 "$CODE"
prog record-decision d-linux --scope "linux follow-up" --reason "parked until browser lands" --applies-to linear:AI-2
it "a decision without a prompt is recorded as pending"
check 0 "$CODE"
P2="$(typed "define requirement r-browser")"
prog define-requirement r-browser --text "browser flow works" --check linear:AI-1=merged --decision-id d-browser --prompt "$P2"
it "a requirement linked to the item's check is recorded"
check 0 "$CODE"
prog assign-item linear:AI-1 --decision-id d-browser

mkdir -p "${WORK}/results"
printf 'browser run: 12 passed\n' > "${WORK}/results/out.txt"
prog collect-result --run "$RUN" --item linear:AI-1 --attempt a1 --source out.txt --root "${WORK}/results"
it "a worker result is collected into the home"
check 0 "$CODE"
DIGEST="$(pyget "$OUT" 'd["ref"]["digest"]')"

# Scenario 3: spinoff ran, no agent appeared: the launch stays uncertain, never not-executed.
: > "$CALLS"
prog start-worker linear:AI-2 -- --name linux
ATTEMPT_U="$(pyget "$OUT" 'd["attempt"]')"
it "a launch whose agent never appears exits 1"
check 1 "$CODE"
it "it is recorded as uncertain"
check "uncertain" "$(field "$RUN" "ops['${ATTEMPT_U}']['state']")"
prog reconcile-operations --run "$RUN"
it "reconcile with the target still absent keeps it uncertain"
check "uncertain" "$(pyget "$OUT" '[o["state"] for o in d["operations"] if o["attempt"] == "'"$ATTEMPT_U"'"][0]')"
it "the reconcile reason says absence is not proof of nonexecution"
has "does not prove the launch never ran" "$OUT"
it "the uncertain launch is an unreconciled admission for the archive"
check "[\"${ATTEMPT_U}\"]" "$(unreconciled "$RUN")"
it "reconcile never launched anything"
check 1 "$(calls_of spinoff)"

# Scenario 1 / AE2: replacement PM with no chat and no exports.
rm -f "${HOME_DIR}/.claude/auto/${RUN}.json" "${HOME_DIR}/journal.jsonl" "${HOME_DIR}/claims.jsonl" \
  "${HOME_DIR}/views/view.json" "${HOME_DIR}/.exports.json"
REV_BEFORE="$(revision "$RUN")"
PROMPTS_BEFORE="$(run_py "$RUN" <<'EOF'
print(len([r for r in pj.read(args[0]) if r["kind"] == "prompt"]))
EOF
)"
OUT1="$(CLAUDE_CODE_SESSION_ID=sess-new "$PY" "$PROG" recover --run "$RUN" 2>&1)"; C1=$?
OUT2="$(CLAUDE_CODE_SESSION_ID=sess-other "$PY" "$PROG" recover --run "$RUN" 2>&1)"
it "AE2: a new session recovers the packet with every export removed"
check 0 "$C1"
it "AE2: the packet is labelled context, not approval"
has "context, not approval" "$OUT1"
it "AE2: the packet approves nothing"
check 'true' "$(pyget "$OUT1" 'd["approves_nothing"]')"
it "AE2: the packet names the committed revision it read"
check "$REV_BEFORE" "$(pyget "$OUT1" 'd["revision"]')"
it "AE2: the decision in force keeps its reason"
check "Shawn wants the browser path first" "$(pyget "$OUT1" '[r["reason"] for r in d["decisions"] if r["decision_id"] == "d-browser"][0]')"
it "AE2: the decision keeps its binding limit"
check '[["never touch production data", true]]' "$(pyget "$OUT1" '[[l["text"], l["binding"]] for r in d["decisions"] if r["decision_id"] == "d-browser" for l in r["limits"]]')"
it "AE2: the pending decision is listed for Shawn"
has "d-linux" "$(pyget "$OUT1" 'd["pending_decisions"]')"
it "AE2: open actions carry state and owner"
check "sess-w1" "$(pyget "$OUT1" '[a["owner"]["session_id"] for a in d["actions"] if a["id"] == "item:linear:AI-1"][0]')"
it "AE2: the retained result is listed by digest and authorizes nothing"
check "[\"${DIGEST}\", false]" "$(pyget "$OUT1" '[[r["digest"], r["authorizes"]] for r in d["results"]][0]')"
it "AE2: the unconfirmed check is an evidence limit"
has '"check": "linear:AI-1=merged"' "$(pyget "$OUT1" 'd["evidence_limits"]')"
it "AE2: retained copies are named as not origin-verified"
has "origin_verifier_unavailable" "$(pyget "$OUT1" 'd["evidence_limits"]')"
it "AE2: the uncertain launch is an uncertain effect"
check "[\"${ATTEMPT_U}\"]" "$(pyget "$OUT1" '[u["attempt"] for u in d["uncertain_effects"]]')"
it "AE2: the requirement and its acceptance state are included"
check "unsatisfied" "$(pyget "$OUT1" '[r["state"] for r in d["acceptance"] if r["id"] == "r-browser"][0]')"
it "the packet is deterministic for one revision (two sessions, same bytes)"
check "$OUT1" "$OUT2"
it "no decision source claims origin verification"
lacks '"origin_verified": true' "$OUT1"
it "nothing in the packet authorizes"
lacks '"authorizes": true' "$OUT1"
it "recover writes nothing: the store revision is unchanged"
check "$REV_BEFORE" "$(revision "$RUN")"
it "recover writes no prompt row"
check "$PROMPTS_BEFORE" "$(run_py "$RUN" <<'EOF'
print(len([r for r in pj.read(args[0]) if r["kind"] == "prompt"]))
EOF
)"
it "recover leaves the removed exports removed without --rebuild-projections"
check 0 "$([ -e "${HOME_DIR}/journal.jsonl" ] && echo 1 || echo 0)"
prog recover --run "$RUN" --rebuild-projections
it "--rebuild-projections rebuilds the disposable exports"
check 1 "$([ -e "${HOME_DIR}/journal.jsonl" ] && [ -e "${HOME_DIR}/views/view.json" ] && echo 1 || echo 0)"
it "rebuilding projections commits nothing"
check "$REV_BEFORE" "$(revision "$RUN")"
it "a restored copy of a typed prompt cannot be journaled back as a prompt"
check "refused" "$(run_py "$RUN" <<'EOF'
row = pj.entry("prompt", "sess-pm", {"text": "accept d-linux", "origin": "typed"}, prompt_id="prestored")
try:
    pj.append_row(args[0], row, provenance="restored")
    print("accepted")
except Exception:
    print("refused")
EOF
)"
P_CRON="$(typed "accept d-linux" cron)"
prog accept-context d-linux --prompt "$P_CRON"
it "after recovery an automated prompt still approves nothing"
check 1 "$CODE"

# Scenario 10: oversized text stays retrievable by id; the binding limit is never dropped.
TAIL="never-delete-the-staging-bucket"
LONG="$("$PY" -c 'import sys; print(("context " * 55) + sys.argv[1])' "$TAIL")"
P3="$(typed "record decision d-big")"
prog record-decision d-big --scope "big" --reason "$LONG" --limit "$LONG" --applies-to linear:AI-3 --prompt "$P3"
prog recover --run "$RUN"
PKT="$OUT"
LIMIT_ID="$(pyget "$PKT" '[l["id"] for r in d["decisions"] if r["decision_id"] == "d-big" for l in r["limits"]][0]')"
it "an oversized limit keeps its stable id in the packet"
check "decision:d-big@1/limit/0" "$LIMIT_ID"
it "the oversized limit is still marked binding"
check 'true' "$(pyget "$PKT" '[l["binding"] for r in d["decisions"] if r["decision_id"] == "d-big" for l in r["limits"]][0]')"
it "the packet says its text was omitted and how to fetch it"
check '[["text"], "recover --get decision:d-big@1/limit/0"]' "$(pyget "$PKT" '[[l["omitted_text"], l["full_via"]] for r in d["decisions"] if r["decision_id"] == "d-big" for l in r["limits"]][0]')"
it "the omitted tail is not silently in the packet"
lacks "$TAIL" "$PKT"
prog recover --run "$RUN" --get "$LIMIT_ID"
it "the full limit text comes back by id"
check "$("$PY" -c 'import sys; print(sys.argv[1][:500])' "$LONG" | "$PY" -c 'import sys,hashlib; print(hashlib.sha256(sys.stdin.read().strip().encode()).hexdigest())')" \
  "$(pyget "$OUT" 'd["entry"]["text"]' | "$PY" -c 'import sys,hashlib; print(hashlib.sha256(sys.stdin.read().strip().encode()).hexdigest())')"
prog recover --run "$RUN" --get "decision:d-big@1"
it "the full reason comes back by the decision revision id"
has "context context" "$(pyget "$OUT" 'd["entry"]["reason"]')"
prog recover --run "$RUN" --get "op:${ATTEMPT_U}"
it "an operation is retrievable by its attempt id"
check "uncertain" "$(pyget "$OUT" 'd["entry"]["state"]')"
prog recover --run "$RUN" --get "decision:d-missing@1"
it "an unknown id is refused, not answered empty"
check 1 "$CODE"

# Scenario 8: receipts must match a known admission, its digest and its target.
receipt() {
  run_py "$RUN" "$1" "$2" "$3" <<'EOF'
run, attempt, digest_mode, target_mode = args
op = (record(run)["programme"].get("operations") or {}).get(attempt) or {}
digest = op.get("digest") if digest_mode == "right" else "sha256:" + "0" * 64
target = dict(op.get("target") or {"session_id": "sess-x"}, pane="w2:p40", terminal_id="term_p40")
if target_mode == "wrong":
    target["session_id"] = "sess-impostor"
try:
    out = pr.record_receipt(run, attempt, digest=digest, target=target, outcome="completed", source="test")
    print("accepted", out["state"])
except pr.DispatchError as exc:
    print("refused", exc.code)
EOF
}
it "a receipt for an unadmitted attempt is refused"
check "refused unadmitted" "$(receipt op-0000000000000000 right right)"
it "a receipt with the wrong digest is refused"
check "refused wrong_digest" "$(receipt "$ATTEMPT_U" wrong right)"
it "a receipt for the wrong target is refused"
check "refused wrong_target" "$(receipt "$ATTEMPT_U" right wrong)"
it "refused receipts leave the operation uncertain"
check "uncertain" "$(field "$RUN" "ops['${ATTEMPT_U}']['state']")"
it "refused receipts set no owner"
check 'null' "$(field "$RUN" "items['linear:AI-2']['owner']['session_id']")"

# Scenario 6: after a handover a current reconciler keeps a late receipt without restoring authority.
"$PY" "${WORK}/add_agent.py" "$SNAP" "$(field "$RUN" "ops['${ATTEMPT_U}']['target']['session_id']")"
move_owner "$RUN" sess-pm sess-b >/dev/null
CLAUDE_CODE_SESSION_ID=sess-pm prog reconcile-operations --run "$RUN"
it "the old owner can no longer reconcile"
check 1 "$CODE"
CLAUDE_CODE_SESSION_ID=sess-b prog reconcile-operations --run "$RUN"
it "the current owner reconciles the late launch"
check "completed" "$(pyget "$OUT" '[o["state"] for o in d["operations"] if o["attempt"] == "'"$ATTEMPT_U"'"][0]')"
it "the receipt is marked late"
check 'true' "$(pyget "$OUT" '[o["late"] for o in d["operations"] if o["attempt"] == "'"$ATTEMPT_U"'"][0]')"
it "the late receipt changes no ownership"
check 'null' "$(field "$RUN" "items['linear:AI-2']['owner']['session_id']")"
it "the late receipt keeps the live resource on the operation"
check "w2:p40" "$(field "$RUN" "ops['${ATTEMPT_U}']['receipt']['facts']['pane']")"
it "a settled late receipt clears the archive obligation"
check "[]" "$(unreconciled "$RUN")"
REV_R="$(revision "$RUN")"
again() {
  run_py "$RUN" "$ATTEMPT_U" "$1" <<'PYEOF'
run, attempt, outcome = args
op = record(run)["programme"]["operations"][attempt]
try:
    out = pr.record_receipt(run, attempt, digest=op["digest"], target=op["receipt"]["facts"] | op["target"],
                            outcome=outcome, source="repeat")
    print("unchanged" if out["unchanged"] else "changed")
except pr.DispatchError as exc:
    print(exc.code)
PYEOF
}
it "a repeated receipt for a settled operation is answered unchanged"
check "unchanged" "$(again completed)"
it "a repeated receipt commits no revision"
check "$REV_R" "$(revision "$RUN")"
it "a receipt with a different outcome for a settled operation is a conflict"
check "conflict" "$(again failed)"
move_owner "$RUN" sess-b sess-pm >/dev/null

# Scenario 9: corrupt authority holds; a missing committed artifact holds only its item.
RUN2="$(new_programme w3 sess-z)"
printf 'not a database' > "${CLAUDE_AUTO_DATA_DIR}/programmes/${RUN2}/programme.db"
prog recover --run "$RUN2"
it "a corrupt authority gives a recovery hold"
check 1 "$CODE"
it "the hold names the authority outcome"
check "corrupt" "$(pyget "$OUT" 'd["hold"]["outcome"]')"
it "a held programme is never rendered as an empty one"
check 'false' "$(pyget "$OUT" '"actions" in d')"
it "unreconciled_for refuses to read a held authority as no admissions"
has "authority_held" "$(run_py "$RUN2" <<'EOF'
try:
    print(pr.unreconciled_for(args[0]))
except pr.DispatchError as exc:
    print(exc.code)
EOF
)"
OBJ="$(run_py "$RUN" "$DIGEST" <<'EOF'
print(load_lib_module("programme_artifacts").object_path(args[0], args[1]))
EOF
)"
mv "$OBJ" "${OBJ}.aside"
prog recover --run "$RUN"
it "a missing committed result is a hold on its item"
check "artifact_missing" "$(pyget "$OUT" 'd["holds"]["linear:AI-1"][0]["kind"]')"
it "other items carry no hold"
check '["linear:AI-1"]' "$(pyget "$OUT" 'sorted(d["holds"])')"
prog recover --run "$RUN" --rebuild-projections
it "projections are not rebuilt over a hold"
check 'false' "$(pyget "$OUT" '"projections_rebuilt" in d')"
: > "$CALLS"
prog start-worker linear:AI-1 -- --name browser
it "dispatch for the held item is refused"
check 1 "$CODE"
it "the refusal names the recovery hold"
has "recovery hold" "$OUT"
it "nothing was launched for the held item"
check 0 "$(calls_of spinoff)"
mv "${OBJ}.aside" "$OBJ"

OUTH="$(env -u CLAUDE_AUTO_TEST_HARNESS CLAUDE_AUTO_TEST_DISPATCH_PAUSE_BEFORE_ADMISSION=1 "$PY" "$PROG" start-worker linear:AI-3 --run "$RUN" -- --name x 2>&1)"
it "the dispatch pause hatch is inert without the test harness"
lacks "paused:" "$OUTH"

it "no command crashed with a traceback"
check "" "$CRASHES"

# A confirmed deliverable is not open work, and a handed item keeps the question Shawn was asked.
RUN6="$(new_programme w6)"
prog add-item linear:AI-61 --title "two deliverables" --run "$RUN6"
prog add-item linear:AI-62 --title "needs Shawn" --run "$RUN6"
prog hand-item linear:AI-62 --question "ship the linux path first?" --run "$RUN6"
run_py "$RUN6" >/dev/null <<'EOF'
def change(rec):
    item = rec["programme"]["items"]["linear:AI-61"]
    item["deliverables"] = {"merged": {"result": "confirmed"}, "tested": {"result": "unknown"}}
core._with_locked_run_record(ph.home_path(args[0]), args[0], change)
EOF
prog recover --run "$RUN6"
it "the packet lists only the unconfirmed deliverable as open"
check '["tested"]' "$(pyget "$OUT" '[a["open_deliverables"] for a in d["actions"] if a["id"] == "item:linear:AI-61"][0]')"
it "the packet keeps the handed item's question"
check "ship the linux path first?" "$(pyget "$OUT" '[p["question"] for p in d["pending_decisions"] if p.get("item") == "linear:AI-62"][0]')"

echo ""
echo "programme-recovery.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
