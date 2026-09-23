#!/usr/bin/env bash
# The untidy states: a binding that is in the wrong place, or one whose issue
# has been closed while the work is still open. Sourced, never executed.
#
# BOTH STATES SUSPEND AUTOMATIC WRITES AND CHANGE NOTHING THEMSELVES.
# They exist because the alternative is worse. A plugin that "helpfully" moved a
# worktree's issue to match the workspace it happens to be sitting in, or that
# reopened a ticket someone had just closed, would be undoing decisions a person
# made deliberately. So each is detected, reported, and left alone until Shawn
# picks a remedy through the bind skill. A hook never prompts (KTD13).
#
# WHY A MISSING WORKSPACE BINDING IS NOT A MISMATCH.
# Most workspaces are unbound and always will be. Reporting every worktree in an
# unbound workspace as misplaced would make the state meaningless within a day,
# and a warning nobody can clear is a warning everybody learns to ignore. A
# mismatch requires BOTH sides to be positively known and to disagree.

# The context and the one comparison. Undefined, `pair_inside` is 127, which
# reads as "outside" and would report every bound worktree as misplaced.
command -v herdr_linear::pair_inside >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/context-filter.sh"

HERDR_LINEAR_STATE_OK=0
HERDR_LINEAR_STATE_MISPLACED=1
HERDR_LINEAR_STATE_STALE=2
HERDR_LINEAR_STATE_UNKNOWN=3   # not enough information to judge; not a problem

# herdr_linear::check_placement <worktree> <workspace-id>
#
# The binding against the context it sits in: the space's project and, when one
# is declared, the session's team. Prints a human-readable report naming both
# sides of whichever half disagrees, and returns MISPLACED.
#
# THE STATE BELONGS TO THE BINDING. The binding is the leaf that contradicts its
# parent; recorded on the session, one bad worktree would suspend every pane in
# it and the next worktree that is inside would clear the state while the first
# contradiction was still true.
herdr_linear::check_placement() {
    local wt="${1:-}" ws="${2:-}" ident ctx pair cp ct ip it

    # misplaced and stale are states THIS FILE sets, so refusing to run outside
    # `bound` meant neither check could ever run again -- the suspension lasted
    # exactly one pass and classify then cleared it back to bound with the
    # mismatch untouched.
    case "$(herdr_linear::binding_state "$wt" 2>/dev/null)" in
        bound|misplaced|stale) ;;
        *) return "$HERDR_LINEAR_STATE_UNKNOWN" ;;
    esac

    pair="$(herdr_linear::context_pair "$ws")"
    cp="${pair%%$'\037'*}"; ct="${pair##*$'\037'}"
    [ -n "$cp" ] || [ -n "$ct" ] || return "$HERDR_LINEAR_STATE_UNKNOWN"

    ident="$(herdr_linear::binding_identifier "$wt")" || return "$HERDR_LINEAR_STATE_UNKNOWN"
    # One fetch for both halves. issue_context reports the project and team
    # NAMES beside their IDS; compare on the ids -- two projects can share a
    # name, and a rename would silently clear a real mismatch.
    ctx="$(herdr_linear::issue_context "$ident" 2>/dev/null)" || return "$HERDR_LINEAR_STATE_UNKNOWN"
    pair="$(herdr_linear::_ctx_pair "$ctx")"
    ip="$(printf '%s' "$pair" | cut -f1)"
    it="$(printf '%s' "$pair" | cut -f2)"

    # Both sides must be positively known. An unbound workspace, or an issue in
    # no project, is the normal case and not a mismatch -- so a half the issue
    # cannot answer is dropped rather than judged, and a pass with no half left
    # judges nothing.
    [ -n "$ip" ] || cp=""
    [ -n "$it" ] || ct=""
    [ -n "$cp" ] || [ -n "$ct" ] || return "$HERDR_LINEAR_STATE_UNKNOWN"

    # The outermost level first: a session whose team the bound issue is outside
    # contradicts every level under it, so reporting the inner disagreement
    # would name the wrong two sides. Each half is the same predicate, asked
    # about one half at a time.
    if ! herdr_linear::pair_inside "" "$it" "" "$ct"; then
        printf 'This worktree is bound to %s, which is outside the team this session was declared as.\n' "$ident"
        printf 'The session is declared as team %s.\n' "$ct"
        printf 'Automatic writes are suspended until this is resolved. Run /work:bind, which offers re-pointing the binding or unbinding it.\n'
        return "$HERDR_LINEAR_STATE_MISPLACED"
    fi
    if ! herdr_linear::pair_inside "$ip" "" "$cp" ""; then
        printf 'This worktree is bound to %s, whose project is %s.\n' "$ident" "$ip"
        printf 'The herdr workspace it sits in is bound to project %s.\n' "$cp"
        printf 'Automatic writes are suspended until this is resolved. Run /work:bind to move either side.\n'
        return "$HERDR_LINEAR_STATE_MISPLACED"
    fi
    return "$HERDR_LINEAR_STATE_OK"
}

# Only lib/herdr-write.sh reads this now; check_placement takes both halves off
# one issue_context.
herdr_linear::_issue_project_id() {
    local resp
    resp="$(herdr_linear::fetch_issue "$1")" || return 1
    printf '%s' "$resp" | python3 -c 'import sys,json;print((json.load(sys.stdin)["data"]["issue"].get("project") or {}).get("id",""))' 2>/dev/null
}

# herdr_linear::check_liveness <worktree>
# The issue was closed in Linear while its worktree is still in use. Report it;
# never reopen it. Someone closed that ticket on purpose.
herdr_linear::check_liveness() {
    local wt="${1:-}" ident type
    # Same reason as check_placement: a check that cannot run in the state it
    # set can never clear it, and can never confirm it either.
    case "$(herdr_linear::binding_state "$wt" 2>/dev/null)" in
        bound|misplaced|stale) ;;
        *) return "$HERDR_LINEAR_STATE_UNKNOWN" ;;
    esac
    ident="$(herdr_linear::binding_identifier "$wt")" || return "$HERDR_LINEAR_STATE_UNKNOWN"
    type="$(herdr_linear::_state_type_of "$ident" 2>/dev/null)" || return "$HERDR_LINEAR_STATE_UNKNOWN"
    case "$type" in
        completed|canceled)
            printf '%s is %s in Linear, but this worktree is still here.\n' "$ident" "$type"
            printf 'Nothing has been changed. If the work is still going, run /work:bind to rebind or reopen deliberately.\n'
            return "$HERDR_LINEAR_STATE_STALE"
            ;;
    esac
    return "$HERDR_LINEAR_STATE_OK"
}

# One pass over both, recording the resulting state on the binding so the write
# path can consult it without repeating the network calls.
herdr_linear::classify() {
    local wt="${1:-}" ws="${2:-}" out place_rc live_rc
    out="$(herdr_linear::check_placement "$wt" "$ws")"; place_rc=$?
    if [ "$place_rc" -eq "$HERDR_LINEAR_STATE_MISPLACED" ]; then
        herdr_linear::binding_set_state "$wt" misplaced
        printf '%s' "$out"
        return "$place_rc"
    fi

    out="$(herdr_linear::check_liveness "$wt")"; live_rc=$?
    if [ "$live_rc" -eq "$HERDR_LINEAR_STATE_STALE" ]; then
        herdr_linear::binding_set_state "$wt" stale
        printf '%s' "$out"
        return "$live_rc"
    fi

    # Clearing is deliberate and narrow: only misplaced/stale return to bound,
    # and only on an explicit OK from the check that set them. "Not MISPLACED"
    # is not the same answer as OK -- UNKNOWN means the check could not judge,
    # and treating that as a pass cleared the suspension on a mismatch nobody
    # had resolved.
    case "$(herdr_linear::binding_state "$wt" 2>/dev/null)" in
        misplaced) [ "$place_rc" -eq "$HERDR_LINEAR_STATE_OK" ] && herdr_linear::binding_set_state "$wt" bound ;;
        stale)     [ "$live_rc"  -eq "$HERDR_LINEAR_STATE_OK" ] && herdr_linear::binding_set_state "$wt" bound ;;
    esac
    return "$HERDR_LINEAR_STATE_OK"
}
