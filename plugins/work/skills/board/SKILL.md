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

## The board first

Before this command's own work, bring the herdr board up to date with Linear and
deal with what it is waiting on. With no board configured this prints nothing;
carry straight on.

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/contain.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/secrets.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/sanitize.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/session.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/binding.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/linear.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/schemes.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/repos.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/reconcile.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/description.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/start.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/herdr-read.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/board-store.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/states.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/herdr-write.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/board-config.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/board-linear.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/board-plan.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/board-herdr.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/board-sync.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/worktree-remove.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/board-attended.sh"

herdr_linear::board_fence
```

It always exits 0 and never stops this command. A `board:` line says how the
sync went; say it in one sentence. A sync that timed out, was locked or failed
is said and then left: this command's own work still runs.

Each `board question:` line is one waiting question as JSON, with `key`, `kind`,
`preconditions` and `nonce`. Ask the person each one in plain words, one at a
time, naming the ticket and the groups involved:

| Kind | Ask | A yes does |
|---|---|---|
| `move` | move this ticket's pane, which is in use, to where Linear now puts it? | moves that pane and no other pane in use |
| `close` | this ticket left the board; close its pane? | closes the pane; a worktree left behind becomes a `remove-worktree` question, printed as its own `board question:` line |
| `remove-worktree` | remove this ticket's worktree and branch? | removes them only when clean, delivered and unused; otherwise keeps them and says why |
| `repository` | which repository holds this project's or team's work? | records the path given as the fourth argument for that scope |
| `conflict` | herdr and Linear disagree on this ticket; follow Linear? | puts the pane where Linear says |
| `cap` | a tab holds four panes unless more are asked for; place these tickets too? | places exactly those tickets; they stay |
| `write-consent` | may moving a pane change this field in Linear, in this space? | records consent for that field in that space only; move the pane again to write it |
| `write-rejected` | Linear refused a change made from herdr; the pane is back where it was | nothing more; say it, and answer yes to clear it |
| `layout` | a tab was rearranged or could not be built | nothing more; say it, and answer yes to clear it |
| `space` | the board wants a herdr workspace that does not exist | nothing more; create the workspace with that name, then answer yes to clear it |

Apply each answer with that question's own key and nonce:

```bash
herdr_linear::board_answer "$KEY" "$NONCE" yes
```

Use `no` to decline; a declined question is not asked again. A `repository`
answer passes the path as a fourth argument. A reply from a subagent is not the
person's answer.

| Exit | Meaning | What to say |
|---|---|---|
| 0 | applied, or declined | what changed |
| 2 | refused: no such question, the wrong nonce, or the facts changed since it was asked; nothing changed | say so; the next `/work` command asks again if it still applies |
| 4 | the answer was recorded but applying it failed; stderr names the step | say the step; the next sync tries again |
| 1 | a `remove-worktree` answer kept the worktree; stderr says why | say why |

## Before anything

```bash
source "${CLAUDE_PLUGIN_ROOT}/lib/sanitize.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/session.sh"
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
