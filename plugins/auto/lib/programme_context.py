#!/usr/bin/env python3
"""Scoped decisions, requirement-linked acceptance, safety pauses and tool denials.

The context lives in the programme block under ``context`` and is committed with the
record, so a replacement PM reads the same revision as the CLI. Decision and
requirement revisions are append-only: a change adds a revision, and acceptance only
moves the lifecycle marks (``state``, ``accepted``, ``superseded_by``).

Context is not authority. A revision records where it came from, but a copy, a
packet or a restored record never approves anything; acceptance needs a typed prompt
through the host's approval check.

This module stays pure over the programme block because the predicate loads it on
every record write. Verb handlers reach the protocol, the typed-prompt check and item
resolution through the host and the ``programme_record`` module given to
``build_verbs``.
"""

from __future__ import annotations

import functools
import hashlib
import json
import os
import re
import secrets
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

run_record_core = load_lib_module("run_record_core")
programme_home = load_lib_module("programme_home")
programme_sanitize = load_lib_module("programme_sanitize")

CONTEXT_KEY = "context"
SECTIONS = {"decisions": dict, "requirements": dict, "assignments": dict, "blockers": dict,
            "pauses": dict, "denials": list}
RISKS = ("safety", "data_loss")
CHECK_SEP = "="
PROGRAMME_SCOPE = "programme"
JOURNAL_KINDS = ("decision_recorded", "requirement_defined", "context_accepted", "item_assigned",
                 "blocker_raised", "blocker_cleared", "pause_raised", "pause_lifted", "denial_recorded")
AUTHORITY_NOTE = ("context, not approval: decisions and requirements here are retained records; "
                  "only a typed prompt through an approval verb accepts a change")
CHECK_RESULTS = ("confirmed", "refuted", "unknown", "not_run", "stale", "missing")
_ID_RE = re.compile(r"[a-z][a-z0-9-]{0,63}")
_ACTION_RE = re.compile(r"[a-z][a-z0-9_]{0,63}")


class ContextError(Exception):
    pass


def _dict(value) -> dict:
    return value if isinstance(value, dict) else {}


def check_id(value, what) -> str:
    if not isinstance(value, str) or not _ID_RE.fullmatch(value):
        raise ContextError(f"{what} id must be lower-case words joined by '-': {value!r}")
    return value


def block(programme) -> dict:
    raw = programme.get(CONTEXT_KEY)
    if raw is None:
        return {name: kind() for name, kind in SECTIONS.items()}
    if not isinstance(raw, dict):
        raise ContextError("the context block is not an object")
    out = {}
    for name, kind in SECTIONS.items():
        value = raw.get(name, kind())
        if not isinstance(value, kind):
            raise ContextError(f"context section {name!r} is not a {kind.__name__}")
        out[name] = value
    return out


def _mutable(programme) -> dict:
    block(programme)
    raw = programme.setdefault(CONTEXT_KEY, {})
    for name, kind in SECTIONS.items():
        raw.setdefault(name, kind())
    return raw


def in_force(revisions):
    hits = [r for r in revisions or [] if _dict(r).get("state") == "accepted"]
    return hits[-1] if hits else None


def pending(revisions):
    hits = [r for r in revisions or [] if _dict(r).get("state") == "pending_acceptance"]
    return hits[-1] if hits else None


def split_check(spec):
    item_id, sep, deliverable = str(spec).rpartition(CHECK_SEP)
    if not sep or not item_id or deliverable not in programme_home.DELIVERABLES:
        raise ContextError(f"a check is <item-id>{CHECK_SEP}<deliverable> with a protocol deliverable "
                           f"{list(programme_home.DELIVERABLES)}: {spec!r}")
    return item_id, deliverable


def _item(items, item_id):
    if item_id in items:
        return items[item_id]
    for item in items.values():
        if item_id in (_dict(item).get("aliases") or []):
            return item
    return None


def check_result(items, spec, accepted_at) -> str:
    item_id, deliverable = split_check(spec)
    entry = _dict(_item(items, item_id)).get("deliverables")
    if not isinstance(entry, dict) or deliverable not in entry:
        return "missing"
    entry = _dict(entry[deliverable])
    checked = run_record_core.parse_iso(entry.get("checked_at")) if isinstance(entry.get("checked_at"), str) else None
    result = entry.get("result")
    if result == "confirmed":
        # Same-second stamps are fresh: both sides are whole-second ISO times.
        accepted = run_record_core.parse_iso(accepted_at) if isinstance(accepted_at, str) else None
        return "stale" if checked is None or (accepted is not None and checked < accepted) else "confirmed"
    if result == "refuted":
        return "refuted"
    return "unknown" if checked is not None else "not_run"


def _evidence_complete(item) -> bool:
    deliverables = item.get("deliverables")
    return bool(item.get("matched_rule")) and isinstance(deliverables, dict) and bool(deliverables) \
        and all(_dict(d).get("result") == "confirmed" for d in deliverables.values())


def outcomes(items) -> dict:
    out = {"completed": [], "handed": [], "dropped": [], "open": []}
    for item_id in sorted(items):
        item = _dict(items[item_id])
        state = item.get("state")
        if state in ("handed", "dropped"):
            out[state].append(item_id)
        elif _evidence_complete(item):
            out["completed"].append(item_id)
        else:
            out["open"].append(item_id)
    return out


def _requirement_row(rid, revisions, items, open_blockers) -> dict:
    current, waiting = in_force(revisions), pending(revisions)
    row = {"id": rid, "rev": None, "pending_rev": waiting and waiting.get("rev"), "text": None,
           "checks": [], "blockers": [], "state": "not_accepted"}
    if current is None:
        return row
    accepted_at = _dict(current.get("accepted")).get("at")
    row.update(rev=current.get("rev"), text=current.get("text"))
    row["checks"] = [{"check": spec, "result": check_result(items, spec, accepted_at)}
                     for spec in current.get("checks") or []]
    row["blockers"] = [b["id"] for b in open_blockers if b.get("requirement") == rid]
    if row["blockers"]:
        row["state"] = "blocked"
    elif row["checks"] and all(c["result"] == "confirmed" for c in row["checks"]):
        row["state"] = "satisfied"
    else:
        row["state"] = "unsatisfied"
    return row


def active_pauses(ctx) -> list:
    return [dict(_dict(p), id=pid) for pid, p in sorted(ctx["pauses"].items())
            if _dict(p).get("state") == "active"]


def paused_items(programme):
    pauses = active_pauses(block(programme))
    every = any(not p.get("items") for p in pauses)
    return every, {i for p in pauses for i in p.get("items") or []}, [p["id"] for p in pauses]


def _pending_rows(ctx) -> list:
    out = []
    for kind in ("decisions", "requirements"):
        for cid, revisions in sorted(ctx[kind].items()):
            waiting = pending(revisions)
            if waiting:
                out.append({"kind": kind[:-1], "id": cid, "rev": waiting.get("rev"),
                            "delta": waiting.get("delta")})
    return out


def evaluate(programme) -> dict:
    ctx = block(programme)
    items = _dict(programme.get("items"))
    blockers = [dict(_dict(b), id=bid) for bid, b in sorted(ctx["blockers"].items())]
    open_blockers = [b for b in blockers if b.get("state") == "open"]
    requirements = [_requirement_row(rid, revs, items, open_blockers)
                    for rid, revs in sorted(ctx["requirements"].items())]
    checked = {split_check(c["check"])[0] for r in requirements for c in r["checks"]}
    gated = set()
    for item_id in checked:
        found = _item(items, item_id)
        gated.add(_dict(found).get("id") or item_id)
    finished = programme_home.FINISHED_ITEM_STATES
    followups = sorted(i for i, item in items.items()
                       if _dict(item).get("state") not in finished and i not in gated)
    return {
        "requirements": requirements,
        "satisfied": [r["id"] for r in requirements if r["state"] == "satisfied"],
        "followups": followups,
        "outcomes": outcomes(items),
        "blockers": open_blockers,
        "safety_pauses": active_pauses(ctx),
        "denials": list(ctx["denials"]),
        "pending": _pending_rows(ctx),
    }


def unsafe_reason(programme, item_id, action):
    ctx = block(programme)
    for pause in active_pauses(ctx):
        if not pause.get("items") or item_id in pause["items"]:
            return (f"safety pause {pause['id']} ({pause.get('risk')}: {pause.get('reason')}) holds "
                    f"{item_id}; it lifts only through lift-pause with a typed prompt")
    for denial in ctx["denials"]:
        denial = _dict(denial)
        if denial.get("action") == action and denial.get("item") in (None, item_id):
            return (f"a tool denied {action} for {item_id} ({denial.get('tool')}: {denial.get('reason')}); "
                    "the denial binds, so do not route around it — ask Shawn")
    return None


def _now() -> str:
    return run_record_core.now_iso()


def _source(prompt) -> dict:
    return {"class": "human_input" if prompt else "derived",
            "prompt_id": prompt and prompt["prompt_id"],
            "origin_label": "typed" if prompt else None,
            "origin_verified": False}


def _accept(revisions, revision, prompt) -> None:
    current = in_force(revisions)
    if current is not None and current is not revision:
        current["state"] = "superseded"
        current["superseded_by"] = revision["rev"]
        revision["supersedes"] = current["rev"]
    revision["state"] = "accepted"
    revision["accepted"] = {"at": _now(), "prompt_id": prompt["prompt_id"], "origin_verified": False}


def _append(revisions, content, prompt, *, accept, delta) -> dict:
    for old in revisions:
        if old.get("state") == "pending_acceptance":
            old["state"] = "replaced"
    revision = dict(content, rev=len(revisions) + 1, state="pending_acceptance", at=_now(),
                    source=_source(prompt), delta=delta, supersedes=None, superseded_by=None,
                    accepted=None)
    if accept:
        _accept(revisions, revision, prompt)
    revisions.append(revision)
    return revision


def _content(revision, keys) -> dict:
    return {k: revision.get(k) for k in keys}


def _text(value, field):
    text = programme_sanitize.clean(value)
    if not text:
        raise ContextError(f"--{field} needs a non-empty value")
    return text


def _ids(ctx, cid, kind) -> None:
    other = "requirements" if kind == "decisions" else "decisions"
    if cid in ctx[other]:
        raise ContextError(f"{cid!r} is already a {other[:-1]} id; decision and requirement ids share one namespace")


def _item_options(item_id) -> list:
    return [item_id.split(":", 1)[-1], item_id]


DECISION_KEYS = ("scope", "reason", "limits", "applies_to", "requirements")
REQUIREMENT_KEYS = ("text", "checks", "decision_id")
ID_FIELDS = {"decisions": "decision_id", "requirements": "requirement_id"}


def _decision_delta(current, content):
    if current is None:
        return None
    return {"added": sorted(set(content["applies_to"]) - set(current.get("applies_to") or [])),
            "removed_limits": sorted(set(current.get("limits") or []) - set(content["limits"]))}


def _record_revision(host, kind, cid, content, delta, wider, prompt, programme):
    ctx = _mutable(programme)
    _ids(ctx, cid, kind)
    revisions = ctx[kind].setdefault(cid, [])
    current = in_force(revisions)
    keys = DECISION_KEYS if kind == "decisions" else REQUIREMENT_KEYS
    if current is not None and _content(current, keys) == content:
        return {ID_FIELDS[kind]: cid, "rev": current["rev"], "state": "accepted", "unchanged": True}
    if prompt:
        host.require_named(prompt, cid)
    revision = _append(revisions, content, prompt, accept=bool(prompt) and not wider, delta=delta)
    return {ID_FIELDS[kind]: cid, "rev": revision["rev"], "state": revision["state"], "unchanged": False,
            "delta": delta, "source": revision["source"]}


def _scope(record, programme, targets) -> list:
    out = []
    for target in targets or [PROGRAMME_SCOPE]:
        out.append(target if target == PROGRAMME_SCOPE else record._resolve(programme, record.check_item_id(target)))
    return sorted(set(out))


def _h_record_decision(host, record, argv):
    positional, opts = host._parse(argv, values=("run", "scope", "reason", "prompt"),
                                   multi=("limit", "applies-to", "requirement"))
    if len(positional) != 1:
        raise ValueError("usage: record-decision <id> --scope <text> --reason <text> [--limit <text>]... "
                         "[--applies-to programme|<item-id>]... [--requirement <id>]... [--prompt <id>]")
    cid = _guarded(record, check_id, positional[0], "decision record")
    scope, reason = _guarded(record, _text, opts.get("scope"), "scope"), _guarded(record, _text, opts.get("reason"), "reason")
    limits = sorted({programme_sanitize.clean(v) for v in opts["limit"] if programme_sanitize.clean(v)})
    requirements = sorted({_guarded(record, check_id, r, "requirement") for r in opts["requirement"]})

    def change(programme, prompt, rec):
        content = {"scope": scope, "reason": reason, "limits": limits,
                   "applies_to": _scope(record, programme, opts["applies-to"]), "requirements": requirements}
        current = in_force(_dict(_guarded(record, block, programme)["decisions"]).get(cid))
        delta = _decision_delta(current, content)
        wider = bool(delta and (delta["added"] or delta["removed_limits"]))
        return _guarded(record, _record_revision, host, "decisions", cid, content, delta, wider, prompt, programme)

    return host._write(opts, change, "decision_recorded", prompt_id=opts.get("prompt"))


def _checks(record, programme, specs) -> list:
    out = []
    for spec in specs:
        item_id, deliverable = split_check(spec)
        key = record._resolve(programme, record.check_item_id(item_id))
        if not record.programme_protocol.obliges(programme["items"][key], deliverable):
            raise ContextError(f"{deliverable!r} is not a deliverable the protocol requires of {key!r}")
        out.append(f"{key}{CHECK_SEP}{deliverable}")
    return sorted(set(out))


def _h_define_requirement(host, record, argv):
    positional, opts = host._parse(argv, values=("run", "text", "decision-id", "prompt"), multi=("check",))
    if len(positional) != 1 or not opts["check"]:
        raise ValueError("usage: define-requirement <id> --text <text> --check <item-id>=<deliverable>... "
                         "[--decision-id <id>] [--prompt <id>]")
    cid = _guarded(record, check_id, positional[0], "requirement")
    text = _guarded(record, _text, opts.get("text"), "text")
    decision = (_guarded(record, check_id, opts["decision-id"], "decision record")
                if opts.get("decision-id") else None)

    def change(programme, prompt, rec):
        ctx = _guarded(record, block, programme)
        if decision and decision not in ctx["decisions"]:
            raise record.RecordError(f"no decision {decision!r}")
        content = {"text": text, "checks": _guarded(record, _checks, record, programme, opts["check"]),
                   "decision_id": decision}
        current = in_force(ctx["requirements"].get(cid))
        delta = None if current is None else {
            "added_checks": sorted(set(content["checks"]) - set(current.get("checks") or [])),
            "removed_checks": sorted(set(current.get("checks") or []) - set(content["checks"]))}
        return _guarded(record, _record_revision, host, "requirements", cid, content, delta, False, prompt, programme)

    return host._write(opts, change, "requirement_defined", prompt_id=opts.get("prompt"))


def _h_accept_context(host, record, argv):
    positional, opts = host._parse(argv, values=("run", "prompt"))
    if len(positional) != 1:
        raise ValueError("usage: accept-context <decision-or-requirement-id> --prompt <id>")
    cid = positional[0]

    def change(programme, prompt, rec):
        ctx = _guarded(record, _mutable, programme)
        kind = "decisions" if cid in ctx["decisions"] else "requirements" if cid in ctx["requirements"] else None
        revision = pending(ctx[kind].get(cid)) if kind else None
        if revision is None:
            raise record.RecordError(f"no pending revision of {cid!r} to accept")
        added = _dict(revision.get("delta")).get("added") or []
        host.require_named(prompt, cid, *[_item_options(t) if t != PROGRAMME_SCOPE else t for t in added])
        _accept(ctx[kind][cid], revision, prompt)
        return {ID_FIELDS[kind]: cid, "rev": revision["rev"], "state": "accepted", "supersedes": revision["supersedes"]}

    return host._write(opts, change, "context_accepted", prompt_id=opts.get("prompt"), needs_prompt=True)


def _h_assign_item(host, record, argv):
    positional, opts = host._parse(argv, values=("run", "decision-id"))
    if len(positional) != 1 or not opts.get("decision-id"):
        raise ValueError("usage: assign-item <item-id> --decision-id <id>")
    item_id = record.check_item_id(positional[0])
    cid = _guarded(record, check_id, opts["decision-id"], "decision record")

    def change(programme, prompt, rec):
        key = record._resolve(programme, item_id)
        ctx = _guarded(record, _mutable, programme)
        revisions = ctx["decisions"].get(cid)
        if not revisions:
            raise record.RecordError(f"no decision {cid!r}")
        current, waiting = in_force(revisions), pending(revisions)
        if current is None or not ({PROGRAMME_SCOPE, key} & set(current.get("applies_to") or [])):
            if waiting and {PROGRAMME_SCOPE, key} & set(waiting.get("applies_to") or []):
                raise record.RecordError(f"{key!r} is in revision {waiting['rev']} of {cid!r}, which waits for "
                                         "acceptance of its delta; accept-context first")
            raise record.RecordError(f"{key!r} is outside the scope of decision {cid!r}")
        ctx["assignments"][key] = {"decision_id": cid, "rev": current["rev"], "at": _now()}
        return {"item": key, "decision_id": cid, "rev": current["rev"]}

    return host._write(opts, change, "item_assigned")


def _h_raise_blocker(host, record, argv):
    names = ("requirement", "check", "dependency", "evidence", "unblock")
    positional, opts = host._parse(argv, values=("run",) + names)
    if len(positional) != 1:
        raise ValueError("usage: raise-blocker <id> --requirement <id> --check <item-id>=<deliverable> "
                         "--dependency <item-id> --evidence <ref> --unblock <text>")
    missing = [n for n in names if not programme_sanitize.clean(opts.get(n))]
    if missing:
        raise record.RecordError("an acceptance blocker names its requirement, check, dependency, evidence and "
                                 f"unblock condition; missing {', '.join('--' + n for n in missing)}")
    bid = _guarded(record, check_id, positional[0], "blocker")
    evidence = record._token(opts["evidence"], "evidence")
    dependency = record.check_item_id(opts["dependency"])

    def change(programme, prompt, rec):
        ctx = _guarded(record, _mutable, programme)
        current = in_force(ctx["requirements"].get(opts["requirement"]))
        if current is None:
            raise record.RecordError(f"no accepted requirement {opts['requirement']!r}")
        item_id, deliverable = _guarded(record, split_check, opts["check"])
        spec = f"{record._resolve(programme, record.check_item_id(item_id))}{CHECK_SEP}{deliverable}"
        if spec not in (current.get("checks") or []):
            raise record.RecordError(f"{spec!r} is not a check of requirement {opts['requirement']!r} "
                                     f"(checks: {current.get('checks')})")
        if _dict(ctx["blockers"].get(bid)).get("state") == "open":
            raise record.RecordError(f"blocker {bid!r} is already open")
        entry = {"requirement": opts["requirement"], "rev": current["rev"], "check": spec,
                 "dependency": record._resolve(programme, dependency), "evidence": evidence,
                 "unblock": programme_sanitize.clean(opts["unblock"]), "state": "open", "at": _now(),
                 "cleared": None}
        ctx["blockers"][bid] = entry
        return dict(entry, blocker=bid)

    return host._write(opts, change, "blocker_raised")


def _h_clear_blocker(host, record, argv):
    positional, opts = host._parse(argv, values=("run", "why"))
    if len(positional) != 1 or not programme_sanitize.clean(opts.get("why")):
        raise ValueError("usage: clear-blocker <id> --why <text>")

    def change(programme, prompt, rec):
        entry = _guarded(record, _mutable, programme)["blockers"].get(positional[0])
        if _dict(entry).get("state") != "open":
            raise record.RecordError(f"no open blocker {positional[0]!r}")
        entry["state"] = "cleared"
        entry["cleared"] = {"at": _now(), "why": programme_sanitize.clean(opts["why"])}
        return {"blocker": positional[0], "requirement": entry["requirement"], "why": entry["cleared"]["why"]}

    return host._write(opts, change, "blocker_cleared")


def _h_pause(host, record, argv):
    positional, opts = host._parse(argv, values=("run", "risk", "reason"), multi=("item",))
    if len(positional) != 1 or opts.get("risk") not in RISKS:
        raise ValueError(f"usage: pause <id> --risk {'|'.join(RISKS)} --reason <text> [--item <id>]...")
    pid = _guarded(record, check_id, positional[0], "pause")
    reason = _guarded(record, _text, opts.get("reason"), "reason")

    def change(programme, prompt, rec):
        ctx = _guarded(record, _mutable, programme)
        if _dict(ctx["pauses"].get(pid)).get("state") == "active":
            raise record.RecordError(f"pause {pid!r} is already active")
        items = sorted({record._resolve(programme, record.check_item_id(i)) for i in opts["item"]})
        ctx["pauses"][pid] = {"risk": opts["risk"], "reason": reason, "items": items, "state": "active",
                              "at": _now(), "lifted": None}
        return {"pause": pid, "risk": opts["risk"], "reason": reason, "items": items, "state": "active"}

    def after(payload):
        code = record._run_tool(["herdr", "notification", "show", f"auto: safety pause {pid} needs you",
                                 "--body", reason, "--sound", "request"])
        return {"escalation": {"herdr": code}}

    return host._write(opts, change, "pause_raised", after=after)


def _h_lift_pause(host, record, argv):
    positional, opts = host._parse(argv, values=("run", "prompt"))
    if len(positional) != 1:
        raise ValueError("usage: lift-pause <id> --prompt <id>")

    def change(programme, prompt, rec):
        entry = _guarded(record, _mutable, programme)["pauses"].get(positional[0])
        if _dict(entry).get("state") != "active":
            raise record.RecordError(f"no active pause {positional[0]!r}")
        host.require_named(prompt, positional[0])
        entry["state"] = "lifted"
        entry["lifted"] = {"at": _now(), "prompt_id": prompt["prompt_id"], "origin_verified": False}
        return {"pause": positional[0], "state": "lifted"}

    return host._write(opts, change, "pause_lifted", prompt_id=opts.get("prompt"), needs_prompt=True)


def requirements_digest(ctx) -> str:
    blob = json.dumps(ctx["requirements"], sort_keys=True, separators=(",", ":"))
    return "sha256:" + hashlib.sha256(blob.encode("utf-8")).hexdigest()


def _h_record_denial(host, record, argv):
    positional, opts = host._parse(argv, values=("run", "tool", "action", "reason", "item"))
    if positional or not opts.get("tool") or not opts.get("action"):
        raise ValueError("usage: record-denial --tool <name> --action <lower_snake> --reason <text> [--item <id>]")
    tool = record._token(opts["tool"], "tool")
    if not _ACTION_RE.fullmatch(opts["action"]):
        raise record.RecordError(f"--action must be a lower_snake name: {opts['action']!r}")
    reason = _guarded(record, _text, opts.get("reason"), "reason")
    item_id = record.check_item_id(opts["item"]) if opts.get("item") else None

    def change(programme, prompt, rec):
        ctx = _guarded(record, _mutable, programme)
        entry = {"id": "x" + secrets.token_hex(3), "tool": tool, "action": opts["action"], "reason": reason,
                 "item": record._resolve(programme, item_id) if item_id else None, "binding": True,
                 "at": _now(), "requirements_digest": requirements_digest(ctx)}
        ctx["denials"].append(entry)
        return dict(entry, denial=entry["id"])

    return host._write(opts, change, "denial_recorded")


def _revisions_view(section) -> dict:
    return {cid: {"in_force": in_force(revs), "pending": pending(revs), "revisions": revs}
            for cid, revs in sorted(section.items())}


def _packet(record, programme, item_id) -> dict:
    ctx = block(programme)
    key = record._resolve(programme, record.check_item_id(item_id))
    assignment = dict(_dict(ctx["assignments"].get(key))) or None
    decision = None
    if assignment:
        revisions = ctx["decisions"].get(assignment["decision_id"]) or []
        decision = next((r for r in revisions if r.get("rev") == assignment["rev"]), None)
        assignment["superseded_by"] = _dict(decision).get("superseded_by")
    bound = assignment and assignment["decision_id"]
    requirements = []
    for rid, revisions in sorted(ctx["requirements"].items()):
        current = in_force(revisions)
        touches = current and (any(split_check(c)[0] == key for c in current.get("checks") or [])
                               or (bound and current.get("decision_id") == bound))
        if touches:
            requirements.append(dict(_content(current, REQUIREMENT_KEYS), id=rid, rev=current["rev"]))
    ids = {r["id"] for r in requirements}
    status = evaluate(programme)
    return {"item": key, "assignment": assignment, "decision_revision": decision, "requirements": requirements,
            "acceptance": [r for r in status["requirements"] if r["id"] in ids],
            "blockers": [b for b in status["blockers"] if key in (b.get("dependency"), split_check(b["check"])[0])],
            "pauses": [p for p in status["safety_pauses"] if not p.get("items") or key in p["items"]],
            "denials": [d for d in status["denials"] if _dict(d).get("item") in (None, key)]}


def _h_context(host, record, argv):
    _, opts = host._parse(argv, values=("run", "item"))
    run_id, home, rec = host._locate(opts)
    revision = None
    if host.programme_authority.promoted(home, run_id):
        snap = host.programme_authority.snapshot(run_id)
        rec, revision = snap["record"], snap["revision"]
    programme = programme_home.normalize_programme(rec.get("programme") or {})
    if opts.get("item"):
        body = _guarded(record, _packet, record, programme, opts["item"])
    else:
        ctx = _guarded(record, block, programme)
        body = {"decisions": _revisions_view(ctx["decisions"]),
                "requirements": _revisions_view(ctx["requirements"]),
                "assignments": ctx["assignments"], "acceptance": _guarded(record, evaluate, programme)}
    host._emit(dict({"ok": True, "run": run_id, "revision": revision, "authority": AUTHORITY_NOTE}, **body))
    return 0


def _guarded(record, fn, *args):
    try:
        return fn(*args)
    except ContextError as exc:
        raise record.RecordError(str(exc)) from None


SPECS = (
    ("record-decision", _h_record_decision,
     "<id> --scope <text> --reason <text> [--limit <text>]... [--applies-to programme|<item-id>]... "
     "[--requirement <id>]... [--prompt <id>] [--run <id>]",
     "an id that is not lower-case words joined by '-'; no --scope or --reason; an unknown item; a prompt "
     "that is not typed or does not name the id. The same content as the revision in force adds nothing. "
     "Without a prompt, or when it widens the scope (adds a target or drops a limit), the revision waits "
     "for accept-context while the prior one stays in force."),
    ("define-requirement", _h_define_requirement,
     "<id> --text <text> --check <item-id>=<deliverable>... [--decision-id <id>] [--prompt <id>] [--run <id>]",
     "a check on a deliverable the protocol does not require of the item; an unknown item or decision; a "
     "prompt that is not typed or does not name the id. Without a prompt the revision waits for accept-context."),
    ("accept-context", _h_accept_context, "<decision-or-requirement-id> --prompt <id> [--run <id>]",
     "no pending revision; a prompt that is not typed, was imported from a legacy journal, or does not name "
     "the id and every target the revision adds."),
    ("assign-item", _h_assign_item, "<item-id> --decision-id <id> [--run <id>]",
     "an item outside the scope of the decision's revision in force (compared by canonical id, so a merge "
     "never widens it); a target only a pending revision adds."),
    ("raise-blocker", _h_raise_blocker,
     "<id> --requirement <id> --check <item-id>=<deliverable> --dependency <item-id> --evidence <ref> "
     "--unblock <text> [--run <id>]",
     "any missing link; a requirement with no accepted revision; a check that is not one of its checks; an "
     "unknown dependency item. Open work without a named dependency never blocks acceptance."),
    ("clear-blocker", _h_clear_blocker, "<id> --why <text> [--run <id>]", "no --why; a blocker that is not open."),
    ("pause", _h_pause, "<id> --risk safety|data_loss --reason <text> [--item <id>]... [--run <id>]",
     "an unknown risk; no --reason; a pause already active. With no --item it holds the whole programme. "
     "It refuses start-worker and prompt-item on what it holds, holds the stop, and notifies Shawn."),
    ("lift-pause", _h_lift_pause, "<id> --prompt <id> [--run <id>]",
     "a pause that is not active; a prompt that is not typed or does not name the pause id."),
    ("record-denial", _h_record_denial,
     "--tool <name> --action <lower_snake> --reason <text> [--item <id>] [--run <id>]",
     "a tool name with spaces; an action that is not lower_snake. The denial binds: the same action on that "
     "item (or any item, without --item) refuses. It never changes a requirement."),
    ("context", _h_context, "[--item <id>] [--run <id>]",
     "an unknown item. Read-only; any session may read. Prints the committed store revision it read."),
)


def build_verbs(host, record) -> dict:
    return {name: host._Verb(functools.partial(handler, host, record), args, rejects=rejects,
                             reads=name == "context")
            for name, handler, args, rejects in SPECS}
