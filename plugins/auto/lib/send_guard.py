"""The send-guard: no session types into a programme driver's pane, on any terminal host.

Host commands are recognised by each host's is_host_command, never by a list here (KTD8).
The driver's pane comes from registry rows. A host variable in the session environment never
proves a pane or a host (KTD3).
"""
from __future__ import annotations

import codecs
import json
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
# Bounds the last-seen file; a PM pane moves a handful of times in a programme's life.
SEEN_CAP = 8
SEGMENT_CAP = 256
_ANSI_C = re.compile(r"\$'((?:[^'\\]|\\.)*)'")
_LOCALE_DOLLAR = re.compile(r"\$(?=\")")
_HEREDOC = re.compile(r"(?<!<)<<-?[ \t]*(['\"]?)\\?([A-Za-z_][\w.-]*)\1")
_ID_EDGE = "A-Za-z0-9_"
_HIDING_CHARS = re.compile(r"[\"'\\\\]")
_RUNTIME = re.compile(r"[$`(){}*?\[~@\\<>|;&]")
# A command word holding any of these may become a different program at run time (a leading `=` is zsh's path
# lookup) and is denied whatever follows it: three review rounds broke every rule that tried to tell from the rest of
# the command whether it types into a pane. A token made only of shell operators is punctuation the lexer split out
# (the `)` and `>` of quoted JavaScript), never a program.
_RUNTIME_WORD = re.compile(r"[$`(){}*?\[~@\\<>|;&]|^=")
_OPERATOR_ONLY = re.compile(r"^[()<>|;&]+$")
_ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*\+?=")
# After these an `a=b` word is the program they run, not an assignment.
_RUNS_NEXT_WORD = frozenset({"exec", "command", "nohup", "time", "sudo", "xargs", "builtin"})
# A quoted `">"` lexes the same as the operator, so stripping it could drop a real target.
_QUOTED_REDIRECT = re.compile(r"([\"'])\s*\d*(?:[<>]+&?|&>+)\d*\s*\1")
_TEST_WORDS = frozenset({"[", "[[", "{", "}"})
_REDIRECT_OPS = frozenset({"<", ">", ">>", ">&", "<&", "<>", "&>", "&>>", ">|"})
_TTY_PATH = re.compile(r"/dev/(?:tty|pts/)[\w$`({/]")
_TTY_WRITE = re.compile(r">|\btee\b|\bof=|\b(?:cp|mv|ln)\b")
# A word after one of these (or after an assignment) is the command being run.
_LIST_BREAKS = _SHELL_BREAKS - {"(", ")"}
_INTERPRETERS = re.compile(r"^(?:python[\d.]*|ruby|perl|node|php|osascript|lua|deno|bun)$")
_STRING_LITERAL = re.compile(r"\"((?:[^\"\\]|\\.)*)\"|'((?:[^'\\]|\\.)*)'")
_UNPROVEN_VERBS = ("send to a pane auto cannot prove is not the driver's", "runtime-built command", "tty write")
_COMMAND_PREFIX = frozenset({"exec", "env", "command", "nohup", "time", "sudo", "xargs", "builtin", "then", "do", "else",
                             "elif", "if", "while", "until", "{", "!"})


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


def _strip_redirects(words: list) -> list:
    """The words with every redirection removed; the lexer splits `2>&1` into `2`, `>&`, `1`, so the fd digit goes too."""
    if _REDIRECT_OPS.isdisjoint(words):
        return words
    out, i = [], 0
    while i < len(words):
        if words[i] in _REDIRECT_OPS:
            # A file descriptor is one or two digits; a longer number is an argument (a Rex id tail) and stays.
            if len(out) > 1 and out[-1].isdigit() and len(out[-1]) <= 2:
                out.pop()
            i += 2
            continue
        out.append(words[i])
        i += 1
    return out


def _scan(text: str, depth: int, hosts: list, pane_ids: list, found: list, proven=None) -> None:
    main, bodies = _split_heredocs(_unquote_dollar(text))
    if depth < MAX_DEPTH:
        nested = _substitutions(main) + bodies + [ln for body in bodies for ln in body.splitlines()]
        for script in nested:
            _scan(script, depth + 1, hosts, pane_ids, found, proven)
    tokens = _lex(main)
    piped = main + "\n" + "\n".join(bodies)
    strip = _strip_redirects if not _QUOTED_REDIRECT.search(main) else list
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
        segment = strip(_segment(tokens, start))
        for host in hosts:
            if proven is not None:
                hit = _unproven(host, tokens, start, segment, piped, proven)
            else:
                hit = host.is_host_command(segment, pane_ids=pane_ids) or host.is_piped_script(segment, piped, pane_ids=pane_ids)
            if hit:
                found.append((host.name, hit[0], hit[1]))


def _is_command_word(tokens: list, start: int) -> bool:
    before = tokens[start - 1] if start else None
    if before is None or before in _SHELL_BREAKS or before in _COMMAND_PREFIX:
        return True
    return _is_assignment(tokens, start - 1)


def _is_assignment(tokens: list, i: int) -> bool:
    """`NAME=value` in a command word's place, so the shell sets a variable and the next word is the command."""
    if not _ASSIGNMENT.match(tokens[i]) or not _is_command_word(tokens, i):
        return False
    return not i or tokens[i - 1] not in _RUNS_NEXT_WORD


def _unproven(host, tokens: list, start: int, segment: list, piped: str, proven):
    """The one policy for a session that is not the PM. Hosts only say what a send is (send_class) and which targets
    a call names; a send, or a call that cannot be told from one, passes only when every target is a literal id that
    the registry proves is another session's pane. A command word built at run time is always a hit."""
    shape = host.send_class(segment, piped)
    if shape is None:
        word = tokens[start]
        if word in _TEST_WORDS or _OPERATOR_ONLY.match(word) or _is_assignment(tokens, start):
            return None
        return ("runtime-built command", "") if _RUNTIME_WORD.search(word) and _is_command_word(tokens, start) else None
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


def _ids(driver: dict) -> list:
    return [i for i in driver.get("ids") or (driver.get("pane_id"), driver.get("terminal_id")) if i]


def _targets_pane(target: str, driver: dict, workspace) -> bool:
    for ident in _ids(driver):
        if target == ident:
            return True
        if ":" not in target and ident.endswith(":" + target) and (workspace is None or ident.split(":", 1)[0] == workspace):
            return True
    return False


def _names_pane(command: str, driver: dict):
    text = _HIDING_CHARS.sub("", _unquote_dollar(command)).casefold()
    for ident in _ids(driver):
        if ident and re.search(r"(?<![%s])%s(?![%s])" % (_ID_EDGE, re.escape(ident.casefold()), _ID_EDGE), text):
            return ident
    return None


def _proven_other(sender: dict, session_id, drivers: list):
    """Callable: is this literal id a pane some session ran in that is not any live driver's? Built once per command."""
    if "proven" not in sender:
        if "workspace" not in sender:
            sender["workspace"] = _sender_workspace(session_id)
        driver_ids = {str(v).casefold() for d in drivers for v in _ids(d) + [d.get("tty")] if v}
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
    sends = host_sends(command, _ids(driver))
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
    ids = [i for d in drivers for i in _ids(d)]
    unproven = host_sends(command, ids, proven=_proven_other(sender, session_id, drivers))
    if unproven:
        return unproven[0][0], unproven[0][1], drivers[0]["pane_id"]
    return (None, "tty write", drivers[0]["pane_id"]) if _tty_write(command) else None


def _seen_path(driver: dict) -> str:
    return os.path.join(load_lib_module("programme_home").programmes_dir(), "live-panes", f"{driver['lease']}.json")


def _seen_ids(driver: dict) -> list:
    try:
        with open(_seen_path(driver)) as fh:
            data = json.load(fh)
        if isinstance(data, dict) and data.get("session_id") == driver.get("session_id"):
            return [i for i in data.get("ids") or [] if isinstance(i, str) and i]
    except (OSError, ValueError, KeyError, TypeError):
        pass
    return []


def _remember(driver: dict, ids: list) -> None:
    path = _seen_path(driver)
    try:
        os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
        payload = {"session_id": driver.get("session_id"), "ids": ids[:SEEN_CAP]}
        load_lib_module("programme_home").atomic_write(path, lambda fh: json.dump(payload, fh), ".live.")
    except Exception:
        # The live ids still guard this call; only the fallback for a later failed lookup is lost.
        pass


def _live_ids(driver: dict, snap: dict, server) -> list:
    sr = load_lib_module("session_registry")
    row = sr.lookup(driver.get("session_id"), driver.get("server"), driver.get("workspace"), include_headless=True)
    found = load_lib_module("terminal_host").host_named("herdr").presence(
        driver.get("session_id"), row, snap, load_lib_module("programme_sources").session_of,
        current_server=server, clean=sr._clean)
    facts = found.value if found.ok else None
    if not isinstance(facts, dict) or facts.get("state") == "gone" or not facts.get("pane_in_snapshot"):
        return []
    pane = facts.get("pane_id")
    terminal = next((p.get("terminal_id") for p in snap["panes"] if isinstance(p, dict) and p.get("pane_id") == pane), None)
    return [i for i in (pane, terminal) if isinstance(i, str) and i]


def _with_live_ids(drivers: list) -> None:
    """Guard each herdr driver by the pane herdr reports it in now: `herdr pane move` gives a pane a new id, and the
    registry keeps the id from session start. Ids seen once stay guarded when a later lookup fails."""
    herdr_drivers = [d for d in drivers if d.get("host") == "herdr"]
    if not herdr_drivers:
        return
    server = load_lib_module("programme_sources").current_server()
    local = [d for d in herdr_drivers if d.get("server") == server]
    snap = load_lib_module("host_herdr").guard_snapshot() if local else None
    for driver in herdr_drivers:
        live = []
        if snap is not None and driver in local:
            try:
                live = _live_ids(driver, snap, server)
            except Exception:
                # One driver's bad row must not drop the live ids of the others.
                pass
        seen = _seen_ids(driver)
        if live and not set(live) <= set(seen):
            _remember(driver, live + [i for i in seen if i not in live])
        driver["ids"] = list(dict.fromkeys(_ids(driver) + live + seen))
        if live:
            # The denial and the journal name the pane the PM is in now.
            driver["pane_id"] = live[0]


def denial(session_id, command):
    drivers = load_lib_module("session_registry").driver_panes()
    try:
        _with_live_ids(drivers)
    except Exception:
        # A hook error fails open, so a broken live lookup must leave the registry ids guarding, not raise.
        pass
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
