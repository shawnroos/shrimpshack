# Changelog

All notable changes to claude-modes are documented here. This project
follows semantic versioning: minor bumps add capability, patch bumps fix
behavior, major bumps change the cascade contract.

## 0.3.0 — In-flow mode editor

Reshape the **active** mode without leaving your work. Previously a mode
was author-once: created via `mode-author`, set via `/mode:set`, then
immutable from your working session unless you hand-edited the YAML and
reloaded. 0.3.0 closes that gap.

### Added

- **`mode` agent** (`agents/mode.md`) — a plugin-shipped subagent
  (dispatch `subagent_type: claude-modes:mode`, or say `@mode`) that
  edits the active mode in its own context window: add/drop
  plugins/skills/agents, explain what the mode enables and why. Redirects
  to `/mode:suggester` for mode switches and `mode-author` for new modes.
  This is the plugin's first shipped agent — see
  `docs/solutions/2026-05-25-plugin-shipped-agents.md` for the precedent
  it sets.
- **`/mode:add <plugin-or-skill>`** — add a plugin, a plugin-shipped
  skill (enables its parent plugin), or a user-authored command/agent to
  the active mode's catalog.
- **`/mode:drop <plugin-or-skill>`** — remove (disable) one, via
  cascade-subtraction into `disable.enabledPlugins`. Refuses to drop
  `claude-modes` itself (R22).
- **`/mode:edit`** — open the mode agent to converse about changes.
- **`lib/resolve-catalog-candidate.sh`** — a shared primitive that
  resolves a user-typed name to fully-qualified plugin/skill/agent
  records across installed plugins, the cached SKILL.md set (both the
  `.claude/skills/` and convention `skills/` layouts), and known
  marketplaces; dedupes across version directories; sanitizes all
  terminal output.
- **`lib/apply-delta.sh`** — atomic delta application (add/drop plugin or
  user-catalog entry) with R22 enforcement as the user-visible fast-fail.
- **`lib/post-write-reload.sh`** — the post-write reload prompt.
- **`lib/mode-add.sh` / `lib/mode-drop.sh`** — the shared edit
  orchestrator (snapshot-based drift detection, per-invocation locking,
  exit-code IPC contract: 0 applied / 1 failure / 2 usage / 10 ambiguous /
  11 idempotent no-op).

### Behavior notes

- **Mode resolution requires opt-in + git-tracked cwd.** A project's
  per-branch pin only applies when (a) some ancestor of cwd has a
  `.claude/modes/` directory (the opt-in marker — created on first
  `/mode:set`) AND (b) cwd is git-tracked under that ancestor. Scratch
  dirs, build outputs, or any untracked subdir nested under a modes-
  using project no longer inherit its pin. Pre-fix the resolver used
  `git rev-parse --show-toplevel` directly, which leaked the parent
  project's mode into every non-repo subdir of its tree (e.g.
  `~/projects/<project>/<random-dir>/` got the project's mode against
  intent). Worktrees naturally don't inherit their parent's pin under
  the new rule either (a worktree's path is registered but not tracked
  in the parent's index).
- **Reload is user-run, not automatic.** On a successful edit the
  orchestrator prints a `/reload-plugins` prompt; you run it to apply the
  new loadout. (No verified script-context reload mechanism exists in the
  harness today — see `docs/spikes/2026-05-23-phase0-spike-results.md`
  Spike D. If a future harness confirms script-context reload, R5 upgrades
  to true auto-reload with no contract change.)
- **`@mode` is a cooperative convention.** The harness routes plugin
  agents by namespaced `subagent_type` (`claude-modes:mode`); the `@mode`
  shorthand relies on the model recognizing it and dispatching the agent.
  Verify in your own session — see Spike C in the same spike doc.
- **Adding by name, not by exact id.** `/mode:add figma` (a name)
  resolves and applies in one shot. A bare fully-qualified id with no
  disambiguation snapshot (`/mode:add figma@every-marketplace`) is treated
  as a stale re-invoke and refused fail-closed; use the plugin name
  instead, or accept the disambiguation flow.
- **Edits preserve the prose layer.** Adding or dropping never drops a
  mode's philosophy / scope / lens / constraints.

### Invariants preserved

- **R22** (claude-modes self-presence) — the editor refuses any delta
  that would disable `claude-modes`, as a fast-fail before the cascade
  engine's mechanical backstop.
- **R28** (no hooks/env/permissions/mcpServers in cascade YAML) — the
  editor routes through `lib/write-mode-yaml.sh`, which rejects them.
- **Atomic write** — every edit is `mktemp` + `mv`, born at 0600.
- **Terminal-escape defense** — all attacker-controllable output is
  sanitized; the lint allowlist guards the new sinks.

### Tested

Suite grew from 514 (V2.0) to 719 passing, 0 failing across 40 files,
including the load-bearing end-to-end chain (`resolve → apply-delta →
post-write-reload`), concurrency drift detection, R22 refusal, prose-layer
survival, and the `$ARGUMENTS`-uniqueness command lint.
