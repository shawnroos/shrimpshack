"""Code the send-guard cannot read as a command: inline interpreter code, and script files a session wrote.

The command-text rules in send_guard.py judge a program name. Here the program is an interpreter or a shell, so
what matters is the code it runs. Inline Python is allowed only when a positive list proves it cannot start a
process, open a socket, write a file, or reach code by string. A script file is read only when the session wrote
or changed it; older files and files identical to the default branch are code the session did not author.
"""
from __future__ import annotations

import ast
import importlib
import os
import re
import shlex
import subprocess
import time
import types

CODE_CAP = 200_000
FILE_CAP = 256 * 1024
NODE_CAP = 20_000
MAX_FILES = 8
GIT_TIMEOUT = 2.0
DEADLINE = 6.0
# Environment names that make an interpreter or shell load code the guard did not read.
LOADER_ENV = re.compile(
    r"^(?:PYTHON(?!(?:UNBUFFERED|IOENCODING|DONTWRITEBYTECODE|HASHSEED|UTF8|FAULTHANDLER|NOUSERSITE)$)\w*|BASH_ENV|ENV|"
    r"ZDOTDIR|HOME|PATH|LD_\w+|DYLD_\w+|SHELLOPTS|BASHOPTS|PS4|PROMPT_COMMAND|NODE_OPTIONS|NODE_PATH|RUBYOPT|RUBYLIB|"
    r"PERL5OPT|PERL5LIB)$")
_COOKIE = re.compile(r"^[ \t\f]*#.*?coding[:=][ \t]*[-\w.]+", re.M)
_PY_NAME = re.compile(r"^(?:python|pythonw|pypy)[\d.]*$")
_OTHER_LANG = {"node": "node", "nodejs": "node", "tsx": "node", "bun": "bun", "deno": "deno", "ruby": "ruby",
               "perl": "perl", "php": "php", "lua": "lua", "swift": "swift", "expect": "expect", "rscript": "rscript",
               "tclsh": "tclsh"}
# Options of each language that take the next word as their value, so that word is not the script.
_VALUE_FLAGS = {"node": {"-r", "--require", "--import", "--loader", "--experimental-loader", "-C", "--conditions"},
                "bun": {"-r", "--preload", "--config", "-c"}, "deno": {"--config", "-c", "--import-map", "--lock"},
                "perl": {"-I", "-M", "-m", "-x", "-C"}, "ruby": {"-I", "-r", "-C", "-x"}, "php": {"-d", "-c", "-z"},
                "lua": {"-l"}, "swift": {"-I", "-L", "-target"}, "expect": {"-c"}, "rscript": {"-e"}, "tclsh": set()}
_CODE_FLAGS = {"node": r"-e|--eval|-p|--print|-pe|-ep", "bun": r"-e|--eval|-p|--print", "deno": r"-e",
               "ruby": r"-[A-Za-z]*e", "perl": r"-[A-Za-z]*[eE]", "lua": r"-e", "php": r"-r", "rscript": r"-e",
               "swift": r"-e", "tclsh": r"NEVER", "expect": r"-c"}
# bun, deno and swift take package commands (`bun install`, `swift build`) as well as scripts.
_SCRIPT_WORD = re.compile(r"[/]|\.(?:[cm]?[jt]sx?|swift)$")
_SUBCOMMANDS = frozenset({"run", "test", "bench", "task", "repl", "check", "compile", "x", "exec"})

# Whole modules. A public attribute is allowed unless its value is itself a module: `shlex.os`, `json.codecs` and
# `glob.os` hand out modules the list does not name.
MODULES = frozenset({
    "json", "re", "collections", "itertools", "math", "datetime", "time", "textwrap", "string", "csv", "hashlib",
    "base64", "urllib.parse", "statistics", "random", "fnmatch", "difflib", "html", "decimal", "fractions",
    "heapq", "bisect", "copy", "pprint", "unicodedata", "binascii", "struct", "calendar", "io", "shlex", "glob",
    "tomllib", "secrets", "sys", "os", "os.path", "pathlib", "tempfile", "shutil", "zlib", "gzip", "bz2", "zipfile",
    "tarfile", "sqlite3", "contextlib", "functools", "ast", "hmac", "subprocess"})
# Process-starting calls. They pass only with a command line written out as literal strings, which the caller
# then judges as a typed command; a computed name, an `env=` or an `executable=` would hide the program.
SPAWN = {"subprocess": frozenset({"run", "call", "check_call", "check_output", "Popen", "getoutput", "getstatusoutput"}),
         "os": frozenset({"system", "popen"})}
_SPAWN_KEYWORDS = frozenset({"stdout", "stderr", "stdin", "text", "capture_output", "check", "timeout",
                             "universal_newlines", "encoding", "errors", "shell"})
NAMESPACES = frozenset({"urllib"})
_EXPLICIT = {
    "sys": frozenset({"argv", "stdin", "stdout", "stderr", "exit", "version_info", "version", "platform", "maxsize",
                      "byteorder", "path"}),
    "os": frozenset({"environ", "getcwd", "getenv", "listdir", "sep", "linesep", "name", "curdir", "pardir",
                     "cpu_count", "getpid", "getppid", "walk", "scandir", "stat", "fspath", "makedirs", "mkdir",
                     "remove", "unlink", "rename", "replace", "rmdir", "chmod", "utime", "symlink", "readlink",
                     "access", "urandom", "get_terminal_size", "devnull", "R_OK", "W_OK", "X_OK", "F_OK",
                     "system", "popen"}),
    "os.path": frozenset({"join", "exists", "isfile", "isdir", "islink", "basename", "dirname", "abspath", "realpath",
                          "expanduser", "expandvars", "splitext", "split", "relpath", "getsize", "getmtime",
                          "getatime", "getctime", "normpath", "commonpath", "commonprefix", "sep", "isabs", "samefile"}),
    "io": frozenset({"StringIO", "BytesIO"}),
    "string": frozenset({"ascii_letters", "ascii_lowercase", "ascii_uppercase", "digits", "hexdigits", "octdigits",
                         "punctuation", "printable", "whitespace", "capwords", "Template"}),
}
_BANNED_NAMES = frozenset({"__import__", "getattr", "setattr", "delattr", "eval", "exec", "compile", "globals",
                           "locals", "vars", "breakpoint", "help", "memoryview"})
# Frames and code objects carry the module globals without a dunder name in sight.
_BANNED_ATTRS = frozenset({"gi_frame", "cr_frame", "ag_frame", "tb_frame", "f_globals", "f_builtins", "f_locals",
                           "f_back", "f_code", "gi_code", "cr_code", "ag_code", "tb_next", "func_globals",
                           "enable_load_extension", "load_extension"})
# os.environ may be read; changing it changes what a later spawn or import loads.
# A compiled program is not code auto can read; anything else is read as text, because a shell runs the lines
# after a NUL byte and Python runs a zip or .pyc whose bytes only look like binary.
_NATIVE_MAGIC = (b"\x7fELF", b"\xfe\xed\xfa\xce", b"\xfe\xed\xfa\xcf", b"\xce\xfa\xed\xfe", b"\xcf\xfa\xed\xfe",
                 b"\xca\xfe\xba\xbe", b"MZ")
_SHELL_SHEBANGS = frozenset({"sh", "bash", "zsh", "dash", "ksh", "ash"})
_MODULE_SUFFIXES = frozenset({"py", "pyc", "pyo", "so", "pyd", "zip", "egg"})
_COPIERS = frozenset({"dict", "sorted", "list", "set", "tuple", "len", "str", "repr", "print", "enumerate", "iter"})
_ENVIRON_READS = frozenset({"get", "copy", "keys", "items", "values"})
_FILE_MODE = frozenset("rwxabt+U")
# A device path is how a script reaches a terminal without a command: `open('/dev/pts/3', 'w')`.
_DEVICE_OK = frozenset({"/dev/null", "/dev/zero", "/dev/urandom", "/dev/random", "/dev/stdin", "/dev/stdout", "/dev/stderr"})
_safe_cache: dict = {}


class Refusal(Exception):
    pass


def _safe_attrs(module: str) -> frozenset:
    if module in _EXPLICIT:
        return _EXPLICIT[module]
    if module not in _safe_cache:
        try:
            mod = importlib.import_module(module)
            names = frozenset(n for n in dir(mod)
                              if not n.startswith("_") and not isinstance(getattr(mod, n, None), types.ModuleType))
        except Exception:
            names = frozenset()
        _safe_cache[module] = names
    return _safe_cache[module]


def _is_module(path: str) -> bool:
    return path in MODULES or path in NAMESPACES


def _bind_imports(nodes: list):
    """({local name: module path}, {local names of spawn functions}) for every import; Refusal for one off the list."""
    bound, spawn_names = {}, set()
    for node in nodes:
        if isinstance(node, ast.Import):
            for alias in node.names:
                if alias.name not in MODULES:
                    raise Refusal(f"`import {alias.name}` is not on the list of modules inline Python may use")
                if alias.asname:
                    bound[alias.asname] = alias.name
                else:
                    top = alias.name.split(".")[0]
                    bound[top] = top
        elif isinstance(node, ast.ImportFrom):
            module = node.module or ""
            if node.level or not _is_module(module):
                raise Refusal(f"`from {'.' * node.level}{module} import …` is not on the list of modules inline Python may use")
            for alias in node.names:
                name = alias.name
                if name == "*":
                    raise Refusal(f"`from {module} import *` hides what is imported")
                if name.startswith("_"):
                    raise Refusal(f"`{module}.{name}` is a private name")
                if module == "os" and name == "environ":
                    raise Refusal("`from os import environ` hides changes to the environment; write `os.environ`")
                if f"{module}.{name}" in MODULES:
                    bound[alias.asname or name] = f"{module}.{name}"
                elif module in NAMESPACES or name not in _safe_attrs(module):
                    raise Refusal(f"`{module}.{name}` is not on the list of names inline Python may use")
                elif name in SPAWN.get(module, ()):
                    spawn_names.add(alias.asname or name)
    return bound, spawn_names


def _module_path(node, bound: dict):
    """The module path an expression names, None for any other value; raises Refusal for a name off the list."""
    if isinstance(node, ast.Name):
        return bound.get(node.id)
    if isinstance(node, ast.Attribute):
        base = _module_path(node.value, bound)
        if base is None:
            return None
        if node.attr.startswith("_"):
            raise Refusal(f"`{base}.{node.attr}` is a private name")
        if f"{base}.{node.attr}" in MODULES:
            return f"{base}.{node.attr}"
        if base in NAMESPACES or node.attr not in _safe_attrs(base):
            raise Refusal(f"`{base}.{node.attr}` is not on the list of names inline Python may use")
    return None


def _open_ok(call: ast.Call) -> bool:
    mode = call.args[1] if len(call.args) > 1 else next((k.value for k in call.keywords if k.arg == "mode"), None)
    if len(call.args) > 3 or any(isinstance(a, ast.Starred) for a in call.args) or any(k.arg is None for k in call.keywords):
        return False
    if mode is None:
        return True
    return isinstance(mode, ast.Constant) and isinstance(mode.value, str) and set(mode.value) <= _FILE_MODE


def _device(text: str) -> bool:
    path = os.path.normpath(text.replace("//", "/"))
    return (path == "/dev" or path.startswith("/dev/")) and path not in _DEVICE_OK


def _environ_read(node, up, parent) -> bool:
    if isinstance(up, ast.Subscript) and up.value is node:
        return isinstance(up.ctx, ast.Load)
    if isinstance(up, ast.Attribute) and up.value is node:
        return up.attr in _ENVIRON_READS and isinstance(parent.get(up), ast.Call)
    if isinstance(up, ast.Call):
        return isinstance(up.func, ast.Name) and up.func.id in _COPIERS
    if isinstance(up, (ast.For, ast.comprehension)):
        return up.iter is node
    return isinstance(up, ast.Compare)


def _literal_command(call: ast.Call):
    """The command line a spawn call runs when every word is a literal string, else None."""
    if len(call.args) > 1 or any(isinstance(a, ast.Starred) for a in call.args):
        return None
    if any(k.arg not in _SPAWN_KEYWORDS and k.arg != "args" for k in call.keywords):
        return None
    arg = call.args[0] if call.args else next((k.value for k in call.keywords if k.arg == "args"), None)
    shell = next((k.value for k in call.keywords if k.arg == "shell"), None)
    shell_on = shell is not None and not (isinstance(shell, ast.Constant) and shell.value is False)
    if isinstance(arg, ast.Constant) and isinstance(arg.value, str):
        return arg.value
    if shell_on:
        return None
    if isinstance(arg, (ast.List, ast.Tuple)) and arg.elts and all(
            isinstance(e, ast.Constant) and isinstance(e.value, str) for e in arg.elts):
        return " ".join(shlex.quote(e.value) for e in arg.elts)
    return None


def _check_tree(tree) -> list:
    """Raises Refusal for code off the list; returns the literal command lines the code's spawn calls run."""
    commands = []
    parent, nodes, stack = {}, [], [tree]
    while stack:
        node = stack.pop()
        nodes.append(node)
        if len(nodes) > NODE_CAP:
            raise Refusal("the code is longer than auto reads")
        for child in ast.iter_child_nodes(node):
            parent[child] = node
            stack.append(child)
    bound, spawn_names = _bind_imports(nodes)
    for node in nodes:
        spawn = None
        if isinstance(node, ast.Attribute):
            base = _module_path(node.value, bound)
            spawn = f"{base}.{node.attr}" if base and node.attr in SPAWN.get(base, ()) else None
        elif isinstance(node, ast.Name) and node.id in spawn_names:
            spawn = node.id
        if spawn:
            up = parent.get(node)
            command = _literal_command(up) if isinstance(up, ast.Call) and up.func is node else None
            if command is None:
                raise Refusal(f"`{spawn}` starts a process, and its command line is not written out as literal strings")
            commands.append(command)
    for node in nodes:
        if isinstance(node, ast.Name):
            if node.id in _BANNED_NAMES or (node.id.startswith("__") and node.id != "__name__"):
                raise Refusal(f"`{node.id}` can load or reach code by name")
            if node.id == "open":
                up = parent.get(node)
                if not (isinstance(up, ast.Call) and up.func is node and _open_ok(up)):
                    raise Refusal("`open` needs a literal mode, such as 'r' or 'w'")
        elif isinstance(node, ast.Attribute):
            if node.attr.startswith("_") or node.attr in _BANNED_ATTRS:
                raise Refusal(f"`.{node.attr}` reaches objects the list does not cover")
            up = parent.get(node)
            if _module_path(node, bound) is not None and not (isinstance(up, ast.Attribute) and up.value is node):
                raise Refusal("a module may only be used by naming an attribute of it")
            if node.attr == "environ" and _module_path(node.value, bound) == "os" and not _environ_read(node, up, parent):
                raise Refusal("`os.environ` may be read but not changed: a changed environment changes what a later "
                              "command or import loads")
        elif isinstance(node, ast.Constant) and isinstance(node.value, (str, bytes)):
            text = node.value if isinstance(node.value, str) else node.value.decode("latin-1")
            if _device(text):
                raise Refusal(f"`{text}` is a device path, and a script can write to a terminal through one")
    for node in nodes:
        if isinstance(node, ast.Name) and node.id in bound:
            up = parent.get(node)
            if not (isinstance(up, ast.Attribute) and up.value is node):
                raise Refusal("a module may only be used by naming an attribute of it")
    return commands


def analyse(code: str):
    """(None, literal command lines the code starts) when the code may run, else (the reason it may not, []).

    Never raises: an exception while reading is a refusal.
    """
    try:
        if len(code) > CODE_CAP:
            return "the code is longer than auto reads (200 KB)", []
        if _COOKIE.search("\n".join(code.splitlines()[:2])):
            return "the code declares a source encoding, which can make Python read different text than auto did", []
        try:
            tree = ast.parse(code)
        except SyntaxError:
            return "auto cannot parse this as Python 3.9", []
        return None, _check_tree(tree)
    except Refusal as exc:
        return str(exc), []
    except Exception as exc:
        return f"auto could not finish reading the code ({type(exc).__name__})", []


_WRITE_ATTRS = frozenset({"write", "write_text", "write_bytes", "touch", "copy", "copy2", "copyfile", "copytree", "move",
                          "rename", "replace", "symlink", "chmod", "mkdir", "makedirs", "dump", "writelines"})


def _fold(node):
    """The string an expression of literals builds ('x' + '.sh', f'a{...}' without fields, Path('d') / 'x'), else None."""
    if isinstance(node, ast.Constant):
        return node.value if isinstance(node.value, str) else None
    if isinstance(node, ast.BinOp) and isinstance(node.op, (ast.Add, ast.Div)):
        left, right = _fold(node.left), _fold(node.right)
        if left is None or right is None:
            return None
        return left + right if isinstance(node.op, ast.Add) else left.rstrip("/") + "/" + right
    if isinstance(node, ast.JoinedStr):
        parts = [_fold(v) for v in node.values]
        return None if any(p is None for p in parts) else "".join(parts)
    if isinstance(node, ast.Call) and node.args and isinstance(node.func, (ast.Name, ast.Attribute)):
        name = node.func.id if isinstance(node.func, ast.Name) else node.func.attr
        parts = [_fold(a) for a in node.args]
        if name in ("Path", "PurePath", "join") and all(p is not None for p in parts):
            return "/".join(p.rstrip("/") if i < len(parts) - 1 else p for i, p in enumerate(parts))
    return None


def written_names(code: str) -> set:
    """The file names code that writes files could be creating: its string constants and the strings its literal
    expressions build. Empty when the code only reads. A name built from variables is a named residual."""
    try:
        nodes = list(ast.walk(ast.parse(code)))
    except Exception:
        return set()
    writes = any(isinstance(n, ast.Attribute) and n.attr in _WRITE_ATTRS for n in nodes) or any(
        isinstance(n, ast.Call) and isinstance(n.func, ast.Name) and n.func.id == "open"
        and any(isinstance(a, ast.Constant) and isinstance(a.value, str) and set(a.value) & set("wax+")
                for a in list(n.args[1:2]) + [k.value for k in n.keywords if k.arg == "mode"])
        for n in nodes)
    if not writes:
        return set()
    return {name for name in (_fold(n) for n in nodes) if name}


def _is_package(path: str) -> bool:
    """A directory with an __init__ file; a bare data directory of the same name loses to the standard module."""
    return os.path.isdir(path) and any(n.startswith("__init__.") for n in os.listdir(path))


def shadowed(code: str, directories):
    """Why a standard module the code imports would be replaced by a file in a directory Python searches first.

    The directories are the working directory (or the script's) plus any existing absolute directory the code names,
    which is how `sys.path.insert(0, '/x')` is spelled. A path built at run time is a named residual.
    """
    try:
        tree = ast.parse(code)
    except Exception:
        return None
    nodes = list(ast.walk(tree))
    modules = {a.name.split(".")[0] for n in nodes if isinstance(n, ast.Import) for a in n.names}
    modules |= {n.module.split(".")[0] for n in nodes if isinstance(n, ast.ImportFrom) and n.module}
    for name in written_names(code):
        if os.path.basename(name).split(".")[0] in modules and name.rsplit(".", 1)[-1] in _MODULE_SUFFIXES:
            return (f"the code writes `{name}` and imports a module of that name, so it would run the file it just "
                    "wrote")
    folders = [d for d in directories if d]
    base = folders[0] if folders else None
    for n in nodes:
        if isinstance(n, ast.Constant) and isinstance(n.value, str) and n.value and not n.value.startswith("-"):
            candidate = n.value if os.path.isabs(n.value) else (os.path.join(base, n.value) if base else None)
            if candidate and os.path.isdir(candidate):
                folders.append(candidate)
    for folder in folders:
        try:
            names = os.listdir(folder)
        except OSError:
            continue
        for module in modules:
            hit = next((n for n in names if n == module and _is_package(os.path.join(folder, n))
                        or n.startswith(module + ".") and n.rsplit(".", 1)[-1] in _MODULE_SUFFIXES), None)
            if hit:
                return f"`{os.path.join(folder, hit)}` would be imported instead of the standard module `{module}`"
    return None


def interpreter_kind(base: str):
    """'python', a language name, or None."""
    name = os.path.basename(base).casefold()
    if _PY_NAME.match(name):
        return "python"
    return _OTHER_LANG.get(name)


def plan(kind: str, rest: list) -> tuple:
    """What an interpreter will run, from the words after its name up to the next shell break.

    ("code", text) inline code operand; ("stdin", None) code from stdin; ("file", operand); ("module", name);
    ("loader", flag) an option that loads code the guard did not read; ("none", None) nothing to run.
    """
    i = 0
    while i < len(rest):
        tok = rest[i]
        if kind == "python":
            if tok in ("-W", "-X", "--check-hash-based-pycs"):
                i += 2
                continue
            if tok.startswith(("-W", "-X")):
                i += 1
                continue
            if re.fullmatch(r"-[A-Za-z]*i[A-Za-z]*", tok):
                return "loader", tok
            if re.fullmatch(r"-[A-Za-z]*c", tok):
                return ("code", rest[i + 1]) if i + 1 < len(rest) else ("none", None)
            if tok.startswith("-c") and len(tok) > 2:
                return "code", tok[2:]
            if re.fullmatch(r"-[A-Za-z]*m", tok):
                return "module", rest[i + 1] if i + 1 < len(rest) else ""
            if tok in ("-V", "--version", "-h", "--help"):
                return "none", None
            if tok == "-":
                return "stdin", None
            if tok.startswith("-"):
                i += 1
                continue
            return "file", tok
        code_flag = _CODE_FLAGS.get(kind)
        if tok in ("--version", "-v", "-V", "--help", "-h"):
            return "none", None
        if code_flag and (re.fullmatch(code_flag, tok) or tok.startswith("--eval=")):
            return ("code", rest[i + 1] if i + 1 < len(rest) else "")
        if tok == "-":
            return "stdin", None
        if tok in _VALUE_FLAGS.get(kind, ()):
            i += 2
            continue
        if tok.startswith("-"):
            i += 1
            continue
        if tok == "eval" and kind == "deno":
            return ("code", rest[i + 1] if i + 1 < len(rest) else "")
        if tok in _SUBCOMMANDS and kind in ("deno", "bun"):
            i += 1
            continue
        if kind in ("bun", "deno", "swift") and not _SCRIPT_WORD.search(tok):
            return "file_maybe", tok
        return "file", tok
    return "stdin", None


class Context:
    """What one guard call knows about where it runs; one per command."""

    def __init__(self, cwd=None, session_start=None):
        self.cwd = cwd
        self.session_start = session_start if session_start is not None else time.time() - 6 * 3600
        self.deadline = time.monotonic() + DEADLINE
        self.files = 0

    def expired(self) -> bool:
        return time.monotonic() > self.deadline

    def remaining(self) -> float:
        return self.deadline - time.monotonic()


def _git(args: list, cwd: str):
    try:
        done = subprocess.run(["git", "-c", "core.fsmonitor=false", "-C", cwd] + args, capture_output=True, text=True,
                              timeout=GIT_TIMEOUT, stdin=subprocess.DEVNULL,
                              env={"PATH": os.environ.get("PATH", ""), "HOME": os.environ.get("HOME", ""),
                                   "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0"})
    except Exception:
        return None
    return done.stdout.strip() if done.returncode == 0 else None


def same_as_default_branch(path: str, ctx: Context) -> bool:
    """A tracked file whose bytes equal the default branch's: code the session did not author.

    Each git call is bounded and the whole lookup stops when the command's time is spent, so a worker cannot use
    many script words to push the hook past its own time limit.
    """
    folder = os.path.dirname(path) or "."
    top = _git(["rev-parse", "--show-toplevel"], folder)
    if not top or ctx.expired():
        return False
    rel = os.path.relpath(os.path.realpath(path), os.path.realpath(top))
    if _git(["ls-files", "--error-unmatch", "--", rel], top) is None or ctx.expired():
        return False
    ours = _git(["hash-object", "--no-filters", "--", rel], top)
    for ref in ("origin/main", "origin/master", "main", "master"):
        if ctx.expired():
            return False
        theirs = _git(["rev-parse", "--verify", "-q", f"{ref}:{rel}"], top)
        if theirs:
            return ours is not None and ours == theirs
    return False


def resolve_path(operand: str, cwd):
    """Absolute path for a literal operand, None when it cannot be resolved without running the shell."""
    if operand.startswith("~/"):
        operand = os.path.expanduser(operand)
    if re.search(r"[$`*?\[\]{}~\ue000]", operand):
        return None
    if os.path.isabs(operand):
        return os.path.normpath(operand)
    return os.path.normpath(os.path.join(cwd, operand)) if cwd else None


def fresh_text(path: str, ctx: Context):
    """(text, None) for a file this session wrote that must be judged, (None, None) for one that needs no reading,
    (None, reason) for one that cannot be read."""
    try:
        lst = os.lstat(path)
    except OSError:
        return None, None
    try:
        st = os.stat(path)
    except OSError:
        return None, "it is a link to a file that does not exist yet"
    newest = max(lst.st_mtime, lst.st_ctime, st.st_mtime, st.st_ctime)
    if newest < ctx.session_start:
        return None, None
    if not os.path.isfile(path):
        return None, "it is not a regular file"
    if ctx.files >= MAX_FILES or ctx.expired():
        return None, "the command names more script files than auto reads in the time allowed"
    ctx.files += 1
    if same_as_default_branch(path, ctx):
        return None, None
    if st.st_size > FILE_CAP:
        return None, "it is larger than auto reads (256 KB)"
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        try:
            data = os.read(fd, FILE_CAP + 1)
        finally:
            os.close(fd)
    except OSError:
        return None, "auto could not read it"
    if data.startswith(_NATIVE_MAGIC):
        return None, None
    return data.decode("utf-8", "replace"), None


def shebang_words(text: str) -> list:
    """The words on a `#!` line, else []."""
    first = text.split("\n", 1)[0]
    return first[2:].split() if first.startswith("#!") else []


def shebang_interpreter(text: str):
    """The program path on a `#!` line, else None."""
    words = shebang_words(text)
    return words[0] if words else None


def file_kind(path: str, text: str, runner: str) -> str:
    """How to judge a file: 'python', 'shell' or a language name, from the runner and then the shebang."""
    if runner in ("python", "shell") or runner in _OTHER_LANG.values():
        return runner
    first = text.split("\n", 1)[0]
    if first.startswith("#!"):
        words = first[2:].split()
        names = [os.path.basename(w) for w in words]
        if "env" in names[:1] and len(names) > 1:
            names = names[1:]
        kind = interpreter_kind(names[0]) if names else None
        if kind:
            return kind
        return "shell" if names and names[0] in _SHELL_SHEBANGS else (names[0] if names else "shell")
    if runner != "exec" and path.endswith(".py"):
        return "python"
    return "shell"
