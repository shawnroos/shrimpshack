"""The send-guard: no session types into a programme driver's pane, on any terminal host.

Host commands are recognised by each host's is_host_command, never by a list here (KTD8).
The driver's pane comes from registry rows. A host variable in the session environment never
proves a pane or a host (KTD3).
"""
from __future__ import annotations

import codecs
import os
import re
import shlex
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

_SHELL_BREAKS = frozenset({"&&", "||", ";", "|", "&", "(", ")", ";;", "|&"})
_SHELL_BINS = frozenset({"bash", "sh", "zsh", "dash"})
_SHELL_VALUE_OPTS = frozenset({"-o", "+o", "-O", "+O", "--rcfile", "--init-file"})
MAX_DEPTH = 4
SEGMENT_CAP = 256
_ANSI_C = re.compile(r"\$'((?:[^'\\]|\\.)*)'")
_LOCALE_DOLLAR = re.compile(r"\$(?=\")")
_HEREDOC = re.compile(r"(?<!<)<<-?[ \t]*(['\"]?)\\?([A-Za-z_][\w.-]*)\1")
_ID_EDGE = "A-Za-z0-9_"
_HIDING_CHARS = re.compile(r"[\"'\\\\]")


def _shell_script(rest: list):
    i, takes_script = 0, False
    while i < len(rest) and rest[i] not in _SHELL_BREAKS:
        tok = rest[i]
        if tok in _SHELL_VALUE_OPTS:
            i += 2
            continue
        if tok[:1] in ("-", "+"):
            takes_script = takes_script or (tok[:2] != "--" and "c" in tok[1:])
            i += 1
            continue
        return tok if takes_script else None
    return None


def _ansi_c(match) -> str:
    try:
        return codecs.decode(match.group(1).encode("latin-1", "backslashreplace"), "unicode_escape")
    except Exception:
        return match.group(1)


def _unquote_dollar(command: str) -> str:
    return _LOCALE_DOLLAR.sub("", _ANSI_C.sub(lambda m: shlex.quote(_ansi_c(m)), command))


def _split_heredocs(text: str):
    """(text without heredoc bodies, [bodies]); a body is scanned as its own script."""
    kept, bodies, pos = [], [], 0
    while True:
        found = _HEREDOC.search(text, pos)
        line_end = text.find("\n", found.end()) if found else -1
        if line_end == -1:
            kept.append(text[pos:])
            return "".join(kept), bodies
        kept.append(text[pos:line_end + 1])
        lines, cursor = [], line_end + 1
        while cursor < len(text):
            end = text.find("\n", cursor)
            end = len(text) if end == -1 else end
            line, cursor = text[cursor:end], end + 1
            if line.strip() == found.group(2):
                break
            lines.append(line)
        bodies.append("\n".join(lines))
        pos = cursor
        if pos >= len(text):
            return "".join(kept), bodies


def _substitutions(text: str) -> list:
    """Scripts inside $( ), <( ), >( ) and backticks; nested ones are found when the inner text is scanned."""
    out, i = [], 0
    while i < len(text):
        if text[i:i + 2] in ("$(", "<(", ">("):
            depth, j = 1, i + 2
            while j < len(text) and depth:
                depth += (text[j] == "(") - (text[j] == ")")
                j += 1
            out.append(text[i + 2:j - 1] if depth == 0 else text[i + 2:])
            i += 2
        elif text[i] == "`":
            j = text.find("`", i + 1)
            out.append(text[i + 1:] if j == -1 else text[i + 1:j])
            i = len(text) if j == -1 else j + 1
        else:
            i += 1
    return out


def _lex(text: str) -> list:
    try:
        lexer = shlex.shlex(text, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        return list(lexer)
    except ValueError:
        # An unbalanced quote must not hide a send behind it.
        return text.split()


def _segment(tokens: list, start: int) -> list:
    end = start
    while end < len(tokens) and end - start < SEGMENT_CAP and (end == start or tokens[end] not in _SHELL_BREAKS):
        end += 1
    return tokens[start:end]


def _scan(text: str, depth: int, hosts: list, pane_ids: list, found: list) -> None:
    main, bodies = _split_heredocs(_unquote_dollar(text))
    if depth < MAX_DEPTH:
        nested = _substitutions(main) + bodies + [ln for body in bodies for ln in body.splitlines()]
        for script in nested:
            _scan(script, depth + 1, hosts, pane_ids, found)
    tokens = _lex(main)
    for start, token in enumerate(tokens):
        rest = tokens[start + 1:]
        script = None
        if os.path.basename(token) in _SHELL_BINS:
            script = _shell_script(rest)
        elif token == "eval":
            script = " ".join(_segment(tokens, start + 1)) or None
        elif token == "<<<" and rest:
            script = rest[0]
        if script is not None:
            if depth < MAX_DEPTH:
                _scan(script, depth + 1, hosts, pane_ids, found)
            continue
        segment = _segment(tokens, start)
        for host in hosts:
            hit = host.is_host_command(segment, pane_ids=pane_ids)
            if hit:
                found.append((host.name, hit[0], hit[1]))


def host_sends(command: str, pane_ids: list) -> list:
    """(host, verb, target) for every host command in ``command`` that types into a pane."""
    terminal_host = load_lib_module("terminal_host")
    hosts = [terminal_host.host_named(name) for name in terminal_host.key_hosts()]
    found = []
    _scan(command, 0, hosts, [i for i in pane_ids if i], found)
    return found


def _sender_workspace(session_id):
    row = load_lib_module("session_registry").lookup(session_id, include_headless=True) if session_id else None
    if row and row.get("workspace"):
        return row["workspace"]
    # A sender with no registry row has no other evidence of its workspace.
    return os.environ.get("HERDR_WORKSPACE_ID") or None


def _targets_pane(target: str, driver: dict, workspace) -> bool:
    pane = driver.get("pane_id") or ""
    if target in (pane, driver.get("terminal_id")):
        return True
    if ":" in target or not pane.endswith(":" + target):
        return False
    return workspace is None or pane.split(":", 1)[0] == workspace


def _names_pane(command: str, driver: dict):
    text = _HIDING_CHARS.sub("", _unquote_dollar(command)).casefold()
    for ident in (driver.get("pane_id"), driver.get("terminal_id")):
        if ident and re.search(r"(?<![%s])%s(?![%s])" % (_ID_EDGE, re.escape(ident.casefold()), _ID_EDGE), text):
            return ident
    return None


def _driver_hit(command: str, session_id, driver: dict):
    ids = [driver.get("pane_id"), driver.get("terminal_id")]
    sends = host_sends(command, ids)
    workspace = _sender_workspace(session_id)
    for host, verb, target in sends:
        if _targets_pane(target, driver, workspace):
            return host, verb, target
    if session_id == driver.get("session_id"):
        return None
    named = _names_pane(command, driver)
    return (None, None, named) if named else None


def denial(session_id, command):
    drivers = load_lib_module("session_registry").driver_panes()
    for driver in drivers:
        hit = _driver_hit(command, session_id, driver)
        if hit is None:
            continue
        host, verb, target = hit
        row = (driver["run"], "blocked_driver_send", session_id, {
            "verb": verb, "target": target, "pane_id": driver["pane_id"], "command": command})
        what = f"`{host} {verb}` into pane" if verb else "a command naming pane"
        reason = (
            f"auto: blocked {what} {driver['pane_id']}, the driver's pane of programme "
            f"{driver['run']!r}. Only the person types into the programme driver's pane, "
            "and other sessions may not name it in any command; report through the "
            "programme's inbox instead. This attempt is journaled."
        )
        return {"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }}, row
    return None
