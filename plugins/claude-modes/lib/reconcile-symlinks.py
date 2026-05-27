#!/usr/bin/env python3
# claude-modes V2 (U9): SessionStart reconciliation orchestrator.
#
# Purpose:
#   Reconcile the live ~/.claude/commands and ~/.claude/agents user-catalog
#   symlinks with the active mode's user_catalog manifest, accounting for
#   the case where another worktree of the same repo concurrently changed
#   the active mode.
#
# Architectural note (V2):
#   The canonical slate-weekly-gist flock pattern uses `os.execvp` to bridge
#   a Python lock-acquirer into a bash script that runs the critical
#   section. V2 eliminates the bridge: Python IS the orchestrator for the
#   entire reconciliation. The Python process holds the FD for its entire
#   lifetime; the lock releases when the kernel cleans up the FD on process
#   exit. Net correctness: identical to the canonical pattern. Net code:
#   simpler — no exec, no environment marshalling.
#
# Contract (rel-001 carry-forward from V1):
#   - SessionStart hooks must NEVER propagate errors. main() is wrapped in a
#     bare try/except that ALWAYS exits 0. Any failure is best-effort logged
#     to ~/.claude/modes/.session-start.log and ~/.claude/modes/.audit.log.
#   - Lock acquire timeout is bounded (3s) to honor SessionStart's tight
#     5s start budget; on timeout, audit "timeout" outcome and exit 0.
#
# Session-key parity with inject-prose.sh:
#   The divergence-toast marker filename uses the same session_key derivation
#   as lib/inject-prose.sh:
#     - Read stdin event JSON for "session_id" field (Claude Code SessionStart
#       hook convention).
#     - If absent/empty/unparseable, fall back to "ppid-<PPID>".
#   Drift here would orphan the toast (inject-prose would never consume it).
#
# State files written/read:
#   - Lock:    ~/.claude/modes/.symlink-lock         (user-global flock; FD held)
#   - Toast:   ~/.claude/modes/.sessions/<key>.divergence-toast (O_EXCL, 0600)
#   - Log:     ~/.claude/modes/.session-start.log    (append-only; contract anchor)
#   - Audit:   ~/.claude/modes/.audit.log            (via lib/audit.sh subprocess)
#
# Per-branch state read:
#   - <repo>/.claude/modes/<branch-slug>.mode — file body = mode name
#     (or empty for Claude Mode)
#   - Fallback: ~/.claude/modes/.last-active-mode (user-global)

import errno
import fcntl
import json
import os
import re
import signal
import subprocess
import sys
import time
from typing import Any, Optional, Tuple, List, Set


CLAUDE_MODES_PYTHON3 = os.environ.get("CLAUDE_MODES_PYTHON3", "/usr/bin/python3")
HOME = os.environ.get("HOME", "")

MODES_DIR = os.path.join(HOME, ".claude", "modes")
USER_CATALOG_ROOT = os.path.join(MODES_DIR, ".user-catalog")
COMMANDS_LIVE = os.path.join(HOME, ".claude", "commands")
AGENTS_LIVE = os.path.join(HOME, ".claude", "agents")
COMMANDS_STAGING = os.path.join(USER_CATALOG_ROOT, "commands")
AGENTS_STAGING = os.path.join(USER_CATALOG_ROOT, "agents")
LOCK_PATH = os.path.join(MODES_DIR, ".symlink-lock")
SESSIONS_DIR = os.path.join(MODES_DIR, ".sessions")
SESSION_LOG = os.path.join(MODES_DIR, ".session-start.log")
LAST_ACTIVE_MODE = os.path.join(MODES_DIR, ".last-active-mode")

# Contract anchor — printed to .session-start.log on every invocation.
# Future Claude Code harness changes should trigger a search for this string.
CONTRACT_ANCHOR = (
    "claude-modes v2: SessionStart reconciler assumes flock(2) semantics + "
    "git rev-parse / symbolic-ref on PATH + ~/.claude/modes/ owned 0700."
)

LOCK_TIMEOUT_SECONDS = 3  # of the SessionStart 5s budget — leaves slack for the rebuild itself

# ──────────────────────────────────────────────────────────────────────────
# Lightweight logging — never raises.


def _log_session(msg: str) -> None:
    """Best-effort append to ~/.claude/modes/.session-start.log."""
    try:
        os.makedirs(MODES_DIR, mode=0o700, exist_ok=True)
        ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        line = "{ts}\t{msg}\n".format(ts=ts, msg=msg.replace("\n", " ").replace("\t", " "))
        # Open with 0600. We do not chmod every append (the contract anchor
        # gets repeated, and the file is already private-by-default since
        # MODES_DIR is 0700). umask 077 on creation ensures 0600 first write.
        old_umask = os.umask(0o077)
        try:
            with open(SESSION_LOG, "a") as f:
                f.write(line)
        finally:
            os.umask(old_umask)
    except Exception:
        # Never propagate.
        pass


def _audit_event(event: str, **fields: Any) -> None:
    """Best-effort delegation to lib/audit.sh — keeps schema parity."""
    try:
        plugin_root = os.path.dirname(os.path.abspath(__file__))
        # Plugin root is the parent of lib/.
        plugin_root = os.path.dirname(plugin_root)
        audit_sh = os.path.join(plugin_root, "lib", "audit.sh")
        if not os.path.isfile(audit_sh):
            # Fallback: write directly to .audit.log in our log format.
            _log_session("audit_unavailable event=" + event)
            return
        args = [event] + ["{}={}".format(k, v) for k, v in fields.items()]
        subprocess.run(
            ["bash", audit_sh] + args,
            timeout=2,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except Exception:
        pass


# ──────────────────────────────────────────────────────────────────────────
# Session-key derivation — parity with inject-prose.sh.


def _read_session_id() -> str:
    """Read session_id from SessionStart event JSON on stdin.

    Empty/unparseable/missing → fall back to ppid-<PPID> (matches the
    inject-prose.sh derivation so the divergence-toast filename collides
    on the consumer side).
    """
    # If stdin is a TTY (no piped JSON), skip the read — avoids blocking.
    try:
        if sys.stdin.isatty():
            return "ppid-{}".format(os.getppid())
    except Exception:
        pass

    raw = ""
    try:
        # Read with a short timeout via select to avoid blocking forever.
        import select

        readable, _, _ = select.select([sys.stdin], [], [], 0.05)
        if readable:
            raw = sys.stdin.read()
    except Exception:
        raw = ""

    if raw:
        try:
            data = json.loads(raw)
            sid = data.get("session_id") if isinstance(data, dict) else None
            if isinstance(sid, str) and sid:
                return sid
        except Exception:
            pass

    return "ppid-{}".format(os.getppid())


# ──────────────────────────────────────────────────────────────────────────
# Branch resolution + slugify.


def _gated_repo_root(cwd: str) -> Optional[str]:
    """READ-side repo root: nearest ancestor of cwd with a .claude/modes/
    directory under which cwd is git-tracked. None otherwise.

    Python mirror of claude_modes::current_repo_root (lib/repo-root.sh). MUST
    stay behavior-equivalent — pinned by mode-body-read-equivalence. This is
    NOT bare `git rev-parse --show-toplevel`: that would let an untracked
    scratch dir under a modes-using project inherit the project's per-branch
    pin (the cross-project leak). Walk up for the .claude/modes/ opt-in marker
    AND require cwd to be git-tracked under it.
    """
    try:
        home_canon = os.path.realpath(os.path.expanduser("~"))
        cur = os.path.realpath(cwd)
    except OSError:
        return None
    d = cur
    while d and d != "/" and d != home_canon:
        if os.path.isdir(os.path.join(d, ".claude", "modes")):
            # cwd == project root always qualifies.
            if cur == d:
                return d
            relpath = os.path.relpath(cur, d)
            # Non-empty ls-files stdout = some tracked file lives under cwd.
            try:
                proc = subprocess.run(
                    ["git", "-C", d, "ls-files", "--", relpath],
                    capture_output=True,
                    text=True,
                    timeout=2,
                )
                if proc.returncode == 0 and proc.stdout.strip():
                    return d
            except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
                pass
            # Marker found but cwd untracked → inner marker claims this
            # subtree; do not walk further.
            return None
        d = os.path.dirname(d)
    return None


def _resolve_branch(cwd: str) -> Tuple[Optional[str], Optional[str]]:
    """Return (branch_or_detached, repo_root). Both None if no git repo.

    repo_root here is the BARE working-tree toplevel — it answers "am I in a
    git repo at all," which reconcile uses for the no-repo vs no-mode vs
    reconcile 3-way classification and for reading per-branch state. The
    read-side leak gate (walk-up for .claude/modes marker + git-tracked cwd)
    is applied SEPARATELY at the per-branch-pin decision in main() via
    _gated_repo_root — NOT here. Conflating the two collapses no-repo and
    no-mode into one bucket (regression caught by worktree-mode-reconciliation).
    """
    # repo root — bare --show-toplevel (the read-path-toplevel-lint excuses
    # this via the inline marker below). The gate is applied SEPARATELY at
    # the per-branch-pin decision in main() via _gated_repo_root; here the
    # bare toplevel is needed for the 3-way no-repo/no-mode/reconcile
    # classification. See the docstring above.
    try:
        proc = subprocess.run(
            # lint: read-path-toplevel-ok — gate applied in main() via _gated_repo_root
            ["git", "-C", cwd, "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            timeout=2,
        )
        if proc.returncode != 0:
            return None, None
        repo_root = proc.stdout.strip()
        if not repo_root:
            return None, None
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return None, None

    # symbolic-ref → branch
    try:
        proc = subprocess.run(
            ["git", "-C", repo_root, "symbolic-ref", "--quiet", "HEAD"],
            capture_output=True,
            text=True,
            timeout=2,
        )
        if proc.returncode == 0:
            ref = proc.stdout.strip()
            if ref.startswith("refs/heads/"):
                return ref[len("refs/heads/"):], repo_root
            if ref:
                return ref, repo_root
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        pass

    # Detached HEAD: fall back to short SHA.
    try:
        proc = subprocess.run(
            ["git", "-C", repo_root, "rev-parse", "--short", "HEAD"],
            capture_output=True,
            text=True,
            timeout=2,
        )
        if proc.returncode == 0:
            sha = proc.stdout.strip()
            if sha:
                return "detached-{}".format(sha), repo_root
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        pass

    # Repo found but HEAD unresolvable (e.g., brand-new repo with no commit).
    return None, repo_root


# Slugify parity with lib/validate-mode-name.sh::slugify_branch.
# Bash version:
#   LC_ALL=C tr -c 'A-Za-z0-9_-' '-' | sed -E 's/-+/-/g' | sed -E 's/^-+//; s/-+$//'
# then reject empty | . | .. | *..*  (no .. can appear after tr-and-collapse,
# so this is effectively just an empty/. check post-normalization).
_SLUG_TR_RE = re.compile(rb"[^A-Za-z0-9_-]")


def _slugify_branch(branch: str) -> Optional[str]:
    if not branch:
        return None
    try:
        encoded = branch.encode("utf-8", errors="replace")
    except Exception:
        return None
    replaced = _SLUG_TR_RE.sub(b"-", encoded)
    # Collapse runs of '-'
    collapsed = re.sub(rb"-+", b"-", replaced)
    # Strip leading/trailing '-'
    stripped = collapsed.strip(b"-")
    if not stripped:
        return None
    slug = stripped.decode("ascii", errors="replace")
    if slug in (".", "..") or ".." in slug:
        return None
    return slug


# ──────────────────────────────────────────────────────────────────────────
# Per-branch / user-global mode resolution.


_VALID_MODE_NAME_RE = re.compile(rb"^[A-Za-z0-9_-]+$")
_RESERVED_MODE_TOKENS = frozenset({
    "default", "none", "set", "status", "clear", "apply", "registry",
    "adopt", "setup", "list", "help", "promote", "rebuild", "coverage",
    "claude", "_global", "_repo",
})


def _validate_mode_body(name: Optional[str]) -> bool:
    """Path-traversal-safe validation for .mode file body content.

    Mirrors claude_modes::validate_name rules from lib/validate-mode-name.sh.
    Returns True iff `name` is safe to use as a path component.

    Security (sec-001 P0): .mode file bodies are attacker-controllable via
    a committed `.claude/modes/<slug>.mode` in a public repo; without this
    gate, a body of `../../tmp/evil` would redirect the cascade to load
    attacker-controlled YAML and (worst case) write attacker symlinks into
    ~/.claude/commands/ via mechanism.user_catalog. Behavior-equivalence
    test at tests/integration/active-mode-resolver-equivalence.test.sh.
    """
    if not name:
        return False
    if len(name) > 64:
        return False
    if name in (".", "..") or ".." in name:
        return False
    if name.startswith("-") or name.startswith("_") or name.endswith("-") or name.endswith("_"):
        return False
    if not _VALID_MODE_NAME_RE.match(name.encode("ascii", errors="replace")):
        return False
    if name in _RESERVED_MODE_TOKENS:
        return False
    return True


def _is_valid_mode_marker(body: Optional[str]) -> bool:
    """True if `body` is either a valid mode name OR the Claude-Mode alias.

    The .mode file can contain either:
      - a real mode name (validated via _validate_mode_body), or
      - the literal sentinel "claude" meaning Claude Mode (no tier-3 contribution).

    "claude" is a reserved token (cannot be NAMED as a user-defined mode), but
    it IS a valid sentinel value at the read site. Day-zero installs and
    explicit user opt-out write "claude" here.
    """
    if body == "claude":
        return True
    return _validate_mode_body(body)


def _read_per_branch_mode(repo_root: str, slug: str) -> Optional[str]:
    """Read <repo>/.claude/modes/<slug>.mode. Returns:
      - mode name string OR the Claude-Mode "claude" sentinel
      - None if file missing or body fails validation.
    """
    mode_file = os.path.join(repo_root, ".claude", "modes", "{}.mode".format(slug))
    try:
        if not os.path.isfile(mode_file):
            return None
        with open(mode_file, "r") as f:
            body = f.read().strip()
        if not _is_valid_mode_marker(body):
            return None
        return body
    except Exception:
        return None


def _read_last_active_mode() -> Optional[str]:
    try:
        if not os.path.isfile(LAST_ACTIVE_MODE):
            return None
        with open(LAST_ACTIVE_MODE, "r") as f:
            body = f.read().strip()
        if not _is_valid_mode_marker(body):
            return None
        return body
    except Exception:
        return None


def _resolve_mode_yaml_path(mode_name: str) -> Optional[str]:
    """Resolve to ~/.claude/modes/<mode>.yaml. None if missing or unsafe.

    Defense-in-depth: _validate_mode_body is the primary gate. The "claude"
    sentinel never resolves to a YAML path (Claude Mode has no tier-3 YAML).
    """
    if not mode_name or mode_name == "claude":
        return None
    if not _validate_mode_body(mode_name):
        return None
    p = os.path.join(MODES_DIR, "{}.yaml".format(mode_name))
    return p if os.path.isfile(p) else None


# ──────────────────────────────────────────────────────────────────────────
# Mode-YAML manifest reading via lib/mode-yaml.sh subprocess.
#
# We deliberately do NOT import yaml in this process. lib/mode-yaml.sh
# already encapsulates yaml.safe_load + schema validation; calling it as a
# subprocess preserves the single-source-of-truth on schema interpretation
# and means this orchestrator works even when PyYAML isn't importable
# (e.g., a live SessionStart hook where the test-suite's PYTHONPATH leak
# doesn't apply).


def _read_manifest(mode_yaml_path: str) -> Tuple[List[str], List[str]]:
    """Return (commands_entries, agents_entries) from the mode YAML's
    mechanism.user_catalog block. Empty lists on any failure."""
    plugin_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    mode_yaml_sh = os.path.join(plugin_root, "lib", "mode-yaml.sh")

    def _query(category: str) -> List[str]:
        try:
            proc = subprocess.run(
                ["bash", mode_yaml_sh, "user-catalog", mode_yaml_path, category],
                capture_output=True,
                text=True,
                timeout=3,
            )
            if proc.returncode != 0:
                return []
            lines = [l for l in proc.stdout.splitlines() if l.strip()]
            return lines
        except Exception:
            return []

    return _query("commands"), _query("agents")


# ──────────────────────────────────────────────────────────────────────────
# Symlink enumeration / comparison.
#
# These functions duplicate symlink-rebuild.sh::enumerate_plugin_symlinks at
# the Bash↔Python language boundary. The duplication is DELIBERATE — see
# docs/solutions/2026-05-27-symlink-enum-dedup-rejected.md for the verdict:
# collapsing would replace ~1ms in-process enumeration with ~20ms-per-call
# subprocess startup, ~4 calls per SessionStart = 80ms+ added to the hot path.
# Not worth it. If drift becomes a risk, the right answer is an equivalence
# test (mirroring the validator + resolver patterns), not a collapse.


def _enumerate_plugin_symlinks(live_dir: str, staging_root: str) -> Set[str]:
    """Return the set of basenames in live_dir that are symlinks whose
    realpath resolves under staging_root. Non-plugin (alien) symlinks and
    regular files are NOT included."""
    out: Set[str] = set()
    if not os.path.isdir(live_dir):
        return out
    try:
        staging_real = os.path.realpath(staging_root)
    except Exception:
        return out
    try:
        with os.scandir(live_dir) as it:
            for entry in it:
                try:
                    if not entry.is_symlink():
                        continue
                    resolved = os.path.realpath(entry.path)
                    if resolved == staging_real:
                        continue
                    if resolved.startswith(staging_real + os.sep):
                        out.add(entry.name)
                except Exception:
                    continue
    except Exception:
        return out
    return out


def _enumerate_staging(staging_dir: str) -> Set[str]:
    """Return the set of basenames directly under staging_dir (files or symlinks)."""
    out: Set[str] = set()
    if not os.path.isdir(staging_dir):
        return out
    try:
        with os.scandir(staging_dir) as it:
            for entry in it:
                try:
                    if entry.is_file(follow_symlinks=False) or entry.is_symlink():
                        out.add(entry.name)
                except Exception:
                    continue
    except Exception:
        return out
    return out


def _current_symlinks_match(target_commands: Set[str], target_agents: Set[str]) -> bool:
    """Return True if the live plugin-owned symlink set already matches the target."""
    cur_cmds = _enumerate_plugin_symlinks(COMMANDS_LIVE, COMMANDS_STAGING)
    cur_agents = _enumerate_plugin_symlinks(AGENTS_LIVE, AGENTS_STAGING)
    return cur_cmds == target_commands and cur_agents == target_agents


# ──────────────────────────────────────────────────────────────────────────
# Divergence detection.
#
# Algorithm:
#   Enumerate every mode YAML in MODES_DIR. For each, compute its manifest
#   (commands ∪ agents). Find which mode (if any) the current live-symlink
#   set matches. If we found a match and that mode is DIFFERENT from the
#   branch's recorded intent, emit the one-time divergence toast — another
#   worktree of the same repo flipped to a different mode underfoot.
#
#   If no mode matches the current symlink set, return None (a hand-edit
#   landed; no toast). If the matching mode equals the intended mode, the
#   no-op fast path already exited; we shouldn't get here.


def _detect_divergent_mode(intended_mode: str) -> Optional[str]:
    """Return the name of the mode the current symlinks correspond to, IF
    that differs from `intended_mode` (else None — no toast)."""
    cur_cmds = _enumerate_plugin_symlinks(COMMANDS_LIVE, COMMANDS_STAGING)
    cur_agents = _enumerate_plugin_symlinks(AGENTS_LIVE, AGENTS_STAGING)

    try:
        candidates = []
        for fname in os.listdir(MODES_DIR):
            if not fname.endswith(".yaml"):
                continue
            base = fname[:-5]  # strip .yaml
            if base.startswith("_") or base.startswith("."):
                continue
            candidates.append(base)
    except Exception:
        return None

    for cand in candidates:
        if cand == intended_mode:
            # The intended mode would have hit the fast path. Skip — its
            # match here is uninteresting (it means we're already at the
            # target, but the fast path missed for some other reason).
            continue
        cand_yaml = _resolve_mode_yaml_path(cand)
        if cand_yaml is None:
            continue
        c_entries, a_entries = _read_manifest(cand_yaml)
        if set(c_entries) == cur_cmds and set(a_entries) == cur_agents:
            return cand
    return None


def _write_divergence_toast(
    session_key: str, branch_slug: str, intended: str, found: str
) -> bool:
    """Write a one-time marker. Returns True if successfully written, False if
    a marker already exists (O_EXCL collision)."""
    try:
        os.makedirs(SESSIONS_DIR, mode=0o700, exist_ok=True)
    except Exception:
        return False
    marker = os.path.join(SESSIONS_DIR, "{}.divergence-toast".format(session_key))
    msg = (
        "Mode-of-record for branch {slug} is {intended} but this repo's active "
        "settings reflect {found} (concurrent worktree). Run /mode:set {intended} "
        "to align, or accept the concurrent worktree's mode."
    ).format(slug=branch_slug, intended=intended, found=found)
    try:
        fd = os.open(marker, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        try:
            os.write(fd, msg.encode("utf-8"))
        finally:
            os.close(fd)
        return True
    except FileExistsError:
        return False
    except Exception:
        return False


# ──────────────────────────────────────────────────────────────────────────
# Rebuild dispatch — delegates to lib/symlink-rebuild.sh.


def _invoke_symlink_rebuild(mode_yaml_path: str) -> int:
    """Invoke lib/symlink-rebuild.sh with the mode YAML. Returns subprocess
    exit code; never raises."""
    plugin_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    rebuild_sh = os.path.join(plugin_root, "lib", "symlink-rebuild.sh")
    try:
        proc = subprocess.run(
            ["bash", "-c",
             '. "$1" && claude_modes::symlink_rebuild "$2"',
             "bash", rebuild_sh, mode_yaml_path],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if proc.returncode != 0:
            _log_session(
                "symlink_rebuild_nonzero rc={} stderr={}".format(
                    proc.returncode, proc.stderr.strip()[:300]
                )
            )
        return proc.returncode
    except subprocess.TimeoutExpired:
        _log_session("symlink_rebuild_timeout mode={}".format(mode_yaml_path))
        return 124
    except Exception as e:
        _log_session("symlink_rebuild_exception err={}".format(repr(e)[:200]))
        return 1


# ──────────────────────────────────────────────────────────────────────────
# Lock helpers.


class _LockTimeout(Exception):
    pass


def _acquire_lock(lock_fd: int, timeout_s: int) -> bool:
    """Acquire LOCK_EX on lock_fd. Returns True on success; False on timeout.
    Uses non-blocking probe first, then alarm-bounded blocking acquire."""
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return True
    except BlockingIOError:
        pass
    except OSError as e:
        if e.errno not in (errno.EWOULDBLOCK, errno.EAGAIN):
            raise
        # else: fall through

    def _on_alarm(signum, frame):
        raise _LockTimeout()

    prev_handler = signal.signal(signal.SIGALRM, _on_alarm)
    signal.alarm(timeout_s)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX)
        return True
    except _LockTimeout:
        return False
    except Exception:
        return False
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, prev_handler)


# ──────────────────────────────────────────────────────────────────────────
# Main flow.


def main() -> int:
    # Contract anchor written every invocation — useful for forensics if
    # SessionStart contract changes in a future Claude Code version.
    _log_session(CONTRACT_ANCHOR)

    # Optional test-only delay BEFORE acquiring the lock changes nothing.
    # But INSIDE the lock we honor a separate env-gate (see below) so the
    # flock contention test can force overlap.

    # Presence gate (the shim should already have done this; defensive copy).
    if not os.path.isdir(MODES_DIR):
        return 0

    session_key = _read_session_id()
    cwd = os.getcwd()

    branch, repo_root = _resolve_branch(cwd)

    if repo_root is None:
        # No git repo. Per spec: fall back to user-global last-active mode if any.
        intended_mode = _read_last_active_mode()
        if not intended_mode:
            _audit_event("session_reconcile", outcome="no-repo", branch_slug="(none)")
            return 0
        # User-global only — proceed with manifest reconciliation, no branch info.
        branch_slug = "(none)"
        return _reconcile_for_mode(intended_mode, branch_slug, session_key)

    branch_slug = _slugify_branch(branch) if branch else None
    if not branch_slug:
        branch_slug = "(none)"

    # Read per-branch state — but ONLY when cwd passes the read-side leak gate
    # (walk-up for a .claude/modes/ marker + git-tracked cwd). An untracked
    # scratch dir nested under a marked project is in a git repo (so repo_root
    # is set and we're past the no-repo branch), but must NOT inherit that
    # project's per-branch pin. The gated root must also match the classified
    # repo_root — a marker found higher up than the working-tree toplevel
    # doesn't apply. See lib/repo-root.sh / _gated_repo_root.
    intended_mode: Optional[str] = None
    gated_root = _gated_repo_root(cwd)
    if (
        gated_root
        and gated_root == repo_root
        and branch_slug
        and branch_slug != "(none)"
    ):
        intended_mode = _read_per_branch_mode(repo_root, branch_slug)

    if intended_mode is None:
        # No per-branch pin (or cwd gated out) → fall back to user-global.
        intended_mode = _read_last_active_mode()

    if intended_mode is None:
        # Truly no mode anywhere. No-op exit.
        _audit_event(
            "session_reconcile",
            outcome="no-mode",
            branch_slug=branch_slug,
        )
        return 0

    return _reconcile_for_mode(intended_mode, branch_slug, session_key)


def _reconcile_for_mode(intended_mode: str, branch_slug: str, session_key: str) -> int:
    """Core reconciliation: resolve mode YAML, compute target manifest, take
    the fast path or invoke rebuild."""
    # Empty mode body OR "claude" == Claude Mode == day-zero manifest. "claude"
    # is in lib/validate-mode-name.sh's reserved-tokens list precisely because
    # it represents the no-modes-active baseline.
    if intended_mode == "" or intended_mode == "claude":
        mode_yaml_path = ""  # symlink-rebuild treats "" as day-zero
        target_commands = _enumerate_staging(COMMANDS_STAGING)
        target_agents = _enumerate_staging(AGENTS_STAGING)
        mode_field = "(none)"
    else:
        mode_yaml_path_opt = _resolve_mode_yaml_path(intended_mode)
        if mode_yaml_path_opt is None:
            # Pointed at a mode YAML that no longer exists. Log + exit clean.
            _log_session(
                "missing_mode_yaml mode={} branch_slug={}".format(
                    intended_mode, branch_slug
                )
            )
            _audit_event(
                "session_reconcile",
                outcome="no-yaml",
                mode=intended_mode,
                branch_slug=branch_slug,
            )
            return 0
        mode_yaml_path = mode_yaml_path_opt
        c_entries, a_entries = _read_manifest(mode_yaml_path)
        target_commands = set(c_entries)
        target_agents = set(a_entries)
        mode_field = intended_mode

    # ─── Pre-lock fast path probe (advisory, racy by design — see TOCTOU recheck) ───
    if _current_symlinks_match(target_commands, target_agents):
        _audit_event(
            "session_reconcile",
            outcome="fast-path",
            mode=mode_field,
            branch_slug=branch_slug,
        )
        return 0

    # ─── Acquire the user-global symlink lock ──────────────────────────────
    # Ensure parent dir exists for the lock file itself.
    try:
        os.makedirs(MODES_DIR, mode=0o700, exist_ok=True)
        # 0o644 chosen for lock files (POSIX advisory locks need readable FD
        # on some systems; the directory is 0700 so still privacy-bounded).
        lock_fd = os.open(LOCK_PATH, os.O_CREAT | os.O_RDWR, 0o644)
    except Exception as e:
        _log_session("lock_open_failed err={}".format(repr(e)[:200]))
        _audit_event(
            "session_reconcile",
            outcome="lock-open-fail",
            mode=mode_field,
            branch_slug=branch_slug,
        )
        return 0

    try:
        if not _acquire_lock(lock_fd, LOCK_TIMEOUT_SECONDS):
            _log_session(
                "lock_timeout mode={} branch_slug={} timeout_s={}".format(
                    mode_field, branch_slug, LOCK_TIMEOUT_SECONDS
                )
            )
            _audit_event(
                "session_reconcile",
                outcome="timeout",
                mode=mode_field,
                branch_slug=branch_slug,
            )
            return 0

        # ─── TOCTOU re-check: state may have changed while we waited ──────
        if _current_symlinks_match(target_commands, target_agents):
            _audit_event(
                "session_reconcile",
                outcome="fast-path",
                mode=mode_field,
                branch_slug=branch_slug,
            )
            return 0

        # Test hook: simulate slow critical-section work so flock contention
        # tests can reliably overlap with a second invocation.
        sleep_s = os.environ.get("CLAUDE_MODES_RECONCILE_SLEEP_INSIDE_LOCK")
        if sleep_s:
            try:
                time.sleep(float(sleep_s))
            except ValueError:
                pass

        # ─── Divergence detection (pre-rebuild) ────────────────────────────
        outcome = "rebuilt"
        if intended_mode != "":
            divergent_from = _detect_divergent_mode(intended_mode)
            if divergent_from is not None:
                if _write_divergence_toast(
                    session_key, branch_slug, intended_mode, divergent_from
                ):
                    outcome = "diverge-toast"

        # ─── Invoke rebuild ────────────────────────────────────────────────
        rc = _invoke_symlink_rebuild(mode_yaml_path)
        if rc != 0:
            _audit_event(
                "session_reconcile",
                outcome="rebuild-fail",
                mode=mode_field,
                branch_slug=branch_slug,
                rc=str(rc),
            )
            return 0

        _audit_event(
            "session_reconcile",
            outcome=outcome,
            mode=mode_field,
            branch_slug=branch_slug,
        )
        return 0
    finally:
        # FD close releases the flock (kernel-level cleanup). We do it
        # explicitly here so the lock-held window is as small as possible
        # rather than relying on interpreter teardown.
        try:
            os.close(lock_fd)
        except Exception:
            pass


# ──────────────────────────────────────────────────────────────────────────
# Entrypoint with rel-001 safety net.

if __name__ == "__main__":
    try:
        sys.exit(main() or 0)
    except SystemExit:
        raise
    except BaseException:
        # rel-001 contract: SessionStart never propagates errors.
        try:
            _log_session("uncaught_exception_swallowed (rel-001)")
        except Exception:
            pass
        sys.exit(0)
