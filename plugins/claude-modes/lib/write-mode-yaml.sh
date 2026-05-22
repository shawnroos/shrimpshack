#!/usr/bin/env bash
# claude-modes V2: mechanical mode-YAML writer with R22 enforcement.
#
# Why this exists:
#   - V1's mode-author skill wrote YAML via inline `cat > <path> << EOF`,
#     which bypassed validation. Closed during V1 review (R26 enforcement
#     bypass P1 — the skill needed to route through this library).
#   - V2 inherits the same need: every write to ~/.claude/modes/<name>.yaml
#     OR <repo>/.claude/modes/_repo.yaml goes through this function so
#     R22 (claude-modes must be enabled) is mechanically enforced.
#
# V2 specifics:
#   - Mode YAMLs (tier 3) must declare schema_version: 2
#   - Mode YAMLs may NOT declare a hooks key under mechanism: (R28 invariant)
#   - Mode YAMLs must include claude-modes@<marketplace>: true in
#     enabledPlugins of the cascade total (this writer accepts mode YAMLs
#     that don't include claude-modes IF _global.yaml will provide it;
#     the cascade engine asserts the total at /mode:set time, not here)
#
# Atomic write idiom (V1 carry-forward):
#   1. (umask 077 && mktemp <dir>/.tmp.XXXXXX) — born at 0600
#   2. Write content to tmp
#   3. Validate the tmp file with the same parser the cascade engine uses
#   4. mv tmp <target> — atomic same-filesystem rename

# shellcheck disable=SC1091
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/mode-yaml.sh"
. "${SCRIPT_DIR}/validate-mode-name.sh"

CLAUDE_MODES_PYTHON3="${CLAUDE_MODES_PYTHON3:-/usr/bin/python3}"

# claude_modes::write_mode_yaml <path> <yaml_content>
#
# Atomically writes <yaml_content> to <path> after validating it.
#
# Validation steps (all must pass; first failure exits non-zero):
#   1. <path> must be under ~/.claude/modes/ OR under <repo>/.claude/modes/
#      (never an arbitrary path — prevents the writer being misused to
#      clobber arbitrary files)
#   2. yaml.safe_load succeeds on the content
#   3. schema_version == 2
#   4. If this is a tier-3 mode YAML (not _global.yaml, not _repo.yaml):
#      - mechanism.hooks must NOT be present (R28 invariant)
#      - mode name (from filename) passes claude_modes::validate_name
#
# Atomic-write idiom:
#   (umask 077 && mktemp ... && write && mv ...)
#
# Returns 0 on success, non-zero on validation failure.
claude_modes::write_mode_yaml() {
  local target_path="$1"
  local yaml_content="$2"

  # ─── 1. Path safety ───────────────────────────────────────────────
  local global_modes_dir="${HOME}/.claude/modes"
  local resolved_target
  resolved_target=$("$CLAUDE_MODES_PYTHON3" -c \
    "import os.path,sys; print(os.path.realpath(sys.argv[1]))" \
    "$target_path" 2>/dev/null)
  local resolved_global
  resolved_global=$("$CLAUDE_MODES_PYTHON3" -c \
    "import os.path,sys; print(os.path.realpath(sys.argv[1]))" \
    "$global_modes_dir" 2>/dev/null)

  local in_global=0 in_repo=0
  case "$resolved_target" in
    "$resolved_global"/*)
      in_global=1
      ;;
  esac

  # Check repo-modes-dir if we're in a git repo.
  if [ "$in_global" -eq 0 ]; then
    if repo_root=$(git -C "$(dirname "$target_path")" rev-parse --show-toplevel 2>/dev/null); then
      local repo_modes_dir="${repo_root}/.claude/modes"
      local resolved_repo
      resolved_repo=$("$CLAUDE_MODES_PYTHON3" -c \
        "import os.path,sys; print(os.path.realpath(sys.argv[1]))" \
        "$repo_modes_dir" 2>/dev/null)
      case "$resolved_target" in
        "$resolved_repo"/*)
          in_repo=1
          ;;
      esac
    fi
  fi

  if [ "$in_global" -eq 0 ] && [ "$in_repo" -eq 0 ]; then
    echo "write-mode-yaml: target path '${target_path}' is not under ~/.claude/modes/ or <repo>/.claude/modes/ — refusing to write" >&2
    return 1
  fi

  # ─── 2. Determine tier (3 = mode YAML, 2 = _global, 4 = _repo) ────
  local basename
  basename="$(basename "$target_path")"
  local mode_name="${basename%.yaml}"

  local tier="mode"  # default: tier 3 mode YAML
  case "$mode_name" in
    _global)
      tier="global"
      ;;
    _repo)
      tier="repo"
      ;;
    *)
      # tier 3 — validate the mode name now
      if ! claude_modes::validate_name "$mode_name"; then
        echo "write-mode-yaml: mode name '${mode_name}' (from filename) fails validation" >&2
        return 1
      fi
      ;;
  esac

  # ─── 3. Stage to tmp file (born at 0600), write content, validate ─
  local target_dir
  target_dir="$(dirname "$target_path")"
  if [ ! -d "$target_dir" ]; then
    mkdir -p "$target_dir" || {
      echo "write-mode-yaml: could not create target dir '${target_dir}'" >&2
      return 1
    }
  fi

  local tmp
  tmp=$( (umask 077 && mktemp "${target_dir}/.write-mode-yaml.XXXXXX") ) || {
    echo "write-mode-yaml: mktemp failed in ${target_dir}" >&2
    return 1
  }
  trap 'rm -f "$tmp"' RETURN

  printf '%s' "$yaml_content" > "$tmp" || {
    echo "write-mode-yaml: write to tmp file failed" >&2
    return 1
  }

  # ─── 4. Parse + schema_version: 2 check (reuses mode-yaml.sh) ─────
  if ! claude_modes::validate_schema_version "$tmp"; then
    echo "write-mode-yaml: refusing to write '${target_path}' — schema_version check failed (see prior error)" >&2
    return 1
  fi

  # ─── 5. Tier-3 R28 enforcement (no hooks in mode YAMLs) ───────────
  if [ "$tier" = "mode" ]; then
    if __claude_modes::py_yaml_query "$tmp" '
mech = data.get("mechanism") or {}
if "hooks" in mech:
    sys.stderr.write("write-mode-yaml: R28 violation — tier-3 mode YAML may not declare mechanism.hooks; hooks belong in ~/.claude/settings.json (machine-wide) or <repo>/.claude/hooks/hooks.json (per-repo), not in any cascade YAML (the V2.0 cascade only flows enabledPlugins)\n")
    sys.exit(1)
' ; then
      :  # No hooks declared — good.
    else
      return 1
    fi
  fi

  # ─── 6. Atomic mv into place ──────────────────────────────────────
  mv "$tmp" "$target_path" || {
    echo "write-mode-yaml: atomic mv from '${tmp}' to '${target_path}' failed" >&2
    return 1
  }
  trap - RETURN

  # ─── 7. Defensive chmod 0600 (born at 0600 already, but defense    ─
  #        in depth — if mv changed perms somehow, restore them). ────
  if [ ! -L "$target_path" ]; then
    chmod 0600 "$target_path" 2>/dev/null || true
  fi

  return 0
}

# Allow direct invocation for testing:
#   echo "<yaml>" | bash lib/write-mode-yaml.sh <path>
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <target-path> < <yaml-content>" >&2
    exit 2
  fi
  yaml_in=$(cat)
  claude_modes::write_mode_yaml "$1" "$yaml_in"
fi
