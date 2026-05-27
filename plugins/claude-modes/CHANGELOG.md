# Changelog

All notable changes to claude-modes are documented here. This project
follows semantic versioning: minor bumps add capability, patch bumps fix
behavior, major bumps change the cascade contract.

## 0.3.1 — Read-path leak fully closed + structural cleanup

A patch release: no new user-facing features, no API or schema changes.
0.3.0 shipped with a known cross-project mode-leak fix (b22fdb9) that
turned out to cover ONLY ONE of FOUR read-path resolvers. This release
closes the class across every read path, plus a structural cleanup the
loop's reviews surfaced.

### Fixed

- **Cross-project mode leak — fully closed across all 4 read paths.**
  The leak (a non-repo subdir of a modes-using project inheriting the
  parent's per-branch pin) lived in 4 hand-mirrored copies of the resolver:
  `active-mode.sh`, `inject-prose.sh` (UserPromptSubmit hot path),
  `status.sh` (`/mode:status`), and `reconcile-symlinks.py` (SessionStart
  reconciler). 0.3.0 fixed copy 1 (b22fdb9). 0.3.1 fixes the other three
  and centralizes the gate logic into one source of truth so the bug
  class can't recur on a 5th copy.
- **`/mode:status` no longer reports a parent project's mode from an
  untracked subdir** (was: status said `delivery`, prose hook correctly
  said nothing — a real inconsistency).
- **`scripts/statusline.sh` no longer displays a parent project's mode
  from an untracked subdir** (last display surface; now routes through
  the canonical gated resolver).
- **R31 prose visibility** (cc99089): `UserPromptSubmit` hook emits the
  documented `hookSpecificOutput.additionalContext` envelope so prose
  injection stays as hidden context, not visible chat text. (This was the
  bug that made it *look* like a long prompt was being injected every
  message.)

### Refactor (no behavior change)

- **`lib/repo-root.sh`** (new). Canonical gated read-side resolver
  (`current_repo_root` — walks up for `.claude/modes/` marker AND
  requires `cwd` to be git-tracked under it) + the write-side companion
  (`current_git_toplevel`). `active-mode.sh`, `inject-prose.sh`, and
  `status.sh` source this; no inline copies remain. (Python mirror in
  `reconcile-symlinks.py` is the one unavoidable cross-language copy and
  is pinned by an equivalence test.)
- **Active-mode resolver triplication collapsed.** `inject-prose.sh` and
  `status.sh` previously each carried hand-mirrored copies of
  `validate_mode_body` / `read_mode_body` / `slugify_branch` /
  `resolve_active_mode`. Both now call canonical
  `claude_modes::read_active_mode_name`. Same path the statusline already
  used.
- **`lib/registry.py`** (new). Canonical reader for
  `~/.claude/plugins/installed_plugins.json`. Replaces 6 inline Bash
  heredocs that each hand-rolled the `{"plugins": dict} -> items` shape +
  list-of-records validity filter under a "REGISTRY-READER SYNC" comment
  convention.
- **3 inline `_sd` sanitize copies** → `from sanitize import
  sanitize_for_display` (same module already used by `cascade-engine.py`
  and `symlink-validate.py`).
- **`claude_modes::safe_move`** (new in `mode-yaml.sh`). Canonical
  try-mv-then-cp-sha256-verify-rm; collapses 3 copies and deletes the
  `_stat_device_id` helper that pre-checked same-FS (mv's own failure is
  the cross-FS signal).
- **Net code reduction** despite adding 2 new library files: -670 / +1360
  across 27 files (most of the + is the new canonical libs + tests; the
  - is the inline duplication that collapsed).

### Mechanical defenses added

- **`tests/integration/read-path-toplevel-lint.test.sh`** — fails CI if
  a bare `git rev-parse --show-toplevel` reappears on any of the 6
  read-path files. Converts the just-closed bug class into a standing
  guarantee. Inline escape marker (`# lint: read-path-toplevel-ok`) for
  the one legitimate layered case (`reconcile-symlinks.py`'s
  `_resolve_branch` — the gate is applied separately at the per-branch-
  pin decision in `main()`).
- **`tests/integration/hostile-registry-key-injection.test.sh`** — e2e
  behavioral test feeding a registry key with embedded `\n`/`\t`/ESC/
  U+202E (RTLO bidi override); asserts no phantom TSV-row forging
  reaches downstream tools. Complements the existing call-shape lint
  (`terminal-sink-lint`) with a runtime-effect check.
- **`tests/integration/active-mode-resolver-equivalence.test.sh`**
  narrowed from 4-way to 2-way (canonical Bash ↔ Python mirror) —
  reflects the post-refactor surface where the inline Bash copies are gone.
- **`tests/integration/mode-body-read-equivalence.test.sh`** gains
  leak-refusal assertions across all 4 read paths (untracked-subdir
  scenarios return empty; the original P0 ship-blocker bug is pinned).

### Behavior notes

- `inject-prose.sh` and `status.sh` now source `active-mode.sh`
  transitively. Measured cost: ~1.6ms/call over baseline (not the 60ms
  the prior inline-copy comments claimed; the inflated figure was
  measuring the wrong thing).

### Tested

Suite grew from 719 → 736 passing, 0 failing across 42 files (was 40).
Added: read-path-toplevel-lint (7 assertions), hostile-registry-key-
injection (5 assertions), leak-refusal anchors in mode-body-read-
equivalence (4 assertions). All deliberate-fail verified.

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
