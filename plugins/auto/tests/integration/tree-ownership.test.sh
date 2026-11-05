#!/usr/bin/env bash
# auto U8 integration test: PreToolUse ownership CHAIN (R21 / AE7 / KTD-7).
#
# The loop's phase work moves into background sub-agents, which carry their OWN
# CLAUDE_CODE_SESSION_ID. Both PreToolUse hooks previously matched a SCALAR
# `driving_session_id`, so neither fired inside the tree — the `fix` phase writes
# code and runs Bash, and it would have run with only prompt-carried (advisory)
# constraints. U8 turns ownership into a SET: a dispatched sub-agent registers its
# session id on the run-record, and the hooks test membership.
#
# Exercises the REAL hooks + REAL run-record, exactly as advisor-gate.test.sh does.
# Nothing is mocked; the only injection points are the sandbox repo and the
# PreToolUse event JSON on stdin.
#
# The action hook no longer reads this set: the limit that refuses destructive commands
# follows a programme's item, and check-settings.test.sh pins it.
#
# Scenarios:
#   6.      question gate widens to the tree (registered sub-agent -> deny+redirect)
#   7.      question gate still fails OPEN (malformed run-record -> allow, exit 0)
#   9.      register_session is idempotent and does not clobber driving_session_id

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RUN_RECORD_PY="${AUTO_ROOT}/lib/run_record.py"
ASKUSER_PY="${AUTO_ROOT}/lib/on-pretooluse-askuser.py"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() {
  FAIL=$((FAIL + 1))
  printf "  \033[31m✗\033[0m %s\n" "$CURRENT"
  [ -n "${1:-}" ] && printf "      %s\n" "$1"
  return 0
}
assert_eq()       { [ "$1" = "$2" ] && pass || fail "expected '$1' got '$2'"; }
assert_contains() { case "$1" in *"$2"*) pass ;; *) fail "expected '$1' to contain '$2'" ;; esac; }
assert_empty()    { [ -z "$1" ] && pass || fail "expected empty, got '$1'"; }

ORIG_HOME="$HOME"
SANDBOX="$(mktemp -d -t auto-test.XXXXXX)"
export HOME="$SANDBOX"
cleanup() {
  export HOME="$ORIG_HOME"
  case "$SANDBOX" in */auto-test.*) rm -rf "$SANDBOX" ;; esac
}
trap cleanup EXIT

mkrepo() { local repo="${SANDBOX}/repo-${1}"; mkdir -p "${repo}/.claude/auto"; printf '%s' "$repo"; }

EVENT() {  # EVENT <session_id> <tool_name> <command>
  "$PY" -c "import json,sys; print(json.dumps({'session_id':sys.argv[1],'tool_name':sys.argv[2],'tool_input':{'command':sys.argv[3]}}))" "$1" "$2" "$3"
}

perm_decision() {
  "$PY" -c "import json,sys
try:
    print(json.loads(sys.argv[1]).get('hookSpecificOutput',{}).get('permissionDecision',''))
except Exception:
    print('')" "$1"
}

rd_loop() {  # rd_loop <repo> <run> <field>
  "$PY" -c "import importlib.util as u;s=u.spec_from_file_location('l','$RUN_RECORD_PY');m=u.module_from_spec(s);s.loader.exec_module(m);l=m.read_run_record('$1','$2');print(l['loop'].get('$3'))"
}

set_driving_session() {  # <repo> <run> <sid>
  "$PY" - "$1" "$2" "$3" "$RUN_RECORD_PY" <<'PYEOF'
import sys, importlib.util, json
repo, run, sid, run_record_py = sys.argv[1:5]
s=importlib.util.spec_from_file_location("run_record",run_record_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
p = L.run_record_path(repo, run)
with open(p) as f: led = json.load(f)
led["driving_session_id"] = sid
with open(p,"w") as f: json.dump(led,f)
PYEOF
}

# The U8 verb under test. A dispatched sub-agent calls this to join the owner set.
register_session() {  # <repo> <run> <sid>
  "$PY" - "$1" "$2" "$3" "$RUN_RECORD_PY" <<'PYEOF'
import sys, importlib.util
repo, run, sid, run_record_py = sys.argv[1:5]
s=importlib.util.spec_from_file_location("run_record",run_record_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
L.register_session(repo, run, sid)
PYEOF
}

read_owners() {  # <repo> <run>
  "$PY" - "$1" "$2" "$RUN_RECORD_PY" <<'PYEOF'
import sys, importlib.util, json
repo, run, run_record_py = sys.argv[1:4]
s=importlib.util.spec_from_file_location("run_record",run_record_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
led = L.read_run_record(repo, run)
print(json.dumps(led.get("agent_session_ids") or []))
PYEOF
}

mk_live_owned() {  # <name> <run> <driving-sid>
  local repo; repo="$(mkrepo "$1")"
  "$PY" - "$repo" "$2" "$RUN_RECORD_PY" <<'PYEOF'
import sys, importlib.util
repo, run, run_record_py = sys.argv[1:4]
s=importlib.util.spec_from_file_location("run_record",run_record_py);L=importlib.util.module_from_spec(s);s.loader.exec_module(L)
L.init_run_record(repo,run,backend="ce",loop_phase="work",steps=[{"id":"U1","state":"pending"}])
PYEOF
  set_driving_session "$repo" "$2" "$3"
  printf '%s' "$repo"
}

# ════════════════════════════════════════════════════════════════════════════
echo "tree-ownership.test.sh"

# ─── 6. question gate widens to the tree ─────────────────────────────────────
it "askuser: registered sub-agent -> deny + advisor redirect"
REPO="$(mk_live_owned q-reg r6 sess-BOSS)"
register_session "$REPO" r6 sess-KID
ev="$(EVENT sess-KID AskUserQuestion 'noop')"
out="$(printf '%s' "$ev" | "$PY" "$ASKUSER_PY" "$REPO")"
assert_eq "deny" "$(perm_decision "$out")"

# ─── 7. question gate still fails OPEN ───────────────────────────────────────
it "askuser still fails OPEN: malformed run_record -> allow"
REPO="$(mkrepo q-malformed)"
printf '{ not valid json' > "${REPO}/.claude/auto/broken.json"
ev="$(EVENT sess-KID AskUserQuestion 'noop')"
out="$(printf '%s' "$ev" | "$PY" "$ASKUSER_PY" "$REPO")"
assert_empty "$out"
it "askuser still exits 0 on a malformed run_record (rel-001)"
printf '%s' "$ev" | "$PY" "$ASKUSER_PY" "$REPO" >/dev/null 2>&1
assert_eq "0" "$?"

# ─── 9. register_session hygiene ─────────────────────────────────────────────
it "register_session is idempotent (no duplicate entries)"
REPO="$(mk_live_owned idem r9 sess-BOSS)"
register_session "$REPO" r9 sess-KID
register_session "$REPO" r9 sess-KID
assert_eq '["sess-KID"]' "$(read_owners "$REPO" r9)"

it "register_session does not clobber driving_session_id"
assert_eq "deny" "$(perm_decision "$(printf '%s' "$(EVENT sess-BOSS AskUserQuestion noop)" | "$PY" "$ASKUSER_PY" "$REPO")")"

# ── summary ─────────────────────────────────────────────────────────────────
echo ""
echo "tree-ownership.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
