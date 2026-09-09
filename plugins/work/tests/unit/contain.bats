#!/usr/bin/env bats
# Containment is the plugin's outermost boundary: every entry point calls it
# before doing anything. A prefix match would admit a sibling directory and an
# unresolved symlink would admit whatever it points at, so both are tested.

bats_require_minimum_version 1.5.0

setup() {
    LIB="$(cd "$BATS_TEST_DIRNAME/../../lib" && pwd)"
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/hl-contain.XXXXXX")"
    WORK="$(cd "$WORK" && pwd -P)"
    mkdir -p "$WORK/root/web-app" "$WORK/rootOther" "$WORK/outside"
    export HERDR_LINEAR_PROJECTS_ROOT="$WORK/root"
    # The machine running this suite may still carry the deprecated name in its
    # own environment. Left set, every test below that unsets the new name would
    # silently read the developer's real projects root instead of deriving.
    unset HERDR_LINEAR_SLATE_ROOT
    . "$LIB/contain.sh"
}

teardown() {
    [ -n "${WORK:-}" ] && rm -rf "$WORK"
    return 0
}

@test "a path under the root is inside" {
    run herdr_linear::contains "$WORK/root/web-app"
    [ "$status" -eq 0 ]
}

@test "the root itself is inside" {
    run herdr_linear::contains "$WORK/root"
    [ "$status" -eq 0 ]
}

@test "a sibling whose name begins with the root path is outside" {
    run herdr_linear::contains "$WORK/rootOther"
    [ "$status" -ne 0 ]
}

@test "an unrelated path is outside" {
    run herdr_linear::contains "$WORK/outside"
    [ "$status" -ne 0 ]
}

@test "a symlink from outside pointing into the root is outside" {
    ln -s "$WORK/outside" "$WORK/root/link-out"
    run herdr_linear::contains "$WORK/root/link-out"
    [ "$status" -ne 0 ]
}

@test "a symlink outside the root pointing in resolves to inside" {
    ln -s "$WORK/root/web-app" "$WORK/link-in"
    run herdr_linear::contains "$WORK/link-in"
    [ "$status" -eq 0 ]
}

@test "a root that does not resolve makes every path outside" {
    export HERDR_LINEAR_PROJECTS_ROOT="$WORK/no-such-root"
    run herdr_linear::contains "$WORK/root/web-app"
    [ "$status" -ne 0 ]
}

@test "an empty path argument is outside" {
    run herdr_linear::contains ""
    [ "$status" -ne 0 ]
}

@test "a symlink to a FILE outside the root is outside" {
    mkdir -p "$WORK/outside"; : > "$WORK/outside/f"
    ln -s "$WORK/outside/f" "$WORK/root/link-to-file"
    run herdr_linear::contains "$WORK/root/link-to-file"
    [ "$status" -ne 0 ]
}

@test "a dangling symlink inside the root is outside" {
    ln -s "$WORK/nowhere" "$WORK/root/dangling"
    run herdr_linear::contains "$WORK/root/dangling"
    [ "$status" -ne 0 ]
}

@test "a hardlink inside the root to a file outside it is outside" {
    mkdir -p "$WORK/outside"; : > "$WORK/outside/key"
    ln "$WORK/outside/key" "$WORK/root/hardlink"
    run herdr_linear::contains "$WORK/root/hardlink"
    [ "$status" -ne 0 ]
}

@test "a regular file inside the root is outside -- only directories are contained" {
    : > "$WORK/root/plain-file"
    run herdr_linear::contains "$WORK/root/plain-file"
    [ "$status" -ne 0 ]
}

# ------------------------------------------------------------- scope readers
#
# The four jobs one root used to do are separate readers now, and a reader
# answers instead of refusing: every test below asserts the value reported, not
# an exit status, because a non-zero exit cannot tell "reported outside" from
# "crashed".

@test "the path signal reports inside for a path under the root, and exits 0" {
    run herdr_linear::path_signal "$WORK/root/web-app"
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
    unset HERDR_LINEAR_PROJECTS_ROOT
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
    unset HERDR_LINEAR_PROJECTS_ROOT
    mkdir -p "$WORK/worktrees/drawer"
    run herdr_linear::path_signal "$WORK/worktrees/drawer"
    [ "$status" -eq 0 ]
    [ "$output" = "outside" ]
}

@test "a directory under no worktrees directory falls back to the configured root" {
    run herdr_linear::worktree_project "$WORK/outside"
    [ "$status" -eq 0 ]
    [ "$output" = "$WORK/root" ]
}

@test "the repo reader returns the main checkout a linked worktree belongs to" {
    unset HERDR_LINEAR_PROJECTS_ROOT
    git -C "$WORK/root" init -q -b main
    git -C "$WORK/root" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
    git -C "$WORK/root" worktree add -q -b f/x "$WORK/root/worktrees/drawer" >/dev/null 2>&1
    run herdr_linear::worktree_repo "$WORK/root/worktrees/drawer"
    [ "$status" -eq 0 ]
    [ "$output" = "$WORK/root" ]
}

# The bare form of --git-common-dir prints `.git` at a main checkout, which is
# what every fixture is; --path-format=absolute is what makes the answer a
# directory the caller can hand to `git -C`.
@test "the repo reader returns the checkout itself at a main checkout" {
    unset HERDR_LINEAR_PROJECTS_ROOT
    git -C "$WORK/root" init -q -b main
    git -C "$WORK/root" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
    run herdr_linear::worktree_repo "$WORK/root"
    [ "$status" -eq 0 ]
    [ "$output" = "$WORK/root" ]
}

@test "the configured root wins over derivation for the project and repo readers" {
    mkdir -p "$WORK/projects/alpha/worktrees/drawer"
    run herdr_linear::worktree_project "$WORK/projects/alpha/worktrees/drawer"
    [ "$output" = "$WORK/root" ]
    run herdr_linear::worktree_repo "$WORK/projects/alpha/worktrees/drawer"
    [ "$output" = "$WORK/root" ]
}

# ------------------------------------------------- the root seam and its name
#
# The variable was renamed and the old spelling kept as a fallback, because the
# new default resolves to the same directory the old name was pointed at: a
# clean rename would keep working by accident and leave the stale setting
# unnoticed. These run the seam in a FRESH shell each time -- the warning is
# emitted when the file is sourced, and setup() has already sourced it here.
seam() {
    run --separate-stderr env -u HERDR_LINEAR_PROJECTS_ROOT -u HERDR_LINEAR_SLATE_ROOT \
        "$@" bash -c ". '$LIB/contain.sh'; herdr_linear::projects_root"
}

@test "the deprecated variable name is still honoured as the root" {
    seam HERDR_LINEAR_SLATE_ROOT="$WORK/root"
    [ "$status" -eq 0 ]
    [ "$output" = "$WORK/root" ]
}

@test "the new variable name wins when both are set" {
    seam HERDR_LINEAR_PROJECTS_ROOT="$WORK/root" HERDR_LINEAR_SLATE_ROOT="$WORK/outside"
    [ "$status" -eq 0 ]
    [ "$output" = "$WORK/root" ]
}

@test "the deprecated name warns once, naming both spellings and where to change it" {
    seam HERDR_LINEAR_SLATE_ROOT="$WORK/root"
    [ "$(printf '%s\n' "$stderr" | grep -c .)" -eq 1 ]
    [[ "$stderr" == *"HERDR_LINEAR_SLATE_ROOT"* ]]
    [[ "$stderr" == *"HERDR_LINEAR_PROJECTS_ROOT"* ]]
    [[ "$stderr" == *"settings.json"* ]]
    # The value is being READ here, so the line must say rename, not delete.
    [[ "$stderr" == *"rename it to"* ]]
    [[ "$stderr" != *"ignored"* ]]
}

@test "the new name alone says nothing" {
    seam HERDR_LINEAR_PROJECTS_ROOT="$WORK/root"
    [ -z "$stderr" ]
}

# The deprecation exists to get the stale setting out of the configuration, and
# someone holding both names has not finished. This test replaced one that
# asserted silence here: warning only when the fallback is READ was a narrower
# rule than the deprecation is for.
@test "holding both names warns that the old one is ignored, not that it needs renaming" {
    seam HERDR_LINEAR_PROJECTS_ROOT="$WORK/root" HERDR_LINEAR_SLATE_ROOT="$WORK/outside"
    [ "$(printf '%s\n' "$stderr" | grep -c .)" -eq 1 ]
    [[ "$stderr" == *"HERDR_LINEAR_SLATE_ROOT"* ]]
    [[ "$stderr" == *"ignored"* ]]
    [[ "$stderr" == *"delete"* ]]
    # Renaming is the wrong instruction here; the new name is already set.
    [[ "$stderr" != *"rename it to"* ]]
}

@test "with neither name set the root defaults to projects under HOME" {
    seam HOME="$WORK"
    [ "$status" -eq 0 ]
    [ "$output" = "$WORK/projects" ]
    [ -z "$stderr" ]
}
