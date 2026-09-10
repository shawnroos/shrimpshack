#!/usr/bin/env bats

load setup_common

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

# The record is the delivery channel: whatever goes in here comes back out of
# binding_identifier and becomes a path segment downstream. The store refuses an
# unsafe identifier so no later reader has to.
@test "an identifier the validator rejects never enters the record" {
    for bad in "../outside" ".." "-D" ".git" "a/b" 'a$b'; do
        run herdr_linear::binding_propose "$WT" "$bad"
        [ "$status" -ne 0 ]
        run herdr_linear::binding_state "$WT"
        [ "$output" = "unbound" ]
    done

    # The positive control -- a validator that refuses everything passes above.
    run herdr_linear::binding_propose "$WT" WEB-1234
    [ "$status" -eq 0 ]
    [ "${#output}" -eq 32 ]
}

# The guard on the way in does not cover a record already on disk -- one written
# before the guard existed, or edited by anything that can reach the store. The
# reader is what every downstream path-builder actually calls, so it validates
# too rather than trusting the file.
@test "an unsafe identifier already in the record is not handed out" {
    bind_it WEB-1234
    run herdr_linear::binding_identifier "$WT"
    [ "$output" = "WEB-1234" ]

    python3 -c 'import sys,json;f=sys.argv[1];d=json.load(open(f));d["issue_identifier"]="../outside";json.dump(d,open(f,"w"))' "$(record_file)"

    run herdr_linear::binding_identifier "$WT"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

# The proposal is on disk between propose and confirm. Confirm compares the id
# it is given against the proposal and would otherwise take a hostile pair.
@test "confirm refuses an unsafe identifier that reached the proposal on disk" {
    nonce="$(herdr_linear::binding_propose "$WT" WEB-1234)"
    python3 -c 'import sys,json;f=sys.argv[1];d=json.load(open(f));d["proposal"]["identifier"]="../outside";json.dump(d,open(f,"w"))' "$(record_file)"

    run herdr_linear::binding_confirm "$WT" "../outside" "$nonce"
    [ "$status" -ne 0 ]
    run herdr_linear::binding_state "$WT"
    [ "$output" != "bound" ]
}

# add-child is the third writer of an identifier into the record, and what it
# writes is a tracker-authored identifier from create.sh.
@test "a child identifier that is not safe never enters the record" {
    bind_it WEB-1234
    run herdr_linear::binding_add_child "$WT" "../outside"
    [ "$status" -ne 0 ]
    run grep -c "outside" "$(record_file)"
    [ "$output" = "0" ]

    run herdr_linear::binding_add_child "$WT" WEB-9999
    [ "$status" -eq 0 ]
}

# A proposed record has no identifier yet. That is ABSENT, and a caller that
# cannot tell it from REFUSED treats a hostile record as an empty one.
@test "a proposed record reports its identifier absent, not refused" {
    herdr_linear::binding_propose "$WT" WEB-1234 >/dev/null
    run herdr_linear::binding_identifier "$WT"
    [ "$status" -eq "$HERDR_LINEAR_BINDING_ABSENT" ]
}

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

# ------------------------------------------------------------------- consent
#
# U2. The write-consent record. It shares ONE mechanism with the binding -- the
# path-hash key -- and nothing else. It carries its own team, project and
# branch, because `branch_at_confirmation` is compared only when the state is
# `bound`, is rewritten by every confirm including the no-human ones, and is
# empty for the unbound checkout R9 has to cover.

grant() {  # <team> <project>
    local n
    n="$(herdr_linear::consent_propose "$WT" "$1" "${2:-}")"
    herdr_linear::consent_confirm "$WT" "$1" "${2:-}" "$n"
}

# The values are pinned, not merely non-zero: 127 is also non-zero, so a
# `-ne 0` assertion here would pass against a reader that does not exist.
@test "a directory with no recorded answer has no consent" {
    run herdr_linear::has_consent "$WT"
    [ "$status" -eq 1 ]
    run herdr_linear::consent_ok "$WT" TEAM-A PROJ-1
    [ "$status" -eq 1 ]
}

# A key that is absent and a key whose value is null both print an empty string
# through `_py field`, so presence is asked for separately from value.
@test "a proposed but unconfirmed answer is still no consent" {
    herdr_linear::consent_propose "$WT" TEAM-A PROJ-1 >/dev/null
    run herdr_linear::has_consent "$WT"
    [ "$status" -eq 1 ]
    run herdr_linear::consent_ok "$WT" TEAM-A PROJ-1
    [ "$status" -eq 1 ]
}

@test "a recorded answer covers the team and project it named" {
    grant TEAM-A PROJ-1
    run herdr_linear::has_consent "$WT"
    [ "$status" -eq 0 ]
    run herdr_linear::consent_ok "$WT" TEAM-A PROJ-1
    [ "$status" -eq 0 ]
}

@test "a write to a different team asks again" {
    grant TEAM-A PROJ-1
    run herdr_linear::consent_ok "$WT" TEAM-B PROJ-1
    [ "$status" -ne 0 ]
}

@test "a write to a different project asks again" {
    grant TEAM-A PROJ-1
    run herdr_linear::consent_ok "$WT" TEAM-A PROJ-2
    [ "$status" -ne 0 ]
}

# start_new and new_project name a team and no project, so a request carrying
# no project is covered by the answer for that team.
@test "a write naming no project is covered by the team's answer" {
    grant TEAM-A PROJ-1
    run herdr_linear::consent_ok "$WT" TEAM-A ""
    [ "$status" -eq 0 ]
}

# The other direction is NOT covered: the question named a team only.
@test "a team-only answer does not cover a write into a project" {
    grant TEAM-A ""
    run herdr_linear::consent_ok "$WT" TEAM-A PROJ-1
    [ "$status" -ne 0 ]
    run herdr_linear::consent_ok "$WT" TEAM-A ""
    [ "$status" -eq 0 ]
}

# A worktree recreated at the same path on different work is a different
# directory as far as the question goes.
@test "a recreated worktree at the same path on a different branch has no consent" {
    grant TEAM-A PROJ-1
    git -C "$WT" checkout -q -b feature/web-9999-other
    run herdr_linear::consent_ok "$WT" TEAM-A PROJ-1
    [ "$status" -ne 0 ]
    run herdr_linear::has_consent "$WT"
    [ "$status" -eq 0 ]
}

# The binding's own branch field is rewritten by every confirm, including the
# no-human pairs in start.sh and create.sh. Consent must not ride on it.
@test "re-confirming the binding on a new branch does not revive consent" {
    grant TEAM-A PROJ-1
    git -C "$WT" checkout -q -b feature/web-9999-other
    bind_it WEB-9999
    run herdr_linear::binding_state "$WT"
    [ "$output" = "bound" ]
    run herdr_linear::consent_ok "$WT" TEAM-A PROJ-1
    [ "$status" -ne 0 ]
}

# R9a and R10a. The nonce orders confirm after propose. A caller that supplies
# an answer of its own -- the headless `claude -p "/work:new ... yes"` case --
# supplies no nonce, and records nothing.
@test "consent_confirm with an answer in place of the nonce records nothing" {
    herdr_linear::consent_propose "$WT" TEAM-A PROJ-1 >/dev/null
    run herdr_linear::consent_confirm "$WT" TEAM-A PROJ-1 yes
    [ "$status" -eq 2 ]
    run herdr_linear::has_consent "$WT"
    [ "$status" -ne 0 ]
}

# R9. The checkout a session runs from before any worktree exists has no
# binding at all, so the consent reader must not require one.
@test "consent is recorded and read from an unbound checkout" {
    run herdr_linear::binding_state "$WT"
    [ "$output" = "unbound" ]
    grant TEAM-A ""
    run herdr_linear::binding_state "$WT"
    [ "$output" = "unbound" ]
    run herdr_linear::consent_ok "$WT" TEAM-A ""
    [ "$status" -eq 0 ]
}

# KTD3. "Nobody to ask" gets its own field. set-judgment replaces its single
# slot wholesale, and the squash-merge question already lost that fight once.
@test "a pending consent question does not evict a pending judgment" {
    herdr_linear::binding_set_judgment "$WT" "did this land?"
    herdr_linear::binding_set_pending_consent "$WT" "would have set WEB-1234 to Done"
    run herdr_linear::binding_take_judgment "$WT" session-two
    [ "$output" = "did this land?" ]
    run herdr_linear::binding_pending_consent "$WT"
    [ "$output" = "would have set WEB-1234 to Done" ]
}

# ---------------------------------------------------------------- the gate
#
# One gate, six verbs. What each verb prints and returns is its own; the log
# line and the deferred-write record are not.

@test "the gate proceeds when the recorded answer covers the write" {
    export HERDR_LINEAR_SHADOW_LOG="$WORK/shadow.log"
    grant TEAM-A PROJ-1
    run herdr_linear::consent_gate "$WT" TEAM-A PROJ-1 "rewrite the description of WEB-1234"
    [ "$status" -eq 0 ]
    [ ! -f "$HERDR_LINEAR_SHADOW_LOG" ]
    run herdr_linear::binding_pending_consent "$WT"
    [ "$status" -ne 0 ]
}

@test "the gate refuses, logs the skip and records it for the next session" {
    export HERDR_LINEAR_SHADOW_LOG="$WORK/shadow.log"
    run herdr_linear::consent_gate "$WT" TEAM-A PROJ-1 "rewrite the description of WEB-1234"
    [ "$status" -eq 1 ]
    run cat "$HERDR_LINEAR_SHADOW_LOG"
    [[ "$output" == *"SHADOW would rewrite the description of WEB-1234"* ]]
    run herdr_linear::binding_pending_consent "$WT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"rewrite the description of WEB-1234"* ]]
    [[ "$output" == *"did not happen"* ]]
}

# The log carries diagnostics the notice does not: a state id nobody reads out
# loud belongs in the log and not in a session's context.
@test "the gate's fifth argument reaches the log and not the record" {
    export HERDR_LINEAR_SHADOW_LOG="$WORK/shadow.log"
    run herdr_linear::consent_gate "$WT" TEAM-A "" "set WEB-1234 to type=completed" "(state st-9); signals: merged"
    [ "$status" -eq 1 ]
    run cat "$HERDR_LINEAR_SHADOW_LOG"
    [[ "$output" == *"SHADOW would set WEB-1234 to type=completed (state st-9); signals: merged"* ]]
    run herdr_linear::binding_pending_consent "$WT"
    [[ "$output" != *"st-9"* ]]
}

# ------------------------------------------------------------------ decline
#
# A refusal and an unanswered question both mean do not write. A third state in
# a two-state record is a case the reader gets wrong, so no is recorded as an
# absence.

@test "declining records no answer and leaves the writes shut" {
    local n; n="$(herdr_linear::consent_propose "$WT" TEAM-A PROJ-1)"
    run herdr_linear::consent_decline "$WT" TEAM-A PROJ-1 "$n"
    [ "$status" -eq 0 ]
    run herdr_linear::has_consent "$WT"
    [ "$status" -eq 1 ]
    run herdr_linear::consent_ok "$WT" TEAM-A PROJ-1
    [ "$status" -eq 1 ]
    # Read from the record itself: the two predicates above would also be
    # satisfied by a `consent` object this file learned to read as a refusal.
    run herdr_linear::_py field "$(herdr_linear::_record_path "$WT")" consent
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "declining clears the proposal, so a held nonce cannot be confirmed later" {
    local n; n="$(herdr_linear::consent_propose "$WT" TEAM-A PROJ-1)"
    herdr_linear::consent_decline "$WT" TEAM-A PROJ-1 "$n"
    run herdr_linear::consent_confirm "$WT" TEAM-A PROJ-1 "$n"
    [ "$status" -eq 2 ]
    run herdr_linear::has_consent "$WT"
    [ "$status" -eq 1 ]
}

# Without this a person who answers no is asked the same question at every
# session start for as long as the record lives.
@test "declining clears the deferred-write notice" {
    local n; n="$(herdr_linear::consent_propose "$WT" TEAM-A PROJ-1)"
    herdr_linear::binding_set_pending_consent "$WT" "would have set WEB-1234 to Done"
    herdr_linear::consent_decline "$WT" TEAM-A PROJ-1 "$n"
    run herdr_linear::binding_pending_consent "$WT"
    [ "$status" -ne 0 ]
}

@test "declining leaves a pending judgment alone" {
    local n; n="$(herdr_linear::consent_propose "$WT" TEAM-A PROJ-1)"
    herdr_linear::binding_set_judgment "$WT" "did this land?"
    herdr_linear::consent_decline "$WT" TEAM-A PROJ-1 "$n"
    run herdr_linear::binding_take_judgment "$WT" session-two
    [ "$output" = "did this land?" ]
}

# The notice is the only surfaced evidence that a write was skipped. Clearing it
# is a suppression, so a decline must answer a proposal that actually happened
# -- not a question nobody asked.
@test "a decline with no proposal in flight is refused, and the notice survives" {
    herdr_linear::binding_set_pending_consent "$WT" "would have set WEB-1234 to Done"
    run herdr_linear::consent_decline "$WT" TEAM-A PROJ-1 anything
    [ "$status" -eq 2 ]
    run herdr_linear::binding_pending_consent "$WT"
    [ "$status" -eq 0 ]
    [ "$output" = "would have set WEB-1234 to Done" ]
}

@test "a decline carrying the wrong nonce is refused, and the notice survives" {
    herdr_linear::consent_propose "$WT" TEAM-A PROJ-1 >/dev/null
    herdr_linear::binding_set_pending_consent "$WT" "would have set WEB-1234 to Done"
    run herdr_linear::consent_decline "$WT" TEAM-A PROJ-1 not-the-nonce
    [ "$status" -eq 2 ]
    run herdr_linear::binding_pending_consent "$WT"
    [ "$output" = "would have set WEB-1234 to Done" ]
}

# The nonce belongs to one question. A decline naming a different team is
# answering something else.
@test "a decline naming a team the proposal did not is refused" {
    local n; n="$(herdr_linear::consent_propose "$WT" TEAM-A PROJ-1)"
    herdr_linear::binding_set_pending_consent "$WT" "would have set WEB-1234 to Done"
    run herdr_linear::consent_decline "$WT" TEAM-B PROJ-1 "$n"
    [ "$status" -eq 2 ]
    run herdr_linear::binding_pending_consent "$WT"
    [ "$output" = "would have set WEB-1234 to Done" ]
}
