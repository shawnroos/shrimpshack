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
    FIX="$(cd "$BATS_TEST_DIRNAME/../fixtures" && pwd)"
    LIB="$(cd "$BATS_TEST_DIRNAME/../../lib" && pwd)"
    TEAM="$LIB/team.sh"
    JOBS="$LIB/jobs.sh"
    BG="$LIB/bg-agent.sh"
    GW_PID=""
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
    sweep_preamble
    sweep_work
    rm -rf "$WORK"
}

# The two kills that must land BEFORE the sweep. Split out of teardown so the
# invariant test can run teardown's real sequence rather than an approximation
# of it — the ordering is load-bearing and the timing is what the race turns on.
sweep_preamble() {
    # `wait` on a TERMed job exits 143. Swallowed on purpose: that is this
    # function reaping what it just killed, not a failure to report.
    if [ -n "${GW_PID:-}" ]; then
        kill "$GW_PID" 2>/dev/null
        wait "$GW_PID" 2>/dev/null || :
    fi
    # A `hang` child execs `sleep 600` and keeps NOTHING of $WORK in its argv, so
    # the sweep below cannot see it. Its pid is the only handle on it, and the
    # fixture writes that down for exactly this reason.
    if [ -f "${FAKE_CLAUDE_RECORD_DIR:-/nonexistent}/pid" ]; then
        while read -r p; do
            if [ -n "$p" ]; then kill -9 "$p" 2>/dev/null || :; fi
        done < "$FAKE_CLAUDE_RECORD_DIR/pid"
    fi
    return 0
}

# sweep_work — leave no live process holding $WORK.
#
# ONE SNAPSHOT IS NOT A SWEEP. A single `pgrep`, kill that list, done, is stale
# the instant it is taken: bg-agent.sh nohup's the supervisor on its own clock
# after dispatch returns (lib/bg-agent.sh:602) and forks a `jobs.sh log` child
# per log line (lib/bg-agent.sh:415), so a process born after the snapshot is
# never signalled — and the `rm -rf` that follows then walks a tree that
# process is still writing into, which is the "Directory not empty" this file
# used to fail with. So: re-sweep until a pass sees NOTHING. The clean pass IS
# the wait; these are not our children, so `wait` cannot be used on them.
#
# EVERY signal is scoped to this test's own mktemp $WORK path. Never signal by
# script name: other sessions on the same box run these same scripts, and a
# name-scoped kill takes their work with it.
#
# On an exhausted budget this prints the survivors and returns 1. Measured: a
# non-zero return from HERE is swallowed by teardown, whose status comes from the
# `rm -rf` after it, so the printf is what a reader actually gets. The return
# code earns its place with a direct caller that checks it — the invariant test
# below does.
sweep_work() {
    local pass p found
    for pass in $(seq 1 25); do
        found=0
        for p in $(pgrep -f "$WORK" 2>/dev/null); do
            [ "$p" = "$$" ] && continue
            found=1
            # `|| :` because a pid can exit between the pgrep and this kill, and
            # kill then returns 1. A bats test body runs under errexit, so an
            # unguarded kill aborts the sweep mid-pass — measured, as a failure
            # of this very test in a full-file run.
            kill -9 "$p" 2>/dev/null || :
        done
        if [ "$found" -eq 0 ]; then return 0; fi
        sleep 0.1
    done
    printf 'sweep_work: processes still hold %s after 25 passes:\n' "$WORK" >&2
    for p in $(pgrep -f "$WORK" 2>/dev/null); do
        [ "$p" = "$$" ] && continue
        ps -o pid=,args= -p "$p" 2>/dev/null
    done >&2
    return 1
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
    # Four, not three: the run's own emptied root is removed with them (R11).
    [ "$(printf '%s' "$output" | jq -r '.removed | length')" = "4" ]

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
    [ "$(printf '%s' "$output" | jq -r '.removed | length')" = "3" ]
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
    [ "$(printf '%s' "$output" | jq -r '.removed | length')" = "4" ]

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

@test "a member pointing at a SIBLING worktree's registration does not get it deleted" {
    # The test above aims the poisoned `.git` at another REPOSITORY's main git
    # dir, where `common` and `admin` are the same directory and the shape check
    # refuses. A SIBLING LINKED WORKTREE's registration has exactly the shape the
    # check permits — `<common>/worktrees/<name>` — so shape alone let a member
    # name another live session's checkout and have teardown deregister it.
    # Measured before the fix: the victim's index, HEAD, refs and reflog were
    # removed and its `git status` became "not a repository".
    git -C "$PRIMARY" worktree add -q --detach "$WORK/victim-live"
    printf 'uncommitted\n' > "$WORK/victim-live/WIP.txt"
    assert_exists "$PRIMARY/.git/worktrees/victim-live"

    three_members
    [ "$status" -eq 0 ]
    printf 'gitdir: %s/.git/worktrees/victim-live\n' "$PRIMARY" > "$ROOT/r1/lead/.git"

    run bash -c "cd '$PRIMARY' && bash '$TEAM' teardown --run-dir '$RUN' 2>/dev/null"
    [ "$status" -eq 0 ]
    # The sibling survives as a REGISTERED worktree, not merely as a directory:
    # deleting the registration is what kills it, and the checkout would still
    # be sitting there afterwards looking fine.
    assert_exists "$PRIMARY/.git/worktrees/victim-live"
    assert_registered "$WORK/victim-live"
    grep -qF uncommitted "$WORK/victim-live/WIP.txt"
}

@test "control: an honest member's own registration IS still removed" {
    # Without this arm the test above passes on a guard that refuses every
    # admin dir — which would read as "hostile case blocked" while silently
    # disabling teardown's deregistration entirely. That exact regression
    # happened while writing the fix.
    three_members
    [ "$status" -eq 0 ]
    assert_exists "$PRIMARY/.git/worktrees/lead"

    run bash -c "cd '$PRIMARY' && bash '$TEAM' teardown --run-dir '$RUN' 2>/dev/null"
    [ "$status" -eq 0 ]
    refute_exists "$ROOT/r1/lead"
    refute_registered "$WORK/nonexistent-never-made"
    refute_exists "$PRIMARY/.git/worktrees/lead"
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
    [ "$(printf '%s' "$output" | jq -r '.removed | length')" = "2" ]
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
# R11, R12 — the run's own worktree root does not outlive the run
# ===========================================================================

@test "teardown removes the run's own empty root and names it in removed" {
    three_members
    [ "$status" -eq 0 ]
    assert_exists "$ROOT/r1"

    run bash -c "cd '$PRIMARY' && bash '$TEAM' teardown --run-dir '$RUN' 2>/dev/null"
    [ "$status" -eq 0 ]
    assert_one_object "$output"
    refute_exists "$ROOT/r1"
    # NAMED, not merely counted: the operator reads `removed` to know what went.
    [ "$(printf '%s' "$output" | jq -r --arg r "$ROOT/r1" '.removed | index($r) != null')" = "true" ]
    # The worktrees/ directory the run's root sat in is not the run's to remove.
    assert_exists "$ROOT"
}

@test "teardown leaves a run root that still holds an unrelated file, and still succeeds" {
    three_members
    [ "$status" -eq 0 ]
    # Somebody else's file inside the run's root. `rmdir` refuses a non-empty
    # directory, which is why it is the verb here (KTD9).
    printf 'not ours\n' > "$ROOT/r1/stray.txt"

    run bash -c "cd '$PRIMARY' && bash '$TEAM' teardown --run-dir '$RUN' 2>/dev/null"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.ok')" = "true" ]
    [ "$(printf '%s' "$output" | jq -r '.removed | length')" = "3" ]
    assert_exists "$ROOT/r1"
    assert_exists "$ROOT/r1/stray.txt"
    [ "$(cat "$ROOT/r1/stray.txt")" = "not ours" ]
}

@test "the run-root prune refuses a root whose basename is not the run id" {
    # Not reachable through the teardown verb: both ways a root is resolved —
    # the parent of a shape-checked member path, and the configured-root
    # fallback — already make the basename the run id. The guard is called
    # directly so it is proved rather than assumed (KTD9).
    mkdir -p "$ROOT/notr1"
    run bash -c ". '$LIB/team-worktree.sh' && spawn::team_run_root_prune '$ROOT/notr1' r1"
    [ "$status" -eq 1 ]
    assert_exists "$ROOT/notr1"

    run bash -c ". '$LIB/team-worktree.sh' && spawn::team_run_root_prune '$ROOT/notr1' notr1"
    [ "$status" -eq 0 ]
    refute_exists "$ROOT/notr1"
}

@test "teardown removes the run root when no member row names a worktree" {
    # The all-unplaced shape. No member row carries a path, so the root cannot
    # be read off one — it comes from the configured worktree root and the run
    # id. The root is made unwritable so every checkout fails and NOTHING is
    # left inside it; `rmdir` needs write on the parent, not on the root.
    mkdir -p "$ROOT/r1"
    chmod 555 "$ROOT/r1"
    three_members
    [ "$status" -eq 5 ]
    [ "$(rec '.members[0].worktree')" = "" ]
    [ "$(rec '.members[2].worktree')" = "" ]
    assert_exists "$ROOT/r1"

    run bash -c "cd '$PRIMARY' && bash '$TEAM' teardown --run-dir '$RUN' 2>/dev/null"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r --arg r "$ROOT/r1" '.removed | index($r) != null')" = "true" ]
    refute_exists "$ROOT/r1"
}

@test "teardown removes the root the member paths name, not the configured one" {
    # The two ways a root is resolved normally land on the same directory, so
    # neither is proved while they agree. An explicit --worktree puts the run's
    # members somewhere the configured root does not point, which is the only
    # shape that tells the parent-of-the-member-path rule from the fallback.
    roster --run-id r1 --run-dir "$RUN" \
        --member lead --alias sonnet --contract "$WORK/c1.md" --worktree "$WORK/alt/r1/lead"
    [ "$status" -eq 0 ]
    assert_exists "$WORK/alt/r1/lead/.git"
    refute_exists "$ROOT/r1"

    run bash -c "cd '$PRIMARY' && bash '$TEAM' teardown --run-dir '$RUN' 2>/dev/null"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r --arg r "$WORK/alt/r1" '.removed | index($r) != null')" = "true" ]
    refute_exists "$WORK/alt/r1"
    # One level only: the directory the run's root sat in is not the run's.
    assert_exists "$WORK/alt"
}

@test "a dispatch that places no member leaves no run root behind" {
    # Runs 1 and 2 of the incident: every member failed to get a checkout,
    # teardown was never called, and the empty root stayed beside real
    # worktrees where `wtl` finds it.
    dispatch_env "alpha"
    contract_file "$WORK/c.json" out.txt
    team_file "$WORK/team.json" single-round 2 "solo:alpha:$WORK/c.json"
    mkdir -p "$ROOT/rz"
    chmod 555 "$ROOT/rz"

    dispatch --team-file "$WORK/team.json" --run-id rz --run-dir "$WORK/rz"
    [ "$status" -eq 5 ]
    [ "$(out '.error')" = "worktree_failed" ]
    refute_exists "$ROOT/rz"
}

@test "control: a dispatch that places a member leaves the run root in place" {
    # The control arm for the case above — it proves the removal is about the
    # root being EMPTY and not about dispatch removing its root whenever a
    # member failed.
    dispatch_env "alpha"
    contract_file "$WORK/c.json" out.txt
    team_file "$WORK/team.json" attached 1 "lead:alpha:$WORK/c.json"

    dispatch --team-file "$WORK/team.json" --run-id rk --run-dir "$WORK/rk"
    [ "$status" -eq 0 ]
    assert_exists "$ROOT/rk"
    assert_exists "$ROOT/rk/lead/.git"
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

@test "a second round is dispatched from the RUN ID, and round 1's ledger survives" {
    # Nothing exercised a second round before this. `dispatch` required
    # --team-file, so the only invocation that parsed re-created the record:
    # round 1's ledger was destroyed and every member was re-placed onto its own
    # existing checkout, which `git worktree add` refuses. attached and
    # unattended modes could not run a second round at all, while `advance`
    # printed `continue` and both the skill and the command documented a flag
    # that did not exist.
    dispatch_env "alpha"
    contract_file "$WORK/c.json" out.txt
    team_file "$WORK/team.json" attached 1 \
        "lead:alpha:$WORK/c.json" "scout:alpha:$WORK/c.json"

    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN"
    [ "$status" -eq 0 ]
    [ "$(out '.round')" = "1" ]
    [ "$(rec '.members[] | select(.name == "lead") | .launch_state')" = "dispatched" ]
    [ "$(rec '.members[] | select(.name == "scout") | .launch_state')" = "pending" ]

    dispatch --run-id r1 --run-dir "$RUN"
    [ "$status" -eq 0 ]
    [ "$(out '.round')" = "2" ]
    # Round 1's ledger is intact and scout joined round 2 — the two halves of
    # "continued" as opposed to "restarted".
    [ "$(rec '.rounds | length')" = "2" ]
    [ "$(rec '.rounds[0].ordinal')" = "1" ]
    [ "$(rec '.members[] | select(.name == "scout") | .round')" = "2" ]
    [ "$(rec '.members[] | select(.name == "lead") | .round')" = "1" ]
    # The RESPONSE must carry it too, not only the record. dispatch lists EVERY
    # member, so without a per-member round a caller reading the response cannot
    # tell which of them this answer is about — it sees three names and one
    # top-level round number.
    [ "$(out '.members[] | select(.name == "scout") | .round')" = "2" ]
    [ "$(out '.members[] | select(.name == "lead") | .round')" = "1" ]
    # lead was NOT re-placed: its handle is the one round 1 gave it.
    [ -n "$(rec '.members[] | select(.name == "lead") | .handle')" ]
}

@test "control: a second dispatch with the TEAM FILE is refused, not silently destructive" {
    # The form that used to wipe the run. It must now refuse rather than
    # re-create, and refuse BEFORE touching the record.
    dispatch_env "alpha"
    contract_file "$WORK/c.json" out.txt
    team_file "$WORK/team.json" attached 1 \
        "lead:alpha:$WORK/c.json" "scout:alpha:$WORK/c.json"

    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN"
    [ "$status" -eq 0 ]
    local before; before="$(rec '.rounds | length')"

    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN"
    [ "$status" -eq 2 ]
    [ "$(out '.error')" = "usage" ]
    [ "$(rec '.rounds | length')" = "$before" ]
}

@test "dispatch on a run with nothing pending refuses instead of opening an empty round" {
    # An empty round sits at `running` for ever, because a round with no members
    # assigned never satisfies "every assigned member is terminal" — the exact
    # shape that hangs a driver.
    dispatch_env "alpha"
    contract_file "$WORK/c.json" out.txt
    team_file "$WORK/team.json" attached 2 "solo:alpha:$WORK/c.json"

    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN"
    [ "$status" -eq 0 ]
    [ "$(rec '.members[] | select(.name == "solo") | .launch_state')" = "dispatched" ]

    dispatch --run-id r1 --run-dir "$RUN"
    [ "$status" -eq 2 ]
    [ "$(out '.error')" = "usage" ]
    [ "$(rec '.rounds | length')" = "1" ]
}

@test "dispatch reports worktree_failed when nothing reached a launcher, not launch_failed" {
    # Both causes exit 5, so the ERROR VALUE is the only thing telling a caller
    # which recovery to attempt. Reporting launch_failed here hands them "its
    # launcher refused it" for a member whose checkout was never created — a
    # launcher that was never invoked cannot have refused anything.
    dispatch_env "alpha"
    contract_file "$WORK/c.json" out.txt
    team_file "$WORK/team.json" single-round 2 "solo:alpha:$WORK/c.json"
    # The destination for the one member is occupied by a plain file.
    mkdir -p "$ROOT/rwt"
    printf 'in the way\n' > "$ROOT/rwt/solo"

    dispatch --team-file "$WORK/team.json" --run-id rwt --run-dir "$WORK/rwt"
    [ "$status" -eq 5 ]
    assert_one_object "$output"
    [ "$(out '.error')" = "worktree_failed" ]
    # Both directions: the wrong sentence is absent AND the right one is
    # present, because absence alone passes on an empty remedy.
    refute_file_match "its launcher refused it" <(out '.remedy')
    out '.remedy' | grep -qF 'has no checkout'
}

@test "control: dispatch still reports launch_failed when a launcher really did refuse" {
    # Placement SUCCEEDS here, so the failure comes from the launcher. Without
    # this arm the test above passes on a surface that always says
    # worktree_failed regardless of cause.
    dispatch_env "alpha"
    team_file "$WORK/team.json" single-round 2 "solo:alpha:$WORK/absent-contract.json"

    dispatch --team-file "$WORK/team.json" --run-id rlf --run-dir "$WORK/rlf"
    [ "$status" -eq 5 ]
    [ "$(out '.error')" = "launch_failed" ]
    [ "$(out '.members[] | select(.name == "solo") | .error')" != "worktree_failed" ]
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

# ===========================================================================
# U4 — `dispatch`: one round, then exit (R1, R4, R5, R25, R31, R33, KTD9,
# KTD17, KTD22).
#
# WHY THESE TESTS RUN THE WHOLE CHAIN
# -----------------------------------
# Dispatch's job is to get a member's OWN alias and a member's OWN skills into
# the process that eventually runs. bg-agent detaches its supervisor with
# `nohup bash "$SELF" --supervise ...`, and everything the supervisor needs must
# be written onto that one command line — a flag parsed by the launcher and left
# off it arrives empty at the child with both ends green. That is a shipped bug
# in this repo, in this file's sibling. So the alias assertion reads the argv
# the FIXTURE recorded (`--model <alias>`, one entry per invocation) and the
# skills assertion reads what the DETACHED SUPERVISOR wrote down and provisioned
# — records on the far side of the boundary. A launcher-side assertion would
# prove nothing about either.
# ===========================================================================

dispatch_env() {    # <alias,alias,...> — the fixture gateway and fixture CLI
    local aliases="$1" portfile="$WORK/port" a i
    export SPAWN_STATE_HOME="$WORK"
    export SPAWN_SEARCH_ROOT="$WORK/searchroot"; mkdir -p "$SPAWN_SEARCH_ROOT"
    export TMPDIR="$WORK/tmp"; mkdir -p "$TMPDIR"
    export SPAWN_CONNECT_TIMEOUT=2 SPAWN_PROBE_TIMEOUT=5
    export SPAWN_START_TIMEOUT=10 SPAWN_LOCK_TIMEOUT=30
    unset SPAWN_INSTALL_DIR SPAWN_CONFIG SPAWN_MODELS_JSON SPAWN_CLAUDE_BIN
    unset SPAWN_BG_TIMEOUT SPAWN_JOB_ROOT
    unset FAKE_CLAUDE_MODE FAKE_CLAUDE_WRITE FAKE_CLAUDE_DENIALS FAKE_CLAUDE_MODEL_USAGE
    export CLAUDE_CONFIG_DIR="$WORK/claude-home"; mkdir -p "$CLAUDE_CONFIG_DIR"
    export FAKE_CLAUDE_RECORD_DIR="$WORK/rec"; mkdir -p "$FAKE_CLAUDE_RECORD_DIR"
    export SPAWN_SKILLS_HOME="$WORK/skills-home"

    mkdir -p "$WORK/bin"
    ln -sf "$FIX/fake-claude.sh" "$WORK/bin/claude"
    export PATH="$WORK/bin:$PATH"

    rm -f "$portfile"
    python3 "$FIX/fake-gateway.py" --token tok-team-s3cr3t --aliases "$aliases" \
        --scenario healthy --port-file "$portfile" >"$WORK/gw.out" 2>"$WORK/gw.err" &
    GW_PID=$!
    for i in $(seq 1 100); do [ -s "$portfile" ] && break; sleep 0.05; done
    PORT="$(cat "$portfile")"
    [ -n "$PORT" ]
    export SPAWN_BASE_URL="http://127.0.0.1:$PORT/anthropic"
    {
        printf 'server:\n  bind: "127.0.0.1:4000"\n  token: tok-team-s3cr3t\n\nmodels:\n'
        for a in $(printf '%s' "$aliases" | tr ',' ' '); do
            printf '  %s:\n    model: up/%s\n' "$a" "$a"
        done
    } > "$WORK/gateway.yaml"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
}

fake_skill() {      # <name> — a skill on the operator's side, for provisioning
    mkdir -p "$SPAWN_SKILLS_HOME/skills/$1"
    printf -- '---\nname: %s\n---\nfixture skill\n' "$1" > "$SPAWN_SKILLS_HOME/skills/$1/SKILL.md"
}

contract_file() {   # <path> <deliverable>
    jq -n --arg d "$2" '{task:("create " + $d), done_means:"the deliverable exists",
                         deliverables:[$d]}' > "$1"
}

# team_file <path> <mode> <max-concurrent> <name:alias:contract[:skill,skill]>...
#
# NO `token_ceiling` KEY unless TEAM_FILE_CEILING is set. Absent is the normal
# case (KTD20: there is no default ceiling), and a file stating 0 is refused at
# dispatch — so a helper that always wrote one could produce neither the
# no-bound case nor an accepted run.
team_file() {
    local f="$1" mode="$2" mc="$3"; shift 3
    local spec name alias contract skills members='[]'
    for spec in "$@"; do
        name="${spec%%:*}"; spec="${spec#*:}"
        alias="${spec%%:*}"; spec="${spec#*:}"
        contract="${spec%%:*}"; skills="${spec#*:}"
        if [ "$skills" = "$contract" ]; then skills=""; fi
        members="$(printf '%s' "$members" | jq -c --arg n "$name" --arg a "$alias" \
            --arg c "$contract" --arg s "$skills" \
            '. + [{name:$n, alias:$a, contract:$c,
                   skills:($s | split(",") | map(select(length > 0)))}]')"
    done
    jq -n --arg m "$mode" --argjson mc "$mc" --argjson ms "$members" \
        --arg tc "${TEAM_FILE_CEILING:-}" \
        '{mode:$m, bounds:{max_concurrent:$mc, max_rounds:3},
          members:$ms}
         | (if $tc == "" then . else .bounds.token_ceiling = ($tc | tonumber) end)' > "$f"
}

dispatch() {        # <args...> — always from inside the temp checkout
    run bash -c "cd '$PRIMARY' && bash '$TEAM' dispatch $* 2>/dev/null"
}

out() { printf '%s' "$output" | jq -r "$1"; }

# The supervisor is detached, so the child's record appears AFTER dispatch has
# returned. Polling is the property, not a workaround: KTD17 says dispatch does
# not wait.
await_invocations() {   # <count> [seconds]
    local want="$1" limit="${2:-40}" i n=0
    for i in $(seq 1 $((limit * 5))); do
        n="$(grep -c '^--- invocation' "$FAKE_CLAUDE_RECORD_DIR/argv" 2>/dev/null)" || n=0
        [ "$n" -ge "$want" ] && return 0
        sleep 0.2
    done
    printf 'await_invocations: wanted %s child invocations, saw %s\n' "$want" "$n" >&2
    return 1
}

await_file() {      # <path> [seconds]
    local f="$1" limit="${2:-40}" i
    for i in $(seq 1 $((limit * 5))); do
        [ -e "$f" ] && return 0
        sleep 0.2
    done
    printf 'await_file: %s never appeared\n' "$f" >&2
    return 1
}

child_models() { awk '/^--model$/{getline; print}' "$FAKE_CLAUDE_RECORD_DIR/argv"; }

assert_child_alias() {  # <alias> — this alias reached a child's own argv
    if ! child_models | grep -qxF "$1"; then
        printf 'assert_child_alias: no child was invoked with --model %s\n' "$1" >&2
        child_models >&2
        return 1
    fi
    return 0
}

refute_child_alias() {  # <alias>
    if child_models | grep -qxF "$1"; then
        printf 'refute_child_alias: a child WAS invoked with --model %s\n' "$1" >&2
        return 1
    fi
    return 0
}

member_job_dir() {  # <handle> <worktree>
    bash "$JOBS" state --handle "$1" --cwd "$2" 2>/dev/null | jq -r '.job.job_dir // empty'
}

member_wt() { rec ".members[] | select(.name == \"$1\") | .worktree"; }
member_handle() { rec ".members[] | select(.name == \"$1\") | .handle"; }
member_state() { rec ".members[] | select(.name == \"$1\") | .launch_state"; }

# ---------------------------------------------------------------------------
# R4 / KTD9 — the round is bounded, and a bigger roster clamps
# ---------------------------------------------------------------------------

@test "four members with a maximum of two dispatch two, and the rest stay pending" {
    dispatch_env "alpha,beta,gamma,delta"
    contract_file "$WORK/c.json" out.txt
    team_file "$WORK/team.json" attached 2 \
        "lead:alpha:$WORK/c.json" "scout:beta:$WORK/c.json" \
        "mason:gamma:$WORK/c.json" "clerk:delta:$WORK/c.json"

    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN"
    [ "$status" -eq 0 ]
    assert_one_object "$output"
    # Clamping is not a refusal (KTD9), and the response says how many remain.
    [ "$(out '.ok')" = "true" ]
    [ "$(out '.dispatched')" = "2" ]
    [ "$(out '.pending')" = "2" ]

    [ "$(member_state lead)" = "dispatched" ]
    [ "$(member_state scout)" = "dispatched" ]
    [ "$(member_state mason)" = "pending" ]
    [ "$(member_state clerk)" = "pending" ]
    # Four worktrees exist either way: a pending member is placed, not deferred.
    assert_exists "$ROOT/r1/clerk/.git"
}

@test "the concurrency maximum is the caller's, not a constant: the same roster at 3 dispatches 3" {
    # The control arm for the clamp above — it proves 2 was the bound the caller
    # gave and not a number compiled into the surface (KTD9).
    dispatch_env "alpha,beta,gamma,delta"
    contract_file "$WORK/c.json" out.txt
    team_file "$WORK/team.json" attached 3 \
        "lead:alpha:$WORK/c.json" "scout:beta:$WORK/c.json" \
        "mason:gamma:$WORK/c.json" "clerk:delta:$WORK/c.json"

    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN"
    [ "$status" -eq 0 ]
    [ "$(out '.dispatched')" = "3" ]
    [ "$(out '.pending')" = "1" ]
}

@test "a bound given in the file and again as a flag takes the flag's value" {
    dispatch_env "alpha,beta,gamma"
    contract_file "$WORK/c.json" out.txt
    team_file "$WORK/team.json" attached 2 \
        "lead:alpha:$WORK/c.json" "scout:beta:$WORK/c.json" "mason:gamma:$WORK/c.json"

    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN" --max-concurrent 1
    [ "$status" -eq 0 ]
    [ "$(out '.dispatched')" = "1" ]
    # The record keeps the EFFECTIVE bound, not the file's.
    [ "$(rec '.bounds.max_concurrent')" = "1" ]
}

# ---------------------------------------------------------------------------
# The two argv scenarios (R25) — asserted on the child's side of the detach
# ---------------------------------------------------------------------------

@test "each child is invoked with its OWN alias, on the fixture's own argv record" {
    dispatch_env "alpha,beta"
    contract_file "$WORK/c.json" out.txt
    team_file "$WORK/team.json" attached 2 \
        "lead:alpha:$WORK/c.json" "scout:beta:$WORK/c.json"

    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN"
    [ "$status" -eq 0 ]
    [ "$(out '.dispatched')" = "2" ]

    await_invocations 2
    # One entry per member, each carrying that member's alias — the value the
    # launcher parsed only counts if it crossed the nohup boundary.
    [ "$(child_models | sort | tr '\n' ',')" = "alpha,beta," ]
    assert_child_alias alpha
    assert_child_alias beta
    # ...and nothing else was invoked: an alias no member named must be absent.
    refute_child_alias gamma
}

@test "control: refute_child_alias fails on an alias a child really did receive" {
    dispatch_env "alpha"
    contract_file "$WORK/c.json" out.txt
    team_file "$WORK/team.json" attached 2 "lead:alpha:$WORK/c.json"
    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN"
    [ "$status" -eq 0 ]
    await_invocations 1
    run refute_child_alias alpha
    [ "$status" -ne 0 ]
    run assert_child_alias never-served
    [ "$status" -ne 0 ]
}

@test "each member's supervisor receives that member's skills and no others" {
    dispatch_env "alpha,beta"
    fake_skill lead-only
    fake_skill scout-only
    contract_file "$WORK/c.json" out.txt
    team_file "$WORK/team.json" attached 2 \
        "lead:alpha:$WORK/c.json:lead-only" "scout:beta:$WORK/c.json:scout-only"

    # The child hangs, so the provisioned skills are still on disk to be looked
    # at: the supervisor removes them the moment the job ends.
    export FAKE_CLAUDE_MODE=hang
    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN"
    [ "$status" -eq 0 ]

    local lead_dir scout_dir
    lead_dir="$(member_job_dir "$(member_handle lead)" "$(member_wt lead)")"
    scout_dir="$(member_job_dir "$(member_handle scout)" "$(member_wt scout)")"
    [ -n "$lead_dir" ]
    [ -n "$scout_dir" ]

    # skills.requested is written BY THE DETACHED SUPERVISOR from the argv it
    # was handed. It is the record that crosses the boundary for skills, which
    # never reach the child's own command line.
    await_file "$lead_dir/skills.requested"
    await_file "$scout_dir/skills.requested"
    [ "$(cat "$lead_dir/skills.requested")" = "lead-only" ]
    [ "$(cat "$scout_dir/skills.requested")" = "scout-only" ]

    # And the effect: each member's worktree holds its own skill and not its
    # team-mate's.
    await_file "$(member_wt lead)/.claude/skills/lead-only/SKILL.md"
    await_file "$(member_wt scout)/.claude/skills/scout-only/SKILL.md"
    refute_exists "$(member_wt lead)/.claude/skills/scout-only"
    refute_exists "$(member_wt scout)/.claude/skills/lead-only"
}

@test "control: a member named no skills gets no skills directory at all" {
    # The absence half of the scenario above can only be read if the present
    # case is reachable, and this arm proves the emptiness is the team file's
    # doing rather than provisioning being broken for everyone.
    dispatch_env "alpha,beta"
    fake_skill lead-only
    contract_file "$WORK/c.json" out.txt
    team_file "$WORK/team.json" attached 2 \
        "lead:alpha:$WORK/c.json:lead-only" "scout:beta:$WORK/c.json"

    export FAKE_CLAUDE_MODE=hang
    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN"
    [ "$status" -eq 0 ]
    await_file "$(member_wt lead)/.claude/skills/lead-only/SKILL.md"
    refute_exists "$(member_wt scout)/.claude/skills"
    [ "$(rec '.members[] | select(.name == "scout") | .skills | length')" = "0" ]
}

# ---------------------------------------------------------------------------
# R5 — a failed launch is recorded and the round continues
# ---------------------------------------------------------------------------

@test "a launch that fails records that member and the NEXT member still runs" {
    dispatch_env "alpha,beta"
    contract_file "$WORK/c.json" out.txt
    # lead's contract does not exist, so bg-agent refuses that one launch and
    # only that one.
    team_file "$WORK/team.json" attached 2 \
        "lead:alpha:$WORK/no-such-contract.json" "scout:beta:$WORK/c.json"

    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN"
    assert_one_object "$output"
    [ "$(out '.dispatched')" = "1" ]
    [ "$(member_state lead)" = "launch_failed" ]
    [ "$(member_state scout)" = "dispatched" ]
    # The response names the launcher's OWN error value for the member it hit.
    [ "$(out '.members[] | select(.name == "lead") | .error')" = "contract_invalid" ]
    [ "$(out '.members[] | select(.name == "scout") | .error')" = "null" ]

    # The proof that the round continued is on the child's side: an invocation
    # exists for the LATER member.
    await_invocations 1
    assert_child_alias beta
    refute_child_alias alpha
}

@test "a launch refused with job_already_running records that member and is not retried" {
    dispatch_env "alpha,beta"
    contract_file "$WORK/c.json" out.txt
    export FAKE_CLAUDE_MODE=hang
    # One job root for every member, so the one-job-at-a-time lock is shared and
    # the SECOND member meets it. A member's own fresh checkout can never hold a
    # prior job, so this configuration is the only way the refusal is reachable
    # from a first round at all — and the refusal is the launcher's, recorded
    # verbatim rather than reduced to "it failed".
    export SPAWN_JOB_ROOT="$WORK/jobroot"

    team_file "$WORK/team.json" attached 2 \
        "lead:alpha:$WORK/c.json" "scout:beta:$WORK/c.json"
    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN"
    assert_one_object "$output"
    # scout is launch_failed, so `dispatched` is lead alone. This count is the
    # roster-versus-count disagreement this branch exists to close, so it is
    # asserted here rather than left to the member states below.
    [ "$(out '.dispatched')" = "1" ]
    [ "$(member_state lead)" = "dispatched" ]
    [ "$(member_state scout)" = "launch_failed" ]
    [ "$(out '.members[] | select(.name == "scout") | .error')" = "job_already_running" ]
    [ "$(member_handle scout)" = "null" ]

    # Not retried, and not retried into a stolen lock: the job the root holds is
    # still lead's, and scout produced no second child.
    local h; h="$(member_handle lead)"
    [ "$(bash "$JOBS" state --handle "$h" --cwd "$(member_wt lead)" | jq -r '.job.state')" = "running" ]
    await_invocations 1
    assert_child_alias alpha
    refute_child_alias beta
}

@test "every dispatched member carries its handle in the record before the next launch begins" {
    dispatch_env "alpha,beta"
    contract_file "$WORK/c.json" out.txt
    # scout's launch fails, so the record is read at a moment when lead's row is
    # the only completed one — its handle must already be there.
    team_file "$WORK/team.json" attached 2 \
        "lead:alpha:$WORK/c.json" "scout:beta:$WORK/no-such-contract.json"

    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN"
    [ "$(member_state lead)" = "dispatched" ]
    [ "$(rec '.members[] | select(.name == "lead") | has("handle")')" = "true" ]
    local h; h="$(member_handle lead)"
    [ -n "$h" ]
    [ "$h" != "null" ]
    # The handle is a real one the record layer answers for, not a placeholder.
    [ "$(bash "$JOBS" state --handle "$h" --cwd "$(member_wt lead)" | jq -r '.job.job_id')" = "$h" ]
    [ "$(out '.members[] | select(.name == "lead") | .handle')" = "$h" ]
}

# ---------------------------------------------------------------------------
# KTD17 — dispatch does not wait
# ---------------------------------------------------------------------------

@test "dispatch returns while a member is still live" {
    dispatch_env "alpha"
    contract_file "$WORK/c.json" out.txt
    export FAKE_CLAUDE_MODE=hang
    team_file "$WORK/team.json" attached 2 "lead:alpha:$WORK/c.json"

    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN"
    [ "$status" -eq 0 ]
    [ "$(out '.dispatched')" = "1" ]

    # The command has already returned — `run` collected its status. The child it
    # started is STILL RUNNING, which is the whole claim: no waiting, no reaping.
    await_file "$FAKE_CLAUDE_RECORD_DIR/pid"
    local pid; pid="$(head -1 "$FAKE_CLAUDE_RECORD_DIR/pid")"
    [ -n "$pid" ]
    kill -0 "$pid"
    [ "$(bash "$JOBS" state --handle "$(member_handle lead)" --cwd "$(member_wt lead)" \
        | jq -r '.job.state')" = "running" ]
}

# ---------------------------------------------------------------------------
# R33 / KTD22 — the team travels as a file, and the file is copied
# ---------------------------------------------------------------------------

@test "the team file is copied into the record, and editing the original does not move the target" {
    dispatch_env "alpha,beta"
    contract_file "$WORK/c.json" out.txt
    team_file "$WORK/team.json" attached 1 \
        "lead:alpha:$WORK/c.json" "scout:beta:$WORK/c.json"

    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN"
    [ "$status" -eq 0 ]
    local copy; copy="$(out '.team_file')"
    [ -n "$copy" ]
    [ "$copy" != "$WORK/team.json" ]
    assert_exists "$copy"
    [ "$(jq -r '[.members[].name] | join(",")' < "$copy")" = "lead,scout" ]

    # The caller edits the original afterwards. The run's copy is unmoved.
    team_file "$WORK/team.json" attached 1 "impostor:alpha:$WORK/c.json"
    [ "$(jq -r '[.members[].name] | join(",")' < "$copy")" = "lead,scout" ]
    [ "$(rec '[.members[].name] | join(",")')" = "lead,scout" ]
}

@test "dispatch mints a run id the later verbs take, without re-stating the team" {
    dispatch_env "alpha"
    contract_file "$WORK/c.json" out.txt
    team_file "$WORK/team.json" attached 1 "lead:alpha:$WORK/c.json"

    dispatch --team-file "$WORK/team.json" --run-dir "$RUN"
    [ "$status" -eq 0 ]
    local id; id="$(out '.run_id')"
    [ -n "$id" ]
    [ "$id" != "null" ]
    [ "$(rec '.run_id')" = "$id" ]
    # teardown takes the run, and names no member, alias or contract.
    run bash -c "cd '$PRIMARY' && bash '$TEAM' teardown --run-dir '$RUN' 2>/dev/null"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.run_id')" = "$id" ]
}

# ---------------------------------------------------------------------------
# The team file's grammar — every refusal before anything is created
# ---------------------------------------------------------------------------

@test "a team file that is not one JSON object is refused, exit 2, nothing created" {
    printf '[{"members":[]}]\n' > "$WORK/team.json"
    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN"
    [ "$status" -eq 2 ]
    assert_one_object "$output"
    [ "$(out '.error')" = "team_file_malformed" ]
    [ "$(out '.remedy | length > 0')" = "true" ]
    refute_exists "$RUN/team.json"
    refute_exists "$ROOT/r1"
}

@test "a team file naming no members is refused, exit 2, nothing created" {
    jq -n '{mode:"attached", members:[]}' > "$WORK/team.json"
    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN"
    [ "$status" -eq 2 ]
    [ "$(out '.error')" = "team_file_empty" ]
    refute_exists "$RUN/team.json"
    refute_exists "$ROOT/r1"
}

@test "a team file repeating a member name is refused, exit 2, nothing created" {
    contract_file "$WORK/c.json" out.txt
    team_file "$WORK/team.json" attached 2 "lead:alpha:$WORK/c.json" "lead:beta:$WORK/c.json"
    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN"
    [ "$status" -eq 2 ]
    [ "$(out '.error')" = "member_duplicate" ]
    refute_exists "$RUN/team.json"
    refute_exists "$ROOT/r1"
}

@test "a team file whose member has no alias or no contract is refused, exit 2" {
    contract_file "$WORK/c.json" out.txt
    jq -n --arg c "$WORK/c.json" \
        '{mode:"attached", members:[{name:"lead", contract:$c}]}' > "$WORK/team.json"
    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN"
    [ "$status" -eq 2 ]
    [ "$(out '.error')" = "member_incomplete" ]
    refute_exists "$ROOT/r1"
}

@test "a missing team file and a member name failing the grammar are both one object, exit 2" {
    dispatch --team-file "$WORK/absent.json" --run-id r1 --run-dir "$RUN"
    [ "$status" -eq 2 ]
    assert_one_object "$output"
    [ "$(out '.error')" = "team_file_unreadable" ]

    contract_file "$WORK/c.json" out.txt
    team_file "$WORK/team.json" attached 2 "../escape:alpha:$WORK/c.json"
    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN"
    [ "$status" -eq 2 ]
    assert_one_object "$output"
    [ "$(out '.error')" = "member_name_invalid" ]
    refute_exists "$ROOT/r1"
}

@test "a team file may not name a member's own path" {
    # THE DECISION (U3's handoff): a member placed outside <root>/<run-id>/<name>
    # is never torn down, so a team file — a plain file anything on the box can
    # write — does not get to choose a member's path. Placement is the surface's,
    # and everything dispatch creates is therefore removable by the record.
    contract_file "$WORK/c.json" out.txt
    jq -n --arg c "$WORK/c.json" --arg w "$WORK/elsewhere" \
        '{mode:"attached", bounds:{max_concurrent:2},
          members:[{name:"lead", alias:"alpha", contract:$c, worktree:$w}]}' > "$WORK/team.json"
    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN"
    [ "$status" -eq 2 ]
    [ "$(out '.error')" = "member_path_forbidden" ]
    [ "$(out '.remedy | length > 0')" = "true" ]
    refute_exists "$WORK/elsewhere"
    refute_exists "$ROOT/r1"
    refute_exists "$RUN/team.json"
}

@test "control: the same team file without that key is accepted and places the member itself" {
    dispatch_env "alpha"
    contract_file "$WORK/c.json" out.txt
    jq -n --arg c "$WORK/c.json" \
        '{mode:"attached", bounds:{max_concurrent:2},
          members:[{name:"lead", alias:"alpha", contract:$c}]}' > "$WORK/team.json"
    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN"
    [ "$status" -eq 0 ]
    [ "$(member_wt lead)" = "$ROOT/r1/lead" ]
}

# ---------------------------------------------------------------------------
# R31 — single-round refuses an oversized roster before it creates anything
# ---------------------------------------------------------------------------

@test "single-round refuses a roster larger than its maximum, exit 2, and no worktree exists" {
    contract_file "$WORK/c.json" out.txt
    team_file "$WORK/team.json" single-round 2 \
        "lead:alpha:$WORK/c.json" "scout:beta:$WORK/c.json" "mason:gamma:$WORK/c.json"

    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN"
    [ "$status" -eq 2 ]
    assert_one_object "$output"
    [ "$(out '.ok')" = "false" ]
    [ "$(out '.error')" = "roster_exceeds_round" ]
    # Nothing was created: single-round arms no driver, so an accepted oversized
    # roster would strand the remainder pending with nothing able to advance it.
    refute_exists "$ROOT/r1"
    refute_exists "$RUN/team.json"
    refute_exists "$RUN/team-file.json"
}

@test "roster_exceeds_round carries its own non-empty remedy, distinct from usage's" {
    contract_file "$WORK/c.json" out.txt
    team_file "$WORK/team.json" single-round 1 \
        "lead:alpha:$WORK/c.json" "scout:beta:$WORK/c.json"
    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN"
    [ "$status" -eq 2 ]
    local re; re="$(out '.remedy')"
    [ -n "$re" ]
    [ "$re" != "null" ]

    # A plain `usage` refusal to compare against. `dispatch --run-id r1` used to
    # be one, because a run id without a team file was always invalid; it is now
    # a legitimate second-round invocation, so the contrast has to come from an
    # invocation that is still genuinely a usage error.
    dispatch
    [ "$status" -eq 2 ]
    [ "$(out '.error')" = "usage" ]
    local us; us="$(out '.remedy')"
    [ -n "$us" ]
    [ "$us" != "null" ]
    [ "$re" != "$us" ]
}

@test "control: single-round at or under the maximum is accepted and dispatches its round" {
    # The control arm for the refusal above — the refusal is about the roster
    # outrunning the round, not about single-round being unsupported.
    dispatch_env "alpha,beta"
    contract_file "$WORK/c.json" out.txt
    team_file "$WORK/team.json" single-round 2 \
        "lead:alpha:$WORK/c.json" "scout:beta:$WORK/c.json"
    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN"
    [ "$status" -eq 0 ]
    [ "$(out '.dispatched')" = "2" ]
    [ "$(out '.pending')" = "0" ]
}

@test "the same roster in attached and in unattended mode both dispatch a first round" {
    dispatch_env "alpha,beta"
    contract_file "$WORK/c.json" out.txt
    team_file "$WORK/att.json" attached 1 \
        "lead:alpha:$WORK/c.json" "scout:beta:$WORK/c.json"
    dispatch --team-file "$WORK/att.json" --run-id att --run-dir "$WORK/run-att"
    [ "$status" -eq 0 ]
    [ "$(out '.mode')" = "attached" ]
    [ "$(out '.dispatched')" = "1" ]
    [ "$(out '.pending')" = "1" ]

    team_file "$WORK/un.json" unattended 1 \
        "lead:alpha:$WORK/c.json" "scout:beta:$WORK/c.json"
    dispatch --team-file "$WORK/un.json" --run-id un --run-dir "$WORK/run-un"
    [ "$status" -eq 0 ]
    [ "$(out '.mode')" = "unattended" ]
    [ "$(out '.dispatched')" = "1" ]
    [ "$(out '.pending')" = "1" ]
}

# ---------------------------------------------------------------------------
# The teardown's own invariant
# ---------------------------------------------------------------------------

work_holders() {    # pids holding $WORK in argv, this shell excluded
    local p out=""
    for p in $(pgrep -f "$WORK" 2>/dev/null); do
        [ "$p" = "$$" ] && continue
        out="${out:+$out }$p"
    done
    printf '%s' "$out"
}

work_holder_args() {
    local p
    for p in $(work_holders); do ps -o args= -p "$p" 2>/dev/null; done
}

# The arming control. The fixture gateway also carries $WORK in its argv, so
# "something matches" proves nothing — this pins a live SUPERVISOR, the process
# whose post-dispatch forking is what a single-pass sweep misses.
assert_supervisor_held() {
    if ! work_holder_args | grep -q 'spawn-bg-agent='; then
        printf 'assert_supervisor_held: no live supervisor holds %s, so the race is not armed\n' "$WORK" >&2
        work_holder_args >&2
        return 1
    fi
    return 0
}

# The window `rm -rf` needs, not a single instant. rm walks the tree over finite
# time and a writer at ANY point in that walk breaks it, so this watches rather
# than samples. It also has to: the late forks are `jobs.sh log` children that
# live tens of milliseconds — a single probe costs more than that and reports
# clean over a real violation.
refute_work_held() {
    local i h
    for i in $(seq 1 25); do
        h="$(work_holders)"
        if [ -n "$h" ]; then
            printf 'refute_work_held: pass %s — these processes still hold %s: %s\n' \
                "$i" "$WORK" "$h" >&2
            work_holder_args >&2
            return 1
        fi
        sleep 0.04
    done
    return 0
}

# A supervisor's fork burst, made deterministic. bg-agent.sh's `job_log` forks
# `bash "$JOBS" log --cwd <worktree-under-$WORK>` once per log line
# (lib/bg-agent.sh:415), so a live supervisor is a process holding $WORK that
# keeps minting further processes holding $WORK. Real dispatch reaches this
# state at an offset no test can pin; this pins it.
#
# THE PARENT ITSELF HOLDS $WORK, on purpose. A forker the sweep could not see
# would be a shape the plugin does not have, and a test built on one would prove
# nothing about it: here a sweep that reaches a genuinely clean pass has killed
# the forker too, so nothing can appear afterwards. What the burst defeats is a
# sweep that takes ONE snapshot — every child minted between that snapshot and
# the kill reaching the forker is never signalled.
#
# Children run a SCRIPT FILE rather than `bash -c "sleep 2" <name>`, because bash
# exec-optimizes the latter into a bare `sleep 2` whose argv keeps no path at all
# — measured, and it makes the child invisible to the very sweep under test.
arm_fork_burst() {
    printf 'sleep 2\n' > "$WORK/burst-child.sh"
    {
        printf 'while :; do\n'
        printf '    bash %s &\n' "$WORK/burst-child.sh"
        printf '    sleep 0.005\n'
        printf 'done\n'
    } > "$WORK/burst.sh"
    bash "$WORK/burst.sh" &
    # Let the burst reach steady state, so the sweep meets a running forker
    # rather than one that has not minted anything yet.
    sleep 0.3
}

@test "after the sweep no live process holds the run's own work root" {
    dispatch_env "alpha,beta,gamma,delta"
    contract_file "$WORK/c.json" out.txt
    team_file "$WORK/team.json" attached 4 \
        "lead:alpha:$WORK/c.json" "scout:beta:$WORK/c.json" \
        "mason:gamma:$WORK/c.json" "clerk:delta:$WORK/c.json"
    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN"
    [ "$status" -eq 0 ]

    # Await nothing. dispatch returns while the supervisors are still coming up
    # (KTD17), which is the state 37 tests in this file leave behind — and the
    # exact window in which a one-shot snapshot goes stale.
    assert_supervisor_held
    arm_fork_burst
    sweep_preamble
    sweep_work
    # Judged over the whole window `rm -rf` needs, because rm walks the tree over
    # finite time and a writer at ANY point in that walk breaks it.
    refute_work_held
}

# ---------------------------------------------------------------------------
# The contract as data
# ---------------------------------------------------------------------------

@test "--describe names the three bound flags and the team file's shape" {
    run bash -c "cd '$PRIMARY' && bash '$TEAM' --describe 2>/dev/null"
    [ "$status" -eq 0 ]
    assert_one_object "$output"
    [ "$(out '.ok')" = "true" ]
    local f
    for f in --team-file --max-concurrent --max-rounds --token-ceiling; do
        [ "$(printf '%s' "$output" | jq -r --arg f "$f" '[.flags[] | select(.name == $f)] | length')" = "1" ]
    done
    # The team file's shape, not merely its name: a caller writes this file.
    for f in mode bounds members; do
        [ "$(printf '%s' "$output" | jq -r --arg f "$f" '[.team_file_fields[] | select(.name == $f)] | length')" = "1" ]
    done
    [ "$(printf '%s' "$output" | jq -r '[.team_file_fields[] | select(.name == "members") | .member_fields[] | .name] | join(",")')" = "name,alias,contract,skills" ]
    # And it answers with no gateway and no config, as bg-agent's does.
    [ "$(out '.response_kind')" = "describe" ]
}

@test "the describe object parses under the platform's own /bin/bash, not only a newer one" {
    # bash 3.2 is the floor and it is /bin/bash here, while PATH's bash on this
    # box is 5.3. Measured: a quote sequence inside this file's longest command
    # substitution parsed one way under 5.3 and another under 3.2, and
    # --describe answered with a record_malformed refusal and a screen of jq
    # compile errors on the shell the plugin actually ships to. Every other test
    # in this file was green at the time, because they all reach team.sh through
    # PATH.
    run bash -c "cd '$PRIMARY' && /bin/bash '$TEAM' --describe 2>'$WORK/describe.err'"
    [ "$status" -eq 0 ]
    assert_one_object "$output"
    [ "$(out '.response_kind')" = "describe" ]
    # The refusal that hid this printed to stderr; an empty stderr is the part
    # that catches it whichever way the object comes out.
    [ ! -s "$WORK/describe.err" ]
}

@test "a member with no checkout is reported worktree_failed and the round dispatches the rest" {
    dispatch_env "alpha,beta"
    contract_file "$WORK/c.json" out.txt
    # lead's destination is occupied by a plain file, so it gets no checkout —
    # and a member with no checkout must be skipped by the launch loop rather
    # than launched with an empty --cwd, which bg-agent would take as the
    # dispatching process's own directory.
    mkdir -p "$ROOT/r1"
    printf 'in the way\n' > "$ROOT/r1/lead"
    team_file "$WORK/team.json" attached 2 \
        "lead:alpha:$WORK/c.json" "scout:beta:$WORK/c.json"

    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN"
    [ "$status" -eq 5 ]
    assert_one_object "$output"
    [ "$(out '.members[] | select(.name == "lead") | .error')" = "worktree_failed" ]
    [ "$(member_state lead)" = "launch_failed" ]
    # R3, measured: with that member launched anyway, bg-agent reads an empty
    # --cwd as the CALLING process's directory — which is the driver's own
    # checkout. The job was claimed there, lock and all. A job root here is the
    # signature of that.
    refute_exists "$PRIMARY/.spawn"
    [ "$(out '.dispatched')" = "1" ]
    [ "$(member_state scout)" = "dispatched" ]
    await_invocations 1
    assert_child_alias beta
    refute_child_alias alpha
}

# ===========================================================================
# U15 — `advance`: one advance, prints intent (R28, R10, R26, R6, R32, KTD4,
# KTD19).
#
# WHY THE PROBES ARE RUN FOR REAL
# -------------------------------
# The whole unit is a probe of somebody else's worktree. `jobs.sh`'s
# resolve_worktree defaults --cwd to $PWD, so a probe that omits it ANSWERS —
# about the driver's own checkout — and a test that only checked "the probe
# returned something" would pass over exactly the bug U4 measured on bg-agent's
# --cwd. So these tests dispatch real jobs into real member worktrees and read
# the answer the probe could only have got from the member's own tree.
#
# Absence is the other trap. `.delay` must be ABSENT on three intents and
# numeric on one, and `jq '.delay == null'` is true of an object with no delay
# key at all — so both directions go through has("delay").
# ===========================================================================

advance() {         # <args...> — always from inside the temp checkout
    run bash -c "cd '$PRIMARY' && bash '$TEAM' advance $* 2>/dev/null"
}

argv_count() {
    local n
    n="$(grep -c '^--- invocation' "$FAKE_CLAUDE_RECORD_DIR/argv" 2>/dev/null)" || n=0
    printf '%s' "$n"
}

member_outcome() { rec ".members[] | select(.name == \"$1\") | .outcome"; }

# A member reaches a terminal state on the supervisor's clock, not ours. This
# waits for THAT, and it asks through the member's own worktree — the same
# question the advance asks.
await_member_terminal() {   # <name> [seconds]
    local name="$1" limit="${2:-40}" h wt i s=""
    h="$(member_handle "$name")"; wt="$(member_wt "$name")"
    for i in $(seq 1 $((limit * 5))); do
        s="$(bash "$JOBS" state --handle "$h" --cwd "$wt" 2>/dev/null | jq -r '.job.state // ""')"
        case "$s" in done|degraded|failed|cancelled) return 0 ;; esac
        sleep 0.2
    done
    printf 'await_member_terminal: %s never went terminal (last: %s)\n' "$name" "$s" >&2
    return 1
}

assert_has_delay() {    # <json>
    if [ "$(printf '%s' "$1" | jq -r 'has("delay")')" != "true" ]; then
        printf 'assert_has_delay: no delay key on %s\n' "$1" >&2
        return 1
    fi
    if [ "$(printf '%s' "$1" | jq -r '.delay | type')" != "number" ]; then
        printf 'assert_has_delay: delay is not a number on %s\n' "$1" >&2
        return 1
    fi
    return 0
}

refute_has_delay() {    # <json>
    if [ "$(printf '%s' "$1" | jq -r 'has("delay")')" != "false" ]; then
        printf 'refute_has_delay: a delay key is present on %s\n' "$1" >&2
        return 1
    fi
    return 0
}

# An ISO-8601 UTC stamp N seconds in the past, in both date dialects.
iso_ago() {         # <seconds>
    local t; t=$(( $(date -u '+%s') - $1 ))
    date -u -r "$t" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
        || date -u -d "@$t" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null
}

# Hand-edit the record. The chokepoint recomputes DERIVED facts on every write
# and leaves raw ones alone, so an edited raw field is what the next advance
# reads — which is how a round's age and a member's handle are put under a
# test's control.
edit_record() {     # <jq args...> <jq program>
    local tmp="$RUN/.edited.$$"
    jq -c "$@" < "$RUN/team.json" > "$tmp" || return 1
    cat "$tmp" > "$RUN/team.json" && rm -f "$tmp"
}

# One dispatched member, hanging, so the round stays in flight.
one_hang_member() { # <roster-size>
    dispatch_env "alpha,beta"
    contract_file "$WORK/c.json" out.txt
    export FAKE_CLAUDE_MODE=hang
    if [ "${1:-1}" -gt 1 ]; then
        team_file "$WORK/team.json" attached 1 \
            "lead:alpha:$WORK/c.json" "scout:beta:$WORK/c.json"
    else
        team_file "$WORK/team.json" attached 1 "lead:alpha:$WORK/c.json"
    fi
    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN"
    [ "$status" -eq 0 ]
    [ "$(member_state lead)" = "dispatched" ]
    await_invocations 1
}

# One dispatched member that finishes, and one still pending behind it.
one_done_one_pending() {
    dispatch_env "alpha,beta"
    contract_file "$WORK/c.json" out.txt
    export FAKE_CLAUDE_WRITE=out.txt
    team_file "$WORK/team.json" attached 1 \
        "lead:alpha:$WORK/c.json" "scout:beta:$WORK/c.json"
    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN"
    [ "$status" -eq 0 ]
    [ "$(member_state lead)" = "dispatched" ]
    [ "$(member_state scout)" = "pending" ]
    await_member_terminal lead
}

# ---------------------------------------------------------------------------
# The four intents, round state first and roster state second
# ---------------------------------------------------------------------------

@test "with the round closed and members still pending, the intent is continue" {
    one_done_one_pending
    advance --run-dir "$RUN"
    [ "$status" -eq 0 ]
    assert_one_object "$output"
    [ "$(out '.ok')" = "true" ]
    [ "$(out '.intent')" = "continue" ]
    refute_has_delay "$output"
    # The advance that records the last outcome is the advance that closes the
    # round, so it must decide on the record it just WROTE.
    [ "$(member_outcome lead)" != "null" ]
    [ "$(rec '.derived.active_round')" = "null" ]
    # The outcome came from `handle.sh result` and that call answered: asked
    # from anywhere but this member's own worktree it would have refused, and
    # the refusal would be on this row.
    [ "$(out '.members[] | select(.name == "lead") | .error')" = "null" ]
    [ "$(out '.members[] | select(.name == "lead") | .outcome')" != "null" ]
}

@test "with a member of the round still running the intent is waiting, not continue" {
    one_hang_member 2
    advance --run-dir "$RUN"
    [ "$status" -eq 0 ]
    assert_one_object "$output"
    [ "$(out '.intent')" = "waiting" ]
    # R32 — undispatched members remain and it still does not say continue.
    [ "$(rec '[.members[] | select(.launch_state == "pending")] | length')" = "1" ]
    [ "$(out '.members[] | select(.name == "lead") | .state')" = "running" ]
}

@test "a bound that fires mid-round yields waiting, not stop, until the round closes" {
    # This is what "round state FIRST, roster state second" is actually for. A
    # bound firing sets `stop_reasons` while the round is still in flight, and
    # deciding roster-state-first would stop the run with members still running
    # — R6 concludes a round only when every member in it is terminal. The
    # `continue` branch alone cannot show this: the chokepoint's
    # `dispatch_allowed` already requires no active round, so swapping THAT
    # branch changes nothing and proves nothing.
    dispatch_env "alpha"
    contract_file "$WORK/c.json" out.txt
    export FAKE_CLAUDE_MODE=hang
    team_file "$WORK/team.json" attached 1 "lead:alpha:$WORK/c.json"
    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN" --max-rounds 1
    [ "$status" -eq 0 ]
    await_invocations 1
    # The bound HAS fired: one round of a one-round run is used up.
    [ "$(rec '.derived.stop_reasons | index("round_max_reached") != null')" = "true" ]

    advance --run-dir "$RUN"
    [ "$status" -eq 0 ]
    [ "$(out '.intent')" = "waiting" ]
    assert_has_delay "$output"

    # Control arm: the same run stops on that same bound once the round has
    # closed, so `waiting` above is about the round being in flight and not
    # about the bound going unread.
    local h wt pid
    h="$(member_handle lead)"; wt="$(member_wt lead)"
    pid="$(bash "$JOBS" state --handle "$h" --cwd "$wt" 2>/dev/null | jq -r '.job.pid')"
    kill -9 "$pid" 2>/dev/null
    advance --run-dir "$RUN"
    [ "$(out '.intent')" = "stop" ]
    [ "$(out '.reasons | index("round_max_reached") != null')" = "true" ]
}

@test "three advances during a live round dispatch nothing and never say continue" {
    one_hang_member 2
    local before; before="$(argv_count)"
    local i
    for i in 1 2 3; do
        advance --run-dir "$RUN"
        [ "$status" -eq 0 ]
        [ "$(out '.intent')" = "waiting" ]
    done
    # R32 measured at the boundary: the child's own argv record is what a
    # second dispatched batch would show up in.
    [ "$(argv_count)" = "$before" ]
    [ "$(member_state scout)" = "pending" ]
}

@test "a continue advance dispatches nothing either" {
    one_done_one_pending
    local before; before="$(argv_count)"
    advance --run-dir "$RUN"
    [ "$(out '.intent')" = "continue" ]
    # Dispatch belongs to U4. `continue` is the tempting case: the round is
    # closed and a member is waiting, and this verb still starts nobody.
    [ "$(argv_count)" = "$before" ]
    [ "$(member_state scout)" = "pending" ]
}

@test "a round in which every launch failed reaches a terminal intent, never waiting" {
    # A U4 defect this unit surfaced. `round` was recorded on the success path
    # and not on the failure path, so a round whose launches ALL failed had zero
    # assigned members — and the chokepoint's `($rm | length) > 0` left it
    # `running` for ever. The advance then answered `waiting` with nothing in
    # flight and nothing that could ever finish: a permanently hung driver.
    dispatch_env "alpha,beta"
    team_file "$WORK/team.json" attached 2 \
        "lead:alpha:$WORK/no-such-contract.json" "scout:beta:$WORK/also-missing.json"

    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN"
    [ "$(member_state lead)" = "launch_failed" ]
    [ "$(member_state scout)" = "launch_failed" ]
    # An attempted launch belongs to the round it was attempted in, whether or
    # not it produced a job.
    [ "$(rec '.members[] | select(.name == "lead") | .round')" = "1" ]
    [ "$(rec '.members[] | select(.name == "scout") | .round')" = "1" ]

    advance --run-dir "$RUN"
    [ "$status" -eq 0 ]
    [ "$(out '.intent')" != "waiting" ]
    [ "$(out '.intent')" = "stop" ]
    [ "$(out '.reasons | index("roster_exhausted") != null')" = "true" ]
    [ "$(rec '.rounds[0].state')" = "finished" ]
    [ "$(rec '.rounds[0].verdict')" = "fail" ]
}

@test "a round where every member lost its checkout also reaches a terminal intent" {
    # The same defect class by the other route into launch_failed. Placement
    # marks a member launch_failed before any round exists, and the launch loop
    # then skips it — so a run where NO member got a checkout had the same
    # empty round, and the same permanently hung driver.
    dispatch_env "alpha,beta"
    contract_file "$WORK/c.json" out.txt
    mkdir -p "$ROOT/r1"
    printf 'in the way\n' > "$ROOT/r1/lead"
    printf 'in the way\n' > "$ROOT/r1/scout"
    team_file "$WORK/team.json" attached 2 \
        "lead:alpha:$WORK/c.json" "scout:beta:$WORK/c.json"

    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN"
    [ "$(member_state lead)" = "launch_failed" ]
    [ "$(member_state scout)" = "launch_failed" ]
    [ "$(rec '.members[] | select(.name == "lead") | .round')" = "1" ]

    advance --run-dir "$RUN"
    [ "$status" -eq 0 ]
    [ "$(out '.intent')" = "stop" ]
    [ "$(rec '.rounds[0].state')" = "finished" ]
}

@test "control: the argv count DOES move when something really is dispatched" {
    # The control arm for the two tests above. They assert an absence — that the
    # child argv record gains no entry — and an absence proves nothing until the
    # counter is shown moving on the present case.
    one_hang_member 2
    local before; before="$(argv_count)"
    advance --run-dir "$RUN"
    [ "$(argv_count)" = "$before" ]
    # scout is still pending; dispatching it is what an advance must NOT do, and
    # what the counter registers when anything does.
    dispatch --team-file "$RUN/team-file.json" --run-id r2 --run-dir "$WORK/run2"
    await_invocations $(( before + 1 ))
    [ "$(argv_count)" -gt "$before" ]
}

@test "with no undispatched members left, the intent is stop with roster_exhausted" {
    dispatch_env "alpha"
    contract_file "$WORK/c.json" out.txt
    export FAKE_CLAUDE_WRITE=out.txt
    team_file "$WORK/team.json" attached 1 "lead:alpha:$WORK/c.json"
    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN"
    [ "$status" -eq 0 ]
    await_member_terminal lead

    advance --run-dir "$RUN"
    [ "$status" -eq 0 ]
    [ "$(out '.intent')" = "stop" ]
    [ "$(out '.reasons | index("roster_exhausted") != null')" = "true" ]
    refute_has_delay "$output"
}

@test "a single-round run dispatches everyone, and its advance says stop, not continue" {
    # U16's other half of the single-round contract. The refusal above proves an
    # oversized roster never starts; this proves the accepted case needs no
    # driver — everyone goes out in the one round, and the advance a returning
    # caller happens to make finds nothing left to dispatch rather than asking
    # for a round that mode arms nobody to run.
    dispatch_env "alpha,beta"
    contract_file "$WORK/c.json" out.txt
    export FAKE_CLAUDE_WRITE=out.txt
    team_file "$WORK/team.json" single-round 2 \
        "lead:alpha:$WORK/c.json" "scout:beta:$WORK/c.json"
    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN"
    [ "$status" -eq 0 ]
    [ "$(out '.dispatched')" = "2" ]
    [ "$(out '.pending')" = "0" ]
    [ "$(member_state lead)" = "dispatched" ]
    [ "$(member_state scout)" = "dispatched" ]
    await_member_terminal lead
    await_member_terminal scout

    advance --run-dir "$RUN"
    [ "$status" -eq 0 ]
    assert_one_object "$output"
    [ "$(out '.intent')" = "stop" ]
    [ "$(out '.reasons | index("roster_exhausted") != null')" = "true" ]
    refute_has_delay "$output"
}

@test "a member still running is probed and left running, and the advance returns" {
    one_hang_member 1
    advance --run-dir "$RUN"
    [ "$status" -eq 0 ]
    [ "$(out '.intent')" = "waiting" ]
    # Probed, not awaited: the job is still live after the advance returned.
    local h wt
    h="$(member_handle lead)"; wt="$(member_wt lead)"
    [ "$(bash "$JOBS" state --handle "$h" --cwd "$wt" 2>/dev/null | jq -r '.job.state')" = "running" ]
    [ "$(member_outcome lead)" = "null" ]
}

# ---------------------------------------------------------------------------
# The run lock
# ---------------------------------------------------------------------------

@test "an advance racing a live holder returns noop and overwrites nothing" {
    one_done_one_pending
    advance --run-dir "$RUN"
    [ "$(out '.intent')" = "continue" ]
    local sum; sum="$(cksum < "$RUN/team.json")"

    mkdir -p "$RUN/advance.lock"
    printf '%s\n' "$$" > "$RUN/advance.lock/pid"
    advance --run-dir "$RUN"
    [ "$status" -eq 0 ]
    assert_one_object "$output"
    [ "$(out '.intent')" = "noop" ]
    refute_has_delay "$output"
    # The first advance's result survives byte for byte.
    [ "$(cksum < "$RUN/team.json")" = "$sum" ]
    [ "$(member_outcome lead)" != "null" ]
    rm -rf "$RUN/advance.lock"
}

@test "a stale advance lock whose holder is gone is broken and the advance proceeds" {
    one_done_one_pending
    local dead
    sleep 0.01 & dead=$!
    wait "$dead" 2>/dev/null || true

    mkdir -p "$RUN/advance.lock"
    printf '%s\n' "$dead" > "$RUN/advance.lock/pid"
    advance --run-dir "$RUN"
    [ "$status" -eq 0 ]
    [ "$(out '.intent')" = "continue" ]
    [ "$(member_outcome lead)" != "null" ]
    # Broken and then released — a lock left behind would noop every advance
    # that followed.
    refute_exists "$RUN/advance.lock"
}

@test "control: the noop assertion fails when the holder is this test's own live pid" {
    # The control arm for the two above: it proves the lock is read at all, and
    # that `noop` is not what an advance says whatever the lock holds.
    one_done_one_pending
    mkdir -p "$RUN/advance.lock"
    printf '%s\n' "$$" > "$RUN/advance.lock/pid"
    advance --run-dir "$RUN"
    [ "$(out '.intent')" = "noop" ]
    rm -rf "$RUN/advance.lock"
    advance --run-dir "$RUN"
    [ "$(out '.intent')" != "noop" ]
}

# ---------------------------------------------------------------------------
# The delay — on `waiting` alone, clamped, and shorter as the round ages
# ---------------------------------------------------------------------------

@test "waiting carries a numeric delay inside [60, 3600]" {
    one_hang_member 1
    advance --run-dir "$RUN"
    [ "$(out '.intent')" = "waiting" ]
    assert_has_delay "$output"
    local d; d="$(out '.delay')"
    [ "$d" -ge 60 ]
    [ "$d" -le 3600 ]
}

@test "continue, stop and noop carry no delay key at all" {
    one_done_one_pending
    advance --run-dir "$RUN"
    [ "$(out '.intent')" = "continue" ]
    refute_has_delay "$output"

    mkdir -p "$RUN/advance.lock"
    printf '%s\n' "$$" > "$RUN/advance.lock/pid"
    advance --run-dir "$RUN"
    [ "$(out '.intent')" = "noop" ]
    refute_has_delay "$output"
    rm -rf "$RUN/advance.lock"

    # Roster exhausted: mark the pending member launch_failed so nothing is
    # left to dispatch, which is the stop case without a bound firing.
    edit_record '.members |= map(if .name == "scout" then .launch_state = "launch_failed" else . end)'
    advance --run-dir "$RUN"
    [ "$(out '.intent')" = "stop" ]
    refute_has_delay "$output"
}

@test "control: refute_has_delay fails on the intent that really carries one" {
    one_hang_member 1
    advance --run-dir "$RUN"
    [ "$(out '.intent')" = "waiting" ]
    run refute_has_delay "$output"
    [ "$status" -ne 0 ]
}

@test "a round that just opened waits longer than one near the child deadline" {
    one_hang_member 1
    export SPAWN_BG_TIMEOUT=4000
    advance --run-dir "$RUN"
    [ "$(out '.intent')" = "waiting" ]
    local fresh; fresh="$(out '.delay')"

    edit_record --arg t "$(iso_ago 3600)" '.rounds |= map(.opened_at = $t)'
    advance --run-dir "$RUN"
    [ "$(out '.intent')" = "waiting" ]
    local aged; aged="$(out '.delay')"

    [ "$fresh" -gt "$aged" ]
    [ "$aged" -ge 60 ]
}

@test "the delay clamps at 3600 above and at 60 below" {
    one_hang_member 1
    export SPAWN_BG_TIMEOUT=100000
    advance --run-dir "$RUN"
    [ "$(out '.delay')" = "3600" ]

    export SPAWN_BG_TIMEOUT=900
    edit_record --arg t "$(iso_ago 5000)" '.rounds |= map(.opened_at = $t)'
    advance --run-dir "$RUN"
    [ "$(out '.delay')" = "60" ]
}

# ---------------------------------------------------------------------------
# The probes: --cwd, and the three answers handle.sh gives kept distinct
# ---------------------------------------------------------------------------

@test "each probe carries --cwd for that member's own worktree" {
    dispatch_env "alpha,beta"
    contract_file "$WORK/c.json" out.txt
    export FAKE_CLAUDE_MODE=hang
    team_file "$WORK/team.json" attached 2 \
        "lead:alpha:$WORK/c.json" "scout:beta:$WORK/c.json"
    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN"
    [ "$status" -eq 0 ]
    await_invocations 2

    # THE CONTROL ARM. Each handle answers ONLY from its own member's worktree:
    # asked from the driver's checkout, or from the other member's, the same
    # handle is handle_unknown. So a `running` answer below could not have come
    # from a probe that omitted --cwd or carried the wrong one.
    local hl hs
    hl="$(member_handle lead)"; hs="$(member_handle scout)"
    [ "$(bash "$JOBS" state --handle "$hl" --cwd "$PRIMARY" 2>/dev/null | jq -r '.error')" = "handle_unknown" ]
    [ "$(bash "$JOBS" state --handle "$hl" --cwd "$(member_wt scout)" 2>/dev/null | jq -r '.error')" = "handle_unknown" ]
    [ "$(bash "$JOBS" state --handle "$hs" --cwd "$PRIMARY" 2>/dev/null | jq -r '.error')" = "handle_unknown" ]

    advance --run-dir "$RUN"
    [ "$status" -eq 0 ]
    [ "$(out '.members[] | select(.name == "lead") | .state')" = "running" ]
    [ "$(out '.members[] | select(.name == "scout") | .state')" = "running" ]
    # And the driver's own checkout was never made into a job root by a probe
    # that resolved against it.
    refute_exists "$PRIMARY/.spawn"
}

@test "a member whose recorded worktree is empty is not probed against the driver" {
    one_hang_member 1
    # An empty --cwd is not an empty argument to jobs.sh: resolve_worktree
    # falls back to $PWD, so the probe would answer about the DRIVER's tree.
    edit_record '.members |= map(.worktree = "")'
    advance --run-dir "$RUN"
    [ "$status" -eq 0 ]
    assert_one_object "$output"
    [ "$(out '.members[] | select(.name == "lead") | .error')" = "worktree_missing" ]
    refute_exists "$PRIMARY/.spawn"
}

@test "handle_unknown for one member does not abort the advance for the others" {
    dispatch_env "alpha,beta"
    contract_file "$WORK/c.json" out.txt
    export FAKE_CLAUDE_MODE=hang
    team_file "$WORK/team.json" attached 2 \
        "lead:alpha:$WORK/c.json" "scout:beta:$WORK/c.json"
    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN"
    [ "$status" -eq 0 ]
    await_invocations 2

    edit_record '.members |= map(if .name == "lead"
                                 then .handle = "job-19700101T000000Z-9999" else . end)'
    advance --run-dir "$RUN"
    [ "$status" -eq 0 ]
    assert_one_object "$output"
    [ "$(out '.members[] | select(.name == "lead") | .error')" = "handle_unknown" ]
    # Terminal, not left non-terminal: nothing can ever answer for that member
    # again, and a member that never goes terminal holds its round open for
    # ever (R6).
    [ "$(member_outcome lead)" = "failed" ]
    # The other member was still probed.
    [ "$(out '.members[] | select(.name == "scout") | .state')" = "running" ]
    [ "$(out '.members[] | select(.name == "scout") | .error')" = "null" ]
}

@test "a member whose supervisor pid is gone resolves failed, not what its file claims" {
    one_hang_member 1
    local h wt pid
    h="$(member_handle lead)"; wt="$(member_wt lead)"
    pid="$(bash "$JOBS" state --handle "$h" --cwd "$wt" 2>/dev/null | jq -r '.job.pid')"
    [ "$pid" != "null" ]
    kill -9 "$pid" 2>/dev/null
    # The status file still CLAIMS running — the thing that would have updated
    # it is the thing that was killed (KTD6).
    [ "$(jq -r '.state' < "$(member_job_dir "$h" "$wt")/status.json")" = "running" ]

    advance --run-dir "$RUN"
    [ "$status" -eq 0 ]
    [ "$(out '.members[] | select(.name == "lead") | .state')" = "failed" ]
    [ "$(member_outcome lead)" = "failed" ]
}

@test "a state of failed is an answer, not an error" {
    one_hang_member 1
    local h wt pid
    h="$(member_handle lead)"; wt="$(member_wt lead)"
    pid="$(bash "$JOBS" state --handle "$h" --cwd "$wt" 2>/dev/null | jq -r '.job.pid')"
    kill -9 "$pid" 2>/dev/null
    advance --run-dir "$RUN"
    # Exit 0, ok:true, error null — a probe that answered is a success whatever
    # it answered.
    [ "$status" -eq 0 ]
    [ "$(out '.ok')" = "true" ]
    [ "$(out '.error')" = "null" ]
    [ "$(out '.intent')" = "stop" ]
}

# ---------------------------------------------------------------------------
# U2 — a terminal non-success outcome always carries a cause (R1, R3, R4, R5)
#
# The cause lives on the member ROW, so every assertion below reads the RECORD
# through `member_failure`. The response's `error` is a PROJECTION of
# `failure.error` (KTD2), so a response-only assertion cannot tell a recorded
# cause from an unrecorded one.
# ---------------------------------------------------------------------------

member_failure() { rec ".members[] | select(.name == \"$1\") | .failure"; }

# refute_json_key <json> <key> — fails as a PLAIN command. `! jq -e` would be
# exempted from set -e by POSIX and could never redden a bats test.
refute_json_key() {
    if [ "$(printf '%s' "$1" | jq -r 'if type == "object" then has("'"$2"'") else "notobject" end' 2>/dev/null)" != "false" ]; then
        printf 'refute_json_key: %s is present on, or the input is not, %s\n' "$2" "$1" >&2
        return 1
    fi
    return 0
}

assert_json_key() {
    if [ "$(printf '%s' "$1" | jq -r 'if type == "object" then has("'"$2"'") else "notobject" end' 2>/dev/null)" != "true" ]; then
        printf 'assert_json_key: %s is absent from %s\n' "$2" "$1" >&2
        return 1
    fi
    return 0
}

# One dispatched member whose child exits 1 — the supervisor classifies that
# `failed` and writes its own account of why.
one_failing_member() {
    dispatch_env "alpha,beta"
    contract_file "$WORK/c.json" out.txt
    export FAKE_CLAUDE_MODE=fail
    team_file "$WORK/team.json" attached 1 "lead:alpha:$WORK/c.json"
    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN"
    [ "$status" -eq 0 ]
    await_invocations 1
    await_member_terminal lead
}

# One dispatched member whose child exits 0 and produces nothing the contract
# names — `degraded` (KTD8), classified by effect and not by the exit status.
one_degraded_member() {
    dispatch_env "alpha,beta"
    contract_file "$WORK/c.json" out.txt
    team_file "$WORK/team.json" attached 1 "lead:alpha:$WORK/c.json"
    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN"
    [ "$status" -eq 0 ]
    await_invocations 1
    await_member_terminal lead
}

@test "a member whose child exits non-zero records the supervisor's own account of why" {
    one_failing_member
    advance --run-dir "$RUN"
    [ "$status" -eq 0 ]
    [ "$(member_outcome lead)" = "failed" ]

    local f; f="$(member_failure lead)"
    [ "$f" != "null" ]
    [ "$(printf '%s' "$f" | jq -r '.error')" = "failed" ]
    # The supervisor's sentence, relayed verbatim — not a taxonomy this layer
    # invented.
    [ "$(printf '%s' "$f" | jq -r '.detail')" = "the child under the 'repo-bounded' ceiling exited 1, so no work is claimed" ]
    [ "$(printf '%s' "$f" | jq -r '.child_exit_code')" = "1" ]
    [ "$(printf '%s' "$f" | jq -r '.degraded_reasons | length > 0')" = "true" ]
    # KTD2: the response's error is the same value, read from the same place.
    [ "$(out '.members[] | select(.name == "lead") | .error')" = "failed" ]
}

@test "a member that reaches degraded carries a non-null cause with its reasons" {
    one_degraded_member
    advance --run-dir "$RUN"
    [ "$status" -eq 0 ]
    [ "$(member_outcome lead)" = "degraded" ]

    local f; f="$(member_failure lead)"
    [ "$f" != "null" ]
    [ "$(printf '%s' "$f" | jq -r '.error')" = "degraded" ]
    [ "$(printf '%s' "$f" | jq -r '.degraded_reasons | length > 0')" = "true" ]
    [ "$(printf '%s' "$f" | jq -r '.detail | length > 0')" = "true" ]
}

@test "the cause holds no narrative, and the absence assertion can fail" {
    one_failing_member
    advance --run-dir "$RUN"
    local f; f="$(member_failure lead)"
    # KTD3: `detail` and `degraded_reasons` are the SUPERVISOR's words. The
    # child's own account of itself is never relayed as a cause.
    refute_json_key "$f" narrative
    # The control arm: the same helper on a key that IS there must redden.
    run refute_json_key "$f" detail
    [ "$status" -ne 0 ]
    run assert_json_key "$f" narrative
    [ "$status" -ne 0 ]
    assert_json_key "$f" detail
}

@test "a member that reaches done carries a null cause" {
    one_done_one_pending
    advance --run-dir "$RUN"
    [ "$status" -eq 0 ]
    [ "$(member_outcome lead)" = "done" ]
    [ "$(member_failure lead)" = "null" ]
    [ "$(out '.members[] | select(.name == "lead") | .error')" = "null" ]
}

@test "a member still running carries a null cause" {
    one_hang_member 1
    advance --run-dir "$RUN"
    [ "$status" -eq 0 ]
    [ "$(out '.members[] | select(.name == "lead") | .state')" = "running" ]
    [ "$(member_outcome lead)" = "null" ]
    [ "$(member_failure lead)" = "null" ]
    [ "$(out '.members[] | select(.name == "lead") | .error')" = "null" ]
}

@test "handle_unknown is recorded as the cause, not only reported" {
    one_hang_member 1
    edit_record '.members |= map(if .name == "lead"
                                 then .handle = "job-19700101T000000Z-9999" else . end)'
    advance --run-dir "$RUN"
    [ "$status" -eq 0 ]
    [ "$(out '.members[] | select(.name == "lead") | .error')" = "handle_unknown" ]
    [ "$(member_outcome lead)" = "failed" ]
    [ "$(member_failure lead | jq -r '.error')" = "handle_unknown" ]
}

@test "a refused result read is recorded as the cause and the probe's own state stands" {
    one_failing_member
    local h wt jd
    h="$(member_handle lead)"; wt="$(member_wt lead)"
    jd="$(member_job_dir "$h" "$wt")"
    assert_exists "$jd/result.json"
    # The job ran and its record is no longer readable — which is not the same
    # as no answer.
    rm -f "$jd/result.json"

    advance --run-dir "$RUN"
    [ "$status" -eq 0 ]
    local f; f="$(member_failure lead)"
    [ "$f" != "null" ]
    [ "$(printf '%s' "$f" | jq -r '.error')" = "result_missing" ]
    # Nothing was read, so there is nothing to relay — absent is null, never ""
    # and never a missing key. `jq -r '.detail'` prints "null" for a key that is
    # not there at all, so PRESENCE is pinned separately from the value.
    assert_json_key "$f" detail
    assert_json_key "$f" child_exit_code
    assert_json_key "$f" degraded_reasons
    [ "$(printf '%s' "$f" | jq -r '.detail')" = "null" ]
    [ "$(printf '%s' "$f" | jq -r '.child_exit_code')" = "null" ]
    # The probe's own state is the outcome; the refusal is not an outcome.
    [ "$(member_outcome lead)" = "failed" ]
    [ "$(out '.members[] | select(.name == "lead") | .error')" = "result_missing" ]
}

@test "a member with no checkout records worktree_missing, not only reports it" {
    one_hang_member 1
    edit_record '.members |= map(.worktree = "")'
    advance --run-dir "$RUN"
    [ "$status" -eq 0 ]
    [ "$(out '.members[] | select(.name == "lead") | .error')" = "worktree_missing" ]
    [ "$(member_failure lead | jq -r '.error')" = "worktree_missing" ]
    # A missing checkout is not an outcome the supervisor reported, so the
    # member's own outcome is left alone.
    [ "$(member_outcome lead)" = "null" ]
}

@test "the cause outlives the member's worktree (R3)" {
    one_failing_member
    advance --run-dir "$RUN"
    [ "$(member_failure lead)" != "null" ]

    run bash -c "cd '$PRIMARY' && bash '$TEAM' teardown --run-dir '$RUN' 2>/dev/null"
    [ "$status" -eq 0 ]
    refute_exists "$ROOT/r1/lead"
    # Read from team.json with the checkout gone — the record is the single
    # source of truth for why a member failed.
    [ "$(member_failure lead | jq -r '.error')" = "failed" ]
    [ "$(member_failure lead | jq -r '.child_exit_code')" = "1" ]
}

# ---------------------------------------------------------------------------
# U3 — a member that never launched names its refusal in the RECORD (R2, R3)
#
# The dispatch-side twin of the section above. `TEAM_LAUNCH_ERRS` is an
# in-process accumulator that dies with the process, so a caller who reads
# `team.json` afterwards — the single source of truth — had no way to say why a
# member never started. Every assertion below reads the ROW.
# ---------------------------------------------------------------------------

@test "a launcher's refusal rides the member's row, not only the response" {
    dispatch_env "alpha,beta"
    contract_file "$WORK/c.json" out.txt
    # lead's contract does not exist, so bg-agent refuses that one launch.
    team_file "$WORK/team.json" attached 2 \
        "lead:alpha:$WORK/no-such-contract.json" "scout:beta:$WORK/c.json"

    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN"
    [ "$(member_state lead)" = "launch_failed" ]
    [ "$(member_state scout)" = "dispatched" ]

    local f; f="$(member_failure lead)"
    [ "$f" != "null" ]
    [ "$(printf '%s' "$f" | jq -r '.error')" = "contract_invalid" ]
    # The launcher's own sentence, relayed rather than re-invented here.
    [ "$(printf '%s' "$f" | jq -r '.detail | length > 0')" = "true" ]
    # A launch that never started has no child and nothing degraded. Absent is
    # null and never a missing key: `jq -r` prints "null" for both, so PRESENCE
    # is pinned apart from the value.
    assert_json_key "$f" detail
    assert_json_key "$f" child_exit_code
    assert_json_key "$f" degraded_reasons
    [ "$(printf '%s' "$f" | jq -r '.child_exit_code')" = "null" ]
    [ "$(printf '%s' "$f" | jq -r '.degraded_reasons')" = "null" ]

    # The member that DID launch carries no cause, and it is the only one that
    # does not: one failed launch marks one row.
    [ "$(member_failure scout)" = "null" ]
    [ "$(rec '[.members[] | select(.failure != null)] | length')" = "1" ]

    # KTD2 — the response's error is a projection of the same value.
    [ "$(out '.members[] | select(.name == "lead") | .error')" = "contract_invalid" ]
    [ "$(out '.members[] | select(.name == "lead") | .failure.error')" = "contract_invalid" ]
    [ "$(out '.members[] | select(.name == "scout") | .failure')" = "null" ]
}

@test "the launch refusal outlives the member's worktree (R3)" {
    dispatch_env "alpha"
    team_file "$WORK/team.json" single-round 2 "solo:alpha:$WORK/absent-contract.json"
    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN"
    [ "$(member_failure solo | jq -r '.error')" = "contract_invalid" ]

    run bash -c "cd '$PRIMARY' && bash '$TEAM' teardown --run-dir '$RUN' 2>/dev/null"
    [ "$status" -eq 0 ]
    refute_exists "$ROOT/r1/solo"
    # Read from team.json with the checkout gone.
    [ "$(member_failure solo | jq -r '.error')" = "contract_invalid" ]
}

@test "a member whose checkout could not be created records worktree_failed on its row" {
    mkdir -p "$ROOT/r1"
    printf 'in the way\n' > "$ROOT/r1/lead"
    roster --run-id r1 --run-dir "$RUN" \
        --member lead --alias sonnet --contract "$WORK/c1.md" \
        --member scout --alias haiku --contract "$WORK/c2.md"
    [ "$status" -eq 5 ]
    [ "$(member_state lead)" = "launch_failed" ]

    local f; f="$(member_failure lead)"
    [ "$f" != "null" ]
    [ "$(printf '%s' "$f" | jq -r '.error')" = "worktree_failed" ]
    assert_json_key "$f" detail
    assert_json_key "$f" child_exit_code
    assert_json_key "$f" degraded_reasons
    [ "$(member_failure scout)" = "null" ]
    [ "$(rec '[.members[] | select(.failure != null)] | length')" = "1" ]

    # The roster's response reads the row rather than asserting the cause on its
    # own, so the two can no longer disagree.
    [ "$(out '.members[] | select(.name == "lead") | .error')" = "worktree_failed" ]
    [ "$(out '.members[] | select(.name == "lead") | .failure.error')" = "worktree_failed" ]
    [ "$(out '.members[] | select(.name == "scout") | .failure')" = "null" ]
}

@test "a checkout that vanished between rounds records worktree_failed on its row" {
    dispatch_env "alpha"
    contract_file "$WORK/c.json" out.txt
    team_file "$WORK/team.json" attached 1 \
        "lead:alpha:$WORK/c.json" "scout:alpha:$WORK/c.json"

    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN"
    [ "$status" -eq 0 ]
    [ "$(member_state scout)" = "pending" ]
    [ "$(member_failure scout)" = "null" ]

    # Round 2 places nothing, so a checkout lost between rounds is caught by the
    # revalidation and nowhere else.
    rm -rf "$(member_wt scout)"
    dispatch --run-id r1 --run-dir "$RUN"
    [ "$status" -eq 5 ]
    [ "$(member_state scout)" = "launch_failed" ]
    [ "$(member_failure scout | jq -r '.error')" = "worktree_failed" ]
    [ "$(out '.members[] | select(.name == "scout") | .error')" = "worktree_failed" ]
    [ "$(out '.members[] | select(.name == "scout") | .failure.error')" = "worktree_failed" ]
    # lead launched in round 1, and another member's lost checkout is not its
    # cause.
    [ "$(member_failure lead)" = "null" ]
}

# ---------------------------------------------------------------------------
# Persist before signal, and the envelope
# ---------------------------------------------------------------------------

@test "the record is written before the intent is printed" {
    one_done_one_pending
    # stdout CLOSED, so every write to it fails. The record must already carry
    # the advance: a crash between the write and the print leaves a consistent
    # record, and a missing successor is detectable.
    run bash -c "cd '$PRIMARY' && bash '$TEAM' advance --run-dir '$RUN' >&- 2>/dev/null"
    [ "$(member_outcome lead)" != "null" ]
    [ "$(rec '.rounds[0].state')" = "finished" ]
}

@test "the intent is exactly one JSON object in the standard envelope" {
    one_done_one_pending
    advance --run-dir "$RUN"
    assert_one_object "$output"
    [ "$(out 'has("schema")')" = "true" ]
    [ "$(out 'has("intent")')" = "true" ]
    [ "$(out 'has("reasons")')" = "true" ]
    [ "$(out '.exit_code')" = "0" ]
    [ "$(out '.run_id')" = "r1" ]
    [ "$(out '.mode')" = "attached" ]
}

@test "advance on a run that has no record is one JSON object, exit 2" {
    run bash -c "cd '$PRIMARY' && bash '$TEAM' advance --run-dir '$WORK/nothing' 2>/dev/null"
    [ "$status" -eq 2 ]
    assert_one_object "$output"
    [ "$(printf '%s' "$output" | jq -r '.ok')" = "false" ]
    [ "$(printf '%s' "$output" | jq -r '.error')" = "record_missing" ]
    [ "$(printf '%s' "$output" | jq -r '.remedy | length > 0')" = "true" ]
}

@test "teardown on a run that has no record says record_missing, not internal" {
    # The same wart as the advance case above, in the verb next door, and it is
    # not cosmetic: the remedy table is keyed on the error value, so `internal`
    # hands a human "this is a plugin bug" where the truth is "your run
    # directory has no record, and here is how to clean up by hand".
    run bash -c "cd '$PRIMARY' && bash '$TEAM' teardown --run-dir '$WORK/nothing' 2>/dev/null"
    [ "$status" -eq 2 ]
    assert_one_object "$output"
    [ "$(printf '%s' "$output" | jq -r '.error')" = "record_missing" ]
    [ "$(printf '%s' "$output" | jq -r '.remedy | length > 0')" = "true" ]
    [ "$(printf '%s' "$output" | jq -r '.remedy')" != "$(printf '%s' "$output" | jq -r '.detail')" ]
}

@test "control: a run dir whose record is unreadable says record_malformed" {
    # The control arm: it proves the two cases are told apart, not that one
    # value was hardcoded over the other.
    mkdir -p "$RUN"
    printf '{"not":"a run record"}\n' > "$RUN/team.json"
    run bash -c "cd '$PRIMARY' && bash '$TEAM' teardown --run-dir '$RUN' 2>/dev/null"
    [ "$status" -eq 2 ]
    [ "$(printf '%s' "$output" | jq -r '.error')" = "record_malformed" ]
    run bash -c "cd '$PRIMARY' && bash '$TEAM' advance --run-dir '$RUN' 2>/dev/null"
    [ "$status" -eq 2 ]
    [ "$(printf '%s' "$output" | jq -r '.error')" = "record_malformed" ]
}

@test "advance takes the run id the dispatch minted, without a run dir" {
    dispatch_env "alpha"
    contract_file "$WORK/c.json" out.txt
    export FAKE_CLAUDE_MODE=hang
    team_file "$WORK/team.json" attached 1 "lead:alpha:$WORK/c.json"
    dispatch --team-file "$WORK/team.json" --run-id r1
    [ "$status" -eq 0 ]
    local dir; dir="$(out '.run_dir')"
    advance --run-id r1
    [ "$status" -eq 0 ]
    [ "$(out '.intent')" = "waiting" ]
    [ "$(out '.run_dir')" = "$dir" ]
}

@test "--describe names advance and all three modes" {
    run bash -c "bash '$TEAM' --describe 2>/dev/null"
    [ "$status" -eq 0 ]
    assert_one_object "$output"
    [ "$(printf '%s' "$output" | jq -r '[.verbs[].name] | index("advance") != null')" = "true" ]
    [ "$(printf '%s' "$output" | jq -r '[.modes[].name] | sort | join(",")')" = "attached,single-round,unattended" ]
    [ "$(printf '%s' "$output" | jq -r '[.intents[].name] | sort | join(",")')" = "continue,noop,stop,waiting" ]
    [ "$(printf '%s' "$output" | jq -r '.intents[] | select(.name == "waiting") | .delay != null')" = "true" ]
}

@test "the describe object still parses under the platform's own /bin/bash" {
    # U4 found --describe completely broken on bash 3.2 while the whole suite
    # was green, because every other test reaches the script through PATH's
    # bash 5. Empty stderr is the assertion, not just a parseable object.
    run bash -c "/bin/bash '$TEAM' --describe 2>'$WORK/describe.err'"
    [ "$status" -eq 0 ]
    assert_one_object "$output"
    [ "$(printf '%s' "$output" | jq -r '[.verbs[].name] | index("advance") != null')" = "true" ]
    [ ! -s "$WORK/describe.err" ]
}

# ===========================================================================
# U13 — bounds and stop reasons (R18, R19, R21, R30, KTD14, KTD20)
#
# THE PLURAL CASE IS THE POINT. One scalar cannot carry two reasons, and an
# `elif` chain over the conditions reads as correct on every run where exactly
# one fires — which is nearly all of them. The two-together test below is the
# only one that can tell those apart, so it is written first and the mutation
# check aims at it.
#
# TOKENS COME FROM THE FIXTURE, NOT FROM A CONSTANT HERE. fake-claude.sh
# reports usage {input:11, output:7} on its ok path, so a member that runs to
# `done` costs 18. Ceilings below are chosen against that number: 10 is crossed
# by one member, 100000 by none.
# ===========================================================================

FIXTURE_MEMBER_TOKENS=18

# A pattern that must NOT be in a child's argv record, as a plain command.
refute_in_argv() {  # <extended-regex> <file>
    if grep -qiE "$1" "$2"; then
        printf 'refute_in_argv: /%s/ reached a child argv:\n%s\n' "$1" "$(cat "$2")" >&2
        return 1
    fi
    return 0
}

# Rewrite a JSON file in place. `cat >`, never cp/mv: both are aliased
# interactive on some operators' boxes and silently decline to overwrite.
edit_json() {       # <file> <jq program>
    local f="$1" tmp="$1.edit.$$"
    jq -c "$2" < "$f" > "$tmp" || return 1
    cat "$tmp" > "$f" && rm -f "$tmp"
}

# The seven words the enumerated no-spend lint forbids, as a plain command so a
# `!` prefix cannot exempt it from failing the test.
refute_spend_words() {  # <file>
    local hits
    hits="$(sed 's/#.*//' "$1" | grep -inE 'spend|budget|cost|quota|dollar|usd|price')" || return 0
    printf 'refute_spend_words: %s carries forbidden words:\n%s\n' "$1" "$hits" >&2
    return 1
}

# One member, run to completion, under a stated ceiling. Returns with the
# member terminal and NOT yet advanced, so the caller owns the first advance.
one_member_run() {  # <ceiling|""> [extra dispatch args...]
    local ceiling="$1"; shift
    dispatch_env "alpha"
    contract_file "$WORK/c.json" out.txt
    export FAKE_CLAUDE_WRITE=out.txt
    TEAM_FILE_CEILING="$ceiling" team_file "$WORK/team.json" attached 1 "lead:alpha:$WORK/c.json"
    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN" "$@"
    [ "$status" -eq 0 ]
    await_member_terminal lead
}

# --- R18 / R21: which bound fired, and roster exhaustion is not one ---------

@test "a roster that empties before the round maximum stops exhausted, not out of rounds" {
    one_member_run ""
    advance --run-dir "$RUN"
    [ "$status" -eq 0 ]
    assert_one_object "$output"
    [ "$(out '.intent')" = "stop" ]
    [ "$(out '.reasons | index("roster_exhausted") != null')" = "true" ]
    [ "$(out '.reasons | index("round_max_reached")')" = "null" ]
    # R21's distinguishability: this run FINISHED its work. A bound firing is
    # the case that must not read the same way, and the next test is that case.
    [ "$(out 'has("complete")')" = "true" ]
    [ "$(out '.complete')" = "true" ]
}

@test "a run out of rounds with members still undispatched does not read as success" {
    dispatch_env "alpha,beta"
    contract_file "$WORK/c.json" out.txt
    export FAKE_CLAUDE_WRITE=out.txt
    team_file "$WORK/team.json" attached 1 \
        "lead:alpha:$WORK/c.json" "scout:beta:$WORK/c.json"
    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN" --max-rounds 1
    [ "$status" -eq 0 ]
    await_member_terminal lead

    advance --run-dir "$RUN"
    [ "$status" -eq 0 ]
    [ "$(out '.intent')" = "stop" ]
    [ "$(out '.reasons | index("round_max_reached") != null')" = "true" ]
    # scout never ran, so the roster is NOT exhausted and the run is not done.
    [ "$(member_state scout)" = "pending" ]
    [ "$(out '.reasons | index("roster_exhausted")')" = "null" ]
    [ "$(out '.complete')" = "false" ]
}

@test "a stop always names at least one reason" {
    # `stop` with an empty reasons list is the shape R21 forbids: the driver is
    # told to halt and given nothing to report. Both stop paths are covered.
    one_member_run ""
    advance --run-dir "$RUN"
    [ "$(out '.intent')" = "stop" ]
    [ "$(out '.reasons | length > 0')" = "true" ]
}

# --- R19: the token ceiling -------------------------------------------------

@test "a run whose tokens cross the ceiling stops with the ceiling reason" {
    dispatch_env "alpha,beta"
    contract_file "$WORK/c.json" out.txt
    export FAKE_CLAUDE_WRITE=out.txt
    TEAM_FILE_CEILING=10 team_file "$WORK/team.json" attached 1 \
        "lead:alpha:$WORK/c.json" "scout:beta:$WORK/c.json"
    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN"
    [ "$status" -eq 0 ]
    await_member_terminal lead

    advance --run-dir "$RUN"
    [ "$status" -eq 0 ]
    # The tokens reached the RECORD, not merely the job: a ceiling read off a
    # total nothing ever writes to would sit at zero and never fire.
    [ "$(rec '.members[] | select(.name == "lead") | .tokens.input')" = "11" ]
    [ "$(rec '.members[] | select(.name == "lead") | .tokens.output')" = "7" ]
    [ "$(rec '.derived.tokens_used')" = "$FIXTURE_MEMBER_TOKENS" ]
    [ "$(out '.intent')" = "stop" ]
    [ "$(out '.reasons | index("token_ceiling_reached") != null')" = "true" ]
    [ "$(out '.complete')" = "false" ]
    [ "$(out '.ceiling_state')" = "reached" ]
    # Not the unmeasured reason: this member WAS measured.
    [ "$(out '.reasons | index("usage_unknown")')" = "null" ]
    [ "$(out '.members_unmeasured')" = "0" ]
}

@test "control: the same run under a ceiling nothing crosses continues" {
    # The control arm for the ceiling. Without it, `token_ceiling_reached` could
    # be a reason this surface reports unconditionally.
    dispatch_env "alpha,beta"
    contract_file "$WORK/c.json" out.txt
    export FAKE_CLAUDE_WRITE=out.txt
    TEAM_FILE_CEILING=100000 team_file "$WORK/team.json" attached 1 \
        "lead:alpha:$WORK/c.json" "scout:beta:$WORK/c.json"
    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN"
    [ "$status" -eq 0 ]
    await_member_terminal lead
    advance --run-dir "$RUN"
    [ "$(out '.intent')" = "continue" ]
    [ "$(out '.reasons | index("token_ceiling_reached")')" = "null" ]
    [ "$(out '.ceiling_state')" = "within" ]
}

@test "no ceiling given means no token bound and no token stop reason" {
    # KTD20 — absent is absent. The member spends real tokens and nothing
    # anywhere treats that as approaching a limit.
    one_member_run ""
    advance --run-dir "$RUN"
    [ "$(rec '.derived.tokens_used')" = "$FIXTURE_MEMBER_TOKENS" ]
    [ "$(out '.reasons | index("token_ceiling_reached")')" = "null" ]
    [ "$(out '.reasons | index("usage_unknown")')" = "null" ]
    [ "$(out '.ceiling_state')" = "none" ]
    # `tokens_remaining` is null rather than a number, and the key is PRESENT:
    # `.x == null` would have been true on day zero of this field.
    [ "$(rec '.derived.bounds | has("tokens_remaining")')" = "true" ]
    [ "$(rec '.derived.bounds.tokens_remaining')" = "null" ]
}

# --- R21: two conditions in the same interval -------------------------------

@test "two conditions firing in the same interval are BOTH listed" {
    # THE `elif` TEST. One member, one round allowed, and a ceiling that member
    # crosses on its own — so `round_max_reached` and `token_ceiling_reached`
    # are true at the same write. A chain that reports the first condition it
    # checks passes every other test in this file and fails only this one.
    one_member_run 10 --max-rounds 1
    advance --run-dir "$RUN"
    [ "$status" -eq 0 ]
    [ "$(out '.intent')" = "stop" ]
    [ "$(out '.reasons | index("round_max_reached") != null')" = "true" ]
    [ "$(out '.reasons | index("token_ceiling_reached") != null')" = "true" ]
    [ "$(out '.reasons | length >= 2')" = "true" ]
    # And the record says the same thing the response does — the reasons are
    # derived at the chokepoint, not assembled by the surface (KTD18).
    [ "$(rec '.derived.stop_reasons | index("round_max_reached") != null')" = "true" ]
    [ "$(rec '.derived.stop_reasons | index("token_ceiling_reached") != null')" = "true" ]
}

@test "control: each of those two conditions can fire alone" {
    # The arm that makes the plural test mean something. If both reasons were
    # reported on every run, the test above would pass while the surface said
    # nothing. Here the ceiling is out of reach and only the round bound fires.
    one_member_run 100000 --max-rounds 1
    advance --run-dir "$RUN"
    [ "$(out '.reasons | index("round_max_reached") != null')" = "true" ]
    [ "$(out '.reasons | index("token_ceiling_reached")')" = "null" ]
}

# --- R19: between rounds only ------------------------------------------------

@test "a crossed ceiling does not stop a round already in flight" {
    # The ceiling governs whether MORE calls happen. A round already dispatched
    # is committed, so it runs to its terminal state and the ceiling overshoots
    # — accepted, and asserted here so it cannot quietly become a mid-round
    # abort.
    one_hang_member 2
    edit_record '(.members[] | select(.name == "lead") | .tokens.input) = 900
                 | .bounds.token_ceiling = 10'
    advance --run-dir "$RUN"
    [ "$status" -eq 0 ]
    [ "$(rec '.derived.stop_reasons | index("token_ceiling_reached") != null')" = "true" ]
    [ "$(out '.intent')" = "waiting" ]
    assert_has_delay "$output"

    # Control arm: once the round closes, that same crossed ceiling stops the
    # run — so `waiting` above is about the round being in flight, not about the
    # ceiling going unread.
    local h wt pid
    h="$(member_handle lead)"; wt="$(member_wt lead)"
    pid="$(bash "$JOBS" state --handle "$h" --cwd "$wt" 2>/dev/null | jq -r '.job.pid')"
    kill -9 "$pid" 2>/dev/null
    advance --run-dir "$RUN"
    [ "$(out '.intent')" = "stop" ]
    [ "$(out '.reasons | index("token_ceiling_reached") != null')" = "true" ]
}

# --- R30: unmeasured usage ---------------------------------------------------

@test "a completed member with no counts is unmeasured, and stops the loop" {
    # Unknown is not zero. Treated as zero the bound is advisory while
    # presenting as active, which is the failure R30 names.
    dispatch_env "alpha,beta"
    contract_file "$WORK/c.json" out.txt
    export FAKE_CLAUDE_WRITE=out.txt
    TEAM_FILE_CEILING=100000 team_file "$WORK/team.json" attached 1 \
        "lead:alpha:$WORK/c.json" "scout:beta:$WORK/c.json"
    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN"
    [ "$status" -eq 0 ]
    await_member_terminal lead
    advance --run-dir "$RUN"
    [ "$(out '.intent')" = "continue" ]
    [ "$(out '.members_unmeasured')" = "0" ]

    # The same run with that member's measurement taken away.
    edit_record '(.members[] | select(.name == "lead") | .tokens)
                 = {input:null, output:null}'
    advance --run-dir "$RUN"
    [ "$(out '.intent')" = "stop" ]
    [ "$(out '.reasons | index("usage_unknown") != null')" = "true" ]
    [ "$(out 'has("members_unmeasured")')" = "true" ]
    [ "$(out '.members_unmeasured')" = "1" ]
}

@test "a wholly unmeasured team reports the ceiling unenforceable, not satisfied" {
    one_member_run 100000
    advance --run-dir "$RUN"
    [ "$(out '.ceiling_state')" = "within" ]

    edit_record '(.members[] | select(.name == "lead") | .tokens)
                 = {input:null, output:null}'
    advance --run-dir "$RUN"
    # "within" would read as satisfied — a ceiling honoured. Nothing was
    # measured, so nothing can be said about it.
    [ "$(out '.ceiling_state')" = "unenforceable" ]
    [ "$(out '.members_unmeasured')" = "1" ]
}

@test "a launch that never ran leaves the ceiling enforceable" {
    # The distinction U14 drew and this unit must not undo: a launch that never
    # happened cannot have spent a token, so it is zero BY CONSTRUCTION and not
    # an absent measurement. Conflating them halts a run on one bad worktree.
    dispatch_env "alpha"
    TEAM_FILE_CEILING=100000 team_file "$WORK/team.json" attached 1 \
        "lead:alpha:$WORK/no-such-contract.json"
    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN"
    [ "$(member_state lead)" = "launch_failed" ]
    advance --run-dir "$RUN"
    [ "$(out '.members_unmeasured')" = "0" ]
    [ "$(out '.reasons | index("usage_unknown")')" = "null" ]
    [ "$(out '.ceiling_state')" = "within" ]
}

# --- KTD20: a ceiling of zero is a refusal, not "no ceiling" -----------------

@test "a ceiling of zero on the flag is refused at launch, and creates nothing" {
    dispatch_env "alpha"
    contract_file "$WORK/c.json" out.txt
    team_file "$WORK/team.json" attached 1 "lead:alpha:$WORK/c.json"
    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN" --token-ceiling 0
    [ "$status" -eq 2 ]
    assert_one_object "$output"
    [ "$(out '.ok')" = "false" ]
    [ "$(out '.error')" = "token_ceiling_zero" ]
    [ "$(out '.remedy | length > 0')" = "true" ]
    refute_exists "$RUN/team.json"
    refute_exists "$ROOT/r1"
}

@test "a ceiling of zero stated in the team file is refused the same way" {
    dispatch_env "alpha"
    contract_file "$WORK/c.json" out.txt
    TEAM_FILE_CEILING=0 team_file "$WORK/team.json" attached 1 "lead:alpha:$WORK/c.json"
    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN"
    [ "$status" -eq 2 ]
    [ "$(out '.error')" = "token_ceiling_zero" ]
    refute_exists "$RUN/team.json"
}

@test "control: a ceiling of one is accepted, and an absent ceiling is accepted" {
    # Both control arms for the refusal above: it is about the VALUE zero and
    # not about a ceiling being stated, nor about one being omitted.
    dispatch_env "alpha"
    contract_file "$WORK/c.json" out.txt
    export FAKE_CLAUDE_MODE=hang
    team_file "$WORK/team.json" attached 1 "lead:alpha:$WORK/c.json"
    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN" --token-ceiling 1
    [ "$status" -eq 0 ]
    [ "$(rec '.bounds.token_ceiling')" = "1" ]

    dispatch --team-file "$WORK/team.json" --run-id r2 --run-dir "$WORK/run2"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.bounds.token_ceiling' < "$WORK/run2/team.json")" = "0" ]
}

# --- KTD14: nothing is passed down to a call --------------------------------

@test "no ceiling value reaches a child's argv" {
    # KTD14. The team's ceiling governs whether MORE calls happen; it is never
    # applied to one. Measured at the boundary the child itself writes — a
    # launcher-side assertion cannot see what actually crossed.
    dispatch_env "alpha"
    contract_file "$WORK/c.json" out.txt
    export FAKE_CLAUDE_MODE=hang
    team_file "$WORK/team.json" attached 1 "lead:alpha:$WORK/c.json"
    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN" --token-ceiling 99991
    [ "$status" -eq 0 ]
    await_invocations 1

    local argv="$FAKE_CLAUDE_RECORD_DIR/argv"
    refute_in_argv 99991 "$argv"
    refute_in_argv 'token[-_]?ceiling|max[-_]?tokens|token[-_]?limit' "$argv"
    # Control arm: this record IS readable and DOES carry this run's argv, so
    # the two absences above are absences and not an unread file.
    assert_child_alias alpha
}

# --- the no-spend lint over every team lib, by GLOB ---------------------------

@test "no team lib carries a forbidden spend word" {
    # GLOBBED, not enumerated. Named, this covered team.sh and team-record.sh
    # and silently missed team-view.sh — 326 lines added in the same branch —
    # because a list only covers what someone remembered to add. Every gate in
    # this repo that globs has auto-enrolled new code and caught real defects;
    # every gate that enumerates has been quietly incomplete at least once.
    local f n=0
    for f in "$LIB"/team*.sh; do
        [ -f "$f" ] || continue
        refute_spend_words "$f"
        n=$(( n + 1 ))
    done
    # A glob that matches nothing passes every assertion inside it.
    [ "$n" -ge 3 ]
}

@test "control: the spend-word check fails on a file that has one" {
    mkdir -p "$WORK/plant"
    cat "$LIB/team.sh" > "$WORK/plant/team.sh"
    printf 'BUDGET_LIMIT=3\n' >> "$WORK/plant/team.sh"
    run refute_spend_words "$WORK/plant/team.sh"
    [ "$status" -ne 0 ]
}

@test "an empty roster is not a finished run" {
    # The guard on `roster_exhausted`: "no member is pending" is true of a
    # record with no members at all, and without the count check a run whose
    # roster is empty reports itself complete having done nothing.
    one_member_run ""
    edit_record '.members = []'
    advance --run-dir "$RUN"
    [ "$status" -eq 0 ]
    [ "$(out '.reasons | index("roster_exhausted")')" = "null" ]
    [ "$(out '.complete')" = "false" ]
}

@test "a result record whose counts are not numbers leaves the member unmeasured" {
    # The job's result record is a FILE, and the counts are read from it rather
    # than computed here. A string arriving where a number belongs must record
    # as absent — propagated it would either abort the advance at `tonumber` or
    # put a string into the total the ceiling is read against.
    one_member_run 100000
    local rf
    rf="$(member_job_dir "$(member_handle lead)" "$(member_wt lead)")/result.json"
    assert_exists "$rf"
    edit_json "$rf" '.usage = {input_tokens:"lots", output_tokens:"more"}'

    advance --run-dir "$RUN"
    [ "$status" -eq 0 ]
    assert_one_object "$output"
    [ "$(rec '.members[] | select(.name == "lead") | .tokens.input')" = "null" ]
    [ "$(out '.members_unmeasured')" = "1" ]
    [ "$(out '.ceiling_state')" = "unenforceable" ]
}

@test "a run with a member still in flight is not complete" {
    # The case a pending-based `complete` gets wrong: a dispatched member is
    # not pending either, so "nobody is pending" reads true in the middle of a
    # live round and the driver is told the run finished while a member runs.
    one_hang_member 1
    advance --run-dir "$RUN"
    [ "$status" -eq 0 ]
    [ "$(out '.intent')" = "waiting" ]
    [ "$(out 'has("complete")')" = "true" ]
    [ "$(out '.complete')" = "false" ]
}

@test "a roster that empties on its last permitted round is still complete" {
    # The other half. A bound firing does not make a finished roster unfinished
    # — the reasons list says which bounds were touched, and `complete` says
    # whether any member was left unrun.
    one_member_run 10 --max-rounds 1
    advance --run-dir "$RUN"
    [ "$(out '.intent')" = "stop" ]
    [ "$(out '.reasons | length >= 2')" = "true" ]
    [ "$(out '.complete')" = "true" ]
}

@test "control: the argv check fails when the ceiling really is in there" {
    # The control arm for the two absences above. An absence proves nothing
    # until the check is shown failing on the present case — and a grep over a
    # file that was never written is indistinguishable from a clean one.
    dispatch_env "alpha"
    contract_file "$WORK/c.json" out.txt
    export FAKE_CLAUDE_MODE=hang
    team_file "$WORK/team.json" attached 1 "lead:alpha:$WORK/c.json"
    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN" --token-ceiling 99991
    [ "$status" -eq 0 ]
    await_invocations 1

    local planted="$WORK/argv.planted"
    cat "$FAKE_CLAUDE_RECORD_DIR/argv" > "$planted"
    printf -- '--token-ceiling\n99991\n' >> "$planted"
    run refute_in_argv 99991 "$planted"
    [ "$status" -ne 0 ]
    run refute_in_argv 'token[-_]?ceiling|max[-_]?tokens|token[-_]?limit' "$planted"
    [ "$status" -ne 0 ]
}

@test "the roster verb refuses a stated ceiling of zero too" {
    # The other boundary a ceiling value arrives at. `dispatch` reads the team
    # file, `roster` takes flags, and a check on only one of them leaves a run
    # that can still be started with a bound nobody can satisfy.
    roster --run-id r1 --run-dir "$RUN" --token-ceiling 0 \
        --member lead --alias sonnet --contract "$WORK/c1.md"
    [ "$status" -eq 2 ]
    assert_one_object "$output"
    [ "$(out '.error')" = "token_ceiling_zero" ]
    [ "$(out '.remedy | length > 0')" = "true" ]
    refute_exists "$RUN/team.json"
    refute_exists "$ROOT/r1"
}

@test "control: the roster verb accepts a positive ceiling and an absent one" {
    roster --run-id r1 --run-dir "$RUN" --token-ceiling 5000 \
        --member lead --alias sonnet --contract "$WORK/c1.md"
    [ "$status" -eq 0 ]
    [ "$(rec '.bounds.token_ceiling')" = "5000" ]

    roster --run-id r2 --run-dir "$WORK/run2" \
        --member lead --alias sonnet --contract "$WORK/c1.md"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.bounds.token_ceiling' < "$WORK/run2/team.json")" = "0" ]
}

@test "a garbage count in a result file makes no noise about a member that is fine" {
    # The other half of the non-numeric case. The counts are read from a file,
    # and a string arriving there must be dropped where it is read — pushed on
    # to the record layer it is refused there instead, and every advance over
    # that member then complains on stderr about a member nothing is wrong with.
    one_member_run 100000
    local rf
    rf="$(member_job_dir "$(member_handle lead)" "$(member_wt lead)")/result.json"
    edit_json "$rf" '.usage = {input_tokens:"lots", output_tokens:"more"}'

    run bash -c "cd '$PRIMARY' && bash '$TEAM' advance --run-dir '$RUN' 2>'$WORK/adv.err'"
    [ "$status" -eq 0 ]
    [ "$(rec '.members[] | select(.name == "lead") | .tokens.input')" = "null" ]
    if [ -s "$WORK/adv.err" ]; then
        printf 'the advance complained about a member that is fine:\n%s\n' "$(cat "$WORK/adv.err")" >&2
        return 1
    fi
}

# ===========================================================================
# U7 / R9 — the cross-writer channels
#
# Two halves. A member cannot recruit another process to satisfy its contract,
# and the driver cannot contaminate a member's measurement.
#
# THE ASSERTION THIS SUITE MAY NOT MAKE. A DENY-rule refusal leaves NO entry in
# the child's permission_denials[] — the array is empty despite refused
# attempts. An assertion on a denial entry would therefore pass whether or not
# the rule existed. Every assertion below is on an EFFECT: a file that is or is
# not there, or the settings path actually handed to a child.
#
# The enforcement itself belongs to the real CLI, not to this plugin, so the
# arms that measure a refusal live in ceilings.bats behind SPAWN_CEILING_LIVE.
# What is provable here without spend is that a member is handed the bounding
# file at all, scoped to its own checkout — and the whole of the second half.
# ===========================================================================

refute_file_match() {   # <pattern> <file>
    if grep -qF -- "$1" "$2"; then
        printf 'refute_file_match: unexpected match for %s in %s\n' "$1" "$2" >&2
        grep -nF -- "$1" "$2" >&2
        return 1
    fi
    return 0
}

# Every file under a worktree, content-addressed. `.git` is a FILE in a linked
# worktree rather than a directory, so the exclusion matches both shapes. The
# job root is left IN: whether a change under it is expected is the caller's
# judgement, not the snapshot's.
snapshot_tree() {       # <worktree> <outfile>
    ( cd "$1" && find . -type f -not -path './.git' -not -path './.git/*' \
        -exec shasum {} + 2>/dev/null | sort -k2 ) > "$2"
}

# The paths that changed between two snapshots and are NOT the member's own
# work — its job root, or a path the caller names as a contracted deliverable.
# Prints one path per line; empty output is the property U7 asserts.
foreign_changes() {     # <before> <after> <deliverable>...
    local before="$1" after="$2"; shift 2
    local path keep d
    diff "$before" "$after" | sed -n 's/^[<>] *[0-9a-f]*  *//p' | sort -u | while read -r path; do
        case "$path" in ./.spawn/*|./.spawn) continue ;; esac
        keep=1
        for d in "$@"; do
            [ "$path" = "./$d" ] && keep=0
        done
        [ "$keep" -eq 1 ] && printf '%s\n' "$path"
    done
}

# ---------------------------------------------------------------------------
# First half — a member cannot recruit another process
# ---------------------------------------------------------------------------

@test "U7/R9: each member's child is handed a ceiling that denies the shell, scoped to its own checkout" {
    # The rendered-file test in ceilings.bats proves the FILE is right. This
    # proves a team member sits under it: the path on the child's own argv, not
    # a path this test went looking for.
    dispatch_env "alpha,beta"
    contract_file "$WORK/c.json" out.txt
    export FAKE_CLAUDE_MODE=hang
    team_file "$WORK/team.json" attached 2 \
        "lead:alpha:$WORK/c.json" "scout:beta:$WORK/c.json"
    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN"
    [ "$status" -eq 0 ]
    await_invocations 2

    local lead_wt scout_wt name wt other s
    lead_wt="$(member_wt lead)"
    scout_wt="$(member_wt scout)"
    [ -n "$lead_wt" ] && [ -n "$scout_wt" ] && [ "$lead_wt" != "$scout_wt" ]

    # PER MEMBER NAME, not per invocation index. An earlier draft walked the argv
    # log positionally and asserted only that each settings file scoped SOME one
    # member — which stays green if two members' checkouts are swapped, since
    # every file is still internally consistent. The record's own row is what
    # ties a name to a checkout, so that is what each file is checked against.
    for name in lead scout; do
        wt="$(member_wt "$name")"
        other="$scout_wt"; [ "$name" = "scout" ] && other="$lead_wt"

        # Asked through the member's OWN recorded checkout: a job whose
        # directory is not under the checkout its row names cannot answer here.
        s="$(member_job_dir "$(member_handle "$name")" "$wt")/ceiling.settings.json"
        assert_exists "$s"
        # ...and that same file really reached a child, off the fixture's own
        # argv log. Without this the test would only prove a file was written.
        awk '/^--settings$/{getline; print}' "$FAKE_CLAUDE_RECORD_DIR/argv" > "$WORK/settings.seen"
        grep -qxF -- "$s" "$WORK/settings.seen"

        # The shell entry, on the file the child was actually given.
        jq -e '.permissions.deny | index("Bash")' "$s" >/dev/null
        jq -r '.permissions.allow[]' "$s" > "$WORK/allow.$name"
        # Scoped to this member's own checkout...
        grep -qF "Write(//${wt#/}/**)" "$WORK/allow.$name"
        # ...and to neither the other member's nor the driver's. Either would be
        # a cross-writer channel: one member over another's deliverable, or a
        # member over the driver's record.
        refute_file_match "${other#/}/**" "$WORK/allow.$name"
        refute_file_match "Write(//${PRIMARY#/}/**)" "$WORK/allow.$name"
        refute_file_match "Edit(//${PRIMARY#/}/**)" "$WORK/allow.$name"
    done
}

@test "U7: a member whose child recorded no denial at all still classifies done" {
    # Deny leaves permission_denials[] EMPTY, so an empty array cannot be read as
    # "nothing was refused" — and must not block a member from being judged on
    # its deliverables.
    #
    # THIS PINS THE CLASSIFIER, NOT THE CEILING, and the distinction matters.
    # Under the fake CLI nothing is ever refused, so the empty array here is the
    # fixture's resting state rather than a deny rule's effect. What is proven is
    # that an empty array plus satisfied deliverables reaches `done` — which is
    # the half a deny-refused member depends on. That a deny rule actually
    # produces the empty array is measured live, in ceilings.bats, not here.
    one_done_one_pending
    local h wt res
    h="$(member_handle lead)"; wt="$(member_wt lead)"
    res="$(bash "$JOBS" state --handle "$h" --cwd "$wt" 2>/dev/null)"
    [ "$(printf '%s' "$res" | jq -r '.job.state')" = "done" ]
    # The empty array is the measured shape, asserted so a future fixture change
    # that starts populating it does not quietly turn this into a different test.
    [ "$(printf '%s' "$res" | jq -r '[.job.result.permission_denials[]?] | length')" = "0" ]
    advance --run-dir "$RUN"
    [ "$status" -eq 0 ]
    [ "$(member_outcome lead)" = "done" ]
}

# ---------------------------------------------------------------------------
# Second half — the driver cannot contaminate a member's measurement
# ---------------------------------------------------------------------------

@test "U7/R9: the driver writes no file into a member's checkout between dispatch and terminal" {
    one_done_one_pending
    local wt; wt="$(member_wt lead)"
    snapshot_tree "$wt" "$WORK/snap.a"
    # The driver's own work across the window: an advance probes every member and
    # writes the record. If any of that lands in a member's checkout, it lands
    # here.
    advance --run-dir "$RUN"
    [ "$status" -eq 0 ]
    snapshot_tree "$wt" "$WORK/snap.b"

    foreign_changes "$WORK/snap.a" "$WORK/snap.b" out.txt > "$WORK/foreign"
    if [ -s "$WORK/foreign" ]; then
        printf 'the driver wrote into %s:\n' "$wt" >&2
        cat "$WORK/foreign" >&2
        return 1
    fi
}

@test "control: a planted write into a member's checkout IS caught by the same snapshot" {
    # Without this arm the test above is satisfied by a driver that does nothing
    # at all, and by a snapshot that cannot see anything.
    one_done_one_pending
    local wt; wt="$(member_wt lead)"
    snapshot_tree "$wt" "$WORK/snap.a"
    printf 'driver was here\n' > "$wt/driver-note.txt"
    advance --run-dir "$RUN"
    [ "$status" -eq 0 ]
    snapshot_tree "$wt" "$WORK/snap.b"

    foreign_changes "$WORK/snap.a" "$WORK/snap.b" out.txt > "$WORK/foreign"
    [ -s "$WORK/foreign" ]
    grep -qxF './driver-note.txt' "$WORK/foreign"
    # And the allowances are real allowances, not a filter that passes
    # everything: the deliverable and the job root did NOT show up beside it.
    refute_file_match './out.txt' "$WORK/foreign"
    refute_file_match './.spawn/' "$WORK/foreign"
}

@test "U7: the driver's record and logs are under the driver's own checkout, never a member's" {
    # NO --run-dir. Every other test in this suite pins the run dir so it can
    # read the record; that override is exactly what this property must not be
    # measured through, because it would prove the flag works and say nothing
    # about where the driver puts its own record when nobody tells it.
    dispatch_env "alpha,beta"
    contract_file "$WORK/c.json" out.txt
    export FAKE_CLAUDE_WRITE=out.txt
    team_file "$WORK/team.json" attached 1 \
        "lead:alpha:$WORK/c.json" "scout:beta:$WORK/c.json"
    dispatch --team-file "$WORK/team.json" --run-id r1
    [ "$status" -eq 0 ]

    local rd wt
    rd="$(out '.run_dir')"
    [ -n "$rd" ] && [ "$rd" != "null" ]
    assert_exists "$rd/team.json"
    # Under the driver's checkout...
    case "$rd" in "$PRIMARY"/*) : ;; *) printf 'run dir %s is not under the driver %s\n' "$rd" "$PRIMARY" >&2; return 1 ;; esac
    # ...and OUTSIDE the worktree root entirely. This line exists because a
    # mutation moving the record to `$WT_ROOT/.spawn` left the check above green:
    # the worktree root is under the driver, so "under the driver" alone does not
    # keep the record out of the one directory every member's checkout is created
    # and torn down inside.
    case "$rd" in "$ROOT"/*|"$ROOT") printf 'run dir %s is inside the worktree root %s\n' "$rd" "$ROOT" >&2; return 1 ;; esac
    # ...and under NONE of the members'. Checked per member, so a run dir that
    # drifted into one member's tree names that member. Read from the record the
    # driver actually wrote, since this test did not choose where that is.
    for wt in $(jq -r '.members[].worktree // empty' "$rd/team.json"); do
        [ -n "$wt" ] && [ "$wt" != "null" ] || continue
        case "$rd" in "$wt"/*) printf 'run dir %s is inside member checkout %s\n' "$rd" "$wt" >&2; return 1 ;; esac
    done
}

# KTD2 — a response's `error` is a PROJECTION of the row's cause, so the two can
# never disagree. The accumulator behind it holds only THIS process's launch
# errors, so a member that failed in an EARLIER round read as error:null beside
# a non-null failure: the response denied a cause the record was holding.
#
# Three members and a concurrency of one, because a launch that FAILS consumes
# no slot — with two members the first round swallows both and there is no
# second round to test.
@test "a member that failed to launch in an earlier round still names its cause in a later round's response" {
    dispatch_env "alpha,beta"
    contract_file "$WORK/c.json" out.txt
    team_file "$WORK/team.json" attached 1 \
        "lead:alpha:$WORK/no-such-contract.json" \
        "scout:beta:$WORK/c.json" \
        "third:alpha:$WORK/c.json"

    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN" --max-concurrent 1
    [ "$(member_state lead)" = "launch_failed" ]
    [ "$(member_failure lead | jq -r '.error')" = "contract_invalid" ]

    dispatch --run-id r1 --run-dir "$RUN" --max-concurrent 1
    assert_one_object "$output"
    [ "$(out '.ok')" = "true" ]
    [ "$(out '.members[] | select(.name == "lead") | .failure.error')" = "contract_invalid" ]
    [ "$(out '.members[] | select(.name == "lead") | .error')" = "contract_invalid" ]
}

# ---------------------------------------------------------------------------
# U4 — the advance response lists EVERY member of the run (R6, R7)
#
# The response's member list was built from this call's probes alone, and the
# probe loop selects only members with a null outcome. So a member that settled
# on an earlier advance vanished from every later response: a run reporting
# `dispatched: 3` listed ONE member, and a reader could not tell "not reported"
# from "not run". The record holds all three, so the response is built from the
# record after the write and the probe supplies only this call's answers.
# ---------------------------------------------------------------------------

# Two members that finish in round 1, and a third dispatched in round 2 under a
# caller-chosen mode. The advance under test is the SECOND one: by then lead and
# scout are settled, and the probe loop looks at nobody but the third member.
two_settled_then_one() {    # <mode for the third member>
    dispatch_env "alpha,beta,gamma"
    contract_file "$WORK/c.json" out.txt
    export FAKE_CLAUDE_WRITE=out.txt
    team_file "$WORK/team.json" attached 2 \
        "lead:alpha:$WORK/c.json" "scout:beta:$WORK/c.json" "mason:gamma:$WORK/c.json"
    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN"
    [ "$status" -eq 0 ]
    [ "$(member_state mason)" = "pending" ]
    await_invocations 2
    await_member_terminal lead
    await_member_terminal scout

    advance --run-dir "$RUN"
    [ "$status" -eq 0 ]
    [ "$(out '.intent')" = "continue" ]
    [ "$(member_outcome lead)" = "done" ]
    [ "$(member_outcome scout)" = "done" ]

    unset FAKE_CLAUDE_WRITE
    export FAKE_CLAUDE_MODE="$1"
    dispatch --run-id r1 --run-dir "$RUN"
    [ "$status" -eq 0 ]
    [ "$(member_state mason)" = "dispatched" ]
    await_invocations 3
}

@test "the second advance lists every member of the run, not only the ones it probed" {
    two_settled_then_one fail
    await_member_terminal mason
    advance --run-dir "$RUN"
    [ "$status" -eq 0 ]
    assert_one_object "$output"
    [ "$(out '.members | length')" = "3" ]
    [ "$(out '[.members[].name] | sort | join(",")')" = "lead,mason,scout"  ]
    # The two settled members carry the outcome the record holds, from a call
    # that probed neither of them.
    [ "$(out '.members[] | select(.name == "lead") | .outcome')" = "done" ]
    [ "$(out '.members[] | select(.name == "scout") | .outcome')" = "done" ]
    [ "$(out '.members[] | select(.name == "mason") | .outcome')" = "failed" ]
}

@test "the failed member's row carries the whole cause, not only an error string" {
    two_settled_then_one fail
    await_member_terminal mason
    advance --run-dir "$RUN"
    [ "$status" -eq 0 ]
    local row
    row="$(printf '%s' "$output" | jq -c '.members[] | select(.name == "mason")')"
    assert_json_key "$row" failure
    [ "$(printf '%s' "$row" | jq -r '.error')" = "failed" ]
    [ "$(printf '%s' "$row" | jq -r '.failure.error')" = "failed" ]
    # AE1 — the supervisor's own sentence reaches the operator's screen. An
    # error value alone does not carry it.
    [ "$(printf '%s' "$row" | jq -r '.failure.detail | length > 0')" = "true" ]
    [ "$(printf '%s' "$row" | jq -r '.failure.child_exit_code')" = "1" ]
    # A member that came back with work carries a null cause, and the key is
    # there to be read.
    local ok_row
    ok_row="$(printf '%s' "$output" | jq -c '.members[] | select(.name == "lead")')"
    assert_json_key "$ok_row" failure
    [ "$(printf '%s' "$ok_row" | jq -r '.failure')" = "null" ]
}

@test "the member list and the run's own verdict describe the same run" {
    two_settled_then_one fail
    await_member_terminal mason
    advance --run-dir "$RUN"
    [ "$status" -eq 0 ]
    # R7 — `mixed` must be readable as two successes and one failure from the
    # response alone.
    [ "$(rec '.derived.verdict')" = "mixed" ]
    [ "$(out '[.members[] | select(.outcome == "done")] | length')" = "2" ]
    [ "$(out '[.members[] | select(.outcome != null and .outcome != "done")] | length')" = "1" ]
    [ "$(out '[.members[] | select(.outcome != null and .outcome != "done" and .error != null)] | length')" = "1" ]
}

@test "the response's dispatched count equals the rows that say dispatched" {
    two_settled_then_one fail
    await_member_terminal mason
    advance --run-dir "$RUN"
    [ "$status" -eq 0 ]
    # The live shape this unit closes: a count of 3 beside a list of 1.
    [ "$(out '.dispatched')" = "3" ]
    [ "$(out '[.members[] | select(.launch_state == "dispatched")] | length')" = "3" ]
}

@test "a member still in flight reports its live state beside members the record settled" {
    two_settled_then_one hang
    advance --run-dir "$RUN"
    [ "$status" -eq 0 ]
    [ "$(out '.intent')" = "waiting" ]
    [ "$(out '.members | length')" = "3" ]
    local row
    row="$(printf '%s' "$output" | jq -c '.members[] | select(.name == "mason")')"
    # The probe answers for the member it probed, and the record answers for the
    # two it did not.
    [ "$(printf '%s' "$row" | jq -r '.state')" = "running" ]
    assert_json_key "$row" outcome
    [ "$(printf '%s' "$row" | jq -r '.outcome')" = "null" ]
    [ "$(out '.members[] | select(.name == "lead") | .outcome')" = "done" ]
    [ "$(out '.members[] | select(.name == "scout") | .outcome')" = "done" ]
}

@test "every row carries the same fields, probed this call or not" {
    two_settled_then_one hang
    advance --run-dir "$RUN"
    [ "$status" -eq 0 ]
    # R6 — a reader must not be able to tell "not reported" from "not run" by
    # the shape of a row.
    [ "$(out '[.members[] | keys_unsorted | join(",")] | unique | length')" = "1" ]
    [ "$(out '.members[0] | keys_unsorted | sort | join(",")')" = "error,failure,launch_state,name,outcome,served_model,state,tokens" ]
}

@test "a member that never launched appears in the advance response with its cause" {
    dispatch_env "alpha,beta"
    contract_file "$WORK/c.json" out.txt
    export FAKE_CLAUDE_MODE=hang
    team_file "$WORK/team.json" attached 2 \
        "lead:alpha:$WORK/no-such-contract.json" "scout:beta:$WORK/c.json"
    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN"
    [ "$(member_state lead)" = "launch_failed" ]
    [ "$(member_state scout)" = "dispatched" ]
    await_invocations 1

    advance --run-dir "$RUN"
    [ "$status" -eq 0 ]
    [ "$(out '.members | length')" = "2" ]
    # A launch that failed is never probed — its row comes from the record or
    # from nowhere.
    [ "$(out '.members[] | select(.name == "lead") | .launch_state')" = "launch_failed" ]
    [ "$(out '.members[] | select(.name == "lead") | .error')" = "contract_invalid" ]
    [ "$(out '.members[] | select(.name == "lead") | .failure.error')" = "contract_invalid" ]
}

# ===========================================================================
# U5 — retry one failed member in place (R8, R9, R10, KTD6, KTD7, KTD8)
#
# A retried member takes `retry_pending`, a launch_state of its own. Flipping it
# back to `pending` would make a member on its second attempt indistinguishable
# from one never tried, and the retired attempt is what the ceiling and the
# closed round are still counted from.
# ===========================================================================

tr_() { bash -c '. "$1"; shift; "$@"' _ "$LIB/team-record.sh" "$@"; }

retry() {           # <args...> — always from inside the temp checkout
    run bash -c "cd '$PRIMARY' && bash '$TEAM' retry $* 2>/dev/null"
}

# A run whose one dispatched member spent tokens and failed. Built through the
# record rather than a child, so the refusal tests do not need a gateway.
seed_failed_run() {     # [max-rounds] [ceiling]
    contract_file "$WORK/c.json" out.txt
    roster --run-id r1 --run-dir "$RUN" \
        --member lead --alias alpha --contract "$WORK/c.json" \
        --member scout --alias beta --contract "$WORK/c.json"
    [ "$status" -eq 0 ]
    tr_ spawn::team_round_open "$RUN"
    tr_ spawn::team_member_set "$RUN" scout round 1
    tr_ spawn::team_member_set "$RUN" scout launch_state dispatched
    tr_ spawn::team_member_set "$RUN" scout tokens_input 10
    tr_ spawn::team_member_set "$RUN" scout tokens_output 5
    tr_ spawn::team_member_set "$RUN" scout outcome done
    tr_ spawn::team_member_set "$RUN" lead round 1
    tr_ spawn::team_member_set "$RUN" lead launch_state dispatched
    tr_ spawn::team_member_set "$RUN" lead handle job-20260818T101500Z-9
    tr_ spawn::team_member_set "$RUN" lead tokens_input 100
    tr_ spawn::team_member_set "$RUN" lead tokens_output 50
    tr_ spawn::team_member_set "$RUN" lead failure \
        '{"kind":"contract_unmet","detail":"no verdict","source":"supervisor"}'
    tr_ spawn::team_member_set "$RUN" lead outcome failed
}

@test "retry returns a failed member to the roster and keeps the attempt it replaces" {
    seed_failed_run
    retry --run-id r1 --run-dir "$RUN" --member lead
    [ "$status" -eq 0 ]
    assert_one_object "$output"
    [ "$(out '.ok')" = "true" ]
    [ "$(out '.error')" = "null" ]

    [ "$(member_state lead)" = "retry_pending" ]
    [ "$(member_outcome lead)" = "null" ]
    [ "$(rec '.members[] | select(.name == "lead") | .attempts | length')" = "1" ]
    [ "$(rec '.members[] | select(.name == "lead") | .attempts[0].failure.kind')" = "contract_unmet" ]
    # R9 — the round it failed in stays closed, with its verdict.
    [ "$(rec '.rounds[0].state')" = "finished" ]
    [ "$(rec '.rounds[0].verdict')" = "mixed" ]
    # KTD8 — the retired spend is still on the run.
    [ "$(rec '.derived.tokens_used')" = "165" ]
    [ "$(member_state scout)" = "dispatched" ]
}

@test "every response counts a member waiting to retry as pending" {
    seed_failed_run
    retry --run-id r1 --run-dir "$RUN" --member lead
    [ "$status" -eq 0 ]
    [ "$(out '.pending')" = "1" ]

    run bash -c "cd '$PRIMARY' && bash '$TEAM' status --run-id r1 --run-dir '$RUN' 2>/dev/null"
    [ "$status" -eq 0 ]
    [ "$(out '.pending')" = "1" ]

    advance --run-id r1 --run-dir "$RUN"
    [ "$status" -eq 0 ]
    [ "$(out '.pending')" = "1" ]
    # The roster is not exhausted, so the run has somewhere to go.
    [ "$(out '.intent')" = "continue" ]
    [ "$(out '.reasons | index("roster_exhausted")')" = "null" ]
}

@test "retry on a member that finished is refused, and the record is unchanged" {
    seed_failed_run
    local before; before="$(cat "$RUN/team.json")"

    retry --run-id r1 --run-dir "$RUN" --member scout
    [ "$status" -eq 2 ]
    [ "$(out '.error')" = "member_not_failed" ]
    [ "$(out '.remedy | length > 0')" = "true" ]
    [ "$(cat "$RUN/team.json")" = "$before" ]
}

@test "retry on a member still in flight is refused" {
    seed_failed_run
    tr_ spawn::team_member_set "$RUN" scout outcome null
    local before; before="$(cat "$RUN/team.json")"

    retry --run-id r1 --run-dir "$RUN" --member scout
    [ "$status" -eq 2 ]
    [ "$(out '.error')" = "member_not_failed" ]
    [ "$(cat "$RUN/team.json")" = "$before" ]
}

@test "retry on a member this run does not have is refused" {
    seed_failed_run
    local before; before="$(cat "$RUN/team.json")"

    retry --run-id r1 --run-dir "$RUN" --member ghost
    [ "$status" -eq 2 ]
    [ "$(out '.error')" = "member_unknown" ]
    [ "$(cat "$RUN/team.json")" = "$before" ]
}

@test "retry names the member it wants" {
    seed_failed_run
    retry --run-id r1 --run-dir "$RUN"
    [ "$status" -eq 2 ]
    [ "$(out '.error')" = "usage" ]
    [ "$(out '.detail | test("--member")')" = "true" ]
}

@test "retry is refused once the round maximum has fired" {
    seed_failed_run
    tr_ spawn::team_round_open "$RUN"
    tr_ spawn::team_round_open "$RUN"
    [ "$(rec '.derived.stop_reasons | index("round_max_reached")')" != "null" ]
    local before; before="$(cat "$RUN/team.json")"

    retry --run-id r1 --run-dir "$RUN" --member lead
    [ "$status" -eq 2 ]
    [ "$(out '.error')" = "run_bound_reached" ]
    [ "$(out '.detail | test("round_max_reached")')" = "true" ]
    [ "$(cat "$RUN/team.json")" = "$before" ]
}

# usage_unknown is a BOUND, not a roster fact: dispatch_allowed requires the
# bound set empty, so a run holding it can never open the round a retry needs.
# An enumerated pair of bounds let this one through, and retry answered ok while
# parking the member at retry_pending for ever. A member that ran and reported
# no counts holds it true, which is exactly a member somebody wants to retry.
@test "retry is refused while an unmeasured attempt blocks every dispatch" {
    contract_file "$WORK/c.json" out.txt
    roster --run-id r9 --run-dir "$RUN" --token-ceiling 100000 \
        --member lead --alias alpha --contract "$WORK/c.json"
    [ "$status" -eq 0 ]
    tr_ spawn::team_round_open "$RUN"
    tr_ spawn::team_member_set "$RUN" lead round 1
    tr_ spawn::team_member_set "$RUN" lead launch_state dispatched
    # Terminal, and it reported NO counts — usage_unknown, not the ceiling.
    tr_ spawn::team_member_set "$RUN" lead outcome failed
    [ "$(rec '.derived.stop_reasons | index("usage_unknown") != null')" = "true" ]
    [ "$(rec '.derived.stop_reasons | index("token_ceiling_reached")')" = "null" ]
    [ "$(rec '.derived.dispatch_allowed')" = "false" ]
    local before; before="$(cat "$RUN/team.json")"

    retry --run-id r9 --run-dir "$RUN" --member lead
    [ "$status" -eq 2 ]
    [ "$(out '.error')" = "run_bound_reached" ]
    [ "$(out '.detail | test("usage_unknown")')" = "true" ]
    [ "$(cat "$RUN/team.json")" = "$before" ]
}

@test "retry is refused once the token ceiling has been reached" {
    contract_file "$WORK/c.json" out.txt
    roster --run-id r2 --run-dir "$RUN" --token-ceiling 120 \
        --member lead --alias alpha --contract "$WORK/c.json"
    [ "$status" -eq 0 ]
    tr_ spawn::team_round_open "$RUN"
    tr_ spawn::team_member_set "$RUN" lead round 1
    tr_ spawn::team_member_set "$RUN" lead launch_state dispatched
    tr_ spawn::team_member_set "$RUN" lead tokens_input 100
    tr_ spawn::team_member_set "$RUN" lead tokens_output 50
    tr_ spawn::team_member_set "$RUN" lead outcome failed
    [ "$(rec '.derived.ceiling_state')" = "reached" ]
    local before; before="$(cat "$RUN/team.json")"

    retry --run-id r2 --run-dir "$RUN" --member lead
    [ "$status" -eq 2 ]
    [ "$(out '.error')" = "run_bound_reached" ]
    [ "$(out '.detail | test("token_ceiling_reached")')" = "true" ]
    [ "$(cat "$RUN/team.json")" = "$before" ]
}

@test "retry waits for an advance holding the run lock rather than interleaving" {
    seed_failed_run
    # A live holder: this shell's own pid, which team_lock_take probes with
    # kill -0 and finds alive.
    mkdir -p "$RUN/advance.lock"
    printf '%s\n' "$$" > "$RUN/advance.lock/pid"

    bash -c "cd '$PRIMARY' && bash '$TEAM' retry --run-id r1 --run-dir '$RUN' --member lead >'$WORK/retry.out' 2>/dev/null" &
    local pid=$!
    sleep 1
    # Still held: the rotation has not been applied behind the lock.
    [ "$(member_state lead)" = "dispatched" ]
    rm -rf "$RUN/advance.lock"
    wait "$pid"

    [ "$(member_state lead)" = "retry_pending" ]
    [ "$(member_outcome lead)" = "null" ]
    [ "$(jq -r '.ok' < "$WORK/retry.out")" = "true" ]
}

@test "retry gives up rather than waiting for ever on a lock nobody releases" {
    seed_failed_run
    mkdir -p "$RUN/advance.lock"
    printf '%s\n' "$$" > "$RUN/advance.lock/pid"

    export SPAWN_TEAM_RETRY_LOCK_WAIT=1
    retry --run-id r1 --run-dir "$RUN" --member lead
    [ "$status" -eq 2 ]
    [ "$(out '.error')" = "run_busy" ]
    [ "$(member_state lead)" = "dispatched" ]
}

@test "the next round dispatches the retried member, and only it" {
    dispatch_env "alpha,beta"
    contract_file "$WORK/c.json" out.txt
    team_file "$WORK/team.json" attached 2 \
        "lead:alpha:$WORK/absent.json" "scout:beta:$WORK/c.json"

    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN"
    # lead names a contract that is not there, so its launcher refuses it and
    # the round goes on without it (R5).
    [ "$(member_state lead)" = "launch_failed" ]
    [ "$(member_state scout)" = "dispatched" ]
    await_member_terminal scout
    advance --run-id r1 --run-dir "$RUN"
    [ "$(rec '.rounds[0].state')" = "finished" ]

    # The contract arrives, and the operator retries that one member.
    contract_file "$WORK/absent.json" out.txt
    retry --run-id r1 --run-dir "$RUN" --member lead
    [ "$status" -eq 0 ]
    [ "$(member_state lead)" = "retry_pending" ]

    local before; before="$(argv_count)"
    dispatch --run-id r1 --run-dir "$RUN"
    [ "$status" -eq 0 ]
    # `dispatched` counts every member in that launch_state, scout included —
    # the round-2 roster is read off the record instead.
    [ "$(member_state lead)" = "dispatched" ]
    [ "$(rec '.members[] | select(.name == "lead") | .round')" = "2" ]
    # R10 — the second attempt is an ordinary round against the run's bounds.
    [ "$(rec '.derived.bounds.rounds_used')" = "2" ]
    await_invocations $(( before + 1 ))
    assert_child_alias alpha
    # EXACTLY one more child, and round 2 holds exactly one member: scout is
    # done and was not re-dispatched. (beta already appears in the argv from
    # round 1, so its absence is not what proves this.)
    [ "$(argv_count)" = "$(( before + 1 ))" ]
    [ "$(rec '.rounds[1].members | join(",")')" = "lead" ]
}

@test "the dispatch response counts a member held back at retry_pending as pending" {
    dispatch_env "alpha,beta"
    contract_file "$WORK/c.json" out.txt
    roster --run-id r1 --run-dir "$RUN" --max-concurrent 1 \
        --member lead --alias alpha --contract "$WORK/c.json" \
        --member scout --alias beta --contract "$WORK/c.json"
    [ "$status" -eq 0 ]
    tr_ spawn::team_round_open "$RUN"
    local m
    for m in lead scout; do
        tr_ spawn::team_member_set "$RUN" "$m" round 1
        tr_ spawn::team_member_set "$RUN" "$m" launch_state dispatched
        tr_ spawn::team_member_set "$RUN" "$m" tokens_input 10
        tr_ spawn::team_member_set "$RUN" "$m" tokens_output 5
        tr_ spawn::team_member_set "$RUN" "$m" outcome failed
        retry --run-id r1 --run-dir "$RUN" --member "$m"
        [ "$status" -eq 0 ]
    done
    team_file "$RUN/team-file.json" attached 1 \
        "lead:alpha:$WORK/c.json" "scout:beta:$WORK/c.json"

    dispatch --run-id r1 --run-dir "$RUN"
    [ "$status" -eq 0 ]
    [ "$(out '.dispatched')" = "1" ]
    # The member the concurrency maximum held back is still waiting to retry,
    # and a response reporting `pending: 0` beside it would read as a run with
    # nowhere left to go.
    [ "$(out '.pending')" = "1" ]
}

# ---------------------------------------------------------------------------
# U9 — a member's output is attributed to the model that SERVED it (R15-R17)
#
# The incident: four members were rejected with unrecognized_model by Claude
# Code's own SDK-path validation, and one of them produced its deliverable
# anyway — the child had fallen back to a default model. Its terminal state was
# `done`, so the record carried a byline no model in the roster wrote.
#
# The requested alias proves nothing. The child's own modelUsage receipt is
# keyed by the served model id, and that key is the only attribution the
# envelope holds (KTD10).
# ---------------------------------------------------------------------------

member_served() { rec ".members[] | select(.name == \"$1\") | .served_model"; }

# One dispatched member that satisfies its contract — so `done` is what it would
# reach on any ground other than the served model — with the child's receipt
# under the test's control.
one_member_serving() {  # <modelUsage JSON|"">
    dispatch_env "alpha,beta"
    contract_file "$WORK/c.json" out.txt
    export FAKE_CLAUDE_WRITE=out.txt
    [ -z "$1" ] || export FAKE_CLAUDE_MODEL_USAGE="$1"
    team_file "$WORK/team.json" attached 1 "lead:alpha:$WORK/c.json"
    dispatch --team-file "$WORK/team.json" --run-id r1 --run-dir "$RUN"
    [ "$status" -eq 0 ]
    await_invocations 1
    await_member_terminal lead
}

# An EMPTY modelUsage is the shape that broke this: to_entries yields [], .[0]
# on that is jq null, and `jq -r` prints it as the four-character string "null".
# That is non-empty, so the substitution gate read it as a model differing from
# the alias and degraded a job for a mismatch that never happened — a served
# model nothing measured, in the record, tripping a gate. Absent stays null.
@test "an empty modelUsage records no served model and degrades nothing" {
    one_member_serving '{}'
    advance --run-dir "$RUN"
    [ "$status" -eq 0 ]
    [ "$(member_served lead)" = "null" ]
    [ "$(member_outcome lead)" = "done" ]
    [ "$(member_failure lead)" = "null" ]
}

@test "a member served by a model other than its alias is degraded and names both" {
    one_member_serving '{"impostor-model":{"canonicalModel":"impostor-model","provider":"firstParty"}}'
    advance --run-dir "$RUN"
    [ "$status" -eq 0 ]
    # Every other signal says done: the deliverable is there and changed, the
    # ceiling refused nothing, no verification ran. Only the substitution is
    # left to decide this, so a green here cannot come from another cause.
    [ "$(member_outcome lead)" = "degraded" ]
    [ "$(member_served lead)" = "impostor-model" ]

    local f; f="$(member_failure lead)"
    [ "$f" != "null" ]
    [ "$(printf '%s' "$f" | jq -r '.error')" = "degraded" ]
    # BOTH names, so a reader can see what was asked for beside what answered.
    [ "$(printf '%s' "$f" | jq -r '[.degraded_reasons[] | select(test("alpha"))] | length > 0')" = "true" ]
    [ "$(printf '%s' "$f" | jq -r '[.degraded_reasons[] | select(test("impostor-model"))] | length > 0')" = "true" ]
}

@test "a member served by the model it asked for records it and is not degraded" {
    one_member_serving '{"alpha":{"canonicalModel":"alpha","provider":"firstParty"}}'
    advance --run-dir "$RUN"
    [ "$status" -eq 0 ]
    [ "$(member_outcome lead)" = "done" ]
    [ "$(member_served lead)" = "alpha" ]
    [ "$(member_failure lead)" = "null" ]
}

@test "a child that reports no modelUsage leaves served_model null, not the alias" {
    one_member_serving ""
    advance --run-dir "$RUN"
    [ "$status" -eq 0 ]
    # Unknown is not a mismatch, so nothing is degraded by it (KTD4).
    [ "$(member_outcome lead)" = "done" ]
    [ "$(member_served lead)" = "null" ]
    # `jq -r` prints "null" for a key measured null AND for one never written,
    # so PRESENCE is pinned apart from the value.
    assert_json_key "$(rec ".members[] | select(.name == \"lead\")")" served_model
    [ "$(member_failure lead)" = "null" ]
}

@test "several modelUsage keys resolve to the first one, not the first sorted" {
    # zeta is first in document order and last in sorted order: a read that
    # sorted would answer alpha-decoy, which is also the requested alias, so a
    # sorting read would additionally report a match that did not happen.
    one_member_serving '{"zeta-served":{"canonicalModel":"zeta-served"},"alpha-decoy":{"canonicalModel":"alpha-decoy"}}'
    advance --run-dir "$RUN"
    [ "$status" -eq 0 ]
    [ "$(member_served lead)" = "zeta-served" ]
    [ "$(member_outcome lead)" = "degraded" ]
}

@test "the served model reaches the advance response's member entry" {
    one_member_serving '{"impostor-model":{"canonicalModel":"impostor-model"}}'
    advance --run-dir "$RUN"
    [ "$status" -eq 0 ]
    [ "$(out '.members[] | select(.name == "lead") | .served_model')" = "impostor-model" ]
    assert_json_key "$(out '.members[] | select(.name == "lead")' | jq -c .)" served_model
}

@test "the served model outlives the member's worktree, like the cause" {
    one_member_serving '{"impostor-model":{"canonicalModel":"impostor-model"}}'
    advance --run-dir "$RUN"
    [ "$(member_served lead)" = "impostor-model" ]

    run bash -c "cd '$PRIMARY' && bash '$TEAM' teardown --run-dir '$RUN' 2>/dev/null"
    [ "$status" -eq 0 ]
    refute_exists "$ROOT/r1/lead"
    [ "$(member_served lead)" = "impostor-model" ]
}

@test "a member degraded by substitution still carries its cause (R1)" {
    one_member_serving '{"impostor-model":{"canonicalModel":"impostor-model"}}'
    advance --run-dir "$RUN"
    local f; f="$(member_failure lead)"
    # The two mechanisms do not mask each other: the substitution is what made
    # this degraded, and the cause U2 writes is still whole.
    [ "$f" != "null" ]
    assert_json_key "$f" detail
    assert_json_key "$f" child_exit_code
    assert_json_key "$f" degraded_reasons
    [ "$(printf '%s' "$f" | jq -r '.detail | length > 0')" = "true" ]
    [ "$(printf '%s' "$f" | jq -r '.child_exit_code')" = "0" ]
    [ "$(out '.members[] | select(.name == "lead") | .error')" = "degraded" ]
}

@test "the entry's canonicalModel is preferred over the key it sits under" {
    # The key and the canonical id are not always the same string — the receipt
    # names both, and canonicalModel is the one that identifies the model rather
    # than the route it was reached by.
    one_member_serving '{"gateway-alias-key":{"canonicalModel":"real-served-id","provider":"firstParty"}}'
    advance --run-dir "$RUN"
    [ "$status" -eq 0 ]
    [ "$(member_served lead)" = "real-served-id" ]
    # Neither name is the requested alias, so this is still a substitution.
    [ "$(member_outcome lead)" = "degraded" ]
}

@test "a receipt whose key differs but whose canonicalModel is the alias is no substitution" {
    # The route the model was reached by is not the model. Comparing the KEY
    # here would degrade a member that ran on exactly what it asked for.
    one_member_serving '{"route-key-not-a-model":{"canonicalModel":"alpha","provider":"firstParty"}}'
    advance --run-dir "$RUN"
    [ "$status" -eq 0 ]
    [ "$(member_served lead)" = "alpha" ]
    [ "$(member_outcome lead)" = "done" ]
    [ "$(member_failure lead)" = "null" ]
}

# ===========================================================================
# U7 — the surface contracts describe what changed (R13, R14)
#
# WHY THESE ARE HERE. A field a caller cannot learn about from `--describe` is
# a field nobody reads. `members[].failure` is the whole point of this plan and
# it shipped in U2 with nothing declaring it; `served_model` shipped in U9 the
# same way. The reporting instruction in the driver skill is the other half:
# the cause existed on the record and the skill told the driver to print
# "probed fields only", so it never reached the operator.
# ===========================================================================

describe_json() {
    bash "$TEAM" --describe 2>/dev/null
}

# assert_response_field <json> <name> — declared exactly once, with real prose.
assert_response_field() {
    local n
    n="$(printf '%s' "$1" | jq -r --arg f "$2" \
        '[.response_fields[] | select(.name == $f) | select(.note != null and (.note | length > 20))] | length')"
    if [ "$n" != "1" ]; then
        printf 'assert_response_field: %s is declared %s times with usable prose, want 1\n' "$2" "$n" >&2
        return 1
    fi
    return 0
}

@test "--describe declares every member field this plan added" {
    local d
    d="$(describe_json)"
    assert_one_object "$d"
    assert_response_field "$d" 'members[].failure'
    assert_response_field "$d" 'members[].served_model'
    assert_response_field "$d" 'members[].attempts'
    # The cause a caller branches on is the projection, not the object, so the
    # contract has to name it too.
    assert_response_field "$d" 'members[].error'
}

@test "--describe says a member's cause is an object with the four keys the record writes" {
    # A note saying only "the cause" leaves a reader to guess the shape, and the
    # shape is what they have to index. These four keys are what
    # team_record_failure and team_record_launch_failure both write.
    local note k
    note="$(describe_json | jq -r '.response_fields[] | select(.name == "members[].failure") | .note')"
    for k in error detail child_exit_code degraded_reasons; do
        if ! printf '%s' "$note" | grep -qF -- "$k"; then
            printf 'the members[].failure note does not name the key %s: %s\n' "$k" "$note" >&2
            return 1
        fi
    done
}

@test "every declared error value maps to the exit code it declares, and back" {
    # spawn::team_code_for is a wildcard case, so the two sides cannot be
    # compared as two lists. They are compared by BEHAVIOUR: ask the function
    # for each declared value and require the declared code. The reverse arm is
    # the list one — a value the function names explicitly and the contract
    # never mentions is a code no caller can anticipate.
    local d v c want
    d="$(describe_json)"
    [ "$(printf '%s' "$d" | jq -r '.error_values | length')" -ge 10 ]
    while read -r v want; do
        c="$(bash -c ". '$TEAM' >/dev/null 2>&1; spawn::team_code_for '$v'")"
        if [ "$c" != "$want" ]; then
            printf 'error value %s: --describe says exit_code %s, spawn::team_code_for says %s\n' \
                "$v" "$want" "$c" >&2
            return 1
        fi
    done < <(printf '%s' "$d" | jq -r '.error_values[] | "\(.value) \(.exit_code)"')

    # Reverse: every value the function names in its own case arms is declared.
    local named
    named="$(sed -n '/^spawn::team_code_for()/,/^}/p' "$TEAM" \
        | sed -n 's/^ *\([a-z_|]*\)) *printf.*/\1/p' | tr '|' '\n' | grep -v '^\*$' | grep -v '^$')"
    for v in $named; do
        if [ "$(printf '%s' "$d" | jq -r --arg v "$v" '[.error_values[] | select(.value == $v)] | length')" != "1" ]; then
            printf 'spawn::team_code_for names %s and --describe declares no such error value\n' "$v" >&2
            return 1
        fi
    done

    # The other reverse arm, and the one that carries the weight. The case above
    # names two values and falls everything else through to EX_USAGE, so a check
    # written only against its arms guards 2 of the 14 declared values: deleting
    # any of the other 12 from the contract reddens nothing. The code-side set of
    # values this surface can actually hand a caller is the set it ASSIGNS, so
    # that is what the contract is compared against.
    #
    # ONE WAY ONLY. launch_failed is declared and never literal-assigned — it
    # reaches a member row through team_record_launch_failure — so demanding
    # declared-implies-assigned would redden correct code.
    local assigned
    assigned="$(grep -ohE 'SPAWN_TEAM_ERROR="[a-z_]+"' "$LIB"/team*.sh | sed 's/.*="//;s/"//' | sort -u)"
    [ -n "$assigned" ]
    for v in $assigned; do
        if [ "$(printf '%s' "$d" | jq -r --arg v "$v" \
                '[(.error_values[].value), (.exit_codes[].error)] | map(select(. == $v)) | length')" -lt 1 ]; then
            printf 'lib/team*.sh can set error %s and --describe declares it nowhere\n' "$v" >&2
            return 1
        fi
    done
}

# --- the driver skill's reporting instruction (R14) -------------------------

skill_body() {   # the body only: frontmatter prose is not an instruction
    awk 'NR==1 && $0=="---" { inb=1; next } inb && $0=="---" { inb=0; next } !inb' \
        "$LIB/../skills/team-run/SKILL.md"
}

# The "Reporting between rounds" section alone. An instruction that lands
# anywhere else in the file is not the one the driver follows when reporting.
reporting_section() {
    skill_body | awk '/^### Reporting between rounds/ { on=1; next } on && /^#/ { exit } on'
}

@test "the reporting section tells the driver to report EVERY member, not the probed ones" {
    local sec
    sec="$(reporting_section)"
    [ -n "$sec" ]
    if ! printf '%s' "$sec" | grep -qiE 'every member'; then
        printf 'the reporting section never says to report every member:\n%s\n' "$sec" >&2
        return 1
    fi
}

@test "the reporting section names a failed member's CAUSE in the per-member list" {
    # PRESENCE, deliberately. An edit that only deletes "probed fields only"
    # leaves a per-member list with no cause in it and would pass an
    # absence-only check, which is exactly the state this plan is fixing.
    local sec
    sec="$(reporting_section)"
    [ -n "$sec" ]
    local f
    # The two fields the cause actually lives in, by name. Prose about "the
    # cause" with no field in it leaves a driver to hunt for one.
    for f in 'members[].error' 'members[].failure'; do
        if ! printf '%s' "$sec" | grep -qF -- "$f"; then
            printf 'the reporting section does not name %s:\n%s\n' "$f" "$sec" >&2
            return 1
        fi
    done
    if ! printf '%s' "$sec" | grep -qiE 'cause'; then
        printf 'the reporting section does not name a members cause:\n%s\n' "$sec" >&2
        return 1
    fi
}

@test "the reporting section still forbids forwarding a member's narrative as fact" {
    # Load-bearing and easy to lose in a rewrite of this section: the cause is
    # the SUPERVISORS classification and may be reported; the members own
    # account of itself may not.
    skill_body | grep -qiE 'narrative'
}

@test "the reporting section no longer says probed fields only" {
    refute_file_match 'Probed fields only' "$LIB/../skills/team-run/SKILL.md"
}

@test "the skill tells the driver what retry is for on a mixed stop" {
    local body
    body="$(skill_body)"
    printf '%s' "$body" | grep -qF 'retry --run-id'
    # And it says the thing a driver would otherwise get wrong: retry only
    # returns the member to the roster, so a round still has to be dispatched.
    printf '%s' "$body" | grep -qiE 'retry[^.]*dispatches nothing|dispatches nothing[^.]*retry'
}

@test "the skill tells the driver to report a model substitution" {
    # served_model exists so the operator learns their review ran on a model
    # they did not ask for. A driver that never prints it makes the field moot.
    skill_body | grep -qF 'served_model'
}

# --- U10 (failure-reporting plan): status carries the cause -----------------

@test "--describe says the cause and the served model reach the status surface too" {
    local d
    d="$(describe_json)"
    [ -n "$d" ]
    local f
    for f in 'members[].failure' 'members[].served_model'; do
        if [ "$(printf '%s' "$d" | jq -r --arg f "$f" \
                '[.response_fields[].name] | index($f) != null')" != "true" ]; then
            printf -- '--describe declares no %s\n' "$f" >&2
            return 1
        fi
    done
    # THE NOTE, not only the name. Both fields were already declared as advance
    # only, so a name check alone passes over the declaration that is wrong.
    if ! printf '%s' "$d" | jq -r '.response_fields[]
            | select(.name == "members[].served_model") | .note' | grep -qF 'status'; then
        printf -- '--describe still does not say status carries served_model\n' >&2
        return 1
    fi
    if printf '%s' "$d" | jq -r '.response_fields[]
            | select(.name == "members[].served_model") | .note' | grep -qiF 'advance only'; then
        printf -- '--describe still calls served_model advance only\n' >&2
        return 1
    fi
}

@test "the reporting section no longer tells the driver that status carries no cause" {
    local sec
    sec="$(reporting_section)"
    [ -n "$sec" ]
    if printf '%s' "$sec" | grep -qiE 'carries no cause|no cause and no served model'; then
        printf 'the reporting section still says status carries no cause:\n%s\n' "$sec" >&2
        return 1
    fi
    # PRESENCE too: deleting the sentence would pass an absence-only check and
    # leave the driver with nothing said about status at all.
    if ! printf '%s' "$sec" | grep -qF 'status'; then
        printf 'the reporting section no longer mentions status:\n%s\n' "$sec" >&2
        return 1
    fi
}
