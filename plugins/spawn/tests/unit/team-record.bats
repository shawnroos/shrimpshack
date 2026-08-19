#!/usr/bin/env bats
# The team run record and its single write chokepoint (U14, KTD18, KTD5).
#
# The property every later unit leans on: every derived fact — round state and
# verdict, round membership, token totals, the bounds evaluation, the stop
# reasons — is recomputed inside the one function that writes the record. No
# reader recomputes anything, so there is nowhere for a stale value to live.

setup() {
    LIB="$(cd "$BATS_TEST_DIRNAME/../../lib" && pwd)"
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/gw-teamrec.XXXXXX")"; WORK="$(cd "$WORK" && pwd -P)"
    RUN="$WORK/run"; mkdir -p "$RUN"
}
teardown() { rm -rf "$WORK"; }

tr_() { bash -c '. "$1"; shift; "$@"' _ "$LIB/team-record.sh" "$@"; }

# The refusal VALUE a failed record call left behind. tr_ runs in a command
# substitution, so the callee's SPAWN_TEAM_ERROR never reaches this shell.
tr_err() {
    bash -c '. "$1"; shift; "$@" >/dev/null 2>&1; printf "%s" "$SPAWN_TEAM_ERROR"' \
        _ "$LIB/team-record.sh" "$@"
}

# Negatives go through helpers that fail as PLAIN COMMANDS. `! grep …` does not
# fail a bats test — POSIX exempts a pipeline beginning with `!`, and three
# assertions in this repo passed while what they guarded was false.
refute_file_match() {   # <extended-regex> <file...>
    local pat="$1"; shift
    if grep -Eq "$pat" "$@" 2>/dev/null; then
        printf 'refute_file_match: unexpected match for %s in %s\n' "$pat" "$*" >&2
        return 1
    fi
    return 0
}

refute_exists() {       # <path>
    if [ -e "$1" ]; then
        printf 'refute_exists: %s exists and must not\n' "$1" >&2
        return 1
    fi
    return 0
}

field() {               # <jq-path> — prints the value, fails if the read fails
    tr_ spawn::team_record_read "$RUN" | jq -r "$1"
}

seed() {                # a two-member record with one open round
    tr_ spawn::team_record_new "$RUN" run-1 attached 2 3 100000
    tr_ spawn::team_member_add "$RUN" lead sonnet "$WORK/wt/lead" "$WORK/c1.md" "ce-code-review lint-router"
    tr_ spawn::team_member_add "$RUN" scout haiku "$WORK/wt/scout" "$WORK/c2.md" "ce-code-review"
    tr_ spawn::team_round_open "$RUN"
}

@test "every member field round-trips, including round assignment and started_at" {
    seed
    tr_ spawn::team_member_set "$RUN" lead launch_state dispatched
    tr_ spawn::team_member_set "$RUN" lead handle job-20260814T101500Z-1234
    tr_ spawn::team_member_set "$RUN" lead round 1
    tr_ spawn::team_member_set "$RUN" lead started_at 2026-08-14T10:15:00Z

    [ "$(field '.members[0].name')" = "lead" ]
    [ "$(field '.members[0].alias')" = "sonnet" ]
    [ "$(field '.members[0].worktree')" = "$WORK/wt/lead" ]
    [ "$(field '.members[0].contract')" = "$WORK/c1.md" ]
    [ "$(field '.members[0].skills | join(",")')" = "ce-code-review,lint-router" ]
    [ "$(field '.members[0].launch_state')" = "dispatched" ]
    [ "$(field '.members[0].handle')" = "job-20260814T101500Z-1234" ]
    [ "$(field '.members[0].round')" = "1" ]
    [ "$(field '.members[0].started_at')" = "2026-08-14T10:15:00Z" ]
    [ "$(field '.members[1].name')" = "scout" ]
    [ "$(field '.members[1].handle')" = "null" ]
    [ "$(field '.members[1].launch_state')" = "pending" ]
}

@test "the round ledger round-trips: ordinal, state, open time, close time, verdict" {
    seed
    [ "$(field '.rounds[0].ordinal')" = "1" ]
    [ "$(field '.rounds[0].state')" = "running" ]
    [ "$(field '.rounds[0].closed_at')" = "null" ]
    [ "$(field '.rounds[0].verdict')" = "null" ]
    [ "$(field '.rounds[0].opened_at | test("^[0-9]{4}-")')" = "true" ]

    for m in lead scout; do
        tr_ spawn::team_member_set "$RUN" "$m" round 1
        tr_ spawn::team_member_set "$RUN" "$m" launch_state dispatched
        tr_ spawn::team_member_set "$RUN" "$m" outcome done
    done
    [ "$(field '.rounds[0].state')" = "finished" ]
    [ "$(field '.rounds[0].verdict')" = "pass" ]
    [ "$(field '.rounds[0].closed_at | test("^[0-9]{4}-")')" = "true" ]
    [ "$(field '.rounds[0].members | join(",")')" = "lead,scout" ]
}

@test "every field U10, U13 and U15 read is present in a record U14 wrote alone" {
    seed
    tr_ spawn::team_member_set "$RUN" lead round 1
    tr_ spawn::team_member_set "$RUN" lead started_at 2026-08-14T10:15:00Z
    local rec; rec="$(tr_ spawn::team_record_read "$RUN")"
    local p
    for p in .run_id .mode .created_at \
             .bounds.max_concurrent .bounds.max_rounds .bounds.token_ceiling \
             '.rounds[0].ordinal' '.rounds[0].state' '.rounds[0].opened_at' \
             '.rounds[0].members' '.rounds[0].tokens.total' '.rounds[0].tokens.unknown' \
             '.members[0].name' '.members[0].alias' '.members[0].round' \
             '.members[0].started_at' '.members[0].launch_state' '.members[0].skills' \
             .derived.verdict .derived.continue .derived.active_round \
             .derived.active_round_state .derived.dispatch_allowed \
             .derived.stop_reasons .derived.tokens_used .derived.usage_unknown \
             .derived.bounds.rounds_used .derived.bounds.rounds_remaining \
             .derived.bounds.tokens_remaining .derived.bounds.concurrency_used; do
        printf '%s' "$rec" | jq -e "$p != null" >/dev/null \
            || { printf 'missing field: %s\n' "$p" >&2; return 1; }
    done
}

@test "the verdict is in the record the moment it is written, with no compute call" {
    tr_ spawn::team_record_new "$RUN" run-1 attached 2 3 0
    [ "$(field '.derived.verdict')" = "pending" ]
    [ "$(field '.derived.continue')" = "true" ]
}

@test "mutating an outcome and writing recomputes the verdict; the old one is gone" {
    seed
    tr_ spawn::team_member_set "$RUN" lead round 1
    tr_ spawn::team_member_set "$RUN" scout round 1
    tr_ spawn::team_member_set "$RUN" lead outcome done
    tr_ spawn::team_member_set "$RUN" scout outcome done
    [ "$(field '.derived.verdict')" = "pass" ]

    tr_ spawn::team_member_set "$RUN" scout outcome failed
    [ "$(field '.derived.verdict')" = "mixed" ]
    [ "$(field '.rounds[0].verdict')" = "mixed" ]
    refute_file_match '"verdict":"pass"' "$RUN/team.json"

    tr_ spawn::team_member_set "$RUN" lead outcome failed
    [ "$(field '.derived.verdict')" = "fail" ]
}

@test "two reads with no write between them see identical derived values" {
    seed
    tr_ spawn::team_member_set "$RUN" lead round 1
    tr_ spawn::team_member_set "$RUN" lead outcome done
    local a b
    a="$(field '.derived')"
    sleep 1
    b="$(field '.derived')"
    [ "$a" = "$b" ]
    [ -n "$a" ]
}

@test "a truncated record says nothing rather than reporting a partial one" {
    seed
    local whole; whole="$(cat "$RUN/team.json")"
    printf '%s' "${whole:0:60}" > "$RUN/team.json"
    run tr_ spawn::team_record_read "$RUN"
    [ "$status" -ne 0 ]
    [ -z "$output" ]

    printf '{"schema":"spawn.team/v1"}' > "$RUN/team.json"
    run tr_ spawn::team_record_read "$RUN"
    [ "$status" -ne 0 ]
    [ -z "$output" ]

    # Control arm: the same reader on the whole record answers.
    printf '%s' "$whole" > "$RUN/team.json"
    run tr_ spawn::team_record_read "$RUN"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "two writes in sequence leave no temp file behind" {
    seed
    tr_ spawn::team_member_set "$RUN" lead outcome done
    refute_exists "$RUN/.team.$$"
    run bash -c 'ls -a "$1" | grep -c "^\.team\." || true' _ "$RUN"
    [ "$output" = "0" ]
    # Control arm: the matcher sees a temp file that IS there.
    : > "$RUN/.team.probe"
    run bash -c 'ls -a "$1" | grep -c "^\.team\." || true' _ "$RUN"
    [ "$output" = "1" ]
}

@test "a write that fails mid-way leaves the previous record intact and readable" {
    seed
    local before; before="$(cat "$RUN/team.json")"
    run tr_ spawn::team_record_write "$RUN" '{"schema":"spawn.team/v1", "members":'
    [ "$status" -ne 0 ]
    [ "$(cat "$RUN/team.json")" = "$before" ]
    run tr_ spawn::team_record_read "$RUN"
    [ "$status" -eq 0 ]
    refute_exists "$RUN/.team.$$"
    run bash -c 'ls -a "$1" | grep -c "^\.team\." || true' _ "$RUN"
    [ "$output" = "0" ]
}

@test "a duplicate member name is refused and the roster is unchanged" {
    seed
    run tr_ spawn::team_member_add "$RUN" lead haiku "$WORK/wt/dup" "$WORK/c3.md" ""
    [ "$status" -ne 0 ]
    [ "$(field '.members | length')" = "2" ]
    # Control arm: a distinct name on the same call shape is accepted.
    run tr_ spawn::team_member_add "$RUN" third haiku "$WORK/wt/dup" "$WORK/c3.md" ""
    [ "$status" -eq 0 ]
    [ "$(field '.members | length')" = "3" ]
}

@test "an unwritable member field is refused by name" {
    seed
    run tr_ spawn::team_member_set "$RUN" lead verdict pass
    [ "$status" -ne 0 ]
    echo "$output" | grep -q "not a writable member field"
    refute_file_match '"verdict":"pass"' "$RUN/team.json"
    run tr_ spawn::team_member_set "$RUN" ghost outcome done
    [ "$status" -ne 0 ]
}

@test "the roster is held in JSON: no shell map anywhere in the file" {
    refute_file_match 'declare -A|local -A' "$LIB/team-record.sh"
    # Control arm: the matcher fires on a planted copy, never on the shipped file.
    mkdir -p "$WORK/plant"
    cat "$LIB/team-record.sh" > "$WORK/plant/team-record.sh"
    printf 'f() { declare -A m; }\n' >> "$WORK/plant/team-record.sh"
    run refute_file_match 'declare -A|local -A' "$WORK/plant/team-record.sh"
    [ "$status" -ne 0 ]
}

@test "a terminal member with unknown usage is not counted as zero" {
    seed
    tr_ spawn::team_member_set "$RUN" lead round 1
    tr_ spawn::team_member_set "$RUN" lead tokens_input 900
    tr_ spawn::team_member_set "$RUN" lead tokens_output 100
    tr_ spawn::team_member_set "$RUN" lead outcome done
    [ "$(field '.derived.usage_unknown')" = "false" ]
    [ "$(field '.rounds[0].tokens.total')" = "1000" ]

    tr_ spawn::team_member_set "$RUN" scout round 1
    tr_ spawn::team_member_set "$RUN" scout outcome done
    [ "$(field '.derived.usage_unknown')" = "true" ]
    [ "$(field '.rounds[0].tokens.unknown')" = "true" ]
    [ "$(field '.derived.stop_reasons | index("usage_unknown") != null')" = "true" ]
}

@test "the bounds fire their own stop reasons, and two firing are both listed" {
    tr_ spawn::team_record_new "$RUN" run-2 attached 2 1 500
    tr_ spawn::team_member_add "$RUN" lead sonnet "$WORK/wt/lead" "$WORK/c1.md" ""
    tr_ spawn::team_round_open "$RUN"
    [ "$(field '.derived.stop_reasons | join(",")')" = "round_max_reached" ]
    [ "$(field '.derived.continue')" = "false" ]

    tr_ spawn::team_member_set "$RUN" lead round 1
    tr_ spawn::team_member_set "$RUN" lead tokens_input 400
    tr_ spawn::team_member_set "$RUN" lead tokens_output 200
    tr_ spawn::team_member_set "$RUN" lead outcome done
    [ "$(field '.derived.stop_reasons | index("round_max_reached") != null')" = "true" ]
    [ "$(field '.derived.stop_reasons | index("token_ceiling_reached") != null')" = "true" ]
    [ "$(field '.derived.tokens_used')" = "600" ]
}

@test "a running round blocks a dispatch; a finished one with pending members allows it" {
    tr_ spawn::team_record_new "$RUN" run-3 attached 1 3 0
    tr_ spawn::team_member_add "$RUN" lead sonnet "$WORK/wt/lead" "$WORK/c1.md" ""
    tr_ spawn::team_member_add "$RUN" scout haiku "$WORK/wt/scout" "$WORK/c2.md" ""
    tr_ spawn::team_round_open "$RUN"
    tr_ spawn::team_member_set "$RUN" lead round 1
    tr_ spawn::team_member_set "$RUN" lead launch_state dispatched
    [ "$(field '.derived.active_round')" = "1" ]
    [ "$(field '.derived.active_round_state')" = "running" ]
    [ "$(field '.derived.dispatch_allowed')" = "false" ]

    tr_ spawn::team_member_set "$RUN" lead outcome done
    [ "$(field '.derived.active_round')" = "null" ]
    [ "$(field '.derived.dispatch_allowed')" = "true" ]
}

@test "a launch_failed member is terminal without an outcome" {
    seed
    tr_ spawn::team_member_set "$RUN" lead round 1
    tr_ spawn::team_member_set "$RUN" lead launch_state launch_failed
    [ "$(field '.rounds[0].state')" = "finished" ]
    [ "$(field '.rounds[0].verdict')" = "fail" ]
}

# closed_at is the one field the chokepoint remembers rather than derives. If a
# later write restamps it, a round's duration shrinks toward zero as the run
# goes on — and U10 reads it for elapsed.
@test "closed_at is stamped once and does not move on a later write" {
    seed
    tr_ spawn::team_member_set "$RUN" lead round 1
    tr_ spawn::team_member_set "$RUN" lead outcome done
    local first; first="$(field '.rounds[0].closed_at')"
    [ "$first" != "null" ]
    sleep 1
    tr_ spawn::team_member_set "$RUN" lead tokens_input 10
    [ "$(field '.rounds[0].closed_at')" = "$first" ]
}

# The gap test 16 left open: it builds a launch_failed member and asserts the
# round's state and verdict, but says nothing about usage — so `usage_missing`
# could conflate "never ran" with "ran and did not report", and did.
@test "a launch that never ran is zero tokens, not unmeasured usage" {
    tr_ spawn::team_record_new "$RUN" run-4 attached 2 3 100000
    tr_ spawn::team_member_add "$RUN" alice sonnet "$WORK/wt/alice" "$WORK/c1.md" ""
    tr_ spawn::team_member_add "$RUN" bob haiku "$WORK/wt/bob" "$WORK/c2.md" ""
    tr_ spawn::team_round_open "$RUN"
    tr_ spawn::team_member_set "$RUN" alice round 1
    tr_ spawn::team_member_set "$RUN" alice launch_state dispatched
    tr_ spawn::team_member_set "$RUN" alice tokens_input 100
    tr_ spawn::team_member_set "$RUN" alice tokens_output 50
    tr_ spawn::team_member_set "$RUN" alice outcome done
    tr_ spawn::team_member_set "$RUN" bob round 1
    tr_ spawn::team_member_set "$RUN" bob launch_state launch_failed

    [ "$(field '.derived.usage_unknown')" = "false" ]
    [ "$(field '.rounds[0].tokens.unknown')" = "false" ]
    [ "$(field '.derived.stop_reasons | index("usage_unknown")')" = "null" ]
    [ "$(field '.derived.continue')" = "true" ]
    [ "$(field '.derived.tokens_used')" = "150" ]

    # The other arm, so the assertion cannot pass by never raising `unknown`: a
    # member that DID run and reported nothing is genuinely unmeasured.
    tr_ spawn::team_member_add "$RUN" carol haiku "$WORK/wt/carol" "$WORK/c3.md" ""
    tr_ spawn::team_member_set "$RUN" carol round 1
    tr_ spawn::team_member_set "$RUN" carol launch_state dispatched
    tr_ spawn::team_member_set "$RUN" carol outcome done
    [ "$(field '.derived.usage_unknown')" = "true" ]
    [ "$(field '.rounds[0].tokens.unknown')" = "true" ]
    [ "$(field '.derived.continue')" = "false" ]
}

@test "a member's failure cause round-trips as an object, not a string" {
    seed
    tr_ spawn::team_member_set "$RUN" lead failure \
        '{"kind":"contract_unmet","detail":"the judge withheld a verdict","at":"2026-08-14T10:20:00Z","source":"supervisor"}'

    [ "$(field '.members[0].failure | type')" = "object" ]
    [ "$(field '.members[0].failure.kind')" = "contract_unmet" ]
    [ "$(field '.members[0].failure.detail')" = "the judge withheld a verdict" ]
    [ "$(field '.members[0].failure.at')" = "2026-08-14T10:20:00Z" ]
    [ "$(field '.members[0].failure.source')" = "supervisor" ]
    # The other member is untouched, so the write is addressed by name.
    [ "$(field '.members[1].failure')" = "null" ]
}

@test "a member's retired attempts round-trip as an ordered array" {
    seed
    tr_ spawn::team_member_set "$RUN" lead attempts \
        '[{"round":1,"outcome":"failed","failure":{"kind":"launch_failed"}},{"round":2,"outcome":"failed","failure":{"kind":"timeout"}}]'

    [ "$(field '.members[0].attempts | type')" = "array" ]
    [ "$(field '.members[0].attempts | length')" = "2" ]
    [ "$(field '.members[0].attempts[0].round')" = "1" ]
    [ "$(field '.members[0].attempts[0].failure.kind')" = "launch_failed" ]
    [ "$(field '.members[0].attempts[1].round')" = "2" ]
    [ "$(field '.members[0].attempts[1].failure.kind')" = "timeout" ]
}

@test "a fresh member row carries a null cause and no retired attempts" {
    seed
    # `has` and not just the value: jq prints null for an ABSENT key too, and
    # KTD4 keeps absent and null distinct.
    [ "$(field '.members[0] | has("failure")')" = "true" ]
    [ "$(field '.members[0].failure')" = "null" ]
    [ "$(field '.members[0] | has("attempts")')" = "true" ]
    [ "$(field '.members[0].attempts | type')" = "array" ]
    [ "$(field '.members[0].attempts | length')" = "0" ]
}

@test "a cause cleared back to null is JSON null, never the string null" {
    seed
    tr_ spawn::team_member_set "$RUN" lead failure '{"kind":"timeout"}'
    [ "$(field '.members[0].failure | type')" = "object" ]
    tr_ spawn::team_member_set "$RUN" lead failure null
    [ "$(field '.members[0].failure | type')" = "null" ]
    refute_file_match '"failure":"null"' "$RUN/team.json"
}

# ===========================================================================
# U5 — rotating a failed attempt out of the live row (R8, R9, R10, KTD6-KTD8)
#
# The rotation is ONE read-modify-write. A half-applied rotation is the failure
# mode this block exists to pin: between an outcome being nulled and the
# launch_state flipping, a concurrent advance sees a dispatched member with a
# null outcome and a null handle, answers handle_unknown, and writes an outcome
# into the middle of the rotation.
# ===========================================================================

# A member that ran, spent tokens and failed, in a round of its own.
seed_failed() {         # <member> <round>
    tr_ spawn::team_member_set "$RUN" "$1" round "$2"
    tr_ spawn::team_member_set "$RUN" "$1" launch_state dispatched
    tr_ spawn::team_member_set "$RUN" "$1" handle "job-2026081$2T101500Z-1234"
    tr_ spawn::team_member_set "$RUN" "$1" started_at "2026-08-1${2}T10:15:00Z"
    tr_ spawn::team_member_set "$RUN" "$1" tokens_input 100
    tr_ spawn::team_member_set "$RUN" "$1" tokens_output 50
    tr_ spawn::team_member_set "$RUN" "$1" failure \
        '{"kind":"contract_unmet","detail":"no verdict","source":"supervisor"}'
    tr_ spawn::team_member_set "$RUN" "$1" outcome failed
}

@test "rotating a failed member appends one attempt holding its handle, outcome and cause" {
    seed
    seed_failed lead 1

    tr_ spawn::team_member_rotate "$RUN" lead

    [ "$(field '.members[0].attempts | length')" = "1" ]
    [ "$(field '.members[0].attempts[0].round')" = "1" ]
    [ "$(field '.members[0].attempts[0].handle')" = "job-20260811T101500Z-1234" ]
    [ "$(field '.members[0].attempts[0].outcome')" = "failed" ]
    [ "$(field '.members[0].attempts[0].failure.kind')" = "contract_unmet" ]
    [ "$(field '.members[0].attempts[0].tokens.input')" = "100" ]
    [ "$(field '.members[0].attempts[0].tokens.output')" = "50" ]
    [ "$(field '.members[0].launch_state')" = "retry_pending" ]
    # The other member is untouched, so the rotation is addressed by name.
    [ "$(field '.members[1].attempts | length')" = "0" ]
    [ "$(field '.members[1].launch_state')" = "pending" ]
}

@test "after a rotation the live row carries no handle, outcome, cause, round, start or tokens" {
    seed
    seed_failed lead 1

    tr_ spawn::team_member_rotate "$RUN" lead

    # KEY PRESENCE as well as value: jq prints null for an absent key too, and a
    # rotation that DELETED these would read identically on the value alone.
    for k in handle outcome failure round started_at tokens; do
        [ "$(field ".members[0] | has(\"$k\")")" = "true" ]
    done
    [ "$(field '.members[0].handle')" = "null" ]
    [ "$(field '.members[0].outcome')" = "null" ]
    [ "$(field '.members[0].failure')" = "null" ]
    [ "$(field '.members[0].round')" = "null" ]
    [ "$(field '.members[0].started_at')" = "null" ]
    [ "$(field '.members[0].tokens.input')" = "null" ]
    [ "$(field '.members[0].tokens.output')" = "null" ]
    # Placement survives: a later round relaunches from the checkout the record
    # already names and places nothing.
    [ "$(field '.members[0].worktree')" = "$WORK/wt/lead" ]
    [ "$(field '.members[0].alias')" = "sonnet" ]
    [ "$(field '.members[0].contract')" = "$WORK/c1.md" ]
    [ "$(field '.members[0].skills | length')" = "2" ]
    refute_file_match '"outcome":"null"' "$RUN/team.json"
}

@test "a second rotation appends a second attempt and keeps the first, in order" {
    seed
    seed_failed lead 1
    tr_ spawn::team_member_rotate "$RUN" lead
    tr_ spawn::team_round_open "$RUN"
    seed_failed lead 2
    tr_ spawn::team_member_rotate "$RUN" lead

    [ "$(field '.members[0].attempts | length')" = "2" ]
    [ "$(field '.members[0].attempts[0].round')" = "1" ]
    [ "$(field '.members[0].attempts[1].round')" = "2" ]
    [ "$(field '.members[0].launch_state')" = "retry_pending" ]
}

@test "rotating a member this run does not have is refused and changes nothing" {
    seed
    seed_failed lead 1
    local before; before="$(cat "$RUN/team.json")"

    # The specific refusal, not merely a non-zero status: a missing function
    # exits 127 and would satisfy `status -ne 0` on a rotation that does not exist.
    [ "$(tr_err spawn::team_member_rotate "$RUN" ghost)" = "member_unknown" ]
    [ "$(cat "$RUN/team.json")" = "$before" ]
}

# A one-member run, so `retry_pending` is the ONLY thing that can make the
# roster look unfinished — with a second pending member the assertions below
# would pass on that member alone.
seed_solo() {
    tr_ spawn::team_record_new "$RUN" run-5 attached 2 3 100000
    tr_ spawn::team_member_add "$RUN" lead sonnet "$WORK/wt/lead" "$WORK/c1.md" ""
    tr_ spawn::team_round_open "$RUN"
}

@test "rotating the only member of a closed round leaves that round finished, with its close time and verdict" {
    seed_solo
    seed_failed lead 1
    [ "$(field '.rounds[0].state')" = "finished" ]
    local closed verdict
    closed="$(field '.rounds[0].closed_at')"
    verdict="$(field '.rounds[0].verdict')"
    [ "$closed" != "null" ]
    [ "$verdict" = "fail" ]

    tr_ spawn::team_member_rotate "$RUN" lead

    # THE DEADLOCK CASE. A round that flips back to running has a null closed_at
    # and parks every later advance at `waiting` for ever.
    [ "$(field '.rounds[0].state')" = "finished" ]
    [ "$(field '.rounds[0].closed_at')" = "$closed" ]
    [ "$(field '.rounds[0].verdict')" = "$verdict" ]
    [ "$(field '.rounds[0].members | index("lead")')" != "null" ]
    [ "$(field '.derived.active_round')" = "null" ]
}

@test "rotating a member whose launch failed leaves its round finished too" {
    seed_solo
    tr_ spawn::team_member_set "$RUN" lead round 1
    tr_ spawn::team_member_set "$RUN" lead failure '{"kind":"launch_failed"}'
    tr_ spawn::team_member_set "$RUN" lead launch_state launch_failed
    [ "$(field '.rounds[0].state')" = "finished" ]

    tr_ spawn::team_member_rotate "$RUN" lead

    # A retired attempt carries no launch_state of its own, so a union that read
    # one off the entry would call this attempt not-done and reopen its round.
    [ "$(field '.rounds[0].state')" = "finished" ]
    [ "$(field '.rounds[0].verdict')" = "fail" ]
    [ "$(field '.derived.usage_unknown')" = "false" ]
}

@test "rotating one member of a mixed round leaves that round mixed, not pass" {
    seed
    tr_ spawn::team_member_set "$RUN" scout round 1
    tr_ spawn::team_member_set "$RUN" scout launch_state dispatched
    tr_ spawn::team_member_set "$RUN" scout tokens_input 10
    tr_ spawn::team_member_set "$RUN" scout tokens_output 5
    tr_ spawn::team_member_set "$RUN" scout outcome done
    seed_failed lead 1
    [ "$(field '.rounds[0].verdict')" = "mixed" ]

    tr_ spawn::team_member_rotate "$RUN" lead

    [ "$(field '.rounds[0].verdict')" = "mixed" ]
    [ "$(field '.rounds[0].members | length')" = "2" ]
}

@test "a rotation does not return the retired attempt's spend to the run" {
    seed_solo
    seed_failed lead 1
    [ "$(field '.derived.tokens_used')" = "150" ]

    tr_ spawn::team_member_rotate "$RUN" lead

    # KTD8: a ceiling that forgot the retired spend lets a retry loop spend past
    # it for ever.
    [ "$(field '.derived.tokens_used')" = "150" ]
    [ "$(field '.derived.bounds.tokens_used')" = "150" ]
    [ "$(field '.derived.bounds.tokens_remaining')" = "99850" ]
    [ "$(field '.rounds[0].tokens.total')" = "150" ]
}

@test "a member at retry_pending is not done, and its run is neither complete nor roster-exhausted" {
    seed_solo
    seed_failed lead 1
    [ "$(field '.derived.complete')" = "true" ]
    [ "$(field '.derived.stop_reasons | index("roster_exhausted")')" != "null" ]

    tr_ spawn::team_member_rotate "$RUN" lead

    # `is_done` itself is unchanged: a retry_pending member has a null outcome
    # and is not launch_failed, so it falls out of the existing definition.
    [ "$(field '.derived.complete')" = "false" ]
    [ "$(field '.derived.members_terminal')" = "0" ]
    [ "$(field '.derived.stop_reasons | index("roster_exhausted")')" = "null" ]
    [ "$(field '.derived.dispatch_allowed')" = "true" ]
    [ "$(field '.derived.verdict')" = "pending" ]
}

@test "the derive jq still defines is_done without naming retry_pending" {
    refute_file_match 'def is_done:.*retry_pending' "$LIB/team-record.sh"
    grep -q 'def is_done: (.outcome != null) or (.launch_state == "launch_failed");' "$LIB/team-record.sh"
}

@test "a rotation does not launder an attempt that ran and reported nothing" {
    seed_solo
    tr_ spawn::team_member_set "$RUN" lead round 1
    tr_ spawn::team_member_set "$RUN" lead launch_state dispatched
    tr_ spawn::team_member_set "$RUN" lead outcome failed
    [ "$(field '.derived.usage_unknown')" = "true" ]
    [ "$(field '.derived.members_unmeasured')" = "1" ]

    tr_ spawn::team_member_rotate "$RUN" lead

    # An attempt that RAN and reported no count is unmeasured spend the ceiling
    # cannot be enforced against; a rotation that dropped it would report the
    # run as fully measured and let the ceiling read as a total.
    [ "$(field '.derived.usage_unknown')" = "true" ]
    [ "$(field '.derived.members_unmeasured')" = "1" ]
    [ "$(field '.derived.stop_reasons | index("usage_unknown")')" != "null" ]
    [ "$(field '.rounds[0].tokens.unknown')" = "true" ]
}

@test "a retired attempt is still a real measurement, so the ceiling stays enforceable" {
    seed
    tr_ spawn::team_member_set "$RUN" lead round 1
    tr_ spawn::team_member_set "$RUN" lead launch_state dispatched
    tr_ spawn::team_member_set "$RUN" lead tokens_input 100
    tr_ spawn::team_member_set "$RUN" lead tokens_output 50
    tr_ spawn::team_member_set "$RUN" lead outcome failed
    tr_ spawn::team_member_set "$RUN" scout round 1
    tr_ spawn::team_member_set "$RUN" scout launch_state dispatched
    tr_ spawn::team_member_set "$RUN" scout outcome done
    [ "$(field '.derived.ceiling_state')" = "within" ]

    tr_ spawn::team_member_rotate "$RUN" lead

    # The only member that ever REPORTED a count is now a retired attempt. Read
    # off the live rows alone the run has no measurement at all, and the ceiling
    # reads `unenforceable` — a run whose one real bill is on the record.
    [ "$(field '.derived.members_unmeasured')" = "1" ]
    [ "$(field '.derived.ceiling_state')" = "within" ]
}
