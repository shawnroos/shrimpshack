# Tactical sequencing

A plan's own sequencing section sets the strategic order before work starts.
This file covers the order the PM decides during the work: a bug from a test
environment, a screenshot from Shawn, a review finding or a failed check
arrives, and the PM must decide what goes first, who takes it, and what it
waits for. Plans cannot foresee these, so the order is decided sweep by sweep.

Where the sweep uses it:

| Sweep step | Sections |
| --- | --- |
| 3 (Shawn's answers) and 5 (read the remit): new work arrives | 1 and 2 |
| 10 (drive workers): before you start or prompt a worker | 3 |
| 8 (check claims): a worker claims `merged`; also before any merge the PM does itself | 4 |
| 12 (hand product calls) | 5 |

## 1. Rank new work

Rank each new finding before you route it, and work the highest rank first. A
lower-ranked item can wait a sweep; a higher one usually cannot, because it
either harms users or stalls other work.

| Rank | Kind of work | Why it ranks here |
| --- | --- | --- |
| 1 | Consent or safety: the product acts without the user's answer, or a change reaches production without a flag | It harms users or production, and every hour adds exposure |
| 2 | A blocker on the review Shawn is doing now | Shawn's review time is the scarcest resource in the programme |
| 3 | A blocker on other workers: a shared failure, such as a flag that is off or a broken shared step | One fix unblocks several items |
| 4 | A failure that real users hit on a test environment | Real use finds what tests miss, but it is not production |
| 5 | Wording and polish | It is safe to batch |

## 2. Route it

1. Find the code the fix touches, and send the work to the worker that owns that code (`P prompt-item`). The owner already holds the context, and a second worker in the same files makes conflicts.
2. If two workers touch the same files, name one owner with `P add-item <item> --pane <pane> --session <session>`. The other worker waits for it or stacks on it.
3. If the owner is in the middle of a merge or a review, add the work to the queue (`P queue --action <name> --item <item>`) instead of prompting now. An interrupted merge leaves a half-reviewed head.
4. If the finding is a rule rather than a defect (for example, "never claim a result the user did not see"), record it with `P record-instruction` and do not start a fix for it now.

## 3. Find what it waits for

Before you start a worker on new work, answer each question. Record every wait
with `P set-waiting`, with a watcher or a named reporter, so the stop rule can
see it.

- **Upstream code.** Does the fix need a PR that has not merged? Stack the branch on that PR and build now. Waiting wastes the worker's time, and a stacked branch rebases cheaply. Run the runtime proof only after the upstream code is live, because before that the proof tests the wrong code.
- **Package.** Does it change a shared package? The order is: package change, eval run, prerelease, consumer pin on a test environment, stable release, consumer pin on the integration branch. Each step proves the one before it, and an integration branch that ships to production must not depend on an untested build.
- **Deploy.** Does a client change need a server change? The server merges first. Read the deployed server's commit before the client change merges. A merged change is not a deployed change, and a client that runs ahead of its server fails for every user.
- **Flag.** Does the check need a feature flag? Create the flag when the first PR needs it. A worker that finds a flag missing in the middle of a browser check loses the run.
- **Shared environment.** Does it need a shared test environment? Name the environment, its current holder, what frees it, and who is next. If a scheduled job moves the head of the PR that holds an environment, merge that PR on the day of its review, or the reviewed head is gone.

## 4. Gate each merge

Run these checks before the PM merges, and again at step 8 when a worker claims
`merged` (a merge already done is checked, and any failed answer becomes rank 1
or 2 work). Hold the merge if any answer is no or unknown.

1. **What does the user see if only this PR lands?** Each PR passes its own checks, but users see the sum. If a sibling PR makes this change correct, hold this PR until the sibling is ready, or tell Shawn the interim behaviour before you merge.
2. **Is every package pin a stable release?** A prerelease pin belongs on a test environment or a preview, never on a branch that ships to production.
3. **Is the upstream change live where this PR runs?** Read the deployed commit; do not assume it.
4. **Is the behaviour behind a flag that is off in production?** The `flagged` check reads this. Wording needs no flag. If a flag is missing, send the PR back to its worker. It is a blocker, not a question for Shawn.
5. **Did an upstream merge move this PR's base?** Then rebase, and review the rebase delta. A clean rebase can still combine two changes badly.

## 5. Order Shawn's asks

Shawn gets each handed item once (`P hand-item` notifies once). When several
are open, put them to him as one list: an item with a deadline first, then by
how much work each answer unblocks. Do not ask again about an item he has
answered; a repeated ask costs his attention and teaches him to skip the list.

## Examples from a real programme

From one day of running seven workstreams on one product:

- Rank 1: the assistant answered its own question and started an edit the user never chose.
- Merge gate 1: two PRs made a background job ask "apply this?", which was meant only for jobs open at release time. They merged before the PR that moved new jobs into the user's turn, so every new job asked the user to approve an edit they had just requested.
- Merge gate 2: a server PR merged with a prerelease package pin onto a branch that ships to production. The client repository had a check that blocked the same pin; the server repository did not.
- Flag: three flags were created only after workers reported them missing in the middle of a browser check.
- Shared environment: a daily sync merged the integration branch into the PR that held an environment, which moved its reviewed head the night before the review.

## Not built yet

These gates are guidance today. The firm form is a dependency field on an item
(`P add-item --after <item>`), with `start-worker` and the merge check refusing
when the upstream item has not landed or deployed. Propose it with
`P propose-rule` when a programme hits the same ordering failure twice.
