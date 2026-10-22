#!/usr/bin/env bash
# End, checked archive and successor (U7): end fences new work and records what is owed; archive
# checks the capture, seals once and leaves the home read-only; a successor links the archive and
# waits for its own acceptance. Nothing here stops a real process or deletes retained data.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
WORK="$(mktemp -d -t auto-programme-archive.XXXXXX)"
SLEEPER=""
trap '[ -n "$SLEEPER" ] && kill "$SLEEPER" 2>/dev/null; rm -rf "$WORK"' EXIT
. "${AUTO_ROOT}/tests/helpers/dispatch-fixture.sh"
. "${AUTO_ROOT}/tests/helpers/closure-fixture.sh"

echo "programme-archive.test.sh"
write_snapshot base
mkdir -p "${WORK}/results"
printf 'browser run: 12 passed\n' > "${WORK}/results/out.txt"

# ── AE5: an unreadable required result and an unresolved watcher block the archive ──
RUN="$(new_programme w2)"
HOME_DIR="$(home_of "$RUN")"
prog add-item linear:AI-1 --title "browser" --run "$RUN"
prog collect-result --run "$RUN" --item linear:AI-1 --attempt a1 --source out.txt --root "${WORK}/results"
DIGEST="$(pyget "$OUT" 'd["ref"]["digest"]')"
sleep 300 &
SLEEPER=$!
prog set-waiting linear:AI-1 --who ci --watcher w-ci --process-id "$SLEEPER" --run "$RUN"
prog watcher-beat w-mon --task-id bh1mon --kind monitor --run "$RUN"
end_typed "$RUN"
it "end commits for a programme with a live watcher process"
check 0 "$CODE"
it "the end commit records what the programme owes: its lease, both watchers"
check '["lease:default.w2", "watcher:w-ci", "watcher:w-mon"]' "$(arch_field "$RUN" 'sorted(closure["resources"])')"
it "the end commit names the session that ended it"
check "sess-pm" "$(arch_field "$RUN" 'closure["ended_by"]')"
it "the lease release after end has a receipt"
check "released" "$(arch_field "$RUN" 'closure["resources"]["lease:default.w2"]["state"]')"
it "the lease file is gone"
check "no" "$([ -e "${CLAUDE_AUTO_DATA_DIR}/programmes/leases/default.w2.json" ] && echo yes || echo no)"

chmod 600 "${HOME_DIR}/artifacts/objects/${DIGEST:0:2}/${DIGEST}"
printf 'browser run: 12 FAILED\n' > "${HOME_DIR}/artifacts/objects/${DIGEST:0:2}/${DIGEST}"
REV0="$(revision "$RUN")"
prog archive --run "$RUN"
it "AE5: archive with an unreadable result and an unresolved watcher exits 1"
check 1 "$CODE"
it "AE5: the refusal names exactly the failed checks"
check '["dispositions", "resources", "results"]' "$(pyget "$OUT" 'sorted(c["check"] for c in d["checks"] if not c["ok"])')"
it "AE5: the unreadable result is named with its reason"
check '[["result:linear:AI-1/a1/out.txt", "digest_mismatch"]]' \
  "$(pyget "$OUT" '[[f["id"], f["reason"]] for c in d["checks"] if c["check"] == "results" for f in c["failures"]]')"
it "AE5: the failed check carries a specific remedy"
has "restore" "$(pyget "$OUT" '[c["remedy"] for c in d["checks"] if c["check"] == "results"][0]')"
it "AE5: both watchers are named, still owed"
check '["watcher:w-ci", "watcher:w-mon"]' "$(pyget "$OUT" 'sorted(f["id"] for c in d["checks"] if c["check"] == "resources" for f in c["failures"])')"
it "AE5: nothing is sealed"
check "null" "$(arch_field "$RUN" 'archive.get("sealed_at")')"
it "AE5: the failed attempt is recorded with its capture revision"
check "$REV0" "$(arch_field "$RUN" 'archive["attempts"][-1]["capture_revision"]')"
it "AE5: the programme stays ended"
check "ended_by_shawn" "$(arch_field "$RUN" 'prog["ended"]["reason"]')"
prog add-item linear:AI-9 --title "new work" --run "$RUN"
it "AE5: new work stays refused after the failed archive"
check 1 "$CODE"
: > "$CALLS"
prog start-worker linear:AI-1 --run "$RUN" -- --name again
it "AE5: no worker is launched after end"
check "1 0" "$CODE $(calls_of spinoff)"

# ── release receipts: no process is ever stopped ──
prog release-resources --run "$RUN"
it "a live watcher pid stays unconfirmed"
check "unconfirmed" "$(arch_field "$RUN" 'closure["resources"]["watcher:w-ci"]["state"]')"
it "the probe never stopped the process"
check "alive" "$(kill -0 "$SLEEPER" 2>/dev/null && echo alive || echo gone)"
it "a monitor watcher waits for the PM's TaskStop report"
check "pending" "$(arch_field "$RUN" 'closure["resources"]["watcher:w-mon"]["state"]')"
prog release-resources --run "$RUN" --watcher w-mon --denied --why "TaskStop was denied"
it "a denied TaskStop leaves the watcher unconfirmed"
check "unconfirmed denied" "$(arch_field "$RUN" 'closure["resources"]["watcher:w-mon"]["state"] + " " + closure["resources"]["watcher:w-mon"]["parts"]["task"]')"
it "a reused process id (another live process) is unconfirmed, never treated as gone"
REUSED="$(new_programme w4)"
prog watcher-beat w-x --process-id "$$" --run "$REUSED"
run_py "$REUSED" <<'EOF' >/dev/null
ph.end_programme(args[0], "ended_by_shawn")
EOF
prog release-resources --run "$REUSED"
check "unconfirmed" "$(arch_field "$REUSED" 'closure["resources"]["watcher:w-x"]["state"]')"
it "the test shell whose id was reused is still running"
check "alive" "$(kill -0 "$$" 2>/dev/null && echo alive || echo gone)"
it "the archive module never sends a stopping signal or calls a process killer"
check "0" "$(grep -cE 'os\.kill\([^)]*, *[1-9]|signal\.SIG|pkill|killall|killpg|terminate\(' "${AUTO_ROOT}/lib/programme_archive.py")"
prog archive --run "$RUN"
it "an unconfirmed release keeps the archive blocked"
check 1 "$CODE"

kill "$SLEEPER" 2>/dev/null; wait "$SLEEPER" 2>/dev/null; SLEEPER=""
prog release-resources --run "$RUN" --watcher w-mon --stopped --why "TaskStop bh1mon returned ok"
it "once the test's own process exits, the pid probe confirms it"
check "released" "$(arch_field "$RUN" 'closure["resources"]["watcher:w-ci"]["state"]')"
it "a reported TaskStop releases the monitor watcher"
check "released" "$(arch_field "$RUN" 'closure["resources"]["watcher:w-mon"]["state"]')"
it "each release keeps its receipt trail"
check '["denied", "confirmed"]' "$(arch_field "$RUN" '[r["outcome"] for r in closure["resources"]["watcher:w-mon"]["receipts"]]')"

# ── worker sessions are observed through herdr, never stopped ──
WRUN="$(new_programme w5)"
prog add-item linear:AI-5 --title "worker item" --pane w2:p30 --terminal-id term_p30 --session sess-w1 --run "$WRUN"
run_py "$WRUN" <<'EOF' >/dev/null
ph.end_programme(args[0], "ended_by_shawn")
EOF
: > "$CALLS"
prog release-resources --run "$WRUN"
it "a worker herdr still lists stays unconfirmed"
check "unconfirmed" "$(arch_field "$WRUN" 'closure["resources"]["worker:sess-w1"]["state"]')"
it "release only lists agents; it sends nothing to the worker"
check "0 1" "$(grep -cv '^herdr agent list' "$CALLS") $(calls_of 'herdr agent list')"
"$PY" - "$SNAP" <<'EOF'
import json, sys
doc = json.load(open(sys.argv[1]))
snap = doc["result"]["snapshot"]
snap["agents"] = [a for a in snap["agents"] if (a.get("agent_session") or {}).get("value") != "sess-w1"]
json.dump(doc, open(sys.argv[1], "w"))
EOF
prog release-resources --run "$WRUN"
it "a worker herdr no longer lists is released"
check "released" "$(arch_field "$WRUN" 'closure["resources"]["worker:sess-w1"]["state"]')"
write_snapshot base

# ── AE5 resolved, AE6: unfinished work archives with dispositions, not as passed ──
cp "${WORK}/results/out.txt" "${HOME_DIR}/artifacts/objects/${DIGEST:0:2}/${DIGEST}"
prog check-archive --run "$RUN"
it "once the retained copy's bytes are restored the results check passes"
check "true" "$(pyget "$OUT" '[c["ok"] for c in d["checks"] if c["check"] == "results"][0]')"
prog archive --run "$RUN"
it "an undisposed waiting item still blocks the archive"
check '["dispositions"]' "$(pyget "$OUT" '[c["check"] for c in d["checks"] if not c["ok"]]')"
prog dispose-item linear:AI-1 --as done --why x --run "$RUN"
it "a disposition must be stopped_unfinished or handed_over"
check 2 "$CODE"
prog dispose-item linear:AI-1 --as stopped_unfinished --why "ran out of time; browser flow untested" --run "$RUN"
it "a disposition records how unfinished work stopped"
check 0 "$CODE"
prog check-archive --run "$RUN"
it "check-archive reports the programme ready at the current revision"
check "true $(revision "$RUN")" "$(pyget "$OUT" 'd["ready"]') $(pyget "$OUT" 'd["revision"]')"
CAP="$(revision "$RUN")"
prog archive --run "$RUN" --op seal-ae6
it "AE6: the archive seals"
check 0 "$CODE"
it "AE6: the seal is one commit on top of the capture revision"
check "$CAP $((CAP + 1)) $((CAP + 1))" "$(pyget "$OUT" 'd["capture_revision"]') $(pyget "$OUT" 'd["sealed_revision"]') $(revision "$RUN")"
prog check-archive --run "$RUN"
it "AE6: the manifest lists the item as stopped unfinished"
check '["linear:AI-1"]' "$(pyget "$OUT" 'd["manifest"]["outcomes"]["stopped_unfinished"]')"
it "AE6: nothing is reported completed"
check '[]' "$(pyget "$OUT" 'd["manifest"]["outcomes"]["completed"]')"
it "AE6: the item itself is not marked done"
check "waiting" "$(arch_field "$RUN" 'prog["items"]["linear:AI-1"]["state"]')"
it "AE6: the manifest binds the capture revision and the retained result's digest"
check "$CAP $DIGEST" "$(pyget "$OUT" 'd["manifest"]["capture_revision"]') $(pyget "$OUT" 'd["manifest"]["retained"]["results"]["result:linear:AI-1/a1/out.txt"]')"
it "AE6: the manifest does not hold its own digest"
lacks "$(pyget "$OUT" 'd["archive"]["manifest"]["digest"]')" "$(pyget "$OUT" 'json.dumps(d["manifest"])')"

# ── requirement-linked acceptance survives archive unconfirmed ──
RRUN="$(new_programme w6)"
prog add-item linear:AI-7 --title "browser acceptance" --kind fix_only --run "$RRUN"
P1="$(typed_in "$RRUN" sess-pm "define requirement r-browser")"
prog define-requirement r-browser --text "browser flow works" --check linear:AI-7=merged --prompt "$P1" --run "$RRUN"
end_typed "$RRUN"
prog dispose-item linear:AI-7 --as stopped_unfinished --why "stopped before merge" --run "$RRUN"
prog archive --run "$RRUN"
it "AE6: a programme with an unconfirmed requirement archives"
check 0 "$CODE"
prog check-archive --run "$RRUN"
it "AE6: the archived requirement is not satisfied"
check '[]' "$(pyget "$OUT" 'd["manifest"]["acceptance"]["satisfied"]')"
it "AE6: its check stays not_run in the manifest"
check '["not_run"]' "$(pyget "$OUT" '[c["result"] for r in d["manifest"]["acceptance"]["requirements"] for c in r["checks"]]')"

# ── uncertain actions need a human's typed disposition naming the attempt ──
URUN="$(new_programme w7)"
prog add-item linear:AI-2 --title "prompted item" --pane w2:p30 --terminal-id term_p30 --session sess-w1 --run "$URUN"
bg "${WORK}/send.out" CLAUDE_AUTO_TEST_DISPATCH_PAUSE_AFTER_INVOKE=1 prompt-item linear:AI-2 "please rebase" --run "$URUN"
wait_for "${WORK}/send.out" "paused:dispatch_after_invoke"
kill -9 "$BG"; wait "$BG" 2>/dev/null; BG=""
SEND="$(field "$URUN" "[k for k, o in ops.items() if o['kind'] == 'send'][0]")"
prog reconcile-operations --run "$URUN"
CRON="$(typed_in "$URUN" sess-pm "abandon ${SEND}" cron)"
prog dispose-action --attempt "$SEND" --as abandoned_unknown --prompt "$CRON" --run "$URUN"
it "a cron prompt cannot dispose of an uncertain action"
check 1 "$CODE"
VAGUE="$(typed_in "$URUN" sess-pm "abandon whatever is stuck")"
prog dispose-action --attempt "$SEND" --as abandoned_unknown --prompt "$VAGUE" --run "$URUN"
it "a typed prompt that does not name the attempt is refused"
check 1 "$CODE"
OTHER="$(typed_in "$URUN" sess-w1 "abandon ${SEND}")"
prog dispose-action --attempt "$SEND" --as abandoned_unknown --prompt "$OTHER" --run "$URUN"
it "a prompt typed in another session is refused"
check 1 "$CODE"
prog dispose-action --attempt "$SEND" --as abandoned_unknown --run "$URUN"
it "dispose-action without a prompt is a usage error"
check 2 "$CODE"
end_typed "$URUN"
prog dispose-item linear:AI-2 --as handed_over --why "Shawn finishes the rebase" --run "$URUN"
prog release-resources --run "$URUN"
write_snapshot base
prog archive --run "$URUN"
it "an uncertain send blocks the archive"
check '["operations", "resources"]' "$(pyget "$OUT" 'sorted(c["check"] for c in d["checks"] if not c["ok"])')"
it "the prompt hook still journals a typed prompt in the driving session after end"
HOOK_OUT="$(prompt_hook sess-pm "abandon ${SEND}; also accept worker:sess-w1 as unknown")"
has 'prompt_id' "$HOOK_OUT"
TYPED="$(run_py "$URUN" <<'EOF'
print([r for r in pj.read(args[0]) if r.get("kind") == "prompt"][-1]["prompt_id"])
EOF
)"
prog dispose-action --attempt "$SEND" --as abandoned_unknown --prompt "$TYPED" --run "$URUN"
it "a typed prompt naming the attempt records the disposition"
check 0 "$CODE"
[ "$CODE" = 0 ] || echo "      $OUT"
it "the disposition records origin_verified true: the transcript shows a human typed the prompt"
check "true" "$(pyget "$OUT" 'd["origin_verified"]')"
it "the action is never recorded as completed"
check "uncertain" "$(field "$URUN" "ops['${SEND}']['state']")"
it "it stays listed as unreconciled for recovery"
check "[\"${SEND}\"]" "$(unreconciled "$URUN")"
prog dispose-action --resource worker:sess-w1 --as accepted_unknown --prompt "$TYPED" --run "$URUN"
it "the same prompt names the unconfirmed worker, so it disposes of it too"
check 0 "$CODE"
prog archive --run "$URUN"
it "with both dispositions recorded the archive seals"
check 0 "$CODE"
prog check-archive --run "$URUN"
it "the manifest carries the uncertain send with its disposition"
check "uncertain abandoned_unknown" "$(pyget "$OUT" 'd["manifest"]["operations"]["'"$SEND"'"]["state"] + " " + d["manifest"]["operations"]["'"$SEND"'"]["disposition"]["as"]')"
it "the manifest reports the handed item as handed over"
check '["linear:AI-2"]' "$(pyget "$OUT" 'd["manifest"]["outcomes"]["handed_over"]')"
it "after seal the prompt hook journals nothing"
BEFORE="$(inventory "$URUN")"
prompt_hook sess-pm "anything after the seal" >/dev/null
check "$BEFORE" "$(inventory "$URUN")"

# ── every home mutation refuses after seal ──
SEALED_REV="$(revision "$RUN")"
BEFORE="$(inventory "$RUN")"
refused() {
  it "after seal: $1 is refused"
  shift
  prog "$@"
  [ "$CODE" != 0 ] && pass || fail "exit $CODE: $OUT"
}
refused "add-item" add-item linear:AI-8 --title late --run "$RUN"
refused "beat" beat --run "$RUN"
refused "watcher-beat" watcher-beat w-ci --run "$RUN"
refused "claim" claim --item linear:AI-1 --deliverable merged --ref pr-1 --run "$RUN"
refused "collect-result (a late result)" collect-result --run "$RUN" --item linear:AI-1 --attempt a2 --source out.txt --root "${WORK}/results"
refused "preserve-code" preserve-code --source "$WORK" --run "$RUN"
refused "reconcile-leases" reconcile-leases --run "$RUN"
refused "dispose-item" dispose-item linear:AI-1 --as handed_over --why late --run "$RUN"
refused "release-resources" release-resources --run "$RUN"
refused "dispose-action" dispose-action --attempt op-x --as abandoned_unknown --prompt p1 --run "$RUN"
prog recover --run "$RUN" --rebuild-projections
it "after seal: recover --rebuild-projections rebuilds nothing"
check "null" "$(pyget "$OUT" 'd.get("projections_rebuilt")')"
PRUNE="$("$PY" "${AUTO_ROOT}/lib/programme_journal.py" prune --run "$RUN" 2>&1)"
it "after seal: prune is refused"
has "read-only" "$PRUNE"
it "after seal: promote (lazy migration) changes nothing"
PROMOTE="$(prog promote --run "$RUN"; echo "$OUT")"
has "already_promoted" "$PROMOTE"
it "after seal: a late receipt for a known admission is refused"
LATE="$(run_py "$URUN" "$SEND" <<'EOF'
try:
    op = pr.operations(record(args[0])["programme"])[args[1]]
    pr.record_receipt(args[0], args[1], digest=op["digest"], target=op["target"], outcome="completed", source="late")
    print("recorded")
except Exception as exc:
    print("refused", exc)
EOF
)"
has "refused" "$LATE"
it "after seal: a direct authority write is refused inside the store"
DIRECT="$(run_py "$RUN" <<'EOF'
pa = load_lib_module("programme_authority")
ran = []
try:
    pa.write(ph.home_path(args[0]), args[0], lambda rec: ran.append(1))
    print("written")
except pa.AuthorityError as exc:
    print("refused", exc.code, "change-ran" if ran else "change-never-ran")
EOF
)"
check "refused sealed change-never-ran" "$DIRECT"
it "after seal: a direct export rewrites nothing"
check "False" "$(run_py "$RUN" <<'EOF'
print(load_lib_module("programme_authority").export(ph.home_path(args[0]), args[0]))
EOF
)"
it "after seal: a raw store commit with a fresh operation is refused"
RAW="$(run_py "$RUN" <<'EOF'
ps = load_lib_module("programme_store")
import sqlite3
conn = sqlite3.connect(ps.db_path(args[0]), isolation_level=None)
rev, state = conn.execute("SELECT revision, state FROM authority").fetchone()
conn.close()
store = ps.Store(args[0], ps.db_path(args[0]), sqlite3.connect(ps.db_path(args[0]), isolation_level=None), {})
event = {"kind": "record_updated", "payload": {}}
adm = ps.admit(ps.commit_subject(json.loads(state), event), provenance="derived", basis="test")
try:
    store.commit("raw-1", base_revision=rev, state=json.loads(state), event=event, admission=adm)
    print("committed")
except ps.StoreError as exc:
    print("refused", exc.code)
EOF
)"
check "refused sealed" "$RAW"
it "after seal: the revision never moved"
check "$SEALED_REV" "$(revision "$RUN")"
it "after seal: every byte, name and mtime in the home is unchanged"
check "$BEFORE" "$(inventory "$RUN")"

# ── sealed reads use a read-only connection ──
it "a sealed store names its seal revision"
check "$SEALED_REV" "$(run_py "$RUN" <<'EOF'
ps = load_lib_module("programme_store")
with ps.open_store(args[0]) as store:
    print(store.sealed["revision"])
EOF
)"
it "a write through the sealed connection fails at SQLite itself"
check "readonly" "$(run_py "$RUN" <<'EOF'
ps = load_lib_module("programme_store")
import sqlite3
with ps.open_store(args[0]) as store:
    try:
        store._db().execute("UPDATE meta SET value = value WHERE key = 'run_id'")
        print("wrote")
    except sqlite3.OperationalError as exc:
        print("readonly" if "readonly" in str(exc) else str(exc))
EOF
)"

# ── AE9: a successor links the archive and waits for its own acceptance ──
SRC_BEFORE="$(inventory "$RUN")"
WS=w2 HERDR_WORKSPACE_ID=w2 prog create-successor "$RUN" --space default.w2
it "AE9: create-successor starts a new programme"
check 0 "$CODE"
SUCC="$(pyget "$OUT" 'd["run"]')"
it "AE9: the successor is a different run"
[ -n "$SUCC" ] && [ "$SUCC" != "$RUN" ] && pass || fail "succ [$SUCC]"
it "AE9: it links the archive's manifest digest and seal revision"
check "$(arch_field "$RUN" 'archive["manifest"]["digest"]') $(arch_field "$RUN" 'archive["sealed_revision"]')" \
  "$(arch_field "$SUCC" 'prog["predecessor"]["manifest"]') $(arch_field "$SUCC" 'prog["predecessor"]["sealed_revision"]')"
it "AE9: it carries the unfinished items as context, not as items"
check '["linear:AI-1"] {}' "$(arch_field "$SUCC" 'prog["predecessor"]["unfinished"]') $(arch_field "$SUCC" 'prog["items"]')"
it "AE9: its agreement waits for acceptance"
check "null" "$(arch_field "$SUCC" 'prog["agreement"]["accepted"]')"
it "AE9: the archive was not written"
check "$SRC_BEFORE" "$(inventory "$RUN")"
prog create-successor "$WRUN" --space default.w9
it "AE9: a programme that is not sealed has no successor"
check 1 "$CODE"

# ── no lifecycle path deletes: empty, done, handed, dropped, end and archive ──
ERUN="$(new_programme w8)"
prog add-item linear:AI-20 --title "dropped" --run "$ERUN"
prog drop-item linear:AI-20 --reason "not needed" --run "$ERUN"
prog add-item linear:AI-21 --title "handed" --run "$ERUN"
prog hand-item linear:AI-21 --question "ship it?" --kind product_call --run "$ERUN"
prog add-item linear:AI-22 --title "done" --run "$ERUN"
run_py "$ERUN" <<'EOF' >/dev/null
pa = load_lib_module("programme_authority")
def done(rec):
    rec["programme"]["items"]["linear:AI-22"]["state"] = "done"
pa.write(ph.home_path(args[0]), args[0], done)
EOF
EMPTY="$(new_programme w9)"
listing() { (cd "$(home_of "$1")" && find . | sort); }
E_BEFORE="$(listing "$ERUN")"
M_BEFORE="$(listing "$EMPTY")"
end_typed "$ERUN"
end_typed "$EMPTY"
prog archive --run "$ERUN"
it "done, handed and dropped items archive with no disposition"
check 0 "$CODE"
[ "$CODE" = 0 ] || echo "      $OUT"
prog archive --run "$EMPTY"
it "an empty programme archives"
check 0 "$CODE"
it "every path present before end is still present after archive"
MISSING="$(comm -23 <(printf '%s\n' "$E_BEFORE") <(listing "$ERUN"))$(comm -23 <(printf '%s\n' "$M_BEFORE") <(listing "$EMPTY"))"
check "" "$MISSING"
prog check-archive --run "$ERUN"
it "the manifest separates completed, handed over and dropped"
check '["linear:AI-22"] ["linear:AI-21"] ["linear:AI-20"]' \
  "$(pyget "$OUT" 'd["manifest"]["outcomes"]["completed"]') $(pyget "$OUT" 'd["manifest"]["outcomes"]["handed_over"]') $(pyget "$OUT" 'd["manifest"]["outcomes"]["dropped"]')"
it "the archive module deletes nothing but its own test resume file"
check "1" "$(grep -cE 'os\.unlink|os\.remove|rmtree|rmdir|\.unlink\(' "${AUTO_ROOT}/lib/programme_archive.py")"
it "that one unlink is the pause hatch's resume file, outside every home"
has "os.unlink(resume)" "$(grep -E 'os\.unlink' "${AUTO_ROOT}/lib/programme_archive.py")"

# ── a recovery-required archived database is a read-only hold, never repaired ──
DB="$(home_of "$EMPTY")/programme.db"
"$PY" - "$DB" <<'EOF'
import os, sqlite3, subprocess, sys
code = ("import sqlite3, os, sys; c = sqlite3.connect(sys.argv[1], isolation_level=None); "
        "c.execute('PRAGMA cache_size=-1'); c.execute('PRAGMA cache_spill=1'); c.execute('BEGIN IMMEDIATE'); "
        "c.execute(\"UPDATE meta SET value = 'x' WHERE key = 'created_at'\"); "
        "c.execute('CREATE TABLE junk (x)'); "
        "c.execute('INSERT INTO junk SELECT randomblob(3000) FROM (WITH RECURSIVE r(i) AS (SELECT 1 UNION ALL "
        "SELECT i+1 FROM r WHERE i < 300) SELECT i FROM r)'); os.kill(os.getpid(), 9)")
subprocess.run([sys.executable, "-c", code, sys.argv[1]])
EOF
it "a killed foreign writer left a hot journal on the sealed database"
check "yes" "$([ -s "${DB}-journal" ] && echo yes || echo no)"
DB_SUM="$(shasum -a 256 "$DB" "${DB}-journal")"
prog check-archive --run "$EMPTY"
it "reading it yields a hold, not a repaired archive"
check "1" "$CODE"
has "recovery required" "$OUT"
prog recover --run "$EMPTY"
it "recover reports the hold"
check "1 unavailable" "$CODE $(pyget "$OUT" 'd["hold"]["outcome"]')"
prog archive --run "$EMPTY"
it "archive retry over the hold seals nothing and repairs nothing"
check 1 "$CODE"
it "the database and its journal are byte-identical: no rollback ran"
check "$DB_SUM" "$(shasum -a 256 "$DB" "${DB}-journal")"

it "an unsealed programme with a hot journal still recovers in place (negative control)"
HOT="$(new_programme w10)"
HDB="$(home_of "$HOT")/programme.db"
"$PY" - "$HDB" <<'EOF'
import subprocess, sys
code = ("import sqlite3, os, sys; c = sqlite3.connect(sys.argv[1], isolation_level=None); "
        "c.execute('PRAGMA cache_size=-1'); c.execute('PRAGMA cache_spill=1'); c.execute('BEGIN IMMEDIATE'); "
        "c.execute('CREATE TABLE junk (x)'); "
        "c.execute('INSERT INTO junk SELECT randomblob(3000) FROM (WITH RECURSIVE r(i) AS (SELECT 1 UNION ALL "
        "SELECT i+1 FROM r WHERE i < 300) SELECT i FROM r)'); os.kill(os.getpid(), 9)")
subprocess.run([sys.executable, "-c", code, sys.argv[1]])
EOF
[ -s "${HDB}-journal" ] || fail "no hot journal was made"
prog add-item linear:AI-30 --title "after the crash" --run "$HOT"
check "0 no" "$CODE $([ -e "${HDB}-journal" ] && echo yes || echo no)"

it "no command crashed with a traceback"
check "" "$CRASHES"

# ── a foreign append absorbed by a refused write is absorbed once; the archive still seals ──
FRUN="$(new_programme w11)"
end_typed "$FRUN"
printf '{"kind": "beat_note", "at": "2026-01-01T00:00:00Z", "session_id": null, "payload": {}}\n' \
  >> "$(home_of "$FRUN")/journal.jsonl"
prog release-resources --run "$FRUN" --watcher no-such-watcher --stopped
it "release-resources refuses a watcher the programme does not owe"
check 1 "$CODE"
has "no owed watcher" "$OUT"
foreign_events() {
  run_py "$1" <<'EOF'
print(sum(1 for e in load_lib_module("programme_authority").snapshot(args[0])["events"]
          if e["kind"] == "foreign_write_absorbed"))
EOF
}
it "the refused write still absorbed the foreign line, once"
check 1 "$(foreign_events "$FRUN")"
prog archive --run "$FRUN"
it "the archive after a refused absorbing write seals at the first attempt"
check "0 sealed" "$CODE $(pyget "$OUT" 'd.get("status")')"
it "the foreign line was never absorbed a second time"
check 1 "$(foreign_events "$FRUN")"

# ── the programme worktree is a closure resource, removed only when nothing in it can be lost ──
export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
cd "$WORK" || exit 1
WT=""
# wt_programme <space>: a programme whose pm_worktree is a fresh detached worktree; sets RUN and WT.
wt_programme() {
  local repo="${WORK}/repo-$1"
  git init -q "$repo" && git -C "$repo" commit -q --allow-empty -m init
  RUN="$(new_programme "$1")"
  WT="$(run_py "$RUN" "$repo" <<'EOF'
pw = load_lib_module("programme_worktree")
pa = load_lib_module("programme_authority")
made = pw.create(args[1], args[0])
def mutate(rec):
    rec["programme"]["pm_worktree"] = made["record"]
pa.write(ph.home_path(args[0]), args[0], mutate, lambda _r, _rec: pj.entry("remit_set", "sess-pm", {}))
print(made["record"]["path"])
EOF
)"
}
wt_state() { arch_field "$1" 'closure["resources"]["worktree"]["state"]'; }
wt_detail() { arch_field "$1" 'closure["resources"]["worktree"]["receipts"][-1]["detail"]'; }
listed() { git -C "$1" worktree list --porcelain | grep -c "^worktree $2$"; }
resources_check() {
  prog check-archive --run "$1"
  pyget "$OUT" '[c for c in d["checks"] if c["check"] == "resources"][0]'
}

wt_programme w40
CLEAN_RUN="$RUN"
CLEAN_REPO="${WORK}/repo-w40"
end_typed "$RUN" >/dev/null
it "end owes the recorded worktree as a closure resource"
check '["lease:default.w40", "worktree"]' "$(arch_field "$RUN" 'sorted(closure["resources"])')"
it "the owed worktree names its path and main checkout"
check "$WT" "$(arch_field "$RUN" 'closure["resources"]["worktree"]["path"]')"
it "before release-resources, check-archive names the worktree"
has '"id": "worktree"' "$(resources_check "$RUN")"
prog release-resources --run "$RUN"
it "release-resources from outside removes a clean detached worktree"
check "released no 0" "$(wt_state "$RUN") $([ -e "$WT" ] && echo yes || echo no) $(listed "$CLEAN_REPO" "$WT")"
it "check-archive then passes its resources check"
check "true" "$(pyget "$(resources_check "$RUN")" 'd["ok"]')"

wt_programme w41
echo draft > "${WT}/notes.txt"
end_typed "$RUN" >/dev/null
prog release-resources --run "$RUN"
it "a worktree with an untracked file is not removed"
check "pending draft" "$(wt_state "$RUN") $(cat "${WT}/notes.txt")"
it "the receipt names the untracked change and the fix"
has "commit or clean" "$(wt_detail "$RUN")"
it "check-archive names the worktree"
has '"id": "worktree"' "$(resources_check "$RUN")"
has "uncommitted or untracked" "$(resources_check "$RUN")"

wt_programme w42
git -C "$WT" commit -q --allow-empty -m "detached work"
end_typed "$RUN" >/dev/null
prog release-resources --run "$RUN"
it "a detached worktree holding a commit no branch reaches is not removed"
check "pending yes" "$(wt_state "$RUN") $([ -d "$WT" ] && echo yes || echo no)"
it "the receipt names the unreachable commit and the fix"
has "no branch or remote reaches" "$(wt_detail "$RUN")"

wt_programme w43
git -C "$WT" switch -q -c shawn-work
git -C "$WT" commit -q --allow-empty -m "his work"
end_typed "$RUN" >/dev/null
prog release-resources --run "$RUN"
it "a worktree on a branch Shawn made and committed to is removed"
check "released no" "$(wt_state "$RUN") $([ -e "$WT" ] && echo yes || echo no)"
it "his branch and its commit survive the removal"
check "his work" "$(git -C "${WORK}/repo-w43" log -1 --format=%s shawn-work 2>&1)"

wt_programme w44
end_typed "$RUN" >/dev/null
INSIDE_OUT="$(cd "$WT" && "$PY" "$PROG" release-resources --run "$RUN" 2>&1)"
it "release-resources run from inside the worktree leaves it in place"
check "pending yes" "$(wt_state "$RUN") $([ -d "$WT" ] && echo yes || echo no)"
it "the refusal names the cd out"
has "cd " "$(wt_detail "$RUN")"
has "inside" "$(wt_detail "$RUN")"
lacks "Traceback" "$INSIDE_OUT"
prog release-resources --run "$RUN"
it "the same worktree is removed once the caller is outside it"
check "released no" "$(wt_state "$RUN") $([ -e "$WT" ] && echo yes || echo no)"

wt_programme w45
end_typed "$RUN" >/dev/null
rm -rf "$WT"
prog release-resources --run "$RUN"
it "a worktree deleted by hand is confirmed as released"
check "released" "$(wt_state "$RUN")"
it "its stale registration is left for git, never pruned by auto"
check "1" "$(listed "${WORK}/repo-w45" "$WT")"

wt_programme w47
end_typed "$RUN" >/dev/null
KEEP="$(typed_in "$RUN" sess-pm "keep the programme worktree: dispose-action --resource worktree")"
prog dispose-action --resource worktree --as accepted_unknown --prompt "$KEEP" --run "$RUN"
it "a typed prompt records a disposition on the worktree resource"
check 0 "$CODE"
prog release-resources --run "$RUN"
it "a worktree with a disposition is observed, never removed"
check "yes 1" "$([ -d "$WT" ] && echo yes || echo no) $(listed "${WORK}/repo-w47" "$WT")"
it "and check-archive no longer names it"
check "true" "$(pyget "$(resources_check "$RUN")" 'd["ok"]')"

RUN="$(new_programme w46)"
end_typed "$RUN" >/dev/null
it "a programme with no worktree owes no worktree resource"
check '["lease:default.w46"]' "$(arch_field "$RUN" 'sorted(closure["resources"])')"

it "a released worktree resource stays released on a later release-resources"
prog release-resources --run "$CLEAN_RUN"
check "released" "$(wt_state "$CLEAN_RUN")"

echo
echo "programme-archive.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
