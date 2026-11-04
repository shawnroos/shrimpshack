# Default behaviours, slice 2: inventory of hard-coded rules

Scope rule (Shawn): a rule enforced by code stays in code. A rule that is only advice to the PM or a worker can move to a shipped default behaviour.
Triggers today (`lib/programme_behaviours.py:50`): claim, merge, block, start, domain. Shipped defaults today: one (`behaviours/record-before-long-wait.md`, trigger start).

Journal counts: run `prog-20261028-130241-d8b9d6`, 873 rows, 54 PM prompts to workers. A count is how often the PM restated the rule in a prompt. It is not a violation count; the journal does not record violations as such.

## Worker clauses (advice to a worker)

| # | Rule | Lives in | Move? | Journal signal |
|---|------|----------|-------|----------------|
| W1 | Record before any long background wait: send your claim first | `behaviours/record-before-long-wait.md` (done in slice 1); still copied in `skills/programme-sweep/SKILL.md:383` | Done; delete the SKILL.md copy | restated in 14 of 54 prompts |
| W2 | Never prompt the PM's pane; report with `programme.sh claim ...` | `SKILL.md:384`; `commands/programme-resume.md:104` | Yes (text); the claim command stays code | restated in 21 of 54 |
| W3 | On a denied command, do not rerun, do not try another tool, wrapper or worker | `SKILL.md:386` | Yes | restated in 13 of 54 |
| W4 | Quote the assignment Ruling by id and limits | `SKILL.md:380` | Partly: the lookup stays code, the "quote, do not paraphrase" text moves | not counted |
| W5 | Decision and restriction flags on start-worker and prompt-item | `SKILL.md:361-372` | No: verb behaviour, code | n/a |

Three copies of W2 and W3 exist (SKILL.md, programme-resume.md, the brief a worker gets). One source of truth means all three read the shipped files.

## PM rules in the sweep skill (advice to the PM)

| # | Rule | Lives in | Move? | Journal signal |
|---|------|----------|-------|----------------|
| P1 | Speak in chat only on a new ask, changed facts, a typed prompt, or a fault; otherwise no text | `SKILL.md:68-84` | Yes, needs an `always` trigger | no counter |
| P2 | Tell Shawn about a fault once at start, once at clear | `SKILL.md:82` | Yes, `always` | no counter |
| P3 | Never repeat an ask whose facts did not change | `SKILL.md:78-81` | Partly: `ask-shown` fingerprint is code; the "never end with a Next: line" text moves | no counter |
| P4 | Read nothing over 6,000 characters; use an agent digest | `SKILL.md:24` | Yes, `always` | no counter |
| P5 | Fix a refusal before asking; ask only through pickers | `SKILL.md:37-40` | Yes, `always` | 3 approval_refused rows |
| P6 | Only a checker writes evidence; a worker's "done" is a claim | `SKILL.md:48` | No: code already enforces it | n/a |
| P7 | Only Shawn's typed messages change terms or Rulings | `SKILL.md:49-60` | No: approval verbs enforce it | 3 approval_refused rows |
| P8 | Never use `/goal` | `SKILL.md:47` | Yes, `always` | none |
| P9 | Pin the merge to the reviewed head | `judgment.md` plus verb `check-mergeable --pin` | Text moves with a `before-merge` trigger; pin check stays code | 11 merge_pinned rows, 9 prompts mention it |
| P10 | Do not retry start-worker blindly when it holds an item | `SKILL.md:336` | Yes, `start` or `block` | 1 prompt_refused row |

## `references/` (PM judgment text)

| # | File | Lines | Move? |
|---|------|-------|-------|
| R-1 | `judgment.md` sections 1-10, 12 (re-check requirements, blocker names what it serves, evidence before report, restriction by source, one owner, one escalation per denial, preferred tool is not a permission, follow the job, report format) | 216 | Most of it, one default per section. Needs `always`, `block` and `merge`. This is the largest line saving. |
| R-2 | `judgment.md` section 11 (who decides) | in the 216 | No: the Authority table is code |
| R-3 | `sequencing.md` | 113 | Mixed; read before deciding |
| R-4 | `waits-and-watchers.md` | 72 | Mostly code mechanics (watcher ids); advice lines can move |
| R-5 | `rulings.md`, `behaviours.md`, `domain.md`, `rituals.md` | 54, 95, 44, 31 | No: they describe verbs, not advice |

## Code strings

| # | Rule | Lives in | Move? |
|---|------|----------|-------|
| C1 | Dispatch prompt: "implement and verify ONLY this step" | `lib/dispatch_prompt.py:81`, `:93` | Leave; this is the auto loop, not the programme |
| C2 | Merge gate: MERGEABLE and CLEAN | code | No: code enforced |
| C3 | `defaults.json` evidence rules (flagged-code, fix-only, shared-package, evals-or-docs, product-question, shared-blocker) | `protocol/defaults.json` | Already data, not code. Different mechanism from behaviour files; do not merge the two. |

## Not measured

- Actual violations per rule. The journal logs PM restatements, not worker misses. Real violation counts need transcript review; I can do that for the winning option only.
- Rows in `sequencing.md` and `waits-and-watchers.md` were not classified line by line.

## Triggers the move needs

| Trigger | Needed by | Note |
|---------|-----------|------|
| `before-merge` | P9, merge-time lines of judgment.md | Fires when the PM runs `check-mergeable`. Items. |
| `always` | P1, P2, P4, P5, P8, most of judgment.md | A standing rule with no moment. Costs prompt size if every one loads every sweep. |
| timer | none found | Rituals already cover time and programme events; add nothing here. |

## Options for ordering

**A. Worker clauses first.** One PR: W2, W3 become shipped files, and start briefs, prompt-item text and `programme-resume.md` read them. W1's SKILL.md copy is deleted. No new trigger. Fixes the "one source of truth" gap from slice 1 and frees about 10 lines in the sweep skill. Small, safe, but the cap gain is small.

**B. New triggers first.** Add `before-merge` and `always`, then move P1-P5, P8, P9. Biggest design choice, touches the guard and the due-check. Frees about 40 lines. Larger risk of a prompt-size cost from `always`.

**C. judgment.md first.** One default per section. Largest line saving (about 150 lines) but needs both new triggers and a read-time rule for `always` loading before it works.

## Recommendation

A, then B's `before-merge` trigger with P9, then `always` with judgment.md in a third slice. Reason: A needs no new trigger and closes the slice 1 gap now; `before-merge` is the narrowest new trigger with a real journal signal (11 pins); `always` is the one that can bloat the prompt, so it goes last with a loading rule designed by then.
