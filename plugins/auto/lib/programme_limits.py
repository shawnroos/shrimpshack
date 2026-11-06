#!/usr/bin/env python3
"""Refuse each write a limit covers: the programme's files, the installed plugin and the two hook switches
under any limit, and every settings or behaviours file under `no-settings-writes`.

A session with no limit on is never refused here. A limit stops an honest worker's mistakes; it is no
boundary against a session set on getting round it. A file tool is matched by real path and Bash by text.
Under a limit a command that names a protected place passes only when every part of it is a plain read, or
a run of the plugin's scripts (for `programme.sh`, one of RUN_VERBS with every argument written out). Any
command naming `CLAUDE_CODE_SESSION_ID` is refused. A name, path or verb built at run time, a glob, or a script written
first and run later gets through.
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
guard_text = load_lib_module("programme_guard_text")
settings_guard = load_lib_module("programme_settings_guard")
behaviour_guard = load_lib_module("programme_behaviour_guard")

DATA_ENV = "CLAUDE_AUTO_DATA_DIR"
ROOT_ENV = "CLAUDE_PLUGIN_ROOT"
# programme.sh knows its caller only by CLAUDE_CODE_SESSION_ID, so a session that sets it can act as the PM.
SESSION_ENV = "CLAUDE_CODE_SESSION_ID"
SESSION_WORD = "SESSION_ID"
LIFT_VERB = "set-check"
WRITES_LIMIT = "no-settings-writes"
HOOK_KEYS = ("disableAllHooks", "allowManagedHooksOnly")
# The shim's __cd_protected must list the same words; tests/integration/check-settings.test.sh compares them.
NAMED_WORDS = ("programmes", "plugins", DATA_ENV, ROOT_ENV, SESSION_WORD, LIFT_VERB, *HOOK_KEYS)
SETTINGS_NAMES = ("settings.json", "settings.local.json")
PROGRAMME_SCRIPTS = ("programme.sh", "programme.py")
# The programme verbs a limited session may run: those whose `reads` is set in programme._VERBS, plus the two
# a worker reports through. tests/integration/programme-limits.test.sh checks each against the verb table.
READ_VERBS = ("status", "rules", "describe", "context", "inbox", "contract-status", "open-worker-questions")
REPORT_VERBS = ("claim", "register-run")
RUN_VERBS = READ_VERBS + REPORT_VERBS
# `rules --ack` writes the acknowledgement.
_VERB_WRITES = {"rules": ("--ack",)}
_PLUGIN_ROOT = os.path.dirname(_LIB_DIR)
_FILE_TOOLS = ("Write", "Edit", "MultiEdit")
_ENV_NAMES = f"{DATA_ENV}|{ROOT_ENV}"
_ENV_REFS = re.compile(rf"\$(?:\{{({_ENV_NAMES})[^}}]*\}}|({_ENV_NAMES})\b)")
_FRAGMENT = re.compile(r"[\s=:,'\"(){}\[\]]+")
_ASSIGNMENT = re.compile(r"^[A-Za-z_]\w*=")
_VARIABLE = re.compile(r"^\$\{?([A-Za-z_]\w*)\}?$")
_SUBSTITUTION = re.compile(r"\$\(|`|[<>]\(")
# Quotes, backslashes, expansion marks and spaces go, so `CLAUDE_CODE_SESS"$(:)"ION_ID` still reads as the name.
_JOINERS = re.compile(r"[\"'\\$(){}`\s]")
_PUNCTUATION = ";&|<>()\n"
_INTERPRETERS = ("bash", "sh", "zsh", "python", "python3")
# Default-deny: anything not listed counts as a write once the command names a protected place. Each listed
# program has no option that writes a file or runs a command, except the ones _READER_WRITES names.
_READERS = frozenset((
    "cat", "head", "tail", "grep", "egrep", "fgrep", "wc", "ls", "stat", "diff", "cmp", "jq", "cut", "tr",
    "find", "realpath", "readlink", "basename", "dirname", "echo", "printf", "test", "[", "true", "cd", "pwd",
))
_READER_WRITES = {"find": ("-delete", "-exec", "-ok", "-fprint", "-fls"), "printf": ("-v",)}
_TOO_LONG = "what a command too long to examine in full names; to write a long file, use the Write tool"

Segment = collections.namedtuple("Segment", "words targets")
Parsed = collections.namedtuple("Parsed", "text segments readable")


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


def _joined(text: str) -> str:
    return _JOINERS.sub("", text).casefold()


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


def _too_long(command) -> bool:
    return isinstance(command, str) and len(command) > guard_text.MAX_COMMAND


def _parsed(command: str, rewrite=None) -> Parsed:
    """The command's segments, and whether it can be called a read at all.

    A command too long to examine in full, one that substitutes a command, and one with an open quote never is:
    the part out of view, the substituted command or the hidden word ends could write.
    """
    text = guard_text.examined(command)
    text = rewrite(text) if rewrite else text
    readable = len(command) <= guard_text.MAX_COMMAND and not _SUBSTITUTION.search(text)
    try:
        return Parsed(text, _segments(text), readable)
    except ValueError:
        return Parsed(text, [Segment(guard_text.HIDING_CHARS.sub("", text).split(), [])], False)


def _fragments(word):
    return filter(None, _FRAGMENT.split(word))


def _protected_path(word, bases, dirs):
    for fragment in _fragments(word):
        for base in bases:
            path = guard_text.resolved(fragment, base)
            if _under(path, dirs):
                return path
    return None


def _named(word, bases, dirs):
    plain = guard_text.HIDING_CHARS.sub("", word)
    return _protected_path(word, bases, dirs) or (DATA_ENV if DATA_ENV in plain else None)


def _expands(word) -> bool:
    return "$" in word or "`" in word


def _only_reads(segment) -> bool:
    if not segment.words:
        return True
    program, args = os.path.basename(segment.words[0]), segment.words[1:]
    if program not in _READERS:
        return False
    return not any(word.startswith(w) for word in args for w in _READER_WRITES.get(program, ()))


def _saved_scripts(segments, bases) -> dict:
    """`P="bash <plugin>/lib/programme.sh"`: the variables holding a run of a plugin script, by name."""
    saved = {}
    for segment in segments:
        if len(segment.words) == 1 and _ASSIGNMENT.match(segment.words[0]):
            name, _, value = segment.words[0].partition("=")
            words = value.split()
            if len(words) > 1 and os.path.basename(words[0]) in _INTERPRETERS \
                    and _protected_path(words[1], bases, _plugin_dirs()):
                saved[name] = words
    return saved


def _script_run(words, saved, bases):
    """(script, verb words) when the words run a plugin script, directly, through an interpreter or `$P`."""
    if not words or _ASSIGNMENT.match(words[0]):
        return None
    found = _VARIABLE.match(words[0])
    if found and found.group(1) in saved:
        words = saved[found.group(1)] + words[1:]
    at = 1 if os.path.basename(words[0]) in _INTERPRETERS else 0
    if len(words) <= at or _expands(words[at]):
        return None
    if not _protected_path(words[at], bases, _plugin_dirs()):
        return None
    return words[at], words[at + 1:]


def _refused_run(script, args):
    """Why this run of a plugin script is refused under a limit; None when it may run."""
    name, verb = os.path.basename(script), args[0] if args else ""
    if name not in PROGRAMME_SCRIPTS:
        return None
    if _expands(verb):
        return f"a run of `{name}` whose verb is built at run time"
    if verb not in RUN_VERBS or any(word.startswith(w) for word in args for w in _VERB_WRITES.get(verb, ())):
        return f"a run of `{name} {verb}`".rstrip()
    if any(map(_expands, args)):
        return (f"a run of `{name} {verb}` with an argument built at run time; write each argument out "
                "literally, with no `$` or backtick")
    return None


def _settings_word(words):
    for word in words:
        for fragment in _fragments(word):
            if _is_settings_name(fragment):
                return fragment
    return None


def _bases(segments, cwd) -> list:
    return [cwd] + [guard_text.resolved(s.words[1], cwd) for s in segments
                    if len(s.words) > 1 and s.words[0] == "cd"]


def _env_refs(text):
    return _ENV_REFS.sub(lambda m: _PLUGIN_ROOT if ROOT_ENV in m.group(0) else programme_home.data_dir(), text)


def _bash_target(command, cwd, dirs):
    if SESSION_ENV in _JOINERS.sub("", command):
        return f"`{SESSION_ENV}`, the variable `programme.sh` knows its caller by"
    if _too_long(command):
        # Spaces kept, so prose such as "the plugin system" does not join into a trigger word.
        plain = guard_text.HIDING_CHARS.sub("", command).casefold()
        # Path tails too: `~/.claude/plugins/cache` never spells a resolved path. A long doc naming them is refused
        # as well; the refusal points it to the Write tool.
        names = (DATA_ENV, ROOT_ENV, SESSION_ENV, LIFT_VERB, *HOOK_KEYS, _PLUGIN_ROOT, *_protected(),
                 "plugins/cache", "/programmes", os.path.basename(programme_home.data_dir()))
        return _TOO_LONG if any(w.casefold() in plain for w in names) else None
    parsed = _parsed(command, _env_refs)
    segments, text = parsed.segments, parsed.text
    if any(LIFT_VERB in " ".join(s.words).split() and not (parsed.readable and _only_reads(s)) for s in segments):
        return f"a check setting with `{LIFT_VERB}`"
    bases = _bases(segments, cwd)
    saved = _saved_scripts(segments, bases)
    kept = []
    for segment in segments:
        name = segment.words[0].partition("=")[0] if len(segment.words) == 1 else None
        if name in saved:
            args = saved[name][2:]
        else:
            run = _script_run(segment.words, saved, bases)
            if run is None:
                kept.append(segment)
                continue
            refused = _refused_run(*run)
            if refused:
                return refused
            # After a cd into a protected folder, a verb, a URL or a relative --ref would read as a path there.
            args = [w for w in run[1] if w.startswith(("/", "~"))] \
                if os.path.basename(run[0]) in PROGRAMME_SCRIPTS else run[1]
        if any(_named(word, bases, dirs) for word in [*args, *segment.targets]):
            kept.append(segment)
    for segment in kept:
        for word in segment.targets:
            hit = _named(word, bases, dirs)
            if hit:
                return hit
    sets_key = any(key in guard_text.HIDING_CHARS.sub("", text) for key in HOOK_KEYS)
    if sets_key:
        hit = _settings_word(t for s in segments for t in s.targets)
        if hit:
            return hit
    found = next(filter(None, (_named(w, bases, dirs) for s in kept for w in s.words)), None)
    if found is None and sets_key:
        found = _settings_word(w for s in segments for w in s.words)
    if found is None or (parsed.readable and all(map(_only_reads, kept))):
        return None
    return found


def _settings_file(path: str) -> bool:
    parent = os.path.dirname(path)
    config = os.environ.get("CLAUDE_CONFIG_DIR")
    return _is_settings_name(path) and (os.path.basename(parent).casefold() == ".claude" or bool(config) and (
        parent.casefold() == guard_text.resolved(config, "/").casefold()))


def _settings_hit(raw, base):
    path = guard_text.resolved(raw, base)
    # As written too: a symlinked .claude folder resolves to a path without its name.
    written = os.path.normpath(os.path.join(base, guard_text.expanded(raw)))
    return path if _settings_file(path) or _settings_file(written) else None


def settings_target(tool_name, tool_input, cwd):
    """The settings file a call would write, for `no-settings-writes`. A Bash call that only reads names none."""
    if tool_name != "Bash":
        raw = tool_input.get("file_path")
        return _settings_hit(raw, cwd) if isinstance(raw, str) and raw else None
    command = tool_input.get("command")
    if not isinstance(command, str):
        return None
    if _too_long(command):
        return _TOO_LONG
    parsed = _parsed(command)
    bases = _bases(parsed.segments, cwd)

    def hit(word):
        return next(filter(None, (_settings_hit(f, b) for f in _fragments(word) if _is_settings_name(f)
                                  for b in bases)), None)

    found = next(filter(None, map(hit, (t for s in parsed.segments for t in s.targets))), None)
    if found:
        return found
    found = next(filter(None, map(hit, (w for s in parsed.segments for w in s.words))), None)
    return None if found is None or (parsed.readable and all(map(_only_reads, parsed.segments))) else found


def only_reads(command, names_target) -> bool:
    """True when each part of a Bash command only reads and no redirect writes a word that names_target accepts."""
    parsed = _parsed(command)
    return parsed.readable and all(map(_only_reads, parsed.segments)) \
        and not any(names_target(t) for s in parsed.segments for t in s.targets)


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
    path = guard_text.resolved(raw, cwd)
    if _under(path, dirs):
        return path
    # As written too: a symlinked settings file resolves to a path without the settings name.
    if _is_settings_name(raw) or _is_settings_name(path):
        new = _new_text(tool_name, tool_input)
        return path if any(key in new for key in HOOK_KEYS) else None
    return None


def _may_name_target(tool_input) -> bool:
    text = _joined(json.dumps(tool_input))
    return any(_joined(word) in text for word in (*NAMED_WORDS, _PLUGIN_ROOT))


def _file_hits(tool_name, tool_input, cwd):
    """(target, kind) for each settings or behaviours file this call would write."""
    if settings_guard.names_settings(tool_input):
        found = settings_target(tool_name, tool_input, cwd)
        if found:
            yield found, "a settings file"
    if behaviour_guard.names_any(tool_input):
        command = tool_input.get("command")
        reads = tool_name == "Bash" and isinstance(command, str) and only_reads(command, behaviour_guard.names_file)
        found = _TOO_LONG if _too_long(command) else None if reads else behaviour_guard.target(tool_name, tool_input, cwd)
        if found:
            yield found, "a behaviours file"


def _protected_target(tool_name, tool_input, cwd):
    if not _may_name_target(tool_input):
        return None
    dirs = _protected()
    if tool_name != "Bash":
        return _file_target(tool_name, tool_input, cwd, dirs)
    command = tool_input.get("command")
    return _bash_target(command, cwd, dirs) if isinstance(command, str) else None


def _refused_write(names, target) -> str:
    others = f". These limits are all on, and each must be lifted: {', '.join(names)}" if len(names) > 1 else ""
    return (f"would write {target}. While a limit is on, Auto refuses this session's writes to the programme's "
            "files or the installed plugin, setting `CLAUDE_AUTO_DATA_DIR`, naming `CLAUDE_CODE_SESSION_ID`, a run "
            f"of `programme.sh` with a verb other than {', '.join(RUN_VERBS)} or with an argument not written out, "
            "and a write of `disableAllHooks` or `allowManagedHooksOnly` to a settings file; a command that names "
            f"one of them must be a plain read{others}")


def decision(stdin_raw: str):
    """(deny, journal_row) or None. The caller emits the deny before it journals the row."""
    data = json.loads(stdin_raw) if stdin_raw else None
    if not isinstance(data, dict) or data.get("tool_name") not in ("Bash", *_FILE_TOOLS):
        return None
    tool_name = data["tool_name"]
    tool_input = data.get("tool_input") if isinstance(data.get("tool_input"), dict) else {}
    session_id = data.get("session_id") if isinstance(data.get("session_id"), str) else None
    cwd = data.get("cwd")
    cwd = cwd if isinstance(cwd, str) and os.path.isabs(cwd) else os.getcwd()
    if settings_guard.names_settings(tool_input) or behaviour_guard.names_any(tool_input):
        # States first: the settings and behaviours guards read them for this call anyway, and finding a
        # behaviours target loads modules that only a limit on needs.
        checks = load_lib_module("programme_checks")
        if checks.hook_checks(session_id)["states"][WRITES_LIMIT]:
            for target, kind in _file_hits(tool_name, tool_input, cwd):
                return checks.limit_refusal(WRITES_LIMIT, session_id, tool_name, f"would write {target}, {kind}",
                                            **settings_guard.written(tool_name, tool_input, target))
    target = _protected_target(tool_name, tool_input, cwd)
    if target is None:
        return None
    # Read only after a hit: this walks every held lease, and most calls name nothing protected.
    checks = load_lib_module("programme_checks")
    states = checks.hook_checks(session_id)["states"]
    names = [name for name in checks.limit_names() if states.get(name)]
    if not names:
        return None
    return checks.limit_refusal(names[0], session_id, tool_name, _refused_write(names, target), limits=names,
                                **settings_guard.written(tool_name, tool_input, target))
