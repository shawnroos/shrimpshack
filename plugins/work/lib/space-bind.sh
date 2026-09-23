#!/usr/bin/env bash
# Binding a space to a project: the guard, the project's teams, and the record,
# in the one order that makes the record safe. Sourced, never executed.
#
# WHY THIS IS A FUNCTION AND NOT A PARAGRAPH. Four skill fences wrote this
# sequence out by hand, and the fourth had already dropped the branch the other
# three carry. A space bound to a project the session's team is not on is a
# level widening the one above it, and nothing catches that afterwards -- the
# record is already written. So the guard and the write travel together, and a
# caller gets a status instead of a sequence to reproduce.
#
# What `workspace_bind_checked` answers, and what a caller says on it:
#
#   0  bound, or already bound to this project. Nothing to say.
#   1  outside: the project's teams do not include the team the session was
#      declared as. NOTHING WAS RECORDED. Name both sides -- the session's team
#      and the project's teams -- and stop.
#   2  the record refused: the proposal was superseded, or confirm was refused.
#      Say what was recorded before it and stop; nothing here retries.
#   3  the project's teams could not be read, so nothing could be judged and
#      nothing was recorded. Say so, and offer to try again.

command -v herdr_linear::context_allows >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/context-filter.sh"
command -v herdr_linear::project_teams >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/context.sh"
command -v herdr_linear::workspace_confirm >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/binding.sh"

HERDR_LINEAR_SPACE_BIND_OK=0
HERDR_LINEAR_SPACE_BIND_OUTSIDE=1
HERDR_LINEAR_SPACE_BIND_REFUSED=2
HERDR_LINEAR_SPACE_BIND_UNKNOWN=3

# herdr_linear::workspace_bind_checked <workspace-id> <project-id>
herdr_linear::workspace_bind_checked() {
    local ws="${1:-}" project="${2:-}" rc nonce teams
    local ids=()
    [ -n "$ws" ] && [ -n "$project" ] || return "$HERDR_LINEAR_SPACE_BIND_REFUSED"

    herdr_linear::context_allows project "$project" "$ws"; rc=$?
    case "$rc" in
        "$HERDR_LINEAR_CONTEXT_INSIDE") ;;
        "$HERDR_LINEAR_CONTEXT_OUTSIDE") return "$HERDR_LINEAR_SPACE_BIND_OUTSIDE" ;;
        *) return "$HERDR_LINEAR_SPACE_BIND_UNKNOWN" ;;
    esac

    # Already the answer. Proposing again would supersede a record that holds
    # the value being asked for, and hand back a nonce nobody asked a person to
    # confirm.
    if [ "$(herdr_linear::workspace_state "$ws" 2>/dev/null)" = "bound" ] \
        && [ "$(herdr_linear::workspace_project "$ws" 2>/dev/null)" = "$project" ]; then
        return "$HERDR_LINEAR_SPACE_BIND_OK"
    fi

    teams="$(herdr_linear::project_teams "$project" 2>/dev/null)" \
        || return "$HERDR_LINEAR_SPACE_BIND_UNKNOWN"
    # The ids go on the record in the same save as the binding, so the guard
    # compares locally afterwards instead of asking Linear on every read.
    while IFS=$'\t' read -r id _; do
        [ -n "$id" ] && ids+=("$id")
    done <<< "$teams"

    nonce="$(herdr_linear::workspace_propose "$ws" "$project")" \
        || return "$HERDR_LINEAR_SPACE_BIND_REFUSED"
    herdr_linear::workspace_confirm "$ws" "$project" "$nonce" ${ids[@]+"${ids[@]}"} \
        || return "$HERDR_LINEAR_SPACE_BIND_REFUSED"
    return "$HERDR_LINEAR_SPACE_BIND_OK"
}
