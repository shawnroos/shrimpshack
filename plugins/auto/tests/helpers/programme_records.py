"""Test helper: read, replace and edit a programme record through the run-record primitives.

A promoted programme's record file is an export of programme.db, so writing that
file changes nothing. These helpers go through run_record_core, which routes a
promoted home to its authority and a legacy home to its JSON file.
"""

import copy
import os
import sys

_LIB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib")
if _LIB not in sys.path:
    sys.path.insert(0, _LIB)
from _bootstrap import load_lib_module  # noqa: E402

core = load_lib_module("run_record_core")
ph = load_lib_module("programme_home")


def load(run):
    return core.read_run_record(ph.home_path(run), run)


def save(run, rec):
    replacement = copy.deepcopy(rec)

    def replace(current):
        current.clear()
        current.update(replacement)

    core._with_locked_run_record(ph.home_path(run), run, replace)


def edit(run, expr, env):
    def change(rec):
        programme = rec.get("programme") if isinstance(rec.get("programme"), dict) else {}
        exec(expr, dict(env, rec=rec, prog=programme, items=programme.get("items")))

    core._with_locked_run_record(ph.home_path(run), run, change)
