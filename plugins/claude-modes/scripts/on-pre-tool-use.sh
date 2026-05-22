#!/usr/bin/env bash
# claude-modes hook shim: PreToolUse on Task|Skill|Agent
# Reads event JSON from stdin, dispatches to lib/gate-delegation.sh
# U1 stub — real implementation lands in U7.
#
# Cost-of-being-installed guarantee: very first check is the modes-dir presence
# gate, before any subprocess work. See plan System-Wide Impact.

[ -d "${HOME}/.claude/modes" ] || exit 0

# Real dispatch in U7:
#   exec bash "$(dirname "$0")/../lib/gate-delegation.sh"
exit 0
