#!/usr/bin/env bash
# claude-modes V2: shared mode/branch-name validation library.
#
# Used by:
#   - /mode:set (guards direct user input bypassing the authoring flow)
#   - mode-author skill (guards conversational input)
#   - lib/set-mode.sh (slugifies git branch names — same rules)
#   - lib/write-mode-yaml.sh (validates name before writing tier-3 YAML)
#
# Single source of truth for what makes a valid mode name. Carry-forward from
# V1 (git tag v0.1.0-experiment) with two V2-specific additions:
#   - Reserved tokens now include `claude`, `_global`, `_repo`
#   - `_global` and `_repo` are cascade-tier baseline filenames (R29, R30)
#   - `claude` is reserved because per R2/F4, "Claude Mode" is the no-modes-active
#     state, not a settable named mode

# Reserved tokens: command verbs that would create ambiguous slash commands,
# plus cascade-tier baseline filenames, plus the no-modes-active alias.
# Example: a mode named "set" would make `/mode:set set` parse ambiguously.
# Example: a mode YAML named "_global.yaml" would collide with the tier-2
# baseline file.
set -uo pipefail

CLAUDE_MODES_RESERVED_TOKENS="default none set status clear apply registry adopt setup list help promote rebuild coverage claude _global _repo"

# claude_modes::validate_name <name>
#
# Validates a mode name (as supplied by the user). Returns 0 if valid,
# non-zero on rejection. Prints a clear error to stderr on rejection
# naming the specific rule violated.
#
# Rules (in evaluation order):
#   1. Non-empty
#   2. Length ≤ 64 characters
#   3. Path-traversal-flavored names rejected before allowlist (clearer error)
#   4. Allowlist: [a-zA-Z0-9_-] only (LC_ALL=C — byte-oriented)
#   5. Does not start or end with - or _ (cosmetic — prevents weird filenames)
#   6. Not in reserved-token list
claude_modes::validate_name() {
  local name="${1:-}"

  if [ -z "$name" ]; then
    echo "validate-mode-name: name is empty" >&2
    return 1
  fi

  if [ "${#name}" -gt 64 ]; then
    echo "validate-mode-name: name '$name' exceeds 64 character limit" >&2
    return 1
  fi

  # Path-traversal-flavored names get the clearest rejection message,
  # so we check them BEFORE the generic allowlist check.
  case "$name" in
    .|..|*..*)
      echo "validate-mode-name: name '$name' is path-traversal-flavored (., .., or contains ..)" >&2
      return 1
      ;;
  esac

  # Allowlist check — anything outside [A-Za-z0-9_-] is rejected.
  # Using LC_ALL=C so [^...] is byte-oriented and rejects UTF-8 lookalikes.
  if LC_ALL=C printf '%s' "$name" | grep -qE '[^A-Za-z0-9_-]'; then
    echo "validate-mode-name: name '$name' contains forbidden characters (allowed: A-Z a-z 0-9 _ -)" >&2
    return 1
  fi

  # Cosmetic: leading/trailing - or _ produce weird filenames.
  # NOTE: `_global` and `_repo` start with underscore but are explicitly
  # reserved below, so they get caught by the reserved-token check before
  # this rule rejects them. Other underscore-leading names are rejected here.
  case "$name" in
    [-_]*|*[-_])
      echo "validate-mode-name: name '$name' may not start or end with '-' or '_'" >&2
      return 1
      ;;
  esac

  # Reserved tokens.
  for reserved in $CLAUDE_MODES_RESERVED_TOKENS; do
    if [ "$name" = "$reserved" ]; then
      echo "validate-mode-name: name '$name' collides with reserved token (reserved: $CLAUDE_MODES_RESERVED_TOKENS)" >&2
      return 1
    fi
  done

  return 0
}

# claude_modes::slugify_branch <branch>
#
# Converts a git branch name to a filesystem-safe slug suitable for use as
# a .mode filename component (tier-6 per-branch pointer). Applies the same
# allowlist as validate_name.
#
# Returns 0 + slug on stdout on success.
# Returns non-zero + nothing on stdout if the resulting slug would be
# invalid (empty after normalization, normalizes to . or .., or contains
# .. sequences after slugification).
#
# Detached HEAD handling: callers should pass the literal short SHA
# (e.g., `detached-<short-sha>`) rather than "HEAD"; this function does NOT
# special-case "HEAD" and will slugify it like any other branch name.
claude_modes::slugify_branch() {
  local branch="${1:-}"

  if [ -z "$branch" ]; then
    return 1
  fi

  # Replace anything outside [A-Za-z0-9_-] with -.
  # Using LC_ALL=C tr keeps this byte-oriented (so UTF-8 multi-byte sequences
  # get fully replaced, not partially-mangled).
  local slug
  slug=$(LC_ALL=C printf '%s' "$branch" | LC_ALL=C tr -c 'A-Za-z0-9_-' '-' )

  # Collapse runs of - (e.g., "feature//foo" → "feature--foo" → "feature-foo").
  slug=$(printf '%s' "$slug" | sed -E 's/-+/-/g')

  # Strip leading/trailing -.
  slug=$(printf '%s' "$slug" | sed -E 's/^-+//; s/-+$//')

  # Post-normalization checks: must be non-empty, not . or .., no ..
  if [ -z "$slug" ]; then
    return 1
  fi

  case "$slug" in
    .|..|*..*)
      return 1
      ;;
  esac

  printf '%s' "$slug"
  return 0
}

# Allow this file to be sourced (preferred) OR executed directly for
# scripting use:  bash lib/validate-mode-name.sh check <name>
#                 bash lib/validate-mode-name.sh slugify-branch <branch>
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
    check)
      claude_modes::validate_name "${2:-}"
      ;;
    slugify-branch)
      claude_modes::slugify_branch "${2:-}"
      ;;
    *)
      echo "Usage: $0 {check <name> | slugify-branch <branch>}" >&2
      exit 2
      ;;
  esac
fi
