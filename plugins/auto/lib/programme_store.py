#!/usr/bin/env python3
"""The Programme transaction authority: ``<home>/programme.db``, one SQLite file.

Every acknowledged mutation commits its state, its event and its stored outcome
in one transaction under the durable commit policy, and returns a receipt only
after COMMIT returns. Content reaches the database only with an admission that
covers its exact bytes. Callers never write the tables directly.
"""

from __future__ import annotations

import collections
import dataclasses
import datetime
import hashlib
import json
import os
import re
import shutil
import sqlite3
import sys
import tempfile
import time
import urllib.parse

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

run_record_core = load_lib_module("run_record_core")
programme_home = load_lib_module("programme_home")

DB_NAME = "programme.db"
SCHEMA_VERSION = 1
BUSY_TIMEOUT_MS = 5000
SYNC_EXTRA = 3
SYNC_FULL = 2
OUTCOMES = ("absent", "supported", "unsupported", "corrupt", "unavailable")
ADMISSION_DECISIONS = ("admitted", "prohibited", "uncertain")
PROVENANCE_CLASSES = (
    "human_input", "checker_evidence", "worker_result", "derived", "restored", "legacy_import",
)
PARSE_RESULTS = ("parsed", "unparseable", "missing")
MAX_OPERATION_ID = 256
SEAL_KEY = "sealed"
RECOVERY_REQUIRED = "recovery required"

_DIGEST_RE = re.compile(r"^[0-9a-f]{64}$")
_MEDIA_TYPE_RE = re.compile(r"^[a-z0-9][a-z0-9.+-]*/[a-z0-9][a-z0-9.+-]*$")

_SCHEMA = (
    "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
    "CREATE TABLE authority (id INTEGER PRIMARY KEY CHECK (id = 1),"
    " revision INTEGER NOT NULL CHECK (revision >= 0), state TEXT NOT NULL)",
    "CREATE TABLE operations (operation_id TEXT PRIMARY KEY, digest TEXT NOT NULL,"
    " base_revision INTEGER NOT NULL, revision INTEGER NOT NULL UNIQUE, outcome TEXT NOT NULL)",
    "CREATE TABLE events (seq INTEGER PRIMARY KEY AUTOINCREMENT, revision INTEGER NOT NULL,"
    " operation_id TEXT NOT NULL REFERENCES operations(operation_id), kind TEXT NOT NULL,"
    " provenance TEXT NOT NULL, payload TEXT NOT NULL, at TEXT NOT NULL)",
    "CREATE INDEX events_by_operation ON events(operation_id)",
    "CREATE TABLE payload_refs (digest TEXT PRIMARY KEY, size INTEGER NOT NULL CHECK (size >= 0),"
    " media_type TEXT NOT NULL,"
    " first_operation_id TEXT NOT NULL REFERENCES operations(operation_id))",
)
_TABLES = {
    "meta": ("key", "value"),
    "authority": ("id", "revision", "state"),
    "operations": ("operation_id", "digest", "base_revision", "revision", "outcome"),
    "events": ("seq", "revision", "operation_id", "kind", "provenance", "payload", "at"),
    "payload_refs": ("digest", "size", "media_type", "first_operation_id"),
}


class StoreError(Exception):
    code = "store_error"

    def __init__(self, message, code=None):
        super().__init__(message)
        if code:
            self.code = code


class StoreAbsent(StoreError):
    code = "absent"


class StoreUnsupported(StoreError):
    code = "unsupported"


class StoreCorrupt(StoreError):
    code = "corrupt"


class StoreUnavailable(StoreError):
    code = "unavailable"


class StoreExists(StoreError):
    code = "exists"


class OperationConflict(StoreError):
    code = "operation_conflict"


class StaleRevision(StoreError):
    code = "stale_revision"


class AdmissionRefused(StoreError):
    code = "admission_refused"


class PayloadConflict(StoreError):
    code = "payload_conflict"


class InventoryInvalid(StoreError):
    code = "inventory_invalid"


class StoreSealed(StoreError):
    code = "sealed"


def canonical(value) -> str:
    try:
        return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False,
                          allow_nan=False)
    except (TypeError, ValueError) as exc:
        raise StoreError(f"value is not canonical JSON: {type(exc).__name__}", "invalid_input")


def digest_of(value) -> str:
    return hashlib.sha256(canonical(value).encode("utf-8")).hexdigest()


def _now_iso() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _hatch(name: str) -> bool:
    return run_record_core._test_hatch_enabled("CLAUDE_AUTO_TEST_STORE_" + name)


def _fault_pause(point: str) -> None:
    if _hatch("PAUSE_" + point.upper()):
        print("paused:" + point, flush=True)
        time.sleep(60)


@dataclasses.dataclass(frozen=True)
class PayloadRef:
    digest: str
    size: int
    media_type: str

    def __post_init__(self):
        if not isinstance(self.digest, str) or not _DIGEST_RE.match(self.digest):
            raise StoreError("payload reference digest must be sha256 hex", "invalid_reference")
        if not isinstance(self.size, int) or isinstance(self.size, bool) or self.size < 0:
            raise StoreError("payload reference size must be a non-negative int", "invalid_reference")
        if not isinstance(self.media_type, str) or not _MEDIA_TYPE_RE.match(self.media_type):
            raise StoreError("payload reference media type is malformed", "invalid_reference")

    def as_dict(self) -> dict:
        return dataclasses.asdict(self)


def payload_ref_for(data: bytes, media_type: str) -> PayloadRef:
    return PayloadRef(hashlib.sha256(data).hexdigest(), len(data), media_type)


@dataclasses.dataclass(frozen=True)
class Admission:
    decision: str
    subject_digest: str | None
    provenance: str
    basis: str
    reasons: tuple = ()


class _Unclassifiable(Exception):
    pass


def _strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for key, item in value.items():
            if not isinstance(key, str):
                raise _Unclassifiable("non-string key")
            yield key
            yield from _strings(item)
    elif isinstance(value, (list, tuple)):
        for item in value:
            yield from _strings(item)
    elif value is not None and not isinstance(value, (bool, int, float)):
        raise _Unclassifiable(type(value).__name__)


def _secret_values(journal, secrets_path):
    path = os.path.expanduser(secrets_path or os.environ.get(journal.SECRETS_ENV)
                              or journal.DEFAULT_SECRETS_FILE)
    try:
        assignments = journal.secret_assignments(path)
    except FileNotFoundError:
        return []
    except (OSError, UnicodeDecodeError):
        return None
    values = {journal.unquote(value) for _, value in assignments}
    return [v for v in values if len(v) >= journal.MIN_SECRET_LEN]


def _secret_bearing(journal, text, values) -> bool:
    if any(value in text for value in values):
        return True
    if any(p.search(text) for p in journal._TOKEN_PATTERNS):
        return True
    return any(m.group(3) != journal.REDACTED for m in journal._ASSIGNMENT.finditer(text))


def secret_values(secrets_path=None):
    """The secrets-file values admission matches, or None when the file is unreadable."""
    return _secret_values(load_lib_module("programme_journal"), secrets_path)


def secret_bearing(text, values) -> bool:
    return _secret_bearing(load_lib_module("programme_journal"), text, values)


def admit(subject, *, provenance: str, basis: str, secrets_path=None) -> Admission:
    if provenance not in PROVENANCE_CLASSES:
        raise StoreError(f"provenance must be one of {list(PROVENANCE_CLASSES)}", "invalid_admission")
    if not isinstance(basis, str) or not basis:
        raise StoreError("an admission needs a basis", "invalid_admission")
    journal = load_lib_module("programme_journal")
    try:
        strings = list(_strings(subject))
        subject_digest = digest_of(subject)
    except (_Unclassifiable, StoreError) as exc:
        return Admission("uncertain", None, provenance, basis, (f"unclassifiable value: {exc}",))
    values = _secret_values(journal, secrets_path)
    if values is None:
        return Admission("uncertain", subject_digest, provenance, basis, ("secrets file unreadable",))
    if any(_secret_bearing(journal, text, values) for text in strings):
        return Admission("prohibited", subject_digest, provenance, basis, ("secret-bearing content",))
    return Admission("admitted", subject_digest, provenance, basis)


def commit_subject(state, event, payload_refs=()) -> dict:
    return {
        "state": state,
        "event": {"kind": event.get("kind"), "payload": dict(event.get("payload") or {})},
        "payload_refs": [ref.as_dict() for ref in payload_refs],
    }


def _require_admitted(admission, subject) -> None:
    if not isinstance(admission, Admission):
        raise AdmissionRefused("content needs an admission decision before it is saved")
    if admission.decision != "admitted":
        raise AdmissionRefused(f"admission is {admission.decision}; nothing was saved")
    if admission.subject_digest != digest_of(subject):
        raise AdmissionRefused("admission does not cover this content; nothing was saved")


@dataclasses.dataclass(frozen=True)
class InventoryEntry:
    identity: str
    digest: str | None
    size: int | None
    parse_result: str
    provenance: str

    def __post_init__(self):
        if not isinstance(self.identity, str) or not self.identity or "\x00" in self.identity:
            raise InventoryInvalid("inventory identity must be a non-empty string")
        if self.parse_result not in PARSE_RESULTS:
            raise InventoryInvalid(f"parse result must be one of {list(PARSE_RESULTS)}")
        if self.provenance not in PROVENANCE_CLASSES:
            raise InventoryInvalid(f"provenance must be one of {list(PROVENANCE_CLASSES)}")
        missing = self.parse_result == "missing"
        if missing != (self.digest is None) or missing != (self.size is None):
            raise InventoryInvalid(f"{self.identity}: only a missing input lacks digest and size")
        if not missing and (not isinstance(self.digest, str) or not _DIGEST_RE.match(self.digest)):
            raise InventoryInvalid(f"{self.identity}: digest must be sha256 hex")


@dataclasses.dataclass(frozen=True)
class ImportInventory:
    import_id: str
    entries: tuple


def inventory_entry(identity, data, *, parse_result, provenance) -> InventoryEntry:
    if data is None:
        return InventoryEntry(identity, None, None, parse_result, provenance)
    return InventoryEntry(identity, hashlib.sha256(data).hexdigest(), len(data), parse_result, provenance)


def _inventory_id(entries) -> str:
    return "imp-" + digest_of([dataclasses.asdict(e) for e in entries])


def freeze_inventory(entries) -> ImportInventory:
    entries = tuple(entries)
    if not entries:
        raise InventoryInvalid("an import inventory needs at least one input")
    if not all(isinstance(e, InventoryEntry) for e in entries):
        raise InventoryInvalid("inventory entries must be InventoryEntry")
    identities = [e.identity for e in entries]
    if len(set(identities)) != len(identities):
        raise InventoryInvalid("inventory identities must be unique")
    return ImportInventory(_inventory_id(entries), entries)


def check_inventory(inventory) -> ImportInventory:
    if not isinstance(inventory, ImportInventory):
        raise InventoryInvalid("not an import inventory")
    rebuilt = freeze_inventory(inventory.entries)
    if rebuilt.import_id != inventory.import_id:
        raise InventoryInvalid("inventory entries do not match its import identity")
    return inventory


def changed_entries(inventory, current) -> list:
    frozen = {e.identity: e for e in check_inventory(inventory).entries}
    now = {e.identity: e for e in current}
    return sorted(i for i in set(frozen) | set(now) if frozen.get(i) != now.get(i))


def db_path(run_id: str) -> str:
    return os.path.join(programme_home.home_path(run_id), DB_NAME)


def _required_pragmas() -> dict:
    return {"busy_timeout": BUSY_TIMEOUT_MS, "journal_mode": "delete", "synchronous": SYNC_EXTRA,
            "fullfsync": 1, "foreign_keys": 1}


def _apply_pragmas(conn) -> dict:
    required = _required_pragmas()
    applied = dict(required, synchronous=SYNC_FULL) if _hatch("WEAK_SYNC") else required
    for name, value in applied.items():
        conn.execute(f"PRAGMA {name} = {value}").fetchall()
    readback = {name: conn.execute(f"PRAGMA {name}").fetchone()[0] for name in required}
    readback["journal_mode"] = str(readback["journal_mode"]).lower()
    wrong = sorted(n for n in required if readback[n] != required[n])
    if wrong:
        raise StoreUnsupported("durable commit policy not in force: " + ", ".join(
            f"{n}={readback[n]!r} (need {required[n]!r})" for n in wrong))
    return readback


def _classify(exc: sqlite3.Error, doing: str) -> StoreError:
    if isinstance(exc, sqlite3.OperationalError):
        return StoreUnavailable(f"{doing}: {exc}")
    return StoreCorrupt(f"{doing}: {exc}")


def _connect(path: str, mode: str):
    uri = "file:" + urllib.parse.quote(path) + "?mode=" + mode
    old = os.umask(0o077)
    try:
        conn = sqlite3.connect(uri, uri=True, isolation_level=None, timeout=BUSY_TIMEOUT_MS / 1000)
    except sqlite3.Error as exc:
        raise _classify(exc, "opening the programme database")
    finally:
        os.umask(old)
    try:
        return conn, _apply_pragmas(conn)
    except BaseException as exc:
        conn.close()
        if isinstance(exc, sqlite3.Error):
            raise _classify(exc, "configuring the programme database")
        raise


def _validate_schema(conn) -> None:
    names = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
    if "meta" not in names:
        raise StoreCorrupt("programme database has no schema")
    row = conn.execute("SELECT value FROM meta WHERE key = 'schema_version'").fetchone()
    try:
        version = int(row[0])
    except (TypeError, ValueError):
        raise StoreCorrupt("programme database schema version is unreadable")
    if version != SCHEMA_VERSION:
        raise StoreUnsupported(f"programme database schema {version}; this auto reads {SCHEMA_VERSION}")
    for table, columns in _TABLES.items():
        found = tuple(r[1] for r in conn.execute(f"PRAGMA table_info({table})"))
        if found != columns:
            raise StoreCorrupt(f"programme database table {table} does not match schema {version}")
    if conn.execute("SELECT COUNT(*) FROM authority").fetchone()[0] != 1:
        raise StoreCorrupt("programme database has no authority row")


def _fsync_dir(path: str) -> None:
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _home(run_id: str) -> str:
    home = programme_home.home_path(run_id)
    try:
        os.stat(home)
    except FileNotFoundError:
        raise StoreAbsent(f"programme home does not exist: {home}")
    except OSError as exc:
        raise StoreUnavailable(f"programme home unreadable: {exc}")
    return home


def create(run_id: str) -> "Store":
    path = os.path.join(_home(run_id), DB_NAME)
    try:
        os.close(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600))
    except FileExistsError:
        raise StoreExists(f"programme database already exists: {path}")
    except OSError as exc:
        raise StoreUnavailable(f"cannot create programme database: {exc}")
    conn = None
    try:
        conn, pragmas = _connect(path, "rw")
        store = Store(run_id, path, conn, pragmas)
        store._transact(lambda: _initialize(conn, run_id), write=True)
        _fsync_dir(os.path.dirname(path))
        return store
    except BaseException:
        if conn is not None:
            conn.close()
        for leftover in (path, path + "-journal"):
            try:
                os.unlink(leftover)
            except FileNotFoundError:
                pass
        raise


def _seal_row(conn):
    row = conn.execute("SELECT value FROM meta WHERE key = ?", (SEAL_KEY,)).fetchone()
    return None if row is None else json.loads(row[0])


def _seal_after_rollback(path: str):
    # A hot journal on an archive must never be rolled back in place, so the rollback runs on a
    # private copy only to learn whether the state it restores is sealed. The database is copied
    # before the journal: SQLite journals a page before it overwrites it in the database.
    scratch = tempfile.mkdtemp(prefix="auto-seal-probe-")
    try:
        copy = os.path.join(scratch, DB_NAME)
        shutil.copyfile(path, copy)
        try:
            shutil.copyfile(path + "-journal", copy + "-journal")
        except FileNotFoundError:
            pass
        conn = sqlite3.connect("file:" + urllib.parse.quote(copy) + "?mode=rw", uri=True,
                               isolation_level=None)
        try:
            return _seal_row(conn)
        finally:
            conn.close()
    except (OSError, sqlite3.Error, ValueError) as exc:
        raise StoreUnavailable(f"{RECOVERY_REQUIRED}: cannot tell whether the journal belongs to a sealed "
                               f"archive ({exc}); nothing was repaired")
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


def _sealed_reader(run_id, path):
    if os.path.lexists(path + "-journal"):
        if _seal_after_rollback(path) is not None:
            raise StoreUnavailable(f"{RECOVERY_REQUIRED}: the sealed archive has an interrupted journal; "
                                   "it stays read-only and nothing was repaired")
        return None
    try:
        conn = sqlite3.connect("file:" + urllib.parse.quote(path) + "?mode=ro", uri=True,
                               isolation_level=None, timeout=BUSY_TIMEOUT_MS / 1000)
    except sqlite3.Error as exc:
        raise _classify(exc, "opening the programme database")
    try:
        seal = _seal_row(conn)
    except sqlite3.Error:
        conn.close()
        if os.path.lexists(path + "-journal"):
            return _sealed_reader(run_id, path)
        return None
    if seal is None:
        conn.close()
        return None
    try:
        store = Store(run_id, path, conn, _apply_pragmas(conn), seal=seal)
        store._transact(lambda: _validate_schema(conn))
    except BaseException:
        conn.close()
        raise
    return store


def open_store(run_id: str) -> "Store":
    path = os.path.join(_home(run_id), DB_NAME)
    try:
        os.stat(path)
    except FileNotFoundError:
        raise StoreAbsent(f"no programme database in {os.path.dirname(path)}")
    except OSError as exc:
        raise StoreUnavailable(f"programme database unreadable: {exc}")
    sealed = _sealed_reader(run_id, path)
    if sealed is not None:
        return sealed
    conn, pragmas = _connect(path, "rw")
    store = Store(run_id, path, conn, pragmas)
    try:
        store._transact(lambda: _validate_schema(conn))
    except BaseException:
        store.close()
        raise
    return store


def probe(run_id: str) -> dict:
    try:
        open_store(run_id).close()
    except StoreError as exc:
        outcome = exc.code if exc.code in OUTCOMES else "unavailable"
        return {"outcome": outcome, "schema_version": None, "detail": str(exc)}
    except OSError as exc:
        return {"outcome": "unavailable", "schema_version": None, "detail": str(exc)}
    return {"outcome": "supported", "schema_version": SCHEMA_VERSION, "detail": None}


def _check_request(operation_id, base_revision, event) -> dict:
    if not isinstance(operation_id, str) or not 0 < len(operation_id) <= MAX_OPERATION_ID \
            or not operation_id.isprintable():
        raise StoreError("operation id must be a printable string", "invalid_input")
    if not isinstance(base_revision, int) or isinstance(base_revision, bool) or base_revision < 0:
        raise StoreError("base revision must be a non-negative int", "invalid_input")
    if not isinstance(event, dict) or not isinstance(event.get("kind"), str) or not event["kind"]:
        raise StoreError("event needs a kind", "invalid_input")
    if not isinstance(event.get("payload", {}), dict):
        raise StoreError("event payload must be a dict", "invalid_input")
    return {"kind": event["kind"], "payload": dict(event.get("payload") or {})}


def _sealed_replay(store, operation_id, digest) -> dict:
    prior = store.outcome(operation_id)
    if prior is None:
        raise StoreSealed("the programme is sealed; its archive takes no new commits")
    if prior.get("digest") != digest:
        raise OperationConflict(f"operation {operation_id} was saved with different input")
    return dict(prior, replayed=True)


class Store:
    def __init__(self, run_id, path, conn, pragmas, seal=None):
        self.run_id = run_id
        self.path = path
        self.pragmas = dict(pragmas)
        self.sealed = seal
        self._conn = conn

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    def close(self) -> None:
        conn, self._conn = self._conn, None
        if conn is None:
            return
        try:
            if conn.in_transaction:
                conn.execute("ROLLBACK")
        finally:
            conn.close()

    def _db(self):
        if self._conn is None:
            raise StoreError("programme store is closed", "closed")
        return self._conn

    def _rollback(self) -> None:
        conn = self._conn
        if conn is not None and conn.in_transaction:
            try:
                conn.execute("ROLLBACK")
            except sqlite3.Error:
                pass

    def _transact(self, body, *, write=False, faults=False):
        conn = self._db()
        try:
            conn.execute("BEGIN IMMEDIATE" if write else "BEGIN")
        except sqlite3.Error as exc:
            raise _classify(exc, "starting a transaction")
        try:
            result = body()
        except sqlite3.Error as exc:
            self._rollback()
            raise _classify(exc, "inside a transaction")
        except BaseException:
            self._rollback()
            raise
        if faults:
            _fault_pause("before_commit")
        try:
            if faults and _hatch("FAIL_COMMIT"):
                raise sqlite3.OperationalError("disk I/O error (test hatch)")
            conn.execute("COMMIT")
        except sqlite3.Error as exc:
            self._rollback()
            raise StoreUnavailable(f"commit not confirmed, no receipt; read outcome() before retrying: {exc}")
        return result

    def read(self) -> dict:
        return self._transact(lambda: _read(self._db()))

    def commit(self, operation_id, *, base_revision, state, event, admission, payload_refs=(), seal=None):
        event = _check_request(operation_id, base_revision, event)
        refs = tuple(payload_refs)
        if not all(isinstance(ref, PayloadRef) for ref in refs):
            raise StoreError("payload references must be PayloadRef", "invalid_reference")
        subject = commit_subject(state, event, refs)
        _require_admitted(admission, subject)
        request = {"base_revision": base_revision, "subject": subject, **({"seal": seal} if seal else {})}
        if self.sealed is not None:
            return _sealed_replay(self, operation_id, digest_of(request))
        replayed, outcome = self._transact(
            lambda: _apply_sealing(self._db(), operation_id, digest_of(request), base_revision, state,
                                   event, admission.provenance, refs, seal), write=True, faults=True)
        if not replayed:
            _fault_pause("after_commit")
        return dict(outcome, replayed=replayed)

    def revision(self) -> int:
        return self._transact(
            lambda: self._db().execute("SELECT revision FROM authority WHERE id = 1").fetchone()[0])

    def outcome(self, operation_id):
        row = self._transact(lambda: self._db().execute(
            "SELECT outcome FROM operations WHERE operation_id = ?", (operation_id,)).fetchone())
        return None if row is None else json.loads(row[0])

    def payload_refs(self) -> list:
        rows = self._transact(lambda: self._db().execute(
            "SELECT digest, size, media_type FROM payload_refs ORDER BY digest").fetchall())
        return [PayloadRef(*row) for row in rows]

    def check_integrity(self) -> dict:
        conn = self._db()
        integrity = _pragma_rows(conn, "integrity_check")
        if integrity == [["ok"]]:
            integrity = []
        foreign = _pragma_rows(conn, "foreign_key_check")
        try:
            references = self._transact(lambda: _reference_problems(self._db()))
        except StoreError as exc:
            references = [str(exc)]
        return {"integrity": integrity, "foreign_keys": foreign, "references": references,
                "ok": not (integrity or foreign or references)}


def _apply_sealing(conn, operation_id, digest, base_revision, state, event, provenance, refs, seal):
    replayed, outcome = _apply(conn, operation_id, digest, base_revision, state, event, provenance, refs)
    if seal is not None and not replayed:
        conn.execute("INSERT INTO meta (key, value) VALUES (?, ?)",
                     (SEAL_KEY, canonical(dict(seal, revision=outcome["revision"]))))
    return replayed, outcome


def head(store) -> dict:
    def body():
        revision, state = store._db().execute("SELECT revision, state FROM authority WHERE id = 1").fetchone()
        return {"revision": revision, "state": json.loads(state)}
    return store._transact(body)


def _initialize(conn, run_id) -> None:
    for statement in _SCHEMA:
        conn.execute(statement)
    conn.executemany("INSERT INTO meta (key, value) VALUES (?, ?)", [
        ("schema_version", str(SCHEMA_VERSION)), ("run_id", run_id),
        ("created_at", _now_iso())])
    conn.execute("INSERT INTO authority (id, revision, state) VALUES (1, 0, '{}')")


def _apply(conn, operation_id, digest, base_revision, state, event, provenance, refs):
    prior = conn.execute("SELECT digest, outcome FROM operations WHERE operation_id = ?",
                         (operation_id,)).fetchone()
    if prior is not None:
        if prior[0] != digest:
            raise OperationConflict(f"operation {operation_id} was saved with different input")
        return True, json.loads(prior[1])
    if _seal_row(conn) is not None:
        raise StoreSealed("the programme is sealed; its archive takes no new commits")
    current = conn.execute("SELECT revision FROM authority WHERE id = 1").fetchone()[0]
    if current != base_revision:
        raise StaleRevision(f"base revision {base_revision} is stale; authority is at {current}")
    revision = current + 1
    outcome = {"operation_id": operation_id, "digest": digest, "base_revision": base_revision,
               "revision": revision, "payload_refs": [r.digest for r in refs],
               "committed_at": _now_iso()}
    conn.execute("INSERT INTO operations (operation_id, digest, base_revision, revision, outcome)"
                 " VALUES (?, ?, ?, ?, ?)",
                 (operation_id, digest, base_revision, revision, canonical(outcome)))
    _record_refs(conn, operation_id, refs)
    conn.execute("UPDATE authority SET revision = ?, state = ? WHERE id = 1 AND revision = ?",
                 (revision, canonical(state), current))
    conn.execute("INSERT INTO events (revision, operation_id, kind, provenance, payload, at)"
                 " VALUES (?, ?, ?, ?, ?, ?)",
                 (revision, operation_id, event["kind"], provenance,
                  canonical(event["payload"]), outcome["committed_at"]))
    return False, outcome


def _record_refs(conn, operation_id, refs) -> None:
    for ref in refs:
        row = conn.execute("SELECT size, media_type FROM payload_refs WHERE digest = ?",
                           (ref.digest,)).fetchone()
        if row is None:
            conn.execute("INSERT INTO payload_refs (digest, size, media_type, first_operation_id)"
                         " VALUES (?, ?, ?, ?)", (ref.digest, ref.size, ref.media_type, operation_id))
        elif tuple(row) != (ref.size, ref.media_type):
            raise PayloadConflict(f"payload {ref.digest} is already recorded with another size or type")


def _read(conn) -> dict:
    revision, state = conn.execute("SELECT revision, state FROM authority WHERE id = 1").fetchone()
    events = [
        {"seq": r[0], "revision": r[1], "operation_id": r[2], "kind": r[3],
         "provenance": r[4], "payload": json.loads(r[5]), "at": r[6]}
        for r in conn.execute("SELECT seq, revision, operation_id, kind, provenance, payload, at"
                              " FROM events ORDER BY seq")]
    return {"revision": revision, "state": json.loads(state), "events": events}


def _reference_problems(conn) -> list:
    problems = []
    authority = conn.execute("SELECT revision FROM authority WHERE id = 1").fetchone()[0]
    ops = conn.execute("SELECT operation_id, digest, revision, outcome FROM operations"
                       " ORDER BY revision").fetchall()
    events = conn.execute("SELECT operation_id, revision FROM events NOT INDEXED").fetchall()
    refs = {r[0] for r in conn.execute("SELECT digest FROM payload_refs")}
    if [op[2] for op in ops] != list(range(1, len(ops) + 1)):
        problems.append("operation revisions are not contiguous from 1")
    if authority != len(ops):
        problems.append(f"authority revision {authority} but {len(ops)} operations")
    known = {op[0]: op[2] for op in ops}
    per_operation = collections.Counter(e[0] for e in events)
    for operation_id, revision in events:
        if operation_id in known and known[operation_id] != revision:
            problems.append(f"event for {operation_id} names revision {revision}")
    for operation_id, digest, revision, text in ops:
        problems.extend(_outcome_problems(operation_id, digest, revision, text, refs))
        count = per_operation[operation_id]
        if count != 1:
            problems.append(f"operation {operation_id} has {count} events")
    return problems


def _pragma_rows(conn, name) -> list:
    try:
        return [list(row) for row in conn.execute(f"PRAGMA {name}")]
    except sqlite3.DatabaseError as exc:
        return [[f"{name} failed: {exc}"]]


def _outcome_problems(operation_id, digest, revision, text, refs) -> list:
    try:
        outcome = json.loads(text)
    except ValueError:
        return [f"operation {operation_id} outcome is unreadable"]
    problems = []
    if not isinstance(outcome, dict) or (outcome.get("operation_id"), outcome.get("digest"),
                                         outcome.get("revision")) != (operation_id, digest, revision):
        return [f"operation {operation_id} outcome does not match its row"]
    for cited in outcome.get("payload_refs") or []:
        if cited not in refs:
            problems.append(f"operation {operation_id} cites unrecorded payload {cited}")
    return problems
