#!/usr/bin/env bash
# auto unit test: auto reads both spinoff pane lines (KTD7) - the old `herdr agent pane: <id>` and the new `agent pane: <host> <id>`.

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

echo "agent-pane-line.test.sh"

WORK="$(mktemp -d -t auto-pane-line.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# parse <host> <text>: prints the pane id, or NONE.
parse() {
  "$PY" - "$AUTO_ROOT" "$1" "$2" <<'PYEOF'
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
th = load_lib_module("terminal_host")
print(th.agent_pane(sys.argv[3], sys.argv[2]) or "NONE")
PYEOF
}

OLD='▸   herdr agent pane: w2:p40 (launched with the brief)'
NEW='agent pane: herdr w2:p41'

it "old herdr line alone parses"
check "w2:p40" "$(parse herdr "$OLD")"

it "new line alone parses"
check "w2:p41" "$(parse herdr "$NEW")"

it "both lines present parse (a new spinoff on herdr prints both)"
check "w2:p41" "$(parse herdr "$(printf '%s\n%s\n' "$OLD" "$NEW")")"

it "the new line parses for rex"
check "block:01a1" "$(parse rex 'agent pane: rex block:01a1')"

it "the new line parses for ghostty"
check "term-9" "$(parse ghostty "$(printf 'noise\nagent pane: ghostty term-9\n')")"

it "a rex line is not taken as a herdr pane"
check "NONE" "$(parse herdr 'agent pane: rex block:01a1')"

it "the old herdr line is not taken as another host's pane"
check "NONE" "$(parse rex "$OLD")"

it "a line quoted mid-sentence does not parse"
check "NONE" "$(parse rex 'see the agent pane: rex block:01a1 line')"

it "no line parses to nothing"
check "NONE" "$(parse herdr 'nothing here')"

# end to end through HerdrHost.start_pane, which is where auto consumes the line
start_pane() {
  cat > "$WORK/spinoff" <<EOS
#!/bin/bash
printf '%s\n' "$1"
EOS
  chmod +x "$WORK/spinoff"
  "$PY" - "$AUTO_ROOT" "$WORK/spinoff" <<'PYEOF'
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
h = load_lib_module("host_herdr").HerdrHost()
print(h.start_pane([sys.argv[2]], 5).value["pane"] or "NONE")
PYEOF
}

it "start_pane reads an old-only spinoff"
check "w2:p40" "$(start_pane "$OLD")"

it "start_pane reads a new-only spinoff"
check "w2:p41" "$(start_pane "$NEW")"

echo
echo "agent-pane-line.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
