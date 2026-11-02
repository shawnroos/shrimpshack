#!/usr/bin/env python3
"""The only sanctioned writers of the personal behaviours folder.

``adopt-behaviour-file`` and ``settle-default-update --as merge`` write drafted content, and only
after Shawn's typed prompt approves the hash of exactly that content. ``copy-default`` and
``settle-default-update --as keep|take`` need a typed prompt that names the id and the mode.
``--as shown`` only records that the PM displayed a shipped change. ``behaviours-seen.json``
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
programme_behaviour_files = load_lib_module("programme_behaviour_files")
programme_home = load_lib_module("programme_home")
programme_journal = load_lib_module("programme_journal")
programme_protocol = load_lib_module("programme_protocol")
run_record_core = load_lib_module("run_record_core")

BehaviourError = programme_behaviours.BehaviourError
ADOPTED = programme_behaviours.APPROVAL_KIND
LOCK_NAME = programme_behaviour_files.LOCK_NAME
MODES = ("shown", "keep", "take", "merge")
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


def _record(bid, **fields) -> None:
    doc = _seen_doc()
    doc[bid] = dict(doc.get(bid) or {}, **fields)
    _atomic(seen_path(), json.dumps(doc, indent=2, sort_keys=True) + "\n")


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


def _approve(host, rec, prompt, bid, digest) -> None:
    host.require_named(prompt, bid)
    # A prompt Shawn typed can approve a draft by carrying its hash; an approval row keyed to the hash
    # (the _verify_adoption key) approves it too. named_text, not the quote: a picker question is
    # PM-written, so only Shawn's own answer may carry the hash.
    key = programme_protocol.approval_key(_target(bid), digest)
    row = host.prompt_lookup(rec["run_id"], prompt["prompt_id"]) or {}
    if key in (row.get("approved") or ()) or digest.split(":")[-1] in programme_journal.named_text(prompt).lower():
        return
    raise BehaviourError(
        f"prompt {prompt['prompt_id']!r} does not approve this content of {bid}.md; Shawn's typed "
        f"approval must name {bid} and carry the content hash {digest}")


def _write_file(bid, text, *, replace) -> None:
    def body():
        path = _personal_path(bid)
        if os.path.exists(path) and not replace and _read_text(path) != text:
            raise BehaviourError(f"{bid}.md already exists in the personal behaviours folder; "
                                 "settle-default-update --as merge replaces it")
        _atomic(path, text)

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
        _approve(host, rec, prompt, bid, digest)
        _write_file(bid, text, replace=False)
        return _adopted(bid, digest, path=_personal_path(bid))

    return host._write(opts, change, ADOPTED, prompt_id=opts.get("prompt"), needs_prompt=True,
                       verb="adopt-behaviour-file", target=bid)


def _h_copy(host, argv):
    positional, opts = host._parse(argv, values=("run", "prompt"))
    if len(positional) != 1:
        raise ValueError("usage: copy-default <id> --prompt <id>")
    bid = programme_behaviours.check_id(positional[0])

    def change(programme, prompt, rec):
        text, digest = _shipped_read(bid)
        host.require_named(prompt, bid)

        def body():
            _seen_doc()
            if os.path.exists(_personal_path(bid)):
                raise BehaviourError(f"{bid}.md already exists in the personal behaviours folder")
            _with_rollback(_personal_path(bid), lambda: _atomic(_personal_path(bid), text),
                           lambda: _record(bid, seen=digest))

        _locked(body)
        return _adopted(bid, digest, path=_personal_path(bid))

    return host._write(opts, change, ADOPTED, prompt_id=opts.get("prompt"), needs_prompt=True,
                       verb="copy-default", target=bid)


def _settle(host, rec, prompt, bid, mode, text) -> dict:
    digest = shipped_hash(bid)
    if mode == "shown":
        _locked(lambda: _record(bid, shown=digest))
        return {"behaviour": bid, "as": mode, "shipped_hash": digest}
    if not os.path.isfile(_personal_path(bid)):
        raise BehaviourError(f"no personal copy of {bid!r} to settle")
    host.require_named(prompt, bid, mode)
    written = digest
    if mode == "merge":
        written = draft_hash(text, bid)
        _approve(host, rec, prompt, bid, written)

    def body():
        # Before any file change: a corrupt seen file must refuse with nothing half done.
        _seen_doc()
        path = _personal_path(bid)
        if mode == "merge":
            change = lambda: _atomic(path, text)
        elif mode == "take":
            change = lambda: os.unlink(path)
        else:
            change = lambda: None
        _with_rollback(path, change, lambda: _record(bid, seen=digest))

    _locked(body)
    return _adopted(bid, written, **{"as": mode, "shipped_hash": digest})


def _h_settle(host, argv):
    positional, opts = host._parse(argv, values=("run", "prompt", "as", "file"))
    if len(positional) != 1 or opts.get("as") not in MODES or (opts.get("file") and opts["as"] != "merge"):
        raise ValueError("usage: settle-default-update <id> --as shown|keep|take|merge [--prompt <id>] "
                         "[--file <path>] (--file only with merge; shown needs no --prompt)")
    bid, mode = programme_behaviours.check_id(positional[0]), opts["as"]
    if mode != "shown" and not opts.get("prompt"):
        raise ValueError(f"--as {mode} needs --prompt <id> of Shawn's typed approval")
    text = _draft_text(opts) if mode == "merge" else None

    def change(programme, prompt, rec):
        return _settle(host, rec, prompt, bid, mode, text)

    shown = mode == "shown"
    return host._write(opts, change, "behaviour_default_shown" if shown else ADOPTED,
                       prompt_id=opts.get("prompt"), needs_prompt=not shown, journal=not shown,
                       verb="settle-default-update", target=bid)


_SPECS = (
    ("adopt-behaviour-file", _h_adopt, "<id> --file <path> --prompt <id>",
     "a session that does not drive the programme; a prompt that is not Shawn's typed prompt, does not name the "
     "id, or does not carry the hash of exactly this content; a draft that fails the behaviour file check; an id "
     "that already has a personal file or a stored personal behaviour. Writes <id>.md into the personal behaviours folder and journals "
     "rule_adopted (how file). A refusal shows the content hash to put in the approval."),
    ("copy-default", _h_copy, "<id> --prompt <id>",
     "a prompt that is not Shawn's typed prompt or does not name the id; an id with no shipped file; an id that "
     "already has a personal file. Copies the shipped file into the personal folder, records seen in "
     "behaviours-seen.json and journals rule_adopted (how file)."),
    ("settle-default-update", _h_settle, "<id> --as shown|keep|take|merge [--prompt <id>] [--file <path>]",
     "an id with no shipped file or no personal copy; for keep, take and merge a prompt that is not Shawn's typed "
     "prompt or does not name the id and the mode; for merge content whose hash the prompt does not carry. shown "
     "records the displayed shipped hash and needs no prompt; keep records seen; take removes the personal file "
     "and records seen; merge writes the approved content and records seen."),
)


def build_verbs(host) -> dict:
    return {name: host._Verb(functools.partial(handler, host), args, rejects=rejects)
            for name, handler, args, rejects in _SPECS}
