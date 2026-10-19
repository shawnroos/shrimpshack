#!/usr/bin/env python3
"""Retained worker results and verification sources of a promoted programme home.

Payload bytes live in ``<home>/artifacts/objects`` under their sha256, written once
and never replaced. Privacy admission runs before any byte is staged. A store commit
references an object only after its bytes and directories are synced. Retained
copies are context, never approval: every authority-sensitive use of one refuses
with ``origin_verifier_unavailable`` until a separate origin verifier exists.
"""

from __future__ import annotations

import contextlib
import fcntl
import hashlib
import os
import re
import secrets
import stat
import sys
import time

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

run_record_core = load_lib_module("run_record_core")
programme_home = load_lib_module("programme_home")
programme_store = load_lib_module("programme_store")
programme_authority = load_lib_module("programme_authority")

AREA = "artifacts"
OBJECTS = "objects"
STAGING = "staging"
EXCLUSION_LOCK = ".publish.lock"
RESUME_FILE = ".test-resume-artifact"
# A chosen bound, not measured: results and source extracts are text, not builds.
MAX_PAYLOAD_BYTES = 8 << 20
TEXT_TYPES = ("application/json",)
STATUSES = ("captured", "unavailable", "prohibited", "unsupported", "changed")
NOT_VERIFIED = "origin_verifier_unavailable"
COLLECTED_KIND = "result_collected"
FAILED_KIND = "result_collection_failed"
RETAINED_KIND = "source_retained"
INVENTORY_KIND = "inventory_frozen"
RECEIPT_KIND = "preservation_checked"
_ATTEMPT_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,63}")
_READ_CHUNK = 1 << 16


class ArtifactError(Exception):
    def __init__(self, message, code):
        super().__init__(message)
        self.code = code


def _hatch(name) -> bool:
    return run_record_core._test_hatch_enabled("CLAUDE_AUTO_TEST_ARTIFACT_" + name)


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def area(run_id) -> str:
    return os.path.join(programme_home.home_path(run_id), AREA)


def object_path(run_id, digest) -> str:
    return os.path.join(area(run_id), OBJECTS, digest[:2], digest)


def _fsync_dir(path) -> None:
    if _hatch("FAIL_DIR_SYNC"):
        raise OSError("directory sync failed (test hatch)")
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _require_promoted(run_id) -> str:
    home = programme_home.home_path(run_id)
    if not programme_authority.promoted(home, run_id):
        raise ArtifactError(f"programme {run_id} is not promoted; run `programme.sh promote` first",
                            "not_promoted")
    return home


def sealed(programme) -> bool:
    return bool(((programme or {}).get("archive") or {}).get("sealed_at"))


@contextlib.contextmanager
def publisher(run_id):
    path = os.path.join(programme_home._ensure_dir(area(run_id)), EXCLUSION_LOCK)
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ArtifactError("home writes are excluded (archive in progress); nothing was retained",
                                "home_write_excluded")
        yield
    finally:
        os.close(fd)


def exclude_publishers(run_id, body):
    """For the archive sealer: waits for in-flight publishers, then holds them out while body runs.

    Lock order: leases, then this exclusion, then the run-record lock, then the journal lock.
    """
    path = os.path.join(programme_home._ensure_dir(area(run_id)), EXCLUSION_LOCK)
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        return body()
    finally:
        os.close(fd)


def admit_bytes(data, media_type, *, provenance, basis):
    try:
        programme_store.PayloadRef(_sha(b""), 0, media_type)
    except programme_store.StoreError:
        return programme_store.Admission("uncertain", None, provenance, basis, ("malformed media type",))
    if not (media_type.startswith("text/") or media_type in TEXT_TYPES):
        return programme_store.Admission("uncertain", None, provenance, basis,
                                         ("only text payloads are classifiable",))
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return programme_store.Admission("uncertain", None, provenance, basis, ("not utf-8 text",))
    return programme_store.admit({"media_type": media_type, "text": text},
                                 provenance=provenance, basis=basis)


def _refuse_admission(admission) -> None:
    if admission.decision != "admitted":
        code = "prohibited" if admission.decision == "prohibited" else "unsupported"
        raise ArtifactError(f"privacy admission is {admission.decision}; no bytes were retained", code)


def _write_all(fd, data) -> None:
    if _hatch("SHORT_WRITE"):
        data = data[:max(len(data) - 1, 0)]
    view = memoryview(data)
    while view:
        written = os.write(fd, view)
        if written <= 0:
            raise ArtifactError("write made no progress", "short_write")
        view = view[written:]


def _read_back(path, ref) -> bytes:
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError:
        raise ArtifactError(f"retained object {ref.digest} is missing", "missing")
    except OSError as exc:
        raise ArtifactError(f"retained object {ref.digest} is unreadable: {exc.strerror}", "unreadable")
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise ArtifactError(f"retained object {ref.digest} is not a regular file", "corrupt")
        chunks, total = [], 0
        while total <= ref.size:
            chunk = os.read(fd, _READ_CHUNK)
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
    finally:
        os.close(fd)
    data = b"".join(chunks)
    if len(data) < ref.size:
        raise ArtifactError(f"retained object {ref.digest} is short", "short_write")
    if len(data) != ref.size or _sha(data) != ref.digest:
        raise ArtifactError(f"retained object {ref.digest} does not match its digest", "digest_mismatch")
    return data


def _existing(final, ref) -> None:
    try:
        _read_back(final, ref)
    except ArtifactError as exc:
        raise ArtifactError(f"an object named {ref.digest} already holds other bytes ({exc.code}); "
                            "it is never replaced", "payload_conflict")


def _pause(run_id, point) -> None:
    if not _hatch("PAUSE_" + point.upper()):
        return
    resume = os.path.join(programme_home.home_path(run_id), RESUME_FILE)
    print("paused:artifact_" + point, flush=True)
    for _ in range(600):
        if os.path.exists(resume):
            return
        time.sleep(0.1)


def _stage(run_id, data) -> str:
    staging = programme_home._ensure_dir(os.path.join(area(run_id), STAGING))
    path = os.path.join(staging, f"{secrets.token_hex(8)}.part")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        _write_all(fd, data)
        os.fsync(fd)
    finally:
        os.close(fd)
    _fsync_dir(staging)
    return path


def _place(run_id, staged, ref) -> None:
    final = object_path(run_id, ref.digest)
    folder = programme_home._ensure_dir(os.path.dirname(final))
    programme_home._ensure_dir(os.path.dirname(folder))
    try:
        os.link(staged, final)
    except FileExistsError:
        _existing(final, ref)
    os.unlink(staged)
    for synced in (folder, os.path.dirname(folder), area(run_id), os.path.dirname(staged)):
        _fsync_dir(synced)


def _bound(admission, data):
    if isinstance(admission, programme_store.Admission) and admission.subject_digest == _sha(data):
        return admission
    return programme_store.Admission("uncertain", None, "derived", "unbound admission",
                                     ("the admission is not bound to these bytes",))


def publish(run_id, data, media_type, *, provenance="worker_result", basis="retained payload",
            admission=None):
    """Admits, stages, verifies and publishes bytes; the caller holds ``publisher``.

    A caller that classified the bytes itself (binary or derived content) passes that
    ``admission``; it counts only when its subject digest is the sha256 of ``data``.
    """
    if len(data) > MAX_PAYLOAD_BYTES:
        raise ArtifactError(f"payload is over {MAX_PAYLOAD_BYTES} bytes", "oversized")
    if admission is None:
        admission = admit_bytes(data, media_type, provenance=provenance, basis=basis)
    else:
        admission = _bound(admission, data)
    _refuse_admission(admission)
    ref = programme_store.payload_ref_for(data, media_type)
    final = object_path(run_id, ref.digest)
    if os.path.lexists(final):
        _existing(final, ref)
        try:
            _fsync_dir(os.path.dirname(final))
        except OSError as exc:
            raise ArtifactError(f"syncing {ref.digest} failed: {exc.strerror or exc}", "sync_failed")
        return ref
    try:
        staged = _stage(run_id, data)
        _read_back(staged, ref)
        _place(run_id, staged, ref)
    except OSError as exc:
        raise ArtifactError(f"retaining {ref.digest} failed: {exc.strerror or exc}", "sync_failed")
    return ref


def read_object(run_id, ref) -> bytes:
    return _read_back(object_path(run_id, ref.digest), ref)


def _ref_of(entry):
    ref = entry.get("ref") or {}
    return programme_store.PayloadRef(ref.get("digest"), ref.get("size"), ref.get("media_type"))


def _relative(source) -> list:
    if not isinstance(source, str) or not source or "\x00" in source or os.path.isabs(source):
        raise ArtifactError("a source is a relative path inside --root", "invalid_source")
    parts = source.split("/")
    if any(p in ("", ".", "..") for p in parts):
        raise ArtifactError("a source path may not hold '..', '.' or empty parts", "outside_root")
    return parts


def _lstat(path, code_if_missing="source_missing"):
    try:
        return os.lstat(path)
    except FileNotFoundError:
        raise ArtifactError("the source does not exist", code_if_missing)
    except OSError as exc:
        raise ArtifactError(f"the source is unreadable: {exc.strerror}", "source_unreadable")


def read_source(root, source) -> bytes:
    parts = _relative(source)
    if not isinstance(root, str) or not os.path.isdir(root):
        raise ArtifactError("--root must be a directory", "invalid_source")
    path = os.path.realpath(root)
    for part in parts[:-1]:
        path = os.path.join(path, part)
        if not stat.S_ISDIR(_lstat(path).st_mode):
            raise ArtifactError("a source path crosses a symlink or non-directory", "symlink")
    path = os.path.join(path, parts[-1])
    before = _lstat(path)
    if stat.S_ISLNK(before.st_mode):
        raise ArtifactError("the source is a symlink", "symlink")
    if not stat.S_ISREG(before.st_mode):
        raise ArtifactError("the source is not a regular file", "not_regular")
    if before.st_size > MAX_PAYLOAD_BYTES:
        raise ArtifactError(f"the source is over {MAX_PAYLOAD_BYTES} bytes", "oversized")
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        raise ArtifactError("the source does not exist", "source_missing")
    except OSError as exc:
        code = "symlink" if os.path.islink(path) else "source_unreadable"
        raise ArtifactError(f"the source is unreadable: {exc.strerror}", code)
    try:
        now = os.fstat(fd)
        if (now.st_dev, now.st_ino) != (before.st_dev, before.st_ino):
            raise ArtifactError("the source was replaced while it was read", "symlink")
        chunks, total = [], 0
        while total <= MAX_PAYLOAD_BYTES:
            chunk = os.read(fd, _READ_CHUNK)
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
    finally:
        os.close(fd)
    if total > MAX_PAYLOAD_BYTES:
        raise ArtifactError(f"the source is over {MAX_PAYLOAD_BYTES} bytes", "oversized")
    return b"".join(chunks)


def _retained(programme) -> dict:
    block = programme.setdefault("retained", {})
    for key in ("results", "sources", "inventories", "receipts"):
        block.setdefault(key, {})
    block.setdefault("failures", [])
    return block


def _item_key(programme, item_id):
    items = programme.get("items") or {}
    if item_id in items:
        return item_id
    for key, item in items.items():
        if item_id in (item.get("aliases") or []):
            return key
    raise ArtifactError(f"no item {item_id!r} in this programme", "unknown_item")


def _check_open(programme) -> None:
    if sealed(programme):
        raise ArtifactError("the programme is sealed; its home takes no new writes", "sealed")


def _current(run_id) -> dict:
    record = programme_authority.read_record(run_id)
    return programme_home.normalize_programme(record.get("programme") or {})


def _commit(run_id, home, change, kind, *, refs=(), operation_id=None, provenance="derived"):
    seen = {}

    def mutate(record):
        record["programme"] = programme_home.normalize_programme(record.get("programme") or {})
        _check_open(record["programme"])
        seen["payload"] = change(record["programme"])

    def compose(_, record):
        return load_lib_module("programme_journal").entry(kind, None, seen["payload"])

    out = programme_authority.write(home, run_id, mutate, compose, operation_id=operation_id,
                                    provenance=provenance, payload_refs=refs)
    payload = seen.get("payload") if not out["replayed"] else (out["row"] or {}).get("payload")
    return dict(payload or {}, revision=out["revision"], replayed=out["replayed"])


def _identity_for_record(identity) -> str:
    probe = programme_store.admit({"identity": identity}, provenance="derived", basis="failure identity")
    return identity if probe.decision == "admitted" else "sha256:" + _sha(identity.encode("utf-8"))


def _record_failure(run_id, home, identity, item, attempt, code) -> None:
    entry = {"identity": _identity_for_record(identity), "item": item, "attempt": attempt,
             "code": code, "at": run_record_core.now_iso()}

    def change(programme):
        _retained(programme)["failures"].append(entry)
        return entry

    try:
        _commit(run_id, home, change, FAILED_KIND)
    except (ArtifactError, run_record_core.RunRecordError) as exc:
        sys.stderr.write(f"programme artifacts: the collection failure was not recorded: {exc}\n")


def collect_result(run_id, *, item, attempt, source, root, media_type="text/plain",
                   expect_digest=None, session_id=None, operation_id=None) -> dict:
    home = _require_promoted(run_id)
    if not isinstance(attempt, str) or not _ATTEMPT_RE.fullmatch(attempt):
        raise ArtifactError("--attempt must be a short token", "invalid_source")
    _relative(source)
    key = _item_key(_current(run_id), item)
    identity = f"result:{key}/{attempt}/{source}"
    with publisher(run_id):
        _check_open(_current(run_id))
        try:
            data = read_source(root, source)
            if expect_digest is not None and _sha(data) != expect_digest:
                raise ArtifactError("the source does not match the expected digest", "digest_mismatch")
            ref = publish(run_id, data, media_type, provenance="worker_result", basis="worker result")
        except ArtifactError as exc:
            _record_failure(run_id, home, identity, key, attempt, exc.code)
            raise
        _pause(run_id, "before_commit")

        def change(programme):
            _item_key(programme, key)
            results = _retained(programme)["results"]
            old = results.get(identity) or {}
            entry = {"identity": identity, "item": key, "attempt": attempt, "source": source,
                     "ref": ref.as_dict(), "provenance": "worker_result", "status": "captured",
                     "authorizes": False, "session_id": session_id,
                     "generation": (old.get("generation") or 0) + (old.get("ref") != ref.as_dict()),
                     "collected_at": run_record_core.now_iso()}
            results[identity] = entry
            return {k: entry[k] for k in ("identity", "item", "attempt", "source", "ref", "generation")}

        return _commit(run_id, home, change, COLLECTED_KIND, refs=(ref,), operation_id=operation_id,
                       provenance="worker_result")


def _prompt_extract(row) -> bytes:
    payload = row.get("payload") or {}
    extract = {"prompt_id": row.get("prompt_id"), "text": payload.get("text"),
               "recorded_origin": payload.get("origin"), "session_id": row.get("session_id"),
               "at": row.get("at")}
    return programme_store.canonical(extract).encode("utf-8")


def retain_prompt(run_id, prompt_id, *, operation_id=None) -> dict:
    home = _require_promoted(run_id)
    identity = f"source:prompt:{prompt_id}"
    journal = load_lib_module("programme_journal")
    with publisher(run_id):
        _check_open(_current(run_id))
        try:
            row = journal.find_prompt(run_id, prompt_id)
            if row is None:
                raise ArtifactError("the prompt is not in the journal", "source_missing")
            ref = publish(run_id, _prompt_extract(row), "application/json", provenance="derived",
                          basis="verification source extract")
        except ArtifactError as exc:
            _record_failure(run_id, home, identity, None, None, exc.code)
            raise
        _pause(run_id, "before_commit")

        def change(programme):
            entry = {"identity": identity, "kind": "prompt", "prompt_id": prompt_id,
                     "ref": ref.as_dict(), "recorded_origin": (row.get("payload") or {}).get("origin"),
                     "verification": NOT_VERIFIED, "authorizes": False,
                     "exclusions": ["unrelated conversation"], "retained_at": run_record_core.now_iso()}
            _retained(programme)["sources"][identity] = entry
            return {k: entry[k] for k in ("identity", "ref", "recorded_origin", "verification")}

        return _commit(run_id, home, change, RETAINED_KIND, refs=(ref,), operation_id=operation_id)


def _entry(programme, identity):
    block = _retained(programme)
    entry = block["results"].get(identity) or block["sources"].get(identity)
    if entry is None:
        raise ArtifactError(f"nothing is retained as {identity!r}", "missing")
    return entry


def restore(run_id, identity) -> dict:
    entry = _entry(_current(run_id), identity)
    data = read_object(run_id, _ref_of(entry))
    return {"identity": identity, "bytes": data, "ref": entry["ref"], "authorizes": False,
            "verification": NOT_VERIFIED, "recorded_origin": entry.get("recorded_origin")}


def verify_origin(run_id, identity) -> dict:
    _entry(_current(run_id), identity)
    return {"ok": False, "identity": identity, "reason": NOT_VERIFIED}


def require_authority(run_id, identity, use) -> None:
    """Authority-sensitive use of a retained copy; refuses until an origin verifier exists."""
    verdict = verify_origin(run_id, identity)
    raise ArtifactError(f"{use} cannot rest on retained {identity}: {verdict['reason']}", NOT_VERIFIED)


def _claims_for(run_id, key) -> int:
    rows = load_lib_module("programme_journal").claims(run_id)
    return sum(1 for r in rows if (r.get("payload") or {}).get("item") == key)


def freeze_inventory(run_id, *, owner, required, operation_id=None) -> dict:
    home = _require_promoted(run_id)
    required = list(required)
    if not required or len(set(required)) != len(required) \
            or not all(isinstance(i, str) and i.startswith(("result:", "source:")) for i in required):
        raise ArtifactError("an inventory names unique result: or source: identities", "invalid_inventory")
    key = _item_key(_current(run_id), owner)

    def change(programme):
        claims = _claims_for(run_id, key)
        body = {"owner": key, "required": required, "claims_generation": claims}
        inventory_id = "inv-" + programme_store.digest_of(body)
        inventories = _retained(programme)["inventories"]
        inventories.setdefault(inventory_id, dict(body, id=inventory_id, frozen_at=run_record_core.now_iso()))
        return {"inventory_id": inventory_id, "owner": key, "required": required,
                "claims_generation": claims}

    return _commit(run_id, home, change, INVENTORY_KIND, operation_id=operation_id)


def _failure_status(failures, identity):
    codes = [f.get("code") for f in failures if f.get("identity") == identity]
    if not codes:
        return "unavailable"
    return {"prohibited": "prohibited", "unsupported": "unsupported"}.get(codes[-1], "unavailable")


def _status(run_id, programme, identity) -> dict:
    block = _retained(programme)
    entry = block["results"].get(identity) or block["sources"].get(identity)
    if entry is None:
        return {"identity": identity, "status": _failure_status(block["failures"], identity)}
    try:
        read_object(run_id, _ref_of(entry))
    except (ArtifactError, programme_store.StoreError) as exc:
        return {"identity": identity, "status": "unavailable", "reason": getattr(exc, "code", "invalid")}
    return {"identity": identity, "status": "captured", "digest": entry["ref"]["digest"]}


def _evaluate(run_id, programme, inventory) -> dict:
    entries = [_status(run_id, programme, i) for i in inventory["required"]]
    claims = _claims_for(run_id, inventory["owner"])
    entries.append({"identity": f"claims:{inventory['owner']}",
                    "status": "captured" if claims == inventory["claims_generation"] else "changed",
                    "claims": claims})
    complete = all(e["status"] == "captured" for e in entries)
    return {"inventory_id": inventory["id"], "entries": entries,
            "status": "complete" if complete else "incomplete",
            "objects": sorted(e["digest"] for e in entries if e.get("digest"))}


def check_preservation(run_id, inventory_id, *, operation_id=None) -> dict:
    home = _require_promoted(run_id)
    programme = _current(run_id)
    if inventory_id not in _retained(programme)["inventories"]:
        raise ArtifactError(f"no inventory {inventory_id!r}", "invalid_inventory")
    prior = _retained(programme)["receipts"].get(inventory_id)
    if prior and prior.get("status") == "complete" and operation_id is None:
        return dict(prior, replayed=True, revision=None)

    def change(programme):
        receipts = _retained(programme)["receipts"]
        existing = receipts.get(inventory_id)
        if existing and existing.get("status") == "complete":
            return existing
        receipt = _evaluate(run_id, programme, _retained(programme)["inventories"][inventory_id])
        receipt.update(receipt_id="rcpt-" + programme_store.digest_of(receipt)[:24],
                       checked_at=run_record_core.now_iso())
        receipts[inventory_id] = receipt
        return receipt

    return _commit(run_id, home, change, RECEIPT_KIND, operation_id=operation_id)


def cleanup_allowed(run_id, inventory_id) -> dict:
    programme = _current(run_id)
    block = _retained(programme)
    inventory = block["inventories"].get(inventory_id)
    if inventory is None:
        return {"allowed": False, "reasons": ["no such inventory"]}
    receipt = block["receipts"].get(inventory_id)
    if not receipt or receipt.get("status") != "complete":
        return {"allowed": False, "reasons": ["no complete preservation receipt"]}
    now = _evaluate(run_id, programme, inventory)
    reasons = [f"{e['identity']}: {e['status']}" for e in now["entries"] if e["status"] != "captured"]
    if now["objects"] != receipt.get("objects"):
        reasons.append("retained objects differ from the receipt")
    return {"allowed": not reasons, "reasons": reasons, "receipt_id": receipt.get("receipt_id")}


def protected_prompts(run_id) -> set:
    """Prompt ids that pruning must keep: required by an inventory and not readable when retained."""
    programme = _current(run_id)
    block = _retained(programme)
    keep = set()
    for inventory in block["inventories"].values():
        for identity in inventory.get("required") or []:
            if identity.startswith("source:prompt:") \
                    and _status(run_id, programme, identity)["status"] != "captured":
                keep.add(identity[len("source:prompt:"):])
    return keep


def retained_for_item(programme, key) -> list:
    results = ((programme or {}).get("retained") or {}).get("results") or {}
    return sorted(e["ref"]["digest"] for e in results.values() if e.get("item") == key)


def collect_verb(host, argv) -> int:
    _, opts = host._parse(argv, values=("run", "item", "attempt", "source", "root", "media-type",
                                        "digest"))
    for flag in ("item", "attempt", "source", "root"):
        if not opts.get(flag):
            raise ValueError(f"collect-result needs --{flag}")
    run_id, _, _ = host._locate(opts)
    sid = load_lib_module("driver_session").driving_session_id()
    try:
        out = collect_result(run_id, item=opts["item"], attempt=opts["attempt"], source=opts["source"],
                             root=opts["root"], media_type=opts.get("media-type") or "text/plain",
                             expect_digest=opts.get("digest"), session_id=sid,
                             operation_id=host._OPERATION["id"])
    except ArtifactError as exc:
        host._emit({"ok": False, "run": run_id, "kind": FAILED_KIND, "code": exc.code,
                    "item": opts["item"], "attempt": opts["attempt"], "collected": False})
        return 1
    host._emit({"ok": True, "run": run_id, "kind": COLLECTED_KIND, "collected": True, **out})
    return 0
