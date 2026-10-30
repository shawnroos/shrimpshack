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
_RUNTIME = re.compile(r"[$`(){}*?\[~@\\<>|;&]")
_TTY_PATH = re.compile(r"/dev/(?:tty|pts/)[\w$`({/]")
_TTY_WRITE = re.compile(r">|\btee\b|\bof=|\b(?:cp|mv|ln)\b")
# A word after one of these (or after an assignment) is the command being run.
_LIST_BREAKS = _SHELL_BREAKS - {"(", ")"}
_INTERPRETERS = re.compile(r"^(?:python[\d.]*|ruby|perl|node|php|osascript|lua|deno|bun)$")
_STRING_LITERAL = re.compile(r"\"((?:[^\"\\]|\\.)*)\"|'((?:[^'\\]|\\.)*)'")
_UNPROVEN_VERBS = ("send to a pane auto cannot prove is not the driver's", "runtime-built command", "tty write")
_COMMAND_PREFIX = frozenset({"exec", "env", "command", "nohup", "time", "sudo", "xargs", "builtin", "then", "do", "else",
                             "elif", "if", "while", "until"})


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


def _scan(text: str, depth: int, hosts: list, pane_ids: list, found: list, proven=None) -> None:
    main, bodies = _split_heredocs(_unquote_dollar(text))
    if depth < MAX_DEPTH:
        nested = _substitutions(main) + bodies + [ln for body in bodies for ln in body.splitlines()]
        for script in nested:
            _scan(script, depth + 1, hosts, pane_ids, found, proven)
    tokens = _lex(main)
    piped = main + "\n" + "\n".join(bodies)
    for start, token in enumerate(tokens):
        rest = tokens[start + 1:]
        script = None
        if os.path.basename(token) in _SHELL_BINS:
            script = _shell_script(rest)
        elif token == "eval":
            script = " ".join(_segment(tokens, start + 1)) or None
        elif token == "<<<" and rest:
            script = rest[0]
        if _INTERPRETERS.match(os.path.basename(token)) and depth < MAX_DEPTH and _is_command_word(tokens, start):
            # Inline code of another language can call the host command through a string; scan every string in it.
            for literal in {m for t in _segment(tokens, start) for m in sum(_STRING_LITERAL.findall(t), ()) if " " in m}:
                _scan(literal, depth + 1, hosts, pane_ids, found, proven)
        if script is None and os.path.basename(token) in _SHELL_BINS and depth < MAX_DEPTH and _is_command_word(tokens, start):
            # A shell with no -c script reads one from stdin or a file, so any quoted text in the command may be that script.
            for quoted in {t for t in tokens if " " in t}:
                _scan(quoted, depth + 1, hosts, pane_ids, found, proven)
        if script is not None:
            if depth < MAX_DEPTH:
                _scan(script, depth + 1, hosts, pane_ids, found, proven)
            continue
        segment = _segment(tokens, start)
        for host in hosts:
            if proven is not None:
                hit = _unproven(host, tokens, start, segment, piped, proven)
            else:
                hit = host.is_host_command(segment, pane_ids=pane_ids) or host.is_piped_script(segment, piped, pane_ids=pane_ids)
            if hit:
                found.append((host.name, hit[0], hit[1]))


def _is_command_word(tokens: list, start: int) -> bool:
    before = tokens[start - 1] if start else None
    return before is None or before in _SHELL_BREAKS or before in _COMMAND_PREFIX or ("=" in before and before[:1] != "-")


def _unproven(host, tokens: list, start: int, segment: list, piped: str, proven):
    """The one policy for a session that is not the PM. Hosts only say what a send is (send_class) and which targets
    a call names; a send, or a call that cannot be told from one, passes only when every target is a literal id that
    the registry proves is another session's pane. A command word built at run time is a hit whenever what follows
    is a send."""
    shape = host.send_class(segment, piped)
    if shape is None:
        if not (_RUNTIME.search(tokens[start]) and _is_command_word(tokens, start)):
            return None
        tail = []
        for tok in tokens[start + 1:start + SEGMENT_CAP]:
            if tok in _LIST_BREAKS:
                break
            tail.append(tok)
        binary = list(host.binaries[:1])
        sends = (host.send_class(binary + tail[k:], piped) for k in range(len(tail)))
        return ("runtime-built command", "") if any(c and c[0] == "send" for c in sends) else None
    kind, targets = shape
    if kind == "read":
        return None
    if targets and not any(_RUNTIME.search(t) or not proven(t) for t in targets):
        return None
    return "send to a pane auto cannot prove is not the driver's", ""


def host_sends(command: str, pane_ids: list, proven=None) -> list:
    """(host, verb, target) for every host command in ``command`` that types into a pane.

    proven (a callable, for a session that is not the driver) switches to the allow-list policy in _unproven."""
    terminal_host = load_lib_module("terminal_host")
    hosts = [terminal_host.host_named(name) for name in terminal_host.key_hosts()]
    found = []
    _scan(command, 0, hosts, [i for i in pane_ids if i], found, proven)
    return found


def _sender_workspace(session_id):
    row = load_lib_module("session_registry").lookup(session_id, include_headless=True) if session_id else None
    # A sender with no registry row has no workspace: a bare pane suffix is then treated as possibly the driver's.
    return row["workspace"] if row and row.get("workspace") else None


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


def _proven_other(sender: dict, session_id, drivers: list):
    """Callable: is this literal id a pane some session ran in that is not any live driver's? Built once per command."""
    if "proven" not in sender:
        if "workspace" not in sender:
            sender["workspace"] = _sender_workspace(session_id)
        driver_ids = {str(v).casefold() for d in drivers for v in (d.get("pane_id"), d.get("terminal_id"), d.get("tty")) if v}
        sender["proven"] = load_lib_module("session_registry").known_panes() - driver_ids
    workspace = sender["workspace"]

    def proven(target: str) -> bool:
        low = target.casefold()
        return low in sender["proven"] or (":" not in low and workspace is not None and f"{workspace}:{low}".casefold() in sender["proven"])

    return proven


def _tty_write(command: str) -> bool:
    text = _HIDING_CHARS.sub("", _unquote_dollar(command))
    return _TTY_PATH.search(text) is not None and _TTY_WRITE.search(text) is not None


def _driver_hit(command: str, session_id, driver: dict, sender: dict):
    ids = [driver.get("pane_id"), driver.get("terminal_id")]
    sends = host_sends(command, ids)
    if sends:
        # One session sends, so every driver shares one workspace lookup, made only when a send was found.
        if "workspace" not in sender:
            sender["workspace"] = _sender_workspace(session_id)
        for host, verb, target in sends:
            if _targets_pane(target, driver, sender["workspace"]):
                return host, verb, target
    if session_id == driver.get("session_id"):
        return None
    named = _names_pane(command, driver)
    return (None, None, named) if named else None


def _strict_hit(command: str, session_id, drivers: list, sender: dict):
    """Allow-list for a session that drives no programme: its command may type into a pane only by proving the
    target is another session's pane, and may not write to a tty device."""
    if any(d.get("session_id") == session_id for d in drivers):
        return None
    ids = [i for d in drivers for i in (d.get("pane_id"), d.get("terminal_id"))]
    unproven = host_sends(command, ids, proven=_proven_other(sender, session_id, drivers))
    if unproven:
        return unproven[0][0], unproven[0][1], drivers[0]["pane_id"]
    return (None, "tty write", drivers[0]["pane_id"]) if _tty_write(command) else None


def denial(session_id, command):
    drivers = load_lib_module("session_registry").driver_panes()
    sender = {}
    for driver in drivers:
        hit = _driver_hit(command, session_id, driver, sender)
        if hit is None and driver is drivers[-1]:
            hit = _strict_hit(command, session_id, drivers, sender)
            driver = drivers[0]
        if hit is None:
            continue
        host, verb, target = hit
        row = (driver["run"], "blocked_driver_send", session_id, {
            "verb": verb, "target": target, "pane_id": driver["pane_id"], "command": command})
        unproven = verb in _UNPROVEN_VERBS
        what = (f"a command ({verb}) that auto cannot prove is not aimed at pane" if unproven else
                f"`{host} {verb}` into pane" if verb else "a command naming pane")
        reason = (
            f"auto: blocked {what} {driver['pane_id']}, the driver's pane of programme "
            f"{driver['run']!r}. Only the person types into the programme driver's pane, "
            "and other sessions may not name it in any command; report through the "
            "programme's inbox instead. This attempt is journaled."
            + (" Fix: send only to a literal pane id that another session's registry row shows, with no variable, "
               "substitution or file in the command word or the target; run osascript only with -e and a script "
               "that does not mention Ghostty, a terminal, key presses or string joins; never write to a tty device."
               if unproven else "")
        )
        return {"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }}, row
    return None
