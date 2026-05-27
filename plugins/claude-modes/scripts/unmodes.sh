#!/usr/bin/env bash
# claude-modes V2 (U7): registry-driven uninstall orchestrator.
#
# Reverses scripts/setup.sh:
#   0. Presence check — exit 0 cleanly if not installed.
#   1. Read install registry (~/.claude/modes/.installed-repos.txt) via
#      claude_modes::list_registered_repos.
#   2. For each listed repo (in dedup'd order):
#      2a. Path-class verification: refuse to act unless
#          `git -C <path> rev-parse --show-toplevel` returns <path>
#          exactly (no traversal, no subdirectory). Audit + continue
#          on mismatch — NEVER rm a path that failed verification.
#      2b. Sidecar-based deletion gate (LOCKED per cross-persona finding
#          2026-05-18 — see plan U7 section). For each registered repo:
#            - If .cascade-meta.json sidecar absent → settings.local.json
#              is not plugin-authored → preserve it; audit
#              uninstall_preserve_settings reason=no-sidecar.
#            - If sidecar present AND current sha256 of settings.local.json
#              matches sidecar.fingerprint → both plugin-authored,
#              unedited → delete both.
#            - If sidecar present AND fingerprints mismatch → user (or
#              another plugin / Claude Code itself) edited
#              settings.local.json post-cascade; delete ONLY the sidecar,
#              preserve settings.local.json, audit a user-edited warning.
#      2c. Remove <repo>/.claude/modes/ entirely (plugin-owned tree per R12).
#   3. Move user catalog files back. Symmetric reverse of setup.sh
#      step 4. For each file currently staged in
#      ~/.claude/modes/.user-catalog/<category>/:
#        - The live ~/.claude/<category>/<name>.md must be a symlink
#          whose target is the staged file. If not, preserve everything
#          (alien state, never destroy user work).
#        - Atomic mv staged → live; cross-filesystem fallback cp+verify+rm.
#   4. Forensic preservation: copy ~/.claude/modes/.audit.log to
#      ~/.claude/.claude-modes-uninstall.log (born-at-0600). This is the
#      ONE R12 exception (writing outside ~/.claude/modes/) — preserved
#      as a uninstall forensic anchor.
#   5. Audit the final "uninstall" event by INLINE-APPEND to the
#      preserved log (the original audit log is about to be deleted, so
#      claude_modes::audit_event would write to a dying file).
#   6. Remove ~/.claude/modes/ entirely (plugin-owned per R12).
#   7. Print user-facing confirmation. NEVER touch ~/.claude/settings.json;
#      pristine is preserved untouched as a forensic anchor.

set -uo pipefail

# ──────────────────────────────────────────────────────────────────────
# Resolve plugin root and source libs.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/lib/install-registry.sh"
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/lib/mode-yaml.sh"
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/lib/audit.sh"
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/lib/sanitize.sh"  # terminal-escape: $settings_local is clone-path-derived

CLAUDE_MODES_PYTHON3="${CLAUDE_MODES_PYTHON3:-/usr/bin/python3}"

# ──────────────────────────────────────────────────────────────────────
# Paths.
MODES_DIR="${HOME}/.claude/modes"
PRISTINE="${HOME}/.claude/settings.json.pristine"
AUDIT_LOG="${MODES_DIR}/.audit.log"
PRESERVED_LOG="${HOME}/.claude/.claude-modes-uninstall.log"
USER_CATALOG="${MODES_DIR}/.user-catalog"
COMMANDS_LIVE="${HOME}/.claude/commands"
AGENTS_LIVE="${HOME}/.claude/agents"
COMMANDS_STAGING="${USER_CATALOG}/commands"
AGENTS_STAGING="${USER_CATALOG}/agents"

PLUGIN_VERSION="0.2.0"

# Counters used in the final audit event.
REPOS_VISITED=0
REPOS_SKIPPED_PATH_CLASS=0
REPOS_SKIPPED_NO_SIDECAR=0
REPOS_DELETED_FULL=0
REPOS_PRESERVED_USER_EDIT=0
FILES_RETURNED=0
FILES_SKIPPED_USER_CATALOG=0

# ──────────────────────────────────────────────────────────────────────
# Logging helpers.
_log() { printf 'unmodes.sh: %s\n' "$1"; }
_err() { printf 'unmodes.sh: %s\n' "$1" >&2; }


# Python realpath helper (portable; macOS lacks coreutils realpath).
_realpath() {
  "$CLAUDE_MODES_PYTHON3" -c \
    'import os.path,sys; print(os.path.realpath(sys.argv[1]))' \
    "$1" 2>/dev/null
}

# ──────────────────────────────────────────────────────────────────────
# Append a single audit-format line directly to a chosen log file.
#
# claude_modes::audit_event hardcodes the path to AUDIT_LOG (inside the
# tree we're about to delete). After step 4 the canonical log path no
# longer exists — we need an inline writer that targets the preserved
# log directly. Line format mirrors audit.sh's: TAB-separated, ISO-UTC
# timestamp, event=<event>, then key=value pairs.
#
# Born-at-0600 enforcement via re-assert chmod after append (the file
# was already born at 0600 by step 4's preservation copy).
_audit_append_to() {
  local log_path="$1"
  local event="$2"
  shift 2

  # Sanitize event name.
  event="${event//$'\t'/ }"
  event="${event//$'\n'/ }"

  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "unknown-time")

  local line="${ts}"$'\t'"event=${event}"

  local pair key value
  for pair in "$@"; do
    key="${pair%%=*}"
    value="${pair#*=}"
    # Match audit.sh truncation length (200 chars).
    if [ "${#value}" -gt 200 ]; then
      value="${value:0:200}..."
    fi
    key="${key//$'\t'/ }"
    key="${key//$'\n'/ }"
    value="${value//$'\t'/ }"
    value="${value//$'\n'/ }"
    line+=$'\t'"${key}=${value}"
  done

  printf '%s\n' "$line" >> "$log_path" 2>/dev/null || {
    _err "could not append uninstall audit event to ${log_path}"
    return 0
  }

  # Re-assert 0600 (preserved log born at 0600 in step 4 already; defense
  # in depth in case OS dropped perms on cross-fs).
  if [ ! -L "$log_path" ]; then
    chmod 0600 "$log_path" 2>/dev/null || true
  fi
}

# ──────────────────────────────────────────────────────────────────────
# Step 0: Presence check.
step_presence_check() {
  if [ ! -d "$MODES_DIR" ]; then
    _log "claude-modes is not installed; nothing to do."
    exit 0
  fi
}

# ──────────────────────────────────────────────────────────────────────
# Step 2: For each registered repo, run path-class + sidecar gate + rm
# the plugin-owned <repo>/.claude/modes/ tree.
step_clean_registered_repos() {
  local listed
  listed=$(claude_modes::list_registered_repos)
  if [ -z "$listed" ]; then
    _log "install registry is empty; no repos to clean"
    return 0
  fi

  local path
  while IFS= read -r path; do
    [ -z "$path" ] && continue
    REPOS_VISITED=$((REPOS_VISITED + 1))

    # ─── 2a. Path-class verification ────────────────────────────────
    # MUST be a git work-tree root AND match the registry entry exactly.
    # Refuse to act on any path that fails the check (closes the
    # attack where a malicious registry entry points at /etc/cron.d).
    local toplevel
    toplevel=$(git -C "$path" rev-parse --show-toplevel 2>/dev/null)
    if [ -z "$toplevel" ]; then
      claude_modes::audit_event "uninstall_skip_path" \
        "path=${path}" \
        "reason=not-git-repo"
      REPOS_SKIPPED_PATH_CLASS=$((REPOS_SKIPPED_PATH_CLASS + 1))
      _log "skip ${path} (not a git work-tree)"
      continue
    fi
    if [ "$toplevel" != "$path" ]; then
      claude_modes::audit_event "uninstall_skip_path" \
        "path=${path}" \
        "reason=path-mismatch" \
        "toplevel=${toplevel}"
      REPOS_SKIPPED_PATH_CLASS=$((REPOS_SKIPPED_PATH_CLASS + 1))
      _log "skip ${path} (path is not the git work-tree root; toplevel=${toplevel})"
      continue
    fi

    # ─── 2b. Sidecar-based deletion gate ────────────────────────────
    local settings_local="${path}/.claude/settings.local.json"
    local sidecar="${path}/.claude/modes/.cascade-meta.json"

    if [ ! -f "$sidecar" ]; then
      # No sidecar → settings.local.json (if any) is not plugin-authored.
      # Preserve it. Still safe to wipe the plugin-owned modes/ tree
      # below (no sidecar means we never wrote one; nothing to lose).
      claude_modes::audit_event "uninstall_preserve_settings" \
        "path=${path}" \
        "reason=no-sidecar"
      REPOS_SKIPPED_NO_SIDECAR=$((REPOS_SKIPPED_NO_SIDECAR + 1))
      _log "no sidecar in ${path}; preserving any settings.local.json"
    else
      # Sidecar present → compare fingerprint vs current settings hash.
      local current_sha sidecar_fp
      current_sha=""
      if [ -f "$settings_local" ]; then
        current_sha=$(claude_modes::sha256_of_file "$settings_local" 2>/dev/null)
      fi
      sidecar_fp=$("$CLAUDE_MODES_PYTHON3" - "$sidecar" <<'PYEOF' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    fp = data.get("fingerprint", "")
    print(fp)
except Exception:
    print("")
PYEOF
)

      if [ -n "$current_sha" ] && [ "$current_sha" = "$sidecar_fp" ]; then
        # Match → both plugin-authored, unedited. Safe to delete both.
        rm -f "$settings_local"
        rm -f "$sidecar"
        REPOS_DELETED_FULL=$((REPOS_DELETED_FULL + 1))
        claude_modes::audit_event "uninstall_repo_clean" \
          "path=${path}" \
          "settings_local=removed" \
          "sidecar=removed"
        _log "removed plugin-authored settings.local.json + sidecar in ${path}"
      else
        # Mismatch (or settings.local.json missing while sidecar present)
        # → preserve settings.local.json (if any), remove sidecar only.
        local mismatch_reason
        if [ -z "$current_sha" ]; then
          mismatch_reason="user-removed-settings-local-post-cascade"
        else
          mismatch_reason="user-edited-post-cascade"
        fi
        rm -f "$sidecar"
        REPOS_PRESERVED_USER_EDIT=$((REPOS_PRESERVED_USER_EDIT + 1))
        claude_modes::audit_event "uninstall_preserve_settings" \
          "path=${path}" \
          "reason=${mismatch_reason}" \
          "sidecar=removed"
        _log "WARNING: $(claude_modes::sanitize_for_display "${settings_local}") appears user-edited post-cascade; preserving it (sidecar removed). Review and clean up manually."
      fi
    fi

    # ─── 2c. Remove the plugin-owned <repo>/.claude/modes/ tree ────
    # This dir is plugin-owned per R12 — rm permitted.
    local repo_modes_dir="${path}/.claude/modes"
    if [ -d "$repo_modes_dir" ]; then
      rm -rf "$repo_modes_dir"
    fi
  done <<< "$listed"
}

# ──────────────────────────────────────────────────────────────────────
# Step 3: Move user-catalog files back (symmetric reverse of setup.sh).
#
# For each file in the staging area, verify the live path is the symlink
# we created at setup time (target points BACK to the staged file).
# Any deviation = alien state, preserve everything, audit + continue.
#
# Symlink-cycle safety: the dispatch path stays inside ~/.claude/. We
# never resolve through user-controlled symlinks for decisions; the
# only resolve we do is the target-vs-staged comparison (realpath both
# sides; if either fails we skip).
step_return_user_catalog() {
  _return_category "$COMMANDS_STAGING" "$COMMANDS_LIVE" "commands"
  _return_category "$AGENTS_STAGING"   "$AGENTS_LIVE"   "agents"
}

# _return_category <staging_dir> <live_dir> <category_label>
_return_category() {
  local staging="$1"
  local live_dir="$2"
  local label="$3"

  if [ ! -d "$staging" ]; then
    return 0
  fi

  # Ensure live dir exists (it may have been removed by the user; we
  # re-create rather than skip, so atomic mv has a destination).
  mkdir -p "$live_dir" 2>/dev/null || true

  local f basename_f live target_real staged_real
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    basename_f="$(basename "$f")"
    live="${live_dir}/${basename_f}"

    # ─── Pre-flight: is the live path the symlink we created? ──────
    # Strict spec (matches the U7 task contract): the live path must be
    # a symlink whose target is the staged file. Anything else (absent,
    # regular file, alien symlink) → preserve everything, audit a skip,
    # continue. Absent-live is deliberately a skip rather than a
    # courtesy restore: if the user removed the symlink after install,
    # we treat that as an explicit intent — don't second-guess by
    # restoring content they may have wanted gone.
    if [ ! -L "$live" ]; then
      local reason
      if [ ! -e "$live" ]; then
        reason="live-absent"
      else
        reason="live-not-symlink"
      fi
      claude_modes::audit_event "uninstall_skip_user_catalog" \
        "category=${label}" \
        "file=${basename_f}" \
        "reason=${reason}"
      FILES_SKIPPED_USER_CATALOG=$((FILES_SKIPPED_USER_CATALOG + 1))
      _log "preserving ${live} (live-${reason}); staged copy at ${f} will be removed with ~/.claude/modes/"
      continue
    fi

    # Live path is a symlink. Verify its target realpath-equals the
    # staged file we hold (it MUST be ours — alien symlinks pointing
    # outside our staging area get preserved).

    # Symlink target must realpath-equal the staged file we hold.
    target_real=$(_realpath "$live")
    staged_real=$(_realpath "$f")
    if [ -z "$target_real" ] || [ -z "$staged_real" ] || [ "$target_real" != "$staged_real" ]; then
      claude_modes::audit_event "uninstall_skip_user_catalog" \
        "category=${label}" \
        "file=${basename_f}" \
        "reason=alien-symlink-target"
      FILES_SKIPPED_USER_CATALOG=$((FILES_SKIPPED_USER_CATALOG + 1))
      _log "preserving ${live} (symlink points outside our staging area: ${target_real})"
      continue
    fi

    # Symlink check passed: remove the symlink, then mv the staged file
    # back into place.
    rm -f "$live" || {
      _err "${label}: could not remove plugin symlink at ${live}"
      continue
    }
    _do_return_file "$f" "$live" "$label" "$basename_f"
  done < <(find -P "$staging" -maxdepth 1 -name '*.md' -type f 2>/dev/null | sort)
}

# _do_return_file <staged> <live> <label> <basename> — performs the
# same-filesystem atomic mv OR cross-filesystem cp+verify+rm fallback
# (mirror of setup.sh's _move_category logic).
_do_return_file() {
  local staged="$1"
  local live="$2"
  local label="$3"
  local basename_f="$4"

  # Atomic move with cross-FS fallback (canonical claude_modes::safe_move:
  # try mv, else cp+sha256-verify+rm). Replaces the prior stat-device-id branch.
  if ! claude_modes::safe_move "$staged" "$live"; then
    _err "${label}: safe_move failed returning ${basename_f}: ${staged} → ${live}"
    return 1
  fi

  # Live file is now a regular file. Don't chmod — user-authored content
  # returned to user-authored state; preserve whatever umask the user's
  # shell normally gives them. (setup.sh chmod'd the staged file at 0600
  # for plugin-state hygiene; here it's back in the user catalog.)

  FILES_RETURNED=$((FILES_RETURNED + 1))
  _log "${label}: returned ${basename_f} → ${live}"
  return 0
}

# ──────────────────────────────────────────────────────────────────────
# Step 4: Forensic preservation.
#
# Copy ~/.claude/modes/.audit.log → ~/.claude/.claude-modes-uninstall.log
# (born-at-0600 via umask + mktemp + atomic mv). This is the ONE R12
# exception — writing a plugin artifact OUTSIDE of ~/.claude/modes/.
# Justification: uninstall must leave a forensic anchor outside the
# tree it deletes; the uninstall log is the only way the user can
# audit what we did after the fact.
step_preserve_audit_log() {
  if [ ! -f "$AUDIT_LOG" ]; then
    _log "no audit log to preserve (none was ever written)"
    # Still create an empty preserved log so the user-facing message
    # and the final audit event have somewhere to land.
    (umask 077 && : > "$PRESERVED_LOG") || {
      _err "could not create empty preserved log at ${PRESERVED_LOG}"
      return 0
    }
    if [ ! -L "$PRESERVED_LOG" ]; then
      chmod 0600 "$PRESERVED_LOG" 2>/dev/null || true
    fi
    return 0
  fi

  # Atomic cp into ~/.claude/ — tmp file in the same dir, then mv.
  local target_dir
  target_dir="$(dirname "$PRESERVED_LOG")"
  mkdir -p "$target_dir" 2>/dev/null || true

  local tmp
  tmp=$( (umask 077 && mktemp "${target_dir}/.claude-modes-uninstall.XXXXXX") ) || {
    _err "mktemp failed for preserved log"
    return 0
  }
  if ! cp "$AUDIT_LOG" "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    _err "cp failed for preserved log"
    return 0
  fi
  if ! mv "$tmp" "$PRESERVED_LOG"; then
    rm -f "$tmp"
    _err "atomic mv failed for preserved log"
    return 0
  fi
  if [ ! -L "$PRESERVED_LOG" ]; then
    chmod 0600 "$PRESERVED_LOG" 2>/dev/null || true
  fi
  _log "preserved audit log → ${PRESERVED_LOG}"
}

# ──────────────────────────────────────────────────────────────────────
# Step 5: Final audit event — INLINE-APPEND to the preserved log.
#
# We can't use claude_modes::audit_event() here because audit.sh writes
# to ~/.claude/modes/.audit.log (the file we just preserved as a frozen
# snapshot; the original is about to be deleted in step 6). Inline
# writer targets the preserved log directly so the final event lands
# in the surviving artifact.
step_emit_final_event() {
  _audit_append_to "$PRESERVED_LOG" "uninstall" \
    "version=${PLUGIN_VERSION}" \
    "repos_visited=${REPOS_VISITED}" \
    "repos_skipped_path_class=${REPOS_SKIPPED_PATH_CLASS}" \
    "repos_skipped_no_sidecar=${REPOS_SKIPPED_NO_SIDECAR}" \
    "repos_deleted_full=${REPOS_DELETED_FULL}" \
    "repos_preserved_user_edit=${REPOS_PRESERVED_USER_EDIT}" \
    "files_returned=${FILES_RETURNED}" \
    "files_skipped_user_catalog=${FILES_SKIPPED_USER_CATALOG}"
}

# ──────────────────────────────────────────────────────────────────────
# Step 6: Delete ~/.claude/modes/ entirely. Plugin-owned per R12 — rm
# permitted. (The preserved log is in ~/.claude/ — NOT inside modes/ —
# so it survives.)
step_delete_modes_dir() {
  rm -rf "$MODES_DIR"
  _log "removed ${MODES_DIR}"
}

# ──────────────────────────────────────────────────────────────────────
# Step 7: User-facing confirmation.
step_print_done() {
  printf '%s\n' "claude-modes uninstalled. Forensic log preserved at ${PRESERVED_LOG}. Your ~/.claude/settings.json was never modified by the plugin and remains as-is."
}

# ──────────────────────────────────────────────────────────────────────
# Optional: purge the pristine snapshot (sec-006/adv-012 explicit consent).
#
# By default the pristine is preserved as a forensic anchor. --purge-pristine
# removes it for users who don't want even the allowlist-filtered snapshot
# (or who have a pre-V2.1 pristine that may still contain secrets) lingering.
step_purge_pristine() {
  if [ -f "$PRISTINE" ]; then
    rm -f "$PRISTINE" 2>/dev/null && \
      printf '%s\n' "purged pristine snapshot at ${PRISTINE}" || \
      _err "could not remove pristine at ${PRISTINE}"
  else
    printf '%s\n' "no pristine snapshot to purge (${PRISTINE} absent)"
  fi
}

# ──────────────────────────────────────────────────────────────────────
# Main.
main() {
  local purge_pristine=0
  local arg
  for arg in "$@"; do
    case "$arg" in
      --purge-pristine) purge_pristine=1 ;;
      --help|-h)
        printf '%s\n' "Usage: unmodes.sh [--purge-pristine]"
        printf '%s\n' "  --purge-pristine  also delete ~/.claude/settings.json.pristine (default: preserved as forensic anchor)"
        return 0
        ;;
      *)
        _err "unmodes.sh: unknown flag '${arg}'"
        return 2
        ;;
    esac
  done

  step_presence_check
  step_clean_registered_repos
  step_return_user_catalog
  step_preserve_audit_log
  step_emit_final_event
  step_delete_modes_dir
  [ "$purge_pristine" -eq 1 ] && step_purge_pristine
  step_print_done
  return 0
}

main "$@"
