#!/usr/bin/env python3
"""Merge a proposal's allow rules into its settings.local.json and keep everything else in that file."""

from __future__ import annotations

import hashlib
import json
import os
import stat
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

programme_gitio = load_lib_module("programme_gitio")
programme_home = load_lib_module("programme_home")
rules = load_lib_module("programme_permission_rules")

SETTINGS_CAP = 1024 * 1024
_NEW_FILE_MODE = 0o600


class WriteRefused(Exception):
    pass


def _sha(data):
    return None if data is None else "sha256:" + hashlib.sha256(data).hexdigest()


def _read(path):
    try:
        with open(path, "rb") as fh:
            return fh.read(SETTINGS_CAP + 1)
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise WriteRefused(f"{path} cannot be read ({type(exc).__name__})") from None


def _parsed(path, data) -> dict:
    if data is None:
        return {}
    if len(data) > SETTINGS_CAP:
        raise WriteRefused(f"{path} is larger than 1 MiB, so Auto left it unchanged")
    try:
        doc = json.loads(data)
    except ValueError:
        raise WriteRefused(f"{path} is not valid JSON, so Auto left it unchanged") from None
    if not isinstance(doc, dict):
        raise WriteRefused(f"{path} is not a JSON object, so Auto left it unchanged")
    return doc


def _allow_list(path, doc) -> list:
    perms = doc.setdefault("permissions", {})
    if not isinstance(perms, dict):
        raise WriteRefused(f"{path} has a permissions value that is not an object, so Auto left it unchanged")
    allow = perms.setdefault("allow", [])
    if not isinstance(allow, list):
        raise WriteRefused(f"{path} has a permissions.allow value that is not a list, so Auto left it unchanged")
    return allow


def _replace(path, doc, mode) -> None:
    def write(fh):
        json.dump(doc, fh, indent=2, ensure_ascii=False)
        fh.write("\n")

    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        programme_home.atomic_write(path, write, ".settings.", encoding="utf-8")
        # atomic_write always leaves 0600.
        if mode != _NEW_FILE_MODE:
            os.chmod(path, mode)
    except OSError as exc:
        raise WriteRefused(f"{path} cannot be written ({type(exc).__name__})") from None


def tracked_note(main, path) -> str | None:
    """Refuses a file git tracks: a local allow rule would become a diff the whole team could commit.

    The return value is a note when git cannot answer. That does not block the write, since most such failures are a
    broken checkout and Shawn has already picked allow.
    """
    name = rules.DESTINATION_FILE
    try:
        with programme_gitio.Git(os.path.dirname(main)) as git:
            code, _ = git.call(main, ["ls-files", "--error-unmatch", "--", name], ok=(0, 1, 128))
    except programme_gitio.GitError as exc:
        return f"git could not say whether {path} is tracked: {exc}"
    if code == 0:
        raise WriteRefused(f"{path} is tracked by git, so a rule written there would show as a change to commit; "
                           "untrack it, or Shawn adds the rule by hand")
    return None if code == 1 else f"git could not say whether {path} is tracked"


def unchanged(path) -> dict:
    digest = _sha(_read(os.path.realpath(path)))
    return {"rules_written": [], "file": path, "before_hash": digest, "after_hash": digest}


def merge(path, wanted) -> dict:
    # The replace would swap a symlink for a plain file, so it works on what the link points to.
    real = os.path.realpath(path)
    data = _read(real)
    doc = _parsed(path, data)
    allow = _allow_list(path, doc)
    new = [rule for rule in wanted if rule not in allow]
    if not new:
        return unchanged(path)
    allow.extend(new)
    _replace(real, doc, _NEW_FILE_MODE if data is None else stat.S_IMODE(os.stat(real).st_mode))
    return {"rules_written": new, "file": path, "before_hash": _sha(data), "after_hash": _sha(_read(real))}
