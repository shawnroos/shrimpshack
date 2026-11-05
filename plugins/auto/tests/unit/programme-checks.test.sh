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
has "Do not retry it, or try it through another tool, wrapper or worker" "$CLAUSE"
has "Keep working on the rest; the PM sees the refusal." "$CLAUSE"

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

# ---- set-check: the verb, the approval rule and status ----

opick() { CLAUDE_CODE_SESSION_ID=sess-ps "$PY" "${AUTO_ROOT}/tests/fixtures/offer_pick.py" "$SR" "$@"; }
sc() {
  OUT="$(CLAUDE_CODE_SESSION_ID=sess-ps "$PY" "$PROG" set-check "$@" --run "$SR" 2>&1)"
  CODE=$?
}
offer() {
  OUT="$(CLAUDE_CODE_SESSION_ID=sess-ps "$PY" "$PROG" offer "$1" --command "$2" --run "$SR" 2>&1)"
  CODE=$?
}
stored() {
  run_py "$SR" "$1" <<'EOF'
rec = load_lib_module("run_record_core").read_run_record(ph.home_path(args[0]), args[0])
print(json.dumps(eval(args[1], {"prog": rec["programme"]}), sort_keys=True))
EOF
}
check_set_rows() {
  run_py "$SR" <<'EOF'
print(sum(1 for r in pj.read(args[0]) if r["kind"] == "check_set"))
EOF
}
last_set() {
  run_py "$SR" "$1" <<'EOF'
row = [r for r in pj.read(args[0]) if r["kind"] == "check_set"][-1]
print(json.dumps(eval(args[1], {"row": row, "p": row["payload"]}), sort_keys=True))
EOF
}
digest() {
  run_py "$SR" <<'EOF'
rec = load_lib_module("run_record_core").read_run_record(ph.home_path(args[0]), args[0])
print(load_lib_module("programme_approval").terms_digest(ph.normalize_programme(rec["programme"])))
EOF
}
status_text() { CLAUDE_CODE_SESSION_ID=sess-ps "$PY" "$PROG" status --run "$SR" 2>&1; }
ITEM_S='{"id": "linear:AI-7", "title": "s", "state": "open", "owner": {"session_id": "sess-sw", "pane": "w90:p1"}}'
ITEM_T='{"id": "linear:AI-8", "title": "t", "state": "open", "owner": {"session_id": "sess-tw", "pane": "w90:p2"}}'
ITEM_DONE='{"id": "linear:AI-9", "title": "d", "state": "done", "owner": {"session_id": "sess-dw", "pane": "w90:p3"}}'
SR="$(new_run sess-ps w90)"
edit_run "$SR" "prog['items'] = {'linear:AI-7': $ITEM_S, 'linear:AI-8': $ITEM_T, 'linear:AI-9': $ITEM_DONE}"
DIGEST_BEFORE="$(digest)"

it "AE5: the PM turns the literal send check off alone"
sc literal-send off
check "0" "$CODE"
has '"kind": "check_set"' "$OUT"
check '"off"' "$(stored "prog['check_settings']['literal-send']['state']")"
check "off" "$(states sess-sw literal-send)"

it "AE5: the change is journaled, with no prompt"
check "1" "$(check_set_rows)"
check '["literal-send", "off", "programme", null, null]' "$(last_set '[p["check"], p["state"], p["scope"], p.get("item"), p.get("prompt_id")]')"

it "AE5: status lists the setting, and rules lists it too"
has "check literal-send: off for the programme" "$(status_text)"
has "check literal-send: off for the programme" "$(CLAUDE_CODE_SESSION_ID=sess-ps "$PY" "$PROG" rules --run "$SR" 2>&1)"
has '"literal-send"' "$(CLAUDE_CODE_SESSION_ID=sess-ps "$PY" "$PROG" status --json --run "$SR" 2>&1 | "$PY" -c 'import json,sys; print(json.dumps([r["check"] for r in json.load(sys.stdin)["model"]["rules_in_force"]["checks"] if r.get("set_at")]))')"

it "the agreement page lists the checks too, outside the agreed terms"
has "check literal-send: off for the programme" "$(CLAUDE_CODE_SESSION_ID=sess-ps "$PY" "$PROG" status agreement --run "$SR" 2>&1)"

it "AE5: turning on a limit with no prompt is refused, and the limit stays off"
sc no-destructive-commands on
check "1" "$CODE"
has "needs --prompt" "$OUT"
check "null" "$(stored "prog['check_settings'].get('no-destructive-commands')")"
check "off" "$(states sess-sw no-destructive-commands)"

it "the picker for a limit lists the decline first and names the check and its reach"
offer limit-a "set-check no-destructive-commands on"
check "0" "$CODE"
check '"Not now"' "$(printf '%s' "$OUT" | "$PY" -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["input"]["questions"][0]["options"][0]["label"]))')"
has "Turn on no destructive commands for the whole programme" "$OUT"

it "a pick of the offer turns the limit on, for workers, with the pick cited"
P="$(opick "set-check no-destructive-commands on")"
sc no-destructive-commands on --prompt "$P"
check "0" "$CODE"
check "on" "$(states sess-sw no-destructive-commands)"
check "[\"$P\", \"$P\"]" "$(last_set '[row["cites"][0], p["prompt_id"]]')"
check '"shawn"' "$(stored "prog['check_settings']['no-destructive-commands']['set_by']")"

it "one pick approves one change: it cannot turn the limit on again after an off"
sc no-destructive-commands off
check "0" "$CODE"
sc no-destructive-commands on --prompt "$P"
check "1" "$CODE"
has "already used" "$OUT"
check "off" "$(states sess-sw no-destructive-commands)"

it "turning a limit off needs no prompt at all, and the record says the PM did it"
check '"pm"' "$(stored "prog['check_settings']['no-destructive-commands']['set_by']")"

it "a prompt on a change that needs none is refused and is not spent"
P="$(opick "set-check no-destructive-commands on")"
sc subagent-refusals off --prompt "$P"
check "1" "$CODE"
has "needs no pick" "$OUT"
sc no-destructive-commands on --prompt "$P"
check "0" "$CODE"
sc no-destructive-commands off

it "own words cannot turn on a limit: the option moves authority"
P="$(opick --other "yes please turn it on" "set-check no-destructive-commands on")"
OUT="$(CLAUDE_CODE_SESSION_ID=sess-ps "$PY" "$PROG" set-check no-destructive-commands on --prompt "$P" --reads-as "Turn on no destructive commands for the whole programme" --run "$SR" 2>&1)"
CODE=$?
check "1" "$CODE"
has "moves authority" "$OUT"
check "off" "$(states sess-sw no-destructive-commands)"

it "a decline runs nothing"
P="$(opick --decline "set-check no-destructive-commands on")"
sc no-destructive-commands on --prompt "$P"
check "1" "$CODE"
has "declined" "$OUT"
check "off" "$(states sess-sw no-destructive-commands)"

it "a pick of another command approves nothing here"
P="$(opick "set-check no-settings-writes on")"
sc no-destructive-commands on --prompt "$P"
check "1" "$CODE"
has "different command" "$OUT"

it "--item sets one item only, and beats the programme setting"
P="$(opick "set-check no-settings-writes on --item linear:AI-7")"
sc no-settings-writes on --item linear:AI-7 --prompt "$P"
check "0" "$CODE"
check "on off" "$(states sess-sw no-settings-writes) $(states sess-tw no-settings-writes)"
has "check no-settings-writes: on for item linear:AI-7" "$(status_text)"
check '["no-settings-writes", "on", "item", "linear:AI-7"]' "$(last_set '[p["check"], p["state"], p["scope"], p["item"]]')"

it "an item setting survives a programme off, and the output says which items still differ"
sc no-settings-writes off
check "0" "$CODE"
has '"items_still_differ": ["linear:AI-7"]' "$OUT"
check "on" "$(states sess-sw no-settings-writes)"

it "a pick made while the item was open does not apply once the item has changed"
P="$(opick "set-check no-destructive-commands on --item linear:AI-8")"
edit_run "$SR" "prog['items']['linear:AI-8']['state'] = 'waiting'"
sc no-destructive-commands on --item linear:AI-8 --prompt "$P"
check "1" "$CODE"
has "changed since the offer" "$OUT"
edit_run "$SR" "prog['items']['linear:AI-8']['state'] = 'open'"

it "--item on an unknown item is refused, with or without a prompt"
sc literal-send off --item linear:AI-404
check "1" "$CODE"
has "AI-404" "$OUT"
offer limit-u "set-check no-destructive-commands on --item linear:AI-404"
check "1" "$CODE"
has "AI-404" "$OUT"

it "--item on a finished item is refused: a finished item's settings never apply"
sc literal-send off --item linear:AI-9
check "1" "$CODE"
has "finished" "$OUT"

it "the pre-filled answer refusal and Linear proof have no off setting, and the refusal gives the reason"
for name in prefilled-answers tracker-proof; do
  sc "$name" off
  check "1" "$CODE"
  has "has no off setting" "$OUT"
  sc "$name" on
  check "1" "$CODE"
  has "has no off setting" "$OUT"
  offer "fixed-${name}" "set-check $name off"
  check "1" "$CODE"
done
check "null null" "$(stored "prog['check_settings'].get('prefilled-answers')") $(stored "prog['check_settings'].get('tracker-proof')")"
check "on on" "$(states sess-sw prefilled-answers tracker-proof)"

it "an unknown check name is refused, and the refusal lists the names"
sc no-such-check off
check "1" "$CODE"
has "unknown check" "$OUT"
has "literal-send" "$OUT"

it "a state other than on or off is refused with the usage"
sc literal-send maybe
check "2" "$CODE"
has "usage: set-check" "$OUT"

it "the same state twice is refused and writes no row"
BEFORE="$(check_set_rows)"
sc literal-send off
check "1" "$CODE"
has "already off" "$OUT"
check "$BEFORE" "$(check_set_rows)"

it "a worker running the verb is refused"
OUT="$(CLAUDE_CODE_SESSION_ID=sess-sw "$PY" "$PROG" set-check tracker-outside-remit off --run "$SR" 2>&1)"
CODE=$?
check "1" "$CODE"
has "driving session" "$OUT"
check "null" "$(stored "prog['check_settings'].get('tracker-outside-remit')")"

it "a PM's sub-agent running the verb is refused"
OUT="$(subagent "bash ${AUTO_ROOT}/lib/programme.sh set-check tracker-outside-remit off --run ${SR}")"
has '"permissionDecision": "deny"' "$OUT"

it "no setting moves terms_digest"
check "$DIGEST_BEFORE" "$(digest)"

it "a limit stays out of the accepted terms: on and off leave the digest alone"
P="$(opick "set-check no-destructive-commands on")"
sc no-destructive-commands on --prompt "$P"
check "$DIGEST_BEFORE" "$(digest)"
sc no-destructive-commands off

it "every check the PM turns off alone goes off with no prompt"
for name in pm-settings-writes tracker-outside-remit advisor-redirect subagent-refusals stop-block; do
  sc "$name" off
  check "0" "$CODE"
  check '"off"' "$(stored "prog['check_settings']['$name']['state']")"
done

it "every check the table gives the PM alone goes on with no prompt"
for name in pm-settings-writes tracker-outside-remit subagent-refusals; do
  sc "$name" on
  check "0" "$CODE"
done
check '"pm"' "$(stored "prog['check_settings']['subagent-refusals']['set_by']")"

it "every check the table gives Shawn stays off with no prompt, and goes on with his pick"
for name in advisor-redirect literal-send stop-block; do
  sc "$name" on
  check "1" "$CODE"
  has "needs --prompt" "$OUT"
  P="$(opick "set-check $name on")"
  sc "$name" on --prompt "$P"
  check "0" "$CODE"
  sc "$name" off
done

it "a change that needs no pick cannot be offered"
offer free-a "set-check literal-send off"
check "1" "$CODE"
has "needs no pick" "$OUT"
offer free-b "set-check subagent-refusals on"
check "1" "$CODE"
has "needs no pick" "$OUT"

it "the same check already on cannot be offered"
P="$(opick "set-check no-destructive-commands on")"
sc no-destructive-commands on --prompt "$P"
offer dup-a "set-check no-destructive-commands on"
check "1" "$CODE"
has "already on" "$OUT"
sc no-destructive-commands off

it "the Stop block: the PM turns on its own alone, and a worker's run stays off"
sc stop-block on --own
check "0" "$CODE"
check "on off" "$(states sess-ps stop-block) $(states sess-sw stop-block)"
has "check stop-block: on for the PM's own run" "$(status_text)"
check '["stop-block", "on", "own", null]' "$(last_set '[p["check"], p["state"], p["scope"], p.get("item")]')"

it "the Stop block: the PM turns off its own alone, and that moves only the PM"
sc stop-block off --own
check "0" "$CODE"
check "off" "$(states sess-ps stop-block)"

it "the Stop block on an item stays Shawn's pick"
sc stop-block on --item linear:AI-7
check "1" "$CODE"
has "needs --prompt" "$OUT"

it "--own is refused on any other check and beside --item"
sc literal-send on --own
check "1" "$CODE"
has "only stop-block" "$OUT"
sc stop-block on --own --item linear:AI-7
check "1" "$CODE"
has "--own" "$OUT"

it "the PM's own setting leaves the record of who set the programme's: Shawn's pick stays Shawn's"
P="$(opick "set-check stop-block on")"
sc stop-block on --prompt "$P"
check "0" "$CODE"
sc stop-block on --own
check "0" "$CODE"
check '["shawn", "pm"]' "$(stored "[prog['check_settings']['stop-block']['set_by'], prog['pm_run']['check_settings']['stop-block']['set_by']]")"
has "check stop-block: on for the programme (by shawn" "$(status_text)"
has "check stop-block: on for the PM's own run (by pm" "$(status_text)"
sc stop-block off
sc stop-block off --own

it "a PM's own Stop block setting with no programme entry is a good shape: no fault row"
edit_run "$SR" "prog['check_settings'].pop('stop-block', None)"
BEFORE="$(check_rows "$SR")"
states sess-ps stop-block >/dev/null
check "$BEFORE" "$(check_rows "$SR")"
check "off" "$(states sess-ps stop-block)"

it "status shows defaults on one line and the no-off pair on one line"
TEXT="$(status_text)"
has "checks at their default:" "$TEXT"
has "no off setting: tracker-proof, prefilled-answers" "$TEXT"

it "a patch to the file that holds the registry names the three rules it holds"
PATCH_OUT="$(CLAUDE_CODE_SESSION_ID=sess-ps "$PY" "$PROG" record-hook-patch "lib/programme_checks.py" --why "w" --pr 1 --run "$SR" 2>&1)"
has "pre-filled answer refusal" "$PATCH_OUT"
has "Linear done, cancelled and root-cause rule" "$PATCH_OUT"
has "approvals that need a pick" "$PATCH_OUT"

it "an item's off beats the programme's on: the limit is not on for that item, so it is asked for and listed"
check "[] ['ask'] ['no-destructive-commands'] False True" "$(run_py <<'EOF'
checks = load_lib_module("programme_checks")
prog = {"check_settings": {"no-destructive-commands": {"state": "on"}},
        "items": {"a": {"state": "active", "check_settings": {"no-destructive-commands": {"state": "off"}}}}}
rows = [{"kind": "contract_set", "payload": {"item": "a", "limits": ["no-destructive-commands"]}}]
terms = load_lib_module("programme_limit_terms")
asks = terms.limit_asks(prog, "a", ["no-destructive-commands"])
print(terms.item_limits(prog, "a"), ["ask" for _ in asks], [r["check"] for r in terms.named_limits(prog, rows, [])],
      checks.effective("no-destructive-commands", prog["items"]["a"], prog),
      checks.effective("no-destructive-commands", {"state": "active"}, prog))
EOF
)"

it "what set-check stores is a shape the hooks' read accepts"
check "[]" "$(run_py "$SR" <<'EOF'
rec = load_lib_module("run_record_core").read_run_record(ph.home_path(args[0]), args[0])
print(load_lib_module("programme_checks")._faults(rec["programme"]))
EOF
)"

echo "programme-checks.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
