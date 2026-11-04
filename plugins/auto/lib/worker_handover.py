#!/usr/bin/env python3
"""``handover-contract``: carry an item's contract to a new run when the PM hands the item to another worker.

Order is the atomicity argument. Two files change, so the old run closes first and the item's pointer
moves second: a crash between them leaves one closed run still bound to the item (no open run at all),
never two open ones, and a repeat call finishes the move from the closed run's contract. The new run
starts as a ``launched`` item seed one version above the old contract, with every pending entry
rebound to the pulse, so the new worker's first pulse applies them all. ``start-worker --contract
<file> --plan <plan>`` then launches it from that seed. ``programme.py`` registers the verb through
``build_verbs(host)``.
"""

from __future__ import annotations

import copy
import functools
import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

run_record_core = load_lib_module("run_record_core")
programme_home = load_lib_module("programme_home")
programme_authority = load_lib_module("programme_authority")
programme_journal = load_lib_module("programme_journal")
worker_contract = load_lib_module("worker_contract")
worker_contract_write = load_lib_module("worker_contract_write")
worker_register = load_lib_module("worker_register")
driver_session = load_lib_module("driver_session")

HANDOVER_KIND = "contract_handover"
VERB = "handover-contract"


def next_seed(block, sid, now=None) -> dict:
    """The old contract as the new run's seed: version + 1, same terms, every pending entry bound at the pulse."""
    seed = copy.deepcopy(block)
    pending = [dict(entry, bite="pulse") for entry in seed.get("pending_versions") or []]
    worker_contract.bump(seed, sid, now)
    seed["pending_versions"] = pending + [{"version": seed["version"], "bite": "pulse"}]
    seed["applied_version"] = 0
    if "goal_bound_version" in seed:
        seed["goal_bound_version"] = 0
    return worker_contract.validate(seed)


def _close_old(run_id, repo, auto_run, worker, sid, space_of) -> dict:
    def close(rec):
        fresh = worker_contract.guard(run_id, worker, caller=sid, space_of=space_of)
        worker_contract_write.open_for_writes(fresh)
        worker_contract.require_capable(rec)
        worker_contract.require_owner(rec, worker)
        block = worker_contract.contract_of(rec)
        if block is None:
            raise worker_contract.ContractError("the run record has no contract to hand over", "no_contract")
        worker_contract.close_run(rec)
        return copy.deepcopy(block)

    return run_record_core._with_locked_run_record(repo, auto_run, close)


def _move_pointer(run_id, home, key, repo, auto_run, worker, seed, sid, space_of) -> dict:
    def edit(rec):
        worker_contract.guard(run_id, worker, caller=sid, space_of=space_of)
        worker_contract_write.open_for_writes(rec)
        programme = rec["programme"] = programme_home.normalize_programme(rec.get("programme") or {})
        item = programme["items"][key]
        live = item.get(worker_register.ITEM_KEY) or {}
        if (live.get("state") != worker_register.BOUND or live.get("run_id") != auto_run
                or live.get("path") != repo):
            raise worker_contract.ContractError(
                f"item {key!r} no longer holds bound run {auto_run}; read its state and run the handover again",
                "state_changed")
        now = run_record_core.now_iso()
        item[worker_register.ITEM_KEY] = {
            "state": worker_register.LAUNCHED, "mode": 1, "attempts": 0, "session_id": None, "contract": seed,
            "plan": None, "launched_at": None, "last_start_ok": None, "run_id": None, "path": None,
            "bound_at": None, "handed_over_from": {"run_id": auto_run, "path": repo, "version": seed["version"] - 1}}
        item["history"].append({"at": now, "kind": "run_handover", "from_run": auto_run,
                                "contract_version": seed["version"]})
        return {"item": key, "from_run": auto_run, "from_path": repo, "version": seed["version"],
                "pending": len(seed["pending_versions"]), "state": worker_register.LAUNCHED}

    compose = lambda summary, _rec: programme_journal.entry(HANDOVER_KIND, sid, summary)  # noqa: E731
    return dict(programme_authority.write(programme_home.home_path(run_id), run_id, edit, compose)["result"],
                journaled=True)


def handover(run_id, item_id, *, caller=None, space_of=None, now=None) -> dict:
    sid = caller or driver_session.driving_session_id()
    home = programme_home.home_path(run_id)
    key, state, worker = worker_contract_write.locate_target(run_record_core.read_run_record(home, run_id), item_id)
    if state.get("state") != worker_register.BOUND:
        raise worker_contract.ContractError(
            f"item {key!r} is {state.get('state')}, not bound: a launched item's contract is edited with "
            "set-contract, and only a bound run is handed over", "not_bound")
    record = worker_contract.guard(run_id, worker, caller=sid, space_of=space_of)
    worker_contract_write.open_for_writes(record)
    worker_contract_write.refuse_if_compacted(home)
    repo, auto_run = state.get("path"), state.get("run_id")
    block = _close_old(run_id, repo, auto_run, worker, sid, space_of)
    return _move_pointer(run_id, home, key, repo, auto_run, worker, next_seed(block, sid, now), sid, space_of)


def _h_handover_contract(host, argv):
    positional, opts = host._parse(argv, values=("run", "item"))
    if positional or not opts.get("item"):
        raise ValueError("usage: handover-contract --item <id> [--run <programme run>]")
    run_id, home, _record = host._locate(opts)
    with worker_contract_write.journaled_refusals(host, run_id, opts["item"], VERB):
        out = handover(run_id, opts["item"])
    host.refresh_view(run_id, home)
    host._emit(dict(out, ok=True, run=run_id, kind=HANDOVER_KIND,
                    next="start-worker <item> --contract <any contract file> --plan <plan> -- <spinoff arguments>"))
    return 0


_SPECS = (
    ("handover-contract", _h_handover_contract, "--item <id> [--run <programme run>]",
     "any caller but the programme's driving session that holds its lease, checked again inside the run-record "
     "lock; a worker outside the remit; an item with no contracted run or one that is not bound; a run that "
     "predates contracts or has no contract. Closes the item's bound run, makes the item a launched seed one "
     "contract version above the old one with the same authority, done bar, workflow and cap and every "
     "pending change bound at the new run's first pulse, and journals contract_handover. The old run then "
     "refuses contract writes. start-worker --contract launches the new worker from that seed."),
)


def build_verbs(host) -> dict:
    return {name: host._Verb(functools.partial(handler, host), args, rejects=rejects)
            for name, handler, args, rejects in _SPECS}
