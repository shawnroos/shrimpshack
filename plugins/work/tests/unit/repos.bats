#!/usr/bin/env bats

load setup_common

# U2 — the scope repository record.
#
# WHAT THE THREE VERBS PROMISE, AND WHAT THEY DO NOT
# `scope_repo` printing nothing is not a failure: a scope with three recorded
# repositories has no single right answer, and returning non-zero for it would
# make the caller unable to tell "cannot tell" from "could not read". The tests
# below assert the exit status of that case as hard as they assert the output.

bats_require_minimum_version 1.5.0

setup() {
    # pwd -P is what the writer records, so the fixture paths are resolved too --
    # $TMPDIR here is a symlink, and a raw mktemp path would never match.
    WORK="$(cd "$(mktemp -d)" && pwd -P)"
    export HERDR_LINEAR_STORE_DIR="$WORK/store"
    LIB="${BATS_TEST_DIRNAME}/../../lib/repos.sh"
    # shellcheck source=/dev/null
    . "$LIB"

    REPO_A="$WORK/repo-a"; REPO_B="$WORK/repo-b"; REPO_C="$WORK/repo-c"
    mkdir -p "$REPO_A" "$REPO_B" "$REPO_C"
}

teardown() { [ -n "${WORK:-}" ] && rm -rf "$WORK"; }

record_file() { printf '%s/scopes/%s.json' "$HERDR_LINEAR_STORE_DIR" "$1"; }

lines_of() { printf '%s\n' "$1" | grep -c . || true; }

@test "an unrecorded scope answers empty from both readers and succeeds" {
    run herdr_linear::scope_repos project-p1 team-t1
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    run herdr_linear::scope_repo project-p1 team-t1
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "an unrecorded scope says none is known and says to ask" {
    run herdr_linear::no_repo_reason project-p1 team-t1
    [ "$status" -eq 0 ]
    [[ "$output" == *"no repository is recorded"* ]]
    [[ "$output" == *"Ask"* ]]
}

@test "one recorded repository is the only answer" {
    herdr_linear::record_scope_repo "$REPO_A" project-p1

    run herdr_linear::scope_repos project-p1
    [ "$status" -eq 0 ]
    [ "$output" = "$REPO_A" ]

    run herdr_linear::scope_repo project-p1
    [ "$status" -eq 0 ]
    [ "$output" = "$REPO_A" ]
}

@test "three recorded repositories are three candidates and no single answer" {
    herdr_linear::record_scope_repo "$REPO_A" project-p1
    herdr_linear::record_scope_repo "$REPO_B" project-p1
    herdr_linear::record_scope_repo "$REPO_C" project-p1

    run herdr_linear::scope_repos project-p1
    [ "$status" -eq 0 ]
    [ "$(lines_of "$output")" -eq 3 ]

    run herdr_linear::scope_repo project-p1
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "the reason for several names every candidate" {
    herdr_linear::record_scope_repo "$REPO_A" project-p1
    herdr_linear::record_scope_repo "$REPO_B" project-p1
    herdr_linear::record_scope_repo "$REPO_C" project-p1

    run herdr_linear::no_repo_reason project-p1
    [ "$status" -eq 0 ]
    [[ "$output" == *"$REPO_A"* ]]
    [[ "$output" == *"$REPO_B"* ]]
    [[ "$output" == *"$REPO_C"* ]]
}

# AE12. A team-keyed answer is invisible to every later issue in that team once
# it gains a project, unless the project lookup falls back to the team key.
@test "a repository recorded under both keys resolves from the team key alone" {
    herdr_linear::record_scope_repo "$REPO_A" project-p1 team-t1

    run herdr_linear::scope_repos project-p9 team-t1
    [ "$status" -eq 0 ]
    [ "$output" = "$REPO_A" ]

    run herdr_linear::scope_repo project-p9 team-t1
    [ "$status" -eq 0 ]
    [ "$output" = "$REPO_A" ]
}

@test "a project key and a team key carrying one id are two records" {
    herdr_linear::record_scope_repo "$REPO_A" project-x1
    herdr_linear::record_scope_repo "$REPO_B" team-x1

    run herdr_linear::scope_repos project-x1
    [ "$output" = "$REPO_A" ]

    run herdr_linear::scope_repos team-x1
    [ "$output" = "$REPO_B" ]
}

@test "recording the same repository twice leaves one entry" {
    herdr_linear::record_scope_repo "$REPO_A" project-p1
    herdr_linear::record_scope_repo "$REPO_A" project-p1

    run herdr_linear::scope_repos project-p1
    [ "$(lines_of "$output")" -eq 1 ]

    run herdr_linear::scope_repo project-p1
    [ "$output" = "$REPO_A" ]
}

# R7a. Resolving a relative path would put the caller's directory back in the
# answer, which is the defect this plan removes.
@test "a relative repository is refused and writes nothing" {
    cd "$WORK"
    run herdr_linear::record_scope_repo "repo-a" project-p1
    [ "$status" -ne 0 ]
    [ ! -e "$(record_file project-p1)" ]

    run herdr_linear::scope_repos project-p1
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "a scope key that is a traversal is refused and writes nothing outside the store" {
    for bad in "../escaped" "../../escaped" ".." "a/b" 'a$b' ""; do
        run herdr_linear::record_scope_repo "$REPO_A" "$bad"
        [ "$status" -ne 0 ]
        run herdr_linear::scope_repos "$bad"
        [ "$status" -ne 0 ]
    done
    [ -z "$(find "$WORK" -name '*.json' -print -quit)" ]
}

@test "a truncated record reads as empty rather than taking the caller down" {
    herdr_linear::record_scope_repo "$REPO_A" project-p1
    printf '{"version": 1, "repos' > "$(record_file project-p1)"

    run herdr_linear::scope_repos project-p1
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    run herdr_linear::no_repo_reason project-p1
    [ "$status" -eq 0 ]
    [[ "$output" == *"no repository is recorded"* ]]
}

# The hold seam opens the critical section wide enough that a missing lock is a
# deterministic loss rather than a race that usually happens not to lose.
@test "two concurrent writers for one scope both survive" {
    export HERDR_LINEAR_LOCK_HOLD_MS=300

    bash -c '. "$1"; herdr_linear::record_scope_repo "$2" project-p1' _ "$LIB" "$REPO_A" &
    local a=$!
    bash -c '. "$1"; herdr_linear::record_scope_repo "$2" project-p1' _ "$LIB" "$REPO_B" &
    local b=$!
    wait "$a"
    wait "$b"

    run herdr_linear::scope_repos project-p1
    [ "$status" -eq 0 ]
    [ "$(lines_of "$output")" -eq 2 ]
    [[ "$output" == *"$REPO_A"* ]]
    [[ "$output" == *"$REPO_B"* ]]
}

# R6 states the record the answer was read from. After the team fallback that
# is the team's file, not the first key the caller passed.
@test "the source of a fallback answer is the team record, not the project one" {
    herdr_linear::record_scope_repo "$REPO_A" team-t1

    run herdr_linear::scope_repo_source project-p9 team-t1
    [ "$status" -eq 0 ]
    [ "$output" = "$(record_file team-t1)" ]

    run herdr_linear::scope_repo_source project-p9
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# A record on disk that cannot be opened is not an empty set. Answering empty
# would ask a question whose answer is recorded, and the answer would then be
# recorded a second time.
@test "a record that exists but cannot be read is an error, not an empty set" {
    herdr_linear::record_scope_repo "$REPO_A" project-p1
    chmod 000 "$(record_file project-p1)"

    run herdr_linear::scope_repos project-p1
    local rc="$status"
    chmod 600 "$(record_file project-p1)"
    [ "$rc" -ne 0 ]
}
