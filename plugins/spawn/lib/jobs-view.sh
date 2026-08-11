#!/usr/bin/env bash
# jobs-view.sh — the `status` verb's view of this worktree's background jobs.
#
# WHY THIS IS ITS OWN FILE, and not the section of spawnctl.sh it was written
# as: spawnctl.sh is argued past the audit's size bar ON CODE LINES in
# docs/residual-review-findings/spawn-quality-audit.md, and
# tests/unit/surfaces.bats ENFORCES that argument at under 1000. These four
# functions took it to 1033. The audit says the decision must be "re-taken, not
# re-quoted, the next time this file grows" — and the honest re-take is that
# this block was never spawnctl's own concern. It reads the job record layer
# (jobs.sh) and renders it; the status verb only splices the result into one
# envelope field. That is a seam the code already had, not one invented to duck
# a counter.
#
# It is SOURCED, not executed: every name below lands in spawnctl.sh's shell,
# which is why the globals stay globals and `jobs_view` can set JOBS_JSON for
# the emit at the bottom of the status verb. SCRIPT_DIR is the sourcing
# script's, which is what JOBS_SH below resolves against.
#
# shellcheck shell=bash

# Its own dependencies, named here rather than assumed from the sourcing
# script. Both are idempotent function-definition files and spawnctl.sh has
# already sourced them by the time it reaches this one, so this costs a re-read
# and nothing else — and it is what makes the file honest about what it needs
# instead of relying on load order. tests/unit/escapes.bats reads these lines:
# its sanitize lint walks source edges transitively from each shipped script,
# so a fragment that inherits its chokepoints must SAY it inherits them.
# shellcheck source=./sanitize.sh
. "$SCRIPT_DIR/sanitize.sh"
# shellcheck source=./common.sh
. "$SCRIPT_DIR/common.sh"

# ---------------------------------------------------------------------------
# Background jobs in this worktree (U12, R18 extended to jobs).
#
# KTD6 is the whole point of this block: a status file that says `running` is a
# CLAIM, and after a kill it still says running because the writer is what died.
# So nothing here reads a status file for a state. Every listed job's state
# comes from `jobs.sh state`, which resolves it by `kill -0` plus a whole-field
# argv match — the same relationship this file already has with the gateway's
# own pidfile. jobs.sh is shelled out to rather than sourced (its dispatch runs
# at file scope), and it is the ONLY thing that decides a state: a second
# opinion here is how the two drift.
#
# WHICH JOBS (KD8). Listing every record a worktree ever held is the crying-wolf
# failure in a different costume, so the list is bounded the same way the handle
# layer already bounds answerability:
#   * a record whose status file is older than SPAWN_JOB_RETENTION is not listed
#     — that is exactly the window handle.sh calls handle_expired, read off the
#     same file's mtime with the same find -mmin idiom, so the report can never
#     advertise a handle whose operations would be refused as expired;
#   * the job holding the worktree lock is listed regardless of age, because a
#     job that has been running for nine days is the single most important thing
#     this block exists to show;
#   * newest first, capped at SPAWN_JOB_REPORT_LIMIT, with the number dropped by
#     the cap reported rather than silently swallowed. Handles carry their own
#     UTC start stamp (job-<UTC>-<n>), so a reverse lexical sort IS newest-first
#     and the cap is applied BEFORE any probe — subprocess cost is bounded by
#     the limit, not by how many records the directory holds.
# With nothing listed the `jobs` field is absent altogether, so a worktree that
# has never run a job reports exactly what it reported before this existed.
# ---------------------------------------------------------------------------
JOBS_SH="$SCRIPT_DIR/jobs.sh"
# The same knob handle.sh reads, and deliberately the same default: one surface
# answering a handle the other surface refuses is worse than either bound.
JOB_RETENTION="${SPAWN_JOB_RETENTION:-604800}"
JOB_REPORT_LIMIT="${SPAWN_JOB_REPORT_LIMIT:-10}"
JOBS_JSON=""

# Both stat dialects. macOS is `stat -f '%m'`, GNU is `stat -c '%Y'`; a helper
# that knew only one would silently yield the empty string on the other box,
# and an empty string here becomes a null age rather than a wrong one.
file_mtime() { stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1" 2>/dev/null; }

# The alias a job is running against. It is NOT in the job record — the record
# layer owns lifecycle, not model choice — so it is read from the two places
# that do have it:
#   * result.json, which the supervisor writes when the job reaches a terminal
#     state (the trusted, on-disk answer);
#   * otherwise the supervisor's own argv, and ONLY when the probe just returned
#     live:true — that probe verified this pid's argv carries this job's marker,
#     so the argv being read is provably ours and not a stranger's.
# Anything that fails the alias grammar becomes null. A crashed job that never
# wrote a result reports no alias, which is honest; guessing one out of the
# job's log prose would not be.
job_alias() {           # <job_dir> <live> <pid>
    local dir="$1" live="$2" pid="$3" a=""
    if [ -f "$dir/result.json" ]; then
        a="$(jq -r '(.alias // "") | tostring' < "$dir/result.json" 2>/dev/null)"
    fi
    if [ -z "$a" ] && [ "$live" = "true" ] && [ -n "$pid" ]; then
        a="$(pid_argv "$pid" | awk '{for (i = 1; i < NF; i++) if ($i == "--alias") {print $(i+1); exit}}')"
    fi
    case "$a" in
        "" | *[!A-Za-z0-9._-]*) a="" ;;
    esac
    printf '%s' "$a"
}

# One listed job, as a JSON object on stdout. Returns 1 if the record could not
# be read at all, and the caller drops it rather than reporting a half-record.
job_entry() {           # <handle> <job_root> <terminal_states> <now_epoch>
    local h="$1" root="$2" terminals="$3" now="$4"
    local out fields dir state src live pid started ended detail alias age last m t tm
    # No --cwd: this child inherits our working directory, which is the same one
    # the --describe call that resolved $root ran under, so both calls resolve
    # the same worktree by construction.
    out="$(bash "$JOBS_SH" state --handle "$h" 2>/dev/null)" || return 1
    [ -n "$out" ] || return 1
    # @tsv, then the tabs swapped for a unit separator. Splitting on the TAB
    # itself silently loses empty fields — tab is IFS whitespace, so `read`
    # collapses two adjacent ones into a single separator and every later field
    # shifts up by one (a job with no pid reported its start time as its pid).
    # 0x1f is not IFS whitespace, so an empty field stays an empty field; and
    # @tsv has already escaped any tab, newline or backslash inside a value, so
    # no value can carry the separator or break the single-line read.
    fields="$(printf '%s' "$out" | jq -r '
        [ (.job.job_dir // ""), (.job.state // ""), (.job.state_source // ""),
          ((.job.live // false) | tostring), ((.job.pid // "") | tostring),
          (.job.started_at // ""), (.job.ended_at // ""), (.job.detail // "") ]
        | @tsv' 2>/dev/null | tr '\t' '\037')" || return 1
    [ -n "$fields" ] || return 1
    IFS=$'\037' read -r dir state src live pid started ended detail <<< "$fields"
    [ -n "$state" ] || return 1
    [ "$pid" = "null" ] && pid=""

    tm=false
    for t in $terminals; do [ "$t" = "$state" ] && tm=true; done

    alias="$(job_alias "$dir" "$live" "$pid")"

    # Age is measured from the CONTRACT COPY's mtime. `claim` writes that file
    # once, before anything else, and nothing ever rewrites it — so it is the
    # moment the job started, on disk, with no ISO-8601 parsing and no second
    # date(1) dialect. The status file would be wrong here: it is rewritten on
    # adopt and on release, so its mtime is last activity, which is the OTHER
    # number below. `started_at` travels alongside for a reader that would
    # rather do its own arithmetic.
    age=""
    m="$(file_mtime "$dir/contract")"
    [ -n "$m" ] && [ -n "$now" ] && age=$((now - m))
    last=""
    m="$(file_mtime "$dir/log")"
    [ -n "$m" ] || m="$(file_mtime "$dir/status.json")"
    [ -n "$m" ] && [ -n "$now" ] && last=$((now - m))

    jq -nc --arg h "$h" --arg d "$dir" --arg s "$state" --arg src "$src" \
        --arg p "$pid" --arg a "$alias" --arg st "$started" --arg en "$ended" \
        --arg dt "$detail" --arg ag "$age" --arg la "$last" \
        --argjson live "$live" --argjson tm "$tm" '{
          handle:$h, state:$s, state_source:$src, live:$live, terminal:$tm,
          alias:(if $a == "" then null else $a end),
          pid:(if $p == "" then null else ($p|tonumber?) end),
          started_at:(if $st == "" then null else $st end),
          ended_at:(if $en == "" then null else $en end),
          age_seconds:(if $ag == "" then null else ($ag|tonumber?) end),
          last_activity_seconds_ago:(if $la == "" then null else ($la|tonumber?) end),
          job_dir:$d, log:($d + "/log"),
          detail:(if $dt == "" then null else $dt end)}' 2>/dev/null
}

# Sets JOBS_JSON, or leaves it empty. It NEVER dies and never changes an exit
# code: "is anything running here" is a side question, and a malformed record or
# a missing record layer must not cost the caller the liveness answer that
# status exists to give.
jobs_view() {
    JOBS_JSON=""
    [ -f "$JOBS_SH" ] || return 0
    local desc root worktree terminals
    desc="$(bash "$JOBS_SH" --describe 2>/dev/null)" || return 0
    [ -n "$desc" ] || return 0
    # The record layer resolves the worktree and honours SPAWN_JOB_ROOT; asking
    # it rather than re-deriving the path here is what keeps one answer to
    # "where do this worktree's jobs live".
    root="$(printf '%s' "$desc" | jq -r '.job_root // ""' 2>/dev/null)"
    worktree="$(printf '%s' "$desc" | jq -r '.worktree // ""' 2>/dev/null)"
    terminals="$(printf '%s' "$desc" | jq -r '(.terminal_states // []) | join(" ")' 2>/dev/null)"
    [ -n "$root" ] && [ -d "$root" ] || return 0

    local holder="" d name=""
    [ -f "$root/lock/job" ] && holder="$(tr -dc 'A-Za-z0-9._-' < "$root/lock/job" 2>/dev/null)"

    local -a cand=()
    for d in "$root"/*/; do
        [ -d "$d" ] || continue
        name="${d%/}"; name="${name##*/}"
        case "$name" in job-*) ;; *) continue ;; esac
        [ -f "$root/$name/status.json" ] || continue
        cand+=("$name")
    done
    [ "${#cand[@]}" -gt 0 ] || return 0

    local mins=0
    [ "$JOB_RETENTION" -ge 0 ] 2>/dev/null && mins=$(( (JOB_RETENTION + 59) / 60 ))

    local now listed=0 omitted=0 obj
    now="$(date +%s 2>/dev/null)"
    local -a objs=()
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        if [ "$mins" -gt 0 ] && [ "$name" != "$holder" ]; then
            [ -n "$(find "$root/$name/status.json" -maxdepth 0 -mmin "-$mins" 2>/dev/null)" ] || continue
        fi
        if [ "$listed" -ge "$JOB_REPORT_LIMIT" ]; then
            omitted=$((omitted + 1)); continue
        fi
        obj="$(job_entry "$name" "$root" "$terminals" "$now")" || continue
        [ -n "$obj" ] || continue
        objs+=("$obj")
        listed=$((listed + 1))
    done < <(printf '%s\n' "${cand[@]}" | sort -r)

    [ "${#objs[@]}" -gt 0 ] || return 0

    # KTD5, one sink: every string in the block goes through strip_display_deep
    # here rather than at each site. A job's `detail` is written by the
    # supervisor and a handle names a directory on disk — both are display text
    # a consumer prints, and the status file is a plain file anyone with the
    # worktree can edit.
    JOBS_JSON="$(printf '%s\n' "${objs[@]}" | jq -sc \
        --arg r "$root" --arg w "$worktree" --argjson om "$omitted" \
        --argjson ret "$JOB_RETENTION" --argjson lim "$JOB_REPORT_LIMIT" \
        "$SPAWN_SANITIZE_JQ_DEF"'
        { job_root:$r, worktree:$w, listed:.,
          running:([ .[] | select(.live) | .handle ] | first // null),
          omitted:$om, retention_seconds:$ret, limit:$lim }
        | strip_display_deep' 2>/dev/null)"
    case "$JOBS_JSON" in "" | null) JOBS_JSON="" ;; esac
    return 0
}
