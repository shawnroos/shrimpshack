#!/usr/bin/env bash
# SessionEnd: let Linear catch up with the repository.
#
# WHY SessionEnd AND NOT Stop (KTD14)
# `Stop` can block a session from ending. R19 says nothing this plugin installs
# may do that, and a tracker write is the last thing that should be able to hold
# a terminal open. `SessionEnd` cannot block, and this hook additionally exits 0
# on every path so that even a crash inside it is invisible to the session.
#
# THIS HOOK NEVER PROMPTS (KTD13)
# It runs while a session is ending; there is nobody to answer. Anything needing
# judgment is recorded against the binding and surfaced by the grounding hook at
# the start of the next session in that worktree.
#
# SHADOW MODE IS ON UNLESS A WORKTREE IS EXPLICITLY LISTED. See lib/reconcile.sh.

set -uo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd -P)" || exit 0
LIB="$PLUGIN_DIR/lib"
for f in contain.sh secrets.sh binding.sh linear.sh reconcile.sh states.sh; do
    # shellcheck source=/dev/null
    [ -r "$LIB/$f" ] && . "$LIB/$f" 2>/dev/null
done

payload="$(cat 2>/dev/null || true)"
cwd="$(printf '%s' "$payload" | python3 -c '
import sys, json
try:
    print(json.load(sys.stdin).get("cwd", "") or "")
except Exception:
    print("")
' 2>/dev/null)"
[ -n "$cwd" ] || exit 0

command -v herdr_linear::reconcile >/dev/null 2>&1 || exit 0

# The untidy states first. Nothing called classify before this line, so
# misplaced and stale were states production never set and reconcile's
# suspension had nothing to read -- a ticket someone cancelled mid-session came
# back as In Progress at session end. The workspace id is taken straight from
# the environment rather than resolved through herdr: a closing session should
# not wait on an IPC round trip, and an id that no longer resolves makes
# check_placement answer UNKNOWN, which suspends nothing and clears nothing.
if command -v herdr_linear::classify >/dev/null 2>&1; then
    suspended="$(herdr_linear::classify "$cwd" "${HERDR_WORKSPACE_ID:-}" 2>/dev/null)"
    case $? in
        "$HERDR_LINEAR_STATE_MISPLACED"|"$HERDR_LINEAR_STATE_STALE")
            # ground.sh is silent for every state but `bound`, so a suspension
            # raised here would otherwise leave the next session with no
            # explanation for why the plugin went quiet. The shadow log is the
            # only human-visible surface a closing session has.
            herdr_linear::_shadow_log "SUSPENDED $(printf '%s' "$suspended" | tr '\n' ' ')"
            exit 0
            ;;
    esac
fi

# Nothing is printed. A SessionEnd hook has no channel to the model, and stray
# output on a closing session is noise in someone's terminal.
herdr_linear::reconcile "$cwd" >/dev/null 2>&1
rc=$?

# Once bound, notice whether the description has fallen behind the work. Records
# a note; never writes the description and never prompts. Both are deliberate:
# a hook cannot author prose, and KTD13 keeps hooks silent.
#
# SKIPPED when reconcile recorded a judgment. pending_judgment is one slot and
# set-judgment replaces it wholesale, so running both evicted the squash-merge
# question -- the headline case the judgment exists for -- with a description
# nudge, every time.
if [ "$rc" -ne "$HERDR_LINEAR_RECONCILE_PROPOSED" ]; then
    herdr_linear::nudge_description "$cwd" >/dev/null 2>&1
fi

exit 0
