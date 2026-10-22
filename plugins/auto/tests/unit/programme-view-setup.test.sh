#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

echo "programme-view-setup.test.sh"

WORK="$(mktemp -d -t auto-programme-view-setup.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_MACHINE="studio"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_AUTO_TEST_HARNESS=1
export CLAUDE_CODE_SESSION_ID="sess-pm"
unset HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_BIN_PATH CLAUDE_AUTO_REPO 2>/dev/null || true
: > "$CLAUDE_AUTO_SECRETS_FILE"
mkdir -p "${WORK}/personal"

OUT="$("$PY" - "$AUTO_ROOT" "$WORK" <<'PYEOF' 2>&1
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
ph = load_lib_module("programme_home")
pv = load_lib_module("programme_view")
setup = load_lib_module("programme_view_setup")
work = sys.argv[2]
personal = os.environ["CLAUDE_AUTO_PERSONAL_PROTOCOL"]

def check(name, ok, detail=""):
    print(("ok|" if ok else "no|") + name + ("" if ok else "|" + str(detail)))

def fresh(**extra):
    block = ph.normalize_programme(ph.new_programme_block([("default", "w2")], "2026-10-20T00:00:00Z"))
    block.update(extra)
    return block

def keys(part):
    return [s["key"] for s in part["steps"]]

def step(part, key):
    return next(s for s in part["steps"] if s["key"] == key)

def states(part):
    return {s["key"]: s["state"] for s in part["steps"]}

terms = list(ph.TERM_GUIDE)
tail = ["rulings", "shared", "items", "accept"]

p = setup.build(fresh())
check("a fresh proposal lists the terms in agreement order, then rulings, shared, items and accept",
      keys(p) == terms + tail, keys(p))
check("the first unfinished step is current", p["current"] == terms[0] and states(p)[terms[0]] == "current"
      and all(states(p)[k] == "upcoming" for k in keys(p)[1:] if k != "items"), states(p))
check("with no probe recorded the items step is not done and the scope is not probed",
      states(p)["items"] != "done" and p["scope"]["probed"] is False, (states(p), p["scope"]))
check("each term step offers the term's option names",
      step(p, "cadence")["options"] == ["on_change", "fixed"]
      and step(p, "tools_of_record")["options"] == ["tracker", "tasks", "plans"], step(p, "cadence"))
check("a term left at the plugin default recommends it with that source",
      step(p, "cadence")["recommendation"] == "on_change" and step(p, "cadence")["recommendation_source"] == "plugin default",
      step(p, "cadence"))
check("each term step carries its group", all(step(p, k)["group"] == k for k in terms), [s["group"] for s in p["steps"]])
check("per-programme term steps need no typed reply", all(not step(p, k)["needs_typed"] and step(p, k)["reply"] is None
      for k in terms))
check("the walkthrough has no autonomy step", "autonomy" not in keys(p), keys(p))
check("accept always needs the typed line", step(p, "accept")["needs_typed"] and step(p, "accept")["reply"] == "accept the agreement",
      step(p, "accept"))

b = fresh()
b["agreement"]["terms"]["remit"]["set_by"] = "shawn"
b["agreement"]["terms"]["stop_rule"]["set_by"] = "proposal"
p = setup.build(b)
check("a term Shawn set is done, a term only proposed is not",
      states(p)["remit"] == "done" and states(p)["stop_rule"] == "current", states(p))
check("a proposed term recommends its value from the PM", step(p, "stop_rule")["recommendation_source"] == "PM proposal",
      step(p, "stop_rule"))

b = fresh()
b["agreement"]["terms"]["remit"]["set_by"] = "carried_over"
b["agreement"]["terms"]["stop_rule"]["set_by"] = "shawn"
b["setup"] = {"kept": ["cadence"]}
p = setup.build(b)
check("a carried-over term and a kept term count as done",
      states(p)["remit"] == "done" and states(p)["cadence"] == "done" and p["current"] == "tools_of_record", states(p))

b = fresh()
b["agreement"]["terms"]["handover"] = {"key": "handover", "options": ["slack", "linear"], "value": "slack",
                                       "default": "slack", "set_by": "proposal", "section": "people"}
p = setup.build(b)
check("a new term in the agreement data adds a step with no code change",
      keys(p) == terms + ["handover"] + tail, keys(p))
check("the new term carries the section its data names", step(p, "handover")["group"] == "people", step(p, "handover"))
check("the new term offers the options its data names", step(p, "handover")["options"] == ["slack", "linear"],
      step(p, "handover"))

b = fresh()
b["agreement"]["terms"]["tools_of_record"]["proposal"] = {"state": "pending", "origin": "pm",
                                                         "value": ["tracker", "wiki"], "extras": {"add": "wiki"}}
p = setup.build(b)
check("a pending proposed new source is offered as an option, as pick-term accepts it",
      step(p, "tools_of_record")["options"] == ["tracker", "tasks", "plans", "wiki"], step(p, "tools_of_record"))

p = setup.build(fresh())
check("shared settings with no personal file are not done", step(p, "shared")["state"] != "done"
      and step(p, "shared")["needs_typed"], step(p, "shared"))
with open(personal, "w") as fh:
    json.dump({"protocol_format": 1, "rules": [], "autonomy": {}}, fh)
p = setup.build(fresh())
check("shared settings already set show as done with using existing",
      step(p, "shared")["state"] == "done" and step(p, "shared")["values"] == "using existing", step(p, "shared"))
p = setup.build(fresh(proposed_rules=[{"id": "r1", "when": "x", "autonomy": "ask"}]))
check("shared settings stay undone while a shared rule is proposed, even with a personal file",
      step(p, "shared")["state"] != "done", step(p, "shared"))
os.remove(personal)

b = fresh()
b["agreement"]["project_terms"] = [{"id": "t1", "area": "deploys", "value": "ask first", "set_by": "proposal",
                                    "reserved": True}]
p = setup.build(b)
check("a proposed ruling needs a typed reply", step(p, "rulings")["needs_typed"]
      and isinstance(step(p, "rulings")["reply"], str) and step(p, "rulings")["state"] != "done", step(p, "rulings"))
b["setup"] = {"kept": ["rulings", "shared"]}
p = setup.build(b)
check("a typed-reply step listed in kept is done with no reply",
      step(p, "rulings")["state"] == "done" and step(p, "rulings")["reply"] is None
      and step(p, "shared")["state"] == "done" and step(p, "shared")["reply"] is None, [step(p, "rulings"), step(p, "shared")])

b = fresh()
b["setup"] = {"step": "cadence"}
p = setup.build(b)
check("a stored step naming an unfinished step makes it current",
      p["current"] == "cadence" and states(p)["cadence"] == "current" and states(p)["remit"] == "upcoming", states(p))
b["agreement"]["terms"]["cadence"]["set_by"] = "shawn"
p = setup.build(b)
check("a stored step naming a done step falls back to the first unfinished one", p["current"] == "remit", states(p))
b["setup"] = {"step": "no-such-step"}
p = setup.build(b)
check("a stored step naming an unknown step falls back to the first unfinished one", p["current"] == "remit", states(p))
check("exactly one step is current", list(states(p).values()).count("current") == 1, states(p))

b = fresh()
b["agreement"]["terms"]["remit"]["value"] = "tabs"
b["remit"]["tabs"] = ["tab-a"]
b["remit"]["repos"] = [{"github": "org/kept", "path": "/x/kept"}]
b["remit"]["tracker"]["projects"] = [{"key": "cue", "name": "Cue"}]
b["setup"] = {"seen": {"tabs": ["tab-a", "tab-b"], "repos": ["org/kept", "org/other"],
                       "tracker": ["cue", "growth"], "items": []}}
p = setup.build(b)
check("a remit narrower than the sources seen lists the excluded tabs, repos and tracker under out",
      p["scope"]["out"] == {"tabs": ["tab-b"], "repos": ["org/other"], "tracker": ["growth"]}, p["scope"])
check("in lists the remit's own scope", "org/kept" in p["scope"]["in"]["repos"] and p["scope"]["in"]["tabs"] == ["tab-a"],
      p["scope"])
b["agreement"]["terms"]["remit"]["value"] = "space"
p = setup.build(b)
check("a whole-space remit leaves no tab out", p["scope"]["out"]["tabs"] == [], p["scope"])
check("a recorded probe with an empty items list is probed and leaves nothing to adopt",
      p["scope"]["probed"] is True and states(p)["items"] == "done", (p["scope"], states(p)))

b = fresh()
b["items"] = {"linear:AI-1": ph.new_item("linear:AI-1", "One", now_iso="2026-10-20T00:00:00Z")}
b["setup"] = {"seen": {"items": [{"item": "linear:AI-1", "title": "One", "pane": None, "session": None},
                                 {"item": "linear:AI-2", "title": "Two", "pane": "w2:p1", "session": "s2"}]}}
p = setup.build(b)
adopted = {i["item"]: i["adopted"] for i in step(p, "items")["items"]}
check("the items step marks items already adopted", adopted == {"linear:AI-1": True, "linear:AI-2": False}, step(p, "items"))
check("the items step recommends adopting from the sweep", step(p, "items")["recommendation_source"] == "sweep",
      step(p, "items"))

for label, seen in (("missing", None), ("empty", {}), ("malformed", "junk")):
    b = fresh()
    if seen is not None:
        b["setup"] = {"seen": seen}
    try:
        p = setup.build(b)
        check(f"{label} setup.seen yields an items step with no items and an empty out list",
              step(p, "items")["items"] == [] and p["scope"]["out"] == {"tabs": [], "repos": [], "tracker": []}, p)
        check(f"{label} setup.seen is not probed and keeps the items step undone",
              p["scope"]["probed"] is False and states(p)["items"] != "done", (p["scope"], states(p)))
    except Exception as exc:
        check(f"{label} setup.seen yields an items step with no items and an empty out list", False, repr(exc))

b = fresh()
b["agreement"]["accepted"] = {"at": "2026-10-20T01:00:00Z", "prompt_id": "p1", "quote": "accept the agreement"}
check("after acceptance the setup part is absent", setup.build(b) is None)

record = {"run_id": "r1", "programme": fresh()}
view = pv.build(record, [])
check("the view carries the setup part before acceptance", isinstance(view.get("setup"), dict)
      and view["setup"]["current"] == terms[0], view.get("setup"))
check("the view keeps format 3", view["view_format"] == 3)
record["programme"]["agreement"]["accepted"] = {"at": "2026-10-20T01:00:00Z", "prompt_id": "p1", "quote": "go"}
check("the view drops the setup part after acceptance", "setup" not in pv.build(record, []))
PYEOF
)"

PASS=0
FAIL=0
while IFS='|' read -r verdict name detail; do
  case "$verdict" in
    ok) PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$name" ;;
    no) FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n      %s\n" "$name" "$detail" ;;
    *) FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m unexpected output: %s\n" "$verdict${name:+|$name}" ;;
  esac
done <<< "$OUT"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] && [ "$PASS" -gt 0 ]
