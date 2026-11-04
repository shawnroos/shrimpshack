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
opick() { "$PY" "${AUTO_ROOT}/tests/fixtures/offer_pick.py" "$@"; }
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
print(v["reason"], v["detail"].split(":")[0])
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
def mutate(rec):
    rec["programme"]["created_at"] = "2026-11-01T00:00:00Z"
core._with_locked_run_record(ph.home_path(run), run, mutate)
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

it "start-ritual on a missed ritual is refused without a typed prompt"
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

it "a due ritual that became missed under the lock is refused without a typed answer"
check "RitualError" "$(run_py <<'EOF'
run = setup([ritual("a")], {"a": {"next_due_at": "2020-01-06T09:00:00Z"}})
class Host:
    prompt_lookup = pr._default_lookup()
try:
    load_lib_module("programme_ritual_run")._check_answer(Host, record(run)["programme"], dict(record(run), run_id=run), "a", None)
    print("allowed")
except pr.RitualError:
    print("RitualError")
EOF
)"

it "skip-ritual needs a typed prompt even for a ritual that is only due"
RUN5="$(new_run)"
run_py "$RUN5" <<'EOF'
def mutate(rec):
    rec["programme"]["rituals"].append(ritual("dd"))
    rec["programme"]["ritual_clock"]["dd"] = {"next_due_at": core.now_iso()}
core._with_locked_run_record(ph.home_path(args[0]), args[0], mutate)
EOF
prog skip-ritual dd --run "$RUN5"
check 1 "$CODE"
has "prompt" "$OUT"

it "start-ritual then fail-ritual ends the in-flight state without answering the ritual"
sleep 1
prog start-ritual dd --run "$RUN5"
check 0 "$CODE"
prog fail-ritual dd --why "worker gone" --run "$RUN5"
check 0 "$CODE"
check "False due" "$(q "$RUN5" "str('dd' in [r['ritual'] for r in due.due(rec, run)['in_flight']]) + ' ' + ','.join(sorted(set(r['state'] for r in due.due(rec, run)['due'])))")"

it "a stored calendar ritual older than the programme does not read as missed in it"
check "" "$(run_py <<'EOF'
run = setup([])
old = ritual("o", "personal", at="2020-01-01T00:00:00Z")
store = {"personal": [old], "repos": {}, "rejected": [], "notices": []}
soon = datetime.datetime.now(UTC) + datetime.timedelta(minutes=1)
print(" ".join(states(due.due(record(run), run, now=soon, rows=[], store=store))))
EOF
)"

it "a quiet ritual is pending once per active-to-quiet change, and its own rows are not activity"
check "q:due||q:due" "$(run_py <<'EOF'
run = setup([event_ritual("q", "quiet")])
now = at("2026-11-02T10:05:00Z")
first = [jrow("stop_quiet", "2026-11-02T10:00:00Z")]
repeat = first + [jrow("ritual_ran", "2026-11-02T10:01:00Z", ritual="q"), jrow("stop_quiet", "2026-11-02T10:02:00Z")]
again = repeat + [jrow("claim", "2026-11-02T10:03:00Z"), jrow("stop_quiet", "2026-11-02T10:04:00Z")]
f = lambda rows: " ".join(states(due.due(record(run), run, now=now, rows=rows)))
print(f(first) + "|" + f(repeat) + "|" + f(again))
EOF
)"

it "an offered in-flight ritual does not keep the sweep unsettled, and an offer from an earlier tenure does not count"
check "True False | False True" "$(run_py <<'EOF'
si = load_lib_module("programme_sweep_inputs")
run = setup([event_ritual("h")])
rows = [jrow("programme_started", "2026-11-02T08:00:00Z"), jrow("handed_over", "2026-11-02T10:00:00Z"),
        jrow("ritual_started", "2026-11-02T10:01:00Z", ritual="h")]
offer = jrow("ritual_offered", "2026-11-02T10:30:00Z", offered=[{"ritual": "h", "pending_at": "2026-11-02T10:00:00Z"}])
now = at("2026-11-02T11:00:00Z")
before = due.due(record(run), run, now=now, rows=rows)
after = due.due(record(run), run, now=now, rows=rows + [offer])
cal = setup([ritual("m")], {"m": {"next_due_at": "2026-11-02T09:00:00Z"}})
stale = [jrow("programme_started", "2026-11-01T08:00:00Z"), jrow("ritual_offered", "2026-11-02T09:30:00Z", offered=[{"ritual": "m", "pending_at": "2026-11-02T09:00:00Z"}]),
         jrow("taken_over", "2026-11-02T10:00:00Z")]
fresh = stale[:2]
n = at("2026-11-02T20:00:00Z")
a = due.due(record(cal), cal, now=n, rows=stale)["missed"][0]["offered"]
b = due.due(record(cal), cal, now=n, rows=fresh)["missed"][0]["offered"]
print(si._rituals_unsettled(before), si._rituals_unsettled(after), "|", a, b)
EOF
)"

it "the handover gate refuses while a handover ritual is unanswered, passes with --without-rituals, and passes once it ran"
RUN6="$(new_run)"
run_py "$RUN6" <<'EOF'
def mutate(rec):
    rec["programme"]["rituals"].append(event_ritual("hh"))
core._with_locked_run_record(ph.home_path(args[0]), args[0], mutate)
EOF
check "refused ok" "$(run_py "$RUN6" <<'EOF'
lc = load_lib_module("programme_lifecycle")
run = args[0]
try:
    due.gate(run, "handover", "live", {}, lc._Refused)
    first = "passed"
except lc._Refused as exc:
    first = "refused" if "hh" in exc.reason and exc.fix else "wrong"
due.gate(run, "handover", "live", {"without-rituals": True}, lc._Refused)
print(first, "ok")
EOF
)"
prog run-ritual hh --run "$RUN6"
check 0 "$CODE"
check "passed" "$(run_py "$RUN6" <<'EOF'
lc = load_lib_module("programme_lifecycle")
try:
    due.gate(args[0], "handover", "live", {}, lc._Refused)
    print("passed")
except lc._Refused:
    print("refused")
EOF
)"

it "offer-rituals records an offer for a missed ritual and the due list then marks it offered"
RUN7="$(new_run)"
run_py "$RUN7" <<'EOF'
def mutate(rec):
    rec["programme"]["rituals"].append(ritual("mm"))
    rec["programme"]["ritual_clock"]["mm"] = {"next_due_at": "2020-01-06T09:00:00Z"}
core._with_locked_run_record(ph.home_path(args[0]), args[0], mutate)
EOF
prog offer-rituals mm --run "$RUN7"
check 0 "$CODE"
check "True" "$(q "$RUN7" "str(due.due(rec, run)['missed'][0]['offered'])")"

it "the ritual verbs a pick can approve are in PICK_VERBS, record-ritual among them"
check "True True True" "$(run_py <<'EOF'
pa = load_lib_module("programme_approval")
print(all(v in pa.PICK_VERBS for v in ("start-ritual", "run-ritual", "skip-ritual", "retire-ritual", "move-ritual", "keep-rituals")),
      pa.label(["start-ritual", "r1"]) == "Approve start-ritual r1", "record-ritual" in pa.PICK_VERBS)
EOF
)"

it "propose-ritual with a production-deploy step is refused and stores nothing"
RUN8="$(new_run)"
prog propose-ritual --run "$RUN8" --when "at start" --trigger start --step "deploy to production"
check 1 "$CODE"
has "protected_escalation" "$OUT"
check "0" "$(q "$RUN8" "len(prog['rituals'])")"

it "record-ritual --from-proposal refuses an id that is not a proposal"
T1="$(tprompt "$RUN8" "record nothing")"
prog record-ritual --run "$RUN8" --from-proposal nothing --prompt "$T1"
check 1 "$CODE"
has "no proposed ritual" "$OUT"

it "record-ritual --from-proposal refuses a declined pick of its offer"
prog propose-ritual --run "$RUN8" --when "on takeover" --trigger takeover --step "read the journal"
PROP="$(jfield "$OUT" 'd["ritual"]')"
T2="$(opick "$RUN8" --decline "record-ritual --from-proposal ${PROP}")"
prog record-ritual --run "$RUN8" --from-proposal "$PROP" --prompt "$T2"
check 1 "$CODE"
check "proposed" "$(q "$RUN8" "next(r for r in prog['rituals'] if r['id']=='$PROP')['state']")"

it "record-ritual --from-proposal refuses a field option beside the proposal"
prog record-ritual --run "$RUN8" --from-proposal "$PROP" --prompt "$T2" --when "something else"
check 2 "$CODE"

it "record-ritual --from-proposal activates the proposal on a pick of its offer, and marks the draft as the PM's"
T3="$(opick "$RUN8" "record-ritual --from-proposal ${PROP}")"
prog record-ritual --run "$RUN8" --from-proposal "$PROP" --prompt "$T3"
check 0 "$CODE"
check "active pm_draft" "$(q "$RUN8" "' '.join((lambda r: (r['state'], r['source']['wording']))(next(r for r in prog['rituals'] if r['id']=='$PROP')))")"

it "a missed ritual is started on a pick of its offer, and skipped on a pick too"
RUN_M="$(new_run)"
TM="$(tprompt "$RUN_M" "read the board every day")"
prog record-ritual --run "$RUN_M" --prompt "$TM" --when "every day" --schedule "daily 09:00" --step "read the board"
MISSED="$(jfield "$OUT" 'd["ritual"]')"
run_py "$RUN_M" "$MISSED" <<'EOF'
def mutate(rec):
    rec["programme"]["ritual_clock"][args[1]] = {"next_due_at": "2026-01-05T09:00:00Z"}
core._with_locked_run_record(ph.home_path(args[0]), args[0], mutate)
EOF
PM1="$(opick "$RUN_M" "start-ritual ${MISSED}")"
prog start-ritual "$MISSED" --prompt "$PM1" --run "$RUN_M"
GOT="$CODE"
PM2="$(opick "$RUN_M" "skip-ritual ${MISSED}")"
prog skip-ritual "$MISSED" --prompt "$PM2" --run "$RUN_M"
check "0 0" "$GOT $CODE"

it "older ritual rows with no wording, and rows with wording, both pass the closed key check"
check "ok ok" "$(run_py <<'EOF'
pr = load_lib_module("programme_rituals")
base = {"id": "wx", "state": "active", "layer": "programme", "when": {"text": "at start", "trigger": "start"},
        "steps": ["read the handover"]}
print(" ".join(pr.verdict(dict(base, source=source), allow_adoption=False).get("reason") or "ok"
               for source in ({"prompt_id": "p", "quote": "q"}, {"prompt_id": "p", "quote": "q", "wording": "pm_draft"})))
EOF
)"

it "keep-rituals --to repo stores the ritual under the one remit repo and it resolves at the repo layer"
mkdir -p "${WORK}/alpha" "${WORK}/beta"
run_py "$RUN8" <<'EOF'
def mutate(rec):
    rec["programme"]["remit"]["repos"] = [{"path": os.path.join(os.environ["WORK"], "alpha"), "github": "acme/alpha"}]
core._with_locked_run_record(ph.home_path(args[0]), args[0], mutate)
EOF
T4="$(tprompt "$RUN8" "keep ${PROP} for this repo")"
prog keep-rituals "$PROP" --to repo --prompt "$T4" --run "$RUN8"
check 0 "$CODE"
check "acme/alpha $PROP@repo" "$(q "$RUN8" "' '.join(pr.read_store()['repos']) + ' ' + ' '.join('%s@%s' % (r['id'], r['layer']) for r in pr.in_force(rec))")"

it "U5: a repo-layer ritual lives in the machine store file; nothing is written inside the repo directory"
check "0" "$(find "${WORK}/alpha" -type f | wc -l | tr -d ' ')"
check "${WORK}/stores/rituals.json" "$(run_py <<'EOF'
print(pr.store_path())
EOF
)"

it "keep-rituals --to repo with two remit repos and no --repo is refused, and a --repo outside the remit is refused"
prog record-ritual --run "$RUN8" --prompt "$T1" --when "at end" --trigger end --step "write the wrap-up"
SECOND="$(jfield "$OUT" 'd["ritual"]')"
run_py "$RUN8" <<'EOF'
def mutate(rec):
    rec["programme"]["remit"]["repos"].append({"path": os.path.join(os.environ["WORK"], "beta"), "github": "acme/beta"})
core._with_locked_run_record(ph.home_path(args[0]), args[0], mutate)
EOF
T5="$(tprompt "$RUN8" "keep ${SECOND} for this repo")"
prog keep-rituals "$SECOND" --to repo --prompt "$T5" --run "$RUN8"
check 1 "$CODE"
has "pass --repo" "$OUT"
prog keep-rituals "$SECOND" --to repo --repo acme/other --prompt "$T5" --run "$RUN8"
check 1 "$CODE"
has "not a remit repo" "$OUT"

it "a stored ritual whose steps were edited after approval is rejected on load and not in force"
T6="$(tprompt "$RUN8" "keep ${SECOND} for personal use everywhere")"
prog keep-rituals "$SECOND" --to personal --prompt "$T6" --run "$RUN8"
check 0 "$CODE"
"$PY" - "$CLAUDE_AUTO_RITUALS_STORE" <<'EOF'
import json, sys
doc = json.load(open(sys.argv[1]))
for entry in doc["personal"]:
    entry["steps"] = ["tampered step"]
json.dump(doc, open(sys.argv[1], "w"))
EOF
check "True True" "$(q "$RUN8" "str(any(r['id'] == '$SECOND' for r in pr.load_store()['rejected'])) + ' ' + str(not any('tampered step' in r['steps'] for r in pr.in_force(rec)))")"

it "an unreadable rituals store makes keep-rituals and move-ritual refuse and leaves the file alone"
printf '{ not json' > "$CLAUDE_AUTO_RITUALS_STORE"
RUN9="$(new_run)"
U1="$(tprompt "$RUN9" "record a start ritual")"
prog record-ritual --run "$RUN9" --prompt "$U1" --when "at start" --trigger start --step "read the handover"
UID1="$(jfield "$OUT" 'd["ritual"]')"
U2="$(tprompt "$RUN9" "keep ${UID1} for personal use everywhere")"
prog keep-rituals "$UID1" --to personal --prompt "$U2" --run "$RUN9"
check 1 "$CODE"
has "unreadable" "$OUT"
U3="$(tprompt "$RUN9" "move ${UID1} to personal use everywhere")"
prog move-ritual "$UID1" --to personal --prompt "$U3" --run "$RUN9"
check 1 "$CODE"
has "unreadable" "$OUT"
check "{ not json" "$(cat "$CLAUDE_AUTO_RITUALS_STORE")"
rm -f "$CLAUDE_AUTO_RITUALS_STORE"

# ---- ritual improvements: U1 refusal detail, U2 offers, U3 first-due report ----
RUN_I="$(new_run)"
PI="$(tprompt "$RUN_I" "record the version check ritual")"

it "U1: a refusal names the step number and the word that matched"
check "protected_escalation full_release: step 2" "$(run_py <<'EOF'
v = pr.verdict(ritual("r1", steps=["check every plugin version", "publish the plugin now"]))
print(v["reason"], v["detail"][:len("full_release: step 2")])
EOF
)"
has 'publish' "$(run_py <<'EOF'
print(pr.verdict(ritual("r1", steps=["check it", "publish the plugin now"]))["detail"])
EOF
)"

it "U1: record-ritual output names the step and tells the PM to reword, not to ask for an approval"
prog record-ritual --run "$RUN_I" --prompt "$PI" --when "daily check" --schedule "daily 09:00" --step "check versions" --step "publish the plugin"
check 1 "$CODE"
has "step 2" "$OUT"
has "reword" "$OUT"
case "$OUT" in *"type the approval"*) fail "fix still tells the PM to ask for a typed approval: $OUT" ;; *) pass ;; esac

it "U2: an offer line may name a protected action while the same text as a step is refused"
prog record-ritual --run "$RUN_I" --prompt "$PI" --when "daily check" --schedule "daily 09:00" --step "check versions" --offer "ask Shawn whether to publish the plugin now"
check 0 "$CODE"
OFFER_ID="$(jfield "$OUT" 'd["ritual"]')"
prog record-ritual --run "$RUN_I" --prompt "$PI" --when "daily check" --schedule "daily 09:00" --step "ask Shawn whether to publish the plugin now"
check 1 "$CODE"
has "protected_escalation" "$OUT"

it "U2: offers alone, without a step, are refused"
prog record-ritual --run "$RUN_I" --prompt "$PI" --when "daily check" --schedule "daily 09:00" --offer "ask whether to publish"
check 2 "$CODE"
has "at least one --step" "$OUT"

it "U2: the stored ritual keeps its offers and an offer never changes the step scan"
check "['ask Shawn whether to publish the plugin now']" "$(q "$RUN_I" "[e for e in prog['rituals'] if e['id'] == '$OFFER_ID'][0]['offers']")"
check "None" "$(run_py "$RUN_I" "$OFFER_ID" <<'EOF'
e = [e for e in record(args[0])["programme"]["rituals"] if e["id"] == args[1]][0]
print(pr.protected_kind(e))
EOF
)"

it "U2: a due row and the Programme view show the offer"
check "['ask Shawn whether to publish the plugin now']" "$(run_py <<'EOF'
e = ritual("r9", offers=["ask Shawn whether to publish the plugin now"])
run = setup([e], clock={"r9": {"next_due_at": "2026-11-02T09:00:00Z"}})
got = due.due(record(run), run, now=at("2026-11-02T09:30:00Z"), store={"personal": [], "repos": {}, "rejected": [], "notices": []}, rows=[])
print(got["due"][0]["offers"])
EOF
)"

it "U2: an offers value that is not a list of non-empty strings is rejected"
check "bad_value offers" "$(run_py <<'EOF'
v = pr.verdict(ritual("r1", offers=["ok", ""]))
print(v["reason"], v["detail"])
EOF
)"

it "U3: record-ritual reports the first due time and the clock it reads"
prog record-ritual --run "$RUN_I" --prompt "$PI" --when "daily check" --schedule "daily 09:00" --step "check versions"
check 0 "$CODE"
has "first_due_at" "$OUT"
has "clock" "$OUT"

it "U3: first due time is strictly after now for a slot already passed today"
check "2026-11-03T09:00:00Z" "$(run_py <<'EOF'
import time
os.environ["TZ"] = "UTC"; time.tzset()
print(iso(pr.next_after({"every": "day", "at": "09:00"}, at("2026-11-02T09:30:00Z"))))
EOF
)"

it "U3: --ran-now recorded before the slot moves the first due time to tomorrow"
prog record-ritual --run "$RUN_I" --prompt "$PI" --when "daily check" --schedule "daily 09:00" --step "check versions" --ran-now --outcome "all versions bumped"
check 0 "$CODE"
check "True" "$(jfield "$OUT" 'd["ran_now"]')"
check "True" "$(jfield "$OUT" 'd["first_due_at"] > __import__("datetime").datetime.now(__import__("datetime").timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")')"

it "U3: --ran-now on an event ritual is refused"
prog record-ritual --run "$RUN_I" --prompt "$PI" --when "at start" --trigger start --step "read the journal" --ran-now
check 1 "$CODE"
has "ran-now" "$OUT"

it "U4: the Programme view shows the next due time in local time with the zone, whatever the machine zone"
view_text() {
  run_py "$1" <<'EOF'
import time, datetime
from zoneinfo import ZoneInfo
zone = args[0]
os.environ["TZ"] = zone; time.tzset()
due_at = (datetime.datetime.now(UTC) + datetime.timedelta(days=3)).replace(second=0, microsecond=0)
e = ritual("r9", offers=["ask Shawn whether to publish the plugin now"])
run = setup([e], clock={"r9": {"next_due_at": iso(due_at)}})
pv = load_lib_module("programme_view")
text = pv._ritual_text(pv.rituals_view(record(run), [])[0])
local = due_at.astimezone(ZoneInfo(zone)).strftime("%Y-%m-%d %H:%M %Z")
print("next " + iso(due_at) + " = " + local + " machine local time" in text, "offers (ask Shawn, never act)" in text)
EOF
}
check "True True" "$(view_text UTC)"
check "True True" "$(view_text America/New_York)"
check "True True" "$(view_text Africa/Johannesburg)"

it "U4: daily 09:00 stays 09:00 local across spring-forward and fall-back"
check "2026-03-08T13:00:00Z 2026-11-01T14:00:00Z" "$(run_py <<'EOF'
import time
os.environ["TZ"] = "America/New_York"; time.tzset()
sched = {"every": "day", "at": "09:00"}
print(iso(pr.next_after(sched, at("2026-03-07T15:00:00Z"))), iso(pr.next_after(sched, at("2026-10-31T14:00:00Z"))))
EOF
)"

it "U3: the clock sentence names the zone"
has "machine local time (UTC)" "$(run_py <<'EOF'
import time
os.environ["TZ"] = "UTC"; time.tzset()
print(pr.describe_clock())
EOF
)"

it "review: --ran-now before today's slot skips that slot, and after it does not skip tomorrow's"
check "2026-11-03T09:00:00Z 2026-11-03T09:00:00Z" "$(run_py <<'EOF'
import time
os.environ["TZ"] = "UTC"; time.tzset()
daily = ritual("rd", when={"text": "daily", "trigger": "calendar", "schedule": {"every": "day", "at": "09:00"}})
def first(now_text):
    programme = {}
    pr.advance_clock(programme, daily, now=at(now_text), first_slot_done=True)
    return programme["ritual_clock"]["rd"]["next_due_at"]
print(first("2026-11-02T08:00:00Z"), first("2026-11-02T09:30:00Z"))
EOF
)"

it "review: the zone label belongs to the due time, not to today"
has "09:00 EDT" "$(run_py <<'EOF'
import time
os.environ["TZ"] = "America/New_York"; time.tzset()
print(pr.local_text(at("2026-07-01T13:00:00Z")))
EOF
)"

it "review: --outcome without --ran-now is refused instead of dropped"
prog record-ritual --run "$RUN_I" --prompt "$PI" --when "daily check" --schedule "daily 09:00" --step "check versions" --outcome "all bumped"
check 2 "$CODE"
has "--outcome" "$OUT"

it "review: --from-proposal accepts --ran-now, as the skill tells the PM"
prog propose-ritual --run "$RUN_I" --when "daily check" --schedule "daily 09:00" --step "check versions" --offer "ask whether to publish"
check 0 "$CODE"
has "ask whether to publish" "$OUT"
PROP_I="$(jfield "$OUT" 'd["ritual"]')"
PI2="$(opick "$RUN_I" "record-ritual --from-proposal ${PROP_I} --ran-now --outcome 'all bumped'")"
prog record-ritual --run "$RUN_I" --from-proposal "$PROP_I" --prompt "$PI2" --ran-now --outcome "all bumped"
check 0 "$CODE"
check "True" "$(jfield "$OUT" 'd["ran_now"]')"

it "review: start-ritual and a due row carry offers with the rule that they are questions"
has "never actions" "$(run_py <<'EOF'
e = ritual("r9", offers=["ask Shawn whether to publish the plugin now"])
run = setup([e], clock={"r9": {"next_due_at": "2026-11-02T09:00:00Z"}})
got = due.due(record(run), run, now=at("2026-11-02T09:30:00Z"), store={"personal": [], "repos": {}, "rejected": [], "notices": []}, rows=[])
print(got["due"][0]["offers_rule"])
EOF
)"

# ---- ritual checks: C1 the check field ----
def_check='{"name": "versions-bumped", "repo_key": "acme/alpha"}'
run_chk() {
  local extra="${2-}"; [ -n "$extra" ] || extra='{}'
  run_py "$1" "$extra" <<'EOF'
import json
c = json.loads(args[0]); extra = json.loads(args[1])
e = ritual("rc", **extra); e["check"] = c
v = pr.verdict(e)
print(v["reason"], v["detail"])
EOF
}

it "C1: a known check on a calendar programme-layer ritual with a remit repo is accepted"
check "None None" "$(run_chk "$def_check")"

it "C1: an unknown check name, an unknown key and a base with .. are refused"
check "bad_value check.name" "$(run_chk '{"name": "rm-everything", "repo_key": "acme/alpha"}')"
check "unknown_key" "$(run_chk '{"name": "versions-bumped", "repo_key": "acme/alpha", "cmd": "ls"}' | cut -d' ' -f1)"
check "bad_value check.base" "$(run_chk '{"name": "versions-bumped", "repo_key": "acme/alpha", "base": "a..b"}')"
check "bad_value check.base" "$(run_chk '{"name": "versions-bumped", "repo_key": "acme/alpha", "base": "--upload-pack=x"}')"

it "C1: a check on the personal layer, or on an event ritual, is refused"
check "bad_value check.layer" "$(run_chk "$def_check" '{"layer": "personal"}')"
check "bad_value check.trigger" "$(run_chk "$def_check" '{"when": {"text": "at start", "trigger": "start"}}')"

it "C1: a programme-layer check must carry a repo key, and a repo-layer check must not"
check "missing_field check.repo_key" "$(run_chk '{"name": "versions-bumped"}')"
check "bad_value check.repo_key" "$(run_chk "$def_check" '{"layer": "repo"}')"
check "None None" "$(run_chk '{"name": "versions-bumped"}' '{"layer": "repo"}')"

it "C1: a hand-edited store entry with a bad check is rejected at load"
check "check.layer" "$(run_py <<'EOF'
store = os.environ["CLAUDE_AUTO_RITUALS_STORE"]
os.makedirs(os.path.dirname(store), exist_ok=True)
e = ritual("rbad", layer="personal"); e["check"] = {"name": "versions-bumped"}
json.dump({"format": 1, "personal": [e], "repos": {}}, open(store, "w"))
print(pr.load_store()["rejected"][0]["detail"] if pr.load_store()["rejected"] else "none rejected")
EOF
)"
rm -f "$CLAUDE_AUTO_RITUALS_STORE"

RUN_C="$(new_run)"
run_py "$RUN_C" <<'EOF'
def mutate(rec):
    rec["programme"]["remit"]["repos"] = [{"path": os.path.join(os.environ["WORK"], "alpha"), "github": "acme/alpha"}]
core._with_locked_run_record(ph.home_path(args[0]), args[0], mutate)
EOF
PC="$(tprompt "$RUN_C" "record the versions bumped check")"
PCX="$(tprompt "$RUN_C" "record the weekly report")"

it "C1: record-ritual --check shows the check in its offer, typed words with no offer must name it, and the repo defaults from a one-repo remit"
prog record-ritual --run "$RUN_C" --prompt "$PCX" --when "daily" --schedule "daily 09:00" --step "check versions" --check versions-bumped
check 1 "$CODE"
has "versions bumped" "$OUT"
has "Check: versions-bumped" "$("$PY" "$PROG" offer ritual-check --command "record-ritual --when 'daily, shown' --schedule 'daily 09:00' --step 'check versions' --check versions-bumped" --run "$RUN_C" 2>&1)"
prog record-ritual --run "$RUN_C" --prompt "$PC" --when "daily" --schedule "daily 09:00" --step "check versions" --check versions-bumped
check 0 "$CODE"
CK="$(jfield "$OUT" 'd["ritual"]')"
check "{'name': 'versions-bumped', 'repo_key': 'acme/alpha'}" "$(q "$RUN_C" "[e for e in prog['rituals'] if e['id'] == '$CK'][0]['check']")"

it "C1: --check-base .. is refused and a missing remit repo is a clear refusal"
prog record-ritual --run "$RUN_C" --prompt "$PC" --when "daily" --schedule "daily 09:00" --step "check versions" --check versions-bumped --check-base "a..b"
check 1 "$CODE"
RUN_C0="$(new_run)"
PC0="$(tprompt "$RUN_C0" "record the versions bumped check")"
prog record-ritual --run "$RUN_C0" --prompt "$PC0" --when "daily" --schedule "daily 09:00" --step "check versions" --check versions-bumped
check 1 "$CODE"
has "--check-repo" "$OUT"

it "C1: propose-ritual --check stores a proposal without a prompt"
prog propose-ritual --run "$RUN_C" --when "daily" --schedule "daily 09:00" --step "check versions" --check versions-bumped
check 0 "$CODE"
check "proposed" "$(jfield "$OUT" 'd["state"]')"

it "C1: move-ritual and keep-rituals refuse a ritual that carries a check"
PM1="$(tprompt "$RUN_C" "move ${CK} to personal use everywhere")"
prog move-ritual "$CK" --to personal --prompt "$PM1" --run "$RUN_C"
check 1 "$CODE"
has "check" "$OUT"

# ---- ritual checks: C3 the run-ritual-checks verb ----
mkrepo() {
  local d="${WORK}/$1"
  mkdir -p "$d/plugins/foo/.claude-plugin" "$d/plugins/foo/lib" "$d/.claude-plugin"
  git -C "$d" init -q -b main
  printf '{"name": "foo", "version": "1.0.0"}' > "$d/plugins/foo/.claude-plugin/plugin.json"
  printf '{"plugins": [{"name": "foo", "version": "1.0.0", "source": "./plugins/foo"}]}' > "$d/.claude-plugin/marketplace.json"
  printf 'x = 1\n' > "$d/plugins/foo/lib/code.py"
  git -C "$d" add -A
  git -C "$d" -c user.name=t -c user.email=t@t commit -q -m initial
  if [ "${2:-ok}" = "unbumped" ]; then
    printf 'x = 2\n' > "$d/plugins/foo/lib/code.py"
    git -C "$d" -c user.name=t -c user.email=t@t commit -q -am "change code, no bump"
  fi
}
check_run() {
  run_py "$1" "$2" "$3" "$4" <<'EOF'
run_name, repo_dir, minutes_ago, key = args[0], args[1], int(args[2]), args[3]
entry = ritual("rchk", check={"name": "versions-bumped", "repo_key": key, "base": "main"})
due_at = datetime.datetime.now(UTC) - datetime.timedelta(minutes=minutes_ago)
run = setup([entry], clock={"rchk": {"next_due_at": iso(due_at)}})
def mutate(rec):
    rec["programme"]["remit"]["repos"] = [{"path": repo_dir, "github": "acme/gamma"}]
core._with_locked_run_record(ph.home_path(run), run, mutate)
print(run)
EOF
}

mkrepo good ok
mkrepo bad unbumped

it "C3: a due ritual whose check passes is answered without the PM: clock moves, one row, counts recorded"
RUNP="$(check_run x "${WORK}/good" 5 acme/gamma)"
prog run-ritual-checks --run "$RUNP"
check 0 "$CODE"
check "1 pass 1" "$(q "$RUNP" "' '.join([str(count('ritual_checked')), [r for r in pj.read(run) if r['kind']=='ritual_checked'][0]['payload']['result'], str([r for r in pj.read(run) if r['kind']=='ritual_checked'][0]['payload']['checked'])])")"
check "[]" "$(run_py "$RUNP" <<'EOF'
rec = record(args[0])
print([r["ritual"] for r in due.due(rec, args[0])["due"]])
EOF
)"

it "C3: a failing check leaves the ritual due with the result in its row, and does not run again for the same slot"
RUNF="$(check_run x "${WORK}/bad" 5 acme/gamma)"
prog run-ritual-checks --run "$RUNF"
check 0 "$CODE"
prog run-ritual-checks --run "$RUNF"
check "1" "$(q "$RUNF" "count('ritual_checked')")"
check "rchk fail foo" "$(run_py "$RUNF" <<'EOF'
rec = record(args[0])
row = due.due(rec, args[0])["due"][0]
print(row["ritual"], row["check"]["result"], row["check"]["failed"][0]["plugin"])
EOF
)"

it "C3: --ritual re-runs a check that already ran for the slot"
prog run-ritual-checks --run "$RUNF" --ritual rchk
check "2" "$(q "$RUNF" "count('ritual_checked')")"

it "C3: a check whose repo is not in the remit is an error row and the ritual stays due"
RUNE="$(check_run x "${WORK}/good" 5 acme/elsewhere)"
prog run-ritual-checks --run "$RUNE"
check "error repo_not_in_remit" "$(q "$RUNE" "' '.join([[r for r in pj.read(run) if r['kind']=='ritual_checked'][0]['payload'][k] for k in ('result','reason')])")"

it "C3: a missed slot is checked too, and a pass moves the clock and marks it late"
RUNM="$(check_run x "${WORK}/good" 300 acme/gamma)"
prog run-ritual-checks --run "$RUNM"
check "pass True" "$(q "$RUNM" "' '.join([[r for r in pj.read(run) if r['kind']=='ritual_checked'][0]['payload']['result'], str([r for r in pj.read(run) if r['kind']=='ritual_checked'][0]['payload']['late'])])")"

it "C3: a session that is not the driver writes nothing and the ritual stays due"
RUNN="$(check_run x "${WORK}/good" 5 acme/gamma)"
CLAUDE_CODE_SESSION_ID=sess-other prog run-ritual-checks --run "$RUNN"
check 0 "$CODE"
has '"not_recorded": ["rchk"]' "$OUT"
check "0" "$(q "$RUNN" "count('ritual_checked')")"

it "C3: a pass row is quiet bookkeeping for the sweep and a fail row is not"
check "True False" "$(run_py <<'EOF'
psi = load_lib_module("programme_sweep_inputs")
print(psi._quiet_row({"kind": "ritual_checked", "payload": {"result": "pass"}}),
      psi._quiet_row({"kind": "ritual_checked", "payload": {"result": "fail"}}))
EOF
)"

it "C3: a ritual with no check is never run by the verb"
RUNQ="$(run_py <<'EOF'
print(setup([ritual("rplain")], clock={"rplain": {"next_due_at": iso(datetime.datetime.now(UTC) - datetime.timedelta(minutes=5))}}))
EOF
)"
prog run-ritual-checks --run "$RUNQ"
check 0 "$CODE"
has '"ran": 0' "$OUT"
check "0" "$(q "$RUNQ" "count('ritual_checked')")"

it "C4: the Programme view shows the last check result, the failed plugins and the age of the clone"
has "check versions-bumped: fail (shipped_changed), failed: foo" "$(run_py "$RUNF" <<'EOF'
pv = load_lib_module("programme_view")
rec = record(args[0])
rows = pv.rituals_view(rec, pj.read(args[0]))
print(pv._ritual_text(rows[0]))
EOF
)"

echo
echo "${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
