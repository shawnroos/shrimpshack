#!/usr/bin/env bash
# The scope records: which Linear project a herdr space is bound to, and which
# team a herdr session is bound to. Sourced, never executed.
#
# Both are the worktree record's shape reused, so both wear its state machine
# with no second one written. Why that is so is stated above each section.

command -v herdr_linear::is_safe_identifier >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/sanitize.sh"
command -v herdr_linear::_py >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/record.sh"
# A scope record is keyed on the herdr session it belongs to. herdr-read.sh is
# read-only by construction, so sourcing it costs nothing and disturbs nothing.
command -v herdr_linear::session_id >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/herdr-read.sh"

# ------------------------------------------------- workspace to project (R9, R10)
#
# Keyed on the herdr SESSION and the workspace ID. The id alone is a stable
# opaque handle within one server -- a rename changes the workspace's label and
# not its id, which is why R10 holds without extra machinery -- but it is not
# unique ACROSS servers: two sessions on one machine each hold a space called
# `w1`, verified live with `herdr session list`. A flat key gave those two
# spaces one project binding, one view and one state.
#
# The record shape is the worktree one reused: `issue_identifier` carries the
# Linear project id, and the branch fields stay empty because a workspace has no
# branch to disagree with.

# herdr_linear::_workspace_dir [session-id]
# Where a session's space records live. A pane with no herdr socket has no
# session level, and keeps the flat directory -- which is also where every
# record written before this keying still sits.
#
# The session id is an ARGUMENT: a store that asks the herdr client which
# session it is in puts that client in the closure of every consumer of the
# store.
herdr_linear::_workspace_dir() {
    local sid="${1:-}"
    # session_id validates a named session already; repeated here because this
    # is the line that turns the value into a path.
    if [ -n "$sid" ] && herdr_linear::is_safe_identifier "$sid"; then
        printf '%s/workspaces/%s' "$HERDR_LINEAR_STORE_DIR" "$sid"
    else
        printf '%s/workspaces' "$HERDR_LINEAR_STORE_DIR"
    fi
}

# The READ path. A record written before session keying stays readable where it
# is until a write claims it, so the whole store does not have to be rewritten
# on upgrade.
herdr_linear::_workspace_record_path() {
    local ws="${1:-}" f flat sid
    herdr_linear::is_safe_identifier "$ws" 2>/dev/null || case "$ws" in
        ''|*[!A-Za-z0-9_:-]*) return 1 ;;
    esac
    sid="$(herdr_linear::session_id 2>/dev/null)" || sid=""
    f="$(herdr_linear::_workspace_dir "$sid")/$ws.json"
    flat="$HERDR_LINEAR_STORE_DIR/workspaces/$ws.json"
    if [ "$flat" != "$f" ] && [ ! -e "$f" ] && [ -e "$flat" ]; then
        printf '%s' "$flat"
        return 0
    fi
    printf '%s' "$f"
}

# The WRITE path, and the migration with it. The first write from a session
# MOVES a flat record into that session rather than copying it: a copy would
# hand a second session the first one's project binding and its created views,
# which is the defect being fixed. The move claims the record once, and the
# session that does not get it reads unbound, which is a state a person can see
# and resolve. Which session a flat record "really" belongs to is not derivable
# -- both servers report the id -- so it is not guessed.
herdr_linear::_workspace_claim_path() {
    local ws="${1:-}" dir f flat sid
    herdr_linear::is_safe_identifier "$ws" 2>/dev/null || case "$ws" in
        ''|*[!A-Za-z0-9_:-]*) return 1 ;;
    esac
    sid="$(herdr_linear::session_id 2>/dev/null)" || sid=""
    dir="$(herdr_linear::_workspace_dir "$sid")"
    f="$dir/$ws.json"
    flat="$HERDR_LINEAR_STORE_DIR/workspaces/$ws.json"
    mkdir -p "$dir" 2>/dev/null
    chmod 700 "$HERDR_LINEAR_STORE_DIR" "$dir" 2>/dev/null
    if [ "$flat" != "$f" ] && [ ! -e "$f" ] && [ -e "$flat" ]; then
        # A silent failure here leaves the space reading unbound in this session
        # while its project binding and its views sit in the record that did not
        # move. That is recoverable, and only if somebody is told.
        mv -f "$flat" "$f" 2>/dev/null \
            || printf 'the space record for %s could not be moved into this session; it reads unbound here and its project binding is still in %s\n' \
                "$ws" "$flat" >&2
    fi
    printf '%s' "$f"
}

herdr_linear::workspace_read() {
    local f
    f="$(herdr_linear::_workspace_record_path "${1:-}")" || return "$HERDR_LINEAR_BINDING_ABSENT"
    herdr_linear::_mode_ok "$f" || return "$HERDR_LINEAR_BINDING_ABSENT"
    herdr_linear::_py read "$f" || return "$HERDR_LINEAR_BINDING_ABSENT"
}

herdr_linear::workspace_state() {
    local rec
    rec="$(herdr_linear::workspace_read "$1")" || { printf 'unbound'; return "$HERDR_LINEAR_BINDING_ABSENT"; }
    printf '%s' "$rec" | python3 -c 'import sys,json;print(json.load(sys.stdin)["state"])' 2>/dev/null
}

herdr_linear::workspace_project() {
    local rec
    rec="$(herdr_linear::workspace_read "$1")" || return "$HERDR_LINEAR_BINDING_ABSENT"
    printf '%s' "$rec" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("issue_identifier",""))' 2>/dev/null
}

# The ids of the teams the space's project belonged to when it was bound. One
# per line. Recorded at confirmation so a guard comparing against them costs no
# Linear call; empty when the confirmation did not carry them, which the caller
# must read as "ask Linear", never as "no teams".
herdr_linear::workspace_team_ids() {
    local rec
    rec="$(herdr_linear::workspace_read "$1")" || return "$HERDR_LINEAR_BINDING_ABSENT"
    printf '%s' "$rec" | python3 -c '
import sys, json
for t in json.load(sys.stdin).get("team_ids") or []:
    print(t)
' 2>/dev/null
}

# herdr_linear::workspaces_effective
# One JSON object per line, {id, state, project_id, project_name}, for each
# space record the loader accepts. A refused record is left out, so its space
# reads as unbound, as workspace_state reports it.
herdr_linear::workspaces_effective() {
    local sid
    sid="$(herdr_linear::session_id 2>/dev/null)" || sid=""
    herdr_linear::_py list-workspaces "$HERDR_LINEAR_STORE_DIR" \
        "$(herdr_linear::_workspace_dir "$sid")"
}

herdr_linear::workspace_propose() {
    local ws="${1:-}" project="${2:-}" f
    [ -n "$ws" ] && [ -n "$project" ] || return "$HERDR_LINEAR_BINDING_REFUSED"
    f="$(herdr_linear::_workspace_claim_path "$ws")" || return "$HERDR_LINEAR_BINDING_REFUSED"
    herdr_linear::_mutate_at "$f" propose "workspace:$ws" "$project"
}

# Same nonce rule, and the same limit on what it proves. See the header.
# The trailing arguments are the ids of the project's teams. The caller supplies
# them rather than this reading them, because the two callers already hold the
# answer -- and a fetch here would make every file that binds a space depend on
# the Linear client.
herdr_linear::workspace_confirm() {
    local ws="${1:-}" project="${2:-}" nonce="${3:-}" f
    [ -n "$ws" ] && [ -n "$project" ] || return "$HERDR_LINEAR_BINDING_REFUSED"
    f="$(herdr_linear::_workspace_claim_path "$ws")" || return "$HERDR_LINEAR_BINDING_REFUSED"
    herdr_linear::_mutate_at "$f" confirm "$project" "$nonce" "" "" "${@:4}"
}

# ------------------------------------------------------ the workspace's view (KTD6)

herdr_linear::workspace_set_view() {
    local ws="${1:-}" id="${2:-}" name="${3:-}" layout="${4:-}" f
    [ -n "$ws" ] && [ -n "$id" ] || return "$HERDR_LINEAR_BINDING_REFUSED"
    herdr_linear::is_safe_identifier "$id" || return "$HERDR_LINEAR_BINDING_REFUSED"
    f="$(herdr_linear::_workspace_claim_path "$ws")" || return "$HERDR_LINEAR_BINDING_REFUSED"
    [ -f "$f" ] || return "$HERDR_LINEAR_BINDING_ABSENT"
    herdr_linear::_mutate_at "$f" set-view "$id" "$name" "$layout"
}

herdr_linear::workspace_clear_view() {
    local ws="${1:-}" f
    f="$(herdr_linear::_workspace_claim_path "$ws")" || return "$HERDR_LINEAR_BINDING_REFUSED"
    [ -f "$f" ] || return "$HERDR_LINEAR_BINDING_ABSENT"
    herdr_linear::_mutate_at "$f" clear-view
}

herdr_linear::workspace_view() {
    local f
    f="$(herdr_linear::_workspace_record_path "${1:-}")" || return "$HERDR_LINEAR_BINDING_ABSENT"
    herdr_linear::_mode_ok "$f" || return "$HERDR_LINEAR_BINDING_ABSENT"
    herdr_linear::_py view "$f" || return "$HERDR_LINEAR_BINDING_ABSENT"
}

herdr_linear::workspace_add_view() {
    local ws="${1:-}" id="${2:-}" f
    [ -n "$ws" ] && [ -n "$id" ] || return "$HERDR_LINEAR_BINDING_REFUSED"
    herdr_linear::is_safe_identifier "$id" || return "$HERDR_LINEAR_BINDING_REFUSED"
    f="$(herdr_linear::_workspace_claim_path "$ws")" || return "$HERDR_LINEAR_BINDING_REFUSED"
    [ -f "$f" ] || return "$HERDR_LINEAR_BINDING_ABSENT"
    herdr_linear::_mutate_at "$f" add-view "$id"
}

herdr_linear::workspace_owns_view() {
    local ws="${1:-}" id="${2:-}" f
    [ -n "$id" ] || return 1
    f="$(herdr_linear::_workspace_record_path "$ws")" || return 1
    herdr_linear::_mode_ok "$f" || return 1
    herdr_linear::_py owns-view "$f" "$id"
}

# WHY THE SESSION RECORD IS BINDING-SHAPED. It reuses the worktree record: the
# team id sits where an issue identifier sits, the team key in the display
# field, and `worktree_path` names the session. That is what gives it the
# unbound / proposed / bound / misplaced states with no second state machine,
# and what makes declaring a team a proposal somebody answers rather than a
# value anything can write.
# ------------------------------------------------------------ the session record

herdr_linear::_session_record_path() {
    local sid
    sid="$(herdr_linear::session_id 2>/dev/null)" || return 1
    # session_id validates a named session already; repeated here because this
    # is the line that turns the value into a path.
    herdr_linear::is_safe_identifier "$sid" || return 1
    printf '%s/contexts/session-%s.json' "$HERDR_LINEAR_STORE_DIR" "$sid"
}

# The write path, which must make the directory: _mutate_at takes its lock by
# creating a directory beside the record, and a missing parent turns that into
# the full lock wait and then a refusal.
herdr_linear::_session_claim_path() {
    local f sid
    sid="$(herdr_linear::session_id 2>/dev/null)" || return 1
    herdr_linear::is_safe_identifier "$sid" || return 1
    f="$(herdr_linear::_session_record_path)" || return 1
    mkdir -p "${f%/*}" 2>/dev/null
    chmod 700 "$HERDR_LINEAR_STORE_DIR" "${f%/*}" 2>/dev/null
    printf '%s' "$f"
}

herdr_linear::session_read() {
    local f
    f="$(herdr_linear::_session_record_path)" || return "$HERDR_LINEAR_BINDING_ABSENT"
    herdr_linear::_mode_ok "$f" || return "$HERDR_LINEAR_BINDING_ABSENT"
    herdr_linear::_py read "$f" || return "$HERDR_LINEAR_BINDING_ABSENT"
}

herdr_linear::session_state() {
    local rec
    rec="$(herdr_linear::session_read)" || { printf 'unbound'; return "$HERDR_LINEAR_BINDING_ABSENT"; }
    printf '%s' "$rec" | python3 -c 'import sys,json;print(json.load(sys.stdin)["state"])' 2>/dev/null
}

# The team only once it is ANSWERED. A proposed team is a question that was
# asked, not an answer, and answering the guard from it would let the asking
# narrow the session.
herdr_linear::session_team() {
    local rec
    rec="$(herdr_linear::session_read)" || return "$HERDR_LINEAR_BINDING_ABSENT"
    printf '%s' "$rec" | python3 -c '
import sys, json
rec = json.load(sys.stdin)
print(rec.get("issue_identifier", "") if rec.get("state") == "bound" else "")
' 2>/dev/null
}

herdr_linear::session_team_key() {
    local rec
    rec="$(herdr_linear::session_read)" || return "$HERDR_LINEAR_BINDING_ABSENT"
    printf '%s' "$rec" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("display_name",""))' 2>/dev/null
}

herdr_linear::session_propose() {
    local team="${1:-}" sid f
    [ -n "$team" ] || return "$HERDR_LINEAR_BINDING_REFUSED"
    herdr_linear::is_safe_identifier "$team" || return "$HERDR_LINEAR_BINDING_REFUSED"
    sid="$(herdr_linear::session_id 2>/dev/null)" || return "$HERDR_LINEAR_BINDING_REFUSED"
    f="$(herdr_linear::_session_claim_path)" || return "$HERDR_LINEAR_BINDING_REFUSED"
    herdr_linear::_mutate_at "$f" propose "session:$sid" "$team"
}

# The same nonce rule the worktree and space records use, and the same limit on
# what it proves: it orders confirm after propose, and nothing here can tell an
# attended session from a headless one.
herdr_linear::session_confirm() {
    local team="${1:-}" nonce="${2:-}" key="${3:-}" f
    [ -n "$team" ] || return "$HERDR_LINEAR_BINDING_REFUSED"
    herdr_linear::is_safe_identifier "$team" || return "$HERDR_LINEAR_BINDING_REFUSED"
    if [ -n "$key" ]; then
        herdr_linear::is_safe_identifier "$key" || return "$HERDR_LINEAR_BINDING_REFUSED"
    fi
    f="$(herdr_linear::_session_claim_path)" || return "$HERDR_LINEAR_BINDING_REFUSED"
    herdr_linear::_mutate_at "$f" confirm "$team" "$nonce" "" "$key"
}
