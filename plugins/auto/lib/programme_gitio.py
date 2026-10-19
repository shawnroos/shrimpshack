#!/usr/bin/env python3
"""Isolated, read-only git access and the frozen inventory of one worktree.

Every git child runs with a scrubbed environment, an empty HOME, no system or global
config, hooks pointed at /dev/null, no fsmonitor, no transport protocols and no lazy
fetch. Worktree bytes are read and hashed here in Python, never through git, so no
clean filter, textconv or index refresh can run against the source.
"""

from __future__ import annotations

import hashlib
import os
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import unicodedata

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

programme_store = load_lib_module("programme_store")

GIT_TIMEOUT = 120.0
# Matches programme_artifacts.MAX_PAYLOAD_BYTES: a larger file could never be retained.
MAX_FILE_BYTES = 8 << 20
# A chosen bound on bytes scanned per capture, not measured.
MAX_SCAN_BYTES = 256 << 20
SAFE_CONFIG = (
    "core.hooksPath=/dev/null", "core.fsmonitor=false", "core.untrackedCache=false",
    "core.pager=cat", "gc.auto=0", "maintenance.auto=false", "protocol.allow=never",
    "submodule.recurse=false", "fetch.recurseSubmodules=false", "credential.helper=",
)
GITLINK = "160000"
ZERO_OID = "0" * 40
PSEUDO_HEADS = ("MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "ORIG_HEAD")


class GitError(Exception):
    def __init__(self, message, code):
        super().__init__(message)
        self.code = code


# A PATH lookup can land on a user wrapper around git (one here starts a daemon), so a
# system git is preferred and PATH is only the fallback.
SYSTEM_GITS = ("/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git")


def git_binary() -> str:
    for candidate in SYSTEM_GITS:
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    found = shutil.which("git")
    if not found:
        raise GitError("git is not on PATH", "git_missing")
    return os.path.realpath(found)


class Git:

    def __init__(self, ceiling):
        self.binary = git_binary()
        self.home = tempfile.mkdtemp(prefix="gitio-home-")
        self.env = {
            "PATH": os.pathsep.join([os.path.dirname(self.binary), "/usr/bin", "/bin"]),
            "HOME": self.home, "XDG_CONFIG_HOME": self.home, "TMPDIR": self.home,
            "LANG": "C", "LC_ALL": "C", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_TERMINAL_PROMPT": "0", "GIT_NO_LAZY_FETCH": "1", "GIT_NO_REPLACE_OBJECTS": "1",
            "GIT_OPTIONAL_LOCKS": "0", "GIT_CEILING_DIRECTORIES": ceiling,
        }

    def close(self):
        shutil.rmtree(self.home, ignore_errors=True)

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    def run(self, cwd, args, *, stdin=None, ok=(0,), timeout=GIT_TIMEOUT) -> bytes:
        return self.call(cwd, args, stdin=stdin, ok=ok, timeout=timeout)[1]

    def call(self, cwd, args, *, stdin=None, ok=(0,), timeout=GIT_TIMEOUT):
        argv = [self.binary]
        for item in SAFE_CONFIG:
            argv += ["-c", item]
        argv += ["-C", cwd] + list(args)
        try:
            proc = subprocess.Popen(argv, stdin=subprocess.PIPE if stdin is not None else subprocess.DEVNULL,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=self.env,
                                    cwd=self.home, start_new_session=True)
        except OSError as exc:
            raise GitError(f"could not run git: {exc.strerror}", "git_failed")
        try:
            out, err = proc.communicate(stdin, timeout=timeout)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except OSError:
                pass
            proc.communicate()
            raise GitError(f"git {args[0]} timed out", "timed_out")
        if proc.returncode not in ok:
            detail = err.decode("utf-8", "replace").strip().splitlines()[-1:] or [""]
            raise GitError(f"git {args[0]} exited {proc.returncode}: {detail[0][:200]}", "git_failed")
        return proc.returncode, out


def blob_oid(data: bytes) -> str:
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


def lstat(path):
    try:
        return os.lstat(path)
    except FileNotFoundError:
        return None


def inside(top: bytes, rel: bytes):
    path = top
    parts = rel.split(b"/")
    for part in parts[:-1]:
        path = os.path.join(path, part)
        st = lstat(path)
        if st is None or not stat.S_ISDIR(st.st_mode):
            return path, None
    path = os.path.join(path, parts[-1])
    return path, lstat(path)


def read_file(path: bytes, st) -> bytes:
    if st.st_size > MAX_FILE_BYTES:
        raise GitError("a worktree file is over the retention limit", "oversized")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        now = os.fstat(fd)
        if (now.st_dev, now.st_ino) != (st.st_dev, st.st_ino) or not stat.S_ISREG(now.st_mode):
            raise GitError("a worktree file was replaced while it was read", "changed")
        chunks, total = [], 0
        while total <= MAX_FILE_BYTES:
            chunk = os.read(fd, 1 << 16)
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
    finally:
        os.close(fd)
    if total > MAX_FILE_BYTES:
        raise GitError("a worktree file is over the retention limit", "oversized")
    return b"".join(chunks)


def _nfc(name: bytes) -> str:
    return unicodedata.normalize("NFC", name.decode("utf-8", "surrogateescape"))


def disk_name(top: bytes, rel: bytes, cache) -> bytes:
    """The bytes the filesystem holds for rel; git may report a precomposed spelling of them."""
    path, out = top, []
    for part in rel.split(b"/"):
        names = cache.get(path)
        if names is None:
            try:
                names = cache[path] = os.listdir(path)
            except OSError:
                names = cache[path] = []
        if part not in names:
            match = [n for n in names if _nfc(n) == _nfc(part)]
            part = match[0] if len(match) == 1 else part
        out.append(part)
        path = os.path.join(path, part)
    return b"/".join(out)


def worktree_entry(top: bytes, rel: bytes, cache=None) -> dict:
    path, st = inside(top, rel)
    entry = {"p": rel.hex()}
    if st is not None and not stat.S_ISDIR(st.st_mode):
        disk = disk_name(top, rel, {} if cache is None else cache)
        if disk != rel:
            entry["disk"] = disk.hex()
    if st is None or stat.S_ISDIR(st.st_mode):
        entry["kind"] = "absent"
    elif stat.S_ISLNK(st.st_mode):
        target = os.readlink(path)
        entry.update(kind="link", target=target.hex(), oid=blob_oid(target))
    elif stat.S_ISREG(st.st_mode):
        data = read_file(path, st)
        entry.update(kind="file", x=bool(st.st_mode & stat.S_IXUSR), size=len(data), oid=blob_oid(data),
                     sha256=hashlib.sha256(data).hexdigest())
    else:
        raise GitError("a worktree path is neither a file, a symlink nor a directory", "unsupported")
    return entry


def _z(data: bytes) -> list:
    return [p for p in data.split(b"\0") if p]


def parse_index(data: bytes) -> list:
    entries = []
    for record in _z(data):
        meta, _, path = record.partition(b"\t")
        mode, oid, stage = meta.decode("ascii").split(" ")
        entries.append([path.hex(), int(stage), mode, oid])
    return sorted(entries)


def _locks(gitdir, common) -> list:
    found = []
    for base, names in ((gitdir, ("index.lock", "HEAD.lock")), (common, ("packed-refs.lock", "config.lock",
                                                                          "shallow.lock"))):
        found += [n for n in names if os.path.lexists(os.path.join(base, n))]
    for base in {gitdir, common}:
        for dirpath, _, files in os.walk(os.path.join(base, "refs")):
            found += [f for f in files if f.endswith(".lock")]
    return found


def _reflog_oids(path) -> list:
    try:
        with open(path, "rb") as fh:
            lines = fh.read().splitlines()
    except FileNotFoundError:
        return []
    oids = []
    for line in lines:
        fields = line.split(b" ", 2)
        oids += [f.decode("ascii") for f in fields[:2] if len(f) == 40 and f != ZERO_OID.encode()]
    return oids


def _pseudo_oids(gitdir) -> list:
    tips = []
    for name in PSEUDO_HEADS:
        try:
            with open(os.path.join(gitdir, name), "rb") as fh:
                lines = fh.read().split()
        except FileNotFoundError:
            continue
        tips += [(f"pseudo/{name}/{i}", line.decode("ascii")) for i, line in enumerate(lines) if len(line) == 40]
    return tips


def locate(git, path) -> dict:
    top = os.path.realpath(path)
    if not os.path.isdir(top):
        raise GitError("the source is not a directory", "invalid_source")
    code, out = git.call(top, ["rev-parse", "--path-format=absolute", "--show-toplevel", "--absolute-git-dir",
                               "--git-common-dir", "--show-object-format", "--is-shallow-repository"],
                         ok=(0, 128))
    if code != 0:
        raise GitError("the source is not inside a git worktree", "invalid_source")
    shown_top, gitdir, common, fmt, shallow = out.decode("utf-8", "surrogateescape").splitlines()
    if os.path.realpath(shown_top) != top:
        raise GitError("the source is not the top of a git worktree", "invalid_source")
    return {"top": top, "gitdir": os.path.realpath(gitdir), "common": os.path.realpath(common),
            "format": fmt, "shallow": shallow == "true"}


def identity(where) -> dict:
    out = {}
    for key in ("top", "gitdir", "common"):
        st = os.stat(where[key])
        out[key] = [where[key], st.st_dev, st.st_ino]
    return out


def unsupported_store(git, where) -> list:
    problems = []
    if where["format"] != "sha1":
        problems.append("object format is not sha1")
    if where["shallow"]:
        problems.append("shallow repository")
    alternates = os.path.join(where["common"], "objects", "info", "alternates")
    if os.path.isfile(alternates) and os.path.getsize(alternates) > 0:
        problems.append("objects borrowed through alternates")
    packs = os.path.join(where["common"], "objects", "pack")
    if os.path.isdir(packs) and any(n.endswith(".promisor") for n in os.listdir(packs)):
        problems.append("promisor pack")
    code, out = git.call(where["top"], ["config", "--get-regexp", r"^(extensions\.partialclone|remote\..*\.promisor)$"],
                         ok=(0, 1))
    if code == 0 and out.strip():
        problems.append("partial clone or promisor remote")
    return problems


def head_of(git, where):
    code, symref = git.call(where["top"], ["symbolic-ref", "-q", "HEAD"], ok=(0, 1))
    code_h, oid = git.call(where["top"], ["rev-parse", "-q", "--verify", "HEAD^{commit}"], ok=(0, 1))
    return {"symref": symref.decode().strip() if code == 0 else None,
            "oid": oid.decode().strip() if code_h == 0 else None}


def object_types(git, top, oids) -> dict:
    if not oids:
        return {}
    out = git.run(top, ["cat-file", "--batch-check"], stdin=("\n".join(oids) + "\n").encode())
    found = {}
    for line in out.decode("ascii", "replace").splitlines():
        fields = line.split()
        if len(fields) == 3:
            found[fields[0]] = (fields[1], int(fields[2]))
    return found


def _tips(git, where, head, extras) -> tuple:
    candidates = []
    if head["oid"]:
        candidates.append(("head", head["oid"]))
    reflogs = [os.path.join(where["gitdir"], "logs", "HEAD")]
    if head["symref"]:
        reflogs.append(os.path.join(where["common"], "logs", *head["symref"].split("/")))
    for log in reflogs:
        candidates += [(f"reflog/{len(candidates)}", oid) for oid in _reflog_oids(log)]
    candidates += _pseudo_oids(where["gitdir"])
    for i, rev in enumerate(extras):
        if not isinstance(rev, str) or not rev or rev.startswith("-"):
            raise GitError("an extra revision must be a plain revision", "invalid_source")
        code, out = git.call(where["top"], ["rev-parse", "-q", "--verify", "--end-of-options", rev + "^{commit}"],
                             ok=(0, 1))
        if code != 0:
            raise GitError("a required extra revision does not exist", "unsupported")
        candidates.append((f"extra/{i}", out.decode().strip()))
    types = object_types(git, where["top"], sorted({oid for _, oid in candidates}))
    tips, seen, lost = [], set(), 0
    for name, oid in candidates:
        if oid in seen:
            continue
        if types.get(oid, ("missing",))[0] != "commit":
            if name.startswith("reflog/"):
                lost += 1
                continue
            raise GitError("a required commit is missing from the source", "unsupported")
        seen.add(oid)
        tips.append([name, oid])
    return tips, lost


def scan(path, *, extras=(), include_ignored=()) -> dict:
    """The frozen expected inventory of one worktree; problems are listed, not raised."""
    with Git(os.path.dirname(os.path.realpath(path))) as git:
        where = locate(git, path)
        inv = {"format": 1, "top": where["top"], "identity": identity(where), "problems": [],
               "quiescence": _locks(where["gitdir"], where["common"])}
        inv["problems"] += unsupported_store(git, where)
        head = head_of(git, where)
        inv["head"] = head
        inv["tips"], inv["lost_reflog"] = _tips(git, where, head, extras)
        inv["index"] = parse_index(git.run(where["top"], ["ls-files", "-s", "-z"]))
        if any(e[2] == GITLINK for e in inv["index"]):
            inv["problems"].append("submodule gitlink")
        others = git.run(where["top"], ["ls-files", "-z", "-o", "--exclude-standard"])
        ignored = git.run(where["top"], ["ls-files", "-z", "-o", "-i", "--exclude-standard", "--directory"])
    top = os.fsencode(where["top"])
    _worktree(inv, top, others, ignored, include_ignored)
    return inv


def _worktree(inv, top, others, ignored, include_ignored) -> None:
    cache = {}
    tracked = sorted({bytes.fromhex(e[0]) for e in inv["index"] if e[2] != GITLINK})
    inv["worktree"] = [worktree_entry(top, p, cache) for p in tracked]
    untracked = []
    for rel in _z(others):
        if rel.endswith(b"/"):
            inv["problems"].append("nested repository in the worktree")
            continue
        untracked.append(worktree_entry(top, rel, cache))
    inv["untracked"] = untracked
    listed = _z(ignored)
    inv["ignored"] = sorted(p.hex() for p in listed)
    required = []
    for rel in include_ignored:
        raw = os.fsencode(rel)
        if not any(raw == p or (p.endswith(b"/") and raw.startswith(p)) for p in listed):
            inv["problems"].append("a required ignored path is not an ignored file")
            continue
        entry = worktree_entry(top, raw, cache)
        if entry["kind"] == "absent":
            inv["problems"].append("a required ignored path is not a file")
            continue
        required.append(entry)
    inv["required_ignored"] = sorted(required, key=lambda e: e["p"])


def digest(inventory) -> str:
    return programme_store.digest_of(inventory)


def closure(git, top, tips, extra_oids) -> list:
    oids = []
    if tips:
        oids = git.run(top, ["rev-list", "--objects", "--no-object-names"] + list(tips) + ["--"]) \
            .decode("ascii").split()
    seen = set(oids)
    for oid in extra_oids:
        if oid not in seen:
            seen.add(oid)
            oids.append(oid)
    return oids


def read_objects(git, top, oids):
    sizes = object_types(git, top, oids)
    missing = [o for o in oids if o not in sizes]
    if missing:
        raise GitError(f"{len(missing)} required objects are missing from the source", "unsupported")
    if sum(size for _, size in sizes.values()) > MAX_SCAN_BYTES:
        raise GitError("the required objects are over the scan limit", "unsupported")
    out = git.run(top, ["cat-file", "--batch"], stdin=("\n".join(oids) + "\n").encode())
    pos = 0
    for _ in oids:
        end = out.find(b"\n", pos)
        fields = out[pos:end].decode("ascii", "replace").split() if end >= 0 else []
        if len(fields) != 3 or not fields[2].isdigit():
            raise GitError("an object vanished while it was read", "changed")
        oid, kind, size = fields
        start = end + 1
        yield oid, kind, out[start:start + int(size)]
        pos = start + int(size) + 1


def pack(git, top, oids) -> bytes:
    return git.run(top, ["pack-objects", "--stdout", "-q"], stdin=("\n".join(oids) + "\n").encode())
