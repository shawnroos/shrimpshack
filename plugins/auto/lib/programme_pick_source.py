from __future__ import annotations

import hashlib
import json
import os
import re
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

# Version 1 sources hash the whole transcript up to this size; they stay readable so approvals already given keep
# their proof. A long-lived PM outgrew it (72 MB), so every later prompt and pick journaled as unverified.
_MAX_TRANSCRIPT_BYTES = 64 * 1024 * 1024
_WINDOW_BYTES = 1024 * 1024
_LOOKBACK_BYTES = 32 * 1024 * 1024
_MAX_OFFSET = 1 << 50
TOOL = "AskUserQuestion"
NOTES_ONLY = "(notes only)"
_TOOL_USE_ID = re.compile(r"[A-Za-z0-9_-]+")


def _hash(value):
    return hashlib.sha256(value).hexdigest()


def registered(path, sid) -> bool:
    return isinstance(path, str) and path == load_lib_module("permission_transcript").path_for(sid)


# The registry keeps 50 rows per pane, so an approval given long ago outlives its session's row. Its path was checked
# at capture and when it approved, so a later read of that past approval checks only the file's name.
def named_for(path, sid) -> bool:
    return isinstance(path, str) and os.path.isabs(path) and os.path.basename(path) == sid + ".jsonl"


def read_window(path, sid, needle=None):
    """The part of the transcript a later check must find unchanged: from the line holding `needle` (a pick's
    asking row) to the end, or the last _WINDOW_BYTES when there is no needle. Returns (start, bytes) or None."""
    if not registered(path, sid):
        return None
    try:
        with open(path, "rb") as stream:
            size = os.fstat(stream.fileno()).st_size
            start = max(0, size - (_LOOKBACK_BYTES if needle else _WINDOW_BYTES))
            stream.seek(start)
            data = stream.read(size - start)
    except FileNotFoundError:
        return None if needle else (0, b"")
    except OSError:
        return None
    if len(data) != size - start or (data and not data.endswith(b"\n")):
        return None
    if needle:
        at = data.find(needle)
        if at < 0:
            return None
        line = data.rfind(b"\n", 0, at) + 1
        if line == 0 and start > 0:
            return None
        start, data = start + line, data[line:]
    return start, data


def window_source(path, sid, needle=None):
    found = read_window(path, sid, needle)
    if found is None:
        return None
    start, window = found
    return {"version": 2, "path": path, "session_id": sid, "offset": start + len(window),
            "window_start": start, "window_hash": _hash(window)}


def read_checked(path, source):
    """The captured window and everything written after it, or None when the window changed. Reads version 1
    (whole-file hash) and version 2 sources."""
    offset = source.get("offset")
    if type(offset) is not int or not 0 <= offset <= _MAX_OFFSET:
        return None
    if source.get("version") == 1:
        start, want, limit = 0, source.get("prefix_hash"), _MAX_TRANSCRIPT_BYTES
    else:
        start, want, limit = source.get("window_start"), source.get("window_hash"), _LOOKBACK_BYTES
        if type(start) is not int or not 0 <= start <= offset or (start == offset and offset):
            return None
    if offset - start > limit:
        return None
    with open(path, "rb") as stream:
        stream.seek(start)
        window = stream.read(offset - start)
        if len(window) != offset - start or _hash(window) != want:
            return None
        tail = stream.read(_MAX_TRANSCRIPT_BYTES + 1)
    return None if len(tail) > _MAX_TRANSCRIPT_BYTES else (window, tail)


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
    response = data.get("tool_response")
    answers = response.get("answers") if isinstance(response, dict) else None
    if (not all(isinstance(value, str) and value for value in (path, sid, tool_use_id))
            or not _TOOL_USE_ID.fullmatch(tool_use_id) or not _valid_answers(answers)):
        return None
    source = window_source(path, sid, tool_use_id.encode("utf-8"))
    if source is None:
        return None
    return dict(source, kind="pick", tool_use_id=tool_use_id, answers_hash=answers_hash(answers),
                answers=redacted(answers))


def _plain(row, sid) -> bool:
    return row.get("sessionId") == sid and not any(row.get(key) for key in ("isMeta", "isSidechain", "isCompactSummary"))


def _content(row) -> list:
    content = (row.get("message") or {}).get("content")
    return content if isinstance(content, list) else []


def _tool_use(row, tool_use_id):
    return next((block for block in _content(row)
                 if isinstance(block, dict) and block.get("type") == "tool_use" and block.get("id") == tool_use_id),
                None)


def _asks(row, tool_use_id) -> bool:
    return _tool_use(row, tool_use_id) is not None


def _unprefilled(row, tool_use_id) -> bool:
    block = _tool_use(row, tool_use_id)
    if block is None:
        return False
    tool_input = block.get("input")
    return block.get("name") == TOOL and isinstance(tool_input, dict) and "answers" not in tool_input


def _answers_row(row, tool_use_id) -> bool:
    return any(isinstance(block, dict) and block.get("type") == "tool_result" and block.get("tool_use_id") == tool_use_id
               for block in _content(row))


def _human_result(row, source) -> bool:
    permission = row.get("permissionDecision")
    by = permission.get("source") if isinstance(permission, dict) else None
    result = row.get("toolUseResult")
    answers = result.get("answers") if isinstance(result, dict) else None
    return (isinstance(by, str) and by.startswith("user") and _valid_answers(answers)
            and "afkTimeoutMs" not in result
            and answers_hash(answers) == source.get("answers_hash")
            and redacted(answers) == source.get("answers"))


def _rows(path, source, tool_use_id):
    checked = read_checked(path, source)
    if checked is None:
        return None
    needle = tool_use_id.encode("utf-8")
    rows = []
    for line in b"".join(checked).splitlines(keepends=True):
        if not line.endswith(b"\n"):
            break
        if needle not in line:
            continue
        row = json.loads(line)
        if isinstance(row, dict):
            rows.append(row)
    return rows


def _verified(row, pinned=True):
    """The asking block and result the transcript holds for this pick, or None unless it shows a human answer."""
    source = (row.get("payload") or {}).get("source")
    sid = row.get("session_id")
    if not isinstance(source, dict) or type(source.get("version")) is not int or source.get("version") not in (1, 2):
        return None
    path = source.get("path")
    tool_use_id = source.get("tool_use_id")
    if (source.get("kind") != "pick" or source.get("session_id") != sid or not isinstance(sid, str)
            or not isinstance(tool_use_id, str) or not tool_use_id
            or not (registered if pinned else named_for)(path, sid)):
        return None
    try:
        rows = _rows(path, source, tool_use_id)
        if rows is None:
            return None
        asked = [r for r in rows if r.get("type") == "assistant" and _asks(r, tool_use_id)]
        if len(asked) != 1 or not _plain(asked[0], sid) or not _unprefilled(asked[0], tool_use_id):
            return None
        uuid = asked[0].get("uuid")
        results = [r for r in rows if r.get("type") == "user" and _answers_row(r, tool_use_id)]
        if (not isinstance(uuid, str) or not uuid or len(results) != 1
                or results[0].get("sourceToolAssistantUUID") != uuid
                or not _plain(results[0], sid) or not _human_result(results[0], source)):
            return None
        return _tool_use(asked[0], tool_use_id), results[0]["toolUseResult"]
    except (OSError, ValueError, TypeError, AttributeError):
        return None


def verify(row, pinned=True) -> str:
    return "picked" if _verified(row, pinned) is not None else "unknown"


def _has_note(result) -> bool:
    annotations = result.get("annotations", {})
    return (NOTES_ONLY in result["answers"].values()
            or not isinstance(annotations, dict)
            or any(not isinstance(entry, dict) or entry.get("notes") for entry in annotations.values()))


def _notes(result) -> list:
    annotations = result.get("annotations", {})
    entries = annotations.values() if isinstance(annotations, dict) else ()
    return [entry["notes"] for entry in entries if isinstance(entry, dict) and isinstance(entry.get("notes"), str)]


def read_pick(row):
    """The raw answers from the transcript (the journal holds them redacted) and why they cannot approve an option,
    or None when the pick does not verify. A noted pick stays verified: the note is Shawn's own words."""
    found = _verified(row)
    if found is None:
        return None
    block, result = found
    questions = block["input"].get("questions")
    asked = [q.get("question") for q in questions if isinstance(q, dict)] if isinstance(questions, list) else []
    unanswered = [question for question in asked if question not in result["answers"]]
    gap, noted = None, False
    if unanswered or not asked:
        gap = f"leaves {len(unanswered)} of {len(asked)} questions unanswered, so it approves nothing"
    elif _has_note(result):
        noted = True
        gap = "carries a note, which counts as Shawn's own words, so it approves no option"
    return {"answers": result["answers"], "gap": gap, "questions": questions, "noted": noted, "notes": _notes(result)}


def question_before(row):
    """The newest picker in the transcript before this prompt's enqueue position, as (tool_use_id, questions), or None.
    The hook fires at send time, so the row's offset holds that position wherever the words are delivered later."""
    source = (row.get("payload") or {}).get("source")
    sid = row.get("session_id")
    if not isinstance(source, dict) or source.get("session_id") != sid or not registered(source.get("path"), sid):
        return None
    try:
        checked = read_checked(source["path"], source)
    except (OSError, TypeError, ValueError):
        return None
    if checked is None:
        return None
    for line in reversed(checked[0].splitlines()):
        try:
            candidate = json.loads(line)
        except ValueError:
            continue
        if not isinstance(candidate, dict) or candidate.get("type") != "assistant" or not _plain(candidate, sid):
            continue
        for block in reversed(_content(candidate)):
            if isinstance(block, dict) and block.get("type") == "tool_use" and block.get("name") == TOOL:
                tool_input = block.get("input")
                if isinstance(tool_input, dict) and "answers" not in tool_input:
                    return block.get("id"), tool_input.get("questions")
    return None


def approval_gap(row):
    pick = read_pick(row)
    return "does not verify against the transcript" if pick is None else pick["gap"]
