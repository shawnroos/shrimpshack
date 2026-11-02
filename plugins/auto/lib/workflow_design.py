#!/usr/bin/env python3
"""What a PM-designed workflow must satisfy before a worker's contract may name it (R17, KTD13).

A workflow file can carry no key from the contract's authority vocabulary, so it cannot grant a worker
authority the contract does not. ``gate`` is the ``workflow_change`` decision kind applied to
``set-contract --workflow``: act changes silently, act_and_tell changes and returns a tell, propose hands
a Shawn ask and changes nothing until it returns with a matching digest, never refuses. The goal doc for a
designed workflow is written by ``write-goal``; this module writes no file.
"""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

run_record_core = load_lib_module("run_record_core")
programme_home = load_lib_module("programme_home")
programme_decisions = load_lib_module("programme_decisions")
worker_contract = load_lib_module("worker_contract")
workflows = load_lib_module("workflows")

KIND = "workflow_change"
FIELD_NAMES = ("authority", "autonomy", "decisions", "asks", "allow", "allowed", "mode")
AUTHORITY_KEYS = frozenset(FIELD_NAMES) | frozenset(programme_decisions.DECISION_KINDS) | frozenset(
    worker_contract.MODES) | frozenset(worker_contract.ASKS)


def authority_keys_in(value, path="") -> list:
    found = []
    if isinstance(value, dict):
        for key, inner in value.items():
            here = f"{path}.{key}" if path else str(key)
            if key in AUTHORITY_KEYS or f"{key}s" in AUTHORITY_KEYS:
                found.append(here)
            found.extend(authority_keys_in(inner, here))
    elif isinstance(value, list):
        for index, inner in enumerate(value):
            found.extend(authority_keys_in(inner, f"{path}[{index}]"))
    return found


def check_no_authority(workflow, name) -> None:
    found = authority_keys_in(workflow)
    if found:
        raise worker_contract.ContractError(
            f"workflow {name!r} carries authority keys {found}; a workflow cannot grant authority beyond the "
            "contract, so take them out and set authority with set-contract --authority", "workflow_authority")


def digest(item_key, workflow) -> str:
    body = json.dumps({"item": item_key, "workflow": workflow}, sort_keys=True)
    return hashlib.sha256(body.encode()).hexdigest()[:12]


def _approved(item, ask_id, token) -> bool:
    ask = programme_decisions.handed(item)
    answered = ask.get("answered")
    return (ask.get("id") == ask_id and ask.get("kind") == KIND and isinstance(answered, dict)
            and answered.get("choice") == "ship" and f"workflow {token}" in (ask.get("evidence") or []))


def _hand_via_programme(programme_run, item_key, question, token) -> None:
    argv = [sys.executable, os.path.join(_LIB_DIR, "programme.py"), "hand-item", item_key, "--run", programme_run,
            "--kind", KIND, "--question", question, "--evidence", f"workflow {token}",
            "--if-nothing", "the contract keeps its current workflow"]
    done = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, text=True, check=False)
    if done.returncode != 0:
        raise worker_contract.ContractError(
            f"hand-item for the workflow change failed: {(done.stderr or done.stdout).strip()}", "hand_failed")


def _current(item, state):
    if state.get("path") and state.get("run_id"):
        block = worker_contract.contract_of(run_record_core.read_run_record(state["path"], state["run_id"]))
    else:
        block = state.get("contract")
    return (block or {}).get("workflow")


def gate(record, programme_run, item_key, state, name, *, approved=None, hand=None, now=None) -> tuple:
    """Apply the workflow_change authority to naming ``name``; return ``(waiting, tell)``.

    ``waiting`` is the result to return instead of writing, or None to go on. ``tell`` is the act_and_tell line.
    """
    programme = programme_home.normalize_programme(record.get("programme") or {})
    item = programme["items"][item_key]
    repo = state.get("path") or item.get("repo")
    workflow, _tier = workflows.resolve(name, repo)
    check_no_authority(workflow, name)
    current = _current(item, state)
    if current is not None and workflows.canonical_name(current) == workflows.canonical_name(name):
        return None, None
    verdict = worker_contract.effective_authority(
        {}, KIND, **worker_contract.programme_inputs(programme, item_key, now=now))
    if verdict["mode"] == "never":
        raise worker_contract.ContractError(
            f"workflow_change is never for item {item_key!r} ({verdict['reason']}); the contract keeps its "
            "current workflow", "authority_never")
    if verdict["mode"] == "propose":
        token = digest(item_key, workflow)
        if not _approved(item, approved, token):
            if item.get("state") == "handed" and not programme_decisions.handed(item).get("answered"):
                raise worker_contract.ContractError(
                    f"item {item_key!r} already waits on Shawn's answer; the contract keeps its current workflow",
                    "item_handed")
            (hand or _hand_via_programme)(
                programme_run, item_key, f"Change the workflow of {item_key} from {current} to {name}?", token)
            return {"state": "waiting_on_shawn", "written": False, "workflow": name, "change": token,
                    "authority": verdict["mode"]}, None
    if verdict["mode"] == "act_and_tell":
        return None, f"Changed the workflow of {item_key} from {current} to {name}."
    return None, None


def _main(argv) -> int:
    if len(argv) != 2 or argv[0] != "check":
        sys.stderr.write("usage: workflow_design.py check <workflow.json>\n")
        return 2
    try:
        with open(argv[1], encoding="utf-8") as fh:
            workflow = json.load(fh)
        check_no_authority(workflow, workflow.get("name") if isinstance(workflow, dict) else argv[1])
        workflows.validate(workflow)
    except (OSError, ValueError, worker_contract.ContractError, workflows.WorkflowError) as exc:
        sys.stderr.write(f"refused: {exc}\n")
        return 1
    sys.stdout.write("ok\n")
    return 0


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))
