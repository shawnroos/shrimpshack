"""What a `NAME=$(...)` assignment can set, and which variables the text writes in ways the guard cannot read.

The send-guard resolves a `$NAME` command word from a plain assignment earlier in the same text. Two cases it could
not read are covered here. A value set by a substitution that only echoes literal words (ce-code-review picks its
Python this way: `PY="$(for c in python3 python py; do ... echo "$c"; done)"`) has a closed set of values, each of which
the guard can judge as a literal. And a variable the text writes through `eval`, `printf -v`, `declare "$n=..."`,
`source` or `+=` has a value the guard cannot know, so it must never resolve.
"""
from __future__ import annotations

import re

VALUE_CAP = 8
_NAME = r"[A-Za-z_]\w*"
_ASSIGN = re.compile(r"(?<![\w$\[{])(%s)(\[[^\]\n]*\])?(\+?)=(?!=)" % _NAME)
_FOR = re.compile(r"\bfor[ \t]+(%s)[ \t]+in[ \t]+([^;\n]*)(?:;|\n)[ \t\n]*do\b" % _NAME)
_LITERAL = re.compile(r"^[^\s$`\\*?\[\]{}~<>()|;&'\"!#%=]+$")
_REF = re.compile(r"^\$(%s)$|^\$\{(%s)\}$" % (_NAME, _NAME))
_TAINT_BUILTIN = re.compile(r"\b(?:read|getopts|mapfile|readarray|declare|typeset|local|readonly|export|select|unset|let)\b([^;&|\n]*)")
_TAINT_FORMS = (re.compile(r"\bprintf[ \t]+-v[ \t]+(%s)" % _NAME), re.compile(r"\$\{(%s):?[=?]" % _NAME),
                re.compile(r"\(\([ \t]*(%s)[ \t]*[-+*/%%&|^]?=" % _NAME))
# A write the text does not spell out: a sourced file, or a variable-writing builtin handed a name through an
# expansion. Nothing can then be said of any variable in the text.
DROP_ALL = re.compile(
    r"(?:^|[;&|(\n{]|\bdo\b|\bthen\b|\belse\b)[ \t]*(?:(?:source|eval)\b|\.(?=[ \t]))"
    r"|\b(?:declare|typeset|export|local|readonly|read|getopts|mapfile|readarray|let|select|unset)\b(?:[ \t]+-\w+)*[ \t]+[\"']?\$"
    r"|\bprintf[ \t]+-v[ \t]+[\"']?\$")
_BREAKS = frozenset({"&&", "||", ";", "|", "&", ";;", "|&", "(", ")"})
_OPENERS = frozenset({"do", "then", "else", "elif", "if", "while", "until", "{", "!"})
_CLOSERS = frozenset({"done", "fi", "}", "esac"})
_REDIRECTS = frozenset({"<", ">", ">>", ">&", "<&", "<>", "&>", "&>>", ">|"})
_QUIET = frozenset({"true", ":", "break", "continue", "exit", "return", "[", "[[", "test"})
_LOOKUPS = frozenset({"command", "which", "type", "hash"})


def ref_name(token: str):
    """NAME when the token is exactly `$NAME` or `${NAME}`, else None."""
    m = _REF.match(token)
    return (m.group(1) or m.group(2)) if m else None


def _quoted(text: str) -> list:
    """Per character: is it inside quotes."""
    out, quote, escaped = [], None, False
    for ch in text:
        out.append(quote is not None)
        if escaped:
            escaped = False
        elif ch == "\\" and quote != "'":
            escaped = True
        elif quote:
            quote = None if ch == quote else quote
        elif ch in "'\"":
            quote = ch
            out[-1] = True
    return out


def tainted_names(text: str) -> set:
    """Names the text writes in a form other than a plain `NAME=word` the position analysis reads: an append, an
    element, a write inside quotes (an `eval` string), or any name handed to a variable-writing builtin."""
    quoted, names = None, set()
    for m in _ASSIGN.finditer(text):
        if m.group(2) or m.group(3):
            names.add(m.group(1))
            continue
        if quoted is None:
            quoted = _quoted(text)
        if quoted[m.start()]:
            names.add(m.group(1))
    for m in _TAINT_BUILTIN.finditer(text):
        names.update(re.findall(_NAME, m.group(1)))
    for pattern in _TAINT_FORMS:
        names.update(m.group(1) for m in pattern.finditer(text))
    return names


def _loop_values(text: str) -> dict:
    out = {}
    for m in _FOR.finditer(text):
        words = m.group(2).split()
        if words and all(_LITERAL.match(w) for w in words):
            out.setdefault(m.group(1), []).extend(words)
    return out


def _discarded(seg: list) -> bool:
    """Does the command send its stdout nowhere (to /dev/null or to stderr)."""
    for i, tok in enumerate(seg):
        prev = seg[i - 1] if i else ""
        nxt = seg[i + 1] if i + 1 < len(seg) else ""
        if tok in (">", ">>", "&>") and nxt == "/dev/null" and not (prev.isdigit() and prev != "1"):
            return True
        if tok == ">&" and nxt == "2" and (not prev.isdigit() or prev == "1"):
            return True
    return False


def body_values(body: str, lex):
    """The literal words a `$(...)` body can print, or None when it can print anything else.

    The only commands that may produce output are `echo` and `printf` of one literal word or loop variable; lookups
    and a loop variable run as a command must send their output away. Any other command makes the output unknowable.
    """
    if "$(" in body or "`" in body or "" in body:
        return None
    loops = _loop_values(body)
    tokens = lex(body)
    out, i, cmd = [], 0, True
    while i < len(tokens):
        tok = tokens[i]
        if tok in _BREAKS:
            cmd, i = True, i + 1
        elif tok == "for":
            while i < len(tokens) and tokens[i] != "do":
                i += 1
        elif tok in _OPENERS:
            cmd, i = True, i + 1
        elif tok in _CLOSERS:
            cmd, i = False, i + 1
        elif not cmd:
            i += 1
        else:
            j = i + 1
            while j < len(tokens) and tokens[j] not in _BREAKS and tokens[j] not in _OPENERS and tokens[j] not in _CLOSERS:
                j += 1
            seg, i, cmd = tokens[i:j], j, False
            word = seg[0]
            if word in _QUIET:
                continue
            if word in _LOOKUPS or ref_name(word) in loops:
                if not _discarded(seg):
                    return None
                continue
            if word not in ("echo", "printf"):
                return None
            if _discarded(seg):
                continue
            args = []
            for k, a in enumerate(seg[1:], 1):
                if a in _REDIRECTS or (a.isdigit() and seg[k + 1:k + 2] and seg[k + 1] in _REDIRECTS):
                    break
                args.append(a)
            if len(args) != 1 or args[0].startswith("-"):
                return None
            if ref_name(args[0]) in loops:
                out.extend(loops[ref_name(args[0])])
            elif _LITERAL.match(args[0]) and "%" not in args[0]:
                out.append(args[0])
            else:
                return None
    unique = list(dict.fromkeys(out))
    return unique if 0 < len(unique) <= VALUE_CAP else None
