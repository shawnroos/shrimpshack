#!/usr/bin/env python3
"""The start path for a contracted worker, and the ``register-run`` verb that binds its Auto run to its item.

``start-worker --contract`` seeds the contract on the item (``auto_run`` block, state ``launched``) before
the launch. The worker's ``register-run`` copies that seed into its run record, then marks the item
``bound``. The copy is the commit point, so a crash between the two re-runs the copy and finishes.
``programme.py`` registers the verb through ``build_verbs(host)``.
"""

from __future__ import annotations

import contextlib
import functools
import json
import os
import sys
import uuid

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module, resolve_host_repo_root  # noqa: E402

run_record_core = load_lib_module("run_record_core")
programme_home = load_lib_module("programme_home")
programme_record = load_lib_module("programme_record")
programme_authority = load_lib_module("programme_authority")
programme_sanitize = load_lib_module("programme_sanitize")
worker_contract = load_lib_module("worker_contract")
driver_session = load_lib_module("driver_session")

ITEM_KEY = "auto_run"
LAUNCHED = "launched"
BOUND = "bound"
BLOCKED = "launch-blocked"
MAX_MODES = 2
WINDOW_ENV = "CLAUDE_AUTO_REGISTER_WINDOW"
DEFAULT_WINDOW = 180.0
CONTRACT_FIELDS = ("authority", "done_bar", "workflow", "fan_out_cap")
PLAN_CAP = 300


class RegisterError(Exception):
    def __init__(self, message, code="refused"):
        super().__init__(message)
        self.code = code


@contextlib.contextmanager
def refusals(host):
    try:
        yield
    except (RegisterError, worker_contract.ContractError) as exc:
        raise host.ProgrammeError(f"refused ({exc.code}): {exc}") from None


def _window() -> float:
    try:
        return float(os.environ.get(WINDOW_ENV, DEFAULT_WINDOW))
    except ValueError:
        return DEFAULT_WINDOW


def _age(stamp) -> float:
    then = run_record_core.parse_iso(stamp)
    now = run_record_core.parse_iso(run_record_core.now_iso())
    return (now - then).total_seconds() if then and now else float("inf")


def load_contract_file(path, set_by) -> dict:
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, ValueError) as exc:
        raise RegisterError(f"cannot read the --contract file: {exc}", "bad_contract_file") from None
    if not isinstance(doc, dict) or set(doc) != set(CONTRACT_FIELDS):
        raise RegisterError(f"the --contract file needs exactly the keys {list(CONTRACT_FIELDS)}", "bad_contract_file")
    return worker_contract.new_contract(set_by=set_by, **doc)


def _register_command(run_id, key) -> str:
    return (f"programme.sh register-run --run {run_id} --item {key} --auto-run <your run id> "
            "--repo <the repo path that holds your run record>")


def kickoff_text(mode, plan, run_id, key) -> str:
    if mode == 1:
        return f"/auto {plan}\n"
    return (f"Your first action is to run /auto {plan}. Do not read the handoff first and do not wait for "
            f"direction. When your run exists, register it with: {_register_command(run_id, key)}\n")


def registration_section(run_id, key) -> str:
    return ("\n\nProgramme registration\n"
            f"Once your Auto run exists, record it with the programme: {_register_command(run_id, key)}")


def _refuse_relaunch(run_id, home, key, state, attempts) -> None:
    if state.get("state") == BOUND:
        raise RegisterError(f"item {key!r} already has a bound run ({state.get('run_id')}); one item is one run",
                            "already_bound")
    if state.get("state") == BLOCKED or attempts >= MAX_MODES:
        if state.get("state") != BLOCKED:
            _mark_blocked(run_id, home, key)
        raise RegisterError(f"both launch modes failed for item {key!r}; the choice returns to Shawn: start the "
                            "worker by hand or drop the contract", "launch_blocked")
    if attempts and state.get("last_start_ok") and _age(state.get("launched_at")) < _window():
        raise RegisterError(f"the launch of item {key!r} is still inside its {_window():g}s registration window",
                            "within_window")


def _mark_blocked(run_id, home, key) -> None:
    def change(rec):
        programme = rec["programme"] = programme_home.normalize_programme(rec.get("programme") or {})
        state = programme["items"][key].get(ITEM_KEY)
        if state and state.get("state") != BLOCKED:
            state["state"] = BLOCKED
            programme["items"][key]["history"].append({"at": run_record_core.now_iso(), "kind": "launch_blocked"})

    programme_authority.write(home, run_id, change)


def plan_start(host, run_id, home, opts, programme, key):
    """The launch plan for a contracted start, or None when the start carries no contract."""
    path, plan = opts.get("contract"), opts.get("plan")
    if not path:
        if plan:
            raise ValueError("--plan goes with --contract")
        return None
    if not plan:
        raise ValueError("--contract needs --plan <the plan the worker runs>")
    plan = programme_sanitize.clean(plan, PLAN_CAP)
    if not plan:
        raise ValueError("--plan needs text")
    with refusals(host):
        state = programme["items"][key].get(ITEM_KEY) or {}
        attempts = int(state.get("attempts") or 0)
        _refuse_relaunch(run_id, home, key, state, attempts)
        sid = driver_session.driving_session_id()
        seed = state.get("contract") or load_contract_file(path, sid or "")
        worker_contract.guard(run_id, None, caller=sid, check_worker=False)
        return {"mode": attempts + 1, "plan": plan, "seed": seed, "attempts": attempts + 1, "sid": sid}


def begin_launch(host, run_id, home, key, start, session_id, extra) -> list:
    """Write the seed and the item's ``launched`` state, then return ``extra`` with the kickoff override."""
    with refusals(host):
        _write_seed(run_id, home, key, start, session_id)
    folder = os.path.join(home, "briefs")
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, f"{key.replace(':', '-').replace('/', '-')}-kickoff-{uuid.uuid4().hex[:8]}.txt")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(kickoff_text(start["mode"], start["plan"], run_id, key))
    return list(extra) + ["--kickoff-file", path]


def _write_seed(run_id, home, key, start, session_id) -> None:
    def change(rec):
        worker_contract.guard(run_id, None, caller=start["sid"], check_worker=False)
        programme = rec["programme"] = programme_home.normalize_programme(rec.get("programme") or {})
        item = programme["items"][key]
        before = item.get(ITEM_KEY) or {}
        if before.get("state") in (BOUND, BLOCKED):
            raise RegisterError(f"item {key!r} is {before['state']}", "already_bound")
        now = run_record_core.now_iso()
        item[ITEM_KEY] = {"state": LAUNCHED, "mode": start["mode"], "attempts": start["attempts"],
                          "session_id": session_id, "contract": start["seed"], "plan": start["plan"],
                          "launched_at": now, "last_start_ok": None, "run_id": None, "path": None,
                          "bound_at": None}
        item["history"].append({"at": now, "kind": "run_launching", "mode": start["mode"], "session_id": session_id})

    programme_authority.write(home, run_id, change)


def after_launch(inner, key, start):
    def assign(programme, op):
        done = inner(programme, op)
        item = programme["items"][programme_record._resolve(programme, key)]
        state = item.get(ITEM_KEY)
        if not state or state.get("session_id") != (op.get("target") or {}).get("session_id"):
            return done
        entry = item["starts"][-1]
        entry["mode"] = start["mode"]
        state["last_start_ok"] = bool(entry.get("ok"))
        if not state["last_start_ok"] and state["attempts"] >= MAX_MODES:
            state["state"] = BLOCKED
            item["history"].append({"at": run_record_core.now_iso(), "kind": "launch_blocked"})
        return done
    return assign


def _expected_owner(item) -> str:
    state = item.get(ITEM_KEY) or {}
    owner = (item.get("owner") or {}).get("session_id")
    pending = state.get("session_id")
    if owner and pending and owner != pending:
        raise RegisterError(f"a newer launch ({pending}) replaced the item's owner session {owner}", "not_owner")
    if not (owner or pending):
        raise RegisterError("the item has no owner session to register a run for", "no_owner")
    return owner or pending


def _in_remit(programme, repo) -> bool:
    real = os.path.realpath(repo)
    roots = {os.path.realpath(e["path"]) for e in (programme.get("remit") or {}).get("repos") or []
             if isinstance(e, dict) and isinstance(e.get("path"), str)}
    if any(real == r or real.startswith(r + os.sep) for r in roots):
        return True
    host_repo = resolve_host_repo_root(cwd=real) if os.path.isdir(real) else None
    return bool(host_repo) and os.path.realpath(host_repo) in roots


def _programme_refusals(programme, key, caller, auto_run, repo) -> None:
    item = programme["items"][key]
    state = item.get(ITEM_KEY) or {}
    if state.get("state") == BOUND:
        raise RegisterError(f"item {key!r} already has a bound run ({state.get('run_id')}); one item is one run",
                            "already_bound")
    if state.get("state") == BLOCKED:
        raise RegisterError(f"item {key!r} is launch-blocked; the choice returned to Shawn", "launch_blocked")
    owner = _expected_owner(item)
    if caller != owner:
        raise RegisterError(f"session {caller} is not the item's owner session {owner}; only the owner registers "
                            "its run", "not_owner")
    if not _in_remit(programme, repo):
        raise RegisterError(f"run record path {repo} is outside the programme's remit repos", "outside_remit")
    for other_key, other in programme["items"].items():
        theirs = other.get(ITEM_KEY) or {}
        if other_key != key and theirs.get("state") == BOUND and theirs.get("run_id") == auto_run:
            raise RegisterError(f"run {auto_run} is already bound to item {other_key}", "bound_elsewhere")


def _record_refusals(programme, key, repo, auto_run) -> dict:
    try:
        record = run_record_core.read_run_record(repo, auto_run)
    except run_record_core.RunRecordError as exc:
        raise RegisterError(f"no run record {auto_run!r} under {repo}: {exc}", "no_record") from None
    owner = _expected_owner(programme["items"][key])
    if record.get("driving_session_id") != owner:
        raise RegisterError(f"run record session {record.get('driving_session_id')} is not the item's owner "
                            f"session {owner}", "session_mismatch")
    if (programme["items"][key].get(ITEM_KEY) or {}).get("contract"):
        worker_contract.require_capable(record, RegisterError)
    return record


def _copy_seed(repo, auto_run, seed) -> bool:
    def mutate(rec):
        worker_contract.require_capable(rec, RegisterError)
        have = rec.get("contract")
        if isinstance(have, dict) and have.get("version", 0) >= seed["version"]:
            return False
        rec["contract"] = worker_contract.validate(seed)
        return True

    return run_record_core._with_locked_run_record(repo, auto_run, mutate)


def _bind(run_id, home, key, caller, auto_run, repo) -> dict:
    def change(rec):
        programme = rec["programme"] = programme_home.normalize_programme(rec.get("programme") or {})
        _programme_refusals(programme, key, caller, auto_run, repo)
        item = programme["items"][key]
        now = run_record_core.now_iso()
        item[ITEM_KEY] = dict(item.get(ITEM_KEY) or {"contract": None}, state=BOUND, run_id=auto_run, path=repo,
                              bound_at=now, session_id=caller)
        item["history"].append({"at": now, "kind": "run_bound", "run": auto_run, "path": repo})
        return {"item": key, "state": BOUND, "auto_run": auto_run, "path": repo}

    return programme_authority.write(home, run_id, change)["result"]


def _register(host, argv):
    positional, opts = host._parse(argv, values=("run", "item", "auto-run", "repo"))
    if positional or not all(opts.get(f) for f in ("run", "item", "auto-run", "repo")):
        raise ValueError("usage: register-run --run <programme run> --item <id> --auto-run <run id> "
                         "--repo <repo path that holds the run record>")
    caller = driver_session.driving_session_id()
    if not caller:
        raise RegisterError("CLAUDE_CODE_SESSION_ID is unset; run this from the worker's Claude session",
                            "no_session")
    auto_run = programme_sanitize.token(opts["auto-run"])
    repo = os.path.realpath(opts["repo"])
    run_id, home, record = host._locate(opts)
    programme = programme_home.normalize_programme(record.get("programme") or {})
    key = programme_record._resolve(programme, programme_record.check_item_id(opts["item"]))
    _programme_refusals(programme, key, caller, auto_run, repo)
    run = _record_refusals(programme, key, repo, auto_run)
    seed = (programme["items"][key].get(ITEM_KEY) or {}).get("contract")
    copied = _copy_seed(repo, auto_run, seed) if seed else False
    out = _bind(run_id, home, key, caller, auto_run, repo)
    host.refresh_view(run_id, home)
    host._emit(dict(out, ok=True, run=run_id, kind="run_registered", contract_copied=copied,
                    contract_version=(seed or {}).get("version"), run_session=run.get("driving_session_id")))
    return 0


def _h_register_run(host, argv):
    with refusals(host):
        return _register(host, argv)


_SPECS = (
    ("register-run", _h_register_run,
     "--run <programme run> --item <id> --auto-run <run id> --repo <repo path>",
     "any caller but the item's owner session; a run record whose own session is not the owner; a path outside "
     "the remit's repos; a run already bound to another item; an item that already has a bound run; a run "
     "that predates contracts when the item holds a contract. Copies the item's contract into the run "
     "record, then marks the item bound."),
)


def build_verbs(host) -> dict:
    return {name: host._Verb(functools.partial(handler, host), args, rejects=rejects)
            for name, handler, args, rejects in _SPECS}
