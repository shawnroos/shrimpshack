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
#   FAKE_LAUNCHCTL_LIST       file holding `list` rows, one per line, in the
#                             real binary's TAB-separated "PID Status Label"
#                             shape. Absent or empty => no jobs are loaded,
#                             which is the unsupervised machine.
#
# WHY `list` IS MODELLED ON THE REAL OUTPUT, TABS AND ALL. Supervision is
# detected by matching a pid against column 1 of `launchctl list`. A fixture
# that printed a friendlier shape would pin the parser to the fixture instead
# of to launchd, and the one thing that must not drift here is the column the
# pid is read from. Verified against the real binary on this machine: a loaded
# job prints "<pid>\t<status>\t<label>", and `list <label>` for an unknown
# label exits 113 rather than 1.
set -uo pipefail

RECORD="${FAKE_LAUNCHCTL_RECORD:-${TMPDIR:-/tmp}/fake-launchctl-argv}"

printf '%s\n' "$*" >> "$RECORD"

case "${1:-}" in
    unload) exit "${FAKE_LAUNCHCTL_UNLOAD_RC:-0}" ;;
    load)   exit "${FAKE_LAUNCHCTL_LOAD_RC:-0}" ;;
    list)
        listfile="${FAKE_LAUNCHCTL_LIST:-}"
        if [ -z "${2:-}" ]; then
            [ -n "$listfile" ] && [ -f "$listfile" ] && cat "$listfile"
            exit 0
        fi
        # `list <label>`: 113 when the label is not loaded, matching the real
        # binary — the caller distinguishes "no such job" from "job is broken".
        if [ -n "$listfile" ] && [ -f "$listfile" ] \
           && awk -F'\t' -v l="$2" '$3 == l { found = 1 } END { exit !found }' "$listfile"; then
            exit 0
        fi
        exit 113 ;;
    *)      exit 0 ;;
esac
