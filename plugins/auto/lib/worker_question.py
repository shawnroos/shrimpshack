#!/usr/bin/env python3
"""Question routing for a programme worker run.

The AskUserQuestion hook calls ``route``. A worker whose run record carries a contract has its
question classified, clamped against the effective authority, and sent to the advisor, the PM or
Shawn. PM and Shawn routes are written as a typed ``worker_question`` row in the claims channel, so
the PM's inbox and unread-claim wake see it. The PM sweep reads ``open_questions``, calls
``escalate_due`` and returns an answer with ``answer``, which lands in the worker's contract as a
pending entry.
"""

from __future__ import annotations

import hashlib
import os
import re
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

run_record_core = load_lib_module("run_record_core")
programme_home = load_lib_module("programme_home")
programme_journal = load_lib_module("programme_journal")
programme_sanitize = load_lib_module("programme_sanitize")
programme_decisions = load_lib_module("programme_decisions")
worker_contract = load_lib_module("worker_contract")

QUESTION_KIND = "worker_question"
ANSWERED_KIND = "worker_question_answered"
ESCALATED_KIND = "worker_question_escalated"
ADVISOR, PM, SHAWN = "advisor", "pm", "shawn"
LIMIT_SECONDS = 30 * 60
TEXT_CAP = 400
OPTION_CAP = 80
OPTIONS_MAX = 4
ANSWER_CAP = 800
LABEL_RE = re.compile(r"\[decision:\s*([a-z_]+)\s*\]", re.I)
_ESCALATION_KIND = "worker_coordination"

_RULES = (
    ("prod_deploy", r"\b(deploy|ship|push|roll ?out)\b.{0,40}\b(prod|production)\b|\bprod(uction)? deploy"),
    ("full_release", r"\bfull release\b|\brelease to (all|everyone)\b|\b(cut|publish) (a |the )?(stable|ga) release\b"),
    ("spend_over_cap", r"\b(spend|budget|over the cap)\b|\$\s?\d"),
    ("merge_around_gate", r"\b(skip|bypass|override|ignore)\b.{0,30}\b(ci|checks?|review|gate|approval)\b"
                          r"|\bmerge (without|anyway)\b|\badmin merge\b"),
    ("denied_operation", r"\bforce[- ]push\b|--force\b|\brm -rf\b|\bdrop (table|database)\b|\breset --hard\b"
                         r"|\bdelete (the )?(branch|database|repo)"),
    ("product_scope", r"\bscope\b|\balso (add|include|support|build)\b|\bshould (we|it) (also )?(include|support|add)\b"),
    ("product_call", r"\b(ux|user experience|wording)\b|\bproduct (call|decision|behaviou?r)\b|\bwhat should the user\b"),
    ("acceptance", r"\bacceptance\b|\bdone when\b|\bgood enough\b|\bdefinition of done\b"),
    ("technical_approach", r"\b(approach|architecture|refactor|implementation|design pattern|data model|schema)\b"
                           r"|\bwhich (library|framework|pattern)\b"),
    ("tool_choice", r"\bwhich (tool|cli|command)\b|\btool choice\b"),
    ("work_sequencing", r"\b(sequence|first or|before or after|what next)\b|\bwhich (first|next)\b|\bin what order\b"),
    ("worker_coordination", r"\b(other worker|another worker|coordinate with)\b"),
    ("optimisation_depth", r"\b(optimi[sz]e|optimi[sz]ation|how deep|polish)\b"),
)
_COMPILED = tuple((kind, re.compile(pattern, re.I | re.S)) for kind, pattern in _RULES)


class QuestionError(worker_contract.ContractError):
    pass


def _flat(value, cap) -> str:
    return programme_journal.redact(programme_sanitize.clean(value, cap=cap))


def read_input(tool_input) -> dict:
    """The question text, option labels and the worker's own kind label from an AskUserQuestion input."""
    parts, options = [], []
    label = tool_input.get("decision_kind") if isinstance(tool_input, dict) else None
    questions = tool_input.get("questions") if isinstance(tool_input, dict) else None
    for q in questions if isinstance(questions, list) else []:
        if not isinstance(q, dict):
            continue
        parts += [str(q.get("header") or ""), str(q.get("question") or "")]
        for opt in q.get("options") or []:
            if isinstance(opt, dict):
                parts.append(str(opt.get("label") or "") + " " + str(opt.get("description") or ""))
                options.append(_flat(opt.get("label"), OPTION_CAP))
    raw = " ".join(p for p in parts if p)
    found = LABEL_RE.search(raw)
    if label is None and found:
        label = found.group(1).lower()
    return {"raw": raw, "text": _flat(LABEL_RE.sub("", raw), TEXT_CAP),
            "options": [o for o in options if o][:OPTIONS_MAX],
            "label": label if isinstance(label, str) and label in programme_decisions.DECISION_KINDS else None}


def classify(raw) -> dict:
    """Deterministic kind from the question text. A protected match wins; two non-protected matches read as unknown."""
    matched = [kind for kind, pattern in _COMPILED if pattern.search(raw or "")]
    protected = [k for k in matched if k in programme_decisions.PROTECTED_KINDS]
    if protected:
        return {"kind": protected[0], "matched": matched}
    if len(matched) == 1:
        return {"kind": matched[0], "matched": matched}
    return {"kind": None, "matched": matched}


def locate_programme(contract, session_id):
    run_ids = [lease.get("run") for lease in programme_home.leases_for_session(contract.get("set_by"))]
    run_ids += [lease.get("run") for _key, lease in programme_home.iter_leases()
                if lease and not lease.get("corrupt")]
    for run_id in dict.fromkeys(r for r in run_ids if isinstance(r, str) and r):
        try:
            record = run_record_core.read_run_record(programme_home.home_path(run_id), run_id)
        except (run_record_core.RunRecordError, programme_home.ProgrammeHomeError, OSError):
            continue
        for key, item in ((record.get("programme") or {}).get("items") or {}).items():
            if session_id in programme_home.session_ids(item):
                return run_id, record, key
    return None


def _authority_for(contract, kind, programme, item_key, now):
    inputs = worker_contract.programme_inputs(programme, item_key, now=now)
    return worker_contract.effective_authority(contract, kind, **inputs)


def decide(contract, programme, item_key, parsed, now=None) -> dict:
    """Pick the route. The worker's label only ever adds restriction to what the classifier found."""
    found = classify(parsed["raw"])
    kinds = [k for k in (found["kind"], parsed["label"]) if k]
    entries = [_authority_for(contract, k, programme, item_key, now) for k in kinds]
    protected = any(e["reason"] == "protected" for e in entries)
    to_shawn = any(e["mode"] in ("propose", "never") and e["asks"] == "shawn" for e in entries)
    confirmed = found["kind"] is not None and all(e["mode"] in ("act", "act_and_tell") for e in entries)
    if confirmed:
        route = ADVISOR
    else:
        route = SHAWN if to_shawn else PM
    worst = min(entries, key=lambda e: programme_decisions.LEVEL_ORDER.index(e["mode"]), default=None)
    reversible = (route == PM and found["kind"] is not None and
                  all(e["mode"] == "propose" and e["asks"] == "pm" for e in entries))
    return {"route": route, "kind": found["kind"], "label": parsed["label"], "mode": worst["mode"] if worst else None,
            "asks": worst["asks"] if worst else PM, "safe_default": reversible,
            "reason": "protected" if protected else ("unknown kind" if found["kind"] is None else
                                                     (worst or {}).get("reason", "authority"))}


def guidance(route, qid, safe_default) -> str:
    head = ("auto: this is a programme worker run. Do NOT ask the operator and do NOT consult the advisor for this "
            f"question. It is recorded as question {qid} for the {'PM' if route == PM else 'PM, who raises it to Shawn'}.")
    park = (" Park only the step that depends on the answer, and keep running steps that do not. The answer "
            "arrives in your contract at the next pulse.")
    if safe_default:
        park = (" You may take a reversible safe default for the dependent step now and say so in the step's "
                "verdict; the PM can override it. Steps that do not depend on the answer keep running."
                " The answer arrives in your contract at the next pulse.")
    return head + park


def _base_id(run_id, item_key, text) -> str:
    return hashlib.sha256(f"{run_id}\n{item_key}\n{text.lower()}".encode()).hexdigest()[:10]


def _rows(programme_run) -> tuple:
    asked = [r for r in programme_journal.claims(programme_run) if r.get("kind") == QUESTION_KIND]
    journal = programme_journal.read(programme_run)
    answered = {(r.get("payload") or {}).get("qid") for r in journal if r.get("kind") == ANSWERED_KIND}
    escalated = {(r.get("payload") or {}).get("qid") for r in journal if r.get("kind") == ESCALATED_KIND}
    return asked, answered, escalated


def _qid_for(asked, answered, base) -> tuple:
    same = [r for r in asked if (r.get("payload") or {}).get("base") == base]
    closed = [r for r in same if (r.get("payload") or {}).get("qid") in answered]
    if len(same) > len(closed):
        return (same[-1].get("payload") or {}).get("qid"), True
    suffix = f"-{len(closed)}" if closed else ""
    return "q" + base + suffix, False


def record_question(programme_run, item_key, worker, parsed, decision, now=None) -> dict:
    asked, answered, _ = _rows(programme_run)
    base = _base_id(worker["run_id"], item_key, parsed["text"])
    qid, existing = _qid_for(asked, answered, base)
    if not existing:
        payload = {"qid": qid, "base": base, "item": item_key, "worker_session": worker["session_id"],
                   "worker_run": worker["run_id"], "repo": worker["repo"], "route": decision["route"],
                   "kind": decision["kind"], "label": decision["label"], "mode": decision["mode"],
                   "asks": decision["asks"], "safe_default": decision["safe_default"],
                   "text": parsed["text"], "options": parsed["options"], "reason": decision["reason"]}
        row = programme_journal.entry(QUESTION_KIND, worker["session_id"], payload, now=now)
        programme_journal.append_row(programme_run, row, channel="claims", provenance="worker_result",
                                     guard=programme_journal._refuse_after_end)
    return {"qid": qid, "new": not existing}


def route(contract, *, repo_root, run_id, session_id, tool_input, now=None):
    """The routing result for a contracted worker's question, or None when it cannot be routed (fail open)."""
    located = locate_programme(contract, session_id)
    if located is None:
        return None
    programme_run, record, item_key = located
    parsed = read_input(tool_input)
    decision = decide(contract, record.get("programme") or {}, item_key, parsed, now)
    if decision["route"] == ADVISOR:
        return decision
    worker = {"run_id": run_id, "session_id": session_id, "repo": os.path.abspath(repo_root)}
    made = record_question(programme_run, item_key, worker, parsed, decision, now)
    return dict(decision, qid=made["qid"], programme_run=programme_run,
                guidance=guidance(decision["route"], made["qid"], decision["safe_default"]))


def _age(row, now) -> float:
    when = run_record_core.parse_iso(row.get("at"))
    return max((now - when).total_seconds(), 0.0) if when else 0.0


def open_questions(programme_run, *, now=None, limit=LIMIT_SECONDS) -> list:
    stamp = run_record_core.parse_iso(now) if isinstance(now, str) else now
    stamp = stamp or run_record_core.parse_iso(run_record_core.now_iso())
    asked, answered, escalated = _rows(programme_run)
    out = []
    for row in asked:
        p = row.get("payload") or {}
        if p.get("qid") in answered:
            continue
        age = _age(row, stamp)
        out.append({"qid": p.get("qid"), "item": p.get("item"), "route": p.get("route"), "kind": p.get("kind"),
                    "mode": p.get("mode"), "asks": p.get("asks"), "safe_default": bool(p.get("safe_default")),
                    "at": row.get("at"), "age_seconds": int(age), "past_limit": age > limit,
                    "escalated": p.get("qid") in escalated,
                    "text": programme_sanitize.wrap(p.get("text"), cap=TEXT_CAP),
                    "options": [programme_sanitize.wrap(o, cap=OPTION_CAP) for o in p.get("options") or []]})
    return out


def due(question) -> bool:
    return not question["escalated"] and (question["route"] == SHAWN or question["past_limit"])


def _hand_via_programme(programme_run, question, row_text) -> None:
    kind = question["kind"] if question["kind"] in programme_decisions.DECISION_KINDS else _ESCALATION_KIND
    worker_contract.hand_item(programme_run, question["item"], kind=kind, question="Worker question: " + row_text,
                              if_nothing="the worker parks the step that depends on this answer")


def _plain_text(programme_run, qid) -> str:
    for row in programme_journal.claims(programme_run):
        p = row.get("payload") or {}
        if row.get("kind") == QUESTION_KIND and p.get("qid") == qid:
            return p.get("text") or ""
    return ""


def _require_driver(programme_run, caller):
    sid = caller or load_lib_module("driver_session").driving_session_id()
    record = run_record_core.read_run_record(programme_home.home_path(programme_run), programme_run)
    if not sid or not load_lib_module("session_registry").caller_drives(record, sid):
        raise QuestionError("only the programme's driving session may escalate or answer a worker question",
                            "not_driving")
    return sid, record


def escalate_due(programme_run, *, now=None, limit=LIMIT_SECONDS, hand=None, caller=None) -> list:
    """Raise one Shawn ask for each due question. The escalated row makes a second call a no-op."""
    sid, record = _require_driver(programme_run, caller)
    items = (record.get("programme") or {}).get("items") or {}
    done = []
    for question in open_questions(programme_run, now=now, limit=limit):
        if not due(question):
            continue
        item = items.get(question["item"]) or {}
        joined = programme_decisions.waits_on_shawn(item)
        if not joined:
            (hand or _hand_via_programme)(programme_run, question, _plain_text(programme_run, question["qid"]))
        programme_journal.append(programme_run, ESCALATED_KIND, sid,
                                 {"qid": question["qid"], "item": question["item"], "joined": joined})
        done.append(question["qid"])
    return done


def pending_answers(block) -> list:
    applied = block.get("applied_version", 0)
    return [{"question_id": e["answer"]["question_id"], "text": e["answer"]["text"], "version": e["version"],
             "applied": e["version"] <= applied}
            for e in block.get("pending_versions") or [] if isinstance(e.get("answer"), dict)]


def answer(programme_run, qid, text, *, caller=None, space_of=None, now=None) -> dict:
    """Return the PM's answer to the worker as a pending contract entry and journal it as a PM answer."""
    clean = programme_sanitize.clean(text, cap=ANSWER_CAP, keep_newlines=True)
    if not clean:
        raise QuestionError("an answer needs text", "empty_answer")
    asked, answered, _ = _rows(programme_run)
    row = next((r for r in asked if (r.get("payload") or {}).get("qid") == qid), None)
    if row is None:
        raise QuestionError(f"no worker question {qid!r} in this programme", "unknown_question")
    if qid in answered:
        raise QuestionError(f"worker question {qid!r} was already answered", "already_answered")
    p = row["payload"]
    worker_contract.guard(programme_run, p["worker_session"], caller=caller, space_of=space_of)
    sid = caller or load_lib_module("driver_session").driving_session_id()
    landed = {}

    def mutate(rec):
        block = worker_contract.contract_of(rec)
        if block is None:
            raise QuestionError("the worker's run record has no contract to carry the answer", "no_contract")
        worker_contract.guard(programme_run, p["worker_session"], caller=caller, space_of=space_of)
        held = [e for e in block.get("pending_versions") or []
                if isinstance(e.get("answer"), dict) and e["answer"].get("question_id") == qid]
        if held:
            landed["version"] = held[0]["version"]
            return
        entry = worker_contract.append_pending(block, bite="pulse", set_by=sid, now=now,
                               extra={"answer": {"question_id": qid, "text": clean, "by": "pm"}})
        worker_contract.validate(block)
        landed["version"] = entry["version"]

    run_record_core._with_locked_run_record(p["repo"], p["worker_run"], mutate)
    programme_journal.append(programme_run, ANSWERED_KIND, sid,
                             {"qid": qid, "item": p["item"], "by": "pm", "version": landed["version"],
                              "answer_id": "a" + qid[1:]})
    return {"qid": qid, "version": landed["version"], "bite": "pulse"}
