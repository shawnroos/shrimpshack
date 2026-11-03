---
artifact_contract: ce-unified-plan/v1
execution: code
product_contract_source: ce-plan-bootstrap
type: feat
title: "feat: the behaviour check offers synergies and edits to existing behaviours - Plan"
date: 2026-11-03
origin: docs/handoff.md
---

# feat: the behaviour check offers synergies and edits to existing behaviours - Plan

## Goal Capsule

**Objective:** When Shawn's words become a standing behaviour, the PM shows him, in the same message as the conflicts, which existing behaviours the new one should link to, extend or share a moment with, and offers a concrete edit to an existing behaviour where one is due. Nothing blocks and nothing changes until Shawn types his answer.

**Means:** Code returns structured synergy candidates and the target of each offered edit. The PM writes the wording. An offered edit is saved as a proposal and applied only on Shawn's typed words (KTD1, KTD3).

**Authority hierarchy:** Shawn's ruling of 2026-11-03 (never blocks; offers edits; finds synergies) and the PM's confirmation of scope on 2026-11-03 > this plan > `plugins/auto/docs/contracts/programme-behaviours-format.md`. A behaviour carries no authority; a protected escalation is never named in a do line.

**Stop conditions:** Stop and report to the PM if the work needs a decision Ruling, a plugin publish, or a change to how the personal behaviours folder is guarded.

**Ships:** One PR to `main`. No version bump, no publish.

---

## Product Contract

### Summary

Today `check-behaviour` and `record-behaviour` list the behaviours a new one applies alongside and flag possible conflicts. They do not say how two behaviours should fit together. This work adds synergy rows and offered edits to the same result, so the PM can show Shawn "this new behaviour and that old one should reference each other, here is the edit".

### Problem Frame

The real pair: `b51850c` (when a worker's work is merged, reflect and stop; take no new work) and `bc3f80d` (every sweep, move every session in the remit forward; do not stop at a report). They are compatible, but `bc3f80d` should say that a finished session is retired by `b51850c`, not moved forward. Nothing linked them and nothing offered the edit. `b51850c` and `bc3f80d` live in the live programme record, not in the stored set on this machine, so the test fixture is built from their quoted shape (the brief quotes `b51850c` in full).

Measured on this machine (names and counts only; 20 stored active behaviours, 204 ordered co-applying pairs): no pair shares an explicit trigger, no pair shares a named tool (only 2 of 20 set a trigger and 3 of 20 name a tool), and a first draft of the ending-rule test finds 2 candidate pairs. So the ending-rule kind has signal today, and the other two kinds are quiet until behaviours carry triggers and tools. Quiet is not noise; they stay (PM call-out 1).

### Requirements

**Synergy rows**
- R1. `check-behaviour` and `record-behaviour` return a `synergies` list beside `behaviours` and `contract`. A row names the existing behaviour (`ref`), a closed `kind`, the words or tool that caused it, and both sides' `do`, `dont` and `stop` lines.
- R2. Three kinds: `shared_moment` (the pair already listed by `same_trigger` or `shared_when`), `shared_tool` (the pair already listed by `shared_tool`), and `ending_rule` (one behaviour ends or retires the work its situation names, and the other's `do` lines never mention an ending). A synergy is only ever raised for a pair the conflict check already lists, so it adds no new noise pairs.
- R3. For `ending_rule`, the row carries an `offer`: the existing behaviour to edit (`target`), the field (`do`), the source layer, and the route to apply it. Code writes no wording. For `shared_moment` and `shared_tool`, the row carries the offer to link them (`--relates-to`) or to merge.
- R4. A synergy row is answered like any other: `--relates-to <id>` or `--unrelated <id>=<reason>`. It counts in `unanswered`. It never blocks recording.

**Offered edits**
- R5. `propose-behaviour --edit-of <id>` saves a proposed replacement of an existing programme-layer behaviour, with the same field flags. The existing behaviour stays unchanged and active.
- R6. `record-behaviour --from-proposal <id> --prompt <id>` on an edit proposal replaces the target behaviour in place, writes a history event `edited`, and needs Shawn's typed prompt naming the proposal id (the existing `require_named` rule).
- R7. For a behaviour that is not a programme-layer entry, the offer names the existing route instead of editing in place: shipped or personal file → `copy-default` then `settle-default-update --as merge`; stored personal or repo entry → record the new wording as a programme behaviour with `--conflicts-with <id>`. Shipped defaults are never edited in place.
- R8. The sweep reference tells the PM to show conflicts, synergies and offered edits in the one existing message, and to apply an edit only on Shawn's typed words.

**Unchanged**
- R9. The check never refuses to record. A protected escalation in a do line is still refused. Behaviours carry no authority.

### Key Decisions

- **Code picks candidates; the PM writes wording.** No model call in code. (Governs R1, R3.)
- **An offered edit is a proposal, applied on typed words.** (Governs R5, R6.)
- **One message.** Conflicts, synergies and offered edits go to Shawn together (PM call-out 2). (Governs R8.)

### Scope Boundaries

- Re-checking old behaviours when a Ruling, term or tool changes later is not in this plan.
- Open P3 issues #187 to #191 are not in this plan.
- In-place editing of stored personal and repo entries is not in this plan (R7 gives the route).
- Publishing is not in this plan.

### Deferred to Follow-Up Work

- In-place edit of stored personal and repo entries, once the use shows it is wanted.
- Synergy kinds based on paraphrase or meaning. Code cannot see them.

---

## Planning Contract

### Key Technical Decisions

1. **KTD1. Synergies classify pairs the conflict check already lists.** `check()` in `plugins/auto/lib/programme_behaviour_check.py` produces the reasoned rows. A new module reads those rows plus the two entries and adds `kind`. A pair the conflict check does not list gets no synergy. Rationale: the 190-pair measurement showed new pair rules re-create the one-shared-word noise; reusing the vetted gate keeps the listed set at 8 of 126 same-repo pairs. Governs R2.
2. **KTD2. `ending_rule` uses a closed word list, tested on both entries.** An entry "ends work" when its `stop` line, or a `do` line, has a word starting with stop, retire, close, end, reflect-and-stop, or "hand back". The offer goes to the other entry when it does not end work and its `when` words overlap the ending entry's `when` or instruction words by two or more (the same cross-field overlap `instruction_touches_situation` uses, either direction). Rationale: the real pair needs the cross-field overlap (`remit` and `session`), and the ending test keeps the kind to the case the handoff names. Governs R2, R3.
3. **KTD3. Offered edits reuse the proposal state.** `propose-behaviour --edit-of <id>` stores an entry with `state: proposed` and `edit_of: <id>`. `record-behaviour --from-proposal` already requires Shawn's typed words naming the id; for an edit proposal it then swaps the target's lines instead of adding a new behaviour. The target keeps its id, trigger and layer. Rationale: the handoff asks for this shape, and it keeps one approval rule. Governs R5, R6.
4. **KTD4. The check output gains keys; no existing key changes.** `synergies` joins `behaviours` and `contract` in `report()`. `unanswered` counts all three. Older callers that read only the old keys keep working. Governs R1, R4.
5. **KTD5. The layer decides the apply route.** The row's `offer.route` is `programme_edit`, `copy_default_then_settle`, or `record_with_conflicts_with`, chosen from the target entry: `from_file(entry)` (`programme_behaviours.py:286`, a `shipped` layer or `source: file`) gives `copy_default_then_settle`; layer `programme` gives `programme_edit`; any other stored `personal` or `repo` entry gives `record_with_conflicts_with`. Governs R3, R7.

### High-Level Technical Design

Directional only.

```
check-behaviour / record-behaviour
  peers = behaviour_check.check(entry, others)        # existing, gate
  contract = contract_check.check(entry, snapshot)    # existing
  synergies = synergy.classify(entry, others, peers) # new: only over rows in `peers`
      for row in peers:
          if row has same_trigger | shared_when : kind shared_moment, offer link
          if row has shared_tool                : kind shared_tool,   offer link
          if ends_work(a) xor ends_work(b) and cross-field overlap >= 2:
                                                  kind ending_rule, offer edit on the non-ending one
  report = {behaviours, contract, synergies, unanswered, checked}

edit offer applied:
  propose-behaviour --edit-of B ...   -> proposed entry E (edit_of: B)
  Shawn types a reply naming E
  record-behaviour --from-proposal E --prompt <id> -> B's lines replaced, history 'edited'
```

### Assumptions

- The live programme record's `b51850c` / `bc3f80d` pair keeps the shape quoted in the brief and in the 2026-11-02 plan. The fixture copies the shape, not private text beyond what the brief quotes.
- A programme-layer entry is the common target. Stored and file-layer targets get a route, not an in-place edit.

### Sequencing and parallelism

- U1 first (tests fail on the unmodified library).
- U2 and U3 touch different files and can run in parallel after U1.
- U4 follows U2 and U3. U5 is last.
- The work is small enough for one worker to do serially; fan-out saves little.

### Risks

- **Ending-word list matches too much.** "stop" appears in many do lines. Mitigation: the gate in KTD1 limits it to already-listed pairs, and U5 re-measures counts on the final rule.
- **An edit proposal that outlives its target.** The target may be retired or moved before Shawn answers. Mitigation: apply refuses with a plain error when the target is gone or no longer a programme-layer entry.
- **Round-2 review finds fix-induced gaps in the new sibling path.** `record-behaviour --from-proposal` now has two meanings. Mitigation: test both paths, and mutate the edit branch once to prove the test can fail.

---

## Implementation Units

### U1. Failing tests first

**Goal:** Pin the behaviour before building it.
**Requirements:** R1 to R9.
**Dependencies:** none.
**Files:** `plugins/auto/tests/unit/programme-behaviour-check.test.sh` (extend), `plugins/auto/tests/unit/programme-behaviours.test.sh` (edit-of cases).
**Approach:**
- Follow the helpers in the existing check test file (`run_py`, `setup`, `beh`, `prompt_for`).
- The first failing test is the `ending_rule` pair: record the `bc3f80d`-shaped behaviour against the `b51850c`-shaped one and expect a synergy row with an `offer` targeting `bc3f80d`.
**Test scenarios:**
- Record the `bc3f80d` shape against `b51850c`: `synergies` has one `ending_rule` row, `offer.target` is the non-ending behaviour, `offer.field` is `do`, and no wording is present.
- Two behaviours with the same explicit trigger: a `shared_moment` row with a link offer.
- Two behaviours naming the same tool: a `shared_tool` row.
- A pair the conflict check does not list gets no synergy (the one-shared-word case).
- An ending behaviour against one whose `do` already mentions stopping: no `ending_rule` row.
- Behaviours in different repos or with disjoint audiences: no synergy.
- `--relates-to` and `--unrelated` answer a synergy row and lower `unanswered`.
- Recording succeeds with unanswered synergies and writes no edit (R9).
- A do line naming a production deploy is still refused.
- `propose-behaviour --edit-of <id>` saves a proposed entry and leaves the target unchanged.
- `record-behaviour --from-proposal` on an edit proposal without a typed prompt naming it is refused; with it, the target's `do` lines are replaced and `history` gets an `edited` event.
- Edit of a target that was retired meanwhile is refused with a plain error.
- Target from a shipped file: the offer route is `copy_default_then_settle`, and `--edit-of` on it is refused.
**Verification:** The new cases fail on the unmodified library for the reasons above.

### U2. Synergy classification

**Goal:** Return `synergies` rows with offers.
**Requirements:** R1 to R4, KTD1, KTD2, KTD5.
**Dependencies:** U1.
**Files:** `plugins/auto/lib/programme_behaviour_synergy.py` (new), `plugins/auto/lib/programme_behaviour_report.py`, `plugins/auto/lib/programme_behaviour_check.py` (export the cross-field overlap helper).
**Approach:**
1. Classify over the rows `check()` already returned.
2. Add `ends_work(entry)` from the closed word list.
3. Build the offer with target, field, route (from where the entry was loaded) and no wording.
4. Add `synergies` to `report()` and count it in `unanswered`; add the kinds to the `checked` block.
**Patterns to follow:** pure functions returning plain dicts, as `programme_behaviour_check.py` does.
**Test scenarios:** Covered by U1.
**Verification:** U1's synergy cases pass; no import cycle.

### U3. Edit proposals

**Goal:** Save an offered edit and apply it on typed words.
**Requirements:** R5 to R7, KTD3, KTD5.
**Dependencies:** U1.
**Files:** `plugins/auto/lib/programme_behaviours.py`, `plugins/auto/lib/programme_fixes.py` (typed-prompt table, if the edit apply needs a new row).
**Approach:**
1. Add `--edit-of` to `propose-behaviour`; refuse a non-programme-layer or non-active target.
2. In `_from_proposal`, branch on `edit_of`: replace the target's lines through `put_programme_entry`, keep its id, trigger and layer, add an `edited` history event, mark the proposal applied.
3. Re-run the protected-escalation verdict on the replaced entry.
**Execution note:** Mutate the edit branch once (swap lines without the `require_named` call) and confirm a test fails.
**Test scenarios:** Covered by U1.
**Verification:** U1's edit cases pass; existing `--from-proposal` tests pass unchanged.

### U4. Documentation

**Goal:** Tell the PM what to show and how to apply.
**Requirements:** R8.
**Dependencies:** U2, U3.
**Files:** `plugins/auto/skills/programme-sweep/references/behaviours.md`, `plugins/auto/docs/contracts/programme-behaviours-format.md` (§10 plus a new row set for synergy kinds), `plugins/auto/docs/contracts/agent-tool-surface.md`, `plugins/auto/skills/programme-sweep/SKILL.md` (only if it names the check).
**Approach:**
- The reference says: in the one message, show synergies and offered edits; write the wording yourself from the row; save it with `propose-behaviour --edit-of`; apply only on Shawn's typed reply; for default behaviours copy first.
**Test expectation:** none -- documentation. Existing doc-lint tests must pass.
**Verification:** Doc-lint tests pass.

### U5. Re-measure and full run

**Goal:** Prove the final rules against the real stored set and the suites.
**Requirements:** all.
**Dependencies:** U2, U3, U4.
**Files:** none (a measurement note in the PR body).
**Approach:**
1. Re-run the read-only measurement (ids and counts only) on this machine's store; state per kind how many pairs fire. Ask the PM to run the same count on the Studio store or state it was not run.
2. If a kind fires on many pairs with no meaningful offer, drop it and say so in the PR body (PM call-out 1).
3. Run the unit and integration suites through `honest-run`, and `check-behaviour` once against the live programme.
**Verification:** Counts reported per kind; suites report a verdict line.

---

## Verification Contract

- U1's tests fail before U2 and U3 and pass after.
- The mutation of the edit-apply branch fails at least one test.
- `check-behaviour` run against the live programme returns `synergies` without error and writes nothing.
- Full unit and integration suites pass through `bash ~/.claude/tools/honest-run/run.sh` with a verdict line. shrimpshack has no CI, so the local run is the evidence.
- ce-code-review has no open P0 to P2; each P3 is logged as an issue in `shawnroos/shrimpshack`.

## Definition of Done

The PR is open with the head sha and test counts, the per-kind measurement is in the PR body, the `b51850c` / `bc3f80d` pair yields an offered edit in a test, no code path blocks recording, and nothing is published.

## Sources

- `docs/handoff.md` (brief, 2026-11-03) and the PM's scope confirmation, 2026-11-03.
- `plugins/auto/docs/plans/2026-11-02-001-feat-behaviour-check-plan.md` (the check this extends).
- `plugins/auto/lib/programme_behaviour_check.py`, `plugins/auto/lib/programme_behaviour_report.py`, `plugins/auto/lib/programme_behaviours.py` (`_h_check`, `_h_record`, `_h_propose`, `_from_proposal`).
- Memory `reference_behaviour_check_what_it_cannot_catch`.
- Local measurement on this machine's `behaviours.json`, 2026-11-03 (ids and counts only).
