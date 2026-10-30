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

echo "programme-behaviours-due.test.sh"

WORK="$(mktemp -d -t auto-behaviours-due.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_CARRYOVER_STORE="${WORK}/personal/carryover.json"
export CLAUDE_AUTO_MACHINE="studio"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_CODE_SESSION_ID="sess-pm"
export CLAUDE_AUTO_BEHAVIOURS_STORE="${WORK}/behaviours.json"
unset HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_BIN_PATH CLAUDE_AUTO_REPO 2>/dev/null || true
: > "$CLAUDE_AUTO_SECRETS_FILE"
export WORK

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
ph = load_lib_module("programme_home")
pj = load_lib_module("programme_journal")
core = load_lib_module("run_record_core")
bd = load_lib_module("programme_behaviours_due")
BEFORE, TRIGGER, AFTER = "2026-10-30T09:00:00Z", "2026-10-30T10:00:00Z", "2026-10-30T11:00:00Z"
def beh(bid, trigger=None, checks=(("the item is a bug", "pm"),), at=BEFORE, **kw):
    when = {"text": "when the work is a bug", "checks": [{"text": t, "by": by} for t, by in checks]}
    if trigger:
        when["trigger"] = trigger
    entry = {"id": bid, "layer": "programme", "applies_to": "both", "state": "active", "at": at,
             "when": when, "do": ["reproduce it first"]}
    entry.update(kw)
    return entry
def setup(behaviours, **items):
    counter = os.path.join(os.environ["WORK"], "spaces")
    n = int(open(counter).read()) + 1 if os.path.exists(counter) else 1
    open(counter, "w").write(str(n))
    run = ph.create_programme(["w%d" % n], "sess-pm")["run"]
    claims = []
    def mutate(rec):
        prog = rec["programme"]
        prog["behaviours"] = behaviours
        prog["items"] = {}
        for key, spec in items.items():
            item = ph.new_item("test:" + key, key, state=spec.get("state", "open"))
            if spec.get("claim"):
                claims.append({"kind": "claim", "at": spec["claim"], "payload": {"item": "test:" + key}})
            if spec.get("merged"):
                item["deliverables"] = {"merged": {"result": "confirmed", "confirmed_at": spec["merged"]}}
                item["matched_rule"] = "r1"
            if spec.get("started"):
                item["history"].append({"kind": "started", "at": spec["started"]})
            if spec.get("waiting"):
                item["history"].append({"kind": "waiting", "at": spec["waiting"]})
            item["behaviour_deliveries"] = [dict({"id": d[0], "reason": d[1], "at": AFTER, "via": "test"},
                                                 **({"trigger": d[2]} if len(d) > 2 else {}))
                                            for d in spec.get("deliveries", [])]
            prog["items"]["test:" + key] = item
    core._with_locked_run_record(ph.home_path(run), run, mutate)
    for row in claims:
        pj.append_row(run, row, channel="claims")
    return run
def due(run, **kw):
    rec = core.read_run_record(ph.home_path(run), run)
    return bd.due(rec, run, **kw)
def line(row):
    return "%s/%s/%s/%s" % (row["item"], row["behaviour"], row["trigger"], row["mark"])
def lines(run, **kw):
    return " ".join(line(r) for r in due(run, **kw)["rows"])
$(cat)
PYEOF
}

it "AE1: a merge behaviour is due for an item whose PR merged after the behaviour was recorded"
check "test:a/b1/merge/None" "$(run_py <<'EOF'
run = setup([beh("b1", "merge")], a={"merged": TRIGGER})
print(lines(run))
EOF
)"

it "AE1: after a relevant delivery the behaviour is not listed again"
check "" "$(run_py <<'EOF'
run = setup([beh("b1", "merge")], a={"merged": TRIGGER, "deliveries": [("b1", "relevant", "merge")]})
print(lines(run))
EOF
)"

it "R4: skipped and applied_by_pm deliveries each answer a behaviour"
check "|" "$(run_py <<'EOF'
run = setup([beh("b1", "merge")], a={"merged": TRIGGER, "deliveries": [("b1", "skipped")]})
run2 = setup([beh("b1", "merge")], a={"merged": TRIGGER, "deliveries": [("b1", "applied_by_pm")]})
print(lines(run) + "|" + lines(run2))
EOF
)"

it "AE2: a behaviour with no trigger is due at a claim"
check "test:a/b1/claim/None" "$(run_py <<'EOF'
run = setup([beh("b1")], a={"claim": TRIGGER})
print(lines(run))
EOF
)"

it "a reminder sent for another trigger does not answer this one; one sent for it does; a skip answers any"
check "test:a/b1/merge/None||" "$(run_py <<'EOF'
d = lambda *x: {"merged": TRIGGER, "deliveries": [x]}
wrong = setup([beh("b1", "merge")], a=d("b1", "relevant", "claim"))
right = setup([beh("b1", "merge")], a=d("b1", "relevant", "merge"))
skip = setup([beh("b1", "merge")], a=d("b1", "skipped", "claim"))
print(lines(wrong) + "|" + lines(right) + "|" + lines(skip))
EOF
)"

it "a delivery recorded before triggers were stored counts as a claim reminder"
check "|test:a/b1/merge/None" "$(run_py <<'EOF'
legacy = setup([beh("b1")], a={"claim": TRIGGER, "deliveries": [("b1", "relevant")]})
merge = setup([beh("b1", "merge")], a={"merged": TRIGGER, "deliveries": [("b1", "relevant")]})
print(lines(legacy) + "|" + lines(merge))
EOF
)"

it "an item whose trigger has not passed lists nothing"
check "" "$(run_py <<'EOF'
run = setup([beh("b1", "merge"), beh("b2", "block"), beh("b3", "start")], a={"claim": TRIGGER})
print(lines(run))
EOF
)"

it "a trigger that passed before the behaviour was recorded lists nothing"
check "" "$(run_py <<'EOF'
run = setup([beh("b1", "claim", at=AFTER)], a={"claim": TRIGGER})
print(lines(run))
EOF
)"

it "AE3: an agent-check-only behaviour is marked judge and a PM-only one with a trigger pm_applies"
check "test:a/b1/claim/judge test:a/b2/claim/pm_applies" "$(run_py <<'EOF'
run = setup([beh("b1", checks=(("the work is done", "agent"),)), beh("b2", "claim", applies_to="pm")], a={"claim": TRIGGER})
print(lines(run))
EOF
)"

it "a PM-only behaviour with no trigger is never due: it has no item moment, so it stays out of the list"
check "" "$(run_py <<'EOF'
run = setup([beh("b1", applies_to="pm")], a={"claim": TRIGGER, "merged": TRIGGER}, b={"claim": TRIGGER})
print(lines(run))
EOF
)"

it "a handed, dropped or decided item is never due"
check "" "$(run_py <<'EOF'
run = setup([beh("b1")], a={"claim": TRIGGER, "state": "handed"}, b={"claim": TRIGGER, "state": "dropped"},
            c={"claim": TRIGGER, "state": "decided"})
print(lines(run))
EOF
)"

it "a single-deliverable item that became done at the merge still lists its merge behaviour"
check "done test:a/b1/merge/None" "$(run_py <<'EOF'
run = setup([beh("b1", "merge")], a={"merged": TRIGGER})
rec = core.read_run_record(ph.home_path(run), run)
pp = load_lib_module("programme_predicate")
print(pp.effective_state(rec["programme"]["items"]["test:a"]), lines(run))
EOF
)"

it "a start behaviour counts a brief delivery as answered; a claim behaviour does not"
check "test:a/b2/claim/None" "$(run_py <<'EOF'
run = setup([beh("b1", "start"), beh("b2", "claim")],
            a={"started": TRIGGER, "claim": TRIGGER, "deliveries": [("b1", "brief"), ("b2", "brief")]})
print(lines(run))
EOF
)"

it "block trigger reads the item's first waiting row"
check "test:a/b1/block/None" "$(run_py <<'EOF'
run = setup([beh("b1", "block")], a={"waiting": TRIGGER})
print(lines(run))
EOF
)"

it "an entry whose trigger is not a known value lists nothing and does not raise"
check "" "$(run_py <<'EOF'
run = setup([beh("b1", "never")], a={"claim": TRIGGER})
print(lines(run))
EOF
)"

it "the list is capped and reports the overflow count and ids"
check "2 1 test:c/b1" "$(run_py <<'EOF'
run = setup([beh("b1")], a={"claim": TRIGGER}, b={"claim": TRIGGER}, c={"claim": TRIGGER})
got = due(run, cap=2)
print(len(got["rows"]), got["overflow"], ",".join(got["overflow_ids"]))
EOF
)"

it "a store that cannot be read is reported in the result, not hidden"
check "1" "$(run_py <<'EOF'
os.makedirs(os.path.dirname(os.environ["CLAUDE_AUTO_BEHAVIOURS_STORE"]), exist_ok=True)
open(os.environ["CLAUDE_AUTO_BEHAVIOURS_STORE"], "w").write("{not json")
run = setup([beh("b1")], a={"claim": TRIGGER})
print(len(due(run)["store_notices"]))
EOF
)"

it "the total counts every due behaviour, past the cap"
check "3" "$(run_py <<'EOF'
run = setup([beh("b1")], a={"claim": TRIGGER}, b={"claim": TRIGGER}, c={"claim": TRIGGER})
print(due(run, cap=2)["total"])
EOF
)"

echo ""
echo "programme-behaviours-due.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
