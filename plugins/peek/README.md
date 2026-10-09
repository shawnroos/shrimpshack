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

## Remote pages

Links and IDs in replies become clickable: GitHub URLs, `owner/repo#12`, `#12`
inside a GitHub repo, Linear URLs, and Linear IDs such as `WEB-2757` when
`WEB` is a team in your workspace. Peek is read-only: it never changes
anything in GitHub or Linear.

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

## Commands

| Command | Does |
|---|---|
| `/peek <path or URL>` | Opens it |
| `/peek WEB-2757` or `/peek owner/repo#12` | Opens a Linear or GitHub item |
| `/peek the export diagram` | Finds a recent file by description |
| `/peek` | Reopens the last file |
| `/peek-menu` | Command menu: switch view, scroll, open, copy, recent files |
| `/peek-ui` | A live gallery of every UI element a mod can draw |

In the pane: `j`/`k` jump between blocks, the wheel scrolls, `r` shows recent
files, `o` opens the file in its own app (a remote page in the browser), `c`
copies the path or link, `u` refreshes a remote page, `b` goes back to the page
you came from, `v` switches a web page to live view, `x` closes.

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
