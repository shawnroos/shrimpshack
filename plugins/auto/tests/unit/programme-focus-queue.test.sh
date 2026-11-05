#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "programme-focus-queue.test.sh"

. "${AUTO_ROOT}/tests/helpers/programme-focus-setup.sh"

SP="$(prompt typed 'focus budget unlimited, scale s1 s3 s5 s7')"
prog amend-term focus_budget unlimited --scale s1=1,s3=3,s5=5,s7=7 --prompt "$SP"

# ---- U4: visible queue and usage ----
statusj() { "$PY" "$PROG" status --json --run "$RUN" 2>&1; }
vq() { statusj | "$PY" -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(eval(sys.argv[1])))' "$1"; }

limit limited --points 10 --agents 3
mk 41 s3 p51
mk 42 s5 p52
snapshot p51:agent p52:agent
it "the Focus row shows points and agents in play against the limits"
prog status --run "$RUN"
has "Focus" "$OUT"
has "points 8 of 10" "$OUT"
has "agents 2 of 3" "$OUT"

it "the json view carries the same usage"
check '[8, 10, 2, 3]' "$(vq '[d["model"]["focus"]["points"]["used"], d["model"]["focus"]["points"]["limit"], d["model"]["focus"]["agents"]["used"], d["model"]["focus"]["agents"]["limit"]]')"

it "focus-note --agents records the subagent number and the view shows it"
prog focus-note --agents 4 --run "$RUN"
check 0 "$CODE"
prog status --run "$RUN"
has "subagents 4" "$OUT"
check '4' "$(vq 'd["model"]["focus"]["subagents"]')"

it "focus-note refuses a missing or non-numeric count"
prog focus-note --agents many --run "$RUN"
check 1 "$CODE"
prog focus-note --run "$RUN"
check 1 "$CODE"

it "an item that is held does not count toward points in play"
check '[5, ["mem:g41"]]' "$(run_py "$RUN" <<'EOF2'
focus = load_lib_module("programme_focus")
prog = record(args[0])["programme"]
prog["items"]["mem:g41"].update(held="x", held_at="2026-10-28T00:00:01Z")
u = focus.usage(prog, [{"pane_id": "w2:p51"}, {"pane_id": "w2:p52"}])
w = focus.waiting(prog)
print(json.dumps([u["points"]["used"], [e["item"] for e in w if e["item"] == "mem:g41"]]))
EOF2
)"

mk 43 s5
mk 44 s3
mk 45 s3
snapshot p51:agent p52:agent
start 45
check 1 "$CODE"
sleep 1.1
start 44
check 1 "$CODE"
it "held items list in the order they were held, not by id, with size and reason"
prog status --run "$RUN"
has "Waiting for a slot" "$OUT"
check '["mem:g45", "mem:g44"]' "$(vq '[w["item"] for w in d["model"]["waiting_for_slot"]]')"
check '["s3", "s3"]' "$(vq '[w["size"] for w in d["model"]["waiting_for_slot"]]')"
POS45="$(printf '%s\n' "$OUT" | grep -n 'mem:g45  size' | head -1 | cut -d: -f1)"
POS44="$(printf '%s\n' "$OUT" | grep -n 'mem:g44  size' | head -1 | cut -d: -f1)"
check true "$([ -n "$POS45" ] && [ -n "$POS44" ] && [ "$POS45" -lt "$POS44" ] && echo true || echo false)"
has "over points: 8 of 10 in play" "$OUT"

it "herdr down shows the agent and point counts as unavailable, not zero"
FAKE_HERDR_DOWN=1 prog status --run "$RUN"
has "agents unavailable" "$OUT"
has "points unavailable" "$OUT"
check 'null' "$(FAKE_HERDR_DOWN=1 statusj | "$PY" -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["model"]["focus"]["agents"]["used"]))')"

it "with no limit set the row says no limit and there is no waiting list"
limit unlimited
prog status --run "$RUN"
has "points no limit" "$OUT"
has "agents no limit" "$OUT"
case "$OUT" in *"Waiting for a slot"*) fail "waiting list shown with no limit" ;; *) pass ;; esac
: > "$CALLS"
prog status --run "$RUN"
check 0 "$(grep -c 'api snapshot' "$CALLS")"


limit limited --points 6 --agents none
mk 101 s5 p61
mk 102 s1 p62
mk 103 s5
snapshot p61:agent p62:agent

it "offer refuses a verb a pick cannot approve (default-deny)"
prog offer focus --command "focus-note --agents 3" --run "$RUN"
check 1 "$CODE"
has "takes no approval" "$OUT"

it "a typed 'yes swap them' approves nothing"
PT="$(prompt typed "yes swap them: ${NS}101 for ${NS}103")"
PROG="$REAL_PROG" prog swap-item "${NS}101" "${NS}103" --prompt "$PT" --run "$RUN"
check 1 "$CODE"
has "no open offer" "$OUT"
check "null" "$(gitem 101 held)"

it "typing the option's own words still approves nothing"
PT2="$(prompt typed "Swap item ${NS}101 out for item ${NS}103")"
PROG="$REAL_PROG" prog swap-item "${NS}101" "${NS}103" --prompt "$PT2" --run "$RUN"
check 1 "$CODE"
has "no open offer" "$OUT"
check "null" "$(gitem 101 held)"

it "the decline option approves nothing and leaves both items unchanged"
PD="$(opick "$RUN" --decline "swap-item ${NS}101 ${NS}103")"
prog swap-item "${NS}101" "${NS}103" --prompt "$PD" --run "$RUN"
check 1 "$CODE"
has "Shawn declined this offer" "$OUT"
check "null" "$(gitem 101 held)"
check "null" "$(gitem 103 held)"

it "a pick of another swap's label does not approve this one"
PO="$(pickit "$(swap_label 102 103)")"
prog swap-item "${NS}101" "${NS}103" --prompt "$PO" --run "$RUN"
check 1 "$CODE"
check "null" "$(gitem 101 held)"

it "swapping out a 1-point item for a 5-point item is refused and names the missing points"
PS="$(pickit "$(swap_label 102 103)")"
prog swap-item "${NS}102" "${NS}103" --prompt "$PS" --run "$RUN"
check 1 "$CODE"
has "needs 4 more point" "$OUT"
check "null" "$(gitem 102 held)"

it "swapping an item that is not in play is refused"
mk 104 s5
PN="$(pickit "$(swap_label 104 103)")"
prog swap-item "${NS}104" "${NS}103" --prompt "$PN" --run "$RUN"
check 1 "$CODE"
has "not in play" "$OUT"
check "null" "$(gitem 104 held)"

it "swap-item refuses when herdr is unreadable"
PU="$(pickit "$(swap_label 101 103)")"
FAKE_HERDR_DOWN=1 prog swap-item "${NS}101" "${NS}103" --prompt "$PU" --run "$RUN"
check 1 "$CODE"
check "null" "$(gitem 101 held)"

it "a pick of its offer parks the item: held with a reason, held_at set, old pane recorded"
PX="$(pickit "$(swap_label 101 103)")"
prog swap-item "${NS}101" "${NS}103" --prompt "$PX" --run "$RUN"
check 0 "$CODE"
has "stop_prompt" "$OUT"
check '"w2:p61"' "$(gitem 101 parked_pane)"
check 'true' "$(field "bool(prog['items']['${NS}101']['held'] and prog['items']['${NS}101']['held_at'])")"
has "${NS}103" "$(gitem 101 held)"

it "the same pick cannot approve a second swap"
prog swap-item "${NS}101" "${NS}103" --prompt "$PX" --run "$RUN"
check true "$([ "$CODE" -ne 0 ] && echo true || echo false)"
has "already used" "$OUT"

it "the swap is recorded as a work_sequencing decision naming both items"
check '["work_sequencing", "mem:g101", "mem:g103"]' "$(field "[ (d['kind'], d['out'], d['in']) for d in prog['decisions'] if d.get('kind') == 'work_sequencing' ][-1]")"
check 1 "$(grep -c '"item_swapped"' "${CLAUDE_AUTO_DATA_DIR}/programmes/${RUN}/journal.jsonl")"

it "the parked item shows in the waiting list with its reason"
prog status --run "$RUN"
has "${NS}101  size s5" "$OUT"

it "the newcomer then starts through the normal gate, freed points counted"
S2="$(spins)"
start 103
check 0 "$CODE"
check "$((S2 + 1))" "$(spins)"

it "a parked item cannot resume while its old pane still holds a live worker"
drop 103
snapshot p61:agent p62:agent
S3="$(spins)"
start 101
check 1 "$CODE"
has "p61" "$OUT"
has "wait for the worker to stop" "$OUT"
has "close the pane" "$OUT"
has "Next: once the old worker has stopped, start ${NS}101 again." "$OUT"
check "$S3" "$(spins)"

it "--despite focus does not bypass the old-worker check, even with an approved override"
approve_override 101
check 0 "$CODE"
start 101 --despite focus
check 1 "$CODE"
has "old worker still live" "$OUT"
check "$S3" "$(spins)"

it "focus-recheck leaves a parked item held while its old pane is live"
prog focus-recheck --run "$RUN"
check 0 "$CODE"
case "$(gitem 101 held)" in null) fail "recheck cleared a parked item with a live old worker" ;; *) pass ;; esac

it "after the old pane is gone the resume starts exactly one worker"
snapshot p62:agent
start 101
check 0 "$CODE"
check "$((S3 + 1))" "$(spins)"
check "null" "$(gitem 101 held)"
check "null" "$(gitem 101 parked_pane)"

# ---- review fixes: parked pane leaves the agent count; a replay is not re-gated ----
limit limited --points none --agents 2
mk 201 s1 p71
mk 202 s1
mk 203 s1 p73
snapshot p71:agent p73:agent
it "a first start with the agents limit full is still held"
start 202
check 1 "$CODE"
has "agents at limit: 2 of 2" "$OUT"
check '"agents at limit: 2 of 2"' "$(gitem 202 held)"

it "swap-item parks 201 and its still-live pane no longer counts: the newcomer is admitted"
PW="$(pickit "$(swap_label 201 202)")"
prog swap-item "${NS}201" "${NS}202" --prompt "$PW" --run "$RUN"
check 0 "$CODE"
S4="$(spins)"
start 202
check 0 "$CODE"
check "$((S4 + 1))" "$(spins)"
check "null" "$(gitem 202 held)"

it "the parked item still cannot resume while its old pane is live"
snapshot p71:agent p73:agent
S5="$(spins)"
start 201
check 1 "$CODE"
has "old worker still live in pane w2:p71" "$OUT"
check "$S5" "$(spins)"

it "a parked item stays held with its old pane live after the programme is set back to unlimited"
limit unlimited
start 201
check 1 "$CODE"
has "old worker still live in pane w2:p71" "$OUT"
has "Next: once the old worker has stopped, start ${NS}201 again." "$OUT"
check "$S5" "$(spins)"
prog focus-recheck --run "$RUN"
case "$(gitem 201 held)" in null) fail "recheck cleared a parked item under unlimited" ;; *) pass ;; esac
limit limited --points none --agents 2

it "a replayed start-worker --op with the agents limit exactly full is not held"
mk 204 s1
snapshot p73:agent
start 204 --op op-replay-1
check 0 "$CODE"
snapshot p73:agent p40:agent
S6="$(spins)"
start 204 --op op-replay-1
check 0 "$CODE"
has '"replayed": true' "$OUT"
check "null" "$(gitem 204 held)"
check "$S6" "$(spins)"

it "take-recommendations leaves focus_budget unlimited, set_by default, with no limits"
RUN2="$(run_py w9 <<'EOF2'
print(ph.create_programme([args[0]], "sess-pm")["run"])
EOF2
)"
PR="$(pickit "Take all recommendations" "$RUN2")"
prog take-recommendations --pick "$PR" --run "$RUN2"
check 0 "$CODE"
check '["unlimited", "default", null, null]' "$(run_py "$RUN2" <<'EOF2'
t = record(args[0])["programme"]["agreement"]["terms"]["focus_budget"]
print(json.dumps([t["value"], t["set_by"], t.get("points"), t.get("agents")]))
EOF2
)"

# ---- agreement text: scale and opt-in visibility ----
agreement_probe() {
  run_py "$1" "$2" <<'EOF2'
pv = load_lib_module("programme_view")
value, set_by = args[1].split("/")
term = {"value": value, "default": "unlimited", "options": ["unlimited", "limited"], "set_by": set_by,
        "points": 10, "agents": 3, "scale": {"s1": 1, "s3": 3}}
block = {"agreement": {"terms": {"focus_budget": term}}}
print(json.dumps([ph.term_extra_texts(term), pv.agreement_lines(block),
                  [t for t, _ in pv.rule_texts(block) if t.startswith("focus_budget")]]))
EOF2
}
LINE='focus_budget: limited, points 10, agents 3, scale s1=1 s3=3'
it "a limited focus_budget renders points, agents and the scale in the extras, the agreement and the rules"
check "[[\"points 10\", \"agents 3\", \"scale s1=1 s3=3\"], [\"${LINE}\"], [\"${LINE}\"]]" "$(agreement_probe "$RUN" limited/shawn)"

it "an opt-in focus_budget set to unlimited by Shawn still shows in the agreement"
has '"focus_budget: unlimited,' "$(agreement_probe "$RUN" unlimited/shawn)"

it "an opt-in focus_budget at its default value but set by default (not by Shawn) is hidden; limited by default shows"
check '[[], []]' "$(agreement_probe "$RUN" unlimited/default | "$PY" -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps([d[1], d[2]]))')"
has '"focus_budget: limited,' "$(agreement_probe "$RUN" limited/default)"

# ---- remit spaces on another herdr server cannot be counted ----
remit_space() {
  run_py "$RUN" "$1" <<'EOF2'
run, mode = args
def mutate(rec):
    spaces = rec["programme"]["remit"]["spaces"]
    spaces[:] = [s for s in spaces if s.get("server") != "elsewhere"]
    if mode == "add":
        spaces.append({"server": "elsewhere", "workspace": "w9"})
    return rec
core._with_locked_run_record(ph.home_path(run), run, mutate)
EOF2
}
snapshot
remit_space add

it "limit set + a remit space on another server holds the start and names that space"
limit limited --points 10 --agents 3 --run "$RUN"
mk 301 s1
start 301
check 1 "$CODE"
has "count unavailable" "$OUT"
has "elsewhere.w9" "$OUT"
has "override-focus ${NS}301" "$OUT"
check 'true' "$(field "bool(prog['items']['${NS}301']['held'])")"

it "an approved override still starts it when a remit space cannot be counted"
approve_override 301
check 0 "$CODE"
start 301 --despite focus
check 0 "$CODE"

it "status shows the counts as unavailable, not zero, when a remit space cannot be counted"
prog status --run "$RUN"
has "agents unavailable" "$OUT"
check 'null' "$(statusj | "$PY" -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["model"]["focus"]["agents"]["used"]))')"
drop 301

it "no limit set + a remit space on another server starts as before and reads no herdr"
limit unlimited --run "$RUN"
mk 302 s1
: > "$CALLS"
start 302
check 0 "$CODE"
check 0 "$(grep -c 'api snapshot' "$CALLS")"
drop 302
remit_space drop

echo ""
echo "through offer: $(grep -c '^offered$' "${WORK}/offered.log") offered, $(grep -c '^refused' "${WORK}/offered.log") refused"
grep '^refused' "${WORK}/offered.log"
echo "programme-focus-queue.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
