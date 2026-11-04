#!/usr/bin/env python3
"""Picker text for approvals that change the behaviour, ritual and carry-over stores, and whose wording they record."""

from __future__ import annotations

import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402


def _offers():
    return load_lib_module("programme_offers")


def require_bound(prompt, error) -> None:
    # Only an approval bound to an offer carries `named`: whoever removes that key must keep this refusal working.
    if not prompt.get("named"):
        raise error(f"prompt {prompt['prompt_id']!r} does not answer an offer of this command, so it approves nothing; "
                    "run `programme.sh offer`, ask with the input it prints, then cite his answer")


def source_of(prompt) -> dict:
    journal = load_lib_module("programme_journal")
    # An old-label pick carries no reading, and the PM wrote the words it picked.
    unbound_pick = prompt.get("origin") == "picked" and not prompt.get("reading")
    return {"prompt_id": prompt["prompt_id"], "quote": journal.redact(prompt["quote"]),
            "wording": journal.PM_DRAFT if unbound_pick else journal.wording_of(prompt)}


def _short(digest) -> str:
    return str(digest).split(":")[-1][:6]


def _joined(lines) -> str:
    return "; ".join(str(line) for line in lines or [])


def _behaviour_text(entry) -> str:
    when = entry.get("when")
    text = when.get("text") if isinstance(when, dict) else when
    return f"When {text}. Do: {_joined(entry.get('do')) or 'nothing'}. Don't: {_joined(entry.get('dont')) or 'nothing'}."


def _ritual_text(entry) -> str:
    when = entry.get("when")
    text = when.get("text") if isinstance(when, dict) else when
    check = (entry.get("check") or {}).get("name")
    return (f"When {text}. Steps: {_joined(entry.get('steps'))}." + (f" Check: {check}." if check else "")
            + (f" Offers: {_joined(entry.get('offers'))}." if entry.get("offers") else ""))


def _proposal(cmd, programme, module_name, noun):
    ident = cmd.opt("from-proposal")
    entry = load_lib_module(module_name)._programme_entry(programme, ident)
    if entry is None or entry.get("state") != "proposed":
        raise _offers().OfferError(f"no proposed {noun} {ident!r}")
    return ident, entry


def _record_behaviour(cmd, programme) -> dict:
    offers = _offers()
    if cmd.opt("from-proposal"):
        ident, entry = _proposal(cmd, programme, "programme_behaviours", "behaviour")
        return offers._rendered(f"Apply drafted behaviour {ident}", _behaviour_text(entry), entry)
    if not cmd.opt("when"):
        raise offers.OfferError("usage: record-behaviour --when <text> ... or --from-proposal <id>")
    fields = {"when": cmd.opt("when"), "do": cmd.opts.get("do"), "dont": cmd.opts.get("dont")}
    return offers._rendered(f"Record behaviour: {cmd.opt('when')}", _behaviour_text(fields))


def _record_ritual(cmd, programme) -> dict:
    offers = _offers()
    if cmd.opt("from-proposal"):
        ident, entry = _proposal(cmd, programme, "programme_rituals", "ritual")
        return offers._rendered(f"Apply drafted ritual {ident}", _ritual_text(entry), entry)
    if not cmd.opt("when"):
        raise offers.OfferError("usage: record-ritual --when <text> ... or --from-proposal <id>")
    fields = {"when": cmd.opt("when"), "steps": cmd.opts.get("step"), "offers": cmd.opts.get("offer"),
              "check": {"name": cmd.opt("check")} if cmd.opt("check") else None}
    return offers._rendered(f"Record ritual: {cmd.opt('when')}", _ritual_text(fields))


def _retire_behaviour(cmd, programme) -> dict:
    offers = _offers()
    ident = cmd.first("<id> --as retired|undone")
    how = cmd.one_of("as", ("retired", "undone"))
    entry = offers._layered("programme_behaviours", programme, ident)
    if entry is None:
        raise offers.OfferError(f"no behaviour {ident!r}")
    word = "Retire" if how == "retired" else "Undo"
    return offers._rendered(f"{word} behaviour {ident}", _behaviour_text(entry), entry)


def _draft(cmd, bid) -> tuple:
    offers = _offers()
    files = load_lib_module("programme_behaviour_file_verbs")
    text = offers._CONTENT["doc"]
    if text is None:
        if cmd.opt("file") == "-":
            raise offers.OfferError("an offer needs the draft in a file it can read again; give --file <path>")
        text = files._draft_text({"file": cmd.opt("file")})
    return text, files.draft_hash(text, bid)


def _adopt_file(cmd, _programme) -> dict:
    offers = _offers()
    bid = cmd.first("<id> --file <path>")
    _text, digest = _draft(cmd, bid)
    return offers._rendered(f"Adopt behaviour file {bid} (content {_short(digest)})",
                            "Writes the draft shown in chat to your personal behaviours folder.", {"hash": digest})


def _copy_default(cmd, _programme) -> dict:
    bid = cmd.first("<id>")
    digest = load_lib_module("programme_behaviour_file_verbs").shipped_hash(bid)
    return _offers()._rendered(f"Copy default {bid} to your personal folder",
                               "Your copy then applies in place of the shipped one, and you can edit it.",
                               {"hash": digest})


def _settle_default(cmd, _programme) -> dict:
    offers = _offers()
    bid = cmd.first("<id> --as keep|take|merge")
    mode = cmd.one_of("as", ("keep", "take", "merge"))
    shipped = load_lib_module("programme_behaviour_file_verbs").shipped_hash(bid)
    if mode == "keep":
        return offers._rendered(f"Keep your copy of default {bid}", "Your copy stays. The shipped change is marked seen.",
                                {"shipped": shipped})
    if mode == "take":
        return offers._rendered(f"Take the new default {bid}", "Removes your copy, so the shipped one applies.",
                                {"shipped": shipped})
    _text, digest = _draft(cmd, bid)
    return offers._rendered(f"Merge default {bid} (content {_short(digest)})",
                            "Replaces your copy with the merged draft shown in chat.",
                            {"shipped": shipped, "hash": digest})


def _ritual_rows(cmd, programme) -> list:
    return load_lib_module("programme_ritual_file_verbs").file_rows(
        programme, cmd.first("<repo key>/<id>"), load_lib_module("programme_approval").prompt_lookup)


def _adopt_ritual_file(cmd, programme) -> dict:
    rows = [row for row in _ritual_rows(cmd, programme) if row["state"] in ("proposed", "changed")]
    if not rows:
        raise _offers().OfferError(f"no proposed ritual file {cmd.pos[0]!r}")
    row = rows[0]
    return _offers()._rendered(f"Adopt ritual file {row['id']} (content {row['hash_short']})",
                               _ritual_text(row["entry"]), {"hash": row["hash"], "state": row["state"]})


def _decline_ritual_file(cmd, programme) -> dict:
    rows = _ritual_rows(cmd, programme)
    current = [row for row in rows if row["state"] in ("proposed", "changed", "declined")] or rows
    if not current:
        raise _offers().OfferError(f"no ritual file {cmd.pos[0]!r} to decline")
    row = current[0]
    return _offers()._rendered(f"Decline ritual file {row['id']} (content {row['hash_short']})",
                               "Takes it out of force for this programme. A changed file proposes it again.",
                               {"hash": row["hash"], "state": row["state"]})


def _carry(cmd, programme) -> dict:
    offers = _offers()
    cmd.first("<ruling-id>...")
    ids = list(dict.fromkeys(cmd.pos))
    label = offers._whole_set(f"Carry Rulings {' and '.join(ids)} to the next programme", ids)
    now = load_lib_module("run_record_core").now_iso()
    active = {r["id"]: r for r in load_lib_module("programme_predicate").offerable_rulings(programme, now)}
    missing = [rid for rid in ids if rid not in active]
    if missing:
        raise offers.OfferError(f"no active Ruling {' or '.join(missing)}")
    return offers._rendered(label, "; ".join(f"{rid}: {active[rid].get('scope')}" for rid in ids),
                            {rid: active[rid].get("rev") for rid in ids})


RENDERERS = {
    "adopt-behaviour-file": _adopt_file,
    "adopt-ritual-file": _adopt_ritual_file,
    "carry-rulings": _carry,
    "copy-default": _copy_default,
    "decline-ritual-file": _decline_ritual_file,
    "record-behaviour": _record_behaviour,
    "record-ritual": _record_ritual,
    "retire-behaviour": _retire_behaviour,
    "settle-default-update": _settle_default,
}
