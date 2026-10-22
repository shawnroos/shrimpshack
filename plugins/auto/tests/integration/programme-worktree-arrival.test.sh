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
CHILDREN=""
trap 'for p in $CHILDREN; do kill -9 "$p" 2>/dev/null; done; rm -rf "$WORK"' EXIT

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

registered_count() {
  git -C "$1" worktree list --porcelain | grep -c "^worktree ${1}/worktrees/programme-${2}$"
}

journal_has() {
  run_py "$1" "$2" "$3" <<'EOF'
rows = [r for r in pj.read(args[0]) if r["kind"] == args[1]]
print(any(args[2] in json.dumps(r) for r in rows))
EOF
}

new_repo() {
  git init -q "$1" && git -C "$1" commit -q --allow-empty -m init
}

# A programme as it was before this change: remit repos set straight on the record, pm_worktree null.
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

it "set-remit with no repos records nothing and makes no worktree git call"
: > "$GITLOG"
remit sess-r "$RUN1" '{"tracker": {"teams": [{"key": "AI"}]}}'
check "0 None 0" "$CODE $(recorded "$RUN1") $(grep -c worktree "$GITLOG")"

it "set-remit adding the first repo creates and records the worktree"
remit sess-r "$RUN1" "{\"repos\": [{\"path\": \"${REPO_A}\"}]}"
check "0 ${REPO_A}/worktrees/programme-${RUN1} 1" "$CODE $(recorded "$RUN1") $(registered_count "$REPO_A" "$RUN1")"
has "\"pm_worktree\": {" "$OUT"

it "the git wrapper sees the creating call, so a zero count of worktree calls is evidence"
check "1" "$(grep -c "worktree add --detach ${REPO_A}/worktrees/programme-${RUN1}" "$GITLOG")"
has "${REPO_A}/worktrees/programme-${RUN1}" "$OUT"

it "the created worktree is detached"
check "1" "$(git -C "$REPO_A" worktree list --porcelain | grep -A3 "^worktree ${REPO_A}/worktrees/programme-${RUN1}$" | grep -c '^detached$')"

it "status shows the recorded worktree"
as sess-r status --run "$RUN1"
has "Programme worktree: ${REPO_A}/worktrees/programme-${RUN1}." "$OUT"

it "a second set-remit adding another repo leaves the record unchanged and makes no worktree"
: > "$GITLOG"
remit sess-r "$RUN1" "{\"repos\": [{\"path\": \"${REPO_A}\"}, {\"path\": \"${REPO_B}\"}]}"
check "0 ${REPO_A}/worktrees/programme-${RUN1} 0 0" \
  "$CODE $(recorded "$RUN1") $(grep -c 'worktree add' "$GITLOG") $(git -C "$REPO_B" worktree list --porcelain | grep -c programme-)"

it "reordering the repos leaves the record unchanged"
remit sess-r "$RUN1" "{\"repos\": [{\"path\": \"${REPO_B}\"}, {\"path\": \"${REPO_A}\"}]}"
check "0 ${REPO_A}/worktrees/programme-${RUN1}" "$CODE $(recorded "$RUN1")"

it "removing the recorded repo leaves the record unchanged and status notes it"
remit sess-r "$RUN1" "{\"repos\": [{\"path\": \"${REPO_B}\"}]}"
check "0 ${REPO_A}/worktrees/programme-${RUN1} 1" "$CODE $(recorded "$RUN1") $(registered_count "$REPO_A" "$RUN1")"
as sess-r status --run "$RUN1"
has "(its repo ${REPO_A} is no longer in the remit)" "$OUT"

it "a create that cannot run does not fail set-remit and says why"
RUN2="$(start_programme sess-s w6)"
NOCOMMITS="${WORK}/repos/empty"
git init -q "$NOCOMMITS"
remit sess-s "$RUN2" "{\"repos\": [{\"path\": \"${NOCOMMITS}\"}]}"
check "0 None" "$CODE $(recorded "$RUN2")"
has '"pm_worktree_error":' "$OUT"

# ── race: two set-remits adding the first repo ───────────────────────────
cat > "${WORK}/pause_shim.py" <<'EOF'
import fcntl, os, runpy, sys
gate, script = sys.argv[1], sys.argv[2]
real = fcntl.flock
seen = {"n": 0}
def flock(fd, op):
    if op & fcntl.LOCK_EX:
        seen["n"] += 1
        if seen["n"] == 1:
            print("shim:paused", flush=True)
            while not os.path.exists(gate):
                import time; time.sleep(0.05)
    return real(fd, op)
fcntl.flock = flock
sys.argv = [script] + sys.argv[3:]
sys.path.insert(0, os.path.dirname(script))
runpy.run_path(script, run_name="__main__")
EOF

wait_for() {
  local i
  for i in $(seq 1 200); do grep -q "$2" "$1" 2>/dev/null && return 0; sleep 0.05; done
  return 1
}

REPO_R="${WORK}/repos/race"
new_repo "$REPO_R"
RUN3="$(start_programme sess-t w7)"
GATE="${WORK}/gate"
LOG="${WORK}/racer.log"
( printf '%s' "{\"repos\": [{\"path\": \"${REPO_R}\"}]}" | CLAUDE_CODE_SESSION_ID=sess-t HERDR_WORKSPACE_ID=w2 \
    "$PY" "${WORK}/pause_shim.py" "$GATE" "$PROG" set-remit --run "$RUN3" > "$LOG" 2>&1 ) &
P=$!
CHILDREN="$CHILDREN $P"
it "race: the first creator pauses under the lock with its worktree already made"
wait_for "$LOG" "shim:paused" || fail "the first set-remit never paused"
check "1 None" "$(registered_count "$REPO_R" "$RUN3") $(recorded "$RUN3")"

it "race: the second creator adopts the worktree and records it"
remit sess-t "$RUN3" "{\"repos\": [{\"path\": \"${REPO_R}\"}]}"
check "0 ${REPO_R}/worktrees/programme-${RUN3}" "$CODE $(recorded "$RUN3")"
FIRST_AT="$(run_py "$RUN3" <<'EOF'
print(programme_records.load(args[0])["programme"]["pm_worktree"]["created_at"])
EOF
)"

it "race: the first creator finishes without replacing the record, and one worktree remains"
touch "$GATE"
wait "$P"
RC=$?
LATE_AT="$(run_py "$RUN3" <<'EOF'
print(programme_records.load(args[0])["programme"]["pm_worktree"]["created_at"])
EOF
)"
check "0 1 ${FIRST_AT} yes" "$RC $(registered_count "$REPO_R" "$RUN3") ${LATE_AT} $([ -d "${REPO_R}/worktrees/programme-${RUN3}" ] && echo yes)"

it "race: the late write does not carry a second record"
check "False" "$("$PY" -c 'import json,sys; print("pm_worktree" in json.loads(sys.stdin.read().splitlines()[-1]))' < "$LOG")"

# ── takeover and handover of a programme recorded before this change ────
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

it "a takeover refused after creation leaves the worktree registered but unrecorded"
typed sess-b '/auto:programme-takeover' >/dev/null
as sess-b takeover
check "1 sess-pm None 1" "$CODE $(run_py "$RUN" <<'EOF'
print(programme_records.load(args[0]).get("driving_session_id"))
EOF
) $(recorded "$RUN") $(registered_count "$REPO_T" "$RUN")"

it "the next takeover adopts and records it, with its path in the JSON line"
snapshot "w2:p31|scratch|sess-w2|term_p31"
typed sess-c '/auto:programme-takeover' >/dev/null
as sess-c takeover
check "0 ${REPO_T}/worktrees/programme-${RUN} 1" "$CODE $(recorded "$RUN") $(registered_count "$REPO_T" "$RUN")"
has "\"path\": \"${REPO_T}/worktrees/programme-${RUN}\"" "$(head -1 <<< "$OUT")"

it "the taken_over journal row carries the worktree"
check "True" "$(journal_has "$RUN" taken_over "programme-${RUN}")"

it "a handover of a programme with no recorded worktree creates it"
REPO_H="${WORK}/repos/handover"
new_repo "$REPO_H"
seed_remit "$RUN" "$REPO_H"
register sess-c w2:p40 term_p40
snapshot "w2:p40|PM|sess-c|term_p40"
typed sess-c '/auto:programme-handover sess-n' >/dev/null
as sess-c handover sess-n
check "0 ${REPO_H}/worktrees/programme-${RUN} 1" "$CODE $(recorded "$RUN") $(registered_count "$REPO_H" "$RUN")"
has "programme-${RUN}" "$OUT"

it "the handed_over journal row carries the worktree"
check "True" "$(journal_has "$RUN" handed_over "${REPO_H}/worktrees/programme-${RUN}")"

it "takeover and handover of a programme with no remit repos record nothing and make no worktree git call"
seed_remit "$RUN" ""
: > "$GITLOG"
register sess-n w2:p50 term_p50
snapshot "w2:p31|scratch|sess-w2|term_p31"
typed sess-d '/auto:programme-takeover' >/dev/null
as sess-d takeover
TO="$CODE"
register sess-d w2:p60 term_p60
snapshot "w2:p60|PM|sess-d|term_p60"
typed sess-d '/auto:programme-handover sess-e' >/dev/null
as sess-d handover sess-e
check "0 0 None 0" "$TO $CODE $(recorded "$RUN") $(grep -c worktree "$GITLOG")"

echo
echo "programme-worktree-arrival.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
