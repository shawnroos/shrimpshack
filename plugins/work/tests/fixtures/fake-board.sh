#!/usr/bin/env bash
# Stand-in for the `board` binary in hook tests.
#
#   FAKE_BOARD_LOG       file; each call appends `argv: ...` and `cwd: ...`
#                        lines, and stdin is appended to "$FAKE_BOARD_LOG.stdin"
#   FAKE_BOARD_EXIT      exit code (default 0); 64 mimics board 0.17.0
#   FAKE_BOARD_SLEEP     seconds to sleep before exiting, to mimic a hang
#   FAKE_BOARD_RESPONSE  file whose bytes are printed on stdout
#
# Exit 64 skips reading stdin, because board 0.17.0 rejects the subcommand
# before it reads anything.

log="${FAKE_BOARD_LOG:-/dev/null}"
printf 'argv: %s\n' "$*" >> "$log"
# $PWD, not pwd -P: the hook cd's to the payload's literal path, and on macOS
# /tmp resolves to /private/tmp.
printf 'cwd: %s\n' "$PWD" >> "$log"

code="${FAKE_BOARD_EXIT:-0}"
if [ "$code" != 64 ]; then
    cat >> "$log.stdin"
fi
[ -n "${FAKE_BOARD_SLEEP:-}" ] && sleep "$FAKE_BOARD_SLEEP"
[ -n "${FAKE_BOARD_RESPONSE:-}" ] && cat "$FAKE_BOARD_RESPONSE"
exit "$code"
