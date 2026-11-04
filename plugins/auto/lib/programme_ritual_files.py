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
SHORT = 20

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


_ID_LABEL = re.compile(r"[a-z][a-z0-9-]*")


def _rejected(key, rid, exc) -> dict:
    # The id of a rejected file comes from a file name anyone with push access chose; only a safe slug is shown.
    label = rid if _ID_LABEL.fullmatch(rid) else "<unnamed file>"
    return {"layer": "repo", "key": key, "id": label, "reason": exc.reason, "detail": exc.detail, "source": "file"}


def _read_repo(path, key) -> dict:
    """Entries, rejected rows and a notice from one remit repo's default branch; never raises.

    ``read`` is True only when the whole listing was handled. ``listed`` holds every ``.md`` name the
    default branch has, valid or not, so a file that turns invalid is told apart from one that is gone.
    """
    out = {"entries": [], "rejected": [], "notice": None, "commit": None, "ref": None, "ref_age_seconds": None,
           "read": False, "listed": set()}
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
            out.update(commit=commit, ref=head, ref_age_seconds=checks._fetch_age(repo))
            listing = repo.run(["ls-tree", "-z", "-l", commit, FOLDER + "/"]).split(b"\0")
            items = []
            for line in listing:
                meta, _, name = line.decode("utf-8", "replace").partition("\t")
                name = name[len(FOLDER) + 1:]
                parts = meta.split()
                if len(parts) == 4 and parts[1] != "tree" and name.endswith(".md"):
                    items.append((parts, name))
            out["listed"] = {name[:-3] for _, name in items}
            if len(items) > MAX_FILES:
                out["notice"] = f"{key} has more than {MAX_FILES} ritual files; none read"
                out["read"] = True
                return out
            for (mode, kind, oid, size), name in items:
                rid = name[:-3]
                try:
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
            out["read"] = True
    except checks._Stop as stop:
        out.update(entries=[], rejected=[], read=False, notice=f"ritual files in {key} not read: {stop.reason}")
    except programme_gitio.GitError as exc:
        out.update(entries=[], rejected=[], read=False, notice=f"ritual files in {key} not read: {exc.code}")
    except Exception:  # noqa: BLE001 — a broken repo must degrade to a notice, never stop a sweep
        out.update(entries=[], rejected=[], read=False, notice=f"ritual files in {key} not read: internal")
    return out


def _cached(path, key, fresh):
    now = time.monotonic()
    hit = _cache.get((path, key))
    if hit is not None and not fresh and now - hit[0] < CACHE_SECONDS:
        return hit[1]
    got = _read_repo(path, key)
    _cache[(path, key)] = (now, got)
    return got


def _row(item, key, repo, state, entry=None) -> dict:
    entry = entry or item["entry"]
    return {"id": entry["id"], "repo_key": key, "state": state, "hash": item["hash"], "hash_short": item["hash"][:SHORT],
            "entry": entry, "file": {"path": item["path"], "commit": repo["commit"], "ref": repo["ref"],
                                      "ref_age_seconds": repo["ref_age_seconds"]}}


def _snapshot(record, key, rid, out):
    """The adopted entry, judged again by today's validator; a malformed or no-longer-valid one is a rejected row."""
    programme_rituals = load_lib_module("programme_rituals")
    snap = record.get("snapshot")
    if not isinstance(snap, dict):
        out["rejected"].append({"layer": "repo", "key": key, "id": rid, "reason": "adoption_malformed",
                                "detail": "the adoption record holds no snapshot", "source": "file"})
        return None
    bare = {k: v for k, v in snap.items() if k not in ("source", "at")}
    check = programme_rituals.verdict(bare, allow_adoption=False)
    if not check["ok"]:
        out["rejected"].append({"layer": "repo", "key": key, "id": rid, "reason": check["reason"],
                                "detail": check["detail"], "source": "file"})
        return None
    return dict(bare, source="file", at=record.get("adopted_at"))


def _unseen_row(snap, key, state, record) -> dict:
    return {"id": snap["id"], "repo_key": key, "state": state, "hash": record.get("hash"),
            "hash_short": str(record.get("hash"))[:SHORT], "entry": snap,
            "file": {"path": f"{FOLDER}/{snap['id']}.md", "commit": None, "ref": None, "ref_age_seconds": None}}


def file_layer(programme, taken, *, fresh=False) -> dict:
    """What the remit repos' ritual files mean for this programme.

    ``taken`` is the set of ids another layer already holds: a file with such an id is rejected and the
    established ritual is left alone. Two unadopted files with one id are both rejected; an adopted one
    keeps its place. An adopted snapshot stays in force until Shawn adopts or declines the new content,
    whatever happens to the file: it leaves force only when the repo was read and the file is gone, when
    its repo left the remit, or when an established ritual holds its id.
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
    matched = set()
    for key, item in seen:
        entry = item["entry"]
        rid = entry["id"]
        name = f"{key}/{rid}"
        record = adoptions.get(name) or {}
        adopted = record.get("state") == "adopted"
        if rid in taken or (count[rid] > 1 and not adopted):
            out["rejected"].append({"layer": "repo", "key": key, "id": rid, "reason": "id_collision", "source": "file",
                                    "detail": "another ritual or another repo's file has this id"})
            continue
        repo = loaded[key]
        if adopted:
            snap = _snapshot(record, key, rid, out)
            matched.add(name)
            if snap is None:
                continue
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
        key, _, rid = name.rpartition("/")
        got = loaded.get(key)
        if record.get("state") != "adopted" or name in matched or got is None:
            continue
        if rid in taken or (got["read"] and rid not in got["listed"]):
            continue
        snap = _snapshot(record, key, rid, out)
        if snap is None:
            continue
        out["in_force"].append(snap)
        out["adopted"].append(_unseen_row(snap, key, "unverified" if got["read"] else "unread", record))
    return out
