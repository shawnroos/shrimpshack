---
description: "Normalize the code to the design — write the Paper file's tokens back out as CSS (design is source of truth)"
argument-hint: "--repo <path> (reads the target Paper fileId + emitTarget from the codebase's token-bridge.config.json)"
---

# Normalize the code to the design

Design is the source of truth. Read the connected Paper file's tokens and write them back out as a CSS file: a base `:root { … }` block plus a dark override block in the codebase's declared theme convention (data-attribute, media-query, class, or file — a `file` convention writes TWO files, base and dark, or refuses). The `-dark` twins Paper stores are re-expanded into the dark scope, and alias referents are de-suffixed so the emitted CSS references real properties.

The target Paper file and the output path (`emitTarget`) come from the target codebase's `token-bridge.config.json` (found via `--repo`, written by `connect`). It refuses to write in place over a source that declares more than one theme convention — that would drop the non-primary block. The round-trip is stable: CSS emitted from a file already in sync with its source re-parses to the same token model.

Use the Skill tool to invoke: `normalize-to-design`
