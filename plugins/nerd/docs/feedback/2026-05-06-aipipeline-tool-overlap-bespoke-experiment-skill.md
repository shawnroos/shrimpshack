---
date: 2026-05-06
source_agent: claude (ai-service-hub /ai-pipeline-test sessions)
session_id: 0f0d4e66-8a61-4424-9caa-02509ce9f244
signal_type: tool-overlap
idea_tag: reposition-execute-any-falsifiable-experiment
tags: [bespoke-experiment-skill, hand-built-nerd-parallel, replicate-cli, parameter-sweep, baseline-variant-compare, competing-tool]
related_commands: [/nerd:nerd, /nerd-this]
outcome: not-invoked
---

## What happened

Someone hand-built nerd's entire experiment loop as a separate project-local skill, `/ai-pipeline-test`, and invoked it across three sessions in the ai-service-hub worktree. The skill's own description is verbatim:

> "Test Slate AI tool pipelines directly via the Replicate CLI. Use this to iterate on prompts, tune guidance/steps/temperature, and validate model behavior before touching application code."

The skill body itself contains sections literally titled "Parameter Sweep" (with `# Guidance sweep for Flux Fill`, `# Steps sweep`, `# Temperature sweep for LLaVA analysis`), "Prompt A/B Testing Pattern" (`# Variant A — current production prompt` / `# Variant B — experimental prompt` / `# Compare visually`), "Evaluate Results" ("**Compare against baseline** — does it match expected quality? ... **Decide next step** — adjust prompt, tune params, or confirm the config is ready"), "Multi-Step Pipeline Testing", and a "Cardinality Check (MANDATORY...)" with an abort criterion ("**Median ≥ threshold** → Greenlight UX work ... **Median < 0.** → ... lower-cardinality UX"). That is parameter-scanner + experiment-executor + report-compiler, hand-coded as a competing skill.

The work it actually ran was nerd-shaped in all three sessions:

- `0f0d4e66` — command-args: "Take a look at the most recent expand image output on Replicate." The agent designed a sweep ("**5 variants × 3 seeds = 15 runs ≈ $0.60**"), ran a baseline-vs-variant scoring pass per cell ("v1_seed1: ✅ Pass ... **v1 baseline scoring: 3/3 pass.**" / "v2_seed1: ✅ Pass"), and produced a refute-style verdict ("**the baseline prompt works perfectly at the NB Stage 1 level** ... so why did production fail?").
- `9756cef7` — command-args: "lets do this properly - formulate hypotheses test confirm/deny use the B+W image and the ones here". The agent wrote competing hypotheses in a table ("**H1** ... is the primary identity-drift cause ... **H2** ... **H3** ... **H4** the prompt isn't the dominant factor"), ran "4 variants × 3 images × 3 runs = **36 NB Pro calls @ 1K** ≈ $0.72", and reached a verdict: "**This proves hypothesis H4** ... H1, H2, H3 are all wrong — removing BLIP-2 caption, adding identity lock, B&W guard — none of them changed [it]."
- `e3af86b4` — command-args: "use this to try as many prompts and approaches as is helpful", then "continue spike-0 sweep monitoring — final scoring + write verdict". The agent ran "**3 prompt formats × 3 vibe sources × 5 destinations = 45 cells**" against a pre-registered rubric ("subject-identity preservation (1–5), composition preservation (1–5), vibe-application strength (1–5), face drift on portraits (binary). Pass criteria: <5% face drift on portraits; mean subject-identity ≥ 4.0") and produced a definitive numeric verdict: "**Format C: subject 4.93, composition 5.00, vibe 5.00, ZERO leakage, ZERO face drift** ... **Format A: 1/6 portraits drift (16.7%), 3/15 cells leak JSON-as-image, fails all gates** ... Format C is decisively the winner."

nerd was never on the menu in any of these runs (the only `/nerd` strings in the transcripts are inside base64 image data). The competing skill was reached for instead — three times.

## What would have helped

[no explicit suggestion — nerd was never considered; the agent reached for the bespoke skill that already existed for "test AI tool pipelines via Replicate CLI." The signal is that the experiment loop was valuable enough that someone built a parallel implementation of it from scratch, with the same vocabulary (parameter sweep, variant A/B, baseline compare, abort criterion), because nerd's framing never claimed this territory.]
