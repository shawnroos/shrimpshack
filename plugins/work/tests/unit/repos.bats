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

# ---------------------------------------------------------------- the pair key
#
# `start.sh` and `context-filter.sh` both used to compose this key and both
# re-implemented the dot guard below. One composer, one failure behaviour:
# nothing on stdout and a non-zero return, same as `_scope_record_path` refuses
# an unsafe key today. Neither caller writes or offers something a person
# cannot see on the strength of a key this function refused to make, so a
# silent refusal costs nothing here -- a caller that must say why out loud
# reads the non-zero return and writes its own message.

@test "the pair key joins the project and team keys" {
    run herdr_linear::pair_key p1 t1
    [ "$status" -eq 0 ]
    [ "$output" = "project-p1.team-t1" ]
}

@test "a project id carrying a dot refuses the pair key, printing nothing" {
    run herdr_linear::pair_key p.1 t1
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "a team id carrying a dot refuses the pair key, printing nothing" {
    run herdr_linear::pair_key p1 t.1
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "an unsafe project id refuses the pair key" {
    run herdr_linear::pair_key ../escaped t1
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "an unsafe team id refuses the pair key" {
    run herdr_linear::pair_key p1 ../escaped
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "either id missing refuses the pair key" {
    run herdr_linear::pair_key p1 ""
    [ "$status" -ne 0 ]
    run herdr_linear::pair_key "" t1
    [ "$status" -ne 0 ]
}

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
    # A candidate that no longer belongs to the scope is why this stays a
    # question, and the key it is recorded under is on no other line the
    # reader has.
    [[ "$output" == *"forget_scope_repo project-p1"* ]]
}

# AE12. A lookup falls through in the order the caller passes: whichever key
# comes second answers when the first holds nothing.
@test "the second key answers when the first holds nothing" {
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

# R6 states the record the answer was read from, which is the key that actually
# answered and not always the first key the caller passed.
@test "the source is the key that answered, not the first key passed" {
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

# The project record is the fallback for a scope with no team of its own. The
# team key is passed first now, so an absent or empty one must be stepped over
# rather than end the lookup.
@test "an empty team key is stepped over and the project record answers" {
    herdr_linear::record_scope_repo "$REPO_A" project-p1

    run herdr_linear::scope_repos "" project-p1
    [ "$status" -eq 0 ]
    [ "$output" = "$REPO_A" ]

    run herdr_linear::scope_repo_source "" project-p1
    [ "$status" -eq 0 ]
    [ "$output" = "$(record_file project-p1)" ]
}

@test "forgetting one repository leaves the rest of the record" {
    herdr_linear::record_scope_repo "$REPO_A" project-p1
    herdr_linear::record_scope_repo "$REPO_B" project-p1

    run herdr_linear::forget_scope_repo project-p1 "$REPO_A"
    [ "$status" -eq 0 ]

    run herdr_linear::scope_repos project-p1
    [ "$status" -eq 0 ]
    [ "$output" = "$REPO_B" ]
}

@test "forgetting with no repository removes the whole record" {
    herdr_linear::record_scope_repo "$REPO_A" project-p1
    herdr_linear::record_scope_repo "$REPO_B" project-p1

    run herdr_linear::forget_scope_repo project-p1
    [ "$status" -eq 0 ]
    [ ! -e "$(record_file project-p1)" ]

    run herdr_linear::scope_repos project-p1
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# A record the reader refuses holds no repository to keep, and leaving it would
# let the person walk away from a file every later read still trips over.
@test "forgetting a repository takes a record the reader refuses with it" {
    herdr_linear::record_scope_repo "$REPO_A" project-p1
    printf '{"version": 1, "repos' > "$(record_file project-p1)"

    run herdr_linear::forget_scope_repo project-p1 "$REPO_A"
    [ "$status" -eq 0 ]
    [ ! -e "$(record_file project-p1)" ]
}

# Refused-but-readable and cannot-be-opened are two different states, and
# _scope_read keeps them apart. Deleting a record nobody can read, on being
# asked to drop ONE repository out of it, throws away every other repository in
# it on the caller's behalf and reports that as done.
@test "forgetting one repository leaves a record that cannot be read alone" {
    herdr_linear::record_scope_repo "$REPO_A" project-p1
    herdr_linear::record_scope_repo "$REPO_B" project-p1
    chmod 000 "$(record_file project-p1)"

    run herdr_linear::forget_scope_repo project-p1 "$REPO_A"
    local rc="$status"
    chmod 600 "$(record_file project-p1)"
    [ "$rc" -ne 0 ]
    [ -e "$(record_file project-p1)" ]
    # The lock is a sibling directory, so a path that returns early still has to
    # release it or every later write for this scope waits out the stale timeout.
    [ ! -e "$(record_file project-p1).lock" ]

    run herdr_linear::scope_repos project-p1
    [ "$status" -eq 0 ]
    [[ "$output" == *"$REPO_A"* ]]
    [[ "$output" == *"$REPO_B"* ]]
}

# Forgetting is how a wrong answer is undone, and the person undoing it does
# not know which keys hold a record. Nothing to forget is the state they asked
# for, so it is success.
@test "forgetting what was never recorded is not an error" {
    run herdr_linear::forget_scope_repo project-p1
    [ "$status" -eq 0 ]

    run herdr_linear::forget_scope_repo project-p1 "$REPO_A"
    [ "$status" -eq 0 ]

    run herdr_linear::forget_scope_repo ../escaped
    [ "$status" -ne 0 ]
}
