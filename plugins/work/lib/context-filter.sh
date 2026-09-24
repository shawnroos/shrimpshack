#!/usr/bin/env bash
# The one resolver and one guard every read path asks.
# Sourced, never executed.
#
# THE MODEL. Three levels, each narrowing the one above: the herdr session
# carries the team, a space carries the project, a tab carries the issue. A
# level that declares nothing narrows nothing -- which is the plugin's behaviour
# before any of this, and stays the default.
#
#
# ONE COMPARISON, NOT TWO. `context_allows_team`, `space_may_bind_project` and
# `context_allows_issue` are the only places a team, a project or an issue is
# judged against the context. Two comparisons that can disagree is the failure
# this exists to prevent. Three named functions rather than one string-keyed
# dispatcher: a misspelled call is then a missing function -- 127 -- instead of
# a `case` falling to a default that every caller reads as "proceed".

command -v herdr_linear::is_safe_identifier >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/sanitize.sh"
command -v herdr_linear::workspace_read >/dev/null 2>&1 \
    || . "${BASH_SOURCE[0]%/*}/scope-record.sh"
command -v herdr_linear::binding_identifier >/dev/null 2>&1 \
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
HERDR_LINEAR_CONTEXT_UNKNOWN=3   # could not be asked; not an answer of "outside"

# ------------------------------------------------------------------ the resolver

# The project and team off a context blob, tab-separated, from one python3.
# `context_fields` in linear.sh answers this shape, but sourcing linear.sh for
# it would put the network and the keychain in the closure of every skill that
# reads a context.
herdr_linear::_ctx_pair() {
    printf '%s' "${1:-}" | python3 -c 'import sys, json
d = json.load(sys.stdin)
print("%s\t%s" % (d.get("project_id", ""), d.get("team_id", "")))' 2>/dev/null
}

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
# The derived name belongs to the derived id. A declared team wears its own key
# rather than whichever name the worktree happened to derive -- the record holds
# the key, and a caller printing an empty name reads a declared team as
# unresolved.
if team_src == "derived":
    name = fb.get("team_name", "")
if not name:
    name = key
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

# herdr_linear::context_pair [workspace-id]
#
# The context's own (project, team) as `project<US>team`. The two store reads a
# judgement would otherwise make per row, made once.
#
# US, not tab: a tab is IFS whitespace, so an empty project would fold and the
# team would arrive in the project's place -- everything then reads as outside.
herdr_linear::context_pair() {
    local ws="${1:-}" team project
    team="$(herdr_linear::session_team 2>/dev/null)" || team=""
    project="$(herdr_linear::_space_project "$ws")"
    printf '%s\037%s' "$project" "$team"
}

# herdr_linear::pair_inside <project> <team> <context-project> <context-team>
#
# THE ONE COMPARISON. Nothing here reads a record or asks Linear, so a listing
# resolves the context once and judges every row against the pair it holds, and
# "one comparison" is a property of the code rather than a claim in a comment.
#
# An issue is inside when its project is the context's project AND, when a team
# is declared, its team is that team. Both halves are needed: a project may span
# several teams, so the project test alone admits another team's issue in the
# very project the space is bound to. A half the context left empty declares
# nothing and narrows nothing.
herdr_linear::pair_inside() {
    local ip="${1:-}" it="${2:-}" cp="${3:-}" ct="${4:-}"
    [ -n "$cp" ] || [ -n "$ct" ] || return "$HERDR_LINEAR_CONTEXT_INSIDE"
    if [ -n "$cp" ] && [ "$ip" != "$cp" ]; then
        return "$HERDR_LINEAR_CONTEXT_OUTSIDE"
    fi
    if [ -n "$ct" ] && [ "$it" != "$ct" ]; then
        return "$HERDR_LINEAR_CONTEXT_OUTSIDE"
    fi
    return "$HERDR_LINEAR_CONTEXT_INSIDE"
}

# herdr_linear::context_allows_fields <project-id> <team-id> [workspace-id]
#
# The one-shot form: resolve the context, then judge. A caller with more than
# one row to judge resolves once with `context_pair` and calls `pair_inside`.
herdr_linear::context_allows_fields() {
    local ws="${3:-}" pair
    pair="$(herdr_linear::context_pair "$ws")"
    herdr_linear::pair_inside "${1:-}" "${2:-}" "${pair%%$'\037'*}" "${pair##*$'\037'}"
}

# herdr_linear::context_allows_team <team-id>
#
# Whether the session's own declared team is <team-id>. A session with no
# declared team answers INSIDE to every team -- a level that declares nothing
# narrows nothing.
herdr_linear::context_allows_team() {
    local id="${1:-}" team
    [ -n "$id" ] || return "$HERDR_LINEAR_CONTEXT_UNKNOWN"
    team="$(herdr_linear::session_team 2>/dev/null)" || team=""
    [ -n "$team" ] || return "$HERDR_LINEAR_CONTEXT_INSIDE"
    [ "$team" = "$id" ] && return "$HERDR_LINEAR_CONTEXT_INSIDE"
    return "$HERDR_LINEAR_CONTEXT_OUTSIDE"
}

# herdr_linear::space_may_bind_project <project-id> [workspace-id]
#
# Whether this space may be BOUND to <project-id> -- true when the project
# carries the session's declared team. This is the question every caller asks
# before writing a binding; it does not compare against the space's current
# project (that comparison is `context_allows_fields`, via `pair_inside`), so a
# space already bound elsewhere still answers this on the session's team alone.
herdr_linear::space_may_bind_project() {
    local id="${1:-}" ws="${2:-}" team
    [ -n "$id" ] || return "$HERDR_LINEAR_CONTEXT_UNKNOWN"
    team="$(herdr_linear::session_team 2>/dev/null)" || team=""
    [ -n "$team" ] || return "$HERDR_LINEAR_CONTEXT_INSIDE"
    herdr_linear::team_in_project "$team" "$id" "$ws"
}

# herdr_linear::context_allows_issue <identifier> [workspace-id]
#
# Whether <identifier> is inside the resolved context. Fetches the issue's own
# project-and-team pair and hands it to `pair_inside`, which is where the rule
# is written.
herdr_linear::context_allows_issue() {
    local id="${1:-}" ws="${2:-}" team project ctx ip it pair
    [ -n "$id" ] || return "$HERDR_LINEAR_CONTEXT_UNKNOWN"
    team="$(herdr_linear::session_team 2>/dev/null)" || team=""
    project="$(herdr_linear::_space_project "$ws")"
    [ -n "$team" ] || [ -n "$project" ] || return "$HERDR_LINEAR_CONTEXT_INSIDE"
    ctx="$(herdr_linear::issue_context "$id" 2>/dev/null)" \
        || return "$HERDR_LINEAR_CONTEXT_UNKNOWN"
    pair="$(herdr_linear::_ctx_pair "$ctx")"
    ip="$(printf '%s' "$pair" | cut -f1)"
    it="$(printf '%s' "$pair" | cut -f2)"
    herdr_linear::context_allows_fields "$ip" "$it" "$ws"
}

# ------------------------------------------------------- the surface's prefix

HERDR_LINEAR_UNBOUND_PREFIX='UNBOUND: '

# herdr_linear::unbound_prefix [identifier] [workspace-id]
#
# The prefix a surface wears while it holds work its context does not cover, or
# nothing. THE ONLY PLACE THE PREFIX IS DECIDED. lib/herdr-write.sh applies it,
# to a new tab in `_tab_label` and to one already open in `retitle_tab`, so a
# title cannot drift from the record it is meant to report.
#
# Only a definite OUTSIDE brands a surface -- a context that could not be asked
# is not an answer, and branding on it would title every tab UNBOUND whenever
# Linear is unreachable. With no identifier there is no work to judge, so
# nothing is reported; a surface holding work no binding names is branded by
# whatever verb knows it, not by guessing here.
herdr_linear::unbound_prefix() {
    local ident="${1:-}" ws="${2:-}" rc
    [ -n "$ident" ] || return 0
    herdr_linear::context_allows_issue "$ident" "$ws"; rc=$?
    [ "$rc" -eq "$HERDR_LINEAR_CONTEXT_OUTSIDE" ] && printf '%s' "$HERDR_LINEAR_UNBOUND_PREFIX"
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
    local top tab wt ctx pair project team pair_key repo

    top="$("$git" -C "$dir" --no-optional-locks rev-parse --show-toplevel 2>/dev/null)" || top=""
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
    pair="$(herdr_linear::_ctx_pair "$ctx")"
    project="$(printf '%s' "$pair" | cut -f1)"
    team="$(printf '%s' "$pair" | cut -f2)"
    # A key `pair_key` refuses states nothing to place a pane at, and this
    # refuses nothing itself: the unsafe or dot-bearing id reads the same as no
    # repository recorded, and only the caller of a WRITE path says why.
    pair_key="$(herdr_linear::pair_key "$project" "$team" 2>/dev/null)" || return 0

    repo="$(herdr_linear::scope_repo "$pair_key" 2>/dev/null)" || return 0
    [ -n "$repo" ] && [ -d "$repo" ] && printf '%s' "$repo"
    return 0
}
