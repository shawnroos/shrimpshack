#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
PROG="${AUTO_ROOT}/lib/programme.py"
HOOKS="${AUTO_ROOT}/.claude/hooks"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
check() { if [ "$1" = "$2" ]; then pass; else fail "expected [$1] got [$2]"; fi; }
has() { case "$2" in *"$1"*) pass ;; *) fail "expected to find [$1] in [$2]" ;; esac; }

echo "programme-pm-anywhere.test.sh"

WORK="$(mktemp -d -t auto-pm-anywhere.XXXXXX)"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

for v in $(env | sed -n 's/^\(HERDR_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
unset CLAUDE_CODE_SESSION_ID CLAUDE_AUTO_REPO LINEAR_API_KEY CLAUDE_CODE_ENTRYPOINT 2>/dev/null || true
export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_MACHINE="studio"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_AUTO_SOURCE_TIMEOUT="2"
export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
: > "$CLAUDE_AUTO_SECRETS_FILE"
NOREPO="${WORK}/norepo"
mkdir -p "$NOREPO"

FAKES="${WORK}/fakes"
SNAP="${WORK}/snapshot.json"
mkdir -p "$FAKES"
export SNAP PY

cat > "${FAKES}/herdr" <<'EOF'
#!/bin/bash
case "$1 ${2:-}" in
  "status server") echo "status: running" ;;
  "api snapshot") cat "$SNAP" ;;
esac
exit 0
EOF
chmod +x "${FAKES}/herdr"
export PATH="${FAKES}:${PATH}"

snapshot() {
  "$PY" - "$SNAP" "$@" <<'PYEOF'
import json, sys
panes = []
for spec in sys.argv[2:]:
    pid, label, sess, term = spec.split("|")
    panes.append({"pane_id": pid, "tab_id": "w2:t1", "workspace_id": "w2", "terminal_id": term,
                  "agent": "claude", "agent_status": "idle", "cwd": "/tmp", "label": label,
                  "agent_session": {"source": "auto", "agent": "claude", "kind": "id", "value": sess} if sess else None})
doc = {"id": "1", "result": {"type": "snapshot", "snapshot": {
    "workspaces": [{"workspace_id": "w2", "label": "Ai Editor"}],
    "tabs": [{"tab_id": "w2:t1", "workspace_id": "w2", "label": "Work"}],
    "panes": panes, "agents": panes}}}
json.dump(doc, open(sys.argv[1], "w"))
PYEOF
}

# register <sid> <pane> <terminal> [<startup cwd>]: the row SessionStart writes for a session.
register() {
  "$PY" - "$AUTO_ROOT" "$1" "$2" "$3" "${4:-}" <<'PYEOF'
import os, sys, time
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
sr = load_lib_module("session_registry")
sid, pane, term, cwd = sys.argv[2:]
time.sleep(1.1)
row = {"at": load_lib_module("run_record_core").now_iso(), "session_id": sid, "pane_id": pane,
       "terminal_id": term, "tab_id": "w2:t1", "server": "default", "workspace": "w2", "interactive": True}
if cwd:
    row.update(source="startup", cwd=cwd)
sr._append(sr.registry_path("default", "w2"), row)
PYEOF
}

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
args = sys.argv[2:]
sys.path.insert(0, os.path.join(sys.argv[1], "tests", "helpers"))
import programme_records
$(cat)
PYEOF
}

OUT=""
CODE=0
HERE="$NOREPO"
as() {
  local sid="$1"; shift
  OUT="$(cd "$HERE" && CLAUDE_CODE_SESSION_ID="$sid" HERDR_WORKSPACE_ID=w2 "$PY" "$PROG" "$@" 2>&1)"
  CODE=$?
}

typed() {
  ( cd "$NOREPO" && HERDR_WORKSPACE_ID=w2 "$PY" "${AUTO_ROOT}/tests/fixtures/programme_prompts.py" "$AUTO_ROOT" "$1" "$2" 2>/dev/null )
}

restored() {
  local sid="$1" cwd="$2"
  ( cd "$NOREPO" && CLAUDE_PLUGIN_ROOT="$AUTO_ROOT" bash "${HOOKS}/on-session-start.sh" \
      <<< "{\"session_id\":\"${sid}\",\"source\":\"compact\",\"cwd\":\"${cwd}\"}" 2>/dev/null ) | "$PY" -c '
import json, sys
raw = sys.stdin.read()
try:
    print((json.loads(raw).get("hookSpecificOutput") or {}).get("additionalContext") or "")
except ValueError:
    print(raw)'
}

driver_of() {
  run_py "$1" <<'EOF'
print(programme_records.load(args[0]).get("driving_session_id"))
EOF
}


REPO="${WORK}/repos/alpha"
git init -q "$REPO" && git -C "$REPO" commit -q --allow-empty -m init

snapshot "w2:p10|PM|sess-pm|term_p10"
register sess-pm w2:p10 term_p10 "$REPO"
as sess-pm start w2
RUN="$("$PY" -c 'import json,sys; print(json.loads(sys.stdin.read().splitlines()[0])["run"])' <<< "$OUT")"
OUT="$(printf '%s' "{\"repos\": [{\"path\": \"${REPO}\"}]}" | CLAUDE_CODE_SESSION_ID=sess-pm HERDR_WORKSPACE_ID=w2 "$PY" "$PROG" set-remit --run "$RUN" 2>&1)"
as sess-pm propose-agreement
P_ACCEPT="$("$PY" -c '
import json, re, sys
ctx = json.loads(sys.stdin.read())["hookSpecificOutput"]["additionalContext"]
print(json.loads(re.search(r"\{.*\}", ctx).group(0))["prompt_id"])' <<< "$(typed sess-pm 'yes, run it on those terms')")"
as sess-pm accept-agreement --prompt "$P_ACCEPT"

# A worktree recorded by an earlier version of auto: real on disk, so only the dropped
# requirement could act on it.
WT="${REPO}/worktrees/programme-${RUN}"
git -C "$REPO" worktree add -q --detach "$WT" >/dev/null 2>&1
run_py "$RUN" "$WT" "$REPO" <<'EOF' >/dev/null
rec = programme_records.load(args[0])
rec["programme"]["pm_worktree"] = {"path": args[1], "repo": args[2], "created_at": "2026-10-23T00:00:00Z"}
programme_records.save(args[0], rec)
EOF

it "setup: the programme carries a recorded worktree that exists"
check "${WT} yes" "$(run_py "$RUN" <<'EOF'
print(((programme_records.load(args[0]).get("programme") or {}).get("pm_worktree") or {}).get("path"))
EOF
) $([ -d "$WT" ] && echo yes)"

stop_hook() {
  ( cd "$NOREPO" && bash "${HOOKS}/on-stop.sh" <<< "{\"session_id\":\"$1\",\"cwd\":\"$2\"}" 2>/dev/null ) || true
}

field() {
  "$PY" -c 'import json,sys; t=sys.stdin.read().strip(); print((json.loads(t) if t else {}).get(sys.argv[1], ""))' "$1"
}

asks_move() {
  case "$1" in *'Run `cd'*|*'/cd '*|*"rogramme worktree"*|*cwd_drift*) echo yes ;; *) echo no ;; esac
}

it "the driving PM stops from outside its recorded worktree with no block and no note"
OUT="$(stop_hook sess-pm "$REPO")"
check "" "$(printf '%s' "$OUT" | tr -d '[:space:]')"

it "a PM blocked for another reason gets no cwd_drift reason and no move note"
run_py "$RUN" <<'EOF' >/dev/null
ph = load_lib_module("programme_home")
rec = programme_records.load(args[0])
item = ph.new_item("linear:AI-7", "linear:AI-7", state="waiting", now_iso="2026-10-23T00:00:00Z")
item["matched_rule"] = "r1"
item["owner"] = {"pane": "w2:p1", "terminal_id": None, "session_id": "sess-w"}
item["waiting_on"] = {"who": "team-x", "watcher": None, "reporter": None}
rec["programme"]["items"] = {"linear:AI-7": item}
programme_records.save(args[0], rec)
EOF
OUT="$(stop_hook sess-pm "$REPO")"
REASON="$(printf '%s' "$OUT" | field reason)"
case "$REASON" in *"linear:AI-7"*) ;; *) fail "expected the unwatched wait to block: $OUT" ;; esac
check "no no" "$(asks_move "$REASON") $(asks_move "$(printf '%s' "$OUT" | field systemMessage)")"
run_py "$RUN" <<'EOF' >/dev/null
rec = programme_records.load(args[0])
rec["programme"]["items"] = {}
programme_records.save(args[0], rec)
EOF

it "status names no programme worktree"
as sess-pm status --run "$RUN"
check "0 no" "$CODE $(asks_move "$OUT")"

it "takeover by a session started in the main checkout asks for no move"
register sess-b w2:p20 term_p20 "$REPO"
snapshot "w2:p31|scratch|sess-w2|term_p31"
typed sess-b '/auto:programme-takeover' >/dev/null
as sess-b takeover
check "0 sess-b no" "$CODE $(driver_of "$RUN") $(asks_move "$OUT")"
has "<auto-rules>" "$OUT"

it "a handover successor's refused write prints the rules with no move line"
register sess-n w2:p60 term_p60 "$REPO"
snapshot "w2:p20|PM|sess-b|term_p20"
typed sess-b '/auto:programme-handover sess-n' >/dev/null
as sess-b handover sess-n
check "0 sess-n" "$CODE $(driver_of "$RUN")"
as sess-n set-now "sweeping" --run "$RUN"
check "1 no" "$CODE $(asks_move "$OUT")"
has "<auto-rules>" "$OUT"

it "programme.sh rules prints no move line"
as sess-n rules --run "$RUN"
check "0 no" "$CODE $(asks_move "$OUT")"

it "restored context after compaction has no move line"
CTX="$(restored sess-n "$NOREPO")"
has "programme: ${RUN}" "$CTX"
check "no" "$(asks_move "$CTX")"

echo
echo "programme-pm-anywhere.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
