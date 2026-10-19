#!/usr/bin/env bash
# End, archive and seal across crashes and concurrent writers (U7). Each writer runs as a real
# process paused at a named point by a test hatch while end, a seal or a kill happens; afterward
# the whole home is compared byte for byte across every entry point that could touch it.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
WORK="$(mktemp -d -t auto-programme-closure.XXXXXX)"
BG=""
BG2=""
trap '[ -n "$BG" ] && kill -9 "$BG" 2>/dev/null; [ -n "$BG2" ] && kill -9 "$BG2" 2>/dev/null; rm -rf "$WORK"' EXIT
. "${AUTO_ROOT}/tests/helpers/dispatch-fixture.sh"
. "${AUTO_ROOT}/tests/helpers/closure-fixture.sh"
NOREPO="${WORK}/norepo"
mkdir -p "$NOREPO" "${WORK}/results"
printf 'browser run: 12 passed\n' > "${WORK}/results/out.txt"

echo "programme-closure.test.sh"
write_snapshot base

resume_archive() { touch "${CLAUDE_AUTO_DATA_DIR}/programmes/.test-resume-archive-$1"; }
killbg() { kill -9 "$1" 2>/dev/null; wait "$1" 2>/dev/null; }
running() { kill -0 "$1" 2>/dev/null && echo running || echo exited; }
objects() { find "$(home_of "$1")/artifacts/objects" -type f 2>/dev/null | wc -l | tr -d ' '; }
archived_events() {
  run_py "$1" <<'EOF'
pa = load_lib_module("programme_authority")
print(sum(1 for r in pa.snapshot(args[0])["journal"] if r.get("kind") == "programme_archived"))
EOF
}
seal_rows() {
  "$PY" -c 'import sqlite3, sys; c = sqlite3.connect("file:" + sys.argv[1] + "?mode=ro", uri=True); print(c.execute("SELECT COUNT(*) FROM meta WHERE key = ?", ("sealed",)).fetchone()[0])' \
    "$(home_of "$1")/programme.db"
}
ready_programme() {
  local run
  run="$(new_programme "$1")"
  prog add-item linear:AI-1 --title "finished elsewhere" --run "$run" >/dev/null
  prog add-item linear:AI-2 --title "second" --run "$run" >/dev/null
  end_typed "$run" >/dev/null
  prog dispose-item linear:AI-1 --as stopped_unfinished --why "stopped" --run "$run" >/dev/null
  prog dispose-item linear:AI-2 --as stopped_unfinished --why "stopped" --run "$run" >/dev/null
  printf '%s' "$run"
}

# ── Scenario 3: killed between the end commit and the lease release ──
RUN3="$(new_programme w2)"
prog add-item linear:AI-1 --title "browser" --kind fix_only --run "$RUN3"
prog watcher-beat w-mon --task-id bh1mon --kind monitor --run "$RUN3"
PID="$(typed_in "$RUN3" sess-pm "/auto:programme-end")"
run_py "$RUN3" sess-pm "$PID" <<'EOF' >/dev/null
pj.append(args[0], "end_request", args[1], {"verb": "end", "text": "/auto:programme-end", "origin": "typed",
                                            "driving": True, "lease_status": "live",
                                            "source": pj.find_prompt(args[0], args[2])["payload"]["source"]},
          cites=[args[2]])
EOF
CLAUDE_AUTO_TEST_ARCHIVE_PAUSE_AFTER_END_COMMIT=1 "$PY" "$PROG" end --run "$RUN3" > "${WORK}/end3.out" 2>&1 &
BG=$!
wait_for "${WORK}/end3.out" "paused:archive_after_end_commit"
it "S3: end reached the point after its commit"
check 0 $?
killbg "$BG"; BG=""
LEASE3="${CLAUDE_AUTO_DATA_DIR}/programmes/leases/default.w2.json"
it "S3: the kill left the lease file naming the run"
check "$RUN3" "$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["run"])' "$LEASE3" 2>&1)"
it "S3: the stale lease reads as ended, so it holds nothing"
check "ended" "$(run_py <<'EOF'
print(ph.lease_status(ph.read_lease(ph.lease_path("default", "w2"))))
EOF
)"
it "S3: the closure records the lease as still owed"
check "pending" "$(arch_field "$RUN3" 'closure["resources"]["lease:default.w2"]["state"]')"
REV3="$(revision "$RUN3")"
prog add-item linear:AI-9 --title late --run "$RUN3"
it "S3: an ordinary writer is refused"
check 1 "$CODE"
prog set-now "sweeping" --run "$RUN3"
it "S3: set-now is refused"
check 1 "$CODE"
prog beat --run "$RUN3"
it "S3: the driver beat cannot revive the lease"
check 1 "$CODE"
prog watcher-beat w-mon --run "$RUN3"
it "S3: an old watcher's beat is refused"
check 1 "$CODE"
prog claim --item linear:AI-1 --deliverable merged --ref pr-1 --run "$RUN3"
it "S3: a late claim is refused"
check 1 "$CODE"
it "S3: none of them moved the revision"
check "$REV3" "$(revision "$RUN3")"
it "S3: after the crash a typed prompt in the driving session is still journaled for closure"
has "$RUN3" "$(prompt_hook sess-pm "stop the monitor watcher w-mon")"
prog release-resources --run "$RUN3" --watcher w-mon --stopped --why "TaskStop bh1mon ok"
it "S3: release-resources removes the leftover lease and records its receipt"
check "released no" "$(arch_field "$RUN3" 'closure["resources"]["lease:default.w2"]["state"]') $([ -e "$LEASE3" ] && echo yes || echo no)"
it "S3: the watcher's reported stop is its receipt"
check "released" "$(arch_field "$RUN3" 'closure["resources"]["watcher:w-mon"]["state"]')"

# ── a late claim that passed its unlocked check before end is refused under the lock ──
RUN4="$(new_programme w3)"
prog add-item linear:AI-1 --title "browser" --kind fix_only --run "$RUN4"
CLAIMS4="$(run_py "$RUN4" <<'EOF'
print(pj.claims_count(args[0]))
EOF
)"
CLAUDE_AUTO_TEST_ARCHIVE_PAUSE_CLAIM=1 CLAUDE_CODE_SESSION_ID=sess-w1 \
  "$PY" "$PROG" claim --item linear:AI-1 --deliverable merged --ref pr-7 --run "$RUN4" > "${WORK}/claim4.out" 2>&1 &
BG=$!
wait_for "${WORK}/claim4.out" "paused:archive_claim"
end_typed "$RUN4"
resume_archive claim
wait "$BG"
CLAIM_CODE=$?
BG=""
it "late claim: the claim paused past its unlocked check exits 1 after end"
check 1 "$CLAIM_CODE"
it "late claim: the refusal names the end"
has "late claim is not recorded" "$(cat "${WORK}/claim4.out")"
it "late claim: no claim row was added"
check "$CLAIMS4" "$(run_py "$RUN4" <<'EOF'
print(pj.claims_count(args[0]))
EOF
)"

# ── Scenario 5: a concurrent write invalidates the candidate; one seal per operation ──
RUN5="$(ready_programme w4)"
OBJ5="$(objects "$RUN5")"
CLAUDE_AUTO_TEST_ARCHIVE_PAUSE_AFTER_CANDIDATE=1 "$PY" "$PROG" archive --run "$RUN5" --op seal-s5 > "${WORK}/a5.out" 2>&1 &
BG=$!
wait_for "${WORK}/a5.out" "paused:archive_after_candidate"
prog dispose-item linear:AI-2 --as handed_over --why "Shawn takes it" --run "$RUN5"
it "S5: a write lands while the candidate waits"
check 0 "$CODE"
resume_archive after_candidate
wait "$BG"
A5=$?
BG=""
it "S5: the superseded candidate is not sealed"
check "1 null" "$A5 $(arch_field "$RUN5" 'archive.get("sealed_at")')"
it "S5: the refusal says the candidate was superseded"
has "superseded" "$(cat "${WORK}/a5.out")"
it "S5: the candidate manifest was published durably anyway"
check "$((OBJ5 + 1))" "$(objects "$RUN5")"
prog archive --run "$RUN5" --op seal-s5
it "S5: a retry with the same operation seals at the new revision"
check 0 "$CODE"
S5_REV="$(pyget "$OUT" 'd["sealed_revision"]')"
S5_MAN="$(pyget "$OUT" 'd["manifest"]["digest"]')"
prog archive --run "$RUN5" --op seal-s5
it "S5: retrying the operation replays the same seal"
check "true $S5_REV $S5_MAN" "$(pyget "$OUT" 'd["replayed"]') $(pyget "$OUT" 'd["sealed_revision"]') $(pyget "$OUT" 'd["manifest"]["digest"]')"
prog archive --run "$RUN5" --op seal-other
it "S5: another operation gets the existing seal, not a second one"
check "already_sealed seal-s5 $S5_REV" "$(pyget "$OUT" 'd["status"]') $(pyget "$OUT" 'd["operation_id"]') $(pyget "$OUT" 'd["sealed_revision"]')"
it "S5: the journal holds exactly one archive event and the store one seal row"
check "1 1" "$(archived_events "$RUN5") $(seal_rows "$RUN5")"
prog check-archive --run "$RUN5"
it "S5: the sealed manifest reflects the write that superseded the first candidate"
check '["linear:AI-2"]' "$(pyget "$OUT" 'd["manifest"]["outcomes"]["handed_over"]')"

# ── Scenario 9: crashes around candidate durability and the seal commit ──
RUN9="$(ready_programme w5)"
OBJ9="$(objects "$RUN9")"
CLAUDE_AUTO_TEST_ARCHIVE_PAUSE_AFTER_CANDIDATE=1 "$PY" "$PROG" archive --run "$RUN9" > "${WORK}/a9a.out" 2>&1 &
BG=$!
wait_for "${WORK}/a9a.out" "paused:archive_after_candidate"
killbg "$BG"; BG=""
it "S9: a kill after the candidate leaves the candidate on disk"
check "$((OBJ9 + 1))" "$(objects "$RUN9")"
it "S9: a candidate alone never reads as archived"
check "null false" "$(arch_field "$RUN9" 'archive.get("sealed_at")') $(prog check-archive --run "$RUN9"; pyget "$OUT" 'd["sealed"]')"
prog dispose-item linear:AI-2 --as stopped_unfinished --why "still stopped" --run "$RUN9"
it "S9: closure writes still work after the orphaned candidate"
check 0 "$CODE"

CLAUDE_AUTO_TEST_STORE_PAUSE_BEFORE_COMMIT=1 "$PY" "$PROG" archive --run "$RUN9" --op seal-s9 > "${WORK}/a9b.out" 2>&1 &
BG=$!
wait_for "${WORK}/a9b.out" "paused:before_commit"
killbg "$BG"; BG=""
it "S9: a kill inside the seal transaction leaves the programme unsealed"
check "null" "$(arch_field "$RUN9" 'archive.get("sealed_at")')"
it "S9: the store still reads and has no seal row"
check "0" "$(seal_rows "$RUN9")"

RUNC="$(ready_programme w6)"
prog status --run "$RUNC" >/dev/null
rm -f "$(home_of "$RUNC")/views/view.json"
CLAUDE_AUTO_TEST_STORE_PAUSE_AFTER_COMMIT=1 "$PY" "$PROG" archive --run "$RUNC" --op seal-c > "${WORK}/a9c.out" 2>&1 &
BG=$!
wait_for "${WORK}/a9c.out" "paused:after_commit"
killbg "$BG"; BG=""
it "S9: a kill right after the seal commit leaves it sealed"
[ "$(arch_field "$RUNC" 'archive.get("sealed_at")')" != "null" ] && pass || fail "not sealed"
C_REV="$(arch_field "$RUNC" 'archive["sealed_revision"]')"
C_MAN="$(arch_field "$RUNC" 'archive["manifest"]["digest"]')"
case "$C_REV" in ''|*[!0-9]*) PREV_REV="unsealed" ;; *) PREV_REV=$((C_REV - 1)) ;; esac
it "S9: the lost response left the projections at the revision before the seal"
check "$PREV_REV no" "$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["projection_of_revision"])' "$(home_of "$RUNC")/.exports.json") $([ -e "$(home_of "$RUNC")/views/view.json" ] && echo yes || echo no)"
BASE="$(inventory "$RUNC")"
prog archive --run "$RUNC" --op seal-c
it "S9: the retry resolves to the one seal"
check "0 true $C_REV $C_MAN" "$CODE $(pyget "$OUT" 'd["replayed"]') $(pyget "$OUT" 'd["sealed_revision"]') $(pyget "$OUT" 'd["manifest"]["digest"]')"
it "S9: one archive event, one seal row"
check "1 1" "$(archived_events "$RUNC") $(seal_rows "$RUNC")"

# ── Scenario 11: a sealed home stays byte-identical under every entry point ──
same() {
  it "S11: $1 leaves the sealed home unchanged"
  check "$BASE" "$(inventory "$RUNC")"
}
same "the seal retry (same operation)"
prog archive --run "$RUNC" --op seal-new
same "an archive retry under a new operation"
prompt_hook sess-pm "please keep going" >/dev/null
same "the prompt hook in the old driving session"
prompt_hook sess-pm "/auto:programme-end again" >/dev/null
same "an end request typed after the seal"
( cd "$NOREPO" && bash "${HOOKS}/on-pre-compact.sh" <<< '{"session_id":"sess-pm","trigger":"auto","custom_instructions":null}' >/dev/null 2>&1 )
same "the pre-compact hook"
( cd "$NOREPO" && bash "${HOOKS}/on-session-start.sh" <<< '{"session_id":"sess-pm","source":"compact"}' >/dev/null 2>&1 )
( cd "$NOREPO" && bash "${HOOKS}/on-session-start.sh" <<< '{"session_id":"sess-pm","source":"startup"}' >/dev/null 2>&1 )
same "the session-start hook"
( cd "$NOREPO" && bash "${HOOKS}/on-stop.sh" <<< '{"session_id":"sess-pm"}' >/dev/null 2>&1 )
same "the stop hook"
prog status --run "$RUNC"
it "S11: status reads the sealed programme with its view missing"
check 0 "$CODE"
same "a status read with the view missing"
prog check-archive --run "$RUNC"
it "S11: check-archive reads the manifest and verifies its digest"
check "0 true" "$CODE $(pyget "$OUT" 'd["sealed"]')"
same "check-archive"
prog recover --run "$RUNC"
prog recover --run "$RUNC" --rebuild-projections
same "recover and recover --rebuild-projections"
prog promote --run "$RUNC"
same "promote (migration detection)"
run_py "$RUNC" <<'EOF' >/dev/null
boot = load_lib_module("_bootstrap")
list(boot.iter_programme_outcomes())
load_lib_module("programme_authority").outcome(args[0])
ph.driven_runs("sess-pm")
core.read_run_record(ph.home_path(args[0]), args[0])
EOF
same "outcome discovery and record reads"
"$PY" "${AUTO_ROOT}/lib/programme_journal.py" prune --run "$RUNC" >/dev/null 2>&1
same "prune"
prog beat --run "$RUNC"
prog watcher-beat w-x --process-id 4242 --run "$RUNC"
prog reconcile-leases --run "$RUNC"
same "beat, watcher-beat and reconcile-leases"
prog collect-result --run "$RUNC" --item linear:AI-1 --attempt late --source out.txt --root "${WORK}/results"
it "S11: a late result is refused"
check 1 "$CODE"
same "a late result"
prog reconcile-operations --run "$RUNC"
same "reconcile-operations"
WS=w6 HERDR_WORKSPACE_ID=w6 prog create-successor "$RUNC" --space default.w6
it "S11: a successor starts from the archive"
check 0 "$CODE"
same "successor creation"

# ── Scenario 10: paused payload and projection writers; the seal waits, nothing changes after ──
RUN10="$(ready_programme w7)"
CLAUDE_AUTO_TEST_ARTIFACT_PAUSE_BEFORE_COMMIT=1 "$PY" "$PROG" collect-result --run "$RUN10" --item linear:AI-1 \
  --attempt a1 --source out.txt --root "${WORK}/results" > "${WORK}/c10.out" 2>&1 &
BG=$!
wait_for "${WORK}/c10.out" "paused:artifact_before_commit"
"$PY" "$PROG" archive --run "$RUN10" --op seal-10 > "${WORK}/a10.out" 2>&1 &
BG2=$!
sleep 1.5
it "S10: the seal waits while a payload writer holds the home"
check "running null" "$(running "$BG2") $(arch_field "$RUN10" 'archive.get("sealed_at")')"
touch "$(home_of "$RUN10")/.test-resume-artifact"
wait "$BG"; C10=$?; BG=""
wait "$BG2"; A10=$?; BG2=""
it "S10: the paused result commits once it resumes"
check 0 "$C10"
it "S10: the seal then refuses its stale candidate instead of sealing over the new result"
check "1 null" "$A10 $(arch_field "$RUN10" 'archive.get("sealed_at")')"
prog archive --run "$RUN10" --op seal-10
it "S10: the retry seals with the result in the manifest"
check "0 true" "$CODE $(prog check-archive --run "$RUN10"; pyget "$OUT" '"result:linear:AI-1/a1/out.txt" in d["manifest"]["retained"]["results"]')"

RUNV="$(ready_programme w8)"
CLAUDE_AUTO_TEST_ARCHIVE_PAUSE_VIEW=1 "$PY" "$PROG" dispose-item linear:AI-2 --as handed_over --why "Shawn" \
  --run "$RUNV" > "${WORK}/v10.out" 2>&1 &
BG=$!
wait_for "${WORK}/v10.out" "paused:archive_view"
"$PY" "$PROG" archive --run "$RUNV" --op seal-v > "${WORK}/av.out" 2>&1 &
BG2=$!
sleep 1.5
it "S10: the seal waits while a projection writer is mid-write"
check "running null" "$(running "$BG2") $(arch_field "$RUNV" 'archive.get("sealed_at")')"
resume_archive view
wait "$BG"; BG=""
wait "$BG2"; AV=$?; BG2=""
it "S10: once the view is written the seal commits on the same capture"
check "0" "$AV"
VIEWB="$(shasum -a 256 "$(home_of "$RUNV")/views/view.json")"
BASEV="$(inventory "$RUNV")"
prog status --run "$RUNV"
prog check-archive --run "$RUNV"
CLAUDE_AUTO_TEST_ARCHIVE_PAUSE_VIEW=1 prog dispose-item linear:AI-2 --as stopped_unfinished --why late --run "$RUNV"
it "S10: no writer changes a byte after the seal"
check "$BASEV" "$(inventory "$RUNV")"
it "S10: the view bytes are the seal's"
check "$VIEWB" "$(shasum -a 256 "$(home_of "$RUNV")/views/view.json")"

it "no command crashed with a traceback"
check "" "$CRASHES"

# ── a session closing an ended programme can still ask to take over another space's programme ──
CRUN="$(new_programme w30 sess-closer)"
end_typed "$CRUN" sess-closer
ORUN="$(new_programme w31 sess-away)"
TAKE_OUT="$(HERDR_WORKSPACE_ID=w31 prompt_hook sess-closer "/auto:programme-takeover")"
it "the closing session's prompt is still journaled into the programme it is closing"
has "this session is closing" "$TAKE_OUT"
has "$CRUN" "$TAKE_OUT"
it "its typed takeover request reaches the programme leased in its space"
check "1" "$(run_py "$ORUN" <<'EOF'
print(sum(1 for r in pj.read(args[0]) if r["kind"] == "takeover_request" and r["session_id"] == "sess-closer"))
EOF
)"
it "the closing context names the programme that received the typed request"
has "journaled this /auto:programme-takeover request into programme $ORUN" "$TAKE_OUT"

echo
echo "programme-closure.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
