#!/usr/bin/env python3
"""Carry-over of Rulings from one programme to the next on the same project.

Running programmes never read the store.
"""

from __future__ import annotations

import functools
import json
import os
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
programme_context = load_lib_module("programme_context")
programme_decisions = load_lib_module("programme_decisions")
programme_predicate = load_lib_module("programme_predicate")
session_registry = load_lib_module("session_registry")
driver_session = load_lib_module("driver_session")

pc = programme_context
STORE_PATH_ENV = "CLAUDE_AUTO_CARRYOVER_STORE"
STORE_NAME = "carryover.json"
STORE_LOCK = ".carryover.lock"
STORE_FORMAT = 1
APPROVAL_KIND = "rule_adopted"
OFFER_KEY = programme_predicate.OFFER_KEY
OFFER_ROWS = ("carryover_offered", "programme_ended")
CARRIED_KEYS = ("kind", "effect", "scope", "reason", "limits", "until")


def store_path() -> str:
    override = os.environ.get(STORE_PATH_ENV)
    if override:
        return override
    return os.path.join(os.path.dirname(programme_protocol.personal_path()), STORE_NAME)


def key_of(repo) -> str:
    return repo.get("github") or os.path.normpath(repo["path"])


def repo_keys(programme) -> list:
    keys = []
    for repo in (programme.get("remit") or {}).get("repos") or []:
        if isinstance(repo, dict) and repo.get("path") and key_of(repo) not in keys:
            keys.append(key_of(repo))
    return keys


def target(key, entry_id) -> str:
    return f"carryover:{key}:{entry_id}"


def _read(path):
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except FileNotFoundError:
        return {"format": STORE_FORMAT, "keys": {}}
    if not isinstance(doc, dict) or not isinstance(doc.get("keys"), dict):
        raise ValueError("the carry-over store is not an object with keys")
    return doc


def entries_under(doc, key) -> list:
    rows = doc["keys"].get(key)
    return [e for e in rows if isinstance(e, dict)] if isinstance(rows, list) else []


def read_store() -> dict:
    return _read(store_path())


def _write(update) -> None:
    path = store_path()

    def body():
        doc = _read(path)
        update(doc)
        folder = os.path.dirname(os.path.abspath(path))
        os.makedirs(folder, exist_ok=True)

        def write(fh):
            json.dump(doc, fh, indent=2, sort_keys=True)
            fh.write("\n")

        programme_home.atomic_write(path, write, ".carryover.", folder)

    os.makedirs(programme_home.programmes_dir(), exist_ok=True)
    run_record_core._flock_run(os.path.join(programme_home.programmes_dir(), STORE_LOCK), body)


def offer(programme, now=None) -> list:
    when = run_record_core.parse_iso(now or run_record_core.now_iso())
    return [{"source": "ruling", "id": rid, "kind": ruling["kind"], "effect": ruling.get("effect"),
             "scope": ruling.get("scope"), "items": list(ruling.get("applies_to") or [])}
            for rid, ruling in programme_predicate.active_rulings(programme, when)]


# programme_behaviours loads this module, so it is loaded here only when the offer is made.
def behaviour_offer(programme) -> list:
    behaviours = load_lib_module("programme_behaviours")
    shown = behaviours.shown_programme_entries(programme, behaviours.load_store())
    return [{"source": "behaviour", "id": e["id"], "when": e.get("when"), "do": list(e.get("do") or []),
             "dont": list(e.get("dont") or []), "quote": (e.get("source") or {}).get("quote")}
            for e in shown if e.get("state", behaviours.ACTIVE) == behaviours.ACTIVE]


def offer_lines(entries) -> list:
    rulings = [e for e in entries if e.get("source", "ruling") == "ruling"]
    kept = [e for e in entries if e.get("source") == "behaviour"]
    lines = [f"carry-over offer: Ruling {e['id']} ({e['effect']} {e['kind']} on "
             f"{', '.join(e['items']) or 'nothing'}: {e['scope']})" for e in rulings]
    lines += [f"carry-over offer: behaviour {e['id']} (when {e['when']}: do {'; '.join(e['do']) or '-'}; "
              f"don't {'; '.join(e['dont']) or '-'})" for e in kept]
    if rulings:
        lines.append("Ask Shawn in this one offer which to carry to the next programme on this project, then "
                     "record his pick with carry-rulings --prompt <id> <ruling-id>...")
    if kept:
        lines.append("For each behaviour he keeps, ask repo or global, then run keep-behaviours <id>... "
                     "--to repo|personal --prompt <id> before end")
    return lines


def entry_for(rid, ruling, key, rec) -> dict:
    return dict({k: ruling.get(k) for k in CARRIED_KEYS}, id="k" + secrets.token_hex(3), key=key, ruling=rid,
                quote=ruling.get("quote"), run_id=rec["run_id"], at=run_record_core.now_iso())


def adopt(entry, prompt, rec) -> dict:
    adoption = {"machine": programme_protocol.machine_name(), "run_id": rec["run_id"],
                "prompt_id": prompt["prompt_id"], "quote": programme_journal.redact(prompt["quote"]),
                "prompt_hash": prompt["text_hash"], "hash": programme_protocol.content_hash(entry)}
    return dict(entry, adoption=adoption)


def prepare(entries, prompt, rec) -> list:
    return [adopt(e, prompt, rec) for e in entries]


def summary(adopted) -> list:
    return [{"id": e["id"], "key": e["key"], "ruling": e["ruling"], "hash": e["adoption"]["hash"]}
            for e in adopted]


# Pre-fill verifies an entry only through its approval row, so every stored entry gets one.
def store(adopted, prompt, run_id, session_id, how) -> None:
    def update(doc):
        for entry in adopted:
            kept = [e for e in entries_under(doc, entry["key"]) if e.get("ruling") != entry["ruling"]]
            doc["keys"][entry["key"]] = kept + [entry]

    _write(update)
    for entry in adopted:
        programme_journal.append(
            run_id, APPROVAL_KIND, session_id,
            {"entry": how, "target": target(entry["key"], entry["id"]), "hash": entry["adoption"]["hash"],
             "prompt_id": prompt["prompt_id"], "quote": prompt["quote"]},
            cites=[prompt["prompt_id"]])


def _verified(entry, key, lookup):
    if entry.get("key") != key:
        return "stored under the wrong key"
    try:
        programme_protocol._verify_adoption(entry, lookup, target(key, entry.get("id")), local_only=True,
                                            elsewhere="adopted_on_another_machine")
    except programme_protocol._Reject as exc:
        return exc.reason + (f" ({exc.detail})" if exc.detail else "")
    return None


def _arrive(ctx, entry, key):
    rid = entry.get("ruling")
    revisions = ctx["decisions"].get(rid) if isinstance(rid, str) else None
    # Already here: carried earlier, or from another remit repo's key.
    if revisions and isinstance(revisions[-1], dict) and revisions[-1].get("carried"):
        return None, None
    try:
        pc.check_id(rid, "ruling")
        kind = programme_decisions.check_kind(entry.get("kind"))
    except (pc.ContextError, programme_decisions.DecisionError) as exc:
        return None, f"not a Ruling ({exc})"
    if rid in ctx["decisions"] or rid in ctx["requirements"]:
        return None, f"the id {rid} is taken in this programme"
    if entry.get("effect") not in pc.EFFECTS:
        return None, f"unknown effect {entry.get('effect')!r}"
    if entry.get("until") and run_record_core.parse_iso(entry["until"]) is None:
        return None, f"end date {entry['until']!r} is not ISO UTC time"
    content = {"scope": programme_sanitize.clean(entry.get("scope")), "reason": entry.get("reason"),
               "limits": [programme_sanitize.clean(v) for v in entry.get("limits") or []], "applies_to": [],
               "requirements": [], "kind": kind, "effect": entry["effect"], "until": entry.get("until")}
    # Pending with no items: it binds only when Shawn's typed prompt names the items it now applies to.
    revision = pc._append(ctx["decisions"].setdefault(rid, []), content, None, accept=False, delta=None)
    revision.update(quote=None, baseline=None,
                    carried={"from": key, "entry": entry.get("id"), "run_id": entry.get("run_id"),
                             "quote": programme_sanitize.clean(entry.get("quote"), cap=0)})
    return {"ruling": rid, "kind": kind, "effect": entry["effect"], "origin": key}, None


# Never raises on store content: a bad store must not block set-remit.
def prefill(host, programme) -> tuple:
    try:
        doc = read_store()
        ctx = pc._mutable(programme)
    except (OSError, ValueError, pc.ContextError) as exc:
        return [], [programme_sanitize.clean(f"carry-over store unreadable, nothing carried over: {exc}", cap=0)]
    added, notices, journals = [], [], {}
    for key in repo_keys(programme):
        for entry in entries_under(doc, key):
            reason = _verified(entry, key, lambda run, prompt: host.prompt_lookup(run, prompt, journals))
            if reason is None:
                arrived, reason = _arrive(ctx, entry, key)
                if arrived:
                    added.append(arrived)
            if reason:
                notices.append(programme_sanitize.clean(
                    f"dropped carried-over entry {entry.get('id')} under {key}: {reason}", cap=0))
    return added, notices


def _offer_index(rows, ids):
    for index in range(len(rows) - 1, -1, -1):
        row = rows[index]
        payload = row.get("payload") or {}
        offered = {e.get("id") for e in payload.get("carryover") or [] if isinstance(e, dict)}
        if row.get("kind") in OFFER_ROWS and set(ids) <= offered:
            return index
    return None


def _make_offer(host, opts):
    def change(programme, prompt, rec):
        entries = offer(programme)
        programme[OFFER_KEY] = {"at": run_record_core.now_iso(), "offered": [e["id"] for e in entries]}
        entries += behaviour_offer(programme)
        return {"carryover": entries, "keys": repo_keys(programme), "lines": offer_lines(entries)}

    return host._write(opts, change, "carryover_offered", verb="carry-rulings", target=OFFER_KEY)


def _carry(host, opts, ids):
    run_id, _, rec = host._locate(opts)
    sid = driver_session.driving_session_id()
    if not session_registry.caller_drives(rec, sid):
        raise host.ProgrammeError("only the programme's driving session may carry Rulings over")
    programme = programme_home.normalize_programme(rec.get("programme") or {})
    if programme_home.sealed(programme):
        raise host.ProgrammeError("the programme is archived; nothing more is carried over from it")
    prompt = host._typed_prompt(run_id, rec, opts["prompt"], "carry-rulings")
    host.require_named(prompt, *ids)
    rows = programme_journal.read(run_id)
    offered_at = _offer_index(rows, ids)
    if offered_at is None or offered_at > host.programme_rulings.prompt_index(rows, prompt["prompt_id"]):
        raise host.ProgrammeError(f"prompt {prompt['prompt_id']!r} was not typed after an offer naming "
                                  f"{', '.join(ids)}: run carry-rulings with no ids, show Shawn the offer, then "
                                  "cite the prompt he types")
    keys = repo_keys(programme)
    if not keys:
        raise host.ProgrammeError("the remit names no repo, so there is no project to carry a Ruling to")
    active = dict(programme_predicate.active_rulings(programme, run_record_core.parse_iso(run_record_core.now_iso())))
    missing = [rid for rid in ids if rid not in active]
    if missing:
        raise host.ProgrammeError(f"no active Ruling {', '.join(missing)} in this programme")
    adopted = prepare([entry_for(rid, active[rid], key, rec) for rid in ids for key in keys], prompt, rec)
    store(adopted, prompt, run_id, sid, "carryover")
    payload = {"carried": ids, "keys": keys, "stored": summary(adopted), "store_path": store_path()}
    programme_journal.append(run_id, "rulings_carried", sid, dict(payload, prompt_id=prompt["prompt_id"]),
                             cites=[prompt["prompt_id"]])
    host._emit(dict({"ok": True, "run": run_id, "kind": "rulings_carried"}, **payload))
    return 0


def _h_carry_rulings(host, argv):
    positional, opts = host._parse(argv, values=("run", "prompt"))
    if bool(positional) != bool(opts.get("prompt")):
        raise ValueError("usage: carry-rulings [--run <id>] (make the offer) | carry-rulings --prompt <id> "
                         "<ruling-id>... [--run <id>] (store Shawn's pick)")
    if not positional:
        return _make_offer(host, opts)
    return _carry(host, opts, list(dict.fromkeys(positional)))


_SPECS = (
    ("carry-rulings", _h_carry_rulings, "[--prompt <id> <ruling-id>...] [--run <id>]",
     "with no ids: a caller that is not the driving session or an ended programme; it lists every active "
     "Ruling and every active programme-layer behaviour in one carry-over offer, and records the offer-made "
     "marker that releases the stop. With ids: no typed "
     "prompt from the driving session, one that does not name each id or was typed before an offer naming "
     "them, an id that is not an active Ruling, a remit with no repo, an archived programme; it also runs "
     "after end. Stores each Ruling under every remit repo's key for the next programme on that project."),
)


def build_verbs(host) -> dict:
    return {name: host._Verb(functools.partial(handler, host), args, rejects=rejects)
            for name, handler, args, rejects in _SPECS}
