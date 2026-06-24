---
date: 2026-05-18
source_agent: claude (crop-rotated-overlay debugging session)
session_id: c96f6cd7-6d50-4a2c-83e3-ca2b5a047873
signal_type: prereq-blocked
tags: [harness-dependency, instrument-defect, measures-wrong-surface, falsifiable-predicate, idea-5]
related_commands: [/nerd:nerd, /ce-debug]
outcome: partial
idea_tag: harness-aware-experimentable-predicate
---

## What happened

Eight crop-tool experiments were designed, but most could not run because they depended on a measurement instrument that did not yet exist — and the instrument that was built measured the wrong surface:

"**Three of the eight tunables can be tested without the harness** (E002 coalesce window, E004 buffer threshold, E005 max scale partially). The other five depend on the per-frame alignment delta the harness produces. So the harness build that's in flight unlocks five of these experiments simultaneously."

When the harness landed, it turned out to be defective for the very bug class it targeted:

"The harness — which I built specifically to close the perception loop — turned out to have a measurement defect that makes it unable to falsify the very theory it was built for. ... `getComputedStyle(host).clipPath` returns `"none"` for the freeform fixture even when the dim region is visibly rendered. The visible dim is drawn by the `<canvas>` child of `<app-crop-overlay>` via imperative `renderCanvas`, NOT by the host's `[style.clip-path]` binding. So the harness parses an attribute that defaults to `'none'` and only updates on circle/rounded crop paths — the entire freeform-rect measurement path is reading a constant."

"I built a measurement instrument grounded in static code reading ... without verifying that the binding actually drives the visible behavior. ... **The session has a deep recursive irony: I built a tool to escape perception fatigue, but built it from theory rather than measurement.**"

Result: of the four theories the experiment was meant to falsify, three were "CONFIRMED-BY-CODE-EVIDENCE (not by measurement)" and one was INCONCLUSIVE because the harness was blocked. No numeric verdict was produced.

## What would have helped

Before designing experiments against a parameter, nerd should check that a predicate the experiment can actually observe exists and reads the surface the behavior is rendered on (here: canvas pixels, not the host `clip-path` binding). An experimentable-predicate / harness-validation gate would have caught that the chosen instrument reads a constant for the primary fixture before five experiments were staked on it.
