---
name: nerd-status
description: "Check the status of the nerd queue, running experiments, and backlog. Shows progress, completed findings, and pending proposals."
allowed-tools: "Read,Bash,Glob"
---

# Nerd Status

Display the current state of the nerd pipeline.

## Read Backlog

```bash
cat .claude/nerd.local.md 2>/dev/null
```

Parse the YAML frontmatter for backlog entries.

## Check Worktrees

```bash
git worktree list 2>/dev/null | grep "nerd-"
```

## Check Results

```bash
ls docs/research/results/*.json 2>/dev/null | wc -l
ls docs/research/*-report.md 2>/dev/null | wc -l
```

## Display Status

Format output as:

```
Nerd Status
═══════════════════

Backlog:
  Proposed: {count}
  Planned:  {count}
  Running:  {count}
  Complete: {count}
  Failed:   {count}

Active Worktrees:
  worktrees/nerd-E001 → nerd/E001 (running)
  worktrees/nerd-E002 → nerd/E002 (running)

Recent Findings:
  E001: JW threshold optimal at 0.85 [KEEP]
  E002: RRF k=40 beats k=60 by 3% [CHANGE]

Reports: docs/research/
```

If backlog is empty: "No research backlog. Run /nerd to analyze the codebase."
