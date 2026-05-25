---
date: 2026-05-15
topic: modes-as-infrastructure
---

# Modes as Infrastructure

## Problem Frame

Claude Code users develop muscle memory for how they want commands, skills, and agents to behave in different *kinds of work* — exploring an unknown codebase needs different review heuristics than shipping a delivery PR; debugging needs different agent availability than designing. Today this is tacit: users either type long context preambles every time, route around tools that behave wrong-for-the-moment, or accept that some commands fight them in some situations.

The cost compounds. Tacit modes mean (1) users can't reliably enter and stay in a working stance, (2) Claude's response varies based on whatever the user remembered to type, and (3) the tacit knowledge can't be authored, shared, or evolved over time.

This plugin introduces **modes** as a first-class concept: named, durable definitions of *a way of working* that shape how Claude's command surface, agents, and skills behave when a mode is active. Modes are user-authored, persisted per-branch, and applied automatically via harness hooks — no modifications to third-party plugins required.

The originating example is a two-mode split — **discovery** (sprawl-by-design exploration phase, light review bar, breadcrumb commits) and **delivery** (shipping phase, strict bar, targeted reviews, decomposed plans) — but the plugin ships with **zero modes pre-defined**. Users author their own through an interactive registry editor; the system supports any number of mutually-exclusive modes the user chooses to define.

---

## Actors

- A1. **Mode author** — the user authoring or refining mode definitions. Uses the registry editor to declare mode philosophy, scope, lens, and per-command bindings. Promotes inferred bindings to authored ones over time.
- A2. **Mode user** — the user invoking commands while in an active mode. Sets, switches, and clears modes; receives mode-shaped behavior from commands; sees mode visibility in their session.
- A3. **Third-party plugin** — installed Claude Code plugins (CE, slate-plugins, document-skills, etc.) whose commands, skills, and agents are *shaped* by active modes but not modified by them. Unaware of mode infrastructure.
- A4. **Claude (the model)** — receives mode-augmented prompts and mode-gated delegation surfaces; executes commands with mode-derived heuristics applied. Performs runtime inference for commands without authored bindings in the active mode.
- A5. **Hook runtime** — the Claude Code harness firing UserPromptSubmit, PreToolUse, and SessionStart hooks. Responsible for injecting mode context and gating delegation calls.

---

## Key Flows

- F1. **Author first mode (empty-start setup)**
  - **Trigger:** A1 invokes `/mode:registry` for the first time on a fresh install
  - **Actors:** A1, A4
  - **Steps:**
    1. Registry editor reports zero modes defined
    2. Claude prompts: "What kind of work is this mode for?"
    3. A1 describes intent in prose (philosophy, lens, when-to-use)
    4. Claude proposes mode definition (name, description, philosophy, scope, lens, constraints) and shows it for confirmation
    5. A1 accepts or refines
    6. Mode definition persisted to `modes/<name>.yaml` in user's `~/.claude/` directory
    7. Registry indexes the new mode; coverage shows 0 authored bindings (all command behavior is inferred)
  - **Outcome:** One mode exists, defined in prose, with no authored bindings yet. Can be activated.
  - **Covered by:** R1, R2, R3, R8, R15

- F2. **Set mode for current work**
  - **Trigger:** A2 invokes `/mode:set <name>` on a branch
  - **Actors:** A2, A5
  - **Steps:**
    1. Plugin reads current branch via `git rev-parse --abbrev-ref HEAD`
    2. If a mode is already active on this branch, prompt for confirmation (transitions are explicit, not silent)
    3. Write mode name to `<repo>/.claude/modes/<branch-slug>.mode`
    4. SessionStart hook (next session) and `/mode:status` (this session) both surface the active mode
  - **Outcome:** Branch is now associated with the named mode; subsequent command invocations on this branch will be mode-shaped.
  - **Covered by:** R4, R5, R12

- F3. **Invoke a command in active mode (authored binding)**
  - **Trigger:** A2 types a slash command (e.g., `/ce-code-review`) while a mode is active on the current branch
  - **Actors:** A2, A4, A5
  - **Steps:**
    1. UserPromptSubmit hook fires; reads current branch's mode
    2. Hook looks up the command in the mode's authored bindings
    3. Found: hook compiles the authored heuristic block to prose and prepends as system-reminder
    4. Claude receives augmented prompt and executes command with heuristics applied
  - **Outcome:** Command behavior is shaped by the mode's authored heuristic deterministically (same prose injected every time).
  - **Covered by:** R6, R7, R10

- F4. **Invoke a command in active mode (runtime inference)**
  - **Trigger:** A2 types a slash command for which the active mode has no authored binding
  - **Actors:** A2, A4, A5
  - **Steps:**
    1. UserPromptSubmit hook fires; reads current branch's mode
    2. Hook looks up the command in the mode's authored bindings — not found
    3. Hook injects the mode's full definition (philosophy, scope, lens, constraints) as system-reminder, marked as inference context
    4. Claude reads the definition and derives appropriate behavior for this command on the fly
  - **Outcome:** Command behavior is shaped probabilistically by the mode's intent. May vary slightly across sessions.
  - **Covered by:** R6, R9, R11

- F5. **Delegation gating (subagent call blocked)**
  - **Trigger:** A4 tries to dispatch a subagent that the active mode has unmounted
  - **Actors:** A4, A5
  - **Steps:**
    1. PreToolUse hook fires on `Agent` tool call
    2. Hook reads `subagent_type` from tool input and active mode's `delegation.agents.unmount` list
    3. Match: hook returns block decision with visible error message
    4. Claude sees the block, reports it to A2 (e.g., "ce-adversarial-reviewer is unmounted in mode discovery. Switch to delivery first or override with /mode:override-once.")
  - **Outcome:** Subagent call is hard-blocked; A2 sees mechanical enforcement.
  - **Covered by:** R10, R13

- F6. **Promote an inferred binding to authored**
  - **Trigger:** A1 invokes `/mode:registry promote /ce-debug delivery` after using `/ce-debug` in delivery mode and finding the inferred behavior good
  - **Actors:** A1, A4
  - **Steps:**
    1. Registry editor surfaces the heuristics block that was inferred at runtime (last inference, or recompute on demand)
    2. A1 accepts as-is, refines, or rejects
    3. Accepted heuristic block is written to the mode's authored bindings
    4. Future invocations of this command in this mode skip inference and use the authored block (deterministic + faster)
  - **Outcome:** One more (command × mode) binding moves from inferred to authored.
  - **Covered by:** R8, R9, R16

---

## Requirements

**Mode definition and storage**

- R1. A mode is a named, durable definition expressing *a way of working* — philosophy, scope, lens, constraints — primarily in prose. Per-command bindings and delegation gates are structured appendices, not the heart of the file.
- R2. Mode definitions live in `~/.claude/modes/<name>.yaml`. Repo-local override allowed at `<repo>/.claude/modes/<name>.yaml` — repo-local wins when both exist.
- R3. The plugin ships with **zero modes pre-defined**. Users author their first mode through the registry editor; modes accumulate from intentional authorship, not from inherited defaults.

**Mode activation and state**

- R4. Mode state is **per-branch**. Stored at `<repo>/.claude/modes/<branch-slug>.mode` as a single line referencing a mode name.
- R5. Modes are **mutually exclusive**. At most one mode is active per branch at any time. No composition rules.
- R12. Switching modes on a branch (including clearing) requires explicit user confirmation. Silent flips are disallowed because mode transitions correspond to real working-stance changes (e.g., discovery → delivery is the load-bearing carve moment).

**Heuristic injection (probabilistic mechanism)**

- R6. A UserPromptSubmit hook fires on every user prompt, reads the active mode (if any) for the current branch, and matches the prompt against the mode's bindings.
- R7. **Exact slash command match only.** The hook matches prompts starting with `/<command>` or `/<plugin>:<command>` against the mode's binding keys. Natural-language prompts are not mode-shaped. The hook handles both bare and plugin-namespaced forms.
- R10. When a match is found and an **authored** binding exists, the hook injects the authored heuristic block compiled to prose as a system-reminder.
- R11. When a match is found but **no authored** binding exists, the hook injects the mode's full definition (philosophy, scope, lens, constraints) as a system-reminder marked as inference context. Claude is expected to derive command behavior from the definition at runtime.

**Delegation gating (deterministic mechanism)**

- R13. A PreToolUse hook fires on `Agent` tool calls, reads the active mode's `delegation.agents` list, and blocks calls targeting unmounted subagents. Block returns a visible error message naming the gated subagent and the active mode.
- R14. Delegation gates also apply to skills (`delegation.skills`). A mode can mount/unmount skills the same way it mounts/unmounts agents.
- R23. Commands are **never** hidden or blocked by modes. Every command remains callable in every mode. Modes shape command *behavior*, not command *availability*.

**Registry**

- R8. The plugin maintains a **registry** of (command, mode) bindings, derived from the YAML mode files plus a scan of the available command surface. The registry is the authoritative model for what modes know about and what they affect.
- R9. Each binding carries provenance: **authored** (explicitly written by the user via the editor), **inferred** (derived at runtime from mode definition, not yet promoted), or **uncovered** (mode hasn't been applied to this command yet).
- R15. The registry editor (`/mode:registry`) is the **primary authoring surface**. Users author modes and refine bindings through interactive conversation with Claude, not by editing YAML directly. YAML files are durable backing; the editor is the workflow.
- R16. The registry supports **promotion** — turning a runtime-inferred binding into an authored one. Promotion is the central UX for maturing a mode over time.
- R20. The registry is **derivable**, not a primary source of truth. If corrupted or out of sync, regenerating it from `~/.claude/modes/*.yaml` + a fresh command-surface scan must produce an equivalent registry. Authored bindings persist in YAML; only inference caches and coverage indices live in the registry alone.
- R21. The registry exposes a **coverage view** — which commands the user invokes frequently but have no authored binding in the active mode. Surfaced when authoring or when invoked explicitly (`/mode:registry coverage`).

**Slash commands**

- R17. The plugin provides at minimum: `/mode:set <name>`, `/mode:status`, `/mode:clear`, `/mode:registry` (interactive editor), `/mode:registry coverage`, `/mode:registry promote <command> <mode>`.

**Visibility**

- R18. The active mode is visible to the user without explicit query: first-injection announcement once per session (e.g., "🔧 Mode: delivery (set 2026-05-13)"), statusline indicator if the harness supports it, and visible error block on gated delegation calls.

**Third-party plugin compatibility**

- R19. The plugin must **not modify** any third-party plugin files. All mode behavior is achieved through harness hooks (UserPromptSubmit, PreToolUse, SessionStart) and the plugin's own slash commands. This includes CE, slate-plugins, document-skills, and any other installed plugins.
- R22. The plugin must tolerate third-party plugins changing or being added. New plugins installed after a mode is authored automatically appear as **uncovered** commands in the coverage view; existing modes continue working with no migration needed.

---

## Acceptance Examples

- AE1. **Covers R3, R15.** Given a fresh install with no modes defined, when the user invokes `/mode:registry`, then the editor reports zero modes and prompts the user to author their first mode through conversation.

- AE2. **Covers R6, R10.** Given delivery mode is active on the current branch and has an authored binding for `/ce-code-review`, when the user invokes `/ce-code-review`, then the UserPromptSubmit hook injects the authored heuristic block as a system-reminder before the prompt reaches the model.

- AE3. **Covers R6, R11.** Given delivery mode is active and has *no* authored binding for `/ce-debug`, when the user invokes `/ce-debug`, then the hook injects the full delivery mode definition (philosophy, scope, lens, constraints) as a system-reminder marked as inference context, and Claude derives appropriate behavior.

- AE4. **Covers R7, R23.** Given delivery mode is active, when the user types "review this PR for me" (natural language, not a slash command), then no mode injection occurs and the prompt reaches the model unaugmented.

- AE5. **Covers R13, R19.** Given discovery mode is active and has unmounted `ce-adversarial-reviewer`, when Claude (executing some CE workflow) attempts to dispatch `ce-adversarial-reviewer`, then the PreToolUse hook blocks the call with a visible message naming the gated subagent and the active mode. CE's files are not modified.

- AE6. **Covers R12.** Given discovery mode is currently active on the branch, when the user invokes `/mode:set delivery`, then the system prompts for explicit confirmation before the mode flip is written.

- AE7. **Covers R16.** Given `/ce-debug` was used in delivery mode and produced a useful inferred binding, when the user invokes `/mode:registry promote /ce-debug delivery`, then the registry editor surfaces the inferred heuristic block, lets the user accept/refine/reject, and on acceptance writes the heuristic into delivery mode's authored bindings.

- AE8. **Covers R22.** Given delivery mode was authored before plugin `new-plugin` was installed, when `new-plugin` is later installed and adds `/new-plugin:foo`, then `/new-plugin:foo` appears as **uncovered** in delivery mode's coverage view. Delivery mode continues to function for previously-bound commands without changes.

---

## Success Criteria

**Human outcome:**
- Shawn can author a mode by describing its intent in conversation, set the mode on a branch, and observe that subsequent commands behave according to the mode's intent — without typing context preambles or re-explaining the mode each invocation.
- A second mode (e.g., delivery vs. discovery) produces materially different command behavior for the same commands, observable to Shawn within minutes of authoring both.
- Shawn trusts the system enough to *stay in modes* during real work, rather than disabling or routing around them.

**Downstream agent handoff:**
- A planner (`/ce-plan`) reading this requirements doc can produce an implementation plan without inventing product behavior, scope boundaries, or mode semantics. The doc names every load-bearing decision (per-branch state, exact-match injection, authored vs. inferred provenance, third-party non-modification, etc.) explicitly enough to constrain implementation choices.
- A future contributor can author a new mode (e.g., "debug mode") using the registry editor without reading source code — the conversation with Claude carries them through definition, initial bindings, and coverage review.

---

## Scope Boundaries

### Deferred for later

- **Mode-flavored command grammar** (e.g., `/ce-plan:discovery` as a structurally different command than `/ce-plan:delivery`). V1 keeps all commands callable in all modes (R23); behavior differs only via heuristic injection. Grammar-level branching is a V2 lane.
- **Compositional modes** (stacking multiple modes simultaneously). V1 is mutually exclusive (R5). The escape valve for V2 is *mode inheritance* (a `discovery-oncall` mode defined as discovery + a small overlay) rather than runtime composition rules.
- **Branch-creation inheritance** (does a new branch inherit its parent branch's mode?). V1 defaults to "no inheritance — new branches start with no mode until explicitly set." Revisit if it becomes friction.
- **Branch rename/delete migrations** (orphaned mode entries when a branch is renamed). V1 documents the sharp edge but doesn't automate cleanup.
- **Convention-driven mode inference** (e.g., `feature/*-pr*-*` patterns auto-suggest a mode at branch checkout). V1 requires explicit `/mode:set`. V2 may layer pattern-based suggestion *on top of* explicit entry, never replacing it.
- **Usage-frequency telemetry** (the "you use /ce-plan weekly but it's uncovered" surface from F6). V1's coverage view lists uncovered commands without weighting; usage tracking is V2.
- **Shared mode definitions** (mode YAML committed to repos and shared across team members). V1's mode files are personal config; nothing prevents users committing them later, but V1 doesn't optimize for that workflow.
- **`/mode:override-once`** (the per-invocation override for delegation gates mentioned in F5). V1 lists the gate; the override mechanism is V2.
- **Targeted-review scope mechanics** for delivery-mode `/ce-code-review`. The default heuristic prose can say "targeted reviews" but the mechanical scope (staged files vs. branch-diff-against-main vs. prompt-user) is a V2 refinement. V1 default: prose-only guidance, no mechanical scoping.

### Outside this product's identity

- **Not a workflow enforcement engine.** Modes shape disposition and gate delegation; they do *not* enforce branch state, block merges, validate PR shape, or run external compliance checks. If the user wants those, that's a different product (CI, branch protections, separate tooling).
- **Not a Claude Code plugin manager.** Modes mount/unmount agents and skills at the *delegation* layer; they don't install, uninstall, or version third-party plugins. The plugin surface remains owned by the harness and other plugin systems.
- **Not a personalization or memory system.** Modes are about *the work being done*, not *who is doing it*. Personal preferences belong in `CLAUDE.md` and the memory system; modes are orthogonal.
- **Not a replacement for skills.** Modes shape how skills behave; they are not themselves a substitute for authoring skills. A "debug mode" is not the same as a `/debug` skill — the mode is a lens, the skill is a procedure.
- **Not a state machine for project lifecycle.** Discovery → delivery is *an example* of mode use, not the product's core abstraction. Other users may define modes that have no temporal sequence to them (e.g., `oncall` and `polish` may both apply intermittently, in any order).
- **Not multi-user or multi-tenant.** Mode state is single-user, single-machine. No syncing, no permissions, no audit trail beyond local file mtime.

---

## Key Decisions

- **Modes are mutually exclusive in V1.** *Rationale:* compositional modes introduce conflict resolution as a first-class problem. Most "powerful and flexible" systems get composition wrong on the first attempt. Mutually exclusive is the simpler, more debuggable, more predictable starting point. Composition can be layered later via named overlays without breaking the V1 invariant.

- **Mode state lives per-branch.** *Rationale:* branches are durable across sessions, follow naturally with `git checkout`, work cleanly with worktrees (each worktree has its own branch, gets its own mode for free), and don't require session memory or harness-level state. Other scopes (per-session, per-repo, per-task) all had worse surprise profiles.

- **Plugin ships with zero pre-defined modes.** *Rationale:* shipping with discovery/delivery as defaults would bake those modes into the system's identity and signal that they're the "right" modes. The empty-start design dogfoods the registry editor as the primary authoring path and forces the system to be genuinely mode-agnostic (not "discovery/delivery plus the ability to add others").

- **Modes shape both heuristics (probabilistic, command-level) and delegation (deterministic, agent/skill-level).** *Rationale:* heuristics-only V1 would be too soft to drive adoption (model-attended behavior is unreliable for load-bearing rules). Adding deterministic delegation gates closes the trust gap without requiring the more invasive mechanism (grammar-level command branching). The split is the smallest V1 that delivers both adoption-grade enforcement and authoring-grade flexibility.

- **Commands are never hidden or blocked by modes; only agents/skills can be gated.** *Rationale:* commands are the user's interface to the system — hiding them would fight muscle memory. Agents and skills are *delegation surfaces* (Claude reaches for them on the user's behalf); gating those changes how Claude operates without shrinking the user's control surface. Asymmetric, and that asymmetry is load-bearing.

- **Authored bindings are deterministic; inferred bindings are runtime-derived.** *Rationale:* users need stable, repeatable behavior for the commands they use most — that's authored. For the long tail of commands they invoke occasionally, runtime inference from the mode definition is "good enough" and avoids forcing exhaustive upfront authoring. The promotion workflow is the bridge: usage reveals which inferences are worth crystallizing.

- **Exact slash command match only; no fuzzy or natural-language matching.** *Rationale:* false positives in mode injection would erode trust quickly. Slash commands are an explicit "I want structured behavior" signal from the user. Natural-language prompts are conversational and don't benefit from automatic mode shaping enough to justify the false-positive risk.

- **Third-party plugins are never modified.** *Rationale:* CE, slate-plugins, and other plugins update frequently and are owned upstream. Forking or patching them would create maintenance debt the plugin cannot absorb. The hook-based approach is parasitic by design — modes observe and augment, never modify.

- **Mode definitions are prose-primary, not config-primary.** *Rationale:* the mode's worldview is the load-bearing artifact. Per-command heuristics are *derived* from the worldview; if the worldview is captured well, derivation is straightforward. Config-primary modes (binding lists) would force exhaustive authoring upfront and lose the ability to shape novel commands.

- **The registry is derivable from YAML + command-surface scan.** *Rationale:* keeps YAML as the durable source of truth (version-controllable, portable) while still allowing the registry to carry richer semantics (provenance, coverage, inference cache). If the registry is corrupted, regenerate.

---

## Dependencies / Assumptions

- **Claude Code harness exposes UserPromptSubmit and PreToolUse hooks.** Verified — both hook types are documented and the user's existing `~/.claude/settings.json` shows hooks of these types in active use. Existing examples in `~/.cc-cmux/handler.cjs` confirm hook implementation patterns.

- **Slash commands are routable via plugin manifest.** Verified by inspection of existing plugins (`crex`, `slate-plugins`) — slash commands are declared in `.claude-plugin/plugin.json` and resolved by the harness.

- **The PreToolUse hook can block tool calls with a structured response.** Assumed based on Claude Code documentation; should be verified by the planner before implementation. If blocking is not supported, R13 needs an alternative mechanism (e.g., warning + soft-fail).

- **Git branch is available at hook execution time.** The hook needs to call `git rev-parse --abbrev-ref HEAD` (or equivalent) to determine the active mode. Assumed git is always available in directories where Claude Code is used. Fallback: if no git context, mode is treated as inactive (no injection, no gating).

- **The hook environment supports reading files in `<repo>/.claude/` and `~/.claude/`.** Verified — existing hooks already do this.

- **YAML parsing is available in the hook runtime.** The hook may be shell-based (using `yq` or a small Node/Python helper). Implementation detail for the planner.

- **Compiling YAML mode definitions to prose at injection time is fast enough to not noticeably delay user prompts.** Assumption — should be measured. If compilation is slow, V1 can pre-compile bindings at write-time (when authored via the editor) and cache the prose alongside the YAML.

- **Runtime inference latency is acceptable.** Model produces inferred heuristics on top of regular command processing, adding tokens (mode definition prepended) and possibly attention overhead. Assumed acceptable for V1; promotion workflow exists in part to reduce inference frequency over time.

- **Durability (under near-term shifts):** This plugin's value proposition assumes Claude Code's hook architecture remains stable and that third-party plugins continue to expose work via slash commands. If the hook API changes substantially or commands move to a different invocation mechanism, V1 would need revision but the core abstraction (modes as named, durable, mutually-exclusive working stances) survives the shift.

- **Multi-machine sync is out of scope.** If the user later wants modes synced across machines, they can commit `~/.claude/modes/` to a personal dotfiles repo manually. The plugin does not provide sync.

---

## Outstanding Questions

### Resolve Before Planning

*(None — all blocking product decisions are resolved.)*

### Deferred to Planning

- **[Affects R13] [Technical]** Exact mechanism for PreToolUse hook to block tool calls. Verify the harness supports structured block responses with user-visible error messages, or determine the closest alternative (e.g., raising an exception, returning a modified tool call).
- **[Affects R6, R11] [Needs research]** YAML-to-prose compilation strategy. Options: compile at hook time (slower, simpler), pre-compile at registry-write time (faster, caching complexity), template-based with mode definition substitution (middle ground). Pick during planning based on measured hook latency.
- **[Affects R8, R20] [Technical]** Registry storage format. Options: JSON, SQLite, in-memory regenerated on every editor invocation. Decide based on registry size and access patterns during planning.
- **[Affects R15, R16] [Technical]** Whether the registry editor is a slash command (`/mode:registry`) that opens a stateful conversation, or a one-shot command that takes args (`/mode:registry edit <mode> <command>`). The interactive-conversation model aligns with the brainstorm's framing; the one-shot model is simpler to implement. Probably both, with `/mode:registry` defaulting to interactive.
- **[Affects R18] [Technical]** Statusline integration mechanism. Depends on whether Claude Code's statusline supports plugin-contributed segments or if visibility is achieved via session-start announcement + `/mode:status` only.
- **[Affects R7] [Technical]** Exact regex/parser for slash command extraction from user prompts. Edge cases: leading whitespace, commands with arguments, multi-line prompts that begin with a slash command. Sketch during planning.
- **[Affects R3] [Needs research]** First-run experience. When a user installs the plugin and invokes any `/mode:*` command for the first time, do we walk them through authoring their first mode, or surface a docs pointer? Probably the former, but the exact onboarding flow is a planning-time design decision.

---

## Next Steps

`-> /ce-plan` for structured implementation planning.
