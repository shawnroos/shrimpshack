#!/usr/bin/env python3
"""Cost, turns, sweeps, context and idle-wake share of Claude Code session transcripts.

Cost is input + 1.25 x cache-create + 0.1 x cache-read + 5 x output. The cache-read
weight is an approximation of the billing ratio, so compare runs with each other, not with an
invoice. Assistant lines whose usage is all zero are placeholders (rate-limit and login notices),
not turns, and are left out. A session's subagent transcripts (`<session-id>/subagents/*.jsonl`, next to
`<session-id>.jsonl`) are summed in, so moving work into agents cannot hide its cost.
"""

import argparse
import collections
import datetime
import glob
import json
import os
import re
import sys
import time

CE_SKILLS = ("lfg", "ce-plan", "ce-code-review", "ce-doc-review")
SWEEP_SKILL = "programme-sweep"
NO_CE = "(none)"
COMMAND_NAME = re.compile(r"<command-name>/?([^<]+)</command-name>")


def weighted_cost(usage):
    return ((usage.get("input_tokens") or 0)
            + 1.25 * (usage.get("cache_creation_input_tokens") or 0)
            + 0.1 * (usage.get("cache_read_input_tokens") or 0)
            + 5 * (usage.get("output_tokens") or 0))


def context_tokens(usage):
    return (usage.get("cache_creation_input_tokens") or 0) + (usage.get("cache_read_input_tokens") or 0)


def _parse_time(stamp):
    return datetime.datetime.fromisoformat(stamp.replace("Z", "+00:00"))


def _local_day(stamp):
    return _parse_time(stamp).astimezone().strftime("%Y-%m-%d")


def _short(name):
    return name.rsplit(":", 1)[-1]


def _result_chars(content):
    if isinstance(content, str):
        return len(content)
    if isinstance(content, list):
        return sum(len(part.get("text", "")) for part in content if isinstance(part, dict))
    return 0


def _source_key(block):
    name = block.get("name") or "?"
    args = block.get("input") or {}
    if name == "Bash":
        command = args.get("command") or ""
        if "programme" in command:
            return "Bash:programme.sh"
        words = command.split()
        return "Bash:" + (words[0] if words else "")
    if name == "Read":
        return "Read:" + str(args.get("file_path") or "")
    return name


def read_transcript(path):
    """Return (assistant turns, tool-result sizes, skill calls, skipped line count) for one file."""
    turns = {}
    order = []
    skills = {}
    pending = {}
    sizes = collections.defaultdict(lambda: [0, 0])
    skipped = 0
    with open(path, errors="ignore") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except ValueError:
                skipped += 1
                continue
            message = entry.get("message")
            if not isinstance(message, dict):
                continue
            content = message.get("content")
            blocks = content if isinstance(content, list) else []
            stamp = entry.get("timestamp")
            if message.get("role") == "assistant":
                for block in blocks:
                    if block.get("type") != "tool_use":
                        continue
                    pending[block.get("id")] = _source_key(block)
                    if block.get("name") == "Skill" and stamp:
                        skills[block.get("id")] = (stamp, str((block.get("input") or {}).get("skill") or ""))
                if message.get("usage") and stamp and (weighted_cost(message["usage"]) or context_tokens(message["usage"])):
                    key = message.get("id") or entry.get("uuid")
                    if key not in turns:
                        order.append(key)
                    turns[key] = (stamp, message["usage"])
            elif message.get("role") == "user":
                for block in blocks:
                    if block.get("type") == "tool_result":
                        slot = sizes[pending.get(block.get("tool_use_id"), "?")]
                        slot[0] += _result_chars(block.get("content"))
                        slot[1] += 1
                if isinstance(content, str) and stamp:
                    found = COMMAND_NAME.search(content)
                    if found:
                        skills[entry.get("uuid")] = (stamp, found.group(1))
    rows = sorted(turns[key] for key in order)
    return rows, sizes, sorted(skills.values()), skipped


def session_files(paths):
    """Expand directories into transcripts, skipping subagent files (they ride with their parent)."""
    found = []
    for path in paths:
        if os.path.isdir(path):
            found.extend(sorted(p for p in glob.glob(os.path.join(path, "*.jsonl"))))
        else:
            found.append(path)
    return found


def subagent_files(session_path):
    stem = session_path[:-len(".jsonl")] if session_path.endswith(".jsonl") else session_path
    return sorted(glob.glob(os.path.join(stem, "subagents", "*.jsonl")))


def _blank_day():
    return {"parent_cost": 0.0, "subagent_cost": 0.0, "turns": 0, "subagent_turns": 0, "sweeps": 0,
            "ctx_sum": 0, "peak_context": 0, "idle_turns": 0, "idle_cost": 0.0}


def _finish(bucket):
    parent = bucket["parent_cost"]
    return {
        "cost": round(parent + bucket["subagent_cost"], 2),
        "parent_cost": round(parent, 2),
        "subagent_cost": round(bucket["subagent_cost"], 2),
        "turns": bucket["turns"],
        "subagent_turns": bucket["subagent_turns"],
        "sweeps": bucket["sweeps"],
        "avg_context": bucket["ctx_sum"] // bucket["turns"] if bucket["turns"] else 0,
        "peak_context": bucket["peak_context"],
        "idle_turns": bucket["idle_turns"],
        "idle_cost_share": (bucket["idle_cost"] / parent) if parent else 0.0,
    }


def _ce_label(call):
    for name in CE_SKILLS:
        if _short(call) == name:
            return name
    return None


def analyse(paths, idle_seconds=1200):
    days = collections.defaultdict(_blank_day)
    total = _blank_day()
    sources = collections.defaultdict(lambda: [0, 0])
    ce = collections.defaultdict(lambda: {"cost": 0.0, "turns": 0, "invocations": 0})
    skipped = 0
    files = session_files(paths)
    for path in files:
        rows, sizes, skills, bad = read_transcript(path)
        skipped += bad
        for key, (chars, calls) in sizes.items():
            sources[key][0] += chars
            sources[key][1] += calls
        previous = None
        sweep_times = [stamp for stamp, name in skills if _short(name) == SWEEP_SKILL]
        for stamp in sweep_times:
            for bucket in (days[_local_day(stamp)], total):
                bucket["sweeps"] += 1
        ce_calls = sorted((stamp, _ce_label(name)) for stamp, name in skills if _ce_label(name))
        for stamp, label in ce_calls:
            ce[label]["invocations"] += 1
        label, upcoming = NO_CE, list(ce_calls)
        ce[NO_CE]
        for stamp, usage in rows:
            while upcoming and upcoming[0][0] <= stamp:
                label = upcoming.pop(0)[1]
            cost = weighted_cost(usage)
            ce[label]["cost"] += cost
            ce[label]["turns"] += 1
            ctx = context_tokens(usage)
            idle = previous is not None and (_parse_time(stamp) - _parse_time(previous)).total_seconds() >= idle_seconds
            for bucket in (days[_local_day(stamp)], total):
                bucket["parent_cost"] += cost
                bucket["turns"] += 1
                bucket["ctx_sum"] += ctx
                bucket["peak_context"] = max(bucket["peak_context"], ctx)
                if idle:
                    bucket["idle_turns"] += 1
                    bucket["idle_cost"] += cost
            previous = stamp
        for sub in subagent_files(path):
            sub_rows, _, _, bad = read_transcript(sub)
            skipped += bad
            for stamp, usage in sub_rows:
                for bucket in (days[_local_day(stamp)], total):
                    bucket["subagent_cost"] += weighted_cost(usage)
                    bucket["subagent_turns"] += 1
    return {
        "files": len(files),
        "skipped_lines": skipped,
        "total": _finish(total),
        "days": {day: _finish(days[day]) for day in sorted(days)},
        "sources": [{"key": key, "chars": chars, "calls": calls}
                    for key, (chars, calls) in sorted(sources.items(), key=lambda kv: -kv[1][0])],
        "ce": {label: {"cost": round(v["cost"], 2), "turns": v["turns"], "invocations": v["invocations"]}
               for label, v in ce.items()},
    }


def render(report, with_sources, with_ce):
    def line(label, row):
        return ("{:<12} cost {:>12,.0f}  (agents {:>10,.0f})  turns {:>5}  sweeps {:>4}  "
                "ctx avg {:>7,} peak {:>7,}  idle wakes {:>4} = {:>4.0%} of cost").format(
            label, row["cost"], row["subagent_cost"], row["turns"], row["sweeps"],
            row["avg_context"], row["peak_context"], row["idle_turns"], row["idle_cost_share"])
    out = [line(day, row) for day, row in report["days"].items()]
    out.append(line("TOTAL", report["total"]))
    if report["skipped_lines"]:
        out.append("skipped {} unreadable lines".format(report["skipped_lines"]))
    if with_sources:
        out.append("")
        out.append("largest tool-result sources (characters):")
        out.extend("  {:<60} {:>10,} in {:>4} calls".format(r["key"][-60:], r["chars"], r["calls"])
                   for r in report["sources"][:15])
    if with_ce:
        out.append("")
        out.append("cost by CE skill active:")
        out.extend("  {:<16} cost {:>12,.0f}  turns {:>5}  invocations {:>3}".format(
            label, v["cost"], v["turns"], v["invocations"]) for label, v in sorted(report["ce"].items()))
    return "\n".join(out)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Token cost of Claude Code session transcripts.")
    parser.add_argument("paths", nargs="+", help="transcript .jsonl files or directories of them")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--sources", action="store_true", help="rank tool-result bytes by tool")
    parser.add_argument("--ce", action="store_true", help="group cost by active CE skill")
    parser.add_argument("--idle-minutes", type=float, default=20.0)
    args = parser.parse_args(argv)
    if os.environ.get("TZ"):
        time.tzset()
    for path in args.paths:
        if not os.path.exists(path):
            print("token-cost: no such transcript: {}".format(path), file=sys.stderr)
            return 2
    report = analyse(args.paths, idle_seconds=args.idle_minutes * 60)
    if report["total"]["turns"] == 0:
        print("token-cost: no assistant turns with usage found in {}".format(", ".join(args.paths)),
              file=sys.stderr)
        return 2
    if not args.sources:
        report.pop("sources")
    if not args.ce:
        report.pop("ce")
    print(json.dumps(report, indent=2) if args.json else render(report, args.sources, args.ce))
    return 0


if __name__ == "__main__":
    sys.exit(main())
