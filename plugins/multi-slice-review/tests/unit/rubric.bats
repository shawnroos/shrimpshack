#!/usr/bin/env bats
# U5 — granularity rubric. Test-first. Consumes prepass signals on stdin.

RUBRIC="$BATS_TEST_DIRNAME/../../skills/multi-slice-review/scripts/rubric.sh"

# run_rubric F D L RS [extra-flags...] -> emits KEY=VALUE lines
run_rubric() {
    local f="$1" d="$2" l="$3" rs="$4"; shift 4
    printf 'F=%s\nD=%s\nL=%s\nRS=%s\n' "$f" "$d" "$l" "$rs" | bash "$RUBRIC" "$@"
}
val() { grep "^$1=" | cut -d= -f2-; }

@test "small tier (D<=2, F<=8) -> 3 slices" {
    out="$(run_rubric 5 2 100 '')"
    [ "$(printf '%s' "$out" | val TIER)" = "small" ]
    [ "$(printf '%s' "$out" | val SLICE_TARGET)" = "3" ]
}

@test "just above small (D=3) -> medium, 4 slices" {
    out="$(run_rubric 5 3 100 '')"
    [ "$(printf '%s' "$out" | val TIER)" = "medium" ]
    [ "$(printf '%s' "$out" | val SLICE_TARGET)" = "4" ]
}

@test "large by subsystem count (D=5) -> 6 slices" {
    out="$(run_rubric 5 5 100 '')"
    [ "$(printf '%s' "$out" | val TIER)" = "large" ]
    [ "$(printf '%s' "$out" | val SLICE_TARGET)" = "6" ]
}

@test "large by file count (F=30) beats small D -> large" {
    out="$(run_rubric 30 2 100 '')"
    [ "$(printf '%s' "$out" | val TIER)" = "large" ]
}

@test "RS destructive -> security lens" {
    printf '%s' "$(run_rubric 5 3 100 destructive | val RISK_LENSES)" | grep -q security
}

@test "RS concurrency,io -> reliability lens" {
    printf '%s' "$(run_rubric 5 3 100 concurrency,io | val RISK_LENSES)" | grep -q reliability
}

@test "RS api -> api-contract lens" {
    printf '%s' "$(run_rubric 5 3 100 api | val RISK_LENSES)" | grep -q api-contract
}

@test "no RS -> RISK_LENSES empty (base correctness+adversarial only)" {
    [ "$(run_rubric 5 3 100 '' | val RISK_LENSES)" = "" ]
}

@test "un-added lens carries a stated reason (skip-with-reason, no RS)" {
    # with no risk surfaces, security/reliability/api-contract are skipped WITH a reason
    run_rubric 5 3 100 '' | grep -q '^LENS_SKIPPED='
}

@test "WAVE_CAP is derived from cores (min(16,cores-2)) not a hardcoded 8" {
    [ "$(run_rubric 5 3 100 '' --cores 10 | val WAVE_CAP)" = "8" ]
    [ "$(run_rubric 5 3 100 '' --cores 6  | val WAVE_CAP)" = "4" ]
    [ "$(run_rubric 5 3 100 '' --cores 4  | val WAVE_CAP)" = "2" ]
    [ "$(run_rubric 5 3 100 '' --cores 20 | val WAVE_CAP)" = "16" ]
}

@test "over-ceiling total (soft-target override) -> capped at MAX_REVIEWERS + notice" {
    out="$(run_rubric 5 5 100 destructive,concurrency --slices 30)"
    [ "$(printf '%s' "$out" | val MAX_REVIEWERS)" = "64" ]
    [ "$(printf '%s' "$out" | val PROJECTED_AGENTS)" = "64" ]
    [ -n "$(printf '%s' "$out" | val CLAMP_NOTICE)" ]
}

@test "within budget -> no clamp notice" {
    out="$(run_rubric 5 3 100 '')"
    [ "$(printf '%s' "$out" | val CLAMP_NOTICE)" = "" ]
}

# P1 #3: rubric must NOT fail open to a valid 'small' sizing on empty/partial input
# (that would nullify prepass's fail-loud guard one stage downstream).
@test "P1 #3: empty signal stream is rejected (no fail-open to small)" {
    run bash -c "printf '' | bash '$RUBRIC' --cores 8"
    [ "$status" -ne 0 ]
}

@test "P1 #3: missing D signal is rejected" {
    run bash -c "printf 'F=5\n' | bash '$RUBRIC' --cores 8"
    [ "$status" -ne 0 ]
}

@test "P3: non-numeric --cores is rejected, not an unbound-variable crash" {
    run bash -c "printf 'F=5\nD=3\nL=10\nRS=\n' | bash '$RUBRIC' --cores abc"
    [ "$status" -ne 0 ]
    echo "$output" | grep -qiv 'unbound variable'
}
