"""The send-guard: no session types into a programme driver's pane, on any terminal host.

Host commands are recognised by each host's is_host_command, never by a list here (KTD8).
The driver's pane comes from registry rows. A host variable in the session environment never
proves a pane or a host (KTD3).
"""
from __future__ import annotations

import codecs
import collections
import json
import os
import re
import shlex
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module, test_hatch_enabled  # noqa: E402

_SHELL_BREAKS = frozenset({"&&", "||", ";", "|", "&", "(", ")", ";;", "|&"})
_SHELL_BINS = frozenset({"bash", "sh", "zsh", "dash"})
# Every shell that could read a heredoc body as a script. Wider than _SHELL_BINS, which also drives the `-c`
# script extraction that each shell's own option grammar has to match.
_SHELL_NAMES = frozenset({"bash", "sh", "zsh", "dash", "ksh", "ksh93", "mksh", "pdksh", "ash", "busybox",
                          "fish", "tcsh", "csh", "yash", "posh", "rc", "osh", "xonsh"})
_SHELL_VALUE_OPTS = frozenset({"-o", "+o", "-O", "+O", "--rcfile", "--init-file"})
MAX_DEPTH = 4
# One heredoc: its text, whether a shell may run it, whether the delimiter was quoted, the path its reader line
# redirects into (`cat > x.sh <<'EOF'`), and the programs on that line.
_Body = collections.namedtuple("_Body", "text shell quoted target readers")
_INLINE_FAULT = "CLAUDE_AUTO_TEST_SEND_GUARD_INLINE_FAULT"
# Bounds the last-seen file; a PM pane moves a handful of times in a programme's life.
SEEN_CAP = 8
SEGMENT_CAP = 256
_ANSI_C = re.compile(r"\$'((?:[^'\\]|\\.)*)'")
_LOCALE_DOLLAR = re.compile(r"\$(?=\")")
_HEREDOC = re.compile(r"(?<!<)<<-?[ \t]*(['\"]?)\\?([A-Za-z_][\w.-]*)\1")
_ID_EDGE = "A-Za-z0-9_"
_HIDING_CHARS = re.compile(r"[\"'\\\\]")
# Each substitution span becomes this one character before the text is lexed, so the shell's own word boundaries
# survive: `RUN=$(a)-$(b)` stays one assignment instead of lexing into a `-$` word that reads as a program.
# A private-use character cannot appear in a real command and is not whitespace, a quote or a shlex punctuation char,
# so it stays glued to its neighbours exactly as the substitution was.
_MARK = "\ue000"
_RUNTIME = re.compile(r"[$`(){}*?\[~@\\<>|;&]|" + _MARK)
# A command word holding any of these may become a different program at run time (a leading `=` is zsh's path
# lookup) and is denied whatever follows it: three review rounds broke every rule that tried to tell from the rest of
# the command whether it types into a pane. A token made only of shell operators is punctuation the lexer split out
# (the `)` and `>` of quoted JavaScript), never a program.
_RUNTIME_WORD = re.compile(r"[$`(){}*?\[~@\\<>|;&]|^=|" + _MARK)
_OPERATOR_ONLY = re.compile(r"^[()<>|;&]+$")
# A command word that is exactly one variable, so a plain-literal assignment in the same text can name the program.
# `${PY:-x}`, `${PY}/bin` and `$PY.sh` deliberately do not match: the shell can still build another name from them.
_VAR_WORD = re.compile(r"^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?$")
_LOOKUPS = frozenset({"which", "whereis", "type"})
_ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*\+?=")
# After these an `a=b` word is the program they run, not an assignment.
_RUNS_NEXT_WORD = frozenset({"exec", "command", "nohup", "xargs", "builtin"})
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
                             "setsid", "arch", "xcrun", "coproc",
                             "elif", "if", "while", "until", "{", "!", "noglob", "nocorrect", "doas", "stdbuf",
                             "caffeinate", "nice"})
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
}


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


def _code_mask(text: str) -> bytearray:
    """1 for each character the shell reads as code: outside quotes, and outside a `#` comment."""
    mask, quote, escaped, comment = bytearray(len(text)), None, False, False
    for i, ch in enumerate(text):
        if comment:
            comment = ch != "\n"
        elif escaped:
            escaped = False
        elif ch == "\\" and quote != "'":
            escaped = True
        elif quote:
            quote = None if ch == quote else quote
        elif ch in "'\"":
            quote = ch
        elif ch == "#" and (i == 0 or text[i - 1] in " \t\n;&|()"):
            comment = True
        mask[i] = 0 if (comment or quote) else 1
    return mask


def _heredoc_reader_is_shell(text: str, start: int, line_end: int) -> bool:
    """Could a shell run this heredoc's body?

    Only a plain line whose own command is a named non-shell program proves it could not. A pipe, a list operator,
    a variable or a substitution on that line can all hand the body to a shell (`cat <<'EOF' | ksh`, `| $S`), and
    a shell that runs the body reads it as a script however the delimiter was quoted. So anything else is shell:
    this is the direction that fails closed.
    """
    line = text[text.rfind("\n", 0, start) + 1:line_end]
    words = _lex(line)
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


def _reader_info(text: str, start: int, line_end: int):
    """(programs on the heredoc's reader line, the path that line redirects into or None)."""
    words = _lex(text[text.rfind("\n", 0, start) + 1:line_end])
    runs, assigns = _command_positions(words)[:2]
    programs = [os.path.basename(w).casefold() for k, w in enumerate(words)
                if runs[k] and not assigns[k] and not _OPERATOR_ONLY.match(w) and w not in _COMMAND_PREFIX]
    target = None
    for k, word in enumerate(words):
        if word in (">", ">>", ">|") and k + 1 < len(words):
            target = words[k + 1]
        elif os.path.basename(word) == "tee" and runs[k]:
            args = [w for w in words[k + 1:] if not w.startswith("-") and not _OPERATOR_ONLY.match(w)]
            target = args[0] if args else target
    return programs, target


def _split_heredocs(text: str):
    """(text without heredoc bodies, [_Body]).

    A quoted delimiter (`<<'EOF'`, `<<"EOF"`, `<<\\EOF`) is the one case where the shell expands nothing in the
    body, so such a body cannot become a command through `$VAR` either.
    """
    kept, bodies, pos, code = [], [], 0, _code_mask(text)
    while True:
        found = _HEREDOC.search(text, pos)
        while found is not None and not code[found.start()]:
            # `# <<'EOF'` and `'<<\"EOF\"'` are not heredocs to any shell, and reading one as a heredoc would take
            # the real commands after it out of the scanned text.
            found = _HEREDOC.search(text, found.end())
        line_end = text.find("\n", found.end()) if found else -1
        if line_end == -1:
            kept.append(text[pos:])
            return "".join(kept), bodies
        kept.append(text[pos:line_end + 1])
        quoted = bool(found.group(1)) or text[max(0, found.start(2) - 1):found.start(2)] == "\\"
        shell = _heredoc_reader_is_shell(text, found.start(), line_end)
        readers, target = _reader_info(text, found.start(), line_end)
        lines, cursor = [], line_end + 1
        while cursor < len(text):
            end = text.find("\n", cursor)
            end = len(text) if end == -1 else end
            line, cursor = text[cursor:end], end + 1
            if line.strip() == found.group(2):
                break
            lines.append(line)
        bodies.append(_Body("\n".join(lines), shell, quoted, target, readers))
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
    """The shell ends a command at a newline, but the lexer reads one as a space; a quoted or escaped newline stays."""
    out, quote, escaped = [], None, False
    for ch in text:
        if escaped:
            escaped = False
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


def _lookup_names(tokens: list, runs: list) -> set:
    """Indices of words that only name a program for `which`, `type`, `whereis` or `command -v` to look up, so
    `which rex herdr` is not read as a `rex` call with the verb `herdr`. The words end at the next shell break."""
    names = set()
    for k, tok in enumerate(tokens):
        lookup = os.path.basename(tok) in _LOOKUPS or (tok == "command" and tokens[k + 1:k + 2] in (["-v"], ["-V"]))
        if not (lookup and runs[k]):
            continue
        j = k + 1
        while j < len(tokens) and tokens[j] not in _SHELL_BREAKS and not _OPERATOR_ONLY.match(tokens[j]):
            names.add(j)
            j += 1
    return names


def _literal_vars(tokens: list, assigns: list, spans: list):
    """([(index, name, values)], names with an assignment the guard cannot read, substitution bodies read as values).

    A value is a plain word, a copy of an earlier variable, or a substitution that only echoes literal words
    (`PY="$(for c in python3 python; do ...; echo "$c"; done)"`), so a name can hold several values. Any other value
    the shell could rebuild — a glob, a tilde, any other substitution — leaves the name unresolvable even when
    another assignment to it is readable. `export X=y` and `local X=y` put the word in argument position, where
    `assigns` is false, so they never reach here.
    """
    values_of = load_lib_module("send_guard_values")
    out, unreadable, bodies_ok, marks = [], set(), set(), 0
    for k, tok in enumerate(tokens):
        first_mark, marks = marks, marks + tok.count(_MARK)
        if not assigns[k]:
            continue
        name, _, value = tok.partition("=")
        copy = values_of.ref_name(value)
        if not value or name.endswith("+"):
            found = None
        elif value == _MARK and first_mark < len(spans) and not spans[first_mark][1]:
            found = values_of.body_values(spans[first_mark][0], lambda t: _lex(_newlines_as_breaks(t)))
            if found:
                bodies_ok.add(spans[first_mark][0])
        elif copy:
            found = next((vals for _k, n, vals in reversed(out) if n == copy), None)
        else:
            found = None if _RUNTIME_WORD.search(value) else [value]
        # A precommand runs the next word, and position analysis reads the raw token, so resolving `$W` to `nice`
        # would leave `$W $H agent prompt $P go` with `$H` in no command position at all.
        if found and not any(os.path.basename(v) in _COMMAND_PREFIX for v in found):
            out.append((k, name, tuple(found)))
        else:
            unreadable.add(name.rstrip("+"))
    return out, unreadable, bodies_ok


def _loop_vars(tokens: list) -> dict:
    """{name: [(values, first, last)]} for each `for NAME in <literal words>; do … done`: inside the loop body, from
    the `do` to the `done`, the variable holds one of the listed words."""
    out = {}
    for k, tok in enumerate(tokens):
        if tok != "for" or tokens[k + 2:k + 3] != ["in"]:
            continue
        words, j = [], k + 3
        while j < len(tokens) and tokens[j] not in (";", "do"):
            words.append(tokens[j])
            j += 1
        while tokens[j:j + 1] == [";"]:
            j += 1
        if (tokens[j:j + 1] != ["do"] or not words
                or any(_RUNTIME_WORD.search(w) or os.path.basename(w) in _COMMAND_PREFIX for w in words)):
            continue
        depth, end = 1, j + 1
        while end < len(tokens) and depth:
            depth += tokens[end] in ("for", "while", "until")
            depth -= tokens[end] == "done"
            end += 1
        out.setdefault(tokens[k + 1], []).append((tuple(words), j, end))
    return out


def _harmless(value: str, hosts: list) -> bool:
    """Is this program name certainly neither a terminal host, a shell, nor a word that runs another program."""
    base = os.path.basename(value).casefold()
    return (base not in _SHELL_NAMES and base not in _SHELL_BINS and base not in _COMMAND_PREFIX
            and base not in ("eval", "source", ".") and all(h.send_class([base], "") is None for h in hosts))


# A word that means the shell may not reach what follows it in the order it was written. An assignment cannot be
# read as naming a program once one of these stands between the start of the text and the use: `H=herdr; false &&
# H=cat; $H …` runs `herdr` while the last assignment written says `cat`.
_CONTROL_WORDS = frozenset({"&&", "||", "|", "if", "then", "else", "elif", "fi", "while", "until", "do", "done",
                            "for", "case", "esac", "select", "!", "&"})


def _resolver(tokens: list, assigns: list, spans: list, main: str, hosts: list, loops_ok: bool = False):
    """Callable: the program a `$NAME` command word was certainly set to earlier in this same text, or None.

    Resolution holds only in a straight-line command list. Any control word, group or pipeline before the use
    means the shell's own order is not the written order, so the name stays unknown. A name with several values
    resolves only when none of them is a host, a shell or a word that runs another program.
    """
    pairs, unreadable, bodies_ok = _literal_vars(tokens, assigns, spans)
    branch = next((k for k, tok in enumerate(tokens)
                   if tok in _CONTROL_WORDS or (_OPERATOR_ONLY.match(tok) and set(tok) & set("()|&"))), len(tokens))
    # A name assigned anywhere the shell might skip, or might reach in another order, is unknown however many
    # other assignments it has: both `H=cat; true && H=herdr; $H` and `H=herdr; false && H=cat; $H` run the
    # assignment the written order does not end on.
    unknown = {name for k, name, _values in pairs if k >= branch} | unreadable
    values_of = load_lib_module("send_guard_values")
    loops, written = (_loop_vars(tokens) if loops_ok else {}), []

    def resolve(index: int, word: str):
        match = _VAR_WORD.match(word)
        if match is None or match.group(1) in unknown:
            return None
        name = match.group(1)
        seen = [values for k, name_, values in pairs if k < min(index, branch) and name_ == name]
        if name in loops and not any(name_ == name for _k, name_, _v in pairs):
            seen = [values for values, first, last in loops[name] if first < index < last]
        if not seen or (len(seen[-1]) > 1 and not all(_harmless(v, hosts) for v in seen[-1])):
            return None
        if not written:
            # Writes the text does not spell out (`eval "X=…"`, `printf -v`, `source`, `+=`) are read once, on the
            # first variable the text sets and uses: most texts never do, and the read is linear in the text.
            written.append(None if values_of.DROP_ALL.search(main) else values_of.tainted_names(main))
        if written[0] is None or name in written[0]:
            return None
        return seen[-1][0]

    resolve.value_bodies = bodies_ok
    return resolve


def _scan(text: str, depth: int, hosts: list, pane_ids: list, found: list, proven=None,
          shell: bool = True, expands: bool = True, loops_ok: bool = False, ctx=None) -> None:
    main, bodies = _split_heredocs(_unquote_dollar(text))
    marked, spans = _mark_substitutions(main)
    tokens = _lex(_newlines_as_breaks(marked))
    piped = main + "\n" + "\n".join(body.text for body in bodies)
    strip = _strip_redirects if not _QUOTED_REDIRECT.search(main) else list
    positions = _command_positions(tokens)
    runs, assigns, _globbed, progs = positions
    resolve = _resolver(tokens, assigns, spans, main, hosts, loops_ok)
    looked_up = _lookup_names(tokens, runs)

    def program(index: int) -> str:
        return resolve(index, tokens[index]) or tokens[index] if 0 <= index < len(tokens) else ""

    if depth < MAX_DEPTH:
        for script in _substitution_scripts(spans):
            # A loop variable resolves only inside a body whose output sets a variable: that body is read as a value.
            _scan(script, depth + 1, hosts, pane_ids, found, proven, shell=shell, expands=expands,
                  loops_ok=script in resolve.value_bodies, ctx=ctx)
        for body in bodies:
            for script in [body.text] + body.text.splitlines():
                _scan(script, depth + 1, hosts, pane_ids, found, proven,
                      shell=shell and body.shell, expands=expands and not body.quoted, ctx=ctx)
    for start, token in enumerate(tokens):
        rest = tokens[start + 1:]
        prog = resolve(start, token) or token
        base = os.path.basename(prog)
        script, script_shell = None, shell
        if base in _SHELL_BINS:
            script = _shell_script(rest)
        elif prog == "eval":
            script = " ".join(_segment(tokens, start + 1)) or None
            # `agent-browser eval '<js>'` is not the shell builtin, so its argument is not a script a shell runs.
            script_shell = shell and runs[start]
        elif token == "<<<" and rest:
            # A here-string is a script only when a shell reads it; for any other program it is stdin data.
            owner = os.path.basename(program(progs[start]))
            script = rest[0] if owner in _SHELL_BINS or owner in ("eval", "source", ".") else None
        if _INTERPRETERS.match(base) and depth < MAX_DEPTH and runs[start]:
            # Inline code of another language can call the host command through a string; scan every string in it.
            for literal in {m for t in _segment(tokens, start) for m in sum(_STRING_LITERAL.findall(t), ()) if " " in m}:
                _scan(literal, depth + 1, hosts, pane_ids, found, proven, shell=False, expands=True, ctx=ctx)
        if script is None and base in _SHELL_BINS and depth < MAX_DEPTH and runs[start]:
            # A shell with no -c script reads one from stdin or a file, so any quoted text in the command may be
            # that script. Lex the unmarked text for this: `bash <(echo '<send>')` holds the script inside a
            # substitution span, which the marked token list no longer carries.
            for quoted in {t for t in tokens + _lex(_newlines_as_breaks(main)) if " " in t}:
                _scan(quoted, depth + 1, hosts, pane_ids, found, proven, shell=False, expands=True, ctx=ctx)
        if script is not None:
            if depth < MAX_DEPTH:
                _scan(script, depth + 1, hosts, pane_ids, found, proven, shell=script_shell, expands=expands, ctx=ctx)
            continue
        if start in looked_up:
            continue
        segment = strip(_segment(tokens, start))
        for host in hosts:
            if proven is not None:
                hit = _unproven(host, tokens, start, segment, piped, proven, positions, shell, expands, resolve)
            else:
                hit = host.is_host_command(segment, pane_ids=pane_ids) or host.is_piped_script(segment, piped, pane_ids=pane_ids)
            if hit:
                found.append((host.name, hit[0], hit[1], hit[2] if len(hit) > 2 else ""))
    if proven is not None and ctx is not None and shell:
        load_lib_module("send_guard_runners").judge_runners(
            sys.modules[__name__], tokens, positions, bodies, looked_up, resolve, depth, hosts, pane_ids, found, proven, ctx)


def _command_positions(tokens: list) -> tuple:
    """(runs, assigns): per token, whether it sits where the shell runs a program, and whether it is a `NAME=value`
    assignment there. One left-to-right pass, because the hook runs on every command under a 10 s limit and a hook
    that times out or raises lets the command through. Redirections keep the position; a precommand's flags and
    assignments keep it too."""
    runs, assigns, globbed, stack = [False] * len(tokens), [False] * len(tokens), set(), []
    progs, cur_prog = [-1] * len(tokens), -1
    at_cmd, prefix, skip, glob_next = True, None, 0, False
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
        glued, glob_next = glob_next, False
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
                    # [kind, position the enclosing word left, saw an alternation `|` inside]
                    stack.append([kind, at_cmd, False])
                    at_cmd, prefix = kind != "array", None
                elif ch == ")":
                    if patterns:
                        patterns = False
                        at_cmd, prefix, glob_next = True, None, False
                        continue
                    kind, saved, alternation = stack.pop() if stack else ["group", True, False]
                    at_cmd, prefix = (True if kind == "group" else saved), None
                    glob_next = kind == "group" and alternation
                elif ch in ";|&":
                    if ch == "|" and stack:
                        stack[-1][2] = True
                    at_cmd, prefix, glob_next, cur_prog = True, None, False, -1
            if in_case and ";;" in tok:
                # One branch ended, so the next word is the following branch's pattern.
                patterns = True
            if tok[-1] in "<>":
                skip = 1
            continue
        if glued and at_cmd:
            # A word glued to a closing `)` is a zsh glob such as `(re|zz)x`, built when the shell runs it.
            globbed.add(k)
        if tok == "case" and at_cmd:
            in_case, patterns, at_cmd, prefix = True, False, False, None
            continue
        if in_case and not patterns and tok == "in":
            patterns = True
            continue
        if tok in _COMMAND_PREFIX:
            at_cmd, prefix = True, tok
        elif at_cmd and _ASSIGNMENT.match(tok) and not (k and tokens[k - 1] in _RUNS_NEXT_WORD):
            assigns[k] = True
        elif at_cmd and prefix and tok.startswith("-"):
            if prefix == "command" and tok in ("-v", "-V"):
                at_cmd, prefix = False, None
            elif tok in _PREFIX_VALUE_OPTS.get(prefix, ()):
                skip = 1
        else:
            if at_cmd:
                cur_prog = k
                progs[k] = k
            at_cmd, prefix = False, None
    return runs, assigns, globbed, progs


def _unproven(host, tokens: list, start: int, segment: list, piped: str, proven, positions,
              shell: bool, expands: bool, resolve):
    """The one policy for a session that is not the PM. Hosts only say what a send is (send_class) and which targets
    a call names; a send, or a call that cannot be told from one, passes only when every target is a literal id that
    the registry proves is another session's pane. A command word built at run time is a hit unless a plain-literal
    assignment in the same text names it, and that name is no host program."""
    shape = host.send_class(segment, piped)
    if shape is None:
        word = tokens[start]
        runs, assigns, globbed, _progs = positions
        if word in _TEST_WORDS or _OPERATOR_ONLY.match(word) or assigns[start] or not runs[start]:
            return None
        if not shell and (not expands or word[:1] not in ("$", "`", _MARK)):
            # Text no shell runs holds no command words. The one exception is a word the shell expands before
            # another program reads the text, which it does for $VAR and $( ) in an unquoted heredoc.
            return None
        literal = resolve(start, word)
        # Casefolded: this filesystem finds `heRdr` on PATH, so a mixed-case literal names the host program too.
        if literal is not None and host.send_class(
                [os.path.basename(literal).casefold()] + list(segment[1:]), piped) is None:
            return None
        built = _RUNTIME_WORD.search(word) or start in globbed
        return ("runtime-built command", "", "variable" if _VAR_WORD.match(word) else "word") if built else None
    kind, targets = shape
    if kind == "read":
        return None
    if targets and not any(_RUNTIME.search(t) or not proven(t) for t in targets):
        return None
    return "send to a pane auto cannot prove is not the driver's", "", "send"


def host_sends(command: str, pane_ids: list, proven=None, cwd=None, session_start=None) -> list:
    """(host, verb, target) for every host command in ``command`` that types into a pane.

    proven (a callable, for a session that is not the driver) switches to the allow-list policy in _unproven."""
    terminal_host = load_lib_module("terminal_host")
    hosts = [terminal_host.host_named(name) for name in terminal_host.key_hosts()]
    found = []
    ctx = load_lib_module("send_guard_inline").Context(cwd, session_start) if proven is not None else None
    _scan(command, 0, hosts, [i for i in pane_ids if i], found, proven, ctx=ctx)
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
        for host, verb, target, _cause in sends:
            if _targets_pane(target, driver, sender["workspace"]):
                return host, verb, target
    if session_id == driver.get("session_id"):
        return None
    named = _names_pane(command, driver)
    return (None, None, named) if named else None


def _strict_hit(command: str, session_id, drivers: list, sender: dict, cwd=None):
    """Allow-list for a session that drives no programme: its command may type into a pane only by proving the
    target is another session's pane, and may not write to a tty device."""
    if any(d.get("session_id") == session_id for d in drivers):
        return None
    ids = [i for d in drivers for i in _ids(d)]
    started = load_lib_module("session_registry").session_start(session_id)
    unproven = host_sends(command, ids, proven=_proven_other(sender, session_id, drivers), cwd=cwd, session_start=started)
    if unproven:
        return unproven[0][0], unproven[0][1], drivers[0]["pane_id"], unproven[0][3]
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


_FIXES = {
    "variable": "this command runs a program named by a variable whose value auto cannot read. Write the program name "
                "as a literal word, or set the variable earlier in the same command from literal words "
                "(`PY=python3`, or `PY=\"$(for c in python3 python; do ...; echo \"$c\"; done)\"`) before any `&&`, "
                "`||`, `if` or loop, and use it only as a whole word, `$PY`.",
    "word": "this command runs a program whose name is built at run time (a `$(...)`, glob, brace or `~` joined into "
            "the word). Write the program name as one literal word.",
    "inline": "this command runs code auto cannot show is safe: {detail}. Write the step as a plain command, or keep "
              "the Python to parsing, formatting and file work with the standard modules; a process it starts must be "
              "a command line written out as literal strings. Code with quotes or a dollar sign goes in a quoted "
              "heredoc (python3 - <<'EOF'). Remove any PYTHON*, BASH_ENV or relative PATH setting from the command.",
    "script": "the script `{detail}`. A script written in this session is judged like a command typed here: write "
              "each program name as a literal word, set variables from literal words, put the script's text in a "
              "quoted heredoc or the editor tool, or run a script that existed before this session.",
    "send": "send only to a literal pane id that another session's registry row shows, with no variable, "
            "substitution or file in the command word or the target; run osascript only with -e and a script "
            "that does not mention Ghostty, a terminal, key presses or string joins; never write to a tty device.",
}


def _fix(cause: str) -> str:
    kind, _, detail = cause.partition(":")
    return _FIXES.get(kind, _FIXES["send"]).replace("{detail}", detail.strip())


def denial(session_id, command, cwd=None):
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
            hit = _strict_hit(command, session_id, drivers, sender, cwd)
            driver = drivers[0]
        if hit is None:
            continue
        host, verb, target, *extra = hit
        cause = extra[0] if extra else ""
        row = (driver["run"], "blocked_driver_send", session_id, {
            "verb": verb, "target": target, "pane_id": driver["pane_id"], "command": command, "cause": cause})
        unproven = verb in _UNPROVEN_VERBS
        what = (f"a command ({verb}) that auto cannot prove is not aimed at pane" if unproven else
                f"`{host} {verb}` into pane" if verb else "a command naming pane")
        whose = (f"the last pane auto saw programme {driver['run']!r}'s driver in. herdr reports that pane "
                 "closed and does not say which pane the driver is in now, so the id is still guarded"
                 if driver.get("unconfirmed") else
                 f"the driver's pane of programme {driver['run']!r}")
        reason = (
            f"auto: blocked {what} {driver['pane_id']}, {whose}. "
            "Only the person types into the programme driver's pane, "
            "and other sessions may not name it in any command; report through the "
            "programme's inbox instead. This attempt is journaled."
            + (f" Fix: {_fix(cause)}" if unproven else "")
        )
        return {"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }}, row
    return None
