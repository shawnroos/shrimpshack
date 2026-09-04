#!/usr/bin/env bats
# U8 — reconciliation writes.
#
# This is the first code in the plugin that can change anything in Linear, so
# the tests are organised around what must NOT happen: no write from an unbound
# worktree, none from outside the Slate root, none while shadow mode is on, none
# recorded when the API said it failed, and nothing that can hold a session open.
#
# The network is tests/fixtures/fake-linear.sh, which refuses any GraphQL
# mutation with exit 97 unless a test explicitly permits one. A path that started
# writing where it should not fails the suite rather than filing to the real
# workspace.

bats_require_minimum_version 1.5.0

# A `!`-negated command is exempt from errexit under POSIX, so `! grep -q X`
# anywhere but the last line detects the defect and lets the test pass anyway.
refute_match() {
    if grep "$@"; then
        printf 'refute_match: unexpectedly matched: %s\n' "$*" >&2
        return 1
    fi
    return 0
}

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
    export HERDR_LINEAR_GH_BIN="$WORK/no-such-gh"
    mkdir -p "$WORK/Slate" "$WORK/rec" "$WORK/cache"
    printf 'LINEAR_API_KEY=%s\n' "lin_api""_RECONCILERECONCILE1" > "$LINEAR_SECRETS_FILE"

    # shellcheck source=/dev/null
    for f in contain.sh secrets.sh binding.sh linear.sh reconcile.sh; do . "$ROOT/lib/$f"; done

    # A worktree with a real origin, so merged/upstream detection is exercised
    # rather than stubbed.
    ORIGIN="$WORK/origin.git"
    git init -q --bare -b main "$ORIGIN"
    WT="$WORK/Slate/wt"
    git init -q -b main "$WT"
    git -C "$WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
    git -C "$WT" remote add origin "$ORIGIN"
    git -C "$WT" push -q origin main
    git -C "$WT" checkout -q -b feature/web-2870-detach
    git -C "$WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m work
    git -C "$WT" push -q origin feature/web-2870-detach
    git -C "$WT" fetch -q origin
}

teardown() { [ -n "${WORK:-}" ] && rm -rf "$WORK"; }

bind_wt() {
    local n; n="$(herdr_linear::binding_propose "$WT" "${1:-WEB-2870}")"
    herdr_linear::binding_confirm "$WT" "${1:-WEB-2870}" "$n"
}

merge_into_main() {
    git -C "$WT" checkout -q main
    git -C "$WT" merge -q --no-edit feature/web-2870-detach
    git -C "$WT" push -q origin main
    git -C "$WT" checkout -q feature/web-2870-detach
    git -C "$WT" fetch -q origin
}

enable_writes() { (cd "$WT" && pwd -P) > "$HERDR_LINEAR_WRITE_ALLOWLIST"; }
# grep -c prints "0" AND exits 1 when there are no matches, so a trailing
# `|| echo 0` appends a SECOND zero and every "= 0" assertion fails against
# "0\n0". Capture into a variable instead.
mutations_sent() {
    local n
    n="$(grep -c 'issueUpdate' "$FAKE_LINEAR_RECORD_DIR/bodies" 2>/dev/null)" || n=0
    printf '%s' "${n:-0}"
}

# ----------------------------------------------------------- reading the repo

@test "unmerged work with commits ahead reads as started" {
    run herdr_linear::repo_signals "$WT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"merged=no"* ]]
    [[ "$output" == *"ahead=1"* ]]
    run herdr_linear::desired_state_type "$(herdr_linear::repo_signals "$WT")"
    [ "$output" = "started" ]
}

@test "work merged into the default branch reads as completed" {
    merge_into_main
    run herdr_linear::repo_signals "$WT"
    [[ "$output" == *"merged=yes"* ]]
    run herdr_linear::desired_state_type "$(herdr_linear::repo_signals "$WT")"
    [ "$output" = "completed" ]
}

# The case Linear's own GitHub integration never sees, and the reason R15 exists.
@test "merged with no pull request still reads as completed" {
    merge_into_main
    signals="$(herdr_linear::repo_signals "$WT")"
    [[ "$signals" == *"pr=none"* ]]
    run herdr_linear::desired_state_type "$signals"
    [ "$output" = "completed" ]
}

# A branch gone from the remote with nothing merged is abandonment, a rebase, or
# a tidy-up. Guessing between them writes the wrong thing to someone's board.
@test "a branch gone from the remote with nothing merged needs judgment" {
    git -C "$WT" push -q origin --delete feature/web-2870-detach
    git -C "$WT" fetch -q --prune origin
    signals="$(herdr_linear::repo_signals "$WT")"
    [[ "$signals" == *"upstream_gone=yes"* ]]
    [[ "$signals" == *"merged=no"* ]]
    run herdr_linear::desired_state_type "$signals"
    [ "$output" = "judgment" ]
}

# The case that made the original ordering wrong. A squash merge creates a new
# commit, so the branch's own commits never become ancestors of main -- the
# ancestry check says "not merged" for work that plainly landed, and the remote
# branch is gone. Testing `ahead > 0` first sent every squash-merged branch to
# `started`, moving finished work BACK to In Progress. Squash is the default
# merge here, so that was the common path, not an edge case.
@test "a squash-merged branch is asked about rather than moved back to started" {
    run herdr_linear::desired_state_type "$(printf 'merged=no\npr=none\nupstream_gone=yes\nahead=3\n')"
    [ "$output" = "judgment" ]
}

@test "an open pull request still reads as started while the branch exists" {
    run herdr_linear::desired_state_type "$(printf 'merged=no\npr=open\nupstream_gone=no\nahead=2\n')"
    [ "$output" = "started" ]
}

# ------------------------------------------------------------- shadow mode

# The default. Every mutation is computed in full and logged INSTEAD of sent.
@test "shadow mode computes the write, logs it, and sends nothing" {
    bind_wt WEB-2870
    merge_into_main
    export FAKE_LINEAR_MODE=found_parent
    run herdr_linear::reconcile "$WT"
    [ "$status" -eq 2 ]
    [ "$(mutations_sent)" = "0" ]
    run cat "$HERDR_LINEAR_SHADOW_LOG"
    [[ "$output" == *"SHADOW would set WEB-2870 to type=completed"* ]]
    # The evidence is logged with the decision, so a reader can judge it.
    [[ "$output" == *"merged=yes"* ]]
}

@test "an empty allowlist is not the same as a missing one -- both keep shadow mode on" {
    bind_wt WEB-2870
    merge_into_main
    export FAKE_LINEAR_MODE=found_parent
    : > "$HERDR_LINEAR_WRITE_ALLOWLIST"
    run herdr_linear::reconcile "$WT"
    [ "$status" -eq 2 ]
    [ "$(mutations_sent)" = "0" ]
}

# A path prefix must not enable a sibling worktree. The allowlist is matched
# whole-line, so `.../wt` does not enable `.../wt-other`.
@test "the allowlist matches a whole path, not a prefix" {
    bind_wt WEB-2870
    merge_into_main
    export FAKE_LINEAR_MODE=found_parent
    printf '%s\n' "$(cd "$WT" && pwd -P)-other" > "$HERDR_LINEAR_WRITE_ALLOWLIST"
    run herdr_linear::reconcile "$WT"
    [ "$status" -eq 2 ]
    [ "$(mutations_sent)" = "0" ]
}

# ------------------------------------------------------------- writing (AE3)

@test "with writes enabled, work landed with no pull request is completed in Linear" {
    bind_wt WEB-2870
    merge_into_main
    enable_writes
    export FAKE_LINEAR_MODE=found_parent
    export FAKE_LINEAR_ALLOW_MUTATION=1
    run herdr_linear::reconcile "$WT"
    [ "$status" -eq 0 ]
    [ "$(mutations_sent)" = "1" ]
    run grep -c 'st-done' "$FAKE_LINEAR_RECORD_DIR/bodies"
    [ "$output" = "1" ]
}

# The state id comes from the team at runtime, never from a hardcoded name --
# every team names its states differently.
@test "the target state is looked up on the team rather than hardcoded" {
    bind_wt WEB-2870
    merge_into_main
    enable_writes
    export FAKE_LINEAR_MODE=found_parent FAKE_LINEAR_ALLOW_MUTATION=1
    run herdr_linear::reconcile "$WT"
    [ "$status" -eq 0 ]
    run grep -c 'teams(' "$FAKE_LINEAR_RECORD_DIR/bodies"
    [ "$output" = "1" ]
}

# Linear's own integration usually gets there first. Writing the same value
# again is noise on someone's activity feed.
@test "an issue already in the target state is not written to" {
    bind_wt WEB-2870
    merge_into_main
    enable_writes
    # found_parent's state type is `started`; use an issue already completed.
    export FAKE_LINEAR_MODE=completed_issue FAKE_LINEAR_ALLOW_MUTATION=1
    run herdr_linear::reconcile "$WT"
    [ "$status" -eq 1 ]
    [ "$(mutations_sent)" = "0" ]
}

# A 200 carrying success:false is a FAILED write that every "did the function
# finish" check reads as a success.
@test "a mutation the API reports as unsuccessful is not recorded as a write" {
    bind_wt WEB-2870
    merge_into_main
    enable_writes
    export FAKE_LINEAR_MODE=found_parent FAKE_LINEAR_ALLOW_MUTATION=1
    export FAKE_LINEAR_MUTATION_RESULT=fail
    run herdr_linear::reconcile "$WT"
    [ "$status" -eq 5 ]
    # A failed write leaves no log at all, which is also "not recorded" -- the
    # assertion has to cover both, or a missing file reads as a grep error and
    # fails a test that is actually passing.
    if [ -f "$HERDR_LINEAR_SHADOW_LOG" ]; then
        refute_match -q 'WROTE' "$HERDR_LINEAR_SHADOW_LOG"
    fi
}

# KTD7, and the reason write_state takes the opening value as an argument: no
# write path can exist that forgot to guard.
@test "a write is refused when the issue moved during the pass" {
    bind_wt WEB-2870
    enable_writes
    export FAKE_LINEAR_ALLOW_MUTATION=1
    run herdr_linear::write_state "$WT" WEB-2870 "2026-09-04T18:11:48.336Z" st-done
    # found_parent_moved answers a different updatedAt than the opening value.
    FAKE_LINEAR_MODE=found_parent_moved run herdr_linear::write_state "$WT" WEB-2870 "2026-09-04T18:11:48.336Z" st-done
    [ "$status" -eq 4 ]
    [ "$(mutations_sent)" = "0" ]
}

@test "write_state refuses without an opening value at all" {
    bind_wt WEB-2870
    enable_writes
    export FAKE_LINEAR_MODE=found_parent FAKE_LINEAR_ALLOW_MUTATION=1
    run herdr_linear::write_state "$WT" WEB-2870 "" st-done
    [ "$status" -eq 4 ]
    [ "$(mutations_sent)" = "0" ]
}

# ---------------------------------------------------------------- boundaries

@test "an unbound worktree is never written from" {
    merge_into_main
    enable_writes
    export FAKE_LINEAR_MODE=found_parent FAKE_LINEAR_ALLOW_MUTATION=1
    run herdr_linear::reconcile "$WT"
    [ "$status" -eq 4 ]
    [ "$(mutations_sent)" = "0" ]
}

@test "a merely proposed worktree is never written from" {
    herdr_linear::binding_propose "$WT" WEB-2870 >/dev/null
    merge_into_main
    enable_writes
    export FAKE_LINEAR_MODE=found_parent FAKE_LINEAR_ALLOW_MUTATION=1
    run herdr_linear::reconcile "$WT"
    [ "$status" -eq 4 ]
    [ "$(mutations_sent)" = "0" ]
}

# ISOLATES the write bound. The reconcile-level tests above cannot: reconcile
# refuses an unbound worktree by its own state check before write_allowed is
# ever consulted, so deleting the bound from write_state left them green. This
# calls write_state directly, on a BOUND worktree, with a target that is neither
# the bound issue nor a recorded child -- the only shape that reaches the bound.
@test "write_state refuses a target that is not the bound issue or a recorded child" {
    bind_wt WEB-2870
    enable_writes
    export FAKE_LINEAR_MODE=found_parent FAKE_LINEAR_ALLOW_MUTATION=1
    run herdr_linear::write_state "$WT" WEB-9999 "2026-09-04T18:11:48.336Z" st-done
    [ "$status" -eq 4 ]
    [ "$(mutations_sent)" = "0" ]
}

@test "write_state accepts a recorded child, so the refusal above is the bound and not a blanket no" {
    bind_wt WEB-2870
    herdr_linear::binding_add_child "$WT" WEB-2870
    enable_writes
    export FAKE_LINEAR_MODE=found_parent FAKE_LINEAR_ALLOW_MUTATION=1
    run herdr_linear::write_state "$WT" WEB-2870 "2026-09-04T18:11:48.336Z" st-done
    [ "$status" -eq 0 ]
}

# ISOLATES containment. The test below it cannot: an outside worktree is also
# unbound, so reconcile refuses it either way and the status is identical with
# and without the check. This one BINDS the outside worktree first, so
# containment is the only thing left that can refuse it.
@test "a BOUND worktree outside the Slate root is still refused, by containment alone" {
    OUT="$WORK/NotSlate/wt"; mkdir -p "$OUT"
    git init -q -b main "$OUT"
    git -C "$OUT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m x

    # Bind it directly through the store: lib/binding.sh does not enforce the
    # Slate root -- containment is the caller's job, which is exactly the
    # property under test.
    n="$(herdr_linear::binding_propose "$OUT" WEB-2870)"
    herdr_linear::binding_confirm "$OUT" WEB-2870 "$n"
    [ "$(herdr_linear::binding_state "$OUT")" = "bound" ]

    printf '%s\n' "$(cd "$OUT" && pwd -P)" > "$HERDR_LINEAR_WRITE_ALLOWLIST"
    export FAKE_LINEAR_MODE=found_parent FAKE_LINEAR_ALLOW_MUTATION=1
    run herdr_linear::reconcile "$OUT"
    [ "$status" -eq 4 ]
    [ "$(mutations_sent)" = "0" ]
}

@test "a worktree outside the Slate root is never written from" {
    OUT="$WORK/NotSlate/wt"; mkdir -p "$OUT"
    git init -q -b main "$OUT"
    git -C "$OUT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m x
    export FAKE_LINEAR_MODE=found_parent FAKE_LINEAR_ALLOW_MUTATION=1
    run herdr_linear::reconcile "$OUT"
    [ "$status" -eq 4 ]
    [ "$(mutations_sent)" = "0" ]
}

# R17/KTD13. A hook has nobody to ask, so judgment is recorded and surfaced by
# the grounding hook at the next session.
@test "a judgment case records a proposal instead of writing or prompting" {
    bind_wt WEB-2870
    # Deleted upstream, commits kept -- exactly the shape a squash merge leaves.
    git -C "$WT" push -q origin --delete feature/web-2870-detach
    git -C "$WT" fetch -q --prune origin
    enable_writes
    export FAKE_LINEAR_MODE=found_parent FAKE_LINEAR_ALLOW_MUTATION=1
    run herdr_linear::reconcile "$WT"
    [ "$status" -eq 3 ]
    [ "$(mutations_sent)" = "0" ]
    run herdr_linear::binding_take_judgment "$WT" "some-session"
    [ "$status" -eq 0 ]
    [[ "$output" == *"gone from the remote"* ]]
}

# ------------------------------------------------------------------ the hook

# R19. Asserted by RUNNING it, not by reading it and concluding it cannot block.
@test "the hook exits 0 with Linear unreachable" {
    bind_wt WEB-2870
    merge_into_main
    enable_writes
    run bash -c "printf '{\"cwd\":\"$WT\",\"hook_event_name\":\"SessionEnd\"}' | HERDR_LINEAR_CURL_BIN=/bin/false bash '$ROOT/hooks/reconcile.sh'"
    [ "$status" -eq 0 ]
}

@test "the hook exits 0 on a malformed payload, an empty payload, and a missing store" {
    run bash -c "printf 'not json' | bash '$ROOT/hooks/reconcile.sh'"
    [ "$status" -eq 0 ]
    run bash -c "printf '' | bash '$ROOT/hooks/reconcile.sh'"
    [ "$status" -eq 0 ]
    run bash -c "printf '{\"cwd\":\"$WT\"}' | HERDR_LINEAR_STORE_DIR=/nonexistent/nope bash '$ROOT/hooks/reconcile.sh'"
    [ "$status" -eq 0 ]
}

@test "the hook prints nothing at all -- a closing session has no channel" {
    bind_wt WEB-2870
    merge_into_main
    export FAKE_LINEAR_MODE=found_parent
    run --separate-stderr bash -c "printf '{\"cwd\":\"$WT\",\"hook_event_name\":\"SessionEnd\"}' | bash '$ROOT/hooks/reconcile.sh'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -z "$stderr" ]
}

@test "the hook is registered on SessionEnd and not on Stop" {
    body="$(cat "$ROOT/hooks/hooks.json")"
    [[ "$body" == *"SessionEnd"* ]]
    [[ "$body" != *'"Stop"'* ]]
}
