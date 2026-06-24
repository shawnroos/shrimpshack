#!/usr/bin/env python3
"""
Print the feedback-header metadata for a Claude Code session.

Usage:
  session-header.py <session-uuid>

Output (plain text, easy to paste into a feedback entry's frontmatter):
  session_id:      <uuid>
  file:            <abs path to jsonl>
  events:          <line count>
  first_event:     <ISO timestamp>
  last_event:      <ISO timestamp>
  cwd:             <first non-empty cwd seen>
  git_branch:      <first non-empty gitBranch seen>
  top_repos:       <repo>:<refs>, ...   (top 5 by path-reference count)
  top_files:       <path>:<refs>, ...   (top 5 most-referenced files)

Notes:
- cwd / gitBranch on the first event are often empty; this scans every event and
  reports the first real value seen (which is the load-bearing one for "where
  was the agent actually working").
- top_repos counts references to /Users/shawnroos/{projects,Documents}/<name>
  paths anywhere in the transcript. For the 2026-05-19 crop-tool session, cwd
  said /Users/shawnroos but top_repos correctly identified Slate.
"""

import json
import re
import sys
from collections import Counter
from pathlib import Path

SESSIONS_DIR = Path.home() / ".claude" / "projects"
PATH_RE = re.compile(r"/Users/shawnroos/(?:projects|Documents)/([A-Za-z0-9_.\-–]+)(/[A-Za-z0-9_./\-]*)?")


def find_session_file(uuid: str) -> Path:
    matches = list(SESSIONS_DIR.rglob(f"{uuid}.jsonl"))
    if not matches:
        sys.exit(f"error: no session file found for {uuid} under {SESSIONS_DIR}")
    if len(matches) > 1:
        sys.exit(f"error: multiple matches for {uuid}: {matches}")
    return matches[0]


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(f"usage: {sys.argv[0]} <session-uuid>")

    uuid = sys.argv[1]
    path = find_session_file(uuid)

    cwd = git_branch = first_ts = last_ts = None
    events = 0
    repo_refs: Counter[str] = Counter()
    file_refs: Counter[str] = Counter()

    with path.open() as f:
        for line in f:
            events += 1
            try:
                d = json.loads(line)
            except json.JSONDecodeError:
                continue

            ts = d.get("timestamp")
            if ts:
                if first_ts is None:
                    first_ts = ts
                last_ts = ts

            if not cwd and d.get("cwd") and d["cwd"] != "/Users/shawnroos":
                cwd = d["cwd"]
            if not git_branch and d.get("gitBranch") and d["gitBranch"] != "HEAD":
                git_branch = d["gitBranch"]

            for m in PATH_RE.finditer(line):
                repo = m.group(1)
                rest = m.group(2) or ""
                repo_refs[repo] += 1
                if rest:
                    file_refs[f"{repo}{rest}".rstrip("\"',)]}")] += 1

    print(f"session_id:      {uuid}")
    print(f"file:            {path}")
    print(f"events:          {events}")
    print(f"first_event:     {first_ts or '(none)'}")
    print(f"last_event:      {last_ts or '(none)'}")
    print(f"cwd:             {cwd or '(none/home)'}")
    print(f"git_branch:      {git_branch or '(none)'}")

    top_repos = ", ".join(f"{r}:{n}" for r, n in repo_refs.most_common(5))
    print(f"top_repos:       {top_repos or '(none)'}")

    top_files = ", ".join(f"{p}:{n}" for p, n in file_refs.most_common(5))
    print(f"top_files:       {top_files or '(none)'}")


if __name__ == "__main__":
    main()
