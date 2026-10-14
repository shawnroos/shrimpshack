---
name: peek-recipes
description: Build a peek page for a kind of link peek does not handle yet, as a recipe in the user's recipe folder. A background agent on Haiku writes and checks the recipe and previews it in the pane; the person approves it there. Use when the person asks to "show <type> in peek", "build a peek page for <X>", "make peek understand <site> links", or to fix or change an existing peek recipe.
allowed-tools: ToolSearch, mcp__peek__check_recipe, mcp__peek__open, Read, Write
---

# Peek recipes

A recipe teaches peek one new kind of link. It is a folder under
`~/.local/share/claude-peek/recipes/<id>/` holding a `recipe.json` and one
script: the script that prints the page, or, for an MCP source, the map script
that turns the tool's result into the page. The source returns one Page as JSON, and peek draws
it with its own layout and keys. Nobody edits peek's own files. A recipe works
in every session of this user and survives peek updates.

You are the front door. You gather what the build needs, hand the build to the
`peek-recipe-builder` agent in the background, and keep working. The person
only reviews and approves. The type is done only after step 6.

## 1. Load the peek tools

Call ToolSearch with the query `select:mcp__peek__check_recipe,mcp__peek__open`.
These tools are deferred, so a session can list their names without their schemas.

If either tool still does not resolve, peek is not loaded in this session. Tell
the person to check that the peek mod is on (`/plugin`) and start a new session,
then run this skill again.

## 2. Learn the vocabulary

Peek draws only what this vocabulary names. An unknown key or block type fails
the check. The full schema, caps and link rule are in
`references/vocabulary.md`, next to this file. The builder reads both.

**Concepts**

- **Page**: `{ title, details?, sections, actions? }`. One page per link.
- **Details**: label/value rows under the title, for facts such as owner, state and date.
- **Section**: `{ heading?, block }`. Each section holds exactly one block.
- **Card** and **List item**: things that open. Give them an `href`.
- **Action**: a footer command, `{ label, open }` or `{ label, copy }`. At most 9. An Action never changes anything outside peek.

**Block types** (the value of `block.type`)

| Type | Use it for | Example |
|---|---|---|
| `markdown` | Prose, a description, a summary | `{ "type": "markdown", "text": "Read **this** first." }` |
| `media` | Pictures and videos | `{ "type": "media", "items": [{ "url": "https://…/a.png", "alt": "Cover", "kind": "image" }] }` |
| `table` | Rows with the same columns | `{ "type": "table", "columns": ["Date", "By"], "rows": [{ "cells": ["Oct 9", "Ana"], "href": "https://…" }] }` |
| `cards` | A few items, each worth a glance, optionally with a picture | `{ "type": "cards", "items": [{ "title": "Setup", "meta": "12 steps", "href": "https://…" }] }` |
| `list` | Many items, one line each | `{ "type": "list", "items": [{ "title": "ENG-412", "meta": "In progress", "href": "https://…" }] }` |
| `fields` | Label/value facts inside the body | `{ "type": "fields", "rows": [{ "label": "Size", "value": "4 MB" }] }` |

**TUI patterns peek adds by itself.** A recipe never draws these.

- Arrow keys and `j`/`k` move through every card, list item and table row, section by section. Markdown, media and fields scroll with the page.
- Enter opens the selected item's `href` through normal routing. A link can land on GitHub, Linear or Slack pages, another recipe's page, or a file. `b` goes back.
- `f` stars the page. Peek shows a star on the item under the mouse, and a click on it stars that item's `href`.
- Actions get the keys `1` to `9` and appear in the ⌃k menu.
- Breadcrumbs, the status line, the loading page, the error page and `u` refresh come from peek.
- Pictures share the pane's image budget. Extra pictures draw as links.

Links must be `http(s)` to a public host or an absolute file path. Peek refuses `localhost`, private IPs, `file://`, dotfiles and app bundles, inside markdown too.

Two complete examples are in `examples/`: `youtube-videos/` (a script recipe)
and `notion-pages/` (an MCP recipe with a sample tool result and its map).

## 3. Gather the brief

Get these from the conversation, or ask the person once for what is missing:

- **type**: what the page is for, for example "Figma files".
- **link**: a real link of that type that the person cares about.
- **source**: how to get the data.
  - **Script (the default).** A CLI or `curl` call a script in the folder makes.
  - **MCP: fetch, then map.** An MCP server and tool that already reads the
    data, with its arguments (`{{url}}` stands for the link). It works only in
    sessions where that server is connected. Say this to the person.
- **id**: 1 to 40 characters of `a-z`, `0-9` and `-`, for example `figma-files`.
- **skill folder**: the absolute path of this file's folder.

For an MCP source, sample it yourself now, because the builder cannot call
other MCP tools. Call the tool with the recipe's arguments and the link, and
save its result as `$TMPDIR/peek-<id>.sample.json` in the map's stdin shape
(`references/vocabulary.md`, "Writing the map", has a one-line way to wrap it).
Add that path to the brief as **sample**.

## 4. Dispatch the builder in the background

Call the Agent tool with `subagent_type: "peek:peek-recipe-builder"`,
`run_in_background: true`, and the brief from step 3 as the prompt. Tell the
person the build runs in the background and the page will appear in the pane
for their approval. Then go on with other work.

**Fallback.** If the agent type is not available, call the Agent tool with
`subagent_type: "general-purpose"`, `model: "haiku"` and `run_in_background: true`.
The prompt is: "Read `<skill folder>/../../agents/peek-recipe-builder.md` and
follow its body exactly, with this brief:" and then the brief. That file is the
whole brief and loop. Do not build the recipe in this session.

## 5. Handle the return

The builder replies with a `status:` block.

- **`ready`**: the check passed and the draft preview is open in the pane.
  Tell the person to read the approval surface at the top of the pane. It shows
  what the recipe runs, the links it matches, its overrides, timer and
  environment names, and each file's name, with **Show files** to open the
  full text of every file. Then they press
  **Approve** there. If `warnings` names an unplaced pane, ask them to open the
  pane first (`/peek`), then call `mcp__peek__open` with the link.
- **`needs-permission`**: ask the person to allow the exact rule in `allow`,
  such as `Bash(/Users/<you>/.local/share/claude-peek/recipes/<id>/page.py:*)`
  or `mcp__<server>__<tool>`. They add it with `/permissions`. Then dispatch
  the builder again with the same brief.
- **`stuck`**: dispatch once more with the same brief and `model: "sonnet"`.
  If that is also stuck, show the person the `last check` result and ask how to
  go on.

Only the person can approve. No tool, command, key, agent or file records an
approval, and there is no hotkey. If the person asks for changes, dispatch the
builder again with the brief and their changes. Any edit makes the recipe a
draft again, and the person approves the new version.

## 6. Report done

After the person says they approved it, call `check_recipe` with
`{ "recipe": "<id>", "link": "<link>" }`. Report the type as done only when the
check passes and `recipe.isApproved` is `true`. Until then, say what is still
waiting, for example "the page is ready for your approval in the pane".

## Using a recipe in a page

A markdown page or a group description can draw an approved recipe's rows. Put
`recipe=<id> url=<link>` on a collection fence, `peek-<layout>` with a layout
such as `list` or `cards`:

````
```peek-list recipe=figma-files url=https://figma.com/file/abc/Design
```
````

- `url` is required: a recipe always runs against one link.
- Before the recipe has run for that link, the block draws one "Open to load"
  row. After a run, it draws the rows with a link from the page's cards, list
  and table blocks, and how long ago they were fetched.
- The block never runs the recipe. Opening the link in peek, or a passing
  `check_recipe` on the approved recipe, runs it and fills the block. A draft
  run fills nothing.
- A draft, a missing recipe, or a link the recipe does not handle draws one red
  line naming the recipe.
