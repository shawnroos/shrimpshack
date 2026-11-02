#!/usr/bin/env python3
"""Checks a ritual may carry: a short fixed list, each one plugin code that reads a repo and never runs it.

A ritual stores only a check *name*. The name maps to a function in this module, so adding a check is
a reviewed code change and never a command string in a ritual. A check reads the repo through the
hardened git runner with fixed argument lists, builds no code from names it finds there, and a result
is ``pass`` only when it can show what it covered: anything that stops it early is ``error``.
"""

from __future__ import annotations

import json
import os
import re
import sys
import time

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

programme_gitio = load_lib_module("programme_gitio")

NAMES = ("versions-bumped",)
RESULTS = ("pass", "fail", "error")
REASONS = ("ok", "shipped_changed", "marketplace_mismatch", "not_a_repo", "ref_missing", "no_plugins",
           "marketplace_unreadable", "bad_plugin_name", "history_window", "git_missing", "git_failed",
           "timeout", "unknown_check", "repo_not_in_remit", "internal")
DEFAULT_BASE = "origin/main"
BUDGET_SECONDS = 30.0
CALL_SECONDS = 10.0
MAX_BLOB_BYTES = 256 * 1024
BUMP_WINDOW = 500

_PLUGIN_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
_GIT_REASONS = {"git_missing": "git_missing", "timed_out": "timeout"}


class _Stop(Exception):
    def __init__(self, reason):
        super().__init__(reason)
        self.reason = reason


def _result(result, reason, **fields) -> dict:
    return dict({"result": result, "reason": reason}, **fields)


class _Repo:
    """One repo read under a shared time budget; every git failure becomes a named stop."""

    def __init__(self, git, path, budget):
        self.git, self.path, self.deadline = git, path, time.monotonic() + budget

    def run(self, args, *, reason="git_failed") -> bytes:
        left = self.deadline - time.monotonic()
        if left <= 0:
            raise _Stop("timeout")
        try:
            return self.git.run(self.path, args, timeout=min(CALL_SECONDS, left))
        except programme_gitio.GitError as exc:
            raise _Stop(_GIT_REASONS.get(exc.code, reason)) from None

    def text(self, args, **kw) -> str:
        return self.run(args, **kw).decode("utf-8", "replace").strip()

    def blob(self, commit, rel, *, reason):
        spec = f"{commit}:{rel}"
        try:
            size = int(self.text(["cat-file", "-s", spec], reason=reason))
        except ValueError:
            raise _Stop(reason) from None
        if size > MAX_BLOB_BYTES:
            raise _Stop(reason)
        return self.run(["cat-file", "blob", spec], reason=reason)


def _version(repo, commit, rel):
    try:
        data = json.loads(repo.blob(commit, rel, reason="git_failed"))
    except _Stop as stop:
        if stop.reason in ("timeout", "git_missing"):
            raise
        return None
    except ValueError:
        return None
    version = data.get("version") if isinstance(data, dict) else None
    return version if isinstance(version, str) else None


def _bump_commit(repo, sha, rel):
    """The newest commit that changed the plugin's version, or the one that added it; None when the window ends first."""
    commits = repo.text(["log", f"-n{BUMP_WINDOW}", "--format=%H", sha, "--", rel]).split()
    versions = {commit: _version(repo, commit, rel) for commit in commits}
    for index, commit in enumerate(commits):
        older = commits[index + 1] if index + 1 < len(commits) else None
        if older is None:
            return commit if len(commits) < BUMP_WINDOW else None
        if versions[commit] != versions[older]:
            return commit
    return None


def _fetch_age(repo):
    try:
        common = repo.text(["rev-parse", "--git-common-dir"])
        folder = common if os.path.isabs(common) else os.path.join(repo.path, common)
        return int(max(0, time.time() - os.stat(os.path.join(folder, "FETCH_HEAD")).st_mtime))
    except (OSError, _Stop):
        return None


def _plugin_names(repo, sha) -> list:
    names = []
    for line in repo.run(["ls-tree", "-z", sha, "plugins/"], reason="no_plugins").split(b"\0"):
        if not line:
            continue
        meta, _, path = line.decode("utf-8", "replace").partition("\t")
        if meta.split()[1:2] != ["tree"]:
            continue
        name = path[len("plugins/"):]
        if not _PLUGIN_RE.match(name):
            raise _Stop("bad_plugin_name")
        names.append(name)
    if not names:
        raise _Stop("no_plugins")
    return names


def _versions_bumped(repo, base) -> dict:
    ref = base or DEFAULT_BASE
    top = repo.text(["rev-parse", "--show-toplevel"], reason="not_a_repo")
    if os.path.realpath(top) != repo.path:
        raise _Stop("not_a_repo")
    sha = repo.text(["rev-parse", "--verify", "--end-of-options", ref + "^{commit}"], reason="ref_missing")
    age = _fetch_age(repo)
    names = _plugin_names(repo, sha)
    try:
        market = json.loads(repo.blob(sha, ".claude-plugin/marketplace.json", reason="marketplace_unreadable"))
        listed = {p["name"]: p.get("version") for p in market["plugins"] if isinstance(p, dict) and "name" in p}
    except (ValueError, KeyError, TypeError):
        raise _Stop("marketplace_unreadable") from None
    checked, failed = 0, []
    for name in names:
        rel = f"plugins/{name}/.claude-plugin/plugin.json"
        now = _version(repo, sha, rel)
        if now is None:
            continue
        checked += 1
        bump = _bump_commit(repo, sha, rel)
        if bump is None:
            raise _Stop("history_window")
        moved = repo.run(["diff", "--name-only", "-z", bump, sha, "--", f"plugins/{name}"]).split(b"\0")
        shipped = [p for p in moved if p and p.decode("utf-8", "replace") != rel]
        if shipped:
            failed.append({"plugin": name, "reason": "shipped_changed", "files": len(shipped)})
        elif name in listed and listed[name] != now:
            failed.append({"plugin": name, "reason": "marketplace_mismatch", "files": 0})
    if checked == 0:
        raise _Stop("no_plugins")
    facts = {"checked": checked, "failed": failed, "ref": ref, "ref_sha": sha, "ref_age_seconds": age}
    if failed:
        return _result("fail", failed[0]["reason"], **facts)
    return _result("pass", "ok", **facts)


_CHECKS = {"versions-bumped": _versions_bumped}


def run_check(name, repo_path, base=None, *, budget_seconds=BUDGET_SECONDS) -> dict:
    """Never raises. ``pass`` only with proof of what was read; every other outcome that is not a finding is ``error``."""
    fn = _CHECKS.get(name)
    if fn is None:
        return _result("error", "unknown_check")
    if not isinstance(repo_path, str) or not os.path.isabs(repo_path) or not os.path.isdir(repo_path):
        return _result("error", "not_a_repo")
    path = os.path.realpath(repo_path)
    try:
        with programme_gitio.Git(os.path.dirname(path)) as git:
            return fn(_Repo(git, path, budget_seconds), base)
    except _Stop as stop:
        return _result("error", stop.reason)
    except programme_gitio.GitError as exc:
        return _result("error", _GIT_REASONS.get(exc.code, "git_failed"))
    except Exception:  # noqa: BLE001 — a check must never raise into a sweep; the reason is fixed text, not the message
        return _result("error", "internal")
