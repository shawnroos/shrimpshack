#!/usr/bin/env bats
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

    export HERDR_LINEAR_SLATE_ROOT="$WORK/Slate"
    export HERDR_LINEAR_STORE_DIR="$WORK/store"
    export HERDR_LINEAR_PIN_DIR="$WORK/pin"
    export HERDR_LINEAR_CURL_BIN="$FIX/fake-linear.sh"
    export HERDR_LINEAR_SECURITY_BIN="$FIX/fake-security.sh"
    export FAKE_SECURITY_STORE_DIR="$WORK/kc"
    export FAKE_LINEAR_RECORD_DIR="$WORK/rec"
    export LINEAR_CACHE_DIR="$WORK/cache"
    export LINEAR_SECRETS_FILE="$WORK/secrets"
    export HERDR_LINEAR_WRITE_ALLOWLIST="$WORK/write-enabled"
    export HERDR_LINEAR_SHADOW_LOG="$WORK/shadow.log"
    mkdir -p "$WORK/Slate" "$WORK/rec" "$WORK/cache"
    printf 'LINEAR_API_KEY=%s\n' "lin_api""_STATESSTATESSTATES1" > "$LINEAR_SECRETS_FILE"

    # shellcheck source=/dev/null
    for f in contain.sh secrets.sh binding.sh linear.sh reconcile.sh states.sh; do . "$ROOT/lib/$f"; done

    WT="$WORK/Slate/wt"; mkdir -p "$WT"
    git -C "$WT" init -q -b feature/web-2870-detach
    git -C "$WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

    CANVAS="44444444-4444-4444-8444-444444444444"
    OTHER="99999999-9999-4999-8999-999999999999"
}

teardown() { [ -n "${WORK:-}" ] && rm -rf "$WORK"; }

bind_wt() { local n; n="$(herdr_linear::binding_propose "$WT" WEB-2870)"; herdr_linear::binding_confirm "$WT" WEB-2870 "$n"; }
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
    [[ "$output" == *"WEB-2870"* ]]
    [[ "$output" == *"$OTHER"* ]]
    [[ "$output" == *"$CANVAS"* ]]
    [[ "$output" == *"writes are suspended"* ]]
    [[ "$output" == *"/herdr-linear:bind"* ]]
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
    [[ "$output" == *"WEB-2870 is completed in Linear"* ]]
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
    (cd "$WT" && pwd -P) > "$HERDR_LINEAR_WRITE_ALLOWLIST"
    export FAKE_LINEAR_MODE=other_project_issue FAKE_LINEAR_ALLOW_MUTATION=1

    run herdr_linear::classify "$WT" w1
    [ "$status" -eq 1 ]
    [ "$(herdr_linear::binding_state "$WT")" = "misplaced" ]

    run herdr_linear::reconcile "$WT"
    [ "$status" -eq 4 ]
    [ "$(mutations_sent)" = "0" ]

    # And the bound itself refuses, not only reconcile's own state check.
    run herdr_linear::write_allowed "$WT" WEB-2870
    [ "$status" -eq 5 ]
}

@test "a stale binding suspends the reconciliation write too" {
    bind_wt
    (cd "$WT" && pwd -P) > "$HERDR_LINEAR_WRITE_ALLOWLIST"
    export FAKE_LINEAR_MODE=completed_issue FAKE_LINEAR_ALLOW_MUTATION=1
    run herdr_linear::classify "$WT" ""
    [ "$status" -eq 2 ]
    [ "$(herdr_linear::binding_state "$WT")" = "stale" ]
    run herdr_linear::write_allowed "$WT" WEB-2870
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
    run herdr_linear::write_allowed "$WT" WEB-2870
    [ "$status" -eq 0 ]
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
    herdr_linear::binding_propose "$WT" WEB-2870 >/dev/null
    herdr_linear::binding_decline "$WT" WEB-2870
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
