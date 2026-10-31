#!/usr/bin/env bash
# auto unit test: the send-guard denies only what can reach a driver's pane (#146). Harmless worker commands
# pass, every send shape denied before stays denied, and a moved herdr pane is guarded by its live id.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
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

echo "send-guard-precision.test.sh"

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

# A herdr that answers `api snapshot` from a file, fails, hangs or prints junk, so no test reads the real server.
FAKES="${WORK}/fakes"
mkdir -p "$FAKES"
export FAKE_HERDR_SNAPSHOT="${WORK}/snapshot.json"
cat > "${FAKES}/herdr" <<'EOF'
#!/bin/bash
[ "$1 $2" = "api snapshot" ] || exit 0
case "${FAKE_HERDR_MODE:-}" in
  fail) exit 1 ;;
  hang) sleep 5 ;;
  junk) echo '{"result": {"snapshot": "not a dict"}}'; exit 0 ;;
esac
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
allowed() { it "allowed: $1"; check allow "$(verdict "$(hook sess-worker "$1" "${@:2}")")"; }

# The herdr PM started in w2:p9T and was later moved, so herdr now reports it in w2:pAG.
row herdr default w2 pm-mv w2:p9T term_p9T
programme herdr default w2 pm-mv >/dev/null
row herdr default w2 sess-worker w2:p50 term_p50
row herdr default w2 sess-peer w2:p77 term_p77
row herdr default w2 sess-earlier w2:pAG term_old_pAG
row rex srv s-rx pm-rex rex-blk-D1 rex-term-D1
programme rex srv s-rx pm-rex >/dev/null
row rex srv s-rx sess-rex-o rex-blk-O1 rex-term-O1

echo "send-guard-precision: harmless commands are allowed"
allowed 'agent-browser eval '\''document.querySelectorAll("a").forEach(a => a.click())'\'''
allowed 'agent-browser eval '\''window.x >= 3 && f(1)'\'''
allowed 'EMAIL=$(grep SLATE_STAGE_USER_EMAIL ~/.secrets | cut -d= -f2); agent-browser fill @e1 "$EMAIL"'
allowed 'TOKEN=$(cat ~/.secrets/x) PW="$PW" agent-browser fill @e2 "$PW"'
allowed 'if [ "$a" = b ]; then echo ok; fi'
allowed '[[ $a == b ]] && echo ok'
allowed '{ echo hi; } > out.txt'
allowed 'if [ "$a" = "$b" ]; then echo ok; fi'
allowed '[[ $a == $b ]] && echo ok'
allowed 'curl -H x=y "$URL"'
allowed 'make CC=gcc FOO=1 "$TARGET"'
allowed 'make -C build "$TARGET"'
allowed 'ls -la "$DIR"'
allowed 'grep -nE pat "$F" > out.txt'
allowed 'xargs -0 rm "$F"'
allowed 'sudo -E make "$T"'
allowed 'env -i make "$T"'
allowed 'time -p make "$T"'
allowed 'timeout "$SECS" pytest'
allowed 'command -v "$PY"'
allowed 'if command -v "$TOOL" >/dev/null; then echo y; fi'
allowed 'xargs -I {} cp {} /tmp/out'
allowed 'xargs -n "$N" echo'
allowed 'sudo -u "$USER" make all'
allowed 'env -u "$X" make'
allowed 'for t in a b; do bash "$t" > out.txt; echo "exit=$?"; done'
allowed 'rex session rename "$REX_SESSION" auto-hook-146'
allowed 'rex window rename w1 x'
allowed 'rex --help 2>&1 | head -60'
allowed 'herdr pane list 2>/dev/null'
allowed 'R=/tmp/x; cat $R/a.md'
allowed 'grep -nE '\''^\s*(rex|send)'\'' file'
allowed 'cat $R/intake.md; ls docs/plans 2>/dev/null | tail -5'
allowed 'python3 -c "import sys; print(sys.argv)" "$(date)"'

echo "send-guard-precision: real sends stay denied"
denied 'herdr pane send-text w2:p9T hi'
denied 'herdr agent prompt $P go'
denied '$H agent prompt w2:p77 go'
denied '$(command -v herdr) agent prompt w2:p77 go'
denied '$R send -b rex-blk-O1 go'
denied 'rex frobnicate'
denied 'rex send go'
denied 'herdr pane send-text w2:p88 hi > /dev/null'
denied 'herdr pane send-text w2:p88 hi 2>&1'
denied 'echo hi 2>&1 > /dev/ttys016'
denied 'rex block rename rex-blk-D1 x'

echo "send-guard-precision: wrappers, here-strings, groups, globs and braces still reach the scan"
denied "timeout 5 bash -c '\$H agent prompt w2:p77 go'"
denied "env -i bash -c '\$H agent prompt w2:p77 go'"
denied "sudo -u me bash -c '\$H agent prompt w2:p77 go'"
denied "bash <<< '\$H agent prompt w2:p77 go'"
denied 'x=$(true); eval "$H agent prompt w2:p77 go"'
denied '{ eval "$H agent prompt w2:p77 go"; }'
denied '>/dev/null eval "$H agent prompt w2:p77 go"'
denied '/usr/local/bin/herd? agent prompt w2:p77 go'
denied '{herdr,} agent prompt w2:p77 go'
denied '$R api call -s s-rx -b rex-blk-O1 session.view'

echo "send-guard-precision: a send later in a runtime-built command still counts"
denied 'W=nice; H=herdr; $W $H agent prompt $P go'
denied '"$X" "$H" pane send-text $P hi'
denied '$WRAP $R send -b "$B" go'
denied '$(printf her)dr pane send-text w2:p88 hi'
denied '/usr/bin/he$(true)rdr pane send-text w2:p88 hi'
denied '`echo her`dr pane send-text w2:p88 hi'
denied '$H --machine other pane send-text w2:p88 hi'

echo "send-guard-precision: Rex sends behind a variable"
denied '$R send go'
denied '$R send -s s-rx -w 1 go'
denied '$R -s s-pm send-key enter'
denied '$R send -C c1 go'
denied '$R do -e x'
denied '$R api call -s s-rx com.superlogical.terminal.write '\''{"block_id":"'\''$B'\''"}'\'''
denied '$R api -s s-rx call com.superlogical.terminal.write x'

echo "send-guard-precision: verbs hidden in groups, quotes or variables still count"
denied '$(echo $H pane send-text) $P hi'
denied '`echo $R send` go'
denied '$(printf '\''%s send'\'' "$R") go'
denied '$(printf %.0s ")" ";"; printf her)dr pane send-text "$P" hi'
denied '$(printf %.0s ")"; printf rex) send go'
denied '$H pane $V $P hi'
denied '$R $V go'
denied '$R -s s-rx $V go'
denied '$H pane send-$(echo text) $P hi'
denied '=herdr pane send-text $P hi'
denied '"$O" -e '\''tell application "Ghostty" to input text "x" to terminal 1'\'''

denied '$R --session=s-pm $V go'
denied '$R ${V/x/x} go'
denied '${H#} pane send-text $P hi'
denied '{ $H pane send-text $P hi; }'
denied '! $H pane send-text $P hi'

denied 'true;herdr pane send-text $P hi; x="$(echo '\''"'\'')"'
denied 'command a=$X pane send-text w2:p88 hi'
denied 'hash -d r=/opt/homebrew/bin/rex; ~r send -b "$T" hi'
denied 'herdr pane send-text --seq ">" p9T x w2:p77'
denied 'env -i A=1 $H pane send-text $P hi'
denied 'sudo -E A=1 $H pane send-text $P hi'
denied 'time -p A=1 $R send -b $B go'
denied '>/dev/null $H pane send-text $P hi'
denied 'x=1 2>/dev/null $H pane send-text $P hi'
denied 'env -u FOO A=1 $H pane send-text $P hi'
denied 'env -C /tmp A=1 $R send -b $B go'
denied 'sudo -u root A=1 $H pane send-text $P hi'
denied 'nohup env -u X A=1 $H pane send-text $P hi'
denied 'sudo -u root $H pane send-text $P hi'
denied 'nice -n 5 $H pane send-text $P hi'
denied 'A=(pane send-text $P hi); $H "${A[@]}"'
denied '(re|zz)x send -b "$T" hi'
denied 'X=$(echo y) $H pane send-text $P hi'
denied 'echo hi;>f $H pane send-text $P hi'
allowed 'echo $(date) $X'
allowed '(cd /tmp && ls) && echo "$X"'
allowed 'diff <(sort a) <(sort b) > "$OUT"'
it "denied: a thousand assignment prefixes do not crash the guard open"
check deny "$(verdict "$(hook sess-worker "$(printf 'a=1 %.0s' $(seq 1000))\$H pane send-text \$P hi")")"
it "denied fast: twenty thousand assignment prefixes are judged well inside the hook's 10 s limit"
START=$(date +%s)
V="$(verdict "$(hook sess-worker "$(printf 'a=1 %.0s' $(seq 20000))\$H pane send-text \$P hi")")"
ELAPSED=$(( $(date +%s) - START ))
check "deny fast" "$V $([ "$ELAPSED" -lt 5 ] && echo fast || echo "slow:${ELAPSED}s")"

echo "send-guard-precision: any command word built at run time is denied, whatever follows (fails closed)"
denied '"$PY" "$SKILL_DIR/scripts/x.py"'
denied '"$UV" run pytest -s tests/'
denied '$R frobnicate -b rex-blk-O1'
denied 'for f in a b; do "$PY" "$f.py"; done'
denied 'rex send -b rex-blk-X9 go'
allowed 'rex send -b rex-blk-O1 go'

echo "send-guard-precision: a moved herdr pane is guarded by its live id"
cat > "$FAKE_HERDR_SNAPSHOT" <<'EOF'
{"result": {"snapshot": {
  "panes": [{"pane_id": "w2:pAG", "terminal_id": "term_pAG", "workspace_id": "w2", "tab_id": "w2:t42"},
            {"pane_id": "w2:p77", "terminal_id": "term_p77", "workspace_id": "w2", "tab_id": "w2:t1"}],
  "agents": [{"pane_id": "w2:pAG", "agent_session": {"kind": "id", "value": "pm-mv"}}],
  "tabs": []}}}
EOF
OUT="$(hook sess-worker 'herdr pane send-text w2:pAG hi')"
it "a send to the PM's live pane is denied although another session once ran there"
check deny "$(verdict "$OUT")"
it "the denial names the live pane"
has "w2:pAG" "$OUT"
denied 'herdr pane send-text w2:p9T hi'
denied 'herdr pane send-text term_pAG hi'
allowed 'herdr pane send-text w2:p77 hi'
it "the PM's own session may still send to a worker pane"
check allow "$(verdict "$(hook pm-mv 'herdr pane send-text w2:p77 hi')")"

it "after one live sighting, a failed lookup still guards the live pane"
check deny "$(verdict "$(hook sess-worker 'herdr pane send-text w2:pAG hi' FAKE_HERDR_MODE=fail)")"
it "a malformed snapshot neither raises nor drops the guard"
check deny "$(verdict "$(hook sess-worker 'herdr pane send-text w2:pAG hi' FAKE_HERDR_MODE=junk)")"
it "a hanging herdr is cut off well inside the hook's budget"
START=$(date +%s)
V="$(verdict "$(hook sess-worker 'herdr pane send-text w2:pAG hi' FAKE_HERDR_MODE=hang)")"
ELAPSED=$(( $(date +%s) - START ))
check "deny fast" "$V $([ "$ELAPSED" -lt 4 ] && echo fast || echo "slow:${ELAPSED}s")"

echo ""
echo "send-guard-precision.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
