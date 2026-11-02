#!/usr/bin/env python3
"""The workflow re-bake: replace a contracted run's remaining steps when the applied contract names a new workflow.

A re-bake is due when ``workflow.baked_from_contract_version`` is behind the contract's applied version, every
pending change has bitten, and the contract names a different workflow than the run carries. One locked
closure skips the old pending steps, adds the new workflow's steps under ids that carry the version, and stamps
the baked version. The stamp is what makes the pulse's repeat call a no-op, and the gap between a contract write
and the stamp is the detectable ``needs-re-bake`` state. Dispatched steps and their findings are never touched.
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
workflows = load_lib_module("workflows")
phase_grammar = load_lib_module("phase-grammar")

NO_CONTRACT = worker_contract.NO_CONTRACT
CURRENT = "current"
WAITING = "waiting"
NEEDS = "needs-re-bake"
BLOCKED = "re-bake-blocked"
BAKED_KEY = "baked_from_contract_version"
FIRST_VERSION = 1
DEFAULT_PHASES = ["plan", "handoff", "work"]


class RebakeError(Exception):
    pass


def _baked(record) -> int:
    # A run that never re-baked was started under the contract's first version.
    return int((record.get("workflow") or {}).get(BAKED_KEY, FIRST_VERSION))


def _differs(record, block) -> bool:
    current = (record.get("workflow") or {}).get("name")
    # A workflow-blind record has no baked workflow to replace.
    return isinstance(current, str) and workflows.canonical_name(block["workflow"]) != workflows.canonical_name(current)


def _due(record):
    block = worker_contract.lenient_block(record)
    if block is None or record.get(phase_grammar.LOOP_PHASE_KEY) == "done":
        return None
    applied = block.get("applied_version", 0)
    if applied < block["version"] or block.get("pending_versions"):
        return None
    if _baked(record) >= applied or not _differs(record, block):
        return None
    return block["workflow"], applied


def state(record) -> dict:
    block = worker_contract.lenient_block(record)
    if block is None:
        return {"state": NO_CONTRACT}
    due = _due(record)
    out = {"baked_from_contract_version": _baked(record), "applied_version": block.get("applied_version", 0),
           "contract_workflow": block["workflow"], "run_workflow": (record.get("workflow") or {}).get("name")}
    if due is not None:
        return dict(out, state=NEEDS)
    waiting = bool(block.get("pending_versions")) and _differs(record, block)
    return dict(out, state=WAITING if waiting else CURRENT)


def _phases(record):
    order = record.get("phase_order") or DEFAULT_PHASES
    phase = record.get(phase_grammar.LOOP_PHASE_KEY)
    return order, (order.index(phase) if phase in order else 0)


def _remaining_steps(workflow, record) -> list:
    order, start = _phases(record)
    keep = [u for u in workflow.get("steps", []) if u.get("phase", "work") in order[start:]]
    if not keep:
        raise RebakeError(f"workflow {workflow['name']!r} has no step in phase {order[start:]}; "
                          "nothing would remain for the run to do")
    return keep


def _resolve(name, repo_root):
    try:
        return workflows.resolve(name, repo_root)
    except workflows.WorkflowError as exc:
        raise worker_contract.ContractError(f"contract workflow {name!r} cannot be used: {exc}",
                                            "unknown_workflow") from None


def check_workflow(name, repo_root, record=None) -> None:
    """Refuse a workflow name that does not resolve in the repo's tiers, one the validator rejects, or one with no step left for the run."""
    workflow, _tier = _resolve(name, repo_root)
    try:
        workflows.validate(workflow)
    except workflows.WorkflowError as exc:
        raise worker_contract.ContractError(f"contract workflow {name!r} is rejected by the validator: {exc}",
                                            "rejected_workflow") from None
    if record is not None:
        try:
            _remaining_steps(workflow, record)
        except RebakeError as exc:
            raise worker_contract.ContractError(str(exc), "empty_workflow") from None


def check_change(programme_record, item_key, item_state, name) -> None:
    """The set-contract check: resolve the name in the worker's repo, and against its run record once it is bound."""
    item = ((programme_record.get("programme") or {}).get("items") or {}).get(item_key) or {}
    repo = item_state.get("path") or item.get("repo")
    if not repo:
        raise worker_contract.ContractError(f"item {item_key!r} names no repo to resolve workflow {name!r} in",
                                            "unknown_workflow")
    record = None
    if item_state.get("path") and item_state.get("run_id"):
        record = run_record_core.read_run_record(item_state["path"], item_state["run_id"])
    check_workflow(name, repo, record)


def _new_steps(workflow, record, version) -> list:
    keep = _remaining_steps(workflow, record)
    ids = {u["id"]: f"{u['id']}-v{version}" for u in keep}
    earlier = {u["id"] for u in workflow["steps"]} - set(ids)
    out = []
    for u in keep:
        step = workflows.step_for(u, workflow)
        step["id"] = ids[u["id"]]
        step["depends_on"] = [ids.get(d, d) for d in step["depends_on"] if d not in earlier]
        out.append(run_record_core._normalize_step(step, loop_phase=record.get(phase_grammar.LOOP_PHASE_KEY, "work")))
    return out


def _bake(rec, repo_root) -> dict:
    due = _due(rec)
    if due is None:
        return {"rebaked": False}
    name, version = due
    try:
        workflow, tier = workflows.load_and_validate(name, repo_root)
    except workflows.WorkflowError as exc:
        raise RebakeError(f"workflow {name!r}: {exc}") from None
    added = _new_steps(workflow, rec, version)
    steps = rec.setdefault("steps", [])
    taken = {s.get("id") for s in steps}
    clash = sorted(s["id"] for s in added if s["id"] in taken)
    if clash:
        raise RebakeError(f"re-bake step ids already exist: {clash}")
    unknown = sorted({d for s in added for d in s["depends_on"]} - taken - {s["id"] for s in added})
    if unknown:
        raise RebakeError(f"workflow {name!r} depends on steps the run does not have: {unknown}")
    skipped = []
    for step in steps:
        if step.get("state") == "pending":
            step["state"] = "terminal-skip"
            step["skip_reason"] = f"workflow replaced v{version}"
            skipped.append(step["id"])
    steps.extend(added)
    previous = (rec.get("workflow") or {}).get("name")
    rec["workflow"] = {"name": workflow["name"], "source_tier": tier, BAKED_KEY: version}
    return {"rebaked": True, "version": version, "from": previous, "to": workflow["name"],
            "skipped": skipped, "added": [s["id"] for s in added]}


def complete(repo_root, run_id, record=None) -> dict:
    """Finish a due re-bake once. A workflow that cannot be baked leaves the run as it was and reads ``re-bake-blocked``."""
    record = record if record is not None else run_record_core.read_run_record(repo_root, run_id)
    if _due(record) is None:
        return {"rebaked": False, "state": state(record)["state"]}
    try:
        return run_record_core._with_locked_run_record(repo_root, run_id, lambda rec: _bake(rec, repo_root))
    except (RebakeError, run_record_core.RunRecordError) as exc:
        return {"rebaked": False, "state": BLOCKED, "why": str(exc)}


def complete_due(repo_root, run_id, record=None):
    """Complete any due re-bake and return the run record as it now stands."""
    record = record if record is not None else run_record_core.read_run_record(repo_root, run_id)
    if _due(record) is None:
        return record
    if complete(repo_root, run_id, record).get("rebaked"):
        return run_record_core.read_run_record(repo_root, run_id)
    return record
