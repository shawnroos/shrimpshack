#!/usr/bin/env bash
# jobs.sh — the background job RECORD layer (plan U7).
#
#   jobs.sh claim   --contract <file> [--cwd <dir>]   create a job, take the
#                                                     worktree lock, print a handle
#   jobs.sh adopt   --handle <id> --pid <n> [--cwd]   record the supervisor pid
#   jobs.sh state   --handle <id> [--cwd <dir>]       resolve state BY PROBE
#   jobs.sh log     --handle <id> [--cwd <dir>]       append stdin to the job log
#   jobs.sh release --handle <id> --state <terminal>  record a terminal state and
#                                                     drop the lock
#
# WHAT THIS FILE IS, AND WHAT IT IS NOT
# -------------------------------------
# It is the on-disk record a background job is found again by: a job directory,
# an append-only log, a status file, and one lock per worktree. It does NOT
# start, supervise or reap anything — the supervisor (`lib/bg-agent.sh`, a later
# unit) sources this file or shells out to it, and owns detachment, the ceiling
# and the reap.
#
# It is deliberately dual-mode. Sourced, it gives the supervisor the helpers
# below with no subprocess per call; executed, every verb answers with the
# shared envelope so a Bash-only caller (and this unit's own tests) can drive
# the record without a supervisor existing yet.
#
# CONTRACT (frozen by KTD2 of the gateway plan; this file implements it):
#   exactly one JSON object on stdout, always; diagnostics on stderr only.
#   exit 0 ok · 2 usage/refusal · 3 unreachable · 4 alias unknown ·
#        5 upstream error · 6 deadline exceeded · 7 auth rejected.
# A new failure class gets a new `error` STRING, never a new code — hence
# `job_already_running` and `handle_unknown` both riding exit 2.
#
# set -e is deliberately OFF (only -u -o pipefail), for the same reason as the
# other scripts: a classified exit code must not become an unclassified 1.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./sanitize.sh
. "$SCRIPT_DIR/sanitize.sh"
# shellcheck source=./common.sh
. "$SCRIPT_DIR/common.sh"

# ---------------------------------------------------------------------------
# Contract constants
# ---------------------------------------------------------------------------
EX_OK=0
EX_USAGE=2

SPAWN_JOB_SCHEMA="spawn.job/v1"

# KTD8: the closed set of terminal states. `done` is NOT reachable from this
# file — it requires the contract's deliverables checked against a baseline,
# which is the supervisor's job. This layer only records what it is told, and
# refuses a state outside the set.
JOB_TERMINAL_STATES="done degraded failed cancelled"
# The non-terminal claims a status file may carry.
JOB_LIVE_STATES="starting running"

# ---------------------------------------------------------------------------
# Configuration surface. Env-overridable so a test can own the whole tree; a
# test that had to write into the developer's real worktree would either be
# skipped or would fight the operator's own job, and both are how a green suite
# stops meaning anything.
# ---------------------------------------------------------------------------
# The scratchpad (KD5, KD13): `<worktree>/.spawn`. The job's OWN artifacts live
# here — its contract, its log, the supervisor's record, the deliverables it
# produces. The work itself lands in the working tree, where it is useful; this
# directory is not a sandbox and was never meant to be one.
SPAWN_JOB_ROOT_OVERRIDE="${SPAWN_JOB_ROOT:-}"

# How long a claim may sit with no supervisor pid recorded before it is treated
# as abandoned. A launcher writes the pid within milliseconds of the spawn, so
# this only ever fires for a launcher that died between `claim` and `adopt`.
CLAIM_GRACE="${SPAWN_JOB_CLAIM_GRACE:-60}"

# ---------------------------------------------------------------------------
# Plumbing
# ---------------------------------------------------------------------------
# Every human-readable diagnostic goes through say() or die(), and both
# sanitize (the source x sink matrix in README.md). A contract file's bytes and
# a job's own log are as untrusted as any model output — they are written by the
# child — so a diagnostic quoting either one reaches the terminal only through
# these two chokepoints. The lint in tests/unit/escapes.bats iterates lib/*.sh
# and reads these exact lines, so this file was covered the moment it landed.
say() { printf '▸ %s\n' "$(spawn::sanitize_for_display "$*")" >&2; }

# The single stdout write lives in common.sh (emit); EMITTED is this script's
# own state, so it stays declared here — a bash function reads the caller's
# globals dynamically.
EMITTED=0

# R11 — the help discriminator. `--help` and a caller mistake are both exit 2
# with error:"usage" because the enum is frozen; this field is the distinction
# as data, and it rides every error response on both encoder tiers.
HELP_REQUESTED=false

VERB=""
HANDLE=""

# R12 — this file's own error vocabulary, falling through to the shared table.
# Keyed on the ENUM, never on the call site: two sites reporting the same value
# must not hand a caller two different repairs.
#
# No word in this table, and none anywhere in this file, names an amount of
# money or a rate limit knob — the enumerated lint in tests/unit/lens.bats
# covers this script now, and it reads the source, not the intent.
remedy_for() {
    case "$1" in
        job_already_running)
            printf 'This worktree already has a background job (KTD2 allows one). Read `running_handle` in this response and query, await or cancel that job; a different worktree holds a different lock and starts freely.' ;;
        handle_unknown)
            printf 'No job directory answers to that handle under this worktree. Check the handle, and check you are asking from the same worktree the job was started in — the record is per worktree, not global.' ;;
        state_invalid)
            printf 'A job may only be released into done, degraded, failed or cancelled. Pick one of those four; there is no fifth terminal state to add.' ;;
        record_unwritable)
            printf 'The job record could not be written. Check the worktree is writable and has space, then start the job again — nothing was launched, so nothing is orphaned.' ;;
        *) spawn::remedy_for "$1" ;;
    esac
}

emit_error() {
    # $1 = exit code, $2 = machine-readable error value, rest = human detail.
    local code="$1" err="$2"; shift 2
    [ "$EMITTED" -eq 1 ] && return 0
    # `detail` is display text a consumer prints, and on the unknown-handle path
    # it quotes raw argv, so it is sanitized. The handle is sanitized for the
    # same reason: emit_error is the one place it can be a handle the grammar
    # REFUSED, so it has not been closed by construction yet, and jq escapes a
    # control byte in transit but emits a Unicode bidi override literally.
    local detail handle_d
    detail="$(spawn::sanitize_for_display "$*")"
    handle_d="$(spawn::sanitize_for_display "$HANDLE")"
    # R12: the site's own REMEDY wins, otherwise the enum's default from the one
    # table — so "every error names its remedy" holds for die sites nobody has
    # written yet.
    local rem="${REMEDY:-}"
    [ -n "$rem" ] || rem="$(remedy_for "$err")"
    local obj=""
    if command -v jq >/dev/null 2>&1; then
        obj="$(jq -nc --arg v "$VERB" --arg h "$handle_d" --arg e "$err" \
            --arg d "$detail" --arg r "$rem" --argjson c "$code" \
            --argjson hr "$HELP_REQUESTED" \
            "$(spawn::envelope_jq plugin)"' + {ok:false, verb:(if $v == "" then null else $v end),
              handle:(if $h == "" then null else $h end),
              job:null, error:$e, detail:$d, help_requested:$hr,
              remedy:(if $r == "" then null else $r end), exit_code:$c}')"
    fi
    # Reached when jq is ABSENT and also when jq is present but ERRORED — that
    # yielded the empty string, emit refused it, and the script would exit with
    # nothing on stdout at all, which is the one failure a consumer cannot tell
    # from success. VERB is raw argv here, so it is reduced to the verb enum's
    # own charset in pure bash: with no encoder available, closing it by
    # construction is the only defence there is.
    [ -n "$obj" ] || obj="$(spawn::envelope_bash plugin "$err" "$code" ",\"verb\":\"${VERB//[^a-z-]/}\",\"handle\":null,\"job\":null,\"help_requested\":$HELP_REQUESTED" "$rem")"
    emit "$obj"
}

die() {
    local code="$1" err="$2"; shift 2
    printf '✗ %s\n' "$(spawn::sanitize_for_display "$*")" >&2
    emit_error "$code" "$err" "$*"
    exit "$code"
}

need_jq() {
    command -v jq >/dev/null 2>&1 || {
        printf '✗ jq is required (the contract is one JSON object on stdout)\n' >&2
        emit "$(spawn::envelope_bash plugin "internal" 2 ",\"verb\":\"${VERB//[^a-z-]/}\",\"handle\":null,\"job\":null,\"help_requested\":$HELP_REQUESTED" "Install jq and re-run. The plugin's contract is one JSON object on stdout, and jq is what encodes it.")"
        exit 2
    }
}

now_utc() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

# ---------------------------------------------------------------------------
# Grammar. Validated BEFORE any path is built from it, so a handle carrying a
# slash, a shell metacharacter or an escape byte can never reach the filesystem
# — refused rather than filtered, the same way spawnctl validates an alias
# before any network call.
# ---------------------------------------------------------------------------
validate_handle() {
    [[ "$1" =~ ^job-[0-9]{8}T[0-9]{6}Z-[0-9]{4,10}$ ]] \
        || die "$EX_USAGE" "usage" "handle failed the grammar job-<UTC>-<n> — refused before any path was built from it"
}

# ---------------------------------------------------------------------------
# Where the record lives.
#
# Per WORKTREE, not per repository and not per checkout directory: KTD2's lock
# is what makes attribution free (only one job could have made the changes), and
# `git rev-parse --show-toplevel` returns the LINKED worktree's own root, so two
# worktrees of the same repo hold two different locks and run freely.
#
# Outside a repository the directory itself is the boundary. That is not a
# fallback to "global": it keeps the same one-lock-per-tree property for a tree
# git does not know about, instead of silently sharing one lock across
# everything on the box.
# ---------------------------------------------------------------------------
WORKTREE=""
JOB_ROOT=""
LOCKDIR=""
resolve_worktree() {
    local d="${1:-$PWD}" top
    [ -d "$d" ] || die "$EX_USAGE" "usage" "--cwd names '$d', which is not a directory"
    # PHYSICAL path. On macOS /tmp is a symlink to /private/tmp, and a logical
    # path here would make the same tree resolve to two different lock paths
    # depending on how the caller spelled it — which is a second concurrent job
    # in the worktree KTD2 says may only have one.
    d="$(cd "$d" 2>/dev/null && pwd -P)" || die "$EX_USAGE" "usage" "cannot enter --cwd"
    top="$(cd "$d" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)"
    if [ -n "$top" ] && [ -d "$top" ]; then
        WORKTREE="$(cd "$top" && pwd -P)"
    else
        WORKTREE="$d"
    fi
    JOB_ROOT="${SPAWN_JOB_ROOT_OVERRIDE:-$WORKTREE/.spawn}"
    LOCKDIR="$JOB_ROOT/lock"
}

# ---------------------------------------------------------------------------
# Liveness (KTD6). THE STATUS FILE IS A CLAIM.
#
# Measured in the spike: after the job was killed, status still read "running",
# because the thing that would have updated it was the thing that died. So state
# is established by probing — `kill -0` plus an argv identity check — and the
# file is only ever consulted for what the job CLAIMED.
#
# The argv check is a WHOLE-FIELD match, never a substring of the command line.
# The substring form fails open in the direction that matters: any unrelated
# process whose argv merely mentions the marker — a `tail` on the job log, an
# editor holding the contract, another jobs.sh — would be "verified as the job"
# and would keep a dead worktree locked forever, or take a signal from a later
# unit's reap. Same shape as spawnctl.sh's _argv_names_binary.
# ---------------------------------------------------------------------------
pid_argv() { ps -o args= -p "$1" 2>/dev/null | head -1; }

pid_is_job() {
    local pid="$1" marker="$2" args
    [ -n "$pid" ] && [ "$pid" != "null" ] && [ "$pid" != "0" ] || return 1
    [ -n "$marker" ] && [ "$marker" != "null" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    args="$(pid_argv "$pid")"
    [ -n "$args" ] || return 1
    awk -v a="$args" -v m="$marker" 'BEGIN{
        n = split(a, f, " ")
        for (i = 1; i <= n; i++) if (f[i] == m) exit 0
        exit 1
    }'
}

# The marker a supervisor must carry in its argv to be recognized as this job.
# Derived from the handle rather than stored separately, so a record whose
# status file was truncated or hand-edited cannot claim a marker that names a
# different job.
job_marker() { printf 'spawn-bg-agent=%s' "$1"; }

status_path()   { printf '%s/%s/status.json' "$JOB_ROOT" "$1"; }
job_dir_path()  { printf '%s/%s' "$JOB_ROOT" "$1"; }

# Reads one field out of a status file. Absent file, unreadable file and
# malformed JSON all yield the empty string: a record that cannot be parsed is
# treated as a record that says nothing, never as one that says "running".
status_field() {
    local handle="$1" field="$2" f
    f="$(status_path "$handle")"
    [ -f "$f" ] || return 1
    jq -r --arg k "$field" '(.[$k] // "") | tostring' < "$f" 2>/dev/null
}

# is_terminal <state>
is_terminal() {
    local s
    for s in $JOB_TERMINAL_STATES; do [ "$s" = "$1" ] && return 0; done
    return 1
}

# ---------------------------------------------------------------------------
# resolve_state <handle> — the whole of KTD6, in one place.
#
# Sets RESOLVED_STATE, RESOLVED_SOURCE, RESOLVED_LIVE, CLAIMED_STATE.
# READ-ONLY BY DESIGN: it writes nothing. A read verb that repaired the record
# would make polling (U10) a mutating operation and would let two concurrent
# readers race each other over the same file, for no gain — the response already
# carries the truth, and `release` is what records it.
# ---------------------------------------------------------------------------
RESOLVED_STATE=""
RESOLVED_SOURCE=""
RESOLVED_LIVE=false
CLAIMED_STATE=""
resolve_state() {
    local handle="$1" pid marker claimed
    claimed="$(status_field "$handle" state)" || claimed=""
    CLAIMED_STATE="$claimed"
    RESOLVED_LIVE=false

    if [ -z "$claimed" ]; then
        # No parseable record. The directory exists (the caller checked) but the
        # status file does not say anything we can act on.
        RESOLVED_STATE="failed"; RESOLVED_SOURCE="probe"; return 0
    fi
    if is_terminal "$claimed"; then
        # A terminal state is the one claim that needs no probe: it was written
        # by a process that was still alive to write it, and nothing moves a job
        # back out of it.
        RESOLVED_STATE="$claimed"; RESOLVED_SOURCE="record"; return 0
    fi

    pid="$(status_field "$handle" pid)" || pid=""
    marker="$(job_marker "$handle")"

    if [ -z "$pid" ] || [ "$pid" = "null" ] || [ "$pid" = "0" ]; then
        # Claimed but never adopted: the launcher had not recorded a supervisor
        # pid yet. Age is the only signal available, exactly as it is for a
        # pid-less gateway lock, and a real launcher adopts within milliseconds.
        if [ -n "$(find "$(job_dir_path "$handle")" -maxdepth 0 -mmin "-$(( (CLAIM_GRACE + 59) / 60 ))" 2>/dev/null)" ]; then
            RESOLVED_STATE="starting"; RESOLVED_SOURCE="probe"; RESOLVED_LIVE=false; return 0
        fi
        RESOLVED_STATE="failed"; RESOLVED_SOURCE="probe"; return 0
    fi

    if pid_is_job "$pid" "$marker"; then
        RESOLVED_STATE="running"; RESOLVED_SOURCE="probe"; RESOLVED_LIVE=true; return 0
    fi
    # Either the pid is gone, or something else now holds it. Both are the same
    # answer to the only question asked here: this job is not running, whatever
    # its status file claims. Never `done` — nothing checked its deliverables.
    RESOLVED_STATE="failed"; RESOLVED_SOURCE="probe"; return 0
}

# ---------------------------------------------------------------------------
# The lock (KTD2). One job per worktree.
#
# mkdir is the atomic primitive because flock(1) does not exist on macOS — the
# same idiom spawnctl.sh uses for an idempotent start. ONE THING IS DELIBERATELY
# DIFFERENT, and it is load-bearing: spawnctl's lock is process-scoped and is
# released by its own EXIT trap. This one MUST NOT BE. The holder is the JOB,
# not the process that claimed it, and `claim` returns a handle and exits while
# the job runs on for an hour. An EXIT-trap release here would drop the lock
# roughly one millisecond after taking it and let a second job start into the
# same working tree — the exact collision KTD2 exists to prevent.
#
# So ownership is established by probing the recorded holder, and the lock is
# dropped only by `release`, or broken by a later `claim` that finds the holder
# resolved to a terminal state.
#
# Breaking is `mv` then remove, never a bare `rm -rf`: read-then-rm-then-mkdir is
# not atomic, and two claimants that read the same dead holder both run rm, the
# first one's mkdir wins, and the second one's rm deletes the lock the winner is
# holding. Only one `mv` can succeed.
# ---------------------------------------------------------------------------
LOCK_HOLDER=""
read_lock_holder() {
    LOCK_HOLDER=""
    [ -d "$LOCKDIR" ] || return 1
    LOCK_HOLDER="$(tr -dc 'A-Za-z0-9._-' < "$LOCKDIR/job" 2>/dev/null)"
    [ -n "$LOCK_HOLDER" ] || return 1
    return 0
}

break_lock() {
    mv "$LOCKDIR" "$LOCKDIR.stale.$$" 2>/dev/null && rm -rf "$LOCKDIR.stale.$$" 2>/dev/null
    return 0
}

# ---------------------------------------------------------------------------
# Verbs
# ---------------------------------------------------------------------------
CONTRACT=""
CWD_ARG=""
PID_ARG=""
STATE_ARG=""
DETAIL_ARG=""

# The job response object, as jq program text merged into the envelope. One
# definition so `claim`, `adopt`, `state` and `release` cannot describe the same
# record three different ways — which is how U10 would end up branching on which
# verb answered.
emit_job() {
    local handle="$1" code="${2:-0}"
    local dir; dir="$(job_dir_path "$handle")"
    local pid started ended detail contract
    pid="$(status_field "$handle" pid)" || pid=""
    started="$(status_field "$handle" started_at)" || started=""
    ended="$(status_field "$handle" ended_at)" || ended=""
    detail="$(status_field "$handle" detail)" || detail=""
    contract="$(status_field "$handle" contract)" || contract=""
    emit "$(jq -nc \
        --arg v "$VERB" --arg h "$handle" --arg d "$dir" --arg r "$JOB_ROOT" \
        --arg w "$WORKTREE" --arg s "$RESOLVED_STATE" --arg src "$RESOLVED_SOURCE" \
        --arg cs "$CLAIMED_STATE" --arg p "$pid" --arg st "$started" \
        --arg en "$ended" --arg dt "$detail" --arg ct "$contract" \
        --arg m "$(job_marker "$handle")" --arg js "$SPAWN_JOB_SCHEMA" \
        --argjson live "$RESOLVED_LIVE" --argjson c "$code" \
        "$(spawn::envelope_jq plugin)"' + {
          ok:true, error:null, remedy:null, exit_code:$c,
          verb:$v, handle:$h, help_requested:false,
          job:{schema:$js, job_id:$h, job_dir:$d, job_root:$r, worktree:$w,
               contract:(if $ct == "" then null else $ct end),
               log:($d + "/log"), status_file:($d + "/status.json"),
               argv_marker:$m,
               pid:(if $p == "" or $p == "null" or $p == "0" then null else ($p|tonumber?) end),
               state:$s, state_source:$src, live:$live,
               claimed_state:(if $cs == "" then null else $cs end),
               started_at:(if $st == "" then null else $st end),
               ended_at:(if $en == "" then null else $en end),
               detail:(if $dt == "" then null else $dt end)}
        }')" || die 2 "internal" "could not encode the job record"
}

# write_status <handle> <state> [pid] [ended_at] [detail]
# Written whole through a temp file and mv'd into place: a reader that catches a
# half-written status file must see the OLD record, not a truncated one — and a
# truncated one parses as "says nothing", which resolve_state reads as failed.
write_status() {
    local handle="$1" state="$2" pid="${3:-}" ended="${4:-}" detail="${5:-}"
    local dir f tmp started contract
    dir="$(job_dir_path "$handle")"
    f="$dir/status.json"
    started="$(status_field "$handle" started_at 2>/dev/null)" || started=""
    [ -n "$started" ] || started="$(now_utc)"
    contract="$(status_field "$handle" contract 2>/dev/null)" || contract=""
    [ -n "$contract" ] || contract="$CONTRACT"
    tmp="$dir/.status.$$"
    jq -nc --arg js "$SPAWN_JOB_SCHEMA" --arg id "$handle" --arg w "$WORKTREE" \
        --arg d "$dir" --arg ct "$contract" --arg s "$state" --arg p "$pid" \
        --arg st "$started" --arg en "$ended" --arg dt "$detail" \
        '{schema:$js, job_id:$id, worktree:$w, job_dir:$d,
          contract:(if $ct == "" then null else $ct end),
          state:$s,
          pid:(if $p == "" or $p == "0" then null else ($p|tonumber?) end),
          started_at:$st,
          ended_at:(if $en == "" then null else $en end),
          detail:(if $dt == "" then null else $dt end)}' > "$tmp" 2>/dev/null \
        || { rm -f "$tmp" 2>/dev/null; return 1; }
    mv "$tmp" "$f" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
    return 0
}

require_job() {
    local handle="$1"
    [ -d "$(job_dir_path "$handle")" ] \
        || die "$EX_USAGE" "handle_unknown" "no job directory for handle '$handle' under $JOB_ROOT"
}

do_claim() {
    [ -n "$CONTRACT" ] || die "$EX_USAGE" "usage" "claim needs --contract <file>"
    [ -f "$CONTRACT" ] || die "$EX_USAGE" "usage" "--contract names '$CONTRACT', which is not a readable file"
    CONTRACT="$(cd "$(dirname "$CONTRACT")" && pwd -P)/$(basename "$CONTRACT")"

    # umask 077 for the whole claim: the contract can name paths and internal
    # detail, and the log will carry whatever the child writes. 0700 is asserted
    # by the tests rather than assumed from the umask.
    umask 077
    mkdir -p "$JOB_ROOT" 2>/dev/null \
        || die "$EX_USAGE" "record_unwritable" "cannot create the job root at $JOB_ROOT"
    chmod 0700 "$JOB_ROOT" 2>/dev/null

    # Take the lock FIRST. Creating the job directory before the refusal check
    # would leave a directory behind on every refused spawn, and a later `claim`
    # scanning for jobs could not tell those from real ones.
    local tries=0
    while ! mkdir "$LOCKDIR" 2>/dev/null; do
        if read_lock_holder && [ "$LOCK_HOLDER" != "pending" ] \
           && [ -d "$(job_dir_path "$LOCK_HOLDER")" ]; then
            # KTD6 again: whether the holder is real is a PROBE, not a read of
            # its status file. A killed supervisor leaves "running" behind, and
            # trusting it wedges the worktree permanently.
            resolve_state "$LOCK_HOLDER"
            if ! is_terminal "$RESOLVED_STATE"; then
                HANDLE="$LOCK_HOLDER"
                say "this worktree already has a background job: $LOCK_HOLDER"
                emit_refusal "$LOCK_HOLDER"
                exit "$EX_USAGE"
            fi
            say "breaking a lock held by $LOCK_HOLDER, which is no longer running"
            break_lock
        elif [ -n "$(find "$LOCKDIR" -maxdepth 0 -mmin -1 2>/dev/null)" ]; then
            # A lock with no usable holder recorded yet. Either we caught a
            # claimant in the window between its mkdir and its write, or a
            # previous break left it wedged. Age is the only signal available,
            # and a real claimant fills it in within milliseconds — so a FRESH
            # one is waited on rather than broken. Breaking it here is how two
            # claimants both proceed into the same worktree, which is exactly
            # what the lock exists to prevent.
            sleep 0.1
        else
            say "breaking a job lock with no live holder recorded"
            break_lock
        fi
        tries=$((tries + 1))
        if [ "$tries" -gt 200 ]; then
            die "$EX_USAGE" "record_unwritable" "could not take the job lock at $LOCKDIR"
        fi
    done
    if ! printf '%s\n' "pending" > "$LOCKDIR/job" 2>/dev/null; then
        # The directory we just made is already gone — another claimant broke it
        # out from under us. We do NOT hold this lock, so say so rather than
        # proceeding into a second job in the same tree.
        die "$EX_USAGE" "record_unwritable" "lost the job lock immediately after taking it"
    fi

    # Handle allocation under the lock, so the mkdir below cannot collide.
    local handle dir
    tries=0
    while :; do
        handle="job-$(date -u '+%Y%m%dT%H%M%SZ')-$((RANDOM % 9000 + 1000))"
        dir="$(job_dir_path "$handle")"
        mkdir "$dir" 2>/dev/null && break
        tries=$((tries + 1))
        [ "$tries" -gt 20 ] && { break_lock; die "$EX_USAGE" "record_unwritable" "could not create a job directory under $JOB_ROOT"; }
    done
    chmod 0700 "$dir" 2>/dev/null
    HANDLE="$handle"

    # The contract is COPIED in, not referenced. A job that outlives its session
    # must still be checkable against what it was asked to do, and the caller's
    # file can be edited or deleted the moment `claim` returns.
    cat "$CONTRACT" > "$dir/contract" 2>/dev/null \
        || { break_lock; die "$EX_USAGE" "record_unwritable" "could not copy the contract into $dir"; }
    # The log exists from the start and is only ever APPENDED to, here and by
    # the `log` verb. Created empty so a reader tailing it while the job runs
    # never has to handle "not there yet".
    : >> "$dir/log" 2>/dev/null \
        || { break_lock; die "$EX_USAGE" "record_unwritable" "could not create the job log in $dir"; }

    write_status "$handle" "starting" "" "" "" \
        || { break_lock; die "$EX_USAGE" "record_unwritable" "could not write the job status file in $dir"; }

    printf '%s\n' "$handle" > "$LOCKDIR/job" 2>/dev/null \
        || { break_lock; die "$EX_USAGE" "record_unwritable" "could not record the lock holder"; }

    resolve_state "$handle"
    emit_job "$handle" 0
    exit "$EX_OK"
}

# The refusal object (KTD2): it names the RUNNING job's handle, because the
# caller's next move is to query or cancel that job, and a refusal that made
# them go looking for the handle would be a refusal they route around.
emit_refusal() {
    local holder="$1" rem
    rem="$(remedy_for job_already_running)"
    local obj=""
    if command -v jq >/dev/null 2>&1; then
        obj="$(jq -nc --arg v "$VERB" --arg h "$holder" --arg d "$(job_dir_path "$holder")" \
            --arg s "$RESOLVED_STATE" --arg r "$rem" --arg w "$WORKTREE" \
            "$(spawn::envelope_jq plugin)"' + {ok:false, verb:$v, handle:null, job:null,
              error:"job_already_running",
              detail:("this worktree already has a background job (" + $h + "), and KTD2 allows one at a time"),
              remedy:$r, help_requested:false, exit_code:2,
              running_handle:$h, running_job_dir:$d, running_state:$s, worktree:$w}')"
    fi
    [ -n "$obj" ] || obj="$(spawn::envelope_bash plugin "job_already_running" 2 ",\"verb\":\"${VERB//[^a-z-]/}\",\"handle\":null,\"job\":null,\"help_requested\":false,\"running_handle\":\"${holder//[^A-Za-z0-9._-]/}\"" "$rem")"
    emit "$obj"
}

do_adopt() {
    [ -n "$HANDLE" ] || die "$EX_USAGE" "usage" "adopt needs --handle <id>"
    validate_handle "$HANDLE"
    require_job "$HANDLE"
    [ -n "$PID_ARG" ] || die "$EX_USAGE" "usage" "adopt needs --pid <n>"
    [[ "$PID_ARG" =~ ^[0-9]+$ ]] || die "$EX_USAGE" "usage" "--pid must be a number"
    write_status "$HANDLE" "running" "$PID_ARG" "" "" \
        || die "$EX_USAGE" "record_unwritable" "could not record the supervisor pid"
    resolve_state "$HANDLE"
    emit_job "$HANDLE" 0
    exit "$EX_OK"
}

do_state() {
    [ -n "$HANDLE" ] || die "$EX_USAGE" "usage" "state needs --handle <id>"
    validate_handle "$HANDLE"
    require_job "$HANDLE"
    resolve_state "$HANDLE"
    emit_job "$HANDLE" 0
    exit "$EX_OK"
}

do_log() {
    [ -n "$HANDLE" ] || die "$EX_USAGE" "usage" "log needs --handle <id>"
    validate_handle "$HANDLE"
    require_job "$HANDLE"
    # APPEND, never truncate. `gw` truncated its log on every start and that
    # destroyed the only evidence of why the previous run died; the same rule is
    # why spawnctl appends to the gateway log. The bytes are the child's, so
    # nothing here interprets them — they are written through verbatim and read
    # back through the sanitizer by whoever displays them.
    local dir; dir="$(job_dir_path "$HANDLE")"
    cat >> "$dir/log" 2>/dev/null \
        || die "$EX_USAGE" "record_unwritable" "could not append to the job log"
    resolve_state "$HANDLE"
    emit_job "$HANDLE" 0
    exit "$EX_OK"
}

do_release() {
    [ -n "$HANDLE" ] || die "$EX_USAGE" "usage" "release needs --handle <id>"
    validate_handle "$HANDLE"
    require_job "$HANDLE"
    [ -n "$STATE_ARG" ] || die "$EX_USAGE" "usage" "release needs --state <done|degraded|failed|cancelled>"
    is_terminal "$STATE_ARG" \
        || die "$EX_USAGE" "state_invalid" "'$STATE_ARG' is not one of the four terminal states"
    write_status "$HANDLE" "$STATE_ARG" "" "$(now_utc)" "$DETAIL_ARG" \
        || die "$EX_USAGE" "record_unwritable" "could not record the terminal state"
    # Only the holder drops the lock. Releasing a lock a DIFFERENT job now holds
    # would let two jobs into one worktree, which is the collision the lock
    # exists to prevent — the same ownership check spawnctl's release_lock makes.
    if read_lock_holder && [ "$LOCK_HOLDER" = "$HANDLE" ]; then
        break_lock
    fi
    resolve_state "$HANDLE"
    emit_job "$HANDLE" 0
    exit "$EX_OK"
}

# ---------------------------------------------------------------------------
# --describe — this layer's contract as data, projected from what the script
# actually runs on (the EX_* constants, the state sets, the verb list below and
# the shared remedy table), so a caller reconciles against the running version
# rather than a table it copied once.
# ---------------------------------------------------------------------------
emit_describe() {
    local terminals lives ev
    terminals="$(printf '%s\n' $JOB_TERMINAL_STATES | jq -Rc . | jq -sc .)" || return 1
    lives="$(printf '%s\n' $JOB_LIVE_STATES | jq -Rc . | jq -sc .)" || return 1
    ev="$(jq -n \
        --arg r_usage "$(remedy_for usage)" \
        --arg r_run "$(remedy_for job_already_running)" \
        --arg r_unk "$(remedy_for handle_unknown)" \
        --arg r_st "$(remedy_for state_invalid)" \
        --arg r_rec "$(remedy_for record_unwritable)" \
        --arg r_int "$(remedy_for internal)" \
        '[{value:"usage",               exit_code:2, remedy:$r_usage},
          {value:"job_already_running", exit_code:2, remedy:$r_run},
          {value:"handle_unknown",      exit_code:2, remedy:$r_unk},
          {value:"state_invalid",       exit_code:2, remedy:$r_st},
          {value:"record_unwritable",   exit_code:2, remedy:$r_rec},
          {value:"internal",            exit_code:2, remedy:$r_int}]')" || return 1

    emit "$(jq -nc --argjson errors "$ev" --argjson terminal "$terminals" \
        --argjson live "$lives" --arg js "$SPAWN_JOB_SCHEMA" --arg root "$JOB_ROOT" \
        --arg w "$WORKTREE" --arg lock "$LOCKDIR" \
        "$(spawn::envelope_jq plugin)"' + {
          ok:true, error:null, exit_code:0,
          response_kind:"describe",
          surface:"jobs.sh",
          summary:"The on-disk record a background job is found again by: one job directory per job, one lock per worktree, and a state established by probing rather than by reading the status file.",
          job_schema:$js,
          worktree:$w, job_root:$root, lock_dir:$lock,
          terminal_states:$terminal,
          non_terminal_states:$live,
          layout:[
            {path:"<job_root>/lock/job", note:"the handle of the job holding this worktree; one job at a time (KTD2)"},
            {path:"<job_root>/<handle>/contract", note:"a copy of the contract the job was started against"},
            {path:"<job_root>/<handle>/log", note:"append-only; readable while the job runs"},
            {path:"<job_root>/<handle>/status.json", note:"the job CLAIM; never read as truth for liveness (KTD6)"}
          ],
          verbs:[
            {name:"claim",   argument:"--contract <file> [--cwd <dir>]",
             note:"creates the job directory 0700 and takes the worktree lock; exit 2 error:job_already_running names the running handle"},
            {name:"adopt",   argument:"--handle <id> --pid <n>",
             note:"records the detached supervisor pid; until then the job reads as starting"},
            {name:"state",   argument:"--handle <id>",
             note:"resolves state by probe (kill -0 plus a whole-field argv match on argv_marker); writes nothing"},
            {name:"log",     argument:"--handle <id> (message on stdin)",
             note:"appends to the job log; never truncates"},
            {name:"release", argument:"--handle <id> --state <terminal> [--detail <text>]",
             note:"records a terminal state and drops the lock, only if this job still holds it"}
          ],
          flags:[
            {name:"--cwd",      value:"dir",  required:false, default:"the process working directory",
             note:"which worktree the record belongs to; git rev-parse --show-toplevel decides, so two worktrees of one repo hold two locks"},
            {name:"--help",     value:null,   required:false, default:null,
             note:"exit 2 with help_requested:true — not a usage error"},
            {name:"--describe", value:null,   required:false, default:null,
             note:"this document; exit 0; needs no job, no lock and no gateway"}
          ],
          exit_codes:[
            {code:0, error:null,    origin:"own", meaning:"the verb did what it says"},
            {code:2, error:"usage", origin:"own",
             meaning:"a caller mistake, help, or a refusal; branch on error and help_requested, never on prose"}
          ],
          error_values:$errors,
          response_fields:[
            {name:"schema",          always:true,  note:"the version of this contract"},
            {name:"ok",              always:true,  note:"boolean; agrees with exit_code"},
            {name:"error",           always:true,  note:"enum value or null, never prose"},
            {name:"remedy",          always:true,  note:"what to do about it; null only on success"},
            {name:"detail",          always:true,  note:"human-readable diagnostic; the only prose field"},
            {name:"content_trust",   always:true,  note:"how far the payload may be trusted"},
            {name:"content_notice",  always:true,  note:"the rule that follows from content_trust"},
            {name:"exit_code",       always:true,  note:"the process exit status, restated in the data"},
            {name:"verb",            always:false, note:"which verb answered"},
            {name:"handle",          always:false, note:"the job handle this call is about"},
            {name:"job",             always:false, note:"the job record: paths, argv_marker, pid, state, state_source, live"},
            {name:"running_handle",  always:false, note:"refusal only: the job already holding this worktree"},
            {name:"running_state",   always:false, note:"refusal only: that job'"'"'s probed state"},
            {name:"help_requested",  always:false, note:"true only for --help; present on every error response"}
          ],
          notes:[
            "state_source:\"probe\" means the answer came from kill -0 plus the argv check; \"record\" means the job had already been released into a terminal state.",
            "A status file claiming running for a pid that is gone, or for a pid whose argv does not carry argv_marker, resolves to failed. The file is a claim (KTD6).",
            "done is never written by this layer: it requires the contract'"'"'s deliverables checked against a pre-job baseline, which belongs to the supervisor."
          ]
        }')"
}

emit_usage() {
    HELP_REQUESTED=true
    emit_error "$EX_USAGE" "usage" "jobs.sh <claim|adopt|state|log|release> [flags]; --describe prints the full contract as data"
    exit "$EX_USAGE"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
DESCRIBE=false
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
        --cwd)      CWD_ARG="${2:-}"; shift 2 || shift ;;
        --contract) CONTRACT="${2:-}"; shift 2 || shift ;;
        --handle)   HANDLE="${2:-}"; shift 2 || shift ;;
        --pid)      PID_ARG="${2:-}"; shift 2 || shift ;;
        --state)    STATE_ARG="${2:-}"; shift 2 || shift ;;
        --detail)   DETAIL_ARG="${2:-}"; shift 2 || shift ;;
        --describe) DESCRIBE=true; shift ;;
        --help|-h)  HELP_REQUESTED=true; shift ;;
        *)          need_jq; die "$EX_USAGE" "usage" "unexpected argument: $1" ;;
    esac
done

need_jq
resolve_worktree "$CWD_ARG"

if [ "$DESCRIBE" = true ]; then
    emit_describe || die "$EX_USAGE" "internal" "could not encode the describe document"
    exit "$EX_OK"
fi
[ "$HELP_REQUESTED" = true ] && emit_usage

case "$VERB" in
    claim)   do_claim ;;
    adopt)   do_adopt ;;
    state)   do_state ;;
    log)     do_log ;;
    release) do_release ;;
    "")      emit_usage ;;
    *)       die "$EX_USAGE" "usage" "unknown verb: $VERB" ;;
esac
