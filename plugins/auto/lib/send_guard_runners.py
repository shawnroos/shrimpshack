"""Shells and interpreters in a command: what code each would run, and whether the guard can show it is safe.

Called from send_guard._scan for a session that drives no programme. Every function takes the send_guard module as
`g`, because the lexer helpers and `_scan` live there and an import in the other direction would be circular.
"""
from __future__ import annotations

import os
import re

_VARIABLE = re.compile(r"\$(?:\{([A-Za-z_]\w*)\}|([A-Za-z_]\w*))")
_ASSIGN = re.compile(r"^([A-Za-z_]\w*)\+?=(.*)$", re.S)
# Set by the system or the harness, and not carried between Bash calls, so a command cannot choose their value
# unless the same command assigns them.
_HARNESS_ENV = frozenset({"HOME", "PWD", "OLDPWD", "USER", "LOGNAME", "TMPDIR", "SHELL", "LANG", "TERM"})
_WRITERS = frozenset({"tee", "cp", "mv", "install", "ln", "sed", "curl", "wget", "dd"})
_ENV_EXPORTERS = frozenset({"export", "declare", "typeset", "readonly", "local", "env"})
# Programs that run the next program after their own words: `timeout 5 python3 x`, `uv run python x`.
_RUN_WRAPPERS = frozenset({"uv", "poetry", "pipx", "pipenv", "rye", "conda", "hatch"})
_WRAPPER_VALUE_OPTS = frozenset({"--with", "--python", "-p", "--project", "--directory", "--env-file", "--group",
                                 "--extra", "--package", "--index", "--from", "-w", "-e", "--with-requirements"})
_TIMEOUT_VALUE_OPTS = frozenset({"-s", "-k", "--signal", "--kill-after", "-w", "-E", "-c", "-n", "-p"})
_CD_CAP = 16
_SYSTEM_DIRS = ("/bin/", "/usr/bin/", "/usr/local/bin/", "/opt/homebrew/bin/", "/sbin/", "/usr/sbin/")


def _hit(found: list, cause: str) -> None:
    found.append(("inline", "runtime-built command", "", cause))


def _unwrap_once(g, tokens: list, k: int) -> int:
    name = os.path.basename(tokens[k])
    j = k + 1
    if name in ("timeout", "gtimeout", "flock", "taskset", "chrt"):
        while j < len(tokens) and tokens[j].startswith("-"):
            j += 2 if tokens[j] in _TIMEOUT_VALUE_OPTS else 1
        j += 1
    elif name in ("ionice", "numactl"):
        while j < len(tokens) and tokens[j].startswith("-"):
            j += 2 if tokens[j] in _TIMEOUT_VALUE_OPTS else 1
    elif name in _RUN_WRAPPERS:
        while j < len(tokens) and tokens[j].startswith("-"):
            j += 2 if tokens[j] in _WRAPPER_VALUE_OPTS else 1
        if tokens[j:j + 1] != ["run"]:
            return k
        j += 1
        while j < len(tokens) and tokens[j].startswith("-"):
            j += 2 if tokens[j] in _WRAPPER_VALUE_OPTS else 1
    else:
        return k
    return j if j < len(tokens) and tokens[j] not in g._SHELL_BREAKS else k


def _real_program(g, tokens: list, k: int) -> int:
    """Index of the program the wrappers starting at `k` run, else `k`. Wrappers may nest."""
    for _ in range(4):
        nxt = _unwrap_once(g, tokens, k)
        if nxt == k:
            break
        k = nxt
    return k


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
            if tok[:2] != "--" and ("c" in tok[1:] or "s" in tok[1:]):
                return None
            i += 1
        else:
            return tok
    return None


def _has_dash_c(args: list) -> bool:
    return any(re.fullmatch(r"-[A-Za-z]*c", a) for a in args)


def _system_program(prog: str) -> bool:
    """A program named by a path in a system directory, as opposed to a file the worker could have put in place."""
    return prog.startswith(_SYSTEM_DIRS) or "/" not in prog


def _runner(g, tokens: list, start: int, prog: str, inline):
    """What the program at `start` runs when it is a shell, an interpreter or a path: a dict, else None."""
    name = os.path.basename(prog).casefold()
    if name in g._SHELL_NAMES or prog in ("source", "."):
        args, stdin = _args(g, tokens, start)
        file = args[0] if prog in ("source", ".") and args else _shell_file(g, args)
        if file is None and stdin and stdin[0] == "file":
            file = stdin[1]
        return {"kind": "shell", "file": file, "args": args, "stdin": stdin, "what": "file" if file else "stdin",
                "self": None if _system_program(prog) or prog in ("source", ".") else prog}
    lang = inline.interpreter_kind(prog)
    if lang:
        args, stdin = _args(g, tokens, start)
        what, value = inline.plan(lang, args)
        if what == "stdin" and stdin and stdin[0] == "file":
            what, value = "file", stdin[1]
        return {"kind": lang, "file": value if what == "file" else None, "args": args, "stdin": stdin,
                "what": what, "value": value, "self": None if _system_program(prog) else prog}
    if "/" in prog and prog.startswith(("./", "../", "/", "~")) and not g._OPERATOR_ONLY.match(prog):
        return {"kind": "exec", "file": prog, "args": [], "stdin": None, "what": "file"}
    return None


def _cwd_track(g, tokens: list, runs: list, base, inline, resolve):
    """The directories each token may run in, as a frozenset (None = unknown); None when a command changes
    directory more often than auto follows.

    A `cd` may fail, sit in a subshell or follow `&&`/`||`, so the directory before it stays possible.
    """
    here, out = frozenset({base}), []
    for k, tok in enumerate(tokens):
        out.append(here)
        if runs[k] and tok in ("cd", "pushd"):
            j = k + 1
            while j < len(tokens) and tokens[j] in ("-L", "-P", "-e", "-@", "--"):
                j += 1
            operand = tokens[j] if j < len(tokens) and tokens[j] not in g._SHELL_BREAKS else None
            if operand and operand.startswith("$"):
                operand = resolve(j, operand) or operand
            if operand is None:
                moved = {os.path.expanduser("~")}
            elif operand.startswith("-"):
                moved = {None}
            else:
                moved = {inline.resolve_path(operand, c) if c else None for c in here}
            here = frozenset(here | moved)
            if len(here) > _CD_CAP:
                return None
    return out


def _prefix_end(g, tokens: list, assigns: list, start: int) -> int:
    """Index just before the assignments and precommands that stand in front of the program at `start`."""
    j = start - 1
    while j >= 0 and (assigns[j] or tokens[j] in g._COMMAND_PREFIX or tokens[j].startswith("-")):
        j -= 1
    return j


def _piped_in(g, tokens: list, assigns: list, start: int) -> bool:
    j = _prefix_end(g, tokens, assigns, start)
    return j >= 0 and tokens[j] in ("|", "|&")


def _piped_source_literal(g, tokens: list, assigns: list, start: int) -> bool:
    """Is the command piped into the program at `start` an echo or printf of literal words, or a cat of a heredoc?

    send_guard's own scan reads such text for sends (the `piped` text), so a shell fed that way needs no second look.
    """
    pipe = _prefix_end(g, tokens, assigns, start)
    i = pipe - 1
    while i >= 0 and tokens[i] not in g._SHELL_BREAKS:
        i -= 1
    producer = tokens[i + 1:pipe]
    if not producer or producer[0] in _shadowed_names(tokens):
        return False
    name = producer[0]
    if name == "echo":
        return not any(g._RUNTIME_WORD.search(w) for w in producer[1:])
    if name == "printf":
        return len(producer) > 1 and "%" not in producer[1] and not any(g._RUNTIME_WORD.search(w) for w in producer[1:])
    if name == "cat":
        # Only a heredoc or here-string: `cat file <<EOF | sh` also reads the file.
        words, i = [], 1
        while i < len(producer):
            if producer[i] in ("<<", "<<-", "<<<"):
                i += 2
                continue
            words.append(producer[i])
            i += 1
        return not words and len(producer) > 1
    return False


def _shadowed_names(tokens: list) -> set:
    """Names the text defines as shell functions, which then run instead of the program of that name."""
    names = set()
    for k, tok in enumerate(tokens):
        if tok == "function" and k + 1 < len(tokens):
            names.add(tokens[k + 1])
        elif tok.endswith("()") and len(tok) > 2:
            names.add(tok[:-2])
        elif k + 1 < len(tokens) and tokens[k + 1] in ("()", "(") and k + 2 < len(tokens) and tokens[k + 2] in (")", "{", "()"):
            names.add(tok)
    return names


def _safe_path_value(value: str) -> bool:
    """Is every component of a PATH value an absolute directory, or $PATH or $HOME, which the harness sets?"""
    parts = value.split(":")
    return all(part in ("$PATH", "${PATH}", "$HOME", "${HOME}") or part.startswith(("/", "$HOME/", "${HOME}/", "~/"))
               and "$" not in part.replace("$HOME", "").replace("${HOME}", "") for part in parts)


def _loader_hit(g, tokens: list, assigns: list, has_runner: bool, inline):
    """The first setting in the text that makes a program load code the guard did not read."""
    for k, tok in enumerate(tokens):
        match = _ASSIGN.match(tok)
        if not match:
            continue
        j = k - 1
        while j >= 0 and tokens[j].startswith("-"):
            j -= 1
        if not (assigns[k] or (j >= 0 and tokens[j] in _ENV_EXPORTERS)):
            continue
        name = match.group(1)
        if not inline.LOADER_ENV.match(name):
            continue
        if name == "PATH":
            if not _safe_path_value(match.group(2).strip("\"'")):
                return "`PATH` names a directory that is not absolute, so a file there can stand in for a program"
        elif has_runner:
            return f"`{name}=` makes the program load code auto did not read"
    return None


def _keys(inline, operand: str, directories) -> set:
    """Every spelling of an operand: as written, and resolved against each directory it may run in."""
    keys = {os.path.normpath(operand)}
    keys |= {p for p in (inline.resolve_path(operand, d) for d in directories) if p}
    return keys


def _writes(g, tokens: list, runs: list, progs: list) -> dict:
    """[(path as written, the writing command's words)] for each write in the text (redirect, tee, cp, mv, sed -i)."""
    out = []
    for k, tok in enumerate(tokens):
        if tok in (">", ">>", ">|", "&>", "&>>") and k + 1 < len(tokens):
            out.append((os.path.normpath(tokens[k + 1]), tokens[progs[k]:k] if progs[k] >= 0 else []))
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
            out.append((os.path.normpath(word), seg))
        for i, word in enumerate(seg):
            if name in ("curl", "wget") and word in ("-o", "-O", "--output") and i + 1 < len(seg):
                out.append((os.path.normpath(seg[i + 1]), seg))
            elif name == "dd" and word.startswith("of="):
                out.append((os.path.normpath(word[3:]), seg))
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
    for k in range(len(tokens)):
        if k % 64 == 0 and ctx.expired():
            _hit(found, "inline:the command names more programs than auto can read in the time allowed")
            return
        if runs[k] and k not in looked_up and not assigns[k]:
            real = _real_program(g, tokens, k)
            run = _runner(g, tokens, real, resolve(real, tokens[real]) or tokens[real], inline) if real not in runners else None
            if run:
                run["anchor"] = k
                runners[real] = run
            if os.path.basename(tokens[k]) == "env" and any(
                    a == "--split-string" or re.fullmatch(r"-[A-Za-z]*S.*", a) for a in _args(g, tokens, k)[0]):
                _hit(found, "inline:`env -S` runs a command line that is split at run time")
    loader = _loader_hit(g, tokens, assigns, bool(runners), inline)
    if loader:
        _hit(found, f"inline:{loader}")
    cwds = _cwd_track(g, tokens, runs, ctx.cwd, inline, resolve) if runners else []
    if cwds is None:
        _hit(found, "inline:the command changes directory more often than auto follows")
        return
    everywhere = frozenset().union(*cwds) | {ctx.cwd} if cwds else frozenset({ctx.cwd})
    kinds = {}
    for real, run in runners.items():
        if run["file"]:
            for key in _keys(inline, run["file"], cwds[real]):
                kinds[key] = run["kind"]
    heredocs = {}
    for body in bodies:
        if body.target:
            heredocs.setdefault(os.path.normpath(body.target), []).append(body)
    heredoc_keys = set()
    for target in heredocs:
        heredoc_keys |= _keys(inline, target, everywhere)
    writes = _writes(g, tokens, runs, progs)

    def scan(command: str) -> None:
        if depth >= g.MAX_DEPTH:
            _hit(found, "inline:a command started from this code nests too deeply for auto to read")
        else:
            g._scan(command, depth + 1, hosts, pane_ids, found, proven, shell=True, expands=True, ctx=ctx)

    if kinds:
        for target, group in heredocs.items():
            kind = next((kinds[key] for key in _keys(inline, target, everywhere) if key in kinds), None)
            if not kind or depth >= g.MAX_DEPTH:
                continue
            text = "\n".join(b.text for b in group)
            if kind == "python":
                why = _python_why(g, text, [ctx.cwd], kinds, inline, scan)
                if why:
                    _hit(found, f"script:{target}: {why}")
            else:
                g._scan(text, depth + 1, hosts, pane_ids, found, proven, shell=True, expands=True, ctx=ctx)
            if sum(1 for path, _words in writes if path == target) > len(group):
                _hit(found, f"script:{target}: another command in the text also writes it, and the same command then "
                            "runs it")
        for path, words in writes:
            path_keys = _keys(inline, path, everywhere)
            if path_keys & set(kinds) and not path_keys & heredoc_keys:
                literal = words[:1] and os.path.basename(words[0]) in ("echo", "printf") and not any(
                    g._RUNTIME_WORD.search(w) for w in words[1:])
                if literal and depth < g.MAX_DEPTH:
                    g._scan(" ".join(words[1:]), depth + 1, hosts, pane_ids, found, proven, shell=True, expands=True, ctx=ctx)
                else:
                    _hit(found, f"script:{path}: its content comes from a command auto cannot read, and the same "
                                "command then runs it")
    written = set(kinds) & (heredoc_keys | {key for path, _words in writes for key in _keys(inline, path, everywhere)})
    for real, run in runners.items():
        if ctx.expired():
            _hit(found, "inline:the command names more programs than auto can read in the time allowed")
            break
        if run.get("what") == "loader" or any(a in ("--rcfile", "--init-file") for a in run["args"]):
            _hit(found, "inline:an option that loads a startup file auto did not read")
            continue
        if run.get("self") and depth < g.MAX_DEPTH:
            _judge_operand(g, run["self"], "exec", cwds[real], depth, hosts, pane_ids, found, proven, ctx, inline, scan)
        if run["kind"] not in ("shell", "exec") and run["what"] in ("code", "stdin"):
            _judge_inline(g, run, tokens, assigns, real, bodies, resolve, found, inline, cwds[real], kinds, scan)
        if run["kind"] == "shell" and run["what"] == "stdin" and not run["stdin"] and not _has_dash_c(run["args"]) \
                and _piped_in(g, tokens, assigns, run["anchor"]) \
                and not _piped_source_literal(g, tokens, assigns, run["anchor"]):
            _hit(found, "inline:a script piped into a shell cannot be read")
        operand = run["file"]
        if not operand:
            continue
        if g._MARK in operand or (run["kind"] not in ("shell", "exec") and operand.startswith("/dev/")):
            _hit(found, "inline:the code comes from a process substitution or a device, which auto cannot read")
        elif depth < g.MAX_DEPTH and not _keys(inline, operand, cwds[real]) & written:
            _judge_operand(g, operand, run["kind"], cwds[real], depth, hosts, pane_ids, found, proven, ctx, inline, scan)


def _expanded(code: str, resolve, index: int, assigned: set):
    """(code with each `$NAME` replaced by the literal value set earlier in the command, None) or (None, why)."""
    missing = []

    def value(match):
        name = match.group(1) or match.group(2)
        if name in _HARNESS_ENV and name not in assigned:
            return "x"
        found = resolve(index, "$" + name)
        if found is None:
            missing.append(name)
            return ""
        return found

    expanded = _VARIABLE.sub(value, code)
    if missing:
        return None, f"`${missing[0]}` is not set from a literal word earlier in this command"
    if re.search(r"[$`]", expanded):
        return None, "the code holds a substitution or a dollar form auto cannot read"
    return expanded, None


def _writes_then_runs(code: str, kinds: dict, inline):
    """Why inline code that names a file the same command then runs cannot be read: the file may not exist yet."""
    named = {os.path.normpath(s) for s in inline.written_names(code)} & set(kinds)
    return (f"the code writes `{sorted(named)[0]}` and the same command then runs it; run it in a separate "
            "command so auto can read the file first") if named else None


def _command_facts(g, command: str, inline) -> tuple:
    """(a shell or interpreter in the command line reads its program from stdin, the script files it runs)."""
    words = g._lex(command)
    runs, assigns = g._command_positions(words)[:2]
    stdin_fed, files = False, set()
    for k in range(len(words)):
        if not runs[k] or assigns[k]:
            continue
        real = _real_program(g, words, k)
        run = _runner(g, words, real, words[real], inline)
        if not run:
            continue
        if run["file"]:
            files.add(os.path.normpath(run["file"]))
        stdin_fed = stdin_fed or (not run["file"] and not _has_dash_c(run["args"]) if run["kind"] == "shell"
                                  else run["what"] == "stdin")
    return stdin_fed, files


def _python_why(g, text: str, dirs, kinds: dict, inline, scan):
    """Why this Python may not run, else None. The literal command lines its spawn calls start are scanned as typed."""
    why, commands = inline.analyse(text)
    why = why or inline.shadowed(text, dirs) or _writes_then_runs(text, kinds, inline)
    if why:
        return why
    written = {os.path.normpath(s) for s in inline.written_names(text)}
    for command in commands:
        stdin_fed, files = _command_facts(g, command, inline)
        if stdin_fed:
            return "a command it starts reads its program from stdin, which auto cannot read"
        if files & written:
            return "the code writes a file and then starts it; run it in a separate command so auto can read the file first"
        scan(command)
    return None


def _judge_inline(g, run, tokens, assigns, start, bodies, resolve, found, inline, cwds, kinds, scan) -> None:
    prog = tokens[start]
    kind, base = run["kind"], os.path.basename(resolve(start, prog) or prog).casefold()
    dirs = [c for c in cwds if c]
    assigned = {m.group(1) for m in (_ASSIGN.match(t) for t in tokens) if m}
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
    elif _piped_in(g, tokens, assigns, run["anchor"]):
        return _hit(found, "inline:code piped in from another command cannot be read")
    else:
        return None
    for code, from_shell_word in sources:
        texts = [code]
        if from_shell_word and re.search(r"[$`]", code):
            expanded, why = _expanded(code, resolve, start, assigned)
            if why:
                return _hit(found, f"inline:{why}")
            texts.append(expanded)
        for text in texts:
            why = _python_why(g, text, dirs, kinds, inline, scan) if kind == "python" else (
                f"`{kind}` code is not read, and only Python can be shown safe")
            if why:
                return _hit(found, f"inline:{why}")
    return None


def _judge_operand(g, operand, kind, cwds, depth, hosts, pane_ids, found, proven, ctx, inline, scan) -> None:
    """Read the script a runner names, in each directory it may run in; a script that does not exist yet is refused."""
    paths = [inline.resolve_path(operand, c) for c in (cwds if not os.path.isabs(operand) else {None})]
    if not paths or all(p is None for p in paths):
        return
    existing = [p for p in paths if p and os.path.lexists(p)]
    if not existing:
        if None not in paths:
            _hit(found, f"script:{operand}: it does not exist yet, so auto cannot read it; create it in an earlier command")
        return
    for path in dict.fromkeys(existing):
        text, why = inline.fresh_text(path, ctx)
        if why:
            return _hit(found, f"script:{operand}: {why}")
        if text is None:
            continue
        judged = inline.file_kind(path, text, kind)
        interpreter = inline.shebang_interpreter(text)
        if interpreter and not _system_program(interpreter):
            planted, planted_why = inline.fresh_text(interpreter, ctx)
            if planted_why or planted is not None:
                return _hit(found, f"script:{operand}: its shebang names `{interpreter}`, which was written in this session")
        if judged == "python":
            why = _python_why(g, text, [os.path.dirname(path)], {}, inline, scan)
        elif judged == "shell":
            sub = []
            g._scan(text, depth + 1, hosts, pane_ids, sub, proven, shell=True, expands=True, ctx=ctx)
            why = "it holds a command auto cannot show is safe" if sub else None
        else:
            why = f"it is {judged} code, which auto does not read"
        if why:
            return _hit(found, f"script:{operand}: {why}")
