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
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

_SHELL_BINS = frozenset({"bash", "sh", "zsh", "dash"})
# Every shell that could read a heredoc body as a script. Wider than _SHELL_BINS, which also drives the `-c`
# script extraction that each shell's own option grammar has to match.
_SHELL_NAMES = _SHELL_BINS | {"ksh", "ksh93", "mksh", "pdksh", "ash", "busybox", "fish", "tcsh", "csh", "yash", "posh",
                              "rc", "osh", "xonsh"}
_SHELL_VALUE_OPTS = frozenset({"-o", "+o", "-O", "+O", "--rcfile", "--init-file"})
_STDIN_SCRIPT = _SHELL_NAMES | {"eval", "source", "."}
MAX_DEPTH = 4
# Bounds the last-seen file; a PM pane moves a handful of times in a programme's life.
SEEN_CAP = 8
# A substitution stays in its word as this one character, so the word cannot read as a literal program or target.
# A private-use character cannot appear in a real command.
_MARK = ""
_ANSI_C = re.compile(r"\$'((?:[^'\\]|\\.)*)'", re.S)
_HIDING_CHARS = re.compile(r"\\\n|\$(?=\")|[\"'\\]")
_BACKTICK_ESCAPE = re.compile(r"\\([\\`$])")
_OPERATOR = re.compile(r";;&?|;&|&&|\|\||\|&|&>>?|<<<|<<-?|<&|<>|>>|>&|>\||[;&|()<>]")
_REDIRECTS = frozenset({"<", ">", ">>", ">&", "<&", "<>", "&>", "&>>", ">|"})
_BLOCK_WORDS = frozenset({"{", "}", "]]"})
_BODY_HEADS = frozenset({"for", "select", "coproc"})
_BLOCK_CLOSERS = frozenset({"done", "fi", "esac"})
_BARE_WORD = re.compile(r"[A-Za-z!{]+(?=[\s;&|()]|$)")
_KEEPS_COMMAND_START = frozenset({"if", "then", "elif", "else", "do", "while", "until", "in", "time", "!", "{"})
_ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*(?:\[[^\]]*\])?\+?=")
# A command word holding any of these may become a different program at run time (a leading `=` is zsh's path lookup).
_COMPUTED = re.compile(r"[$`*?\[~{]|^=|" + _MARK)
# Words that keep the command position, each with its options that take the next word as a value.
_PRECOMMANDS = {
    **dict.fromkeys(("if", "then", "do", "else", "elif", "while", "until", "!", "command", "nohup", "builtin",
                     "noglob", "nocorrect", "caffeinate"), frozenset()),
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


class _Reader:
    """One pass over shell text that leaves final words, so no later reader sees quoting or redirections.

    After read(): `commands` holds (words, here-strings) per simple command, `scripts` the text of every substitution,
    and `bodies` (text, whether a shell reads it, whether its delimiter was quoted) per heredoc. An unbalanced quote is
    an ordinary character, because it must not hide a send on a later line.
    """

    def __init__(self, text):
        self.text, self.i = text, 0
        self.commands, self.scripts, self.bodies = [], [], []
        self.words, self.heres = [], []
        self.word, self.in_word, self.quoted = [], False, False
        # What the next word is when it is not an argument: a redirect target, a here-string or a heredoc delimiter.
        self.expect = None
        self.pending, self.line_start = [], 0
        self.array, self.arithmetic = False, False

    def read(self):
        while self.i < len(self.text):
            ch = self.text[self.i]
            step = _STEPS.get(ch)
            if step:
                step(self)
            else:
                self._take(ch)
        self._end_word()
        self._end_command()
        # A shell can sit on any line after the heredoc, so this waits for the whole text.
        self.bodies = [(body, _shell_reads(self.commands[start:end], self.commands[start:]), was_quoted)
                       for body, start, end, was_quoted in self.bodies]
        return self

    def _take(self, ch):
        self.word.append(ch)
        self.in_word = True
        self.i += 1

    def _end_word(self):
        if not self.in_word:
            return
        value, was_quoted, role = "".join(self.word), self.quoted, self.expect
        self.word = []
        self.in_word, self.quoted, self.expect = False, False, None
        if role == "here":
            self.heres.append(value)
        elif role in ("<<", "<<-"):
            self.pending.append((value, role == "<<-", was_quoted))
        elif role is None:
            if self._is_block_word(value, was_quoted):
                self._end_command()
            else:
                self.words.append(value)

    def _is_block_word(self, value, was_quoted):
        if was_quoted or (value not in _BLOCK_WORDS and value != "do"):
            return False
        # As an argument it is a plain word: `echo } herdr pane run` runs echo.
        program = _program(self.words)
        if program is None:
            return value in _BLOCK_WORDS
        head = self.words[program]
        return head in _BODY_HEADS and value in ("do", "{") or value in _BLOCK_WORDS and head in ("[[", "function")

    def _end_command(self):
        if self.words or self.heres:
            self.commands.append((self.words, self.heres))
            self.words, self.heres = [], []

    def _backslash(self):
        if self.text[self.i + 1:self.i + 2] != "\n":
            self.word.append(self.text[self.i + 1:self.i + 2])
            self.in_word = self.quoted = True
        self.i += 2

    def _single_quote(self):
        end = self.text.find("'", self.i + 1)
        if end == -1:
            self._take("'")
            return
        self.word.append(self.text[self.i + 1:end])
        self.in_word = self.quoted = True
        self.i = end + 1

    def _double_quote(self):
        start, kept, taken = self.i, len(self.word), len(self.scripts)
        self.i += 1
        if self.expansions('"'):
            self.quoted = True
        else:
            del self.word[kept:], self.scripts[taken:]
            self.word.append('"')
            self.i = start + 1
        self.in_word = True

    def expansions(self, stop):
        """Reads double-quote rules up to `stop` (None: the end), and says whether it got there."""
        while self.i < len(self.text):
            ch = self.text[self.i]
            if ch == stop:
                self.i += 1
                return True
            if ch == "\\":
                following = self.text[self.i + 1:self.i + 2]
                if following != "\n":
                    self.word.append(following if following in ('"', "\\", "$", "`") else ch + following)
                self.i += 2
            elif self.text.startswith("$(", self.i):
                self._paren_span()
            elif ch == "`":
                self._backtick_span()
            else:
                self.word.append(ch)
                self.i += 1
        return stop is None

    def _paren_span(self):
        end = _closing_paren(self.text, self.i + 2)
        self._substitution(self.text[self.i + 2:end], end + 1)

    def _backtick_span(self):
        end = _closing_backtick(self.text, self.i + 1)
        self._substitution(_BACKTICK_ESCAPE.sub(r"\1", self.text[self.i + 1:end]), end + 1)

    def _substitution(self, script, resume):
        self.scripts.append(script)
        self.word.append(_MARK)
        self.in_word = True
        self.i = resume

    def _dollar(self):
        if self.text.startswith("$(", self.i):
            self._paren_span()
        elif self.text.startswith("$[", self.i):
            end = self.text.find("]", self.i)
            end = len(self.text) if end == -1 else end
            self._substitution(self.text[self.i + 2:end], end + 1)
        elif self.text.startswith('$"', self.i):
            self.i += 1
        else:
            found = _ANSI_C.match(self.text, self.i)
            if found is None:
                self._take("$")
                return
            self.word.append(_ansi_c(found))
            self.in_word = self.quoted = True
            self.i = found.end()

    def _angle(self):
        if self.text.startswith(("<(", ">("), self.i):
            self._paren_span()
        else:
            self._operator()

    def _open_paren(self):
        if self.word and self.word[-1].endswith("=") and not self.quoted:
            self.array = True
            self._take(" ")
        else:
            self.arithmetic = self.arithmetic or self.text.startswith("((", self.i)
            self._operator()

    def _close_paren(self):
        if self.array:
            self.array = False
            self.i += 1
        else:
            self.arithmetic = self.arithmetic and not self.text.startswith("))", self.i)
            self._operator()

    def _comment(self):
        # In an array the word stays open across gaps, so only the source character shows a word start.
        if self.in_word and not (self.array and self.text[self.i - 1] in " \t\n(" and self.text[self.i - 2] != "\\"):
            self._take("#")
        else:
            end = self.text.find("\n", self.i)
            self.i = len(self.text) if end == -1 else end

    def _blank(self):
        if self.array:
            self._take(self.text[self.i])
        else:
            self._end_word()
            self.i += 1

    def _newline(self):
        if self.array:
            self._take("\n")
            return
        self._end_word()
        self._end_command()
        self.i += 1
        for delimiter, strip_tabs, was_quoted in self.pending:
            body = self._heredoc_body(delimiter, strip_tabs)
            self.bodies.append((body, self.line_start, len(self.commands), was_quoted))
        self.pending = []
        self.line_start = len(self.commands)

    def _heredoc_body(self, delimiter, strip_tabs):
        lines = []
        while self.i < len(self.text):
            end = self.text.find("\n", self.i)
            end = len(self.text) if end == -1 else end
            line, self.i = self.text[self.i:end], end + 1
            if (line.lstrip("\t") if strip_tabs else line) == delimiter:
                break
            lines.append(line)
        return "\n".join(lines)

    def _operator(self):
        op = _OPERATOR.match(self.text, self.i).group()
        if op[0] in "<>" and self.in_word and not self.quoted and "".join(self.word).isdigit():
            self.word, self.in_word = [], False
        self._end_word()
        self.i += len(op)
        # `((x << 2))` is a shift, and a heredoc read there would swallow the commands on the next lines.
        if op in ("<<", "<<-") and not self.arithmetic:
            self.expect = op
        elif op == "<<<":
            self.expect = "here"
        elif op in _REDIRECTS:
            self.expect = "target"
        else:
            self._end_command()


_STEPS = {
    "\\": _Reader._backslash, "'": _Reader._single_quote, '"': _Reader._double_quote, "$": _Reader._dollar,
    "`": _Reader._backtick_span, "#": _Reader._comment, " ": _Reader._blank, "\t": _Reader._blank, "\n": _Reader._newline,
    "(": _Reader._open_paren, ")": _Reader._close_paren, "<": _Reader._angle, ">": _Reader._angle,
    ";": _Reader._operator, "&": _Reader._operator, "|": _Reader._operator,
}


def _ansi_c(match) -> str:
    try:
        return codecs.decode(match.group(1).encode("latin-1", "backslashreplace"), "unicode_escape")
    except Exception:
        return match.group(1)


def _closing_paren(text, i):
    """Index of the `)` closing a span whose contents start at i, or len(text) when it never closes.

    A `)` inside a case block or a comment closes nothing. An unmatched `case` runs to the end of the text, which is
    then read as a script, so a misread here refuses rather than hides a send.
    """
    depth, quote, cases, word_start, command_start = 1, None, 0, True, True
    while i < len(text):
        ch = text[i]
        if ch == "\\" and quote != "'":
            i += 2
            word_start = command_start = False
            continue
        if quote:
            quote = None if ch == quote else quote
        elif ch in "'\"":
            quote = ch
            word_start = command_start = False
        elif word_start and ch == "#":
            end = text.find("\n", i)
            i = len(text) if end == -1 else end
            continue
        elif ch in " \t":
            word_start = True
        elif ch in "\n;&|()":
            if not cases:
                depth += (ch == "(") - (ch == ")")
                if not depth:
                    return i
            word_start = command_start = True
        elif word_start and (found := _BARE_WORD.match(text, i)):
            word = found.group()
            if command_start and word == "case":
                cases += 1
            elif command_start and word == "esac":
                cases = max(cases - 1, 0)
            command_start = command_start and word in _KEEPS_COMMAND_START
            word_start = False
            i = found.end()
            continue
        else:
            word_start = command_start = False
        i += 1
    return len(text)


def _closing_backtick(text, i):
    while i < len(text) and text[i] != "`":
        i += 2 if text[i] == "\\" else 1
    return min(i, len(text))


def _program(words):
    """Index of the word the shell runs as the program, or None."""
    i, prefix = 0, None
    while i < len(words):
        word = words[i]
        if word in _PRECOMMANDS:
            prefix = word
            i += 1
        elif _ASSIGNMENT.match(word):
            i += 1
        elif prefix and word.startswith("-"):
            if prefix == "command" and word in ("-v", "-V"):
                return None
            i += 2 if word in _PRECOMMANDS[prefix] else 1
        elif prefix in ("timeout", "gtimeout"):
            # Its first plain word is the duration; the command comes next.
            prefix = None
            i += 1
        else:
            return i
    return None


def _programs(commands) -> list:
    return [words[k] for words, _heres in commands for k in [_program(words)] if k is not None]


def _shell_reads(line, rest) -> bool:
    """A heredoc's `line` naming no program of its own may feed a block opened above it. Otherwise only `rest`, all the
    commands from that line on, can prove no shell reads it, by holding only named non-shells. This fails closed."""
    if not set(_programs(line)) - _BLOCK_CLOSERS:
        return True
    return any(os.path.basename(p).casefold() in _STDIN_SCRIPT or _COMPUTED.search(p) for p in _programs(rest))


def _shell_script(args):
    takes_script, i = False, 0
    while i < len(args):
        tok = args[i]
        if tok in _SHELL_VALUE_OPTS:
            i += 2
        elif tok[:1] in ("-", "+"):
            takes_script = takes_script or (tok[:2] != "--" and "c" in tok[1:])
            i += 1
        else:
            return tok if takes_script else None
    return None


def _heredoc_scripts(bodies) -> list:
    scripts = []
    for body, shell, was_quoted in bodies:
        if shell:
            scripts.append(body)
        elif not was_quoted:
            # An unquoted heredoc expands `$( )` and backticks for any reader.
            reader = _Reader(body)
            reader.expansions(None)
            scripts.extend(reader.scripts)
    return scripts


def _scan(text, depth, hosts, pane_ids, found) -> None:
    reader = _Reader(text).read()
    nested = reader.scripts + _heredoc_scripts(reader.bodies)
    piped = "\n".join([" ".join(part) for command in reader.commands for part in command]
                      + [body for body, _shell, _quoted in reader.bodies])
    for words, heres in reader.commands:
        k = _program(words)
        if k is None:
            continue
        name = os.path.basename(words[k]).casefold()
        if name in _STDIN_SCRIPT:
            nested.extend(heres)
        script = None
        if name in _SHELL_BINS:
            script = _shell_script(words[k + 1:])
        elif words[k] == "eval":
            script = " ".join(words[k + 1:]) or None
        if script is not None:
            nested.append(script)
            continue
        for host in hosts:
            hit = host.is_host_command(words[k:], pane_ids=pane_ids) or host.is_piped_script(words[k:], piped, pane_ids=pane_ids)
            if hit:
                found.append((host.name, hit[0], hit[1]))
    if depth < MAX_DEPTH:
        for script in nested:
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
    text = _HIDING_CHARS.sub("", _ANSI_C.sub(_ansi_c, command)).casefold()
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
            if (_targets_pane(target, driver, workspace) and session_registry.in_programme(driver, session_id)
                    and load_lib_module("programme_checks").run_state("literal-send", driver["run"], session_id)):
                return _refusal(session_id, command, driver, host, verb, target)
    return None
