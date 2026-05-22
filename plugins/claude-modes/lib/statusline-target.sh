#!/usr/bin/env bash
# claude-modes: shared statusLine target-command extractor.
#
# maint-3: the Python parser that pulls the script path out of
# settings.json::statusLine.command was byte-identical across three files
# (lib/statusline-dispatcher.sh, scripts/install-statusline.sh,
# scripts/uninstall-statusline.sh), kept in sync only by a comment. This is
# the single shared copy. Each caller keeps its OWN error-handling policy
# (the dispatcher returns rc=1; install/uninstall call __die and add a
# writable check) — only the identical parse logic is centralized here.
#
# Usage:
#   . "${PLUGIN_ROOT}/lib/statusline-target.sh"
#   raw=$(claude_modes::statusline_extract_command_path "$SETTINGS_FILE") || handle-no-path
#
# Prints the raw (un-tilde-expanded) token on stdout; returns 1 if the
# settings file is missing/unparseable or no script-like token is found.
# Honors CLAUDE_MODES_PYTHON3 (default /usr/bin/python3).

set -uo pipefail

claude_modes::statusline_extract_command_path() {
  local settings_file="$1"
  local py="${CLAUDE_MODES_PYTHON3:-/usr/bin/python3}"

  [ -f "$settings_file" ] || return 1

  local raw
  raw=$(
    "$py" - "$settings_file" <<'PYEOF' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    cmd = (d.get("statusLine") or {}).get("command", "")
    parts = cmd.split()
    for p in parts:
        if p.endswith(".sh") or "/" in p:
            print(p)
            break
except Exception:
    pass
PYEOF
  )

  [ -z "$raw" ] && return 1
  printf '%s' "$raw"
}
