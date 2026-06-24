---
date: 2026-05-19
source_agent: claude (crop-tool debugging session)
session_id: 4435cee2-d532-4ea0-b2d4-e1e90d4c3007
signal_type: surface-gap
idea_tag: instrument-inversion
tags: [nerd-on-instrument, harness-as-system-under-test, measurement-surface-sweep, recursive-application]
related_commands: [/nerd-this]
outcome: not-invoked
---

## What happened

`/nerd-this` with the harness file as scope would have been the right call after Round 2 revealed the surface mismatch. Instead of me dispatching a third general-purpose agent for "Round 3 with rounded fixture," nerd-this scoped to the harness spec could have systematically swept measurement-surface candidates (clipPath vs canvas alpha vs full-page screenshot vs DOM mutation observer vs PerformanceObserver) against a deterministic "does this surface change during gesture?" test. That's exactly the "find every tunable parameter" shape nerd was built for, applied recursively to the measurement instrument itself.

## What would have helped

A `/nerd-on-instrument` mode that treats the harness as the system-under-test rather than the source code — sweep parameters of the measurement instrument (which surface to read, which threshold, which sampling cadence) until you find one where the metric responds to a known perturbation. That's what I should have done between Round 1 and Round 2 instead of jumping to v2 by intuition.
