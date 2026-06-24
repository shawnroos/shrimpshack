---
date: 2026-05-15
source_agent: claude (Slate denoise QA harness session)
session_id: 0ad1342c-1c08-42dc-b2f6-41db0862bb9e
signal_type: surface-gap
tags: [human-as-judge, qualitative-verdict, no-numeric-metric, perceptual-sweep, generate-variants-for-review]
related_commands: [/nerd:nerd, /nerd-this]
outcome: not-invoked
idea_tag: new-pattern
---

## What happened

The sweep here had no numeric metric. The user defined the verdict criterion as human perceptual judgment, verbatim:

> "we will offer multiple levels of strength of noise reduction that the user, in this case it will be QA engineers, we'll be able to test the various levels by clicking on a UI that cycles through our options... the UI will mute or reduce the volume to zero when the audio file is not selected."

The agent's own framing of the gap, verbatim:

> "QA currently has no way to A/B strength levels — they get whatever lalal.ai's defaults produce."

The shape is exactly nerd's: enumerate a parameter space (`filter` 0/1/2 × splitter models), generate one output per variant, line them up for comparison. But the comparison instrument is a person listening, not a metric that the executor can read and rank. nerd's verdict vocabulary (KEEP/CHANGE/REMOVE, theories REFUTED/SUPPORTED) assumes the experiment produces a number the harness compares against a threshold. There is no number here — the deliverable is "render all variants side-by-side so a human can pick."

This is not cleanly covered by ideas #1–6. The closest is #3 (reposition-execute-any-falsifiable-experiment), but the missing piece is not falsifiability — it's that the judge is a human ear, so nerd would need a "generate-and-present variants for human review" terminal state instead of an automated numeric verdict. Hence `new-pattern`.

## What would have helped

[no explicit suggestion given — the agent did not consider nerd, so it never articulated the gap. The latent signal: nerd has no mode for a parameter sweep whose verdict is "render N variants for a human to judge" rather than "measure a metric and compare to a threshold." A human-judge / perceptual-sweep terminal state would let nerd own this class of QA-harness task.]
