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
| Web pages | The page text |

## Commands

| Command | Does |
|---|---|
| `/peek <path or URL>` | Opens it |
| `/peek the export diagram` | Finds a recent file by description |
| `/peek` | Reopens the last file |
| `/peek-menu` | Command menu: switch view, scroll, open, copy, recent files |
| `/peek-ui` | A live gallery of every UI element a mod can draw |

In the pane: `j`/`k` jump between blocks, the wheel scrolls, `r` shows recent
files, `o` opens the file in its own app, `c` copies the path, `x` closes.

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

## Development

```
claude plugin validate .
claude plugin test .
```
