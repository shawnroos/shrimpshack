#!/usr/bin/env python3
# claude-modes V2 U4: cascade engine Python helper.
#
# Reads tier YAMLs (tier 2 = _global.yaml, tier 3 = active mode YAML,
# tier 4 = <repo>/.claude/modes/_repo.yaml), merges the single V2.0
# cascade-owned key (`enabledPlugins`), asserts R22 (claude-modes
# self-presence in the cascade total), preserves non-plugin-owned keys
# verbatim from the target settings.local.json, writes the merged result
# atomically (born-at-0600), and emits a sidecar at
# <repo>/.claude/modes/.cascade-meta.json with a sha256 fingerprint.
#
# ──────────────────────────────────────────────────────────────────────
# V2.0 SCOPE CUT (binary-verified 2026-05-18):
#   PLUGIN_OWNED_KEYS_V2 = ["enabledPlugins"] only. /reload-plugins hot-
#   reloads only the plugin layer; other keys (env, permissions,
#   mcpServers, hooks) require a new session. Putting them in the
#   cascade would mislead users. Tier YAMLs may declare those keys —
#   the cascade engine silently ignores them (defensive log only).
#
# Hook contract: this is a CLI helper. Errors PROPAGATE (non-zero exit).
# When this is called from within a hook context (the bash orchestrator
# may swallow), errors still surface to stderr.
#
# Argv contract (no shell interpolation of user-controlled strings into
# Python source bodies — sec-001 / sys.argv pattern):
#   sys.argv[1] = tier_2_path           (always ~/.claude/modes/_global.yaml)
#   sys.argv[2] = tier_3_path           (active mode YAML path, or "" for Claude Mode)
#   sys.argv[3] = tier_4_path           (<repo>/.claude/modes/_repo.yaml, or "")
#   sys.argv[4] = claude_modes_id       (e.g., "claude-modes@local-dev")
#   sys.argv[5] = target_settings_local_path  (<repo>/.claude/settings.local.json)
#   sys.argv[6] = sidecar_path          (<repo>/.claude/modes/.cascade-meta.json)
#
# Exit codes:
#   0 = success
#   1 = R22 violation (claude-modes not in cascade total)
#   2 = YAML parse error
#   3 = file I/O error
#   4 = R30 symlink security error
#   5 = R28 unexpected hooks-in-tier (defensive — write-mode-yaml.sh should
#       have refused at write time)
#   6 = malformed argv contract
#
# Why explicit `raise` instead of `assert`:
#   `python3 -O` strips assert statements. Load-bearing security
#   enforcements must survive the optimizer flag. See
#   feedback_deterministic_over_probabilistic_v1.

import datetime
import hashlib
import json
import os
import stat
import sys
import tempfile
from typing import Any

# Python-side terminal-escape defense (the language-boundary twin of
# lib/sanitize.sh). Every externally-controlled value (tier-4 _repo.yaml
# content, clone-dir-derived paths, YAML-parse-error snippets) routed into a
# human-facing stderr message MUST go through sanitize_for_display, or a
# hostile clone can inject ESC/OSC/CSI/bidi bytes into the terminal.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sanitize import sanitize_for_display  # noqa: E402

try:
    import yaml
except ImportError:
    sys.stderr.write(
        "cascade-engine.py: PyYAML not available. On macOS use /usr/bin/python3 "
        "(ships with PyYAML). Set CLAUDE_MODES_PYTHON3 accordingly.\n"
    )
    sys.exit(3)


PLUGIN_OWNED_KEYS_V2 = ["enabledPlugins"]


class SecurityError(Exception):
    """Raised on R28, R30, or other load-bearing security invariants."""


def _safe_load(path: str) -> dict:
    """yaml.safe_load on path; empty dict on missing or empty path."""
    if not path:
        return {}
    try:
        with open(path, "r") as f:
            data = yaml.safe_load(f)
    except FileNotFoundError:
        sys.stderr.write(
            f"cascade-engine: tier file not found: "
            f"{sanitize_for_display(path)}\n"
        )
        sys.exit(3)
    except yaml.YAMLError as e:
        # PyYAML's YAMLError.__str__ embeds get_snippet() — a slice of the raw
        # source — so str(e) for a tier-4 _repo.yaml carries attacker bytes.
        sys.stderr.write(
            f"cascade-engine: YAML parse error in "
            f"{sanitize_for_display(path)}: {sanitize_for_display(str(e))}\n"
        )
        sys.exit(2)
    except OSError as e:
        sys.stderr.write(
            f"cascade-engine: I/O error reading "
            f"{sanitize_for_display(path)}: {sanitize_for_display(str(e))}\n"
        )
        sys.exit(3)
    # A YAML document with a list/scalar root (e.g. "- foo" or "42") parses
    # without error but is not a tier mapping. `data or {}` only guards
    # None/empty, so a non-dict would flow into _extract_enabled_plugins and
    # raise AttributeError on .get() — a raw traceback + exit 1 instead of
    # the documented exit 2. Reject non-mappings here (mirrors the isinstance
    # guard in _read_existing_settings_local).
    if data is not None and not isinstance(data, dict):
        sys.stderr.write(
            f"cascade-engine: tier file {sanitize_for_display(path)} must be "
            f"a YAML mapping, got {type(data).__name__}\n"
        )
        sys.exit(2)
    return data or {}


def _check_tier_4_symlink_safety(tier_4_path: str) -> None:
    """R30: refuse if tier-4 _repo.yaml is reachable only through a symlink.

    Two attack vectors:
      1. LEAF symlink: _repo.yaml itself is a symlink -> /etc/passwd etc.
         Caught by the lstat S_ISLNK check.
      2. ANCESTOR symlink: an intermediate dir (e.g. <repo>/.claude/modes is
         itself a committed directory symlink to an attacker dir) makes the
         leaf a regular file whose REALPATH lands outside the repo tree. The
         leaf lstat passes, but the content the cascade reads/hashes/trusts
         is attacker-controlled and outside the repo. Caught by the realpath
         containment check below.

    tier_4_path is always <repo>/.claude/modes/_repo.yaml, so the repo root
    is dirname^3. We require realpath(_repo.yaml) to stay under
    realpath(repo_root) — closing both leaf and ancestor symlink escapes.
    """
    if not tier_4_path or not os.path.exists(tier_4_path):
        return

    # Leaf symlink (lstat examines the link itself, not its target).
    st = os.lstat(tier_4_path)
    if stat.S_ISLNK(st.st_mode):
        # tier_4_path is clone-dir-derived (attacker-controlled). Sanitize at
        # CONSTRUCTION so the exception can't carry raw bytes to any catch site.
        raise SecurityError(
            f"R30: tier-4 _repo.yaml must not be a symlink — "
            f"content must be in the repo's tree directly: "
            f"{sanitize_for_display(tier_4_path)}"
        )

    # Ancestor-directory symlink escape: realpath must remain inside the repo.
    repo_root = os.path.dirname(os.path.dirname(os.path.dirname(tier_4_path)))
    real_repo = os.path.realpath(repo_root)
    real_leaf = os.path.realpath(tier_4_path)
    # Containment: real_leaf must equal real_repo or be a child of it.
    if real_leaf != real_repo and not real_leaf.startswith(real_repo + os.sep):
        # tier_4_path + real_leaf are attacker-controlled (clone path + symlink
        # target realpath). Sanitize at construction. real_repo is the victim's
        # own clone root — sanitize it too for uniformity (cheap, no downside).
        raise SecurityError(
            f"R30: tier-4 _repo.yaml resolves outside the repo tree "
            f"(ancestor-directory symlink escape) — "
            f"{sanitize_for_display(tier_4_path)} -> "
            f"{sanitize_for_display(real_leaf)}, not under "
            f"{sanitize_for_display(real_repo)}"
        )


def _extract_enabled_plugins(tier_data: dict) -> dict:
    """Extract mechanism.enabledPlugins from a tier. Returns {} if absent.

    Tier shape:
        mechanism:
          enabledPlugins:
            "name@marketplace": true|false
    """
    mech = tier_data.get("mechanism") or {}
    ep = mech.get("enabledPlugins") or {}
    if not isinstance(ep, dict):
        return {}
    return dict(ep)


def _extract_disable_enabled_plugins(tier_data: dict) -> list:
    """Extract disable.enabledPlugins list. Returns [] if absent.

    Tier shape:
        disable:
          enabledPlugins:
            - "name@marketplace"
            - ...
    """
    dis = tier_data.get("disable") or {}
    ep = dis.get("enabledPlugins") or []
    if not isinstance(ep, list):
        return []
    return [str(x) for x in ep]


def _defensive_hooks_warning(tier_label: str, tier_data: dict) -> None:
    """V2.0: any cascade YAML may declare mechanism.hooks but it's IGNORED.

    The V2.0 cascade only flows enabledPlugins (PLUGIN_OWNED_KEYS_V2), so
    mechanism.hooks in ANY tier — tier_2 (_global.yaml), tier_3 (mode YAML),
    or tier_4 (_repo.yaml) — is silently dropped. write-mode-yaml.sh rejects
    tier-3 hooks at write time (R28), but tier-2/tier-4 files are hand-edited
    and have no write-time guard, so this warning is the only signal a user
    gets that their hooks won't take effect (api-contract re-review finding:
    the SKILL used to direct users to put hooks here, and they vanished
    without a trace). Fires for every tier.
    """
    mech = tier_data.get("mechanism") or {}
    if "hooks" in mech:
        sys.stderr.write(
            f"cascade-engine: warning — {tier_label} cascade YAML declares "
            f"mechanism.hooks but V2.0 silently ignores it (cascade only "
            f"flows enabledPlugins). Hooks belong in ~/.claude/settings.json "
            f"or <repo>/.claude/hooks/hooks.json, not in a cascade YAML.\n"
        )


def _merge_enabled_plugins(tiers: list) -> dict:
    """Merge enabledPlugins across tiers in order.

    Each tier is (label, data). For each tier:
      1. Union its mechanism.enabledPlugins into the cascade total,
         later tiers overriding the boolean for matching keys.
      2. Subtract any keys listed in its disable.enabledPlugins from
         the running total (removal, not set-to-false).

    Returns the merged dict {name@marketplace: bool}.
    """
    cascade: dict = {}
    for label, data in tiers:
        _defensive_hooks_warning(label, data)
        add = _extract_enabled_plugins(data)
        for key, value in add.items():
            cascade[key] = bool(value)
        for key in _extract_disable_enabled_plugins(data):
            cascade.pop(key, None)
    return cascade


_R22_ALLOWED_MARKETPLACES = frozenset({
    "local-dev",
    "every-marketplace",
    "anthropic-marketplace",
    "claude-plugins-official",
})


def _assert_r22(cascade: dict, claude_modes_id: str) -> None:
    """R22: claude-modes must be enabled in the cascade total.

    "Every mode" must have claude-modes in its effective enabledPlugins;
    otherwise /mode:set would wedge the user out of the plugin.

    Error message MUST contain "claude-modes" and "every mode" — tests
    grep for both substrings.

    Security (P1, sec-002/adv-001): R22 originally used `startswith(
    "claude-modes@")`, which let `claude-modes@evil-marketplace: true`
    satisfy the check. Now we require either the configured identifier or
    membership in the known-marketplace allowlist (exact-key match).
    """
    if cascade.get(claude_modes_id) is True:
        return
    # Exact-key fallback against the marketplace allowlist — survives
    # republication to a different known marketplace without weakening
    # the check to a substring match.
    for marketplace in _R22_ALLOWED_MARKETPLACES:
        candidate = "claude-modes@{}".format(marketplace)
        if cascade.get(candidate) is True:
            return
    # The cascade key listing includes tier-4 (_repo.yaml) plugin keys, which
    # are fully attacker-controlled. Sanitize EACH key (the bracket/quote
    # punctuation from sorted()/repr is ours, not attacker bytes). claude_modes_id
    # is the resolved self-identifier (ours), left as-is.
    cascade_keys = sorted(
        sanitize_for_display(k) for k, v in cascade.items() if v
    )
    raise SecurityError(
        f"R22: claude-modes must be enabled in every mode's cascade total "
        f"(expected '{claude_modes_id}' or one of "
        f"{sorted('claude-modes@' + m for m in _R22_ALLOWED_MARKETPLACES)} "
        f"to be true). Cascade total has: {cascade_keys}"
    )


def _read_existing_settings_local(path: str) -> dict:
    """Read current settings.local.json (preserves non-plugin-owned keys).

    Returns {} if file is absent. Strict-JSON parse error → exit 3.
    """
    if not os.path.exists(path):
        return {}
    try:
        with open(path, "r") as f:
            text = f.read()
        if not text.strip():
            return {}
        return json.loads(text)
    except json.JSONDecodeError as e:
        sys.stderr.write(
            f"cascade-engine: existing settings.local.json at "
            f"{sanitize_for_display(path)} "
            f"is not valid JSON: {sanitize_for_display(str(e))}. Refusing to "
            f"overwrite to preserve user data — please fix or remove the file "
            f"manually.\n"
        )
        sys.exit(3)
    except OSError as e:
        sys.stderr.write(
            f"cascade-engine: I/O error reading "
            f"{sanitize_for_display(path)}: {sanitize_for_display(str(e))}\n"
        )
        sys.exit(3)


def _atomic_write_0600(target_path: str, content_bytes: bytes) -> None:
    """Write content_bytes to target_path atomically, born at 0600.

    Idiom: (umask 077) mkstemp in same dir as target, write, fsync,
    rename. The mkstemp result is born at 0600 because we set umask
    before calling tempfile.mkstemp.
    """
    target_dir = os.path.dirname(target_path) or "."
    os.makedirs(target_dir, mode=0o700, exist_ok=True)

    old_umask = os.umask(0o077)
    try:
        fd, tmp_path = tempfile.mkstemp(
            prefix=".cascade.", suffix=".tmp", dir=target_dir
        )
    finally:
        os.umask(old_umask)

    try:
        with os.fdopen(fd, "wb") as f:
            f.write(content_bytes)
            f.flush()
            os.fsync(f.fileno())
        # Defensive: re-assert 0600 after fdopen close (some platforms
        # respect umask, some don't on mkstemp).
        if not os.path.islink(tmp_path):
            os.chmod(tmp_path, 0o600)
        os.rename(tmp_path, target_path)
    except Exception:
        # Clean up tmp on any failure before re-raising.
        try:
            os.unlink(tmp_path)
        except FileNotFoundError:
            pass
        raise

    # Defensive: re-assert 0600 after rename (rename preserves perms but
    # belt-and-suspenders for filesystems that may behave oddly).
    if not os.path.islink(target_path):
        try:
            os.chmod(target_path, 0o600)
        except OSError:
            pass


def _sha256_of_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _warn_if_settings_hand_edited(
    target_settings_local_path: str, sidecar_path: str
) -> None:
    """adv-006: warn (don't abort) if settings.local.json drifted from the
    last cascade's recorded fingerprint.

    Best-effort: any read/parse failure is swallowed (proceed silently).
    First-time set (no sidecar yet) and idempotent re-set (fingerprint
    matches) both stay silent.
    """
    if not os.path.exists(sidecar_path):
        return
    if not os.path.exists(target_settings_local_path):
        return
    try:
        with open(sidecar_path, "r") as f:
            prev_sidecar = json.load(f)
        prev_fingerprint = prev_sidecar.get("fingerprint")
        if not prev_fingerprint:
            return
        with open(target_settings_local_path, "rb") as f:
            current_fingerprint = _sha256_of_bytes(f.read())
        if current_fingerprint != prev_fingerprint:
            sys.stderr.write(
                "cascade-engine: WARNING — settings.local.json at "
                f"{sanitize_for_display(target_settings_local_path)} changed "
                "since the last "
                "/mode:set (sidecar fingerprint mismatch). Plugin-owned keys "
                "(enabledPlugins) are recompiled from the mode YAMLs; other "
                "keys are preserved verbatim. If you meant to manage plugins "
                "directly, edit the mode YAMLs in ~/.claude/modes/ instead. "
                "(Editing _repo.yaml also triggers this warning — that is a "
                "legitimate input change, not a lost edit.)\n"
            )
    except (OSError, json.JSONDecodeError, KeyError, TypeError):
        return


def main() -> int:
    if len(sys.argv) != 7:
        sys.stderr.write(
            "cascade-engine.py: expected 6 argv: tier_2_path tier_3_path "
            "tier_4_path claude_modes_id target_settings_local_path "
            "sidecar_path\n"
        )
        return 6

    tier_2_path = sys.argv[1]
    tier_3_path = sys.argv[2]
    tier_4_path = sys.argv[3]
    claude_modes_id = sys.argv[4]
    target_settings_local_path = sys.argv[5]
    sidecar_path = sys.argv[6]

    if not tier_2_path:
        sys.stderr.write(
            "cascade-engine.py: tier_2_path (argv[1]) is required (always "
            "~/.claude/modes/_global.yaml)\n"
        )
        return 6
    if not target_settings_local_path:
        sys.stderr.write(
            "cascade-engine.py: target_settings_local_path (argv[5]) is "
            "required\n"
        )
        return 6
    if not sidecar_path:
        sys.stderr.write(
            "cascade-engine.py: sidecar_path (argv[6]) is required\n"
        )
        return 6
    if not claude_modes_id:
        sys.stderr.write(
            "cascade-engine.py: claude_modes_id (argv[4]) is required\n"
        )
        return 6

    # ─── R30: symlink-safety check on tier 4 before anything else ──────
    try:
        _check_tier_4_symlink_safety(tier_4_path)
    except SecurityError as e:
        sys.stderr.write(f"cascade-engine: {e}\n")
        return 4

    # ─── Load tiers ────────────────────────────────────────────────────
    tier_2_data = _safe_load(tier_2_path)
    tier_3_data = _safe_load(tier_3_path) if tier_3_path else {}
    tier_4_data = _safe_load(tier_4_path) if tier_4_path else {}

    # ─── Cascade merge in tier order ───────────────────────────────────
    tiers = [
        ("tier_2", tier_2_data),
        ("tier_3", tier_3_data),
        ("tier_4", tier_4_data),
    ]
    merged_enabled_plugins = _merge_enabled_plugins(tiers)

    # ─── R22 cascade-total assertion ───────────────────────────────────
    try:
        _assert_r22(merged_enabled_plugins, claude_modes_id)
    except SecurityError as e:
        sys.stderr.write(f"cascade-engine: {e}\n")
        return 1

    # ─── Preserve non-plugin-owned keys verbatim from existing file ────
    existing = _read_existing_settings_local(target_settings_local_path)

    # ─── adv-006: warn if settings.local.json was hand-edited ──────────
    # If the current file's sha256 differs from the fingerprint the last
    # cascade recorded in the sidecar, the user (or another tool) modified
    # settings.local.json since the last /mode:set. We WARN but PROCEED:
    # cascade is idempotent and self-healing, plugin-owned keys are
    # recompiled deterministically from the mode YAMLs, and non-plugin-owned
    # keys are preserved verbatim (above). Aborting here would wedge
    # /mode:set on a single stray edit for zero security gain.
    #
    # Known false-positive: editing _repo.yaml (a legitimate INPUT change)
    # also shifts the fingerprint, so the warning can fire after a tier-4
    # edit even though settings.local.json itself wasn't hand-edited.
    # Distinguishing the two would require re-running the cascade twice;
    # not worth it for V2.0. The warning text names enabledPlugins so a
    # user who edited a YAML understands why their plugin set recompiled.
    _warn_if_settings_hand_edited(target_settings_local_path, sidecar_path)

    # Build output: everything from existing EXCEPT the plugin-owned
    # keys (which we replace), plus our merged values for owned keys.
    output: dict[str, Any] = {}
    for key, value in existing.items():
        if key not in PLUGIN_OWNED_KEYS_V2:
            output[key] = value
    output["enabledPlugins"] = dict(sorted(merged_enabled_plugins.items()))

    # ─── Serialize + write atomically ──────────────────────────────────
    # Stable key order; trailing newline for tidiness with editors.
    serialized = json.dumps(output, indent=2, sort_keys=True).encode("utf-8")
    serialized = serialized + b"\n"

    try:
        _atomic_write_0600(target_settings_local_path, serialized)
    except OSError as e:
        sys.stderr.write(
            f"cascade-engine: atomic write to "
            f"{sanitize_for_display(target_settings_local_path)} failed: "
            f"{sanitize_for_display(str(e))}\n"
        )
        return 3

    # ─── Sidecar: fingerprint + compiled_at + source_modes ─────────────
    fingerprint = _sha256_of_bytes(serialized)

    source_modes = ["_global.yaml"]
    if tier_3_path:
        # Strip dir + .yaml suffix for display ("delivery", "writing", ...)
        source_modes.append(os.path.splitext(os.path.basename(tier_3_path))[0])
    if tier_4_path and os.path.exists(tier_4_path):
        source_modes.append("_repo.yaml")

    sidecar_obj = {
        "tool": "claude-modes",
        "version": "2.0",
        "fingerprint": fingerprint,
        # kieran-python-002: datetime.utcnow() is deprecated (3.12) / removed
        # (3.15). Timezone-aware now(UTC) produces the same "...Z" string.
        "compiled_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source_modes": source_modes,
    }
    sidecar_bytes = (
        json.dumps(sidecar_obj, indent=2, sort_keys=True) + "\n"
    ).encode("utf-8")

    try:
        _atomic_write_0600(sidecar_path, sidecar_bytes)
    except OSError as e:
        sys.stderr.write(
            f"cascade-engine: atomic write to sidecar "
            f"{sanitize_for_display(sidecar_path)} "
            f"failed: {sanitize_for_display(str(e))}\n"
        )
        return 3

    # Emit fingerprint + meta to stdout for the orchestrator to capture
    # (one JSON line for easy parsing).
    sys.stdout.write(
        json.dumps(
            {
                "fingerprint": fingerprint,
                "settings_local": target_settings_local_path,
                "sidecar": sidecar_path,
                "enabledPlugins_count": len(merged_enabled_plugins),
            }
        )
        + "\n"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
