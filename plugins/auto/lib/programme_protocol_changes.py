#!/usr/bin/env python3
"""Protocol change reporting: what changed in Authority and Done standards since the PM last acknowledged.

``ack-protocol`` stores the merged protocol per remit repo in the programme block: each kind's
Authority level, each Done standard's content hash and each rejected entry. The rules view
compares the protocol it reads now with that snapshot, so a hand edit shows on the next read with
no programme write. The same pass lists grant Rulings whose kind Authority now holds narrower than
the level recorded when the grant became active. ``programme.py`` registers the verb through
``build_verbs(host)``.
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
programme_decisions = load_lib_module("programme_decisions")
programme_context = load_lib_module("programme_context")

ACK_KEY = "protocol_ack"
NO_REPO = "personal"
SECTION_NAMES = {"autonomy": "Authority", "rules": "Done standard"}
LEVEL_ORDER = programme_decisions.LEVEL_ORDER


def _repos(programme) -> list:
    out = []
    for repo in (programme.get("remit") or {}).get("repos") or []:
        if isinstance(repo, dict) and repo.get("path"):
            key = repo.get("github") or os.path.normpath(repo["path"])
            if key not in [k for k, _ in out]:
                out.append((key, repo["path"]))
    return out or [(NO_REPO, None)]


def _rejected_key(entry) -> str:
    return f"{entry['layer']}:{entry['id']}:{entry['reason']}"


def snapshot_of(host, protocol) -> dict:
    return {"autonomy": {kind: entry["level"] for kind, entry in sorted(protocol["autonomy"].items())},
            "rules": {rid: host.programme_protocol.content_hash(
                {k: rule[k] for k in host.programme_protocol.RULE_FIELDS})
                for rid, rule in sorted(protocol["rules"].items())},
            "rejected": sorted(_rejected_key(e) for e in protocol["rejected"] if e.get("id"))}


def current(host, programme, journals=None) -> dict:
    def lookup(run_id, prompt_id):
        return host.prompt_lookup(run_id, prompt_id, journals)

    out = {}
    for key, path in _repos(programme):
        protocol = host.programme_protocol.load(repo_path=path, prompt_lookup=lookup)
        out[key] = (protocol, snapshot_of(host, protocol), path)
    return out


def _add(rows, row, key) -> None:
    for held in rows:
        if {k: v for k, v in held.items() if k != "repos"} == row:
            held["repos"].append(key)
            return
    rows.append(dict(row, repos=[key]))


def _diff(acked, now, key, changed, rejected, protocol) -> None:
    for section in ("autonomy", "rules"):
        before, after = acked.get(section) or {}, now[section]
        for name in sorted(set(before) | set(after)):
            if before.get(name) == after.get(name):
                continue
            was, is_now = before.get(name), after.get(name)
            if section == "rules":
                was, is_now = was and "present", is_now and "present"
            _add(changed, {"section": section, "id": name, "was": was, "now": is_now}, key)
    seen = set(acked.get("rejected") or [])
    for entry in protocol["rejected"]:
        if entry.get("id") and _rejected_key(entry) not in seen:
            _add(rejected, {"layer": entry["layer"], "id": entry["id"], "reason": entry["reason"]}, key)


def _narrower(level, baseline) -> bool:
    # A grant with no recorded baseline is compared as made at act, as the gate does.
    return level is not None and LEVEL_ORDER.index(level) < LEVEL_ORDER.index(baseline or "act")


def _level(host, programme, kind, targets, loaded):
    items = programme["items"]
    paths = {items[t].get("repo") if t in items else None for t in targets}
    by_path = {path: protocol for protocol, _, path in loaded.values()}
    # The gate's rule (programme_rulings.protocol_for): a programme-wide or repo-less target reads every remit repo.
    if None in paths:
        paths = set(by_path)
    if not paths <= set(by_path):
        return host.programme_rulings.authority_level(host, programme, kind, targets)
    levels = [host.programme_rulings.level_of(by_path[p], kind) for p in paths]
    levels = [lv for lv in levels if lv is not None]
    return min(levels, key=LEVEL_ORDER.index) if levels else None


def conflicts(host, programme, now_iso, loaded) -> list:
    when = run_record_core.parse_iso(now_iso)
    items = programme.get("items") or {}
    out = []
    for rid, revisions in sorted(programme_context.block(programme)["decisions"].items()):
        ruling = programme_context.in_force(revisions)
        if not ruling or ruling.get("effect") != "grant" or ruling.get("kind") is None \
                or programme_context.ruling_state(revisions, when) != "active":
            continue
        targets = sorted({programme_context._canonical(items, t) for t in ruling.get("applies_to") or []})
        level = _level(host, programme, ruling["kind"], targets, loaded)
        if _narrower(level, ruling.get("baseline")):
            out.append({"ruling": rid, "kind": ruling["kind"], "items": targets,
                        "baseline": ruling.get("baseline") or "act", "level": level})
    return out


def report(host, programme, journals=None) -> dict:
    acked = (programme.get(ACK_KEY) or {}).get("repos") or {}
    unacknowledged, changed, rejected = [], [], []
    loaded = current(host, programme, journals)
    for key, (protocol, now, _) in loaded.items():
        if key not in acked:
            unacknowledged.append(key)
            continue
        _diff(acked[key], now, key, changed, rejected, protocol)
    out = {"unacknowledged": unacknowledged, "changed": changed, "rejected": rejected,
           "conflicts": conflicts(host, programme, run_record_core.now_iso(), loaded)}
    return out if any(out.values()) else {}


def _repo_text(row) -> str:
    return "" if row["repos"] == [NO_REPO] else f" (repos: {', '.join(row['repos'])})"


def _section_of(entry_id) -> str:
    # Rejected entries carry no section; Authority keys are decision kinds, written with "_", and rule ids never are.
    return "Authority" if entry_id in programme_decisions.DECISION_KINDS or "_" in entry_id else "Done standard"


def lines(report_) -> list:
    if not report_:
        return []
    out = []
    if report_["unacknowledged"]:
        out.append(f"protocol not acknowledged for {', '.join(report_['unacknowledged'])}: run ack-protocol "
                   "once to set the baseline this programme reports changes against")
    tell = "; tell Shawn this programme now reads it, then run ack-protocol"
    for row in report_["changed"]:
        name = SECTION_NAMES[row["section"]]
        if row["section"] == "rules":
            what = "removed" if row["now"] is None else "added" if row["was"] is None else "changed"
        else:
            what = f"{row['was'] or 'unset'} -> {row['now'] or 'unset'}"
        out.append(f"protocol change: {name} {row['id']} {what}{_repo_text(row)}{tell}")
    for row in report_["rejected"]:
        out.append(f"protocol change: {_section_of(row['id'])} {row['id']} at the {row['layer']} layer rejected "
                   f"({row['reason']}): the layer below still applies{_repo_text(row)}{tell}")
    for row in report_["conflicts"]:
        out.append(f"Ruling conflict: {row['ruling']} grants {row['kind']} on {', '.join(row['items'])}, but "
                   f"Authority now holds {row['kind']} at {row['level']} ({row['baseline']} when granted); the "
                   f"narrower applies: ask Shawn to accept a new revision of {row['ruling']} or close it")
    return out


def _h_ack_protocol(host, argv):
    positional, opts = host._parse(argv, values=("run",))
    if positional:
        raise ValueError("usage: ack-protocol [--run <id>]")

    def change(programme, prompt, rec):
        repos = {key: now for key, (_, now, _) in current(host, programme).items()}
        programme[ACK_KEY] = {"at": run_record_core.now_iso(), "repos": repos}
        return {"acknowledged": sorted(repos)}

    return host._write(opts, change, "protocol_acknowledged", verb="ack-protocol", target=ACK_KEY)


_SPECS = (
    ("ack-protocol", _h_ack_protocol, "[--run <id>]",
     "a caller that is not the driving session; an ended programme. Records the merged Authority levels, Done "
     "standard hashes and rejected entries per remit repo as the baseline the rules view compares with; run "
     "it after telling Shawn about each listed change. It never clears a Ruling conflict."),
)


def build_verbs(host) -> dict:
    return {name: host._Verb(functools.partial(handler, host), args, rejects=rejects)
            for name, handler, args, rejects in _SPECS}
