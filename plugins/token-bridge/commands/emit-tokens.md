---
description: "Emit a CSS file from a Paper file's design tokens — the reverse of sync (Paper → code)"
argument-hint: "--repo <path> (reads the target Paper fileId + emitTarget from the codebase's token-bridge.config.json)"
---

# Emit Paper tokens to CSS

Read the configured Paper file's tokens and write them back out as a CSS file: a base `:root { … }` block plus a dark override block in the codebase's declared theme convention (data-attribute or media-query). The `-dark` twins Paper stores are re-expanded into the dark scope, and alias referents are de-suffixed so the emitted CSS references real properties.

The target Paper file and the output path (`emitTarget`) come from the target codebase's `token-bridge.config.json` (found via `--repo`). Emit refuses to write in place over a source that declares more than one theme convention — that would drop the non-primary block. The round-trip is stable: CSS emitted from a file already in sync with its source re-parses to the same token model.

Use the Skill tool to invoke: `emit-tokens`
