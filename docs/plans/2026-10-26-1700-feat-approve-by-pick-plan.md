---
title: Approve By Pick - Plan
type: feat
date: 2026-10-26
topic: approve-by-pick
artifact_contract: ce-unified-plan/v1
product_contract_source: session
execution: code
---

# Approve By Pick - Plan

## Goal Capsule

- **Objective:** Shawn approves programme changes by picking an option the PM offers, or by accepting Claude Code's suggested prompt, instead of typing each approval by hand.
- **Means:** an accepted suggestion verifies as typed (U1). Every `--prompt` approval verb except the typed-only set also takes a verified pick (U2). The PM's instructions say to offer approvals as pickers (U3).
- **Product authority:** Shawn. Settled this session through pickers on 2026-10-26.
- **Open blockers:** none.
- **Execution profile:** Standard, three units, U1 then U2 then U3.
- **Finishes and ships:** one PR to `main`, squash-merged pinned to the reviewed head, published as auto 0.16.2.

---

## Product Contract

### Problem (verified 2026-10-26)

The Peek PM (programme `prog-20261018-102220-10892e`, session `aabe367e`) could not adopt three rules or add a worktree to the remit. Each approval verb refused with `prompt '<id>' is not typed (origin 'unknown'; human source unverified)`. The transcript rows for p0e070b, pb8eca7 and pf9b147 carry `promptSource: "suggestion_accepted"`: Shawn pressed Enter on Claude Code's suggested prompt. `programme_prompt_source._human_text` accepts only `promptSource == "typed"`. Patching that one check makes all three verify as `typed` against the live transcript, with no journal rewrite.

### Requirements

- R1. A user turn with `promptSource: "suggestion_accepted"` and all other human markers (`origin.kind human`, `turnOrigin human`, not meta, not sidechain, not compact summary) verifies as `typed`. The allowed promptSource values stay an explicit list (default-deny); any other value stays `unknown`.
- R2. Every approval verb that takes `--prompt <id>` also accepts a verified pick (origin `picked`, from the AskUserQuestion PostToolUse journal row), except the typed-only set.
- R3. Typed-only set: `accept-agreement` and `edit-project-term` (rulings and reserved areas). Keep it as one named constant beside the approval check. A pick given to one of these refuses with a one-line reason naming it typed-only. `adopt-rule` and `amend-term` take picks even though the setup walkthrough marks shared settings and the autonomy term `needs_typed`: Shawn's picker option named them as pick-approvable. The setup walkthrough's own `needs_typed` steps are unchanged.
- R4. A pick's journaled quote stays its `picked: <question> -> <answer>` summary, but the naming checks (`require_named`, `require_sources_named`, and promote-correction's all-projects negation scan) run against the answer text only, and a pick cited by a `--prompt` verb must hold exactly one question, as `programme_setup._answer_for` already requires. A question is PM-written, so `picked: Adopt rule r-12? -> No` must approve nothing. An option label must carry the exact rule id, path or value it approves. A pre-filled picker stays refused (existing `_unprefilled` check).
- R5. Every downstream verifier of an approval accepts a verified pick wherever it accepts typed. Today that is `programme_protocol._verify_adoption` (`origin != "typed"` at line 222), which `prompt_lookup` feeds for adopted rules, behaviours and carryover. Without it a rule adopted by a pick is rejected as `adoption_unverified` at load. The takeover/handover request checks in `programme_lifecycle.py` (lines 128-137) stay typed-only: those rows come from typed slash commands, not `--prompt` verbs.
- R6. The PM's instructions (`skills/programme-sweep/SKILL.md` approvals table, `commands/programme.md` setup section) say: when Shawn's approval is needed, ask in an AskUserQuestion picker whose option labels name exactly what is approved, then cite the pick's prompt id. `commands/programme.md` lines 88-90 ("anything else whose change only a typed reply approves") shrink to the real typed-only set.

### Out of scope

- Workspace-bound SendMessage (separate paused plan).
- Changing how picks are journaled.

### Known trade-off (accepted by Shawn)

A suggested prompt is written by a model that sees the PM's conversation, so the PM can steer the wording it wants approved, and a picker's options are written by the PM. Shawn chose convenience over that risk. The typed-only set (accept-agreement, and edit-project-term for rulings and reserved areas) keeps the strongest guard; setup's own `needs_typed` walkthrough steps stay typed. State this caveat in the PR body.

---

## Implementation

### Key Technical Decisions

- KTD1 (session-settled: user-directed — chosen over keeping the refusal with a clearer error: Shawn chose convenience): accepted suggestions count as typed everywhere.
- KTD2 (session-settled: user-directed — chosen over "only rules and remit" and "every approval": keep the strongest guard on the agreement and rulings): picks approve every `--prompt` verb except accept-agreement and edit-project-term (the R3 typed-only set).
- KTD3: verbs keep the `--prompt <id>` flag and accept a prompt id of either origin, so existing PM habits and the Stop hook advice text keep working. The approval check in `programme.py:_typed_prompt` accepts origin `typed` or `picked` (both resolved by `programme_journal.prompt_origin`, which already verifies picks through `programme_pick_source.verify`). A pick row's journaled `text` is its `picked: <question> -> <answer>` summary, so `quote` and `text_hash` keep their meaning. Record `origin` on the approval it returns.
- KTD4: `programme_protocol.py:222` accepts `picked` (R5), pinned by a test that a pick-adopted rule loads as adopted. `programme_import.py:144` is unchanged: stored labels are only `typed`, `cron` or `unknown`, never `picked`. The `programme_lifecycle.py` request checks stay typed-only (R5).
- KTD5: a pick cited through `--prompt` approves one change. `_typed_prompt` refuses a picked prompt whose (path, tool_use_id) an earlier approval row or a `PICK_KINDS` row already cited, sharing the ledger check in `programme_setup._picked`. A PM-worded pick is cheaper to replay than Shawn's typed text, and setup already treats one pick as one choice. Typed prompts keep today's behaviour.
- KTD6: the R3 typed-only gate lives where each typed-only verb calls the approval check (`accept-agreement` in `programme.py`, `edit-project-term` in `programme_terms._amend`), not in `_write`'s `verb` argument, which those calls do not pass.

### Units

- **U1 — suggestions verify as typed.** `lib/programme_prompt_source.py`. Red-first unit test with a fixture row mirroring the real shape (`origin.kind human`, `turnOrigin human`, `promptSource suggestion_accepted`, `entrypoint cli`). Also a test that an unlisted promptSource (e.g. `"queued"`) stays `unknown`. Sweep tests asserting a non-typed promptSource is refused; fix the ones now wrong.
- **U2 — picks approve.** `lib/programme.py` (`_typed_prompt` and the R3 gate), `lib/programme_terms.py` (edit-project-term typed-only), `lib/programme_protocol.py:222` (R5), `lib/programme_context.py:_source` (store `origin_label` from the approval's origin instead of a hard-coded `"typed"`). `programme_archive.py:525` inherits through `host._typed_prompt`. Intended test flips: `tests/unit/programme-setup.test.sh` (about lines 219-264) asserts picks are refused by amend-term, record-instruction, adopt-rule, accept-context, dispose-action and `_verify_adoption`; flip those to accept, and keep the accept-agreement refusal with the new typed-only wording. Tests: adopt-rule accepts a verified pick whose answer names the rule id; adopt-rule refuses a pick that does not name it; accept-agreement and edit-project-term refuse a verified pick; set-remit accepts a pick naming the added path; a rule adopted by a pick passes `_verify_adoption`; a pre-filled picker still approves nothing; adopt-rule refuses `picked: Adopt rule r-12? -> No`; promote-correction refuses a pick whose question names all projects and whose answer declines; a two-question pick is refused by `--prompt` verbs; a pick used once by adopt-rule is refused by a second adopt-rule and by pick-term; edit-project-term refuses a pick after acceptance; accept-context on a pick stores `origin_label: "picked"`.
- **U3 — PM instructions and docs.** `skills/programme-sweep/SKILL.md`, `commands/programme.md`, durability/schema docs and CONCEPTS where they define "typed". Runtime hint text too: the PostToolUse hint in `lib/on-posttooluse-askuser.py` ("Cite its prompt_id in setup verbs that take a pick") and the `_before_acceptance` refusal in `lib/programme_setup.py` ("after acceptance only a typed prompt approves") must name the `--prompt` route for picks and the typed-only set. Keep `_VERBS` reject text short (the size budget attributes it to `_h_adopt_check`).

### Verification

- Unit and integration suites through `honest-run`: unit equal to main's baseline (the vocabulary-audit failure is pre-existing on main), integration all green.
- Live check: with the edited lib, `programme_prompt_source.origin()` on the Peek journal rows p0e070b, pb8eca7, pf9b147 returns `typed`; p5f1483 and p2f54f0 stay `typed`.

### Sequencing

U1, U2, U3 in order; U2 and U3 touch shared verb text, so no parallel fan-out.
