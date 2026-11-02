#!/usr/bin/env python3
"""The PM's read of a contracted Auto-run worker: ``contract-status`` and the quiet-sweep inputs (R11, R12, R13).

Status reads the worker's run record from the item's ``auto_run`` block and never scrapes a pane. The exit
predicate is the cached ``exit_predicate_result``, never recomputed. An item counts as done only when that
cached predicate is met and every external evidence kind of the done bar is confirmed by the PM's own
deliverable checker: the worker's record can claim, but it never proves.
"""

from __future__ import annotations

import functools
import json
import os
import sys
import tempfile

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

run_record_core = load_lib_module("run_record_core")
programme_home = load_lib_module("programme_home")
programme_record = load_lib_module("programme_record")
worker_contract = load_lib_module("worker_contract")
worker_question = load_lib_module("worker_question")
worker_register = load_lib_module("worker_register")
phase_grammar = load_lib_module("phase-grammar")

CONTRACT, NO_CONTRACT, UNRESOLVABLE, LAUNCHED = "contract", "no contract", "unresolvable", "launched"
SEEN_NAME = "contract-seen.json"
EVIDENCE_DELIVERABLE = {"pr_merged": "merged", "ci_green": "merged"}


def bound_run(item):
    state = item.get(worker_register.ITEM_KEY) or {}
    if state.get("state") == worker_register.BOUND and state.get("run_id") and state.get("path"):
        return state["run_id"], state["path"]
    return None


def _read(path, run_id):
    try:
        return run_record_core.read_run_record(path, run_id), None
    except (run_record_core.RunRecordError, OSError, ValueError) as exc:
        return None, f"{type(exc).__name__}: {exc}"


def _mtime(path, run_id):
    try:
        return os.stat(run_record_core.run_record_path(path, run_id)).st_mtime_ns
    except OSError:
        return None


def unverified_external(item, block) -> list:
    deliverables = item.get("deliverables") or {}
    wanted = (block.get("done_bar") or {}).get("external") or []
    return [kind for kind in wanted
            if (deliverables.get(EVIDENCE_DELIVERABLE.get(kind, kind)) or {}).get("result") != "confirmed"]


def _steps(record) -> dict:
    by_state = {}
    for step in record.get("steps") or []:
        state = step.get("state") if isinstance(step, dict) else None
        by_state[str(state)] = by_state.get(str(state), 0) + 1
    return {"total": sum(by_state.values()), "by_state": by_state}


def _questions(rows) -> dict:
    oldest = min(rows, key=lambda q: q["at"] or "", default=None)
    return {"open": len(rows), "oldest_at": oldest and oldest["at"],
            "oldest_age_seconds": max((q["age_seconds"] for q in rows), default=None),
            "past_limit": any(q["past_limit"] for q in rows), "due": [q["qid"] for q in rows if is_due(q)]}


def is_due(question) -> bool:
    return not question["escalated"] and (question["route"] == worker_question.SHAWN or question["past_limit"])


def _pending(block) -> list:
    out = []
    for entry in block.get("pending_versions") or []:
        row = {"version": entry["version"], "bite": entry["bite"]}
        if isinstance(entry.get("answer"), dict):
            row["question_id"] = entry["answer"].get("question_id")
        out.append(row)
    return out


def _done(cached, missing) -> dict:
    blocked = ([] if cached.get("met") is True else ["exit_predicate_not_met"])
    blocked += ["external_evidence_unverified"] if missing else []
    return {"counts_as_done": not blocked, "done_blocked_by": blocked}


def item_status(key, item, questions) -> dict:
    """The read for one item; ``questions`` are the programme's open worker questions for that item."""
    bound = bound_run(item)
    state = item.get(worker_register.ITEM_KEY) or {}
    if bound is None:
        seed = state.get("contract") if state.get("state") == worker_register.LAUNCHED else None
        if seed:
            return {"item": key, "state": LAUNCHED, "version": seed.get("version"), "counts_as_done": False}
        return {"item": key, "state": NO_CONTRACT, "counts_as_done": False}
    run_id, path = bound
    record, why = _read(path, run_id)
    block = None
    if record is not None:
        try:
            block = worker_contract.contract_of(record)
        except worker_contract.ContractError as exc:
            record, why = None, str(exc)
    if record is None:
        return {"item": key, "state": UNRESOLVABLE, "run_id": run_id, "path": path, "why": why,
                "counts_as_done": False}
    if block is None:
        return {"item": key, "state": NO_CONTRACT, "run_id": run_id, "counts_as_done": False}
    cached = record.get("exit_predicate_result") or {}
    missing = unverified_external(item, block)
    return dict({
        "item": key, "state": CONTRACT, "run_id": run_id, "path": path, "version": block["version"],
        "applied_version": block.get("applied_version", 0), "stale": worker_contract.is_stale(block),
        "pending_versions": _pending(block), "steps": _steps(record), "exit_predicate": cached,
        "last_beat_at": (record.get("loop") or {}).get("last_beat_at"),
        phase_grammar.LOOP_PHASE_KEY: (record.get("loop") or {}).get(phase_grammar.LOOP_PHASE_KEY), "mtime_ns": _mtime(path, run_id),
        "unverified_external": missing, "questions": _questions(questions),
    }, **_done(cached, missing))


def read_all(programme_run, programme, keys=None, now=None) -> dict:
    items = programme.get("items") or {}
    wanted = sorted(items) if keys is None else keys
    by_item = {}
    for question in worker_question.open_questions(programme_run, now=now):
        by_item.setdefault(question["item"], []).append(question)
    return {key: item_status(key, items[key], by_item.get(key, [])) for key in wanted}


def fingerprint(status) -> dict:
    if status["state"] != CONTRACT:
        return {"state": status["state"]}
    asked = status["questions"]
    return {"state": CONTRACT, "version": status["version"], "last_beat_at": status["last_beat_at"],
            "mtime_ns": status["mtime_ns"], "open": asked["open"], "oldest_at": asked["oldest_at"]}


def _load_seen(home) -> dict:
    try:
        with open(os.path.join(home, SEEN_NAME), encoding="utf-8") as fh:
            doc = json.load(fh)
        return doc if isinstance(doc, dict) else {}
    except (OSError, ValueError):
        return {}


def commit_seen(home, fingerprints) -> None:
    fd, tmp = tempfile.mkstemp(prefix=SEEN_NAME + ".", dir=home)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(fingerprints, handle, sort_keys=True)
        os.replace(tmp, os.path.join(home, SEEN_NAME))
    except BaseException:
        os.unlink(tmp)
        raise


def _compact(status) -> dict:
    keep = ("item", "state", "version", "applied_version", "stale", "last_beat_at", "unverified_external",
            "counts_as_done", "done_blocked_by", "why")
    out = {k: status[k] for k in keep if k in status}
    if status["state"] == CONTRACT:
        out.update(steps=status["steps"]["by_state"], met=status["exit_predicate"].get("met"),
                   open_questions=status["questions"]["open"])
    return out


def sweep_facts(programme_run, home, programme, now=None) -> dict:
    """What the quiet-sweep verdict needs: which contracted items moved since the last committed look, and due questions."""
    try:
        statuses = {k: s for k, s in read_all(programme_run, programme, now=now).items() if s["state"] != NO_CONTRACT}
    except Exception as exc:  # noqa: BLE001 — one unreadable store must degrade the sweep, never end it
        return {"error": f"{type(exc).__name__}: {exc}", "changed": [], "due": [], "items": {}, "fingerprints": {}}
    prints = {key: fingerprint(s) for key, s in statuses.items()}
    seen = _load_seen(home)
    return {"error": None, "changed": [k for k, fp in prints.items() if seen.get(k) != fp],
            "due": [qid for s in statuses.values() if s["state"] == CONTRACT for qid in s["questions"]["due"]],
            "items": {k: _compact(s) for k, s in statuses.items()}, "fingerprints": prints}


def find_item(repo_root, run_id):
    real = os.path.realpath(repo_root)
    checked = set()
    for _key, lease in programme_home.iter_leases():
        run = (lease or {}).get("run")
        if not lease or lease.get("corrupt") or not isinstance(run, str) or run in checked:
            continue
        checked.add(run)
        record, _why = _read(programme_home.home_path(run), run)
        programme = (record or {}).get("programme") or {}
        for key, item in (programme.get("items") or {}).items():
            state = item.get(worker_register.ITEM_KEY) or {}
            if (state.get("state") == worker_register.BOUND and state.get("run_id") == run_id
                    and os.path.realpath(state.get("path") or "") == real):
                return run, programme, key
    return None


def guidance_extras(repo_root, run_id, record) -> dict:
    """Effective authority and pending PM answers for the pulse's guidance; read before the engine trims applied entries."""
    block = record.get("contract") if isinstance(record, dict) else None
    if not isinstance(block, dict):
        return {}
    out = {"answers": [a for a in worker_question.pending_answers(block) if not a["applied"]]}
    try:
        found = find_item(repo_root, run_id)
        if found:
            _run, programme, key = found
            out["effective"] = worker_contract.effective_map(block, **worker_contract.programme_inputs(programme, key))
    except Exception:  # noqa: BLE001 — a programme that cannot be read leaves the stored modes in the guidance
        pass
    return out


def _h_contract_status(host, argv):
    positional, opts = host._parse(argv, values=("run",))
    if len(positional) > 1:
        raise ValueError("usage: contract-status [<item>] [--run <id>]")
    run_id, _home, record = host._locate(opts)
    programme = programme_home.normalize_programme(record.get("programme") or {})
    if positional:
        keys = [programme_record._resolve(programme, programme_record.check_item_id(positional[0]))]
    else:
        keys = [k for k, item in sorted(programme["items"].items()) if item.get(worker_register.ITEM_KEY)]
    host._emit({"ok": True, "run": run_id, "items": read_all(run_id, programme, keys)})
    return 0


_SPECS = (
    ("contract-status", _h_contract_status, "[<item>] [--run <id>]",
     "nothing; read-only. Reads the worker's run record from the item, never a pane. The exit predicate is the "
     "cached one. Reads 'no contract' for an item without one and 'unresolvable' for a record that is missing "
     "or moved."),
)


def build_verbs(host) -> dict:
    return {name: host._Verb(functools.partial(handler, host), args, reads=True, rejects=rejects)
            for name, handler, args, rejects in _SPECS}
