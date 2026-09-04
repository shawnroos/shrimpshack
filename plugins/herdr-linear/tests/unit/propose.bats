#!/usr/bin/env bats
# U7 — candidate generation, and the skill's contract.
#
# NO LINEAR OBJECT IS CREATED OR MODIFIED HERE. fake-linear.sh refuses any
# GraphQL mutation with exit 97 unless a test explicitly permits one, so a
# proposal path that started writing would fail the suite rather than silently
# filing tickets in the real workspace.

bats_require_minimum_version 1.5.0

setup() {
    ROOT="${BATS_TEST_DIRNAME}/../.."
    FIX="${BATS_TEST_DIRNAME}/../fixtures"
    WORK="$(mktemp -d)"

    export HERDR_LINEAR_SLATE_ROOT="$WORK/Slate"
    export HERDR_LINEAR_STORE_DIR="$WORK/store"
    export HERDR_LINEAR_PIN_DIR="$WORK/pin"
    export HERDR_LINEAR_CURL_BIN="$FIX/fake-linear.sh"
    export HERDR_LINEAR_SECURITY_BIN="$FIX/fake-security.sh"
    export FAKE_SECURITY_STORE_DIR="$WORK/kc"
    export FAKE_LINEAR_RECORD_DIR="$WORK/rec"
    export LINEAR_CACHE_DIR="$WORK/cache"
    export LINEAR_SECRETS_FILE="$WORK/secrets"
    mkdir -p "$WORK/Slate" "$WORK/rec" "$WORK/cache"
    printf 'LINEAR_API_KEY=%s\n' "lin_api""_PROPOSEPROPOSEPROPO" > "$LINEAR_SECRETS_FILE"

    # shellcheck source=/dev/null
    for f in contain.sh secrets.sh binding.sh linear.sh herdr-read.sh propose.sh; do . "$ROOT/lib/$f"; done

    WT="$WORK/Slate/wt"; mkdir -p "$WT"
    git -C "$WT" init -q -b feature/web-3318-drawer
    git -C "$WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

    NOID="$WORK/Slate/noid"; mkdir -p "$NOID"
    git -C "$NOID" init -q -b rehome-sprawl
    git -C "$NOID" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

    OUTSIDE="$WORK/NotSlate/wt"; mkdir -p "$OUTSIDE"
    git -C "$OUTSIDE" init -q -b feature/web-3318-drawer
    git -C "$OUTSIDE" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
}

teardown() { [ -n "${WORK:-}" ] && rm -rf "$WORK"; }

# --------------------------------------------------------------- containment

@test "a worktree outside the Slate root is refused before anything is read" {
    export FAKE_LINEAR_MODE=found_child
    run herdr_linear::candidates "$OUTSIDE"
    [ "$status" -eq 2 ]
    [ ! -f "$FAKE_LINEAR_RECORD_DIR/bodies" ]
}

# ------------------------------------------------------------- the branch rule

# AE1. The branch carries the identifier, so that issue is proposed -- and
# nothing is written until a person confirms.
@test "a branch carrying an identifier proposes that issue and writes nothing" {
    export FAKE_LINEAR_MODE=found_child
    run herdr_linear::candidates "$WT"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | grep -c .)" = "1" ]
    [[ "$output" == "WEB-3318	"* ]]
    [[ "$output" == *"	branch" ]]
    run herdr_linear::binding_state "$WT"
    [ "$output" = "unbound" ]
}

@test "the proposal path sends no mutation" {
    export FAKE_LINEAR_MODE=found_child
    run herdr_linear::candidates "$WT"
    [ "$status" -eq 0 ]
    # 97 is the fixture's mutation refusal. Reaching it at all would mean this
    # path tried to write.
    run grep -c mutation "$FAKE_LINEAR_RECORD_DIR/bodies"
    [ "$output" = "0" ]
}

# ------------------------------------------------------------ the fallback

@test "a branch carrying no identifier falls back to a bounded list" {
    export FAKE_LINEAR_MODE=candidates
    run herdr_linear::candidates "$NOID"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | grep -c .)" = "3" ]
    [[ "$output" == *"	assignee"* ]]
}

@test "the fallback list is hard-capped, and the cap is sent to Linear" {
    export FAKE_LINEAR_MODE=candidates
    export HERDR_LINEAR_CANDIDATE_LIMIT=2
    run herdr_linear::candidates "$NOID"
    [ "$status" -eq 0 ]
    run grep -c '"n": 2' "$FAKE_LINEAR_RECORD_DIR/bodies"
    [ "$output" = "1" ]
}

@test "a bound workspace scopes the fallback to its project" {
    n="$(herdr_linear::workspace_propose "w1" "44444444-4444-4444-8444-444444444444")"
    herdr_linear::workspace_confirm "w1" "44444444-4444-4444-8444-444444444444" "$n"
    export FAKE_LINEAR_MODE=candidates
    run herdr_linear::candidates "$NOID" "w1"
    [ "$status" -eq 0 ]
    [[ "$output" == *"	project"* ]]
    run grep -c '44444444-4444-4444-8444-444444444444' "$FAKE_LINEAR_RECORD_DIR/bodies"
    [ "$output" = "1" ]
}

# The invariant underneath the next test. A proposed workspace record has no
# project recorded at all -- propose writes a candidate, confirm writes the
# value -- so there is nothing for the fallback to scope by even before the
# state is examined.
@test "a proposed workspace has no project recorded until it is confirmed" {
    herdr_linear::workspace_propose "w1" "44444444-4444-4444-8444-444444444444" >/dev/null
    run herdr_linear::workspace_state "w1"
    [ "$output" = "proposed" ]
    run herdr_linear::workspace_project "w1"
    [ -z "$output" ]
}

# A workspace that is only PROPOSED is not bound, so its project must not scope
# anything -- the plugin never assumes the correspondence before confirmation.
#
# Note the state check in lib/propose.sh is a BACKSTOP, not the only thing
# holding this: workspace_project already answers empty for a non-bound record,
# so mutating that check away leaves this test green. Both are kept; only the
# test above proves the property directly.
@test "a merely proposed workspace does not scope the fallback" {
    herdr_linear::workspace_propose "w1" "44444444-4444-4444-8444-444444444444" >/dev/null
    export FAKE_LINEAR_MODE=candidates
    run herdr_linear::candidates "$NOID" "w1"
    [ "$status" -eq 0 ]
    [[ "$output" == *"	assignee"* ]]
    run grep -c '44444444-4444-4444-8444-444444444444' "$FAKE_LINEAR_RECORD_DIR/bodies"
    [ "$output" = "0" ]
}

# KTD12. An empty filtered list is an ANSWER. Widening it is how a chooser ends
# up looking at every issue in the workspace.
@test "an empty filtered list stops rather than widening" {
    export FAKE_LINEAR_MODE=no_candidates
    run herdr_linear::candidates "$NOID"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    # Exactly one query. A second, wider one would be the defect.
    [ "$(wc -l < "$FAKE_LINEAR_RECORD_DIR/bodies" | tr -d ' ')" = "1" ]
}

@test "the fallback query asks only for unfinished issues assigned to the viewer" {
    export FAKE_LINEAR_MODE=candidates
    run herdr_linear::candidates "$NOID"
    body="$(cat "$FAKE_LINEAR_RECORD_DIR/bodies")"
    [[ "$body" == *'"isMe"'* ]]
    [[ "$body" == *'"completed"'* ]]
    [[ "$body" == *'"canceled"'* ]]
    [[ "$body" == *'updatedAt'* ]]
}

# ---------------------------------------------------------------- declines (R4)

# The fixture must serve the branch fetch SUCCESSFULLY for this to isolate the
# decline filter. With no_candidates the branch fetch fails to parse anyway, so
# the test passed whether or not the filter existed -- green for the wrong
# reason, caught by mutating the filter away and watching nothing turn red.
@test "a declined candidate is not offered again by the branch rule" {
    export FAKE_LINEAR_MODE=found_child
    run herdr_linear::candidates "$WT"
    [ "$status" -eq 0 ]
    [[ "$output" == "WEB-3318"* ]]

    herdr_linear::binding_decline "$WT" WEB-3318
    run herdr_linear::candidates "$WT"
    [ "$status" -eq 1 ]
}

@test "a declined candidate is filtered out of the fallback list too" {
    herdr_linear::binding_decline "$NOID" WEB-3317
    export FAKE_LINEAR_MODE=candidates
    run herdr_linear::candidates "$NOID"
    [ "$status" -eq 0 ]
    [[ "$output" != *"WEB-3317"* ]]
    [[ "$output" == *"WEB-3318"* ]]
}

# ------------------------------------------------------------ unavailability

@test "an unreachable Linear reports unavailable and proposes nothing" {
    export HERDR_LINEAR_CURL_BIN=/bin/false
    run herdr_linear::candidates "$WT"
    [ "$status" -eq 3 ]
    [ -z "$output" ]
}

# A branch identifier that does not resolve is not an error -- it is settled by
# the fetch returning nothing, and the fallback then runs.
@test "a branch identifier that does not exist falls through to the fallback" {
    export FAKE_LINEAR_MODE="seq:not_found,candidates"
    run herdr_linear::candidates "$WT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"	assignee"* ]]
}

# ------------------------------------------------------------- the skill file

# disable-model-invocation is the whole of R6's second half. If it is ever
# dropped, the model can invoke the bind skill on its own initiative and every
# claim about attended confirmation stops being true.
@test "the bind skill cannot be invoked by the model" {
    run grep -c '^disable-model-invocation: true$' "$ROOT/skills/bind/SKILL.md"
    [ "$output" = "1" ]
}

@test "the bind skill runs the containment check before recording anything" {
    body="$(cat "$ROOT/skills/bind/SKILL.md")"
    [[ "$body" == *"herdr_linear::contains"* ]]
    # The containment section precedes the recording section.
    c=$(grep -n 'herdr_linear::contains' "$ROOT/skills/bind/SKILL.md" | head -1 | cut -d: -f1)
    r=$(grep -n 'herdr_linear::binding_confirm' "$ROOT/skills/bind/SKILL.md" | head -1 | cut -d: -f1)
    [ "$c" -lt "$r" ]
}

@test "the bind skill tells the reader not to widen an empty list" {
    body="$(cat "$ROOT/skills/bind/SKILL.md")"
    [[ "$body" == *"Do not widen the"* ]]
    [[ "$body" == *"supported"* ]]
}

@test "the bind skill defers to the conventions doc on unsettled questions" {
    body="$(cat "$ROOT/skills/bind/SKILL.md")"
    [[ "$body" == *"linear-conventions.md"* ]]
    [[ "$body" == *"Not yet settled"* ]]
}
