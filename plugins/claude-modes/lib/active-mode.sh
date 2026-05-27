#!/usr/bin/env bash
# claude-modes V2 (U5): active-mode reader helpers.
#
# THE canonical active-mode resolver + validator. Sourced by:
#   - /mode:status        (lib/status.sh)            — read_active_mode_name
#   - /mode:apply         (lib/apply-mode.sh)         — read_active_mode_name
#   - UserPromptSubmit prose hook (lib/inject-prose.sh) — read_active_mode_name
#   - the statusline      (scripts/statusline.sh)     — read_per_branch_mode_name
# All four route through the SAME gated chain (current_repo_root walk-up +
# git-tracked-cwd check + read_validated_mode_body). They differ ONLY in the
# user-global fallback: read_active_mode_name chains per-branch → ~/.claude/
# modes/.last-active-mode, while read_per_branch_mode_name returns empty if
# this repo+branch has no pin. The statusline uses the per-branch-only form
# because it's a per-repo display surface and the global pointer is shared-
# mutable across concurrent sessions (see feedback_mode_set_leaks_via_
# global_pointer_to_other_sessions): a statusline that consulted it would
# flicker to reflect another tab's /mode:set in a repo with no pin of its own.
#
# No hand-mirrored Bash copies of the resolver or validator remain. (The
# repo-root walk lives in lib/repo-root.sh, sourced below.) The ONE unavoidable
# mirror is the Python validator/resolver in reconcile-symlinks.py — a
# SessionStart hook in Python can't source Bash; the Bash↔Python pair is pinned
# equivalent by active-mode-resolver-equivalence.test.sh +
# mode-body-read-equivalence.test.sh.
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
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/repo-root.sh"

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

# claude_modes::read_per_branch_mode_name [repo_root] [branch_slug]
#
# PER-BRANCH ONLY — does NOT consult the user-global ~/.claude/modes/
# .last-active-mode fallback. Returns:
#   0 + mode name on stdout, OR
#   0 + empty stdout (= no per-branch pin in this repo/branch)
#
# Use this when the caller is a per-repo display surface (e.g. the
# statusline) that must NOT inherit a sibling concurrent session's
# /mode:set via the global pointer. See feedback_mode_set_leaks_via_global
# _pointer_to_other_sessions: the global pointer is a shared mutable
# variable across every concurrent claude-modes session, so a display
# surface that reflects "this repo + this branch's mode" must avoid it
# or it'll flicker to another tab's state. Used by scripts/statusline.sh.
#
# Both args are optional. If omitted, they're resolved from cwd via
# the canonical current_repo_root + current_branch_slug helpers.
claude_modes::read_per_branch_mode_name() {
  local repo_root="${1:-}"
  local branch_slug="${2:-}"

  if [ -z "$repo_root" ]; then
    repo_root=$(claude_modes::current_repo_root)
  fi
  [ -z "$repo_root" ] && return 0

  if [ -z "$branch_slug" ]; then
    branch_slug=$(claude_modes::current_branch_slug 2>/dev/null || true)
  fi
  [ -z "$branch_slug" ] && return 0

  local content
  if content=$(claude_modes::read_validated_mode_body "${repo_root}/.claude/modes/${branch_slug}.mode"); then
    printf '%s' "$content"
    return 0
  fi
  return 0
}

# claude_modes::read_active_mode_name [repo_root] [branch_slug]
#
# Reads the active mode name following the V2 resolution chain:
#   1. Per-branch state file (claude_modes::read_per_branch_mode_name)
#   2. User-global ~/.claude/modes/.last-active-mode fallback
# Returns:
#   0 + mode name on stdout, OR
#   0 + empty stdout (= no mode active, "Claude Mode" / no-modes-active)
#
# Never errors — "no git repo" and "no per-branch file" are both expected
# states that resolve to the user-global fallback or empty.
#
# Both args are optional. Callers that already know them can pass through
# to skip the git resolution cost.
#
# NOTE: a per-repo display surface (statusline, etc.) should call
# read_per_branch_mode_name instead — see its docstring for why.
claude_modes::read_active_mode_name() {
  local repo_root="${1:-}"
  local branch_slug="${2:-}"

  # Try per-branch first (delegates to the same gated chain).
  local content
  content=$(claude_modes::read_per_branch_mode_name "$repo_root" "$branch_slug")
  if [ -n "$content" ]; then
    printf '%s' "$content"
    return 0
  fi

  # User-global fallback.
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
