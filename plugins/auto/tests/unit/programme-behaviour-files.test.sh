#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
check() { if [ "$1" = "$2" ]; then pass; else fail "expected [$1] got [$2]"; fi; }
has() { case "$2" in *"$1"*) pass ;; *) fail "expected to find [$1] in [$2]" ;; esac; }

echo "programme-behaviour-files.test.sh"

WORK="$(mktemp -d -t auto-behaviour-files.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
unset CLAUDE_AUTO_BEHAVIOURS_DIR CLAUDE_AUTO_SHIPPED_BEHAVIOURS_DIR 2>/dev/null || true
: > "$CLAUDE_AUTO_SECRETS_FILE"

N=0
fresh_dirs() {
  N=$((N + 1))
  SHIPPED="${WORK}/${N}/shipped"
  PERSONAL="${WORK}/${N}/personal"
  mkdir -p "$SHIPPED" "$PERSONAL"
  export SHIPPED PERSONAL
}

# load <expr over r>: prints the python expression's value after loading both folders
load() {
  "$PY" - "$AUTO_ROOT" "$1" <<'PYEOF' 2>&1
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
pf = load_lib_module("programme_behaviour_files")
r = pf.load_files(shipped_dir=os.environ["SHIPPED"], personal_dir=os.environ["PERSONAL"])
by = {e["id"]: e for e in r["entries"]}
rej = {x["id"]: x for x in r["rejected"]}
print(eval(sys.argv[2]))
PYEOF
}

GOOD_BODY='Do:
- check the diff before claiming
- name the file

Dont:
- skip the tests
'

it "happy path: frontmatter and Do/Dont body load as one entry"
fresh_dirs
cat > "${PERSONAL}/check-diff.md" <<EOF
---
when: a worker claims a unit
trigger: start
applies_to: workers
checks:
  - pm: the diff was read
  - agent: tests ran
stop: never past the plan
---
${GOOD_BODY}
EOF
check "start|workers|personal|file|['check the diff before claiming', 'name the file']|['skip the tests']|2" \
  "$(load 'str(by["check-diff"]["when"]["trigger"]) + "|" + by["check-diff"]["applies_to"] + "|" + by["check-diff"]["layer"] + "|" + by["check-diff"]["source"] + "|" + str(by["check-diff"]["do"]) + "|" + str(by["check-diff"]["dont"]) + "|" + str(len(by["check-diff"]["when"]["checks"]))')"

it "a check keeps who verifies it"
check "[{'text': 'the diff was read', 'by': 'pm'}, {'text': 'tests ran', 'by': 'agent'}]" \
  "$(load 'by["check-diff"]["when"]["checks"]')"

it "at is the file mtime as a UTC ISO second"
check "True" "$(load 'bool(__import__("re").match(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$", by["check-diff"]["at"]))')"

it "a file with no trigger loads with trigger claim"
fresh_dirs
printf -- '---\nwhen: work is claimed\n---\nDo:\n- be careful\n' > "${PERSONAL}/careful.md"
check "claim|both" "$(load 'by["careful"]["when"].get("trigger", "claim") + "|" + by["careful"]["applies_to"]')"

it "a Don't: heading with an apostrophe fills dont"
fresh_dirs
printf -- "---\nwhen: x\n---\nDo:\n- a thing\n\nDon't:\n- another\n" > "${PERSONAL}/apos.md"
check "['another']" "$(load 'by["apos"]["dont"]')"

it "a shipped file loads with layer shipped"
fresh_dirs
printf -- '---\nwhen: work is claimed\n---\nDo:\n- be careful\n' > "${SHIPPED}/careful.md"
check "shipped|file" "$(load 'by["careful"]["layer"] + "|" + by["careful"]["source"]')"

it "empty folders load with no entries and no rejections"
fresh_dirs
check "0 0" "$(load 'str(len(r["entries"])) + " " + str(len(r["rejected"]))')"

it "missing folders load with no error"
fresh_dirs
rmdir "$SHIPPED" "$PERSONAL"
check "0 0" "$(load 'str(len(r["entries"])) + " " + str(len(r["rejected"]))')"

it "an unknown key rejects that file and a valid sibling still loads"
fresh_dirs
printf -- '---\nwhen: x\nflavour: spicy\n---\nDo:\n- a thing\n' > "${PERSONAL}/odd.md"
printf -- '---\nwhen: x\n---\nDo:\n- a thing\n' > "${PERSONAL}/fine.md"
check "unknown_key|True" "$(load 'rej["odd"]["reason"] + "|" + str("fine" in by)')"

it "a do line naming a protected escalation rejects"
fresh_dirs
printf -- '---\nwhen: x\n---\nDo:\n- run the production deploy\n' > "${PERSONAL}/ship.md"
check "protected_escalation" "$(load 'rej["ship"]["reason"]')"

it "a comms line naming a protected escalation rejects a file entry"
fresh_dirs
printf -- '---\nwhen: x\ncomms:\n  - tell them to deploy to production\n---\nDo:\n- a thing\n' > "${PERSONAL}/talk.md"
check "protected_escalation" "$(load 'rej["talk"]["reason"]')"

it "a formats line naming a protected escalation rejects a file entry"
fresh_dirs
printf -- '---\nwhen: x\nformats:\n  - always deploy to production first\n---\nDo:\n- a thing\n' > "${PERSONAL}/fmt.md"
check "protected_escalation" "$(load 'rej["fmt"]["reason"]')"

it "ordinary comms and formats lines load"
fresh_dirs
printf -- '---\nwhen: x\nformats:\n  - one table per answer\ncomms:\n  - lead with the action\n---\nDo:\n- a thing\n' > "${PERSONAL}/plain.md"
check "['one table per answer']|['lead with the action']" "$(load 'str(by["plain"]["formats"]) + "|" + str(by["plain"]["comms"])')"

it "a file name that is not a valid id rejects"
fresh_dirs
printf -- '---\nwhen: x\n---\nDo:\n- a thing\n' > "${PERSONAL}/Bad_Name.md"
check "bad_value|id" "$(load 'rej["Bad_Name"]["reason"] + "|" + str(rej["Bad_Name"]["detail"])')"

it "a file with no when rejects with missing_field"
fresh_dirs
printf -- '---\ntrigger: start\n---\nDo:\n- a thing\n' > "${PERSONAL}/nowhen.md"
check "missing_field|when" "$(load 'rej["nowhen"]["reason"] + "|" + str(rej["nowhen"]["detail"])')"

it "a file with no frontmatter rejects without raising"
fresh_dirs
printf 'Do:\n- a thing\n' > "${PERSONAL}/bare.md"
check "missing_field" "$(load 'rej["bare"]["reason"]')"

it "a file using examples rejects with unknown_key"
fresh_dirs
printf -- '---\nwhen: x\nexamples: nope\n---\nDo:\n- a thing\n' > "${PERSONAL}/ex.md"
check "unknown_key|examples" "$(load 'rej["ex"]["reason"] + "|" + str(rej["ex"]["detail"])')"

it "a check without a pm or agent prefix rejects"
fresh_dirs
printf -- '---\nwhen: x\nchecks:\n  - someone looked\n---\nDo:\n- a thing\n' > "${PERSONAL}/chk.md"
check "bad_value" "$(load 'rej["chk"]["reason"]')"

it "a file with neither Do nor Dont rejects"
fresh_dirs
printf -- '---\nwhen: x\n---\n' > "${PERSONAL}/empty.md"
printf -- '---\nwhen: x\n---\nJust prose.\n' > "${PERSONAL}/prose.md"
check "missing_field|bad_value" "$(load 'rej["empty"]["reason"] + "|" + rej["prose"]["reason"]')"

it "non-markdown files are ignored"
fresh_dirs
printf 'x' > "${PERSONAL}/notes.txt"
check "0 0" "$(load 'str(len(r["entries"])) + " " + str(len(r["rejected"]))')"

it "the personal folder defaults beside the store file and honours the env override"
fresh_dirs
mkdir -p "${WORK}/personal/behaviours"
printf -- '---\nwhen: x\n---\nDo:\n- a thing\n' > "${WORK}/personal/behaviours/beside.md"
OUT="$("$PY" - "$AUTO_ROOT" <<'PYEOF' 2>&1
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
pf = load_lib_module("programme_behaviour_files")
a = [e["id"] for e in pf.load_files(shipped_dir="/nonexistent")["entries"]]
os.environ["CLAUDE_AUTO_BEHAVIOURS_DIR"] = os.environ["PERSONAL"]
b = pf.personal_dir()
print(a, b == os.environ["PERSONAL"])
PYEOF
)"
check "['beside'] True" "$OUT"

it "integration: every shipped file in plugins/auto/behaviours loads with zero rejections"
SHIPPED_REAL="${AUTO_ROOT}/behaviours"
COUNT=0
[ -d "$SHIPPED_REAL" ] && COUNT="$(find "$SHIPPED_REAL" -maxdepth 1 -name '*.md' | wc -l | tr -d ' ')"
if [ "$COUNT" -eq 0 ]; then
  CURRENT="integration: no shipped files yet (${SHIPPED_REAL}); vacuous pass"
  pass
else
  OUT="$("$PY" - "$AUTO_ROOT" <<'PYEOF' 2>&1
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
pf = load_lib_module("programme_behaviour_files")
r = pf.load_files(shipped_dir=pf.shipped_dir(), personal_dir="/nonexistent")
print(len(r["entries"]), r["rejected"])
PYEOF
)"
  check "${COUNT} []" "$OUT"
fi

echo ""
echo "programme-behaviour-files.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
