#!/usr/bin/env python3
"""One sanitizer for text that comes from outside the PM: panes, issues, PRs, claims."""

from __future__ import annotations

import re

DEFAULT_CAP = 500
TOKEN_CAP = 256
DATA_TAG = "auto-external"
ELLIPSIS = "..."

_ESCAPES = re.compile(
    r"\x1b\[[0-9;?]*[ -/]*[@-~]"
    r"|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)"
    r"|\x1b[PX^_][^\x1b]*\x1b\\"
    r"|\x1b[@-Z\\-_]"
    r"|\x9b[0-9;?]*[ -/]*[@-~]"
)
_CONTROL = re.compile("[\x00-\x08\x0b-\x1f\x7f-\x9f\u200b-\u200f\u202a-\u202e\u2066-\u2069]")
_NEWLINES = re.compile(r"[ ]*[\r\n\t]+[ ]*")


def clean(value, cap=DEFAULT_CAP, *, keep_newlines=False) -> str:
    text = "" if value is None else str(value)
    text = _ESCAPES.sub("", text)
    text = _CONTROL.sub("", text)
    if keep_newlines:
        text = text.replace("\r\n", "\n").replace("\r", "\n").replace("\t", " ")
    else:
        text = _NEWLINES.sub(" ", text)
    text = text.strip()
    if cap and len(text) > cap:
        text = text[: max(cap - len(ELLIPSIS), 0)] + ELLIPSIS
    return text


def token(value, cap=TOKEN_CAP):
    text = clean(value, cap=0)
    if not text or len(text) > cap or any(ch.isspace() for ch in text):
        return None
    return text


def wrap(value, tag=DATA_TAG, cap=DEFAULT_CAP) -> str:
    body = clean(value, cap, keep_newlines=True).replace("<", "\\u003c")
    return f"<{tag}>{body}</{tag}>"
