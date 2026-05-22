#!/usr/bin/env bash
# claude-modes V2 (U5): /mode:set + /mode:clear orchestrator.
#
# Usage:
#   bash lib/set-mode.sh <mode-name>   # set the active mode
#   bash lib/set-mode.sh --clear       # clear the active mode (Claude Mode)
#
# Ordered steps for /mode:set:
#   1. Parse + validate name
#   2. Resolve repo_root + branch_slug (or no-repo / no-branch fallback)
#   3. R26 sentinel check: if .mode-set.in-progress exists, log
#      resume/replace, then write a fresh sentinel for the new target
#   4. Resolve mode YAML path + schema_version
#   5. cascade_compile (writes settings.local.json + sidecar)
#   6. symlink_rebuild (reconciles user-catalog symlinks)
#   7. Write per-branch state (skipped in no-repo / no-branch case)
#   8. Write ~/.claude/modes/.last-active-mode (user-global pointer for
#      inject-prose.sh)
#   9. Audit `mode_set` outcome=ok
#  10. Clear sentinel
#  11. Print user-facing signal
#
# /mode:clear differs by passing "" (no tier-3) to cascade_compile and
# symlink_rebuild, removing the per-branch state file, and clearing the
# user-global pointer.
#
# R26 crash-safety contract:
#   - Sentinel is written BEFORE cascade/symlink mutations.
#   - cascade_compile, symlink_rebuild, and the per-branch/global writes
#     are all idempotent (deterministic from inputs).
#   - On failure: sentinel is preserved so a re-run with the same target
#     resumes; a re-run with a different target replaces the stale
#     sentinel and proceeds.
#   - On success: sentinel is cleared.
#
# Hook contract: this is a CLI helper. Errors propagate as non-zero exits.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/validate-mode-name.sh"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/mode-yaml.sh"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/cascade-engine.sh"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/symlink-rebuild.sh"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/audit.sh"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/active-mode.sh"

CLAUDE_MODES_SENTINEL="${HOME}/.claude/modes/.mode-set.in-progress"
CLAUDE_MODES_LAST_ACTIVE="${HOME}/.claude/modes/.last-active-mode"

# ──────────────────────────────────────────────────────────────────────
# Atomic single-file write helpers.

# __claude_modes::atomic_write_string <target_path> <content>
#
# Writes content to target_path atomically (mktemp + mv on same FS) with
# 0600 perms. The destination directory is created if missing.
# Returns 0 on success, 1 on failure (with stderr message).
__claude_modes::atomic_write_string() {
  local target="$1"
  local content="$2"

  local dir
  dir=$(dirname "$target")
  mkdir -p "$dir" 2>/dev/null || {
    echo "set-mode: could not create directory ${dir}" >&2
    return 1
  }

  local tmp
  # umask 077 ensures the tmp file is created 0600; mv preserves perms.
  tmp=$( (umask 077 && mktemp "${dir}/.set-mode.XXXXXX") ) || {
    echo "set-mode: could not create temp file in ${dir}" >&2
    return 1
  }

  # Write content without trailing newline (callers that want one append it).
  printf '%s' "$content" > "$tmp" || {
    rm -f "$tmp"
    echo "set-mode: write failed for ${target}" >&2
    return 1
  }

  # Re-assert 0600 in case umask was overridden, but skip if symlink
  # (rel-101 — macOS chmod has no -h).
  if [ ! -L "$tmp" ]; then
    chmod 0600 "$tmp" 2>/dev/null || true
  fi

  mv "$tmp" "$target" || {
    rm -f "$tmp"
    echo "set-mode: atomic rename failed for ${target}" >&2
    return 1
  }

  return 0
}

# ──────────────────────────────────────────────────────────────────────
# Sentinel management (R26).

# __claude_modes::sentinel_check <target_name>
#
# Inspects the in-progress sentinel. If it matches target_name, logs a
# resume notice. If it differs, logs a replace notice. In both cases,
# proceeds — the caller will write a fresh sentinel.
__claude_modes::sentinel_check() {
  local target="$1"

  if [ ! -f "$CLAUDE_MODES_SENTINEL" ]; then
    return 0
  fi

  local prev
  prev=$(tr -d '[:space:]' < "$CLAUDE_MODES_SENTINEL" 2>/dev/null || true)

  if [ "$prev" = "$target" ]; then
    echo "set-mode: resuming previous /mode:set for ${target}" >&2
  else
    echo "set-mode: previous /mode:set interrupted for ${prev:-<unknown>}; replacing with ${target}" >&2
    # Stale sentinel for a different target — drop it before we write
    # the fresh one. (atomic_write_string overwrites via mv, but being
    # explicit makes the audit + log story clearer.)
    rm -f "$CLAUDE_MODES_SENTINEL" 2>/dev/null || true
  fi
  return 0
}

# __claude_modes::sentinel_write <target_name>
__claude_modes::sentinel_write() {
  local target="$1"
  __claude_modes::atomic_write_string "$CLAUDE_MODES_SENTINEL" "$target"
}

# __claude_modes::sentinel_clear
__claude_modes::sentinel_clear() {
  rm -f "$CLAUDE_MODES_SENTINEL" 2>/dev/null || true
}

# ──────────────────────────────────────────────────────────────────────
# Per-branch + user-global state writes.

# __claude_modes::write_per_branch <repo_root> <branch_slug> <mode_name>
__claude_modes::write_per_branch() {
  local repo_root="$1"
  local branch_slug="$2"
  local mode_name="$3"

  local target="${repo_root}/.claude/modes/${branch_slug}.mode"
  __claude_modes::atomic_write_string "$target" "$mode_name"
}

# __claude_modes::remove_per_branch <repo_root> <branch_slug>
__claude_modes::remove_per_branch() {
  local repo_root="$1"
  local branch_slug="$2"

  local target="${repo_root}/.claude/modes/${branch_slug}.mode"
  rm -f "$target" 2>/dev/null || true
  return 0
}

# __claude_modes::write_user_global <mode_name>
__claude_modes::write_user_global() {
  local mode_name="$1"
  __claude_modes::atomic_write_string "$CLAUDE_MODES_LAST_ACTIVE" "$mode_name"
}

# __claude_modes::clear_user_global
__claude_modes::clear_user_global() {
  rm -f "$CLAUDE_MODES_LAST_ACTIVE" 2>/dev/null || true
  return 0
}

# ──────────────────────────────────────────────────────────────────────
# Public: claude_modes::set_mode <name>

claude_modes::set_mode() {
  local name="${1:-}"

  # ─── Step 1: validate name (OUTSIDE the lock — cheap, no shared state) ─
  if ! claude_modes::validate_name "$name"; then
    # validate_name printed the error.
    claude_modes::audit_event "mode_set" "mode=${name}" "outcome=fail" "step=validate_name"
    return 1
  fi

  # ─── adv-009: serialize the whole critical section under one flock ──
  # Two concurrent /mode:set calls otherwise both pass the sentinel AND
  # both mutate ~/.claude catalog (cascade_compile + symlink_rebuild +
  # .last-active-mode), corrupting state. We hold ~/.claude/modes/.symlink-lock
  # — the SAME lock that guards the catalog — across steps 2-10.
  #
  # Re-entrancy: if an ancestor already holds the lock (CLAUDE_MODES_LOCK_HELD=1),
  # run the body directly to avoid self-deadlock (fcntl.flock is per-OFD).
  if [ "${CLAUDE_MODES_LOCK_HELD:-}" = "1" ]; then
    __claude_modes::set_mode_locked "$name"
    return $?
  fi

  local lock_path="${HOME}/.claude/modes/.symlink-lock"
  __claude_modes::with_flock_run "$lock_path" -- \
    bash "${BASH_SOURCE[0]}" --__locked-set "$name"
}

# __claude_modes::set_mode_locked <name>
#
# The critical section of /mode:set (steps 2-10). MUST run while the
# user-global catalog lock (~/.claude/modes/.symlink-lock) is held — see
# claude_modes::set_mode, which is the only intended caller path.
__claude_modes::set_mode_locked() {
  local name="${1:-}"

  # Defense-in-depth (sec re-review P3): the public set_mode validates before
  # acquiring the lock, but this internal entry point is also reachable via
  # the --__locked-set CLI dispatch. Re-validate so the name can never reach
  # resolve_mode_file's path interpolation unvalidated, even if a future
  # caller skips the public path.
  if ! claude_modes::validate_name "$name"; then
    claude_modes::audit_event "mode_set" "mode=${name}" "outcome=fail" "step=validate_name_locked"
    return 1
  fi

  # ─── Step 2: resolve repo_root + branch_slug ───────────────────────
  local repo_root branch_slug
  repo_root=$(claude_modes::current_repo_root)
  branch_slug=""
  if [ -n "$repo_root" ]; then
    branch_slug=$(claude_modes::current_branch_slug 2>/dev/null || true)
  fi

  # ─── Step 3: R26 sentinel check (post-validate per advisor #6) ─────
  __claude_modes::sentinel_check "$name"
  if ! __claude_modes::sentinel_write "$name"; then
    claude_modes::audit_event "mode_set" "mode=${name}" "outcome=fail" "step=sentinel_write"
    return 1
  fi

  # ─── Step 4: resolve mode YAML + validate schema_version ───────────
  local mode_yaml_path
  if ! mode_yaml_path=$(claude_modes::resolve_mode_file "$name"); then
    # Sentinel preserved for crash-recovery semantics on re-run.
    claude_modes::audit_event "mode_set" "mode=${name}" "outcome=fail" "step=resolve_mode_file"
    return 1
  fi

  if ! claude_modes::validate_schema_version "$mode_yaml_path"; then
    claude_modes::audit_event "mode_set" "mode=${name}" "outcome=fail" "step=validate_schema_version"
    return 1
  fi

  # ─── Step 5: cascade_compile (writes settings.local.json + sidecar) ─
  if ! claude_modes::cascade_compile "$name" "$repo_root"; then
    claude_modes::audit_event "mode_set" "mode=${name}" "outcome=fail" "step=cascade_compile"
    return 1
  fi

  # ─── Step 6: symlink_rebuild ───────────────────────────────────────
  if ! claude_modes::symlink_rebuild "$mode_yaml_path"; then
    claude_modes::audit_event "mode_set" "mode=${name}" "outcome=fail" "step=symlink_rebuild"
    return 1
  fi

  # ─── Step 7: write per-branch state (skip in no-repo / no-branch) ──
  if [ -n "$repo_root" ] && [ -n "$branch_slug" ]; then
    if ! __claude_modes::write_per_branch "$repo_root" "$branch_slug" "$name"; then
      claude_modes::audit_event "mode_set" "mode=${name}" "outcome=fail" "step=write_per_branch"
      return 1
    fi
  fi

  # ─── Step 8: update user-global .last-active-mode ──────────────────
  if ! __claude_modes::write_user_global "$name"; then
    claude_modes::audit_event "mode_set" "mode=${name}" "outcome=fail" "step=write_user_global"
    return 1
  fi

  # ─── Step 9: audit ok ──────────────────────────────────────────────
  claude_modes::audit_event "mode_set" \
    "mode=${name}" \
    "branch_slug=${branch_slug}" \
    "repo_root=${repo_root}" \
    "outcome=ok"

  # ─── Step 10: clear sentinel (all mutations succeeded) ─────────────
  __claude_modes::sentinel_clear

  # ─── Step 11: user-facing signal ───────────────────────────────────
  if [ -n "$repo_root" ] && [ -n "$branch_slug" ]; then
    printf 'mode set to %s on branch %s — run /reload-plugins to apply\n' "$name" "$branch_slug"
  elif [ -n "$repo_root" ]; then
    # Should be unreachable (no branch in a repo is the bare-repo-no-commits
    # path which current_branch_slug rejects), but handle defensively.
    printf 'mode set to %s (no branch context — using user-global state) — run /reload-plugins to apply\n' "$name"
  else
    printf 'mode set to %s (no git repo — using user-global state) — run /reload-plugins to apply\n' "$name"
  fi

  return 0
}

# ──────────────────────────────────────────────────────────────────────
# Public: claude_modes::clear_mode
#
# Implements /mode:clear: return to no-modes-active state ("Claude Mode").
# Per V2 plan F4: tier 1+2+4 still apply; tier 3 contribution is dropped.
# The symlink rebuild restores the full user catalog (day-zero topology).
claude_modes::clear_mode() {
  # ─── adv-009: serialize the whole clear under the catalog lock ──────
  # Same rationale as set_mode: clear_mode mutates the user catalog
  # (cascade_compile + symlink_rebuild + per-branch/global state). Hold the
  # same ~/.claude/modes/.symlink-lock across the whole flow, with the same
  # re-entrancy guard against self-deadlock.
  if [ "${CLAUDE_MODES_LOCK_HELD:-}" = "1" ]; then
    __claude_modes::clear_mode_locked
    return $?
  fi

  local lock_path="${HOME}/.claude/modes/.symlink-lock"
  __claude_modes::with_flock_run "$lock_path" -- \
    bash "${BASH_SOURCE[0]}" --__locked-clear
}

# __claude_modes::clear_mode_locked
#
# The critical section of /mode:clear. MUST run while the user-global
# catalog lock is held — see claude_modes::clear_mode.
__claude_modes::clear_mode_locked() {
  # ─── Resolve repo_root + branch_slug ────────────────────────────────
  local repo_root branch_slug
  repo_root=$(claude_modes::current_repo_root)
  branch_slug=""
  if [ -n "$repo_root" ]; then
    branch_slug=$(claude_modes::current_branch_slug 2>/dev/null || true)
  fi

  # ─── Sentinel for /mode:clear is the literal token "_clear" ─────────
  # (Outside the validate_name allowlist by design — internal-only token
  # never written by /mode:set. Matches the "stale sentinel for different
  # target" branch of R26 if a previous /mode:set was interrupted.)
  __claude_modes::sentinel_check "_clear"
  if ! __claude_modes::sentinel_write "_clear"; then
    claude_modes::audit_event "mode_clear" "outcome=fail" "step=sentinel_write"
    return 1
  fi

  # ─── Cascade with no tier-3 contribution ───────────────────────────
  # cascade_compile already treats mode_name="" as Claude Mode.
  if ! claude_modes::cascade_compile "" "$repo_root"; then
    claude_modes::audit_event "mode_clear" "outcome=fail" "step=cascade_compile"
    return 1
  fi

  # ─── Symlink rebuild with empty manifest (day-zero topology) ───────
  if ! claude_modes::symlink_rebuild ""; then
    claude_modes::audit_event "mode_clear" "outcome=fail" "step=symlink_rebuild"
    return 1
  fi

  # ─── Remove per-branch state file ──────────────────────────────────
  if [ -n "$repo_root" ] && [ -n "$branch_slug" ]; then
    __claude_modes::remove_per_branch "$repo_root" "$branch_slug"
  fi

  # ─── Clear user-global .last-active-mode ──────────────────────────
  __claude_modes::clear_user_global

  claude_modes::audit_event "mode_clear" \
    "branch_slug=${branch_slug}" \
    "repo_root=${repo_root}" \
    "outcome=ok"

  __claude_modes::sentinel_clear

  if [ -n "$repo_root" ] && [ -n "$branch_slug" ]; then
    printf 'mode cleared on branch %s (Claude Mode active) — run /reload-plugins to apply\n' "$branch_slug"
  else
    printf 'mode cleared (Claude Mode active) — run /reload-plugins to apply\n'
  fi
  return 0
}

# ──────────────────────────────────────────────────────────────────────
# CLI entry point.

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
    --clear)
      claude_modes::clear_mode
      ;;
    --__locked-set)
      # Internal entry point: invoked by with_flock_run with the catalog
      # lock already held. Runs the critical section only. Not for direct use.
      shift
      __claude_modes::set_mode_locked "$@"
      ;;
    --__locked-clear)
      # Internal entry point (see --__locked-set).
      __claude_modes::clear_mode_locked
      ;;
    "")
      echo "set-mode: mode name required (or --clear)" >&2
      echo "Usage: $0 <mode-name>" >&2
      echo "       $0 --clear" >&2
      exit 2
      ;;
    --*)
      echo "set-mode: unknown flag '${1}'" >&2
      exit 2
      ;;
    *)
      claude_modes::set_mode "$1"
      ;;
  esac
fi
