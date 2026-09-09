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

@test "a symlink to a FILE outside the root is outside" {
    mkdir -p "$WORK/outside"; : > "$WORK/outside/f"
    ln -s "$WORK/outside/f" "$WORK/Slate/link-to-file"
    run herdr_linear::contains "$WORK/Slate/link-to-file"
    [ "$status" -ne 0 ]
}

@test "a dangling symlink inside the root is outside" {
    ln -s "$WORK/nowhere" "$WORK/Slate/dangling"
    run herdr_linear::contains "$WORK/Slate/dangling"
    [ "$status" -ne 0 ]
}

@test "a hardlink inside the root to a file outside it is outside" {
    mkdir -p "$WORK/outside"; : > "$WORK/outside/key"
    ln "$WORK/outside/key" "$WORK/Slate/hardlink"
    run herdr_linear::contains "$WORK/Slate/hardlink"
    [ "$status" -ne 0 ]
}

@test "a regular file inside the root is outside -- only directories are contained" {
    : > "$WORK/Slate/plain-file"
    run herdr_linear::contains "$WORK/Slate/plain-file"
    [ "$status" -ne 0 ]
}

# ------------------------------------------------------------- scope readers
#
# The four jobs one root used to do are separate readers now, and a reader
# answers instead of refusing: every test below asserts the value reported, not
# an exit status, because a non-zero exit cannot tell "reported outside" from
# "crashed".

@test "the path signal reports inside for a path under the root, and exits 0" {
    run herdr_linear::path_signal "$WORK/Slate/web-app"
    [ "$status" -eq 0 ]
    [ "$output" = "inside" ]
}

# AE7.
@test "the path signal reports outside for a path under no known root, and exits 0" {
    run herdr_linear::path_signal "$WORK/outside"
    [ "$status" -eq 0 ]
    [ "$output" = "outside" ]
}

@test "a worktree resolves its project from the parent of its worktrees directory" {
    unset HERDR_LINEAR_SLATE_ROOT
    mkdir -p "$WORK/projects/alpha/worktrees/drawer"
    run herdr_linear::worktree_project "$WORK/projects/alpha/worktrees/drawer"
    [ "$status" -eq 0 ]
    [ "$output" = "$WORK/projects/alpha" ]
    [ "$(basename "$output")" = "alpha" ]
}

# Worktrees BESIDE the projects rather than under one: the parent of the
# worktrees directory is not a project, and the path signal says so rather than
# erroring.
@test "worktrees beside the projects yield an outside path signal, not an error" {
    unset HERDR_LINEAR_SLATE_ROOT
    mkdir -p "$WORK/worktrees/drawer"
    run herdr_linear::path_signal "$WORK/worktrees/drawer"
    [ "$status" -eq 0 ]
    [ "$output" = "outside" ]
}

@test "a directory under no worktrees directory falls back to the configured root" {
    run herdr_linear::worktree_project "$WORK/outside"
    [ "$status" -eq 0 ]
    [ "$output" = "$WORK/Slate" ]
}

@test "the repo reader returns the main checkout a linked worktree belongs to" {
    unset HERDR_LINEAR_SLATE_ROOT
    git -C "$WORK/Slate" init -q -b main
    git -C "$WORK/Slate" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
    git -C "$WORK/Slate" worktree add -q -b f/x "$WORK/Slate/worktrees/drawer" >/dev/null 2>&1
    run herdr_linear::worktree_repo "$WORK/Slate/worktrees/drawer"
    [ "$status" -eq 0 ]
    [ "$output" = "$WORK/Slate" ]
}

# The bare form of --git-common-dir prints `.git` at a main checkout, which is
# what every fixture is; --path-format=absolute is what makes the answer a
# directory the caller can hand to `git -C`.
@test "the repo reader returns the checkout itself at a main checkout" {
    unset HERDR_LINEAR_SLATE_ROOT
    git -C "$WORK/Slate" init -q -b main
    git -C "$WORK/Slate" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
    run herdr_linear::worktree_repo "$WORK/Slate"
    [ "$status" -eq 0 ]
    [ "$output" = "$WORK/Slate" ]
}

@test "the configured root wins over derivation for the project and repo readers" {
    mkdir -p "$WORK/projects/alpha/worktrees/drawer"
    run herdr_linear::worktree_project "$WORK/projects/alpha/worktrees/drawer"
    [ "$output" = "$WORK/Slate" ]
    run herdr_linear::worktree_repo "$WORK/projects/alpha/worktrees/drawer"
    [ "$output" = "$WORK/Slate" ]
}
