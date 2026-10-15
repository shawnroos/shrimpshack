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

echo "programme-source-reads.test.sh"

WORK="$(mktemp -d -t auto-programme-source-reads.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_MACHINE="studio"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_CODE_SESSION_ID="sess-pm"
export CLAUDE_AUTO_SOURCE_TIMEOUT="2"
unset HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_BIN_PATH HERDR_ENV CLAUDE_AUTO_REPO LINEAR_API_KEY 2>/dev/null || true
: > "$CLAUDE_AUTO_SECRETS_FILE"

FAKES="${WORK}/fakes"
CALLS="${WORK}/calls.log"
SNAP="${WORK}/snapshot.json"
mkdir -p "$FAKES"
export CALLS SNAP

cat > "${FAKES}/herdr" <<'EOF'
#!/bin/bash
printf 'herdr %s\n' "$*" >> "$CALLS"
case "$1 ${2:-}" in
  "status server") echo "status: running" ;;
  "api snapshot") cat "$SNAP" ;;
esac
exit 0
EOF
cat > "${FAKES}/board" <<'EOF'
#!/bin/bash
printf 'board %s\n' "$*" >> "$CALLS"
if [ -n "${FAKE_BOARD_JSON:-}" ]; then cat "$FAKE_BOARD_JSON"; exit 0; fi
echo '{"error":{"code":7,"message":"plugin op unsupported: no snapshot"}}'
exit 1
EOF
chmod +x "${FAKES}"/*
export PATH="${FAKES}:${PATH}"

REPO="${WORK}/repo"
mkdir -p "${REPO}/docs/plans" "${REPO}/sub"
( cd "$REPO" && git init -q ) || echo "git setup failed"
printf -- '---\ntitle: Crop rework\nstatus: active\n---\n\nBody naming AI-901 only.\n' > "${REPO}/docs/plans/2026-10-06-crop.md"
printf '# Old export plan\n\nNames AI-555.\n' > "${REPO}/docs/plans/2026-09-01-old.md"
touch -t 202601010000 "${REPO}/docs/plans/2026-09-01-old.md"
printf 'not a plan\n' > "${REPO}/docs/plans/notes.txt"

ALT="${WORK}/alt"
mkdir -p "${ALT}/handbook/plans" "${ALT}/docs/plans" "${ALT}/.compound-engineering"
( cd "$ALT" && git init -q ) || echo "git setup failed"
printf 'docs_root: handbook\n' > "${ALT}/.compound-engineering/config.yaml"
printf '# Handbook plan\n' > "${ALT}/handbook/plans/a.md"
printf '# Ignored default plan\n' > "${ALT}/docs/plans/b.md"

ESCAPE="${WORK}/escape"
mkdir -p "${ESCAPE}/docs/plans" "${ESCAPE}/.compound-engineering"
( cd "$ESCAPE" && git init -q ) || echo "git setup failed"
printf "docs_root: '../alt/handbook'\n" > "${ESCAPE}/.compound-engineering/config.yaml"
printf '# Own plan\n' > "${ESCAPE}/docs/plans/own.md"

NOREPO="${WORK}/norepo"
mkdir -p "$NOREPO"

mkdir -p "${CLAUDE_AUTO_TASKS_DIR}/sess-w1" "${CLAUDE_AUTO_TASKS_DIR}/sess-empty"
printf '{"id":"1","subject":"Read the code","activeForm":"Reading the code","status":"completed"}' > "${CLAUDE_AUTO_TASKS_DIR}/sess-w1/1.json"
printf '{"id":"2","subject":"Fix crop","activeForm":"Fixing the \\u001b[31mcrop\\u001b[0m bounds","status":"in_progress","blockedBy":["1"]}' > "${CLAUDE_AUTO_TASKS_DIR}/sess-w1/2.json"
printf '{"id":"3","subject":"Ship","activeForm":"Shipping","status":"pending"}' > "${CLAUDE_AUTO_TASKS_DIR}/sess-w1/3.json"
printf 'not json' > "${CLAUDE_AUTO_TASKS_DIR}/sess-w1/4.json"
printf '{"id":"9","status":"pending"}' > "${CLAUDE_AUTO_TASKS_DIR}/sess-w1/.lock"

lib_py() {
  "$PY" - "${AUTO_ROOT}/lib" "$@" <<PYEOF 2>&1
import json, os, sys
sys.path.insert(0, sys.argv[1])
from _bootstrap import load_lib_module
args = sys.argv[2:]
$(cat)
PYEOF
}

it "a task list reports counts by status"
check '{"completed": 1, "in_progress": 1, "pending": 1}' "$(lib_py <<'EOF'
print(json.dumps(load_lib_module("programme_tasks").read_session("sess-w1")["counts"], sort_keys=True))
EOF
)"
it "the in-progress task's activeForm is the now line, sanitised"
check 'Fixing the crop bounds' "$(lib_py <<'EOF'
print(load_lib_module("programme_tasks").read_session("sess-w1")["now"])
EOF
)"
it "an emptied task folder is an empty list"
check '[0, null]' "$(lib_py <<'EOF'
s = load_lib_module("programme_tasks").read_session("sess-empty")
print(json.dumps([s["total"], s["now"]]))
EOF
)"
it "a session with no task folder is an empty list, and the source stays available"
check '[0, false, "available", 1]' "$(lib_py <<'EOF'
r = load_lib_module("programme_tasks").read(["sess-none", "sess-w1"])
print(json.dumps([r["sessions"]["sess-none"]["total"], r["unavailable"], r["state"], r["with_lists"]]))
EOF
)"
it "a session id that climbs out of the tasks folder reads nothing"
check '0' "$(lib_py <<'EOF'
print(load_lib_module("programme_tasks").read_session("../tasks/sess-w1")["total"])
EOF
)"
it "the now line is capped"
check '120' "$(lib_py "$WORK" <<'EOF'
os.makedirs(os.path.join(args[0], "captasks", "s1"))
with open(os.path.join(args[0], "captasks", "s1", "1.json"), "w") as fh:
    json.dump({"id": "1", "subject": "x", "activeForm": "y" * 500, "status": "in_progress"}, fh)
os.environ["CLAUDE_AUTO_TASKS_DIR"] = os.path.join(args[0], "captasks")
print(len(load_lib_module("programme_tasks").read_session("s1")["now"]))
EOF
)"
it "a tasks root that is not a folder is unavailable"
check '"unavailable"' "$(CLAUDE_AUTO_TASKS_DIR="${CLAUDE_AUTO_SECRETS_FILE}" lib_py <<'EOF'
print(json.dumps(load_lib_module("programme_tasks").read(["sess-w1"])["state"]))
EOF
)"

it "plans changed in the last week are reported with title and issue ids"
check '[["docs/plans/2026-10-06-crop.md", "Crop rework", ["AI-901"]]]' "$(lib_py "$REPO" <<'EOF'
plans = load_lib_module("programme_plans").read_repo(args[0])
print(json.dumps([[p["path"], p["title"], p["issues"]] for p in plans]))
EOF
)"
it "the title falls back to the first heading"
check '"Handbook plan"' "$(lib_py "$ALT" <<'EOF'
print(json.dumps(load_lib_module("programme_plans").read_repo(args[0])[0]["title"]))
EOF
)"
it "a docs_root in the compound-engineering config moves the plans folder"
check '["handbook/plans/a.md"]' "$(lib_py "$ALT" <<'EOF'
print(json.dumps([p["path"] for p in load_lib_module("programme_plans").read_repo(args[0])]))
EOF
)"
it "a docs_root outside the repo is ignored"
check '["docs/plans/own.md"]' "$(lib_py "$ESCAPE" <<'EOF'
print(json.dumps([p["path"] for p in load_lib_module("programme_plans").read_repo(args[0])]))
EOF
)"
it "a pane folder inside a repo resolves to the repo's top level, and one outside resolves to nothing"
check "[\"$(cd "$REPO" && pwd -P)\", null]" "$(lib_py "${REPO}/sub" "$NOREPO" <<'EOF'
r = load_lib_module("programme_plans").read(args)
print(json.dumps([os.path.realpath(r["roots"][args[0]]), r["roots"][args[1]]]))
EOF
)"
it "a plan read stops at the byte cap"
check 'True' "$(lib_py "$WORK" <<'EOF'
pp = load_lib_module("programme_plans")
big = os.path.join(args[0], "bigrepo")
os.makedirs(os.path.join(big, "docs", "plans"))
with open(os.path.join(big, "docs", "plans", "big.md"), "w") as fh:
    fh.write("# Big\n" + "x" * (pp.BYTES_CAP + 10) + " AI-999\n")
print(pp.read_repo(big)[0]["issues"] == [])
EOF
)"

write_snapshot() {
  "$PY" - "$SNAP" "$REPO" "$NOREPO" <<'PYEOF'
import json, sys
path, repo, norepo = sys.argv[1:4]
def sess(value):
    return {"source": "auto", "agent": "claude", "kind": "id", "value": value}
panes = [
    {"pane_id": "w2:p10", "tab_id": "w2:t1", "workspace_id": "w2", "terminal_id": "term_p10", "agent": "claude",
     "agent_status": "idle", "cwd": norepo, "label": "PM", "agent_session": sess("sess-pm")},
    {"pane_id": "w2:p30", "tab_id": "w2:t1", "workspace_id": "w2", "terminal_id": "term_p30", "agent": "claude",
     "agent_status": "working", "cwd": repo + "/sub", "label": None, "terminal_title_stripped": "Claude Code",
     "agent_session": sess("sess-w1")},
]
doc = {"id": "1", "result": {"type": "snapshot", "snapshot": {
    "workspaces": [{"workspace_id": "w2"}], "tabs": [], "panes": panes, "agents": panes}}}
json.dump(doc, open(path, "w"))
PYEOF
}
write_snapshot

RUN="$(lib_py <<'EOF'
print(load_lib_module("programme_home").create_programme(["w2"], "sess-pm")["run"])
EOF
)"

OUT=""
CODE=0
prog() {
  OUT="$("$PY" "$PROG" "$@" --run "$RUN" 2>&1)"
  CODE=$?
}
jq_py() {
  "$PY" -c "import json,sys; d=json.loads(sys.stdin.read()); print(json.dumps($1, sort_keys=True))" <<< "$OUT" 2>&1
}
field() {
  lib_py "$RUN" "$1" <<'EOF'
ph = load_lib_module("programme_home")
core = load_lib_module("run_record_core")
prog = core.read_run_record(ph.home_path(args[0]), args[0])["programme"]
print(json.dumps(eval(args[1]), sort_keys=True))
EOF
}
set_sources() {
  lib_py "$RUN" "$1" <<'EOF'
ph = load_lib_module("programme_home")
core = load_lib_module("run_record_core")
def change(rec):
    rec["programme"]["agreement"]["terms"]["sources"]["value"] = json.loads(args[1])
core._with_locked_run_record(ph.home_path(args[0]), args[0], change)
EOF
}
typed_prompt() {
  lib_py "$RUN" "$1" <<'EOF'
print(load_lib_module("programme_journal").append_prompt(args[0], "sess-pm", args[1], "typed")["prompt_id"])
EOF
}
predicate_reasons() {
  lib_py "$RUN" <<'EOF'
ph = load_lib_module("programme_home")
core = load_lib_module("run_record_core")
rec = core.read_run_record(ph.home_path(args[0]), args[0])
print(" ".join(sorted(r["kind"] + ":" + str(r.get("system")) for r in load_lib_module("programme_predicate").compute(rec)["reasons"] if r["kind"] == "source_unavailable")))
EOF
}

it "the sources term defaults to tracker, tasks and plans"
check '["tracker", "tasks", "plans"]' "$(field 'prog["agreement"]["terms"]["sources"]["value"]')"

: > "$CALLS"
prog sweep
it "a pane whose owner has a task list carries its counts and now line"
check '[{"completed": 1, "in_progress": 1, "pending": 1}, "Fixing the crop bounds"]' "$(jq_py '[[p["tasks"]["counts"], p["tasks"]["now"]] for p in d["panes"] if p["pane_id"] == "w2:p30"][0]')"
it "the tasks source counts the remit sessions that have a list"
check '["available", 1]' "$(jq_py '[d["sources"]["tasks"]["state"], d["sources"]["tasks"]["with_lists"]]')"
it "the plans source reports each repo's recent plans"
check '[1, 1]' "$(jq_py '[d["sources"]["plans"]["repos"], d["sources"]["plans"]["recent"]]')"
it "an issue named in a repo's plan is a plan signal for the pane in that repo"
check '[["linear:AI-901", ["plan"]]]' "$(jq_py '[[p["item"], p["signals"]] for p in d["proposals"]]')"
it "the plan's issue is asked of the tracker"
check '["board", "linear-api"]' "$(jq_py '[t["provider"] for t in d["sources"]["tracker"]["tried"]]')"

export FAKE_BOARD_JSON="${WORK}/board.json"
printf '%s' '{"issues":{"AI-777":{"identifier":"AI-777","title":"Other","state":{"name":"Todo","type":"unstarted"},"bindings":[]}}}' > "$FAKE_BOARD_JSON"
prog sweep --record-sources
it "a plan issue the tracker does not know is not proposed"
check '[["herdr:w2/p30", []]]' "$(jq_py '[[p["item"], p["signals"]] for p in d["proposals"]]')"
it "sweep --record-sources records the tracker with the provider that answered"
check '["board", null]' "$(field '[prog["sources"]["tracker"]["provider"], prog["sources"]["tracker"]["unavailable_since"]]')"
it "the tasks and plans states are recorded too"
check '[true, true]' "$(field '["tasks" in prog["sources"], "plans" in prog["sources"]]')"
it "the status view shows the tracker's provider"
OUT_STATUS="$("$PY" "$PROG" status --run "$RUN" 2>&1)"
has "tracker: available via board" "$OUT_STATUS"
has "tasks: available" "$OUT_STATUS"
unset FAKE_BOARD_JSON

prog add-item linear:AI-901 --title "Crop rework" --pane w2:p30 --session sess-w1
it "an item row shows the owner's in-progress task as a now line"
has "now: Fixing the crop bounds (1/3 tasks done)" "$("$PY" "$PROG" status --run "$RUN" 2>&1)"

it "propose-agreement takes a sources list and stores it in the canonical order"
prog propose-agreement --term "sources=plans,tracker"
check '["tracker", "plans"]' "$(field 'prog["agreement"]["terms"]["sources"]["value"]')"
it "the rules block renders the sources as words"
has "sources: tracker, plans" "$("$PY" "$PROG" rules --run "$RUN" 2>&1)"
it "a source name outside the three is refused"
prog propose-agreement --term "sources=tracker,board"
check 1 "$CODE"
it "an empty part is refused"
prog propose-agreement --term "sources=tracker,,plans"
check 1 "$CODE"
prog propose-agreement --term "sources=tracker,tasks,plans"
P_ACCEPT="$(typed_prompt "yes, accept")"
prog accept-agreement --prompt "$P_ACCEPT"

it "amend-term sources turns a source off when the typed prompt names it"
P_OFF="$(typed_prompt "please stop watching plans, no plans for this one")"
prog amend-term sources tracker,tasks --prompt "$P_OFF"
check '0 ["tracker", "tasks"]' "$CODE $(field 'prog["agreement"]["terms"]["sources"]["value"]')"
it "amend-term sources refuses a prompt that does not name the source it changes"
P_VAGUE="$(typed_prompt "turn that thing off")"
prog amend-term sources tracker --prompt "$P_VAGUE"
check 1 "$CODE"
has "'tasks'" "$OUT"
it "amend-term sources none turns every source off"
P_NONE="$(typed_prompt "turn off tracker, tasks and plans")"
prog amend-term sources none --prompt "$P_NONE"
check '0 []' "$CODE $(field 'prog["agreement"]["terms"]["sources"]["value"]')"
it "the rules block says none"
has "sources: none" "$("$PY" "$PROG" rules --run "$RUN" 2>&1)"

set_sources '["tasks", "plans"]'
: > "$CALLS"
prog sweep
it "a tracker turned off is never read by the sweep"
lacks "board" "$(cat "$CALLS")"
it "the sweep reports the turned-off tracker as off"
check '["off", null]' "$(jq_py '[d["sources"]["tracker"]["state"], d["sources"]["tracker"]["unavailable"]]')"

set_sources '["tracker"]'
prog sweep
it "tasks turned off are not read: panes carry no task counts"
check '[null, null]' "$(jq_py '[[p["tasks"] for p in d["panes"] if p["pane_id"] == "w2:p30"][0], d["tasks"]]')"
it "plans turned off are not read: no plan signal and no plans block"
check '[[], null]' "$(jq_py '[[p["signals"] for p in d["proposals"] if p["pane"] == "w2:p30"][0], d["plans"]]')"
it "turned-off sources report state off"
check '["off", "off"]' "$(jq_py '[d["sources"]["tasks"]["state"], d["sources"]["plans"]["state"]]')"
it "an off source is not recorded by sweep --record-sources"
check '[]' "$(jq_py '[c["source"] for c in d["source_changes"] if c["source"] in ("tasks", "plans")]')"
it "the item row drops its now line while tasks are off"
lacks "now: Fixing" "$("$PY" "$PROG" status --run "$RUN" 2>&1)"

set_sources '["tracker", "tasks", "plans"]'
prog set-source tracker --unavailable
it "a tracker outage holds the stop while the tracker is on"
check "source_unavailable:tracker" "$(predicate_reasons)"
set_sources '["tasks", "plans"]'
it "the same outage never holds the stop once the tracker is turned off"
check "" "$(predicate_reasons)"
it "the status view shows the turned-off tracker as off, not as an outage"
OUT_STATUS="$("$PY" "$PROG" status --run "$RUN" 2>&1)"
has "tracker: off: turned off in the agreement" "$OUT_STATUS"
lacks "tracker unavailable since" "$OUT_STATUS"

it "no command crashed with a traceback"
lacks "Traceback" "$OUT"

echo ""
echo "programme-source-reads.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
