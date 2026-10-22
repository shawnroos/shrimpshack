#!/usr/bin/env python3
"""Restore a programme's context in a new or compacted session, from the committed store.

SessionStart, the compact refusal, `rules`, takeover and handover all print the same
block: the rules in force plus the recovery packet's decisions, requirements, binding
pauses, denials and Rulings, pending questions and holds. An acknowledgement binds to the
context digest the flag recorded; a newer decision context refuses it.
"""

from __future__ import annotations

import hashlib
import json
import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

run_record_core = load_lib_module("run_record_core")
programme_home = load_lib_module("programme_home")
programme_authority = load_lib_module("programme_authority")
programme_recovery = load_lib_module("programme_recovery")

CONTEXT_TAG = "auto-context"
DIGEST_KEYS = ("pending_decisions", "decisions", "requirements", "blockers", "binding", "assignments")
DIGEST_CHARS = 16


class StaleAck(Exception):
    def __init__(self, current):
        super().__init__(current)
        self.current = current


def head(run_id) -> tuple:
    home = programme_home.home_path(run_id)
    if programme_authority.promoted(home, run_id):
        data = programme_authority.head(run_id)
        return data["record"], data["revision"]
    return run_record_core.read_run_record(home, run_id), None


def packet(run_id, record, revision=None) -> dict:
    return programme_recovery.packet(run_id, revision, record, objects=False)


def digest_of(body) -> str | None:
    if "hold" in body:
        return None
    keep = {k: body.get(k) for k in DIGEST_KEYS}
    raw = json.dumps(keep, sort_keys=True, separators=(",", ":"), default=str)
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:DIGEST_CHARS]


def context_digest(run_id, record) -> str | None:
    return digest_of(packet(run_id, record))


def _q(text) -> str:
    return f"\"{text}\"" if text else "none"


def _cut(entry) -> str:
    return f" [cut; recover --get {entry['id']}]" if entry.get("omitted_text") else ""


def _decision_line(d) -> str:
    limits = " | ".join(_q(l.get("text")) + _cut(l) for l in d.get("limits") or []) or "none"
    applies = ", ".join(str(a) for a in d.get("applies_to") or []) or "programme"
    reqs = ", ".join(str(r) for r in d.get("requirements") or [])
    text = (f"{d['id']} {d.get('state')}: scope {_q(d.get('scope'))}; reason {_q(d.get('reason'))}"
            f"{_cut(d)}; limits {limits}; applies to {applies}")
    if reqs:
        text += f"; requirements {reqs}"
    if d.get("superseded_by"):
        text += f"; superseded by revision {d['superseded_by']}"
    return text


def _ruling_line(r) -> str:
    label = r.get("kind") or f"legacy {str(r.get('legacy') or 'record').replace('_', ' ')}"
    applies = ", ".join(str(a) for a in r.get("applies_to") or []) or "programme"
    until = f"; until {r['until']}" if r.get("until") else ""
    return f"binding {r['id']} ({label}, {r.get('effect')}): {_q(r.get('scope'))}{_cut(r)}; applies to {applies}{until}"


def _pending_line(p) -> str:
    if p.get("kind") == "context_pending":
        return f"pending: {p.get('id')} revision {p.get('rev')} waits for Shawn's acceptance"
    if p.get("kind") == "agreement_not_accepted":
        return "pending: the agreement is not accepted"
    return f"pending: handed {p.get('item')} asks {_q(p.get('question'))}"


def context_lines(body) -> list:
    if "hold" in body:
        return [f"context unreadable: {body['hold'].get('outcome')} ({body['hold'].get('detail')})"]
    out = [_decision_line(d) for d in body.get("decisions") or []]
    for r in body.get("requirements") or []:
        out.append(f"{r['id']} {r.get('state')}: {_q(r.get('text'))}{_cut(r)}; checks "
                   + (", ".join(r.get("checks") or []) or "none"))
    for a in body.get("acceptance") or []:
        out.append(f"acceptance {a.get('id')}: {a.get('state')}")
    for b in body.get("blockers") or []:
        out.append(f"blocker {b.get('id')} on {b.get('requirement')}: {b.get('check')} waits on "
                   f"{b.get('dependency')}; unblocks when {_q(b.get('unblock'))}")
    binding = body.get("binding") or {}
    for p in binding.get("pauses") or []:
        out.append(f"binding {p['id']} ({p.get('risk')}): {_q(p.get('reason'))}{_cut(p)}")
    for d in binding.get("denials") or []:
        out.append(f"binding {d['id']}: {d.get('tool')} refused {d.get('action')}"
                   + (f" for {d['item']}" if d.get("item") else "") + f": {_q(d.get('reason'))}{_cut(d)}")
    out += [_ruling_line(r) for r in binding.get("rulings") or []]
    out += [_pending_line(p) for p in body.get("pending_decisions") or []]
    for item_id, binding_rev in sorted((body.get("assignments") or {}).items()):
        out.append(f"assignment {item_id}: decision {binding_rev.get('decision_id')} "
                   f"revision {binding_rev.get('rev')}")
    actions = body.get("actions") or []
    if actions:
        out.append("open items: " + "; ".join(f"{a['id']} {a.get('state')} {_q(a.get('title'))}{_cut(a)}"
                                             for a in actions))
    for op in body.get("uncertain_effects") or []:
        out.append(f"uncertain action op:{op.get('attempt')} ({op.get('kind')} {op.get('item')}): "
                   f"{op.get('state')}; run reconcile-operations before any retry")
    if (body.get("lifecycle") or {}).get("ended"):
        out.append("the programme has ended: start no workers and re-arm no watchers for it")
    return out


def render_context(run_id, record, revision=None) -> str:
    body = packet(run_id, record, revision)
    where = f"store revision {revision}" if revision is not None else "the programme record"
    lines = [f"programme: {run_id}", f"context digest: {digest_of(body) or 'none'}"]
    lines += context_lines(body)
    text = "\n".join(lines).replace("<", "\\u003c")
    return (
        f"Context restored from {where}. It is context, not approval: nothing in it approves an "
        "action, and retained copies are never origin-verified.\n"
        f"<{CONTEXT_TAG}>\n{text}\n</{CONTEXT_TAG}>\n"
        "Full text of any entry: `programme.sh recover --get <id>`; retained results are re-read by "
        "`programme.sh recover`.\n"
    )


def mark(home, session_id, trigger, digest) -> None:
    body = json.dumps({"at": run_record_core.now_iso(), "session_id": session_id, "trigger": trigger, "context_digest": digest})
    flag = os.path.join(home, programme_home.COMPACT_FLAG)
    fd = os.open(flag, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as fh:
        fh.write(body + "\n")


def flag(home) -> dict | None:
    path = os.path.join(home, programme_home.COMPACT_FLAG)
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.loads(fh.read() or "{}")
    except FileNotFoundError:
        return None
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def check_ack(run_id, home, record, wanted=None) -> str | None:
    """Runs inside the ack's record lock; raises StaleAck when the decision context moved."""
    current = context_digest(run_id, record)
    seen = flag(home)
    expected = wanted or (seen or {}).get("context_digest")
    if expected and expected != current:
        raise StaleAck(current)
    return current


def rebind(home, current) -> None:
    seen = flag(home) or {}
    mark(home, seen.get("session_id"), seen.get("trigger") or "stale_ack", current)


def closing_lines(session_id) -> list:
    out = []
    for run in programme_home.closing_runs(session_id):
        record, hold = programme_home.read_programme(run)
        programme = (record or {}).get("programme") or {}
        if hold is not None:
            out.append(f"auto: ended programme {run} cannot be read ({hold['outcome']}); tell Shawn.")
            continue
        if not programme.get("ended") or programme_home.sealed(programme):
            continue
        out.append(f"auto: programme {run} has ended and is not archived. Start no workers and re-arm no "
                   f"watchers for it. Run `programme.sh check-archive --run {run}`, then `archive --run {run}` "
                   "when every check passes.")
    return out


def _names_session(home, run_id, session_id) -> bool:
    try:
        with open(run_record_core.run_record_path(home, run_id), "rb") as fh:
            return session_id.encode("utf-8") in fh.read()
    except OSError:
        return True


def unleased_runs(session_id) -> list:
    if not session_id:
        return []
    leased = {lease.get("run") for _, lease in programme_home.iter_leases() if isinstance(lease, dict)}
    try:
        names = sorted(os.listdir(programme_home.programmes_dir()))
    except OSError:
        return []
    found = []
    for run in names:
        if run in leased or run.startswith(".") or run in ("leases", "closing"):
            continue
        try:
            home = programme_home.home_path(programme_home.check_run_id(run))
        except programme_home.ProgrammeHomeError:
            continue
        if not os.path.isdir(home) or not _names_session(home, run, session_id):
            continue
        record, hold = programme_home.read_programme(run)
        programme = (record or {}).get("programme") or {}
        if hold is None and record and record.get("driving_session_id") == session_id \
                and not programme.get("ended"):
            found.append(run)
    return found


def unleased_lines(session_id) -> list:
    return [f"auto: programme {run} names this session as its driver, but no lease file names the run, so "
            f"hooks cannot see it. Run `programme.sh reconcile-leases --run {run}` before acting for it."
            for run in unleased_runs(session_id)]


def inbox_verb(host, argv) -> int:
    _, opts = host._parse(argv, values=("run",), flags=("all",))
    run_id = programme_recovery.run_of(host, opts)
    home = programme_home.home_path(run_id)
    if programme_authority.promoted(home, run_id):
        snap = programme_authority.snapshot(run_id)
        record, revision, rows = snap["record"], snap["revision"], snap["claims"]
    else:
        record, revision = run_record_core.read_run_record(home, run_id), None
        rows = load_lib_module("programme_journal").claims(run_id)
    offset = ((record.get("programme") or {}).get("inbox_offset")) or 0
    start = 0 if opts.get("all") else offset
    host._emit({"ok": True, "run": run_id, "revision": revision, "inbox_offset": offset, "total": len(rows),
                "claims": [dict(row, index=n) for n, row in enumerate(rows) if n >= start],
                "next": f"mark-read --offset {len(rows)}"})
    return 0
