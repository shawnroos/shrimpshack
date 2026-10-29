---
title: Programme Focus Budget - Plan
type: feat
date: 2026-10-28
topic: programme-focus-budget
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
deepened: 2026-10-28
---

# Programme Focus Budget - Plan

## Goal Capsule

- **Objective:** a programme does fewer things at once, so Shawn has to trade work off and each running task gets more of the team's effort ("more wood behind each arrow"). Work over the limit waits where Shawn can see it.
- **Means:** a `focus_budget` agreement term holding a point total for tasks and a count for agents (KTD1). The PM's `start-worker` gate enforces it for panes (KTD3). A pick-approved swap settles a full slate (KTD6).
- **Product authority:** Shawn. Settled this session through pickers on 2026-10-28.
- **Open blockers:** none.
- **Execution profile:** Standard, six units. U1 lands first. U2 follows. U3 needs U1 and U2. U4 and U5 run in parallel after U3. U6 lands last.
- **Finishes and ships:** one PR to `main`, squash-merged pinned to the reviewed head. The version bump is a separate `publish:` commit afterwards, per repo habit. Nothing is published to a registry from this plan.
- **Stop conditions:** stop and report if the same P0/P1 review finding recurs three rounds in a row, or if the unverified items under Outstanding Questions turn out to need a product choice.

---

## Product Contract

### Summary

A workspace's agreement gets a focus budget with two limits. Tasks are limited by a point total, using a point scale held in the agreement (for example small=1, medium=3, large=5). Agents (worker panes and subagents) are limited by a count. A programme has no limit until Shawn sets one.

When a task would take the points over the limit, it waits in an ordered queue that the status view shows. When a more urgent task arrives and the points are full, the PM asks Shawn to pick: swap a running task out, or queue the newcomer. Shawn sets and changes the limits in plain chat, like other agreement terms.

### Problem Frame

Programmes spread too thin. A single `/lfg` run on auto 0.16.3 fanned out about 25 subagents, and several tasks ran side by side with nothing forcing a choice about which mattered most. Rate-limit stalls were a symptom. The cause is that nothing makes Shawn decide what not to do now.

Nothing in the auto plugin limits work today. `start-worker` starts a worker for any open item. Items carry no size or order. The only "budget" is `cadence.eval_budget_usd_per_day`, which no code reads.

### Requirements

**The budget**
- R1. The agreement carries a focus budget with a task point limit and an agent count limit. Either may be unset, and unset means unlimited.
- R2. The agreement holds the point scale (size name to points). Items get a size from that scale.
- R3. Shawn sets, changes, or clears the limits and the scale in plain chat, through the same approval path as other agreement terms.
- R4. A new programme starts with no limit. Having no limit is a valid setup state, not an unfinished step.

**Enforcement**
- R5. The PM starts no worker if the item's points would take the points in play over the limit, unless Shawn overrides with `--despite`, which the journal records. The item is held, with the reason shown.
- R6. The PM starts no worker if the running worker count is at the agent limit. Held the same way.
- R7. An item with no size is held until it is sized, but only while a point limit is set.
- R8. Subagent fan-out inside one session is advised, not enforced. The sweep guidance tells the PM to keep it within the agent limit, and the status view shows the count the PM records.

**Queue and tradeoff**
- R9. Held items show in the status view in the order they were held, with the reason each is held.
- R10. When a new item would not fit and the slate is full, the PM asks Shawn to pick one of: swap a named running task out for the newcomer, or queue the newcomer. Nothing is swapped without the pick.
- R11. A swapped-out task is parked: its points free up, it joins the held queue, and its worker is told to stop at a safe point.

### Success Criteria

- With a point limit set, the points in play cannot pass the limit without an explicit swap pick or an explicit `--despite` override, which the journal records.
- The status view shows points in play against the limit, agents against the limit, and the held items in order.
- Saying "only 10 points at once" in chat changes the live limit without a file edit.
- The behaviour that tells the programme it is working: Shawn starts having to choose what to queue.

### Scope Boundaries

**Deferred to follow-up work**
- The stage-qualification ladder, which is a separate brainstorm and plan.
- Reordering the held queue by chat. Order is first held, first served.
- Reading task sizes from Linear estimates.
- A budget shared across programmes or the whole machine.
- A global default for plain sessions with no programme. That text lives in Shawn's own instructions file, not in this repo.

**Outside this plan**
- Hard enforcement of subagents inside a session. Skills outside this repo cannot be edited, and no hook can see subagent starts.

### Key Decisions

- **Focus over rate-limit safety.** The budget exists to force tradeoffs. Avoiding stalls is a side benefit. Governs R1, R5, R10. (session-settled: user-directed — chosen over a rate-limit guard: Shawn said the problem is "too much spread too thin" and the goal is "more wood behind each arrow".)
- **Wait in a queue.** Over-limit work waits instead of failing or running anyway. Governs R5, R6, R9. (session-settled: user-directed — chosen over refuse-and-tell and warn-but-proceed: nothing is dropped, and the wait is visible.)
- **The PM asks Shawn to pick at a full slate.** No automatic bumping. Governs R10. (session-settled: user-directed — chosen over automatic bump and silent priority queueing: the tradeoff must be Shawn's and visible.)
- **Tasks in points, agents by count.** Governs R1, R2. (session-settled: user-directed — chosen over a plain task count and over reading Linear estimates: Shawn wants a point scale the agreement owns.)
- **Programme first, plain sessions advised.** Governs R8. (session-settled: user-approved — chosen over programme-only and over one shared setting file: the PM can enforce what it starts, and a lone session can only follow a rule by choice.)
- **No default limit.** A programme is unlimited until set. Governs R4. (session-settled: user-approved — proposed with the tradeoff shown that a default number would be a guess; confirmed.)

### Outstanding Questions

**Deferred to implementation**
- Whether the view model needs a `VIEW_FORMAT` bump, and whether any golden file in `tests/unit/programme-view.test.sh` breaks on a new line.
- Where `lib/programme.py` merges each module's `build_verbs` output. The research read the load order only.
- Whether `commands/*.md` restate the term list.

---

## Planning Contract

### Key Technical Decisions

- KTD1. Add one fixed term `focus_budget`, not a project term. Project terms refuse the words "budget" and "limit" (`lib/programme_terms.py` `PROTECTED_STEMS`), so a fixed key is the only route. Its value is `unlimited` or `limited`, with extras `points` (integer or none), `agents` (integer or none) and `scale` (size name to points). Numeric values ride as extras because `_check_value` accepts only listed options, the same pattern `cadence` uses for `seconds`. Implements R1, R2, R3, R4.
- KTD2. "In play" has one definition: an item whose `effective_state` (`lib/programme_predicate.py`) is `open` or `waiting`, which is not held or parked, and whose `owner.pane` matches a live herdr pane with `role(...) == "worker"` (a live agent, the same test the agent count uses). A pane that has dropped to a shell does not count. No new item state is added. Nothing in the plugin ever clears `owner` when a worker ends or its pane dies, so a raw owner check would keep a dead worker's points forever. Reading the live worker makes the budget heal itself. Points in play are the sum of those items' sizes. Implements R5, R6.
- KTD3. The firm gate is one function in a new module `lib/programme_focus.py`, called from `_h_start_worker` right after `programme_context.unsafe_reason` and before `programme_recovery.admit`. `programme.py` is at 986 of 1000 lines (`tests/unit/size-budget.test.sh`), so the logic lives in the new module and `programme.py` only loads it. Implements R5, R6, R7.
- KTD4. `admit` reads herdr itself (`read_herdr()`, then `pane_views` and `role(...) == "worker"`, the same calls `check_target` makes), once per start. `_h_start_worker` has no sweep snapshot, and a stored one would be stale. The gate fails closed: if a limit is set and herdr cannot be read, the start is held with a named next step (retry once herdr answers, or use the existing `--despite`). A silent pass would let an unreadable count read as "under the limit". Implements R5, R6.
- KTD5. Held items carry `held` (a reason) and `held_at` fields set by the gate, and the view sorts on `held_at`. A refused verb discards its own writes (`programme_authority.write` commits only if the change does not raise), so the gate commits the hold in a separate write first and raises afterwards. Each refused start therefore adds one journal row. The existing `working_model.queue` holds PM actions, not items, so it is not reused. Implements R9.
- KTD6. The swap goes through a new verb `swap-item <out> <in>`, approved by an exact-label pick via `programme_approval.PICK_VERBS` and `approval-label`. `hand-item` and `answer-handed` are not used: their answers are only ship or decline. The decline option approves nothing, and the PM then queues the newcomer. The PM records the call with `log-decision --kind work_sequencing`. Implements R10, R11.
- KTD7. Subagents are advisory (R8). The PM's own subagents share the PM's session id and no start or stop hook exists, so no code can count them. The PM records the number it is running with `focus-note --agents N`, and the view shows that number. Implements R8.
- KTD9. Held items do not keep the PM awake. `programme_predicate._item_reasons` reports every open item as `open_item` and an ownerless one as `ownerless_item`, both actionable, so a held item would make the PM try to start it every sweep and look stuck. Held items get the same suppression `PAUSED_REASONS` gives paused items, so a programme with only held items may stop under the default stop rule ("nothing it can act on"). The predicate reads only the stored record and cannot see freed room, so a new verb `focus-recheck` does that job: the sweep runs it, it dry-runs the gate for each held item in `held_at` order, and it clears `held` on each item that now fits, subtracting the room that item takes before testing the next. A cleared item counts as actionable again. Implements R9.
- KTD10. An untouched `focus_budget` (value `unlimited`, `set_by` default) is left out of `agreement_lines` and `rule_texts` in `lib/programme_view.py`. `normalize_programme` adds the term to every programme, and `terms_digest` hashes all terms, so otherwise every pending accept pick would go stale. Already-accepted agreements store no digest and are unaffected. Implements R4.
- KTD8. `focus_budget` is excluded from the setup pending-steps logic. `_term_step` marks a term done only when `set_by` is outside `UNSET_BY`, so a never-set budget would block setup. It is optional by design (R4). Implements R4.

### Assumptions

- A parked item's worker keeps its pane. The PM prompts it to stop at a safe point with `prompt-item`, then the item leaves the points count at once. The alternative, closing the pane, loses the worker's context and is not chosen.
- First-held-first-served is acceptable ordering until reordering is built.

### High-Level Technical Design

*Directional guidance for review.*

```
start-worker <item>
  └─ programme_focus.admit(programme, item)      # reads herdr itself (KTD4)
        limit unset (both)           → admit
        herdr unreadable (any limit) → hold("count unavailable: retry or --despite")
        point limit set:
           item unsized              → hold("unsized: size-item <item> <size>")
           in_play + points > limit  → hold("over points: N of M in play")
        agent limit set:
           workers >= limit          → hold("agents at limit: N of M")
        else                         → admit
  hold  → item.held = reason, item.held_at = now (first hold only), refuse start
  admit → clear held, continue to launch_worker
```

```
newcomer arrives, slate full
  PM sweep ──► AskUserQuestion: [ "Approve swap-item <out> <in>" , "Queue <in>" ]
        pick = swap label ─► swap-item: out parked (held, points freed), worker told to stop
                              then start-worker <in> passes the gate
        pick = queue      ─► newcomer stays held; nothing changes
```

---

## Implementation Units

### U1. The `focus_budget` term

- **Goal:** the agreement carries, validates, stores, shows and amends the budget.
- **Requirements:** R1, R2, R3, R4
- **Dependencies:** none
- **Files:**
  - `plugins/auto/lib/programme_home.py` (modify): `default_terms`, `TERM_GUIDE`
  - `plugins/auto/lib/programme_focus.py` (create): extras parsing and validation shared by amend, propose, pick and view
  - `plugins/auto/lib/programme.py` (modify, minimal): `_check_value`, `_set_term` extras
  - `plugins/auto/lib/programme_proposals.py` (modify): `_proposal`, `settle_amend` extras
  - `plugins/auto/lib/programme_view.py` (modify): `_term_text`
  - `plugins/auto/lib/programme_view_work.py` (modify): `_value_text`
  - `plugins/auto/lib/programme_view_setup.py` (modify): `_term_step`
  - `plugins/auto/lib/programme_setup.py` (modify): `take-recommendations` loop, `pick-term` extras
  - `plugins/auto/lib/programme_import.py` (read): confirm import and carry-over need no change
  - `plugins/auto/tests/unit/programme-terms.test.sh` (modify)
  - `plugins/auto/tests/unit/programme-setup.test.sh` (modify)
- **Approach:**
  1. Add `focus_budget` to `default_terms` with value `unlimited`, `points` none, `agents` none, and `scale` of small=1, medium=3, large=5 (KTD1).
  2. Add its `TERM_GUIDE` entry. Choose the editor from the existing set (`interval` or `choice`), with `binding` "code".
  3. Extend `_check_value`, `_set_term`, `_proposal` and `settle_amend` to carry `--points`, `--agents` and `--scale` the way they carry `--seconds`. Keep every added function under the 120-line limit; put the extras handling in `programme_focus.py`, since `programme.py` sits at 986 of 1000 lines.
  4. Print the three extras in `_term_text` and `_value_text`, and skip an untouched `focus_budget` in `agreement_lines` and `rule_texts` (KTD10).
  5. Make `_term_step` treat `focus_budget` as optional (KTD8).
  6. Keep `take-recommendations` from stamping it: skip it in the loop in `lib/programme_setup.py`. Let `pick-term` accept `--points`, `--agents` and `--scale`, since it parses only `--seconds` and `--until` today.
- **Patterns to follow:** `cadence` and its `seconds` extra; the `sources` to `tools_of_record` migration shim in `normalize_programme`.
- **Test scenarios:**
  - Happy path: `amend-term focus_budget limited --points 10 --agents 3 --prompt <pick>` stores the values and `status --terms` shows `points 10`.
  - Happy path: an old programme record read with `normalize_programme` gains `focus_budget` as `unlimited`.
  - Edge: `--points 0` and a negative value are refused with a message naming the allowed range.
  - Edge: clearing sets value `unlimited` and keeps the scale.
  - Error: `amend-term focus_budget 10` (a bare number) is refused as "fits no option" with the usable form named.
  - Error: a scale entry with a non-integer value is refused.
  - Integration: a fresh programme completes setup with `focus_budget` never touched. Covers R4.
  - Integration: the accept-terms digest of a programme that never sets the term is identical before and after this change (KTD10). Setting the term changes it.
  - Integration: `take-recommendations` leaves `focus_budget` at `unlimited` with `set_by` default.
  - Integration: an already-accepted agreement still reads as accepted after the term back-fills.
- **Verification:** the term round-trips through amend, status, the contract view and setup with no new pending step.

### U2. Item size

- **Goal:** items carry a size from the agreement's scale, and `size-item` sets it.
- **Requirements:** R2, R7
- **Dependencies:** U1
- **Files:**
  - `plugins/auto/lib/programme_home.py` (modify): `ITEM_FIELDS`, `normalize_item`
  - `plugins/auto/lib/programme_record.py` (modify, minimal): `add-item --size`
  - `plugins/auto/lib/programme_focus.py` (modify): `size-item` verb, `points_of(item, scale)`
  - `plugins/auto/tests/unit/programme-items.test.sh` (modify)
  - `plugins/auto/tests/unit/programme-focus.test.sh` (create)
- **Approach:**
  1. Add an optional `size` field (a scale name) set with `setdefault`, so older records read cleanly.
  2. `add-item --size <name>` and `size-item <item> <name>` both validate the name against the current scale.
  3. `points_of` resolves a size to points; an unknown name (scale later edited) counts as unsized, not zero.
  4. `programme_record.py` is at 971 lines, so keep its edit to the flag and delegate to `programme_focus.py`.
- **Patterns to follow:** `_h_add_item` flags; `build_verbs(host)` and `_SPECS` in `lib/programme_terms.py`.
- **Test scenarios:**
  - Happy path: `add-item ... --size medium` stores `medium`; `points_of` returns 3.
  - Happy path: `size-item` changes an item's size and records history.
  - Edge: a size renamed out of the scale makes the item unsized and not zero-point.
  - Error: `size-item` with a name outside the scale is refused and lists the valid names.
  - Edge: an item from an old record has no `size` and reads as unsized.
- **Verification:** items round-trip with and without a size; `status` shows the size.

### U3. The gate in `start-worker`

- **Goal:** `start-worker` holds an item that would break a limit and records why.
- **Requirements:** R5, R6, R7
- **Dependencies:** U1, U2
- **Files:**
  - `plugins/auto/lib/programme_focus.py` (modify): `admit`, `in_play`, `hold`, `focus-recheck` verb
  - `plugins/auto/lib/programme_sources.py` (modify, minimal): call `admit` in `_h_start_worker`
  - `plugins/auto/lib/programme_predicate.py` (modify): suppress held items from the actionable reasons (KTD9)
  - `plugins/auto/tests/unit/programme-focus.test.sh` (modify)
  - `plugins/auto/tests/unit/programme-sources.test.sh` (modify)
  - `plugins/auto/tests/integration/programme-dispatch-recovery.test.sh` (modify)
- **Approach:**
  1. Implement `in_play` per KTD2 and `admit` per the High-Level Technical Design.
  2. Call `admit` in `_h_start_worker` after `unsafe_reason` and before `programme_recovery.admit`, so a held start leaves no launch attempt in the journal.
  3. On a hold, commit `held` and `held_at` (first hold only) in a separate write, then raise the refusal with the reason and the next step (KTD5). On admit, clear both.
  4. Honour the existing `--despite` as the override, and journal that it was used.
  5. Workers Shawn starts by hand never pass this gate. Count them in the worker total from the herdr read so they use up the agent limit even though they cannot be blocked.
  6. Suppress held items in `_item_reasons` the way `PAUSED_REASONS` suppresses paused ones (KTD9).
  7. Add `focus-recheck`: for each held item in `held_at` order, dry-run `admit` and clear `held` when it fits (KTD9). It writes nothing else.
- **Execution note:** write the failing gate tests first and mutate each branch of `admit` to prove every test can fail.
- **Patterns to follow:** `unsafe_reason` in `lib/programme_context.py` as a sibling check.
- **Test scenarios:**
  - Happy path: no limits set, `start-worker` behaves exactly as before.
  - Happy path: 10-point limit, 7 in play, a 3-point item starts.
  - Edge: 10-point limit, 7 in play, a 5-point item is held with `over points: 7 of 10 in play`; no journal launch entry exists.
  - Edge: a 3-point item at exactly 10 of 10 starts; at 11 it is held.
  - Edge: an item that finishes frees its points, and the next start passes.
  - Edge: an unsized item is held only while a point limit is set; with no point limit it starts.
  - Error: agent limit 3 with 3 workers in the snapshot holds the start.
  - Error: any limit set, including a points-only limit, and herdr unreachable holds the start and names the retry step (KTD4).
  - Error: `--despite` starts a held item and the journal records the override.
  - Integration: a held item shows `held` after a failed start and has it cleared after a later successful start.
  - Integration: a hand-started worker pane in the snapshot reduces the room for the next start.
  - Edge: an item whose worker pane has died (owner set, pane absent from herdr) does not count toward points in play.
  - Edge: an item whose pane still exists but holds a shell with no agent does not count either.
  - Edge: an item whose evidence reads done while its stored state is still open does not count.
  - Integration: with only held items left, the PM's `may_stop` is true under the default stop rule; with one startable item it stays false.
  - Integration: a refused start leaves `held` set after the verb raises (the separate write committed).
  - Integration: a running item finishes while a held item remains; before `focus-recheck` the held item is suppressed, and after it the item is actionable and `may_stop` is false.
  - Integration: with two held items and room for only one, `focus-recheck` clears the earlier `held_at` item and leaves the later one held.
- **Verification:** with a point limit set, no sequence of `start-worker` calls reaches more points in play than the limit without `--despite`.

### U4. Visible queue and usage

- **Goal:** the status view shows points and agents against the limits and the held items in order.
- **Requirements:** R8, R9
- **Dependencies:** U3
- **Files:**
  - `plugins/auto/lib/programme_view.py` (modify, minimal): `build`, `rows`, `_item_lines`
  - `plugins/auto/lib/programme_view_work.py` (modify): work entry marks
  - `plugins/auto/lib/programme_focus.py` (modify): `usage(programme, snapshot)`, `focus-note --agents N`
  - `plugins/auto/tests/unit/programme-view.test.sh` (modify)
  - `plugins/auto/tests/unit/programme-view-mod.test.sh` (modify)
- **Approach:**
  1. Add a "Focus" row under "Queue" showing `points 7 of 10`, `agents 2 of 3` and the PM-recorded subagent number, or `no limit` per unset limit.
  2. Add a "Waiting for a slot" list of held items sorted by `held_at`, each with size and reason.
  3. `focus-note --agents N` records the PM's own subagent count for the view (KTD7).
  4. `programme_view.py` is at 813 lines. Build the new rows in `programme_focus.py` and call them from `rows`.
  5. Check whether `VIEW_FORMAT` needs a bump and whether golden files break (Open Questions).
- **Patterns to follow:** the existing "Queue" row in `rows(model, work)`.
- **Test scenarios:**
  - Happy path: limits set, usage line shows the right numbers.
  - Happy path: three held items appear in `held_at` order with reasons.
  - Edge: no limits set shows `no limit` and no "Waiting for a slot" list.
  - Edge: herdr down shows the agent count as unavailable, not zero.
  - Edge: an item with `held` and `held_at` written onto it in the test fixture appears in the held list and not in points in play. The end-to-end swap case is tested in U5.
- **Verification:** the status text and the `--json` view both carry the usage and the ordered held list.

### U5. Swap pick

- **Goal:** at a full slate the PM asks, and a swap pick parks one task and admits the newcomer.
- **Requirements:** R10, R11
- **Dependencies:** U3
- **Files:**
  - `plugins/auto/lib/programme_focus.py` (modify): `swap-item` verb
  - `plugins/auto/lib/programme_approval.py` (modify): `PICK_VERBS`
  - `plugins/auto/lib/programme_fixes.py` (modify): `FIXES`
  - `plugins/auto/lib/programme_decisions.py` (read only): `work_sequencing` kind already exists
  - `plugins/auto/tests/unit/programme-focus.test.sh` (modify)
  - `plugins/auto/tests/unit/programme-approval.test.sh` (modify)
- **Approach:**
  1. `swap-item <out> <in>` runs only when a pick names it. It marks `<out>` parked (held, `held_at` set, points freed) and stages the prompt that tells its worker to stop at a safe point (Assumptions).
  2. Add the verb to `PICK_VERBS` so `approval-label` can print its exact label (default-deny otherwise).
  3. A decline or any answer that is not the exact label approves nothing, and the newcomer stays held.
  4. After `swap-item`, the PM starts `<in>` through the normal gate, so the swap cannot over-fill.
  5. A parked item resumes through `start-worker` and the normal gate. `swap-item` records the parked item's old pane, and the gate refuses a resume while that pane still holds a live worker, naming the step: wait for the worker to stop, or close the pane. A second worker is never started beside the old one.
  6. The swap must pass the gate itself: if parking `<out>` does not free enough points for `<in>`, `swap-item` refuses and says how many points are still missing.
- **Patterns to follow:** `programme_approval.label` and the approve-by-pick flow from `docs/plans/2026-10-26-1700-feat-approve-by-pick-plan.md`.
- **Test scenarios:**
  - Covers R10. Happy path: an exact-label pick runs `swap-item`; `<out>` is parked, `<in>` starts.
  - Covers R10. Edge: a typed "yes swap them" approves nothing.
  - Error: swapping a 1-point item for a 5-point item with 2 free points is refused and names the missing points.
  - Error: swapping an item that is not in play is refused.
  - Edge: the decline option leaves both items unchanged and `<in>` held.
  - Integration: the swap is recorded as a `work_sequencing` decision with both item ids.
  - Integration: park, then free room, then resume. While the old pane still holds a live worker the resume is refused with the named step. After the pane is gone the resume starts exactly one worker for the item.
- **Verification:** no path parks or starts an item without a pick whose answer equals the printed label.

### U6. Sweep guidance, docs and vocabulary

- **Goal:** the PM knows to gate, ask and note; the docs and vocabulary name the new parts.
- **Requirements:** R3, R8, R10
- **Dependencies:** U1, U2, U3, U4, U5
- **Files:**
  - `plugins/auto/skills/programme-sweep/SKILL.md` (modify): step 11, step 14
  - `plugins/auto/skills/programme-sweep/references/sequencing.md` (modify)
  - `plugins/auto/docs/contracts/agent-tool-surface.md` (modify): new verbs
  - `plugins/auto/docs/contracts/run-record-schema.md` (modify): term extras and item fields
  - `plugins/auto/CONCEPTS.md` (modify): focus budget row, agreement row
  - `plugins/auto/README.md` (modify, one line)
  - `plugins/auto/tests/unit/vocabulary-audit.test.sh`, `doc-fence-agent-tool-surface.test.sh`, `doc-fence-run-record-schema.test.sh`, `programme-sweep-skill.test.sh` (run, modify only if they need new rows)
- **Approach:**
  1. At the top of step 11, add: check `status` usage before starting a worker; on a held start, do not retry blindly: ask the swap pick when a newcomer outranks running work, otherwise leave it queued.
  2. In step 11, tell the PM to run `focus-recheck` first each sweep, so freed room is seen before it decides what to start.
  3. In step 14, tell the PM to run `focus-note --agents N` with the subagent count it is using, and to keep fan-out within the agent limit (R8).
  4. Document every new verb in `agent-tool-surface.md` (the doc-fence tests derive from the verb list).
  5. Add `focus budget` to `CONCEPTS.md` in the table's three-column shape, and update the agreement row that lists "budget".
  6. Keep the phrases `programme-sweep-skill.test.sh` greps for ("## When to speak", "P ask-shown <item> --fingerprint <fp>").
- **Test scenarios:**
  - Test expectation: the doc-fence, vocabulary and skill-shape tests pass with the new verbs and terms present, and fail if a new verb is left undocumented (mutate once to prove it).
- **Verification:** all `tests/unit` pass; `CONCEPTS.md` names the term once and the audit finds no stray synonym.

---

## Verification Contract

- Run the unit and integration suites through the honest runner so a killed run does not read as a pass: `bash ~/.claude/tools/honest-run/run.sh --expect "TOTAL: [0-9]+ passed, 0 failed" -- bash plugins/auto/tests/run.sh all`. The `TOTAL:` line prints on failures too, so the `0 failed` part of the pattern is what makes it a pass check.
- Run `bash plugins/auto/tests/unit/size-budget.test.sh` after every unit: `programme.py` (986), `programme_record.py` (971), `programme_sources.py` (922) and `programme_view.py` (813) are at or near the 1000-line limit.
- Mutation check on the gate: break each branch of `admit` in turn and confirm a test fails. A green gate test is not evidence the gate works.
- Manual check: arm a test programme with `--points 5`, add one 3-point and one 5-point item, start the first, confirm the second is held and appears in `status`, then run the swap pick end to end.
- Personal lint: run the `lint-router` skill on changed files before committing.

## Definition of Done

- Every requirement R1 to R11 is covered by a unit and a test that fails when the behaviour is removed.
- The manual check above ran against a real test programme, and the held item showed in `status`.
- `tests/run.sh all` and the size budget pass with the honest runner reporting a verdict line.
- Code review has no open P0, P1 or P2 finding.
- No dead or abandoned-attempt code remains in the diff.
- The feature commit follows `feat(auto): <plain sentence> (#NNN)`. The `publish:` commit is separate and not part of this plan.

## Operational Notes

- Nothing is published to the package registry from this plan. Per the standing rule, a publish needs an eval run behind it, and this plan adds no eval.
- To enable the budget for a plain session with no programme, Shawn adds a line to his own instructions file. This repo does not edit it.

## Sources

- `plugins/auto/lib/programme_home.py` (`default_terms`, `TERM_GUIDE`, `normalize_programme`, `ITEM_FIELDS`)
- `plugins/auto/lib/programme.py` (`_h_amend_term`, `_check_value`, `_set_term`)
- `plugins/auto/lib/programme_sources.py` (`_h_start_worker`, `sweep()`)
- `plugins/auto/lib/programme_terms.py` (`PROTECTED_STEMS`, `build_verbs`)
- `plugins/auto/lib/programme_approval.py` (`PICK_VERBS`, `label`)
- `plugins/auto/skills/programme-sweep/SKILL.md` (steps 11, 14) and `references/sequencing.md`
- `docs/plans/2026-10-26-1700-feat-approve-by-pick-plan.md`
