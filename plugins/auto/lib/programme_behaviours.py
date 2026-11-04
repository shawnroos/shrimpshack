#!/usr/bin/env python3
"""Behaviours: Shawn's standing guidance on how the PM and its workers do the work.

A behaviour lives in one of three layers. Programme-layer entries sit in the programme
block under ``behaviours``. Personal and repo entries sit in ``behaviours.json`` beside
the personal protocol, a personal list plus a list per repo key; each carries an
adoption block like the personal protocol's. A behaviour carries no authority and no
done bar, and one that names a protected escalation in what it tells an agent to do is
refused.
"""

from __future__ import annotations

import functools
import os
import re
import secrets
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

run_record_core = load_lib_module("run_record_core")
programme_home = load_lib_module("programme_home")
programme_journal = load_lib_module("programme_journal")
programme_protocol = load_lib_module("programme_protocol")
programme_sanitize = load_lib_module("programme_sanitize")
programme_naming = load_lib_module("programme_naming")
programme_carryover = load_lib_module("programme_carryover")
programme_layered_store = load_lib_module("programme_layered_store")
programme_terms = load_lib_module("programme_terms")
behaviour_check = load_lib_module("programme_behaviour_check")
behaviour_report = load_lib_module("programme_behaviour_report")

STORE_PATH_ENV = "CLAUDE_AUTO_BEHAVIOURS_STORE"
STORE_NAME = "behaviours.json"
STORE_LOCK = ".behaviours.lock"
STORE_FORMAT = 1
APPROVAL_KIND = "rule_adopted"

LAYERS = ("programme", "repo", "personal", "shipped")
STORED_LAYERS = ("repo", "personal")
MOVE_LAYERS = ("programme", "repo", "personal")
# Same id: the higher rank replaces the lower. "shipped" is only ever loaded from files.
LAYER_RANK = {"shipped": 0, "personal": 1, "repo": 2, "programme": 3}
AUDIENCES = ("pm", "workers", "both")
STATES = ("active", "proposed", "retired")
ACTIVE = "active"
CHECK_BY = ("pm", "agent")
TRIGGERS = ("claim", "merge", "block", "start", "domain")
LIST_FIELDS = ("do", "dont", "skills", "tools", "agents", "formats", "comms")
TEXT_FIELDS = ("evidence", "stop", "why")
EDITABLE_FIELDS = ("when", "applies_to", "examples") + LIST_FIELDS + TEXT_FIELDS
REQUIRED = ("id", "layer", "when", "applies_to")
OPTIONAL = LIST_FIELDS + TEXT_FIELDS + (
    "repo_key", "examples", "source", "state", "overrides", "moved_to", "moved_repo_key", "history", "at",
    "relates_to", "unrelated", "edit_of", "edit_base",
)
# The other fields stay unscanned: stop conditions and "don't" lines need words such as
# "cost", "limit" and "publish", which are protected stems.
PROTECTED_FIELDS = ("do", "skills", "tools", "agents")
# A behaviour carries no authority and limits are enforced in code, so "keep cost under $1"
# is ordinary guidance here, unlike in a project term.
UNPROTECTED_KINDS = ("risk_or_cost_limit", "settled_human_choice")

ID_RE = re.compile(r"[a-z][a-z0-9-]*")
_Reject = programme_protocol._Reject


def check_id(bid) -> str:
    # fullmatch, not "$": "$" accepts a trailing newline, and an id also names a file in the behaviours folders.
    if not isinstance(bid, str) or not ID_RE.fullmatch(bid):
        raise ValueError("a behaviour id is lowercase letters, digits and -, and starts with a letter")
    return bid


BehaviourError = behaviour_check.BehaviourError


def _lines(entry, field) -> None:
    rows = entry.get(field)
    if not isinstance(rows, list) or not all(isinstance(r, str) and r.strip() for r in rows):
        raise _Reject("bad_value", field)


def _sub(obj, required, optional, prefix) -> None:
    try:
        programme_protocol._keys(obj, required, optional)
    except _Reject as exc:
        raise _Reject(exc.reason, prefix + ("." + exc.detail if exc.detail != "not an object" else ""))


def _check_when(when) -> None:
    _sub(when, ("text",), ("checks", "trigger"), "when")
    programme_protocol._text(when["text"], "when.text")
    if when.get("trigger", TRIGGERS[0]) not in TRIGGERS:
        raise _Reject("bad_value", "when.trigger")
    checks = when.get("checks", [])
    if not isinstance(checks, list):
        raise _Reject("bad_value", "when.checks")
    for check in checks:
        _sub(check, ("text", "by"), (), "when.checks")
        if not isinstance(check["text"], str) or not check["text"].strip() or check["by"] not in CHECK_BY:
            raise _Reject("bad_value", "when.checks")


def _check_layer(entry) -> None:
    layer = entry["layer"]
    if layer not in LAYERS:
        raise _Reject("bad_value", "layer")
    if layer == "repo":
        if "repo_key" not in entry:
            raise _Reject("missing_field", "repo_key")
        programme_protocol._text(entry["repo_key"], "repo_key")
    elif "repo_key" in entry:
        raise _Reject("bad_value", "repo_key")
    if "moved_to" in entry and (layer != "programme" or entry["moved_to"] not in STORED_LAYERS):
        raise _Reject("bad_value", "moved_to")
    if entry.get("moved_to") == "repo":
        programme_protocol._text(entry.get("moved_repo_key"), "moved_repo_key")
    elif "moved_repo_key" in entry:
        raise _Reject("bad_value", "moved_repo_key")


def _check_extras(entry) -> None:
    for field in TEXT_FIELDS:
        if field in entry:
            programme_protocol._text(entry[field], field)
    if "examples" in entry:
        _sub(entry["examples"], (), ("good", "bad"), "examples")
        for field, text in entry["examples"].items():
            programme_protocol._text(text, "examples." + field)
    if "source" in entry:
        _sub(entry["source"], (), ("prompt_id", "quote", "wording"), "source")
    overrides = entry.get("overrides", [])
    if not isinstance(overrides, list) or not all(isinstance(o, str) and ID_RE.fullmatch(o) for o in overrides):
        raise _Reject("bad_value", "overrides")
    for field in ("relates_to", "unrelated"):
        if not behaviour_check.answers_valid(entry, field):
            raise _Reject("bad_value", field)
    if not isinstance(entry.get("history", []), list):
        raise _Reject("bad_value", "history")
    if "at" in entry and run_record_core.parse_iso(entry["at"]) is None:
        raise _Reject("bad_value", "at")


# Unlike programme_terms.protected_kind, a stem counts only where a word starts, so
# "reproduction" does not match "production" while "deployed" still matches "deploy".
def line_kind(line):
    words = programme_naming.name_words(line)
    tails = ["".join(words[i:]) for i in range(len(words))]
    for kind, stems in programme_terms.PROTECTED_STEMS.items():
        if kind not in UNPROTECTED_KINDS and any(t.startswith(stem) for t in tails for stem in stems):
            return kind
    return next((programme_terms.PROTECTED_WORDS[w] for w in words if w in programme_terms.PROTECTED_WORDS), None)


def protected_kind(entry):
    for field in PROTECTED_FIELDS:
        for line in entry.get(field) or ():
            kind = line_kind(line)
            if kind:
                return kind
    return None


def _validate(entry, *, allow_adoption=True) -> None:
    programme_protocol._keys(entry, REQUIRED, OPTIONAL + (("adoption",) if allow_adoption else ()))
    if not isinstance(entry["id"], str) or not ID_RE.fullmatch(entry["id"]):
        raise _Reject("bad_value", "id")
    _check_layer(entry)
    _check_when(entry["when"])
    if entry["applies_to"] not in AUDIENCES:
        raise _Reject("bad_value", "applies_to")
    if entry.get("state", ACTIVE) not in STATES:
        raise _Reject("bad_value", "state")
    for field in LIST_FIELDS:
        if field in entry:
            _lines(entry, field)
    if not entry.get("do") and not entry.get("dont"):
        raise _Reject("missing_field", "do or dont")
    _check_extras(entry)
    kind = protected_kind(entry)
    if kind:
        raise _Reject("protected_escalation", kind)


def verdict(entry, *, allow_adoption=True) -> dict:
    return programme_protocol._verdict(lambda: _validate(entry, allow_adoption=allow_adoption))


def put_programme_entry(programme, entry) -> dict:
    check = verdict(entry, allow_adoption=False)
    _refuse(entry, check)
    if entry["layer"] != "programme":
        raise BehaviourError(f"behaviour {entry['id']!r} is a {entry['layer']} entry, not a programme one")
    rows = [e for e in programme.get("behaviours") or [] if not _is(e, entry["id"])]
    programme["behaviours"] = rows + [entry]
    return entry


_S = programme_layered_store.LayeredStore(
    "behaviour", file_name=STORE_NAME, lock_name=STORE_LOCK, path_env=STORE_PATH_ENV, error=BehaviourError,
    verdict=lambda entry: verdict(entry), target=lambda entry: target(entry))
_refuse = _S.refuse
store_path = _S.path
_read = _S._read
read_store = _S.read
write_store = _S.write
_load_stored = _S.load
_is, _without, _place = programme_layered_store._is, programme_layered_store._without, programme_layered_store._place
_default_lookup = programme_layered_store._default_lookup
adopt = programme_carryover.adopt


def target(entry) -> str:
    if entry.get("layer") == "repo":
        return f"behaviour:repo:{entry.get('repo_key')}:{entry.get('id')}"
    return f"behaviour:personal:{entry.get('id')}"


def store(adopted, prompt, run_id, session_id, how="behaviour") -> None:
    _S.store(adopted, prompt, run_id, session_id, how)


def load_store(lookup=None) -> dict:
    out = _load_stored(lookup)
    # Loaded here, not at import: the file loader imports this module.
    load_lib_module("programme_behaviour_files").load_into(out)
    return out


def repo_key_for(programme, repo):
    if isinstance(repo, dict):
        return programme_carryover.key_of(repo)
    if not isinstance(repo, str) or not repo:
        return None
    real = os.path.realpath(repo)
    for entry in (programme.get("remit") or {}).get("repos") or []:
        if isinstance(entry, dict) and isinstance(entry.get("path"), str) \
                and os.path.realpath(entry["path"]) == real:
            return programme_carryover.key_of(entry)
    return os.path.normpath(repo)


def _programme_entries(programme, rejected) -> list:
    out = []
    for entry in programme.get("behaviours") or []:
        check = verdict(entry, allow_adoption=False)
        if check["ok"] and entry["layer"] != "programme":
            check = {"ok": False, "reason": "wrong_layer", "detail": entry["layer"]}
        if check["ok"]:
            out.append(entry)
            continue
        name = entry.get("id") if isinstance(entry, dict) else None
        rejected.append({"layer": "programme", "key": None, "id": name,
                         "reason": check["reason"], "detail": check["detail"]})
    return out


def _reaches(entry, audience) -> bool:
    return audience is None or entry["applies_to"] in (audience, "both")


def _held(loaded, entry) -> bool:
    if entry.get("moved_to") is None:
        return False
    rows = loaded["personal"] if entry["moved_to"] == "personal" else loaded["repos"].get(entry["moved_repo_key"])
    return any(e["id"] == entry["id"] for e in rows or ())


# A copy moved to one repo still serves the programme's other repos; only an item in the
# repo that holds the verified copy reads that copy instead.
def _held_for(loaded, entry, key) -> bool:
    if entry.get("moved_to") == "repo" and entry.get("moved_repo_key") != key:
        return False
    return _held(loaded, entry)


def shown_programme_entries(programme, loaded) -> list:
    keys = programme_carryover.repo_keys(programme) or [None]
    return [e for e in _programme_entries(programme, []) if not all(_held_for(loaded, e, k) for k in keys)]


def from_file(entry) -> bool:
    return entry.get("layer") == "shipped" or entry.get("source") == "file"


def resolve(record, item, repo=None, *, audience=None, lookup=None, store=None) -> dict:
    programme = (record or {}).get("programme") or {}
    loaded = store if store is not None else load_store(lookup)
    rejected = list(loaded["rejected"])
    key = repo_key_for(programme, repo if repo is not None else (item or {}).get("repo"))
    ranked = [(LAYER_RANK["programme"], e) for e in _programme_entries(programme, rejected)
              if not _held_for(loaded, e, key)]
    ranked += [(LAYER_RANK["repo"], e) for e in (loaded["repos"].get(key) or []) if key]
    ranked += [(LAYER_RANK["personal"], e) for e in loaded["personal"] + loaded.get("files", [])]
    ranked += [(LAYER_RANK["shipped"], e) for e in loaded.get("shipped", [])]
    top = {}
    for rank, e in ranked:
        # A proposal is not a decision yet, so it must not hide the file entry it would replace.
        if e.get("state", ACTIVE) in (ACTIVE, "retired"):
            top[e["id"]] = max(top.get(e["id"], 0), rank)
    # Only file-sourced entries are replaced by a higher layer; stored layers keep coexisting as before.
    # A retired winner still hides the file entries below it. No verb retires a file id: a shipped
    # default is switched off by a personal file or a --conflicts-with record whose overrides name it.
    candidates = [e for rank, e in ranked if (rank == top.get(e["id"]) or not from_file(e))
                  and e.get("state", ACTIVE) == ACTIVE]
    overridden = {name for e in candidates for name in e.get("overrides") or ()}
    in_force = [e for e in candidates if e["id"] not in overridden and _reaches(e, audience)]
    return {"in_force": in_force, "rejected": rejected, "notices": list(loaded["notices"])}


def in_force(record, item, repo=None, *, audience=None, lookup=None, store=None) -> list:
    return resolve(record, item, repo, audience=audience, lookup=lookup, store=store)["in_force"]


def _for_workers(record, item, bid, lookup, store=None):
    entry = next((e for e in in_force(record, item, audience="workers", lookup=lookup, store=store)
                  if e["id"] == bid), None)
    if entry is None:
        raise BehaviourError(f"behaviour {bid!r} is not in force for this item's worker (unknown, retired, "
                             "overridden, or it applies to the PM only)")
    return entry


def _pm_checked_only(entry) -> bool:
    checks = entry["when"].get("checks") or []
    return bool(checks) and all(c["by"] == "pm" for c in checks)


# Code cannot test a PM check, so a behaviour gated only by PM checks joins the brief only
# when the PM names it, having seen its checks hold on the item.
def brief_entries(record, item, chosen=(), *, lookup=None) -> tuple:
    loaded = load_store(lookup)
    for bid in chosen:
        _for_workers(record, item, bid, lookup, store=loaded)
    rows = in_force(record, item, audience="workers", store=loaded)
    taken = [e for e in rows if not _pm_checked_only(e) or e["id"] in chosen]
    return taken, [e["id"] for e in rows if e not in taken]


# Shipped defaults are optional context: a plain start (no handoff, nothing chosen) has no brief to carry
# them, and they must not make it refuse. Stored and personal behaviours still do.
def brief_for_start(record, item, chosen=(), *, has_handoff, lookup=None) -> tuple:
    taken, held_back = brief_entries(record, item, chosen, lookup=lookup)
    if not has_handoff and not chosen and all(e.get("layer") == "shipped" for e in taken):
        return [], held_back, [e["id"] for e in taken]
    return taken, held_back, []


# A shipped file cannot know the run, the item or where the plugin sits, so it names a placeholder and
# the code that renders a brief or a reminder fills it. A name this table lacks is refused at load.
PLACEHOLDERS = ("claim_command",)
_PLACEHOLDER = re.compile(r"\{([^{}\s]*)\}")


def unknown_placeholder(text):
    return next((n for n in _PLACEHOLDER.findall(text) if n not in PLACEHOLDERS), None)


def fills_for(run_id, item_key) -> dict:
    program = os.path.join(_LIB_DIR, "programme.sh")
    return {"claim_command": f"bash {program} claim --run {run_id} --item {item_key} --deliverable <name> --ref <ref>"}


def _fill(text, fills) -> str:
    return _PLACEHOLDER.sub(lambda m: fills.get(m.group(1), m.group(0)), text) if fills else text


# What prompt-item --standing sends: the worker behaviours that start with the work, minus those only
# the PM can judge (the same ones a start brief holds back until the PM names them).
def standing_entries(record, item, lookup=None) -> list:
    return [e for e in brief_entries(record, item, lookup=lookup)[0] if trigger_of(e) == "start"]


def _short(entry, fills=None) -> str:
    parts = [f"{entry['id']}: when {entry['when']['text']}"]
    for label, field in (("do", "do"), ("don't", "dont")):
        if entry.get(field):
            parts.append(f"{label}: {'; '.join(entry[field])}")
    if entry.get("evidence"):
        parts.append(f"evidence: {entry['evidence']}")
    parts += [f"{field}: {', '.join(entry[field])}" for field in ("skills", "formats", "comms") if entry.get(field)]
    judged = [c["text"] for c in entry["when"].get("checks") or [] if c["by"] == "agent"]
    if judged:
        parts.append(f"you judge: {'; '.join(judged)}")
    return _fill(". ".join(parts), fills)


def brief_lines(entries, fills=None) -> list:
    return ["Behaviours this work follows:"] + ["- " + _short(e, fills) for e in entries] if entries else []


# A move or keep is when the behaviour began reaching other items, so it counts as a start
# too; otherwise a behaviour kept from another programme could send back earlier claims.
# An edit changes what the behaviour asks for, so it restarts the start as a file edit does.
def since(entry):
    starts = [h.get("at") for h in entry.get("history") or []
              if isinstance(h, dict) and h.get("event") in ("recorded", "moved", "kept", "edited")]
    return starts[-1] if starts else entry.get("at")


# Same-second or unknown start reads as remind-only: work that may already have passed
# the trigger is never sent back without proof the behaviour came first.
def timing(entry, trigger_at) -> str:
    if trigger_at is None:
        return "before_trigger"
    start, passed = run_record_core.parse_iso(since(entry) or ""), run_record_core.parse_iso(trigger_at)
    return "send_back" if start and passed and start < passed else "remind_only"


def trigger_of(entry) -> str:
    return entry["when"].get("trigger", TRIGGERS[0])


def trigger_times(run_id, key, item) -> dict:
    claims = [r.get("at") for r in programme_journal.claims(run_id)
              if (r.get("payload") or {}).get("item") == key and r.get("at")]
    blocks = [h.get("at") for h in item.get("history") or [] if h.get("kind") in ("waiting", "handed")]
    merged = ((item.get("deliverables") or {}).get("merged") or {}).get("confirmed_at")
    starts = [h.get("at") for h in item.get("history") or [] if h.get("kind") == "started" and h.get("at")]
    return {"claim": min(claims, default=None), "merge": merged, "block": min(blocks, default=None),
            "start": min(starts, default=None)}


def record_delivery(item, bid, reason, via, **extra) -> None:
    item.setdefault("behaviour_deliveries", []).append(
        dict({"id": bid, "reason": reason, "at": run_record_core.now_iso(), "via": via}, **extra))


RECORDED = "behaviour_recorded"
PROPOSED = "behaviour_proposed"
MOVED = "behaviour_moved"
RETIRED = "behaviour_retired"
ENDINGS = ("retired", "undone")
LAYER_WORDS = {"programme": ("programme",), "repo": ("repo",), "personal": ("personal", "global", "all projects")}
_LIST_OPTS = (("do", "do"), ("dont", "dont"), ("skill", "skills"), ("tool", "tools"), ("agent", "agents"),
              ("format", "formats"), ("comm", "comms"))
_FIELD_VALUES = ("when", "trigger", "applies-to", "evidence", "stop", "why", "good", "bad")
_FIELD_MULTI = ("pm-check", "agent-check") + tuple(opt for opt, _ in _LIST_OPTS)
_FIELDS_DOC = ("--when <text> [--trigger claim|merge|block|start] [--pm-check <text>]... [--agent-check <text>]... "
               "[--applies-to pm|workers|both] "
               "[--do <line>]... [--dont <line>]... [--skill <name>]... [--tool <name>]... [--agent <name>]... "
               "[--format <line>]... [--comm <line>]... [--evidence <text>] [--stop <text>] [--good <text>] "
               "[--bad <text>] [--why <text>]")


def _clean(value, what) -> str:
    text = programme_sanitize.clean(value)
    if not text:
        raise ValueError(f"{what} needs a non-empty value")
    return text


def _has_fields(opts) -> bool:
    return any(opts.get(name) for name in _FIELD_VALUES + _FIELD_MULTI)


def _draft(opts, bid, *, when=None, tools=(), do=()) -> dict:
    when_text = opts.get("when") or when
    if not when_text:
        raise ValueError("a behaviour needs --when <text> describing the situation")
    checks = [{"text": _clean(t, "--" + by + "-check"), "by": by}
              for by in CHECK_BY for t in opts.get(by + "-check") or []]
    entry = {"id": bid, "layer": "programme", "applies_to": opts.get("applies-to") or "both", "state": ACTIVE,
             "at": run_record_core.now_iso(), "when": {"text": _clean(when_text, "--when"), "checks": checks}}
    if opts.get("trigger"):
        if opts["trigger"] not in TRIGGERS:
            raise ValueError("--trigger must be one of " + "|".join(TRIGGERS))
        entry["when"]["trigger"] = opts["trigger"]
    for opt, field in _LIST_OPTS:
        rows = [_clean(v, "--" + opt) for v in opts.get(opt) or []]
        if rows:
            entry[field] = rows
    if tools and "tools" not in entry:
        entry["tools"] = list(tools)
    if do and not entry.get("do") and not entry.get("dont"):
        entry["do"] = list(do)
    for field in TEXT_FIELDS:
        if opts.get(field):
            entry[field] = _clean(opts[field], "--" + field)
    examples = {k: _clean(opts[k], "--" + k) for k in ("good", "bad") if opts.get(k)}
    if examples:
        entry["examples"] = examples
    return entry


def _mark(entry, event, prompt=None, **extra) -> dict:
    row = {"event": event, "at": run_record_core.now_iso(), **extra}
    if prompt:
        row["prompt_id"] = prompt["prompt_id"]
    return dict(entry, history=list(entry.get("history") or []) + [row])


def _programme_entry(programme, bid):
    return next((e for e in programme.get("behaviours") or [] if _is(e, bid)), None)


def _stored_rows(loaded) -> list:
    return loaded["personal"] + [e for es in loaded["repos"].values() for e in es]


def _stored_entry(loaded, bid):
    return next((e for e in _stored_rows(loaded) if e["id"] == bid), None)


def _active(programme, loaded) -> list:
    rows = [e for e in _programme_entries(programme, []) if not _held(loaded, e)]
    rows += _stored_rows(loaded)
    rows += _file_rows(loaded)
    return [e for e in rows if e.get("state", ACTIVE) == ACTIVE]


def _file_rows(loaded) -> list:
    return list(loaded.get("shipped") or []) + list(loaded.get("files") or [])


def _overrides(entry, conflicts, known) -> list:
    for other in conflicts:
        if other == entry["id"] or other not in known:
            raise BehaviourError(f"no behaviour {other!r} in force to override")
    return sorted(set(entry.get("overrides") or []) | set(conflicts))


def _editable(programme, bid) -> dict:
    target = _programme_entry(programme, bid)
    if target is None or target.get("state", ACTIVE) != ACTIVE:
        raise BehaviourError(f"no active programme behaviour {bid!r} to edit; a repo, personal or shipped "
                             "behaviour changes through the route its synergy row names")
    return target


def _edit_fields(opts, target) -> dict:
    """The target's fields under the options given, so an edit names only what changes."""
    merged = dict(opts)
    when = target["when"]
    merged.setdefault("when", when["text"])
    if when.get("trigger"):
        merged.setdefault("trigger", when["trigger"])
    merged.setdefault("applies-to", target["applies_to"])
    if not any(opts.get(by + "-check") for by in CHECK_BY):
        for by in CHECK_BY:
            merged[by + "-check"] = [c["text"] for c in when.get("checks") or [] if c.get("by") == by]
    for opt, field in _LIST_OPTS:
        if not opts.get(opt) and target.get(field):
            merged[opt] = list(target[field])
    for field in TEXT_FIELDS:
        if not opts.get(field) and target.get(field):
            merged[field] = target[field]
    for name, text in (target.get("examples") or {}).items():
        merged.setdefault(name, text)
    return merged


def _apply_edit(entry, target, prompt, proposal) -> dict:
    """The checked proposal laid over the target, which keeps its id, start time, history and earlier answers."""
    edited = {k: v for k, v in entry.items() if k not in ("edit_of", "edit_base", "history")}
    for field in ("relates_to", "unrelated"):
        if field in target:
            edited.setdefault(field, target[field])
    edited.update(at=target.get("at", edited.get("at")), state=ACTIVE,
                  overrides=sorted(set(target.get("overrides") or []) | set(entry.get("overrides") or [])),
                  history=list(target.get("history") or []))
    previous = {k: target[k] for k in EDITABLE_FIELDS if k in target}
    return _mark(edited, "edited", prompt, from_proposal=proposal, previous=previous)


def _undo(entry, edited) -> str:
    if edited:
        return (f"the replaced wording is kept as 'previous' on the last 'edited' event of {entry['id']}: "
                f"propose it back with propose-behaviour --edit-of {entry['id']} and apply it on Shawn's typed reply")
    return f"retire-behaviour {entry['id']} --as undone --prompt <id>"


def _edit_view(programme, entry, others) -> tuple:
    """An edit proposal as the check sees it: the edited behaviour itself, against everything else in force."""
    target = _editable(programme, entry["edit_of"]) if entry.get("edit_of") else None
    if not target:
        return entry, others, None
    # The proposal copied the target's fields, so applying it after another edit landed would undo that edit.
    if entry.get("edit_base") != len(target.get("history") or []):
        raise BehaviourError(f"{target['id']!r} changed since this edit was proposed; propose the edit again "
                             "so it starts from the current wording")
    return dict(entry, id=target["id"]), [o for o in others if o["id"] != target["id"]], target


def _from_proposal(programme, prompt, proposal) -> dict:
    entry = _programme_entry(programme, proposal)
    if entry is None or entry.get("state") != "proposed":
        raise BehaviourError(f"no proposed behaviour {proposal!r}")
    load_lib_module("programme_offers_stores").require_bound(prompt, BehaviourError)
    return dict(entry, state=ACTIVE)


def _h_check(host, argv):
    positional, opts = host._parse(argv, values=("run", "from-proposal") + _FIELD_VALUES,
                                   multi=_FIELD_MULTI + ("conflicts-with",))
    proposal = opts.get("from-proposal")
    if positional or (proposal and _has_fields(opts)):
        raise ValueError("usage: check-behaviour " + _FIELDS_DOC + " [--conflicts-with <id>]... [--run <id>], "
                         "or check-behaviour --from-proposal <id> [--conflicts-with <id>]... [--run <id>]")
    run_id, _, record = host._locate(opts)
    programme = programme_home.normalize_programme(record.get("programme") or {})
    found = _programme_entry(programme, proposal) if proposal else None
    if proposal and (found is None or found.get("state") != "proposed"):
        raise BehaviourError(f"no proposed behaviour {proposal!r}")
    entry = dict(found, state=ACTIVE) if proposal else _draft(opts, "bcheck")
    _refuse(entry, verdict(entry, allow_adoption=False))
    others = _active(programme, load_store(host.prompt_lookup))
    entry, others, _ = _edit_view(programme, entry, others)
    _overrides(entry, opts["conflicts-with"], {e["id"] for e in others})
    host._emit({"ok": True, "run": run_id, "kind": "behaviour_checked", "when": entry["when"]["text"],
                **behaviour_report.report(host, dict(record, programme=programme), entry, others, lines=True)})
    return 0


def _h_record(host, argv):
    positional, opts = host._parse(argv, values=("run", "prompt", "from-proposal") + _FIELD_VALUES,
                                   multi=_FIELD_MULTI + ("conflicts-with", "relates-to", "unrelated"))
    proposal = opts.get("from-proposal")
    if positional or (proposal and _has_fields(opts)):
        raise ValueError("usage: record-behaviour --prompt <id> " + _FIELDS_DOC + " [--conflicts-with <id>]... "
                         "[--relates-to <id>]... [--unrelated <id>=<reason>]..., or record-behaviour "
                         "--from-proposal <id> --prompt <id> [--conflicts-with <id>]... [--relates-to <id>]... "
                         "[--unrelated <id>=<reason>]...")
    bid = proposal or "b" + secrets.token_hex(3)
    if not proposal:
        _draft(opts, bid)
    related, unrelated = answers = behaviour_report.answers(opts)

    def change(programme, prompt, rec):
        proposed = _from_proposal(programme, prompt, proposal) if proposal else _draft(opts, bid)
        entry, others, target = _edit_view(programme, proposed, _active(programme, load_store(host.prompt_lookup)))
        entry["overrides"] = _overrides(entry, opts["conflicts-with"], {e["id"] for e in others})
        result = behaviour_report.report(host, rec, entry, others, lines=False, given=answers)
        if related:
            entry["relates_to"] = related
        if unrelated:
            entry["unrelated"] = unrelated
        entry["source"] = load_lib_module("programme_offers_stores").source_of(prompt)
        if target:
            applied = _mark(dict(_programme_entry(programme, proposal), state="retired"), "applied", prompt,
                            edited=target["id"])
            put_programme_entry(programme, applied)
            entry = put_programme_entry(programme, _apply_edit(entry, target, prompt, proposal))
        else:
            entry = put_programme_entry(programme, _mark(entry, "recorded", prompt))
        return {"behaviour": entry["id"], "layer": "programme", "when": entry["when"]["text"],
                "trigger": trigger_of(entry), "checks": entry["when"]["checks"], "overrides": entry["overrides"],
                "from_proposal": proposal, "edited": bool(target), **result,
                "undo": _undo(entry, bool(target))}

    return host._write(opts, change, RECORDED, prompt_id=opts.get("prompt"), needs_prompt=True,
                       verb="record-behaviour", target=bid)


def _term(programme, term_id) -> dict:
    for entry in programme_home.project_terms(programme):
        if entry.get("id") == term_id:
            return entry
    raise BehaviourError(f"no project term {term_id!r}")


def _h_propose(host, argv):
    positional, opts = host._parse(argv, values=("run", "from-term", "edit-of") + _FIELD_VALUES, multi=_FIELD_MULTI)
    if positional or (opts.get("edit-of") and opts.get("from-term")):
        raise ValueError("usage: propose-behaviour " + _FIELDS_DOC + ", or propose-behaviour --from-term <term-id>, "
                         "or propose-behaviour --edit-of <id> with the fields to change")
    bid = "b" + secrets.token_hex(3)

    def change(programme, prompt, rec):
        term = _term(programme, opts["from-term"]) if opts.get("from-term") else None
        if opts.get("edit-of"):
            if not _has_fields(opts):
                raise BehaviourError("an edit proposal needs at least one field to change")
            target = _editable(programme, opts["edit-of"])
            entry = dict(_draft(_edit_fields(opts, target), bid), edit_of=target["id"],
                         edit_base=len(target.get("history") or []))
        elif term:
            area, value = term.get("area"), term.get("value")
            entry = _draft(opts, bid, when=f"choosing a tool for {area}", tools=[value],
                           do=[f"use {value} for {area}"])
        else:
            entry = _draft(opts, bid)
        entry = dict(entry, state="proposed")
        entry = put_programme_entry(programme, _mark(entry, "proposed", **({"from_term": term["id"]} if term else {})))
        return {"behaviour": bid, "state": "proposed", "when": entry["when"]["text"],
                "checks": entry["when"]["checks"], "from_term": term and term["id"],
                "edit_of": entry.get("edit_of")}

    return host._write(opts, change, PROPOSED)


def _check_layer_named(host, prompt, bid, to) -> None:
    options = LAYER_WORDS[to]
    host.require_named(prompt, options, *([bid] if bid else []))
    # require_named looks only at the word just before the name, so "not the repo" would
    # pass it; any negation earlier in the prompt refuses.
    words = host._name_words(programme_journal.named_text(prompt))
    start = min(s for option in options for s, _ in host._runs(words, host._squash(option)))
    if set(words[:start]) & set(host._NEGATIONS):
        raise BehaviourError(f"prompt {prompt['prompt_id']!r} negates the {to} layer; a move needs a plain yes")


def _repo_key(programme, wanted) -> str:
    keys = programme_carryover.repo_keys(programme)
    if wanted:
        if wanted not in keys:
            raise BehaviourError(f"--repo {wanted!r} is not a remit repo; the remit holds {', '.join(keys) or 'none'}")
        return wanted
    if len(keys) != 1:
        raise BehaviourError(f"the remit holds {len(keys)} repos ({', '.join(keys) or 'none'}); "
                             "pass --repo <key> naming one")
    return keys[0]


def _current(programme, loaded, bid) -> tuple:
    stored = _stored_entry(loaded, bid)
    local = _programme_entry(programme, bid)
    entry = stored if stored is not None and (local is None or _held(loaded, local)) else local
    if entry is None or entry.get("state", ACTIVE) != ACTIVE:
        raise BehaviourError(f"no active behaviour {bid!r} to move")
    return entry, local


# An override may only point at a broader layer, or moving it up would let the broader
# entry beat a narrower one. Dropped links are reported so the PM can raise them again.
def _placed(entry, to, key, loaded) -> tuple:
    out = {k: v for k, v in entry.items() if k not in ("adoption", "moved_to", "moved_repo_key", "repo_key", "overrides")}
    out["layer"] = to
    if to == "repo":
        out["repo_key"] = key
    wanted = list(entry.get("overrides") or ())
    broader = ({e["id"] for e in loaded["personal"]}
               | {e["id"] for e in _file_rows(loaded) if e.get("state", ACTIVE) == ACTIVE}) if to == "repo" else set()
    kept = wanted if to == "programme" else [b for b in wanted if b in broader]
    if kept:
        out["overrides"] = kept
    return out, [b for b in wanted if b not in kept]


def _pointer(local, to, key) -> dict:
    out = {k: v for k, v in local.items() if k not in ("moved_to", "moved_repo_key")}
    if to != "programme":
        out["moved_to"] = to
    if to == "repo":
        out["moved_repo_key"] = key
    return out


def _move(host, programme, prompt, rec, bid, to, wanted) -> dict:
    read_store()
    loaded = load_store(host.prompt_lookup)
    entry, local = _current(programme, loaded, bid)
    key = _repo_key(programme, wanted) if to == "repo" else None
    if entry["layer"] == to and entry.get("repo_key") == key:
        raise BehaviourError(f"behaviour {bid!r} is already on the {to} layer")
    placed, dropped = _placed(entry, to, key, loaded)
    moved = _mark(placed, "moved", prompt, **{"from": entry["layer"], "to": to})
    if to == "programme":
        return {"from": entry["layer"], "programme": put_programme_entry(programme, moved), "adopted": None,
                "unstore": entry["layer"] != "programme", "dropped_overrides": dropped}
    adopted = adopt(moved, prompt, rec)
    _refuse(adopted, verdict(adopted))
    if local is not None:
        put_programme_entry(programme, _pointer(local, to, key))
    return {"from": entry["layer"], "adopted": adopted, "unstore": False, "key": key, "dropped_overrides": dropped}


def _unstore(bid) -> None:
    write_store(lambda doc: _without(doc, bid))


# The store write and its rule_adopted rows run after the programme write commits; until
# the store holds a verified copy, resolve keeps the programme copy in force.
def _after_store(seen, how) -> None:
    if seen.get("adopted"):
        store([seen["adopted"]], seen["prompt"], seen["run"], seen["sid"], how)
    if seen.get("unstore"):
        _unstore(seen["bid"])


def _h_move(host, argv):
    positional, opts = host._parse(argv, values=("run", "prompt", "to", "repo"))
    if len(positional) != 1 or opts.get("to") not in MOVE_LAYERS or (opts.get("repo") and opts["to"] != "repo"):
        raise ValueError("usage: move-behaviour <id> --to programme|repo|personal --prompt <id> "
                         "[--repo <key>] (--repo only with --to repo)")
    bid, to = positional[0], opts["to"]
    seen = {"bid": bid}

    def change(programme, prompt, rec):
        _check_layer_named(host, prompt, bid, to)
        out = _move(host, programme, prompt, rec, bid, to, opts.get("repo"))
        seen.update(out, prompt=prompt, run=rec["run_id"], sid=rec.get("driving_session_id"))
        adopted = out["adopted"]
        return {"behaviour": bid, "from": out["from"], "to": to, "repo_key": out.get("key"),
                "target": adopted and target(adopted), "hash": adopted and adopted["adoption"]["hash"],
                "store_path": store_path(), "dropped_overrides": out["dropped_overrides"]}

    return host._write(opts, change, MOVED, prompt_id=opts.get("prompt"), needs_prompt=True,
                       verb="move-behaviour", target=bid, after=lambda _: _after_store(seen, "move"))


def _retire(host, programme, prompt, rec, bid, how) -> dict:
    local = _programme_entry(programme, bid)
    if local is None or local.get("moved_to"):
        read_store()
    stored = _stored_entry(load_store(host.prompt_lookup), bid)
    live = [e for e in (local, stored) if e is not None and e.get("state", ACTIVE) != "retired"]
    if not live:
        raise BehaviourError(f"no behaviour {bid!r} that is not already retired")
    adopted = None
    if local is not None and local.get("state", ACTIVE) != "retired":
        put_programme_entry(programme, _mark(dict(local, state="retired"), how, prompt))
    if stored is not None and stored.get("state", ACTIVE) != "retired":
        bare = {k: v for k, v in stored.items() if k != "adoption"}
        adopted = adopt(_mark(dict(bare, state="retired"), how, prompt), prompt, rec)
    return {"layers": [e["layer"] for e in live], "adopted": adopted}


def _h_retire(host, argv):
    positional, opts = host._parse(argv, values=("run", "prompt", "as"))
    if len(positional) != 1 or opts.get("as") not in ENDINGS:
        raise ValueError("usage: retire-behaviour <id> --as retired|undone --prompt <id>")
    bid, how = positional[0], opts["as"]
    seen = {"bid": bid}

    def change(programme, prompt, rec):
        out = _retire(host, programme, prompt, rec, bid, how)
        seen.update(out, prompt=prompt, run=rec["run_id"], sid=rec.get("driving_session_id"))
        return {"behaviour": bid, "as": how, "layers": out["layers"],
                "target": out["adopted"] and target(out["adopted"])}

    return host._write(opts, change, RETIRED, prompt_id=opts.get("prompt"), needs_prompt=True,
                       verb="retire-behaviour", target=bid, after=lambda _: _after_store(seen, "retire"))


KEPT = "behaviours_kept"


def _keep(host, programme, prompt, rec, wanted, to, repo) -> dict:
    _check_layer_named(host, prompt, None, to)
    read_store()
    loaded = load_store(host.prompt_lookup)
    named = [b for b in wanted if not programme_naming.missing(programme_journal.named_text(prompt), [b])]
    if not named:
        raise BehaviourError(f"prompt {prompt['prompt_id']!r} names none of {', '.join(wanted)}")
    key = _repo_key(programme, repo) if to == "repo" else None
    adopted, dropped = [], {}
    for bid in named:
        local = _programme_entry(programme, bid)
        if local is None or local.get("state", ACTIVE) != ACTIVE:
            raise BehaviourError(f"no active programme-layer behaviour {bid!r} to keep")
        placed, lost = _placed(local, to, key, loaded)
        if lost:
            dropped[bid] = lost
        moved = _mark(placed, "kept", prompt, to=to)
        adopted.append(adopt(moved, prompt, rec))
        _refuse(adopted[-1], verdict(adopted[-1]))
        put_programme_entry(programme, _pointer(local, to, key))
    return {"kept": named, "not_named": [b for b in wanted if b not in named], "adopted": adopted, "key": key,
            "dropped_overrides": dropped}


# Re-running on a kept entry re-adopts it; the store write replaces it by id (_place), so
# a second offer never duplicates an entry.
def _h_keep(host, argv):
    positional, opts = host._parse(argv, values=("run", "prompt", "to", "repo"))
    if not positional or opts.get("to") not in STORED_LAYERS or (opts.get("repo") and opts["to"] != "repo"):
        raise ValueError("usage: keep-behaviours <id>... --to repo|personal --prompt <id> [--repo <key>]")
    wanted, to = list(dict.fromkeys(positional)), opts["to"]
    seen = {}

    def change(programme, prompt, rec):
        out = _keep(host, programme, prompt, rec, wanted, to, opts.get("repo"))
        seen.update(out, prompt=prompt, run=rec["run_id"], sid=rec.get("driving_session_id"))
        return {"kept": out["kept"], "not_named": out["not_named"], "to": to, "repo_key": out["key"],
                "targets": [target(a) for a in out["adopted"]], "store_path": store_path(),
                "dropped_overrides": out["dropped_overrides"]}

    def after(_):
        store(seen["adopted"], seen["prompt"], seen["run"], seen["sid"], "keep")

    return host._write(opts, change, KEPT, prompt_id=opts.get("prompt"), needs_prompt=True,
                       verb="keep-behaviours", target=",".join(wanted), after=after)


REMINDED = "behaviour_reminded"
REASONS = ("relevant", "sent_back")
_OPENERS = {
    ("sent_back", "send_back"): "Your claim is sent back: it does not show what this behaviour asks for. "
                                "Bring the work into line, then claim again.",
    ("relevant", "remind_only"): "This applies from now on. Work you already finished is not sent back.",
}


def _reminder(entry, reason, when, count, cap, fills=None) -> str:
    opener = _OPENERS.get((reason, when), "This applies to your work now.")
    if reason == "sent_back" and count > 1:
        opener += f" This is send-back {count} for this behaviour."
    lines = [f"Behaviour {entry['id']}: {opener}", _short(entry, fills)]
    return programme_sanitize.clean("\n".join(lines), cap, keep_newlines=True)


def _h_remind(host, argv):
    positional, opts = host._parse(argv, values=("run", "reason", "trigger"), multi=("despite",))
    trigger = opts.get("trigger") or "claim"
    if len(positional) != 2 or opts.get("reason") not in REASONS or trigger not in TRIGGERS:
        raise ValueError("usage: remind-behaviour <item> <id> --reason relevant|sent_back "
                         "[--trigger claim|merge|block|start] [--despite <attempt>]...")
    sources = load_lib_module("programme_sources")
    programme_record = load_lib_module("programme_record")
    item_id, bid, reason = programme_record.check_item_id(positional[0]), positional[1], opts["reason"]
    run_id, home, record = host._locate(opts)
    sid = host._guard(home, record)
    programme = programme_home.normalize_programme(record.get("programme") or {})
    key = programme_record._resolve(programme, item_id)
    item = programme["items"][key]
    entry = _for_workers(dict(record, programme=programme), item, bid, host.prompt_lookup)
    passed = trigger_times(run_id, key, item)[trigger]
    when = timing(entry, passed)
    if reason == "sent_back" and when != "send_back":
        raise BehaviourError(f"behaviour {bid!r} cannot send {key!r} back: " + (
            f"the item has not passed its {trigger}" if passed is None else
            f"it started after the item's {trigger} at {passed}; remind only (--reason relevant)"))
    before = [d for d in item.get("behaviour_deliveries") or [] if d.get("id") == bid]
    count = sum(d.get("reason") == "sent_back" for d in before) + (reason == "sent_back")
    facts = {"trigger": trigger, "trigger_at": passed, "timing": when}

    def on_sent(sent_item):
        record_delivery(sent_item, bid, reason, "remind-behaviour", **facts)

    return sources.send_to_item(
        host, opts, (run_id, home, record, sid), programme, key, _reminder(entry, reason, when, count, sources.PROMPT_CAP, fills_for(run_id, key)),
        kind=REMINDED, on_sent=on_sent,
        extra=dict(facts, behaviour=bid, reason=reason, sent_back_count=count,
                   already_reminded=any(d.get("reason") in REASONS for d in before)))


_SPECS = (
    ("record-behaviour", _h_record,
     "--prompt <id> " + _FIELDS_DOC + " [--conflicts-with <id>]... [--relates-to <id>]... "
     "[--unrelated <id>=<reason>]... [--run <id>], or --from-proposal <id> --prompt <id> "
     "[--conflicts-with <id>]... [--relates-to <id>]... [--unrelated <id>=<reason>]... [--run <id>]",
     "no prompt from the driving session; no --when, or neither --do nor --dont; a bad --applies-to; a "
     "do line, skill, tool or agent that names a protected escalation; a --conflicts-with id that is not a "
     "behaviour in force; a --relates-to or --unrelated id that is neither a behaviour in force nor a part of the "
     "contract; an --unrelated with no reason; with --from-proposal, any field option, an id that is not a "
     "proposal, or a prompt that does not answer its offer. Applies at once at the programme layer and "
     "prints the behaviour and contract check beside the checks. The check never refuses."),
    ("check-behaviour", _h_check,
     _FIELDS_DOC + " [--conflicts-with <id>]... [--run <id>], or --from-proposal <id> [--conflicts-with <id>]... "
     "[--run <id>]",
     "no --when, or neither --do nor --dont; a bad --applies-to; a do line, skill, tool or agent that names a "
     "protected escalation; a --conflicts-with id that is not a behaviour in force; with --from-proposal, any "
     "field option or an id that is not a proposal. Reads only: it needs no prompt, records nothing and journals "
     "nothing."),
    ("propose-behaviour", _h_propose,
     _FIELDS_DOC + " [--run <id>], or --from-term <term-id> [--run <id>], or --edit-of <id> <the fields to change> "
     "[--run <id>]",
     "no --when (unless --from-term or --edit-of), or neither --do nor --dont; an unknown project term; a protected "
     "escalation in a do line, skill, tool or agent; with --edit-of, no field to change or a target that is not an "
     "active programme behaviour (a repo, personal or shipped one changes through the route its synergy row "
     "names). Needs no prompt: a proposal applies nothing. An edit proposal copies the target's fields and "
     "replaces the ones given; applying it with record-behaviour --from-proposal replaces the target in place."),
    ("move-behaviour", _h_move,
     "<id> --to programme|repo|personal --prompt <id> [--repo <key>] [--run <id>]",
     "no prompt from the driving session; typed words with no offer that do not name the behaviour id and the "
     "layer (programme, repo, or personal, global or all projects), or hold a negation anywhere before the layer "
     "word; an unreadable behaviours store; a behaviour that is not active; a move to the layer it is on; "
     "--to repo with a remit of several repos and no --repo, or a --repo outside the remit."),
    ("retire-behaviour", _h_retire,
     "<id> --as retired|undone --prompt <id> [--run <id>]",
     "no prompt from the driving session; an unknown or already retired behaviour; an unreadable "
     "behaviours store when the behaviour lives there. The entry stays visible as retired."),
    ("keep-behaviours", _h_keep,
     "<id>... --to repo|personal --prompt <id> [--repo <key>] [--run <id>]",
     "no prompt from the driving session; typed words with no offer that do not name the layer (repo, or personal, "
     "global or all projects) or negate it, or name none of the ids; a named id that is not an active "
     "programme-layer behaviour; an unreadable store; --to repo with several remit repos and no --repo; an ended "
     "programme. A pick of a different set is refused. Ids typed words do not name are listed as not_named."),
    ("remind-behaviour", _h_remind,
     "<item> <id> --reason relevant|sent_back [--trigger claim|merge|block|start] [--despite <attempt>]... [--run <id>]",
     "a session that does not drive the programme; a behaviour not in force for the item's worker (unknown, "
     "retired, overridden or PM-only); --reason sent_back when the item has not passed the trigger (default "
     "claim) or the behaviour started at or after it (remind only); every prompt-item refusal (no owner pane, "
     "a driver or tracker pane, a session mismatch). Sends through the prompt-item path and records the "
     "delivery on the item."),
)


READ_VERBS = ("check-behaviour",)


def build_verbs(host) -> dict:
    return {name: host._Verb(functools.partial(handler, host), args, rejects=rejects, reads=name in READ_VERBS)
            for name, handler, args, rejects in _SPECS}
