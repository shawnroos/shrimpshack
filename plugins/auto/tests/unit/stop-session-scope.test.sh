#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
ON_STOP="${AUTO_ROOT}/lib/on-stop.py"
ON_STOP_SH="${AUTO_ROOT}/.claude/hooks/on-stop.sh"
ASKUSER="${AUTO_ROOT}/lib/on-pretooluse-askuser.py"
RESUME="${AUTO_ROOT}/lib/auto-resume.py"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
check() { if [ "$1" = "$2" ]; then pass; else fail "expected [$1] got [$2]"; fi; }

echo "stop-session-scope.test.sh"

WORK="$(mktemp -d -t auto-stop-scope.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
unset CLAUDE_CODE_SESSION_ID CLAUDE_AUTO_REPO
for v in $(env | sed -n 's/^\(HERDR_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
NOREPO="${WORK}/norepo"
mkdir -p "$NOREPO"

payload() {
  "$PY" -c 'import json,sys; d={"session_id": sys.argv[1]} if sys.argv[1] else {}; d.update({"stop_hook_active": True} if sys.argv[2] == "1" else {}); print(json.dumps(d))' "$1" "${2:-0}"
}

stop_py() {
  local repo="$1" sid="$2" refire="${3:-0}"
  ( cd "${repo:-$NOREPO}" && "$PY" "$ON_STOP" "$repo" <<< "$(payload "$sid" "$refire")" 2>/dev/null ) || true
}

verdict() {
  if [ -z "$(printf '%s' "$1" | tr -d '[:space:]')" ]; then echo allow; return; fi
  if printf '%s' "$1" | grep -q '"decision":[[:space:]]*"block"'; then echo block; else echo "other:$1"; fi
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
def rec_path(run):
    return os.path.join(ph.home_path(run), ".claude", "auto", run + ".json")
def load(run):
    return json.load(open(rec_path(run)))
def save(run, rec):
    json.dump(rec, open(rec_path(run), "w"))
def waiting(item_id, reporter=None, watcher=None):
    it = ph.new_item(item_id, item_id, state="waiting", now_iso=iso(30))
    it["matched_rule"] = "r1"
    it["owner"] = {"pane": "w2:p1", "terminal_id": None, "session_id": "sess-w"}
    it["waiting_on"] = {"who": "team-x", "watcher": watcher, "reporter": reporter}
    return it
$(cat)
PYEOF
}

make_programme() {
  local space="$1" sid="$2" mode="$3"
  prog "$space" "$sid" "$mode" <<'EOF'
space, sid, mode = args
made = ph.create_programme([space], sid)
run = made["run"]
rec = load(run)
items = {}
if mode == "unwatched":
    items["linear:AI-7"] = waiting("linear:AI-7")
elif mode == "watched":
    items["linear:AI-8"] = waiting("linear:AI-8", reporter="shawn")
rec["programme"]["items"] = items
rec["programme"]["agreement"]["accepted"] = {"at": iso(60), "prompt_id": "p000001"}
rec.setdefault("agent_session_ids", []).append("sess-fork")
save(run, rec)
print(run)
EOF
}

plant_task() {
  local repo="$1" run="$2" driver="${3:-}" agents="${4:-}"
  mkdir -p "${repo}/.claude/auto"
  "$PY" - "$repo" "$run" "$driver" "$agents" <<'PYEOF'
import json, os, sys
repo, run, driver, agents = sys.argv[1:5]
data = {
  "run_id": run, "loop_phase": "work",
  "loop": {"driver": "self", "last_beat_at": "2099-01-01T00:00:00Z"},
  "exit_predicate_result": {"met": False, "blockers": 0, "majors": 0, "all_steps_terminal": False},
}
if driver:
    data["driving_session_id"] = driver
if agents:
    data["agent_session_ids"] = agents.split(",")
json.dump(data, open(os.path.join(repo, ".claude", "auto", run + ".json"), "w"))
PYEOF
}

make_batch_repo() {
  local d; d="$(mktemp -d "${WORK}/batch.XXXXXX")"
  ( cd "$d" && git init -q && git -c user.email=t@t -c user.name=t commit --allow-empty -q -m init && mkdir -p .claude/auto/batches )
  echo "$d"
}

plant_sidecar() {
  local repo="$1" wt="$2" host="${3:-}"
  "$PY" - "$repo" "$wt" "$host" <<'PYEOF'
import json, sys
repo, wt, host = sys.argv[1:4]
sidecar = {"id": "b1", "created_at": "2099-01-01T00:00:00Z", "status": "committed",
           "composite_intent": "t", "plans": [{"path": "a", "slug": "plan-a", "worktree": wt,
           "branch": "x", "port": 3001, "suggested_run_id": "plan-a-1"}]}
if host:
    sidecar["host_session_id"] = host
json.dump(sidecar, open(repo + "/.claude/auto/batches/b1.json", "w"))
PYEOF
}

PM_RUN="$(make_programme w2 sess-pm unwatched)"
PM_HOME="${CLAUDE_AUTO_DATA_DIR}/programmes/${PM_RUN}"
REPO="${WORK}/repo"
mkdir -p "${REPO}/.claude/auto"

it "a fork with a new session id stops while the PM has an unwatched wait: allowed"
check "allow" "$(verdict "$(stop_py "$REPO" sess-fork)")"

it "the fork's stop writes no nag state"
check "0" "$(find "$REPO/.claude/auto" "$PM_HOME" -name '.stop-nag*' 2>/dev/null | wc -l | tr -d ' ')"

it "a fork that ran register-session on the PM's programme and a task run stops: allowed"
plant_task "$REPO" "pm-task" "sess-pm" "sess-fork"
check "allow" "$(verdict "$(stop_py "$REPO" sess-fork)")"
rm -f "${REPO}/.claude/auto/pm-task.json"

it "the PM stops with an unwatched wait: blocked"
OUT="$(stop_py "" sess-pm)"
check "block" "$(verdict "$OUT")"

it "the PM's block reason names the unwatched item"
if printf '%s' "$OUT" | grep -q 'linear:AI-7' && printf '%s' "$OUT" | grep -q 'unwatched'; then pass; else fail "got: $OUT"; fi

it "the PM's re-fire is allowed"
check "allow" "$(verdict "$(stop_py "" sess-pm 1)")"

it "the re-fire journals stopped_unwatched with the item"
GOT="$("$PY" - "$PM_HOME/journal.jsonl" <<'EOF'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
hit = [r for r in rows if r["kind"] == "stopped_unwatched"]
print(len(hit), hit[0]["session_id"] if hit else "-", hit[0]["payload"]["items"] if hit else "-",
      any(k in r for r in hit for k in ("run_id", "loop")))
EOF
)"
check "1 sess-pm ['linear:AI-7'] False" "$GOT"

it "a fork's re-fire journals nothing"
stop_py "" sess-fork 1 >/dev/null
check "1" "$(grep -c stopped_unwatched "$PM_HOME/journal.jsonl")"

it "the PM stops with every wait watched: allowed on the first attempt"
W_RUN="$(make_programme w3 sess-pm2 watched)"
check "allow" "$(verdict "$(stop_py "" sess-pm2)")"

it "the watched PM's re-fire journals nothing"
check "0" "$( [ -f "${CLAUDE_AUTO_DATA_DIR}/programmes/${W_RUN}/journal.jsonl" ] && grep -c stopped_unwatched "${CLAUDE_AUTO_DATA_DIR}/programmes/${W_RUN}/journal.jsonl" || echo 0)"

it "an unread claim in the home's inbox holds the watched PM"
printf '{"claim":1}\n' > "${CLAUDE_AUTO_DATA_DIR}/programmes/${W_RUN}/claims.jsonl"
check "block" "$(verdict "$(stop_py "" sess-pm2)")"
rm -f "${CLAUDE_AUTO_DATA_DIR}/programmes/${W_RUN}/claims.jsonl"

it "a malformed programme home never blocks"
M_RUN="$(make_programme w4 sess-pm3 unwatched)"
printf '{ not json' > "${CLAUDE_AUTO_DATA_DIR}/programmes/${M_RUN}/.claude/auto/${M_RUN}.json"
check "allow" "$(verdict "$(stop_py "" sess-pm3)")"

it "a programme block that is not a dict never blocks"
C_RUN="$(make_programme w5 sess-pm4 unwatched)"
prog "$C_RUN" <<'EOF' >/dev/null
rec = load(args[0]); rec["programme"] = "broken"; save(args[0], rec)
EOF
check "allow" "$(verdict "$(stop_py "" sess-pm4)")"

it "a programme written by a newer format never blocks"
N_RUN="$(make_programme w6 sess-pm5 unwatched)"
prog "$N_RUN" <<'EOF' >/dev/null
rec = load(args[0]); rec["programme_format"] = 99; save(args[0], rec)
EOF
check "allow" "$(verdict "$(stop_py "" sess-pm5)")"

it "an ended programme never blocks"
E_RUN="$(make_programme w7 sess-pm6 unwatched)"
prog "$E_RUN" <<'EOF' >/dev/null
ph.end_programme(args[0], "test")
EOF
check "allow" "$(verdict "$(stop_py "" sess-pm6)")"

it "with the compact flag set, the block reason says the rules were reloaded and does not repeat them"
touch "${PM_HOME}/.compact-flag"
GOT="$("$PY" - "$AUTO_ROOT" <<'EOF'
import importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location("on_stop", os.path.join(sys.argv[1], "lib", "on-stop.py"))
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
reason = (mod.decide("", json.dumps({"session_id": "sess-pm"})) or {}).get("reason", "")
print("Rules in force were reloaded after compaction" in reason, "<auto-rules>" in reason)
EOF
)"
check "True False" "$GOT"

it "without the compact flag, the block reason does not mention reloaded rules"
rm -f "${PM_HOME}/.compact-flag"
GOT="$("$PY" - "$AUTO_ROOT" <<'EOF'
import importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location("on_stop", os.path.join(sys.argv[1], "lib", "on-stop.py"))
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
out = mod.decide("", json.dumps({"session_id": "sess-pm"})) or {}
print(out.get("decision"), "Rules in force were reloaded" in out.get("reason", ""))
EOF
)"
check "block False" "$GOT"

it "the shim runs the check from a cwd outside any repo when a lease exists"
OUT="$( cd "$NOREPO" && bash "$ON_STOP_SH" <<< "$(payload sess-pm)" )"
check "block" "$(verdict "$OUT")"

it "the shim runs no Python with no repo and no lease"
MARK="${WORK}/marker-py"
printf '#!/usr/bin/env bash\ntouch "%s/python-ran"\n' "$WORK" > "$MARK"; chmod +x "$MARK"
( cd "$NOREPO" && CLAUDE_AUTO_DATA_DIR="${WORK}/empty-data" CLAUDE_AUTO_PYTHON3="$MARK" bash "$ON_STOP_SH" <<< '{}' )
check "no" "$( [ -e "${WORK}/python-ran" ] && echo yes || echo no )"

it "the shim and programme_home agree on the default data dir"
DEF="$(sed -n 's/^DEFAULT_DATA_DIR = "~\/\(.*\)"$/\1/p' "${AUTO_ROOT}/lib/programme_home.py")"
if grep -qF "\${HOME:-}/${DEF}" "$ON_STOP_SH"; then pass; else fail "default data dir differs"; fi

T="${WORK}/task"
mkdir -p "${T}/.claude/auto"
plant_task "$T" "owned" "sess-A"

it "a task run's driving session stops with steps open: blocked"
check "block" "$(verdict "$(stop_py "$T" sess-A)")"

it "another session in the same repo stops during that task run: allowed"
check "allow" "$(verdict "$(stop_py "$T" sess-Z)")"

it "a stop with no session id is still held by a task run that records a driver"
check "block" "$(verdict "$(stop_py "$T" "")")"

L="${WORK}/legacy"
mkdir -p "${L}/.claude/auto"
plant_task "$L" "legacy" ""

it "a legacy task run with no driving session holds any session in the repo"
check "block" "$(verdict "$(stop_py "$L" sess-Z)")"

it "two sessions blocked by different runs keep separate nag alternation"
D="${WORK}/two"
mkdir -p "${D}/.claude/auto"
plant_task "$D" "run-a" "sess-A"
plant_task "$D" "run-b" "sess-B"
full() { printf '%s' "$1" | grep -q 'YIELD silently' && echo full || echo terse; }
A1="$(full "$(stop_py "$D" sess-A)")"
B1="$(full "$(stop_py "$D" sess-B)")"
A2="$(full "$(stop_py "$D" sess-A)")"
B2="$(full "$(stop_py "$D" sess-B)")"
check "full full terse terse" "$A1 $B1 $A2 $B2"

it "nag state lives in per-session dot files"
check "2" "$(find "${D}/.claude/auto" -maxdepth 1 -name '.stop-nag-*.json' | wc -l | tr -d ' ')"

it "the PM's repeated block is terse the second time"
P1="$(stop_py "" sess-pm)"
P2="$(stop_py "" sess-pm)"
if printf '%s' "$P2" | grep -q 'still may not stop' && [ "$(verdict "$P2")" = block ]; then pass; else fail "got: $P2"; fi

it "after /auto-resume continue from session B, B is held and A is not"
RS="${WORK}/resumed"
mkdir -p "${RS}/.claude/auto"
"$PY" - "$AUTO_ROOT" "$RS" <<'EOF'
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_run_record
L = load_run_record()
L.init_run_record(sys.argv[2], "resumed", backend="ce", loop_phase="work",
                  steps=[{"id": "S1", "state": "pending"}], driving_session_id="sess-A")
L.set_loop(sys.argv[2], "resumed", driver="manual", blocked_on="waiting on a human")
EOF
( cd "$RS" && CLAUDE_AUTO_REPO="$RS" CLAUDE_CODE_SESSION_ID=sess-B "$PY" "$RESUME" continue resumed >/dev/null 2>&1 )
check "block allow" "$(verdict "$(stop_py "$RS" sess-B)") $(verdict "$(stop_py "$RS" sess-A)")"

B="$(make_batch_repo)"
WT="${B}/worktrees/plan-a"
mkdir -p "$WT"
plant_task "$WT" "plan-a-1" "sess-child"
plant_sidecar "$B" "$WT" "sess-H"

it "a batch with host_session_id holds its host"
check "block" "$(verdict "$(stop_py "$B" sess-H)")"

it "a batch with host_session_id does not hold another session"
check "allow" "$(verdict "$(stop_py "$B" sess-Z)")"

it "a batch sidecar without host_session_id holds every session in the repo"
plant_sidecar "$B" "$WT" ""
check "block" "$(verdict "$(stop_py "$B" sess-Z)")"

it "the PM's AskUserQuestion during a live programme is not redirected"
AQ="${WORK}/askq"
mkdir -p "${AQ}/.claude/auto"
"$PY" - "$AQ" <<'EOF'
import json, os, sys
data = {"run_id": "prog-x", "run_kind": "programme", "programme_format": 1, "loop_phase": "work",
        "loop": {"driver": "self", "last_beat_at": "2099-01-01T00:00:00Z"},
        "driving_session_id": "sess-pm", "steps": []}
json.dump(data, open(os.path.join(sys.argv[1], ".claude", "auto", "prog-x.json"), "w"))
EOF
OUT="$( cd "$AQ" && "$PY" "$ASKUSER" "$AQ" <<< '{"session_id":"sess-pm","tool_name":"AskUserQuestion"}' )"
check "" "$OUT"

it "a task run's driver is still redirected"
plant_task "$AQ" "task-q" "sess-q"
OUT="$( cd "$AQ" && "$PY" "$ASKUSER" "$AQ" <<< '{"session_id":"sess-q","tool_name":"AskUserQuestion"}' )"
if printf '%s' "$OUT" | grep -q '"permissionDecision": "deny"'; then pass; else fail "got: $OUT"; fi

it "the PM's AskUserQuestion from a lease with no repo is not redirected"
OUT="$( cd "$NOREPO" && "$PY" "$ASKUSER" "" <<< '{"session_id":"sess-pm","tool_name":"AskUserQuestion"}' 2>/dev/null )"
check "" "$OUT"

echo ""
echo "stop-session-scope.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
