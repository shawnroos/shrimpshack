"""Shells and interpreters in a command: what code each would run, and whether the guard can show it is safe.

Called from send_guard._scan for a session that drives no programme. Every function takes the send_guard module as
`g`, because the lexer helpers and `_scan` live there and an import in the other direction would be circular.
"""
from __future__ import annotations

import os
import re

_VARIABLE = re.compile(r"\$(?:\{([A-Za-z_]\w*)\}|([A-Za-z_]\w*))")
# Set by the system or the harness, and not carried between Bash calls, so a command cannot choose their value.
_HARNESS_ENV = frozenset({"HOME", "PWD", "OLDPWD", "USER", "LOGNAME", "TMPDIR", "SHELL", "LANG", "TERM"})
_WRITERS = frozenset({"tee", "cp", "mv", "install", "ln", "sed", "curl", "wget", "dd"})


def _hit(found: list, cause: str) -> None:
    found.append(("inline", "runtime-built command", "", cause))


def _args(g, tokens: list, start: int):
    """(the program's arguments with redirections removed, its stdin as ("here"|"heredoc"|"file", word) or None)."""
    seg, out, stdin, i = g._segment(tokens, start)[1:], [], None, 0
    while i < len(seg):
        if seg[i] in ("<<<", "<<", "<<-", "<") and i + 1 < len(seg):
            stdin = ({"<<<": "here", "<": "file"}.get(seg[i], "heredoc"), seg[i + 1])
            i += 2
            continue
        out.append(seg[i])
        i += 1
    return g._strip_redirects(out), stdin


def _shell_file(g, args: list):
    """The script file a shell is told to run; None for a `-c` script or stdin."""
    i = 0
    while i < len(args):
        tok = args[i]
        if tok in g._SHELL_VALUE_OPTS:
            i += 2
        elif tok[:1] in ("-", "+"):
            if tok[:2] != "--" and "c" in tok[1:]:
                return None
            i += 1
        else:
            return tok
    return None


def _runner(g, tokens: list, start: int, prog: str, inline):
    """What the program at `start` runs when it is a shell, an interpreter or a path: a dict, else None."""
    name = os.path.basename(prog).casefold()
    if name in g._SHELL_NAMES or prog in ("source", "."):
        args, stdin = _args(g, tokens, start)
        file = args[0] if prog in ("source", ".") and args else _shell_file(g, args)
        if file is None and stdin and stdin[0] == "file":
            file = stdin[1]
        return {"kind": "shell", "file": file, "args": args, "stdin": stdin, "what": "file" if file else "stdin"}
    lang = inline.interpreter_kind(prog)
    if lang:
        args, stdin = _args(g, tokens, start)
        what, value = inline.plan(lang, args)
        if what == "stdin" and stdin and stdin[0] == "file":
            what, value = "file", stdin[1]
        return {"kind": lang, "file": value if what == "file" else None, "args": args, "stdin": stdin,
                "what": what, "value": value}
    if "/" in prog and prog.startswith(("./", "../", "/", "~")) and not g._OPERATOR_ONLY.match(prog):
        return {"kind": "exec", "file": prog, "args": [], "stdin": None, "what": "file"}
    return None


def _cwd_track(g, tokens: list, runs: list, base, inline) -> list:
    """The directory each token runs in, following literal `cd`; None once a `cd` operand is built at run time."""
    cwd, out = base, []
    for k, tok in enumerate(tokens):
        out.append(cwd)
        if runs[k] and tok in ("cd", "pushd"):
            operand = next((w for w in tokens[k + 1:k + 3] if w != "--"), None)
            if operand is None:
                cwd = os.path.expanduser("~")
            else:
                cwd = None if operand.startswith("-") else inline.resolve_path(operand, cwd)
    return out


def _prefix_end(g, tokens: list, assigns: list, start: int) -> int:
    """Index just before the assignments and precommands that stand in front of the program at `start`."""
    j = start - 1
    while j >= 0 and (assigns[j] or tokens[j] in g._COMMAND_PREFIX or tokens[j].startswith("-")):
        j -= 1
    return j


def _loader_name(g, tokens: list, assigns: list, start: int, inline):
    """The loader variable set as a prefix of the program (`PYTHONPATH=x python3`, `env BASH_ENV=x bash`)."""
    for j in range(start - 1, _prefix_end(g, tokens, assigns, start), -1):
        name = tokens[j].partition("=")[0].rstrip("+")
        if assigns[j] and inline.LOADER_ENV.match(name):
            return name
    return None


def _writes(g, tokens: list, runs: list, progs: list) -> dict:
    """{normalised path: the writing command's words} for each path the text writes (redirect, tee, cp, mv, sed -i)."""
    out = {}
    for k, tok in enumerate(tokens):
        if tok in (">", ">>", ">|") and k + 1 < len(tokens):
            out[os.path.normpath(tokens[k + 1])] = tokens[progs[k]:k] if progs[k] >= 0 else []
            continue
        name = os.path.basename(tok)
        if not runs[k] or name not in _WRITERS:
            continue
        seg = g._segment(tokens, k)
        plain = [w for w in g._strip_redirects(seg[1:]) if not w.startswith("-")]
        if name == "tee":
            targets = plain
        elif name in ("cp", "mv", "install", "ln") or (
                name == "sed" and any(w.startswith("-i") or w == "--in-place" for w in seg)):
            targets = plain[-1:]
        else:
            targets = []
        for word in targets:
            out[os.path.normpath(word)] = seg
        for i, word in enumerate(seg):
            if name in ("curl", "wget") and word in ("-o", "-O", "--output") and i + 1 < len(seg):
                out[os.path.normpath(seg[i + 1])] = seg
            elif name == "dd" and word.startswith("of="):
                out[os.path.normpath(word[3:])] = seg
    return out


def judge_runners(g, tokens, positions, bodies, looked_up, resolve, depth, hosts, pane_ids, found, proven, ctx) -> None:
    """Refuse when a shell or interpreter would run code the guard cannot show is safe. Any failure here refuses."""
    inline = g.load_lib_module("send_guard_inline")
    try:
        if g.test_hatch_enabled(g._INLINE_FAULT):
            raise RuntimeError("fault injected")
        _judge(g, tokens, positions, bodies, looked_up, resolve, depth, hosts, pane_ids, found, proven, ctx, inline)
    except Exception as exc:
        _hit(found, f"inline:auto could not finish reading this command ({type(exc).__name__}), so it is refused")


def _judge(g, tokens, positions, bodies, looked_up, resolve, depth, hosts, pane_ids, found, proven, ctx, inline) -> None:
    runs, assigns, _globbed, progs = positions
    runners = {}
    for k, tok in enumerate(tokens):
        if runs[k] and k not in looked_up and not assigns[k]:
            runner = _runner(g, tokens, k, resolve(k, tok) or tok, inline)
            if runner:
                runners[k] = runner
    kinds = {os.path.normpath(r["file"]): r["kind"] for r in runners.values() if r["file"]}
    cwds = _cwd_track(g, tokens, runs, ctx.cwd, inline) if runners else []
    heredoc_targets = {os.path.normpath(b.target) for b in bodies if b.target}

    def scan(command: str) -> None:
        if depth >= g.MAX_DEPTH:
            _hit(found, "inline:a command started from this code nests too deeply for auto to read")
        else:
            g._scan(command, depth + 1, hosts, pane_ids, found, proven, shell=True, expands=True, ctx=ctx)

    if depth < g.MAX_DEPTH and kinds:
        for body in bodies:
            kind = kinds.get(os.path.normpath(body.target)) if body.target else None
            if kind == "python":
                why = _python_why(g, body.text, ctx.cwd, kinds, inline, scan)
                if why:
                    _hit(found, f"script:{body.target}: {why}")
            elif kind:
                g._scan(body.text, depth + 1, hosts, pane_ids, found, proven, shell=True, expands=True, ctx=ctx)
    if kinds:
        for path, words in _writes(g, tokens, runs, progs).items():
            if path in kinds and path not in heredoc_targets:
                literal = words[:1] and os.path.basename(words[0]) in ("echo", "printf") and not any(
                    g._RUNTIME_WORD.search(w) for w in words[1:])
                if literal and depth < g.MAX_DEPTH:
                    g._scan(" ".join(words[1:]), depth + 1, hosts, pane_ids, found, proven, shell=True, expands=True, ctx=ctx)
                else:
                    _hit(found, f"script:{path}: its content comes from a command auto cannot read, and the same "
                                "command then runs it")
    for k, run in runners.items():
        loader = _loader_name(g, tokens, assigns, k, inline)
        if loader or any(a in ("--rcfile", "--init-file") for a in run["args"]) or run.get("what") == "loader":
            _hit(found, "inline:" + (f"`{loader}=` makes the program load code auto did not read" if loader else
                                     "an option that loads a startup file auto did not read"))
            continue
        if run["kind"] not in ("shell", "exec") and run["what"] in ("code", "stdin"):
            _judge_inline(g, run, tokens, assigns, k, bodies, resolve, found, inline, cwds[k], kinds, scan)
        operand = run["file"]
        if operand and run["kind"] not in ("shell", "exec") and (g._MARK in operand or operand.startswith("/dev/")):
            _hit(found, "inline:the code comes from a process substitution or a device, which auto cannot read")
        elif operand and os.path.normpath(operand) not in heredoc_targets and depth < g.MAX_DEPTH:
            _judge_file(g, operand, run["kind"], cwds[k], depth, hosts, pane_ids, found, proven, ctx, inline, scan)


def _expanded(code: str, resolve, index: int):
    """(code with each `$NAME` replaced by the literal value set earlier in the command, None) or (None, why)."""
    missing = []

    def value(match):
        name = match.group(1) or match.group(2)
        if name in _HARNESS_ENV:
            return "x"
        found = resolve(index, "$" + name)
        if found is None:
            missing.append(name)
            return ""
        return found

    expanded = _VARIABLE.sub(value, code)
    if missing:
        return None, f"`${missing[0]}` is not set from a literal word earlier in this command"
    if re.search(r"[$`]", expanded):
        return None, "the code holds a substitution or a dollar form auto cannot read"
    return expanded, None


def _writes_then_runs(code: str, kinds: dict, inline):
    """Why inline code that names a file the same command then runs cannot be read: the file does not exist yet."""
    named = {os.path.normpath(s) for s in inline.written_names(code)} & set(kinds)
    return (f"the code writes `{sorted(named)[0]}` and the same command then runs it; run it in a separate "
            "command so auto can read the file first") if named else None


def _stdin_fed(g, command: str, inline) -> bool:
    """Does this literal command line start a shell or interpreter with no script, so it reads one from stdin?"""
    words = g._lex(command)
    run = _runner(g, words, 0, words[0], inline) if words else None
    if not run:
        return False
    if run["kind"] == "shell":
        return not run["file"] and not any(re.fullmatch(r"-[A-Za-z]*c", a) for a in run["args"])
    return run["what"] == "stdin"


def _python_why(g, text: str, cwd, kinds: dict, inline, scan):
    """Why this Python may not run, else None. The literal command lines its spawn calls start are scanned as typed."""
    why, commands = inline.analyse(text)
    why = why or inline.shadowed(text, [cwd]) or _writes_then_runs(text, kinds, inline)
    if why:
        return why
    for command in commands:
        if _stdin_fed(g, command, inline):
            return "a command it starts reads its program from stdin, which auto cannot read"
        scan(command)
    return None


def _judge_inline(g, run, tokens, assigns, start, bodies, resolve, found, inline, cwd, kinds, scan) -> None:
    prog = tokens[start]
    kind, base = run["kind"], os.path.basename(resolve(start, prog) or prog).casefold()
    if run["what"] == "code":
        sources = [(run["value"], True)]
    elif run["stdin"] and run["stdin"][0] == "here":
        sources = [(run["stdin"][1], True)]
    elif run["stdin"] and run["stdin"][0] == "heredoc":
        mine = [b for b in bodies if base in b.readers]
        if not mine:
            return _hit(found, "inline:auto cannot find the heredoc this program reads")
        if any(not b.quoted and re.search(r"\\[$`\\\n]", b.text) for b in mine):
            return _hit(found, "inline:the heredoc is not quoted and holds a backslash escape the shell rewrites; "
                               "quote the delimiter (<<'EOF')")
        sources = [(b.text, not b.quoted) for b in mine]
    elif _prefix_end(g, tokens, assigns, start) >= 0 and tokens[_prefix_end(g, tokens, assigns, start)] in ("|", "|&"):
        return _hit(found, "inline:code piped in from another command cannot be read")
    else:
        return None
    for code, from_shell_word in sources:
        texts = [code]
        if from_shell_word and re.search(r"[$`]", code):
            expanded, why = _expanded(code, resolve, start)
            if why:
                return _hit(found, f"inline:{why}")
            texts.append(expanded)
        for text in texts:
            why = _python_why(g, text, cwd, kinds, inline, scan) if kind == "python" else (
                f"`{kind}` code is not read, and only Python can be shown safe")
            if why:
                return _hit(found, f"inline:{why}")
    return None


def _judge_file(g, operand, kind, cwd, depth, hosts, pane_ids, found, proven, ctx, inline, scan) -> None:
    path = inline.resolve_path(operand, cwd)
    if path is None:
        return
    text, why = inline.fresh_text(path, ctx)
    if why:
        return _hit(found, f"script:{operand}: {why}")
    if text is None:
        return
    judged = inline.file_kind(path, text, kind)
    if judged == "python":
        why = _python_why(g, text, os.path.dirname(path), {}, inline, scan)
    elif judged == "shell":
        sub = []
        g._scan(text, depth + 1, hosts, pane_ids, sub, proven, shell=True, expands=True, ctx=ctx)
        why = "it holds a command auto cannot show is safe" if sub else None
    else:
        why = f"it is {judged} code, which auto does not read"
    if why:
        _hit(found, f"script:{operand}: {why}")
