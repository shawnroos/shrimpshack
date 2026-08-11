#!/usr/bin/env bats
# U7 — the job record.
#
# The unit under test is lib/jobs.sh: one job directory per job, one lock per
# worktree, and a state established by PROBING rather than by reading the status
# file (KTD6). Nothing here needs a gateway or the `claude` CLI — a job record
# is on-disk state, so every assertion is on a run's exit code and on what
# landed on disk, never on the source text or on a message.
#
# The "job" in these tests is a fixture process that does nothing but stay alive
# carrying the argv marker. That is the whole of what the record layer knows
# about a job: a pid whose argv identifies it. A real supervisor arrives in U9.
#
# Failure classes are asserted on EXIT CODES (Verification Contract): a caller
# branches on the number and on the `error` enum, so those are what is pinned.

setup() {
    LIB="$(cd "$BATS_TEST_DIRNAME/../../lib" && pwd)"
    JOBS="$LIB/jobs.sh"
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/gw-jobs.XXXXXX")"
    # PHYSICAL path. On macOS /tmp is a symlink to /private/tmp, and jobs.sh
    # resolves the worktree with `pwd -P` on purpose — a logical path here would
    # compare unequal to what the script recorded, for a reason that has nothing
    # to do with the code.
    WORK="$(cd "$WORK" && pwd -P)"

    export TMPDIR="$WORK/tmp"; mkdir -p "$TMPDIR"
    # Nothing in this suite talks to a gateway, and a test that forgot that must
    # not reach the REAL one on port 4000. Pinned at a port nothing serves.
    export SPAWN_BASE_URL="http://127.0.0.1:1/anthropic"
    unset SPAWN_JOB_ROOT SPAWN_JOB_CLAIM_GRACE

    # Two independent worktrees. `git init` rather than bare directories,
    # because the per-worktree lock is resolved through
    # `git rev-parse --show-toplevel` — testing it on non-repos would exercise
    # the fallback and leave the property KTD2 actually turns on unproven.
    TREE_A="$WORK/tree-a"; mkdir -p "$TREE_A"; ( cd "$TREE_A" && git init -q . )
    TREE_B="$WORK/tree-b"; mkdir -p "$TREE_B"; ( cd "$TREE_B" && git init -q . )

    CONTRACT="$WORK/contract.txt"
    printf 'task: make the suite green\ndone: run-tests.sh unit exits 0\ndeliverables: report.md\n' > "$CONTRACT"

    # The stand-in for a supervisor: it holds a pid and carries the argv marker,
    # which is exactly and only what the record layer identifies a job by.
    FAKEJOB="$WORK/fake-job.sh"
    cat > "$FAKEJOB" <<'EOF'
#!/usr/bin/env bash
# $1 is the argv marker; it exists to be seen by `ps -o args=`.
while :; do sleep 0.2; done
EOF
    chmod +x "$FAKEJOB"
}

teardown() {
    # Leave no stray process. Same shape as launch.bats: every fixture process
    # this suite starts carries $WORK in its argv, so this reaps the ones a
    # failing test never got to kill.
    for p in $(pgrep -f "$WORK" 2>/dev/null); do
        [ "$p" = "$$" ] && continue
        kill -9 "$p" 2>/dev/null
    done
    rm -rf "$WORK"
}

# --- helpers ---------------------------------------------------------------

# NEGATIVE ASSERTIONS. bats runs under `set -e`, but POSIX exempts a pipeline
# beginning with `!` from it — so `! grep -q PATTERN file` NEVER fails a test,
# it evaluates and moves on. That shape already let a token-leak assertion pass
# over genuinely leaking code in this repo. These fail as PLAIN commands, which
# set -e does honour.
refute_file_match() {   # <literal> <file...>
    local pat="$1"; shift
    if grep -qF -- "$pat" "$@"; then
        printf 'refute_file_match: unexpected match for %s in %s\n' "$pat" "$*" >&2
        grep -nF -- "$pat" "$@" >&2
        return 1
    fi
    return 0
}
refute_output_match() { # <literal>, against $output
    if printf '%s' "$output" | grep -qF -- "$1"; then
        printf 'refute_output_match: unexpected match for %s in:\n%s\n' "$1" "$output" >&2
        return 1
    fi
    return 0
}

# Mode as an octal number, on either stat dialect. macOS is `stat -f '%Lp'`;
# GNU is `stat -c '%a'`. A test that only knew one would report a false green on
# the other box by way of an empty string comparing unequal to nothing.
mode_of() {
    stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null
}

# Runs jobs.sh with STDERR SPLIT OFF to a file. bats' `run` merges the two
# streams, and the contract is "one JSON object on stdout, diagnostics on stderr
# only" — merged, every say() line lands in $output and every jq assertion in
# this file parses a diagnostic instead of the response. Keeping stderr in a
# file rather than discarding it means a failing test can still show it.
jrun() {
    run bash -c 'err="$1"; shift; bash "$@" 2>>"$err"' _ "$WORK/err.log" "$JOBS" "$@"
}

claim() {   # <tree> -> $output is the response, $status the exit code
    jrun claim --contract "$CONTRACT" --cwd "$1"
}

handle_of() { printf '%s' "$1" | jq -r '.handle'; }

# Starts the stand-in supervisor for <handle> and records the pid, then adopts
# it. Sets JOB_PID.
start_and_adopt() {  # <tree> <handle>
    bash "$FAKEJOB" "spawn-bg-agent=$2" &
    JOB_PID=$!
    jrun adopt --handle "$2" --pid "$JOB_PID" --cwd "$1"
    [ "$status" -eq 0 ]
}

# --- scenario 1: the job directory ----------------------------------------

@test "a claim creates a 0700 job directory holding the contract, the log and the status file" {
    claim "$TREE_A"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -s 'length')" = "1" ]
    [ "$(printf '%s' "$output" | jq -r '.ok')" = "true" ]
    [ "$(printf '%s' "$output" | jq -r '.error')" = "null" ]

    local h dir
    h="$(handle_of "$output")"
    dir="$(printf '%s' "$output" | jq -r '.job.job_dir')"
    [ -d "$dir" ]
    [ "$(mode_of "$dir")" = "700" ]
    # The scratchpad root is inside the worktree (KD5) and not somewhere global.
    [ "$(printf '%s' "$output" | jq -r '.job.worktree')" = "$TREE_A" ]
    [ "$(printf '%s' "$output" | jq -r '.job.job_root')" = "$TREE_A/.spawn" ]
    [ "$(mode_of "$TREE_A/.spawn")" = "700" ]

    # The contract is COPIED in, byte for byte: the caller's file can be edited
    # or deleted the moment claim returns, and the job still has to be checkable
    # against what it was asked to do.
    [ -f "$dir/contract" ]
    cmp -s "$CONTRACT" "$dir/contract"
    rm -f "$CONTRACT"
    grep -q 'deliverables: report.md' "$dir/contract"

    [ -f "$dir/log" ]
    [ -f "$dir/status.json" ]
    [ "$(jq -r '.job_id' < "$dir/status.json")" = "$h" ]
    [ "$(jq -r '.state' < "$dir/status.json")" = "starting" ]
}

@test "the log is append-only and readable while the job is running" {
    claim "$TREE_A"
    [ "$status" -eq 0 ]
    local h log
    h="$(handle_of "$output")"
    log="$(printf '%s' "$output" | jq -r '.job.log')"

    start_and_adopt "$TREE_A" "$h"
    [ "$(printf '%s' "$output" | jq -r '.job.state')" = "running" ]
    [ "$(printf '%s' "$output" | jq -r '.job.live')" = "true" ]

    printf 'first line\n' | bash "$JOBS" log --handle "$h" --cwd "$TREE_A" >/dev/null
    # Readable MID-RUN, not only after the job ends: the job is still live here.
    kill -0 "$JOB_PID"
    [ "$(cat "$log")" = "first line" ]

    printf 'second line\n' | bash "$JOBS" log --handle "$h" --cwd "$TREE_A" >/dev/null
    printf 'third line\n'  | bash "$JOBS" log --handle "$h" --cwd "$TREE_A" >/dev/null
    kill -0 "$JOB_PID"
    # Append, never truncate — the earlier lines are still there, in order.
    [ "$(wc -l < "$log" | tr -d ' ')" = "3" ]
    [ "$(head -1 "$log")" = "first line" ]
    [ "$(tail -1 "$log")" = "third line" ]

    kill "$JOB_PID" 2>/dev/null
}

# --- scenario 2: one job per worktree (KTD2) -------------------------------

@test "a second claim in the same worktree is refused at exit 2 and names the running handle" {
    claim "$TREE_A"
    [ "$status" -eq 0 ]
    local first
    first="$(handle_of "$output")"
    start_and_adopt "$TREE_A" "$first"

    claim "$TREE_A"
    [ "$status" -eq 2 ]
    [ "$(printf '%s' "$output" | jq -s 'length')" = "1" ]
    [ "$(printf '%s' "$output" | jq -r '.ok')" = "false" ]
    [ "$(printf '%s' "$output" | jq -r '.error')" = "job_already_running" ]
    [ "$(printf '%s' "$output" | jq -r '.exit_code')" = "2" ]
    # The refusal is only usable if it names the job the caller must now query.
    [ "$(printf '%s' "$output" | jq -r '.running_handle')" = "$first" ]
    [ "$(printf '%s' "$output" | jq -r '.running_state')" = "running" ]
    [ "$(printf '%s' "$output" | jq -r '.remedy')" != "null" ]

    # And no second job directory was left behind by the refused claim.
    [ "$(find "$TREE_A/.spawn" -maxdepth 1 -type d -name 'job-*' | wc -l | tr -d ' ')" = "1" ]

    kill "$JOB_PID" 2>/dev/null
}

@test "the worktree is free again once the job is released" {
    claim "$TREE_A"
    [ "$status" -eq 0 ]
    local first
    first="$(handle_of "$output")"
    start_and_adopt "$TREE_A" "$first"

    jrun release --handle "$first" --cwd "$TREE_A" --state degraded --detail "nothing was produced"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.job.state')" = "degraded" ]
    # A terminal state needs no probe — it was written by something still alive.
    [ "$(printf '%s' "$output" | jq -r '.job.state_source')" = "record" ]
    [ "$(printf '%s' "$output" | jq -r '.job.ended_at')" != "null" ]

    claim "$TREE_A"
    [ "$status" -eq 0 ]
    [ "$(handle_of "$output")" != "$first" ]

    kill "$JOB_PID" 2>/dev/null
}

@test "release refuses a state outside the four terminal states" {
    claim "$TREE_A"
    [ "$status" -eq 0 ]
    local h; h="$(handle_of "$output")"

    jrun release --handle "$h" --cwd "$TREE_A" --state finished
    [ "$status" -eq 2 ]
    [ "$(printf '%s' "$output" | jq -r '.error')" = "state_invalid" ]
    # The record was not moved into a state the closed set does not contain.
    [ "$(jq -r '.state' < "$TREE_A/.spawn/$h/status.json")" = "starting" ]
}

# --- scenario 3: a different worktree is a different lock ------------------

@test "a claim in a different worktree is not refused" {
    claim "$TREE_A"
    [ "$status" -eq 0 ]
    local a; a="$(handle_of "$output")"
    start_and_adopt "$TREE_A" "$a"

    claim "$TREE_B"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.ok')" = "true" ]
    local b; b="$(handle_of "$output")"
    [ "$b" != "$a" ]
    [ "$(printf '%s' "$output" | jq -r '.job.worktree')" = "$TREE_B" ]

    # Two records, two locks, neither in the other's tree.
    [ -d "$TREE_A/.spawn/$a" ]
    [ -d "$TREE_B/.spawn/$b" ]
    [ ! -d "$TREE_B/.spawn/$a" ]
    [ "$(cat "$TREE_A/.spawn/lock/job")" = "$a" ]
    [ "$(cat "$TREE_B/.spawn/lock/job")" = "$b" ]

    # A subdirectory of a worktree resolves to the SAME lock as its root: the
    # boundary is the worktree, not the directory the caller happened to be in.
    mkdir -p "$TREE_A/deep/nested"
    claim "$TREE_A/deep/nested"
    [ "$status" -eq 2 ]
    [ "$(printf '%s' "$output" | jq -r '.running_handle')" = "$a" ]

    kill "$JOB_PID" 2>/dev/null
}

# --- scenario 4: the status file is a claim (KTD6) -------------------------

@test "a status file claiming running for a dead pid resolves to a terminal state" {
    claim "$TREE_A"
    [ "$status" -eq 0 ]
    local h; h="$(handle_of "$output")"
    start_and_adopt "$TREE_A" "$h"

    # Kill the writer, exactly the way the spike did. Nothing updates the file,
    # because the thing that would have updated it is the thing that died.
    kill -9 "$JOB_PID" 2>/dev/null
    wait "$JOB_PID" 2>/dev/null || true

    # The file still lies. That is the precondition, and asserting it is what
    # keeps the next assertion from being vacuous.
    [ "$(jq -r '.state' < "$TREE_A/.spawn/$h/status.json")" = "running" ]

    jrun state --handle "$h" --cwd "$TREE_A"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.job.state')" = "failed" ]
    [ "$(printf '%s' "$output" | jq -r '.job.state_source')" = "probe" ]
    [ "$(printf '%s' "$output" | jq -r '.job.live')" = "false" ]
    # The claim is reported alongside the resolved state rather than hidden, so
    # a caller can see that the two disagreed.
    [ "$(printf '%s' "$output" | jq -r '.job.claimed_state')" = "running"  ]
    # Never `done`: nothing checked any deliverable.
    refute_output_match '"state":"done"'

    # And a read verb WRITES NOTHING — the record still carries the claim, so
    # polling is not a mutation and two pollers cannot race over the file.
    [ "$(jq -r '.state' < "$TREE_A/.spawn/$h/status.json")" = "running" ]

    # The dead job no longer holds the worktree.
    claim "$TREE_A"
    [ "$status" -eq 0 ]
}

# --- scenario 5: a recycled pid is not the job ------------------------------

@test "a live pid whose argv does not carry the marker is not treated as the job" {
    claim "$TREE_A"
    [ "$status" -eq 0 ]
    local h; h="$(handle_of "$output")"

    # Something else entirely, alive, on the pid the record names — the pid
    # recycling case. It is a real live process, so `kill -0` alone says yes;
    # only the argv check says no.
    bash "$FAKEJOB" "not-the-marker-$WORK" &
    local other=$!
    jrun adopt --handle "$h" --pid "$other" --cwd "$TREE_A"
    [ "$status" -eq 0 ]
    kill -0 "$other"

    jrun state --handle "$h" --cwd "$TREE_A"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.job.live')" = "false" ]
    [ "$(printf '%s' "$output" | jq -r '.job.state')" = "failed" ]
    [ "$(printf '%s' "$output" | jq -r '.job.state_source')" = "probe" ]

    # And it does not keep the worktree locked, which is the consequence that
    # matters: a recycled pid read as ours would wedge the tree permanently.
    claim "$TREE_A"
    [ "$status" -eq 0 ]

    kill "$other" 2>/dev/null

    # The mirror of the same check: a pid whose argv DOES carry the marker is
    # the job. Without this arm, an argv check that never matches anything would
    # pass every assertion above.
    local h2; h2="$(handle_of "$output")"
    start_and_adopt "$TREE_A" "$h2"
    jrun state --handle "$h2" --cwd "$TREE_A"
    [ "$(printf '%s' "$output" | jq -r '.job.live')" = "true" ]
    [ "$(printf '%s' "$output" | jq -r '.job.state')" = "running" ]
    kill "$JOB_PID" 2>/dev/null
}

# --- the envelope and the contract-as-data ---------------------------------

has_envelope() {  # reads the response on stdin
    jq -e '(keys) as $k
           | ["schema","ok","error","remedy","detail",
              "content_trust","content_notice","exit_code"]
           | all(. as $f | $k | index($f) != null)' >/dev/null
}

@test "every response carries the shared envelope, on success and on refusal" {
    claim "$TREE_A"
    [ "$status" -eq 0 ]
    printf '%s' "$output" | has_envelope
    [ "$(printf '%s' "$output" | jq -r '.schema')" = "spawn.response/v1" ]
    [ "$(printf '%s' "$output" | jq -r '.content_trust')" = "plugin-authored" ]
    local h; h="$(handle_of "$output")"
    start_and_adopt "$TREE_A" "$h"

    claim "$TREE_A"
    [ "$status" -eq 2 ]
    printf '%s' "$output" | has_envelope
    [ "$(printf '%s' "$output" | jq -r '.remedy')" != "null" ]
    [ "$(printf '%s' "$output" | jq -r '.detail')" != "null" ]

    jrun state --handle "job-20200101T000000Z-1111" --cwd "$TREE_A"
    [ "$status" -eq 2 ]
    printf '%s' "$output" | has_envelope
    [ "$(printf '%s' "$output" | jq -r '.error')" = "handle_unknown" ]

    kill "$JOB_PID" 2>/dev/null
}

# A PATH with every tool this script uses EXCEPT jq. Copied from envelope.bats,
# which owns the same idiom for the other three scripts: the pure-bash encoder
# tier is the one nobody runs, so it is the one that drifts silently.
jq_free_path() {
    local d="$WORK/nojq" t p
    mkdir -p "$d"
    for t in bash sh sed awk grep cat wc tr cut head tail sort mktemp dirname \
             basename mkdir rm cp mv ln chmod find kill sleep date git ps pgrep stat; do
        p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$d/$t"
    done
    printf '%s' "$d"
}

@test "R23/KTD7: with jq ABSENT the job record still emits one parseable envelope" {
    local nojq; nojq="$(jq_free_path)"
    # Proof the harness tests what it claims: jq really is unreachable.
    run env PATH="$nojq" bash -c 'command -v jq 2>/dev/null'
    [ "$status" -ne 0 ]

    # need_jq's hand-written string is a THIRD encoder, reached before any verb
    # runs, and it is the one most easily forgotten — a box with no jq is
    # exactly where a caller most needs something to parse.
    run env PATH="$nojq" bash -c "bash '$JOBS' claim --contract '$CONTRACT' --cwd '$TREE_A' 2>/dev/null"
    [ "$status" -eq 2 ]
    [ "$(printf '%s' "$output" | jq -s 'length')" = "1" ]
    printf '%s' "$output" | has_envelope
    [ "$(printf '%s' "$output" | jq -r '.schema')" = "spawn.response/v1" ]
    [ "$(printf '%s' "$output" | jq -r '.ok')" = "false" ]
    [ "$(printf '%s' "$output" | jq -r '.exit_code')" = "2" ]
    [ "$(printf '%s' "$output" | jq -r '.error')" = "internal" ]
    [ "$(printf '%s' "$output" | jq -r '.remedy')" != "null" ]
    [ "$(printf '%s' "$output" | jq -r '.help_requested')" = "false" ]
    [ "$(printf '%s' "$output" | jq -r '.verb')" = "claim" ]
    # Nothing was created: with no encoder there is no way to write a status
    # file, so refusing before the first mkdir is the only honest answer.
    [ ! -d "$TREE_A/.spawn" ]

    # The same on the help path, where help_requested is the discriminator a
    # caller branches on and is a bash literal needing no encoder.
    run env PATH="$nojq" bash -c "bash '$JOBS' --help --cwd '$TREE_A' 2>/dev/null"
    [ "$status" -eq 2 ]
    printf '%s' "$output" | has_envelope
    [ "$(printf '%s' "$output" | jq -r '.content_trust')" = "plugin-authored" ]
}

@test "--describe answers at exit 0 with no job, no lock and no gateway, and its enum matches the constants" {
    jrun --describe --cwd "$TREE_A"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -s 'length')" = "1" ]
    [ "$(printf '%s' "$output" | jq -r '.ok')" = "true" ]
    [ "$(printf '%s' "$output" | jq -r '.response_kind')" = "describe" ]
    # KTD8's closed set, as data rather than as prose in a comment.
    [ "$(printf '%s' "$output" | jq -c '.terminal_states')" = '["done","degraded","failed","cancelled"]' ]
    # The frozen enum: nothing here may declare a code outside {0,2,3,4,5,6,7}.
    [ "$(printf '%s' "$output" | jq -c '[.exit_codes[].code] | map(. as $c | [0,2,3,4,5,6,7] | index($c) != null) | all')" = "true" ]
    # Reading it left nothing behind — --describe is answerable before any job
    # exists, which is how U8-U10 learn the layout without starting one.
    [ ! -d "$TREE_A/.spawn" ]
}

@test "an unknown verb and a bad handle are refused before anything is written" {
    jrun frobnicate --cwd "$TREE_A"
    [ "$status" -eq 2 ]
    [ "$(printf '%s' "$output" | jq -r '.error')" = "usage" ]

    # A handle carrying a path traversal never reaches the filesystem: it is
    # refused by the grammar, not filtered on the way through.
    jrun state --handle '../../etc' --cwd "$TREE_A"
    [ "$status" -eq 2 ]
    [ "$(printf '%s' "$output" | jq -r '.error')" = "usage" ]

    jrun --help --cwd "$TREE_A"
    [ "$status" -eq 2 ]
    [ "$(printf '%s' "$output" | jq -r '.help_requested')" = "true" ]
    [ "$(printf '%s' "$output" | jq -r '.error')" = "usage" ]
}

# --- what this unit adds to the lints, beyond joining them (KTD10) ---------
#
# The two ENUMERATED lints are extended in their own suites rather than copied
# here — the no-spend grep in lens.bats and config_write_lint in launch.bats now
# both name jobs.sh. A second copy of a lint is how the two copies drift, and
# the copy nobody runs is the one that goes wrong. What is left here is the
# assertion those two do not make.

@test "the job record never resolves or holds the gateway token" {
    # A record layer has no reason to read gateway.yaml, and the surest way not
    # to leak a token is not to hold one. Asserted on the source because the
    # property is an absence.
    refute_file_match 'SPAWN_TOKEN' "$JOBS"
    refute_file_match 'CONFIG_PATH' "$JOBS"
    # Nothing in a job's own tree is world-readable either: the contract can
    # name internal paths and the log carries whatever the child wrote.
    claim "$TREE_A"
    [ "$status" -eq 0 ]
    local dir; dir="$(printf '%s' "$output" | jq -r '.job.job_dir')"
    [ "$(mode_of "$dir/contract")" = "600" ]
    [ "$(mode_of "$dir/status.json")" = "600" ]
    [ "$(mode_of "$dir/log")" = "600" ]
}
