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
CHANGE_ROWS = {"ruling_recorded": "ruling_id", "context_accepted": "decision_id", "ruling_closed": "ruling_id"}
NAMED_WHEN_NEW = ("grant", "decided")


class RulingError(programme_decisions.DecisionError):
    pass


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


# Only rows that change the Ruling count; an assignment or requirement that merely cites its id does not.
def _touches(row, cid) -> bool:
    payload = row.get("payload") or {}
    key = CHANGE_ROWS.get(row.get("kind"))
    if key is not None:
        return payload.get(key) == cid and not payload.get("unchanged")
    return row.get("kind") == "remit_set" and any(
        isinstance(e, dict) and e.get("ruling") == cid for e in payload.get("carried_over") or [])


# A later reply ("no, keep it") voids an earlier approval, so the prompt must be Shawn's newest unanswered words.
def check_newest(rows, prompt_id) -> None:
    at = prompt_index(rows, prompt_id)
    cited = programme_journal._cited_ids(rows)
    later = next((r.get("prompt_id") for r in rows[at + 1:] if r.get("kind") == "prompt"
                  and programme_journal.prompt_origin(r) == "typed" and r.get("prompt_id") not in cited), None)
    if later:
        raise RulingError(f"prompt {prompt_id!r} was typed before prompt {later!r}, which nothing has cited yet; "
                          f"a Ruling change binds only on Shawn's newest typed prompt")


# Default-deny: the prompt must postdate every journaled change to the Ruling, so words Shawn typed about an
# older version never approve a newer one.
def check_fresh(rows, cid, prompt_id) -> None:
    at = prompt_index(rows, prompt_id)
    changed = [i for i, row in enumerate(rows) if _touches(row, cid)]
    if changed and at < changed[-1]:
        raise RulingError(f"prompt {prompt_id!r} was typed before the latest change to {cid!r}; a Ruling "
                          "change binds only on a prompt Shawn typed after it was proposed")
    check_newest(rows, prompt_id)


def _approval_of(row):
    kind, payload = row.get("kind"), row.get("payload") or {}
    if kind == "ruling_recorded" and payload.get("state") == "accepted" and not payload.get("unchanged"):
        return payload.get("ruling_id")
    if kind == "context_accepted" and "decision_id" in payload:
        return payload["decision_id"]
    if kind == "ruling_closed":
        return payload.get("ruling_id")
    if kind == "rulings_carried":
        return ", ".join(payload.get("carried") or [])
    return None


def check_prompt_unused(rows, prompt_id) -> None:
    for row in rows:
        approved = _approval_of(row) if prompt_id in (row.get("cites") or []) else None
        if approved is not None:
            raise RulingError(f"prompt {prompt_id!r} already approved a Ruling change ({approved}); one typed "
                              "prompt approves one Ruling change")


# Runs on the journal as the approval row lands: a prompt journaled after a timed-out run-lock wait, or a
# second use, refuses the change before its record is written.
def recheck_approval(rows, row) -> None:
    if _approval_of(row) is None:
        return
    for prompt_id in row.get("cites") or []:
        check_newest(rows, prompt_id)
        check_prompt_unused(rows, prompt_id)


def check_approval(rows, cid, prompt_id) -> None:
    check_fresh(rows, cid, prompt_id)
    check_prompt_unused(rows, prompt_id)


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


# Must match the conflict test in programme_decisions.who_decides, or a worker acts where the PM may not.
def grant_conflicted(host, programme, ruling, item) -> bool:
    if ruling.get("effect") != "grant" or ruling.get("kind") is None:
        return False
    level = authority_level(host, programme, ruling["kind"], [item])
    return programme_decisions.narrower_than_baseline(level, ruling.get("baseline"))


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


# The PM picks a Ruling's id, so a prompt naming only the id proves nothing about a new grant or decided
# Ruling; Shawn's words must also name its kind and items. A new restrict only narrows the PM.
def _names_needed(content, delta, new) -> list:
    if new and content.get("effect") in NAMED_WHEN_NEW:
        return [content["kind"]] + [_named(t) for t in content.get("applies_to") or []]
    delta = pc._dict(delta)
    return [_named(t) for t in delta.get("names", delta.get("added")) or []] + list(delta.get("words") or [])


# A carried Ruling arrives with no items, so every item it is given is new here and must be named by
# Shawn's prompt, whatever its effect; accept-context reads the same names.
def _carried_delta(content) -> dict:
    items = list(content["applies_to"])
    return {"added": items, "removed": [], "removed_limits": [], "until": None, "names": items, "words": [],
            "wider": False}


def _record(host, programme, rec, cid, content, prompt, *, correction=None) -> dict:
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
    carried = pc._dict(revisions[-1]).get("carried") if revisions and current is None else None
    delta = _carried_delta(content) if carried else pc.ruling_delta(current, content)
    accept = bool(prompt) and not (delta and delta["wider"])
    if accept:
        check_approval(programme_journal.read(rec["run_id"]), cid, prompt["prompt_id"])
    if prompt and not correction:
        host.require_named(prompt, cid, *_names_needed(content, delta if carried else None, current is None))
    revisions = ctx["decisions"].setdefault(cid, revisions)
    revision = pc._append(revisions, content, prompt, accept=accept, delta=delta)
    revision.update(quote=prompt and prompt["quote"], replies_to=correction, baseline=None)
    if carried:
        revision["carried"] = carried
    if revision["state"] == "accepted":
        _activate(host, programme, revision, prompt, baseline=pc._dict(current).get("baseline"))
    return dict(out, rev=revision["rev"], state=revision["state"], unchanged=False, delta=delta,
                source=revision["source"], baseline=revision["baseline"])


def _correction(host, programme, rec, cid, base, anchor_id, prompt) -> dict:
    found = anchor(programme, anchor_id)
    check_anchor_order(programme_journal.read(rec["run_id"]), anchor_id, prompt["prompt_id"])
    kind = programme_decisions.check_kind(found["kind"])
    target = found["item"] or pc.PROGRAMME_SCOPE
    out = _record(host, programme, rec, cid, dict(base, kind=kind, applies_to=[target]), prompt,
                  correction=anchor_id)
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
        return _record(host, programme, rec, cid, content, prompt)

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
            check_approval(programme_journal.read(rec["run_id"]), cid, prompt["prompt_id"])
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
        # accept-context is a pick verb for requirements, but a Ruling binds only on words Shawn typed (R5).
        if kind == "decisions" and prompt.get("origin") != "typed":
            raise RulingError(f"accepting Ruling {cid!r} needs a typed prompt; prompt {prompt['prompt_id']!r} is "
                              f"{'a pick' if prompt.get('origin') == 'picked' else 'an accepted suggestion'}")
        if revision.get("carried") and not revision.get("applies_to"):
            raise RulingError(f"bind carried Ruling {cid} with record-ruling naming its items")
        delta = pc._dict(revision.get("delta"))
        if revision.get("effect") == "grant" and delta.get("wider") and "words" not in delta:
            raise RulingError(f"the pending revision of Ruling {cid!r} was recorded before a widening kept the "
                              "limits it drops and its end date for Shawn to name; re-record it with record-ruling")
        if kind == "decisions":
            check_approval(programme_journal.read(rec["run_id"]), cid, prompt["prompt_id"])
        prior = pc.in_force(ctx[kind][cid])
        host.require_named(prompt, cid, *_names_needed(revision, revision.get("delta"), kind == "decisions"
                                                       and prior is None))
        pc._accept(ctx[kind][cid], revision, prompt)
        if revision.get("effect") in pc.EFFECTS:
            # Only a widening re-baselines; a narrowing must not clear an open Ruling conflict.
            _activate(host, programme, revision, prompt,
                      baseline=None if delta.get("wider") else pc._dict(prior).get("baseline"))
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
     "not name the id, or for a new grant or decided Ruling its kind and every item too; a prompt that would "
     "bind the change but was typed before the Ruling's latest journaled change or before a typed prompt "
     "nothing has cited yet, or already approved a Ruling change. Without a prompt it "
     "waits for accept-context. A widening (a grant that adds items, drops a limit or ends later; a restrict "
     "that loses items, drops a limit or ends sooner) waits too, while the prior revision stays in force. "
     "With --replies-to the anchor gives the item and kind, the prompt must come after the anchor and approve "
     "no other Ruling change, and the Ruling applies at once with a notice."),
    ("close-ruling", _h_close_ruling,
     "<id> --as fulfilled|withdrawn [--why <text>] [--prompt <id>] [--origin pm|ui] [--run <id>]",
     "no Ruling in force or pending; --as fulfilled without --why; --as withdrawn, or closing a restrict or a decided "
     "Ruling, without a typed prompt naming the id; a prompt typed before the Ruling's latest change or before "
     "a typed prompt nothing has cited yet, or that already approved a Ruling change. Closing as fulfilled never counts as a beat."),
    ("accept-context", _h_accept_context, "<decision-or-requirement-id> --prompt <id> [--run <id>]",
     "no pending revision; a pick or accepted suggestion for a Ruling (a requirement takes one); a prompt "
     "that is not typed, came from a legacy journal or an obsolete writer, or does not name the id and every "
     "target the revision adds (for a Ruling, every item it gives the PM; for a grant revision, each limit it "
     "drops and its new end date as YYYY-MM-DD or 'no end date'; for a new grant or decided Ruling its kind); "
     "for a Ruling, a prompt typed before the pending revision was recorded or before a typed prompt nothing "
     "has cited yet, or that already approved a Ruling change; a pending wider grant recorded before its dropped limits and end date were kept (re-record it); "
     "a carried Ruling that has no items yet. A grant that becomes active records the Authority level for its "
     "kind as its baseline; accepting a narrowing keeps the prior baseline."),
)


def build_verbs(host) -> dict:
    return {name: host._Verb(functools.partial(handler, host), args, rejects=rejects)
            for name, handler, args, rejects in _SPECS}
