---
date: 2026-05-08
source_agent: claude (autonomous /nerd run — Batch 27)
session_id: 3d1160db-5360-4718-82bd-f0e533b97343
signal_type: execution-defect
tags: [stale-worktrees, auto-cleanup-not-honored, rerun-risk, merge-step-leaves-worktree, backlog-drift]
related_commands: [/nerd:nerd, /nerd-schedule]
idea_tag: new-pattern
outcome: invoked
---

## What happened

The orchestrator left worktrees on disk for branches it had already merged, despite cleanup being configured. From `docs/research/batch27-findings.md`, "N1 — Backlog drift via stale worktrees is real":

"Four worktrees were on disk: `nerd-E-EMBED-BATCH`, `nerd-E-INDEX-BATCH`, `nerd-E-PERF-CMDPALETTE`, `nerd-E-SQLITE-CACHE`. Three of those branches were **already merged** into `nerd/E-TUI-ALLOC-B16` from Batch 25/26. The directories were left behind. With `auto_cleanup_worktrees: true` configured, this should have been automatic — but it wasn't."

The defect has a downstream consequence — re-running already-completed experiments:

"If the orchestrator merges a branch but leaves the worktree, downstream agents see 'active worktree' signals and may re-run the experiment."

The autonomous-run-2026-05-08 pre-flight independently noted residual worktree state ("2 modified/untracked docs from prior autonomous run").

## What would have helped

From the agent's N1 action items:

"Either: Have the merge step always `git worktree remove`, or Have the audit step always cross-check `git branch --merged` before claiming worktrees are 'in progress'."
