#!/usr/bin/env python3
"""``set-contract``: the one verb that changes a programme worker's contract after it starts.

The PM session alone may call it, for a worker in the programme's remit. The driving-session and lease
checks run before the lock and again inside it, so a takeover that lands in between is refused. While
the item is ``launched`` the item's seed contract is the only copy and the change edits that; once the
item is ``bound`` the change lands in the worker's run record with a version bump and a
``pending_versions`` entry the engine settles. ``programme.py`` registers the verb through ``build_verbs(host)``.
"""

from __future__ import annotations

import contextlib
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
programme_record = load_lib_module("programme_record")
programme_authority = load_lib_module("programme_authority")
programme_journal = load_lib_module("programme_journal")
programme_decisions = load_lib_module("programme_decisions")
worker_contract = load_lib_module("worker_contract")
worker_question = load_lib_module("worker_question")
worker_register = load_lib_module("worker_register")
worker_rebake = load_lib_module("worker_rebake")
driver_session = load_lib_module("driver_session")

SET_KIND = "contract_set"
REFUSED_KIND = "request_refused"
VERB = "set-contract"
FIELD_OF = {"authority": "authority", "drop": "authority", "done_internal": "done_bar", "done_external": "done_bar",
            "workflow": "workflow", "fan_out_cap": "fan_out_cap"}


def _fields(change) -> list:
    return sorted({FIELD_OF[key] for key in change})


def _merged(block, change) -> dict:
    new = copy.deepcopy(block)
    authority = dict(new.get("authority") or {})
    for kind in change.get("drop") or []:
        if kind not in authority:
            raise worker_contract.ContractError(f"contract authority has no entry for {kind!r}; nothing to drop",
                                                "no_such_entry")
        del authority[kind]
    authority.update(change.get("authority") or {})
    new["authority"] = authority
    if "done_internal" in change or "done_external" in change:
        bar = new["done_bar"]
        new["done_bar"] = {"internal": change.get("done_internal", bar["internal"]),
                           "external": change.get("done_external", bar["external"])}
    for key in ("workflow", "fan_out_cap"):
        if key in change:
            new[key] = change[key]
    return new


def _refuse_widening(change, inputs) -> None:
    order = programme_decisions.LEVEL_ORDER
    for kind, entry in sorted((change.get("authority") or {}).items()):
        verdict = worker_contract.effective_authority({}, kind, **inputs)
        if order.index(entry["mode"]) > order.index(verdict["mode"]):
            raise worker_contract.ContractError(
                f"authority for {kind!r} cannot go to {entry['mode']!r}: the programme's Authority table and "
                f"Rulings cap it at {verdict['mode']!r} ({verdict['reason']})", "widens_authority")


def _narrows(block, change, inputs) -> bool:
    order = programme_decisions.LEVEL_ORDER
    return any(order.index(entry["mode"]) < order.index(worker_contract.effective_authority(block, kind, **inputs)["mode"])
               for kind, entry in (change.get("authority") or {}).items())


def _revise(block, change, bite, programme, key, sid, now, queue):
    new = _merged(block, change)
    worker_contract.validate(new)
    inputs = worker_contract.programme_inputs(programme, key, now=now)
    _refuse_widening(change, inputs)
    chosen = bite or ("pulse" if _narrows(block, change, inputs) else "step")
    if chosen not in worker_contract.BITES:
        raise worker_contract.ContractError(f"bite {chosen!r} is not one of {list(worker_contract.BITES)}", "bad_bite")
    if queue:
        worker_question.append_pending(new, bite=chosen, set_by=sid, now=now)
    else:
        new["version"] += 1
        new["set_at"] = now or run_record_core.now_iso()
        new["set_by"] = sid
    worker_contract.validate(new)
    return new, {"version": new["version"], "bite": chosen, "fields": _fields(change), "queued": queue}


def _open_for_writes(record) -> None:
    if (record.get("programme") or {}).get("ended"):
        raise worker_contract.ContractError("the programme has ended", "ended")


def _refuse_done(rec, key, auto_run) -> None:
    if (rec.get("loop") or {}).get("phase") == "done":
        raise worker_contract.ContractError(
            f"run {auto_run} for item {key} is done and its contract is closed; start a follow-up run for the item "
            "from a copy of this contract (start-worker --contract) and register it", "run_done")


def _locate_target(record, item_id):
    programme = programme_home.normalize_programme(record.get("programme") or {})
    key = programme_record._resolve(programme, programme_record.check_item_id(item_id))
    item = programme["items"][key]
    state = item.get(worker_register.ITEM_KEY)
    if not isinstance(state, dict):
        raise worker_contract.ContractError(
            f"item {key!r} has no contracted run; start it with start-worker --contract", "no_contract_run")
    if state.get("state") == worker_register.BLOCKED:
        raise worker_contract.ContractError(f"item {key!r} is launch-blocked; the choice returned to Shawn",
                                            "launch_blocked")
    worker = (item.get("owner") or {}).get("session_id") or state.get("session_id")
    return key, state, worker


def _edit_seed(run_id, key, worker, change, bite, sid, space_of, now) -> dict:
    def edit(rec):
        worker_contract.guard(run_id, worker, caller=sid, space_of=space_of)
        _open_for_writes(rec)
        programme = rec["programme"] = programme_home.normalize_programme(rec.get("programme") or {})
        live = programme["items"][key].get(worker_register.ITEM_KEY) or {}
        if live.get("state") != worker_register.LAUNCHED:
            raise worker_contract.ContractError(
                f"item {key!r} is now {live.get('state')}, no longer launched; run the change again", "state_changed")
        live["contract"], summary = _revise(live["contract"], change, bite, programme, key, sid, now, queue=False)
        return dict(summary, item=key, auto_run=None, via="seed")

    compose = lambda summary, _rec: programme_journal.entry(SET_KIND, sid, summary)  # noqa: E731
    return dict(programme_authority.write(programme_home.home_path(run_id), run_id, edit, compose)["result"],
                journaled=True)


def _edit_run(run_id, key, state, worker, change, bite, sid, space_of, now) -> dict:
    repo, auto_run = state.get("path"), state.get("run_id")
    landed = {}

    def edit(rec):
        fresh = worker_contract.guard(run_id, worker, caller=sid, space_of=space_of)
        _open_for_writes(fresh)
        if not rec.get("contract_capable"):
            raise worker_contract.ContractError("run predates contracts", "predates_contracts")
        _refuse_done(rec, key, auto_run)
        if rec.get("driving_session_id") != worker:
            raise worker_contract.ContractError(
                f"run record session {rec.get('driving_session_id')} is not the item's owner session {worker}",
                "session_mismatch")
        block = worker_contract.contract_of(rec)
        if block is None:
            raise worker_contract.ContractError("the run record has no contract yet; register-run copies the seed",
                                                "no_contract")
        rec["contract"], summary = _revise(block, change, bite, fresh.get("programme") or {}, key, sid, now,
                                           queue=True)
        landed.update(summary, item=key, auto_run=auto_run, via="run")

    run_record_core._with_locked_run_record(repo, auto_run, edit)
    try:
        programme_journal.append(run_id, SET_KIND, sid, landed)
        landed["journaled"] = True
    except programme_journal.JournalError:
        landed["journaled"] = False
    return landed


def set_contract(run_id, item_id, change, *, bite=None, caller=None, space_of=None, now=None) -> dict:
    sid = caller or driver_session.driving_session_id()
    home = programme_home.home_path(run_id)
    key, state, worker = _locate_target(run_record_core.read_run_record(home, run_id), item_id)
    record = worker_contract.guard(run_id, worker, caller=sid, space_of=space_of)
    _open_for_writes(record)
    if "workflow" in change:
        worker_rebake.check_change(record, key, state, change["workflow"])
    if os.path.exists(os.path.join(home, programme_home.COMPACT_FLAG)):
        raise worker_contract.ContractError(
            "context was compacted or handed over: read the rules in force, then run `programme.py rules --ack`",
            "compacted")
    if state.get("state") == worker_register.LAUNCHED:
        return _edit_seed(run_id, key, worker, change, bite, sid, space_of, now)
    return _edit_run(run_id, key, state, worker, change, bite, sid, space_of, now)


def _split(text) -> list:
    return [part.strip() for part in text.split(",") if part.strip()]


def _entry(spec) -> tuple:
    kind, sep, rest = spec.partition("=")
    mode, _, asks = rest.partition(":")
    if not sep or not kind or not mode:
        raise ValueError(f"--authority takes <decision kind>=<mode>[:<asks>], got {spec!r}")
    return kind, {"mode": mode, "asks": asks or "pm"}


def parse_change(opts) -> dict:
    change = {}
    if opts.get("authority"):
        change["authority"] = dict(_entry(spec) for spec in opts["authority"])
    if opts.get("drop-authority"):
        change["drop"] = list(opts["drop-authority"])
    if opts.get("done-internal"):
        change["done_internal"] = _split(opts["done-internal"])
    if opts.get("done-external"):
        change["done_external"] = [] if opts["done-external"] == "none" else _split(opts["done-external"])
    if opts.get("workflow"):
        change["workflow"] = opts["workflow"]
    if opts.get("fan-out-cap"):
        change["fan_out_cap"] = int(opts["fan-out-cap"])
    if not change:
        raise ValueError("set-contract needs at least one change: --authority, --drop-authority, --done-internal, "
                         "--done-external, --workflow or --fan-out-cap")
    return change


def _log_refusal(run_id, sid, item_id, exc) -> None:
    try:
        programme_journal.append(run_id, REFUSED_KIND, sid or "",
                                 {"verb": VERB, "item": item_id, "code": exc.code, "reason": str(exc)})
    except Exception as err:
        sys.stderr.write(f"programme.py: could not journal the refusal: {err}\n")


@contextlib.contextmanager
def _refusals(host, run_id, item_id):
    try:
        yield
    except worker_contract.ContractError as exc:
        _log_refusal(run_id, driver_session.driving_session_id(), item_id, exc)
        raise host.ProgrammeError(f"refused ({exc.code}): {exc}") from None


def _h_set_contract(host, argv):
    positional, opts = host._parse(argv, values=("run", "item", "bite", "workflow", "fan-out-cap", "done-internal",
                                                 "done-external"), multi=("authority", "drop-authority"))
    if positional or not opts.get("item"):
        raise ValueError("usage: set-contract --item <id> [--run <programme run>] [--authority <kind>=<mode>[:<asks>]]... "
                         "[--drop-authority <kind>]... [--done-internal <a,b>] [--done-external <a,b|none>] "
                         "[--workflow <name>] [--fan-out-cap <n>] [--bite pulse|step]")
    change = parse_change(opts)
    run_id, home, _record = host._locate(opts)
    with _refusals(host, run_id, opts["item"]):
        out = set_contract(run_id, opts["item"], change, bite=opts.get("bite"))
    host.refresh_view(run_id, home)
    host._emit(dict(out, ok=True, run=run_id, kind=SET_KIND))
    return 0


_SPECS = (
    ("set-contract", _h_set_contract,
     "--item <id> [--run <programme run>] [--authority <kind>=<mode>[:<asks>]]... [--drop-authority <kind>]... "
     "[--done-internal <a,b>] [--done-external <a,b|none>] [--workflow <name>] [--fan-out-cap <n>] "
     "[--bite pulse|step]",
     "any caller but the programme's driving session that holds its lease, checked again inside the run-record "
     "lock; a worker outside the remit; an item with no contracted run or a launch-blocked one; a done run; a "
     "run that predates contracts; an authority change that widens a kind past the Authority table and active "
     "Rulings; an unknown decision kind, mode, done-bar name, workflow name or bite. With no --bite, a change "
     "that narrows any authority binds at the next pulse and every other change at the next step boundary. "
     "While the item is launched it edits the item's seed contract and bumps its version; once bound it bumps "
     "the run record's contract version and queues one pending entry. Journals contract_set."),
)


def build_verbs(host) -> dict:
    return {name: host._Verb(functools.partial(handler, host), args, rejects=rejects)
            for name, handler, args, rejects in _SPECS}
