#!/usr/bin/env bash
# Integrated interruption recovery (U9). Every writer runs as a real programme.py process, is
# paused by a fenced test hatch at a named boundary and killed with SIGKILL; a fresh process
# then recovers and every revision the test saw acknowledged must still be in the store,
# byte for byte. The negative controls at the end rerun sections against a patched copy of
# the plugin and require the named assertions to fail.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="${DURABILITY_AUTO_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
ONLY="${DURABILITY_ONLY:-}"
WORK="$(mktemp -d -t auto-programme-durability.XXXXXX)"
BG=""
trap '[ -n "$BG" ] && kill -9 "$BG" 2>/dev/null; chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
export PYTHONDONTWRITEBYTECODE=1
. "${AUTO_ROOT}/tests/helpers/preserve-fixtures.sh"
# dispatch-fixture's field() (a record expression) replaces preserve-fixtures' JSON field().
. "${AUTO_ROOT}/tests/helpers/dispatch-fixture.sh"
. "${AUTO_ROOT}/tests/helpers/closure-fixture.sh"
OLD_COMMIT="f9934a3"

echo "programme-durability.test.sh"
write_snapshot base

want() { [ -z "$ONLY" ] || case " $ONLY " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
killbg() { [ -n "$BG" ] && { kill -9 "$BG" 2>/dev/null; wait "$BG" 2>/dev/null; }; BG=""; }
jget() { pyget "$1" "$2"; }
lease_file() { printf '%s/programmes/leases/default.%s.json' "$CLAUDE_AUTO_DATA_DIR" "$1"; }

cat > "${WORK}/acked.py" <<'EOF'
import hashlib, json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
st = load_lib_module("programme_store")
cmd, run, path = sys.argv[2:5]


def current():
    with st.open_store(run) as store:
        data = store.read()
        integrity = store.check_integrity()
    rows = [[e["revision"], e["operation_id"], e["kind"],
             hashlib.sha256(json.dumps([e["payload"], e["provenance"], e["at"]], sort_keys=True).encode()).hexdigest()]
            for e in data["events"]]
    return data["revision"], rows, integrity


try:
    acked = json.load(open(path))
except (OSError, ValueError):
    acked = []
try:
    revision, rows, integrity = current()
except st.StoreError as exc:
    print(f"store unreadable: {exc.code}: {exc}")
    raise SystemExit(0)
if cmd == "ack":
    json.dump(rows, open(path, "w"))
    print(revision)
elif cmd == "check":
    problems = []
    if not integrity["ok"]:
        problems.append("integrity: " + json.dumps({k: v for k, v in integrity.items() if v and k != "ok"}))
    have = {(r[0], r[1]): r for r in rows}
    for row in acked:
        if have.get((row[0], row[1])) != row:
            problems.append(f"acknowledged revision {row[0]} ({row[1]}) changed or vanished")
    if acked and revision < max(r[0] for r in acked):
        problems.append(f"head {revision} is behind the acknowledged {max(r[0] for r in acked)}")
    print("intact" if not problems else "; ".join(problems))
EOF

# ack <run>: every event now in the store has been seen acknowledged by the test.
ack() { "$PY" "${WORK}/acked.py" "$AUTO_ROOT" ack "$1" "${WORK}/acked-$1.json" >/dev/null; }
intact() { "$PY" "${WORK}/acked.py" "$AUTO_ROOT" check "$1" "${WORK}/acked-$1.json" 2>&1; }

# interrupt <pause-marker> "<hatch env>" <programme.py args...>: run the writer, kill it at the pause.
INTERRUPTED=""
interrupt() {
  local marker="$1" hatch="$2" out="${WORK}/int.out"
  shift 2
  bg "$out" "$hatch" "$@"
  if wait_for "$out" "$marker"; then INTERRUPTED="paused"; else INTERRUPTED="never paused: $(head -c 300 "$out")"; fi
  killbg
}

# recovered <run> <label>: a fresh process reads the store and every acknowledged revision is intact.
recovered() {
  prog recover --run "$1"
  it "$2: a fresh recover reads the store with no hold"
  check "0 true" "$CODE $(jget "$OUT" '"hold" not in d')"
  it "$2: every acknowledged revision is intact"
  check "intact" "$(intact "$1")"
}

OLD="${WORK}/old/plugins/auto/lib"
mkdir -p "${WORK}/old"
TOP="${DURABILITY_GIT_TOP:-$(git -C "$AUTO_ROOT" rev-parse --show-toplevel 2>/dev/null)}"
if want import || want corrupt; then
it "the obsolete implementation at ${OLD_COMMIT} is extracted to write legacy homes"
if [ -n "$TOP" ] && git -C "$TOP" archive "$OLD_COMMIT" plugins/auto/lib plugins/auto/protocol 2>/dev/null \
     | tar -x -C "${WORK}/old" 2>/dev/null && [ -f "${OLD}/programme.py" ]; then pass; else fail "git archive failed"; fi
fi
legacy() {
  local space="$1" run
  run="$(CLAUDE_CODE_SESSION_ID=sess-pm HERDR_WORKSPACE_ID="$space" "$PY" "${OLD}/programme.py" start --space "default.${space}" 2>&1 \
    | "$PY" -c 'import json,sys; print(json.loads(sys.stdin.read().strip().splitlines()[-1])["run"])')"
  CLAUDE_CODE_SESSION_ID=sess-pm "$PY" "${OLD}/programme.py" add-item linear:AI-7 --title "legacy item" --run "$run" >/dev/null 2>&1
  printf '%s' "$run"
}
legacy_digest() {
  "$PY" - "$(home_of "$1")" "$1" <<'EOF'
import hashlib, os, sys
home, run = sys.argv[1:3]
h = hashlib.sha256()
for rel in (f".claude/auto/{run}.json", "journal.jsonl", "claims.jsonl"):
  p = os.path.join(home, rel)
  h.update(rel.encode() + b"\0" + (open(p, "rb").read() if os.path.exists(p) else b"-"))
print(h.hexdigest())
EOF
}
outcome_of() {
  run_py "$1" <<'EOF'
print(load_lib_module("programme_authority").outcome(args[0])["outcome"])
EOF
}

# ════════════════════════════════════════════════════════════════════════════
# 1. Transaction commit (AE1): kill before and after the commit on each write path.
if want commit; then
  RUN="$(new_programme w2)"
  prog add-item linear:AI-1 --title "browser" --kind fix_only --run "$RUN"
  ack "$RUN"
  # verb args per write path: an ordinary record write, a decision, a journal row.
  PATHS=("set-now|doing A|--run" "record-decision|d-1|--scope|browser only|--reason|first|--run" "beat|--run")
  for spec in "${PATHS[@]}"; do
    IFS='|' read -r -a ARGS <<< "$spec"
    NAME="commit ${ARGS[0]}"
    PRE="$(revision "$RUN")"
    interrupt "paused:before_commit" CLAUDE_AUTO_TEST_STORE_PAUSE_BEFORE_COMMIT=1 "${ARGS[@]}" "$RUN"
    it "$NAME: the writer reached the point before its commit"
    check "paused" "$INTERRUPTED"
    it "$NAME: a kill before commit leaves the revision at the last acknowledged one"
    check "$PRE" "$(revision "$RUN")"
    recovered "$RUN" "$NAME (before commit)"
    prog "${ARGS[@]}" "$RUN"
    it "$NAME: the retry after the kill commits once"
    check "0 $((PRE + 1))" "$CODE $(revision "$RUN")"
    ack "$RUN"
  done

  PRE="$(revision "$RUN")"
  interrupt "paused:after_commit" CLAUDE_AUTO_TEST_STORE_PAUSE_AFTER_COMMIT=1 set-now "doing B" --op op-lost --run "$RUN"
  it "commit lost response: the writer was killed after its commit, before it answered"
  check "paused $((PRE + 1))" "$INTERRUPTED $(revision "$RUN")"
  recovered "$RUN" "commit lost response"
  prog set-now "doing B" --op op-lost --run "$RUN"
  it "commit lost response: a retry with the same --op returns the saved revision, not a new one"
  check "0 true $((PRE + 1)) $((PRE + 1))" "$CODE $(jget "$OUT" 'd.get("replayed")') $(jget "$OUT" 'd.get("revision")') $(revision "$RUN")"
  ack "$RUN"
  prog set-now "doing C" --op op-lost --run "$RUN"
  it "commit: reusing an --op with different input refuses (KTD4)"
  check "1" "$CODE"
  it "commit: the refused reuse does not move the revision"
  check "$((PRE + 1))" "$(revision "$RUN")"

  PRE="$(revision "$RUN")"
  interrupt "paused:after_commit" "CLAUDE_AUTO_TEST_STORE_PAUSE_AFTER_COMMIT=1 CLAUDE_CODE_SESSION_ID=sess-w1" \
    claim --item linear:AI-1 --deliverable merged --ref pr-1 --run "$RUN"
  it "commit claim: a claim killed after its commit is kept"
  check "$((PRE + 1))" "$(revision "$RUN")"
  recovered "$RUN" "commit claim"
  CLAUDE_CODE_SESSION_ID=sess-w1 prog claim --item linear:AI-1 --deliverable merged --ref pr-1 --run "$RUN"
  # Known limit, pinned: claims carry no --op, so a retried claim adds a second identical row.
  it "commit claim: a retried claim after a lost response appends a second identical claim row (known limit)"
  check "0 2" "$CODE $(run_py "$RUN" <<'EOF'
print(pj.claims_count(args[0]))
EOF
)"
  ack "$RUN"
fi

# ════════════════════════════════════════════════════════════════════════════
# 2. Export refresh: the exports are rebuilt after the commit and never read back as state.
if want export; then
  RUN="$(new_programme w3)"
  HOME_DIR="$(home_of "$RUN")"
  prog add-item linear:AI-1 --title "export" --run "$RUN"
  ack "$RUN"
  export_tag() { "$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["projection_of_revision"])' "${HOME_DIR}/.claude/auto/${RUN}.json" 2>&1; }
  journal_lines() { wc -l < "${HOME_DIR}/journal.jsonl" | tr -d ' '; }

  PRE="$(revision "$RUN")"
  LINES="$(journal_lines)"
  interrupt "paused:export_midway" CLAUDE_AUTO_TEST_EXPORT_PAUSE_MIDWAY=1 set-now "half exported" --run "$RUN"
  it "export midway: the writer was killed after writing one export file of three"
  check "paused" "$INTERRUPTED"
  it "export midway: the commit before the export is kept"
  check "$((PRE + 1))" "$(revision "$RUN")"
  it "export midway: the record export is new and the journal export still old (mixed revisions on disk)"
  check "$((PRE + 1)) ${LINES}" "$(export_tag) $(journal_lines)"
  ack "$RUN"
  recovered "$RUN" "export midway"
  prog set-now "next write" --run "$RUN"
  it "export midway: the next write accepts the half-written exports as its own, not a foreign writer"
  check "0 0" "$CODE $(find "$HOME_DIR" -name '*.foreign-*' | wc -l | tr -d ' ')"
  it "export midway: no foreign-write event is absorbed"
  check "0" "$(run_py "$RUN" <<'EOF'
print(sum(1 for e in load_lib_module("programme_authority").snapshot(args[0])["events"] if "foreign" in e["kind"]))
EOF
)"
  it "export midway: the exports now match the head revision"
  check "$(revision "$RUN") $(run_py "$RUN" <<'EOF'
print(len(load_lib_module("programme_authority").snapshot(args[0])["journal"]))
EOF
)" "$(export_tag) $(journal_lines)"
  ack "$RUN"

  PRE="$(revision "$RUN")"
  interrupt "paused:after_commit" CLAUDE_AUTO_TEST_STORE_PAUSE_AFTER_COMMIT=1 set-now "never exported" --run "$RUN"
  it "export not started: the exports stay at the earlier revision"
  check "$((PRE + 1)) ${PRE}" "$(revision "$RUN") $(export_tag)"
  ack "$RUN"
  prog status --run "$RUN" --json
  it "export not started: status reads the store, not the stale export"
  has "never exported" "$OUT"
  prog recover --rebuild-projections --run "$RUN"
  it "export not started: recover --rebuild-projections brings the exports to the head"
  check "0 $((PRE + 1))" "$CODE $(export_tag)"
  it "export not started: every acknowledged revision is intact"
  check "intact" "$(intact "$RUN")"
fi

# ════════════════════════════════════════════════════════════════════════════
# 3. Payload sync: result bytes are synced before the reference commit; a kill between leaves
#    unreferenced bytes only.
if want payload; then
  RUN="$(new_programme w4)"
  HOME_DIR="$(home_of "$RUN")"
  prog add-item linear:AI-1 --title "payload" --run "$RUN"
  ack "$RUN"
  mkdir -p "${WORK}/results"
  printf 'browser run: 12 passed\n' > "${WORK}/results/out.txt"
  R_SHA="$(shasum -a 256 "${WORK}/results/out.txt" | cut -d' ' -f1)"
  objects() { find "${HOME_DIR}/artifacts/objects" -type f 2>/dev/null | wc -l | tr -d ' '; }

  for point in ARTIFACT_PAUSE_BEFORE_COMMIT STORE_PAUSE_BEFORE_COMMIT; do
    PRE="$(revision "$RUN")"
    MARK="paused:artifact_before_commit"
    [ "$point" = STORE_PAUSE_BEFORE_COMMIT ] && MARK="paused:before_commit"
    interrupt "$MARK" "CLAUDE_AUTO_TEST_${point}=1" collect-result --item linear:AI-1 --attempt a1 \
      --source out.txt --root "${WORK}/results" --op "op-collect-${point}" --run "$RUN"
    it "payload ${point}: the collector was killed after syncing the bytes, before the reference commit"
    check "paused ${PRE}" "$INTERRUPTED $(revision "$RUN")"
    it "payload ${point}: the synced object is on disk under its digest"
    check "1" "$(objects)"
    it "payload ${point}: no result names the unreferenced bytes"
    check "[]" "$(field "$RUN" 'sorted((prog.get("retained") or {}).get("results") or {})')"
    recovered "$RUN" "payload ${point}"
  done
  prog collect-result --item linear:AI-1 --attempt a1 --source out.txt --root "${WORK}/results" \
    --op op-collect-STORE_PAUSE_BEFORE_COMMIT --run "$RUN"
  it "payload: the retry commits the reference and reuses the synced object"
  check "0 ${R_SHA} 1" "$CODE $(jget "$OUT" 'd["ref"]["digest"]') $(objects)"
  ack "$RUN"
  printf 'other bytes\n' > "${WORK}/results/other.txt"
  PRE="$(revision "$RUN")"
  prog collect-result --item linear:AI-1 --attempt a1 --source other.txt --root "${WORK}/results" \
    --op op-collect-STORE_PAUSE_BEFORE_COMMIT --run "$RUN"
  it "payload: reusing the collect --op for different bytes refuses (KTD4)"
  check "1 ${PRE}" "$CODE $(revision "$RUN")"
  PRE="$(revision "$RUN")"
  printf 'second result\n' > "${WORK}/results/two.txt"
  CLAUDE_AUTO_TEST_ARTIFACT_FAIL_DIR_SYNC=1 prog collect-result --item linear:AI-1 --attempt a2 \
    --source two.txt --root "${WORK}/results" --run "$RUN"
  it "payload: a failed directory sync is never acknowledged as collected"
  check "1" "$CODE"
  it "payload: the failed collection records no captured result"
  check "[]" "$(field "$RUN" '[k for k, r in prog["retained"]["results"].items() if "a2" in k and r.get("status") == "captured"]')"
  it "payload: every acknowledged revision is intact after the failure"
  check "intact" "$(intact "$RUN")"
fi

# ════════════════════════════════════════════════════════════════════════════
# 4. Import promotion: a legacy JSON programme moves into programme.db in one commit.
if want import; then
  for point in IMPORT_PAUSE_AFTER_FREEZE STORE_PAUSE_BEFORE_COMMIT STORE_PAUSE_AFTER_COMMIT; do
    case "$point" in
      IMPORT_PAUSE_AFTER_FREEZE) SP=w11; MARK="paused:after_freeze" ;;
      STORE_PAUSE_BEFORE_COMMIT) SP=w12; MARK="paused:before_commit" ;;
      *) SP=w13; MARK="paused:after_commit" ;;
    esac
    LRUN="$(legacy "$SP")"
    BEFORE="$(legacy_digest "$LRUN")"
    interrupt "$MARK" "CLAUDE_AUTO_TEST_${point}=1" promote --run "$LRUN"
    it "import ${point}: the promotion was killed at its pause"
    check "paused" "$INTERRUPTED"
    prog recover --run "$LRUN"
    if [ "$point" = IMPORT_PAUSE_AFTER_FREEZE ]; then
      it "import ${point}: a fresh recover still reads the legacy programme"
      check "0 legacy" "$CODE $(outcome_of "$LRUN")"
      has "linear:AI-7" "$OUT"
    else
      it "import ${point}: a fresh recover holds on the interrupted import instead of reading an empty programme"
      check "1 unavailable" "$CODE $(outcome_of "$LRUN")"
      has "an import was interrupted" "$OUT"
    fi
    it "import ${point}: the legacy inputs are untouched by the killed import"
    check "$BEFORE" "$(legacy_digest "$LRUN")"
    prog promote --run "$LRUN"
    it "import ${point}: a rerun finishes the promotion"
    check "0" "$CODE"
    has "promoted" "$OUT"
    it "import ${point}: the promoted store holds the legacy item"
    check '["linear:AI-7"]' "$(field "$LRUN" 'sorted(items)')"
    it "import ${point}: the store passes its integrity check"
    check "intact" "$(intact "$LRUN")"
    it "import ${point}: no import marker is left behind"
    check "absent" "$([ -e "$(home_of "$LRUN")/.import-in-progress" ] && echo present || echo absent)"
    ack "$LRUN"
    prog promote --run "$LRUN"
    it "import ${point}: a second rerun is idempotent"
    check "0 already_promoted intact" "$CODE $(jget "$OUT" 'd["status"]') $(intact "$LRUN")"
  done
fi

# ════════════════════════════════════════════════════════════════════════════
# 5. Lease reconciliation: leases are derived from the committed remit, never committed state.
if want lease; then
  RUN="$(run_py <<'EOF'
print(ph.create_programme(["w5", "w6"], "sess-pm")["run"])
EOF
)"
  ack "$RUN"
  REV="$(revision "$RUN")"
  rm -f "$(lease_file w5)" "$(lease_file w6)"
  interrupt "paused:lease_after_write" CLAUDE_AUTO_TEST_LEASE_PAUSE_AFTER_WRITE=1 reconcile-leases --run "$RUN"
  it "lease: reconcile was killed after rewriting one of two leases"
  check "paused 1" "$INTERRUPTED $(ls "${CLAUDE_AUTO_DATA_DIR}/programmes/leases" | grep -c '^default\.w[56]\.json$')"
  it "lease: the rewritten lease is whole and names the run"
  check "$RUN" "$(cat "$(lease_file w5)" "$(lease_file w6)" 2>/dev/null | "$PY" -c 'import json,sys; print(json.loads(sys.stdin.read())["run"])' 2>&1)"
  it "lease: the kill left the leases lock free and the store unchanged"
  check "$REV intact" "$(revision "$RUN") $(intact "$RUN")"
  prog reconcile-leases --run "$RUN"
  it "lease: a fresh reconcile restores the other lease"
  check "0 1" "$CODE $(jget "$OUT" 'len(d["leases"])')"
  prog reconcile-leases --run "$RUN"
  it "lease: reconcile again writes nothing"
  check "0 []" "$CODE $(jget "$OUT" 'd["leases"]')"
  it "lease: reconciliation never commits a revision"
  check "$REV" "$(revision "$RUN")"
fi

# ════════════════════════════════════════════════════════════════════════════
# 6. Dispatch: the admission commits before the launch; a crash leaves it admitted and unretried.
if want dispatch; then
  RUN="$(new_programme w7)"
  prog add-item linear:AI-1 --title "worker" --run "$RUN"
  ack "$RUN"
  : > "$CALLS"
  interrupt "paused:dispatch_after_invoke" "FAKE_SPINOFF_AGENT=1 CLAUDE_AUTO_TEST_DISPATCH_PAUSE_AFTER_INVOKE=1" \
    start-worker linear:AI-1 --run "$RUN" -- --name w1
  it "dispatch: the dispatcher was killed after the launch, before its receipt"
  check "paused" "$INTERRUPTED"
  ATTEMPT="$(field "$RUN" 'sorted(ops)[0]')"
  it "dispatch: the killed launch is still admitted"
  check "admitted" "$(field "$RUN" "ops['${ATTEMPT}']['state']")"
  ack "$RUN"
  recovered "$RUN" "dispatch"
  prog start-worker linear:AI-1 --run "$RUN" -- --name w1
  it "dispatch: a retry after the crash is refused before any second launch"
  check "1 1" "$CODE $(calls_of spinoff)"
  it "dispatch: the refusal names the unreconciled attempt"
  has "$ATTEMPT" "$OUT"
  prog reconcile-operations --run "$RUN"
  it "dispatch: reconcile settles the launch from the live session"
  check "completed" "$(field "$RUN" "ops['${ATTEMPT}']['state']")"
  it "dispatch: spinoff ran exactly once across crash, retry and reconcile"
  check "1" "$(calls_of spinoff)"
  it "dispatch: every acknowledged revision is intact"
  check "intact" "$(intact "$RUN")"

  prog add-item linear:AI-2 --title "second" --run "$RUN"
  : > "$CALLS"
  bg "${WORK}/d2.out" CLAUDE_AUTO_TEST_DISPATCH_PAUSE_AFTER_ADMISSION=1 start-worker linear:AI-2 --run "$RUN" -- --name w2
  wait_for "${WORK}/d2.out" "paused:dispatch_after_admission"
  end_programme "$RUN" >/dev/null
  resume "$RUN"; wait "$BG"; C=$?; BG=""
  it "dispatch: end between admission and launch refuses the launch"
  check "1 0" "$C $(calls_of spinoff)"
fi

# ════════════════════════════════════════════════════════════════════════════
# 7. Capture verification (AE3, AE4): captured code must re-read and restore before it counts.
if want capture; then
  RUN="$(new_programme w8)"
  HOME_DIR="$(home_of "$RUN")"
  prog add-item linear:AI-1 --title "code" --run "$RUN"
  ack "$RUN"
  SRC="${WORK}/w/rich"
  mkrich "$SRC"
  EXP_TREE="$(tree_digest "$SRC")"
  EXP_INDEX="$(index_listing "$SRC")"
  EXP_HEAD="$(g -C "$SRC" rev-parse HEAD)"
  PRE="$(revision "$RUN")"
  interrupt "paused:preserve_before_rescan" CLAUDE_AUTO_TEST_PRESERVE_PAUSE_BEFORE_RESCAN=1 preserve-code --source "$SRC" --run "$RUN"
  it "capture: the capture was killed after publishing its objects, before verification"
  check "paused ${PRE}" "$INTERRUPTED $(revision "$RUN")"
  recovered "$RUN" "capture"
  prog preserve-code --check --source "$SRC" --run "$RUN"
  it "capture: cleanup of the source is refused after the killed capture"
  check "1" "$CODE"
  prog preserve-code --source "$SRC" --run "$RUN"
  it "capture: a fresh capture verifies and completes"
  check "0 complete" "$CODE $(jget "$OUT" 'd.get("status")')"
  ack "$RUN"
  prog preserve-code --check --source "$SRC" --run "$RUN"
  it "capture: cleanup is allowed only after the verified capture"
  check "0" "$CODE"
  prog preserve-code --source "$SRC" --op cap-1 --run "$RUN"
  prog preserve-code --source "${WORK}/w" --op cap-1 --run "$RUN"
  it "capture: reusing a capture --op for a different source refuses (KTD4)"
  check "1" "$CODE"
  has "operation_conflict" "$OUT"
  ack "$RUN"

  SRC2="${WORK}/w/dropped"
  mkrich "$SRC2"
  CLAUDE_AUTO_TEST_PRESERVE_DROP_OBJECT=1 prog preserve-code --source "$SRC2" --run "$RUN"
  it "capture: a capture missing an object is not reported complete"
  check "1 incomplete" "$CODE $(jget "$OUT" 'd.get("status")')"
  prog preserve-code --check --source "$SRC2" --run "$RUN"
  it "capture: cleanup stays blocked when verification found a missing object"
  check "1" "$CODE"

  SRC3="${WORK}/w/moving"
  mkrich "$SRC3"
  rm -f "${HOME_DIR}/.test-resume-preserve"
  bg "${WORK}/c3.out" CLAUDE_AUTO_TEST_PRESERVE_PAUSE_BEFORE_RESCAN=1 preserve-code --source "$SRC3" --run "$RUN"
  wait_for "${WORK}/c3.out" "paused:preserve_before_rescan"
  printf 'written during capture\n' >> "${SRC3}/new.txt"
  touch "${HOME_DIR}/.test-resume-preserve"
  wait "$BG"; C=$?; BG=""
  rm -f "${HOME_DIR}/.test-resume-preserve"
  it "capture: a source written during capture is refused as not quiescent"
  check "1" "$C"
  has "quiescence_uncertain" "$(cat "${WORK}/c3.out")"

  # AE3: the verified capture and a collected result restore after the source is removed.
  mkdir -p "${WORK}/results"
  printf 'worker result bytes\n' > "${WORK}/results/r.txt"
  prog collect-result --item linear:AI-1 --attempt a1 --source r.txt --root "${WORK}/results" --run "$RUN"
  DIG="$(jget "$OUT" 'd["ref"]["digest"]')"
  ack "$RUN"
  SID="$(run_py "$RUN" "$SRC" <<'EOF'
print(load_lib_module("programme_preserve").source_key(os.path.realpath(args[1])))
EOF
)"
  rm -rf "$SRC" "${WORK}/results"
  OUTR="$(pp restore "{\"run\": \"$RUN\", \"source\": \"$SID\", \"dest\": \"${WORK}/restored\"}")"
  it "AE3: the code restores after its source is removed"
  check "true" "$(jget "$OUTR" 'd.get("ok")')"
  it "AE3: the restored worktree, index and head match the removed source"
  check "${EXP_TREE}|${EXP_INDEX}|${EXP_HEAD}" "$(tree_digest "${WORK}/restored")|$(index_listing "${WORK}/restored")|$(g -C "${WORK}/restored" rev-parse HEAD)"
  it "AE3: the collected result reads back from the home without its source"
  check "$DIG" "$(run_py "$RUN" "$DIG" <<'EOF'
pa = load_lib_module("programme_artifacts")
ps = load_lib_module("programme_store")
data = pa.read_object(args[0], ps.PayloadRef(args[1], 20, "text/plain"))
import hashlib; print(hashlib.sha256(data).hexdigest())
EOF
)"
  it "capture: every acknowledged revision is intact"
  check "intact" "$(intact "$RUN")"
fi

# ════════════════════════════════════════════════════════════════════════════
# 8. End (AE5): the end commit closes admission even when the process dies right after it.
if want end; then
  RUN="$(new_programme w9)"
  prog add-item linear:AI-1 --title "end" --run "$RUN"
  ack "$RUN"
  end_request() {
    local pid
    pid="$(typed_in "$1" sess-pm "/auto:programme-end")"
    run_py "$1" sess-pm "$pid" <<'EOF' >/dev/null
pj.append(args[0], "end_request", args[1], {"verb": "end", "text": "/auto:programme-end", "origin": "typed",
                                            "driving": True, "lease_status": "live",
                                            "source": pj.find_prompt(args[0], args[2])["payload"]["source"]},
          cites=[args[2]])
EOF
  }
  end_request "$RUN"
  ack "$RUN"
  PRE="$(revision "$RUN")"
  interrupt "paused:before_commit" CLAUDE_AUTO_TEST_STORE_PAUSE_BEFORE_COMMIT=1 end --run "$RUN"
  it "end: killed before its commit, the programme is not ended"
  check "paused ${PRE} false" "$INTERRUPTED $(revision "$RUN") $(field "$RUN" 'bool(prog.get("ended"))')"
  recovered "$RUN" "end (before commit)"
  interrupt "paused:archive_after_end_commit" CLAUDE_AUTO_TEST_ARCHIVE_PAUSE_AFTER_END_COMMIT=1 end --run "$RUN"
  it "end: killed after the end commit, before releasing leases"
  check "paused" "$INTERRUPTED"
  it "end: the end is committed"
  check "true" "$(field "$RUN" 'bool(prog.get("ended"))')"
  ack "$RUN"
  recovered "$RUN" "end (after commit)"
  REV="$(revision "$RUN")"
  prog add-item linear:AI-9 --title late --run "$RUN"
  it "end: admission stays closed for a new item"
  check "1" "$CODE"
  prog start-worker linear:AI-1 --run "$RUN" -- --name late
  it "end: admission stays closed for a launch"
  check "1 0" "$CODE $(calls_of 'spinoff')"
  it "end: the refusals moved no revision"
  check "$REV" "$(revision "$RUN")"
  prog release-resources --run "$RUN"
  it "end: release-resources settles the lease the kill left behind"
  check "released absent" "$(arch_field "$RUN" 'closure["resources"]["lease:default.w9"]["state"]') $([ -e "$(lease_file w9)" ] && echo present || echo absent)"
  ack "$RUN"
  it "end: every acknowledged revision is intact"
  check "intact" "$(intact "$RUN")"
fi

# ════════════════════════════════════════════════════════════════════════════
# 9. Sealing (AE5, AE6): the archive seals once; retries replay the seal.
if want seal; then
  ready() {
    local run
    run="$(new_programme "$1")"
    prog add-item linear:AI-1 --title "unfinished" --run "$run" >/dev/null
    end_typed "$run" >/dev/null
    prog dispose-item linear:AI-1 --as stopped_unfinished --why "stopped" --run "$run" >/dev/null
    printf '%s' "$run"
  }
  seal_rows() {
    "$PY" -c 'import sqlite3, sys; c = sqlite3.connect("file:" + sys.argv[1] + "?mode=ro", uri=True); print(c.execute("SELECT COUNT(*) FROM meta WHERE key = ?", ("sealed",)).fetchone()[0])' \
      "$(home_of "$1")/programme.db"
  }
  for point in STORE_PAUSE_BEFORE_COMMIT ARCHIVE_PAUSE_AFTER_CANDIDATE STORE_PAUSE_AFTER_COMMIT; do
    case "$point" in
      STORE_PAUSE_BEFORE_COMMIT) SP=w20; MARK="paused:before_commit" ;;
      ARCHIVE_PAUSE_AFTER_CANDIDATE) SP=w21; MARK="paused:archive_after_candidate" ;;
      *) SP=w22; MARK="paused:after_commit" ;;
    esac
    RUN="$(ready "$SP")"
    ack "$RUN"
    PRE="$(revision "$RUN")"
    interrupt "$MARK" "CLAUDE_AUTO_TEST_${point}=1" archive --run "$RUN" --op "seal-${SP}"
    it "seal ${point}: the archive was killed at its pause"
    check "paused" "$INTERRUPTED"
    if [ "$point" = STORE_PAUSE_AFTER_COMMIT ]; then
      it "seal ${point}: the seal committed before the kill"
      check "1 $((PRE + 1))" "$(seal_rows "$RUN") $(revision "$RUN")"
      ack "$RUN"
    else
      it "seal ${point}: nothing is sealed and the revision is unchanged"
      check "0 ${PRE}" "$(seal_rows "$RUN") $(revision "$RUN")"
      prog add-item linear:AI-9 --title late --run "$RUN"
      it "seal ${point}: admission stays closed while unsealed"
      check "1" "$CODE"
    fi
    prog archive --run "$RUN" --op "seal-${SP}"
    it "seal ${point}: the retry with the same --op ends sealed"
    check "0 1" "$CODE $(seal_rows "$RUN")"
    ack "$RUN"
    prog archive --run "$RUN" --op "seal-${SP}"
    it "seal ${point}: a further retry replays the seal without a second seal row"
    check "0 already_sealed true 1" "$CODE $(jget "$OUT" 'd["status"]') $(jget "$OUT" 'd["replayed"]') $(seal_rows "$RUN")"
    prog check-archive --run "$RUN"
    it "seal ${point}: the sealed manifest reads back"
    check "0" "$CODE"
    it "seal ${point}: every acknowledged revision is intact"
    check "intact" "$(intact "$RUN")"
    it "seal ${point}: the unfinished item is archived as stopped, not done (AE6)"
    check "stopped_unfinished open" "$(arch_field "$RUN" 'closure["dispositions"]["linear:AI-1"]["as"]') $(field "$RUN" "items['linear:AI-1']['state']")"
  done
  # Known limit, pinned (residual 16): a kill right after the seal commit leaves the exports at the
  # pre-seal revision; the sealed store is the authority and nothing rebuilds them.
  it "seal: after a kill right after the seal commit the record export stays at the pre-seal revision (known limit)"
  check "$((PRE))" "$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["projection_of_revision"])' "$(home_of "$RUN")/.claude/auto/${RUN}.json" 2>&1)"

  # AE5: an unreadable required result blocks the archive; the end and the bytes stay.
  RUN="$(new_programme w23)"
  prog add-item linear:AI-1 --title "result" --run "$RUN" >/dev/null
  mkdir -p "${WORK}/results5"
  printf 'needed result\n' > "${WORK}/results5/n.txt"
  prog collect-result --item linear:AI-1 --attempt a1 --source n.txt --root "${WORK}/results5" --run "$RUN"
  NDIG="$(jget "$OUT" 'd["ref"]["digest"]')"
  end_typed "$RUN" >/dev/null
  prog dispose-item linear:AI-1 --as stopped_unfinished --why "stopped" --run "$RUN" >/dev/null
  ack "$RUN"
  OBJ="$(home_of "$RUN")/artifacts/objects/${NDIG:0:2}/${NDIG}"
  chmod u+w "$OBJ" 2>/dev/null; printf 'garbled' > "$OBJ"
  prog archive --run "$RUN"
  it "AE5: archive refuses when a required result is unreadable"
  check "1 0" "$CODE $(seal_rows "$RUN")"
  has "failed" "$OUT"
  it "AE5: the refusal leaves the programme ended with admission closed"
  prog add-item linear:AI-9 --title late --run "$RUN"
  check "1 true" "$CODE $(field "$RUN" 'bool(prog.get("ended"))')"
  it "AE5: the damaged object is retained, not deleted"
  check "present" "$([ -e "$OBJ" ] && echo present || echo absent)"
  it "AE5: every acknowledged revision is intact"
  check "intact" "$(intact "$RUN")"
fi

# ════════════════════════════════════════════════════════════════════════════
# 10. AE7, AE8 across a crash: a denial and requirement links survive; relevance gates acceptance.
if want acceptance; then
  RUN="$(new_programme w24)"
  prog add-item linear:AI-1 --title "browser acceptance" --kind fix_only --run "$RUN"
  prog add-item linear:AI-2 --title "linux investigation" --run "$RUN"
  P1="$(typed_in "$RUN" sess-pm "define requirement r-browser")"
  prog define-requirement r-browser --text "browser flow works" --check linear:AI-1=merged --prompt "$P1" --run "$RUN"
  it "AE7: the browser requirement is defined from a typed prompt"
  check "0" "$CODE"
  ack "$RUN"
  REQS="$(jget "$(CLAUDE_CODE_SESSION_ID=sess-x "$PY" "$PROG" context --run "$RUN" 2>&1)" 'd["requirements"]')"
  interrupt "paused:after_commit" CLAUDE_AUTO_TEST_STORE_PAUSE_AFTER_COMMIT=1 record-denial --tool Bash \
    --action start_worker --reason "permission denied for spinoff" --item linear:AI-2 --run "$RUN"
  it "AE8: the denial write was killed after its commit"
  check "paused" "$INTERRUPTED"
  ack "$RUN"
  recovered "$RUN" "AE8"
  PK="$(CLAUDE_CODE_SESSION_ID=sess-replacement "$PY" "$PROG" context --item linear:AI-2 --run "$RUN" 2>&1)"
  it "AE8: a replacement session sees the denial"
  has "permission denied for spinoff" "$(jget "$PK" 'd["denials"]')"
  it "AE8: the requirements are unchanged by the denial"
  check "$REQS" "$(jget "$(CLAUDE_CODE_SESSION_ID=sess-x "$PY" "$PROG" context --run "$RUN" 2>&1)" 'd["requirements"]')"
  prog start-worker linear:AI-2 --run "$RUN" -- --name linux
  it "AE8: the denial binds the item after recovery"
  check "1" "$CODE"
  has "denied" "$OUT"
  prog raise-blocker b1 --requirement r-browser --check linear:AI-1=merged --dependency linear:AI-2 \
    --unblock "linux probe passes" --run "$RUN"
  it "AE7: an open unrelated investigation cannot block browser acceptance without dependency evidence"
  check "1" "$CODE"
  it "AE7: r-browser carries no blocker from the open investigation"
  check "[]" "$(jget "$("$PY" "$PROG" status --run "$RUN" --json 2>&1)" '[b["id"] for b in d["model"]["acceptance"]["blockers"]]')"
  prog raise-blocker b2 --requirement r-browser --check linear:AI-1=merged --dependency linear:AI-2 \
    --evidence trace:t-linux-1 --unblock "linux probe passes" --run "$RUN"
  it "AE7: a blocker with named dependency evidence is recorded against r-browser"
  check "0 [\"r-browser\"]" "$CODE $(jget "$("$PY" "$PROG" status --run "$RUN" --json 2>&1)" '[b["requirement"] for b in d["model"]["acceptance"]["blockers"]]')"
  ack "$RUN"
  it "AE7/AE8: every acknowledged revision is intact"
  check "intact" "$(intact "$RUN")"
fi

# ════════════════════════════════════════════════════════════════════════════
# 11. Corrupt and unknown inputs never become empty state or approval.
if want corrupt; then
  RUN="$(new_programme w25)"
  prog add-item linear:AI-1 --title "keep me" --run "$RUN"
  DB="$(home_of "$RUN")/programme.db"
  "$PY" - "$DB" <<'EOF'
import sys
with open(sys.argv[1], "r+b") as fh:
    fh.seek(100)
    fh.write(b"\xff" * 4000)
EOF
  prog recover --run "$RUN"
  it "corrupt: recover over a damaged store exits 1 with a hold"
  check "1 true" "$CODE $(jget "$OUT" '"hold" in d')"
  prog status --run "$RUN" --json
  it "corrupt: status never shows an empty programme in place of the damaged one"
  lacks '"items": {}' "$OUT"
  prog add-item linear:AI-2 --title "new" --run "$RUN"
  it "corrupt: a writer refuses rather than recreating the store"
  check "1" "$CODE"

  RUN="$(new_programme w26)"
  P_CRON="$(typed_in "$RUN" sess-pm "accept the agreement" cron)"
  prog propose-agreement --run "$RUN"
  prog accept-agreement --prompt "$P_CRON" --run "$RUN"
  it "provenance: a prompt a cron job injected approves nothing"
  check "1" "$CODE"
  prog accept-agreement --prompt p0123456789abcdef --run "$RUN"
  it "provenance: a prompt id the journal does not hold approves nothing"
  check "1" "$CODE"
  it "provenance: the agreement stays unaccepted"
  check "null" "$(field "$RUN" '(prog.get("agreement") or {}).get("accepted")')"
  it "provenance: no decision or prompt in the store is origin-verified"
  check "[]" "$(run_py "$RUN" <<'EOF'
snap = load_lib_module("programme_authority").snapshot(args[0])
print(json.dumps(sorted({r.get("kind") for r in snap["journal"] if (r.get("payload") or {}).get("origin_verified") is True})))
EOF
)"

  if [ -f "${OLD}/programme.py" ]; then
    LRUN="$(legacy w27)"
    printf '{not json\n' >> "$(home_of "$LRUN")/journal.jsonl"
    prog promote --run "$LRUN"
    it "malformed legacy: a promote over an unparseable journal line keeps the content and names the gap"
    check "0 promoted" "$CODE $(jget "$OUT" 'd["status"]')"
    check '["linear:AI-7"] ["unparseable_line"]' "$(field "$LRUN" 'sorted(items)') $(run_py "$LRUN" <<'EOF'
ev = [e for e in load_lib_module("programme_authority").snapshot(args[0])["events"] if e["kind"] == "legacy_import"][0]
print(json.dumps(sorted({g["kind"] for g in ev["payload"]["gaps"]})))
EOF
)"
  fi
fi

# ════════════════════════════════════════════════════════════════════════════
# Negative controls: each patch removes one protection in an isolated copy of the plugin; the
# named assertions above must then fail. Skipped inside a control run.
if [ -z "${DURABILITY_CONTROL:-}" ] && want controls; then
  control() {
    local name="$1" sections="$2" file="$3" expr="$4"
    shift 4
    local copy="${WORK}/control-${name}/plugins/auto" log="${WORK}/control-${name}.log"
    mkdir -p "$copy"
    (cd "${AUTO_ROOT}" && tar --exclude '__pycache__' -cf - lib .claude protocol tests/helpers tests/fixtures 2>/dev/null) | tar -xf - -C "$copy"
    cp "${copy}/lib/${file}" "${copy}/lib/${file}.orig"
    "$PY" - "${copy}/lib/${file}" "$expr" <<'EOF'
import sys
path, expr = sys.argv[1], sys.argv[2]
old, new = expr.split("\n=>\n")
text = open(path).read()
if text.count(old) != 1:
    raise SystemExit(f"patch anchor found {text.count(old)} times")
open(path, "w").write(text.replace(old, new))
EOF
    local patched=$?
    it "control ${name}: the patch applies to the copy"
    check "0 differ" "$patched $(cmp -s "${copy}/lib/${file}" "${copy}/lib/${file}.orig" && echo same || echo differ)"
    DURABILITY_CONTROL=1 DURABILITY_AUTO_ROOT="$copy" DURABILITY_ONLY="$sections" DURABILITY_GIT_TOP="$TOP" \
      bash "${SCRIPT_DIR}/programme-durability.test.sh" > "$log" 2>&1
    local code=$?
    it "control ${name}: the patched run fails"
    check "1" "$code"
    local want_fail
    for want_fail in "$@"; do
      it "control ${name}: [${want_fail}] fails"
      if sed $'s/\x1b\\[[0-9;]*m//g' "$log" | grep -F "✗ ${want_fail}" >/dev/null; then pass
      else fail "not red: $(sed $'s/\x1b\\[[0-9;]*m//g' "$log" | grep '✗' | head -5 | tr '\n' '|')"; fi
    done
  }

  BASE="${WORK}/control-baseline/plugins/auto"
  mkdir -p "$BASE"
  (cd "${AUTO_ROOT}" && tar --exclude '__pycache__' -cf - lib .claude protocol tests/helpers tests/fixtures 2>/dev/null) | tar -xf - -C "$BASE"
  DURABILITY_CONTROL=1 DURABILITY_AUTO_ROOT="$BASE" DURABILITY_ONLY="commit dispatch capture" DURABILITY_GIT_TOP="$TOP" \
    bash "${SCRIPT_DIR}/programme-durability.test.sh" > "${WORK}/control-baseline.log" 2>&1
  it "control baseline: the unpatched copy passes the sections the controls rerun"
  check "0" "$?"

  control split-commit commit programme_store.py "$(printf '%s\n=>\n%s' \
'    conn.execute("UPDATE authority SET revision = ?, state = ? WHERE id = 1 AND revision = ?",
                 (revision, canonical(state), current))' \
'    conn.execute("UPDATE authority SET revision = ?, state = ? WHERE id = 1 AND revision = ?",
                 (revision, canonical(state), current))
    conn.execute("COMMIT")
    conn.execute("BEGIN IMMEDIATE")')" \
    "commit set-now: a kill before commit leaves the revision at the last acknowledged one" \
    "commit set-now (before commit): every acknowledged revision is intact"

  control no-dispatch-fence dispatch programme_recovery.py "$(printf '%s\n=>\n%s' \
'    for prior in unreconciled_admissions(programme):' \
'    for prior in []:')" \
    "dispatch: a retry after the crash is refused before any second launch" \
    "dispatch: the refusal names the unreconciled attempt" \
    "dispatch: spinoff ran exactly once across crash, retry and reconcile"

  control no-capture-verify capture programme_preserve.py "$(printf '%s\n=>\n%s' \
'    report = _verify_stored(run_id, stored, inv)' \
'    report = {"ok": True, "reasons": [], "mismatches": []}')" \
    "capture: a capture missing an object is not reported complete" \
    "capture: cleanup stays blocked when verification found a missing object"
fi

echo ""
it "no programme.py call crashed with a traceback"
check "" "$CRASHES"
echo "programme-durability.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
