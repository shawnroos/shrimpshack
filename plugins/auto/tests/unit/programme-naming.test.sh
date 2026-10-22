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

echo "programme-naming.test.sh"

WORK="$(mktemp -d -t auto-naming.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
: > "$CLAUDE_AUTO_SECRETS_FILE"

named() {
  "$PY" - "$AUTO_ROOT" "$@" <<'PYEOF' 2>&1
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
prog = load_lib_module("programme")
text, needs = sys.argv[2], json.loads(sys.argv[3])
if "WIDEN" in needs:
    needs = [n for n in needs if n != "WIDEN"] + list(prog._widen_word({"widening": True}))
try:
    prog.require_named({"prompt_id": "p1", "quote": text}, *needs)
    print("PASS")
except prog.ProgrammeError:
    print("REFUSE")
PYEOF
}

expect() {
  it "$1: \"$2\" for $3"
  check "$1" "$(named "$2" "$3")"
}

expect PASS "set merge_pr to act" '["merge_pr", "act"]'
expect PASS "set merge-pr to act" '["merge_pr", "act"]'
expect PASS "set merge pr to act" '["merge_pr", "act"]'
expect PASS "set MergePR to act" '["merge_pr", "act"]'
expect PASS "set merge_pr to act_and_tell" '["merge_pr", "act_and_tell"]'
expect PASS "set merge_pr to act and tell" '["merge_pr", "act_and_tell"]'
expect REFUSE "set merge_pr to act_and_tell please" '["merge_pr", "act"]'
expect REFUSE "set merge_pr to act and tell please" '["merge_pr", "act"]'
expect REFUSE "actually leave merge_pr alone" '["merge_pr", "act"]'
expect REFUSE "nevertheless merge_pr stays" '["merge_pr", "never"]'
expect PASS "set merge_pr to never" '["merge_pr", "never"]'
expect REFUSE "do NOT widen merge_pr past propose, never act" '["merge_pr", "act", "widen"]'
expect REFUSE "widen merge_pr but do not act" '["merge_pr", "act", "widen"]'
expect REFUSE "widen merge_pr, don't act" '["merge_pr", "act", "widen"]'
expect REFUSE "don't widen merge_pr to act" '["merge_pr", "act", "widen"]'
expect PASS "yes widen merge_pr to act" '["merge_pr", "act", "widen"]'
expect PASS "yes widening merge_pr to act" '["merge_pr", "act", "WIDEN"]'
expect PASS "widened merge_pr to act" '["merge_pr", "act", "WIDEN"]'
expect REFUSE "not widening merge_pr to act" '["merge_pr", "act", "WIDEN"]'
expect REFUSE "merge_pr to act, widen-ish" '["merge_pr", "act", "WIDEN"]'
expect PASS "drop AI-80 please" '[["AI-80", "linear:AI-80"]]'
expect PASS "drop linear:AI-80." '[["AI-80", "linear:AI-80"]]'
expect REFUSE "drop AI-801" '[["AI-80", "linear:AI-80"]]'
expect REFUSE "drop linear:AI-801" '[["AI-80", "linear:AI-80"]]'
expect PASS "set cadence_seconds to 180" '["cadence_seconds", "180"]'
expect REFUSE "set cadence_seconds to 1800" '["cadence_seconds", "180"]'
expect REFUSE "set cadence_seconds to 18" '["cadence_seconds", "180"]'
expect PASS "adopt auto-merge" '["auto-merge"]'
expect REFUSE "adopt auto-merge-docs-only" '["auto-merge"]'
expect PASS "adopt verified.lookup for shrimpshack" '["shrimpshack", "verified.lookup"]'
expect REFUSE "adopt verified.lookups for shrimpshack" '["shrimpshack", "verified.lookup"]'
expect REFUSE "drop Файл правка" '[["Файл правка"]]'
expect REFUSE "drop it" '["!!!"]'

refuse_by_id() {
  "$PY" - "$AUTO_ROOT" "$1" "$2" "$3" <<'PYEOF' 2>&1
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
pn = load_lib_module("programme_naming")
quote, choice, typed_at = sys.argv[2:5]
items = {"linear:WEB-12": {"state": "handed", "title": "Editor places missed crop"},
         "linear:WEB-99": {"state": "open", "title": "Unrelated work item"}}
ask = {"at": "2026-10-20T10:00:00Z", "facts_at": "2026-10-20T10:00:00Z"}
print("REFUSE" if pn.item_refusal(quote, items, "linear:WEB-12", choice, prompt_at=typed_at, ask=ask) else "PASS")
PYEOF
}
FRESH="2026-10-20T10:05:00Z"
STALE="2026-10-20T09:55:00Z"
it "an id reply with the choice word approves"
check "PASS" "$(refuse_by_id "ship WEB-12" ship "$FRESH")"
it "an id reply with words between the choice word and the id approves"
check "PASS" "$(refuse_by_id "decline the WEB-12 change" decline "$FRESH")"
it "an id reply carrying the opposite choice word is refused"
check "REFUSE" "$(refuse_by_id "decline WEB-12" ship "$FRESH")"
it "an id reply with the choice word negated is refused"
check "REFUSE" "$(refuse_by_id "do not ship WEB-12" ship "$FRESH")"
it "an id-only reply with no choice word is refused"
check "REFUSE" "$(refuse_by_id "WEB-12 looks risky" ship "$FRESH")"
it "an id reply typed before the ask's current facts were set is refused"
check "REFUSE" "$(refuse_by_id "ship WEB-12" ship "$STALE")"
it "an id reply naming both choices is refused"
check "REFUSE" "$(refuse_by_id "ship or decline WEB-12" ship "$FRESH")"

it "a missing prompt approves nothing to check"
check "PASS" "$("$PY" - "$AUTO_ROOT" <<'PYEOF' 2>&1
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
load_lib_module("programme").require_named(None, "merge_pr")
print("PASS")
PYEOF
)"

echo ""
echo "programme-naming.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
