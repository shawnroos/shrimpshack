---
description: A human-invoked working session on the retro backlog. Read every open item, cluster by surface, fix or cull, and record the disposition. The run succeeds when the backlog is smaller than it was.
---

You are working the retro backlog down. Not reading it — working it down. Every item in it is tool friction some past session hit, wrote down, and worked around; this is the session where that friction gets fixed, or the tool that caused it gets deleted.

**Not `/reflect`.** `/reflect` is silent automatic hygiene. It runs on its own triggers, never stops you, and its retro job is *capture* — it writes items into the backlog and moves on. This command is invoked by a person, takes attention, and *empties* what `/reflect` filled. See `skills/reflect/SKILL.md`.

**Not `/memories`.** `/memories <topic>` is deliberate study of a subject: retrieve, read, say what applies. It changes nothing on disk except a use log. This command changes tools, files, and dispositions. See `commands/memories.md`. If you want to reason about a topic rather than repair a tool, that is the other command — as is `/reflect-regroup` when a human has stopped you mid-task with no topic named (`commands/reflect-regroup.md`).

**Not a report.** A run that summarises the backlog and stops has failed, however good the summary. The measure is the count of items that left `open`. Zero items closed and no work done is a failed run; zero items closed because you fixed nothing but proved two items already dead and culled them is a good one.

---

## 1. Load the whole open backlog

Point at the store once, then read every open item:

```bash
STORE="${REFLECT_MEMORY_DIR:-$HOME/.claude/projects/-$(printf '%s' "${HOME#/}" | tr / -)/memory}"
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/retro.py" "$STORE"
```

That prints surface, name, and description for every item at `disposition: open`, and the count on stderr.

**The whole backlog, never a recent window.** Staleness is sort order here, never a filter. A "last two weeks" view would hide exactly the item three sessions kept re-deriving — the oldest, most re-hit, most worth fixing item is the first one a recency filter drops, and that failure is why this backlog exists at all. Sort by age to decide reading order:

```bash
python3 -c 'import os, sys
sys.path.insert(0, os.environ["CLAUDE_PLUGIN_ROOT"] + "/scripts")
import retro
rows = retro.list_items(os.environ["STORE"], disposition="open")
for r in sorted(rows, key=lambda r: r["frontmatter"].get("opened", "")):
    fm = r["frontmatter"]
    print(fm.get("opened", "?"), fm.get("surface", "-"), r["name"],
          "|", fm.get("sessions", ""))'
```

`list_items` is the only view of the backlog that exists. Do not read `.retro/` by hand and do not build a second listing — a parallel reader is how the two views drift apart.

Expect **5–20 open items across a handful of surfaces**. The backlog takes on about two new items a week and one queue drain yields 0–4. Hundreds of items means something is wrong with capture, not that you should skim.

## 2. Run the probes first

An item may carry a probe: stored shell that proves the thing is fixed. It runs here and nowhere else — over the whole open backlog, before you read anything. Whatever it proves fixed is already closed by the time you start, so you spend your attention on what is actually still broken.

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/retro.py" probe "$STORE"
```

**A probe runs only after Shawn has approved its text, and approving is his call, not yours.** A probe is shell some earlier session wrote while reading a transcript — including transcripts from repos nobody reviewed. It runs with his full privileges. So for each open item carrying an unapproved probe, print the probe text verbatim, say which item it belongs to, and ask. Record only what he approves:

```bash
PYTHONPATH="${CLAUDE_PLUGIN_ROOT}/scripts" python3 -c \
  "import retro; i = retro.read_item(STORE, NAME); \
   retro.record_probe_approval(STORE, NAME, retro.probe_hash(i['probe']))"
```

The hash pins the bytes he saw. Edit the probe afterwards and it is unapproved again, which is the point.

**What the runner proves, and what it does not.** A probe closes its item only by printing a line equal to `RETRO-FIXED` plus a nonce minted for that one execution — never by exiting zero, which proves nothing here (`timeout` does not exist on this machine and fails while the shell reports success; `cp`, `mv` and `rm` are aliased interactive and no-op at exit zero). The nonce stops a *stale* proof and stops forwarded tool output from forging one, because it cannot appear in anything written before the run.

It does **not** make the probe honest. The probe holds the nonce in its own environment, so any approved probe can close its item with a bare `echo`. The thing standing between a wrong probe and a falsely-closed item is the approval above — his eyes on the text. Treat the nonce as replay protection, not as proof.

An item with no probe is never auto-closed. It waits for step 4.

If the backlog looks thin and the queue has not been vented recently, run `/reflect` first — that is the pass that turns queued session material into items. Do not drain the queue from here; a drain outside the vent pass discards the candidates it hands back.

## 3. Cluster by surface

Every item declares a surface: `plugin`, `skill`, `harness`, or `codebase`. Group them and read the groups, not the list.

The point is not tidiness. Five items on one skill are usually not five bugs — they are one wrong design generating five symptoms, and you only see that with the five side by side. Fixing them one at a time gets you five patches and a sixth symptom next month.

Name the clusters out loud before you act. A cluster of one is a normal result; say so and move on.

## 4. Pick and act

Take one cluster. Choose the outcome the evidence supports:

- **Fix it.** Change the tool. Then prove it — run the thing that failed and show it working.
- **Cull it.** Delete the tool. See below.
- **Won't fix.** The friction is real and you are choosing to live with it. This is a decision with a reason, not a place to park items you did not get to. An item you simply did not reach stays `open`.

**Culling is a first-class outcome.** Concluding "delete this skill" is a normal end to a cluster, not an admission that you failed to fix something. A tool that has generated friction across three sessions and saved nobody anything is a cost with no benefit, and removing it closes every item pointing at it.

Worked example. Three open items name the surface `skill` and the thing `slate-editor-warmup`: sessions 4a1, 9c2, and 11e each recorded that the skill's preflight hangs and they killed it and worked without it. Nothing in any of the three sessions used its output. The fix is not making the preflight faster — nobody wants the output. You delete the skill directory, run the harness to confirm nothing referenced it, and move all three items to `culled` with that as the proof.

`culled` means the tool was deleted. It is not memory retirement, which means a memory was *wrong*. Do not use one word for the other; the glossary keeps them apart on purpose.

## 5. Record the disposition

An item leaves `open` only with a proof naming what closed it. `set_disposition` refuses an empty proof, so there is no path where an item quietly closes on nothing:

```bash
ITEM=skill-slate-editor-warmup-hangs \
DISP=culled \
PROOF='deleted plugins/slate-editor/skills/warmup; harness green with no references' \
python3 -c 'import os, sys
sys.path.insert(0, os.environ["CLAUDE_PLUGIN_ROOT"] + "/scripts")
import retro
print(retro.set_disposition(os.environ["STORE"], os.environ["ITEM"],
                            os.environ["DISP"], os.environ["PROOF"]))'
```

`DISP` is one of `fixed`, `culled`, `wontfix`. The proof is what a later reader needs to tell whether the close was real — name the command you ran, the file you deleted, or the decision you took. "Fixed" is not a proof.

If you touched an item without closing it — reproduced it, narrowed it, learned something — leave it `open` and record that this session hit it:

```bash
ITEM=plugin-spawn-status-stale python3 -c 'import os, sys
sys.path.insert(0, os.environ["CLAUDE_PLUGIN_ROOT"] + "/scripts")
import retro
retro.append_session(os.environ["STORE"], os.environ["ITEM"],
                     os.environ.get("CLAUDE_SESSION_ID") or "unknown")'
```

The session list is how an item's real cost becomes visible. An item on its fifth session is arguing for a cull.

## 6. Report what shrank

One line per item that left the backlog, plus the count. Not a tour of what you read:

```
Retro — 14 open, 4 closed, 10 remain.
  • skill-slate-editor-warmup-hangs      culled  (skill deleted; nothing referenced it)
  • skill-warmup-preflight-timeout       culled  (same skill)
  • skill-warmup-output-unused           culled  (same skill)
  • harness-retro-test-needs-chrome-bin  fixed   (harness exports CHROME_BIN; suite green)
Untouched: 10 open, oldest 2026-06-02 (plugin-spawn-status-stale, 5 sessions).
```

Name the oldest untouched item every time. It is the one a recency filter would have hidden, and printing it is what stops the backlog growing a permanent tail.

A run that closes nothing is a valid outcome only when you can say what you did instead — "reproduced two, neither fix is small, both stay open with today's session appended." Say that plainly. Do not dress it up as progress.
