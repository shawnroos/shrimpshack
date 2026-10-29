#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
PROG="${AUTO_ROOT}/lib/programme.py"
WATCH="${AUTO_ROOT}/lib/programme-watch.sh"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
check() { if [ "$1" = "$2" ]; then pass; else fail "expected [$1] got [$2]"; fi; }
has() { case "$2" in *"$1"*) pass ;; *) fail "expected to find [$1] in [$2]" ;; esac; }
lacks() { case "$2" in *"$1"*) fail "did not expect [$1] in [$2]" ;; *) pass ;; esac; }
atleast() { if [ "$2" -ge "$1" ] 2>/dev/null; then pass; else fail "expected at least [$1] got [$2]"; fi; }

echo "programme-watch.test.sh"

WORK="$(mktemp -d -t auto-programme-watch.XXXXXX)"
BG_PIDS=""
cleanup() {
  for p in $BG_PIDS; do kill "$p" 2>/dev/null; done
  rm -rf "$WORK"
}
trap cleanup EXIT

export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_MACHINE="studio"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_CODE_SESSION_ID="sess-pm"
export CLAUDE_AUTO_WATCH_INTERVAL_SECONDS="0.3"
# Held lines go out on the next poll, so the single-change tests below see them within one interval.
export CLAUDE_AUTO_WATCH_COLLAPSE_SECONDS="0.01"
unset HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_BIN_PATH CLAUDE_AUTO_REPO 2>/dev/null || true
: > "$CLAUDE_AUTO_SECRETS_FILE"

FAKES="${WORK}/fakes"
mkdir -p "$FAKES"
SNAP="${WORK}/snapshot.json"
HERDR_EXIT_FILE="${WORK}/herdr-exit"
BOARD_JSON="${WORK}/board.json"
BOARD_EXIT_FILE="${WORK}/board-exit"
HERDR_CALLS="${WORK}/herdr-calls.log"
cat > "${FAKES}/herdr" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "${HERDR_CALLS}"
if [ -f "${HERDR_EXIT_FILE}" ]; then echo "herdr: server not running" >&2; exit "\$(cat "${HERDR_EXIT_FILE}")"; fi
[ "\$1 \$2" = "api snapshot" ] || exit 2
cat "${SNAP}"
EOF
cat > "${FAKES}/board" <<EOF
#!/bin/sh
if [ -f "${BOARD_EXIT_FILE}" ]; then echo '{"error":{"code":7,"message":"unsupported"}}'; exit "\$(cat "${BOARD_EXIT_FILE}")"; fi
cat "${BOARD_JSON}"
EOF
chmod +x "${FAKES}/herdr" "${FAKES}/board"
export PATH="${FAKES}:${PATH}"

BEATS="${WORK}/beats.log"
cat > "${FAKES}/programme-cli" <<EOF
#!/bin/sh
"${PY}" "${PROG}" "\$@"
rc=\$?
printf '%s\n' "\$*" >> "${BEATS}"
exit \$rc
EOF
chmod +x "${FAKES}/programme-cli"
export CLAUDE_AUTO_PROGRAMME_CLI="${FAKES}/programme-cli"

snap() {
  "$PY" - "$SNAP" "$@" <<'PYEOF'
import json, os, sys
path, seq, own_seq, other_seq = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
panes = sys.argv[5].split(",") if len(sys.argv) > 5 else ["w2:p1", "w2:p2"]
snapshot = {
    "agents": [
        {"pane_id": "w2:p1", "workspace_id": "w2", "state_change_seq": own_seq, "agent_status": "working"},
        {"pane_id": "w2:p2", "workspace_id": "w2", "state_change_seq": seq, "agent_status": "idle"},
        {"pane_id": "w9:p1", "workspace_id": "w9", "state_change_seq": other_seq, "agent_status": "idle"},
    ],
    "panes": [{"pane_id": p, "workspace_id": p.split(":")[0], "revision": 7,
               "cwd": os.environ.get("SNAP_CWD") if p.startswith("w2:") else None} for p in panes + ["w9:p1"]],
    "tabs": [], "workspaces": [{"workspace_id": "w2"}, {"workspace_id": "w9"}],
}
with open(path, "w") as fh:
    json.dump({"id": "cli:api:snapshot", "result": {"snapshot": snapshot}}, fh)
PYEOF
}

board_json() {
  printf '{"issues":[{"identifier":"AI-1","updatedAt":"%s"},{"identifier":"AI-2","updatedAt":"2026-01-01T00:00:00Z"}]}\n' "$1" > "$BOARD_JSON"
}

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
ph = load_lib_module("programme_home")
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

field() {
  run_py "$RUN" "$1" <<'EOF'
run, expr = args
prog = record(run)["programme"]
print(json.dumps(eval(expr), sort_keys=True))
EOF
}

edit() {
  run_py "$RUN" "$1" <<'EOF'
run, expr = args
home = ph.home_path(run)
def change(rec):
    prog = rec["programme"]
    exec(expr)
core._with_locked_run_record(home, run, change)
EOF
}

reset_state() {
  edit 'prog["watchers"] = {}; prog["sources"] = {}'
  rm -f "$HERDR_EXIT_FILE" "$BOARD_EXIT_FILE"
  : > "$BEATS"
  snap 41 5 1
  board_json "2026-10-01T00:00:00Z"
}

WPID=""
start_watch() {
  local name="$1"; shift
  bash "$WATCH" --run "$RUN" "$@" > "${WORK}/${name}.out" 2> "${WORK}/${name}.err" &
  WPID=$!
  BG_PIDS="${BG_PIDS} ${WPID}"
}

wait_exit() {
  local pid="$1" limit="${2:-160}" n=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 0.1
    n=$((n + 1))
    if [ "$n" -ge "$limit" ]; then kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 124; fi
  done
  wait "$pid" 2>/dev/null
}

wait_for() {
  local file="$1" pattern="$2" limit="${3:-100}" n=0
  while ! grep -q -- "$pattern" "$file" 2>/dev/null; do
    sleep 0.1
    n=$((n + 1))
    [ "$n" -ge "$limit" ] && return 1
  done
  return 0
}

lines() { if [ -s "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }
count() { grep -c -- "$2" "$1" 2>/dev/null || true; }
alive() { if kill -0 "$1" 2>/dev/null; then echo yes; else echo no; fi; }
stop_watch() { kill "$1" 2>/dev/null; wait "$1" 2>/dev/null; }

reset_state
it "a worker turning busy or idle (its herdr sequence moving) prints nothing and keeps polling"
CLAUDE_AUTO_WATCH_COLLAPSE_SECONDS=0 start_watch seq --max-polls 6
wait_for "$BEATS" "watcher-beat remit" || true
sleep 0.4
snap 42 5 1
wait_exit "$WPID"
check 0 "$(count "${WORK}/seq.out" "remit-changed")"

reset_state
it "a pane added to the remit prints remit-changed naming the pane"
start_watch pane
wait_for "$BEATS" "watcher-beat remit" || true
sleep 0.4
snap 41 5 1 "w2:p1,w2:p2,w2:p3"
wait_for "${WORK}/pane.out" "+w2:p3" || true
has "+w2:p3" "$(cat "${WORK}/pane.out")"
it "a second pane change in the same run prints a second line"
snap 41 5 1 "w2:p1,w2:p2,w2:p3,w2:p4"
wait_for "${WORK}/pane.out" "+w2:p4" || true
check 2 "$(lines "${WORK}/pane.out")"
it "the watcher is still running after both changes"
sleep 0.7
check yes "$(alive "$WPID")"
check 2 "$(lines "${WORK}/pane.out")"
stop_watch "$WPID"

reset_state
it "changes outside the remit workspace never wake the watcher"
start_watch other --max-polls 4
sleep 0.4
snap 41 5 99 "w2:p1,w2:p2"
wait_exit "$WPID"
check 0 "$?"
it "the outside change leaves stdout empty"
check 0 "$(lines "${WORK}/other.out")"

reset_state
it "the PM's own pane changing state does not wake it"
HERDR_PANE_ID="w2:p1" start_watch own --max-polls 4
sleep 0.4
snap 41 6 1
wait_exit "$WPID"
check 0 "$(lines "${WORK}/own.out")"

reset_state
it "a claim appended to the inbox prints claim"
add_claim() {
  run_py "$RUN" <<'EOF' >/dev/null
load_lib_module("programme_journal").append_claim(args[0], "sess-w", {"item": "linear:AI-1", "deliverable": "merged", "ref": "pr-1"})
EOF
}
add_claim
start_watch claim
wait_for "$BEATS" "watcher-beat remit" || true
sleep 0.4
add_claim
wait_for "${WORK}/claim.out" "claim" || true
has "claim" "$(cat "${WORK}/claim.out")"
it "the claim line counts only the new claim"
has "claim 1 new" "$(cat "${WORK}/claim.out")"
it "the watcher keeps polling after the claim line"
sleep 0.7
check yes "$(alive "$WPID")"
check 1 "$(lines "${WORK}/claim.out")"
stop_watch "$WPID"

reset_state
it "nothing changes for 3 intervals: no stdout"
start_watch quiet --max-polls 3
QPID="$WPID"
wait_exit "$WPID"
check 0 "$(lines "${WORK}/quiet.out")"
it "the remit watcher beat once at start and once per interval"
check 4 "$(count "$BEATS" "watcher-beat remit")"
it "every beat names the watcher's own pid"
check 4 "$(count "$BEATS" "--process-id ${QPID}")"
it "the record holds the remit watcher's pid"
check "\"${QPID}\"" "$(field 'prog["watchers"]["remit"]["process_id"]')"
it "the record holds a fresh heartbeat"
check "true" "$(run_py "$RUN" <<'EOF'
import datetime
w = record(args[0])["programme"]["watchers"]["remit"]
when = core.parse_iso(w["last_beat_at"])
age = (datetime.datetime.now(datetime.timezone.utc) - when).total_seconds()
print("true" if age < 10 else age)
EOF
)"
it "the beat output never reaches the watcher's stdout"
lacks '"ok"' "$(cat "${WORK}/quiet.out")"

reset_state
it "herdr unavailable prints source-unavailable once and keeps polling"
echo 1 > "$HERDR_EXIT_FILE"
start_watch down --max-polls 4
wait_exit "$WPID"
check 0 "$?"
check 1 "$(count "${WORK}/down.out" "source-unavailable herdr")"
it "herdr unavailable still polls every interval"
atleast 4 "$(count "$HERDR_CALLS" "api snapshot")"
: > "$HERDR_CALLS"
it "herdr unavailable keeps beating"
atleast 4 "$(count "$BEATS" "watcher-beat remit")"

reset_state
it "herdr coming back after an outage prints source-available and keeps polling"
echo 1 > "$HERDR_EXIT_FILE"
start_watch back
wait_for "${WORK}/back.out" "source-unavailable" || true
rm -f "$HERDR_EXIT_FILE"
wait_for "${WORK}/back.out" "source-available" || true
has "source-available herdr" "$(tail -n 1 "${WORK}/back.out")"
sleep 0.7
check yes "$(alive "$WPID")"
it "the recovery prints once, not once per poll"
check 1 "$(count "${WORK}/back.out" "source-available herdr")"
it "a second outage in the same run prints source-unavailable again"
echo 1 > "$HERDR_EXIT_FILE"
sleep 0.9
check 2 "$(count "${WORK}/back.out" "source-unavailable herdr")"
it "down, up, down prints unavailable, available, unavailable in that order"
check "source-unavailable source-available source-unavailable" "$(cut -d' ' -f1 "${WORK}/back.out" | tr '\n' ' ' | sed 's/ $//')"
stop_watch "$WPID"

reset_state
it "a recorded outage that recovers prints source-available once across several polls"
edit 'prog["sources"]["herdr"] = {"unavailable_since": "2026-10-06T10:00:00Z"}'
start_watch recorded --max-polls 4
wait_exit "$WPID"
check 1 "$(count "${WORK}/recorded.out" "source-available herdr")"
check 1 "$(lines "${WORK}/recorded.out")"

reset_state
it "an outage already in the record does not wake the PM again"
edit 'prog["sources"]["herdr"] = {"unavailable_since": "2026-10-06T10:00:00Z"}'
echo 1 > "$HERDR_EXIT_FILE"
start_watch known --max-polls 3
wait_exit "$WPID"
check 0 "$(lines "${WORK}/known.out")"

reset_state
prog() { "$PY" "$PROG" "$@" --run "$RUN" >/dev/null 2>&1; }
prog add-item linear:AI-800 --title "Fix the crop"
prog set-waiting linear:AI-800 --who ci
it "a wait that comes due prints wait-due with the item"
DUE="$("$PY" -c 'import datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(seconds=3)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
edit "prog['items']['linear:AI-800']['waiting_on']['due_at'] = '${DUE}'"
start_watch due
wait_for "${WORK}/due.out" "wait-due" 80 || true
check "wait-due linear:AI-800" "$(cat "${WORK}/due.out")"
it "the watcher keeps polling after a wait comes due"
sleep 0.7
check yes "$(alive "$WPID")"
check 1 "$(lines "${WORK}/due.out")"
stop_watch "$WPID"
it "a wait already past due at start does not wake the PM"
start_watch pastdue --max-polls 2
wait_exit "$WPID"
check 0 "$(lines "${WORK}/pastdue.out")"
edit "prog['items']['linear:AI-800']['waiting_on'].pop('due_at', None)"

reset_state
it "a second watcher for the same programme prints remit-watcher-exit superseded and exits 0"
start_watch first
FIRST="$WPID"
wait_for "$BEATS" "watcher-beat remit" || true
bash "$WATCH" --run "$RUN" --max-polls 2 > "${WORK}/second.out" 2> "${WORK}/second.err"
check 0 "$?"
check "remit-watcher-exit superseded" "$(cat "${WORK}/second.out")"
it "the second watcher says on stderr which watcher is current"
has "$FIRST" "$(cat "${WORK}/second.err")"
it "the first watcher keeps beating after the second exits"
BEFORE="$(count "$BEATS" "--process-id ${FIRST}")"
sleep 1
AFTER="$(count "$BEATS" "--process-id ${FIRST}")"
atleast $((BEFORE + 1)) "$AFTER"
it "the record still names the first watcher"
check "\"${FIRST}\"" "$(field 'prog["watchers"]["remit"]["process_id"]')"
kill "$FIRST" 2>/dev/null; wait "$FIRST" 2>/dev/null

reset_state
edit 'prog["watchers"]["remit"] = {"process_id": "999999", "last_beat_at": "2026-01-01T00:00:00Z"}'
it "a stale remit watcher entry does not block a new watcher"
start_watch stale --max-polls 1
SPID="$WPID"
wait_exit "$WPID"
check "\"${SPID}\"" "$(field 'prog["watchers"]["remit"]["process_id"]')"
it "a process beat records the beating session on the remit watcher"
check '"sess-pm"' "$(field 'prog["watchers"]["remit"].get("session_id")')"

reset_state
sleep 300 &
OLDPID=$!
BG_PIDS="${BG_PIDS} ${OLDPID}"
FRESH="$("$PY" -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
edit "prog['watchers']['remit'] = {'process_id': '${OLDPID}', 'last_beat_at': '${FRESH}', 'session_id': 'sess-old'}"
it "a live remit watcher from a session that no longer drives does not supersede a new one"
start_watch takeover --max-polls 2
TPID="$WPID"
wait_exit "$WPID"
check 0 "$(count "${WORK}/takeover.out" "remit-watcher-exit")"
it "the new driving session's watcher takes over the remit entry"
check "\"${TPID}\"" "$(field 'prog["watchers"]["remit"]["process_id"]')"
edit "prog['watchers']['remit'] = {'process_id': '${OLDPID}', 'last_beat_at': '${FRESH}', 'session_id': 'sess-pm'}"
it "the same live watcher from the driving session does supersede a new one"
start_watch takeover2 --max-polls 2
wait_exit "$WPID"
check "remit-watcher-exit superseded" "$(cat "${WORK}/takeover2.out")"
kill "$OLDPID" 2>/dev/null; wait "$OLDPID" 2>/dev/null

reset_state
OLD_BEAT="2026-01-01T00:00:00Z"
edit "prog['watchers']['remit'] = {'process_id': '12345', 'last_beat_at': '${OLD_BEAT}'}"
it "the PM's watcher-beat --task-id on a monitor watcher leaves its heartbeat unchanged"
"$PY" "$PROG" watcher-beat remit --task-id bmon1 --kind monitor --run "$RUN" > /dev/null 2>&1
check "\"${OLD_BEAT}\"" "$(field 'prog["watchers"]["remit"]["last_beat_at"]')"
it "the monitor task id is still recorded"
check '["bmon1", "monitor"]' "$(field '[prog["watchers"]["remit"]["task_id"], prog["watchers"]["remit"]["kind"]]')"
it "a bare PM beat on a monitor watcher leaves its heartbeat unchanged"
"$PY" "$PROG" watcher-beat remit --run "$RUN" > /dev/null 2>&1
check "\"${OLD_BEAT}\"" "$(field 'prog["watchers"]["remit"]["last_beat_at"]')"
it "a new Monitor-only watcher starts with no heartbeat"
"$PY" "$PROG" watcher-beat w-newmon --task-id bmon2 --kind monitor --run "$RUN" > /dev/null 2>&1
check 'null' "$(field 'prog["watchers"]["w-newmon"]["last_beat_at"]')"
it "a process beat on the monitor watcher still stamps its heartbeat"
"$PY" "$PROG" watcher-beat remit --process-id 12345 --run "$RUN" > /dev/null 2>&1
lacks "$OLD_BEAT" "$(field 'prog["watchers"]["remit"]["last_beat_at"]')"
edit "prog['watchers']['cron'] = {'task_id': 'c-9', 'kind': 'cron', 'last_beat_at': '${OLD_BEAT}'}"
it "the PM's watcher-beat --task-id on a cron watcher still stamps its heartbeat"
"$PY" "$PROG" watcher-beat cron --task-id c-9 --kind cron --run "$RUN" > /dev/null 2>&1
lacks "$OLD_BEAT" "$(field 'prog["watchers"]["cron"]["last_beat_at"]')"

reset_state
it "the tracker is off unless asked for"
start_watch notracker --max-polls 2
wait_exit "$WPID"
lacks "tracker" "$(cat "${WORK}/notracker.out")"
it "a newer tracker updatedAt prints tracker-changed"
: > "$BEATS"
start_watch tracker --tracker
wait_for "$BEATS" "watcher-beat remit" || true
sleep 0.4
board_json "2026-10-06T12:00:00Z"
wait_for "${WORK}/tracker.out" "tracker-changed" || true
has "tracker-changed AI-1" "$(cat "${WORK}/tracker.out")"
it "the watcher keeps polling after a tracker change"
sleep 0.7
check yes "$(alive "$WPID")"
check 1 "$(lines "${WORK}/tracker.out")"
stop_watch "$WPID"
it "--linear is no longer a flag"
bash "$WATCH" --run "$RUN" --linear --max-polls 1 > /dev/null 2>&1
check 2 "$?"
it "a failing tracker read is source-unavailable tracker, and polling goes on"
echo 1 > "$BOARD_EXIT_FILE"
start_watch trackerr --tracker --max-polls 3
wait_exit "$WPID"
check 0 "$?"
check "source-unavailable tracker" "$(cut -d' ' -f1,2 "${WORK}/trackerr.out")"

reset_state
it "a tracker turned off in the agreement is never polled, even with --tracker"
edit 'prog["agreement"]["terms"]["tools_of_record"]["value"] = ["tasks", "plans"]'
echo 1 > "$BOARD_EXIT_FILE"
start_watch trackeroff --tracker --max-polls 3
wait_exit "$WPID"
check 0 "$(lines "${WORK}/trackeroff.out")"
has "turns the tracker off" "$(cat "${WORK}/trackeroff.err")"
edit 'prog["agreement"]["terms"]["tools_of_record"]["value"] = ["tracker", "tasks", "plans"]'

reset_state
it "a record from the old code with the tracker off under its sources term is never polled"
edit 't = prog["agreement"]["terms"]; old = t.pop("tools_of_record"); t["sources"] = dict(old, key="sources", value=["tasks", "plans"])'
echo 1 > "$BOARD_EXIT_FILE"
start_watch trackeroffold --tracker --max-polls 3
wait_exit "$WPID"
check 0 "$(lines "${WORK}/trackeroffold.out")"
has "turns the tracker off" "$(cat "${WORK}/trackeroffold.err")"
edit 't = prog["agreement"]["terms"]; t.pop("sources", None); t["tools_of_record"] = dict(t.get("tools_of_record") or {}, key="tools_of_record", value=["tracker", "tasks", "plans"])'

reset_state
TASKS="${CLAUDE_AUTO_TASKS_DIR}/sess-w7"
mkdir -p "$TASKS"
printf '{"id":"1","subject":"Write tests","activeForm":"Writing tests","status":"pending"}' > "${TASKS}/1.json"
prog add-item linear:AI-820 --title "Tasks" --session sess-w7
it "a task status change for a remit session prints nothing"
start_watch tasks --max-polls 6
wait_for "$BEATS" "watcher-beat remit" || true
sleep 0.4
printf '{"id":"1","subject":"Write tests","activeForm":"Writing tests","status":"in_progress"}' > "${TASKS}/1.json"
wait_exit "$WPID"
check 0 "$(lines "${WORK}/tasks.out")"
it "the tasks source going down still prints source-unavailable tasks"
mv "$CLAUDE_AUTO_TASKS_DIR" "${CLAUDE_AUTO_TASKS_DIR}.away"
: > "$CLAUDE_AUTO_TASKS_DIR"
start_watch tasksdown --max-polls 3
wait_exit "$WPID"
check "source-unavailable tasks" "$(cut -d' ' -f1,2 "${WORK}/tasksdown.out")"
rm -f "$CLAUDE_AUTO_TASKS_DIR"
mv "${CLAUDE_AUTO_TASKS_DIR}.away" "$CLAUDE_AUTO_TASKS_DIR"

reset_state
it "a task change is ignored while the agreement turns tasks off"
edit 'prog["agreement"]["terms"]["tools_of_record"]["value"] = ["tracker", "plans"]'
start_watch tasksoff --max-polls 4
wait_for "$BEATS" "watcher-beat remit" || true
sleep 0.4
printf '{"id":"1","subject":"Write tests","activeForm":"Writing tests","status":"completed"}' > "${TASKS}/1.json"
wait_exit "$WPID"
check 0 "$(lines "${WORK}/tasksoff.out")"
edit 'prog["agreement"]["terms"]["tools_of_record"]["value"] = ["tracker", "tasks", "plans"]'
prog drop-item linear:AI-820 --reason "test done"

REPO="${WORK}/planrepo"
mkdir -p "${REPO}/docs/plans"
( cd "$REPO" && git init -q ) || echo "git setup failed"
printf '# Old plan\n' > "${REPO}/docs/plans/old.md"
reset_state
export SNAP_CWD="$REPO"
snap 41 5 1
it "a new plan file in a remit repo wakes the watcher naming plans"
start_watch plans --max-polls 20
wait_for "$BEATS" "watcher-beat remit" || true
sleep 0.4
printf '# New plan for AI-830\n' > "${REPO}/docs/plans/new.md"
wait_for "${WORK}/plans.out" "plans-changed" || true
check "plans-changed +planrepo/docs/plans/new.md" "$(cat "${WORK}/plans.out")"
it "editing that plan afterwards prints nothing over several polls"
touch -m -t 203001010000 "${REPO}/docs/plans/new.md"
sleep 1.5
check 1 "$(lines "${WORK}/plans.out")"
it "the watcher keeps polling after a plan change"
check yes "$(alive "$WPID")"
stop_watch "$WPID"

reset_state
it "a new plan is ignored while the agreement turns plans off"
edit 'prog["agreement"]["terms"]["tools_of_record"]["value"] = ["tracker", "tasks"]'
start_watch plansoff --max-polls 4
wait_for "$BEATS" "watcher-beat remit" || true
sleep 0.4
printf '# Another\n' > "${REPO}/docs/plans/another.md"
wait_exit "$WPID"
check 0 "$(lines "${WORK}/plansoff.out")"
edit 'prog["agreement"]["terms"]["tools_of_record"]["value"] = ["tracker", "tasks", "plans"]'
unset SNAP_CWD

HELD="remit-changed +w2:p3"
held_change() {
  wait_for "$BEATS" "watcher-beat remit" || true
  sleep 0.4
  snap 41 5 1 "w2:p1,w2:p2,w2:p3"
  sleep 0.7
}

reset_state
it "a non-urgent change is held inside the collapse window"
CLAUDE_AUTO_WATCH_COLLAPSE_SECONDS=1.5 start_watch burst
held_change
check 0 "$(lines "${WORK}/burst.out")"
it "two non-urgent changes in successive polls print as one line holding both"
snap 41 5 1 "w2:p1,w2:p2,w2:p3,w2:p4"
wait_for "${WORK}/burst.out" "remit-changed" 30 || true
check "${HELD}; remit-changed +w2:p4" "$(cat "${WORK}/burst.out")"
stop_watch "$WPID"

reset_state
it "a claim alone prints in the poll that finds it, without waiting for the window"
CLAUDE_AUTO_WATCH_COLLAPSE_SECONDS=30 start_watch claimfast
wait_for "$BEATS" "watcher-beat remit" || true
sleep 0.4
add_claim
wait_for "${WORK}/claimfast.out" "claim" 15 || true
check "claim 1 new" "$(cat "${WORK}/claimfast.out")"
stop_watch "$WPID"

reset_state
it "a held change and a later claim print at once as one line, held change first"
CLAUDE_AUTO_WATCH_COLLAPSE_SECONDS=30 start_watch claimheld
held_change
add_claim
wait_for "${WORK}/claimheld.out" "claim" 15 || true
check "${HELD}; claim 1 new" "$(cat "${WORK}/claimheld.out")"
stop_watch "$WPID"

reset_state
it "a held change then a source outage print as one line, held change first"
CLAUDE_AUTO_WATCH_COLLAPSE_SECONDS=30 start_watch heldown
held_change
echo 1 > "$HERDR_EXIT_FILE"
wait_for "${WORK}/heldown.out" "source-unavailable" 15 || true
check "${HELD}; source-unavailable herdr exit=1" "$(cat "${WORK}/heldown.out")"
stop_watch "$WPID"

reset_state
it "a held change prints before the watcher exits at --max-polls"
CLAUDE_AUTO_WATCH_COLLAPSE_SECONDS=30 start_watch heldmax --max-polls 4
held_change
wait_exit "$WPID"
check "$HELD" "$(cat "${WORK}/heldmax.out")"

reset_state
it "a held change prints, then remit-watcher-exit ended, when the programme ends"
CLAUDE_AUTO_WATCH_COLLAPSE_SECONDS=30 start_watch heldend
held_change
edit 'prog["ended"] = True'
wait_exit "$WPID"
check "${HELD}|remit-watcher-exit ended" "$(paste -sd'|' "${WORK}/heldend.out")"
edit 'prog.pop("ended", None)'

reset_state
it "a held change prints when the watcher's Monitor stops it with SIGTERM"
CLAUDE_AUTO_WATCH_COLLAPSE_SECONDS=30 start_watch heldterm
held_change
check 0 "$(lines "${WORK}/heldterm.out")"
kill -TERM "$WPID"
wait_exit "$WPID" 30
check "$HELD" "$(cat "${WORK}/heldterm.out")"

reset_state
prog set-waiting linear:AI-800 --who ci
it "item mode runs the command and prints one line with its exit status"
CLAUDE_AUTO_WATCH_INTERVAL_SECONDS=1 start_watch item --item linear:AI-800 -- sh -c 'sleep 3.5; exit 3'
wait_exit "$WPID" 100
check 0 "$?"
check "item-exited linear:AI-800 exit=3" "$(cat "${WORK}/item.out")"
it "item mode beats once to register and once per interval: 3 interval beats"
check 4 "$(count "$BEATS" "--item linear:AI-800")"
it "item mode beats a watcher id derived from the item"
check "\"linear:AI-800\"" "$(field 'prog["watchers"]["item-linear-AI-800"]["item"]')"
it "item mode never touches the remit watcher"
check 0 "$(count "$BEATS" "watcher-beat remit")"

reset_state
prog set-waiting linear:AI-800 --who ci
it "item mode whose command is killed reports the signal"
CHILD="${WORK}/child.pid"
start_watch killed --item linear:AI-800 -- sh -c "echo \$\$ > '${CHILD}'; exec sleep 30"
wait_for "$CHILD" "[0-9]" || true
wait_for "$BEATS" "--item linear:AI-800" || true
kill "$(cat "$CHILD")"
wait_exit "$WPID"
check "item-exited linear:AI-800 signal=15" "$(cat "${WORK}/killed.out")"
it "the beats stop once the command is killed"
BEFORE="$(count "$BEATS" "--item linear:AI-800")"
sleep 1
check "$BEFORE" "$(count "$BEATS" "--item linear:AI-800")"
predicate_at() {
  run_py "$RUN" "$1" <<'EOF'
import datetime
pp = load_lib_module("programme_predicate")
rec = record(args[0])
beat = core.parse_iso(rec["programme"]["watchers"]["item-linear-AI-800"]["last_beat_at"])
cadence = ph.cadence_seconds(rec)
now = beat + datetime.timedelta(seconds=cadence + int(args[1]))
print(json.dumps(pp.compute(rec, now=now, inbox_size=0).get("unwatched_waits")))
EOF
}
it "before the cadence passes the killed command's wait still counts as watched"
check "[]" "$(predicate_at -2)"
it "after the cadence passes the predicate reports an unwatched wait"
check '["linear:AI-800"]' "$(predicate_at 1)"

reset_state
it "item mode without a command is a usage error"
bash "$WATCH" --run "$RUN" --item linear:AI-800 > "${WORK}/usage.out" 2> "${WORK}/usage.err"
check 2 "$?"
it "the usage error leaves stdout empty"
check 0 "$(lines "${WORK}/usage.out")"

it "an unknown run is refused with no stdout"
bash "$WATCH" --run no-such-run --max-polls 1 > "${WORK}/norun.out" 2> "${WORK}/norun.err"
check 1 "$?"
check 0 "$(lines "${WORK}/norun.out")"

it "watcher-beat --prompt stores the armed cron prompt on the watcher"
prog watcher-beat cron --task-id cron-7 --prompt "wake up and   sweep the space"
check '"wake up and   sweep the space"' "$(field 'prog["watchers"]["cron"]["prompt"]')"
it "watcher-beat --prompt keeps the cron task id"
check '"cron-7"' "$(field 'prog["watchers"]["cron"]["task_id"]')"
it "watcher-beat refuses an empty --prompt"
"$PY" "$PROG" watcher-beat cron --prompt "   " --run "$RUN" > /dev/null 2>&1
check 2 "$?"
it "watcher-beat refuses an overlong --prompt"
"$PY" "$PROG" watcher-beat cron --prompt "$(printf 'a%.0s' $(seq 1 4001))" --run "$RUN" > /dev/null 2>&1
check 2 "$?"
it "a prompt equal to the stored cron prompt after collapsing whitespace has origin cron"
check "cron unknown" "$(run_py "$RUN" <<'EOF'
oup = load_lib_module("on-user-prompt")
rec = record(args[0])
print(oup.classify_origin("wake up and sweep the space", rec), oup.classify_origin("wake up and sweep", rec))
EOF
)"

reset_state
it "a running watcher prints remit-watcher-exit ended and exits 0 when the programme ends"
start_watch endlive
wait_for "$BEATS" "watcher-beat remit" || true
edit 'prog["ended"] = True'
wait_exit "$WPID"
check 0 "$?"
check "remit-watcher-exit ended" "$(cat "${WORK}/endlive.out")"

it "a watcher started after the programme ended prints remit-watcher-exit ended"
start_watch ended
wait_exit "$WPID"
check 0 "$?"
check "remit-watcher-exit ended" "$(cat "${WORK}/ended.out")"
has "ended" "$(cat "${WORK}/ended.err")"

it "a remit watcher that crashes prints a crash line before it exits, so the sweep can tell it from expiry"
CRASH="$("$PY" - "$AUTO_ROOT" <<'PYEOF' 2>/dev/null
import importlib.util, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
spec = importlib.util.spec_from_file_location("pw", os.path.join(sys.argv[1], "lib", "programme-watch.py"))
pw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pw)
class Boom:
    def __init__(self, *args):
        pass
    def poll(self, record):
        raise RuntimeError("source read blew up")
pw._read = lambda run_id: {}
pw._ended = pw._superseded = lambda record: False
pw._beat = lambda *args: True
pw._programme = lambda record: {}
pw.RemitSignals = Boom
code = pw._remit_mode("prog-x", {"tracker": False, "max_polls": 1})
print(f"code={code}")
PYEOF
)"
case "$CRASH" in *"remit-watcher-exit crashed"*"code=1"*) pass ;; *) fail "got: $CRASH" ;; esac

echo ""
echo "programme-watch.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
