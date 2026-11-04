"""Shells and interpreters in a command: what code each would run, and whether the guard can show it is safe.

Called from send_guard._scan for a session that drives no programme. Every function takes the send_guard module as
`g`, because the lexer helpers and `_scan` live there and an import in the other direction would be circular.
"""
from __future__ import annotations

import os
import re
import shlex

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
                                 "--extra", "--package", "--index", "--from", "-w", "-e", "--with-requirements",
                                 "--with-editable", "--index-url", "--extra-index-url", "--find-links",
                                 "--refresh-package", "--reinstall-package", "--upgrade-package",
                                 "--python-platform", "--cache-dir", "--no-binary-package"})
_TIMEOUT_VALUE_OPTS = frozenset({"-s", "-k", "--signal", "--kill-after", "-w", "-E", "-c", "-n", "-p"})
# A command that unpacks, patches or checks out files may create the script the same command then runs.
_UNPACKERS = frozenset({"tar", "unzip", "gunzip", "bunzip2", "unxz", "7z", "7za", "patch", "rsync", "ditto", "cpio",
                        "truncate"})
_GIT_REWRITERS = frozenset({"apply", "am", "checkout", "restore", "switch", "merge", "pull", "rebase", "reset", "stash",
                            "cherry-pick", "revert", "clone"})
_SCRIPT_KINDS = {".py": "python", ".sh": "shell", ".bash": "shell", ".zsh": "shell", ".js": "node", ".mjs": "node",
                 ".cjs": "node", ".ts": "node", ".rb": "ruby", ".pl": "perl"}
_CD_CAP = 64
_WRAPPER_DEPTH = 16
_SYSTEM_DIRS = ("/bin/", "/usr/bin/", "/usr/local/bin/", "/opt/homebrew/bin/", "/sbin/", "/usr/sbin/")


class _Judge:
    """One command text: the programs in it that run code, and the checks each one gets."""

    def __init__(self, g, tokens, positions, bodies, looked_up, resolve, depth, hosts, pane_ids, found, proven, ctx,
                 inline, cwd_at, text):
        self.g, self.tokens, self.bodies, self.looked_up = g, tokens, bodies, looked_up
        self.text, self._raw = text, False
        self.runs, self.assigns, _globbed, self.progs = positions
        self.resolve, self.depth, self.hosts, self.pane_ids = resolve, depth, hosts, pane_ids
        self.found, self.proven, self.ctx, self.inline, self.cwds = found, proven, ctx, inline, cwd_at
        self.everywhere = frozenset().union(*cwd_at) | ctx.cwds if cwd_at else ctx.cwds
        self.runners: dict = {}
        self.kinds: dict = {}
        self.writes: list = []
        self.heredocs: dict = {}
        self.heredoc_keys: set = set()

    def hit(self, cause: str) -> None:
        _hit(self.found, cause)

    def single_quoted(self, value: str) -> bool:
        """Does every word equal to `value` stand in single quotes in the command text, so the shell passes it as is?

        The text is lexed a second time keeping the quotes. If that lex does not line up with the token list one for
        one, nothing is credited: the answer errs toward the shell expanding it."""
        if self._raw is False:
            try:
                lexer = shlex.shlex(self.text, posix=False, punctuation_chars=True)
                lexer.whitespace_split = True
                raw = list(lexer)
            except ValueError:
                raw = None
            self._raw = raw if raw is not None and len(raw) == len(self.tokens) else None
        if not self._raw or "'" in value:
            return False
        same = [i for i, tok in enumerate(self.tokens) if tok == value]
        return bool(same) and all(self._raw[i] == "'" + value + "'" for i in same)

    def session_wrote_it(self, name: str) -> bool:
        """Is the script named `name`, in any directory the command may run in, one this session wrote or changed?"""
        paths = [self.inline.resolve_path(name, c) for c in (self.everywhere if not os.path.isabs(name) else {None})]
        return any(p and os.path.lexists(p) and self.inline.session_wrote(p, self.ctx) for p in paths)

    def scan(self, command: str, cws=None) -> None:
        if self.depth >= self.g.MAX_DEPTH:
            self.hit("inline:a command started from this code nests too deeply for auto to read")
        else:
            self.g._scan(command, self.depth + 1, self.hosts, self.pane_ids, self.found, self.proven, shell=True,
                         expands=True, ctx=self.ctx.child(cws or self.everywhere))

    def discover(self) -> bool:
        g, tokens, runs, assigns = self.g, self.tokens, self.runs, self.assigns
        for k in range(len(tokens)):
            if k % 64 == 0 and self.ctx.expired():
                self.hit("inline:the command names more programs than auto can read in the time allowed")
                return False
            if runs[k] and k not in self.looked_up and not assigns[k]:
                real = _real_program(g, tokens, k)
                if real < 0:
                    self.hit("inline:more wrappers are nested than auto follows")
                    return False
                if real not in self.runners:
                    run = _runner(g, tokens, real, self.resolve(real, tokens[real]) or tokens[real], self.inline,
                                  wrapped=real != k)
                    if run:
                        run["anchor"] = k
                        self.runners[real] = run
                if os.path.basename(tokens[k]) == "env" and any(
                        a == "--split-string" or re.fullmatch(r"-[A-Za-z]*S.*", a) for a in _args(g, tokens, k)[0]):
                    self.hit("inline:`env -S` runs a command line that is split at run time")
            elif k not in self.looked_up and k not in self.runners and self._is_program_name(tokens[k]):
                # A shell or interpreter named among the arguments of a program auto does not know (`watch`, `script`,
                # `parallel`, `conda run`) may be the program that command runs; a mere mention judges nothing.
                run = _runner(g, tokens, k, tokens[k], self.inline)
                if run:
                    run.update(anchor=k, soft=True, optional=True, self=None)
                    self.runners[k] = run
        return True

    def _is_program_name(self, tok: str) -> bool:
        return ("/" not in tok and not self.g._OPERATOR_ONLY.match(tok) and tok not in ("source", ".")
                and (tok.casefold() in self.g._SHELL_NAMES or bool(self.inline.interpreter_kind(tok))))

    def loader(self) -> None:
        """A setting that makes a program load code auto did not read, when a runner it reaches is in the text."""
        tokens, runs, assigns, progs = self.tokens, self.runs, self.assigns, self.progs
        for k, tok in enumerate(tokens):
            match = _ASSIGN.match(tok)
            if not match or match.group(1) == "PATH" or not self.inline.LOADER_ENV.match(match.group(1)):
                continue
            j = k - 1
            while j >= 0 and tokens[j].startswith("-"):
                j -= 1
            if not (assigns[k] or (j >= 0 and tokens[j] in _ENV_EXPORTERS)):
                continue
            target = self._prefix_target(k) if assigns[k] else None
            reached = any(progs[real] == target or real == target for real in self.runners) if target is not None \
                else any(real > k for real in self.runners)
            if reached:
                self.hit(f"inline:`{match.group(1)}=` makes the program load code auto did not read")
                return

    def _prefix_target(self, k: int):
        """Index of the program a prefix assignment at `k` is set for, None for an assignment statement."""
        t = k + 1
        while t < len(self.tokens) and self.tokens[t] not in self.g._SHELL_BREAKS:
            if self.runs[t] and not self.assigns[t]:
                return t
            t += 1
        return None

    def path_dirs(self, value: str, k: int, cws) -> list:
        """The directories a PATH value names, resolved against where the command runs. A component built from an
        unset variable or a substitution is the harness's or the system's, and is not read."""
        home = os.path.expanduser("~")
        out = []
        for part in value.strip("\"'").split(":"):
            if part in ("$PATH", "${PATH}") or self.g._MARK in part or part.startswith("$("):
                continue
            part = part.replace("${HOME}", home).replace("$HOME", home)
            if part.startswith("~"):
                part = os.path.expanduser(part)
            literal = None
            match = re.match(r"\$\{?([A-Za-z_]\w*)\}?", part)
            if match and match.group(1) in ("PWD", "OLDPWD"):
                bases = [c for c in cws if c]
                rest = part[match.end():]
                out += [os.path.normpath(c + rest) for c in bases]
                continue
            if match:
                literal = self.resolve(k, "$" + match.group(1))
                if literal is None:
                    continue
                part = literal + part[match.end():]
            if "$" in part:
                continue
            if part.startswith("/"):
                out.append(os.path.normpath(part))
            else:
                out += [os.path.normpath(os.path.join(c, part or ".")) for c in cws if c]
        return list(dict.fromkeys(out))

    def path_programs(self) -> None:
        """A program found first in a PATH directory the text names is read when the session wrote it."""
        tokens, runs, assigns = self.tokens, self.runs, self.assigns
        for k, tok in enumerate(tokens):
            match = _ASSIGN.match(tok)
            if not match or match.group(1) != "PATH":
                continue
            j = k - 1
            while j >= 0 and tokens[j].startswith("-"):
                j -= 1
            if not (assigns[k] or (j >= 0 and tokens[j] in _ENV_EXPORTERS)):
                continue
            target = self._prefix_target(k) if assigns[k] else None
            affected = [target] if target is not None else [t for t in range(k + 1, len(tokens))
                                                            if runs[t] and not assigns[t]]
            dirs = self.path_dirs(match.group(2), k, self.cwds[k])
            for t in affected:
                for index in {t, _real_program(self.g, tokens, t)}:
                    self._planted(tokens[index] if index >= 0 else "", dirs, self.cwds[t])

    def _planted(self, name: str, dirs: list, cws) -> None:
        if not name or "/" in name or name.startswith("$"):
            return
        for folder in dirs:
            path = os.path.join(folder, name)
            if os.path.lexists(path):
                self.operand(path, "exec", cws, soft=True)
                return

    def check_writes(self) -> None:
        g, inline, everywhere = self.g, self.inline, self.everywhere
        for body in self.bodies:
            if body.target:
                self.heredocs.setdefault(os.path.normpath(body.target), []).append(body)
        for target in self.heredocs:
            self.heredoc_keys |= _keys(inline, target, everywhere)
        self.writes = _writes(g, self.tokens, self.runs, self.progs)
        for real, run in self.runners.items():
            if run["file"]:
                for key in _keys(inline, run["file"], self.cwds[real]):
                    self.kinds[key] = run["kind"]
        if not self.kinds:
            return
        for target, group in self.heredocs.items():
            kind = next((self.kinds[key] for key in _keys(inline, target, everywhere) if key in self.kinds), None)
            if not kind or self.depth >= g.MAX_DEPTH:
                continue
            text = "\n".join(b.text for b in group)
            if kind == "python":
                why = _python_why(g, text, [c for c in self.ctx.cwds if c], self.kinds, inline, self.scan,
                                  self.session_wrote_it)
                if why:
                    self.hit(f"script:{target}: {why}")
            else:
                self.scan(text)
            if sum(1 for path, _words in self.writes if path == target) > len(group):
                self.hit(f"script:{target}: another command in the text also writes it, and the same command then "
                         "runs it")
        for path, words in self.writes:
            path_keys = _keys(inline, path, everywhere)
            if path_keys & set(self.kinds) and not path_keys & self.heredoc_keys:
                literal = words[:1] and os.path.basename(words[0]) in ("echo", "printf") and not any(
                    g._RUNTIME_WORD.search(w) for w in words[1:]) and not (
                    os.path.basename(words[0]) == "printf" and len(words) > 1 and "%" in words[1])
                if literal and self.depth < g.MAX_DEPTH:
                    self.scan(" ".join(words[1:]))
                else:
                    self.hit(f"script:{path}: its content comes from a command auto cannot read, and the same "
                             "command then runs it")

    def unpackers(self) -> None:
        """A command that unpacks, patches or checks out files, before a script runs in the same text."""
        g, tokens = self.g, self.tokens
        starts = []
        for k, tok in enumerate(tokens):
            if not self.runs[k]:
                continue
            name = os.path.basename(tok)
            if name in _UNPACKERS:
                starts.append((k, name))
            elif name == "git":
                j = k + 1
                while j < len(tokens) and tokens[j].startswith("-"):
                    j += 2 if tokens[j] in ("-C", "-c", "--git-dir", "--work-tree") else 1
                if tokens[j:j + 1] and tokens[j] in _GIT_REWRITERS:
                    starts.append((k, f"git {tokens[j]}"))
        for real, run in self.runners.items():
            if run["file"] and not run.get("soft"):
                before = next((name for k, name in starts if k < real), None)
                if before:
                    self.hit(f"script:{run['file']}: `{before}` may unpack, patch or check out that file in the same "
                             "command; run the script in a separate command so auto can read it")

    def check_runner(self, real: int, run: dict) -> None:
        g, tokens, assigns, inline = self.g, self.tokens, self.assigns, self.inline
        cws = self.cwds[real]
        if run.get("what") == "loader" or any(a in ("--rcfile", "--init-file") for a in run["args"]):
            self.hit("inline:an option that loads a startup file auto did not read")
            return
        if run.get("self") and self.depth < g.MAX_DEPTH:
            self.operand(run["self"], "exec", cws)
        if run["kind"] not in ("shell", "exec") and run["what"] in ("code", "stdin"):
            _judge_inline(g, run, tokens, assigns, real, self.bodies, self.resolve, self.found, inline, cws, self.kinds,
                          lambda command, _c=cws: self.scan(command, _c), self.session_wrote_it, self.single_quoted)
        if run["kind"] == "shell" and run["what"] == "stdin" and not run["stdin"] and not _has_dash_c(run["args"]) \
                and _piped_in(g, tokens, assigns, run["anchor"]) \
                and not _piped_source_literal(g, tokens, assigns, run["anchor"]):
            self.hit("inline:a script piped into a shell cannot be read")
        operand = run["file"]
        if not operand:
            return
        if g._MARK in operand or (run["kind"] not in ("shell", "exec") and operand.startswith("/dev/")):
            self.hit("inline:the code comes from a process substitution or a device, which auto cannot read")
        elif self.depth < g.MAX_DEPTH and not _keys(inline, operand, cws) & self.written:
            self.operand(operand, run["kind"], cws, optional=run.get("optional", False), soft=run.get("soft", False))

    def operand(self, operand: str, kind: str, cws, optional: bool = False, soft: bool = False) -> None:
        _judge_operand(self.g, operand, kind, cws, self.depth, self.hosts, self.pane_ids, self.found, self.proven,
                       self.ctx, self.inline, lambda command, _c=cws: self.scan(command, _c), optional, soft)

    def run(self) -> None:
        if not self.discover():
            return
        self.loader()
        if self.cwds is None:
            return
        self.check_writes()
        self.written = set(self.kinds) & (self.heredoc_keys | {key for path, _w in self.writes
                                                               for key in _keys(self.inline, path, self.everywhere)})
        self.path_programs()
        self.unpackers()
        for real, run in self.runners.items():
            if self.ctx.expired():
                self.hit("inline:the command names more programs than auto can read in the time allowed")
                break
            self.check_runner(real, run)


def _hit(found: list, cause: str) -> None:
    found.append(("inline", "runtime-built command", "", cause))


def _unwrap_once(g, tokens: list, k: int) -> int:
    name = os.path.basename(tokens[k])
    j = k + 1
    if name in ("timeout", "gtimeout", "flock", "taskset", "chrt"):
        listed = False
        while j < len(tokens) and tokens[j].startswith("-"):
            listed = listed or tokens[j] in ("-c", "--cpu-list")
            j += 2 if tokens[j] in _TIMEOUT_VALUE_OPTS else 1
        j += 0 if (name == "taskset" and listed) else 1
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
    """Index of the program the wrappers starting at `k` run, else `k`. Wrappers may nest; -1 past the bound."""
    for _ in range(_WRAPPER_DEPTH):
        nxt = _unwrap_once(g, tokens, k)
        if nxt == k:
            return k
        k = nxt
    return k if _unwrap_once(g, tokens, k) == k else -1


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


def _runner(g, tokens: list, start: int, prog: str, inline, wrapped: bool = False):
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
        return {"kind": lang, "file": value if what in ("file", "file_maybe") else None, "args": args, "stdin": stdin,
                "what": what, "value": value, "self": None if _system_program(prog) else prog,
                "optional": what == "file_maybe"}
    if "/" in prog and prog.startswith(("./", "../", "/", "~")) and not g._OPERATOR_ONLY.match(prog):
        return {"kind": "exec", "file": prog, "args": [], "stdin": None, "what": "file"}
    kind = _SCRIPT_KINDS.get(os.path.splitext(prog)[1]) if wrapped else None
    if kind:
        return {"kind": kind, "file": prog, "args": [], "stdin": None, "what": "file"}
    return None


def _cwd_track(g, tokens: list, runs: list, base, inline, resolve):
    """The directories each token may run in, as a frozenset (None = unknown); None when a command changes
    directory more often than auto follows.

    A `cd` may fail, sit in a subshell or follow `&&`/`||`, so the directory before it stays possible.
    """
    here, out = frozenset(base), []
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


def track_cwd(g, tokens: list, runs: list, ctx, resolve):
    """_cwd_track for send_guard._scan, which hands each nested scan the directories its token may run in."""
    return _cwd_track(g, tokens, runs, ctx.cwds, g.load_lib_module("send_guard_inline"), resolve)


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


def _keys(inline, operand: str, directories) -> set:
    """Every spelling of an operand: as written, and resolved against each directory it may run in."""
    keys = {os.path.normpath(operand)}
    resolved = {p for p in (inline.resolve_path(operand, d) for d in directories) if p}
    keys |= resolved | {os.path.realpath(p) for p in resolved}
    return keys | {key.casefold() for key in keys}


def _writes(g, tokens: list, runs: list, progs: list) -> list:
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


def judge_runners(g, tokens, positions, bodies, looked_up, resolve, depth, hosts, pane_ids, found, proven, ctx,
                  cwd_at, text) -> None:
    """Refuse when a shell or interpreter would run code the guard cannot show is safe. Any failure here refuses."""
    inline = g.load_lib_module("send_guard_inline")
    try:
        if g.test_hatch_enabled(g._INLINE_FAULT):
            raise RuntimeError("fault injected")
        _Judge(g, tokens, positions, bodies, looked_up, resolve, depth, hosts, pane_ids, found, proven, ctx, inline,
               cwd_at, text).run()
    except Exception as exc:
        _hit(found, f"inline:auto could not finish reading this command ({type(exc).__name__}), so it is refused")


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


def _writes_then_runs(code: str, kinds: dict, inline, fresh):
    """Why inline code that writes a file the same command then runs cannot be read: the file may not exist yet.

    A name built at run time cannot be matched, so it counts only against a script the session wrote (`fresh`): an
    older script is not one this session made, and refusing every such pair cost 2.2% of worker commands."""
    named = {os.path.normpath(s) for s in inline.written_names(code)} & set(kinds)
    if named:
        return (f"the code writes `{sorted(named)[0]}` and the same command then runs it; run it in a separate "
                "command so auto can read the file first")
    if inline.unfoldable_write(code) and any(fresh(name) for name in kinds):
        return ("the code writes a file whose name it builds at run time, and the same command then runs a script "
                "the session wrote; run the script in a separate command so auto can read it first")
    return None


def _command_facts(g, command: str, inline) -> tuple:
    """(a shell or interpreter in the command line reads its program from stdin, the script files it runs)."""
    words = g._lex(command)
    runs, assigns = g._command_positions(words)[:2]
    stdin_fed, files = False, set()
    for k in range(len(words)):
        if not runs[k] or assigns[k]:
            continue
        real = _real_program(g, words, k)
        if real < 0:
            stdin_fed = True
            continue
        run = _runner(g, words, real, words[real], inline, wrapped=real != k)
        if not run:
            continue
        if run["file"]:
            files.add(os.path.normpath(run["file"]))
        stdin_fed = stdin_fed or (not run["file"] and not _has_dash_c(run["args"]) if run["kind"] == "shell"
                                  else run["what"] == "stdin")
    return stdin_fed, files


def _python_why(g, text: str, dirs, kinds: dict, inline, scan, fresh=lambda name: False):
    """Why this Python may not run, else None. The literal command lines its spawn calls start are scanned as typed."""
    why, commands = inline.analyse(text)
    why = why or inline.shadowed(text, dirs) or _writes_then_runs(text, kinds, inline, fresh)
    if why:
        return why
    written = {os.path.normpath(s) for s in inline.written_names(text)}
    unfoldable = inline.unfoldable_write(text)
    for command in commands:
        stdin_fed, files = _command_facts(g, command, inline)
        if stdin_fed:
            return "a command it starts reads its program from stdin, which auto cannot read"
        if files & written or (unfoldable and any(fresh(name) for name in files)):
            return "the code writes a file and then starts a script; run it in a separate command so auto can read the file first"
        scan(command)
    return None


def _judge_inline(g, run, tokens, assigns, start, bodies, resolve, found, inline, cwds, kinds, scan,
                  fresh=lambda name: False, single_quoted=lambda value: False) -> None:
    prog = tokens[start]
    kind, base = run["kind"], os.path.basename(resolve(start, prog) or prog).casefold()
    dirs = [c for c in cwds if c]
    assigned = {m.group(1) for m in (_ASSIGN.match(t) for t in tokens) if m}
    if run["what"] == "code":
        sources = [(run["value"], not single_quoted(run["value"]))]
    elif run["stdin"] and run["stdin"][0] == "here":
        sources = [(run["stdin"][1], not single_quoted(run["stdin"][1]))]
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
            why = _python_why(g, text, dirs, kinds, inline, scan, fresh) if kind == "python" else (
                f"`{kind}` code is not read, and only Python can be shown safe")
            if why:
                return _hit(found, f"inline:{why}")
    return None


def _judge_operand(g, operand, kind, cwds, depth, hosts, pane_ids, found, proven, ctx, inline, scan,
                   optional=False, soft=False) -> None:
    """Read the script a runner names, in each directory it may run in; a script that does not exist yet is refused.

    optional: a name that may be a package command (`bun run dev`) is read only when it is a file.
    soft: the program was only named among another program's arguments, so a file that is not text auto reads is
    ignored instead of refused."""
    paths = [inline.resolve_path(operand, c) for c in (cwds if not os.path.isabs(operand) else {None})]
    if not paths or all(p is None for p in paths):
        return
    existing = [p for p in paths if p and os.path.lexists(p)]
    if not existing:
        if None not in paths and not optional:
            _hit(found, f"script:{operand}: it does not exist yet, so auto cannot read it; create it in an earlier command")
        return
    for path in dict.fromkeys(existing):
        text, why = inline.fresh_text(path, ctx)
        if why and soft and why == "it is not a regular file":
            continue
        if why:
            return _hit(found, f"script:{operand}: {why}")
        if text is None:
            continue
        judged = inline.file_kind(path, text, kind)
        shebang_words = inline.shebang_words(text)
        if len(shebang_words) > 1:
            scan(" ".join(shebang_words))
        interpreter = inline.shebang_interpreter(text)
        if interpreter and not _system_program(interpreter):
            planted, planted_why = inline.fresh_text(interpreter, ctx)
            if planted_why or planted is not None:
                return _hit(found, f"script:{operand}: its shebang names `{interpreter}`, which was written in this session")
        if judged == "python":
            why = _python_why(g, text, [os.path.dirname(path)], {}, inline, scan)
        elif judged == "shell":
            sub = []
            g._scan(text, depth + 1, hosts, pane_ids, sub, proven, shell=True, expands=True, ctx=ctx.child(cwds))
            why = "it holds a command auto cannot show is safe" if sub else None
        elif soft:
            why = None
        else:
            why = f"it is {judged} code, which auto does not read"
        if why:
            return _hit(found, f"script:{operand}: {why}")
