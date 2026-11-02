---
artifact_contract: ce-unified-plan/v1
execution: code
product_contract_source: ce-plan-bootstrap
type: feat
title: "feat: check every new behaviour against the behaviours in force and the programme contract - Plan"
date: 2026-11-02
origin: docs/handoff.md
---

# feat: check every new behaviour against the behaviours in force and the programme contract - Plan

## Goal Capsule

**Objective:** When Shawn's words become a standing behaviour, the PM and Shawn see, in one message at the moment of recording, which behaviours and which parts of the programme contract the new one touches and which it may contradict.

**Means:** A reasoned, deterministic comparison at record time that hands the PM a structured side-by-side for the judgment code cannot make (KTD1, KTD2).

**Authority hierarchy:** Shawn's typed rule (handoff, 2026-11-02) and the PM addition (the check also runs against the contract) > this plan > the existing behaviours contract (`plugins/auto/docs/contracts/programme-behaviours-format.md`). A behaviour carries no authority; the check informs and decides nothing.

**Stop conditions:** Stop and report to the PM if the work needs a decision Ruling, a change to the PR #165 branch, or a plugin publish.

**Ships:** One PR to `main`, no version bump, no publish.

---

## Product Contract

### Summary

`record-behaviour` today returns a `related` list built from single shared words. This work replaces that list with two reasoned results shown together: behaviours the new one applies alongside or may compromise, and contract parts it references or may contradict. Shawn or the PM can then link what applies and mark what does not.

### Problem Frame

Measured on this machine (names and counts only, 20 stored repo behaviours, 190 pairs): the current rule flags 48 pairs. 19 of them are in different repos, so no item is ever under both. 43 of the 48 share exactly one word. Only 3 survive "same repo and two or more shared `when` words". The live pair from the handoff, b51850c (retire a finished worker) and bc3f80d (every sweep, move every session forward), shares one `when` word ("session"), so the current rule lists it with no stated reason. The instructions of each do speak about the other's situation: bc3f80d's `when` words "remit" and "session" appear in b51850c's `do`/`dont` lines. Counting that cross-field overlap (two or more words, either direction) lists the live pair and, together with the `when`-to-`when` rule, 8 of the 126 same-repo pairs. Nothing compares either behaviour with the programme's terms, preferred tools, Rulings, Authority levels or Done standards. The only contract check today is the refusal of protected escalations (`protected_kind`, `plugins/auto/lib/programme_behaviours.py:144`).

Real-data limits shape the design: no pair has a `do` line equal to the other's `dont` line, only 2 of 20 set a trigger, and only 3 of 20 name a tool, skill or agent. Code can narrow the candidates and give reasons. It cannot decide which pairs contradict.

### Requirements

**Scope of the check**
- R1. Every behaviour that becomes active runs the check: `record-behaviour` (direct and `--from-proposal`). Behaviours from other layers join through the same input shape, so shipped defaults (PR #165 "ship default behaviours as editable files") need no new code once they exist.
- R2. The behaviour result lists only behaviours that can be in force for the same item as the new one. Two behaviours cannot co-apply when their audiences do not intersect or they sit in different repos.
- R3. Each listed behaviour carries a stated reason from a closed set: same trigger; shared `when` subject (two or more content words in both `when` texts); instruction touches situation (two or more content words shared between one behaviour's `when` and the other's `do`/`dont` lines, either direction); shared named tool, skill or agent; an equal `do`/`dont` line; or a tool one names and the other forbids in `dont`. A single shared word is not a reason.
- R4. A pair where a `do` line of one equals a `dont` line of the other, or one names as a tool what the other forbids by `dont`, is flagged as a possible compromise with that reason. `check-behaviour` also returns both behaviours' `do`, `dont` and `stop` lines side by side for every listed pair, so the PM can judge the cases code cannot.

**Contract check**
- R5. The check reads the programme contract from one snapshot: agreement terms (cadence, stop rule, remit, tools of record), preferred tools, Rulings in force with their effect, Authority levels and protected escalations, Done standards (rules), and the operating contract line. The contract line applies to every behaviour, so it is read but never printed as a row.
- R6. Each contract part the new behaviour touches is listed with a reason and the part's id and text. A part is touched when the behaviour names its subject (a tool it names; a deliverable word a Done standard requires; "sweep", "every" or "remit" against cadence and remit; a `stop` line against the stop rule; a decision kind a Ruling or Authority level reserves).
- R7. A contract part is flagged "may contradict" when: a preferred-tool text says not to use a tool the behaviour names; a `do` line touches a kind that an active `restrict` Ruling or an Authority level stricter than PM-decides reserves for Shawn; or the behaviour's `stop` line shares two or more content words with the stop-rule text. A `stop` line alone gives a plain stop-rule row. The protected-escalation refusal is unchanged.

**Output and answers**
- R8. `record-behaviour` prints the behaviour result and the contract result in the same output as the checks and the `undo` line. The output always names the reasons it checked and says that opposite meaning is not detected, so an empty list is not read as a pass.
- R9. `--relates-to <id>` and `--unrelated <id>=<reason>` store the answer on the entry (`relates_to`, `unrelated`), and the output reports how many listed items are still unanswered. `--conflicts-with` keeps its meaning.
- R11. `check-behaviour`, a read-only verb with the same field flags and no prompt, prints both results and writes nothing. The PM runs it before recording so Shawn sees the result before the behaviour takes effect.
- R10. The check never refuses to record, never changes a Ruling or Authority level, and never turns a behaviour into a gate on a protected escalation. Recording still needs Shawn's typed words.

### Key Decisions

- **The check informs; it does not refuse.** Refusing until every flagged item is answered is a product-shape choice for Shawn. This plan ships the advisory form and the `unanswered` count, and the PR body asks Shawn whether to make the count a refusal. Governs R9, R10.

### Scope Boundaries

**Deferred for follow-up**
- Refusing to record until the check is answered (open question for Shawn).
- A `link-behaviour` verb to answer an old behaviour's check after recording. Until then the PM answers by running `check-behaviour`, then `record-behaviour` with `--relates-to` and `--unrelated`, or by undoing and re-recording as the sweep reference already says for `--conflicts-with`.
- Re-running the check when a Ruling, term or preferred tool changes later.
- Shipped defaults as a layer: PR #165 is open and its branch is not touched here.

**Outside this work**
- Any model call inside the verb, and any change to how behaviours resolve, deliver or override one another.

### Open Questions

- **For Shawn (not blocking):** should recording refuse until each listed item is linked or marked unrelated with a reason? The default shipped is no.

---

## Planning Contract

### Key Technical Decisions

- **KTD1. Reasons come from a closed set, not a word list.** The applicability reasons are the six in R3. The measurement above shows a one-word match is noise (43 of 48), exact-text reasons are rare, and the cross-field reason is the one that lists the live pair, so every row says which reason fired. Governs R2, R3.
- **KTD2. Code narrows and explains; the PM judges.** The verb returns a side-by-side for each listed pair and part. It does not call a model: the verb runs under the programme lock, tests run offline, and a model verdict would not be repeatable. Only structural contradictions (R4, R7) are flagged by code. Governs R4, R7.
- **KTD3. Two small modules, one shared row shape.** `programme_behaviours.py` is 948 lines; the comparison goes in `lib/programme_behaviour_check.py` (behaviours against behaviours) and `lib/programme_contract_check.py` (behaviour against the contract snapshot). Behaviour rows are `{ref, kind, reasons: [..], lines: {do, dont, stop}, text, flag}`. Contract rows are the same without `lines`. `flag` is `may_contradict` or absent. Governs R2 to R7.
- **KTD4. One snapshot for the contract.** The check calls `rules_in_force` (`plugins/auto/lib/programme.py:162`, reached through `host`) with `behaviours=False, changes=False` and passes the result to `lib/programme_contract_check.py`. That one dict holds the terms, Rulings, Authority levels, Done standards and, once the agreement is accepted, `operating_contract` with the preferred tools and protected kinds. Before acceptance there is no `operating_contract`, and the check skips preferred tools. The behaviour side keeps `_active` (programme plus stored layers), because it applies the held and moved rules. Governs R5.
- **KTD5. Contract-part ids share one namespace with behaviour ids.** `relates_to` and `unrelated` take a behaviour id as it is, and a contract part as `ruling:<id>`, `term:<key>`, `tool:<id>`, `rule:<id>`, `authority:<action>`, or `contract`. The format doc's id check widens for these two fields only. Governs R9.
- **KTD6. The old `related` key is replaced by `behaviours`.** Rows carry `reasons` instead of `shared`. `related` is read in four places that change with it: the old test (`plugins/auto/tests/unit/programme-behaviours.test.sh:627-629`, rewritten to a two-word case), `skills/programme-sweep/references/behaviours.md`, the `behaviour_recorded` payload line in `docs/contracts/run-record-schema.md`, and the journal row, because `_write` journals the whole return value. `record-behaviour` returns rows without the `lines` side-by-side, because `_write` journals and replays whatever the handler returns; `check-behaviour` returns the rows with `lines`. Governs R3, R8.

### High-Level Technical Design

```text
record-behaviour
  entry  = draft (or proposal)
  active = _active(programme, store)            # programme + repo + personal [+ defaults]
  snap   = contract_snapshot(host, rec)          # rules_in_force + project terms + protected kinds

  peers  = [b in active if co_apply(entry, b)]   # audience intersects, same repo or no repo
  behaviour_result = for b in peers:
        reasons = same_trigger | shared_when(>=2) | instruction_touches_situation(>=2)
                | shared_tool | equal_do_dont | tool_forbidden_in_dont
        keep b only when reasons non-empty; flag may_contradict on equal_do_dont / tool_forbidden_in_dont
  contract_result  = for part in snap:
        reason = names_subject(entry, part)      # per part kind, see R6
        flag may_contradict per R7

  output = {checks, undo, behaviours: behaviour_result, contract: contract_result,
            unanswered: count(rows not in relates_to / unrelated)}
```

### Assumptions

- A behaviour's `when.text`, `do`, `dont`, `tools`, `skills`, `agents` and `stop` are the only fields compared. `evidence` and `why` are not (the format doc already exempts them from the protected-escalation scan).
- Decision kinds come from `programme_decisions` and Authority actions from the protocol autonomy map. Their exact word forms are read at implementation time; the match uses the same word-start rule as `_line_kind` so "reproduction" does not match "production".
- `rules_in_force` is safe to call inside the record lock because it reads the record in hand and the protocol files only. Confirm during U3.
- Contract rows for the current programme (4 terms, 3 preferred tools, 1 Ruling, 11 rules, the contract line) are small enough to print whole. If a programme's rows exceed the sweep digest's 20-line habit, print counts first and the rows after.

### Sequencing and parallelism

```text
U1 failing tests + fixtures        (first; fixes the row shape)
 |
 +-- U2 behaviour check module  --+
 |                                +--> U4 wire into verbs + fields --+
 +-- U3 contract check module   --+                                  +--> U6 full run + re-measure
 |                                                                   |
 +-- U5 docs (5 files) ----------------------------------------------+
```

U2, U3 and U5 touch disjoint files and depend only on the row shape from U1, so they can run in parallel. U4 needs U2 and U3. U6 needs U4 and U5. The units are small; running U2 and U3 in two parallel agents is optional, and one agent running them in order is acceptable.

### Risks

- **A reason that fires on nearly everything.** "Shared subject" could re-create the noise. Mitigation: the two-word floor and the co-apply filter, and U6 re-runs the 190-pair measurement and reports the new count in the PR.
- **Contract kind words are broad** ("scope", "merge"). Mitigation: only a `restrict` Ruling or an Authority level stricter than PM-decides can raise `may_contradict`; other matches stay plain references. The stop-rule row is a plain reference unless the `stop` line shares two or more content words with the stop-rule text, so a behaviour that merely has a `stop` is not flagged.
- **An empty result reads as a pass.** Most real contradictions use no shared word, so the list will often be empty. Mitigation: the output always states which reasons were checked and that opposite meaning is not detected (R8).
- **`related` is read in four places.** KTD6 names them; U1 and U5 update all of them.

---

## Implementation Units

### U1. Failing tests first

**Goal:** Pin the behaviour with tests that fail on today's code and fix the row shape.
**Requirements:** R2, R3, R4, R6, R7, R8, R9, R10, R11.
**Dependencies:** none.
**Files:** `plugins/auto/tests/unit/programme-behaviour-check.test.sh` (new), `plugins/auto/tests/unit/programme-behaviours.test.sh` (edit lines 627-629), `plugins/auto/tests/fixtures/` (only if a fixture helper is needed).
**Execution note:** Write the b51850c versus bc3f80d test first and watch it fail before any library change.
**Approach:**
- Follow the helper style of `programme-behaviours.test.sh` (`run_py`, `setup`, `beh`, `prompt_for`).
- Seed the two real behaviours' shapes (names and structure, not private text) and a contract with a cadence term, a stop rule, a preferred tool, a `restrict` Ruling and a Done standard.
**Test scenarios:**
- Record "retire a finished worker" against "every sweep, move every session forward" using the real pair's `when`, `do` and `dont` words: the result lists bc3f80d with reason "instruction touches situation" (words "remit" and "session"), shows both sides' `do`/`dont`/`stop`, and the contract result references the cadence and remit terms.
- A behaviour sharing exactly one `when` word with another lists nothing (the old noise case).
- Two repo-layer behaviours in different repos are never listed against each other.
- A `workers`-only behaviour and a `pm`-only behaviour are not listed against each other.
- A `do` line equal to another behaviour's `dont` line is listed with `may_contradict`.
- A preferred-tool text "do not use X" and a new behaviour with `--tool X` gives a `may_contradict` contract row.
- A `do` line touching a kind reserved by an active `restrict` Ruling gives a `may_contradict` row; the same line with no such Ruling gives a plain reference or nothing.
- A `stop` line gives a plain stop-rule row; it gets `may_contradict` only when it shares two or more content words with the stop-rule text.
- A behaviour with nothing to list prints which reasons were checked and that opposite meaning is not detected (R8).
- `check-behaviour` with the same fields prints both results, writes nothing, journals nothing and needs no prompt (R11).
- A `do` line naming a production deploy is still refused with `protected_escalation` (R10).
- `--relates-to` and `--unrelated id=reason` store on the entry and lower `unanswered`; `--unrelated` without a reason is refused; an unknown id is refused.
- Recording succeeds with unanswered items (R10), and the entry's `history` and `overrides` are unchanged by the check.
- `--from-proposal` runs the same check.
**Verification:** The new file fails on the unmodified library for the reasons above, and the edited old test fails the same way.

### U2. Behaviour-versus-behaviour check

**Goal:** Return reasoned rows for the behaviours that can apply with the new one.
**Requirements:** R2, R3, R4, R1.
**Dependencies:** U1.
**Files:** `plugins/auto/lib/programme_behaviour_check.py` (new), `plugins/auto/lib/programme_behaviours.py` (remove `_related`, `_topic` once nothing calls them).
**Approach:**
- `co_apply` filters by audience intersection and repo compatibility (KTD1, R2).
- Reasons per KTD1; `equal_do_dont` and tool-versus-`dont` set `flag` (R4).
- Word extraction reuses `programme_naming.name_words` and the existing common-word list.
- Layer-agnostic: no branch on layer names beyond `repo_key`, so defaults need no change.
**Patterns to follow:** `_line_kind` word-start matching in `programme_behaviours.py`; pure functions returning plain dicts, as `programme_terms.py` does.
**Test scenarios:** Covered by U1; add unit cases for `co_apply` edges (`both` against `pm`, a repo entry against a no-repo item) in the same new test file.
**Verification:** U1's behaviour cases pass; no import cycle with `programme_behaviours.py`.

### U3. Behaviour-versus-contract check

**Goal:** Return reasoned rows for each contract part the new behaviour touches or may contradict.
**Requirements:** R5, R6, R7.
**Dependencies:** U1.
**Files:** `plugins/auto/lib/programme_contract_check.py` (new).
**Approach:**
- Input: the entry and the `rules_in_force` snapshot (KTD4). Output rows as in KTD3, with the ids from KTD5.
- `contract_snapshot(host, rec)` builds the snapshot as KTD4 says. The operating contract line is read but never becomes a row (R5).
- One small matcher per part kind: terms, preferred tools, Rulings, Authority levels, Done standards.
- Reserved-kind matching uses the word-start rule; only `restrict` Rulings and Authority levels stricter than PM-decides can flag.
- Calling `rules_in_force` inside the record lock is safe (`change()` already loads the store there); pass `changes=False` to skip the protocol-changes report.
**Technical design:** Directional only: `for part in snapshot.parts(): reason = MATCHERS[part.kind](entry, part); if reason: rows.append(row(part, reason))`.
**Test scenarios:** Covered by U1's contract cases.
**Verification:** U1's contract cases pass; protected-escalation refusal tests in `programme-behaviours.test.sh` still pass.

### U4. Wire into record-behaviour and the entry fields

**Goal:** Print both results before and at recording, accept the answers, and store them.
**Requirements:** R1, R8, R9, R10, R11.
**Dependencies:** U2, U3.
**Files:** `plugins/auto/lib/programme_behaviours.py` (`_h_record`, a new read-only `check-behaviour` handler, `_check_extras`, the `OPTIONAL` key set that `_validate` checks), `plugins/auto/lib/programme.py` (verb table and usage text for `record-behaviour` and `check-behaviour`).
**Approach:**
- `check-behaviour` takes the same field flags as `record-behaviour` without `--prompt`, builds the draft, runs both checks against the programme as it stands, prints the result and writes nothing. This is how Shawn sees the check before the behaviour takes effect (R11).
- `_h_record` builds both results inside `change`, sets `relates_to`/`unrelated` on the entry before `put_programme_entry`, and returns `behaviours`, `contract`, `unanswered` and the checked-reasons line beside `checks` and `undo`. The journaled payload carries ids, reasons and flags only (KTD6).
- `relates_to` and `unrelated` flags go in `_h_record`'s own multi-value tuple beside `conflicts-with`, not in `_FIELD_MULTI`: `_has_fields` and `propose-behaviour` read `_FIELD_MULTI`, and `--from-proposal ... --relates-to` must stay legal.
- `_check_extras` and `OPTIONAL` accept `relates_to` (list of ids per KTD5) and `unrelated` (list of `{id, reason}`, reason not empty). Any other key is still rejected.
- The check must not raise: a failure in a matcher is reported as a notice in the output and the behaviour still records (R10).
**Test scenarios:** Covered by U1.
**Verification:** All U1 tests pass; `programme-behaviours.test.sh` passes in full.

### U5. Documentation

**Goal:** State the check in the places the PM and Shawn read.
**Requirements:** R8, R9.
**Dependencies:** U1 (row shape).
**Files:** `plugins/auto/docs/contracts/programme-behaviours-format.md` (entry table adds `relates_to`, `unrelated`; new section "The record-time check" with the reasons, the two results and the no-refusal rule; section 6 line on `overrides`), `plugins/auto/skills/programme-sweep/references/behaviours.md` (replace the "read `P rules`, pass `--conflicts-with`" advice with the two results shown in one message, plus how to answer), `plugins/auto/skills/programme-sweep/SKILL.md` (step 3 row and the "Behaviours" pointer), `plugins/auto/docs/contracts/agent-tool-surface.md` (the Behaviours entry, lines 255-275 area, now naming `check-behaviour`), `plugins/auto/docs/contracts/run-record-schema.md` (the `behaviour_recorded` payload line that lists `related`).
**Approach:** Write the durable docs in plain sentences of 20 words or fewer. State each reason once, in the format doc; the other files link to it.
**Test expectation:** none -- documentation. Run `bash plugins/auto/tests/run.sh unit` for any docs lint test the repo has.
**Verification:** The reference tells the PM to run `check-behaviour` first, show Shawn the one-message template (checks, the two results, the `undo` line, the layer question), then record with his answers.

### U6. Full run and re-measurement

**Goal:** Prove nothing else broke and report the new noise count.
**Requirements:** R2, R3.
**Dependencies:** U4, U5.
**Files:** none new. The measurement runs from the scratchpad, read-only.
**Approach:**
- Run unit and integration through `honest-run` with the expect markers the repo's runner prints; read the verdict line.
- Re-run the 190-pair measurement with the new rule and put old and new counts in the PR body.
- Recall check: the live pair and the three same-repo `when`-to-`when` pairs must each appear with a stated reason. State them in the PR.
- Run the real pair (b51850c, bc3f80d) against a scratch copy of the programme and show the output.
**Verification:** `plugins/auto/tests/run.sh unit` and `integration` pass with a verdict line; at most 10 same-repo pairs are listed (8 expected), and every pair in the recall check is listed with its reason.

---

## Verification Contract

- `bash ~/.claude/tools/honest-run/run.sh --expect "<runner pass marker>" -- bash plugins/auto/tests/run.sh unit`, then the same with `integration`. Confirm the marker text from a first run's output before trusting it.
- This change is Python and Bash only, so the JS/TS lint router is expected to be a no-op.
- `bash ~/.claude/tools/comment-bloat/run.sh` on the changed files.
- Manual: record a behaviour on a scratch programme and read the printed output against the sweep reference's one-message template.

## Definition of Done

- All R1 to R11 hold and each has a passing test (U1).
- The full unit and integration runs pass, shown by a verdict line.
- Listed pairs drop from 48 to at most 10, with the recall check met, stated in the PR.
- The docs in U5 match the code.
- No change to the PR #165 branch, no version bump, no publish.
- Abandoned-attempt code is removed from the diff (`_related` and `_topic` are gone if unused).
- ce-code-review has no open P0 to P2 finding; P3 findings are filed as GitHub issues in `shawnroos/shrimpshack`; thermo-nuclear review ran once.

## Sources

- `docs/handoff.md` (repo root worktree copy), the PM addition on the contract check.
- `plugins/auto/lib/programme_behaviours.py` (`_related`, `_topic`, `_h_record`, `_check_extras`, `protected_kind`).
- `plugins/auto/lib/programme.py` (`rules_in_force`), `plugins/auto/lib/programme_view_agreement.py` (the contract parts and where each is held), `plugins/auto/lib/programme_terms.py` (protected stems).
- Measurement: this machine's behaviours store (20 repo entries) and the live programme record, counts only.
