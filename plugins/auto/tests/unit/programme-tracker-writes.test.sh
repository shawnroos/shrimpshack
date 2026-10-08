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

echo "programme-tracker-writes.test.sh"

WORK="$(mktemp -d -t auto-tracker-writes.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_MACHINE="studio"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_CODE_SESSION_ID="sess-pm"
unset HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_BIN_PATH CLAUDE_AUTO_REPO LINEAR_API_KEY 2>/dev/null || true
: > "$CLAUDE_AUTO_SECRETS_FILE"

FAKES="${WORK}/fakes"
mkdir -p "$FAKES"
for tool in board herdr; do
  printf '#!/bin/sh\nexit 1\n' > "${FAKES}/${tool}"
  chmod +x "${FAKES}/${tool}"
done
export PATH="${FAKES}:/usr/bin:/bin"

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import json, os, sys
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

field() {
  run_py "$RUN" "$1" <<'EOF'
run, expr = args
prog = record(run)["programme"]
items = prog["items"]
print(json.dumps(eval(expr), sort_keys=True))
EOF
}

journal_count() {
  run_py "$RUN" "$1" <<'EOF'
print(len([r for r in pj.read(args[0]) if r["kind"] == args[1]]))
EOF
}

OUT=""
CODE=0
prog() {
  OUT="$("$PY" "$PROG" "$@" 2>&1)"
  CODE=$?
}
prog_in() {
  local input="$1"; shift
  OUT="$(printf '%s' "$input" | "$PY" "$PROG" "$@" 2>&1)"
  CODE=$?
}
jq_py() {
  "$PY" -c 'import json,sys; d=json.loads(sys.stdin.read().strip().splitlines()[-1]); print(json.dumps(eval(sys.argv[1]), sort_keys=True))' "$1" <<< "$OUT"
}

prog add-item linear:AI-800 --title "Fix the crop"

it "describe lists tracker-synced and record-issues"
DESC="$("$PY" "$PROG" describe 2>/dev/null)"
check "True True" "$("$PY" -c 'import json,sys; v=json.load(sys.stdin)["verbs"]; print("tracker-synced" in v, "record-issues" in v)' <<< "$DESC")"

it "an item never synced is due for a tracker write"
prog tracker-synced --item linear:AI-800 --state in_progress --check
check "0 true" "$CODE $(jq_py 'd["due"]')"

it "the check writes nothing and journals nothing"
check "null 0" "$(field 'items["linear:AI-800"].get("tracker_synced")') $(journal_count tracker_synced)"

it "tracker-synced records the state the PM reported"
prog tracker-synced --item linear:AI-800 --state in_progress --note "worker started"
check 0 "$CODE"
check '["in_progress", "worker started"]' "$(field '[items["linear:AI-800"]["tracker_synced"][k] for k in ("state", "note")]')"

it "tracker-synced is journaled once"
check 1 "$(journal_count tracker_synced)"

it "the same state is not due again"
prog tracker-synced --item linear:AI-800 --state in_progress --check
check "false" "$(jq_py 'd["due"]')"

it "repeating the same state changes nothing and journals nothing"
prog tracker-synced --item linear:AI-800 --state in_progress --note "again"
check "0 false 1 \"worker started\"" "$CODE $(jq_py 'd["changed"]') $(journal_count tracker_synced) $(field 'items["linear:AI-800"]["tracker_synced"]["note"]')"

it "a new state is due and records once"
prog tracker-synced --item linear:AI-800 --state pr_open --check
A="$(jq_py 'd["due"]')"
prog tracker-synced --item linear:AI-800 --state pr_open --note "PR opened"
check "true 2 \"pr_open\"" "$A $(journal_count tracker_synced) $(field 'items["linear:AI-800"]["tracker_synced"]["state"]')"

it "the item history records each sync"
check 2 "$(field 'len([h for h in items["linear:AI-800"]["history"] if h["kind"] == "tracker_synced"])')"

it "a state label with spaces is refused"
prog tracker-synced --item linear:AI-800 --state "in progress"
check 1 "$CODE"

it "an unknown item is refused"
prog tracker-synced --item linear:AI-999 --state in_progress
check 1 "$CODE"

it "a session that does not drive the programme may not record a sync"
OUT="$(CLAUDE_CODE_SESSION_ID=sess-worker "$PY" "$PROG" tracker-synced --run "$RUN" --item linear:AI-800 --state merged 2>&1)"
check "1" "$?"

ISSUES='[{"key":"AI-800","title":"Fix the crop","state":"In Progress","state_type":"started","url":"https://linear.app/x/issue/AI-800"},
 {"key":"AI-801","title":"Esc \u001b[31mred","state":"Done","state_type":"completed","state_id":"11111111-2222-4333-8444-555555555555"},
 {"key":"not an issue","title":"x"}, "junk"]'

it "record-issues stores the issues the PM read through the MCP"
prog_in "$ISSUES" record-issues
check 0 "$CODE"
check '["AI-800", "AI-801"]' "$(field 'sorted(prog["recorded_issues"]["issues"])')"

it "record-issues sets the tracker available with provider linear-mcp"
check '["linear-mcp", null, "linear-mcp"]' "$(field '[prog["sources"]["tracker"]["provider"], prog["sources"]["tracker"]["unavailable_since"], prog["recorded_issues"]["provider"]]')"

it "record-issues sanitises titles and keeps the state id"
check '["Esc red", "11111111-2222-4333-8444-555555555555", "completed"]' "$(field '[prog["recorded_issues"]["issues"]["AI-801"][k] for k in ("title", "state_id", "state_type")]')"

it "record-issues drops entries that are not issues and counts them"
check 2 "$(field 'prog["recorded_issues"]["dropped"]')"

it "record-issues is journaled"
check 1 "$(journal_count issues_recorded)"

it "record-issues caps the number of issues"
BIG="$("$PY" -c 'import json; print(json.dumps([{"key": "AI-%d" % (n + 1), "title": "t", "state": "Todo", "state_type": "unstarted"} for n in range(500)]))')"
prog_in "$BIG" record-issues
check "0 200 300" "$CODE $(field 'len(prog["recorded_issues"]["issues"])') $(field 'prog["recorded_issues"]["dropped"]')"

it "record-issues refuses input that is not JSON"
prog_in "not json" record-issues
check 2 "$CODE"

it "record-issues refuses an unknown state type by dropping it to null"
prog_in '[{"key":"AI-5","title":"t","state":"Odd","state_type":"weird type"}]' record-issues
check 'null' "$(field 'prog["recorded_issues"]["issues"]["AI-5"]["state_type"]')"

it "a sweep whose readers fail keeps the MCP-recorded tracker available"
prog sweep --record-sources
check '[]' "$(jq_py '[c for c in d["recorded_sources"] if c["source"] == "tracker"]')"
check '"linear-mcp"' "$(field 'prog["sources"]["tracker"]["provider"]')"

it "source_changes still reports a board that comes back"
OUT="$(run_py "$RUN" <<'EOF'
ps = load_lib_module("programme_sources")
prog = record(args[0])["programme"]
print(json.dumps(ps.source_changes(prog, {"tracker": {"unavailable": False, "state": "available", "provider": "board"}})))
EOF
)"
has '"provider": "board"' "$OUT"

it "the recorded check never reads MCP-recorded issues"
OUT="$(run_py "$RUN" <<'EOF'
pe = load_lib_module("programme_evidence")
try:
    print(json.dumps(pe.check_recorded("AI-801")))
except pe.Unknown as exc:
    print("unknown")
EOF
)"
check "unknown" "$OUT"

echo
echo "programme-tracker-writes.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
