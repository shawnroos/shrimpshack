#!/usr/bin/env bash
# claude-modes V2 (U5): active-mode reader helpers.
#
# Read-only helpers used by:
#   - /mode:status (U12)
#   - /mode:apply (this unit)
#   - lib/inject-prose.sh (R25 prose injection — though inject-prose.sh
#     embeds its own resolver for hook-context reasons; future refactor
#     candidate)
#
# Resolution chain for "what mode is active right now":
#   1. <repo>/.claude/modes/<branch-slug>.mode  (per-branch state)
#   2. ~/.claude/modes/.last-active-mode         (user-global fallback)
#   3. empty → no mode active ("Claude Mode" / no-modes-active state)
#
# V2 vs V1 changes:
#   - Detached HEAD is NOT an error. It slugifies to `detached-<short-sha>`
#     so per-branch state can still be written.
#   - "no git repo" is NOT an error. read_active_mode_name returns empty +
#     rc=0; callers fall through to the user-global pointer or treat
#     "no active mode" as the Claude Mode state.
#   - read_active_mode_name accepts optional explicit repo_root and
#     branch_slug args so callers that already resolved them don't pay
#     the git cost twice.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/validate-mode-name.sh"

# Read a .mode / .last-active-mode body with edge-only whitespace stripping
# (mirrors Python's str.strip() at the reconcile-symlinks.py read site) and
# return it only if it's a valid mode marker.
#
# sec-005: the old `tr -d '[:space:]'` deleted INTERNAL whitespace too, so
# "delivery x" resolved to "deliveryx" here (canonical resolver!) while
# Python's .strip() kept "delivery x" and rejected it — the canonical
# write-side resolver diverging from the read side. Edge-strip + validate
# closes that. "claude" is accepted as the Claude-Mode sentinel even though
# validate_name rejects it as a mode NAME (same split contract as the other
# read sites). Prints the validated body on stdout; returns 1 if absent or
# invalid.
claude_modes::read_validated_mode_body() {
  local mode_file="$1"
  [ -f "$mode_file" ] || return 1
  local content
  content=$(LC_ALL=C sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' < "$mode_file" 2>/dev/null | head -c 256)
  [ -z "$content" ] && return 1
  if [ "$content" = "claude" ] || claude_modes::validate_name "$content" >/dev/null 2>&1; then
    printf '%s' "$content"
    return 0
  fi
  return 1
}

# claude_modes::current_branch_slug
#
# Outputs the filesystem-safe slug for the current git branch.
# Returns:
#   0 + slug on stdout if inside a git repo (named branch OR detached HEAD)
#   1 + empty stdout if NOT inside a git repo
#
# Detached HEAD: slugifies to `detached-<short-sha>` so /mode:set still
# writes a per-branch state file deterministically. (V1 errored here; V2
# accepts it.)
claude_modes::current_branch_slug() {
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return 1
  fi

  local branch
  # git symbolic-ref --short -q exits non-zero in detached HEAD.
  branch=$(git symbolic-ref --short -q HEAD 2>/dev/null || true)

  if [ -z "$branch" ]; then
    # Detached HEAD case — synthesize from the short SHA.
    local short_sha
    short_sha=$(git rev-parse --short HEAD 2>/dev/null || true)
    if [ -z "$short_sha" ]; then
      # Bare repo with no commits, or some other pathology. Give up.
      return 1
    fi
    branch="detached-${short_sha}"
  fi

  local slug
  if ! slug=$(claude_modes::slugify_branch "$branch"); then
    return 1
  fi

  printf '%s' "$slug"
  return 0
}

# claude_modes::current_git_toplevel
#
# Write-side: returns the working tree's toplevel via `git rev-parse
# --show-toplevel`, empty if cwd isn't inside a git working tree. This is
# the CREATION root — where set-mode / apply-mode / mode-author drop new
# files (the `.claude/modes/` directory itself, branch-pin files, etc.).
#
# Do NOT use this for READING the active mode — the read path needs the
# `current_repo_root` walk + git-tracked gate so non-repo subdirs and
# scratch dirs don't inherit a parent project's pin. See below.
claude_modes::current_git_toplevel() {
  git rev-parse --show-toplevel 2>/dev/null || true
  return 0
}

# claude_modes::current_repo_root
#
# READ-side: returns the absolute path of the nearest ancestor of $PWD that
# contains a `.claude/modes/` directory AND under which $PWD is git-tracked.
# Empty if no such ancestor found before $HOME or the filesystem root.
#
# WHY this is NOT `git rev-parse --show-toplevel`:
#   `--show-toplevel` walks up from cwd until it finds ANY `.git` directory
#   and returns that path. For a non-repo subdir nested under a git project's
#   tree (e.g. a scratch dir at `~/projects/A/scratch/`), git correctly
#   reports the project's toplevel — but the resolver would then read THAT
#   project's per-branch pin and inherit a mode the user never set FOR the
#   scratch dir. The "non-repo subdir of a modes-using project inherits the
#   project's mode" leak was the blocker on shipping 0.3.0.
#
# The fix walks up looking for the `.claude/modes/` DIRECTORY directly. A
# project opts in to mode resolution by having `.claude/modes/` (which any
# project that has ever run `/mode:set` already has — the per-branch pin
# lives in that directory). Walk semantics:
#   - dir = $PWD
#   - while dir is a strict descendant of $HOME and not "/":
#       if `<dir>/.claude/modes/` is a directory: return dir, stop
#       dir = parent(dir)
#   - if we reach $HOME or "/" without a hit: return empty
#
# Crucially we DO NOT examine `$HOME/.claude/modes/` — that's the user-global
# modes dir (where user-installed mode YAMLs live), NOT a project root. It's
# the FALLBACK tier; if no per-branch project root is found the resolver
# falls through to the user-global pointer (`~/.claude/modes/.last-active-mode`),
# which is handled in read_active_mode_name, not here.
#
# Behavior across location classes (verified 2026-05-25 repro):
#   - cwd == project root with `.claude/modes/`        → returns project root
#   - cwd is descendant of marked project              → returns project root
#   - cwd is non-repo subdir of UNMARKED tree           → returns empty (the fix)
#   - cwd is worktree of marked project, foreign branch → walks up, but the
#       branch-pin file won't match the worktree's branch, so the caller
#       falls through to global (correct)
#   - nested marked project inside marked parent       → returns nested
#       (stop-at-first; "more specific wins")
#   - cwd at or above $HOME                            → returns empty
#       (defers to user-global fallback)
#
# Always returns 0 — caller distinguishes by empty vs non-empty output.
claude_modes::current_repo_root() {
  # Resolve $HOME and cwd to canonical absolute paths so the boundary check
  # is stable across symlinks (e.g. /tmp → /private/tmp on macOS).
  local home_canon cwd dir
  home_canon=$(cd "$HOME" && pwd -P 2>/dev/null) || home_canon="$HOME"
  cwd=$(pwd -P 2>/dev/null) || cwd="$PWD"
  dir="$cwd"

  # Walk up. We stop BEFORE testing $HOME itself (see "WHY" above — $HOME's
  # .claude/modes is the user-global modes dir, not a project root).
  while [ -n "$dir" ] && [ "$dir" != "/" ] && [ "$dir" != "$home_canon" ]; do
    if [ -d "${dir}/.claude/modes" ]; then
      # Found the candidate project root. Apply the SECOND gate: cwd must
      # be git-tracked in this project's working tree. This is what
      # distinguishes "I'm in src/ doing real work on the project"
      # (tracked → mode applies) from "I'm in scratch/ which happens to
      # live under the project's tree" (untracked → no mode). The
      # `.claude/modes/` dir alone isn't enough — every modes-using
      # project has it, so without this gate the leak hits every random
      # subdir of every modes-using project.
      #
      # Implementation notes:
      #   - cwd == project root itself: always qualifies. `ls-files` on
      #     the bare toplevel can be ambiguous (no relative path); short-
      #     circuit it. The user is literally AT the project root.
      #   - cwd is a descendant: compute the relative path and ask git
      #     whether ANY tracked file exists under it via `ls-files`. We
      #     do NOT use `--error-unmatch`: that requires an exact-path
      #     match, but the path may be a directory (no tracked file at
      #     that exact path even when files BELOW it are tracked). The
      #     non-empty stdout of `ls-files <relpath>` is the right test.
      #   - `git -C <dir>` runs from a specific dir; we need it because
      #     the ls-files invocation must use the candidate project's
      #     working tree, not whatever git context cwd may otherwise be
      #     in.
      if [ "$cwd" = "$dir" ]; then
        printf '%s' "$dir"
        return 0
      fi
      local relpath tracked
      relpath="${cwd#${dir}/}"
      # If relpath is unchanged (no prefix match), something's wrong with
      # our walk; bail to "not in project".
      if [ "$relpath" = "$cwd" ]; then
        return 0
      fi
      tracked=$(git -C "$dir" ls-files -- "$relpath" 2>/dev/null | head -1)
      if [ -n "$tracked" ]; then
        printf '%s' "$dir"
      fi
      # Empty tracked → walk-up found a marker but cwd isn't tracked in it.
      # Return empty (no per-branch project root); caller falls through
      # to the user-global pointer. We do NOT continue walking up looking
      # for an outer marker — the inner marker "claims" this part of the
      # tree, and stopping here matches the user's mental model
      # ("I'm under THIS project but not in a tracked dir of it").
      return 0
    fi
    # parent(dir). `dirname /` is "/", which would loop forever; we already
    # break out of the loop on dir == "/" above.
    dir=$(dirname "$dir")
  done
  return 0
}

# claude_modes::read_active_mode_name [repo_root] [branch_slug]
#
# Reads the active mode name following the V2 resolution chain.
# Returns:
#   0 + mode name on stdout, OR
#   0 + empty stdout (= no mode active, "Claude Mode" / no-modes-active)
#
# Never errors — "no git repo" and "no per-branch file" are both expected
# states that resolve to the user-global fallback or empty.
#
# Both args are optional. If omitted, they're resolved from the cwd via
# `git rev-parse`. Callers that already know them can pass them through
# to avoid the git subprocess cost.
claude_modes::read_active_mode_name() {
  local repo_root="${1:-}"
  local branch_slug="${2:-}"

  # Per-branch lookup (only meaningful inside a git working tree).
  if [ -z "$repo_root" ]; then
    repo_root=$(claude_modes::current_repo_root)
  fi
  if [ -z "$branch_slug" ] && [ -n "$repo_root" ]; then
    # current_branch_slug uses cwd-relative git; only call if cwd is
    # inside the resolved repo_root. For simplicity here, just call it —
    # we accept that callers who pass a wrong repo_root + empty slug get
    # cwd-derived slug.
    branch_slug=$(claude_modes::current_branch_slug 2>/dev/null || true)
  fi

  if [ -n "$repo_root" ] && [ -n "$branch_slug" ]; then
    local content
    if content=$(claude_modes::read_validated_mode_body "${repo_root}/.claude/modes/${branch_slug}.mode"); then
      printf '%s' "$content"
      return 0
    fi
  fi

  # User-global fallback.
  local content
  if content=$(claude_modes::read_validated_mode_body "${HOME}/.claude/modes/.last-active-mode"); then
    printf '%s' "$content"
    return 0
  fi

  # No active mode anywhere — return empty stdout, rc=0.
  return 0
}

# Allow direct invocation for debugging:
#   bash lib/active-mode.sh slug
#   bash lib/active-mode.sh repo-root
#   bash lib/active-mode.sh name [repo_root] [branch_slug]
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-name}" in
    slug)        claude_modes::current_branch_slug ;;
    repo-root)   claude_modes::current_repo_root ;;
    name)        claude_modes::read_active_mode_name "${2:-}" "${3:-}" ;;
    *)
      echo "Usage: $0 {slug | repo-root | name [repo_root] [branch_slug]}" >&2
      exit 2
      ;;
  esac
fi
