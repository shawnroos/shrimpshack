#!/usr/bin/env python3
"""The plans source: plan docs in the repos the remit's panes work in. Read-only."""

from __future__ import annotations

import datetime
import os
import re
import sys
import time

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

programme_exec = load_lib_module("programme_exec")
programme_sanitize = load_lib_module("programme_sanitize")
programme_tracker = load_lib_module("programme_tracker")

GIT_TIMEOUT = 2.0
RECENT_DAYS = 7
FILE_CAP = 200
RECENT_CAP = 20
REPO_CAP = 16
BYTES_CAP = 65536
CONFIG_BYTES_CAP = 8192
ISSUE_CAP = 5
TITLE_CAP = 200
CONFIG_REL = os.path.join(".compound-engineering", "config.yaml")
_DOCS_ROOT = re.compile(r"^docs_root:\s*(.+?)\s*$")
_TITLE_LINE = re.compile(r"^title:\s*(.+?)\s*$")


def repo_root(cwd, cache) -> str | None:
    if not cwd or not os.path.isdir(cwd):
        return None
    if cwd not in cache:
        result = programme_exec.bounded(["git", "-C", cwd, "rev-parse", "--show-toplevel"], GIT_TIMEOUT)
        top = result["stdout"].strip() if result["ran"] and result["code"] == 0 else ""
        cache[cwd] = top if top and os.path.isdir(top) else None
    return cache[cwd]


def _read_text(path, cap) -> str:
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read(cap)
    except OSError:
        return ""


def plans_dir(root) -> str:
    for line in _read_text(os.path.join(root, CONFIG_REL), CONFIG_BYTES_CAP).splitlines():
        match = _DOCS_ROOT.match(line)
        if not match:
            continue
        docs = os.path.realpath(os.path.join(root, match.group(1).strip("'\"")))
        real_root = os.path.realpath(root)
        if docs == real_root or docs.startswith(real_root + os.sep):
            return os.path.join(docs, "plans")
    return os.path.join(root, "docs", "plans")


def plan_files(root) -> list:
    folder = plans_dir(root)
    try:
        names = sorted(n for n in os.listdir(folder) if n.endswith(".md"))[:FILE_CAP]
    except OSError:
        return []
    out = []
    for name in names:
        path = os.path.join(folder, name)
        try:
            mtime = os.stat(path).st_mtime
        except OSError:
            continue
        if os.path.isfile(path):
            out.append((path, mtime))
    return out


def _title(text) -> str | None:
    lines = text.splitlines()
    if lines and lines[0].strip() == "---":
        for line in lines[1:]:
            if line.strip() == "---":
                break
            match = _TITLE_LINE.match(line)
            if match:
                return programme_sanitize.clean(match.group(1).strip("'\""), TITLE_CAP) or None
    for line in lines:
        if line.startswith("# "):
            return programme_sanitize.clean(line[2:], TITLE_CAP) or None
    return None


def _iso(stamp) -> str:
    return datetime.datetime.fromtimestamp(stamp, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def read_repo(root, now=None) -> list:
    cutoff = (now if now is not None else time.time()) - RECENT_DAYS * 86400
    recent = sorted((f for f in plan_files(root) if f[1] >= cutoff), key=lambda f: -f[1])[:RECENT_CAP]
    out = []
    for path, mtime in recent:
        text = _read_text(path, BYTES_CAP)
        rel = os.path.relpath(os.path.realpath(path), os.path.realpath(root))
        out.append({"path": programme_sanitize.clean(rel, 400),
                    "title": _title(text), "mtime": _iso(mtime),
                    "issues": programme_tracker.issue_ids(text)[:ISSUE_CAP]})
    return out


def read(cwds, now=None) -> dict:
    cache, repos = {}, {}
    for cwd in cwds:
        root = repo_root(cwd, cache)
        if root and root not in repos and len(repos) < REPO_CAP:
            repos[root] = read_repo(root, now)
    return {"state": "available", "unavailable": False, "reason": None,
            "roots": {cwd: cache.get(cwd) for cwd in cwds},
            "repos": [{"repo": root, "plans": plans} for root, plans in sorted(repos.items())]}
