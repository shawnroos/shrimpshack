#!/usr/bin/env python3
"""Rulings: Shawn's dated, scoped orders and decisions, each a revision chain in the context decision store.

A Ruling is a decision record with a decision kind, an effect (decided, grant or restrict), an end
date and Shawn's words. ``programme.py`` registers ``record-ruling``, ``close-ruling`` and
``accept-context`` through ``build_verbs(host)``. The handlers here load the protocol to record a
grant's Authority baseline; ``programme_context`` stays pure.
"""

from __future__ import annotations

import functools
import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

run_record_core = load_lib_module("run_record_core")
programme_journal = load_lib_module("programme_journal")
programme_sanitize = load_lib_module("programme_sanitize")
programme_decisions = load_lib_module("programme_decisions")
programme_context = load_lib_module("programme_context")

pc = programme_context
ENDINGS = ("fulfilled", "withdrawn")
CORRECTION_EFFECTS = ("grant", "restrict")
ANCHOR_ROWS = {"item_handed": "ask", "pm_decided": "decision_id", "handed_answered": "decision_id"}


class RulingError(programme_decisions.DecisionError):
    pass


def _dict(value) -> dict:
    return value if isinstance(value, dict) else {}


def row_index(rows, kind, key, value):
    return next((i for i, row in enumerate(rows) if row.get("kind") == kind
                 and (row.get(key) == value or (row.get("payload") or {}).get(key) == value)), None)


def prompt_index(rows, prompt_id) -> int:
    index = row_index(rows, "prompt", "prompt_id", prompt_id)
    if index is None:
        raise RulingError(f"no prompt {prompt_id!r} in this programme's journal")
    return index


def anchor(programme, anchor_id) -> dict:
    for entry in programme.get("decisions") or []:
        if isinstance(entry, dict) and entry.get("id") == anchor_id:
            return {"kind": entry.get("kind"), "item": entry.get("item"), "ask": False}
    for key, item in programme["items"].items():
        if programme_decisions.ask_id(item) == anchor_id:
            return {"kind": programme_decisions.ask_kind(item), "item": key, "ask": True}
    raise RulingError(f"no ask or recorded choice {anchor_id!r} in this programme")


def check_anchor_order(rows, anchor_id, prompt_id) -> None:
    first = min((i for kind, key in ANCHOR_ROWS.items()
                 for i in [row_index(rows, kind, key, anchor_id)] if i is not None), default=None)
    if first is None or first > prompt_index(rows, prompt_id):
        raise RulingError(f"{anchor_id!r} was not recorded before prompt {prompt_id!r}; a correction "
                          "replies only to an ask or choice Shawn had already seen")


def _check_protected(kind, effect) -> None:
    if effect != "restrict" and kind in programme_decisions.PROTECTED_KINDS:
        raise RulingError(f"kind {kind!r} is protected and stays with Shawn: no Ruling may {effect} it; "
                          "the PM hands every such call to Shawn with hand-item")


def _until(value):
    if not value:
        return None
    if run_record_core.parse_iso(value) is None:
        raise RulingError(f"--until must be an ISO time in UTC like 2026-11-01T00:00:00Z: {value!r}")
    return value


def target_repos(programme, targets) -> set:
    items = programme["items"]
    return {items[t].get("repo") if t in items else None for t in targets}


def protocol_for(host, programme, targets) -> dict:
    repos = target_repos(programme, targets)
    if None in repos:
        repos = {r.get("path") for r in (programme.get("remit") or {}).get("repos") or [] if isinstance(r, dict)}
    return host.programme_protocol.load(repos=sorted(r for r in repos if r), prompt_lookup=host.prompt_lookup)


def level_of(protocol, kind):
    return (protocol["autonomy"].get(kind) or {}).get("level")


def authority_level(host, programme, kind, targets):
    return level_of(protocol_for(host, programme, targets), kind)


def legacy_restricts(programme) -> list:
    out = []
    for rid, _, current in pc.current_revisions(pc.block(programme)["decisions"]):
        if current.get("legacy") == "project_term":
            out.append({"id": rid, "area": current.get("area"), "scope": current.get("scope")})
    return out


def _activate(host, programme, revision, prompt, baseline=None) -> None:
    if revision.get("quote") is None:
        revision["quote"] = prompt["quote"]
    if revision.get("effect") == "grant":
        revision["baseline"] = baseline or authority_level(host, programme, revision["kind"],
                                                           revision.get("applies_to") or [])


def _check_revisable(cid, revisions, kind, effect, prompt) -> None:
    if not revisions:
        return
    last = revisions[-1]
    if last.get("legacy"):
        raise RulingError(f"{cid!r} is an old {last['legacy'].replace('_', ' ')} with no decision kind; record it "
                          "again as a Ruling with a kind under a new id")
    if not pc.is_ruling(revisions):
        raise RulingError(f"{cid!r} is a decision record without a kind; record the Ruling under a new id")
    if pc.ruling_state(revisions, None) == "closed":
        raise RulingError(f"Ruling {cid!r} is closed; record a new Ruling instead")
    if (last.get("kind"), last.get("effect")) != (kind, effect):
        raise RulingError(f"Ruling {cid!r} is a {last.get('effect')} of {last.get('kind')}; a revision keeps "
                          "its kind and effect, so record a new Ruling for a different one")
    if effect == "decided" and pc.in_force(revisions) is not None and not prompt:
        raise RulingError(f"Ruling {cid!r} is Shawn's own decision; changing it needs a typed prompt naming it")


def _named(target):
    return target if target == pc.PROGRAMME_SCOPE else pc._item_options(target)


# A carried Ruling arrives with no items, so every item it is given is new here and must be named by
# Shawn's prompt, whatever its effect; accept-context reads the same names.
def _carried_delta(content) -> dict:
    items = list(content["applies_to"])
    return {"added": items, "removed": [], "removed_limits": [], "until": None, "names": items, "wider": False}


def _record(host, programme, cid, content, prompt, *, correction=None) -> dict:
    ctx = pc._mutable(programme)
    pc._ids(ctx, cid, "decisions")
    _check_protected(content["kind"], content["effect"])
    revisions = ctx["decisions"].get(cid) or []
    if correction and revisions:
        raise RulingError(f"{cid!r} already exists; a correction records a new Ruling")
    _check_revisable(cid, revisions, content["kind"], content["effect"], prompt)
    current = pc.in_force(revisions)
    out = {"ruling_id": cid, "kind": content["kind"], "effect": content["effect"],
           "applies_to": content["applies_to"]}
    if current is not None and pc._content(current, pc.RULING_KEYS) == content:
        return dict(out, rev=current["rev"], state="accepted", unchanged=True)
    carried = _dict(revisions[-1]).get("carried") if revisions and current is None else None
    delta = _carried_delta(content) if carried else pc.ruling_delta(current, content)
    if prompt and not correction:
        host.require_named(prompt, cid, *[_named(t) for t in (delta or {}).get("names") or [] if carried])
    revisions = ctx["decisions"].setdefault(cid, revisions)
    revision = pc._append(revisions, content, prompt, accept=bool(prompt) and not (delta and delta["wider"]),
                          delta=delta)
    revision.update(quote=prompt and prompt["quote"], replies_to=correction, baseline=None)
    if carried:
        revision["carried"] = carried
    if revision["state"] == "accepted":
        _activate(host, programme, revision, prompt, baseline=_dict(current).get("baseline"))
    return dict(out, rev=revision["rev"], state=revision["state"], unchanged=False, delta=delta,
                source=revision["source"], baseline=revision["baseline"])


def _check_prompt_unused(ctx, prompt_id) -> None:
    for rid, revisions in ctx["decisions"].items():
        if any(r.get("replies_to") and _dict(r.get("source")).get("prompt_id") == prompt_id for r in revisions):
            raise RulingError(f"prompt {prompt_id!r} already drove correction {rid!r}; one typed prompt makes "
                              "one correction")


def _correction(host, programme, rec, cid, base, anchor_id, prompt) -> dict:
    found = anchor(programme, anchor_id)
    check_anchor_order(programme_journal.read(rec["run_id"]), anchor_id, prompt["prompt_id"])
    _check_prompt_unused(pc._mutable(programme), prompt["prompt_id"])
    kind = programme_decisions.check_kind(found["kind"])
    target = found["item"] or pc.PROGRAMME_SCOPE
    out = _record(host, programme, cid, dict(base, kind=kind, applies_to=[target]), prompt, correction=anchor_id)
    item = programme["items"].get(target)
    if base["effect"] == "grant" and found["ask"] and item and item["state"] == "handed":
        item.update(state="open", waiting_on=None)
        host.programme_record._history(item, "reopened", ruling=cid)
        out["reopened"] = target
    who = "the PM decides" if base["effect"] == "grant" else "Shawn decides"
    out["notice"] = programme_sanitize.clean(
        f"Ruling {cid}: {who} {kind} on {target} from now on. Shawn said \"{prompt['quote']}\"", cap=0)
    return out


def _h_record_ruling(host, argv):
    positional, opts = host._parse(argv, values=("run", "kind", "effect", "scope", "reason", "until", "prompt",
                                                 "replies-to"), multi=("limit", "applies-to", "requirement"))
    replies = opts.get("replies-to")
    if len(positional) != 1 or opts.get("effect") not in pc.EFFECTS or bool(replies) == bool(opts.get("kind")):
        raise ValueError("usage: record-ruling <id> --effect decided|grant|restrict --scope <text> "
                         "(--kind <decision-kind> [--applies-to programme|<item-id>]... | --replies-to "
                         "<ask-or-decision-id> --prompt <id>) [--reason <text>] [--limit <text>]... "
                         "[--until <iso>] [--requirement <id>]... [--prompt <id>]")
    if replies and (opts["applies-to"] or opts["effect"] not in CORRECTION_EFFECTS):
        raise ValueError("a --replies-to correction takes its item and kind from the anchor and is a grant "
                         "or a restrict")
    record = host.programme_record
    cid = pc._guarded(record, pc.check_id, positional[0], "ruling")
    kind = None if replies else programme_decisions.check_kind(opts["kind"])
    base = {"scope": pc._guarded(record, pc._text, opts.get("scope"), "scope"),
            "reason": programme_sanitize.clean(opts.get("reason")) or None,
            "limits": sorted({programme_sanitize.clean(v) for v in opts["limit"] if programme_sanitize.clean(v)}),
            "requirements": sorted({pc._guarded(record, pc.check_id, r, "requirement") for r in opts["requirement"]}),
            "effect": opts["effect"], "until": _until(opts.get("until"))}
    if kind:
        _check_protected(kind, base["effect"])

    def change(programme, prompt, rec):
        if replies:
            return _correction(host, programme, rec, cid, base, replies, prompt)
        content = dict(base, kind=kind, applies_to=pc._scope(record, programme, opts["applies-to"]))
        return _record(host, programme, cid, content, prompt)

    return host._write(opts, change, "ruling_recorded", prompt_id=opts.get("prompt"), needs_prompt=bool(replies),
                       verb="record-ruling", target=cid)


def _h_close_ruling(host, argv):
    positional, opts = host._parse(argv, values=("run", "as", "why", "prompt", "origin"))
    if len(positional) != 1 or opts.get("as") not in ENDINGS:
        raise ValueError("usage: close-ruling <id> --as fulfilled|withdrawn [--why <text>] [--prompt <id>]")
    cid, ending = positional[0], opts["as"]
    origin = host.programme_proposals.origin_of(opts)
    why = programme_sanitize.clean(opts.get("why")) or None
    if ending == "fulfilled" and not why:
        raise ValueError("close-ruling --as fulfilled needs --why")

    def change(programme, prompt, rec):
        revisions = pc._mutable(programme)["decisions"].get(cid) or []
        current = pc.in_force(revisions) or pc.pending(revisions)
        if current is None or not pc.is_ruling(revisions):
            raise RulingError(f"no Ruling {cid!r} in force or pending to close")
        # Closing a restrict hands its kind back to the PM, and closing a decided Ruling reopens Shawn's call.
        if not prompt and (ending == "withdrawn" or current.get("effect") != "grant"):
            raise RulingError(f"closing Ruling {cid!r} ({current.get('effect')}, as {ending}) needs a typed "
                              "prompt naming it")
        if prompt:
            host.require_named(prompt, cid)
        for revision in revisions:
            if revision.get("state") == "pending_acceptance":
                revision["state"] = "replaced"
        current["state"] = "closed"
        current["closed"] = {"at": run_record_core.now_iso(), "as": ending, "why": why,
                             "prompt_id": prompt and prompt["prompt_id"]}
        return {"ruling_id": cid, "rev": current["rev"], "as": ending, "why": why, "state": "closed",
                "origin": origin}

    withdrawn = ending == "withdrawn"
    return host._write(opts, change, "ruling_closed", prompt_id=opts.get("prompt"), needs_prompt=withdrawn,
                       beat=withdrawn, verb="close-ruling", target=cid)


def _h_accept_context(host, argv):
    positional, opts = host._parse(argv, values=("run", "prompt"))
    if len(positional) != 1:
        raise ValueError("usage: accept-context <decision-or-requirement-id> --prompt <id>")
    cid = positional[0]
    record = host.programme_record

    def change(programme, prompt, rec):
        ctx = pc._guarded(record, pc._mutable, programme)
        kind = "decisions" if cid in ctx["decisions"] else "requirements" if cid in ctx["requirements"] else None
        revision = pc.pending(ctx[kind].get(cid)) if kind else None
        if revision is None:
            raise record.RecordError(f"no pending revision of {cid!r} to accept")
        delta = _dict(revision.get("delta"))
        added = delta.get("names", delta.get("added")) or []
        host.require_named(prompt, cid, *[pc._item_options(t) if t != pc.PROGRAMME_SCOPE else t for t in added])
        pc._accept(ctx[kind][cid], revision, prompt)
        if revision.get("effect") in pc.EFFECTS:
            _activate(host, programme, revision, prompt)
        return {pc.ID_FIELDS[kind]: cid, "rev": revision["rev"], "state": "accepted",
                "supersedes": revision["supersedes"], "baseline": revision.get("baseline")}

    return host._write(opts, change, "context_accepted", prompt_id=opts.get("prompt"), needs_prompt=True)


_SPECS = (
    ("record-ruling", _h_record_ruling,
     "<id> --effect decided|grant|restrict --scope <text> (--kind <decision-kind> [--applies-to "
     "programme|<item-id>]... | --replies-to <ask-or-decision-id> --prompt <id>) [--reason <text>] "
     "[--limit <text>]... [--until <iso>] [--requirement <id>]... [--prompt <id>] [--run <id>]",
     "an unknown kind or effect; a grant or decided Ruling of a protected kind; an end date that is not ISO "
     "UTC time; a revision that changes the kind or effect, or revises a closed Ruling or a kind-less "
     "decision record; a change to a decided Ruling without a typed prompt; a prompt that is not typed or does "
     "not name the id. Without a prompt it waits for accept-context. A widening (a grant that adds items, "
     "drops a limit or ends later; a restrict that loses items, drops a limit or ends sooner) waits too, while "
     "the prior revision stays in force. With --replies-to the anchor gives the item and kind, the prompt "
     "must come after the anchor and drive no other correction, and the Ruling applies at once with a notice."),
    ("close-ruling", _h_close_ruling,
     "<id> --as fulfilled|withdrawn [--why <text>] [--prompt <id>] [--origin pm|ui] [--run <id>]",
     "no Ruling in force or pending; --as fulfilled without --why; --as withdrawn, or closing a restrict or a decided "
     "Ruling, without a typed prompt naming the id. Closing as fulfilled never counts as a beat."),
    ("accept-context", _h_accept_context, "<decision-or-requirement-id> --prompt <id> [--run <id>]",
     "no pending revision; a prompt that is not typed, came from a legacy journal or an obsolete writer, or "
     "does not name the id and every target the revision adds (for a Ruling, every item it gives the PM). "
     "A grant that becomes active records the Authority level for its kind as its baseline."),
)


def build_verbs(host) -> dict:
    return {name: host._Verb(functools.partial(handler, host), args, rejects=rejects)
            for name, handler, args, rejects in _SPECS}
