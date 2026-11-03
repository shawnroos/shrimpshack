#!/usr/bin/env python3
"""Rituals that ship inside a repo: ``.auto/rituals/<id>.md`` on the repo's default branch.

A file is only ever *proposed*. It is read from the committed tree of the remote default branch
(``origin/HEAD``), never from the working folder, so a change takes effect only after the repo's own
review and merge. It is in force for a programme only after Shawn's typed words name the ritual and
the content hash; a changed file proposes again and the adopted snapshot stays in force until he
adopts or declines the new content. A file carries no power a stored ritual lacks: the same validator
runs, a step that names a protected action is refused, and ``check`` names come from the fixed list.
"""

from __future__ import annotations

import os
import re
import sys
import time

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

programme_behaviour_files = load_lib_module("programme_behaviour_files")
programme_carryover = load_lib_module("programme_carryover")
programme_gitio = load_lib_module("programme_gitio")
programme_protocol = load_lib_module("programme_protocol")
programme_ritual_checks = load_lib_module("programme_ritual_checks")
programme_sanitize = load_lib_module("programme_sanitize")

_Reject = programme_protocol._Reject

FOLDER = ".auto/rituals"
SCHEMA = 1
MAX_FILES = 50
MAX_FILE_BYTES = programme_behaviour_files.MAX_FILE_BYTES
MAX_LINE_CHARS = programme_behaviour_files.MAX_LINE_CHARS
KEYS = ("when", "schedule", "trigger", "check", "check_base", "why")
CACHE_SECONDS = 20.0
APPROVAL_STATES = ("proposed", "changed", "declined")

_NAME_RE = re.compile(r"[a-z][a-z0-9-]*\.md")
_OID_RE = re.compile(r"[0-9a-f]{40,64}")
_HEAD_RE = re.compile(r"refs/remotes/origin/[A-Za-z0-9._/-]+")
_SECTION = re.compile(r"^(?:#+\s*)?(steps|offers)\s*:?\s*$", re.IGNORECASE)
_cache = {}


def invalidate() -> None:
    _cache.clear()


def _body(lines):
    out, section = {"steps": [], "offers": []}, None
    for line in lines:
        if not line.strip():
            continue
        head = _SECTION.match(line.strip())
        if head:
            section = head.group(1).lower()
            continue
        bullet = programme_behaviour_files._BULLET.match(line)
        if section is None or not bullet:
            raise _Reject("bad_value", "body")
        out[section].append(bullet.group(1))
    return out["steps"], out["offers"]


def parse_text(text, rid, repo_key) -> dict:
    """The ritual entry a file holds, validated by the ritual validator; raises ``_Reject``."""
    programme_rituals = load_lib_module("programme_rituals")
    if not programme_rituals._ID_RE.match(rid):
        raise _Reject("bad_value", "id")
    if any(len(line) > MAX_LINE_CHARS for line in programme_behaviour_files._LINES.split(text)):
        raise _Reject("bad_value", "line length")
    head, body = programme_behaviour_files._split(text)
    fields = programme_behaviour_files._frontmatter(head, KEYS, KEYS, ())
    if not fields.get("when"):
        raise _Reject("missing_field", "when")
    if bool(fields.get("schedule")) == bool(fields.get("trigger")):
        raise _Reject("bad_value", "when.schedule")
    steps, offers = _body(body)
    if fields.get("schedule"):
        try:
            when = {"text": fields["when"], "trigger": "calendar",
                    "schedule": programme_rituals.parse_schedule(fields["schedule"])}
        except ValueError:
            raise _Reject("bad_value", "schedule") from None
    else:
        when = {"text": fields["when"], "trigger": fields["trigger"]}
    entry = {"id": rid, "layer": "repo", "repo_key": repo_key, "state": "active", "when": when, "steps": steps}
    if offers:
        entry["offers"] = offers
    if fields.get("why"):
        entry["why"] = fields["why"]
    if fields.get("check"):
        entry["check"] = {"name": fields["check"]}
        if fields.get("check_base"):
            entry["check"]["base"] = fields["check_base"]
    elif fields.get("check_base"):
        raise _Reject("bad_value", "check_base")
    clean = programme_sanitize.clean
    for line in steps + offers + [fields["when"], fields.get("why", "")]:
        if clean(line, cap=0) != line:
            raise _Reject("bad_value", "text")
    check = programme_rituals.verdict(entry, allow_adoption=False)
    if not check["ok"]:
        raise _Reject(check["reason"], check["detail"])
    return entry


def entry_hash(entry) -> str:
    return programme_protocol.content_hash({"schema": SCHEMA, "entry": entry})[len("sha256:"):]


def _rejected(key, rid, exc) -> dict:
    return {"layer": "repo", "key": key, "id": rid, "reason": exc.reason, "detail": exc.detail, "source": "file"}


def _read_repo(path, key) -> dict:
    """Entries, rejected rows and a notice from one remit repo's default branch; never raises."""
    out = {"entries": [], "rejected": [], "notice": None, "commit": None, "ref_age_seconds": None, "read": False}
    checks = programme_ritual_checks
    try:
        if not os.path.isabs(path) or not os.path.isdir(path):
            raise checks._Stop("not_a_repo")
        real = os.path.realpath(path)
        with programme_gitio.Git(os.path.dirname(real)) as git:
            repo = checks._Repo(git, real, checks.BUDGET_SECONDS)
            if os.path.realpath(repo.text(["rev-parse", "--show-toplevel"], reason="not_a_repo")) != real:
                raise checks._Stop("not_a_repo")
            try:
                head = repo.text(["symbolic-ref", "-q", "refs/remotes/origin/HEAD"])
            except checks._Stop:
                head = ""
            if not _HEAD_RE.fullmatch(head):
                out["notice"] = (f"origin/HEAD does not resolve in {key}; no ritual files read "
                                 "(there is no fallback to a local branch)")
                return out
            commit = repo.text(["rev-parse", "--verify", "--end-of-options", head + "^{commit}"])
            out.update(commit=commit, ref_age_seconds=checks._fetch_age(repo), read=True)
            listing = repo.run(["ls-tree", "-z", "-l", commit, FOLDER + "/"]).split(b"\0")
            files = [line for line in listing if line]
            if len(files) > MAX_FILES:
                out["notice"] = f"{key} has more than {MAX_FILES} ritual files; none read"
                return out
            for line in files:
                meta, _, name = line.decode("utf-8", "replace").partition("\t")
                name = name[len(FOLDER) + 1:]
                parts = meta.split()
                if len(parts) != 4 or not name.endswith(".md"):
                    continue
                mode, kind, oid, size = parts
                rid = name[:-3]
                try:
                    if kind == "tree":
                        continue
                    if not _NAME_RE.fullmatch(name) or mode not in ("100644", "100755") or kind != "blob" \
                            or not _OID_RE.fullmatch(oid):
                        raise _Reject("bad_value", "file")
                    if not size.isdigit() or int(size) > MAX_FILE_BYTES:
                        raise _Reject("bad_value", "file size")
                    try:
                        text = repo.run(["cat-file", "blob", oid]).decode("utf-8")
                    except UnicodeDecodeError:
                        raise _Reject("bad_value", "file") from None
                    entry = parse_text(text, rid, key)
                    out["entries"].append({"entry": entry, "hash": entry_hash(entry), "path": f"{FOLDER}/{name}"})
                except _Reject as exc:
                    out["rejected"].append(_rejected(key, rid, exc))
    except checks._Stop as stop:
        out["notice"] = f"ritual files in {key} not read: {stop.reason}"
    except programme_gitio.GitError as exc:
        out["notice"] = f"ritual files in {key} not read: {exc.code}"
    except Exception:  # noqa: BLE001 — a broken repo must degrade to a notice, never stop a sweep
        out["notice"] = f"ritual files in {key} not read: internal"
    return out


def _cached(path, key, fresh):
    now = time.monotonic()
    hit = _cache.get(path)
    if hit is not None and not fresh and now - hit[0] < CACHE_SECONDS:
        return hit[1]
    got = _read_repo(path, key)
    _cache[path] = (now, got)
    return got


def _row(item, key, repo, state, entry=None) -> dict:
    entry = entry or item["entry"]
    return {"id": entry["id"], "repo_key": key, "state": state, "hash": item["hash"], "hash_short": item["hash"][:12],
            "entry": entry, "file": {"path": item["path"], "commit": repo["commit"],
                                      "ref_age_seconds": repo["ref_age_seconds"]}}


def file_layer(programme, taken, *, fresh=False) -> dict:
    """What the remit repos' ritual files mean for this programme.

    ``taken`` is the set of ids another layer already holds: a file with such an id is rejected and
    the established ritual is left alone. Two files with one id are both rejected.
    """
    adoptions = programme.get("ritual_adoptions") or {}
    out = {"in_force": [], "adopted": [], "proposals": [], "declined": [], "rejected": [], "notices": []}
    seen, loaded = [], {}
    for repo in (programme.get("remit") or {}).get("repos") or []:
        if not (isinstance(repo, dict) and repo.get("path")):
            continue
        key = programme_carryover.key_of(repo)
        if key in loaded:
            continue
        got = _cached(repo["path"], key, fresh)
        loaded[key] = got
        out["rejected"] += got["rejected"]
        if got["notice"]:
            out["notices"].append(got["notice"])
        seen += [(key, item) for item in got["entries"]]
    count = {}
    for _, item in seen:
        count[item["entry"]["id"]] = count.get(item["entry"]["id"], 0) + 1
    present = set()
    for key, item in seen:
        entry = item["entry"]
        rid = entry["id"]
        if rid in taken or count[rid] > 1:
            out["rejected"].append({"layer": "repo", "key": key, "id": rid, "reason": "id_collision", "source": "file",
                                    "detail": "another ritual or another repo's file has this id"})
            continue
        present.add(f"{key}/{rid}")
        record = adoptions.get(f"{key}/{rid}") or {}
        repo = loaded[key]
        if record.get("state") == "adopted":
            snap = dict(record["snapshot"], source="file", at=record.get("adopted_at"))
            out["in_force"].append(snap)
            same = record.get("hash") == item["hash"]
            out["adopted"].append(_row(dict(item, hash=record.get("hash", item["hash"])), key, repo,
                                       "adopted" if same else "changed_since_adoption", snap))
            if not same:
                out["proposals"].append(_row(item, key, repo, "changed"))
        elif record.get("state") == "declined" and record.get("hash") == item["hash"]:
            out["declined"].append(_row(item, key, repo, "declined"))
        else:
            out["proposals"].append(_row(item, key, repo, "proposed"))
    for name, record in adoptions.items():
        key = name.rsplit("/", 1)[0]
        if record.get("state") != "adopted" or name in present:
            continue
        # A repo that was read and no longer holds the file removed the ritual; one that could not be read keeps its snapshot.
        if loaded.get(key, {}).get("read"):
            continue
        if record.get("snapshot", {}).get("id") in taken:
            continue
        snap = dict(record["snapshot"], source="file", at=record.get("adopted_at"))
        out["in_force"].append(snap)
        out["adopted"].append({"id": snap["id"], "repo_key": key, "state": "unread", "hash": record.get("hash"),
                               "hash_short": str(record.get("hash"))[:12], "entry": snap,
                               "file": {"path": f"{FOLDER}/{snap['id']}.md", "commit": None, "ref_age_seconds": None}})
    return out
