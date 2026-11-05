#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "programme-storage-cutover-races-and-gaps.test.sh"

. "${AUTO_ROOT}/tests/helpers/programme-storage-cutover-setup.sh"

it "the obsolete implementation at ${OLD_COMMIT} is extracted for the old-writer scenarios"
# programme-storage-cutover-races-and-gaps.test.sh counts this check's pass; here a failed extraction still fails the file.
[ "$OLD_EXTRACTED" = yes ] || fail "git archive ${OLD_COMMIT} failed; every old-writer scenario below fails with it"

# ── 7. interrupted takeover and personal-protocol projection ─────────────
WS=w6
as sess-i start --space default.w6
RUN6="$(json_field 'd["run"]')"
P6="$(opick sess-i "$RUN6" accept-agreement)"
as sess-i accept-agreement --prompt "$P6" --run "$RUN6"
as sess-i propose-rule '{"id":"tidy-branches","applies_when":{"change_kinds":["evals_or_docs"]},"requires":["merged"],"evidence_bar":{"merged":"merged at the gate"},"caveat":"","autonomy":"act_and_tell","added_by":"pm","added_at":"2026-10-06T10:00:00Z","why":"docs need a merge"}' --run "$RUN6"
P6R="$(opick sess-i "$RUN6" 'adopt-rule tidy-branches')"
LOG6="${WORK}/adopt6.log"
( CLAUDE_AUTO_TEST_STORE_PAUSE_BEFORE_COMMIT=1 CLAUDE_CODE_SESSION_ID=sess-i HERDR_WORKSPACE_ID=w6 HERDR_PANE_ID="$(pane_for sess-i w6)" \
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
( CLAUDE_AUTO_TEST_STORE_PAUSE_AFTER_COMMIT=1 CLAUDE_CODE_SESSION_ID=sess-j HERDR_WORKSPACE_ID=w6 HERDR_PANE_ID="$(pane_for sess-j w6)" \
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
    fh.write(json.dumps({"kind": "rulings_carried", "at": "2026-01-01T00:00:00Z", "session_id": "sess-k",
                         "cites": [pid], "payload": {"prompt_id": pid, "carried": ["r1"], "stored": []}}) + "\n")
    fh.write('{"kind": "item_added", "at": "2026-01-0')
EOF
it "an import exposes record-only updates, truncated lines and conflicting approval labels"
as sess-k promote --run "$RUN7"
check "0 promoted conflicting_approval_label,record_only_update,unparseable_line" "$CODE $(json_field 'd["status"]') $(run_py "$RUN7" <<'EOF'
ev = [e for e in auth.snapshot(args[0])["events"] if e["kind"] == "legacy_import"][0]
print(",".join(sorted({g["kind"] for g in ev["payload"]["gaps"]})))
EOF
)"
it "a carry citing the conflicting prompt is listed as a conflicting approval"
check "True" "$(run_py "$RUN7" "$P7A" <<'EOF'
ev = [e for e in auth.snapshot(args[0])["events"] if e["kind"] == "legacy_import"][0]
print({"kind": "conflicting_approval_label", "prompt_id": args[1], "approval": "rulings_carried"} in ev["payload"]["gaps"])
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
echo "programme-storage-cutover-races-and-gaps.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
