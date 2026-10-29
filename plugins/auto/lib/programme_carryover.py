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


target = programme_protocol.carryover_target


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
    return [{"source": "ruling", "id": rid, "rev": ruling.get("rev"), "kind": ruling["kind"],
             "effect": ruling.get("effect"), "scope": ruling.get("scope"),
             "items": list(ruling.get("applies_to") or [])}
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


def _put_into(doc, adopted) -> None:
    for entry in adopted:
        kept = [e for e in entries_under(doc, entry["key"]) if e.get("ruling") != entry["ruling"]]
        doc["keys"][entry["key"]] = kept + [entry]


def _put(adopted) -> None:
    _write(lambda doc: _put_into(doc, adopted))


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


def _carried_rows(journals, notices) -> list:
    try:
        names = sorted(os.listdir(programme_home.programmes_dir()))
    except OSError:
        return []
    rows = []
    for run in names:
        try:
            programme_home.check_run_id(run)
            if not os.path.isdir(programme_home.home_path(run)):
                continue
            journals[run] = programme_journal.read(run)
        except programme_home.ProgrammeHomeError:
            continue
        # A held or unreadable home must not block set-remit; its carries wait for the next pre-fill.
        except Exception as exc:
            notices.append(programme_sanitize.clean(f"carry-over rows of {run} unreadable: {exc}", cap=0))
            continue
        rows.extend(r for r in journals[run] if r.get("kind") == "rulings_carried")
    return rows


def _missing(doc, entry) -> bool:
    held = [e for e in entries_under(doc, entry["key"]) if e.get("ruling") == entry.get("ruling")]
    return not any(e.get("id") == entry.get("id") or str(e.get("at") or "") >= str(entry.get("at") or "")
                   for e in held)


# Refills the store from the rulings_carried rows: an entry is written only when it verifies as the store
# entry would, and only when no entry for its Ruling under that key is as new, so a later carry is never
# overwritten and a healed entry is never stored twice. Without ``write`` the refill stays in the returned doc.
def _refill(host, keys, journals, notices, write=True) -> dict:
    def lookup(run, prompt):
        return host.prompt_lookup(run, prompt, journals)

    def update(current):
        for entry in due:
            if _missing(current, entry):
                _put_into(current, [entry])

    doc = read_store()
    due = [e for row in _carried_rows(journals, notices) for e in (row.get("payload") or {}).get("adopted") or []
           if isinstance(e, dict) and e.get("key") in keys and _missing(doc, e)
           and _verified(e, e["key"], lookup) is None]
    if due and write:
        _write(update)
        return read_store()
    update(doc)
    return doc


# Never raises on store content: a bad store must not block set-remit.
def prefill(host, programme, write=True) -> tuple:
    added, notices, journals = [], [], {}
    try:
        doc = _refill(host, repo_keys(programme), journals, notices, write)
        ctx = pc._mutable(programme)
    except (OSError, ValueError, pc.ContextError) as exc:
        return [], [programme_sanitize.clean(f"carry-over store unreadable, nothing carried over: {exc}", cap=0)]
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


def _offer_index(rows, ids, before):
    for index in range(before - 1, -1, -1):
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


def _check_carry(host, run_id, programme, prompt, ids) -> tuple:
    rows = programme_journal.read(run_id)
    index = _offer_index(rows, ids, host.programme_rulings.prompt_index(rows, prompt["prompt_id"]))
    if index is None:
        raise host.ProgrammeError(f"prompt {prompt['prompt_id']!r} was not typed after an offer naming "
                                  f"{', '.join(ids)}: run carry-rulings with no ids, show Shawn the offer, then "
                                  "cite the prompt he types")
    host.programme_rulings.check_newest(rows, prompt["prompt_id"])
    host.programme_rulings.check_prompt_unused(rows, prompt["prompt_id"])
    offered = {e.get("id"): e.get("rev") for e in rows[index]["payload"]["carryover"]
               if isinstance(e, dict) and e.get("source", "ruling") == "ruling"}
    keys = repo_keys(programme)
    if not keys:
        raise host.ProgrammeError("the remit names no repo, so there is no project to carry a Ruling to")
    active = dict(programme_predicate.active_rulings(programme, run_record_core.parse_iso(run_record_core.now_iso())))
    missing = [rid for rid in ids if rid not in active]
    if missing:
        raise host.ProgrammeError(f"no active Ruling {', '.join(missing)} in this programme")
    # An offer without revisions predates this check, so it cannot show which version Shawn picked.
    stale = [rid for rid in ids if offered.get(rid) != active[rid].get("rev")]
    if stale:
        raise host.ProgrammeError(f"Ruling {', '.join(stale)} changed after the offer Shawn answered: run "
                                  "carry-rulings with no ids for a fresh offer, then cite the prompt he types after it")
    return active, keys


# The journal checks, the rulings_carried row and then the store write share the programme's write lock, so a
# concurrent Ruling change or a second use of the prompt waits for this carry and then sees it. That one row
# is also each stored entry's approval and holds the entries it adopted: the store is a cache of those rows,
# which pre-fill refills, so a carry cut off after its row still arrives and a refused carry stores nothing.
def _carry(host, opts, ids):
    run_id, home, _ = host._locate(opts, finish_move=True)
    sid = driver_session.driving_session_id()
    seen = {}

    def mutate(rec):
        if not session_registry.caller_drives(rec, sid):
            raise host.ProgrammeError("only the programme's driving session may carry Rulings over")
        programme = programme_home.normalize_programme(rec.get("programme") or {})
        if programme_home.sealed(programme):
            raise host.ProgrammeError("the programme is archived; nothing more is carried over from it")
        prompt = host._typed_prompt(run_id, rec, opts["prompt"], "carry-rulings")
        host.require_named(prompt, *ids)
        active, keys = _check_carry(host, run_id, programme, prompt, ids)
        adopted = prepare([entry_for(rid, active[rid], key, rec) for rid in ids for key in keys], prompt, rec)
        seen.update(prompt=prompt, adopted=adopted)
        return {"carried": ids, "keys": keys, "stored": summary(adopted), "store_path": store_path()}

    def compose(payload, _):
        return programme_journal.entry("rulings_carried", sid, dict(payload, prompt_id=seen["prompt"]["prompt_id"],
                                                                    adopted=seen["adopted"]),
                                       cites=[seen["prompt"]["prompt_id"]])

    out = host.promoting(run_id, home, "carry-rulings", lambda: host.programme_authority.write(
        home, run_id, mutate, compose, operation_id=host._OPERATION["id"],
        recheck=host.programme_rulings.recheck_approval, legacy_refuses=host.programme_rulings.changes_ruling,
        then=lambda _: _put(seen["adopted"])))
    if out["replayed"]:
        payload = {k: v for k, v in ((out["row"] or {}).get("payload") or {}).items() if k != "adopted"}
        host._emit(dict(payload, ok=True, run=run_id, kind="rulings_carried", replayed=True, revision=out["revision"]))
        return 0
    host._emit(dict({"ok": True, "run": run_id, "kind": "rulings_carried"}, **out["result"]))
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
     "them, a prompt that already approved a Ruling change, a Ruling whose revision changed after that offer "
     "(or an offer that did not record it), an id that is not an active Ruling, a remit with no repo, an "
     "archived programme; it also runs "
     "after end. Stores each Ruling under every remit repo's key for the next programme on that project. With ids, "
     "on a home still on its old JSON files, once every check above passes it moves the home to programme.db and "
     "runs the carry there, checks and all, and refuses, changing nothing, when that move cannot run; a prompt "
     "typed before the move approves nothing."),
)


def build_verbs(host) -> dict:
    return {name: host._Verb(functools.partial(handler, host), args, rejects=rejects)
            for name, handler, args, rejects in _SPECS}
