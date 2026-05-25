#!/usr/bin/env bash
# claude-modes V2: post-write reload PROMPT helper (degraded R5).
#
# Centralizes the post-write reload trigger so the agent (U7) and all
# slash commands (U5) share ONE entry point: after a mode YAML is
# written, call claude_modes::post_write_reload to close the loop on
# applying the change in the live harness.
#
# # Why this ships DEGRADED (Phase 0 Spike D outcome)
#
# Spike D found ZERO call sites in the codebase that invoke /reload-plugins
# from script context — every existing site PRINTS the string for the user
# to type (set-mode.sh, restore-claude-modes.sh, mode-suggester,
# mode-author). Whether script-context emission actually triggers an
# in-harness reload could not be falsified positively from inside a running
# session (the session's plugin state is fixed at session start). So the
# DEFAULT path here does NOT attempt auto-reload: it prints a visible
# one-line notice that names the literal /reload-plugins command, and the
# user mechanically runs reload. Same deterministic-V1 contract; different
# actor (the user closes the loop, not the script).
#
# # Upgrade path (kept inert by default)
#
# If a future release verifies in a fresh session that script-context
# reload works, the auto path is a SMALL ADDITIVE change: implement the
# emission inside __claude_modes::post_write_reload_auto (marked TODO
# below) and flip the default of CLAUDE_MODES_AUTO_RELOAD. The print path
# is the load-bearing default until that verification lands.
#
# Reload-failure handling (auto path only): if auto-reload is attempted and
# fails, audit outcome=reload_fail, print a recovery instruction, and
# return non-zero — but do NOT revert the YAML. The writer already
# committed an atomic, validated write; YAML correctness is independent of
# whether the harness has reloaded yet. Reverting a good write only adds a
# second failure mode (revert-failure) without restoring harness state.
# The degraded default path has no failure mode (it only prints), so it
# always returns 0.

# shellcheck disable=SC1091
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/audit.sh"
. "${SCRIPT_DIR}/sanitize.sh"

# claude_modes::post_write_reload <mode-name> <delta-summary>
#
# Thin dispatcher. The DEFAULT (CLAUDE_MODES_AUTO_RELOAD unset or != 1) is
# the degraded print-prompt path. The auto path is guarded OFF by default
# and inert until a future release confirms script-context reload works.
#
# Args:
#   mode-name      — the mode whose YAML was just written (attacker-class:
#                    a mode name can carry crafted bytes → sanitize before
#                    any terminal print)
#   delta-summary  — a human-readable summary of what changed (attacker-
#                    class: may embed plugin keys → sanitize before print)
#
# Returns: 0 on the degraded path always; 0 on auto success; non-zero on
#          auto reload failure.
claude_modes::post_write_reload() {
  local mode_name="${1:-unknown}"
  local delta_summary="${2:-updated}"

  if [ "${CLAUDE_MODES_AUTO_RELOAD:-0}" = "1" ]; then
    __claude_modes::post_write_reload_auto "$mode_name" "$delta_summary"
    return $?
  fi

  __claude_modes::post_write_reload_prompt "$mode_name" "$delta_summary"
  return $?
}

# __claude_modes::post_write_reload_prompt <mode-name> <delta-summary>
#
# Degraded DEFAULT path: print a visible, non-silent one-line notice that
# names the literal /reload-plugins command, audit the prompt, return 0.
# There is no failure mode here — printing always "succeeds".
__claude_modes::post_write_reload_prompt() {
  local mode_name="$1"
  local delta_summary="$2"

  # Sanitize attacker-class values before they reach a human terminal. The
  # _d ("display") variants are safe-by-construction (Cc/Cf stripped) — only
  # these are interpolated into the printf below (terminal-sink lint
  # convention: the _d suffix is the "already sanitized" signal).
  local mode_name_d delta_summary_d
  mode_name_d="$(claude_modes::sanitize_for_display "$mode_name")"
  delta_summary_d="$(claude_modes::sanitize_for_display "$delta_summary")"

  # Side-effect notice → stderr (write-mode-yaml.sh convention): keeps operator
  # prose out of any structured stdout a caller captures via $(...).
  printf 'Mode %s updated (%s). Run /reload-plugins to apply.\n' \
    "$mode_name_d" "$delta_summary_d" >&2

  # Audit with the RAW mode name (the audit log is a file, not a terminal;
  # sanitization is a terminal-display concern only). Audit always returns
  # 0 and never propagates failure.
  claude_modes::audit_event "mode_reload_prompt" "mode=${mode_name}" "outcome=ok"

  return 0
}

# __claude_modes::post_write_reload_auto <mode-name> <delta-summary>
#
# Future auto-reload path. Guarded OFF by default (only reached when
# CLAUDE_MODES_AUTO_RELOAD=1). Inert in production until a release verifies
# script-context reload works in a fresh session.
#
# Test seam: CLAUDE_MODES_TEST_RELOAD mocks the reload mechanism's outcome
# (ok|fail) so the guard + failure-handling can be tested without a real
# harness. With AUTO=1 and NO mock set, we treat the attempt as FAILED:
# production has no real emission mechanism yet, and silently faking success
# would hide the upgrade work. This is the safe default for the inert path.
__claude_modes::post_write_reload_auto() {
  local mode_name="$1"
  local delta_summary="$2"

  local mode_name_d delta_summary_d
  mode_name_d="$(claude_modes::sanitize_for_display "$mode_name")"
  delta_summary_d="$(claude_modes::sanitize_for_display "$delta_summary")"

  # TODO(upgrade R5 → true auto-reload): replace this mock-driven branch
  # with the real script-context emission once a fresh-session spike
  # confirms it triggers an in-harness reload. Until then the only way to
  # reach the "ok" branch is the test mock, and unmocked production
  # correctly falls through to reload_fail.
  local reload_outcome="${CLAUDE_MODES_TEST_RELOAD:-fail}"

  if [ "$reload_outcome" = "ok" ]; then
    printf 'Reloading plugins for mode %s (%s).\n' \
      "$mode_name_d" "$delta_summary_d" >&2
    claude_modes::audit_event "mode_reload_prompt" "mode=${mode_name}" "outcome=ok"
    return 0
  fi

  # Reload failed — do NOT revert the YAML. Surface a recovery instruction
  # and audit the failure.
  claude_modes::audit_event "mode_reload_prompt" "mode=${mode_name}" "outcome=reload_fail"
  printf 'Reload failed for mode %s — run /reload-plugins to recover. YAML is up to date.\n' \
    "$mode_name_d" >&2
  return 1
}

# Allow direct invocation for testing / manual use:
#   bash lib/post-write-reload.sh <mode-name> <delta-summary>
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <mode-name> <delta-summary>" >&2
    exit 2
  fi
  claude_modes::post_write_reload "$@"
fi
