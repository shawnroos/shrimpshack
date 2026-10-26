from __future__ import annotations

import json
import os
import re
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

programme_pick_source = load_lib_module("programme_pick_source")

_MAX_TRANSCRIPT_BYTES = programme_pick_source._MAX_TRANSCRIPT_BYTES
_hash = programme_pick_source._hash
# Accepting Claude Code's suggested prompt is Shawn pressing Enter on model-written text: it resolves to
# "suggested", which approves what a pick may approve but never a typed-only verb. Other sources stay unverified.
_HUMAN_SOURCES = ('typed', 'suggestion_accepted')
_COMMAND = re.compile(
    r'<command-message>([^<>\n]+)</command-message>\n'
    r'<command-name>(/[^<>\n]+)</command-name>'
    r'(?:\n<command-args>([\s\S]*)</command-args>)?'
)


def capture(data):
    path = data.get('transcript_path')
    sid = data.get('session_id')
    prompt_id = data.get('prompt_id')
    text = data.get('prompt')
    if not all(isinstance(value, str) and value for value in (path, sid, prompt_id)):
        return None
    if not isinstance(text, str):
        return None
    prefix = programme_pick_source.read_prefix(path, sid)
    if prefix is None:
        return None
    # The runtime appends the source row after UserPromptSubmit returns; older rows cannot authorize this occurrence.
    return {'version': 1, 'path': path, 'session_id': sid, 'prompt_id': prompt_id,
            'offset': len(prefix), 'prefix_hash': _hash(prefix),
            'text_hash': _hash(text.encode('utf-8'))}


def _human_text(row):
    if (row.get('origin') or {}).get('kind') != 'human' or row.get('turnOrigin') != 'human':
        return None
    if any(row.get(key) for key in ('isMeta', 'isSidechain', 'isCompactSummary')):
        return None
    message = row.get('message') or {}
    text = message.get('content')
    if message.get('role') != 'user' or not isinstance(text, str):
        return None
    if row.get('promptSource') in _HUMAN_SOURCES:
        return text
    command = _COMMAND.fullmatch(text)
    if row.get('promptSource') is None and row.get('entrypoint') == 'cli' and command:
        name, slash_name, args = command.groups()
        if slash_name == '/' + name:
            return slash_name + (' ' + args if args else '')
    return None


def origin(row):
    payload = row.get('payload') or {}
    claimed = payload.get('origin')
    if claimed not in ('typed', 'unknown', 'picked'):
        return claimed
    source = payload.get('source')
    if isinstance(source, dict) and source.get('kind') == 'pick':
        return programme_pick_source.verify(row)
    if not isinstance(source, dict) or type(source.get('version')) is not int or source.get('version') != 1:
        return 'unknown'
    sid = row.get('session_id')
    path = source.get('path')
    offset = source.get('offset')
    if (source.get('session_id') != sid or not isinstance(sid, str)
            or not isinstance(path, str) or not os.path.isabs(path)
            or os.path.basename(path) != sid + '.jsonl'
            or type(offset) is not int or not 0 <= offset <= _MAX_TRANSCRIPT_BYTES):
        return 'unknown'
    try:
        with open(path, 'rb') as stream:
            prefix = stream.read(offset)
            if len(prefix) != offset or _hash(prefix) != source.get('prefix_hash'):
                return 'unknown'
            tail = stream.read(_MAX_TRANSCRIPT_BYTES + 1)
        if len(tail) > _MAX_TRANSCRIPT_BYTES:
            return 'unknown'
        for line in tail.splitlines(keepends=True):
            if not line.endswith(b'\n'):
                break
            candidate = json.loads(line)
            if not isinstance(candidate, dict):
                continue
            if (candidate.get('type') != 'user' or candidate.get('sessionId') != sid
                    or candidate.get('promptId') != source.get('prompt_id')):
                continue
            text = _human_text(candidate)
            if text is not None and _hash(text.encode('utf-8')) == source.get('text_hash'):
                return 'suggested' if candidate.get('promptSource') == 'suggestion_accepted' else 'typed'
            return 'unknown'
    except (OSError, ValueError, TypeError, AttributeError):
        return 'unknown'
    return 'unknown'
