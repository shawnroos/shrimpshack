---
title: "feat: In-flow mode editor (mode agent + slash commands)"
type: feat
status: active
date: 2026-05-23
origin: docs/brainstorms/2026-05-23-mode-agent-in-flow-editor-requirements.md
---

# In-flow mode editor (mode agent + slash commands)

## Overview

Ship claude-modes 0.3.0: an in-flow editor for the active mode. A new
agent at `agents/mode.md` plus three slash commands (`/mode:add`,
`/mode:drop`, `/mode:edit`) let the user reshape the active mode without
leaving the work — adding/removing plugins, skills, or agents from the
mode's catalog, walking the user through accept/reject via
AskUserQuestion, persisting atomically via `lib/write-mode-yaml.sh`, and
auto-reloading via `/reload-plugins` on success.

All four surfaces share one mechanism: build a delta, confirm with the
user, write atomically, reload. The agent provides conversational
ergonomics (`@mode add figma`); the slash commands provide
no-conversation execution (`/mode:add figma`).

This plan does not invent product behavior — it implements what the
origin requirements doc specified. Open questions deferred to /ce-plan
are resolved in this document with rationale.

---

## Problem Frame

Modes today are author-once structures: created via `mode-author`, set
via `/mode:set`, then immutable from the user's working session unless
they leave the task, hand-edit YAML, and reload plugins. The user hits
friction every time they use a mode and does not act on it. The
requirements doc (`see origin`) names two friction shapes: "I want this
skill in the mode" and "this mode has an edge." Both are the same
operation — apply a delta to the active mode, in-flow, persisted
atomically.

---

## Requirements Trace

- R1. The user can add a plugin/skill/agent to the active mode in one
  conversational turn (`@mode add X`) or one slash invocation
  (`/mode:add X`), with the catalog reloaded before the next user
  action *(origin SC1)*.
- R2. The user can remove or disable a plugin in the active mode by the
  same mechanism, with the disable correctly written to the YAML's
  `disable:` block per cascade-subtraction semantics *(origin SC2)*.
- R3. The agent surfaces the candidate list when an identifier is
  ambiguous — never silently picks one *(origin SC3)*.
- R4. The agent never writes the YAML without an explicit accept
  *(origin SC4)*.
- R5. **Reload prompt** fires on every successful write with a visible
  one-line notice naming `/reload-plugins` for the user to run
  *(origin SC5, degraded by Phase 0 Spike D — see "Verified
  Empirically in Phase 0" below)*. The notice is non-silent and
  mechanically deterministic; the user's reload is a single
  mechanical step. This degradation is documented as recoverable: if
  post-ship verification shows script-context reload works, R5
  upgrades to true auto-reload in a follow-on release without code
  rework (`lib/post-write-reload.sh` adds the emission line; user-
  prompt notice removed).
- R6. Existing 530/0 test suite stays green *(origin SC6)*; new tests
  added for each surface and documented failure modes.
- R7. V2 invariants R22 (claude-modes self-presence), R28 (no
  hooks/env/permissions/mcpServers in cascade YAMLs), and atomic-write
  are preserved at the writer level (mechanical enforcement, not
  agent-level checks alone) *(origin Privacy & Safety)*.

**Origin scope boundaries (carried verbatim from
`docs/brainstorms/2026-05-23-mode-agent-in-flow-editor-requirements.md`):**

- Per-tool-call telemetry (was Layer A) — deferred for later
- PreCompact auto-reflection (was Layer D) — deferred for later
- Remote marketplace fetch — deferred for later
- The `mode` agent does not become a general-purpose plugin manager
- The agent does not write hooks, env, permissions, or mcpServers
  (R28 preserved)

---

## Scope Boundaries

### Deferred for later

*Carried from origin — product/version sequencing. Work that will be
done eventually but not in 0.3.0.*

- Per-tool-call telemetry (revisit when in-session candidate ranking
  from existing dispatch context proves insufficient)
- PreCompact auto-reflection (revisit when the user reports
  retrospective friction; current evidence says point-of-use is the
  load-bearing moment)
- Remote marketplace fetch (revisit when "no candidates found" becomes
  a real failure mode for not-yet-installed plugins)

### Outside this product's identity

*Carried from origin — positioning rejection. Adjacent product the
plan must not accidentally build.*

- General-purpose plugin manager — the mode agent only edits the
  active mode, never cross-mode operations
- Hooks/env/permissions/mcpServers editor — R28 preserved, the agent
  redirects to `~/.claude/settings.json` or
  `<repo>/.claude/hooks/hooks.json`

### Deferred to Follow-Up Work

*Plan-local — implementation work intentionally split across other
PRs, issues, or repos.*

- Marketplace publication (`~/.claude/plugins/marketplaces/shrimpshack/
  .claude-plugin/marketplace.json` version bump to 0.3.0): performed
  after this plan's PR merges and the user smokes the install. Not in
  this plan's PR diff.

---

## Context & Research

### Relevant Code and Patterns

- `lib/write-mode-yaml.sh` — atomic writer (mktemp+mv, umask 077,
  R28 enforcement at line 147-158). Pattern to mirror for any
  catalog-mutating helper. The agent and all three slash commands MUST
  terminate here; raw `cat > path` is forbidden by R28 discipline.
- `lib/active-mode.sh::name` — canonical active-mode resolver
  (per-branch override → user-global fallback). Both agent and slash
  commands MUST use it; reading `.last-active-mode` directly produces
  wrong answers in multi-mode-per-repo setups.
- `lib/set-mode.sh::__claude_modes::atomic_write_string` (lines 65-103) —
  parallel atomic-write idiom for non-YAML strings (e.g. per-branch
  `.mode` pointer). Reference for shape.
- `lib/audit.sh::claude_modes::audit_event` — TSV append-only logger.
  Shape: `claude_modes::audit_event <event> key=value …`. Returns 0
  always; never propagates failure. New events for 0.3.0:
  `mode_edit_accept`, `mode_edit_reject`.
- `lib/cascade-engine.sh::__claude_modes::resolve_self_identifier`
  (lines 59-126) — the ONLY current reader of
  `~/.claude/plugins/installed_plugins.json`. Note the inline comment
  at lines 87-95: real entries are LISTS of install records, not
  single dicts. The candidate resolver MUST mirror this list-awareness
  or it will silently pass dict-shaped test fixtures while failing on
  real registries.
- `lib/cascade-engine.sh::__claude_modes::with_flock_run` —
  Python-wrapped `fcntl.flock` (macOS lacks `flock(1)`). Shared lock
  at `~/.claude/modes/.symlink-lock`, re-entrancy via
  `CLAUDE_MODES_LOCK_HELD=1`. Catalog mutations during multi-step ops
  wrap under this lock.
- `lib/sanitize.sh::claude_modes::sanitize_for_display` — terminal
  escape sanitizer. Per
  `docs/solutions/terminal-escape-audit.md`, every printf site that
  interpolates an attacker-controllable variable (plugin keys,
  marketplace paths, SKILL.md field names) MUST route through this.
  Lint computes new files into scope automatically; CI fails if any
  new printf site bypasses sanitization.
- `lib/inject-prose.sh` (lines 351-369) — R31 subagent-dispatch
  guidance block. The mode agent must propagate the active mode's lens
  to any subagent it dispatches in turn (no current need, but if the
  agent calls Task later this invariant applies).
- `.claude/skills/mode-suggester/SKILL.md` — closest reference for new
  skill bodies. Frontmatter shape, ToolSearch+AskUserQuestion preload
  block (lines 28-34), anti-patterns section, canonical-resolver use
  (lines 86-95). Lift the preload block verbatim into the new agent
  body.
- `.claude/skills/mode-author/SKILL.md` — Phase 3a (lines 222-242)
  inlines a Python read of `installed_plugins.json` from a skill body.
  0.3.0 formalizes this read into `lib/resolve-catalog-candidate.sh`
  once and routes both the agent and all slash commands through it.
- `commands/set.md`, `commands/adopt.md` — mechanical slash command
  shape (single `$ARGUMENTS`-bearing bash dispatch line). Per
  `feedback_slash_command_arg_substitution`, exactly one `$`-bearing
  line per `.md` and it IS the dispatch line. Mirror for `/mode:add`
  and `/mode:drop`.
- `commands/mode-suggester.md` — skill-dispatching command shape
  (no bash line; body describes the flow + points at the skill). The
  `/mode:edit` command follows this shape; the agent is summoned via
  `@mode` natively.
- `tests/integration/mode-adopt.test.sh` — closest structural analog
  for testing a multi-path catalog-mutating command. Per-scenario
  `__seed_<state>` helpers + `__reset_home_state` + audit-log probes
  via `tail -n 1 .audit.log | grep …`. Mirror for the new slash
  command and agent dispatch tests.
- `tests/integration/concurrent-mode-set.test.sh` — deliberate-fail
  discipline. New regression tests MUST prove they CAN fail by
  exercising the unprotected path (e.g. `CLAUDE_MODES_TEST_NO_LOCK=1`),
  per memory `feedback_new_tests_need_deliberate_fail_smoke_check`.

### Institutional Learnings

- *`docs/plans/2026-05-15-001-feat-modes-as-infrastructure-plan.md`
  (lines 177, 192, 222, 641):* subagent dispatch routes through the
  Task tool with `<plugin>:` prefix-stripping. A plugin-shipped agent
  named `mode` is reachable as `subagent_type: mode` AND
  `subagent_type: claude-modes:mode`. Tests must cover both forms.
- *`docs/solutions/terminal-escape-audit.md`:* new sinks in EITHER
  language require routing through that language's `sanitize_for_display`
  AND updating the source × sink matrix. Both lints fail CI otherwise.
  Lint scope is computed via `find` — the new resolver, agent, and
  slash command code all land in-scope automatically.
- *`lib/cascade-engine.sh:86-95`* (inline comment): real
  `installed_plugins.json` keys plugins to LISTS of install records,
  not dicts. The existing reader was burned by this once; the new
  candidate resolver must handle both shapes from day one.
- *Brainstorm "unverified assumptions" (origin doc lines 264-271):*
  `subagent_type: mode` routing for plugin-shipped agents was flagged
  for planning-time confirmation. Resolved in Decisions below.

### External References

None — this work mirrors existing in-repo patterns rather than
introducing new external dependencies.

---

## Key Technical Decisions

- **Agent name: `mode`. ONLY namespaced form resolves via Task tool
  (Phase 0 Spike B verified).** The Task tool's enumeration in this
  harness lists plugin-shipped agents ONLY as `<plugin>:<agent-name>`;
  bare forms do NOT resolve. So `subagent_type: claude-modes:mode` is
  the only working dispatch form. The 2026-05-15 plan's "prefix-
  stripping" policy was about claude-modes' OWN hook normalizing
  names for its blocklist lookup, NOT about harness Task-tool
  resolution. **U7 tests only the namespaced form.** Alternatives
  considered below.
- **Auto-reload behavior: SHIPS DEGRADED (Phase 0 Spike D outcome —
  low-confidence but cannot be falsified positively from in-session).**
  R5 ships as: on writer success, `lib/post-write-reload.sh` prints a
  visible one-line notice containing the literal `/reload-plugins`
  command for the user to type. **The user mechanically runs reload.**
  Same deterministic-V1 contract; different actor. Reason: zero call
  sites in the existing codebase invoke `/reload-plugins` from script
  context; every site prints the string for the user. Spike D could not
  empirically test from in-session because the running session's plugin
  state is fixed at session start. Post-ship: if the user verifies in a
  fresh session that script-context reload works, R5 upgrades to true
  auto-reload in a follow-on release (purely additive change to U6).
- **Reload-failure handling: do not revert.** If reload fails after a
  successful YAML write, leave the YAML on disk, audit the failure
  (`outcome=reload_fail`), surface the error to the user with the
  manual recovery command. Rationale: reverting a successful atomic
  write introduces a second failure mode (revert-failure) without
  restoring harness state. The YAML is correct; the harness is one
  step behind; the user runs `/reload-plugins` manually.
- **R22 enforcement: single layer at apply-delta.sh (U3).** Scope
  review observed that R22 already has cascade-time enforcement
  (`lib/cascade-engine.py:248-289`) covering the worst case (broken
  cascade at next compile). The plan originally added a third writer-
  level layer (former U4) to close the "wrote-then-broke" gap; on
  review, that gap is the same gap that triggers a clear, named
  cascade-error on the next reload — not silent breakage. The
  user-visible fast-fail belongs in `apply-delta.sh` (refuse the delta
  before the write); the cascade engine is the mechanical backstop.
  Two layers, not three. Former U4's content is folded into U3's
  R22 pre-check (now described as primary enforcement, not "fast-fail
  in front of a backstop").
- **Tier-3 only.** The agent and slash commands edit `~/.claude/modes/
  <name>.yaml` (or `<repo>/.claude/modes/<name>.yaml`). `_global.yaml`
  (tier 2) and `_repo.yaml` (tier 4) are out of scope for 0.3.0. The
  writer's existing path-safety check (lines 57-94) refuses targets
  outside those directories; the agent's path validation mirrors it.
- **Delta confirmation UX: before/after YAML block in the
  AskUserQuestion `preview` field.** Diff format is harder to read for
  small changes; natural-language summary loses precision. The
  AskUserQuestion preview supports rendered code blocks — the agent
  formats the relevant YAML section before-and-after as the preview.
- **Mode-agent ↔ mode-suggester boundary.** mode-suggester switches
  between modes; mode-agent edits the active mode. Disambiguation
  rule: if the user's request implies changing *which* mode is active,
  route to mode-suggester; if it implies changing what the *current*
  mode contains, route to mode-agent. Both agents' system prompts
  encode this distinction and point at each other. The mode-agent
  refuses requests like "switch to design" with a redirect to
  mode-suggester.
- **Candidate resolver search order.** When resolving "X" to a
  fully-qualified identifier: (1) cached SKILL.md frontmatter under
  `~/.claude/plugins/cache/*/*/.claude/skills/*/SKILL.md` (matches by
  skill name), (2) `installed_plugins.json` entries (matches by plugin
  name with marketplace suffix), (3) marketplace.json files at
  `~/.claude/plugins/marketplaces/*/.claude-plugin/marketplace.json`
  (matches by plugin name in installable-but-not-yet-installed
  entries). Order is by specificity: a named skill is more precise
  than a plugin; a plugin already installed is more usable than one
  the user would need to install.
- **Plugin manifest: NO new key, version bump only (Phase 0 Spike A
  correction).** The convention (13:2 across surveyed plugins) is
  agents at `./agents/<name>.md` with NO `agents:` manifest
  declaration — auto-discovery. The original plan assumption (add
  `"agents": "./.claude/agents"` key) was falsified empirically. U1
  now ONLY bumps version `0.2.0 → 0.3.0` in `.claude-plugin/plugin.json`
  AND creates the `./agents/` directory. The marketplace bump (0.2.4
  → 0.3.0) is in Deferred to Follow-Up Work.

---

## Open Questions

### Resolved During Planning

- *Open Q1 from brainstorm (agent naming):* Resolved as `mode`. Three
  reviewers flagged noun-space overload; user re-confirmed `mode`
  during plan review with explicit disambiguation note added to U7
  (the `@` prefix signals the agent; bare "mode" in prose signals the
  active mode). See Key Technical Decisions and Alternatives Considered.
- *Open Q2 from brainstorm (reload-failure handling):* Resolved as
  no-revert. See Key Technical Decisions.
- *Open Q3 from brainstorm (cross-tier writes):* Resolved as
  tier-3-only for 0.3.0. Out of scope for tier-2 and tier-4. See Scope
  Boundaries.
- *Open Q4 from brainstorm (delta confirmation UX):* Resolved as
  before/after YAML block in AskUserQuestion preview field. See Key
  Technical Decisions.
- *Open Q5 from brainstorm (mode-agent ↔ mode-suggester boundary):*
  Resolved as "mode-suggester switches modes, mode-agent edits the
  active mode" with **pinned redirect mechanism**: the mode agent
  PRINTS a one-line redirect with the exact slash command and exits;
  no sub-Task dispatch, no heuristic switch logic. See Key Technical
  Decisions and U7.
- *Release sequencing (added during plan review):* All four surfaces
  ship in 0.3.0 (agent + 3 slash commands). User decision during
  plan review; product-lens raised alternative (agent-first, then
  slash commands in 0.3.1) but user retained simultaneous shipping
  for symmetry and to preserve the brainstorm-committed surface.
- *R22 enforcement layering (revised on scope review):* Single layer
  at apply-delta.sh (U3) as primary user-visible enforcement; cascade-
  engine R22 (`lib/cascade-engine.py:248-289`) is the mechanical
  backstop. Former U4 (writer-level third layer) is CUT; over-defense
  not requested by the brainstorm.
- *Remote marketplace fetch classification:* Carried forward as
  deferred-for-later (pre-decided in brainstorm, no planning-time
  revision needed). Noted explicitly here so its absence from the
  "Resolved" list isn't read as an oversight.

### Verified Empirically in Phase 0 (formerly "Resolved During Planning")

- *Plugin-shipped agent discovery shape* (`"agents":` manifest key vs
  convention path vs auto-discovery). Three pieces of repo evidence
  argue for empirical verification: (1) the plugin currently has no
  `agents` key, (2) other plugins (slate-plugins, slate-devs) ship
  agents at `./agents/` with NO manifest declaration, (3) no
  primary-source documentation confirms what claude-modes' specific
  layout choice should be. Phase 0 Spike A resolves.
- *`subagent_type` prefix-stripping for plugin-shipped agents.* The
  2026-05-15 plan's claim was misread — that plan documents the
  claude-modes hook normalizing names for ITS OWN blocklist lookup,
  not the harness Task tool's resolution behavior. Phase 0 Spike B
  verifies whether `mode` and `claude-modes:mode` both resolve.
- *`@mode` mention syntax dispatch.* Unverified that user-typed `@`
  prefix triggers Task-tool subagent dispatch (vs file mention, text
  mention, or no-op). Phase 0 Spike C resolves; R1's UX adjusts
  based on outcome.
- *Script-context `/reload-plugins` emission.* Every existing call
  site in this codebase **prints** the string for the user to act
  on; none invokes it from a script. The brainstorm's "mode-suggester
  does this successfully" citation was wrong on inspection. Phase 0
  Spike D resolves; R5 ships in either the auto-reload shape (if
  spike succeeds) or the user-prompted-reload shape (if no working
  emission exists) — both satisfy the non-silent contract.

### Deferred to Implementation

- *Whether the candidate resolver should batch its three sources
  (skills cache + installed_plugins + marketplaces) into a single
  in-memory index per invocation, or query lazily.* Performance
  question that depends on the size of the user's plugin cache. Defer
  to U2 implementation; the simpler eager-load is acceptable for V1
  unless profiling shows otherwise.
- *Whether `/mode:add` should accept the candidate-rank shortcut
  (e.g., `/mode:add 2` after a previous disambiguation listed
  candidates 1-3).* UX nicety, not a planning-time decision.
- *Whether mtime+filehash drift detection (U5 concurrency fix) should
  also re-resolve the candidate after the lock-free dwell phase.*
  Minor edge case — could the candidate have been uninstalled while
  the user was thinking? Defer to U5; rejecting the write on candidate
  drift is the conservative choice if it comes up.

---

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance
> for review, not implementation specification. The implementing agent
> should treat it as context, not code to reproduce.*

### Surface → mechanism map

```
        @mode <utterance>          /mode:add <id>      /mode:drop <id>      /mode:edit
              │                          │                  │                    │
              ▼                          ▼                  ▼                    │
        agent (mode.md)         slash command       slash command                │
              ▲                          │                  │                    │
              │                          ▼                  ▼                    │
              │           lib/mode-add.sh       lib/mode-drop.sh                  │
              │                          │                  │                    │
              │                          │                  │                    │
              └──────────────────────────┴──────────────────┴────────────────────┘
                                         │
                                         ▼ (read-only: explain mode, no delta;
                                            mutation: continue below)
                                         │
                          resolve candidate    ◀── lib/resolve-catalog-candidate.sh
                                         │
                                         ▼
                          build delta + confirm via AskUserQuestion preview
                                         │
                                         ▼
                          R22 pre-check (lib/apply-delta.sh; primary enforcement)
                                         │
                                         ▼
                                lib/write-mode-yaml.sh  (R28 enforced; cascade-time R22 backstop)
                                         │
                                         ▼
                              lib/post-write-reload.sh
                                         │
                                         ▼
                              /reload-plugins  (auto-fire on success, OR
                                                visible notice + user prompt
                                                — depends on Phase 0 Spike D)
                                         │
                                         ▼
                              claude_modes::audit_event mode_edit_accept
```

### Delta shape (pseudo-spec, not code)

A "delta" is one of:
- `add_plugin(id)` → adds `mechanism.enabledPlugins.<id>: true`
- `drop_plugin(id)` → adds `<id>` to `disable.enabledPlugins`
- `add_user_catalog(category, basename)` → appends to
  `mechanism.user_catalog.{commands|agents}` list
- `drop_user_catalog(category, basename)` → removes from the same list

The agent constructs a delta from natural-language input; the slash
commands construct deltas from their argument. Both pass the same
delta object to `lib/apply-delta.sh` (or inline in the slash command's
bash dispatch). The writer doesn't see the delta; it sees the final
YAML after delta application.

**Note: a delta is a mutation.** The agent also handles read-only
operations (e.g., "explain the current mode", "what's enabled in
this mode?", "why is X disabled?"), which do NOT produce a delta
and do NOT write to disk. This section specifies the mutation paths
only; the read-only paths are described in U7's Flow section.

---

## Output Structure

The plan creates these new files. Existing files are modified, not
shown in this tree.

    .claude/
      agents/
        mode.md                                ← NEW (first plugin-shipped agent)
    commands/
      mode-add.md                              ← NEW
      mode-drop.md                             ← NEW
      mode-edit.md                             ← NEW (dispatches the mode agent directly; no skill wrapper)
    lib/
      resolve-catalog-candidate.sh             ← NEW (candidate resolver)
      apply-delta.sh                           ← NEW (delta → YAML mutation)
      post-write-reload.sh                     ← NEW (auto-reload helper)
    tests/
      integration/
        mode-agent-dispatch.test.sh            ← NEW
        mode-add-command.test.sh               ← NEW
        mode-drop-command.test.sh              ← NEW
        mode-edit-end-to-end.test.sh           ← NEW (integration)
        post-write-reload.test.sh              ← NEW
      unit/
        resolve-catalog-candidate.test.sh      ← NEW
        apply-delta.test.sh                    ← NEW

---

## Implementation Units

- U1. **Manifest + agent path scaffolding**

**Goal:** Bump the plugin version to 0.3.0 and create the `./agents/`
directory (plugin root) so U7 can populate `agents/mode.md`. Per
Phase 0 Spike A: NO manifest declaration is needed (auto-discovery is
the convention used by 13 of 15 surveyed plugins). Foundational;
everything else assumes the directory exists.

**Requirements:** R1, R6 (suite stays green)

**Dependencies:** None

**Files:**
- Modify: `.claude-plugin/plugin.json` (bump `version` to `0.3.0` ONLY; no `agents:` key per Phase 0 Spike A).
- Create: `agents/` (empty directory at plugin root, to be populated by U7).
- Modify: `tests/integration/r22-self-enforcement.test.sh` only if it greps `version` field; otherwise no test changes here.

**Approach:**
- One-line bump to plugin.json `version`. NO `agents:` manifest key
  added — auto-discovery is the convention (Phase 0 Spike A: 13:2
  empirical evidence; only iloom-lite declares `agents:` and uses a
  path-array format unrelated to the directory-discovery question).
- `mkdir agents/`. The directory exists as a discovery target; U7
  populates `agents/mode.md`.

**Patterns to follow:**
- Plugin-root `./agents/` convention used by 13 of 15 surveyed plugins
  including compound-engineering, nerd, slate-plugins, slate-devs.
- Existing `"skills": "./.claude/skills"` and `"commands": "./commands"`
  manifest keys remain unchanged.

**Test scenarios:**
- *Test expectation: none — pure manifest scaffolding with no behavioral change. Verified by suite-still-passes-after-manifest-edit.*

**Verification:**
- `bash tests/run.sh all` still passes 530/0.
- `cat .claude-plugin/plugin.json` shows `version: "0.3.0"` and NO new keys.
- `ls agents/` returns successfully (empty directory present).

---

- U2. **`lib/resolve-catalog-candidate.sh` — candidate resolver**

**Goal:** Net-new library that resolves a user-supplied identifier
("figma", "ce-correctness-reviewer", "rams") to one or more
fully-qualified plugin/skill/agent records, by searching three sources
in order.

**Requirements:** R3 (ambiguous → list candidates), R7 (sanitization)

**Dependencies:** U1 (manifest in place; soft dependency — could
parallelize but cleaner to land U1 first)

**Files:**
- Create: `lib/resolve-catalog-candidate.sh`
- Create: `tests/unit/resolve-catalog-candidate.test.sh`
- Modify: `docs/solutions/terminal-escape-audit.md` (add the new file to the source × sink matrix)

**Approach:**
- Public API: `claude_modes::resolve_candidate <query>` returns N records (TSV: `kind=<plugin|skill|agent>\tid=<fqn>\tsource=<cache|installed|marketplace>\tinstalled=<Y|N>`).
- Source 1: skills cache — scan **BOTH** layouts (verified empirically against the live user cache by the feasibility reviewer: 525 SKILL.md files exist; the originally-documented glob matched only 28 of 525, ~95% miss):
  - `~/.claude/plugins/cache/*/*/*/.claude/skills/*/SKILL.md` (Anthropic-convention layout)
  - `~/.claude/plugins/cache/*/*/*/skills/*/SKILL.md` (convention-based layout used by slate-plugins, nerd, awesome-claude-skills, others)
  Match by `name:` frontmatter. Deduplicate across version directories: keep the highest semver per `(plugin, skill_name)` pair (or newest mtime if semver-comparison fails).
- Source 2: `~/.claude/plugins/installed_plugins.json` — LIST-of-records aware (mirror `cascade-engine.sh:87-95` pattern).
- Source 3: `~/.claude/plugins/marketplaces/*/.claude-plugin/marketplace.json` — enumerates installable-but-not-installed entries.
- Empty result → exit 0 with no output (caller decides error message).
- Source-load failure (a source's path exists but parse fails) → emit a `source=missing\treason=<short>` TSV row to stderr so the caller can distinguish "tried all 3, none matched" from "one source was unreadable, results may be incomplete."
- Multiple results → all returned, caller disambiguates via AskUserQuestion.
- All output strings routed through `claude_modes::sanitize_for_display`.
- **Visibility note (private vs shared):** This lib is shipped as a `claude_modes::` public function and is intended as a **shared primitive** other claude-modes consumers (mode-author, mode-suggester, future tools) can adopt. The TSV output contract is part of the lib's stable interface; treat shape changes as breaking.

**Patterns to follow:**
- Lib script shape from `lib/write-mode-yaml.sh` (set flags, SCRIPT_DIR sourcing, BASH_SOURCE guard, `claude_modes::` namespace).
- `installed_plugins.json` reading from `lib/cascade-engine.sh::__claude_modes::resolve_self_identifier` lines 59-126.

**Technical design:**
*Directional sketch — not implementation spec:*
```
claude_modes::resolve_candidate() {
  query="$1"
  emit_candidates_from_skills_cache "$query"
  emit_candidates_from_installed_plugins "$query"
  emit_candidates_from_marketplaces "$query"
  # Each emit_ function prints zero or more TSV lines to stdout.
  # Sanitization happens inside each emit_ function before printf.
}
```

**Test scenarios:**
- *Happy path:* Single-installed plugin matching the query → one record returned with `source=installed installed=Y`.
- *Happy path:* Single-cached skill matching the query at Anthropic-layout (`.../.claude/skills/X/SKILL.md`) → one record with `kind=skill source=cache`.
- *Happy path:* Single-cached skill at convention-layout (`.../skills/X/SKILL.md`, NO `.claude/` infix) → one record with `kind=skill source=cache`. **This is the empirically-verified case the original glob missed.**
- *Edge case:* Query matches both a skill and a plugin → both returned, caller responsible for disambiguation (resolver does not silently rank).
- *Edge case:* Empty query → exit 0 with no output (caller decides).
- *Edge case:* Query with shell metacharacters (`'; rm -rf /`) → safely sanitized in output; no command injection.
- *Edge case:* Same skill cached at multiple version directories (e.g., `claude-modes/0.2.0/`, `0.2.1/`, `0.2.4/`) → resolver deduplicates, returns ONE record (highest semver wins).
- *Edge case:* `installed_plugins.json` shape is LIST-of-records (real shape) — resolver finds the entry. **Deliberate-fail:** swap to a DICT-shaped fixture; resolver should fall through with zero matches (proves the list-awareness is doing work).
- *Edge case:* Drop a fixture SKILL.md at the documented Anthropic-layout path with name `__probe`, query for `__probe`, confirm match. Move the file one directory up; query again; confirm zero matches. (Proves the glob is doing work, not vacuously passing.)
- *Error path:* `installed_plugins.json` missing → resolver continues with sources 1 and 3, does not crash; stderr emits `source=missing\treason=<short>` row.
- *Error path:* `installed_plugins.json` exists but unparseable → graceful continuation, stderr emits the missing row.
- *Error path:* Cache or marketplaces directory missing → same: graceful continuation with stderr signal.

**Verification:**
- Unit test passes.
- `docs/solutions/terminal-escape-audit.md` updated with new printf sites.
- `bash tests/integration/terminal-sink-lint.test.sh` passes (lint computes the new file into scope).

---

- U3. **`lib/apply-delta.sh` — delta application**

**Goal:** Net-new library that applies a delta (add/drop plugin or
user-catalog entry) to a tier-3 mode YAML by reading the current YAML,
mutating in memory, and handing the result to `lib/write-mode-yaml.sh`
for atomic write.

**Requirements:** R1, R2, R7 (R22 + R28 enforcement preserved)

**Dependencies:** U2 (uses resolver output)

**Files:**
- Create: `lib/apply-delta.sh`
- Create: `tests/unit/apply-delta.test.sh`

**Approach:**
- Public API: `claude_modes::apply_delta <mode-yaml-path> <op> <args...>` where `op` ∈ `{add-plugin, drop-plugin, add-user-catalog, drop-user-catalog}`.
- Reads the YAML via Python (`yaml.safe_load`), mutates the dict in memory, serializes back via `yaml.safe_dump`, hands to `write-mode-yaml.sh` via stdin.
- For `drop-plugin`: adds to `disable.enabledPlugins` list (does NOT remove from `mechanism.enabledPlugins` — cascade-subtraction semantics).
- For `add-plugin` of an id currently in `disable.enabledPlugins` (un-disable + add):
  - Read the parent tiers (`_global.yaml`, `_repo.yaml`) to determine whether the plugin is enabled by a parent.
  - If parent enables it: remove from `disable.enabledPlugins` only (no positive add — keeps YAML quiet).
  - If parent does not enable it: remove from `disable.enabledPlugins` AND add to `mechanism.enabledPlugins`.
- **R22 enforcement (primary site — formerly split between this lib and U4):** before serializing, simulate the post-delta cascade for the `claude-modes` plugin specifically. Call `lib/cascade-engine.sh::__claude_modes::resolve_self_identifier` to get the live marketplace id (which respects `CLAUDE_MODES_CANONICAL_ID` env override). If the post-delta YAML would put that id (or *any* `claude-modes@*` key — defense in depth for marketplace renames and stale entries) into `disable.enabledPlugins` OR set it to `false` in `mechanism.enabledPlugins`, refuse with stderr `R22: claude-modes@<id> is required and cannot be disabled at the mode tier` and exit 1. **Cascade-engine R22 (`lib/cascade-engine.py:248-289`) remains the mechanical backstop** at next compile; this layer is the user-visible fast-fail.
- Writes go through `lib/write-mode-yaml.sh` — never raw `cat > path`.

**Patterns to follow:**
- `lib/write-mode-yaml.sh` for the stdin → tmp → mv shape (delta-apply hands to writer, not directly to disk).
- Python YAML pattern from existing libs (cascade-engine.py for shape).

**Test scenarios:**
- *Happy path:* `add-plugin figma@every-marketplace` on a fresh mode → YAML now has `mechanism.enabledPlugins.figma@every-marketplace: true`.
- *Happy path:* `drop-plugin typescript-lsp@every-marketplace` on a mode with that plugin in cascade-inherited enabledPlugins → YAML now has `disable.enabledPlugins: [typescript-lsp@every-marketplace]`.
- *Happy path:* `add-user-catalog commands rams.md` → `mechanism.user_catalog.commands` list appended.
- *Edge case:* Adding a plugin that's already in `mechanism.enabledPlugins` → idempotent (no change, exit 0).
- *Edge case:* Dropping a plugin that's already in `disable.enabledPlugins` → idempotent.
- *Edge case:* `add-plugin` with an id that's currently in `disable.enabledPlugins` → REMOVES from disable list AND adds to enabledPlugins (un-disable + add).
- *Error path:* `drop-plugin claude-modes@<resolved-marketplace-id>` → R22 check fires, refuses with stderr `R22: claude-modes@<id> is required and cannot be disabled at the mode tier`, exit 1, YAML unchanged. Cascade-engine R22 is the mechanical backstop at next compile.
- *Error path:* `drop-plugin claude-modes@stale-marketplace-name` (a key referring to a defunct marketplace, not the live one) → still refused (defense-in-depth against marketplace renames).
- *Error path:* `mechanism.enabledPlugins.claude-modes@<id>: false` delta → refused (treats `false` as disable).
- *Edge case:* `CLAUDE_MODES_CANONICAL_ID` env override is set (e.g., to `claude-modes@local-dev`) and the delta targets the OTHER identifier → R22 check still fires (defense-in-depth glob over `claude-modes@*`).
- *Error path:* Mode YAML doesn't exist → exit 1 with "no such mode."
- *Error path:* Delta would produce `mechanism.hooks` → exit 1 from `write-mode-yaml.sh`'s R28 enforcement (existing, line 147-158).
- **Deliberate-fail:** comment out the R22 simulation block in apply-delta.sh via Edit, re-run the R22 refusal tests, confirm they now FAIL (the bad delta writes successfully). Restore. This proves the check is what's enforcing, not a side-effect of YAML parsing.

**Verification:**
- Unit test passes.
- R22 and R28 invariants are preserved for all happy-path scenarios.

---

- U4. **[CUT during plan review — content folded into U3.]**

The original U4 added a third R22 enforcement layer at
`lib/write-mode-yaml.sh`. Scope-guardian review observed that the
existing cascade-time R22 (`lib/cascade-engine.py:248-289`) plus U3's
apply-delta pre-check already form two layers; the third writer-level
layer was over-defense. The U3 pre-check is now described as primary
enforcement (refuse the delta before write); cascade-time is the
backstop on the next reload. The U-ID is preserved per the
stability rule — never renumber on deletion.

**Adversarial follow-up (folded into U3):** the apply-delta R22
check must use `lib/cascade-engine.sh::__claude_modes::resolve_self_identifier`
to get the live marketplace identifier (respecting
`CLAUDE_MODES_CANONICAL_ID` env override), not a hardcoded
`claude-modes@*` glob. This closes the marketplace-identity drift
edge case the adversarial review surfaced (a fixture using
`local-dev` and a real install using `shrimpshack` must not
disagree).

---

- U5. **Slash commands: `/mode:add`, `/mode:drop`, `/mode:edit`**

**Goal:** Ship the three slash-command entry points. `/mode:add` and
`/mode:drop` are mechanical (single bash dispatch); `/mode:edit` is
skill-dispatching (points at the mode agent).

**Requirements:** R1, R2 (slash form of the operation), R3, R4

**Dependencies:** U2, U3 (the slash commands consume both libs)

**Files:**
- Create: `commands/mode-add.md`
- Create: `commands/mode-drop.md`
- Create: `commands/mode-edit.md`
- Create: `lib/mode-add.sh` (orchestrator: resolver → disambiguate → confirm → apply-delta → reload)
- Create: `lib/mode-drop.sh` (orchestrator: same shape, drop semantics)
- Create: `tests/integration/mode-add-command.test.sh`
- Create: `tests/integration/mode-drop-command.test.sh`

**Approach:**
- Slash command bodies follow the `commands/adopt.md` / `commands/set.md` pattern: short prose explaining what the command does, then ONE bash dispatch line.
- `/mode:edit` (no-bash) follows the `commands/mode-suggester.md` pattern: short prose pointing at the agent (`subagent_type: mode`); no intermediate skill wrapper.
- Frontmatter: `allowed-tools: AskUserQuestion, Bash, Read`.
- Orchestrator libs (`mode-add.sh`, `mode-drop.sh`) do the multi-step flow: read active mode, resolve candidate(s), disambiguate via AskUserQuestion if N>1 candidates, show before/after YAML preview via AskUserQuestion, apply-delta on accept, **call `lib/post-write-reload.sh` (U6) on writer success** to emit the reload trigger and handle reload-failure auditing.
- **Locking discipline (adversarial review fix):** the orchestrator does NOT hold an exclusive lock during human-in-the-loop AskUserQuestion dwell time. Instead: (a) acquire `~/.claude/modes/.symlink-lock` briefly around the read (for consistent resolver output), release; (b) human-prompt phase runs lock-free; (c) re-acquire the lock for the write phase, **re-validate the active mode hasn't changed and the YAML hasn't been modified by another process since the read** (compare mtime + filehash). If drift detected, refuse with a "mode changed during edit; please retry" message rather than overwriting concurrent edits. This prevents a user wandering away mid-question from blocking every other claude-modes operation indefinitely.

**Patterns to follow:**
- `commands/adopt.md` → `lib/adopt-file.sh` for the command-to-lib composition pattern.
- `commands/set.md` for the single-`$ARGUMENTS` dispatch shape.
- `lib/set-mode.sh::__claude_modes::set_mode_locked` for the
  step-by-step orchestrator with per-step `if ! …; then audit_event
  outcome=fail step=…; return 1; fi` pattern.

**Test scenarios for `/mode:add`:**
- *Happy path:* `/mode:add figma` with one match → resolves, asks for accept, on Y writes YAML and triggers reload, audit log records `mode_edit_accept`.
- *Happy path:* `/mode:add ce-correctness-reviewer` (a skill) → resolves to skill, asks, on Y appends to user_catalog.agents.
- *Edge case:* `/mode:add figma` with three matches → AskUserQuestion disambiguates with all three preview blocks; user picks one; proceeds.
- *Edge case:* `/mode:add <unknown>` → "No candidates for <X>. Try `/plugin install` or check the spelling." Exit 1.
- *Edge case:* `/mode:add` (no arg) → usage message, exit 2.
- *Error path:* User declines at AskUserQuestion → no write, audit logs `mode_edit_reject`, exit 0 (decline is not an error).
- *Error path:* Writer fails (e.g., R22 refusal) → audit logs `outcome=fail step=write`, surface stderr, no reload triggered.
- *Error path:* Reload fails after successful write → audit logs `outcome=reload_fail`, prints recovery instruction, YAML stays (no revert).
- *Integration:* No active mode (Claude Mode) → command refuses with "no active mode — `/mode:set <name>` first."
- *Integration (concurrency):* Start `/mode:add X` in session A, pause at AskUserQuestion. In session B, run `/mode:set Y` against the same `~/.claude/modes/`. Session B proceeds without blocking (proves the lock is NOT held during dwell time). When session A user accepts, session A's mtime+filehash check detects the drift and refuses with "mode changed during edit; please retry." Audit log records `outcome=fail step=drift_detected`. Without this test, the original adversarial review's "lock held during dwell" hazard is unverified.
- *Integration (concurrency, no drift):* Start `/mode:add X`, pause, accept after 10 seconds with NO concurrent edits → succeeds; mtime+filehash check passes; write commits.

**Test scenarios for `/mode:drop`:**
- *Happy path:* `/mode:drop typescript-lsp` → resolves, asks, on Y adds to `disable.enabledPlugins`, reload.
- *Edge case:* `/mode:drop typescript-lsp` when already in disable list → idempotent, no change, exit 0 with a "already dropped" notice.
- *Error path:* `/mode:drop claude-modes` → apply-delta's R22 pre-check fires; writer's R22 check is the backstop; user sees R22 error; no write, no reload.
- *(Mirror remaining scenarios from `/mode:add` for symmetry.)*

**Test scenarios for `/mode:edit`:**
- *Happy path:* `/mode:edit` with no args → harness routes to mode-editor skill (which dispatches the agent). Test verifies the command body references the skill correctly; deeper testing lives with the agent dispatch test (U7).

**Verification:**
- All three command files exist with correct frontmatter.
- Integration tests pass.
- `/mode:add figma` in a live session demonstrates the happy-path end-to-end manually before merging.

---

- U6. **`lib/post-write-reload.sh` — auto-reload helper**

**Goal:** Centralize the post-write reload trigger so the agent and all
slash commands share one mechanism. On writer success, emit
`/reload-plugins` invocation + a one-line console notice. On reload
failure, audit and surface recovery instruction without reverting.

**Requirements:** R5 (auto-reload + visible notice)

**Dependencies:** None (independent helper); U5 will call it

**Files:**
- Create: `lib/post-write-reload.sh`
- Create: `tests/integration/post-write-reload.test.sh`

**Approach:**
- Public API: `claude_modes::post_write_reload <mode-name> <delta-summary>`. Returns 0 on reload success, non-zero on reload failure.
- Print to stdout: `Reloading plugins for mode <name> (<delta-summary>).`
- Emit the harness invocation. Exact emission shape is implementation-time discovery — try the user-facing string first (the documented Claude Code mechanism); if that doesn't trigger reload in-harness, escalate to a JSON systemMessage or hookSpecificOutput per Claude Code hook conventions.
- On reload failure: audit `outcome=reload_fail mode=<name>`, print "Reload failed — run `/reload-plugins` to recover. YAML is up to date.", return non-zero.

**Execution note:** The exact emission idiom is a quick in-harness
spike at implementation time, not a planning-time decision. Test
inside Claude Code; observe whether a newly-added plugin's commands
become available without the user typing `/reload-plugins`.

**Patterns to follow:**
- `lib/audit.sh` for the audit-call shape.
- `lib/sanitize.sh` for any user-name interpolation in the console notice.

**Test scenarios:**
- *Happy path:* Mock the reload mechanism (test harness env var `CLAUDE_MODES_TEST_RELOAD=ok`); function returns 0, prints the notice, audit log records `outcome=ok`.
- *Error path:* Mock reload failure (`CLAUDE_MODES_TEST_RELOAD=fail`); function returns non-zero, prints recovery message, audit log records `outcome=reload_fail`.
- *Edge case:* Mode name with shell metacharacters → sanitized in console notice.
- **Deliberate-fail:** Set `CLAUDE_MODES_TEST_RELOAD=ok` but break the audit call; confirm test detects the missing audit entry.
- *Integration:* This unit's tests use mocks. Real-harness verification lives in U7's end-to-end test.

**Verification:**
- Unit test passes with both ok and fail mocks.
- Audit log entries have the expected shape.

---

- U7. **`mode` agent (`agents/mode.md`)**

**Goal:** Ship the conversational entry point. A subagent at
`agents/mode.md` reachable as `subagent_type: mode` and
`subagent_type: claude-modes:mode` (both forms — see Phase 0 spike).
The `/mode:edit` slash command dispatches this agent directly (no
intermediate skill wrapper — scope-guardian review cut the
no-behavior `mode-editor` skill; the command body is parallel to
`commands/mode-suggester.md` but points at the agent).

**Requirements:** R1 (conversational form), R3, R4, R7

**Dependencies:** U2, U3, U5, U6 (the agent calls all of these),
Phase 0 (plugin-agent dispatch and `@mode` routing verified)

**Files:**
- Create: `agents/mode.md`
- Create: `tests/integration/mode-agent-dispatch.test.sh`
- Create: `tests/integration/mode-edit-end-to-end.test.sh`

**Approach:**
- Agent frontmatter: `name: mode`, `description: <multi-paragraph>` explaining when to use (the user wants to edit the active mode), and how it differs from mode-suggester (which switches modes). Optionally `model: sonnet`.
- Agent body sections:
  - **Loading AskUserQuestion** — lift the ToolSearch eager-load block verbatim from `mode-suggester/SKILL.md:28-34`.
  - **Active mode resolution** — use `bash ${CLAUDE_PLUGIN_ROOT}/lib/active-mode.sh name`.
  - **Disambiguating "mode" in transcripts** — explicit note: `@mode` (with @-prefix) summons this agent; bare "mode" in prose refers to the active mode (the user's stated working stance). The agent's responses should use "this mode" or the active mode's name (e.g., "the `design` mode") rather than "mode" alone, to keep transcripts readable.
  - **Flow** — (a) read user utterance, (b) classify intent (add / drop / explain / refuse-out-of-scope), (c) resolve candidates if needed, (d) handle read-only intents ("explain the current mode") by reading and summarizing without producing a delta, (e) for mutation intents show before/after YAML via AskUserQuestion preview, (f) call `lib/mode-add.sh` or `lib/mode-drop.sh` on accept, (g) confirm reload result.
  - **Boundary with mode-suggester (PINNED MECHANISM):** when the user's utterance implies switching modes (e.g., "switch to delivery", "should I be in a different mode?"), the agent **prints a one-line redirect with the exact slash command and exits without writing**. Specifically: `> Switching modes is mode-suggester's job. Run /mode:suggester (or /mode:set delivery directly).` No nested subagent dispatch (avoids the unverified prefix-stripping assumption); no heuristic switch logic (defers to mode-suggester's logic).
  - **Boundary with R28 (hooks/env/permissions/mcpServers):** when the user asks to add anything that would land outside `mechanism.enabledPlugins` / `mechanism.user_catalog` / `command_heuristics`, the agent prints a redirect pointing at `~/.claude/settings.json` or `<repo>/.claude/hooks/hooks.json`, identical in shape to `mode-author/SKILL.md`'s redirect (literal "hooks live in" phrase preserved for test compatibility — `tests/integration/mode-status-registry.test.sh:351` greps for it).
  - **Writer-error UX:** when `lib/mode-add.sh` or `lib/mode-drop.sh` returns non-zero AFTER user accept (e.g., R22 refusal that bypassed the pre-check, or R28 refusal that the agent didn't catch upfront), the agent translates the stderr to a user-facing explanation naming WHICH invariant fired AND the recovery action. Example for R22 refusal: "The writer refused: claude-modes is required in every mode (R22). To recover, either pick a different plugin to drop, or run `/mode:registry` to see what's currently disabled." Does NOT loop back to AskUserQuestion.
  - **Anti-patterns** — include "never write the YAML without AskUserQuestion accept", "never edit `_global.yaml` or `_repo.yaml`", "never invoke mode-suggester via sub-Task; just print the redirect", "never silently rank candidates — surface ambiguity to the user."

**Patterns to follow:**
- `.claude/skills/mode-suggester/SKILL.md` for skill body shape and ToolSearch preload.
- User-authored agents under `~/.claude/modes/.user-catalog/agents/` (e.g., `code-reviewer.md`, `root-cause-debugger.md`) for agent frontmatter shape.

**Test scenarios:**
- *Happy path:* Dispatch `subagent_type=mode` with utterance "add figma" → agent resolves, confirms, calls lib/mode-add.sh, reload fires. (Test by mocking lib/mode-add.sh and asserting it was called with `figma`.)
- *Happy path:* Dispatch `subagent_type=claude-modes:mode` (namespaced form) → reaches the agent. **Conditional on Phase 0 spike outcome:** if the spike shows only the namespaced form works for plugin-shipped agents, this is the canonical form and the bare-`mode` test below is dropped. If both forms work (per the 2026-05-15 plan's claimed prefix-stripping), keep both tests.
- *Happy path:* Dispatch `subagent_type=mode` (bare form) → reaches the agent. *Conditional on Phase 0 — drop if the spike falsifies prefix-stripping for plugin-shipped agents.*
- *Edge case:* "Explain the current mode" → agent reads YAML, summarizes, no write, no AskUserQuestion fired.
- *Edge case:* "Switch to delivery" → agent refuses + prints the pinned one-line redirect (`> Switching modes is mode-suggester's job. Run /mode:suggester (or /mode:set delivery directly).`). Test asserts the EXACT output shape — no sub-Task dispatch, no heuristic switch.
- *Edge case:* "Add a hook that runs lint" → agent refuses + redirects per R28; output contains the literal "hooks live in" phrase for test-grep compatibility.
- *Edge case:* "Install figma from the marketplace" → agent refuses + redirects to `/plugin install` (out-of-scope: agent edits modes, doesn't install plugins from marketplaces; preserves the "Outside this product's identity" boundary).
- *Error path:* User declines at AskUserQuestion → no write, audit log `mode_edit_reject`.
- *Error path:* Writer refuses after user accept (R22 violation that bypassed the pre-check — simulated by env override + injected fixture). Agent translates stderr to user-facing recovery message naming the invariant. Audit log records `outcome=fail step=write`. Test asserts the user-facing message names "R22" or "claude-modes is required" — generic "write failed" fails the assertion.
- *Integration (end-to-end):* In a sandboxed `$HOME`, set up a mode YAML, dispatch the agent with a real "add" utterance, observe: YAML changes, audit log has `mode_edit_accept`, reload notice appears. This is `mode-edit-end-to-end.test.sh` — the load-bearing integration test.
- *Integration (auto-reload verification gate):* The end-to-end test must ALSO assert that a newly-added plugin's commands become available in the test harness **without manually typing /reload-plugins** (i.e., that R5's auto-reload behavior actually triggered, not just that the notice printed). If Phase 0 falsified script-context reload, this assertion is replaced by "the notice instructs the user to run /reload-plugins" — the same probe, inverted.

**Verification:**
- Agent dispatch test passes for both `subagent_type` forms.
- End-to-end test passes.
- Manual smoke: in a live session, `@mode add figma` walks through the flow correctly.
- `bash tests/run.sh all` stays green at 530+ tests.

---

- U8. **Documentation + release housekeeping + pattern precedent**

**Goal:** Update CHANGELOG/README references, document the new
commands and agent in user-facing docs, finalize the terminal-sink
lint matrix, AND document the plugin-shipped-agent precedent for
future contributors.

**Requirements:** R6 (suite green); user-facing docs reflect 0.3.0

**Dependencies:** U1-U7 (all surfaces shipped first), Phase 0 outcome
(spike results inform the precedent doc — which manifest layout
worked, which dispatch forms resolve, which reload mechanism).

**Files:**
- Modify: `README.md` (if it exists in the plugin; add commands + agent section)
- Modify: `docs/solutions/terminal-escape-audit.md` (already touched in U2; final sweep across all new printf sites)
- Create or modify: `CHANGELOG.md` with the 0.3.0 entry
- Create: `docs/solutions/plugin-shipped-agents.md` — captures the precedent set by U7 for future plugin-shipped agents in this repo (manifest layout from Spike A, dispatch resolution from Spike B, agent-vs-skill split criterion, sibling-agent boundary convention).

**Approach:**
- One short CHANGELOG entry per the existing changelog format (if present); summary of: the four surfaces, the candidate resolver, R22 enforcement at apply-delta, Phase 0 spike outcomes (briefly).
- README section if applicable: brief description of `@mode` and the three slash commands.
- Precedent doc captures the design conventions so the next plugin agent doesn't re-derive them.
- Confirm the terminal-sink audit matrix has rows for every new printf site across U2-U7.

**Test scenarios:**
- *Test expectation: none — documentation update with no behavioral change. Folded reviewer note: scope-guardian observed this could be a PR-checklist item rather than a unit, but the precedent doc earns it real-unit status now (it's a genuine artifact, not a CHANGELOG line).*

**Verification:**
- `bash tests/run.sh all` stays green.
- CHANGELOG includes 0.3.0 entry.
- `docs/solutions/plugin-shipped-agents.md` exists and references Phase 0 spike outcomes.

---

## System-Wide Impact

- **Interaction graph:** The new mode agent is reachable from any
  Claude Code surface that can dispatch via the Task tool, plus
  directly via `@mode` mentions. The three slash commands are
  reachable from the user's prompt only. `lib/apply-delta.sh` and
  `lib/write-mode-yaml.sh` form a single chokepoint for catalog
  mutations — all four surfaces flow through them.
- **Error propagation:** Each step in `lib/mode-add.sh` /
  `lib/mode-drop.sh` returns explicit non-zero on failure with a
  stderr message naming the failing step (mirror of
  `lib/set-mode.sh::__claude_modes::set_mode_locked`). Audit log
  records `outcome=fail step=<name>` on every failure path.
  Reload failures are recorded but never trigger YAML revert.
- **State lifecycle risks:** The "wrote, but not reloaded" gap is the
  primary new failure surface. Mitigation: clear user-facing notice
  (R5), manual `/reload-plugins` is the documented recovery, no
  silent state divergence. The "wrote and reloaded, but new plugin
  is broken at runtime" gap is pre-existing for any catalog edit and
  not new to this work.
- **API surface parity:** The agent and slash commands present
  equivalent capabilities. Any feature added to one (e.g., a
  candidate-rank shortcut) should be considered for the other.
- **Integration coverage:** `mode-edit-end-to-end.test.sh` (U7) is the
  load-bearing integration test — exercises agent → resolver →
  apply-delta → writer → reload as one chain. Without this test, the
  per-unit tests prove each step in isolation but not their
  composition.
- **Unchanged invariants:** Plain `/mode:set` continues to work
  identically. mode-suggester behavior is unchanged. mode-author
  behavior is unchanged. `_global.yaml` and `_repo.yaml` editing
  is unchanged (still file-system-only; the new surfaces explicitly
  refuse to touch them). The cascade-compile sequence is unchanged.
  The hooks/env/permissions/mcpServers exclusion (R28) is preserved
  and now joined by R22 at the same enforcement layer.

---

## Risks & Dependencies

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| `/reload-plugins` script-context emission has no working idiom in the harness | **Medium-High** | High | **Phase 0 Spike D verifies empirically before any unit work.** If no working idiom exists, R5 ships in degraded form (prints `/reload-plugins` as a copyable instruction in the same visible notice). Feasibility review noted every existing call site **prints** the string rather than invoking it — so the assumption is contradicted by repo evidence, not "Low likelihood." Phase 0 forces empirical resolution. |
| Plugin-shipped agent discovery requires a different manifest/path than the plan assumes | **Medium** | High | **Phase 0 Spike A verifies empirically before U1.** Adversarial review noted the only primary-source evidence (slate-plugins, slate-devs) ships agents at `./agents/` with NO manifest declaration. The plan's `"agents": "./.claude/agents"` may be wrong layout, wrong key name, or unnecessary. Spike resolves before commitment. |
| `subagent_type: mode` does NOT resolve via prefix-stripping from `claude-modes:mode` | **Medium** | Medium | **Phase 0 Spike B verifies empirically.** The 2026-05-15 plan's prefix-stripping claim is about claude-modes' OWN hook normalizing names for blocklist lookup, NOT about harness Task-tool resolution. U7 tests adjust based on spike outcome — drop bare-form coverage if only namespaced form works. |
| `@mode` mention syntax does NOT trigger Task-tool subagent dispatch | **Medium** | High | **Phase 0 Spike C verifies empirically.** Claude Code's `@` is commonly used for file/image mentions; subagent dispatch is typically model-initiated, not user-syntax-initiated. If `@mode` doesn't dispatch, R1's UX revises to model-instructed dispatch ("when the user asks to edit the mode, dispatch subagent_type=mode") with `/mode:edit` as the explicit fallback. |
| Candidate resolver returns wrong source-priority (e.g., a marketplace entry ranked above a cached skill) | Medium | Low | U2 returns all matches to the caller for disambiguation — does not silently rank. Caller (agent or slash command) surfaces via AskUserQuestion. User can always pass a fully-qualified id to bypass resolution. |
| Terminal-sink lint fails CI for a new printf site | Medium | Low | U2 explicitly touches `docs/solutions/terminal-escape-audit.md`; reviewers verify the matrix update in code review. The lint failure is loud and informative. |
| Mode agent's system prompt over-triggers `/mode:edit` for ambient mismatches | Medium | Medium | Per the brainstorm: agent is invocation-only, never ambient. Tests verify the agent declines to act when summoned for out-of-scope requests (refuse + redirect). |
| Lock held during human-in-the-loop AskUserQuestion blocks all other claude-modes operations | **Low** (after fix) | High | U5's locking discipline (revised on adversarial review): release lock between read and write phases; re-validate via mtime+filehash drift-check before commit. Concurrency test in U5 verifies the lock is NOT held during dwell time. |
| Writer-error UX through the agent surfaces as generic "write failed" with no recovery path | Low | Medium | U7's flow specification: when `lib/mode-add.sh`/`lib/mode-drop.sh` returns non-zero after user accept, the agent translates stderr to a user-facing message naming WHICH invariant fired and the recovery action. Tested explicitly in U7. |

---

## Alternative Approaches Considered

- **Approach: name the agent `mode-editor` instead of `mode`.**
  Rejected: less felicitous (`@mode-editor add figma` reads as
  bureaucratic). The prefix-stripping policy makes
  `subagent_type=mode` unambiguous; collisions are mitigable by
  rename. Felicity wins here.
- **Approach: name the agent `mode-tutor` (the brainstorm's original
  framing).** Rejected: "tutor" implies didactic, reflective
  behavior. The agent does edits, not reflection. The reframe in the
  brainstorm explicitly moved away from "tutor" framing.
- **Approach: revert the YAML when reload fails.** Rejected: two
  failure modes are worse than one. If revert fails, the user is in
  a state worse than "wrote, didn't reload" — they're in "wrote, then
  tried to undo, partially undone." Write-then-don't-revert keeps the
  invariant "what's on disk is what the user accepted" intact.
- **Approach: skip the slash commands; ship only the agent.**
  Rejected: the brainstorm explicitly committed to both surfaces. The
  slash form gives no-conversation execution for users who know what
  they want; removing it forces a conversational round-trip for every
  edit.
- **Approach: extend mode-suggester to also edit modes (one agent,
  two responsibilities).** Rejected: the boundary between "switch
  modes" and "edit active mode" is sharp; collapsing the agents
  obscures it. Two agents with clear redirects to each other is
  cleaner than one agent with two modes of operation.
- **Approach: add a third R22 enforcement layer at the writer
  (former U4).** Considered during planning, then CUT on scope-
  guardian review. Cascade-engine R22 (`lib/cascade-engine.py:248-
  289`) already catches any R22 violation on the next compile;
  apply-delta's R22 pre-check (U3) is the user-visible fast-fail.
  A third writer-level layer is over-defense for a class the
  cascade engine already mechanically enforces.
- **Approach: ship a `mode-editor` skill wrapper for `/mode:edit`.**
  Considered during planning, then CUT on scope-guardian review.
  The skill would have been ~30 lines of prose pointing at an agent
  that already exists and is already directly addressable. Routing
  `/mode:edit` directly at the agent (parallel to
  `commands/mode-suggester.md`'s pattern but pointing at an agent
  rather than a skill) eliminates one new file with no behavioral
  cost.
- **Approach: consolidate `lib/mode-add.sh` and `lib/mode-drop.sh`
  into one parameterized lib.** Considered during planning;
  partially accepted. The two libs remain separate (parallel to
  `lib/set-mode.sh`'s shape) for clarity at the call site, but the
  shared logic (resolver call, AskUserQuestion disambiguation,
  drift-check, writer call, post-write-reload) lives in a private
  helper sourced by both. This balances the maintenance-divergence
  concern with the readability concern.
- **Approach: ship agent only in 0.3.0; slash commands in 0.3.1.**
  Considered during plan review (raised by product-lens). Rejected
  by user decision: the brainstorm committed to both surfaces, and
  shipping all four together preserves symmetry. Usage signal is
  available later via the audit log if the question becomes pointed.

---

## Phased Delivery

### Phase 0: Verification spikes (BEFORE any unit work)

Five reviewers (feasibility, product-lens, adversarial) converged on
the observation that three load-bearing assumptions are unverified.
Phase 0 runs four small spikes in-harness BEFORE U1 to falsify or
confirm each one. Each spike is ~5-15 minutes; total Phase 0 is under
an hour.

- **Spike A — plugin-agent manifest discovery.** In a throwaway
  worktree, add `"agents": "./.claude/agents"` to `.claude-plugin/
  plugin.json`, drop a trivial `mode.md` agent file, install the
  plugin, attempt Task-tool dispatch via `subagent_type: mode`.
  Observe whether the agent is reachable. If not, try removing the
  manifest key (auto-discovery convention) and try again. Also try
  `./agents/mode.md` (convention used by slate-plugins per feasibility
  research). **Outcome documented:** which layout actually works.
- **Spike B — `subagent_type` prefix-stripping.** Once Spike A finds
  a working layout, dispatch the same agent as both `subagent_type:
  mode` and `subagent_type: claude-modes:mode`. Confirm whether both
  forms resolve to the same agent. **Outcome documented:** which
  forms work; U7 tests adjusted accordingly. The feasibility reviewer
  flagged that the 2026-05-15 plan's prefix-stripping claim is about
  the claude-modes hook normalizing names for its OWN blocklist
  lookup, NOT about the harness Task tool — so this needs primary-
  source verification, not citation.
- **Spike C — `@mode` mention dispatch.** Type `@mode test` in a live
  Claude Code session with the agent installed. Observe whether it
  triggers Task-tool subagent dispatch (the primary R1 UX), routes
  as a text mention, or does something else. **Outcome documented:**
  whether the conversational headline feature works as designed, or
  whether R1's UX needs revision (e.g., dispatching the agent via
  model instruction rather than `@`-mention syntax).
- **Spike D — `/reload-plugins` script-context emission.** Write a
  throwaway skill that emits `/reload-plugins` from a Bash block in
  candidate emission shapes: (a) raw `echo '/reload-plugins'` to
  stdout, (b) JSON `systemMessage` output per Claude Code hook
  conventions, (c) `hookSpecificOutput` if the hook surface supports
  it. Add an enabled plugin to a mode YAML, invoke the test skill,
  observe whether the new plugin's commands become available without
  the user typing `/reload-plugins` themselves. **Outcome documented:**
  the exact working emission shape (if any), or that no script-
  context mechanism exists — in which case R5 degrades to "prints
  `/reload-plugins` as a copyable instruction" per the R5 framing in
  Requirements Trace.

**Phase 0 gate:** if Spike A or Spike C falsifies a foundational
assumption (no plugin-agent discovery, no `@mode` dispatch), pause
the plan and revise R1's UX before U1. If Spike D falsifies
script-context reload, U6 ships the degraded R5 (user-runs-reload
with a clear notice) — same Mechanical-V1 contract, different
actor. The plan proceeds either way; the spikes determine which
*shape* of R1 and R5 ships.

### Phase 1: Foundations

- **U1.** Manifest scaffolding (1-line change; uses Phase 0 Spike A's
  verified layout).

Single-unit phase; U4 was cut on scope review. U1 is bounded.

### Phase 2: Libraries (sequential after Phase 1)

- **U2.** Candidate resolver.
- **U3.** Delta application (now includes R22 enforcement as primary
  site, formerly split with U4).
- **U6.** Post-write reload helper (uses Phase 0 Spike D's verified
  emission shape, or the degraded user-prompt fallback).

U2 and U6 are independent — parallel-safe. U3 depends on U2's
output shape. Land U2 + U6 in parallel, then U3.

### Phase 3: Surfaces + integration (sequential after Phase 2)

- **U5.** Three slash commands.
- **U7.** Mode agent (no skill wrapper — cut on scope review).

U5 and U7 are independent in code but share integration concerns
(both call U2/U3/U6). Parallel-safe; converge in U7's end-to-end test.

### Phase 4: Cleanup

- **U8.** Documentation + housekeeping (terminal-escape audit final
  sweep, CHANGELOG 0.3.0 entry, manifest version bump confirmation).

### Parallelism summary for /ce-work

| Batch | Parallel-safe units | Sequential after |
|---|---|---|
| 0 | Spikes A, B, C, D (sequential — B depends on A; C/D parallel-safe after A) | — |
| 1 | U1 | Batch 0 |
| 2 | U2, U6 | Batch 1 |
| 3 | U3 | Batch 2 |
| 4 | U5, U7 | Batch 3 |
| 5 | U8 | Batch 4 |

Six batches total (Phase 0 + Phases 1-4). Max parallelism is 2
(well under the 16-concurrent cap from CLAUDE.md).

---

## Documentation Plan

- `CHANGELOG.md` 0.3.0 entry: four surfaces + R22 backstop.
- `docs/solutions/terminal-escape-audit.md` updated with new sink
  rows (touched in U2, finalized in U8).
- README (if present in the plugin) gets a brief section on
  `@mode` and the three slash commands.

The brainstorm doc at
`docs/brainstorms/2026-05-23-mode-agent-in-flow-editor-requirements.md`
is the durable origin and does not need editing.

---

## Operational / Rollout Notes

- Branch: `feat/modes-v2` (current). No new branch needed; this is
  the established V2 branch.
- Marketplace publication is **Deferred to Follow-Up Work** — after
  this plan's PR merges and the user smokes the install, bump
  `~/.claude/plugins/marketplaces/shrimpshack/.claude-plugin/marketplace.json`
  to 0.3.0 in a separate PR.
- Auto-switch hazard reminder: the repo has an auto-commit hook that
  switches HEAD to `feature/claude-dispatch` mid-task. Verify branch
  before every commit and after every batch completes (per memory
  `project_claude_modes_v2_committed`).
- **Suite baseline: 530/0 is the regression floor.** Any drop below
  530 is a regression. The previous estimate (~545-555/0) was a
  guess; per-unit new scenario counts are: U2 ~10, U3 ~10, U5 ~14,
  U6 ~5, U7 ~10, U1/U8 ~0 — net positive delta is ~45-55 new
  scenarios, but the actual count will depend on test-file granularity
  and is not a deliverable.
- **n=1 kill-criterion (product-lens addition):** if after two weeks
  of 0.3.0 in active use the audit log shows fewer than ~10
  `mode_edit_accept` events across all modes (i.e., the user
  invoked `@mode`, `/mode:add`, or `/mode:drop` fewer than ~10
  times total), revisit whether the in-flow editor is solving the
  right friction or whether the friction was actually about
  something else (e.g., authoring new modes mid-flow, or editing
  global skills rather than mode-scoped catalogs). The threshold is
  a heuristic, not a hard gate — the qualitative question is "did
  this become a habit." Audit-log telemetry already captures this
  without new instrumentation.
- **Pattern precedent note (product-lens addition):** `mode.md` is
  the first plugin-shipped agent in claude-modes. Future plugin-
  shipped agents in this repo should inherit: the manifest field
  (per Phase 0 Spike A outcome), the both-form dispatch tests
  (per Spike B outcome), the agent-vs-skill split criterion (agent =
  own context window for tasks polluting main convo; skill = inline
  orchestration), and the boundary-with-sibling-agents convention
  (printed redirect, not sub-dispatch). U8 documents this
  precedent.

---

## Sources & References

- **Origin document:**
  [docs/brainstorms/2026-05-23-mode-agent-in-flow-editor-requirements.md](../brainstorms/2026-05-23-mode-agent-in-flow-editor-requirements.md)
- Related plans:
  - [docs/plans/2026-05-15-001-feat-modes-as-infrastructure-plan.md](2026-05-15-001-feat-modes-as-infrastructure-plan.md) — subagent dispatch + prefix-stripping policy reference
  - [docs/plans/2026-05-18-001-feat-modal-harness-v2-plan.md](2026-05-18-001-feat-modal-harness-v2-plan.md) — V2 plan; original Q4 on /reload-plugins now resolved
- Related code:
  - `lib/write-mode-yaml.sh` — atomic writer + R28 enforcement
  - `lib/cascade-engine.sh` lines 59-126 — `installed_plugins.json` reader pattern (list-of-records)
  - `lib/active-mode.sh::name` — canonical active-mode resolver
  - `lib/audit.sh` — TSV audit logger
  - `lib/sanitize.sh::claude_modes::sanitize_for_display` — terminal escape sink discipline
  - `lib/inject-prose.sh` lines 351-369 — R31 subagent-dispatch guidance
  - `.claude/skills/mode-suggester/SKILL.md` — closest reference shape for new skill bodies
  - `tests/integration/mode-adopt.test.sh` — closest structural analog for new integration tests
- External references: none required.
