---
date: 2026-05-19
source_agent: claude (crop-tool debugging session)
session_id: 4435cee2-d532-4ea0-b2d4-e1e90d4c3007
signal_type: tool-overlap
idea_tag: hypothesis-brief-sweep-of-one
tags: [ce-debug-overlap, hypothesis-test-vs-parameter-sweep, positioning, collapsing-the-choice]
related_commands: [/nerd:nerd, /ce-debug]
outcome: not-invoked
---

## What happened

Tighter coupling with `/ce-debug`'s verdict criteria — ce-debug's "50% drop" verdict is exactly a one-shot experiment. If nerd could consume a ce-debug brief as a single sweep-of-one and produce the same numeric output, the two would compose cleanly. Right now they live in parallel and I have to choose which one applies, which is why one of them got dropped this session.

Short version: I underused nerd because my mental model treated it as "discover unknown parameters" rather than "execute any falsifiable experiment, including hypothesis-tests of single commits." If nerd is positioned more clearly as the second thing, ce-debug becomes redundant and the choice collapses.

## What would have helped

Reposition nerd as "execute any falsifiable experiment" (which subsumes both parameter-sweeps and hypothesis-tests of single commits). At that framing, a ce-debug brief becomes a sweep-of-one that nerd can consume, and the agent stops having to pick between the two.
