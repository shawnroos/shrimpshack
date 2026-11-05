#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
PROG="${AUTO_ROOT}/lib/programme.py"
ACTION="${AUTO_ROOT}/lib/on-pretooluse-action.py"
SUBAGENT="${AUTO_ROOT}/lib/on-pretooluse-subagent.py"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
check() { if [ "$1" = "$2" ]; then pass; else fail "expected [$1] got [$2]"; fi; }
has() { case "$2" in *"$1"*) pass ;; *) fail "expected to find [$1] in [$2]" ;; esac; }
lacks() { case "$2" in *"$1"*) fail "did not expect [$1] in [$2]" ;; *) pass ;; esac; }

echo "programme-checks.test.sh"

WORK="$(mktemp -d -t auto-programme-checks.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# A leftover host variable would put the session in a host this test never set up.
for v in $(env | grep -oE '^(HERDR|REX|GHOSTTY|AUTO_TEST)_[A-Z_]*'); do unset "$v"; done
unset CLAUDE_CODE_SESSION_ID CMUX_WORKSPACE_ID TERM_PROGRAM CLAUDE_AUTO_REPO 2>/dev/null || true

export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_MACHINE="studio"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_CODE_SESSION_ID="sess-pm"
printf 'export DEMO_TOKEN=hunter2secretvalue\n' > "$CLAUDE_AUTO_SECRETS_FILE"

FAKEBIN="${WORK}/bin"
mkdir -p "$FAKEBIN"
cat > "${FAKEBIN}/herdr" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_HERDR_LOG:-/dev/null}"
exit "${FAKE_HERDR_EXIT:-0}"
EOF
chmod +x "${FAKEBIN}/herdr"
export PATH="${FAKEBIN}:${PATH}"
export FAKE_HERDR_LOG="${WORK}/herdr.log"
: > "$FAKE_HERDR_LOG"

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
sys.path.insert(0, os.path.join(sys.argv[1], "tests", "helpers"))
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

prog() {
  OUT="$("$PY" "$PROG" "$@" --run "$RUN" 2>&1)"
  CODE=$?
}

rows() {
  run_py "$RUN" <<'EOF'
print(sum(1 for r in pj.read(args[0]) if r["kind"] == "hook_patched"))
EOF
}

last_row() {
  run_py "$RUN" "$1" <<'EOF'
row = [r for r in pj.read(args[0]) if r["kind"] == "hook_patched"][-1]
print(json.dumps(eval(args[1], {"row": row, "p": row["payload"]}), sort_keys=True))
EOF
}

REPO="${WORK}/shrimpshack"
CACHE="${WORK}/home/.claude/plugins/cache/shrimpshack/auto/1.2.3"
OTHER="${WORK}/other-repo"
mkdir -p "${REPO}/plugins/auto/lib" "${CACHE}/lib" "$OTHER"

action() {
  local payload
  payload="$("$PY" -c '
import json, sys
print(json.dumps({"session_id": sys.argv[1], "tool_name": sys.argv[2], "tool_input": json.loads(sys.argv[3])}))' "$1" "$2" "$3")"
  ( cd "$REPO" && "$PY" "$ACTION" "$REPO" <<< "$payload" )
}

subagent() {
  local payload
  payload="$("$PY" -c '
import json, sys
print(json.dumps({"session_id": "sess-pm", "agent_id": "a1", "agent_type": "general-purpose", "tool_name": "Bash",
                  "tool_input": {"command": sys.argv[1]}}))' "$1")"
  "$PY" "$SUBAGENT" <<< "$payload"
}

REPO_HOOK="${REPO}/plugins/auto/lib/on-pretooluse-action.py"
CACHE_HOOK="${CACHE}/lib/on-pretooluse-action.py"

it "the hook is live for this session: a done-state tracker write from the same PM is refused"
OUT="$(action sess-pm mcp__linear__save_issue '{"id": "AI-1", "state": "Done"}')"
has '"permissionDecision": "deny"' "$OUT"

it "the PM's Edit of hook code in a repo is not refused"
OUT="$(action sess-pm Edit "{\"file_path\": \"${REPO_HOOK}\", \"old_string\": \"a\", \"new_string\": \"b\"}")"
check "" "$OUT"

it "the PM's Edit and Write of hook code in the installed cache are not refused"
OUT="$(action sess-pm Edit "{\"file_path\": \"${CACHE_HOOK}\", \"old_string\": \"a\", \"new_string\": \"b\"}")"
OUT="${OUT}$(action sess-pm Write "{\"file_path\": \"${CACHE_HOOK}\", \"content\": \"x\"}")"
check "" "$OUT"

it "the PM's shell patch of the installed cache is not refused"
OUT="$(action sess-pm Bash "{\"command\": \"cp ${REPO_HOOK} ${CACHE_HOOK}\"}")"
OUT="${OUT}$(action sess-pm Bash "{\"command\": \"sed -i '' 's/a/b/' ${CACHE_HOOK}\"}")"
check "" "$OUT"

it "with a remit that leaves shrimpshack out, the same Edit is not refused"
run_py "$RUN" "$OTHER" <<'EOF' >/dev/null
import programme_records
programme_records.edit(args[0], 'prog.setdefault("remit", {})["repos"] = [{"path": ' + repr(args[1]) + ', "name": "other"}]', globals())
EOF
OUT="$(action sess-pm Edit "{\"file_path\": \"${REPO_HOOK}\", \"old_string\": \"a\", \"new_string\": \"b\"}")"
check "" "$OUT"

it "record-hook-patch needs a file, a why and a PR"
prog record-hook-patch lib/x.py --why "blocks work"
A="$CODE"
has "usage: record-hook-patch" "$OUT"
prog record-hook-patch lib/x.py --pr 12
B="$CODE"
has "usage: record-hook-patch" "$OUT"
prog record-hook-patch --why "blocks work" --pr 12
has "usage: record-hook-patch" "$OUT"
check "2 2 2 0" "$A $B $CODE $(rows)"

it "record-hook-patch from a session that does not drive the programme is refused and writes no row"
OUT="$(CLAUDE_CODE_SESSION_ID=sess-other "$PY" "$PROG" record-hook-patch lib/x.py --why "w" --pr 12 --run "$RUN" 2>&1)"
CODE=$?
has "only the programme's driving session" "$OUT"
check "1 0" "$CODE $(rows)"

it "the driver's record-hook-patch writes one row with the file, the why and the PR"
prog record-hook-patch "${CACHE}/lib/programme_view.py" --why "the view hides a live worker" --pr "https://github.com/shawnroos/shrimpshack/pull/999"
check "0 1" "$CODE $(rows)"
check "\"${CACHE}/lib/programme_view.py\"" "$(last_row 'p["file"]')"
check '"the view hides a live worker"' "$(last_row 'p["why"]')"
check '"https://github.com/shawnroos/shrimpshack/pull/999"' "$(last_row 'p["pr"]')"

it "a patch to a file with no protected rule names no rule in its notice"
check '[]' "$(last_row 'p["protects"]')"
lacks "It holds" "$(last_row 'p["text"]')"

it "the view lists the patch"
prog status
has "hook_patched" "$OUT"
has "programme_view.py" "$OUT"

it "patching the hook that holds the Linear rule names that rule in the row and in the output"
prog record-hook-patch "$CACHE_HOOK" --why "blocks work" --pr 999
check "0" "$CODE"
has "Linear done, cancelled and root-cause rule" "$OUT"
has "Linear done, cancelled and root-cause rule" "$(last_row 'p["text"]')"
has "on-pretooluse-action.py" "$(last_row 'p["text"]')"

it "the shell wrapper of that hook counts as the same file"
prog record-hook-patch ".claude/hooks/on-pretooluse-action.sh" --why "blocks work" --pr 999
has "Linear done, cancelled and root-cause rule" "$OUT"

it "patching a file behind the picker and pick rules names both"
prog record-hook-patch "lib/programme_approval.py" --why "blocks work" --pr 999
has "Auto writing the picker's text" "$OUT"
has "approvals that need a pick" "$OUT"

for file in programme_journal programme_setup programme_prompt_source programme_offers; do
  it "patching ${file}.py names the pick rule"
  prog record-hook-patch "lib/${file}.py" --why "blocks work" --pr 999
  has "approvals that need a pick" "$OUT"
done

it "every key in PROTECTED is a real file, so a rename fails here"
check "[]" "$(run_py <<'EOF'
checks = load_lib_module("programme_checks")
root = sys.argv[1]
def exists(key):
    return os.path.isfile(os.path.join(root, ".claude", "hooks", "hooks.json") if key == "hooks"
                          else os.path.join(root, "lib", key + ".py"))
print([key for key in checks.PROTECTED if not exists(key)])
EOF
)"

it "patching the pre-filled answer hook names that rule"
prog record-hook-patch "lib/on-pretooluse-askuser.py" --why "blocks work" --pr 999
has "pre-filled answer refusal" "$OUT"

it "patching the hook wiring names every protected rule"
prog record-hook-patch ".claude/hooks/hooks.json" --why "blocks work" --pr 999
has "Auto writing the picker's text" "$OUT"
has "pre-filled answer refusal" "$OUT"

it "control characters in the why do not reach the row"
prog record-hook-patch "lib/x.py" --why "$(printf 'bad\033[31m why')" --pr 999
check '"bad why"' "$(last_row 'p["why"]')"

it "a why holding a known secret is refused and saves no row"
BEFORE="$(rows)"
prog record-hook-patch "lib/x.py" --why "token hunter2secretvalue" --pr 999
check "1 ${BEFORE}" "$CODE $(rows)"

it "the notice reaches Shawn through the host"
: > "$FAKE_HERDR_LOG"
OUT="$(HERDR_PANE_ID=w2:p1 "$PY" "$PROG" record-hook-patch "lib/on-pretooluse-askuser.py" --why "blocks work" --pr 999 --run "$RUN" 2>&1)"
HERDR_LOG="$(cat "$FAKE_HERDR_LOG")"
has "notification show" "$HERDR_LOG"
has "on-pretooluse-askuser.py" "$HERDR_LOG"
has "pre-filled answer refusal" "$HERDR_LOG"

it "a delivered notice reports notified true"
OUT="$(HERDR_PANE_ID=w2:p1 "$PY" "$PROG" record-hook-patch "lib/x.py" --why "blocks work" --pr 999 --run "$RUN" 2>&1)"
has '"notified": true' "$OUT"

it "a failed host notification reports notified false, and the row is kept"
BEFORE="$(rows)"
OUT="$(HERDR_PANE_ID=w2:p1 FAKE_HERDR_EXIT=1 "$PY" "$PROG" record-hook-patch "lib/x.py" --why "blocks work" --pr 999 --run "$RUN" 2>&1)"
CODE=$?
has '"notified": false' "$OUT"
check "0 $((BEFORE + 1))" "$CODE $(rows)"

it "the PM's sub-agent running the verb is refused by the sub-agent guard"
OUT="$(subagent "bash ${AUTO_ROOT}/lib/programme.sh record-hook-patch lib/x.py --why w --pr 1 --run ${RUN}")"
has '"permissionDecision": "deny"' "$OUT"

it "the same sub-agent's read verb is not refused"
OUT="$(subagent "bash ${AUTO_ROOT}/lib/programme.sh status --run ${RUN}")"
check "" "$OUT"

CLAUSE="$(cat "${AUTO_ROOT}/behaviours/denied-command-stop.md")"

it "the clause covers a refusal of an Auto limit"
has "an Auto limit (not Claude Code) refuses a command" "$CLAUSE"
has "Do not run it again and do not try another tool, wrapper or worker for it" "$CLAUSE"
has "Keep working on the rest; the PM reads your transcript." "$CLAUSE"

it "the clause no longer tells a worker to stop on any denial, and leaves Claude Code denials to Claude Code"
lacks "a command is blocked" "$CLAUSE"
lacks "a blocked command" "$CLAUSE"
has "Claude Code's normal handling" "$CLAUSE"
lacks "bypass" "$CLAUSE"

new_run() {
  run_py "$@" <<'EOF'
print(ph.create_programme(args[1:], args[0])["run"])
EOF
}

edit_run() {
  run_py "$1" "$2" <<'EOF' >/dev/null
core = load_lib_module("run_record_core")
def mutate(rec):
    exec(args[1], {"prog": rec["programme"], "rec": rec})
core._with_locked_run_record(ph.home_path(args[0]), args[0], mutate)
EOF
}

states() {
  run_py "$@" <<'EOF'
checks = load_lib_module("programme_checks")
got = checks.session_checks(args[0])["states"]
print(" ".join("on" if got[name] else "off" for name in args[1:]))
EOF
}

check_rows() {
  run_py "$1" <<'EOF'
print(sum(1 for r in pj.read(args[0]) if r["kind"] == "checks_unreadable"))
EOF
}

ITEM_A='{"id": "linear:AI-1", "title": "a", "state": "open", "owner": {"session_id": "sess-a", "pane": "w30:p1"}}'
ITEM_B='{"id": "linear:AI-2", "title": "b", "state": "waiting", "owner": {"session_id": "sess-b0", "pane": "w30:p2"}, "sessions": [{"session_id": "sess-b"}]}'
ON='{"state": "on"}'
OFF='{"state": "off"}'
LIMIT="no-destructive-commands"
SEND="literal-send"

it "the registry holds one row per check, with its default, its off rule and who may turn it on"
OUT="$(run_py <<'EOF'
checks = load_lib_module("programme_checks")
for name in sorted(checks.CHECKS):
    row = checks.CHECKS[name]
    print(name, row.default, row.can_turn_off, checks.turning_on_needs(name), checks.turning_on_needs(name, own_run=True), row.limit)
EOF
)"
check "advisor-redirect True True shawn shawn False
literal-send True True shawn shawn False
no-destructive-commands False True shawn shawn True
no-settings-writes False True shawn shawn True
pm-settings-writes True True pm pm False
prefilled-answers True False None None False
stop-block True True shawn pm False
subagent-refusals True True pm pm False
tracker-outside-remit True True pm pm False
tracker-proof True False None None False" "$OUT"

R30="$(new_run sess-pm30 w30)"
edit_run "$R30" "prog['items'] = {'linear:AI-1': $ITEM_A, 'linear:AI-2': $ITEM_B}"

ALL="no-destructive-commands no-settings-writes pm-settings-writes literal-send tracker-outside-remit advisor-redirect subagent-refusals stop-block tracker-proof prefilled-answers"
DEFAULTS="off off on on on on on on on on"

it "a record with no check_settings field reads as the table's defaults"
edit_run "$R30" "prog.pop('check_settings', None)"
check "$DEFAULTS" "$(states sess-a $ALL)"

it "a session in no programme reads as the defaults, with no match"
OUT="$(run_py <<'EOF'
checks = load_lib_module("programme_checks")
got = checks.session_checks("sess-nobody")
print(got["matches"], got["unreadable"], got["decided_by"], sorted(got["states"]) == sorted(checks.CHECKS))
EOF
)"
check "[] [] {} True" "$OUT"

it "an empty or missing session id matches nothing, even an item with no session"
edit_run "$R30" "prog['check_settings'] = {'$LIMIT': $ON}; prog['items']['linear:AI-9'] = {'id': 'linear:AI-9', 'state': 'open', 'owner': {'session_id': ''}}"
OUT="$(run_py <<'EOF'
checks = load_lib_module("programme_checks")
print(checks.session_checks("")["states"]["no-destructive-commands"], checks.session_checks(None)["states"]["no-destructive-commands"])
EOF
)"
check "False False" "$OUT"
edit_run "$R30" "prog['items'].pop('linear:AI-9')"

it "programme setting on, item setting off: off for that item's sessions only"
edit_run "$R30" "prog['check_settings'] = {'$LIMIT': $ON}; prog['items']['linear:AI-1']['check_settings'] = {'$LIMIT': $OFF}"
check "off on" "$(states sess-a $LIMIT) $(states sess-b $LIMIT)"

it "programme setting off, item setting on: on for that item's sessions only"
edit_run "$R30" "prog['check_settings'] = {'$SEND': $OFF}; prog['items']['linear:AI-1']['check_settings'] = {'$SEND': $ON}"
check "on off" "$(states sess-a $SEND) $(states sess-b $SEND)"

it "a session listed on an item, not its owner, counts as attached (a takeover session keeps the limit)"
edit_run "$R30" "prog['check_settings'] = {'$LIMIT': $ON}; prog['items']['linear:AI-1'].pop('check_settings', None)"
check "on on" "$(states sess-b $LIMIT) $(states sess-b0 $LIMIT)"

it "the result names the run and item behind a setting, for the refusal to journal"
OUT="$(run_py "$R30" "$LIMIT" <<'EOF'
checks = load_lib_module("programme_checks")
got = checks.session_checks("sess-b")
print(got["decided_by"][args[1]] == {"run": args[0], "item": "linear:AI-2", "scope": "programme"},
      got["matches"] == [{"run": args[0], "item": "linear:AI-2", "role": "worker"}])
EOF
)"
check "True True" "$OUT"

it "a session on two items takes the limit either one has on"
edit_run "$R30" "prog['items']['linear:AI-1']['check_settings'] = {'$LIMIT': $OFF}; prog['items']['linear:AI-2']['check_settings'] = {'$LIMIT': $ON}; prog['items']['linear:AI-1']['sessions'] = [{'session_id': 'sess-two'}]; prog['items']['linear:AI-2']['sessions'] = [{'session_id': 'sess-two'}]"
check "on" "$(states sess-two $LIMIT)"
edit_run "$R30" "prog['items'] = {'linear:AI-1': $ITEM_A, 'linear:AI-2': $ITEM_B}; prog['check_settings'] = {}"

it "a worker in another space is found through the programme's lease"
R31="$(new_run sess-pm31 w31)"
edit_run "$R31" "prog['check_settings'] = {'$LIMIT': $ON}; prog['items'] = {'linear:AI-5': {'id': 'linear:AI-5', 'state': 'open', 'owner': {'session_id': 'sess-far', 'pane': 'w99:p1'}}}"
check "on" "$(states sess-far $LIMIT)"

it "the PM takes a programme setting, but a limit binds only a session on an item"
edit_run "$R31" "prog['check_settings'] = {'$LIMIT': $ON, '$SEND': $OFF}"
check "off off" "$(states sess-pm31 $LIMIT $SEND)"
OUT="$(run_py "$R31" <<'EOF'
checks = load_lib_module("programme_checks")
print(checks.session_checks("sess-pm31")["matches"] == [{"run": args[0], "item": None, "role": "pm"}])
EOF
)"
check "True" "$OUT"

it "a PM that is also on an item takes the limit"
edit_run "$R31" "prog['items']['linear:AI-5']['sessions'] = [{'session_id': 'sess-pm31'}]"
check "on" "$(states sess-pm31 $LIMIT)"

it "after a takeover the new driver is the PM and the old one is not"
edit_run "$R31" "rec['driving_session_id'] = 'sess-new-pm'; prog['items']['linear:AI-5']['sessions'] = []"
check "off on" "$(states sess-new-pm $SEND) $(states sess-pm31 $SEND)"

for finished in done handed dropped decided; do
  it "an item in state ${finished} stops applying its settings and the programme's"
  edit_run "$R31" "prog['items'] = {'linear:AI-5': {'id': 'linear:AI-5', 'state': '$finished', 'owner': {'session_id': 'sess-far'}, 'check_settings': {'$LIMIT': $ON}}}"
  check "off" "$(states sess-far $LIMIT)"
done

it "a session with a finished item and a live one keeps the live item's limit"
edit_run "$R31" "prog['items'] = {'linear:AI-5': {'id': 'linear:AI-5', 'state': 'done', 'owner': {'session_id': 'sess-far'}}, 'linear:AI-6': {'id': 'linear:AI-6', 'state': 'open', 'owner': {'session_id': 'sess-far'}}}"
check "on" "$(states sess-far $LIMIT)"

it "an ended programme stops applying"
run_py "$R31" <<'EOF' >/dev/null
ph.end_programme(args[0], "test")
EOF
check "off" "$(states sess-far $LIMIT)"

R32="$(new_run sess-pm32 w32)"
BASE32="prog['items'] = {'linear:AI-7': {'id': 'linear:AI-7', 'state': 'open', 'owner': {'session_id': 'sess-shape'}}};"
for bad in "'on'" "['$LIMIT']" "7" "True"; do
  it "a check_settings value of ${bad} is treated as the default"
  edit_run "$R32" "$BASE32 prog['check_settings'] = $bad"
  check "off on" "$(states sess-shape $LIMIT $SEND)"
done
for bad in "'on'" "True" "1" "{'state': 'maybe'}" "{'state': ['on']}" "{'state': True}" "{}" "None"; do
  it "a setting of ${bad} is treated as the default"
  edit_run "$R32" "$BASE32 prog['check_settings'] = {'$LIMIT': $bad, '$SEND': $bad}"
  check "off on" "$(states sess-shape $LIMIT $SEND)"
done

it "a bad item setting falls through to the programme setting"
edit_run "$R32" "$BASE32 prog['check_settings'] = {'$LIMIT': $ON}; prog['items']['linear:AI-7']['check_settings'] = 'off'"
check "on" "$(states sess-shape $LIMIT)"

it "an unknown check name in a record is ignored"
edit_run "$R32" "$BASE32 prog['check_settings'] = {'no-such-check': $ON}"
check "$DEFAULTS" "$(states sess-shape $ALL)"

it "the two checks with no off setting stay on, even when a record says off"
edit_run "$R32" "$BASE32 prog['check_settings'] = {'prefilled-answers': $OFF, 'tracker-proof': $OFF}"
check "on on" "$(states sess-shape prefilled-answers tracker-proof)"

for bad in "prog['items']['linear:AI-7']['owner'] = 'sess-shape'" "prog['items']['linear:AI-7']['sessions'] = 7" "prog['items']['linear:AI-7'] = 'x'" "prog['items'] = ['x']"; do
  it "a malformed record does not raise, and reads as the defaults: ${bad}"
  edit_run "$R32" "$BASE32 prog['check_settings'] = {'$LIMIT': $ON}; ${bad}"
  check "off on" "$(states sess-shape $LIMIT $SEND)"
done

it "a programme of the wrong shape reads as the defaults and does not hide the next programme's worker"
R34="$(new_run sess-pm34 w34)"
edit_run "$R34" "prog['check_settings'] = {'$LIMIT': $ON}; prog['items'] = {'linear:AI-4': {'id': 'linear:AI-4', 'state': 'open', 'owner': {'session_id': 'sess-next'}}}"
edit_run "$R32" "$BASE32 prog['check_settings'] = {'$LIMIT': $ON}; rec['saved'] = prog; rec['programme'] = 'x'"
check "off on" "$(states sess-shape $LIMIT) $(states sess-next $LIMIT)"
edit_run "$R32" "rec['programme'] = rec.pop('saved')"

it "a wrong-shape setting journals one row across many calls, and a new one after it was fixed"
edit_run "$R32" "$BASE32 prog['check_settings'] = {}"
states sess-shape $LIMIT >/dev/null
BEFORE="$(check_rows "$R32")"
edit_run "$R32" "$BASE32 prog['check_settings'] = {'$LIMIT': 'on'}"
for _ in 1 2 3; do states sess-shape $LIMIT >/dev/null; done
A="$(check_rows "$R32")"
edit_run "$R32" "$BASE32 prog['check_settings'] = {}"
states sess-shape $LIMIT >/dev/null
B="$(check_rows "$R32")"
edit_run "$R32" "$BASE32 prog['check_settings'] = {'$LIMIT': 'on'}"
states sess-shape $LIMIT >/dev/null
check "$((BEFORE + 1)) $((BEFORE + 1)) $((BEFORE + 2))" "$A $B $(check_rows "$R32")"

it "the wrong-shape row names where the setting is, and not its value"
edit_run "$R32" "$BASE32 prog['check_settings'] = {}"
states sess-shape $LIMIT >/dev/null
edit_run "$R32" "$BASE32 prog['check_settings'] = {}; prog['items']['linear:AI-7']['check_settings'] = {'$LIMIT': 'hunter-value'}"
states sess-shape $LIMIT >/dev/null
ROW="$(run_py "$R32" <<'EOF'
print(json.dumps([r for r in pj.read(args[0]) if r["kind"] == "checks_unreadable"][-1]["payload"], sort_keys=True))
EOF
)"
has "bad_shape" "$ROW"
has "linear:AI-7" "$ROW"
lacks "hunter-value" "$ROW"

it "no environment variable changes a result"
edit_run "$R32" "$BASE32 prog['check_settings'] = {'$LIMIT': $ON}"
PLAIN="$(states sess-shape $ALL)"
OPENED="$(CLAUDE_AUTO_TEST_HARNESS=1 CLAUDE_AUTO_TEST_DESTRUCTIVE_CHECK=1 CLAUDE_AUTO_CHECKS=off CLAUDE_AUTO_CHECK_SETTINGS='{}' \
  CLAUDE_AUTO_NO_DESTRUCTIVE_COMMANDS=off NO_DESTRUCTIVE_COMMANDS=off CLAUDE_CODE_SESSION_ID=sess-other HERDR_PANE_ID=w32:p1 CLAUDE_CODE_SUBAGENT=1 \
  states sess-shape $ALL)"
check "$PLAIN" "$OPENED"

it "the session comes only from the caller, never from the environment"
check "off" "$(CLAUDE_CODE_SESSION_ID=sess-shape states sess-nobody $LIMIT)"

it "the checks module reads no environment at all"
OUT="$(grep -nE 'environ|getenv|test_hatch|_hatch\(' "${AUTO_ROOT}/lib/programme_checks.py")"
check "" "$OUT"

it "a programme home that cannot be read gives the defaults and raises nothing"
edit_run "$R32" "$BASE32 prog['check_settings'] = {'$LIMIT': $ON}"
chmod 000 "${CLAUDE_AUTO_DATA_DIR}/programmes/${R32}"
OUT="$(states sess-shape $LIMIT $SEND)"
chmod 700 "${CLAUDE_AUTO_DATA_DIR}/programmes/${R32}"
check "off on" "$OUT"

it "an unusable data directory gives the defaults and raises nothing"
check "$DEFAULTS" "$(CLAUDE_AUTO_DATA_DIR=relative/path states sess-shape $ALL)"

start_store_lock() {
  LOCKER_OUT="${WORK}/locker.out"
  : > "$LOCKER_OUT"
  "$PY" - "${CLAUDE_AUTO_DATA_DIR}/programmes/$1/programme.db" > "$LOCKER_OUT" 2>&1 <<'EOF' &
import sqlite3, sys, time
conn = sqlite3.connect(sys.argv[1], isolation_level=None)
conn.execute("BEGIN EXCLUSIVE")
print("locked", flush=True)
time.sleep(60)
EOF
  LOCKER_PID=$!
  for _ in $(seq 1 100); do grep -q '^locked' "$LOCKER_OUT" && return 0; "$PY" -c 'import time; time.sleep(0.1)'; done
  return 1
}
stop_store_lock() { kill "$LOCKER_PID" 2>/dev/null; wait "$LOCKER_PID" 2>/dev/null; }

timed_read() {
  run_py "$@" <<'EOF'
import time
checks = load_lib_module("programme_checks")
start = time.monotonic()
got = checks.session_checks(args[0])
print(got["states"][args[1]], got["unreadable"], time.monotonic() - start < 3)
EOF
}

R33="$(run_py <<'EOF'
print(ph.create_programme([f"w{n}" for n in range(40, 56)], "sess-pm33")["run"])
EOF
)"
edit_run "$R33" "prog['check_settings'] = {'$LIMIT': $ON, '$SEND': $OFF}; prog['items'] = {'linear:AI-8': {'id': 'linear:AI-8', 'state': 'open', 'owner': {'session_id': 'sess-held'}}}"
OUT="$(run_py "$R33" <<'EOF'
print(load_lib_module("programme_import").promote(args[0])["status"])
print(load_lib_module("programme_authority").promoted(ph.home_path(args[0]), args[0]))
EOF
)"
has "True" "$OUT"

it "with the store free, a promoted programme's setting is in force"
check "on off" "$(states sess-held $LIMIT $SEND)"

it "a programme over 16 spaces with its store held gives the defaults within 3 s, on every call, with no row yet"
start_store_lock "$R33" || fail "the store was never locked: $(head -c 200 "$LOCKER_OUT")"
OUT=""
for _ in 1 2 3 4 5; do OUT="${OUT}$(timed_read sess-held $LIMIT)
"; done
EXPECT="False ['${R33}'] True"
check "$(printf '%s\n%s\n%s\n%s\n%s' "$EXPECT" "$EXPECT" "$EXPECT" "$EXPECT" "$EXPECT")" "$(printf '%s' "$OUT")"
it "under the hold a check that defaults on is on, whatever the record says"
check "on" "$(states sess-held $SEND)"
stop_store_lock

it "many calls over one held episode leave one row once the store frees"
OUT=""
for _ in 1 2 3; do OUT="${OUT} $(states sess-held $LIMIT)"; done
check " on on on 1" "${OUT} $(check_rows "$R33")"

it "the row says when the episode began and why, and is not repeated"
ROW="$(run_py "$R33" <<'EOF'
row = [r for r in pj.read(args[0]) if r["kind"] == "checks_unreadable"][-1]["payload"]
print(sorted(row), row["outcome"])
EOF
)"
has "'detail', 'outcome', 'since'" "$ROW"
has "unavailable" "$ROW"

it "a second hold is a second episode, with one more row"
start_store_lock "$R33" || fail "the store was never locked"
states sess-held $LIMIT >/dev/null
states sess-other-session $LIMIT >/dev/null
stop_store_lock
states sess-held $LIMIT >/dev/null
states sess-held $LIMIT >/dev/null
check "2" "$(check_rows "$R33")"

it "parallel hooks reading after a hold still write one row"
start_store_lock "$R33" || fail "the store was never locked"
states sess-held $LIMIT >/dev/null
stop_store_lock
for _ in 1 2 3 4 5 6 7 8; do states sess-held $LIMIT >/dev/null & PIDS="${PIDS:-} $!"; done
for pid in $PIDS; do wait "$pid"; done
check "3" "$(check_rows "$R33")"

it "a failed write of the row leaves it owed, and the next read writes it"
start_store_lock "$R33" || fail "the store was never locked"
states sess-held $LIMIT >/dev/null
stop_store_lock
OUT="$(run_py "$R33" <<'EOF'
checks = load_lib_module("programme_checks")
real = pj.append
def boom(*a, **k):
    raise OSError("no room")
pj.append = boom
print(checks.session_checks("sess-held")["states"]["no-destructive-commands"])
pj.append = real
EOF
)"
check "True 3" "${OUT} $(check_rows "$R33")"
states sess-held $LIMIT >/dev/null
check "4" "$(check_rows "$R33")"

it "a held programme does not change a session that another programme decides"
start_store_lock "$R33" || fail "the store was never locked"
edit_run "$R32" "$BASE32 prog['check_settings'] = {'$SEND': $OFF}"
OUT="$(states sess-shape $SEND)"
stop_store_lock
check "off" "$OUT"

echo "programme-checks.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
