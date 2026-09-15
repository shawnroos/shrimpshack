#!/usr/bin/env bash
# The bind skill's view step: which Linear view a herdr space renders as.
# Sourced, never executed.
#
# Choosing an existing view writes nothing to Linear. Creating one is a Linear
# write and goes through the consent gate here, the same site shape as
# doc_publish: refused with a shadow line, never silently.

command -v herdr_linear::is_safe_identifier >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/sanitize.sh"

HERDR_LINEAR_VIEW_OK=0
HERDR_LINEAR_VIEW_REFUSED=1
HERDR_LINEAR_VIEW_SHADOW=2
HERDR_LINEAR_VIEW_FAILED=3

# One `<id><TAB><name>` line per candidate; nothing and success for a project
# with none, non-zero only when the space is not bound or Linear could not be
# asked -- the one-known-answer shape of project_teams.
herdr_linear::views_for_space() {
    local ws="${1:-}" project
    [ "$(herdr_linear::workspace_state "$ws" 2>/dev/null)" = "bound" ] || return "$HERDR_LINEAR_VIEW_REFUSED"
    project="$(herdr_linear::workspace_project "$ws")" || return "$HERDR_LINEAR_VIEW_REFUSED"
    [ -n "$project" ] || return "$HERDR_LINEAR_VIEW_REFUSED"
    herdr_linear::project_views "$project"
}

herdr_linear::view_choose() {
    local ws="${1:-}" id="${2:-}" v name layout project filter
    [ -n "$ws" ] && [ -n "$id" ] || return "$HERDR_LINEAR_VIEW_REFUSED"
    herdr_linear::is_safe_identifier "$id" || return "$HERDR_LINEAR_VIEW_REFUSED"
    [ "$(herdr_linear::workspace_state "$ws" 2>/dev/null)" = "bound" ] || return "$HERDR_LINEAR_VIEW_REFUSED"
    project="$(herdr_linear::workspace_project "$ws")" || return "$HERDR_LINEAR_VIEW_REFUSED"
    [ -n "$project" ] || return "$HERDR_LINEAR_VIEW_REFUSED"
    v="$(herdr_linear::view_read "$id")" || return "$HERDR_LINEAR_VIEW_FAILED"
    # The same KTD12 test views_for_space listed by: an id typed past the list
    # must not make a view of another project this space's board.
    filter="$(printf '%s' "$v" | python3 -c 'import sys,json;print(json.dumps(json.load(sys.stdin).get("filter") or {}))')" || return "$HERDR_LINEAR_VIEW_FAILED"
    herdr_linear::filter_names_project "$filter" "$project" || return "$HERDR_LINEAR_VIEW_REFUSED"
    name="$(herdr_linear::sanitize_for_display "$(printf '%s' "$v" | python3 -c 'import sys,json;sys.stdout.write(json.load(sys.stdin).get("name") or "")')")"
    layout="$(printf '%s' "$v" | python3 -c 'import sys,json;print(json.dumps(json.load(sys.stdin).get("layout") or {}, sort_keys=True))')" || return "$HERDR_LINEAR_VIEW_FAILED"
    herdr_linear::workspace_set_view "$ws" "$id" "$name" "$layout" || return "$HERDR_LINEAR_VIEW_FAILED"
    printf '%s' "$id"
    return "$HERDR_LINEAR_VIEW_OK"
}

herdr_linear::view_none() {
    local ws="${1:-}"
    [ -n "$ws" ] || return "$HERDR_LINEAR_VIEW_REFUSED"
    herdr_linear::workspace_clear_view "$ws" || return "$HERDR_LINEAR_VIEW_FAILED"
    return "$HERDR_LINEAR_VIEW_OK"
}

# Gated against the worktree the person stands in, not the space. The id goes
# under created_views BEFORE it becomes the space's view (KTD11: that list is
# the bound a later change-view verb reads). A view whose board preferences
# failed still exists and is still recorded, with layout `list`, a reason on
# stderr and the prefs code returned: an unrecorded view is one nobody can
# find to delete.
herdr_linear::view_create_gated() {
    local dir="${1:-}" team="${2:-}" project="${3:-}" name="${4:-}" ws="${5:-}" view_id rc layout
    [ -n "$dir" ] && [ -n "$project" ] && [ -n "$name" ] && [ -n "$ws" ] || return "$HERDR_LINEAR_VIEW_REFUSED"
    [ "$(herdr_linear::workspace_state "$ws" 2>/dev/null)" = "bound" ] || return "$HERDR_LINEAR_VIEW_REFUSED"
    [ "$(herdr_linear::workspace_project "$ws")" = "$project" ] || return "$HERDR_LINEAR_VIEW_REFUSED"
    # No team, no consent record to match: the gate would log "nothing has
    # answered" for a question nobody could have been asked.
    [ -n "$team" ] || return "$HERDR_LINEAR_VIEW_REFUSED"

    if ! herdr_linear::consent_gate "$dir" "$team" "$project" "create view \"$name\" on project $project"; then
        return "$HERDR_LINEAR_VIEW_SHADOW"
    fi

    view_id="$(herdr_linear::view_create "$project" "$name")"; rc=$?
    case "$rc" in
        0|"$HERDR_LINEAR_VIEW_PREFS_FAILED") ;;
        *) return "$HERDR_LINEAR_VIEW_FAILED" ;;
    esac
    [ -n "$view_id" ] || return "$HERDR_LINEAR_VIEW_FAILED"
    herdr_linear::is_safe_identifier "$view_id" || return "$HERDR_LINEAR_VIEW_FAILED"
    # Logged the moment the id is known good, before any record write: from here
    # the view exists at Linear, and a record failure below must not lose it.
    herdr_linear::_shadow_log "CREATED view \"$name\" ($view_id) on project $project"

    if ! herdr_linear::workspace_add_view "$ws" "$view_id"; then
        printf 'view %s was created at Linear but the space record could not be written: record it or delete it in Linear\n' "$view_id" >&2
        printf '%s' "$view_id"
        return "$HERDR_LINEAR_VIEW_FAILED"
    fi
    if [ "$rc" -eq 0 ]; then
        layout='{"grouping":"workflowState","column_order":[],"hidden":[]}'
    else
        layout='{"grouping":null,"column_order":[],"hidden":[],"layout":"list"}'
        printf 'view %s was created but its board preferences were not: it lists rather than boards until arranged in Linear\n' "$view_id" >&2
    fi
    if ! herdr_linear::workspace_set_view "$ws" "$view_id" "$(herdr_linear::sanitize_for_display "$name")" "$layout"; then
        printf 'view %s was created at Linear and listed under created_views, but could not be made the space view\n' "$view_id" >&2
        printf '%s' "$view_id"
        return "$HERDR_LINEAR_VIEW_FAILED"
    fi
    printf '%s' "$view_id"
    [ "$rc" -eq 0 ] && return "$HERDR_LINEAR_VIEW_OK"
    return "$HERDR_LINEAR_VIEW_PREFS_FAILED"
}
