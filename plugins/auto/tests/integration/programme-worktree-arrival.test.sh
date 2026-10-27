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

echo "programme-worktree-arrival.test.sh"

WORK="$(mktemp -d -t auto-pmwt-arrival.XXXXXX)"
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
GITLOG="${WORK}/git.log"
REAL_GIT="$(command -v git)"
mkdir -p "$FAKES"
: > "$GITLOG"
export SNAP PY GITLOG REAL_GIT

cat > "${FAKES}/herdr" <<'EOF'
#!/bin/bash
case "$1 ${2:-}" in
  "status server") echo "status: running" ;;
  "api snapshot") cat "$SNAP" ;;
esac
exit 0
EOF
cat > "${FAKES}/git" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$GITLOG"
exec "$REAL_GIT" "$@"
EOF
chmod +x "${FAKES}"/*
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

register() {
  "$PY" - "$AUTO_ROOT" "$1" "$2" "$3" "${4:-w2}" <<'PYEOF'
import os, sys, time
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
sr = load_lib_module("session_registry")
sid, pane, term, ws = sys.argv[2:]
time.sleep(1.1)
sr._append(sr.registry_path("default", ws), {
    "at": load_lib_module("run_record_core").now_iso(), "session_id": sid, "pane_id": pane,
    "terminal_id": term, "tab_id": ws + ":t1", "server": "default", "workspace": ws, "interactive": True})
PYEOF
}

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
ph = load_lib_module("programme_home")
pj = load_lib_module("programme_journal")
args = sys.argv[2:]
sys.path.insert(0, os.path.join(sys.argv[1], "tests", "helpers"))
import programme_records
$(cat)
PYEOF
}

OUT=""
CODE=0
as() {
  local sid="$1"; shift
  OUT="$(CLAUDE_CODE_SESSION_ID="$sid" HERDR_WORKSPACE_ID=w2 "$PY" "$PROG" "$@" 2>&1)"
  CODE=$?
}

remit() {
  local sid="$1" run="$2" json="$3"
  OUT="$(printf '%s' "$json" | CLAUDE_CODE_SESSION_ID="$sid" HERDR_WORKSPACE_ID=w2 "$PY" "$PROG" set-remit --run "$run" 2>&1)"
  CODE=$?
}

typed() {
  ( cd "$NOREPO" && HERDR_WORKSPACE_ID=w2 "$PY" "${AUTO_ROOT}/tests/fixtures/programme_prompts.py" "$AUTO_ROOT" "$1" "$2" 2>/dev/null )
}

recorded() {
  run_py "$1" <<'EOF'
wt = (programme_records.load(args[0]).get("programme") or {}).get("pm_worktree")
print(wt["path"] if wt else None)
EOF
}


journal_rows_name_worktree() {
  run_py "$1" "$2" <<'EOF'
rows = [r for r in pj.read(args[0]) if r["kind"] == args[1]]
print(len(rows) > 0, any("pm_worktree" in json.dumps(r) for r in rows))
EOF
}

made_worktree() {
  echo "$(git -C "$1" worktree list --porcelain | grep -c programme-) $([ -e "${1}/worktrees" ] && echo dir || echo nodir)"
}

new_repo() {
  git init -q "$1" && git -C "$1" commit -q --allow-empty -m init
}

# Remit repos set straight on the record with pm_worktree null, so no set-remit runs first.
seed_remit() {
  run_py "$1" "$2" <<'EOF'
rec = programme_records.load(args[0])
rec["programme"].setdefault("remit", {})["repos"] = [{"path": p, "github": None} for p in args[1].split(",") if p]
rec["programme"]["pm_worktree"] = None
programme_records.save(args[0], rec)
EOF
}

start_programme() {
  local sid="$1"
  as "$sid" start "$2"
  "$PY" -c 'import json,sys; print(json.loads(sys.stdin.read().splitlines()[0])["run"])' <<< "$OUT"
}

REPO_A="${WORK}/repos/alpha"
REPO_B="${WORK}/repos/beta"
new_repo "$REPO_A"
new_repo "$REPO_B"

# ── set-remit ─────────────────────────────────────────────────────────────
RUN1="$(start_programme sess-r w5)"

it "set-remit adding a repo records no worktree and makes no worktree git call"
: > "$GITLOG"
remit sess-r "$RUN1" "{\"repos\": [{\"path\": \"${REPO_A}\"}]}"
check "0 None 0 0 nodir" "$CODE $(recorded "$RUN1") $(grep -c worktree "$GITLOG") $(made_worktree "$REPO_A")"

it "the set-remit output carries no pm_worktree key"
case "$OUT" in *pm_worktree*) fail "set-remit output names pm_worktree: $OUT" ;; *) pass ;; esac

it "a second set-remit adding another repo still makes no worktree"
remit sess-r "$RUN1" "{\"repos\": [{\"path\": \"${REPO_A}\"}, {\"path\": \"${REPO_B}\"}]}"
check "0 None 0 nodir" "$CODE $(recorded "$RUN1") $(made_worktree "$REPO_B")"

it "the remit_set journal rows carry no pm_worktree key"
check "True False" "$(journal_rows_name_worktree "$RUN1" remit_set)"

it "status names no programme worktree"
as sess-r status --run "$RUN1"
case "$OUT" in *"Programme worktree"*) fail "status names a programme worktree: $OUT" ;; *) pass ;; esac

# ── takeover and handover ────────────────────────────────────────────────
snapshot "w2:p10|PM|sess-pm|term_p10"
register sess-pm w2:p10 term_p10
RUN="$(start_programme sess-pm w2)"
as sess-pm propose-agreement
P_ACCEPT="$("$PY" -c '
import json, re, sys
ctx = json.loads(sys.stdin.read())["hookSpecificOutput"]["additionalContext"]
print(json.loads(re.search(r"\{.*\}", ctx).group(0))["prompt_id"])' <<< "$(typed sess-pm 'yes, run it on those terms')")"
as sess-pm accept-agreement --prompt "$P_ACCEPT"
REPO_T="${WORK}/repos/takeover"
new_repo "$REPO_T"
seed_remit "$RUN" "$REPO_T"

it "setup: a running programme with a remit repo and no recorded worktree"
check "None" "$(recorded "$RUN")"

it "a takeover records no worktree and makes no worktree git call"
snapshot "w2:p31|scratch|sess-w2|term_p31"
: > "$GITLOG"
typed sess-c '/auto:programme-takeover' >/dev/null
as sess-c takeover
check "0 None 0 0 nodir" "$CODE $(recorded "$RUN") $(grep -c worktree "$GITLOG") $(made_worktree "$REPO_T")"

it "the takeover restore text asks for no move"
case "$OUT" in *'Run `cd'*|*'/cd '*) fail "takeover output asks the PM to move: $OUT" ;; *) pass ;; esac

it "the taken_over journal row carries no pm_worktree key"
check "True False" "$(journal_rows_name_worktree "$RUN" taken_over)"

it "a handover records no worktree and makes no worktree git call"
REPO_H="${WORK}/repos/handover"
new_repo "$REPO_H"
seed_remit "$RUN" "$REPO_H"
register sess-c w2:p40 term_p40
snapshot "w2:p40|PM|sess-c|term_p40"
: > "$GITLOG"
typed sess-c '/auto:programme-handover sess-n' >/dev/null
as sess-c handover sess-n
check "0 None 0 0 nodir" "$CODE $(recorded "$RUN") $(grep -c worktree "$GITLOG") $(made_worktree "$REPO_H")"

it "the handed_over journal row carries no pm_worktree key"
check "True False" "$(journal_rows_name_worktree "$RUN" handed_over)"

echo
echo "programme-worktree-arrival.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
