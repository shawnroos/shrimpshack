---
title: "fix: Rituals — clearer refusals, offer steps, first-due report, named clock"
type: fix
status: active
date: 2026-11-02
product_contract_source: ce-plan-bootstrap
origin: docs/handoff.md
---

# fix: Rituals — clearer refusals, offer steps, first-due report, named clock

## Goal Capsule

**Objective.** The first real ritual (daily 09:00 "every plugin version bumped", `r307220`) showed that recording and reading a ritual costs the PM guesswork. Make the refusals, the record result and the Programme view say what the PM needs to act.

**Constraints.**
- A ritual step carries no authority. Protected escalations stay with Shawn (handoff, Key decisions).
- A missed ritual is offered, never run late (unchanged).
- Do not edit the "Default behaviours" or "Behaviour conflict check" branches. Do not edit `lib/programme_behaviours.py`; both branches touch it.
- Do not publish, and do not bump the plugin version.

## Problem Frame

| # | Handoff point | Code finding (verified) | Class |
|---|---|---|---|
| 1 | Refusal names no step or word | `programme_rituals.py:137` raises `_Reject("protected_escalation", kind)`; `protected_kind()` drops which line matched. The wrong fix text ("type the approval") is attached elsewhere — locate at execution. | Defect |
| 2 | "Check, then offer" cannot be said | The scan covers every `steps` line, so an ask-first step that names "publish" is refused. | Defect (PM direction this session: failing tests first) |
| 3 | Mechanical check costs a model turn | Nothing runs commands on a schedule today. | Product choice — Shawn |
| 4 | No first-due report, no "ran now" | `_h_record` calls `advance_clock`, which sets `next_due_at` to the first slot strictly after now, and returns neither it. A ritual recorded after 09:00 waits until tomorrow; one recorded before 09:00 is due today, so the PM runs it by hand and calls `run-ritual`. | Defect |
| 5 | Which clock | `next_after` reads the schedule in the machine's local clock (`_local`, `astimezone()`); no output says so, and the view shows bare UTC. | Defect |
| 6 | PM downtime | Measurement only. | No code |
| 7 | Does a repo ritual travel | **No.** The repo layer is a section of the machine-level `rituals.json` beside the personal protocol, keyed by `repo_key`. No file is written inside the repo. | Finding; shipping with the repo is a product choice — Shawn |

## Scope

**In:** U1–U4 code and tests; U5 characterization test; U6 options note; U7 measurement.
**Out:** plugin version bump and publish (left to the PM); a check command on a ritual (point 3); a repo-committed ritual file (point 7 follow-up); both go in the options note.

## Implementation Units

Execution is sequential. U1–U4 all edit `lib/programme_rituals.py` or the record result, so parallel branches would conflict. U6 and U7 touch no code and can run beside any code unit.

### U1. Refusal names the step, the word and the fix  *(test first)*
- **Goal:** `ritual refused: protected_escalation (full_release: step 2 "publish the plugin" names "publish")` plus a fix line: reword the step, or move the action into an offer. U1 and U2 ship in the same PR, so the hint never points at a missing field.
- **Files:** `plugins/auto/lib/programme_rituals.py`: a new ritual-local `_scan(entry)` returns `(step_index, kind, word)` and `protected_kind` calls it; `_validate` puts step, word and the reword advice into the `_Reject` detail, which `refuse()` already prints, so `programme_layered_store.py` stays unchanged and Behaviour refusals do not change. The wrong "type the approval" fix is `programme_fixes.py:23` (`_TYPED`, mapped at line 115 for `record-ritual`); it is keyed by verb and cannot see the reason, so reword `_TYPED`'s record-ritual entry to cover both cases (typed words needed; a protected-word refusal is fixed by rewording). Do not edit `programme_behaviours.py`; reuse `programme_naming.name_words` and `programme_terms.PROTECTED_STEMS` / `PROTECTED_WORDS` from the ritual module.
- **Tests:** `plugins/auto/tests/unit/programme-rituals.test.sh` next to the existing AE3 cases.
  - Red first: a two-step ritual whose second step says "publish the plugin" is refused and the message holds `step 2` and `publish`.
  - The fix text does not mention typing an approval.
  - A stored ritual rejected on load carries the same detail (the long detail must survive `_Reject.detail` and the `rejected` row).
  - Wording of the existing AE3 case ("deploys to production") still names its kind.
- **Doc:** `docs/contracts/programme-rituals-format.md` line 15, error section line 50.

### U2. Offers may name a protected action  *(test first; after U1)*
- **Design (directional).** Add an optional `offers` list, separate from `steps`. `steps` keep the full protected scan. An `offers` line is a question for Shawn, never an action: the PM asks, and acts only on a typed pick through the normal gates. A separate field, not a keyword inside a step line, so the scan stays default-deny (a wording-based exemption would leak; see memory `enumeration fixes never close a class`).
- **Files:** `programme_rituals.py` (`OPTIONAL`, `_validate`, `_draft`, `_FIELDS_DOC`, `_h_record`, `_h_propose`: `--offer <line>`, repeatable); `programme_rituals_due.py` (`_row` carries `offers`); `programme_view.py` (`rituals_view`, `_ritual_text`); skill text for `programme-ritual` / `programme-sweep` so the PM reads an offer as a question.
- **Tests (red first):**
  - A ritual with `--step "check the plugin versions"` and `--offer "ask whether to publish the plugin now"` records.
  - The same text as a `--step` is still refused (guard unchanged).
  - A ritual with only offers and no steps is refused (`steps` stays required).
  - A due row and the Programme view show the offer.
  - An offer never changes `protected_kind(entry)` for the steps.
  - Run a ritual with an offer: no journal row records the action as done.
- **Doc:** rituals contract format table; add to `skills/programme-ritual` text that an offer needs Shawn's pick and the PM acts outside the ritual.
- **Validation and rollout:** `_validate` checks `offers` is a list of non-empty strings; `_move` and `_retire` copy the whole entry, so `offers` travels (add a test). The store is one machine-wide file read by every worktree, and an older plugin copy rejects `offers` as `unknown_key`, so the ritual stops firing there until that copy updates; say so in the contract doc. Cap offers in due rows like `when` (`TEXT_CAP`).
- **Risk:** the offer text must not become a back door. It is shown, never executed; the sweep and `run-ritual` ignore it for authority.

### U3. `record-ritual` reports the first due time; `--ran-now`  *(test first; after U2)*
- **Behaviour.** The result adds `first_due_at` (UTC), `first_due_local` and `clock`; all three are null/absent-with-note for an event ritual, which has no schedule. U3 adds the `describe_clock` helper and the clock sentence; U4 reuses them in the Programme view. `--ran-now [--outcome <text>]` means "the first slot was done by hand". It moves the clock past the current first slot (`advance_clock(now=<that slot>)`, so recorded at 08:00 the next due is tomorrow 09:00, not today) and puts `ran_now` and the outcome in the single `ritual_recorded` journal row. No separate `ritual_ran` row: `host._write` writes one row per call, and a clock past the slot already keeps the ritual out of `due`. An event ritual with `--ran-now` is refused with a clear message. Plain `run-ritual` before the slot has the same early-answer gap; out of scope, noted in the PR.
- **Decision:** a ritual recorded after today's time is due **tomorrow** (existing `advance_clock`); lock it with a test and state it in the result. No behaviour change.
- **Files:** `programme_rituals.py` (`_h_record`, `advance_clock`); reuse the run row from `programme_ritual_run.py` rather than copying it.
- **Test seam:** `_h_record` has no clock override, so `advance_clock`/the first-due computation is unit-tested through `run_py` with an explicit `now`; the CLI-level tests assert only relative facts (`first_due_at` is in the future, `--ran-now` leaves it after the first slot). No env override is added.
- **Tests (red first):** with a fixed `now` before 09:00 → `first_due_at` is today 09:00; after 09:00 → tomorrow 09:00; `--ran-now` at 08:00 → `next_due_at` is tomorrow, not in `due` or `missed` at 09:00, the recorded row holds the outcome; a bad `--outcome` or `--ran-now` on an event ritual is refused or no-ops with a clear message (decide at execution).

### U4. Show the clock in the Programme view  *(after U3)*
- **Behaviour.** The sentence U3 defines: "machine local time (<zone abbreviation>)". The record result and `rituals_view` show `next_due_at` in UTC and in local time with the zone name. No new schedule field.
- **Files:** `programme_rituals.py` (reuse `describe_clock`), `programme_view.py` (`_ritual_text`), contract doc.
- **Tests:** zone set by `TZ` plus `time.tzset()` in the helper script (the file today pins `TZ=UTC`): `America/New_York` daily 09:00 across spring-forward and fall-back stays 09:00 local; view text holds the zone abbreviation.
- **Note:** the schedule-in-local-time design is already in `next_after`'s docstring; this unit surfaces it, it does not change it.

### U5. Characterize the repo layer  *(after U4; small)*
- Add one test that pins today's behaviour: `move-ritual --to repo` writes into the machine store (`CLAUDE_AUTO_RITUALS_STORE`) under `repos.<key>`, not into the repo directory. State this in the contract doc. This answers point 7 with evidence; shipping a file with the repo waits for Shawn (U6).

### U6. Options note for Shawn  *(parallel, docs only)*
- `docs/ritual-options-note.md`, one page, 2 to 3 options each with one recommendation:
  - **Point 3, check command:** (a) sweep script runs a pinned command from an allowlist and wakes the PM only on failure; (b) a hook; (c) keep prose steps only. It must stay inside the worker-command guard rules, and a command must be recorded with Shawn's typed words like the ritual.
  - **Point 7, ship with repo:** (a) read `<repo>/.auto/rituals.json` as an extra layer source; (b) keep the machine store; (c) export/import verb.
- Delivery to the PM: the PM's claim channel needs a registered deliverable. `programme.sh claim --deliverable plan` was refused: `'plan' is not a deliverable of 'task:ritual-improvements'`, and `context` lists none. Ask the PM to register one, then send the claim.

### U7. Measure PM downtime  *(parallel, no code)*
- Read the programme journals (names and counts only) for the last 7 days; count gaps over one hour between PM sweep rows. Put the number in the PR body; add it to the options note when U7 finishes (U6 is finalized last). No code merged.

## Parallelism Analysis

| Lane | Units | Why |
|---|---|---|
| A (sequential) | U1 → U2 → U3 → U4 → U5 | Same files and one shared test file |
| B | U6, U7 | Docs and read-only measurement; run beside lane A |

## Test Strategy

Tests are shell tests in the existing style (`it`, `check`, `has`). Each red-first unit commits its failing tests first, then the change; the PR shows the red commit. Run through `bash ~/.claude/tools/honest-run/run.sh --expect "<marker>" -- bash plugins/auto/tests/unit/programme-rituals.test.sh` so a silent run is not read as a pass. Run `programme-verbs`, `programme-ritual-skill`, and the two integration tests (`programme-ritual-gates`, `programme-sweep-inputs`).

## Risks

| Risk | Mitigation |
|---|---|
| Offer field becomes a way to smuggle an action | Separate field, never executed, never changes the step scan; test pins it |
| Editing `programme_behaviours.py` collides with two other workers | Ritual-local helper; do not edit that file |
| Time-zone tests flaky under the file's `TZ=UTC` pin | Set zone per helper call, restore after |
| Contract doc and skill text drift from code | Update docs in the same unit as the code; `programme-ritual-skill.test.sh` covers the skill |

## Open Questions (for Shawn, via the PM)

- Point 3 option and point 7 option (U6).
