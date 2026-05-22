#!/usr/bin/env bash
# claude-modes V2 hook shim: UserPromptSubmit (R25 prose injection).
#
# Responsibilities (thin shim only):
#   1. Cost-of-being-installed presence gate (modes-dir check first thing).
#   2. PROSE_INJECTION_DISABLED env-var escape hatch.
#   3. Read JSON event from stdin → save to a 0600 tmpfile.
#   4. Dispatch to lib/inject-prose.sh with the tmpfile path as argv.
#   5. Always exit 0 (rel-001 contract — UserPromptSubmit must never block).
#
# Output contract: a single JSON object {"systemMessage": "..."} on stdout
# if injection is warranted, else no output. Errors → stderr, exit 0.

# Cost-of-being-installed: this is the absolute first check, before any
# subprocess work (python3, mktemp). If a user doesn't use modes, the hook
# costs one stat syscall + one process exec per prompt.
set -uo pipefail

[ -d "${HOME}/.claude/modes" ] || exit 0

# Escape hatch for users (or tests) who want to suppress injection without
# uninstalling the plugin. Honoured before mktemp so a disabled hook is as
# cheap as the presence gate above.
[ "${PROSE_INJECTION_DISABLED:-}" = "1" ] && exit 0

# Resolve the plugin root. Under the harness, CLAUDE_PLUGIN_ROOT is set by
# Claude Code. Under direct invocation (tests, debugging), fall back to the
# script's own location.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-${SCRIPT_DIR}/..}"

# Stash stdin into a 0600 tmpfile so the inject-prose library can parse it
# with Python without any heredoc / shell-quoting hazard. umask 077 ensures
# the file is 0600 from creation — important because the JSON event may
# contain prompt text that should not be world-readable.
stdin_file=""
if stdin_file=$( ( umask 077 && mktemp -t claude-modes-stdin.XXXXXX ) 2>/dev/null ); then
  trap 'rm -f "$stdin_file"' EXIT
  cat > "$stdin_file"
else
  # If we can't even allocate a tmpfile, bail silently per rel-001.
  exit 0
fi

# Dispatch to the prose-injection library. The library is responsible for
# all per-mode reads, marker handling, and JSON emission. We intentionally
# DO NOT `exec` here: we want our EXIT trap to fire so the tmpfile is
# cleaned up after the library returns.
bash "${PLUGIN_ROOT}/lib/inject-prose.sh" "$stdin_file" || true

# rel-001: never propagate errors to UserPromptSubmit.
exit 0
