#!/usr/bin/env bash
# claude-modes V2 U4: cascade engine bash orchestrator.
#
# Responsibilities:
#   - Resolve tier-3 path (active mode YAML or "" for Claude Mode)
#   - Resolve tier-4 path (<repo>/.claude/modes/_repo.yaml or "")
#   - Resolve claude-modes plugin identifier (post-pub hardcoded > registry
#     installPath match > synthetic "claude-modes@local-dev")
#   - Acquire flock on ~/.claude/modes/.symlink-lock (R27) — shared lock
#     with U8 symlink-rebuild so within-repo cascade compiles serialize
#   - Tier-4 trust gate (direnv-pattern .trusted-repos.txt; prompt on
#     first encounter OR hash change)
#   - Invoke lib/cascade-engine.py with resolved paths
#   - On success: append repo to ~/.claude/modes/.installed-repos.txt
#   - Record audit event
#
# Note: macOS bash has no flock(1) binary. We use a Python helper for
# fcntl.flock instead — wrapped in a function below.
#
# Hook contract: this is a CLI helper. Errors propagate.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/mode-yaml.sh"
. "${SCRIPT_DIR}/validate-mode-name.sh"
. "${SCRIPT_DIR}/audit.sh"
. "${SCRIPT_DIR}/install-registry.sh"  # api-contract: register_repo (canonical writer)
. "${SCRIPT_DIR}/sanitize.sh"          # terminal-escape: claude_modes::sanitize_for_display

CLAUDE_MODES_PYTHON3="${CLAUDE_MODES_PYTHON3:-/usr/bin/python3}"
CASCADE_PY="${SCRIPT_DIR}/cascade-engine.py"

# Trust-gate consent input source. Three modes (see tier4_trust_gate):
#   - UNSET (default) → read from /dev/tty with a 30s timeout. If no TTY is
#     attached (hook/agent/CI context), fail CLOSED (decline trust).
#   - Set to a file/fd by a caller (agent or test) → read one line from it,
#     no timeout, fail closed on read error.
# correctness-003: the old default of /dev/stdin consumed the hook event
# JSON when the gate ran inside a hook. rel-003: the old /dev/tty read had
# no timeout, hanging the hook if the user was AFK. agent-native-002: the
# stdin contract was undocumented for agent callers — the three modes here
# are the documented contract. Tests pipe "y\n"/"n\n" by pointing this var
# at a file (or /dev/stdin explicitly).
: "${CLAUDE_MODES_TRUST_PROMPT_INPUT:=}"

# ──────────────────────────────────────────────────────────────────────
# Identifier resolution.
#
# Three-tier strategy per plan Q2:
#   1. Post-publication: hardcoded canonical identifier (override via env
#      for testing future canonical values).
#   2. Pre-publication with installed_plugins.json listing the plugin:
#      parse + match realpath(installPath) against realpath of this lib's
#      plugin root, return the marketplace-prefixed identifier.
#   3. Pre-publication first-run / no registry: synthetic
#      "claude-modes@local-dev".
__claude_modes::resolve_self_identifier() {
  # Allow override for testing / future publication.
  if [ -n "${CLAUDE_MODES_CANONICAL_ID:-}" ]; then
    printf '%s' "$CLAUDE_MODES_CANONICAL_ID"
    return 0
  fi

  local registry="${HOME}/.claude/plugins/installed_plugins.json"
  # The plugin root is the parent of this lib/ dir.
  local plugin_root
  plugin_root="$(cd "${SCRIPT_DIR}/.." && pwd)"

  if [ -f "$registry" ]; then
    # Parse the registry, find an entry whose installPath realpath matches
    # this plugin's realpath, and return its identifier. We use Python to
    # avoid jq dependency.
    local id
    id=$("$CLAUDE_MODES_PYTHON3" - "$registry" "$plugin_root" <<'PYEOF'
import json, os, sys
registry_path = sys.argv[1]
plugin_root = os.path.realpath(sys.argv[2])
try:
    with open(registry_path) as f:
        data = json.load(f)
except Exception:
    sys.exit(0)

# Shape: {"plugins": {"<name>@<marketplace>": <record>}} or top-level dict.
# CRITICAL: the real installed_plugins.json keys each plugin to a LIST of
# install records (one per scope), NOT a single dict:
#   {"plugins": {"name@mkt": [{"scope": "user", "installPath": "..."}]}}
# A marketplace-installed plugin is therefore a list, and the old
# `isinstance(val, dict)` guard skipped EVERY real entry → the resolver always
# fell through to the local-dev synthetic. Handle both the list-of-records and
# the bare-dict shape. (Bug surfaced on first contact with a real marketplace
# install; never exercised because tests used CLAUDE_MODES_CANONICAL_ID or the
# fallback. Mirror this list-awareness in any future registry reader.)
candidates = []
plugins = data.get("plugins") if isinstance(data, dict) else None
if isinstance(plugins, dict):
    candidates = plugins.items()
elif isinstance(data, dict):
    candidates = data.items()

for key, val in candidates:
    # val may be a list of install records OR a single record dict.
    records = val if isinstance(val, list) else [val]
    for rec in records:
        if not isinstance(rec, dict):
            continue
        install_path = rec.get("installPath") or rec.get("install_path")
        if not install_path:
            continue
        if os.path.realpath(install_path) == plugin_root:
            sys.stdout.write(key)
            sys.exit(0)
sys.exit(0)
PYEOF
)
    if [ -n "$id" ]; then
      printf '%s' "$id"
      return 0
    fi
  fi

  # Fallback: pre-publication local-dev synthetic.
  printf '%s' "claude-modes@local-dev"
}

# ──────────────────────────────────────────────────────────────────────
# Cross-platform flock on ~/.claude/modes/.symlink-lock.
#
# macOS lacks flock(1); fcntl.flock via Python is portable. We wrap the
# whole cascade in a python -c that holds the lock for the duration of
# the subshell — this is overkill for the simple call we're making, so
# instead we use a child-with-inherited-fd pattern: open the lock fd in
# bash, then have Python flock+sleep while we run the cascade in the
# parent. Simpler approach: shell out to a single Python process that
# acquires the lock, runs the cascade, releases. Implemented below.

__claude_modes::with_flock_run() {
  # __claude_modes::with_flock_run <lock_path> -- <command> [args...]
  local lock_path="$1"; shift
  if [ "${1:-}" = "--" ]; then shift; fi

  # Re-entrancy guard (adv-009): an ancestor in this call stack already
  # holds this lock and exported CLAUDE_MODES_LOCK_HELD=1 (see set_mode /
  # clear_mode, which wrap the whole critical section in a single flock).
  # fcntl.flock is per-open-file-description, so a second open()+LOCK_EX on
  # the same path from the same process tree self-deadlocks. When the env
  # var is set we skip acquisition and just run the command — the lock is
  # already held above us. Do NOT unset this var "for cleanliness": inner
  # callers rely on it being inherited.
  if [ "${CLAUDE_MODES_LOCK_HELD:-}" = "1" ]; then
    "$@"
    return $?
  fi

  # TEST-ONLY escape hatch: concurrent-mode-set.test.sh sets this to neuter
  # the lock and prove the race test goes red without serialization (per the
  # deliberate-fail discipline). NEVER set this in production code paths;
  # it is deliberately a distinct var from CLAUDE_MODES_LOCK_HELD so a grep
  # for "NO_LOCK" surfaces all bypasses.
  if [ "${CLAUDE_MODES_TEST_NO_LOCK:-}" = "1" ]; then
    "$@"
    return $?
  fi

  # Ensure the lock file exists with 0600.
  mkdir -p "$(dirname "$lock_path")" 2>/dev/null
  if ! (umask 077 && : >> "$lock_path") 2>/dev/null; then
    echo "cascade-engine: could not create lock file at $lock_path" >&2
    return 1
  fi

  # The Python wrapper opens the lock file, acquires LOCK_EX, then
  # spawns the command as a child. The lock is released when Python
  # exits (file close on process exit). The child inherits
  # CLAUDE_MODES_LOCK_HELD=1 so nested with_flock_run calls skip re-acquire.
  "$CLAUDE_MODES_PYTHON3" - "$lock_path" "$@" <<'PYEOF'
import fcntl, os, subprocess, sys
lock_path = sys.argv[1]
argv = sys.argv[2:]
with open(lock_path, "a+") as lock_file:
    try:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
    except OSError as e:
        sys.stderr.write(f"cascade-engine: flock acquire failed: {e}\n")
        sys.exit(1)
    try:
        env = os.environ.copy()
        env["CLAUDE_MODES_LOCK_HELD"] = "1"
        result = subprocess.run(argv, env=env)
        sys.exit(result.returncode)
    finally:
        try:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)
        except OSError:
            pass
PYEOF
}

# Display sanitizer lives in lib/sanitize.sh (shared with status.sh,
# on-post-tool-use.sh, etc.). See that file + docs/solutions/terminal-escape-audit.md.
# (sourced at the top of this file)

# ──────────────────────────────────────────────────────────────────────
# Tier-4 trust gate (direnv-pattern .trusted-repos.txt).
#
# Records: <absolute-repo-path>:<sha256-of-_repo.yaml>:<accepted-at-iso>
# Returns 0 if tier-4 should be merged; 1 if it should be skipped.
__claude_modes::tier4_trust_gate() {
  local repo_root="$1"
  local repo_yaml="$2"

  local trusted_file="${HOME}/.claude/modes/.trusted-repos.txt"
  # Ensure existence at 0600 for first-read consistency.
  if ! (umask 077 && : >> "$trusted_file") 2>/dev/null; then
    echo "cascade-engine: could not create trusted-repos file at $trusted_file" >&2
    return 1
  fi

  local current_hash
  current_hash=$(claude_modes::sha256_of_file "$repo_yaml")
  if [ -z "$current_hash" ]; then
    echo "cascade-engine: could not hash $(claude_modes::sanitize_for_display "$repo_yaml")" >&2
    return 1
  fi

  # Look for an exact trusted entry. P2 (sec-004/adv-003): repo paths can
  # contain regex metacharacters (e.g., `.`, `+`) so the original BRE
  # `grep -q "^..."` could match foreign entries or be spoofed. Use
  # `grep -Fxq` (fixed-string, whole-line) against a record that includes
  # any timestamp suffix — we scan line-by-line because we don't know the
  # acceptance timestamp.
  while IFS= read -r __entry || [ -n "$__entry" ]; do
    case "$__entry" in
      "${repo_root}:${current_hash}:"*)
        return 0
        ;;
    esac
  done < "$trusted_file"

  # Surface a named diff of every enabledPlugins entry in _repo.yaml.
  # sec re-review (L2): EVERY attacker-controlled string below (the path, the
  # plugin keys, and the repo_root in the prompt) is sanitized via
  # sanitize_for_display — strips Cc+Cf (incl. U+202E bidi) — so a hostile
  # _repo.yaml or clone path can't spoof what the user consents to.
  echo "" >&2
  echo "claude-modes: _repo.yaml found at:" >&2
  printf '  %s\n' "$(claude_modes::sanitize_for_display "$repo_yaml")" >&2
  echo "" >&2
  echo "It declares the following enabledPlugins (tier 4):" >&2
  local listing
  listing=$(claude_modes::get_enabled_plugins "$repo_yaml" 2>/dev/null)
  if [ -n "$listing" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] && printf '  - %s\n' "$(claude_modes::sanitize_for_display "$line")" >&2
    done <<< "$listing"
  else
    echo "  (none — disable-only or empty)" >&2
  fi
  local disabling
  disabling=$(claude_modes::get_disabled_plugins "$repo_yaml" 2>/dev/null)
  if [ -n "$disabling" ]; then
    echo "" >&2
    echo "It disables (subtracts from cascade):" >&2
    while IFS= read -r line; do
      [ -n "$line" ] && printf '  - %s\n' "$(claude_modes::sanitize_for_display "$line")" >&2
    done <<< "$disabling"
  fi
  echo "" >&2
  printf "install tier 4 configuration from %s/.claude/modes/_repo.yaml? Plugins listed will be loaded into Claude on next /reload-plugins. [y/N] " "$(claude_modes::sanitize_for_display "$repo_root")" >&2

  local reply=""
  if [ -z "$CLAUDE_MODES_TRUST_PROMPT_INPUT" ]; then
    # Default: interactive TTY with timeout. No TTY → fail closed.
    if [ ! -e /dev/tty ]; then
      echo "cascade-engine: tier 4 skipped — no TTY for trust prompt (non-interactive); decline by default" >&2
      claude_modes::audit_event "trust_gate" "repo=${repo_root}" "decision=N" "reason=no_tty"
      return 1
    fi
    # rel-003: 30s timeout so an AFK user can't hang the hook indefinitely.
    if ! IFS= read -r -t 30 reply < /dev/tty 2>/dev/null; then
      echo "cascade-engine: tier 4 skipped — trust prompt timed out or failed; decline by default" >&2
      claude_modes::audit_event "trust_gate" "repo=${repo_root}" "decision=N" "reason=timeout_or_error"
      return 1
    fi
  else
    # Explicit input source from caller (agent / test). No timeout; fail
    # closed on read error.
    IFS= read -r reply < "$CLAUDE_MODES_TRUST_PROMPT_INPUT" 2>/dev/null || reply=""
  fi

  case "$reply" in
    y|Y|yes|YES)
      # Record acceptance.
      local ts
      ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
      printf '%s:%s:%s\n' "$repo_root" "$current_hash" "$ts" >> "$trusted_file"
      chmod 0600 "$trusted_file" 2>/dev/null || true
      return 0
      ;;
    *)
      echo "cascade-engine: tier 4 skipped — user declined trust gate" >&2
      claude_modes::audit_event "trust_gate" "repo=${repo_root}" "decision=N"
      return 1
      ;;
  esac
}

# ──────────────────────────────────────────────────────────────────────
# claude_modes::cascade_compile <mode_name> [repo_root]
#
# Compiles the active mode's cascade into <repo_root>/.claude/settings.local.json.
#
# Args:
#   mode_name  — name of the active mode (tier 3). Pass "" or "claude"
#                for Claude Mode (no tier-3 contribution).
#   repo_root  — optional; if omitted, resolved via `git -C "$PWD"
#                rev-parse --show-toplevel`. If no repo, the cascade
#                compiles only tiers 2 and 3 but does NOT write a
#                per-repo settings.local.json (no-repo case).
#
# Returns 0 on success; non-zero on cascade failure or trust-gate decline.
claude_modes::cascade_compile() {
  local mode_name="${1:-}"
  local repo_root="${2:-}"

  # ─── Resolve repo_root (or detect no-repo case) ──────────────────────
  if [ -z "$repo_root" ]; then
    repo_root=$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null)
  fi

  local no_repo=0
  if [ -z "$repo_root" ]; then
    no_repo=1
  fi

  # ─── Resolve tier paths ──────────────────────────────────────────────
  local tier_2_path="${HOME}/.claude/modes/_global.yaml"
  if [ ! -f "$tier_2_path" ]; then
    echo "cascade-engine: tier 2 _global.yaml not found at $tier_2_path — run /mode:setup first" >&2
    claude_modes::audit_event "cascade_compile" "mode=${mode_name}" "status=fail" "reason=no_global_yaml"
    return 1
  fi

  local tier_3_path=""
  if [ -n "$mode_name" ] && [ "$mode_name" != "claude" ]; then
    tier_3_path=$(claude_modes::resolve_mode_file "$mode_name") || {
      echo "cascade-engine: could not resolve mode '$mode_name' — aborting cascade" >&2
      claude_modes::audit_event "cascade_compile" "mode=${mode_name}" "status=fail" "reason=mode_not_found"
      return 1
    }
  fi

  local tier_4_path=""
  if [ "$no_repo" = "0" ]; then
    local candidate="${repo_root}/.claude/modes/_repo.yaml"
    # R30 (trust-gate symlink ordering, P1 cluster): lstat-reject any
    # symlink at the _repo.yaml path BEFORE the trust gate reads or hashes
    # it. Without this, the trust gate follows the symlink, sha256s the
    # *target's* content, and (on accept) records the target's hash in
    # .trusted-repos.txt — letting an attacker leak symlink target
    # fingerprints into the trust ledger.
    #
    # Contract: R30 violation is a hard fail (non-zero return + R30 in
    # stderr). Test surface at tests/integration/symlink-path-traversal.test.sh.
    if [ -L "$candidate" ]; then
      # terminal-escape (L6): $candidate is ${repo_root}/... — a hostile clone
      # path. Sanitize before this stderr print (same as the consent-listing
      # sites below; the rejection branches were missed in L2-a).
      echo "cascade-engine: R30 path-safety violation — _repo.yaml at $(claude_modes::sanitize_for_display "$candidate") is a symlink (refusing to read)" >&2
      claude_modes::audit_event "trust_gate" "repo=${repo_root}" "decision=N" "reason=R30_symlink_rejected"
      return 1
    elif [ -e "$candidate" ]; then
      # R30 ancestor-symlink containment: the leaf -L check above misses an
      # ANCESTOR directory symlink (e.g. <repo>/.claude/modes is itself a
      # committed symlink to an attacker dir, making _repo.yaml a regular
      # file whose realpath lands OUTSIDE the repo). Require realpath of the
      # candidate to stay under realpath of repo_root before reading/hashing.
      local __real_repo __real_cand
      __real_repo=$("$CLAUDE_MODES_PYTHON3" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$repo_root" 2>/dev/null)
      __real_cand=$("$CLAUDE_MODES_PYTHON3" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$candidate" 2>/dev/null)
      # Fail CLOSED if either realpath couldn't resolve (python3 missing/slow,
      # error swallowed by 2>/dev/null → empty). Without this guard, an empty
      # $__real_repo makes the case pattern `"$__real_repo"/*` collapse to
      # `/*`, which matches EVERY absolute path — turning the containment
      # check into a no-op (fail-open). adv/testing/reliability re-review P1.
      if [ -z "$__real_repo" ] || [ -z "$__real_cand" ]; then
        echo "cascade-engine: R30 path-safety violation — could not resolve realpath for tier-4 containment check (refusing tier 4)" >&2
        claude_modes::audit_event "trust_gate" "repo=${repo_root}" "decision=N" "reason=R30_realpath_unresolved"
        return 1
      fi
      case "$__real_cand" in
        "$__real_repo"/*) : ;;  # contained — OK
        *)
          # terminal-escape (L6): both $candidate and $__real_cand (realpath of
          # an attacker-committed symlink target) are attacker-controlled.
          echo "cascade-engine: R30 path-safety violation — _repo.yaml at $(claude_modes::sanitize_for_display "$candidate") resolves outside the repo tree (ancestor-directory symlink escape) → $(claude_modes::sanitize_for_display "$__real_cand")" >&2
          claude_modes::audit_event "trust_gate" "repo=${repo_root}" "decision=N" "reason=R30_ancestor_symlink_rejected"
          return 1
          ;;
      esac
      # Trust gate runs BEFORE we let Python see the path. Trust gate
      # decision: 0 = merge, 1 = skip.
      if __claude_modes::tier4_trust_gate "$repo_root" "$candidate"; then
        tier_4_path="$candidate"
      else
        tier_4_path=""
      fi
    fi
  fi

  # ─── Resolve self identifier (R22 reference) ─────────────────────────
  local claude_modes_id
  claude_modes_id=$(__claude_modes::resolve_self_identifier)

  # ─── No-repo case: compile but do not write per-repo files ───────────
  if [ "$no_repo" = "1" ]; then
    # We still want to validate the cascade resolves and R22 holds — so
    # we run the Python with a tmp target + tmp sidecar in $HOME and
    # discard. Audit records the no-repo case.
    # correctness-002: BSD/macOS mktemp only substitutes X's at the END of
    # the template — a ".json" after the X-run is literal, so the temp name
    # is NOT randomized (defeats the unguessable-name protection and can
    # collide). Keep X's terminal; these throwaway files are rm -f'd below,
    # and cascade-engine.py treats the paths as opaque (no extension logic).
    # umask 077 so they're born 0600 (rel-004).
    local tmp_target tmp_sidecar
    tmp_target=$( (umask 077 && mktemp "${HOME}/.cascade-norepo-settings.XXXXXX") ) || {
      claude_modes::audit_event "cascade_compile" "mode=${mode_name:-claude}" "status=fail" "no_repo=1" "step=mktemp_target"
      return 1
    }
    tmp_sidecar=$( (umask 077 && mktemp "${HOME}/.cascade-norepo-sidecar.XXXXXX") ) || {
      rm -f "$tmp_target"
      claude_modes::audit_event "cascade_compile" "mode=${mode_name:-claude}" "status=fail" "no_repo=1" "step=mktemp_sidecar"
      return 1
    }
    local rc=0
    "$CLAUDE_MODES_PYTHON3" "$CASCADE_PY" \
        "$tier_2_path" "$tier_3_path" "$tier_4_path" \
        "$claude_modes_id" "$tmp_target" "$tmp_sidecar" >/dev/null
    rc=$?
    if [ "$rc" -eq 0 ]; then
      rm -f "$tmp_target" "$tmp_sidecar"
      claude_modes::audit_event "cascade_compile" \
        "mode=${mode_name:-claude}" \
        "status=ok" \
        "no_repo=1"
      return 0
    else
      rm -f "$tmp_target" "$tmp_sidecar"
      claude_modes::audit_event "cascade_compile" \
        "mode=${mode_name:-claude}" \
        "status=fail" \
        "no_repo=1" \
        "rc=$rc"
      return "$rc"
    fi
  fi

  # ─── Repo case: target + sidecar paths ───────────────────────────────
  local target_settings="${repo_root}/.claude/settings.local.json"
  local sidecar="${repo_root}/.claude/modes/.cascade-meta.json"

  mkdir -p "$(dirname "$target_settings")" 2>/dev/null
  mkdir -p "$(dirname "$sidecar")" 2>/dev/null

  # ─── Acquire flock and run cascade ───────────────────────────────────
  local lock_path="${HOME}/.claude/modes/.symlink-lock"
  local rc=0
  __claude_modes::with_flock_run "$lock_path" -- \
      "$CLAUDE_MODES_PYTHON3" "$CASCADE_PY" \
      "$tier_2_path" "$tier_3_path" "$tier_4_path" \
      "$claude_modes_id" "$target_settings" "$sidecar"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    claude_modes::audit_event "cascade_compile" \
      "mode=${mode_name:-claude}" \
      "repo=${repo_root}" \
      "status=fail" \
      "rc=$rc"
    return "$rc"
  fi

  # ─── Track this repo via the canonical registry writer ──────────────
  # api-contract re-review finding: this used to inline a grep -qxF +
  # conditional append (dedup-on-WRITE) with a TOCTOU race between the check
  # and the append, AND duplicated logic against install-registry.sh's
  # canonical register_repo (dedup-on-READ via atomic O_APPEND). Delegating
  # to register_repo kills the race and the divergent second write path.
  claude_modes::register_repo "$repo_root" || true

  claude_modes::audit_event "cascade_compile" \
    "mode=${mode_name:-claude}" \
    "repo=${repo_root}" \
    "status=ok"
  return 0
}

# Allow direct invocation:
#   bash lib/cascade-engine.sh <mode_name> [repo_root]
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  claude_modes::cascade_compile "${1:-}" "${2:-}"
fi
