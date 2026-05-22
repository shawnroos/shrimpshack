#!/usr/bin/env bash
# claude-modes: /mode:statusline subcommand dispatcher.
#
# Routes /mode:statusline {install|uninstall|status} (default: status)
# to the corresponding scripts. Lives in lib/ following the same
# convention as lib/registry-dispatcher.sh (per
# feedback_slash_command_arg_substitution: no $-bearing logic in the
# command markdown).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLAUDE_MODES_PYTHON3="${CLAUDE_MODES_PYTHON3:-/usr/bin/python3}"

SETTINGS_FILE="${HOME}/.claude/settings.json"
MARKER_BEGIN="# >>> claude-modes statusline snippet (managed — do not edit between markers)"

# maint-3: shared parser (lib/statusline-target.sh). This caller's own
# policy: return 1 on any miss (it's a query helper, never fatal).
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/lib/statusline-target.sh"

__resolve_target() {
  local raw
  raw=$(claude_modes::statusline_extract_command_path "$SETTINGS_FILE") || return 1
  local resolved="${raw/#\~/$HOME}"
  [ ! -f "$resolved" ] && return 1
  printf '%s' "$resolved"
}

__status() {
  local target
  if ! target=$(__resolve_target); then
    echo "statusline: no statusline configured in ~/.claude/settings.json"
    echo "  (statusLine.command is absent, points at a missing file, or settings.json is missing)"
    return 0
  fi

  echo "statusline target:  ${target}"
  if grep -qF "$MARKER_BEGIN" "$target" 2>/dev/null; then
    echo "claude-modes snippet: INSTALLED"
    echo ""
    echo "Test the mode segment with:"
    echo "  echo '{\"workspace\":{\"current_dir\":\"\$PWD\"}}' | bash ${PLUGIN_ROOT}/scripts/statusline.sh"
  else
    echo "claude-modes snippet: NOT installed"
    echo ""
    echo "Install with:  /mode:statusline install"
    echo "  (mutates ${target} — backs up the original first)"
  fi
}

case "${1:-status}" in
  install)
    exec bash "${PLUGIN_ROOT}/scripts/install-statusline.sh"
    ;;
  uninstall)
    exec bash "${PLUGIN_ROOT}/scripts/uninstall-statusline.sh"
    ;;
  status|"")
    __status
    ;;
  -h|--help)
    cat <<'USAGE'
Usage: /mode:statusline [install | uninstall | status]

  install    — insert the claude-modes snippet into the user's statusline
               script (idempotent; backs up the original first).
  uninstall  — remove the snippet and reverse the printf augmentation
               (idempotent; backs up the original first).
  status     — (default) report whether the snippet is installed and
               where the user's statusline script lives.

Claude Code allows ONE statusline command per session. This subcommand
manages the snippet that composes into that single slot.
USAGE
    ;;
  *)
    echo "statusline-dispatcher: unknown subcommand: $1" >&2
    echo "Usage: /mode:statusline [install | uninstall | status]" >&2
    exit 2
    ;;
esac
