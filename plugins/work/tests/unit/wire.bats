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

manifest() { printf '{"name":"work","version":"%s"}' "$1" > "$WORK/plugin.json"; }
marketplace() { printf '{"plugins":[{"name":"%s","version":"%s"}]}' "$1" "$2" > "$WORK/marketplace.json"; }

@test "matching versions pass" {
    manifest 0.1.0; marketplace work 0.1.0
    run version_sync_check "$WORK/plugin.json" "$WORK/marketplace.json"
    [ "$status" -eq 0 ]
}

@test "drifted versions fail and name both" {
    manifest 0.1.0; marketplace work 0.2.0
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

# --- run_suite: a directory with zero .bats files must FAIL, not pass silently ---

@test "run_suite fails loudly on an empty directory" {
    run run_suite "$WORK"
    [ "$status" -ne 0 ]
    [[ "$output" == *"zero .bats files found under"* ]]
    [[ "$output" == *"$WORK"* ]]
}

@test "run_suite fails when the suite count drops below the floor" {
    cat > "$WORK/one.bats" <<'EOF'
@test "trivially true" { [ 1 -eq 1 ]; }
EOF
    HERDR_LINEAR_MIN_SUITES=2 run run_suite "$WORK"
    [ "$status" -ne 0 ]
    [[ "$output" == *"expected at least 2"* ]]
}

@test "run_suite passes when the suite count meets the floor and tests pass" {
    cat > "$WORK/one.bats" <<'EOF'
@test "trivially true" { [ 1 -eq 1 ]; }
EOF
    HERDR_LINEAR_MIN_SUITES=1 run run_suite "$WORK"
    [ "$status" -eq 0 ]
}

# --- skill_lib_sync_check: a skill's declared sourcing must cover the real
# dependency closure of the functions it calls, computed from the lib files
# themselves rather than trusted by inspection ---

# owned_skills is a fixed list inside the check, so a fixture root needs a
# (possibly empty) SKILL.md for each of the five names or the check reports
# them as missing, which would mask the thing under test.
sync_fixture() {
    local root="$1" describe_block="$2"
    mkdir -p "$root/lib"
    cat > "$root/lib/a.sh" <<'EOF'
herdr_linear::fn_a() { :; }
EOF
    cat > "$root/lib/b.sh" <<'EOF'
herdr_linear::fn_b() { herdr_linear::fn_a; }
EOF
    for s in new new-sub-issue bind layout; do
        mkdir -p "$root/skills/$s"
        printf -- '---\nname: %s\n---\nno bash here\n' "$s" > "$root/skills/$s/SKILL.md"
    done
    mkdir -p "$root/skills/describe"
    printf -- '---\nname: describe\n---\n%s\n' "$describe_block" > "$root/skills/describe/SKILL.md"
}

@test "sync check fails when a skill sources too few lib files" {
    sync_fixture "$WORK" '```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/b.sh"
herdr_linear::fn_b
```'
    run skill_lib_sync_check "$WORK"
    [ "$status" -ne 0 ]
    [[ "$output" == *"missing"*"'a'"* ]] || [[ "$output" == *"missing ['a']"* ]]
}

@test "sync check passes when sourcing covers the full dependency closure" {
    sync_fixture "$WORK" '```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/a.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/b.sh"
herdr_linear::fn_b
```'
    run skill_lib_sync_check "$WORK"
    [ "$status" -eq 0 ]
}

@test "sync check flags a call to a function defined nowhere" {
    sync_fixture "$WORK" '```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/a.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/b.sh"
herdr_linear::fn_never_defined
```'
    run skill_lib_sync_check "$WORK"
    [ "$status" -ne 0 ]
    [[ "$output" == *"undefined function"* ]]
    [[ "$output" == *"fn_never_defined"* ]]
}

