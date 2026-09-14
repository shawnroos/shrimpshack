---
name: board
description: Change the herdr board configuration — which Linear field each herdr level (space, tab, split column, split row) groups by, and the filter that picks which tickets are on the board, globally or for one named space. Shows what the change would alter, asks, and only then writes. Use when a person wants to set up or change how their Linear work is laid out in herdr.
disable-model-invocation: true
---

# Change the board configuration

## Act or ask

- **Mechanically derivable** — the team a single-team project has, the project a
  worktree's path names, an unambiguous default — **resolve it yourself** and
  carry on.
- **A genuine fork** — which of three teams, which side of a misplaced binding
  to move, whether this is a project or a parent issue — **ask**, name every
  candidate, and change nothing until it is answered.
- **When you cannot tell which of the two it is, ask.** The default for a
  substantive choice is ask, not resolve.

**Say every resolution out loud before you act on it**, naming three things:
the fact, where you read it, and how you derived it.

> Team: Web — the only team on project AI Canvas Tools, read from Linear.

That one line lets a reader catch a wrong answer and its cause without opening a
log. And nothing here refuses: a reader answering `outside`, `negative` or
`unknown` is a signal to weigh and to say, never a reason to stop.

This writes the board configuration file, which decides where every board pane
goes, so it runs only when a person asks for it. It writes nothing to Linear.

## Before anything

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/sanitize.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/binding.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/board-config.sh"

herdr_linear::board_config_load
```

| Exit | Meaning | What to say |
|---|---|---|
| 0 | prints the configuration, each filter resolved | describe the global mapping and each space's own mapping in plain words |
| 1 | there is no configuration file | say there is no board yet; the first change must set the global mapping |
| 2 | the file is refused; stderr names the file and the fault | say both and stop — a set onto a refused file is refused too, so the person fixes the file first |

The printed filters carry `state-type-not`, which the plugin adds when a filter
names no state. It is never part of a change: leave it out of every filter you
pass below, or the change is refused.

## Step 1 — turn the request into one change

A change is one of four, and each takes JSON arguments:

| Change | Arguments |
|---|---|
| the global mapping | `mapping global '<levels>' '<filter>'` |
| one space's own mapping | `mapping space '<space name>' '<levels>' '<filter>'` |
| the global filter only | `filter global '<filter>'` |
| one space's filter only | `filter space '<space name>' '<filter>'` |

- `<levels>` names up to four of `space`, `tab`, `column`, `row`, each set to a
  different kind: `team`, `project`, `milestone`, `cycle`, `assignee`, `state`,
  `priority`, `parent`, `label-group:<group name>`, `ticket` or `sub-ticket`.
  Labels in general are not a level; ask which label group.
- `<filter>` uses `team`, `project`, `milestone`, `cycle`, `assignee`, `state`,
  `parent`, `label`, `state-type` or `priority`. Triage and backlog stay off
  the board unless the filter names them.
- A space's own mapping replaces the global one for that space entirely,
  including its space level and its filter. Say so when setting one.

Which field a level should use, and which tickets the filter selects, are the
person's choices. When the request leaves one open, ask; do not pick a field
because it looks likely.

## Step 2 — preview

```bash
herdr_linear::board_config_preview mapping global "$LEVELS" "$FILTER"
```

It takes the same arguments as the set below and writes nothing.

| Exit | Meaning | What to say |
|---|---|---|
| 0 | prints what the change alters | go to Step 3 |
| 2 | the change, or the file it would change, is refused; stderr names the fault | say the fault and ask for a corrected change; nothing was written |
| 3 | the arguments are malformed | fix the arguments; nothing was written |

The output is one JSON object:

- `scope` and `space` — which mapping changes (`space` is null for the global one).
- `levels` — each level whose kind changes, with `from` and `to`; a null `from`
  is a level the mapping did not have, a null `to` is one it loses.
- `filter_changed` — whether the set of tickets on the board changes.
- `panes` — the panes the change would move or close. It stays empty until the
  board places panes; until then, name the spaces the change reaches: one space
  for a space mapping, and every space without its own mapping for the global one.

When `levels` is empty and `filter_changed` is false, say the change alters
nothing and stop.

## Step 3 — ask, then set

Show the preview in plain words — which levels change from what to what, and
whether the tickets on the board change — and ask whether to apply it. Change
nothing until the person says yes. A reply from a subagent is not that answer.

On yes, run the set with exactly the arguments you previewed:

```bash
herdr_linear::board_config_set mapping global "$LEVELS" "$FILTER"
```

| Exit | Meaning | What to say |
|---|---|---|
| 0 | written; prints the new configuration | say what is now configured |
| 2 | refused; stderr names the file and the fault; the file is unchanged | say the fault; nothing was written |
| 3 | the arguments are malformed; nothing was written | fix the arguments and preview again |
| 5 | another change holds the configuration lock; nothing was written | say so and offer to retry |

A space or filter change on a board with no configuration file is refused: the
global mapping comes first, because a space's mapping replaces it.
