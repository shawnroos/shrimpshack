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

programme_home = load_lib_module("programme_home")
programme_plans = load_lib_module("programme_plans")

REPO_CAP = 20

# spinoff.sh prints this line itself, before the worker exists, so the path is the PM's launch fact.
_WORKTREE_LINE = re.compile(r"^▸ worktree:[ \t]+(\S.*?)[ \t]*$", re.MULTILINE)
_VIA_KIND = "pm-created"
_GITHUB_RE = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")


def worktree_of(output) -> str | None:
    found = _WORKTREE_LINE.search(output or "")
    return found.group(1) if found else None


def same_path(a, b) -> bool:
    return os.path.realpath(a) == os.path.realpath(b)


def is_pm_created(repo) -> bool:
    return isinstance(repo, dict) and (repo.get("via") or {}).get("kind") == _VIA_KIND


def authority_repos(programme) -> list:
    """Repos that may shape authority, rulings and carry-over. Any entry with ``via`` is skipped (default-deny):
    a worker can edit files in its own worktree, so a PM-created entry only widens the sweep and PR checks."""
    return [r for r in (programme.get("remit") or {}).get("repos") or [] if isinstance(r, dict) and not r.get("via")]


def entry_for(repos, path):
    return next((r for r in repos or [] if isinstance(r, dict) and isinstance(r.get("path"), str)
                 and same_path(r["path"], path)), None)


def stale_paths(repos) -> set:
    return {os.path.normpath(r["path"]) for r in repos or []
            if isinstance(r, dict) and isinstance(r.get("path"), str) and not os.path.isdir(r["path"])}


def dropped_stale(gone, after_repos) -> list:
    kept = {os.path.normpath(r["path"]) for r in after_repos}
    return sorted(p for p in gone if p not in kept)


def parse_repo(raw, stored, fail):
    """One repo as the remit stores it, or None for a stored path whose folder is gone. A new path that is not a
    folder is refused through ``fail``, and ``via`` is only ever carried over from the stored entry."""
    if not isinstance(raw, dict) or not isinstance(raw.get("path"), str):
        raise fail("each repo is an object with a path")
    path = raw["path"]
    if not os.path.isabs(path) or ".." in path.split(os.sep):
        raise fail(f"repo path must be an absolute directory, got {path!r}")
    known = entry_for(stored, path)
    if not os.path.isdir(path):
        if known is not None:
            return None
        raise fail(f"repo path must be an absolute directory, got {path!r}")
    github = raw.get("github")
    if github is not None and (not isinstance(github, str) or not _GITHUB_RE.fullmatch(github)):
        raise fail(f"repo github must be owner/name, got {github!r}")
    entry = {"path": os.path.normpath(path), "github": github}
    if known is not None and known.get("via"):
        entry["via"] = known["via"]
    return entry


def unnamed_removals(changes, gone) -> list:
    """The changes that still need typed words: a repo whose folder is gone is dropped without them."""
    return [(part, entry) for part, how, entry in changes
            if not (part == "repos" and how == "removed" and os.path.normpath(entry["path"]) in gone)]


def add_for_worker(programme, *, worktree, folder, item, session, at) -> dict:
    """Adds the repo the PM launched to the remit. ``repo`` is the confirmed root, ``added`` the path written."""
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
    repos = programme["remit"].setdefault("repos", [])
    if not repos:
        out["reason"] = "the remit lists no repos, which means no limit; an entry would narrow it"
    elif entry_for(repos, launched):
        out["reason"] = "the repo is already in the remit"
    elif len(repos) >= REPO_CAP:
        out["reason"] = f"the remit already lists {len(repos)} repos, the most it holds"
    else:
        # github stays null: the worktree's git config is writable by the worker, and PR checks key on the slug.
        repos.append({"path": launched, "github": None,
                      "via": {"kind": _VIA_KIND, "item": item, "session": session, "at": at}})
        out["added"] = launched
    return out


def _recorded_repos(item) -> list:
    return [s["repo"] for s in item.get("starts") or [] if s.get("ok") and s.get("repo")]


def _works_in(programme, skip, path) -> bool:
    finished = programme_home.FINISHED_ITEM_STATES
    for key, item in (programme.get("items") or {}).items():
        if key == skip or item.get("state") in finished:
            continue
        if any(same_path(r, path) for r in _recorded_repos(item) + [item.get("repo")] if r):
            return True
    return False


def drop_for_item(programme, item_key) -> dict:
    """Removes the PM-created entry for this item's repo. The folder is already gone at a retire, so the entry is
    found by the item and the repo it recorded at start, never by resolving the pane's folder."""
    repos = programme["remit"].setdefault("repos", [])
    mine = _recorded_repos((programme.get("items") or {}).get(item_key) or {})
    out = {"dropped": None, "reason": f"no PM-created entry for {item_key}"}
    for entry in [r for r in repos if is_pm_created(r)
                  and (r["via"].get("item") == item_key or any(same_path(m, r["path"]) for m in mine))]:
        if len(repos) == 1:
            out["reason"] = f"{entry['path']} is the last entry; an empty list would mean no limit"
        elif _works_in(programme, item_key, entry["path"]):
            out["reason"] = f"another open item still works in {entry['path']}"
        else:
            repos.remove(entry)
            out.update(dropped=entry["path"], reason=None)
    return out
