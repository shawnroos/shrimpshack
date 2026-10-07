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

echo "programme-predicate.test.sh"

WORK="$(mktemp -d -t auto-programme-predicate.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_TEST_HARNESS=1

scenario() {
  "$PY" - "$AUTO_ROOT" <<PYEOF 2>&1
import datetime, json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
ph = load_lib_module("programme_home")
pp = load_lib_module("programme_predicate")
NOW = datetime.datetime(2026, 10, 6, 12, 0, tzinfo=datetime.timezone.utc)

def at(minutes):
    return (NOW + datetime.timedelta(minutes=minutes)).strftime("%Y-%m-%dT%H:%M:%SZ")

def ago(minutes):
    return at(-minutes)

def item(item_id, state="open", rule="code_fix", pane="w2/p3", joined=595, **extra):
    out = ph.new_item(item_id, item_id, state=state, now_iso=ago(joined))
    out["matched_rule"] = rule
    out["owner"]["pane"] = pane
    out["deliverables"] = {"merged": {"result": "unknown"}, "recorded": {"result": "unknown"}}
    out.update(extra)
    return out

def done(item_id, **extra):
    out = item(item_id, state="done", **extra)
    out["deliverables"] = {"merged": {"result": "confirmed"}, "recorded": {"result": "confirmed"}}
    return out

def waiting(item_id, **waiting_on):
    out = item(item_id, state="waiting")
    out["waiting_on"] = dict({"who": "team:infra", "watcher": None, "reporter": None}, **waiting_on)
    return out

def record(*items, stop_rule=None, until=None, watchers=None, queue=None, offset=0,
           sources=None, proposed=None, phase="work"):
    block = ph.new_programme_block([("default", "w2")], ago(600))
    block["agreement"]["accepted"] = {"at": ago(590), "prompt_id": "p1"}
    if stop_rule:
        block["agreement"]["terms"]["stop_rule"]["value"] = stop_rule
        block["agreement"]["terms"]["stop_rule"]["until"] = until
    for it in items:
        block["items"][it["id"]] = it
    block["watchers"] = watchers or {}
    block["working_model"]["queue"] = queue or []
    block["inbox_offset"] = offset
    if sources is not None:
        block["sources"] = sources
    if proposed is not None:
        block["proposed_rules"] = proposed
    rec = {"run_id": "prog-1", "run_kind": "programme", "programme_format": 1,
           "programme": block, "steps": []}
    rec["loop" + "_phase"] = phase
    return rec

def live(beat_minutes=5, **extra):
    return dict({"process_id": 4242, "last_beat_at": ago(beat_minutes)}, **extra)

def show(rec, inbox=None, when=NOW):
    out = pp.compute(rec, when, inbox)
    kinds = sorted("%s:%s" % (r["kind"], r.get("item") or r.get("system") or "-")
                   for r in out["reasons"])
    print("may_stop=%s done=%s reasons=%s" % (out["may_stop"], out["done"], ",".join(kinds)))
    return out

$(cat)
PYEOF
}

it "AE1: done, handed and watched waits may stop with no reasons"
OUT="$(scenario <<'EOF'
show(record(done("linear:AI-1"), item("linear:AI-2", state="handed"),
            waiting("linear:AI-3", watcher="w1"), watchers={"w1": live()}))
EOF
)"
check "may_stop=True done=False reasons=" "$OUT"

it "AE2: a wait on another team with no watcher and no reporter refuses the stop"
OUT="$(scenario <<'EOF'
out = show(record(done("linear:AI-1"), waiting("linear:AI-3")))
print(out["unwatched_waits"])
EOF
)"
check "may_stop=False done=False reasons=unwatched_wait:linear:AI-3
['linear:AI-3']" "$OUT"

it "a named reporter makes the wait watched"
OUT="$(scenario <<'EOF'
show(record(waiting("linear:AI-3", reporter="dana")))
EOF
)"
check "may_stop=True done=False reasons=" "$OUT"

it "a watcher heartbeat 61 minutes old under an hourly cadence is an unwatched wait"
OUT="$(scenario <<'EOF'
show(record(waiting("linear:AI-3", watcher="w1"), watchers={"w1": live(61)}))
EOF
)"
check "may_stop=False done=False reasons=unwatched_wait:linear:AI-3" "$OUT"

it "a watcher with no process or task id is no watcher"
OUT="$(scenario <<'EOF'
show(record(waiting("linear:AI-3", watcher="w1"), watchers={"w1": {"last_beat_at": ago(1)}}))
EOF
)"
check "may_stop=False done=False reasons=unwatched_wait:linear:AI-3" "$OUT"

it "a watcher that names the item by its item field counts"
OUT="$(scenario <<'EOF'
show(record(waiting("linear:AI-3"), watchers={"w9": live(item="linear:AI-3", task_id="t1")}))
EOF
)"
check "may_stop=True done=False reasons=" "$OUT"

it "a waiting item whose worker pane closed, with a live watcher, may stop"
OUT="$(scenario <<'EOF'
it = waiting("linear:AI-3", watcher="w1")
it["owner"]["pane"] = None
show(record(it, watchers={"w1": live()}))
EOF
)"
check "may_stop=True done=False reasons=" "$OUT"

it "an open item waiting on a blocker with no trace id is an undebugged blocker"
OUT="$(scenario <<'EOF'
it = item("linear:AI-4")
it["waiting_on"] = {"who": "team:infra", "kind": "blocker", "trace_id": None}
show(record(it))
EOF
)"
check "may_stop=False done=False reasons=open_item:linear:AI-4,undebugged_blocker:linear:AI-4" "$OUT"

it "a waiting blocker with a recorded trace id and a live watcher may stop"
OUT="$(scenario <<'EOF'
show(record(waiting("linear:AI-4", kind="blocker", trace_id="tr-9", watcher="w1"),
            watchers={"w1": live()}))
EOF
)"
check "may_stop=True done=False reasons=" "$OUT"

it "an item no rule matches and no rule proposed: no_rule_proposed, done false"
OUT="$(scenario <<'EOF'
show(record(item("herdr:w2/p7", rule=None)))
EOF
)"
check "may_stop=False done=False reasons=no_rule_proposed:herdr:w2/p7,open_item:herdr:w2/p7" "$OUT"

it "the same item after a rule is proposed, waiting on Shawn, may stop"
OUT="$(scenario <<'EOF'
it = waiting("herdr:w2/p7", who="shawn", reporter="shawn")
it["matched_rule"] = None
show(record(it, proposed=[{"id": "infra-only", "items": ["herdr:w2/p7"]}]))
EOF
)"
check "may_stop=True done=False reasons=" "$OUT"

it "an open item with no owner pane and no queued worker start"
OUT="$(scenario <<'EOF'
show(record(item("linear:AI-5", pane=None)))
EOF
)"
check "may_stop=False done=False reasons=open_item:linear:AI-5,ownerless_item:linear:AI-5" "$OUT"

it "a queued worker start clears the ownerless entry but the queue itself refuses the stop"
OUT="$(scenario <<'EOF'
show(record(item("linear:AI-5", pane=None),
            queue=[{"action": "start_worker", "item": "linear:AI-5"}]))
EOF
)"
check "may_stop=False done=False reasons=open_item:linear:AI-5,queued_action:-" "$OUT"

it "an open item with an owner pane still refuses the stop"
OUT="$(scenario <<'EOF'
show(record(item("linear:AI-6")))
EOF
)"
check "may_stop=False done=False reasons=open_item:linear:AI-6" "$OUT"

it "inbox size above the read offset is an unread claim"
OUT="$(scenario <<'EOF'
show(record(done("linear:AI-1"), offset=2), inbox=3)
show(record(done("linear:AI-1"), offset=3), inbox=3)
show(record(done("linear:AI-1"), offset=2), inbox=None)
EOF
)"
check "may_stop=False done=True reasons=unread_claim:-
may_stop=True done=True reasons=
may_stop=True done=True reasons=" "$OUT"

it "a source unavailable 20 minutes refuses; 3 hours becomes a wait on the system"
OUT="$(scenario <<'EOF'
show(record(done("linear:AI-1"), sources={"linear": {"unavailable_since": ago(20)}}))
out = show(record(done("linear:AI-1"), sources={"linear": {"unavailable_since": ago(180)}}))
print([w.get("system") for w in out["waits"]])
show(record(done("linear:AI-1"), sources={"linear": {"unavailable_since": None}}))
EOF
)"
check "may_stop=False done=True reasons=source_unavailable:linear
may_stop=True done=True reasons=
['linear']
may_stop=True done=True reasons=" "$OUT"

it "only when done: one open item refuses, all finished allows"
OUT="$(scenario <<'EOF'
show(record(done("linear:AI-1"), waiting("linear:AI-3", reporter="dana"), stop_rule="only_when_done"))
show(record(done("linear:AI-1"), item("linear:AI-2", state="dropped"), stop_rule="only_when_done"))
EOF
)"
check "may_stop=False done=False reasons=not_done:-
may_stop=True done=True reasons=" "$OUT"

it "until a set time: refused at 17:59, the default applies at 18:01"
OUT="$(scenario <<'EOF'
until = "2026-10-06T18:00:00Z"
rec = record(done("linear:AI-1"), stop_rule="until_time", until=until)
show(rec, when=NOW.replace(hour=17, minute=59))
show(rec, when=NOW.replace(hour=18, minute=1))
rec2 = record(done("linear:AI-1"), waiting("linear:AI-3"), stop_rule="until_time", until=until)
show(rec2, when=NOW.replace(hour=18, minute=1))
EOF
)"
check "may_stop=False done=True reasons=until_time:-
may_stop=True done=True reasons=
may_stop=False done=False reasons=unwatched_wait:linear:AI-3" "$OUT"

it "until a set time with no time set falls back to the default"
OUT="$(scenario <<'EOF'
show(record(done("linear:AI-1"), stop_rule="until_time", until=None))
EOF
)"
check "may_stop=True done=True reasons=" "$OUT"

it "never stop always refuses"
OUT="$(scenario <<'EOF'
show(record(done("linear:AI-1"), stop_rule="never_stop"))
show(record(stop_rule="never_stop"))
EOF
)"
check "may_stop=False done=True reasons=never_stop:-
may_stop=False done=True reasons=never_stop:-" "$OUT"

it "a herdr item still open keeps done false"
OUT="$(scenario <<'EOF'
show(record(done("linear:AI-1"), item("herdr:w2/p26")))
EOF
)"
check "may_stop=False done=False reasons=open_item:herdr:w2/p26" "$OUT"

it "a stored done without confirmed evidence is not done"
OUT="$(scenario <<'EOF'
it = done("linear:AI-1")
it["deliverables"]["recorded"] = {"result": "refuted"}
show(record(it))
it2 = done("linear:AI-2", rule=None)
show(record(it2))
EOF
)"
check "may_stop=False done=False reasons=unproven_done:linear:AI-1
may_stop=False done=False reasons=no_rule_proposed:linear:AI-2,unproven_done:linear:AI-2" "$OUT"

it "confirmed evidence on every deliverable makes an item done whatever its stored state"
OUT="$(scenario <<'EOF'
it = done("linear:AI-1")
it["state"] = "open"
out = show(record(it))
print(out["items"]["finished"])
EOF
)"
check "may_stop=True done=True reasons=
1" "$OUT"

it "done flips to false when a new item joins, and the item is marked new"
OUT="$(scenario <<'EOF'
rec = record(done("linear:AI-1"))
print(pp.compute(rec, NOW, None)["done"])
rec["programme"]["items"]["linear:AI-9"] = item("linear:AI-9", joined=5)
out = show(rec)
print(out["new_items"])
EOF
)"
check "True
may_stop=False done=False reasons=open_item:linear:AI-9
['linear:AI-9']" "$OUT"

it "an ended programme may stop"
OUT="$(scenario <<'EOF'
show(record(item("linear:AI-6"), stop_rule="never_stop", phase="done"))
EOF
)"
check "may_stop=True done=False reasons=" "$OUT"

it "an empty programme is done and may stop under the default"
OUT="$(scenario <<'EOF'
show(record())
EOF
)"
check "may_stop=True done=True reasons=" "$OUT"

it "a corrupt programme block refuses the stop instead of raising"
OUT="$(scenario <<'EOF'
show({"run_kind": "programme", "programme": "garbage"})
show({"run_kind": "programme", "programme": {"items": {"linear:AI-1": "bad"}}})
show({"run_kind": "programme", "programme": {"items": []}})
show({"run_kind": "programme", "programme": {}})
out = show(record(done("linear:AI-1"), offset="x"), inbox="junk")
print(out["inbox_checked"])
EOF
)"
check "may_stop=False done=False reasons=corrupt_record:-
may_stop=False done=False reasons=corrupt_record:linear:AI-1
may_stop=False done=False reasons=corrupt_record:-
may_stop=False done=False reasons=corrupt_record:-
may_stop=True done=True reasons=
False" "$OUT"

mutant() {
  local switch="$1"
  shift
  ( export "$switch=1"; scenario )
}

it "each switch flips its conjunct"
OUT="$(cat <<'EOF' | mutant CLAUDE_AUTO_TEST_NO_UNWATCHED_WAIT
show(record(waiting("linear:AI-3")))
EOF
)
$(cat <<'EOF' | mutant CLAUDE_AUTO_TEST_NO_WATCHER_STALENESS
show(record(waiting("linear:AI-3", watcher="w1"), watchers={"w1": live(61)}))
EOF
)
$(cat <<'EOF' | mutant CLAUDE_AUTO_TEST_NO_UNDEBUGGED_BLOCKER
show(record(waiting("linear:AI-4", kind="blocker", reporter="dana")))
EOF
)
$(cat <<'EOF' | mutant CLAUDE_AUTO_TEST_NO_RULE_CHECK
it = waiting("herdr:w2/p7", reporter="dana")
it["matched_rule"] = None
show(record(it))
EOF
)
$(cat <<'EOF' | mutant CLAUDE_AUTO_TEST_NO_UNREAD_CLAIM
show(record(offset=1), inbox=4)
EOF
)
$(cat <<'EOF' | mutant CLAUDE_AUTO_TEST_NO_SOURCE_OUTAGE
show(record(sources={"herdr": {"unavailable_since": ago(20)}}))
EOF
)
$(cat <<'EOF' | mutant CLAUDE_AUTO_TEST_NO_OPEN_ITEM
show(record(item("linear:AI-6")))
EOF
)
$(cat <<'EOF' | mutant CLAUDE_AUTO_TEST_NO_QUEUED_ACTION
show(record(queue=[{"action": "sweep"}]))
EOF
)
$(cat <<'EOF' | mutant CLAUDE_AUTO_TEST_NO_ONLY_WHEN_DONE
show(record(waiting("linear:AI-3", reporter="dana"), stop_rule="only_when_done"))
EOF
)
$(cat <<'EOF' | mutant CLAUDE_AUTO_TEST_NO_UNTIL_TIME
show(record(stop_rule="until_time", until="2026-10-06T18:00:00Z"))
EOF
)
$(cat <<'EOF' | mutant CLAUDE_AUTO_TEST_NO_NEVER_STOP
show(record(stop_rule="never_stop"))
EOF
)
$(cat <<'EOF' | mutant CLAUDE_AUTO_TEST_NO_DONE_CHECK
show(record(item("linear:AI-6"), stop_rule="only_when_done"))
EOF
)
$(cat <<'EOF' | mutant CLAUDE_AUTO_TEST_NO_EVIDENCE_CHECK
it = done("linear:AI-1")
it["deliverables"]["recorded"] = {"result": "refuted"}
show(record(it))
EOF
)"
check "may_stop=True done=False reasons=
may_stop=True done=False reasons=
may_stop=True done=False reasons=
may_stop=True done=False reasons=
may_stop=True done=True reasons=
may_stop=True done=True reasons=
may_stop=True done=False reasons=
may_stop=True done=True reasons=
may_stop=True done=False reasons=
may_stop=True done=True reasons=
may_stop=True done=True reasons=
may_stop=True done=True reasons=
may_stop=True done=True reasons=" "$OUT"

it "an ownerless open item still refuses with the open-item switch, and clears with both"
OUT="$(export CLAUDE_AUTO_TEST_NO_OPEN_ITEM=1; scenario <<'EOF'
show(record(item("linear:AI-5", pane=None)))
EOF
)
$(export CLAUDE_AUTO_TEST_NO_OPEN_ITEM=1 CLAUDE_AUTO_TEST_NO_OWNERLESS_ITEM=1; scenario <<'EOF'
show(record(item("linear:AI-5", pane=None)))
EOF
)"
check "may_stop=False done=False reasons=ownerless_item:linear:AI-5
may_stop=True done=False reasons=" "$OUT"

it "a switch is inert without the test harness flag"
OUT="$(unset CLAUDE_AUTO_TEST_HARNESS; mutant CLAUDE_AUTO_TEST_NO_NEVER_STOP <<'EOF'
show(record(stop_rule="never_stop"))
EOF
)"
check "may_stop=False done=True reasons=never_stop:-" "$OUT"

it "a written programme record stores programme_status and carries no met"
OUT="$(scenario <<'EOF'
core = load_lib_module("run_record_core")
made = ph.create_programme(["w2"], "sess-1")
home, run = made["home"], made["run"]
def add(rec):
    rec["programme"]["items"]["linear:AI-1"] = item("linear:AI-1")
core._with_locked_run_record(home, run, add)
with open(core.run_record_path(home, run)) as fh:
    stored = json.load(fh)
status = stored.get("programme_status") or {}
print("exit_predicate_result" in stored, "met" in status,
      status.get("done"), status.get("may_stop"), [r["kind"] for r in status.get("reasons", [])])
rr = load_lib_module("run_record_predicate")
print(sorted(rr.recompute_predicate(stored)) == sorted(status))
EOF
)"
check "False False False False ['open_item']
True" "$OUT"

it "a task record keeps the old predicate unchanged"
OUT="$(scenario <<'EOF'
core = load_lib_module("run_record_core")
repo = os.path.join(os.environ["CLAUDE_AUTO_DATA_DIR"], "task-repo")
os.makedirs(repo, exist_ok=True)
core.init_run_record(repo, "task-1", backend="native", steps=[{"id": "a"}])
with open(core.run_record_path(repo, "task-1")) as fh:
    stored = json.load(fh)
print("programme_status" in stored, sorted(stored["exit_predicate_result"]))
EOF
)"
check "False ['all_steps_terminal', 'all_steps_terminal_global', 'blockers', 'gaps_open', 'iteration_pending', 'majors', 'met', 'minors']" "$OUT"

echo
echo "programme-predicate.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
