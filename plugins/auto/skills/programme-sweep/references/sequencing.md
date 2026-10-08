# Tactical sequencing

A plan's own sequencing section sets the strategic order before work starts.
This file covers the order the PM decides during the work: a bug from a test
environment, a screenshot from Shawn, a review finding or a failed check
arrives, and the PM must decide what goes first, who takes it, and what it
waits for.

Use it at three sweep steps: when new work arrives (step 3 or 5), before you
start or prompt a worker (step 10), and before you merge.

## 1. Rank new work

Rank each new finding before you route it. Work the highest rank first.

| Rank | Kind of work |
| --- | --- |
| 1 | Consent or safety: the product acts without the user's answer, or a change reaches production without a flag |
| 2 | A blocker on the review Shawn is doing now |
| 3 | A blocker on other workers: a shared failure, such as a flag that is off or a broken shared step |
| 4 | A failure that real users hit on a test environment |
| 5 | Wording and polish |

## 2. Route it

1. Find the code the fix touches. Send the work to the worker that owns that code.
2. If two workers touch the same files, name one owner. The other worker waits or stacks on it.
3. If the owner is in the middle of a merge or a review, queue the work behind it. Do not interrupt the merge.
4. If the finding is only a rule for the evals, log it where the programme keeps eval rules. Do not start a fix.

## 3. Find what it waits for

Before you start a worker on new work, answer each question:

- **Upstream code.** Does the fix need a PR that has not merged? Then stack the branch on that PR and build now. Do not wait. Run the runtime proof only after the upstream code is live.
- **Package.** Does it change a shared package? Then the order is: package change, eval run, prerelease, consumer pin on a test environment, stable release, consumer pin on the integration branch.
- **Deploy.** Does a client change need a server change? Then the server merges first, and you confirm the deployed server runs it (read its deployed commit) before the client change merges.
- **Flag.** Does the check need a feature flag? Create the flag when the first PR needs it, not when a worker reports that it is missing.
- **Shared environment.** Does it need a shared test environment? Name the environment, its current holder, what frees it, and who is next. If a scheduled job moves the head of the PR that holds an environment, merge that PR the same day as its review.

## 4. Gate each merge

Before you merge, answer each question. Hold the merge if an answer is wrong.

1. **What does the user see if only this PR lands?** If a sibling PR makes the change correct, hold this PR until the sibling is ready. Or tell Shawn the interim behaviour before you merge.
2. **Is every package pin a stable release?** A prerelease pin is for a test environment or a preview only, when the integration branch ships to production.
3. **Is the upstream change live where this PR runs?** Read the deployed commit. Do not assume.
4. **Is the behaviour behind a flag that is off in production?** Wording needs no flag. If a flag is missing, send the PR back. It is not a question for Shawn.
5. **Did an upstream merge move this PR's base?** Then rebase, and run a focused review on the rebase delta.

## 5. Order Shawn's asks

Send Shawn one list, ordered by deadline and then by how much work each answer unblocks. Put an item with a deadline first. Do not repeat an ask he has already answered.

## Examples from a real programme

From one day of running seven workstreams on one product:

- Rank 1: the assistant answered its own question and started an edit the user never chose.
- Merge gate 1: two PRs made a background job ask "apply this?", which was meant only for jobs open at release time. They merged before the PR that moved new jobs into the user's turn, so every new job asked the user to approve an edit they had just requested.
- Merge gate 2: a server PR merged with a prerelease package pin onto a branch that ships to production. The client repository had a check that blocked the same pin; the server repository did not.
- Flag: three flags were created only after workers reported them missing in the middle of a browser check.
- Shared environment: a daily sync merged the integration branch into the PR that held an environment, which moved its reviewed head the night before the review.

## Not built yet

These gates are guidance today. The firm form is a dependency field on an item
(`P add-item --after <item>`), with `start-worker` and the merge path refusing
when the upstream item has not landed or deployed. Propose it as a rule when a
programme hits the same ordering failure twice.
