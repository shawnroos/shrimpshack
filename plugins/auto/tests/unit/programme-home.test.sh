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

echo "programme-home.test.sh"

WORK="$(mktemp -d -t auto-programme.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

fresh() {
  export CLAUDE_AUTO_DATA_DIR="${WORK}/data-$1"
}

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
ph = load_lib_module("programme_home")
args = sys.argv[2:]
$(cat)
PYEOF
}

edit_record() {
  run_py "$1" "$2" <<'EOF'
run, expr = args
core = load_lib_module("run_record_core")
home = ph.home_path(run)
path = core.run_record_path(home, run)
with open(path) as fh:
    rec = json.load(fh)
exec(expr)
with open(path, "w") as fh:
    json.dump(rec, fh)
print("edited")
EOF
}

create() {
  run_py "$@" <<'EOF'
session, *spaces = args
try:
    out = ph.create_programme(spaces, session)
    print("CREATED " + out["run"])
except ph.LeaseHeld as exc:
    print("REFUSED " + str(exc))
except ph.ProgrammeHomeError as exc:
    print("ERROR " + str(exc))
EOF
}

fresh a
it "create for default.w2: lease names run, home and session; record is a programme"
OUT="$(create sess-1 w2)"
RUN="${OUT#CREATED }"
SHAPE="$(run_py "$RUN" <<'EOF'
run = args[0]
lease = ph.read_lease(ph.lease_path("default", "w2"))
core = load_lib_module("run_record_core")
rec = core.read_run_record(ph.home_path(run), run)
ok = [
    lease["run"] == run,
    lease["home"] == ph.home_path(run),
    lease["session_id"] == "sess-1",
    "run_id" not in lease and "loop" not in lease,
    rec["run_kind"] == "programme",
    rec["programme_format"] == core.PROGRAMME_FORMAT,
    rec["driving_session_id"] == "sess-1",
    rec["steps"] == [],
    rec["loop"]["driver"] == "self",
    load_lib_module("phase-grammar").current_phase(rec) == "work",
    rec["programme"]["remit"]["spaces"] == [{"server": "default", "workspace": "w2"}],
    rec["programme"]["agreement"]["accepted"] is None,
    oct(os.stat(ph.home_path(run)).st_mode & 0o777) == "0o700",
    oct(os.stat(ph.lease_path("default", "w2")).st_mode & 0o777) == "0o600",
]
print(ok)
EOF
)"
check "[True, True, True, True, True, True, True, True, True, True, True, True, True, True]" "$SHAPE"

it "a second create for default.w2 while the first run beats is refused, naming the holder"
OUT="$(create sess-2 w2)"
case "$OUT" in "REFUSED "*"$RUN"*"sess-1"*) pass ;; *) fail "$OUT" ;; esac

it "leases_for_session finds the lease for the driving session only"
LS="$(run_py <<'EOF'
print(len(ph.leases_for_session("sess-1")), len(ph.leases_for_session("sess-2")), len(ph.leases_for_session("")))
EOF
)"
check "1 0 0" "$LS"

it "the leases folder holds only lease files (lock sits beside it)"
LISTING="$(ls -A "${CLAUDE_AUTO_DATA_DIR}/programmes/leases")"
check "default.w2.json" "$LISTING"

it "a create after the beat is older than two cadence periods reports orphaned and still refuses"
edit_record "$RUN" 'rec["programme"]["agreement"]["accepted"] = {"at": "2020-01-01T00:00:00Z", "prompt_id": "p1"}; rec["loop"]["last_beat_at"] = "2020-01-01T00:00:00Z"' >/dev/null
OUT="$(create sess-2 w2)"
case "$OUT" in "REFUSED "*"orphaned, takeover needed"*) pass ;; *) fail "$OUT" ;; esac

it "an orphaned lease survives the refused create"
LS="$(run_py <<'EOF'
print(ph.read_lease(ph.lease_path("default", "w2"))["session_id"])
EOF
)"
check "sess-1" "$LS"

fresh b
it "two concurrent creates for default.w2: exactly one wins"
for i in 1 2 3 4; do
  ( create "sess-c$i" w2 > "${WORK}/race-$i.out" ) &
done
wait
WINS="$(cat "${WORK}"/race-*.out | grep -c '^CREATED ')"
REFUSALS="$(cat "${WORK}"/race-*.out | grep -c '^REFUSED ')"
check "1 3" "$WINS $REFUSALS"

fresh c
it "a corrupt lease reads as orphaned without a crash"
mkdir -p "${CLAUDE_AUTO_DATA_DIR}/programmes/leases"
printf '{not json' > "${CLAUDE_AUTO_DATA_DIR}/programmes/leases/default.w2.json"
OUT="$(run_py <<'EOF'
print(ph.lease_status(ph.read_lease(ph.lease_path("default", "w2"))))
EOF
)"
check "orphaned" "$OUT"

it "a create over a corrupt lease is refused as orphaned"
OUT="$(create sess-1 w2)"
case "$OUT" in "REFUSED "*"orphaned, takeover needed"*) pass ;; *) fail "$OUT" ;; esac

it "a lease naming a missing home reads as orphaned"
printf '{"programme_format": 1, "run": "prog-gone", "home": "%s", "session_id": "s", "server": "default", "workspace": "w3"}' \
  "${CLAUDE_AUTO_DATA_DIR}/programmes/prog-gone" > "${CLAUDE_AUTO_DATA_DIR}/programmes/leases/default.w3.json"
OUT="$(run_py <<'EOF'
print(ph.lease_status(ph.read_lease(ph.lease_path("default", "w3"))))
EOF
)"
check "orphaned" "$OUT"

it "a lease whose home points outside the data dir reads as orphaned"
printf '{"programme_format": 1, "run": "prog-x", "home": "/tmp", "session_id": "s", "server": "default", "workspace": "w4"}' \
  > "${CLAUDE_AUTO_DATA_DIR}/programmes/leases/default.w4.json"
OUT="$(run_py <<'EOF'
print(ph.lease_status(ph.read_lease(ph.lease_path("default", "w4"))))
EOF
)"
check "orphaned" "$OUT"

it "a lease stamped by a newer auto is refused with its own reason"
printf '{"programme_format": 99, "run": "prog-n", "home": "x", "session_id": "s", "server": "default", "workspace": "w6"}' \
  > "${CLAUDE_AUTO_DATA_DIR}/programmes/leases/default.w6.json"
OUT="$(create sess-1 w6)"
case "$OUT" in "REFUSED "*"newer auto"*) pass ;; *) fail "$OUT" ;; esac

fresh d
it "server s2 with workspace w2 does not collide with default.w2"
A="$(create sess-1 w2)"
B="$(create sess-2 s2.w2)"
case "$A|$B" in "CREATED "*"|CREATED "*) pass ;; *) fail "$A | $B" ;; esac

it "the s2 lease file is keyed by its server"
check "yes" "$([ -f "${CLAUDE_AUTO_DATA_DIR}/programmes/leases/s2.w2.json" ] && echo yes || echo no)"

fresh e
it "a widened remit w2+w5 writes two leases"
OUT="$(create sess-1 w2 w5)"
N="$(ls "${CLAUDE_AUTO_DATA_DIR}/programmes/leases" | wc -l | tr -d ' ')"
case "$OUT" in "CREATED "*) check "2" "$N" ;; *) fail "$OUT" ;; esac

it "a create for w5 alone is then refused"
OUT="$(create sess-2 w5)"
case "$OUT" in "REFUSED "*) pass ;; *) fail "$OUT" ;; esac

it "a create whose remit overlaps on one space writes no lease at all"
OUT="$(create sess-3 w7 w5)"
W7="$([ -f "${CLAUDE_AUTO_DATA_DIR}/programmes/leases/default.w7.json" ] && echo yes || echo no)"
case "$OUT" in "REFUSED "*) check "no" "$W7" ;; *) fail "$OUT" ;; esac

fresh f
it "a workspace id of ../x is refused by the path check"
OUT="$(create sess-1 ../x)"
case "$OUT" in "ERROR "*) pass ;; *) fail "$OUT" ;; esac

it "a leading-dot workspace id is refused"
OUT="$(create sess-1 .hidden)"
case "$OUT" in "ERROR "*) pass ;; *) fail "$OUT" ;; esac

it "a run id that the record slug would rewrite is refused"
OUT="$(run_py <<'EOF'
try:
    ph.create_programme(["w2"], "s", run_id="prog.one")
    print("created")
except ph.ProgrammeHomeError:
    print("refused")
EOF
)"
check "refused" "$OUT"

it "the home path and the record file agree on the run id"
OUT="$(run_py <<'EOF'
core = load_lib_module("run_record_core")
out = ph.create_programme(["w9"], "s")
run = out["run"]
print(os.path.exists(core.run_record_path(ph.home_path(run), run)) and core._slugify_branch(run) == run)
EOF
)"
check "True" "$OUT"

it "with the data dir under ~/.claude/shared the resolver refuses and creates nothing"
OUT="$(CLAUDE_AUTO_DATA_DIR="${HOME}/.claude/shared/auto-programme-test-$$" run_py <<'EOF'
try:
    ph.data_dir()
    print("allowed")
except ph.UnsafeDataDir:
    print("refused")
EOF
)"
check "refused|absent" "$OUT|$([ -e "${HOME}/.claude/shared/auto-programme-test-$$" ] && echo present || echo absent)"

it "the resolver refuses ~/.claude/skills, ~/.claude/auto and a memory dir"
OUT="$(run_py "$HOME" <<'EOF'
home = args[0]
res = []
for sub in (".claude/skills/x", ".claude/auto/x", ".claude/projects/-Users-x/memory/x"):
    os.environ["CLAUDE_AUTO_DATA_DIR"] = os.path.join(home, sub)
    try:
        ph.data_dir()
        res.append("allowed")
    except ph.UnsafeDataDir:
        res.append("refused")
print(" ".join(res))
EOF
)"
check "refused refused refused" "$OUT"

it "a relative data dir is refused"
OUT="$(CLAUDE_AUTO_DATA_DIR="rel/dir" run_py <<'EOF'
try:
    ph.data_dir()
    print("allowed")
except ph.UnsafeDataDir:
    print("refused")
EOF
)"
check "refused" "$OUT"

fresh g
it "a home with only journal, claims and views beside the leases folder yields no task runs"
OUT="$(create sess-1 w2)"
RUN="${OUT#CREATED }"
H="${CLAUDE_AUTO_DATA_DIR}/programmes/side-home"
mkdir -p "$H/views"
: > "$H/journal.jsonl"; : > "$H/claims.jsonl"
COUNTS="$(run_py "$H" "$RUN" <<'EOF'
boot = sys.modules["_bootstrap"]
side, run = args
task = len(list(boot.iter_worktree_run_records(side)))
leases = len(list(boot.iter_worktree_run_records(ph.leases_dir())))
homes = [r for _, r, _ in boot.iter_programme_homes()]
print(task, leases, homes == [run])
EOF
)"
check "0 0 True" "$COUNTS"

it "the programme-home iterator never raises on a refused data dir"
OUT="$(CLAUDE_AUTO_DATA_DIR="rel/dir" run_py <<'EOF'
boot = sys.modules["_bootstrap"]
print(list(boot.iter_programme_homes()))
EOF
)"
check "[]" "$OUT"

fresh h
it "an agreement unaccepted for one cadence ends its run and releases its lease"
OUT="$(create sess-1 w2)"
OLD="${OUT#CREATED }"
edit_record "$OLD" 'rec["programme"]["created_at"] = "2020-01-01T00:00:00Z"' >/dev/null
OUT="$(create sess-2 w2)"
STATE="$(run_py "$OLD" <<'EOF'
run = args[0]
core = load_lib_module("run_record_core")
rec = core.read_run_record(ph.home_path(run), run)
lease = ph.read_lease(ph.lease_path("default", "w2"))
print(load_lib_module("phase-grammar").current_phase(rec), rec["programme"]["ended"]["reason"], lease["session_id"])
EOF
)"
case "$OUT" in "CREATED "*) check "done agreement_unaccepted sess-2" "$STATE" ;; *) fail "$OUT" ;; esac

it "end_programme releases every lease the run holds"
OUT="$(create sess-3 w8 w9)"
R="${OUT#CREATED }"
LEFT="$(run_py "$R" <<'EOF'
ph.end_programme(args[0], "ended_by_shawn")
print(len(ph.leases_for_session("sess-3")), os.path.exists(ph.lease_path("default", "w8")))
EOF
)"
check "0 False" "$LEFT"

it "an ended run's lease does not block a new create"
OUT="$(create sess-4 w8)"
case "$OUT" in "CREATED "*) pass ;; *) fail "$OUT" ;; esac

it "a task record with no run_kind reads as task and recomputes as before"
REPO="${WORK}/task-repo"
OUT="$(run_py "$REPO" <<'EOF'
core = load_lib_module("run_record_core")
rr = load_lib_module("run_record")
rec = core.init_run_record(args[0], "t1", backend="native", steps=[{"id": "a"}])
pred = load_lib_module("run_record_predicate").recompute_predicate(rec)
print("run_kind" in rec, "programme_format" in rec, "programme" in rec, core.run_kind(rec), pred == rec["exit_predicate_result"])
EOF
)"
check "False False False task True" "$OUT"

it "init_run_record refuses a programme with steps"
OUT="$(run_py "${WORK}/bad-repo" <<'EOF'
core = load_lib_module("run_record_core")
try:
    core.init_run_record(args[0], "p", backend="native", run_kind="programme", steps=[{"id": "a"}], loop_phase="work", programme={})
    print("created")
except core.RunRecordError:
    print("refused")
EOF
)"
check "refused" "$OUT"

it "init_run_record refuses an unknown run kind"
OUT="$(run_py "${WORK}/bad-repo2" <<'EOF'
core = load_lib_module("run_record_core")
try:
    core.init_run_record(args[0], "p", backend="native", run_kind="batch")
    print("created")
except core.RunRecordError:
    print("refused")
EOF
)"
check "refused" "$OUT"

it "the item constructor fills every field and rejects an unknown state"
OUT="$(run_py <<'EOF'
item = ph.new_item("linear:AI-753", "Fix export")
keys = sorted(item)
try:
    ph.normalize_item(dict(item, state="maybe"))
    bad = "accepted"
except ph.ProgrammeHomeError:
    bad = "refused"
print(keys == sorted(ph.ITEM_FIELDS), item["state"], bad)
EOF
)"
check "True open refused" "$OUT"

it "normalize_programme fills a sparse block and keeps unknown keys"
OUT="$(run_py <<'EOF'
blk = ph.normalize_programme({"items": {"herdr:w2/p26": {"title": "pane"}}, "extra": 1})
it = blk["items"]["herdr:w2/p26"]
print(sorted(set(ph.PROGRAMME_FIELDS) - set(blk)), it["id"], it["state"], blk["extra"], ph.cadence_seconds({"programme": blk}))
EOF
)"
check "[] herdr:w2/p26 open 1 3600" "$OUT"

echo ""
echo "programme-home.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
