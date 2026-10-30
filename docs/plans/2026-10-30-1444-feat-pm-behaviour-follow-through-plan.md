---
title: PM Behaviour Follow-Through - Plan
type: feat
date: 2026-10-30
topic: pm-behaviour-follow-through
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-brainstorm
execution: code
---

# PM Behaviour Follow-Through - Plan

## Goal Capsule

- **Objective:** Each sweep, the PM is told which of Shawn's behaviours apply to the items whose trigger has passed, and cannot end the sweep as quiet until it has answered each one.
- **Means:** A trigger field on each behaviour, a "behaviours due" list in the sweep digest, and a rule that an unanswered due behaviour keeps the sweep open.
- **Product authority:** Shawn. Only a typed prompt approves a new or changed behaviour (unchanged by this work).
- **Open blockers:** None.
- **Scope of this plan:** The PM side only. Worker-side checks and `agent-check` enforcement are not active scope (see Scope Boundaries).

## Product Contract

### Summary

The PM never sees behaviours unless it remembers to run `P rules`, and the digest-driven quiet sweep (auto 0.16.8) lets it skip that step. The Studio programme `prog-20261029-122819-86a88d` shows the result: 14 behaviours recorded, 4 sent to workers at start, 0 `remind-behaviour` rows across the whole journal. This work makes the sweep put due behaviours in front of the PM and hold the sweep open until each is answered.

### Problem Frame

Measured on the Studio journal (1,170 rows, 2026-10-29 to 2026-10-30):

- `programme_sweep_inputs.py` puts only a rule count and rule ids in the digest. No behaviour text reaches the PM.
- `items_changed` is already in the digest, so the trigger moment exists; behaviours are not tied to it.
- A behaviour's PM check is free text ("an item has a PR whose merge state is CLEAN"). The trigger (`claim|merge|block`) exists only as an argument to `remind-behaviour`, not on the behaviour.
- Workers do receive behaviours at start (`behaviour_ids` on 15 of 19 `worker_started` rows). Nothing reaches a worker already running.

### Key Decisions

- **The digest lists due behaviours; the PM sends them.** The sweep works out which behaviours apply to changed items and lists them; the PM reads the check text and runs `remind-behaviour`. Governs R2, R3. (session-settled: user-directed — chosen over automatic sending and over listing every behaviour: keeps the PM's judgment on relevance without relying on it to remember the list.)
- **A behaviour carries a trigger.** Governs R1. (session-settled: user-directed — chosen over a packager agent matching free text: a model guess should not decide what the PM sees.)
- **A due behaviour stays open until answered.** Governs R4. (session-settled: user-directed — chosen over report-only: a busy or compacted PM can still skip a line it is not forced to answer.)
- **Existing behaviours are due on every claim until given a trigger.** Governs R5. (session-settled: user-directed — chosen over never-due and over a one-time trigger proposal: a claim is the one change every item produces.)

### Requirements

**Trigger on the behaviour**

- R1. A behaviour records when it applies: `claim`, `merge`, `block` or `start` (a worker started on the item). Recording and moving verbs accept it, and `P rules` prints it.
- R5. A behaviour recorded before this change, with no trigger, is due on `claim`.

**Digest and sweep**

- R2. For each item whose behaviour trigger has passed, the digest lists each behaviour in force for that item that the item has no answer for: no `relevant`, `sent_back` or `skipped` delivery (and, for `start`, no `brief` delivery). Each line names the behaviour id, its PM checks and the item.
- R3. An `agent-check` behaviour appears in the same list marked "judge". A behaviour that applies to the PM only appears marked "PM applies".
- R4. A due behaviour keeps the sweep verdict `changed`. It leaves the list only when the PM records either a reminder (`remind-behaviour`) or "does not apply" for that item, and the journal holds a row for whichever it chose.
- R6. The PM can record "does not apply" for a behaviour on an item with a one-line reason.

### Key Flow

- F1. Item changes, behaviour answered
  - **Trigger:** A claim arrives for item `task:ship-x`.
  - **Steps:** The sweep reads the claim and finds `items_changed`. The digest lists behaviours whose trigger is `claim`. The PM reads each check against the claim, sends `remind-behaviour` for those that hold, and records "does not apply" for the rest.
  - **Outcome:** Every listed behaviour has a journal row for that item; the next sweep can be quiet.

### Acceptance Examples

- AE1. Covers R2, R4. Given a behaviour with trigger `merge` and an item whose PR just merged, when the sweep runs, the digest lists the behaviour for that item and the verdict is `changed`; after the PM sends the reminder, the next sweep does not list it again.
- AE2. Covers R5. Given a behaviour recorded before this change and a new claim, when the sweep runs, the digest lists it as due on `claim`.
- AE3. Covers R3. Given a behaviour with only an `agent-check` and a matching trigger, the digest lists it marked "judge", and it still keeps the sweep open until answered.
- AE4. Covers R6. Given a due behaviour that does not hold for the item, when the PM records "does not apply" with a reason, the journal gains a row and the line leaves the digest.

### Success Criteria

- On a throwaway programme: record one behaviour with a trigger, change an item, and the digest lists it; a quiet sweep is impossible until it is answered.
- A journal read of any programme can count, per behaviour, how many items it was due on and how many were answered: reminded or "does not apply".

### Scope Boundaries

**Deferred for later**

- Worker-side detection that a worker broke a behaviour (a hook or transcript check).
- Reaching workers already running when a behaviour is recorded, other than through a due line on their next change.
- A Programme view count of delivered, followed and broken per behaviour.

**Outside this plan**

- Making `agent-check` behaviours verifiable.
- Changing which prompts count as verified human prompts (the `queued` source in `programme_prompt_source.py`); ask Shawn before touching it.
- The PM passing a local path where a remit repo key is required (16 `move-behaviour` refusals in the Studio journal); a separate small fix.

### Dependencies / Assumptions

- The digest generator (`plugins/auto/lib/programme_sweep_inputs.py`) and the packager agent can carry a new section (confirmed in planning; see U4).
- The `start` trigger assumes `start-worker` already delivers behaviours at start; this plan does not change that.
- `plugins/auto/lib/programme_behaviours.py` is 934 lines against a 1000-line budget, so the new logic goes in its own modules (KTD5).

### Outstanding Questions

**Deferred to Planning**

- Which evaluation backs the release. Shawn's standing rule: nothing is published until it has been through an eval, and the experiment is named. Planning proposes the replay check in the Verification Contract; Shawn confirms it or names another.
- Whether Shawn needs a way to set a trigger on an already-recorded behaviour without retiring and re-recording it. This plan leaves existing behaviours on the `claim` default.

### Sources / Research

- Studio journal `~/.claude/plugins/data/auto-shrimpshack/programmes/prog-20261029-122819-86a88d/journal.jsonl` (read over `ssh studio`).
- `plugins/auto/lib/programme_sweep_inputs.py` (`_facts`, `_verdict`, `build`), `plugins/auto/skills/programme-sweep/SKILL.md` steps 1, 5, 8, 11, `plugins/auto/lib/programme_behaviours.py` (`TRIGGERS`, `remind` verb).
- Original design: `docs/plans/2026-10-20-1359-feat-programme-behaviours-plan.md`.

## Planning Contract

**Product Contract preservation:** restructured, no scope change. The Objective and R2 were reworded after review to say what the Key Decisions already meant (due when the trigger has passed and no answer exists, including a `skipped` answer); R-IDs are unchanged. Two deferred questions were answered by planning, and the `start` trigger is resolved in KTD3 without changing R1.

### Key Technical Decisions

- KTD1. **The trigger lives at `when.trigger`, optional, and an absent trigger reads as `claim`.** Existing behaviours need no backfill and no store rewrite, which is how R5 holds. `_check_when` in `plugins/auto/lib/programme_behaviours.py` today rejects any key other than `text` and `checks`, so it gains `trigger`. Governs R1, R5.
- KTD2. **"Due" is level-triggered, not edge-triggered.** An item is due for a behaviour when its trigger has passed and the item holds no answer for that behaviour, however many sweeps ago the trigger passed. This is what makes R4 hold across a compacted or skipped sweep; an edge on "changed since last sweep" would let one missed sweep lose the line. A behaviour is due only for a trigger that passed after the behaviour was in force (`since(entry)` at or before the trigger time, the rule `timing` already uses), so recording a behaviour does not list every old item. An item is considered unless it is `handed`, `dropped` or `decided` (`CLOSED_ITEM_STATES`); a `done` item is still considered, because a `merge` trigger makes a single-deliverable item `done` at the same instant. Governs R2, R4.
- KTD3. **`start` is due only when the worker started without being given the behaviour.** `start-worker` already delivers behaviours at start (a `brief` delivery). For the `start` trigger a `brief` delivery counts as an answer; for the other triggers it does not (the sweep skill already says so). Governs R1, R2.
- KTD4. **The answer is a delivery row with reason `skipped` or `applied_by_pm`, written by a new verb `skip-behaviour <item> <id> --why <line> [--applied]`.** `--applied` records that the PM applied a PM-only behaviour itself; without it the row means "does not apply", so a journal count can tell followed from not applicable. It reuses `record_delivery` and the item's `behaviour_deliveries`, so `programme_view.behaviours_view` and the "already answered" test need no new store. It needs no typed prompt: it records the PM's judgment, not Shawn's approval. The verb resolves the behaviour for any audience (`in_force` with no audience filter), not through `_for_workers`, which refuses a PM-only behaviour. Governs R3, R4, R6.
- KTD5. **The due computation is a new module, `plugins/auto/lib/programme_behaviours_due.py`.** `programme_behaviours.py` is 934 of 1000 lines and `size-budget.test.sh` fails the build above the budget; its growth is limited to the U1 items named after this clause. The new modules are pure over the record, the behaviours store and the journal, so a table test can exercise them. `programme_behaviours.py` keeps only the trigger accessor, the `--trigger` option, the trigger-value check and the `TRIGGERS` extension (U1); the `start` trigger time is computed in `programme_behaviours_due.py`, not in `trigger_times`. Governs R2.
- KTD6. **`sweep-inputs` carries the list; the packager only copies it.** The verdict gains the code `behaviours_due` computed in `_verdict`, so a model never decides whether a sweep is quiet. The packager agent writes a "Behaviours due" digest section from the new `behaviours_due` field and lists overflow by id. Governs R2, R4.

### High-Level Design

> *Directional guidance for review, not implementation specification.*

```
sweep-inputs build
  facts.due = behaviours_due.due(record, store, journal)
      for item not handed/dropped/decided
        for b in behaviours in force for item (audience: PM or workers)
          t = trigger time of trigger_of(b) on item        # claim | merge | block | start
          answered = any delivery on item for b.id with reason in
                     (relevant, sent_back, skipped, applied_by_pm[, brief when trigger == start])
          if t >= b.since and not answered: emit {item, id, trigger, pm_checks, judge, mark}
  verdict.why += ["behaviours_due"] when facts.due is non-empty
PM, from the digest section
  checks hold      -> remind-behaviour <item> <id> --reason relevant --trigger <t>
  does not hold    -> skip-behaviour   <item> <id> --why "<line>"
  PM-only, applied -> skip-behaviour   <item> <id> --applied --why "<what you did>"
next sweep: those lines are gone; no other reason -> quiet
```

### Implementation Units

- U1. **Trigger on the behaviour**
  - **Goal:** A behaviour carries an optional trigger; none reads as `claim`.
  - **Requirements:** R1, R5.
  - **Dependencies:** None.
  - **Files:** `plugins/auto/lib/programme_behaviours.py` (`_check_when`, `_draft`, `_FIELD_VALUES`, `_FIELDS_DOC`, `_short`, `TRIGGERS`, the `remind-behaviour` usage and refusal text), `plugins/auto/lib/programme_view.py` (`_behaviour_row`, `_behaviour_text`), `plugins/auto/docs/contracts/programme-behaviours-format.md`, `plugins/auto/tests/unit/programme-behaviours.test.sh`.
  - **Approach:** Add `--trigger claim|merge|block|start` to `record-behaviour` and `propose-behaviour`; store it as `when.trigger`; add a `trigger_of(entry)` accessor that defaults to `claim`; print it in `P rules`. A move or keep copies `when` unchanged, so it carries the trigger. Add `start` to `TRIGGERS` so `remind-behaviour --trigger start` works, and make `_check_when` reject a `trigger` outside the allowed values (`bad_value`, `when.trigger`) so a hand-edited store entry cannot crash the sweep. Stay under 1000 lines in this file.
  - **Execution note:** Test-first: a failing case for an old entry with no trigger proves R5 before code changes.
  - **Patterns to follow:** The `--pm-check` option handling in `_draft`.
  - **Test scenarios:** A behaviour recorded with `--trigger merge` stores and prints it. One recorded without a trigger reads `claim`. An unknown trigger value is refused at the option with a `fix:` line naming the allowed values, and a store entry with `trigger: never` is rejected on load. `remind-behaviour --trigger start` succeeds, and `--reason sent_back` for `start` is refused as remind-only. A store entry written before this change still loads. A moved behaviour keeps its trigger.
  - **Verification:** `programme-behaviours.test.sh` passes and `size-budget.test.sh` passes.

- U2. **Compute the due list**
  - **Goal:** A pure function lists the behaviours due per open item.
  - **Requirements:** R2, R3, R5.
  - **Dependencies:** U1.
  - **Files:** `plugins/auto/lib/programme_behaviours_due.py` (new), `plugins/auto/tests/unit/programme-behaviours-due.test.sh` (new). The `start` trigger time is the earliest `started` history row of the item (`plugins/auto/lib/programme_sources.py:689` writes it).
  - **Approach:** Follow KTD2 and KTD3. Reuse `in_force` (with `store=load_store(lookup)`) and `trigger_times`; skip a behaviour for an item already holding `relevant`, `sent_back`, `skipped` or `applied_by_pm`; read the trigger with `.get` so a bad value lists nothing. Mark an `agent`-check-only behaviour `judge` and a behaviour that applies to the PM only `PM applies`. Cap the list (a constant like `PR_CAP` in `programme_sweep_inputs.py`) and return the overflow as a count plus ids.
  - **Test scenarios:** Covers AE1: a `merge` behaviour and a merged item is due; after a `relevant` delivery it is not. Covers AE2: a trigger-less behaviour is due at a claim. Covers AE3: an `agent-check` behaviour is marked `judge`. A `dropped`, `handed` or `decided` item is never due. A single-deliverable item whose merge was just confirmed (effective state `done`) lists its `merge` behaviour. A trigger that passed before the behaviour was recorded lists nothing. A `start` behaviour with a `brief` delivery is not due; a `claim` behaviour with a `brief` delivery is. An item with no trigger passed lists nothing. Cap overflow reports the count.
  - **Verification:** The new suite passes.

- U3. **`skip-behaviour` verb**
  - **Goal:** The PM can record "does not apply" for an item and a behaviour.
  - **Requirements:** R4, R6.
  - **Dependencies:** U1.
  - **Files:** `plugins/auto/lib/programme_behaviours_skip.py` (new, separate from the due module), `plugins/auto/lib/programme.py` (register next to `programme_behaviours.build_verbs` near line 908, and the errors list near 916), `plugins/auto/lib/programme_journal.py` (add `behaviour_skipped` to `KINDS`), `plugins/auto/lib/programme_fixes.py` (a `FIXES` entry for the verb), `plugins/auto/docs/contracts/agent-tool-surface.md`, `plugins/auto/docs/contracts/run-record-schema.md` (delivery reasons and journal kinds), `plugins/auto/tests/unit/programme-verbs.test.sh` (hard-coded verb list), `plugins/auto/tests/unit/refusal-fixes.test.sh`, `plugins/auto/tests/unit/doc-fence-run-record-schema.test.sh`.
  - **Approach:** Follow KTD4. Mirror `_h_remind`'s item lookup and driving-session guard, but resolve the behaviour for any audience; write through `host._write` with a `behaviour_skipped` journal kind. Refuse an unknown behaviour or item, a retired behaviour and a missing `--why`, each with a `fix:` line from the new `FIXES` entry.
  - **Test scenarios:** Covers AE4: the call writes the delivery row and the journal row, and the same behaviour is no longer due. A session that does not drive the programme is refused. An empty `--why` is refused. A PM-only behaviour accepts `--applied` and records `applied_by_pm`. The verb appears in the tool-surface and run-record doc-fence tests and in the refusal-fixes test.
  - **Verification:** `programme-verbs.test.sh`, `refusal-fixes.test.sh`, `doc-fence-agent-tool-surface.test.sh` and `doc-fence-run-record-schema.test.sh` pass.

- U4. **Digest field, verdict code and packager section**
  - **Goal:** The sweep verdict holds `changed` while behaviours are due, and the digest shows them.
  - **Requirements:** R2, R3, R4.
  - **Dependencies:** U2, U3.
  - **Files:** `plugins/auto/lib/programme_sweep_inputs.py` (`_facts`, `_verdict`, `build`), `plugins/auto/agents/programme-sweep-packager.md`, `plugins/auto/tests/integration/programme-sweep-inputs.test.sh`, `plugins/auto/tests/unit/programme-sweep-packager-skill.test.sh`.
  - **Approach:** Add `due` to `_facts`, wrapped so an unreadable behaviours store yields an empty list and a `behaviours_store_unreadable` why code instead of an exception; the `behaviours_due` code to `_verdict`'s table, and a `behaviours_due` field to `build`. Add a "Behaviours due (source: behaviours_due)" section to the digest template with one line per entry (`item | behaviour id | trigger | PM checks | judge/PM applies`) and an overflow line by id. Keep the digest under its 6,000-character limit.
  - **Test scenarios:** Covers AE1: a programme with a due behaviour reads `changed` with `behaviours_due` in `why`; after a `remind-behaviour` or `skip-behaviour` it reads `unchanged` again. The existing `unchanged` cases still pass with no behaviours recorded and with an unreadable store (the `behaviours_store_unreadable` code, no crash). The digest template test finds the new section and source name.
  - **Verification:** Both suites pass.

- U5. **Sweep skill and reference text**
  - **Goal:** The PM's instructions tell it to answer each due line.
  - **Requirements:** R2, R3, R4, R6.
  - **Dependencies:** U3, U4.
  - **Files:** `plugins/auto/skills/programme-sweep/SKILL.md` (step 1's quiet-sweep list, step 5's behaviours bullet), `plugins/auto/skills/programme-sweep/references/behaviours.md`, `plugins/auto/tests/unit/programme-sweep-skill.test.sh`, `plugins/auto/tests/unit/programme-sweep-packager-skill.test.sh`.
  - **Approach:** Step 5 becomes: read the digest's "Behaviours due"; for each line either remind or skip; apply a PM-only behaviour yourself and then skip with a why. Add `behaviours_due` to the quiet-sweep list. Keep the existing rule that step 8 sends back work that skips a behaviour. `skills/programme-sweep/SKILL.md` is 39,251 bytes against a 39,630-byte cap in `programme-sweep-packager-skill.test.sh`: put the detail in `references/behaviours.md` (not capped) and keep the SKILL.md edit net-zero or smaller. Remove any text now stale ("`P rules` prints each behaviour's PM checks" remains useful for judging).
  - **Test scenarios:** The skill test finds the new step text and the `skip-behaviour` verb; no instruction refers to a step that no longer exists.
  - **Verification:** `programme-sweep-skill.test.sh` and `programme-sweep-packager-skill.test.sh` pass.

### Sequencing

U1 first. U2 and U3 can then run in parallel (separate new modules; only U3 touches `programme.py`, `programme_journal.py` and `programme_fixes.py`). U4 follows U2 and U3. U5 follows U4. The whole plan is one PR on `plugins/auto`.

### Risks

- **First-sweep flood (R5).** The 14 existing behaviours are due at every item whose claim came after the behaviour was recorded. KTD2's recorded-before-trigger rule and the list cap bound it; the replay check below measures it before release.
- **Merge trigger on a finished item.** A `merge` behaviour must still list for an item that became `done` at that merge; U2 has a test for it, and the replay check covers it.
- **Older plugin versions reading the new store.** `_check_when` rejects unknown keys, so a session on an older cached `auto` version sees a behaviour carrying `when.trigger` as rejected. Only behaviours recorded with `--trigger` are affected; existing ones are untouched.
- **PM compaction.** The skill step is still prose; the verdict is mechanical. A PM that never runs the sweep skill still cannot get a quiet sweep while lines are open.
- **Version collision.** `plugin.json` is at 0.16.8 and `fix/bounded-transcript` claims 0.16.9; the version bump belongs to whoever releases second.

## Verification Contract

- Unit and integration suites for the files above: `bash plugins/auto/tests/unit/programme-behaviours.test.sh`, `programme-behaviours-due.test.sh`, `refusal-fixes.test.sh`, `doc-fence-run-record-schema.test.sh`, `programme-verbs.test.sh`, `programme-sweep-skill.test.sh`, `programme-sweep-packager-skill.test.sh`, `doc-fence-agent-tool-surface.test.sh`, `size-budget.test.sh`, and `plugins/auto/tests/integration/programme-sweep-inputs.test.sh`. Run each through `~/.claude/tools/honest-run/run.sh` and confirm each suite's real pass marker before using `--expect`; a run with no verdict line did not finish.
- **Replay check (proposed release evidence):** copy the Studio programme record and journal (`prog-20261029-122819-86a88d`) to a scratch directory, run the new due computation against it, and record the due count, the digest size and the number of sweeps that would stay quiet once lines are answered. Pass: the count is bounded by the cap and the digest stays under 6,000 characters.
- Throwaway-programme check: record a `merge`-trigger behaviour, merge an item, see the digest line and a `changed` verdict, answer it, see `unchanged`.

## Definition of Done

- All requirements R1 to R6 hold under AE1 to AE4 on a throwaway programme, with the suites above green on the PR's head.
- `programme_behaviours.py` is at or under 1000 lines and no new allowlist entry in `size-budget.test.sh`.
- The replay check result is recorded in the PR, and Shawn has confirmed it as the release evidence or named another.
- The PR is merged and the plugin released per the repo's release rule; no abandoned-attempt code remains in the diff.
