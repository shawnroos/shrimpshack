---
name: sync-tokens
description: >
  Sync WCS --wcs-* design tokens from the merged develop SCSS into a Paper design file.
  Use when someone asks to sync WCS tokens to Paper, update the Paper design tokens, or
  reconcile the Paper file with the shipped design system. Reads source from origin/develop
  and the target Paper fileId from wcs-paper.config.json; the reconcile is idempotent.
allowed-tools: Bash, Read
---

# Sync WCS tokens to Paper

The script owns the reconcile end-to-end. Your job is to run it and relay its JSON report — do not re-derive, re-order, or second-guess its decisions.

## Workflow

1. Run the deterministic sync script. With no arguments it reads the target `fileId` from `wcs-paper.config.json`, reads both source SCSS files from the merged `origin/develop` ref, parses + classifies the tokens, diffs the desired set against the live Paper file, applies the minimal reconcile, and prints a JSON report:

   ```bash
   python3 "${CLAUDE_PLUGIN_ROOT}/lib/sync_tokens.py"
   ```

   To preview the reconcile without writing anything — worth doing before the first sync into a file, since the reconcile is destructive — pass `--no-apply`: it reports the same `created`/`updated`/`deleted`/`recreated`/`declined` diff but makes no changes.

2. Read the exit code and the JSON report on stdout:
   - **Exit 2 (refused):** `wcs-paper.config.json` has no `fileId`. The report's `error` field carries an actionable message — surface it verbatim and stop. Never guess or substitute a target file; the reconcile deletes tokens absent from source, so targeting the wrong file is destructive.
   - **Exit 4 (error):** a git read, the Paper daemon, or an apply step failed. Relay the `error` / `envelope` so the cause is visible (e.g. daemon not running).
   - **Exit 0 (ok):** report the outcome from the fields below.

3. Relay the report fields: `created`, `updated`, `deleted`, `recreated` (token names), `declined` (tokens Paper cannot represent — shadows, motion, filters — each with a `reason`), and `empty` (true when the source already matched the file, i.e. a no-op re-run). A `recreated` entry is a delete-then-create pair because Paper cannot change a token's type in place.

## What the script writes

Each theme is written as a separately named Paper token (Paper has no per-file theme mode):

- The **light** value keeps the token's own name (`--wcs-accent`).
- The **dark** value of a theme-varying token gets a `-dark` twin (`--wcs-accent-dark`). Mode-invariant tokens are written once, with no twin.
- Tier-2 tokens are written as `var(--wcs-*)` aliases, not resolved hex. A dark twin's alias references the dark counterpart (`var(--wcs-accent-dark)`).
- The `--font-family` token (from `_general.scss`) is written at type `fontFamily`.

Re-running against an unchanged source produces an empty diff and zero writes (idempotent).
