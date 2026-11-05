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

echo "programme-checks.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
