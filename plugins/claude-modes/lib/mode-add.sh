#!/usr/bin/env bash
# claude-modes (0.3.0 / U5): /mode:add orchestrator.
#
# Adds a plugin or skill to the ACTIVE mode's tier-3 YAML, in-flow:
#   resolve active mode → resolve candidate(s) → (disambiguate) → apply-delta →
#   post-write-reload prompt. Deterministic and NON-INTERACTIVE: the lib never
#   calls AskUserQuestion (a model tool). Disambiguation is delegated to the
#   caller (the .md command body or the U7 mode agent) via the exit-10 contract.
#
# ─── PUBLIC CLI CONTRACT (shared with /mode:drop and the U7 agent) ───────────
#
#   bash lib/mode-add.sh <query-or-fqn> [<expected-snapshot>]
#
# Exit codes (the load-bearing inter-process language):
#   0   — applied (exactly one candidate, OR an FQN-shaped arg). apply_delta +
#         post_write_reload have already run; the YAML is written and the reload
#         prompt printed.
#   1   — orchestrator failure: no active mode, zero candidates, drift detected,
#         R22 refusal, or writer failure. A human-readable message is on stderr.
#   2   — usage error (missing arg).
#   10  — AMBIGUOUS: N>1 candidates. The caller must disambiguate. stdout carries:
#           __SNAPSHOT__=<sha256-hex-of-mode-yaml>
#           <TSV candidate row>            (the resolver's stable TSV shape)
#           <TSV candidate row>
#           ...
#         The caller presents the rows via AskUserQuestion, then RE-INVOKES this
#         lib with the chosen fully-qualified id AND the __SNAPSHOT__ value as the
#         second arg, e.g.:  bash lib/mode-add.sh figma@every-marketplace <sha>
#
# ─── FQN SHORTCUT ────────────────────────────────────────────────────────────
# An arg containing '@' (plugin FQN) or ':' (skill FQN) is treated as an already-
# resolved fully-qualified id — resolution is SKIPPED. This is how the caller
# re-invokes after disambiguation, and how a power user names an exact target.
# The kind (plugin vs skill) is inferred from the separator: ':' → skill,
# '@' → plugin. (A '@' before any ':' also reads as plugin — plugin FQNs never
# contain ':'; skill FQNs never contain '@'.)
#
# FAIL-CLOSED SNAPSHOT (Batch-4 Finding 3): the FQN-shortcut path REQUIRES a
# non-empty second arg (the YAML snapshot hash). It is the re-invoke/power-user
# path; a re-invoke that lost its snapshot — or a power user who omits it —
# cannot prove the YAML is unchanged, so the lib treats a missing/empty snapshot
# as DRIFT and refuses (rather than the old fail-OPEN where an empty snapshot
# SKIPPED the drift check). The bare-query (first-invocation, resolve) path does
# NOT require a snapshot. So a one-shot power-user FQN add must pass the current
# hash: `bash lib/mode-add.sh figma@mkt "$(bash lib/mode-yaml.sh sha256 <yaml>)"`,
# or use the bare plugin NAME (which resolves and needs no snapshot).
#
# A plugin-shipped SKILL on this path (`<plugin>:<skill>`) is routed to its
# PARENT PLUGIN (re-derived from installed_plugins.json), never appended to
# user_catalog.agents — see __claude_modes::edit_op_for_kind / run_edit Step 5b.
#
# ─── LOCKING DISCIPLINE (adversarial-review fix) ─────────────────────────────
# The exclusive flock (~/.claude/modes/.symlink-lock) is held ONLY for the
# duration of a single bash invocation — it is acquired around the read+write and
# released when bash exits (exit 10 included). The human-in-the-loop dwell time
# (AskUserQuestion) happens BETWEEN two separate bash processes, so the lock is
# never held across it. Cross-invocation consistency is carried by the SNAPSHOT
# (a content hash of the mode YAML at read time): on re-invoke the lib re-hashes
# the YAML and REFUSES (drift) if it changed since the snapshot was taken. This
# prevents a wandering user from blocking every other claude-modes op AND from
# silently overwriting a concurrent edit.
#
# ─── AUDIT DISCIPLINE ────────────────────────────────────────────────────────
# apply_delta (U3) already emits mode_edit_accept outcome=ok / outcome=fail
# step=r22 / step=write, and post_write_reload (U6) emits mode_reload_prompt.
# This orchestrator only audits the failures apply_delta cannot see:
# step=no_active_mode, step=no_candidates, step=drift_detected. Same event name
# (mode_edit_accept) for a single greppable edit-attempt stream.
#
# SECURITY (R7 / terminal-escape class — see docs/solutions/terminal-escape-audit.md):
#   This lib prints NO attacker-class value to a terminal. Error messages are
#   FIXED strings (the user's raw query is never echoed back — Batch-4 Finding 5
#   replaced the one diagnostic that did with a fixed string, rather than
#   allowlisting the generic `arg` name globally) so there is no
#   sanitize_for_display sink here. The exit-10 candidate TSV goes to stdout
#   (consumed by the model, not a human terminal); its fields were already
#   Cc/Cf-stripped at the transport boundary inside resolve-catalog-candidate.sh.

# shellcheck disable=SC1091
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/active-mode.sh"               # claude_modes::read_active_mode_name
. "${SCRIPT_DIR}/mode-yaml.sh"                  # resolve_mode_file, sha256_of_file
. "${SCRIPT_DIR}/resolve-catalog-candidate.sh" # claude_modes::resolve_candidate
. "${SCRIPT_DIR}/apply-delta.sh"               # claude_modes::apply_delta
. "${SCRIPT_DIR}/post-write-reload.sh"         # claude_modes::post_write_reload
. "${SCRIPT_DIR}/cascade-engine.sh"            # __claude_modes::with_flock_run
. "${SCRIPT_DIR}/audit.sh"                      # claude_modes::audit_event

CLAUDE_MODES_PYTHON3="${CLAUDE_MODES_PYTHON3:-/usr/bin/python3}"

# __claude_modes::edit_op_for_kind <verb> <kind>
#
# Maps (add|drop) × (plugin|skill) → the apply_delta op + any fixed leading
# args. Echoes the op-args as a single line; the caller appends the id/basename.
# Returns non-zero on an unknown kind.
#
# add  + plugin → add-plugin
# drop + plugin → drop-plugin
# add  + skill  → add-user-catalog agents
# drop + skill  → drop-user-catalog agents
#
# IMPORTANT (Batch-4): a PLUGIN-SHIPPED skill (kind=skill source=cache) is NOT
# routed through this add/drop-user-catalog mapping — it is REWRITTEN to a
# plugin op against the skill's PARENT PLUGIN before this function is consulted
# (see __claude_modes::run_edit). user_catalog.agents resolves user-authored
# BASENAMES staged under ~/.claude/modes/.user-catalog/; a plugin-shipped skill
# is never staged there, so a colon-FQN written into that list is a dangling,
# never-enabling reference. The add:skill / drop:skill cases below remain ONLY
# for a future genuinely-user-authored-skill source (none exists in U2). With
# only the plugin/skill-cache/marketplace sources, the skill branch is reached
# solely via the parent-plugin rewrite (→ plugin), never directly.
__claude_modes::edit_op_for_kind() {
  local verb="$1" kind="$2"
  case "${verb}:${kind}" in
    add:plugin)  printf 'add-plugin' ;;
    drop:plugin) printf 'drop-plugin' ;;
    add:skill)   printf 'add-user-catalog agents' ;;
    drop:skill)  printf 'drop-user-catalog agents' ;;
    *) return 1 ;;
  esac
  return 0
}

# __claude_modes::parent_plugin_for_name <plugin-name>
#
# Given a plugin NAME (the part before ':' in a skill FQN, or the cached skill's
# containing plugin dir), look up its installed "<name>@<marketplace>" FQN from
# installed_plugins.json. Echoes the FQN on success, NOTHING on a miss (plugin
# not installed / no registry / unparseable). Reads the registry via the
# canonical lib/registry.py::iter_plugin_entries.
#
# Used by the FQN-shortcut re-invoke path: when the caller re-invokes with a
# chosen skill colon-FQN (`<plugin>:<skill>`), the parent_plugin field from the
# original resolution is gone, so we re-derive it here.
__claude_modes::parent_plugin_for_name() {
  local plugin_name="$1"
  local registry="${HOME}/.claude/plugins/installed_plugins.json"
  [ -f "$registry" ] || return 0
  "$CLAUDE_MODES_PYTHON3" - "$registry" "$plugin_name" "$SCRIPT_DIR" <<'PYEOF' 2>/dev/null
import sys
registry_path, name, lib_dir = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, lib_dir)
from registry import iter_plugin_entries, load_registry  # noqa: E402
for key, _records in iter_plugin_entries(load_registry(registry_path)):
    if key.split("@", 1)[0] == name:
        sys.stdout.write(key)
        break
PYEOF
}

# __claude_modes::kind_from_fqn <fqn>
#
# Infers the candidate kind from a fully-qualified id's separator. Skill FQNs are
# "<plugin>:<skill>"; plugin FQNs are "<plugin>@<marketplace>". '@' wins if both
# appear (a plugin FQN never contains ':'). Echoes plugin|skill.
__claude_modes::kind_from_fqn() {
  local fqn="$1"
  case "$fqn" in
    *@*) printf 'plugin' ;;
    *:*) printf 'skill' ;;
    *)   printf 'plugin' ;;  # bare name — default to plugin
  esac
}

# __claude_modes::run_edit <verb> <arg> <expected_snapshot>
#
# The LOCKED critical section: re-validate active mode + YAML, drift-check against
# the expected snapshot (if provided), then apply + reload. MUST run with the
# catalog lock held (the public entry wraps it in with_flock_run). Per-step error
# handling mirrors set-mode.sh's set_mode_locked.
__claude_modes::run_edit() {
  local verb="$1"
  local arg="$2"
  local expected_snapshot="${3:-}"

  # ─── Step 1: resolve active mode (refuse if none) ───────────────────────
  local active_mode
  active_mode="$(claude_modes::read_active_mode_name 2>/dev/null || true)"
  if [ -z "$active_mode" ] || [ "$active_mode" = "claude" ]; then
    echo "mode-${verb}: no active mode — run /mode:set <name> first" >&2
    claude_modes::audit_event "mode_edit_accept" \
      "op=${verb}" "outcome=fail" "step=no_active_mode"
    return 1
  fi

  # ─── Step 2: resolve the active mode's tier-3 YAML path ─────────────────
  local mode_path
  if ! mode_path="$(claude_modes::resolve_mode_file "$active_mode")"; then
    # resolve_mode_file printed its own error.
    claude_modes::audit_event "mode_edit_accept" \
      "mode=${active_mode}" "op=${verb}" "outcome=fail" "step=resolve_mode_file"
    return 1
  fi

  # ─── Step 3: snapshot the YAML now (for the exit-10 / drift contract) ────
  # Batch-4 Finding 3: a FAILED hash must NOT degrade to an empty snapshot. An
  # empty __SNAPSHOT__= emitted at exit 10 would fail-OPEN downstream (the
  # re-invoke's drift check below treats empty-expected as "no check"). So if the
  # hash can't be computed, REFUSE here rather than emit a poisoned snapshot.
  local snapshot
  if ! snapshot="$(claude_modes::sha256_of_file "$mode_path" 2>/dev/null)" \
     || [ -z "$snapshot" ]; then
    echo "mode-${verb}: could not hash the mode file for the drift check; refusing rather than risk clobbering a concurrent edit. Please retry." >&2
    claude_modes::audit_event "mode_edit_accept" \
      "mode=${active_mode}" "op=${verb}" "outcome=fail" "step=snapshot_failed"
    return 1
  fi

  # Is this the FQN-shortcut / re-invoke / power-user path? An arg containing '@'
  # or ':' is an already-resolved id (the disambiguation re-invoke, or a power
  # user naming an exact target). That path is the ONLY one that should carry a
  # snapshot — and Batch-4 Finding 3 makes it FAIL-CLOSED: a re-invoke that lost
  # its snapshot (or never had one) must be treated as drift, NOT waved through.
  # The bare-query first-invocation path does not require a snapshot.
  local is_fqn_shortcut=0
  case "$arg" in
    *@*|*:*) is_fqn_shortcut=1 ;;
  esac

  # ─── Step 4: drift-check (fail-CLOSED on the re-invoke path) ─────────────
  #   - FQN-shortcut path: a non-empty snapshot is REQUIRED. An empty/missing
  #     expected_snapshot, OR a mismatch, is drift → refuse. (Fail-closed: a
  #     re-invoke without a valid snapshot can't prove the YAML is unchanged, so
  #     we must not write.)
  #   - Resolve path (bare query, first call): no snapshot expected; only a
  #     PROVIDED-but-mismatched snapshot is drift.
  # A mismatch means another process edited the mode during the human-in-the-loop
  # dwell; refuse rather than clobber.
  if [ "$is_fqn_shortcut" -eq 1 ]; then
    if [ -z "$expected_snapshot" ]; then
      # One-shot FQN add (no prior exit-10, so no snapshot to carry). The lib
      # can't distinguish this from a re-invoke that LOST its snapshot, and a
      # write without a verified snapshot can't prove the YAML is unchanged —
      # so we refuse fail-closed. The actionable workaround is the resolve path
      # (bare plugin/skill NAME), which needs no snapshot. (Batch-4 Finding 3 +
      # the follow-up: this message names the real cause, not a phantom "changed
      # during edit".)
      echo "mode-${verb}: to add an exact id in one step, use the plugin/skill NAME (e.g. /mode:${verb} ${arg%%@*}) — a bare fully-qualified id carries no snapshot, so it's treated as a stale re-invoke and refused." >&2
      claude_modes::audit_event "mode_edit_accept" \
        "mode=${active_mode}" "op=${verb}" "outcome=fail" "step=snapshot_missing"
      return 1
    fi
    if [ "$expected_snapshot" != "$snapshot" ]; then
      # Snapshot present but stale: a genuine concurrent edit during the dwell.
      echo "mode-${verb}: the mode changed during your edit (another session or branch switch); please retry" >&2
      claude_modes::audit_event "mode_edit_accept" \
        "mode=${active_mode}" "op=${verb}" "outcome=fail" "step=drift_detected"
      return 1
    fi
  elif [ -n "$expected_snapshot" ] && [ "$expected_snapshot" != "$snapshot" ]; then
    echo "mode-${verb}: mode changed during edit; please retry" >&2
    claude_modes::audit_event "mode_edit_accept" \
      "mode=${active_mode}" "op=${verb}" "outcome=fail" "step=drift_detected"
    return 1
  fi

  # ─── Step 5: resolve the candidate. An FQN-shaped arg skips resolution. ──
  # parent_plugin carries the skill's parent-plugin FQN (from the resolver's
  # parent_plugin= field, or re-derived on the FQN-shortcut path). It is the
  # routing target for a plugin-shipped skill — see Step 5b.
  local kind="" id="" parent_plugin=""
  case "$arg" in
    *@*|*:*)
      # Already fully-qualified — trust the caller's exact id.
      id="$arg"
      kind="$(__claude_modes::kind_from_fqn "$arg")"
      # On the skill FQN-shortcut path (re-invoke after disambiguation, or a
      # power user naming a colon-FQN) the parent_plugin field is gone. Re-derive
      # it from the registry using the plugin name (the part before the ':').
      if [ "$kind" = "skill" ]; then
        parent_plugin="$(__claude_modes::parent_plugin_for_name "${arg%%:*}")"
      fi
      ;;
    *)
      # Resolve via the catalog ONCE. The resolver emits 0..N TSV rows on stdout
      # (one `kind=...` line per match) plus possible `source=missing` diagnostic
      # rows on STDERR (dropped here). Keep only real candidate rows.
      local rows row_count
      rows="$(claude_modes::resolve_candidate "$arg" 2>/dev/null | grep '^kind=' || true)"
      if [ -z "$rows" ]; then
        row_count=0
      else
        row_count="$(printf '%s\n' "$rows" | grep -c '^kind=')"
      fi

      if [ "$row_count" -eq 0 ]; then
        echo "mode-${verb}: no catalog candidates matched. Try /plugin install or check the spelling." >&2
        claude_modes::audit_event "mode_edit_accept" \
          "mode=${active_mode}" "op=${verb}" "outcome=fail" "step=no_candidates"
        return 1
      fi

      if [ "$row_count" -gt 1 ]; then
        # AMBIGUOUS. Emit the snapshot + the candidate rows to STDOUT and exit
        # 10 so the caller disambiguates via AskUserQuestion and re-invokes with
        # the chosen FQN + this snapshot. No write happens here; the lock will
        # release when this bash exits, freeing other ops during the dwell.
        printf '__SNAPSHOT__=%s\n' "$snapshot"
        printf '%s\n' "$rows"
        return 10
      fi

      # Exactly one row — parse its kind= / id= / parent_plugin= fields. The row
      # is TSV (tab-separated): kind=<k>\tid=<fqn>\tsource=<s>\tinstalled=<Y|N>
      # [\tparent_plugin=<fqn>]. Split on TAB and strip the "key=" prefix from
      # each field by name so the parse is independent of field order.
      kind="$(printf '%s\n' "$rows" | head -n1 | awk -F'\t' '{for(i=1;i<=NF;i++){if($i ~ /^kind=/){sub(/^kind=/,"",$i); print $i}}}')"
      id="$(printf '%s\n' "$rows" | head -n1 | awk -F'\t' '{for(i=1;i<=NF;i++){if($i ~ /^id=/){sub(/^id=/,"",$i); print $i}}}')"
      parent_plugin="$(printf '%s\n' "$rows" | head -n1 | awk -F'\t' '{for(i=1;i<=NF;i++){if($i ~ /^parent_plugin=/){sub(/^parent_plugin=/,"",$i); print $i}}}')"
      ;;
  esac

  if [ -z "$id" ] || [ -z "$kind" ]; then
    # FIXED string (Batch-4 Finding 5): do NOT echo the raw user query ($arg) to
    # a terminal. The resolve path's arg is benign, but the FQN-shortcut path's
    # arg could carry attacker-class bytes (a colon-FQN echoed from a hostile
    # cached SKILL.md name). This lib prints NO attacker-class value (see SECURITY
    # header); a fixed string keeps that invariant without the global-ATTACKER_VARS
    # cascade an `arg` allowlist entry would cause (see terminal-escape-audit.md).
    echo "mode-${verb}: could not determine the target plugin/skill from your input" >&2
    claude_modes::audit_event "mode_edit_accept" \
      "mode=${active_mode}" "op=${verb}" "outcome=fail" "step=parse_candidate"
    return 1
  fi

  # ─── Step 5b: plugin-shipped skill → route to its PARENT PLUGIN. ──────────
  # A kind=skill candidate (source=cache) is enabled by enabling its parent
  # plugin, NOT by writing its colon-FQN into user_catalog.agents (that list
  # resolves user-authored BASENAMES staged under .user-catalog/; a plugin
  # skill is never staged there, so the colon-FQN would dangle and never
  # enable). Rewrite the candidate to a plugin op against the parent FQN so the
  # existing add-plugin / drop-plugin path (incl. R22) handles it uniformly. If
  # the parent plugin isn't installed (empty parent_plugin), refuse — you enable
  # a plugin-shipped skill by installing+enabling its plugin.
  if [ "$kind" = "skill" ]; then
    if [ -z "$parent_plugin" ]; then
      # FIXED string — the skill FQN / plugin name are attacker-class (a hostile
      # cached SKILL.md name / dir), and this lib prints no attacker-class value
      # to a terminal (see SECURITY header). Name the remedy, not the value.
      echo "mode-${verb}: that's a plugin-shipped skill, but its parent plugin isn't installed. Run /plugin install for the plugin, then retry." >&2
      claude_modes::audit_event "mode_edit_accept" \
        "mode=${active_mode}" "op=${verb}" "outcome=fail" "step=skill_plugin_not_installed"
      return 1
    fi
    # Remap: treat the skill as its parent plugin from here on.
    id="$parent_plugin"
    kind="plugin"
  fi

  # ─── Step 6: map (verb, kind) → apply_delta op + args ───────────────────
  local op_args
  if ! op_args="$(__claude_modes::edit_op_for_kind "$verb" "$kind")"; then
    echo "mode-${verb}: unsupported candidate kind '${kind}'" >&2
    claude_modes::audit_event "mode_edit_accept" \
      "mode=${active_mode}" "op=${verb}" "outcome=fail" "step=unsupported_kind"
    return 1
  fi

  # ─── Step 7: apply the delta. apply_delta enforces R22 and emits its own
  #     mode_edit_accept audit (outcome=ok / step=r22 / step=write / step=
  #     no_change). Exit-code language:
  #       0  — real write (proceed to the reload prompt)
  #       11 — IDEMPOTENT NO-OP (already present / already dropped): NOTHING was
  #            written, so there is NOTHING to reload. Skip the reload prompt
  #            (Batch-4 Finding 4: emitting it printed a false "Mode updated" +
  #            logged mode_reload_prompt with no matching edit), audit a
  #            no_change, and exit 0 (a no-op is success, not a failure).
  #       other non-zero — failure; message already on stderr, just propagate.
  # word-split op_args intentionally (it may be "drop-user-catalog agents").
  local apply_rc
  # shellcheck disable=SC2086
  claude_modes::apply_delta "$mode_path" $op_args "$id"
  apply_rc=$?
  if [ "$apply_rc" -eq 11 ]; then
    # Idempotent no-op. No reload prompt, distinct no_change audit, exit 0.
    claude_modes::audit_event "mode_edit_accept" \
      "mode=${active_mode}" "op=${verb}" "outcome=ok" "step=no_change"
    return 0
  fi
  if [ "$apply_rc" -ne 0 ]; then
    return 1
  fi

  # ─── Step 8: real write — emit the reload prompt (U6). A delta-summary names
  #     the verb + id for the user; post_write_reload sanitizes it before any
  #     terminal print and audits mode_reload_prompt. ──────────────────────────
  claude_modes::post_write_reload "$active_mode" "${verb} ${id}"
  # post_write_reload's degraded default always returns 0; the auto path's
  # reload_fail is non-fatal to the edit (YAML is written, no revert). We return
  # 0 either way — the edit itself succeeded.
  return 0
}

# claude_modes::mode_add <arg> [<expected_snapshot>]
#
# Public entry for the ADD verb. Acquires the catalog lock for the whole
# critical section (read+drift-check+write), with the same re-entrancy guard as
# set_mode (run inline if an ancestor already holds the lock).
claude_modes::mode_add() {
  __claude_modes::mode_edit_dispatch "add" "$@"
}

# claude_modes::mode_drop <arg> [<expected_snapshot>]
#
# Public entry for the DROP verb. Shared dispatch with add (same locking +
# critical section; only the verb differs).
claude_modes::mode_drop() {
  __claude_modes::mode_edit_dispatch "drop" "$@"
}

# __claude_modes::mode_edit_dispatch <verb> <arg> [<expected_snapshot>]
#
# Shared lock-acquire wrapper for both verbs. Mirrors set_mode's flock pattern:
# if an ancestor already holds the lock (CLAUDE_MODES_LOCK_HELD=1), run the
# critical section inline to avoid self-deadlock; otherwise re-exec this script
# under the flock with the internal --__locked-<verb> dispatch.
__claude_modes::mode_edit_dispatch() {
  local verb="$1"; shift
  local arg="${1:-}"
  local expected_snapshot="${2:-}"

  if [ -z "$arg" ]; then
    echo "mode-${verb}: usage: $0 <query-or-fqn> [<expected-snapshot>]" >&2
    return 2
  fi

  if [ "${CLAUDE_MODES_LOCK_HELD:-}" = "1" ]; then
    __claude_modes::run_edit "$verb" "$arg" "$expected_snapshot"
    return $?
  fi

  local lock_path="${HOME}/.claude/modes/.symlink-lock"
  __claude_modes::with_flock_run "$lock_path" -- \
    bash "${BASH_SOURCE[0]}" "--__locked-${verb}" "$arg" "$expected_snapshot"
}

# ──────────────────────────────────────────────────────────────────────
# CLI entry point. Dual-purpose: sourceable AND runnable.
#   bash lib/mode-add.sh <query-or-fqn> [<expected-snapshot>]
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
    --__locked-add)
      # Internal: invoked by with_flock_run with the lock already held.
      shift
      __claude_modes::run_edit "add" "${1:-}" "${2:-}"
      ;;
    --__locked-drop)
      # Internal: shared dispatch path for /mode:drop (see lib/mode-drop.sh).
      shift
      __claude_modes::run_edit "drop" "${1:-}" "${2:-}"
      ;;
    "")
      echo "mode-add: usage: $0 <query-or-fqn> [<expected-snapshot>]" >&2
      exit 2
      ;;
    --*)
      echo "mode-add: unknown flag '${1}'" >&2
      exit 2
      ;;
    *)
      claude_modes::mode_add "$@"
      ;;
  esac
fi
