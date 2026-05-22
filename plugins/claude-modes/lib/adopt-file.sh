#!/usr/bin/env bash
# claude-modes V2 (U11): manual /mode:adopt mechanism (R20).
#
# Public function:
#   claude_modes::adopt_file <file_path> [source]
#     <file_path>: basename (foo.md) OR absolute path under
#                  ~/.claude/commands/ or ~/.claude/agents/
#     [source]:    metadata for audit (manual|post-tool-use|session-scan);
#                  defaults to "manual" when called directly.
#
# Behavior:
#   1. Normalize the argument:
#        - basename → probe both ~/.claude/commands/<base> and
#          ~/.claude/agents/<base>; refuse if both exist or neither does.
#        - leading "~/" expands via ${path/#~/$HOME} (slash-command bodies
#          don't shell-expand $ARGUMENTS).
#        - relative path → resolved against $PWD.
#   2. Validate the resolved path is under ~/.claude/commands/ or
#      ~/.claude/agents/ using realpath + trailing-/ boundary (R7 idiom).
#      Refuse otherwise.
#   3. If the path is already a symlink pointing under
#      ~/.claude/modes/.user-catalog/, exit 0 with an "already managed"
#      message (no FS changes). The mode-of-record is reported by grepping
#      every ~/.claude/modes/*.yaml's user_catalog manifest for the basename.
#   4. Path-traversal validate via lib/symlink-validate.py: ensure
#      basename, treated as a manifest entry under
#      ~/.claude/modes/.user-catalog/<category>/, doesn't escape staging.
#   5. Determine active mode from ~/.claude/modes/.last-active-mode.
#      Refuse if empty (no active mode).
#   6. Atomic mv from live → staging. On EXDEV (cross-FS) fall back to
#      cp -p + sha256 verify + rm; explicit error if verify fails.
#   7. Symlink the staging file back to the live path.
#   8. Mutate the active mode YAML's mechanism.user_catalog.<category>
#      list — initialize if missing, append basename (deduped), then
#      write back via claude_modes::write_mode_yaml. PyYAML rewrites
#      lose comments; this is acceptable for plugin-managed YAMLs.
#   9. Emit audit event "adopt" with metadata only (never file contents).
#
# Returns 0 success, non-zero with a stderr error on each failure case.
# All errors are explicit; never silent.

# shellcheck disable=SC1091
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/mode-yaml.sh"
. "${SCRIPT_DIR}/validate-mode-name.sh"
. "${SCRIPT_DIR}/write-mode-yaml.sh"
. "${SCRIPT_DIR}/audit.sh"
. "${SCRIPT_DIR}/active-mode.sh"  # sec-005: read_validated_mode_body

CLAUDE_MODES_PYTHON3="${CLAUDE_MODES_PYTHON3:-/usr/bin/python3}"

# Internal: realpath via the pinned Python (portable on macOS without
# GNU coreutils). FOLLOWS symlinks.
__claude_modes::adopt_realpath() {
  "$CLAUDE_MODES_PYTHON3" -c \
    'import os.path,sys; print(os.path.realpath(sys.argv[1]))' \
    "$1" 2>/dev/null
}

# Internal: parent-realpath + leaf — resolves the directory chain via
# realpath (so /tmp → /private/tmp gets normalized) but does NOT follow
# the leaf if it's itself a symlink. This is the right shape for the
# live-dir boundary check: a symlink at ~/.claude/commands/foo.md still
# classifies as "in ~/.claude/commands/" even though its target points
# elsewhere.
__claude_modes::adopt_parent_realpath() {
  "$CLAUDE_MODES_PYTHON3" -c '
import os, os.path, sys
p = sys.argv[1]
parent = os.path.dirname(p) or "."
leaf = os.path.basename(p)
print(os.path.join(os.path.realpath(parent), leaf))
' "$1" 2>/dev/null
}

# Internal: returns 0 (true) if $1 (an existing path) is strictly under $2
# using the realpath + trailing-/ boundary trick. Same idiom as
# lib/symlink-validate.py.
__claude_modes::adopt_under_dir() {
  local candidate_resolved="$1"
  local boundary_dir="$2"
  local boundary
  boundary=$(__claude_modes::adopt_realpath "$boundary_dir")
  if [ -z "$boundary" ]; then
    return 1
  fi
  case "$candidate_resolved" in
    "$boundary"/*) return 0 ;;
    *) return 1 ;;
  esac
}

# Internal: search ~/.claude/modes/*.yaml for one that lists $2 in its
# mechanism.user_catalog.$1 manifest. Echoes the first mode name found,
# or nothing if no mode claims it. Mode-agnostic staging means we can't
# tell from the symlink target alone (advisor finding).
# Find which mode YAML claims <basename> in its user_catalog.<category>.
# Returns 0 + prints the claimant mode name when found.
# Returns 1 (no output) when no mode claims it AND every YAML parsed cleanly.
# Returns 2 (no output) when at least one competing mode YAML FAILED TO PARSE
#   and no claimant was found — the claimant landscape is UNCERTAIN, so callers
#   that repair/recover on "no claimant" must treat this as "do not proceed"
#   rather than "definitely unclaimed". (round-8/9: a malformed competing YAML
#   was silently swallowed by `2>/dev/null` + the grep simply not matching, so
#   recovery could double-record a basename a malformed mode actually claims.)
__claude_modes::adopt_find_mode_of_record() {
  local category="$1"
  local basename="$2"
  local modes_dir="${HOME}/.claude/modes"
  [ -d "$modes_dir" ] || return 1

  local yaml saw_unparseable=0
  for yaml in "$modes_dir"/*.yaml; do
    [ -f "$yaml" ] || continue
    # Skip cascade-tier baseline files.
    case "$(basename "$yaml")" in
      _global.yaml|_repo.yaml) continue ;;
    esac
    # Capture catalog output AND exit code separately (a pipe would hide the
    # parse-error rc behind grep's rc). py_yaml_query exits 3 on YAML parse
    # error, 2 on file-not-found, 0 on success.
    local catalog rc
    catalog=$(claude_modes::get_user_catalog "$yaml" "$category" 2>/dev/null)
    rc=$?
    if [ "$rc" -ne 0 ]; then
      saw_unparseable=1
      continue
    fi
    if printf '%s\n' "$catalog" | grep -Fxq -- "$basename"; then
      printf '%s' "$(basename "${yaml%.yaml}")"
      return 0
    fi
  done
  # No claimant found. If any YAML was unparseable, the answer is uncertain.
  [ "$saw_unparseable" -eq 1 ] && return 2
  return 1
}

# Internal: recover a half-adopted file orphaned by reconcile (round-8 P1).
# Sequence that gets here: adopt staged the file + symlinked it, but the
# manifest write (step 8) failed; then symlink_rebuild (every SessionStart)
# deleted the now-orphaned live symlink because no manifest claimed it. The
# file survives in staging but is gone from the live dir, so the normal
# live-dir probe misses it. This re-creates the symlink and completes the
# manifest write. Returns 0 if it recovered, 1 if $arg is NOT a recoverable
# orphan (so the caller falls through to its "not found" error).
__claude_modes::adopt_recover_orphaned_staging() {
  local arg="$1"
  local commands_live="${HOME}/.claude/commands"
  local agents_live="${HOME}/.claude/agents"
  local staging_root="${HOME}/.claude/modes/.user-catalog"

  # Locate the orphan in staging. Refuse on ambiguity (both categories).
  local cat="" staged_path=""
  local in_cmd=0 in_agt=0
  [ -f "${staging_root}/commands/${arg}" ] && in_cmd=1
  [ -f "${staging_root}/agents/${arg}" ] && in_agt=1
  if [ "$in_cmd" = 1 ] && [ "$in_agt" = 1 ]; then
    return 1  # ambiguous — not a clean single-orphan recovery; let caller error
  fi
  if [ "$in_cmd" = 1 ]; then
    cat="commands"; staged_path="${staging_root}/commands/${arg}"
  elif [ "$in_agt" = 1 ]; then
    cat="agents"; staged_path="${staging_root}/agents/${arg}"
  else
    return 1  # not in staging → genuinely not found
  fi

  # Must be a TRUE orphan: no live file/symlink already at the live path, and
  # no mode manifest already claims it (if a manifest claims it, reconcile
  # would have kept the symlink — this isn't the half-state).
  local live_path="${HOME}/.claude/${cat}/${arg}"
  if [ -e "$live_path" ] || [ -L "$live_path" ]; then
    return 1
  fi
  # Claimant check. rc 0 = a mode claims it (not an orphan → don't recover).
  # rc 2 = a competing YAML failed to parse, so we CAN'T be sure it's unclaimed
  # — refuse to recover rather than risk double-recording into the active mode.
  # rc 1 = cleanly unclaimed → genuine orphan, proceed.
  local __claimant __fmr_rc
  __claimant=$(__claude_modes::adopt_find_mode_of_record "$cat" "$arg")
  __fmr_rc=$?
  if [ -n "$__claimant" ] || [ "$__fmr_rc" -eq 0 ]; then
    return 1
  fi
  if [ "$__fmr_rc" -eq 2 ]; then
    echo "/mode:adopt: '${arg}' is staged but a mode YAML failed to parse, so its claimant cannot be determined — refusing to recover (fix the malformed YAML, then re-run). " >&2
    return 2  # handled + reported, NOT recovered
  fi

  # Re-derive the active mode (same source as the normal flow + L7-c repair).
  local mode
  mode=$(claude_modes::read_validated_mode_body \
    "${HOME}/.claude/modes/.last-active-mode" 2>/dev/null) || mode=""
  if [ -z "$mode" ]; then
    echo "/mode:adopt: '${arg}' is orphaned in staging (live symlink was removed by reconcile) but no active mode is set to re-record it. Run /mode:set <mode>, then /mode:adopt '${arg}' again." >&2
    return 2  # handled + reported, but NOT recovered → caller suppresses "not found" yet exits non-zero
  fi
  local mode_yaml
  if ! mode_yaml=$(claude_modes::resolve_mode_file "$mode" 2>/dev/null) \
      || [ -z "$mode_yaml" ]; then
    echo "/mode:adopt: '${arg}' is orphaned in staging; active mode '${mode}' has no resolvable YAML. Re-run /mode:set, then /mode:adopt '${arg}' again." >&2
    return 2
  fi

  # Re-create the symlink (staging → live), then complete the manifest write.
  if ! ln -s "$staged_path" "$live_path"; then
    echo "/mode:adopt: '${arg}' is orphaned in staging but the live symlink could not be re-created at '${live_path}'." >&2
    return 2
  fi
  if __claude_modes::adopt_update_manifest "$mode_yaml" "$cat" "$arg"; then
    claude_modes::audit_event "adopt_recover_orphan" \
      "file=${arg}" "mode=${mode}" "category=${cat}"
    echo "/mode:adopt: recovered orphaned '${arg}' (re-created symlink + recorded in mode '${mode}', ${cat})"
    return 0
  fi
  # Manifest write still fails → leave the re-created symlink (better than a
  # bare staging orphan: now reconcile would only re-delete it, and the user
  # has a clear recoverable error) and report.
  echo "/mode:adopt: '${arg}' is orphaned in staging; re-created the symlink but its manifest entry could not be written to mode '${mode}' (RECOVERABLE). Fix the YAML, then re-run /mode:adopt '${arg}'. Do NOT run /mode:set into a different mode until repaired." >&2
  return 2  # handled + reported, recovery FAILED → non-zero (matches L7-c tail)
}

# Internal: rewrites the mode YAML's mechanism.user_catalog.<category>
# list to include $basename (deduped). Reads file → mutates → writes via
# claude_modes::write_mode_yaml (which re-validates).
__claude_modes::adopt_update_manifest() {
  local mode_yaml="$1"
  local category="$2"
  local basename="$3"

  local new_yaml
  new_yaml=$("$CLAUDE_MODES_PYTHON3" - "$mode_yaml" "$category" "$basename" <<'PYEOF'
import sys, yaml

path = sys.argv[1]
category = sys.argv[2]
basename = sys.argv[3]

with open(path) as f:
    data = yaml.safe_load(f) or {}

mech = data.setdefault("mechanism", {}) or {}
data["mechanism"] = mech
uc = mech.setdefault("user_catalog", {}) or {}
mech["user_catalog"] = uc
entries = uc.setdefault(category, []) or []
if not isinstance(entries, list):
    sys.stderr.write(
        f"adopt-file: existing mechanism.user_catalog.{category} is not a list — refusing to mutate\n"
    )
    sys.exit(1)
if basename not in entries:
    entries.append(basename)
    uc[category] = entries

# safe_dump with sort_keys=False keeps user-authored top-level ordering
# as much as possible (PyYAML still re-emits in insertion order).
sys.stdout.write(yaml.safe_dump(data, sort_keys=False, default_flow_style=False))
PYEOF
  ) || {
    echo "adopt-file: failed to parse/mutate mode YAML '${mode_yaml}'" >&2
    return 1
  }

  # write_mode_yaml re-validates schema_version, path safety, R28.
  if ! claude_modes::write_mode_yaml "$mode_yaml" "$new_yaml"; then
    echo "adopt-file: failed to write back mutated mode YAML '${mode_yaml}'" >&2
    return 1
  fi
  return 0
}

# Internal: atomic mv with cross-FS fallback (cp -p + sha256 verify + rm).
__claude_modes::adopt_safe_move() {
  local src="$1"
  local dst="$2"

  if mv "$src" "$dst" 2>/dev/null; then
    return 0
  fi

  # Fallback: cp + verify + rm. Cross-FS is unlikely (both paths under
  # $HOME) but cheap to guard.
  if ! cp -p "$src" "$dst" 2>/dev/null; then
    echo "adopt-file: cp fallback failed ('${src}' → '${dst}')" >&2
    return 1
  fi

  local src_sha dst_sha
  src_sha=$(claude_modes::sha256_of_file "$src" 2>/dev/null)
  dst_sha=$(claude_modes::sha256_of_file "$dst" 2>/dev/null)
  if [ -z "$src_sha" ] || [ "$src_sha" != "$dst_sha" ]; then
    rm -f "$dst" 2>/dev/null || true
    echo "adopt-file: sha256 mismatch after cp fallback — refusing to remove source" >&2
    return 1
  fi

  if ! rm -f "$src" 2>/dev/null; then
    echo "adopt-file: cp succeeded but rm of source failed — leaving both copies in place" >&2
    return 1
  fi
  return 0
}

# Public.
claude_modes::adopt_file() {
  local arg="${1:-}"
  local source="${2:-manual}"

  if [ -z "$arg" ]; then
    echo "/mode:adopt: missing required argument <file>" >&2
    return 1
  fi

  # ── 1. Normalize argument → absolute path ─────────────────────────
  # Expand a literal leading "~/" since slash-command $ARGUMENTS isn't
  # tilde-expanded.
  case "$arg" in
    "~/"*)
      arg="${HOME}/${arg#~/}"
      ;;
  esac

  local commands_live="${HOME}/.claude/commands"
  local agents_live="${HOME}/.claude/agents"

  local file_path=""
  case "$arg" in
    */*|/*)
      # Path-shaped (relative or absolute) — resolve against $PWD if
      # relative, or take as-is if absolute.
      if [ "${arg#/}" = "$arg" ]; then
        file_path="${PWD%/}/${arg}"
      else
        file_path="$arg"
      fi
      ;;
    *)
      # Pure basename — probe both live dirs. Refuse on ambiguity.
      local in_cmd=0 in_agt=0
      [ -e "${commands_live}/${arg}" ] && in_cmd=1
      [ -e "${agents_live}/${arg}" ] && in_agt=1
      if [ "$in_cmd" -eq 1 ] && [ "$in_agt" -eq 1 ]; then
        echo "/mode:adopt: basename '${arg}' exists in both ~/.claude/commands/ and ~/.claude/agents/ — pass an absolute path to disambiguate" >&2
        return 1
      fi
      if [ "$in_cmd" -eq 1 ]; then
        file_path="${commands_live}/${arg}"
      elif [ "$in_agt" -eq 1 ]; then
        file_path="${agents_live}/${arg}"
      else
        # round-8 P1 (reconcile-first half-state): the live symlink may have
        # been DELETED by symlink_rebuild (which runs on every SessionStart and
        # removes any plugin-owned symlink not in the active manifest) BEFORE
        # the user could re-run /mode:adopt. The file is still in staging but
        # gone from the live dir, so the live-dir probe above misses it and the
        # L7-c repair (which keys off the live symlink) is unreachable. Detect
        # the orphan from the STAGING side and recover: re-create the symlink +
        # complete the manifest write. This closes the natural ordering the
        # L7-c fix missed (it only handled re-adopt-before-reconcile).
        # Recovery contract: 0 = recovered cleanly; 2 = handled but FAILED
        # (reported a RECOVERABLE error — caller must NOT print "not found" but
        # MUST propagate non-zero); 1 = not a recoverable orphan (fall through
        # to "not found"). This keeps suppress-not-found while still surfacing a
        # real failure as non-zero rc (matches the L7-c half-state tail).
        __claude_modes::adopt_recover_orphaned_staging "$arg"
        case $? in
          0) return 0 ;;
          2) return 1 ;;
        esac
        echo "/mode:adopt: '${arg}' not found in ~/.claude/commands/ or ~/.claude/agents/" >&2
        return 1
      fi
      ;;
  esac

  # ── 2. Validate path is under one of the two live dirs (R7 boundary)
  # Use PARENT-REALPATH (resolves directory chain but does NOT follow the
  # leaf symlink) for the live-dir boundary so an already-adopted file
  # (symlink at live path → staging) still classifies as "lives in
  # ~/.claude/commands/" despite its target pointing elsewhere. macOS
  # /tmp → /private/tmp symlink resolution is correctly handled because
  # both sides of the comparison get realpath'd.
  local file_abs file_resolved
  file_abs=$(__claude_modes::adopt_parent_realpath "$file_path")
  file_resolved=$(__claude_modes::adopt_realpath "$file_path")
  if [ -z "$file_abs" ] || [ -z "$file_resolved" ]; then
    echo "/mode:adopt: could not resolve path '${file_path}'" >&2
    return 1
  fi

  local category=""
  if __claude_modes::adopt_under_dir "$file_abs" "$commands_live"; then
    category="commands"
  elif __claude_modes::adopt_under_dir "$file_abs" "$agents_live"; then
    category="agents"
  else
    echo "/mode:adopt: file must be in ~/.claude/commands/ or ~/.claude/agents/" >&2
    return 1
  fi

  # R7 defense: realpath must ALSO land under one of the managed trees OR
  # under user-catalog staging. This catches `~/.claude/commands/sym → /etc/passwd`
  # (the symlink lives in commands/ but its target escapes everywhere
  # legitimate).
  local user_catalog_root_for_r7="${HOME}/.claude/modes/.user-catalog"
  if ! __claude_modes::adopt_under_dir "$file_resolved" "$commands_live" \
      && ! __claude_modes::adopt_under_dir "$file_resolved" "$agents_live" \
      && ! __claude_modes::adopt_under_dir "$file_resolved" "$user_catalog_root_for_r7"; then
    echo "/mode:adopt: R7 — '${file_path}' resolves outside managed directories ('${file_resolved}')" >&2
    return 1
  fi

  local basename
  basename="$(basename "$file_abs")"

  # ── 3. Already-adopted branch ─────────────────────────────────────
  # If the live path is a symlink that resolves into .user-catalog/,
  # treat as already managed.
  local user_catalog_root="${HOME}/.claude/modes/.user-catalog"
  local staging="${user_catalog_root}/${category}"

  if [ -L "$file_path" ]; then
    local link_resolved
    link_resolved=$(__claude_modes::adopt_realpath "$file_path")
    # round-8 P2: a BROKEN symlink (staging target deleted) still satisfies
    # adopt_under_dir because adopt_realpath uses os.path.realpath, which
    # resolves a dangling target's PATH without requiring it to exist. Repairing
    # from here would write a manifest entry for a file that no longer exists +
    # report success. Require the staging target to actually exist before the
    # already-adopted / half-state-repair logic runs; a dangling plugin-owned
    # symlink is a corruption to report, not a state to "repair".
    # round-8 P2: a BROKEN symlink (staging target deleted) still satisfies
    # adopt_under_dir because adopt_realpath uses os.path.realpath, which
    # resolves a dangling target's PATH without requiring it to exist. The
    # pure-basename arg path is already guarded (its `[ -e ]` probe rejects a
    # dangling link as "not found"), but the PATH-SHAPED arg form reaches here
    # with a dangling link — repairing it would write a manifest entry for a
    # nonexistent file + report success. Refuse a dangling plugin-owned symlink.
    if [ -L "$file_path" ] && [ ! -e "$file_path" ] \
       && __claude_modes::adopt_under_dir "$link_resolved" "$user_catalog_root"; then
      echo "/mode:adopt: '${basename}' is a plugin-owned symlink whose staging target no longer exists ('${link_resolved}') — refusing to repair a dangling entry. Remove the symlink and re-adopt the original file." >&2
      return 1
    fi
    if __claude_modes::adopt_under_dir "$link_resolved" "$user_catalog_root"; then
      # Try to identify which mode declares it.
      local claimant claimant_rc
      claimant=$(__claude_modes::adopt_find_mode_of_record "$category" "$basename")
      claimant_rc=$?
      if [ -n "$claimant" ]; then
        echo "/mode:adopt: '${basename}' already managed by mode '${claimant}'" >&2
        return 0
      fi
      # rc 2 = a competing mode YAML failed to parse → claimant uncertain.
      # Refuse to "repair" (which would write this basename into the active
      # mode) when a malformed YAML might already claim it (round-8/9: silent
      # parse-swallow could double-record). Report and stop.
      if [ "$claimant_rc" -eq 2 ]; then
        echo "/mode:adopt: '${basename}' is staged but a mode YAML failed to parse, so its claimant cannot be determined — refusing to repair the manifest (fix the malformed YAML, then re-run /mode:adopt)." >&2
        return 1
      fi
      # NO claimant but the symlink IS staged → HALF-ADOPTED state: a prior
      # adopt ran steps 6-7 (mv + symlink) but step 8 (manifest write) failed
      # or was interrupted. Returning 0 here ("already staged") would strand
      # the file: the next symlink_rebuild computes to_remove = current −
      # target, finds this orphan symlink in no manifest, and DELETES it
      # (correctness round-7 P1). Instead, COMPLETE step 8 now — re-derive the
      # active mode and write the manifest entry. If that write ALSO fails,
      # report a DISTINCT recoverable-needs-manual-fix error and return
      # non-zero (never loop silently / never claim success).
      local ha_mode ha_yaml
      ha_mode=$(claude_modes::read_validated_mode_body \
        "${HOME}/.claude/modes/.last-active-mode" 2>/dev/null) || ha_mode=""
      if [ -z "$ha_mode" ]; then
        echo "/mode:adopt: '${basename}' is staged but recorded in no mode manifest (half-adopted), and no active mode is set to complete the recording. Run /mode:set <mode>, then /mode:adopt '${basename}' again." >&2
        return 1
      fi
      if ! ha_yaml=$(claude_modes::resolve_mode_file "$ha_mode" 2>/dev/null) \
          || [ -z "$ha_yaml" ]; then
        echo "/mode:adopt: '${basename}' is staged but recorded in no mode manifest (half-adopted); active mode '${ha_mode}' has no resolvable YAML. Re-run /mode:set, then /mode:adopt '${basename}' again." >&2
        return 1
      fi
      if __claude_modes::adopt_update_manifest "$ha_yaml" "$category" "$basename"; then
        claude_modes::audit_event "adopt_repair_manifest" \
          "file=${basename}" "mode=${ha_mode}" "category=${category}"
        echo "/mode:adopt: completed manifest recording for previously half-adopted '${basename}' in mode '${ha_mode}' (${category})"
        return 0
      fi
      echo "/mode:adopt: '${basename}' is staged but its manifest entry could not be written to mode '${ha_mode}' (half-adopted, RECOVERABLE). Fix the YAML at the path /mode:set reported, then re-run /mode:adopt '${basename}'. Do NOT run /mode:set into a different mode until repaired, or symlink reconciliation may remove the staged file." >&2
      return 1
    fi
  fi

  # ── 3b. Existence + "regular file, not yet symlink" gate ─────────
  # NOTE: `[ -f X ]` follows symlinks. We need both "is a regular file"
  # AND "is not a symlink", per advisor.
  if [ ! -f "$file_path" ] || [ -L "$file_path" ]; then
    echo "/mode:adopt: '${file_path}' is not a regular file (or is a symlink we don't recognize)" >&2
    return 1
  fi

  # ── 4. Path-traversal validate the eventual staging-entry name ───
  mkdir -p "$staging" 2>/dev/null || true
  if ! "$CLAUDE_MODES_PYTHON3" "${SCRIPT_DIR}/symlink-validate.py" \
        "$staging" "$basename" >/dev/null 2>&1; then
    echo "/mode:adopt: R7 path-traversal validation failed for basename '${basename}'" >&2
    return 1
  fi

  # ── 5. Determine active mode (sec-005: edge-strip + validate) ────
  local active_mode_file="${HOME}/.claude/modes/.last-active-mode"
  local active_mode=""
  active_mode=$(claude_modes::read_validated_mode_body "$active_mode_file" 2>/dev/null) || active_mode=""
  if [ -z "$active_mode" ]; then
    echo "/mode:adopt: no active mode; run /mode:set <mode> first" >&2
    return 1
  fi

  local mode_yaml
  if ! mode_yaml=$(claude_modes::resolve_mode_file "$active_mode" 2>/dev/null) \
      || [ -z "$mode_yaml" ]; then
    echo "/mode:adopt: active mode '${active_mode}' is set but its YAML is missing — re-run /mode:set" >&2
    return 1
  fi

  # ── 6. Atomic mv live → staging ──────────────────────────────────
  local dst="${staging}/${basename}"
  if [ -e "$dst" ] || [ -L "$dst" ]; then
    echo "/mode:adopt: a file already exists at the staging path '${dst}' — refusing to clobber" >&2
    return 1
  fi

  if ! __claude_modes::adopt_safe_move "$file_path" "$dst"; then
    return 1
  fi

  # ── 7. ln -s back ────────────────────────────────────────────────
  if ! ln -s "$dst" "$file_path"; then
    echo "/mode:adopt: ln -s failed ('${dst}' → '${file_path}'); attempting rollback" >&2
    # Best-effort rollback: move file back so we don't leave the user in
    # a half-state.
    mv "$dst" "$file_path" 2>/dev/null || true
    return 1
  fi

  # ── 8. Mutate mode YAML manifest ─────────────────────────────────
  if ! __claude_modes::adopt_update_manifest "$mode_yaml" "$category" "$basename"; then
    echo "/mode:adopt: manifest update failed; FS state is partially adopted (symlink at '${file_path}' → '${dst}'). Re-run /mode:adopt once the YAML issue is fixed, or manually remove the symlink." >&2
    return 1
  fi

  # ── 9. Audit (metadata only) ─────────────────────────────────────
  claude_modes::audit_event "adopt" \
    "file=${basename}" \
    "mode=${active_mode}" \
    "category=${category}" \
    "source=${source}"

  echo "/mode:adopt: adopted '${basename}' into mode '${active_mode}' (${category})"
  return 0
}

# Direct invocation: bash lib/adopt-file.sh <file> [source]
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  claude_modes::adopt_file "${1:-}" "${2:-manual}"
fi
