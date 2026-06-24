---
date: 2026-05-19
source_agent: claude (crop-tool debugging session)
session_id: 4435cee2-d532-4ea0-b2d4-e1e90d4c3007
signal_type: prereq-blocked
idea_tag: harness-aware-experimentable-predicate
tags: [harness-defects, measurement-instrument-broken, inconclusive-by-association]
related_commands: [/nerd:nerd]
outcome: not-invoked
---

## What happened

Friction at the dispatch boundary. When I wrote the experiments design I noted that E002 (coalesce window) and E004 (buffer threshold) were "ready for the nerd's experiment-executor" but several others depended on the harness landing first. The harness then turned out to have measurement defects through two rounds — so even the "nerd-ready" experiments would have been blocked on the same surface-mismatch problem the harness has. Dispatching nerd at any of those points would have produced sweeps grounded in an instrument I knew was broken.

## What would have helped

An "experimentable" predicate for `/nerd:nerd` proposals that's harness-aware — right now nerd's Phase 2c marks a finding "experimentable" if it has a sweep-able value, but doesn't ask "is the existing harness capable of producing the metric this sweep needs?" When the harness is itself under question, every parameter becomes inconclusive-by-association.
