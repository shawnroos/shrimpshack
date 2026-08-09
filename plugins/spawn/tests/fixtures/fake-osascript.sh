#!/usr/bin/env bash
# fake-osascript.sh — stand-in for /usr/bin/osascript in spawn tests (U1).
#
# KTD2 captures the OpenRouter key through a macOS password dialog: osascript
# with a hidden answer, the value returned on stdout. Pointing lib/secrets.sh at
# this script through SPAWN_OSASCRIPT_BIN lets that path run headlessly — a real
# dialog cannot be driven from a test, and the Bash tool has no TTY to fall back
# to.
#
# It records argv (append-only) so the suite can assert two things about the
# dialog the plugin actually asks for: that it requests a HIDDEN answer, and
# that no secret is ever passed in — the prompt and title are the only argv, and
# the value travels back on stdout.
#
# Environment:
#   FAKE_OSASCRIPT_RECORD_DIR  where the argv record lands
#                              (default: $TMPDIR/fake-osascript-record)
#   FAKE_OSASCRIPT_ANSWER      the canned value returned in ok mode
#   FAKE_OSASCRIPT_MODE        ok | cancel | error | empty  (default: ok)
#                              cancel reproduces the real Cancel button: exit 1
#                                     with "User canceled. (-128)" on stderr and
#                                     NOTHING on stdout. Cancel and a scripting
#                                     failure both exit 1, so the -128 code on
#                                     stderr is the only thing that separates
#                                     them — secrets.sh reads it, and that is
#                                     the behaviour this mode pins.
#                              error  a non-cancel failure (exit 1, other stderr)
#                              empty  the operator pressed OK on a blank field:
#                                     exit 0 with an empty answer

set -uo pipefail

MODE="${FAKE_OSASCRIPT_MODE:-ok}"
REC_DIR="${FAKE_OSASCRIPT_RECORD_DIR:-${TMPDIR:-/tmp}/fake-osascript-record}"
ANSWER="${FAKE_OSASCRIPT_ANSWER:-fixture-dialog-answer}"

mkdir -p "$REC_DIR"

{
  echo "--- invocation ---"
  for a in "$@"; do printf '%s\n' "$a"; done
} >> "$REC_DIR/argv"

case "$MODE" in
  cancel)
    printf '0:53: execution error: User canceled. (-128)\n' >&2
    exit 1
    ;;
  error)
    printf '0:0: execution error: something else went wrong. (-1700)\n' >&2
    exit 1
    ;;
  empty)
    printf '\n'
    exit 0
    ;;
  *)
    printf '%s\n' "$ANSWER"
    exit 0
    ;;
esac
