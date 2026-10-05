#!/usr/bin/env bash
# PostToolUse on any Linear MCP server: hand the write to `board linear report`.
#
# stdin is inherited, never piped through a variable, so a large tool_response
# reaches the board whole. A missing board is skipped and an old one exits 64 at
# once; both are silent because every path exits 0 and nothing reaches stdout.

command -v board >/dev/null 2>&1 || exit 0
board linear report >/dev/null 2>&1
exit 0
