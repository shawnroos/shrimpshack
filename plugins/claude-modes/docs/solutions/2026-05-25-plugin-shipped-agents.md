---
authors: Claude
type: architecture-pattern
project: claude-modes
topics: [plugin-agents, subagent-dispatch, conventions, R31]
---

# Plugin-shipped agents — the precedent the `mode` agent sets

## Why this exists

0.3.0's `mode` agent (`agents/mode.md`) is the **first agent claude-modes
ships from its own plugin**. Before it, the plugin shipped only commands,
skills, and hooks. The conventions below were established empirically
(Phase 0 spikes, `docs/spikes/2026-05-23-phase0-spike-results.md`) and
should be inherited by every future plugin-shipped agent in this repo so
the next one doesn't re-run the same verification.

## The conventions

### 1. Layout: `agents/<name>.md` at the plugin root

NOT `.claude/agents/<name>.md`. A filesystem survey of 15 installed
plugins (Phase 0 Spike A) found 13 use `./agents/` at the plugin root and
only 2 use `.claude/agents/`. Auto-discovery is the universal pattern.

### 2. No `agents:` manifest key

`.claude-plugin/plugin.json` does NOT need an `agents` entry — agent
discovery is convention-based, not manifest-declared. 13 of 15 surveyed
plugins ship agents with no manifest declaration. (One, iloom-lite,
declares an `agents:` array of paths, but that's not required for
discovery.) Do not add the key; it does nothing.

### 3. Filename: plain `.md`

Both `<name>.md` and `<name>.agent.md` are observed in the wild;
plain `.md` is more common and matches the user-authored agent shape
under `~/.claude/agents/`. Use plain `.md`.

### 4. Dispatch: namespaced `subagent_type` ONLY

A plugin-shipped agent resolves as `subagent_type: claude-modes:<name>`,
NOT the bare `<name>` (Phase 0 Spike B — the Task tool's enumeration lists
plugin agents only in namespaced form; the bare form does not resolve).
The 2026-05-15 plan's "prefix-stripping" note was about claude-modes' OWN
hook normalizing names for its blocklist, not harness Task-tool
resolution. Tests for a plugin agent must use the namespaced form; do not
write bare-form coverage.

### 5. `@<name>` is a cooperative convention, not a harness contract

The `@mode` shorthand relies on the model recognizing the `@`-prefix and
emitting a Task dispatch — it is not (verified) routed by the harness the
way `@file` mentions are (Phase 0 Spike C, low-confidence; user-verifiable
post-ship). Document `@<name>` as a convenience the agent's own
description supports, and always provide a slash-command fallback
(`/mode:edit` for `@mode`).

### 6. Agent vs skill: which to ship

- **Agent** — when the work needs its OWN context window so it doesn't
  pollute the user's main conversation (analysis, multi-step reasoning,
  a sustained editing conversation). The `mode` agent qualifies: tuning a
  mode is a back-and-forth that shouldn't clutter the main session.
- **Skill** — when the work is inline orchestration the main agent runs
  directly (e.g. `mode-suggester`, `mode-author`). A skill IS the
  implementation; an agent is dispatched.

Corollary: don't wrap an agent in a no-behavior skill. 0.3.0's
`/mode:edit` dispatches the agent directly (parallel to
`commands/mode-suggester.md`'s skill dispatch, but pointing at the agent).
An intermediate `mode-editor` skill was designed and then cut in review —
it added a routing hop with zero behavior.

### 7. Sibling-agent boundaries: print a redirect, don't sub-dispatch

When an agent's request belongs to a sibling (e.g. the `mode` agent gets a
"switch modes" request that's `mode-suggester`'s job), it should PRINT a
one-line redirect naming the slash command and stop — NOT dispatch the
sibling as a nested Task. Nested plugin-agent dispatch depends on the
same unverified namespaced-resolution surface and is fragile; a printed
redirect is robust and keeps each agent's responsibility narrow.

### 8. Command `allowed-tools` must grant `Task` if the command dispatches

A slash command that dispatches a subagent (`/mode:edit` →
`subagent_type: claude-modes:mode`) must list `Task` in its
`allowed-tools` frontmatter. A skill-dispatching command (the harness
loads a skill) does not. This bit `/mode:edit` in review — it dispatched
an agent but omitted `Task`.

## Related

- `docs/spikes/2026-05-23-phase0-spike-results.md` — the empirical basis
  (Spikes A–D).
- `lib/inject-prose.sh` R31 — propagates the active mode's lens to
  subagent dispatches; a complementary mechanism (the mode reaches
  agents) to this doc's concern (the plugin ships an agent).
- `agents/mode.md` — the reference implementation of every convention
  above.
