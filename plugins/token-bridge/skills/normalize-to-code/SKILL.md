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

   To preview the reconcile without writing anything, pass `--no-apply`: it reports the same `created`/`updated`/`recreated`/`prunable`/`declined` diff but makes no changes. Pass `--url` to override the daemon URL from config.

2. Read the exit code and the JSON report on stdout:
   - **Exit 2 (refused):** the report's `error` field carries the machine code and `note` an actionable message — surface `note` verbatim and stop. Codes: `no_config` / `bad_config` / `no_target_file` (config problems); `unresolved_imports`; `theme_file_unreadable`; `empty_parse` (the source parsed to zero tokens while owned tokens are live — reported so a truncated source cannot produce a whole-file `prunable` list). Never guess or substitute a target file.
   - **Exit 4 (error):** the source read (file or git ref), the Paper daemon, or an apply step failed. Relay the `error` / `envelope` so the cause is visible (e.g. daemon not running, source path wrong).
   - **Exit 0 (ok):** report the outcome from the fields below.

3. **This never deletes.** A run creates, updates, and recreates retyped tokens — nothing is removed. A live token absent from the source is reported under `prunable`: a list for the user to act on in Paper, never an action this tool takes.

   Relay these report fields:
   - `created`, `updated`, `recreated` (token names). A `recreated` entry is a delete-then-create pair, because Paper cannot retype in place — any Paper-side field this tool does not model (a hand-written description) does not survive it.
   - **`prunable`** — live tokens absent from this parse. **These were NOT removed.** Surface them so the user can decide, and tell them removal is a manual step in Paper. Never call them deleted.
   - `parseComplete` — false when the parser could not read the whole source (an unresolved or not-followed import). When false, warn that `prunable` may list tokens the user did not remove, and that values may be stale — do not encourage acting on `prunable` until it reads whole.
   - `stillDeclared` — `prunable` names still declared somewhere the sync does not read, such as a component rule. **Warn the user NOT to hand-delete these** — they are in use (a move, not a retirement), and removing them in Paper would break the component that still references them.
   - `declined` — tokens Paper cannot represent (shadows, motion, filters), each with a `reason`.
   - `pinnedByComment` — a `prunable` name whose declaration exists only inside a comment. Commenting a token out does NOT retire it; say so.
   - `empty` — true when the source already matched the file (a no-op re-run).

   **You cannot delete tokens through this tool. Do not offer to.** If the user wants a token gone, tell them to remove it in Paper; `prunable` is the list.

## What the script writes

v1 is base + a single "dark" theme (its dark scope declared by the config's `themeConventions` — a `data-attribute`, `media-query`, `class`, or `file` convention (the last reads the dark theme from a separate file)). Each theme is written as a separately named Paper token (Paper has no per-file theme mode):

- The **base** (light) value keeps the token's own name (`--accent`).
- The **dark** value of a theme-varying token gets a `-dark` twin (`--accent-dark`). Mode-invariant tokens are written once, with no twin.
- Tier-2 tokens are written as `var(--*)` aliases, not resolved hex. A dark twin's alias references the dark counterpart (`var(--accent-dark)`).
- Only custom properties matching the config's `source.prefix` are included (all of them when no prefix is set). A font-stack value is written at type `fontFamily`.

Re-running against an unchanged source produces an empty diff and zero writes (idempotent).
