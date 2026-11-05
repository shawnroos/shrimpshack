#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "programme-focus.test.sh"

. "${AUTO_ROOT}/tests/helpers/programme-focus-setup.sh"

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
has 'Next: leave it queued and run `focus-recheck` when room frees, ask Shawn for a swap, or ask Shawn to approve breaking the budget: run `programme.sh offer focus --command '"'"'override-focus '"${NS}5"''"'"'`, ask with the input it prints, run `override-focus '"${NS}5"' --prompt <pick id>`, then start again with `--despite focus`.' "$OUT"
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
has "Next: \`size-item ${NS}6 <size>\`, then start it again." "$OUT"

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
has 'Next: retry once the count is readable, or ask Shawn to approve breaking the budget: run `programme.sh offer focus --command '"'"'override-focus '"${NS}64"''"'"'`, ask with the input it prints' "$OUT"
check 'true' "$(field "bool(prog['items']['${NS}64']['held'])")"

it "--despite focus with no approval is refused, holds the item and names the override-focus step"
snapshot p31:agent
mk 72 s7 p31
mk 54 s5
start 54
check 1 "$CODE"
S54="$(spins)"
start 54 --despite focus
check 1 "$CODE"
has "needs Shawn's pick first" "$OUT"
has "programme.sh offer focus --command 'override-focus ${NS}54'" "$OUT"
has "override-focus ${NS}54 --prompt <pick id>" "$OUT"
check "$S54" "$(spins)"
check 'true' "$(field "bool(prog['items']['${NS}54']['held'])")"

it "override-focus approves nothing from typed text, even the option's own words"
for TXT in "yes override ${NS}54" "Break the focus budget for item ${NS}54"; do
  PROG="$REAL_PROG" prog override-focus "${NS}54" --prompt "$(prompt typed "$TXT")" --run "$RUN"
  check 1 "$CODE"
  has "no open offer" "$OUT"
done
check "null" "$(gitem 54 focus_override)"

it "override-focus approves nothing from a suggested prompt, another verb's label or another item's label"
prog override-focus "${NS}54" --prompt "$(prompt suggested "$(override_label 54)")" --run "$RUN"
check 1 "$CODE"
prog override-focus "${NS}54" --prompt "$(pickit "$(swap_label 72 54)")" --run "$RUN"
check 1 "$CODE"
prog override-focus "${NS}54" --prompt "$(pickit "$(override_label 72)")" --run "$RUN"
check 1 "$CODE"
check "null" "$(gitem 54 focus_override)"
start 54 --despite focus
check 1 "$CODE"

it "a pick with a note approves nothing, because the note is Shawn's own words"
prog override-focus "${NS}54" --prompt "$(PICK_NOTE='but not this week' pickit "$(override_label 54)")" --run "$RUN"
check 1 "$CODE"
has "own words" "$OUT"
check "null" "$(gitem 54 focus_override)"

it "a pick of its offer records the approval and journals it"
POV="$(pickit "$(override_label 54)")"
prog override-focus "${NS}54" --prompt "$POV" --run "$RUN"
check 0 "$CODE"
check "\"${POV}\"" "$(field "prog['items']['${NS}54']['focus_override']['prompt_id']")"
check 1 "$(grep -c '"focus_override_approved"' "${CLAUDE_AUTO_DATA_DIR}/programmes/${RUN}/journal.jsonl")"

it "the same pick cannot approve a second override"
prog override-focus "${NS}54" --prompt "$POV" --run "$RUN"
check true "$([ "$CODE" -ne 0 ] && echo true || echo false)"
has "already used" "$OUT"

it "an approved override starts the held item once, journals it and consumes the approval"
start 54 --despite focus
check 0 "$CODE"
check "null" "$(gitem 54 focus_override)"
check "null" "$(gitem 54 held)"
check 'true' "$(run_py "$RUN" <<'EOF2'
pr = load_lib_module("programme_recovery")
ops = [o for o in pr.operations(record(args[0])["programme"]).values() if o["item"] == "mem:g54"]
print(json.dumps(any(o.get("despite") == ["focus"] for o in ops)))
EOF2
)"
check 1 "$(grep -c '"focus_overridden"' "${CLAUDE_AUTO_DATA_DIR}/programmes/${RUN}/journal.jsonl")"
has "${POV}" "$(grep '"focus_overridden"' "${CLAUDE_AUTO_DATA_DIR}/programmes/${RUN}/journal.jsonl")"

it "the approval is single-use: a second --despite focus start on the item is held again"
snapshot p31:agent
start 54 --despite focus
check 1 "$CODE"
has "needs Shawn's pick first" "$OUT"
it "override-focus on an item with no hold is refused, and the refused pick is not spent"
mk 190 s5
snapshot p31:agent
PV190="$(pickit "$(override_label 190)")"
prog override-focus "${NS}190" --prompt "$PV190" --run "$RUN"
check 1 "$CODE"
has "not held" "$OUT"
check "null" "$(gitem 190 focus_override)"
start 190
check 1 "$CODE"
prog override-focus "${NS}190" --prompt "$PV190" --run "$RUN"
check 0 "$CODE"
check "\"${PV190}\"" "$(field "prog['items']['${NS}190']['focus_override']['prompt_id']")"
drop 190

it "an approval is cleared when room frees and the item starts normally, so the next full budget needs a fresh pick"
mk 191 s5
snapshot p31:agent
start 191
check 1 "$CODE"
approve_override 191
check 0 "$CODE"
snapshot
start 191
check 0 "$CODE"
check "null" "$(gitem 191 focus_override)"
snapshot p31:agent
start 191 --despite focus
check 1 "$CODE"
has "needs Shawn's pick first" "$OUT"
drop 191

it "dropping an item clears its approval"
mk 192 s5
start 192
approve_override 192
check "true" "$(field "bool(prog['items']['${NS}192']['focus_override'])")"
drop 192
check "null" "$(gitem 192 focus_override)"

it "granting an approval to a finished item is refused"
mk 196 s5
start 196
check 1 "$CODE"
drop 196
approve_override 196
check 1 "$CODE"
has "is dropped" "$OUT"
check "null" "$(gitem 196 focus_override)"

it "a size change clears the approval"
mk 193 s5
start 193
approve_override 193
check "true" "$(field "bool(prog['items']['${NS}193']['focus_override'])")"
prog size-item "${NS}193" s7 --run "$RUN"
check 0 "$CODE"
check "null" "$(gitem 193 focus_override)"
drop 193

it "an approval is refused once the hold has grown, and a fresh pick is needed"
mk 194 s5
start 194
approve_override 194
mk 195 s1 p32
snapshot p31:agent p32:agent
S194="$(spins)"
start 194 --despite focus
check 1 "$CODE"
has "needs Shawn's pick first" "$OUT"
check "$S194" "$(spins)"
check "null" "$(gitem 194 focus_override)"
approve_override 194
check 0 "$CODE"
start 194 --despite focus
check 0 "$CODE"
drop 194
drop 195
snapshot p31:agent

it "two consumes of one approval against the same stale snapshot let only one through"
mk 197 s5
start 197
approve_override 197
check 'consumed,refused' "$(run_py "$RUN" "${NS}197" <<'EOF2'
host = load_lib_module("programme")
pf = load_lib_module("programme_focus")
run, key = args[0], args[1]
home = ph.home_path(run)
rec = record(run)
stale = ph.normalize_programme(rec["programme"])
out = []
for _ in range(2):
    try:
        pf.admit(host, run, home, rec, stale, key, ("focus",))
        out.append("consumed")
    except host.ProgrammeError:
        out.append("refused")
print(",".join(out))
EOF2
)"
drop 197

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
print(json.dumps([c.points, c.agents]))
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
echo "through offer: $(grep -c '^offered$' "${WORK}/offered.log") offered, $(grep -c '^refused' "${WORK}/offered.log") refused"
grep '^refused' "${WORK}/offered.log"
echo "programme-focus.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
