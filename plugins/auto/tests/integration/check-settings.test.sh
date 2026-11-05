#!/usr/bin/env bash
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

echo "check-settings.test.sh"

WORK="$(mktemp -d -t auto-check-settings.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

for v in $(env | grep -oE '^(HERDR|REX|GHOSTTY|AUTO_TEST)_[A-Z_]*'); do unset "$v"; done
unset CLAUDE_CODE_SESSION_ID CMUX_WORKSPACE_ID TERM_PROGRAM CLAUDE_AUTO_REPO 2>/dev/null || true

FAKEBIN="${WORK}/bin"
mkdir -p "$FAKEBIN"
cat > "${FAKEBIN}/herdr" <<'EOF'
#!/usr/bin/env bash
if [ "$1 $2" = "pane get" ]; then
  pane="${FAKE_HERDR_PANE:-$3}"
  printf '{"id":"cli:pane:get","result":{"pane":{"pane_id":"%s","workspace_id":"%s","terminal_id":"term_%s","tab_id":"w2:t1"}},"type":"pane_info"}\n' \
    "$pane" "${pane%%:*}" "${pane##*:}"
fi
exit 0
EOF
chmod +x "${FAKEBIN}/herdr"
export PATH="${FAKEBIN}:${PATH}"

MARKER_PY="${WORK}/marker-python"
printf '#!/usr/bin/env bash\ntouch "%s/python-ran"\nexit 0\n' "$WORK" > "$MARKER_PY"
chmod +x "$MARKER_PY"

export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_BEHAVIOURS_DIR="${WORK}/personal/behaviours"
export CLAUDE_AUTO_BEHAVIOURS_STORE="${WORK}/personal/behaviours.json"
: > "$CLAUDE_AUTO_SECRETS_FILE"
mkdir -p "$CLAUDE_AUTO_BEHAVIOURS_DIR"
NOREPO="${WORK}/norepo"
REPO="${WORK}/repo"
DEST="${WORK}/dest"
mkdir -p "$NOREPO" "${REPO}/.claude/auto" "${DEST}/.claude"

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
ph = load_lib_module("programme_home")
pj = load_lib_module("programme_journal")
core = load_lib_module("run_record_core")
args = sys.argv[2:]
$(cat)
PYEOF
}

edit_run() {
  run_py "$RUN" "$1" <<'EOF' >/dev/null
def mutate(rec):
    exec(args[1], {"prog": rec["programme"], "rec": rec})
core._with_locked_run_record(ph.home_path(args[0]), args[0], mutate)
EOF
}

# clear every setting, on the programme and on each item
clear_settings() {
  edit_run "prog['check_settings'] = {}
for i in prog['items'].values(): i.pop('check_settings', None)"
}
set_programme() { edit_run "prog['check_settings'] = {'$1': {'state': '$2'}}"; }
set_item() { edit_run "prog['check_settings'] = {}; prog['items']['linear:AI-1']['check_settings'] = {'$1': {'state': '$2'}}"; }

payload() {
  "$PY" -c 'import json, sys
print(json.dumps({"session_id": sys.argv[1], "cwd": sys.argv[3], "hook_event_name": "PreToolUse", "tool_name": sys.argv[2],
                  "tool_input": json.loads(sys.argv[4]), **json.loads(sys.argv[5] or "{}")}))' "$1" "$2" "$3" "$4" "${5:-}"
}

# Always through the shell hook, from a folder with no .claude/auto: the shim decides what reaches Python.
tool_hook() { ( cd "$NOREPO" && bash "${HOOKS}/on-pretooluse-action.sh" <<< "$(payload "$1" "$2" "$NOREPO" "$3")" ); }
bash_hook() {
  tool_hook "$1" Bash "$("$PY" -c 'import json, sys; print(json.dumps({"command": sys.argv[1]}))' "$2")"
}
reaches_python() {
  rm -f "${WORK}/python-ran"
  ( cd "$NOREPO" && CLAUDE_AUTO_PYTHON3="$MARKER_PY" bash "${HOOKS}/on-pretooluse-action.sh" \
      <<< "$(payload "$1" Bash "$NOREPO" "$("$PY" -c 'import json, sys; print(json.dumps({"command": sys.argv[1]}))' "$2")")" )
  [ -e "${WORK}/python-ran" ] && echo ran || echo none
}
verdict() {
  case "$1" in
    "") echo allow ;;
    *'"deny"'*) echo deny ;;
    *'"block"'*) echo block ;;
    *) echo "other:$1" ;;
  esac
}
limit_rows() {
  run_py "$RUN" "$1" <<'EOF'
rows = [r for r in pj.read(args[0]) if r["kind"] == "limit_refused"]
print(json.dumps(eval(args[1], {"rows": rows, "os": os})))
EOF
}
session_start() {
  ( cd "$NOREPO" && HERDR_ENV=1 HERDR_PANE_ID="$2" HERDR_WORKSPACE_ID="${2%%:*}" FAKE_HERDR_PANE="$2" CLAUDE_CODE_ENTRYPOINT=cli \
    bash "${HOOKS}/on-session-start.sh" <<< "{\"session_id\":\"$1\",\"source\":\"startup\",\"cwd\":\"$NOREPO\"}" ) >/dev/null
}
plant_task() {
  "$PY" - "$REPO" "$1" "$2" <<'EOF'
import json, os, sys
repo, run, sid = sys.argv[1:4]
json.dump({"run_id": run, "loop_phase": "work", "driving_session_id": sid,
           "loop": {"driver": "self", "last_beat_at": "2099-01-01T00:00:00Z"},
           "exit_predicate_result": {"met": False, "blockers": 0, "majors": 0, "all_steps_terminal": False}},
          open(os.path.join(repo, ".claude", "auto", run + ".json"), "w"))
EOF
}
task_driver() {
  "$PY" -c 'import json, sys; print(json.load(open(sys.argv[1]))["loop"]["driver"])' "${REPO}/.claude/auto/$1.json"
}
ask_hook() {
  local input="${3:-}"
  [ -n "$input" ] || input='{"questions":[]}'
  ( cd "$2" && bash "${HOOKS}/on-pretooluse-askuser.sh" <<< "$(payload "$1" AskUserQuestion "$2" "$input")" )
}
stop_hook() {
  # The hook remembers a block it has shown; a fresh signature shows each case its own block.
  find "${CLAUDE_AUTO_DATA_DIR}/programmes" -name "$(run_py "$RUN" <<'EOF'
print(os.path.basename(ph.stop_shown_path(args[0], "sess-pm")).replace("sess-pm", "*"))
EOF
)" -delete 2>/dev/null
  ( cd "$2" && bash "${HOOKS}/on-stop.sh" <<< "{\"session_id\":\"$1\",\"stop_hook_active\":false}" 2>/dev/null )
}
subagent_hook() {
  ( cd "$NOREPO" && bash "${HOOKS}/on-pretooluse-subagent.sh" \
      <<< "$(payload "$1" Bash "$NOREPO" "$("$PY" -c 'import json, sys; print(json.dumps({"command": sys.argv[1]}))' "$2")" '{"agent_id":"a1","agent_type":"general-purpose"}')" )
}

session_start sess-pm w2:p31
session_start sess-peer w2:p40
RUN="$(run_py <<'EOF'
print(ph.create_programme(["w2"], "sess-pm")["run"])
EOF
)"
edit_run "prog['agreement']['accepted'] = {'at': '2026-11-01T00:00:00Z', 'prompt_id': 'p000001'}
prog['remit'] = {'tracker': {'teams': [{'key': 'AI', 'name': 'AI'}]}}
prog['permission_proposals'] = []
prog['items'] = {
  'linear:AI-1': {'id': 'linear:AI-1', 'title': 'a', 'state': 'open', 'history': [],
                  'owner': {'session_id': 'sess-worker', 'pane': 'w2:p5'},
                  'sessions': [{'session_id': 'sess-takeover'}],
                  'auto_run': {'state': 'bound', 'run_id': 'task-bound', 'path': '$REPO', 'contract': None}},
  'linear:AI-2': {'id': 'linear:AI-2', 'title': 'b', 'state': 'open', 'history': [],
                  'owner': {'session_id': 'sess-free', 'pane': 'w2:p6'}},
  'linear:AI-3': {'id': 'linear:AI-3', 'title': 'c', 'state': 'waiting', 'history': [],
                  'owner': {'session_id': 'sess-wait', 'pane': 'w2:p7'},
                  'waiting_on': {'who': 'team-x', 'watcher': None, 'reporter': None}, 'matched_rule': 'r1'}}"
plant_task task-bound sess-worker
plant_task task-solo sess-solo

LIMIT="no-destructive-commands"
WRITES="no-settings-writes"
SETTINGS="${DEST}/.claude/settings.local.json"
SETTINGS_WRITE="{\"file_path\": \"${SETTINGS}\", \"content\": \"{}\"}"

# ── every check, on and off ──────────────────────────────────────────────────
# What one call does under the current settings. A new check with no case here fails the matrix.
exercise() {
  case "$1" in
    no-destructive-commands) verdict "$(bash_hook sess-worker 'rm -rf build/')" ;;
    no-settings-writes) verdict "$(tool_hook sess-worker Write "$SETTINGS_WRITE")" ;;
    pm-settings-writes)
      edit_run "prog['permission_proposals'] = [{'id': 'pp1', 'state': 'open', 'destination': '$DEST'}]"
      verdict "$(tool_hook sess-pm Write "$SETTINGS_WRITE")"
      edit_run "prog['permission_proposals'] = []" ;;
    literal-send) verdict "$(bash_hook sess-worker 'herdr agent prompt w2:p31 go')" ;;
    tracker-outside-remit) verdict "$(tool_hook sess-pm mcp__linear__save_issue '{"team":"WEB","title":"x"}')" ;;
    advisor-redirect) verdict "$(ask_hook sess-worker "$REPO")" ;;
    subagent-refusals) verdict "$(subagent_hook sess-pm "bash programme.sh drop-item x")" ;;
    stop-block) verdict "$(stop_hook sess-pm "$NOREPO")" ;;
    tracker-proof) verdict "$(tool_hook sess-pm mcp__linear__save_issue '{"id":"AI-753","state":"Done"}')" ;;
    prefilled-answers) verdict "$(ask_hook sess-pm "$NOREPO" '{"questions":[],"answers":{"a":"b"}}')" ;;
    *) echo "no case" ;;
  esac
}
expected_on() { case "$1" in stop-block) echo block ;; *) echo deny ;; esac; }
expected_off() { case "$1" in tracker-proof|prefilled-answers) echo deny ;; *) echo allow ;; esac; }

NAMES="$(run_py <<'EOF'
print(" ".join(load_lib_module("programme_checks").CHECKS))
EOF
)"
for name in $NAMES; do
  it "matrix: $name set on for the programme"
  set_programme "$name" on
  check "$(expected_on "$name")" "$(exercise "$name")"
  it "matrix: $name set off for the programme"
  set_programme "$name" off
  check "$(expected_off "$name")" "$(exercise "$name")"
done
clear_settings

for name in no-destructive-commands no-settings-writes literal-send advisor-redirect; do
  it "matrix: $name set on for item AI-1 alone"
  set_item "$name" on
  check "$(expected_on "$name")" "$(exercise "$name")"
  it "matrix: $name set off for item AI-1 alone"
  set_item "$name" off
  check "$(expected_off "$name")" "$(exercise "$name")"
done
clear_settings

it "the defaults: both limits off, every other check on"
OUT=""
for name in $NAMES; do OUT="$OUT $name=$(exercise "$name")"; done
check " no-destructive-commands=allow no-settings-writes=allow pm-settings-writes=deny literal-send=deny tracker-outside-remit=deny advisor-redirect=deny subagent-refusals=deny stop-block=block tracker-proof=deny prefilled-answers=deny" "$OUT"

# ── no-destructive-commands: refuses, journals, no pause ─────────────────────
set_programme "$LIMIT" on

it "a limited worker with no task run: rm -rf ~/x is refused through the shell hook"
OUT="$(bash_hook sess-free 'rm -rf ~/x')"
check "deny" "$(verdict "$OUT")"
it "the refusal names the limit"
has "$LIMIT" "$OUT"
it "the refusal says who can lift it"
has "set-check $LIMIT off" "$OUT"
it "the refusal is journaled once, with the limit, the item and the command"
check '[["no-destructive-commands", "linear:AI-2", "Bash", "rm -rf ~/x"]]' \
  "$(limit_rows '[[r["payload"]["check"], r["payload"]["item"], r["payload"]["tool"], r["payload"]["command"]] for r in rows if r["session_id"] == "sess-free"]')"
it "the row names the session that was refused"
check '["sess-free"]' "$(limit_rows '[r["session_id"] for r in rows[-1:]]')"

it "a secret in a refused command does not reach the journal"
printf 'export DEMO_TOKEN=hunter2secretvalue\n' > "$CLAUDE_AUTO_SECRETS_FILE"
bash_hook sess-free 'rm -rf hunter2secretvalue' >/dev/null
case "$(limit_rows '[r["payload"]["command"] for r in rows]')" in
  *hunter2secretvalue*) fail "the secret reached the journal" ;;
  *) pass ;;
esac
: > "$CLAUDE_AUTO_SECRETS_FILE"

it "a limited worker with a task run: refused and the run keeps going"
OUT="$(bash_hook sess-worker 'git push --force origin main')"
check "deny self" "$(verdict "$OUT") $(task_driver task-bound)"
it "the refusal writes nothing to the task run's audit"
check "0" "$("$PY" -c 'import json, sys; print(len(json.load(open(sys.argv[1])).get("advisor_audit") or []))' "${REPO}/.claude/auto/task-bound.json")"
it "the next destructive call is refused too: a limit stays armed"
check "deny" "$(verdict "$(bash_hook sess-worker 'git reset --hard HEAD~1')")"
it "an attached takeover session is limited"
check "deny" "$(verdict "$(bash_hook sess-takeover 'rm -rf build/')")"
it "a sub-agent of a limited worker carries the limit"
check "deny" "$(verdict "$( ( cd "$NOREPO" && bash "${HOOKS}/on-pretooluse-action.sh" <<< "$(payload sess-worker Bash "$NOREPO" '{"command":"rm -rf build/"}' '{"agent_id":"a1","agent_type":"general-purpose"}')" ) )")"
it "a limited worker's ordinary command is allowed"
check "allow" "$(verdict "$(bash_hook sess-free 'git status')")"
it "the PM with no item is not limited by a limit on the programme"
check "allow" "$(verdict "$(bash_hook sess-pm 'rm -rf build/')")"
it "a session outside the programme is not limited"
check "allow" "$(verdict "$(bash_hook sess-stranger 'rm -rf build/')")"
it "a Write whose content quotes rm -rf is allowed: only a command is read"
PLAN_WRITE="{\"file_path\": \"${WORK}/plan.md\", \"content\": \"never rm -rf /\"}"
check "allow" "$(verdict "$(tool_hook sess-free Write "$PLAN_WRITE")")"

it "a limit added mid-run applies on the next call"
clear_settings
A="$(verdict "$(bash_hook sess-worker 'rm -rf build/')")"
set_item "$LIMIT" on
B="$(verdict "$(bash_hook sess-worker 'rm -rf build/')")"
check "allow deny" "$A $B"
it "a limit on one item leaves another item's worker free"
check "allow" "$(verdict "$(bash_hook sess-free 'rm -rf build/')")"
it "a limit stops when its item finishes"
edit_run "prog['items']['linear:AI-1']['state'] = 'done'"
check "allow" "$(verdict "$(bash_hook sess-worker 'rm -rf build/')")"
edit_run "prog['items']['linear:AI-1']['state'] = 'open'"

it "no environment variable opens the check: the old hatch does nothing for an unlimited worker"
clear_settings
OUT="$(CLAUDE_AUTO_TEST_HARNESS=1 CLAUDE_AUTO_TEST_DESTRUCTIVE_CHECK=1 bash_hook sess-free 'rm -rf build/')"
check "" "$OUT"
it "no environment variable closes the check: a limited worker stays limited"
set_programme "$LIMIT" on
OUT="$(CLAUDE_AUTO_TEST_HARNESS=1 CLAUDE_AUTO_CHECKS=off bash_hook sess-free 'rm -rf build/')"
check "deny" "$(verdict "$OUT")"

it "the test hatch and the pause path are gone from the hook"
OUT="$(grep -nE 'test_hatch|_pause_run|apply_pause|_audit_action|_owns_session|DESTRUCTIVE_CHECK|DENY_UNSUPPORTED' "${AUTO_ROOT}/lib/on-pretooluse-action.py")"
check "" "$OUT"

# ── the pattern list and rm path-scoping, under the limit ────────────────────
for cmd in \
  'git push --force origin main' 'git push origin main --force' 'git push origin main -f' \
  'git push origin main --force-with-lease' 'rm -rf build/' 'rm -fr build/' 'git reset --hard HEAD~1' \
  'git branch -D feature/x' 'git checkout -- .' 'git restore -- .' 'git clean -fdx' 'npm publish' \
  'gh release create v1' 'gh repo delete owner/repo --yes' 'gh release delete v1.0 --yes' \
  'gh pr merge 42 --admin --squash'; do
  it "limit: '$cmd' is refused"
  check "deny" "$(verdict "$(bash_hook sess-worker "$cmd")")"
done

for benign in 'git status' 'git push origin my-feature' 'git push origin bugfix/foo' 'git push -u origin main' \
  'gh pr merge 42 --squash' 'git checkout -- file.py' 'git checkout main' 'ls -la'; do
  it "limit: '$benign' is allowed"
  check "allow" "$(verdict "$(bash_hook sess-worker "$benign")")"
done

for eph in 'rm -rf /tmp/auto-test.XXXX' 'rm -rf /private/tmp/auto.XXXX' 'rm -rf /var/folders/xx/yy/T/auto.XXXX' \
  'rm -rf /private/var/folders/xx/yy/T/auto.XXXX' 'rm -fr /tmp/scratch' 'rm -rf -- /tmp/a /tmp/b' 'rm -rf /tmp/x'; do
  it "limit: temp teardown '$eph' is allowed"
  check "allow" "$(verdict "$(bash_hook sess-worker "$eph")")"
done

PINNED_TMPDIR="/private/var/folders/zz/T"
for eph in 'rm -rf $TMPDIR/scratch' 'rm -rf "$TMPDIR/scratch"' 'rm -rf ${TMPDIR}/scratch'; do
  it "limit: '$eph' with TMPDIR set is allowed"
  check "allow" "$(verdict "$(TMPDIR="$PINNED_TMPDIR" bash_hook sess-worker "$eph")")"
done

for danger in 'rm -rf /tmp' 'rm -rf /tmp/' 'rm -rf /var/folders/' 'rm -rf "$HOME/important"' 'rm -rf ../sibling' \
  'rm -rf /tmp/../etc' 'rm -rf src /tmp/ok' 'rm -rf /tmp/*' 'rm -rf /tmp/{a,b}' 'rm -rf /tmp/$VAR' \
  'rm -rf "/tmp/$(echo ..)/etc"' 'rm -rf $TMPDIR/' 'rm -rf $TMPDIR/../x'; do
  it "limit: '$danger' is refused"
  check "deny" "$(verdict "$(TMPDIR="$PINNED_TMPDIR" bash_hook sess-worker "$danger")")"
done

it "limit: rm -rf \$TMPDIR/x with TMPDIR unset is refused"
check "deny" "$(verdict "$(env -u TMPDIR bash -c '
  cd "$1" && bash "$2/on-pretooluse-action.sh" <<< "$3"' _ "$NOREPO" "$HOOKS" \
  "$(payload sess-worker Bash "$NOREPO" '{"command":"rm -rf $TMPDIR/x"}')")")"
clear_settings

# ── the shim: only a lease and text that could match start Python ────────────
for ordinary in 'ls -la' 'git status' 'npm test' 'echo hello' 'git log --oneline' 'cat README.md' 'git push origin main' 'gh pr view 3'; do
  it "shim: '$ordinary' starts no Python, with a lease held"
  check "none" "$(reaches_python sess-worker "$ordinary")"
done

DESTRUCTIVE_SAMPLES=('git push --force' 'git reset --hard' 'git checkout .' 'git restore .' 'git clean -f' 'git branch -D x'
  'rm -rf x' 'rm -fr x' 'npm publish' 'gh release create v1' 'gh repo delete o/r' 'gh release delete v1' 'gh pr merge 1 --admin')
it "shim: the samples below cover every destructive pattern, so a new pattern fails here until it is added"
OUT="$(run_py "${DESTRUCTIVE_SAMPLES[@]}" <<'EOF'
action = load_lib_module("on-pretooluse-action")
print(sorted({label for label, _ in action._DESTRUCTIVE_PATTERNS} - {action._matched_destructive(s) for s in args}))
EOF
)"
check "[]" "$OUT"
for cmd in "${DESTRUCTIVE_SAMPLES[@]}"; do
  it "shim: destructive '$cmd' reaches Python"
  check "ran" "$(reaches_python sess-worker "$cmd")"
  it "shim: destructive '$cmd' split by a tab and a newline reaches Python"
  spaced="${cmd// /$'\t'}"
  check "ran" "$(reaches_python sess-worker "ls
$spaced")"
done

it "shim: the hosts below cover every host's binary, so a new host fails here until the shim names it"
OUT="$(AUTO_TEST_HOST=stub run_py <<'EOF'
send_guard = load_lib_module("send_guard")
print(sorted(b for host in send_guard._hosts() for b in host.binaries))
EOF
)"
check "['herdr', 'osascript', 'rex', 'stubhost']" "$OUT"

for binary in herdr rex osascript stubhost HERDR; do
  it "shim: a command naming $binary reaches Python"
  check "ran" "$(reaches_python sess-worker "$binary something")"
done

for hidden in 'her"dr" agent prompt w2:p31 go' "her'dr' agent prompt w2:p31 go" 'he\rdr agent prompt w2:p31 go' \
  'h$""erdr agent prompt w2:p31 go' \
  "\$'\\x68erdr' agent prompt w2:p31 go" "\$'herdr' agent prompt w2:p31 go" \
  "her\\
dr agent prompt w2:p31 go"; do
  it "shim: a host name hidden as [$hidden] reaches Python"
  check "ran" "$(reaches_python sess-worker "$hidden")"
done

it "shim: a command over the text bound reaches Python without a text test"
LONG="$(printf 'x%.0s' $(seq 1 1600))"
check "ran" "$(reaches_python sess-worker "$LONG")"
it "shim: a command naming settings.local.json reaches Python"
check "ran" "$(reaches_python sess-worker "cat .claude/settings.local.json")"
it "shim: a command or a Write naming settings.json reaches Python, the name hidden or not"
rm -f "${WORK}/python-ran"
( cd "$NOREPO" && CLAUDE_AUTO_PYTHON3="$MARKER_PY" bash "${HOOKS}/on-pretooluse-action.sh" \
  <<< "$(payload sess-worker Write "$NOREPO" "{\"file_path\": \"${DEST}/.claude/settings.json\"}")" )
A="$([ -e "${WORK}/python-ran" ] && echo ran || echo none)"
check "ran ran ran" "$A $(reaches_python sess-worker "cat .claude/settings.json") $(reaches_python sess-worker "cat .claude/sett''ings.json")"
it "shim: the protected words match programme_limits, so a word added to one fails here until the other has it"
SHIM_WORDS="$(sed -n "s/^__cd_protected='\(.*\)'$/\1/p" "${HOOKS}/on-pretooluse-action.sh" | tr '|' '\n' | LC_ALL=C sort | tr '\n' ' ')"
check "$SHIM_WORDS" "$(run_py <<'EOF'
print(" ".join(sorted(w.casefold() for w in load_lib_module("programme_limits").NAMED_WORDS)) + " ")
EOF
)"
it "shim: a command naming behaviours reaches Python"
check "ran" "$(reaches_python sess-worker "ls behaviours")"

it "shim: a Linear call whose text says Bash still reaches Python"
rm -f "${WORK}/python-ran"
( cd "$NOREPO" && CLAUDE_AUTO_PYTHON3="$MARKER_PY" bash "${HOOKS}/on-pretooluse-action.sh" \
  <<< "$(payload sess-pm mcp__linear__save_issue "$NOREPO" '{"title":"Bash","note":"\"Bash\" wrap"}')" )
check "ran" "$([ -e "${WORK}/python-ran" ] && echo ran || echo none)"

it "shim: a destructive command with no lease on the machine starts no Python"
EMPTY="${WORK}/no-leases"
mkdir -p "$EMPTY"
rm -f "${WORK}/python-ran"
( cd "$NOREPO" && CLAUDE_AUTO_DATA_DIR="$EMPTY" CLAUDE_AUTO_PYTHON3="$MARKER_PY" bash "${HOOKS}/on-pretooluse-action.sh" \
  <<< "$(payload sess-worker Bash "$NOREPO" '{"command":"rm -rf build/"}')" )
check "none" "$([ -e "${WORK}/python-ran" ] && echo ran || echo none)"

it "shim: the text test on a command at the bound takes under 1 s"
START="$("$PY" -c 'import time; print(time.time())')"
reaches_python sess-worker "$(printf 'push clean rm branch reset gh %.0s' $(seq 1 40))" >/dev/null
check "fast" "$("$PY" -c 'import sys, time; print("fast" if time.time() - float(sys.argv[1]) < 1 else "slow")' "$START")"

# ── no-settings-writes ───────────────────────────────────────────────────────
set_programme "$WRITES" on
it "a worker under no-settings-writes in a programme with no proposals: Write is refused"
OUT="$(tool_hook sess-worker Write "$SETTINGS_WRITE")"
check "deny" "$(verdict "$OUT")"
it "the refusal names the limit"
has "$WRITES" "$OUT"
it "Edit and MultiEdit are refused"
EDIT_INPUT="{\"file_path\": \"${SETTINGS}\", \"old_string\": \"a\", \"new_string\": \"b\"}"
MULTI_INPUT="{\"file_path\": \"${SETTINGS}\", \"edits\": []}"
A="$(verdict "$(tool_hook sess-worker Edit "$EDIT_INPUT")")"
B="$(verdict "$(tool_hook sess-worker MultiEdit "$MULTI_INPUT")")"
check "deny deny" "$A $B"
it "a Bash write is refused"
check "deny" "$(verdict "$(bash_hook sess-worker "echo '{}' > .claude/settings.local.json")")"
it "the behaviours store and folder are refused"
STORE_WRITE="{\"file_path\": \"${CLAUDE_AUTO_BEHAVIOURS_STORE}\", \"content\": \"{}\"}"
FOLDER_WRITE="{\"file_path\": \"${CLAUDE_AUTO_BEHAVIOURS_DIR}/x.md\", \"content\": \"x\"}"
A="$(verdict "$(tool_hook sess-worker Write "$STORE_WRITE")")"
B="$(verdict "$(tool_hook sess-worker Write "$FOLDER_WRITE")")"
C="$(verdict "$(bash_hook sess-worker "echo x > ${CLAUDE_AUTO_BEHAVIOURS_STORE}")")"
check "deny deny deny" "$A $B $C"
it "the behaviours refusal names the limit"
has "$WRITES" "$(tool_hook sess-worker Write "$STORE_WRITE")"
it "each refusal is journaled with the check and the path"
check "true" "$(limit_rows 'any(r["payload"]["check"] == "no-settings-writes" and r["payload"].get("path") == os.path.realpath(os.environ["CLAUDE_AUTO_BEHAVIOURS_STORE"]) for r in rows)' | tr -d '\n')"
it "the same worker on /tmp/x is allowed"
A="$(verdict "$(tool_hook sess-worker Write '{"file_path": "/tmp/x", "content": "x"}')")"
B="$(verdict "$(bash_hook sess-worker 'echo x > /tmp/x')")"
C="$(verdict "$(bash_hook sess-worker 'rm -rf /tmp/x')")"
check "allow allow allow" "$A $B $C"
it "settings.json in a .claude folder or the user config folder is refused too, by Write and by Bash"
PERMS="{\\\"permissions\\\": {\\\"allow\\\": [\\\"Bash(*)\\\"]}}"
A="$(verdict "$(tool_hook sess-worker Write "{\"file_path\": \"${DEST}/.claude/settings.json\", \"content\": \"${PERMS}\"}")")"
B="$(verdict "$(tool_hook sess-worker Write "{\"file_path\": \"~/.claude/settings.json\", \"content\": \"${PERMS}\"}")")"
C="$(verdict "$(export CLAUDE_CONFIG_DIR="${WORK}/cfg"; tool_hook sess-worker Write "{\"file_path\": \"${WORK}/cfg/settings.json\", \"content\": \"{}\"}")")"
D="$(verdict "$(bash_hook sess-worker "echo '{}' > ${DEST}/.claude/settings.json")")"
E="$(verdict "$(bash_hook sess-worker "cd ${DEST}/.claude && echo '{}' > settings.json")")"
F="$(verdict "$(bash_hook sess-worker "echo '{}' > ${DEST}/.claude/sett''ings.json")")"
G="$(verdict "$(bash_hook sess-worker "sed -i '' s/a/b/ ${SETTINGS}")")"
check "deny deny deny deny deny deny deny" "$A $B $C $D $E $F $G"
it "the same worker on a look-alike name is allowed"
A="$(verdict "$(tool_hook sess-worker Write "{\"file_path\": \"${DEST}/notes/settings.json\", \"content\": \"{}\"}")")"
B="$(verdict "$(tool_hook sess-worker Write "{\"file_path\": \"${DEST}/.claude/my-settings.json\", \"content\": \"{}\"}")")"
check "allow allow" "$A $B"
it "reads of the settings and behaviours files stay open under the limit, and journal nothing"
BEFORE="$(limit_rows 'len(rows)')"
OUT=""
for c in "cat ${SETTINGS}" "grep allow ${DEST}/.claude/settings.json" "jq . ~/.claude/settings.json" \
  "cat ${SETTINGS} > ${WORK}/copy" "cat ${CLAUDE_AUTO_BEHAVIOURS_STORE}" "ls ${CLAUDE_AUTO_BEHAVIOURS_DIR}" \
  "echo \$CLAUDE_AUTO_BEHAVIOURS_DIR"; do
  OUT="${OUT}$(verdict "$(bash_hook sess-worker "$c")") "
done
check "allow allow allow allow allow allow allow " "$OUT"
check "$BEFORE" "$(limit_rows 'len(rows)')"
it "a Bash write to the behaviours files is still refused under the limit"
A="$(verdict "$(bash_hook sess-worker "cat ${WORK}/copy > ${CLAUDE_AUTO_BEHAVIOURS_STORE}")")"
B="$(verdict "$(bash_hook sess-worker "rm ${CLAUDE_AUTO_BEHAVIOURS_DIR}/x.md")")"
C="$(verdict "$(bash_hook sess-worker "export CLAUDE_AUTO_BEHAVIOURS_DIR=/tmp/x")")"
check "deny deny deny" "$A $B $C"
clear_settings
it "an unlimited worker is allowed"
A="$(verdict "$(tool_hook sess-worker Write "$SETTINGS_WRITE")")"
B="$(verdict "$(tool_hook sess-worker Write "$STORE_WRITE")")"
check "allow allow" "$A $B"
it "a limit added mid-run applies on the next settings write"
set_item "$WRITES" on
check "deny" "$(verdict "$(tool_hook sess-worker Write "$SETTINGS_WRITE")")"
clear_settings

# ── the PM's settings and behaviours writes ──────────────────────────────────
it "pm-settings-writes off: the PM's write to the behaviours store is allowed"
A="$(verdict "$(tool_hook sess-pm Write "$STORE_WRITE")")"
set_programme pm-settings-writes off
B="$(verdict "$(tool_hook sess-pm Write "$STORE_WRITE")")"
check "deny allow" "$A $B"
it "pm-settings-writes off leaves no-settings-writes alone: a limited PM on an item is refused"
edit_run "prog['check_settings'] = {'pm-settings-writes': {'state': 'off'}, '$WRITES': {'state': 'on'}}
prog['items']['linear:AI-2']['sessions'] = [{'session_id': 'sess-pm'}]"
check "deny" "$(verdict "$(tool_hook sess-pm Write "$SETTINGS_WRITE")")"
edit_run "prog['items']['linear:AI-2'].pop('sessions')"
clear_settings

# ── the literal send, whoever sends it ───────────────────────────────────────
it "literal send off: a session in the space with no item may send, because the target's programme decides"
A="$(verdict "$(bash_hook sess-peer 'herdr agent prompt w2:p31 go')")"
set_programme literal-send off
B="$(verdict "$(bash_hook sess-peer 'herdr agent prompt w2:p31 go')")"
check "deny allow" "$A $B"
it "literal send off: the send writes no blocked_driver_send row"
BEFORE="$(run_py "$RUN" <<'EOF'
print(sum(1 for r in pj.read(args[0]) if r["kind"] == "blocked_driver_send"))
EOF
)"
bash_hook sess-worker 'herdr agent prompt w2:p31 go' >/dev/null
check "$BEFORE" "$(run_py "$RUN" <<'EOF'
print(sum(1 for r in pj.read(args[0]) if r["kind"] == "blocked_driver_send"))
EOF
)"
it "literal send: an item's own setting beats the programme for that item's worker"
edit_run "prog['check_settings'] = {'literal-send': {'state': 'off'}}
prog['items']['linear:AI-1']['check_settings'] = {'literal-send': {'state': 'on'}}"
A="$(verdict "$(bash_hook sess-worker 'herdr agent prompt w2:p31 go')")"
B="$(verdict "$(bash_hook sess-free 'herdr agent prompt w2:p31 go')")"
check "deny allow" "$A $B"
clear_settings

# ── the tracker: only the remit check moves ──────────────────────────────────
set_programme tracker-outside-remit off
it "Linear remit check off: an out-of-remit write is allowed"
check "allow" "$(verdict "$(tool_hook sess-pm mcp__linear__save_issue '{"team":"WEB","title":"x"}')")"
it "Linear remit check off: a done state is still refused"
check "deny" "$(verdict "$(tool_hook sess-pm mcp__linear__save_issue '{"id":"AI-753","state":"Done"}')")"
it "Linear remit check off: a root-cause comment is still refused"
check "deny" "$(verdict "$(tool_hook sess-pm mcp__linear__save_comment '{"issueId":"AI-753","body":"Root cause: the cache"}')")"
clear_settings

# ── the advisor redirect: programme task runs only ───────────────────────────
it "advisor redirect off for the programme: a standalone run's question is still redirected"
set_programme advisor-redirect off
check "deny" "$(verdict "$(ask_hook sess-solo "$REPO")")"
it "advisor redirect off for the programme: a bound run's question goes through"
check "allow" "$(verdict "$(ask_hook sess-worker "$REPO")")"
it "a run of the same name in another repository is not the bound run"
OTHER_REPO="${WORK}/other-repo"
mkdir -p "${OTHER_REPO}/.claude/auto"
"$PY" -c 'import json, shutil, sys; shutil.copy(sys.argv[1], sys.argv[2])' "${REPO}/.claude/auto/task-bound.json" "${OTHER_REPO}/.claude/auto/task-bound.json"
check "deny" "$(verdict "$(ask_hook sess-worker "$OTHER_REPO")")"
clear_settings

# ── the Stop block ───────────────────────────────────────────────────────────
it "stop block off: a programme's PM stops"
set_programme stop-block off
check "allow" "$(verdict "$(stop_hook sess-pm "$NOREPO")")"
it "stop block off: a standalone run's block is unchanged"
check "block" "$(verdict "$(stop_hook sess-solo "$REPO")")"
it "stop block off: a bound run's worker stops"
check "allow" "$(verdict "$(stop_hook sess-worker "$REPO")")"
it "stop block off for the programme, but the PM's own stays on: the PM is held"
edit_run "prog['check_settings'] = {'stop-block': {'state': 'off', 'own': 'on'}}"
check "block" "$(verdict "$(stop_hook sess-pm "$NOREPO")")"
it "stop block on for the programme, the PM's own off: the PM stops and a bound run is held"
edit_run "prog['check_settings'] = {'stop-block': {'state': 'on', 'own': 'off'}}"
A="$(verdict "$(stop_hook sess-pm "$NOREPO")")"
B="$(verdict "$(stop_hook sess-worker "$REPO")")"
check "allow block" "$A $B"
it "stop block on an item alone: only that item's bound run is released"
edit_run "prog['check_settings'] = {}; prog['items']['linear:AI-1']['check_settings'] = {'stop-block': {'state': 'off'}}"
check "allow" "$(verdict "$(stop_hook sess-worker "$REPO")")"
it "a PM who stops with the block off writes no stop_quiet row"
set_programme stop-block off
stop_hook sess-pm "$NOREPO" >/dev/null
stop_hook sess-pm "$NOREPO" >/dev/null
check "0" "$(run_py "$RUN" <<'EOF'
print(sum(1 for r in pj.read(args[0]) if r["kind"] == "stop_quiet"))
EOF
)"
clear_settings

# ── the sub-agent guard ──────────────────────────────────────────────────────
it "sub-agent refusals off: a PM's sub-agent may also write the programme's files"
set_programme subagent-refusals off
check "allow" "$(verdict "$( ( cd "$NOREPO" && bash "${HOOKS}/on-pretooluse-subagent.sh" <<< "$(payload sess-pm Write "$NOREPO" "{\"file_path\": \"${CLAUDE_AUTO_DATA_DIR}/programmes/${RUN}/x\", \"content\": \"x\"}" '{"agent_id":"a1","agent_type":"general-purpose"}')" ) )")"
clear_settings

# ── a wrong setting, and a held store ────────────────────────────────────────
it "an off on the no-off pair changes nothing"
edit_run "prog['check_settings'] = {'tracker-proof': {'state': 'off'}, 'prefilled-answers': {'state': 'off'}}"
A="$(verdict "$(tool_hook sess-pm mcp__linear__save_issue '{"id":"AI-753","state":"Done"}')")"
B="$(verdict "$(ask_hook sess-pm "$NOREPO" '{"questions":[],"answers":{"a":"b"}}')")"
check "deny deny" "$A $B"
clear_settings

timed() {
  "$PY" - "$@" <<'EOF'
import subprocess, sys, time
cwd, script, stdin = sys.argv[1:4]
start = time.time()
try:
    out = subprocess.run(["bash", script], input=stdin, cwd=cwd, capture_output=True, text=True, timeout=9).stdout.strip()
except subprocess.TimeoutExpired:
    out = "timeout"
print(f"{'slow' if time.time() - start >= 3 else 'fast'} {out}")
EOF
}

STORE="${CLAUDE_AUTO_DATA_DIR}/programmes/${RUN}/programme.db"
if [ -f "$STORE" ]; then pass_store=1; else pass_store=0; fi
it "the fixture programme is store-backed"
check "1" "$pass_store"

set_programme "$LIMIT" on
"$PY" - "$STORE" > "${WORK}/locker.out" 2>&1 <<'EOF' &
import sqlite3, sys, time
conn = sqlite3.connect(sys.argv[1], isolation_level=None)
conn.execute("BEGIN EXCLUSIVE")
print("locked", flush=True)
time.sleep(60)
EOF
LOCKER=$!
for _ in $(seq 1 100); do grep -q '^locked' "${WORK}/locker.out" && break; "$PY" -c 'import time; time.sleep(0.05)'; done

it "store held: a limited worker's destructive command is allowed within 3 s, because a limit's default is off"
check "fast " "$(timed "$NOREPO" "${HOOKS}/on-pretooluse-action.sh" "$(payload sess-worker Bash "$NOREPO" '{"command":"rm -rf build/"}')")"
it "store held: a done state from the PM is still refused within 3 s"
OUT="$(timed "$NOREPO" "${HOOKS}/on-pretooluse-action.sh" "$(payload sess-pm mcp__linear__save_issue "$NOREPO" '{"id":"AI-753","state":"Done"}')")"
case "$OUT" in fast*'"deny"'*) pass ;; *) fail "got [$OUT]" ;; esac
it "store held: a send to the PM's pane is still refused within 3 s"
OUT="$(timed "$NOREPO" "${HOOKS}/on-pretooluse-action.sh" "$(payload sess-peer Bash "$NOREPO" '{"command":"herdr agent prompt w2:p31 go"}')")"
case "$OUT" in fast*'"deny"'*) pass ;; *) fail "got [$OUT]" ;; esac
it "store held: a PM's sub-agent is still refused within 3 s"
OUT="$(timed "$NOREPO" "${HOOKS}/on-pretooluse-subagent.sh" "$(payload sess-pm Bash "$NOREPO" '{"command":"bash programme.sh drop-item x"}' '{"agent_id":"a1","agent_type":"general-purpose"}')")"
case "$OUT" in fast*'"deny"'*) pass ;; *) fail "got [$OUT]" ;; esac
it "store held: the PM's Stop is still blocked within the hook limit"
OUT="$("$PY" - "$NOREPO" "${HOOKS}/on-stop.sh" '{"session_id":"sess-pm","stop_hook_active":false}' <<'EOF'
import subprocess, sys, time
cwd, script, stdin = sys.argv[1:4]
start = time.time()
out = subprocess.run(["bash", script], input=stdin, cwd=cwd, capture_output=True, text=True, timeout=12).stdout.strip()
print("fast" if time.time() - start < 3 else "slow", out)
EOF
)"
case "$OUT" in fast*'"block"'*) pass ;; *) fail "got [$OUT]" ;; esac
kill "$LOCKER" 2>/dev/null; wait "$LOCKER" 2>/dev/null

it "after the hold ends, the next read journals the one unreadable episode, and the limit is back"
OUT="$(verdict "$(bash_hook sess-worker 'rm -rf build/')")"
check "deny 1" "$OUT $(run_py "$RUN" <<'EOF'
print(sum(1 for r in pj.read(args[0]) if r["kind"] == "checks_unreadable" and r["payload"].get("outcome") != "bad_shape"))
EOF
)"
clear_settings

it "a limit stops when the programme ends"
set_programme "$LIMIT" on
A="$(verdict "$(bash_hook sess-worker 'rm -rf build/')")"
run_py "$RUN" <<'EOF' >/dev/null
ph.end_programme(args[0], "test")
EOF
check "deny allow" "$A $(verdict "$(bash_hook sess-worker 'rm -rf build/')")"

echo ""
echo "check-settings.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
