---
title: "Default behaviours slice 2, PR A: worker clauses read the shipped files"
date: 2026-11-02
status: draft
product_contract_source: ce-plan-bootstrap
depth: standard
---

# Default behaviours slice 2, PR A: worker clauses read the shipped files

## Problem frame

Three worker clauses are typed by hand in three places: `skills/programme-sweep/SKILL.md:383-388`, `commands/programme-resume.md:104`, and whatever the PM pastes into a brief or `prompt-item`. Slice 1 moved only "record before any long background wait" into `behaviours/record-before-long-wait.md`, and the SKILL.md copy of that line still exists. Result: two sources of truth, and a size cap on SKILL.md that blocked the rewrite.

Clause key: W1 = record before any long background wait (`behaviours/record-before-long-wait.md`, from slice 1); W2 = never prompt the PM's pane; W3 = denied command; W4 = assignment-Ruling quoting (stays in code). Direction (PM, 2026-11-02): PR A first. Then PR B (`before-merge` trigger with the merge-pin rule), then PR C (`always` trigger with `judgment.md`). Each is its own PR. This plan covers PR A only.

## Scope

In:
- W2 "never prompt the PM's pane; report with `programme.sh claim ...`" becomes a shipped file.
- W3 "denied command: do not rerun, no other tool, wrapper or worker; continue the work that does not need it" becomes a shipped file.
- Prompts to running workers (`prompt-item`, the resume prompt) get these clauses from the files, not from typed text.
- Delete the SKILL.md and `programme-resume.md` copies of W1, W2, W3.
- Fix #194 (shadowed rows), #195 (approval replay), #196 (write rollback) in the machinery.

Note: `start-worker --handoff <missing file>` already errors since slice 1 (a shipped default joins the tail and `_read_brief` opens the file); this PR does not change that, so the PR text need not claim a new side effect.

Out (kept in code): the `claim` verb itself, the `--decision` and `--restriction` flags, the assignment-Ruling quoting (W4 lookup). Out of this PR: `before-merge`, `always`, `judgment.md`, `winners()`, #197-#199.

## Key findings from the code (verified by reading)

- A `trigger: start`, `applies_to: workers` file already joins every start brief that has a handoff, as a "Behaviours this work follows:" block (`lib/programme_behaviours.py:363` `brief_lines`, called from `_h_start_worker` in `lib/programme_sources.py`).
- A plain `start-worker` with no handoff gets no brief, and `_read_brief` refuses a tail without `--handoff`. Those workers get the clauses from a first `prompt-item --standing`.
- `prompt-item` (`lib/programme_sources.py:845`) appends only decisions and restrictions. It has no way to append behaviours, so the PM types the clauses.
- The W2 text holds run id, item id and the plugin root. A shipped file cannot hold those. The file needs placeholders that code fills at render time.
- `_approve` (`lib/programme_behaviour_file_verbs.py:136`) accepts an approval keyed to a content hash with no use record, so the same approval can apply twice (#195).
- `_h_copy` writes the personal file, then records `seen` in a second step (`:186-205`). A failure between the two leaves the file without the record (#196). `_atomic` already makes each single write safe.
- `load_into` rejects a personal file whose id matches a stored personal entry ("shadowed"), as a notice only; no row in the rules or Programme view (#194).

## Decisions

1. **Placeholders, filled by code.** Shipped files may use `{claim_command}`; `brief_lines` fills it per run and item from run id, item id and plugin root only. A file with an unknown placeholder fails the load. The claim command stays in code.
2. **`prompt-item --standing`.** A new flag appends the in-force worker behaviours with trigger `start` as a block, the same text the start brief carries. The PM stops typing clauses. The resume prompt uses the flag. For a plain `start-worker` with no `--handoff` there is no brief file to carry anything (`_read_brief` refuses without a handoff), so the PM sends `prompt-item --standing` as that worker's first prompt. No carve-out in `brief_for_start`, no new frontmatter key.
3. **W3 wording passes the scanner.** The load path scans every line and rejects the protected stems "permission", "refused", "denied" (`lib/programme_terms.py:42`). The shipped W3 file says: "Do not run a blocked command again, and do not try another tool, wrapper or worker for it. Continue the work that does not need it; the PM reads the block from your transcript." Its `when:` avoids the stems too. The scan is not relaxed for shipped files. The meaning is the PM's wording; the words differ.
4. **Size budget.** `lib/programme_sources.py` is 987 lines against a 1000-line budget. The `--standing` block builder goes in `lib/programme_behaviours.py` (or a new small module), not in `programme_sources.py`; the handler there only calls it.
5. **No violation transcript review.** The journal restatement counts (W2 21 of 54 prompts, W3 13 of 54) already show the rules are repeated by hand; a miss count would not change the order or scope here. Skipped.

## Implementation units

### U1. Two shipped worker-clause files and placeholder rendering
Files: `behaviours/never-prompt-the-pm-pane.md`, `behaviours/denied-command-stop.md` (wording per Decision 3), `lib/programme_behaviour_files.py` (placeholder check at load), `lib/programme_behaviours.py` (`brief_lines` fill), `docs/contracts/programme-behaviours-format.md` (document placeholders).
Tests: `tests/unit/programme-default-behaviours.test.sh`, `tests/unit/programme-behaviour-files.test.sh`.
Scenarios: both shipped files load (a test loads the real files, so a scanner rejection fails the suite); unknown placeholder refuses the load; rendered line holds the real run, item and claim command; a start with `--handoff` carries all three clause files (W1, W2, W3) once; rendered size of the block is measured and asserted under a stated number.
Depends on: none.

### U2. `prompt-item --standing`
Files: `lib/programme_behaviours.py` (block builder), `lib/programme_sources.py` (`_h_prompt_item`: parse the flag, call the builder), usage text where `prompt-item` usage lives, `docs/contracts/`.
Scenarios: flag appends the block; no flag appends nothing new; text over `PROMPT_CAP` (4000) refuses with the existing message; a plain `start-worker` followed by `prompt-item --standing` delivers all three clauses; `tests/unit/size-budget.test.sh` still passes.
Depends on: U1.

### U3. Delete the hand-typed copies
Files: `skills/programme-sweep/SKILL.md` (lines ~380-388 become: "start briefs carry the worker behaviours; for a start with no handoff, and for every later reminder, send `prompt-item --standing`"), `commands/programme-resume.md:~104`.
Scenarios: a grep test fails if any of the three sentences appears outside `behaviours/`; the SKILL.md line count falls.
Depends on: U2.

### U4. #194 shadowed rows
Files: `lib/programme_behaviour_files.py` (`load_into`), `lib/programme_view_behaviours.py`, the `rules` output.
Fact from the code: `load_into` (`:274`) rejects a personal file whose id matches a stored personal entry, reason "shadowed", but only as a notice; no row appears in the rules or the Programme view. `resolve()` keeps stored programme and repo entries coexisting with a shipped default, so a default is not "shadowed" by them today.
Scenarios: the rejected personal file shows as a shadowed row in `rules` and the view. Open question for the PM, not decided here: should a programme or repo entry that shares a default's id also show a row? The issue text suggests yes; today's resolver keeps both in force. Default for this PR: show the notice-backed case only, and ask.
Depends on: none.

### U5. #196 write rollback
Files: `lib/programme_behaviour_file_verbs.py` (`_h_copy`, `_settle`).
Design: `_h_copy` removes the new personal file if `_record` fails (the file did not exist before). `_settle` modes `merge` and `take` capture the prior file text before the write and restore it, or recreate it for `take`, if `_record` fails.
Scenarios: force `_record` to fail after the write, in copy, merge and take; assert the verb errors and the personal file equals its state before the call (absent for copy); a second try succeeds. Mutation check: remove the restore and confirm the test fails.
Depends on: none.

### U6. #195 approval replay
Files: `lib/programme_behaviour_file_verbs.py` (`_approve`, `_seen_doc`), `lib/programme_protocol.py` only if the key helper needs a field.
Design: record the consumed approval key (prompt id plus content hash) in the same locked document as `seen`, only after the write and `_record` succeed (so a failed write, rolled back by U5, does not burn the approval). A second use of a consumed approval always refuses, even for the same unchanged write; the PM gets a fresh approval to retry after success. The verb's own operation-replay path (`programme_recovery.admit`, `replayed`) is separate and unchanged.
Scenarios: same prompt, same hash, applied twice: second refuses; new hash, same prompt: refuses on the hash; failed write then retry with the same approval: allowed.
Depends on: U5.

## Parallelism

```
lane 1:  U1 -> U2 -> U3
lane 2:  U4            (independent)
         U5 -> U6      (same file, sequential)
```
Lanes 1 and 2 can both touch `lib/programme_behaviours.py` (U1, U2, U4) and `lib/programme_behaviour_files.py` (U1 placeholder check, U4 shadow record); keep U4 in `load_into` and U1 in the parse path. Run lane 1 and lane 2 in two worktrees if parallel; merge lane 2 first. With one worker, order: U1, U2, U3, U5, U6, U4. One PR, one review pass.

## Verification

- Run the unit tests through `bash plugins/auto/tests/run.sh` or the single test path, via `honest-run` with `--expect`.
- Manual check: start a worker with `start-worker` on a scratch programme; read its first prompt and confirm the three clauses appear once. Send `prompt-item --standing`; confirm the block. Journal shows the same text.
- Review: ce-simplify-code, then ce-code-review until P0-P2 are clear. Thermo-nuclear once, because this changes the briefs every worker receives. Log P3 as GitHub issues in `shawnroos/shrimpshack`. Do not publish.

## Risks

- A worker brief that is now long enough to hit `PROMPT_CAP` on prompts that already carry decisions. U3 covers the refusal; measure the rendered size in U1.
- Placeholder fill must not take text from a worker-controlled field. Fill from run, item and plugin root only.
- U5 and U6 interact; the success-only recording in U6 is what stops a failed write burning an approval.

## Not done in this plan

- `ce-doc-review` ran with coherence and feasibility (2026-11-02, non-interactive); 5 coherence and 7 feasibility findings applied. Adversarial review (activated: no upstream Product Contract) and the cross-model pass were not run: the PM fixed the scope and order, and the cross-model pass sends the plan off this machine.
- #194-#196 root causes come from the issue text and a read of `programme_behaviour_file_verbs.py`; confirm each by reproducing before fixing (U4-U6 each start with a failing test).
