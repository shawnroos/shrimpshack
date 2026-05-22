#!/usr/bin/env bash
# claude-modes V2 U12: /mode:status — cascade visibility report.
#
# Surfaces, for the current shell:
#   1. The active mode (per-branch pointer, or user-global fallback,
#      or "Claude Mode" if neither resolves).
#   2. Which cascade tiers are visible right now:
#        Tier 1 — ~/.claude/settings.json (always)
#        Tier 2 — ~/.claude/modes/_global.yaml (always)
#        Tier 3 — ~/.claude/modes/<active-mode>.yaml (if mode set)
#        Tier 4 — <repo>/.claude/modes/_repo.yaml (if in a repo + file exists)
#      Each line is marked "contributed" or "inactive".
#   3. The compiled plugin catalog from <repo>/.claude/settings.local.json
#      (if a cascade-meta sidecar is present at the expected path).
#   4. User-catalog inventory: count of plugin-owned symlinks at
#      ~/.claude/commands/ and ~/.claude/agents/.
#   5. Paths to settings.local.json + cascade-meta sidecar for the
#      current repo, when applicable.
#   6. Drift detection: deferred to V2.1 per R23 — display the marker.
#
# Substrate note (read me first): U5 owns lib/active-mode.sh and U6 owns
# lib/install-registry.sh. U12 ships before either lands. We inline the
# minimum bits we need (active-mode resolver lifted from inject-prose.sh,
# installed-repos read directly from the cascade-engine-maintained file)
# so this command works the moment U12 ships, and decouples from
# interface drift in U5/U6.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/mode-yaml.sh"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/sanitize.sh"  # terminal-escape: claude_modes::sanitize_for_display

CLAUDE_MODES_PYTHON3="${CLAUDE_MODES_PYTHON3:-/usr/bin/python3}"

# Inlined active-mode resolver (mirrors lib/inject-prose.sh::__resolve_active_mode).
# Returns the active mode name on stdout, or empty string if none.
# Resolution order:
#   1. <repo>/.claude/modes/<branch-slug>.mode  (per-branch tier-6 pointer)
#   2. ~/.claude/modes/.last-active-mode        (user-global fallback)
#
# Security (sec-001 P0): .mode body validated before path construction.
# Slug-divergence (P1 cluster): detached-HEAD synthesizes `detached-<sha>`
# to match active-mode.sh::current_branch_slug. Behavior-equivalence test
# at tests/integration/active-mode-resolver-equivalence.test.sh.
__claude_modes::status_validate_mode_body() {
  local name="$1"
  [ -z "$name" ] && return 1
  # "claude" is the Claude-Mode sentinel — accept as a valid marker.
  [ "$name" = "claude" ] && return 0
  [ "${#name}" -gt 64 ] && return 1
  case "$name" in
    .|..|*..*) return 1 ;;
    [-_]*|*[-_]) return 1 ;;
  esac
  # Reserved tokens (mirrors CLAUDE_MODES_RESERVED_TOKENS; see
  # lib/inject-prose.sh::__inject_prose::validate_mode_body for rationale).
  case "$name" in
    default|none|set|status|clear|apply|registry|adopt|setup|list|help|promote|rebuild|coverage)
      return 1 ;;
  esac
  if LC_ALL=C printf '%s' "$name" | grep -qE '[^A-Za-z0-9_-]'; then
    return 1
  fi
  return 0
}

# Read a .mode body, edge-stripping only (mirror Python's str.strip()).
# sec-005: see lib/inject-prose.sh::read_mode_body — `tr -d '[:space:]'`
# deleted internal whitespace, diverging from Python's .strip() and letting
# the same .mode file resolve to different modes across read sites.
__claude_modes::status_read_mode_body() {
  local mode_file="$1"
  LC_ALL=C sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' < "$mode_file" 2>/dev/null \
    | head -c 256
}

# Returns 0 if the cascade sidecar's source_modes lists "_repo.yaml" — i.e.
# tier-4 was actually merged (not just present on disk). Ground truth for the
# Tier-4 [contributed] vs [not contributed] display. Returns 1 if the sidecar
# is absent/unreadable or _repo.yaml is not in source_modes.
__claude_modes::status_sidecar_lists_repo() {
  local sidecar="$1"
  [ -n "$sidecar" ] && [ -f "$sidecar" ] || return 1
  "$CLAUDE_MODES_PYTHON3" - "$sidecar" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
except Exception:
    sys.exit(1)
sm = data.get("source_modes") or []
sys.exit(0 if "_repo.yaml" in sm else 1)
PYEOF
}

__claude_modes::status_slugify_branch() {
  local branch="$1"
  [ -z "$branch" ] && return 1
  local slug
  slug=$(LC_ALL=C printf '%s' "$branch" | LC_ALL=C tr -c 'A-Za-z0-9_-' '-')
  slug=$(printf '%s' "$slug" | sed -E 's/-+/-/g; s/^-+//; s/-+$//')
  [ -z "$slug" ] && return 1
  case "$slug" in .|..|*..*) return 1 ;; esac
  printf '%s' "$slug"
}

__claude_modes::status_resolve_active_mode() {
  local branch_slug short_sha repo_root mode_file content=""

  if repo_root=$(git rev-parse --show-toplevel 2>/dev/null) && [ -n "$repo_root" ]; then
    if branch_slug=$(git symbolic-ref --short -q HEAD 2>/dev/null) && [ -n "$branch_slug" ]; then
      branch_slug=$(__claude_modes::status_slugify_branch "$branch_slug") || branch_slug=""
    else
      if short_sha=$(git rev-parse --short HEAD 2>/dev/null) && [ -n "$short_sha" ]; then
        branch_slug=$(__claude_modes::status_slugify_branch "detached-${short_sha}") || branch_slug=""
      fi
    fi
    if [ -n "$branch_slug" ]; then
      mode_file="${repo_root}/.claude/modes/${branch_slug}.mode"
      if [ -f "$mode_file" ]; then
        content=$(__claude_modes::status_read_mode_body "$mode_file")
        if __claude_modes::status_validate_mode_body "$content"; then
          printf '%s' "$content"
          return 0
        fi
        content=""
      fi
    fi
  fi

  mode_file="${HOME}/.claude/modes/.last-active-mode"
  if [ -f "$mode_file" ]; then
    content=$(__claude_modes::status_read_mode_body "$mode_file")
    if __claude_modes::status_validate_mode_body "$content"; then
      printf '%s' "$content"
      return 0
    fi
  fi

  return 0
}

# Count plugin-owned symlinks under a live dir whose targets resolve under
# the user-catalog staging dir. Returns count on stdout.
# A "plugin-owned" symlink for purposes of /mode:status is one whose
# realpath-resolved target lives under ~/.claude/modes/.user-catalog/.
__claude_modes::status_count_user_catalog() {
  local live_dir="$1"
  local staging_root="${HOME}/.claude/modes/.user-catalog"

  if [ ! -d "$live_dir" ]; then
    printf '0'
    return 0
  fi

  "$CLAUDE_MODES_PYTHON3" - "$live_dir" "$staging_root" <<'PYEOF'
import os, sys
live = sys.argv[1]
staging = os.path.realpath(sys.argv[2])
count = 0
try:
    entries = os.listdir(live)
except OSError:
    print(0)
    sys.exit(0)
for name in entries:
    p = os.path.join(live, name)
    if not os.path.islink(p):
        continue
    try:
        resolved = os.path.realpath(p)
    except OSError:
        continue
    # Match if the realpath sits anywhere under the staging root.
    rel = os.path.relpath(resolved, staging)
    if not rel.startswith(".."):
        count += 1
print(count)
PYEOF
}

# Pretty-print enabledPlugins from a compiled settings.local.json.
# One line per entry: "  plugin@market: true|false".
__claude_modes::status_print_plugin_catalog() {
  local settings_path="$1"
  if [ ! -f "$settings_path" ]; then
    echo "  (no compiled settings.local.json; run /mode:set or /mode:apply)"
    return 0
  fi
  "$CLAUDE_MODES_PYTHON3" - "$settings_path" <<'PYEOF'
import json, sys, unicodedata
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
except Exception as e:
    print(f"  (settings.local.json present but unreadable: {e})")
    sys.exit(0)
ep = data.get("enabledPlugins") or {}
if not isinstance(ep, dict) or not ep:
    print("  (enabledPlugins is empty)")
    sys.exit(0)
# terminal-escape: plugin KEYS can originate from a hostile _repo.yaml (the
# cascade merges them verbatim into settings.local.json). The trust gate shows
# a sanitized rendering at consent time, but /mode:status re-displays them —
# so strip Cc+Cf here too (matches claude_modes::sanitize_for_display).
def _san(s):
    return "".join(c for c in s if unicodedata.category(c) not in ("Cc", "Cf"))
for key in sorted(ep.keys()):
    val = ep[key]
    print(f"  {_san(key)}: {str(val).lower()}")
PYEOF
}

# claude_modes::status
#
# The user-facing /mode:status entry point. All output goes to stdout;
# diagnostics about missing files are inline (no stderr noise).
claude_modes::status() {
  local active_mode
  active_mode=$(__claude_modes::status_resolve_active_mode)

  # Resolve repo root (if any) for tier-4 + compiled-settings lookups.
  local repo_root=""
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || repo_root=""

  local tier_1_path="${HOME}/.claude/settings.json"
  local tier_2_path="${HOME}/.claude/modes/_global.yaml"
  local tier_3_path=""
  if [ -n "$active_mode" ]; then
    tier_3_path="${HOME}/.claude/modes/${active_mode}.yaml"
  fi
  local tier_4_path=""
  if [ -n "$repo_root" ]; then
    tier_4_path="${repo_root}/.claude/modes/_repo.yaml"
  fi

  local settings_local=""
  local sidecar=""
  if [ -n "$repo_root" ]; then
    settings_local="${repo_root}/.claude/settings.local.json"
    sidecar="${repo_root}/.claude/modes/.cascade-meta.json"
  fi

  # terminal-escape (round-5): repo_root is mixed-use — the RAW value builds
  # tier_4_path/settings_local/sidecar which are [ -f ]-tested + read from
  # disk, so we can't sanitize repo_root at source (would break the FS reads).
  # Instead build sanitized DISPLAY variants and use ONLY those in every
  # echo/printf below. Raw vars stay for FS ops; display vars for the terminal.
  local tier_4_path_d settings_local_d sidecar_d
  tier_4_path_d=$(claude_modes::sanitize_for_display "$tier_4_path")
  settings_local_d=$(claude_modes::sanitize_for_display "$settings_local")
  sidecar_d=$(claude_modes::sanitize_for_display "$sidecar")

  # ─── Header: active mode ──────────────────────────────────────────
  echo "claude-modes /mode:status"
  echo "========================="
  echo ""
  if [ -z "$active_mode" ]; then
    echo "Active mode: claude (no modes active)"
  else
    echo "Active mode: ${active_mode}"
  fi

  if [ -n "$repo_root" ]; then
    local branch=""
    branch=$(git symbolic-ref --short -q HEAD 2>/dev/null) || branch="(detached)"
    # terminal-escape: repo_root (clone path) and the RAW branch name are both
    # attacker-influenceable (a hostile repo can be cloned into a crafted dir
    # name; git accepts bidi/control bytes in branch names). Sanitize before
    # display so /mode:status can't be turned into a terminal-injection sink.
    echo "Current repo: $(claude_modes::sanitize_for_display "$repo_root")"
    echo "Current branch: $(claude_modes::sanitize_for_display "$branch")"
  else
    echo "Current repo: (not in a git working tree)"
  fi
  echo ""

  # ─── Cascade tiers visible ────────────────────────────────────────
  echo "Cascade tiers visible:"
  if [ -f "$tier_1_path" ]; then
    printf '  Tier 1 [contributed]: %s\n' "$tier_1_path"
  else
    printf '  Tier 1 [inactive]:    %s (missing)\n' "$tier_1_path"
  fi

  if [ -f "$tier_2_path" ]; then
    printf '  Tier 2 [contributed]: %s\n' "$tier_2_path"
  else
    printf '  Tier 2 [inactive]:    %s (missing — run /mode:setup)\n' "$tier_2_path"
  fi

  if [ -z "$active_mode" ]; then
    printf '  Tier 3 [inactive]:    (no active mode — Claude Mode)\n'
  elif [ -f "$tier_3_path" ]; then
    printf '  Tier 3 [contributed]: %s\n' "$tier_3_path"
  else
    printf '  Tier 3 [inactive]:    %s (active mode set but YAML missing)\n' "$tier_3_path"
  fi

  if [ -z "$repo_root" ]; then
    printf '  Tier 4 [inactive]:    (not in a git working tree)\n'
  elif [ ! -f "$tier_4_path" ]; then
    printf '  Tier 4 [inactive]:    %s (no _repo.yaml in this repo)\n' "$tier_4_path_d"
  else
    # _repo.yaml EXISTS on disk, but existence ≠ contribution. The trust
    # gate may have declined it (R30) — in which case the cascade excluded
    # tier-4 and the sidecar's source_modes will NOT list "_repo.yaml". Read
    # the sidecar (ground truth) instead of file existence (agent-native
    # re-review finding: file-existence gave a false [contributed]).
    if __claude_modes::status_sidecar_lists_repo "$sidecar"; then
      printf '  Tier 4 [contributed]: %s\n' "$tier_4_path_d"
    else
      printf '  Tier 4 [not contributed]: %s (present but not merged — trust gate not granted, or cascade not yet run)\n' "$tier_4_path_d"
    fi
  fi
  echo ""

  # ─── Compiled plugin catalog ──────────────────────────────────────
  echo "Compiled plugin catalog (enabledPlugins):"
  if [ -n "$repo_root" ]; then
    __claude_modes::status_print_plugin_catalog "$settings_local"
  else
    echo "  (not in a repo; no per-repo settings.local.json)"
  fi
  echo ""

  # ─── User catalog inventory ───────────────────────────────────────
  local cmd_count agent_count
  cmd_count=$(__claude_modes::status_count_user_catalog "${HOME}/.claude/commands")
  agent_count=$(__claude_modes::status_count_user_catalog "${HOME}/.claude/agents")
  echo "User catalog (plugin-owned symlinks under ~/.claude/):"
  echo "  commands: ${cmd_count}"
  echo "  agents:   ${agent_count}"
  echo ""

  # ─── Path summary ─────────────────────────────────────────────────
  echo "Paths:"
  if [ -n "$repo_root" ]; then
    if [ -f "$settings_local" ]; then
      echo "  compiled settings: ${settings_local_d}"
    else
      echo "  compiled settings: ${settings_local_d} (not yet written)"
    fi
    if [ -f "$sidecar" ]; then
      echo "  cascade-meta:      ${sidecar_d}"
    else
      echo "  cascade-meta:      ${sidecar_d} (not yet written)"
    fi
  else
    echo "  compiled settings: (not in a repo)"
    echo "  cascade-meta:      (not in a repo)"
  fi
  echo ""

  # ─── Drift detection notice (R23 deferral) ────────────────────────
  echo "Drift detection deferred to V2.1."

  return 0
}

# Allow direct invocation for testing and command dispatch:
#   bash lib/status.sh
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  claude_modes::status
fi
