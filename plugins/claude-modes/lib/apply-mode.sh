#!/usr/bin/env bash
# claude-modes V2 (U5): /mode:apply — re-apply current branch's active mode.
#
# Usage: bash lib/apply-mode.sh
#
# Looks up the current per-branch active mode via active-mode.sh and
# re-runs the same orchestration as /mode:set (cascade_compile +
# symlink_rebuild) without changing which mode is active. Useful when:
#   - settings.local.json has drifted from the cascade's expected output
#     (e.g., manual edit, partial write, restore from backup)
#   - user wants to force a refresh after editing the active mode YAML
#
# Idempotency contract is the same as /mode:set: cascade_compile and
# symlink_rebuild are deterministic from inputs, so re-running converges.
#
# R26 crash-safety: shares the same sentinel as /mode:set since apply IS
# a re-set under the hood.
#
# Hook contract: CLI helper. Errors propagate.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/active-mode.sh"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/set-mode.sh"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/audit.sh"

claude_modes::apply_mode() {
  # Resolve current repo + branch + active mode.
  local repo_root branch_slug mode_name
  repo_root=$(claude_modes::current_repo_root)
  branch_slug=""
  if [ -n "$repo_root" ]; then
    branch_slug=$(claude_modes::current_branch_slug 2>/dev/null || true)
  fi

  mode_name=$(claude_modes::read_active_mode_name "$repo_root" "$branch_slug")

  if [ -z "$mode_name" ]; then
    # No mode active. Per V2 plan F4, this is "Claude Mode" — re-apply
    # means re-running /mode:clear's cascade (no tier-3). This keeps
    # apply useful even in the no-modes-active state (e.g., user edited
    # _global.yaml and wants the changes propagated).
    echo "apply-mode: no active mode for this branch — applying Claude Mode (no tier-3 contribution)" >&2
    claude_modes::clear_mode
    return $?
  fi

  # Delegate to set_mode for the full orchestration. set_mode is
  # idempotent — re-running with the same name converges.
  claude_modes::set_mode "$mode_name"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  claude_modes::apply_mode
fi
