#!/usr/bin/env python3
"""The programme worktree: one detached git worktree the PM works from for the programme's life."""

from __future__ import annotations

import os
import shlex
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
import _bootstrap  # noqa: E402
from _bootstrap import load_lib_module  # noqa: E402

run_record_core = load_lib_module("run_record_core")
programme_exec = load_lib_module("programme_exec")
session_registry = load_lib_module("session_registry")

WORKTREES_DIR = "worktrees"
NAME_PREFIX = "programme-"
# A checkout of a large repo writes every tracked file; a killed add leaves a half-made
# worktree that the next call reports rather than adopts.
CREATE_TIMEOUT = 600.0
GIT_TIMEOUT = 30.0
START_SOURCES = ("startup", "resume")


def _real(path):
    if not isinstance(path, str) or not path:
        return None
    try:
        return os.path.realpath(path)
    except (OSError, ValueError):
        return None


def inside(path, worktree) -> bool:
    path, worktree = _real(path), _real(worktree)
    if not path or not worktree:
        return False
    try:
        return os.path.commonpath([path, worktree]) == worktree
    except ValueError:
        return False


def main_checkout(repo_path):
    if not isinstance(repo_path, str) or not os.path.isdir(repo_path):
        return None
    return _real(_bootstrap.resolve_host_repo_root(cwd=repo_path))


def target_path(main, run) -> str:
    return os.path.join(main, WORKTREES_DIR, NAME_PREFIX + run)


def record_value(path, repo, now_iso=None) -> dict:
    return {"path": path, "repo": repo, "created_at": now_iso or run_record_core.now_iso()}


def _git(main, *argv, timeout=GIT_TIMEOUT):
    return programme_exec.bounded(["git", "-C", main, *argv], timeout)


def _ok(result) -> bool:
    return result["ran"] and result["code"] == 0


def _listing(main):
    result = _git(main, "worktree", "list", "--porcelain")
    if not _ok(result):
        return None
    entries, current = {}, None
    for line in result["stdout"].splitlines():
        if line.startswith("worktree "):
            current = _real(line[len("worktree "):].strip())
            entries[current] = {}
        elif current and line.startswith("HEAD "):
            entries[current]["head"] = line[len("HEAD "):].strip()
    return entries


def registered(main):
    listed = _listing(main)
    return None if listed is None else list(listed)


def _ensure_excluded(main, target) -> None:
    rel = os.path.relpath(target, main) + "/"
    if _git(main, "check-ignore", "-q", rel)["code"] == 0:
        return
    found = _git(main, "rev-parse", "--git-path", "info/exclude")
    if not _ok(found) or not found["stdout"].strip():
        return
    exclude = os.path.join(main, found["stdout"].strip())
    try:
        with open(exclude) as fh:
            text = fh.read()
    except FileNotFoundError:
        text = ""
    except OSError:
        return
    if WORKTREES_DIR + "/" in text.splitlines():
        return
    os.makedirs(os.path.dirname(exclude), exist_ok=True)
    with open(exclude, "a") as fh:
        fh.write(("" if not text or text.endswith("\n") else "\n") + WORKTREES_DIR + "/\n")


def _outcome(status, path, record=None, error=None) -> dict:
    return {"status": status, "path": path, "record": record, "error": error}


def create(repo_path, run, now_iso=None) -> dict:
    main = main_checkout(repo_path)
    if not main:
        return _outcome("refused", None, error=f"{repo_path} is not inside a git repo")
    target = target_path(main, run)
    listed = registered(main)
    if listed is None:
        return _outcome("failed", target, error=f"could not list the worktrees of {main}")
    if _real(target) in listed:
        if not _ok(_git(target, "status", "--porcelain")):
            return _outcome("unusable", target, error=(
                f"{target} is a registered worktree of {main} but git status fails in it; "
                "Shawn should remove it before the programme can use it"))
        _ensure_excluded(main, target)
        return _outcome("adopted", target, record_value(target, main, now_iso))
    if os.path.lexists(target):
        return _outcome("refused", target, error=(
            f"{target} exists and is not a worktree of {main}; nothing was created"))
    _ensure_excluded(main, target)
    result = _git(main, "worktree", "add", "--detach", target, timeout=CREATE_TIMEOUT)
    if not _ok(result):
        return _outcome("failed", target, error=(
            f"{programme_exec.failure(result, 'git worktree add')} (path {target})"))
    return _outcome("created", target, record_value(target, main, now_iso))


def _seen(status, path, detail, head=None) -> dict:
    return {"status": status, "path": path, "detail": detail, "head": head}


def observe(value) -> dict:
    path, main = _real(value.get("path")), _real(value.get("repo"))
    listed = _listing(main) if main else None
    if listed is None:
        if path and not os.path.lexists(path):
            return _seen("gone", path, f"{path} no longer exists and its repo {main} cannot be listed")
        return _seen("failed", path, f"could not list the worktrees of {main}")
    if path not in listed:
        return _seen("gone", path, f"git no longer lists {path} as a worktree of {main}")
    if not os.path.isdir(path):
        return _seen("gone", path, f"{path} was deleted; git keeps a stale entry until it prunes it")
    return _seen("present", path, f"{path} is still a worktree of {main}", listed[path].get("head"))


def _cwd():
    try:
        return os.getcwd()
    except OSError:
        return None


def release(value) -> dict:
    seen = observe(value)
    if seen["status"] != "present":
        return seen
    path, main, head = seen["path"], _real(value.get("repo")), seen["head"]
    later = "then run release-resources again, or record dispose-action --resource worktree"
    if inside(_cwd(), path):
        return _seen("refused", path, (
            f"this command ran inside {path}; cd {shlex.quote(main)} and run release-resources again"))
    status = _git(path, "status", "--porcelain", "--untracked-files=all")
    if not _ok(status):
        return _seen("failed", path, f"{programme_exec.failure(status, 'git status')}; {later}")
    if status["stdout"].strip():
        return _seen("refused", path, (
            f"{path} has uncommitted or untracked changes; commit or clean them, {later}"))
    if not head:
        return _seen("failed", path, f"git lists no HEAD for {path}; {later}")
    lost = _git(main, "rev-list", "-n", "1", head, "--not", "--branches", "--remotes")
    if not _ok(lost):
        return _seen("failed", path, f"{programme_exec.failure(lost, 'git rev-list')}; {later}")
    if lost["stdout"].strip():
        return _seen("refused", path, (
            f"{path} holds commits that no branch or remote reaches; create a branch at its HEAD "
            f"(git -C {shlex.quote(path)} branch <name>), {later}"))
    removed = _git(main, "worktree", "remove", path)
    if not _ok(removed):
        return _seen("failed", path, f"{programme_exec.failure(removed, 'git worktree remove')}; {later}")
    return _seen("removed", path, f"removed {path}; branches made in it are kept")


def _block(record_or_programme):
    if not isinstance(record_or_programme, dict):
        return {}
    inner = record_or_programme.get("programme")
    return inner if isinstance(inner, dict) else record_or_programme


def recorded(record_or_programme):
    value = _block(record_or_programme).get("pm_worktree")
    if isinstance(value, dict) and isinstance(value.get("path"), str) and value["path"]:
        return value
    return None


def remit_repo(record_or_programme):
    repos = ((_block(record_or_programme).get("remit") or {}).get("repos")) or []
    for repo in repos:
        path = repo.get("path") if isinstance(repo, dict) else None
        if isinstance(path, str) and path:
            return path
    return None


def start_dir(session_id):
    rows = [r for r in session_registry.session_rows(session_id)
            if r.get("source") in START_SOURCES and isinstance(r.get("cwd"), str)]
    if not rows:
        return None
    return max(rows, key=lambda r: str(r.get("at") or ""))["cwd"]


def cd_can_stick(session_id, worktree) -> bool:
    start = start_dir(session_id)
    return bool(start) and inside(worktree, start)


def move_line(record_or_programme, session_id, cwd) -> str:
    worktree = recorded(record_or_programme)
    if not worktree or inside(cwd, worktree["path"]):
        return ""
    path = worktree["path"]
    if cd_can_stick(session_id, path):
        return f"Run `cd {shlex.quote(path)}` so this PM works from the programme worktree."
    return (f"Ask Shawn to type `/cd {path}`: this PM works from the programme worktree, "
            "and a cd run here would not last.")


def restore_line(record_or_programme, session_id, cwd=None) -> str:
    if not session_id:
        return ""
    try:
        line = move_line(record_or_programme, session_id, cwd if cwd is not None else _cwd())
    except Exception:
        return ""  # The move line is advice: a registry it cannot read must not cost the PM its rules.
    return line + "\n" if line else ""


def _in_remit(repo, programme) -> bool:
    paths = [r.get("path") for r in ((programme.get("remit") or {}).get("repos") or [])
             if isinstance(r, dict)]
    if any(_real(p) == _real(repo) or inside(p, repo) for p in paths):
        return True
    return any(main_checkout(p) == _real(repo) for p in paths)


def status_line(record_or_programme) -> str:
    programme = _block(record_or_programme)
    worktree = recorded(programme)
    if not worktree:
        return ""
    line = f"Programme worktree: {worktree['path']}"
    repo = worktree.get("repo")
    if repo and not _in_remit(repo, programme):
        line += f" (its repo {repo} is no longer in the remit)"
    return line + "."
