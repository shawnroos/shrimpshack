---
date: 2026-05-15
source_agent: claude (Slate denoise QA harness session)
session_id: 0ad1342c-1c08-42dc-b2f6-41db0862bb9e
signal_type: positioning
tags: [parameter-sweep-as-feature, ce-brainstorm-ce-plan-spine, nerd-never-considered, denoise-strength-variants]
related_commands: [/nerd:nerd, /ce-brainstorm, /ce-plan]
outcome: not-invoked
idea_tag: reposition-execute-any-falsifiable-experiment
---

## What happened

The user asked, verbatim:

> "There are apparently guidance that we can give the noise removal plugin, which will apply strength. What I'd like to do is create a temporary solution for the purposes of testing, where we will offer multiple levels of strength of noise reduction... we'll be able to test the various levels by clicking on a UI that cycles through our options... we will need to generate file for every single level of noise reduction we apply. /ce-brainstorm"

The agent then walked through the parameter space entirely inside the CE planning pipeline. From its own reasoning:

> "`denoise.service.ts:50-54` — `DEFAULT_DENOISE_OPTIONS = { stem: 'vocals', filter: 1, splitter: 'perseus' }`. The `filter` param is the strength knob."

> "So there are actually **two strength axes** we could vary, and we should pick:" [filter 0/1/2, and three splitter models phoenix/orion/perseus]

> "4 variants locked: prod-default reference + filter 0/1/2 on perseus."

This is a textbook parameter sweep — competing variants over a tunable knob (`filter`), against a known evidence signal (the agent noted "Anaheim Ducks complaint is the concrete signal; PR #4116 already executed against it; we just don't know if Perseus helped"). nerd was in the session's skill catalog (the `skill_listing` attachment lists `nerd:nerd`), but it was never invoked, mentioned, or reasoned about. The work routed `/ce-brainstorm` → `/ce-plan` → `/ce-work` and produced a hand-built denoise QA panel component instead.

The difference from the prior ce-debug overlap signal (session 4435cee2): there the agent recognized nerd and chose ce-debug; here nerd was simply invisible. Framing the task as a "feature" pulled it into the CE planning spine, where nerd does not surface as a candidate at all.

## What would have helped

[no explicit suggestion given — the agent never surfaced nerd as an option, so it never reasoned about why not. The signal is that "find every tunable parameter" never gets considered when a parameter study arrives framed as a feature request entering /ce-brainstorm.]
