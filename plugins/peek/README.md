# peek

A side pane for Claude Code that shows the files and links in a conversation.
Click a path or URL in a reply, or run `/peek`, and the file opens beside the
transcript.

## What it shows

| File | In the pane |
|---|---|
| Markdown | One scrolling page with styled headings, quotes, tables, code, diagrams, images and clickable tasks |
| Code | Syntax colours and line numbers |
| Images (PNG, JPG, GIF, WebP, HEIC, SVG) | The picture, on terminals that draw images |
| Mermaid (`.mmd`, or fenced in markdown) | Drawn as text boxes and arrows when `mermaid-ascii` is installed |
| Folders | A clickable file list |
| Web pages | Open Graph title, description and preview image, the site's favicon, then the page text |
| GitHub pull requests | Details, line counts, files changed, a CI summary, the description and comments |
| GitHub issues and repos | Details, the body or README, comments, and a repo's open pull requests and issues |
| Linear issues and projects | Details, the description, comments with replies, and a project's open issues |
| Slack threads | The channel and reply count, then the conversation: the first message full width, replies inset under it, each with the speaker's picture or coloured initials, a time that opens that message in Slack, and images inline |
| A link to a file (`.md`, `.png`, `.json`, `.csv`, code, ...) | Downloaded and drawn like the local file; `o` and `c` still use the link |
| A link to a video (`.mp4`, `.webm`, `.mov`) | A Play button that opens it in your browser |

## Remote pages

Links and IDs in replies become clickable: GitHub URLs, `owner/repo#12`, `#12`
inside a GitHub repo, Linear URLs, Linear IDs such as `WEB-2757` when
`WEB` is a team in your workspace, and Slack message links
(`https://<workspace>.slack.com/archives/<channel>/p<ts>`). A link to a reply
opens its whole thread, and Recent and groups count a thread and its reply
links as one item. Peek is read-only: it never changes anything in GitHub,
Linear or Slack.

Pictures, videos and Mermaid diagrams in a pull request, issue or Linear
description or comment draw the same way as on a web page: up to 8 pictures
inline, a video as its thumbnail and a Play button. A picture that cannot be
downloaded, such as an attachment in a private repo, stays a link.

A Slack thread draws as a conversation. Each speaker keeps one colour and shows
their Slack profile picture, or a badge with their initials when there is none.
Each message shows its time (relative for today, such as `5m ago`, otherwise
`Oct 6, 1:22 PM`); click the time to open that message in Slack. Up to 6 image
files per thread draw inline, within the pane's image limit. Other files, and
images peek may not read, show as a row with the name, type, size and an
`open in Slack` link.

Peek reads Slack through the Slack MCP server under your Claude Code
permissions, so each Slack tool asks for permission until you choose to always
allow it, or add its name to `permissions.allow` in `~/.claude/settings.json`:

| Tool | Peek uses it for |
|---|---|
| `mcp__plugin_slack_slack__slack_read_thread` | The messages |
| `mcp__plugin_slack_slack__slack_read_channel` | The channel name |
| `mcp__plugin_slack_slack__slack_read_file` | Image files |
| `mcp__plugin_slack_slack__slack_search_users` | Profile pictures |

With the claude.ai Slack connector the names start with
`mcp__claude_ai_Slack__` instead. If you decline the file or user-search read,
the thread still opens: files show as rows and speakers show initials. Peek
asks for each file and each speaker once per session, so after allowing a tool
you declined, start a new session to see the pictures.

Each page comes from the best source available, and the footer names it:

| Source | Used for | Needs |
|---|---|---|
| `gh` | GitHub items | `gh auth login` |
| `curl` | Web pages and their images | `curl` on the path |
| Linear API | Linear items | `LINEAR_API_KEY` in the environment or `~/.secrets`, or the `work-linear` Keychain item |
| Slack MCP | Slack threads | The Slack plugin's MCP server (or the claude.ai Slack connector) connected in this session; check with `/mcp` |
| `slack` | Slack threads, when the Slack MCP server is not connected | The public Slack CLI at `~/.slack/bin/slack` or on the path, signed in with `slack login` |
| This session | Anything the agent already read through a GitHub, Linear or web tool | Nothing |

Open issues, pull requests and Slack threads on screen refresh every 60 seconds. Open ones in
Recent or stars refresh every 5 minutes, at most 20 per round. Closed and merged
items, repos, projects and web pages refresh when opened or when you press `u`.
Refresh pauses after 10 minutes with no activity and backs off when a service
rate-limits it. When no tool or key is available, refresh repeats the agent's
own read call.

## Live view

On a web page, press `v` to switch between the reader page and the real page.
The real page is rendered by WebKit and drawn in the pane. You can scroll it
with the wheel or `j`/`k`, and click links and buttons. After you click a text
field, typing goes to the page. Press Escape or Done typing (`d`) to give the
keys back to peek. While the page is live, `b` goes back in the page, `u`
reloads it, and `o`, `c` and `f` open, copy or star the page's current address.

Live view is a page renderer, not a browser. It has one page, no tabs, and no
downloads. It loads only `http` and `https` pages and refuses pop-up windows
and JavaScript dialogs.

- **Nothing is saved.** Cookies and site data live only in memory. A login lasts
  until peek unloads, then it is gone.
- **Frames are budgeted.** Peek sends a new picture only when the page changes,
  and at most about 1 MB a second, because faster streams stutter in the pane.
  A busy page, such as a video, drops to a few frames a second.
- **First use builds the helper.** Live view uses a small Swift program that is
  compiled on first use (about 40 seconds) into `~/.cache/claude-peek/bin/`.
  This needs the Xcode command-line tools: run `xcode-select --install` once.
- **Terminal only.** Live view needs a terminal that draws images. Under a
  multiplexer, set `CLAUDE_CODE_FORCE_TERMINAL_IMAGES` (Setup step 4).

## Groups

A group is a titled set of files and links that the agent put together for
you, such as a plan, its pull request and the docs it rests on. It has a
description and can split its items into sections. A group can also fill
itself from a rule over task props and section its members by one prop (see
Rule groups and splits under Tasks), and its description can hold `peek-`
blocks (see View definitions). Each section shows its
items as cards (the default) or as a list of lines; the agent picks this with
`save_group`, as `layout` on a new section or with the `layout` section action.

The agent makes and changes groups with four tools: `list_groups`,
`read_group`, `save_group` and `delete_group`. Ask it to "group the files for
this feature" and the group shows in the Groups tab. The agent's changes are
edits, never a rewrite: it cannot remove an item you added, or put back an item
you removed, unless it forces the change. It also needs force to delete a
starred group or one holding items you added.

You manage groups in the pane:

- `e` opens the Groups tab: one full-width card per group, with its title,
  description, first section and that section's first row of items. Click
  **MORE ▼** or press `m` (⌃k "Expand/Collapse group") to show every section
  in place; **LESS ▲** or `m` again folds it back. `j`/`k` move between cards.
- Click an item on a card to open it; `b` then returns to the group page.
  Click a card's title or press `o` to open the group page; `e` again goes
  back to the list.
- `f` on a card stars the group. Up to 4 starred groups sit near the top of
  Recent, below Open work and above Favourites, whatever the scope and filter, as the same cards,
  folded until you expand them; the rest are in the Groups tab. On a group page, `f` stars the selected item, as everywhere else.
- ⌃k on any file or link lists "Add to group" and "Remove from group" for each
  group. On a group page, ⌃k also has "Remove from this group" and "Star this
  group". The footer hint stays `⌃k menu`.

Groups belong to a project: every worktree of one repo sees the same groups,
and a session in another project does not. They live as one JSON file per
group in `~/.local/share/claude-peek/groups/`, so they survive plugin updates
and cache cleanups. A file path inside the repo is stored relative to it and
opens the copy in the current worktree.

An item that no longer exists, such as a deleted file or a pull request that
returns "not found", shows as **missing** and is counted in the status line.
An item peek cannot load right now, such as a link that times out, shows as
**unavailable**; it is not counted as missing.

## Tasks

Peek keeps the work that is too small, or too far from code, for a Linear
ticket: your own to-dos, deliverables such as a plan, and the step lists agents
work through. A task is a markdown file with props in its frontmatter. Peek
never reads git, pull requests or commits to decide a status, and no task
action changes anything outside these local files.

### Capture a task by telling the agent

Say "task: fix the crumb hover, after the Esc work". The agent saves it with
`save_task` (the `peek-tasks` skill tells it to save first and confirm after).
Peek records the creator itself: you, stored as `creator: shawn`, when the
agent saves a task you asked for (`on_behalf: person`), or the agent's session
id when it saves its own work (`on_behalf: self`). A creator the agent passes
is ignored.

### Where tasks live

| Session in | Tasks folder |
|---|---|
| A git repo | `.peek/tasks/` in the main checkout: the folder that holds the repo's shared `.git`. Every worktree of the repo reads and writes this one folder, so removing a worktree never deletes tasks. |
| No git repo | `~/.local/share/claude-peek/tasks/`, the user-level list. Every session shows your own tasks in it; mirrored agent lists placed there show only in sessions outside a repo. |

The first time peek writes a repo's tasks folder, it adds `.peek/` to the
repo's `.git/info/exclude`. That file is local and every worktree shares it;
peek never edits a committed `.gitignore`.

A new task is a file named `<name-slug>-<8-character id>.md`, such as:

```markdown
---
name: "Fix the crumb hover"
id: k3x9a0qz
status: todo
creator: "shawn"
session: "0f1c…"
sequence: { after: "7bq2m1xa" }
---
The task's description, as markdown.
```

| Prop | Holds |
|---|---|
| `name` | What to do. Without it, the file name |
| `id` | A unique id. Without it, the file path |
| `status` | `todo`, `doing`, `done` or `cancelled` |
| `creator` | `shawn`, or the session id of the agent that made it |
| `parent` | The id of the task this one is part of |
| `sequence` | `{ after, before, with }`, each a task id or a list of ids |
| `due` | A date, `YYYY-MM-DD` |
| `attachments` | A list of file paths or URLs |

Only `id`, `status` and `creator` are required in a tasks folder, so a quick
capture is never flagged. A task with a missing required prop shows a `⚑` on
its row; it is never hidden.

### Deliverables

A markdown file anywhere in the repo becomes a task when its frontmatter has
`isTask: true`, so a plan or a write-up can sit in your task list. It stays
where it is. Peek reads these from git-tracked `.md` files in the session's own
worktree (the first 2000). A status change on one is an ordinary uncommitted
edit on that branch, and only sessions in that worktree see it. A deliverable
needs every Task prop (`id`, `status`, `creator`, `parent`, `sequence`, `due`,
`attachments`), so it shows `⚑` until they are filled. `move_tasks` does not
move a deliverable.

### Status

A status is `todo`, `doing`, `done` or `cancelled`. On a task's page, or on a
selected task row, `w` cycles todo, doing, done; ⌃k "Set cancelled" cancels.
Agents set a status with `save_task`. Peek rewrites only the `status:` line.

Every status change goes through one path, whether it comes from the pane, a
tool, agent-list mirroring or a hand edit. Under one lock per project, peek
compares the new status with the stored one and does nothing when they match,
so a change several sessions see is logged once. Otherwise it writes the doc
and one change-log entry in `~/.local/share/claude-peek/task-log/<project>/`,
outside the repo. Each session reads new entries every 3 seconds. Entries are
kept 7 days. A status you edit by hand is logged (as `by: unknown`) the next
time peek reads the doc. When two changes collide, the later one wins and both
are logged.

### Agent task lists (mirrored)

Claude Code keeps each session's task list (the agent's TaskCreate and
TaskUpdate items) as one file per item under `~/.claude/tasks/<session id>/`,
and deletes the files once the list is finished. Peek checks the 200 newest of
those folders every 3 seconds and keeps its own record of each item, from the
first time it sees it, in
`~/.local/share/claude-peek/mirror/<session id>/<item id>.md`. A record keeps
its last status after Claude Code deletes the item. Peek never writes Claude
Code's own task files.

| Agent item | Mirrored record |
|---|---|
| `pending`, `in_progress`, `completed` | `todo`, `doing`, `done` |
| blocked by another item | `sequence: { after: … }` |
| its list | `list: <session id>#<n>`; `n` rises each time Claude Code clears the list and the agent starts another |
| who made it | `creator: <session id>` |

A list belongs to the repo of the session it ran in, which peek notes when the
session starts (or reads from the session's transcript). A list peek cannot
place belongs to the user-level list. If a list's files are already gone when
peek first sees the folder, peek tries to rebuild it from the session's
transcript; this is a best effort and often finds nothing.

Each list gets one group in its repo, titled
`Agent tasks <first 8 characters of the session id> #<n>`,
with the rule `list=<session id>#<n>` and split by status (see Rule groups
below). A list outside any repo gets no group; its items show on the Tasks page
of sessions outside a repo. A list shows only in the repo its session ran in.

**Finished and ended lists.** A list is finished when every item is done or
cancelled, when its session ended, when Claude Code cleared it, or when its
folder has not changed for 24 hours. Open items in a list that is over read
"session ended". A finished list folds to one line in Recent ("finished" or
"N session ended"). 12 hours later it archives: peek removes its group, unless
you starred the group or added items to it, and its items leave the Tasks page,
`list_tasks` and Recent. On the Tasks page, ⌃k "Archived: Agent tasks …" opens a
page of an archived list's items, newest archive first. A task that goes back to todo or doing makes the list
active again and brings its group back. Your own tasks never close or move on
their own.

**Takeover and adopt.** When you change a mirrored item's status in peek, or an
agent does with `save_task`, peek first writes a takeover doc: a task doc in
the list repo's tasks folder that keeps the agent session as creator and
records the item it came from (`mirror`, `list`, `session`, `task_id`). From
then on, the agent's own updates to that item change the takeover doc, and the
latest change wins. ⌃k "Adopt this task", on an open item whose session ended,
does the same and records `adopted_by: shawn`, so the task stays in your list.
`move_tasks` adopts items into a list you name.

### Open work in Recent

The top of Recent, above starred groups and Favourites, shows **OPEN WORK**:
your own open tasks (todo or doing, doing first), up to 5, then one line per
agent list of this repo, up to 3: active lists first with their open count,
then finished lists until they archive. A list's line opens the Tasks page. When there are more, a last
row counts them.

### The Tasks page

Open it from ⌃k: type "Tasks" (the row shows only when you type) and pick
"Tasks: every task, by now, next and later". The page is your tasks folder,
drawn as one focus block over every task peek knows: your list, the user-level
list, deliverables in this worktree and the mirrored items of this repo's agent
lists that have not archived.

- **Now:** doing.
- **Next:** up to 5 todo tasks not waiting on an unfinished task, by sequence
  then due date.
- **Later:** the other open tasks.

Done and cancelled tasks are left out. ⌃k "Filter: creator …" shows one
creator's tasks; "Filter: creator anyone" shows all again.

### Rule groups and splits

A group can fill itself from a rule. `save_group` with
`rule: "creator=shawn and status=todo"` (or `{ creator: "shawn", status: "todo" }`)
makes every task whose props match a member: tasks in the tasks folders,
deliverables and mirrored items. Members are worked out each time the group is
read, never stored, so the group fills and empties as props change. Items
added by hand stay; an item you removed stays removed. A rule holds up to 10
props, each equal to one value. A text value matches a true/false or number
prop by how it prints (`isTask=true`), and a list prop matches when any of its
values does. Besides props, a rule can test `id`, `href` (the path), `type` and
`name`.

`split: "status"` shows a group's members in sections, one per value of that
prop. Status sections run todo, doing, done, cancelled; other props sort by
value, and items without the prop go under "none". Any prop works, such as
`creator`, `due` or `parent`.

## View definitions

Every peek type that has one is drawn from a **view definition**: one markdown
file whose frontmatter declares the type's props and rules, and whose body is
the page's template. The template is ordinary markdown with `{{prop}}`
placeholders and `peek-` blocks. A definition holds no loops, expressions or
code, so it runs nothing and needs no approval.

### Where definitions live

| Folder | Holds |
|---|---|
| `views/` in the peek plugin | Peek's own: `task.md` (Task) and `gh-pr.md` (the GitHub pull request page) |
| `~/.local/share/claude-peek/views/` | Yours and your agents'. Every session and project reads it. |

Peek reads every `.md` file in both folders, up to 100 per folder, and
re-reads a file when it changes. Two files that declare the same `type`, in
either folder, is an error on both, and neither loads. So a user definition
cannot replace a built-in one by reusing its name.

Peek picks a definition this way:

- **A markdown file** whose frontmatter peek can read uses the first
  definition, by type name, whose `match` fits it. A file without frontmatter
  draws as plain markdown.
- **A remote page** (pull request, issue, Linear, Slack, web) uses the
  definition whose `match` names its record kind. A kind with no definition
  keeps its built-in drawing.

### Check a definition

Before saving one, have the agent call `check_view` with the text (or a file
path). It reports every problem with its line, including a type name another
definition already uses. Always check: a definition with problems does not
load. Its problems show in red at the top of every page it would match, file
or remote, and a type-name clash names both files.

### Frontmatter keys

| Key | Type | Required | Meaning |
|---|---|---|---|
| `type` | text: 1 to 40 of `a-z`, `0-9`, `-`, starting with a letter or digit | Yes | The type's name; unique across both folders |
| `match` | one-line map | Yes | Which items the type draws (below) |
| `props` | map of prop name to `{ kind, required, values }` | No | The type's props, up to 40 |
| `requires_when` | map | No | Props that become required on a condition |
| `layout_default` | map of place to layout | No | Checked, but not used yet (below) |
| `colors` | map of prop to `{ value: color }` | No | Colors for a prop's values |
| `icons` | map of field label to icon | No | Icons for a fields box's labels |

Any other top-level key is an error.

**`match`** takes one rule, or `folder` and `prop` together:

| Rule | Matches |
|---|---|
| `{ folder: notes/meetings }` | A markdown file inside a folder with this path, anywhere in its path. Names joined by `/`; no leading `/`, `.` or `..` |
| `{ prop: isTask, equals: true }` | A markdown file whose frontmatter prop has exactly this value (`true` is a boolean, not text). `prop` and `equals` go together |
| `{ folder: …, prop: …, equals: … }` | Either one is enough |
| `{ record: gh-pr }` | A remote page of this kind: `gh-pr`, `gh-issue`, `gh-repo`, `linear-issue`, `linear-project`, `slack-thread` or `web`. It stands alone |
| `{ recipe: … }` | Reserved. It passes the check but matches nothing yet |

**`props`**: each name starts with a letter or `_`, then letters, digits or
`_` (no `-`), up to 32 characters. Each declaration is a one-line map:

| Field | Value |
|---|---|
| `kind` | `text`, `choice`, `date`, `ref` (another item's id) or `links` (a list of paths or URLs). Required |
| `required` | `true` or `false` (the default) |
| `values` | For a `choice` only, and required there: a list of 1 to 40 values |

Peek uses `required` and `requires_when` to flag missing props on tasks only:
the `⚑` on a block row and `missing` in `read_task`. On other types they have
no visible effect yet. Peek does not check a value against its kind. A prop counts as missing when it is absent, `null`, blank
text or an empty list.

**`requires_when`** makes more props required when every condition matches the
doc. Write conditions as `prop: value`, plus exactly one of `all: true` (every
declared prop) or `props: [a, b]` (declared props only):

```yaml
requires_when: { isTask: true, all: true }
```

**`colors`** maps a declared prop's values to color names. Write it as a
block map, one prop per line (a one-line map inside a one-line map is too
deep):

```yaml
colors:
  ciTone: { bad: red, ok: green }
```

The names that draw are `red`,
`yellow`, `green`, `teal`, `blue`, `mauve`, `peach`, `accent`, `text`,
`subtext`, `gray` and `muted`; any other name is an error. Colors apply to a
fields-box value (the prop key is the label, lowercase, with `_` for spaces,
such as `merge_state`), to the header title, and to a row's status icon
(`colors.status`).

**`icons`** maps a fields-box label, lowercase with `-` for spaces
(`merge-state`), to an icon of 1 to 4 characters. A declared icon replaces the
built-in one for its label; other labels keep theirs.

**`layout_default`** maps a place (`page`, `group`, `recent`, `gallery`) to a
layout (`cards`, `list`, `tree`, `sections`, `board`, `focus`). Peek checks it
but does not use it yet: a block's layout comes from its fence language, and
`y` changes it in place.

### The YAML peek reads

Peek reads a small part of YAML, and reports anything else as an error naming
the line:

- `key: value` lines, and maps nested by indentation up to two levels. Indent
  with spaces; a tab is an error.
- One-line lists `[a, b]` of plain values, and one-line maps `{ k: v }` whose
  values are plain values or one-line lists. A one-line map inside a one-line
  map is too deep, so `colors: { a: { x: red } }` is an error; put the outer
  map on its own lines.
- Block lists of `- value` lines. A map inside a list is an error.
- Values: `true`, `false`, `null` (or `~`, or nothing), numbers, `"double"`
  quotes (with `\n`, `\t`, `\"`), `'single'` quotes (`''` for a quote), and
  plain text. Plain text may not start with `&`, `*`, `!`, `|`, `>`, `%`,
  `@`, `?` or a backtick, so anchors, tags and multi-line strings are out.
- `#` after a space starts a comment. A key named twice is an error.

### The template

The body after the frontmatter is the page. It is ordinary markdown, plus
placeholders and blocks.

**Placeholders.** `{{name}}` (a letter or `_`, then letters, digits, `_` or
`-`) inserts a prop of the item being drawn. On a markdown file, `name` is the
`name` prop or the file name, and `id` is the `id` prop or the file path. On a
remote page, the values are the record's fields (by label, lowercase with `_`
for spaces), its change counts, and `title`, `kind`, `address`, `url` and
`status`.

- In text, a placeholder inserts plain text: markdown characters are escaped,
  a list is joined with commas, and a missing prop inserts nothing.
- `{{description}}` or `{{body}}` alone on a line inserts the file's own
  markdown body, drawn on its own, so it can never break the template's
  blocks.
- In a block's options, spaces in the value become `_`.
- `{% … %}`, `{{#each …}}` and anything else that is not a plain `{{name}}` is
  an error.

**Blocks.** A block is a fenced code block whose language starts with `peek-`.
Options follow the language on the fence line as `key=value` tokens separated
by spaces. A value is up to 200 of letters, digits and `_ . : / , @ # -` (no
spaces, so `title=Details`), or one `{{name}}`. Each key appears once. An
unknown `peek-` language is an error (`peek-diagram` is peek's own fence for
a drawn Mermaid diagram, not a template block), every block must be closed, and a template
holds at most 40 blocks.

**Collection blocks** select items and draw them:

| Block | Draws |
|---|---|
| `peek-list` | One row per item: status glyph, name, then creator, due date, "session ended" and `⚑` as room allows |
| `peek-cards` | Items as cards |
| `peek-tree` | Items nested by their parent prop, with branch lines, a child count and a fold control per parent |
| `peek-sections` | Items in sections by one prop (status by default), nested inside each section. A child whose parent is in another section draws at the top of its own with the parent named |
| `peek-board` | The same sections as side-by-side columns; when they do not fit, it draws as sections |
| `peek-focus` | Now (doing), Next (up to 5 todo tasks not waiting on an open task) and Later (the other open tasks). Done and cancelled are left out |

These options shape the layout:

| Option | Does |
|---|---|
| `split=<prop>` | The prop `peek-sections` and `peek-board` split by. Default `status` |
| `values=a,b,c` | The section order. For `status` the default is todo, doing, done, cancelled; otherwise values sort alphabetically, and items without the prop go under "none" |
| `cap=<n>` | Draw at most `n` of the selected items |
| `nest=<prop>` | The prop that names an item's parent. Default `parent` |

Every other option is a rule: an item is selected when its prop equals the
value. A rule can also go in the block's body as `a=b and c=d`; both parts
apply. With no rule, a block selects every item. These blocks are equivalent:

````markdown
```peek-sections creator=shawn status=todo
```

```peek-sections
creator=shawn and status=todo
```
````

The items are every task peek knows: your tasks folder, the user-level list,
deliverables in this worktree and the mirrored items of this repo's agent lists
that have not archived. Each item also has two
props no file stores: `neighbours`, the ids its sequence links in either
direction, and `ancestors`, its parent chain. So `ancestors={{id}}` selects
every task under this one. Rules match props as described in Rule groups.
Items sort by sequence (`after`, `before`, `with`) first, then due date, then
name. A block with nothing to show draws a dim "no items" line.

Collection blocks draw on markdown file pages, in group descriptions, on the
Tasks page and in PR and issue bodies.

**Recipe blocks.** `recipe=<id> url=<link>` on a collection fence draws the
rows an approved recipe returns for that link, instead of tasks:
`peek-list recipe=figma-files url=https://figma.com/file/abc/Design`. `url` is
required, because a recipe always runs against a link. Each row with a link in
the recipe page's cards, list and table blocks becomes an item named by its
title, with props `recipe` (the recipe id) and `section` (its section's
heading, when it has one). Rows without a link are left out. The other options still apply, so
`section=Files` selects one section's rows. A block never runs its recipe.
Before the recipe has run for that link, the block draws one "Open to load"
row; Enter opens the link as the recipe page, which runs it once. After that
run, the block draws the rows peek saved, with a dim "fetched … ago" line. Only
opening the page, `u` on it, its opted-in timer and `check_recipe` refresh
them. When the recipe changes, the block shows "Open to load" again. A draft or
missing recipe draws one red line naming it.

On a page with blocks, `j`/`k` move between rows, Enter or a click opens the
selected item, and `n`/`m` jump between blocks. `y` switches the selected
block's layout (cards, list, tree, sections, board, focus) and `z` folds or
unfolds the selected parent. Peek keeps both choices for that block across
sessions.

**Record blocks** draw parts of a remote page's record. They draw only on a
remote page; anywhere else they show one dim line. Each names a record field
with `from=`: `title`, `status`, `meta` (label and value rows), `stats` (a
change summary), `body` or `comments`. A block whose field is empty is left
out.

| Block | Options | Draws |
|---|---|---|
| `peek-header` | `from` (default `title`) | The title line, with the site icon or the kind's icon |
| `peek-fields` | `from`, `title`, `icon`, `detail`, `color` | A framed box. Label and value rows (`meta`) draw with label icons; a change summary (`stats`) draws additions, deletions, files and CI. `icon` is `kind`, an icon name or literal text. `detail` names a field shown on the box's top line. `color` is `kind` or a color name |
| `peek-media` | `from`, `title` | A section rule, then the field as markdown with its pictures and videos |
| `peek-comments` | `from`, `title` | A comment thread with its count |

### Worked example: Task

`views/task.md`, peek's own Task type:

````markdown
---
type: task
match: { folder: .peek/tasks, prop: isTask, equals: true }
props:
  id:          { kind: text, required: true }
  status:      { kind: choice, values: [todo, doing, done, cancelled], required: true }
  creator:     { kind: text, required: true }
  parent:      { kind: ref }
  sequence:    { kind: ref }
  due:         { kind: date }
  attachments: { kind: links }
requires_when: { isTask: true, all: true }
layout_default: { page: tree, group: list }
---
# {{name}}

| Prop | Value |
|---|---|
| Status | {{status}} |
| Created by | {{creator}} |
| Due | {{due}} |
| Parent | {{parent}} |
| Attachments | {{attachments}} |

{{description}}

## Children

```peek-tree ancestors={{id}}
```

## Sequence

```peek-list neighbours={{id}}
```
````

- `match` takes every file in a `.peek/tasks` folder, and any other file with
  `isTask: true`.
- `requires_when` makes every declared prop required for a deliverable, which
  is what flags a plan doc until the agent fills it in.
- The table fills from the task's props, and `{{description}}` alone on its
  line draws the task's own body.
- `ancestors={{id}}` selects every task whose parent chain includes this one,
  drawn as a tree. `neighbours={{id}}` selects the tasks its sequence links.

### Worked example: the pull request page

`views/gh-pr.md` draws a GitHub pull request with no PR-specific drawing code.
Its icons are Nerd Font glyphs, so some may look blank here:

````markdown
---
type: gh-pr
match: { record: gh-pr }
props:
  title:  { kind: text, required: true }
  status: { kind: choice, values: [open, draft, merged, closed] }
  body:   { kind: text }
  ciTone: { kind: choice, values: [bad, wait, ok, none] }
icons:
  state: 󰝥
  author: 󰀄
  branch: 󰘬
  review: 󰈈
  merge-state: 
  assignees: 󰡉
  labels: 󰓹
  milestone: 󰓾
  created: 󰃳
  updated: 󰥔
  merged: 
  closed: 󰃲
colors:
  ciTone: { bad: red, wait: yellow, ok: green, none: gray }
---
```peek-header from=title
```

```peek-fields from=meta title=Details icon=kind detail=status color=kind
```

```peek-fields from=stats title=Changes icon=gh-pr color=green
```

```peek-media from=body title=Description
```

```peek-comments from=comments title=Comments
```
````

- `match: { record: gh-pr }` takes every pull request page.
- The template is five record blocks in order: the title, the Details box from
  the `meta` rows, the Changes box from `stats`, the description from `body`,
  and the comments.
- `icons` gives each Details label its glyph; `colors` colors the CI line by
  `ciTone`.

### Build a new type

1. Write the definition. This one draws every markdown file under a
   `notes/meetings` folder:

   ````markdown
   ---
   type: meeting
   match: { folder: notes/meetings }
   props:
     date:      { kind: date, required: true }
     attendees: { kind: links }
   ---
   # {{name}}

   | Prop | Value |
   |---|---|
   | Date | {{date}} |
   | Attendees | {{attendees}} |

   {{body}}

   ## My open tasks

   ```peek-sections creator=shawn
   ```
   ````

2. Have the agent call `check_view` with the text, and fix every problem it
   reports.
3. Save it as `~/.local/share/claude-peek/views/meeting.md`.
4. Open a meeting note that has frontmatter. It draws from the template.

## Recipes

A recipe gives peek a page for a kind of link it does not handle, such as Figma
files or an internal wiki. Ask the agent to "show Figma files in peek". It uses
the `peek-recipes` skill to write the recipe, check it and show it to you.

A recipe is a folder in `~/.local/share/claude-peek/recipes/<id>/`. It holds a
`recipe.json` that names the links it handles, and one data source:

- a script in the folder, which gets the link and prints a page as JSON, or
- an MCP tool, whose result a map script in the folder turns into a page. This works only in sessions where that MCP server is connected.

The page is built from a fixed vocabulary: a title, details, sections (markdown,
media, table, cards, list or fields) and up to 9 actions that open a link or copy
text. Peek draws every recipe page with the same keys as its other pages. The
arrow keys move through cards, list items and table rows, enter opens one, and
actions have keys `1` to `9` in the ⌃k menu. Recipes live outside the plugin, so
they work in every session and survive peek updates.

This vocabulary is not the `peek-` blocks of view definitions, though some names
match. A recipe block carries its own rows, which the script printed. A `peek-`
block carries no data: it selects items by their props. To show a recipe's rows
inside a markdown page, use a recipe block (see "Recipe blocks" under The
template).

A recipe page runs its source when you open it, when you press `u`, and on a
timer only when the recipe asks for one (every 5 minutes or more). Groups, stars
and Recent never run it. When the source fails, the page names the recipe and the
error. It does not fall back to the web page. A GitHub, Linear or Slack link
stays on its built-in page unless the recipe says it overrides that page.

**Drafts and approval.** A new recipe is a draft, and normal link opens ignore
it. The agent previews a draft in the pane, marked unapproved. Above the page,
the approval surface shows what the recipe runs, the links it matches, the
environment names it reads, warnings for MCP tools that look like they change
something and for paths outside the folder, and each file's name. **Show files**
there opens the full text of every file.
Press **Approve** there to make it live. Only that button approves a recipe: no
agent tool, command or file write can. Any later change to a file in the folder
turns the recipe back into a draft until you approve it again. While a recipe is
a draft, it runs only what the session's permissions already allow.

The agent uses two tools, `check_recipe` and `open` (see Agent tools). Both are
deferred, so the agent loads them with ToolSearch first.

**Background builder.** The skill does not build the recipe in your session.
It gathers the type, a sample link and the source, then hands the build to the
`peek-recipe-builder` agent (`agents/peek-recipe-builder.md`), which runs in the
background on Haiku while the session goes on. The builder writes the folder,
tests the script or map, runs `check_recipe` up to five failed times and opens
the draft preview. It returns `ready`, `stuck` or `needs-permission`; it never
approves and never calls the type done. On `ready` the agent asks you to press
Approve, and reports done only when `check_recipe` says the recipe is approved.
The builder cannot answer permission prompts, so a check that needs one comes
back as `needs-permission` with the exact rule to allow. For an MCP source the
session calls the tool once itself and passes the result as a sample, because
the builder can use only peek's tools. If the agent type does not load, the skill
runs the same file as the brief for a general background agent on Haiku.

The skill is `skills/peek-recipes/SKILL.md`. The full vocabulary is in its
`references/vocabulary.md`, and `examples/` holds a script recipe and an MCP
recipe with their sample pages. The MCP recipe also holds a sample tool result
for its map script.

## Agent tools

Peek gives the agent these tools (as `mcp__peek__<name>`). The `peek-tasks`
skill tells it when to use the task tools, and the `peek-recipes` skill when to
use `check_recipe` and `open`.

| Tool | Inputs | Does |
|---|---|---|
| `list_tasks` | `status`; `creator` (`person`, `self` or a session id); `list` (`<session id>#<n>`) | Lists tasks, deliverables and the mirrored items of this repo's lists that have not archived, up to 200, with id, name, path, status, creator and any list, parent, sequence and due date |
| `read_task` | `id` (an id or a path) | One task in full: every prop, its body, and any required prop it is missing. Finds any task by id, including other repos' and archived lists |
| `save_task` | `id` (leave out to create); `name`; `on_behalf` (`person` or `self`; required to create); `status`; `description`; `sequence` (`{ after, before, with }`, ids); `parent`; `due` (`YYYY-MM-DD`); `attachments` (paths or URLs) | Creates a task in your list, or changes one. A mirrored item changes only its status, through a takeover doc |
| `move_tasks` | `tasks` (ids) or `list` (`<session id>#<n>`); `to` (`mine`, `user`, or a folder in another git repo) | Moves task docs to another list. Moving a mirrored item adopts it. Moving a list moves where that session's lists belong, with their groups |
| `check_view` | `text` or `path` | Checks a view definition and reports every problem |
| `list_groups` | none | Every group with its rule, split and counts |
| `read_group` | `id` | One group with its rule, split, sections, items and the items under each split value |
| `save_group` | `id` (leave out to create); `title`; `description`; `sections`; `rule` (text or object; `null` or empty text clears it); `split` (a prop name; empty text clears it); `order`; `add`; `move`; `remove` | Creates or edits a group |
| `delete_group` | `id`; `force` | Deletes a group |
| `star` | `target`; `starred` | Stars or unstars a file or link |
| `check_recipe` | `recipe` (the folder name); `link` | Runs a recipe once against a real link. Reports whether it matched, which page wins the link, any recipe whose links overlap, and whether the page fits the vocabulary. It never approves, and it saves the rows for recipe blocks |
| `open` | `link` | Opens a link in the pane through normal routing, drafts included. Returns the page outline or the error |

## Commands

| Command | Does |
|---|---|
| `/peek <path or URL>` | Opens it |
| `/peek WEB-2757` or `/peek owner/repo#12` | Opens a Linear or GitHub item |
| `/peek the export diagram` | Finds a recent file by description |
| `/peek` | Reopens the last file |
| `/peek-menu` | Command menu: every action in the current view with its key, plus recent files |
| `/peek-ui` | A live gallery of every UI element a mod can draw |

In the pane: `j`/`k` jump between blocks (on a page with task rows they move
between rows, and `n`/`m` jump between blocks), the wheel scrolls, `r` shows recent
files, `o` opens the file in its own app (a remote page in the browser), `c`
copies the path or link, `u` refreshes a remote page, `b` goes back to the page
you came from, `v` switches a web page to live view, `e` shows groups, `x`
closes. On tasks, `w` changes the status, `y` switches a block's layout and `z`
folds a parent (see Tasks). In Recent, Gallery and Groups, `j`/`k`/`h`/`l` move the selection, `o`
opens it and `f` stars it; in Gallery, `t` and `n` change the file type and the
sort order.

The footer shows only the page status and `⌃k menu`. The keys are not drawn,
but they all work. Open the menu (Ctrl+K, Setup step 2) to see each action
that applies to the current view, with its key.

## Setup

1. Turn on function hooks, which mods need. Add to `~/.claude/settings.json`:

   ```json
   { "env": { "CLAUDE_CODE_ENABLE_FUNCTION_HOOKS": "1" } }
   ```

2. Optional, to open the command menu with Ctrl+K while the pane has focus,
   add this to `~/.claude/keybindings.json`:

   ```json
   { "bindings": [{ "context": "Pane", "bindings": { "ctrl+k": "command:peek-menu" } }] }
   ```

3. Optional, to draw Mermaid diagrams: `go install github.com/AlexanderGrooff/mermaid-ascii@latest`,
   then put the binary at `~/.cache/claude-peek/bin/mermaid-ascii`.

4. Optional, to draw images through a multiplexer such as herdr or tmux, add
   `"CLAUDE_CODE_FORCE_TERMINAL_IMAGES": "1"` to the same `env` block. Use a
   terminal with kitty graphics (Ghostty, kitty).

## Requirements

macOS: image conversion uses `sips` and `rsvg-convert`, and Open uses `open`.
Live view needs the Xcode command-line tools (`swiftc`).
Web reader pages are cleaned with [Defuddle](https://github.com/kepano/defuddle), which strips menus, footers and other page chrome. Up to 8 of the page's images show inline; a video shows its thumbnail and a Play button that opens it in your browser. Peek installs a pinned copy with npm on first use into `~/.cache/claude-peek/` (needs Node). Without it, peek falls back to its own simpler cleanup.

## Development

```
claude plugin validate .
claude plugin test .
python3 tests/mirror-skill-examples.py --check
```

The test sandbox cannot read JSON or markdown files, so two fixtures are copies:
`tests/fixtures/skill-examples.ts` holds the skill's examples, and
`tests/fixtures/plugin-shape.ts` holds the skills' names, the `peek-recipes`
skill and the agents. After you edit an example, a skill or an agent, run
`python3 tests/mirror-skill-examples.py` to rewrite both. `--check` fails when
a copy is out of date or when an example's output no longer equals its sample
page.
