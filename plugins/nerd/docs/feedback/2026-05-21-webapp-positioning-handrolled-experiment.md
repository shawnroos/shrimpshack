---
date: 2026-05-21
source_agent: claude (ai-service-hub text-layer-as-rendered-image session)
session_id: b1c829a6-b99a-4eb1-b666-230d57cd6505
signal_type: positioning
idea_tag: reposition-execute-any-falsifiable-experiment
tags: [hand-rolled-experiment, baseline-variant-compare, refuted-verdict-by-hand, should-have-been-nerd]
related_commands: [/nerd:nerd, /nerd-this]
outcome: not-invoked
---

## What happened

The agent designed and ran nerd's exact workflow by hand, never considering nerd. It wrote:

"**Experiment plan:** 1. **Step 1 (verify input):** Generate a transparent PNG of "Hey" via Pixi-style rendering ... 2. **Step 2 (baseline):** Reproduce the bug — run NB pro with the current `LIGHTING_PROMPT_TEMPLATE` and Rembrandt preset against the transparent text PNG. Confirm we see black-bg output. 3. **Step 3 (variant A — prompt prefix):** Prepend a transparent-bg preservation clause and re-run. 4. **Step 4 (variant B — text-specific template):** Test a fundamentally different template framing the input as a text element, not a photograph. 5. **Step 5 (compare):** Inspect outputs visually, pick winner."

It then stated a hypothesis, swept the variants, and produced a REFUTED-style verdict by hand: "Let me first run the experiment correctly to **prove** the hypothesis" → "Now restructure the variants to specifically test the JPG vs PNG hypothesis with the **baseline prompt**" → "**Critical finding revised.** ... This means: **PNG vs JPG output format doesn't fix the problem.**"

That is parameter-scanner → experiment-executor → report-compiler — baseline, competing variants, compare, pick winner, refute the hypothesis — executed entirely by hand because nerd was never on the menu.

## What would have helped

[no explicit suggestion — the agent never surfaced nerd, so it gave none. The signal is that nerd's "discover unknown parameters" framing kept it off the menu for a falsifiable experiment the agent had already fully designed.]
