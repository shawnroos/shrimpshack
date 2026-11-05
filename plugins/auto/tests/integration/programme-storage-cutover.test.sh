#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "programme-storage-cutover.test.sh"

. "${AUTO_ROOT}/tests/helpers/programme-storage-cutover-setup.sh"

it "the obsolete implementation at ${OLD_COMMIT} is extracted for the old-writer scenarios"
if [ "$OLD_EXTRACTED" = yes ]; then
  pass
else
  fail "git archive ${OLD_COMMIT} failed; every old-writer scenario below fails with it"
fi

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

it "a prompt typed after promotion with no open offer approves nothing"
P1B="$(new_typed sess-a 'set the stop_rule to never_stop')"
as sess-a amend-term stop_rule never_stop --prompt "$P1B" --run "$RUN1"
check "1" "$CODE"
has "no open offer" "$OUT"

it "a prompt typed after promotion as the answer to an open offer approves"
as sess-a offer stop --command 'amend-term stop_rule never_stop' --run "$RUN1"
P1C="$(TYPED_AFTER="$(asked_row sess-a)" new_typed sess-a 'yes, never stop')"
as sess-a amend-term stop_rule never_stop --prompt "$P1C" --reads-as "Set stop_rule to never_stop" --run "$RUN1"
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
    d.pop("contract_capable", None)  # the one additive key the worker contract stamps on new task records
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
( CLAUDE_AUTO_TEST_STORE_PAUSE_AFTER_COMMIT=1 CLAUDE_CODE_SESSION_ID=sess-f HERDR_WORKSPACE_ID=w10 HERDR_PANE_ID="$(pane_for sess-f w10)" \
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

WS=w4
RUN4="$(legacy_programme sess-d w4)"
GATE4="${WORK}/gate4"
LOG4="${WORK}/old4.log"
( CLAUDE_CODE_SESSION_ID=sess-d HERDR_WORKSPACE_ID=w4 HERDR_PANE_ID="$(pane_for sess-d w4)" "$PY" "${WORK}/pause_shim.py" "$GATE4" \
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
( CLAUDE_CODE_SESSION_ID=sess-h HERDR_WORKSPACE_ID=w5 HERDR_PANE_ID="$(pane_for sess-h w5)" SHIM_PAUSE_AT=2 "$PY" "${WORK}/pause_shim.py" "$GATE5" \
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

echo ""
echo "programme-storage-cutover.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
