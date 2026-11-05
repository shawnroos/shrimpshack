#!/usr/bin/env python3
"""Refuse a limited session's write to the programme's files, the installed plugin and the two hook switches.

A session with no limit on is never refused here. Best effort: a file tool is matched by real path and
Bash by text. A command that names a protected place passes only when all it does is read, or run the
plugin's own scripts with a verb other than `set-check`, so a path built at run time or a script written
elsewhere still gets through.
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
# programme.sh knows its caller only by this variable, so a session that sets it can act as the PM.
SESSION_ENV = "CLAUDE_CODE_SESSION_ID"
LIFT_VERB = "set-check"
HOOK_KEYS = ("disableAllHooks", "allowManagedHooksOnly")
# The shim's __cd_protected must list the same words; tests/integration/check-settings.test.sh compares them.
NAMED_WORDS = ("programmes", "plugins", DATA_ENV, ROOT_ENV, SESSION_ENV, LIFT_VERB, *HOOK_KEYS)
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
    "cat", "head", "tail", "more", "grep", "egrep", "fgrep", "rg", "ls", "stat", "wc", "file", "du",
    "jq", "diff", "cmp", "cut", "tr", "sort", "sed", "find", "realpath", "readlink", "basename",
    "dirname", "shasum", "sha256sum", "md5", "md5sum", "echo", "printf", "test", "[", "true", "cd", "pwd",
))
_READER_WRITES = {
    "sed": ("--in-place", "--file"),
    "sort": ("--output", "--compress-program"),
    "find": ("-delete", "-exec", "-ok", "-fprint", "-fls"),
    "rg": ("--pre",),
}
# A short-flag cluster holding one of these letters writes or hides the script: `sort -uo`, `sed -Ei`, `sed -f`.
_SHORT_WRITES = {"sed": "iIf", "sort": "o"}
# What a sed script holds besides its commands: s and y bodies, and /regex/ addresses. An s that ends a label
# (`ts;w x;s;`) is not a command, so a letter before it keeps the body in view.
_SED_BODIES = re.compile(r"(?<![A-Za-z])[sy]([^\s\\])(?:\\.|(?!\1).)*\1(?:\\.|(?!\1).)*\1|/(?:\\.|[^/\\])*/", re.DOTALL)
# w and W write a file, e runs a command. A letter in a label or appended text counts too: refusing a read is safe.
_SED_ACTS = re.compile(r"[wWe]")

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
    plain = settings_guard._HIDING_CHARS.sub("", word)
    return _protected_path(word, bases, dirs) or next((env for env in (DATA_ENV, SESSION_ENV) if env in plain), None)


def _substitutes(word) -> bool:
    return "$(" in word or "`" in word


def _sed_scripts(args) -> list:
    """The script words of a sed call: each -e argument, or else the first word that is not a flag."""
    scripts, loose, args = [], [], iter(args)
    for word in args:
        if word.startswith("--expression"):
            scripts.append(word.partition("=")[2] if "=" in word else next(args, ""))
        elif word.startswith("-") and not word.startswith("--") and "e" in word:
            scripts.append(word[word.index("e") + 1:] or next(args, ""))
        elif not word.startswith("-"):
            loose.append(word)
    return scripts or loose[:1]


def _only_reads(segment) -> bool:
    if not segment.words:
        return True
    program, args = os.path.basename(segment.words[0]), segment.words[1:]
    if program not in _READERS or any(map(_substitutes, segment.words)):
        return False
    if any(word.startswith(w) for word in args for w in _READER_WRITES.get(program, ())):
        return False
    short = _SHORT_WRITES.get(program, "")
    if any(word[:1] == "-" and word[1:2] != "-" and set(word[1:]) & set(short) for word in args):
        return False
    return program != "sed" or not any(_SED_ACTS.search(_SED_BODIES.sub("", s)) for s in _sed_scripts(args))


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


def _bases(segments, cwd) -> list:
    return [cwd] + [settings_guard._resolved(s.words[1], cwd) for s in segments
                    if len(s.words) > 1 and s.words[0] == "cd"]


def _bash_target(command, cwd, dirs):
    text = behaviour_guard._examined(command)
    text = _ENV_REFS.sub(lambda m: _PLUGIN_ROOT if ROOT_ENV in m.group(0) else programme_home.data_dir(), text)
    try:
        segments, readable = _segments(text), True
    except ValueError:
        # An open quote hides where words end, so nothing can be called a read.
        segments, readable = [Segment(text.split(), [])], False
    if any(LIFT_VERB in s.words and not _only_reads(s) for s in segments):
        return f"a check setting with `{LIFT_VERB}`"
    bases = _bases(segments, cwd)
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


def _settings_file(path: str) -> bool:
    parent = os.path.dirname(path)
    config = os.environ.get("CLAUDE_CONFIG_DIR")
    return _is_settings_name(path) and (os.path.basename(parent).casefold() == ".claude" or bool(config) and (
        parent.casefold() == settings_guard._resolved(config, "/").casefold()))


def _settings_hit(raw, base):
    path = settings_guard._resolved(raw, base)
    # As written too: a symlinked .claude folder resolves to a path without its name.
    written = os.path.normpath(os.path.join(base, settings_guard._expanded(raw)))
    return path if _settings_file(path) or _settings_file(written) else None


def settings_target(tool_name, tool_input, cwd):
    """The settings file a call would write, for `no-settings-writes`. A Bash call that only reads names none."""
    if tool_name != "Bash":
        raw = tool_input.get("file_path")
        return _settings_hit(raw, cwd) if isinstance(raw, str) and raw else None
    command = tool_input.get("command")
    if not isinstance(command, str):
        return None
    text = behaviour_guard._examined(command)
    try:
        segments, readable = _segments(text), True
    except ValueError:
        segments, readable = [Segment(settings_guard._HIDING_CHARS.sub("", text).split(), [])], False
    bases = _bases(segments, cwd)

    def hit(word):
        return next(filter(None, (_settings_hit(f, b) for f in _fragments(word) if _is_settings_name(f)
                                  for b in bases)), None)

    found = next(filter(None, map(hit, (t for s in segments for t in s.targets))), None)
    if found:
        return found
    found = next(filter(None, map(hit, (w for s in segments for w in s.words))), None)
    return None if found is None or (readable and all(map(_only_reads, segments))) else found


def only_reads(command, names_target) -> bool:
    """True when each part of a Bash command only reads and no redirect writes a word that names_target accepts."""
    try:
        segments = _segments(behaviour_guard._examined(command))
    except ValueError:
        return False
    return all(map(_only_reads, segments)) and not any(names_target(t) for s in segments for t in s.targets)


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
    return any(word.casefold() in text for word in (*NAMED_WORDS, _PLUGIN_ROOT))


def _refused_write(names, target) -> str:
    others = f". These limits are all on, and each must be lifted: {', '.join(names)}" if len(names) > 1 else ""
    return (f"would write {target}. While a limit is on, this session cannot write the programme's files or the "
            "installed plugin, set `CLAUDE_AUTO_DATA_DIR` or `CLAUDE_CODE_SESSION_ID`, run `set-check`, or write "
            "`disableAllHooks` or `allowManagedHooksOnly` to a settings file, and a command that names one of them "
            f"must only read it{others}")


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
