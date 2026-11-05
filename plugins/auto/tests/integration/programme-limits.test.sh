#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
HOOK="${AUTO_ROOT}/.claude/hooks/on-pretooluse-action.sh"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
check() { if [ "$1" = "$2" ]; then pass; else fail "expected [$1] got [$2]"; fi; }
has() { case "$2" in *"$1"*) pass ;; *) fail "expected to find [$1] in [$2]" ;; esac; }

echo "programme-limits.test.sh"

WORK="$(mktemp -d -t auto-programme-limits.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# A leftover host variable would put the session in a host this test never set up.
for v in $(env | grep -oE '^(HERDR|REX|GHOSTTY|AUTO_TEST)_[A-Z_]*'); do unset "$v"; done
unset CLAUDE_CODE_SESSION_ID CMUX_WORKSPACE_ID TERM_PROGRAM CLAUDE_AUTO_REPO CLAUDE_CONFIG_DIR 2>/dev/null || true

export HOME="${WORK}/home"
export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_PLUGIN_ROOT="$AUTO_ROOT"
: > "$CLAUDE_AUTO_SECRETS_FILE"

NOREPO="${WORK}/norepo"
CACHE="${HOME}/.claude/plugins/cache/shrimpshack/auto/9.9.9"
CACHE_HOOK="${CACHE}/lib/on-pretooluse-action.py"
SETTINGS="${NOREPO}/.claude/settings.local.json"
mkdir -p "${NOREPO}/.claude" "${CACHE}/lib"
printf 'x\n' > "$CACHE_HOOK"

MARKER_PY="${WORK}/marker-python"
cat > "$MARKER_PY" <<EOF
#!/usr/bin/env bash
touch "${WORK}/python-ran"
exit 0
EOF
chmod +x "$MARKER_PY"

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
ph = load_lib_module("programme_home")
pj = load_lib_module("programme_journal")
args = sys.argv[2:]
$(cat)
PYEOF
}

RUN="$(run_py <<'EOF'
print(ph.create_programme(["w2"], "sess-pm")["run"])
EOF
)"

edit_run() {
  run_py "$RUN" "$1" <<'EOF' >/dev/null
core = load_lib_module("run_record_core")
def mutate(rec):
    exec(args[1], {"prog": rec["programme"], "rec": rec})
core._with_locked_run_record(ph.home_path(args[0]), args[0], mutate)
EOF
}

ON="{'state': 'on'}"
OFF="{'state': 'off'}"
edit_run "prog['items'] = {
  'linear:AI-1': {'id': 'linear:AI-1', 'state': 'open', 'owner': {'session_id': 'sess-lim'}, 'check_settings': {'no-destructive-commands': $ON}},
  'linear:AI-2': {'id': 'linear:AI-2', 'state': 'open', 'owner': {'session_id': 'sess-free'}},
  'linear:AI-3': {'id': 'linear:AI-3', 'state': 'open', 'owner': {'session_id': 'sess-first'}, 'sessions': [{'session_id': 'sess-takeover'}], 'check_settings': {'no-settings-writes': $ON}},
  'linear:AI-4': {'id': 'linear:AI-4', 'state': 'done', 'owner': {'session_id': 'sess-done'}, 'check_settings': {'no-destructive-commands': $ON}},
}"

PROGRAMMES="${CLAUDE_AUTO_DATA_DIR}/programmes"
HOME_FILE="$(run_py "$RUN" <<'EOF'
print(os.path.join(ph.home_path(args[0]), "record.json"))
EOF
)"

# Always through the shell hook: the shim's prefilter decides whether Python runs at all.
payload() {
  "$PY" -c 'import json,sys
d = {"session_id": sys.argv[1], "hook_event_name": "PreToolUse", "cwd": sys.argv[2], "tool_name": sys.argv[3], "tool_input": json.loads(sys.argv[4])}
if len(sys.argv) > 5: d["agent_id"] = sys.argv[5]
print(json.dumps(d))' "$@"
}
call() {
  local sid="$1" tool="$2" input="$3"; shift 3
  local raw
  raw="$(payload "$sid" "$NOREPO" "$tool" "$input" "$@")"
  ( cd "$NOREPO" && bash "$HOOK" <<< "$raw" )
}
verdict() {
  local out
  out="$(call "$@")"
  case "$out" in
    *'"permissionDecision": "deny"'*) printf 'deny' ;;
    "") printf 'allow' ;;
    *) printf 'other[%s]' "$out" ;;
  esac
}
bash_input() { "$PY" -c 'import json,sys; print(json.dumps({"command": sys.argv[1]}))' "$1"; }
sh_verdict() { verdict "$1" Bash "$(bash_input "$2")"; }

BLOCKED_BASH=(
  "echo x > ${HOME_FILE}"
  "printf x >>${HOME_FILE}"
  "rm -rf ${PROGRAMMES}"
  "sed -i '' s/a/b/ ${HOME_FILE}"
  "cp /tmp/a ${HOME_FILE}"
  "mv /tmp/a ${HOME_FILE}"
  "touch ${HOME_FILE}"
  "cat /tmp/a | tee ${HOME_FILE}"
  "dd if=/tmp/a of=${HOME_FILE}"
  "python3 -c \"open('${HOME_FILE}', 'w')\""
  "bash -c \"rm ${HOME_FILE}\""
  "sqlite3 ${PROGRAMMES}/${RUN}/programme.db 'delete from x'"
  "find ${PROGRAMMES} -delete"
  "find ${PROGRAMMES} -exec rm {} ;"
  "cat ${HOME_FILE} | xargs rm"
  "echo \"\$(rm ${HOME_FILE})\""
  "cat \`rm ${HOME_FILE}\`"
  "cd ${CLAUDE_AUTO_DATA_DIR} && rm programmes/x"
  "cd ${CLAUDE_AUTO_DATA_DIR} && rm pro\"\"grammes/x"
  "un\"\"set CLAUDE_AUTO_DA\"\"TA_DIR"
  "echo '{\"dis\"\"ableAllHooks\":true}' > .claude/settings.local.json"
  "cd ${HOME_FILE%/*} && rm record.json"
  "rm \$CLAUDE_AUTO_DATA_DIR/programmes/x"
  "rm \${CLAUDE_AUTO_DATA_DIR}/programmes/x"
  "export CLAUDE_AUTO_DATA_DIR=/tmp/other"
  "CLAUDE_AUTO_DATA_DIR=/tmp/other bash ${CACHE}/lib/programme.sh status"
  "env -u CLAUDE_AUTO_DATA_DIR bash x.sh"
  "unset CLAUDE_AUTO_DATA_DIR"
  "rm ${CACHE_HOOK}"
  "sed -i '' s/deny/allow/ ${CACHE_HOOK}"
  "cp /tmp/x ~/.claude/plugins/cache/shrimpshack/auto/9.9.9/lib/on-pretooluse-action.py"
  "cp /tmp/x \$HOME/.claude/plugins/cache/x"
  "cd ${HOME}/.claude/plugins && rm -rf cache"
  "D=${CACHE}/lib; rm \$D/x"
  "bash ${CACHE}/lib/programme.sh status > ${CACHE_HOOK}"
  "bash ${CACHE}/lib/programme.sh status --out ${CACHE_HOOK}"
  "rm \${CLAUDE_PLUGIN_ROOT}/lib/x"
  "echo '{\"disableAllHooks\": true}' > ${SETTINGS}"
  "echo '{\"allowManagedHooksOnly\": true}' > ${SETTINGS}"
  "echo '{\"disableAllHooks\": true}' > ~/.claude/settings.json"
  "jq '.disableAllHooks=true' ${SETTINGS} | sponge ${SETTINGS}"
  "python3 -c \"import json; json.dump({'disableAllHooks': True}, open('.claude/settings.local.json', 'w'))\""
  "cat > .claude/settings.local.json <<EOF
{\"disableAllHooks\": true}
EOF"
  "sed -Ei '' s/a/b/ ${HOME_FILE}"
  "sed -E -i.bak s/a/b/ ${HOME_FILE}"
  "sed -I '' s/a/b/ ${HOME_FILE}"
  "sed --in-place=.bak s/a/b/ ${HOME_FILE}"
  "sed -n 'w ${HOME_FILE}' /tmp/a"
  "sed 's/a/b/w ${HOME_FILE}' /tmp/a"
  "sed -e p -e 'W ${HOME_FILE}' /tmp/a"
  "sed -f /tmp/script ${HOME_FILE}"
  "sed 's/a/b/e' ${HOME_FILE}"
  "sort -uo ${HOME_FILE} /tmp/a"
  "sort -o ${HOME_FILE} /tmp/a"
  "sort --output=${HOME_FILE} /tmp/a"
  "tree -o ${HOME_FILE} /tmp"
  "less -o ${HOME_FILE} /tmp/a"
  "rg --pre rm x ${PROGRAMMES}"
  "export CLAUDE_CODE_SESSION_ID=sess-pm; bash ${CACHE}/lib/programme.sh set-check no-destructive-commands off --item linear:AI-1"
  "CLAUDE_CODE_SESSION_ID=sess-pm bash ${CACHE}/lib/programme.sh set-check no-destructive-commands off --item linear:AI-1"
  "env CLAUDE_CODE_SESSION_ID=sess-pm bash ${CACHE}/lib/programme.sh set-check no-destructive-commands off --item linear:AI-1"
  "bash ${CACHE}/lib/programme.sh set-check no-destructive-commands off --item linear:AI-1"
  "bash \${CLAUDE_PLUGIN_ROOT}/lib/programme.sh set-check no-destructive-commands off"
  "P=\"bash ${CACHE}/lib/programme.sh\"; \$P set-check no-destructive-commands off"
  "export CLAUDE_CODE_SESS\"\"ION_ID=sess-pm"
  "python3 -c \"import os; os.environ['CLAUDE_CODE_SESSION_ID'] = 'sess-pm'\""
)
it "a limited worker's Bash write to a protected target is refused, each form through the shell hook"
BAD=""
for c in "${BLOCKED_BASH[@]}"; do
  [ "$(sh_verdict sess-lim "$c")" = deny ] || BAD="${BAD}[${c}] "
done
check "" "$BAD"

it "an unlimited worker running the same commands is not refused"
BAD=""
for c in "${BLOCKED_BASH[@]}"; do
  [ "$(sh_verdict sess-free "$c")" = allow ] || BAD="${BAD}[${c}] "
done
check "" "$BAD"

FILE_CALLS=(
  "Edit|{\"file_path\": \"${HOME_FILE}\", \"old_string\": \"a\", \"new_string\": \"b\"}"
  "MultiEdit|{\"file_path\": \"${HOME_FILE}\", \"edits\": [{\"old_string\": \"a\", \"new_string\": \"b\"}]}"
  "Write|{\"file_path\": \"${HOME_FILE}\", \"content\": \"{}\"}"
  "Write|{\"file_path\": \"${PROGRAMMES}/new-file\", \"content\": \"{}\"}"
  "Edit|{\"file_path\": \"${CACHE_HOOK}\", \"old_string\": \"a\", \"new_string\": \"b\"}"
  "Write|{\"file_path\": \"${CACHE_HOOK}\", \"content\": \"x\"}"
  "MultiEdit|{\"file_path\": \"${CACHE_HOOK}\", \"edits\": []}"
  "Edit|{\"file_path\": \"${AUTO_ROOT}/lib/on-pretooluse-action.py\", \"old_string\": \"a\", \"new_string\": \"b\"}"
  "Write|{\"file_path\": \"${SETTINGS}\", \"content\": \"{\\\"disableAllHooks\\\": true}\"}"
  "Write|{\"file_path\": \"${SETTINGS}\", \"content\": \"{\\\"allowManagedHooksOnly\\\": true}\"}"
  "Write|{\"file_path\": \"${HOME}/.claude/settings.json\", \"content\": \"{\\\"disableAllHooks\\\": true}\"}"
  "Edit|{\"file_path\": \"${SETTINGS}\", \"old_string\": \"{\", \"new_string\": \"{\\\"disableAllHooks\\\": true,\"}"
  "MultiEdit|{\"file_path\": \"${SETTINGS}\", \"edits\": [{\"old_string\": \"a\", \"new_string\": \"b\"}, {\"old_string\": \"{\", \"new_string\": \"{\\\"disableAllHooks\\\": true,\"}]}"
)
it "a limited worker's Edit, MultiEdit and Write to a protected target are refused through the shell hook"
BAD=""
for entry in "${FILE_CALLS[@]}"; do
  [ "$(verdict sess-lim "${entry%%|*}" "${entry#*|}")" = deny ] || BAD="${BAD}[${entry}] "
done
check "" "$BAD"

it "an unlimited worker doing the same is not refused"
BAD=""
for entry in "${FILE_CALLS[@]}"; do
  [ "$(verdict sess-free "${entry%%|*}" "${entry#*|}")" = allow ] || BAD="${BAD}[${entry}] "
done
check "" "$BAD"

it "the PM, on no item, is not limited: its code route to the installed copy stays open"
check "allow allow" "$(verdict sess-pm Edit "{\"file_path\": \"${CACHE_HOOK}\", \"old_string\": \"a\", \"new_string\": \"b\"}") $(sh_verdict sess-pm "sed -i '' s/a/b/ ${CACHE_HOOK}")"

ALLOWED_BASH=(
  "cat ${HOME_FILE}"
  "ls -la ${PROGRAMMES}"
  "cat ${HOME_FILE} | grep open | head -3"
  "head -5 ${CACHE_HOOK}"
  "sed -n 1,5p ${CACHE_HOOK}"
  "grep -n deny ${CACHE_HOOK}"
  "find ${PROGRAMMES} -name record.json"
  "cat ${HOME_FILE} > /tmp/copy"
  "cat ${HOME_FILE} 2>/dev/null"
  "cd ${PROGRAMMES} && ls"
  "echo \$CLAUDE_AUTO_DATA_DIR"
  "cat \$CLAUDE_AUTO_DATA_DIR/programmes/x"
  "grep -rn CLAUDE_AUTO_DATA_DIR lib"
  "grep disableAllHooks ${SETTINGS}"
  "jq .disableAllHooks ${SETTINGS}"
  "bash ${CACHE}/lib/programme.sh status"
  "bash ${CACHE}/lib/programme.sh claim tests-pass && git push"
  "/usr/bin/python3 ${CACHE}/lib/programme.py status"
  "${CACHE}/lib/programme.sh status"
  "P=\"bash ${CACHE}/lib/programme.sh\"; \$P status; git status"
  "bash \${CLAUDE_PLUGIN_ROOT}/lib/programme.sh status"
  "grep -rn programmes lib"
  "git push"
  "npm test"
  "echo hello > /tmp/out"
  "echo disableAllHooks > notes.txt"
  "sed -e 1p ${HOME_FILE}"
  "sed -n '/open/p' ${HOME_FILE}"
  "sed -nE 's/a/b/gp' ${HOME_FILE}"
  "sed -n -e '/x/{p;q;}' ${HOME_FILE}"
  "sort -u ${HOME_FILE}"
  "sort -t, -k2 ${HOME_FILE}"
  "echo \$CLAUDE_CODE_SESSION_ID"
  "grep -rn CLAUDE_CODE_SESSION_ID lib"
  "grep -rn set-check ${CACHE}/lib"
  "bash ${CACHE}/lib/programme.sh offer limit-x --command 'set-check no-destructive-commands on --item linear:AI-1'"
)
it "a limited worker's reads and its runs of the plugin's own scripts are not refused"
BAD=""
for c in "${ALLOWED_BASH[@]}"; do
  [ "$(sh_verdict sess-lim "$c")" = allow ] || BAD="${BAD}[${c}] "
done
check "" "$BAD"

it "the Read tool on those files is not refused"
check "allow allow" "$(verdict sess-lim Read "{\"file_path\": \"${HOME_FILE}\"}") $(verdict sess-lim Read "{\"file_path\": \"${CACHE_HOOK}\"}")"

it "another settings key stays allowed for a limited worker, by Write, Edit and Bash"
A="$(verdict sess-lim Write "{\"file_path\": \"${SETTINGS}\", \"content\": \"{\\\"permissions\\\": {}}\"}")"
B="$(verdict sess-lim Edit "{\"file_path\": \"${SETTINGS}\", \"old_string\": \"a\", \"new_string\": \"\\\"model\\\": \\\"x\\\"\"}")"
C="$(sh_verdict sess-lim "echo '{\"model\": \"x\"}' > ${SETTINGS}")"
check "allow allow allow" "$A $B $C"

it "removing the hook key from a settings file is allowed: only a write that sets it is refused"
check "allow" "$(verdict sess-lim Edit "{\"file_path\": \"${SETTINGS}\", \"old_string\": \"\\\"disableAllHooks\\\": true,\", \"new_string\": \"\"}")"

it "the hook key in a file that is not a settings file is allowed"
check "allow" "$(verdict sess-lim Write "{\"file_path\": \"${NOREPO}/notes.md\", \"content\": \"disableAllHooks stops every hook\"}")"

it "R29: a takeover session attached to the item is limited"
check "deny deny" "$(verdict sess-takeover Edit "{\"file_path\": \"${HOME_FILE}\", \"old_string\": \"a\", \"new_string\": \"b\"}") $(sh_verdict sess-takeover "rm ${CACHE_HOOK}")"

it "R29: a sub-agent of a limited worker is limited"
check "deny" "$(verdict sess-lim Write "{\"file_path\": \"${HOME_FILE}\", \"content\": \"{}\"}" agent-1)"

it "the accepted gap: a launched session attached to no item is unlimited"
check "allow allow" "$(verdict sess-launched Edit "{\"file_path\": \"${HOME_FILE}\", \"old_string\": \"a\", \"new_string\": \"b\"}") $(sh_verdict sess-launched "rm ${CACHE_HOOK}")"

it "R29: the limit stops when the item finishes"
check "allow" "$(verdict sess-done Write "{\"file_path\": \"${HOME_FILE}\", \"content\": \"{}\"}")"

it "a refusal names the limit, its item and the route to lift it"
OUT="$(call sess-lim Edit "{\"file_path\": \"${CACHE_HOOK}\", \"old_string\": \"a\", \"new_string\": \"b\"}")"
has "no-destructive-commands" "$OUT"
has "linear:AI-1" "$OUT"
has "ask the PM" "$OUT"
has "set-check no-destructive-commands off" "$OUT"
has "$CACHE_HOOK" "$OUT"

it "an item's limit is lifted by the command the refusal gives: an item setting beats the programme setting"
has "set-check no-destructive-commands off --item linear:AI-1" "$OUT"

it "a refusal says what else a limited session cannot write"
has "the programme's files" "$OUT"
has "the installed plugin" "$OUT"
has "disableAllHooks" "$OUT"

last_limit_row() {
  run_py "$RUN" <<'EOF'
rows = [r for r in pj.read(args[0]) if r["kind"] == "limit_refused" and "limits" in r["payload"]]
print(json.dumps(rows[-1]["payload"], sort_keys=True) if rows else "none")
print(rows[-1]["session_id"] if rows and "session_id" in rows[-1] else "")
EOF
}
it "R28: a refusal journals one row naming the limit, the item and the path"
ROW="$(last_limit_row)"
has '"limits": ["no-destructive-commands"]' "$ROW"
has '"item": "linear:AI-1"' "$ROW"
has "\"path\": \"$("$PY" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$CACHE_HOOK")\"" "$ROW"
has '"tool": "Edit"' "$ROW"

it "a Bash refusal journals the command with secrets redacted"
printf 'export DEMO_TOKEN=hunter2secretvalue\n' > "$CLAUDE_AUTO_SECRETS_FILE"
sh_verdict sess-lim "rm ${CACHE_HOOK} hunter2secretvalue" >/dev/null
ROW="$(last_limit_row)"
has '"command"' "$ROW"
case "$ROW" in *hunter2secretvalue*) fail "secret in the row: $ROW" ;; *) pass ;; esac
: > "$CLAUDE_AUTO_SECRETS_FILE"

count_rows() {
  run_py "$RUN" "$1" <<'EOF'
print(sum(1 for r in pj.read(args[0]) if r["kind"] == args[1]))
EOF
}
it "R28: a refusal does not pause: the item and the loop are as they were and the next call still works"
BEFORE="$(run_py "$RUN" <<'EOF'
core = load_lib_module("run_record_core")
rec = core.read_run_record(ph.home_path(args[0]), args[0])
print(rec["programme"]["items"]["linear:AI-1"]["state"], json.dumps(rec.get("loop"), sort_keys=True))
EOF
)"
sh_verdict sess-lim "rm ${CACHE_HOOK}" >/dev/null
AFTER="$(run_py "$RUN" <<'EOF'
core = load_lib_module("run_record_core")
rec = core.read_run_record(ph.home_path(args[0]), args[0])
print(rec["programme"]["items"]["linear:AI-1"]["state"], json.dumps(rec.get("loop"), sort_keys=True))
EOF
)"
check "$BEFORE" "$AFTER"
check "allow" "$(sh_verdict sess-lim "git status")"

it "two guards refusing one call give one deny from the first in order, and a row from each in order"
N="$(count_rows limit_refused)"
OUT="$(call sess-lim Bash "$(bash_input "git reset --hard; rm ${HOME_FILE}")")"
has '"permissionDecision": "deny"' "$OUT"
case "$OUT" in *"${HOME_FILE}"*) fail "the protected-place guard answered first: $OUT" ;; *) pass ;; esac
check "destructive protected" "$(run_py "$RUN" "$N" <<'EOF'
rows = [r for r in pj.read(args[0]) if r["kind"] == "limit_refused"][int(args[1]):]
print(" ".join("protected" if "limits" in r["payload"] else "destructive" for r in rows))
EOF
)"

it "a read journals no row"
N="$(count_rows limit_refused)"
sh_verdict sess-lim "cat ${HOME_FILE}" >/dev/null
check "$N" "$(count_rows limit_refused)"

it "with two limits on, a refusal names both, since lifting one does not free the call"
edit_run "prog['items']['linear:AI-2']['check_settings'] = {'no-destructive-commands': $ON, 'no-settings-writes': $ON}"
OUT="$(sh_verdict sess-free "rm ${CACHE_HOOK}"; call sess-free Edit "{\"file_path\": \"${CACHE_HOOK}\", \"old_string\": \"a\", \"new_string\": \"b\"}")"
has "each must be lifted: no-destructive-commands, no-settings-writes" "$OUT"
has '"limits": ["no-destructive-commands", "no-settings-writes"]' "$(last_limit_row)"
edit_run "prog['items']['linear:AI-2']['check_settings'] = None"

it "a programme's limit is lifted for the one worker through its item, as the refusal says"
edit_run "prog['check_settings'] = {'no-destructive-commands': $ON}"
has "set-check no-destructive-commands off --item linear:AI-2" "$(call sess-free Edit "{\"file_path\": \"${CACHE_HOOK}\", \"old_string\": \"a\", \"new_string\": \"b\"}")"
edit_run "prog['check_settings'] = {}"

it "a limit turned on mid-run applies on the next call, and lifting it applies on the next call"
check "allow" "$(sh_verdict sess-free "rm ${CACHE_HOOK}")"
edit_run "prog['items']['linear:AI-2']['check_settings'] = {'no-settings-writes': $ON}"
check "deny" "$(sh_verdict sess-free "rm ${CACHE_HOOK}")"
edit_run "prog['items']['linear:AI-2']['check_settings'] = {'no-settings-writes': $OFF}"
check "allow" "$(sh_verdict sess-free "rm ${CACHE_HOOK}")"

it "a limit set on the programme binds every item's worker, and an item setting off frees that one worker"
edit_run "prog['check_settings'] = {'no-destructive-commands': $ON}; prog['items']['linear:AI-2']['check_settings'] = None"
check "deny" "$(sh_verdict sess-free "rm ${CACHE_HOOK}")"
edit_run "prog['items']['linear:AI-2']['check_settings'] = {'no-destructive-commands': $OFF}"
check "allow" "$(sh_verdict sess-free "rm ${CACHE_HOOK}")"
edit_run "prog['check_settings'] = {}; prog['items']['linear:AI-2']['check_settings'] = None"

it "status and the refusal name the same limit"
OUT="$(CLAUDE_CODE_SESSION_ID=sess-pm "$PY" "${AUTO_ROOT}/lib/programme.py" status --run "$RUN" 2>&1)"
has "no-destructive-commands" "$OUT"

# ---- the shim's prefilter ----

marker_call() {
  rm -f "${WORK}/python-ran"
  local raw
  raw="$(payload sess-lim "$NOREPO" "$1" "$2")"
  ( cd "$NOREPO" && CLAUDE_AUTO_PYTHON3="$MARKER_PY" bash "$HOOK" <<< "$raw" )
  [ -e "${WORK}/python-ran" ] && printf 'ran' || printf 'none'
}
it "an Edit or Write naming a protected target starts Python"
check "ran ran ran ran" "$(marker_call Edit "{\"file_path\": \"${HOME_FILE}\"}") $(marker_call MultiEdit "{\"file_path\": \"${CACHE_HOOK}\"}") $(marker_call Write "{\"file_path\": \"${HOME_FILE}\"}") $(marker_call Write "{\"file_path\": \"${SETTINGS}\", \"content\": \"disableAllHooks\"}")"

it "an Edit to the plugin root the hook runs from starts Python, whatever that path says"
check "ran" "$(marker_call Edit "{\"file_path\": \"${AUTO_ROOT}/lib/x.py\"}")"

it "an ordinary Edit, MultiEdit or Write starts no Python"
check "none none none" "$(marker_call Edit "{\"file_path\": \"${NOREPO}/a.txt\"}") $(marker_call MultiEdit "{\"file_path\": \"${NOREPO}/a.txt\"}") $(marker_call Write "{\"file_path\": \"${NOREPO}/a.txt\"}")"

cwd_marker_call() {
  rm -f "${WORK}/python-ran"
  local raw
  raw="$(payload sess-lim "$1" "$2" "$3")"
  ( cd "$NOREPO" && CLAUDE_AUTO_PYTHON3="$MARKER_PY" bash "$HOOK" <<< "$raw" )
  [ -e "${WORK}/python-ran" ] && printf 'ran' || printf 'none'
}
it "a Bash call naming CLAUDE_CODE_SESSION_ID or set-check starts Python"
check "ran ran ran" "$(marker_call Bash "{\"command\": \"export CLAUDE_CODE_SESSION_ID=x\"}") $(marker_call Bash "{\"command\": \"export CLAUDE_CODE_SESS\\\"\\\"ION_ID=x\"}") $(marker_call Bash "{\"command\": \"\$P set-check a off\"}")"

it "a Read, an ordinary Edit or an ordinary Bash with cwd inside the plugin root starts no Python"
check "none none none" "$(cwd_marker_call "$AUTO_ROOT" Read "{\"file_path\": \"${NOREPO}/a.txt\"}") $(cwd_marker_call "$AUTO_ROOT" Edit "{\"file_path\": \"${NOREPO}/a.txt\"}") $(cwd_marker_call "$AUTO_ROOT" Bash "{\"command\": \"git status\"}")"

it "the same calls with cwd inside the programme folder or the plugin cache start no Python"
check "none none" "$(cwd_marker_call "$PROGRAMMES" Edit "{\"file_path\": \"${NOREPO}/a.txt\"}") $(cwd_marker_call "$CACHE" Read "{\"file_path\": \"${NOREPO}/a.txt\"}")"

it "a transcript path inside the plugin root starts no Python"
rm -f "${WORK}/python-ran"
RAW="$("$PY" -c 'import json,sys; print(json.dumps({"session_id": "sess-lim", "transcript_path": sys.argv[1], "cwd": sys.argv[2], "tool_name": "Read", "tool_input": {"file_path": "a.txt"}}))' "${AUTO_ROOT}/t.jsonl" "$NOREPO")"
( cd "$NOREPO" && CLAUDE_AUTO_PYTHON3="$MARKER_PY" bash "$HOOK" <<< "$RAW" )
check "none" "$([ -e "${WORK}/python-ran" ] && printf ran || printf none)"

it "with cwd inside the plugin root, a call whose input names a protected target still starts Python"
check "ran ran ran" "$(cwd_marker_call "$AUTO_ROOT" Edit "{\"file_path\": \"${AUTO_ROOT}/lib/x.py\"}") $(cwd_marker_call "$AUTO_ROOT" Write "{\"file_path\": \"${HOME_FILE}\"}") $(cwd_marker_call "$AUTO_ROOT" Bash "{\"command\": \"rm ${CACHE_HOOK}\"}")"

it "a settings or behaviours name anywhere in the payload still starts Python, for their guards"
check "ran ran" "$(cwd_marker_call "${NOREPO}/.claude/settings.local.json" Read "{\"file_path\": \"a.txt\"}") $(cwd_marker_call "${NOREPO}/behaviours" Read "{\"file_path\": \"a.txt\"}")"

it "macOS's bash 3.2 reads a large payload with no tool_input key inside the hook's time limit"
BIG="${WORK}/big-payload.json"
"$PY" -c 'import json; print(json.dumps({"session_id": "sess-lim", "tool_name": "Write", "other": {"content": "x" * 200000}}))' > "$BIG"
START="$("$PY" -c 'import time; print(time.time())')"
( cd "$NOREPO" && CLAUDE_AUTO_PYTHON3="$MARKER_PY" /bin/bash "$HOOK" < "$BIG" ) >/dev/null
check "True" "$("$PY" -c "import time; print(time.time() - $START < 5)")"

it "a limited session in a protected folder running a call that names nothing is not refused"
cwd_verdict() {
  local raw out
  raw="$(payload sess-lim "$1" "$2" "$3")"
  out="$( cd "$NOREPO" && bash "$HOOK" <<< "$raw" )"
  [ -z "$out" ] && printf 'allow' || printf 'deny'
}
check "allow allow" "$(cwd_verdict "${HOME_FILE%/*}" Bash "{\"command\": \"rm record.json\"}") $(cwd_verdict "${HOME_FILE%/*}" Edit "{\"file_path\": \"record.json\", \"old_string\": \"a\", \"new_string\": \"b\"}")"

# ---- settings that cannot be read ----

it "R30: with the record unreadable each check uses its default, so a limit refuses nothing and nothing hangs"
run_py "$RUN" <<'EOF' >/dev/null
print(load_lib_module("programme_import").promote(args[0])["status"])
EOF
check "deny" "$(sh_verdict sess-lim "rm ${CACHE_HOOK}")"
DB="$(run_py "$RUN" <<'EOF'
print(os.path.join(ph.home_path(args[0]), "programme.db"))
EOF
)"
LOCK_OUT="${WORK}/locker.out"
"$PY" - "$DB" "$WORK/locker.stop" > "$LOCK_OUT" 2>&1 <<'EOF' &
import os, sqlite3, sys, time
conn = sqlite3.connect(sys.argv[1], isolation_level=None)
conn.execute("BEGIN EXCLUSIVE")
print("locked", flush=True)
for _ in range(600):
    if os.path.exists(sys.argv[2]):
        break
    time.sleep(0.05)
conn.execute("ROLLBACK")
EOF
LOCKER=$!
for _ in $(seq 1 100); do grep -q locked "$LOCK_OUT" 2>/dev/null && break; sleep 0.05; done
START="$("$PY" -c 'import time; print(time.time())')"
V="$(sh_verdict sess-lim "rm ${CACHE_HOOK}")"
ELAPSED="$("$PY" -c "import time; print(time.time() - $START < 3)")"
touch "${WORK}/locker.stop"
wait "$LOCKER" 2>/dev/null
check "locked allow True" "$(head -1 "$LOCK_OUT") $V $ELAPSED"

it "R30: the failure to read is journaled once the store is free"
sh_verdict sess-lim "rm ${CACHE_HOOK}" >/dev/null
check "1" "$(count_rows checks_unreadable)"

echo ""
echo "programme-limits.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
