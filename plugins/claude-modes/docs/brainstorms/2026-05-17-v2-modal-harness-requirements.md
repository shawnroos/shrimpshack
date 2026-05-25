---
date: 2026-05-17
topic: v2-modal-harness
---

# claude-modes V2 — Modal Harness

## Problem Frame

Claude Code's harness exposes a single flat descriptor surface to the model: every installed plugin's agents, skills, and commands compete for the same context budget regardless of what kind of work is happening. As users install more opinionated systems — compound-engineering for pipelined feature work, ai-ml-toolkit for ML engineering, slate-plugins for product work — they all bleed into every session. The catalog grows linearly with adoption; the descriptor budget does not. `/doctor` flags this directly when a user crosses ~200 agents (observed empirically on Shawn's machine at 278 agents).

The harness is **amodal**: there is no native mechanism to reshape the catalog per kind of work. Users have no current workaround for this — most haven't hit the ceiling yet, and those who have just live with the noise. V2 creates the category "modal harness" — every other piece of software a user runs has modes (vim modes, IDE perspectives, app workspaces) but Claude Code today has none.

**V1's relevance and limit.** V1 of this plugin (archived at git tag `v0.1.0-experiment` in this repo; origin docs at `docs/brainstorms/2026-05-15-modes-as-infrastructure-requirements.md` and `docs/plans/2026-05-15-001-feat-modes-as-infrastructure-plan.md`) shipped a parasitic implementation: a PreToolUse hook that blocks Task/Skill dispatch to agents the active mode unmounts. The mechanism works (gating is deterministic; the audit log proves it), but the user-facing experience exposes the harness's amodal nature: even in a mode that explicitly unmounts ce-adversarial-reviewer, `/help` still shows 278 agents, the user types a slash command that COULD dispatch the unmounted agent, Claude tries to dispatch it, the hook blocks it, the user sees a block message. That's **block-after-attempt**, not **hide-from-catalog**. The frustration is structural — V1 couldn't reshape what the harness exposes to the model because R19 forbade modifying any other plugin's files and the harness offered no other lever.

V2's premise: **modes are settings.** Claude Code's `~/.claude/settings.json::enabledPlugins` controls which plugins are loaded. Switching modes swaps which set of plugins is loaded. The catalog actually shrinks at the harness level. The user sees only what the active mode allows — no block-after-attempt, no noise, no "wait, why is that even an option?" The harness becomes modal because the settings file becomes modal.

The harness-bloat problem is currently visible only to power users (Shawn hit it early because he experiments heavily). Descriptor-budget pressure is going to be universal within ~12 months as plugin ecosystems mature. V2 is pre-positioning against an inevitable problem.

---

## Actors

- A1. **Mode user (V2's V0 user, Shawn).** Installs claude-modes; sets up a few modes for different kinds of work; switches between them across sessions. Cares deeply about not having their files destroyed, not having their existing config invalidated, and being able to fully uninstall and return to pre-V2 state.
- A2. **Mode author.** Same person as A1 in V0; eventually anyone adopting the plugin. Writes mode YAML files that declare which plugins are enabled, which commands/agents are in scope, and what prose context the mode injects when active.
- A3. **Hypothetical stranger adopter.** Someone who installs claude-modes from a future marketplace listing. Has their own pre-existing `~/.claude/settings.json` they care about; has their own user-authored `~/.claude/commands/` and `~/.claude/agents/`; has no prior context about V1 or this plugin's design lineage. The credibility test for V2 is: would this person trust the plugin's install based on reading the README and source alone.
- A4. **Claude (the model).** Reads whatever `~/.claude/settings.json` resolves to at session start. V2 reshapes settings.json per mode; Claude sees the resulting catalog without any awareness that modes exist. Modes are transparent to the model — they shape the surface the model is given, not the model's reasoning.
- A5. **Claude Code (the harness).** Reads `~/.claude/settings.json` at startup and on `/reload-plugins`. V2's mechanism depends on this being a stable contract.
- A6. **Anthropic.** Not a user; a third party who might ship native session-profile / mode-equivalent functionality in Claude Code within 12 months. V2 is explicitly positioned so harness-level absorption of the abstraction is an acceptable success outcome.

---

## Key Flows

- F1. **First-time install.**
  - **Trigger:** User installs claude-modes from a marketplace or local symlink; runs `/mode:setup`.
  - **Actors:** A1, A5.
  - **Steps:** Plugin reads user's current `~/.claude/settings.json` once (for forensic anchor `~/.claude/settings.json.pristine` per R18); generates `~/.claude/modes/_global.yaml` (the cascade's always-active baseline, R29) from the user's pre-install settings — extracting hooks, env, permissions, MCP servers, and enabledPlugins into YAML form; moves user's existing `~/.claude/commands/*.md` and `~/.claude/agents/*.md` into `~/.claude/modes/.user-catalog/`; symlinks them back to original paths so day-zero catalog is byte-identical; seeds example mode YAMLs (`example-discovery.yaml`, `example-delivery.yaml`); creates the empty install registry `~/.claude/modes/.installed-repos.txt` (R32). **The user's `~/.claude/settings.json` is never modified or symlinked** — under the cascade model, the plugin only writes to repo-local files (when the user runs `/mode:set` in a repo). Install touches the user's machine-global file only to READ it.
  - **Outcome:** Plugin is installed; `_global.yaml` mirrors pre-install behavior so day-zero state is observationally identical to pre-install. No mode is active anywhere yet (Claude Mode = no mode active on any branch).
  - **Covered by:** R3, R4, R7, R12, R13, R18, R29, R32.

- F2. **Set a mode.**
  - **Trigger:** User runs `/mode:set <name>`.
  - **Actors:** A1, A5.
  - **Steps:** Plugin reads `~/.claude/modes/<name>.yaml`; generates `~/.claude/modes/.live-settings.json` from the YAML's mechanism section by replacing only plugin-owned keys in the current settings; rebuilds symlinks at `~/.claude/commands/` and `~/.claude/agents/` to reflect the mode's manifest; writes per-branch state at `<repo>/.claude/modes/<branch-slug>.mode`; signals user to `/reload-plugins` (or auto-detects if harness supports it).
  - **Outcome:** Active mode is `<name>`; catalog reshaped at harness level on next reload.
  - **Covered by:** R1, R5, R6, R8, R11, R14.

- F3. **Author a new mode.**
  - **Trigger:** User runs `/mode:registry` with no args, or `/mode:set <new-name>` with a name that doesn't exist.
  - **Actors:** A2 (mode author).
  - **Steps:** mode-author skill walks the user through intent capture → definition synthesis → which axes the mode shapes (plugin catalog / user catalog / context injection / none) → mechanism declaration (which plugins, which user commands, which user agents) → validation → write YAML.
  - **Outcome:** New mode YAML at `~/.claude/modes/<name>.yaml`; user opts to set it immediately or later.
  - **Covered by:** R10, R15, R20.

- F4. **Return to Claude Mode (no-modes-active state).**
  - **Trigger:** User runs `/mode:clear`.
  - **Actors:** A1, A5.
  - **Steps:** Plugin removes the per-branch mode pointer at `<repo>/.claude/modes/<branch-slug>.mode`; re-runs the cascade engine with no tier-3 contribution → compiled `<repo>/.claude/settings.local.json` reflects tiers 1+2+4 only (user's pre-install settings + global baseline + repo baseline); invokes user-catalog symlink rebuild with the empty active-mode manifest, restoring the day-zero symlink topology (all files in `.user-catalog/` linked back). Signals user to `/reload-plugins`.
  - **Outcome:** User is back to no-modes-active state. If `_repo.yaml` exists in this repo, its tier-4 contributions remain in effect (e.g., repo-specific hooks/plugins persist) — this is intentional, since `_repo.yaml` represents "always-on while in this repo regardless of mode."
  - **Covered by:** R2, R8. (Note: previously F4 used `/mode:set claude`; revised to `/mode:clear` per cascade model — there is no static `claude.yaml` to set.)

- F5. **Uninstall.**
  - **Trigger:** User runs `bash ~/.claude/plugins/claude-modes/scripts/unmodes.sh`.
  - **Actors:** A1.
  - **Steps:** Plugin moves all files from `~/.claude/modes/.user-catalog/commands/` and `.../agents/` back to `~/.claude/commands/` and `~/.claude/agents/`; removes all plugin-owned symlinks. **Reads the install registry `~/.claude/modes/.installed-repos.txt` (R32)** and for each listed repo: removes `<repo>/.claude/settings.local.json` (only if file content matches the cascade engine's signature — never blindly delete user-authored content), removes `<repo>/.claude/modes/` (per-branch state, repo-tier YAMLs). Deletes `~/.claude/modes/`. **`~/.claude/settings.json` is NOT modified by uninstall** — under the cascade model, the plugin never owned it post-install, so there is nothing to restore. The `settings.json.pristine` file remains as a forensic anchor but is not used for restoration.
  - **Outcome:** `~/.claude/commands/`, `~/.claude/agents/`, and `~/.claude/settings.json` are byte-identical to pre-install state (assuming the user didn't edit settings.json themselves between install and uninstall). All repo-local artifacts written by claude-modes are cleaned up. Confirmed by an automated round-trip test.
  - **Covered by:** R17, R18, R32.

---

## Cascading Configuration Model

V2 is structured as a **cascade of configuration tiers** rather than a single mode-as-settings overlay. This emerged after the first plan draft revealed two structural problems: (1) hooks/permissions/MCP servers that belong to the user "regardless of mode" had nowhere to live except inside every mode YAML (duplication), and (2) a single user-global `~/.claude/modes/.live-settings.json` couldn't represent two repos in different modes simultaneously without race-condition workarounds.

**V2.0 ships 5 cascade tiers** (in order of application; later overrides earlier; default merge semantic is **add with explicit `disable:` block for subtract**). V2.1 adds tier 5 (per scope-guardian 2026-05-18 — see R31 deferral):

1. **User's `~/.claude/settings.json`** — Untouched by claude-modes after install. The user owns this file directly; the plugin reads it once at install (for the pristine recovery anchor) and never writes to it.
2. **Global baseline `~/.claude/modes/_global.yaml`** — The "always-active across all modes" tier. Carries hooks, MCP servers, plugins, env vars, and permissions that should apply regardless of which mode is set, machine-wide. Authored once at install (cascading from the user's pre-install state) and edited directly by the user. **This is one of two hooks-permitted tiers in V2.0.**
3. **Global mode definition `~/.claude/modes/<mode-name>.yaml`** — The mode YAML proper. Carries the mode's plugin additions/subtractions, env additions, permission grants, and the prose layer (philosophy/scope/lens/constraints). Modes ADD to the global baseline by default; mode YAMLs may carry an explicit `disable:` block to subtract specific keys (e.g., a focused writing mode that disables a globally-loaded CE plugin). **Mode YAMLs CANNOT declare hooks at any tier.**
4. **Repo baseline `<repo>/.claude/modes/_repo.yaml`** (optional) — Per-repo additions to the cascade. Hooks, plugins, env vars, MCP servers, permissions that apply across all modes WHEN INSIDE THIS REPO. Lives in the repo's tree; commit-able if the user wants to share repo-wide claude-modes config with collaborators. **This is the second hooks-permitted tier in V2.0** (per R28 trust analysis — user-authored, same trust level as `_global.yaml`).
5. *(V2.1)* Repo mode override `<repo>/.claude/modes/<mode-name>.override.yaml` — per-repo mode customization. Deferred to V2.1 per R31.
6. **Per-branch mode pointer `<repo>/.claude/modes/<branch-slug>.mode`** — Records which mode is active for this branch in this repo. Read at session start and on `/mode:set`. Selects which tier-3 file to apply; does not itself contribute settings.

**Compiled output (V2.0):** `/mode:set` cascades tiers 1 → 2 → 3 (selected by tier 6) → 4 and writes the result to **`<repo>/.claude/settings.local.json`**. Claude Code's existing native cascade (`~/.claude/settings.json` → `<repo>/.claude/settings.json` → `<repo>/.claude/settings.local.json`) does the rest — the repo-local file overrides the user-global file for this session.

**Per-repo isolation is automatic.** Two repos open simultaneously each have their own `settings.local.json`; `/mode:set delivery` in repo A doesn't touch repo B. The R27 worktree reconciliation problem becomes "within a single repo's worktrees" — a much smaller blast radius than the original cross-repo race.

**Merge semantics — `disable:` blocks.** A mode YAML may declare:

```yaml
disable:
  enabledPlugins: ["compound-engineering@every-marketplace"]
  env: ["DEBUG_MODE"]
  permissions: ["network.write"]
```

Each key under `disable:` is a list of keys-to-subtract from what previous tiers contributed. The cascade respects subtract: a delivery mode that disables CE produces a final live settings without CE even though global enables it.

**Trust boundary intact.** Hooks living in `_global.yaml` does NOT re-introduce the hooks-injection RCE vector. The trust check is "where does this YAML come from?" — `_global.yaml` is authored directly by the user via local editing (same trust level as `~/.claude/settings.json`); shared mode YAMLs (downloaded from gists or marketplaces) live in `~/.claude/modes/<name>.yaml` and CANNOT declare hooks. The mechanical enforcement: the cascade engine refuses to accept `hooks` from any tier OTHER than `_global.yaml` and `_repo.yaml`. Per-mode hooks remain forbidden.

---

## Requirements

**Core mode mechanism**

- R1. Modes are YAML files at `~/.claude/modes/<name>.yaml`. Each mode's YAML carries two layers: **mechanism** (additions and subtractions to the cascade — `enabledPlugins`, `env`, `permissions`, `mcpServers` add by default; an explicit `disable:` block subtracts specific keys from previous tiers; plus a separate **user-catalog manifest** declaring which user commands/agents are visible in this mode) and **prose** (philosophy, scope, lens, constraints, optional command-heuristics for runtime injection). **Mode YAMLs CANNOT declare `hooks` at any tier** (R28 invariant); hooks live in `_global.yaml` and `_repo.yaml` only, which are user-edited directly and not subject to the same trust assumptions as shareable mode YAMLs.
- R2. **`_global.yaml` is the always-active baseline.** Auto-generated at install from the user's pre-existing `~/.claude/settings.json` (cascading the relevant keys into a YAML representation); represents the "always-on across all modes" tier. Users edit this file directly to add machine-wide hooks, plugins, env vars, and MCP servers. **"Claude Mode" is the no-modes-active state** — when no mode is set on a branch, the cascade applies tiers 1 (`~/.claude/settings.json`) and 2 (`_global.yaml`) and the result reflects the user's pre-install behavior plus any global baseline additions. Setting any named mode adds tier 3 (and optionally 4-5) to the cascade. Returning to "Claude Mode" is `/mode:clear` (no mode active for this branch) rather than `/mode:set claude`.
- R5. `/mode:set <name>` runs the cascade engine: reads tiers 1-6 (per the Cascading Configuration Model section), applies add and disable semantics in tier order, and writes the compiled result to **`<repo>/.claude/settings.local.json`**. Claude Code's native cascade (`~/.claude/settings.json` → `<repo>/.claude/settings.json` → `<repo>/.claude/settings.local.json`) then makes the repo-local file override the user-global file for this session. Settings keys the cascade touches: `enabledPlugins`, `env`, `permissions`, `mcpServers` (subject to the reload-semantics matrix in "Resolve Before Planning"). Settings keys the cascade NEVER touches: everything else in `~/.claude/settings.json` (statusLine, worktree config, output style, font, etc.) — preserved by Claude Code's own merge. **`hooks` flows through the cascade from `_global.yaml` and `_repo.yaml` only**; mode YAMLs are blocked from declaring hooks at cascade-compile time. **Permissions diff/confirm gate:** if the cascade produces a `permissions` result that ADDS a grant not present in the previous compiled settings.local.json, `/mode:set` surfaces the named diff and prompts `add these permissions on swap? [y/N]` (default N). Plain swaps where the new permissions are a subset proceed silently.
- R6. Per-branch mode state at `<repo>/.claude/modes/<branch-slug>.mode` records which mode is active on each branch. Branch slug uses the same filesystem-safe slugifier across all consumers (carried forward from V1: `claude_modes::slugify_branch`).
- R8. `/mode:set` writes the compiled cascade output to `<repo>/.claude/settings.local.json` and signals the user to run `/reload-plugins` (which Claude Code uses to re-read settings mid-session, including the repo-local tier). If a future harness API supports auto-reload, plugin adopts it. **No conservative-vs-opt-in distinction** — the cascade always writes to the repo-local file, which Claude Code natively cascades over `~/.claude/settings.json` (the user's file). The plugin never owns or rewrites `~/.claude/settings.json`.
- R26. **`/mode:set` is idempotent and crash-safe.** The swap operation builds the target filesystem state from the mode YAML alone, never depending on the previous catalog's state. Plugin writes a `~/.claude/modes/.mode-set.in-progress` sentinel before any mutation and clears it after the last mutation completes. On any subsequent `/mode:set` or `/mode:status` invocation, the plugin detects an orphaned sentinel and surfaces: `previous /mode:set was interrupted; re-running for <target>` then re-applies. Because re-apply is idempotent, partial completion is always recoverable by re-running. Tested by `tests/integration/mode-set-crash-recovery.test.sh` which simulates kills at every mutation boundary and asserts the re-apply path produces the correct end state.

- R28. **Hooks are user-owned at baseline tiers (2 and 4), never mode-scoped.** Background: `hooks` in Claude Code's settings.json carries shell commands that execute on tool lifecycle events. If `/mode:set` accepted `hooks` from a shareable mode YAML (gist, marketplace), a malicious `PreToolUse` hook entry would register an attacker-controlled command at the harness level on next `/reload-plugins` — RCE on the next tool use. **Under the V2.0 cascade model, hooks flow from tier 2 (`_global.yaml`, R29) and tier 4 (`_repo.yaml`, R30) ONLY** — both user-authored via local editing, same trust level as `~/.claude/settings.json` itself. Mode YAMLs (tier 3, and V2.1's tier 5) are mechanically blocked by the cascade engine from declaring `hooks`. The plugin's own hooks (R25 UserPromptSubmit prose hook, R27 SessionStart reconciliation, R20 SessionStart-scan + PostToolUse Write) are managed via the plugin's own `hooks.json` manifest, not via mode YAMLs.

- R27. **Per-branch mode reconciliation within a repo.** Under the cascade model, each repo writes its own `<repo>/.claude/settings.local.json` — concurrent repos are filesystem-disjoint and don't race. The reconciliation problem is now scoped to **worktrees of the SAME repo** (which share `<repo>/.claude/settings.local.json` and the user-catalog symlinks at `~/.claude/commands/`):
  - **SessionStart hook.** On every Claude Code session start, the plugin reads `<repo>/.claude/modes/<branch-slug>.mode` for the current worktree's branch. If no per-branch record exists, the cascade engine compiles to settings.local.json with no tier-3 mode applied (i.e., `_global.yaml` + `_repo.yaml` only — Claude Mode).
  - **flock serialization** within a repo. Before rebuilding `<repo>/.claude/settings.local.json` (cascade write) and before rebuilding `~/.claude/commands/` symlinks (user-catalog), the hook acquires an exclusive flock on `<repo>/.claude/modes/.cascade-lock` (repo-scoped) AND on `~/.claude/modes/.symlink-lock` (user-catalog-scoped, since commands remain user-global per the scoping decision). Same-repo concurrent worktrees serialize on the repo lock; cross-repo concurrent worktrees only contend on the user-catalog lock.
  - **No-op fast path.** Before rebuilding, the hook compares the would-be cascade result to the existing settings.local.json (and compares user-catalog symlink set to target). If both match, skip rebuilds. Same-mode same-repo concurrent worktrees experience zero contention beyond brief flock acquisition.
  - **Divergence toast.** When this session's recorded branch-mode differs from the active settings.local.json's implied mode (a concurrent same-repo worktree just set a different mode), surface a one-time `<system-reminder>` (via the R25 UserPromptSubmit hook): `Mode-of-record for branch <slug> is <X> but this repo's active settings reflect <Y> (concurrent worktree). Run /mode:set <X> to align, or accept the concurrent worktree's mode.`
  - **Stance.** Modes are **per-branch in intent, per-repo in mechanism, except user-catalog which is per-machine.** Cross-repo concurrent worktrees are fully isolated. Same-repo concurrent worktrees in different modes converge on whichever session started most recently within that repo, with divergence surfaced. User-catalog (commands/agents) is still per-machine (Claude Code limitation); R27 within-a-repo still applies for the symlink-set races.
  - Tested by `tests/integration/worktree-mode-reconciliation.test.sh` covering: same-mode same-repo concurrent open (no rebuild, no toast), different-mode same-repo concurrent open (toast fires in second session), different-repo concurrent open in different modes (full isolation — neither session sees the other), branch checkout within a worktree (re-reconciles on next session), no per-branch record (defaults to Claude Mode).
- R14. `/mode:status` reports the active mode for the current repo's current branch (read from tier 6 — `<repo>/.claude/modes/<branch-slug>.mode`), **plus the cascade tiers in effect**: tier 1 (always `~/.claude/settings.json`), tier 2 (always `~/.claude/modes/_global.yaml`), tier 3 (active mode YAML, if any), tier 4 (`_repo.yaml` if present in this repo), tier 5 (`<mode>.override.yaml` if present). For each visible tier, `/mode:status` shows the file path and whether it contributed to the compiled result. Also reports plugin catalog (compiled `enabledPlugins`), user catalog (commands/agents visible in the active mode), and the path to the compiled `<repo>/.claude/settings.local.json`. Drift detection between live settings and tier-by-tier expectation is deferred to V2.1 per R23.

**User catalog (commands and agents authored by the user)**

- R3. On install, the plugin **moves** existing `~/.claude/commands/*.md` and `~/.claude/agents/*.md` (via `mv`, single atomic op, content unchanged) into `~/.claude/modes/.user-catalog/commands/` and `.../agents/`. Plugin then symlinks each file back to its original path. **Day-zero catalog is byte-identical to pre-install state.**
- R4. Each mode YAML's user-catalog manifest declares which user-authored commands and agents are visible in this mode. Claude Mode includes everything by default; other modes opt in to specific files.
- R7. On `/mode:set`, the plugin rebuilds symlinks at `~/.claude/commands/` and `~/.claude/agents/`. It removes ONLY symlinks whose target is inside `~/.claude/modes/.user-catalog/` (plugin-owned symlinks). Regular files and alien symlinks at those paths are never touched. **Path-traversal safety:** before creating each symlink, the plugin resolves the target via `realpath` (or equivalent) and refuses to create any symlink whose resolved target is not a descendant of `~/.claude/modes/.user-catalog/`. A user-catalog manifest entry containing `..` or any path-traversal sequence (e.g., `../../.ssh/id_rsa`) MUST fail validation at `/mode:set` time with a clear error. This is enforced by an automated test fixture (`tests/integration/symlink-path-traversal.test.sh`) that drives the symlink builder with malicious manifests and asserts refusal.
- R20. **New-file adoption.** Files authored at `~/.claude/commands/*.md` or `~/.claude/agents/*.md` while a non-Claude mode is active become candidates for mode-scoping via two paths:
  - **Manual: `/mode:adopt <file>`** — first-class slash command. User runs after authoring; plugin `mv`s the file to `~/.claude/modes/.user-catalog/...` and symlinks back, scoping it to the active mode. Always works regardless of how the file was written (editor, IDE, Bash, Claude Write).
  - **PostToolUse hook (Claude-tool writes only)** — when Claude itself calls the Write tool to create a file at the user-catalog path, the PostToolUse Write hook offers immediate consent: "Tag `/foo` as a `delivery`-mode command? [Y/n]" (default N — safer in non-interactive contexts like CE fan-outs). On Y → `mv` + symlink. On N or non-interactive → file stays global; user can run `/mode:adopt <file>` later.
  - **SessionStart scan (editor writes)** — Claude Code hooks cannot observe external editor writes (vim, cursor, cmux save) because PostToolUse matchers fire on tool dispatch, not filesystem events. On every SessionStart, the plugin lists regular (non-symlink) files at `~/.claude/commands/` and `~/.claude/agents/` that were not present at the last recorded scan. For each new file, the plugin queues a one-time `<system-reminder>` (via the R25 prose-injection hook): "Untagged new file `/foo.md` at user-catalog path — run `/mode:adopt <file>` to scope to active mode, or leave global." User dismisses by running `/mode:adopt` or by ignoring.
  - Default behavior across all paths: untagged files remain visible in every mode (the absence of R20, by design).

**Plugin catalog (third-party plugins shipped via Claude Code marketplaces)**

- R11. Mode YAML's `enabledPlugins` mechanism field controls which third-party plugins are enabled in this mode. Same format Claude Code uses in `~/.claude/settings.json::enabledPlugins`.
- R22. claude-modes itself is `enabledPlugins[claude-modes@<marketplace>] = true` in EVERY mode (the meta-plugin must always be loaded so `/mode:set` continues to work after switching). Plugin enforces this at TWO points: (a) **write-time** — refuses to write a mode YAML that would disable itself, and (b) **`/mode:set`-time** — refuses to apply a mode YAML whose `enabledPlugins` omits claude-modes (covers the case where the YAML was hand-edited after writing). The `/mode:set`-time check is the load-bearing one; write-time is a convenience. **Recovery path:** plugin ships `scripts/restore-claude-modes.sh` (smaller than `unmodes.sh`) that re-enables claude-modes in the live settings file from outside Claude Code, for users who bypassed validation by editing `.live-settings.json` directly and got wedged.

**Safety, reversibility, and uninstall**

- R12. The plugin only writes files inside `~/.claude/modes/`. Exception: on `/mode:set`, it creates/removes symlinks at `~/.claude/commands/` and `~/.claude/agents/` — but the targets always point INTO `~/.claude/modes/.user-catalog/`, and the plugin's symlinks are detectable by target prefix.
- R13. The plugin source contains zero `rm` or `unlink` calls on regular files at user-authored paths (`~/.claude/commands/`, `~/.claude/agents/`, `~/.claude/settings.json`). Enforced by automated lint (regression test). `rm` is allowed only on symlinks whose target is inside the plugin's owned tree, and on the plugin's own state files.
- R17. **`scripts/unmodes.sh` exists and mechanically reverses install:** moves user-catalog files from `~/.claude/modes/.user-catalog/` back to `~/.claude/commands/` and `~/.claude/agents/`, removes plugin-owned symlinks, deletes any `<repo>/.claude/settings.local.json` written by claude-modes across all known repos (tracked via an install registry at `~/.claude/modes/.installed-repos.txt`), deletes any `<repo>/.claude/modes/` directories (per-branch state, repo-tier YAMLs), deletes `~/.claude/modes/`. **The user's `~/.claude/settings.json` is NEVER modified by uninstall** — the plugin never owned it post-install, so there's nothing to restore. The `settings.json.pristine` file (R18) remains as a forensic anchor but is informational only; uninstall doesn't overwrite the user's settings with it. Tested by an automated round-trip suite that asserts: post-uninstall, `~/.claude/settings.json` SHA-256 equals pre-install (assuming the user didn't edit it themselves); every `~/.claude/commands/*.md` and `~/.claude/agents/*.md` is a regular file with byte-identical content to pre-install; no `<repo>/.claude/settings.local.json` files written by claude-modes survive.
- R18. The plugin writes `~/.claude/settings.json.pristine` at install time (copy of the user's settings.json AT THE MOMENT BEFORE the plugin first touches anything). This file is never modified by the plugin after install — it is the recovery anchor.
- R21. *(Superseded by the cascade model; content redistributed to R8 — write target — and Key Decisions — "the plugin never owns settings.json" stance. Slot kept for ID stability with previous reviews.)*

**Conversational authoring**

- R10. The mode-author skill carries forward from V1, sharpened for V2's mechanism. Phased flow: intent capture → definition synthesis → which axes the mode shapes (plugin catalog, user catalog, context injection, none) → mechanism declaration → validation → write. The skill produces a complete YAML; user can edit it directly any time post-write.
- R25. **Prose-injection mechanism.** V2 ships a `UserPromptSubmit` hook that reads the active mode YAML's prose layer (philosophy, scope, lens, constraints, applicable command-heuristics) and prepends it to every user prompt as a `<system-reminder>` block. This is the ONE small hook V2 ships beyond the settings-swap mechanism — necessary to make R15's "context injection" axis real. Hook is presence-gated (no modes dir → exits 0 silently, per V1's cost-of-being-installed pattern). Hook respects `PROSE_INJECTION_DISABLED` env-var escape hatch for debugging. Reconciles with Key Decisions: V2 is **settings-swap for catalog reshaping; one small UserPromptSubmit hook for prose injection** — still much smaller hook surface than V1's PreToolUse+PostToolUse pair, and the hook never blocks tool dispatch (only annotates context).

- R15. The skill explicitly asks the user which axes their mode shapes:
  - **Plugin catalog** (`enabledPlugins`): which third-party plugins are loaded
  - **User catalog** (commands and agents): which user-authored files are visible
  - **Context injection** (carried from V1; probabilistic): philosophy/scope/lens/constraints and command-heuristics prose injected into Claude's `<system-reminder>` when commands run
  - **None**: minimal mode that uses the full catalog and injects only the mode's name (rare; mostly useful for placeholder modes during authoring)

**Schema and migration**

- R9. Mode YAML carries `schema_version: 2`. V2 introduces this version explicitly (V1 used `schema_version: 1`). The parser rejects unknown versions visibly. V2 does NOT migrate V1 mode YAMLs automatically — V1 is archived and superseded; the migration story is "author your modes fresh in V2."

**Observability**

- R16. Statusline integration carries forward from V1 (visible mode indicator, OSC 2 terminal-title escape with `[mode] cwd-basename` prefix, A.2-with-reset semantics). The mechanism is unchanged because it was always read-only — V2 keeps it.
- R23. *(Deferred to V2.1.)* Drift detection between the active mode YAML and the live settings file. V2.0's `/mode:status` (R14) reports active mode + catalog only — no drift surfacing. Drift detection requires a settled semantic (deep-equal on plugin-owned-keys subset? semantic equivalence? formatting-tolerant?) that produces no false positives. Ships in V2.1 once the semantic is designed and tested.

- R24. **Restrictive permissions on settings-derived files.** All files the plugin writes that are derived from `~/.claude/settings.json` or that carry mode-mechanism data (including credentials, env vars, hook command lines) MUST be created with mode `0600` (owner read+write only). Under the V2.0 cascade model, covers: `~/.claude/modes/_global.yaml` (carries hooks + env + MCP creds — CRITICAL), `~/.claude/settings.json.pristine` (forensic anchor — CRITICAL), `~/.claude/modes/.installed-repos.txt` (install registry — discloses which repos a user works in), `<repo>/.claude/modes/_repo.yaml` (when present — carries hooks + env + MCP creds, repo-tier — CRITICAL), `<repo>/.claude/settings.local.json` (compiled cascade output — carries env + permissions + MCP from all tiers), `~/.claude/modes/.audit.log` (audit log carry-forward from V1), and any future settings-derived artifacts. (V2.1 will add `<mode>.override.yaml` to this list per R31.) **Important note for `_repo.yaml`:** because it lives in the repo's tree, the user may commit it to source control. If they do, hooks/env/MCP creds in `_repo.yaml` become readable to anyone with repo access. README guidance: either avoid putting secrets in `_repo.yaml` and use env-var references instead, or add `_repo.yaml` to `.gitignore`. The 0600 invariant protects the file on disk but cannot protect against intentional commit. **Born-at-0600 pattern:** use `(umask 077 && mktemp ... && write ... && mv ...)` to ensure the file is created at mode 0600. Enforced by `tests/integration/settings-file-perms.test.sh`.

**Cascade tiers (new in cascade model)**

- R29. **`_global.yaml` is the always-active baseline tier.** Lives at `~/.claude/modes/_global.yaml`. Carries hooks, MCP servers, plugins, env vars, and permissions that apply across ALL modes on this machine. Auto-generated at install from the user's pre-existing `~/.claude/settings.json` (the cascade engine extracts the relevant keys into YAML form); user-editable thereafter. Cascade engine reads `_global.yaml` before any mode YAML during compilation. **Hooks live here** — mode YAMLs cannot declare hooks; the cascade engine refuses to accept `hooks` keys from any tier other than `_global.yaml` and `_repo.yaml` (mechanical enforcement of the R28 invariant under the cascade model).
- R30. **Repo baseline `<repo>/.claude/modes/_repo.yaml` (optional).** Per-repo additions to `_global.yaml`. Hooks, plugins, env vars, MCP servers, and permissions that apply across all modes WHEN INSIDE THIS REPO. Lives in the repo's tree (commit-able if the user wants to share repo-wide claude-modes config with collaborators; user choice). Cascade engine reads `_repo.yaml` as tier 4 — between the active mode YAML (tier 3) and the per-branch pointer (tier 6, which selects tier 3). **Justification for V2.0 (vs. scope-guardian's defer recommendation):** real workflows have repo-specific baseline needs that aren't mode-specific (e.g., a frontend repo needs a specific MCP server + env var regardless of whether the user is in delivery or discovery). Without R30, the user must either (a) bloat `_global.yaml` with repo-specific config that pollutes other repos, (b) repeat the config in every mode YAML used in that repo, or (c) hand-edit `<repo>/.claude/settings.local.json` outside the plugin's awareness. R30 is the per-repo equivalent of `_global.yaml` and earns V2.0 placement. **Trust:** `_repo.yaml` is at the same trust level as `_global.yaml` — user-authored via local editing — so it inherits the same hooks-permitted status as `_global.yaml` in R28.
- R31. *(Deferred to V2.1 per scope-guardian review 2026-05-18.)* Repo mode override `<repo>/.claude/modes/<mode-name>.override.yaml` — strictly more niche than R30 and structurally entangled with compositional modes / mode inheritance (already deferred). Design alongside those in V2.1.
- R32. **Install registry `~/.claude/modes/.installed-repos.txt`.** Tracks which repos have had `<repo>/.claude/settings.local.json` written by claude-modes. One absolute path per line. On uninstall (R17), the script reads this registry and removes the plugin-owned `<repo>/.claude/settings.local.json` from each listed repo (only if the file's content matches the cascade-engine signature — never blindly delete a file the user may have authored). Registry is append-only during plugin lifetime; cleaned by uninstall. If a repo is moved or deleted between install and uninstall, the registry entry is silently skipped (with audit log entry).

**Distribution and adoption**

- R19. The plugin is designed to be publishable to a Claude Code marketplace as V2.x without prerequisites beyond Claude Code itself. README has a brisk install path, an "How V2 handles your files" section for paranoid readers (which now emphasizes that **the plugin never writes to `~/.claude/settings.json`** — only to repo-local `.claude/settings.local.json` files in repos where the user explicitly invokes `/mode:set`), an "Uninstalling" section that points at `scripts/unmodes.sh`, and a "Cascading configuration tiers" section explaining `_global.yaml`, `_repo.yaml`, and the override pattern.

---

## Acceptance Examples

- AE1. **Covers R3, R12, R17.** Given a user with 14 commands and 6 agents in `~/.claude/commands/` and `~/.claude/agents/`; when they run `/mode:setup`; then those 20 files are moved (single atomic `mv` each) into `~/.claude/modes/.user-catalog/`, symlinked back to their original locations; `cat`-ing any file at the original path returns the original content byte-identically; running `scripts/unmodes.sh` afterwards restores `~/.claude/` to byte-identical pre-install state, verified by SHA-256 hash of every regular file.

- AE2. **Covers R2, R8.** Given a fresh V2 install with the user's pre-V2 settings.json captured as `~/.claude/modes/claude.yaml`; when the user runs `/mode:set claude` and then `/reload-plugins`; then `/help` shows the same agents/commands/skills it would have shown pre-V2 install. Claude Mode is observationally indistinguishable from "no mode."

- AE3. **Covers R5, R7, R11.** Given a user in Claude Mode with all 278 third-party agents visible; the user has authored a `delivery` mode that declares `enabledPlugins: [compound-engineering, claude-modes]` only and includes 3 specific user commands in its user-catalog; when the user runs `/mode:set delivery` and `/reload-plugins`; then `/help` shows only the agents/commands those two plugins ship plus the 3 user commands. The other 276 agents are not present in the catalog.

- AE4. **Covers R13, R17.** Given a user with V2 installed; when an attacker (or buggy version of the plugin itself) attempts to write `rm "$HOME/.claude/commands/foo.md"` somewhere in `lib/*.sh` or `scripts/*.sh`; then the R19-style lint test (`tests/integration/no-destructive-rm.test.sh`) fails CI, preventing the change from landing.

- AE5. **Covers R22.** Given a user attempts to author a mode YAML that omits `claude-modes` from `enabledPlugins`; when they run `/mode:set <that-mode>`; then the plugin refuses with a clear error: "claude-modes itself must be enabled in every mode (else /mode:set will stop working). Add `claude-modes@<marketplace>: true` to this mode's enabledPlugins."

- AE6. **Covers R20.** Three sub-cases prove the adoption paths:
  - **AE6a (manual):** User in `delivery` mode writes a new command via vim to `~/.claude/commands/strict-deploy.md` (Claude session inactive at write time). User opens Claude Code; next SessionStart scan surfaces a `<system-reminder>`: "Untagged new file `/strict-deploy.md` — run `/mode:adopt` to scope." User runs `/mode:adopt /strict-deploy.md`. File `mv`s to `~/.claude/modes/.user-catalog/commands/strict-deploy.md`, symlinked back. `/help` in `delivery` mode shows `/strict-deploy`; `/help` in `discovery` mode does not.
  - **AE6b (Claude-tool write):** User in `delivery` mode asks Claude to author a new command; Claude calls Write to `~/.claude/commands/strict-deploy.md`. PostToolUse Write hook immediately prompts: "Tag `/strict-deploy` as a `delivery`-mode command? [Y/n]" (default N). User answers Y. File `mv` + symlink as above.
  - **AE6c (non-interactive default):** Same as AE6b but in a CE pipeline fan-out subagent context (non-interactive). Hook detects non-interactive context (heuristic: stdin not a TTY) and defaults to N → file stays global. User can run `/mode:adopt` later if desired.

- AE7. *(Removed; covered R23 which is deferred to V2.1.)*

- AE8. **Covers R29, R5, cross-repo isolation.** Given user has `~/.claude/modes/_global.yaml` with `enabledPlugins: {compound-engineering@every-marketplace: true}` and three mode YAMLs (`delivery.yaml`, `discovery.yaml`, `writing.yaml`); the user opens Claude Code in repo A on branch `feature/x` with `delivery` set, and opens Claude Code in repo B on branch `main` with `writing` set; **simultaneously**; when each session runs `/help`; then repo A's session shows compound-engineering plugin (from `_global.yaml`) plus delivery's additions; repo B's session shows compound-engineering plugin (same global) plus writing's additions. The two sessions are observably independent — neither sees the other's mode. `<repoA>/.claude/settings.local.json` and `<repoB>/.claude/settings.local.json` are filesystem-disjoint.

- AE9. **Covers R29, R1 disable: block.** Given `_global.yaml` declares `enabledPlugins: {compound-engineering@every-marketplace: true, ai-toolkit@every-marketplace: true}`; given a `writing.yaml` mode YAML with `disable: { enabledPlugins: ["compound-engineering@every-marketplace"] }`; when the user runs `/mode:set writing` and `/reload-plugins`; then `/help` shows ai-toolkit (from global, not disabled) but does NOT show compound-engineering (disabled by mode). The cascade engine correctly subtracts.

- AE10. **Covers R32, install registry.** Given the user installs claude-modes and runs `/mode:set delivery` in repos A, B, and C across time; given `~/.claude/modes/.installed-repos.txt` records the absolute paths of A, B, and C; when the user runs `scripts/unmodes.sh`; then the script reads the registry, removes the plugin-owned `<repo>/.claude/settings.local.json` from each of A, B, and C (only if file content matches cascade-engine signature — files the user manually authored at that path are preserved), and deletes any `<repo>/.claude/modes/` directories. Uninstall is comprehensive across all repos where claude-modes was used.

---

## Success Criteria

- **Human outcome — public adoption signal:** within 6 months of V2.0 marketplace publication, at least one non-Shawn user has installed V2 and reports it useful (either via marketplace install count + retention, or a direct testimonial). If zero non-Shawn users adopt despite marketplace listing, the abstraction's universal appeal is wrong and V2 was the wrong bet — but Shawn keeps using it personally as the V0 user, which is also acceptable.
- **Human outcome — Shawn V0:** Shawn has reached for `/mode:set` (any mode, including switches between non-Claude modes) on at least one real project within 30 days post-install. V1's adoption bar carries forward.
- **Human outcome — /doctor pressure dissolves:** in a non-Claude mode, `/doctor` no longer reports descriptor-budget truncation. The harness-bloat problem is structurally addressed.
- **Downstream handoff — planning:** `/ce-plan` can write a Deep implementation plan from this requirements doc without inventing product behavior, scope boundaries, or success criteria. Implementation choices remain in planning territory; product choices are all settled here.
- **Downstream handoff — uninstall credibility:** the automated `tests/integration/install-uninstall-roundtrip.test.sh` proves byte-identical recovery from any sequence of operations. Strangers reading the test code can verify the safety claim themselves.

---

## Scope Boundaries

### Deferred for later

- **Repo mode override (R31).** `<mode-name>.override.yaml` deferred to V2.1 per scope-guardian review 2026-05-18 + user decision 2026-05-18: strictly more niche than R30 (kept in V2.0), structurally entangled with compositional modes / mode inheritance (also deferred). Design alongside those in V2.1.
- **Snapshot mode capture.** A `/mode:snapshot` command that takes the current settings state and bakes it into a new mode YAML. Useful but slightly different mental model from "modes are working stances"; V2.1 candidate.
- **Compositional modes (stacking).** V1 deferred this; V2 does too. A `discovery + oncall` overlay needs conflict-resolution design that's not blocked by V2.0 but isn't required for the category-creation thesis.
- **Mode inheritance.** Same — V2.1 escape valve for compositional concerns.
- **Per-mode hook overrides** beyond what the plugin-owned-keys mechanism provides natively.
- **Convention-driven mode inference.** Auto-suggesting mode based on branch name patterns. V2.0 requires explicit `/mode:set`.
- **Usage telemetry / coverage weighting.** V2.0 lists uncovered user commands without prioritization.
- **Shared mode definitions** (team-level, committed to repos). V2.0's modes are personal config.
- **Mount/unmount semantics for individual agents WITHIN an enabled plugin.** V2.0 mode-scopes at the plugin granularity via `enabledPlugins` plus user catalog at the file granularity. Finer-grained "this plugin is enabled but only some of its agents" requires harness support that doesn't exist today.
- **`/mode:rollback` command** as a first-class slash command. V2.0 ships `scripts/unmodes.sh` for full uninstall; per-set rollback (revert just the last `/mode:set` without uninstalling) is V2.1.
- **Auto-reload on settings file change.** V2.0 relies on user-driven `/reload-plugins`. Auto-reload would need either a Claude Code feature or a file-watcher daemon.
- **Per-mode color in statusline.** V1 carried statusline forward; V2 inherits it as yellow-only. Per-mode color is a V2.1 candidate (forward-compatible field already in V1's authoring skill).

### Outside this product's identity

- **Not a workflow enforcement engine.** Modes shape what the harness exposes; they don't enforce branch state, block merges, validate PR shape, or gate workflows. V1's framing carries forward.
- **Not a plugin manager.** V2.0 reads `~/.claude/settings.json::enabledPlugins` but doesn't install, version, or update plugins. That's marketplace tooling's job.
- **Not a memory or personalization system.** Modes are about the work, not the user's identity or preferences.
- **Not a state machine for project lifecycle.** Discovery → delivery is ONE possible mode pair, not the system's identity. Modes may be intermittent and orderless (modality modes like design / pm / writing).
- **Not multi-user or multi-tenant.** Single user per Claude Code install. No team sharing in V2.0.
- **Not a replacement for skills.** Modes shape what skills are AVAILABLE in a context; they don't substitute for authoring skills.
- **Not a way to write to third-party plugin files.** V1's R19 invariant carries forward. Third-party plugin source is never modified.

---

## Key Decisions

- **Mechanism: cascading config tiers writing to repo-local `settings.local.json`; one small UserPromptSubmit hook for prose injection.** V1's parasitic PreToolUse gate was structurally limited to block-after-attempt because the harness exposes a flat catalog. V2's cascade engine resolves global baseline + mode definition + repo baseline + repo override + per-branch active mode into a single repo-local settings.local.json — letting Claude Code's NATIVE settings cascade (user-global → repo-project → repo-local) do the application work for us. The plugin never owns `~/.claude/settings.json`; it only owns repo-local files in repos where the user invoked `/mode:set`. This eliminates the single-machine-single-mode race, dramatically reduces the trust ask (no mutation of the user's machine-global file), and lets multiple repos hold different modes simultaneously without contention. V2 retains ONE small hook — the `UserPromptSubmit` hook (R25) that prepends the active mode's prose layer to every user prompt — because context injection has no settings.json analogue. The hook never blocks tool dispatch; it only annotates context.

- **Cascade tiers with add-by-default + explicit `disable:` blocks.** V2.0 compiles in tier order: tier 1 `~/.claude/settings.json` (user-owned, read-only) → tier 2 `_global.yaml` (machine baseline) → tier 3 `<mode-name>.yaml` (global mode definition; selected by tier 6's active-mode pointer) → tier 4 `_repo.yaml` (per-repo baseline, optional) → tier 6 `<branch-slug>.mode` (per-branch active-mode pointer — selects which tier-3 file to apply; does not itself contribute settings). Tier 5 (`<mode>.override.yaml`) is deferred to V2.1 per R31. Each tier ADDS by default; tiers 3 and 4 may carry an explicit `disable:` block to subtract specific keys from prior tiers. Most expressive without being implicit; modes can grant additional plugins via add, and a focused mode can subtract globally-loaded plugins via explicit disable. Mode YAMLs (tier 3) CANNOT declare `hooks` — hooks live in tier 2 (`_global.yaml`) and tier 4 (`_repo.yaml`) only, enforced mechanically by the cascade engine. R28 invariant survives.
- **One YAML per mode; plugin generates JSON on swap.** Source-of-truth is human-readable YAML carrying both mechanism and prose. Plugin compiles mechanism → settings.json overlay; prose stays in YAML for runtime injection. Resolves the "JSON is hostile to prose" tension without adopting two-file-per-mode.
- **Claude Mode is a first-class mode, not a null state.** Shawn's reframe during brainstorm: the user's pre-V2 settings.json content becomes the `claude` mode's YAML. There is always exactly one active mode. `/mode:clear` doesn't exist; returning to baseline is `/mode:set claude`.
- **User catalog mode-scoping via staging-dir + symlinks, not frontmatter mutation.** The plugin moves user files ONCE at install (single atomic `mv`, content unchanged); subsequent operations are symlink rebuilds. The plugin never modifies user-authored content in place. The `rm`-on-regular-files invariant is enforced by automated lint.
- **The plugin owns a narrow set of top-level keys in settings.json.** Candidate set (verified during planning): `enabledPlugins`, `permissions`, `hooks`, `env`, `mcpServers`. Everything else (statusLine, etc.) is preserved verbatim on `/mode:set`. User can manually edit non-owned keys without the plugin clobbering them.
- **claude-modes itself is always enabled.** The plugin's enableness is invariant across all modes (else `/mode:set` would stop working after a swap). The plugin enforces this at mode-write time (R22).
- **Reversibility is mechanical and tested.** `scripts/unmodes.sh` ships from V2.0 day one. Round-trip test proves byte-identity. Strangers can audit the source.
- **V1 is dropped, not migrated.** V1's mechanism is incompatible with V2's. Migration tooling would mostly translate semantics that V1 had wrong. The brainstorm-to-V2 path is "author your modes fresh."
- **Hedge against native modes (durability).** V2's YAML schema is designed as a portable abstraction. If Anthropic ships native session-profile / mode mechanism within 12 months, V2's YAMLs should be ingestable by that mechanism with mechanical translation. V2 is positioned as "first-mover that proves the shape"; harness absorption is an acceptable success outcome.

---

## Dependencies / Assumptions

- **Claude Code's `enabledPlugins` mechanism is stable enough to depend on.** The key name and shape are documented in user settings files but not in the plugin-dev SKILL.md. V2 treats this as an empirical contract; if it changes, V2 needs a migration. SessionStart contract anchor (carried from V1) logs the assumed shape so harness-update regressions are observable.
- **`/reload-plugins` re-reads settings.json mid-session.** Empirically true today (Shawn verified it during V1 work). Not documented as a stable API. If the mechanism becomes restart-only, V2 needs to surface that clearly to users and adapt the apply step accordingly.
- **`~/.claude/commands/` and `~/.claude/agents/` are read by the harness as the canonical user-catalog paths.** Standard Claude Code convention. V2 assumes the harness follows symlinks at these paths (not following them would defeat the symlink-rebuild mechanism). [Needs research during planning.]
- **PostToolUse hook on Write events fires reliably for `~/.claude/commands/*.md` writes regardless of whether Claude wrote via tool call or the user wrote via editor.** Open question — Write tool-use vs editor write may not both trigger PostToolUse. If the editor path doesn't fire, R20's "PostToolUse-based opt-in tagging" becomes Claude-tool-use only and the user-via-editor case needs a different mechanism (manual `/mode:adopt <file>`, or a periodic-scan helper).
- **Plugin installation happens via marketplace or symlink** — V2.0 doesn't ship a custom installer beyond what the marketplace flow provides plus `scripts/setup.sh` for the first-run wizard.
- **Single-user model.** V2.0 doesn't reason about multi-user environments. Shared dev VMs, CI runners with multiple users, etc., are out of scope.

---

## Outstanding Questions

### Resolve Before Planning

These four items are P0 blockers surfaced by ce-doc-review (2026-05-17). Each requires a decision or empirical result before `/ce-plan` can produce a buildable plan.

- ~~Multi-worktree user-catalog architecture fork.~~ **Resolved 2026-05-17 → see R27 (SessionStart-driven per-branch reconciliation with flock).**
- ~~R20 PostToolUse-on-editor-writes empirical verification.~~ **Resolved 2026-05-17 → architectural inference confirms PostToolUse matchers fire on tool dispatch, not filesystem events. External editor writes are invisible to hooks. R20 rewritten with three adoption paths: `/mode:adopt <file>` manual command (load-bearing), PostToolUse for Claude-tool writes (immediate UX), SessionStart-scan for editor writes (catches the majority case). See revised R20 + AE6 a/b/c.**
- ~~Hooks-injection threat model + validation gate design.~~ **Resolved 2026-05-17 → V2.0 stance: hooks are NOT plugin-owned (R28); permissions get a diff/confirm gate (R5 revised). V2.1 may revisit if mode-scoped hooks become a demonstrated need.**
- **/reload-plugins reload-semantics matrix — Day 1 of planning.** Binary inspection (Claude Code 2.1.138) shows "Restart to apply" co-occurs with plugin/MCP changes; `enabledPlugins` flip likely reload-safe, `mcpServers` likely requires restart. Also unverified that `/reload-plugins` actually purges descriptors from model context (the core "/doctor pressure dissolves" premise). **Day 1 of `/ce-plan` must execute the matrix below before any V2 code is written.** Results dictate which keys remain in R5's plugin-owned set (currently: enabledPlugins, env, permissions, mcpServers — hooks already excluded per R28).

  **Test recipe** (run in a fresh Claude Code session per matrix row to avoid context pollution):

  | Row | Key | Test |
  |---|---|---|
  | 1 | `enabledPlugins` | Fresh session A: `/doctor` baseline → record agent count. Edit `~/.claude/settings.json` to disable 5 plugins → `/reload-plugins` → re-run `/doctor`. Open fresh session B → `/doctor`. Expected: count drops in BOTH session A AND session B. If only B drops, A's context is sticky and /reload-plugins doesn't purge model-context → V2's thesis needs reframing. |
  | 2 | `enabledPlugins` (re-enable) | After row 1, re-enable the 5 plugins → `/reload-plugins` → re-run `/doctor`. Expected: count returns to baseline. Probes whether descriptor space is reclaimed or just re-counted. |
  | 3 | `permissions` | Fresh session: baseline tool list. Edit settings to add a new permission grant → `/reload-plugins` → attempt to use the newly-granted action. Expected: works without restart. If it requires restart, `permissions` is restart-only and the R5 diff/confirm gate needs a restart prompt. |
  | 4 | `env` | Fresh session: read an env-var-dependent setting. Edit env in settings → `/reload-plugins` → re-read. Expected: new value visible. |
  | 5 | `mcpServers` (toggle off) | Fresh session: list tools from an MCP server. Edit settings to remove that MCP server → `/reload-plugins` → list tools. Expected (per binary evidence): tools still listed; restart prompt UX needed. If they DO disappear cleanly, R5 can include mcpServers without restart UX. |
  | 6 | `mcpServers` (toggle on) | Reverse of row 5. Add an MCP server entry → `/reload-plugins` → check tool list. Expected: tools appear or restart needed. |
  | 7 | `/doctor` descriptor counting | Critical row: does /doctor count plugin descriptors *currently in the model's context*, or descriptors in the *current settings.json state*? Edit settings to disable a plugin → DO NOT run /reload-plugins → run /doctor. If count drops without reload, /doctor reads settings.json (V2's mechanism doesn't actually need /reload-plugins for the /doctor success criterion). If count stays, /doctor reads runtime state (V2 needs /reload-plugins to dispatch). |

  **Decision rule based on results:**
  - Row 1 result is load-bearing. If session A's count doesn't drop, V2.0 needs to be reframed as "use Claude Mode in long sessions, set restrictive modes only at session start." That's a significant scope reframe; surface to Shawn before continuing planning.
  - Rows 3, 4 confirm whether `permissions` and `env` stay in plugin-owned. Failing rows → drop from V2.0, defer to V2.0.x dot-release once a workaround is settled.
  - Rows 5, 6 confirm whether mcpServers stays. If restart-required, either drop from V2.0 or add a restart-prompt UX to R5 (`/mode:set` surfaces "this mode requires Claude Code restart — continue? [y/N]").
  - Row 7 tells us whether /reload-plugins is even necessary for the central /doctor goal or whether settings.json mutation alone is enough.

  Record results in a `docs/plans/2026-05-XX-reload-matrix-results.md` artifact that planning and implementation both reference.

### Deferred to Planning

**Original technical deferrals (pre-review):**

- [Affects R5][Technical] Exact set of plugin-owned top-level keys in settings.json. Candidates: `enabledPlugins`, `permissions`, `hooks`, `env`, `mcpServers`. Verify each one (a) is mode-relevant and (b) is safe to fully replace. Determine during planning by reading Claude Code's settings spec. *(See also "Resolve Before Planning" reload-semantics matrix.)*
- [Affects R8][Technical, Needs research] Is there a way to programmatically trigger `/reload-plugins` from a hook or shell command, or is it strictly user-typed? Determine empirically during planning.
- [Affects R10][Technical] Exact YAML schema for the user-catalog manifest in a mode YAML. Filename list? Glob patterns? Per-file inclusion/exclusion? Determine in planning based on which shape is easiest to author. *Plan should also verify the chosen shape doesn't preclude a future stacking/inheritance extension (compositional modes — V2.1).*
- [Affects R15][Product, Deferred during planning] When the mode-author skill asks "which axes does this mode shape," what does the conversation look like if the user says "all of them" vs "just one"? Detailed conversation choreography is U10-level planning detail.
- [Affects R22][Technical] Verifying `claude-modes` is in enabledPlugins requires knowing the plugin's identifier format (`<plugin-name>@<marketplace-name>`). The marketplace name isn't fixed until the plugin is published. Plan must address how the plugin self-identifies before it has a marketplace home.

**Surfaced by ce-doc-review (2026-05-17). P2 — significant decisions for planner to settle:**

- [Affects R6][scope-guardian] R6's per-branch state file (`<repo>/.claude/modes/<branch-slug>.mode`) has no V2.0 reader. F2 writes it but no requirement reads from it; auto-restore on branch checkout is a Deferred-for-later item. Decide during planning: keep R6 as write-only state (premature scope), drop R6 from V2.0 entirely, or pull auto-restore-on-checkout forward from V2.1 to give R6 a consumer.
- [Affects R10, R15][scope-guardian] Mode-author conversational skill is shipping on an unfinalized user-catalog YAML schema. Decide whether to ship the skill in V2.0 (paired with schema finalization at planning entry) or defer to V2.1 and let V2.0 users hand-write YAML.
- [Affects R3, R17, AE1][adversarial, feasibility] "Byte-identical" claim is content-only (SHA-256 of regular files). Post-install, files at original paths are observable-as-symlinks (`[ -L ]`, `stat`, `realpath` all see different state). External tools indexing those paths see different file types. Decide during planning whether to (a) narrow the marketing claim to "content-identical via cat", (b) extend the round-trip test to assert metadata equivalence, or (c) detect external indexers via `/mode:setup` and offer to skip the move-then-symlink for affected files.
- [Affects R3][adversarial, security-lens] Hard links and cross-filesystem mv. R3's "single atomic op" claim is filesystem-dependent. Decide during planning whether to (a) detect and refuse install when `~/.claude` is on a different filesystem from the install target, (b) detect hard links to outside `~/.claude/commands/` and warn, or (c) fall back to copy+verify+delete with explicit error handling.
- [Affects Premise][product-lens F3] V2's success criteria are non-overlapping and collectively exhaustive (public win, absorption win, personal-tool win) — no outcome counts as failure. Before planning, name one concrete failure condition (e.g., "if by month 6 zero non-Shawn adopters AND Shawn used /mode:set fewer than 4 times, V2 is archived at v0.2.0-experiment"). Without that, the bet is unfalsifiable and downstream maintenance decisions inherit the structure.
- [Affects Premise][product-lens F1] Vim-modal vs IDE-perspective switching frequency unexamined. V2's mechanism (slash command + reload) has non-trivial switch cost, biasing toward IDE-perspective usage (set once, rarely switch). But R6 and R20 are designed around frequent switching. Either name the expected switching frequency explicitly, or deprioritize R6/R20 if usage will be IDE-perspective-like.
- [Affects Success Criteria][product-lens F4, scope-guardian] "/doctor pressure dissolves" goal depends on `/reload-plugins` actually purging plugin descriptors from the model's context, not just from `/help` output. *Subsumed by the reload-semantics matrix in Resolve Before Planning.*
- [Affects Premise][product-lens F5] Trust-ask escalation. V2 is materially more invasive than V1 (moves user's files, may own settings.json). Stranger adoption test (A3) is structurally hard to pass. Decide during planning whether to default to a less invasive mode (e.g., conservative mode by default, R21 inverted) to reduce the trust ask.
- [Affects R20][security-lens 6] R20 default-Y consent prompt unsafe in non-interactive contexts (CE pipeline fan-outs, background subagents). Decide during planning whether to (a) detect automation context and skip the prompt, (b) default to N (safe default: do nothing), or (c) require explicit interactive-mode flag.
- [Affects R13][feasibility F4] R13 lint pattern under-specifies destructive verbs. Beyond `rm`/`unlink`, the lint must also catch: `find -delete`, `> file` (truncation), `: > file`, `truncate -s 0`, `cp /dev/null file`, `mv /tmp/empty.md file` (overwrite), `tee file < /dev/null`, in-place `sed -i`. Decide during planning whether to (a) maintain a denylist of destructive verbs (and which), or (b) maintain an allowlist of plugin-owned write paths.

**Surfaced by ce-doc-review (2026-05-17). P3 — clarifications and FYI:**

- [Affects R9][coherence] Spec the parser behavior when V1 mode YAMLs (`schema_version: 1`) are detected in `~/.claude/modes/` at V2 install: warn-and-leave-in-place, move-to-backup, or fail-loud. Add to F1 install flow.
- [Affects R3, R4, R7, R12, R20, F1, F5][coherence] Terminology drift: "user-catalog directory" vs ".user-catalog" vs "staging dir" vs "user-catalog manifest" are used interchangeably. Standardize: "user-catalog directory" for the filesystem artifact; "user-catalog manifest" for the YAML field; pick one and use consistently.
- [Affects R2, F1, F4][coherence] Claude Mode frozen-snapshot vs live-reference ambiguity. Decide and document whether Claude Mode's YAML is captured once at install (frozen) or refreshed from current settings (dynamic). Affects what `/mode:set claude` restores.
- [Affects R22, AE5][coherence] AE5 prescribes error message text more verbose than R22's spec. Either quote AE5's text in R22 or note that AE5 illustrates the spirit, not the canonical wording.
- [Affects R5, R7, R12, R13][coherence] "plugin-owned" used many times, never explicitly defined. Add glossary: "plugin-owned keys = enabledPlugins, env, permissions, mcpServers (post-reload-matrix-verification; `hooks` explicitly NOT plugin-owned per R28); plugin-owned symlinks = symlinks whose realpath-resolved target is inside `~/.claude/modes/.user-catalog/`."
- [Affects R16][scope-guardian] Statusline carry-forward has no acceptance example. Either add an AE confirming yellow `[mode] cwd-basename` displays correctly post-install, or annotate R16 as zero-cost carry-forward.
- [Affects Scope Boundaries — Compositional][scope-guardian] V2.0 YAML schema design should not preclude compositional modes (stacking/inheritance) in V2.1. Planner should verify the chosen manifest shape supports a future overlay extension without requiring V2.0 YAML migration.
- [Affects R16, audit log][security-lens 8] Audit log inheritance from V1 is unqualified. Spec what the audit log records in V2: mode identifiers and operation timestamps only — never raw mechanism payload values (MCP creds, env vars, hook command lines).

**Surfaced by cascade-update doc-review (2026-05-18). Coherence + scope items for planner to resolve:**

- [Affects R2, F1][coherence] Claude Mode's YAML — frozen-vs-dynamic ambiguity. Decide during planning: `~/.claude/modes/claude.yaml` is captured ONCE at install (frozen snapshot of pre-install settings) OR computed on-the-fly from current tier 1 + tier 2 each `/mode:set` invocation. Under the cascade model, "Claude Mode" is the no-modes-active state (tiers 1 + 2 only), so a static `claude.yaml` file may be redundant — could be eliminated entirely in favor of "no tier 3 selected = Claude Mode."
- [Affects R1][coherence] User-catalog manifest YAML schema. R1 says modes carry "mechanism" + "prose" + "user-catalog manifest" but the relationship between mechanism keys (enabledPlugins, env, etc.) and the user-catalog manifest (commands, agents lists) is not explicit. Decide schema during planning: is `user_catalog:` a top-level mode YAML key, sibling to `mechanism:` and `prose:`? Or is it a sub-key under `mechanism:`?
- [Affects R7, R3][coherence] Cross-filesystem + hard-link edge cases for user-catalog moves. Already in Deferred-to-Planning (P2 from prior review); reaffirming.
- [Affects R20][coherence] SessionStart scan state management. Where does the plugin store "last scan" metadata (file at `~/.claude/modes/.user-catalog-scan.json` or similar)? When is it updated (session start, session end)? Decide during planning.
- [Affects R26][coherence] Idempotence scope under cascade. R26 says `/mode:set` is idempotent given fixed inputs — but the cascade has multiple input tiers (`_global.yaml`, mode YAML, repo tier). Clarify: idempotence means "given fixed tiers 1, 2, 3 and the same mode name, two `/mode:set` invocations produce identical settings.local.json." If any tier changes between invocations, the cascade recomputes — this is correct behavior, not an idempotence failure.
- [Affects R10, R15][scope-guardian F6] Mode-author skill cascade-awareness. The skill produces tier-3 mode YAMLs but the user's hook-related needs go in tier 2 (`_global.yaml`). Decide during planning: does the skill detect when a user describes a hook-related need and redirect them to edit `_global.yaml` directly? Or does the README alone handle that guidance? If the skill covers it, add a conversation branch to R10/R15's Phase 2.5 axes question.
- [Affects R29, R30][scope-guardian F5] Cascade tier additions gated on reload-matrix. If U1 row 1 fails (V2's reload thesis broken), the entire cascade model becomes meaningless. R29 + R32 ship gated on a green matrix. R30/R31 (already deferred to V2.1) remain deferred only if the matrix passes; if it fails, V2 needs a complete reframe and R30/R31 may be permanently mooted.
- [Affects AE coverage][coherence] Add AE for explicit cascade tier visibility in /mode:status (Finding 14). When the user runs /mode:status with both _global.yaml and a tier-3 mode active, the output should clearly show which tiers contributed which keys.
- [Affects glossary][coherence] Add explicit glossary entry: "plugin-owned keys = enabledPlugins, env, permissions, mcpServers (post-reload-matrix-verification; `hooks` explicitly NOT plugin-owned in mode tiers per R28, but DOES flow through cascade from tier 2 `_global.yaml`); plugin-owned symlinks = symlinks whose realpath-resolved target is inside `~/.claude/modes/.user-catalog/`."

### Deferred to V2.1+ (post-launch product decisions)

- Per-mode color in statusline (V1 left the field forward-compatible).
- `/mode:snapshot` capture flow.
- Compositional / inherited modes.
- Auto-reload on settings change.
- `/mode:rollback` for per-swap undo (vs. `unmodes.sh` for full uninstall).
- Convention-driven mode inference (branch-name patterns).
- Shared / team-level modes.

---

## Next Steps

This doc has been through ce-doc-review (2026-05-17) — six reviewer personas (coherence, feasibility, product-lens, scope-guardian, adversarial, security-lens) surfaced 28 findings. 4 P0 gates were settled in-conversation (multi-worktree → R27, R20 PostToolUse → R20 + AE6 rewrite, hooks-injection → R28 + R5 revise, reload-semantics matrix → day-1 planning recipe). 6 P1s revised in-place (R7 path-traversal, R23 deferral, R22 wedge-prevention, R24 chmod 0600, R17 drift-aware uninstall, R25 prose-injection hook, R26 idempotent /mode:set). 17 P2/P3 findings appended to Deferred-to-Planning with persona attribution.

→ **`/ce-plan`** for structured implementation planning of V2.0.

Recommended planning depth: **Deep**.

**Day 1 of `/ce-plan` MUST execute the reload-semantics matrix** in "Resolve Before Planning" before any V2 code is written. Results dictate which plugin-owned keys remain in R5 and whether V2's central "/doctor pressure dissolves" thesis is structurally sound. If row 1 fails (session A's count doesn't drop), surface to Shawn before continuing — that's a thesis-reframing trigger.

The plan will need to address: the install/uninstall lifecycle (R3, R17 drift-aware, R18, R21), the YAML schema (R1, R9, deferred user-catalog manifest shape), the symlink mechanism (R3, R7 with path-traversal validation, R12), the prose-injection hook (R25), the per-branch reconciliation mechanism (R27 with flock + no-op-fast-path), the idempotent crash-safe /mode:set (R26), the new-file adoption paths (R20 a/b/c), the round-trip test infrastructure (R17 + AE1 + AE4), and the 0600 permission invariant (R24).

Plan should explicitly preserve the V1 institutional knowledge as origin:

- V1 origin docs: `docs/brainstorms/2026-05-15-modes-as-infrastructure-requirements.md`, `docs/plans/2026-05-15-001-feat-modes-as-infrastructure-plan.md`
- V1 archived working tree: git tag `v0.1.0-experiment`
- V1 reusable substrate (kept conceptually, may need translation): `claude_modes::slugify_branch`, audit log pattern, mode-author phased conversation flow, statusline + OSC 2 title escape, the canonical PreToolUse JSON shape (carried as documentation even though V2's mechanism doesn't use PreToolUse blocking), `$HOME`-isolation test pattern, R19 lint pattern (generalized to "no destructive verbs on user paths").
