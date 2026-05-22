#!/usr/bin/env bash
# claude-modes V2 (U6): /mode:setup install orchestrator.
#
# Bootstraps claude-modes V2 in a fresh Claude Code environment:
#   1. Presence check — refuses re-install unless a crashed prior run
#      left .setup.in-progress; in that case, resumes idempotently.
#   1a. Writes .setup.in-progress sentinel (R26 crash-safety).
#   2. Pristine capture — born-at-0600 cp of ~/.claude/settings.json to
#      ~/.claude/settings.json.pristine (forensic anchor only).
#   3. Generates _global.yaml from pristine's enabledPlugins ONLY (V2.0
#      scope cut — other settings keys stay in settings.json untouched).
#      R22 enforcement: synthesizes "claude-modes@local-dev: true" if the
#      user's pristine doesn't already carry a claude-modes marketplace
#      identifier; emits a one-time .first-install.notice.
#   4. Moves user-authored ~/.claude/commands/*.md and agents/*.md into
#      ~/.claude/modes/.user-catalog/<category>/ and symlinks them back.
#      Pre-flight: symlinks preserved in place; hard-linked files trigger
#      hard-fail with explicit remediation; cross-filesystem fallback uses
#      cp + sha256 verify + rm.
#   5. Seeds discovery.yaml + delivery.yaml from examples/.
#   6. Archives any pre-existing schema_version: 1 mode YAMLs to
#      ~/.claude/modes/.v1-archive/.
#   7. Creates the install registry at ~/.claude/modes/.installed-repos.txt
#      (born-at-0600, initially empty).
#   8. Initial symlink rebuild with NO mode active (Claude Mode = include
#      all) to materialize the day-zero topology.
#   9. Audit event + clears sentinel.
#
# R26 contract: every step is idempotent. If a SIGKILL fires mid-step,
# re-running `/mode:setup` converges on the same end state.
#
# Test hooks (env-var triggered, used by integration tests only — DO NOT
# rely on these in production paths):
#   CLAUDE_MODES_SETUP_TEST_INTERRUPT_AFTER_MOVES=<N>
#     Simulates a crash by exiting 137 after the Nth user-catalog file
#     move. Reliable substitute for racing real signals in CI.

set -uo pipefail

# ──────────────────────────────────────────────────────────────────────
# Resolve plugin root and source libs.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/lib/validate-mode-name.sh"
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/lib/mode-yaml.sh"
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/lib/write-mode-yaml.sh"
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/lib/install-registry.sh"
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/lib/audit.sh"
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/lib/symlink-rebuild.sh"
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/lib/cascade-engine.sh"  # __claude_modes::resolve_self_identifier

CLAUDE_MODES_PYTHON3="${CLAUDE_MODES_PYTHON3:-/usr/bin/python3}"

# ──────────────────────────────────────────────────────────────────────
# Paths.
MODES_DIR="${HOME}/.claude/modes"
SENTINEL="${MODES_DIR}/.setup.in-progress"
GLOBAL_YAML="${MODES_DIR}/_global.yaml"
NOTICE_FILE="${MODES_DIR}/.first-install.notice"
SKIP_LIST="${MODES_DIR}/.setup-skip-list"
V1_ARCHIVE="${MODES_DIR}/.v1-archive"
USER_CATALOG="${MODES_DIR}/.user-catalog"
COMMANDS_LIVE="${HOME}/.claude/commands"
AGENTS_LIVE="${HOME}/.claude/agents"
COMMANDS_STAGING="${USER_CATALOG}/commands"
AGENTS_STAGING="${USER_CATALOG}/agents"
SETTINGS_JSON="${HOME}/.claude/settings.json"
PRISTINE="${HOME}/.claude/settings.json.pristine"

# Plugin version (for audit event).
PLUGIN_VERSION="0.2.0"

# Move counter (incremented per successful catalog file move; used by
# the test interrupt hook).
MOVED_COUNT=0

# ──────────────────────────────────────────────────────────────────────
# Logging helpers.
_log() { printf '/mode:setup: %s\n' "$1"; }
_err() { printf '/mode:setup: %s\n' "$1" >&2; }

# Cross-platform stat helpers (macOS vs Linux flag differences).
_stat_link_count() {
  if [ "$(uname)" = "Darwin" ]; then
    stat -f '%l' "$1" 2>/dev/null
  else
    stat -c '%h' "$1" 2>/dev/null
  fi
}

_stat_device_id() {
  if [ "$(uname)" = "Darwin" ]; then
    stat -f '%d' "$1" 2>/dev/null
  else
    stat -c '%d' "$1" 2>/dev/null
  fi
}

# Path realpath via pinned Python (portable across macOS sans coreutils).
_realpath() {
  "$CLAUDE_MODES_PYTHON3" -c \
    'import os.path,sys; print(os.path.realpath(sys.argv[1]))' \
    "$1" 2>/dev/null
}

# Test interrupt hook — fires after the Nth catalog file move if the
# env var is set. Used by integration tests to simulate a crash
# deterministically (no race with real signals).
_maybe_test_interrupt() {
  local n="${CLAUDE_MODES_SETUP_TEST_INTERRUPT_AFTER_MOVES:-}"
  if [ -n "$n" ] && [ "$MOVED_COUNT" = "$n" ]; then
    _err "TEST HOOK: simulated crash after ${n} moves (sentinel persists)"
    exit 137
  fi
}

# ──────────────────────────────────────────────────────────────────────
# Step 1: Presence check.
#
# Refuse re-install if _global.yaml exists AND no sentinel. If sentinel
# exists → log resume and continue (each step is idempotent).
step_presence_check() {
  if [ -e "$SENTINEL" ]; then
    _log "resuming previous /mode:setup (.setup.in-progress sentinel found)"
    return 0
  fi

  if [ -f "$GLOBAL_YAML" ]; then
    _err "claude-modes is already installed (${GLOBAL_YAML} exists)."
    _err "Run scripts/unmodes.sh to uninstall first, or delete _global.yaml manually to force a re-install."
    exit 1
  fi
}

# ──────────────────────────────────────────────────────────────────────
# Step 1a: Write sentinel.
step_write_sentinel() {
  if [ ! -d "$MODES_DIR" ]; then
    mkdir -m 0700 -p "$MODES_DIR"
  fi
  (umask 077 && : > "$SENTINEL") || {
    _err "could not write sentinel at ${SENTINEL}"
    exit 1
  }
  # Re-assert perms in case file pre-existed at weaker mode.
  if [ ! -L "$SENTINEL" ]; then
    chmod 0600 "$SENTINEL" 2>/dev/null || true
  fi
}

# ──────────────────────────────────────────────────────────────────────
# Step 2: Pristine capture.
#
# Born-at-0600 ALLOWLIST-FILTERED snapshot of settings.json →
# settings.json.pristine. If pristine already exists (resume case), skip.
#
# sec-006/adv-012: the old capture cp'd the WHOLE settings.json — a snapshot
# of secrets (apiKeyHelper, mcpServers credentials, env tokens) that lived
# at 0600 forever (unmodes.sh preserves it as a "forensic anchor"). The
# pristine is only ever read by step_generate_global, which uses
# `enabledPlugins`. So we snapshot ONLY a small allowlist of structural,
# non-secret keys — no secret material ever enters the file.
#
# Allowlist (not denylist): a denylist would leak any NEW secret key Claude
# Code adds until we update it. We keep enabledPlugins (operationally
# required) plus theme + statusLine (cosmetic; useful if V2.1 revives
# drift-diff). Everything else is dropped.
#
# NOTE: pre-V2.1 pristines created by an older setup.sh may STILL contain
# secrets — we do NOT silently rewrite a pre-existing pristine (it may be a
# forensic anchor the user relies on). Use `unmodes.sh --purge-pristine` to
# remove one explicitly.
PRISTINE_ALLOWLIST_KEYS="enabledPlugins theme statusLine"
step_pristine_capture() {
  if [ -f "$PRISTINE" ]; then
    _log "pristine already exists; preserving it (resume-safe)"
    return 0
  fi

  if [ ! -f "$SETTINGS_JSON" ]; then
    _log "no ${SETTINGS_JSON}; skipping pristine capture"
    return 0
  fi

  local tmp
  tmp=$( (umask 077 && mktemp "${PRISTINE}.XXXXXX") ) || {
    _err "mktemp failed for pristine capture"
    exit 1
  }

  # Filter settings.json to the allowlist; write JSON to tmp. Fail closed.
  if ! "$CLAUDE_MODES_PYTHON3" - "$SETTINGS_JSON" "$tmp" $PRISTINE_ALLOWLIST_KEYS <<'PYEOF'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
allow = set(sys.argv[3:])
try:
    with open(src) as f:
        data = json.load(f) or {}
except Exception as e:
    sys.stderr.write("pristine filter: cannot parse {}: {}\n".format(src, e))
    sys.exit(1)
filtered = {k: v for k, v in data.items() if k in allow}
with open(dst, "w") as f:
    json.dump(filtered, f, indent=2, sort_keys=True)
    f.write("\n")
PYEOF
  then
    rm -f "$tmp"
    _err "pristine allowlist filter failed"
    exit 1
  fi

  if ! mv "$tmp" "$PRISTINE"; then
    rm -f "$tmp"
    _err "atomic mv failed for pristine capture"
    exit 1
  fi
  if [ ! -L "$PRISTINE" ]; then
    chmod 0600 "$PRISTINE" 2>/dev/null || true
  fi
  _log "captured pristine settings (allowlist-filtered) → ${PRISTINE}"
}

# ──────────────────────────────────────────────────────────────────────
# Step 3: Generate _global.yaml from pristine.
#
# Read pristine's enabledPlugins ONLY (V2.0 scope cut). If claude-modes
# isn't in the user's enabledPlugins (typical pre-publication first run),
# add the synthetic identifier "claude-modes@local-dev: true" and
# leave a .first-install.notice for U10's prose hook to surface.
step_generate_global() {
  if [ -f "$GLOBAL_YAML" ]; then
    _log "_global.yaml already exists; preserving it (resume-safe)"
    return 0
  fi

  # Extract enabledPlugins from pristine (or default to empty if no
  # pristine — e.g., fresh user with no prior settings.json).
  local plugins_block notice_needed
  plugins_block=""
  notice_needed=0

  if [ -f "$PRISTINE" ]; then
    # Use the pinned Python to parse pristine JSON and emit a YAML
    # mapping body for enabledPlugins, plus a flag indicating whether
    # claude-modes was already present.
    local result
    result=$("$CLAUDE_MODES_PYTHON3" - "$PRISTINE" <<'PYEOF'
import json, sys
path = sys.argv[1]
try:
    with open(path) as f:
        data = json.load(f) or {}
except (json.JSONDecodeError, OSError):
    data = {}
ep = data.get("enabledPlugins") or {}
# Detect any claude-modes@<marketplace> identifier so we don't double-add.
has_claude_modes = any(
    isinstance(k, str) and k.split("@", 1)[0] == "claude-modes"
    for k in ep.keys()
)
# Print "HAS=1" or "HAS=0" then a sentinel line, then each entry.
print("HAS=1" if has_claude_modes else "HAS=0")
print("---ENTRIES---")
# Emit in a deterministic order.
for key in sorted(ep.keys()):
    val = ep[key]
    # Coerce to YAML bool literal — only true/false are meaningful.
    val_str = "true" if val else "false"
    # Quote the key always for safety with @ and : in marketplace ids.
    safe_key = key.replace('"', '\\"')
    print(f'    "{safe_key}": {val_str}')
PYEOF
)
    local has_line entries
    has_line=$(printf '%s\n' "$result" | head -n 1)
    entries=$(printf '%s\n' "$result" | sed -n '/^---ENTRIES---$/,$p' | tail -n +2)

    if [ "$has_line" = "HAS=0" ]; then
      notice_needed=1
    fi
    plugins_block="$entries"
  else
    # No pristine at all → empty user enabledPlugins; we add claude-modes.
    notice_needed=1
  fi

  # R22: ensure claude-modes is present in the cascade total. Resolve the
  # ACTUAL installed identifier (marketplace install → "claude-modes@<mkt>",
  # e.g. "claude-modes@shrimpshack") rather than hardcoding the synthetic
  # "claude-modes@local-dev". resolve_self_identifier falls back to
  # "claude-modes@local-dev" only when there is genuinely no marketplace
  # registry match — so this is strictly better: it uses the real id when one
  # exists, and local-dev only pre-publication. (Hardcoding local-dev here was
  # the third manifestation of the registry-shape resolver bug: even after the
  # resolver was fixed, setup wrote local-dev → compiled a phantom plugin and
  # dropped the real one. See lib/cascade-engine.sh resolver + Scenario 11.)
  local self_id
  self_id=$(__claude_modes::resolve_self_identifier 2>/dev/null)
  [ -z "$self_id" ] && self_id="claude-modes@local-dev"
  if [ "$notice_needed" -eq 1 ]; then
    if [ -n "$plugins_block" ]; then
      plugins_block="${plugins_block}"$'\n'"    \"${self_id}\": true"
    else
      plugins_block="    \"${self_id}\": true"
    fi
  fi

  # If after all of that there are STILL no entries (shouldn't happen, but
  # defensive), emit at least claude-modes.
  if [ -z "$plugins_block" ]; then
    plugins_block="    \"${self_id}\": true"
  fi

  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "unknown-time")

  local content
  content="schema_version: 2
name: _global
description: |
  Auto-generated by /mode:setup at ${ts} from
  ~/.claude/settings.json.pristine. Always-active baseline of plugins
  enabled across all modes on this machine. Mode YAMLs cascade ON TOP
  of this; the result becomes <repo>/.claude/settings.local.json after
  /mode:set + /reload-plugins.

mechanism:
  enabledPlugins:
${plugins_block}
"

  if ! claude_modes::write_mode_yaml "$GLOBAL_YAML" "$content"; then
    _err "failed to write ${GLOBAL_YAML} via write-mode-yaml"
    exit 1
  fi
  _log "generated ${GLOBAL_YAML} from pristine enabledPlugins"

  # Surface the one-time notice (consumed by U10's prose hook on next
  # prompt). Only write if notice was needed and notice doesn't already
  # exist (idempotent).
  if [ "$notice_needed" -eq 1 ] && [ ! -f "$NOTICE_FILE" ]; then
    local notice_content
    notice_content="claude-modes auto-added as \"${self_id}\" to your _global.yaml because it was not already in ~/.claude/settings.json::enabledPlugins. If this says \"@local-dev\" you are running a pre-publication/dev checkout; once installed from a marketplace, re-run /mode:setup (or edit ~/.claude/modes/_global.yaml) so the canonical marketplace identifier is used."
    (umask 077 && printf '%s\n' "$notice_content" > "$NOTICE_FILE") || \
      _err "could not write first-install notice"
    if [ -f "$NOTICE_FILE" ] && [ ! -L "$NOTICE_FILE" ]; then
      chmod 0600 "$NOTICE_FILE" 2>/dev/null || true
    fi
    _log "wrote first-install notice → ${NOTICE_FILE}"
  fi
}

# ──────────────────────────────────────────────────────────────────────
# Step 4: Move user catalog.
#
# For each *.md file in ~/.claude/commands/ and ~/.claude/agents/:
#   - If skip-list contains the path → leave it alone.
#   - If it's a symlink → preserve in place (alien-symlink protection R7).
#   - If it has hard links (link count > 1) → HARD-FAIL with remediation.
#   - Otherwise → atomic mv to .user-catalog/<category>/<basename>, then
#     ln -s back to original path.
#   - Cross-filesystem fallback: cp + sha256 verify + rm.
#
# Resume-safe: if the original path is already a symlink pointing into
# the staging area, the file's been moved before — skip and continue.
step_move_user_catalog() {
  # Pre-create staging dirs at 0700.
  mkdir -m 0700 -p "$COMMANDS_STAGING"
  mkdir -m 0700 -p "$AGENTS_STAGING"

  # Load skip-list once (one path per line; lines starting with # ignored).
  local -a skip_paths=()
  if [ -f "$SKIP_LIST" ]; then
    local line
    while IFS= read -r line; do
      case "$line" in
        ''|\#*) continue ;;
        *) skip_paths+=("$line") ;;
      esac
    done < "$SKIP_LIST"
  fi

  # rel-001 (R26): pre-flight BOTH categories before mutating EITHER. The
  # per-category two-pass alone is insufficient — running commands' PASS 2
  # (mutate) before agents' PASS 1 (pre-flight) means a hard-link in agents
  # aborts AFTER commands were already moved+symlinked, so the "no files
  # moved" promise is a lie. Lifting both pre-flights ahead of both applies
  # restores atomic-fail-before-any-mutation across the whole step.
  _preflight_category "$COMMANDS_LIVE" "commands" "${skip_paths[@]+"${skip_paths[@]}"}"
  _preflight_category "$AGENTS_LIVE"   "agents"   "${skip_paths[@]+"${skip_paths[@]}"}"

  _apply_category "$COMMANDS_LIVE" "$COMMANDS_STAGING" "commands" "${skip_paths[@]+"${skip_paths[@]}"}"
  _apply_category "$AGENTS_LIVE"   "$AGENTS_STAGING"   "agents"   "${skip_paths[@]+"${skip_paths[@]}"}"
}

# _enumerate_md_files <live_dir>  → prints *.md entries (files + symlinks),
# one per line, sorted; nothing if dir absent/empty.
_enumerate_md_files() {
  local live_dir="$1"
  [ -d "$live_dir" ] || return 0
  find -P "$live_dir" -maxdepth 1 -name '*.md' \( -type f -o -type l \) 2>/dev/null | sort
}

# _is_skip_listed <file> [skip_paths...]  → 0 if file is skip-listed.
_is_skip_listed() {
  local file="$1"; shift
  local sp
  for sp in "$@"; do
    [ "$sp" = "$file" ] && return 0
  done
  return 1
}

# _preflight_category <live_dir> <category_label> [skip_paths...]
#
# PASS 1 of the user-catalog move: validate every *.md file in live_dir
# WITHOUT any FS mutation. Hard-fails (exit 1) if any non-skip, non-symlink
# file has hard links — moving it would silently break the other links.
# Creates live_dir if absent (the only FS effect, and it's idempotent +
# non-destructive). Called for EVERY category before ANY apply runs, so a
# hard-link anywhere aborts before the first move (rel-001 / R26).
_preflight_category() {
  local live_dir="$1"
  local label="$2"
  shift 2
  local -a skip_paths=("$@")

  if [ ! -d "$live_dir" ]; then
    _log "${label}: no ${live_dir} (creating empty)"
    mkdir -p "$live_dir"
    return 0
  fi

  local -a files=()
  local f
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    files+=("$f")
  done < <(_enumerate_md_files "$live_dir")

  if [ "${#files[@]}" -eq 0 ]; then
    _log "${label}: no *.md files to move"
    return 0
  fi

  local file basename_f link_count
  for file in "${files[@]}"; do
    basename_f="$(basename "$file")"

    # Skip-listed or alien symlink — no pre-flight check needed.
    _is_skip_listed "$file" "${skip_paths[@]+"${skip_paths[@]}"}" && continue
    [ -L "$file" ] && continue

    # Hard-link check.
    link_count=$(_stat_link_count "$file")
    if [ -n "$link_count" ] && [ "$link_count" -gt 1 ] 2>/dev/null; then
      _err ""
      _err "HARD-FAIL: ${file} has ${link_count} hard links."
      _err ""
      _err "claude-modes refuses to move hard-linked files because moving"
      _err "them would silently break the other links. Remediation options:"
      _err ""
      _err "  (a) Break the hard link by copying through a temp file:"
      _err "        cp \"${file}\" \"${file}.tmp\" && rm \"${file}\" && mv \"${file}.tmp\" \"${file}\""
      _err "      Then re-run /mode:setup."
      _err ""
      _err "  (b) Add the path to ${SKIP_LIST} (one path per line)"
      _err "      to leave it as a regular global file (visible in every"
      _err "      mode, never scoped by claude-modes)."
      _err ""
      _err "No files have been moved. The install is in a clean state to retry."
      exit 1
    fi
  done
}

# _apply_category <live_dir> <staging_dir> <category_label> [skip_paths...]
#
# PASS 2 of the user-catalog move: mv each *.md file to staging + symlink
# back. MUST run only after _preflight_category has passed for ALL
# categories (see step_move_user_catalog).
_apply_category() {
  local live_dir="$1"
  local staging="$2"
  local label="$3"
  shift 3
  local -a skip_paths=("$@")

  [ -d "$live_dir" ] || return 0

  local -a files=()
  local f
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    files+=("$f")
  done < <(_enumerate_md_files "$live_dir")

  [ "${#files[@]}" -eq 0 ] && return 0

  local file basename_f
  for file in "${files[@]}"; do
    basename_f="$(basename "$file")"

    # Skip-listed?
    if _is_skip_listed "$file" "${skip_paths[@]+"${skip_paths[@]}"}"; then
      _log "${label}: skip-list — leaving ${file} in place"
      continue
    fi

    # Symlink — alien per R7 / R13; preserve in place.
    if [ -L "$file" ]; then
      _log "${label}: preserving alien symlink ${file}"
      continue
    fi

    local staged="${staging}/${basename_f}"
    # (Resume-safety for already-symlinked files is handled by the alien-
    # symlink `continue` above — every symlink is skipped before reaching
    # here, so a prior crashed run's symlinks are left in place.)

    # Same-filesystem check. $staged doesn't exist yet, so probe the live
    # file and the staging DIR (its eventual parent). Both calls are distinct;
    # the prior 5-call retry chain probed the same path repeatedly (dead).
    local live_dev staging_dev
    live_dev=$(_stat_device_id "$file")
    staging_dev=$(_stat_device_id "$staging")

    if [ -n "$live_dev" ] && [ -n "$staging_dev" ] && [ "$live_dev" = "$staging_dev" ]; then
      # Same filesystem — single atomic mv.
      if ! mv "$file" "$staged"; then
        _err "${label}: mv failed: ${file} → ${staged}"
        exit 1
      fi
    else
      # Cross-filesystem — cp + verify(sha256) + rm.
      _log "${label}: cross-filesystem move detected — using cp+verify+rm for ${file}"
      local src_sum dst_sum
      src_sum=$(claude_modes::sha256_of_file "$file") || {
        _err "${label}: could not hash source ${file}"
        exit 1
      }
      if ! cp "$file" "$staged" 2>/dev/null; then
        rm -f "$staged"
        _err "${label}: cp failed: ${file} → ${staged}"
        exit 1
      fi
      dst_sum=$(claude_modes::sha256_of_file "$staged") || {
        rm -f "$staged"
        _err "${label}: could not hash destination ${staged}"
        exit 1
      }
      if [ "$src_sum" != "$dst_sum" ]; then
        rm -f "$staged"
        _err "${label}: sha256 mismatch after cross-fs copy of ${file}"
        exit 1
      fi
      rm "$file" || {
        _err "${label}: could not rm source ${file} after verified copy"
        exit 1
      }
    fi

    # Set staged file perms (don't follow symlinks).
    if [ ! -L "$staged" ]; then
      chmod 0600 "$staged" 2>/dev/null || true
    fi

    # Symlink back to original path.
    if ! ln -s "$staged" "$file"; then
      _err "${label}: failed to create symlink ${file} → ${staged}"
      exit 1
    fi

    MOVED_COUNT=$((MOVED_COUNT + 1))
    _log "${label}: moved ${basename_f} → staging + symlinked back"

    # Test hook: simulate crash after Nth move.
    _maybe_test_interrupt
  done
}

# ──────────────────────────────────────────────────────────────────────
# Step 5: Seed example modes.
#
# Copies examples/example-discovery.yaml + example-delivery.yaml to
# ~/.claude/modes/discovery.yaml and delivery.yaml. Idempotent — preserves
# existing files (don't clobber user edits to the seeds).
step_seed_examples() {
  local src dst basename_d
  for basename_d in discovery delivery; do
    src="${PLUGIN_ROOT}/examples/example-${basename_d}.yaml"
    dst="${MODES_DIR}/${basename_d}.yaml"
    if [ ! -f "$src" ]; then
      _err "seed: missing source ${src}"
      exit 1
    fi
    if [ -f "$dst" ]; then
      _log "seed: ${dst} already exists; preserving"
      continue
    fi
    local tmp
    tmp=$( (umask 077 && mktemp "${MODES_DIR}/.seed.XXXXXX") ) || {
      _err "seed: mktemp failed in ${MODES_DIR}"
      exit 1
    }
    if ! cp "$src" "$tmp" 2>/dev/null; then
      rm -f "$tmp"
      _err "seed: cp failed for ${src}"
      exit 1
    fi
    if ! mv "$tmp" "$dst"; then
      rm -f "$tmp"
      _err "seed: atomic mv failed for ${dst}"
      exit 1
    fi
    if [ ! -L "$dst" ]; then
      chmod 0600 "$dst" 2>/dev/null || true
    fi
    _log "seeded ${dst}"
  done
}

# ──────────────────────────────────────────────────────────────────────
# Step 6: Archive V1 modes.
#
# Any ~/.claude/modes/*.yaml (other than what we just wrote — _global,
# discovery, delivery) with schema_version: 1 → move to .v1-archive/.
step_archive_v1_modes() {
  mkdir -m 0700 -p "$V1_ARCHIVE"

  local f basename_f sv
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    basename_f="$(basename "$f")"
    # Skip files we just wrote/seeded.
    case "$basename_f" in
      _global.yaml|discovery.yaml|delivery.yaml) continue ;;
    esac
    # Skip symlinks (alien — never touch).
    if [ -L "$f" ]; then
      continue
    fi
    # Read schema_version cheaply.
    sv=$("$CLAUDE_MODES_PYTHON3" - "$f" 2>/dev/null <<'PYEOF'
import sys, yaml
try:
    with open(sys.argv[1]) as fp:
        d = yaml.safe_load(fp) or {}
    print(d.get("schema_version", ""))
except Exception:
    print("")
PYEOF
)
    if [ "$sv" = "1" ]; then
      local dest="${V1_ARCHIVE}/${basename_f}"
      if [ -e "$dest" ]; then
        # Resume-safe: dest already exists; append a uniquifier.
        dest="${V1_ARCHIVE}/${basename_f}.$(date -u +%s)"
      fi
      if mv "$f" "$dest"; then
        _log "archived V1 mode → ${dest}"
      else
        _err "could not archive V1 mode ${f}"
      fi
    fi
  done < <(find -P "$MODES_DIR" -maxdepth 1 -name '*.yaml' -type f 2>/dev/null)
}

# ──────────────────────────────────────────────────────────────────────
# Step 7: Create install registry (empty).
step_create_registry() {
  local registry
  registry=$(claude_modes::registry_path)
  if [ -f "$registry" ]; then
    _log "registry already exists; preserving"
    # Still re-assert 0600.
    if [ ! -L "$registry" ]; then
      chmod 0600 "$registry" 2>/dev/null || true
    fi
    return 0
  fi
  if ! (umask 077 && : > "$registry") 2>/dev/null; then
    _err "could not create install registry at ${registry}"
    exit 1
  fi
  if [ ! -L "$registry" ]; then
    chmod 0600 "$registry" 2>/dev/null || true
  fi
  _log "created install registry → ${registry}"
}

# ──────────────────────────────────────────────────────────────────────
# Step 8: Initial symlink rebuild (no mode active = include all).
#
# Materializes the day-zero topology. With step 4 already creating
# symlinks per file, this is largely a verification pass — it
# reconciles any drift and removes plugin-owned symlinks not in the
# day-zero manifest (none, in a clean install).
step_initial_symlink_rebuild() {
  if ! claude_modes::symlink_rebuild ""; then
    _err "initial symlink_rebuild failed — install is in a partial state"
    _err "Re-run /mode:setup to retry (sentinel persists)."
    exit 1
  fi
  _log "initial symlink topology materialized"
}

# ──────────────────────────────────────────────────────────────────────
# Step 9: Audit + clear sentinel.
step_finalize() {
  # Count moved files (currently in staging that have a symlink back).
  local commands_count=0 agents_count=0
  if [ -d "$COMMANDS_STAGING" ]; then
    commands_count=$(find -P "$COMMANDS_STAGING" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d '[:space:]')
  fi
  if [ -d "$AGENTS_STAGING" ]; then
    agents_count=$(find -P "$AGENTS_STAGING" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d '[:space:]')
  fi

  claude_modes::audit_event "setup" \
    "version=${PLUGIN_VERSION}" \
    "commands_moved=${commands_count}" \
    "agents_moved=${agents_count}"

  rm -f "$SENTINEL"
  _log "setup complete (${commands_count} command(s), ${agents_count} agent(s) staged)"
}

# ──────────────────────────────────────────────────────────────────────
# Main.
main() {
  step_presence_check
  step_write_sentinel
  step_pristine_capture
  step_generate_global
  step_move_user_catalog
  step_seed_examples
  step_archive_v1_modes
  step_create_registry
  step_initial_symlink_rebuild
  step_finalize
  return 0
}

main "$@"
