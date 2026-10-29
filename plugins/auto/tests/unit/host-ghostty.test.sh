#!/usr/bin/env bash
# auto unit test: the Ghostty terminal host (R10, R11, R12, R14, R15, R16, R17, AE2, AE3, AE7, KTD3, KTD6, KTD10).
#
# The osascript fake replays recorded output (tests/fixtures/hosts/ghostty). Ghostty had no windows when the
# fixtures were captured, so the empty list and the terminal-not-found send are real; every fixture directory
# that holds a `handwritten` file is NOT captured (a list with terminals, a send that succeeds).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
PROG="${AUTO_ROOT}/lib/programme.py"
WATCH="${AUTO_ROOT}/lib/programme-watch.sh"
HOOKS="${AUTO_ROOT}/.claude/hooks"
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

echo "host-ghostty.test.sh"

WORK="$(mktemp -d -t auto-host-ghostty.XXXXXX)"
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
export CLAUDE_CONFIG_DIR="${WORK}/claude"
: > "$CLAUDE_AUTO_SECRETS_FILE"
mkdir -p "${CLAUDE_CONFIG_DIR}/sessions"
NOREPO="${WORK}/norepo"
mkdir -p "$NOREPO"

W=win-6C1A0E2B-4F7D-4B8E-9A55-1D2C3E4F5A6B
T1=3F2A9C10-7B6E-4D55-8A21-0C9E1B7D4A01
T2=3F2A9C10-7B6E-4D55-8A21-0C9E1B7D4A02
TTY1=/dev/ttys016
TTY2=/dev/ttys017
SETTINGS="System Settings > Privacy & Security > Automation"

export AUTO_ROOT
CALLS="${WORK}/calls.log"
export CALLS
FAKEBIN="${WORK}/fakebin"
host_fake_install ghostty "$FAKEBIN"
# A PATH with no herdr on it: TERM_PROGRAM=ghostty resolves to Ghostty only when no herdr server answers.
NOHERDR_PATH=""
IFS=: read -r -a _dirs <<< "$PATH"
for d in "${_dirs[@]}"; do [ -x "$d/herdr" ] || NOHERDR_PATH="${NOHERDR_PATH:+$NOHERDR_PATH:}$d"; done
GPATH="${FAKEBIN}:${NOHERDR_PATH}"

HEAD_PY='import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
th = load_lib_module("terminal_host")
ph = load_lib_module("programme_home")
pj = load_lib_module("programme_journal")
sr = load_lib_module("session_registry")
rc = load_lib_module("run_record_core")
gh = th.host_named("ghostty")
args = sys.argv[2:]
'
# py <VAR=value ...>: Python with the Ghostty host module loaded, PATH holding the osascript fake.
py() { env PATH="$GPATH" "$@" "$PY" - "$AUTO_ROOT" 2>&1; }
pyargs() { env PATH="$GPATH" HOST_FAKE_OVERLAY="${OVERLAY:-}" "$PY" - "$AUTO_ROOT" "$@" 2>&1; }

echo "host-ghostty: own pane is found by tty, never by a GHOSTTY variable (R11, KTD3)"
it "a tty that Ghostty lists gives the terminal id, the tty as terminal id, the window as space and the title"
OUT="$(env PATH="$GPATH" HOST_FAKE_OVERLAY=terminal-list-pm "$PY" - "$AUTO_ROOT" <<PYEOF
$HEAD_PY
r = gh.own_pane({}, tty="$TTY1")
v = r.value
print(r.status, v["pane_id"], v["terminal_id"], v["server"], v["workspace"], v["tab_space_name"])
PYEOF
)"
check "degraded $T1 $TTY1 local $W Claude Code" "$OUT"

it "AE7, R11: a tty Ghostty does not own finds no pane and refuses with a fix line"
OUT="$(env PATH="$GPATH" HOST_FAKE_OVERLAY=terminal-list-pm "$PY" - "$AUTO_ROOT" <<PYEOF
$HEAD_PY
r = gh.own_pane({}, tty="/dev/ttys099")
print(r.status, r.value, "|", r.why, "|", r.fix)
PYEOF
)"
has "refuse None" "$OUT"
has "no terminal on /dev/ttys099" "$OUT"
has "directly in a Ghostty window" "$OUT"

for bad in "" "??" "None"; do
  it "AE7: an empty or ?? tty ($bad) refuses without asking Ghostty"
  : > "$CALLS"
  OUT="$(env PATH="$GPATH" HOST_FAKE_OVERLAY=terminal-list-pm "$PY" - "$AUTO_ROOT" <<PYEOF
$HEAD_PY
t = None if "$bad" == "None" else "$bad"
r = gh.own_pane({}, tty=t)
print(r.status, r.value, "|", r.why)
PYEOF
)"
  has "refuse None | this session's claude process has no tty" "$OUT"
  check "" "$(cat "$CALLS")"
done

it "KTD3: GHOSTTY_* and TERM_PROGRAM naming a listed terminal do not make a tty Ghostty does not own a pane"
OUT="$(env PATH="$GPATH" HOST_FAKE_OVERLAY=terminal-list-pm GHOSTTY_SURFACE_ID=$T1 GHOSTTY_TERMINAL_ID=$T1 TERM_PROGRAM=ghostty GHOSTTY_RESOURCES_DIR=/x "$PY" - "$AUTO_ROOT" <<PYEOF
$HEAD_PY
r = gh.own_pane(dict(os.environ), tty="/dev/ttys099")
print(r.status, r.value)
PYEOF
)"
check "refuse None" "$OUT"

it "KTD3: with no tty argument the host module walks the process chain, so a faked environment still finds nothing"
OUT="$(env PATH="$GPATH" HOST_FAKE_OVERLAY=terminal-list-pm GHOSTTY_SURFACE_ID=$T1 TERM_PROGRAM=ghostty "$PY" - "$AUTO_ROOT" <<PYEOF
$HEAD_PY
sr.process_tty = lambda *a, **k: None
r = gh.own_pane(dict(os.environ))
print(r.status, r.value)
PYEOF
)"
check "refuse None" "$OUT"

it "a Ghostty with no windows (real capture) has no pane to find"
OUT="$(env PATH="$GPATH" "$PY" - "$AUTO_ROOT" <<PYEOF
$HEAD_PY
print(gh.own_pane({}, tty="$TTY1").status, gh.list_panes().value["panes"])
PYEOF
)"
check "refuse []" "$OUT"

echo "host-ghostty: Automation denied refuses with the Settings path (real capture)"
DENIED="$(env PATH="$GPATH" HOST_FAKE_FORCE=automation-denied "$PY" - "$AUTO_ROOT" <<PYEOF
$HEAD_PY
for name, r in (("own_pane", gh.own_pane({}, tty="$TTY1")), ("list_panes", gh.list_panes()),
                ("send_prompt", gh.send_prompt("$T1", "go")), ("change_token", gh.change_token(None))):
    print(name, r.status, "$SETTINGS" in (r.fix or ""), r.why)
p = gh.presence("pm-gh", {"host": "ghostty", "tty": "$TTY1", "interactive": True, "pane_id": "$T1"}, None, None).value
print("presence", p["state"], p["why"])
PYEOF
)"
for m in own_pane list_panes send_prompt change_token; do
  it "$m refuses and the fix line names the Automation setting"
  has "$m refuse True macOS denied Automation control of Ghostty" "$DENIED"
done
it "presence is unknown, never gone, when Automation is denied"
has "presence unknown Ghostty could not be read (macOS denied Automation" "$DENIED"
it "start_pane maps a spinoff failure that reports the denial to the same refusal"
printf '#!/bin/bash\necho "execution error: Not authorized to send Apple events to Ghostty. (-1743)" >&2\nexit 1\n' > "${WORK}/spin-denied"
chmod +x "${WORK}/spin-denied"
OUT="$(env PATH="$GPATH" "$PY" - "$AUTO_ROOT" "${WORK}/spin-denied" <<PYEOF
$HEAD_PY
r = gh.start_pane([args[0]], 10)
print(r.status, "$SETTINGS" in r.fix, r.value["pane"], r.value["run"]["code"])
PYEOF
)"
check "refuse True None 1" "$OUT"

echo "host-ghostty: list_panes reads the terminal list"
it "two terminals: each pane carries its window as workspace, the title as label and the tty"
OUT="$(env PATH="$GPATH" HOST_FAKE_OVERLAY=terminal-list-pm-worker "$PY" - "$AUTO_ROOT" <<PYEOF
$HEAD_PY
r = gh.list_panes()
print(r.status, [(p["pane_id"], p["workspace_id"], p["label"], p["terminal_id"]) for p in r.value["panes"]])
PYEOF
)"
check "native [('$T1', '$W', 'Claude Code', '$TTY1'), ('$T2', '$W', 'worker', '$TTY2')]" "$OUT"
it "agent rows are degraded: Ghostty does not say which session a terminal runs"
OUT="$(env PATH="$GPATH" "$PY" - "$AUTO_ROOT" <<PYEOF
$HEAD_PY
r = gh.list_panes(agents=True); print(r.status, r.value)
PYEOF
)"
check "degraded []" "$OUT"

echo "host-ghostty: start_pane wraps spinoff with the host named and parses the terminal id"
SPINOFF="${WORK}/spinoff"
cat > "$SPINOFF" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "\$SPINOFF_ARGS"
echo "  agent pane: ghostty $T2"
EOF
chmod +x "$SPINOFF"
export SPINOFF_ARGS="${WORK}/spinoff-args"
OUT="$(env PATH="$GPATH" "$PY" - "$AUTO_ROOT" "$SPINOFF" <<PYEOF
$HEAD_PY
r = gh.start_pane([args[0], "--topic", "x", "--session-id", "w1"], 10)
print(r.status, r.value["pane"], r.value["run"]["code"])
PYEOF
)"
it "start_pane returns the terminal id spinoff reported"
check "native $T2 0" "$OUT"
it "spinoff was told to use the ghostty launcher"
has "--launcher ghostty" "$(cat "$SPINOFF_ARGS")"
it "a spinoff that reported a Rex block or a herdr pane does not give a Ghostty terminal"
printf '#!/bin/bash\necho "agent pane: rex block:1"\necho "herdr agent pane: w1:p2"\n' > "${WORK}/spin-other"; chmod +x "${WORK}/spin-other"
OUT="$(env PATH="$GPATH" "$PY" - "$AUTO_ROOT" "${WORK}/spin-other" <<PYEOF
$HEAD_PY
print(gh.start_pane([args[0]], 10).value["pane"])
PYEOF
)"
check "None" "$OUT"

echo "host-ghostty: confirm_started polls the registry (degraded)"
rowfor() {
  env PATH="$GPATH" "$PY" - "$AUTO_ROOT" "$@" <<PYEOF
$HEAD_PY
sid, pane, host = args
entry = {"at": rc.now_iso(), "session_id": sid, "pane_id": pane, "terminal_id": "$TTY2", "server": "local",
         "workspace": "$W", "interactive": True, "resolved": host, "host": host, "tty": "$TTY2"}
sr._append(sr.registry_path("local", "$W", host), entry)
PYEOF
}
rowfor worker-1 "$T2" ghostty
OUT="$(env PATH="$GPATH" "$PY" - "$AUTO_ROOT" "$T2" <<PYEOF
$HEAD_PY
r = gh.confirm_started("worker-1", args[0], set(), 2, None)
print(r.status, r.value["row"]["pane_id"])
r = gh.confirm_started("worker-1", "other-terminal", set(), 2, None)
print(r.status, r.value["row"])
r = gh.confirm_started("worker-never", None, set(), 0.2, None)
print(r.status, r.value["row"], r.why)
PYEOF
)"
it "a worker whose SessionStart row is in the registry is confirmed, as degraded"
has "degraded $T2" "$OUT"
it "a row in a different terminal than spinoff reported refuses"
has "refuse None" "$OUT"
it "no row within the wait refuses with the session named"
has "no SessionStart row for session worker-never" "$OUT"

echo "host-ghostty: send_prompt types the text then Enter into the located terminal"
: > "$CALLS"
OUT="$(env PATH="$GPATH" HOST_FAKE_OVERLAY=send-ok "$PY" - "$AUTO_ROOT" <<PYEOF
$HEAD_PY
r = gh.send_prompt("$T2", "-go now")
print(r.status, r.value["code"])
PYEOF
)"
it "a terminal Ghostty knows takes the prompt"
check "native 0" "$OUT"
it "the pane and the text follow a double dash, the text unchanged, so a leading dash is not an osascript option"
has "-- $T2 -go now" "$(cat "$CALLS")"
it "the script is the constant, which types with input text and presses enter"
has "input text (item 2 of argv) to tt" "$(cat "$CALLS")"
has 'send key "enter" to tt' "$(cat "$CALLS")"
it "a terminal Ghostty does not list refuses with the reason (real capture), not a silent success"
OUT="$(env PATH="$GPATH" "$PY" - "$AUTO_ROOT" <<PYEOF
$HEAD_PY
r = gh.send_prompt("00000000-0000-0000-0000-000000000000", "go")
print(r.status, r.why)
PYEOF
)"
has "refuse Ghostty has no terminal 00000000-0000-0000-0000-000000000000 (error=terminal-not-found)" "$OUT"

echo "host-ghostty: presence is gone only on two Ghostty facts and unknown otherwise (R16, AE3, KTD6)"
session_file() { # session_file <pid> <session id> [pid-in-file]
  printf '{"pid":%s,"sessionId":"%s","kind":"interactive"}\n' "${3:-$1}" "$2" > "${CLAUDE_CONFIG_DIR}/sessions/$1.json"
}
rm -f "${CLAUDE_CONFIG_DIR}"/sessions/*.json
presence() { # presence <overlay> [LIST_TIMEOUT]
  env PATH="$GPATH" HOST_FAKE_OVERLAY="$1" "$PY" - "$AUTO_ROOT" "${2:-}" <<PYEOF
$HEAD_PY
if args[0]:
    gh.LIST_TIMEOUT = float(args[0])
row = {"host": "ghostty", "tty": "$TTY1", "interactive": True, "pane_id": "$T1", "server": "local", "workspace": "$W"}
r = gh.presence("pm-gh", row, None, None)
print(r.value["state"], "|", r.value["why"])
PYEOF
}
it "AE3: the recorded tty is no longer a Ghostty terminal: gone"
has "gone | /dev/ttys016, where the driving session ran, is no longer a Ghostty terminal" "$(presence "")"
it "the tty is present and the foreground pid is the driving session: present"
session_file 4242 pm-gh
has "present | the terminal on /dev/ttys016 runs the driving session" "$(presence terminal-list-pm)"
it "AE3: the tty is present but Claude's pid file for the foreground pid is missing: unknown"
rm -f "${CLAUDE_CONFIG_DIR}/sessions/4242.json"
has "unknown | process 4242" "$(presence terminal-list-pm)"
it "AE3: the tty is present but the foreground pid cannot be read: unknown"
has "unknown | the foreground process of the terminal on /dev/ttys016 could not be read" "$(presence terminal-list-pm-no-pid)"
it "AE3: the foreground pid belongs to another Claude session: gone"
session_file 4242 someone-else
has "gone | the terminal on /dev/ttys016 now runs another Claude session" "$(presence terminal-list-pm)"
it "a pid file that names a different pid than its own file name is not trusted: unknown"
session_file 4242 someone-else 9999
has "unknown |" "$(presence terminal-list-pm)"
it "a pid file that is not JSON is not trusted: unknown"
echo "not json" > "${CLAUDE_CONFIG_DIR}/sessions/4242.json"
has "unknown |" "$(presence terminal-list-pm)"
it "an osascript that times out: unknown, not gone"
DYN="${WORK}/dyn"; mkdir -p "$DYN"
printf '#!/bin/bash\nsleep 3\n' > "${DYN}/osascript"; chmod +x "${DYN}/osascript"
OUT="$(env PATH="${DYN}:${NOHERDR_PATH}" "$PY" - "$AUTO_ROOT" <<PYEOF
$HEAD_PY
gh.LIST_TIMEOUT = 0.3
row = {"host": "ghostty", "tty": "$TTY1", "interactive": True, "pane_id": "$T1"}
r = gh.presence("pm-gh", row, None, None)
print(r.value["state"], "|", r.value["why"])
PYEOF
)"
has "unknown | Ghostty could not be read (osascript -e" "$OUT"
it "an osascript that errors in some other way: unknown"
printf '#!/bin/bash\necho "boom" >&2\nexit 7\n' > "${DYN}/osascript"
OUT="$(env PATH="${DYN}:${NOHERDR_PATH}" "$PY" - "$AUTO_ROOT" <<PYEOF
$HEAD_PY
row = {"host": "ghostty", "tty": "$TTY1", "interactive": True, "pane_id": "$T1"}
print(gh.presence("pm-gh", row, None, None).value["state"])
PYEOF
)"
check "unknown" "$OUT"
it "no recorded tty, a row from another host, or a headless row: unknown"
OUT="$(env PATH="$GPATH" HOST_FAKE_OVERLAY=terminal-list-pm "$PY" - "$AUTO_ROOT" <<PYEOF
$HEAD_PY
for row in (None, {"host": "ghostty", "interactive": True}, {"host": "rex", "tty": "$TTY1", "interactive": True},
            {"host": "ghostty", "tty": "$TTY1", "interactive": False}):
    print(gh.presence("pm-gh", row, None, None).value["state"], end=" ")
PYEOF
)"
check "unknown unknown unknown unknown " "$OUT"

echo "host-ghostty: SessionStart records the tty and the terminal the host proved (KTD12)"
GENV=(PATH="$GPATH" HOST_FAKE_OVERLAY=terminal-list-pm-worker TERM_PROGRAM=ghostty GHOSTTY_SURFACE_ID=$T2)
record() { # record <session> <tty or None>
  env "${GENV[@]}" "$PY" - "$AUTO_ROOT" "$1" "$2" <<PYEOF
$HEAD_PY
sid, tty = args
e = sr.record_session({"session_id": sid, "source": "startup", "cwd": "/x"}, dict(os.environ), None if tty == "None" else tty)
print(json.dumps(e and {k: e.get(k) for k in ("pane_id", "terminal_id", "tty", "server", "workspace", "host", "tab_space_name")}))
PYEOF
}
it "the hook's tty reaches own_pane: the row names the terminal, the tty, the window and the host"
check "{\"pane_id\": \"$T1\", \"terminal_id\": \"$TTY1\", \"tty\": \"$TTY1\", \"server\": \"local\", \"workspace\": \"$W\", \"host\": \"ghostty\", \"tab_space_name\": \"Claude Code\"}" "$(record pm-gh $TTY1)"
record sess-worker $TTY2 > /dev/null
it "no tty (headless, or no claude ancestor): no row is written"
check "null" "$(record sess-lost None)"
it "a tty Ghostty does not own: no row is written, so the faked GHOSTTY_SURFACE_ID did not make one"
check "null" "$(record sess-faked /dev/ttys099)"

echo "host-ghostty: programme start, AE7 and typed takeover on Ghostty (R14, R21, AE3)"
RUN_PM="$(env PATH="$GPATH" "$PY" - "$AUTO_ROOT" <<PYEOF
$HEAD_PY
print(ph.create_programme([("local", "$W", "ghostty")], "pm-gh")["run"])
PYEOF
)"
it "setup: the programme lease carries the ghostty host"
check "ghostty" "$(ls "${CLAUDE_AUTO_DATA_DIR}/programmes/leases" | grep -o '^ghostty' | head -1)"
as_gh() { # as_gh <session> <VAR=value ...> -- <programme args>
  local sid="$1"; shift
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  OUT="$(cd "$NOREPO" && env PATH="$GPATH" TERM_PROGRAM=ghostty CLAUDE_CODE_SESSION_ID="$sid" "${envs[@]}" "$PY" "$PROG" "$@" 2>&1)"
  CODE=$?
}
record_lone() { env PATH="$GPATH" HOST_FAKE_OVERLAY=terminal-list-lone TERM_PROGRAM=ghostty "$PY" - "$AUTO_ROOT" <<PYEOF
$HEAD_PY
e = sr.record_session({"session_id": "sess-lone2", "source": "startup", "cwd": "/x"}, dict(os.environ), "/dev/ttys018")
print(e["workspace"])
PYEOF
}
it "setup: the lone session's row names its own window"
check "win-9D8C7B6A-1111-4222-8333-444455556666" "$(record_lone)"
it "R14: start from a registered Ghostty session succeeds and records the space"
as_gh sess-lone2 HOST_FAKE_OVERLAY=terminal-list-lone -- start
check "0" "$CODE"
has "programme_started" "$OUT"
it "AE7: a session with no registry row whose tty matches no Ghostty terminal is refused by start, with a fix line"
as_gh sess-nowhere HOST_FAKE_OVERLAY=terminal-list-pm-worker -- start
check "1" "$CODE"
has "cannot identify this session's ghostty terminal pane" "$OUT"
has "Ghostty window" "$OUT"

echo "host-ghostty: change_token is a hash of the terminal list and the remit watcher wakes only when it moves (R17)"
LIST="${WORK}/list"
cat > "${DYN}/osascript" <<EOF
#!/bin/bash
cat "${LIST}"
EOF
chmod +x "${DYN}/osascript"
rec() { printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1e' "$@"; }
write_list() { { rec $W $T1 $TTY1 4242 "Claude Code"; rec $W $T2 $TTY2 "$1" "$2"; printf '\n'; } > "$LIST"; }
write_list 4343 worker
tokens() { env PATH="${DYN}:${NOHERDR_PATH}" CLAUDE_CODE_SESSION_ID="${1:-}" "$PY" - "$AUTO_ROOT" <<PYEOF
$HEAD_PY
r = gh.change_token(None)
print(r.status, sorted((a["pane_id"][-2:], a["state_change_seq"]) for a in r.value["agents"]))
PYEOF
}
A="$(tokens)"
it "the token is degraded and gives every terminal a number"
has "degraded [('01'," "$A"
it "the same list gives the same token"
check "$A" "$(tokens)"
write_list 4343 "worker busy"
it "a title change moves that terminal's number"
if [ "$A" != "$(tokens)" ]; then pass; else fail "title change did not move the token"; fi
write_list 4343 worker
it "the PM's own terminal is left out, so its own title changes cannot wake it"
has "[('02'," "$(tokens pm-gh)"
lacks "('01'" "$(tokens pm-gh)"

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
: > "$BEATS"
wait_for() { local file="$1" pattern="$2" limit="${3:-100}" n=0
  while ! grep -q -- "$pattern" "$file" 2>/dev/null; do sleep 0.1; n=$((n + 1)); [ "$n" -ge "$limit" ] && return 1; done; return 0; }
env PATH="${DYN}:${NOHERDR_PATH}" CLAUDE_CODE_SESSION_ID=pm-gh TERM_PROGRAM=ghostty bash "$WATCH" --run "$RUN_PM" > "${WORK}/watch.out" 2> "${WORK}/watch.err" &
WPID=$!
BG_PIDS="$BG_PIDS $WPID"
wait_for "$BEATS" "watcher-beat remit" || true
sleep 1.2
it "nothing changed across several polls: the watcher prints nothing"
check "" "$(cat "${WORK}/watch.out")"
write_list 4344 worker
wait_for "${WORK}/watch.out" "remit-changed" || true
it "the worker terminal's foreground pid changed: one remit-changed line names the terminal"
has "remit-changed" "$(cat "${WORK}/watch.out")"
has "${T2}" "$(cat "${WORK}/watch.out")"
it "the wake is exactly one line"
check 1 "$(wc -l < "${WORK}/watch.out" | tr -d ' ')"
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

echo "host-ghostty: notify is degraded to a journal line"
OUT="$("$PY" - "$AUTO_ROOT" <<PYEOF
$HEAD_PY
r = gh.notify("t", "b"); print(r.status, r.value)
PYEOF
)"
it "no Ghostty notification exists, so the answer is degraded and says where the ask lives"
check "degraded journal" "$OUT"

echo "host-ghostty: is_host_command treats any osascript naming the terminal as a send"
cmd_hit() { # cmd_hit <argv words...>: prints the verb and target, or none
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF
$HEAD_PY
hit = gh.is_host_command(args, pane_ids=["$T1", "$TTY1", None])
print("none" if hit is None else hit[0] + "|" + hit[1])
PYEOF
}
it "input text to the terminal id"
check "input text|$T1" "$(cmd_hit osascript -e "tell application \"Ghostty\" to input text \"x\" to terminal id \"$T1\"")"
it "the terminal id in a different case"
check "input text|$T1" "$(cmd_hit osascript -e "tell application \"Ghostty\" to input text \"x\" to (first terminal whose id is \"$(echo $T1 | tr A-F a-f)\")")"
it "send key to the terminal whose tty is the PM's"
check "send key|$TTY1" "$(cmd_hit osascript -e "tell application \"Ghostty\" to send key \"enter\" to (first terminal whose tty is \"$TTY1\")")"
it "the tty written without /dev/"
check "send key|$TTY1" "$(cmd_hit osascript -e 'tell application "Ghostty" to send key "enter" to (first terminal whose tty contains "ttys016")')"
it "perform action"
check "perform action|$T1" "$(cmd_hit osascript -e "tell application \"Ghostty\" to perform action \"close_surface\" on terminal id \"$T1\"")"
it "a script file that takes the terminal id as an argument"
check "script|$T1" "$(cmd_hit osascript /tmp/x.scpt "$T1")"
it "any Ghostty script that only reads the PM's terminal is still a hit (default deny)"
check "script|$T1" "$(cmd_hit osascript -e "tell application \"Ghostty\" to get name of terminal id \"$T1\"")"
it "the binary named through a variable or an absolute path"
check "input text|$T1" "$(cmd_hit '$OSASCRIPT' -e "input text to terminal id \"$T1\"")"
check "input text|$T1" "$(cmd_hit /usr/bin/osascript -e "input text to terminal id \"$T1\"")"
it "a send that picks every terminal reaches the PM's, so it is a hit"
check "input text|$T1" "$(cmd_hit osascript -e 'tell application "Ghostty" to repeat with t in terminals
input text "x" to t
end repeat')"
check "send key|$T1" "$(cmd_hit osascript -e 'tell application "Ghostty" to send key "enter" to focused terminal of front window')"
it "a send to another terminal id is not a hit"
check "none" "$(cmd_hit osascript -e "tell application \"Ghostty\" to input text \"x\" to terminal id \"$T2\"")"
it "an unrelated osascript call is not a hit"
check "none" "$(cmd_hit osascript -e 'display notification "hi"')"
it "another program's command is not a hit"
check "none" "$(cmd_hit herdr agent prompt "$T1" hi)"
it "text that merely contains part of the tty digits is not taken for it"
check "none" "$(cmd_hit osascript -e 'tell application "Ghostty" to input text "x" to terminal id "other" -- ttys0160')"

echo "host-ghostty: the guard blocks and journals osascript input text into the PM's terminal (R12)"
hook() {
  local payload
  payload="$("$PY" -c 'import json,sys; print(json.dumps({"session_id": sys.argv[1], "tool_name": "Bash", "tool_input": {"command": sys.argv[2]}}))' "$1" "$2")"
  ( cd "$NOREPO" && env PATH="$GPATH" "${@:3}" bash "${HOOKS}/on-pretooluse-action.sh" <<< "$payload" )
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
SEND_PM="osascript -e 'tell application \"Ghostty\" to input text \"go\" to terminal id \"$T1\"'"
it "another session's input text into the PM's terminal id, every wrapper form"
every_form sess-worker "$SEND_PM" deny
it "send key by the PM's tty, every wrapper form"
every_form sess-worker "osascript -e 'tell application \"Ghostty\" to send key \"enter\" to (first terminal whose tty is \"$TTY1\")'" deny
it "the PM typing into its own terminal, every wrapper form"
every_form pm-gh "osascript /tmp/send.scpt $T1 go" deny
every_form pm-gh "osascript /tmp/send.scpt $TTY1 go" deny
it "a script file that gets the PM's id as an argument"
every_form sess-worker "osascript /tmp/send.scpt $T1 go" deny
it "the attempt is journaled with the verb and the PM's terminal"
ROW="$(env PATH="$GPATH" "$PY" - "$AUTO_ROOT" "$RUN_PM" <<PYEOF
$HEAD_PY
r = [x for x in pj.read(args[0]) if x["kind"] == "blocked_driver_send"][0]
print(r["kind"], r["session_id"], r["payload"]["verb"], r["payload"]["target"])
PYEOF
)"
check "blocked_driver_send sess-worker input text $T1" "$ROW"
it "input text into the worker's own terminal stays allowed, every wrapper form"
every_form sess-worker "osascript -e 'tell application \"Ghostty\" to input text \"go\" to terminal id \"$T2\"'" allow
it "KTD3: GHOSTTY variables that claim the worker is the PM do not weaken the guard"
FAKES=(GHOSTTY_SURFACE_ID=$T1 TERM_PROGRAM=ghostty GHOSTTY_RESOURCES_DIR=/x HERDR_PANE_ID=w9:p9)
every_form sess-worker "$SEND_PM" deny "${FAKES[@]}"
it "KTD3: GHOSTTY variables naming the PM do not make a send to another terminal look like the PM's"
every_form sess-worker "osascript -e 'tell application \"Ghostty\" to input text \"go\" to terminal id \"$T2\"'" allow "${FAKES[@]}"

echo "host-ghostty: typed takeover moves the lease only on Ghostty evidence (R13, AE3)"
N=0
CASE_RUN="" CASE_PM="" CASE_TAKER=""
# fresh_case: a Ghostty programme with its own PM terminal (tty ttys016 recorded) and a taker in the same window.
fresh_case() { # fresh_case <n>: prints the run id; the caller names the sessions with the same n
  env "${GENV[@]}" "$PY" - "$AUTO_ROOT" "pm-t$1" "taker-t$1" "$1" <<PYEOF
$HEAD_PY
pm, tk, n = args
win = "win-take" + n
for sid, pane, tty in ((pm, "pane-pm" + n, "$TTY1"), (tk, "pane-tk" + n, "$TTY2")):
    sr._append(sr.registry_path("local", win, "ghostty"), {"at": rc.now_iso(), "session_id": sid, "pane_id": pane,
               "terminal_id": tty, "tty": tty, "server": "local", "workspace": win, "interactive": True,
               "resolved": "ghostty", "host": "ghostty"})
print(ph.create_programme([("local", win, "ghostty")], pm)["run"])
PYEOF
}
takeover_gh() {
  OUT="$(env PATH="$GPATH" HOST_FAKE_OVERLAY="$1" TERM_PROGRAM=ghostty CLAUDE_CODE_SESSION_ID="$CASE_TAKER" "$PY" "$PROG" takeover 2>&1)"
  CODE=$?
}
typed() {
  ( cd "$NOREPO" && env PATH="$GPATH" TERM_PROGRAM=ghostty "$PY" "${AUTO_ROOT}/tests/fixtures/programme_prompts.py" "$AUTO_ROOT" "$CASE_TAKER" "$1" >/dev/null 2>&1 )
}
driver() {
  env PATH="$GPATH" "$PY" - "$AUTO_ROOT" "$CASE_RUN" <<PYEOF
$HEAD_PY
print(ph._read_record(args[0]).get("driving_session_id"))
PYEOF
}
rm -f "${CLAUDE_CONFIG_DIR}"/sessions/*.json
N=$((N + 1)); CASE_PM="pm-t$N"; CASE_TAKER="taker-t$N"; CASE_RUN="$(fresh_case $N)"
typed '/auto:programme-takeover'
it "AE3: the PM's tty is present but its foreground cannot be read: the typed takeover is refused"
takeover_gh terminal-list-pm-no-pid
check "1 $CASE_PM" "$CODE $(driver)"
it "the refusal does not claim the PM is gone"
lacks "driver_gone" "$OUT"
it "AE3: the PM's tty is present and its foreground is the PM: refused"
session_file 4242 "$CASE_PM"
takeover_gh terminal-list-pm
check "1 $CASE_PM" "$CODE $(driver)"
N=$((N + 1)); CASE_PM="pm-t$N"; CASE_TAKER="taker-t$N"; CASE_RUN="$(fresh_case $N)"
typed '/auto:programme-takeover'
it "AE3: the PM's tty is no longer a Ghostty terminal: the typed takeover moves the lease"
takeover_gh terminal-list-empty
check "0 $CASE_TAKER" "$CODE $(driver)"
N=$((N + 1)); CASE_PM="pm-t$N"; CASE_TAKER="taker-t$N"; CASE_RUN="$(fresh_case $N)"
typed '/auto:programme-takeover'
it "AE3: the PM's foreground process is another session: the typed takeover moves the lease"
session_file 4242 some-other-session
takeover_gh terminal-list-pm
check "0 $CASE_TAKER" "$CODE $(driver)"

echo "host-ghostty: R10, a worker's message that its item is done leaves the item open (AE2)"
prog() { OUT="$(cd "$NOREPO" && env PATH="$GPATH" CLAUDE_CODE_SESSION_ID=pm-gh "$PY" "$PROG" "$@" 2>&1)"; CODE=$?; }
ITEM="ghostty:${W}/${T2}"
prog add-item "$ITEM" --run "$RUN_PM" --kind evals_or_docs --title "Ghostty worker item" --pane "$T2"
it "setup: the Ghostty item was added"
check "0" "$CODE"
prog claim --run "$RUN_PM" --item "$ITEM" --deliverable merged --ref shawnroos/shrimpshack#97
it "the claim is journaled"
check "0" "$CODE"
STATE="$(env PATH="$GPATH" "$PY" - "$AUTO_ROOT" "$RUN_PM" "$ITEM" <<PYEOF
$HEAD_PY
pp = load_lib_module("programme_predicate")
rec = rc.read_run_record(ph.home_path(args[0]), args[0])
item = rec["programme"]["items"][args[1]]
print(pp.effective_state(item), item.get("done_at"))
PYEOF
)"
it "the item is still open and has no done time"
check "open None" "$STATE"

echo "host-ghostty: the host module does not depend on the working-directory quirk"
it "a terminal's working directory reads empty after command:, so no host module code reads it"
check "0" "$(grep -ci 'working directory' "${AUTO_ROOT}/lib/host_ghostty.py" | tr -d ' ')"

echo "host-ghostty.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
