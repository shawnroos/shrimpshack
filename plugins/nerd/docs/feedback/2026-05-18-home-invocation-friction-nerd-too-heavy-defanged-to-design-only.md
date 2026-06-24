---
date: 2026-05-18
source_agent: claude (crop-rotated-overlay debugging session)
session_id: c96f6cd7-6d50-4a2c-83e3-ca2b5a047873
signal_type: invocation-friction
tags: [ce-debug-overlap, nerd-too-heavy, design-not-run, full-scan-vs-targeted, idea-3]
related_commands: [/nerd:nerd, /ce-debug]
outcome: partial
idea_tag: reposition-execute-any-falsifiable-experiment
---

## What happened

`/nerd:nerd` was invoked mid-session (`lets design measuarable experiments that we can use nerd for`) while a `/ce-debug` theory-elimination flow was already in flight. The agent recognized nerd as the right shape but declined to actually run it:

"**`/nerd:nerd` is a different shape of agent than what's in flight.** The harness agent is building a deterministic regression test for a specific bug class (mid-drag visual alignment). `/ce-debug` will use that harness to falsify our four crop theories. `/nerd:nerd` would scan the codebase for tunable parameters and design parameter sweeps — completely different output shape."

"**But running full `/nerd:nerd` right now would be wrong for two reasons.** First, it'd take significant time and compute (parameter scan + perf explorer + specialists in parallel, plus experiment execution in worktrees). Second, it'd cut across the goal's sequential dependency — we don't need a broad codebase scan; we need targeted measurable experiments specifically for the crop-tool theories and tunables that surfaced this session."

So nerd was downgraded to design-only: "you're asking me to design the experiments, not run them. Design means: name the parameters, state the falsifiable hypothesis, specify the metric command, specify the sweep range." Meanwhile `/ce-debug` carried the actual execution — "spawn its own worktrees per theory, run the harness in baseline+theory configurations, produce numeric verdicts." The two ended up parallel: "we can fire `/ce-debug` on the four shipped theories ... AND `/nerd:nerd` on E002+E004 (now designed). They're parallel — neither blocks the other."

## What would have helped

A lighter-weight nerd entry point that skips the broad codebase scan and consumes an already-identified set of tunables/theories as the experiment input — so "design measurable experiments for these specific parameters" doesn't fall back to design-only while a different command (`/ce-debug`) does the worktree-per-theory execution that nerd already knows how to do.
