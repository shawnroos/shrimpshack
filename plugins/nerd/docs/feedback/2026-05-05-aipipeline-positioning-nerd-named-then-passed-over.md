---
date: 2026-05-05
source_agent: claude (ai-service-hub vibe-transfer spike-0 session)
session_id: e3af86b4-ee19-4ac3-afc4-1c0a4a31f9e3
signal_type: positioning
idea_tag: parallel-routing-nudge
tags: [nerd-explicitly-named, lost-routing-decision, bespoke-skill-won, replicate-sweep, spike-0]
related_commands: [/nerd-this, /nerd:nerd]
outcome: not-invoked
---

## What happened

This is the rare case where the agent explicitly named nerd as the right tool — and still routed to the bespoke `/ai-pipeline-test` skill instead.

While writing the vibe-transfer requirements doc, the agent flagged the load-bearing assumption and named nerd-this as the verification tool, verbatim:

> "**NB will honor a structured profile passed as text.** Strong assumption. Needs a `nerd-this`-style sweep before locking the prompt — try at least 10 vibe-source × destination pairs across portraits, landscapes, and product shots, with the profile expressed in 2–3 different formats (JSON, prose, key:value) to find which the model honors most consistently."

It then offered the sweep as an explicit next-step option in an AskUserQuestion, again naming nerd:

> "Spike the analysis pipeline first" — "Before planning, run a nerd-this / replicate sweep to validate the load-bearing assumption: NB will honor a structured vibe profile and produce subject-locked output. ~$10–20 in Replicate. De-risks the whole feature."

The user picked the spike. But when it came time to actually execute, the agent routed away from nerd to the bespoke skill, framing the bespoke skill's description as the better fit:

> "Want me to invoke the dedicated AI pipeline spike skill for this — `/ai-pipeline-test` is exactly built for 'test AI tool pipelines via Replicate CLI — run models, iterate prompts, and tune weighting parameters before code ch[anges]'"

It then ran exactly the sweep it had described under nerd's name — "**3 prompt formats × 3 vibe sources × 5 destinations = 45 cells**", scored each cell against a pre-registered rubric, and wrote a verdict ("Format C: subject 4.93, composition 5.00 ... fails all gates" → U1 PASS) — under `/ai-pipeline-test`, not nerd.

The discriminator here is positioning, not unawareness: the agent *was* aware of nerd-this, recommended it twice by name, and still lost the routing decision at execution time because the bespoke skill's description ("test AI tool pipelines via Replicate CLI") read as a more literal match for the task than nerd's framing did.

## What would have helped

[no explicit suggestion — the agent didn't articulate why it switched off nerd, it just asserted the bespoke skill "is exactly built for" the task. The latent signal: when an agent has already named nerd-this as the verification tool, a routing nudge that recognizes "this is a falsifiable sweep you already framed as nerd-this" would prevent a more narrowly-described local skill from winning the execution decision.]
