#!/usr/bin/env bats

load setup_common

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

# A plain checkout is its own project, so the repo reader answers -- and a
# directory that is no checkout at all answers with itself rather than with the
# configured root, which is a boundary and not a project.
@test "a directory under no worktrees directory is answered by the repo reader" {
    git -C "$WORK/root/web-app" init -q -b main
    run herdr_linear::worktree_project "$WORK/root/web-app"
    [ "$status" -eq 0 ]
    [ "$output" = "$WORK/root/web-app" ]

    run herdr_linear::worktree_project "$WORK/outside"
    [ "$status" -eq 0 ]
    [ "$output" = "$WORK/outside" ]
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

# The configured root is the containment boundary and nothing else. A worktree
# under it belongs to its OWN project, and the same fixture proves both halves:
# the project reader derives, the signal still answers from the root.
@test "the configured root does not override a worktree's own project" {
    mkdir -p "$WORK/root/alpha/worktrees/drawer"
    run herdr_linear::worktree_project "$WORK/root/alpha/worktrees/drawer"
    [ "$status" -eq 0 ]
    [ "$output" = "$WORK/root/alpha" ]
    run herdr_linear::path_signal "$WORK/root/alpha/worktrees/drawer"
    [ "$output" = "inside" ]
}

# What the project reader answers is a directory; what the repo reader answers
# has to be a REPOSITORY, because `git -C` is handed it. The configured root
# here is a plain directory, exactly as ~/projects is on a real machine.
@test "the repo reader answers a repository, not the configured root" {
    [ "$(git -C "$WORK/root" rev-parse --git-dir 2>/dev/null || printf 'none')" = "none" ]
    mkdir -p "$WORK/root/alpha"
    git -C "$WORK/root/alpha" init -q -b main
    git -C "$WORK/root/alpha" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
    git -C "$WORK/root/alpha" worktree add -q -b f/x "$WORK/root/alpha/worktrees/drawer" >/dev/null 2>&1
    run herdr_linear::worktree_repo "$WORK/root/alpha/worktrees/drawer"
    [ "$status" -eq 0 ]
    [ "$output" = "$WORK/root/alpha" ]
    run git -C "$output" rev-parse --git-dir
    [ "$status" -eq 0 ]
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

# --------------------------------------------- the ephemeral worktrees root
#
# A second boundary, not a second project root. Worktrees started from a ticket
# live outside every project, so a signal that knows only ~/projects reports
# `outside` for the plugin's own worktrees and both hooks exit 0 in them.
#
# Each root is resolved INDEPENDENTLY. The single-root form returned early on
# an unresolvable root, which would have made every worktrees-root path read
# `outside` on a machine with no ~/projects directory -- the two tests below
# that delete one root are what hold that apart.

wt_setup() {
    mkdir -p "$WORK/wt/acme/ai-canvas-tools/WEB-1-x" "$WORK/wtOther"
    export HERDR_LINEAR_WORKTREES_ROOT="$WORK/wt"
}

# AE7.
@test "a path under the worktrees root is inside" {
    wt_setup
    run herdr_linear::path_signal "$WORK/wt/acme/ai-canvas-tools/WEB-1-x"
    [ "$status" -eq 0 ]
    [ "$output" = "inside" ]
}

@test "the worktrees root itself is inside" {
    wt_setup
    run herdr_linear::path_signal "$WORK/wt"
    [ "$status" -eq 0 ]
    [ "$output" = "inside" ]
}

# AE7. The projects root is gone; the worktrees root must still answer.
@test "a worktrees-root path is inside when the projects root does not exist" {
    wt_setup
    rm -rf "$WORK/root"
    run herdr_linear::path_signal "$WORK/wt/acme/ai-canvas-tools/WEB-1-x"
    [ "$status" -eq 0 ]
    [ "$output" = "inside" ]
}

@test "a projects-root path is inside when the worktrees root does not exist" {
    export HERDR_LINEAR_WORKTREES_ROOT="$WORK/absent-wt"
    run herdr_linear::path_signal "$WORK/root/web-app"
    [ "$status" -eq 0 ]
    [ "$output" = "inside" ]
}

@test "a sibling whose name begins with the worktrees root path is outside" {
    wt_setup
    run herdr_linear::path_signal "$WORK/wtOther"
    [ "$status" -eq 0 ]
    [ "$output" = "outside" ]
}

@test "a symlink under the worktrees root pointing outside it is outside" {
    wt_setup
    ln -s "$WORK/outside" "$WORK/wt/escape"
    run herdr_linear::path_signal "$WORK/wt/escape"
    [ "$status" -eq 0 ]
    [ "$output" = "outside" ]
}

@test "with the seam unset the worktrees root defaults to worktrees under HOME" {
    run --separate-stderr env -u HERDR_LINEAR_WORKTREES_ROOT HOME="$WORK" \
        bash -c ". '$LIB/contain.sh'; herdr_linear::worktrees_root"
    [ "$status" -eq 0 ]
    [ "$output" = "$WORK/worktrees" ]
}

# ------------------------------------------------ the root is usable, or not
#
# R13. The promise that deleting the whole ephemeral tree is safe is a property
# of the CONFIGURATION, not of the default. A root that swallows ~/projects
# turns one `rm -rf` into the loss of every canonical checkout, so the reader
# answers `unusable` and the caller refuses rather than creating anything.

@test "a disjoint worktrees root is usable" {
    wt_setup
    run herdr_linear::worktrees_root_usable
    [ "$status" -eq 0 ]
    [ "$output" = "usable" ]
}

# Set-but-empty falls back to the default, exactly as the projects-root seam
# does. This is asserted rather than guarded against: a refusal branch for an
# empty root would be unreachable through the seam, and an unreachable guard
# reads as protection nobody has.
@test "an empty worktrees seam falls back to the default rather than to nothing" {
    run --separate-stderr env HERDR_LINEAR_WORKTREES_ROOT= HOME="$WORK" \
        bash -c ". '$LIB/contain.sh'; herdr_linear::worktrees_root"
    [ "$status" -eq 0 ]
    [ "$output" = "$WORK/worktrees" ]
}

@test "the filesystem root is not a usable worktrees root" {
    export HERDR_LINEAR_WORKTREES_ROOT="/"
    run herdr_linear::worktrees_root_usable
    [ "$status" -eq 0 ]
    [ "$output" != "usable" ]
}

@test "the home directory is not a usable worktrees root" {
    export HERDR_LINEAR_WORKTREES_ROOT="$WORK/home"
    mkdir -p "$WORK/home"
    run env HOME="$WORK/home" bash -c ". '$LIB/contain.sh'; herdr_linear::worktrees_root_usable"
    [ "$status" -eq 0 ]
    [ "$output" != "usable" ]
}

# AE10.
@test "a worktrees root equal to the projects root is not usable" {
    export HERDR_LINEAR_WORKTREES_ROOT="$WORK/root"
    run herdr_linear::worktrees_root_usable
    [ "$status" -eq 0 ]
    [ "$output" != "usable" ]
    [[ "$output" == *"$WORK/root"* ]]
}

@test "a worktrees root containing the projects root is not usable" {
    export HERDR_LINEAR_WORKTREES_ROOT="$WORK"
    run herdr_linear::worktrees_root_usable
    [ "$status" -eq 0 ]
    [ "$output" != "usable" ]
}

@test "a worktrees root inside the projects root is not usable" {
    mkdir -p "$WORK/root/ephemeral"
    export HERDR_LINEAR_WORKTREES_ROOT="$WORK/root/ephemeral"
    run herdr_linear::worktrees_root_usable
    [ "$status" -eq 0 ]
    [ "$output" != "usable" ]
}

# A root that is not there YET is still a usable configuration -- the plugin
# creates it. Only an overlapping or absurd one is refused.
@test "a worktrees root that does not exist yet is usable" {
    export HERDR_LINEAR_WORKTREES_ROOT="$WORK/not-yet"
    run herdr_linear::worktrees_root_usable
    [ "$status" -eq 0 ]
    [ "$output" = "usable" ]
}

# ------------------------------------------ the project reader under the new root

# R11. A root spelled `.../worktrees` is exactly what the default is, and the
# `*/worktrees/*` case used to cut every path under it at the first `worktrees`
# segment -- answering with the home directory for every ticket worktree.
@test "a worktree under the worktrees root answers the repository it was made from" {
    export HERDR_LINEAR_WORKTREES_ROOT="$WORK/home/worktrees"
    git -C "$WORK/root/web-app" init -q -b main
    git -C "$WORK/root/web-app" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
    mkdir -p "$WORK/home/worktrees/acme/web"
    git -C "$WORK/root/web-app" worktree add -q -b f/x "$WORK/home/worktrees/acme/web/WEB-1-x" >/dev/null 2>&1
    run herdr_linear::worktree_project "$WORK/home/worktrees/acme/web/WEB-1-x"
    [ "$status" -eq 0 ]
    [ "$output" = "$WORK/root/web-app" ]
}

@test "a project's own worktrees directory still answers the project" {
    export HERDR_LINEAR_WORKTREES_ROOT="$WORK/home/worktrees"
    mkdir -p "$WORK/root/alpha/worktrees/drawer"
    run herdr_linear::worktree_project "$WORK/root/alpha/worktrees/drawer"
    [ "$status" -eq 0 ]
    [ "$output" = "$WORK/root/alpha" ]
}
