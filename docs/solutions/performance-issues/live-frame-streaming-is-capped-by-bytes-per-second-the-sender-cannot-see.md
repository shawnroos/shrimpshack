---
title: "Live frame streaming into a mod pane is capped by bytes per second, and the sender cannot see the cap"
date: 2026-10-09
module: plugins/peek
problem_type: performance_issue
component: tooling
severity: medium
category: performance-issues
symptoms:
  - "a 60-frame burst showed about 10,000 blits/s with 0 denied for png and file sources but 22-30 of 38 shm blits denied, so the burst measured handoff, not drawing"
  - "full-pane PNG frames looked choppy at 470 KB x 5/s and 119 KB x 30/s and smooth at 119 KB x 10/s, while the sender logged 0 late and 0 denied"
  - "a static page froze on an old picture because $.ui.blit resolves with a deny field instead of rejecting, and the caller only caught rejections"
  - "the helper's 1 s frame prune deleted the frame file the pane was showing, and a redraw re-reads file sources by path"
root_cause: wrong_api
resolution_type: code_fix
tags: [peek, live-view, blit, throughput, byte-budget, herdr, ghostty, frame-pruning]
---

# Live frame streaming into a mod pane is capped by bytes per second, and the sender cannot see the cap

## Problem

Peek's live view streams frames of a WebKit page, rendered by a Swift helper, into a Claude Code mod pane. Each frame swaps a keyed `Image` with `$.ui.blit`. The first stream was choppy, and on a page that stopped changing the pane could freeze on an old picture or lose its picture. Three separate causes sat behind this:

1. The pane path has a bytes-per-second ceiling that the sender cannot see.
2. A refused blit resolves with `{ deny }` and does not reject, so `.catch`-only code dropped frames silently.
3. The helper deleted the frame file the pane was still showing.

## Symptoms

- Full-pane frames looked choppy even though the sender logged 0 late and 0 denied blits.
- A burst test reported about 10,000 blits/s for `png` and `file` sources with 0 denied, but only 38 `shm` blits with 22-30 denied ("the surface has not written its last frames (paused or busy)"). This session measured those numbers.
- On a static page the pane kept an old frame after a refused blit.
- On a static page a redraw could lose the shown frame, because its file was gone.

## What Didn't Work

- **Reading blit throughput as draw throughput.** The burst numbers measured handoff to the engine, not drawing. The engine types say so: the surface writes Images "some sixty a second: byte and `file` sources fold to the last per frame; every `shm` source reaches the terminal (it unlinks each), and is denied while frames are not written" (`plugins/peek/.claude-plugin/types/claude-code/index.d.ts:5237-5247`, the `ImageBlitArgs` doc). The `$.ui.blit` doc adds "blits between frames fold into one: up to 120 a second taken, some sixty shown" (same file, `:2352-2357`). So 10,000/s for `file` means most blits were folded away, and `shm` denials are flow control, not a fault. The plan records the same reading (`docs/plans/2026-10-09-1605-feat-peek-live-browser-plan.md:114`, KTD5).
- **Trusting the sender's log.** Every blit was sent on time and none was refused, yet the stream was choppy. No API acknowledges a draw, so the ceiling sits after peek, where the sender cannot observe it (plan `:227`, U1 results).
- **Raising the frame rate or switching to raw frames.** This session judged by eye, over 10 s streams under herdr and Ghostty:

  | Frame | Rate | Throughput | Result |
  |---|---|---|---|
  | 470 KB PNG | 5/s | ~2.4 MB/s | choppy |
  | 470 KB PNG | 10/s | ~4.7 MB/s | choppy |
  | 119 KB PNG | 10/s | ~1.2 MB/s | smooth |
  | 119 KB PNG | 30/s | ~3.6 MB/s | choppy |
  | 2.9 MB raw rgb | 30/s | ~87 MB/s | choppy |

  Frame size times rate decides smoothness; frame rate alone does not. The plan's KTD7 (plan `:116`) and U1 results (plan `:227`) record the PNG rows; the raw-rgb row is from this session only.
- **Rendering large and shrinking.** A 1200x800 Hacker News PNG at 1x was 548 KB (plan `:227`). At that size even 5/s is over budget.

## Solution

### 1. A byte budget in the helper

The helper tracks bytes sent over the last second and holds any frame that would push past about 1 MB (`plugins/peek/helper/peek-web.swift:272-273`, `byteBudget = 1_000_000`; `overBudget` at `:528-531`). The check runs twice: before a snapshot, against the last frame's size (`:555`), and after encode, against the real size (`:582-587`). A held frame keeps `dirty = true`, so it is retried.

When frames keep waiting, the helper steps down a quality ladder, rate first and then scale (`:270-271`):

```swift
let qualityLevels: [(rate: Double, scale: CGFloat)] = [(30, 1), (15, 1), (10, 1), (5, 1), (5, 0.75), (5, 0.5)]
```

Three waited frames in a row step down one level (`:600-605`). After 3 s without a wait, it steps back up one level (`:553`). Walking the list backwards means scale recovers before rate.

Two more rules cut bytes:

- **Send only on change.** The tick returns unless the page set `dirty` (`:554`). Navigation, resize and the injected change-report script set it (`:412`, `:422`, `:178`).
- **Skip identical frames.** `if png == lastSentPng { return }` (`:580`) drops a byte-identical frame before it is written.

### 2. Lay the page out small instead of shrinking a big render

Peek sizes the WebKit viewport from the pane's cell box at 8 CSS px per column, clamped to 320-900 px wide (`plugins/peek/hooks/register.tsx:855`, `:991-994`):

```ts
const width = Math.round(Math.max(320, Math.min(900, columns * LIVE_PX_PER_COLUMN)))
return { width, height: Math.round((width * rows * CELL_ASPECT) / columns) }
```

The helper snapshots at 1x pixels, dividing out the backing scale (`peek-web.swift:561-562`). The page lays out like a narrow window, so text keeps its normal size, and each frame is small. The plan states the start point as about 600x400 (plan `:116`).

### 3. Read the blit result, and redraw on deny

`UiBlitResult` is `{ deny?: string }`; `deny` is set when the Image is not mounted, the size differs, or the source is bad (`index.d.ts:13563-13573`). A refused blit resolves; it does not reject.

Before (the failure shape):

```ts
void $.ui.blit({ ... }).catch(() => $.ui.invalidate('ui.render'))
```

After (`register.tsx:897-903`, in `onLiveChange`):

```ts
void $.ui.blit({ requestId: PANE, key: LIVE_FRAME, source: { file: path, format: 'png', generation: id } }).then(
  result => {
    if (result.deny) $.ui.invalidate('ui.render')
  },
  () => $.ui.invalidate('ui.render'),
)
```

The invalidate makes the render hook draw the newest frame, so a refused blit costs one redraw, not a stuck picture.

### 4. Never delete the newest frame file

The helper prunes frame files older than 1 s, because the terminal reads each file after the blit returns. The first version pruned every old file. On a static page no new frame arrives, so it deleted the frame on screen, and a later redraw re-reads `file` sources by path. The fix keeps at least one file (`peek-web.swift:548-551`):

```swift
// The newest frame is what the pane shows; a redraw may read it again however old it is.
while frames.count > 1, let oldest = frames.first, now - oldest.at > 1 {
```

### Verification (run by hand this session)

- `claude plugin test`: 304 pass.
- Helper smoke tests: on a static page, the newest frame file is still on disk after a quiet period; paused, 0 frames; on resume, 1 frame.

## Why This Works

- The ceiling is bytes per second through Claude Code, herdr and the terminal, somewhere between about 1.2 MB/s (smooth) and 2.4 MB/s (choppy) by this session's measurement. The helper source records it as "the terminal pane path chokes above ~1.2 MB/s" (`peek-web.swift:272`). A budget measured in bytes addresses that limit directly. Rate and scale are only levers to stay under it.
- The sender gets no draw acknowledgement, so it cannot react to the choke. The budget has to be set ahead of time from a measurement, and enforced at the source.
- Small layout beats downscaling because PNG size tracks pixel count. A narrow viewport at 1x gives fewer pixels with readable text. A shrunk large render gives the same pixel count with unreadable text.
- `file` sources fold to the last per frame, so a burst of blits never queues up in the terminal. That makes `file` safe to send on every change, and the budget only has to bound bytes, not count blits.
- Engine calls in this API resolve with `{ deny }` for refusals. The `.catch` branch only sees real errors. Handling both paths with the same invalidate keeps the pane in sync.
- A `file` source is a reference, not a copy. Whatever the pane currently shows must stay on disk until a newer frame replaces it.

## Prevention

- **Measure drawing, not handoff.** A blit count says how fast the engine accepted work. For a stream, judge a sustained run (10 s or more) at real frame size, by eye or on the terminal side. Read the `ImageBlitArgs` doc before trusting any burst number.
- **Budget in bytes per second for any image stream into a pane.** Start from about 1 MB/s under herdr and Ghostty. Plain Ghostty outside herdr is not yet checked (plan `:114`).
- **Treat every engine `Promise` that can return `{ deny }` as two outcomes.** Check `result.deny` in the success branch. A `.catch` alone drops refusals silently.
- **Keep the referenced resource alive.** Any cleanup of files that a `file` source points at must keep the newest one, regardless of age.
- **Test the static case.** A static page exposes both freeze bugs: no new frame arrives to mask a dropped blit or a deleted file. This session checked the second one by hand (newest frame still on disk after a quiet period); no repeatable script exists yet.
