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

@test "rebinding a worktree to another issue takes the old children out of created_children" {
    bind_it WEB-1234
    herdr_linear::binding_add_child "$WT" WEB-5001
    herdr_linear::binding_set_desc_head "$WT" "old head"
    [ "$(herdr_linear::binding_read "$WT" | python3 -c 'import sys,json;print(json.load(sys.stdin)["description_head"])')" = "old head" ]
    bind_it WEB-7777
    run herdr_linear::binding_read "$WT"
    result="$(printf '%s' "$output" | python3 -c '
import sys,json;d=json.load(sys.stdin);p=d["prior_bindings"]
print(d["issue_identifier"], d["created_children"], d["description_head"], p[0]["issue_identifier"], p[0]["created_children"])')"
    [ "$result" = "WEB-7777 []  WEB-1234 ['WEB-5001']" ]
}

@test "bindings_effective reports, for every record, the state binding_read reports" {
    local mk n row
    mk() {   # mk <name> <identifier>
        local d="$WORK/$1"; mkdir -p "$d"
        git -C "$d" init -q -b "feature/$(printf '%s' "$2" | tr 'A-Z' 'a-z')-x"
        git -C "$d" -c user.email=t@t -c user.name=t commit -q --allow-empty -m i
        n="$(herdr_linear::binding_propose "$d" "$2")"
        herdr_linear::binding_confirm "$d" "$2" "$n"
    }
    mk bound WEB-2001
    mk moved WEB-2002
    git -C "$WORK/moved" checkout -q -b elsewhere
    mk proposed WEB-2003
    herdr_linear::binding_propose "$WORK/proposed" WEB-2004 >/dev/null
    mk gone WEB-2005
    local gone_key; gone_key="$(herdr_linear::binding_key "$WORK/gone")"
    rm -rf "$WORK/gone"
    mk refused WEB-2006
    chmod 664 "$HERDR_LINEAR_STORE_DIR/bindings/$(herdr_linear::binding_key "$WORK/refused").json"

    run herdr_linear::bindings_effective
    [ "$status" -eq 0 ]
    eff_of() {
        printf '%s\n' "$output" | python3 -c '
import sys
for line in sys.stdin.read().split("\n"):
    f = line.split("\x1f")
    if len(f) == 5 and f[2] == sys.argv[1]:
        print(f[4])' "$1"
    }
    for row in bound moved proposed; do
        want="$(herdr_linear::binding_read "$WORK/$row" | python3 -c 'import sys,json;print(json.load(sys.stdin)["state"])')"
        got="$(eff_of "$(cd "$WORK/$row" && pwd -P)")"
        [ -n "$want" ]
        [ "$got" = "$want" ]
    done
    [ "$(eff_of "$(cd "$WORK/moved" && pwd -P)")" = "proposed" ]
    [ "$(printf '%s\n' "$output" | grep -c "$gone_key.json.*worktree_missing")" -eq 1 ]
    [ "$(printf '%s\n' "$output" | grep -c 'WEB-2006')" -eq 0 ]
}

@test "bindings_effective leaves out a record whose fields carry the row separator or a newline" {
    bind_it WEB-1234
    local f; f="$(record_file)"
    python3 -c '
import json, sys
d = json.load(open(sys.argv[1])); d["tab"] = "wA:t1\nwA:t2"
json.dump(d, open(sys.argv[1], "w"))' "$f"
    run herdr_linear::bindings_effective
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    python3 -c '
import json, sys
d = json.load(open(sys.argv[1])); d["tab"] = "wA:t1\x1fbound"
json.dump(d, open(sys.argv[1], "w"))' "$f"
    run herdr_linear::bindings_effective
    [ -z "$output" ]
    python3 -c '
import json, sys
d = json.load(open(sys.argv[1])); d["tab"] = "wA:t1"
json.dump(d, open(sys.argv[1], "w"))' "$f"
    run herdr_linear::bindings_effective
    [ "$(printf '%s' "$output" | grep -c 'WEB-1234')" -eq 1 ]
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

# ------------------------------------------------------ the workspace's view (U4)

ws_file() { printf '%s/workspaces/%s.json' "$HERDR_LINEAR_STORE_DIR" "$1"; }

bind_ws() {   # bind_ws <ws> <project>
    local n
    n="$(herdr_linear::workspace_propose "$1" "$2")"
    herdr_linear::workspace_confirm "$1" "$2" "$n"
}

LAYOUT='{"grouping":"workflowState","column_order":["st-backlog","st-todo"],"hidden":["st-cancel"]}'

@test "set-view on a bound record writes id, name, layout and fetched_at, at version 1 and mode 600" {
    bind_ws w1 proj-ai-canvas
    run herdr_linear::workspace_set_view w1 cccc-1 "Canvas board" "$LAYOUT"
    [ "$status" -eq 0 ]
    result="$(python3 -c '
import sys,json;d=json.load(open(sys.argv[1]));v=d["view"]
print(d["version"], d["state"], v["id"], v["name"], v["layout"]["grouping"], ",".join(v["layout"]["column_order"]), v["layout"]["hidden"][0], len(v["fetched_at"]))' "$(ws_file w1)")"
    [ "$result" = "1 bound cccc-1 Canvas board workflowState st-backlog,st-todo st-cancel 20" ]
    [ "$(stat -f %Lp "$(ws_file w1)" 2>/dev/null || stat -c %a "$(ws_file w1)")" = "600" ]
    run herdr_linear::workspace_view w1
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')" = "cccc-1" ]
}

@test "rebinding a space to another project drops the old view and moves what was created to prior_bindings" {
    bind_ws w1 proj-ai-canvas
    herdr_linear::workspace_add_view w1 cccc-1
    herdr_linear::workspace_set_view w1 cccc-1 "Canvas board" "$LAYOUT"
    bind_ws w1 proj-other
    result="$(python3 -c '
import sys,json;d=json.load(open(sys.argv[1]));p=d["prior_bindings"]
print(d["state"], d["issue_identifier"], d["view"], d["created_views"], len(p), p[0]["issue_identifier"], p[0]["view"]["id"], p[0]["created_views"])' "$(ws_file w1)")"
    [ "$result" = "bound proj-other None [] 1 proj-ai-canvas cccc-1 ['cccc-1']" ]
    run herdr_linear::workspace_owns_view w1 cccc-1
    [ "$status" -ne 0 ]
}

@test "confirming the same project again keeps the view and created_views" {
    bind_ws w1 proj-ai-canvas
    herdr_linear::workspace_add_view w1 cccc-1
    herdr_linear::workspace_set_view w1 cccc-1 "Canvas board" "$LAYOUT"
    bind_ws w1 proj-ai-canvas
    result="$(python3 -c '
import sys,json;d=json.load(open(sys.argv[1]))
print(d["view"]["id"], d["created_views"], d["prior_bindings"])' "$(ws_file w1)")"
    [ "$result" = "cccc-1 ['cccc-1'] []" ]
}

@test "set-view with no layout records a null layout, and clear-view removes the view" {
    bind_ws w1 proj-ai-canvas
    herdr_linear::workspace_set_view w1 cccc-1 "Canvas board"
    [ "$(python3 -c 'import sys,json;print(json.load(open(sys.argv[1]))["view"]["layout"])' "$(ws_file w1)")" = "None" ]
    run herdr_linear::workspace_clear_view w1
    [ "$status" -eq 0 ]
    [ "$(python3 -c 'import sys,json;d=json.load(open(sys.argv[1]));print("view" in d, d["view"])' "$(ws_file w1)")" = "True None" ]
    run herdr_linear::workspace_view w1
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "set-view refuses a layout that is not a JSON object" {
    bind_ws w1 proj-ai-canvas
    run herdr_linear::workspace_set_view w1 cccc-1 "Canvas board" '["not","an","object"]'
    [ "$status" -eq 2 ]
    [ "$(python3 -c 'import sys,json;print(json.load(open(sys.argv[1]))["view"])' "$(ws_file w1)")" = "None" ]
}

# Records written before the view existed carry neither key. The loader adds
# both, so a reader can index them without a presence check of its own --
# and the KEYS are asserted, not only the values, because a reader that gets
# a KeyError and one that gets None are different failures.
@test "a record written before this change reads with view null and created_views empty, keys present" {
    bind_ws w1 proj-ai-canvas
    python3 - "$(ws_file w1)" <<'PY'
import sys, json
p = sys.argv[1]
d = json.load(open(p))
d.pop("view", None); d.pop("created_views", None)
json.dump(d, open(p, "w"))
PY
    run herdr_linear::workspace_read w1
    [ "$status" -eq 0 ]
    result="$(printf '%s' "$output" | python3 -c 'import sys,json;d=json.load(sys.stdin);print("view" in d, d["view"], "created_views" in d, d["created_views"])')"
    [ "$result" = "True None True []" ]
    run herdr_linear::workspace_owns_view w1 anything
    [ "$status" -eq 1 ]
}

@test "owns-view is true only for an id in created_views" {
    bind_ws w1 proj-ai-canvas
    herdr_linear::workspace_set_view w1 cccc-2 "Someone else's board"
    run herdr_linear::workspace_owns_view w1 cccc-2
    [ "$status" -eq 1 ]
    herdr_linear::workspace_add_view w1 cccc-1
    herdr_linear::workspace_add_view w1 cccc-1
    run herdr_linear::workspace_owns_view w1 cccc-1
    [ "$status" -eq 0 ]
    run herdr_linear::workspace_owns_view w1 cccc-2
    [ "$status" -eq 1 ]
    [ "$(python3 -c 'import sys,json;print(",".join(json.load(open(sys.argv[1]))["created_views"]))' "$(ws_file w1)")" = "cccc-1" ]
}

@test "a created_views that is not a list makes the record absent" {
    bind_ws w1 proj-ai-canvas
    python3 -c 'import sys,json;p=sys.argv[1];d=json.load(open(p));d["created_views"]="cccc-1";json.dump(d,open(p,"w"))' "$(ws_file w1)"
    run herdr_linear::workspace_read w1
    [ "$status" -eq 1 ]
}

# The loader returns nothing for a future version, and the view ops stop
# there. They do NOT fall through to a blank record the way older mutations
# do: a view on a fabricated unbound record would be a board for a space
# nobody bound.
@test "set-view on a record from a future version is refused and the record is untouched" {
    bind_ws w1 proj-ai-canvas
    python3 -c 'import sys,json;p=sys.argv[1];d=json.load(open(p));d["version"]=2;json.dump(d,open(p,"w"),sort_keys=True)' "$(ws_file w1)"
    before="$(cat "$(ws_file w1)")"
    run herdr_linear::workspace_set_view w1 cccc-1 "Canvas board" "$LAYOUT"
    [ "$status" -eq 1 ]
    run herdr_linear::workspace_add_view w1 cccc-1
    [ "$status" -eq 1 ]
    [ "$(cat "$(ws_file w1)")" = "$before" ]
}

@test "set-view on a workspace with no record does not create one" {
    run herdr_linear::workspace_set_view w9 cccc-1 "Canvas board"
    [ "$status" -eq 1 ]
    [ ! -e "$(ws_file w9)" ]
}

@test "a view id that is not a safe identifier never enters the record" {
    bind_ws w1 proj-ai-canvas
    for bad in "../outside" ".." "-D" 'a$b' "a/b"; do
        run herdr_linear::workspace_set_view w1 "$bad" "n"
        [ "$status" -eq 2 ]
        run herdr_linear::workspace_add_view w1 "$bad"
        [ "$status" -eq 2 ]
    done
    [ "$(python3 -c 'import sys,json;d=json.load(open(sys.argv[1]));print(d["view"], d["created_views"])' "$(ws_file w1)")" = "None []" ]
}

@test "two concurrent set-view calls serialise through the lock, and the last one wins intact" {
    bind_ws w1 proj-ai-canvas
    HERDR_LINEAR_LOCK_HOLD_MS=250 herdr_linear::workspace_set_view w1 cccc-1 "First" "$LAYOUT" &
    p1=$!
    sleep 0.05
    HERDR_LINEAR_LOCK_HOLD_MS=250 herdr_linear::workspace_set_view w1 cccc-2 "Second" "$LAYOUT" &
    p2=$!
    wait $p1; wait $p2
    run herdr_linear::workspace_read w1
    [ "$status" -eq 0 ]
    result="$(printf '%s' "$output" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["view"]["id"], d["view"]["name"], d["state"])')"
    [ "$result" = "cccc-2 Second bound" ]
}

# ------------------------------------------------ bind arguments (KTD4, R16)

LONG64="a123456789b123456789c123456789d123456789e123456789f123456789g123"
LONG65="${LONG64}h"
PROJ_ID=44444444-4444-4444-8444-444444444444
VIEW_ID=cccccccc-cccc-4ccc-8ccc-cccccccccccc

hostile_ids() {
    printf '%s\0' "-rf" "--exec" ".hidden" ".." $'a\nb' "a b" "" "$LONG65" "a.b" "a/b" $'caf\xc3\xa9'
}

# linear.sh and views.sh are sourced only here: binding.sh must not reach them,
# and view_read is replaced so a test can see whether a read was attempted.
load_view_libs() {
    local f
    for f in secrets.sh linear.sh views.sh; do . "${BATS_TEST_DIRNAME}/../../lib/$f"; done
    READS="$WORK/reads"
    herdr_linear::view_read() {
        printf '%s\n' "$1" >> "$READS"
        [ -z "${CANNED_VIEW_FAIL:-}" ] || return 3
        printf '{"id":"%s","name":"Board","archived":false,"filter":{"project":{"id":{"eq":"%s"}}},"layout":{}}' \
            "$1" "${CANNED_VIEW_PROJECT:-$PROJ_ID}"
    }
}

@test "the bind identifier rule accepts the valid set, up to 64 characters" {
    for good in wA "$PROJ_ID" WEB-1234 a_b 9 "$LONG64"; do
        run herdr_linear::is_bind_identifier "$good"
        [ "$status" -eq 0 ]
    done
}

# Mutation note: this is the test that goes red when the first-character rule is
# removed from is_bind_identifier. Only that rule refuses `-rf` and `--exec`;
# the charset admits both.
@test "the bind identifier rule refuses an option-shaped id" {
    for bad in "-rf" "--exec" "-" "_x"; do
        run herdr_linear::is_bind_identifier "$bad"
        [ "$status" -eq 1 ]
    done
}

@test "the bind identifier rule refuses every hostile shape" {
    local bad
    while IFS= read -r -d '' bad; do
        run herdr_linear::is_bind_identifier "$bad"
        [ "$status" -eq 1 ]
    done < <(hostile_ids)
    # The library rule stays as it was: it still admits a dot the bind rule refuses.
    run herdr_linear::is_safe_identifier "a.b"
    [ "$status" -eq 0 ]
}

@test "a valid space, project and view parse into four fixed lines" {
    run --separate-stderr herdr_linear::bind_args_parse --space wA --project "$PROJ_ID" --view "$VIEW_ID"
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'space\twA\nproject\t%s\nview\t%s\nissue\t' "$PROJ_ID" "$VIEW_ID")" ]
}

@test "a valid space, project and issue parse, in any flag order" {
    run --separate-stderr herdr_linear::bind_args_parse --issue WEB-1234 --project "$PROJ_ID" --space wA
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'space\twA\nproject\t%s\nview\t\nissue\tWEB-1234' "$PROJ_ID")" ]
}

@test "no arguments is the interactive form, not a refusal" {
    run --separate-stderr herdr_linear::bind_args_parse
    [ "$status" -eq "$HERDR_LINEAR_BINDING_ABSENT" ]
    [ -z "$output" ]
}

@test "a hostile id in any slot is refused, prints nothing, and is not echoed" {
    local bad slot
    while IFS= read -r -d '' bad; do
        for slot in space project view issue; do
            set -- --space wA --project "$PROJ_ID"
            case "$slot" in
                space)   set -- --space "$bad" --project "$PROJ_ID" ;;
                project) set -- --space wA --project "$bad" ;;
                view)    set -- "$@" --view "$bad" ;;
                issue)   set -- "$@" --issue "$bad" ;;
            esac
            run --separate-stderr herdr_linear::bind_args_parse "$@"
            [ "$status" -eq "$HERDR_LINEAR_BINDING_REFUSED" ]
            [ -z "$output" ]
            [[ "$stderr" == *"--$slot"* ]]
            if [ -n "$bad" ]; then [[ "$stderr" != *"$bad"* ]]; fi
        done
    done < <(hostile_ids)
}

@test "a malformed argument form is refused" {
    local form
    for form in \
        "--space wA" \
        "--project $PROJ_ID" \
        "--space wA --project $PROJ_ID --space wB" \
        "--space wA --project $PROJ_ID --view $VIEW_ID --issue WEB-1234" \
        "--space wA --project $PROJ_ID --team T1" \
        "--space wA --project $PROJ_ID stray" \
        "--space=wA --project $PROJ_ID" \
        "--space wA --project"; do
        # shellcheck disable=SC2086
        run --separate-stderr herdr_linear::bind_args_parse $form
        [ "$status" -eq "$HERDR_LINEAR_BINDING_REFUSED" ]
        [ -z "$output" ]
    done
}

@test "a space that is not the pane's own space is refused" {
    run --separate-stderr herdr_linear::bind_space_is_own wB wA
    [ "$status" -eq "$HERDR_LINEAR_BINDING_REFUSED" ]
    run --separate-stderr herdr_linear::bind_space_is_own wA ""
    [ "$status" -eq "$HERDR_LINEAR_BINDING_REFUSED" ]
    run --separate-stderr herdr_linear::bind_space_is_own "" ""
    [ "$status" -eq "$HERDR_LINEAR_BINDING_REFUSED" ]
    run --separate-stderr herdr_linear::bind_space_is_own wA wA
    [ "$status" -eq 0 ]
}

@test "a view whose filter does not name the project is refused" {
    load_view_libs
    CANNED_VIEW_PROJECT=99999999-9999-4999-8999-999999999999 \
        run --separate-stderr herdr_linear::view_names_project "$VIEW_ID" "$PROJ_ID"
    [ "$status" -eq "$HERDR_LINEAR_VIEW_REFUSED" ]
    run --separate-stderr herdr_linear::view_names_project "$VIEW_ID" "$PROJ_ID"
    [ "$status" -eq 0 ]
    CANNED_VIEW_FAIL=1 run --separate-stderr herdr_linear::view_names_project "$VIEW_ID" "$PROJ_ID"
    [ "$status" -eq "$HERDR_LINEAR_VIEW_FAILED" ]
}

@test "a hostile view or project id is refused before the view is read" {
    load_view_libs
    local bad
    while IFS= read -r -d '' bad; do
        run --separate-stderr herdr_linear::view_names_project "$bad" "$PROJ_ID"
        [ "$status" -eq "$HERDR_LINEAR_VIEW_REFUSED" ]
        run --separate-stderr herdr_linear::view_names_project "$VIEW_ID" "$bad"
        [ "$status" -eq "$HERDR_LINEAR_VIEW_REFUSED" ]
    done < <(hostile_ids)
    [ ! -e "$READS" ]
}

@test "an issue the worktree's branch contradicts is refused" {
    load_view_libs
    run --separate-stderr herdr_linear::bind_issue_fits_branch "$WT" WEB-9999
    [ "$status" -eq "$HERDR_LINEAR_VIEW_REFUSED" ]
    run --separate-stderr herdr_linear::bind_issue_fits_branch "$WT" WEB-1234
    [ "$status" -eq 0 ]
    git -C "$WT" checkout -q -b feature/no-ticket-here
    run --separate-stderr herdr_linear::bind_issue_fits_branch "$WT" WEB-9999
    [ "$status" -eq 0 ]
    run --separate-stderr herdr_linear::bind_issue_fits_branch "$WT" "-rf"
    [ "$status" -eq "$HERDR_LINEAR_VIEW_REFUSED" ]
    run --separate-stderr herdr_linear::bind_issue_fits_branch "$WORK/absent" WEB-1234
    [ "$status" -eq "$HERDR_LINEAR_VIEW_REFUSED" ]
}

@test "a valid space, project and view parse and validate end to end" {
    load_view_libs
    local space="" project="" view=""
    run --separate-stderr herdr_linear::bind_args_parse --space wA --project "$PROJ_ID" --view "$VIEW_ID"
    [ "$status" -eq 0 ]
    while IFS=$'\t' read -r k v; do
        case "$k" in space) space="$v" ;; project) project="$v" ;; view) view="$v" ;; esac
    done <<< "$output"
    run herdr_linear::bind_space_is_own "$space" wA
    [ "$status" -eq 0 ]
    run herdr_linear::view_names_project "$view" "$project"
    [ "$status" -eq 0 ]
}
