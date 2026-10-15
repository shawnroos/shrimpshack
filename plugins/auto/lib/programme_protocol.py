#!/usr/bin/env python3
"""Programme protocol: the rules that map a kind of change to its deliverables.

Three JSON layers load in order, fail-closed: the plugin defaults, Shawn's
personal layer and the project layer of one repo. A rule, autonomy entry or check
that fails validation or adoption goes to ``rejected`` with a reason; it never
loads. The format is in ``docs/contracts/programme-protocol-format.md``.
"""

from __future__ import annotations

import hashlib
import json
import os
import platform
import re
import subprocess
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

programme_home = load_lib_module("programme_home")

PERSONAL_PATH_ENV = "CLAUDE_AUTO_PERSONAL_PROTOCOL"
MACHINE_ENV = "CLAUDE_AUTO_MACHINE"
DEFAULT_PERSONAL_PATH = "~/.claude/shared/auto/protocol.json"
PLUGIN_PATH = os.path.join(os.path.dirname(_LIB_DIR), "protocol", "defaults.json")
PROJECT_FILE = ".claude/auto-protocol.json"
PROTOCOL_FORMAT = 1
GIT_TIMEOUT_SECONDS = 5

LAYERS = ("plugin", "personal", "project")
DELIVERABLES = programme_home.DELIVERABLES
OUTCOMES = ("handed", "debugged")
REQUIREMENTS = DELIVERABLES + OUTCOMES
AUTONOMY_LEVELS = programme_home.AUTONOMY_LEVELS
AUTONOMY_WIDTH = {"never": 0, "propose": 1, "act_and_tell": 2, "act": 3}
CHANGE_KINDS = (
    "flagged_code", "fix_only", "shared_package", "evals_or_docs",
    "product_question", "shared_blocker",
)
RULE_FIELDS = (
    "id", "applies_when", "requires", "evidence_bar", "caveat", "autonomy",
    "added_by", "added_at", "why",
)
ADOPTION_FIELDS = ("machine", "run_id", "prompt_id", "quote", "prompt_hash", "hash")
LAYER_KEYS = ("protocol_format", "rules", "autonomy", "checks")
CHECK_KEYS = ("verified.lookup", "verified.deployed_sha")
CHECK_PLACEHOLDERS = ("id", "sha", "repo")

_RULE_ID_RE = re.compile(r"^[a-z][a-z0-9-]*$")
_KIND_RE = re.compile(r"^[a-z][a-z0-9_]*$")
_PLACEHOLDER_RE = re.compile(r"\{([^{}]*)\}")
_SYNC_CONFLICT_MARK = ".sync-conflict-"


class _Reject(Exception):
    def __init__(self, reason: str, detail=None):
        super().__init__(reason)
        self.reason = reason
        self.detail = detail


def personal_path() -> str:
    override = os.environ.get(PERSONAL_PATH_ENV)
    if override:
        return override
    return os.path.expanduser(DEFAULT_PERSONAL_PATH)


def machine_name() -> str:
    override = os.environ.get(MACHINE_ENV)
    if override:
        return override
    return platform.node().split(".")[0] or "unknown"


def content_hash(entry: dict) -> str:
    body = {k: v for k, v in entry.items() if k != "adoption"}
    blob = json.dumps(body, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return "sha256:" + hashlib.sha256(blob.encode("utf-8")).hexdigest()


def approval_key(target: str, digest: str) -> str:
    return "%s@%s" % (target, digest)


def target_of(section: str, name: str, repo=None) -> str:
    if section == "checks":
        return "check:%s:%s" % (repo, name)
    return "%s:%s" % ("rule" if section == "rules" else "autonomy", name)


def _keys(obj, required, optional=()) -> None:
    if not isinstance(obj, dict):
        raise _Reject("bad_value", "not an object")
    for key in obj:
        if key not in required and key not in optional:
            raise _Reject("unknown_key", key)
    for key in required:
        if key not in obj:
            raise _Reject("missing_field", key)


def _text(value, field, *, allow_empty=False) -> None:
    if not isinstance(value, str) or (not allow_empty and not value.strip()):
        raise _Reject("bad_value", field)


def _check_requires(rule: dict) -> None:
    requires = rule["requires"]
    if not isinstance(requires, list) or not requires:
        raise _Reject("bad_value", "requires")
    for name in requires:
        if not isinstance(name, str) or name not in REQUIREMENTS:
            raise _Reject("unknown_deliverable", str(name))
    if len(set(requires)) != len(requires):
        raise _Reject("bad_value", "requires")
    bar = rule["evidence_bar"]
    if not isinstance(bar, dict) or set(bar) != set(requires):
        raise _Reject("bad_value", "evidence_bar")
    for value in bar.values():
        _text(value, "evidence_bar")


def _check_applies_when(value) -> None:
    _keys(value, ("change_kinds",))
    kinds = value["change_kinds"]
    if not isinstance(kinds, list) or not kinds:
        raise _Reject("bad_value", "applies_when")
    for kind in kinds:
        if not isinstance(kind, str) or not _KIND_RE.match(kind):
            raise _Reject("bad_value", "applies_when")


def _check_level(level) -> None:
    if not isinstance(level, str) or level not in AUTONOMY_LEVELS:
        raise _Reject("unknown_autonomy", str(level))


def _validate_rule(rule, *, allow_adoption=True) -> None:
    _keys(rule, RULE_FIELDS, ("adoption",) if allow_adoption else ())
    if not isinstance(rule["id"], str) or not _RULE_ID_RE.match(rule["id"]):
        raise _Reject("bad_value", "id")
    _check_applies_when(rule["applies_when"])
    _check_requires(rule)
    _text(rule["caveat"], "caveat", allow_empty=True)
    _check_level(rule["autonomy"])
    _text(rule["added_by"], "added_by")
    if programme_home.run_record_core.parse_iso(rule["added_at"]) is None:
        raise _Reject("bad_value", "added_at")
    _text(rule["why"], "why")


def _verdict(check, *args) -> dict:
    try:
        check(*args)
    except _Reject as exc:
        return {"ok": False, "reason": exc.reason, "detail": exc.detail}
    return {"ok": True, "reason": None, "detail": None}


def validate_proposal(rule) -> dict:
    return _verdict(lambda: _validate_rule(rule, allow_adoption=False))


def _validate_autonomy(action, entry) -> None:
    if not isinstance(action, str) or not _KIND_RE.match(action):
        raise _Reject("bad_value", "action")
    _keys(entry, ("level",))
    _check_level(entry["level"])


def validate_autonomy(action, entry) -> dict:
    return _verdict(_validate_autonomy, action, entry)


def _validate_bare_check(key, entry) -> None:
    if isinstance(entry, dict) and "adoption" in entry:
        raise _Reject("unknown_key", "adoption")
    _validate_check_block({key: entry})


def validate_check(key, entry) -> dict:
    return _verdict(_validate_bare_check, key, entry)


def _validate_adoption(adoption) -> None:
    try:
        _keys(adoption, ADOPTION_FIELDS, ("widening",))
        for field in ADOPTION_FIELDS:
            _text(adoption[field], field, allow_empty=(field == "quote"))
        if "widening" in adoption and not isinstance(adoption["widening"], bool):
            raise _Reject("bad_value", "widening")
    except _Reject as exc:
        raise _Reject("adoption_malformed", exc.detail)


def _verify_adoption(entry: dict, prompt_lookup, target, *, local_only=False, missing="not_adopted",
                     elsewhere="check_not_adopted_here"):
    adoption = entry.get("adoption")
    if adoption is None:
        raise _Reject(missing)
    _validate_adoption(adoption)
    if adoption["hash"] != content_hash(entry):
        raise _Reject("adoption_unverified", "hash")
    if adoption["machine"] != machine_name():
        if local_only:
            raise _Reject(elsewhere, adoption["machine"])
        return adoption["machine"]
    if prompt_lookup is None:
        raise _Reject("adoption_unverified", "no prompt lookup")
    try:
        prompt = prompt_lookup(adoption["run_id"], adoption["prompt_id"])
    except Exception:
        raise _Reject("adoption_unverified", "prompt lookup failed")
    if not isinstance(prompt, dict):
        raise _Reject("adoption_unverified", "prompt missing")
    if prompt.get("origin") != "typed":
        raise _Reject("adoption_unverified", "prompt not typed")
    if prompt.get("text_hash") != adoption["prompt_hash"]:
        raise _Reject("adoption_unverified", "prompt hash")
    if approval_key(target, adoption["hash"]) not in (prompt.get("approved") or ()):
        raise _Reject("adoption_unverified", "no approval")
    return None


def _wider(level: str, prior: str) -> bool:
    return AUTONOMY_WIDTH[level] > AUTONOMY_WIDTH[prior]


def _new_state() -> dict:
    return {"rules": {}, "autonomy": {}, "checks": {}, "rejected": [], "notices": [], "layers": []}


def _reject(state, layer, entry_id, reason, detail=None) -> None:
    state["rejected"].append({"layer": layer, "id": entry_id, "reason": reason, "detail": detail})


def _adopt(layer, entry, lookup, prior_level, level, target):
    if layer == "plugin":
        return None
    adopted_on = _verify_adoption(entry, lookup, target, local_only=(layer == "project"),
                                  elsewhere="not_adopted_here")
    widening = entry["adoption"].get("widening") is True
    wider = prior_level is not None and _wider(level, prior_level)
    # Another machine's adoption is checked only by its own hash, which any writer of the
    # synced file can recompute, so it may narrow here but never widen.
    if adopted_on is not None and (widening or wider):
        raise _Reject("widening_not_adopted_here", adopted_on)
    if wider and not widening:
        raise _Reject("widening_unmarked", "%s over %s" % (level, prior_level))
    return adopted_on


def _merge_rules(state, layer, rules, lookup) -> None:
    ids = [r.get("id") if isinstance(r, dict) else None for r in rules]
    for index, raw in enumerate(rules):
        rid = ids[index] if isinstance(ids[index], str) else None
        label = rid or "#%d" % index
        if rid is not None and ids.count(rid) > 1:
            _reject(state, layer, label, "duplicate_id")
            continue
        try:
            _validate_rule(raw)
            prior = state["rules"].get(rid)
            adopted_on = _adopt(layer, raw, lookup, prior and prior["autonomy"], raw["autonomy"],
                                target_of("rules", rid))
        except _Reject as exc:
            _reject(state, layer, label, exc.reason, exc.detail)
            continue
        rule = {k: raw[k] for k in RULE_FIELDS}
        rule.update(layer=layer, adopted_on=adopted_on, adoption=raw.get("adoption"))
        state["rules"][rid] = rule


def _merge_autonomy(state, layer, entries, lookup) -> None:
    for action, raw in entries.items():
        try:
            _validate_autonomy(action, {k: v for k, v in raw.items() if k != "adoption"}
                               if isinstance(raw, dict) else raw)
            prior = state["autonomy"].get(action)
            adopted_on = _adopt(layer, raw, lookup, prior and prior["level"], raw["level"],
                                target_of("autonomy", action))
        except _Reject as exc:
            _reject(state, layer, action, exc.reason, exc.detail)
            continue
        state["autonomy"][action] = {"level": raw["level"], "layer": layer, "adopted_on": adopted_on}


def _validate_check_block(block) -> None:
    if not isinstance(block, dict):
        raise _Reject("bad_value", "checks")
    for key, entry in block.items():
        if key not in CHECK_KEYS:
            raise _Reject("unknown_check", key)
        _keys(entry, ("argv",), ("adoption",))
        argv = entry["argv"]
        if not isinstance(argv, list) or not argv:
            raise _Reject("bad_value", key)
        for part in argv:
            _text(part, key)
            for name in _PLACEHOLDER_RE.findall(part):
                if name not in CHECK_PLACEHOLDERS:
                    raise _Reject("bad_value", key)


def _merge_check_block(state, layer, repo, block, lookup) -> None:
    try:
        _validate_check_block(block)
    except _Reject as exc:
        _reject(state, layer, repo, exc.reason, exc.detail)
        return
    for key, entry in block.items():
        try:
            if layer != "plugin":
                _verify_adoption(entry, lookup, target_of("checks", key, repo), local_only=True,
                                 missing="check_not_adopted")
        except _Reject as exc:
            _reject(state, layer, "%s:%s" % (repo, key), exc.reason, exc.detail)
            continue
        state["checks"].setdefault(repo, {})[key] = {"argv": list(entry["argv"]), "layer": layer}


def _merge_checks(state, layer, checks, lookup, project_repo) -> None:
    if layer == "project":
        _merge_check_block(state, layer, project_repo, checks, lookup)
        return
    for repo, block in checks.items():
        _merge_check_block(state, layer, repo, block, lookup)


def _layer_shape(doc) -> None:
    if not isinstance(doc, dict):
        raise _Reject("malformed_layer", "not an object")
    for key in doc:
        if key not in LAYER_KEYS:
            raise _Reject("unknown_key", key)
    stamp = doc.get("protocol_format", PROTOCOL_FORMAT)
    if not isinstance(stamp, int) or isinstance(stamp, bool) or stamp < 1:
        raise _Reject("malformed_layer", "protocol_format")
    if stamp > PROTOCOL_FORMAT:
        raise _Reject("newer_format", str(stamp))
    for key, kind in (("rules", list), ("autonomy", dict), ("checks", dict)):
        if not isinstance(doc.get(key, kind()), kind):
            raise _Reject("malformed_layer", key)


def _apply_layer(state, layer, source, text, lookup, project_repo) -> None:
    try:
        try:
            doc = json.loads(text)
        except ValueError:
            raise _Reject("malformed_layer", "not JSON")
        _layer_shape(doc)
    except _Reject as exc:
        _reject(state, layer, None, exc.reason, exc.detail)
        state["layers"].append({"layer": layer, "source": source, "status": "rejected"})
        return
    _merge_rules(state, layer, doc.get("rules", []), lookup)
    _merge_autonomy(state, layer, doc.get("autonomy", {}), lookup)
    _merge_checks(state, layer, doc.get("checks", {}), lookup, project_repo)
    state["layers"].append({"layer": layer, "source": source, "status": "loaded"})


def _read_file(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except FileNotFoundError:
        return None
    except (OSError, ValueError):
        raise _Reject("malformed_layer", "unreadable")


def _read_plugin(path):
    text = _read_file(path)
    if text is None:
        raise _Reject("malformed_layer", "missing")
    return text


def _sync_conflicts(path: str) -> list:
    folder = os.path.dirname(path) or "."
    try:
        names = sorted(os.listdir(folder))
    except OSError:
        return []
    return [os.path.join(folder, n) for n in names if _SYNC_CONFLICT_MARK in n]


def _git(repo_path: str, *argv):
    env = dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_TERMINAL_PROMPT="0")
    try:
        done = subprocess.run(
            ["git", "-C", repo_path] + list(argv), capture_output=True, text=True,
            timeout=GIT_TIMEOUT_SECONDS, env=env,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    return done


def _read_project(repo_path: str):
    ref = _git(repo_path, "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD")
    if ref is None or ref.returncode != 0 or not ref.stdout.strip():
        raise _Reject("no_default_branch", repo_path)
    spec = "%s:%s" % (ref.stdout.strip(), PROJECT_FILE)
    present = _git(repo_path, "cat-file", "-e", spec)
    if present is None:
        raise _Reject("malformed_layer", "unreadable at " + spec)
    if present.returncode != 0:
        return None, spec
    shown = _git(repo_path, "cat-file", "-p", spec)
    if shown is None or shown.returncode != 0:
        raise _Reject("malformed_layer", "unreadable at " + spec)
    return shown.stdout, spec


def _load_layer(state, layer, source, read, lookup, project_repo) -> None:
    try:
        text, source = read()
    except _Reject as exc:
        _reject(state, layer, None, exc.reason, exc.detail)
        state["layers"].append({"layer": layer, "source": source, "status": "rejected"})
        return
    if text is None:
        state["layers"].append({"layer": layer, "source": source, "status": "missing"})
        return
    _apply_layer(state, layer, source, text, lookup, project_repo)


def plugin_layer(plugin_path=None) -> dict:
    state = _new_state()
    source = plugin_path or PLUGIN_PATH
    _load_layer(state, "plugin", source, lambda: (_read_plugin(source), source), None, None)
    return state


def load(repo_path=None, repo_key=None, prompt_lookup=None, plugin_path=None) -> dict:
    state = plugin_layer(plugin_path)

    personal = personal_path()
    for conflict in _sync_conflicts(personal):
        state["notices"].append({"layer": "personal", "kind": "sync_conflict", "path": conflict})
    _load_layer(state, "personal", personal,
                lambda: (_read_file(personal), personal), prompt_lookup, None)

    if repo_path:
        project_repo = repo_key or os.path.realpath(repo_path)
        _load_layer(state, "project", repo_path,
                    lambda: _read_project(repo_path), prompt_lookup, project_repo)
    return state


def match(protocol: dict, change_kinds) -> dict:
    kinds = set(change_kinds or ())
    hits = [
        rule for _, rule in sorted(protocol["rules"].items())
        if kinds & set(rule["applies_when"]["change_kinds"])
    ]
    if not hits:
        return {"matched_rule": None, "requires": [], "deliverables": [],
                "autonomy": None, "reason": "no_matching_rule"}
    requires = [name for name in REQUIREMENTS if any(name in r["requires"] for r in hits)]
    autonomy = min((r["autonomy"] for r in hits), key=lambda level: AUTONOMY_WIDTH[level])
    return {
        "matched_rule": [r["id"] for r in hits],
        "requires": requires,
        "deliverables": [name for name in requires if name in DELIVERABLES],
        "autonomy": autonomy,
        "reason": None,
    }


def proposed_rules(record) -> list:
    block = (record or {}).get("programme") or {}
    rules = block.get("proposed_rules")
    return rules if isinstance(rules, list) else []


def summary(protocol: dict, record=None) -> list:
    rows = []
    for rid, rule in sorted(protocol["rules"].items()):
        rows.append({"id": rid, "status": "loaded", "layer": rule["layer"],
                     "adopted_on": rule["adopted_on"], "autonomy": rule["autonomy"],
                     "requires": list(rule["requires"])})
    for entry in protocol["rejected"]:
        rows.append({"id": entry["id"], "status": "rejected", "layer": entry["layer"],
                     "reason": entry["reason"]})
    for rule in proposed_rules(record):
        verdict = validate_proposal(rule)
        rows.append({"id": rule.get("id") if isinstance(rule, dict) else None,
                     "status": "proposed", "layer": "record", "reason": verdict["reason"]})
    return rows
