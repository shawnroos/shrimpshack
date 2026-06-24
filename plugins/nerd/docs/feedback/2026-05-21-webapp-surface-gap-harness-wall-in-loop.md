---
date: 2026-05-21
source_agent: claude (ai-service-hub ce-code-review convergence loop)
session_id: 3f736433-28a1-4a74-9426-4c24e368b3b4
signal_type: surface-gap
idea_tag: instrument-inversion
tags: [harness-wall, instrument-cant-measure, convergence-loop-blocked, harness-as-system-under-test]
related_commands: [/nerd-this, /nerd:nerd]
outcome: not-invoked
---

## What happened

A review→fix→re-review convergence loop ("the bar is **zero P0/P1/P2**") stalled because the test instrument couldn't measure the behavior the convergence criterion required. The agent named it the "harness wall":

"the testing reviewer marked these `manual`/`human` — meaning "needs cross-team input or harness work." The reason they're `manual` not `safe_auto`: the rest of `replicate.service.spec.ts`'s deep-async suite is `xit`'d because of Karma-batch flakiness with `fakeAsync` + the `httpMock.verify()` race. So the question isn't *whether* to test S10/S18, it's *whether they can be tested without hitting that same harness wall*."

"Now I understand the harness wall precisely. The `xit`'d tests fail because of a **`cancelPrediction` fire-and-forget POST + `httpMock.verify()` race in the Karma batch** ... **S10's test would hit the *exact same wall***."

The agent then worked around the broken instrument by refactoring the code-under-test rather than treating the harness as the system-under-test: "the real choice the user picked ("fix both") collides with a harness reality the reviewers surfaced but I under-weighted when I framed the question ... refactoring the substrate to make it testable is a *much* bigger change than the loop should make."

## What would have helped

A `/nerd-this` scoped to the spec harness — sweeping measurement-surface candidates (which async wait primitive, which flush cadence, fakeAsync vs explicit-flush vs isolated-it) against a deterministic "does this test reliably observe `cancelPrediction`?" predicate — would have attacked the harness wall directly instead of forcing a code refactor around it. The loop hit exactly the harness-as-system-under-test situation nerd-on-instrument is built for, and never reached for it.
