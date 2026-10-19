#!/usr/bin/env python3
"""Closed catalog of read-only gh operations and a conservative matcher for native Bash rules."""

from __future__ import annotations

import os
import re

UNSEEN = "Settings files cannot show managed settings or a command-line --settings flag."
DESTINATION_FILE = os.path.join(".claude", "settings.local.json")
BUILTIN_READ_ONLY = ("cat", "echo", "grep", "head", "ls", "pwd", "tail", "wc")

_NUMBER = re.compile(r"[0-9]{1,12}")
_FIELDS = re.compile(r"[A-Za-z][A-Za-z0-9,]{0,399}")
_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._/-]{0,199}")
_WORD = re.compile(r"[a-z_]{1,40}")
_SHA = re.compile(r"[0-9a-f]{7,40}")

_EXCLUSIONS = (
    "merge (gh pr merge)",
    "comment or review (gh pr comment, gh pr review)",
    "push (git push)",
    "credential access (gh auth token, gh auth status --show-token)",
)
_TEXT_REACH = (
    "The rule matches command text, not a repository: in sessions of this repository it also "
    "allows reads of other GitHub repositories through --repo or -R."
)

CATALOG = {
    "pr_checks": {
        "argv": ("gh", "pr", "checks"),
        "rule": "Bash(gh pr checks *)",
        "target": _NUMBER,
        "flags": {"--json": _FIELDS, "--required": None},
        "aliases": {},
        "reach": "Also allows gh pr checks with --watch (a long-running read) and --web (opens a browser).",
    },
    "pr_view": {
        "argv": ("gh", "pr", "view"),
        "rule": "Bash(gh pr view *)",
        "target": _NUMBER,
        "flags": {"--json": _FIELDS, "--comments": None},
        "aliases": {"-c": "--comments"},
        "reach": "Also allows gh pr view with --web (opens a browser) and any --json field, including comment bodies.",
    },
    "run_list": {
        "argv": ("gh", "run", "list"),
        "rule": "Bash(gh run list *)",
        "target": None,
        "flags": {
            "--json": _FIELDS,
            "--limit": _NUMBER,
            "--branch": _NAME,
            "--workflow": _NAME,
            "--status": _WORD,
            "--commit": _SHA,
        },
        "aliases": {"-L": "--limit", "-b": "--branch", "-w": "--workflow", "-s": "--status", "-c": "--commit"},
        "reach": "Also allows gh run list with --web (opens a browser) and any filter.",
    },
    "run_view": {
        "argv": ("gh", "run", "view"),
        "rule": "Bash(gh run view *)",
        "target": _NUMBER,
        "flags": {
            "--json": _FIELDS,
            "--verbose": None,
            "--job": _NUMBER,
            "--attempt": _NUMBER,
            "--exit-status": None,
        },
        "aliases": {"-v": "--verbose", "-j": "--job", "-a": "--attempt"},
        "reach": (
            "Also allows gh run view --log and --log-failed, which print full job logs that can hold "
            "secrets a CI step echoed, and --web (opens a browser)."
        ),
    },
}
for _op_id, _spec in CATALOG.items():
    _spec["id"] = _op_id
    _spec["exclusions"] = list(_EXCLUSIONS)

_CONTROL = re.compile("[\x00-\x09\x0b-\x1f\x7f-\x9f​-‏ -‮⁠-⁩﻿]")
_FORBIDDEN = (
    ("$(", "subshell"),
    ("`", "subshell"),
    ("(", "subshell"),
    (")", "subshell"),
    ("<", "redirection"),
    (">", "redirection"),
    ("#", "comment"),
    ("'", "quote"),
    ('"', "quote"),
    ("$", "expansion"),
    ("\\", "escape"),
)
_OPERATORS = re.compile(r"(\|\||&&|\|&|[|;&\n])")
_TOKEN = re.compile(r"[A-Za-z0-9._/,:=+-]+")
_ENV = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)=")
_SCOPE_COMMANDS = ("cd", "pushd", "popd")
_SCOPE_FLAGS = ("-C", "-R", "--repo", "--hostname")


class _Refused(Exception):
    def __init__(self, kind, subject):
        super().__init__(subject)
        self.kind = kind
        self.subject = subject


def _split(command):
    if not isinstance(command, str) or not command.strip():
        raise _Refused("unknown_scope", "empty command")
    if _CONTROL.search(command.strip(" \n")):
        raise _Refused("unknown_scope", "control character")
    text = command.strip(" \n")
    for needle, label in _FORBIDDEN:
        if needle in text:
            raise _Refused("unknown_scope", label)
    parts = _OPERATORS.split(text)
    segments = []
    for index in range(0, len(parts), 2):
        tokens = parts[index].split(" ")
        tokens = [tok for tok in tokens if tok]
        if not tokens:
            raise _Refused("unknown_scope", "empty subcommand")
        for tok in tokens:
            if not _TOKEN.fullmatch(tok):
                raise _Refused("unknown_scope", f"unexpected character in {tok}")
        operator = parts[index - 1] if index else None
        segments.append((";" if operator == "\n" else operator, tokens))
    return segments


def _check_scope(tok):
    name = tok.partition("=")[0]
    if name in _SCOPE_FLAGS:
        raise _Refused("unknown_scope", name)


def _gh(tokens):
    for tok in tokens[1:3]:
        if tok.startswith("-"):
            _check_scope(tok)
            raise _Refused("unlisted_flag", tok)
    argv = tuple(tokens[:3])
    spec = next((s for s in CATALOG.values() if s["argv"] == argv), None)
    if spec is None:
        raise _Refused("not_catalogued", " ".join(argv))
    target, flags = None, {}
    rest = iter(tokens[3:])
    for tok in rest:
        if not tok.startswith("-"):
            if target is not None or spec["target"] is None or not spec["target"].fullmatch(tok):
                raise _Refused("unknown_scope", f"argument {tok}")
            target = tok
            continue
        _check_scope(tok)
        name, eq, value = tok.partition("=")
        name = spec["aliases"].get(name, name)
        if name not in spec["flags"]:
            raise _Refused("unlisted_flag", name)
        if name in flags:
            raise _Refused("unknown_scope", f"repeated flag {name}")
        shape = spec["flags"][name]
        if shape is None:
            if eq:
                raise _Refused("unlisted_flag", tok)
            flags[name] = None
            continue
        if not eq:
            value = next(rest, None)
        if value is None or not shape.fullmatch(value):
            raise _Refused("unlisted_flag", f"{name} value")
        flags[name] = value
    words = list(argv) + ([target] if target else [])
    for name in spec["flags"]:
        if name in flags:
            words.append(name if flags[name] is None else f"{name} {flags[name]}")
    return {"op": spec["id"], "target": target, "normalized": " ".join(words)}


def _builtin(tokens):
    for tok in tokens[1:]:
        _check_scope(tok)
        if tokens[0] == "tail" and (tok.startswith("--follow") or (tok[:1] == "-" and tok[1:2] != "-" and ("f" in tok or "F" in tok))):
            raise _Refused("unlisted_flag", tok)


def _segment(tokens):
    env = _ENV.match(tokens[0])
    if env:
        raise _Refused("unknown_scope", f"environment prefix {env.group(1)}")
    if tokens[0] == "gh":
        return _gh(tokens)
    if tokens[0] in _SCOPE_COMMANDS:
        raise _Refused("unknown_scope", tokens[0])
    if tokens[0] in BUILTIN_READ_ONLY:
        _builtin(tokens)
        return None
    raise _Refused("not_catalogued", tokens[0])


def eligibility(command):
    try:
        calls, rendered = [], []
        for operator, tokens in _split(command):
            call = _segment(tokens)
            if call:
                calls.append(call)
            if operator:
                rendered.append(operator)
            rendered.append(call["normalized"] if call else " ".join(tokens))
    except _Refused as refusal:
        return {"eligible": False, "kind": refusal.kind, "subject": refusal.subject}
    if not calls:
        return {"eligible": False, "kind": "not_catalogued", "subject": "no catalog operation"}
    return {
        "eligible": True,
        "operations": sorted({call["op"] for call in calls}),
        "calls": calls,
        "normalized": " ".join(rendered),
    }


def _entry(item):
    if isinstance(item, str):
        return item, None
    if isinstance(item, dict):
        return item.get("rule"), item.get("source")
    if isinstance(item, (list, tuple)) and len(item) == 2:
        return item[0], item[1]
    return None, None


def _pattern(rule):
    if not isinstance(rule, str):
        return None
    rule = rule.strip()
    if rule == "Bash":
        return "*"
    match = re.fullmatch(r"Bash\((.*)\)", rule, re.S)
    if not match:
        return None
    pattern = " ".join(match.group(1).split())
    if pattern.endswith(":*"):
        pattern = pattern[:-2] + " *"
    return pattern or "*"


def _matches(pattern, text):
    tail = r"(?: .*)?" if pattern.endswith(" *") else ""
    body = pattern[:-2] if tail else pattern
    regex = ".*".join(re.escape(part) for part in body.split("*")) + tail
    return re.fullmatch(regex, text, re.S) is not None


def _first_match(entries, texts):
    for item in entries or ():
        rule, source = _entry(item)
        pattern = _pattern(rule)
        if pattern is not None and any(_matches(pattern, text) for text in texts):
            return rule, source
    return None


def _reaches_more(rule, op_id):
    pattern = _pattern(rule)
    if "*" not in pattern:
        return False
    catalog_literal = _pattern(CATALOG[op_id]["rule"]).split("*")[0]
    return len(pattern.split("*")[0]) < len(catalog_literal)


def _result(outcome, rule=None, source=None, layer=None, note=""):
    return {"outcome": outcome, "rule": rule, "source": source, "layer": layer, "note": note, "unseen": UNSEEN}


def _catalog_op(tokens):
    try:
        return _gh(tokens)["op"] if tokens[0] == "gh" else None
    except _Refused:
        return None


def _is_builtin(tokens):
    if tokens[0] not in BUILTIN_READ_ONLY:
        return False
    try:
        _builtin(tokens)
    except _Refused:
        return False
    return True


def coverage(command, allow, ask=(), deny=(), *, classify_all_shell=False):
    try:
        segments = [tokens for _, tokens in _split(command)]
    except _Refused as refusal:
        whole = [" ".join(command.split())] if isinstance(command, str) else []
        for layer, entries in (("deny", deny), ("ask", ask)):
            hit = _first_match(entries, whole)
            if hit:
                return _result("blocked_elsewhere", *hit, layer, f"{layer} rule {hit[0]} matches the command")
        return _result("not_covered", note=f"cannot read the command ({refusal.subject}), so no rule is counted")
    views = []
    for tokens in segments:
        env = _ENV.match(tokens[0])
        stripped = tokens
        while stripped and _ENV.match(stripped[0]):
            stripped = stripped[1:]
        views.append((tokens, stripped, env.group(1) if env else None))
    for layer, entries in (("deny", deny), ("ask", ask)):
        for tokens, stripped, _ in views:
            texts = [" ".join(tokens)] + ([" ".join(stripped)] if stripped else [])
            hit = _first_match(entries, texts)
            if hit:
                return _result("blocked_elsewhere", *hit, layer, f"{layer} rule {hit[0]} matches {texts[-1]}")
    if classify_all_shell:
        return _result(
            "blocked_elsewhere", "autoMode.classifyAllShell", None, "classifier",
            "user settings send every shell command to the auto-mode classifier",
        )
    covering, notes = None, []
    for tokens, _, env in views:
        text = " ".join(tokens)
        if env:
            return _result("not_covered", note=f"environment prefix {env} is never counted as covered: {text}")
        if _is_builtin(tokens):
            continue
        matches = [_entry(item) for item in allow or ()]
        matches = [(r, s) for r, s in matches if _pattern(r) is not None and _matches(_pattern(r), text)]
        if not matches:
            return _result("not_covered", note=f"no allow rule covers: {text}")
        op_id = _catalog_op(tokens)
        narrow = [m for m in matches if not (op_id and _reaches_more(m[0], op_id))]
        chosen = (narrow or matches)[0]
        if op_id and not narrow:
            notes.append(f"{chosen[0]} reaches more than {CATALOG[op_id]['rule']}")
        covering = covering or chosen
    rule, source = covering or (None, None)
    return _result("covered", rule, source, "allow" if covering else "built-in", "; ".join(notes))


def broader_by(proposed, decided_sets):
    held = set()
    for ops in decided_sets or ():
        held.update(ops)
    return sorted(set(proposed) - held)


def render_proposal(op_ids):
    unknown = [op for op in op_ids if op not in CATALOG]
    if unknown:
        raise ValueError(f"unknown operation {', '.join(map(str, unknown))}")
    ordered = [op for op in CATALOG if op in set(op_ids)]
    return {
        "operations": ordered,
        "rules": [CATALOG[op]["rule"] for op in ordered],
        "reach": [_TEXT_REACH] + [CATALOG[op]["reach"] for op in ordered],
        "exclusions": list(_EXCLUSIONS),
        "destination": DESTINATION_FILE,
    }


def _read_head(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read(4096).splitlines()[0].strip()
    except (OSError, UnicodeDecodeError, IndexError):
        return None


def main_checkout(repo_path):
    if not isinstance(repo_path, str) or not repo_path:
        return None
    dotgit = os.path.join(repo_path, ".git")
    if os.path.isdir(dotgit):
        return os.path.realpath(repo_path)
    line = _read_head(dotgit)
    if not line or not line.startswith("gitdir:"):
        return None
    gitdir = os.path.join(repo_path, line[len("gitdir:"):].strip())
    common = _read_head(os.path.join(gitdir, "commondir"))
    if not common:
        return None
    common = os.path.realpath(os.path.join(gitdir, common))
    if os.path.basename(common) != ".git":
        return None
    return os.path.dirname(common)


def destination(repo_path, remit_paths):
    main = main_checkout(repo_path)
    if main is None:
        return {"ok": False, "reason": "cannot resolve the main checkout from .git and commondir"}
    remit = {os.path.realpath(path) for path in remit_paths or () if isinstance(path, str) and path}
    if main not in remit:
        return {"ok": False, "reason": f"main checkout {main} is not a remit repository"}
    return {"ok": True, "main": main, "file": os.path.join(main, DESTINATION_FILE)}
