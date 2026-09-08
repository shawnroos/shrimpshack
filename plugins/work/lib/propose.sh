#!/usr/bin/env bash
# Candidate generation for binding a worktree to an issue. Sourced, never run.
#
# WHY THE LIST IS SHORT ON PURPOSE (KTD12)
# There are 86 worktrees on this machine and branch matching reaches under a
# fifth of them, so the fallback path is the common one, not the exception. A
# list of forty issues is not a list anyone chooses from -- it is a list people
# dismiss. So the fallback offers a handful, and when its filter is empty it
# SAYS SO AND STOPS rather than widening. Widening a filter that found nothing
# is how a chooser ends up looking at every issue in the workspace.
#
# NOTHING HERE WRITES. It proposes. Only lib/binding.sh moves a record, and only
# a confirmation moves it to bound.

# Self-sourced rather than left to the caller's source list. The candidate block
# is read from a terminal and answered, so the filter has to be present wherever
# this file is, not wherever someone remembered to add it -- skills/bind is the
# real caller and lists its libraries by hand.
if ! command -v herdr_linear::sanitize_stream >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    . "$(dirname "${BASH_SOURCE[0]}")/sanitize.sh"
fi

HERDR_LINEAR_CANDIDATE_LIMIT="${HERDR_LINEAR_CANDIDATE_LIMIT:-5}"

HERDR_LINEAR_PROPOSE_OK=0
HERDR_LINEAR_PROPOSE_NONE=1       # the filter was empty; say so, do not widen
HERDR_LINEAR_PROPOSE_OUTSIDE=2    # not under the Slate root
HERDR_LINEAR_PROPOSE_UNAVAILABLE=3

# The GraphQL for the fallback list. Assigned to the viewer, not in a terminal
# state, most recently updated first, and hard-capped.
herdr_linear::_candidate_query() {
    local project="${1:-}" limit="$2"
    python3 -c '
import sys, json
project, limit = sys.argv[1], int(sys.argv[2])
f = {"assignee": {"isMe": {"eq": True}},
     "state": {"type": {"nin": ["completed", "canceled"]}}}
if project:
    f["project"] = {"id": {"eq": project}}
q = ("query($f:IssueFilter,$n:Int){issues(first:$n,filter:$f,"
     "orderBy:updatedAt){nodes{identifier title updatedAt "
     "state{name type} project{id name} team{key}}}}")
print(json.dumps({"query": q, "variables": {"f": f, "n": limit}}))
' "$project" "$limit"
}

# herdr_linear::candidates <worktree> [workspace-id]
#
# Prints one candidate per line as `IDENTIFIER<TAB>TITLE<TAB>SOURCE`, most
# relevant first. SOURCE says which rule produced it, so whoever is choosing can
# see why an issue is on the list.
herdr_linear::candidates() {
    local wt="${1:-}" ws="${2:-}" branch ident resp project declined out=""

    herdr_linear::contains "$wt" || return "$HERDR_LINEAR_PROPOSE_OUTSIDE"

    # R4. A candidate already declined for this worktree is never offered again,
    # whichever rule would have produced it.
    declined="$(herdr_linear::binding_read "$wt" 2>/dev/null \
        | python3 -c 'import sys,json;print(" ".join(json.load(sys.stdin).get("declined") or []))' 2>/dev/null)" || declined=""

    is_declined() {
        case " $declined " in *" $1 "*) return 0 ;; esac
        return 1
    }

    # 1. The branch. One shape match, then one fetch by identifier -- a
    #    non-existent identifier is settled by the fetch returning nothing,
    #    which is an answer rather than a guess.
    branch="$(herdr_linear::_current_branch "$wt")"
    ident="$(herdr_linear::branch_identifier "$branch" 2>/dev/null)" || ident=""
    if [ -n "$ident" ] && ! is_declined "$ident"; then
        resp="$(herdr_linear::fetch_issue "$ident" 2>/dev/null)"
        case $? in
            0)
                out="$(printf '%s' "$resp" | python3 -c '
import sys, json
i = json.load(sys.stdin)["data"]["issue"]
print("%s\t%s\tbranch" % (i["identifier"], i.get("title", "")))
' 2>/dev/null)"
                if [ -n "$out" ]; then
                    printf '%s\n' "$out" | herdr_linear::sanitize_stream
                    return "$HERDR_LINEAR_PROPOSE_OK"
                fi
                ;;
            "$HERDR_LINEAR_UNAVAILABLE"|"$HERDR_LINEAR_AUTH"|"$HERDR_LINEAR_RATELIMITED")
                return "$HERDR_LINEAR_PROPOSE_UNAVAILABLE"
                ;;
        esac
    fi

    # 2. The fallback. Scoped to the workspace's bound project when there is
    #    one. When the workspace is unbound the plan says to scope by "the
    #    Linear team the worktree's repository belongs to" -- but no repo-to-team
    #    mapping exists on this machine, and inventing one would produce a
    #    confident wrong scope. The list is instead scoped only by assignee and
    #    state, and the SOURCE column says which it was, so the person choosing
    #    can see that the scope is wide.
    project=""
    if [ -n "$ws" ]; then
        project="$(herdr_linear::workspace_project "$ws" 2>/dev/null)" || project=""
        # A backstop, deliberately redundant: workspace_project already answers
        # empty for anything but a bound record, because propose writes a
        # candidate and only confirm writes the value. Mutating this line away
        # turns no test red. It stays so that a future change to what propose
        # records cannot silently make a proposed workspace scope the list.
        [ "$(herdr_linear::workspace_state "$ws" 2>/dev/null)" = "bound" ] || project=""
    fi

    resp="$(herdr_linear::query "$(herdr_linear::_candidate_query "$project" "$HERDR_LINEAR_CANDIDATE_LIMIT")" 2>/dev/null)" \
        || return "$HERDR_LINEAR_PROPOSE_UNAVAILABLE"

    out="$(HERDR_LINEAR_SRC="$([ -n "$project" ] && echo project || echo assignee)" \
        HERDR_LINEAR_DECLINED="$declined" \
        printf '%s' "$resp" | HERDR_LINEAR_SRC="$([ -n "$project" ] && echo project || echo assignee)" \
        HERDR_LINEAR_DECLINED="$declined" python3 -c '
import sys, json, os
src = os.environ.get("HERDR_LINEAR_SRC", "assignee")
declined = set((os.environ.get("HERDR_LINEAR_DECLINED") or "").split())
nodes = json.load(sys.stdin)["data"]["issues"]["nodes"]
for n in nodes:
    if n["identifier"] in declined:
        continue
    print("%s\t%s\t%s" % (n["identifier"], n.get("title", ""), src))
' 2>/dev/null)"

    # Emptiness is judged on the raw block, before the filter: a title made
    # entirely of stripped characters must still count as a candidate, or the
    # list silently shortens and the caller is told the filter found nothing.
    [ -n "$out" ] || return "$HERDR_LINEAR_PROPOSE_NONE"
    printf '%s\n' "$out" | herdr_linear::sanitize_stream
    return "$HERDR_LINEAR_PROPOSE_OK"
}
