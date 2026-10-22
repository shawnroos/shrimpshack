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
lacks() { case "$2" in *"$1"*) fail "did not expect [$1] in [$2]" ;; *) pass ;; esac; }

echo "programme-trajectory.test.sh"

WORK="$(mktemp -d -t auto-programme-trajectory.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_MACHINE="studio"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_CODE_SESSION_ID="sess-pm"
unset HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH CLAUDE_AUTO_REPO 2>/dev/null || true
: > "$CLAUDE_AUTO_SECRETS_FILE"

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import io, json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
ph = load_lib_module("programme_home")
pj = load_lib_module("programme_journal")
core = load_lib_module("run_record_core")
args = sys.argv[2:]
def record(run):
    return core.read_run_record(ph.home_path(run), run)
$(cat)
PYEOF
}

RUN="$(run_py <<'EOF'
print(ph.create_programme(["w2"], "sess-pm")["run"])
EOF
)"
HOME_DIR="${CLAUDE_AUTO_DATA_DIR}/programmes/${RUN}"
RECORD_FILE="$(run_py "$RUN" <<'EOF'
print(core.run_record_path(ph.home_path(args[0]), args[0]))
EOF
)"

field() {
  run_py "$RUN" "$1" <<'EOF'
run, expr = args
rec = record(run)
prog = rec["programme"]
print(json.dumps(eval(expr), sort_keys=True))
EOF
}

edit() {
  run_py "$RUN" "$1" <<'EOF'
run, expr = args
sys.path.insert(0, os.path.join(sys.argv[1], "tests", "helpers"))
import programme_records
programme_records.edit(run, expr, globals())
EOF
}

count_kind() {
  run_py "$RUN" "$1" <<'EOF'
run, kind = args
print(sum(1 for row in pj.read(run) if row["kind"] == kind))
EOF
}

OUT=""
CODE=0
prog() {
  OUT="$("$PY" "$PROG" "$@" 2>&1)"
  CODE=$?
}
record_traj() {
  OUT="$(printf '%s' "$1" | "$PY" "$PROG" record-trajectories 2>&1)"
  CODE=$?
}

prog add-item linear:AI-1 --title "View test"
prog add-item linear:AI-2 --title "Docs pass"
prog add-item linear:AI-3 --title "Finished one"
edit 'rec["programme"]["items"]["linear:AI-3"]["state"] = "done"'
edit 'rec["programme"].setdefault("instructions", []).append({"id": "i0a1b2c", "state": "active", "applies_to": "programme", "at": "2026-10-19T00:00:00Z", "quote": "keep PRs small", "prompt_id": "p0000001", "until": None, "why": None, "closed": None})'
RULE_ID="$(run_py "$RUN" <<'EOF'
prog = load_lib_module("programme")
print(prog.rules_in_force(record(args[0]))["rules"][0]["id"])
EOF
)"

it "describe lists record-trajectories"
has '"record-trajectories"' "$("$PY" "$PROG" describe 2>/dev/null)"

edit 'del rec["programme"]["items"]["linear:AI-1"]["trajectory"]; del rec["programme"]["trajectory_sweeps"]'
it "the record is old-shaped: no item trajectory and no trajectory_sweeps on disk"
check '["missing", "missing"]' "$(field '[prog["items"]["linear:AI-1"].get("trajectory", "missing"), prog.get("trajectory_sweeps", "missing")]')"
it "an old record normalises to a None trajectory and empty trajectory_sweeps"
check '[null, []]' "$(run_py "$RUN" <<'EOF'
prog = ph.normalize_programme(record(args[0])["programme"])
print(json.dumps([prog["items"]["linear:AI-1"]["trajectory"], prog["trajectory_sweeps"]]))
EOF
)"

it "empty input writes nothing and journals nothing"
BEFORE="$(shasum "$RECORD_FILE")"
record_traj '[]'
check 0 "$CODE"
check "$BEFORE" "$(shasum "$RECORD_FILE")"
check 0 "$(count_kind trajectory_changed)"

BIG="$("$PY" -c 'import json; print(json.dumps([{"item": "linear:AI-1", "done": [], "current": {"title": "x" * 100, "clause": None}, "planned": [], "finish": "PR"}] * 12000))')"
it "input over the byte cap is refused whole"
BEFORE="$(shasum "$RECORD_FILE")"
record_traj "$BIG"
check 2 "$CODE"
has "larger than" "$OUT"
it "the over-cap refusal leaves the record unchanged"
check "$BEFORE" "$(shasum "$RECORD_FILE")"

FIRST='[
 {"item": "linear:AI-1", "done": [],
  "current": {"title": "Write view test", "clause": "term:cadence"},
  "planned": [{"title": "Run auto suite", "clause": "rule:'"$RULE_ID"'"},
              {"title": "Open PR", "clause": "instruction:i0a1b2c"}],
  "finish": "merged PR", "location": {"tab": "AI-Editor", "pane": "owner-history"}},
 {"item": "linear:AI-2", "done": [],
  "current": {"title": "Install toolchain", "clause": null},
  "planned": [{"title": "Edit docs", "clause": "instruction:i9999999"}],
  "finish": "docs merged"}
]'
record_traj "$FIRST"
it "a first recording succeeds"
check 0 "$CODE"
it "both items store their trajectory"
check '["Write view test", "Install toolchain"]' "$(field '[prog["items"][k]["trajectory"]["current"]["title"] for k in ("linear:AI-1", "linear:AI-2")]')"
it "valid clauses are kept"
check '["term:cadence", "rule:'"$RULE_ID"'", "instruction:i0a1b2c"]' "$(field '[s["clause"] for s in [prog["items"]["linear:AI-1"]["trajectory"]["current"]] + prog["items"]["linear:AI-1"]["trajectory"]["planned"]]')"
it "the first recording journals no plan change (R29)"
check 0 "$(count_kind trajectory_changed)"
it "the trajectory stores the finish, session id and hash"
check '["merged PR", "sess-pm", true]' "$(field '[prog["items"]["linear:AI-1"]["trajectory"][k] for k in ("finish", "session_id")] + [bool(prog["items"]["linear:AI-1"]["trajectory"]["hash"])]')"
it "location stores both tab and pane names"
check '{"pane": "owner-history", "tab": "AI-Editor"}' "$(field 'prog["items"]["linear:AI-1"]["trajectory"]["location"]')"
it "an entry without location stores none"
check "null" "$(field 'prog["items"]["linear:AI-2"]["trajectory"]["location"]')"
it "a step with no clause is stored with a null clause and no note (AE3)"
check '{"clause": null, "title": "Install toolchain"}' "$(field 'prog["items"]["linear:AI-2"]["trajectory"]["current"]')"
it "a clause naming a missing instruction is stored as null with an unknown_clause note"
check '{"clause": null, "note": "unknown_clause", "title": "Edit docs"}' "$(field 'prog["items"]["linear:AI-2"]["trajectory"]["planned"][0]')"
it "the done item is skipped and the rest stored"
check "null" "$(field 'prog["items"]["linear:AI-3"].get("trajectory")')"
it "the first call sets trajectory_sweeps to one time"
check 1 "$(field 'len(prog["trajectory_sweeps"])')"
FIRST_AT="$(field 'prog["trajectory_sweeps"][-1]')"
it "the stored recorded_at matches the sweep time"
check "$FIRST_AT" "$(field 'prog["items"]["linear:AI-1"]["trajectory"]["recorded_at"]')"

DONE_ENTRY='[{"item": "linear:AI-3", "done": [], "current": {"title": "x", "clause": null}, "planned": [], "finish": "y"},
 {"item": "linear:AI-2", "done": [], "current": {"title": "Install toolchain", "clause": null}, "planned": [{"title": "Edit docs", "clause": null}], "finish": "docs merged"}]'
sleep 1
record_traj "$DONE_ENTRY"
it "a batch with a done item still succeeds"
check 0 "$CODE"
it "the done item is reported as skipped with a reason"
has '"skipped"' "$OUT"
has "done" "$OUT"
it "a second call shifts trajectory_sweeps so the first time becomes previous"
check "[$FIRST_AT, true]" "$(field '[prog["trajectory_sweeps"][0], len(prog["trajectory_sweeps"]) == 2]')"
it "an unchanged item still updates recorded_at"
check "$(field 'prog["trajectory_sweeps"][1]')" "$(field 'prog["items"]["linear:AI-2"]["trajectory"]["recorded_at"]')"
it "items not in the input keep their last trajectory"
check '"Write view test"' "$(field 'prog["items"]["linear:AI-1"]["trajectory"]["current"]["title"]')"
it "an unchanged path journals nothing"
check 0 "$(count_kind trajectory_changed)"
check 0 "$(count_kind effects_recorded)"

AE1='[
 {"item": "linear:AI-1", "done": [],
  "current": {"title": "Write view test", "clause": "term:cadence"},
  "planned": [{"title": "Fix flaky test", "clause": null}, {"title": "Run auto suite", "clause": null},
              {"title": "Open PR", "clause": null}],
  "finish": "merged PR"},
 {"item": "linear:AI-2", "done": [], "current": {"title": "Install toolchain", "clause": null},
  "planned": [{"title": "Edit docs", "clause": null}], "finish": "docs merged"}
]'
record_traj "$AE1"
it "inserting a step journals one trajectory_changed row (AE1)"
check 1 "$(count_kind trajectory_changed)"
it "the change row names the changed item with old and new hash"
check '["linear:AI-1", true, true]' "$(run_py "$RUN" <<'EOF'
rows = [r for r in pj.read(args[0]) if r["kind"] == "trajectory_changed"]
p = rows[-1]["payload"]
print(json.dumps([p["item"], bool(p["old_hash"]), p["old_hash"] != p["new_hash"]]))
EOF
)"
it "the changed item gets a history row and the unchanged one does not"
check '[1, 0]' "$(field '[sum(1 for h in prog["items"][k]["history"] if h["kind"] == "trajectory_changed") for k in ("linear:AI-1", "linear:AI-2")]')"

PROGRESS='[{"item": "linear:AI-1", "done": [{"title": "Write view test", "clause": "term:cadence"}],
  "current": {"title": "Fix flaky test", "clause": null},
  "planned": [{"title": "Run auto suite", "clause": null}, {"title": "Open PR", "clause": null}],
  "finish": "merged PR"}]'
record_traj "$PROGRESS"
it "ordinary progress (current moves to done, next becomes current) is not a change"
check 1 "$(count_kind trajectory_changed)"

RETITLE='[{"item": "linear:AI-1", "done": [{"title": "  write   VIEW test ", "clause": null}],
  "current": {"title": "fix Flaky  test", "clause": null},
  "planned": [{"title": "Run auto suite", "clause": null}, {"title": "OPEN pr", "clause": null}],
  "finish": "merged PR"}]'
record_traj "$RETITLE"
it "a retitle that differs only in case or spacing is not a change"
check 1 "$(count_kind trajectory_changed)"

edit 'rec["programme"]["items"]["linear:AI-1"]["trajectory"]["session_id"] = "sess-old-driver"'
NEWPATH='[{"item": "linear:AI-1", "done": [], "current": {"title": "Totally different", "clause": null},
  "planned": [], "finish": "merged PR"}]'
record_traj "$NEWPATH"
it "a recording under a new driving session gives no change row (AE8)"
check 1 "$(count_kind trajectory_changed)"
it "the stored session id updates to the new driving session"
check '"sess-pm"' "$(field 'prog["items"]["linear:AI-1"]["trajectory"]["session_id"]')"

SWEEPS_BEFORE="$(field 'prog["trajectory_sweeps"]')"
record_traj '[{"item": "linear:AI-3", "done": [], "current": {"title": "x", "clause": null}, "planned": [], "finish": "y"}]'
it "a batch where every entry is skipped leaves trajectory_sweeps alone"
check "$SWEEPS_BEFORE" "$(field 'prog["trajectory_sweeps"]')"

it "the view is rebuilt once per call, not once per item"
check '[0, 1, 2]' "$(run_py "$RUN" <<'EOF'
prog = load_lib_module("programme")
calls = []
real = prog.refresh_view
prog.refresh_view = lambda *a, **k: (calls.append(1), real(*a, **k))
before = sum(1 for r in pj.read(args[0]) if r["kind"] == "trajectory_changed")
batch = [
  {"item": "linear:AI-1", "done": [], "current": {"title": "Another path", "clause": None}, "planned": [], "finish": "PR"},
  {"item": "linear:AI-2", "done": [], "current": {"title": "Other path", "clause": None}, "planned": [], "finish": "PR"},
]
sys.stdin = io.StringIO(json.dumps(batch))
saved, sys.stdout = sys.stdout, io.StringIO()
code = prog._cli(["record-trajectories"])
sys.stdout = saved
after = sum(1 for r in pj.read(args[0]) if r["kind"] == "trajectory_changed")
print(json.dumps([code, len(calls), after - before]))
EOF
)"

it "merging two items that both have trajectories keeps the newer one"
edit 'rec["programme"]["items"]["linear:AI-1"]["trajectory"]["recorded_at"] = "2000-01-01T00:00:00Z"'
prog merge-item linear:AI-2 linear:AI-1
check 0 "$CODE"
check '"Other path"' "$(field 'prog["items"]["linear:AI-1"]["trajectory"]["current"]["title"]')"

it "merging keeps the destination's trajectory when it is the newer one"
prog add-item linear:AI-4 --title "Stale"
edit 'rec["programme"]["items"]["linear:AI-4"]["trajectory"] = {"done": [], "current": {"title": "Old", "clause": None}, "planned": [], "finish": None, "location": None, "recorded_at": "2000-01-01T00:00:00Z", "session_id": "sess-pm", "hash": "x"}'
prog merge-item linear:AI-4 linear:AI-1
check '"Other path"' "$(field 'prog["items"]["linear:AI-1"]["trajectory"]["current"]["title"]')"

edit 'rec["programme"].setdefault("context", {}).setdefault("decisions", {})["r-small-prs"] = [{"rev": 1, "state": "accepted", "at": "2026-10-20T00:00:00Z", "kind": "merge_strategy", "effect": "restrict", "applies_to": ["linear:AI-1"], "until": None, "scope": "PRs under 300 lines", "reason": None, "quote": "keep PRs small", "limits": [], "requirements": []}]'
edit 'rec["programme"]["context"]["decisions"]["r-gone"] = [{"rev": 1, "state": "closed", "at": "2026-10-20T00:00:00Z", "kind": "merge_strategy", "effect": "grant", "applies_to": ["linear:AI-1"], "until": None, "scope": "x", "reason": None, "quote": "x", "limits": [], "requirements": []}]'
record_traj '[{"item": "linear:AI-1", "done": [], "current": {"title": "Split the PR", "clause": "ruling:r-small-prs"},
  "planned": [{"title": "Old cite", "clause": "instruction:i0a1b2c"}, {"title": "Legacy as Ruling", "clause": "ruling:i0a1b2c"},
              {"title": "Closed", "clause": "ruling:r-gone"}, {"title": "Not legacy", "clause": "instruction:r-small-prs"}],
  "finish": "PR"}]'
it "a step cites an active Ruling as ruling:<id>, and a legacy instruction both as ruling:<id> and instruction:<id>"
check '["ruling:r-small-prs", "instruction:i0a1b2c", "ruling:i0a1b2c", null, null]' "$(field '[s["clause"] for s in [prog["items"]["linear:AI-1"]["trajectory"]["current"]] + prog["items"]["linear:AI-1"]["trajectory"]["planned"]]')"
it "a closed Ruling and instruction:<id> naming a non-legacy Ruling are unknown clauses"
check '["unknown_clause", "unknown_clause"]' "$(field '[s.get("note") for s in prog["items"]["linear:AI-1"]["trajectory"]["planned"][2:]]')"
it "a stored instruction:<id> step still counts as reliant on that instruction"
check "1 1" "$(run_py "$RUN" <<'EOF'
pvw = load_lib_module("programme_view_work")
steps = [pvw._step(s, "planned") for s in record(args[0])["programme"]["items"]["linear:AI-1"]["trajectory"]["planned"]]
counts = pvw.reliant_counts([{"steps": steps}])
print(counts.get("instruction:i0a1b2c"), counts.get("ruling:i0a1b2c"))
EOF
)"

echo ""
echo "programme-trajectory.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
