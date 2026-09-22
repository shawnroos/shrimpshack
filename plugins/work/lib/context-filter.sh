#!/usr/bin/env bash
# The session record, and the one resolver and one guard every read path asks.
# Sourced, never executed.
#
# THE MODEL. Three levels, each narrowing the one above: the herdr session
# carries the team, a space carries the project, a tab carries the issue. A
# level that declares nothing narrows nothing -- which is the plugin's behaviour
# before any of this, and stays the default.
#
# WHY THE SESSION RECORD IS BINDING-SHAPED. It reuses the worktree record: the
# team id sits where an issue identifier sits, the team key in the display
# field, and `worktree_path` names the session. That is what gives it the
# unbound / proposed / bound / misplaced states with no second state machine,
# and what makes declaring a team a proposal somebody answers rather than a
# value anything can write.
#
# ONE COMPARISON, NOT TWO. `context_allows` is the only place a team, a project
# or an issue is judged against the context. Two comparisons that can disagree
# is the failure this exists to prevent.

command -v herdr_linear::is_safe_identifier >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/sanitize.sh"
command -v herdr_linear::workspace_read >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/binding.sh"
# The resolver's fallback and the session id are not optional extras: undefined,
# `current_context` is 127, the `||` branch reads it as no derivation, and the
# filter silently widens to everything.
command -v herdr_linear::current_context >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/context.sh"
command -v herdr_linear::session_id >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/herdr-read.sh"
command -v herdr_linear::scope_repo >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/repos.sh"

HERDR_LINEAR_CONTEXT_INSIDE=0
HERDR_LINEAR_CONTEXT_OUTSIDE=1
HERDR_LINEAR_CONTEXT_KIND=2      # not a kind this guard judges
HERDR_LINEAR_CONTEXT_UNKNOWN=3   # could not be asked; not an answer of "outside"

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

# The team only once it is BOUND. A proposed team is a question that was asked,
# not an answer, and answering the guard from it would let the asking narrow the
# session.
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

herdr_linear::session_set_state() {
    local f
    f="$(herdr_linear::_session_claim_path)" || return "$HERDR_LINEAR_BINDING_REFUSED"
    herdr_linear::_mutate_at "$f" set-state "${1:-}"
}

# ------------------------------------------------------------------ the resolver

# The space's project, only from a bound record -- a proposal is a candidate.
herdr_linear::_space_project() {
    local ws="${1:-}"
    [ -n "$ws" ] || return 0
    [ "$(herdr_linear::workspace_state "$ws" 2>/dev/null)" = "bound" ] || return 0
    herdr_linear::workspace_project "$ws" 2>/dev/null || true
}

# herdr_linear::context <worktree> [workspace-id]
#
# The effective filter as JSON: `team_id`, `team_key`, `team_name`, `project_id`
# and `identifier`, each with a `*_source` naming the level that decided it --
# `session`, `space`, `tab`, `derived` for the worktree derivation, or `none`.
#
# The keys are `current_context`'s keys for the same facts, so a caller reading
# them with `context_fields` reads this unchanged.
herdr_linear::context() {
    local wt="${1:-}" ws="${2:-}" team="" key="" name="" project="" ident=""
    local team_src=none project_src=none issue_src=none fallback=""

    team="$(herdr_linear::session_team 2>/dev/null)" || team=""
    if [ -n "$team" ]; then
        team_src=session
        key="$(herdr_linear::session_team_key 2>/dev/null)" || key=""
    fi

    project="$(herdr_linear::_space_project "$ws")"
    [ -n "$project" ] && project_src=space

    ident="$(herdr_linear::binding_identifier "$wt" 2>/dev/null)" || ident=""
    [ -n "$ident" ] && issue_src=tab

    # The fallback is today's derivation, asked only for what no level declared.
    # Asking it when every level answered would spend a Linear call to learn
    # what the records already say.
    if [ -z "$team" ] || [ -z "$project" ]; then
        fallback="$(herdr_linear::current_context "$wt" "$ws" 2>/dev/null)" || fallback=""
    fi

    HERDR_LINEAR_FALLBACK="$fallback" python3 -c '
import sys, json, os
team, key, name, project, ident = sys.argv[1:6]
team_src, project_src, issue_src = sys.argv[6:9]
try:
    fb = json.loads(os.environ.get("HERDR_LINEAR_FALLBACK") or "{}")
except ValueError:
    fb = {}
if not project and fb.get("project_id"):
    project, project_src = fb["project_id"], "derived"
if not team and fb.get("team_id"):
    team, team_src = fb["team_id"], "derived"
# The derived name belongs to the derived id. A declared team keeps its key and
# no name rather than wearing whichever name the worktree happened to derive.
if team_src == "derived":
    name = fb.get("team_name", "")
if not ident and fb.get("identifier"):
    ident, issue_src = fb["identifier"], "tab"
print(json.dumps({"team_id": team, "team_key": key, "team_name": name,
                  "project_id": project, "identifier": ident,
                  "team_source": team_src, "project_source": project_src,
                  "issue_source": issue_src}))
' "$team" "$key" "$name" "$project" "$ident" "$team_src" "$project_src" "$issue_src"
}

# --------------------------------------------------------------------- the guard

# herdr_linear::team_in_project <team-id> <project-id> [workspace-id]
#
# Whether the project carries the team. 0 inside, 1 outside, 3 when it could not
# be asked. The space's own record answers for the project it is bound to, which
# is what keeps a read off the network; any other project is asked about once.
#
# Both directions of the narrowing rule are this one comparison: a space
# declaring a project under a session team, and a session declaring a team under
# a bound space, differ only in which value is held and which is offered.
herdr_linear::team_in_project() {
    local team="${1:-}" project="${2:-}" ws="${3:-}" lines rc
    [ -n "$team" ] && [ -n "$project" ] || return "$HERDR_LINEAR_CONTEXT_UNKNOWN"

    if [ "$(herdr_linear::_space_project "$ws")" = "$project" ]; then
        lines="$(herdr_linear::workspace_team_ids "$ws" 2>/dev/null)" || lines=""
        if [ -n "$lines" ]; then
            printf '%s\n' "$lines" | grep -qxF "$team" \
                && return "$HERDR_LINEAR_CONTEXT_INSIDE"
            return "$HERDR_LINEAR_CONTEXT_OUTSIDE"
        fi
    fi

    lines="$(herdr_linear::project_teams "$project" 2>/dev/null)"; rc=$?
    [ "$rc" -eq 0 ] || return "$HERDR_LINEAR_CONTEXT_UNKNOWN"
    printf '%s\n' "$lines" | cut -f1 | grep -qxF "$team" \
        && return "$HERDR_LINEAR_CONTEXT_INSIDE"
    return "$HERDR_LINEAR_CONTEXT_OUTSIDE"
}

# herdr_linear::context_allows_fields <project-id> <team-id> [workspace-id]
#
# The two-part issue test on fields the caller already holds, for a listing that
# read them once for every row. `context_allows issue` fetches the same two
# values and ends here, so there is one comparison and not two that can disagree.
herdr_linear::context_allows_fields() {
    local ip="${1:-}" it="${2:-}" ws="${3:-}" team project
    team="$(herdr_linear::session_team 2>/dev/null)" || team=""
    project="$(herdr_linear::_space_project "$ws")"
    [ -n "$team" ] || [ -n "$project" ] || return "$HERDR_LINEAR_CONTEXT_INSIDE"
    if [ -n "$project" ] && [ "$ip" != "$project" ]; then
        return "$HERDR_LINEAR_CONTEXT_OUTSIDE"
    fi
    if [ -n "$team" ] && [ "$it" != "$team" ]; then
        return "$HERDR_LINEAR_CONTEXT_OUTSIDE"
    fi
    return "$HERDR_LINEAR_CONTEXT_INSIDE"
}

# herdr_linear::context_allows <kind> <id> [workspace-id]
#
# `team`, `project` or `issue`. 0 inside, 1 outside, 3 when it could not be
# asked, 2 for a kind this does not judge. A level that declared nothing does
# not narrow, so a session with no team answers 0 to everything.
#
# An issue is inside when its project is the space's project AND, when a session
# team is declared, its team is that team. Both halves are needed: a project may
# span several teams, so the project test alone admits another team's issue in
# the very project the space is bound to.
herdr_linear::context_allows() {
    local kind="${1:-}" id="${2:-}" ws="${3:-}" team project ctx ip it
    [ -n "$id" ] || return "$HERDR_LINEAR_CONTEXT_KIND"
    team="$(herdr_linear::session_team 2>/dev/null)" || team=""

    case "$kind" in
        team)
            [ -n "$team" ] || return "$HERDR_LINEAR_CONTEXT_INSIDE"
            [ "$team" = "$id" ] && return "$HERDR_LINEAR_CONTEXT_INSIDE"
            return "$HERDR_LINEAR_CONTEXT_OUTSIDE"
            ;;
        project)
            [ -n "$team" ] || return "$HERDR_LINEAR_CONTEXT_INSIDE"
            herdr_linear::team_in_project "$team" "$id" "$ws"
            return $?
            ;;
        issue)
            project="$(herdr_linear::_space_project "$ws")"
            [ -n "$team" ] || [ -n "$project" ] || return "$HERDR_LINEAR_CONTEXT_INSIDE"
            ctx="$(herdr_linear::issue_context "$id" 2>/dev/null)" \
                || return "$HERDR_LINEAR_CONTEXT_UNKNOWN"
            ip="$(printf '%s' "$ctx" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("project_id",""))' 2>/dev/null)"
            it="$(printf '%s' "$ctx" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("team_id",""))' 2>/dev/null)"
            herdr_linear::context_allows_fields "$ip" "$it" "$ws"
            return $?
            ;;
    esac
    return "$HERDR_LINEAR_CONTEXT_KIND"
}

# ------------------------------------------------------- the surface's prefix

# herdr_linear::unbound_prefix [identifier] [workspace-id]
#
# The prefix a surface wears while it holds work its context does not cover, or
# nothing. THE ONLY PLACE THE PREFIX IS DECIDED; lib/herdr-write.sh's
# `_tab_label` is the only place it is applied, so a title cannot drift from the
# record it is meant to report.
#
# No identifier is the fresh tab standing in no worktree: it holds no work the
# context covers, for want of any work at all. Only a definite OUTSIDE brands a
# surface -- a context that could not be asked is not an answer, and branding on
# it would title every tab UNBOUND whenever Linear is unreachable.
herdr_linear::unbound_prefix() {
    local ident="${1:-}" ws="${2:-}" rc
    if [ -z "$ident" ]; then
        printf 'UNBOUND: '
        return 0
    fi
    herdr_linear::context_allows issue "$ident" "$ws"; rc=$?
    [ "$rc" -eq "$HERDR_LINEAR_CONTEXT_OUTSIDE" ] && printf 'UNBOUND: '
    return 0
}

# ---------------------------------------------------- the expected directory

# herdr_linear::expected_cwd [directory] [workspace-id]
#
# Where the pane holding <directory> should be standing: the bound issue's
# worktree, from this directory first and then from the binding whose recorded
# tab is this tab, else the repository the project-and-team pair names, else
# nothing.
#
# IT STATES, AND IT NEVER MOVES ANYTHING. Standing somewhere else on purpose is
# legitimate, so this prints a path for a caller to offer and refuses nothing.
herdr_linear::expected_cwd() {
    local dir="${1:-$PWD}" ws="${2:-}" git="${HERDR_LINEAR_GIT_BIN:-git}"
    local top tab wt ctx project team repo

    top="$("$git" -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || top=""
    [ -n "$top" ] && top="$(cd "$top" 2>/dev/null && pwd -P)"
    if [ -n "$top" ] && herdr_linear::binding_identifier "$top" >/dev/null 2>&1; then
        printf '%s' "$top"
        return 0
    fi

    tab="$(herdr_linear::tab_id 2>/dev/null)" || tab=""
    if [ -n "$tab" ]; then
        wt="$(herdr_linear::bindings_effective 2>/dev/null \
            | awk -F'\037' -v t="$tab" '$4 == t && $3 != "" { print $3; exit }')" || wt=""
        if [ -n "$wt" ] && [ -d "$wt" ]; then
            printf '%s' "$wt"
            return 0
        fi
    fi

    ctx="$(herdr_linear::context "$dir" "$ws" 2>/dev/null)" || return 0
    project="$(printf '%s' "$ctx" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("project_id",""))' 2>/dev/null)"
    team="$(printf '%s' "$ctx" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("team_id",""))' 2>/dev/null)"
    [ -n "$project" ] && [ -n "$team" ] || return 0
    # The pair key becomes a filename under the store, and `.` separates its two
    # halves, so an id carrying one could spell a plain key as a pair.
    herdr_linear::is_safe_identifier "$project" || return 0
    herdr_linear::is_safe_identifier "$team" || return 0
    case "$project$team" in *.*) return 0 ;; esac

    repo="$(herdr_linear::scope_repo "project-$project.team-$team" 2>/dev/null)" || return 0
    [ -n "$repo" ] && [ -d "$repo" ] && printf '%s' "$repo"
    return 0
}
