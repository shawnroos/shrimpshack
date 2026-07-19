---
name: connect
description: >
  Connect a codebase to a Paper file by scaffolding its token-bridge.config.json.
  Use when someone wants to set up token-bridge for a repo, bind a codebase to a Paper
  design file, or start syncing a new project's tokens with Paper. References an existing
  Paper file (by id or URL) or creates a new one via the daemon; refuses to overwrite an
  existing config unless forced.
allowed-tools: Bash, Read
---

# Connect a repo to a Paper file

The script writes the config; your job is to gather the inputs, run it, and relay its JSON report. This is the one-time bootstrap the other commands depend on.

## What you need first

- **`--repo`** — the target codebase root (the config is written here).
- **`--source`** — the CSS/SCSS file the tokens live in, relative to `--repo`.
- **A target Paper file** — EITHER `--file <id-or-URL>` to bind an existing file, OR `--create-file` (with an optional `--name`) to create a fresh one via the daemon.
- Optional: `--prefix` (custom-property namespace, e.g. `--brand-`; omit for all), `--emit-target` (Paper→CSS output; defaults to `<source>.generated.<ext>`), and the theme convention: `--convention data-attribute --attr data-theme --value dark` (default), `--convention media-query --query "(prefers-color-scheme: dark)"`, or `--convention class --class wcs-dark`.

If the user hasn't given the Paper file, ask whether to reference an existing one (get its id or URL) or create a new one.

## Workflow

1. Run the connect script:

   ```bash
   # reference an existing file
   python3 "${CLAUDE_PLUGIN_ROOT}/lib/connect.py" --repo /path/to/codebase \
     --source src/styles/tokens.css --prefix=--brand- \
     --file https://app.paper.design/file/<fileId>/1-0

   # or create a new file
   python3 "${CLAUDE_PLUGIN_ROOT}/lib/connect.py" --repo /path/to/codebase \
     --source src/styles/tokens.css --create-file --name "My Design System"
   ```

   Note: a `--prefix` value that starts with `--` must use the `=` form (`--prefix=--brand-`).

2. Read the exit code and JSON report:
   - **Exit 0 (ok):** report `configPath`, `fileId`, `created` (true when a new Paper file was made), `source`, `emitTarget`, and `convention`.
   - **Exit 3 (config_exists):** a config is already there — surface the path and offer `--force` to overwrite.
   - **Exit 2 (bad args):** e.g. neither/both of `--file`/`--create-file`, a media-query convention with no `--query`, or a class convention with no `--class`. Relay the `note`.
   - **Exit 4 (error):** daemon `create_file` failed or the write failed. Relay it.

3. After a successful connect, the natural next step is `status` (see where code and design stand) or a first `normalize-to-code` to seed the Paper file from the codebase.
