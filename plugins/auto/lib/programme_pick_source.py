from __future__ import annotations

import hashlib
import json
import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

_MAX_TRANSCRIPT_BYTES = 64 * 1024 * 1024
TOOL = "AskUserQuestion"


def _hash(value):
    return hashlib.sha256(value).hexdigest()


def answers_hash(answers) -> str:
    return _hash(json.dumps(answers, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8"))


def _valid_answers(answers) -> bool:
    return (isinstance(answers, dict) and bool(answers)
            and all(isinstance(k, str) and isinstance(v, str) for k, v in answers.items()))


def redacted(answers) -> dict:
    # Lazy: programme_journal loads programme_prompt_source, which loads this module.
    redact = load_lib_module("programme_journal").redact
    return {redact(question): redact(answer) for question, answer in answers.items()}


def summary(answers) -> str:
    return "\n".join(f"picked: {question} -> {answer}" for question, answer in answers.items())


def capture(data):
    path = data.get("transcript_path")
    sid = data.get("session_id")
    tool_use_id = data.get("tool_use_id")
    answers = (data.get("tool_response") or {}).get("answers") if isinstance(data.get("tool_response"), dict) else None
    if not all(isinstance(value, str) and value for value in (path, sid, tool_use_id)) or not _valid_answers(answers):
        return None
    if not os.path.isabs(path) or os.path.basename(path) != sid + ".jsonl":
        return None
    try:
        with open(path, "rb") as stream:
            prefix = stream.read(_MAX_TRANSCRIPT_BYTES + 1)
    except FileNotFoundError:
        prefix = b""
    except OSError:
        return None
    if len(prefix) > _MAX_TRANSCRIPT_BYTES or (prefix and not prefix.endswith(b"\n")):
        return None
    return {"version": 1, "kind": "pick", "path": path, "session_id": sid, "tool_use_id": tool_use_id,
            "offset": len(prefix), "prefix_hash": _hash(prefix), "answers_hash": answers_hash(answers),
            "answers": redacted(answers)}


def _plain(row, sid) -> bool:
    return row.get("sessionId") == sid and not any(row.get(key) for key in ("isMeta", "isSidechain", "isCompactSummary"))


def _content(row) -> list:
    content = (row.get("message") or {}).get("content")
    return content if isinstance(content, list) else []


def _asks(row, tool_use_id) -> bool:
    return any(isinstance(block, dict) and block.get("type") == "tool_use" and block.get("id") == tool_use_id
               for block in _content(row))


def _unprefilled(row, tool_use_id) -> bool:
    for block in _content(row):
        if isinstance(block, dict) and block.get("type") == "tool_use" and block.get("id") == tool_use_id:
            tool_input = block.get("input")
            return block.get("name") == TOOL and isinstance(tool_input, dict) and "answers" not in tool_input
    return False


def _answers_row(row, tool_use_id) -> bool:
    return any(isinstance(block, dict) and block.get("type") == "tool_result" and block.get("tool_use_id") == tool_use_id
               for block in _content(row))


def _human_result(row, source) -> bool:
    permission = row.get("permissionDecision")
    by = permission.get("source") if isinstance(permission, dict) else None
    answers = (row.get("toolUseResult") or {}).get("answers") if isinstance(row.get("toolUseResult"), dict) else None
    return (isinstance(by, str) and by.startswith("user") and _valid_answers(answers)
            and answers_hash(answers) == source.get("answers_hash")
            and redacted(answers) == source.get("answers"))


def _rows(path, offset, prefix_hash):
    with open(path, "rb") as stream:
        prefix = stream.read(offset)
        if len(prefix) != offset or _hash(prefix) != prefix_hash:
            return None
        tail = stream.read(_MAX_TRANSCRIPT_BYTES + 1)
    if len(tail) > _MAX_TRANSCRIPT_BYTES:
        return None
    rows = []
    for line in (prefix + tail).splitlines(keepends=True):
        if not line.endswith(b"\n"):
            break
        row = json.loads(line)
        if isinstance(row, dict):
            rows.append(row)
    return rows


def verify(row) -> str:
    source = (row.get("payload") or {}).get("source")
    sid = row.get("session_id")
    if not isinstance(source, dict) or type(source.get("version")) is not int or source.get("version") != 1:
        return "unknown"
    path = source.get("path")
    offset = source.get("offset")
    tool_use_id = source.get("tool_use_id")
    if (source.get("kind") != "pick" or source.get("session_id") != sid or not isinstance(sid, str)
            or not isinstance(tool_use_id, str) or not tool_use_id
            or not isinstance(path, str) or not os.path.isabs(path) or os.path.basename(path) != sid + ".jsonl"
            or type(offset) is not int or not 0 <= offset <= _MAX_TRANSCRIPT_BYTES):
        return "unknown"
    try:
        rows = _rows(path, offset, source.get("prefix_hash"))
        if rows is None:
            return "unknown"
        asked = [r for r in rows if r.get("type") == "assistant" and _asks(r, tool_use_id)]
        if len(asked) != 1 or not _plain(asked[0], sid) or not _unprefilled(asked[0], tool_use_id):
            return "unknown"
        uuid = asked[0].get("uuid")
        results = [r for r in rows if r.get("type") == "user" and _answers_row(r, tool_use_id)]
        if (not isinstance(uuid, str) or not uuid or len(results) != 1
                or results[0].get("sourceToolAssistantUUID") != uuid
                or not _plain(results[0], sid) or not _human_result(results[0], source)):
            return "unknown"
        return "picked"
    except (OSError, ValueError, TypeError, AttributeError):
        return "unknown"
