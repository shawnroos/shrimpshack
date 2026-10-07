#!/usr/bin/env python3
"""Programme item, wait, inbox and working-model verbs.

``programme.py`` registers these through ``build_verbs(host)``, passing itself as
``host`` so the verbs share its locate, guard, typed-prompt and write path.
No verb sets an item to done: done is derived from confirmed evidence.
"""

from __future__ import annotations

import functools
import json
import os
import re
import secrets
import shutil
import subprocess
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
driver_session = load_lib_module("driver_session")

CLAIMS_NAME = "claims.jsonl"
SOURCES = ("herdr", "board", "linear")
SOURCE_STATES = ("available", "unavailable", "unsupported")
CHOICES = ("ship", "decline")
ID_CAP = 128
CRON_PROMPT_CAP = 4000
NOTIFY_TIMEOUT_SECONDS = 5
BOARD_SOURCE = "linear"
ISSUELESS_SOURCE = "herdr"
WAITABLE_STATES = ("open", "waiting")
_ID_RE = re.compile(r"[a-z][a-z0-9_-]*:[A-Za-z0-9._/#@+:-]+")
_ACTION_RE = re.compile(r"[a-z][a-z0-9_]*")
_PID_RE = re.compile(r"[0-9]+")
_SHASUM_RE = re.compile(r"[0-9a-f]{40}|[0-9a-f]{64}|sha(?:1|256|512)-[A-Za-z0-9+/]+={0,2}")
_EVIDENCE_RANK = {"confirmed": 3, "refuted": 2, "unknown": 1}


class RecordError(Exception):
    pass


def check_item_id(value) -> str:
    if (not isinstance(value, str) or len(value) > ID_CAP or ".." in value
            or not _ID_RE.fullmatch(value)):
        raise RecordError(f"item id must be source:key with no '..', spaces or control text: {value!r}")
    return value


def _now() -> str:
    return run_record_core.now_iso()


def _text(value, field, *, required=True):
    text = programme_sanitize.clean(value)
    if required and not text:
        raise ValueError(f"--{field} needs a non-empty value")
    return text or None


def _token(value, field):
    if value is None:
        return None
    text = programme_sanitize.token(value)
    if text is None:
        raise RecordError(f"--{field} must be one short word with no spaces: {value!r}")
    return text


def _resolve(programme, item_id) -> str:
    items = programme["items"]
    if item_id in items:
        return item_id
    for key, item in items.items():
        if item_id in (item.get("aliases") or []):
            return key
    raise RecordError(f"no item {item_id!r} in this programme")


def _history(item, kind, **fields) -> None:
    item["history"].append(dict({"at": _now(), "kind": kind}, **fields))


def _load_protocol(host, repo=None) -> dict:
    return programme_protocol.load(repo_path=repo, prompt_lookup=host.prompt_lookup)


def _check_kinds(protocol, kinds) -> list:
    known = set(programme_protocol.CHANGE_KINDS)
    for rule in protocol["rules"].values():
        known.update(rule["applies_when"]["change_kinds"])
    unknown = [k for k in kinds if k not in known]
    if unknown:
        raise RecordError(f"unknown change kind {unknown}; known: {sorted(known)}")
    return list(dict.fromkeys(kinds))


def _apply_match(item, protocol, kinds) -> dict:
    result = programme_protocol.match(protocol, kinds)
    old = item.get("deliverables") or {}
    item["change_kinds"] = list(kinds)
    item["matched_rule"] = result["matched_rule"]
    item["requires"] = list(result["requires"])
    item["deliverables"] = {name: old.get(name) or {"result": "unknown"}
                            for name in result["deliverables"]}
    return {"matched_rule": result["matched_rule"], "deliverables": sorted(item["deliverables"])}


def _set_owner(item, opts) -> bool:
    sid = _token(opts.get("session"), "session")
    pane = _token(opts.get("pane"), "pane")
    terminal = _token(opts.get("terminal-id"), "terminal-id")
    if not (sid or pane or terminal):
        return False
    owner = {"pane": pane, "terminal_id": terminal, "session_id": sid}
    if owner == item["owner"]:
        return False
    item["owner"] = owner
    if sid:
        item["sessions"].append({"session_id": sid, "pane": pane, "terminal_id": terminal,
                                 "name": _text(opts.get("session-name"), "session-name", required=False),
                                 "at": _now()})
    _history(item, "owner", session_id=sid, pane=pane)
    return True


def _h_add_item(host, argv):
    positional, opts = host._parse(
        argv, values=("run", "title", "repo", "pane", "terminal-id", "session", "session-name"),
        multi=("kind",))
    if len(positional) != 1:
        raise ValueError("usage: add-item <source:key> [--title <text>] [--kind <change-kind>]...")
    item_id = check_item_id(positional[0])
    protocol = _load_protocol(host, opts.get("repo"))
    kinds = _check_kinds(protocol, opts["kind"])
    title = _text(opts.get("title"), "title", required=False)
    seen = {}

    def change(programme, prompt, rec):
        try:
            key = _resolve(programme, item_id)
        except RecordError:
            key = None
        if key is None:
            item = programme_home.new_item(item_id, title or "", now_iso=_now())
            payload = dict({"item": item_id, "title": item["title"]}, **_apply_match(item, protocol, kinds))
            payload["owner_changed"] = _set_owner(item, opts)
            _history(item, "added")
            programme["items"][item_id] = item
            return payload
        item = programme["items"][key]
        if item["state"] in ("handed", "dropped"):
            raise RecordError(f"item {key!r} is {item['state']}; use answer-handed or reopen-item")
        seen["update"] = True
        payload = {"item": key, "title": item["title"]}
        if title:
            item["title"] = payload["title"] = title
        if kinds:
            payload.update(_apply_match(item, protocol, kinds))
        payload["owner_changed"] = _set_owner(item, opts)
        _history(item, "updated")
        return payload

    return host._write(opts, change, lambda payload: "item_updated" if seen.get("update") else "item_added")


def _rewrite_refs(programme, old_ids, new_id) -> None:
    olds = set(old_ids)
    model = programme["working_model"]
    for entry in model.get("queue") or []:
        if isinstance(entry, dict) and entry.get("item") in olds:
            entry["item"] = new_id
    doing = model.get("doing")
    if isinstance(doing, dict) and doing.get("item") in olds:
        doing["item"] = new_id
    for watcher in (programme.get("watchers") or {}).values():
        if isinstance(watcher, dict) and watcher.get("item") in olds:
            watcher["item"] = new_id
    for rule in programme.get("proposed_rules") or []:
        if isinstance(rule, dict) and isinstance(rule.get("items"), list):
            rule["items"] = list(dict.fromkeys(new_id if i in olds else i for i in rule["items"]))
    for entry in programme.get("instructions") or []:
        if isinstance(entry, dict) and entry.get("applies_to") in olds:
            entry["applies_to"] = new_id


def _unique(rows) -> list:
    out, seen = [], set()
    for row in rows:
        mark = json.dumps(row, sort_keys=True)
        if mark not in seen:
            seen.add(mark)
            out.append(row)
    return out


def _merge_deliverables(dst, src) -> dict:
    out = dict(dst)
    for name, entry in src.items():
        mine = out.get(name)
        rank = _EVIDENCE_RANK.get((entry or {}).get("result"), 0)
        if mine is None or rank > _EVIDENCE_RANK.get((mine or {}).get("result"), 0):
            out[name] = entry
    return out


def _merge_sessions(dst, src) -> list:
    known = {s.get("session_id") for s in dst if isinstance(s, dict)}
    return list(dst) + [s for s in src if not isinstance(s, dict) or s.get("session_id") not in known]


def _merge_into(programme, src_id, dst_id) -> None:
    items = programme["items"]
    src, dst = items.pop(src_id), items[dst_id]
    dst["aliases"] = [a for a in dict.fromkeys(dst["aliases"] + [src_id] + src["aliases"]) if a != dst_id]
    dst["sessions"] = _merge_sessions(dst["sessions"], src["sessions"])
    dst["task_runs"] = _unique(dst["task_runs"] + src["task_runs"])
    dst["deliverables"] = _merge_deliverables(dst["deliverables"], src["deliverables"])
    rules = list(dict.fromkeys((dst.get("matched_rule") or []) + (src.get("matched_rule") or [])))
    dst["matched_rule"] = rules or None
    for key in ("change_kinds", "requires"):
        dst[key] = list(dict.fromkeys((dst.get(key) or []) + (src.get(key) or [])))
    if not any(dst["owner"].values()):
        dst["owner"] = src["owner"]
    for key in ("title", "waiting_on", "tested_build"):
        if not dst.get(key) and src.get(key):
            dst[key] = src[key]
    dst["history"].extend(src["history"])
    _history(dst, "merged", source=src_id)
    _rewrite_refs(programme, [src_id] + src["aliases"], dst_id)


def _rename(programme, old_id, new_id) -> None:
    item = programme["items"].pop(old_id)
    item["id"] = new_id
    item["aliases"] = [a for a in dict.fromkeys(item["aliases"] + [old_id]) if a != new_id]
    _history(item, "aliased", source=old_id)
    programme["items"][new_id] = item
    _rewrite_refs(programme, [old_id], new_id)


def _h_alias_item(host, argv):
    positional, opts = host._parse(argv, values=("run",))
    if len(positional) != 2:
        raise ValueError("usage: alias-item <old-id> <new-id>")
    old_id, new_id = check_item_id(positional[0]), check_item_id(positional[1])

    def change(programme, prompt, rec):
        src = _resolve(programme, old_id)
        try:
            dst = _resolve(programme, new_id)
        except RecordError:
            dst = None
        if dst == src:
            raise RecordError(f"{old_id!r} and {new_id!r} are already one item")
        if dst is None:
            _rename(programme, src, new_id)
        else:
            _merge_into(programme, src, dst)
        return {"from": src, "to": dst or new_id, "merged": dst is not None}

    return host._write(opts, change, "item_aliased")


def _h_merge_item(host, argv):
    positional, opts = host._parse(argv, values=("run",))
    if len(positional) != 2:
        raise ValueError("usage: merge-item <from-id> <into-id>")
    from_id, into_id = check_item_id(positional[0]), check_item_id(positional[1])

    def change(programme, prompt, rec):
        src, dst = _resolve(programme, from_id), _resolve(programme, into_id)
        if src == dst:
            raise RecordError(f"{from_id!r} and {into_id!r} are already one item")
        _merge_into(programme, src, dst)
        return {"from": src, "into": dst}

    return host._write(opts, change, "item_merged")


def _issue_backed(item_id) -> bool:
    return item_id.split(":", 1)[0] != ISSUELESS_SOURCE


def _open_deliverables(item) -> list:
    return sorted(name for name, d in (item.get("deliverables") or {}).items()
                  if (d or {}).get("result") != "confirmed")


def _item_names(given, key) -> list:
    names = []
    for item_id in (given, key):
        for name in (item_id.split(":", 1)[-1], item_id):
            if name not in names:
                names.append(name)
    return names


def _h_drop_item(host, argv):
    positional, opts = host._parse(argv, values=("run", "reason", "prompt"))
    if len(positional) != 1:
        raise ValueError("usage: drop-item <id> --reason <text> [--prompt <id>]")
    item_id = check_item_id(positional[0])
    reason = _text(opts.get("reason"), "reason")

    def change(programme, prompt, rec):
        key = _resolve(programme, item_id)
        item = programme["items"][key]
        if item["state"] not in WAITABLE_STATES:
            raise RecordError(f"item {key!r} is {item['state']}; only an open or waiting item drops")
        still_open = _open_deliverables(item)
        host.require_named(prompt, _item_names(item_id, key))
        if _issue_backed(key) and still_open and not prompt:
            raise RecordError(
                f"item {key!r} is issue-backed with open deliverables {still_open}; "
                "dropping it needs --prompt <id> of a typed prompt")
        item.update(state="dropped", dropped_reason=reason, waiting_on=None)
        _history(item, "dropped", reason=reason, prompt_id=prompt and prompt["prompt_id"])
        return {"item": key, "reason": reason, "open_deliverables": still_open}

    return host._write(opts, change, "item_dropped", prompt_id=opts.get("prompt"))


def _h_reopen_item(host, argv):
    positional, opts = host._parse(argv, values=("run", "prompt"))
    if len(positional) != 1:
        raise ValueError("usage: reopen-item <id> --prompt <id>")
    item_id = check_item_id(positional[0])

    def change(programme, prompt, rec):
        key = _resolve(programme, item_id)
        item = programme["items"][key]
        if item["state"] != "dropped":
            raise RecordError(f"item {key!r} is {item['state']}, not dropped")
        host.require_named(prompt, _item_names(item_id, key))
        item.update(state="open", dropped_reason=None)
        _history(item, "reopened", prompt_id=prompt["prompt_id"])
        return {"item": key}

    return host._write(opts, change, "item_reopened", prompt_id=opts.get("prompt"), needs_prompt=True)


def _watcher_ids(opts) -> dict:
    pid = opts.get("process-id")
    if pid is not None and not _PID_RE.fullmatch(pid):
        raise RecordError(f"--process-id must be a number: {pid!r}")
    task_id = _token(opts.get("task-id"), "task-id")
    kind = opts.get("kind")
    if kind is not None and kind not in programme_home.WATCHER_KINDS:
        raise RecordError(f"--kind must be one of {', '.join(programme_home.WATCHER_KINDS)}: {kind!r}")
    if task_id and kind is None:
        kind = "cron" if opts.get("prompt") else "monitor"
    return {"process_id": pid, "task_id": task_id, "kind": kind if task_id else None}


def _upsert_watcher(programme, watcher_id, ids, item=None) -> dict:
    watchers = programme.setdefault("watchers", {})
    entry = dict(watchers.get(watcher_id) or {})
    for key, value in ids.items():
        if value is not None:
            entry[key] = value
    if item is not None:
        entry["item"] = item
    if any(ids.values()):
        entry["last_beat_at"] = _now()
    entry.setdefault("last_beat_at", None)
    watchers[watcher_id] = entry
    return entry


def _wait_spec(opts, watcher) -> dict:
    spec = {"who": _token(opts.get("who"), "who"), "watcher": watcher,
            "reporter": _token(opts.get("reporter"), "reporter")}
    if opts.get("blocker"):
        spec["kind"] = "blocker"
    for flag in ("trace-id", "job-id"):
        if opts.get(flag):
            spec[flag.replace("-", "_")] = _token(opts[flag], flag)
    if opts.get("due") is not None:
        if run_record_core.parse_iso(opts["due"]) is None:
            raise RecordError(f"--due must be an ISO time: {opts['due']!r}")
        spec["due_at"] = opts["due"]
    return spec


def _h_set_waiting(host, argv):
    positional, opts = host._parse(
        argv, values=("run", "who", "reporter", "watcher", "process-id", "task-id", "kind", "trace-id",
                      "job-id", "due"),
        flags=("blocker", "clear"))
    if len(positional) != 1:
        raise ValueError("usage: set-waiting <id> --who <name> [--watcher <id>] ... | --clear")
    if not opts.get("clear") and not opts.get("who"):
        raise ValueError("set-waiting needs --who <name> (or --clear)")
    item_id = check_item_id(positional[0])
    watcher = opts.get("watcher")
    if watcher is not None:
        watcher = programme_home.check_segment(watcher)
    ids = _watcher_ids(opts)

    def change(programme, prompt, rec):
        key = _resolve(programme, item_id)
        item = programme["items"][key]
        if item["state"] not in WAITABLE_STATES:
            raise RecordError(f"item {key!r} is {item['state']}; only an open or waiting item waits")
        if opts.get("clear"):
            item.update(state="open", waiting_on=None)
            _history(item, "wait_cleared")
            return {"item": key, "waiting_on": None}
        spec = _wait_spec(opts, watcher)
        if watcher is not None:
            _upsert_watcher(programme, watcher, ids, item=key)
        item.update(state="waiting", waiting_on=spec)
        _history(item, "waiting", who=spec["who"], watcher=watcher)
        return {"item": key, "waiting_on": spec}

    return host._write(opts, change, "item_waiting")


def _h_watcher_beat(host, argv):
    positional, opts = host._parse(argv, values=("run", "process-id", "task-id", "kind", "item", "prompt"))
    if len(positional) != 1:
        raise ValueError("usage: watcher-beat <watcher-id> [--process-id <n>|--task-id <id> [--kind cron|monitor]] "
                         "[--item <id>] [--prompt <cron prompt>]")
    watcher_id = programme_home.check_segment(positional[0])
    ids = _watcher_ids(opts)
    item_id = check_item_id(opts["item"]) if opts.get("item") else None
    cron_prompt = opts.get("prompt")
    if cron_prompt is not None and not (cron_prompt.strip() and len(cron_prompt) <= CRON_PROMPT_CAP):
        raise ValueError(f"--prompt must be the armed cron prompt, 1 to {CRON_PROMPT_CAP} characters")

    def change(programme, prompt, rec):
        known = (programme.get("watchers") or {}).get(watcher_id)
        if known is None and not any(ids.values()):
            raise RecordError(f"no watcher {watcher_id!r}; register it with --process-id or --task-id")
        item = _resolve(programme, item_id) if item_id else None
        entry = _upsert_watcher(programme, watcher_id, ids, item=item)
        entry["last_beat_at"] = _now()
        if cron_prompt is not None:
            entry["prompt"] = cron_prompt
        return {"watcher": watcher_id, "last_beat_at": entry["last_beat_at"]}

    return host._write(opts, change, "watcher_beat", compact_exempt=True, journal=False)


def _run_tool(argv):
    path = shutil.which(argv[0])
    if path is None:
        return None
    try:
        done = subprocess.run([path] + argv[1:], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL, timeout=NOTIFY_TIMEOUT_SECONDS, check=False)
    except subprocess.TimeoutExpired:
        return "timeout"
    except OSError:
        return None
    return done.returncode


def notify_handed(item_id, question) -> dict:
    source, _, key = item_id.partition(":")
    board = "skipped"
    if source == BOARD_SOURCE:
        board = _run_tool(["board", "mark", key, "needs_you"])
    herdr = None
    if board != 0:
        herdr = _run_tool(["herdr", "notification", "show", f"auto: {item_id} needs you",
                           "--body", question, "--sound", "request"])
    return {"board": board, "herdr": herdr}


def _h_hand_item(host, argv):
    positional, opts = host._parse(argv, values=("run", "question"))
    if len(positional) != 1:
        raise ValueError("usage: hand-item <id> --question <text>")
    item_id = check_item_id(positional[0])
    question = _text(opts.get("question"), "question")

    def change(programme, prompt, rec):
        key = _resolve(programme, item_id)
        item = programme["items"][key]
        if item["state"] not in WAITABLE_STATES:
            raise RecordError(f"item {key!r} is {item['state']}; only an open or waiting item is handed")
        item.update(state="handed", waiting_on=None,
                    handed={"at": _now(), "question": question, "answered": None})
        _history(item, "handed", question=question)
        return {"item": key, "question": question}

    def after(payload):
        return {"notify": notify_handed(payload["item"], question)}

    return host._write(opts, change, "item_handed", after=after)


def _h_answer_handed(host, argv):
    positional, opts = host._parse(argv, values=("run", "prompt", "choice", "repo"), multi=("kind",))
    if len(positional) != 1 or opts.get("choice") not in CHOICES:
        raise ValueError("usage: answer-handed <id> --choice ship|decline --prompt <id> [--kind <k>]...")
    item_id = check_item_id(positional[0])
    protocol = _load_protocol(host, opts.get("repo"))
    given = _check_kinds(protocol, opts["kind"])

    def change(programme, prompt, rec):
        key = _resolve(programme, item_id)
        item = programme["items"][key]
        if item["state"] != "handed":
            raise RecordError(f"item {key!r} is {item['state']}, not handed")
        host.require_named(prompt, _item_names(item_id, key))
        answered = {"at": _now(), "choice": opts["choice"], "prompt_id": prompt["prompt_id"]}
        item["handed"] = dict(item.get("handed") or {}, answered=answered)
        payload = {"item": key, "choice": opts["choice"]}
        if opts["choice"] == "decline":
            item.update(state="dropped", dropped_reason=f"declined by Shawn ({prompt['prompt_id']})")
        else:
            kinds = given or [k for k in item.get("change_kinds") or [] if k != "product_question"]
            if not kinds:
                raise RecordError(f"item {key!r} has no change kind to ship; pass --kind <change-kind>")
            payload.update(_apply_match(item, protocol, kinds))
            item["state"] = "open"
        _history(item, "answered", choice=opts["choice"], prompt_id=prompt["prompt_id"])
        return payload

    return host._write(opts, change, "handed_answered", prompt_id=opts.get("prompt"), needs_prompt=True)


def claims_path(home) -> str:
    return os.path.join(home, CLAIMS_NAME)


def claims_count(home) -> int:
    try:
        with open(claims_path(home), "rb") as fh:
            return sum(1 for _ in fh)
    except OSError:
        return 0


def _h_claim(host, argv):
    positional, opts = host._parse(argv, values=("run", "item", "deliverable", "ref"))
    if positional:
        raise ValueError("a claim is --item, --deliverable and --ref; free text is never a claim")
    for flag in ("item", "deliverable", "ref"):
        if not opts.get(flag):
            raise ValueError(f"claim needs --{flag}")
    item_id = check_item_id(opts["item"])
    ref = _token(opts["ref"], "ref")
    run_id, home, record = host._locate(opts)
    programme = programme_home.normalize_programme(record.get("programme") or {})
    if programme.get("ended"):
        raise RecordError("the programme has ended")
    key = _resolve(programme, item_id)
    deliverable = opts["deliverable"]
    if deliverable not in (programme["items"][key].get("deliverables") or {}):
        raise RecordError(f"{deliverable!r} is not a deliverable of {key!r}")
    sid = programme_sanitize.token(driver_session.driving_session_id() or "")
    payload = {"item": key, "deliverable": deliverable, "ref": ref}
    programme_journal.append_to(claims_path(home), "claim", sid, payload)
    host._emit({"ok": True, "run": run_id, "kind": "claim", **payload})
    return 0


def _h_mark_read(host, argv):
    _, opts = host._parse(argv, values=("run", "offset"))
    offset = opts.get("offset")
    if offset is not None and not _PID_RE.fullmatch(offset):
        raise ValueError("--offset must be a whole number")

    def change(programme, prompt, rec):
        size = claims_count(programme_home.home_path(rec["run_id"]))
        target = size if offset is None else int(offset)
        before = programme.get("inbox_offset") or 0
        if target > size or target < before:
            raise RecordError(f"offset {target} is outside the unread claims ({before}..{size})")
        programme["inbox_offset"] = target
        return {"from": before, "offset": target}

    return host._write(opts, change, "claims_read")


def _h_set_now(host, argv):
    positional, opts = host._parse(argv, values=("run", "item"), flags=("clear",))
    if opts.get("clear") == bool(positional) or len(positional) > 1:
        raise ValueError("usage: set-now <text> [--item <id>] | set-now --clear")
    text = None if opts.get("clear") else _text(positional[0], "text")
    item_id = check_item_id(opts["item"]) if opts.get("item") else None

    def change(programme, prompt, rec):
        key = _resolve(programme, item_id) if item_id else None
        doing = {"text": text, "item": key, "at": _now()} if text else None
        programme["working_model"]["doing"] = doing
        return {"doing": doing}

    return host._write(opts, change, "working_now")


def _h_queue(host, argv):
    positional, opts = host._parse(argv, values=("run", "action", "item", "why", "remove"))
    if positional or bool(opts.get("action")) == bool(opts.get("remove")):
        raise ValueError("usage: queue --action <name> [--item <id>] [--why <text>] | queue --remove <id>")
    if opts.get("action") and not _ACTION_RE.fullmatch(opts["action"]):
        raise ValueError(f"--action must be a lower_snake name: {opts['action']!r}")
    item_id = check_item_id(opts["item"]) if opts.get("item") else None
    why = _text(opts.get("why"), "why", required=False)

    def change(programme, prompt, rec):
        queue = programme["working_model"].setdefault("queue", [])
        if opts.get("remove"):
            kept = [e for e in queue if not (isinstance(e, dict) and e.get("id") == opts["remove"])]
            if len(kept) == len(queue):
                raise RecordError(f"no queue entry {opts['remove']!r}")
            programme["working_model"]["queue"] = kept
            return {"op": "remove", "id": opts["remove"]}
        entry = {"id": "q" + secrets.token_hex(3), "action": opts["action"],
                 "item": _resolve(programme, item_id) if item_id else None, "why": why, "at": _now()}
        queue.append(entry)
        return {"op": "add", "entry": entry}

    return host._write(opts, change, "queue_changed")


def _h_record_tested_build(host, argv):
    positional, opts = host._parse(argv, values=("run", "shasum", "package", "version"))
    if len(positional) != 1 or not opts.get("shasum"):
        raise ValueError("usage: record-tested-build <id> --shasum <sha> [--package <name>] [--version <v>]")
    item_id = check_item_id(positional[0])
    if not _SHASUM_RE.fullmatch(opts["shasum"]):
        raise RecordError(f"--shasum must be a hex sha1/sha256 or an sha integrity string: {opts['shasum']!r}")
    build = {"shasum": opts["shasum"], "package": _token(opts.get("package"), "package"),
             "version": _token(opts.get("version"), "version")}

    def change(programme, prompt, rec):
        key = _resolve(programme, item_id)
        item = programme["items"][key]
        item["tested_build"] = dict(build, at=_now())
        _history(item, "tested_build", shasum=build["shasum"])
        return dict(build, item=key)

    return host._write(opts, change, "tested_build_recorded")


def _h_set_source(host, argv):
    positional, opts = host._parse(argv, values=("run", "watcher"),
                                   flags=("available", "unavailable", "unsupported"))
    if len(positional) != 1 or positional[0] not in SOURCES:
        raise ValueError(f"usage: set-source <{'|'.join(SOURCES)}> --available|--unavailable|--unsupported")
    states = [flag for flag in SOURCE_STATES if opts.get(flag)]
    if len(states) != 1:
        raise ValueError("set-source needs exactly one of --available, --unavailable or --unsupported")
    name, state = positional[0], states[0]
    watcher = programme_home.check_segment(opts["watcher"]) if opts.get("watcher") else None

    def change(programme, prompt, rec):
        sources = programme.setdefault("sources", {})
        entry = dict(sources.get(name) or {})
        if state == "unavailable":
            entry["unavailable_since"] = entry.get("unavailable_since") or _now()
        else:
            entry["unavailable_since"] = None
        if state == "unsupported":
            entry["unsupported_since"] = entry.get("unsupported_since") or _now()
        else:
            entry["unsupported_since"] = None
        if watcher is not None:
            entry["watcher"] = watcher
        sources[name] = entry
        return {"source": name, "state": state, "unavailable_since": entry["unavailable_since"],
                "unsupported_since": entry["unsupported_since"], "watcher": entry.get("watcher")}

    return host._write(opts, change, "source_changed")


_SPECS = (
    ("add-item", _h_add_item,
     "<source:key> [--title <text>] [--kind <change-kind>]... [--repo <path>] [--pane <id>] "
     "[--terminal-id <id>] [--session <id>] [--session-name <name>] [--run <id>]",
     "an id that is not source:key or holds '..', spaces or control text; an unknown change kind; "
     "a handed or dropped item."),
    ("alias-item", _h_alias_item, "<old-id> <new-id> [--run <id>]",
     "an unknown old id; ids that are already one item. An existing new id merges the two."),
    ("merge-item", _h_merge_item, "<from-id> <into-id> [--run <id>]",
     "an unknown id; an item merged into itself."),
    ("drop-item", _h_drop_item, "<id> --reason <text> [--prompt <id>] [--run <id>]",
     "no --reason; a finished item; an issue-backed item with open deliverables without a typed prompt; "
     "a prompt whose text does not name the item id or key."),
    ("reopen-item", _h_reopen_item, "<id> --prompt <id> [--run <id>]",
     "no typed prompt, or one whose text does not name the item id or key; an item that is not dropped."),
    ("set-waiting", _h_set_waiting,
     "<id> --who <name> [--reporter <name>] [--watcher <id> [--process-id <n>] [--task-id <id> "
     "[--kind cron|monitor]]] "
     "[--blocker] [--trace-id <id>] [--job-id <id>] [--due <iso>] [--run <id>] | <id> --clear",
     "no --who; a finished item; a watcher id that is not a safe name; a --due that is not an ISO time."),
    ("watcher-beat", _h_watcher_beat,
     "<watcher-id> [--process-id <n>|--task-id <id> [--kind cron|monitor]] [--item <id>] "
     "[--prompt <cron prompt>] [--run <id>]",
     "an unknown watcher with no process or task id; a --kind other than cron or monitor; an empty or "
     "overlong --prompt. A task id is a cron watcher when --prompt is given and a Monitor otherwise, "
     "unless --kind says which. --prompt stores the "
     "armed cron prompt verbatim, so a prompt that equals it is journaled with origin cron. "
     "Exempt from the compact flag; not journaled."),
    ("hand-item", _h_hand_item, "<id> --question <text> [--run <id>]",
     "a handed or finished item (it notifies once)."),
    ("answer-handed", _h_answer_handed,
     "<id> --choice ship|decline --prompt <id> [--kind <change-kind>]... [--repo <path>] [--run <id>]",
     "no typed prompt, or one whose text does not name the item id or key; an item that is not handed; "
     "ship with no change kind."),
    ("claim", _h_claim, "--run <id> --item <id> --deliverable <name> --ref <reference>",
     "free text; a reference with spaces; an unknown item or a deliverable the item does not "
     "require; an ended programme. Open to any session and exempt from the compact flag."),
    ("mark-read", _h_mark_read, "[--offset <n>] [--run <id>]",
     "an offset past the inbox or behind the current read offset."),
    ("set-now", _h_set_now, "<text> [--item <id>] [--run <id>] | --clear",
     "both text and --clear, or neither."),
    ("queue", _h_queue, "--action <name> [--item <id>] [--why <text>] [--run <id>] | --remove <entry-id>",
     "an action that is not lower_snake; an unknown entry id."),
    ("record-tested-build", _h_record_tested_build,
     "<id> --shasum <sha> [--package <name>] [--version <v>] [--run <id>]",
     "a shasum that is not hex sha1/sha256 or an sha integrity string."),
    ("set-source", _h_set_source,
     "herdr|board|linear --available|--unavailable|--unsupported [--watcher <id>] [--run <id>]",
     "an unknown source; more than one state flag or none. --unsupported marks a source this "
     "machine cannot read (a missing tool or plugin op); it never holds the stop."),
)


def build_verbs(host) -> dict:
    return {name: host._Verb(functools.partial(handler, host), args, rejects=rejects)
            for name, handler, args, rejects in _SPECS}
