#!/usr/bin/env python3
"""The one journal row for a programme whose check settings cannot be read, or hold a bad shape."""

from __future__ import annotations

import json
import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

programme_home = load_lib_module("programme_home")
run_record_core = load_lib_module("run_record_core")
programme_sanitize = load_lib_module("programme_sanitize")

UNREADABLE = "checks_unreadable"
JOURNAL_LOCK_WAIT = 0.5
DETAIL_CAP = 300


def _marker(run) -> str:
    return os.path.join(programme_home.home_path(run), ".checks-unreadable.json")


def _create_new(path, text="") -> bool:
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except OSError:
        return False
    try:
        os.write(fd, text.encode("utf-8"))
    finally:
        os.close(fd)
    return True


def mark_episode(run, outcome, detail) -> None:
    payload = {"since": run_record_core.now_iso(), "outcome": outcome,
               "detail": programme_sanitize.clean(detail or "", DETAIL_CAP)}
    _create_new(_marker(run), json.dumps(payload))


def journal_episode(run) -> None:
    # The store a hold blocks is the store the journal writes to, so a hold leaves only the marker
    # file and the first read after it writes the one row. The rename lets one of many hooks win.
    marker = _marker(run)
    claim = f"{marker}.{os.getpid()}"
    try:
        os.rename(marker, claim)
    except OSError:
        return
    try:
        try:
            with open(claim, encoding="utf-8") as fh:
                payload = json.load(fh)
        except ValueError:
            payload = {"since": None, "outcome": "unknown", "detail": ""}
        load_lib_module("programme_journal").append(run, UNREADABLE, None, payload, lock_timeout=JOURNAL_LOCK_WAIT)
    except Exception:
        os.replace(claim, marker)
    else:
        os.unlink(claim)


def settle_faults(run, faults) -> None:
    seen = _marker(run) + ".bad-shape"
    if not faults:
        try:
            os.unlink(seen)
        except OSError:
            pass
    elif _create_new(seen):
        mark_episode(run, "bad_shape", ", ".join(faults))
        journal_episode(run)
