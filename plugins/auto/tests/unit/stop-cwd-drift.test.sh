#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
ON_STOP="${AUTO_ROOT}/lib/on-stop.py"
ON_STOP_SH="${AUTO_ROOT}/.claude/hooks/on-stop.sh"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
check() { if [ "$1" = "$2" ]; then pass; else fail "expected [$1] got [$2]"; fi; }
has()   { if printf '%s' "$2" | grep -qF -- "$1"; then pass; else fail "missing [$1] in: $2"; fi; }
lacks() { if printf '%s' "$2" | grep -qF -- "$1"; then fail "unexpected [$1] in: $2"; else pass; fi; }

echo "stop-cwd-drift.test.sh"

WORK="$(mktemp -d -t auto-stop-drift.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
unset CLAUDE_CODE_SESSION_ID CLAUDE_AUTO_REPO
for v in $(env | sed -n 's/^\(HERDR_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
NOREPO="${WORK}/norepo"
mkdir -p "$NOREPO"

# The macOS temp dir is a symlink (/var -> /private/var), so MAIN and REAL_MAIN name one
# directory two ways.
MAIN="${WORK}/main"
SIB="${WORK}/sibling"
mkdir -p "$MAIN/src" "$SIB"
REAL_MAIN="$(cd "$MAIN" && pwd -P)"

payload() {
  "$PY" -c 'import json,sys; d={"session_id": sys.argv[1], "cwd": sys.argv[2]}; d.update({"stop_hook_active": True} if sys.argv[3] == "1" else {}); print(json.dumps(d))' "$1" "$2" "${3:-0}"
}

stop_py() {
  local sid="$1" cwd="$2" refire="${3:-0}"
  ( cd "$NOREPO" && "$PY" "$ON_STOP" "" <<< "$(payload "$sid" "$cwd" "$refire")" 2>/dev/null ) || true
}

verdict() {
  if [ -z "$(printf '%s' "$1" | tr -d '[:space:]')" ]; then echo allow; return; fi
  if printf '%s' "$1" | grep -q '"decision":[[:space:]]*"block"'; then echo block; return; fi
  if printf '%s' "$1" | grep -q '"decision"'; then echo "other:$1"; else echo allow; fi
}

field() {
  "$PY" -c 'import json,sys; t=sys.stdin.read().strip(); print((json.loads(t) if t else {}).get(sys.argv[1], ""))' "$1"
}

prog() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import datetime, json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
ph = load_lib_module("programme_home")
args = sys.argv[2:]
NOW = datetime.datetime.now(datetime.timezone.utc)
def iso(minutes_ago=0):
    return (NOW - datetime.timedelta(minutes=minutes_ago)).strftime("%Y-%m-%dT%H:%M:%SZ")
sys.path.insert(0, os.path.join(sys.argv[1], "tests", "helpers"))
import programme_records
load = programme_records.load
save = programme_records.save
def waiting(item_id, reporter=None):
    it = ph.new_item(item_id, item_id, state="waiting", now_iso=iso(30))
    it["matched_rule"] = "r1"
    it["owner"] = {"pane": "w2:p1", "terminal_id": None, "session_id": "sess-w"}
    it["waiting_on"] = {"who": "team-x", "watcher": None, "reporter": reporter}
    return it
$(cat)
PYEOF
}

# space sid mode(watched|unwatched) worktree-path ("" = none)
make_programme() {
  prog "$@" <<'EOF'
space, sid, mode, wt = args
run = ph.create_programme([space], sid)["run"]
rec = load(run)
item = "linear:AI-8" if mode == "watched" else "linear:AI-7"
rec["programme"]["items"] = {item: waiting(item, reporter="shawn" if mode == "watched" else None)}
rec["programme"]["agreement"]["accepted"] = {"at": iso(60), "prompt_id": "p000001"}
if wt:
    rec["programme"]["pm_worktree"] = {"path": wt, "repo": os.path.dirname(os.path.dirname(wt)),
                                       "created_at": iso(60)}
save(run, rec)
print(run)
EOF
}

set_worktree() {
  prog "$1" "$2" <<'EOF' >/dev/null
rec = load(args[0]); rec["programme"]["pm_worktree"] = json.loads(args[1]); save(args[0], rec)
EOF
}

# sid|source|cwd rows into the session registry
rows() {
  prog "$@" <<'EOF' >/dev/null
sr = load_lib_module("session_registry")
path = sr.registry_path("default", "w1")
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "a") as fh:
    for spec in args:
        sid, source, cwd = spec.split("|")
        fh.write(json.dumps({"session_id": sid, "source": source, "cwd": cwd, "at": iso(120),
                             "pane_id": "w1:p-" + sid, "interactive": True}) + "\n")
EOF
}

# --- the main programme: watched (it may stop on its own), worktree inside MAIN ---
WT="${MAIN}/worktrees/programme-a"
mkdir -p "$WT/plugins/auto" "${MAIN}/worktrees/programme-a2"
RUN="$(make_programme w2 sess-pm watched "$WT")"
rows "sess-pm|startup|${MAIN}"

it "a PM whose stdin cwd is the worktree stops normally"
check "allow" "$(verdict "$(stop_py sess-pm "$WT")")"

it "a PM whose stdin cwd is a subdirectory of the worktree stops normally"
check "allow" "$(verdict "$(stop_py sess-pm "${WT}/plugins/auto")")"

it "a PM whose stdin cwd names the worktree through a symlinked parent stops normally"
check "allow" "$(verdict "$(stop_py sess-pm "${REAL_MAIN}/worktrees/programme-a")")"

it "a PM in a sibling folder that shares the worktree's name prefix has drifted"
check "block" "$(verdict "$(stop_py sess-pm "${MAIN}/worktrees/programme-a2")")"

it "a PM in the main checkout whose programme may otherwise stop is blocked"
OUT="$(stop_py sess-pm "$MAIN")"
check "block" "$(verdict "$OUT")"

it "the block reason carries the cd into the worktree"
has "cd ${WT}" "$(printf '%s' "$OUT" | field reason)"

it "the repeat block is terse and still carries the cd"
OUT2="$(stop_py sess-pm "$MAIN")"
REASON2="$(printf '%s' "$OUT2" | field reason)"
check "block" "$(verdict "$OUT2")"
has "still may not stop" "$REASON2"
has "cd ${WT}" "$REASON2"

it "a re-fire with stop_hook_active lets the stop through"
check "allow" "$(verdict "$(stop_py sess-pm "$MAIN" 1)")"

it "a drifted PM with an unwatched wait gets both the wait and the cd"
U_WT="${MAIN}/worktrees/programme-u"
mkdir -p "$U_WT"
U_RUN="$(make_programme w3 sess-pmu unwatched "$U_WT")"
rows "sess-pmu|startup|${MAIN}"
U_REASON="$(stop_py sess-pmu "$MAIN" | field reason)"
has "linear:AI-7" "$U_REASON"
has "cd ${U_WT}" "$U_REASON"

it "a worker session in another directory is never blocked for drift"
rows "sess-w|startup|${MAIN}"
check "allow" "$(verdict "$(stop_py sess-w "$MAIN")")"

it "a stop with no cwd in stdin lets the stop through"
OUT="$( cd "$NOREPO" && "$PY" "$ON_STOP" "" <<< '{"session_id":"sess-pm"}' 2>/dev/null )"
check "allow" "$(verdict "$OUT")"

# --- the cd cannot stick: the session started in a sibling worktree ---
S_WT="${MAIN}/worktrees/programme-s"
mkdir -p "$S_WT"
S_RUN="$(make_programme w4 sess-sib watched "$S_WT")"
rows "sess-sib|startup|${SIB}"

it "drift from a session started outside the main checkout is not blocked"
OUT="$(stop_py sess-sib "$SIB")"
check "allow" "$(verdict "$OUT")"

it "that stop gets a systemMessage naming /cd <worktree>"
has "/cd ${S_WT}" "$(printf '%s' "$OUT" | field systemMessage)"

it "a session with no startup row is not blocked and is told /cd"
N_WT="${MAIN}/worktrees/programme-n"
mkdir -p "$N_WT"
make_programme w5 sess-norow watched "$N_WT" >/dev/null
OUT="$(stop_py sess-norow "$MAIN")"
check "allow" "$(verdict "$OUT")"
has "/cd ${N_WT}" "$(printf '%s' "$OUT" | field systemMessage)"

it "an unwatched wait still blocks a /cd-only PM, and the /cd note rides along"
SU_WT="${MAIN}/worktrees/programme-su"
mkdir -p "$SU_WT"
make_programme w6 sess-sibu unwatched "$SU_WT" >/dev/null
rows "sess-sibu|startup|${SIB}"
OUT="$(stop_py sess-sibu "$SIB")"
check "block" "$(verdict "$OUT")"
has "/cd ${SU_WT}" "$(printf '%s' "$OUT" | field systemMessage)"
lacks "cwd_drift" "$(printf '%s' "$OUT" | field reason)"

# --- fail open ---
F_WT="${MAIN}/worktrees/programme-f"
mkdir -p "$F_WT"
F_RUN="$(make_programme w7 sess-f watched "$F_WT")"
rows "sess-f|startup|${MAIN}"

it "fail-open fixture: the drifted PM is blocked before the record is broken"
check "block" "$(verdict "$(stop_py sess-f "$MAIN")")"

it "pm_worktree null lets the stop through"
set_worktree "$F_RUN" 'null'
check "allow" "$(verdict "$(stop_py sess-f "$MAIN")")"

it "a recorded worktree path that no longer exists lets the stop through"
set_worktree "$F_RUN" "{\"path\": \"${MAIN}/worktrees/programme-gone\", \"repo\": \"${MAIN}\"}"
check "allow" "$(verdict "$(stop_py sess-f "$MAIN")")"

it "a malformed pm_worktree lets the stop through"
set_worktree "$F_RUN" '"junk"'
A="$(verdict "$(stop_py sess-f "$MAIN")")"
set_worktree "$F_RUN" '{"path": 5}'
check "allow allow" "$A $(verdict "$(stop_py sess-f "$MAIN")")"

it "an ended programme lets the stop through"
E_WT="${MAIN}/worktrees/programme-e"
mkdir -p "$E_WT"
E_RUN="$(make_programme w8 sess-e watched "$E_WT")"
rows "sess-e|startup|${MAIN}"
B="$(verdict "$(stop_py sess-e "$MAIN")")"
prog "$E_RUN" <<'EOF' >/dev/null
ph.end_programme(args[0], "test")
EOF
check "block allow" "$B $(verdict "$(stop_py sess-e "$MAIN")")"

it "programme status output is the same from inside the worktree and from a drifted cwd"
S_IN="$( cd "$WT" && bash "${AUTO_ROOT}/lib/programme.sh" status --run "$RUN" 2>&1 )"
stop_py sess-pm "$MAIN" >/dev/null
S_OUT="$( cd "$MAIN" && bash "${AUTO_ROOT}/lib/programme.sh" status --run "$RUN" 2>&1 )"
if [ -n "$S_IN" ] && [ "$S_IN" = "$S_OUT" ]; then pass; else fail "inside: [$S_IN] drifted: [$S_OUT]"; fi

it "programme status never names cwd_drift"
lacks "cwd_drift" "$S_OUT"

it "the shim blocks a drifted PM from a cwd outside any repo"
OUT="$( cd "$NOREPO" && bash "$ON_STOP_SH" <<< "$(payload sess-pm "$MAIN")" )"
check "block" "$(verdict "$OUT")"

it "setting every CLAUDE_AUTO_* variable does not turn the drift block off"
ENV_ARGS=()
for v in $(grep -rhoE 'CLAUDE_AUTO_[A-Z0-9_]+' "${AUTO_ROOT}/lib" "${AUTO_ROOT}/.claude/hooks" | sort -u); do
  case "$v" in
    *_|CLAUDE_AUTO_DATA_DIR|CLAUDE_AUTO_PYTHON3) ;;
    CLAUDE_AUTO_REPO) ENV_ARGS+=("$v=$MAIN") ;;
    CLAUDE_AUTO_TASKS_DIR|CLAUDE_AUTO_SECRETS_FILE|CLAUDE_AUTO_CARRYOVER_STORE) ENV_ARGS+=("$v=${WORK}/env-${v}") ;;
    *) ENV_ARGS+=("$v=1") ;;
  esac
done
OUT="$( cd "$NOREPO" && env "${ENV_ARGS[@]}" bash "$ON_STOP_SH" <<< "$(payload sess-pm "$MAIN")" )"
if [ "${#ENV_ARGS[@]}" -gt 10 ] && [ "$(verdict "$OUT")" = block ]; then pass; else fail "vars: ${#ENV_ARGS[@]} out: $OUT"; fi

echo ""
echo "stop-cwd-drift.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
