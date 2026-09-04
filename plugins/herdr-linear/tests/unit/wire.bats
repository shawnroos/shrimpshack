#!/usr/bin/env bats
# The runner's own rules. Both exist because a green line over a broken rule is
# worse than no line: the version fields drift silently, and spawn's credential
# patterns do not match the one credential this plugin actually handles.

bats_require_minimum_version 1.5.0

setup() {
    RUNNER="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)/tests/run-tests.sh"
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/hl-wire.XXXXXX")"
    WORK="$(cd "$WORK" && pwd -P)"
    . "$RUNNER"
}

teardown() {
    [ -n "${WORK:-}" ] && rm -rf "$WORK"
    return 0
}

manifest() { printf '{"name":"herdr-linear","version":"%s"}' "$1" > "$WORK/plugin.json"; }
marketplace() { printf '{"plugins":[{"name":"%s","version":"%s"}]}' "$1" "$2" > "$WORK/marketplace.json"; }

@test "matching versions pass" {
    manifest 0.1.0; marketplace herdr-linear 0.1.0
    run version_sync_check "$WORK/plugin.json" "$WORK/marketplace.json"
    [ "$status" -eq 0 ]
}

@test "drifted versions fail and name both" {
    manifest 0.1.0; marketplace herdr-linear 0.2.0
    run version_sync_check "$WORK/plugin.json" "$WORK/marketplace.json"
    [ "$status" -ne 0 ]
    [[ "$output" == *"0.1.0"* ]]
    [[ "$output" == *"0.2.0"* ]]
}

@test "an unregistered plugin fails" {
    manifest 0.1.0; marketplace something-else 0.1.0
    run version_sync_check "$WORK/plugin.json" "$WORK/marketplace.json"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not registered"* ]]
}

@test "a Linear key shape is caught" {
    printf 'KEY=lin_api_%s\n' "AbCdEfGhIjKlMnOpQrStUv" > "$WORK/leak.txt"
    run scan_paths "$WORK"
    [ "$status" -ne 0 ]
}

@test "an Anthropic key shape is caught" {
    printf 'KEY=sk-ant-%s\n' "AbCdEfGhIjKlMnOpQrStUv" > "$WORK/leak.txt"
    run scan_paths "$WORK"
    [ "$status" -ne 0 ]
}

@test "a clean tree passes" {
    printf 'nothing to see here\n' > "$WORK/clean.txt"
    run scan_paths "$WORK"
    [ "$status" -eq 0 ]
}

