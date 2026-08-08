#!/usr/bin/env bats
# U2 — declare families and tiers; comprehend prose.
#
# WHAT THIS SUITE IS FOR
# -----------------------
# Comprehending prose ("kimi k3, review this diff" -> --alias k3) is the
# READING AGENT's job (KD6): the command layer comprehends, the script layer
# parses. There is no bash prose parser to unit-test. What IS mechanical, and
# what this suite pins:
#
#   1. the declared grammar in lib/models.json is internally consistent —
#      every family default and every tier alias actually exists in the flat
#      aliases map, so the grammar never points a resolved family/tier at
#      nothing;
#   2. AE1/AE2/AE3 as DATA assertions on that declared table;
#   3. AE8/R24: the byte-for-byte prompt guarantee still holds at the script
#      layer, independent of which alias carried it;
#   4. a malformed families/no_family_alias/chain_policy block collapses to a
#      safe empty value rather than breaking table_json()'s downstream
#      consumer (spawnctl status's drift computation);
#   5. the chain policy (KTD4) is declared, and bg-agent is refuse while
#      agent/session are allow;
#   6. --describe (all three scripts) declares the grammar as data, per U4's
#      agreement contract.

setup() {
    FIX="$(cd "$BATS_TEST_DIRNAME/../fixtures" && pwd)"
    LIB="$(cd "$BATS_TEST_DIRNAME/../../lib" && pwd)"
    LENS="$LIB/lens.sh"
    LAUNCH="$LIB/launch.sh"
    CTL="$LIB/spawnctl.sh"
    SHIPPED_MODELS_JSON="$LIB/models.json"
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/gw-models.XXXXXX")"
    WORK="$(cd "$WORK" && pwd -P)"
    TOKEN="tok-models-s3cr3t-4b1e"
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
    unset SPAWN_LAUNCH_TIMEOUT
    # A port nothing serves. A test that forgets to point somewhere must not
    # probe the REAL gateway on 4000.
    export SPAWN_BASE_URL="http://127.0.0.1:1/anthropic"
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

# NEGATIVE ASSERTIONS. bats runs under `set -e`, but POSIX exempts a pipeline
# beginning with `!` from it, so `! grep -q ...` never fails a test — the same
# footgun launch.bats:81-97 and describe.bats document. These fail as PLAIN
# commands.
refute_match() {        # <extended-regex> <string>
    if printf '%s' "$2" | grep -qE -- "$1"; then
        printf 'refute_match: unexpected match for %s in:\n%s\n' "$1" "$2" >&2
        return 1
    fi
    return 0
}

# Run the lens capturing STDOUT ONLY, prompt on stdin.
lens() {
    local prompt="$1"; shift
    run bash -c 'printf "%s" "$1" | bash "$2" "${@:3}" 2>/dev/null' _ "$prompt" "$LENS" "$@"
}

# Run spawnctl capturing STDOUT ONLY.
ctl() {
    run bash -c 'bash "$1" "${@:2}" 2>/dev/null' _ "$CTL" "$@"
}

describe_of() {         # <script> — prints the describe object, fails if not exit 0
    local out rc
    out="$(bash "$1" --describe 2>/dev/null)"; rc=$?
    [ "$rc" -eq 0 ] || { printf 'describe_of: %s exited %s\n' "$1" "$rc" >&2; return 1; }
    printf '%s' "$out"
}

# make_config <path> <token> [alias=model ...] — enough gateway.yaml for the
# control layer's token read.
make_config() {
    local path="$1" token="$2"; shift 2
    {
        printf 'server:\n'
        printf '  bind: "127.0.0.1:4000"\n'
        printf '  token: %s        # Bearer or x-api-key\n' "$token"
        printf '\nmodels:\n'
        local spec
        for spec in "$@"; do
            printf '  %s:\n' "${spec%%=*}"
            printf '    model: %s\n' "${spec#*=}"
        done
    } > "$path"
}

# start_fixture <scenario> <aliases> [extra fake-gateway.py args...]
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

    local a
    local -a specs=() parts=()
    IFS=',' read -ra parts <<< "$aliases"
    for a in "${parts[@]}"; do specs+=("$a=up/$a"); done
    make_config "$WORK/gateway.yaml" "$TOKEN" "${specs[@]}"
    export SPAWN_CONFIG="$WORK/gateway.yaml"
}

write_table() {          # <json> — a malformed or custom table for status/describe
    printf '%s\n' "$1" > "$WORK/models.json"
    export SPAWN_MODELS_JSON="$WORK/models.json"
}

# --- 1. the declared grammar is internally consistent -----------------------

@test "declared grammar: every family default and every tier alias exists in the aliases map" {
    run jq -e '
        (.aliases // {}) as $a
        | [ (.families // {}) | to_entries[] as $f
            | ($f.value.default), ($f.value.tiers // {} | to_entries[].value)
          ]
        | all(. as $alias | $a | has($alias))
    ' "$SHIPPED_MODELS_JSON"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
}

@test "declared grammar: no_family_alias is itself a served alias" {
    run jq -e '(.aliases // {}) as $a | .no_family_alias as $n | $a | has($n)' "$SHIPPED_MODELS_JSON"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
}

# --- 2. AE1 / AE2 / AE3 as data assertions ----------------------------------

@test "AE1: kimi + k3 tier is declared to resolve to the k3 alias" {
    run jq -r '.families.kimi.tiers.k3' "$SHIPPED_MODELS_JSON"
    [ "$status" -eq 0 ]
    [ "$output" = "k3" ]
}

@test "AE2: a bare family resolves to its declared default, and the default is a served alias" {
    run jq -r '.families.gpt.default' "$SHIPPED_MODELS_JSON"
    [ "$status" -eq 0 ]
    [ "$output" = "gpt" ]
    run jq -e '.aliases | has("gpt")' "$SHIPPED_MODELS_JSON"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
}

@test "AE3: a family absent from the declared block is absent, not silently defaulted" {
    # Take the shipped grammar and drop the glm family entirely — table_json()
    # (spawnctl.sh) is the shape normalizer under test elsewhere; here the
    # assertion is on the SOURCE data contract: an absent family must not
    # resolve to anything, default included.
    run bash -c 'jq "del(.families.glm)" "$1"' _ "$SHIPPED_MODELS_JSON"
    [ "$status" -eq 0 ]
    local mutated="$output"
    run bash -c 'printf "%s" "$1" | jq -e ".families | has(\"glm\") | not"' _ "$mutated"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
    # And glm's alias is untouched in the aliases map — dropping the family
    # from the grammar does not remove the metadata entry, it removes only the
    # PATH prose would use to reach it.
    run bash -c 'printf "%s" "$1" | jq -e ".aliases | has(\"glm\")"' _ "$mutated"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
}

# --- 3. AE8 / R24: byte-for-byte, stdin only --------------------------------

@test "AE8/R24: prose with quotes, newlines and a leading dash reaches the model unchanged via stdin" {
    start_fixture healthy "alpha" --request-log "$WORK/req.jsonl"
    local prompt
    prompt="$(printf 'she said "hello"\n-not a flag\nline three')"

    lens "$prompt" --alias alpha
    [ "$status" -eq 0 ]
    [ -f "$WORK/req.jsonl" ]

    run jq -r '.body.messages[0].content' "$WORK/req.jsonl"
    [ "$status" -eq 0 ]
    [ "$output" = "$prompt" ]
}

@test "R24: a prompt on argv is refused with exit 2 and never reaches the wire, regardless of alias" {
    start_fixture healthy "alpha" --request-log "$WORK/req.jsonl"

    lens "" --alias alpha "a prompt smuggled in on argv"
    [ "$status" -eq 2 ]
    [ "$(echo "$output" | jq -r '.error')" = "usage" ]
    [ ! -f "$WORK/req.jsonl" ]
}

# --- 4. malformed families/chain_policy leaves drift working ----------------

@test "a malformed families block leaves the drift computation working" {
    start_fixture healthy "alpha"
    write_table '{
        "aliases": {"alpha": {"context_window": 1000, "source": "test", "model": "up/alpha", "chain": false}},
        "families": "this should be an object, not a string",
        "no_family_alias": 42,
        "chain_policy": ["also wrong"]
    }'

    ctl status
    [ "$status" -eq 0 ]
    # One parseable object.
    [ "$(echo "$output" | jq -s 'length')" = "1" ]
    # The drift block still has all four classes, none of them poisoned by the
    # malformed families/no_family_alias/chain_policy siblings in the same file.
    [ "$(echo "$output" | jq -r '.drift|keys|sort|join(",")')" \
        = "missing_from_table,missing_window,model_drift,unknown_resolution" ]
    [ "$(echo "$output" | jq -r '.drift.missing_from_table|length')" = "0" ]
    [ "$(echo "$output" | jq -r '.drift.missing_window|length')" = "0" ]
}

@test "a models.json that is not even an object collapses table_json() to the safe empty shape" {
    write_table '"just a string"'
    run bash "$CTL" --describe
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.families')" = "{}" ]
    [ "$(echo "$output" | jq -r '.no_family_alias')" = "null" ]
    [ "$(echo "$output" | jq -r '.chain_policy')" = "{}" ]
}

@test "a malformed family entry is DROPPED, not fabricated: siblings survive" {
    write_table '{
        "aliases": {"kimi": {"context_window": 1, "source": "t", "model": "m", "chain": false}},
        "families": {
            "kimi": {"default": "kimi", "tiers": {"k3": "k3"}},
            "glm": "not an object"
        },
        "no_family_alias": "kimi",
        "chain_policy": {"agent": "allow"}
    }'
    run bash "$CTL" --describe
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.families.kimi.default')" = "kimi" ]
    [ "$(echo "$output" | jq -e '.families | has("glm")')" = "false" ]
}

# --- 5. chain policy (KTD4) --------------------------------------------------

@test "chain policy is declared: bg-agent refuses, agent and session allow" {
    run jq -r '.chain_policy["bg-agent"]' "$SHIPPED_MODELS_JSON"
    [ "$status" -eq 0 ]
    [ "$output" = "refuse" ]
    run jq -r '.chain_policy.agent' "$SHIPPED_MODELS_JSON"
    [ "$status" -eq 0 ]
    [ "$output" = "allow" ]
    run jq -r '.chain_policy.session' "$SHIPPED_MODELS_JSON"
    [ "$status" -eq 0 ]
    [ "$output" = "allow" ]
}

# --- 6. --describe declares the grammar -------------------------------------

@test "--describe (lens.sh, launch.sh, spawnctl.sh) all declare families, no_family_alias and chain_policy" {
    local d
    for s in "$LENS" "$LAUNCH" "$CTL"; do
        d="$(describe_of "$s")"
        [ -n "$d" ]
        run bash -c 'printf "%s" "$1" | jq -e "has(\"families\") and has(\"no_family_alias\") and has(\"chain_policy\")"' _ "$d"
        [ "$status" -eq 0 ]
        [ "$output" = "true" ]
    done
}

@test "--describe's families block agrees with lib/models.json (the running version, not a copy)" {
    local d
    d="$(describe_of "$LENS")"
    run bash -c 'printf "%s" "$1" | jq -r ".families.kimi.tiers.k3"' _ "$d"
    [ "$status" -eq 0 ]
    [ "$output" = "k3" ]
    run bash -c 'printf "%s" "$1" | jq -r ".chain_policy[\"bg-agent\"]"' _ "$d"
    [ "$status" -eq 0 ]
    [ "$output" = "refuse" ]
}

@test "--describe answers the grammar with the gateway DOWN and no config present" {
    # setup() already leaves SPAWN_BASE_URL pointed at a dead port and no
    # SPAWN_CONFIG exported (R10's condition, reused here for U2's data).
    run bash "$LAUNCH" --describe
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.families.gpt.default')" = "gpt" ]
}
