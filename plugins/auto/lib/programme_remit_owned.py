#!/usr/bin/env python3
"""Remit repo entries the PM creates for the workers it starts, and drops when it retires them.

An entry carries ``via`` (kind, item, session, time). Only ``start-worker`` writes one, and only when the repo is
what the PM launched. ``set-remit`` stdin never sets or changes it.
"""

from __future__ import annotations

import os
import re
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

programme_exec = load_lib_module("programme_exec")
programme_home = load_lib_module("programme_home")

REPO_CAP = 20
VIA_KIND = "pm-created"
GIT_TIMEOUT = 5

# spinoff.sh prints this line itself, before the worker exists, so the path is the PM's launch fact.
_WORKTREE_LINE = re.compile(r"^▸ worktree:[ \t]+(\S.*?)[ \t]*$", re.MULTILINE)
_GITHUB_ORIGIN = re.compile(
    r"^(?:https://(?:[^@/]+@)?github\.com/|git@github\.com:|ssh://git@github\.com/)"
    r"([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(?:\.git)?/?$")


def worktree_of(output) -> str | None:
    found = _WORKTREE_LINE.search(output or "")
    return found.group(1) if found else None


def same_path(a, b) -> bool:
    return os.path.realpath(a) == os.path.realpath(b)


def is_pm_created(repo) -> bool:
    return isinstance(repo, dict) and (repo.get("via") or {}).get("kind") == VIA_KIND


def authority_repos(programme) -> list:
    """Repos that may shape authority levels, rulings and carry-over. A PM-created entry only widens the sweep."""
    return [r for r in (programme.get("remit") or {}).get("repos") or [] if isinstance(r, dict) and not r.get("via")]


def _git(root, *args) -> str:
    result = programme_exec.bounded(["git", "-C", root, *args], GIT_TIMEOUT)
    return result["stdout"].strip() if result["ran"] and result["code"] == 0 else ""


def _root(folder) -> str | None:
    if not folder or not os.path.isdir(folder):
        return None
    top = _git(folder, "rev-parse", "--show-toplevel")
    return top if top and os.path.isdir(top) else None


def _github(root) -> str | None:
    found = _GITHUB_ORIGIN.match(_git(root, "remote", "get-url", "origin"))
    return f"{found.group(1)}/{found.group(2)}" if found else None


def add_for_worker(programme, *, worktree, folder, item, session, at) -> dict:
    """Adds the repo the PM launched to the remit. ``repo`` is the confirmed root, ``added`` the path written."""
    out = {"added": None, "repo": None, "reason": None}
    if not worktree:
        out["reason"] = "spinoff did not report its worktree, so the repo cannot be tied to what the PM launched"
        return out
    launched, seen = _root(worktree), _root(folder)
    if launched is None or seen is None:
        out["reason"] = f"the worktree {worktree!r} or the pane folder {folder!r} is not a git folder on disk"
        return out
    if not same_path(launched, seen):
        out["reason"] = f"the pane folder {folder!r} does not match the worktree {worktree!r} the PM launched"
        return out
    out["repo"] = launched
    repos = programme["remit"].setdefault("repos", [])
    if not repos:
        out["reason"] = "the remit lists no repos, which means no limit; an entry would narrow it"
    elif any(same_path(r["path"], launched) for r in repos if isinstance(r, dict) and r.get("path")):
        out["reason"] = "the repo is already in the remit"
    elif len(repos) >= REPO_CAP:
        out["reason"] = f"the remit already lists {len(repos)} repos, the most it holds"
    else:
        repos.append({"path": launched, "github": _github(launched),
                      "via": {"kind": VIA_KIND, "item": item, "session": session, "at": at}})
        out["added"] = launched
    return out


def _works_in(programme, skip, path) -> bool:
    finished = programme_home.FINISHED_ITEM_STATES
    for key, item in (programme.get("items") or {}).items():
        if key == skip or item.get("state") in finished:
            continue
        if any(s.get("ok") and s.get("repo") and same_path(s["repo"], path) for s in item.get("starts") or []):
            return True
    return False


def drop_for_item(programme, item_key) -> dict:
    """Removes the entry the PM created for this item. The folder is already gone at a retire, so it matches by item."""
    repos = programme["remit"].setdefault("repos", [])
    out = {"dropped": None, "reason": f"no PM-created entry for {item_key}"}
    for entry in [r for r in repos if is_pm_created(r) and r["via"].get("item") == item_key]:
        if len(repos) == 1:
            out["reason"] = f"{entry['path']} is the last entry; an empty list would mean no limit"
        elif _works_in(programme, item_key, entry["path"]):
            out["reason"] = f"another open item still works in {entry['path']}"
        else:
            repos.remove(entry)
            out.update(dropped=entry["path"], reason=None)
    return out
