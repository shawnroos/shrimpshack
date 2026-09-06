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

HERDR_LINEAR_STATE_OK=0
HERDR_LINEAR_STATE_MISPLACED=1
HERDR_LINEAR_STATE_STALE=2
HERDR_LINEAR_STATE_UNKNOWN=3   # not enough information to judge; not a problem

# herdr_linear::check_placement <worktree> <workspace-id>
# Prints a human-readable report on a mismatch and returns MISPLACED.
herdr_linear::check_placement() {
    local wt="${1:-}" ws="${2:-}" ident issue_project ws_project

    # misplaced and stale are states THIS FILE sets, so refusing to run outside
    # `bound` meant neither check could ever run again -- the suspension lasted
    # exactly one pass and classify then cleared it back to bound with the
    # mismatch untouched.
    case "$(herdr_linear::binding_state "$wt" 2>/dev/null)" in
        bound|misplaced|stale) ;;
        *) return "$HERDR_LINEAR_STATE_UNKNOWN" ;;
    esac
    [ -n "$ws" ] || return "$HERDR_LINEAR_STATE_UNKNOWN"

    # Both sides must be positively known. An unbound workspace is the normal
    # case, not a mismatch.
    #
    # A backstop, deliberately redundant: workspace_project below already
    # answers empty for anything but a bound record, so mutating this line away
    # turns no test red. It stays so that a future change to what
    # workspace_propose records cannot silently make a proposed workspace
    # produce a mismatch report. The property itself is pinned by
    # propose.bats -- "a proposed workspace has no project recorded".
    [ "$(herdr_linear::workspace_state "$ws" 2>/dev/null)" = "bound" ] \
        || return "$HERDR_LINEAR_STATE_UNKNOWN"
    ws_project="$(herdr_linear::workspace_project "$ws" 2>/dev/null)" || return "$HERDR_LINEAR_STATE_UNKNOWN"
    [ -n "$ws_project" ] || return "$HERDR_LINEAR_STATE_UNKNOWN"

    ident="$(herdr_linear::binding_identifier "$wt")" || return "$HERDR_LINEAR_STATE_UNKNOWN"
    # issue_context reports the project NAME; the workspace binding stores the
    # project ID. Compare on the id rather than on names -- two projects can
    # share a name, and a rename would silently clear a real mismatch.
    issue_project="$(herdr_linear::_issue_project_id "$ident")" || return "$HERDR_LINEAR_STATE_UNKNOWN"
    [ -n "$issue_project" ] || return "$HERDR_LINEAR_STATE_UNKNOWN"

    [ "$issue_project" != "$ws_project" ] || return "$HERDR_LINEAR_STATE_OK"

    printf 'This worktree is bound to %s, whose project is %s.\n' "$ident" "$issue_project"
    printf 'The herdr workspace it sits in is bound to project %s.\n' "$ws_project"
    printf 'Automatic writes are suspended until this is resolved. Run /work:bind to move either side.\n'
    return "$HERDR_LINEAR_STATE_MISPLACED"
}

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
