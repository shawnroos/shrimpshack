#!/usr/bin/env python3
"""Reads tool calls and their results from the live Claude Code session log.

All log reading lives here, so a change in the log format breaks in one place and stops
with a clear message instead of a wrong number.
"""

import glob
import json
import os
import re

SESSION_VAR = "CLAUDE_CODE_SESSION_ID"
UNREADABLE = "cannot read this session log"
CONVERSATION = ("user", "assistant")
PERSISTED_TAG = "<persisted-output>"
SAVED_TO = re.compile(r"Full output saved to: (.+)")


class LogError(Exception):
    def __init__(self, kind, message):
        super().__init__(message)
        self.kind = kind


def find_log(session_id=None, projects_root=None):
    if not session_id:
        session_id = os.environ.get(SESSION_VAR, "")
    if not session_id:
        raise LogError(
            "no_session",
            f"{SESSION_VAR} is not set, so this session's log cannot be found. Run this from inside a Claude Code session.",
        )
    if projects_root is None:
        projects_root = os.path.join(os.path.expanduser("~"), ".claude", "projects")
    matches = []
    if os.sep not in session_id and session_id not in (".", ".."):
        pattern = os.path.join(glob.escape(projects_root), "*", glob.escape(session_id) + ".jsonl")
        matches = sorted(glob.glob(pattern))
    if not matches:
        raise LogError("not_found", f"No session log for session {session_id} was found under {projects_root}.")
    if len(matches) > 1:
        raise LogError(
            "ambiguous",
            f"{len(matches)} session logs share the id {session_id}, so the right one cannot be chosen: " + ", ".join(matches),
        )
    return matches[0]


def _unreadable(detail):
    return LogError("unreadable", f"{UNREADABLE}: {detail}")


def _is_text_item(item):
    return isinstance(item, dict) and (item.get("type") != "text" or isinstance(item.get("text"), str))


def _check_conversation_line(entry, number):
    message = entry.get("message")
    if not isinstance(entry.get("uuid"), str) or not isinstance(message, dict):
        raise _unreadable(f"line {number} is a {entry.get('type')} line without a uuid or message")
    content = message.get("content")
    if isinstance(content, str):
        return
    if not isinstance(content, list) or not all(isinstance(b, dict) for b in content):
        raise _unreadable(f"line {number} has message content of an unknown shape")
    for block in content:
        kind = block.get("type")
        if kind == "tool_use":
            if not (
                isinstance(block.get("id"), str)
                and isinstance(block.get("name"), str)
                and isinstance(block.get("input"), dict)
            ):
                raise _unreadable(f"line {number} has a tool_use block without an id, name or input")
        elif kind == "tool_result":
            result = block.get("content")
            shaped = result is None or isinstance(result, str) or (isinstance(result, list) and all(map(_is_text_item, result)))
            if not (isinstance(block.get("tool_use_id"), str) and shaped and block.get("is_error") in (None, True, False)):
                raise _unreadable(f"line {number} has a tool_result block that cannot be parsed")


def _parsed_lines(path, name=None):
    where = f" of {name}" if name else ""
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except OSError as e:
        raise _unreadable(f"{name or path} cannot be opened ({e.strerror})") from e
    lines = raw.split(b"\n")
    for index, data in enumerate(lines):
        if not data.strip():
            continue
        try:
            entry = json.loads(data.decode("utf-8"))
        except ValueError:
            # The log is appended to while we read it: the final line may be half-written.
            if index == len(lines) - 1:
                continue
            raise _unreadable(f"line {index + 1}{where} is not JSON") from None
        if not isinstance(entry, dict):
            raise _unreadable(f"line {index + 1}{where} is not a JSON object")
        yield index + 1, entry


def load(path):
    entries = []
    for number, entry in _parsed_lines(path):
        if entry.get("type") in CONVERSATION:
            _check_conversation_line(entry, number)
        entries.append(entry)
    return Log(path, entries)


def _bash_commands(entry):
    if not isinstance(entry, dict) or entry.get("type") != "assistant":
        return
    message = entry.get("message")
    content = message.get("content") if isinstance(message, dict) else None
    if not isinstance(content, list):
        return
    for block in content:
        if isinstance(block, dict) and block.get("type") == "tool_use" and block.get("name") == "Bash":
            command = block.get("input", {}).get("command") if isinstance(block.get("input"), dict) else None
            if isinstance(command, str):
                yield command


def _latest_invocation(entries, needle):
    latest = None
    for entry in entries:
        if any(needle in command for command in _bash_commands(entry)):
            latest = entry
    return latest


def _message_id(entry):
    message = entry.get("message")
    if entry.get("type") != "assistant" or not isinstance(message, dict) or not isinstance(message.get("id"), str):
        return None
    return message["id"]


def _blocks(entry, kind):
    message = entry.get("message")
    content = message.get("content") if entry.get("type") in CONVERSATION and isinstance(message, dict) else None
    if not isinstance(content, list):
        return []
    return [b for b in content if b.get("type") == kind]


def _joined(content):
    if content is None:
        return ""
    if isinstance(content, str):
        return content
    return "\n".join(item["text"] for item in content if item.get("type") == "text")


def _unwrap(text):
    """MCP results arrive as an envelope whose text is the tool's own reply."""
    try:
        outer = json.loads(text)
    except ValueError:
        return text, False
    if not isinstance(outer, dict):
        return text, False
    items = outer.get("content")
    if not (isinstance(items, list) and items and all(isinstance(i, dict) and i.get("type") == "text" and isinstance(i.get("text"), str) for i in items)):
        return text, False
    return "\n".join(i["text"] for i in items), outer.get("isError") is True


class Log:
    def __init__(self, path, entries):
        self.path = path
        self.session_dir = path[: -len(".jsonl")] if path.endswith(".jsonl") else path
        self.entries = entries
        self._by_uuid = {e["uuid"]: e for e in entries if isinstance(e.get("uuid"), str)}
        self._position = {id(e): i for i, e in enumerate(entries)}

    def find_invocation(self, needle):
        found = _latest_invocation(self.entries, needle)
        if found is not None:
            return found
        pattern = os.path.join(glob.escape(self.session_dir), "subagents", "*.jsonl")
        for sub in sorted(glob.glob(pattern)):
            entries = (entry for _, entry in _parsed_lines(sub, "subagent log " + os.path.basename(sub)))
            if _latest_invocation(entries, needle) is not None:
                raise LogError(
                    "subagent",
                    "This was run from a subagent; reports only run in the main session. Run it again from the main conversation.",
                )
        raise LogError("no_invocation", f"No Bash call containing {needle} is in this session log.")

    def branch(self, from_entry):
        path = []
        seen = set()
        entry = from_entry
        while entry is not None:
            key = entry.get("uuid")
            if key in seen:
                break
            seen.add(key)
            path.append(entry)
            parent = entry.get("parentUuid")
            if parent is None and entry.get("subtype") == "compact_boundary":
                parent = entry.get("logicalParentUuid")
            entry = self._by_uuid.get(parent)
        return self._with_parallel_calls(path, from_entry)

    def _with_parallel_calls(self, path, from_entry):
        # Parallel tool calls from one API message fork the parentUuid chain, so a walk
        # from a later line misses some of them. They share the message id; a rewound
        # branch gets a new one.
        turns = {_message_id(e) for e in path} - {None}
        uses = set()
        for entry in self.entries:
            if _message_id(entry) in turns:
                uses.update(b["id"] for b in _blocks(entry, "tool_use"))
        on_branch = {id(e) for e in path}
        for entry in self.entries:
            if _message_id(entry) in turns or any(b["tool_use_id"] in uses for b in _blocks(entry, "tool_result")):
                on_branch.add(id(entry))
        # The cap keeps the invoking line last: calls() depends on it, and a sibling written
        # after it ran concurrently with it.
        last = self._position.get(id(from_entry), len(self.entries))
        return [e for e in self.entries if id(e) in on_branch and self._position[id(e)] <= last]

    def calls(self, branch, after_text=None):
        invoking = branch[-1] if branch else None
        start = -1 if after_text is None else None
        uses = []
        seen = set()
        results = {}
        for position, entry in enumerate(branch):
            if entry.get("type") not in CONVERSATION or not isinstance(entry["message"]["content"], list):
                continue
            for block in entry["message"]["content"]:
                if block.get("type") == "tool_use":
                    if block["id"] in seen:
                        raise _unreadable(f"the tool call {block['id']} appears twice on this branch")
                    seen.add(block["id"])
                    if entry is not invoking:
                        uses.append((position, block))
                elif block.get("type") == "tool_result":
                    answered = block["tool_use_id"]
                    if answered in results:
                        raise _unreadable(f"the tool call {answered} has two results on this branch")
                    if answered in seen:
                        results[answered] = (entry, block)
                    if start is None and after_text in _joined(block.get("content")):
                        start = position
        if start is None:
            return []
        return [self._call(block, results.get(block["id"])) for position, block in uses if position > start]

    def _call(self, use, result):
        call = {
            "id": use["id"],
            "tool": use["name"],
            "input": use["input"],
            "timestamp": None,
            "has_result": result is not None,
            "is_error": False,
            "text": None,
        }
        if result is not None:
            entry, block = result
            text = _joined(block.get("content"))
            if text.startswith(PERSISTED_TAG):
                text = self._persisted(text)
            text, envelope_error = _unwrap(text)
            call.update(timestamp=entry.get("timestamp"), is_error=block.get("is_error") is True or envelope_error, text=text)
        return call

    def _persisted(self, notice):
        match = SAVED_TO.search(notice)
        if not match:
            raise _unreadable("a <persisted-output> notice names no file")
        target = match.group(1).strip()
        allowed = os.path.realpath(os.path.join(self.session_dir, "tool-results"))
        # realpath before the check, so a symlink or ".." cannot lead out of tool-results/.
        real = os.path.realpath(target)
        if not os.path.isabs(target) or os.path.commonpath([allowed, real]) != allowed or real == allowed:
            raise _unreadable(f"a <persisted-output> notice points outside this session's tool-results directory: {target}")
        try:
            with open(real, encoding="utf-8") as f:
                return f.read()
        except OSError as e:
            raise _unreadable(f"the saved output {target} cannot be read ({e.strerror})") from e
