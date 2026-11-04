#!/usr/bin/env bash
# auto unit test: the send-guard refuses only a literal send into a PM's pane from that programme's own sessions.
# A command that only names the pane, reads it or computes its target passes. A moved herdr pane is guarded by its live id.

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
lacks() { case "$2" in *"$1"*) fail "did not expect [$1] in [$2]" ;; *) pass ;; esac; }

echo "send-guard-literal.test.sh"

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
RUN_MV="$(programme herdr default w2 pm-mv)"
row herdr default w2 sess-worker w2:p50 term_p50
row herdr default w2 sess-peer w2:p77 term_p77
row herdr default w2 sess-earlier w2:pAG term_old_pAG
row rex srv s-rx pm-rex rex-blk-D1 rex-term-D1
programme rex srv s-rx pm-rex >/dev/null
row rex srv s-rx sess-rex-o rex-blk-O1 rex-term-O1
row ghostty srv g-1 pm-gh ghost-term-9 /dev/ttys016
programme ghostty srv g-1 pm-gh >/dev/null
row ghostty srv g-1 sess-gh-o ghost-term-8 /dev/ttys017
# In no leased space and on no item: outside every programme.
row herdr default w8 sess-outside w8:p1 term_w8p1
# In another space, and in the record of the herdr programme as an item's owner or listed session.
row herdr default w9 sess-far-owner w9:p1 term_w9p1
row herdr default w9 sess-far-listed w9:p2 term_w9p2
row herdr default w9 sess-far-done w9:p3 term_w9p3
py "$RUN_MV" <<PYEOF >/dev/null
$HEAD_PY
def mutate(rec):
    rec["programme"]["items"] = {
        "linear:A-1": {"id": "linear:A-1", "title": "owned", "state": "open", "owner": {"session_id": "sess-far-owner"}},
        "linear:A-2": {"id": "linear:A-2", "title": "listed", "state": "open", "owner": {"session_id": "sess-x"},
                       "sessions": [{"session_id": "sess-far-listed"}]},
        "linear:A-3": {"id": "linear:A-3", "title": "finished", "state": "done", "owner": {"session_id": "sess-far-done"}},
        "linear:A-4": {"id": "linear:A-4", "title": "no row", "state": "open", "owner": {"session_id": "sess-no-row-item"}},
    }
rc._with_locked_run_record(ph.home_path(args[0]), args[0], mutate)
PYEOF

PM=w2:p9T

echo "send-guard-literal: a literal send into the PM's pane from a worker is refused"
denied "herdr agent prompt $PM go"
denied "herdr pane run $PM ls"
denied "herdr pane send-text $PM hi"
denied "herdr pane send-keys $PM enter"
denied "herdr agent send-keys $PM esc"
denied "herdr pane close $PM"
denied "herdr --session default pane run $PM ls"
denied "herdr pane run $PM ls > /dev/null 2>&1"
denied "/opt/homebrew/bin/herdr pane run $PM ls"
denied "\$HERDR_BIN_PATH pane run $PM ls"
denied "\"\$HERDR_BIN_PATH\" pane run $PM ls"
denied "herdr pane run term_p9T ls"
denied "herdr pane run p9T ls"
denied "h''erdr pane run $PM ls"
denied "HERDR pane run $PM ls"
denied "/opt/homebrew/bin/heRdr pane run $PM ls"
denied "BASH -c 'herdr pane run $PM ls'"
denied "her\\dr pane run $PM ls"
denied "herdr pane run w2:\$'p9T' ls"
denied "herdr pane run \$'\\x77'2:p9T ls"
denied "env -u X herdr pane run $PM ls"
denied "env FOO=1 herdr pane run $PM ls"
denied "sudo -u root herdr pane run $PM ls"
denied "nice -n 5 herdr pane run $PM ls"
denied "nohup herdr pane run $PM ls"
denied "timeout 5 herdr pane run $PM ls"
denied "timeout -k 1 5 herdr pane run $PM ls"
denied "gtimeout 5 herdr pane run $PM ls"
denied "FOO=1 herdr pane run $PM ls"
denied ">/dev/null herdr pane run $PM ls"
denied "ls && herdr pane run $PM ls"
denied "ls; herdr pane run $PM ls"
denied "ls | herdr pane run $PM ls"
denied "ls
herdr pane run $PM ls"
denied "(herdr pane run $PM ls)"
denied "{ herdr pane run $PM ls; }"
denied "if true; then herdr pane run $PM ls; fi"
denied "case x in a) :;; esac; herdr pane run $PM ls"
denied "bash -c 'herdr pane run $PM ls'"
denied "/bin/sh -ec 'herdr pane run $PM ls'"
denied "timeout 5 bash -c 'herdr pane run $PM ls'"
denied "eval 'herdr pane run $PM ls'"
denied "eval herdr pane run $PM ls"
denied "bash -c \"eval 'herdr pane run $PM ls'\""
denied "echo \"\$(herdr pane run $PM ls)\""
denied "echo \`herdr pane run $PM ls\`"
denied "X=\$(herdr pane run $PM ls); echo \$X"
denied "bash <<EOF
herdr pane run $PM ls
EOF"
denied "cat <<'EOF' | bash
echo don't
herdr pane run $PM ls
EOF"
denied "bash <<< 'herdr pane run $PM ls'"

echo "send-guard-literal: a computed send gets through"
allowed "H=herdr; \$H pane run $PM ls"
allowed "\$H agent prompt $PM go"
allowed "P=$PM; herdr pane run \$P ls"
allowed "herdr pane run \$P ls"
allowed "herdr pane run w2:p\$N ls"
allowed "herdr pane run \$(cat /tmp/pane) ls"
allowed "\$(command -v herdr) pane run $PM ls"
allowed "/usr/bin/he\$(true)rdr pane run $PM ls"
allowed "python3 -c \"import os; os.system('herdr pane run $PM ls')\""
allowed "ruby -e 'system(\"herdr pane run $PM ls\")'"
allowed "python3 - <<EOF
os.system('herdr pane run $PM ls')
EOF"
allowed "echo 'herdr pane run $PM ls' | bash"
allowed "bash <(echo 'herdr pane run $PM ls')"
allowed "bash script.sh 'herdr pane run $PM ls'"
allowed "bash /tmp/send.sh $PM"
allowed "echo hi > /dev/ttys016"

echo "send-guard-literal: a command that only names the pane or the verb is allowed"
allowed "echo herdr pane run $PM ls"
allowed "echo $PM"
allowed "echo 'driver is $PM'"
allowed "grep -rn herdr pane run $PM lib"
allowed "git grep 'herdr pane run $PM'"
allowed "git grep osascript tmux"
allowed "git commit -m 'herdr pane run $PM ls'"
allowed "printf '%s\\n' herdr pane run $PM"
allowed "cat <<'EOF' > notes.md
herdr pane run $PM ls
EOF"
allowed "cat > notes.md <<EOF
herdr pane run $PM ls
EOF"
allowed "gh pr create --body \"\$(cat <<'EOF'
herdr pane run $PM ls
EOF
)\""
allowed "herdr pane get $PM"
allowed "herdr pane read $PM"
allowed "herdr agent read $PM"
allowed "herdr pane list"
allowed "herdr pane close --help"
allowed "herdr pane close"
allowed "herdr frob $PM"
allowed "which herdr pane run $PM"
allowed "which rex herdr"
allowed "type herdr rex"
allowed "whereis rex herdr"
allowed "command -v herdr rex"
allowed "sed -n 1,50p lib/host_rex.py; grep -n send_prompt lib/host_herdr.py"
allowed "bash ~/.claude/tools/honest-run/run.sh --expect '[0-9]+ passed' -- pytest -q"

echo "send-guard-literal: a send to another pane is allowed"
allowed "herdr pane run w2:p77 ls"
allowed "bash -c 'herdr pane run w2:p77 ls'"
allowed "herdr pane close w2:p77"
allowed "herdr agent prompt w2:p88 go"
allowed "herdr agent prompt go"
allowed "ls && herdr pane run w2:p77 ls"

echo "send-guard-literal: ordinary commands stay allowed"
allowed 'agent-browser eval '\''document.querySelectorAll("a").forEach(a => a.click())'\'''
allowed 'agent-browser eval '\''window.x >= 3 && f(1)'\'''
allowed 'EMAIL=$(grep SLATE_STAGE_USER_EMAIL ~/.secrets | cut -d= -f2); agent-browser fill @e1 "$EMAIL"'
allowed 'if [ "$a" = b ]; then echo ok; fi'
allowed 'rex session rename "$REX_SESSION" auto-hook-146'
allowed 'rex --help 2>&1 | head -60'
allowed '"$PY" "$SKILL_DIR/scripts/x.py"'
allowed 'for c in python3 py; do "$c" x.py; done'
allowed '/opt/homebrew/bin/tmux -S /private/tmp/enf2/s.sock send-keys -t enf -l "hello"'
allowed 's=queued; case "$s" in *in_progress*|*queued*) echo wait;; *) echo settled;; esac'
allowed 'cat > probe.mjs <<'\''EOF'\''
const shot = (kind, extra = {}) => ({ index: 0, kind, ...extra });
EOF'
allowed 'prev=""; s=$(gh pr checks 497 --json name,bucket); cur=$(jq -r '\''.[] | select(.bucket!="pending")'\'' <<<"$s" | sort); comm -13 <(echo "$prev") <(echo "$cur")'
allowed 'echo "peer-deadline-secs=$(( ${CROSS_MODEL_HARD_SECS:-1200} + 10 ))"'

echo "send-guard-literal: Rex"
as_rex() { it "$1: $2"; check "$1" "$(verdict "$(hook sess-rex-o "$2")")"; }
as_rex deny 'rex send -b rex-blk-D1 hi'
as_rex deny 'rex send --block=rex-blk-D1 hi'
as_rex deny 'rex send -brex-blk-D1 hi'
as_rex deny 'rex api call -b rex-blk-D1 session.view'
as_rex deny 'rex api call -s s-rx com.superlogical.terminal.write '\''{"block_id":"rex-blk-D1"}'\'''
as_rex deny 'rex -s s-rx send -b rex-blk-D1 hi'
as_rex deny 'rex -b rex-blk-D1 send hi'
as_rex deny 'rex api -s s-rx call m '\''{"block_id":"rex-blk-D1"}'\'''
as_rex deny 'REX send -b rex-blk-D1 hi'
as_rex allow 'rex frob -b rex-blk-D1'
as_rex allow 'rex capture -b rex-blk-D1 --trim'
as_rex allow 'rex block rename rex-blk-D1 x'
as_rex allow 'echo rex send -b rex-blk-D1 hi'
as_rex allow 'rex send hi rex-blk-D1'
as_rex allow 'rex send -b rex-blk-O1 rex-blk-D1'
as_rex allow 'rex api call -s s-rx session.view'
as_rex allow 'rex api call -s s-rx m '\''{"block_id":"rex-blk-O1","data":"rex-blk-D1"}'\'''
as_rex allow 'rex send -b $B go'

echo "send-guard-literal: Ghostty"
as_gh() { it "$1: $2"; check "$1" "$(verdict "$(hook sess-gh-o "$2")")"; }
as_gh deny 'osascript -e '\''tell application "Ghostty" to input text "x" to terminal id "ghost-term-9"'\'''
as_gh deny 'osascript -e '\''tell application "Ghostty" to send key "enter" to (first terminal whose tty is "/dev/ttys016")'\'''
as_gh deny 'echo '\''tell application "Ghostty" to input text "x" to terminal id "ghost-term-9"'\'' | osascript'
as_gh deny 'OSASCRIPT -e '\''input text "x" to terminal id "ghost-term-9"'\'''
as_gh allow 'osascript -e '\''return "ghost-term-9"'\'''
as_gh allow 'osascript -e '\''tell application "Ghostty" to get name of terminal id "ghost-term-9"'\'''
as_gh allow 'osascript /tmp/x.scpt ghost-term-9'
as_gh allow 'osascript -e '\''tell application "System Events" to keystroke "x"'\'''
as_gh allow 'osascript -e '\''tell application "Ghostty" to input text "x" to first terminal'\'''
as_gh allow 'osascript -e '\''tell application "Ghostty" to send key "enter" to focused terminal of front window'\'''
as_gh allow 'osascript -e '\''tell application "Ghostty" to input text "x" to terminal id "ghost-term-8"'\'''
as_gh allow 'osascript -e '\''display notification "hi"'\'''
as_gh allow 'echo '\''display notification "hi"'\'' | osascript'
as_gh allow 'echo osascript -e '\''input text "x" to terminal id "ghost-term-9"'\'''

BSNL=$'\\\n'
echo "send-guard-literal: a comment does not hide a literal send"
denied "cd /tmp  # go there
herdr pane run $PM ls"
denied "echo a # note
herdr pane run $PM ls"
denied "# don't run this twice
echo a
herdr pane send-text $PM hi"
denied "echo a # don't
herdr pane send-text $PM hi"
denied "echo a#b; herdr pane send-text $PM hi"
denied "gh pr view org/repo#12 && herdr pane send-text $PM hi"
denied "curl https://x.y/z#frag; herdr pane send-text $PM hi"
denied "echo \${#a}; herdr pane send-text $PM hi"
denied "echo \$(date)#x; herdr pane send-text $PM hi"
denied "bash -c 'cd /tmp # x
herdr pane send-text $PM hi'"
denied "cat <<EOF | bash
cd /tmp # x
herdr pane send-text $PM hi
EOF"
denied "cat <<EOF | bash # don't
herdr pane send-text $PM hi
EOF"
denied "echo 'a # b'; herdr pane send-text $PM hi"
denied "echo hi # cat <<EOF
herdr pane send-text $PM hi"
denied "# a comment ends at its newline ${BSNL}herdr pane send-text $PM hi"
denied "echo \`a # b\` ; herdr pane send-text $PM hi"
denied "echo \`a # b\`; herdr pane send-text $PM hi"
allowed "echo hi # see \`herdr pane send-text $PM hi\`"
allowed "# herdr pane send-text $PM hi"
allowed "echo hi # herdr pane send-text $PM hi"
allowed "echo hi # don't; herdr pane send-text $PM hi"
allowed "echo 'a # b' herdr pane send-text $PM hi"
allowed "cat <<'EOF' # it's notes
herdr pane send-text $PM hi
EOF"

echo "send-guard-literal: a backslash-newline does not hide a literal send"
denied "herdr pane send-text ${BSNL}  $PM hi"
denied "herdr ${BSNL}  pane send-text $PM hi"
denied "cd /tmp && ${BSNL}  herdr pane send-text $PM hi"
denied "her${BSNL}dr pane send-text $PM hi"
denied "bash -c 'herdr ${BSNL} pane send-text $PM hi'"
denied "bash -c \"herdr ${BSNL} pane send-text $PM hi\""
denied "herdr pane send-text \"w2:${BSNL}p9T\" hi"
allowed "echo 'a${BSNL}b' herdr pane send-text $PM hi"
allowed "echo a ${BSNL}  herdr pane send-text $PM hi"
allowed "herdr pane send-text ${BSNL}  w2:p77 hi"
as_rex deny "rex ${BSNL}  send -b rex-blk-D1 hi"
as_rex deny "cd /tmp && ${BSNL}  rex send -b rex-blk-D1 hi"
as_gh deny "cd /tmp && ${BSNL}  osascript -e 'input text \"x\" to terminal id \"ghost-term-9\"'"

echo "send-guard-literal: Rex's block noun"
as_rex deny 'rex block send -b rex-blk-D1 hi'
as_rex deny 'rex block send-key -b rex-blk-D1 enter'
as_rex deny 'rex block call -b rex-blk-D1 foo'
as_rex deny 'rex -S srv block send --block=rex-blk-D1 hi'
as_rex allow 'rex block send -b rex-blk-O1 hi'
as_rex allow 'rex block send-key -b rex-blk-O1 enter'
as_rex allow 'rex block capture -b rex-blk-D1'
as_rex allow 'rex block inspect -b rex-blk-D1'
as_rex allow 'rex block close -b rex-blk-D1'
as_rex allow 'echo rex block send -b rex-blk-D1 hi'
it "the refusal names the block noun's verb"
has "rex block send" "$(hook sess-rex-o 'rex block send -b rex-blk-D1 hi')"

echo "send-guard-literal: an ordinary word after a command is not a command position"
allowed "echo do herdr pane send-text $PM hi"
allowed "echo if herdr pane send-text $PM hi"
allowed "echo exec herdr pane send-text $PM hi"
allowed "grep time herdr pane send-text $PM"
allowed "echo then herdr pane send-text $PM hi"
denied "function f { herdr pane send-text $PM hi; }"
denied "f() { herdr pane send-text $PM hi; }"
denied "if [[ a ]] then herdr pane send-text $PM hi; fi"
denied "if { true; } then herdr pane send-text $PM hi; fi"
denied "while [[ -z x ]] do herdr pane send-text $PM hi; done"
denied "if (( 1 )) then herdr pane send-text $PM hi; fi"
denied "if (true) then herdr pane send-text $PM hi; fi"
denied "sudo env nohup herdr pane send-text $PM hi"
denied "! herdr pane send-text $PM hi"

SEND="herdr pane run $PM ls"
echo "send-guard-literal: real bash runs the send, so the guard must refuse"
denied "echo \">\"; $SEND"
denied "echo \">\"; herdr pane run >/dev/null $PM ls"
denied "cat <<E\"O\"F
body
EOF
$SEND"
denied "cat <<EOF
\$($SEND)
EOF"
denied "cat <<EOF
\`$SEND\`
EOF"
denied "echo \"\$(echo ')'; $SEND)\""
denied "echo \"\$(echo \")\"; $SEND)\""
denied "h\$\"\"erdr pane run $PM ls"
denied "((x << 2))
$SEND"
denied "echo \$[1<<2]
$SEND"
denied "echo \`echo \\\`$SEND\\\`\`"
denied "a=(x # don't
 y); $SEND 'z'"
denied "a[0]=1 $SEND"
denied "cat <<EOF | {bash,}
$SEND
EOF"

echo "send-guard-literal: real bash treats it as data, so the guard must allow"
allowed "cat <<'E O F'
$SEND
E O F"
allowed "cat <<A <<B
x
A
$SEND
B"
allowed "cat <<EOF
  EOF
$SEND
EOF"
allowed "echo } $SEND"
allowed "echo { $SEND"

echo "send-guard-literal: an unreadable record proves no membership"
row herdr default w7 pm-unread w7:p1 term_w7p1
RUN_UNREAD="$(programme herdr default w7 pm-unread)"
py "$RUN_UNREAD" <<PYEOF >/dev/null
$HEAD_PY
def mutate(rec):
    rec["programme"]["items"] = {"linear:U-1": {"id": "linear:U-1", "title": "owned", "state": "open",
                                                "owner": {"session_id": "sess-no-row-unread"}}}
rc._with_locked_run_record(ph.home_path(args[0]), args[0], mutate)
PYEOF
UNREAD_DB="${CLAUDE_AUTO_DATA_DIR}/programmes/${RUN_UNREAD}/programme.db"
it "with the record readable, the item proves a session with no registry row is in the programme"
check deny "$(verdict "$(hook sess-no-row-unread 'herdr pane run w7:p1 ls')")"
mv "$UNREAD_DB" "${UNREAD_DB}.saved"
printf 'not a database' > "$UNREAD_DB"
it "with the record unreadable, the same session is allowed"
check allow "$(verdict "$(hook sess-no-row-unread 'herdr pane run w7:p1 ls')")"
it "with the record unreadable, the driver's own session is still refused"
check deny "$(verdict "$(hook pm-unread 'herdr pane run w7:p1 ls')")"
mv "${UNREAD_DB}.saved" "$UNREAD_DB"

echo "send-guard-literal: who counts as one of the programme's own sessions"
SEND="herdr pane run $PM ls"
as() { it "$1: $3 from [$2]"; check "$1" "$(verdict "$(hook "$2" "$3")")"; }
as allow sess-outside "$SEND"
as allow sess-unregistered "$SEND"
as allow "" "$SEND"
as deny sess-far-owner "$SEND"
as deny sess-far-listed "$SEND"
# No registry row: only the item proves membership, and a bare suffix may still be the PM's pane.
as deny sess-no-row-item "$SEND"
as deny sess-no-row-item 'herdr pane run p9T ls'
as allow sess-far-done "$SEND"
as deny pm-mv "$SEND"
as deny pm-mv "bash -c '$SEND'"
as allow pm-mv 'herdr pane run w2:p77 ls'
as allow pm-mv 'herdr pane close w2:p77'
as allow pm-mv "herdr pane get $PM"
as allow pm-mv "echo $PM"
# Another programme's PM is outside this one, and its own space holds another run.
as allow pm-rex "$SEND"
as deny pm-rex 'rex send -b rex-blk-D1 hi'
as allow sess-worker 'rex send -b rex-blk-D1 hi'
as allow sess-worker 'osascript -e '\''input text "x" to terminal id "ghost-term-9"'\'''
OUT="$(hook sess-worker "$SEND")"
it "the refusal keeps the inbox route"
has "report through the programme's inbox" "$OUT"
it "the refusal no longer forbids naming the pane"
lacks "may not name it" "$OUT"
it "the refusal does not mention proof"
lacks "cannot prove" "$OUT"
it "the refusal is journaled with the verb and the target, with no cause"
ROW="$(py "$RUN_MV" <<PYEOF
$HEAD_PY
pj = load_lib_module("programme_journal")
r = [x for x in pj.read(args[0]) if x["kind"] == "blocked_driver_send"][-1]
print(r["session_id"], r["payload"]["verb"], r["payload"]["target"], "cause" in r["payload"])
PYEOF
)"
check "sess-worker pane run $PM False" "$ROW"

echo "send-guard-literal: the store is held during the membership read"
LOCKER_OUT="${WORK}/locker.out"
"$PY" - "${CLAUDE_AUTO_DATA_DIR}/programmes/${RUN_MV}/programme.db" > "$LOCKER_OUT" 2>&1 <<'EOF' &
import sqlite3, sys, time
conn = sqlite3.connect(sys.argv[1], isolation_level=None)
conn.execute("BEGIN EXCLUSIVE")
print("locked", flush=True)
time.sleep(60)
EOF
LOCKER_PID=$!
for _ in $(seq 1 100); do grep -q '^locked' "$LOCKER_OUT" && break; "$PY" -c 'import time; time.sleep(0.1)'; done
it "the store is locked"
has locked "$(cat "$LOCKER_OUT")"
timed() {
  local start end out
  start=$("$PY" -c 'import time; print(time.time())')
  out="$(hook "$1" "$SEND")"
  end=$("$PY" -c 'import time; print(time.time())')
  echo "$(verdict "$out") $("$PY" -c 'import sys; print("fast" if float(sys.argv[2]) - float(sys.argv[1]) < 3 else "slow")' "$start" "$end")"
}
it "the driver is refused"; check "deny fast" "$(timed pm-mv)"
it "a session in the leased space is refused"; check "deny fast" "$(timed sess-worker)"
it "a session only an item could prove is allowed"; check "allow fast" "$(timed sess-far-owner)"
kill "$LOCKER_PID" 2>/dev/null; wait "$LOCKER_PID" 2>/dev/null
it "with the store free again the same session is refused"
check deny "$(verdict "$(hook sess-far-owner "$SEND")")"

echo "send-guard-literal: malformed and very long input"
it "odd and hostile command text never raises, because a hook error fails open"
OUT="$(AUTO_TEST_HOST=stub "$PY" - "$AUTO_ROOT" <<'PYEOF' 2>&1
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
sg = load_lib_module("send_guard")
cmds = ["", " ", "herdr", "herdr agent", "herdr --session", "herdr --machine", "$", "$(", "`", "'", '"', ">", "< <", "<<", "<<<", "rex -b", "rex send -b", "rex --block=",
        "rex api call {", "osascript", "osascript -e", "osascript -l", "osascript -", "$H", "$H agent", "$H $H $H", "env", "env X=1", "exec", "x=1", "( herdr agent prompt",
        "herdr agent prompt )", "stubhost", "stubhost send", "bash -c", "eval", "a;b;c", "herdr agent prompt p1 p2 p3 " * 80, "$(" * 50, ")" * 50,
        "case", "case x in", "esac", ";;", "timeout", "timeout 5", "cat <<EOF", "cat <<'EOF' | bash\n", "$((" * 1500]
bad = []
for c in cmds:
    try:
        sg.host_sends(c, ["pane-x", "term-x"])
    except Exception as exc:
        bad.append((c[:20], type(exc).__name__))
print(bad)
PYEOF
)"
check "[]" "$OUT"
it "a thousand assignment prefixes do not hide the send"
check deny "$(verdict "$(hook sess-worker "$(printf 'a=1 %.0s' $(seq 1000))herdr pane run $PM ls")")"
fast() {
  local want="$1" text="$2" start elapsed v
  start=$(date +%s)
  v="$(verdict "$(hook sess-worker "$text")")"
  elapsed=$(( $(date +%s) - start ))
  check "$want fast" "$v $([ "$elapsed" -lt 5 ] && echo fast || echo "slow:${elapsed}s")"
}
it "twenty thousand assignment prefixes are judged well inside the hook's 10 s limit"
fast deny "$(printf 'a=1 %.0s' $(seq 20000))herdr pane run $PM ls"
it "twenty thousand precommand words are judged well inside the limit"
fast deny "$(printf 'if %.0s' $(seq 20000))herdr pane run $PM ls"
it "twenty thousand words after a shell are judged well inside the limit"
fast allow "bash herdr $(printf 'word %.0s' $(seq 20000))"
it "a long single-quoted payload is judged well inside the limit"
fast allow "python3 -c 'herdr $(printf 'a%.0s' $(seq 80000))'"
it "deeply nested arithmetic is judged, not met with a recursion error"
check deny "$(verdict "$(hook sess-worker "echo $(printf '$((%.0s' $(seq 1500))1$(printf '))%.0s' $(seq 1500)); herdr pane run $PM ls")")"

echo "send-guard-literal: a pane herdr cannot confirm stays guarded and says so"
cat > "$FAKE_HERDR_SNAPSHOT" <<'EOF'
{"result": {"snapshot": {
  "panes": [{"pane_id": "w2:p77", "terminal_id": "term_p77", "workspace_id": "w2", "tab_id": "w2:t1"}],
  "agents": [], "tabs": []}}}
EOF
OUT="$(hook sess-worker "herdr pane run $PM ls")"
it "a send to a driver pane herdr reports closed is still refused"
check deny "$(verdict "$OUT")"
it "the refusal says herdr does not know which pane the driver is in now"
has "does not say which pane the driver is in now" "$OUT"
it "naming that pane is not a send"
check allow "$(verdict "$(hook sess-worker "echo $PM")")"

echo "send-guard-literal: a moved herdr pane is guarded by its live id"
cat > "$FAKE_HERDR_SNAPSHOT" <<'EOF'
{"result": {"snapshot": {
  "panes": [{"pane_id": "w2:pAG", "terminal_id": "term_pAG", "workspace_id": "w2", "tab_id": "w2:t42"},
            {"pane_id": "w2:p77", "terminal_id": "term_p77", "workspace_id": "w2", "tab_id": "w2:t1"}],
  "agents": [{"pane_id": "w2:pAG", "agent_session": {"kind": "id", "value": "pm-mv"}}],
  "tabs": []}}}
EOF
OUT="$(hook sess-worker 'herdr pane send-text w2:pAG hi')"
it "a send to the PM's live pane is refused although another session once ran there"
check deny "$(verdict "$OUT")"
it "the refusal names the live pane"
has "w2:pAG" "$OUT"
denied 'herdr pane send-text w2:p9T hi'
denied 'herdr pane close w2:p9T'
denied 'herdr pane close w2:pAG'
denied 'herdr pane send-text term_pAG hi'
allowed 'herdr pane close w2:p77'
allowed 'herdr pane send-text w2:p77 hi'
it "the PM's own session may still send to a worker pane"
check allow "$(verdict "$(hook pm-mv 'herdr pane send-text w2:p77 hi')")"
it "the PM's own session may close a worker pane"
check allow "$(verdict "$(hook pm-mv 'herdr pane close w2:p77')")"
it "after one live sighting, a failed lookup still guards the live pane"
check deny "$(verdict "$(hook sess-worker 'herdr pane send-text w2:pAG hi' FAKE_HERDR_MODE=fail)")"
it "a malformed snapshot neither raises nor drops the guard"
check deny "$(verdict "$(hook sess-worker 'herdr pane send-text w2:pAG hi' FAKE_HERDR_MODE=junk)")"
it "a hanging herdr is cut off well inside the hook's budget"
START=$(date +%s)
V="$(verdict "$(hook sess-worker 'herdr pane send-text w2:pAG hi' FAKE_HERDR_MODE=hang)")"
ELAPSED=$(( $(date +%s) - START ))
check "deny fast" "$V $([ "$ELAPSED" -lt 4 ] && echo fast || echo "slow:${ELAPSED}s")"
it "a command with no host word never asks herdr, even when herdr hangs"
START=$(date +%s)
V="$(verdict "$(hook sess-worker 'ls -la' FAKE_HERDR_MODE=hang)")"
ELAPSED=$(( $(date +%s) - START ))
check "allow fast" "$V $([ "$ELAPSED" -lt 2 ] && echo fast || echo "slow:${ELAPSED}s")"

echo ""
echo "send-guard-literal.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
