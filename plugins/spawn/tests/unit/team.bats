#!/usr/bin/env bats
# U3 — the roster: one worktree per member, one provisional row per member, and
# a teardown that removes exactly what the record names (R2, R3, R25).
#
# EVERYTHING HAPPENS IN A TEMP REPOSITORY. Every worktree these tests create,
# and every worktree they remove, lives under a per-test mktemp directory with
# its own `git init`. SPAWN_TEAM_WORKTREE_ROOT is exported for the same reason:
# the derived default points at the real `worktrees/` of whatever checkout the
# suite is run from, where other people's live work is.
#
# TWO FALSE-GREEN TRAPS THIS FILE IS WRITTEN AGAINST
#   1. `! grep …` does NOT fail a bats test — POSIX exempts a pipeline
#      beginning with `!`. Negatives go through helpers that fail as PLAIN
#      commands, and every absence assertion has a control arm proving it can
#      fail on the present case.
#   2. An assertion that would have been TRUE on day zero is not an assertion.
#      `jq '.handle == null'` passes on a record with no `handle` key at all, so
#      the provisional-row test pins key PRESENCE and type, not just the value.

setup() {
    LIB="$(cd "$BATS_TEST_DIRNAME/../../lib" && pwd)"
    TEAM="$LIB/team.sh"
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/gw-team.XXXXXX")"; WORK="$(cd "$WORK" && pwd -P)"

    PRIMARY="$WORK/proj"
    mkdir -p "$PRIMARY"
    git -C "$PRIMARY" init -q
    git -C "$PRIMARY" config user.email t@example.com
    git -C "$PRIMARY" config user.name tester
    printf 'seed\n' > "$PRIMARY/README.md"
    git -C "$PRIMARY" add README.md
    git -C "$PRIMARY" commit -qm seed

    ROOT="$PRIMARY/worktrees"
    export SPAWN_TEAM_WORKTREE_ROOT="$ROOT"
    RUN="$WORK/run"
}

teardown() {
    rm -rf "$WORK"
}

# roster <args...> — always run from inside the temp checkout, never the real one.
roster() {
    run bash -c "cd '$PRIMARY' && bash '$TEAM' roster $* 2>/dev/null"
}

three_members() {
    roster --run-id r1 --run-dir "$RUN" \
        --member lead --alias sonnet --contract "$WORK/c1.md" --skill ce-code-review \
        --member scout --alias haiku --contract "$WORK/c2.md" \
        --member mason --alias opus --contract "$WORK/c3.md"
}

# --- negatives that fail as plain commands ---------------------------------

refute_exists() {
    if [ -e "$1" ]; then
        printf 'refute_exists: %s exists and must not\n' "$1" >&2
        return 1
    fi
    return 0
}

assert_exists() {
    if [ ! -e "$1" ]; then
        printf 'assert_exists: %s is missing\n' "$1" >&2
        return 1
    fi
    return 0
}

# Registration, not just presence on disk: a worktree git still lists is one a
# session can still be using, whatever is in the directory.
assert_registered() {
    if ! git -C "$PRIMARY" worktree list --porcelain | grep -qxF "worktree $1"; then
        printf 'assert_registered: git no longer lists %s\n' "$1" >&2
        return 1
    fi
    return 0
}

refute_registered() {
    if git -C "$PRIMARY" worktree list --porcelain | grep -qxF "worktree $1"; then
        printf 'refute_registered: git still lists %s\n' "$1" >&2
        return 1
    fi
    return 0
}

# assert_one_object <text> — exactly one JSON object on stdout, always.
assert_one_object() {
    if [ "$(printf '%s' "$1" | jq -s 'length' 2>/dev/null)" != "1" ]; then
        printf 'assert_one_object: stdout is not exactly one JSON object: %s\n' "$1" >&2
        return 1
    fi
    if [ "$(printf '%s' "$1" | jq -r 'type' 2>/dev/null)" != "object" ]; then
        printf 'assert_one_object: stdout is not an object: %s\n' "$1" >&2
        return 1
    fi
    return 0
}

rec() {  # <jq-path> — read the run record the surface wrote
    jq -r "$1" < "$RUN/team.json"
}

jq_free_path() {
    local d="$WORK/nojq" t p
    mkdir -p "$d"
    for t in bash sh sed awk grep cat wc tr cut head tail sort mktemp dirname \
             basename mkdir rm cp mv ln chmod find date id uname stat git python3; do
        p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$d/$t"
    done
    printf '%s' "$d"
}

# ===========================================================================
# R2 — one worktree per member
# ===========================================================================

@test "three members get three worktrees, each a distinct checkout of its own" {
    three_members
    [ "$status" -eq 0 ]
    assert_one_object "$output"
    [ "$(printf '%s' "$output" | jq -r '.ok')" = "true" ]

    local m tops="" top wt
    for m in lead scout mason; do
        wt="$(rec ".members[] | select(.name == \"$m\") | .worktree")"
        [ "$wt" = "$ROOT/r1/$m" ]
        assert_exists "$wt/.git"
        top="$(cd "$wt" && git rev-parse --show-toplevel)"
        top="$(cd "$top" && pwd -P)"
        [ "$top" = "$(cd "$wt" && pwd -P)" ]
        tops="$tops$top"$'\n'
    done
    # Distinct, not merely three answers: three members sharing one checkout
    # would contend for the one-job-per-worktree lock (R2).
    [ "$(printf '%s' "$tops" | sort -u | wc -l | tr -d ' ')" = "3" ]
}

# ===========================================================================
# R3 — the driver's own worktree never holds a member
# ===========================================================================

@test "a member placed in the driver's own worktree is refused, exit 2, named error" {
    roster --run-id r1 --run-dir "$RUN" \
        --member lead --alias sonnet --contract "$WORK/c1.md" --worktree "$PRIMARY"
    [ "$status" -eq 2 ]
    assert_one_object "$output"
    [ "$(printf '%s' "$output" | jq -r '.ok')" = "false" ]
    [ "$(printf '%s' "$output" | jq -r '.error')" = "driver_worktree" ]
    [ "$(printf '%s' "$output" | jq -r '.remedy | length > 0')" = "true" ]
    # Refused BEFORE anything was created: no record, no worktrees.
    refute_exists "$RUN/team.json"
    refute_exists "$ROOT/r1"
}

@test "control: the same call to a path that is NOT the driver's worktree is accepted" {
    # The control arm for the refusal above — it proves the refusal is about the
    # driver's toplevel and not about --worktree being given at all.
    roster --run-id r1 --run-dir "$RUN" \
        --member lead --alias sonnet --contract "$WORK/c1.md" --worktree "$ROOT/r1/lead"
    [ "$status" -eq 0 ]
    [ "$(rec '.members[0].worktree')" = "$ROOT/r1/lead" ]
    assert_exists "$ROOT/r1/lead/.git"
}

# ===========================================================================
# R25 / the provisional row
# ===========================================================================

@test "every member row is written pending with a null handle before any dispatch" {
    three_members
    [ "$status" -eq 0 ]
    local i
    for i in 0 1 2; do
        # Key PRESENCE and TYPE, not just the value: `.handle == null` is true
        # of a record with no handle key at all, and would have passed on day
        # zero. `has` cannot.
        [ "$(rec ".members[$i] | has(\"handle\")")" = "true" ]
        [ "$(rec ".members[$i] | has(\"launch_state\")")" = "true" ]
        [ "$(rec ".members[$i].handle")" = "null" ]
        [ "$(rec ".members[$i].launch_state")" = "pending" ]
        [ "$(rec ".members[$i].round")" = "null" ]
    done
    [ "$(rec '.members | length')" = "3" ]
    [ "$(rec '[.members[].name] | join(",")')" = "lead,scout,mason" ]
    # The row carries the member's own alias and skills — a team reports by name
    # and each member carries its own contract and skill list (R25).
    [ "$(rec '.members[0].alias')" = "sonnet" ]
    [ "$(rec '.members[0].skills | join(",")')" = "ce-code-review" ]
    [ "$(rec '.members[1].skills | length')" = "0" ]
}

# ===========================================================================
# Teardown removes exactly what the record names
# ===========================================================================

@test "teardown removes the worktrees the record names and leaves a sibling alone" {
    three_members
    [ "$status" -eq 0 ]

    # A worktree created OUTSIDE this run, beside the run's own directory. This
    # is what a glob of the destination would take with it.
    git -C "$PRIMARY" worktree add --detach -q "$ROOT/outsider" HEAD
    printf 'someone else was working here\n' > "$ROOT/outsider/WIP.txt"
    assert_exists "$ROOT/outsider/WIP.txt"

    run bash -c "cd '$PRIMARY' && bash '$TEAM' teardown --run-dir '$RUN' 2>/dev/null"
    [ "$status" -eq 0 ]
    assert_one_object "$output"
    [ "$(printf '%s' "$output" | jq -r '.removed | length')" = "3" ]

    # What the record named is gone...
    refute_exists "$ROOT/r1/lead"
    refute_exists "$ROOT/r1/scout"
    refute_exists "$ROOT/r1/mason"
    # ...and the sibling, with its uncommitted file, is untouched.
    assert_exists "$ROOT/outsider"
    assert_exists "$ROOT/outsider/WIP.txt"
    [ "$(cat "$ROOT/outsider/WIP.txt")" = "someone else was working here" ]
    # Still a live worktree to git, not just a surviving directory.
    git -C "$PRIMARY" worktree list | grep -q "$ROOT/outsider"
}

@test "control: refute_exists and assert_exists both fail on the case they deny" {
    # The absence assertions above are only evidence if they CAN fail. A member
    # path that is still there must redden refute_exists, and a sibling that was
    # removed must redden assert_exists.
    git -C "$PRIMARY" worktree add --detach -q "$ROOT/still-here" HEAD
    run refute_exists "$ROOT/still-here"
    [ "$status" -ne 0 ]
    run assert_exists "$ROOT/never-existed"
    [ "$status" -ne 0 ]
}

@test "teardown after a partial roster removes what exists and does not fail on what does not" {
    three_members
    [ "$status" -eq 0 ]
    # scout's checkout is taken away behind the run's back — teardown must
    # remove the other two and report the missing one rather than aborting.
    git -C "$PRIMARY" worktree remove --force "$ROOT/r1/scout"
    refute_exists "$ROOT/r1/scout"

    run bash -c "cd '$PRIMARY' && bash '$TEAM' teardown --run-dir '$RUN' 2>/dev/null"
    [ "$status" -eq 0 ]
    assert_one_object "$output"
    [ "$(printf '%s' "$output" | jq -r '.ok')" = "true" ]
    [ "$(printf '%s' "$output" | jq -r '.removed | length')" = "2" ]
    refute_exists "$ROOT/r1/lead"
    refute_exists "$ROOT/r1/mason"
}

@test "a member git will not remove is deregistered alone, never by a repo-wide prune" {
    three_members
    [ "$status" -eq 0 ]

    # A registration belonging to nobody in this run whose DIRECTORY is already
    # missing — git calls it "prunable". This is the entire blast radius of
    # `git worktree prune`: it deregisters every one of these in the repository,
    # including a sibling session's checkout caught mid-move or on a stalled
    # mount, and says nothing on either side.
    git -C "$PRIMARY" worktree add --detach -q "$ROOT/absent-sibling" HEAD
    rm -rf "$ROOT/absent-sibling"
    assert_registered "$ROOT/absent-sibling"

    # lead is locked, so `git worktree remove --force` refuses it and teardown
    # takes the fallback path — the only path that ever deregisters by hand.
    git -C "$PRIMARY" worktree lock "$ROOT/r1/lead"
    run git -C "$PRIMARY" worktree remove --force "$ROOT/r1/lead"
    [ "$status" -ne 0 ]

    run bash -c "cd '$PRIMARY' && bash '$TEAM' teardown --run-dir '$RUN' 2>/dev/null"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.removed | length')" = "3" ]

    # Our own member: gone from disk AND deregistered.
    refute_exists "$ROOT/r1/lead"
    refute_registered "$ROOT/r1/lead"
    # The stale registration this run never touched is STILL THERE. A prune
    # would have taken it, and nothing else in this file would have noticed.
    assert_registered "$ROOT/absent-sibling"
}

@test "a member whose .git points somewhere else does not get that somewhere else deleted" {
    # The registration to delete is read from the member's own checkout, so the
    # member's own checkout can lie about where it is. A `.git` FILE is one line
    # of text pointing at a directory, and it is inside a tree a running member
    # can write. Without the shape guard, teardown's fallback would delete
    # whatever it names — here, another repository's entire .git.
    git -C "$PRIMARY" init -q "$WORK/victim"
    assert_exists "$WORK/victim/.git"

    three_members
    [ "$status" -eq 0 ]
    printf 'gitdir: %s\n' "$WORK/victim/.git" > "$ROOT/r1/lead/.git"

    run bash -c "cd '$PRIMARY' && bash '$TEAM' teardown --run-dir '$RUN' 2>/dev/null"
    [ "$status" -eq 0 ]
    refute_exists "$ROOT/r1/lead"
    assert_exists "$WORK/victim/.git"
}

@test "control: assert_registered and refute_registered each fail on the case they deny" {
    git -C "$PRIMARY" worktree add --detach -q "$ROOT/registered" HEAD
    run refute_registered "$ROOT/registered"
    [ "$status" -ne 0 ]
    run assert_registered "$ROOT/never-registered"
    [ "$status" -ne 0 ]
}

@test "teardown refuses a recorded path that is not shaped like one the roster made" {
    # Default-deny on the SHAPE, not only on the source. A member row can name a
    # path the roster did not choose (an explicit --worktree), and a row is not
    # by itself consent to remove an arbitrary directory: only
    # `<root>/<run-id>/<member-name>` is removed. Without this, anything that
    # can write a member row can name any path on the box and have teardown
    # delete it.
    roster --run-id r1 --run-dir "$RUN" \
        --member lead --alias sonnet --contract "$WORK/c1.md" --worktree "$ROOT/elsewhere"
    [ "$status" -eq 0 ]
    [ "$(rec '.members[0].worktree')" = "$ROOT/elsewhere" ]
    assert_exists "$ROOT/elsewhere/.git"

    run bash -c "cd '$PRIMARY' && bash '$TEAM' teardown --run-dir '$RUN' 2>/dev/null"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.removed | length')" = "0" ]
    assert_exists "$ROOT/elsewhere/.git"
}

@test "control: the same member at the shape the roster makes IS removed" {
    # The control arm for the refusal above — it proves the skip is about the
    # path's shape and not about teardown being unable to remove anything.
    roster --run-id r1 --run-dir "$RUN" \
        --member lead --alias sonnet --contract "$WORK/c1.md" --worktree "$ROOT/r1/lead"
    [ "$status" -eq 0 ]
    run bash -c "cd '$PRIMARY' && bash '$TEAM' teardown --run-dir '$RUN' 2>/dev/null"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.removed | length')" = "1" ]
    refute_exists "$ROOT/r1/lead"
}

@test "teardown removes nothing whose path the record does not name" {
    three_members
    [ "$status" -eq 0 ]
    # A directory inside the run's OWN root that no member row names. Only the
    # record's paths may be removed, so this survives.
    mkdir -p "$ROOT/r1/not-a-member"
    printf 'x\n' > "$ROOT/r1/not-a-member/keep.txt"

    run bash -c "cd '$PRIMARY' && bash '$TEAM' teardown --run-dir '$RUN' 2>/dev/null"
    [ "$status" -eq 0 ]
    assert_exists "$ROOT/r1/not-a-member/keep.txt"
}

# ===========================================================================
# worktree_failed
# ===========================================================================

@test "a worktree that cannot be created marks that member launch_failed and spares the rest" {
    # The destination for scout is occupied by a plain file, so `git worktree
    # add` fails for scout and only for scout.
    mkdir -p "$ROOT/r1"
    printf 'in the way\n' > "$ROOT/r1/scout"

    three_members
    [ "$status" -eq 5 ]
    assert_one_object "$output"
    [ "$(printf '%s' "$output" | jq -r '.ok')" = "false" ]
    [ "$(printf '%s' "$output" | jq -r '.error')" = "worktree_failed" ]
    [ "$(printf '%s' "$output" | jq -r '.members[] | select(.name == "scout") | .error')" = "worktree_failed" ]

    [ "$(rec '.members[] | select(.name == "scout") | .launch_state')" = "launch_failed" ]
    # The rest of the roster is intact — rows AND checkouts.
    [ "$(rec '.members[] | select(.name == "lead") | .launch_state')" = "pending" ]
    [ "$(rec '.members[] | select(.name == "mason") | .launch_state')" = "pending" ]
    assert_exists "$ROOT/r1/lead/.git"
    assert_exists "$ROOT/r1/mason/.git"
    [ "$(rec '.members | length')" = "3" ]
}

@test "worktree_failed carries its own non-empty remedy, distinct from usage's" {
    mkdir -p "$ROOT/r1"
    printf 'in the way\n' > "$ROOT/r1/lead"
    roster --run-id r1 --run-dir "$RUN" --member lead --alias sonnet --contract "$WORK/c1.md"
    [ "$status" -eq 5 ]
    local wf; wf="$(printf '%s' "$output" | jq -r '.remedy')"
    [ -n "$wf" ]
    [ "$wf" != "null" ]

    roster --run-id r1 --run-dir "$RUN"
    [ "$status" -eq 2 ]
    local us; us="$(printf '%s' "$output" | jq -r '.remedy')"
    [ -n "$us" ]
    [ "$us" != "null" ]
    [ "$wf" != "$us" ]
}

# ===========================================================================
# The contract's floor: one JSON object on every path
# ===========================================================================

@test "with jq absent the roster still answers with one JSON-shaped refusal" {
    local nojq; nojq="$(jq_free_path)"
    run env PATH="$nojq" bash -c 'command -v jq 2>/dev/null'
    [ "$status" -ne 0 ]

    run env PATH="$nojq" bash -c "cd '$PRIMARY' && bash '$TEAM' roster --run-id r1 --member lead 2>/dev/null"
    [ "$status" -eq 2 ]
    assert_one_object "$output"
    [ "$(printf '%s' "$output" | jq -r '.ok')" = "false" ]
    [ "$(printf '%s' "$output" | jq -r '.error')" = "usage" ]
    [ "$(printf '%s' "$output" | jq -r '.remedy | length > 0')" = "true" ]
    refute_exists "$ROOT/r1"
}

@test "an unknown verb and a member name that fails the grammar are both one object, exit 2" {
    run bash -c "cd '$PRIMARY' && bash '$TEAM' fly 2>/dev/null"
    [ "$status" -eq 2 ]
    assert_one_object "$output"
    [ "$(printf '%s' "$output" | jq -r '.error')" = "usage" ]

    roster --run-id r1 --run-dir "$RUN" --member ../escape --alias sonnet --contract "$WORK/c1.md"
    [ "$status" -eq 2 ]
    assert_one_object "$output"
    [ "$(printf '%s' "$output" | jq -r '.error')" = "member_name_invalid" ]
    refute_exists "$ROOT/r1"
}

@test "the run's worktrees are excluded from the primary checkout's git status" {
    three_members
    [ "$status" -eq 0 ]
    [ "$(git -C "$PRIMARY" status --porcelain | wc -l | tr -d ' ')" = "0" ]
}
