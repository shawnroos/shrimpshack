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
    [ -n "${GW_PID:-}" ] && { kill "$GW_PID" 2>/dev/null; wait "$GW_PID" 2>/dev/null; }
    # A `hang` child execs `sleep 600` and keeps NOTHING of $WORK in its argv, so
    # the sweep below cannot see it. Its pid is the only handle on it, and the
    # fixture writes that down for exactly this reason.
    if [ -f "${FAKE_CLAUDE_RECORD_DIR:-/nonexistent}/pid" ]; then
        while read -r p; do
            [ -n "$p" ] && kill -9 "$p" 2>/dev/null
        done < "$FAKE_CLAUDE_RECORD_DIR/pid"
    fi
    for p in $(pgrep -f "$WORK" 2>/dev/null); do
        [ "$p" = "$$" ] && continue
        kill -9 "$p" 2>/dev/null
    done
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
    unset FAKE_CLAUDE_MODE FAKE_CLAUDE_WRITE FAKE_CLAUDE_DENIALS
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
        '{mode:$m, bounds:{max_concurrent:$mc, max_rounds:3, token_ceiling:0},
          members:$ms}' > "$f"
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

    dispatch --run-id r1
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
