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
  - "letting a picker answer or an accepted prompt suggestion approve a command, not only a setup choice"
last_updated: 2026-10-26
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
6. **When a pick approves a command, bind the answer to the exact command, never to its words.** Branch `feature/approve-by-pick` widened picks from setup to approval verbs (`adopt-rule`, `amend-term`, `drop-item` and others). It first judged the answer's intent from free text, and three review rounds in a row each found a decline that still approved:
   - "No" approved, because the naming check looks only at the word before a name and the PM's question named the rule;
   - "Skip r1" approved past a negation denylist;
   - "Keep item-x" approved `drop-item` past an opener allowlist that was not tied to the verb.
   Exact labels closed it. `label(argv)` in `plugins/auto/lib/programme_approval.py` is "Approve " plus the shell-quoted verb and arguments, without `--prompt` and `--run`. A pick approves only when its single answer, minus a trailing " (Recommended)", equals the label of the command actually being run. The read-only verb `approval-label` prints the label, and the PM uses it word for word as the approve option. Every other option approves nothing, whatever its wording. Three corollaries:
   - a verb whose change arrives on stdin (`set-remit`) cannot be bound by a label, so picks refuse it;
   - an option value may not start with `--`, or `--why --run x` lets two different commands share one label;
   - picks reach only a default-deny allowlist of verbs (`PICK_VERBS`), so a verb added later refuses picks until someone adds it on purpose.
7. **An accepted prompt suggestion is not typed text.** When Shawn presses Enter on Claude Code's grey suggested prompt, the transcript row carries `promptSource: "suggestion_accepted"` (observed in Claude Code 2.1.310), not `"typed"`. A model wrote that text, so auto resolves it to its own origin, `suggested`, which approves only what a pick may approve. Typed-only verbs and takeover requests still need text Shawn typed.

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

Approval label (item 6):

```text
Command                                   Approve option            Any other answer
programme.sh adopt-rule r1 --prompt p7    "Approve adopt-rule r1"   approves nothing ("No", "Skip r1", "Keep r1 as a proposal")
```

Related: `docs/solutions/architecture-patterns/read-permission-refusals-from-the-transcript-not-hooks.md` (the same transcript-over-hooks trust model for permission refusals).
