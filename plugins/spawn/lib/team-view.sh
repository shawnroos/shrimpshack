#!/usr/bin/env bash
# team-view.sh — the `status` verb's view of one team run (U10, R14, R15).
#
# WHY THIS IS ITS OWN FILE: jobs-view.sh's argument, one layer up. Rendering is
# not the dispatch path's concern, and team.sh is already the largest surface
# here. It is SOURCED into team.sh, which is why the globals stay globals and
# why `team_epoch_of` is called rather than re-written — a second copy of that
# helper is a duplicate body, and tests/unit/escapes.bats has no length floor.
#
# WHAT THIS FILE MAY NOT DO, and the reason it is worth stating: it NEVER
# writes. `advance` probes and records; `status` probes and reports. Every
# derived figure it prints (`ceiling_state`, `members_unmeasured`) is read from
# the record's `.derived` block, which was recomputed at whatever write last
# touched the run — so a figure here is as of that write, and nothing may branch
# on it. Deciding from a derivation you did not write is the drift KTD18 exists
# to prevent; U10 only displays, which is what makes a plain read honest here.
#
# NOTHING BELOW READS A NARRATIVE. `narrative.text` is the one model-authored
# field in this plugin, and a status render that interpolated it would be a
# model's claim wearing the plugin's voice. Progress is measured against the
# pre-job baseline instead (KTD12) — deliverable_state in common.sh, the same
# comparison the supervisor judges a finished job with.
#
# shellcheck shell=bash

# Its own dependencies, named here rather than assumed from the sourcing script,
# for the reason jobs-view.sh states: escapes.bats's sink lint walks source
# edges transitively, so a fragment that inherits its chokepoints must say so.
# shellcheck source=./sanitize.sh
. "$SCRIPT_DIR/sanitize.sh"
# shellcheck source=./common.sh
. "$SCRIPT_DIR/common.sh"

# The same convention jobs-view.sh uses: newest first, capped, and the number
# dropped by the cap reported rather than swallowed.
TEAM_VIEW_LIMIT="${SPAWN_TEAM_VIEW_LIMIT:-10}"
TEAM_VIEW_JSON=""

# The last non-empty line of a member's own job log.
#
# TODAY EVERY WRITER OF THAT LOG IS THE SUPERVISOR, writing its own literals —
# the child's own output goes to child.json and child.err, not here — so this
# line carries no model prose and calling it "free-form text written by the
# child's CLI", as this comment once did, invited the wrong conclusion in both
# directions: that the value is already untrusted, and therefore that piping
# child.err in here would change nothing.
#
# It would change everything. `narrative.text` is the one untrusted field in
# this plugin and nothing renders it; a log tail carrying model output would put
# third-party prose into a status render and into the prompt hook that consumes
# this, which is the laundering both surfaces exist to prevent. It still reaches
# the sanitizer sink with everything else, because sanitising is about terminal
# control bytes, not about trust — a sanitised model claim is still a model
# claim wearing the plugin's voice.

team_view_log_tail() {  # <job dir>
    local f="$1/log"
    [ -f "$f" ] || return 0
    tail -n 20 "$f" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -n 1
}

# One member's RESOLVED state (R15, KTD6). Sets TV_STATE, TV_SOURCE, TV_LIVE,
# TV_JOBDIR and TV_ERR.
#
# A status file is a CLAIM: after a kill it still says `running`, because the
# writer is what died. `jobs.sh state` is the only thing that decides a state
# here — it resolves by `kill -0` plus a whole-field argv match — and a second
# opinion in this file is how the two would drift.
#
# The --cwd is never empty: jobs.sh's resolve_worktree falls back to $PWD, so a
# member with no checkout probed with an empty --cwd would answer about the
# DRIVER's own worktree. A member with no checkout is reported, never probed.
team_view_probe() {     # <launch_state> <handle> <worktree>
    local ls="$1" handle="$2" wt="$3" out
    TV_STATE=""; TV_SOURCE="probe"; TV_LIVE=false; TV_JOBDIR=""; TV_ERR=""
    case "$ls" in
        pending)
            TV_STATE="pending"; TV_SOURCE="record"; return 0 ;;
        retry_pending)
            # A member waiting for its next attempt holds no handle, so falling
            # through to the probe below would report it worktree_missing or
            # unresolvable — a member the record can account for exactly.
            TV_STATE="retrying"; TV_SOURCE="record"; return 0 ;;
        launch_failed)
            # R5: the launcher's specific error rides dispatch's response and is
            # not in the record, so this surface can say THAT a member failed to
            # launch and not why. Inventing a reason would be worse than the gap.
            TV_STATE="failed"; TV_SOURCE="record"; TV_ERR="launch_failed"; return 0 ;;
    esac
    if [ -z "$handle" ] || [ -z "$wt" ] || [ ! -d "$wt" ]; then
        TV_STATE="unresolvable"; TV_ERR="worktree_missing"; return 0
    fi
    out="$(bash "$JOBS_SH" state --handle "$handle" --cwd "$wt" 2>/dev/null)"
    # ONE jq over an answer already in memory, not one per field. This runs on
    # the prompt-submit path, once per member per run: at the shipped bounds
    # (12 members x 4 runs) the field-at-a-time shape cost 4.7s of forks alone
    # against a 5s budget, so the hook could exceed its deadline before probing
    # anything. Measured on this box; the tab split is what keeps it one fork.
    # ONE FIELD PER LINE, never @tsv into `read`. Tab is an IFS *whitespace*
    # character, so a run of tabs collapses to one delimiter and every field
    # after an empty one shifts left — an absent `error` silently becomes the
    # state_source. Line-per-field has no such collapse: `read` returns an empty
    # string for an empty line.
    local fields
    fields="$(printf '%s' "$out" | jq -r '(.job.state // ""), (.error // ""),
        (.job.state_source // "probe"), ((.job.live // false) | tostring),
        (.job.job_dir // "")' 2>/dev/null)"
    {
        read -r TV_STATE
        read -r TV_ERR
        read -r TV_SOURCE
        read -r TV_LIVE
        read -r TV_JOBDIR
    } <<EOF
$fields
EOF
    if [ -z "$TV_STATE" ]; then
        TV_STATE="unresolvable"
        [ -n "$TV_ERR" ] || TV_ERR="handle_unknown"
        TV_SOURCE=""; TV_LIVE=false; TV_JOBDIR=""
        return 0
    fi
    TV_ERR=""
    case "$TV_LIVE" in true|false) ;; *) TV_LIVE=false ;; esac
    return 0
}

# The per-path checklist (R23, KTD12), as a JSON array — one line per path the
# contract names, including the paths with nothing to report.
#
# THE BASELINE IS WHAT MAKES A PATH READABLE AT ALL. `deliverable_state` treats a
# missing baseline record as "was absent", so a file that was sitting there
# before the run would read as changed — present-but-untouched reported as
# progress, which is the exact failure KTD9 exists to prevent, one surface over.
# So a member with no baseline on disk (never launched, or its job directory is
# gone) reports `unmeasured` per path: presence is still stated, progress is not
# claimed.
team_view_deliverables() {  # <job dir> <contract path> <worktree>
    local dir="$1" contract="$2" wt="$3" list="" base="" rel row
    if [ -n "$dir" ] && [ -f "$dir/deliverables.list" ]; then
        list="$dir/deliverables.list"
        [ -f "$dir/baseline.deliverables" ] && base="$dir/baseline.deliverables"
    fi
    { if [ -n "$list" ]; then
          cat "$list" 2>/dev/null
      elif [ -n "$contract" ] && [ -f "$contract" ]; then
          jq -r 'if (.deliverables | type) == "array"
                 then .deliverables[] | select(type == "string") | select(length > 0)
                 else empty end' < "$contract" 2>/dev/null
      fi
    } | { while IFS= read -r rel; do
            [ -n "$rel" ] || continue
            if [ -n "$base" ] && [ -n "$wt" ] && [ -d "$wt" ]; then
                row="$(deliverable_state "$base" "$wt" "$rel")"
                printf '%s\t%s\n' "$rel" "$row"
            elif [ -n "$wt" ] && [ -e "$wt/$rel" ]; then
                printf '%s\tunknown\ttrue\tunknown\n' "$rel"
            else
                printf '%s\tunknown\tfalse\tunknown\n' "$rel"
            fi
        done; } \
      | jq -Rsc 'split("\n") | map(select(length > 0) | split("\t"))
                 | map({path:.[0],
                        present_before:(if .[1] == "unknown" then null else .[1] == "true" end),
                        present:(.[2] == "true"),
                        changed:(if .[3] == "unknown" then null else .[3] == "true" end)}
                       | . + {status:(if .changed == null then "unmeasured"
                                      elif (.present | not) then "absent"
                                      elif .changed then "progress"
                                      else "unchanged" end)})'
}

# One member row. Returns 1 if the row could not be encoded, and the caller
# drops that member rather than reporting a half-row.
team_view_row() {       # <index> <member json>
    local idx="$1" m="$2" name ls handle wt contract alias round started
    local deliv elapsed="" last="" epoch term=false ti="null" to="null" usage="unknown"
    # One fork over one in-memory object, one field per line — see the note in
    # team_view_probe for why this is not @tsv, and why the fork count matters
    # on a path that runs per member per run on every prompt submit.
    local mfields
    mfields="$(printf '%s' "$m" | jq -r '(.name // ""), (.launch_state // ""),
        (.handle // ""), (.worktree // ""), (.contract // ""), (.alias // ""),
        (if .round == null then "" else (.round | tostring) end),
        (.started_at // ""), ((.outcome != null) | tostring),
        (.tokens.input // "null" | tostring), (.tokens.output // "null" | tostring),
        (.failure | tojson), (.served_model | tojson)')"
    local has_outcome fail_json sm_json
    {
        read -r name
        read -r ls
        read -r handle
        read -r wt
        read -r contract
        read -r alias
        read -r round
        read -r started
        read -r has_outcome
        read -r ti
        read -r to
        # tojson, never a raw read: `failure` is an OBJECT, and jq -r would
        # pretty-print it across lines and shift every read after it.
        read -r fail_json
        read -r sm_json
    } <<EOF
$mfields
EOF

    team_view_probe "$ls" "$handle" "$wt"
    deliv="$(team_view_deliverables "$TV_JOBDIR" "$contract" "$wt")"
    [ -n "$deliv" ] || deliv='[]'
    last="$(team_view_log_tail "$TV_JOBDIR")"

    if [ -n "$started" ] && [ -n "$TEAM_VIEW_NOW" ]; then
        epoch="$(team_epoch_of "$started")" && elapsed=$(( TEAM_VIEW_NOW - epoch ))
    fi

    # R15's hard edge: a member that has not reached a terminal state reports
    # usage as unknown, NEVER as a number — the child emits usage only when it
    # finishes, so a count on a live member is a leftover, not a measurement.
    # The record's counts are believed only once the record also says terminal.
    if [ "$ls" = "launch_failed" ] || [ "$has_outcome" = "true" ]; then
        term=true
        [ "$ti" = "null" ] || [ "$to" = "null" ] || usage="measured"
    fi
    [ "$usage" = "measured" ] || { ti="null"; to="null"; }

    # The PROBE's answer first, the recorded cause behind it. Measured live: a
    # member that degraded reported error:null here beside a real failure.detail,
    # because the probe resolved it fine and had nothing of its own to say — and
    # a reader who sees error:null next to a cause reads "no error", which is
    # the whole defect this surface was changed to remove.
    #
    # The probe still WINS where it speaks: worktree_missing is a fact about
    # right now that no record holds, and it must not be masked by a cause that
    # settled rounds ago. The two only ever differ when both have something to
    # say, and then the live reading is the more urgent one.
    jq -nc --arg n "$name" --arg a "$alias" --arg w "$wt" --arg ls "$ls" \
        --arg h "$handle" --arg st "$TV_STATE" --arg src "$TV_SOURCE" \
        --arg e "$TV_ERR" --arg r "$round" --arg sa "$started" --arg el "$elapsed" \
        --arg ll "$last" --arg us "$usage" --argjson idx "$idx" \
        --argjson live "$TV_LIVE" --argjson term "$term" \
        --argjson dl "$deliv" --argjson ti "$ti" --argjson to "$to" \
        --argjson fail "${fail_json:-null}" --argjson sm "${sm_json:-null}" '{
          idx:$idx, name:$n, alias:$a, worktree:$w, launch_state:$ls,
          handle:(if $h == "" then null else $h end),
          state:$st, state_source:$src, live:$live, terminal:$term,
          error:(if $e != "" then $e else ($fail.error // null) end),
          failure:$fail, served_model:$sm,
          round:(if $r == "" then null else ($r | tonumber?) end),
          started_at:(if $sa == "" then null else $sa end),
          elapsed_seconds:(if $el == "" then null else ($el | tonumber?) end),
          deliverables:$dl,
          progress:{paths:($dl | length),
                    changed:([ $dl[] | select(.status == "progress") ] | length),
                    unchanged:([ $dl[] | select(.status == "unchanged") ] | length),
                    absent:([ $dl[] | select(.status == "absent") ] | length),
                    unmeasured:([ $dl[] | select(.status == "unmeasured") ] | length)},
          usage:{state:$us, input:$ti, output:$to},
          last_log_line:(if $ll == "" then null else $ll end)}' 2>/dev/null
}

# The loop diagram (R22) — a SECOND VIEW of the rows above, never a second
# source. Every member state in it is read out of $rows, which is the array the
# member rows are rendered from, so the two cannot disagree; the only thing it
# adds is the round ledger, which is the record's and is not probed at all.
#
# Node ids are positional (r<ordinal>, r<ordinal>_m<idx>) rather than built from
# names: a member name is a safe directory component but not a safe mermaid id,
# and team.json is a plain file anything on the box can write.
TEAM_VIEW_DIAGRAM_JQ='
def lbl: tostring | gsub("[\"\\[\\]]"; "");
. as $rec
| ($rec.bounds.max_rounds // 0) as $mr
| ([ $rec.rounds[]? | {ordinal, state, verdict} ]) as $rs
| ($rs | length) as $used
| ($rs + (if $mr > $used then [ range($used + 1; $mr + 1) | {ordinal:., state:"pending", verdict:null} ] else [] end)) as $all
| ([ $all[] | select(.state == "running") | .ordinal ]) as $act
| ([ "flowchart TB" ]
   + [ $all[] | "  r\(.ordinal)[\"round \(.ordinal) — \(.state | lbl)\(if .verdict then " (" + (.verdict | lbl) + ")" else "" end)\"]" ]
   + [ $rows[] | . as $r
       | select($r.round != null and ($act | index($r.round)) != null)
       | "  r\($r.round) --> r\($r.round)_m\($r.idx)[\"\($r.name | lbl) — \($r.state | lbl)\"]" ]
   + [ range(0; ($all | length) - 1) | "  r\($all[.].ordinal) --> r\($all[. + 1].ordinal)" ])
| join("\n")
'

# Sets TEAM_VIEW_JSON from a record already read by the caller. It never dies
# and never changes an exit code: a member whose worktree is gone costs that
# member's fields, not the render.
team_view() {           # <record json>
    local rec="$1" m idx=0 listed=0 omitted=0 total obj rows diagram
    TEAM_VIEW_JSON=""
    TEAM_VIEW_NOW="$(date -u '+%s' 2>/dev/null)"
    total="$(printf '%s' "$rec" | jq -r '.members | length' 2>/dev/null)"
    case "$total" in ''|*[!0-9]*) return 0 ;; esac

    # Newest first, on the record's own `started_at`, with the members that have
    # never started last — and the cap applied AFTER the sort and BEFORE any
    # probe, so the subprocess cost is bounded by the limit rather than by the
    # roster. Ties keep roster order: jq's sort_by is stable.
    local -a objs=()
    while IFS= read -r m; do
        [ -n "$m" ] || continue
        if [ "$listed" -ge "$TEAM_VIEW_LIMIT" ]; then
            omitted=$((omitted + 1)); continue
        fi
        obj="$(team_view_row "$idx" "$m")" || { idx=$((idx + 1)); continue; }
        [ -n "$obj" ] || { idx=$((idx + 1)); continue; }
        objs+=("$obj")
        listed=$((listed + 1)); idx=$((idx + 1))
    # STARTED MEMBERS FIRST, NEWEST FIRST, then the never-started in roster
    # order. The cap truncates the TAIL, so the order decides who gets dropped —
    # and a `| reverse` here put the never-started members at the head, so a
    # roster larger than the cap omitted exactly the members in flight, which are
    # the only reason to call status at all. Reverse only the started group, by
    # sorting that group on a descending key, rather than reversing the whole
    # list and taking the never-started group with it.
    done < <(printf '%s' "$rec" | jq -c '
        [ .members[] ] | to_entries
        | ( map(select(.value.started_at != null))
            | sort_by(.value.started_at) | reverse )
          + ( map(select(.value.started_at == null)) )
        | .[] | .value' 2>/dev/null)

    if [ "${#objs[@]}" -gt 0 ]; then
        rows="$(printf '%s\n' "${objs[@]}" | jq -sc '.')"
    else
        rows='[]'
    fi
    diagram="$(printf '%s' "$rec" | jq -r --argjson rows "$rows" "$TEAM_VIEW_DIAGRAM_JQ" 2>/dev/null)"

    # KTD5, ONE SINK: rows and the diagram string alike. The diagram is built
    # separately and would bypass this if it were emitted anywhere else — it
    # carries member names and resolved states, and the record it is built from
    # is an ordinary file.
    TEAM_VIEW_JSON="$(printf '%s' "$rec" | jq -c --argjson rows "$rows" \
        --arg dg "$diagram" --argjson om "$omitted" --argjson lim "$TEAM_VIEW_LIMIT" \
        "$SPAWN_SANITIZE_JQ_DEF"'
        { members:$rows, listed:($rows | length), omitted:$om, limit:$lim,
          diagram:$dg,
          members_unmeasured:.derived.members_unmeasured,
          ceiling_state:.derived.ceiling_state,
          complete:.derived.complete }
        | strip_display_deep' 2>/dev/null)"
    case "$TEAM_VIEW_JSON" in "" | null) TEAM_VIEW_JSON="" ;; esac
    return 0
}
