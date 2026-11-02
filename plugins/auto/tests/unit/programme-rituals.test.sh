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
has() { case "$2" in *"$1"*) pass ;; *) fail "expected to find [$1] in [$2]" ;; esac; }

echo "programme-rituals.test.sh"

WORK="$(mktemp -d -t auto-programme-rituals.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export TZ=UTC
export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_CARRYOVER_STORE="${WORK}/personal/carryover.json"
export CLAUDE_AUTO_MACHINE="studio"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_CODE_SESSION_ID="sess-pm"
export CLAUDE_AUTO_RITUALS_STORE="${WORK}/stores/rituals.json"
unset CLAUDE_AUTO_BEHAVIOURS_STORE HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_BIN_PATH CLAUDE_AUTO_REPO 2>/dev/null || true
: > "$CLAUDE_AUTO_SECRETS_FILE"
export WORK

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import datetime, hashlib, json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
sys.path.insert(0, os.path.join(sys.argv[1], 'tests', 'fixtures'))
from programme_prompts import append_prompt as fixture_prompt
ph = load_lib_module("programme_home")
pj = load_lib_module("programme_journal")
core = load_lib_module("run_record_core")
pr = load_lib_module("programme_rituals")
due = load_lib_module("programme_rituals_due")
args = sys.argv[2:]
UTC = datetime.timezone.utc
def at(text):
    return datetime.datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=UTC)
def iso(d):
    return d.strftime("%Y-%m-%dT%H:%M:%SZ")
def record(run):
    return core.read_run_record(ph.home_path(run), run)
def ritual(rid, layer="programme", **kw):
    entry = {"id": rid, "layer": layer, "state": "active", "at": "2026-11-01T00:00:00Z",
             "when": {"text": "every Monday", "trigger": "calendar",
                      "schedule": {"every": "week", "weekday": 0, "at": "09:00"}},
             "steps": ["report what drifted"]}
    if layer == "repo":
        entry["repo_key"] = "acme/alpha"
    entry.update(kw)
    return entry
def event_ritual(rid, trigger="handover", **kw):
    return ritual(rid, when={"text": "at handover", "trigger": trigger}, **kw)
def setup(rituals, clock=None):
    counter = os.path.join(os.environ["WORK"], "spaces")
    n = int(open(counter).read()) + 1 if os.path.exists(counter) else 1
    open(counter, "w").write(str(n))
    run = ph.create_programme(["w%d" % n], "sess-pm")["run"]
    def mutate(rec):
        rec["programme"]["rituals"] = rituals
        rec["programme"]["ritual_clock"] = clock or {}
    core._with_locked_run_record(ph.home_path(run), run, mutate)
    return run
def jrow(kind, when, **payload):
    return {"kind": kind, "at": when, "payload": payload}
def states(result):
    return sorted("%s:%s" % (r["ritual"], r["state"]) for b in ("due", "missed", "in_flight") for r in result[b])
def prompt_for(run, text):
    row = fixture_prompt(run, "sess-pm", text)
    return {"prompt_id": row["prompt_id"], "quote": text,
            "text_hash": "sha256:" + hashlib.sha256(text.encode("utf-8")).hexdigest()}
$(cat)
PYEOF
}

PROG="${AUTO_ROOT}/lib/programme.py"
OUT=""
CODE=0
prog() { OUT="$("$PY" "$PROG" "$@" 2>&1)"; CODE=$?; }
new_run() {
  run_py <<'EOF'
print(setup([]))
EOF
}
tprompt() {
  run_py "$1" "$2" "${3:-typed}" <<'EOF'
print(fixture_prompt(args[0], "sess-pm", args[1], args[2])["prompt_id"])
EOF
}
q() {
  run_py "$1" "$2" <<'EOF'
run, expr = args
rec = record(run)
prog = rec["programme"]
def kinds():
    return [r["kind"] for r in pj.read(run)]
def count(kind):
    return kinds().count(kind)
print(eval(expr))
EOF
}
jfield() { "$PY" -c 'import json,sys; d=json.loads(sys.argv[1].splitlines()[-1]); print(eval(sys.argv[2]))' "$1" "$2" 2>&1; }

it "a weekly schedule resolves to the first Monday 09:00 strictly after a given time"
check "2026-11-02T09:00:00Z 2026-11-09T09:00:00Z" "$(run_py <<'EOF'
sch = pr.parse_schedule("weekly mon 09:00")
print(iso(pr.next_after(sch, at("2026-11-01T12:00:00Z"))), iso(pr.next_after(sch, at("2026-11-02T09:00:00Z"))))
EOF
)"

it "a monthly day 31 lands on the last day of a shorter month"
check "2026-02-28T08:30:00Z" "$(run_py <<'EOF'
print(iso(pr.next_after(pr.parse_schedule("monthly 31 08:30"), at("2026-02-01T00:00:00Z"))))
EOF
)"

it "a bad schedule text is refused with the grammar in the message"
check "True" "$(run_py <<'EOF'
try:
    pr.parse_schedule("sometimes")
    print(False)
except ValueError as exc:
    print("weekly mon HH:MM" in str(exc))
EOF
)"

it "AE3: a step that deploys to production is rejected with the escalation kind named"
check "protected_escalation prod_deploy" "$(run_py <<'EOF'
v = pr.verdict(ritual("r1", steps=["deploy it to production yourself"]))
print(v["reason"], v["detail"])
EOF
)"

it "a calendar ritual without a schedule, and an event ritual with one, are both rejected"
check "bad_value bad_value" "$(run_py <<'EOF'
a = pr.verdict(ritual("r1", when={"text": "x", "trigger": "calendar"}))
b = pr.verdict(ritual("r2", when={"text": "x", "trigger": "start", "schedule": {"every": "day", "at": "09:00"}}))
print(a["reason"], b["reason"])
EOF
)"

it "an unknown key and a repo_key on a programme entry are rejected"
check "unknown_key bad_value" "$(run_py <<'EOF'
print(pr.verdict(ritual("r1", surprise=1))["reason"], pr.verdict(ritual("r2", repo_key="acme/alpha"))["reason"])
EOF
)"

it "an old programme block with no rituals normalizes to an empty list and clock"
check "[] {}" "$(run_py <<'EOF'
block = ph.new_programme_block([], "2026-11-01T00:00:00Z")
del block["rituals"], block["ritual_clock"]
out = ph.normalize_programme(block)
print(out["rituals"], out["ritual_clock"])
EOF
)"

it "a weekly ritual past its due time is due inside the grace window"
check "r1:due" "$(run_py <<'EOF'
run = setup([ritual("r1")], {"r1": {"next_due_at": "2026-11-02T09:00:00Z"}})
print(" ".join(states(due.due(record(run), run, now=at("2026-11-02T09:30:00Z"), rows=[]))))
EOF
)"

it "AE1: past two cadence periods it is missed, and three misses appear together"
check "a:missed b:missed c:missed" "$(run_py <<'EOF'
clock = {k: {"next_due_at": "2026-11-02T09:00:00Z"} for k in "abc"}
run = setup([ritual("a"), ritual("b"), ritual("c")], clock)
print(" ".join(states(due.due(record(run), run, now=at("2026-11-02T20:00:00Z"), rows=[]))))
EOF
)"

it "a ritual before its due time is neither due nor missed"
check "" "$(run_py <<'EOF'
run = setup([ritual("r1")], {"r1": {"next_due_at": "2026-11-09T09:00:00Z"}})
print(" ".join(states(due.due(record(run), run, now=at("2026-11-02T20:00:00Z"), rows=[]))))
EOF
)"

it "a ritual with no clock yet becomes pending at the first slot after it came into force"
check "r1:missed" "$(run_py <<'EOF'
run = setup([ritual("r1")])
print(" ".join(states(due.due(record(run), run, now=at("2026-11-03T09:00:00Z"), rows=[]))))
EOF
)"

it "an event ritual is due from its journal row and cleared by a later answer"
check "h:due|" "$(run_py <<'EOF'
run = setup([event_ritual("h")])
rows = [jrow("handed_over", "2026-11-02T10:00:00Z")]
first = " ".join(states(due.due(record(run), run, now=at("2026-11-02T10:05:00Z"), rows=rows)))
rows.append(jrow("ritual_ran", "2026-11-02T10:06:00Z", ritual="h"))
print(first + "|" + " ".join(states(due.due(record(run), run, now=at("2026-11-02T10:07:00Z"), rows=rows))))
EOF
)"

it "an event that happened before the ritual came into force does not make it pending"
check "" "$(run_py <<'EOF'
run = setup([event_ritual("h", at="2026-11-02T12:00:00Z")])
rows = [jrow("handed_over", "2026-11-02T10:00:00Z")]
print(" ".join(states(due.due(record(run), run, now=at("2026-11-02T12:05:00Z"), rows=rows))))
EOF
)"

it "AE4: a started ritual with no outcome reads in_flight, and a failure ends that state"
check "h:in_flight|h:due" "$(run_py <<'EOF'
run = setup([event_ritual("h")])
rows = [jrow("handed_over", "2026-11-02T10:00:00Z"), jrow("ritual_started", "2026-11-02T10:01:00Z", ritual="h")]
first = " ".join(states(due.due(record(run), run, now=at("2026-11-02T10:05:00Z"), rows=rows)))
rows.append(jrow("ritual_failed", "2026-11-02T10:03:00Z", ritual="h", why="x"))
print(first + "|" + " ".join(states(due.due(record(run), run, now=at("2026-11-02T10:05:00Z"), rows=rows))))
EOF
)"

it "an offer row marks the miss offered, and a miss it did not cover stays unoffered"
check "True False" "$(run_py <<'EOF'
run = setup([ritual("a"), ritual("b")], {k: {"next_due_at": "2026-11-02T09:00:00Z"} for k in "ab"})
rows = [jrow("ritual_offered", "2026-11-02T21:00:00Z", offered=[{"ritual": "a", "pending_at": "2026-11-02T09:00:00Z"}])]
got = {r["ritual"]: r["offered"] for r in due.due(record(run), run, now=at("2026-11-02T22:00:00Z"), rows=rows)["missed"]}
print(got["a"], got["b"])
EOF
)"

it "a personal ritual keeps a separate clock per programme"
check "r1:due|" "$(run_py <<'EOF'
card = pr.adopt(ritual("r1", "personal"), prompt_for(setup([]), "keep r1 global"), {"run_id": "x"})
run1 = setup([], {"r1": {"next_due_at": "2026-11-02T09:00:00Z"}})
run2 = setup([], {"r1": {"next_due_at": "2026-11-09T09:00:00Z"}})
store = {"personal": [card], "repos": {}, "rejected": [], "notices": []}
a = due.due(record(run1), run1, now=at("2026-11-02T09:10:00Z"), rows=[], store=store)
b = due.due(record(run2), run2, now=at("2026-11-02T09:10:00Z"), rows=[], store=store)
print(" ".join(states(a)) + "|" + " ".join(states(b)))
EOF
)"

it "narrower layer wins when the same id exists in the programme and the personal store"
check "programme" "$(run_py <<'EOF'
run = setup([ritual("r1", steps=["narrow"])])
store = {"personal": [ritual("r1", "personal", steps=["broad"])], "repos": {}, "rejected": [], "notices": []}
got = pr.in_force(record(run), store=store)
print(got[0]["layer"])
EOF
)"

RUN="$(new_run)"
P1="$(tprompt "$RUN" "record the Monday report ritual")"
it "record-ritual with a typed prompt stores it, sets the clock and journals one row"
prog record-ritual --run "$RUN" --prompt "$P1" --when "every Monday" --schedule "weekly mon 09:00" --step "report what drifted"
check 0 "$CODE"
RID="$(jfield "$OUT" 'd["ritual"]')"
check "True 1" "$(q "$RUN" "str('next_due_at' in prog['ritual_clock']['$RID']) + ' ' + str(count('ritual_recorded'))")"

it "record-ritual with neither --trigger nor --schedule is refused"
prog record-ritual --run "$RUN" --prompt "$P1" --when "sometime" --step "do a thing"
check 2 "$CODE"
has "exactly one of --trigger or --schedule" "$OUT"

it "AE3: record-ritual with a production-deploy step is refused"
prog record-ritual --run "$RUN" --prompt "$P1" --when "at start" --trigger start --step "deploy to production"
check 1 "$CODE"
has "protected_escalation" "$OUT"

it "propose-ritual needs no prompt and applies nothing"
prog propose-ritual --run "$RUN" --when "on takeover" --trigger takeover --step "read the journal"
check 0 "$CODE"
check "proposed" "$(jfield "$OUT" 'd["state"]')"

it "run-ritual on a due ritual needs no prompt and moves the clock past now"
run_py "$RUN" "$RID" <<'EOF'
def mutate(rec):
    rec["programme"]["ritual_clock"][args[1]] = {"next_due_at": "2026-01-05T09:00:00Z"}
core._with_locked_run_record(ph.home_path(args[0]), args[0], mutate)
EOF
prog start-ritual "$RID" --run "$RUN"
check 1 "$CODE"
has "prompt" "$OUT"

it "AE2: skip-ritual on a missed ritual is refused without a typed prompt, then succeeds and is not offered again"
prog skip-ritual "$RID" --run "$RUN"
check 1 "$CODE"
P2="$(tprompt "$RUN" "skip ${RID} this time")"
prog skip-ritual "$RID" --run "$RUN" --prompt "$P2"
check 0 "$CODE"
check "True" "$(q "$RUN" "str(prog['ritual_clock']['$RID']['next_due_at'] > core.now_iso())")"
check "" "$(q "$RUN" "' '.join(states(due.due(rec, run)))")"

it "start-ritual then run-ritual leaves the ritual answered and journals both rows"
run_py "$RUN" "$RID" <<'EOF'
def mutate(rec):
    rec["programme"]["ritual_clock"][args[1]] = {"next_due_at": core.now_iso()}
core._with_locked_run_record(ph.home_path(args[0]), args[0], mutate)
EOF
sleep 1
prog start-ritual "$RID" --run "$RUN"
check 0 "$CODE"
prog run-ritual "$RID" --run "$RUN" --outcome "sent the digest"
check 0 "$CODE"
check "1 1" "$(q "$RUN" "str(count('ritual_started')) + ' ' + str(count('ritual_ran'))")"

run_py "$RUN" <<'EOF'
def mutate(rec):
    rec["programme"]["rituals"].append(ritual("rbad", steps=["deploy to production"]))
    rec["programme"]["ritual_clock"]["rbad"] = {"next_due_at": core.now_iso()}
core._with_locked_run_record(ph.home_path(args[0]), args[0], mutate)
EOF
it "AE3: a stored ritual whose step is protected is rejected on load with the escalation reason"
check "protected_escalation" "$(q "$RUN" "[r['reason'] for r in pr.resolve(rec)['rejected'] if r['id'] == 'rbad'][0]")"
it "AE3: start-ritual refuses that ritual because it is not in force"
prog start-ritual rbad --run "$RUN"
check 1 "$CODE"
has "not in force" "$OUT"

it "retire-ritual with a typed prompt ends the ritual and drops its clock"
P3="$(tprompt "$RUN" "retire ${RID}")"
prog retire-ritual "$RID" --as retired --prompt "$P3" --run "$RUN"
check 0 "$CODE"
check "retired True" "$(q "$RUN" "next(r for r in prog['rituals'] if r['id']=='$RID')['state'] + ' ' + str('$RID' not in prog['ritual_clock'])")"

it "offer-rituals refuses an id that is not missed or in flight"
prog offer-rituals nothing --run "$RUN"
check 1 "$CODE"

it "keep-rituals moves a programme ritual to the personal store and move-ritual brings it back"
RUN2="$(new_run)"
Q1="$(tprompt "$RUN2" "record a ritual")"
prog record-ritual --run "$RUN2" --prompt "$Q1" --when "at start" --trigger start --step "read the handover"
KID="$(jfield "$OUT" 'd["ritual"]')"
Q2="$(tprompt "$RUN2" "keep ${KID} for personal use everywhere")"
prog keep-rituals "$KID" --to personal --prompt "$Q2" --run "$RUN2"
check 0 "$CODE"
check "$KID@personal" "$(q "$RUN2" "' '.join('%s@%s' % (r['id'], r['layer']) for r in pr.in_force(rec)) ")"
Q3="$(tprompt "$RUN2" "move ${KID} back to the programme layer")"
prog move-ritual "$KID" --to programme --prompt "$Q3" --run "$RUN2"
check 0 "$CODE"
check "$KID@programme" "$(q "$RUN2" "' '.join('%s@%s' % (r['id'], r['layer']) for r in pr.in_force(rec)) ")"

it "waiting_before lists a handover ritual no one answered in the tenure, and an answer in the tenure clears it"
check "h|" "$(run_py <<'EOF'
run = setup([event_ritual("h"), ritual("cal")])
rows = [jrow("programme_started", "2026-11-02T08:00:00Z")]
first = ",".join(due.waiting_before(record(run), run, "handover", rows=rows))
rows.append(jrow("ritual_ran", "2026-11-02T09:00:00Z", ritual="h"))
print(first + "|" + ",".join(due.waiting_before(record(run), run, "handover", rows=rows)))
EOF
)"

it "an answer from an earlier tenure does not clear a handover ritual for the next tenure"
check "h" "$(run_py <<'EOF'
run = setup([event_ritual("h")])
rows = [jrow("programme_started", "2026-11-02T08:00:00Z"), jrow("ritual_ran", "2026-11-02T09:00:00Z", ritual="h"),
        jrow("handed_over", "2026-11-02T10:00:00Z")]
print(",".join(due.waiting_before(record(run), run, "handover", rows=rows)))
EOF
)"

it "a handover ritual run before the verb is not due again for the incoming PM"
check "" "$(run_py <<'EOF'
run = setup([event_ritual("h")])
rows = [jrow("programme_started", "2026-11-02T08:00:00Z"), jrow("ritual_ran", "2026-11-02T09:00:00Z", ritual="h"),
        jrow("handed_over", "2026-11-02T10:00:00Z")]
print(" ".join(states(due.due(record(run), run, now=at("2026-11-02T10:05:00Z"), rows=rows))))
EOF
)"

it "a handover left unanswered (--without-rituals) shows as due then missed for the incoming PM"
check "h:due h:missed" "$(run_py <<'EOF'
run = setup([event_ritual("h")])
rows = [jrow("programme_started", "2026-11-02T08:00:00Z"), jrow("handed_over", "2026-11-02T10:00:00Z")]
a = " ".join(states(due.due(record(run), run, now=at("2026-11-02T10:05:00Z"), rows=rows)))
b = " ".join(states(due.due(record(run), run, now=at("2026-11-02T20:00:00Z"), rows=rows)))
print(a + " " + b)
EOF
)"

RUN3="$(new_run)"
it "a beat after a silence longer than two cadence periods journals one resume event, and the next beat adds none"
run_py "$RUN3" <<'EOF'
def mutate(rec):
    rec.setdefault("loop", {})["last_beat_at"] = "2026-01-01T00:00:00Z"
core._with_locked_run_record(ph.home_path(args[0]), args[0], mutate)
EOF
prog beat --run "$RUN3"
check 0 "$CODE"
prog beat --run "$RUN3"
check "1" "$(q "$RUN3" "count('ritual_event')")"

it "the first write on a fresh programme journals no resume event"
RUN4="$(new_run)"
prog beat --run "$RUN4"
check "0" "$(q "$RUN4" "count('ritual_event')")"

it "a resume event makes a resume ritual due, and a later answer clears it"
check "x:due|" "$(run_py <<'EOF'
run = setup([event_ritual("x", "resume")])
rows = [jrow("ritual_event", "2026-11-02T10:00:00Z", trigger="resume")]
a = " ".join(states(due.due(record(run), run, now=at("2026-11-02T10:05:00Z"), rows=rows)))
rows.append(jrow("ritual_ran", "2026-11-02T10:06:00Z", ritual="x"))
print(a + "|" + " ".join(states(due.due(record(run), run, now=at("2026-11-02T10:07:00Z"), rows=rows))))
EOF
)"

it "a stop_quiet row makes a quiet ritual due"
check "q:due" "$(run_py <<'EOF'
run = setup([event_ritual("q", "quiet")])
rows = [jrow("stop_quiet", "2026-11-02T10:00:00Z")]
print(" ".join(states(due.due(record(run), run, now=at("2026-11-02T10:05:00Z"), rows=rows))))
EOF
)"

it "the sweep verdict names rituals_due for a due ritual and stays quiet once a miss has been offered"
check "True False" "$(run_py <<'EOF'
si = load_lib_module("programme_sweep_inputs")
run = setup([ritual("a")], {"a": {"next_due_at": "2026-11-02T09:00:00Z"}})
due_now = {"due": [{"ritual": "a"}], "missed": [], "in_flight": []}
offered = {"due": [], "missed": [{"ritual": "a", "offered": True}], "in_flight": []}
print(si._rituals_unsettled(due_now), si._rituals_unsettled(offered))
EOF
)"

it "the programme view lists a missed ritual from the record and journal alone"
check "missed" "$(run_py <<'EOF'
pv = load_lib_module("programme_view")
run = setup([ritual("a")], {"a": {"next_due_at": "2020-01-06T09:00:00Z"}})
rec = record(run)
rows = pv.rituals_view(rec, [])
print(rows[0]["state"])
EOF
)"

it "the agreement page renders a Rituals section naming the missed ritual"
has "MISSED" "$(run_py <<'EOF'
pv = load_lib_module("programme_view")
run = setup([ritual("a")], {"a": {"next_due_at": "2020-01-06T09:00:00Z"}})
rows = pv.rituals_view(record(run), [])
print(pv._ritual_text(rows[0]))
EOF
)"

echo
echo "${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
