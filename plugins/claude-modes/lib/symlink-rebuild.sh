#!/usr/bin/env bash
# claude-modes V2 (U8): user-catalog symlink rebuild orchestrator.
#
# Purpose:
#   Reconcile the live `~/.claude/commands/` and `~/.claude/agents/`
#   symlink topology with the active mode's `mechanism.user_catalog`
#   manifest. The mechanism:
#     - Files declared by the manifest get a symlink at the live path
#       pointing at the matching file in `~/.claude/modes/.user-catalog/`.
#     - Plugin-owned symlinks not in the manifest get removed.
#     - Alien (non-plugin-owned) entries — files we didn't create, or
#       symlinks pointing OUTSIDE the staging dir — are NEVER touched.
#
# Security invariants:
#   - R7 (path traversal): every manifest entry passes
#     `lib/symlink-validate.py` BEFORE any FS mutation. ALL entries are
#     validated in pass 1; if any fail, the rebuild aborts with no
#     symlinks created or removed. Pass 2 applies the diff.
#   - R13 (no destructive verbs on user-authored paths): before each
#     `rm` we verify the path is a symlink AND its realpath resolves
#     under `~/.claude/modes/.user-catalog/`. Regular files at the
#     live-path locations are NEVER removed.
#   - Alien-symlink preservation: any live-path symlink whose realpath
#     does NOT resolve under `.user-catalog/` is treated as user state
#     and left alone, even if its name collides with a manifest entry.
#     (If a manifest entry would create a symlink at a path already
#     occupied by an alien symlink, we leave the alien in place and
#     skip the create — matches the "never clobber user state" rule.)
#
# Public function:
#   claude_modes::symlink_rebuild [mode_yaml_path]
#
# When `mode_yaml_path` is empty (no-modes-active / "Claude Mode"), the
# manifest is the full set of files currently in
# `.user-catalog/commands/` and `.user-catalog/agents/` — i.e., restore
# the day-zero topology. Per the V2 plan (U5), `/mode:clear` calls this
# with an empty arg precisely to undo any sticky restrictions from the
# previous mode.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/mode-yaml.sh"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/audit.sh"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/sanitize.sh"  # terminal-escape: $entry is untrusted manifest content

CLAUDE_MODES_PYTHON3="${CLAUDE_MODES_PYTHON3:-/usr/bin/python3}"

# ──────────────────────────────────────────────────────────────────────
# Internal helpers.

# Echo the realpath of $1 using the pinned Python (portable across
# macOS without GNU coreutils). Echoes the empty string on error.
__claude_modes::realpath() {
  "$CLAUDE_MODES_PYTHON3" -c \
    'import os.path,sys; print(os.path.realpath(sys.argv[1]))' \
    "$1" 2>/dev/null
}

# Echo 1 if symlink at $1 resolves under realpath($2), else echo 0.
# Used to classify "plugin-owned" vs "alien" live-path symlinks.
__claude_modes::symlink_targets_under() {
  local link_path="$1"
  local under_dir="$2"

  if [ ! -L "$link_path" ]; then
    echo 0
    return
  fi

  local resolved
  resolved=$(__claude_modes::realpath "$link_path")
  local resolved_under
  resolved_under=$(__claude_modes::realpath "$under_dir")

  case "$resolved" in
    "$resolved_under"/*) echo 1 ;;
    *) echo 0 ;;
  esac
}

# Validate every manifest entry against the staging dir using
# lib/symlink-validate.py. Returns 0 if all entries are safe;
# returns non-zero with stderr explaining the offender otherwise.
#
# Args:
#   $1 = staging dir (e.g., ~/.claude/modes/.user-catalog/commands)
#   $2..$N = manifest entries
__claude_modes::validate_manifest_entries() {
  local staging="$1"
  shift

  local validator="${SCRIPT_DIR}/symlink-validate.py"

  local entry
  for entry in "$@"; do
    if ! "$CLAUDE_MODES_PYTHON3" "$validator" "$staging" "$entry" >/dev/null 2>&1; then
      # Re-run capturing stderr for the user-facing message.
      local err
      err=$("$CLAUDE_MODES_PYTHON3" "$validator" "$staging" "$entry" 2>&1 1>/dev/null)
      # $entry is untrusted manifest content (R7 chokepoint); $staging is
      # repo-derived; $err is symlink-validate.py's stderr (already sanitized
      # at its source in L7-a, but re-sanitize here for defense-in-depth).
      echo "symlink-rebuild: refusing rebuild — manifest entry '$(claude_modes::sanitize_for_display "${entry}")' in '$(claude_modes::sanitize_for_display "${staging}")' failed validation: $(claude_modes::sanitize_for_display "${err}")" >&2
      return 1
    fi
  done
  return 0
}

# Enumerate currently-installed plugin-owned symlinks in a live dir.
# Args:
#   $1 = live dir (e.g., ~/.claude/commands)
#   $2 = staging dir (e.g., ~/.claude/modes/.user-catalog/commands)
# Stdout: basename per line of each plugin-owned symlink.
__claude_modes::enumerate_plugin_symlinks() {
  local live_dir="$1"
  local staging="$2"

  if [ ! -d "$live_dir" ]; then
    return 0
  fi

  # -P never dereferences symlinks; -maxdepth 1 stays in the live dir.
  local link
  while IFS= read -r link; do
    [ -z "$link" ] && continue
    if [ "$(__claude_modes::symlink_targets_under "$link" "$staging")" = "1" ]; then
      basename "$link"
    fi
  done < <(find -P "$live_dir" -maxdepth 1 -type l 2>/dev/null)
}

# Enumerate files directly under a staging category (no recursion).
# Used for the "empty mode" / Claude Mode case to construct the
# day-zero manifest.
__claude_modes::enumerate_staging_files() {
  local staging="$1"
  if [ ! -d "$staging" ]; then
    return 0
  fi
  local f
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    basename "$f"
  done < <(find -P "$staging" -maxdepth 1 \( -type f -o -type l \) 2>/dev/null)
}

# ──────────────────────────────────────────────────────────────────────
# Per-category reconciler. Returns added/removed counts via the
# globals __SR_ADDED and __SR_REMOVED so the caller can roll them into
# a single audit event.
__SR_ADDED=0
__SR_REMOVED=0

# claude_modes::symlink_rebuild_category <live_dir> <staging> entries...
#
# Two-pass: validate every entry first (R7), then apply the diff.
__claude_modes::symlink_rebuild_category() {
  local live_dir="$1"
  local staging="$2"
  shift 2

  __SR_ADDED=0
  __SR_REMOVED=0

  # Ensure live dir exists for the symlink targets.
  mkdir -p "$live_dir"

  # ─── Pass 1: validate every entry (no FS mutation yet) ──────────
  if ! __claude_modes::validate_manifest_entries "$staging" "$@"; then
    return 1
  fi

  # ─── Pass 2: compute diff and apply ─────────────────────────────
  # Build target set (sorted-unique) from manifest entries.
  local target_set
  target_set=$(
    if [ "$#" -gt 0 ]; then
      printf '%s\n' "$@" | sort -u
    fi
  )

  # Build current set of plugin-owned symlinks in live_dir.
  local current_set
  current_set=$(__claude_modes::enumerate_plugin_symlinks "$live_dir" "$staging" | sort -u)

  # to_create = target_set − current_set
  # to_remove = current_set − target_set
  local to_create to_remove
  to_create=$(comm -23 <(printf '%s\n' "$target_set") <(printf '%s\n' "$current_set"))
  to_remove=$(comm -13 <(printf '%s\n' "$target_set") <(printf '%s\n' "$current_set"))

  local name live target
  # ─── Create symlinks for entries in target but not current ──────
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    live="${live_dir}/${name}"
    target="${staging}/${name}"

    # If something already exists at the live path:
    if [ -e "$live" ] || [ -L "$live" ]; then
      if [ -L "$live" ]; then
        if [ "$(__claude_modes::symlink_targets_under "$live" "$staging")" = "1" ]; then
          # Already a plugin-owned symlink at the right basename — but
          # may point at the wrong target (e.g., shape changed). Verify
          # and skip if it already resolves to the desired target.
          local cur_resolved want_resolved
          cur_resolved=$(__claude_modes::realpath "$live")
          want_resolved=$(__claude_modes::realpath "$target")
          if [ "$cur_resolved" = "$want_resolved" ]; then
            continue
          fi
          # Otherwise: replace the plugin-owned link with the correct one.
          rm -f "$live"
        else
          # Alien symlink at this basename — preserve, skip create.
          continue
        fi
      else
        # Regular file/dir — alien per R13; preserve, skip create.
        continue
      fi
    fi

    if ln -s "$target" "$live"; then
      __SR_ADDED=$((__SR_ADDED + 1))
    else
      echo "symlink-rebuild: failed to create symlink '${live}' -> '${target}'" >&2
      return 1
    fi
  done <<< "$to_create"

  # ─── Remove plugin-owned symlinks no longer in the manifest ─────
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    live="${live_dir}/${name}"

    # R13 guard: only rm if it's a symlink AND it points under staging.
    if [ ! -L "$live" ]; then
      continue
    fi
    if [ "$(__claude_modes::symlink_targets_under "$live" "$staging")" != "1" ]; then
      # Alien — never touch.
      continue
    fi

    if rm "$live"; then
      __SR_REMOVED=$((__SR_REMOVED + 1))
    else
      echo "symlink-rebuild: failed to remove plugin-owned symlink '${live}'" >&2
      return 1
    fi
  done <<< "$to_remove"

  return 0
}

# ──────────────────────────────────────────────────────────────────────
# Public function.
#
# claude_modes::symlink_rebuild [mode_yaml_path]
#
# Reads the mode's user_catalog manifest (or constructs a day-zero
# manifest from the staging dir if mode_yaml_path is empty), validates
# every entry under R7, then reconciles ~/.claude/commands and
# ~/.claude/agents.
#
# Returns 0 on success (with an audit event), non-zero on validation
# failure (with NO FS mutations — atomic fail-safely contract).
claude_modes::symlink_rebuild() {
  local mode_yaml_path="${1:-}"
  local user_catalog_root="${HOME}/.claude/modes/.user-catalog"
  local commands_staging="${user_catalog_root}/commands"
  local agents_staging="${user_catalog_root}/agents"
  local commands_live="${HOME}/.claude/commands"
  local agents_live="${HOME}/.claude/agents"

  # ─── Build per-category manifest arrays ───────────────────────────
  local -a commands_entries=()
  local -a agents_entries=()

  if [ -n "$mode_yaml_path" ]; then
    # Tier-3 mode: read manifest entries from YAML.
    local line
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      commands_entries+=("$line")
    done < <(claude_modes::get_user_catalog "$mode_yaml_path" "commands" 2>/dev/null)

    while IFS= read -r line; do
      [ -z "$line" ] && continue
      agents_entries+=("$line")
    done < <(claude_modes::get_user_catalog "$mode_yaml_path" "agents" 2>/dev/null)
  else
    # No active mode = Claude Mode. Day-zero manifest = every file
    # currently in the staging dir.
    local f
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      commands_entries+=("$f")
    done < <(__claude_modes::enumerate_staging_files "$commands_staging")

    while IFS= read -r f; do
      [ -z "$f" ] && continue
      agents_entries+=("$f")
    done < <(__claude_modes::enumerate_staging_files "$agents_staging")
  fi

  # ─── PRE-PASS validation: validate BOTH categories before any FS  ─
  # mutations so an attack entry in agents: doesn't get partial
  # symlink creation in commands:. This is the "atomic fail-safely"
  # invariant tested by the integration test.
  if [ "${#commands_entries[@]}" -gt 0 ]; then
    if ! __claude_modes::validate_manifest_entries "$commands_staging" "${commands_entries[@]}"; then
      return 1
    fi
  fi
  if [ "${#agents_entries[@]}" -gt 0 ]; then
    if ! __claude_modes::validate_manifest_entries "$agents_staging" "${agents_entries[@]}"; then
      return 1
    fi
  fi

  # ─── Apply per-category diffs ────────────────────────────────────
  local commands_added=0 commands_removed=0
  local agents_added=0 agents_removed=0

  if ! __claude_modes::symlink_rebuild_category \
      "$commands_live" "$commands_staging" "${commands_entries[@]+"${commands_entries[@]}"}"; then
    return 1
  fi
  commands_added=$__SR_ADDED
  commands_removed=$__SR_REMOVED

  if ! __claude_modes::symlink_rebuild_category \
      "$agents_live" "$agents_staging" "${agents_entries[@]+"${agents_entries[@]}"}"; then
    return 1
  fi
  agents_added=$__SR_ADDED
  agents_removed=$__SR_REMOVED

  # ─── Audit success ───────────────────────────────────────────────
  local mode_field
  if [ -n "$mode_yaml_path" ]; then
    mode_field="$(basename "${mode_yaml_path%.yaml}")"
  else
    mode_field="(none)"
  fi

  claude_modes::audit_event "symlink_rebuild" \
    "mode=${mode_field}" \
    "commands_added=${commands_added}" \
    "commands_removed=${commands_removed}" \
    "agents_added=${agents_added}" \
    "agents_removed=${agents_removed}"

  return 0
}

# Allow direct invocation for debugging:
#   bash lib/symlink-rebuild.sh [mode_yaml_path]
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  claude_modes::symlink_rebuild "${1:-}"
fi
