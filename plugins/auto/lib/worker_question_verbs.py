#!/usr/bin/env python3
"""The PM's verbs over a programme worker's open questions: list them, escalate the overdue ones, answer one.

Thin wrappers over ``worker_question``; the driving-session checks live there. ``programme.py`` registers
them through ``build_verbs(host)``.
"""

from __future__ import annotations

import functools
import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

worker_question = load_lib_module("worker_question")
worker_contract = load_lib_module("worker_contract")

OPEN_KIND = "worker_questions"
ESCALATED_KIND = "worker_questions_escalated"
ANSWER_KIND = "worker_question_answer"


_refusals = worker_contract.refusals


def _limit(opts) -> int:
    return int(opts["limit"]) if opts.get("limit") else worker_question.LIMIT_SECONDS


def _parsed(host, argv, values):
    positional, opts = host._parse(argv, values=values)
    if positional:
        raise ValueError(f"{argv[0]} takes only options, got {positional}")
    run_id, home, _record = host._locate(opts)
    return run_id, home, opts


def _h_open(host, argv):
    run_id, _home, opts = _parsed(host, argv, ("run", "limit"))
    host._emit({"ok": True, "run": run_id, "kind": OPEN_KIND,
                "questions": worker_question.open_questions(run_id, limit=_limit(opts))})
    return 0


def _h_escalate(host, argv):
    run_id, home, opts = _parsed(host, argv, ("run", "limit"))
    with _refusals(host):
        done = worker_question.escalate_due(run_id, limit=_limit(opts))
    host.refresh_view(run_id, home)
    host._emit({"ok": True, "run": run_id, "kind": ESCALATED_KIND, "escalated": done})
    return 0


def _h_answer(host, argv):
    run_id, home, opts = _parsed(host, argv, ("run", "question", "text"))
    if not opts.get("question") or not opts.get("text"):
        raise ValueError("usage: answer-worker-question --question <qid> --text <answer> [--run <programme run>]")
    with _refusals(host):
        landed = worker_question.answer(run_id, opts["question"], opts["text"])
    host.refresh_view(run_id, home)
    host._emit(dict(landed, ok=True, run=run_id, kind=ANSWER_KIND))
    return 0


_SPECS = (
    ("open-worker-questions", _h_open, "[--run <programme run>] [--limit <seconds>]", None),
    ("escalate-worker-questions", _h_escalate, "[--run <programme run>] [--limit <seconds>]",
     "any caller but the programme's driving session. Raises one Shawn ask for each open question that is routed "
     "to Shawn or past the limit; a second call raises none."),
    ("answer-worker-question", _h_answer, "--question <qid> --text <answer> [--run <programme run>]",
     "any caller but the programme's driving session that holds its lease; an unknown or already answered "
     "question; a worker whose run record has no contract. The answer lands in the worker's contract as a "
     "pending entry that bites at the next pulse; it is a PM answer, never a Shawn approval."),
)


def build_verbs(host) -> dict:
    return {name: host._Verb(functools.partial(handler, host), args, rejects=rejects, reads=name == "open-worker-questions")
            for name, handler, args, rejects in _SPECS}
