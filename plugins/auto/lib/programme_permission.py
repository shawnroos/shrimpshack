#!/usr/bin/env python3
"""Programme permission proposals: one shared, typed-answerable proposal per blocked read.

Programme never writes a settings file. A proposal names a native allow rule for
Shawn to apply. Refusals come only from the item sessions' own transcripts.
"""

from __future__ import annotations

import functools
import os
import sys

_LIB_DIR = os.path.dirname(os.path.abspath(__file__))
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)
from _bootstrap import load_lib_module  # noqa: E402

run_record_core = load_lib_module("run_record_core")
programme_home = load_lib_module("programme_home")
programme_journal = load_lib_module("programme_journal")
programme_record = load_lib_module("programme_record")
rules = load_lib_module("programme_permission_rules")
state = load_lib_module("programme_permission_state")
transcript = load_lib_module("permission_transcript")
settle = load_lib_module("programme_permission_settle")

RecordError = programme_record.RecordError

EVIDENCE_CAP = 50
CHOICE_WORDS = {
    "applied": ("applied", "apply"),
    "not-now": ("not now", "later", "postpone", "postponed"),
    # "no" itself is a negation word, so the typed text must say reject or decline.
    "no": ("reject", "rejected", "decline", "declined"),
}


def _joined(item, sid):
    times = [run_record_core.parse_iso(s.get("at")) for s in item.get("sessions") or []
             if isinstance(s, dict) and s.get("session_id") == sid]
    return min((t for t in times if t), default=None)


def _refusals(item, sid):
    """(rejected Bash uses since the item's scan cursor, why unread); uses is None when nothing was read.

    Only uses ruled after sid joined the item count, so a session's earlier history is never replayed.
    """
    path, joined = transcript.path_for(sid), _joined(item, sid)
    end = transcript.size(path) if path else None
    if end is None or joined is None:
        return None, "no transcript in the session registry"
    cursor = item.setdefault("permission_scan", {})
    start = cursor.get(sid, 0) if cursor.get(sid, 0) <= end else 0
    found = transcript.tool_uses(path, start)
    if found is None:
        return None, f"its transcript is unreadable or grew by more than {transcript.TRANSCRIPT_CAP} bytes"
    uses, read_to = found
    # A use still waiting for its result row is read again next time.
    cursor[sid] = min((u["offset"] for u in uses if not u["answered"]), default=read_to)
    return [u for u in uses if u["ruling"] == "reject" and u["at"] and u["at"] >= joined], None


def _new_proposal(programme, ops, dest) -> dict:
    numbers = [int(p["id"][5:]) for p in state.proposals(programme)
               if isinstance(p.get("id"), str) and p["id"][:5] == "perm-" and p["id"][5:].isdigit()]
    proposal = {"id": f"perm-{max(numbers, default=0) + 1}", "destination": dest["main"],
                "settings_file": dest["file"], "items": [], "evidence": [], "state": state.OPEN,
                "created_at": run_record_core.now_iso(), "changed_at": run_record_core.now_iso(),
                "notified_at": None, "explanation": None, "answers": [], "confirmed": None}
    _render(proposal, ops)
    programme["permission_proposals"].append(proposal)
    return proposal


def _render(proposal, ops) -> None:
    rendered = rules.render_proposal(ops)
    proposal.update(operations=rendered["operations"], rules=rendered["rules"], reach=rendered["reach"],
                    exclusions=rendered["exclusions"],
                    key={"operations": rendered["operations"], "destination": proposal["destination"]})


def _attach(proposal, evidence, item_keys) -> None:
    proposal["items"] = list(dict.fromkeys((proposal.get("items") or []) + item_keys))
    if any(e.get("tool_use_id") == evidence["tool_use_id"] for e in proposal.get("evidence") or []):
        return
    proposal["evidence"] = (proposal.get("evidence") or [])[-(EVIDENCE_CAP - 1):] + [evidence]
    if proposal.get("state") == state.RESOLVED:
        proposal.update(redenied_at=run_record_core.now_iso(),
                        explanation="denied again after it resolved; the applied rule may have been removed "
                                    "or narrowed")


def _place(programme, ops, dest, evidence, item_keys) -> tuple:
    mine = [p for p in state.proposals(programme) if p.get("destination") == dest["main"]]
    decided = [p for p in mine if p.get("state") != state.OPEN]
    touched, asking = [], None
    for proposal in decided:
        if set(proposal.get("operations") or []) & set(ops):
            _attach(proposal, evidence, item_keys)
            touched.append(proposal["id"])
    rest = rules.broader_by(ops, [p.get("operations") or [] for p in decided])
    if rest:
        asking = next((p for p in mine if p.get("state") == state.OPEN), None)
        if asking is None:
            asking = _new_proposal(programme, rest, dest)
        elif set(rest) - set(asking["operations"]):
            _render(asking, sorted(set(asking["operations"]) | set(rest)))
            asking.update(notified_at=None, changed_at=run_record_core.now_iso())
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


def _destination(programme, key):
    item = programme["items"][key]
    if not item.get("repo"):
        state.note(item, "no_repo", "the item has no recorded repository; set it with add-item --repo")
        return None
    remit = [r.get("path") for r in programme["remit"].get("repos") or [] if isinstance(r, dict)]
    dest = rules.destination(item["repo"], remit)
    if not dest["ok"]:
        state.note(item, "bad_destination", dest["reason"])
        return None
    return dest


def _propose_one(programme, key, sid, use) -> list:
    item = programme["items"][key]
    layer = transcript.layer(use)
    if layer not in transcript.PROPOSABLE:
        why = transcript.NEXT_ACTION.get(layer, "the transcript names no layer Programme knows, so no rule "
                                                "is proposed")
        state.note(item, "unknown_cause" if layer == "unknown" else "not_proposable",
                   f"refused by {layer} (reasonType {use['reason_type'] or 'none'}); {why}")
        return []
    verdict = rules.eligibility(use["command"])
    if not verdict["eligible"]:
        state.note(item, "ineligible", f"{verdict['kind']}: {verdict['subject']}")
        return []
    dest = _destination(programme, key)
    if dest is None:
        return None
    evidence = {"tool_use_id": use["tool_use_id"], "session_id": sid,
                "at": use["at"].strftime("%Y-%m-%dT%H:%M:%SZ"), "operations": verdict["operations"],
                "command": verdict["normalized"], "layer": layer, "reason_type": use["reason_type"],
                "items": [key]}
    ids, asking = _place(programme, verdict["operations"], dest, evidence, [key])
    for proposal_id in ids:
        state.note(item, "proposal" if asking else "decided", ", ".join(ids), proposal=proposal_id)
    if asking:
        _wait_on_shawn(item, asking["id"])
    return ids


def _scan(programme, key, named) -> list:
    item, touched, unread, found = programme["items"][key], [], [], 0
    for sid in programme_home.session_ids(item):
        uses, why = _refusals(item, sid)
        if uses is None:
            unread.append(f"{sid}: {why}")
            if not named and "registry" not in why:
                state.note(item, "unknown_cause", f"session {sid}: {why}; its refusals were not read")
            continue
        found += len(uses)
        for use in uses:
            ids = _propose_one(programme, key, sid, use)
            if ids is None:
                # A missing repo or destination can be fixed; read this refusal again after it is.
                item["permission_scan"][sid] = min(item["permission_scan"][sid], use["offset"])
                continue
            touched += ids
    if named and not found and not (item.get("permission_block") or {}).get("proposals"):
        why = f"unread ({'; '.join(unread)})" if unread else "no refusal in its sessions' transcripts"
        state.note(item, "unknown_cause", f"reported blocked, but {why}; the denying layer is unknown")
    return touched


def _h_propose_permission(host, argv):
    positional, opts = host._parse(argv, values=("run",), multi=("item",))
    if positional:
        raise ValueError("usage: propose-permission [--item <id>]... [--run <id>]")
    item_ids = [programme_record.check_item_id(i) for i in opts["item"]]
    run_id, home, _ = host._locate(opts)

    def change(programme, prompt, rec):
        programme.setdefault("permission_proposals", [])
        keys = list(dict.fromkeys(programme_record._resolve(programme, i) for i in item_ids)) or \
            sorted(k for k, i in programme["items"].items()
                   if i.get("state") not in programme_home.FINISHED_ITEM_STATES)
        touched = []
        for key in keys:
            touched += _scan(programme, key, named=bool(item_ids))
        return {"items": keys, "proposals": sorted(set(touched))}

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
    due = [p for p in state.proposals(programme) if p.get("state") == state.OPEN and not p.get("notified_at")]
    results = {p["id"]: _notify(p) for p in due}
    sent = {pid for pid, code in results.items() if code == 0}
    if sent:
        def stamp(rec):
            for proposal in state.proposals(rec.get("programme") or {}):
                if proposal.get("id") in sent and not proposal.get("notified_at"):
                    proposal["notified_at"] = run_record_core.now_iso()

        run_record_core._with_locked_run_record(home, run_id, stamp)
    return results


def _choices_named(host, prompt) -> set:
    words = host._name_words(programme_journal.named_text(prompt))
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


def _answer(programme, proposal, choice, prompt, live) -> dict:
    nxt = state.step(proposal, choice)
    if nxt == state.VERIFY:
        return settle.apply_answer(programme, proposal, choice, prompt, live)
    out = state.record_answer(proposal, choice, prompt, state.RETRYING if nxt == state.DEFER else nxt)
    if nxt == state.DEFER:
        proposal["pending_answer"] = {"choice": choice, "prompt_id": prompt["prompt_id"],
                                      "at": run_record_core.now_iso()}
        out["deferred"] = True
    elif choice == "applied":
        out["noop"] = True
    return out


def _h_answer_permission(host, argv):
    positional, opts = host._parse(argv, values=("run", "prompt"))
    if len(positional) != 2 or positional[1] not in CHOICE_WORDS:
        raise ValueError("usage: answer-permission <perm-id> applied|not-now|no --prompt <id>")
    proposal_id, choice = positional
    _, _, record = host._locate(opts)
    live = settle.live_item(record, proposal_id) if choice == "applied" else None

    def change(programme, prompt, rec):
        proposal = state.find(programme, proposal_id)
        if proposal is None:
            raise RecordError(f"no permission proposal {proposal_id!r} in this programme")
        _gate(host, proposal, choice, prompt)
        return _answer(programme, proposal, choice, prompt, live)

    def kind(payload):
        return "permission_verified" if payload.get("verify") else "permission_answered"

    return host._write(opts, change, kind, prompt_id=opts.get("prompt"), needs_prompt=True)


def in_force(programme) -> list:
    return [{k: p.get(k) for k in ("id", "state", "rules", "settings_file", "items", "confirmed")}
            for p in state.proposals(programme)
            if p.get("state") != state.RESOLVED or rules.needs_eyes(p)]


_SPECS = (
    ("propose-permission", _h_propose_permission, "[--item <id>]... [--run <id>]",
     "refused from any session but the driving one. Reads the owner's and listed sessions' transcripts (paths from the "
     "session registry) for refusals ruled after each session joined the item; with no --item, every "
     "unfinished item. A mode or classifier refusal of an eligible read becomes a proposal; a deny rule, a "
     "hook, an unknown layer, an item with no recorded repo, a destination outside the remit, or an "
     "ineligible command gets an explanation instead. A named item with no readable refusal gets an "
     "unknown-cause explanation. Re-sends open proposals not yet notified."),
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
    verbs.update(settle.build_verbs(host))
    return verbs
