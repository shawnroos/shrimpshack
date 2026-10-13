---
title: "A timer test must wait for the work the mock clock cannot see"
date: 2026-10-13
module: plugins/peek
problem_type: test_failure
component: testing_framework
severity: medium
category: test-failures
symptoms:
  - "three timer tests in plugins/peek/tests/recipe-pane.test.ts failed intermittently: full suite 2 green / 13 red with 3 suites run at once, recipe-pane alone 9/16 green before the fix and 16/16 after"
  - "the tests read the recipe run count before the timed run had finished, and only under load"
  - "making the tick return its promise (tickRemote awaiting tickPage) still raced"
root_cause: async_timing
resolution_type: test_fix
related_components:
  - tooling
tags: [peek, flaky-test, mock-clock, settle, crypto-subtle, fire-and-forget, wait-for-effect]
---

# A timer test must wait for the work the mock clock cannot see

## Problem

Three timer tests in `plugins/peek/tests/recipe-pane.test.ts` failed at random:

- "an opted-in recipe page re-runs after its minutes on screen, and the ticker starts though it is the first page of the session"
- "a failing timed run keeps the last page with its failure marker and backs off before the next try"
- "after ten idle minutes timed runs pause, and the next activity resumes them"

Each test advances the mock clock past a recipe's `refreshMinutes` and then counts how many times the recipe script ran. The count was sometimes one run short. The production code was correct. The test read the count before the timed run had reached its script.

## Symptoms

- Failure message: `Expected [FIGMA, FIGMA] Received [FIGMA]`. The timed re-run had not happened yet when the test checked.
- The failure depended on load. Three full suites run in parallel gave 2 green runs and 13 red. `recipe-pane.test.ts` run on its own passed 9 of 16 times.
- More `settle()` calls did not help. After a 4.5-minute `clock.advance`, up to 30 `settle()` calls still left the count at 1.

## What Didn't Work

- **Calling `settle()` more times.** As above, 30 calls after the advance still left the count at 1. The pending work is invisible to `settle()`, so repeating it changes nothing.
- **Making the tick return its promise.** The tick was changed to return a promise, and `tickRemote` awaited a `tickPage` that it started at the same time as its other work. The tests were still red 3 of 6 times. The test helpers still could not see the hashing (next section), so they had no promise to wait on. Also, `$.clock.every` starts the callback and does not wait for it (`plugins/peek/hooks/register.tsx:632`).

## Solution

Root cause: a timed run does work that the test harness cannot see.

1. The 15-second ticker starts the tick and does not wait for it: `$.clock.every(15_000, () => void tickRemote($).catch(() => undefined))` (`plugins/peek/hooks/register.tsx:632`).
2. `tickRemote` also starts `tickPage` without waiting for it: `void tickPage($).catch(() => undefined)` (`plugins/peek/hooks/register.tsx:2049`).
3. `tickPage` calls `refreshPage` (`register.tsx:2042`). `refreshPage` writes `isRefreshing: true` (`register.tsx:822`), then calls `loadPage` (`register.tsx:823`). `loadPage` (`register.tsx:765`) calls `loadRecipes` (`register.tsx:773`) before the run starts.
4. `loadRecipes` and `loadRecipe` hash every file in the recipe folder and then the whole manifest with `crypto.subtle.digest` (`plugins/peek/hooks/recipes.ts:45-46`, `:90`, `:134`). `runRecipe` loads the recipe again before and after the script to compare digests (`plugins/peek/hooks/recipe-run.ts:171`, `:179-180`). So one timed run hashes the folder more than once.

`crypto.subtle.digest` resolves outside the engine's event loop and is not a `$` call. Per this session's diagnosis, the pane test world's `clock.advance()` and `settle()` helpers (from `claude-code/testing`) wait only for `$` calls and event-loop turns; the engine types do not document this, so treat it as observed behaviour rather than a contract. They return while the run is still hashing, and the script runs later. When the CPU is busy, "later" comes after the test's `expect`.

The diagnostic confirmed this. A hash stand-in that returned synchronously (diagnostic only, not committed) made the count reach 2 at once, and the tests passed 6 of 6 times.

The fix changes only the test. Production keeps the non-blocking tick. In `paneWorld`, the test adds a pass-through `state.set` hook. The hook calls `next(e)` and counts each time the `view` page goes from `isRefreshing: true` to not refreshing. That change comes from the last write `refreshPage` makes, on success (`register.tsx:828`) and on failure (`register.tsx:838`). `pane.refreshesDone(n)` resolves when the count reaches `n` (`plugins/peek/tests/recipe-pane.test.ts:100`, `:128-140`).

Before (each test read the count right after advancing the clock):

```ts
await stayActive(driver, pane, 2)
expect(pane.scripts()).toEqual([FIGMA, FIGMA])
```

After (`recipe-pane.test.ts:654-656`):

```ts
await stayActive(driver, pane, 2)
await pane.refreshesDone(1)
expect(pane.scripts()).toEqual([FIGMA, FIGMA])
```

The signal in `paneWorld` (`recipe-pane.test.ts:128-140`):

```ts
on('state.set', async (_$, e, next) => {
  const answered = await next(e)
  const write = e as { key?: string; value?: { page?: { isRefreshing?: boolean } } | null }
  if (write.key === 'view') {
    const isNowRefreshing = write.value?.page?.isRefreshing === true
    if (isRefreshing && !isNowRefreshing) refreshes += 1
    isRefreshing = isNowRefreshing
    for (const one of waiters.filter(waiter => refreshes >= waiter.count)) {
      waiters.splice(waiters.indexOf(one), 1)
      one.resolve()
    }
  }
  return answered
})
```

The three tests wait on `refreshesDone` before each check that expects a run to have happened (`recipe-pane.test.ts:655`, `:687`, `:698`, `:710`, `:715`).

Results after the fix, measured in this session: `recipe-pane.test.ts` alone passed 16 of 16 times. The full suite run one at a time passed 15 of 15 times. This is on branch `feature/peek-view-builder`, commit "test(peek): make recipe timer runs settle before the test reads them". No PR existed for the branch as of 2026-10-13.

Caveat: a check that expects *no* run still reads the count with nothing to wait on. One example is the 15-minute idle advance at `recipe-pane.test.ts:712-713`. A late run would not fail that check. The next exact-count check after a `refreshesDone(n)` wait would fail instead, because it would see one run too many.

Mutation checks show that the tests can still fail:

| Mutation | Result |
|---|---|
| Remove `startTicking` from the load path | All three tests red: `refreshesDone` never resolves, so each test hits the runner's 5 s timeout |
| Remove the back-off in `tickPage` (`register.tsx:2043-2044`) | Failing-run test red |
| Run `tickPage` before the idle check in `tickRemote` (`register.tsx:2048`) | Idle test red |

## Why This Works

The wait now depends on an event that the run itself causes, not on time passing. `refreshPage` always ends with a write that clears `isRefreshing`, whether the run succeeds or fails. That write happens after all of the hashing and after the script. When `refreshesDone(n)` resolves, the run has finished, and the test does not need to know how long hashing takes. The hook calls `next(e)` and returns its answer, so the real state write still happens.

## Prevention

- Do not trust `clock.advance()` or `settle()` to cover work that resolves outside the engine, such as `crypto.subtle`, `fetch`, timers outside `$.clock`, or native promises from host APIs. In this session they returned before such work finished.
- When production code starts work with `void promise`, a test needs a signal the work emits when it ends. A `$` write that marks the end is a good signal. Wait for that signal. Do not add more `settle()` calls.
- `refreshesDone` has no timeout of its own. A missing signal fails only through the test runner's timeout (5 s here). Keep that timeout short so a broken signal fails fast.
- Before you call a test flaky or fixed, measure it. Run it N times on its own and under parallel load, and report the ratio. This failure only appeared under CPU load.
- A check that expects nothing to happen cannot wait on a signal. Follow it with an exact-count check after a later wait, so a late run still fails the test.

## Related

- [A test can pass because it cannot fail](../logic-errors/a-test-can-pass-because-it-cannot-fail.md): the mutation checks above follow it.
- [A tally keyed on exit status reports work that never happened](../logic-errors/a-tally-keyed-on-exit-status-reports-work-that-never-happened.md): wait on the effect, not a proxy for it.
- [A lock a stalled writer can lose must be re-checked before the commit](../logic-errors/a-lock-a-stalled-writer-can-lose-must-be-rechecked-before-the-commit.md): same plugin; a test double that does not behave like the real primitive hides the bug.
