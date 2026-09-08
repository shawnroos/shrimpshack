#!/usr/bin/env bats
# U10 — `team status`: what every member is doing, probed at the moment of
# asking (R14, R15, R22, R23, R30, KTD12, KTD13).
#
# EVERYTHING HAPPENS IN A TEMP REPOSITORY, for team.bats's reason:
# SPAWN_TEAM_WORKTREE_ROOT's derived default points at the real `worktrees/` of
# whatever checkout the suite runs from, where other people's live work is.
#
# TWO FALSE-GREEN TRAPS THIS FILE IS WRITTEN AGAINST
#   1. `! grep …` does NOT fail a bats test — POSIX exempts a pipeline starting
#      with `!`. Every absence goes through a helper that fails as a PLAIN
#      command, and every absence assertion has a control arm proving it fires.
#   2. An assertion true on day zero is not an assertion. The baseline records
#      below are written BY HAND (`cksum` inline), not with the library's own
#      fingerprint helper — a fixture built by the code under test cannot
#      witness that code.

setup() {
    LIB="$(cd "$BATS_TEST_DIRNAME/../../lib" && pwd)"
    TEAM="$LIB/team.sh"
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/gw-tview.XXXXXX")"; WORK="$(cd "$WORK" && pwd -P)"
    . "$BATS_TEST_DIRNAME/../lib/sweep.bash"
    # A FILE, not a variable: every helper below runs inside $( ), and an
    # assignment in a command substitution never reaches this shell — the first
    # version of this recorded three pids per test and killed none of them.
    PIDFILE="$WORK/pids"
    : > "$PIDFILE"

    PRIMARY="$WORK/proj"
    mkdir -p "$PRIMARY"
    git -C "$PRIMARY" init -q
    git -C "$PRIMARY" config user.email t@example.com
    git -C "$PRIMARY" config user.name tester
    printf 'seed\n' > "$PRIMARY/README.md"
    git -C "$PRIMARY" add README.md
    git -C "$PRIMARY" commit -qm seed

    export SPAWN_TEAM_WORKTREE_ROOT="$PRIMARY/worktrees"
    RUN="$WORK/run"
}

teardown() {
    while read -r p; do [ -n "$p" ] && kill -9 "$p" 2>/dev/null; done < "$PIDFILE"
    sweep_work
    rm -rf "$WORK"
}

# --- negatives that fail as plain commands ---------------------------------

refute_output_contains() {
    if printf '%s' "$1" | grep -qF -- "$2"; then
        printf 'refute_output_contains: found %s and must not\n' "$2" >&2
        return 1
    fi
    return 0
}

assert_json_key() {
    if [ "$(printf '%s' "$1" | jq -r 'if type == "object" then has("'"$2"'") else "notobject" end' 2>/dev/null)" != "true" ]; then
        printf 'assert_json_key: %s is absent from %s\n' "$2" "$1" >&2
        return 1
    fi
    return 0
}

assert_output_contains() {
    if ! printf '%s' "$1" | grep -qF -- "$2"; then
        printf 'assert_output_contains: %s is missing\n' "$2" >&2
        return 1
    fi
    return 0
}

# --- fixtures ---------------------------------------------------------------

contract() {            # <file> <deliverable>...
    local f="$1"; shift
    printf '%s\n' "$*" | tr ' ' '\n' | jq -Rs --arg t 'do the thing' \
        '{task:$t, deliverables:(split("\n") | map(select(length > 0)))}' > "$f"
}

team_cmd() {            # run team.sh from inside the temp checkout, never the real one
    run bash -c "cd '$PRIMARY' && bash '$TEAM' $* 2>/dev/null"
}

# One member's record row, through the record layer's own chokepoint so the
# derived block is recomputed exactly as a real write would leave it.
rec_set() {             # <name> <field> <value>
    bash -c "SCRIPT_DIR='$LIB'; . '$LIB/team-record.sh'; spawn::team_member_set '$RUN' '$1' '$2' '$3'" >/dev/null 2>&1
}

rec_round_open() {
    bash -c "SCRIPT_DIR='$LIB'; . '$LIB/team-record.sh'; spawn::team_round_open '$RUN'" >/dev/null 2>&1
}

new_handle() {          # <n>
    printf 'job-20260101T00000%sZ-100%s' "$1" "$1"
}

# A job directory in a member's OWN worktree, with the status file the record
# layer would have written. `state` here is a CLAIM: what resolves it is the pid.
plant_job() {           # <worktree> <handle> <claimed state> <pid>
    local wt="$1" h="$2" st="$3" pid="$4" d
    # A SEPARATE LINE, and it has to be: `local` expands all its words before it
    # assigns any of them, so `d="$wt/..."` on the line above read an empty $wt
    # and every planted job landed at /.spawn/.
    d="$wt/.spawn/$h"
    mkdir -p "$d"
    jq -nc --arg id "$h" --arg w "$wt" --arg d "$d" --arg s "$st" --arg p "$pid" \
        '{schema:"spawn.job/v1", job_id:$id, worktree:$w, job_dir:$d,
          contract:null, state:$s,
          pid:(if $p == "" then null else ($p|tonumber) end),
          started_at:"2026-01-01T00:00:00Z", ended_at:null, detail:null}' \
        > "$d/status.json"
    printf '%s' "$d"
}

# The pre-job baseline, WRITTEN BY HAND. `f:<cksum>` and `absent` are the two
# forms lib/common.sh produces; computing them here with cksum keeps the fixture
# independent of the code the assertions are about.
plant_baseline() {      # <job dir> <worktree> <path>...
    local d="$1" wt="$2"; shift 2
    local rel
    : > "$d/deliverables.list"
    : > "$d/baseline.deliverables"
    for rel in "$@"; do
        printf '%s\n' "$rel" >> "$d/deliverables.list"
        if [ -f "$wt/$rel" ]; then
            printf 'f:%s\t%s\n' "$(cksum < "$wt/$rel")" "$rel" >> "$d/baseline.deliverables"
        else
            printf 'absent\t%s\n' "$rel" >> "$d/baseline.deliverables"
        fi
    done
}

# A live process whose argv carries the job's marker as a WHOLE FIELD — what
# jobs.sh matches on.
#
# THE TRAILING `; :` IS LOAD-BEARING. `bash -c 'sleep 300' marker` optimises to
# an exec, and the marker vanishes from the process's argv along with the shell
# — every "running" member in this file resolved to `failed` for that reason,
# which is the same answer the dead-pid test wants and would have made two
# scenarios pass on one cause.
live_marked() {         # <handle>
    # THE REDIRECTS ARE THE FIXTURE, not decoration. >/dev/null 2>&1 because
    # these helpers run inside $( ) and a child holding the substitution's pipe
    # never lets it close; 3>&- because bats reads its TAP stream on fd 3 and
    # waits for every holder of it — a `sleep 300` that inherited fd 3 hung the
    # run AFTER the test had already printed `ok`.
    bash -c 'sleep 300; :' "spawn-bg-agent=$1" >/dev/null 2>&1 3>&- &
    local p=$!
    printf '%s\n' "$p" >> "$PIDFILE"
    printf '%s' "$p"
}

live_unmarked() {
    bash -c 'sleep 300; :' spawn-team-view-decoy >/dev/null 2>&1 3>&- &
    local p=$!
    printf '%s\n' "$p" >> "$PIDFILE"
    printf '%s' "$p"
}

dead_pid() {
    bash -c 'sleep 300; :' spawn-team-view-corpse >/dev/null 2>&1 3>&- &
    local p=$!
    kill -9 "$p" 2>/dev/null
    wait "$p" 2>/dev/null
    printf '%s' "$p"
}

# A three-member run with every member dispatched into round 1.
three_dispatched() {
    contract "$WORK/c1.json" out1.txt
    contract "$WORK/c2.json" out2.txt
    contract "$WORK/c3.json" out3.txt
    team_cmd roster --run-id r1 --run-dir "$RUN" \
        --member lead --alias sonnet --contract "$WORK/c1.json" \
        --member scout --alias haiku --contract "$WORK/c2.json" \
        --member mason --alias opus --contract "$WORK/c3.json"
    [ "$status" -eq 0 ]
    rec_round_open
    local i=1 n
    for n in lead scout mason; do
        rec_set "$n" handle "$(new_handle $i)"
        rec_set "$n" round 1
        rec_set "$n" started_at "2026-01-01T00:00:00Z"
        rec_set "$n" launch_state dispatched
        i=$((i + 1))
    done
}

wt_of() {               # <name>
    printf '%s/r1/%s' "$SPAWN_TEAM_WORKTREE_ROOT" "$1"
}

# ---------------------------------------------------------------------------

@test "U10: three members mid-round render three rows with state, elapsed, checklist and usage" {
    three_dispatched
    local i=1 n d
    for n in lead scout mason; do
        d="$(plant_job "$(wt_of "$n")" "$(new_handle $i)" running "$(live_marked "$(new_handle $i)")")"
        plant_baseline "$d" "$(wt_of "$n")" "out$i.txt"
        i=$((i + 1))
    done

    team_cmd status --run-dir "$RUN"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.members | length')" = 3 ]
    # PER FIELD, and on presence as well as value: `.elapsed_seconds` reads null
    # on a record with no such key at all, which would pass on day zero.
    printf '%s' "$output" | jq -e '
        all(.members[];
            (.state == "running")
            and (has("elapsed_seconds") and (.elapsed_seconds | type) == "number")
            and (has("deliverables") and (.deliverables | length) == 1)
            and (has("usage") and (.usage | has("state"))))'
}

@test "U10/R15: a member whose supervisor pid is gone renders failed, not what its status file claims" {
    three_dispatched
    local d
    d="$(plant_job "$(wt_of lead)" "$(new_handle 1)" running "$(dead_pid)")"
    plant_baseline "$d" "$(wt_of lead)" out1.txt

    team_cmd status --run-dir "$RUN"
    [ "$status" -eq 0 ]
    # The CLAIM is still `running` on disk — this is what makes the assertion
    # about resolution rather than about an empty status file.
    [ "$(jq -r '.state' "$(wt_of lead)/.spawn/$(new_handle 1)/status.json")" = running ]
    [ "$(printf '%s' "$output" | jq -r '.members[] | select(.name == "lead") | .state')" = failed ]
    [ "$(printf '%s' "$output" | jq -r '.members[] | select(.name == "lead") | .live')" = false ]
}

@test "U10/R15: a member whose argv marker does not match renders failed even though its pid is alive" {
    three_dispatched
    local pid d
    pid="$(live_unmarked)"
    d="$(plant_job "$(wt_of lead)" "$(new_handle 1)" running "$pid")"
    plant_baseline "$d" "$(wt_of lead)" out1.txt

    # The pid IS alive — without this the test would pass for the wrong reason.
    kill -0 "$pid"
    team_cmd status --run-dir "$RUN"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.members[] | select(.name == "lead") | .state')" = failed ]
}

@test "U10/KTD12: a deliverable that existed before the job and was not touched is unchanged, not progress" {
    three_dispatched
    local d wt; wt="$(wt_of lead)"
    printf 'pre-existing\n' > "$wt/out1.txt"
    d="$(plant_job "$wt" "$(new_handle 1)" running "$(live_marked "$(new_handle 1)")")"
    plant_baseline "$d" "$wt" out1.txt

    team_cmd status --run-dir "$RUN"
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '.members[] | select(.name == "lead") | .deliverables[0]
        | .path == "out1.txt" and .present == true and .changed == false
          and .status == "unchanged"'
    [ "$(printf '%s' "$output" | jq -r '.members[] | select(.name == "lead") | .progress.changed')" = 0 ]
}

@test "U10/KTD12: a deliverable that appeared during the run is marked progress" {
    three_dispatched
    local d wt; wt="$(wt_of lead)"
    d="$(plant_job "$wt" "$(new_handle 1)" running "$(live_marked "$(new_handle 1)")")"
    plant_baseline "$d" "$wt" out1.txt
    printf 'produced by the member\n' > "$wt/out1.txt"

    team_cmd status --run-dir "$RUN"
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '.members[] | select(.name == "lead") | .deliverables[0]
        | .present_before == false and .present == true and .changed == true
          and .status == "progress"'
}

@test "U10/KTD12: with no baseline on disk a present deliverable is unmeasured, never progress" {
    # The same class as the unchanged case, at the point where the comparison
    # has nothing to compare against. A member with no job directory has no
    # baseline, and `absent` is deliverable_state's answer for a missing record
    # — so a file that was in the checkout all along would read as "appeared".
    contract "$WORK/c1.json" already.txt
    team_cmd roster --run-id r1 --run-dir "$RUN" \
        --member lead --alias sonnet --contract "$WORK/c1.json"
    [ "$status" -eq 0 ]
    printf 'was here first\n' > "$(wt_of lead)/already.txt"

    team_cmd status --run-dir "$RUN"
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '.members[0].deliverables[0]
        | .path == "already.txt" and .present == true
          and .changed == null and .status == "unmeasured"'
    [ "$(printf '%s' "$output" | jq -r '.members[0].progress.changed')" = 0 ]
}

@test "U10/R23: the checklist has one line per contract path, including paths with nothing to report" {
    contract "$WORK/c1.json" one.txt two.txt three.txt
    team_cmd roster --run-id r1 --run-dir "$RUN" \
        --member lead --alias sonnet --contract "$WORK/c1.json"
    [ "$status" -eq 0 ]
    rec_round_open
    rec_set lead handle "$(new_handle 1)"
    rec_set lead round 1
    rec_set lead started_at "2026-01-01T00:00:00Z"
    rec_set lead launch_state dispatched
    local d wt; wt="$(wt_of lead)"
    d="$(plant_job "$wt" "$(new_handle 1)" running "$(live_marked "$(new_handle 1)")")"
    plant_baseline "$d" "$wt" one.txt two.txt three.txt
    printf 'x\n' > "$wt/two.txt"

    team_cmd status --run-dir "$RUN"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.members[0].deliverables | length')" = 3 ]
    printf '%s' "$output" | jq -e '[.members[0].deliverables[].path] == ["one.txt","two.txt","three.txt"]'
    printf '%s' "$output" | jq -e '[.members[0].deliverables[].status] == ["absent","progress","absent"]'
}

@test "U10/R15: a running member's usage renders unknown; a terminal member's renders its counts" {
    three_dispatched
    local d
    d="$(plant_job "$(wt_of lead)" "$(new_handle 1)" running "$(live_marked "$(new_handle 1)")")"
    plant_baseline "$d" "$(wt_of lead)" out1.txt
    # A LIVE member carrying counts. R15 says a member that has not reached a
    # terminal state reports unknown, never a number — so a leftover count on a
    # live row must not be believed. Without this planted count the assertion
    # would pass on a row that simply had nothing to report.
    rec_set lead tokens_input 111
    rec_set lead tokens_output 222

    d="$(plant_job "$(wt_of scout)" "$(new_handle 2)" done "")"
    plant_baseline "$d" "$(wt_of scout)" out2.txt
    rec_set scout outcome done
    rec_set scout tokens_input 700
    rec_set scout tokens_output 300

    team_cmd status --run-dir "$RUN"
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '.members[] | select(.name == "lead") | .usage
        | .state == "unknown" and .input == null and .output == null'
    printf '%s' "$output" | jq -e '.members[] | select(.name == "scout") | .usage
        | .state == "measured" and .input == 700 and .output == 300'
}

@test "U10/R15: a terminal member with only one of the two counts renders unknown, not half a number" {
    # THE CASE THE GUARD EXISTS FOR, found by mutation: with the guard removed
    # the running-member arm above still passed, because a live row never gets
    # as far as reading a count. Half a measurement is the arm that can only be
    # wrong — R30 stops a run on unknown usage, and a rendered input with a null
    # output reads to a human as a measured bill.
    three_dispatched
    rec_set lead outcome done
    rec_set lead tokens_input 900

    team_cmd status --run-dir "$RUN"
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '.members[] | select(.name == "lead") | .usage
        | .state == "unknown" and .input == null and .output == null'
}

@test "U10/R30: the unmeasured count appears in the response" {
    three_dispatched
    rec_set lead outcome done
    rec_set scout outcome done
    rec_set scout tokens_input 10
    rec_set scout tokens_output 20

    team_cmd status --run-dir "$RUN"
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e 'has("members_unmeasured") and (.members_unmeasured | type) == "number"'
    # lead is terminal with no counts; scout is measured; mason has not finished.
    [ "$(printf '%s' "$output" | jq -r '.members_unmeasured')" = 1 ]
}

@test "U10/KTD12: a member that produced nothing shows zero progress and its narrative reaches no output" {
    three_dispatched
    local d wt; wt="$(wt_of lead)"
    d="$(plant_job "$wt" "$(new_handle 1)" done "")"
    plant_baseline "$d" "$wt" out1.txt
    # The model's own account of itself, in the file the supervisor writes it to.
    jq -nc '{schema:"spawn.result/v1",
             narrative:{text:"ZZQUACKZZ I have completed every deliverable in full."},
             terminal_state:"degraded"}' > "$d/result.json"
    jq -nc '{result:"ZZQUACKZZ I have completed every deliverable in full."}' > "$d/child.json"
    rec_set lead outcome degraded

    team_cmd status --run-dir "$RUN"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.members[] | select(.name == "lead") | .progress.changed')" = 0 ]
    [ "$(printf '%s' "$output" | jq -r '.members[] | select(.name == "lead") | .deliverables[0].status')" = absent ]
    # DAY-ZERO GUARD: the marker is provably in the fixture on disk, so its
    # absence downstream is a fact about the render and not about the fixture.
    assert_output_contains "$(cat "$d/result.json")" ZZQUACKZZ
    refute_output_contains "$output" ZZQUACKZZ
}

@test "U10 control arm: the narrative absence assertion fires when the marker IS present" {
    three_dispatched
    # Same helper, same haystack shape, on text the render DOES carry — proving
    # refute_output_contains can fail rather than being vacuously true.
    run refute_output_contains '{"members":[{"name":"lead","last_log_line":"ZZQUACKZZ"}]}' ZZQUACKZZ
    [ "$status" -ne 0 ]
}

@test "U10/R14: a roster larger than the display cap renders the cap and reports the omitted count" {
    contract "$WORK/c.json" out.txt
    local args="" i
    for i in 1 2 3 4 5; do
        args="$args --member m$i --alias sonnet --contract $WORK/c.json"
    done
    team_cmd roster --run-id r1 --run-dir "$RUN" $args
    [ "$status" -eq 0 ]

    SPAWN_TEAM_VIEW_LIMIT=2 run bash -c "cd '$PRIMARY' && SPAWN_TEAM_VIEW_LIMIT=2 bash '$TEAM' status --run-dir '$RUN' 2>/dev/null"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.members | length')" = 2 ]
    [ "$(printf '%s' "$output" | jq -r '.listed')" = 2 ]
    [ "$(printf '%s' "$output" | jq -r '.omitted')" = 3 ]
}

@test "U10: a member whose worktree was removed renders unresolvable without aborting the render for the others" {
    three_dispatched
    local d
    d="$(plant_job "$(wt_of scout)" "$(new_handle 2)" running "$(live_marked "$(new_handle 2)")")"
    plant_baseline "$d" "$(wt_of scout)" out2.txt
    rm -rf "$(wt_of lead)"

    team_cmd status --run-dir "$RUN"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.members | length')" = 3 ]
    printf '%s' "$output" | jq -e '.members[] | select(.name == "lead")
        | .state == "unresolvable" and .error == "worktree_missing"'
    [ "$(printf '%s' "$output" | jq -r '.members[] | select(.name == "scout") | .state')" = running ]
}

@test "U10/R22: the diagram marks finished, running and pending rounds distinctly and expands only the running round" {
    three_dispatched
    # Round 1 closed (both its members terminal), round 2 open with mason in it.
    rec_set lead outcome done
    rec_set scout outcome done
    rec_round_open
    rec_set mason round 2

    team_cmd status --run-dir "$RUN"
    [ "$status" -eq 0 ]
    local dg; dg="$(printf '%s' "$output" | jq -r '.diagram')"
    assert_output_contains "$dg" 'flowchart TB'
    assert_output_contains "$dg" 'r1["round 1 — finished'
    assert_output_contains "$dg" 'r2["round 2 — running"]'
    assert_output_contains "$dg" 'r3["round 3 — pending"]'
    # Only the running round is expanded: mason is in round 2 and appears as a
    # member node; the finished round's members do not.
    assert_output_contains "$dg" 'r2 --> r2_m'
    refute_output_contains "$dg" 'r1 --> r1_m'
}

@test "U10/R22: the diagram's member states match the row states for the same members in one response" {
    three_dispatched
    local d i n
    i=1
    for n in lead scout mason; do
        d="$(plant_job "$(wt_of "$n")" "$(new_handle $i)" running "$(live_marked "$(new_handle $i)")")"
        plant_baseline "$d" "$(wt_of "$n")" "out$i.txt"
        i=$((i + 1))
    done
    # One member's supervisor is dead, so the states in this response are NOT
    # all the same word — a diagram built from a second source would show the
    # claim while the rows show the resolution.
    kill -9 $(jq -r '.pid' "$(wt_of mason)/.spawn/$(new_handle 3)/status.json") 2>/dev/null
    sleep 1

    team_cmd status --run-dir "$RUN"
    [ "$status" -eq 0 ]
    local dg; dg="$(printf '%s' "$output" | jq -r '.diagram')"
    [ "$(printf '%s' "$output" | jq -r '.members[] | select(.name == "mason") | .state')" = failed ]
    assert_output_contains "$dg" 'mason — failed'
    assert_output_contains "$dg" 'lead — running'
    refute_output_contains "$dg" 'mason — running'
}

@test "U10/KTD5: the diagram string passes through the same sanitizer as the rows" {
    three_dispatched
    # team.json is an ordinary file: the member-name grammar closes the ROSTER
    # path, not the file. An ESC written straight into the record must not reach
    # the diagram, which is built separately from the rows and would bypass the
    # sink if it were emitted on its own.
    python3 - "$RUN/team.json" <<'PY'
import json, sys
p = sys.argv[1]
r = json.load(open(p))
for m in r["members"]:
    if m["name"] == "lead":
        m["name"] = "lead]2;pwned"
json.dump(r, open(p, "w"))
PY
    # CONTROL ARM: the escape is provably in the record — read the way the
    # render reads it. json.dump writes the byte as the six characters ,
    # so a raw-byte grep over the file answers "no escape here" on a record that
    # decodes to one, which is the control arm passing for the wrong reason.
    run bash -c "jq -r '.members[].name' '$RUN/team.json' | python3 -c 'import sys; sys.exit(0 if chr(27) in sys.stdin.read() else 1)'"
    [ "$status" -eq 0 ]

    team_cmd status --run-dir "$RUN"
    [ "$status" -eq 0 ]
    printf '%s' "$output" > "$WORK/out.json"
    # Decoded, for the control arm's reason — and over EVERY string in the
    # response, the diagram among them, since the diagram is the one built
    # outside the row encoder.
    run bash -c "jq -r '[.. | strings] | join(\"\")' '$WORK/out.json' | python3 -c 'import sys; sys.exit(0 if chr(27) in sys.stdin.read() else 1)'"
    [ "$status" -ne 0 ]
    run bash -c "jq -r '.diagram' '$WORK/out.json' | python3 -c 'import sys; sys.exit(0 if chr(27) in sys.stdin.read() else 1)'"
    [ "$status" -ne 0 ]
    # And the name still reached the diagram, so the assertion above is about
    # stripping rather than about the member vanishing.
    assert_output_contains "$(jq -r '.diagram' "$WORK/out.json")" 'lead'
}

@test "U10: output is exactly one JSON object, on the failure path too" {
    three_dispatched
    team_cmd status --run-dir "$RUN"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -s 'length')" = 1 ]
    printf '%s' "$output" | jq -e 'type == "object"'

    team_cmd status --run-dir "$WORK/no-such-run"
    [ "$status" -ne 0 ]
    [ "$(printf '%s' "$output" | jq -s 'length')" = 1 ]
    printf '%s' "$output" | jq -e '.ok == false and .error == "record_missing" and (.remedy | length) > 0'
}

@test "U10: status writes nothing — the record is byte-identical before and after" {
    three_dispatched
    local before after
    before="$(cksum < "$RUN/team.json")"
    team_cmd status --run-dir "$RUN"
    [ "$status" -eq 0 ]
    after="$(cksum < "$RUN/team.json")"
    [ "$before" = "$after" ]
    # And no stray temp file was left in the run directory.
    [ "$(find "$RUN" -maxdepth 1 -name '.team.*' | wc -l | tr -d ' ')" = 0 ]
}

@test "U10: no function body in team-view.sh duplicates one in another shipped script" {
    run python3 - "$LIB" <<'PYEOF'
import sys, pathlib, re, hashlib
lib = pathlib.Path(sys.argv[1])
funcs = {}
for f in sorted(lib.glob("*.sh")):
    lines = f.read_text().split("\n"); i = 0
    while i < len(lines):
        one = re.match(r'^([A-Za-z_][A-Za-z0-9_:]*)\(\)\s*\{(.*)\}\s*$', lines[i])
        if one:
            b = re.sub(r'\s+', ' ', one.group(2).strip())
            if b:
                funcs.setdefault(hashlib.sha256(b.encode()).hexdigest(), []).append((f.name, one.group(1)))
            i += 1
            continue
        m = re.match(r'^([A-Za-z_][A-Za-z0-9_:]*)\(\)\s*\{\s*$', lines[i])
        if m:
            body = []; j = i + 1
            while j < len(lines) and not re.match(r'^\}', lines[j]):
                body.append(lines[j]); j += 1
            norm = [re.sub(r'\s+', ' ', l.strip()) for l in body
                    if l.strip() and not l.strip().startswith("#")]
            if norm:
                funcs.setdefault(hashlib.sha256("\n".join(norm).encode()).hexdigest(), []).append((f.name, m.group(1)))
            i = j
            continue
        i += 1
bad = 0
for group in funcs.values():
    where = sorted(set(group))
    if len(where) > 1 and any(a == "team-view.sh" for a, _ in where):
        print("DUPLICATE: " + ", ".join("%s:%s" % w for w in where)); bad = 1
sys.exit(bad)
PYEOF
    [ "$status" -eq 0 ]
}

@test "a member waiting to retry renders as retrying, not as unresolvable" {
    three_dispatched
    rec_set lead attempts \
        '[{"round":1,"handle":"job-x","outcome":"failed","failure":{"kind":"contract_unmet"},"tokens":{"input":10,"output":5}}]'
    rec_set lead handle null
    rec_set lead round null
    rec_set lead launch_state retry_pending

    team_cmd status --run-dir "$RUN"
    [ "$status" -eq 0 ]
    # A retried member holds no handle, so the probe below the state arm would
    # answer worktree_missing on a member the record accounts for exactly.
    [ "$(printf '%s' "$output" | jq -r '.members[] | select(.name == "lead") | .state')" = "retrying" ]
    [ "$(printf '%s' "$output" | jq -r '.members[] | select(.name == "lead") | .state_source')" = "record" ]
    [ "$(printf '%s' "$output" | jq -r '.members[] | select(.name == "lead") | .error')" = "null" ]
    [ "$(printf '%s' "$output" | jq -r '.members[] | select(.name == "lead") | .live')" = "false" ]
    [ "$(printf '%s' "$output" | jq -r '.members[] | select(.name == "lead") | .terminal')" = "false" ]
    [ "$(printf '%s' "$output" | jq -r '.pending')" = "1" ]
}

# --- U10 (failure-reporting plan): the cause and the served model on status ---
#
# The prefix says which U10: this file's older tests are the status verb's own
# unit from a different plan, and the tests below are the failure-reporting
# plan's U10. Same label, different plan, so evidence has to name which.

@test "U10-cause: a failed member's status row carries the failure object, not only an error string" {
    three_dispatched
    rec_set lead failure \
        '{"error":"child_failed","detail":"the child exited 3 before writing out1.txt","child_exit_code":3,"degraded_reasons":[]}'
    rec_set lead outcome failed

    team_cmd status --run-dir "$RUN"
    [ "$status" -eq 0 ]
    local row
    row="$(printf '%s' "$output" | jq -c '.members[] | select(.name == "lead")')"
    # KEY PRESENCE as well as value: `.failure.detail` reads null on a row with
    # no such key at all, which cannot fail on day zero.
    assert_json_key "$row" failure
    [ "$(printf '%s' "$row" | jq -r '.failure.detail')" = "the child exited 3 before writing out1.txt" ]
    [ "$(printf '%s' "$row" | jq -r '.failure.error')" = "child_failed" ]
    [ "$(printf '%s' "$row" | jq -r '.failure.child_exit_code')" = "3" ]
}

@test "U10-cause: a member served by another model carries served_model in its status row" {
    three_dispatched
    rec_set lead served_model claude-3-5-haiku-20241022
    rec_set lead outcome degraded

    team_cmd status --run-dir "$RUN"
    [ "$status" -eq 0 ]
    local row
    row="$(printf '%s' "$output" | jq -c '.members[] | select(.name == "lead")')"
    assert_json_key "$row" served_model
    [ "$(printf '%s' "$row" | jq -r '.served_model')" = "claude-3-5-haiku-20241022" ]
    # And it is NOT the alias the member asked for — the whole point of the field.
    [ "$(printf '%s' "$row" | jq -r '.alias')" = "sonnet" ]
}

@test "U10-cause: a member that succeeded carries failure null, and the key is there" {
    three_dispatched
    rec_set lead outcome succeeded

    team_cmd status --run-dir "$RUN"
    [ "$status" -eq 0 ]
    local row
    row="$(printf '%s' "$output" | jq -c '.members[] | select(.name == "lead")')"
    assert_json_key "$row" failure
    [ "$(printf '%s' "$row" | jq -r '.failure | type')" = "null" ]
}

@test "U10-cause: a never-dispatched member carries failure null and served_model null, never its alias" {
    contract "$WORK/c1.json" out1.txt
    team_cmd roster --run-id r1 --run-dir "$RUN" \
        --member lead --alias sonnet --contract "$WORK/c1.json"
    [ "$status" -eq 0 ]

    team_cmd status --run-dir "$RUN"
    [ "$status" -eq 0 ]
    local row
    row="$(printf '%s' "$output" | jq -c '.members[] | select(.name == "lead")')"
    assert_json_key "$row" failure
    assert_json_key "$row" served_model
    [ "$(printf '%s' "$row" | jq -r '.failure | type')" = "null" ]
    [ "$(printf '%s' "$row" | jq -r '.served_model | type')" = "null" ]
    # ABSENT IS NULL. A row that filled the field from the request would read
    # `sonnet` here and claim an attribution nothing measured.
    [ "$(printf '%s' "$row" | jq -r '.launch_state')" = "pending" ]
}

# MEASURED ON A LIVE RUN, not imagined. A degraded member reported error:null
# on this surface beside a populated failure.detail, because the probe resolved
# it cleanly and had nothing of its own to say. A reader seeing error:null next
# to a cause reads "no error" — the defect this branch exists to remove. The
# advance envelope said "degraded" for the same member at the same moment.
#
# `pending` is the reachable way to force a SILENT probe here: that arm returns
# with TV_ERR empty, which is the same condition a cleanly-resolved terminal job
# produces live. The rule under test is the projection, not the arm.
@test "U10-cause: a silent probe lets the recorded cause reach error" {
    three_dispatched
    rec_set lead launch_state pending
    rec_set lead failure \
        '{"error":"degraded","detail":"the child exited 0, which is not evidence work happened","child_exit_code":0,"degraded_reasons":["the contract names out1.txt, and it is not there"]}'

    team_cmd status --run-dir "$RUN"
    [ "$status" -eq 0 ]
    local row
    row="$(printf '%s' "$output" | jq -c '.members[] | select(.name == "lead")')"
    assert_json_key "$row" error
    [ "$(printf '%s' "$row" | jq -r '.failure.detail')" != "null" ]
    [ "$(printf '%s' "$row" | jq -r '.error')" = "degraded" ]
}

# The probe still WINS where it speaks. worktree_missing is a fact about right
# now that no record holds, and a cause that settled rounds ago must not mask it.
@test "U10-cause: a live probe answer outranks the recorded cause on status" {
    three_dispatched
    rec_set lead failure \
        '{"error":"child_failed","detail":"the child exited 3","child_exit_code":3,"degraded_reasons":[]}'
    rec_set lead outcome failed
    rm -rf "$(wt_of lead)"

    team_cmd status --run-dir "$RUN"
    [ "$status" -eq 0 ]
    local row
    row="$(printf '%s' "$output" | jq -c '.members[] | select(.name == "lead")')"
    [ "$(printf '%s' "$row" | jq -r '.error')" = "worktree_missing" ]
    [ "$(printf '%s' "$row" | jq -r '.failure.error')" = "child_failed" ]
}

# The record holds the launcher's OWN value for a failed launch (U3). The probe
# arm can only say the category, so a status row that stopped at launch_failed
# was hiding a contract_invalid the record was already holding.
@test "U10-cause: a launch failure shows the launcher's own error, not the category" {
    three_dispatched
    rec_set lead launch_state launch_failed
    rec_set lead failure '{"error":"contract_invalid","detail":"the contract named by this member does not parse","child_exit_code":null,"degraded_reasons":null}'

    team_cmd status --run-dir "$RUN"
    [ "$status" -eq 0 ]
    local row
    row="$(printf '%s' "$output" | jq -c '.members[] | select(.name == "lead")')"
    [ "$(printf '%s' "$row" | jq -r '.error')" = "contract_invalid" ]
    [ "$(printf '%s' "$row" | jq -r '.failure.error')" = "contract_invalid" ]
}

# A launch that failed before any launcher answered has no recorded cause, so
# the category is all there is and must still be reported.
@test "U10-cause: a launch failure with no recorded cause still reports the category" {
    three_dispatched
    rec_set lead launch_state launch_failed

    team_cmd status --run-dir "$RUN"
    [ "$status" -eq 0 ]
    local row
    row="$(printf '%s' "$output" | jq -c '.members[] | select(.name == "lead")')"
    [ "$(printf '%s' "$row" | jq -r '.error')" = "launch_failed" ]
}

# team-view's own jq -r fork reads .allow and .grants off the member object by
# a fixed field ORDER, matched by a `read -r` block of the same length and
# order — a field dropped from either side, or the two lists drifting apart,
# shifts every read after it rather than failing loudly. status is the only
# surface that has to re-derive this projection (dispatch and advance answer
# from the member object directly), so it is the one place this can silently
# stop happening.
@test "U10: a member's requested allow reaches its status row" {
    contract "$WORK/c1.json" out1.txt
    team_cmd roster --run-id r1 --run-dir "$RUN" \
        --member lead --alias sonnet --contract "$WORK/c1.json" --allow Bash
    [ "$status" -eq 0 ]

    team_cmd status --run-dir "$RUN"
    [ "$status" -eq 0 ]
    local row
    row="$(printf '%s' "$output" | jq -c '.members[] | select(.name == "lead")')"
    assert_json_key "$row" allow
    [ "$(printf '%s' "$row" | jq -c '.allow')" = '["Bash"]' ]
}

@test "U10: a member that asked for nothing renders allow as an empty array, not absent" {
    three_dispatched

    team_cmd status --run-dir "$RUN"
    [ "$status" -eq 0 ]
    local row
    row="$(printf '%s' "$output" | jq -c '.members[] | select(.name == "lead")')"
    assert_json_key "$row" allow
    [ "$(printf '%s' "$row" | jq -c '.allow')" = '[]' ]
}

@test "U10: what the ceiling actually applied reaches the status row as grants" {
    three_dispatched
    rec_set lead grants '["Bash"]'

    team_cmd status --run-dir "$RUN"
    [ "$status" -eq 0 ]
    local row
    row="$(printf '%s' "$output" | jq -c '.members[] | select(.name == "lead")')"
    assert_json_key "$row" grants
    [ "$(printf '%s' "$row" | jq -c '.grants')" = '["Bash"]' ]
}

# grants stays null until a result lands (R15's contract), and a member's own
# allow request must never be mistaken for what actually reached it.
@test "U10: a member still in flight renders grants null, distinct from its own allow" {
    contract "$WORK/c1.json" out1.txt
    team_cmd roster --run-id r1 --run-dir "$RUN" \
        --member lead --alias sonnet --contract "$WORK/c1.json" --allow WebSearch
    [ "$status" -eq 0 ]

    team_cmd status --run-dir "$RUN"
    [ "$status" -eq 0 ]
    local row
    row="$(printf '%s' "$output" | jq -c '.members[] | select(.name == "lead")')"
    [ "$(printf '%s' "$row" | jq -r '.grants | type')" = "null" ]
    [ "$(printf '%s' "$row" | jq -c '.allow')" = '["WebSearch"]' ]
}
