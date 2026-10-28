#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
PROG="${AUTO_ROOT}/lib/programme.py"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
check() { if [ "$1" = "$2" ]; then pass; else fail "expected [$1] got [$2]"; fi; }
has() { case "$2" in *"$1"*) pass ;; *) fail "expected to find [$1] in [$2]" ;; esac; }

echo "programme-focus.test.sh"

WORK="$(mktemp -d -t auto-programme-focus.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_MACHINE="studio"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_CODE_SESSION_ID="sess-pm"
unset HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_BIN_PATH CLAUDE_AUTO_REPO 2>/dev/null || true
: > "$CLAUDE_AUTO_SECRETS_FILE"

FAKES="${WORK}/fakes"
mkdir -p "$FAKES"
printf '#!/bin/sh\nexit 0\n' > "${FAKES}/board"
CALLS="${WORK}/calls.log"
SNAP="${WORK}/snapshot.json"
: > "$CALLS"
export CALLS SNAP PY CLAUDE_AUTO_TEST_HARNESS=1 CLAUDE_AUTO_SOURCE_TIMEOUT=2 CLAUDE_AUTO_WORKER_WAIT=1
cat > "${FAKES}/herdr" <<'FEOF'
#!/bin/bash
printf 'herdr %s\n' "$*" >> "$CALLS"
case "$1 ${2:-}" in
  "status server")
    [ -n "${FAKE_HERDR_DOWN:-}" ] && exit 1
    echo "status: running" ;;
  "api snapshot") cat "$SNAP" ;;
  "agent list")
    "$PY" -c 'import json,sys; s=json.load(open(sys.argv[1]))["result"]["snapshot"]; print(json.dumps({"id":"1","result":{"type":"agent_list","agents":s["agents"]}}))' "$SNAP" ;;
esac
exit 0
FEOF
cat > "${FAKES}/spinoff" <<'FEOF'
#!/bin/bash
printf 'spinoff %s\n' "$*" >> "$CALLS"
sid=""
while [ $# -gt 0 ]; do
  [ "$1" = "--session-id" ] && sid="$2"
  shift
done
echo "  herdr agent pane: w2:p40 (launched with the brief)"
"$PY" - "$SNAP" "$sid" <<'PYEOF'
import json, sys
path, sid = sys.argv[1:3]
doc = json.load(open(path))
snap = doc["result"]["snapshot"]
pane = {"pane_id": "w2:p40", "tab_id": "w2:t1", "workspace_id": "w2", "terminal_id": "term_p40",
        "agent": "claude", "agent_status": "idle", "cwd": "/tmp", "label": "worker",
        "terminal_title_stripped": "worker",
        "agent_session": {"source": "auto", "agent": "claude", "kind": "id", "value": sid}}
snap["panes"] = [p for p in snap["panes"] if p["pane_id"] != "w2:p40"] + [pane]
snap["agents"] = [p for p in snap["agents"] if p["pane_id"] != "w2:p40"] + [pane]
json.dump(doc, open(path, "w"))
PYEOF
FEOF
chmod +x "${FAKES}"/*
export PATH="${FAKES}:${PATH}"

snapshot() {
  "$PY" - "$SNAP" "$@" <<'PYEOF'
import json, sys
path, specs = sys.argv[1], sys.argv[2:]
def pane(pid, agent, label=None, sess=None):
    return {"pane_id": pid, "tab_id": "w2:t1", "workspace_id": "w2", "terminal_id": "term_" + pid.split(":")[1],
            "agent": agent, "agent_status": "idle" if agent else None, "cwd": "/tmp", "label": label,
            "terminal_title_stripped": None,
            "agent_session": {"source": "auto", "agent": "claude", "kind": "id", "value": sess} if sess else None}
panes = [pane("w2:p10", "claude", "PM", "sess-pm")]
for spec in specs:
    pid, kind = spec.split(":", 2)[:2]
    pid = "w2:" + pid
    panes.append(pane(pid, "claude" if kind == "agent" else None, None, "sess-" + pid.split(":")[1] if kind == "agent" else None))
doc = {"id": "1", "result": {"type": "snapshot", "snapshot": {
    "workspaces": [{"workspace_id": "w2", "label": "Ai Editor"}],
    "tabs": [{"tab_id": "w2:t1", "workspace_id": "w2", "label": "Work"}],
    "panes": panes, "agents": [p for p in panes if p["agent"]]}}}
json.dump(doc, open(path, "w"))
PYEOF
}
snapshot

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
sys.path.insert(0, os.path.join(sys.argv[1], 'tests', 'fixtures'))
from programme_prompts import append_prompt as fixture_prompt
ph = load_lib_module("programme_home")
pj = load_lib_module("programme_journal")
core = load_lib_module("run_record_core")
args = sys.argv[2:]
def record(run):
    return core.read_run_record(ph.home_path(run), run)
$(cat)
PYEOF
}

RUN="$(run_py w2 <<'EOF'
print(ph.create_programme([args[0]], "sess-pm")["run"])
EOF
)"

prompt() {
  run_py "$RUN" "$1" "$2" <<'EOF'
run, origin, text = args
print(fixture_prompt(run, "sess-pm", text, origin)["prompt_id"])
EOF
}

field() {
  run_py "$RUN" "$1" <<'EOF'
run, expr = args
prog = record(run)["programme"]
print(json.dumps(eval(expr), sort_keys=True))
EOF
}

OUT=""
CODE=0
prog() {
  OUT="$("$PY" "$PROG" "$@" 2>&1)"
  CODE=$?
}

FB='prog["agreement"]["terms"]["focus_budget"]'

it "a fresh programme carries focus_budget unlimited with no limits and the default scale"
check '[null, null, {"large": 5, "medium": 3, "small": 1}, "default", "unlimited"]' \
  "$(field "[${FB}['points'], ${FB}['agents'], ${FB}['scale'], ${FB}['set_by'], ${FB}['value']]")"

it "amend-term focus_budget limited stores the points and agents"
P1="$(prompt typed 'focus budget limited, 10 points and 3 agents')"
prog amend-term focus_budget limited --points 10 --agents 3 --prompt "$P1"
check 0 "$CODE"
check '["limited", 10, 3]' "$(field "[${FB}['value'], ${FB}['points'], ${FB}['agents']]")"

it "the terms view shows the points"
prog status --run "$RUN"
has "points 10" "$OUT"
has "agents 3" "$OUT"

it "an amend that sets only the points keeps the agent limit"
P2="$(prompt typed 'focus budget limited, only 6 points')"
prog amend-term focus_budget limited --points 6 --prompt "$P2"
check '[6, 3]' "$(field "[${FB}['points'], ${FB}['agents']]")"

it "a zero point limit is refused with the allowed range"
prog amend-term focus_budget limited --points 0 --prompt "$P1"
check 1 "$CODE"
has "positive whole number" "$OUT"

it "a negative agent limit is refused"
prog amend-term focus_budget limited --agents -2 --prompt "$P1"
check 1 "$CODE"
has "positive whole number" "$OUT"

it "a bare number is refused as fitting no option and names the usable form"
P3="$(prompt typed 'focus budget 10')"
prog amend-term focus_budget 10 --prompt "$P3"
check 1 "$CODE"
has "fits no option" "$OUT"
has "limited --points" "$OUT"

it "limited with neither limit is refused"
prog amend-term focus_budget limited --points none --agents none --prompt "$P1"
check 1 "$CODE"

it "a scale entry with a non-integer value is refused"
prog amend-term focus_budget limited --points 6 --scale small=x --prompt "$P1"
check 1 "$CODE"
has "whole number" "$OUT"

it "a scale entry with a zero value is refused"
prog amend-term focus_budget limited --points 6 --scale small=0 --prompt "$P1"
check 1 "$CODE"

it "a scale replaces the old one"
prog amend-term focus_budget limited --points 6 --scale small=2,large=8 --prompt "$P2"
check 0 "$CODE"
check '{"large": 8, "small": 2}' "$(field "${FB}['scale']")"

it "clearing sets unlimited, drops both limits and keeps the scale"
P4="$(prompt typed 'focus budget unlimited')"
prog amend-term focus_budget unlimited --prompt "$P4"
check 0 "$CODE"
check '["unlimited", null, null, {"large": 8, "small": 2}]' \
  "$(field "[${FB}['value'], ${FB}['points'], ${FB}['agents'], ${FB}['scale']]")"

it "propose-term carries the limits as extras and an amend that matches accepts the proposal"
prog propose-term focus_budget limited --points 9
check 0 "$CODE"
check '{"points": 9}' "$(field "${FB}['proposal']['extras']")"
P5="$(prompt typed 'focus budget limited, 9 points')"
prog amend-term focus_budget limited --points 9 --prompt "$P5"
check '"accepted"' "$(field "${FB}['proposal']['state']")"

it "an old record without focus_budget gains it as unlimited and stays accepted"
check '["unlimited", "default", true]' "$(run_py "$RUN" <<'EOF'
rec = record(args[0])
prog = json.loads(json.dumps(rec["programme"]))
prog["agreement"]["terms"].pop("focus_budget")
prog["agreement"]["accepted"] = {"at": "x", "prompt_id": "p1", "quote": "ok"}
t = ph.normalize_programme(prog)
f = t["agreement"]["terms"]["focus_budget"]
print(json.dumps([f["value"], f["set_by"], bool(t["agreement"]["accepted"])]))
EOF
)"

it "the accept-terms digest ignores an untouched focus_budget and changes once it is set"
FRESH="$(run_py w3 <<'EOF'
print(ph.create_programme([args[0]], "sess-pm2")["run"])
EOF
)"
check '["same", "differs"]' "$(run_py "$FRESH" <<'EOF'
approval = load_lib_module("programme_approval")
block = record(args[0])["programme"]
without = json.loads(json.dumps(block))
without["agreement"]["terms"].pop("focus_budget")
set_ = json.loads(json.dumps(block))
set_["agreement"]["terms"]["focus_budget"].update(value="limited", points=5, set_by="shawn")
print(json.dumps([
    "same" if approval.terms_digest(block) == approval.terms_digest(without) else "differs",
    "differs" if approval.terms_digest(block) != approval.terms_digest(set_) else "same"]))
EOF
)"

it "setup counts a never-set focus_budget as done"
check '"done"' "$(run_py "$FRESH" <<'EOF'
vs = load_lib_module("programme_view_setup")
step = vs._term_step("focus_budget", record(args[0])["programme"]["agreement"]["terms"]["focus_budget"], set())
print(json.dumps(step["state"] if "state" in step else ("done" if step["done"] else "open")))
EOF
)"

# ---- U2: item size ----
P6="$(prompt typed 'focus budget unlimited, scale small 1 medium 3 large 5')"
prog amend-term focus_budget unlimited --scale small=1,medium=3,large=5 --prompt "$P6"
SIZED="mem:one"
prog add-item mem:one --title "one" --size medium --run "$RUN"
[ "$CODE" -eq 0 ] || echo "$OUT"
check 0 "$CODE"
it "add-item --size stores the size and points_of resolves it"
check '["medium", 3]' "$(run_py "$RUN" <<'EOF'
focus = load_lib_module("programme_focus")
prog = record(args[0])["programme"]
print(json.dumps([prog["items"]["mem:one"]["size"], focus.points_of(prog["items"]["mem:one"], prog["agreement"]["terms"]["focus_budget"]["scale"])]))
EOF
)"

it "add-item with a size outside the scale is refused and lists the valid names"
prog add-item mem:two --title two --size huge --run "$RUN"
check 1 "$CODE"
has "small" "$OUT"
has "large" "$OUT"
check 'false' "$(field '"mem:two" in prog["items"]')"

it "size-item changes the size and records history"
prog add-item mem:two --title two --run "$RUN"
prog size-item mem:two large --run "$RUN"
check 0 "$CODE"
check '["large", "sized"]' "$(field '[prog["items"]["mem:two"]["size"], prog["items"]["mem:two"]["history"][-1]["kind"]]')"

it "size-item with a name outside the scale is refused and lists the valid names"
prog size-item mem:two huge --run "$RUN"
check 1 "$CODE"
has "small" "$OUT"
check '"large"' "$(field 'prog["items"]["mem:two"]["size"]')"

it "size-item on an unknown item is refused"
prog size-item mem:nope small --run "$RUN"
check 1 "$CODE"

it "an item with no size reads as unsized, not zero points"
prog add-item mem:three --title three --run "$RUN"
check 'null' "$(field 'prog["items"]["mem:three"]["size"]')"
check 'null' "$(run_py "$RUN" <<'EOF'
focus = load_lib_module("programme_focus")
prog = record(args[0])["programme"]
print(json.dumps(focus.points_of(prog["items"]["mem:three"], prog["agreement"]["terms"]["focus_budget"]["scale"])))
EOF
)"

it "a size renamed out of the scale makes the item unsized"
check 'null' "$(run_py "$RUN" <<'EOF'
focus = load_lib_module("programme_focus")
print(json.dumps(focus.points_of({"size": "large"}, {"small": 1})))
EOF
)"

it "an old item record without a size field normalizes to unsized"
check 'null' "$(run_py "$RUN" <<'EOF'
print(json.dumps(ph.normalize_item({"id": "mem:old", "title": "x"}).get("size", "missing")))
EOF
)"

# ---- U3: the gate in start-worker ----
NS="mem:g"
mk() {
  local id="$1" size="$2" pane="${3:-}"
  local args=(add-item "${NS}${id}" --title "g${id}" --run "$RUN")
  [ -n "$size" ] && args+=(--size "$size")
  [ -n "$pane" ] && args+=(--pane "w2:${pane}" --terminal-id "term_${pane}" --session "sess-${pane}")
  prog "${args[@]}"
  [ "$CODE" -eq 0 ] || echo "mk failed: $OUT"
}
drop() { prog drop-item "${NS}$1" --reason "test cleanup" --run "$RUN"; }
start() { FAKE_HERDR_DOWN="${DOWN:-}" prog start-worker "${NS}$1" "${@:2}" --run "$RUN" -- --name "w$1"; }
spins() { grep -c '^spinoff' "$CALLS"; }
nops() { run_py "$RUN" <<'EOF2'
pr = load_lib_module("programme_recovery")
print(len(pr.operations(record(args[0])["programme"])))
EOF2
}
gitem() { field "prog['items']['${NS}$1']['$2']"; }
limit() {
  local p; p="$(prompt typed "focus budget $*")"
  prog amend-term focus_budget "$@" --prompt "$p"
  [ "$CODE" -eq 0 ] || echo "limit failed: $OUT"
}

SP="$(prompt typed 'focus budget unlimited, scale s1 s3 s5 s7')"
prog amend-term focus_budget unlimited --scale s1=1,s3=3,s5=5,s7=7 --prompt "$SP"

snapshot
mk 0 ""
it "no limit set: an unsized item starts exactly as before and is not held"
S0="$(spins)"
start 0
check 0 "$CODE"
check "null" "$(gitem 0 held)"
check "$((S0 + 1))" "$(spins)"
drop 0

it "no limit set: herdr is not read for the gate"
: > "$CALLS"
mk 00 ""
start 00
check 0 "$CODE"
check 0 "$(grep -c 'api snapshot' "$CALLS")"
drop 00

limit limited --points 10
mk 7 s7 p31
mk 3 s3
snapshot p31:agent
it "10-point limit, 7 in play: a 3-point item starts (exactly 10 of 10)"
start 3
check 0 "$CODE"
check "null" "$(gitem 3 held)"
drop 3

mk 5 s5
snapshot p31:agent
S1="$(spins)"; O1="$(nops)"
it "10-point limit, 7 in play: a 5-point item is held, no launch is attempted"
start 5
check 1 "$CODE"
has "over points: 7 of 10 in play" "$OUT"
has "Next:" "$OUT"
check '"over points: 7 of 10 in play (this item is 5)"' "$(gitem 5 held)"
check "$S1" "$(spins)"
check "$O1" "$(nops)"

it "a refused start leaves held and held_at committed after the verb raised"
check 'true' "$(field "bool(prog['items']['${NS}5']['held_at'])")"

it "each refusal adds one journal row and keeps the first held_at"
HELD_AT="$(gitem 5 held_at)"
J1="$(grep -c '"item_held"' "${CLAUDE_AUTO_DATA_DIR}/programmes/${RUN}/journal.jsonl")"
sleep 1.1
start 5
check "$HELD_AT" "$(gitem 5 held_at)"
check "$((J1 + 1))" "$(grep -c '"item_held"' "${CLAUDE_AUTO_DATA_DIR}/programmes/${RUN}/journal.jsonl")"

mk 1 s1
mk 31 s3 p32
snapshot p31:agent p32:agent
it "at 10 of 10 in play a 1-point item is held (11 would pass the limit)"
start 1
check 1 "$CODE"
has "over points: 10 of 10 in play" "$OUT"

it "an item that finishes frees its points and the next start passes"
drop 7
snapshot p32:agent
start 1
check 0 "$CODE"
check "null" "$(gitem 1 held)"
drop 1
drop 31

it "a successful start clears an earlier hold"
snapshot
start 5
check 0 "$CODE"
check "null" "$(gitem 5 held)"
check "null" "$(gitem 5 held_at)"
drop 5

mk 71 s7 p31
mk 51 s5
snapshot
it "an item whose worker pane died does not count toward points in play"
start 51
check 0 "$CODE"
drop 51

mk 52 s5
snapshot p31:shell
it "an item whose pane holds a shell with no agent does not count"
start 52
check 0 "$CODE"
drop 52

mk 53 s5
snapshot p31:agent
it "the same item with a live worker pane does count and is held"
start 53
check 1 "$CODE"

it "an unsized item is held while a point limit is set, naming size-item"
mk 6 ""
snapshot
start 6
check 1 "$CODE"
has "unsized" "$OUT"
has "size-item ${NS}6" "$OUT"

it "an unsized item starts when only an agent limit is set"
limit limited --points none --agents 3
start 6
check 0 "$CODE"
drop 6
drop 71
drop 53

mk 61 ""
mk 62 "" p33
mk 63 "" p34
snapshot p33:agent p34:agent p35:agent
it "agents at the limit hold the start, counting a worker no item owns"
start 61
check 1 "$CODE"
has "agents at limit: 3 of 3" "$OUT"
check '"agents at limit: 3 of 3"' "$(gitem 61 held)"

it "a shell pane does not use up the agent limit"
snapshot p33:agent p34:agent p35:shell
start 61
check 0 "$CODE"

it "herdr unreadable with only a points limit set holds the start and names the retry step"
drop 61
mk 64 s1
limit limited --points 10 --agents none
DOWN=1 start 64
check 1 "$CODE"
has "count unavailable" "$OUT"
has "--despite focus" "$OUT"
check 'true' "$(field "bool(prog['items']['${NS}64']['held'])")"

it "--despite focus starts a held item and journals the override"
snapshot p31:agent
mk 72 s7 p31
mk 54 s5
start 54
check 1 "$CODE"
start 54 --despite focus
check 0 "$CODE"
check "null" "$(gitem 54 held)"
check 'true' "$(run_py "$RUN" <<'EOF2'
pr = load_lib_module("programme_recovery")
ops = [o for o in pr.operations(record(args[0])["programme"]).values() if o["item"] == "mem:g54"]
print(json.dumps(any(o.get("despite") == ["focus"] for o in ops)))
EOF2
)"
check 1 "$(grep -c '"focus_overridden"' "${CLAUDE_AUTO_DATA_DIR}/programmes/${RUN}/journal.jsonl")"
drop 54
drop 72
drop 64

it "focus-recheck clears a held item that now fits and leaves one that does not"
mk 73 s7 p31
snapshot p31:agent
mk 81 s3
mk 82 s5
start 81
check 0 "$CODE"
drop 81
start 82
check 1 "$CODE"
sleep 1.1
snapshot p31:agent
drop 73
snapshot
prog focus-recheck --run "$RUN"
check 0 "$CODE"
check "null" "$(gitem 82 held)"

it "focus-recheck clears the earlier held item first and subtracts its room before the next"
limit limited --points 5
mk 91 s3
mk 92 s3
mk 93 s7 p36
snapshot p36:agent
start 92
check 1 "$CODE"
sleep 1.1
start 91
check 1 "$CODE"
drop 93
snapshot
prog focus-recheck --run "$RUN"
check 0 "$CODE"
check "null" "$(gitem 92 held)"
has "over points: 3 of 5 in play" "$OUT"
has "over points" "$(gitem 91 held)"

it "focus-recheck with herdr unreadable leaves every held item held"
FAKE_HERDR_DOWN=1 prog focus-recheck --run "$RUN"
check 0 "$CODE"
has "over points" "$(gitem 91 held)"

it "census ignores an item whose evidence reads done, a held item and a dropped item"
check '[3, 4]' "$(run_py "$RUN" <<'EOF2'
focus = load_lib_module("programme_focus")
prog = ph.new_programme_block([("default", "w2")], "2026-10-28T00:00:00Z")
prog["agreement"]["terms"]["focus_budget"]["scale"] = {"s3": 3, "s5": 5}
def item(i, size, pane, **kw):
    out = ph.new_item(i, i, state="open", now_iso="2026-10-28T00:00:00Z")
    out.update(size=size, owner=dict(out["owner"], pane=pane), **kw)
    prog["items"][i] = out
item("mem:live", "s3", "w2:p1")
item("mem:evid", "s5", "w2:p2", matched_rule="r", deliverables={"d": {"result": "confirmed"}})
item("mem:held", "s5", "w2:p3", held="over points", held_at="2026-10-28T00:00:01Z")
item("mem:gone", "s5", "w2:p4")
prog["items"]["mem:gone"]["state"] = "dropped"
item("mem:new", "s3", None)
panes = [{"pane_id": "w2:p%d" % n} for n in (1, 2, 3, 4)]
c = focus.census(prog, "mem:new", panes)
print(json.dumps([c["points"], c["agents"]]))
EOF2
)"

it "with only held items left may_stop is true; with one startable item it stays false"
check '["True", "False"]' "$(run_py "$RUN" <<'EOF2'
import datetime
pp = load_lib_module("programme_predicate")
def build(*items):
    block = ph.new_programme_block([("default", "w2")], "2026-10-28T00:00:00Z")
    block["agreement"]["accepted"] = {"at": "2026-10-28T00:00:01Z", "prompt_id": "p1"}
    for i, kw in items:
        it_ = ph.new_item(i, i, state="open", now_iso="2026-10-28T00:00:00Z")
        it_.update(matched_rule="r", **kw)
        block["items"][i] = it_
    return {"run_id": "prog-1", "run_kind": "programme", "programme_format": 1, "programme": block, "steps": []}
now = datetime.datetime(2026, 10, 28, 1, 0, tzinfo=datetime.timezone.utc)
held = pp.compute(build(("mem:h", {"held": "over points", "held_at": "2026-10-28T00:00:02Z"})), now, None)
live = pp.compute(build(("mem:h", {"held": "over points", "held_at": "2026-10-28T00:00:02Z"}), ("mem:s", {})), now, None)
print(json.dumps([str(held["may_stop"]), str(live["may_stop"])]))
EOF2
)"

echo ""
echo "programme-focus.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
