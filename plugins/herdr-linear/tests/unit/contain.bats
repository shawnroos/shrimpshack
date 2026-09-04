#!/usr/bin/env bats
# Containment is the plugin's outermost boundary: every entry point calls it
# before doing anything. A prefix match would admit a sibling directory and an
# unresolved symlink would admit whatever it points at, so both are tested.

bats_require_minimum_version 1.5.0

setup() {
    LIB="$(cd "$BATS_TEST_DIRNAME/../../lib" && pwd)"
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/hl-contain.XXXXXX")"
    WORK="$(cd "$WORK" && pwd -P)"
    mkdir -p "$WORK/Slate/web-app" "$WORK/SlateOther" "$WORK/outside"
    export HERDR_LINEAR_SLATE_ROOT="$WORK/Slate"
    . "$LIB/contain.sh"
}

teardown() {
    [ -n "${WORK:-}" ] && rm -rf "$WORK"
    return 0
}

@test "a path under the root is inside" {
    run herdr_linear::contains "$WORK/Slate/web-app"
    [ "$status" -eq 0 ]
}

@test "the root itself is inside" {
    run herdr_linear::contains "$WORK/Slate"
    [ "$status" -eq 0 ]
}

@test "a sibling whose name begins with the root path is outside" {
    run herdr_linear::contains "$WORK/SlateOther"
    [ "$status" -ne 0 ]
}

@test "an unrelated path is outside" {
    run herdr_linear::contains "$WORK/outside"
    [ "$status" -ne 0 ]
}

@test "a symlink from outside pointing into the root is outside" {
    ln -s "$WORK/outside" "$WORK/Slate/link-out"
    run herdr_linear::contains "$WORK/Slate/link-out"
    [ "$status" -ne 0 ]
}

@test "a symlink outside the root pointing in resolves to inside" {
    ln -s "$WORK/Slate/web-app" "$WORK/link-in"
    run herdr_linear::contains "$WORK/link-in"
    [ "$status" -eq 0 ]
}

@test "a root that does not resolve makes every path outside" {
    export HERDR_LINEAR_SLATE_ROOT="$WORK/no-such-root"
    run herdr_linear::contains "$WORK/Slate/web-app"
    [ "$status" -ne 0 ]
}

@test "an empty path argument is outside" {
    run herdr_linear::contains ""
    [ "$status" -ne 0 ]
}
