#!/usr/bin/env python3
"""Promote a legacy JSON programme home into its ``programme.db`` authority.

Promotion holds the leases lock, the run-record lock and the journal lock, in that
order, for its whole run. It freezes an inventory of the record, journal and
claims bytes, admits them for privacy before anything is copied, and commits the
imported state, the imported history, the gaps it found and the import identity
in one transaction. The original files are renamed aside, never deleted.
"""

from __future__ import annotations

import json
import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

run_record_core = load_lib_module("run_record_core")
programme_home = load_lib_module("programme_home")
programme_store = load_lib_module("programme_store")
programme_authority = load_lib_module("programme_authority")

LEGACY = programme_authority.LEGACY
APPROVAL_KINDS = ("agreement_accepted", "term_amended", "instruction_recorded", "instruction_closed",
                  "rule_adopted", "item_reopened", "handed_answered", "remit_set", "item_dropped",
                  "project_term_amended", "rulings_carried")
RESUME_FILE = ".test-resume-import"


class ImportRefused(Exception):
    pass


def _inputs(home, run_id) -> list:
    return [("record", run_record_core.run_record_path(home, run_id)),
            ("journal", os.path.join(home, programme_authority.JOURNAL_EXPORT)),
            ("claims", os.path.join(home, programme_authority.CLAIMS_EXPORT))]


def _read(path):
    try:
        with open(path, "rb") as fh:
            return fh.read()
    except FileNotFoundError:
        return None


def _parse_record(data):
    try:
        record = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        return None
    if not isinstance(record, dict) or run_record_core.run_kind(record) != "programme":
        return None
    return record


def _freeze(home, run_id) -> tuple:
    entries, parsed = [], {}
    for identity, path in _inputs(home, run_id):
        data = _read(path)
        if data is None:
            entries.append(programme_store.inventory_entry(identity, None, parse_result="missing",
                                                           provenance=LEGACY))
            parsed[identity] = None
            continue
        if identity == "record":
            value = _parse_record(data)
            ok = value is not None
        else:
            value = programme_authority.parse_lines(data, identity)
            ok = not value[1]
        parsed[identity] = value
        entries.append(programme_store.inventory_entry(
            identity, data, parse_result="parsed" if ok else "unparseable", provenance=LEGACY))
    return programme_store.freeze_inventory(entries), parsed


def _prompt_ids_in(node, out) -> set:
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "prompt_id" and isinstance(value, str):
                out.add(value)
            else:
                _prompt_ids_in(value, out)
    elif isinstance(node, list):
        for value in node:
            _prompt_ids_in(value, out)
    return out


def _cited(rows) -> set:
    cited = set()
    for row in rows:
        cited.update(c for c in row.get("cites") or [] if isinstance(c, str))
        ref = (row.get("payload") or {}).get("prompt_id")
        if isinstance(ref, str) and row.get("kind") != "prompt":
            cited.add(ref)
    return cited


def _term_explained(rows, key, value) -> bool:
    for row in rows:
        payload = row.get("payload") or {}
        if row.get("kind") == "agreement_proposed" and (payload.get("terms") or {}).get(key) == value:
            return True
        if row.get("kind") == "term_amended" and payload.get("term") == key and payload.get("value") == value:
            return True
    return False


def _record_only(record, rows) -> list:
    gaps = []
    for prompt_id in sorted(_prompt_ids_in(record.get("programme") or {}, set()) - _cited(rows)):
        gaps.append({"kind": "record_only_update", "prompt_id": prompt_id})
    mentioned = {(r.get("payload") or {}).get("item") for r in rows}
    for item_id in sorted(((record.get("programme") or {}).get("items") or {})):
        if item_id not in mentioned:
            gaps.append({"kind": "record_only_update", "item": item_id})
    raised = {(r.get("payload") or {}).get("blocker") for r in rows}
    for blocker in sorted(_context(record).get("blockers") or {}):
        if blocker not in raised:
            gaps.append({"kind": "record_only_update", "blocker": blocker})
    terms = (((record.get("programme") or {}).get("agreement") or {}).get("terms") or {})
    for key, term in sorted(terms.items()):
        if isinstance(term, dict) and term.get("set_by") not in (None, "default") \
                and not _term_explained(rows, key, term.get("value")):
            gaps.append({"kind": "record_only_update", "term": key})
    return gaps


def _context(record) -> dict:
    context = (record.get("programme") or {}).get("context")
    return context if isinstance(context, dict) else {}


def _label_conflicts(rows) -> list:
    prompts = {}
    for row in rows:
        if row.get("kind") == "prompt" and isinstance(row.get("prompt_id"), str):
            payload = row.get("payload") or {}
            prompts.setdefault(row["prompt_id"], set()).add((payload.get("origin"), payload.get("text")))
    gaps = [{"kind": "conflicting_approval_label", "prompt_id": pid}
            for pid, labels in sorted(prompts.items()) if len(labels) > 1]
    for row in rows:
        cites = row.get("cites") or []
        if row.get("kind") in APPROVAL_KINDS and cites and cites[0] in prompts \
                and any(origin not in ("typed", "unknown") for origin, _ in prompts[cites[0]]):
            gaps.append({"kind": "conflicting_approval_label", "prompt_id": cites[0],
                         "approval": row.get("kind")})
    return gaps


def _claims_rows(parsed_claims) -> tuple:
    if parsed_claims is None:
        return [], []
    rows, gaps = parsed_claims
    placed = list(rows)
    for gap in gaps:
        placed.insert(min(gap["line"] - 1, len(placed)), {"kind": "claim_unreadable", "line": gap["line"]})
    return placed, gaps


def _build(run_id, inventory, parsed) -> dict:
    record = parsed["record"]
    if record is None:
        raise ImportRefused("the legacy record is missing, unparseable or not a programme")
    state = run_record_core._lazy_load("format_compat").upgrade_run_record(dict(record))
    state.pop(programme_authority.TAG, None)
    run_record_core._prepare_for_write(state)
    journal, journal_gaps = parsed["journal"] or ([], [])
    claims, claims_gaps = _claims_rows(parsed["claims"])
    gaps = journal_gaps + claims_gaps + _record_only(state, journal) + _label_conflicts(journal)
    summary = {"kind": "legacy_imported", "at": run_record_core.now_iso(), "session_id": None,
               "payload": {"import_id": inventory.import_id, "journal": len(journal),
                           "claims": len(claims), "gaps": len(gaps)}}
    payload = {"channel": programme_authority.HISTORY, "import_id": inventory.import_id,
               "inventory": [dict(e.__dict__) for e in inventory.entries], "journal": journal,
               "claims": claims, "gaps": gaps, "row": summary}
    return {"state": state, "event": {"kind": programme_authority.IMPORT_KIND, "payload": payload}}


def _admission(plan):
    subject = programme_store.commit_subject(plan["state"], plan["event"])
    admission = programme_store.admit(subject, provenance=LEGACY, basis="legacy import")
    if admission.decision == "admitted":
        return admission, []
    payload = plan["event"]["payload"]
    parts = {"record": plan["state"], "journal": payload["journal"], "claims": payload["claims"]}
    blamed = [name for name, part in parts.items()
              if programme_store.admit(part, provenance=LEGACY, basis="legacy import").decision != "admitted"]
    return admission, blamed or ["record", "journal", "claims"]


def _pause_after_freeze(home) -> None:
    if not run_record_core._test_hatch_enabled("CLAUDE_AUTO_TEST_IMPORT_PAUSE_AFTER_FREEZE"):
        return
    resume = os.path.join(home, RESUME_FILE)
    run_record_core.test_pause("after_freeze", resume, poll=0.05)
    try:
        os.unlink(resume)
    except FileNotFoundError:
        pass


def _write_marker(home, import_id) -> None:
    path = os.path.join(home, programme_authority.IMPORT_MARKER)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(fd, (json.dumps({"import_id": import_id}) + "\n").encode("utf-8"))
        os.fsync(fd)
    finally:
        os.close(fd)
    programme_store.fsync_dir(home)


def _marker_id(home):
    try:
        with open(os.path.join(home, programme_authority.IMPORT_MARKER)) as fh:
            return json.load(fh).get("import_id")
    except (OSError, ValueError, AttributeError):
        return None


def _committed_import(run_id, import_id) -> bool:
    try:
        with programme_store.open_store(run_id) as store:
            return bool(import_id) and store.outcome(import_id) is not None
    except programme_store.StoreError:
        return False


def _discard_partial(home, run_id) -> None:
    path = programme_store.db_path(run_id)
    for leftover in (path, path + "-journal"):
        try:
            os.unlink(leftover)
        except FileNotFoundError:
            pass
    os.unlink(os.path.join(home, programme_authority.IMPORT_MARKER))
    programme_store.fsync_dir(home)


def _set_aside(home, run_id, inventory) -> list:
    kept = []
    frozen = {e.identity: e for e in inventory.entries}
    for identity, path in _inputs(home, run_id):
        entry = frozen.get(identity)
        data = _read(path)
        if entry is None or entry.digest is None or data is None:
            continue
        if programme_store.inventory_entry(identity, data, parse_result=entry.parse_result,
                                           provenance=LEGACY) != entry:
            continue
        aside = f"{path}.imported-{inventory.import_id[4:16]}"
        os.replace(path, aside)
        kept.append(os.path.basename(aside))
    programme_store.fsync_dir(home)
    programme_store.fsync_dir(os.path.dirname(run_record_core.run_record_path(home, run_id)))
    return kept


def _inventory_of(run_id, import_id):
    with programme_store.open_store(run_id) as store:
        events = [e for e in store.read()["events"] if e["operation_id"] == import_id]
        revision = store.revision()
    entries = [programme_store.InventoryEntry(**e) for e in events[0]["payload"]["inventory"]]
    return programme_store.check_inventory(programme_store.ImportInventory(import_id, tuple(entries))), revision


def _finish(home, run_id, import_id, status) -> dict:
    inventory, revision = _inventory_of(run_id, import_id)
    if os.path.lexists(os.path.join(home, programme_authority.IMPORT_MARKER)):
        os.unlink(os.path.join(home, programme_authority.IMPORT_MARKER))
        programme_store.fsync_dir(home)
    kept = _set_aside(home, run_id, inventory)
    programme_authority.export(home, run_id, journal_held=True)
    return {"status": status, "import_id": import_id, "revision": revision, "kept_aside": kept}


def _import_event_id(run_id):
    with programme_store.open_store(run_id) as store:
        hits = [e["operation_id"] for e in store.read()["events"]
                if e["kind"] == programme_authority.IMPORT_KIND]
    return hits[0] if hits else None


def _promote_locked(home, run_id) -> dict:
    marker = os.path.join(home, programme_authority.IMPORT_MARKER)
    db = programme_store.db_path(run_id)
    if os.path.lexists(marker):
        pending = _marker_id(home)
        if _committed_import(run_id, pending):
            return _finish(home, run_id, pending, "already_promoted")
        _discard_partial(home, run_id)
    elif os.path.lexists(db):
        imported = _import_event_id(run_id)
        if imported is None:
            return {"status": "already_promoted", "import_id": None,
                    "revision": programme_authority.snapshot(run_id)["revision"], "kept_aside": []}
        return _finish(home, run_id, imported, "already_promoted")
    inventory, parsed = _freeze(home, run_id)
    _pause_after_freeze(home)
    try:
        plan = _build(run_id, inventory, parsed)
    except ImportRefused as exc:
        return {"status": "declined", "import_id": inventory.import_id, "reason": str(exc)}
    admission, blamed = _admission(plan)
    if blamed:
        return {"status": "declined", "import_id": inventory.import_id,
                "reason": f"privacy admission is {admission.decision} for the legacy "
                          f"{', '.join(blamed)}; nothing was copied and the inputs are untouched"}
    changed = programme_store.changed_entries(inventory, _freeze(home, run_id)[0].entries)
    if changed:
        return {"status": "refused", "import_id": inventory.import_id,
                "reason": f"the legacy {', '.join(changed)} changed after the inventory froze; "
                          "rerun promote to import them under a new import identity"}
    _write_marker(home, inventory.import_id)
    with programme_store.create(run_id) as store:
        store.commit(inventory.import_id, base_revision=0, state=plan["state"], event=plan["event"],
                     admission=admission)
    return _finish(home, run_id, inventory.import_id, "promoted")


def _sealed(home, run_id):
    if os.path.lexists(os.path.join(home, programme_authority.IMPORT_MARKER)) \
            or not os.path.lexists(programme_store.db_path(run_id)):
        return None
    try:
        return programme_authority.sealed_info(run_id)
    except programme_authority.AuthorityError:
        return None


def promote(run_id) -> dict:
    run_id = programme_home.check_run_id(run_id)
    home = programme_home.home_path(run_id)
    if not os.path.isdir(home):
        raise programme_home.ProgrammeHomeError(f"no programme home for {run_id}")
    sealed = _sealed(home, run_id)
    if sealed is not None:
        return {"status": "already_promoted", "import_id": None, "revision": sealed.get("revision"),
                "kept_aside": [], "sealed": True}
    lock = run_record_core.lock_path(home, run_id)
    journal_lock = os.path.join(home, load_lib_module("programme_journal").LOCK_NAME)

    def under_record_lock():
        return run_record_core._flock_run(journal_lock, lambda: _promote_locked(home, run_id))

    return programme_home._with_leases_lock(lambda: run_record_core._flock_run(lock, under_record_lock))
