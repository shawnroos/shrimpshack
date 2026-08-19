#!/usr/bin/env bash
# Per-repository record of whether stacked pull requests are usable.
#
# Only an explicit "unavailable" record suppresses. Every other outcome — no
# record, unreadable file, unwritable state dir — reports usable, so a broken
# cache costs a spurious ask rather than silently costing every ask.
set -uo pipefail

STATE_DIR="${STACKUP_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.claude/state}/stackup}"

_key() {
  local remote
  # Falling back to a constant would give every remote-less repo the same key, so
  # one record-unavailable would silence the ask in all of them.
  remote="$(git remote get-url origin 2>/dev/null)"
  [ -n "$remote" ] || remote="$(git remote -v 2>/dev/null | awk 'NR==1{print $2}')"
  [ -n "$remote" ] || remote="$(git rev-parse --show-toplevel 2>/dev/null)"
  [ -n "$remote" ] || remote="$PWD"
  printf '%s' "$remote" | shasum | cut -d' ' -f1
}

case "${1:-status}" in
  status)
    f="$STATE_DIR/$(_key)"
    [ -r "$f" ] && [ "$(cat "$f" 2>/dev/null)" = "unavailable" ] && { echo unavailable; exit 0; }
    echo usable
    ;;
  record-unavailable)
    # The hooks never run `gh stack` themselves, so without this entrypoint the
    # suppression branch is unreachable and the repo is asked forever.
    mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
    printf 'unavailable' > "$STATE_DIR/$(_key)" 2>/dev/null || exit 0
    ;;
  forget)
    rm -f "$STATE_DIR/$(_key)" 2>/dev/null || true
    ;;
esac
exit 0
