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

# claude_modes::current_repo_root
#
# Outputs the absolute repo root path if inside a git repo; empty otherwise.
# Always returns 0 — caller distinguishes by empty vs non-empty output.
claude_modes::current_repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || true
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
