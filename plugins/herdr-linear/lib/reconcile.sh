#!/usr/bin/env bash
# Compare the repository against Linear and write the difference. Sourced.
#
# SHADOW MODE IS ON BY DEFAULT, AND THAT IS THE POINT.
# This is the first code in the plugin that changes anything in Linear. Every
# mutation is computed in full and written to a log INSTEAD of being sent, until
# someone turns writes on for a specific worktree after reading what the log
# said it would have done. A tracker integration whose first act is an
# unreviewed write to a real ticket is how people stop trusting one.
#
# WHAT IT DOES NOT DO (R15)
# Linear's own GitHub integration is live for this team and already moves an
# issue Todo -> In Progress -> Done from a pull request. Verified on WEB-3172:
# the attachment was created from the branch name and the state moved with no
# manual step. So this covers only what that integration leaves behind -- most
# importantly work that landed with no pull request at all, which it never sees.
#
# THE GUARD CANNOT BE FORGOTTEN.
# herdr_linear::write_state takes the opening `updatedAt` as a required argument
# and calls the stale-write guard itself. A caller that had to remember to guard
# first is a caller that will eventually not. Same reasoning as the binding
# nonce: an argument that must be supplied cannot be skipped by accident.

HERDR_LINEAR_GH_BIN="${HERDR_LINEAR_GH_BIN:-gh}"
HERDR_LINEAR_GIT_BIN="${HERDR_LINEAR_GIT_BIN:-git}"

# Writes are OFF unless a worktree is listed here. The list is a file, one
# resolved worktree path per line, so turning writes on is a deliberate edit
# someone makes after reading a shadow log -- not a flag flipped in passing.
HERDR_LINEAR_WRITE_ALLOWLIST="${HERDR_LINEAR_WRITE_ALLOWLIST:-$HOME/.claude/herdr-linear/write-enabled}"
HERDR_LINEAR_SHADOW_LOG="${HERDR_LINEAR_SHADOW_LOG:-$HOME/.claude/herdr-linear/shadow.log}"

HERDR_LINEAR_RECONCILE_OK=0
HERDR_LINEAR_RECONCILE_NOTHING=1     # no difference to write
HERDR_LINEAR_RECONCILE_SHADOW=2      # computed and logged, deliberately not sent
HERDR_LINEAR_RECONCILE_PROPOSED=3    # needs judgment; recorded against the binding
HERDR_LINEAR_RECONCILE_REFUSED=4
HERDR_LINEAR_RECONCILE_FAILED=5

herdr_linear::_git() { "$HERDR_LINEAR_GIT_BIN" -C "$1" --no-optional-locks "${@:2}" 2>/dev/null; }

herdr_linear::_default_branch() {
    local wt="$1" ref
    ref="$(herdr_linear::_git "$wt" symbolic-ref --quiet refs/remotes/origin/HEAD)"
    if [ -n "$ref" ]; then printf '%s' "${ref#refs/remotes/origin/}"; return 0; fi
    for c in main master; do
        herdr_linear::_git "$wt" show-ref --verify --quiet "refs/remotes/origin/$c" && { printf '%s' "$c"; return 0; }
    done
    return 1
}

# The repository side, read explicitly rather than inferred from one signal.
# Prints `key=value` lines so a caller and a log see the same evidence.
herdr_linear::repo_signals() {
    local wt="$1" branch default merged upstream_gone pr_state ahead
    branch="$(herdr_linear::_current_branch "$wt")"
    [ -n "$branch" ] || return 1
    default="$(herdr_linear::_default_branch "$wt")" || default=""

    merged=no
    if [ -n "$default" ] && herdr_linear::_git "$wt" merge-base --is-ancestor HEAD "origin/$default"; then
        merged=yes
    fi

    # A branch that no longer exists on the remote. On its own this says
    # nothing: it happens when work lands AND when someone tidies up a branch
    # that was abandoned. Paired with merged=yes it is completion; alone it is a
    # judgment call, which is why it is reported rather than acted on.
    upstream_gone=no
    herdr_linear::_git "$wt" ls-remote --exit-code --heads origin "$branch" >/dev/null || upstream_gone=yes

    pr_state=none
    if command -v "$HERDR_LINEAR_GH_BIN" >/dev/null 2>&1; then
        pr_state="$("$HERDR_LINEAR_GH_BIN" pr view "$branch" --json state -q .state 2>/dev/null | tr '[:upper:]' '[:lower:]')"
        [ -n "$pr_state" ] || pr_state=none
    fi

    ahead=0
    if [ -n "$default" ]; then
        ahead="$(herdr_linear::_git "$wt" rev-list --count "origin/$default..HEAD" || echo 0)"
    fi

    printf 'branch=%s\ndefault=%s\nmerged=%s\nupstream_gone=%s\npr=%s\nahead=%s\n' \
        "$branch" "$default" "$merged" "$upstream_gone" "$pr_state" "$ahead"
}

# Map the signals to a Linear state TYPE, or to `judgment` when the repository
# does not settle it. Types, not names: every team names its states differently,
# and the names are read from the team at runtime.
herdr_linear::desired_state_type() {
    local signals="$1" merged pr upstream_gone ahead
    merged="$(printf '%s' "$signals" | sed -n 's/^merged=//p')"
    pr="$(printf '%s' "$signals" | sed -n 's/^pr=//p')"
    upstream_gone="$(printf '%s' "$signals" | sed -n 's/^upstream_gone=//p')"
    ahead="$(printf '%s' "$signals" | sed -n 's/^ahead=//p')"

    # Merged into the default branch is the one unambiguous completion signal,
    # whether or not a pull request existed. Work landing with no PR is exactly
    # the case Linear's own integration never sees.
    if [ "$merged" = yes ]; then printf 'completed'; return 0; fi

    # THE ORDER HERE IS THE WHOLE DESIGN, and it is counter-intuitive.
    #
    # `merge-base --is-ancestor` answers NO for squash-merged work: the squash
    # creates a new commit and the branch's own commits never become ancestors
    # of the default branch. Squash is the default merge here, so "commits not
    # merged, branch gone from the remote" is what LANDED work looks like most
    # of the time -- not what abandoned work looks like.
    #
    # It is also what abandoned work looks like, and what a rebase looks like.
    # The repository genuinely cannot tell them apart, so this must be asked
    # rather than guessed. Testing `ahead > 0` BEFORE this sent every
    # squash-merged branch to `started`, quietly moving finished work back to
    # In Progress -- the exact opposite of what happened.
    if [ "$upstream_gone" = yes ]; then printf 'judgment'; return 0; fi

    if [ "$pr" = open ]; then printf 'started'; return 0; fi
    if [ "${ahead:-0}" -gt 0 ] 2>/dev/null; then printf 'started'; return 0; fi
    printf 'none'
}

# The team's own states, by type. Read at runtime because names differ per team
# and a hardcoded "Done" is wrong the first time another team is used.
herdr_linear::team_state_id() {
    local team_key="$1" want_type="$2" body resp
    body="$(python3 -c '
import sys, json
q = ("query($k:String!){teams(filter:{key:{eq:$k}},first:1){nodes{"
     "states{nodes{id name type}}}}}")
print(json.dumps({"query": q, "variables": {"k": sys.argv[1]}}))
' "$team_key")" || return 1
    resp="$(herdr_linear::query "$body")" || return 1
    printf '%s' "$resp" | HERDR_LINEAR_WANT="$want_type" python3 -c '
import sys, json, os
want = os.environ["HERDR_LINEAR_WANT"]
try:
    nodes = json.load(sys.stdin)["data"]["teams"]["nodes"]
    states = nodes[0]["states"]["nodes"]
except Exception:
    sys.exit(1)
for s in states:
    if s.get("type") == want:
        sys.stdout.write(s["id"]); sys.exit(0)
sys.exit(1)
'
}

# herdr_linear::write_state <worktree> <identifier> <opening_updated_at> <state_id>
#
# The opening updatedAt is REQUIRED. The guard is called here, not by the
# caller, so no write path can exist that forgot to take it.
herdr_linear::write_state() {
    local wt="$1" ident="$2" opening="$3" state_id="$4" body resp

    [ -n "$ident" ] && [ -n "$opening" ] && [ -n "$state_id" ] \
        || return "$HERDR_LINEAR_RECONCILE_REFUSED"

    # R30. The bound issue, or one this plugin created beneath it. Nothing else.
    herdr_linear::write_allowed "$wt" "$ident" || return "$HERDR_LINEAR_RECONCILE_REFUSED"

    # KTD7, and it is checked HERE so it cannot be skipped.
    herdr_linear::guard_unchanged "$ident" "$opening" || return "$HERDR_LINEAR_RECONCILE_REFUSED"

    body="$(python3 -c '
import sys, json
q = "mutation($id:String!,$s:String!){issueUpdate(id:$id,input:{stateId:$s}){success}}"
print(json.dumps({"query": q, "variables": {"id": sys.argv[1], "s": sys.argv[2]}}))
' "$ident" "$state_id")" || return "$HERDR_LINEAR_RECONCILE_FAILED"

    resp="$(herdr_linear::query "$body")" || return "$HERDR_LINEAR_RECONCILE_FAILED"

    # Recorded from the API's OWN answer. Reaching the end of this function is
    # not evidence that anything changed -- a 200 carrying success:false is a
    # failed write that every "did we get here" check reads as a success.
    printf '%s' "$resp" | python3 -c '
import sys, json
try:
    ok = json.load(sys.stdin)["data"]["issueUpdate"]["success"]
except Exception:
    sys.exit(1)
sys.exit(0 if ok is True else 1)
' || return "$HERDR_LINEAR_RECONCILE_FAILED"

    return "$HERDR_LINEAR_RECONCILE_OK"
}

herdr_linear::writes_enabled() {
    local wt resolved
    resolved="$(cd "${1:-}" 2>/dev/null && pwd -P)" || return 1
    [ -r "$HERDR_LINEAR_WRITE_ALLOWLIST" ] || return 1
    grep -qxF "$resolved" "$HERDR_LINEAR_WRITE_ALLOWLIST" 2>/dev/null
}

herdr_linear::_shadow_log() {
    mkdir -p "$(dirname "$HERDR_LINEAR_SHADOW_LOG")" 2>/dev/null
    printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$HERDR_LINEAR_SHADOW_LOG"
}

# The whole pass for one worktree.
herdr_linear::reconcile() {
    local wt="${1:-}" ident signals want ctx cur_type team opening state_id rc

    herdr_linear::contains "$wt" || return "$HERDR_LINEAR_RECONCILE_REFUSED"
    [ "$(herdr_linear::binding_state "$wt" 2>/dev/null)" = "bound" ] \
        || return "$HERDR_LINEAR_RECONCILE_REFUSED"
    ident="$(herdr_linear::binding_identifier "$wt")" || return "$HERDR_LINEAR_RECONCILE_REFUSED"

    signals="$(herdr_linear::repo_signals "$wt")" || return "$HERDR_LINEAR_RECONCILE_NOTHING"
    want="$(herdr_linear::desired_state_type "$signals")"
    [ "$want" != none ] || return "$HERDR_LINEAR_RECONCILE_NOTHING"

    # R17. Anything the repository does not settle becomes a proposal recorded
    # against the binding. It is never prompted from here -- this is a hook, and
    # KTD13 keeps hooks silent; U6 surfaces it at the next session.
    if [ "$want" = judgment ]; then
        herdr_linear::binding_set_judgment "$wt" \
            "The branch for $ident is gone from the remote, and its commits are not in the default branch. With squash merges that is what landed work looks like -- and also what abandoned or rebased work looks like. Is this finished, abandoned, or rebased?"
        return "$HERDR_LINEAR_RECONCILE_PROPOSED"
    fi

    ctx="$(herdr_linear::issue_context "$ident")" || return "$HERDR_LINEAR_RECONCILE_NOTHING"
    opening="$(printf '%s' "$ctx" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("updated_at",""))')"
    team="$(printf '%s' "$ctx" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("team",""))')"
    cur_type="$(herdr_linear::_state_type_of "$ident")"

    # Already there. Linear's GitHub integration usually got here first, and
    # writing the same value again is noise on someone's activity feed.
    [ "$cur_type" != "$want" ] || return "$HERDR_LINEAR_RECONCILE_NOTHING"

    state_id="$(herdr_linear::team_state_id "$team" "$want")" \
        || return "$HERDR_LINEAR_RECONCILE_NOTHING"

    if ! herdr_linear::writes_enabled "$wt"; then
        herdr_linear::_shadow_log "SHADOW would set $ident to type=$want (state $state_id); signals: $(printf '%s' "$signals" | tr '\n' ' ')"
        return "$HERDR_LINEAR_RECONCILE_SHADOW"
    fi

    herdr_linear::write_state "$wt" "$ident" "$opening" "$state_id"
    rc=$?
    [ "$rc" -eq 0 ] && herdr_linear::_shadow_log "WROTE $ident to type=$want"
    return "$rc"
}

herdr_linear::_state_type_of() {
    local resp
    resp="$(herdr_linear::fetch_issue "$1")" || return 1
    printf '%s' "$resp" | python3 -c 'import sys,json;print((json.load(sys.stdin)["data"]["issue"]["state"] or {}).get("type",""))' 2>/dev/null
}
