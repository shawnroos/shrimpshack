#!/usr/bin/env python3
"""Protocol change reporting: what changed in Authority and Done standards since the PM last acknowledged.

``ack-protocol`` stores a baseline of the merged protocol per remit repo; the rules view diffs
against it on read, so a hand edit shows with no programme write.
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
programme_context = load_lib_module("programme_context")
programme_carryover = load_lib_module("programme_carryover")

ACK_KEY = "protocol_ack"
NO_REPO = "personal"
SECTION_NAMES = {"autonomy": "Authority", "rules": "Done standard", "checks": "check command"}


def _repos(programme) -> list:
    out = {}
    for repo in (programme.get("remit") or {}).get("repos") or []:
        if isinstance(repo, dict) and repo.get("path"):
            out.setdefault(programme_carryover.key_of(repo), repo["path"])
    return list(out.items()) or [(NO_REPO, None)]


def _rejected_key(entry) -> str:
    return f"{entry['layer']}:{entry['id']}:{entry['reason']}"


def snapshot_of(host, protocol) -> dict:
    return {"autonomy": {kind: entry["level"] for kind, entry in sorted(protocol["autonomy"].items())},
            "rules": {rid: host.programme_protocol.content_hash(
                {k: rule[k] for k in host.programme_protocol.RULE_FIELDS})
                for rid, rule in sorted(protocol["rules"].items())},
            "rejected": sorted(_rejected_key(e) for e in protocol["rejected"] if e.get("id"))}


def _load(host, programme, journals, base, keys=None) -> dict:
    def lookup(run_id, prompt_id):
        return host.prompt_lookup(run_id, prompt_id, journals)

    if base is None:
        base = host.programme_protocol.load(prompt_lookup=lookup)
    return {key: (host.programme_protocol.with_project(base, path, lookup), path)
            for key, path in _repos(programme) if keys is None or key in keys}


def current(host, programme, journals=None, base=None) -> dict:
    return {key: (protocol, snapshot_of(host, protocol), path)
            for key, (protocol, path) in _load(host, programme, journals, base).items()}


def _add(rows, row, key) -> None:
    for held in rows:
        if {k: v for k, v in held.items() if k != "repos"} == row:
            held["repos"].append(key)
            return
    rows.append(dict(row, repos=[key]))


def _diff(acked, protocol, key, changed, rejected, host) -> None:
    now = snapshot_of(host, protocol)
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
            _add(rejected, {"layer": entry["layer"], "id": entry["id"], "reason": entry["reason"],
                            "section": entry.get("section")}, key)


def conflicts(host, programme, grants, loaded) -> list:
    every = [path for _, path in loaded.values()]
    levels = host.programme_protocol.AuthorityLevels(host.prompt_lookup, seed={
        frozenset([path] if path else []): protocol for protocol, path in loaded.values()})
    out = []
    for ruling in grants:
        targets = sorted(ruling["targets"])
        repos = host.programme_rulings.repos_for(programme, targets, every)
        # A grant with no items covers nothing, so no level can conflict with it.
        if targets and levels.conflicted(ruling, repos):
            out.append({"ruling": ruling["id"], "kind": ruling["kind"], "items": targets,
                        "baseline": ruling["baseline"] or "act", "level": levels.level(ruling["kind"], repos)})
    return out


def report(host, programme, journals=None, base=None) -> dict:
    acked = (programme.get(ACK_KEY) or {}).get("repos") or {}
    grants = [r for r in programme_context.rulings(programme, run_record_core.now_iso())
              if r["state"] == "active" and r["effect"] == "grant" and r["kind"] is not None]
    # A programme-wide grant reads every remit repo, so an active grant loads them all here and seeds the levels.
    loaded = _load(host, programme, journals, base, None if grants else set(acked))
    unacknowledged, changed, rejected = [], [], []
    for key, _ in _repos(programme):
        if key not in acked:
            unacknowledged.append(key)
            continue
        _diff(acked[key], loaded[key][0], key, changed, rejected, host)
    out = {"unacknowledged": unacknowledged, "changed": changed, "rejected": rejected,
           "conflicts": conflicts(host, programme, grants, loaded)}
    return out if any(out.values()) else {}


def _repo_text(row) -> str:
    return "" if row["repos"] == [NO_REPO] else f" (repos: {', '.join(row['repos'])})"


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
        out.append(f"protocol change: {SECTION_NAMES.get(row.get('section'), 'Done standard')} {row['id']} at the {row['layer']} layer rejected "
                   f"({row['reason']}): the layer below still applies{_repo_text(row)}{tell}")
    for row in report_["conflicts"]:
        out.append(f"Ruling conflict: {row['ruling']} grants {row['kind']} on {', '.join(row['items'])}, but "
                   f"Authority now holds {row['kind']} at {row['level']} ({row['baseline']} when granted); the "
                   f"narrower applies: ask Shawn to close {row['ruling']} or accept a widened revision of it; a "
                   "narrowing revision keeps the old level")
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
