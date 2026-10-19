#!/usr/bin/env python3
"""Programme authority: the record, journal and claims of a promoted programme home.

A promoted home keeps its state in ``programme.db``. The record, journal and claims
files beside it are exports, rebuilt after each commit and never read back as state.
A legacy home (JSON only, never promoted) keeps the JSON path until
``programme_import.promote`` moves it.
"""

from __future__ import annotations

import hashlib
import json
import os
import secrets
import sys
import time

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

run_record_core = load_lib_module("run_record_core")
programme_home = load_lib_module("programme_home")
programme_store = load_lib_module("programme_store")

TAG = "projection_of_revision"
MANIFEST = ".exports.json"
IMPORT_MARKER = ".import-in-progress"
JOURNAL_EXPORT = "journal.jsonl"
_REQUESTS = {}
CLAIMS_EXPORT = "claims.jsonl"
RECORD_KIND = "record_updated"
CREATED_KIND = "programme_created"
IMPORT_KIND = "legacy_import"
FOREIGN_KIND = "foreign_write_absorbed"
LEGACY = "legacy_import"
HISTORY = "history"
OUTCOMES = ("absent", "legacy", "supported", "unsupported", "corrupt", "unavailable")
HOLDS = ("unsupported", "corrupt", "unavailable")


class AuthorityError(run_record_core.RunRecordError):
    def __init__(self, message, code="authority_error"):
        super().__init__(message)
        self.code = code


class AuthorityHold(AuthorityError):
    def __init__(self, run_id, outcome, detail):
        super().__init__(f"programme {run_id} authority is {outcome}: {detail}", outcome)
        self.run_id = run_id
        self.outcome = outcome
        self.detail = detail


def _journal():
    return load_lib_module("programme_journal")


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def home_for(repo_root, run_id):
    try:
        home = programme_home.home_path(run_id)
    except programme_home.ProgrammeHomeError:
        return None
    return home if os.path.realpath(repo_root) == os.path.realpath(home) else None


def _tagged(path) -> bool:
    try:
        with open(path) as fh:
            doc = json.load(fh)
    except (OSError, ValueError):
        return False
    return isinstance(doc, dict) and TAG in doc


def promoted(home, run_id) -> bool:
    if any(os.path.lexists(os.path.join(home, name))
           for name in (programme_store.DB_NAME, MANIFEST, IMPORT_MARKER)):
        return True
    return _tagged(run_record_core.run_record_path(home, run_id))


def routes(repo_root, run_id) -> bool:
    home = home_for(repo_root, run_id)
    return home is not None and promoted(home, run_id)


def _guarded(run_id, body):
    try:
        return body()
    except AuthorityError:
        raise
    except programme_store.StoreError as exc:
        if exc.code in HOLDS:
            raise AuthorityHold(run_id, exc.code, str(exc))
        raise AuthorityError(f"programme {run_id}: {exc}", exc.code)


def _open(run_id):
    home = programme_home.home_path(run_id)
    if os.path.lexists(os.path.join(home, IMPORT_MARKER)):
        raise AuthorityHold(run_id, "unavailable", "an import was interrupted; rerun `programme.sh promote`")
    try:
        return programme_store.open_store(run_id)
    except programme_store.StoreAbsent:
        raise AuthorityHold(run_id, "unavailable", "programme.db is missing for a promoted home")
    except programme_store.StoreError as exc:
        raise AuthorityHold(run_id, exc.code if exc.code in HOLDS else "unavailable", str(exc))


def _record_of(run_id, state) -> dict:
    if not isinstance(state, dict) or run_record_core.run_kind(state) != "programme":
        raise AuthorityHold(run_id, "corrupt", "the authority does not hold a programme record")
    return run_record_core._lazy_load("format_compat").upgrade_run_record(json.loads(json.dumps(state)))


def outcome(run_id) -> dict:
    home = programme_home.home_path(run_id)
    try:
        os.stat(home)
    except FileNotFoundError:
        return {"outcome": "absent", "detail": "no programme home"}
    except OSError as exc:
        return {"outcome": "unavailable", "detail": f"programme home unreadable: {exc}"}
    if promoted(home, run_id):
        try:
            read_record(run_id)
        except AuthorityHold as exc:
            return {"outcome": exc.outcome, "detail": exc.detail}
        return {"outcome": "supported", "detail": None}
    if os.path.exists(run_record_core.run_record_path(home, run_id)):
        return {"outcome": "legacy", "detail": None}
    return {"outcome": "absent", "detail": "no programme record"}


def rows_of(events) -> tuple:
    journal, claims, pruned = [], [], set()
    for event in events:
        payload = event.get("payload") or {}
        channel = payload.get("channel")
        if channel in ("journal", "claims") and isinstance(payload.get("row"), dict):
            row = payload["row"]
            (journal if channel == "journal" else claims).append(row)
            if channel == "journal" and row.get("kind") == "prompts_pruned":
                pruned.update((row.get("payload") or {}).get("prompt_ids") or [])
        elif channel == HISTORY:
            journal.extend(dict(r, provenance=LEGACY) for r in payload.get("journal") or [])
            claims.extend(dict(r, provenance=LEGACY) for r in payload.get("claims") or [])
            if isinstance(payload.get("row"), dict):
                journal.append(payload["row"])
    journal = [r for r in journal if not (r.get("kind") == "prompt" and r.get("prompt_id") in pruned)]
    return journal, claims


def snapshot(run_id) -> dict:
    with _open(run_id) as store:
        data = _guarded(run_id, store.read)
    journal, claims = rows_of(data["events"])
    return {"revision": data["revision"], "record": _record_of(run_id, data["state"]),
            "journal": journal, "claims": claims, "events": data["events"]}


def read_record(run_id) -> dict:
    with _open(run_id) as store:
        head = _guarded(run_id, lambda: programme_store.head(store))
    return _record_of(run_id, head["state"])


def head(run_id) -> dict:
    with _open(run_id) as store:
        data = _guarded(run_id, lambda: programme_store.head(store))
    return {"revision": data["revision"], "record": _record_of(run_id, data["state"])}


def journal_rows(run_id) -> list:
    return snapshot(run_id)["journal"]


def claims_rows(run_id) -> list:
    return snapshot(run_id)["claims"]


def _row_event(row, channel) -> dict:
    return {"kind": row["kind"], "payload": {"channel": channel, "row": row}}


def _new_op(prefix) -> str:
    return f"{prefix}-{secrets.token_hex(8)}"


def commit(store, run_id, operation_id, base, state, event, provenance, payload_refs=(), seal=None) -> dict:
    subject = programme_store.commit_subject(state, event, payload_refs)
    admission = programme_store.admit(subject, provenance=provenance, basis="programme write")
    return _guarded(run_id, lambda: store.commit(operation_id, base_revision=base, state=state,
                                                 event=event, admission=admission,
                                                 payload_refs=payload_refs, seal=seal))


def _refuse_sealed(store, run_id) -> None:
    if store.sealed is not None:
        raise AuthorityError(f"programme {run_id} is archived (sealed at revision "
                             f"{store.sealed.get('revision')}); its home is read-only", "sealed")


def sealed_info(run_id):
    """The seal row of an archived programme, or None; a held authority raises AuthorityHold."""
    with _open(run_id) as store:
        return store.sealed


def _locked(home, run_id, body):
    return run_record_core._flock_run(run_record_core.lock_path(home, run_id), body)


def _journal_locked(home, body):
    return run_record_core._flock_run(os.path.join(home, _journal().LOCK_NAME), body)


def bind_request(operation_id, request_digest) -> None:
    _REQUESTS[operation_id] = request_digest


def _replayed(store, run_id, operation_id) -> dict:
    data = _guarded(run_id, store.read)
    hits = [e for e in data["events"] if e["operation_id"] == operation_id]
    saved = (hits[0]["payload"] or {}).get("request") if hits else None
    asked = _REQUESTS.get(operation_id)
    # Rows saved before requests were bound carry no digest; they replay as before.
    if saved is not None and asked is not None and saved != asked:
        raise AuthorityError(f"operation {operation_id} was saved with different input; nothing was "
                             "changed. Use a new --op for a different request", "operation_conflict")
    row = (hits[0]["payload"] or {}).get("row") if hits else None
    return {"result": None, "row": row, "replayed": True, "revision": hits[0]["revision"] if hits else None}


def _legacy_write(home, run_id, change, compose) -> dict:
    seen = {}

    def tracked(record):
        seen["record"] = record
        return change(record)

    result = run_record_core._with_locked_run_record(home, run_id, tracked)
    row = compose(result, seen["record"]) if compose else None
    if row is not None:
        _journal().append_row(run_id, row)
    return {"result": result, "row": row, "replayed": False, "revision": None}


def write(home, run_id, change, compose=None, *, operation_id=None, provenance="derived",
          payload_refs=(), base_revision=None, seal=None) -> dict:
    if not promoted(home, run_id):
        return _legacy_write(home, run_id, change, compose)

    def body():
        with _open(run_id) as store:
            if operation_id is not None and _guarded(run_id, lambda: store.outcome(operation_id)):
                return _replayed(store, run_id, operation_id)
            _refuse_sealed(store, run_id)
            absorb_foreign(store, home, run_id)
            head = _guarded(run_id, lambda: programme_store.head(store))
            record = _record_of(run_id, head["state"])
            result = change(record)
            row = compose(result, record) if compose else None
            run_record_core._prepare_for_write(record)
            event = _row_event(row, "journal") if row is not None else \
                {"kind": RECORD_KIND, "payload": {"channel": "none"}}
            if _REQUESTS.get(operation_id) is not None:
                event["payload"]["request"] = _REQUESTS[operation_id]
            base = head["revision"] if base_revision is None else base_revision
            receipt = commit(store, run_id, operation_id or _new_op("w"), base, record,
                             event, provenance, payload_refs, seal)
        export(home, run_id, final=seal is not None)
        return {"result": result, "row": row, "replayed": receipt["replayed"],
                "revision": receipt["revision"]}

    return _locked(home, run_id, body)


def mutate(home, run_id, change):
    return write(home, run_id, change)["result"]


def append_row(run_id, row, *, channel="journal", provenance="derived", guard=None):
    home = programme_home.home_path(run_id)

    def body():
        with _open(run_id) as store:
            _refuse_sealed(store, run_id)
            absorb_foreign(store, home, run_id)
            head = _guarded(run_id, lambda: programme_store.head(store))
            current = _record_of(run_id, head["state"])
            if guard is not None:
                guard(current)
            built = row(rows_of(_guarded(run_id, store.read)["events"])[0]) if callable(row) else row
            if built is None:
                return None
            commit(store, run_id, _new_op("a"), head["revision"], head["state"],
                   _row_event(built, channel), provenance)
        export(home, run_id)
        return built

    return _locked(home, run_id, body)


def create(home, run_id, record) -> dict:
    try:
        store = programme_store.create(run_id)
    except programme_store.StoreExists:
        raise run_record_core.RunRecordExists(f"programme {run_id} already has an authority")
    except programme_store.StoreError as exc:
        raise AuthorityError(f"programme {run_id}: cannot create its authority: {exc}", exc.code)
    with store:
        run_record_core._prepare_for_write(record)
        commit(store, run_id, "create-" + run_id, 0, record,
               {"kind": CREATED_KIND, "payload": {"channel": "none"}}, "derived")
    export(home, run_id)
    return record


def _render(home, run_id, snap) -> dict:
    record = dict(snap["record"], **{TAG: snap["revision"]})
    return {
        run_record_core.run_record_path(home, run_id): json.dumps(record, indent=2, sort_keys=True) + "\n",
        os.path.join(home, JOURNAL_EXPORT): "".join(json.dumps(r, sort_keys=True) + "\n" for r in snap["journal"]),
        os.path.join(home, CLAIMS_EXPORT): "".join(json.dumps(r, sort_keys=True) + "\n" for r in snap["claims"]),
    }


def _write_text(path, text) -> None:
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    programme_home.atomic_write(path, lambda fh: fh.write(text), ".export.")


def _file_meta(path):
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except OSError:
        return None
    return {"digest": _sha(data), "size": len(data)}


def _sealed_record(record) -> bool:
    return bool(((record.get("programme") or {}).get("archive") or {}).get("sealed_at"))


def _test_pause(point) -> None:
    if run_record_core._test_hatch_enabled("CLAUDE_AUTO_TEST_EXPORT_PAUSE_" + point.upper()):
        print("paused:export_" + point, flush=True)
        time.sleep(60)


def export(home, run_id, *, journal_held=False, final=False) -> bool:
    try:
        snap = snapshot(run_id)
        if _sealed_record(snap["record"]) and not final:
            return False
        files = _render(home, run_id, snap)

        def body():
            manifest = {TAG: snap["revision"], "files": {}, "prior": {}}
            for path, text in files.items():
                rel = os.path.relpath(path, home)
                data = text.encode("utf-8")
                manifest["files"][rel] = {"digest": _sha(data), "size": len(data)}
                current = _file_meta(path)
                if current is not None:
                    manifest["prior"][rel] = current
            _write_text(os.path.join(home, MANIFEST), json.dumps(manifest, sort_keys=True) + "\n")
            for path, text in files.items():
                _write_text(path, text)
                _test_pause("midway")

        if journal_held:
            body()
        else:
            _journal_locked(home, body)
        return True
    except Exception as exc:
        sys.stderr.write(f"programme authority: exports of {run_id} not rebuilt after the commit: {exc}\n")
        return False


def _read_manifest(home):
    try:
        with open(os.path.join(home, MANIFEST)) as fh:
            doc = json.load(fh)
    except (OSError, ValueError):
        return None
    return doc if isinstance(doc, dict) and isinstance(doc.get("files"), dict) else None


def _change_of(path, ours):
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except FileNotFoundError:
        return None
    digest = _sha(data)
    if any(meta.get("digest") == digest for meta in ours):
        return None
    for meta in ours:
        size = meta.get("size")
        if isinstance(size, int) and len(data) > size and _sha(data[:size]) == meta.get("digest"):
            return "appended", data[size:], data
    return "rewritten", None, data


def parse_lines(data: bytes, source: str) -> tuple:
    rows, gaps = [], []
    for number, line in enumerate(data.splitlines(), 1):
        try:
            row = json.loads(line.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            row = None
        if isinstance(row, dict):
            rows.append(row)
        elif line.strip():
            gaps.append({"kind": "unparseable_line", "input": source, "line": number,
                         "digest": _sha(line), "size": len(line)})
    return rows, gaps


def _quarantine(path, revision) -> str:
    aside = f"{path}.foreign-r{revision}-{secrets.token_hex(3)}"
    os.replace(path, aside)
    return aside


def _foreign_findings(home, manifest, revision):
    found = {"journal": [], "claims": [], "gaps": []}
    for rel, meta in sorted(manifest["files"].items()):
        path = os.path.join(home, rel)
        ours = [m for m in (meta, (manifest.get("prior") or {}).get(rel)) if isinstance(m, dict)]
        change = _change_of(path, ours)
        if change is None:
            continue
        how, delta, data = change
        if how == "appended" and rel in (JOURNAL_EXPORT, CLAIMS_EXPORT):
            rows, gaps = parse_lines(delta, rel)
            found["journal" if rel == JOURNAL_EXPORT else "claims"].extend(rows)
            found["gaps"].extend(gaps)
            found["gaps"].append({"kind": "foreign_append", "input": rel, "digest": _sha(delta),
                                  "size": len(delta), "rows": len(rows)})
            continue
        aside = _quarantine(path, revision)
        found["gaps"].append({"kind": "foreign_rewrite", "input": rel, "digest": _sha(data),
                              "size": len(data), "kept_as": os.path.basename(aside)})
    return found


def absorb_foreign(store, home, run_id) -> None:
    manifest = _read_manifest(home)
    if manifest is None or store.sealed is not None:
        return
    head = _guarded(run_id, lambda: programme_store.head(store))
    found = _journal_locked(home, lambda: _foreign_findings(home, manifest, head["revision"]))
    if not (found["journal"] or found["claims"] or found["gaps"]):
        return
    summary = {"kind": FOREIGN_KIND, "at": run_record_core.now_iso(), "session_id": None,
               "payload": {"gaps": found["gaps"],
                           "absorbed": {"journal": len(found["journal"]), "claims": len(found["claims"])}}}
    payload = {"channel": HISTORY, "journal": found["journal"], "claims": found["claims"],
               "gaps": found["gaps"], "row": summary}
    event = {"kind": FOREIGN_KIND, "payload": payload}
    decision = programme_store.admit(programme_store.commit_subject(head["state"], event),
                                     provenance=LEGACY, basis="foreign export write").decision
    if decision != "admitted":
        summary["payload"]["absorbed"] = {"journal": 0, "claims": 0, "refused": decision}
        event = {"kind": FOREIGN_KIND, "payload": dict(payload, journal=[], claims=[])}
    commit(store, run_id, _new_op("f"), head["revision"], head["state"], event, LEGACY)
    sys.stderr.write(f"programme authority: {run_id}: an obsolete writer changed its exports; "
                     f"{len(found['gaps'])} change(s) recorded as {FOREIGN_KIND}\n")
