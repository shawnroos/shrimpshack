---
name: normalize-to-design
description: >
  Normalize the code to the design: fix the codebase's CSS to match the Paper file's
  tokens (design is the source of truth). Use when someone asks to make the code match
  the design, pull Paper's tokens back into code, write Paper's tokens to CSS, or export
  design tokens from Paper. Reads the target Paper fileId, the output path (emitTarget),
  the prefix, and the theme conventions from the codebase's token-bridge.config.json
  (found via --repo).
allowed-tools: Bash, Read
---

# Normalize the code to the design

Design is the source of truth: this writes the Paper file's tokens back out as CSS at the configured `emitTarget`. (Runs the Paper → CSS emitter.)

The script owns the inversion end-to-end. Your job is to run it and relay its JSON report — do not hand-assemble the CSS.

## Workflow

1. Run the deterministic emit script, pointing it at the target codebase with `--repo`. It reads that codebase's `token-bridge.config.json` for the source Paper `fileId`, the output `emitTarget` path, the prefix, and the theme conventions, calls `get_tokens`, inverts the `-dark` twin + alias scheme, and writes the CSS:

   ```bash
   python3 "${CLAUDE_PLUGIN_ROOT}/lib/emit_tokens.py" run --repo /path/to/codebase
   ```

   Pass `--url` to override the daemon URL from config.

2. Read the exit code and the JSON report on stdout:
   - **Exit 2 (refused):** the config is missing, invalid, or has no `fileId` — the `error` field carries the code (`no_config` / `bad_config` / `no_target_file`) and `note` an actionable message. Surface `note` and stop.
   - **Exit 4 (error):** the daemon failed, no `emitTarget` is configured, or an in-place emit onto a dual-convention source was refused (`refused_in_place_dual_convention` — point `emitTarget` at a distinct file). Relay the `error`/`note`.
   - **Exit 0 (ok):** report `emitTarget` (the file written), `tokenCount`, and `bytes`.

## What the script writes

- A base `:root { … }` block from the base tokens (values kept as-is, including `var(--*)` aliases — never resolved to a literal).
- A dark override block for the `-dark` twins, in the config's **primary** convention: `:root[data-theme="dark"] { … }` for a data-attribute convention, or `@media (query) { :root { … } }` for a media-query one. The `-dark` suffix is stripped from both the property name and any `var(--…-dark)` alias referent.
- A token with no `-dark` twin is emitted base-only.

## Round-trip stability

CSS emitted from a Paper file that is already in sync with its source, when parsed back and rebuilt into the desired Paper set, yields an identical token model — no churn. The fixed point is at the token-model level, not the CSS string, because Paper re-serializes values on store. (Proven offline by `emit_tokens.py roundtrip`.)
