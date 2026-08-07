#!/usr/bin/env bats
# Regression guards for the defects the code review found.
#
# Every test in this file was written AFTER a fix and then verified by mutating
# the fix back out and watching the test go red. A test that has only ever been
# seen green proves nothing — that is precisely how this change set reached
# review with a 114-test suite passing over seven P1 defects. The mutation used
# for each one is named in its comment so the next person can repeat it.
#
# The unifying theme of the fixes below: each was already fixed ONCE somewhere
# else in the same file, and the sibling instance was missed.

setup() {
    FIX="$(cd "$BATS_TEST_DIRNAME/../fixtures" && pwd)"
    LIB="$(cd "$BATS_TEST_DIRNAME/../../lib" && pwd)"
    CTL="$LIB/gatewayctl.sh"
    LENS="$LIB/lens.sh"
    LAUNCH="$LIB/launch.sh"
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/gw-regress.XXXXXX")"
    WORK="$(cd "$WORK" && pwd -P)"
    TOKEN="tok-regress-123"
    GW_PID=""

    export GATEWAY_STATE_HOME="$WORK"
    export GATEWAY_SEARCH_ROOT="$WORK/searchroot"
    mkdir -p "$GATEWAY_SEARCH_ROOT"
    export GATEWAY_CONNECT_TIMEOUT=2
    export GATEWAY_PROBE_TIMEOUT=5
    export GATEWAY_START_TIMEOUT=10
    export GATEWAY_LOCK_TIMEOUT=10
    unset GATEWAY_INSTALL_DIR GATEWAY_CONFIG GATEWAY_MODELS_JSON
    export GATEWAY_BASE_URL="http://127.0.0.1:1/anthropic"
}

teardown() {
    [ -n "${GW_PID:-}" ] && { kill "$GW_PID" 2>/dev/null; wait "$GW_PID" 2>/dev/null; }
    local p
    for p in $(pgrep -f "$WORK" 2>/dev/null); do
        [ "$p" = "$$" ] && continue
        kill -9 "$p" 2>/dev/null
    done
    rm -rf "$WORK"
}

start_fixture() {
    local scenario="${1:-healthy}" aliases="${2:-kimi}"
    local portfile="$WORK/port"
    python3 "$FIX/fake-gateway.py" \
        --token "$TOKEN" --aliases "$aliases" --scenario "$scenario" \
        --port-file "$portfile" >"$WORK/gw.out" 2>"$WORK/gw.err" &
    GW_PID=$!
    local i
    for i in $(seq 1 100); do
        [ -s "$portfile" ] && break
        sleep 0.05
    done
    PORT="$(cat "$portfile")"
    [ -n "$PORT" ]
    export GATEWAY_BASE_URL="http://127.0.0.1:$PORT/anthropic"
}

make_config() {
    local path="$1" port="$2" token="$3"
    {
        printf 'server:\n'
        printf '  bind: "127.0.0.1:%s"\n' "$port"
        printf '  token: %s\n' "$token"
        printf '\nmodels:\n'
        printf '  kimi:\n    model: up/kimi\n    display_name: "kimi"\n'
    } > "$path"
}

# --- KTD2: one JSON object on stdout, ALWAYS -------------------------------
#
# MUTATION that must turn these red: in the tmpwork() of the script under test,
# delete the emit_error line, leaving `printf ... >&2; exit 2`. That is the
# code exactly as it shipped into review. Verified red for all three.
#
# The bug: need_jq, eight lines below tmpwork in each file, already carried this
# fix with a comment explaining why silence is a contract violation a consumer
# cannot distinguish from a crash. tmpwork did not.

@test "KTD2: gatewayctl emits one JSON object when the temp dir cannot be created" {
    run bash -c "TMPDIR=/nonexistent-regress-dir/ bash '$CTL' status 2>/dev/null"
    [ "$status" -eq 2 ]
    [ -n "$output" ]
    run jq -e . <<< "$output"
    [ "$status" -eq 0 ]
}

@test "KTD2: lens emits one JSON object when the temp dir cannot be created" {
    run bash -c "printf 'hi' | TMPDIR=/nonexistent-regress-dir/ bash '$LENS' --alias kimi 2>/dev/null"
    [ "$status" -eq 2 ]
    [ -n "$output" ]
    run jq -e . <<< "$output"
    [ "$status" -eq 0 ]
}

# HONEST SCOPE — read this before trusting what the name implies.
#
# This does NOT exercise launch's own tmpwork. launch calls `ensure` (~line 252)
# long before tmpwork (~line 340), so an unusable TMPDIR fails inside the
# gatewayctl SUBPROCESS first. launch's own tmpwork emit_error is defensive
# depth for a TMPDIR that goes unwritable mid-run, and is UNREACHABLE BY THIS
# TEST. An unreachable line that a test appears to cover is worse than an
# uncovered one.
#
# What it actually guards is a DISJUNCTION, established by mutation:
#   * revert gatewayctl's tmpwork emit alone  -> still green (launch's
#     silent-preflight fallback at launch.sh:258 covers it)
#   * delete launch's fallback alone          -> still green (gatewayctl's
#     object is non-empty and gets forwarded)
#   * remove BOTH                             -> RED
# So the contract has two independent guards and this test fails only when the
# last one goes. That is real defence in depth, not redundancy to be tidied
# away: whichever guard a future edit removes, the other still holds the
# contract, and this test catches the edit that removes the second.
@test "KTD2: launch still returns one parseable object when the temp dir is unusable" {
    run bash -c "printf 'hi' | TMPDIR=/nonexistent-regress-dir/ bash '$LAUNCH' --alias kimi 2>/dev/null"
    [ "$status" -eq 2 ]
    [ -n "$output" ]
    run jq -e . <<< "$output"
    [ "$status" -eq 0 ]
}

# --- status on a shape-valid but structurally wrong models table -----------
#
# MUTATION: revert table_json to `jq -c '.' < "$MODELS_JSON" || printf ...`.
# Verified red — status then exits 0 with zero bytes on stdout, which is the
# one failure a consumer cannot tell from success.
#
# models.json is hand-maintained metadata by KTD7's design, so a typo here is
# the expected input. launch.sh hardened its own read of this same file after
# hitting the identical class; status's two readers were left open.

@test "status emits one JSON object when an alias maps to a scalar, not an object" {
    start_fixture healthy "kimi"
    printf '{"version":1,"aliases":{"kimi": 5}}' > "$WORK/models.json"
    export GATEWAY_MODELS_JSON="$WORK/models.json"
    run bash "$CTL" status
    [ -n "$output" ]
    run jq -e . <<< "$output"
    [ "$status" -eq 0 ]
}

@test "status emits one JSON object when the models table is a top-level array" {
    start_fixture healthy "kimi"
    printf '[]' > "$WORK/models.json"
    export GATEWAY_MODELS_JSON="$WORK/models.json"
    run bash "$CTL" status
    [ -n "$output" ]
    run jq -e . <<< "$output"
    [ "$status" -eq 0 ]
}

# --- stop must never report success over a serving gateway -----------------
#
# MUTATION: delete the `probe` + unmanaged block from the stale-pidfile branch
# of `stop`. Verified red — stop then returns ok:true/exit 0, deletes the
# pidfile, and the fixture is still answering.
#
# The empty-pidfile branch three lines above already probed for this reason.

@test "stop refuses ok:true when the recorded pid is dead but a gateway still serves" {
    start_fixture healthy "kimi"
    printf '999999\n' > "$WORK/.gateway.pid"
    make_config "$WORK/gw.yaml" "$PORT" "$TOKEN"
    export GATEWAY_CONFIG="$WORK/gw.yaml"
    mkdir -p "$GATEWAY_SEARCH_ROOT/gateway-9.9.9/target/release"
    : > "$GATEWAY_SEARCH_ROOT/gateway-9.9.9/target/release/gateway"
    chmod +x "$GATEWAY_SEARCH_ROOT/gateway-9.9.9/target/release/gateway"

    # stdout ONLY: bats `run` merges stderr, and these paths print a say()/die()
    # diagnostic, which would make the captured text unparseable as JSON.
    run bash -c "bash '$CTL' stop 2>/dev/null"
    [ "$status" -ne 0 ]
    [ "$(jq -r '.ok' <<< "$output")" = "false" ]
    [ "$(jq -r '.result' <<< "$output")" = "unmanaged" ]
    # The pidfile is the only record of the live process; deleting it is what
    # made the gateway unstoppable through this surface on the next call.
    [ -f "$WORK/.gateway.pid" ]
    # And the gateway really is still up.
    run kill -0 "$GW_PID"
    [ "$status" -eq 0 ]
}

# --- stop must not republish an unrelated process's arguments --------------
#
# MUTATION: restore `--arg argv "...$(pid_argv "$pid")"` and the actual_argv
# field. Verified red — the sentinel appears in stdout.
#
# KTD6 refuses to put OUR token in argv because the process table is readable
# by anything on the box. Harvesting another process's argv into an agent
# transcript is that same leak with the roles reversed.

@test "stop reports the executable, not the argv, of a recycled pid" {
    local sentinel="SENTINEL-SECRET-ARGV-VALUE"
    # A long-lived process whose ARGV contains the sentinel. `sleep` rejects a
    # non-numeric argument, so use python, which accepts trailing argv freely.
    python3 -c 'import time,sys; time.sleep(30)' "$sentinel" &
    local helper=$!
    printf '%s\n' "$helper" > "$WORK/.gateway.pid"
    make_config "$WORK/gw.yaml" 1 "$TOKEN"
    export GATEWAY_CONFIG="$WORK/gw.yaml"
    mkdir -p "$GATEWAY_SEARCH_ROOT/gateway-9.9.9/target/release"
    : > "$GATEWAY_SEARCH_ROOT/gateway-9.9.9/target/release/gateway"
    chmod +x "$GATEWAY_SEARCH_ROOT/gateway-9.9.9/target/release/gateway"

    run bash -c "bash '$CTL' stop 2>/dev/null"
    kill -9 "$helper" 2>/dev/null

    [ "$(jq -r '.result' <<< "$output")" = "pid_mismatch" ]
    run grep -qF "$sentinel" <<< "$output"
    [ "$status" -ne 0 ]
}

# --- restart must not announce success when its stop leg refused -----------
#
# MUTATION: delete the `if [ "$stop_rc" -ne "$EX_OK" ]` block from restart.
# Verified red — restart then returns ok:true/exit 0 with the ORIGINAL process
# still serving the old config, which is the caller's whole reason for
# restarting silently not honoured.

@test "restart fails when the stop phase refused to signal anything" {
    start_fixture healthy "kimi"
    printf '999999\n' > "$WORK/.gateway.pid"
    make_config "$WORK/gw.yaml" "$PORT" "$TOKEN"
    export GATEWAY_CONFIG="$WORK/gw.yaml"
    mkdir -p "$GATEWAY_SEARCH_ROOT/gateway-9.9.9/target/release"
    : > "$GATEWAY_SEARCH_ROOT/gateway-9.9.9/target/release/gateway"
    chmod +x "$GATEWAY_SEARCH_ROOT/gateway-9.9.9/target/release/gateway"

    run bash -c "bash '$CTL' restart 2>/dev/null"
    [ "$status" -ne 0 ]
    [ "$(jq -r '.ok' <<< "$output")" = "false" ]
    # The fixture was never restarted.
    run kill -0 "$GW_PID"
    [ "$status" -eq 0 ]
}

# --- the untrusted-data contract reaches the machine channel ---------------
#
# MUTATION: drop content_trust/content_notice from either emit in lens.sh.
# Verified red.
#
# The rule lived only in skills/lens/SKILL.md, which states in its own text
# that the primary consumer cannot invoke a skill. The consumer that most needs
# "this is adversary-controlled" was the one guaranteed never to read it.

@test "lens marks the answer as untrusted in the JSON the consumer parses" {
    start_fixture healthy "kimi"
    make_config "$WORK/gw.yaml" "$PORT" "$TOKEN"
    export GATEWAY_CONFIG="$WORK/gw.yaml"

    run bash -c "printf 'question' | bash '$LENS' --alias kimi"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.content_trust' <<< "$output")" = "untrusted-third-party-model-output" ]
    run jq -e '.content_notice | test("never execute")' <<< "$output"
    [ "$status" -eq 0 ]
}

@test "lens marks the spill path as untrusted too" {
    start_fixture healthy "kimi"
    make_config "$WORK/gw.yaml" "$PORT" "$TOKEN"
    export GATEWAY_CONFIG="$WORK/gw.yaml"
    export GATEWAY_SPILL_BYTES=1

    run bash -c "printf 'question' | bash '$LENS' --alias kimi 2>/dev/null"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.output_file' <<< "$output")" != "null" ]
    [ "$(jq -r '.content_trust' <<< "$output")" = "untrusted-third-party-model-output" ]
    rm -f "$(jq -r '.output_file' <<< "$output")"
}

# --- emit must refuse an empty payload -------------------------------------
#
# The shared chokepoint. Every caller builds its argument with `emit "$(jq ...)"`
# and a jq that errors yields "" with no failure visible at the call site, so
# emit used to write a bare newline and mark the object as emitted.
#
# MUTATION: remove the `[ -n "$1" ] || return 1` line from common.sh emit.

@test "emit refuses an empty payload rather than writing a blank line" {
    run bash -c '
        EMITTED=0
        . "'"$LIB"'/common.sh"
        emit ""
        echo "rc=$?"
        echo "emitted=$EMITTED"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"rc=1"* ]]
    [[ "$output" == *"emitted=0"* ]]
}
