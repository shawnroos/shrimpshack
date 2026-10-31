#!/usr/bin/env bash
# auto unit test: the Rex terminal host (R10, R12, R15, R18, AE4, AE6, KTD3, KTD10).
#
# The rex fake replays output captured from the real Rex Beta CLI (tests/fixtures/hosts/rex).
# A fixture directory holding a `handwritten` file is NOT captured: it changes one field of a real
# capture, or stands in for a shape that could not be captured without typing into a live block.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
PROG="${AUTO_ROOT}/lib/programme.py"
WATCH="${AUTO_ROOT}/lib/programme-watch.sh"
HOOKS="${AUTO_ROOT}/.claude/hooks"
FIXTURES="${AUTO_ROOT}/tests/fixtures/hosts/rex"
. "${AUTO_ROOT}/tests/helpers/host-fakes.sh"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
check() { if [ "$1" = "$2" ]; then pass; else fail "expected [$1] got [$2]"; fi; }
has() { case "$2" in *"$1"*) pass ;; *) fail "expected to find [$1] in [$2]" ;; esac; }
lacks() { case "$2" in *"$1"*) fail "did not expect [$1] in [$2]" ;; *) pass ;; esac; }

echo "host-rex.test.sh"

WORK="$(mktemp -d -t auto-host-rex.XXXXXX)"
BG_PIDS=""
cleanup() { for p in $BG_PIDS; do kill "$p" 2>/dev/null; done; rm -rf "$WORK"; }
trap cleanup EXIT

for v in $(env | grep -oE '^(HERDR|REX|GHOSTTY|AUTO_TEST|HOST_FAKE)_[A-Z_]*'); do unset "$v"; done
unset CMUX_WORKSPACE_ID TERM_PROGRAM CLAUDE_CODE_SESSION_ID CLAUDE_CODE_ENTRYPOINT CLAUDE_AUTO_REPO 2>/dev/null || true
export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_TEST_HARNESS=1
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_AUTO_SOURCE_TIMEOUT=3
: > "$CLAUDE_AUTO_SECRETS_FILE"
NOREPO="${WORK}/norepo"
mkdir -p "$NOREPO"

SID=session:01a18693-5b41-787b-af33-87750812e31e
WS=01a18693-5b41-787b-af33-87750812e31e
BID=block:01a18693-5b44-7cdc-a847-3bcbb92a53ab
NOB=block:01a18693-5b44-7cdc-a847-3bcbb92a53ac
HOSTID=36cd92c4-5843-4f54-8139-52a41012758e

export AUTO_ROOT
CALLS="${WORK}/calls.log"
export CALLS
FAKEBIN="${WORK}/fakebin"
host_fake_install rex "$FAKEBIN"
BASE_PATH="$PATH"
# A PATH with no rex on it, whatever this machine has installed.
NOREX_PATH=""
IFS=: read -r -a _dirs <<< "$BASE_PATH"
for d in "${_dirs[@]}"; do [ -x "$d/rex" ] || NOREX_PATH="${NOREX_PATH:+$NOREX_PATH:}$d"; done
WITHREX_PATH="${FAKEBIN}:${NOREX_PATH}"

HEAD_PY='import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
th = load_lib_module("terminal_host")
ph = load_lib_module("programme_home")
pj = load_lib_module("programme_journal")
sr = load_lib_module("session_registry")
rc = load_lib_module("run_record_core")
rex = th.host_named("rex")
args = sys.argv[2:]
def show(res, *keys):
    print(res.status, *[json.dumps(res.value.get(k) if isinstance(res.value, dict) else None) for k in keys])
'
# py: Python with the rex host module loaded, PATH holding the rex fake. Extra VAR=value words set the environment.
py() { env PATH="$WITHREX_PATH" "$@" "$PY" - "$AUTO_ROOT" 2>&1; }
pyargs() { local first="$1"; shift; env PATH="$WITHREX_PATH" "$PY" - "$AUTO_ROOT" "$@" 2>&1; }

echo "host-rex: own pane is selected by the variables and proved by rex session inspect (KTD3)"
it "REX_SESSION and REX_BLOCK that rex session inspect lists give the block, the space and the session label"
OUT="$(env PATH="$WITHREX_PATH" REX_SESSION=$SID REX_BLOCK=$BID "$PY" - "$AUTO_ROOT" <<PYEOF
$HEAD_PY
r = rex.own_pane(os.environ)
v = r.value
print(r.status, v["pane_id"], v["server"], v["workspace"], v["tab_space_name"], v["terminal_id"])
PYEOF
)"
check "native $BID $HOSTID $WS cosmic-delta None" "$OUT"

it "a real session id with a block id that session does not list refuses"
OUT="$(env PATH="$WITHREX_PATH" REX_SESSION=$SID REX_BLOCK=$NOB "$PY" - "$AUTO_ROOT" <<PYEOF
$HEAD_PY
r = rex.own_pane(os.environ); print(r.status, r.why)
PYEOF
)"
has "refuse" "$OUT"
has "has no block $NOB" "$OUT"

it "a faked session that rex session inspect rejects refuses even with a plausible block (never env only)"
OUT="$(env PATH="$WITHREX_PATH" REX_SESSION=session:00000000-0000-0000-0000-000000000000 REX_BLOCK=$BID "$PY" - "$AUTO_ROOT" <<PYEOF
$HEAD_PY
r = rex.own_pane(os.environ); print(r.status, r.value, r.why)
PYEOF
)"
has "refuse None" "$OUT"
has "session target" "$OUT"

it "no REX_BLOCK refuses: the focused block is not the session's own"
OUT="$(env PATH="$WITHREX_PATH" REX_SESSION=$SID "$PY" - "$AUTO_ROOT" <<PYEOF
$HEAD_PY
print(rex.own_pane(os.environ).status)
PYEOF
)"
check "refuse" "$OUT"

it "a value that starts with a dash is never handed to rex as a flag"
: > "$CALLS"
OUT="$(env PATH="$WITHREX_PATH" REX_SESSION=--json REX_BLOCK=$BID "$PY" - "$AUTO_ROOT" <<PYEOF
$HEAD_PY
print(rex.own_pane(os.environ).status)
PYEOF
)"
check "refuse" "$OUT"
check "" "$(cat "$CALLS")"

echo "host-rex: AE4, rex missing from PATH refuses with the install step"
OUT="$(env PATH="$NOREX_PATH" REX_SESSION=$SID REX_BLOCK=$BID "$PY" - "$AUTO_ROOT" <<PYEOF
$HEAD_PY
for name, call in (("own_pane", lambda: rex.own_pane(os.environ)), ("list_panes", lambda: rex.list_panes()),
                   ("start_pane", lambda: rex.start_pane(["spinoff"], 1)),
                   ("send_prompt", lambda: rex.send_prompt("$BID", "go")),
                   ("change_token", lambda: rex.change_token(lambda argv: (None, "missing")))):
    r = call()
    print(name, r.status, "install" in (r.fix or "") and "PATH" in (r.fix or "") and "rex skill setup" in (r.fix or ""))
r = rex.presence("s", {"pane_id": "$BID", "host": "rex", "interactive": True, "workspace": "$WS"}, None, None)
print("presence", r.status, r.value["state"])
PYEOF
)"
for m in own_pane list_panes start_pane send_prompt change_token; do
  it "$m refuses and the fix line names the install step"
  has "$m refuse True" "$OUT"
done
it "presence answers unknown, not gone, when rex is missing"
has "presence native unknown" "$OUT"

as_rex() {
  local sid="$1" path="$2"; shift 2
  OUT="$(cd "$NOREPO" && env PATH="$path" CLAUDE_CODE_SESSION_ID="$sid" REX_SESSION=$SID REX_BLOCK=$BID "$PY" "$PROG" "$@" 2>&1)"
  CODE=$?
}
LEASES="${CLAUDE_AUTO_DATA_DIR}/programme/leases"
lease_count() { ls "${CLAUDE_AUTO_DATA_DIR}/programmes/leases" 2>/dev/null | grep -vc '^\.'; }
BEFORE="$(lease_count)"
it "AE4: programme start from a Rex session with no rex on PATH refuses and names the install step"
as_rex sess-rex-lone "$NOREX_PATH" start
check "1" "$CODE"
has "rex command is not on PATH" "$OUT"
has "install Rex and put its rex command on PATH" "$OUT"
it "the refused start wrote no lease"
check "$BEFORE" "$(lease_count)"
it "AE4: become-pm refuses the same way"
as_rex sess-rex-lone "$NOREX_PATH" become-pm
has '"step": "refused"' "$OUT"
has "install Rex and put its rex command on PATH" "$OUT"
it "with rex present but REX_BLOCK rejected by rex session inspect, start refuses too"
OUT="$(cd "$NOREPO" && env PATH="$WITHREX_PATH" CLAUDE_CODE_SESSION_ID=sess-rex-fake REX_SESSION=$SID REX_BLOCK=$NOB "$PY" "$PROG" start 2>&1)"
check "1" "$?"
has "cannot identify this session's rex terminal pane" "$OUT"

echo "host-rex: list_panes, locate and the empty server"
it "one session: the snapshot lists the block under the session's workspace id"
OUT="$(env PATH="$WITHREX_PATH" HOST_FAKE_OVERLAY="session-ls-json-one" "$PY" - "$AUTO_ROOT" <<PYEOF
$HEAD_PY
r = rex.list_panes(); p = r.value["panes"]
print(r.status, [(x["pane_id"], x["workspace_id"], x["label"]) for x in p])
PYEOF
)"
check "native [('$BID', '$WS', 'shell')]" "$OUT"
it "0-session server: locate finds nothing"
OUT="$(env PATH="$WITHREX_PATH" HOST_FAKE_OVERLAY="session-ls-json-empty" "$PY" - "$AUTO_ROOT" <<PYEOF
$HEAD_PY
r = rex.list_panes(); print(r.status, r.value["panes"], any(p["pane_id"] == "$BID" for p in r.value["panes"]))
PYEOF
)"
check "native [] False" "$OUT"
it "rex cannot be read: list_panes refuses with the reason, not an empty list"
OUT="$(env PATH="$WITHREX_PATH" HOST_FAKE_FORCE=session-inspect-missing "$PY" - "$AUTO_ROOT" <<PYEOF
$HEAD_PY
r = rex.list_panes(); print(r.status, r.value)
PYEOF
)"
has "refuse None" "$OUT"
it "agent rows are degraded: Rex does not say which session a block runs"
OUT="$(env PATH="$WITHREX_PATH" "$PY" - "$AUTO_ROOT" <<PYEOF
$HEAD_PY
r = rex.list_panes(agents=True); print(r.status, r.value)
PYEOF
)"
check "degraded []" "$OUT"

echo "host-rex: start_pane wraps spinoff with the host named and parses the block"
SPINOFF="${WORK}/spinoff"
cat > "$SPINOFF" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$SPINOFF_ARGS"
echo "  agent pane: rex block:01a18693-5b44-7cdc-a847-3bcbb92a53ab"
EOF
chmod +x "$SPINOFF"
export SPINOFF_ARGS="${WORK}/spinoff-args"
OUT="$(env PATH="$WITHREX_PATH" "$PY" - "$AUTO_ROOT" "$SPINOFF" <<PYEOF
$HEAD_PY
r = rex.start_pane([args[0], "--topic", "x", "--session-id", "w1"], 10)
print(r.status, r.value["pane"], r.value["run"]["code"])
PYEOF
)"
it "start_pane returns the block spinoff reported"
check "native $BID 0" "$OUT"
it "spinoff was told to use the rex launcher"
has "--launcher rex" "$(cat "$SPINOFF_ARGS")"
it "a spinoff that reported a herdr pane does not give a Rex block"
printf '#!/bin/bash\necho "herdr agent pane: w1:p2"\n' > "${WORK}/spin-herdr"; chmod +x "${WORK}/spin-herdr"
OUT="$(env PATH="$WITHREX_PATH" "$PY" - "$AUTO_ROOT" "${WORK}/spin-herdr" <<PYEOF
$HEAD_PY
print(rex.start_pane([args[0]], 10).value["pane"])
PYEOF
)"
check "None" "$OUT"

echo "host-rex: confirm_started polls the registry (degraded)"
rowfor() {
  env PATH="$WITHREX_PATH" "$PY" - "$AUTO_ROOT" "$@" <<PYEOF
$HEAD_PY
sid, pane, ws, host = args
entry = {"at": rc.now_iso(), "session_id": sid, "pane_id": pane, "terminal_id": None, "server": "$HOSTID",
         "workspace": ws, "interactive": True, "resolved": host, "host": host}
sr._append(sr.registry_path("$HOSTID", ws, host), entry)
PYEOF
}
rowfor worker-1 "$BID" "$WS" rex
OUT="$(env PATH="$WITHREX_PATH" "$PY" - "$AUTO_ROOT" "$BID" <<PYEOF
$HEAD_PY
r = rex.confirm_started("worker-1", args[0], set(), 2, None)
print(r.status, r.value["row"]["pane_id"])
r = rex.confirm_started("worker-1", "block:other", set(), 2, None)
print(r.status, r.value["row"])
r = rex.confirm_started("worker-never", None, set(), 0.2, None)
print(r.status, r.value["row"], r.why)
PYEOF
)"
it "a worker whose SessionStart row is in the registry is confirmed, as degraded"
has "degraded $BID" "$OUT"
it "a row in a different block than spinoff reported refuses"
has "refuse None" "$OUT"
it "no row within the wait refuses with the session named"
has "no SessionStart row for session worker-never" "$OUT"

echo "host-rex: send_prompt types the text, then Enter"
: > "$CALLS"
OUT="$(env PATH="$WITHREX_PATH" "$PY" - "$AUTO_ROOT" <<PYEOF
$HEAD_PY
r = rex.send_prompt("$BID", "-go now")
print(r.status, r.value["code"])
r = rex.send_prompt("$NOB", "go")
print(r.status, r.why)
PYEOF
)"
it "the first block takes the prompt"
has "native 0" "$OUT"
it "the text follows a double dash so a leading dash is not a flag"
has "send -b $BID --autostart=false -- -go now" "$(cat "$CALLS")"
it "Enter is sent as a key after the text"
has "send-key -b $BID enter" "$(cat "$CALLS")"
it "a block rex does not know refuses with rex's own reason"
has "refuse rex send exited 3" "$OUT"

echo "host-rex: presence is present, gone or unknown, and unknown whenever the answer is ambiguous"
presence() { # presence <row-workspace> <row-pane> <overlay> [rex-on-path]
  env PATH="${4:-$WITHREX_PATH}" HOST_FAKE_OVERLAY="$3" "$PY" - "$AUTO_ROOT" "$1" "$2" <<PYEOF
$HEAD_PY
ws, pane = args
row = {"pane_id": pane, "host": "rex", "interactive": True, "workspace": ws, "server": "$HOSTID"}
r = rex.presence("pm", row, None, None)
print(r.value["state"], "|", r.value["why"])
PYEOF
}
it "a claude process in the recorded block: present"
has "present |" "$(presence "$WS" "$BID" "session-ls-json-one api-process-claude")"
it "a block that runs no claude process: unknown, not gone"
check "unknown" "$(presence "$WS" "$BID" "session-ls-json-one" | cut -d' ' -f1)"
it "the recorded block closed while the session lives: gone"
has "gone | block $NOB that ran the driving session is closed" "$(presence "$WS" "$NOB" "session-ls-json-one")"
it "the program in the block exited: gone"
has "gone | the program in block $BID has exited" "$(presence "$WS" "$BID" "session-ls-json-one api-process-exited")"
it "the recorded session is no longer listed: gone"
has "gone | Rex session session:99999999-0000-0000-0000-000000000000 that ran" "$(presence 99999999-0000-0000-0000-000000000000 "$BID" "session-ls-json-one")"
it "a server with no sessions: unknown, not gone"
check "unknown" "$(presence "$WS" "$BID" "session-ls-json-empty" | cut -d' ' -f1)"
it "rex errors on the session read: unknown"
check "unknown" "$(presence 00000000-0000-0000-0000-000000000000 "$BID" "session-ls-json-ghost" | cut -d' ' -f1)"
it "no registry row: unknown"
OUT="$(env PATH="$WITHREX_PATH" "$PY" - "$AUTO_ROOT" <<PYEOF
$HEAD_PY
print(rex.presence("pm", None, None, None).value["state"])
PYEOF
)"
check "unknown" "$OUT"

row() { env PATH="$WITHREX_PATH" AUTO_TEST_HOST= "$PY" - "$AUTO_ROOT" "$@" <<PYEOF
$HEAD_PY
sid, pane = args
entry = {"at": rc.now_iso(), "session_id": sid, "pane_id": pane, "terminal_id": None, "server": "$HOSTID",
         "workspace": "$WS", "interactive": True, "resolved": "rex", "host": "rex"}
sr._append(sr.registry_path("$HOSTID", "$WS", "rex"), entry)
PYEOF
}
row pm-rex "$BID"
row sess-worker "$NOB"
RUN_PM="$(env PATH="$WITHREX_PATH" "$PY" - "$AUTO_ROOT" "$HOSTID" "$WS" <<PYEOF
$HEAD_PY
print(ph.create_programme([(args[0], args[1], "rex")], "pm-rex")["run"])
PYEOF
)"

echo "host-rex: change_token is the session revision, and the remit watcher wakes only when it moves"
it "every block carries its session's revision from session.view"
OUT="$(env PATH="$WITHREX_PATH" HOST_FAKE_OVERLAY="session-ls-json-one" "$PY" - "$AUTO_ROOT" <<PYEOF
$HEAD_PY
import subprocess
def read_json(argv):
    done = subprocess.run(argv, capture_output=True, text=True)
    return (json.loads(done.stdout), None) if done.returncode == 0 else (None, "exit=%d" % done.returncode)
r = rex.change_token(read_json)
print(r.status, [(a["pane_id"], a["state_change_seq"]) for a in r.value["agents"]])
PYEOF
)"
check "native [('$BID', 53)]" "$OUT"

DYN="${WORK}/dyn"
mkdir -p "$DYN"
REVFILE="${WORK}/revision"
cat > "${DYN}/rex" <<EOF
#!/bin/bash
case "\$*" in
  "session ls --json"*) cat "${FIXTURES}/session-ls-json-one/stdout" ;;
  "api call -s "*" session.view"*) sed "s/\"revision\":[0-9]*/\"revision\":\$(cat "${REVFILE}")/" "${FIXTURES}/api-session-view/stdout" ;;
  *) echo "dyn rex: unexpected \$*" >&2; exit 99 ;;
esac
EOF
chmod +x "${DYN}/rex"
BEATS="${WORK}/beats.log"
cat > "${DYN}/programme-cli" <<EOF
#!/bin/sh
"${PY}" "${PROG}" "\$@"
rc=\$?
printf '%s\n' "\$*" >> "${BEATS}"
exit \$rc
EOF
chmod +x "${DYN}/programme-cli"
export CLAUDE_AUTO_PROGRAMME_CLI="${DYN}/programme-cli"
export CLAUDE_AUTO_WATCH_INTERVAL_SECONDS="0.3"
export CLAUDE_AUTO_MACHINE="studio"

echo 53 > "$REVFILE"
: > "$BEATS"
wait_for() { local file="$1" pattern="$2" limit="${3:-100}" n=0
  while ! grep -q -- "$pattern" "$file" 2>/dev/null; do sleep 0.1; n=$((n + 1)); [ "$n" -ge "$limit" ] && return 1; done; return 0; }
env PATH="${DYN}:${NOREX_PATH}" CLAUDE_CODE_SESSION_ID=pm-rex REX_SESSION=$SID bash "$WATCH" --run "$RUN_PM" > "${WORK}/watch.out" 2> "${WORK}/watch.err" &
WPID=$!
BG_PIDS="$BG_PIDS $WPID"
wait_for "$BEATS" "watcher-beat remit" || true
sleep 1.2
it "revision unchanged across several polls: the watcher prints nothing"
check "" "$(cat "${WORK}/watch.out")"
echo 54 > "$REVFILE"
sleep 1.2
it "revision 53 to 54 alone does not wake the PM: the watcher wakes on a block joining or leaving, not on busy or idle changes"
check "" "$(cat "${WORK}/watch.out")"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

echo "host-rex: the event stream wakes the remit watcher, and a dropped stream falls back to polling (R4, R5)"
EVFAKE="${WORK}/evfake"
mkdir -p "$EVFAKE"
EVFILE="${WORK}/events.in"
: > "$EVFILE"
# A rex whose `events` command stays open and prints every line appended to $EVFILE, like the real stream.
cat > "${EVFAKE}/rex" <<EOF
#!/bin/bash
case "\$1" in
  events) tail -n +1 -f "$EVFILE" ;;
  *) exec "${FAKEBIN}/rex" "\$@" ;;
esac
EOF
chmod +x "${EVFAKE}/rex"
EVPATH="${EVFAKE}:${NOREX_PATH}"
BLOCK_LINE='{"type":"session_event","payload":{"session_id":"'$SID'","event":{"type":"block_created","payload":{"block_id":"block:x"}}}}'
CLOSE_LINE='{"type":"session_event","payload":{"session_id":"'$SID'","event":{"type":"block_closed","payload":{"block_id":"block:x"}}}}'
NOISE_LINE='{"type":"session_event","payload":{"session_id":"'$SID'","event":{"type":"client_connected","payload":{"client_id":"client:x"}}}}'
REV_LINE='{"type":"session_event","payload":{"session_id":"'$SID'","event":{"type":"session_view_changed","payload":{"revision":9}}}}'
SESSION_LINE='{"type":"session_destroyed","payload":{"session_id":"'$SID'"}}'
wake_py() { # wake_py <path> <python body>: runs the body with `w` a started wake source
  env PATH="$1" "$PY" - "$AUTO_ROOT" <<PYEOF
$HEAD_PY
import time
w = rex.wake_source()
started = w is not None and w.start()
$2
if w is not None:
    w.close()
PYEOF
}
it "a fresh wake source is due once, then quiet until an event arrives"
OUT="$(wake_py "$EVPATH" '
first = w.due(); w.begin_read(); time.sleep(0.3)
print(started, first, w.due())')"
check "True True False" "$OUT"

it "a block joining, a block leaving and a session ending each make it due"
OUT="$(for line in "$BLOCK_LINE" "$CLOSE_LINE" "$SESSION_LINE"; do : > "$EVFILE"
  wake_py "$EVPATH" "
w.due(); w.begin_read(); time.sleep(0.3)
open('$EVFILE', 'a').write('''$line''' + chr(10)); time.sleep(0.6)
print(w.due())"; done | tr '\n' ' ')"
check "True True True " "$OUT"

it "a client connecting and a revision change alone never make it due (the watcher's own reads cause the first)"
: > "$EVFILE"
OUT="$(wake_py "$EVPATH" "
w.due(); w.begin_read(); time.sleep(0.3)
f = open('$EVFILE', 'a'); f.write('''$NOISE_LINE''' + chr(10)); f.write('''$REV_LINE''' + chr(10)); f.flush(); time.sleep(0.6)
print(w.due())")"
check "False" "$OUT"

it "an event that arrives while a read is under way is not lost"
: > "$EVFILE"
OUT="$(wake_py "$EVPATH" "
w.due(); w.begin_read()
open('$EVFILE', 'a').write('''$BLOCK_LINE''' + chr(10)); time.sleep(0.6)
print(w.due())")"
check "True" "$OUT"

it "the safety net makes it due even when no event came"
OUT="$(wake_py "$EVPATH" "
import sys
sys.modules[type(rex).__module__].SAFETY_NET_SECONDS = 0.2
w = rex.wake_source(); w.start(); w.due(); w.begin_read(); time.sleep(0.5)
print(w.due())")"
check "True" "$OUT"

it "a stream that ends is never healthy again: the watcher reads on every poll as before"
OUT="$(env PATH="$WITHREX_PATH" "$PY" - "$AUTO_ROOT" <<PYEOF
$HEAD_PY
import time
w = rex.wake_source(); w.start(); time.sleep(0.5)
w.begin_read()
print(w.due(), w.due())
w.close()
PYEOF
)"
check "True True" "$OUT"

it "close stops the event reader"
OUT="$(wake_py "$EVPATH" "
p = w._proc; w.close(); time.sleep(0.5)
print(p.poll() is not None)")"
check "True" "$OUT"

it "rex missing from PATH: no wake source, the watcher polls"
OUT="$(env PATH="$NOREX_PATH" "$PY" - "$AUTO_ROOT" <<PYEOF
$HEAD_PY
print(rex.wake_source())
PYEOF
)"
check "None" "$OUT"

echo "host-rex: the remit watcher skips its host read on a quiet poll (R4)"
WCALLS="${WORK}/wake.calls"
run_watch() { # run_watch <path> <polls>: a remit watcher on a 0.3s poll; CALLS records every rex call it makes
  : > "$WCALLS"
  env PATH="$1" CALLS="$WCALLS" HOST_FAKE_OVERLAY="session-ls-json-one" CLAUDE_CODE_SESSION_ID=pm-rex REX_SESSION=$SID \
    bash "$WATCH" --run "$RUN_PM" --max-polls "$2" > "${WORK}/wake.out" 2>/dev/null
}
: > "$EVFILE"
run_watch "$EVPATH" 6
it "a healthy stream and no events: the session view is read once, not on every poll"
check "1" "$(grep -c 'session.view' "$WCALLS")"
it "the same polls with no stream read the view on every poll, as today"
run_watch "$WITHREX_PATH" 6
[ "$(grep -c 'session.view' "$WCALLS")" -ge 6 ] && pass || fail "view reads: $(grep -c 'session.view' "$WCALLS")"

echo "host-rex: notify is degraded to a journal line"
OUT="$("$PY" - "$AUTO_ROOT" <<PYEOF
$HEAD_PY
r = rex.notify("t", "b"); print(r.status, r.value)
PYEOF
)"
it "no Rex notification exists, so the answer is degraded and says where the ask lives"
check "degraded journal" "$OUT"

echo "host-rex: is_host_command treats any rex call naming the block as a send"
cmd_hit() { # cmd_hit <argv words...>: prints the verb and target, or none
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF
$HEAD_PY
hit = rex.is_host_command(args, pane_ids=["$BID", None])
print("none" if hit is None else hit[0] + "|" + hit[1])
PYEOF
}
it "rex send -b <id>"; check "send|$BID" "$(cmd_hit rex send -b "$BID" hi)"
it "--block=<id> in one word"; check "send|$BID" "$(cmd_hit rex send "--block=$BID" hi)"
it "--block <id> in two words"; check "send|$BID" "$(cmd_hit rex send --block "$BID" hi)"
it "-b<id> with the flag glued on"; check "send|$BID" "$(cmd_hit rex send "-b$BID" hi)"
it "the id tail Rex accepts as a target"; check "send|$BID" "$(cmd_hit rex send -b 3bcbb92a53ab hi)"
it "the id tail behind --block="; check "send|$BID" "$(cmd_hit rex send --block=a53ab hi)"
it "send-key"; check "send-key|$BID" "$(cmd_hit rex send-key -b "$BID" enter)"
it "run"; check "run|$BID" "$(cmd_hit rex run -b "$BID" -- ls)"
it "split"; check "split|$BID" "$(cmd_hit rex split -b "$BID" -- ls)"
it "do"; check "do|$BID" "$(cmd_hit rex do -b "$BID" client.key)"
it "api call with the id inside the JSON argument"
check "api call|$BID" "$(cmd_hit rex api call -s "$SID" com.superlogical.terminal.write "{\"block_id\":\"$BID\",\"args\":{\"data\":\"x\"}}")"
it "api call block.method"
check "api call|$BID" "$(cmd_hit rex api call block.method "{\"session_id\":\"$SID\",\"block_id\":\"$BID\",\"method\":\"write\"}")"
it "global options before the verb do not hide it"
check "send|$BID" "$(cmd_hit rex -S other --timeout 2s send -b "$BID" hi)"
it "an absolute path to the binary"
check "send|$BID" "$(cmd_hit "/Applications/Rex Beta.app/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex" send -b "$BID" hi)"
it "the binary named through a variable"
check "send|$BID" "$(cmd_hit '$REX' send -b "$BID" hi)"
it "a verb auto has never heard of that names the block is still a send"
check "frobnicate|$BID" "$(cmd_hit rex frobnicate "--block=$BID")"
it "a send to another block is not a hit"
check "none" "$(cmd_hit rex send -b "$NOB" hi)"
it "reading the block with capture is not a hit"
check "none" "$(cmd_hit rex capture -b "$BID" --trim)"
it "rex session inspect is not a hit"
check "none" "$(cmd_hit rex session inspect "$SID" --json)"
it "text shorter than the minimum tail is not taken for a block"
check "none" "$(cmd_hit rex send -b "$NOB" ab)"
it "another program's command is not a hit"
check "none" "$(cmd_hit herdr send -b "$BID" hi)"

echo "host-rex: AE6, the guard blocks and journals rex send into the PM's block"
hook() {
  local payload
  payload="$("$PY" -c 'import json,sys; print(json.dumps({"session_id": sys.argv[1], "tool_name": "Bash", "tool_input": {"command": sys.argv[2]}}))' "$1" "$2")"
  ( cd "$NOREPO" && env PATH="$WITHREX_PATH" "${@:3}" bash "${HOOKS}/on-pretooluse-action.sh" <<< "$payload" )
}
is_deny() { case "$1" in *'"deny"'*) return 0 ;; esac; return 1; }
verdict() { if is_deny "$1"; then echo deny; else echo allow; fi; }
NL=$'\n'
every_form() {
  local sender="$1" send="$2" want="$3" i out bad=""
  local names=(plain bash-c sh-c eval heredoc here-string dollar-paren backticks nested env-bash-lc)
  local forms=("$send" "bash -c '$send'" "sh -c \"$send\"" "eval '$send'" "bash <<EOF${NL}$send${NL}EOF"
               "bash <<< '$send'" "echo \"\$($send)\"" "echo \`$send\`" "bash -c \"eval '$send'\"" "env X=1 bash -lc '$send'")
  for i in "${!forms[@]}"; do
    out="$(hook "$sender" "${forms[$i]}" "${@:4}")"
    if is_deny "$out"; then [ "$want" = deny ] || bad="$bad ${names[$i]}(denied)"
    else [ "$want" = allow ] || bad="$bad ${names[$i]}(allowed)"; fi
  done
  check "" "$bad"
}
it "AE6: another session's rex send into the PM's block, every wrapper form"
every_form sess-worker "rex send -b $BID go" deny
it "AE6: the --block= form, every wrapper form"
every_form sess-worker "rex send --block=$BID go" deny
it "AE6: send-key into the PM's block, every wrapper form"
every_form sess-worker "rex send-key -b $BID enter" deny
it "AE6: split and run beside the PM's block, every wrapper form"
every_form sess-worker "rex split -b $BID -- ls" deny
every_form sess-worker "rex run -b $BID -- ls" deny
it "AE6: the PM typing into its own block, every wrapper form"
every_form pm-rex "rex send -b $BID go" deny
it "quoted and glued flag forms are denied"
OUTS="$(for c in "rex send -b '$BID' go" "rex send \"--block=$BID\" go" "rex send --block \"$BID\" go" "rex send -b$BID go" \
                  "rex send -b 3bcbb92a53ab go" "rex api call block.method '{\"block_id\":\"$BID\",\"method\":\"write\"}'" \
                  "rex api call -s $SID com.superlogical.terminal.write '{\"block_id\":\"$BID\",\"args\":{\"data\":\"x\"}}'"; do
  verdict "$(hook sess-worker "$c")"; done | sort | uniq -c)"
check "7 deny" "$(echo $OUTS)"
it "the attempt is journaled with the rex verb and the PM's block"
ROW="$(env PATH="$WITHREX_PATH" "$PY" - "$AUTO_ROOT" "$RUN_PM" <<PYEOF
$HEAD_PY
r = [x for x in pj.read(args[0]) if x["kind"] == "blocked_driver_send"][0]
print(r["kind"], r["session_id"], r["payload"]["verb"], r["payload"]["target"])
PYEOF
)"
check "blocked_driver_send sess-worker send $BID" "$ROW"
it "a send to another block stays allowed, every wrapper form"
every_form sess-worker "rex send -b $NOB go" allow
it "the PM reading its own block with capture stays allowed"
check "allow" "$(verdict "$(hook pm-rex "rex capture -b $BID --trim")")"
it "KTD3: REX variables that claim the worker is in the PM's block do not weaken the guard"
FAKES=(REX_SESSION=$SID REX_BLOCK=$BID REX_BLOCK_ID=$BID TERM_PROGRAM=ghostty HERDR_PANE_ID=w9:p9)
every_form sess-worker "rex send -b $BID go" deny "${FAKES[@]}"
it "KTD3: REX variables naming the PM's block do not make a send to another block look like the PM's"
every_form sess-worker "rex send -b $NOB go" allow "${FAKES[@]}"

echo "host-rex: R10, a worker's message that its item is done leaves the item open"
prog() { OUT="$(cd "$NOREPO" && env PATH="$WITHREX_PATH" CLAUDE_CODE_SESSION_ID=pm-rex "$PY" "$PROG" "$@" 2>&1)"; CODE=$?; }
ITEM="rex:${WS}/${BID#block:}"
prog add-item "$ITEM" --run "$RUN_PM" --kind evals_or_docs --title "Rex worker item" --pane "$BID"
it "setup: the Rex item was added"
check "0" "$CODE"
prog claim --run "$RUN_PM" --item "$ITEM" --deliverable merged --ref shawnroos/shrimpshack#97
it "the claim is journaled"
check "0" "$CODE"
STATE="$(env PATH="$WITHREX_PATH" "$PY" - "$AUTO_ROOT" "$RUN_PM" "$ITEM" <<PYEOF
$HEAD_PY
pp = load_lib_module("programme_predicate")
rec = rc.read_run_record(ph.home_path(args[0]), args[0])
item = rec["programme"]["items"][args[1]]
print(pp.effective_state(item), item.get("done_at"))
PYEOF
)"
it "the item is still open and has no done time"
check "open None" "$STATE"

echo "host-rex: a pane's agent_status is read from the status its program reports, only where the server offers it (R1, R2, R3, R6)"
# Fixtures api-program-status-* and api-process-claude-live were captured on a Rex server of API revision 8
# (the proof run); a `handwritten` file in a directory marks the ones that change one captured field.
OVERLAY_ONE="session-ls-json-one api-process-claude-live"
panes_status() { # overlay words as $1; prints the pane's agent_status, or "-" when the key is absent
  env PATH="$WITHREX_PATH" HOST_FAKE_OVERLAY="$1" "$PY" - "$AUTO_ROOT" <<PYEOF
$HEAD_PY
r = rex.list_panes(); p = [x for x in r.value["panes"] if x["pane_id"] == "$BID"][0]
print(r.status, p.get("agent_status", "-"))
PYEOF
}
it "a working Claude reads working"
check "native working" "$(panes_status "$OVERLAY_ONE")"
it "a Claude blocked on a permission reads blocked"
check "native blocked" "$(panes_status "$OVERLAY_ONE api-program-status-blocked")"
it "a finished turn (done) reads idle, which is what the sweep treats as settled"
check "native idle" "$(panes_status "$OVERLAY_ONE api-program-status-done")"
it "a state this host does not know reads idle, as the Rex schema says"
check "native idle" "$(panes_status "$OVERLAY_ONE api-program-status-unknown-state")"
it "a root record that works and a child that is blocked: the worst state wins"
check "native blocked" "$(panes_status "$OVERLAY_ONE api-program-status-tree")"
it "a record whose reporter is not in the block reads unknown (AE2)"
check "native -" "$(panes_status "$OVERLAY_ONE api-program-status-dead-owner")"
it "a pid that now belongs to a program with another name reads unknown"
check "native -" "$(panes_status "session-ls-json-one api-process-reused-pid")"
it "a record with no owner cannot be checked, so it reads unknown"
check "native -" "$(panes_status "$OVERLAY_ONE api-program-status-no-owner")"
it "a block with no records reads unknown and makes no process call"
: > "$CALLS"
OUT="$(panes_status "$OVERLAY_ONE api-program-status-empty")"
check "native -" "$OUT"
lacks "terminal.process" "$(cat "$CALLS")"

it "the reported text never reaches the snapshot: not the message, not an escape sequence (AE5)"
OUT="$(env PATH="$WITHREX_PATH" HOST_FAKE_OVERLAY="$OVERLAY_ONE api-program-status-hostile-message" "$PY" - "$AUTO_ROOT" <<PYEOF
$HEAD_PY
r = rex.list_panes(); text = json.dumps(r.value)
print(r.status, "IGNORE" in text, "\\\\u001b" in text, len(text) < 5000)
PYEOF
)"
check "native False False True" "$OUT"

it "an older server (no status method): no status call, no agent_status, the panes as before (AE3)"
: > "$CALLS"
OUT="$(panes_status "session-ls-json-one api-describe-program-status-missing")"
check "native -" "$OUT"
lacks "program_status {" "$(cat "$CALLS")"
has "api describe com.superlogical.terminal.program_status" "$(cat "$CALLS")"

it "the probe runs once per process however many snapshots are read"
: > "$CALLS"
env PATH="$WITHREX_PATH" HOST_FAKE_OVERLAY="$OVERLAY_ONE" "$PY" - "$AUTO_ROOT" <<PYEOF >/dev/null 2>&1
$HEAD_PY
rex.list_panes(); rex.list_panes(); rex.list_panes()
PYEOF
check "1" "$(grep -c 'api describe' "$CALLS")"

it "a probe that cannot run counts as not offered, never as a refusal"
OUT="$(env PATH="$WITHREX_PATH" HOST_FAKE_OVERLAY="session-ls-json-one" HOST_FAKE_FORCE="command-not-found" "$PY" - "$AUTO_ROOT" <<PYEOF
$HEAD_PY
print(sys.modules[type(rex).__module__]._offers("com.superlogical.terminal.program_status"))
PYEOF
)"
check "False" "$OUT"

it "the number of blocks read per snapshot is capped"
: > "$CALLS"
env PATH="$WITHREX_PATH" HOST_FAKE_OVERLAY="$OVERLAY_ONE" "$PY" - "$AUTO_ROOT" <<PYEOF >/dev/null 2>&1
$HEAD_PY
sys.modules[type(rex).__module__].MAX_STATUS_BLOCKS = 0
rex.list_panes()
PYEOF
lacks "program_status {" "$(cat "$CALLS")"

it "the change token stays free of status, so a status change never wakes the PM (R5)"
OUT="$(env PATH="$WITHREX_PATH" HOST_FAKE_OVERLAY="session-ls-json-one api-program-status-blocked" "$PY" - "$AUTO_ROOT" <<PYEOF
$HEAD_PY
import subprocess
def read_json(argv):
    done = subprocess.run(argv, capture_output=True, text=True)
    return (json.loads(done.stdout), None) if done.returncode == 0 else (None, "exit=%d" % done.returncode)
r = rex.change_token(read_json)
print(sorted(set(k for a in r.value["agents"] for k in a)), any("agent_status" in p for p in r.value["panes"]))
PYEOF
)"
check "['pane_id', 'state_change_seq'] False" "$OUT"

it "a Rex pane that reads idle lets the permission settle see the owner pane as idle, as it does for herdr"
OUT="$(env PATH="$WITHREX_PATH" HOST_FAKE_OVERLAY="$OVERLAY_ONE api-program-status-done" "$PY" - "$AUTO_ROOT" <<PYEOF
$HEAD_PY
settle = load_lib_module("programme_permission_settle")
snap = rex.list_panes().value
print(settle._pane_status(snap, "$BID"), settle._pane_status(snap, "$NOB"))
PYEOF
)"
check "idle gone" "$OUT"

echo "host-rex.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
