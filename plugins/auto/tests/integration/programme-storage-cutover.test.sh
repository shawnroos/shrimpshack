#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
LIB="${AUTO_ROOT}/lib"
PROG="${LIB}/programme.py"
OLD_COMMIT="f9934a3"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
check() { if [ "$1" = "$2" ]; then pass; else fail "expected [$1] got [$2]"; fi; }
has() { case "$2" in *"$1"*) pass ;; *) fail "expected to find [$1] in [$2]" ;; esac; }
lacks() { case "$2" in *"$1"*) fail "did not expect [$1] in [$2]" ;; *) pass ;; esac; }

echo "programme-storage-cutover.test.sh"

WORK="$(mktemp -d -t auto-storage-cutover.XXXXXX)"
CHILDREN=""
cleanup() {
  for pid in $CHILDREN; do kill -9 "$pid" 2>/dev/null; done
  rm -rf "$WORK"
}
trap cleanup EXIT

for v in $(env | sed -n 's/^\(HERDR_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
unset CLAUDE_CODE_SESSION_ID CLAUDE_AUTO_REPO LINEAR_API_KEY CLAUDE_CODE_ENTRYPOINT 2>/dev/null || true
export CLAUDE_AUTO_TEST_HARNESS=1
export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_MACHINE="studio"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
SECRET="zq-fixture-secret-7731"
printf 'FIXTURE_TOKEN=%s\n' "$SECRET" > "$CLAUDE_AUTO_SECRETS_FILE"
NOREPO="${WORK}/norepo"
mkdir -p "$NOREPO"

OLD="${WORK}/old/plugins/auto/lib"
mkdir -p "${WORK}/old"
it "the obsolete implementation at ${OLD_COMMIT} is extracted for the old-writer scenarios"
TOP="$(git -C "$AUTO_ROOT" rev-parse --show-toplevel 2>/dev/null)"
if [ -n "$TOP" ] && git -C "$TOP" archive "$OLD_COMMIT" plugins/auto/lib plugins/auto/protocol 2>/dev/null | tar -x -C "${WORK}/old" 2>/dev/null \
   && [ -f "${OLD}/programme.py" ]; then
  pass
else
  fail "git archive ${OLD_COMMIT} failed; every old-writer scenario below fails with it"
fi

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import hashlib, json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
import _bootstrap as boot
ph = load_lib_module("programme_home")
pj = load_lib_module("programme_journal")
core = load_lib_module("run_record_core")
auth = load_lib_module("programme_authority")
imp = load_lib_module("programme_import")
store = load_lib_module("programme_store")
args = sys.argv[2:]
def home(run):
    return ph.home_path(run)
def export_path(run):
    return core.run_record_path(home(run), run)
def sha(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()
def rev(run):
    return auth.snapshot(run)["revision"]
def kinds(run):
    return [r["kind"] for r in auth.snapshot(run)["journal"]]
$(cat)
PYEOF
}

as() {
  local sid="$1"; shift
  OUT="$(CLAUDE_CODE_SESSION_ID="$sid" HERDR_WORKSPACE_ID="${WS:-w9}" "$PY" "$PROG" "$@" 2>&1)"
  CODE=$?
}

old_as() {
  local sid="$1"; shift
  OUT="$(CLAUDE_CODE_SESSION_ID="$sid" HERDR_WORKSPACE_ID="${WS:-w9}" "$PY" "${OLD}/programme.py" "$@" 2>&1)"
  CODE=$?
}

hook_payload() {
  "$PY" -c 'import json,sys; print(json.dumps({"session_id": sys.argv[1], "prompt": sys.argv[2], "hook_event_name": "UserPromptSubmit"}))' "$1" "$2"
}

prompt_id_of() {
  "$PY" -c '
import json, re, sys
raw = sys.stdin.read().strip()
if not raw:
    print(""); sys.exit()
ctx = json.loads(raw)["hookSpecificOutput"]["additionalContext"]
print(re.search(r"\"prompt_id\": \"(p[0-9a-f]+)\"", ctx).group(1))'
}

old_typed() {
  hook_payload "$1" "$2" | HERDR_WORKSPACE_ID="${WS:-w9}" "$PY" "${OLD}/on-user-prompt.py" | prompt_id_of
}

# Runs the current hook with a transcript row that shows Shawn typed the prompt.
new_typed() {
  HERDR_WORKSPACE_ID="${WS:-w9}" "$PY" - "$AUTO_ROOT" "$LIB" "$1" "$2" <<'EOF' | prompt_id_of
import json, os, subprocess, sys
root, lib, sid, text = sys.argv[1:]
sys.path.insert(0, os.path.join(root, "lib"))
sys.path.insert(0, os.path.join(root, "tests", "fixtures"))
from programme_prompts import fixture
payload, _, path, row = fixture(text, sid)
out = subprocess.run([sys.executable, os.path.join(lib, "on-user-prompt.py")], input=json.dumps(payload),
                     text=True, capture_output=True)
path.write_text(json.dumps(row) + "\n")
sys.stdout.write(out.stdout)
EOF
}

json_field() {
  "$PY" -c "import json,sys; d=json.loads(sys.stdin.read().strip().splitlines()[-1]); print(json.dumps($1, sort_keys=True) if not isinstance($1, str) else $1)" <<< "$OUT" 2>&1
}

legacy_programme() {
  local sid="$1" space="$2"
  old_as "$sid" start --space "default.${space}"
  "$PY" -c 'import json,sys; print(json.loads(sys.stdin.read().strip().splitlines()[-1])["run"])' <<< "$OUT"
}

wait_for() {
  local file="$1" text="$2" i=0
  while [ $i -lt 100 ]; do
    grep -q "$text" "$file" 2>/dev/null && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

# ── 1. import a quiesced legacy programme ─────────────────────────────────
WS=w1
RUN1="$(legacy_programme sess-a w1)"
P1="$(old_typed sess-a 'I accept the agreement, stop_rule never_stop later')"
old_as sess-a accept-agreement --prompt "$P1" --run "$RUN1"
old_as sess-a add-item linear:AI-1 --title "first item" --kind fix_only --run "$RUN1"
old_as sess-w claim --run "$RUN1" --item linear:AI-1 --deliverable merged --ref pr-1
it "the obsolete implementation built a legacy home with a JSON record, journal and claim"
check "legacy 1" "$(run_py "$RUN1" <<'EOF'
run = args[0]
print(auth.outcome(run)["outcome"], len(open(os.path.join(home(run), "claims.jsonl")).readlines()))
EOF
)"

BEFORE1="$(run_py "$RUN1" <<'EOF'
run = args[0]
print(" ".join(sha(p) for p in (export_path(run), os.path.join(home(run), "journal.jsonl"),
                                  os.path.join(home(run), "claims.jsonl"))))
EOF
)"

it "promotion imports the quiesced legacy programme"
as sess-a promote --run "$RUN1"
check "0 promoted" "$CODE $(json_field 'd["status"]')"

it "every supported reader observes the same authority revision and record"
check "same" "$(run_py "$RUN1" <<'EOF'
run = args[0]
snap = auth.snapshot(run)
views = {
    "core": core.read_run_record(home(run), run),
    "safe": boot.load_run_record_safe(export_path(run)),
    "lease": ph._read_record(run),
    "discovery": [led for _, r, led in boot.iter_programme_homes() if r == run][0],
}
bad = [k for k, v in views.items() if v != snap["record"]]
tag = json.load(open(export_path(run)))[auth.TAG]
print("same" if not bad and tag == snap["revision"] else f"differs {bad} tag={tag} rev={snap['revision']}")
EOF
)"

it "the import keeps the legacy journal and claims and marks their provenance"
check "True True 1 legacy_import" "$(run_py "$RUN1" <<'EOF'
run = args[0]
snap = auth.snapshot(run)
ks = [r["kind"] for r in snap["journal"]]
print("agreement_accepted" in ks, "item_added" in ks, pj.claims_count(run),
      snap["claims"][0].get("provenance"))
EOF
)"

it "the original inputs are kept aside, byte for byte"
[[ "$BEFORE1" =~ ^[0-9a-f]{64}\ [0-9a-f]{64}\ [0-9a-f]{64}$ ]] || fail "the legacy inputs were not hashed: $BEFORE1"
check "$BEFORE1" "$(run_py "$RUN1" <<'EOF'
run = args[0]
names = sorted(os.listdir(os.path.dirname(export_path(run)))) + sorted(os.listdir(home(run)))
def aside(base):
    hits = [n for n in os.listdir(os.path.dirname(base)) if n.startswith(os.path.basename(base) + ".imported-")]
    return sha(os.path.join(os.path.dirname(base), hits[0])) if hits else "missing"
print(" ".join(aside(p) for p in (export_path(run), os.path.join(home(run), "journal.jsonl"),
                                   os.path.join(home(run), "claims.jsonl"))))
EOF
)"

it "status reads the promoted programme through the CLI"
as sess-a status --run "$RUN1" --json
check "0 linear:AI-1" "$CODE $(json_field '",".join(sorted(i["id"] for i in d["model"]["items"]))' 2>/dev/null)"

# ── 5. imported typed prompts stay unverified ─────────────────────────────
it "an imported typed prompt cannot approve a new change"
as sess-a amend-term stop_rule never_stop --prompt "$P1" --run "$RUN1"
check "1" "$CODE"
has "imported from a legacy journal" "$OUT"

it "a prompt typed after promotion still approves through the unchanged typed check"
P1B="$(new_typed sess-a 'set the stop_rule to never_stop')"
as sess-a amend-term stop_rule never_stop --prompt "$P1B" --run "$RUN1"
check "0" "$CODE"

# ── 4. writers cannot bypass the authority ───────────────────────────────
it "a verb commits the record and its journal event at one revision"
check "1 True" "$(run_py "$RUN1" <<'EOF'
import subprocess
run = args[0]
before = rev(run)
env = dict(os.environ, CLAUDE_CODE_SESSION_ID="sess-a")
subprocess.run([sys.executable, os.path.join(sys.argv[1], "lib", "programme.py"), "set-now",
                "working", "--run", run], env=env, capture_output=True)
snap = auth.snapshot(run)
ev = [e for e in snap["events"] if e["kind"] == "working_now"][-1]
print(snap["revision"] - before, ev["revision"] == snap["revision"] and snap["record"]["programme"]["working_model"]["doing"] is not None)
EOF
)"

it "a worker claim goes into the authority, and the claims export follows it"
WS=w1 as sess-w2 claim --run "$RUN1" --item linear:AI-1 --deliverable merged --ref pr-2
check "0 2 2" "$CODE $(run_py "$RUN1" <<'EOF'
run = args[0]
print(pj.claims_count(run), len(open(os.path.join(home(run), "claims.jsonl")).readlines()))
EOF
)"

it "a write whose record would hold a secrets-file value is refused before anything is saved"
R1A="$(run_py "$RUN1" <<'EOF'
print(rev(args[0]))
EOF
)"
WS=w1 as sess-a add-item linear:AI-2 --title "deploy with ${SECRET} today" --run "$RUN1"
check "1 $R1A" "$CODE $(run_py "$RUN1" <<'EOF'
print(rev(args[0]))
EOF
)"
has "admission is prohibited" "$OUT"
lacks "$SECRET" "$OUT"
check "0" "$(grep -rlaF "$SECRET" "${CLAUDE_AUTO_DATA_DIR}/programmes/${RUN1}" | wc -l | tr -d ' ')"

it "raw journal and claims appends refuse a promoted home"
check "refused refused" "$(run_py "$RUN1" <<'EOF'
run = args[0]
out = []
for name in ("journal.jsonl", "claims.jsonl"):
    try:
        pj.append_to(os.path.join(home(run), name), "claim", "s", {})
        out.append("wrote")
    except pj.JournalError:
        out.append("refused")
print(" ".join(out))
EOF
)"

it "an evidence refutation and a hook prompt land in the authority"
check "True True" "$(run_py "$RUN1" <<'EOF'
run = args[0]
pj.append(run, "evidence_refuted", "sess-a", {"item": "linear:AI-1", "deliverable": "merged", "ref": "pr-1"})
ks = kinds(run)
print("evidence_refuted" in ks, sum(1 for k in ks if k == "prompt") >= 2)
EOF
)"

it "the shared record primitive and set_loop route to the authority"
check "2 True" "$(run_py "$RUN1" <<'EOF'
run = args[0]
before = rev(run)
core._with_locked_run_record(home(run), run, lambda r: r.setdefault("loop", {}).update(note="x"))
load_lib_module("run_record").set_loop(home(run), run, beat=True)
print(rev(run) - before, json.load(open(export_path(run)))[auth.TAG] == rev(run))
EOF
)"

it "the offline downgrade refuses a promoted record"
check "refused" "$(run_py "$RUN1" <<'EOF'
run = args[0]
try:
    load_lib_module("run_record").downgrade_record_file(export_path(run))
    print("wrote")
except Exception as exc:
    print("refused" if "programme.db" in str(exc) else f"other {exc}")
EOF
)"

it "prune records which prompts it drops instead of rewriting the journal"
check "pruned-in-authority" "$(run_py "$RUN1" <<'EOF'
import datetime
run = args[0]
later = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=30)
pj.append_prompt(run, "sess-a", "an uncited aside", "typed")
removed = pj.prune_uncited_prompts(run, now=later)
rows = auth.snapshot(run)["journal"]
print("pruned-in-authority" if removed >= 1 and rows[-1]["kind"] == "prompts_pruned"
      and not any(r.get("payload", {}).get("text") == "an uncited aside" for r in rows) else f"no {removed}")
EOF
)"

# ── 6. ordinary task runs are unchanged ──────────────────────────────────
it "a task record written by the new code matches the obsolete code key for key"
check "same-shape no-db" "$(run_py "$OLD" <<'EOF'
import importlib.util, subprocess
old_lib = args[0]
repo_new, repo_old = os.path.join(os.environ["CLAUDE_AUTO_DATA_DIR"], "..", "task-new"), \
    os.path.join(os.environ["CLAUDE_AUTO_DATA_DIR"], "..", "task-old")
os.makedirs(repo_new, exist_ok=True); os.makedirs(repo_old, exist_ok=True)
core.init_run_record(repo_new, "task-1", backend="native", steps=[{"id": "s1"}], loop_phase="work")
code = ("import sys; sys.path.insert(0, %r); from _bootstrap import load_lib_module; "
        "c = load_lib_module('run_record_core'); "
        "c.init_run_record(%r, 'task-1', backend='native', steps=[{'id': 's1'}], loop_phase='work')") % (old_lib, repo_old)
subprocess.run([sys.executable, "-c", code], check=True)
def shape(repo):
    d = json.load(open(core.run_record_path(repo, "task-1")))
    d["loop"].pop("last_beat_at", None)
    return d
new, old = shape(repo_new), shape(repo_old)
core._with_locked_run_record(repo_new, "task-1", lambda r: None)
again = shape(repo_new)
dbs = [n for n in os.listdir(os.path.join(repo_new, ".claude", "auto")) if "programme" in n or n.endswith(".db")]
print(("same-shape" if new == old and again == old else "differs") + (" no-db" if not dbs else f" db {dbs}"))
EOF
)"

# ── 8. exports removed after commit ──────────────────────────────────────
WS=w8
as sess-e start --space default.w8
RUN8="$(json_field 'd["run"]')"
as sess-e add-item linear:AI-9 --title "open work" --run "$RUN8"
it "a new programme is born in the authority"
check "supported" "$(run_py "$RUN8" <<'EOF'
print(auth.outcome(args[0])["outcome"])
EOF
)"

it "every export of the new programme is removed"
check "gone" "$(run_py "$RUN8" <<'EOF'
run = args[0]
gone = True
for p in (export_path(run), os.path.join(home(run), "journal.jsonl"), os.path.join(home(run), "claims.jsonl"),
          os.path.join(home(run), "views", "view.json")):
    try:
        os.unlink(p)
    except FileNotFoundError:
        gone = False
print("gone" if gone and not os.path.exists(export_path(run)) else "missing-before-delete")
EOF
)"

it "with every export removed, discovery, record reads and lease lookup still find the authority"
check "True live True" "$(run_py "$RUN8" <<'EOF'
run = args[0]
found = run in [r for _, r, _ in boot.iter_programme_homes()]
lease = ph.read_lease(ph.lease_path("default", "w8"))
rec = core.read_run_record(home(run), run)
print(found, ph.lease_status(lease), rec["driving_session_id"] == "sess-e")
EOF
)"

it "the CLI status works with the exports removed"
as sess-e status --run "$RUN8" --json
check "0 $RUN8" "$CODE $(json_field 'd["run"]')"

it "SessionStart still restores the rules with the exports removed"
SS="$(printf '{"session_id":"sess-e","source":"startup"}' | "$PY" "${LIB}/on-session-start.py" "$NOREPO" 2>&1)"
has "Rules in force" "$SS"

it "Stop still sees the programme with the exports removed"
STOP="$(printf '{"session_id":"sess-e"}' | "$PY" "${LIB}/on-stop.py" "$NOREPO" 2>&1)"
has "$RUN8" "$STOP"

cp "${CLAUDE_AUTO_DATA_DIR}/programmes/${RUN8}/programme.db" "${WORK}/db8.bak"
printf 'not a database at all, just bytes' > "${CLAUDE_AUTO_DATA_DIR}/programmes/${RUN8}/programme.db"
it "a corrupt authority is an explicit hold for readers, not an empty programme"
check "corrupt held corrupt corrupt" "$(run_py "$RUN8" <<'EOF'
run = args[0]
o = auth.outcome(run)["outcome"]
try:
    core.read_run_record(home(run), run); r = "read"
except auth.AuthorityHold as exc:
    r = "held"
outs = {x["run_id"]: x["outcome"] for x in boot.iter_programme_outcomes()}
holds = [d.get("hold", {}).get("outcome") for d in ph.driven_runs("sess-e")]
print(o, r, outs.get(run), holds[0] if holds else "none")
EOF
)"

it "a corrupt authority's lease is held, so no competing start takes the space"
check "unavailable" "$(run_py "$RUN8" <<'EOF'
print(ph.lease_status(ph.read_lease(ph.lease_path("default", "w8"))))
EOF
)"
WS=w8 as sess-x start --space default.w8
check "1" "$CODE"
has "is held by run ${RUN8}" "$OUT"

it "Stop blocks once and names the held authority instead of letting it pass as free"
STOP="$(printf '{"session_id":"sess-e"}' | "$PY" "${LIB}/on-stop.py" "$NOREPO" 2>&1)"
has "corrupt" "$STOP"

it "SessionStart reports the hold instead of nothing"
SS="$(printf '{"session_id":"sess-e","source":"startup"}' | "$PY" "${LIB}/on-session-start.py" "$NOREPO" 2>&1)"
has "corrupt" "$SS"

it "a typed prompt in a held programme is reported, not silently dropped"
HP="$(hook_payload sess-e 'hello' | HERDR_WORKSPACE_ID=w8 "$PY" "${LIB}/on-user-prompt.py")"
has "corrupt" "$HP"

rm -f "${CLAUDE_AUTO_DATA_DIR}/programmes/${RUN8}/programme.db"
it "a promoted home whose database is missing is unavailable, never a fallback to JSON"
check "unavailable" "$(run_py "$RUN8" <<'EOF'
print(auth.outcome(args[0])["outcome"])
EOF
)"
cp "${WORK}/db8.bak" "${CLAUDE_AUTO_DATA_DIR}/programmes/${RUN8}/programme.db"

# ── 10. crash after ownership commit, before lease publication ───────────
it "a start killed after its commit leaves no lease, but a competing start is still refused"
LOG10="${WORK}/start10.log"
( CLAUDE_AUTO_TEST_STORE_PAUSE_AFTER_COMMIT=1 CLAUDE_CODE_SESSION_ID=sess-f HERDR_WORKSPACE_ID=w10 \
    "$PY" "$PROG" start --space default.w10 > "$LOG10" 2>&1 ) &
P10=$!
CHILDREN="$CHILDREN $P10"
wait_for "$LOG10" "paused:after_commit" || fail "the start never reached its commit"
pkill -9 -P "$P10" 2>/dev/null; kill -9 "$P10" 2>/dev/null; wait "$P10" 2>/dev/null
check "no-lease" "$(run_py <<'EOF'
print("no-lease" if ph.read_lease(ph.lease_path("default", "w10")) is None else "lease")
EOF
)"
WS=w10 as sess-g start --space default.w10
check "1" "$CODE"
has "is held by run prog-" "$OUT"
it "the refusal names the original run and republishes its lease"
check "sess-f" "$(run_py <<'EOF'
lease = ph.read_lease(ph.lease_path("default", "w10"))
print(lease and lease.get("session_id"))
EOF
)"

# ── 2. interrupted import ────────────────────────────────────────────────
WS=w2
RUN2="$(legacy_programme sess-b w2)"
LOG2="${WORK}/promote2.log"
( CLAUDE_AUTO_TEST_STORE_PAUSE_BEFORE_COMMIT=1 CLAUDE_CODE_SESSION_ID=sess-b \
    "$PY" "$PROG" promote --run "$RUN2" > "$LOG2" 2>&1 ) &
P2=$!
CHILDREN="$CHILDREN $P2"
it "an import killed before its commit leaves a hold, not a half-promoted programme"
wait_for "$LOG2" "paused:before_commit" || fail "the import never reached its commit"
kill -9 "$P2" 2>/dev/null; wait "$P2" 2>/dev/null
check "unavailable" "$(run_py "$RUN2" <<'EOF'
print(auth.outcome(args[0])["outcome"])
EOF
)"
it "rerunning the import after a kill before commit imports exactly once"
as sess-b promote --run "$RUN2"
check "0 promoted 1" "$CODE $(json_field 'd["status"]') $(run_py "$RUN2" <<'EOF'
print(sum(1 for e in auth.snapshot(args[0])["events"] if e["kind"] == "legacy_import"))
EOF
)"

WS=w3
RUN3="$(legacy_programme sess-c w3)"
LOG3="${WORK}/promote3.log"
( CLAUDE_AUTO_TEST_STORE_PAUSE_AFTER_COMMIT=1 CLAUDE_CODE_SESSION_ID=sess-c \
    "$PY" "$PROG" promote --run "$RUN3" > "$LOG3" 2>&1 ) &
P3=$!
CHILDREN="$CHILDREN $P3"
wait_for "$LOG3" "paused:after_commit" || fail "the import never reached its commit"
kill -9 "$P3" 2>/dev/null; wait "$P3" 2>/dev/null
it "rerunning an import killed after its commit is a no-op that keeps the originals"
as sess-c promote --run "$RUN3"
check "0 already_promoted 1 kept" "$CODE $(json_field 'd["status"]') $(run_py "$RUN3" <<'EOF'
run = args[0]
n = sum(1 for e in auth.snapshot(run)["events"] if e["kind"] == "legacy_import")
d = os.path.dirname(export_path(run))
kept = any(x.startswith(run + ".json.imported-") for x in os.listdir(d))
print(n, "kept" if kept else "lost")
EOF
)"

# ── 3 + 9. obsolete writers paused across the cutover ────────────────────
cat > "${WORK}/pause_shim.py" <<'EOF'
import fcntl, os, runpy, sys
gate, script = sys.argv[1], sys.argv[2]
want = int(os.environ.get("SHIM_PAUSE_AT", "1"))
real = fcntl.flock
seen = {"n": 0}
def flock(fd, op):
    if op & fcntl.LOCK_EX:
        seen["n"] += 1
        if seen["n"] == want:
            print("shim:paused", flush=True)
            while not os.path.exists(gate):
                import time; time.sleep(0.05)
    return real(fd, op)
fcntl.flock = flock
sys.argv = [script] + sys.argv[3:]
sys.path.insert(0, os.path.dirname(script))
runpy.run_path(script, run_name="__main__")
EOF

WS=w4
RUN4="$(legacy_programme sess-d w4)"
GATE4="${WORK}/gate4"
LOG4="${WORK}/old4.log"
( CLAUDE_CODE_SESSION_ID=sess-d HERDR_WORKSPACE_ID=w4 "$PY" "${WORK}/pause_shim.py" "$GATE4" \
    "${OLD}/programme.py" propose-agreement --term stop_rule=never_stop --why old-writer --run "$RUN4" \
    > "$LOG4" 2>&1 ) &
P4=$!
CHILDREN="$CHILDREN $P4"
it "an obsolete writer paused before its record lock does not stop promotion"
wait_for "$LOG4" "shim:paused" || fail "the obsolete writer never paused"
as sess-d promote --run "$RUN4"
check "0 promoted" "$CODE $(json_field 'd["status"]')"
R4="$(run_py "$RUN4" <<'EOF'
print(rev(args[0]))
EOF
)"
touch "$GATE4"
wait "$P4" 2>/dev/null
it "the resumed obsolete writer reports success only to its own obsolete file"
has '"ok": true' "$(cat "$LOG4")"
it "the obsolete write never reaches the authority, and every reader ignores it"
check "$R4 nothing never_stop-only-in-export" "$(run_py "$RUN4" <<'EOF'
run = args[0]
snap = auth.snapshot(run)
term = lambda r: r["programme"]["agreement"]["terms"]["stop_rule"]["value"]
readers = [snap["record"], core.read_run_record(home(run), run), boot.load_run_record_safe(export_path(run)),
           ph._read_record(run)]
raw = json.load(open(export_path(run)))
print(snap["revision"], "nothing" if all(term(r) != "never_stop" for r in readers) else "leaked",
      "never_stop-only-in-export" if term(raw) == "never_stop" else "export-untouched")
EOF
)"

it "the next authority write quarantines the obsolete record write and journals it"
as sess-d beat --run "$RUN4"
check "0 True True" "$CODE $(run_py "$RUN4" <<'EOF'
run = args[0]
d = os.path.dirname(export_path(run))
quarantined = any(".foreign-" in n for n in os.listdir(d))
print(quarantined, "foreign_write_absorbed" in kinds(run))
EOF
)"

WS=w5
RUN5="$(legacy_programme sess-h w5)"
GATE5="${WORK}/gate5"
LOG5="${WORK}/old5.log"
( CLAUDE_CODE_SESSION_ID=sess-h HERDR_WORKSPACE_ID=w5 SHIM_PAUSE_AT=2 "$PY" "${WORK}/pause_shim.py" "$GATE5" \
    "${OLD}/programme.py" propose-agreement --term stop_rule=never_stop --why split-write --run "$RUN5" \
    > "$LOG5" 2>&1 ) &
P5=$!
CHILDREN="$CHILDREN $P5"
it "an obsolete writer paused between its record write and its journal append"
wait_for "$LOG5" "shim:paused" || fail "the obsolete writer never paused"
as sess-h promote --run "$RUN5"
check "0 promoted" "$CODE $(json_field 'd["status"]')"
touch "$GATE5"
wait "$P5" 2>/dev/null
it "the record half is imported, and the late journal line is absorbed as unverified history"
as sess-h beat --run "$RUN5"
check "never_stop gap foreign_write" "$(run_py "$RUN5" <<'EOF'
run = args[0]
snap = auth.snapshot(run)
imp_ev = [e for e in snap["events"] if e["kind"] == "legacy_import"][0]
gaps = {g["kind"] for g in imp_ev["payload"]["gaps"]}
late = [r for r in snap["journal"] if r["kind"] == "agreement_proposed"]
print(snap["record"]["programme"]["agreement"]["terms"]["stop_rule"]["value"],
      "gap" if "record_only_update" in gaps else f"no-gap {gaps}",
      late[-1].get("provenance") if late else "missing")
EOF
)"

it "a fresh obsolete hook invocation after promotion cannot create an approving prompt"
WS=w4
P4OLD="$(old_typed sess-d 'accept the agreement')"
as sess-d beat --run "$RUN4"
as sess-d accept-agreement --prompt "$P4OLD" --run "$RUN4"
check "1" "$CODE"
has "imported from a legacy journal" "$OUT"

# ── 7. interrupted takeover and personal-protocol projection ─────────────
WS=w6
as sess-i start --space default.w6
RUN6="$(json_field 'd["run"]')"
P6="$(new_typed sess-i 'accept the agreement')"
as sess-i accept-agreement --prompt "$P6" --run "$RUN6"
as sess-i propose-rule '{"id":"tidy-branches","applies_when":{"change_kinds":["evals_or_docs"]},"requires":["merged"],"evidence_bar":{"merged":"merged at the gate"},"caveat":"","autonomy":"act_and_tell","added_by":"pm","added_at":"2026-10-06T10:00:00Z","why":"docs need a merge"}' --run "$RUN6"
P6R="$(new_typed sess-i 'adopt rule tidy-branches')"
LOG6="${WORK}/adopt6.log"
( CLAUDE_AUTO_TEST_STORE_PAUSE_BEFORE_COMMIT=1 CLAUDE_CODE_SESSION_ID=sess-i HERDR_WORKSPACE_ID=w6 \
    "$PY" "$PROG" adopt-rule tidy-branches --prompt "$P6R" --run "$RUN6" > "$LOG6" 2>&1 ) &
P6P=$!
CHILDREN="$CHILDREN $P6P"
wait_for "$LOG6" "paused:before_commit" || fail "the adoption never reached its commit"
kill -9 "$P6P" 2>/dev/null; wait "$P6P" 2>/dev/null
it "a personal projection written before a killed commit is not an adopted rule"
check "rejected" "$(run_py "$RUN6" <<'EOF'
prog = load_lib_module("programme")
rules = prog.rules_in_force(core.read_run_record(home(args[0]), args[0]))
ids = [r["id"] for r in rules["rules"]]
rej = [r["id"] for r in rules["rejected_rules"]]
print("rejected" if "tidy-branches" not in ids and "tidy-branches" in rej else f"ids={ids} rej={rej}")
EOF
)"
it "retrying the adoption consumes the approval once"
as sess-i adopt-rule tidy-branches --prompt "$P6R" --run "$RUN6" --op adopt-once
check "0 1 1 adopted" "$CODE $(run_py "$RUN6" <<'EOF'
run = args[0]
prog = load_lib_module("programme")
n = kinds(run).count("rule_adopted")
doc = json.load(open(os.environ["CLAUDE_AUTO_PERSONAL_PROTOCOL"]))
mine = [r for r in doc["rules"] if r.get("id") == "tidy-branches"]
ids = [r["id"] for r in prog.rules_in_force(core.read_run_record(home(run), run))["rules"]]
print(n, len(mine), "adopted" if "tidy-branches" in ids else "not")
EOF
)"
it "replaying the adoption with the same operation id returns the committed result without consuming it again"
as sess-i adopt-rule tidy-branches --prompt "$P6R" --run "$RUN6" --op adopt-once
check "0 true rule_adopted 1" "$CODE $(json_field 'd.get("replayed")') $(json_field 'd.get("kind")') $(run_py "$RUN6" <<'EOF'
print(kinds(args[0]).count("rule_adopted"))
EOF
)"
it "the same operation id with no prior commit runs the verb normally"
as sess-i set-now "replay probe" --run "$RUN6" --op fresh-op
check "0 null" "$CODE $(json_field 'd.get("replayed")')"

it "a typed prompt and a rule adoption appended by an obsolete writer after promotion approve nothing"
run_py "$RUN6" >/dev/null <<'EOF'
run = args[0]
prog = load_lib_module("programme")
proto = load_lib_module("programme_protocol")
rows = auth.snapshot(run)["journal"]
real = [r for r in rows if r["kind"] == "rule_adopted"][-1]
prompt = pj.find_prompt(run, real["cites"][0], rows)
path = os.environ["CLAUDE_AUTO_PERSONAL_PROTOCOL"]
doc = json.load(open(path))
mine = [r for r in doc["rules"] if r.get("id") == "tidy-branches"][0]
forged = {k: v for k, v in mine.items() if k != "adoption"}
forged.update(id="forged-rule", why="copied text")
fake, text = "p" + "f" * 12, "adopt rule forged-rule"
digest = proto.content_hash(forged)
forged["adoption"] = dict(mine["adoption"], prompt_id=fake, hash=digest, prompt_hash=prog.text_hash(text))
doc["rules"].append(forged)
json.dump(doc, open(path, "w"))
row_p = dict(prompt, prompt_id=fake, payload=dict(prompt["payload"], text=text))
row_a = dict(real, cites=[fake], payload=dict(real["payload"], prompt_id=fake, hash=digest,
                                               target=proto.target_of("rules", "forged-rule")))
with open(os.path.join(home(run), "journal.jsonl"), "a") as fh:
    row_e = {"kind": "end_request", "at": real["at"], "session_id": "sess-i", "cites": None,
             "payload": {"verb": "end", "text": "/auto:programme-end", "origin": "typed", "driving": False}}
    for row in (row_p, row_a, row_e):
        row.pop("provenance", None)
        fh.write(json.dumps(row, sort_keys=True) + "\n")
EOF
as sess-i set-now "absorb the obsolete rows" --run "$RUN6"
check "0 1 None foreign_write rejected 0" "$CODE $(run_py "$RUN6" <<'EOF'
run = args[0]
prog = load_lib_module("programme")
asked = load_lib_module("programme_lifecycle")._requests(run, "end", "sess-i")
fake = "p" + "f" * 12
rows = auth.snapshot(run)["journal"]
absorbed = [r.get("provenance") for r in rows if r.get("prompt_id") == fake or fake in (r.get("cites") or [])]
rules = prog.rules_in_force(core.read_run_record(home(run), run))
ids = [r["id"] for r in rules["rules"]]
rej = [r["id"] for r in rules["rejected_rules"]]
print(kinds(run).count("foreign_write_absorbed"), prog.prompt_lookup(run, fake),
      ",".join(sorted(set(absorbed))),
      "rejected" if "forged-rule" not in ids and "forged-rule" in rej else f"ids={ids} rej={rej}", len(asked))
EOF
)"
run_py "$RUN6" >/dev/null <<'EOF'
path = os.environ["CLAUDE_AUTO_PERSONAL_PROTOCOL"]
doc = json.load(open(path))
doc["rules"] = [r for r in doc["rules"] if r.get("id") != "forged-rule"]
json.dump(doc, open(path, "w"))
EOF

run_py "$RUN6" >/dev/null <<'EOF'
run = args[0]
import datetime
old = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=5)).strftime("%Y-%m-%dT%H:%M:%SZ")
core._with_locked_run_record(home(run), run, lambda r: r["loop"].update(last_beat_at=old))
EOF
new_typed sess-j '/auto:programme-takeover' >/dev/null
it "an obsolete writer's consuming row cannot use up a real typed request"
check "1 foreign_write 1" "$(run_py "$RUN6" <<'EOF' | tail -1
run = args[0]
lc = load_lib_module("programme_lifecycle")
before = lc._requests(run, "takeover", "sess-j")
consumed = {"kind": "taken_over", "at": before[0]["at"], "session_id": "sess-j",
            "payload": {"request": lc._request_ref(before[0])}}
with open(os.path.join(home(run), "journal.jsonl"), "a") as fh:
    fh.write(json.dumps(consumed, sort_keys=True) + "\n")
auth.mutate(home(run), run, lambda r: None)
prov = [r.get("provenance") for r in auth.snapshot(run)["journal"] if r.get("kind") == "taken_over"]
print(len(before), ",".join(sorted(set(map(str, prov)))), len(lc._requests(run, "takeover", "sess-j")))
EOF
)"
LOG7="${WORK}/takeover7.log"
( CLAUDE_AUTO_TEST_STORE_PAUSE_AFTER_COMMIT=1 CLAUDE_CODE_SESSION_ID=sess-j HERDR_WORKSPACE_ID=w6 \
    "$PY" "$PROG" takeover --run "$RUN6" > "$LOG7" 2>&1 ) &
P7=$!
CHILDREN="$CHILDREN $P7"
wait_for "$LOG7" "paused:after_commit" || fail "the takeover never reached its commit"
kill -9 "$P7" 2>/dev/null; wait "$P7" 2>/dev/null
it "a takeover killed between its commit and its lease rewrite leaves no dual driver"
check "sess-j 0 0 taken_over" "$(run_py "$RUN6" <<'EOF'
run = args[0]
rec = core.read_run_record(home(run), run)
print(rec["driving_session_id"], len(ph.driven_runs("sess-i")), len(ph.driven_runs("sess-j")),
      "taken_over" if "taken_over" in kinds(run) else "no-event")
EOF
)"
it "reconciling the leases from the authority restores one driver"
as sess-j reconcile-leases --run "$RUN6"
check "0 0 1" "$CODE $(run_py "$RUN6" <<'EOF'
print(len(ph.driven_runs("sess-i")), len(ph.driven_runs("sess-j")))
EOF
)"

# ── a current-code record write that decided "legacy" just before promote ran ──
cat > "${WORK}/racer.py" <<'EOF'
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
ph = load_lib_module("programme_home")
core = load_lib_module("run_record_core")
run, mode = sys.argv[2], sys.argv[3]
if mode == "core":
    core._with_locked_run_record(ph.home_path(run), run,
                                 lambda r: r["programme"]["working_model"].update(doing="racer was here"))
else:
    load_lib_module("programme_authority").write(
        ph.home_path(run), run, lambda r: r["programme"]["working_model"].update(next="second racer"),
        lambda _, r: load_lib_module("programme_journal").entry("working_now", None, {"by": "racer"}))
print("racer:ok", flush=True)
EOF
WS=w13
RUN10="$(legacy_programme sess-r w13)"
GATE10="${WORK}/gate10"
LOG10="${WORK}/racer10.log"
LOG10B="${WORK}/racer10b.log"
( "$PY" "${WORK}/pause_shim.py" "$GATE10" "${WORK}/racer.py" "$AUTO_ROOT" "$RUN10" core > "$LOG10" 2>&1 ) &
P10=$!
( "$PY" "${WORK}/pause_shim.py" "$GATE10" "${WORK}/racer.py" "$AUTO_ROOT" "$RUN10" write > "$LOG10B" 2>&1 ) &
P10B=$!
CHILDREN="$CHILDREN $P10 $P10B"
it "two record writes that routed before promotion are paused at the run lock"
wait_for "$LOG10" "shim:paused" && wait_for "$LOG10B" "shim:paused" && pass || fail "a racing writer never paused"
as sess-r promote --run "$RUN10"
check "0 promoted" "$CODE $(json_field 'd["status"]')"
touch "$GATE10"
wait "$P10" "$P10B" 2>/dev/null
it "both racing writes report success"
has "racer:ok" "$(cat "$LOG10")"
has "racer:ok" "$(cat "$LOG10B")"
as sess-r beat --run "$RUN10"
it "the acknowledged racing writes land in the authority, not only in the export"
check "racer was here|second racer|no-quarantine|1" "$(run_py "$RUN10" <<'EOF'
run = args[0]
d = os.path.dirname(export_path(run))
snap = auth.snapshot(run)
wm = snap["record"]["programme"]["working_model"]
print(wm.get("doing"), wm.get("next"), "quarantined" if any(".foreign-" in n for n in os.listdir(d)) else
      "no-quarantine", sum(1 for r in snap["journal"] if (r.get("payload") or {}).get("by") == "racer"), sep="|")
EOF
)"
it "the write path commits its record change and journal row together"
check "same" "$(run_py "$RUN10" <<'EOF'
snap = auth.snapshot(args[0])
ev = [e for e in snap["events"] if ((e["payload"] or {}).get("row") or {}).get("payload", {}).get("by") == "racer"]
# A row appended apart from its record change commits under an "a-" operation of its own.
print("same" if len(ev) == 1 and ev[0]["operation_id"].startswith("w-") else f"split {ev}")
EOF
)"

# ── journal and claims appends that decided "legacy" just before promote ran ──
cat > "${WORK}/appender.py" <<'EOF'
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
sys.path.insert(0, os.path.join(sys.argv[1], "tests", "fixtures"))
from _bootstrap import load_lib_module
from programme_prompts import append_prompt as fixture_prompt
pj = load_lib_module("programme_journal")
run, mode = sys.argv[2], sys.argv[3]
try:
    if mode == "prompt":
        print("appender:prompt_id", fixture_prompt(run, "sess-t", "please merge it")["prompt_id"], flush=True)
    elif mode == "claim":
        pj.append_claim(run, "worker-t", {"item": "racing-claim"})
    else:
        pj.append_to(pj.journal_path(run), "working_now", None, {"by": "append_to-racer"})
    print("appender:ok", flush=True)
except pj.JournalError as exc:
    print("appender:refused", exc, flush=True)
EOF
WS=w14
RUN14="$(legacy_programme sess-t w14)"
GATE14="${WORK}/gate14"
for mode in prompt claim path; do
  ( "$PY" "${WORK}/pause_shim.py" "$GATE14" "${WORK}/appender.py" "$AUTO_ROOT" "$RUN14" "$mode" \
      > "${WORK}/append14-${mode}.log" 2>&1 ) &
  CHILDREN="$CHILDREN $!"
done
it "a typed prompt, a claim and a path append that routed before promotion are paused at the journal lock"
wait_for "${WORK}/append14-prompt.log" "shim:paused" && wait_for "${WORK}/append14-claim.log" "shim:paused" \
  && wait_for "${WORK}/append14-path.log" "shim:paused" && pass || fail "a racing append never paused"
as sess-t promote --run "$RUN14"
check "0 promoted" "$CODE $(json_field 'd["status"]')"
touch "$GATE14"
for mode in prompt claim path; do wait_for "${WORK}/append14-${mode}.log" "appender:" ; done
sleep 0.2
P14="$(sed -n 's/^appender:prompt_id \(p[0-9a-f]*\)$/\1/p' "${WORK}/append14-prompt.log")"
it "the racing prompt and claim report success"
has "appender:ok" "$(cat "${WORK}/append14-prompt.log")"
has "appender:ok" "$(cat "${WORK}/append14-claim.log")"
it "the racing path append is refused rather than written into the export"
has "appender:refused" "$(cat "${WORK}/append14-path.log")"
as sess-t beat --run "$RUN14"
it "the racing prompt lands in the authority as a native row and still approves"
check "native|typed|claim-native|no-path-row|no-quarantine" "$(run_py "$RUN14" "$P14" <<'EOF'
run, pid = args
prog = load_lib_module("programme")
snap = auth.snapshot(run)
prow = [r for r in snap["journal"] if r.get("prompt_id") == pid]
crow = [r for r in snap["claims"] if (r.get("payload") or {}).get("item") == "racing-claim"]
look = prog.prompt_lookup(run, pid)
d = os.path.dirname(export_path(run))
print("native" if len(prow) == 1 and "provenance" not in prow[0] else f"prompt {prow}",
      (look or {}).get("origin"),
      "claim-native" if len(crow) == 1 and "provenance" not in crow[0] else f"claim {crow}",
      "no-path-row" if not any((r.get("payload") or {}).get("by") == "append_to-racer" for r in snap["journal"])
      else "path-row-leaked",
      "quarantined" if any(".foreign-" in n for n in os.listdir(d)) else "no-quarantine", sep="|")
EOF
)"
it "the racing prompt and claim commit as authority events with their own provenance"
check "derived worker_result" "$(run_py "$RUN14" "$P14" <<'EOF'
run, pid = args
snap = auth.snapshot(run)
def prov(pred):
    ev = [e for e in snap["events"] if pred(((e["payload"] or {}).get("row") or {}))]
    return ev[0]["provenance"] if len(ev) == 1 else f"events {len(ev)}"
print(prov(lambda r: r.get("prompt_id") == pid), prov(lambda r: (r.get("payload") or {}).get("item") == "racing-claim"))
EOF
)"
it "the racing prompt's source record is kept in the store and in the journal export"
check "store-source export-source" "$(run_py "$RUN14" "$P14" <<'EOF'
run, pid = args
snap = auth.snapshot(run)
stored = [r for r in snap["journal"] if r.get("prompt_id") == pid]
with open(os.path.join(home(run), "journal.jsonl")) as fh:
    exported = [json.loads(l) for l in fh if l.strip()]
exported = [r for r in exported if r.get("prompt_id") == pid]
def has_source(rows):
    return len(rows) == 1 and isinstance(rows[0]["payload"].get("source"), dict) \
        and rows[0]["payload"]["source"].get("session_id") == "sess-t"
print("store-source" if has_source(stored) else f"store {stored}",
      "export-source" if has_source(exported) else f"export {exported}")
EOF
)"

WS=w15
RUN15="$(legacy_programme sess-u w15)"
GATE15="${WORK}/gate15"
( "$PY" "${WORK}/pause_shim.py" "$GATE15" "${WORK}/appender.py" "$AUTO_ROOT" "$RUN15" claim \
    > "${WORK}/append15.log" 2>&1 ) &
P15=$!
CHILDREN="$CHILDREN $P15"
it "a claim paused before promotion is refused when the programme ends before it resumes"
wait_for "${WORK}/append15.log" "shim:paused" || fail "the racing claim never paused"
as sess-u promote --run "$RUN15"
run_py "$RUN15" >/dev/null <<'EOF'
auth.mutate(home(args[0]), args[0], lambda r: r["programme"].update(ended={"at": "2026-01-01T00:00:00Z"}))
EOF
touch "$GATE15"
wait "$P15" 2>/dev/null
check "appender:refused 0" "$(grep -o 'appender:refused' "${WORK}/append15.log") $(run_py "$RUN15" <<'EOF'
print(len(auth.snapshot(args[0])["claims"]))
EOF
)"
has "the programme has ended" "$(cat "${WORK}/append15.log")"

# ── 11. import gaps ──────────────────────────────────────────────────────
WS=w7
RUN7="$(legacy_programme sess-k w7)"
P7A="$(old_typed sess-k 'I accept the agreement, stop_rule never_stop later')"
old_as sess-k accept-agreement --prompt "$P7A" --run "$RUN7"
run_py "$RUN7" "$P7A" >/dev/null <<'EOF'
run, pid = args
path = export_path(run)
rec = json.load(open(path))
rec["programme"].setdefault("instructions", []).append({"id": "i000001", "state": "active", "at": "2026-01-01T00:00:00Z",
    "applies_to": "programme", "until": None, "why": None, "prompt_id": "p999999", "quote": "be careful",
    "closed": None})
json.dump(rec, open(path, "w"))
jp = os.path.join(home(run), "journal.jsonl")
rows = [json.loads(l) for l in open(jp)]
first = [r for r in rows if r.get("prompt_id") == pid][0]
with open(jp, "a") as fh:
    fh.write(json.dumps(dict(first, payload=dict(first["payload"], origin="cron"))) + "\n")
    fh.write('{"kind": "item_added", "at": "2026-01-0')
EOF
it "an import exposes record-only updates, truncated lines and conflicting approval labels"
as sess-k promote --run "$RUN7"
check "0 promoted conflicting_approval_label,record_only_update,unparseable_line" "$CODE $(json_field 'd["status"]') $(run_py "$RUN7" <<'EOF'
ev = [e for e in auth.snapshot(args[0])["events"] if e["kind"] == "legacy_import"][0]
print(",".join(sorted({g["kind"] for g in ev["payload"]["gaps"]})))
EOF
)"
it "the conflicting prompt approves nothing new"
as sess-k amend-term stop_rule never_stop --prompt "$P7A" --run "$RUN7"
check "1" "$CODE"
has "imported from a legacy journal" "$OUT"

WS=w11
RUN11="$(legacy_programme sess-l w11)"
LOG11="${WORK}/promote11.log"
( CLAUDE_AUTO_TEST_IMPORT_PAUSE_AFTER_FREEZE=1 CLAUDE_CODE_SESSION_ID=sess-l \
    "$PY" "$PROG" promote --run "$RUN11" > "$LOG11" 2>&1 ) &
P11=$!
CHILDREN="$CHILDREN $P11"
wait_for "$LOG11" "paused:after_freeze" || fail "the import never froze its inventory"
printf '{"kind": "beat_note", "at": "2026-01-01T00:00:00Z", "session_id": null, "payload": {}}\n' \
  >> "${CLAUDE_AUTO_DATA_DIR}/programmes/${RUN11}/journal.jsonl"
touch "${CLAUDE_AUTO_DATA_DIR}/programmes/${RUN11}/.test-resume-import"
wait "$P11" 2>/dev/null
it "inputs changed after the inventory froze refuse the import"
has "changed" "$(cat "$LOG11")"
check "legacy" "$(run_py "$RUN11" <<'EOF'
print(auth.outcome(args[0])["outcome"])
EOF
)"
it "a rerun imports the changed inputs under a new import identity"
FIRST_ID="$(sed -n 's/.*"import_id": "\(imp-[0-9a-f]*\)".*/\1/p' "$LOG11" | head -1)"
as sess-l promote --run "$RUN11"
NEW_ID="$(json_field 'd["import_id"]')"
if [ "$CODE" = 0 ] && [ -n "$NEW_ID" ] && [ "$NEW_ID" != "$FIRST_ID" ]; then pass; else fail "code=$CODE first=$FIRST_ID new=$NEW_ID"; fi

# ── 12. privacy admission before copying ─────────────────────────────────
WS=w12
RUN12="$(legacy_programme sess-m w12)"
run_py "$RUN12" "$SECRET" >/dev/null <<'EOF'
run, secret = args
path = export_path(run)
rec = json.load(open(path))
rec["programme"]["working_model"]["doing"] = "deploy using " + secret
json.dump(rec, open(path, "w"))
EOF
B12="$(run_py "$RUN12" <<'EOF'
print(sha(export_path(args[0])))
EOF
)"
it "a legacy programme holding a prohibited value is declined, untouched"
[[ "$B12" =~ ^[0-9a-f]{64}$ ]] || fail "the legacy record was not hashed: $B12"
as sess-m promote --run "$RUN12"
check "1 declined legacy $B12" "$CODE $(json_field 'd["status"]') $(run_py "$RUN12" <<'EOF'
print(auth.outcome(args[0])["outcome"], sha(export_path(args[0])))
EOF
)"
lacks "$SECRET" "$OUT"
it "the decline leaves no database, staging or diagnostic holding the prohibited bytes"
check "0" "$(grep -rlaF "$SECRET" "${CLAUDE_AUTO_DATA_DIR}/programmes/${RUN12}" | grep -v "/.claude/auto/${RUN12}.json$" | wc -l | tr -d ' ')"
check "absent" "$( [ -e "${CLAUDE_AUTO_DATA_DIR}/programmes/${RUN12}/programme.db" ] && echo present || echo absent)"

echo ""
echo "programme-storage-cutover.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
