#!/bin/sh
[ -f "${0%/*}/fake.env" ] && . "${0%/*}/fake.env"
{ printf 'board'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >> "${FAKE_CALLS:-/dev/null}"
if [ -n "${FAKE_BOARD_FILE:-}" ]; then
  cat "$FAKE_BOARD_FILE"
  exit "${FAKE_BOARD_EXIT:-0}"
fi
cat "$FAKE_FIXTURES/board-unsupported.json" >&2
exit "${FAKE_BOARD_EXIT:-1}"
