#!/usr/bin/env bash
# fake-launchctl.sh — recording stand-in for /bin/launchctl (U3 step 6, R28).
#
# NOTHING HERE TOUCHES REAL launchd. A suite that ran `launchctl load` for real
# would load the operator's own agent on the machine it is testing on — the one
# agent this whole step is about, and one that is deliberately unloaded right
# now.
#
# WHY IT RECORDS ARGV, IN ORDER. "It reloaded the agent" is a claim about a
# SEQUENCE: an unload followed by a load. A fixture that only reported success
# would make "unload then load, in that order" unassertable, and a load without
# the unload silently leaves launchd running the OLD command.
#
# Records APPEND, never truncate.
#
# Environment:
#   FAKE_LAUNCHCTL_RECORD     file the argv lines are appended to
#                             (default: $TMPDIR/fake-launchctl-argv)
#   FAKE_LAUNCHCTL_UNLOAD_RC  exit status for `unload` (default 0). The real
#                             binary fails when the job is not loaded, which is
#                             an ordinary state the caller must tolerate.
#   FAKE_LAUNCHCTL_LOAD_RC    exit status for `load` (default 0)
set -uo pipefail

RECORD="${FAKE_LAUNCHCTL_RECORD:-${TMPDIR:-/tmp}/fake-launchctl-argv}"

printf '%s\n' "$*" >> "$RECORD"

case "${1:-}" in
    unload) exit "${FAKE_LAUNCHCTL_UNLOAD_RC:-0}" ;;
    load)   exit "${FAKE_LAUNCHCTL_LOAD_RC:-0}" ;;
    *)      exit 0 ;;
esac
