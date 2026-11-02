---
title: "feat: Programme rituals (calendar and programme-event workflows run by the PM)"
type: feat
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-brainstorm
execution: code
date: 2026-11-02
---

## Goal Capsule

**Objective:** Shawn can describe a recurring or moment-driven routine in plain words ("every Monday, report what drifted"; "at handover, brief the next PM"), and the programme's PM runs it at the right time, or, if the PM could not, offers it at the next opportunity instead of losing it.

**Means:** A new stored object, the ritual, beside Behaviours in `plugins/auto`, plus a skill that authors rituals.

**Product authority:** Shawn. Technical choices inside this scope are the worker's.

**Open blockers:** None. Real-journal measurement of PM downtime was not possible (the local programmes folder is empty). The resume-after-gap threshold ships as a named constant derived from the lease rule and is revisited once a journal is measured.

## Product Contract

### Summary

A ritual is a named workflow the PM runs when a trigger fires: a calendar rule or a programme moment. It is stored in the same three layers as Behaviours. A ritual the PM could not run is offered, once per sweep, in a single picker. An authoring skill turns Shawn's plain description into a ritual, so the framework ships without a fixed catalog.

### Problem Frame

Behaviours fire on an item change (claim, merge, block, start). Nothing fires on the calendar or on a whole-programme moment such as start, end, handover or takeover. Those moments are where work is lost: a handover drops context, a takeover starts blind, a quiet week hides drift. The PM is a Claude session that can hit a usage limit, compact, lose its login or be closed, so a ritual that runs only if the PM is alive at the right minute will be missed.

### Key Decisions

- **The framework and authoring skill ship; no fixed ritual catalog.** Shawn asked for scaffolding and a skill "for creating all the above and more we might not have conceived." (session-settled: user-directed — chosen over designing one concrete Monday and one concrete handover ritual first: Shawn wants any ritual authorable.) Governs R1, R12.
- **One picker per sweep for missed rituals.** (session-settled: user-approved — chosen over folding into the status report or offering one at a time: several missed rituals must not become several prompts.) Governs R8, R9.
- **Same three layers as Behaviours** (programme, repo, personal). (session-settled: user-approved — chosen over programme-plus-personal and programme-only.) Governs R3.
- **The clock is a stored due time, not the session cron.** (session-settled: user-approved — chosen over cron-only and stored-plus-cron wake: the cron dies with the session, so a stored time is the only clock that survives a dead PM.) Governs R5, R6.
- **First-version triggers:** calendar rules, programme start/end/handover/takeover, resume after a gap, going quiet. (session-settled: user-directed.) Governs R4.

### Actors

- **Shawn:** authors, retires and answers the missed-ritual picker.
- **PM:** runs rituals during its sweep; offers missed ones.
- **Takeover PM:** inherits rituals and the record of any ritual in flight.
- **Worker:** not a driver. A ritual may send a worker a message, as the PM does today.

### Requirements

**Ritual object**
- R1. A ritual is a stored object with a plain-words description of what it does, a trigger, and a state of active, proposed or retired.
- R2. A ritual's steps are written in Shawn's words and may include PM actions, a message to a worker, and a report to Shawn; the framework does not fix a step vocabulary.
- R3. Rituals live in the programme, repo and personal layers, with the same narrower-wins resolution, move and keep rules as Behaviours (`plugins/auto/docs/contracts/programme-behaviours-format.md`).
- R4. Triggers are: a calendar rule (a recurring schedule such as every Monday), programme start, programme end, PM handover, PM takeover, resume after a gap (PM restart, compaction, login reset or usage-limit reset), and going quiet (the stop rule fires before the programme idles).
- R5. Each calendar ritual has a stored next-due time in the programme store; any sweep that finds a past-due time treats the ritual as due.
- R6. The PM's session cron may wake the PM earlier, but no ritual depends on it to be remembered.

**Running and recording**
- R7. When a trigger fires and the PM is able, the PM runs the ritual and records the run (ritual, trigger, time, outcome) in the programme journal.
- R8. When the PM could not run a due ritual, the ritual is recorded as missed, never dropped and never run silently late.
- R9. At the next sweep the PM offers all missed rituals in one picker, per ritual: run now, skip this time, or retire. It does not prompt twice for the same miss.
- R10. A takeover PM can see a ritual that was in flight and either finish it or offer it.
- R11. The Programme view shows missed rituals even when no PM is alive.

**Authoring and safety**
- R12. A skill turns Shawn's plain description into a ritual (trigger, steps, layer) and records it with a typed confirmation, as Behaviours do.
- R13. A ritual whose steps would touch a protected escalation (production deploy, release, spend over cap, merge around the gate, refused permissions) is rejected on record and refused at run time.
- R14. Rituals carry no authority: they cannot widen what the PM or a worker may decide.

### Key Flows

- F1. **Monday, PM alive.** Sweep finds the Monday ritual past its due time → PM runs it → records the run → sets the next due time. Covers R5, R7.
- F2. **Monday, PM down.** The due time passes with no PM → on the next sweep the PM records the ritual as missed → includes it in the one picker with any others → Shawn picks run now, skip or retire. Covers R5, R8, R9.
- F3. **Handover.** The outgoing PM runs the handover ritual before leaving; if it cannot, the incoming PM sees the missed ritual and offers it. Covers R4, R8, R10.
- F4. **Author a ritual.** Shawn describes a routine → the skill proposes trigger, steps and layer → Shawn confirms → the ritual is stored. Covers R1, R12.

### Acceptance Examples

- AE1. **Covers R8, R9.** Given three rituals missed during a usage-limit outage, when the PM next sweeps, then it shows one picker listing all three, and no ritual runs before Shawn answers.
- AE2. **Covers R9.** Given Shawn chose "skip this time" for a missed Monday, when the next sweep runs, then the PM does not offer that miss again, and next Monday's occurrence is due on schedule.
- AE3. **Covers R13.** Given a ritual step "deploy to production", when Shawn tries to record it, then it is rejected with the escalation kind named.
- AE4. **Covers R10.** Given a PM that began a handover ritual and died, when a takeover PM starts, then it sees the ritual as in flight and offers to finish it.

### Scope Boundaries

**Deferred for later**
- Triggers beyond the list in R4: plugin update installed, remit or agreement change.

**Outside this work**
- Rituals triggered by item changes (these stay Behaviours; a worker retiring is already a Behaviour trigger).
- Editing the `default-behaviours` or `pm-drives-auto-core` branches. Coordinate through the PM.
- Any ritual that runs without a PM sweep or acts on its own authority.

### Dependencies / Assumptions

- Assumes the sweep (`plugins/auto/skills/programme-sweep/SKILL.md`) is the single place the PM checks what is due, as it does for Behaviours (`plugins/auto/lib/programme_behaviours_due.py`).
- Assumes the programme store can hold a next-due time per ritual (`plugins/auto/docs/contracts/run-record-schema.md`).

### Outstanding Questions

**Resolve Before Planning**
- None.

**Deferred to Planning**
- Real downtime measurement: the local `~/.claude/plugins/data/auto-shrimpshack/programmes/` folder is empty and the Studio machine's journal was not read. Measure it after U4 ships and tune the gap constant (U4).

### Sources / Research

- Handoff brief: `docs/handoff.md`. Its path `docs/contracts/programme-behaviours-format.md` is wrong; the contract is at `plugins/auto/docs/contracts/programme-behaviours-format.md`.
- Behaviour concept page: `plugins/auto/docs/concepts/programme/behaviour.md`.
- Lifecycle verbs: `plugins/auto/lib/programme_lifecycle.py`. Sweep cron fallback: `plugins/auto/skills/programme-sweep/SKILL.md`.

**Product Contract preservation:** unchanged by planning (open questions answered in KTD1, KTD9 and U4). In the planning sections below, every path is relative to `plugins/auto/`; `../../` reaches the repo root.

---

## Planning Contract

### Key Technical Decisions

- **KTD1. Mirror Behaviours, as a sibling module.** A new `lib/programme_rituals.py` copies the shape of `lib/programme_behaviours.py`: validate, store, resolve, `build_verbs(host)`. Rituals get their own store file `rituals.json` beside `behaviours.json`, with the same lock, atomic write and adoption rows. Rationale: reuses proven locking and approval code without widening Behaviours' strict key check. Resolves the "same store file or sibling" question. Governs R1, R3, R12.
- **KTD2. Due-ness is computed, never remembered.** A pure function (`lib/programme_rituals_due.py`, like `programme_behaviours_due.py`) takes the record, the clock and the journal and returns rows: `due`, `missed`, `in_flight`. The sweep inputs call it. Nothing in the session holds ritual state. Governs R5, R6, R8, R11.
- **KTD3. Due versus missed uses a grace window.** A ritual is *due* until `next_due_at` plus two cadence periods has passed, the same threshold the lease uses to call a PM orphaned (`programme_home.lease_state`). After that it is *missed* and can only be offered, never run silently. Rationale: honours "not run silently late" without turning a one-sweep delay into a prompt. Governs R8, R9.
- **KTD4. Calendar rules are a small closed grammar, and the clock is per programme.** Version one accepts: daily at a time, weekly on a weekday at a time, monthly on a day at a time, in the machine's local time. The entry holds only the rule. Each programme keeps its own `ritual_clock[<ritual id>].next_due_at` in its record, set from the rule at first sight and written in the same programme write that journals a run, skip or retire. Rationale: personal and repo entries are shared by every programme on the machine, so a shared due time would let one programme's Monday hide it from the others. After any answer, `next_due_at` becomes the first scheduled time after the answer time, so an old miss is never re-offered. A richer grammar is deferred. Governs R4, R5, R9.
- **KTD5. Event triggers come from rows that already exist, plus two new ones.** Start, takeover, handover, end and going-quiet are read from the journal kinds `programme_started`, `taken_over`, `handed_over`, `programme_ended` and `stop_quiet`, keyed by row time. A trigger is due when its row has no later `ritual_ran`, `ritual_skipped` or `ritual_failed` answer for that ritual, then missed after the grace window. Only resume-after-gap needs a new `ritual_event` row, written inside the `beat` verb (`_h_beat` in `lib/programme_lifecycle.py`) by comparing the stored `loop.last_beat_at` with now before overwriting it. Rationale: `programme_authority.write` commits one journal row per write, so a second atomic row is not possible. Going quiet fires once per active-to-quiet transition: the due function ignores a `stop_quiet` row that follows no activity since the previous one. Governs R4, R7, R10.
- **KTD5b. Handover and end are gated before the verb.** The outgoing PM still holds authority only until those verbs run, so `handover` and `end` refuse once when an active ritual with that trigger has no answer, with a `fix:` line naming the ritual. The PM runs it (or Shawn skips it) and retries. `--without-rituals` proceeds and leaves the rituals unanswered; the incoming PM then sees them missed (handover) or `P status` shows them missed (end). Rationale: the session-fragility rule means a PM that cannot run the ritual must still be able to hand over. Governs R4, R8, R10.
- **KTD6. Missed rituals are offered through one bundled picker, with answers recorded per ritual and the offer itself recorded once.** Modelled on `programme_carryover.offer`. Each answer (`run now`, `skip this time`, `retire`) is a verb call that writes a journal row, which removes that miss. An `offer-rituals` verb writes `ritual_offered` (ritual ids and the due times offered) when the PM posts the picker; the due function marks such a miss `offered`, and step 5c posts again only when an unoffered miss appears or the set changes. Rationale: without this an unanswered picker reposts every sweep. Governs R9.
- **KTD7. Verbs: `record-ritual`, `propose-ritual`, `retire-ritual`, `move-ritual`, `keep-rituals`, `start-ritual`, `run-ritual`, `fail-ritual`, `skip-ritual`, `offer-rituals`.** Authoring verbs need a typed human prompt that names the ritual id and layer (the existing `require_named` and `_typed_prompt`). A picker answer is recorded per ritual: the PM issues one `run-ritual`, `skip-ritual` or `retire-ritual` per ritual, each citing the same typed answer and naming that ritual's id; U2 settles the naming convention for a multi-id answer. Governs R9, R12.
- **KTD8. Protected-escalation scan reuses `PROTECTED_STEMS` and `PROTECTED_WORDS` from `lib/programme_terms.py` on the step lines.** It runs at record time and again on every load: resolution re-validates each entry, so a ritual stored before a protected word was added is rejected and never in force, and `start-ritual` refuses it as "not in force". Governs R13, R14.
- **KTD9. The Programme view needs no PM.** `P status --json` builds missed rituals from KTD2 on read, so a programme with no live PM still shows them. Governs R11.

### High-Level Technical Design

*Directional; the prose in the units is authoritative.*

```text
trigger source                          what is read                         who reads it
-------------------------------------   ----------------------------------   ----------------------------
calendar rule                           programme.ritual_clock[id]           sweep-inputs -> rituals_due()
start/takeover/handover/end/quiet       existing journal kinds (KTD5)        sweep-inputs -> rituals_due()
resume after a gap                      journal row ritual_event (in beat)   sweep-inputs -> rituals_due()

rituals_due(record, now):
  for each ritual in force:
    if calendar and now >= next_due_at:        row = pending(next_due_at)
    if trigger row with no later answer:       row = pending(trigger time)
    row.state = "due"     if now <= row.at + 2*cadence
              = "missed"  otherwise            (+ "offered" if ritual_offered covers it)
    "in_flight" if ritual_started has no later ran / failed / skipped
  return {due, missed, in_flight}

sweep step 5c:
  due        -> start-ritual (scans steps, writes ritual_started), PM performs steps,
                then run-ritual (or fail-ritual)
  missed +   -> offer-rituals, then ONE picker listing every unoffered miss:
  in_flight     run now / skip this time / retire  (in-flight: finish)

handover / end verbs: refuse once if a ritual for that trigger is unanswered (KTD5b)
```

### Assumptions

- The sweep digest (`lib/programme_sweep_inputs.py`) is the one place the PM learns what is due, so a rituals reason added there reaches both the cron wake and the quiet-sweep rule.
- "Cadence period" is the programme's existing cadence term; no new clock is introduced.
- Local time is acceptable for calendar rules because the programme and PM run on one machine at a time.

---

## Implementation Units

### U1. Ritual entry format, validation and store

**Goal:** A ritual can be validated, stored in three layers and resolved, mirroring Behaviours.
**Requirements:** R1, R2, R3, R13, R14
**Dependencies:** none
**Files:** create `lib/programme_rituals.py`, `docs/contracts/programme-rituals-format.md`, `tests/unit/programme-rituals.test.sh`; modify `lib/programme_home.py` (`PROGRAMME_FIELDS` and `new_programme_block` gain `rituals` and `ritual_clock`), `docs/contracts/run-record-schema.md` (section 10.5), `tests/unit/doc-fence-run-record-schema.test.sh`
**Approach:**
- Entry fields: `id`, `layer`, `when` (`text` plus one `trigger`), `steps` (plain-words lines), `applies_to` (PM only in v1), `state`, `why`, `source`, `history`, `adoption`, `schedule` (calendar rule only; the due time lives in the programme's `ritual_clock`, KTD4).
- Store `rituals.json` next to `behaviours.json` with its own env override and lock, copying `_read`, `write_store` and `load_store` semantics (refuse unreadable or newer-format files).
- Resolve narrower-wins as in Behaviours; `normalize_programme` reads a missing `rituals` as `[]`.
- Scan step lines with the protected-escalation words (KTD8).
**Patterns to follow:** `lib/programme_behaviours.py` (`_validate`, `store_path`, `write_store`, `resolve`), `docs/contracts/programme-behaviours-format.md`.
**Test scenarios:**
- Happy path: a valid weekly ritual validates and round-trips through the programme list and the personal layer.
- Error: a step "deploy to production" is rejected with `protected_escalation`. Covers AE3.
- Error: unknown key, missing `when.trigger`, `repo_key` on a non-repo layer each give the named rejection reason.
- Edge: an old programme record without `rituals` normalizes to an empty list.
- Edge: an unreadable or newer-format `rituals.json` refuses writes and loads nothing.
- Integration: narrower layer wins when the same ritual id exists in the programme and personal layers.
**Verification:** The new unit test passes, the schema doc fence passes, and an old record loads unchanged.

### U2. Authoring and recording verbs

**Goal:** Shawn's typed message can record, propose, retire, move and keep rituals; the PM can record runs and skips.
**Requirements:** R7, R9, R12, R13
**Dependencies:** U1
**Files:** modify `lib/programme_rituals.py` (`build_verbs`), `lib/programme.py` (register in `_VERBS`), `docs/contracts/agent-tool-surface.md`, `docs/contracts/run-record-schema.md` (journal kinds), `tests/unit/doc-fence-agent-tool-surface.test.sh`, `tests/unit/programme-verbs.test.sh`; extend `tests/unit/programme-rituals.test.sh`
**Approach:**
- Implement the KTD7 verbs through `host._write` with `needs_prompt` so the typed-message rule applies. Settle here how one chat answer naming several ritual ids maps to one verb call per ritual.
- `start-ritual` re-scans the steps (KTD8), refuses on a hit, and writes `ritual_started`. `run-ritual` writes `ritual_ran` (ritual, trigger, time, outcome); `fail-ritual` writes `ritual_failed`; `skip-ritual` writes `ritual_skipped`; `offer-rituals` writes `ritual_offered`.
- `run-ritual`, `skip-ritual` and `retire-ritual` set the programme's `ritual_clock` `next_due_at` to the first scheduled time after now, in the same write (KTD4).
- Adoption rows for stored layers follow the Behaviours `rule_adopted` pattern.
**Patterns to follow:** `_h_record`, `_h_retire`, `_h_keep` in `lib/programme_behaviours.py`; `lib/programme_behaviours_skip.py` for a verb that needs no typed prompt only when the answer is the picker pick.
**Test scenarios:**
- Happy path: `record-ritual` with a typed prompt naming the id and layer stores the ritual and journals `ritual_recorded`.
- Error: a cron-prompt citation or an untyped prompt is refused and journaled.
- Happy path: `run-ritual` on a weekly ritual advances that programme's `next_due_at` to the following week, and leaves another programme's clock for the same personal ritual unchanged.
- Happy path: `skip-ritual` advances `next_due_at` and journals `ritual_skipped`. Covers AE2.
- Edge: answering a weekly miss that is three weeks old sets `next_due_at` after now, not one week after the old time.
- Error: `start-ritual` on a stored ritual whose step is "deploy to production" refuses with `protected_escalation` and writes no `ritual_started`. Covers AE3.
- Happy path: `start-ritual` then `fail-ritual` leaves the ritual neither in flight nor answered-as-ran.
- Edge: `move-ritual` to the personal layer keeps the programme copy until the store holds a verified copy.
**Verification:** Both doc fences pass; each verb has a journal-kind entry in the schema doc.

### U3. Due, missed and in-flight computation

**Goal:** A pure function reports which rituals are due, missed or in flight from the record, journal and clock.
**Requirements:** R5, R6, R8, R10, R11
**Dependencies:** U1, U2
**Files:** create `lib/programme_rituals_due.py`, `tests/unit/programme-rituals-due.test.sh`; modify `lib/programme_sweep_inputs.py` (call it and add a rituals reason and a `rituals_due` verdict field)
**Approach:**
- Implement the HTD logic with the KTD3 grace window and the KTD4 calendar grammar (`next_due_at` computation as a small helper in the same module).
- Level-triggered like `programme_behaviours_due.due`: an answer row removes the item; a cap of 20 rows with overflow ids.
- A `ritual_started` row without a later `ritual_ran` or `ritual_failed` marks the ritual in flight.
**Patterns to follow:** `lib/programme_behaviours_due.py`.
**Test scenarios:**
- Happy path: a weekly ritual whose `next_due_at` passed one minute ago is `due`.
- Edge: the same ritual past two cadence periods is `missed`. Covers AE1 (three missed rituals appear together).
- Edge: a `ritual_skipped` row removes the miss and the next occurrence is due next week. Covers AE2.
- Edge: a weekly miss three weeks old, answered by run or by skip, is not offered at the next sweep.
- Edge: a `ritual_offered` row marks the miss `offered`; an unanswered picker is not reposted until a new miss appears or the set changes.
- Integration: a `ritual_started` row written before a PM dies reads `in_flight` for the takeover PM. Covers AE4.
- Edge: month-end monthly rule (day 31) lands on the last day of shorter months.
- Edge: a `ritual_started` row with no outcome gives `in_flight`. Covers AE4.
- Edge: more than 20 pending rituals returns 20 rows plus overflow ids.
**Verification:** Unit test passes; a sweep-inputs run on a fixture with one missed ritual reports `rituals_due` non-empty so the quiet-sweep rule cannot skip it.

### U4. Lifecycle triggers, handover and end gates, resume-after-gap

**Goal:** Every trigger in R4 reaches the due function, and `handover` and `end` give the outgoing PM a chance to run their rituals first.
**Requirements:** R4, R7, R8, R10
**Dependencies:** U3
**Files:** modify `lib/programme_lifecycle.py` (`_h_handover`, `_h_end`, `_h_beat`), `lib/programme_rituals_due.py`, `docs/contracts/run-record-schema.md`; extend `tests/unit/programme-rituals-due.test.sh` and the lifecycle tests
**Approach:**
- Start, takeover, handover, end and going-quiet need no new row: the due function reads `programme_started`, `taken_over`, `handed_over`, `programme_ended` and `stop_quiet` (KTD5). Going quiet counts once per active-to-quiet transition.
- `_h_beat` compares the stored `loop.last_beat_at` with now before overwriting it and, past the gap threshold, writes one `ritual_event` row for `resume_after_gap` in the same write. The threshold is a named constant set to the lease's two-cadence rule; it is revisited after a real journal is measured.
- `_h_handover` and `_h_end` refuse once when an active ritual with their trigger is unanswered, with a `fix:` line naming it; `--without-rituals` proceeds (KTD5b).
**Patterns to follow:** `_h_beat`, `_h_handover`, `_h_end` and `_finish` in `lib/programme_lifecycle.py`; `programme_home.lease_state`.
**Test scenarios:**
- Happy path: after `handover`, a handover ritual is `due` for the incoming PM from the `handed_over` row.
- Error: `handover` with an unanswered handover ritual refuses with a `fix:` line naming it; `--without-rituals` succeeds and the ritual then reads `missed`. Covers F3.
- Integration: a PM that wrote `ritual_started` and died is `in_flight` for the takeover PM. Covers AE4.
- Edge: a beat after a gap longer than the threshold writes one `resume_after_gap` event, not one per beat; a gap hidden by an unrelated write (for example `admit`) still counts because the comparison runs at beat time.
- Edge: a second `stop_quiet` row with no activity since the first does not make the going-quiet ritual due again.
- Edge: `end` with an unanswered end ritual refuses; `P status` shows the ritual missed after `--without-rituals`.
**Verification:** Lifecycle tests still pass; each trigger in R4 has a covering test.

### U5. Sweep step and missed-ritual picker

**Goal:** The PM runs due rituals and offers all missed ones in one picker.
**Requirements:** R7, R8, R9, R6
**Dependencies:** U3, U4
**Files:** modify `skills/programme-sweep/SKILL.md` (new step 5c, quiet-sweep rule, step 16 arming), create `skills/programme-sweep/references/rituals.md`, modify `tests/unit/programme-sweep-skill.test.sh`
**Approach:**
- Step 5c: for each `due` row the PM calls `start-ritual`, performs the steps, then calls `run-ritual` (or `fail-ritual`). For unoffered `missed` and `in_flight` rows it calls `offer-rituals`, asks one picker (run now / skip this time / retire; finish for in-flight) and records each answer with the matching verb.
- The picker never auto-answers and never runs a missed ritual before an answer.
- Add rituals due to the quiet-sweep rule's "changed" conditions, counting offered-but-unanswered rows as not new.
- No wake-up change: the existing cadence cron finds a due ritual within one cadence, inside the two-cadence grace window, and R6 asks for nothing more.
**Patterns to follow:** step 5 "Behaviours due" and `programme_carryover.offer`.
**Test scenarios:**
- Happy path: the skill text names step 5c and the quiet-sweep rule lists rituals due as a reason not to stay quiet.
- Edge: the skill test fails if the picker instruction allows running a missed ritual before an answer. Covers AE1.
- Happy path: the skill text calls `start-ritual` before any step and `offer-rituals` before the picker.
**Test expectation:** skill text is checked by the existing skill test style; behaviour is covered by U3 and U4.
**Verification:** Sweep skill tests pass; a dry sweep on a fixture with one missed ritual surfaces it in the digest.

### U6. Programme view for rituals

**Goal:** `P status` and the Programme view list rituals in force and missed rituals without a live PM.
**Requirements:** R11
**Dependencies:** U3
**Files:** modify `lib/programme_view.py` (`rituals_view`, text section), `lib/programme.py` (wire into `build_view`); extend `tests/unit/programme-rituals-due.test.sh`
**Approach:** Mirror `behaviours_view` and `_behaviour_row`: rows carry id, layer, trigger, state, next due, and a `missed` flag from the due function evaluated at read time.
**Patterns to follow:** `programme_view.behaviours_view`.
**Test scenarios:**
- Integration: a record with an orphaned lease and a missed ritual shows the ritual under `contract.rituals` in `P status --json`. Covers R11.
- Edge: a programme with no rituals prints no Rituals section.
**Verification:** JSON and text views both show a missed ritual on a fixture with no live PM.

### U7. Authoring skill, concept page and release

**Goal:** Shawn can say what a ritual should do in plain words and get a stored, confirmed ritual; the docs and version are updated.
**Requirements:** R12, R1, R2
**Dependencies:** U2
**Files:** create `skills/programme-ritual/SKILL.md`, `commands/programme-ritual.md`, `docs/concepts/programme/ritual.md`, `tests/unit/programme-ritual-skill.test.sh`; modify `docs/programme-overview.md`, `.claude-plugin/plugin.json` and `../../.claude-plugin/marketplace.json` (version bump per `../../scripts/check-version-bumped.sh`)
**Approach:**
- The skill interviews briefly (when does it run, what should the PM do, which layer), drafts the entry, shows it, and records it only after Shawn's typed confirmation naming the id and layer.
- It can propose rituals Shawn did not name (for example from the candidate triggers) as `propose-ritual` entries that need his answer.
- The concept page follows `behaviour.md`: one paragraph, where it lives, one note.
**Patterns to follow:** `skills/programme-remit/SKILL.md`, `docs/concepts/programme/behaviour.md`.
**Test scenarios:**
- Happy path: skill text requires a typed confirmation before `record-ritual` and names the protected-escalation refusal. Covers F4, AE3.
- Test expectation for docs and version: none -- covered by the version check script and doc fences.
**Verification:** Skill test passes; `scripts/check-version-bumped.sh` passes; publishing follows the shrimpshack publish workflow and the evals rule before any registry publish.

### Unit sequencing

U1 → U2 → U3 → (U4, U6 in parallel) → U5. U4 and U5 both touch `lib/programme_sweep_inputs.py` and the schema doc only through U3's function, so they do not conflict. U7 needs only U2 and can run in parallel with U3 to U6.

---

## Verification Contract

- Unit tests: run each touched script in `tests/unit/` (`programme-rituals.test.sh`, `programme-rituals-due.test.sh`, `programme-verbs.test.sh`, `programme-sweep-skill.test.sh`, `programme-ritual-skill.test.sh`, plus the lifecycle tests), through `bash ~/.claude/tools/honest-run/run.sh` with a marker that proves the tests ran.
- Doc fences: `tests/unit/doc-fence-agent-tool-surface.test.sh` and `tests/unit/doc-fence-run-record-schema.test.sh` must pass with the new verbs, journal kinds and fields.
- Mutation check: for each acceptance example, break the line that enforces it once and confirm its test fails (a green run can be incapable of failing).
- Manual check: in a scratch programme, record a weekly ritual, advance the clock past two cadence periods, and confirm the sweep shows one picker; answer "skip" and confirm no second offer.
- Release: `scripts/check-version-bumped.sh`; no registry publish without an eval run.

## Definition of Done

- Every R-ID is covered by a passing test or the manual check above, and AE1 to AE4 each have a test that fails when its enforcing line is broken.
- A missed ritual is never run before a picker answer, and the Programme view shows it with no live PM.
- Protected-escalation steps are rejected at record time and refused at run time.
- Concept page, format contract, agent-tool-surface and schema docs are updated and their doc fences pass. The plugin version is not bumped in this change: the repo ships by a separate `publish:` commit after merge, and nothing publishes without an eval run.
- Dead-end or experimental code from abandoned attempts is removed from the diff.

## Risks

- **Verb-surface growth.** Seven new verbs enlarge the tool surface and its doc fence; keep names parallel to Behaviours.
- **Grace-window mistuning.** Two cadence periods is borrowed from the lease; if it prompts too often or too late, adjust the one constant.
- **Month and weekday edge cases in the calendar grammar.** Covered by U3 edge tests; a richer grammar stays deferred.
