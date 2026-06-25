---
description: One-time opt-in setup for the reflect plugin — migrate an existing MEMORY.md to the budgeted pointer index, patch the Memory Protocol in your CLAUDE.md, and create the QMD collections. Idempotent and backs up before editing.
---

Run the reflect plugin's opt-in setup. The plugin's hooks (seeded recall + reflect triggers) are already wired automatically from the manifest — this command only performs the invasive one-time live edits, which the plugin deliberately does NOT do on its own.

Run it:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup.sh"
```

It is idempotent (safe to re-run) and conservative:
- migrates an existing `MEMORY.md` to the one-line-per-memory budgeted format, backing up to `MEMORY.md.pre-qmd-migration.bak`;
- patches the `## Memory Protocol` section of your `~/.claude/CLAUDE.md`, backing it up first and skipping if the section structure is ambiguous;
- scaffolds `~/.claude/doc-store/` and creates + embeds the `claude-*` QMD collections.

After it runs, report what changed (index size before/after, whether the protocol was patched or skipped, collections created). If `qmd` isn't installed, the collection step is a clean no-op and search-based recall stays dormant until you install it — everything else still works.
