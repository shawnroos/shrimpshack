#!/usr/bin/env bash
# claude-modes (0.3.0 / U3): delta application + R22 PRIMARY enforcement.
#
# Applies one delta (add/drop a plugin, add/drop a user-catalog entry) to a
# tier-3 mode YAML by:
#   1. reading the current YAML via yaml.safe_load,
#   2. mutating the dict IN MEMORY,
#   3. simulating the post-delta state and REFUSING any delta that would
#      violate R22 (claude-modes self-presence) — the user-visible fast-fail,
#   4. serializing via yaml.safe_dump and handing the result to
#      lib/write-mode-yaml.sh for the atomic write (R28 enforced THERE).
#
# This lib NEVER does a raw `cat > path`. Every write terminates in
# claude_modes::write_mode_yaml (mktemp+mv, umask 077, path-safety, R28).
#
# Public API:
#   claude_modes::apply_delta <mode-yaml-path> <op> <args...>
#     op ∈ {add-plugin, drop-plugin, add-user-catalog, drop-user-catalog}
#       add-plugin       <id>                  → mechanism.enabledPlugins.<id> = true
#       drop-plugin      <id>                  → append <id> to disable.enabledPlugins
#       add-user-catalog <category> <basename> → append basename to
#                                                mechanism.user_catalog.<category>
#       drop-user-catalog <category> <basename> → remove basename from same list
#     category ∈ {commands, agents}
#   Returns:
#     0  — a real write happened (YAML changed + atomically written)
#     11 — IDEMPOTENT NO-OP (add-already-present / drop-already-dropped): nothing
#          was written. The caller MUST treat this distinctly from a real write —
#          skip the reload prompt, emit a no-change audit (see Batch-4 Finding 4:
#          a no-op previously returned 0 and the orchestrator falsely printed
#          "Mode updated" + logged mode_reload_prompt with no matching
#          mode_edit_accept). Direct CLI callers that don't care can treat
#          {0,11} as "not an error".
#     non-zero (other) — error (R22 refusal, usage, read/parse failure).
#
# Delta semantics (mirrors the cascade — see lib/cascade-engine.py:_merge):
#   - drop-plugin uses cascade-SUBTRACTION: the id goes into
#     disable.enabledPlugins; mechanism.enabledPlugins is NOT touched. (The
#     cascade engine subtracts disabled keys from the running total.)
#   - add-plugin of an id currently in disable.enabledPlugins is an UN-DISABLE:
#       * if a parent tier (tier-2 _global.yaml / tier-4 _repo.yaml) enables
#         the id → remove from disable ONLY (no positive add — keeps the YAML
#         quiet; the parent already provides the enable).
#       * if no parent enables it → remove from disable AND set
#         mechanism.enabledPlugins.<id> = true.
#
# R22 PRIMARY enforcement (the load-bearing part):
#   Before serializing, simulate the post-delta state for claude-modes
#   specifically. The live identifier comes from
#   __claude_modes::resolve_self_identifier (lib/cascade-engine.sh) which
#   respects CLAUDE_MODES_CANONICAL_ID. The delta is REFUSED (exit 1, YAML
#   UNCHANGED) if the post-delta YAML would:
#     - put the live id OR any `claude-modes@*` key into disable.enabledPlugins
#       (defense-in-depth glob — survives marketplace renames / stale keys), OR
#     - set any `claude-modes@*` key to false in mechanism.enabledPlugins.
#   Cascade-engine R22 (lib/cascade-engine.py:248-289) remains the mechanical
#   backstop at the next compile; this check is the user-visible fast-fail.
#
# SECURITY (R7 / terminal-escape class — see docs/solutions/terminal-escape-audit.md):
#   This lib prints NOTHING that interpolates a YAML-derived (attacker-class)
#   string to a terminal. The R22 refusal message and audit fields carry only
#   the RESOLVED SELF-ID (ours, trusted) and the OP NAME (a fixed enum). Plugin
#   ids / catalog basenames are passed to Python via argv (never shell-
#   interpolated into source) and are written to the YAML file (not a terminal),
#   so no sanitize_for_display sink exists here — and thus no ATTACKER_VARS /
#   audit-doc entry is required for this file.

# shellcheck disable=SC1091
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/write-mode-yaml.sh"   # claude_modes::write_mode_yaml (atomic + R28)
. "${SCRIPT_DIR}/cascade-engine.sh"    # __claude_modes::resolve_self_identifier (R22 id)
. "${SCRIPT_DIR}/audit.sh"             # claude_modes::audit_event

CLAUDE_MODES_PYTHON3="${CLAUDE_MODES_PYTHON3:-/usr/bin/python3}"

# claude_modes::apply_delta <mode-yaml-path> <op> <args...>
claude_modes::apply_delta() {
  local mode_path="${1:-}"
  local op="${2:-}"

  if [ -z "$mode_path" ] || [ -z "$op" ]; then
    echo "apply-delta: usage: apply_delta <mode-yaml-path> <op> <args...>" >&2
    return 2
  fi
  shift 2  # remaining args are op-specific

  if [ ! -f "$mode_path" ]; then
    echo "apply-delta: no such mode: ${mode_path}" >&2
    return 1
  fi

  # ─── Mode name (for audit) from the filename. ─────────────────────────
  local basename mode_name
  basename="$(basename "$mode_path")"
  mode_name="${basename%.yaml}"

  # ─── Resolve the live claude-modes identifier for R22 (respects the env
  #     override). Trusted string — safe to print / audit. ──────────────
  local claude_modes_id
  claude_modes_id="$(__claude_modes::resolve_self_identifier)"

  # ─── Resolve parent tiers (for add-plugin un-disable logic). ──────────
  # Tier 2 is always the user-global _global.yaml. Tier 4 (the repo's
  # _repo.yaml) exists only when the mode YAML lives inside a git repo.
  local tier2_path="${HOME}/.claude/modes/_global.yaml"
  [ -f "$tier2_path" ] || tier2_path=""

  local tier4_path=""
  local repo_root
  if repo_root=$(git -C "$(dirname "$mode_path")" rev-parse --show-toplevel 2>/dev/null); then
    local cand="${repo_root}/.claude/modes/_repo.yaml"
    [ -f "$cand" ] && tier4_path="$cand"
  fi

  # ─── Apply the delta + R22 simulation in one Python pass. ─────────────
  # The op + its args + the parent-tier paths + the resolved id are passed as
  # argv (no source interpolation — closes the Python-injection class). Python
  # mutates the dict, runs the R22 post-delta check, and on success prints the
  # serialized YAML to stdout. On R22 violation it exits 22 (no YAML emitted).
  # On idempotent no-op it exits 10 (no YAML emitted — caller skips the write).
  local new_yaml rc
  new_yaml=$("$CLAUDE_MODES_PYTHON3" - \
      "$mode_path" "$claude_modes_id" "$tier2_path" "$tier4_path" "$op" "$@" <<'PYEOF'
import sys, yaml

mode_path     = sys.argv[1]
claude_id     = sys.argv[2]
tier2_path    = sys.argv[3]   # may be "" (absent)
tier4_path    = sys.argv[4]   # may be "" (absent)
op            = sys.argv[5]
op_args       = sys.argv[6:]

# Exit-code contract (read by the bash caller):
#   0  → success, serialized YAML on stdout
#   10 → idempotent no-op (no change), NO stdout
#   22 → R22 violation, NO stdout
#   30 → bad usage / unknown op / bad args
#   40 → could not read/parse the mode YAML

def _load(path):
    try:
        with open(path) as f:
            d = yaml.safe_load(f)
    except Exception:
        return None
    return d if isinstance(d, dict) else {}

data = _load(mode_path)
if data is None:
    sys.stderr.write("apply-delta: could not read/parse %s\n" % mode_path)
    sys.exit(40)


def _ensure_dict(parent, key):
    cur = parent.get(key)
    if not isinstance(cur, dict):
        cur = {}
        parent[key] = cur
    return cur


def _ensure_list(parent, key):
    cur = parent.get(key)
    if not isinstance(cur, list):
        cur = []
        parent[key] = cur
    return cur


def _parent_enables(path, plugin_id):
    """True iff <path>'s mechanism.enabledPlugins.<plugin_id> is literally True."""
    if not path:
        return False
    pd = _load(path)
    if not pd:
        return False
    mech = pd.get("mechanism")
    if not isinstance(mech, dict):
        return False
    ep = mech.get("enabledPlugins")
    if not isinstance(ep, dict):
        return False
    return ep.get(plugin_id) is True


changed = False

if op == "add-plugin":
    if len(op_args) != 1 or not op_args[0]:
        sys.stderr.write("apply-delta: add-plugin requires <id>\n")
        sys.exit(30)
    pid = op_args[0]
    mech = _ensure_dict(data, "mechanism")
    ep = _ensure_dict(mech, "enabledPlugins")
    disable = data.get("disable")
    disable_ep = disable.get("enabledPlugins") if isinstance(disable, dict) else None
    in_disable = isinstance(disable_ep, list) and pid in disable_ep

    if in_disable:
        # Un-disable. Remove EVERY occurrence from the disable list.
        disable_ep[:] = [x for x in disable_ep if x != pid]
        changed = True
        # Decide whether a positive add is needed.
        if not (_parent_enables(tier2_path, pid) or _parent_enables(tier4_path, pid)):
            ep[pid] = True
    else:
        # Plain add. Idempotent if already enabled (True).
        if ep.get(pid) is True:
            sys.exit(10)
        ep[pid] = True
        changed = True

elif op == "drop-plugin":
    if len(op_args) != 1 or not op_args[0]:
        sys.stderr.write("apply-delta: drop-plugin requires <id>\n")
        sys.exit(30)
    pid = op_args[0]
    disable = _ensure_dict(data, "disable")
    disable_ep = _ensure_list(disable, "enabledPlugins")
    if pid in disable_ep:
        sys.exit(10)  # already dropped — idempotent
    disable_ep.append(pid)
    changed = True
    # Cascade-subtraction: do NOT touch mechanism.enabledPlugins.

elif op in ("add-user-catalog", "drop-user-catalog"):
    if len(op_args) != 2 or not op_args[0] or not op_args[1]:
        sys.stderr.write("apply-delta: %s requires <category> <basename>\n" % op)
        sys.exit(30)
    category, base = op_args[0], op_args[1]
    if category not in ("commands", "agents"):
        sys.stderr.write("apply-delta: category must be 'commands' or 'agents'\n")
        sys.exit(30)
    mech = _ensure_dict(data, "mechanism")
    uc = _ensure_dict(mech, "user_catalog")
    lst = _ensure_list(uc, category)
    if op == "add-user-catalog":
        if base in lst:
            sys.exit(10)  # idempotent
        lst.append(base)
        changed = True
    else:  # drop-user-catalog
        if base not in lst:
            sys.exit(10)  # idempotent
        lst[:] = [x for x in lst if x != base]
        changed = True

else:
    sys.stderr.write("apply-delta: unknown op '%s'\n" % op)
    sys.exit(30)

if not changed:
    sys.exit(10)

# ─── R22 PRIMARY enforcement — simulate the post-delta state. ────────────
# Refuse if the post-delta YAML would (a) put the live id OR any claude-modes@*
# key into disable.enabledPlugins, or (b) set any claude-modes@* key to false in
# mechanism.enabledPlugins. The claude_id glob is defense-in-depth: it catches
# stale-marketplace keys and the CANONICAL_ID-override mismatch case even though
# they aren't the resolved id.
def _is_self_key(k):
    return isinstance(k, str) and (k == claude_id or k.startswith("claude-modes@"))

disable = data.get("disable")
if isinstance(disable, dict):
    dep = disable.get("enabledPlugins")
    if isinstance(dep, list):
        for entry in dep:
            if _is_self_key(entry):
                sys.exit(22)

mech = data.get("mechanism")
if isinstance(mech, dict):
    ep = mech.get("enabledPlugins")
    if isinstance(ep, dict):
        for k, v in ep.items():
            if _is_self_key(k) and v is False:
                sys.exit(22)
# ─── END R22 PRIMARY enforcement ─────────────────────────────────────────

sys.stdout.write(yaml.safe_dump(data, default_flow_style=False, sort_keys=True))
sys.exit(0)
PYEOF
)
  rc=$?

  case "$rc" in
    0)
      # Hand the serialized YAML to the atomic writer (R28 enforced there).
      if ! claude_modes::write_mode_yaml "$mode_path" "$new_yaml"; then
        claude_modes::audit_event "mode_edit_accept" \
          "mode=${mode_name}" "op=${op}" "target=${1:-}" "outcome=fail" "step=write"
        return 1
      fi
      claude_modes::audit_event "mode_edit_accept" \
        "mode=${mode_name}" "op=${op}" "target=${1:-}" "outcome=ok"
      return 0
      ;;
    10)
      # Idempotent no-op — nothing written, nothing to reload. Signal the caller
      # DISTINCTLY (rc 11) so it can skip the reload prompt and emit a no-change
      # audit instead of falsely reporting "Mode updated". Audit the no-op here
      # so apply-delta's edit stream stays self-describing (the orchestrator adds
      # its own no_change event too; both are greppable under mode_edit_accept).
      claude_modes::audit_event "mode_edit_accept" \
        "mode=${mode_name}" "op=${op}" "target=${1:-}" "outcome=ok" "step=no_change"
      return 11
      ;;
    22)
      # R22 refusal. The message names the RESOLVED self-id (trusted) only.
      echo "R22: ${claude_modes_id} is required and cannot be disabled at the mode tier" >&2
      claude_modes::audit_event "mode_edit_accept" \
        "mode=${mode_name}" "op=${op}" "target=${1:-}" "outcome=fail" "step=r22"
      return 1
      ;;
    *)
      # 30 (usage) / 40 (read) / anything else — stderr already explained.
      return 1
      ;;
  esac
}

# Allow direct invocation for testing / manual use:
#   bash lib/apply-delta.sh <mode-yaml-path> <op> <args...>
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <mode-yaml-path> <op> <args...>" >&2
    exit 2
  fi
  claude_modes::apply_delta "$@"
fi
