---
argument-hint: <mode-name>
allowed-tools: Bash
---

Set the active mode for the current branch in the current repo. Writes
the compiled cascade output to `<repo>/.claude/settings.local.json`. Run
`/reload-plugins` after to activate the new plugin set.

The orchestration runs the cascade engine (tiers 1+2+3+4 merge), rebuilds
the user-catalog symlinks for the mode's authored manifest, writes the
per-branch state file at `<repo>/.claude/modes/<branch-slug>.mode`, and
updates the user-global pointer at `~/.claude/modes/.last-active-mode`.

R26 crash-safety: a sentinel at `~/.claude/modes/.mode-set.in-progress`
guards the orchestration. If a previous `/mode:set` was interrupted, a
re-run with the same target resumes idempotently; a re-run with a
different target replaces the stale sentinel and proceeds.

Usage: `/mode:set <mode-name>`

To return to the no-modes-active state ("Claude Mode"), use `/mode:clear`.

`bash ${CLAUDE_PLUGIN_ROOT}/lib/set-mode.sh "$ARGUMENTS"`
