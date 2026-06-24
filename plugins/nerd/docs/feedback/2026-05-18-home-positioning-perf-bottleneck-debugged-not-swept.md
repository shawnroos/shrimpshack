---
date: 2026-05-18
source_agent: claude (Brand Foundry run-latency debugging session)
session_id: 693d9167-e2a6-4efb-b3b2-1357f83aff66
signal_type: positioning
tags: [ce-debug-overlap, performance-bottleneck, numeric-baseline, architecture-bottleneck-theory, recurred-identically, idea-3]
related_commands: [/ce-debug, /nerd:nerd]
outcome: not-invoked
idea_tag: reposition-execute-any-falsifiable-experiment
---

## What happened

`/ce-debug` was invoked to investigate Brand Foundry run latency with the args:

"the reason our runs are taking so long, with a list of considered options for speeding up the run"

The investigation opened from a quantified baseline, not a correctness bug:

"Investigating root cause now. Starting from the empirical timing data we already have for Pizza Hut + BECU.

| Run | Wall-clock | generate_bgs_overlays | generate_media |
|---|---|---|---|
| Pizza Hut | 20.6 min | **480 s (8m0s)** | 241s (4m1s) |
| BECU | 19.8 min | **490 s (8m10s)** | (pending log) |

`generate_bgs_overlays` is the consistent single biggest cost — **8+ minutes every run**, regardless of brand. That's the bug under investigation."

This is a parameter/architecture sweep in everything but name: a measured baseline (480s/490s), an isolated hot path (`generate_bgs_overlays` = 26 OpenAI calls per run), and an explicit ask for "a list of considered options for speeding up the run." It maps directly onto nerd's data-bottleneck / architecture-bottleneck theories. nerd was never considered.

The recurrence is itself the signal: the *identical* `/ce-debug` args ("the reason our runs are taking so long, with a list of considered options for speeding up the run") were run again in a separate session (aedb6958-4f4e-4e09-a12f-73d33040d634) over the same `generate_bgs_overlays` bottleneck. A recurring, numerically-anchored "why is this slow and what are the options" investigation is exactly nerd's shape, yet it routed to `/ce-debug` both times.

## What would have helped

Position nerd as the tool for "I have a measured bottleneck and a list of candidate speedups — which one actually wins" (performance/architecture sweeps), not only "discover unknown tunable parameters." Framed that way, a perf-latency `/ce-debug` brief like this becomes a nerd sweep that compares the considered options against the existing numeric baseline.
