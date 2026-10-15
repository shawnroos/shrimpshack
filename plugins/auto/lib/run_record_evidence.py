#!/usr/bin/env python3
"""Evidence checks and their journal for ordinary task runs.

A task run's driving session may check a named deliverable. The result goes in
the run's ``task_evidence`` block and in ``.claude/auto/journal/<run>.jsonl``.
Nothing here feeds the exit predicate: a task run finishes exactly as it would
without evidence.
"""
from __future__ import annotations

import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

run_record_core = load_lib_module("run_record_core")
driver_session = load_lib_module("driver_session")

BLOCK = "task_evidence"
JOURNAL_DIR = "journal"
JOURNAL_KIND = "evidence_checked"


def _programme_home():
    return load_lib_module("programme_home")


def _journal():
    return load_lib_module("programme_journal")


def journal_path(repo_root: str, run_id: str) -> str:
    slug = run_record_core._slugify_branch(run_id)
    return os.path.join(repo_root, ".claude", "auto", JOURNAL_DIR, f"{slug}.jsonl")


def read_journal(repo_root: str, run_id: str) -> list:
    return _journal().read_path(journal_path(repo_root, run_id))


def _guard(record, session_id) -> None:
    if run_record_core.run_kind(record) != "task":
        raise run_record_core.RunRecordError(
            "check-deliverable here is for task runs; a programme uses programme.py check-deliverable")
    driving = record.get("driving_session_id")
    if not driving or driving != session_id:
        raise run_record_core.RunRecordError(
            "only the run's driving session may check its deliverables "
            f"(caller {session_id!r}, driving session {driving!r})")


def _ref(value) -> str:
    ref = load_lib_module("programme_sanitize").token(value) if value is not None else None
    if ref is None:
        raise ValueError(f"--ref must be one short word with no spaces: {value!r}")
    return ref


def check_deliverable(repo_root: str, run_id: str, deliverable: str, ref) -> dict:
    if deliverable not in _programme_home().DELIVERABLES:
        raise ValueError(f"deliverable must be one of {list(_programme_home().DELIVERABLES)}")
    ref = _ref(ref)
    session_id = driver_session.driving_session_id()
    if not session_id:
        raise ValueError("check-deliverable needs CLAUDE_CODE_SESSION_ID (the driving session's own id)")
    _guard(run_record_core.read_run_record(repo_root, run_id), session_id)
    slug = run_record_core._slugify_branch(run_id)
    # The checker reads a programme journal keyed by this id for a merge pin; a task
    # run has none, but an id that fails the programme slug check would turn every
    # merged check into unknown, so the slug is passed instead of the raw id.
    verdict = load_lib_module("programme_evidence").run_check(slug, slug, deliverable, ref)

    def mutate(record):
        _guard(record, session_id)
        now = run_record_core.now_iso()
        refs = record.setdefault(BLOCK, {}).setdefault(deliverable, {})
        old = refs.get(ref) or {}
        confirmed_at = None
        if verdict["result"] == "confirmed":
            confirmed_at = old.get("confirmed_at") or now
        refs[ref] = {"result": verdict["result"], "checked_at": now, "confirmed_at": confirmed_at,
                     "fields": verdict.get("fields") or {}, "misses": verdict.get("misses") or [],
                     "note": verdict.get("note")}
        return {"deliverable": deliverable, "ref": ref, "result": verdict["result"],
                "previous": old.get("result"), "fields": refs[ref]["fields"],
                "misses": refs[ref]["misses"], "note": refs[ref]["note"]}

    out = run_record_core._with_locked_run_record(repo_root, run_id, mutate)
    _journal().append_to(journal_path(repo_root, run_id), JOURNAL_KIND, session_id, out)
    return out
