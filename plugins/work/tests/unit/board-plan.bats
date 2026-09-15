#!/usr/bin/env bats

load setup_common

# U6 — the placement engine and classifier. Pure: every input is a file, the
# answer is one JSON document, and nothing here talks to herdr or Linear.
#
# The fixtures describe a board that agrees everywhere: space WEB holds tab
# "Ana" (column Todo: WEB-1 over WEB-6, column In Progress: WEB-3) and tab
# "No assignee" (WEB-2); space OPS holds tab "Ben" (OPS-4). Each test changes
# one fact and reads what the engine concludes.

bats_require_minimum_version 1.5.0

setup() {
    LIB_DIR="${BATS_TEST_DIRNAME}/../../lib"
    FIX="${BATS_TEST_DIRNAME}/../fixtures/board"
    # shellcheck source=/dev/null
    . "$LIB_DIR/board-plan.sh"
    IN="$BATS_TEST_TMPDIR/input.json"
    OUT="$BATS_TEST_TMPDIR/plan.json"
    python3 - "$FIX" "$IN" <<'PY'
import json, sys, os
fix, out = sys.argv[1], sys.argv[2]
load = lambda n: json.load(open(os.path.join(fix, n)))
tickets = load("tickets.json")
doc = {
    "config": load("config.json"),
    "reads": [
        {"mapping": "global", "complete": True, "tickets": tickets},
        {"mapping": "Mine", "complete": True, "tickets": []},
        {"mapping": "Later", "complete": True, "tickets": []},
    ],
    "snapshot": load("snapshot.json"),
    "layouts": load("layouts.json"),
    "ledger": load("ledger.json"),
    "previous": load("sync-state.json"),
    "in_use": {"invoking_pane_id": None, "treat_all_in_use": False},
    "writes_enabled": True,
}
json.dump(doc, open(out, "w"), indent=1)
PY
}

# edit '<python statements over d>' — d is the input document; T(id) is that
# ticket in the global read, P(id) that pane in the snapshot.
edit() {
    python3 - "$IN" "$1" <<'PY'
import json, sys
path, code = sys.argv[1], sys.argv[2]
d = json.load(open(path))
snap = d["snapshot"]["result"]["snapshot"]
def read(m): return next(r for r in d["reads"] if r["mapping"] == m)
def T(i): return next(t for t in read("global")["tickets"] if t["id"] == i)
def P(i): return next(p for p in snap["panes"] if p["pane_id"] == i)
def drop_pane(i):
    snap["panes"] = [p for p in snap["panes"] if p["pane_id"] != i]
def pane(i): return {"type": "pane", "pane_id": i}
def split(direction, a, b): return {"type": "split", "direction": direction, "ratio": 0.5, "first": a, "second": b}
def layout(tab, root): d["layouts"][tab] = {"tab_id": tab, "root": root}
exec(code)
json.dump(d, open(path, "w"), indent=1)
PY
}

plan() {
    run herdr_linear::board_plan "$IN"
    [ "$status" -eq 0 ]
    printf '%s' "$output" > "$OUT"
}

# ask '<python expression over p>' — p is the plan; A(kind, issue) lists the
# matching actions, either argument None for any.
ask() {
    python3 - "$OUT" "$1" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
def A(kind=None, issue=None, space=None):
    return [a for a in p["actions"] if (kind is None or a["kind"] == kind)
            and (issue is None or a["issue_id"] == issue) and (space is None or a["space"] == space)]
def S(name): return next(s for s in p["spaces"] if s["name"] == name)
def tab(space, name): return next(t for t in S(space)["tabs"] if t["name"] == name)
def leaves(node):
    if node["type"] == "split":
        return leaves(node["first"]) + leaves(node["second"])
    return [node]
def columns(node):
    if node["type"] == "split" and node["direction"] == "right":
        return columns(node["first"]) + columns(node["second"])
    return [node]
def issues(node): return [l.get("issue_id") for l in leaves(node) if l["type"] == "pane"]
v = eval(sys.argv[2])
print(json.dumps(v, sort_keys=True))
PY
}

# ------------------------------------------------------------ the agreed board

@test "a board where Linear, herdr and the ledger agree produces no action" {
    plan
    run ask 'A()'
    [ "$output" = "[]" ]
    run ask 'p["complete"]'
    [ "$output" = "true" ]
    run ask 'p["members"]'
    [ "$output" = '["iss-1", "iss-2", "iss-3", "iss-4", "iss-6"]' ]
}

# Live boards repeat names across teams: every team has its own "In Progress".
@test "a tab label two groups share is read as the group its own space renders, not as outside the board" {
    edit 'T("iss-4")["assignee"] = {"id": "user-ana-ops", "name": "Ana"}'
    plan
    run ask 'A("hide")'
    [ "$output" = "[]" ]
    run ask 'A(None, "iss-1") + A(None, "iss-3") + A(None, "iss-6")'
    [ "$output" = "[]" ]
}

@test "the same inputs always produce the same bytes" {
    edit 'T("iss-1")["state"] = {"id": "st-prog", "name": "In Progress", "type": "started"}; read("Mine")["tickets"] = [T("iss-3")]'
    plan
    cp "$OUT" "$BATS_TEST_TMPDIR/first.json"
    plan
    cmp "$OUT" "$BATS_TEST_TMPDIR/first.json"
    run ask 'len(A())'
    [ "$output" -gt 0 ]
}

@test "malformed input is refused with a named fault and exit 2" {
    printf '{"config": 1}' > "$IN"
    run herdr_linear::board_plan "$IN"
    [ "$status" -eq 2 ]
    [[ "$output" == *"refused"* ]]
    run herdr_linear::board_plan "$BATS_TEST_TMPDIR/absent.json"
    [ "$status" -eq 2 ]
    run herdr_linear::board_plan
    [ "$status" -eq 3 ]
}

# ------------------------------------------------------------ placement

@test "AE2: an unassigned ticket under an assignee tab level lands in No assignee" {
    edit 'd["ledger"] = {}; d["previous"] = {}'
    plan
    run ask '[a["kind"] for a in A(issue="iss-2")]'
    [ "$output" = '["place"]' ]
    run ask 'A("place", "iss-2")[0]["tab"]'
    [ "$output" = '"No assignee"' ]
    run ask 'issues(tab("WEB", "No assignee")["tree"])'
    [ "$output" = '["iss-2"]' ]
    run ask 'A("place", "iss-2")[0]["groups"]["assignee"]'
    [ "$output" = "null" ]
}

@test "groups are ordered stably: state columns by state type, No groups last" {
    edit 'd["ledger"] = {}; d["previous"] = {}'
    plan
    run ask '[t["name"] for t in S("WEB")["tabs"]]'
    [ "$output" = '["Ana", "No assignee"]' ]
    run ask '[issues(c) for c in columns(tab("WEB", "Ana")["tree"])]'
    [ "$output" = '[["iss-1", "iss-6"], ["iss-3"]]' ]
    run ask 'p["rendered"]["WEB"]["state"]'
    [ "$output" = '["st-todo", "st-prog"]' ]
}

@test "AE11: a ticket claimed by the global mapping and an override has a home and a pointer" {
    edit 'read("Mine")["tickets"] = [T("iss-1")]'
    plan
    run ask '[(a["kind"], a["space"], a["role"]) for a in A(issue="iss-1")]'
    [ "$output" = '[["place", "Mine", "pointer"]]' ]
    run ask 'issues(tab("Mine", "High")["tree"])'
    [ "$output" = '["iss-1"]' ]
    run ask '[l["role"] for l in leaves(tab("Mine", "High")["tree"])]'
    [ "$output" = '["pointer"]' ]
    run ask '[l["pane_id"] for l in leaves(tab("WEB", "Ana")["tree"]) if l.get("issue_id") == "iss-1"]'
    [ "$output" = '["w1:p1"]' ]
}

@test "a ticket claimed only by two overrides takes its home in the first space in configuration order" {
    edit '
t = dict(T("iss-1")); t["id"] = "iss-5"; t["identifier"] = "WEB-5"
read("Later")["tickets"] = [t]
read("Mine")["tickets"] = [t]'
    plan
    run ask 'sorted((a["space"], a["role"]) for a in A("place", "iss-5"))'
    [ "$output" = '[["Later", "pointer"], ["Mine", "home"]]' ]
}

@test "a sub-ticket level nests a child under its parent's column, and a parent outside the view still gets one" {
    edit '
d["config"]["global"]["levels"] = {"space": "team", "column": "sub-ticket"}
d["ledger"] = {}; d["previous"] = {}
base = T("iss-1")
def mk(i, ident, parent):
    t = dict(base); t["id"] = i; t["identifier"] = ident; t["parent"] = parent; return t
read("global")["tickets"] = [
    mk("iss-12", "WEB-12", {"id": "iss-99", "identifier": "WEB-99"}),
    mk("iss-11", "WEB-11", {"id": "iss-10", "identifier": "WEB-10"}),
    mk("iss-10", "WEB-10", None)]'
    plan
    run ask '[issues(c) for c in columns(S("WEB")["tabs"][0]["tree"])]'
    [ "$output" = '[["iss-10", "iss-11"], ["iss-12"]]' ]
    run ask '[c["type"] for c in columns(S("WEB")["tabs"][0]["tree"])]'
    [ "$output" = '["split", "pane"]' ]
    run ask 'p["rendered"]["WEB"]["sub-ticket"]'
    [ "$output" = '["iss-10", "iss-99"]' ]
}

@test "a label-group level uses the one label whose parent is the named group" {
    edit '
d["config"]["global"]["levels"] = {"space": "team", "tab": "label-group:Area"}
d["ledger"] = {}; d["previous"] = {}
T("iss-1")["labels"]["nodes"] = [
    {"id": "lab-bug", "name": "Bug", "parent": None},
    {"id": "lab-front", "name": "Frontend", "parent": {"id": "lab-area", "name": "Area"}}]'
    plan
    run ask 'A("place", "iss-1")[0]["tab"]'
    [ "$output" = '"Frontend"' ]
    run ask 'A("place", "iss-3")[0]["tab"]'
    [ "$output" = '"No Area"' ]
}

# ------------------------------------------------------------ classification

@test "ledger and Linear agree, herdr differs: a herdr move becomes a write-back candidate" {
    edit 'layout("w1:t1", split("right", split("down", pane("w1:p3"), pane("w1:p6")), pane("w1:p1")))'
    plan
    run ask '[(a["kind"], a["field"], a["write_field"], a["target_value"]) for a in A(issue="iss-1")]'
    [ "$output" = '[["write-back-candidate", "state", "stateId", "st-prog"]]' ]
    run ask '[(a["kind"], a["target_value"]) for a in A(issue="iss-3")]'
    [ "$output" = '[["write-back-candidate", "st-todo"]]' ]
    run ask 'len(A("move"))'
    [ "$output" = "0" ]
}

@test "with Linear writes off, a herdr move is restored and nothing is written" {
    edit 'layout("w1:t1", split("right", split("down", pane("w1:p3"), pane("w1:p6")), pane("w1:p1"))); d["writes_enabled"] = False'
    plan
    run ask '[(a["kind"], a["reason"]) for a in A(issue="iss-1")]'
    [ "$output" = '[["move", "restore"]]' ]
    run ask 'len(A("write-back-candidate"))'
    [ "$output" = "0" ]
}

@test "ledger and herdr agree, Linear differs: a Linear change moves the pane" {
    edit 'T("iss-1")["state"] = {"id": "st-prog", "name": "In Progress", "type": "started"}'
    plan
    run ask '[(a["kind"], a["reason"], a["pane_id"], a["groups"]["state"]) for a in A(issue="iss-1")]'
    [ "$output" = '[["move", "linear-change", "w1:p1", "st-prog"]]' ]
    run ask '[issues(c) for c in columns(tab("WEB", "Ana")["tree"])]'
    [ "$output" = '[["iss-6"], ["iss-1", "iss-3"]]' ]
    run ask 'len(A("write-back-candidate"))'
    [ "$output" = "0" ]
}

@test "both differ to the same value: agreement updates the ledger and moves nothing" {
    edit '
T("iss-2")["assignee"] = {"id": "user-ana", "name": "Ana"}
P("w1:p2")["tab_id"] = "w1:t1"
layout("w1:t1", split("right", split("down", pane("w1:p1"), split("down", pane("w1:p6"), pane("w1:p2"))), pane("w1:p3")))
del d["layouts"]["w1:t2"]
snap["tabs"] = [t for t in snap["tabs"] if t["tab_id"] != "w1:t2"]'
    plan
    run ask '[(a["kind"], a["groups"]["assignee"]) for a in A(issue="iss-2")]'
    [ "$output" = '[["agreement", "user-ana"]]' ]
    run ask 'len(A("move")) + len(A("write-back-candidate")) + len(A("conflict-question"))'
    [ "$output" = "0" ]
}

@test "both differ to different values: a conflict question, and neither a move nor a write-back" {
    edit '
T("iss-2")["assignee"] = {"id": "user-cy", "name": "Cy"}
P("w1:p2")["tab_id"] = "w1:t1"
layout("w1:t1", split("right", split("down", pane("w1:p1"), split("down", pane("w1:p6"), pane("w1:p2"))), pane("w1:p3")))
del d["layouts"]["w1:t2"]
snap["tabs"] = [t for t in snap["tabs"] if t["tab_id"] != "w1:t2"]'
    plan
    run ask '[(a["kind"], a["fields"]) for a in A(issue="iss-2")]'
    [ "$output" = '[["conflict-question", ["assignee"]]]' ]
}

@test "a ledger entry pending a Linear change is never read as a herdr move" {
    edit '
d["ledger"]["WEB"]["iss-1"]["pending_linear_change"] = True
layout("w1:t1", split("right", pane("w1:p6"), split("down", pane("w1:p1"), pane("w1:p3"))))'
    plan
    run ask '[(a["kind"], a["reason"]) for a in A(issue="iss-1")]'
    [ "$output" = '[["move", "restore"]]' ]
    run ask 'len(A("write-back-candidate"))'
    [ "$output" = "0" ]

    edit 'd["ledger"]["WEB"]["iss-1"]["pending_linear_change"] = False'
    plan
    run ask '[a["kind"] for a in A(issue="iss-1")]'
    [ "$output" = '["write-back-candidate"]' ]
}

@test "an incomplete read never classifies a ticket as leaving" {
    edit 'read("global")["tickets"] = [t for t in read("global")["tickets"] if t["id"] != "iss-4"]; read("global")["complete"] = False'
    plan
    run ask 'A(issue="iss-4")'
    [ "$output" = "[]" ]
    run ask 'p["complete"]'
    [ "$output" = "false" ]
    run ask '[l["pane_id"] for l in leaves(tab("OPS", "Ben")["tree"])]'
    [ "$output" = '["w2:p4"]' ]

    edit 'read("global")["complete"] = True'
    plan
    run ask '[(a["kind"], a["pane_id"]) for a in A(issue="iss-4")]'
    [ "$output" = '[["close-question", "w2:p4"]]' ]
}

@test "AE13: a home pane missing by id, alias and board label hides its ticket, and stays hidden" {
    edit 'drop_pane("w1:p3"); layout("w1:t1", split("down", pane("w1:p1"), pane("w1:p6")))'
    plan
    run ask '[(a["kind"], a["fingerprint"]) for a in A(issue="iss-3")]'
    [ "$output" = '[["hide", "2026-09-10T10:00:00.000Z"]]' ]
    run ask 'issues(tab("WEB", "Ana")["tree"])'
    [ "$output" = '["iss-1", "iss-6"]' ]

    edit 'd["ledger"]["WEB"]["iss-3"]["hidden"] = True; d["ledger"]["WEB"]["iss-3"]["hidden_fingerprint"] = "2026-09-10T10:00:00.000Z"'
    plan
    run ask 'A(issue="iss-3")'
    [ "$output" = "[]" ]

    edit 'T("iss-3")["updatedAt"] = "2026-09-11T09:00:00.000Z"'
    plan
    run ask 'sorted(a["kind"] for a in A(issue="iss-3"))'
    [ "$output" = '["place", "unhide"]' ]
}

@test "a home pane found by alias or by board label is not hidden" {
    edit '
drop_pane("w1:p3")
snap["panes"].append({"pane_id": "w1:p7", "tab_id": "w1:t1", "workspace_id": "w1", "agent": None})
layout("w1:t1", split("right", split("down", pane("w1:p1"), pane("w1:p6")), pane("w1:p7")))
d["aliases"] = {"w1:p3": "w1:p7"}'
    plan
    run ask '[(a["kind"], a["pane_id"]) for a in A(issue="iss-3")]'
    [ "$output" = '[["relink", "w1:p7"]]' ]

    edit 'd["aliases"] = {}; P("w1:p7")["label"] = "work:iss-3"'
    plan
    run ask '[a["kind"] for a in A(issue="iss-3")]'
    [ "$output" = '["relink"]' ]
    run ask 'len(A("hide"))'
    [ "$output" = "0" ]
    run ask '[l["board_label"] for l in leaves(tab("WEB", "Ana")["tree"]) if l.get("issue_id") == "iss-3"]'
    [ "$output" = '["work:iss-3"]' ]
}

@test "a pointer pane is found by its own space's pointer label, and never by the home label" {
    key="$(printf '%s' Mine | shasum | cut -c1-16)"
    edit '
read("Mine")["tickets"] = [T("iss-1")]
snap["workspaces"].append({"workspace_id": "w3", "label": "Mine"})
snap["tabs"].append({"tab_id": "w3:t1", "workspace_id": "w3", "label": "High"})
snap["panes"].append({"pane_id": "w3:p9", "tab_id": "w3:t1", "workspace_id": "w3", "agent": None, "label": "work:iss-1"})
layout("w3:t1", pane("w3:p9"))
d["ledger"]["Mine"] = {"iss-1": {"pane_id": "w3:p1", "role": "pointer", "board_created": True, "hidden": False,
                                 "hidden_fingerprint": "", "pending_linear_change": False, "groups": {"priority": "2"}}}'
    plan
    run ask '[a["kind"] for a in A(issue="iss-1", space="Mine")]'
    [ "$output" = '["recreate-pointer"]' ]

    edit "P(\"w3:p9\")[\"label\"] = \"work:iss-1:pointer:$key\""
    plan
    run ask '[(a["kind"], a["pane_id"]) for a in A(issue="iss-1", space="Mine")]'
    [ "$output" = '[["relink", "w3:p9"]]' ]
    run ask '[l["board_label"] for l in leaves(tab("Mine", "High")["tree"])]'
    [ "$output" = "[\"work:iss-1:pointer:$key\"]" ]
}

@test "every ledger pane in a space missing re-places the space and hides nothing" {
    edit '
for i in ("w1:p1", "w1:p2", "w1:p3", "w1:p6"): drop_pane(i)
snap["workspaces"] = [w for w in snap["workspaces"] if w["workspace_id"] != "w1"]'
    plan
    run ask 'sorted((a["issue_id"], a["reason"]) for a in A("place", space="WEB"))'
    [ "$output" = '[["iss-1", "rebuilt"], ["iss-2", "rebuilt"], ["iss-3", "rebuilt"], ["iss-6", "rebuilt"]]' ]
    run ask 'len(A("hide")) + len(A("close-question"))'
    [ "$output" = "0" ]
}

@test "a missing pointer pane is recreated and its ticket stays visible" {
    edit '
read("Mine")["tickets"] = [T("iss-1"), T("iss-3")]
snap["workspaces"].append({"workspace_id": "w3", "label": "Mine"})
snap["tabs"] += [{"tab_id": "w3:t1", "workspace_id": "w3", "label": "High"}, {"tab_id": "w3:t2", "workspace_id": "w3", "label": "Urgent"}]
snap["panes"].append({"pane_id": "w3:p1", "tab_id": "w3:t1", "workspace_id": "w3", "agent": None})
layout("w3:t1", pane("w3:p1"))
entry = lambda pane, pr: {"pane_id": pane, "role": "pointer", "board_created": True, "hidden": False,
                          "hidden_fingerprint": "", "pending_linear_change": False, "groups": {"priority": pr}}
d["ledger"]["Mine"] = {"iss-1": entry("w3:p1", "2"), "iss-3": entry("w3:p2", "1")}'
    plan
    run ask '[(a["kind"], a["space"]) for a in A(issue="iss-3")]'
    [ "$output" = '[["recreate-pointer", "Mine"]]' ]
    run ask 'A(issue="iss-1")'
    [ "$output" = "[]" ]
    run ask 'issues(tab("WEB", "Ana")["tree"])'
    [ "$output" = '["iss-1", "iss-6", "iss-3"]' ]
}

@test "a column change in a tab that lost a pane since the last sync is a conflict, not a herdr move" {
    edit 'drop_pane("w1:p6"); layout("w1:t1", split("right", pane("w1:p3"), pane("w1:p1")))'
    plan
    run ask '[(a["kind"], a["reason"]) for a in A(issue="iss-1")]'
    [ "$output" = '[["conflict-question", "tab-lost-a-pane"]]' ]
    run ask 'len(A("write-back-candidate"))'
    [ "$output" = "0" ]
    run ask '[a["kind"] for a in A(issue="iss-6")]'
    [ "$output" = '["hide"]' ]
}

@test "a pane dropped off the grid is a conflict, never a write-back" {
    edit 'layout("w1:t1", split("down", pane("w1:p1"), split("right", pane("w1:p6"), pane("w1:p3"))))'
    plan
    run ask 'sorted((a["issue_id"], a["reason"]) for a in A("conflict-question"))'
    [ "$output" = '[["iss-3", "ambiguous-layout"], ["iss-6", "ambiguous-layout"]]' ]
    run ask 'len(A("write-back-candidate")) + len(A("move"))'
    [ "$output" = "0" ]
}

@test "a board pane moved into a tab or space the board did not render hides its ticket and writes nothing" {
    edit '
snap["tabs"].append({"tab_id": "w1:t9", "workspace_id": "w1", "label": "Parking"})
P("w1:p3")["tab_id"] = "w1:t9"
layout("w1:t9", pane("w1:p3"))
layout("w1:t1", split("down", pane("w1:p1"), pane("w1:p6")))'
    plan
    run ask '[(a["kind"], a["reason"]) for a in A(issue="iss-3")]'
    [ "$output" = '[["hide", "moved-out-of-board"]]' ]

    # "Ben" is a real assignee group, but only in space OPS: WEB never rendered it.
    edit 'next(x for x in snap["tabs"] if x["tab_id"] == "w1:t9")["label"] = "Ben"'
    plan
    run ask '[(a["kind"], a["reason"]) for a in A(issue="iss-3")]'
    [ "$output" = '[["hide", "moved-out-of-board"]]' ]

    edit '
P("w1:p3")["tab_id"] = "w9:t1"; P("w1:p3")["workspace_id"] = "w9"
layout("w9:t1", split("right", pane("w9:p9"), pane("w1:p3")))
del d["layouts"]["w1:t9"]'
    plan
    run ask '[(a["kind"], a["reason"]) for a in A(issue="iss-3")]'
    [ "$output" = '[["hide", "moved-out-of-board"]]' ]
    run ask 'len(A("move")) + len(A("write-back-candidate"))'
    [ "$output" = "0" ]
}

@test "a pane not marked board-created is never in a move or a close" {
    edit '
d["ledger"]["OPS"]["iss-4"]["board_created"] = False
T("iss-4")["state"] = {"id": "st-ops-doing", "name": "Doing", "type": "started"}'
    plan
    run ask '[a["kind"] for a in A(issue="iss-4")]'
    [ "$output" = "[]" ]

    edit 'read("global")["tickets"] = [t for t in read("global")["tickets"] if t["id"] != "iss-4"]'
    plan
    run ask '[a["kind"] for a in A(issue="iss-4") if a["kind"] in ("move", "move-question", "close-question")]'
    [ "$output" = "[]" ]
}

@test "a move of a pane in use is a question: the invoking pane, the focused pane, a pane with an agent" {
    edit 'T("iss-1")["state"] = {"id": "st-prog", "name": "In Progress", "type": "started"}'
    plan
    run ask '[a["kind"] for a in A(issue="iss-1")]'
    [ "$output" = '["move"]' ]

    edit 'd["in_use"]["invoking_pane_id"] = "w1:p1"'
    plan
    run ask '[(a["kind"], a["in_use"]) for a in A(issue="iss-1")]'
    [ "$output" = '[["move-question", true]]' ]

    edit 'd["in_use"]["invoking_pane_id"] = None; snap["focused_pane_id"] = "w1:p1"'
    plan
    run ask '[a["kind"] for a in A(issue="iss-1")]'
    [ "$output" = '["move-question"]' ]

    edit 'snap["focused_pane_id"] = "w9:p9"; P("w1:p1")["agent"] = "claude"'
    plan
    run ask '[a["kind"] for a in A(issue="iss-1")]'
    [ "$output" = '["move-question"]' ]

    edit 'P("w1:p1")["agent"] = None; d["in_use"]["treat_all_in_use"] = True'
    plan
    run ask '[a["kind"] for a in A(issue="iss-1")]'
    [ "$output" = '["move-question"]' ]
}
