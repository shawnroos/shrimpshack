#!/usr/bin/env bats
# U4 — the binding store.
#
# WHAT THE NONCE TESTS DO AND DO NOT CLAIM
# There is no test here called "an unattended session cannot confirm", because
# this library cannot enforce that and a test with that name would be a check
# narrower than its invariant. U1 proved no field separates an interactive
# session from a headless one, so a headless session running the bind skill can
# call propose, take the nonce, and call confirm. What IS tested is ordering:
# confirm requires the CURRENT proposal's nonce, so no accidental, stale, or
# cross-session confirmation can happen. U7's skill owns the other half of R6.

bats_require_minimum_version 1.5.0

setup() {
    WORK="$(mktemp -d)"
    export HERDR_LINEAR_STORE_DIR="$WORK/store"
    export HERDR_LINEAR_PIN_DIR="$WORK/pin"
    export CLAUDE_SESSION_ID="session-one"
    # shellcheck source=/dev/null
    . "${BATS_TEST_DIRNAME}/../../lib/binding.sh"

    WT="$WORK/wt"
    mkdir -p "$WT"
    git -C "$WT" init -q -b feature/web-1234-thing
    git -C "$WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
}

teardown() { [ -n "${WORK:-}" ] && rm -rf "$WORK"; }

record_file() { printf '%s/bindings/%s.json' "$HERDR_LINEAR_STORE_DIR" "$(herdr_linear::binding_key "$WT")"; }

bind_it() {   # propose + confirm, the happy path, used as a fixture
    local nonce
    nonce="$(herdr_linear::binding_propose "$WT" "${1:-WEB-1234}")"
    herdr_linear::binding_confirm "$WT" "${1:-WEB-1234}" "$nonce"
}

# ------------------------------------------------------------------- lifecycle

@test "a worktree with no record is unbound" {
    run herdr_linear::binding_state "$WT"
    [ "$output" = "unbound" ]
}

@test "propose moves to proposed and returns a nonce" {
    run herdr_linear::binding_propose "$WT" WEB-1234
    [ "$status" -eq 0 ]
    [ "${#output}" -eq 32 ]
    run herdr_linear::binding_state "$WT"
    [ "$output" = "proposed" ]
}

@test "confirm without the current proposal's nonce leaves the record proposed" {
    herdr_linear::binding_propose "$WT" WEB-1234 >/dev/null
    run herdr_linear::binding_confirm "$WT" WEB-1234 ""
    [ "$status" -eq 2 ]
    run herdr_linear::binding_state "$WT"
    [ "$output" = "proposed" ]
}

@test "confirm with a wrong nonce leaves the record proposed" {
    herdr_linear::binding_propose "$WT" WEB-1234 >/dev/null
    run herdr_linear::binding_confirm "$WT" WEB-1234 "0000000000000000"
    [ "$status" -eq 2 ]
    run herdr_linear::binding_state "$WT"
    [ "$output" = "proposed" ]
}

# The two-sessions-one-worktree case the nonce genuinely closes: a second
# proposal supersedes the first, and the first session's stale nonce is dead.
@test "a nonce from a superseded proposal no longer confirms" {
    stale="$(herdr_linear::binding_propose "$WT" WEB-1234)"
    herdr_linear::binding_propose "$WT" WEB-5678 >/dev/null
    run herdr_linear::binding_confirm "$WT" WEB-1234 "$stale"
    [ "$status" -eq 2 ]
    run herdr_linear::binding_state "$WT"
    [ "$output" = "proposed" ]
}

@test "confirm with the current nonce binds, and records the identifier" {
    bind_it WEB-1234
    run herdr_linear::binding_state "$WT"
    [ "$output" = "bound" ]
    run herdr_linear::binding_identifier "$WT"
    [ "$output" = "WEB-1234" ]
}

# ------------------------------------------------------------- R8, R4, R7

# R8. The record is keyed on the worktree path and the branch, and holds nothing
# from herdr at all -- so a pane moving workspace, a tab being renamed and the
# server restarting cannot reach it. Changing every herdr variable proves the
# binding does not consult them.
@test "a confirmed binding survives a pane move, a tab rename and a herdr restart" {
    bind_it WEB-1234
    HERDR_PANE_ID="wJ:p99" HERDR_TAB_ID="wJ:t99" HERDR_WORKSPACE_ID="wJ" \
        run herdr_linear::binding_state "$WT"
    [ "$output" = "bound" ]
    unset HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID
    run herdr_linear::binding_state "$WT"
    [ "$output" = "bound" ]
}

# KTD4. Worktree names recur here by convention, so a recreated worktree at the
# same path must not inherit a record still reading bound.
@test "a record confirmed on one branch is not bound after the path is recreated on another" {
    bind_it WEB-1234
    rm -rf "$WT"
    mkdir -p "$WT"
    git -C "$WT" init -q -b feature/something-else
    git -C "$WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    run herdr_linear::binding_state "$WT"
    [ "$output" = "proposed" ]
}

@test "the downgrade is reported, not written -- the record on disk still says bound" {
    bind_it WEB-1234
    git -C "$WT" checkout -q -b other
    run herdr_linear::binding_state "$WT"
    [ "$output" = "proposed" ]
    run grep -c '"state": "bound"' "$(record_file)"
    [ "$output" = "1" ]
}

# R7. The store is outside every repository, so a binding committed into a
# worktree is not on a read path at all.
@test "a binding file committed inside the worktree is ignored and the worktree stays unbound" {
    printf '{"version":1,"worktree_path":"%s","state":"bound","issue_identifier":"WEB-9999"}\n' "$WT" \
        > "$WT/.work-binding.json"
    git -C "$WT" add .work-binding.json
    git -C "$WT" -c user.email=t@t -c user.name=t commit -q -m "plant a binding"
    run herdr_linear::binding_state "$WT"
    [ "$output" = "unbound" ]
    run herdr_linear::binding_identifier "$WT"
    [ "$status" -ne 0 ]
}

@test "a declined candidate is never proposed again for that worktree" {
    herdr_linear::binding_propose "$WT" WEB-1234 >/dev/null
    herdr_linear::binding_decline "$WT" WEB-1234
    run herdr_linear::binding_state "$WT"
    [ "$output" = "unbound" ]
    run herdr_linear::binding_propose "$WT" WEB-1234
    [ "$status" -eq 2 ]
    run herdr_linear::binding_state "$WT"
    [ "$output" = "unbound" ]
}

# ------------------------------------------------- a record is valid or absent

# The class, not the one case. A file that PARSES is not a valid record: a state
# outside the enum would fall through every state check silently, which is worse
# than a truncated file that fails loudly at the parse.
@test "a truncated record reads as absent" {
    bind_it WEB-1234
    printf '{"version":1,"worktree' > "$(record_file)"
    run herdr_linear::binding_state "$WT"
    [ "$output" = "unbound" ]
}

@test "a record that parses but carries a state outside the enum reads as absent" {
    bind_it WEB-1234
    printf '{"version":1,"worktree_path":"%s","state":"confirmed"}' "$WT" > "$(record_file)"
    run herdr_linear::binding_state "$WT"
    [ "$output" = "unbound" ]
}

@test "a record missing a required field reads as absent" {
    bind_it WEB-1234
    printf '{"version":1,"state":"bound"}' > "$(record_file)"
    run herdr_linear::binding_state "$WT"
    [ "$output" = "unbound" ]
}

@test "a record from a future version reads as absent rather than being guessed at" {
    bind_it WEB-1234
    printf '{"version":99,"worktree_path":"%s","state":"bound"}' "$WT" > "$(record_file)"
    run herdr_linear::binding_state "$WT"
    [ "$output" = "unbound" ]
}

@test "a group- or world-writable record reads as absent" {
    bind_it WEB-1234
    chmod 660 "$(record_file)"
    run herdr_linear::binding_state "$WT"
    [ "$output" = "unbound" ]
    chmod 606 "$(record_file)"
    run herdr_linear::binding_state "$WT"
    [ "$output" = "unbound" ]
}

# KNOWINGLY UNTESTED: the owner check in _mode_ok. Creating a file owned by
# another user needs root, which no test on this machine may take. The mode half
# of the same function is covered above; the owner half is asserted by reading.
@test "the store directory is 0700 and records are 0600" {
    bind_it WEB-1234
    [ "$(stat -f %Lp "$HERDR_LINEAR_STORE_DIR")" = "700" ]
    [ "$(stat -f %Lp "$(record_file)")" = "600" ]
}

# --------------------------------------------------------------- concurrency

# A REAL race. Two sequential declines would both land with the lock removed, so
# this stages an actual overlap: the hold seam keeps the first mutation inside
# its critical section while the second starts. Without the lock the second
# read-modify-write reads the pre-first record and its rename drops the first
# entry. Mutation-tested by deleting the lock acquire.
@test "two concurrent declines both land, and neither loses the other" {
    herdr_linear::binding_propose "$WT" WEB-1111 >/dev/null
    HERDR_LINEAR_LOCK_HOLD_MS=250 herdr_linear::binding_decline "$WT" WEB-1111 &
    p1=$!
    sleep 0.05
    HERDR_LINEAR_LOCK_HOLD_MS=250 herdr_linear::binding_decline "$WT" WEB-2222 &
    p2=$!
    wait $p1; wait $p2
    run herdr_linear::binding_read "$WT"
    [ "$status" -eq 0 ]
    declined="$(printf '%s' "$output" | python3 -c 'import sys,json;print(",".join(sorted(json.load(sys.stdin)["declined"])))')"
    [ "$declined" = "WEB-1111,WEB-2222" ]
}

# --------------------------------------------------------- judgment and children

# R18: retained, and re-presented once at the start of the NEXT session. "Once"
# is per session, not once ever -- a judgment answered by nobody must keep
# surfacing until it is answered or dismissed.
@test "an unanswered judgment is returned once per session and retained across sessions" {
    bind_it WEB-1234
    herdr_linear::binding_set_judgment "$WT" "move WEB-1234 to In Review?"

    run herdr_linear::binding_take_judgment "$WT" "session-one"
    [ "$status" -eq 0 ]
    [ "$output" = "move WEB-1234 to In Review?" ]

    run herdr_linear::binding_take_judgment "$WT" "session-one"
    [ "$status" -ne 0 ]

    run herdr_linear::binding_take_judgment "$WT" "session-two"
    [ "$status" -eq 0 ]
    [ "$output" = "move WEB-1234 to In Review?" ]
}

@test "a dismissed judgment is not returned again to any session" {
    bind_it WEB-1234
    herdr_linear::binding_set_judgment "$WT" "a question"
    herdr_linear::binding_clear_judgment "$WT"
    run herdr_linear::binding_take_judgment "$WT" "session-three"
    [ "$status" -ne 0 ]
}

# R30 bounds writes to the bound issue and issues created beneath it, so the
# record of what was created is part of the authorization boundary.
@test "a created child issue is recorded against the binding" {
    bind_it WEB-1234
    herdr_linear::binding_add_child "$WT" WEB-5001
    herdr_linear::binding_add_child "$WT" WEB-5002
    herdr_linear::binding_add_child "$WT" WEB-5001
    run herdr_linear::binding_read "$WT"
    kids="$(printf '%s' "$output" | python3 -c 'import sys,json;print(",".join(json.load(sys.stdin)["created_children"]))')"
    [ "$kids" = "WEB-5001,WEB-5002" ]
}

# ------------------------------------------------------------------- the seed

# The pin key is copied verbatim from linear-pin.sh, so the fixture is planted
# through the SAME derivation the real hook uses. Deriving it independently here
# would make "no seed found" indistinguishable from a byte-off key.
@test "the pin store seeds a candidate and is never written to" {
    key="$(herdr_linear::_pin_branch_key "$WT")"
    [ -n "$key" ]
    mkdir -p "$HERDR_LINEAR_PIN_DIR/branch"
    printf 'WEB-4321' > "$HERDR_LINEAR_PIN_DIR/branch/$key"
    before="$(find "$HERDR_LINEAR_PIN_DIR" -type f -exec shasum {} \; | shasum)"

    run herdr_linear::binding_seed_candidate "$WT"
    [ "$status" -eq 0 ]
    [ "$output" = "WEB-4321" ]

    # A seed yields a candidate, never a binding.
    run herdr_linear::binding_state "$WT"
    [ "$output" = "unbound" ]

    after="$(find "$HERDR_LINEAR_PIN_DIR" -type f -exec shasum {} \; | shasum)"
    [ "$before" = "$after" ]
}

@test "a pin holding something that is not an issue identifier is not used as a seed" {
    key="$(herdr_linear::_pin_branch_key "$WT")"
    mkdir -p "$HERDR_LINEAR_PIN_DIR/branch"
    printf 'not-an-id' > "$HERDR_LINEAR_PIN_DIR/branch/$key"
    run herdr_linear::binding_seed_candidate "$WT"
    [ "$status" -ne 0 ]
}

@test "a detached worktree has no pin key and therefore no seed" {
    git -C "$WT" checkout -q --detach
    run herdr_linear::binding_seed_candidate "$WT"
    [ "$status" -ne 0 ]
}

# ------------------------------------------------- workspace to project (R9,R10)

@test "a workspace binding takes the same propose-and-confirm path" {
    run herdr_linear::workspace_state "w1"
    [ "$output" = "unbound" ]
    nonce="$(herdr_linear::workspace_propose "w1" "proj-ai-canvas")"
    run herdr_linear::workspace_state "w1"
    [ "$output" = "proposed" ]
    run herdr_linear::workspace_confirm "w1" "proj-ai-canvas" "wrong"
    [ "$status" -eq 2 ]
    herdr_linear::workspace_confirm "w1" "proj-ai-canvas" "$nonce"
    run herdr_linear::workspace_state "w1"
    [ "$output" = "bound" ]
    run herdr_linear::workspace_project "w1"
    [ "$output" = "proj-ai-canvas" ]
}

# R10. The record is keyed on the workspace ID, which a rename does not change,
# and it holds no label at all -- so there is nothing for a rename to invalidate.
@test "a workspace binding survives a rename and a herdr restart" {
    nonce="$(herdr_linear::workspace_propose "w1" "proj-ai-canvas")"
    herdr_linear::workspace_confirm "w1" "proj-ai-canvas" "$nonce"
    HERDR_WORKSPACE_LABEL="Renamed Entirely" run herdr_linear::workspace_state "w1"
    [ "$output" = "bound" ]
    run herdr_linear::workspace_project "w1"
    [ "$output" = "proj-ai-canvas" ]
}

@test "a workspace id that is not a safe identifier is refused" {
    run herdr_linear::workspace_propose "../../etc/passwd" "proj"
    [ "$status" -ne 0 ]
    [ ! -e "$HERDR_LINEAR_STORE_DIR/workspaces/../../etc/passwd.json" ]
}
