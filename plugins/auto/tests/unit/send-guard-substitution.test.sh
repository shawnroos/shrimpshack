#!/usr/bin/env bash
# auto unit test: the send-guard reads shell substitution, heredocs and variable command words the way the shell
# does, so review and build commands pass while a send into another session's pane stays denied. Each legitimate
# shape here was refused in a real programme journal; each denied probe is the nearest bypass of the rule that
# lets the legitimate shape through.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="${SEND_GUARD_AUTO_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
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

echo "send-guard-substitution.test.sh"

WORK="$(mktemp -d -t auto-send-guard.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

for v in $(env | grep -oE '^(HERDR|REX|GHOSTTY|AUTO_TEST)_[A-Z_]*'); do unset "$v"; done
unset CMUX_WORKSPACE_ID TERM_PROGRAM CLAUDE_CODE_SESSION_ID CLAUDE_CODE_ENTRYPOINT CLAUDE_AUTO_REPO 2>/dev/null || true
export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_TEST_HARNESS=1
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
: > "$CLAUDE_AUTO_SECRETS_FILE"
NOREPO="${WORK}/norepo"
mkdir -p "$NOREPO"

FAKES="${WORK}/fakes"
mkdir -p "$FAKES"
export FAKE_HERDR_SNAPSHOT="${WORK}/snapshot.json"
cat > "${FAKES}/herdr" <<'EOF'
#!/bin/bash
[ "$1 $2" = "api snapshot" ] || exit 0
[ -f "$FAKE_HERDR_SNAPSHOT" ] && cat "$FAKE_HERDR_SNAPSHOT"
exit 0
EOF
chmod +x "${FAKES}/herdr"
export PATH="${FAKES}:${PATH}"

HEAD_PY='import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
ph = load_lib_module("programme_home")
sr = load_lib_module("session_registry")
rc = load_lib_module("run_record_core")
args = sys.argv[2:]
'
py() { "$PY" - "$AUTO_ROOT" "$@" 2>&1; }

row() {
  AUTO_TEST_HOST=stub py "$@" <<PYEOF
$HEAD_PY
host, server, workspace, sid, pane, term = args
entry = {"at": rc.now_iso(), "session_id": sid, "pane_id": pane, "terminal_id": term, "server": server,
         "workspace": workspace, "interactive": True, "resolved": host}
if host != "herdr":
    entry["host"] = host
sr._append(sr.registry_path(server, workspace, host), entry)
PYEOF
}

programme() {
  AUTO_TEST_HOST=stub py "$@" <<PYEOF
$HEAD_PY
host, server, workspace, sid = args
print(ph.create_programme([(server, workspace, host)], sid)["run"])
PYEOF
}

hook() {
  local payload
  payload="$("$PY" -c 'import json,sys; print(json.dumps({"session_id": sys.argv[1], "tool_name": "Bash", "tool_input": {"command": sys.argv[2]}}))' "$1" "$2")"
  ( cd "$NOREPO" && env "${@:3}" bash "${HOOKS}/on-pretooluse-action.sh" <<< "$payload" )
}
verdict() { case "$1" in *'"deny"'*) echo deny ;; *) echo allow ;; esac; }
denied()  { it "denied: $1"; check deny "$(verdict "$(hook sess-worker "$1" "${@:2}")")"; }
allowed() {
  local out; out="$(hook sess-worker "$1" "${@:2}")"
  it "allowed: $1"; check allow "$(verdict "$out")"
  [ "$(verdict "$out")" = deny ] && printf '      %s\n' "$(printf %s "$out" | cut -c1-420)"
  return 0
}
# The command is read from stdin, so a multi-line or heavily quoted command is written as it runs.
A() { local c; c="$(cat)"; allowed "$c"; }
D() { local c; c="$(cat)"; denied "$c"; }
# Accepted by the guard before this change too: reported, not asserted, because this work adds no refusal to
# inline code that the line scan already accepts.
G() { local c; c="$(cat)"; printf "  - known gap (accepted today): %s\n" "$(printf %s "$c" | head -2 | tr '\n' ' ')"; }

row herdr default w2 pm-mv w2:p9T term_p9T
programme herdr default w2 pm-mv >/dev/null
row herdr default w2 sess-worker w2:p50 term_p50
row herdr default w2 sess-peer w2:p77 term_p77

echo "send-guard-substitution: a variable command word passes only when every value it can hold passes (KTD4)"
A <<'T'
SKILL_DIR="/Users/me/skills/ce-code-review"; PY="$(for c in python3 python py; do command -v "$c" >/dev/null 2>&1 && "$c" -c '' >/dev/null 2>&1 && { echo "$c"; break; }; done)"; [ -n "$PY" ] || { echo "no working Python 3 interpreter on PATH" >&2; exit 1; };
"$PY" "$SKILL_DIR/scripts/packs-resolve.py"
T
A <<'T'
SCRATCH_ROOT="/tmp/compound-engineering-$(id -u)"; (umask 077; mkdir -p "$SCRATCH_ROOT") || exit 1; chmod 700 "$SCRATCH_ROOT"; RUN_ID=$(date +%Y%m%d-%H%M%S)-$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' ')
T
A <<'T'
W=ls; python3 -c 'print(1)'; $W ls
T
A <<'T'
X=python3; Y=$X; "$Y" -c ''
T
D <<'T'
X=ls; X=$(cat names.txt); $X pane send-text w9:zz hi
T
D <<'T'
X=ls; X=$(printf %s%s her dr); "$X" pane send-text w9:zz hi
T
D <<'T'
PY="$(for c in python3 herdr; do command -v "$c" >/dev/null 2>&1 && { echo "$c"; break; }; done)"; "$PY" pane send-text w9:zz hi
T
D <<'T'
PY="$(for c in python3 bash; do echo "$c"; done)"; "$PY" -c 'herdr pane send-text w9:zz hi'
T
D <<'T'
X=herdr; $X pane send-text w9:zz hi
T
D <<'T'
for c in herdr; do "$c" pane send-text w9:zz hi; done
T
D <<'T'
X=$(echo herdr); $X pane send-text w9:zz hi
T
D <<'T'
X=$(cat /tmp/name); $X pane send-text w9:zz hi
T
D <<'T'
read X; $X pane send-text w9:zz hi
T
D <<'T'
$X pane send-text w9:zz hi
T
D <<'T'
X=her; "${X}dr" pane send-text w9:zz hi
T
D <<'T'
X=her; Y=dr; "$X$Y" pane send-text w9:zz hi
T
D <<'T'
"${X:-herdr}" pane send-text w9:zz hi
T
D <<'T'
"${!X}" pane send-text w9:zz hi
T
D <<'T'
"$1" pane send-text w9:zz hi
T
D <<'T'
X=ls; eval "X=herdr"; $X pane send-text w9:zz hi
T
D <<'T'
X=ls; printf -v X herdr; $X pane send-text w9:zz hi
T
D <<'T'
X=ls; X+=x; $X pane send-text w9:zz hi
T
D <<'T'
X=ls; X=herdr; $X pane send-text w9:zz hi
T
D <<'T'
X=$(printf %s%s her dr); "$X" pane send-text w9:zz hi
T
D <<'T'
X=$(echo -e '\x68erdr'); "$X" pane send-text w9:zz hi
T
D <<'T'
X=$(printf '\150erdr'); "$X" pane send-text w9:zz hi
T
D <<'T'
X=bash; "$X" -c 'herdr pane send-text w9:zz hi'
T
D <<'T'
X=env; "$X" herdr pane send-text w9:zz hi
T
D <<'T'
X=eval; "$X" herdr pane send-text w9:zz hi
T
D <<'T'
for c in her{d,}r; do "$c" pane send-text w9:zz hi; done
T
D <<'T'
for c in /opt/homebrew/bi?/herd?; do "$c" pane send-text w9:zz hi; done
T
D <<'T'
for c in ~/bin/herdr; do "$c" pane send-text w9:zz hi; done
T
D <<'T'
PY="$(for c in python3 python; do command -v "$c"; done)"; "$PY" -c ''
T
D <<'T'
X=herdr; eval "$X pane send-text w9:zz hi"
T

echo "send-guard-substitution: a shell that runs a file does not turn every quoted argument into a script"
A <<'T'
bash tests/run.sh --expect "t.test.sh: [0-9]+ passed" -- bash t.sh | tail -3
T
A <<'T'
python3 -I -c "import json,sys; d=json.load(sys.stdin)['verbs']; print(json.dumps(d['claim'],indent=1))" < in.json; bash status.sh --run r1 | grep -i -B2 -A8 'p11'
T
D <<'T'
echo "herdr pane send-text w9:zz hi" > /tmp/f; bash /tmp/f
T
D <<'T'
echo "$X pane send-text w9:zz hi" > /tmp/f; bash /tmp/f
T
D <<'T'
echo 'herdr pane send-text w9:zz hi' | bash
T
D <<'T'
echo '$X pane send-text w9:zz hi' | bash 2>&1
T
D <<'T'
echo '$X pane send-text w9:zz hi' | sh -s
T
D <<'T'
bash status.sh "herdr pane send-text w9:zz hi"
T

echo "send-guard-substitution: bypasses found in review stay denied"
D <<'T'
cat '<<EOF'
herdr pane send-text w9:zz hi
EOF
T
D <<'T'
cat file # <<EOF
herdr pane send-text w9:zz hi
EOF
T
D <<'T'
cat "<<'EOF'"
herdr pane send-text w9:zz hi
EOF
T
D <<'T'
sort -S 1 --compress-program=sh <<'EOF'
herdr pane send-text w9:zz hi
EOF
T
D <<'T'
X=ls; for i in 1 2; do Y=$X; X=herdr; done; $Y pane send-text w9:zz hi
T
D <<'T'
X=ls; n=X; declare "$n=herdr"; $X pane send-text w9:zz hi
T
D <<'T'
X=ls; source ./vars.sh; $X pane send-text w9:zz hi
T
D <<'T'
X=ls; . ./vars.sh; $X pane send-text w9:zz hi
T
D <<'T'
X=ls; n=X; printf -v "$n" herdr; $X pane send-text w9:zz hi
T
D <<'T'
X=ls; n=X; read -r "$n" < names.txt; $X pane send-text w9:zz hi
T
D <<'T'
echo '$(command -v herdr) pane send-text w9:zz hi' | sed -n 'w /tmp/f'; bash /tmp/f
T
D <<'T'
echo '${H:-herdr} pane send-text w9:zz hi' | awk '{print > "/tmp/f"}'; bash /tmp/f
T
A <<'T'
export PATH="$HOME/bin:$PATH"; PY=python3; "$PY" -c ''
T
D <<'T'
echo "$(cat <<'E'
x
E
herdr pane send-text w9:zz hi
)"
T
D <<'T'
echo $(cat <<'E'
x
E
herdr pane send-text w9:zz hi
)
T
D <<'T'
echo `cat <<'E'
x
E
herdr pane send-text w9:zz hi
`
T
D <<'T'
bash -c "cat <<'E'
x
E
herdr pane send-text w9:zz hi"
T
D <<'T'
cat "x <<'EOF'"
herdr pane send-text w9:zz hi
T
D <<'T'
wc -l \<<'EOF'
herdr pane send-text w9:zz hi
EOF
T
D <<'T'
./cat <<'EOF'
herdr pane send-text w9:zz hi
EOF
T
D <<'T'
cat <<'EOF'
herdr pane send-text w9:zz hi
T

echo "send-guard-substitution: malformed input never raises (an exception in the hook lets the command through)"
it "the scan returns for unclosed quotes, substitutions and heredocs, null bytes and deep nesting"
FUZZ="$(AUTO_ROOT="$AUTO_ROOT" "$PY" -c '
import os, sys
sys.path.insert(0, os.path.join(os.environ["AUTO_ROOT"], "lib"))
import send_guard
cases = ["$(", "`", "echo \"$(", "echo '"'"'$(", "cat <<", "cat <<E", "cat <<\x27E\x27\n", "X=$(", "X=\"$(echo", "for x in", "for x in a;",
         "$X", "\"$X\" a", "X=a; ${X", "\x00", "$(" * 60 + ")" * 60, "a=1 " * 3000 + "$X b", "python3 - <<\x27E\x27\nx = (\nE",
         "node - <<\x27E\x27\n{{{{\nE", "cat <<\x27E\x27\nx\n", "bash <<<", "eval", "X=$(echo $(echo $(", "{", "((", "`echo `"]
for c in cases:
    send_guard.host_sends(c, ["w9:driver"], proven=lambda t: False)
    send_guard.host_sends(c, ["w9:driver"])
print("ok")' 2>&1 | tail -1)"
check ok "$FUZZ"

echo "send-guard-substitution: each refusal names the cause and a change the session can make itself"
OUT="$(hook sess-worker '$X pane send-text w2:p77 hi')"
it "a variable command word with no known value: the fix says to use a literal or set it from literals"
has "set the variable earlier in the same command from literal words" "$OUT"
OUT="$(hook sess-worker 'X=her; "${X}dr" pane send-text w2:p77 hi')"
it "a command word built from parts: the fix says to write one literal word"
has "Write the program name as one literal word" "$OUT"
OUT="$(hook sess-worker 'herdr pane send-text w9:zz hi')"
it "a send to an unproven pane keeps the registry-row fix"
has "another session's registry row shows" "$OUT"
it "no refusal text tells the session to ask someone"
case "$OUT$(hook sess-worker '$X pane send-text w2:p77 hi')" in *"ask Shawn"*|*"ask the PM"*) fail "refusal asks a person" ;; *) pass ;; esac

echo ""
echo "send-guard-substitution.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
