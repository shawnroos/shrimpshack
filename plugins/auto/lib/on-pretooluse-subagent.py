#!/usr/bin/env python3
"""PreToolUse guard: a dispatched sub-agent may read a programme but never write to it.

`_guard` cannot tell a sub-agent from the PM, because a sub-agent inherits the parent's
CLAUDE_CODE_SESSION_ID. Claude Code puts `agent_id` on hook input for a sub-agent's tool call,
so this hook denies any programme CLI verb outside READ_VERBS, `check-mergeable --pin`, and
`gh pr merge` when `agent_id` is present. The main session's calls pass through untouched.

Residual: a call that reaches programme code without naming programme.sh or programme.py
(for example an inline Python import) is not caught here.
"""

import json
import re
import shlex
import sys

READ_VERBS = frozenset({"status", "inbox", "describe", "check-mergeable"})
_PROGRAMME = re.compile(r"programme\.(?:sh|py)$")
_SEPARATORS = frozenset({";", "&&", "||", "|", "&", "\n"})
_MERGE = re.compile(r"\bgh\s+pr\s+merge\b")


def _segments(command):
    lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|")
    lexer.whitespace_split = True
    lexer.commenters = ""
    segment = []
    try:
        for token in lexer:
            if token in _SEPARATORS or set(token) <= set(";&|"):
                if segment:
                    yield segment
                segment = []
            else:
                segment.append(token)
    except ValueError:
        yield None
        return
    if segment:
        yield segment


def refusal(command):
    if _MERGE.search(command):
        return "a sub-agent may not merge a PR; return the readiness facts to the PM"
    for segment in _segments(command):
        if segment is None:
            if "programme." in command:
                return "a sub-agent's command naming the programme CLI could not be parsed"
            continue
        for at, token in enumerate(segment):
            if not _PROGRAMME.search(token.strip("\"'")):
                continue
            rest = segment[at + 1:]
            verb = next((t for t in rest if not t.startswith("-")), None)
            if verb not in READ_VERBS:
                return f"a sub-agent may not run programme verb {verb!r}; only {sorted(READ_VERBS)} are open to it"
            if verb == "check-mergeable" and "--pin" in rest:
                return "a sub-agent may not pin a merge head; the PM runs check-mergeable --pin"
    return None


def decide(stdin_raw):
    try:
        data = json.loads(stdin_raw or "{}")
    except ValueError:
        return None
    if not isinstance(data, dict) or not data.get("agent_id") or data.get("tool_name") != "Bash":
        return None
    command = (data.get("tool_input") or {}).get("command")
    if not isinstance(command, str):
        return None
    reason = refusal(command)
    if reason is None:
        return None
    return {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                   "permissionDecisionReason": "auto: " + reason}}


def main() -> int:
    try:
        decision = decide(sys.stdin.read())
    except Exception:  # noqa: BLE001 — rel-001: a hook crash must never block the main session's tools
        decision = None
    if decision is not None:
        json.dump(decision, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
