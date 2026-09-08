#!/usr/bin/env bash
# handle.sh — what a holder can DO with a background job handle (plan U10, R22).
#
#   handle.sh state  --handle <id> [--cwd <dir>]        what is this job doing
#   handle.sh await  --handle <id> [--deadline <s>]     block until terminal, BOUNDED
#                    [--interval <s>]
#   handle.sh result --handle <id> [--cwd <dir>]        the supervisor's record,
#                                                       measured against the contract
#   handle.sh cancel --handle <id> [--deadline <s>]     stop it; idempotent
#
# WHAT THIS FILE IS
# -----------------
# The four operations R22 names, and nothing else. It is the layer a Bash-only
# caller reaches: `bg-agent.sh` hands back a handle and exits, `jobs.sh` owns the
# on-disk record, and neither of them answers "is it done yet" in a shape a
# caller can loop on without inventing a protocol of its own.
#
# It ADDS to those layers and changes neither. The record layer is SHELLED OUT
# TO, never sourced — jobs.sh runs its argument parser and dispatch
# unconditionally at the bottom of the file, so sourcing it from here would run
# a verb, exactly as U9 measured. Cancellation is delivered as a SIGNAL to the
# supervisor, which already owns the reap, the result and the release; nothing
# here writes a terminal state behind the supervisor's back.
#
# THE BOUND ON `await` IS THE POINT (plan: "an unbounded await is a deadlock").
# The caller this exists for holds `Bash, Read` and cannot receive a
# notification — it can only block or poll, and a block with no deadline is a
# session that never comes back. So `await` always has a deadline and its two
# outcomes are told apart by EXIT CODE:
#
#   exit 0  the job reached a terminal state    outcome:"terminal"
#   exit 6  the bound was hit, job still runs   outcome:"deadline"
#
# UNKNOWN vs EXPIRED vs CRASHED — three different answers (R22):
#
#   handle_unknown   no job directory answers to that handle under this
#                    worktree. It was never started here, or it was started in a
#                    different worktree; the record is per worktree, not global.
#   handle_expired   the record IS here, it is terminal, and its status file is
#                    older than the retention window (SPAWN_JOB_RETENTION). The
#                    job ran; its result may have been reclaimed since.
#   state "failed"   NOT an error at all — a successful `state` answer. A job
#                    whose supervisor died is resolved failed by probe (KTD6),
#                    and a crash is something the holder can read, not something
#                    the call refuses to answer.
#
# A record REMOVED from disk is indistinguishable from one that never existed,
# which is why expiry marks a record rather than deleting one. Nothing in this
# file removes a job directory.
#
# CONTRACT (frozen with the rest of the plugin):
#   exactly one JSON object on stdout, always; diagnostics on stderr only.
#   exit 0 ok · 2 usage/refusal · 3 unreachable · 4 alias unknown ·
#        5 upstream error · 6 deadline exceeded · 7 auth rejected.
# A new failure class gets a new `error` STRING, never a new code — hence
# handle_expired, result_pending, result_missing and job_starting all riding
# exit 2, and await's bound riding the 6 that already means "a deadline".
#
# set -e is deliberately OFF (only -u -o pipefail): a classified exit code must
# not become an unclassified 1.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./sanitize.sh
. "$SCRIPT_DIR/sanitize.sh"
# shellcheck source=./common.sh
. "$SCRIPT_DIR/common.sh"

JOBS="$SCRIPT_DIR/jobs.sh"

# ---------------------------------------------------------------------------
# Contract constants
# ---------------------------------------------------------------------------
EX_OK=0
EX_USAGE=2
EX_DEADLINE=6

SPAWN_HANDLE_SCHEMA="spawn.handle/v1"

JOB_TERMINAL_STATES="done degraded failed cancelled"

# ---------------------------------------------------------------------------
# Configuration surface. Env-overridable so a test owns the whole tree and a
# caller can widen a bound without editing the file.
# ---------------------------------------------------------------------------
# How long `await` may block before it answers "not yet" instead of blocking on.
AWAIT_DEADLINE_DEFAULT="${SPAWN_AWAIT_DEADLINE:-300}"
# How often it re-probes inside that bound. Every poll is a `kill -0` plus a
# `ps` read — cheap, and nothing here reaches the network.
AWAIT_INTERVAL_DEFAULT="${SPAWN_AWAIT_INTERVAL:-2}"
# How long `cancel` waits for the signalled supervisor to reap its child and
# record a terminal state before it reports the signal delivered but unconfirmed.
CANCEL_DEADLINE_DEFAULT="${SPAWN_CANCEL_DEADLINE:-15}"
# How long a terminal record stays answerable. A week, because a job started on
# a Friday must still be readable on the following Friday. Measured on the
# status file's mtime with find -mmin, the same age idiom the record layer uses
# for its claim grace — parsing an ISO timestamp in bash means two incompatible
# date(1) dialects and a portability trap for no gain.
RETENTION="${SPAWN_JOB_RETENTION:-604800}"

# ---------------------------------------------------------------------------
# Plumbing
# ---------------------------------------------------------------------------
# Every human-readable diagnostic goes through say() or die(), and both
# sanitize. A job's own log and the detail a supervisor recorded are written by
# the child and are as untrusted as any model output, so a diagnostic quoting
# either reaches the terminal only through these two chokepoints. The lint in
# tests/unit/escapes.bats iterates lib/*.sh and reads these exact lines.
EMITTED=0

# R11 — the help discriminator. `--help` and a caller mistake are both exit 2
# with error:"usage" because the enum is frozen; this field is the distinction
# as data, on both encoder tiers.
HELP_REQUESTED=false

VERB=""
HANDLE=""

# R12 — this file's own error vocabulary, falling through to the shared table.
# Keyed on the ENUM, never on the call site.
#
# No word in this table names an amount of money or a rate limit knob — the
# enumerated lint in tests/unit/lens.bats covers this script, and it reads the
# source, not the intent.
remedy_for() {
    case "$1" in
        handle_unknown)
            printf 'No job answers to that handle under this worktree. Check the handle, and check you are asking from the same worktree the job was started in — the record is per worktree, not global.' ;;
        handle_expired)
            printf 'The job ran and finished, but its record is older than the retention window and may have been reclaimed. Nothing is still running under that handle. Raise SPAWN_JOB_RETENTION if you need older records to stay answerable, or read the job directory named in `detail` directly if it is still there.' ;;
        deadline_exceeded)
            printf 'The await bound was hit and the job is STILL RUNNING — nothing was stopped and nothing was lost. Await again with a longer --deadline, query `state`, or `cancel` it.' ;;
        result_pending)
            printf 'The job has not reached a terminal state, so there is no result to read yet. Await it (`await --handle <id> --deadline <s>`) and read the result once it is terminal.' ;;
        result_missing)
            printf 'The job is terminal but wrote no result record, which means its supervisor died before it could measure anything. Read the job log for what it managed to do; the job is not running and nothing is orphaned.' ;;
        job_starting)
            printf 'The job has been claimed but no supervisor pid is recorded yet, so there is nothing to signal. Try again in a moment: a claim that is never adopted resolves failed on its own once the grace window passes, and a failed job is already terminal.' ;;
        cancel_unconfirmed)
            printf 'The stop signal was delivered but the job had not recorded a terminal state before the bound. It is being reaped; query `state` again, or `cancel` again with a longer --deadline. Cancelling twice is safe.' ;;
        *) spawn::remedy_for "$1" ;;
    esac
}

need_jq() {
    command -v jq >/dev/null 2>&1 || {
        printf '✗ jq is required (the contract is one JSON object on stdout)\n' >&2
        emit "$(spawn::envelope_bash plugin "internal" 2 ",\"verb\":\"${VERB//[^a-z-]/}\",\"handle\":null,\"job\":null,\"help_requested\":false" "Install jq and re-run. The plugin's contract is one JSON object on stdout, and jq is what encodes it.")"
        exit 2
    }
}

# ---------------------------------------------------------------------------
# Grammar. Validated BEFORE any path is built from it or any handle is handed to
# the record layer, so a handle carrying a slash or a shell metacharacter is
# refused rather than filtered. Same expression the record layer enforces: the
# two must agree, or a handle this file accepted would be refused one layer down
# with a message about a grammar the caller was never shown.
# ---------------------------------------------------------------------------
# A bound is a positive whole number of seconds. ZERO IS REFUSED rather than
# read as "check once": the same guard the lens applies to --timeout 0, and an
# await with no wait in it is `state` under another name.
validate_seconds() {   # <value> <flag name>
    [[ "$2" =~ ^[0-9]+$ ]] && [ "$2" -gt 0 ] \
        || die "$EX_USAGE" "usage" "$1 must be a whole number of seconds greater than zero"
}

validate_interval() {  # <value>
    [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]] \
        || die "$EX_USAGE" "usage" "--interval must be a number of seconds"
    case "$1" in 0|0.|0.0|0.00|0.000) die "$EX_USAGE" "usage" "--interval must be greater than zero — a poll with no gap is a spin" ;; esac
}

# ---------------------------------------------------------------------------
# The record layer, shelled out to (never sourced — its dispatch runs
# unconditionally). One call site, so every verb here reads the record the same
# way and a change to the invocation cannot reach three of the four.
#
# Sets JOB_JSON, JOB_RC. Diagnostics from the record layer are dropped rather
# than relayed: this file re-classifies what it got and says its own piece.
# ---------------------------------------------------------------------------
JOB_JSON=""
JOB_RC=0
read_record() {   # <handle>
    JOB_JSON="$(bash "$JOBS" state --handle "$1" --cwd "$WORKTREE_ARG" 2>/dev/null)"
    JOB_RC=$?
    [ -n "$JOB_JSON" ] || return 1
    return 0
}

jf() {   # <jq filter> — one field out of the record we last read
    printf '%s' "$JOB_JSON" | jq -r "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Load the record, and classify the three answers a bad handle can have.
#
# The record layer answers `handle_unknown` when no directory exists. Expiry is
# decided HERE, because it is a retention judgement about how long an answer
# stays useful, not a fact about the record's structure — and putting it in the
# record layer would make the supervisor's own state calls expire mid-job.
#
# Sets: JOB_STATE, JOB_DIR, JOB_PID, JOB_LIVE, JOB_MARKER.
# ---------------------------------------------------------------------------
JOB_STATE=""
JOB_DIR=""
JOB_PID=""
JOB_LIVE="false"
JOB_MARKER=""
load_job() {
    validate_handle "$HANDLE"
    if ! read_record "$HANDLE"; then
        die "$EX_USAGE" "internal" "the record layer answered nothing for handle '$HANDLE'"
    fi
    if [ "$JOB_RC" -ne 0 ]; then
        local err; err="$(jf '.error // "internal"')"
        case "$err" in
            handle_unknown)
                die "$EX_USAGE" "handle_unknown" "no job answers to handle '$HANDLE' under this worktree" ;;
            *)
                REMEDY="$(remedy_for "$err")" \
                die "$EX_USAGE" "$err" "the record layer refused this handle: $(jf '.detail // ""')" ;;
        esac
    fi
    JOB_STATE="$(jf '.job.state // ""')"
    JOB_DIR="$(jf '.job.job_dir // ""')"
    JOB_PID="$(jf '.job.pid // ""')"
    JOB_LIVE="$(jf '.job.live // false')"
    JOB_MARKER="$(jf '.job.argv_marker // ""')"
    [ "$JOB_PID" = "null" ] && JOB_PID=""

    # EXPIRY. Only a terminal record can expire: a running job is answerable
    # however long it has been running, and a status file that has not been
    # rewritten for a week is exactly what a long job looks like.
    if is_terminal "$JOB_STATE" && [ "$RETENTION" -ge 0 ] 2>/dev/null; then
        local sf mins
        sf="$JOB_DIR/status.json"
        mins=$(( (RETENTION + 59) / 60 ))
        if [ -f "$sf" ] && [ -z "$(find "$sf" -maxdepth 0 -mmin "-$mins" 2>/dev/null)" ]; then
            die "$EX_USAGE" "handle_expired" "the record for '$HANDLE' is terminal ($JOB_STATE) and older than the ${RETENTION}s retention window; its directory is $JOB_DIR"
        fi
    fi
}

# The response. One builder, so `state`, `await`, `result` and `cancel` cannot
# describe the same record four different ways — which is how a caller ends up
# branching on which verb answered.
#
# $1 = exit code, $2 = a jq object fragment of this verb's own fields (may be
# "{}"). The job record is relayed VERBATIM from the record layer: this file is
# not a second opinion about what state a job is in.
emit_handle() {
    local code="$1" extra="$2"
    local job; job="$(printf '%s' "$JOB_JSON" | jq -c '.job // null' 2>/dev/null)"
    [ -n "$job" ] || job='null'
    # `terminal` is decided in bash from the same closed set the verbs branch on,
    # rather than re-derived in the encoder: two definitions of the four terminal
    # states is how a fifth one gets added to only one of them.
    local tm=false
    is_terminal "$JOB_STATE" && tm=true
    emit "$(jq -nc --arg v "$VERB" --arg h "$HANDLE" --arg hs "$SPAWN_HANDLE_SCHEMA" \
        --argjson j "$job" --argjson c "$code" --argjson tm "$tm" \
        "$(spawn::envelope_jq plugin)"' + {
          ok:true, error:null, remedy:null, exit_code:$c,
          handle_schema:$hs, verb:$v, handle:$h, help_requested:false,
          state:$j.state, terminal:$tm, live:$j.live, job:$j
        } + '"$extra")" \
        || die "$EX_USAGE" "internal" "could not encode the handle response"
}

# ---------------------------------------------------------------------------
# Verbs
# ---------------------------------------------------------------------------

do_state() {
    [ -n "$HANDLE" ] || die "$EX_USAGE" "usage" "state needs --handle <id>"
    load_job
    local res="false"
    [ -f "$JOB_DIR/result.json" ] && res="true"
    emit_handle 0 "{outcome:\"state\", result_available:$res, expired:false}"
    exit "$EX_OK"
}

do_await() {
    [ -n "$HANDLE" ] || die "$EX_USAGE" "usage" "await needs --handle <id>"
    # A flag that was GIVEN is validated, even when it was given empty: an
    # empty --deadline silently falling back to the default is a bound the
    # caller never chose, and the whole point of the flag is that the caller
    # owns how long it is willing to block.
    local deadline="$AWAIT_DEADLINE_DEFAULT" interval="$AWAIT_INTERVAL_DEFAULT"
    [ "$DEADLINE_SET" = true ] && deadline="$DEADLINE_ARG"
    [ "$INTERVAL_SET" = true ] && interval="$INTERVAL_ARG"
    validate_seconds "--deadline" "$deadline"
    validate_interval "$interval"

    load_job
    local start="$SECONDS" polls=1 waited=0
    while :; do
        if is_terminal "$JOB_STATE"; then
            waited=$(( SECONDS - start ))
            local res="false"
            [ -f "$JOB_DIR/result.json" ] && res="true"
            emit_handle 0 "{outcome:\"terminal\", awaited:true, deadline_seconds:$deadline, waited_seconds:$waited, polls:$polls, result_available:$res, expired:false}"
            exit "$EX_OK"
        fi
        waited=$(( SECONDS - start ))
        [ "$waited" -ge "$deadline" ] && break
        sleep "$interval"
        polls=$(( polls + 1 ))
        # A handle that vanished mid-await (its worktree wiped under us) is a
        # refusal, not a silent loop to the deadline — load_job dies on it.
        load_job
    done

    # THE BOUND, not the job. Distinguishable by exit code and by `outcome`, and
    # the job is still running: this response is the only one in the file whose
    # ok:false does not mean something went wrong.
    waited=$(( SECONDS - start ))
    say "the await bound of ${deadline}s passed and $HANDLE is still $JOB_STATE"
    local rem; rem="$(remedy_for deadline_exceeded)"
    emit "$(jq -nc --arg v "$VERB" --arg h "$HANDLE" --arg hs "$SPAWN_HANDLE_SCHEMA" \
        --arg s "$JOB_STATE" --arg r "$rem" \
        --argjson j "$(printf '%s' "$JOB_JSON" | jq -c '.job // null')" \
        --argjson d "$deadline" --argjson w "$waited" --argjson p "$polls" \
        "$(spawn::envelope_jq plugin)"' + {
          ok:false, error:"deadline_exceeded", remedy:$r, exit_code:6,
          detail:("the await bound of " + ($d|tostring) + "s passed with the job still " + $s + " — the bound was reached, not the job"),
          handle_schema:$hs, verb:$v, handle:$h, help_requested:false,
          outcome:"deadline", awaited:false, deadline_seconds:$d,
          waited_seconds:$w, polls:$p, expired:false,
          state:$s, terminal:false, live:$j.live, job:$j
        }')" || die "$EX_USAGE" "internal" "could not encode the await response"
    exit "$EX_DEADLINE"
}

do_result() {
    [ -n "$HANDLE" ] || die "$EX_USAGE" "usage" "result needs --handle <id>"
    load_job
    is_terminal "$JOB_STATE" \
        || die "$EX_USAGE" "result_pending" "the job is $JOB_STATE, so the supervisor has not measured anything yet"
    local rf="$JOB_DIR/result.json"
    [ -f "$rf" ] \
        || die "$EX_USAGE" "result_missing" "the job is $JOB_STATE but wrote no result record in $JOB_DIR"
    local result; result="$(jq -c . < "$rf" 2>/dev/null)"
    [ -n "$result" ] \
        || die "$EX_USAGE" "result_missing" "the result record in $JOB_DIR is not readable as one JSON object"

    # The contract the job was started against, relayed from the COPY in the job
    # directory. The caller's own file can have been edited or deleted since;
    # the copy is what the supervisor measured against, so it is what a holder
    # checking the result must be shown.
    local contract='null'
    if [ -f "$JOB_DIR/contract" ]; then
        contract="$(jq -c . < "$JOB_DIR/contract" 2>/dev/null)"
        [ -n "$contract" ] || contract='null'
    fi
    # Lifted out of the encoder rather than re-derived from the embedded object:
    # `deliverables_satisfied` is the field a caller branches on to decide
    # whether the contract was met, and it must read the same whether it is
    # taken from the top level or from inside `result`.
    local satisfied tstate
    satisfied="$(printf '%s' "$result" | jq -c '.deliverables_satisfied // false' 2>/dev/null)"
    [ -n "$satisfied" ] || satisfied=false
    tstate="$(printf '%s' "$result" | jq -r '.terminal_state // ""' 2>/dev/null)"
    [ -n "$tstate" ] || tstate="$JOB_STATE"

    # Built with jq rather than by string-pasting: the paths in it come from the
    # worktree, and a directory name carrying a quote would otherwise be pasted
    # straight into the program text. A jq object is also valid jq program text,
    # so the fragment merges exactly as a hand-written one would.
    local extra
    extra="$(jq -nc --arg rf "$rf" --arg cf "$JOB_DIR/contract" \
        --argjson ct "$contract" --argjson r "$result" \
        --argjson sat "$satisfied" --arg ts "$tstate" \
        '{outcome:"result", expired:false, result_available:true,
          result_file:$rf, contract_file:$cf, contract:$ct, result:$r,
          deliverables_satisfied:$sat, terminal_state:$ts}')" \
        || die "$EX_USAGE" "internal" "could not encode the result payload"
    emit_handle 0 "$extra"
    exit "$EX_OK"
}

# The pid is re-verified with a WHOLE-FIELD argv match immediately before the
# signal, not just at the record layer's probe a moment earlier. Between the two
# the pid can be recycled onto an unrelated process, and the cost of the
# substring form here is not a wrong answer but a SIGTERM to somebody else's
# process. Same shape as the record layer's own check, deliberately duplicated
# rather than sourced: that file cannot be sourced without running a verb.
pid_still_is_job() {   # <pid> <marker>
    local pid="$1" marker="$2" args
    [ -n "$pid" ] && [ -n "$marker" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    args="$(ps -o args= -p "$pid" 2>/dev/null | head -1)"
    [ -n "$args" ] || return 1
    awk -v a="$args" -v m="$marker" 'BEGIN{
        n = split(a, f, " ")
        for (i = 1; i <= n; i++) if (f[i] == m) exit 0
        exit 1
    }'
}

do_cancel() {
    [ -n "$HANDLE" ] || die "$EX_USAGE" "usage" "cancel needs --handle <id>"
    local deadline="$CANCEL_DEADLINE_DEFAULT"
    [ "$DEADLINE_SET" = true ] && deadline="$DEADLINE_ARG"
    validate_seconds "--deadline" "$deadline"
    load_job

    # IDEMPOTENT. Cancelling a job that is already terminal is a no-op and a
    # SUCCESS, not an error: the holder asked for it to be stopped and it is
    # stopped. An error here would make every retry-after-timeout loop have to
    # tell "already done" apart from "could not cancel", which is the branch
    # this answer removes.
    if is_terminal "$JOB_STATE"; then
        emit_handle 0 "{outcome:\"already_terminal\", cancelled:false, signalled:false,
            already_terminal:true, expired:false, terminal_state:\"$JOB_STATE\"}"
        exit "$EX_OK"
    fi

    # Claimed but not yet adopted: there is no supervisor pid to signal, and
    # writing a terminal state from here would drop the one-job lock out from
    # under a launcher that is still mid-spawn — two jobs in one worktree, which
    # is the one thing the lock exists to prevent. Refused instead, and it
    # resolves itself: an unadopted claim goes failed on its own once the record
    # layer's grace window passes, and failed is terminal.
    if [ -z "$JOB_PID" ] || [ "$JOB_LIVE" != "true" ]; then
        die "$EX_USAGE" "job_starting" "the job is $JOB_STATE with no live supervisor recorded, so there is nothing to signal"
    fi
    pid_still_is_job "$JOB_PID" "$JOB_MARKER" \
        || die "$EX_USAGE" "job_starting" "the recorded pid $JOB_PID no longer carries this job's argv marker, so it was not signalled"

    # TERM, never KILL. The supervisor traps it and owns what has to happen
    # next: reap the child, write the result, release the lock. A KILL here
    # would leave the child re-parented with the gateway token still in its
    # environment and the worktree locked by a job nothing is running.
    kill -TERM "$JOB_PID" 2>/dev/null \
        || die "$EX_USAGE" "job_starting" "the supervisor pid $JOB_PID could not be signalled"
    say "sent the stop signal to $HANDLE (pid $JOB_PID); waiting up to ${deadline}s for it to record a terminal state"

    local start="$SECONDS" waited=0
    while :; do
        load_job
        if is_terminal "$JOB_STATE"; then
            waited=$(( SECONDS - start ))
            emit_handle 0 "{outcome:\"cancelled\", cancelled:true, signalled:true,
                already_terminal:false, expired:false, waited_seconds:$waited,
                deadline_seconds:$deadline, terminal_state:\"$JOB_STATE\"}"
            exit "$EX_OK"
        fi
        waited=$(( SECONDS - start ))
        [ "$waited" -ge "$deadline" ] && break
        sleep 1
    done

    # Signalled, and it had not landed in time. The signal is delivered either
    # way, so this is reported as an unconfirmed cancel rather than a failure to
    # cancel — and cancelling again is safe.
    say "the stop signal was delivered to $HANDLE but it had not recorded a terminal state within ${deadline}s"
    local rem; rem="$(remedy_for cancel_unconfirmed)"
    emit "$(jq -nc --arg v "$VERB" --arg h "$HANDLE" --arg hs "$SPAWN_HANDLE_SCHEMA" \
        --arg s "$JOB_STATE" --arg r "$rem" \
        --argjson j "$(printf '%s' "$JOB_JSON" | jq -c '.job // null')" \
        --argjson d "$deadline" --argjson w "$waited" \
        "$(spawn::envelope_jq plugin)"' + {
          ok:false, error:"cancel_unconfirmed", remedy:$r, exit_code:6,
          detail:("the stop signal was delivered but the job was still " + $s + " after " + ($d|tostring) + "s"),
          handle_schema:$hs, verb:$v, handle:$h, help_requested:false,
          outcome:"unconfirmed", cancelled:false, signalled:true,
          already_terminal:false, expired:false,
          waited_seconds:$w, deadline_seconds:$d,
          state:$s, terminal:false, live:$j.live, job:$j
        }')" || die "$EX_USAGE" "internal" "could not encode the cancel response"
    exit "$EX_DEADLINE"
}

# ---------------------------------------------------------------------------
# --describe — this layer's contract as data, projected from the constants the
# script actually runs on, so a caller reconciles against the running version
# rather than a table it copied once.
# ---------------------------------------------------------------------------
emit_describe() {
    local ev
    ev="$(jq -n \
        --arg r_usage "$(remedy_for usage)" \
        --arg r_unk "$(remedy_for handle_unknown)" \
        --arg r_exp "$(remedy_for handle_expired)" \
        --arg r_dl "$(remedy_for deadline_exceeded)" \
        --arg r_pend "$(remedy_for result_pending)" \
        --arg r_miss "$(remedy_for result_missing)" \
        --arg r_start "$(remedy_for job_starting)" \
        --arg r_canc "$(remedy_for cancel_unconfirmed)" \
        --arg r_int "$(remedy_for internal)" \
        '[{value:"usage",              exit_code:2, remedy:$r_usage},
          {value:"handle_unknown",     exit_code:2, remedy:$r_unk},
          {value:"handle_expired",     exit_code:2, remedy:$r_exp},
          {value:"result_pending",     exit_code:2, remedy:$r_pend},
          {value:"result_missing",     exit_code:2, remedy:$r_miss},
          {value:"job_starting",       exit_code:2, remedy:$r_start},
          {value:"deadline_exceeded",  exit_code:6, remedy:$r_dl},
          {value:"cancel_unconfirmed", exit_code:6, remedy:$r_canc},
          {value:"internal",           exit_code:2, remedy:$r_int}]')" || return 1

    emit "$(jq -nc --argjson errors "$ev" --arg hs "$SPAWN_HANDLE_SCHEMA" \
        --argjson ad "$AWAIT_DEADLINE_DEFAULT" --arg ai "$AWAIT_INTERVAL_DEFAULT" \
        --argjson cd "$CANCEL_DEADLINE_DEFAULT" --argjson ret "$RETENTION" \
        "$(spawn::envelope_jq plugin)"' + {
          ok:true, error:null, exit_code:0,
          response_kind:"describe",
          surface:"handle.sh",
          summary:"What a holder can do with a background job handle: query its state, await a terminal state within a bound, read the supervisor’s result against the contract, and cancel it. Adds nothing to the record and starts nothing.",
          handle_schema:$hs,
          terminal_states:["done","degraded","failed","cancelled"],
          non_terminal_states:["starting","running"],
          retention_seconds:$ret,
          verbs:[
            {name:"state",  argument:"--handle <id> [--cwd <dir>]",
             note:"the job record as the record layer resolves it, by probe; writes nothing and blocks for nothing"},
            {name:"await",  argument:"--handle <id> [--deadline <s>] [--interval <s>]",
             note:"polls until the job is terminal or the bound passes; exit 0 outcome:terminal, exit 6 outcome:deadline with the job still running",
             deadline_default:$ad, interval_default:$ai},
            {name:"result", argument:"--handle <id> [--cwd <dir>]",
             note:"the supervisor’s measured record plus the contract copy it was measured against; exit 2 result_pending while the job runs"},
            {name:"cancel", argument:"--handle <id> [--deadline <s>]",
             note:"signals the supervisor and waits for it to record a terminal state; cancelling an already-terminal job is a no-op at exit 0",
             deadline_default:$cd}
          ],
          flags:[
            {name:"--handle",   value:"id",   required:true,  default:null,
             note:"the handle bg-agent.sh returned; validated against job-<UTC>-<n> before any path is built from it"},
            {name:"--cwd",      value:"dir",  required:false, default:"the process working directory",
             note:"which worktree the record belongs to; the record is per worktree, not global"},
            {name:"--deadline", value:"secs", required:false, default:null,
             note:"whole seconds greater than zero; zero is refused rather than read as check-once"},
            {name:"--interval", value:"secs", required:false, default:null,
             note:"await only: how often to re-probe inside the bound"},
            {name:"--help",     value:null,   required:false, default:null,
             note:"exit 2 with help_requested:true — not a usage error"},
            {name:"--describe", value:null,   required:false, default:null,
             note:"this document; exit 0; needs no job, no lock and no gateway"}
          ],
          exit_codes:[
            {code:0, error:null,   origin:"own", meaning:"the operation did what it says; for await, the job reached a terminal state"},
            {code:2, error:"usage", origin:"own",
             meaning:"a caller mistake, help, or a refusal; branch on error and help_requested, never on prose"},
            {code:6, error:"deadline_exceeded", origin:"own",
             meaning:"a BOUND was reached, not the job: for await the job is still running, for cancel the signal was delivered but unconfirmed"}
          ],
          error_values:$errors,
          response_fields:[
            {name:"schema",         always:true,  note:"the version of this contract"},
            {name:"ok",             always:true,  note:"boolean; agrees with exit_code"},
            {name:"error",          always:true,  note:"enum value or null, never prose"},
            {name:"remedy",         always:true,  note:"what to do about it; null only on success"},
            {name:"detail",         always:true,  note:"human-readable diagnostic; the only prose field"},
            {name:"content_trust",  always:true,  note:"how far the payload may be trusted"},
            {name:"content_notice", always:true,  note:"the rule that follows from content_trust"},
            {name:"exit_code",      always:true,  note:"the process exit status, restated in the data"},
            {name:"verb",           always:false, note:"which operation answered"},
            {name:"handle",         always:false, note:"the job handle this call is about"},
            {name:"state",          always:false, note:"the resolved state, relayed from the record layer"},
            {name:"terminal",       always:false, note:"whether that state is one of the four terminal states"},
            {name:"live",           always:false, note:"whether a supervisor process answered the probe"},
            {name:"job",            always:false, note:"the record layer’s job object, relayed verbatim"},
            {name:"outcome",        always:false, note:"state | terminal | deadline | result | cancelled | already_terminal | unconfirmed"},
            {name:"result",         always:false, note:"result only: the supervisor’s measured record; its narrative field carries its own untrusted marking"},
            {name:"contract",       always:false, note:"result only: the contract COPY the supervisor measured against"},
            {name:"cancelled",      always:false, note:"cancel only: whether this call is what stopped it"},
            {name:"help_requested", always:false, note:"true only for --help; present on every error response"}
          ],
          notes:[
            "await is ALWAYS bounded. A caller holding only Bash cannot receive a notification, so an unbounded await is a session that never returns; exit 0 means the job is terminal and exit 6 means the bound was reached with the job still running.",
            "handle_unknown means no job answers to that handle under this worktree. handle_expired means the record is here, terminal, and older than retention_seconds. A crashed job is neither: it resolves to state failed and answers normally.",
            "A job directory removed from disk is indistinguishable from one that never existed, which is why expiry MARKS a record rather than deleting one. Nothing in this file removes a job directory.",
            "cancel delivers a signal to the supervisor and lets it own the reap, the result and the release. Nothing here writes a terminal state, so a cancel racing a launcher cannot drop the one-job lock out from under it.",
            "result.narrative.text is the model’s own account and carries the untrusted marking (R19). Everything else in result is measured by the supervisor."
          ]
        }')"
}

emit_usage() {
    HELP_REQUESTED=true
    emit_error "$EX_USAGE" "usage" "handle.sh <state|await|result|cancel> --handle <id> [flags]; --describe prints the full contract as data"
    exit "$EX_USAGE"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
DESCRIBE=false
WORKTREE_ARG=""
DEADLINE_ARG=""
INTERVAL_ARG=""
DEADLINE_SET=false
INTERVAL_SET=false

if [ "$#" -eq 0 ]; then
    VERB=""
else
    case "$1" in
        --describe) DESCRIBE=true; shift ;;
        --help|-h)  HELP_REQUESTED=true; shift; VERB="" ;;
        -*)         VERB="" ;;
        *)          VERB="$1"; shift ;;
    esac
fi

while [ "$#" -gt 0 ]; do
    case "$1" in
        --handle)   HANDLE="${2:-}"; shift 2 || shift ;;
        --cwd)      WORKTREE_ARG="${2:-}"; shift 2 || shift ;;
        --deadline) DEADLINE_ARG="${2:-}"; DEADLINE_SET=true; shift 2 || shift ;;
        --interval) INTERVAL_ARG="${2:-}"; INTERVAL_SET=true; shift 2 || shift ;;
        --describe) DESCRIBE=true; shift ;;
        --help|-h)  HELP_REQUESTED=true; shift ;;
        *)          need_jq; die "$EX_USAGE" "usage" "unexpected argument: $1" ;;
    esac
done

need_jq

if [ "$DESCRIBE" = true ]; then
    emit_describe || die "$EX_USAGE" "internal" "could not encode the describe document"
    exit "$EX_OK"
fi
[ "$HELP_REQUESTED" = true ] && emit_usage

case "$VERB" in
    state)  do_state ;;
    await)  do_await ;;
    result) do_result ;;
    cancel) do_cancel ;;
    "")     emit_usage ;;
    *)      die "$EX_USAGE" "usage" "unknown verb: $VERB" ;;
esac
