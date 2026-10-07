#!/usr/bin/env bash
# Pins /usr/bin/python3: a bare `python3` on macOS may resolve to a Homebrew
# interpreter that lacks the modules auto relies on.

set -uo pipefail

CLAUDE_AUTO_PYTHON3="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

auto::programme() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  "$CLAUDE_AUTO_PYTHON3" "${script_dir}/programme.py" "$@"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  auto::programme "$@"
fi
