# peek

A side pane for Claude Code that shows the files and links in a conversation.
Click a path or URL in a reply, or run `/peek`, and the file opens beside the
transcript.

## What it shows

| File | In the pane |
|---|---|
| Markdown | One scrolling page with styled headings, quotes, code, diagrams, images and clickable tasks |
| Code | Syntax colours and line numbers |
| Images (PNG, JPG, GIF, WebP, HEIC, SVG) | The picture, on terminals that draw images |
| Mermaid (`.mmd`, or fenced in markdown) | Drawn as text boxes and arrows when `mermaid-ascii` is installed |
| Folders | A clickable file list |
| Web pages | Open Graph title, description and preview image, the site's favicon, then the page text |
| GitHub pull requests | Details, line counts, files changed, a CI summary, the description and comments |
| GitHub issues and repos | Details, the body or README, comments, and a repo's open pull requests and issues |
| Linear issues and projects | Details, the description, comments with replies, and a project's open issues |
| A link to a file (`.md`, `.png`, `.json`, `.csv`, code, ...) | Downloaded and drawn like the local file; `o` and `c` still use the link |
| A link to a video (`.mp4`, `.webm`, `.mov`) | A Play button that opens it in your browser |

## Remote pages

Links and IDs in replies become clickable: GitHub URLs, `owner/repo#12`, `#12`
inside a GitHub repo, Linear URLs, and Linear IDs such as `WEB-2757` when
`WEB` is a team in your workspace. Peek is read-only: it never changes
anything in GitHub or Linear.

Pictures, videos and Mermaid diagrams in a pull request, issue or Linear
description or comment draw the same way as on a web page: up to 8 pictures
inline, a video as its thumbnail and a Play button. A picture that cannot be
downloaded, such as an attachment in a private repo, stays a link.

Each page comes from the best source available, and the footer names it:

| Source | Used for | Needs |
|---|---|---|
| `gh` | GitHub items | `gh auth login` |
| `curl` | Web pages and their images | `curl` on the path |
| Linear API | Linear items | `LINEAR_API_KEY` in the environment or `~/.secrets`, or the `work-linear` Keychain item |
| This session | Anything the agent already read through a GitHub, Linear or web tool | Nothing |

Open issues and pull requests on screen refresh every 60 seconds. Open ones in
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
description and can split its items into sections. Each section shows its
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
- `f` on a card stars the group. Up to 4 starred groups sit at the top of
  Recent, above Favourites, whatever the scope and filter, as the same cards,
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

## Commands

| Command | Does |
|---|---|
| `/peek <path or URL>` | Opens it |
| `/peek WEB-2757` or `/peek owner/repo#12` | Opens a Linear or GitHub item |
| `/peek the export diagram` | Finds a recent file by description |
| `/peek` | Reopens the last file |
| `/peek-menu` | Command menu: every action in the current view with its key, plus recent files |
| `/peek-ui` | A live gallery of every UI element a mod can draw |

In the pane: `j`/`k` jump between blocks, the wheel scrolls, `r` shows recent
files, `o` opens the file in its own app (a remote page in the browser), `c`
copies the path or link, `u` refreshes a remote page, `b` goes back to the page
you came from, `v` switches a web page to live view, `e` shows groups, `x`
closes. In Recent, Gallery and Groups, `j`/`k`/`h`/`l` move the selection, `o`
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
```
