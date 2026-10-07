#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
HOOKS="${AUTO_ROOT}/.claude/hooks"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
check() { if [ "$1" = "$2" ]; then pass; else fail "expected [$1] got [$2]"; fi; }
has() { case "$2" in *"$1"*) pass ;; *) fail "expected to find [$1] in [$2]" ;; esac; }

echo "tracker-guard.test.sh"

WORK="$(mktemp -d -t auto-tracker-guard.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

for v in $(env | sed -n 's/^\(HERDR_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
unset CLAUDE_CODE_SESSION_ID

export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
: > "$CLAUDE_AUTO_SECRETS_FILE"
NOREPO="${WORK}/norepo"
mkdir -p "$NOREPO"

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
ph = load_lib_module("programme_home")
pj = load_lib_module("programme_journal")
core = load_lib_module("run_record_core")
args = sys.argv[2:]
$(cat)
PYEOF
}

RUN="$(run_py <<'EOF'
print(ph.create_programme(["w2"], "sess-pm")["run"])
EOF
)"

mcp_hook() {
  local sid="$1" tool="$2" input="$3"
  local payload
  payload="$("$PY" -c 'import json,sys; print(json.dumps({"session_id": sys.argv[1], "tool_name": sys.argv[2], "tool_input": json.loads(sys.argv[3])}))' "$sid" "$tool" "$input")"
  ( cd "$NOREPO" && bash "${HOOKS}/on-pretooluse-action.sh" <<< "$payload" )
}

decision_of() {
  "$PY" -c 'import json,sys
raw = sys.stdin.read().strip()
print(json.loads(raw)["hookSpecificOutput"]["permissionDecision"] if raw else "allow")'
}

it "the driving session is denied setting an issue to Done"
OUT="$(mcp_hook sess-pm mcp__linear__save_issue '{"id":"AI-753","state":"Done"}')"
check "deny" "$(printf '%s' "$OUT" | decision_of)"

it "the deny reason names the done state in one line"
has "Done" "$OUT"

it "the driving session is denied a done state in any case"
OUT="$(mcp_hook sess-pm mcp__linear__save_issue '{"id":"AI-753","state":"cancelled"}')"
check "deny" "$(printf '%s' "$OUT" | decision_of)"

it "the driving session is denied a completed state type"
OUT="$(mcp_hook sess-pm mcp__linear__save_issue '{"id":"AI-753","state":"completed"}')"
check "deny" "$(printf '%s' "$OUT" | decision_of)"

it "the driving session is denied Duplicate and a duplicateOf link"
A="$(mcp_hook sess-pm mcp__linear__save_issue '{"id":"AI-753","state":"Duplicate"}' | decision_of)"
B="$(mcp_hook sess-pm mcp__linear__save_issue '{"id":"AI-753","duplicateOf":"AI-700"}' | decision_of)"
check "deny deny" "$A $B"

it "the driving session is denied a stateType field naming canceled"
OUT="$(mcp_hook sess-pm mcp__linear__save_issue '{"id":"AI-753","stateType":"canceled"}')"
check "deny" "$(printf '%s' "$OUT" | decision_of)"

it "the driving session may move an issue to In Review"
OUT="$(mcp_hook sess-pm mcp__linear__save_issue '{"id":"AI-753","state":"In Review"}')"
check "" "$OUT"

it "the driving session may add links and a parent-free new issue"
A="$(mcp_hook sess-pm mcp__linear__save_issue '{"id":"AI-753","links":[{"url":"https://github.com/o/r/pull/1","title":"PR"}]}')"
B="$(mcp_hook sess-pm mcp__linear__save_issue '{"team":"AI","title":"Blocker: CI cache","state":"Todo","relatedTo":["AI-753"]}')"
check "|" "${A}|${B}"

it "an unresolvable state id is denied"
OUT="$(mcp_hook sess-pm mcp__linear__save_issue '{"id":"AI-753","state":"0b7e1a52-6f0c-4c1e-9a55-1d2b3c4d5e6f"}')"
check "deny" "$(printf '%s' "$OUT" | decision_of)"

run_py "$RUN" <<'EOF' >/dev/null
run = args[0]
home = ph.home_path(run)
def mutate(rec):
    rec["programme"]["recorded_issues"] = {"provider": "linear-mcp", "at": "2026-10-07T00:00:00Z", "issues": {
        "AI-753": {"title": "t", "state": "In Review", "state_type": "started",
                   "state_id": "11111111-2222-4333-8444-555555555555", "url": None, "source": "linear-mcp"},
        "AI-754": {"title": "t", "state": "Shipped", "state_type": "completed",
                   "state_id": "99999999-2222-4333-8444-555555555555", "url": None, "source": "linear-mcp"}}}
core._with_locked_run_record(home, run, mutate)
EOF

it "a state id the recorded issues show as not done is allowed"
OUT="$(mcp_hook sess-pm mcp__linear__save_issue '{"id":"AI-753","state":"11111111-2222-4333-8444-555555555555"}')"
check "" "$OUT"

it "a state id the recorded issues show as done is denied"
OUT="$(mcp_hook sess-pm mcp__linear__save_issue '{"id":"AI-753","state":"99999999-2222-4333-8444-555555555555"}')"
check "deny" "$(printf '%s' "$OUT" | decision_of)"

it "a custom state name the recorded issues show as done is denied"
OUT="$(mcp_hook sess-pm mcp__linear__save_issue '{"id":"AI-753","state":"shipped"}')"
check "deny" "$(printf '%s' "$OUT" | decision_of)"

it "the driving session is denied a root-cause comment"
OUT="$(mcp_hook sess-pm mcp__linear__save_comment '{"issueId":"AI-753","body":"Root cause: the cache key ignored the lockfile."}')"
check "deny" "$(printf '%s' "$OUT" | decision_of)"

it "the driving session is denied editing a comment into a root-cause comment"
OUT="$(mcp_hook sess-pm mcp__linear__save_comment '{"id":"c1","body":"the root-cause was X"}')"
check "deny" "$(printf '%s' "$OUT" | decision_of)"

it "the driving session may post a progress comment"
OUT="$(mcp_hook sess-pm mcp__linear__save_comment '{"issueId":"AI-753","body":"PR opened: https://github.com/o/r/pull/1"}')"
check "" "$OUT"

it "a denied write is journaled"
OUT="$(run_py "$RUN" <<'EOF'
rows = [r for r in pj.read(args[0]) if r["kind"] == "blocked_tracker_write"]
print(len(rows) > 0, rows[-1]["session_id"], rows[-1]["payload"]["tool"])
EOF
)"
check "True sess-pm mcp__linear__save_comment" "$OUT"

it "a non-driving session is untouched by the tracker guard"
A="$(mcp_hook sess-worker mcp__linear__save_issue '{"id":"AI-753","state":"Done"}')"
B="$(mcp_hook sess-worker mcp__linear__save_comment '{"issueId":"AI-753","body":"Root cause: X"}')"
check "|" "${A}|${B}"

it "a session with no programme at all is untouched"
OUT="$( cd "$NOREPO" && CLAUDE_AUTO_DATA_DIR="${WORK}/empty" bash "${HOOKS}/on-pretooluse-action.sh" <<< '{"session_id":"sess-pm","tool_name":"mcp__linear__save_issue","tool_input":{"id":"AI-1","state":"Done"}}' )"
check "" "$OUT"

it "junk input never raises and exits 0"
RESULTS=""
for payload in 'not json' '{"session_id":"sess-pm","tool_name":"mcp__linear__save_issue","tool_input":null}' \
  '{"session_id":"sess-pm","tool_name":"mcp__linear__save_issue","tool_input":{"state":42}}' \
  '{"session_id":"sess-pm","tool_name":"mcp__linear__save_comment","tool_input":{"body":{}}}' \
  '{"session_id":null,"tool_name":"mcp__linear__save_issue","tool_input":{"state":"Done"}}' \
  '[1,2,3]' ''; do
  ERR="${WORK}/err"
  ( cd "$NOREPO" && bash "${HOOKS}/on-pretooluse-action.sh" <<< "$payload" ) >/dev/null 2>"$ERR"
  RESULTS="${RESULTS}$?$(grep -c Traceback "$ERR")"
done
check "00000000000000" "$RESULTS"

it "a non-string state from the driving session is denied, not ignored"
OUT="$(mcp_hook sess-pm mcp__linear__save_issue '{"id":"AI-753","state":42}')"
check "deny" "$(printf '%s' "$OUT" | decision_of)"

run_py "$RUN" <<'EOF' >/dev/null
run = args[0]
home = ph.home_path(run)
def mutate(rec):
    rec["programme"]["remit"]["tracker"] = {"teams": [{"key": "AI", "name": "AI Labs", "id": "team-ai"}],
                                            "projects": [{"name": "Cue jobs", "id": "p-cue"}], "initiatives": []}
    rec["programme"]["recorded_issues"]["issues"]["AI-760"] = {"title": "t", "state": "Todo", "state_type": "unstarted",
                                                               "project": {"id": "p-other", "name": "Other"}}
core._with_locked_run_record(home, run, mutate)
EOF

it "a write to an issue outside the remit teams is denied"
A="$(mcp_hook sess-pm mcp__linear__save_comment '{"issueId":"XY-12","body":"Work started."}' | decision_of)"
B="$(mcp_hook sess-pm mcp__linear__save_issue '{"id":"XY-12","state":"In Progress"}' | decision_of)"
C="$(mcp_hook sess-pm mcp__linear__create_attachment '{"issue":"XY-12","filename":"a.png"}' | decision_of)"
check "deny deny deny" "$A $B $C"

it "a write to an issue inside the remit teams is allowed"
OUT="$(mcp_hook sess-pm mcp__linear__save_comment '{"issueId":"AI-753","body":"Work started."}')"
check "" "$OUT"

it "a new issue in a team outside the remit is denied and one inside is allowed"
A="$(mcp_hook sess-pm mcp__linear__save_issue '{"team":"XY","title":"Blocker"}' | decision_of)"
B="$(mcp_hook sess-pm mcp__linear__save_issue '{"team":"AI Labs","title":"Blocker"}' | decision_of)"
check "deny allow" "$A $B"

it "an issue given by uuid cannot be checked against the remit teams and is denied"
OUT="$(mcp_hook sess-pm mcp__linear__save_comment '{"issueId":"0b7e1a52-6f0c-4c1e-9a55-1d2b3c4d5e6f","body":"Work started."}')"
check "deny" "$(printf '%s' "$OUT" | decision_of)"

it "a recorded issue in a project outside the remit is denied"
OUT="$(mcp_hook sess-pm mcp__linear__save_comment '{"issueId":"AI-760","body":"Work started."}')"
check "deny" "$(printf '%s' "$OUT" | decision_of)"

it "a non-driving session may write outside the remit"
OUT="$(mcp_hook sess-worker mcp__linear__save_comment '{"issueId":"XY-12","body":"Work started."}')"
check "" "$OUT"

it "hooks.json routes the Linear MCP tools to the action hook"
OUT="$("$PY" -c 'import json,re,sys
doc = json.load(open(sys.argv[1]))
hits = [e["matcher"] for e in doc["hooks"]["PreToolUse"]
        if re.fullmatch(e["matcher"], "mcp__linear__save_issue")
        and any("on-pretooluse-action" in h["command"] for h in e["hooks"])]
print(len(hits))' "${HOOKS}/hooks.json")"
check "1" "$OUT"

echo
echo "tracker-guard.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
