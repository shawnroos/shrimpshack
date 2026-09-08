---
argument-hint: "<topic>"
allowed-tools: Bash, Read, Edit
description: Deliberate memory work on a named topic — retrieve broadly from the memory store, read the bodies, say what applies, act on it, and record the use honestly.
---

Work through what the memory store knows about **$ARGUMENTS**, then act on it.

This is the deliberate path: a human named a topic and asked for it, so search wide
and let marginal hits through — the cost of a near-miss here is one line you read and
discard, not a wrong memory injected unbidden.

**Not the same command as `/reflect-regroup`.** `/memories <topic>` takes a topic,
is about a *subject*, and stops nothing — you keep doing what you were doing.
`/reflect-regroup` takes no argument, is invoked by a human who has seen you go wrong,
and its first instruction is to **stop** and ground yourself in what you are doing
right now. Name the topic → this command. Interrupted mid-task with no topic named →
`/reflect-regroup`.

**Not the same command as `/reflect-retro`.** `/memories <topic>` reads the memory
store and changes what you *think*. `/reflect-retro` reads the retro backlog and
changes the *tools* — it fixes or deletes what caused the friction and records a
disposition, and it has failed if the backlog is the same size afterwards. Studying a
subject → this command. Working the friction backlog down → `commands/reflect-retro.md`.

## 1. Retrieve

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/scoped-memory/reflect_cli.py" recall --deliberate --query "$ARGUMENTS"
```

That is one call and it runs the whole layered path itself: declared triggers first,
then `qmd vsearch`, then the local BM25 index if qmd was skipped, wedged, or empty.
`--deliberate` widens K and relaxes the local confidence gate — the relaxation exists
precisely because a human asked. It always prints a final status line naming which
layer answered; read that line, it is how you know whether qmd was even consulted.

Add `--here` when the topic is about *this repo* — it drops sibling repos' memories
and keeps this repo's plus the global ones. Add `--store <dir>` only to point at a
non-default store. Exit code is 0 even when nothing matched (recall must not fail a
caller's pipeline), so read the output, never the exit code.

If it says **no confident match**, try one differently-phrased query before concluding
nothing is there — the status line tells you which layer was doing the matching, and a
BM25 layer misses on vocabulary the store words differently.

## 2. Read

The command returns **bodies**, not titles — read them. For memories that are clearly
relevant but came back cold or truncated, follow the pointer in `MEMORY.md`
(`- [Title](file.md)`) and read the file directly from the memory dir.

## 3. State what applies, and act

Say plainly which memories apply to the work at hand and what each one changes about
what you are about to do. A memory you read and did not use is worth one line saying
so. Then act on the ones that apply — the point of the command is the changed action,
not the reading.

"Nothing in the store covers this" is a valid, useful answer. State it; don't pad.

## 4. Record the use honestly

For each memory you **genuinely applied** (not merely read):

- append one line to `MEMORY_USE.log` in the memory dir:
  `<timestamp> <memory-name> applied [session:<id>] [note]` — use `[session:unknown]`
  when you don't know the session id, never a guess;
- update `last_used:` in that memory's frontmatter to today.

`applied` is the only token you write there. Surfacing events (what recall showed you)
are already recorded in `RECALL.log` by the CLI itself — never hand-log those, and
never log a memory you only read. Only `applied` raises activation, so a padded log
promotes memories for having been looked at.

## 5. Propose triggers for the ones that should have been ambient

If a memory you just applied would have surfaced on its own — its situation is
machine-recognizable (a command shape, an error string, a tool or file name) — check
whether it has a `triggers:` block, and declare one if it doesn't:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/scoped-memory/triggers.py" add \
  --memory <file.md> --regex 'gh\s+pr\s+view\b' --literal 'statusCheckRollup'
```

Always the tool, never a hand edit: it validates the patterns, recompiles the manifest,
and preserves the file's mtime (activation reads mtime as last reinforcement). Skip it
where the situation isn't crisply recognizable — a vague trigger fires on unrelated
work and teaches everyone to ignore the next one. Memories without triggers are served
by ranked search; that is the design, not a gap.

## When to reach for this mid-session

You don't need the command to search memory — step 1's call is the same one call
whether a human typed `/memories` or you decided to look. Reach for it when:

- a **successful** command returns a surprising or thin result (nothing failed, but the
  output doesn't explain what you're seeing);
- you're about to touch an **unfamiliar external system** — a CLI, a service, someone
  else's repo;
- an action was **denied**, or a tool behaved in a way you didn't expect;
- you're about to **re-derive something that smells previously solved**.

Those four are where the expensive misses have actually happened.
