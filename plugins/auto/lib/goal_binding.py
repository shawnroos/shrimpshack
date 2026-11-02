#!/usr/bin/env python3
"""The worker's side of a goal doc: the bind and rebind instructions, and the report that it bound.

A native ``/goal`` can only be set by the session itself, so Auto asks and the worker acts. The worker
reports the goal version it bound with ``goal-bound``; the engine stores it as the contract's
``goal_bound_version`` and never reads it to decide done. A missing or failed bind leaves the exit
predicate in charge.
"""

from __future__ import annotations

import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

run_record_core = load_lib_module("run_record_core")
worker_contract = load_lib_module("worker_contract")
driver_session = load_lib_module("driver_session")

MODE_REBIND = "rebind"
MODE_BIND_ONCE = "bind-once"
# U1 did not probe whether a bound goal re-reads its file; flip to MODE_BIND_ONCE only on a recorded probe.
REREAD_MODE = MODE_REBIND

BIND_TAG = "GOAL BIND:"
REBIND_TAG = "GOAL REBIND:"
_REPORT = 'bash "$CLAUDE_PLUGIN_ROOT/lib/run_record.sh" goal-bound {run} {version}'
_TAIL = "If it fails, carry on: the exit predicate still decides done."


def instruction(repo_root, run_id, record, mode=None) -> str:
    block = worker_contract.contract_of(record)
    if block is None or not block.get("goal_version"):
        return ""
    reading = load_lib_module("goal_doc").reading(repo_root, run_id, record)
    path = reading.get("path")
    if reading["state"] not in ("current", "goal-stale") or not path:
        return ""
    version, bound = block["goal_version"], block.get("goal_bound_version", 0)
    report = _REPORT.format(run=run_id, version=version)
    if not bound:
        return f"{BIND_TAG} run `/goal {path}` yourself now, then report it with `{report}`. Auto never binds it. {_TAIL}"
    if version > bound and (mode or REREAD_MODE) == MODE_REBIND:
        return (f"{REBIND_TAG} the goal doc changed (v{version}, you bound v{bound}). At the next step boundary "
                f"re-run `/goal {path}`, then report it with `{report}`. {_TAIL}")
    return ""


def annotate(intent, repo_root, run_id, record, mode=None) -> None:
    text = instruction(repo_root, run_id, record, mode)
    if text:
        intent["operator_guidance"] = f"{intent.get('operator_guidance') or ''}\n\n{text}".lstrip("\n")


def record_bound(repo_root, run_id, version) -> dict:
    error = run_record_core.RunRecordError
    session = driver_session.driving_session_id()
    if not session:
        raise ValueError("goal-bound needs CLAUDE_CODE_SESSION_ID (the run's own session id)")
    try:
        version = int(version)
    except (TypeError, ValueError):
        raise ValueError(f"goal version must be an integer: {version!r}") from None
    landed = {}

    def mutate(record):
        block = worker_contract.contract_of(record)
        if block is None:
            raise error(f"run {run_id} has no contract, so there is no goal to bind")
        if not record.get("driving_session_id") or record["driving_session_id"] != session:
            raise error(f"only the run's own session may report a goal bound (caller {session!r})")
        if not 1 <= version <= block.get("goal_version", 0):
            raise error(f"goal version {version} is not between 1 and the contract's goal version "
                        f"{block.get('goal_version', 0)}")
        block["goal_bound_version"] = max(block.get("goal_bound_version", 0), version)
        worker_contract.validate(block)
        landed.update(run=run_id, goal_bound_version=block["goal_bound_version"], goal_version=block["goal_version"])

    run_record_core._with_locked_run_record(repo_root, run_id, mutate)
    return landed
