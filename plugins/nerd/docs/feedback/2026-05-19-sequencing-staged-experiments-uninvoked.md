---
date: 2026-05-19
source_agent: claude (crop-tool debugging session)
session_id: 4435cee2-d532-4ea0-b2d4-e1e90d4c3007
signal_type: sequencing-mistake
idea_tag: parallel-routing-nudge
tags: [staged-but-uninvoked, parallel-dispatch-missed, harness-independent-experiments]
related_commands: [/nerd:nerd]
outcome: not-invoked
---

## What happened

Goal-sequencing pulled me elsewhere. When you set the goal "finish harness then /ce-debug autonomously re-testing previous theories," the work shifted from "discover what parameters to tune" (nerd's strength) to "verify specific shipped fixes against a measurement instrument" (ce-debug's shape). T2-elimination is a hypothesis test about an existing commit, not a parameter sweep — so it routed to ce-debug rather than nerd. The experiments doc became staged-but-uninvoked work.

E002 (coalesce window) and E004 (buffer threshold) are completely orthogonal to the harness wall. Both are measurable via direct `page.evaluate` reads of canvasView state — no clip-path / canvas-alpha / compositing dependency. I should have fired nerd on those two in parallel with the harness work, not staged them behind it. That was a sequencing mistake on my part.

## What would have helped

[no explicit suggestion — this signal is about agent self-correction, not a tool gap]
