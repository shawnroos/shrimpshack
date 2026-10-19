---
title: A staleness display computed at write time cannot show a stalled writer
date: 2026-10-19
category: logic-errors
module: plugins/auto
problem_type: logic_error
component: tooling
symptoms:
  - "The programme band and pane showed every item at '5s' old and kept showing '5s' while minutes went by"
  - An item whose PM had stalled never faded
  - All unit tests passed, because each test fed the mod a view that already held the writer's age
root_cause: logic_error
resolution_type: code_fix
severity: high
tags: [staleness, time-relative-state, compute-at-reader, stalled-writer, programme-view, mods, auto-plugin, polling]
---

# A staleness display computed at write time cannot show a stalled writer

## Problem

The programme view shows how old each work item's trajectory is, and fades it once it is old. It worked out that age when it built `view.json`. The view is rebuilt only when the PM writes to the programme, so the age stopped moving whenever the PM stopped writing. A stalled PM is the one case the display exists to show.

## Symptoms

- In a live Claude Code session, the work band and the programme pane showed every item at "5s" old and kept showing "5s" while minutes went by.
- An item whose PM had stalled never faded. Its `faded` flag stayed at whatever it was on the last write.
- All unit tests passed.

## What Didn't Work

The approach that failed was working out age at build time. In `plugins/auto/lib/programme_view_work.py`, `_work_entry` takes `ctx["now"]` at build time and writes `age_seconds` and `faded` into each work entry. The mod drew those two values exactly as written.

The tests could not catch this, because each test fed the mod a fixed `view.json` that already held the writer's answer (for example `workEntry(..., { age_seconds: 2400, faded: true })` in `tree.test.ts`). Those tests checked that the mod draws what it is given. No test let time pass without a write, so nothing compared the drawn age with the clock. The defect showed up only in a real session, where the clock kept running and the file did not change.

## Solution

The fix is the commit "fix(auto): age stale work from the clock and tidy the contract view" on branch `feature/programme-sessions-contract` (no PR opened and not on `main` as of this writing; find the PR that lands that branch for the merged form).

1. The mod works out age and fade when it draws, from the stored `recorded_at` and `fade_after_seconds`, using `$.clock.now()`. This is `age` in `plugins/auto/mods/programme-view/view.ts`:

```ts
function age(entry: Raw, nowMs: number): { age_seconds: number | null; faded: boolean } {
  const stored = { age_seconds: typeof entry.age_seconds === 'number' ? entry.age_seconds : null, faded: entry.faded === true }
  const at = typeof entry.recorded_at === 'string' ? Date.parse(entry.recorded_at) : Number.NaN
  if (Number.isNaN(at)) return stored
  const seconds = Math.max(0, Math.floor((nowMs - at) / 1000))
  const after = typeof entry.fade_after_seconds === 'number' ? entry.fade_after_seconds : undefined
  return { age_seconds: seconds, faded: after === undefined ? stored.faded : seconds > after }
}
```

2. The band and the pane read the view through one function, `loadView` in the same file. It parses `work` once with `readWork(view.work, await $.clock.now())`, which applies `age` to every entry, so neither surface can show a write-time age. (The first version of the fix applied the same step twice, once in each surface's own reader; a later refactor merged the readers.)

3. The 2-second poll now also redraws the pane when the wall-clock minute changes, not only when the file changes:

```diff
+    let lastMinute = Math.floor((await $.clock.now()) / 60_000)
     $.clock.every(POLL_MS, async () => {
       const current = await stamp($).catch(() => lastStamp)
-      if (current !== lastStamp) {
+      const minute = Math.floor((await $.clock.now()) / 60_000)
+      if (current !== lastStamp || minute !== lastMinute) {
         lastStamp = current
+        lastMinute = minute
         await $.ui.invalidate('ui.render')
       }
     })
```

The writer did not change. `_work_entry` still writes `recorded_at`, `fade_after_seconds`, and a build-time `age_seconds` and `faded`. The mod overwrites the last two whenever `recorded_at` parses. If `fade_after_seconds` is missing, `age` keeps the writer's `faded`. If `recorded_at` is missing or does not parse, it keeps the writer's values unchanged.

Two tests in `plugins/auto/mods/programme-view/tree.test.ts` cover the fix. The shared test world (`plugins/auto/mods/programme-view/test-world.ts`) pins the mock clock to `2026-10-19T10:00:00Z` and returns the clock:

- "age and fade follow the clock, not the view build: a stalled PM still fades". The view says `age_seconds: 5, faded: false`, but `recorded_at` is 40 minutes before the clock. The test expects "40m" and a faded title.
- "the pane redraws as a minute passes with no view change". The test draws "1m", calls `clock.advance(61_000)` without touching the view file, and expects "2m".

## Why This Works

Age is a function of two values: when something happened, and the time now. The writer knows only the first, and only at the moment it writes. The reader knows both every time it draws. When the reader computes age from a stored timestamp, the result is correct no matter when the file was last written.

The minute check covers the second half of the problem. A correct formula has no effect if nothing redraws, and a change-only poll never redraws while the writer is silent, which is exactly the case being displayed.

## Prevention

- **Compute time-relative state at the reader, from a stored timestamp. Never compute it at the writer.** This covers age, "N minutes ago", overdue or faded flags, countdowns, and expiry. The writer stores the event time and any threshold (here `recorded_at` and `fade_after_seconds`). The reader derives age and status from those values and its own clock. A derived value the writer stores is a snapshot that goes out of date between writes.
- **Give the reader a redraw trigger based on time, not only one based on change.** If the display depends on the clock, the passage of time is an input. Redraw at the coarsest step the display can show, which here is one minute.
- **Be most careful when the display reports writer health.** Freshness indicators, heartbeats, and "last seen" values exist to show that the writer stopped. If the writer computes them, they stop changing at the moment they matter.
- **Test shape.** Pin a mock clock. Write the fixture once with a stored timestamp, and give the derived fields wrong values on purpose (such as `age_seconds: 5`). Assert that the drawn output follows the clock. Then advance the clock past a display step without writing, and assert that the output changes. A fixture that already holds the correct derived values tests only that the reader copies them.
- **Known gap.** The plain-text fallback rows still use the build-time age. `work_texts` in `programme_view_work.py` writes "Nm old" into `rows`, and the mod draws `rows` only when `parts` is missing. Any surface that reads `rows` directly still freezes the same way.

## Related Issues

- [A file lock a stalled writer can lose must be re-checked right before the commit](a-lock-a-stalled-writer-can-lose-must-be-rechecked-before-the-commit.md): the same stalled-writer case, handled at the writer; this doc handles it at the reader.
- [Live frame streaming into a mod pane is capped by bytes per second, and the sender cannot see the cap](../performance-issues/live-frame-streaming-is-capped-by-bytes-per-second-the-sender-cannot-see.md): another mod view that froze because it redrew only on new writes.
- [Which keys a mod's band above the prompt can receive](../architecture-patterns/claude-code-mod-band-key-routing.md): keyboard routing for the same band; not about time.
