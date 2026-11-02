#!/usr/bin/env python3
"""Behaviour files: a shipped folder and a personal folder of markdown behaviours.

One file is one behaviour; the file name without ``.md`` is its id. Frontmatter holds the
fields and the body holds the ``Do:`` and ``Don't:`` bullet lists. Every file goes through
``programme_behaviours.verdict``; a bad file is reported and never stops its neighbours.
"""

from __future__ import annotations

import datetime
import os
import re
import stat
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

programme_behaviours = load_lib_module("programme_behaviours")
programme_protocol = load_lib_module("programme_protocol")

SHIPPED_DIR_ENV = "CLAUDE_AUTO_SHIPPED_BEHAVIOURS_DIR"
PERSONAL_DIR_ENV = "CLAUDE_AUTO_BEHAVIOURS_DIR"
FOLDER_NAME = "behaviours"

SCALARS = ("when", "trigger", "applies_to", "evidence", "stop", "why")
LISTS = ("checks", "overrides", "skills", "tools", "agents", "formats", "comms")
KEYS = SCALARS + LISTS
MAX_FILE_BYTES = 64 * 1024
MAX_LINE_CHARS = 500
SEEN_NAME = "behaviours-seen.json"
LOCK_NAME = ".behaviour-files.lock"

_Reject = programme_protocol._Reject
_KEY_LINE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*):\s*(.*)$")
_ITEM = re.compile(r"^\s*-\s+(.*\S)\s*$")
_LINES = re.compile(r"\r\n|\n|\r")
_HEADING = re.compile(r"^(?:#+\s*)?(?:\*\*)?(do|don'?t)(?::)?(?:\*\*)?:?\s*$", re.IGNORECASE)
_BULLET = re.compile(r"^\s*[-*]\s+(.*\S)\s*$")


def shipped_dir() -> str:
    return os.environ.get(SHIPPED_DIR_ENV) or os.path.join(os.path.dirname(_LIB_DIR), FOLDER_NAME)


def personal_dir() -> str:
    override = os.environ.get(PERSONAL_DIR_ENV)
    if override:
        return override
    return os.path.join(os.path.dirname(programme_protocol.personal_path()), FOLDER_NAME)


def _unquote(value):
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
        return value[1:-1].strip()
    return value


def _flow(value):
    if not value.endswith("]"):
        raise _Reject("bad_value", "frontmatter")
    inner = value[1:-1].strip()
    if not inner:
        return []
    items = [_unquote(part.strip()) for part in inner.split(",")]
    if not all(items):
        raise _Reject("bad_value", "frontmatter")
    return items


def _split(text):
    # Not str.splitlines: it would turn a vertical tab or U+2028 into a silent line break.
    lines = _LINES.split(text)
    if not lines or lines[0].strip() != "---":
        raise _Reject("missing_field", "frontmatter")
    for end in range(1, len(lines)):
        if lines[end].strip() == "---":
            return lines[1:end], lines[end + 1:]
    raise _Reject("bad_value", "frontmatter")


def _frontmatter(lines) -> dict:
    fields, current = {}, None
    for line in lines:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        item = _ITEM.match(line)
        if item and current is not None and isinstance(fields[current], list):
            fields[current].append(_unquote(item.group(1)))
            continue
        key = _KEY_LINE.match(line)
        if not key or line[0].isspace():
            raise _Reject("bad_value", "frontmatter")
        name, value = key.group(1), key.group(2).strip()
        if name not in KEYS:
            raise _Reject("unknown_key", name)
        if name in fields:
            raise _Reject("bad_value", name)
        if name in SCALARS:
            fields[name] = _unquote(value)
        elif value.startswith("["):
            fields[name] = _flow(value)
        else:
            fields[name] = [_unquote(value)] if value else []
        current = name
        if name in LISTS and value:
            current = None
    return fields


def _body(lines) -> dict:
    out, section = {"do": [], "dont": []}, None
    for line in lines:
        if not line.strip():
            continue
        head = _HEADING.match(line.strip())
        if head:
            section = "do" if head.group(1).lower() == "do" else "dont"
            continue
        bullet = _BULLET.match(line)
        if section is None or not bullet:
            raise _Reject("bad_value", "body")
        out[section].append(bullet.group(1))
    return {k: v for k, v in out.items() if v}


def _checks(rows) -> list:
    out = []
    for row in rows:
        by, _, text = row.partition(":")
        if by.strip() not in programme_behaviours.CHECK_BY or not text.strip():
            raise _Reject("bad_value", "when.checks")
        out.append({"text": text.strip(), "by": by.strip()})
    return out


def _entry(bid, fields, body, mtime) -> dict:
    entry = {"id": bid, "layer": "personal", "state": "active",
             "applies_to": fields.get("applies_to", "both"), **body,
             "at": datetime.datetime.fromtimestamp(mtime, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
    if fields.get("when"):
        when = {"text": fields["when"]}
        if fields.get("trigger"):
            when["trigger"] = fields["trigger"]
        if fields.get("checks"):
            when["checks"] = _checks(fields["checks"])
        entry["when"] = when
    for key in ("overrides", "skills", "tools", "agents", "formats", "comms"):
        if fields.get(key):
            entry[key] = fields[key]
    for key in ("evidence", "stop", "why"):
        if fields.get(key):
            entry[key] = fields[key]
    return entry


def read_file(path):
    folder = os.path.realpath(os.path.dirname(path))
    try:
        if stat.S_ISLNK(os.lstat(path).st_mode) and os.path.commonpath([os.path.realpath(path), folder]) != folder:
            raise _Reject("bad_value", "file")
        # Checked before open: opening a FIFO named x.md would block the whole load.
        if not stat.S_ISREG(os.stat(path).st_mode):
            raise _Reject("bad_value", "file")
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as fh:
            info = os.fstat(fh.fileno())
            if not stat.S_ISREG(info.st_mode):
                raise _Reject("bad_value", "file")
            data = fh.read(MAX_FILE_BYTES + 1)
    except OSError:
        raise _Reject("bad_value", "file")
    if len(data) > MAX_FILE_BYTES:
        raise _Reject("bad_value", "file size")
    try:
        return data.decode("utf-8"), info.st_mtime
    except UnicodeDecodeError:
        raise _Reject("bad_value", "file")


def parse_text(text, bid, mtime=0.0) -> dict:
    # line_kind is quadratic in the words of a line, so a long line is refused before it runs.
    if any(len(line) > MAX_LINE_CHARS for line in _LINES.split(text)):
        raise _Reject("bad_value", "line length")
    head, body = _split(text)
    return _entry(bid, _frontmatter(head), _body(body), mtime)


def _texts(entry):
    for field in ("do", "dont", "skills", "tools", "agents", "formats", "comms"):
        for line in entry.get(field) or ():
            yield field, line
    if entry.get("evidence"):
        yield "evidence", entry["evidence"]
    when = entry.get("when") or {}
    yield "when.text", when.get("text", "")
    for check in when.get("checks") or ():
        yield "checks", check["text"]


def _clean_only(entry) -> None:
    clean = programme_behaviours.programme_sanitize.clean
    for field, text in _texts(entry):
        if clean(text, cap=0) != text:
            raise _Reject("bad_value", field)


# File entries scan every rendered text field; the stored PROTECTED_FIELDS stay as they are.
def _scan(entry) -> None:
    for _, line in _texts(entry):
        kind = programme_behaviours.line_kind(line)
        if kind:
            raise _Reject("protected_escalation", kind)


# source is set after verdict: the stored schema types it as an object, a file entry's is the string "file".
def entry_from_text(text, bid, layer, mtime=0.0) -> dict:
    if not programme_behaviours.ID_RE.fullmatch(bid):
        raise _Reject("bad_value", "id")
    entry = parse_text(text, bid, mtime)
    _clean_only(entry)
    check = programme_behaviours.verdict(entry, allow_adoption=False)
    if not check["ok"]:
        raise _Reject(check["reason"], check["detail"])
    _scan(entry)
    entry["layer"], entry["source"] = layer, "file"
    return entry


def read_entry(path, bid, layer) -> dict:
    text, mtime = read_file(path)
    return entry_from_text(text, bid, layer, mtime)


# "at" is the file's mtime, which changes on every write; an approval must survive a rewrite.
def entry_hash(entry) -> str:
    return programme_protocol.content_hash({k: v for k, v in entry.items() if k != "at"})


def seen_path() -> str:
    return os.path.join(os.path.dirname(programme_behaviours.store_path()), SEEN_NAME)


def _load_dir(folder, layer, out) -> None:
    try:
        names = sorted(n for n in os.listdir(folder) if n.endswith(".md") and not n.startswith("."))
    except OSError:
        return
    for name in names:
        bid = name[:-3]
        try:
            out["entries"].append(read_entry(os.path.join(folder, name), bid, layer))
        except _Reject as exc:
            out["rejected"].append({"layer": layer, "key": None, "id": bid,
                                    "reason": exc.reason, "detail": exc.detail})


def load_files(shipped_dir=None, personal_dir=None) -> dict:
    out = {"entries": [], "rejected": []}
    _load_dir(globals()["shipped_dir"]() if shipped_dir is None else shipped_dir, "shipped", out)
    _load_dir(globals()["personal_dir"]() if personal_dir is None else personal_dir, "personal", out)
    return out


def load_into(out) -> None:
    loaded = load_files()
    stored = {e["id"] for e in out["personal"]}
    out["shipped"], out["files"] = [], []
    rejected = list(loaded["rejected"])
    for entry in loaded["entries"]:
        if entry["layer"] == "personal" and entry["id"] in stored:
            rejected.append({"layer": "personal", "key": None, "id": entry["id"], "reason": "shadowed",
                             "detail": "a stored personal entry has this id"})
        else:
            out["shipped" if entry["layer"] == "shipped" else "files"].append(entry)
    out["rejected"] += rejected
    clean = programme_behaviours.programme_sanitize.clean
    out["notices"] += [clean(f"behaviour file {r['layer']}/{r['id']}.md rejected: {r['reason']}"
                             + (f" ({r['detail']})" if r["detail"] else ""), cap=0) for r in rejected]
