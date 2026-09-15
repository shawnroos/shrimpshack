#!/usr/bin/env bash
# PostToolUse on any Linear MCP server: an agent's own Linear write can change a
# ticket's place on the work board, so the board is marked behind and the agent
# is told to run the unattended sync (KTD15).
#
# The sync itself never runs here (KTD2): it reads Linear page by page and
# creates panes, and a hook has neither the time nor anybody to ask. Every path
# exits 0.

set -uo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd -P)" || exit 0
LIB="$PLUGIN_DIR/lib"

for f in contain.sh binding.sh board-store.sh board-config.sh; do
    # shellcheck source=/dev/null
    [ -r "$LIB/$f" ] && . "$LIB/$f" 2>/dev/null
done

payload="$(cat 2>/dev/null || true)"

# The hooks.json matcher is broad on purpose, so the write test is repeated here.
# Reads are listed and everything else counts as a write: a tool Linear adds
# later marks the board behind, which costs one sync, rather than leaving it stale.
fields="$(printf '%s' "$payload" | python3 -c '
import sys, json, re
try:
    p = json.load(sys.stdin)
except Exception:
    sys.exit(1)
m = re.match(r"^mcp__(.+)__([^_][^\t\n]*)$", str(p.get("tool_name") or ""))
if not m or "linear" not in m.group(1).lower():
    sys.exit(1)
tool = m.group(2)
if tool.startswith(("get_", "list_", "search_", "extract_")) or tool == "whoami":
    sys.exit(1)
print(str(p.get("cwd") or "").replace("\n", " "))
' 2>/dev/null)" || exit 0

command -v herdr_linear::board_config_load >/dev/null 2>&1 || exit 0
herdr_linear::board_config_load >/dev/null 2>&1
[ "$?" -ne "$HERDR_LINEAR_BOARD_ABSENT" ] || exit 0

herdr_linear::board_mark_behind >/dev/null 2>&1 || true

# R26: the board is machine-wide, so the mark is made from anywhere, but a
# session outside the project roots is told nothing.
[ -n "$fields" ] || exit 0
command -v herdr_linear::path_signal >/dev/null 2>&1 || exit 0
[ "$(herdr_linear::path_signal "$fields")" = "inside" ] || exit 0

HERDR_LINEAR_BOARD_SYNC_LIB_PATH="$LIB/board-sync.sh" python3 -c '
import json, os
lib = os.environ["HERDR_LINEAR_BOARD_SYNC_LIB_PATH"]
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": (
        "That Linear write may have moved a ticket on the work board, so the board "
        "is now marked behind Linear. Bring it up to date with the unattended sync, "
        "from a shell: bash -c \x27. \"%s\" && herdr_linear::board_sync\x27. It asks "
        "nobody, never moves a pane in use, and records any question for the next "
        "/work command. If it exits 3, another sync is already running and nothing "
        "more is needed." % lib
    ),
}}))
' 2>/dev/null

exit 0
