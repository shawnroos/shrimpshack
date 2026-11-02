#!/usr/bin/env python3
"""Repos the PM adds to the remit for the workers it starts, and drops when it retires them.

They live in ``remit["worker_repos"]``, apart from the typed ``remit["repos"]``. Only the sweep scope reads them
(``sweep_scope``); every other reader of the remit sees the typed list alone, so a worker-editable worktree can
never shape authority, rulings or PR checks. Only ``start-worker`` writes one; ``set-remit`` never touches the list.
"""

from __future__ import annotations

import os
import re
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

programme_home = load_lib_module("programme_home")
programme_plans = load_lib_module("programme_plans")

REPO_CAP = 20

# spinoff.sh prints this line itself, before the worker exists, so the path is the PM's launch fact.
_WORKTREE_LINE = re.compile(r"^▸ worktree:[ \t]+(\S.*?)[ \t]*$", re.MULTILINE)
_GITHUB_RE = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")


def worktree_of(output) -> str | None:
    found = _WORKTREE_LINE.search(output or "")
    return found.group(1) if found else None


def same_path(a, b) -> bool:
    return os.path.realpath(a) == os.path.realpath(b)


def entry_for(repos, path):
    return next((r for r in repos or [] if isinstance(r, dict) and isinstance(r.get("path"), str)
                 and same_path(r["path"], path)), None)


def sweep_scope(remit) -> list:
    """The repos a pane may sit in. An empty typed list means no limit, which worker repos never narrow."""
    typed = [r for r in remit.get("repos") or [] if isinstance(r, dict) and r.get("path")]
    return typed + [r for r in remit.get("worker_repos") or [] if typed and r.get("path")]


def stale_paths(repos) -> set:
    return {os.path.normpath(r["path"]) for r in repos or []
            if isinstance(r, dict) and isinstance(r.get("path"), str) and not os.path.isdir(r["path"])}


def dropped_stale(gone, after_repos) -> list:
    kept = {os.path.normpath(r["path"]) for r in after_repos}
    return sorted(p for p in gone if p not in kept)


def parse_repo(raw, stored, fail):
    """One typed repo as the remit stores it, or None for a stored path whose folder is gone. A new path that is
    not a folder is refused through ``fail``."""
    if not isinstance(raw, dict) or not isinstance(raw.get("path"), str):
        raise fail("each repo is an object with a path")
    path = raw["path"]
    if not os.path.isabs(path) or ".." in path.split(os.sep):
        raise fail(f"repo path must be an absolute directory, got {path!r}")
    if not os.path.isdir(path):
        if entry_for(stored, path) is not None:
            return None
        raise fail(f"repo path must be an absolute directory, got {path!r}")
    github = raw.get("github")
    if github is not None and (not isinstance(github, str) or not _GITHUB_RE.fullmatch(github)):
        raise fail(f"repo github must be owner/name, got {github!r}")
    return {"path": os.path.normpath(path), "github": github}


def unnamed_removals(changes, gone) -> list:
    """The changes that still need typed words: a repo whose folder is gone is dropped without them."""
    return [(part, entry) for part, how, entry in changes
            if not (part == "repos" and how == "removed" and os.path.normpath(entry["path"]) in gone)]


def add_for_worker(programme, *, worktree, folder, item, session, at) -> dict:
    """Adds the repo the PM launched. ``repo`` is the confirmed root, ``added`` the path written."""
    out = {"added": None, "repo": None, "reason": None}
    if not worktree:
        out["reason"] = "spinoff did not report its worktree, so the repo cannot be tied to what the PM launched"
        return out
    launched, seen = programme_plans.repo_root(worktree, {}), programme_plans.repo_root(folder, {})
    if launched is None or seen is None:
        out["reason"] = f"the worktree {worktree!r} or the pane folder {folder!r} is not a git folder on disk"
        return out
    if not same_path(launched, seen):
        out["reason"] = f"the pane folder {folder!r} does not match the worktree {worktree!r} the PM launched"
        return out
    out["repo"] = launched
    remit = programme["remit"]
    workers = remit.setdefault("worker_repos", [])
    if not remit.get("repos"):
        out["reason"] = "the remit lists no repos, which means no limit; every repo is already in scope"
    elif entry_for(remit["repos"], launched) or entry_for(workers, launched):
        out["reason"] = "the repo is already in the remit"
    elif len(workers) >= REPO_CAP:
        out["reason"] = f"the remit already lists {len(workers)} worker repos, the most it holds"
    else:
        workers.append({"path": launched, "item": item, "session": session, "at": at})
        out["added"] = launched
    return out


def _recorded_repos(item) -> list:
    return [s["repo"] for s in item.get("starts") or [] if s.get("ok") and s.get("repo")]


def _works_in(programme, skip, path) -> bool:
    finished = programme_home.FINISHED_ITEM_STATES
    for key, item in (programme.get("items") or {}).items():
        if key == skip or item.get("state") in finished:
            continue
        if any(same_path(r, path) for r in _recorded_repos(item)):
            return True
    return False


def drop_for_item(programme, item_key) -> dict:
    """Removes the worker repo for this item. The folder is already gone at a retire, so the entry is found by the
    item and the repo it recorded at start, never by resolving the pane's folder."""
    workers = programme["remit"].setdefault("worker_repos", [])
    mine = _recorded_repos((programme.get("items") or {}).get(item_key) or {})
    dropped, kept = [], []
    for entry in [w for w in workers if w.get("item") == item_key or any(same_path(m, w["path"]) for m in mine)]:
        if _works_in(programme, item_key, entry["path"]):
            kept.append(entry["path"])
        else:
            workers.remove(entry)
            dropped.append(entry["path"])
    reason = None if dropped else (f"another open item still works in {kept[0]}" if kept
                                   else f"no worker repo for {item_key}")
    return {"dropped": dropped or None, "reason": reason}
