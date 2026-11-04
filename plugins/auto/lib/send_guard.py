"""The send-guard: a programme's own sessions do not literally type into its driver's pane, on any terminal host.

Only a send the shell runs as written counts. A command that names the pane, reads it, or computes its program or
target passes, and so does any session outside the programme. Host commands are recognised by each host's
is_host_command. The driver's pane comes from registry rows, and a host variable never proves a pane or a host.
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
# Every shell that could read a heredoc body as a script. Wider than _SHELL_BINS, which also drives the `-c`
# script extraction that each shell's own option grammar has to match.
_SHELL_NAMES = frozenset({"bash", "sh", "zsh", "dash", "ksh", "ksh93", "mksh", "pdksh", "ash", "busybox",
                          "fish", "tcsh", "csh", "yash", "posh", "rc", "osh", "xonsh"})
_SHELL_VALUE_OPTS = frozenset({"-o", "+o", "-O", "+O", "--rcfile", "--init-file"})
MAX_DEPTH = 4
# Bounds the last-seen file; a PM pane moves a handful of times in a programme's life.
SEEN_CAP = 8
SEGMENT_CAP = 256
_ANSI_C = re.compile(r"\$'((?:[^'\\]|\\.)*)'")
_LOCALE_DOLLAR = re.compile(r"\$(?=\")")
_HEREDOC = re.compile(r"(?<!<)<<-?[ \t]*(['\"]?)\\?([A-Za-z_][\w.-]*)\1")
_HIDING_CHARS = re.compile(r"\\\n|[\"'\\]")
# Each substitution span becomes this one character before the text is lexed, so the shell's own word boundaries
# survive: `RUN=$(a)-$(b)` stays one assignment instead of lexing into a `-$` word that reads as a program.
# A private-use character cannot appear in a real command and is not whitespace, a quote or a shlex punctuation char,
# so it stays glued to its neighbours exactly as the substitution was.
_MARK = "\ue000"
_QUOTED, _CODE, _COMMENT = 0, 1, 2
# A command word holding any of these may become a different program at run time (a leading `=` is zsh's path lookup).
# A token made only of shell operators is punctuation the lexer split out (the `)` and `>` of quoted JavaScript).
_RUNTIME_WORD = re.compile(r"[$`(){}*?\[~@\\<>|;&]|^=|" + _MARK)
_OPERATOR_ONLY = re.compile(r"^[()<>|;&]+$")
_ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*\+?=")
# After these an `a=b` word is the program they run, not an assignment.
_RUNS_NEXT_WORD = frozenset({"exec", "command", "nohup", "xargs", "builtin"})
# A quoted `">"` lexes the same as the operator, so stripping it could drop a real target.
_QUOTED_REDIRECT = re.compile(r"([\"'])\s*\d*(?:[<>]+&?|&>+)\d*\s*\1")
_REDIRECT_OPS = frozenset({"<", ">", ">>", ">&", "<&", "<>", "&>", "&>>", ">|"})
_COMMAND_PREFIX = frozenset({"exec", "env", "command", "nohup", "time", "sudo", "xargs", "builtin", "then", "do", "else",
                             "elif", "if", "while", "until", "{", "!", "noglob", "nocorrect", "doas", "stdbuf",
                             "caffeinate", "nice", "timeout", "gtimeout"})
# `if [[ a ]] then` and `if { a; } then` have no separator before the keyword, and these words end the condition.
_ENDS_CONDITION = frozenset({"]]", "}"})
# Options of a precommand that take the next word as their value; any other option keeps the command position.
_PREFIX_VALUE_OPTS = {
    "sudo": frozenset({"-u", "-g", "-h", "-p", "-C", "-r", "-t", "-U", "-D", "-R", "-T"}),
    "doas": frozenset({"-u", "-C"}),
    "env": frozenset({"-u", "-C", "-S", "-P"}),
    "xargs": frozenset({"-I", "-i", "-n", "-P", "-a", "-d", "-E", "-L", "-s", "-J", "-R", "-S"}),
    "nice": frozenset({"-n"}),
    "stdbuf": frozenset({"-i", "-o", "-e"}),
    "exec": frozenset({"-a"}),
    "time": frozenset({"-o", "-f"}),
    "timeout": frozenset({"-k", "-s"}),
    "gtimeout": frozenset({"-k", "-s"}),
}


def _shell_script(tokens: list, i: int):
    takes_script = False
    while i < len(tokens) and tokens[i] not in _SHELL_BREAKS:
        tok = tokens[i]
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


def _char_kinds(text: str) -> bytearray:
    kinds, quote, escaped, comment, tick = bytearray(len(text)), None, False, False, False
    for i, ch in enumerate(text):
        if comment:
            # A comment inside backticks ends at the closing backtick: the shell reads the span on its own.
            ends_span = tick and ch == "`"
            comment, tick = ch != "\n" and not ends_span, tick and not ends_span
        elif escaped:
            escaped = False
        elif ch == "\\" and quote != "'":
            escaped = True
        elif quote:
            quote = None if ch == quote else quote
        elif ch in "'\"":
            quote = ch
        elif ch == "`":
            tick = not tick
        # `)` is left out on purpose: `$(date)#x` is one word to the shell, and reading a real `(a)#x` comment as code
        # only scans more text.
        elif ch == "#" and (i == 0 or text[i - 1] in " \t\n;&|("):
            comment = True
        kinds[i] = _COMMENT if comment else _QUOTED if quote else _CODE
    return kinds


def _strip_comments(text: str) -> str:
    return "".join(ch for ch, kind in zip(text, _char_kinds(text)) if kind != _COMMENT)


def _heredoc_reader_is_shell(text: str, start: int, line_end: int) -> bool:
    """Could a shell run this heredoc's body?

    Only a plain line whose own command is a named non-shell program proves it could not. A pipe, a list operator,
    a variable or a substitution on that line can all hand the body to a shell (`cat <<'EOF' | ksh`, `| $S`), and
    a shell that runs the body reads it as a script however the delimiter was quoted. So anything else is shell:
    this is the direction that fails closed.
    """
    line = text[text.rfind("\n", 0, start) + 1:line_end]
    words = _lex(_strip_comments(line))
    if not words:
        return True
    runs, assigns = _command_positions(words)[:2]
    programs = [w for k, w in enumerate(words)
                if runs[k] and not assigns[k] and not _OPERATOR_ONLY.match(w) and w not in _COMMAND_PREFIX]
    if not programs:
        return True
    # Every program on the line, not only the first: the body goes to the pipeline, so `cat <<'EOF' | ksh` hands
    # it to a shell. A program built at run time could be any of them.
    return any(os.path.basename(w).casefold() in _SHELL_NAMES or w in ("eval", "source", ".")
               or _RUNTIME_WORD.search(w) for w in programs)


def _split_heredocs(text: str):
    """(text without heredoc bodies, [(body, a shell runs it)])."""
    kept, bodies, pos, kinds = [], [], 0, _char_kinds(text)
    while True:
        found = _HEREDOC.search(text, pos)
        while found is not None and kinds[found.start()] != _CODE:
            # `# <<'EOF'` and `'<<\"EOF\"'` are not heredocs to any shell, and reading one as a heredoc would take
            # the real commands after it out of the scanned text.
            found = _HEREDOC.search(text, found.end())
        line_end = text.find("\n", found.end()) if found else -1
        if line_end == -1:
            kept.append(text[pos:])
            return "".join(kept), bodies
        kept.append(text[pos:line_end + 1])
        shell = _heredoc_reader_is_shell(text, found.start(), line_end)
        lines, cursor = [], line_end + 1
        while cursor < len(text):
            end = text.find("\n", cursor)
            end = len(text) if end == -1 else end
            line, cursor = text[cursor:end], end + 1
            if line.strip() == found.group(2):
                break
            lines.append(line)
        bodies.append(("\n".join(lines), shell))
        pos = cursor
        if pos >= len(text):
            return "".join(kept), bodies


def _mark_substitutions(text: str):
    """(text with each outermost $( ), <( ), >( ) and backtick span replaced by one marker, [(contents, arithmetic)]).

    Only outermost spans are returned; nested ones are found when the contents are scanned. An unterminated span
    swallows the rest of the text, which keeps a half-written send inside it from escaping the scan.
    """
    out, spans, i, quote, escaped = [], [], 0, None, False
    while i < len(text):
        ch = text[i]
        # Quoting decides what the shell expands: single quotes expand nothing, double quotes expand `$( )` and
        # backticks but not a process substitution, and a backslash outside single quotes escapes the next char.
        if escaped or (ch == "\\" and quote != "'"):
            escaped = not escaped
            out.append(ch)
            i += 1
            continue
        if quote == "'":
            # Single quotes expand nothing, so no span can open until they close.
            quote = None if ch == "'" else quote
            out.append(ch)
            i += 1
            continue
        if ch == "'" and quote is None:
            quote = "'"
            out.append(ch)
            i += 1
            continue
        if ch == '"':
            quote = None if quote == '"' else '"'
            out.append(ch)
            i += 1
            continue
        if text[i:i + 2] == "$(" or (text[i:i + 2] in ("<(", ">(") and quote is None):
            arithmetic = text[i:i + 3] == "$(("
            depth, j = 1, i + 2
            while j < len(text) and depth:
                depth += (text[j] == "(") - (text[j] == ")")
                j += 1
            spans.append((text[i + 2:j - 1] if depth == 0 else text[i + 2:], arithmetic))
            out.append(_MARK)
            i = j if depth == 0 else len(text)
        elif ch == "`":
            j = text.find("`", i + 1)
            spans.append((text[i + 1:] if j == -1 else text[i + 1:j], False))
            out.append(_MARK)
            i = len(text) if j == -1 else j + 1
        else:
            out.append(ch)
            i += 1
    return "".join(out), spans


def _substitution_scripts(spans: list, depth: int = 0) -> list:
    """The spans that hold commands. Arithmetic holds none, so only its own nested substitutions are returned.

    Bounded like `_scan`: nested arithmetic is attacker-controlled, and an unbounded walk here raises
    RecursionError, which the hook swallows into an allow.
    """
    scripts = []
    for contents, arithmetic in spans:
        if not arithmetic:
            scripts.append(contents)
        elif depth < MAX_DEPTH:
            scripts.extend(_substitution_scripts(_mark_substitutions(contents)[1], depth + 1))
        else:
            # Past the bound the arithmetic is scanned as a script rather than dropped: it fails closed.
            scripts.append(contents)
    return scripts


def _newlines_as_breaks(text: str) -> str:
    """The shell ends a command at a newline, but the lexer reads one as a space. A quoted newline stays, and a
    backslash-newline goes, because the shell deletes it before it reads words and the lexer would keep the newline."""
    out, quote, escaped = [], None, False
    for ch in text:
        if escaped:
            escaped = False
            if ch == "\n":
                out.pop()
                continue
        elif ch == "\\" and quote != "'":
            escaped = True
        elif quote:
            quote = None if ch == quote else quote
        elif ch in "'\"":
            quote = ch
        elif ch == "\n":
            ch = " ;\n"
        out.append(ch)
    return "".join(out)


def _lex(text: str) -> list:
    try:
        lexer = shlex.shlex(text, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        # shlex would start a comment at a `#` inside a word, where the shell does not; _strip_comments has removed
        # the real ones by now.
        lexer.commenters = ""
        return list(lexer)
    except ValueError:
        # An unbalanced quote must not hide a send on a later line, so the line ends stay command breaks.
        return [tok for line in text.splitlines() for tok in line.split() + [";"]]


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


def _command_positions(tokens: list) -> tuple:
    """(runs, assigns, progs): per token, whether it sits where the shell runs a program, whether it is a `NAME=value`
    assignment there, and the index of the program its command runs. One left-to-right pass, because a hook that times
    out or raises lets the command through. Redirections keep the position; a precommand's flags and assignments keep it too."""
    runs, assigns, stack = [False] * len(tokens), [False] * len(tokens), []
    progs, cur_prog = [-1] * len(tokens), -1
    at_cmd, prefix, skip = True, None, 0
    in_case, patterns = False, False
    for k, tok in enumerate(tokens):
        progs[k] = cur_prog
        if skip:
            skip -= 1
            continue
        if tok == "esac":
            # Tested before the pattern branch below: `;;` arms the next branch's pattern, so `esac` arrives while
            # that is armed and would be eaten as a pattern, latching every later word out of command position.
            in_case, patterns, at_cmd, prefix = False, False, False, None
            continue
        if patterns and not _OPERATOR_ONLY.match(tok):
            # A `case` pattern names no program: `*queued*)` is a glob the shell matches, not a command to run.
            runs[k] = False
            continue
        nxt = tokens[k + 1] if k + 1 < len(tokens) else None
        if tok in _REDIRECT_OPS:
            skip = 1
            continue
        if tok.isdigit() and len(tok) <= 2 and nxt in _REDIRECT_OPS:
            continue
        runs[k] = at_cmd
        if _OPERATOR_ONLY.match(tok):
            # The lexer joins neighbouring operators (`);`, `;>`, `<(`), so read them one character at a time.
            prev = tokens[k - 1] if k else ""
            for idx, ch in enumerate(tok):
                before = tok[idx - 1] if idx else prev[-1:]
                if ch == "(":
                    kind = "sub" if before in ("$", "<", ">") else "array" if before == "=" else "group"
                    stack.append((kind, at_cmd))
                    at_cmd, prefix = kind != "array", None
                elif ch == ")":
                    if patterns:
                        patterns = False
                        at_cmd, prefix = True, None
                        continue
                    kind, saved = stack.pop() if stack else ("group", True)
                    at_cmd, prefix = (True if kind == "group" else saved), None
                elif ch in ";|&":
                    at_cmd, prefix, cur_prog = True, None, -1
            if in_case and ";;" in tok:
                # One branch ended, so the next word is the following branch's pattern.
                patterns = True
            if tok[-1] in "<>":
                skip = 1
            continue
        if tok == "case" and at_cmd:
            in_case, patterns, at_cmd, prefix = True, False, False, None
            continue
        if in_case and not patterns and tok == "in":
            patterns = True
            continue
        # `function f { ...` reaches `{` with no command position, and `echo do herdr` must not gain one.
        if tok in _COMMAND_PREFIX and (at_cmd or tok == "{" or (k and tokens[k - 1] in _ENDS_CONDITION)):
            at_cmd, prefix = True, tok
        elif at_cmd and _ASSIGNMENT.match(tok) and not (k and tokens[k - 1] in _RUNS_NEXT_WORD):
            assigns[k] = True
        elif at_cmd and prefix and tok.startswith("-"):
            if prefix == "command" and tok in ("-v", "-V"):
                at_cmd, prefix = False, None
            elif tok in _PREFIX_VALUE_OPTS.get(prefix, ()):
                skip = 1
        elif at_cmd and prefix in ("timeout", "gtimeout"):
            # Its first plain word is the duration; the command comes next.
            prefix = None
        else:
            if at_cmd:
                cur_prog = k
                progs[k] = k
            at_cmd, prefix = False, None
    return runs, assigns, progs


def _scan(text: str, depth: int, hosts: list, pane_ids: list, found: list) -> None:
    main, bodies = _split_heredocs(_unquote_dollar(text))
    # Before the substitution and newline passes, which have no comment state: an apostrophe in a comment would read
    # as an open quote there.
    main = _strip_comments(main)
    marked, spans = _mark_substitutions(main)
    tokens = _lex(_newlines_as_breaks(marked))
    piped = "\n".join([main] + [body for body, _shell in bodies])
    strip = _strip_redirects if not _QUOTED_REDIRECT.search(main) else list
    runs, assigns, progs = _command_positions(tokens)
    if depth < MAX_DEPTH:
        for script in _substitution_scripts(spans):
            _scan(script, depth + 1, hosts, pane_ids, found)
        for body, shell in bodies:
            if shell:
                _scan(body, depth + 1, hosts, pane_ids, found)
    for start, token in enumerate(tokens):
        script = None
        if token == "<<<":
            # A here-string is a script only when a shell reads it; for any other program it is stdin data.
            owner = os.path.basename(tokens[progs[start]]) if progs[start] >= 0 else ""
            if owner in _SHELL_BINS or owner in ("eval", "source", "."):
                script = next(iter(tokens[start + 1:start + 2]), None)
        elif runs[start] and not assigns[start] and token not in _COMMAND_PREFIX and not _OPERATOR_ONLY.match(token):
            if os.path.basename(token).casefold() in _SHELL_BINS:
                script = _shell_script(tokens, start + 1)
            elif token == "eval":
                script = " ".join(_segment(tokens, start + 1)) or None
            if script is None:
                segment = strip(_segment(tokens, start))
                for host in hosts:
                    hit = host.is_host_command(segment, pane_ids=pane_ids) or host.is_piped_script(segment, piped, pane_ids=pane_ids)
                    if hit:
                        found.append((host.name, hit[0], hit[1]))
        if script is not None and depth < MAX_DEPTH:
            _scan(script, depth + 1, hosts, pane_ids, found)


def _hosts() -> list:
    terminal_host = load_lib_module("terminal_host")
    return [terminal_host.host_named(name) for name in terminal_host.key_hosts()]


def host_sends(command: str, pane_ids: list) -> list:
    """(host, verb, target) for every host command in ``command`` that types into a pane."""
    found = []
    _scan(command, 0, _hosts(), [i for i in pane_ids if i], found)
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
    if not isinstance(facts, dict):
        # The lookup itself failed, so herdr says nothing either way about where the driver is.
        return [], None
    if facts.get("state") == "gone" or not facts.get("pane_in_snapshot"):
        return [], False
    pane = facts.get("pane_id")
    terminal = next((p.get("terminal_id") for p in snap["panes"] if isinstance(p, dict) and p.get("pane_id") == pane), None)
    return [i for i in (pane, terminal) if isinstance(i, str) and i], True


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
        live, hosting = [], None
        if snap is not None and driver in local:
            try:
                live, hosting = _live_ids(driver, snap, server)
            except Exception:
                # One driver's bad row must not drop the live ids of the others.
                pass
        seen = _seen_ids(driver)
        # herdr answered and says the recorded pane does not host the driver, and nothing else names a pane for it:
        # the id below still guards (a live pane auto cannot see must not become sendable), but it is not confirmed.
        driver["unconfirmed"] = hosting is False and not live and not seen
        if live and not set(live) <= set(seen):
            _remember(driver, live + [i for i in seen if i not in live])
        driver["ids"] = list(dict.fromkeys(_ids(driver) + live + seen))
        if live:
            # The denial and the journal name the pane the PM is in now.
            driver["pane_id"] = live[0]


def _mentions_host(command: str) -> bool:
    text = _HIDING_CHARS.sub("", _unquote_dollar(command)).casefold()
    return any(binary in text for host in _hosts() for binary in host.binaries)


def _refusal(session_id, command, driver: dict, host: str, verb: str, target: str) -> tuple:
    whose = (f"the last pane auto saw programme {driver['run']!r}'s driver in. herdr reports that pane "
             "closed and does not say which pane the driver is in now, so the id is still guarded"
             if driver.get("unconfirmed") else
             f"the driver's pane of programme {driver['run']!r}")
    reason = (
        f"auto: blocked `{host} {verb}` into pane {driver['pane_id']}, {whose}. "
        "Only the person types into the programme driver's pane; report through the "
        "programme's inbox instead. This attempt is journaled."
    )
    row = (driver["run"], "blocked_driver_send", session_id, {
        "verb": verb, "target": target, "pane_id": driver["pane_id"], "command": command})
    return {"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }}, row


def denial(session_id, command):
    # Cheapest first: this runs on every Bash call of every session while a programme runs. The record read and the
    # herdr snapshot wait until a command is close to a real send.
    if not _mentions_host(command):
        return None
    session_registry = load_lib_module("session_registry")
    drivers = session_registry.driver_panes()
    if not drivers:
        return None
    sends = host_sends(command, [i for driver in drivers for i in _ids(driver)])
    if not sends:
        return None
    if any(host == "herdr" for host, _verb, _target in sends):
        try:
            _with_live_ids(drivers)
        except Exception:
            # A hook error fails open, so a broken live lookup must leave the registry ids guarding, not raise.
            pass
    workspace = _sender_workspace(session_id)
    for driver in drivers:
        for host, verb, target in sends:
            if _targets_pane(target, driver, workspace) and session_registry.in_programme(driver, session_id):
                return _refusal(session_id, command, driver, host, verb, target)
    return None
