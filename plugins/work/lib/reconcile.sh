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
HERDR_LINEAR_WRITE_ALLOWLIST="${HERDR_LINEAR_WRITE_ALLOWLIST:-$HOME/.claude/work/write-enabled}"
HERDR_LINEAR_SHADOW_LOG="${HERDR_LINEAR_SHADOW_LOG:-$HOME/.claude/work/shadow.log}"

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
    local wt="$1" branch default merged upstream_gone pr_state ahead branch_moved first head_sha
    branch="$(herdr_linear::_current_branch "$wt")"
    [ -n "$branch" ] || return 1
    default="$(herdr_linear::_default_branch "$wt")" || default=""

    merged=no
    if [ -n "$default" ] && herdr_linear::_git "$wt" merge-base --is-ancestor HEAD "origin/$default"; then
        merged=yes
    fi

    # Ancestry ALONE calls a brand-new worktree merged: a branch cut from the
    # default tip with nothing committed on it has HEAD == origin/default, so
    # `--is-ancestor` is true and the issue reconciled straight to Done at the
    # first session end. The branch's oldest reflog entry is where the branch
    # was cut; equal to HEAD means nothing was ever committed here.
    #
    # Two ways this answers `unknown`: reflogs expire (90 days by default) and
    # core.logAllRefUpdates can be off. Unknown refuses `completed`, so the cost
    # is missing a genuine landing on a very old branch rather than closing a
    # ticket nobody finished.
    branch_moved=unknown
    first="$(herdr_linear::_git "$wt" reflog show --format=%H "refs/heads/$branch" | tail -1)"
    head_sha="$(herdr_linear::_git "$wt" rev-parse HEAD)"
    if [ -n "$first" ] && [ -n "$head_sha" ]; then
        if [ "$first" = "$head_sha" ]; then branch_moved=no; else branch_moved=yes; fi
    fi

    # A branch that no longer exists on the remote. On its own this says
    # nothing: it happens when work lands AND when someone tidies up a branch
    # that was abandoned. Paired with merged=yes it is completion; alone it is a
    # judgment call, which is why it is reported rather than acted on.
    #
    # `ls-remote --exit-code` exits 2 for "no such ref" and 128 for "cannot
    # reach origin", and _git swallows stderr -- so an offline session end read
    # every live branch as deleted. Only a literal 2 is a deleted branch.
    if herdr_linear::_git "$wt" ls-remote --exit-code --heads origin "$branch" >/dev/null; then
        upstream_gone=no
    else
        case $? in
            2) upstream_gone=yes ;;
            *) upstream_gone=unknown ;;
        esac
    fi

    pr_state=none
    if command -v "$HERDR_LINEAR_GH_BIN" >/dev/null 2>&1; then
        pr_state="$("$HERDR_LINEAR_GH_BIN" pr view "$branch" --json state -q .state 2>/dev/null | tr '[:upper:]' '[:lower:]')"
        [ -n "$pr_state" ] || pr_state=none
    fi

    ahead=0
    if [ -n "$default" ]; then
        ahead="$(herdr_linear::_git "$wt" rev-list --count "origin/$default..HEAD" || echo 0)"
    fi

    printf 'branch=%s\ndefault=%s\nmerged=%s\nbranch_moved=%s\nupstream_gone=%s\npr=%s\nahead=%s\n' \
        "$branch" "$default" "$merged" "$branch_moved" "$upstream_gone" "$pr_state" "$ahead"
}

# Map the signals to a Linear state TYPE, or to `judgment` when the repository
# does not settle it. Types, not names: every team names its states differently,
# and the names are read from the team at runtime.
herdr_linear::desired_state_type() {
    local signals="$1" merged pr upstream_gone ahead branch_moved
    merged="$(printf '%s' "$signals" | sed -n 's/^merged=//p')"
    branch_moved="$(printf '%s' "$signals" | sed -n 's/^branch_moved=//p')"
    pr="$(printf '%s' "$signals" | sed -n 's/^pr=//p')"
    upstream_gone="$(printf '%s' "$signals" | sed -n 's/^upstream_gone=//p')"
    ahead="$(printf '%s' "$signals" | sed -n 's/^ahead=//p')"

    # Merged into the default branch is the one unambiguous completion signal,
    # whether or not a pull request existed. Work landing with no PR is exactly
    # the case Linear's own integration never sees.
    #
    # branch_moved is the discriminator between a landing and a worktree that
    # was opened and closed without a single commit. Do NOT reach for `ahead`
    # instead: a genuine merge leaves ahead=0 too.
    if [ "$merged" = yes ] && [ "$branch_moved" = yes ]; then printf 'completed'; return 0; fi

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
    #
    # `ahead > 0` here is not the ordering mistake described above -- it only
    # says there is work to ask ABOUT. A branch with no commits of its own that
    # was never pushed is also "gone from the remote", and asking whether it
    # landed or was abandoned is a question about nothing.
    if [ "$upstream_gone" = yes ] && [ "${ahead:-0}" -gt 0 ] 2>/dev/null; then printf 'judgment'; return 0; fi

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

    # An issue someone has closed stays closed. The equality test below is NOT
    # this check: canceled != started reads as a difference worth writing, so a
    # ticket cancelled mid-session came back as In Progress at session end.
    # states.sh says the same thing at the hook level; this is the half that
    # cannot be skipped by a caller that forgot to classify first.
    case "$cur_type" in
        completed)
            [ "$want" = completed ] || return "$HERDR_LINEAR_RECONCILE_NOTHING"
            ;;
        canceled)
            # Canceled is not "done early" -- somebody decided this work should
            # not happen. If the branch then lands, moving the ticket to Done
            # silently overrules that decision, so it is asked rather than
            # assumed. Every other terminal transition stays refused.
            if [ "$want" = completed ]; then
                herdr_linear::binding_set_judgment "$wt" \
                    "$ident is canceled in Linear, but its branch has landed. Someone decided this work should not happen; moving it to Done would overrule that. Close it, reopen it, or leave it canceled?"
                return "$HERDR_LINEAR_RECONCILE_PROPOSED"
            fi
            return "$HERDR_LINEAR_RECONCILE_NOTHING"
            ;;
    esac

    # Already there. Linear's GitHub integration usually got here first, and
    # writing the same value again is noise on someone's activity feed.
    [ "$cur_type" != "$want" ] || return "$HERDR_LINEAR_RECONCILE_NOTHING"

    state_id="$(herdr_linear::team_state_id "$team" "$want")" \
        || return "$HERDR_LINEAR_RECONCILE_NOTHING"

    if ! herdr_linear::writes_enabled "$wt"; then
        herdr_linear::_shadow_log "SHADOW would set $ident to type=$want (state $state_id); signals: $(printf '%s' "$signals" | tr '\n' ' ')"
        return "$HERDR_LINEAR_RECONCILE_SHADOW"
    fi

    # The shadow log is the only human-visible surface, and the hook throws
    # stdout and stderr away. Logging successes alone made every AUTH,
    # rate-limit, stale-guard and malformed-response failure invisible.
    if herdr_linear::write_state "$wt" "$ident" "$opening" "$state_id"; then
        rc=0
        herdr_linear::_shadow_log "WROTE $ident to type=$want"
    else
        rc=$?
        herdr_linear::_shadow_log "FAILED setting $ident to type=$want (state $state_id), rc=$rc"
    fi
    return "$rc"
}

# herdr_linear::nudge_description <worktree>
#
# ONCE BOUND, the hooks earn their keep. This one notices that the description
# no longer describes the work and records a note for the next session.
#
# It does NOT write the description, and could not: Problem, Solution and
# Proposal are prose about the actor and the intent, and a hook has nobody to
# ask and nothing to author from. It also does not prompt -- KTD13 keeps hooks
# silent, so this goes on the binding and U6 surfaces it once at the next
# session start, on the same path a judgment proposal takes.
herdr_linear::nudge_description() {
    local wt="${1:-}" head synced ahead default ident existing

    [ "$(herdr_linear::binding_state "$wt" 2>/dev/null)" = "bound" ] || return 1
    ident="$(herdr_linear::binding_identifier "$wt")" || return 1

    head="$(herdr_linear::_git "$wt" rev-parse HEAD)"
    [ -n "$head" ] || return 1
    synced="$(herdr_linear::binding_desc_head "$wt" 2>/dev/null)" || synced=""
    [ "$head" != "$synced" ] || return 1

    # Only when there is actually new work. A worktree sitting at the default
    # branch with nothing on it has no description to fall behind.
    default="$(herdr_linear::_default_branch "$wt")" || return 1
    ahead="$(herdr_linear::_git "$wt" rev-list --count "origin/$default..HEAD" || echo 0)"
    [ "${ahead:-0}" -gt 0 ] 2>/dev/null || return 1

    # Do not re-raise the same nudge every session end. A note that reappears
    # untouched is one a person learns to dismiss without reading.
    existing="$(herdr_linear::binding_read "$wt" 2>/dev/null \
        | python3 -c 'import sys,json;j=json.load(sys.stdin).get("pending_judgment") or {};print(j.get("text",""))' 2>/dev/null)" || existing=""
    case "$existing" in
        *"$head"*) return 1 ;;
    esac

    herdr_linear::binding_set_judgment "$wt" \
        "$ident has $ahead commit(s) the description does not cover (HEAD $head). If the work changed what the problem or the proposal is, rewrite it with /work:describe -- do not append a note."
    return 0
}

herdr_linear::_state_type_of() {
    local resp
    resp="$(herdr_linear::fetch_issue "$1")" || return 1
    printf '%s' "$resp" | python3 -c 'import sys,json;print((json.load(sys.stdin)["data"]["issue"]["state"] or {}).get("type",""))' 2>/dev/null
}
