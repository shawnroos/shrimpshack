# Peek page vocabulary: full reference

This file states every field peek accepts. It follows the validator in
`plugins/peek/hooks/page.ts` (`validatePage`, `validateRecipe`). Peek rejects
any key that is not listed here. `?` marks an optional field.

## Page

```
Page    = { title, details?, sections, actions? }
Detail  = { label, value }
Section = { heading?, block }
Block   = markdown | media | table | cards | list | fields
Action  = { label, open } | { label, copy }
```

| Field | Type | Cap |
|---|---|---|
| `title` | text, one line, required | 200 characters |
| `details` | list of Detail | 20 rows |
| `Detail.label` | text, one line, required | 200 |
| `Detail.value` | text, one line, required | 1000 |
| `sections` | list of Section, required (it can be empty) | 30 sections |
| `Section.heading` | text, one line | 200 |
| `actions` | list of Action | 9 actions |
| `Action.label` | text, one line, required | 200 |
| `Action.open` | a link (see the link rule) | 2048 |
| `Action.copy` | text, one line, required; a newline is refused | 500 |

An Action has exactly one of `open` or `copy`.

## Blocks

Each block is an object with `type` plus the keys below, and no other keys.

| `type` | Keys | Item shape | Takes focus |
|---|---|---|---|
| `markdown` | `text` | text, required, up to 100,000 characters, newlines kept | no |
| `media` | `items` | `{ url, alt?, kind }`, `kind` is `"image"` or `"video"` | no |
| `table` | `columns`, `rows` | columns: list of text (up to 12, 200 each); row: `{ cells, href? }` | each row |
| `cards` | `items` | `{ title, meta?, href?, image? }` | each card |
| `list` | `items` | `{ title, meta?, href? }` | each item |
| `fields` | `rows` | `{ label, value }`, the same as a Detail | no |

- At most 200 items or rows per block.
- `title` is up to 200 characters. `meta`, `alt`, a table cell and a field value are up to 1000.
- A table row has exactly one cell per column. A cell can be an empty string.
- `media.url` and `cards.image` must be http(s) addresses. They cannot be file paths.
- An item without `href` still takes focus, but enter does nothing on it.

## Text rules

- Peek removes control characters and bidirectional-override characters from all text. It keeps zero-width joiners.
- In one-line fields, tab, CR, LF, U+2028 and U+2029 become a space. Markdown keeps its newlines and tabs.
- Text that is empty after this cleaning counts as missing.
- Text over its cap is refused with its length. Peek never cuts it short. Shorten it in the source.

## Link rule

One rule applies to `href`, `Action.open` and every link found inside markdown.

- **Allowed:** an `http` or `https` link to a public host, or an absolute file path that starts with `/`.
- **Refused:**
  - a private host: `localhost`, `*.local`, `*.localhost`, and private, loopback or link-local IP addresses, including numeric spellings;
  - `file://` and every other scheme;
  - relative paths;
  - a path with a segment that starts with `.` (dot-folders, dotfiles, `..`);
  - a path with a segment ending in `.app`, `.command`, `.terminal` or `.workflow`.
- Peek scans markdown for inline links `[x](target)`, reference definitions `[x]: target`, autolinks `<scheme:...>`, `href=` and `src=` in HTML, and bare `http(s)://` text. It scans code spans and fences too. One bad link fails the whole markdown block, and the problem names that link.
- A link opens through peek's normal routing. It can open a built-in page (GitHub, Linear, Slack), another recipe's page, a file, or the web reader.

## How peek draws a page

- The title and Details come first, then each Section with its heading as a rule, then its block.
- Arrow keys and `j`/`k` move through one list: every card, list item and table row, section by section. Markdown, media and fields scroll with the page.
- Enter opens the selected item's `href`. `b` goes back. `f` stars an item with an `href`.
- Each Action gets the key `1` to `9` in order, and shows in the ⌃k menu with its label.
- `copy` copies the whole text and shows a short notice.
- Markdown draws like peek's remote pages: headings, code, mermaid fences, and `![alt](url)` pictures. Badges stay as text.
- Pictures share the pane's image budget. Peek downloads at most 12 pictures per page. Pictures past the budget, and pictures that fail to download, show as links. A video shows a Play button that plays its `url` in the pane through the live view, sound included, where the terminal draws images (kitty, Ghostty), and opens it in the browser elsewhere. `b` or `v` stops it and shows the page again. Give a page that plays the video, such as a YouTube watch page: YouTube's `/embed/` player refuses to play as a whole page.
- An empty block shows "Nothing in this section." A page with no sections shows "This page has no sections."

## Recipe folder

```
~/.local/share/claude-peek/recipes/<id>/
  recipe.json
  <script>            (script sources only)
```

- `<id>` is the folder name: 1 to 40 characters of `a-z`, `0-9` and `-`. Do not put `id` in recipe.json, because it is an unknown key there.
- A folder holds at most 50 files and 50 subfolders. Each file is at most 4 MiB. Peek refuses symlinks and special files.
- Peek hashes every file in the folder, dotfiles included. Any change to any file, or a new empty folder, makes the recipe a draft again. A marker file such as `.approved` has no effect.

## recipe.json

```
{ name, match, overrides?, source, refreshMinutes? }
```

| Field | Rule |
|---|---|
| `name` | text, one line, required, up to 80 characters. Peek shows it on the loading page, the error page and the approval surface. |
| `match` | 1 to 20 entries of `{ host, path? }` |
| `match[].host` | A host name with at least two labels, such as `figma.com`, or `*.figma.com`. It is lowercased. `*.com` and `fig*.com` are refused. |
| `match[].path` | Starts with `/`, up to 200 characters. `*` is the only wildcard. `?`, `#`, `[`, `]`, `{`, `}` and spaces are refused. |
| `overrides` | A list of `"github"`, `"linear"`, `"slack"`. Default `[]`. |
| `source` | Exactly one of a script source or an MCP source (below) |
| `refreshMinutes` | `0` (the default: no timer), or 5 to 1440 |

### Matching

- An exact host matches only that host. `figma.com` does not match `www.figma.com`. List both when the site serves on both.
- `*.figma.com` matches any subdomain at any depth, but not `figma.com` itself.
- A trailing dot on the link's host is ignored.
- No `path` matches every path. In a path, `*` matches any run of characters, `/` included. A path without `*` must equal the link's path exactly, as the link spells it (percent-encoded).
- Peek ignores the query and the fragment.
- Peek matches the link as it was typed. It does not add or remove `www.`.

### Routing

- A link that a built-in page handles (GitHub, Linear, Slack) stays on the built-in page unless the recipe lists that family in `overrides`.
- A matching recipe always wins over the generic web reader.
- Normal opens use approved recipes only. When two approved recipes claim one link, peek shows an error page naming both. `check_recipe` fails a recipe whose matches overlap any other recipe, drafts included.

### Script source

```
"source": { "run": ["./script", "arg", ...], "timeoutSeconds": 20, "env": ["NAME"] }
```

- `run[0]` starts with `./`, names a regular file inside the folder, and has no `..`. Peek runs it directly, so it needs a `#!` line and the executable bit (`chmod +x`).
- `run` has up to 20 arguments, each up to 1000 characters with no control characters.
- Peek appends the link as the last argument.
- The working directory is the recipe folder's real path.
- The environment holds only `HOME`, `PATH`, `LANG`, `TMPDIR`, `PEEK_URL` (the link) and the names in `env`. Those four and `PEEK_URL` cannot be replaced through `env`.
- `env` lists up to 20 names matching `[A-Za-z_][A-Za-z0-9_]*`. Peek passes the value from its own environment. It removes those values from any error text it shows.
- `timeoutSeconds` is 1 to 60. The default is 20.
- stdout must be one Page as JSON. stderr shows on the error page when the exit code is not 0 (up to 500 characters).
- **Never write into the recipe folder.** Peek hashes the folder again after the run. A write there discards the page and makes the recipe a draft. Write scratch files under `$TMPDIR`.

### MCP source: fetch, then map

```
"source": { "mcp": { "server": "name", "tool": "tool_name", "args": { "id": "{{url}}" } }, "map": ["./map.py"], "timeoutSeconds": 20, "env": ["NAME"] }
```

An MCP tool returns its own data, never a Page. Peek calls the tool, then runs
your map script on the tool's result, and the map script prints the Page. Peek's
built-in pages work the same way: the Slack page calls `slack_read_thread` and
parses its text, and the GitHub and Linear pages map the JSON their tools return.

- `server` is the MCP server name as Claude Code knows it. It can contain spaces, for example `claude.ai Notion`.
- `tool` is 1 to 64 characters of `A-Z a-z 0-9 _ . -`.
- `args` is an object, at most 4000 characters as JSON. Peek replaces `{{url}}` with the link in every string, at any depth.
- `map` is required. It follows every rule of a script source's `run`: `map[0]` starts with `./` and names a regular file inside the folder, it needs a `#!` line and `chmod +x`, it gets the link as its last argument and in `PEEK_URL`, it runs in the recipe folder with only the script environment, and it must never write into the folder.
- `env` names variables for the map script, as for a script source. The tool itself gets no environment.
- `timeoutSeconds` is one limit for both steps: the tool call and the map run share it.
- A tool name with a word such as create, update, delete, send, post, set, close or merge gets a warning. A recipe only reads.
- The recipe works only in sessions where that server is connected. Elsewhere its links show the error page.
- For a draft, the session must allow both steps: the tool, as `mcp__<server>__<tool>` (each character of the server name outside `A-Z a-z 0-9 _ -` becomes `_`), and the map, as a Bash rule on its absolute path. Peek checks both before it runs either.

**The map's stdin.** Peek writes exactly one JSON object, then a newline:

```
{"text": <the tool's text content blocks joined with "\n", or "">, "structured": <the tool's structuredContent, or null>}
```

- `text` joins only the text blocks. Images and other blocks are dropped. Many tools put JSON inside `text`, so the map parses it a second time (`json.loads(source["text"])`).
- `structured` is `null` when the tool has no structured content.
- When the tool returns no text and no structured content, the map does not run, and the result is `empty-result`.

**Writing the map: sample, map, test locally, check.**

1. Call the MCP tool yourself, with the recipe's arguments and a real sample link. The `peek-recipes` skill does this step before it dispatches the builder agent, which cannot call other MCP tools.
2. Save its result in the stdin shape as `$TMPDIR/sample.json`: the tool's text in `text`, its structured content (or `null`) in `structured`. For example, with the tool's text saved as `$TMPDIR/tool.txt`: `python3 -c 'import json,sys; print(json.dumps({"text": sys.stdin.read().rstrip("\n"), "structured": None}, separators=(",", ":"), ensure_ascii=False))' < $TMPDIR/tool.txt > $TMPDIR/sample.json`.
3. Write `map.py` with only the `python3` standard library. It reads stdin and prints one Page.
4. From the recipe folder, run `python3 map.py < $TMPDIR/sample.json` until it prints a valid Page.
5. Run `check_recipe`. When the map fails there, `fetched.stdin` holds the exact stdin peek gave it (declared env values redacted, cut at 8000 characters). If it differs from your sample, save it as the new sample and go back to step 4.

`examples/notion-pages/` is a complete MCP recipe. `examples/notion-pages.sample.json`
is a made-up sample in the shape the Notion MCP server's `notion-fetch` tool returns,
saved as map stdin, and `examples/notion-pages.page.json` is what `map.py` prints for it.

## Failures

When a source fails, peek shows an error page that names the recipe and the problem. It never falls back to the web reader. `check_recipe` reports the same kinds:

| Kind | Cause |
|---|---|
| `invalid-recipe` | The folder no longer loads, or `run[0]` or `map[0]` is not a regular file inside the folder |
| `changed-during-run` | The folder changed before or while the source ran |
| `needs-permission` | A draft asked to run something this session's permissions do not allow |
| `started-failed` | Peek could not start the process at all |
| `timeout` | The source ran past `timeoutSeconds`. For an MCP source, the tool call and the map share that limit. |
| `exit-nonzero` | The script or map exited with a code other than 0. For a map, `fetched.stdin` holds its input. Exit 126 with `Permission denied` means the script lacks `chmod +x`. Exit 127 means the `#!` interpreter was not found on `PATH`. |
| `output-truncated` | stdout was too large |
| `not-JSON` | The script or map printed nothing, or something that is not JSON. For a map, `fetched.stdin` holds its input. |
| `server-not-connected` | The MCP call was refused, usually because the server is not connected |
| `tool-error` | The MCP tool returned an error |
| `empty-result` | The MCP tool returned no text and no structured content, so the map did not run |
| `invalid-page` | The JSON is outside this vocabulary. `problems` names each path, such as `sections[0].block.type`; what each problem says quotes the page, so it is under `fetched.problems`. For a map, `fetched.stdin` holds its input. |
