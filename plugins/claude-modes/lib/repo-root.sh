#!/usr/bin/env bash
# claude-modes V2: canonical repo-root resolvers.
#
# THE single source of truth for "which project tree applies to cwd, and
# where do I create project config." Every read-path resolver in the plugin
# (active-mode.sh, inject-prose.sh, status.sh) sources THIS file rather than
# carrying a hand-mirrored copy. Before this lib existed the gate logic was
# copied into 3+ Bash sites; b22fdb9 fixed one, e0099fc a second, and a
# code review found status.sh still leaking — the classic "fix the cited
# instance, miss the class" failure. Centralizing here makes the gate live
# in exactly one place (plus one unavoidable Python mirror in
# reconcile-symlinks.py, pinned by mode-body-read-equivalence).
#
# This file is DELIBERATELY dependency-free: it sources nothing. The two
# functions use only `git`, `pwd`, `dirname`, and parameter expansion. That
# is what makes it cheap to source on the UserPromptSubmit hot path
# (measured ~1.6ms/call over bare-bash baseline — vs ~5ms for the full
# active-mode.sh chain, which transitively sources validate-mode-name.sh
# that the resolvers don't use). No inline copy is justified; source this.

set -uo pipefail

# claude_modes::current_git_toplevel
#
# WRITE-side: the working tree's toplevel via `git rev-parse --show-toplevel`,
# empty if cwd isn't inside a git working tree. This is the CREATION root —
# where set-mode / apply-mode / mode-author drop new files (the
# `.claude/modes/` directory itself, branch-pin files, etc.).
#
# Do NOT use this for READING the active mode — the read path needs the
# `current_repo_root` walk + git-tracked gate so non-repo subdirs and scratch
# dirs don't inherit a parent project's pin. See below.
claude_modes::current_git_toplevel() {
  git rev-parse --show-toplevel 2>/dev/null || true
  return 0
}

# claude_modes::current_repo_root
#
# READ-side: the absolute path of the nearest ancestor of $PWD that contains
# a `.claude/modes/` directory AND under which $PWD is git-tracked. Empty if
# no such ancestor is found before $HOME or the filesystem root.
#
# WHY this is NOT `git rev-parse --show-toplevel`:
#   `--show-toplevel` returns ANY enclosing git repo's toplevel. For a
#   non-repo scratch dir nested under a git project's tree (e.g.
#   `~/projects/A/scratch/`), git reports the project's toplevel — and the
#   resolver would then read THAT project's per-branch pin and inherit a mode
#   the user never set for the scratch dir. That cross-project leak was the
#   0.3.0 ship blocker.
#
# The fix walks up looking for the `.claude/modes/` DIRECTORY (the opt-in
# marker — every project that has run `/mode:set` has it) AND requires cwd to
# be git-tracked under it (distinguishes "real work in src/" from "a scratch
# dir that merely lives under the project").
#
# Behavior across location classes:
#   - cwd == project root with `.claude/modes/`     → returns project root
#   - cwd is tracked descendant of marked project   → returns project root
#   - cwd is UNTRACKED subdir of marked project       → empty (the gate)
#   - cwd is worktree of marked project (untracked)  → empty (falls through)
#   - nested marked project inside marked parent     → returns nested (stop-at-first)
#   - cwd at or above $HOME                          → empty (defers to global)
#
# Always returns 0 — caller distinguishes by empty vs non-empty stdout.
claude_modes::current_repo_root() {
  # Canonicalize $HOME and cwd so the boundary check is symlink-stable
  # (e.g. /tmp → /private/tmp on macOS).
  local home_canon cwd dir relpath tracked
  home_canon=$(cd "$HOME" && pwd -P 2>/dev/null) || home_canon="$HOME"
  cwd=$(pwd -P 2>/dev/null) || cwd="$PWD"
  dir="$cwd"

  # Walk up. Stop BEFORE testing $HOME itself — $HOME/.claude/modes is the
  # user-global modes dir, not a project root; the global fallback is handled
  # by the caller (read_active_mode_name), not here.
  while [ -n "$dir" ] && [ "$dir" != "/" ] && [ "$dir" != "$home_canon" ]; do
    if [ -d "${dir}/.claude/modes" ]; then
      # cwd == project root always qualifies (ls-files on a bare toplevel
      # has no relative path to test).
      if [ "$cwd" = "$dir" ]; then
        printf '%s' "$dir"
        return 0
      fi
      relpath="${cwd#${dir}/}"
      # No prefix match → walk is inconsistent; treat as "not in project".
      if [ "$relpath" = "$cwd" ]; then
        return 0
      fi
      # Non-empty ls-files stdout = some tracked file lives under cwd.
      # (NOT --error-unmatch: relpath may be a dir with tracked children but
      # no tracked file at the exact path.)
      tracked=$(git -C "$dir" ls-files -- "$relpath" 2>/dev/null | head -1)
      if [ -n "$tracked" ]; then
        printf '%s' "$dir"
      fi
      # Marker found but cwd untracked → inner marker claims this subtree; do
      # not walk further. Caller falls through to the user-global pointer.
      return 0
    fi
    dir=$(dirname "$dir")
  done
  return 0
}
