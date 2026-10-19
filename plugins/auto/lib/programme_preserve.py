#!/usr/bin/env python3
"""Exact code capture of a worker worktree and an independent restore proof (KTD9).

A capture freezes the worktree's inventory, privacy-scans every object and byte it will
retain, then publishes a self-contained git bundle, separate worktree bytes and a
manifest as immutable artifacts. The verifier rebuilds the code in a fresh repository
from those artifacts alone and compares it with the frozen inventory. The result is a
receipt bound to the source generation; nothing here deletes or changes the source.
"""

from __future__ import annotations

import contextlib
import fcntl
import hashlib
import json
import os
import re
import secrets
import shutil
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
programme_artifacts = load_lib_module("programme_artifacts")
programme_gitio = load_lib_module("programme_gitio")

pa = programme_artifacts
gitio = programme_gitio

AREA = "code"
BUNDLE_TYPE = "application/x-git-bundle"
BYTES_TYPE = "application/octet-stream"
JSON_TYPE = "application/json"
CAPTURED_KIND = "code_captured"
FAILED_KIND = "code_capture_failed"
BUNDLE_HEADER = b"# v2 git bundle\n"
REF_PREFIX = "refs/preserved/"
RESUME_FILE = ".test-resume-preserve"
LFS_POINTER = b"version https://git-lfs.github.com/spec/v1"
_COMPRESSED = (b"\x1f\x8b", b"PK\x03\x04", b"(\xb5/\xfd", b"\xfd7zXZ\x00", b"BZh", b"7z\xbc\xaf\x27\x1c",
               b"\x78\x01", b"\x78\x5e", b"\x78\x9c", b"\x78\xda")
_ASCII_RUN = re.compile(rb"[\x20-\x7e\t\r\n]{4,}")
_ERROR_CODES = {"oversized": "unsupported", "changed": "quiescence_uncertain", "timed_out": "git_failed",
                "git_missing": "git_failed"}


class PreserveError(Exception):
    def __init__(self, message, code):
        super().__init__(message)
        self.code = code


def _hatch(name) -> bool:
    return run_record_core._test_hatch_enabled("CLAUDE_AUTO_TEST_PRESERVE_" + name)


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def admit_binary(data, *, values=None, provenance="worker_result", basis="code bytes scanned"):
    """Privacy admission for bytes that need not be text.

    Valid UTF-8 is scanned as text. Other bytes are scanned as their printable ASCII runs,
    and every secrets-file value is also searched raw in UTF-8 and UTF-16. Compressed bytes
    could hide anything, so they are uncertain rather than admitted.
    """
    digest = _sha(data)
    if values is None:
        values = programme_store.secret_values()
    if values is None:
        return programme_store.Admission("uncertain", digest, provenance, basis, ("secrets file unreadable",))
    for value in values:
        if any(value.encode(enc) in data for enc in ("utf-8", "utf-16-le", "utf-16-be")):
            return programme_store.Admission("prohibited", digest, provenance, basis, ("secret-bearing content",))
    try:
        texts = [data.decode("utf-8")]
    except UnicodeDecodeError:
        if data.startswith(_COMPRESSED):
            return programme_store.Admission("uncertain", digest, provenance, basis,
                                             ("compressed bytes cannot be scanned",))
        texts = [b"\n".join(_ASCII_RUN.findall(data)).decode("ascii")]
    if any(programme_store.secret_bearing(text, values) for text in texts):
        return programme_store.Admission("prohibited", digest, provenance, basis, ("secret-bearing content",))
    return programme_store.Admission("admitted", digest, provenance, basis)


def _admit(data, values, what):
    admission = admit_binary(data, values=values)
    if admission.decision == "prohibited":
        raise PreserveError(f"{what} holds secret-bearing content; nothing was retained", "prohibited")
    if admission.decision != "admitted":
        raise PreserveError(f"{what} cannot be classified ({admission.reasons[0]}); nothing was retained",
                            "unsupported")
    if data.startswith(LFS_POINTER):
        raise PreserveError(f"{what} is an LFS pointer; its payload lives outside the repository", "unsupported")
    return admission


def source_key(top) -> str:
    return "code:" + hashlib.sha256(top.encode("utf-8", "surrogateescape")).hexdigest()[:24]


def _code_dir(run_id) -> str:
    return programme_home._ensure_dir(os.path.join(programme_home._ensure_dir(pa.area(run_id)), AREA))


@contextlib.contextmanager
def _source_lock(run_id, source_id, *, exclusive):
    path = os.path.join(_code_dir(run_id), source_id.split(":", 1)[1] + ".lock")
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        try:
            fcntl.flock(fd, (fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH) | fcntl.LOCK_NB)
        except BlockingIOError:
            raise PreserveError("a capture of this source is running", "capture_in_progress")
        yield
    finally:
        os.close(fd)


def _pause(run_id, point) -> None:
    if not _hatch("PAUSE_" + point.upper()):
        return
    resume = os.path.join(programme_home.home_path(run_id), RESUME_FILE)
    print("paused:preserve_" + point, flush=True)
    for _ in range(600):
        if os.path.exists(resume):
            return
        time.sleep(0.1)


def _code_block(programme) -> dict:
    retained = programme.setdefault("retained", {})
    retained.setdefault("code_failures", [])
    return retained.setdefault("code", {})


def entry_for(run_id, source_id) -> dict:
    entry = _code_block(pa._current(run_id)).get(source_id)
    if entry is None:
        raise PreserveError(f"no code capture for {source_id!r}", "missing")
    return entry


def _summary(entry) -> dict:
    return {k: entry.get(k) for k in ("source_id", "status", "receipt_id", "generation", "reasons")}


def _ref(d) -> object:
    return programme_store.PayloadRef(d["digest"], d["size"], d["media_type"])


def _tips_for_pack(inv) -> list:
    tips = [list(t) for t in inv["tips"]]
    if _hatch("OMIT_DETACHED") and not inv["head"]["symref"]:
        tips = [t for t in tips if t[1] != inv["head"]["oid"]]
    return tips


def _manifest_entries(inv) -> tuple:
    index = [e for e in inv["index"] if not (_hatch("OMIT_STAGES") and e[1] > 0)]
    index_oids = {e[3] for e in inv["index"]}
    entries = []
    for group, items in (("tracked", inv["worktree"]), ("untracked", inv["untracked"]),
                         ("ignored", inv["required_ignored"])):
        if group == "ignored" and _hatch("OMIT_IGNORED"):
            continue
        for e in items:
            src = "pack" if e.get("kind") == "file" and e["oid"] in index_oids else "object"
            entries.append(dict(e, set=group, src=src))
    return index, entries


def _objects(git, top, tips, inv) -> tuple:
    tip_oids = sorted({t[1] for t in tips})
    excluded, prereqs = [], []
    if _hatch("INCREMENTAL") and inv["head"]["oid"]:
        code, out = git.call(top, ["rev-parse", "-q", "--verify", inv["head"]["oid"] + "^"], ok=(0, 1))
        if code == 0:
            prereqs = [out.decode().strip()]
            excluded = ["^" + prereqs[0]]
    reach = gitio.closure(git, top, tip_oids + excluded, ())
    seen = set(reach)
    staged = [e[3] for e in inv["index"] if e[3] not in seen and e[2] != gitio.GITLINK]
    if _hatch("OMIT_STAGED_BLOBS"):
        staged = []
    oids = reach + sorted(set(staged))
    if _hatch("DROP_OBJECT") and reach and reach[-1] not in tip_oids:
        oids.remove(reach[-1])
    return oids, prereqs


def _bundle(tips, prereqs, pack) -> bytes:
    lines = [f"-{oid} \n" for oid in prereqs] + [f"{oid} {REF_PREFIX}{name}\n" for name, oid in tips]
    return BUNDLE_HEADER + "".join(lines).encode("ascii") + b"\n" + pack


def check_bundle(data) -> dict:
    if not data.startswith(BUNDLE_HEADER):
        raise PreserveError("the retained bundle is not a v2 git bundle", "bundle_malformed")
    end = data.find(b"\n\n", len(BUNDLE_HEADER) - 1)
    if end < 0:
        raise PreserveError("the retained bundle has no header end", "bundle_malformed")
    refs = []
    for line in data[len(BUNDLE_HEADER):end].decode("ascii", "replace").splitlines():
        if line.startswith("-"):
            raise PreserveError("the bundle relies on prerequisite commits outside it", "bundle_prerequisites")
        oid, _, name = line.partition(" ")
        refs.append([name, oid])
    return {"refs": refs, "pack_offset": end + 2}


def _scan_objects(git, top, oids, values) -> int:
    count = 0
    for oid, kind, data in gitio.read_objects(git, top, oids):
        _admit(data, values, f"git {kind} object")
        count += 1
    return count


def _file_payloads(top, entries, values) -> dict:
    payloads, cache = {}, {}
    root = os.fsencode(top)
    for e in entries:
        if e["kind"] != "file" or e["src"] != "object":
            continue
        now = gitio.worktree_entry(root, bytes.fromhex(e["p"]), cache)
        if now != {k: v for k, v in e.items() if k not in ("set", "src")}:
            raise PreserveError("a worktree file changed during capture", "quiescence_uncertain")
        path, st = gitio._inside(root, bytes.fromhex(e["p"]))
        data = gitio.read_file(path, st)
        if _sha(data) != e["sha256"]:
            raise PreserveError("a worktree file changed during capture", "quiescence_uncertain")
        payloads[e["sha256"]] = (data, _admit(data, values, "a worktree file"))
    return payloads


def _admit_names(inv, tips, values) -> None:
    names = [bytes.fromhex(e[0]) for e in inv["index"]] + [bytes.fromhex(p) for p in inv["ignored"]]
    for e in inv["worktree"] + inv["untracked"] + inv["required_ignored"]:
        names.append(bytes.fromhex(e["p"]))
        if e.get("target"):
            names.append(bytes.fromhex(e["target"]))
    names += [name.encode() for name, _ in tips]
    _admit(b"\n".join(names), values, "a path name or symlink target")


def _check_inventory(inv) -> None:
    if inv["problems"]:
        raise PreserveError("the source holds content this version cannot capture: "
                            + "; ".join(sorted(set(inv["problems"]))), "unsupported")
    if inv["quiescence"]:
        raise PreserveError("git lock files show a writer may be active", "quiescence_uncertain")


def _json_payload(value, what):
    data = programme_store.canonical(value).encode("utf-8")
    admission = pa.admit_bytes(data, JSON_TYPE, provenance="worker_result", basis=what)
    if admission.decision != "admitted":
        raise PreserveError(f"the {what} is not admissible ({admission.decision})",
                            "prohibited" if admission.decision == "prohibited" else "unsupported")
    return data


def _prepare(top, inv) -> dict:
    """Builds and admits everything a capture will retain; nothing is written yet."""
    values = programme_store.secret_values()
    if values is None:
        raise PreserveError("the secrets file is unreadable, so admission is uncertain", "unsupported")
    tips = _tips_for_pack(inv)
    index, entries = _manifest_entries(inv)
    with gitio.Git(os.path.dirname(top)) as git:
        oids, prereqs = _objects(git, top, tips, inv)
        scanned = _scan_objects(git, top, oids, values)
        bundle = _bundle(tips, prereqs, gitio.pack(git, top, oids))
        git_binary = git.binary
    _admit_names(inv, tips, values)
    files = _file_payloads(top, entries, values)
    bundle_admission = programme_store.Admission("admitted", _sha(bundle), "worker_result",
                                                 f"{scanned} git objects scanned before packing")
    inventory = _json_payload(inv, "code inventory")
    manifest = {"format": 1, "generation": gitio.digest(inv), "head": inv["head"],
                "refs": [[REF_PREFIX + n, o] for n, o in tips], "index": index, "worktree": entries,
                "bundle": programme_store.payload_ref_for(bundle, BUNDLE_TYPE).as_dict(), "git": git_binary}
    return {"bundle": (bundle, bundle_admission), "files": files, "inventory": inventory,
            "manifest": _json_payload(manifest, "code manifest")}


def _publish_all(run_id, prepared) -> dict:
    refs = {"bundle": pa.publish(run_id, prepared["bundle"][0], BUNDLE_TYPE, admission=prepared["bundle"][1])}
    refs["files"] = [pa.publish(run_id, data, BYTES_TYPE, admission=adm)
                     for data, adm in prepared["files"].values()]
    for key in ("inventory", "manifest"):
        refs[key] = pa.publish(run_id, prepared[key], JSON_TYPE, basis="code " + key)
    return refs


def _error_code(exc) -> str:
    return _ERROR_CODES.get(exc.code, exc.code)


def _record_failure(run_id, home, source_id, code) -> None:
    def change(programme):
        block = _code_block(programme)
        failure = {"source_id": source_id, "code": code, "at": run_record_core.now_iso()}
        programme["retained"]["code_failures"].append(failure)
        if source_id in block:
            block[source_id].update(status="incomplete", reasons=[code])
        return failure

    try:
        pa._commit(run_id, home, change, FAILED_KIND)
    except (pa.ArtifactError, run_record_core.RunRecordError) as exc:
        sys.stderr.write(f"programme preserve: the capture failure was not recorded: {exc}\n")


def _replay(run_id, operation_id):
    if operation_id is None:
        return None
    for entry in _code_block(pa._current(run_id)).values():
        if entry.get("operation_id") == operation_id:
            return dict(_summary(entry), replayed=True, revision=None, mismatches=[])
    return None


def capture(run_id, path, *, extras=(), include_ignored=(), operation_id=None) -> dict:
    try:
        home = pa._require_promoted(run_id)
    except pa.ArtifactError as exc:
        raise PreserveError(str(exc), exc.code)
    prior = _replay(run_id, operation_id)
    if prior is not None:
        return prior
    top = os.path.realpath(path)
    source_id = source_key(top)
    with _source_lock(run_id, source_id, exclusive=True):
        try:
            with pa.publisher(run_id):
                pa._check_open(pa._current(run_id))
                return _capture_locked(run_id, home, top, source_id, list(extras), list(include_ignored),
                                       operation_id)
        except (gitio.GitError, pa.ArtifactError) as exc:
            failure = PreserveError(str(exc), _error_code(exc))
        except PreserveError as exc:
            failure = exc
        _record_failure(run_id, home, source_id, failure.code)
        raise failure


def _capture_locked(run_id, home, top, source_id, extras, include_ignored, operation_id) -> dict:
    inv = gitio.scan(top, extras=extras, include_ignored=include_ignored)
    _check_inventory(inv)
    prepared = _prepare(top, inv)
    refs = _publish_all(run_id, prepared)
    _pause(run_id, "before_rescan")
    if gitio.digest(gitio.scan(top, extras=extras, include_ignored=include_ignored)) != gitio.digest(inv):
        raise PreserveError("the source changed during capture", "quiescence_uncertain")
    stored = {"manifest": refs["manifest"].as_dict(), "bundle": refs["bundle"].as_dict(),
              "inventory": refs["inventory"].as_dict()}
    report = _verify_stored(run_id, stored, inv)
    all_refs = [refs["bundle"], refs["inventory"], refs["manifest"]] + refs["files"]
    entry = dict(stored, files=[r.as_dict() for r in refs["files"]], source_id=source_id, top=top, identity=inv["identity"], generation=gitio.digest(inv),
                 extras=extras, include_ignored=include_ignored, objects=sorted({r.digest for r in all_refs}),
                 status="complete" if report["ok"] else "incomplete", reasons=report["reasons"],
                 lost_reflog=inv["lost_reflog"], operation_id=operation_id, authorizes=False,
                 captured_at=run_record_core.now_iso())
    entry["receipt_id"] = "code-" + programme_store.digest_of(
        {k: entry[k] for k in ("source_id", "generation", "objects", "status")})[:24]

    def change(programme):
        _code_block(programme)[source_id] = entry
        return _summary(entry)

    out = pa._commit(run_id, home, change, CAPTURED_KIND, refs=tuple(all_refs), operation_id=operation_id,
                     provenance="worker_result")
    return dict(out, mismatches=report["mismatches"])


def _ensure_parent(dest: bytes, rel: bytes) -> bytes:
    path = dest
    for part in rel.split(b"/")[:-1]:
        path = os.path.join(path, part)
        st = gitio._lstat(path)
        if st is None:
            os.mkdir(path, 0o755)
        elif not stat.S_ISDIR(st.st_mode):
            return None
    return os.path.join(path, rel.split(b"/")[-1])


def _write_entry(path, entry, data) -> None:
    if entry["kind"] == "link":
        os.symlink(bytes.fromhex(entry["target"]), path)
        return
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        pa._write_all(fd, data)
        os.fchmod(fd, 0o755 if entry.get("x") else 0o644)
    finally:
        os.close(fd)


def _restore_worktree(run_id, git, dest, entries) -> list:
    problems = []
    wanted = sorted({e["oid"] for e in entries if e["kind"] == "file" and e["src"] == "pack"})
    present = gitio.object_types(git, dest, wanted)
    have = [o for o in wanted if o in present]
    blobs = {oid: data for oid, _, data in gitio.read_objects(git, dest, have)} if have else {}
    root = os.fsencode(dest)
    for e in entries:
        if e["kind"] == "absent":
            continue
        data = None
        if e["kind"] == "file":
            try:
                data = blobs[e["oid"]] if e["src"] == "pack" else \
                    pa.read_object(run_id, programme_store.PayloadRef(e["sha256"], e["size"], BYTES_TYPE))
            except (KeyError, pa.ArtifactError):
                problems.append(["objects_missing", "worktree " + e["p"]])
                continue
        path = _ensure_parent(root, bytes.fromhex(e.get("disk") or e["p"]))
        if path is None:
            problems.append(["worktree_mismatch", "parent of " + e["p"]])
            continue
        _write_entry(path, e, data)
    return problems


def _restore_refs(git, dest, manifest) -> None:
    for name, oid in manifest["refs"]:
        git.run(dest, ["update-ref", name, oid])
    head = manifest["head"]
    if head["symref"]:
        if head["oid"]:
            git.run(dest, ["update-ref", head["symref"], head["oid"]])
        git.run(dest, ["symbolic-ref", "HEAD", head["symref"]])
    elif head["oid"]:
        git.run(dest, ["update-ref", "--no-deref", "HEAD", head["oid"]])


def _index_input(entries) -> bytes:
    return b"".join(f"{mode} {oid} {stage}\t".encode() + bytes.fromhex(p) + b"\0" for p, stage, mode, oid in entries)


def _materialize(run_id, stored, dest) -> list:
    manifest = json.loads(pa.read_object(run_id, _ref(stored["manifest"])))
    bundle = pa.read_object(run_id, _ref(stored["bundle"]))
    try:
        check_bundle(bundle)
    except PreserveError as exc:
        return [[exc.code, "bundle"]]
    os.mkdir(dest, 0o700)
    with gitio.Git(os.path.dirname(dest)) as git:
        bundle_file = os.path.join(git.home, "code.bundle")
        with open(bundle_file, "wb") as fh:
            fh.write(bundle)
        git.run(dest, ["init", "-q", "--template=", "--object-format=sha1", "."])
        code, _ = git.call(dest, ["bundle", "verify", "-q", bundle_file], ok=(0, 1, 128))
        if code != 0:
            return [["bundle_unverified", "bundle"]]
        git.run(dest, ["bundle", "unbundle", bundle_file])
        problems = []
        try:
            _restore_refs(git, dest, manifest)
        except gitio.GitError:
            problems.append(["objects_missing", "refs"])
        git.run(dest, ["update-index", "-z", "--index-info"], stdin=_index_input(manifest["index"]))
        problems += _restore_worktree(run_id, git, dest, manifest["worktree"])
        code, _ = git.call(dest, ["fsck", "--full", "--no-dangling", "--no-progress"], ok=range(0, 256))
        if code != 0:
            problems.append(["objects_missing", "fsck"])
    return problems


def _present_paths(dest: bytes) -> set:
    found = set()
    for dirpath, dirs, files in os.walk(dest):
        if dirpath == dest:
            dirs[:] = [d for d in dirs if d != b".git"]
        for name in files + [d for d in dirs if os.path.islink(os.path.join(dirpath, d))]:
            found.add(os.path.relpath(os.path.join(dirpath, name), dest).hex())
    return found


def _compare(git, dest, inv) -> list:
    problems = []
    oids = sorted({t[1] for t in inv["tips"]} | {e[3] for e in inv["index"]})
    types = gitio.object_types(git, dest, oids)
    problems += [["objects_missing", f"commit {o}"] for _, o in inv["tips"]
                 if types.get(o, ("missing",))[0] != "commit"]
    problems += [["objects_missing", f"index {e[0]}"] for e in inv["index"]
                 if types.get(e[3], ("missing",))[0] != "blob"]
    if gitio._head(git, {"top": dest}) != inv["head"]:
        problems.append(["head_mismatch", "HEAD"])
    restored = gitio.parse_index(git.run(dest, ["ls-files", "-s", "-z"]))
    if restored != inv["index"]:
        missing = [e[0] for e in inv["index"] if e not in restored]
        extra = [e[0] for e in restored if e not in inv["index"]]
        problems.append(["index_mismatch", f"missing {missing} extra {extra}"])
    root = os.fsencode(dest)
    expected = inv["worktree"] + inv["untracked"] + inv["required_ignored"]
    cache = {}
    for e in expected:
        try:
            now = gitio.worktree_entry(root, bytes.fromhex(e["p"]), cache)
        except gitio.GitError:
            now = None
        if now != e:
            problems.append(["worktree_mismatch", e["p"]])
    wanted = {e.get("disk") or e["p"] for e in expected if e["kind"] != "absent"}
    problems += [["unexpected_file", p] for p in sorted(_present_paths(root) - wanted)]
    return problems


def _verify_stored(run_id, stored, inv) -> dict:
    dest = os.path.join(_code_dir(run_id), "verify-" + secrets.token_hex(8))
    try:
        try:
            problems = _materialize(run_id, stored, dest)
            if os.path.isdir(dest) and not any(p[0] in ("bundle_unverified", "bundle_prerequisites",
                                                         "bundle_malformed") for p in problems):
                with gitio.Git(os.path.dirname(dest)) as git:
                    problems += _compare(git, dest, inv)
        except (gitio.GitError, pa.ArtifactError) as exc:
            problems = [[_error_code(exc), "verifier"]]
    finally:
        shutil.rmtree(dest, ignore_errors=True)
    return {"ok": not problems, "reasons": sorted({p[0] for p in problems}), "mismatches": problems}


def verify(run_id, source_id, *, expected=None) -> dict:
    entry = entry_for(run_id, source_id)
    inv = expected if expected is not None else \
        json.loads(pa.read_object(run_id, _ref(entry["inventory"])))
    return _verify_stored(run_id, entry, inv)


def restore(run_id, source_id, dest) -> dict:
    entry = entry_for(run_id, source_id)
    if os.path.lexists(dest):
        raise PreserveError("the restore destination already exists", "dest_exists")
    try:
        problems = _materialize(run_id, entry, os.path.abspath(dest))
    except (gitio.GitError, pa.ArtifactError) as exc:
        problems = [[_error_code(exc), "restore"]]
    return {"ok": not problems, "problems": problems, "dest": os.path.abspath(dest)}


def _source_reasons(entry) -> list:
    try:
        now = gitio.scan(entry["top"], extras=entry.get("extras") or (),
                         include_ignored=entry.get("include_ignored") or ())
    except gitio.GitError as exc:
        return ["source_missing" if not os.path.lexists(entry["top"]) else "source_" + _error_code(exc)]
    reasons = []
    if now["identity"] != entry["identity"]:
        reasons.append("identity_changed")
    if gitio.digest(now) != entry["generation"]:
        reasons.append("generation_changed")
    return reasons


def cleanup_check(run_id, source_id) -> dict:
    """Whether the receipt still covers the source as it is now; never deletes anything."""
    block = _code_block(pa._current(run_id))
    entry = block.get(source_id)
    if entry is None:
        return {"allowed": False, "reasons": ["no_receipt"], "receipt_id": None, "generation": None}
    reasons = [] if entry.get("status") == "complete" else ["capture_incomplete"]
    try:
        with _source_lock(run_id, source_id, exclusive=False):
            reasons += _source_reasons(entry)
    except PreserveError as exc:
        reasons.append(exc.code)
    try:
        for ref in [entry[k] for k in ("bundle", "inventory", "manifest")] + list(entry["files"]):
            pa.read_object(run_id, _ref(ref))
    except (pa.ArtifactError, programme_store.StoreError, KeyError):
        reasons.append("retained_unreadable")
    return {"allowed": not reasons, "reasons": reasons, "receipt_id": entry.get("receipt_id"),
            "generation": entry.get("generation")}


def preserve_verb(host, argv) -> int:
    _, opts = host._parse(argv, values=("run", "source"), flags=("check",), multi=("extra", "ignored"))
    if not opts.get("source"):
        raise ValueError("preserve-code needs --source <worktree>")
    run_id, _, record = host._locate(opts)
    # Not host._guard: preservation stays open after end (KTD10), so only the session is checked.
    sid = load_lib_module("driver_session").driving_session_id()
    if not load_lib_module("session_registry").caller_drives(record, sid):
        raise host.ProgrammeError("only the programme's driving session may run this verb")
    try:
        if opts.get("check"):
            out = cleanup_check(run_id, source_key(os.path.realpath(opts["source"])))
            host._emit(dict(out, ok=out["allowed"], run=run_id, kind="code_cleanup_check"))
            return 0 if out["allowed"] else 1
        out = capture(run_id, opts["source"], extras=opts["extra"], include_ignored=opts["ignored"],
                      operation_id=host._OPERATION["id"])
    except PreserveError as exc:
        host._emit({"ok": False, "run": run_id, "kind": FAILED_KIND, "code": exc.code, "preserved": False})
        return 1
    complete = out.get("status") == "complete"
    host._emit(dict(out, ok=complete, run=run_id, kind=CAPTURED_KIND, preserved=complete))
    return 0 if complete else 1
