---
title: "A picker answer is approval only after the transcript check"
date: 2026-10-20
module: plugins/auto
problem_type: architecture_pattern
component: tooling
severity: high
category: architecture-patterns
tags:
  - claude-code
  - askuserquestion
  - approval
  - transcript
  - hooks
  - programme
applies_when:
  - "letting an AskUserQuestion answer approve or record a human decision"
  - "writing a PostToolUse or PreToolUse hook on AskUserQuestion"
  - "matching a picker answer against an option or a value list"
retire_when: "Claude Code documents a hook or event that delivers a picker answer with a harness-signed human origin; check the hooks reference for AskUserQuestion answer provenance."
---

## Context

The auto programme's setup walkthrough (branch `feature/programme-setup-in-mod`) lets Shawn answer setup questions in an AskUserQuestion picker, and those answers approve per-programme settings before the agreement is accepted. Typed approval already had a transcript check (`plugins/auto/docs/contracts/programme-prompt-source.md`). Picker answers needed their own, because they reach the session by a different road and the obvious hooks either do not see them or can be fed by the model.

## Guidance

1. **A picker answer never fires `UserPromptSubmit`.** It is a tool result. Hooks that journal typed prompts never see it.
2. **The model can answer its own picker.** AskUserQuestion takes an optional `answers` field in its own input (engine types: "User answers collected by the permission component"). A PostToolUse payload with answers therefore proves nothing about who chose. Deny a driving-session call whose input carries `answers` in PreToolUse, and still verify every pick from the transcript.
3. **What the transcript holds (Claude Code 2.1.304, observed in a live session):**
   - the assistant row: `message.content[]` has `{type: "tool_use", id, name: "AskUserQuestion", input: {questions: [...]}}`;
   - the answer row: `type: "user"`, `sourceToolAssistantUUID` equal to the assistant row's `uuid`, `toolUseResult.answers` (question text to chosen label or free text), and `permissionDecision: {decision: "accept", source: "user_temporary"}`;
   - no `origin`, `turnOrigin` or `promptSource` field, so the typed-prompt check cannot be reused.
   Rows written by Claude Code 2.1.292 and earlier carry no `permissionDecision`, so a check that requires it refuses every pick on those versions.
4. **Verify like the typed path, then add the pick conditions.** Capture the transcript path, byte offset, prefix hash and an answers hash when the PostToolUse hook fires (it carries `tool_use_id`). At approval time require: prefix unchanged; exactly one AskUserQuestion `tool_use` with that id and no `answers` in its input; exactly one result row linked by `sourceToolAssistantUUID`; a `permissionDecision.source` that starts with `user`; answers that hash to the captured value. Store the journal row as `unknown` and resolve it to `picked` only through that check; a stored `picked` label must never be trusted (`plugins/auto/lib/programme_pick_source.py`, `plugins/auto/lib/programme_prompt_source.py`).
5. **Tie each pick to what it answered.** Cite one pick once (key it on transcript path plus `tool_use_id`, not prompt id), require the question to name the setting, and match the answer strictly:
   - a single option: compare to the exact label after stripping a trailing "(Recommended)", case-insensitive. A substring test approved "don't take all recommendations", and a one-word negation check still approved "instead of take all recommendations, walk each step";
   - a multi-select list: require set equality between the options the answer names and the value. Containment let a pick of "tracker, tasks, plans" approve a value that silently dropped plans.

## Why This Matters

Each gap above lets something other than Shawn's choice approve a programme action, and none of them fails loudly: a pre-filled picker, a trusted label, a substring match or a containment check all produce a green approval. The review of this branch found the substring and containment gaps only by running the matcher on hostile answers (round 1 and round 2 of `ce-code-review`).

## When to Apply

Any time a picker answer is used as evidence of a human decision, in auto or elsewhere. A picker used only to steer the model's own next step needs none of this.

## Examples

```text
Answer                                               take-all match
"take all recommendations (Recommended)"             accept
"Take all recommendations"                           accept
"don't take all recommendations"                     refuse (substring test accepted it)
"instead of take all recommendations, walk each step" refuse (one-word negation accepted it)
```

Related: `docs/solutions/architecture-patterns/read-permission-refusals-from-the-transcript-not-hooks.md` (the same transcript-over-hooks trust model for permission refusals).
