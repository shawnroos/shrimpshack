#!/usr/bin/env bats

load setup_common

# U9 — the untidy states.
#
# Both states exist to STOP the plugin doing something, so every test here
# checks that nothing was changed. A plugin that moved a worktree's issue to
# match whatever workspace it happens to be sitting in, or that reopened a
# ticket someone had just closed, would be undoing decisions a person made
# deliberately.

bats_require_minimum_version 1.5.0

setup() {
    ROOT="${BATS_TEST_DIRNAME}/../.."
    FIX="${BATS_TEST_DIRNAME}/../fixtures"
    WORK="$(mktemp -d)"

    export HERDR_LINEAR_PROJECTS_ROOT="$WORK/root"
    export HERDR_LINEAR_STORE_DIR="$WORK/store"
    export HERDR_LINEAR_PIN_DIR="$WORK/pin"
    export HERDR_LINEAR_CURL_BIN="$FIX/fake-linear.sh"
    export HERDR_LINEAR_SECURITY_BIN="$FIX/fake-security.sh"
    export FAKE_SECURITY_STORE_DIR="$WORK/kc"
    export FAKE_LINEAR_RECORD_DIR="$WORK/rec"
    export LINEAR_CACHE_DIR="$WORK/cache"
    export LINEAR_SECRETS_FILE="$WORK/secrets"
    export HERDR_LINEAR_SHADOW_LOG="$WORK/shadow.log"
    mkdir -p "$WORK/root" "$WORK/rec" "$WORK/cache"
    printf 'LINEAR_API_KEY=%s\n' "lin_api""_STATESSTATESSTATES1" > "$LINEAR_SECRETS_FILE"

    # shellcheck source=/dev/null
    for f in contain.sh secrets.sh binding.sh scope-record.sh linear.sh reconcile.sh states.sh; do . "$ROOT/lib/$f"; done

    WT="$WORK/root/wt"; mkdir -p "$WT"
    git -C "$WT" init -q -b feature/web-2670-blur
    git -C "$WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

    CANVAS="44444444-4444-4444-8444-444444444444"
    OTHER="99999999-9999-4999-8999-999999999999"
}

teardown() { [ -n "${WORK:-}" ] && rm -rf "$WORK"; }

bind_wt() { local n; n="$(herdr_linear::binding_propose "$WT" WEB-2670)"; herdr_linear::binding_confirm "$WT" WEB-2670 "$n"; }
# The ids the fake tracker puts on every issue in these fixtures.
grant_consent() {
    local dir="$1" team="${2:-55555555-5555-4555-8555-555555555555}"
    local project="${3-44444444-4444-4444-8444-444444444444}" n
    n="$(herdr_linear::consent_propose "$dir" "$team" "$project")"
    herdr_linear::consent_confirm "$dir" "$team" "$project" "$n"
}
# classify RETURNS the state as its exit code, so every call goes through `run`.
# A bare call trips errexit on a perfectly normal "this is misplaced" answer.
bind_ws() { local n; n="$(herdr_linear::workspace_propose "$1" "$2")"; herdr_linear::workspace_confirm "$1" "$2" "$n"; }
mutations_sent() { local n; n="$(grep -c 'issueUpdate' "$FAKE_LINEAR_RECORD_DIR/bodies" 2>/dev/null)" || n=0; printf '%s' "${n:-0}"; }

# ------------------------------------------------------------- misplaced (R22)

# AE5. Both sides are named, and NEITHER remedy is applied -- moving the issue
# or moving the workspace are both decisions a person makes.
@test "a worktree in a workspace bound to another project reports the mismatch and applies neither remedy" {
    bind_wt
    bind_ws w1 "$CANVAS"
    export FAKE_LINEAR_MODE=other_project_issue
    run herdr_linear::check_placement "$WT" w1
    [ "$status" -eq 1 ]
    [[ "$output" == *"WEB-2670"* ]]
    [[ "$output" == *"$OTHER"* ]]
    [[ "$output" == *"$CANVAS"* ]]
    [[ "$output" == *"writes are suspended"* ]]
    [[ "$output" == *"/work:bind"* ]]
    [ "$(mutations_sent)" = "0" ]
}

@test "matching projects are not a mismatch" {
    bind_wt
    bind_ws w1 "$CANVAS"
    export FAKE_LINEAR_MODE=found_parent
    run herdr_linear::check_placement "$WT" w1
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# Most workspaces are unbound and always will be. Reporting every worktree in
# one as misplaced makes the state meaningless within a day, and a warning
# nobody can clear is one everybody learns to ignore.
@test "a workspace with no binding does not make every worktree in it misplaced" {
    bind_wt
    export FAKE_LINEAR_MODE=other_project_issue
    run herdr_linear::check_placement "$WT" w1
    [ "$status" -eq 3 ]
    [ -z "$output" ]
}

@test "a merely proposed workspace binding is not enough to judge a mismatch" {
    bind_wt
    herdr_linear::workspace_propose w1 "$CANVAS" >/dev/null
    export FAKE_LINEAR_MODE=other_project_issue
    run herdr_linear::check_placement "$WT" w1
    [ "$status" -eq 3 ]
}

@test "an unbound worktree is never misplaced" {
    bind_ws w1 "$CANVAS"
    export FAKE_LINEAR_MODE=other_project_issue
    run herdr_linear::check_placement "$WT" w1
    [ "$status" -eq 3 ]
}

# Comparing on names would let a rename silently clear a real mismatch, and two
# projects can share a name.
@test "the comparison is on the project id, not its name" {
    bind_wt
    bind_ws w1 "$CANVAS"
    export FAKE_LINEAR_MODE=other_project_issue
    run herdr_linear::check_placement "$WT" w1
    [ "$status" -eq 1 ]
    # The report names ids, so a reader can act on it without guessing.
    [[ "$output" == *"$OTHER"* ]]
}

# ----------------------------------------------------------------- stale (R23)

# AE6. Reported, and nothing is reopened. Someone closed that ticket on purpose.
@test "a completed issue with a live worktree is reported and not reopened" {
    bind_wt
    export FAKE_LINEAR_MODE=completed_issue FAKE_LINEAR_ALLOW_MUTATION=1
    run herdr_linear::check_liveness "$WT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"WEB-2670 is completed in Linear"* ]]
    [[ "$output" == *"Nothing has been changed"* ]]
    [ "$(mutations_sent)" = "0" ]
}

@test "a canceled issue is treated the same as a completed one" {
    bind_wt
    export FAKE_LINEAR_MODE=canceled_issue FAKE_LINEAR_ALLOW_MUTATION=1
    run herdr_linear::check_liveness "$WT"
    [ "$status" -eq 2 ]
    [[ "$output" == *"canceled"* ]]
    [ "$(mutations_sent)" = "0" ]
}

@test "an open issue is not stale" {
    bind_wt
    export FAKE_LINEAR_MODE=found_parent
    run herdr_linear::check_liveness "$WT"
    [ "$status" -eq 0 ]
}

# ------------------------------------------------------- suspending writes

@test "a misplaced binding suspends the reconciliation write until it is resolved" {
    bind_wt
    bind_ws w1 "$CANVAS"
    grant_consent "$WT"
    export FAKE_LINEAR_MODE=other_project_issue FAKE_LINEAR_ALLOW_MUTATION=1

    run herdr_linear::classify "$WT" w1
    [ "$status" -eq 1 ]
    [ "$(herdr_linear::binding_state "$WT")" = "misplaced" ]

    run herdr_linear::reconcile "$WT"
    [ "$status" -eq 4 ]
    [ "$(mutations_sent)" = "0" ]

    # And the bound itself refuses, not only reconcile's own state check.
    run herdr_linear::write_allowed "$WT" WEB-2670
    [ "$status" -eq 5 ]
}

@test "a stale binding suspends the reconciliation write too" {
    bind_wt
    grant_consent "$WT"
    export FAKE_LINEAR_MODE=completed_issue FAKE_LINEAR_ALLOW_MUTATION=1
    run herdr_linear::classify "$WT" ""
    [ "$status" -eq 2 ]
    [ "$(herdr_linear::binding_state "$WT")" = "stale" ]
    run herdr_linear::write_allowed "$WT" WEB-2670
    [ "$status" -eq 5 ]
}

# ---------------------------------------------------------------- clearing

@test "the misplaced state clears when the mismatch is gone, and writes resume" {
    bind_wt
    bind_ws w1 "$CANVAS"
    export FAKE_LINEAR_MODE=other_project_issue
    run herdr_linear::classify "$WT" w1
    [ "$status" -eq 1 ]
    [ "$(herdr_linear::binding_state "$WT")" = "misplaced" ]

    # The remedy Shawn chose: the issue now sits in the workspace's project.
    export FAKE_LINEAR_MODE=found_parent
    run herdr_linear::classify "$WT" w1
    [ "$status" -eq 0 ]
    [ "$(herdr_linear::binding_state "$WT")" = "bound" ]
    run herdr_linear::write_allowed "$WT" WEB-2670
    [ "$status" -eq 0 ]
}

# The FIXTURE IS HELD CONSTANT ACROSS BOTH CALLS. The test above flips it
# between them, which is why it missed this: both checks used to refuse to run
# unless the state was exactly `bound`, so once misplaced was set neither could
# run again and the next pass cleared it with the mismatch untouched. The
# suspension lasted exactly one pass.
@test "a mismatch that is still there stays misplaced on the next pass" {
    bind_wt
    bind_ws w1 "$CANVAS"
    export FAKE_LINEAR_MODE=other_project_issue
    run herdr_linear::classify "$WT" w1
    [ "$status" -eq 1 ]
    [ "$(herdr_linear::binding_state "$WT")" = "misplaced" ]

    run herdr_linear::classify "$WT" w1
    [ "$status" -eq 1 ]
    [ "$(herdr_linear::binding_state "$WT")" = "misplaced" ]
    run herdr_linear::write_allowed "$WT" WEB-2670
    [ "$status" -eq 5 ]
}

@test "an issue that is still closed stays stale on the next pass" {
    bind_wt
    export FAKE_LINEAR_MODE=completed_issue
    run herdr_linear::classify "$WT" ""
    [ "$status" -eq 2 ]
    [ "$(herdr_linear::binding_state "$WT")" = "stale" ]

    run herdr_linear::classify "$WT" ""
    [ "$status" -eq 2 ]
    [ "$(herdr_linear::binding_state "$WT")" = "stale" ]
    run herdr_linear::write_allowed "$WT" WEB-2670
    [ "$status" -eq 5 ]
}

# UNKNOWN is not OK. The SessionEnd hook passes no workspace id it can trust, so
# placement is unjudgeable there -- and a pass that could not look must not
# clear a suspension somebody else's pass raised.
@test "a pass that cannot judge placement does not clear a misplaced binding" {
    bind_wt
    bind_ws w1 "$CANVAS"
    export FAKE_LINEAR_MODE=other_project_issue
    run herdr_linear::classify "$WT" w1
    [ "$(herdr_linear::binding_state "$WT")" = "misplaced" ]

    export FAKE_LINEAR_MODE=found_parent
    run herdr_linear::classify "$WT" ""
    [ "$(herdr_linear::binding_state "$WT")" = "misplaced" ]
}

# THE case the narrow clearing exists for. An unbound worktree -- one whose
# candidate was declined -- must stay unbound. Making the clear unconditional
# turns classify into something that BINDS a worktree nobody bound, which is the
# one thing the whole propose-and-confirm design exists to prevent.
@test "classify never binds a worktree that was never bound" {
    [ "$(herdr_linear::binding_state "$WT")" = "unbound" ]
    export FAKE_LINEAR_MODE=found_parent
    run herdr_linear::classify "$WT" ""
    [ "$status" -eq 0 ]
    [ "$(herdr_linear::binding_state "$WT")" = "unbound" ]
}

@test "classify never binds a worktree whose candidate was declined" {
    herdr_linear::binding_propose "$WT" WEB-2670 >/dev/null
    herdr_linear::binding_decline "$WT" WEB-2670
    export FAKE_LINEAR_MODE=found_parent
    run herdr_linear::classify "$WT" ""
    [ "$(herdr_linear::binding_state "$WT")" = "unbound" ]
}

# The branch-downgrade case is covered by the read path rather than by clearing:
# the downgrade is computed on every read, so even a blanket write could not
# resurrect it. Kept because it pins that interaction.
@test "clearing does not resurrect a binding downgraded by a branch change" {
    bind_wt
    git -C "$WT" checkout -q -b somewhere-else
    [ "$(herdr_linear::binding_state "$WT")" = "proposed" ]
    export FAKE_LINEAR_MODE=found_parent
    run herdr_linear::classify "$WT" ""
    [ "$(herdr_linear::binding_state "$WT")" = "proposed" ]
}

# ------------------------------------------------------------- the skill

@test "the bind skill documents both remedies for a misplaced binding" {
    body="$(cat "$ROOT/skills/bind/SKILL.md")"
    [[ "$body" == *"misplaced"* ]]
}

# ------------------------------------- the session level's own contradiction
#
# The unattended half of the settled decision: a read path that finds the bound
# issue outside the session's declared team has nobody to ask, so it records
# `misplaced` and suspends writes. UNKNOWN is not a contradiction -- a Linear
# that could not be asked must change nothing.
#
# The state goes on the BINDING, which is the record that contradicts its
# parent. On the session it would suspend every pane in that session for one
# bad worktree, and the clear-back would be last-writer-wins.

declare_session_team() {
    export HERDR_SOCKET_PATH="$WORK/herdr/sessions/alpha/herdr.sock"
    local n; n="$(herdr_linear::session_propose "$1")"
    herdr_linear::session_confirm "$1" "$n" "${2:-}"
}

bind_other_wt() {   # bind_other_wt <dir> <identifier>
    mkdir -p "$1"
    git -C "$1" init -q -b feature/other
    git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    local n; n="$(herdr_linear::binding_propose "$1" "$2")"
    herdr_linear::binding_confirm "$1" "$2" "$n"
}

@test "an issue outside the session's team records misplaced on the binding" {
    declare_session_team 55555555-5555-4555-8555-555555555555 WEB
    bind_wt
    export FAKE_LINEAR_MODE=found_other_team
    run herdr_linear::classify "$WT" ""
    [ "$status" -eq "$HERDR_LINEAR_STATE_MISPLACED" ]
    [[ "$output" == *"WEB-2670"* ]]
    [[ "$output" == *"55555555-5555-4555-8555-555555555555"* ]]
    [ "$(herdr_linear::binding_state "$WT")" = "misplaced" ]
}

# The finding itself. One worktree outside the team must not suspend the
# session, and a second worktree that IS inside must not clear the first
# worktree's contradiction while it is still true.
@test "a worktree inside the team does not clear another worktree's contradiction" {
    declare_session_team 55555555-5555-4555-8555-555555555555 WEB
    bind_wt
    bind_other_wt "$WORK/root/wtb" WEB-2671

    export FAKE_LINEAR_MODE=found_other_team
    run herdr_linear::classify "$WT" ""
    [ "$status" -eq "$HERDR_LINEAR_STATE_MISPLACED" ]
    [ "$(herdr_linear::binding_state "$WT")" = "misplaced" ]

    export FAKE_LINEAR_MODE=found_child
    run herdr_linear::classify "$WORK/root/wtb" ""
    [ "$status" -eq 0 ]
    [ "$(herdr_linear::binding_state "$WT")" = "misplaced" ]
    [ "$(herdr_linear::binding_state "$WORK/root/wtb")" = "bound" ]
    [ "$(herdr_linear::session_state)" = "bound" ]
}

# Started from a binding that is NOT already misplaced, because a re-record of
# the state it already holds is indistinguishable from leaving it alone.
@test "a session contradiction that could not be judged is left exactly as it was" {
    declare_session_team 55555555-5555-4555-8555-555555555555 WEB
    bind_wt
    [ "$(herdr_linear::binding_state "$WT")" = "bound" ]
    export HERDR_LINEAR_CURL_BIN=/bin/false
    run herdr_linear::classify "$WT" ""
    [ "$status" -eq 0 ]
    [ "$(herdr_linear::binding_state "$WT")" = "bound" ]
}

@test "an issue back inside the session's team clears the suspension" {
    declare_session_team 55555555-5555-4555-8555-555555555555 WEB
    bind_wt
    export FAKE_LINEAR_MODE=found_other_team
    run herdr_linear::classify "$WT" ""
    [ "$(herdr_linear::binding_state "$WT")" = "misplaced" ]
    export FAKE_LINEAR_MODE=found_child
    run herdr_linear::classify "$WT" ""
    [ "$status" -eq 0 ]
    [ "$(herdr_linear::binding_state "$WT")" = "bound" ]
}

# -------------------------------------------------- the title on the surface

# The prefix is only honest if it tracks the state. classify is the one place
# that decides a binding is misplaced and the one place that decides it is not,
# so it is where the tab holding that work is retitled.
herdr_on() {
    export HERDR_BIN="$FIX/fake-herdr.sh"
    export FAKE_HERDR_RECORD_DIR="$WORK/hrec"
    export FAKE_HERDR_ALLOW_MUTATION=1
    mkdir -p "$WORK/hrec"
}
renames() {
    tr '\037' '|' < "$FAKE_HERDR_RECORD_DIR/argvq" 2>/dev/null | grep '^4|tab|rename|' || true
}

@test "the tab holding a binding that has just gone misplaced is titled UNBOUND" {
    herdr_on
    bind_wt
    bind_ws w1 "$CANVAS"
    herdr_linear::binding_set_tab "$WT" wA:t1
    export FAKE_LINEAR_MODE=other_project_issue
    run herdr_linear::classify "$WT" w1
    [ "$status" -eq 1 ]
    [ "$(renames)" = "4|tab|rename|wA:t1|UNBOUND: Plugin PM" ]
}

@test "the prefix comes off the tab when the mismatch is resolved" {
    herdr_on
    bind_wt
    bind_ws w1 "$CANVAS"
    herdr_linear::binding_set_tab "$WT" wA:t1
    export FAKE_LINEAR_MODE=other_project_issue
    run herdr_linear::classify "$WT" w1
    [ "$status" -eq 1 ]
    export FAKE_LINEAR_MODE=found_parent
    run herdr_linear::classify "$WT" w1
    [ "$status" -eq 0 ]
    [ "$(renames | tail -n1)" = "4|tab|rename|wA:t1|Plugin PM" ]
}

# classify runs at every session end. A pass that changed nothing must not
# spend a herdr round trip, and must not rewrite a title nobody moved.
@test "a mismatch that was already recorded does not retitle the tab again" {
    herdr_on
    bind_wt
    bind_ws w1 "$CANVAS"
    herdr_linear::binding_set_tab "$WT" wA:t1
    export FAKE_LINEAR_MODE=other_project_issue
    run herdr_linear::classify "$WT" w1
    rm -f "$FAKE_HERDR_RECORD_DIR/argv" "$FAKE_HERDR_RECORD_DIR/argvq"
    run herdr_linear::classify "$WT" w1
    [ "$status" -eq 1 ]
    [ ! -s "$FAKE_HERDR_RECORD_DIR/argv" ]
}

@test "a binding with no tab recorded asks herdr nothing" {
    herdr_on
    bind_wt
    bind_ws w1 "$CANVAS"
    export FAKE_LINEAR_MODE=other_project_issue
    run herdr_linear::classify "$WT" w1
    [ "$status" -eq 1 ]
    [ ! -s "$FAKE_HERDR_RECORD_DIR/argv" ]
}

# The title reports PLACEMENT. A binding that goes straight from misplaced to
# stale used to skip the clearing branch entirely and keep the prefix for a
# mismatch that was already resolved.
@test "the prefix comes off even when the issue was closed in the same pass" {
    herdr_on
    bind_wt
    bind_ws w1 "$CANVAS"
    herdr_linear::binding_set_tab "$WT" wA:t1
    export FAKE_LINEAR_MODE=other_project_issue
    run herdr_linear::classify "$WT" w1
    [ "$status" -eq 1 ]
    # Placed correctly now, and closed.
    export FAKE_LINEAR_MODE=completed_issue
    run herdr_linear::classify "$WT" w1
    [ "$status" -eq 2 ]
    [ "$(renames | tail -n1)" = "4|tab|rename|wA:t1|Plugin PM" ]
}
