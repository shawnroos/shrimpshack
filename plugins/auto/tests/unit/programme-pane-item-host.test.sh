#!/usr/bin/env bash
# auto unit test: a proposed pane item is minted with the pane's own host prefix (KTD5).

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

echo "programme-pane-item-host.test.sh"

for v in $(env | grep -oE '^(HERDR|REX|GHOSTTY|AUTO_TEST|HOST_FAKE)_[A-Z_]*'); do unset "$v"; done
unset CMUX_WORKSPACE_ID TERM_PROGRAM 2>/dev/null || true

item_id() {
  AUTO_ROOT="$AUTO_ROOT" "$PY" -I - "$@" <<'PYEOF'
import os, sys
sys.path.insert(0, os.environ["AUTO_ROOT"] + "/lib")
from _bootstrap import load_lib_module
ps = load_lib_module("programme_sources")
pane_id, workspace, host = sys.argv[1], sys.argv[2], sys.argv[3] or None
pane = {"pane_id": pane_id, "workspace_id": workspace, "terminal_id": None, "cwd": None, "title": "t",
        "label": None, "agent": "claude", "owner": {"session_id": None, "source": None}}
if host:
    pane["host"] = host
out = ps.propose({"items": {}}, [pane], {"panes": set(), "session": None}, {pane_id: {}}, None)
print(out["proposals"][0]["item"])
PYEOF
}

it "a herdr pane keeps the herdr:<ws>/<pane> id"
check "herdr:w1/p2" "$(item_id w1:p2 w1 "")"

it "a pane that names no host reads as herdr"
check "herdr:w1/p2" "$(item_id w1:p2 w1 herdr)"

it "a Rex block gets a rex: id with its session"
check "rex:sess-1/blk-9" "$(item_id blk-9 sess-1 rex)"

it "a Ghostty terminal gets a ghostty: id with its window"
check "ghostty:win-3/term-7" "$(item_id term-7 win-3 ghostty)"

it "the host detected for the session prefixes a pane that names none"
check "rex:sess-1/blk-9" "$(REX_SESSION=sess-1 item_id blk-9 sess-1 "")"

echo
echo "programme-pane-item-host.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
