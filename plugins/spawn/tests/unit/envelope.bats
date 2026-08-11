#!/usr/bin/env bats
# U3 — one envelope in common.sh (R23).
#
# WHAT THIS SUITE IS FOR
# ----------------------
# Each script encodes a response in THREE places: the jq success emit, the jq
# error emit, and a pure-bash fallback for a box with no jq at all (plus the
# hardcoded string inside need_jq, which is the same tier). Three encoders is
# how a field set drifts: a change lands in the tier that runs every day and
# not in the one nobody runs, and the drift is invisible until the day the
# unusual tier is the one a consumer gets.
#
# So every assertion here is made on a RUN of a script, never on its source. In
# particular the no-jq tier is exercised by making jq genuinely unreachable —
# a broken jq shim on PATH does not test it at all, because `command -v jq`
# still succeeds and the script takes the jq branch.
#
# The assertions are on FIELD NAMES and enum values, not prose: R23's promise is
# that a Bash-only consumer can branch on the same names whichever script it
# called.

setup() {
    LIB="$(cd "$BATS_TEST_DIRNAME/../../lib" && pwd)"
    FIX="$(cd "$BATS_TEST_DIRNAME/../fixtures" && pwd)"
    LENS="$LIB/lens.sh"
    LAUNCH="$LIB/launch.sh"
    CTL="$LIB/spawnctl.sh"
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/gw-env.XXXXXX")"
    WORK="$(cd "$WORK" && pwd -P)"
    GW_PID=""

    export SPAWN_STATE_HOME="$WORK"
    export SPAWN_SEARCH_ROOT="$WORK/searchroot"
    mkdir -p "$SPAWN_SEARCH_ROOT"
    export TMPDIR="$WORK/tmp"
    mkdir -p "$TMPDIR"
    export SPAWN_CONNECT_TIMEOUT=2
    export SPAWN_PROBE_TIMEOUT=5
    export SPAWN_START_TIMEOUT=10
    export SPAWN_LOCK_TIMEOUT=30
    unset SPAWN_INSTALL_DIR SPAWN_CONFIG SPAWN_MODELS_JSON
    unset SPAWN_LENS_TIMEOUT SPAWN_SPILL_BYTES SPAWN_LENS_MAX_TOKENS
    # A port nothing serves. A test that forgets to point somewhere must not
    # probe the REAL gateway on 4000 — the same guard lens.bats sets.
    export SPAWN_BASE_URL="http://127.0.0.1:1/anthropic"
    TOKEN="tok-env-s3cr3t-4b1c"
}

teardown() {
    if [ -n "${GW_PID:-}" ]; then
        kill "$GW_PID" 2>/dev/null || true
        wait "$GW_PID" 2>/dev/null || true
    fi
    for p in $(pgrep -f "$WORK" 2>/dev/null); do
        [ "$p" = "$$" ] && continue
        kill -9 "$p" 2>/dev/null
    done
    rm -rf "$WORK"
}

# --- helpers ---------------------------------------------------------------

# NEGATIVE ASSERTION. `! grep ...` is exempt from set -e and so never fails a
# test; this fails as a plain command, which set -e does honour. Same reason
# launch.bats:81-97 grew its refute_ helpers.
refute_json_field() {   # <json> <jq-path>
    local json="$1" path="$2" v
    v="$(printf '%s' "$json" | jq -r "$path" 2>/dev/null)"
    if [ "$v" != "null" ] && [ -n "$v" ]; then
        printf 'refute_json_field: expected %s to be null/absent, got: %s\n' "$path" "$v" >&2
        return 1
    fi
    return 0
}

make_config() {
    local path="$1" token="$2"; shift 2
    {
        printf 'server:\n'
        printf '  bind: "127.0.0.1:4000"\n'
        printf '  token: %s\n' "$token"
        printf '\nmodels:\n'
        local spec
        for spec in "$@"; do
            printf '  %s:\n' "${spec%%=*}"
            printf '    model: %s\n' "${spec#*=}"
        done
    } > "$path"
}

start_fixture() {
    local scenario="$1" aliases="$2"; shift 2
    local portfile="$WORK/port"
    rm -f "$portfile"
    python3 "$FIX/fake-gateway.py" \
        --token "$TOKEN" --aliases "$aliases" --scenario "$scenario" \
        --port-file "$portfile" "$@" >"$WORK/gw.out" 2>"$WORK/gw.err" &
    GW_PID=$!
    local i
    for i in $(seq 1 100); do
        [ -s "$portfile" ] && break
        sleep 0.05
    done
    PORT="$(cat "$portfile")"
    [ -n "$PORT" ]
    export SPAWN_BASE_URL="http://127.0.0.1:$PORT/anthropic"
    local a; local -a specs=() parts=()
    IFS=',' read -ra parts <<< "$aliases"
    for a in "${parts[@]}"; do specs+=("$a=up/$a"); done
    make_config "$WORK/gateway.yaml" "$TOKEN" "${specs[@]}"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
}

# THE ENVELOPE. One list, asserted against every response every script produces.
# A field added here without being added to common.sh turns this red everywhere
# at once, which is the point: the contract has one home.
assert_envelope() {   # <json> <expected-exit-code>
    local json="$1" code="$2"
    printf '%s' "$json" | jq -e '.' >/dev/null   # parses at all
    [ "$(printf '%s' "$json" | jq -s 'length')" = "1" ]   # exactly ONE object
    printf '%s' "$json" | jq -e '
        has("schema") and has("ok") and has("error") and has("remedy")
        and has("content_trust") and has("content_notice") and has("exit_code")' >/dev/null
    [ "$(printf '%s' "$json" | jq -r '.schema')" = "spawn.response/v1" ]
    [ "$(printf '%s' "$json" | jq -r '.exit_code')" = "$code" ]
    # ok and exit_code cannot disagree — a true/non-zero pair is the
    # announced-but-broken wrong-success this plugin refuses everywhere else.
    [ "$(printf '%s' "$json" | jq -r 'if .ok then 0 else 1 end')" = "$([ "$code" = "0" ] && echo 0 || echo 1)" ]
    # `error` is an ENUM or null — never prose. Enforced structurally: a lower
    # snake_case token, which "a gateway is serving but the pidfile is..." is
    # not.
    printf '%s' "$json" | jq -e '.error == null or (.error | test("^[a-z][a-z0-9_]*$"))' >/dev/null
    # ...and it is present exactly when the call failed.
    printf '%s' "$json" | jq -e 'if .ok then .error == null else .error != null end' >/dev/null
    printf '%s' "$json" | jq -e '.content_trust | test("^[a-z][a-z0-9-]*$")' >/dev/null
    printf '%s' "$json" | jq -e '.content_notice | length > 0' >/dev/null
}

# jq_free_path — a PATH holding everything the scripts need EXCEPT jq. A shim
# that errors would not do: `command -v jq` succeeds and the script never
# reaches its fallback, so the tier under test would be the jq tier again.
jq_free_path() {
    local d="$WORK/nojq" t p
    mkdir -p "$d"
    for t in bash sh curl sed awk grep egrep fgrep cat wc tr cut head tail sort \
             mktemp dirname basename mkdir rm cp mv ln chmod find kill sleep \
             date id uname stat python3 pgrep ps; do
        p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$d/$t"
    done
    printf '%s' "$d"
}

# --- scenario 1: every script, every response shape ------------------------

@test "R23: every script's ERROR response carries the envelope, with an enum in .error" {
    run bash -c "bash '$LENS' --alias 'bad;alias' < /dev/null 2>/dev/null"
    [ "$status" -eq 2 ]
    assert_envelope "$output" 2
    [ "$(echo "$output" | jq -r '.error')" = "usage" ]

    run bash -c "bash '$LAUNCH' --alias 'bad;alias' < /dev/null 2>/dev/null"
    [ "$status" -eq 2 ]
    assert_envelope "$output" 2
    [ "$(echo "$output" | jq -r '.error')" = "usage" ]

    run bash -c "bash '$CTL' no-such-verb 2>/dev/null"
    [ "$status" -eq 2 ]
    assert_envelope "$output" 2
    [ "$(echo "$output" | jq -r '.error')" = "usage" ]
}

@test "R23: every script's HELP response carries the envelope" {
    run bash -c "bash '$LENS' -h 2>/dev/null"
    assert_envelope "$output" "$status"

    run bash -c "bash '$LAUNCH' -h 2>/dev/null"
    assert_envelope "$output" "$status"

    run bash -c "bash '$CTL' --help 2>/dev/null"
    assert_envelope "$output" "$status"
}

@test "R23: the lens's SUCCESS response carries the envelope and the untrusted marking" {
    start_fixture healthy "alpha"
    run bash -c "printf 'hello' | bash '$LENS' --alias alpha 2>/dev/null"
    [ "$status" -eq 0 ]
    assert_envelope "$output" 0
    [ "$(echo "$output" | jq -r '.content_trust')" = "untrusted-third-party-model-output" ]
    # The operation payload sits alongside the envelope, not under it: a
    # consumer reads .text, not .payload.text.
    [ "$(echo "$output" | jq -r '.text | length > 0')" = "true" ]
    refute_json_field "$output" '.error'
    refute_json_field "$output" '.remedy'
}

@test "R23: spawnctl's SUCCESS response carries the envelope and the plugin marking" {
    start_fixture healthy "alpha"
    run bash -c "bash '$CTL' ensure alpha 2>/dev/null"
    [ "$status" -eq 0 ]
    assert_envelope "$output" 0
    [ "$(echo "$output" | jq -r '.content_trust')" = "plugin-authored" ]
    [ "$(echo "$output" | jq -r '.verb')" = "ensure" ]
}

@test "R23: spawnctl status answers with the envelope whether the gateway is up or down" {
    # Down first — for `status` a dead gateway is a normal answer, so the
    # envelope has to hold on the answer a human reads most often.
    make_config "$WORK/gateway.yaml" "$TOKEN" "alpha=up/alpha"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
    run bash -c "bash '$CTL' status 2>/dev/null"
    [ "$status" -eq 3 ]
    assert_envelope "$output" 3
    [ "$(echo "$output" | jq -r '.error')" = "unreachable" ]
    [ "$(echo "$output" | jq -r '.running')" = "false" ]
    # The probe's prose is not lost — it moved to `detail`, where prose lives.
    [ "$(echo "$output" | jq -r '.detail | length > 0')" = "true" ]

    start_fixture healthy "alpha"
    run bash -c "bash '$CTL' status 2>/dev/null"
    [ "$status" -eq 0 ]
    assert_envelope "$output" 0
    [ "$(echo "$output" | jq -r '.running')" = "true" ]
}

# --- scenario 2: the tier nobody runs --------------------------------------

@test "R23/KTD7: with jq ABSENT every script still emits one parseable envelope" {
    local nojq; nojq="$(jq_free_path)"
    # Proof the harness is testing what it claims: jq really is unreachable.
    run env PATH="$nojq" bash -c 'command -v jq 2>/dev/null'
    [ "$status" -ne 0 ]

    # lens and launch: the emit_error fallback.
    run env PATH="$nojq" bash -c "bash '$LENS' --alias 'bad;alias' < /dev/null 2>/dev/null"
    [ "$status" -eq 2 ]
    assert_envelope "$output" 2
    [ "$(echo "$output" | jq -r '.error')" = "usage" ]

    run env PATH="$nojq" bash -c "bash '$LAUNCH' --alias 'bad;alias' < /dev/null 2>/dev/null"
    [ "$status" -eq 2 ]
    assert_envelope "$output" 2

    # spawnctl: the need_jq string, which is a THIRD hand-written encoder and
    # the one most likely to be forgotten — it is reached before any verb runs.
    run env PATH="$nojq" bash -c "bash '$CTL' status 2>/dev/null"
    [ "$status" -eq 2 ]
    assert_envelope "$output" 2
    [ "$(echo "$output" | jq -r '.verb')" = "status" ]
}

@test "R12/R23: every failure carries a remedy, on every encoder tier" {
    # --describe declares remedy present on every failure ("null only on
    # success"). Two of the three tiers used to break that promise: the bash
    # encoder hardcoded remedy null while emit_error computed a real one and
    # threaded it into the jq object only, and need_jq — the tier that fires
    # when jq is genuinely absent — passed none at all.
    #
    # The tiers do NOT carry the same remedy for a given argv, and asserting
    # that they do would be asserting something false: without jq the script
    # cannot reach alias validation, so it fails at need_jq with a different,
    # correct error. The invariant is that the field is answered, never that
    # the two answers match.
    local nojq; nojq="$(jq_free_path)"
    run env PATH="$nojq" bash -c 'command -v jq 2>/dev/null'
    [ "$status" -ne 0 ]

    local s arg rem
    # jq present: a classified usage error.
    for s in "$LENS" "$LAUNCH"; do
        run bash -c "bash '$s' --alias < /dev/null 2>/dev/null"
        [ "$status" -eq 2 ]
        rem="$(echo "$output" | jq -r '.remedy')"
        [ -n "$rem" ] && [ "$rem" != "null" ]
    done

    # jq absent: need_jq's tier, in all three scripts.
    for s in "$LENS:--alias" "$LAUNCH:--alias" "$CTL:bogusverb"; do
        arg="${s##*:}"
        run env PATH="$nojq" bash -c "bash '${s%%:*}' $arg < /dev/null 2>/dev/null"
        [ "$status" -eq 2 ]
        rem="$(echo "$output" | jq -r '.remedy')"
        [ -n "$rem" ] && [ "$rem" != "null" ]
    done
}

@test "R23: the no-jq fallback carries the same trust marking as the jq tier" {
    local nojq; nojq="$(jq_free_path)"
    run env PATH="$nojq" bash -c "bash '$LENS' --alias 'bad;alias' < /dev/null 2>/dev/null"
    [ "$(echo "$output" | jq -r '.content_trust')" = "untrusted-third-party-model-output" ]
    run env PATH="$nojq" bash -c "bash '$CTL' status 2>/dev/null"
    [ "$(echo "$output" | jq -r '.content_trust')" = "plugin-authored" ]
}

# --- scenario 3: EMITTED -------------------------------------------------

@test "KTD2: no script emits twice, on any path, with or without jq" {
    start_fixture healthy "alpha"
    local out
    out="$(printf 'hello' | bash "$LENS" --alias alpha 2>/dev/null)"
    [ "$(printf '%s' "$out" | jq -s 'length')" = "1" ]
    out="$(bash "$CTL" ensure alpha 2>/dev/null)"
    [ "$(printf '%s' "$out" | jq -s 'length')" = "1" ]
    # An unserved alias runs the preflight rewrap: ensure emits its object into
    # a pipe and the lens emits its own — exactly one reaches stdout.
    out="$(printf 'hello' | bash "$LENS" --alias gamma 2>/dev/null || true)"
    [ "$(printf '%s' "$out" | jq -s 'length')" = "1" ]

    local nojq; nojq="$(jq_free_path)"
    out="$(env PATH="$nojq" bash "$LENS" --alias 'bad;alias' < /dev/null 2>/dev/null || true)"
    [ "$(printf '%s' "$out" | jq -s 'length')" = "1" ]
}

# --- scenario 4: a preflight failure is switchable --------------------------

@test "R23: a preflight failure reaches the caller as ONE enum value, in every script" {
    start_fixture healthy "alpha,beta"
    make_config "$WORK/gateway.yaml" "$TOKEN" "alpha=up/alpha" "beta=up/beta"
    export SPAWN_CONFIG="$WORK/gateway.yaml"

    # spawnctl's own answer and the two rewraps must all say alias_unknown —
    # the divergence this unit exists to close was spawnctl saying it in
    # English while the lenses said it as an enum.
    run bash -c "bash '$CTL' ensure gamma 2>/dev/null"
    [ "$status" -eq 4 ]
    [ "$(echo "$output" | jq -r '.error')" = "alias_unknown" ]

    run bash -c "printf 'hi' | bash '$LENS' --alias gamma 2>/dev/null"
    [ "$status" -eq 4 ]
    assert_envelope "$output" 4
    [ "$(echo "$output" | jq -r '.error')" = "alias_unknown" ]
    [ "$(echo "$output" | jq -r '.preflight.error')" = "alias_unknown" ]

    run bash -c "printf 'hi' | bash '$LAUNCH' --alias gamma 2>/dev/null"
    [ "$status" -eq 4 ]
    assert_envelope "$output" 4
    [ "$(echo "$output" | jq -r '.error')" = "alias_unknown" ]
    [ "$(echo "$output" | jq -r '.preflight.error')" = "alias_unknown" ]
}

@test "R23: a preflight AUTH failure agrees on the enum across all three scripts, and its prose survives in detail" {
    start_fixture healthy "alpha"
    make_config "$WORK/bad.yaml" "wrong-token" "alpha=up/alpha"
    export SPAWN_CONFIG="$WORK/bad.yaml"

    run bash -c "bash '$CTL' ensure alpha 2>/dev/null"
    [ "$status" -eq 7 ]
    [ "$(echo "$output" | jq -r '.error')" = "auth_rejected" ]
    [ "$(echo "$output" | jq -r '.detail | length > 0')" = "true" ]

    run bash -c "printf 'hi' | bash '$LENS' --alias alpha 2>/dev/null"
    [ "$status" -eq 7 ]
    [ "$(echo "$output" | jq -r '.error')" = "auth_rejected" ]
    # The rewrap did not swallow the control layer's prose.
    [ "$(echo "$output" | jq -r '.detail | length > 0')" = "true" ]
    [ "$(echo "$output" | jq -r '.preflight.error')" = "auth_rejected" ]
}

# --- scenario 5: the empty-payload guard -----------------------------------

@test "KTD2: emit still refuses an empty payload rather than writing a bare newline" {
    # Sourced directly: this is the one guard whose whole job is to produce NO
    # output, so it cannot be observed through a script that also succeeds.
    run bash -c ". '$LIB/common.sh'; EMITTED=0; emit ''; printf 'rc=%s\n' \"\$?\""
    [ "$status" -eq 0 ]
    [ "$output" = "rc=1" ]

    # And a non-empty payload is written exactly once.
    run bash -c ". '$LIB/common.sh'; EMITTED=0; emit '{\"a\":1}'; emit '{\"a\":2}'"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -s 'length')" = "1" ]
    [ "$(printf '%s' "$output" | jq -r '.a')" = "1" ]
}

@test "R23: the exit-code -> enum table is one table, and it refuses to guess" {
    run bash -c ". '$LIB/common.sh'; for c in 0 2 3 4 5 6 7 99; do printf '%s=%s\n' \"\$c\" \"\$(spawn::enum_for_code \$c)\"; done"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | grep '^0=')" = "0=" ]
    [ "$(echo "$output" | grep '^2=')" = "2=usage" ]
    [ "$(echo "$output" | grep '^3=')" = "3=unreachable" ]
    [ "$(echo "$output" | grep '^4=')" = "4=alias_unknown" ]
    [ "$(echo "$output" | grep '^5=')" = "5=upstream_error" ]
    [ "$(echo "$output" | grep '^6=')" = "6=deadline_exceeded" ]
    [ "$(echo "$output" | grep '^7=')" = "7=auth_rejected" ]
    # An unnamed code returns nothing rather than inventing a value the
    # contract does not list — the caller supplies its own fallback.
    [ "$(echo "$output" | grep '^99=')" = "99=" ]
}

# --- the two tiers must agree on the FIELD SET, not just the core -----------
#
# The pre-existing jq-absent tests assert the shared envelope core plus
# `.error`. That is not enough: it passed green while launch.sh's bash tier was
# missing `cwd`, `base_url` and `context_window` — three fields its own jq tier
# emits and its own --describe publishes. A consumer on a box without jq got a
# different shape than the contract promises, and nothing went red.
#
# common.sh states the rule this pins: "Any envelope that covers fewer than
# three drifts on the tier it missed, silently, because the missing tier is the
# one nobody runs." Comparing key sets is what turns that from a warning into a
# guard.

@test "R23: the jq and no-jq tiers emit the SAME KEYS for the same failure" {
    local nojq; nojq="$(jq_free_path)"
    run env PATH="$nojq" bash -c 'command -v jq 2>/dev/null'
    [ "$status" -ne 0 ]

    local script name with without only_jq only_bash
    for script in "$LENS" "$LAUNCH"; do
        name="$(basename "$script")"

        # Same invocation, same failure, both tiers.
        with="$(bash "$script" --alias 'bad;alias' < /dev/null 2>/dev/null \
                 | jq -S 'keys' 2>/dev/null)"
        without="$(env PATH="$nojq" bash -c "bash '$script' --alias 'bad;alias' < /dev/null 2>/dev/null" \
                 | jq -S 'keys' 2>/dev/null)"

        # Guard the guard: both tiers actually produced something parseable, or
        # "the key sets match" is a statement about two empty strings.
        [ -n "$with" ] || { echo "$name: jq tier produced nothing"; return 1; }
        [ -n "$without" ] || { echo "$name: no-jq tier produced nothing"; return 1; }

        if [ "$with" != "$without" ]; then
            only_jq="$(jq -n --argjson a "$with" --argjson b "$without" '$a - $b | join(",")')"
            only_bash="$(jq -n --argjson a "$with" --argjson b "$without" '$b - $a | join(",")')"
            echo "$name: encoder tiers disagree on their field set"
            echo "  only in the jq tier:    ${only_jq:-<none>}"
            echo "  only in the bash tier:  ${only_bash:-<none>}"
            return 1
        fi
    done
}

@test "R23: every error enum a surface can EMIT is published in its error_values" {
    # The contract a consumer builds a switch from is `error_values`. A surface
    # that can emit an enum it does not publish hands that consumer a value its
    # own documentation says cannot occur.
    #
    # This was live twice over when the check was written:
    #   * lens emitted `deadline_exceeded` (lens.sh:686) and published it in the
    #     exit_codes table but NOT in error_values — two published tables
    #     disagreeing with each other;
    #   * both surfaces gained `internal` when encoder failures stopped
    #     masquerading as `usage`, and neither published it.
    # Neither was found by reading. Both fell out of comparing the two lists
    # mechanically, which is the only way this stays true as enums are added.
    local script name published emitted missing
    for script in "$LENS" "$LAUNCH"; do
        name="$(basename "$script")"
        published="$(bash "$script" --describe 2>/dev/null | jq -r '.error_values[].value' | sort -u)"
        # Every `die "$EX_..." "<enum>"` site — the only way these surfaces
        # produce a classified failure.
        emitted="$(grep -oE 'die "\$EX_[A-Z]+" "[a-z_]+"' "$script" \
                   | sed 's/.*"\([a-z_]*\)"$/\1/' | sort -u)"

        # Guard the guard: if either extraction breaks, this test must fail
        # loudly rather than compare two empty sets and pass.
        [ -n "$published" ] || { echo "$name: no error_values published"; return 1; }
        [ -n "$emitted" ] || { echo "$name: found no die sites — the grep broke"; return 1; }

        missing="$(comm -13 <(echo "$published") <(echo "$emitted") | tr '\n' ' ')"
        if [ -n "${missing// /}" ]; then
            echo "$name emits enum(s) it does not publish in error_values: $missing"
            return 1
        fi
    done
}

@test "R23: the shared envelope helpers survive a consumer that declares none of their globals" {
    # common.sh's helpers read the CALLER's globals by bash dynamic scoping —
    # EMITTED, ALIAS, HELP_REQUESTED, REMEDY, remedy_for. Every script here runs
    # under `set -u`, where an undefined global is FATAL, so an unguarded read
    # kills the next consumer inside the one function whose entire job is
    # guaranteeing something reaches stdout.
    #
    # This was live: emit() read "$EMITTED" bare, and a bare consumer aborted
    # with "EMITTED: unbound variable" mid-emit, printing nothing at all — the
    # exact failure emit's own header says it exists to prevent.
    #
    # NOTE ON THE ASSERTIONS: the first version of this check piped straight to
    # `jq -e .` and reported success, because jq on EMPTY input exits 0. It was
    # passing against zero bytes. Emptiness is therefore asserted BEFORE
    # validity, and the field values after — an order this file has been bitten
    # into using.
    local consumer="$BATS_TEST_TMPDIR/bare-consumer.sh"
    cat > "$consumer" <<EOS
set -uo pipefail
SCRIPT_DIR="$LIB"
. "\$SCRIPT_DIR/sanitize.sh"
. "\$SCRIPT_DIR/common.sh"
spawn::emit_error plugin "foo bar" 2 usage "a consumer declaring none of the globals"
EOS

    run bash "$consumer"
    [ "$status" -eq 0 ]
    # Non-empty FIRST — this is the assertion the vacuous version skipped.
    [ -n "$output" ]
    [ "$(printf '%s' "$output" | wc -c | tr -d ' ')" -gt 100 ]
    # Exactly one object, and parseable.
    [ "$(echo "$output" | jq -s 'length')" = "1" ]
    # The caller-named null fields are present...
    [ "$(echo "$output" | jq -r 'has("foo")')" = "true" ]
    [ "$(echo "$output" | jq -r 'has("bar")')" = "true" ]
    # ...and it fell back to the shared remedy table rather than dying on a
    # remedy_for the consumer never defined.
    [ "$(echo "$output" | jq -r '.remedy')" != "null" ]
    [ "$(echo "$output" | jq -r '.error')" = "usage" ]
}
