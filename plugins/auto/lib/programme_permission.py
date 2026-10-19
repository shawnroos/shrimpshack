#!/usr/bin/env python3
"""Programme permission proposals: one shared, typed-answerable proposal per blocked read.

Programme never writes a settings file. A proposal names a native allow rule for
Shawn to apply; denials count only when the session's own transcript confirms them.
"""

from __future__ import annotations

import functools
import json
import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

run_record_core = load_lib_module("run_record_core")
programme_home = load_lib_module("programme_home")
programme_journal = load_lib_module("programme_journal")
programme_sanitize = load_lib_module("programme_sanitize")
programme_permission_rules = load_lib_module("programme_permission_rules")
programme_record = load_lib_module("programme_record")
session_registry = load_lib_module("session_registry")
driver_session = load_lib_module("driver_session")

RecordError = programme_record.RecordError

BLOCKS_NAME = "blocks.jsonl"
COMMAND_CAP = 2000
REASON_CAP = 300
EVIDENCE_CAP = 50
TRANSCRIPT_CAP = 64 * 1024 * 1024
OPEN = "open"
QUIET_STATES = ("postponed", "rejected")
ASKING_STATES = ("open", "ineffective", "retry_unobserved")
RESOLVED = "resolved"
RETRYING = "retrying"
CHOICE_WORDS = {
    "applied": ("applied", "apply"),
    "not-now": ("not now", "later", "postpone", "postponed"),
    # "no" itself is a negation word, so the typed text must say reject or decline.
    "no": ("reject", "rejected", "decline", "declined"),
}
DECLINED_STATE = {"not-now": "postponed", "no": "rejected"}


def _now() -> str:
    return run_record_core.now_iso()


def _proposals(programme) -> list:
    found = programme.setdefault("permission_proposals", [])
    return [p for p in found if isinstance(p, dict)]


def _find(programme, proposal_id) -> dict:
    for proposal in _proposals(programme):
        if proposal.get("id") == proposal_id:
            return proposal
    raise RecordError(f"no permission proposal {proposal_id!r} in this programme")


def blocks_path(home) -> str:
    return os.path.join(home, BLOCKS_NAME)


def _transcript_rows(path):
    with open(path, "rb") as fh:
        data = fh.read(TRANSCRIPT_CAP + 1)
    if len(data) > TRANSCRIPT_CAP:
        return []
    rows = []
    for line in data.splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if isinstance(row, dict):
            rows.append(row)
    return rows


def _blocks(row, kind) -> list:
    content = (row.get("message") or {}).get("content") if isinstance(row.get("message"), dict) else None
    return [b for b in content if isinstance(b, dict) and b.get("type") == kind] if isinstance(content, list) else []


def runtime_ruling(row) -> dict:
    found = row.get("permissionDecision") if isinstance(row.get("permissionDecision"), dict) else {}
    ruling = found.get("decision")
    return {"ruling": ruling if ruling in ("accept", "reject") else None,
            "reason_type": programme_sanitize.token(found.get("reasonType")),
            "denial_kind": programme_sanitize.token(row.get("toolDenialKind"))}


def confirm(row, decision="reject"):
    payload = row.get("payload") if isinstance(row.get("payload"), dict) else {}
    sid, tool_use_id, path = row.get("session_id"), payload.get("tool_use_id"), payload.get("transcript_path")
    if not (isinstance(sid, str) and sid and isinstance(tool_use_id, str) and tool_use_id):
        return None
    # The registry's path, never the row's alone: a forged row could name a transcript its author wrote.
    known = (session_registry.lookup(sid, include_headless=True) or {}).get("transcript_path")
    if not isinstance(path, str) or path != known or os.path.basename(path) != sid + ".jsonl":
        return None
    try:
        rows = _transcript_rows(path)
    except OSError:
        return None
    command, found = None, None
    for entry in rows:
        if entry.get("type") == "assistant":
            for block in _blocks(entry, "tool_use"):
                if block.get("id") == tool_use_id and block.get("name") == "Bash":
                    command = (block.get("input") or {}).get("command")
        elif entry.get("type") == "user" and command is not None:
            if any(b.get("tool_use_id") == tool_use_id for b in _blocks(entry, "tool_result")):
                found = runtime_ruling(entry)["ruling"]
    if not isinstance(command, str) or found != decision:
        return None
    if programme_journal.redact(command)[:COMMAND_CAP] != payload.get("command"):
        return None
    return command


def _denial_rows(run_id, tool_use_ids) -> dict:
    rows = {}
    for row in programme_journal.read(run_id):
        payload = row.get("payload") if isinstance(row.get("payload"), dict) else {}
        if row.get("kind") == "permission_denied" and payload.get("tool_use_id") in tool_use_ids:
            rows[payload["tool_use_id"]] = row
    missing = [t for t in tool_use_ids if t not in rows]
    if missing:
        raise RecordError(f"no permission_denied row with tool_use_id {missing}")
    return rows


def _on_item(item, sid) -> bool:
    if (item.get("owner") or {}).get("session_id") == sid:
        return True
    return any(isinstance(s, dict) and s.get("session_id") == sid for s in item.get("sessions") or [])


def _explain(item, cause, detail=None, *, proposal=None, unconfirmed=None, reports=None) -> None:
    block = dict(item.get("permission_block") or {})
    block.setdefault("proposals", [])
    block.setdefault("unconfirmed", [])
    if not (cause == "unconfirmed" and block.get("cause")):
        block.update(cause=cause, detail=detail)
    block["at"] = _now()
    if proposal and proposal not in block["proposals"]:
        block["proposals"].append(proposal)
    if unconfirmed and unconfirmed not in block["unconfirmed"]:
        block["unconfirmed"].append(unconfirmed)
    if reports is not None:
        block["reports"] = reports
    item["permission_block"] = block


def _new_proposal(programme, ops, dest) -> dict:
    numbers = [int(p["id"][5:]) for p in _proposals(programme)
               if isinstance(p.get("id"), str) and p["id"][:5] == "perm-" and p["id"][5:].isdigit()]
    proposal = {"id": f"perm-{max(numbers, default=0) + 1}", "destination": dest["main"],
                "settings_file": dest["file"], "items": [], "evidence": [], "state": OPEN,
                "created_at": _now(), "changed_at": _now(), "notified_at": None,
                "explanation": None, "answers": [], "confirmed": None}
    _render(proposal, ops)
    programme["permission_proposals"].append(proposal)
    return proposal


def _render(proposal, ops) -> None:
    rendered = programme_permission_rules.render_proposal(ops)
    proposal.update(operations=rendered["operations"], rules=rendered["rules"], reach=rendered["reach"],
                    exclusions=rendered["exclusions"],
                    key={"operations": rendered["operations"], "destination": proposal["destination"]})


def _attach(proposal, evidence, item_keys) -> None:
    proposal["items"] = list(dict.fromkeys((proposal.get("items") or []) + item_keys))
    if any(e.get("tool_use_id") == evidence["tool_use_id"] for e in proposal.get("evidence") or []):
        return
    proposal["evidence"] = (proposal.get("evidence") or [])[-(EVIDENCE_CAP - 1):] + [evidence]
    if proposal.get("state") == RESOLVED:
        proposal.update(redenied_at=_now(), explanation="denied again after it resolved; the applied rule "
                                                        "may have been removed or narrowed")


def _place(programme, ops, dest, evidence, item_keys) -> tuple:
    mine = [p for p in _proposals(programme) if p.get("destination") == dest["main"]]
    decided = [p for p in mine if p.get("state") != OPEN]
    touched, asking = [], None
    for proposal in decided:
        if set(proposal.get("operations") or []) & set(ops):
            _attach(proposal, evidence, item_keys)
            touched.append(proposal["id"])
    rest = programme_permission_rules.broader_by(ops, [p.get("operations") or [] for p in decided])
    if rest:
        asking = next((p for p in mine if p.get("state") == OPEN), None)
        if asking is None:
            asking = _new_proposal(programme, rest, dest)
        elif set(rest) - set(asking["operations"]):
            _render(asking, sorted(set(asking["operations"]) | set(rest)))
            asking.update(notified_at=None, changed_at=_now())
        _attach(asking, evidence, item_keys)
        touched.append(asking["id"])
    return touched, asking


def _wait_on_shawn(item, proposal_id) -> None:
    if item["state"] not in programme_record.WAITABLE_STATES or \
            (item.get("waiting_on") or {}).get("permission") == proposal_id:
        return
    item.update(state="waiting", waiting_on={"who": "shawn", "reporter": "shawn", "watcher": None,
                                             "permission": proposal_id})
    programme_record._history(item, "waiting", who="shawn", permission=proposal_id)


def _evidence(row, verdict, item_keys) -> dict:
    payload = row.get("payload") or {}
    return {"tool_use_id": payload.get("tool_use_id"), "session_id": row.get("session_id"),
            "at": row.get("at"), "operations": verdict["operations"], "command": verdict["normalized"],
            "reason": programme_sanitize.clean(payload.get("reason"), REASON_CAP) or None,
            "layer": programme_sanitize.token(payload.get("layer")), "items": item_keys}


def _destinations(programme, keys) -> dict:
    remit = [r.get("path") for r in programme["remit"].get("repos") or [] if isinstance(r, dict)]
    groups = {}
    for key in keys:
        item = programme["items"][key]
        if not item.get("repo"):
            _explain(item, "no_repo", "the item has no recorded repository; set it with add-item --repo")
            continue
        dest = programme_permission_rules.destination(item["repo"], remit)
        if not dest["ok"]:
            _explain(item, "bad_destination", dest["reason"])
            continue
        groups.setdefault(dest["main"], (dest, []))[1].append(key)
    return groups


def _propose_one(programme, row, keys) -> list:
    sid = row.get("session_id")
    tool_use_id = row["payload"]["tool_use_id"]
    command = confirm(row)
    if command is None:
        for key in keys:
            _explain(programme["items"][key], "unconfirmed",
                     "a denial row has no matching transcript entry", unconfirmed=tool_use_id)
        return []
    verdict = programme_permission_rules.eligibility(command)
    touched = []
    for dest, group in _destinations(programme, keys).values():
        if not verdict["eligible"]:
            for key in group:
                _explain(programme["items"][key], "ineligible", f"{verdict['kind']}: {verdict['subject']}")
            continue
        ids, asking = _place(programme, verdict["operations"], dest, _evidence(row, verdict, group), group)
        for key in group:
            item = programme["items"][key]
            for proposal_id in ids:
                _explain(item, "proposal" if asking else "decided", ", ".join(ids), proposal=proposal_id)
            if asking:
                _wait_on_shawn(item, asking["id"])
        touched += ids
    return touched


def _reports(home, keys) -> dict:
    counts = {}
    for row in programme_journal.read_path(blocks_path(home)):
        key = (row.get("payload") or {}).get("item")
        if key in keys:
            counts[key] = counts.get(key, 0) + 1
    return counts


def _h_propose_permission(host, argv):
    positional, opts = host._parse(argv, values=("run",), multi=("item", "denial"))
    if positional or (opts["denial"] and not opts["item"]):
        raise ValueError("usage: propose-permission [--item <id>]... [--denial <tool_use_id>]...")
    item_ids = [programme_record.check_item_id(i) for i in opts["item"]]
    run_id, home, _ = host._locate(opts)
    rows = _denial_rows(run_id, opts["denial"])

    def change(programme, prompt, rec):
        programme.setdefault("permission_proposals", [])
        keys = list(dict.fromkeys(programme_record._resolve(programme, i) for i in item_ids))
        linked = {}
        for tool_use_id, row in rows.items():
            on = [k for k in keys if _on_item(programme["items"][k], row.get("session_id"))]
            if not on:
                raise RecordError(
                    f"denial {tool_use_id!r} is from session {row.get('session_id')!r}, which is not on "
                    f"{keys}; relink the owner with add-item <id> --session <id>")
            linked[tool_use_id] = on
        touched = []
        for tool_use_id, row in rows.items():
            touched += _propose_one(programme, row, linked[tool_use_id])
        unlinked = [k for k in keys if not any(k in on for on in linked.values())]
        for key, count in _reports(home, unlinked).items():
            _explain(programme["items"][key], "unknown_cause",
                     f"{count} worker reports and no runtime denial record; the denying layer is unknown",
                     reports=count)
        return {"items": keys, "denials": sorted(rows), "proposals": sorted(set(touched))}

    def after(payload):
        return {"notify": notify_pending(run_id, home)}

    return host._write(opts, change, "permission_proposed", after=after)


def _notify(proposal):
    body = (f"Allow {', '.join(proposal.get('rules') or [])} in {proposal.get('settings_file')} "
            f"for {len(proposal.get('items') or [])} items. Answer: applied, not now, or reject "
            f"{proposal.get('id')}.")
    return programme_record._run_tool(["herdr", "notification", "show",
                                       f"auto: permission {proposal.get('id')} needs you",
                                       "--body", body, "--sound", "request"])


def notify_pending(run_id, home) -> dict:
    record = run_record_core.read_run_record(home, run_id)
    programme = programme_home.normalize_programme(record.get("programme") or {})
    due = [p for p in _proposals(programme) if p.get("state") == OPEN and not p.get("notified_at")]
    results = {p["id"]: _notify(p) for p in due}
    sent = {pid for pid, code in results.items() if code == 0}
    if sent:
        def stamp(rec):
            for proposal in (rec.get("programme") or {}).get("permission_proposals") or []:
                if isinstance(proposal, dict) and proposal.get("id") in sent and not proposal.get("notified_at"):
                    proposal["notified_at"] = _now()

        run_record_core._with_locked_run_record(home, run_id, stamp)
    return results


def _h_report_block(host, argv):
    positional, opts = host._parse(argv, values=("run", "item", "command"))
    if positional:
        raise ValueError("a block report is --item and --command; free text is never a report")
    for flag in ("item", "command"):
        if not opts.get(flag):
            raise ValueError(f"report-block needs --{flag}")
    item_id = programme_record.check_item_id(opts["item"])
    run_id, home, record = host._locate(opts)
    programme = programme_home.normalize_programme(record.get("programme") or {})
    if programme.get("ended"):
        raise RecordError("the programme has ended")
    key = programme_record._resolve(programme, item_id)
    verdict = programme_permission_rules.eligibility(opts["command"])
    payload = {"item": key, "operations": verdict.get("operations"),
               "refusal": None if verdict["eligible"] else verdict["kind"],
               "command_hash": host.text_hash(verdict.get("normalized") or opts["command"])}
    sid = programme_sanitize.token(driver_session.driving_session_id() or "")
    programme_journal.append_to(blocks_path(home), "permission_block_reported", sid, payload)
    host._emit({"ok": True, "run": run_id, "kind": "permission_block_reported", **payload})
    return 0


def _choices_named(host, prompt) -> set:
    words = host._name_words(programme_journal.redact(prompt["quote"]))
    return {choice for choice, options in CHOICE_WORDS.items()
            if any(host._affirmed(words, start) for option in options
                   for start, _ in host._runs(words, host._squash(option)))}


def _gate(host, proposal, choice, prompt) -> None:
    host.require_named(prompt, proposal["id"])
    named = _choices_named(host, prompt)
    if named != {choice}:
        raise RecordError(
            f"prompt {prompt['prompt_id']!r} must give exactly one answer for {proposal['id']}: "
            f"{' or '.join(CHOICE_WORDS[choice])} for {choice} (it names {sorted(named) or 'none'})")
    typed_at = run_record_core.parse_iso(prompt.get("at"))
    changed_at = run_record_core.parse_iso(proposal.get("changed_at"))
    if typed_at is None or changed_at is None or typed_at <= changed_at:
        raise RecordError(f"prompt {prompt['prompt_id']!r} is older than {proposal['id']}'s last state change")
    if any(a.get("prompt_id") == prompt["prompt_id"] for a in proposal.get("answers") or []):
        raise RecordError(f"prompt {prompt['prompt_id']!r} already answered {proposal['id']}")


def _record_answer(proposal, choice, prompt, state) -> dict:
    before = proposal["state"]
    proposal.setdefault("answers", []).append({"at": _now(), "choice": choice, "prompt_id": prompt["prompt_id"],
                                               "from": before, "to": state})
    if state != before:
        proposal.update(state=state, changed_at=_now())
    return {"proposal": proposal["id"], "choice": choice, "state": state, "from": before}


def _settle_module():
    return load_lib_module("programme_permission_settle")


def _answer_declined(programme, proposal, choice, prompt, live) -> dict:
    state = proposal.get("state")
    if state in ASKING_STATES:
        return _record_answer(proposal, choice, prompt, DECLINED_STATE[choice])
    if state in QUIET_STATES:
        return _record_answer(proposal, choice, prompt, state)
    if state == RETRYING:
        return _settle_module().defer_answer(proposal, choice, prompt)
    raise RecordError(f"{proposal['id']} is {state}; Programme no longer asks about it")


def apply_answer(programme, proposal, choice, prompt, live) -> dict:
    return _settle_module().apply_answer(programme, proposal, choice, prompt, live)


ANSWERS = {"applied": apply_answer, "not-now": _answer_declined, "no": _answer_declined}


def _h_answer_permission(host, argv):
    positional, opts = host._parse(argv, values=("run", "prompt"))
    if len(positional) != 2 or positional[1] not in ANSWERS:
        raise ValueError("usage: answer-permission <perm-id> applied|not-now|no --prompt <id>")
    proposal_id, choice = positional
    _, _, record = host._locate(opts)
    live = _settle_module().live_item(record, proposal_id) if choice == "applied" else None

    def change(programme, prompt, rec):
        proposal = _find(programme, proposal_id)
        _gate(host, proposal, choice, prompt)
        return ANSWERS[choice](programme, proposal, choice, prompt, live)

    def kind(payload):
        return "permission_verified" if payload.get("verify") else "permission_answered"

    return host._write(opts, change, kind, prompt_id=opts.get("prompt"), needs_prompt=True)


def _needs_eyes(proposal) -> bool:
    return proposal.get("state") == RESOLVED and (proposal.get("confirmed") is False
                                                   or bool(proposal.get("redenied_at")))


def in_force(programme) -> list:
    out = []
    for proposal in _proposals(programme):
        if proposal.get("state") == RESOLVED and not _needs_eyes(proposal):
            continue
        out.append({k: proposal.get(k) for k in ("id", "state", "rules", "settings_file", "items", "confirmed")})
    return out


def asking(programme) -> list:
    return [p for p in _proposals(programme) if p.get("state") in ASKING_STATES or _needs_eyes(p)]


_SPECS = (
    ("propose-permission", _h_propose_permission,
     "[--item <id>]... [--denial <tool_use_id>]... [--run <id>]",
     "a denial with no permission_denied row; a denial whose session is not the owner or a listed "
     "session of any given item (relink with add-item --session). A denial the session's transcript "
     "does not confirm is ignored and counted on the item. An item with no recorded repo, a destination "
     "outside the remit, or an ineligible command gets an explanation instead of a proposal. Re-sends "
     "open proposals not yet notified."),
    ("report-block", _h_report_block, "--run <id> --item <id> --command <text>",
     "free text; no --item or --command; an unknown item; an ended programme. Stores operation ids "
     "and a command hash, never the text. Open to any session and exempt from the compact flag."),
    ("answer-permission", _h_answer_permission, "<perm-id> applied|not-now|no --prompt <id> [--run <id>]",
     "no typed prompt; a prompt that does not name the proposal id, or does not say exactly one of "
     "applied/apply, not now/later/postpone, reject/decline matching the choice; a prompt older than the "
     "proposal's last state change; a prompt an earlier answer cited; any answer on a resolved proposal. "
     "applied reads the user, main-checkout local and worktree settings files read-only and reserves one "
     "retry only when every blocked command is covered; applied while retrying changes nothing; not-now "
     "or no while retrying applies after the outcome."),
)


def build_verbs(host) -> dict:
    verbs = {name: host._Verb(functools.partial(handler, host), args, rejects=rejects)
             for name, handler, args, rejects in _SPECS}
    verbs.update(_settle_module().build_verbs(host))
    return verbs
