---
name: normalize-to-code
description: >
  Normalize the design to the code: fix the Paper file's tokens to match the
  codebase's CSS custom properties (code is the source of truth). Use when someone
  asks to push code tokens to Paper, make the design match the code, sync tokens to
  Paper, or reconcile a Paper file with a codebase's design system. Reads the source
  path, prefix, theme conventions, and target Paper fileId from the codebase's
  token-bridge.config.json (found via --repo); the reconcile is idempotent.
allowed-tools: Bash, Read
---

# Normalize the design to the code

Code is the source of truth: this rewrites the Paper file's tokens to match the codebase. (Runs the token-sync reconcile.)

The script owns the reconcile end-to-end. Your job is to run it and relay its JSON report — do not re-derive, re-order, or second-guess its decisions.

## Workflow

1. Run the deterministic sync script, pointing it at the target codebase with `--repo`. It reads that codebase's `token-bridge.config.json` for the target `fileId`, the CSS source path (a working-tree file by default, or a git ref when the config's `source.ref` is set), the prefix, and the theme conventions. It then parses + classifies the tokens, diffs the desired set against the live Paper file, applies the minimal reconcile, and prints a JSON report:

   ```bash
   python3 "${CLAUDE_PLUGIN_ROOT}/lib/sync_tokens.py" run --repo /path/to/codebase
   ```

   To preview the reconcile without writing anything — worth doing before the first sync into a file, since the reconcile is destructive — pass `--no-apply`: it reports the same `created`/`updated`/`deleted`/`recreated`/`declined` diff but makes no changes. Pass `--url` to override the daemon URL from config.

2. Read the exit code and the JSON report on stdout:
   - **Exit 2 (refused):** the config is missing, invalid, or has no `fileId`. The report's `error` field carries the machine code (`no_config` / `bad_config` / `no_target_file`) and `note` an actionable message — surface `note` verbatim and stop. Never guess or substitute a target file; the reconcile deletes tokens absent from source, so targeting the wrong file is destructive.
   - **Exit 4 (error):** the source read (file or git ref), the Paper daemon, or an apply step failed. Relay the `error` / `envelope` so the cause is visible (e.g. daemon not running, source path wrong).
   - **Exit 0 (ok):** report the outcome from the fields below.

3. Relay the report fields: `created`, `updated`, `deleted`, `recreated` (token names), `declined` (tokens Paper cannot represent — shadows, motion, filters — each with a `reason`), and `empty` (true when the source already matched the file, i.e. a no-op re-run). A `recreated` entry is a delete-then-create pair because Paper cannot change a token's type in place.

## What the script writes

v1 is base + a single "dark" theme (its dark scope declared by the config's `themeConventions` — a `data-attribute` or `media-query` convention). Each theme is written as a separately named Paper token (Paper has no per-file theme mode):

- The **base** (light) value keeps the token's own name (`--accent`).
- The **dark** value of a theme-varying token gets a `-dark` twin (`--accent-dark`). Mode-invariant tokens are written once, with no twin.
- Tier-2 tokens are written as `var(--*)` aliases, not resolved hex. A dark twin's alias references the dark counterpart (`var(--accent-dark)`).
- Only custom properties matching the config's `source.prefix` are included (all of them when no prefix is set). A font-stack value is written at type `fontFamily`.

Re-running against an unchanged source produces an empty diff and zero writes (idempotent).
