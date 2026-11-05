#!/usr/bin/env python3
"""Refuse a limited session's write to the programme's files, the installed plugin and the two hook switches.

A session with no limit on is never refused here. Best effort: a file tool is matched by real path and
Bash by text. A command that names a protected place passes only when all it does is read, or run the
plugin's own scripts, so a path built at run time or a script written elsewhere still gets through.
"""

from __future__ import annotations

import collections
import functools
import json
import os
import re
import shlex
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

programme_home = load_lib_module("programme_home")
settings_guard = load_lib_module("programme_settings_guard")
behaviour_guard = load_lib_module("programme_behaviour_guard")

DATA_ENV = "CLAUDE_AUTO_DATA_DIR"
ROOT_ENV = "CLAUDE_PLUGIN_ROOT"
HOOK_KEYS = ("disableAllHooks", "allowManagedHooksOnly")
SETTINGS_NAMES = ("settings.json", "settings.local.json")
_PLUGIN_ROOT = os.path.dirname(_LIB_DIR)
_FILE_TOOLS = ("Write", "Edit", "MultiEdit")
_ENV_NAMES = f"{DATA_ENV}|{ROOT_ENV}"
_ENV_REFS = re.compile(rf"\$(?:\{{({_ENV_NAMES})[^}}]*\}}|({_ENV_NAMES})\b)")
_FRAGMENT = re.compile(r"[\s=:,'\"(){}\[\]]+")
_ASSIGNMENT = re.compile(r"^[A-Za-z_]\w*=")
_PUNCTUATION = ";&|<>()\n"
_INTERPRETERS = ("bash", "sh", "zsh", "python", "python3")
# Default-deny: anything not listed counts as a write once the command names a protected place.
_READERS = frozenset((
    "cat", "head", "tail", "less", "more", "grep", "egrep", "fgrep", "rg", "ls", "stat", "wc", "file", "du",
    "jq", "diff", "cmp", "cut", "tr", "sort", "sed", "find", "tree", "realpath", "readlink", "basename",
    "dirname", "shasum", "sha256sum", "md5", "md5sum", "echo", "printf", "test", "[", "true", "cd", "pwd",
))
_READER_WRITES = {
    "sed": ("-i", "--in-place"),
    "sort": ("-o", "--output"),
    "find": ("-delete", "-exec", "-ok", "-fprint", "-fls"),
}

Segment = collections.namedtuple("Segment", "words targets")


@functools.lru_cache(maxsize=None)
def _real_plugin_dirs(configs) -> frozenset:
    dirs = {os.path.join(c, "plugins", "cache") for c in configs if c}
    return frozenset(os.path.realpath(d).casefold() for d in dirs | {_PLUGIN_ROOT})


def _plugin_dirs() -> frozenset:
    return _real_plugin_dirs((os.path.expanduser("~/.claude"), os.environ.get("CLAUDE_CONFIG_DIR")))


def _under(path: str, dirs) -> bool:
    folded = path.casefold()
    return any(folded == d or folded.startswith(d + os.sep) for d in dirs)


def _protected() -> frozenset:
    return _plugin_dirs() | {os.path.realpath(programme_home.programmes_dir()).casefold()}


def _is_settings_name(path: str) -> bool:
    return os.path.basename(path).casefold() in SETTINGS_NAMES


def _segments(command: str) -> list:
    """Split at shell separators, keeping redirect targets apart from words. Raises ValueError on an open quote."""
    lexer = shlex.shlex(command, posix=True, punctuation_chars=_PUNCTUATION)
    lexer.whitespace = " \t\r"
    lexer.whitespace_split = True
    lexer.commenters = ""
    found = [Segment([], [])]
    target_next = False
    for token in lexer:
        if token and set(token) <= set(_PUNCTUATION):
            if "(" in token or ")" in token or not set(token) & set("<>"):
                found.append(Segment([], []))
            target_next = target_next or (">" in token and "(" not in token)
            continue
        (found[-1].targets if target_next else found[-1].words).append(token)
        target_next = False
    return [s for s in found if s.words or s.targets]


def _fragments(word):
    return filter(None, _FRAGMENT.split(word))


def _protected_path(word, bases, dirs):
    for fragment in _fragments(word):
        for base in bases:
            path = settings_guard._resolved(fragment, base)
            if _under(path, dirs):
                return path
    return None


def _named(word, bases, dirs):
    return _protected_path(word, bases, dirs) or (DATA_ENV if DATA_ENV in word else None)


def _substitutes(word) -> bool:
    return "$(" in word or "`" in word


def _only_reads(segment) -> bool:
    if not segment.words:
        return True
    program = os.path.basename(segment.words[0])
    if program not in _READERS or any(map(_substitutes, segment.words)):
        return False
    writes = _READER_WRITES.get(program, ())
    return not any(word.startswith(w) for word in segment.words[1:] for w in writes)


def _runs_plugin_script(segment, bases, dirs) -> bool:
    """`bash <plugin>/lib/programme.sh ...`, directly or saved in a variable, is how a worker reaches its verbs."""
    words = segment.words
    saved = len(words) == 1 and _ASSIGNMENT.match(words[0])
    if saved:
        words = words[0].split("=", 1)[1].split()
    at = 1 if words and os.path.basename(words[0]) in _INTERPRETERS else 0
    if len(words) <= at or (saved and not at) or any(map(_substitutes, words)):
        return False
    if not _protected_path(words[at], bases[:1], _plugin_dirs()):
        return False
    return not any(_named(word, bases, dirs) for word in [*words[at + 1:], *segment.targets])


def _settings_word(words):
    for word in words:
        for fragment in _fragments(word):
            if _is_settings_name(fragment):
                return fragment
    return None


def _bash_target(command, cwd, dirs):
    text = behaviour_guard._examined(command)
    text = _ENV_REFS.sub(lambda m: _PLUGIN_ROOT if ROOT_ENV in m.group(0) else programme_home.data_dir(), text)
    try:
        segments, readable = _segments(text), True
    except ValueError:
        # An open quote hides where words end, so nothing can be called a read.
        segments, readable = [Segment(text.split(), [])], False
    bases = [cwd] + [settings_guard._resolved(s.words[1], cwd) for s in segments
                     if len(s.words) > 1 and s.words[0] == "cd"]
    kept = [s for s in segments if not _runs_plugin_script(s, bases, dirs)]
    for segment in kept:
        for word in segment.targets:
            hit = _named(word, bases, dirs)
            if hit:
                return hit
    sets_key = any(key in settings_guard._HIDING_CHARS.sub("", text) for key in HOOK_KEYS)
    if sets_key:
        hit = _settings_word(t for s in segments for t in s.targets)
        if hit:
            return hit
    found = next(filter(None, (_named(w, bases, dirs) for s in kept for w in s.words)), None)
    if found is None and sets_key:
        found = _settings_word(w for s in segments for w in s.words)
    if found is None or (readable and all(map(_only_reads, kept))):
        return None
    return found


def _new_text(tool_name, tool_input) -> str:
    if tool_name == "Write":
        return str(tool_input.get("content") or "")
    if tool_name == "Edit":
        return str(tool_input.get("new_string") or "")
    edits = tool_input.get("edits")
    return " ".join(str(e.get("new_string") or "") for e in edits if isinstance(e, dict)) if isinstance(edits, list) else ""


def _file_target(tool_name, tool_input, cwd, dirs):
    raw = tool_input.get("file_path")
    if not isinstance(raw, str) or not raw:
        return None
    path = settings_guard._resolved(raw, cwd)
    if _under(path, dirs):
        return path
    # As written too: a symlinked settings file resolves to a path without the settings name.
    if _is_settings_name(raw) or _is_settings_name(path):
        new = _new_text(tool_name, tool_input)
        return path if any(key in new for key in HOOK_KEYS) else None
    return None


def _may_name_target(tool_input) -> bool:
    text = settings_guard._HIDING_CHARS.sub("", json.dumps(tool_input)).casefold()
    words = ("programmes", "plugins", DATA_ENV.casefold(), ROOT_ENV.casefold(), _PLUGIN_ROOT.casefold(),
             *(key.casefold() for key in HOOK_KEYS))
    return any(word in text for word in words)


def _refused_write(names, target) -> str:
    others = f". These limits are all on, and each must be lifted: {', '.join(names)}" if len(names) > 1 else ""
    return (f"would write {target}. While a limit is on, this session cannot write the programme's files or the "
            "installed plugin, set `CLAUDE_AUTO_DATA_DIR`, or write `disableAllHooks` or `allowManagedHooksOnly` to a "
            f"settings file, and a command that names one of them must only read it{others}")


def decision(stdin_raw: str):
    """(deny, journal_row) or None. The caller emits the deny before it journals the row."""
    data = json.loads(stdin_raw) if stdin_raw else None
    if not isinstance(data, dict) or data.get("tool_name") not in ("Bash", *_FILE_TOOLS):
        return None
    tool_name = data["tool_name"]
    tool_input = data.get("tool_input") if isinstance(data.get("tool_input"), dict) else {}
    if not _may_name_target(tool_input):
        return None
    cwd = data.get("cwd")
    cwd = cwd if isinstance(cwd, str) and os.path.isabs(cwd) else os.getcwd()
    dirs = _protected()
    if tool_name == "Bash":
        command = tool_input.get("command")
        target = _bash_target(command, cwd, dirs) if isinstance(command, str) else None
    else:
        target = _file_target(tool_name, tool_input, cwd, dirs)
    if target is None:
        return None
    # Read only after a hit: this walks every held lease, and most calls name nothing protected.
    checks_module = load_lib_module("programme_checks")
    session_id = data.get("session_id") if isinstance(data.get("session_id"), str) else None
    states = checks_module.hook_checks(session_id)["states"]
    names = [name for name in checks_module.limit_names() if states.get(name)]
    if not names:
        return None
    return checks_module.limit_refusal(names[0], session_id, tool_name, _refused_write(names, target), limits=names,
                                       **settings_guard.written(tool_name, tool_input, target))
