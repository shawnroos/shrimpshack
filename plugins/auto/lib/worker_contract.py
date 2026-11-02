#!/usr/bin/env python3
"""The PM-set contract a programme worker's run record carries.

One optional ``contract`` block holds ``version``, ``set_at``, ``set_by``, an ``authority`` map keyed
by decision kind, ``done_bar``, ``workflow`` and ``fan_out_cap``, plus the engine-written
``pending_versions`` and ``applied_version``. A record with no ``contract`` key behaves as it did before.
``effective_authority`` clamps the stored map against the programme's Authority table and active
Rulings at every read; ``guard`` is the one write check every contract-writing verb calls.
"""

from __future__ import annotations

import copy
import os
import re
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

run_record_core = load_lib_module("run_record_core")
programme_decisions = load_lib_module("programme_decisions")

CONTRACT_KEY = "contract"
NO_CONTRACT = "no_contract"
HAS_CONTRACT = "contract"
MODES = ("act", "act_and_tell", "propose", "never")
ASKS = ("pm", "shawn")
BITES = ("pulse", "step")
DONE_INTERNAL = ("steps_terminal", "gaps_closed", "phase_reached")
DONE_EXTERNAL = ("pr_merged", "ci_green")
REQUIRED = ("version", "set_at", "set_by", "authority", "done_bar", "workflow", "fan_out_cap")
OPTIONAL = ("pending_versions", "applied_version")
_WORKFLOW_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
_NO_LEVEL = "propose"


class ContractError(Exception):
    def __init__(self, message, code="invalid"):
        super().__init__(message)
        self.code = code


def _is_int(value) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _check_entry(kind, entry) -> None:
    if not isinstance(entry, dict) or set(entry) != {"mode", "asks"}:
        raise ContractError(f"authority entry for {kind!r} needs exactly the keys mode and asks", "bad_authority")
    if entry["mode"] not in MODES:
        raise ContractError(f"authority entry for {kind!r} has unknown mode {entry['mode']!r}; known: {list(MODES)}",
                            "bad_authority")
    if entry["asks"] not in ASKS:
        raise ContractError(f"authority entry for {kind!r} has unknown asks {entry['asks']!r}; known: {list(ASKS)}",
                            "bad_authority")


def _check_authority(authority) -> None:
    if not isinstance(authority, dict):
        raise ContractError("contract authority must be a map from decision kind to {mode, asks}", "bad_authority")
    for kind, entry in authority.items():
        try:
            programme_decisions.check_kind(kind)
        except programme_decisions.DecisionError:
            raise ContractError(f"contract authority names unknown decision kind {kind!r}", "unknown_kind")
        _check_entry(kind, entry)


def _check_names(label, value, known) -> None:
    if not isinstance(value, list) or any(not isinstance(v, str) for v in value):
        raise ContractError(f"done bar {label} must be a list of names", "bad_done_bar")
    for name in value:
        if name not in known:
            raise ContractError(
                f"done bar {label} names {name!r}, which the exit predicate does not compute; known: {list(known)}",
                "bad_done_bar")
    if len(set(value)) != len(value):
        raise ContractError(f"done bar {label} repeats a name", "bad_done_bar")


def _check_done_bar(done_bar) -> None:
    if not isinstance(done_bar, dict) or set(done_bar) != {"internal", "external"}:
        raise ContractError("contract done_bar needs exactly the keys internal and external", "bad_done_bar")
    _check_names("internal", done_bar["internal"], DONE_INTERNAL)
    _check_names("external", done_bar["external"], DONE_EXTERNAL)
    if not done_bar["internal"]:
        raise ContractError("done bar internal must name at least one exit-predicate input", "bad_done_bar")


def _check_pending(version, pending, applied) -> None:
    if not isinstance(pending, list):
        raise ContractError("pending_versions must be a list", "bad_pending")
    for entry in pending:
        if (not isinstance(entry, dict) or not {"version", "bite"} <= set(entry) <= {"version", "bite", "answer"}
                or not _is_int(entry["version"]) or entry["version"] < 1 or entry["bite"] not in BITES):
            raise ContractError(f"pending_versions entry {entry!r} needs an integer version and a bite of "
                                f"{list(BITES)}", "bad_pending")
        answer = entry.get("answer")
        if "answer" in entry and (not isinstance(answer, dict) or set(answer) != {"question_id", "text", "by"}
                                  or answer["by"] != "pm" or not all(isinstance(v, str) for v in answer.values())):
            raise ContractError(f"pending_versions answer in {entry!r} needs question_id, text and by 'pm'",
                                "bad_pending")
    if not _is_int(applied) or applied < 0 or applied > version:
        raise ContractError(f"applied_version {applied!r} must be an integer from 0 to the contract version {version}",
                            "bad_applied")


def validate(block) -> dict:
    if not isinstance(block, dict):
        raise ContractError("contract must be a map", "bad_shape")
    unknown = sorted(set(block) - set(REQUIRED) - set(OPTIONAL))
    if unknown:
        raise ContractError(f"contract has unknown keys {unknown}", "bad_shape")
    missing = [k for k in REQUIRED if k not in block]
    if missing:
        raise ContractError(f"contract is missing {missing}", "bad_shape")
    version = block["version"]
    if not _is_int(version) or version < 1:
        raise ContractError(f"contract version {version!r} must be an integer of at least 1", "bad_version")
    if run_record_core.parse_iso(block["set_at"]) is None:
        raise ContractError(f"contract set_at {block['set_at']!r} is not a timestamp", "bad_shape")
    if not isinstance(block["set_by"], str) or not block["set_by"]:
        raise ContractError("contract set_by must name the writing session", "bad_shape")
    _check_authority(block["authority"])
    _check_done_bar(block["done_bar"])
    workflow = block["workflow"]
    if not isinstance(workflow, str) or not _WORKFLOW_NAME_RE.match(workflow):
        raise ContractError(f"contract workflow {workflow!r} is not a workflow name", "bad_workflow")
    cap = block["fan_out_cap"]
    if not _is_int(cap) or cap < 1:
        raise ContractError(f"contract fan_out_cap {cap!r} must be an integer of at least 1", "bad_cap")
    _check_pending(version, block.get("pending_versions", []), block.get("applied_version", 0))
    return copy.deepcopy(block)


def new_contract(*, set_by, authority, done_bar, workflow, fan_out_cap, version=1, now=None) -> dict:
    return validate({
        "version": version, "set_at": now or run_record_core.now_iso(), "set_by": set_by,
        "authority": authority, "done_bar": done_bar, "workflow": workflow, "fan_out_cap": fan_out_cap,
        "pending_versions": [], "applied_version": 0,
    })


def contract_of(record):
    if CONTRACT_KEY not in record:
        return None
    block = record[CONTRACT_KEY]
    if not isinstance(block, dict):
        raise ContractError(f"the record's contract is {type(block).__name__}, not a map", "bad_shape")
    return block


def is_stale(block) -> bool:
    return block["version"] > block.get("applied_version", 0)


def reading(record) -> dict:
    block = contract_of(record)
    if block is None:
        return {"state": NO_CONTRACT}
    return {"state": HAS_CONTRACT, "version": block["version"], "applied_version": block.get("applied_version", 0),
            "stale": is_stale(block), "authority_kinds": sorted(block.get("authority") or {})}


def _narrower(a, b):
    order = programme_decisions.LEVEL_ORDER
    return a if order.index(a) <= order.index(b) else b


def effective_authority(contract, kind, *, item, level_of, rulings_of, now=None, accepted=True) -> dict:
    programme_decisions.check_kind(kind)
    level = level_of(kind) or _NO_LEVEL
    verdict = programme_decisions.who_decides(
        kind, item, level=level, rulings=rulings_of(kind), now=now or run_record_core.now_iso(), accepted=accepted)
    stored = (contract.get("authority") or {}).get(kind)
    mode = verdict["level"] if stored is None else _narrower(stored["mode"], verdict["level"])
    asks = "shawn" if verdict["decider"] == "shawn" else (stored or {}).get("asks", "pm")
    return {"kind": kind, "mode": mode, "asks": asks, "source": "programme" if stored is None else "contract",
            "clamped": stored is not None and mode != stored["mode"], "reason": verdict["reason"]}


def effective_map(contract, *, item, level_of, rulings_of, now=None, accepted=True) -> dict:
    return {kind: effective_authority(contract, kind, item=item, level_of=level_of, rulings_of=rulings_of,
                                      now=now, accepted=accepted)
            for kind in programme_decisions.DECISION_KINDS}


def programme_inputs(programme, item, prompt_lookup=None, now=None) -> dict:
    protocol = load_lib_module("programme_protocol")
    rulings = load_lib_module("programme_rulings")
    stamp = now or run_record_core.now_iso()
    levels = protocol.AuthorityLevels(prompt_lookup)
    repos = rulings.repos_for(programme, [item])
    return {
        "item": item, "now": stamp, "accepted": programme_decisions.stamped(programme),
        "level_of": lambda kind: levels.level(kind, repos),
        "rulings_of": lambda kind: rulings.pc.rulings_for(programme, item, kind, stamp),
    }


def _remit_has_worker(record, worker_session, space_of) -> bool:
    programme_home = load_lib_module("programme_home")
    programme = record.get("programme") or {}
    remit = programme.get("remit") or {}
    space = space_of(worker_session)
    if space:
        keys = set()
        for entry in remit.get("spaces") or []:
            try:
                keys.add(programme_home.space_key(entry.get("server") or programme_home.DEFAULT_SERVER,
                                                  entry.get("workspace"), entry.get("host")))
            except (programme_home.ProgrammeHomeError, AttributeError):
                continue
        if programme_home.space_key(*space) in keys:
            return True
    repos = {os.path.realpath(r["path"]) for r in remit.get("repos") or []
             if isinstance(r, dict) and isinstance(r.get("path"), str)}
    for item in (programme.get("items") or {}).values():
        sessions = {(item.get("owner") or {}).get("session_id")} | {
            s.get("session_id") for s in item.get("sessions") or [] if isinstance(s, dict)}
        if worker_session in sessions and item.get("repo") and os.path.realpath(item["repo"]) in repos:
            return True
    return False


def _lease_held(programme_home, run_id, caller) -> bool:
    for lease in programme_home.leases_for_session(caller):
        if lease.get("run") == run_id and programme_home.lease_status(lease) in programme_home.HELD_LEASE_STATES:
            return True
    return False


def guard(run_id, worker_session, *, caller=None, space_of=None, check_worker=True) -> dict:
    """Refuse unless the caller drives programme ``run_id`` and holds its lease and the worker is in its remit.

    Reads the programme record fresh on every call, and takes no lock itself, so a verb calls it once
    before taking the run-record lock and again inside it: a takeover between the two is refused.
    ``check_worker=False`` skips the remit check for a worker the caller is about to launch: it has no
    session yet, and start-worker already refuses an item outside the remit.
    """
    programme_home = load_lib_module("programme_home")
    session_registry = load_lib_module("session_registry")
    sid = caller or load_lib_module("driver_session").driving_session_id()
    if not sid:
        raise ContractError("CLAUDE_CODE_SESSION_ID is unset; run this from the PM's Claude session", "no_session")
    record = run_record_core.read_run_record(programme_home.home_path(run_id), run_id)
    if not session_registry.caller_drives(record, sid):
        raise ContractError("only the programme's driving session may write a worker's contract", "not_driving")
    if not _lease_held(programme_home, run_id, sid):
        raise ContractError("this session no longer holds the programme's lease; a handover or takeover moved "
                            "write authority", "lease_lost")
    if check_worker and (not worker_session
                         or not _remit_has_worker(record, worker_session, space_of or session_registry.space_of_session)):
        raise ContractError(f"worker session {worker_session!r} is not in the programme's remit", "outside_remit")
    return record
