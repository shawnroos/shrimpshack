#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
PROG="${AUTO_ROOT}/lib/programme.py"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
check() { if [ "$1" = "$2" ]; then pass; else fail "expected [$1] got [$2]"; fi; }
has() { case "$2" in *"$1"*) pass ;; *) fail "expected to find [$1] in [$2]" ;; esac; }
lacks() { case "$2" in *"$1"*) fail "did not expect [$1] in [$2]" ;; *) pass ;; esac; }

echo "refusal-fixes.test.sh"

WORK="$(mktemp -d -t auto-refusal-fixes.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_MACHINE="studio"
export CLAUDE_CODE_SESSION_ID="sess-pm"
unset HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH CLAUDE_AUTO_REPO 2>/dev/null || true

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
sys.path.insert(0, os.path.join(sys.argv[1], 'tests', 'fixtures'))
from programme_prompts import append_prompt as fixture_prompt
ph = load_lib_module("programme_home")
args = sys.argv[2:]
$(cat)
PYEOF
}

OUT=""
CODE=0
prog() {
  OUT="$("$PY" "$PROG" "$@" 2>&1)"
  CODE=$?
}
last_line() { printf '%s\n' "$OUT" | tail -n 1; }

RUN="$(run_py <<'EOF'
print(ph.create_programme(["w2"], "sess-pm")["run"])
EOF
)"

DESC="$("$PY" "$PROG" describe 2>/dev/null)"
VERBS="$("$PY" -c 'import json,sys; print(" ".join(sorted(json.load(sys.stdin)["verbs"])))' <<< "$DESC" 2>&1)"

it "every registered programme verb has an entry in the fix table"
MISSING="$(run_py $VERBS <<'EOF'
fixes = load_lib_module("programme_fixes")
print(" ".join(v for v in args if v not in fixes.FIXES))
EOF
)"
check "" "$MISSING"

it "the fix table names no verb that is not registered"
check "" "$(run_py $VERBS <<'EOF'
fixes = load_lib_module("programme_fixes")
print(" ".join(sorted(set(fixes.FIXES) - set(args))))
EOF
)"

it "every programme.sh verb named in a fix is registered, or become-pm"
NAMED="$(run_py <<'EOF'
fixes = load_lib_module("programme_fixes")
for verb in fixes.FIXES:
    print(fixes.fix_for(verb))
print(fixes.FALLBACK)
EOF
)"
NAMED="${NAMED}
$(cd "${AUTO_ROOT}/lib" && grep -hE 'fix=|_fix\(|return \(?f?"' programme*.py verb_cli.py)"
UNKNOWN=""
for verb in $(printf '%s\n' "$NAMED" | grep -oE 'programme\.sh [a-z][a-z-]*' | awk '{print $2}' | sort -u); do
  case " $VERBS become-pm " in *" $verb "*) ;; *) UNKNOWN="$UNKNOWN $verb" ;; esac
done
check "" "$UNKNOWN"

it "a verb missing from the table falls back to become-pm"
check "programme.sh become-pm" "$(run_py <<'EOF'
print(load_lib_module("programme_fixes").fix_for("no-such-verb"))
EOF
)"

it "a non-driving session running set-waiting refuses at exit 1"
CLAUDE_CODE_SESSION_ID="sess-stranger" prog set-waiting w2:item --who shawn --run "$RUN"
check 1 "$CODE"
it "the refusal keeps its wording"
has "only the programme's driving session may run this verb" "$OUT"
it "the fix line comes last, on its own line, and names become-pm"
check "fix: programme.sh become-pm" "$(last_line)"

P_CRON="$(run_py "$RUN" <<'EOF'
print(fixture_prompt(args[0], "sess-pm", "wake up and sweep the space", "cron")["prompt_id"])
EOF
)"

it "adopt-rule citing an unverified prompt refuses at exit 1"
prog adopt-rule docs-verified --prompt "$P_CRON" --run "$RUN"
check 1 "$CODE"
it "its fix names approval-label for the same command and a picker"
has "fix: run \`programme.sh approval-label adopt-rule docs-verified\`" "$(last_line)"
has "AskUserQuestion" "$(last_line)"

it "adopt-rule citing an unknown prompt id gets the same approval-label fix"
prog adopt-rule docs-verified --prompt p000000 --run "$RUN"
check 1 "$CODE"
has "programme.sh approval-label adopt-rule docs-verified" "$(last_line)"

it "a verb a pick cannot approve gets a typed-prompt fix, not approval-label"
prog approval-label record-instruction
check 1 "$CODE"
has "fix: " "$(last_line)"
lacks "approval-label" "$(last_line)"

it "a refusal with no specific fix prints the verb's table entry"
TABLE="$(run_py <<'EOF'
print(load_lib_module("programme_fixes").fix_for("merge-item"))
EOF
)"
prog merge-item w2:nope w2:nope --run "$RUN"
check 1 "$CODE"
check "fix: ${TABLE}" "$(last_line)"
it "that table entry is not the bare fallback"
lacks "become-pm" "$TABLE"

it "bad arguments still exit 2, with the table entry as the fix"
prog set-waiting --run "$RUN"
check 2 "$CODE"
has "bad arguments" "$OUT"
has "fix: " "$(last_line)"

it "an unknown subcommand still exits 2 with no fix line"
prog no-such-verb
check 2 "$CODE"
lacks "fix:" "$OUT"

HOME_DIR="${CLAUDE_AUTO_DATA_DIR}/programmes/${RUN}"
touch "${HOME_DIR}/.compact-flag"
it "a write verb under the compact flag refuses at exit 1, wording unchanged"
prog set-now "testing" --run "$RUN"
check 1 "$CODE"
has "then run \`programme.py rules --ack\`" "$OUT"
it "its fix is rules --ack, last on stderr (the rules go to stdout)"
check "fix: programme.sh rules --ack" "$("$PY" "$PROG" set-now "testing" --run "$RUN" 2>&1 >/dev/null | tail -n 1)"
rm -f "${HOME_DIR}/.compact-flag"

it "a successful verb prints no fix line"
prog describe
check 0 "$CODE"
lacks "fix:" "$OUT"

it "run_record.py refusals print no fix line (the table is programme-only)"
OUT="$("$PY" "${AUTO_ROOT}/lib/run_record.py" show --run no-such-run 2>&1)"
lacks "fix:" "$OUT"

echo
echo "TOTAL: $((PASS + FAIL))  PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
