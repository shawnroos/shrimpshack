#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
check() { if [ "$1" = "$2" ]; then pass; else fail "expected [$1] got [$2]"; fi; }

echo "programme-store.test.sh"

WORK="$(mktemp -d -t auto-programme-store.XXXXXX)"
CHILDREN=()
cleanup() {
  for pid in "${CHILDREN[@]+"${CHILDREN[@]}"}"; do kill -9 "$pid" 2>/dev/null; done
  rm -rf "$WORK"
}
trap cleanup EXIT
export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_AUTO_TEST_HARNESS=1
export PYTHONDONTWRITEBYTECODE=1
unset CLAUDE_AUTO_TEST_STORE_PAUSE_BEFORE_COMMIT CLAUDE_AUTO_TEST_STORE_PAUSE_AFTER_COMMIT \
      CLAUDE_AUTO_TEST_STORE_FAIL_COMMIT CLAUDE_AUTO_TEST_STORE_WEAK_SYNC
SECRET_VALUE="fixture-secret-7d1c9e4b"
cat > "$CLAUDE_AUTO_SECRETS_FILE" <<EOF
export FIXTURE_TOKEN="${SECRET_VALUE}"
EOF

PRELUDE="${WORK}/prelude.py"
cat > "$PRELUDE" <<'EOF'
import json, os, sqlite3, stat, sys
sys.path.insert(0, os.path.join(os.environ["AUTO_ROOT"], "lib"))
from _bootstrap import load_lib_module
ph = load_lib_module("programme_home")
ps = load_lib_module("programme_store")


def mkhome(run):
    os.makedirs(ph.home_path(run), mode=0o700)
    return ps.create(run)


def event_for(op, kind="item_updated"):
    return {"kind": kind, "payload": {"note": op}}


def save(store, op, base, state, refs=(), provenance="derived"):
    event = event_for(op)
    admission = ps.admit(ps.commit_subject(state, event, refs), provenance=provenance, basis="fixture")
    return store.commit(op, base_revision=base, state=state, event=event,
                        admission=admission, payload_refs=refs)


def db_path(run):
    return os.path.join(ph.home_path(run), ps.DB_NAME)


def raw(run):
    return sqlite3.connect(db_path(run), isolation_level=None)


def counts(run):
    with ps.open_store(run) as store:
        view = store.read()
        return view["revision"], len(view["events"])
EOF
export AUTO_ROOT PRELUDE

run_py() {
  "$PY" - "$@" <<PYEOF 2>&1
exec(open(__import__("os").environ["PRELUDE"]).read())
args = sys.argv[1:]
$(cat)
PYEOF
}

CHILD="${WORK}/child.py"
cat > "$CHILD" <<'EOF'
exec(open(__import__("os").environ["PRELUDE"]).read())
run, op, base, value = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
state = {"value": value}
big = os.environ.get("STORE_TEST_BIG") == "1"
if big:
    state["lines"] = [" ".join(["ordinary words"] * 35) + f" {i}" for i in range(4000)]
with ps.open_store(run) as store:
    if big:
        store._conn.execute("PRAGMA cache_size = 50")
        store._conn.execute("PRAGMA cache_spill = 50")
    receipt = save(store, op, base, state)
print("receipt " + json.dumps(receipt, sort_keys=True), flush=True)
EOF

HOLDER="${WORK}/holder.py"
cat > "$HOLDER" <<'EOF'
import sqlite3, sys, time
conn = sqlite3.connect(sys.argv[1], isolation_level=None)
conn.execute("BEGIN IMMEDIATE")
print("locked", flush=True)
time.sleep(60)
EOF

wait_for() {
  local file="$1" marker="$2" tries="${3:-200}" i
  for i in $(seq 1 "$tries"); do
    grep -q "$marker" "$file" 2>/dev/null && return 0
    "$PY" -c 'import time; time.sleep(0.05)'
  done
  return 1
}

it "a home without a database probes absent, opening refuses, and nothing is created"
OUT="$(run_py <<'EOF'
os.makedirs(ph.home_path("prog-absent"), mode=0o700)
outcome = ps.probe("prog-absent")["outcome"]
try:
    ps.open_store("prog-absent")
    opened = "opened"
except ps.StoreAbsent as exc:
    opened = exc.code
print(outcome, opened, os.path.exists(db_path("prog-absent")))
EOF
)"
check "absent absent False" "$OUT"

it "create applies and reads back the durable commit policy; db 0600 in a 0700 home"
OUT="$(run_py <<'EOF'
store = mkhome("prog-create")
p = store.pragmas
mode = stat.S_IMODE(os.stat(db_path("prog-create")).st_mode)
home = stat.S_IMODE(os.stat(ph.home_path("prog-create")).st_mode)
print(p["journal_mode"], p["synchronous"], p["fullfsync"], p["foreign_keys"],
      p["busy_timeout"] == ps.BUSY_TIMEOUT_MS, oct(mode), oct(home), store.read()["revision"])
store.close()
print(ps.probe("prog-create")["outcome"])
EOF
)"
check "delete 3 1 1 True 0o600 0o700 0
supported" "$OUT"

it "creating over an existing database refuses"
OUT="$(run_py <<'EOF'
try:
    ps.create("prog-create")
    print("created")
except ps.StoreError as exc:
    print(exc.code)
EOF
)"
check "exists" "$OUT"

it "AE1: a committed update and its event survive into a fresh process"
RECEIPT="$(run_py <<'EOF'
mkhome("prog-ae1").close()
EOF
"$PY" "$CHILD" prog-ae1 op-1 0 first 2>&1)"
OUT="$(run_py "$RECEIPT" <<'EOF'
receipt = json.loads(args[0].split(" ", 1)[1])
with ps.open_store("prog-ae1") as store:
    view = store.read()
    ev = view["events"][0]
    print(receipt["revision"], view["revision"], view["state"]["value"], len(view["events"]),
          ev["operation_id"], ev["revision"], ev["kind"],
          store.outcome("op-1") == {k: v for k, v in receipt.items() if k != "replayed"})
EOF
)"
check "1 1 first 1 op-1 1 item_updated True" "$OUT"

it "kill before COMMIT: the left journal is private, nothing lands, and the next write clears it"
run_py <<'EOF' >/dev/null
mkhome("prog-killpre").close()
EOF
OUTF="${WORK}/killpre.out"
CLAUDE_AUTO_TEST_STORE_PAUSE_BEFORE_COMMIT=1 "$PY" "$CHILD" prog-killpre op-1 0 doomed >"$OUTF" 2>&1 &
PID=$!; CHILDREN+=("$PID")
if wait_for "$OUTF" "paused:before_commit"; then
  JOURNAL="${CLAUDE_AUTO_DATA_DIR}/programmes/prog-killpre/programme.db-journal"
  JMODE="$(stat -f '%Lp' "$JOURNAL" 2>/dev/null || echo missing)"
  kill -9 "$PID"; wait "$PID" 2>/dev/null
  OUT="$(run_py <<'EOF'
rev, n = counts("prog-killpre")
with ps.open_store("prog-killpre") as store:
    outcome = store.outcome("op-1")
    save(store, "op-2", 0, {"value": "next"})
print(rev, n, outcome, os.path.exists(db_path("prog-killpre") + "-journal"))
EOF
)"
  check "600 0 0 None False receipt=no" "${JMODE} ${OUT} receipt=$(grep -q '^receipt' "$OUTF" && echo yes || echo no)"
else
  kill -9 "$PID" 2>/dev/null; fail "child never reached the before-commit pause: $(cat "$OUTF")"
fi

it "kill before COMMIT after pages spilled into the db: the hot journal rolls back and is removed on reopen"
run_py <<'EOF' >/dev/null
mkhome("prog-spill").close()
EOF
DB="${CLAUDE_AUTO_DATA_DIR}/programmes/prog-spill/programme.db"
BEFORE="$(stat -f '%z' "$DB")"
OUTF="${WORK}/spill.out"
STORE_TEST_BIG=1 CLAUDE_AUTO_TEST_STORE_PAUSE_BEFORE_COMMIT=1 "$PY" "$CHILD" prog-spill op-1 0 doomed >"$OUTF" 2>&1 &
PID=$!; CHILDREN+=("$PID")
if wait_for "$OUTF" "paused:before_commit" 1200; then
  DURING="$(stat -f '%z' "$DB")"
  HOT="$([ -s "${DB}-journal" ] && echo journal || echo nojournal)"
  kill -9 "$PID"; wait "$PID" 2>/dev/null
  OUT="$(run_py <<'EOF'
rev, n = counts("prog-spill")
with ps.open_store("prog-spill") as store:
    outcome = store.outcome("op-1")
print(rev, n, outcome, os.path.exists(db_path("prog-spill") + "-journal"))
EOF
)"
  check "spilled journal 0 0 None False" "$([ "$DURING" -gt "$BEFORE" ] && echo spilled || echo "not-spilled($BEFORE/$DURING)") ${HOT} $(echo $OUT)"
else
  kill -9 "$PID" 2>/dev/null; fail "child never reached the before-commit pause: $(cat "$OUTF")"
fi

it "an event with no payload key commits under an admission built from commit_subject"
OUT="$(run_py <<'EOF'
store = mkhome("prog-nopayload")
event = {"kind": "item_added"}
admission = ps.admit(ps.commit_subject({"v": 1}, event), provenance="derived", basis="fixture")
r = store.commit("op-1", base_revision=0, state={"v": 1}, event=event, admission=admission)
print(r["revision"], store.read()["events"][0]["payload"])
EOF
)"
check "1 {}" "$OUT"

it "kill after COMMIT, before the response: the commit is there and a retry replays it without a new event"
run_py <<'EOF' >/dev/null
mkhome("prog-killpost").close()
EOF
OUTF="${WORK}/killpost.out"
CLAUDE_AUTO_TEST_STORE_PAUSE_AFTER_COMMIT=1 "$PY" "$CHILD" prog-killpost op-1 0 kept >"$OUTF" 2>&1 &
PID=$!; CHILDREN+=("$PID")
if wait_for "$OUTF" "paused:after_commit"; then
  kill -9 "$PID"; wait "$PID" 2>/dev/null
  RETRY="$("$PY" "$CHILD" prog-killpost op-1 0 kept 2>&1)"
  OUT="$(run_py "$RETRY" <<'EOF'
receipt = json.loads(args[0].split(" ", 1)[1])
print(receipt["revision"], receipt["replayed"], *counts("prog-killpost"))
EOF
)"
  check "1 True 1 1 receipt=no" "${OUT} receipt=$(grep -q '^receipt' "$OUTF" && echo yes || echo no)"
else
  kill -9 "$PID" 2>/dev/null; fail "child never reached the after-commit pause: $(cat "$OUTF")"
fi

it "the same operation id with different input refuses and mutates nothing"
OUT="$(run_py <<'EOF'
store = mkhome("prog-conflict")
save(store, "op-1", 0, {"value": "a"})
try:
    save(store, "op-1", 0, {"value": "b"})
    print("accepted")
except ps.OperationConflict as exc:
    print(exc.code, store.read()["state"]["value"], *counts("prog-conflict"))
EOF
)"
check "operation_conflict a 1 1" "$OUT"

it "a stale base revision refuses and mutates nothing"
OUT="$(run_py <<'EOF'
store = mkhome("prog-stale")
save(store, "op-1", 0, {"value": "a"})
save(store, "op-2", 1, {"value": "b"})
try:
    save(store, "op-3", 1, {"value": "c"})
    print("accepted")
except ps.StaleRevision as exc:
    print(exc.code, store.read()["state"]["value"], *counts("prog-stale"), store.outcome("op-3"))
EOF
)"
check "stale_revision b 2 2 None" "$OUT"

it "revisions are monotonic and each names its own event and outcome"
OUT="$(run_py <<'EOF'
with ps.open_store("prog-stale") as store:
    view = store.read()
    print([e["revision"] for e in view["events"]],
          [store.outcome(op)["revision"] for op in ("op-1", "op-2")])
EOF
)"
check "[1, 2] [1, 2]" "$OUT"

it "unsupported configuration: a pragma readback mismatch refuses to open"
OUT="$(CLAUDE_AUTO_TEST_STORE_WEAK_SYNC=1 run_py <<'EOF'
os.makedirs(ph.home_path("prog-weak"), mode=0o700)
try:
    ps.create("prog-weak")
    created = "created"
except ps.StoreUnsupported as exc:
    created = exc.code
print(created, os.path.exists(db_path("prog-weak")))
EOF
)"
check "unsupported False" "$OUT"

it "unsupported configuration on an existing store: open refuses, probe reports unsupported"
OUT="$(CLAUDE_AUTO_TEST_STORE_WEAK_SYNC=1 run_py <<'EOF'
try:
    ps.open_store("prog-stale")
    opened = "opened"
except ps.StoreUnsupported as exc:
    opened = exc.code
print(opened, ps.probe("prog-stale")["outcome"])
EOF
)"
check "unsupported unsupported" "$OUT"

it "contention past the busy timeout: no receipt, nothing committed"
run_py <<'EOF' >/dev/null
mkhome("prog-busy").close()
EOF
OUTF="${WORK}/holder.out"
"$PY" "$HOLDER" "${CLAUDE_AUTO_DATA_DIR}/programmes/prog-busy/programme.db" >"$OUTF" 2>&1 &
PID=$!; CHILDREN+=("$PID")
if wait_for "$OUTF" "locked"; then
  OUT="$(run_py <<'EOF'
ps.BUSY_TIMEOUT_MS = 200
receipt = None
try:
    with ps.open_store("prog-busy") as store:
        receipt = save(store, "op-1", 0, {"value": "x"})
    print("receipt")
except ps.StoreUnavailable as exc:
    print(exc.code, receipt)
EOF
)"
  kill -9 "$PID"; wait "$PID" 2>/dev/null
  AFTER="$(run_py <<'EOF'
with ps.open_store("prog-busy") as store:
    print(*counts("prog-busy"), store.outcome("op-1"))
EOF
)"
  check "unavailable None | 0 0 None" "${OUT} | ${AFTER}"
else
  kill -9 "$PID" 2>/dev/null; fail "holder never took the write lock: $(cat "$OUTF")"
fi

it "a failure at COMMIT (simulated sync error): no receipt, rolled back, a clean retry then succeeds"
OUT="$(CLAUDE_AUTO_TEST_STORE_FAIL_COMMIT=1 run_py <<'EOF'
store = mkhome("prog-syncfail")
try:
    save(store, "op-1", 0, {"value": "x"})
    print("receipt")
except ps.StoreUnavailable as exc:
    print(exc.code, store.outcome("op-1"), *counts("prog-syncfail"))
EOF
)"
RETRY="$(run_py <<'EOF'
with ps.open_store("prog-syncfail") as store:
    print(save(store, "op-1", 0, {"value": "x"})["revision"], *counts("prog-syncfail"))
EOF
)"
check "unavailable None 0 0 | 1 1 1" "${OUT} | ${RETRY}"

it "hatch fence: fault variables without CLAUDE_AUTO_TEST_HARNESS=1 have no effect"
OUT="$(unset CLAUDE_AUTO_TEST_HARNESS
       export CLAUDE_AUTO_TEST_STORE_FAIL_COMMIT=1 CLAUDE_AUTO_TEST_STORE_WEAK_SYNC=1 \
              CLAUDE_AUTO_TEST_STORE_PAUSE_BEFORE_COMMIT=1 CLAUDE_AUTO_TEST_STORE_PAUSE_AFTER_COMMIT=1
       run_py <<'EOF'
store = mkhome("prog-fence")
print(save(store, "op-1", 0, {"value": "x"})["revision"], store.pragmas["synchronous"])
EOF
)"
check "1 3" "$OUT"

it "the integrity checks are clean on a healthy store"
OUT="$(run_py <<'EOF'
with ps.open_store("prog-stale") as store:
    r = store.check_integrity()
print(r["integrity"], r["foreign_keys"], r["references"], r["ok"])
EOF
)"
check "[] [] [] True" "$OUT"

it "integrity_check alone detects a damaged index page"
OUT="$(run_py <<'EOF'
store = mkhome("prog-badpage")
for i in range(1, 30):
    save(store, f"op-{i}", i - 1, {"value": i})
store.close()
conn = raw("prog-badpage")
root = conn.execute("SELECT rootpage FROM sqlite_master WHERE name = 'events_by_operation'").fetchone()[0]
size = conn.execute("PRAGMA page_size").fetchone()[0]
conn.close()
with open(db_path("prog-badpage"), "r+b") as fh:
    fh.seek(size * (root - 1))
    fh.write(b"\xff" * size)
with ps.open_store("prog-badpage") as store:
    r = store.check_integrity()
print(bool(r["integrity"]), r["foreign_keys"], r["ok"])
EOF
)"
check "True [] False" "$OUT"

it "foreign_key_check alone detects an event citing a missing operation"
OUT="$(run_py <<'EOF'
store = mkhome("prog-badfk")
save(store, "op-1", 0, {"value": 1})
store.close()
conn = raw("prog-badfk")
conn.execute("PRAGMA foreign_keys=OFF")
cols = [c[1] for c in conn.execute("PRAGMA table_info(events)")]
row = dict(zip(cols, conn.execute("SELECT * FROM events").fetchone()))
row.update(seq=None, operation_id="ghost")
conn.execute(f"INSERT INTO events ({','.join(cols)}) VALUES ({','.join('?' * len(cols))})",
             [row[c] for c in cols])
conn.close()
with ps.open_store("prog-badfk") as store:
    r = store.check_integrity()
print(r["integrity"], bool(r["foreign_keys"]), r["references"], r["ok"])
EOF
)"
check "[] True [] False" "$OUT"

it "the application reference check alone detects an authority revision no operation explains"
OUT="$(run_py <<'EOF'
store = mkhome("prog-badref")
save(store, "op-1", 0, {"value": 1})
store.close()
conn = raw("prog-badref")
conn.execute("UPDATE authority SET revision = 99")
conn.close()
with ps.open_store("prog-badref") as store:
    r = store.check_integrity()
print(r["integrity"], r["foreign_keys"], bool(r["references"]), r["ok"])
EOF
)"
check "[] [] True False" "$OUT"

it "the application reference check detects a cited payload reference that is not recorded"
OUT="$(run_py <<'EOF'
store = mkhome("prog-badpay")
ref = ps.payload_ref_for(b"result bytes", "text/plain")
save(store, "op-1", 0, {"value": 1}, refs=(ref,))
store.close()
conn = raw("prog-badpay")
conn.execute("PRAGMA foreign_keys=OFF")
conn.execute("DELETE FROM payload_refs")
conn.close()
with ps.open_store("prog-badpay") as store:
    r = store.check_integrity()
print(r["integrity"], r["foreign_keys"], bool(r["references"]), r["ok"])
EOF
)"
check "[] [] True False" "$OUT"

it "payload references record digest, size and type; conflicting or malformed references refuse"
OUT="$(run_py <<'EOF'
store = mkhome("prog-refs")
ref = ps.payload_ref_for(b"result bytes", "text/plain")
save(store, "op-1", 0, {"value": 1}, refs=(ref,))
got = store.payload_refs()
bad = ps.PayloadRef(ref.digest, ref.size + 1, ref.media_type)
try:
    save(store, "op-2", 1, {"value": 2}, refs=(bad,))
    conflict = "accepted"
except ps.StoreError as exc:
    conflict = exc.code
try:
    ps.PayloadRef("not-a-digest", 1, "text/plain")
    malformed = "accepted"
except ps.StoreError as exc:
    malformed = exc.code
print(got == [ref], ref.size, conflict, malformed, *counts("prog-refs"))
EOF
)"
check "True 12 payload_conflict invalid_reference 1 1" "$OUT"

it "privacy admission: a secret-bearing payload is prohibited and its bytes appear nowhere under the home"
OUT="$(run_py "$SECRET_VALUE" <<'EOF'
store = mkhome("prog-secret")
save(store, "op-0", 0, {"value": "clean"})
state = {"value": "token " + args[0]}
event = event_for("op-1")
subject = ps.commit_subject(state, event)
admission = ps.admit(subject, provenance="human_input", basis="fixture")
try:
    store.commit("op-1", base_revision=1, state=state, event=event, admission=admission)
    refused = "committed"
except ps.AdmissionRefused as exc:
    refused = exc.code + (" leaked" if args[0] in str(exc) else "")
clean = ps.admit(ps.commit_subject({"value": "clean2"}, event), provenance="derived", basis="fixture")
try:
    store.commit("op-1", base_revision=1, state=state, event=event, admission=clean)
    forged = "committed"
except ps.AdmissionRefused as exc:
    forged = exc.code + (" leaked" if args[0] in str(exc) else "")
print(admission.decision, refused, forged, store.outcome("op-1"), *counts("prog-secret"))
EOF
)"
LEAK="$(grep -rla "$SECRET_VALUE" "${CLAUDE_AUTO_DATA_DIR}/programmes/prog-secret" 2>/dev/null | wc -l | tr -d ' ')"
check "prohibited admission_refused admission_refused None 1 1 leaks=0" "${OUT} leaks=${LEAK}"

it "privacy admission: a known token shape is prohibited without a secrets-file entry"
OUT="$(run_py <<'EOF'
print(ps.admit({"note": "ghp_" + "A" * 36}, provenance="derived", basis="fixture").decision)
EOF
)"
check "prohibited" "$OUT"

it "privacy admission: an unreadable secrets file or an unclassifiable value is uncertain, not admitted"
chmod 000 "$CLAUDE_AUTO_SECRETS_FILE"
OUT1="$(run_py <<'EOF'
print(ps.admit({"note": "plain"}, provenance="derived", basis="fixture").decision)
EOF
)"
chmod 600 "$CLAUDE_AUTO_SECRETS_FILE"
OUT2="$(run_py <<'EOF'
a = ps.admit({"blob": b"\x00\x01"}, provenance="derived", basis="fixture").decision
b = ps.admit({"note": "plain"}, provenance="derived", basis="fixture").decision
try:
    ps.admit({"note": "plain"}, provenance="made_up", basis="fixture")
    c = "accepted"
except ps.StoreError as exc:
    c = exc.code
print(a, b, c)
EOF
)"
check "uncertain | uncertain admitted invalid_admission" "${OUT1} | ${OUT2}"

it "privacy admission: a missing secrets file falls back to token patterns, not refusal"
OUT="$(CLAUDE_AUTO_SECRETS_FILE="${WORK}/no-such-file" run_py <<'EOF'
print(ps.admit({"note": "plain"}, provenance="derived", basis="fixture").decision)
EOF
)"
check "admitted" "$OUT"

it "an event records the admission's provenance, never upgrading it"
OUT="$(run_py <<'EOF'
store = mkhome("prog-prov")
save(store, "op-1", 0, {"value": 1}, provenance="restored")
print(store.read()["events"][0]["provenance"])
EOF
)"
check "restored" "$OUT"

it "a newer schema version refuses as unsupported"
OUT="$(run_py <<'EOF'
mkhome("prog-newer").close()
conn = raw("prog-newer")
conn.execute("UPDATE meta SET value = '99' WHERE key = 'schema_version'")
conn.close()
try:
    ps.open_store("prog-newer")
    opened = "opened"
except ps.StoreUnsupported as exc:
    opened = exc.code
print(opened, ps.probe("prog-newer")["outcome"])
EOF
)"
check "unsupported unsupported" "$OUT"

it "a non-database file and a database missing its tables both probe corrupt"
OUT="$(run_py <<'EOF'
os.makedirs(ph.home_path("prog-garbage"), mode=0o700)
with open(db_path("prog-garbage"), "wb") as fh:
    fh.write(b"this is not sqlite" * 300)
mkhome("prog-notables").close()
conn = raw("prog-notables")
conn.execute("DROP TABLE events")
conn.close()
out = []
for run in ("prog-garbage", "prog-notables"):
    try:
        ps.open_store(run)
        out.append("opened")
    except ps.StoreCorrupt as exc:
        out.append(exc.code)
    out.append(ps.probe(run)["outcome"])
print(*out)
EOF
)"
check "corrupt corrupt corrupt corrupt" "$OUT"

it "an unreadable database probes unavailable, not absent"
OUT="$(run_py <<'EOF'
mkhome("prog-noaccess").close()
os.chmod(ph.home_path("prog-noaccess"), 0)
try:
    print(ps.probe("prog-noaccess")["outcome"])
finally:
    os.chmod(ph.home_path("prog-noaccess"), 0o700)
EOF
)"
check "unavailable" "$OUT"

it "import inventory: frozen, ordered, bound to an identity that changes when any input changes"
OUT="$(run_py <<'EOF'
e1 = ps.inventory_entry("record.json", b'{"a": 1}', parse_result="parsed", provenance="legacy_import")
e2 = ps.inventory_entry("journal.jsonl", None, parse_result="missing", provenance="legacy_import")
inv = ps.freeze_inventory([e1, e2])
again = ps.freeze_inventory([e1, e2])
e1b = ps.inventory_entry("record.json", b'{"a": 2}', parse_result="parsed", provenance="legacy_import")
changed = ps.freeze_inventory([e1b, e2])
reordered = ps.freeze_inventory([e2, e1])
try:
    inv.entries[0].digest = "x"
    mutable = "mutable"
except Exception:
    mutable = "frozen"
print(inv.import_id == again.import_id, inv.import_id != changed.import_id,
      inv.import_id != reordered.import_id, mutable, e2.digest, ps.check_inventory(inv) is inv,
      ps.changed_entries(inv, [e1b, e2]))
EOF
)"
check "True True True frozen None True ['record.json']" "$OUT"

it "import inventory: tampering, duplicates and unknown classes refuse"
OUT="$(run_py <<'EOF'
import dataclasses
e1 = ps.inventory_entry("record.json", b"{}", parse_result="parsed", provenance="legacy_import")
inv = ps.freeze_inventory([e1])
tampered = dataclasses.replace(inv, entries=(dataclasses.replace(e1, size=99),))
out = []
for build in (lambda: ps.check_inventory(tampered),
              lambda: ps.freeze_inventory([e1, e1]),
              lambda: ps.inventory_entry("x", b"{}", parse_result="guessed", provenance="legacy_import"),
              lambda: ps.inventory_entry("x", b"{}", parse_result="parsed", provenance="approval"),
              lambda: ps.freeze_inventory([])):
    try:
        build()
        out.append("accepted")
    except ps.StoreError as exc:
        out.append(exc.code)
print(*out)
EOF
)"
check "inventory_invalid inventory_invalid inventory_invalid inventory_invalid inventory_invalid" "$OUT"

it "close without COMMIT rolls back; nothing depends on connection teardown"
OUT="$(run_py <<'EOF'
store = mkhome("prog-close")
store._conn.execute("BEGIN IMMEDIATE")
store._conn.execute("UPDATE authority SET revision = 5")
store.close()
print(*counts("prog-close"))
EOF
)"
check "0 0" "$OUT"

it "every file under the store's homes is private (0600) and every directory 0700"
[ -d "${CLAUDE_AUTO_DATA_DIR}/programmes" ] || fail "no programme homes were created"
BAD="$(find "${CLAUDE_AUTO_DATA_DIR}/programmes" -mindepth 1 \( -type f ! -perm 600 -o -type d ! -perm 700 \) \
       ! -path '*/prog-garbage/*' -print)"
check "" "$BAD"

echo ""
echo "programme-store.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
