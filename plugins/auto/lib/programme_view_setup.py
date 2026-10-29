#!/usr/bin/env python3
"""The view's setup part: the walkthrough's steps, in and out lists, until the agreement is accepted."""

from __future__ import annotations

import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

programme_home = load_lib_module("programme_home")
programme_proposals = load_lib_module("programme_proposals")
programme_protocol = load_lib_module("programme_protocol")
programme_view_work = load_lib_module("programme_view_work")
programme_approval = load_lib_module("programme_approval")

UNSET_BY = (None, "default", "proposal")
SOURCES = {"carried_over": "carried over", "proposal": "PM proposal"}
PROPOSAL_SOURCES = {"pm": "PM proposal", "ui": "proposed in the pane"}
RULINGS, SHARED, ITEMS, ACCEPT = "rulings", "shared", "items", "accept"
USING_EXISTING = "using existing"
REPLIES = {RULINGS: "approve the proposed rulings", SHARED: "adopt the proposed shared rules"}
SEEN_PARTS = ("tabs", "repos", "tracker")
# Its only option defers to the personal protocol, which every programme shares (`adopt-autonomy`).
SHARED_TERMS = ("autonomy",)


_dict = programme_view_work._dict


def _list(value) -> list:
    return value if isinstance(value, list) else []


def _strings(value) -> list:
    return [v for v in _list(value) if isinstance(v, str) and v]


def _step(key, label, group, done, values, recommendation, source, needs_typed=False, pending=False) -> dict:
    return {"key": key, "label": label, "group": group, "done": done, "values": values,
            "recommendation": recommendation, "recommendation_source": source, "needs_typed": needs_typed,
            "reply": REPLIES.get(key) if needs_typed and pending and not done else None}


def _term_step(key, term, kept) -> dict:
    guide = _dict(programme_home.TERM_GUIDE.get(key))
    proposal = _dict(term.get("proposal"))
    if proposal.get("state") == "pending":
        recommendation, source = proposal.get("value"), PROPOSAL_SOURCES.get(proposal.get("origin"), "PM proposal")
    elif term.get("set_by") in (None, "default"):
        recommendation, source = term.get("default", term.get("value")), "plugin default"
    else:
        recommendation, source = term.get("value"), SOURCES.get(term.get("set_by"), "set by Shawn")
    if isinstance(recommendation, list):
        recommendation = ", ".join(str(v) for v in recommendation) or "none"
    done = term.get("set_by") not in UNSET_BY or key in kept or programme_home.is_opt_in(key)
    out = _step(key, guide.get("label") or key.replace("_", " "),
                term.get("section") or guide.get("section") or key, done,
                programme_view_work._value_text(term), recommendation, source, needs_typed=key in SHARED_TERMS)
    out["options"] = [o["name"] for o in programme_view_work._options(programme_proposals.offered(term), guide)]
    return out


def _rulings_step(block, kept) -> dict:
    entries = programme_home.project_terms(block)
    proposed = [e for e in entries if e.get("set_by") == "proposal"]
    done = RULINGS in kept or (bool(entries) and not proposed)
    values = "; ".join(f"{e.get('area')}: {e.get('value')}" + (" (reserved)" if e.get("reserved") else "")
                       for e in entries) or "none"
    source = next((e.get("source") for e in proposed if e.get("source")), "PM proposal") if proposed else None
    return _step(RULINGS, "rulings and reserved areas", RULINGS, done, values,
                 f"{len(proposed)} proposed" if proposed else "none", source, needs_typed=True, pending=bool(proposed))


def _shared_step(block, kept, protocol) -> dict:
    personal = next((layer for layer in protocol["layers"] if layer["layer"] == "personal"), {})
    using = personal.get("status") == "loaded"
    proposed = programme_protocol.proposed_rules({"programme": block})
    done = (using or SHARED in kept) and not proposed
    rules = ", ".join(sorted(protocol["rules"])) or "none"
    return _step(SHARED, "shared settings", SHARED, done, USING_EXISTING if using else f"plugin defaults: {rules}",
                 f"{len(proposed)} proposed rules" if proposed else "plugin defaults",
                 "personal file" if using else "plugin default", needs_typed=True, pending=bool(proposed))


def _seen_items(seen, block) -> list:
    adopted = _dict(block.get("items"))
    out = []
    for entry in _list(seen.get("items")):
        entry = _dict(entry)
        if isinstance(entry.get("item"), str):
            out.append({"item": entry["item"], "title": entry.get("title") or "", "pane": entry.get("pane"),
                        "session": entry.get("session"), "adopted": entry["item"] in adopted})
    return out


def _probed(seen) -> bool:
    return isinstance(seen.get("items"), list)


def _items_step(seen, block, kept) -> dict:
    items = _seen_items(seen, block)
    waiting = [i for i in items if not i["adopted"]]
    probed = _probed(seen)
    out = _step(ITEMS, "items to adopt", ITEMS, ITEMS in kept or (probed and not waiting),
                f"{len(items) - len(waiting)} adopted of {len(items)}" if probed else "not probed yet",
                f"adopt {len(waiting)}" if waiting else "none", "sweep")
    out["items"] = items
    return out


def _repo_name(repo) -> str:
    repo = _dict(repo)
    return repo.get("github") or os.path.basename(str(repo.get("path") or ""))


def _scope_name(entry) -> str:
    entry = _dict(entry)
    return str(entry.get("key") or entry.get("name") or entry.get("id"))


def _tracker_names(tracker) -> set:
    names = set()
    for part in programme_home.TRACKER_SCOPE_PARTS:
        for entry in _list(_dict(tracker).get(part)):
            names.update(str(_dict(entry).get(k)) for k in ("key", "name", "id") if _dict(entry).get(k))
    return names


def _scope(block, seen) -> dict:
    remit = _dict(block.get("remit"))
    tabs_only = _dict(_dict(_dict(block.get("agreement")).get("terms")).get("remit")).get("value") == "tabs"
    tabs = _strings(remit.get("tabs")) if tabs_only else []
    repos = [_repo_name(r) for r in _list(remit.get("repos"))]
    tracker = _dict(remit.get("tracker"))
    covered = {name for r in _list(remit.get("repos")) for name in (_repo_name(r), _dict(r).get("path")) if name}
    tracked = _tracker_names(tracker)
    seen_parts = {part: _strings(seen.get(part)) for part in SEEN_PARTS}
    return {
        "in": {"spaces": [programme_home.space_label(_dict(s)) for s in _list(remit.get("spaces"))],
               "tabs": tabs, "repos": repos,
               "tracker": [_scope_name(e) for part in programme_home.TRACKER_SCOPE_PARTS
                           for e in _list(tracker.get(part))]},
        # Mirrors remit_texts: no remit repos reads as "any", so nothing seen is out.
        "out": {"tabs": [t for t in seen_parts["tabs"] if tabs_only and t not in tabs],
                "repos": [r for r in seen_parts["repos"] if covered and r not in covered],
                "tracker": [t for t in seen_parts["tracker"] if t not in tracked]},
        "probed": _probed(seen),
    }


def build(block, protocol=None) -> dict | None:
    agreement = _dict(block.get("agreement"))
    if agreement.get("accepted"):
        return None
    if protocol is None:
        protocol = programme_protocol.load()
    setup = _dict(block.get("setup"))
    seen, kept = _dict(setup.get("seen")), set(_strings(setup.get("kept")))
    terms = _dict(agreement.get("terms"))
    steps = [_term_step(key, _dict(terms[key]), kept) for key in programme_view_work._ordered_terms(terms)]
    accept = _step(ACCEPT, "accept", ACCEPT, False, "not accepted", "accept the agreement", None)
    digest = programme_approval.terms_digest(block)
    accept.update(terms_digest=digest, label=programme_approval.accept_label(block, digest))
    steps += [_rulings_step(block, kept), _shared_step(block, kept, protocol), _items_step(seen, block, kept), accept]
    unfinished = [s["key"] for s in steps if not s["done"]]
    current = setup.get("step") if setup.get("step") in unfinished else unfinished[0]
    for s in steps:
        s["state"] = "done" if s.pop("done") else ("current" if s["key"] == current else "upcoming")
    return {"current": current, "steps": steps, "scope": _scope(block, seen)}
