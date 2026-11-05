#!/usr/bin/env python3
"""The only sanctioned writers of the personal behaviours folder.

Every verb here but ``--as shown`` needs Shawn's answer to an offer of that command. For ``adopt-behaviour-file``
and ``settle-default-update --as merge`` the offer stores the hash of the draft shown in chat, so a changed draft is
refused. ``--as shown`` only records that the PM displayed a shipped change. ``behaviours-seen.json``
maps each id to ``seen`` (the shipped hash Shawn last settled) and ``shown`` (the shipped hash the
PM last displayed).
"""

from __future__ import annotations

import functools
import json
import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

programme_behaviours = load_lib_module("programme_behaviours")
programme_offers = load_lib_module("programme_offers")
programme_behaviour_files = load_lib_module("programme_behaviour_files")
programme_home = load_lib_module("programme_home")
programme_protocol = load_lib_module("programme_protocol")
run_record_core = load_lib_module("run_record_core")

BehaviourError = programme_behaviours.BehaviourError
ADOPTED = programme_behaviours.APPROVAL_KIND
LOCK_NAME = programme_behaviour_files.LOCK_NAME
MODES = ("shown", "keep", "take", "merge")
# Shares the seen document with the per-id records; ids start with a letter, so no behaviour can collide.
SPENT = "_approvals_spent"
MAX_BYTES = 64 * 1024
seen_path = programme_behaviour_files.seen_path


def _target(bid) -> str:
    return f"behaviour-file:{bid}"


def _personal_path(bid) -> str:
    return os.path.join(programme_behaviour_files.personal_dir(), bid + ".md")


def _shipped_path(bid) -> str:
    return os.path.join(programme_behaviour_files.shipped_dir(), bid + ".md")


def _valid(bid, build) -> dict:
    try:
        return build()
    except programme_protocol._Reject as exc:
        raise BehaviourError(f"behaviour file {bid}.md is not valid: {exc.reason}"
                             + (f" ({exc.detail})" if exc.detail else ""))


def draft_hash(text, bid) -> str:
    return programme_behaviour_files.entry_hash(
        _valid(bid, lambda: programme_behaviour_files.entry_from_text(text, bid, "personal")))


def _shipped_read(bid) -> tuple:
    # One read: the approved hash must describe the very bytes copy-default writes.
    if not os.path.isfile(_shipped_path(bid)):
        raise BehaviourError(f"no shipped behaviour {bid!r}")
    text, mtime = _valid(bid, lambda: programme_behaviour_files.read_file(_shipped_path(bid)))
    entry = _valid(bid, lambda: programme_behaviour_files.entry_from_text(text, bid, "shipped", mtime))
    return text, programme_behaviour_files.entry_hash(entry)


def shipped_hash(bid) -> str:
    return _shipped_read(bid)[1]


def _locked(body):
    os.makedirs(programme_home.programmes_dir(), exist_ok=True)
    return run_record_core._flock_run(os.path.join(programme_home.programmes_dir(), LOCK_NAME), body)


def _atomic(path, text) -> None:
    folder = os.path.dirname(path)
    os.makedirs(folder, exist_ok=True)
    programme_home.atomic_write(path, lambda fh: fh.write(text), ".behaviour.", folder)


def _read_text(path):
    # isfile first: opening a FIFO named <id>.md would block.
    if not os.path.isfile(path):
        return None
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except (OSError, UnicodeDecodeError):
        return None


def _snapshot(path):
    if not os.path.isfile(path):
        return None
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except (OSError, UnicodeDecodeError) as exc:
        raise BehaviourError(f"cannot read {path} to keep it safe; nothing was changed: {exc}")


# The file change and the seen record are two writes. A failed record puts the file back, so a
# retry starts from the state the verb found and a take or merge never loses the user's copy.
def _with_rollback(path, change, record) -> None:
    before = _snapshot(path)
    change()
    try:
        record()
    except BaseException:
        if before is None:
            if os.path.lexists(path):
                os.unlink(path)
        else:
            _atomic(path, before)
        raise


def _seen_doc() -> dict:
    path = seen_path()
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except FileNotFoundError:
        return {}
    except (OSError, ValueError) as exc:
        raise BehaviourError(f"{path} is unreadable; not overwriting it: {exc}")
    if not isinstance(doc, dict) or not all(isinstance(v, dict) for v in doc.values()):
        raise BehaviourError(f"{path} is not a seen record; not overwriting it")
    return doc


def _use_key(prompt, verb, bid, mode, digest) -> str:
    return "|".join((prompt["prompt_id"], verb, bid, mode, digest))


def _unspent(used) -> None:
    if used in (_seen_doc().get(SPENT) or {}):
        raise BehaviourError("this approval was already used for this change; ask Shawn to approve it again")


# The spent mark is written in the same file write as seen, so a write that failed spends nothing.
def _store_seen(doc, used) -> None:
    if used:
        doc.setdefault(SPENT, {})[used] = {"at": run_record_core.now_iso()}
    _atomic(seen_path(), json.dumps(doc, indent=2, sort_keys=True) + "\n")


def _spend(used) -> None:
    _store_seen(_seen_doc(), used)


def _record(bid, used=None, **fields) -> None:
    doc = _seen_doc()
    doc[bid] = dict(doc.get(bid) or {}, **fields)
    _store_seen(doc, used)


def _draft_text(opts) -> str:
    path = opts.get("file")
    if not path:
        raise ValueError("--file <path> is required: the drafted behaviour file ('-' reads stdin)")
    try:
        if path == "-":
            text = sys.stdin.read(MAX_BYTES + 1)
        else:
            with open(path, encoding="utf-8") as fh:
                text = fh.read(MAX_BYTES + 1)
    except (OSError, UnicodeDecodeError) as exc:
        raise ValueError(f"cannot read the draft {path}: {exc}")
    if len(text.encode("utf-8")) > MAX_BYTES:
        raise ValueError(f"the draft is over {MAX_BYTES} bytes")
    return text


def _write_file(bid, text, *, replace, used) -> None:
    def body():
        path = _personal_path(bid)
        _unspent(used)
        if os.path.exists(path) and not replace and _read_text(path) != text:
            raise BehaviourError(f"{bid}.md already exists in the personal behaviours folder; "
                                 "settle-default-update --as merge replaces it")
        _with_rollback(path, lambda: _atomic(path, text), lambda: _spend(used))

    _locked(body)


def _adopted(bid, digest, **extra) -> dict:
    return {"entry": "file", "how": "file", "target": _target(bid), "hash": digest, "behaviour": bid, **extra}


def _h_adopt(host, argv):
    positional, opts = host._parse(argv, values=("run", "prompt", "file"))
    if len(positional) != 1:
        raise ValueError("usage: adopt-behaviour-file <id> --file <path> --prompt <id>")
    bid = programme_behaviours.check_id(positional[0])
    text = _draft_text(opts)

    def change(programme, prompt, rec):
        # The stored entry would shadow the file at load, so the file is refused up front.
        if any(isinstance(e, dict) and e.get("id") == bid for e in programme_behaviours.read_store()["personal"]):
            raise BehaviourError(f"a stored personal behaviour {bid!r} already exists; a file with this id "
                                 "would be rejected as shadowed")
        digest = draft_hash(text, bid)
        _write_file(bid, text, replace=False, used=_use_key(prompt, "adopt-behaviour-file", bid, "adopt", digest))
        limit = programme_behaviour_files.parse_text(text, bid).get("limit")
        asks = load_lib_module("programme_checks").limit_asks(programme, None, [limit] if limit else [])
        return _adopted(bid, digest, path=_personal_path(bid), **({"limit_asks": asks} if asks else {}))

    return host._write(opts, change, ADOPTED, prompt_id=opts.get("prompt"), needs_prompt=True,
                       verb="adopt-behaviour-file", target=bid, content=text)


def _h_copy(host, argv):
    positional, opts = host._parse(argv, values=("run", "prompt"))
    if len(positional) != 1:
        raise ValueError("usage: copy-default <id> --prompt <id>")
    bid = programme_behaviours.check_id(positional[0])

    def change(programme, prompt, rec):
        text, digest = _shipped_read(bid)
        used = _use_key(prompt, "copy-default", bid, "copy", digest)
        path = _personal_path(bid)

        def body():
            _unspent(used)
            if os.path.exists(path):
                raise BehaviourError(f"{bid}.md already exists in the personal behaviours folder")
            _with_rollback(path, lambda: _atomic(path, text), lambda: _record(bid, used=used, seen=digest))

        _locked(body)
        return _adopted(bid, digest, path=path)

    return host._write(opts, change, ADOPTED, prompt_id=opts.get("prompt"), needs_prompt=True,
                       verb="copy-default", target=bid)


def _settle(prompt, bid, mode, text) -> dict:
    digest = shipped_hash(bid)
    if mode == "shown":
        _locked(lambda: _record(bid, shown=digest))
        return {"behaviour": bid, "as": mode, "shipped_hash": digest}
    if not os.path.isfile(_personal_path(bid)):
        raise BehaviourError(f"no personal copy of {bid!r} to settle")
    written = draft_hash(text, bid) if mode == "merge" else digest
    used = _use_key(prompt, "settle-default-update", bid, mode, written)

    def body():
        # Before any file change: a corrupt seen file or a spent approval must refuse with nothing half done.
        _unspent(used)
        path = _personal_path(bid)
        if mode == "keep":
            _record(bid, used=used, seen=digest)
            return
        change = (lambda: _atomic(path, text)) if mode == "merge" else (lambda: os.unlink(path))
        _with_rollback(path, change, lambda: _record(bid, used=used, seen=digest))

    _locked(body)
    return _adopted(bid, written, **{"as": mode, "shipped_hash": digest})


def _h_settle(host, argv):
    positional, opts = host._parse(argv, values=("run", "prompt", "as", "file"))
    if len(positional) != 1 or opts.get("as") not in MODES or (opts.get("file") and opts["as"] != "merge"):
        raise ValueError("usage: settle-default-update <id> --as shown|keep|take|merge [--prompt <id>] "
                         "[--file <path>] (--file only with merge; shown needs no --prompt)")
    bid, mode = programme_behaviours.check_id(positional[0]), opts["as"]
    if mode != "shown" and not opts.get("prompt"):
        raise ValueError(f"--as {mode} needs --prompt <id> of Shawn's answer")
    text = _draft_text(opts) if mode == "merge" else None

    def change(programme, prompt, _rec):
        return _settle(prompt, bid, mode, text)

    shown = mode == "shown"
    return host._write(opts, change, "behaviour_default_shown" if shown else ADOPTED,
                       prompt_id=opts.get("prompt"), needs_prompt=not shown, journal=not shown,
                       verb="settle-default-update", target=bid, content=text)


_SPECS = (
    ("adopt-behaviour-file", _h_adopt, "<id> --file <path> --prompt <id>",
     "a session that does not drive the programme; a prompt that does not answer an offer of this command; a draft "
     "that changed since that offer or fails the behaviour file check; an id that already has a personal file or a "
     "stored personal behaviour. Writes <id>.md into the personal behaviours folder and journals rule_adopted (how "
     "file)."),
    ("copy-default", _h_copy, "<id> --prompt <id>",
     "a prompt that does not answer an offer of this command; an id with no shipped file; an id that "
     "already has a personal file. Copies the shipped file into the personal folder, records seen in "
     "behaviours-seen.json and journals rule_adopted (how file)."),
    ("settle-default-update", _h_settle, "<id> --as shown|keep|take|merge [--prompt <id>] [--file <path>]",
     "an id with no shipped file or no personal copy; for keep, take and merge a prompt that does not answer an "
     "offer of this command; for merge a draft that changed since that offer. shown "
     "records the displayed shipped hash and needs no prompt; keep records seen; take removes the personal file "
     "and records seen; merge writes the approved content and records seen."),
)


def build_verbs(host) -> dict:
    return {name: host._Verb(functools.partial(handler, host), args, rejects=rejects)
            for name, handler, args, rejects in _SPECS}
