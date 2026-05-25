---
argument-hint: <file>
allowed-tools: Bash
---

Scope a user-authored command or agent to the currently active mode.

`/mode:adopt <file>` moves the file into the cascade's user-catalog
staging directory (`~/.claude/modes/.user-catalog/<commands|agents>/`)
and symlinks it back to its original location, then updates the active
mode's `mechanism.user_catalog.<commands|agents>` manifest so the
cascade engine carries the file across mode swaps.

Argument forms:

- **Basename**: `/mode:adopt strict-deploy.md` — probes both
  `~/.claude/commands/` and `~/.claude/agents/`; refuses on ambiguity.
- **Absolute path**: `/mode:adopt ~/.claude/commands/strict-deploy.md`
  (leading `~/` is expanded by the dispatch script — the slash-command
  argument string is not shell-expanded by the harness).

Refusals (each surfaced as a clear stderr message):

- File is not under `~/.claude/commands/` or `~/.claude/agents/`.
- No active mode is set (run `/mode:set <mode>` first).
- File is already a symlink into `.user-catalog/` (idempotent no-op
  reporting the mode-of-record when discoverable).
- Path-traversal attempt rejected via R7 realpath validation.

Audit: every successful adopt emits a `adopt` event with metadata only
(file basename, mode, category, source=`manual`) to
`~/.claude/modes/.audit.log`.

To dispatch, run:

`bash "${CLAUDE_PLUGIN_ROOT}/lib/adopt-file.sh" "$ARGUMENTS" manual`
