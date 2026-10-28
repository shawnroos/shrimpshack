#!/usr/bin/env python3
"""PreToolUse guard: a PM's dispatched sub-agent may read a programme but never write to it.

`_guard` cannot tell a sub-agent from the PM, because a sub-agent inherits the parent's
CLAUDE_CODE_SESSION_ID; Claude Code marks a sub-agent's tool call with `agent_id` instead.
The guard is default-deny: a command that mentions programme code passes only as a direct
`programme.sh <read verb>` call or a read-only viewer, so an inline interpreter or a
wrapper cannot reach a write verb.
"""

import json
import os
import re
import shlex
import sys

READ_VERBS = frozenset({"status", "inbox", "describe", "check-mergeable"})
VIEWERS = frozenset({"cat", "head", "tail", "less", "grep", "rg", "wc", "ls", "file", "stat", "diff"})
GIT_READS = frozenset({"show", "diff", "log", "blame", "status", "grep"})
GH_PR_READS = frozenset({"view", "list", "checks", "diff", "status"})
_SHELLS = frozenset({"bash", "sh", "zsh"})
_PYTHONS = frozenset({"python", "python3"})
_SEPARATORS = frozenset({";", "&&", "||", "|", "&", "\n"})
_ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
_PR_MERGE = re.compile(r"\bgh\b.*\bpr\b.*\bmerge\b|/pulls/\d+/merge|mergePullRequest", re.S)
DIGEST_NAME = "sweep-digest.md"
WRITE_TOOLS = frozenset({"Write", "Edit", "MultiEdit", "NotebookEdit"})
# A viewer that runs a command or writes a file is a write verb in disguise.
_VIEWER_WRITE_FLAGS = frozenset({"--pre", "--pre-glob", "--output", "-O", "--open-files-in-pager"})
# ${CLAUDE_PLUGIN_ROOT} is how every agent file names programme.sh; any other expansion runs before the guard's verb.
_EXPANSION = re.compile(r"\$(?!\{CLAUDE_PLUGIN_ROOT\})[({A-Za-z_]|`|[<>]\(")
_DENY_PROGRAMME = ("a sub-agent may only run `programme.sh` with a read verb ({}); this command reaches "
                   "programme code another way")


def _segments(command):
    lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|\n")
    lexer.whitespace_split = True
    lexer.whitespace = " \t\r"
    lexer.commenters = ""
    segment = []
    for token in lexer:
        if token in _SEPARATORS or set(token) <= set(";&|\n"):
            if segment:
                yield segment
            segment = []
        else:
            segment.append(token)
    if segment:
        yield segment


def _programme_call(segment):
    head = segment[0]
    if head.endswith(("programme.sh", "programme.py")):
        return segment[1:]
    base = os.path.basename(head)
    if len(segment) > 1 and ((base in _SHELLS and segment[1].endswith("programme.sh"))
                             or (base in _PYTHONS and segment[1].endswith("programme.py"))):
        return segment[2:]
    return None


def _gh_refusal(args):
    words, at = [], 0
    while at < len(args):
        token = args[at]
        if token in ("-R", "--repo", "--hostname"):
            at += 2
            continue
        if not token.startswith("-"):
            words.append(token)
        at += 1
    if words[:1] == ["pr"] and len(words) > 1 and words[1] not in GH_PR_READS:
        return f"a sub-agent may not run `gh pr {words[1]}`; it changes the PR"
    if words[:1] == ["api"]:
        methods = [args[i + 1].upper() for i, t in enumerate(args[:-1]) if t in ("-X", "--method")]
        writes_body = any(t in ("-f", "-F", "--field", "--raw-field", "--input") for t in args)
        if any(m != "GET" for m in methods) or (writes_body and methods != ["GET"]):
            return "a sub-agent may run `gh api` reads only"
    return None


def _redirect_refusal(segment):
    for at, token in enumerate(segment):
        if ">" not in token:
            continue
        after = token[token.index(">"):].lstrip(">&")
        if (after or (segment[at + 1] if at + 1 < len(segment) else "")) != "/dev/null":
            return "a sub-agent may not redirect output from a command naming programme code, except to /dev/null"
    return None


def _viewer_refusal(segment):
    for token in segment:
        if token.split("=", 1)[0] in _VIEWER_WRITE_FLAGS or token.startswith("-O"):
            return "a sub-agent may not run a viewer with --pre, --output or -O; they run a command or write a file"
    return None


def _is_read_call(rest):
    # `rules --ack` clears the compact flag and is a write; any flag beyond --run <id> stays denied.
    if rest[0] in READ_VERBS:
        return True
    args = rest[1:]
    return rest[0] == "rules" and (not args or (len(args) == 2 and args[0] == "--run" and not args[1].startswith("-")))


def _segment_refusal(segment):
    mentions = any("programme" in token.lower() for token in segment)
    if mentions and segment and _ASSIGNMENT.match(segment[0]):
        return "a sub-agent may not set environment variables on a command naming programme code"
    while segment and _ASSIGNMENT.match(segment[0]):
        segment = segment[1:]
    if not segment:
        return None
    base = os.path.basename(segment[0])
    if base in _SHELLS and "-c" in segment[1:]:
        script = segment[segment.index("-c") + 1:segment.index("-c") + 2]
        return refusal(script[0]) if script else None
    if base == "eval":
        return refusal(" ".join(segment[1:]))
    if base == "gh":
        return _gh_refusal(segment[1:])
    if not mentions:
        return None
    if any(_EXPANSION.search(token) for token in segment):
        return "a sub-agent may not use shell expansion in a command naming programme code"
    redirect = _redirect_refusal(segment)
    if redirect:
        return redirect
    if base in VIEWERS or (base == "git" and len(segment) > 1 and segment[1] in GIT_READS):
        return _viewer_refusal(segment)
    rest = _programme_call(segment)
    if rest is None or not rest or not _is_read_call(rest):
        return _DENY_PROGRAMME.format(", ".join(sorted(READ_VERBS | {"rules"})))
    if rest[0] == "check-mergeable" and "--pin" in rest:
        return "a sub-agent may not pin a merge head; the PM runs check-mergeable --pin"
    return None


def refusal(command):
    command = command.replace("\\\n", "")
    try:
        segments = list(_segments(command))
    except ValueError:
        lowered = command.lower()
        if "programme" in lowered or _PR_MERGE.search(command):
            return "a sub-agent's command naming programme code or a PR merge could not be parsed"
        return None
    for segment in segments:
        reason = _segment_refusal(segment)
        if reason:
            return reason
    if _PR_MERGE.search(command) and not any(os.path.basename(s[0]) in VIEWERS for s in segments if s):
        return "a sub-agent may not merge a PR; return the readiness facts to the PM"
    return None


def _drives_programme(session_id) -> bool:
    lib = os.path.dirname(os.path.abspath(__file__))
    if lib not in sys.path:
        sys.path.insert(0, lib)
    from _bootstrap import load_lib_module
    return bool(load_lib_module("programme_home").driven_runs(session_id))


def _driven_homes(session_id):
    lib = os.path.dirname(os.path.abspath(__file__))
    if lib not in sys.path:
        sys.path.insert(0, lib)
    from _bootstrap import load_lib_module
    programme_home = load_lib_module("programme_home")
    return [hold["home"] for hold in programme_home.driven_runs(session_id)], programme_home.programmes_dir()


def write_refusal(tool_input, homes, programmes_dir):
    """Deny a programme-home write by path, not by shell text: only the packager's digest file is allowed.

    Paths compare case-folded because the macOS filesystem treats PROGRAMMES and programmes as one folder."""
    target = tool_input.get("file_path") or tool_input.get("notebook_path")
    if not isinstance(target, str) or not target:
        return None
    real = os.path.realpath(target).casefold()
    protected = os.path.realpath(programmes_dir).casefold()
    if real != protected and not real.startswith(protected + os.sep):
        return None
    if real in {os.path.join(os.path.realpath(home), DIGEST_NAME).casefold() for home in homes}:
        return None
    return f"a sub-agent may write only <home>/{DIGEST_NAME} inside a programme's home folder"


def decide(stdin_raw, drives=_drives_programme, homes=_driven_homes):
    try:
        data = json.loads(stdin_raw or "{}")
    except ValueError:
        return None
    if not isinstance(data, dict) or not data.get("agent_id"):
        return None
    tool, tool_input = data.get("tool_name"), data.get("tool_input") or {}
    if tool == "Bash":
        command = tool_input.get("command")
        if not isinstance(command, str) or not drives(data.get("session_id")):
            return None
        reason = refusal(command)
    elif tool in WRITE_TOOLS:
        driven, programmes_dir = homes(data.get("session_id"))
        reason = write_refusal(tool_input, driven, programmes_dir) if driven else None
    else:
        return None
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
