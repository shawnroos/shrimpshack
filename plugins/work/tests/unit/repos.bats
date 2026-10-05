#!/usr/bin/env bats

load setup_common

# The scope repository record: which repository a Linear scope is worked in,
# kept in the plugin's own data file, with the old ~/.claude/work store read
# only as a fallback and never written.
#
# `scope_repo` printing nothing is not a failure: a scope with three recorded
# repositories has no single right answer, and returning non-zero for it would
# make the caller unable to tell "cannot tell" from "could not read".

bats_require_minimum_version 1.5.0

setup() {
    # pwd -P is what the writer records; $TMPDIR is a symlink here.
    WORK="$(cd "$(mktemp -d)" && pwd -P)"
    export CLAUDE_PLUGIN_DATA="$WORK/plugin-data"
    export HERDR_LINEAR_STORE_DIR="$WORK/store"
    LIB="${BATS_TEST_DIRNAME}/../../lib/repos.sh"
    # shellcheck source=/dev/null
    . "$LIB"

    REPO_A="$WORK/repo-a"; REPO_B="$WORK/repo-b"; REPO_C="$WORK/repo-c"
    mkdir -p "$REPO_A" "$REPO_B" "$REPO_C"
}

teardown() {
    [ -n "${WORK:-}" ] || return 0
    chmod -R u+rwx "$WORK" 2>/dev/null
    rm -rf "$WORK"
}

plugin_file() { printf '%s/scopes.json' "$CLAUDE_PLUGIN_DATA"; }

old_file() { printf '%s/scopes/%s.json' "$HERDR_LINEAR_STORE_DIR" "$1"; }

# Seeds the old store as the retired writer left it, dated in the past so a
# write within the same second cannot hide an mtime change.
old_record() {
    local key="$1"; shift
    mkdir -p "$HERDR_LINEAR_STORE_DIR/scopes"
    python3 -c 'import json,sys; print(json.dumps({"version": 1, "repositories": sys.argv[1:]}))' \
        "$@" > "$(old_file "$key")"
    chmod 600 "$(old_file "$key")"
    touch -t 202001010000 "$(old_file "$key")"
}

entry_of() {
    python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1]))["scopes"][sys.argv[2]]["repositories"]))' \
        "$(plugin_file)" "$1"
}

mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1"; }

lines_of() { printf '%s\n' "$1" | grep -c . || true; }

@test "the pair key joins the project and team keys" {
    run herdr_linear::pair_key p1 t1
    [ "$status" -eq 0 ]
    [ "$output" = "project-p1.team-t1" ]
}

@test "a dot in either id refuses the pair key, printing nothing" {
    run herdr_linear::pair_key p.1 t1
    [ "$status" -ne 0 ]
    [ -z "$output" ]
    run herdr_linear::pair_key p1 t.1
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "an unsafe or missing id refuses the pair key" {
    run herdr_linear::pair_key ../escaped t1
    [ "$status" -ne 0 ]
    [ -z "$output" ]
    run herdr_linear::pair_key p1 ../escaped
    [ "$status" -ne 0 ]
    run herdr_linear::pair_key p1 ""
    [ "$status" -ne 0 ]
    run herdr_linear::pair_key "" t1
    [ "$status" -ne 0 ]
}

@test "an unrecorded scope answers empty from both readers and succeeds" {
    run herdr_linear::scope_repos project-p1.team-t1 team-t1
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    run herdr_linear::scope_repo project-p1.team-t1 team-t1
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "an unrecorded scope says none is known and says to ask" {
    run herdr_linear::no_repo_reason project-p1 team-t1
    [ "$status" -eq 0 ]
    [[ "$output" == *"no repository is recorded"* ]]
    [[ "$output" == *"Ask"* ]]
}

@test "an answer recorded for a team is returned by the next lookup without asking" {
    herdr_linear::record_scope_repo "$REPO_A" project-p1.team-t1

    run herdr_linear::scope_repo project-p1.team-t1 team-t1
    [ "$status" -eq 0 ]
    [ "$output" = "$REPO_A" ]
    [ "$(entry_of project-p1.team-t1)" = "$REPO_A" ]
}

@test "the answer is written to the plugin data file and nowhere under the old store" {
    herdr_linear::record_scope_repo "$REPO_A" project-p1.team-t1

    [ -f "$(plugin_file)" ]
    [ ! -e "$HERDR_LINEAR_STORE_DIR" ]
}

@test "with CLAUDE_PLUGIN_DATA unset the answer goes under the fallback path" {
    unset CLAUDE_PLUGIN_DATA
    export HOME="$WORK/home"
    mkdir -p "$HOME"

    herdr_linear::record_scope_repo "$REPO_A" project-p1.team-t1

    [ -f "$HOME/.claude/plugins/data/work-shrimpshack/scopes.json" ]
    run herdr_linear::scope_repo project-p1.team-t1
    [ "$output" = "$REPO_A" ]
}

@test "a miss reads the old store, records the answer in the plugin file, and leaves the old file alone" {
    old_record project-p1.team-t1 "$REPO_A"
    local before listing_before
    before="$(mtime "$(old_file project-p1.team-t1)")"
    listing_before="$(ls -la "$HERDR_LINEAR_STORE_DIR/scopes")"
    mkdir -p "$CLAUDE_PLUGIN_DATA"
    : > "$(plugin_file)"

    run herdr_linear::scope_repo project-p1.team-t1 team-t1
    [ "$status" -eq 0 ]
    [ "$output" = "$REPO_A" ]

    [ "$(entry_of project-p1.team-t1)" = "$REPO_A" ]
    [ "$(mtime "$(old_file project-p1.team-t1)")" = "$before" ]
    [ "$(ls -la "$HERDR_LINEAR_STORE_DIR/scopes")" = "$listing_before" ]
}

@test "the plugin file answers before the old store for the same key" {
    herdr_linear::record_scope_repo "$REPO_A" project-p1.team-t1
    old_record project-p1.team-t1 "$REPO_B"

    run herdr_linear::scope_repos project-p1.team-t1
    [ "$output" = "$REPO_A" ]
}

@test "recording against a key the old store answers adds to that answer" {
    old_record project-p1 "$REPO_B"
    herdr_linear::record_scope_repo "$REPO_A" project-p1

    run herdr_linear::scope_repos project-p1
    [ "$(lines_of "$output")" -eq 2 ]
}

@test "an old-store record that is group-writable is not trusted" {
    old_record project-p1.team-t1 "$REPO_A"
    chmod 660 "$(old_file project-p1.team-t1)"

    run herdr_linear::scope_repos project-p1.team-t1
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "a corrupt plugin file is reported and not overwritten" {
    mkdir -p "$CLAUDE_PLUGIN_DATA"
    printf '{"version": 1, "scop' > "$(plugin_file)"
    local before
    before="$(cat "$(plugin_file)")"

    run herdr_linear::record_scope_repo "$REPO_A" project-p1.team-t1
    [ "$status" -ne 0 ]
    [[ "$output" == *"$(plugin_file)"* ]]
    [ "$(cat "$(plugin_file)")" = "$before" ]

    run herdr_linear::scope_repos project-p1.team-t1
    [ "$status" -ne 0 ]
    [[ "$output" == *"$(plugin_file)"* ]]

    run herdr_linear::forget_scope_repo project-p1.team-t1
    [ "$status" -ne 0 ]
    [ "$(cat "$(plugin_file)")" = "$before" ]
    [ ! -e "$(plugin_file).lock" ]
}

@test "a corrupt plugin file is not hidden behind an old-store answer" {
    old_record project-p1.team-t1 "$REPO_A"
    mkdir -p "$CLAUDE_PLUGIN_DATA"
    printf 'not json' > "$(plugin_file)"

    run herdr_linear::scope_repos project-p1.team-t1
    [ "$status" -ne 0 ]
    [ "$(cat "$(plugin_file)")" = "not json" ]
}

@test "the reason given for a corrupt plugin file names it rather than asking" {
    mkdir -p "$CLAUDE_PLUGIN_DATA"
    printf 'not json' > "$(plugin_file)"

    run herdr_linear::no_repo_reason project-p1.team-t1
    [ "$status" -eq 0 ]
    [[ "$output" == *"$(plugin_file)"* ]]
    [[ "$output" != *"no repository is recorded"* ]]
}

@test "a plugin file that exists but cannot be read is an error, not an empty set" {
    herdr_linear::record_scope_repo "$REPO_A" project-p1.team-t1
    chmod 000 "$(plugin_file)"

    run herdr_linear::scope_repos project-p1.team-t1
    local rc="$status"
    chmod 600 "$(plugin_file)"
    [ "$rc" -ne 0 ]
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

@test "the reason for several names every candidate and the key to forget from" {
    herdr_linear::record_scope_repo "$REPO_A" project-p1
    herdr_linear::record_scope_repo "$REPO_B" project-p1
    herdr_linear::record_scope_repo "$REPO_C" project-p1

    run herdr_linear::no_repo_reason project-p1
    [ "$status" -eq 0 ]
    [[ "$output" == *"$REPO_A"* ]]
    [[ "$output" == *"$REPO_B"* ]]
    [[ "$output" == *"$REPO_C"* ]]
    [[ "$output" == *"forget_scope_repo project-p1"* ]]
}

@test "keys are read in the order given: the team key answers when the pair holds nothing" {
    herdr_linear::record_scope_repo "$REPO_A" team-t1
    herdr_linear::record_scope_repo "$REPO_B" project-p9

    run herdr_linear::scope_repos project-p9.team-t1 team-t1 project-p9
    [ "$status" -eq 0 ]
    [ "$output" = "$REPO_A" ]
}

@test "an empty key is stepped over" {
    herdr_linear::record_scope_repo "$REPO_A" project-p1

    run herdr_linear::scope_repos "" project-p1
    [ "$status" -eq 0 ]
    [ "$output" = "$REPO_A" ]
}

@test "the source is the key that answered, not the first key passed" {
    herdr_linear::record_scope_repo "$REPO_A" team-t1

    run herdr_linear::scope_repo_source project-p9.team-t1 team-t1
    [ "$status" -eq 0 ]
    [ "$output" = "team-t1" ]

    run herdr_linear::scope_repo_source project-p9
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "the scope file is the plugin data file" {
    run herdr_linear::scope_file
    [ "$status" -eq 0 ]
    [ "$output" = "$(plugin_file)" ]
}

@test "recording the same repository twice leaves one entry" {
    herdr_linear::record_scope_repo "$REPO_A" project-p1
    herdr_linear::record_scope_repo "$REPO_A" project-p1

    run herdr_linear::scope_repos project-p1
    [ "$(lines_of "$output")" -eq 1 ]
}

@test "a relative repository is refused and writes nothing" {
    cd "$WORK"
    run herdr_linear::record_scope_repo "repo-a" project-p1
    [ "$status" -ne 0 ]
    [ ! -e "$(plugin_file)" ]
}

@test "an unsafe scope key is refused and writes nothing" {
    for bad in "../escaped" "../../escaped" ".." "a/b" 'a$b' ""; do
        run herdr_linear::record_scope_repo "$REPO_A" "$bad"
        [ "$status" -ne 0 ]
        run herdr_linear::scope_repos "$bad"
        [ "$status" -ne 0 ]
    done
    [ -z "$(find "$WORK" -name '*.json' -print -quit)" ]
}

# The hold seam widens the critical section so a missing lock is a
# deterministic loss rather than a race that usually happens not to lose.
@test "two concurrent writers both survive" {
    export HERDR_LINEAR_LOCK_HOLD_MS=300

    bash -c '. "$1"; herdr_linear::record_scope_repo "$2" project-p1' _ "$LIB" "$REPO_A" &
    local a=$!
    bash -c '. "$1"; herdr_linear::record_scope_repo "$2" team-t1' _ "$LIB" "$REPO_B" &
    local b=$!
    wait "$a"
    wait "$b"

    run herdr_linear::scope_repos project-p1
    [ "$output" = "$REPO_A" ]
    run herdr_linear::scope_repos team-t1
    [ "$output" = "$REPO_B" ]
    [ ! -e "$(plugin_file).lock" ]
}

# A stale lock that cannot be removed must still count toward the wait, or the
# writer spins forever. macOS has no `timeout`, so the watchdog is a poll loop.
@test "a stale lock that cannot be removed fails within the wait instead of hanging" {
    mkdir -p "$CLAUDE_PLUGIN_DATA"
    mkdir "$(plugin_file).lock"
    touch "$(plugin_file).lock/held"
    touch -t 200001010000 "$(plugin_file).lock"

    HERDR_LINEAR_SCOPE_LOCK_WAIT_SECONDS=1 HERDR_LINEAR_SCOPE_LOCK_STALE_SECONDS=1 \
        bash -c '. "$1"; herdr_linear::record_scope_repo "$2" project-p1' _ "$LIB" "$REPO_A" \
        >/dev/null 2>&1 &
    local pid=$! i=0
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 100 ]; do
        sleep 0.1
        i=$(( i + 1 ))
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null || true
        echo "writer still running after 10s: the stale-lock path never times out" >&2
        return 1
    fi
    local rc=0
    wait "$pid" || rc=$?
    [ "$rc" -ne 0 ]
    [ ! -e "$(plugin_file)" ]
}

@test "forgetting one repository leaves the rest" {
    herdr_linear::record_scope_repo "$REPO_A" project-p1
    herdr_linear::record_scope_repo "$REPO_B" project-p1

    run herdr_linear::forget_scope_repo project-p1 "$REPO_A"
    [ "$status" -eq 0 ]

    run herdr_linear::scope_repos project-p1
    [ "$output" = "$REPO_B" ]
}

@test "forgetting a whole key leaves other keys" {
    herdr_linear::record_scope_repo "$REPO_A" project-p1
    herdr_linear::record_scope_repo "$REPO_B" team-t1

    run herdr_linear::forget_scope_repo project-p1
    [ "$status" -eq 0 ]

    run herdr_linear::scope_repos project-p1
    [ -z "$output" ]
    run herdr_linear::scope_repos team-t1
    [ "$output" = "$REPO_B" ]
}

@test "a forgotten answer is not brought back from the old store" {
    old_record project-p1.team-t1 "$REPO_A"
    local before
    before="$(mtime "$(old_file project-p1.team-t1)")"

    run herdr_linear::forget_scope_repo project-p1.team-t1
    [ "$status" -eq 0 ]

    run herdr_linear::scope_repos project-p1.team-t1
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -f "$(old_file project-p1.team-t1)" ]
    [ "$(mtime "$(old_file project-p1.team-t1)")" = "$before" ]
}

@test "forgetting one repository of an old-store answer keeps the others" {
    old_record project-p1 "$REPO_A" "$REPO_B"

    run herdr_linear::forget_scope_repo project-p1 "$REPO_A"
    [ "$status" -eq 0 ]

    run herdr_linear::scope_repos project-p1
    [ "$output" = "$REPO_B" ]
}

@test "forgetting what was never recorded is not an error and writes nothing" {
    run herdr_linear::forget_scope_repo project-p1
    [ "$status" -eq 0 ]
    run herdr_linear::forget_scope_repo project-p1 "$REPO_A"
    [ "$status" -eq 0 ]
    [ ! -e "$(plugin_file)" ]

    run herdr_linear::forget_scope_repo ../escaped
    [ "$status" -ne 0 ]
}
