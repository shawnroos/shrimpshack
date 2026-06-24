---
date: 2026-05-09
source_agent: claude (autonomous /nerd run — drained backlog)
session_id: 3d1160db-5360-4718-82bd-f0e533b97343
signal_type: surface-gap
tags: [drained-backlog-noop, wiring-not-a-parameter-sweep, qualitative-validation, highest-roi-out-of-scope, unwired-infra-debt-S028]
related_commands: [/nerd:nerd, /nerd-loop]
idea_tag: reposition-execute-any-falsifiable-experiment
outcome: not-invoked
---

## What happened

With the backlog drained (77/78 completed), the autonomous /nerd run no-op'd — and the agent explicitly noted that the single highest-ROI piece of work in the queue is outside what /nerd can execute. From `docs/research/autonomous-run-2026-05-09.md`:

"The highest-ROI next move is `/nerd-loop \"Wire PromptProfile into ACP session startup...\"`. The autonomous /nerd path cannot deliver this — the experiment requires a human-supervised loop because it is wiring + qualitative validation (suggestion acceptance rate), not a measurable parameter sweep."

The prior run had already flagged this as a structural pattern via synthesis node S028 (`docs/research/autonomous-run-2026-05-08.md`):

"S028 (high confidence): *Unwired infrastructure with documented savings persists across batches.* ... E-PROMPT-WIRE as the outstanding instance — 7 batches without the switch being flipped despite documented 87% token savings. Consequence: research velocity is outpacing integration velocity. Recommend prioritizing wiring work over new experiment design until the gap closes."

So nerd repeatedly surfaces the most valuable next action (wire the existing PromptProfile infra) but its surface only covers measurable parameter sweeps — the wiring + acceptance-rate validation shape falls through to a human-supervised /nerd-loop, which never gets promoted to active. The work that nerd's own loop-scout ranks 9.5/10 is the work nerd can't run.

## What would have helped

Reposition the experiment surface so "flip an unwired switch and validate via a qualitative acceptance-rate metric" is a falsifiable experiment nerd can execute, not something that has to be hand-routed to a supervised loop. The agent's own S028 says research velocity is outpacing integration velocity precisely because the integration-shaped work doesn't fit the parameter-sweep mold the autonomous path is built around.
