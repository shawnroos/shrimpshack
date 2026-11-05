#!/usr/bin/env python3
"""Picker text for approvals that change the behaviour, ritual and carry-over stores."""

from __future__ import annotations

import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

programme_offer_rendering = load_lib_module("programme_offer_rendering")

OfferError = programme_offer_rendering.OfferError
_rendered = programme_offer_rendering.rendered
_layered = programme_offer_rendering.layered
_whole_set = programme_offer_rendering.whole_set


def _short(digest) -> str:
    return str(digest).split(":")[-1][:6]


def _joined(lines) -> str:
    return "; ".join(str(line) for line in lines or [])


def _when_text(entry):
    when = entry.get("when")
    return when.get("text") if isinstance(when, dict) else when


def _behaviour_text(entry) -> str:
    return (f"When {_when_text(entry)}. Do: {_joined(entry.get('do')) or 'nothing'}. "
            f"Don't: {_joined(entry.get('dont')) or 'nothing'}.")


def _ritual_text(entry) -> str:
    check = (entry.get("check") or {}).get("name")
    return (f"When {_when_text(entry)}. Steps: {_joined(entry.get('steps'))}." + (f" Check: {check}." if check else "")
            + (f" Offers: {_joined(entry.get('offers'))}." if entry.get("offers") else ""))


def _behaviour_fields(cmd) -> dict:
    return {"when": cmd.opt("when"), "do": cmd.many("do"), "dont": cmd.many("dont")}


def _ritual_fields(cmd) -> dict:
    return {"when": cmd.opt("when"), "steps": cmd.many("step"), "offers": cmd.many("offer"),
            "check": {"name": cmd.opt("check")} if cmd.opt("check") else None}


def _recorder(noun, module_name, text_of, fields_of, shown=()):
    def render(cmd, programme) -> dict:
        multi = getattr(load_lib_module(module_name), "RECORD_MULTI", ())
        ident = cmd.opt("from-proposal")
        if ident:
            entry = load_lib_module(module_name)._programme_entry(programme, ident)
            if entry is None or entry.get("state") != "proposed":
                raise OfferError(f"no proposed {noun} {ident!r}")
            return _rendered(f"Apply drafted {noun} {ident}", f"{text_of(entry)} {cmd.extras('from-proposal', multi=multi)}", entry)
        if not cmd.opt("when"):
            raise OfferError(f"usage: record-{noun} --when <text> ... or --from-proposal <id>")
        text = f"{text_of(fields_of(cmd))} {cmd.extras(*shown, multi=multi)}"
        digest = programme_offer_rendering.programme_journal.canonical_sha(text)[len("sha256:"):][:6]
        return _rendered(programme_offer_rendering.fitting(f"Record {noun}: {cmd.opt('when')}", f"Record {noun} {digest}"),
                         text)
    return render


def _retire_behaviour(cmd, programme) -> dict:
    ident = cmd.first("<id> --as retired|undone")
    how = cmd.one_of("as", ("retired", "undone"))
    entry = _layered("programme_behaviours", programme, ident)
    if entry is None:
        raise OfferError(f"no behaviour {ident!r}")
    word = "Retire" if how == "retired" else "Undo"
    return _rendered(f"{word} behaviour {ident}", _behaviour_text(entry), entry)


def _path(cmd) -> str:
    return cmd.opt("file", cap=None)


def _draft(cmd, bid) -> tuple:
    files = load_lib_module("programme_behaviour_file_verbs")
    path = _path(cmd)
    text = cmd.doc
    if text is None:
        if path == "-":
            raise OfferError("an offer needs the draft in a file it can read again; give --file <path>")
        text = files._draft_text({"file": path})
    return text, files.draft_hash(text, bid)


def _adopt_file(cmd, _programme) -> dict:
    bid = cmd.first("<id> --file <path>")
    _text, digest = _draft(cmd, bid)
    return _rendered(f"Adopt behaviour file {bid} (content {_short(digest)})",
                     f"Writes the draft shown in chat, from {_path(cmd)}, to your personal behaviours folder.",
                     {"hash": digest})


def _copy_default(cmd, _programme) -> dict:
    bid = cmd.first("<id>")
    digest = load_lib_module("programme_behaviour_file_verbs").shipped_hash(bid)
    return _rendered(f"Copy default {bid} to your personal folder",
                               "Your copy then applies in place of the shipped one, and you can edit it.",
                               {"hash": digest})


def _settle_default(cmd, _programme) -> dict:
    bid = cmd.first("<id> --as keep|take|merge")
    mode = cmd.one_of("as", ("keep", "take", "merge"))
    shipped = load_lib_module("programme_behaviour_file_verbs").shipped_hash(bid)
    if mode == "keep":
        return _rendered(f"Keep your copy of default {bid}", "Your copy stays. The shipped change is marked seen.",
                                {"shipped": shipped})
    if mode == "take":
        return _rendered(f"Take the new default {bid}", "Removes your copy, so the shipped one applies.",
                                {"shipped": shipped})
    _text, digest = _draft(cmd, bid)
    return _rendered(f"Merge default {bid} (content {_short(digest)})",
                     f"Replaces your copy with the merged draft shown in chat, from {_path(cmd)}.",
                            {"shipped": shipped, "hash": digest})


def _ritual_rows(cmd, programme) -> list:
    return load_lib_module("programme_ritual_file_verbs").file_rows(
        programme, cmd.first("<repo key>/<id>"), load_lib_module("programme_approval").prompt_lookup)


def _adopt_ritual_file(cmd, programme) -> dict:
    row = load_lib_module("programme_ritual_file_verbs").proposed_row(_ritual_rows(cmd, programme))
    if row is None:
        raise OfferError(f"no proposed ritual file {cmd.pos[0]!r}")
    return _rendered(f"Adopt ritual file {row['id']} (content {row['hash_short']})",
                     _ritual_text(row["entry"]), {"hash": row["hash"], "state": row["state"]})


def _decline_ritual_file(cmd, programme) -> dict:
    row = load_lib_module("programme_ritual_file_verbs").declinable_row(_ritual_rows(cmd, programme))
    if row is None:
        raise OfferError(f"no ritual file {cmd.pos[0]!r} to decline")
    return _rendered(f"Decline ritual file {row['id']} (content {row['hash_short']})",
                     "Takes it out of force for this programme. A changed file proposes it again.",
                     {"hash": row["hash"], "state": row["state"]})


def _carry(cmd, programme) -> dict:
    cmd.first("<ruling-id>...")
    ids = list(dict.fromkeys(cmd.pos))
    label = _whole_set(f"Carry Rulings {' and '.join(ids)} to the next programme", ids)
    now = load_lib_module("run_record_core").now_iso()
    active = {r["id"]: r for r in load_lib_module("programme_predicate").offerable_rulings(programme, now)}
    missing = [rid for rid in ids if rid not in active]
    if missing:
        raise OfferError(f"no active Ruling {' or '.join(missing)}")
    return _rendered(label, "; ".join(f"{rid}: {active[rid].get('scope')}" for rid in ids),
                            {rid: active[rid].get("rev") for rid in ids})


RENDERERS = {
    "adopt-behaviour-file": _adopt_file,
    "adopt-ritual-file": _adopt_ritual_file,
    "carry-rulings": _carry,
    "copy-default": _copy_default,
    "decline-ritual-file": _decline_ritual_file,
    "record-behaviour": _recorder("behaviour", "programme_behaviours", _behaviour_text, _behaviour_fields,
                                  ("when", "do", "dont")),
    "record-ritual": _recorder("ritual", "programme_rituals", _ritual_text, _ritual_fields,
                               ("when", "step", "offer", "check")),
    "retire-behaviour": _retire_behaviour,
    "settle-default-update": _settle_default,
}
