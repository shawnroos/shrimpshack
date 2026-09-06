#!/usr/bin/env bats
# U11 — the read-only herdr accessor.
#
# Nothing here touches the live herdr server. That is a decision, not a
# convenience: this suite runs inside the user's real terminal, so a test that
# probed the running server would answer differently on every machine and, one
# careless verb later, could disturb work in progress. Everything goes through
# HERDR_BIN pointed at tests/fixtures/fake-herdr.sh.
#
# The load-bearing assertions in this file are the three the spinoff comments
# record as measured failures: the exact-line probe (a substring match accepts
# "not running"), the flood probe (an early-exiting reader kills herdr mid-write
# and the probe reports false on a success), and the rejected override (a set
# but unusable HERDR_BIN must resolve to nothing rather than quietly drive some
# other binary). Each one is mutated in the report, not merely present.

# `run --separate-stderr` is a 1.5.0 flag; the probe tests read stdout and
# stderr apart.
bats_require_minimum_version 1.5.0

# A `!`-negated command is exempt from errexit under POSIX, and bats scores a
# test by errexit or the final command's status -- so `! grep -q X` anywhere but
# the last line detects the defect and lets the test pass anyway. Every absence
# assertion goes through this instead: it returns non-zero on a match, which is
# a plain command failure and does fail the test wherever it sits.
refute_match() {   # refute_match <grep-args...> -- fails when grep MATCHES
    if grep "$@"; then
        printf 'refute_match: unexpectedly matched: %s\n' "$*" >&2
        return 1
    fi
    return 0
}

setup() {
    FIX="$(cd "$BATS_TEST_DIRNAME/../fixtures" && pwd)"
    LIB="$(cd "$BATS_TEST_DIRNAME/../../lib" && pwd)"
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/hl-read.XXXXXX")"
    # /tmp is a symlink on macOS; every path compared below is resolved.
    WORK="$(cd "$WORK" && pwd -P)"

    export FAKE_HERDR_RECORD_DIR="$WORK/rec"
    export FAKE_HERDR_MODE=running

    # The seam is on by DEFAULT, not per test. PATH still holds this machine's
    # real /opt/homebrew/bin/herdr, so a test that merely forgot to set the
    # override would talk to the user's LIVE server and pass for the wrong
    # reason. The tests that need resolution to fail unset it themselves.
    export HERDR_BIN="$FIX/fake-herdr.sh"
    export HERDR_LINEAR_BIN_PATHS=""

    # The accessor reads the session's own position from these. Tests that care
    # set them; the default is a known value so nothing leaks in from the herdr
    # pane this suite runs inside.
    export HERDR_PANE_ID="wA:p1"
    export HERDR_TAB_ID="wA:t1"
    export HERDR_WORKSPACE_ID="wA"

    # shellcheck source=../../lib/herdr-read.sh
    . "$LIB/herdr-read.sh"
}

teardown() {
    [ -n "${WORK:-}" ] && rm -rf "$WORK"
    return 0
}

argv_record() { cat "$WORK/rec/argv" 2>/dev/null; }

# Put a working fake at <dir>/herdr and hand back the dir.
plant_herdr() {
    local dir="$1"
    mkdir -p "$dir"
    cp "$FIX/fake-herdr.sh" "$dir/herdr"
    chmod +x "$dir/herdr"
    printf '%s' "$dir"
}

# Resolution

@test "the binary is absent from PATH and is found on the fallback list" {
    plant_herdr "$WORK/opt" >/dev/null
    export HERDR_LINEAR_BIN_PATHS="$WORK/nowhere:$WORK/opt"

    # Without this the test would find the host's real herdr on the default
    # PATH and pass for the wrong reason — never exercising the fallback walk.
    PATH="/usr/bin:/bin" run -0 bash -c '! command -v herdr'

    run -0 env -u HERDR_BIN PATH="/usr/bin:/bin" bash -c \
        "export HERDR_LINEAR_BIN_PATHS='$WORK/nowhere:$WORK/opt'; . '$LIB/herdr-read.sh'; herdr_linear::bin"
    [ "$output" = "$WORK/opt/herdr" ]
}

@test "an explicitly-set override that is not executable resolves to empty and does not fall through" {
    plant_herdr "$WORK/opt" >/dev/null
    export HERDR_LINEAR_BIN_PATHS="$WORK/opt"

    printf '#!/bin/sh\n' >"$WORK/not-exec"
    chmod -x "$WORK/not-exec"
    HERDR_BIN="$WORK/not-exec" run -0 herdr_linear::bin
    [ -z "$output" ]

    # The rejected value is recoverable, so a diagnostic can name it.
    HERDR_BIN="$WORK/not-exec" run -0 herdr_linear::bin_rejected
    [ "$output" = "$WORK/not-exec" ]
}

@test "an override pointing at a DIRECTORY resolves to empty — -x alone is true of a directory" {
    plant_herdr "$WORK/opt" >/dev/null
    export HERDR_LINEAR_BIN_PATHS="$WORK/opt"

    [ -x "$WORK/opt" ]  # the trap: the directory itself passes -x
    HERDR_BIN="$WORK/opt" run -0 herdr_linear::bin
    [ -z "$output" ]
}

@test "an empty candidate list means nowhere, not the defaults" {
    run -0 env -u HERDR_BIN PATH="/usr/bin:/bin" bash -c \
        "export HERDR_LINEAR_BIN_PATHS=''; . '$LIB/herdr-read.sh'; herdr_linear::bin"
    [ -z "$output" ]
}

@test "a relative override resolves to an absolute path" {
    plant_herdr "$WORK/opt" >/dev/null
    run -0 bash -c \
        "cd '$WORK/opt' && export HERDR_BIN=./herdr && . '$LIB/herdr-read.sh' && herdr_linear::bin"
    [ "$output" = "$WORK/opt/herdr" ]
}

# The liveness probe

@test "a live server probes true and the captured text is kept" {
    export HERDR_BIN="$(plant_herdr "$WORK/opt")/herdr"
    run -0 herdr_linear::probe
    herdr_linear::probe
    [[ "$HERDR_LINEAR_PROBE_OUT" == *"status: running"* ]]
    [[ "$HERDR_LINEAR_PROBE_OUT" == *"version: 0.8.2"* ]]
}

@test "the server reports 'not running' and the probe returns false rather than matching the substring" {
    export HERDR_BIN="$(plant_herdr "$WORK/opt")/herdr"
    export FAKE_HERDR_MODE=not_running
    run -1 herdr_linear::probe
    herdr_linear::probe || true
    # Proof the input really did contain the word the substring match accepts.
    [[ "$HERDR_LINEAR_PROBE_OUT" == *"running"* ]]
    [[ "$HERDR_LINEAR_PROBE_OUT" == *"not running"* ]]
}

@test "the probe survives a server that keeps writing long past the match" {
    export HERDR_BIN="$(plant_herdr "$WORK/opt")/herdr"
    export FAKE_HERDR_MODE=running_then_flood
    run -0 herdr_linear::probe
    herdr_linear::probe
    # The match line is not the first line, and the whole flood was read: a
    # reader that exited at the match would lose the tail and (under pipefail)
    # report the success as a failure.
    [[ "$HERDR_LINEAR_PROBE_OUT" == *"status: running"* ]]
    [[ "$HERDR_LINEAR_PROBE_OUT" == *"trailing: end"* ]]
    [ "${#HERDR_LINEAR_PROBE_OUT}" -gt 65536 ]
}

@test "an unresolvable binary probes false without running anything" {
    run -0 env -u HERDR_BIN PATH="/usr/bin:/bin" bash -c \
        "export HERDR_LINEAR_BIN_PATHS=''; . '$LIB/herdr-read.sh'; herdr_linear::probe; echo \"rc=\$?\""
    [ "$output" = "rc=1" ]
}

@test "a dead server's stderr is captured, not swallowed" {
    export HERDR_BIN="$(plant_herdr "$WORK/opt")/herdr"
    export FAKE_HERDR_MODE=dead
    run -1 herdr_linear::probe
    herdr_linear::probe || true
    [ -z "$HERDR_LINEAR_PROBE_OUT" ]
    [[ "$HERDR_LINEAR_PROBE_ERR" == *"could not connect"* ]]
}


@test "the session's position costs one pane get, never a snapshot walk" {
    # The env value was originally used raw, on the belief that it IS this
    # pane's id. It is an alias: after a pane moves workspace the old id keeps
    # resolving for the moved process while api snapshot reports the new one.
    # So one cheap `pane get` is the cost of a correct id -- but a snapshot
    # walk, which is what this accessor exists to avoid, still must not happen.
    export HERDR_BIN="$(plant_herdr "$WORK/opt")/herdr"
    export HERDR_PANE_ID="wA:p1"

    run -0 herdr_linear::pane_id
    [ "$output" = "wA:p1" ]

    record="$(argv_record)"
    [ "$record" = "pane get wA:p1" ]
    refute_match -q 'api snapshot' <<<"$record"
}

@test "tab and workspace ids resolve the same way, and are empty when unset" {
    export HERDR_BIN="$(plant_herdr "$WORK/opt")/herdr"
    # The env values are deliberately WRONG here. A fallback that returns them
    # would match a naive expectation, so the expectation is the resolved value.
    export HERDR_PANE_ID="wA:p9"
    export HERDR_TAB_ID="wSTALE:t0"
    export HERDR_WORKSPACE_ID="wSTALE"
    run -0 herdr_linear::tab_id
    [ "$output" = "wA:t2" ]
    run -0 herdr_linear::workspace_id
    [ "$output" = "wA" ]

    # The two calls above already invoked the fixture, so "no record file" is
    # not the question -- "no FURTHER invocation" is.
    before="$(argv_record | wc -l)"
    unset HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID
    run -1 herdr_linear::pane_id
    [ -z "$output" ]
    [ "$(argv_record | wc -l)" -eq "$before" ]
}

# Topology — the lookups that genuinely need neighbours

@test "a dotted field path is read out of a snapshot response" {
    export HERDR_BIN="$(plant_herdr "$WORK/opt")/herdr"
    run -0 bash -c "$(declare -f herdr_linear::json); '$WORK/opt/herdr' api snapshot | herdr_linear::json result.snapshot.focused_pane_id"
    [ "$output" = "wA:p1" ]

    run -0 bash -c "$(declare -f herdr_linear::json); '$WORK/opt/herdr' api snapshot | herdr_linear::json result.snapshot.panes.1.pane_id"
    [ "$output" = "wA:p2" ]

    run -0 bash -c "$(declare -f herdr_linear::json); '$WORK/opt/herdr' api snapshot | herdr_linear::json result.snapshot.nope.missing"
    [ -z "$output" ]
}

@test "the tab a pane sits in, and that tab's other panes, come from the snapshot" {
    export HERDR_BIN="$(plant_herdr "$WORK/opt")/herdr"

    run -0 herdr_linear::tab_of_pane "wA:p2"
    [ "$output" = "wA:t1" ]

    run -0 herdr_linear::panes_in_tab "wA:t1"
    [ "$output" = "wA:p1
wA:p2" ]

    run -1 herdr_linear::tab_of_pane "wA:nope"
    [ -z "$output" ]
}

@test "topology lookups against a dead server answer empty rather than garbage" {
    export HERDR_BIN="$(plant_herdr "$WORK/opt")/herdr"
    export FAKE_HERDR_MODE=dead
    run -1 herdr_linear::tab_of_pane "wA:p2"
    [ -z "$output" ]
    run -1 herdr_linear::panes_in_tab "wA:t1"
    [ -z "$output" ]
}

# The read-only boundary

@test "no accessor ever invokes a mutating herdr verb" {
    export HERDR_BIN="$(plant_herdr "$WORK/opt")/herdr"

    herdr_linear::bin >/dev/null
    herdr_linear::probe || true
    herdr_linear::pane_id >/dev/null || true
    herdr_linear::tab_id >/dev/null || true
    herdr_linear::workspace_id >/dev/null || true
    herdr_linear::snapshot >/dev/null || true
    herdr_linear::tab_of_pane "wA:p2" >/dev/null || true
    herdr_linear::panes_in_tab "wA:t1" >/dev/null || true

    record="$(argv_record)"
    [ -n "$record" ]  # the fixture WAS reached, so the absence below means something
    verbs="$("$FIX/fake-herdr.sh" --list-mutating-verbs)"
    [ -n "$verbs" ]   # an empty list would make the loop below vacuous
    for verb in $verbs; do
        refute_match -qw -- "$verb" <<<"$record"
    done
    # Only the two read verbs were ever used.
    # `pane get <id>` joins the allow-list because resolving this pane's own id
    # needs it and it mutates nothing. The list stays an ALLOW-list: a verb not
    # named here fails the test even if it is absent from the mutating set.
    refute_match -qvE '^(status server|api snapshot|pane get .*)$' <<<"$record"
}

@test "the readers work with jq absent, through the python3 fallback" {
    # jq is on this machine's PATH twice over, so "no jq" has to be built, not
    # assumed. Without this test the python3 branch never executes and a defect
    # in it ships green on every machine that has jq.
    mkdir -p "$WORK/bin"
    for t in bash python3 dirname basename mkdir seq cat env; do
        ln -sf "$(command -v "$t")" "$WORK/bin/$t"
    done

    run -0 env PATH="$WORK/bin" bash -c '! command -v jq'

    run -0 env PATH="$WORK/bin" HERDR_BIN="$FIX/fake-herdr.sh" bash -c \
        ". '$LIB/herdr-read.sh'; herdr_linear::tab_of_pane wA:p2; echo; herdr_linear::panes_in_tab wA:t1"
    [ "$output" = "wA:t1
wA:p1
wA:p2" ]

    run -0 env PATH="$WORK/bin" bash -c \
        ". '$LIB/herdr-read.sh'; '$FIX/fake-herdr.sh' api snapshot | herdr_linear::json result.snapshot.panes.1.pane_id"
    [ "$output" = "wA:p2" ]
}

@test "the session's own pane id is resolved, not taken from the environment" {
    # Herdr keeps a moved pane's OLD id resolving for that process, but api
    # snapshot reports the new one -- so the environment value is an alias, not
    # an identity. Trusting it makes tab_of_pane silently return empty, which is
    # exactly how the two accessors compose. Observed live: a pane moved from
    # wR:pA to wJ:p37 kept HERDR_PANE_ID=wR:pA.
    export HERDR_PANE_ID="wZ:pSTALE"
    export FAKE_HERDR_ALIAS_OF="wZ:pSTALE"
    export FAKE_HERDR_ALIAS_TO="wA:p2"

    run -0 herdr_linear::pane_id
    [ "$output" = "wA:p2" ]

    run -0 herdr_linear::tab_of_pane "$(herdr_linear::pane_id)"
    [ "$output" = "wA:t1" ]
}

@test "an unresolvable pane id falls back to the environment rather than emptying" {
    export HERDR_PANE_ID="wA:p1"
    export HERDR_BIN="$WORK/no-such-herdr"
    run herdr_linear::pane_id
    [ "$output" = "wA:p1" ]
}
