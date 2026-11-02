#!/usr/bin/env python3
"""The engine's side of a worker's PM-set contract: bite points, applied version, wave clamp.

The PM's write verb appends ``{version, bite}`` entries to the contract's ``pending_versions``. The
engine alone removes them and writes ``applied_version``: at pulse start for bite ``pulse``, and at
each wave (``dispatch_batch``) and each ``build_dispatch_prompt`` for bite ``step``. The applied
version never passes a still-pending entry, so the PM reads "landed" only when everything up to it
has bitten. A record with no ``contract`` key is never read past that check and never written.
"""

from __future__ import annotations

import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

run_record_core = load_lib_module("run_record_core")

PULSE_BITES = ("pulse",)
STEP_BITES = ("step",)


def _block(record):
    block = record.get("contract") if isinstance(record, dict) else None
    return block if isinstance(block, dict) else None


def _settle(block, bites, keep_answers=False) -> bool:
    pending = block.get("pending_versions") or []
    keep = [e for e in pending if e.get("bite") not in bites or (keep_answers and "answer" in e)]
    version = block["version"]
    target = version if not keep else min(version, min(e["version"] for e in keep) - 1)
    applied = max(block.get("applied_version", 0), target)
    if len(keep) == len(pending) and applied == block.get("applied_version", 0):
        return False
    block["pending_versions"] = keep
    block["applied_version"] = applied
    return True


def apply_bites(repo_root, run_id, bites, record=None, keep_answers=False) -> dict:
    """Apply the pending entries that bite at ``bites``; return the record as it now stands."""
    record = record if record is not None else run_record_core.read_run_record(repo_root, run_id)
    block = _block(record)
    if block is None or not _settle(dict(block), bites, keep_answers):
        return record

    def mutate(rec):
        live = _block(rec)
        if live is not None:
            _settle(live, bites, keep_answers)

    run_record_core._with_locked_run_record(repo_root, run_id, mutate)
    return run_record_core.read_run_record(repo_root, run_id)


def apply_at_pulse(repo_root, run_id, record=None) -> dict:
    # A PM answer stays pending until deliver_answers: the pulse may return before any intent carries its text.
    return apply_bites(repo_root, run_id, PULSE_BITES, record, keep_answers=True)


def deliver_answers(repo_root, run_id, versions) -> None:
    """Retire the answer entries whose text the pulse's intent just carried; an answer queued since stays pending."""
    if not versions:
        return

    def mutate(rec):
        live = _block(rec)
        if live is None:
            return
        live["pending_versions"] = [e for e in live.get("pending_versions") or []
                                    if not ("answer" in e and e["version"] in versions)]
        _settle(live, PULSE_BITES, keep_answers=True)

    run_record_core._with_locked_run_record(repo_root, run_id, mutate)


def _step_record(repo_root, run_id) -> dict:
    record = apply_bites(repo_root, run_id, STEP_BITES)
    if _block(record) is None:
        return record
    return load_lib_module("worker_rebake").complete_due(repo_root, run_id, record)


def clamp_wave_with_record(repo_root, run_id, cap) -> tuple:
    record = _step_record(repo_root, run_id)
    block = _block(record)
    if block is None:
        return cap, record
    ceiling = block.get("fan_out_cap")
    return (min(cap, ceiling) if isinstance(ceiling, int) and not isinstance(ceiling, bool) else cap), record


def clamp_wave(repo_root, run_id, cap) -> int:
    return clamp_wave_with_record(repo_root, run_id, cap)[0]


def _names(label, names) -> str:
    return f"{label} {', '.join(names) if names else 'none'}"


def guidance(block, effective=None, answers=None) -> str:
    """The contract text the worker reads; ``effective`` (kind -> verdict) replaces the stored modes."""
    done = block.get("done_bar") or {}
    lines = [
        f"PM CONTRACT v{block.get('version')} (applied v{block.get('applied_version', 0)}): "
        f"workflow {block.get('workflow')}; fan-out cap {block.get('fan_out_cap')} subagents per wave.",
        "Done bar: " + _names("internal", done.get("internal")) + "; " + _names("external", done.get("external")) + ".",
    ]
    authority = effective if effective is not None else block.get("authority") or {}
    label = "Effective authority" if effective is not None else "Authority"
    if authority:
        lines.append(f"{label}: " + "; ".join(f"{kind}={entry['mode']} (asks {entry['asks']})"
                                              for kind, entry in sorted(authority.items())) + ".")
    lines.append("Decision kinds not listed follow the programme's Authority table. "
                 "Work to this contract; ask the named asker for any `propose` or `never` decision.")
    lines += [f"PM answer to question {a['question_id']}: {a['text']}" for a in answers or []]
    return "\n".join(lines)


def append_guidance(text, record, effective=None, answers=None):
    block = _block(record)
    if block is None:
        return text
    body = guidance(block, effective, answers)
    return f"{text}\n\n{body}" if text else body


def step_section(repo_root, run_id) -> str:
    block = _block(_step_record(repo_root, run_id))
    return "" if block is None else guidance(block)
