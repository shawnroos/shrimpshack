---
argument-hint: [--new]
allowed-tools: Bash
---

List all globally-defined modes at `~/.claude/modes/*.yaml` with their
metadata (schema_version, description, plugin/user-catalog counts, prose
layer presence).

Framework files (`_global.yaml`, `_repo.yaml`) are excluded — those are
the tier-2/tier-4 baselines of the cascade, not modes you can `/mode:set`.

Subcommands:

- (no args) — print the registry summary.
- `--new`   — print a pointer at the mode-author skill. Mode authoring
  is a conversational flow; this command surfaces the entry instructions
  rather than invoking the skill from a shell context.

To dispatch, run:

`bash ${CLAUDE_PLUGIN_ROOT}/lib/registry.sh "$ARGUMENTS"`
