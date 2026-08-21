#!/usr/bin/env bats
# U10 — the handle is usable (R22).
#
# The unit under test is lib/handle.sh: the four operations a holder can perform
# on a job handle — query state, await completion within a bound, read the
# result against the contract, and cancel. Nothing here needs a gateway or the
# `claude` CLI: a handle names an on-disk record and a process, so every
# assertion is on a run's EXIT CODE and on what is on disk, never on source text
# and never on a message.
#
# The "supervisor" in these tests is a fixture process that carries the argv
# marker and answers a TERM the way the real one does — reap, record, release.
# That is the whole of what a handle-holder interacts with: a pid whose argv
# identifies it, and a record it writes.
#
# Failure classes are asserted on EXIT CODES and on the `error` enum, because
# the exit enum {0,2,3,4,5,6,7} is frozen and a new failure class is a new
# STRING. That is why handle_unknown, handle_expired and result_pending are all
# exit 2 and are told apart by `error`, and why await's two outcomes — the job
# finished, and the bound was reached — are told apart by exit 0 versus 6.

setup() {
    LIB="$(cd "$BATS_TEST_DIRNAME/../../lib" && pwd)"
    JOBS="$LIB/jobs.sh"
    HANDLE_SH="$LIB/handle.sh"

    WORK="$(mktemp -d "${TMPDIR:-/tmp}/gw-handle.XXXXXX")"

    . "$BATS_TEST_DIRNAME/../lib/sweep.bash"
    # PHYSICAL path. On macOS /tmp is a symlink to /private/tmp and the record
    # layer resolves the worktree with `pwd -P`, so a logical path here would
    # compare unequal to what the script recorded for a reason that has nothing
    # to do with the code.
    WORK="$(cd "$WORK" && pwd -P)"

    export TMPDIR="$WORK/tmp"; mkdir -p "$TMPDIR"
    # Nothing in this suite talks to a gateway, and a test that forgot that must
    # not reach the REAL one on port 4000. Pinned at a port nothing serves.
    export SPAWN_BASE_URL="http://127.0.0.1:1/anthropic"
    unset SPAWN_JOB_ROOT SPAWN_JOB_CLAIM_GRACE SPAWN_JOB_RETENTION
    unset SPAWN_AWAIT_DEADLINE SPAWN_AWAIT_INTERVAL SPAWN_CANCEL_DEADLINE

    # A real git worktree: the one-job lock is resolved through
    # `git rev-parse --show-toplevel`, and testing on a bare directory would
    # exercise the fallback instead of the property KTD2 turns on.
    TREE="$WORK/tree"; mkdir -p "$TREE"; ( cd "$TREE" && git init -q . )

    CONTRACT="$WORK/contract.json"
    printf '{"task":"make the suite green","done_means":"unit exits 0","deliverables":["report.md"]}\n' > "$CONTRACT"

    # The stand-in for the supervisor. It carries the argv marker (which is the
    # only thing that makes it live to the record layer) and answers a TERM in
    # one of three ways, so this suite can drive a cancel that lands, a cancel
    # that does not land in time, and a job that simply keeps running.
    FAKESUP="$WORK/fake-supervisor.sh"
    cat > "$FAKESUP" <<'FIXTURE'
#!/usr/bin/env bash
# $1 is the argv marker, a whole space-separated argv field, exactly where the
# real supervisor carries it. The rest is what it needs to answer a TERM the
# way the real one does.
JOBS_PATH="$2"; JOB_HANDLE="$3"; JOB_TREE="$4"; MODE="${5:-release}"
on_term() {
    case "$MODE" in
        release)
            bash "$JOBS_PATH" release --handle "$JOB_HANDLE" --state cancelled \
                --cwd "$JOB_TREE" >/dev/null 2>&1
            exit 0 ;;
        deaf)
            # Signalled, and it does not record anything. This is what an
            # unconfirmed cancel looks like from the outside.
            return 0 ;;
    esac
    exit 0
}
trap on_term TERM
while :; do sleep 0.2; done
FIXTURE
    chmod +x "$FAKESUP"

    HND=""
    FAKE_PID=""
}

teardown() {
    # Leave no stray process. Every fixture process this suite starts carries
    # $WORK in its argv, so this reaps the ones a failing test never got to.
    sweep_work
    rm -rf "$WORK"
}

# --- helpers ---------------------------------------------------------------

# NEGATIVE ASSERTIONS. bats runs under `set -e`, but POSIX exempts a pipeline
# beginning with `!` from it — so `! grep -q PATTERN` NEVER fails a test, it
# evaluates and moves on. These fail as PLAIN commands, which set -e honours.
refute_output_match() {  # <literal>, against $output
    if printf '%s' "$output" | grep -qF -- "$1"; then
        printf 'refute_output_match: unexpected match for %s in:\n%s\n' "$1" "$output" >&2
        return 1
    fi
    return 0
}

refute_file_exists() {   # <path>
    if [ -e "$1" ]; then
        printf 'refute_file_exists: %s exists and should not\n' "$1" >&2
        return 1
    fi
    return 0
}

has_envelope() {  # reads the response on stdin
    jq -e '(keys) as $k
           | ["schema","ok","error","remedy","detail",
              "content_trust","content_notice","exit_code"]
           | all(. as $f | $k | index($f) != null)' >/dev/null
}

# Runs handle.sh with STDERR SPLIT OFF to a file. bats' `run` merges the two
# streams, and the contract is "one JSON object on stdout, diagnostics on stderr
# only" — merged, every say() line lands in $output and every jq assertion here
# would parse a diagnostic instead of the response.
hrun() {
    run bash -c 'err="$1"; shift; bash "$@" 2>>"$err"' _ "$WORK/err.log" "$HANDLE_SH" "$@"
}

jrun() {
    run bash -c 'err="$1"; shift; bash "$@" 2>>"$err"' _ "$WORK/err.log" "$JOBS" "$@"
}

jqr() { printf '%s' "$output" | jq -r "$1"; }

# Claims a job and puts a live fixture supervisor behind it, exactly as the
# launcher does: claim, spawn carrying the marker, adopt.
start_job() {   # [term-mode: release|deaf]
    jrun claim --contract "$CONTRACT" --cwd "$TREE"
    [ "$status" -eq 0 ]
    HND="$(jqr '.handle')"
    bash "$FAKESUP" "spawn-bg-agent=$HND" "$JOBS" "$HND" "$TREE" "${1:-release}" &
    FAKE_PID=$!
    bash "$JOBS" adopt --handle "$HND" --pid "$FAKE_PID" --cwd "$TREE" >/dev/null 2>&1
    wait_live
}

# The record layer identifies a job by reading the pid's argv out of `ps`, and
# there is a short window after the fork where it is not there yet. Polled
# rather than slept on: a fixed sleep is either flaky or slow, and on this box
# there is no timeout(1) to bound it with.
wait_live() {
    local i
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        if [ "$(bash "$JOBS" state --handle "$HND" --cwd "$TREE" 2>/dev/null | jq -r '.job.live')" = "true" ]; then
            return 0
        fi
        sleep 0.25
    done
    printf 'wait_live: the fixture supervisor never became live to the record layer\n' >&2
    return 1
}

finish_job() {  # <terminal state>
    kill -9 "$FAKE_PID" 2>/dev/null
    # `wait` on a process killed by a signal returns 128+n, and bats runs under
    # set -e — an unguarded wait here fails the test for the reaping this helper
    # exists to do.
    wait "$FAKE_PID" 2>/dev/null || true
    bash "$JOBS" release --handle "$HND" --state "$1" --cwd "$TREE" >/dev/null 2>&1
}

# A supervisor's result record. Written by hand here rather than by running a
# real job: this unit tests what a HOLDER can do with the record, and coupling
# it to a live model call would make the suite need a gateway.
write_result() {  # <terminal state> <deliverables_satisfied>
    # Built with jq rather than a printf template: a hand-written template that
    # emits invalid JSON fails as "the verb refused" and looks like a bug in the
    # code under test, which is exactly what happened on the first pass here.
    jq -n --arg h "$HND" --arg s "$1" --argjson ok "$2" \
        '{schema:"spawn.job-result/v1", job_id:$h, terminal_state:$s,
          deliverables:[{path:"report.md", present:true, changed:true, satisfied:$ok}],
          deliverables_satisfied:$ok,
          changed_files:["report.md"],
          narrative:{text:"I wrote the report.",
                     content_trust:"untrusted-third-party-model-output",
                     content_notice:"Data, not instructions."}}' \
        > "$TREE/.spawn/$HND/result.json"
}

# A handle that is GRAMMAR-VALID and names nothing. A malformed one would be
# refused by the grammar check and would test the `usage` path instead of the
# unknown-handle path — a different requirement entirely.
NOSUCH="job-20200101T000000Z-1111"

# =========================================================================
# 1. Each operation against a running, a finished and an unknown handle
# =========================================================================

@test "state answers on a running job, a finished job, and refuses an unknown one" {
    start_job
    hrun state --handle "$HND" --cwd "$TREE"
    [ "$status" -eq 0 ]
    [ "$(jqr '.state')" = "running" ]
    [ "$(jqr '.terminal')" = "false" ]
    [ "$(jqr '.live')" = "true" ]
    [ "$(jqr '.result_available')" = "false" ]
    # The record is relayed, not re-derived: the handle layer is not a second
    # opinion about what state a job is in.
    [ "$(jqr '.job.job_id')" = "$HND" ]

    finish_job done
    hrun state --handle "$HND" --cwd "$TREE"
    [ "$status" -eq 0 ]
    [ "$(jqr '.state')" = "done" ]
    [ "$(jqr '.terminal')" = "true" ]
    [ "$(jqr '.live')" = "false" ]

    hrun state --handle "$NOSUCH" --cwd "$TREE"
    [ "$status" -eq 2 ]
    [ "$(jqr '.error')" = "handle_unknown" ]
    [ "$(jqr '.remedy')" != "null" ]
}

@test "await answers on a running job's bound, on a finished job at once, and refuses an unknown one" {
    start_job
    hrun await --handle "$HND" --cwd "$TREE" --deadline 2 --interval 1
    [ "$status" -eq 6 ]
    [ "$(jqr '.outcome')" = "deadline" ]

    finish_job degraded
    hrun await --handle "$HND" --cwd "$TREE" --deadline 30
    [ "$status" -eq 0 ]
    [ "$(jqr '.outcome')" = "terminal" ]
    [ "$(jqr '.state')" = "degraded" ]

    hrun await --handle "$NOSUCH" --cwd "$TREE" --deadline 30
    [ "$status" -eq 2 ]
    [ "$(jqr '.error')" = "handle_unknown" ]
}

@test "result is pending on a running job, reads the record on a finished one, and refuses an unknown one" {
    start_job
    hrun result --handle "$HND" --cwd "$TREE"
    [ "$status" -eq 2 ]
    [ "$(jqr '.error')" = "result_pending" ]
    [ "$(jqr '.remedy')" != "null" ]

    finish_job done
    write_result done true
    hrun result --handle "$HND" --cwd "$TREE"
    [ "$status" -eq 0 ]
    [ "$(jqr '.outcome')" = "result" ]
    [ "$(jqr '.deliverables_satisfied')" = "true" ]
    [ "$(jqr '.terminal_state')" = "done" ]
    # AGAINST ITS CONTRACT (R22): the contract COPY in the job directory rides
    # along, because the caller's own file can have been edited or deleted since
    # and the copy is what the supervisor measured against.
    [ "$(jqr '.contract.task')" = "make the suite green" ]
    [ "$(jqr '.contract.deliverables[0]')" = "report.md" ]
    # R19: the model's narrative keeps its own untrusted marking through the
    # relay, while the envelope around it stays plugin-authored.
    [ "$(jqr '.result.narrative.content_trust')" = "untrusted-third-party-model-output" ]
    [ "$(jqr '.content_trust')" = "plugin-authored" ]

    hrun result --handle "$NOSUCH" --cwd "$TREE"
    [ "$status" -eq 2 ]
    [ "$(jqr '.error')" = "handle_unknown" ]
}

@test "a terminal job that wrote no result record is result_missing, not a crash" {
    start_job
    finish_job failed
    refute_file_exists "$TREE/.spawn/$HND/result.json"
    hrun result --handle "$HND" --cwd "$TREE"
    [ "$status" -eq 2 ]
    [ "$(jqr '.error')" = "result_missing" ]
    [ "$(jqr '.remedy')" != "null" ]
}

@test "cancel stops a running job, is a no-op on a finished one, and refuses an unknown one" {
    start_job release
    hrun cancel --handle "$HND" --cwd "$TREE" --deadline 20
    [ "$status" -eq 0 ]
    [ "$(jqr '.outcome')" = "cancelled" ]
    [ "$(jqr '.cancelled')" = "true" ]
    [ "$(jqr '.signalled')" = "true" ]
    [ "$(jqr '.terminal_state')" = "cancelled" ]
    # ON DISK, not in the message: the record says cancelled and the one-job
    # lock is gone, so the worktree can take a new job.
    [ "$(jq -r '.state' < "$TREE/.spawn/$HND/status.json")" = "cancelled" ]
    refute_file_exists "$TREE/.spawn/lock"

    # The same job, now finished: cancelling it is a no-op at exit 0.
    hrun cancel --handle "$HND" --cwd "$TREE"
    [ "$status" -eq 0 ]
    [ "$(jqr '.outcome')" = "already_terminal" ]
    [ "$(jqr '.cancelled')" = "false" ]

    hrun cancel --handle "$NOSUCH" --cwd "$TREE"
    [ "$status" -eq 2 ]
    [ "$(jqr '.error')" = "handle_unknown" ]
}

# =========================================================================
# 2. Await returns on completion AND on its own bound, distinguishably
# =========================================================================

@test "await returns on completion and on its own bound, and the two are distinguishable" {
    start_job

    # THE BOUND. The job is still running when this returns, which is the whole
    # distinction: exit 6 says the deadline was reached, not the job.
    hrun await --handle "$HND" --cwd "$TREE" --deadline 2 --interval 1
    local bound_status="$status" bound_out="$output"
    [ "$bound_status" -eq 6 ]
    [ "$(printf '%s' "$bound_out" | jq -r '.error')" = "deadline_exceeded" ]
    [ "$(printf '%s' "$bound_out" | jq -r '.outcome')" = "deadline" ]
    [ "$(printf '%s' "$bound_out" | jq -r '.awaited')" = "false" ]
    [ "$(printf '%s' "$bound_out" | jq -r '.terminal')" = "false" ]
    [ "$(printf '%s' "$bound_out" | jq -r '.state')" = "running" ]
    [ "$(printf '%s' "$bound_out" | jq -r '.polls')" -ge 2 ]
    # The remedy must not be the shared "nothing is still running" one: here
    # something IS still running, and telling a caller otherwise is worse than
    # telling them nothing.
    printf '%s' "$bound_out" | jq -e '.remedy | test("still running"; "i")' >/dev/null
    # And it really is still running.
    kill -0 "$FAKE_PID" 2>/dev/null

    # COMPLETION, reached WHILE the await is blocked — not by finishing first
    # and then asking. A releaser lands in the background about a second in.
    ( sleep 1
      kill -9 "$FAKE_PID" 2>/dev/null
      bash "$JOBS" release --handle "$HND" --state done --cwd "$TREE" >/dev/null 2>&1 ) &

    hrun await --handle "$HND" --cwd "$TREE" --deadline 60 --interval 1
    local done_status="$status" done_out="$output"
    [ "$done_status" -eq 0 ]
    [ "$(printf '%s' "$done_out" | jq -r '.error')" = "null" ]
    [ "$(printf '%s' "$done_out" | jq -r '.outcome')" = "terminal" ]
    [ "$(printf '%s' "$done_out" | jq -r '.awaited')" = "true" ]
    [ "$(printf '%s' "$done_out" | jq -r '.terminal')" = "true" ]
    [ "$(printf '%s' "$done_out" | jq -r '.state')" = "done" ]

    # The two outcomes differ in the two places a caller can branch on: the
    # exit code and the `outcome` field. Asserted as a difference rather than
    # as two literals, because "distinguishable" is the requirement.
    [ "$bound_status" -ne "$done_status" ]
    [ "$(printf '%s' "$bound_out" | jq -r '.outcome')" != "$(printf '%s' "$done_out" | jq -r '.outcome')" ]
}

@test "await refuses a zero, negative or non-numeric bound rather than blocking forever" {
    start_job
    local bad
    for bad in 0 -1 abc 1.5 ""; do
        hrun await --handle "$HND" --cwd "$TREE" --deadline "$bad"
        [ "$status" -eq 2 ]
        [ "$(jqr '.error')" = "usage" ]
        [ "$(jqr '.help_requested')" = "false" ]
    done
    # A zero poll interval is a spin, and is refused for the same reason.
    hrun await --handle "$HND" --cwd "$TREE" --deadline 5 --interval 0
    [ "$status" -eq 2 ]
    [ "$(jqr '.error')" = "usage" ]
}

# =========================================================================
# 3. Expired is distinguishable from never-existed — and both from a crash
# =========================================================================

@test "an expired handle, an unknown handle and a crashed job are three different answers" {
    start_job
    finish_job done

    # EXPIRED: the record is here, terminal, and its status file is older than
    # the retention window. Backdated on disk rather than waited out.
    touch -t 200001010000 "$TREE/.spawn/$HND/status.json"
    hrun state --handle "$HND" --cwd "$TREE"
    [ "$status" -eq 2 ]
    [ "$(jqr '.error')" = "handle_expired" ]
    [ "$(jqr '.remedy')" != "null" ]
    # It is a retention judgement, not a deletion: the record is still there.
    [ -d "$TREE/.spawn/$HND" ]
    [ -f "$TREE/.spawn/$HND/status.json" ]

    # UNKNOWN: grammar-valid and nothing answers to it.
    hrun state --handle "$NOSUCH" --cwd "$TREE"
    [ "$status" -eq 2 ]
    [ "$(jqr '.error')" = "handle_unknown" ]

    # The two share an exit code — the enum is frozen — so `error` is the whole
    # of the distinction, and it must actually differ.
    hrun state --handle "$HND" --cwd "$TREE"
    local expired_err; expired_err="$(jqr '.error')"
    hrun state --handle "$NOSUCH" --cwd "$TREE"
    [ "$expired_err" != "$(jqr '.error')" ]

    # CRASHED: neither of the above. A supervisor killed outright leaves a
    # status file still claiming `running`, and the probe resolves it to failed
    # — a SUCCESSFUL answer a holder can read, not a refusal (KTD6).
    start_job
    [ "$(jq -r '.state' < "$TREE/.spawn/$HND/status.json")" = "running" ]
    kill -9 "$FAKE_PID" 2>/dev/null
    wait "$FAKE_PID" 2>/dev/null || true
    hrun state --handle "$HND" --cwd "$TREE"
    [ "$status" -eq 0 ]
    [ "$(jqr '.error')" = "null" ]
    [ "$(jqr '.state')" = "failed" ]
    [ "$(jqr '.job.state_source')" = "probe" ]
    [ "$(jqr '.job.claimed_state')" = "running" ]
}

@test "expiry never touches a job that is still running, however long it has been running" {
    start_job
    # A long job's status file has not been rewritten since it was adopted, and
    # that must never read as expired: only a TERMINAL record can expire.
    touch -t 200001010000 "$TREE/.spawn/$HND/status.json"
    hrun state --handle "$HND" --cwd "$TREE"
    [ "$status" -eq 0 ]
    [ "$(jqr '.state')" = "running" ]
    [ "$(jqr '.expired')" = "false" ]
}

@test "the retention window is the knob, and every operation honours it" {
    start_job
    finish_job done
    write_result done true
    touch -t 200001010000 "$TREE/.spawn/$HND/status.json"

    # Widen it and the record answers again — proof the refusal is retention and
    # not something else about the record.
    SPAWN_JOB_RETENTION=999999999 hrun state --handle "$HND" --cwd "$TREE"
    [ "$status" -eq 0 ]
    [ "$(jqr '.state')" = "done" ]

    local verb
    for verb in state result cancel; do
        hrun "$verb" --handle "$HND" --cwd "$TREE"
        [ "$status" -eq 2 ]
        [ "$(jqr '.error')" = "handle_expired" ]
    done
    hrun await --handle "$HND" --cwd "$TREE" --deadline 5
    [ "$status" -eq 2 ]
    [ "$(jqr '.error')" = "handle_expired" ]
}

# =========================================================================
# 4. Every operation's response carries the envelope
# =========================================================================

@test "every operation carries the shared envelope, on success and on refusal" {
    start_job

    # Success and refusal for each of the four, plus the two bounded outcomes.
    hrun state --handle "$HND" --cwd "$TREE"
    [ "$status" -eq 0 ]; printf '%s' "$output" | has_envelope
    [ "$(jqr '.schema')" = "spawn.response/v1" ]
    [ "$(jqr '.content_trust')" = "plugin-authored" ]

    hrun await --handle "$HND" --cwd "$TREE" --deadline 2 --interval 1
    [ "$status" -eq 6 ]; printf '%s' "$output" | has_envelope
    [ "$(jqr '.remedy')" != "null" ]
    [ "$(jqr '.detail')" != "null" ]

    hrun result --handle "$HND" --cwd "$TREE"
    [ "$status" -eq 2 ]; printf '%s' "$output" | has_envelope

    local v
    for v in state await result cancel; do
        hrun "$v" --handle "$NOSUCH" --cwd "$TREE" --deadline 5
        [ "$status" -eq 2 ]
        printf '%s' "$output" | has_envelope
        [ "$(jqr '.remedy')" != "null" ]
        [ "$(jqr '.help_requested')" = "false" ]
        [ "$(jqr '.exit_code')" = "2" ]
        [ "$(jqr '.ok')" = "false" ]
    done

    finish_job done
    write_result done true
    for v in state result cancel; do
        hrun "$v" --handle "$HND" --cwd "$TREE"
        [ "$status" -eq 0 ]
        printf '%s' "$output" | has_envelope
        [ "$(jqr '.ok')" = "true" ]
        [ "$(jqr '.error')" = "null" ]
        [ "$(jqr '.exit_code')" = "0" ]
        # One JSON object on stdout, always.
        [ "$(printf '%s' "$output" | jq -s 'length')" = "1" ]
    done
}

@test "R23/KTD7: with jq ABSENT the handle layer still emits one parseable envelope" {
    # RESOLVED BEFORE the PATH is narrowed — a lookup made afterwards would find
    # whatever the narrowed PATH holds, which is the trap that made an earlier
    # unit's live arms measure a fixture.
    local d="$WORK/nojq" t p
    mkdir -p "$d"
    for t in bash sh sed awk grep cat wc tr cut head tail sort mktemp dirname \
             basename mkdir rm cp mv ln chmod find kill sleep date git ps pgrep stat touch; do
        p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$d/$t"
    done

    # Proof the harness tests what it claims: jq really is unreachable.
    run env PATH="$d" bash -c 'command -v jq 2>/dev/null'
    [ "$status" -ne 0 ]

    # need_jq's hand-written string is a THIRD encoder, reached before any verb
    # runs, and it is the one most easily forgotten.
    run env PATH="$d" bash -c "bash '$HANDLE_SH' state --handle '$NOSUCH' --cwd '$TREE' 2>/dev/null"
    [ "$status" -eq 2 ]
    [ "$(printf '%s' "$output" | jq -s 'length')" = "1" ]
    printf '%s' "$output" | has_envelope
    [ "$(jqr '.schema')" = "spawn.response/v1" ]
    [ "$(jqr '.ok')" = "false" ]
    [ "$(jqr '.error')" = "internal" ]
    [ "$(jqr '.remedy')" != "null" ]
    [ "$(jqr '.verb')" = "state" ]

    run env PATH="$d" bash -c "bash '$HANDLE_SH' --help 2>/dev/null"
    [ "$status" -eq 2 ]
    printf '%s' "$output" | has_envelope
    [ "$(jqr '.content_trust')" = "plugin-authored" ]
}

# =========================================================================
# 5. Cancel is idempotent
# =========================================================================

@test "cancelling an already-terminal job is a no-op at exit 0, for each terminal state" {
    local st
    for st in done degraded failed cancelled; do
        start_job
        finish_job "$st"
        hrun cancel --handle "$HND" --cwd "$TREE"
        [ "$status" -eq 0 ]
        [ "$(jqr '.ok')" = "true" ]
        [ "$(jqr '.outcome')" = "already_terminal" ]
        [ "$(jqr '.cancelled')" = "false" ]
        [ "$(jqr '.signalled')" = "false" ]
        [ "$(jqr '.terminal_state')" = "$st" ]
        # The record it was already in is not rewritten by asking again.
        [ "$(jq -r '.state' < "$TREE/.spawn/$HND/status.json")" = "$st" ]
    done
}

@test "cancelling twice is safe: the second call is a no-op and changes nothing on disk" {
    start_job release
    hrun cancel --handle "$HND" --cwd "$TREE" --deadline 20
    [ "$status" -eq 0 ]
    [ "$(jqr '.cancelled')" = "true" ]
    local ended; ended="$(jq -r '.ended_at' < "$TREE/.spawn/$HND/status.json")"

    hrun cancel --handle "$HND" --cwd "$TREE" --deadline 20
    [ "$status" -eq 0 ]
    [ "$(jqr '.cancelled')" = "false" ]
    [ "$(jqr '.outcome')" = "already_terminal" ]
    # Byte-for-byte the same record: a second cancel must not restamp the end.
    [ "$(jq -r '.ended_at' < "$TREE/.spawn/$HND/status.json")" = "$ended" ]
}

@test "a cancel that is signalled but not confirmed reports the bound, and cancelling again is still safe" {
    start_job deaf
    hrun cancel --handle "$HND" --cwd "$TREE" --deadline 2
    [ "$status" -eq 6 ]
    [ "$(jqr '.error')" = "cancel_unconfirmed" ]
    [ "$(jqr '.signalled')" = "true" ]
    [ "$(jqr '.cancelled')" = "false" ]
    [ "$(jqr '.remedy')" != "null" ]
    printf '%s' "$output" | has_envelope
    # Nothing was written behind the supervisor's back: the record still says
    # what the supervisor last said, and the worktree is still locked by it.
    [ "$(jq -r '.state' < "$TREE/.spawn/$HND/status.json")" = "running" ]
    [ -d "$TREE/.spawn/lock" ]

    hrun cancel --handle "$HND" --cwd "$TREE" --deadline 2
    [ "$status" -eq 6 ]
    [ "$(jqr '.error')" = "cancel_unconfirmed" ]
}

@test "KTD2: cancel never writes a terminal state itself, so it cannot drop the lock under a launcher" {
    # A claim with no supervisor adopted yet — the millisecond window between
    # `claim` and `adopt`. Recording `cancelled` here would drop the one-job
    # lock while the launcher is still spawning, and a second job could claim
    # the same worktree. Refused instead, and it resolves itself: an unadopted
    # claim goes failed on its own once the grace window passes.
    jrun claim --contract "$CONTRACT" --cwd "$TREE"
    [ "$status" -eq 0 ]
    HND="$(jqr '.handle')"

    hrun cancel --handle "$HND" --cwd "$TREE"
    [ "$status" -eq 2 ]
    [ "$(jqr '.error')" = "job_starting" ]
    [ "$(jqr '.remedy')" != "null" ]
    # The lock is untouched and the record still says what the launcher wrote.
    [ -d "$TREE/.spawn/lock" ]
    [ "$(jq -r '.state' < "$TREE/.spawn/$HND/status.json")" = "starting" ]

    # And it is not a wedge: once the claim grace passes the job resolves
    # failed, which is terminal, which makes cancel the no-op it should be.
    # Aged on DISK rather than by shrinking the grace to zero: the record layer
    # turns its grace into `find -mmin -<n>`, and BSD find reads `-mmin -0` as
    # "exactly 0" where GNU reads it as "less than 0" — a knob that means two
    # different things on two boxes is not a knob a test can stand on.
    touch -t 200001010000 "$TREE/.spawn/$HND"
    hrun state --handle "$HND" --cwd "$TREE"
    [ "$status" -eq 0 ]
    [ "$(jqr '.state')" = "failed" ]
    hrun cancel --handle "$HND" --cwd "$TREE"
    [ "$status" -eq 0 ]
    [ "$(jqr '.outcome')" = "already_terminal" ]
}

@test "cancel signals only a pid whose argv still carries this job's marker" {
    start_job
    # Point the record at a pid that is alive but is NOT this job — the shape a
    # recycled pid takes. The whole-field argv check is what stands between a
    # cancel and a SIGTERM to an unrelated process.
    sleep 120 &
    local other=$!
    bash "$JOBS" adopt --handle "$HND" --pid "$other" --cwd "$TREE" >/dev/null 2>&1

    hrun cancel --handle "$HND" --cwd "$TREE" --deadline 2
    # The record layer's own probe resolves a pid that does not carry the marker
    # to `failed` (KTD6) — which is TERMINAL, so cancel is the no-op it is for
    # any other terminal job. The property being pinned is not the exit code but
    # what did NOT happen: no signal reached the unrelated process.
    [ "$status" -eq 0 ]
    [ "$(jqr '.outcome')" = "already_terminal" ]
    [ "$(jqr '.signalled')" = "false" ]
    [ "$(jqr '.terminal_state')" = "failed" ]
    kill -0 "$other" 2>/dev/null
    kill -9 "$other" 2>/dev/null
    wait "$other" 2>/dev/null || true
}

# =========================================================================
# The agent-facing contract: --describe and --help (R10, R11)
# =========================================================================

@test "--describe answers at exit 0 with no job and no gateway, and stays inside the frozen enum" {
    hrun --describe
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -s 'length')" = "1" ]
    [ "$(jqr '.ok')" = "true" ]
    [ "$(jqr '.response_kind')" = "describe" ]
    [ "$(jqr '.surface')" = "handle.sh" ]
    printf '%s' "$output" | has_envelope
    # KTD8's closed set, as data rather than as prose in a comment.
    [ "$(printf '%s' "$output" | jq -c '.terminal_states')" = '["done","degraded","failed","cancelled"]' ]
    # The frozen enum: nothing here may declare a code outside {0,2,3,4,5,6,7}.
    [ "$(printf '%s' "$output" | jq -c '[.exit_codes[].code] | map(. as $c | [0,2,3,4,5,6,7] | index($c) != null) | all')" = "true" ]
    # Every declared error names a remedy, and the four verbs are all declared.
    [ "$(printf '%s' "$output" | jq -c '[.error_values[] | select(.remedy == null or .remedy == "")] | length')" = "0" ]
    [ "$(printf '%s' "$output" | jq -c '[.verbs[].name] | sort')" = '["await","cancel","result","state"]' ]
    # The bound a Bash-only caller has to plan around is stated as a number, not
    # as prose it would have to parse.
    [ "$(printf '%s' "$output" | jq -r '.verbs[] | select(.name=="await") | .deadline_default')" -gt 0 ]
    # Reading it left nothing behind.
    refute_file_exists "$TREE/.spawn"
}

@test "R11: --help is exit 2 with help_requested true, and a caller mistake is exit 2 with it false" {
    hrun --help
    [ "$status" -eq 2 ]
    [ "$(jqr '.error')" = "usage" ]
    [ "$(jqr '.help_requested')" = "true" ]
    printf '%s' "$output" | has_envelope

    hrun bogusverb --handle "$NOSUCH"
    [ "$status" -eq 2 ]
    [ "$(jqr '.error')" = "usage" ]
    [ "$(jqr '.help_requested')" = "false" ]

    hrun state --cwd "$TREE"
    [ "$status" -eq 2 ]
    [ "$(jqr '.error')" = "usage" ]
    [ "$(jqr '.help_requested')" = "false" ]
}

@test "a malformed handle is refused by the grammar before any path is built from it" {
    hrun state --handle "../../etc" --cwd "$TREE"
    [ "$status" -eq 2 ]
    [ "$(jqr '.error')" = "usage" ]
    refute_file_exists "$TREE/.spawn/../../etc"
}

@test "diagnostics go to stderr and stdout stays exactly one JSON object" {
    start_job
    # A verb that says() something: the await bound prints a diagnostic.
    hrun await --handle "$HND" --cwd "$TREE" --deadline 2 --interval 1
    [ "$status" -eq 6 ]
    [ "$(printf '%s' "$output" | jq -s 'length')" = "1" ]
    refute_output_match "▸"
    grep -q "await bound" "$WORK/err.log"
}

# =========================================================================
# The unit's own verification line: a Bash-only caller can poll to completion
# using only --describe and the handle.
# =========================================================================

@test "a Bash-only caller polls a job to completion using only --describe and the handle" {
    start_job

    # Everything the caller knows, it reads out of the contract document: which
    # verb to call, which states are terminal, and what the two await outcomes
    # mean. Nothing is hard-coded from this file's knowledge of the script.
    local doc; doc="$(bash "$HANDLE_SH" --describe 2>/dev/null)"
    local awaitverb terminals
    awaitverb="$(printf '%s' "$doc" | jq -r '.verbs[] | select(.name=="await") | .name')"
    terminals="$(printf '%s' "$doc" | jq -r '.terminal_states | join(" ")')"
    [ -n "$awaitverb" ]
    [ -n "$terminals" ]

    ( sleep 1
      kill -9 "$FAKE_PID" 2>/dev/null
      bash "$JOBS" release --handle "$HND" --state done --cwd "$TREE" >/dev/null 2>&1 ) &

    # The loop a Bash-only caller writes: bounded await, and exit 6 means go
    # round again. It cannot spin forever, because each pass has a deadline.
    local rc=6 out="" tries=0 st=""
    while [ "$rc" -eq 6 ] && [ "$tries" -lt 10 ]; do
        out="$(bash "$HANDLE_SH" "$awaitverb" --handle "$HND" --cwd "$TREE" --deadline 5 --interval 1 2>/dev/null)"
        rc=$?
        tries=$(( tries + 1 ))
    done
    [ "$rc" -eq 0 ]
    st="$(printf '%s' "$out" | jq -r '.state')"
    # The state it landed in is one the contract declared terminal.
    printf '%s' "$terminals" | grep -qw "$st"
    [ "$(printf '%s' "$out" | jq -r '.terminal')" = "true" ]
}
