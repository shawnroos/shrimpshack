---
title: "feat: Modes-as-Infrastructure for Claude Code"
type: feat
status: active
date: 2026-05-15
deepened: 2026-05-16
origin: docs/brainstorms/2026-05-15-modes-as-infrastructure-requirements.md
---

# feat: Modes-as-Infrastructure for Claude Code

## Overview

This plan implements V1 of `claude-modes`, a Claude Code plugin that introduces **modes** — named, durable, mutually-exclusive definitions of *a way of working* (philosophy, scope, lens, constraints) that recompose Claude's delegation surface and influence command behavior when active. The plugin lives at `~/projects/claude-modes/` (greenfield repo, no remote yet).

**Two layers of influence — be honest about which is deterministic:**

- **Delegation gating (deterministic):** modes can mount/unmount specific agents and skills; the PreToolUse hook hard-blocks `Task`/`Skill` calls to unmounted entities with no possibility of accidental dispatch. This is the load-bearing mechanism for `feedback_deterministic_over_probabilistic_v1`.
- **Command-behavior shaping (probabilistic):** modes inject heuristic prose into `<system-reminder>` via UserPromptSubmit when a bound slash command runs; Claude attends to this context but the effect is probabilistic by mechanism. Commands are never hidden, never blocked, never rewritten (R23) — this preserves muscle memory and aligns with the design choice to develop heuristics rather than gate the command surface.

The plan does NOT claim command-behavior shaping is deterministic. Don't expect a mode to *prevent* a command from doing something via the heuristic-injection path — only to bias Claude toward doing it differently. If a future use case requires deterministic command-side enforcement (e.g., "delivery mode must refuse to land a PR with TODOs"), that's V2 work (per-mode command wrappers or hook-side hard refusal) and would need to be justified against the "commands are never hidden" invariant.

Two mechanisms drive mode behavior:

1. **Heuristic injection** (probabilistic, dispositional) — a UserPromptSubmit hook reads the active mode for the current branch, matches the user's slash command, and injects a heuristic block (either compiled-from-authored-binding or full-mode-definition-for-inference) as a system-reminder before the prompt reaches Claude.
2. **Delegation gating** (deterministic, mechanical) — a PreToolUse hook on `Task` and `Skill` tool calls reads the active mode's unmounted-subagent list and hard-blocks calls to gated subagents/skills. **Two-part guarantee:**
   - **Gating is deterministic** (the tool does not execute; harness honors the canonical block JSON; audit log records every block event).
   - **User-visible messaging is two-channel:** in-session via Claude relaying the `systemMessage` field (best-effort — model may not always relay), AND out-of-band via the append-only `~/.claude/modes/.audit.log` (always observable; `tail -f` works). The audit-log channel is what makes the deterministic guarantee discoverable when in-session relay misses, honoring `feedback_deterministic_over_probabilistic_v1` at the visibility layer.

The plugin ships with **two labeled example modes** (`example-discovery`, `example-delivery`) seeded at install time — the user adapts them, deletes them, or uses them as a study reference for authoring their own. Non-example modes are still authored via the interactive registry editor. Mode definitions live in `~/.claude/modes/<name>.yaml`; per-branch active-mode pointer lives at `<repo>/.claude/modes/<branch-slug>.mode`. (REVISED post-doc-review — original plan was zero pre-defined modes; see Alternative Approaches Considered for the reversal rationale.)

The plugin is **parasitic** — it never modifies third-party plugins (CE, slate-plugins, document-skills). All mode behavior is achieved through harness hooks and the plugin's own slash commands.

---

## Problem Frame

Claude Code users develop tacit "modes of working" — exploring an unknown codebase needs a different review bar than shipping a delivery PR; debugging needs different agent availability than designing. Today this is muscle memory: users either type long context preambles every invocation, route around tools that behave wrong-for-the-moment, or accept that some commands fight them in some situations. The tacit knowledge cannot be authored, shared, or evolved.

The originating example was a two-mode split — **discovery** (sprawl-by-design exploration, light review bar) and **delivery** (shipping phase, strict bar, decomposed plans) — but the abstraction generalizes along two axes:

- **Workflow-stage modes** (like discovery/delivery): named stages of a project where the same commands should behave differently.
- **Modality modes** (e.g., design-mode, pm-mode, writing-mode): named *kinds of work* where Claude's whole agent/skill stack recomposes — a design-mode session reaches for product-designer tools and review lenses; pm-mode mobilizes data, strategy, and stakeholder framings; writing-mode acts as a writing sparring partner. Modes-as-infrastructure makes these modalities first-class without the bloat of building each as a separate sub-system inside Claude Code.

The cross-command coherence is what makes this an *infrastructure* concern rather than a 3-slash-command concern: when the user moves from `/ce-work` to `/ce-code-review` in delivery mode, both commands read the same mode state and recompose accordingly — `/ce-work` dispatches the delivery-mode agent set; `/ce-code-review` enforces the delivery-mode review bar. Single-purpose slash commands can't deliver this; modes-as-infrastructure can.

**The harness-bloat problem modes solve at scale.** Claude Code's harness has a single flat descriptor surface: every installed plugin's agents, skills, and commands compete for the same context budget in the model's system prompt at all times, regardless of what kind of work is happening. Today this is observable as `/doctor` flagging agent-descriptor truncation when too many plugins are installed (e.g., a 185-agent ai-ml-toolkit plugin alone pushes past the threshold). The underlying problem is structural, not capacity: a user who installs opinionated systems for different kinds of work — compound-engineering for pipelined feature work, ai-ml-toolkit for ML engineering, future systems for product strategy, writing, design — has no way to *contextualize* which surface is active when. Each opinionated system bleeds into every session, competing for the model's attention with every other one.

Modes-as-infrastructure makes the harness *modal*: when a mode is active, only the agents/skills/commands relevant to that mode are mounted (or, equivalently, irrelevant ones are unmounted). The harness narrows from "everything I've installed competing all the time" to "the agents/skills/commands appropriate for the work I'm doing right now." This lets the user install and develop multiple opinionated systems (CE-style pipelines, dual-track agile workflows, design-system flows) without each erasing the others. The descriptor-budget problem `/doctor` flags becomes a mode-design problem, not a scale problem.

See origin: `docs/brainstorms/2026-05-15-modes-as-infrastructure-requirements.md`.

The "shape commands" promise has a precise meaning in V1: heuristic injection biases Claude toward mode-appropriate behavior; it does not enforce it. Where mechanical enforcement is needed, it lives at the delegation layer (PreToolUse gating + audit log). This asymmetry is intentional and aligns with the design principle that commands are the user's interface and should not be hidden or overridden behind the user's back.

The hard constraint shaping V1: Shawn won't adopt tooling whose behavior is only probabilistic (memory: `feedback_deterministic_over_probabilistic_v1`). V1 must ship deterministic mechanical enforcement on at least one load-bearing mechanism — that's why delegation gating is in V1 and not deferred.

---

## Requirements Trace

- R1. Mode definitions are prose-primary durable artifacts (philosophy, scope, lens, constraints); structured bindings are appendix. *(satisfied by U2)*
- R2. Mode YAML at `~/.claude/modes/<name>.yaml` with optional repo-local override at `<repo>/.claude/modes/<name>.yaml`. *(U2, U6)*
- R3. Plugin ships with **two labeled example modes** (`example-discovery`, `example-delivery`) that user adapts or deletes; first-mode authoring is still interactive and is the mechanism for creating *non-example* modes. The example modes are clearly labeled in name and in their `description` field as "example to adapt or delete — not intended for production use as-is". *(U10, plus install step in U1)* (REVISED post-doc-review from the original "zero pre-defined modes" — see Alternative Approaches Considered for the re-justification.)
- R4. Per-branch mode state at `<repo>/.claude/modes/<branch-slug>.mode`. *(U3)*
- R5. Mutually exclusive modes (one active per branch). *(U3)*
- R6. UserPromptSubmit hook reads active mode, matches prompt against bindings. *(U4)*
- R7. Exact slash command match only (bare and plugin-namespaced forms). *(U4)*
- R8. Registry of (command, mode) bindings, derivable from YAML + command-surface scan. *(U8)*
- R9. Binding provenance (authored / inferred / uncovered). *(U8, U9)*
- R10. Authored bindings compile to prose and inject as system-reminder. *(U4, U5)*
- R11. No authored binding → inject full mode definition as inference context. *(U4)*
- R12. Mode switching requires explicit confirmation. *(U3)*
- R13. PreToolUse hook on `Task` (subagent dispatch) blocks calls to unmounted subagents using the canonical block-decision JSON; the block reason reaches Claude, which relays it to the user. *(U7)*
- R14. Delegation gates also apply to skills. *(U7)*
- R15. Registry editor is the primary authoring surface. *(U9, U10)*
- R16. Promotion workflow turns inferred bindings into authored. *(U9)*
- R17. Slash commands: `/mode:set`, `/mode:status`, `/mode:clear`, `/mode:registry`, `/mode:registry coverage`, `/mode:registry promote`. *(U3, U9)*
- R18. Mode visibility: first-injection announcement, `/mode:status` command, statusline if supported. *(U4, U3)*
- R19. No modifications to third-party plugins. *(architectural invariant — enforced by mechanism choice in U1, U4, U7)*
- R20. Registry is derivable, not primary source of truth; rebuildable via `/mode:registry --rebuild`. *(U8)*
- R21. Coverage view (`/mode:registry coverage`) lists uncovered frequently-used commands. *(U9)*
- R22. New plugins installed after a mode is authored surface as uncovered; existing modes continue working. *(U8)*
- R23. Commands are never hidden or blocked by modes; only agents/skills are gated. *(architectural invariant — U7 only operates on `Task` and `Skill` tool calls, never on slash commands)*

- R25. Mode YAML carries `schema_version` field to enable migrations. *(U2)*
- R26. Mode names are validated (filesystem-safe slug; no collision with reserved tokens `default`, `none`, `set`, `status`, `clear`, `registry`). Validation library is shared between `/mode:set` (U3 — guards direct user input bypassing the authoring flow) and `mode-author` (U10 — guards conversational input). *(U3, U10)*

*(R24 was removed in post-doc-review revision. See "Deferred for later → PreToolUse contract self-test infrastructure (U13/U14)" — the V1 mitigation for the "Low likelihood" hook contract change risk is now documentation-only.)*

**Origin actors:** A1 (Mode author), A2 (Mode user), A3 (Third-party plugin — invariant: not modified), A4 (Claude the model), A5 (Hook runtime).

**Origin flows:** F1 (Author first mode), F2 (Set mode for current work), F3 (Invoke command in active mode — authored binding), F4 (Invoke command in active mode — runtime inference), F5 (Delegation gating — subagent call blocked), F6 (Promote inferred binding to authored).

**Origin acceptance examples:** AE1–AE8 (covers R3/R15, R6/R10, R6/R11, R7/R23, R13/R19, R12, R16, R22 — see test scenarios in implementation units).

---

## Scope Boundaries

### Deferred for later

*(Carried from origin — product/version sequencing.)*

- **Mode-flavored command grammar** (e.g., `/ce-plan:discovery` as structurally different from `/ce-plan:delivery`). V1 keeps all commands callable in all modes; behavior differs only via heuristic injection. Grammar-level branching is V2.
- **Compositional modes** (stacking multiple modes). V1 is mutually exclusive; future escape valve is *mode inheritance* (a `discovery-oncall` mode defined as discovery + small overlay) rather than runtime composition.
- **Branch-creation inheritance** (does a new branch inherit parent's mode?). V1 defaults to no inheritance.
- **Branch rename/delete migrations**. V1 documents sharp edge but doesn't automate cleanup.
- **Convention-driven mode inference** (branch-name patterns auto-suggest mode). V1 requires explicit `/mode:set`.
- **Usage-frequency telemetry** for coverage weighting. V1 lists uncovered commands without weighting.
- **Shared mode definitions** (team-level, committed to repos). V1's mode files are personal config.
- **`/mode:override-once`** per-invocation delegation gate override. V1 ships the gate without escape valve.
- **Targeted-review scope mechanics** for delivery-mode `/ce-code-review`. V1 default: prose-only guidance, no mechanical scoping.
- **`/mode:delete <name>` command.** V1 recovery for "I want to remove this mode" is manual: `rm ~/.claude/modes/<name>.yaml` + `/mode:registry --rebuild`. Add the command if friction emerges in real use. Documented explicitly in the README.
- **PreToolUse contract self-test infrastructure (U13/U14).** V1 ships with documentation-only mitigation for the "Low likelihood" hook contract change risk (canonical contract documented in `architecture.md`; SessionStart log line names the contract version; README has a "verify-on-harness-update" note). V2 candidate if observed adoption shows the deterministic-V1 promise needs runtime observability beyond documentation. The originally-proposed self-test (synthetic `Task` against canary subagent + degraded-mode signaling via `.degraded`) was deferred because (a) the self-test mechanism remained an Open Question, (b) self-attestation by the system being attested cannot detect hook-not-loaded states, and (c) U13/U14's footprint (~150 lines + new state surface) was disproportionate to a Low-likelihood risk per scope discipline.

### Outside this product's identity

*(Carried from origin — positioning rejection.)*

- **Not a workflow enforcement engine.** Modes shape disposition and gate delegation; they do not enforce branch state, block merges, validate PR shape, or run external compliance checks.
- **Not a Claude Code plugin manager.** Modes mount/unmount at the delegation layer; they don't install or version third-party plugins.
- **Not a personalization or memory system.** Modes are about the work, not the user.
- **Not a replacement for skills.** Modes shape how skills behave; they don't substitute for authoring skills.
- **Not a state machine for project lifecycle.** Discovery → delivery is one example; modes may be intermittent and orderless (e.g., `oncall`, `polish`).
- **Not multi-user or multi-tenant.** Single-user, single-machine, no syncing.

### Deferred to Follow-Up Work

*(Plan-local — implementation work intentionally split across follow-up PRs.)*

- **Statusline integration** (R18): the first-injection announcement and `/mode:status` ship in V1; statusline indicator requires harness-specific integration work and ships as a follow-up once V1 is in real use.
- **Plugin marketplace publishing**: the plugin is initialized as a standalone local repo. Publishing flow (remote, marketplace registration, install instructions) is a separate concern after V1 stabilizes.
- **Cross-machine sync hooks**: if Shawn later wants modes synced across machines via dotfiles, that's an opt-in workflow, not a V1 feature.

---

## Context & Research

### Relevant Code and Patterns

- **`~/projects/crex/`** — closest precedent for this plugin. Mirrors: `.claude-plugin/plugin.json` with explicit `skills`/`commands`/`hooks` keys; `.claude/{hooks,commands,skills}/` layout; shell scripts in top-level `scripts/`; opt-in hook settings file at `~/.config/<plugin>/settings.json`; slash command files at `.claude/commands/<namespace>/<verb>.md` producing `/crex:save` etc. README template covers Prerequisites → Install → Configure → Skills table → Slash commands table → File layout → Development.
- **`~/projects/Slate/plugins/slate-devs/`** — canonical "no `$`-bearing inline bash" structure. All `$`-bearing shell logic lives in `lib/*.sh`; command `.md` files only invoke scripts. Critical pattern for this plugin given `feedback_slash_command_arg_substitution`.
- **`~/.cc-cmux/handler.cjs:1184-1188`** — earlier PreToolUse blocking pattern. Matches on `tool_name == "Agent"` and writes `{"decision":"block","reason":"..."}` to stdout. **Caveat (verified during deepening):** this branch is unexercised in the current runtime config (`~/.cc-cmux/config.json` has `visibleAgentPanes: false`), and the tool name `Agent` predates the current `Task` naming. Cite as architectural evidence that PreToolUse blocking *exists*, not as the canonical contract.
- **`~/.claude/plugins/cache/claude-plugins-official/plugin-dev/.../skills/hook-development/SKILL.md`** — authoritative reference for hook event semantics, env vars, and stdin/stdout protocols. **This is the canonical source** for the PreToolUse contract used by U7: `{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":"..."}}` written to stderr with exit code 2. Worked examples at `examples/validate-bash.sh` and `examples/validate-write.sh`.
- **`~/.claude/plugins/cache/claude-code-templates/ai-ml-toolkit/1.0.0/cli-tool/docs_to_claude/HOOKS_GUIDE.md`** — secondary reference; lines 115–130 enumerate `Task` as the canonical subagent-dispatch matcher; lines 238–248 document exit-code semantics; lines 263–272 document PreToolUse permission output. Confirms the matcher and output shape used in U7.
- **`~/projects/Slate/plugins/slate-calls/tests/`** — the closest test-suite precedent. Uses bats + plain-sh runner orchestrator + per-test `$HOME` isolation via `mktemp -d`. Plan U11 reorients on this precedent (the earlier slate-roadmap reference was misattributed).

### Institutional Learnings

- **`feedback_slash_command_arg_substitution`** — slash-command `.md` bodies substitute `$0/$1/$2/$ARGUMENTS` before bash runs; `$`-bearing shell snippets get mangled. Rule: all `$`-bearing logic lives in `lib/*.sh`; command markdown only invokes scripts. **Shapes U3, U9 directly.**
- **`feedback_deterministic_over_probabilistic_v1`** — Shawn won't adopt V1 if behavior is only probabilistic. Delegation gating (U7) must hard-block with visible error; heuristic injection (U4, U5) is dispositional but structured (named heuristics, not freeform). **Shapes risk register and U7's verification bar.**
- **`feedback_subagent_write_verification`** — verify subagent file writes on disk before trusting "done". Applies during execution when CE pipeline runs.
- **`feedback_edit_block_replacement_boundaries`** — block-level Edit replacements need anchor context on both sides; smoke-test after non-trivial edits.

### External References

External research was skipped in Phase 1.2 per the standard rationale: this plugin's "framework" is Claude Code itself; there is no external best-practices literature for modes-as-infrastructure because the abstraction is novel. Local empirical grounding (hooks, manifest conventions, prior plugins) is the relevant context.

---

## Key Technical Decisions

- **Plugin layout mirrors crex.** Manifest at `.claude-plugin/plugin.json` with explicit `skills`/`commands`/`hooks` keys; `.claude/` directory wraps these; top-level `lib/` and `scripts/`. *Rationale:* crex is the closest precedent in Shawn's existing plugins, and its layout has been battle-tested against the same harness this plugin targets.

- **Hook entry points are shell scripts under `scripts/`; all `$`-bearing logic lives in `lib/*.sh`.** Each hook event has a thin shim script (`scripts/on-prompt-submit.sh`, `scripts/on-pre-tool-use.sh`, `scripts/on-session-start.sh`) that reads stdin and dispatches to `lib/` functions. *Rationale:* `feedback_slash_command_arg_substitution` rules out inline `$`-bearing bash in command markdown; the lib/scripts split is the documented safe pattern. Rejected alternative: single Node.js dispatcher (cc-cmux pattern). It's architecturally cleaner but adds a Node dependency, and shell is sufficient for V1's scope.

- **YAML-to-prose compilation at hook time, no cache.** The UserPromptSubmit handler reads YAML, looks up the matched command's binding, and compiles to prose inline. *Rationale:* per agent research, write-time caching introduces stale-cache failure modes ("Claude behaves slightly wrong" — worst kind of bug because it erodes trust silently); hook-time compile is ~5-20ms per invocation, acceptable given UserPromptSubmit already runs on every prompt. Revisit only if a real latency floor (>100ms felt) emerges.

- **Registry storage: JSON file at `~/.claude/modes/registry.json`.** Atomic-rename writes; `/mode:registry --rebuild` for corruption recovery. *Rationale:* per agent spot-check, the user's installed command surface is ~1k commands + ~785 skills + ~272 agents. Even at 5 modes × 1k commands = 5k binding rows, JSON is trivial. SQLite is overkill at this scale and adds a binary dependency. R20 explicitly says the registry is derivable — JSON file matches that semantics.

- **Slash command namespacing via directory structure.** `commands/mode/set.md` → `/mode:set`, etc. *Rationale:* this is how Claude Code resolves namespaced commands (confirmed by inspection of crex `commands/crex/save.md` → `/crex:save`). No manifest-level namespace declaration needed.

- **State location: `~/.claude/modes/` (not XDG-style `~/.config/claude-modes/`).** *Rationale:* the plugin's job is to integrate tightly with Claude Code, not be a generic XDG citizen. Co-locating mode state with other `.claude/` config matches the harness's mental model. Crex chose `~/.config/crex/` because crex preceded this convention; new plugins should prefer `~/.claude/`.

- **Heuristic injection is structured-prose, not freeform context.** Authored bindings store named fields (focus / bar / behavior / scope) that compile to a consistent prose shape. Inferred bindings inject the *full mode definition* (philosophy, scope, lens, constraints) so the model has rich context to derive from. *Rationale:* "soften the review bar" is too vague to be reliable; named heuristics give Claude a contract to execute repeatably, even though the mechanism remains probabilistic.

- **PreToolUse hook scope: `Task` (subagent dispatch) and `Skill` tools, matcher `Task|Skill`.** *Rationale:* commands are never gated (R23); other tools (Bash, Read, Edit) shouldn't be gated either because that fights muscle memory. Gating is targeted at *delegation surfaces* — the things Claude reaches for on the user's behalf. The earlier-named `Agent` matcher is a stale identifier from previous harness versions; current Claude Code routes subagent calls through the `Task` tool with `tool_input.subagent_type`. Hook script may defensively match `Task|Agent` and warn-log on `Agent` to detect future regressions.

- **PreToolUse block contract: canonical `hookSpecificOutput` + `systemMessage` shape on stderr + exit 2.** Emit `{"hookSpecificOutput":{"permissionDecision":"deny"},"systemMessage":"<message>"}` to stderr; exit code 2. The block reason lives in `systemMessage` as a **sibling** of `hookSpecificOutput`, NOT as a child field — verified against `hook-development/SKILL.md` lines 144–153 and the working `validate-bash.sh`/`validate-write.sh` examples. *Rationale:* this is the contract documented in `hook-development/SKILL.md` and exercised by official examples — the earlier-cited cc-cmux `{"decision":"block","reason":"..."}` stdout pattern is a different (Stop-hook-shaped) contract that bled into the original plan; an earlier draft of this plan invented a `permissionDecisionReason` child field that does not exist in any documented harness consumer. Using the canonical contract ensures the deterministic-gating guarantee holds across harness updates that may tighten conformance.

- **Block-reason visibility is probabilistic by default; deterministic gating is on the tool execution only.** The PreToolUse block prevents the tool from running (deterministic). The block reason reaches Claude via stderr; Claude is expected to relay it to the user but may or may not (probabilistic). This is in tension with `feedback_deterministic_over_probabilistic_v1` and is tracked as Open Question and as a Risk row. V1 ships with Claude-relayed messaging; an out-of-band channel (cmux notification, audit log file, `systemMessage` field if it surfaces from PreToolUse) is V2 candidate.

- **Single repo, single plugin, no marketplace yet.** Initialize as `~/projects/claude-modes/` standalone; no remote, no marketplace registration in V1. *Rationale:* let V1 stabilize through real personal use before considering publishing.

---

## Open Questions

### Resolved During Planning

- **PreToolUse hook can block tool calls?** Yes — canonical pattern is `{"hookSpecificOutput":{"permissionDecision":"deny"},"systemMessage":"<reason>"}` to stderr with exit code 2, per `hook-development/SKILL.md` lines 144–153 and the working `validate-bash.sh`/`validate-write.sh` examples. Note: the reason text lives in `systemMessage` as a sibling of `hookSpecificOutput`, NOT as a child field — an earlier plan draft invented `permissionDecisionReason` which no documented harness consumer reads. R13 is achievable using the canonical contract.
- **What tool name does Claude Code use for subagent dispatch?** `Task` (not `Agent`). `tool_input.subagent_type` is the subagent identifier. Confirmed by HOOKS_GUIDE.md and the user's own installed plugins (slate-product-assistant).
- **Does the block reason reach the user?** The block reason reaches Claude (via stderr); the user sees it only if Claude relays it. V1 trusts Claude to relay; an out-of-band visibility channel is a V2 Open Question.
- **YAML-to-prose strategy?** Hook-time compile, no cache. Write-time caching introduces silent-staleness failure modes incompatible with `feedback_deterministic_over_probabilistic_v1`.
- **Registry storage?** JSON file with atomic-rename writes; `/mode:registry --rebuild` for recovery.
- **Slash command namespacing mechanism?** Directory-based (`commands/<namespace>/<verb>.md`); no manifest declaration.
- **Where do user-authored modes live?** `~/.claude/modes/<name>.yaml` (global) + `<repo>/.claude/modes/<name>.yaml` (optional repo-local override). Crex precedent confirms cross-dir reads are unrestricted.

### Deferred to Implementation

- **Exact regex for slash command extraction** from user prompts. Edge cases: leading whitespace, multi-line prompts, arguments after command. Sketch during U4.
- **Exact YAML field set in authored bindings.** V1 starts with `focus / bar / behavior / scope` as common fields; the schema will evolve from first real authoring session in U10.
- **First-run flow specifics.** When the user invokes any `/mode:*` command and no modes exist, do we offer to author the first one inline, or surface a doc pointer? Designed in U10; the requirements doc strongly implies inline.
- **Statusline integration** [Needs research]. Whether Claude Code's statusline supports plugin-contributed segments. If yes, add a minimal segment in V1. If no, defer to follow-up.
- **Mode-file checksum / freshness signal in registry.** Whether the registry tracks YAML file mtime so coverage rebuilds detect external edits. Probably yes, but mechanism is a U8 detail.
- **Test runner choice.** Bash-test framework (`bats`) vs. plain `.sh` scripts with assertion helpers. The closest precedent is `~/projects/Slate/plugins/slate-calls/tests/` (hybrid: plain-sh `run-tests.sh` orchestrator + bats for actual tests + per-test `$HOME` isolation). Recommendation: adopt the slate-calls hybrid. Decide during U11 (see U11 Open Question below).
- **[Affects U10] Mode name validation rules.** Filesystem-safe character set, length cap, reserved tokens (`default`, `none`, `set`, `status`, `clear`, `registry`). Specified to satisfy R26.
- **[Affects U10] Atomicity of author + set.** Should the final step of authoring offer "Set `<name>` as the active mode on your current branch now? [Y/n]" (default Y)? Recommend yes; confirm during U10.
- **[Affects U10] Minimum content schema.** Does a mode YAML require non-empty `philosophy`/`scope`/`lens`, or is a near-empty mode valid?
- *(Resolved during doc-review: Inspirational example display. V1 ships actual example modes (`example-discovery`, `example-delivery`) at install — they ARE the inspirational reference. mode-author's intent-capture step references them by name when the user struggles to articulate, suggesting `~/.claude/modes/example-discovery.yaml` as a study target. No separate display branch needed.)*

**Surfaced during doc-review for future revisit (not blocking V1):**
- **Schema migration mechanism.** `schema_version: 1` ships in V1, but no migration script + no `lib/migrations/` directory yet. When V2 needs to evolve the schema, the migration story has to be designed alongside the change. Adversarial-reviewer F4 flagged this as "shipping a hook with no mechanism." V1-acceptable but worth knowing.
- **V1 path-dependency vs. V2 trajectory.** Several deferred V2 features (mode inheritance, shared mode definitions, branch-creation inheritance) inherit constraints from V1 choices (mutually exclusive, personal config, per-branch state). When you reach for one, the V1 commitments may need re-examination. Product-lens F5.
- **Hook compounding tax across plugin stack.** UserPromptSubmit + PreToolUse fire on every prompt across every repo. Compounded with cmux, crex, claude-modes, and future plugins, the per-prompt latency tax is a system-level concern, not a per-plugin one. Product-lens F6. No fix at this plan's level; worth tracking when the stack grows.
- **Structured-vs-freeform heuristic prose.** The plan asserts structured prose is more reliable than freeform without evidence. Adversarial-reviewer F5 suggests a falsification test after first real mode authoring. Cheap experiment, deferred.
- **Performance budget validation.** &lt;50ms p95 per hook fire is the U11 baseline target but is empirically untested. Adversarial residual risk + Feasibility F5. Self-correcting via U11's `tests/perf-baseline.txt`.
- **[Affects U10] Draft persistence on abort.** Is mid-authoring abort lossy (simpler) or saved to a draft (more forgiving)?
- **[Affects U10, U3] SessionStart announcement on fresh install.** Confirm zero-mode SessionStart is silent (cost-of-being-installed) until the user invokes a `/mode:*` command.
- *(Resolved during doc-review: Block-reason out-of-band visibility. V1 ships `~/.claude/modes/.audit.log` as the always-on out-of-band channel — `tail -f` works, every block event recorded with timestamp/mode/tool/entity/reason. In-session relay via `systemMessage` is best-effort bonus. Honors the deterministic-V1 adoption bar at the visibility layer.)*
- **[Affects U6, R2] Repo-local mode trust boundary.** Cloned repos can ship `.claude/modes/<name>.yaml` that injects into the user's `<system-reminder>` context via heuristic injection. V1 ships with documentation only. V2 candidates: per-repo opt-in allowlist; prose-field sanitization. See new Risks row "Repo-local mode YAML is a trust boundary crossing".
- **[Affects U7] Fully-qualified vs bare subagent names.** Should the unmount list match both `compound-engineering:ce-adversarial-reviewer` and bare `ce-adversarial-reviewer`? Recommend yes — strip any `<plugin>:` prefix before lookup.
- *(Removed in post-doc-review revision: PreToolUse contract self-test mechanism question — U13/U14 deferred to V2 per Scope Boundaries → Deferred for later. V1 mitigation is documentation-only.)*

---

## Output Structure

```
~/projects/claude-modes/
├── .claude-plugin/
│   └── plugin.json                       # name, version, description, paths
├── .claude/
│   ├── hooks/
│   │   └── hooks.json                    # UserPromptSubmit, PreToolUse, SessionStart bindings
│   ├── commands/
│   │   └── mode/
│   │       ├── set.md                    # /mode:set <name>
│   │       ├── status.md                 # /mode:status
│   │       ├── clear.md                  # /mode:clear
│   │       └── registry.md               # /mode:registry [coverage|promote|--rebuild]
│   └── skills/
│       └── mode-author/
│           └── SKILL.md                  # interactive authoring conversation
├── lib/
│   ├── active-mode.sh                    # read current branch + .mode file
│   ├── mode-yaml.sh                      # parse mode YAML; resolve global vs. repo-local override
│   ├── compile-heuristic.sh              # YAML binding → prose system-reminder
│   ├── inject-heuristic.sh               # UserPromptSubmit handler logic
│   ├── gate-delegation.sh                # PreToolUse handler logic
│   ├── registry-scan.sh                  # scan plugin cache, enumerate commands/agents/skills
│   ├── registry-read.sh                  # registry.json read helpers
│   ├── registry-write.sh                 # atomic-rename writes (mktemp in target dir); rebuild
│   ├── set-mode.sh                       # /mode:set logic (branch detect, confirm, write)
│   └── validate-mode-name.sh             # mode + branch name validation (slug, reserved tokens)
├── scripts/
│   ├── on-prompt-submit.sh               # hook shim: read stdin, dispatch to lib/inject-heuristic.sh
│   ├── on-pre-tool-use.sh                # hook shim: read stdin, dispatch to lib/gate-delegation.sh
│   ├── on-session-start.sh               # hook shim: surface active mode at session start
│   └── install-examples.sh               # idempotent install of example modes (run from README)
├── examples/
│   ├── example-discovery.yaml            # labeled example: sprawl-by-design exploration mode
│   └── example-delivery.yaml             # labeled example: shipping-phase strict-bar mode
├── tests/
│   ├── run.sh                            # orchestrator: [unit|integration|smoke|perf|all]
│   ├── SMOKE_CHECKLIST.md                # manual smoke test artifact (PR-checkable)
│   ├── perf-baseline.txt                 # recorded median ms for no-mode hook path
│   ├── helpers/
│   │   └── test-helpers.sh               # shared scaffolding incl. $HOME isolation contract
│   ├── fixtures/
│   │   ├── mode-yamls/                   # sample mode definitions
│   │   ├── plugin-cache-tree/            # fixture for registry scan tests
│   │   └── fake-ce-plugin/               # CE-shaped fixture for R19 hash-check test
│   ├── unit/                             # per-lib unit tests
│   └── integration/                      # cross-layer scenarios per U11
├── docs/
│   ├── brainstorms/
│   │   └── 2026-05-15-modes-as-infrastructure-requirements.md  # already exists
│   └── plans/
│       └── 2026-05-15-001-feat-modes-as-infrastructure-plan.md  # this file
└── README.md                             # Prerequisites, Install, Configure, Commands, File layout
```

*The implementer may adjust this structure if implementation reveals a better layout; per-unit `**Files:**` sections remain authoritative.*

---

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

**Sequence diagram — Heuristic injection (F3 + F4):**

```
User       UserPromptSubmit-hook    lib/active-mode.sh    lib/mode-yaml.sh    Claude (model)
 │                │                       │                     │                    │
 │ /ce-code-review│                       │                     │                    │
 │───────────────▶│                       │                     │                    │
 │                │ read branch & .mode   │                     │                    │
 │                │──────────────────────▶│                     │                    │
 │                │   "delivery"          │                     │                    │
 │                │◀──────────────────────│                     │                    │
 │                │ resolve mode YAML     │                     │                    │
 │                │────────────────────────────────────────────▶│                    │
 │                │   { /ce-code-review: { focus, bar, ... } }  │                    │
 │                │◀────────────────────────────────────────────│                    │
 │                │ compile to prose                            │                    │
 │                │ if binding exists: authored prose            │                    │
 │                │ else: full mode definition (inference ctx)  │                    │
 │                │ prepend as <system-reminder>                                     │
 │                │──────────────────────────────────────────────────────────────────▶│
 │                │                                                          execute │
 │                                                              shaped output ◀──────│
 │ shaped output  │◀──────────────────────────────────────────────────────────────────│
 │◀───────────────│                                                                  │
```

**Sequence diagram — Delegation gating (F5):**

```
Claude (model)        PreToolUse-hook        lib/gate-delegation.sh        Hook runtime
     │                      │                          │                         │
     │ Task(subagent_type=ce-adversarial-reviewer)     │                         │
     │─────────────────────▶│                          │                         │
     │                      │ read active mode YAML    │                         │
     │                      │─────────────────────────▶│                         │
     │                      │ check unmount list       │                         │
     │                      │◀─────────────────────────│                         │
     │                      │ stderr: {"hookSpecificOutput":                      │
     │                      │   {"permissionDecision":"deny"},                    │
     │                      │  "systemMessage":                                   │
     │                      │   "ce-adversarial-reviewer unmounted                │
     │                      │    in mode discovery..."}                           │
     │                      │ exit 2                                              │
     │                      │─────────────────────────────────────────────────────▶│
     │                      │                                          block tool │
     │ tool result: blocked │◀────────────────────────────────────────────────────│
     │◀─────────────────────│                                                     │
     │ relay reason to user                                                       │
     │                                                                            │
```

**Decision matrix — UserPromptSubmit handler logic:**

| Active mode? | Prompt starts with slash command? | Authored binding? | Action |
|---|---|---|---|
| No | * | * | Pass-through (no injection) |
| Yes | No | * | Pass-through (R7: exact slash match only) |
| Yes | Yes | Yes | Inject compiled prose from authored binding |
| Yes | Yes | No | Inject full mode definition as inference context |

---

## Implementation Units

- U1. **Plugin scaffold and manifest**

**Goal:** Create the plugin's directory structure, manifest, and minimal `hooks.json` registration so subsequent units can be developed against a real plugin install.

**Requirements:** R19 (architectural invariant — plugin is parasitic, never modifies third-party plugins; established here by the structural choice of hooks-only integration).

**Dependencies:** None.

**Files:**
- Create: `.claude-plugin/plugin.json`
- Create: `.claude/hooks/hooks.json` (stub registrations for UserPromptSubmit, PreToolUse, SessionStart pointing at `scripts/on-*.sh`)
- Create: `examples/example-discovery.yaml` (labeled example mode shipped with the plugin; copied to `~/.claude/modes/` at install time by `scripts/install-examples.sh` IF that target doesn't already contain `example-discovery.yaml`)
- Create: `examples/example-delivery.yaml` (companion to above)
- Create: `scripts/install-examples.sh` (idempotent copy; does not overwrite existing files; runs from README install instructions, NOT auto-run, so users can opt out by skipping the step)
- Create: `README.md` (stub: Prerequisites, Install via symlink to `~/.claude/plugins/` + optional example-mode install, file layout)
- Create: `.gitignore` (ignore registry.json if it lands in the repo accidentally during dev)

**Approach:**
- Mirror crex's `plugin.json` shape exactly: explicit `skills`, `commands`, `hooks` keys pointing at `.claude/` subdirectories.
- `hooks.json` declares three hook entries using `${CLAUDE_PLUGIN_ROOT}` to reference scripts.
- README is intentionally minimal in V1 — fleshes out as the plugin matures.

**Patterns to follow:**
- `~/projects/crex/.claude-plugin/plugin.json` — manifest shape
- `~/projects/crex/.claude/hooks/hooks.json` — hook registration shape (wrapper `{"description":..., "hooks":{...}}`)
- `~/projects/crex/README.md` — README sections

**Test scenarios:**
- Test expectation: none — pure scaffolding, no behavior. Manual smoke test (install plugin, verify `/mode:*` commands appear in `/help`) covered by U3's verification.

**Verification:**
- Symlinking `~/projects/claude-modes` into `~/.claude/plugins/` makes the plugin loadable without errors at the next Claude Code session start.

---

- U2. **Mode YAML schema and parser**

**Goal:** Define the YAML structure for mode definitions (philosophy, scope, lens, constraints, command-heuristics, delegation) and implement a parser/resolver that reads global mode files with optional repo-local override.

**Requirements:** R1, R2, R25.

**Dependencies:** U1.

**Files:**
- Create: `lib/mode-yaml.sh` (parse mode YAML, resolve global vs. repo-local override)
- Create: `tests/unit/mode-yaml.test.sh`
- Create: `tests/helpers/test-helpers.sh` (shared test scaffolding — fixture creation, assertion helpers)

**Approach:**
- Use `python3 -c "import yaml; yaml.safe_load(...)"` as the **default** parser (ubiquitous on macOS; empirically verified present on target install via `/usr/bin/python3 -c "import yaml"`) with `yq` as an optional accelerator if available. **MUST use `yaml.safe_load()` (or `Loader=yaml.SafeLoader`), never bare `yaml.load()`** — bare `load()` executes arbitrary Python via YAML tags (e.g., `!!python/object/apply:os.system [rm -rf ~]`), which is a code-execution vector given that repo-local mode YAMLs (R2, U6) may come from cloned repos. Earlier draft framed `yq` as preferred; verification at deepening time showed `yq` is not in the user's PATH while `python3 + PyYAML 6.0.2` is.
- Schema for V1 (informal — refine in U10 from first authoring session):
  - **`schema_version: 1`** (required, top-level) — enables future V2 migrations without heuristic shape-detection. Parser reads and validates this field; unknown versions error visibly.
  - `name:`, `description:`, `philosophy:` (prose), `scope:` (prose), `lens:` (prose), `constraints:` (list of prose statements)
  - `command-heuristics:` map keyed by exact slash command, each value an object with `focus / bar / behavior / scope` string fields (V1 set; extensible)
  - `delegation:` with `agents.mount[] / agents.unmount[] / skills.mount[] / skills.unmount[]`
- Resolver precedence: if `<repo>/.claude/modes/<name>.yaml` exists, it fully replaces global; no field-level merge in V1 (kept simple — revisit if friction emerges).

**Patterns to follow:**
- `~/projects/Slate/plugins/slate-devs/lib/` — script extraction style (functions, not procedural top-level code)

**Test scenarios:**
- Happy path: parse a mode file with all standard sections (including `schema_version: 1`); verify each field is accessible via getter functions.
- Happy path: resolver returns global mode file when no repo-local override exists.
- Error path: mode YAML missing `schema_version` errors with a clear message naming the file (this is V1's first version, so absent = invalid; future versions migrate older shapes).
- Error path: mode YAML with `schema_version` greater than parser's known version errors with "this mode requires a newer plugin version" rather than silently misinterpreting.
- Edge case: resolver returns repo-local mode file when both exist; global is ignored.
- Edge case: missing `command-heuristics` section returns empty map without error (mode with no authored bindings is valid).
- Edge case: missing `delegation` section returns empty mount/unmount lists.
- Error path: malformed YAML returns a parse error with the offending file path in the message.
- Error path: YAML containing unsafe tags (e.g., `!!python/object/apply:os.system [echo BAD]`) is rejected by `safe_load`; assert `BAD` does NOT appear in shell output. Regression guard against switching back to bare `yaml.load()`.
- Error path: file does not exist returns a "mode not found" error, not a parse error.

**Verification:**
- All unit tests pass. The resolver correctly distinguishes "mode doesn't exist" from "mode YAML is malformed" — these are different conditions with different remediations.

---

- U3. **`/mode:set`, `/mode:status`, `/mode:clear` slash commands**

**Goal:** Ship the three interactive mode-management commands. `/mode:set <name>` writes the active mode for the current branch; `/mode:status` reports active mode + bindings summary; `/mode:clear` removes the branch's mode pointer.

**Requirements:** R4, R5, R12, R17, R18 (visibility via `/mode:status`), R26 (`/mode:set` validates mode name via shared `lib/validate-mode-name.sh` before any filesystem write).

**Dependencies:** U1, U2, and `lib/validate-mode-name.sh` from U10 (extracted to a shared library so U3 can call it without circular dependency on the full mode-author skill).

**Files:**
- Create: `.claude/commands/mode/set.md`
- Create: `.claude/commands/mode/status.md`
- Create: `.claude/commands/mode/clear.md`
- Create: `lib/active-mode.sh` (read branch via `git rev-parse --abbrev-ref HEAD`; read `<repo>/.claude/modes/<branch-slug>.mode`)
- Create: `lib/set-mode.sh` (branch detect → check existing mode → confirm if changing → write `.mode` file atomically)
- Create: `tests/unit/active-mode.test.sh`
- Create: `tests/unit/set-mode.test.sh`
- Create: `tests/integration/mode-lifecycle.test.sh`

**Approach:**
- Per `feedback_slash_command_arg_substitution`, command `.md` files contain *zero* `$`-bearing bash. The body is prose instructions that call `bash lib/set-mode.sh <name>` (and similar). Argument capture happens via the harness's `argument-hint` frontmatter + the command's defined param.
- `lib/set-mode.sh` uses `git rev-parse --abbrev-ref HEAD` to find the current branch and applies a **filesystem-safe allowlist slug**, not just `/` → `-`. Allowlist: `[a-zA-Z0-9_-]`; all other characters (including `..`, NUL, TAB, CR, leading dots) replaced with `-`. After slugification, reject slugs that normalize to `.`, `..`, empty string, or contain `..` sequences — git permits these branch names and unguarded slugs would produce path traversal (`<repo>/.claude/modes/...mode` resolves to parent). Uses the same `lib/validate-mode-name.sh` library that U10 calls for mode names — extracted to a shared helper to avoid drift.
- Detached HEAD handling: `git rev-parse --abbrev-ref HEAD` returns the literal `HEAD` in detached state; treat this as "no branch context" (same as not-a-git-repo), do not write `HEAD.mode`. Surface clearly.
- Confirmation logic (R12): if a mode is already active and the user is *changing* it (not clearing), the script prompts: "Currently in `discovery` — change to `delivery`? [y/N]". This uses Claude Code's argument-passing pattern, not interactive stdin, because hook environments don't have stdin to the user.
- **Zero-mode reconciliation with U10:** when invoked with zero modes defined system-wide, `/mode:set <name>` does NOT error "mode not defined" — it routes to the `mode-author` skill with `<name>` pre-filled as the proposed mode name. The "mode not defined; create via /mode:registry" error fires only when ≥1 mode exists but the requested one doesn't. This avoids the contradiction with U10's zero-mode flow.
- **Success output spec:** `/mode:set` success prints "Mode `<name>` active on branch `<branch-slug>`. Invoke any slash command to see mode-shaped behavior." `/mode:status` with no active mode prints "No mode active on branch `<branch-slug>`. Set with `/mode:set <name>` or author a new mode via `/mode:registry`." `/mode:clear` success prints "Mode cleared from branch `<branch-slug>`."
- `/mode:status` invokes `lib/active-mode.sh` plus a binding summary (count authored vs. inferred per the registry — but registry is U8, so V1 status can report just the active mode name until U8 lands; U9 extends it). When degraded-mode state exists (per U14), `/mode:status` surfaces the degradation reason.

**Technical design:** *(directional guidance, not implementation specification)*

`commands/mode/set.md` body:

```markdown
---
argument-hint: <mode-name>
allowed-tools: Bash
---

Set the active mode for the current branch to the named mode.

Read `lib/set-mode.sh` for the logic. To set, run:

`bash ${CLAUDE_PLUGIN_ROOT}/lib/set-mode.sh "$ARGUMENTS"`
```

*Note: this is the only place `$` appears in the .md file — and it's inside a backtick'd code block where the harness's substitution rules render it as literal text passed to bash, not pre-substituted. Verify behavior during U3 implementation against the live harness.*

**Patterns to follow:**
- `~/projects/crex/.claude/commands/crex/save.md` — command `.md` shape: frontmatter, prose, single bash invocation.
- `~/projects/Slate/plugins/slate-devs/commands/slate-devs.md` — lib/-call pattern.

**Test scenarios:**
- Happy path (`/mode:set`): on a fresh branch with no mode, write `<repo>/.claude/modes/<branch-slug>.mode` containing the mode name. Verify file contents.
- Happy path (`/mode:status`): with an active mode, report the mode name in the output. With no active mode, report "no mode active".
- Happy path (`/mode:clear`): removes the `.mode` file, leaving the branch unmoded.
- Edge case: branch name with `/` (e.g., `feature/foo`) slugifies to `feature-foo` for the filename.
- Edge case (path traversal): branch named `..`, `../escape`, or `feature/../..` slugifies to a safe form OR is rejected before any file write. Test asserts no file is created outside `<repo>/.claude/modes/` regardless of branch name.
- Edge case (control characters): branch with TAB/CR/NUL bytes in name (rare but git-permitted) is sanitized.
- Edge case: not in a git repo → `/mode:status` reports "no git context, mode inactive" and `/mode:set` errors gracefully.
- Edge case: detached HEAD state → `/mode:set` errors with "no branch context (detached HEAD); check out a branch first"; does not write `HEAD.mode`.
- Edge case (`Covers AE6`): when a mode is already active and the user runs `/mode:set` with a different mode, the script prompts for confirmation before overwriting.
- Edge case (`Covers AE6`): when a mode is already active and the user runs `/mode:set` with the *same* mode, no confirmation prompt (no-op).
- Edge case (zero-mode state): `/mode:set <name>` with zero modes routes to `mode-author` with `<name>` pre-filled — does NOT error. (Reconciles with U10.)
- Edge case (zero-mode state): `/mode:status` with zero modes reports "no modes defined; author your first via /mode:registry" — does NOT error, does NOT no-op.
- Edge case (zero-mode state): `/mode:clear` with zero modes reports "no modes defined and no active mode" — does NOT error.
- Error path: `/mode:set <name>` with ≥1 mode defined but the requested name not in `~/.claude/modes/` errors with "mode `<name>` not defined; existing modes: <list>; create new via /mode:registry".
- Error path (path traversal — R26 enforced at U3 entry): `/mode:set ../../etc/passwd` is rejected before any filesystem write; test asserts no file is created at any path. Same defense applies to `/mode:set ../registry`, `/mode:set ../../escape`, etc.

**Verification:**
- The full lifecycle (`/mode:set delivery` → `/mode:status` → `/mode:clear` → `/mode:status`) round-trips correctly. Branch slug handling works for branches with `/` in the name. Confirmation prompt fires on mode changes.

---

- U4. **UserPromptSubmit hook: heuristic injection (authored + inferred)**

**Goal:** Implement the UserPromptSubmit hook handler that reads the active mode, matches the user's prompt against authored bindings, and injects the appropriate heuristic block as a system-reminder.

**Requirements:** R6, R7, R10, R11, R18 (first-injection announcement).

**Dependencies:** U2, U3.

**Files:**
- Create: `scripts/on-prompt-submit.sh` (hook shim: read event JSON from stdin, dispatch to `lib/`)
- Create: `lib/inject-heuristic.sh` (core logic)
- Create: `lib/compile-heuristic.sh` (YAML binding → prose system-reminder)
- Create: `tests/unit/inject-heuristic.test.sh`
- Create: `tests/unit/compile-heuristic.test.sh`
- Modify: `.claude/hooks/hooks.json` (replace U1 stub with real registration)

**Approach:**
- Hook shim reads stdin event JSON, extracts the user prompt, and calls `lib/inject-heuristic.sh "$prompt"`.
- `lib/inject-heuristic.sh`:
  1. Resolve active mode (U3's `active-mode.sh`). No mode → exit 0, emit nothing.
  2. Match the prompt: strip leading whitespace, check if it starts with `/<word>` or `/<plugin>:<word>`. Otherwise → exit 0 (R7).
  3. Look up command in mode's `command-heuristics`. Match against bare form *and* plugin-namespaced form (e.g., `/ce-code-review` matches both bare and `/compound-engineering:ce-code-review`).
  4. If authored binding found → call `lib/compile-heuristic.sh` with the binding fields, emit `{"systemMessage": "<compiled prose>"}` JSON.
  5. If no binding found → emit `{"systemMessage": "<full mode definition>"}` JSON marked as inference context (with a clear `**Mode context (inference):**` prefix so the model knows to derive behavior rather than execute a contract).
- First-injection announcement (R18): track first-injection-per-session via a marker file. **Location:** `~/.claude/modes/.sessions/<session_id>` (NOT `/tmp/...`) — `~/.claude/modes/.sessions/` directory created with mode `0700` (`mkdir -m 0700`), individual marker files created with mode `0600`. This avoids `/tmp` world-readability on shared/CI systems. Stale markers older than 7 days are pruned on SessionStart. On first inject, prepend "🔧 Mode: `<name>` (set `<date>`)" to the systemMessage.
- `lib/compile-heuristic.sh`: hard-code field-to-prose mapping for `focus / bar / behavior / scope`. ~30 lines. Template-free, schema-explicit. Expandable as YAML schema grows.

**Patterns to follow:**
- `~/.cc-cmux/handler.cjs` — stdin-read + JSON-emit pattern (the cmux handler is JS, but the same shape works in shell).

**Test scenarios:**
- Happy path (`Covers AE2`): mode active with authored binding for `/ce-code-review`; user submits `/ce-code-review`; hook emits compiled prose system-reminder containing recognizable phrases from the binding's `behavior` field.
- Happy path (`Covers AE3`): mode active without authored binding for `/ce-debug`; user submits `/ce-debug`; hook emits the full mode definition as system-reminder, prefixed with inference-context marker.
- Happy path (`Covers AE4`): mode active; user submits natural-language "review this PR"; hook emits nothing (no injection on non-slash prompts).
- Edge case: prompt with leading whitespace before slash command — still matches (whitespace tolerance).
- Edge case: plugin-namespaced form `/compound-engineering:ce-code-review` matches the same authored binding as the bare `/ce-code-review`.
- Edge case: no active mode → hook exits cleanly with no output (pass-through).
- Edge case: active mode YAML file is missing or malformed → hook errors visibly to stderr but does *not* block the prompt (graceful degradation).
- Integration scenario: full lifecycle — `/mode:set delivery` → first invocation `/ce-code-review` shows announcement + injected prose; second invocation `/ce-code-review` shows injected prose only (no re-announcement).
- Integration scenario: command not in any binding triggers inference-mode injection; the model's prompt now contains the full mode definition.

**Verification:**
- Test fixtures simulate the harness's stdin JSON and assert against the script's stdout JSON. The complete set of decision-matrix branches (active/inactive × slash/natural × bound/unbound) all behave as specified. Manual smoke test: type `/ce-code-review` in a mode-active branch and observe the model's response references the bindings' guidance.

---

- U5. **Mode definition prose-loading for inferred bindings**

**Goal:** When no authored binding exists for a command, the inference injection must include enough of the mode's prose definition (philosophy + scope + lens + constraints) to let Claude derive useful behavior. Implement the definition-loading and formatting logic.

**Requirements:** R11.

**Dependencies:** U2, U4.

**Files:**
- Modify: `lib/inject-heuristic.sh` (add inference-context branch)
- Modify: `lib/compile-heuristic.sh` (add `compile_definition_for_inference` function)
- Modify: `tests/unit/compile-heuristic.test.sh`

**Approach:**
- `compile_definition_for_inference` reads the mode's top-level prose fields and concatenates them into a formatted system-reminder block:
  ```
  **Mode context (inference):** Active mode is `<name>`.
  
  **Philosophy:** <philosophy>
  
  **Scope:** <scope>
  
  **Lens:** <lens>
  
  **Constraints:**
  - <constraint 1>
  - <constraint 2>
  
  No authored heuristics exist for the command you just invoked.
  Derive appropriate behavior from this mode's intent.
  ```
- The "no authored heuristics ... derive appropriate behavior" framing matters: it signals to Claude that the injected context is a *lens* to apply, not a *rule* to follow verbatim.

**Test scenarios:**
- Happy path: mode with full prose definition produces a well-formatted inference-context block containing all four sections.
- Edge case: mode missing `constraints` section emits the block without that section (no empty list bullet).
- Edge case: mode missing `philosophy` or `scope` (shouldn't happen if U2 validates, but tolerate) emits the block with placeholder noting missing field.

**Verification:**
- The inference block visibly differs from an authored-binding block (different prefix, different structure). A user reading their session log can tell which mode of injection fired.

---

- U6. **Repo-local mode override**

**Goal:** Implement the resolution rule from R2 — if `<repo>/.claude/modes/<name>.yaml` exists, it fully replaces the global mode definition for that name.

**Requirements:** R2.

**Dependencies:** U2.

**Files:**
- Modify: `lib/mode-yaml.sh` (already implements the resolver from U2; this unit adds tests and any missing edge handling)
- Modify: `tests/unit/mode-yaml.test.sh`

**Approach:**
- U2 already structures the resolver; this unit hardens it: detect both files, prefer repo-local, log to stderr when override is in effect (visibility — user should know when their repo is overriding).
- No field-level merge in V1; repo-local fully replaces global (key technical decision: keeps semantics simple).

**Test scenarios:**
- Happy path: only global mode file exists → global resolves.
- Happy path: only repo-local mode file exists → repo-local resolves (covers the case where the user wants a project-specific mode that doesn't exist globally).
- Happy path: both exist → repo-local resolves; stderr emits a "using repo-local override" note for visibility.
- Edge case: malformed repo-local file → error is reported with the repo-local path (not the global), so the user knows where to fix.

**Verification:**
- The override mechanism works as documented. The visibility note appears in stderr (and thus in Claude Code's debug logs) when an override is in effect.

---

- U7. **PreToolUse hook: delegation gating (Task subagents + Skills)**

**Goal:** Implement the deterministic delegation gate. PreToolUse hook on `Task` (subagent dispatch) and `Skill` tool calls reads the active mode's `delegation.{agents,skills}.unmount` lists and hard-blocks calls to gated subagents/skills using the canonical PreToolUse contract.

**Requirements:** R13, R14, R23 (commands never gated — enforced by hook scope: only `Task` and `Skill` matchers, not slash command tools).

**Dependencies:** U2, U3.

**Files:**
- Create: `scripts/on-pre-tool-use.sh` (hook shim)
- Create: `lib/gate-delegation.sh` (core logic)
- Create: `lib/audit.sh` (append-only audit-log writer for block events)
- Create: `tests/unit/gate-delegation.test.sh`
- Create: `tests/unit/audit.test.sh`
- Modify: `.claude/hooks/hooks.json` (PreToolUse hook registered with matcher `Task|Skill`; optionally also match `Agent` defensively with a warn-log)

**Approach:**
- Hook shim reads stdin event JSON, extracts `tool_name` and `tool_input`. Tool name is `Task` (current harness), not `Agent` (legacy).
- `lib/gate-delegation.sh`:
  1. Resolve active mode (U3). No mode → exit 0 (allow).
  2. If `tool_name` is `Task`, extract `subagent_type` from `tool_input`. Strip any `<plugin>:` prefix to normalize (so `compound-engineering:ce-adversarial-reviewer` matches bare `ce-adversarial-reviewer` in unmount list). Look up in mode's `delegation.agents.unmount`. If matched → emit canonical block JSON (below).
  3. If `tool_name` is `Skill`, extract skill name from `tool_input.skill`. Look up in mode's `delegation.skills.unmount`. If matched → emit canonical block JSON.
  4. Optional defense: if `tool_name` is the legacy `Agent`, behave as for `Task` but emit a stderr warning so the harness regression is observable.
  5. Otherwise → exit 0 (allow).
- **Canonical block JSON contract:** write `{"hookSpecificOutput":{"permissionDecision":"deny"},"systemMessage":"<reason>"}` to **stderr** and exit with code **2**. The block reason lives in `systemMessage` as a **sibling** of `hookSpecificOutput`, NOT as a `permissionDecisionReason` child field — that field name was invented in an earlier draft and is consumed by no documented harness. This is the contract documented in `hook-development/SKILL.md` lines 144–153 and used verbatim by `validate-bash.sh`/`validate-write.sh`. The earlier `{"decision":"block","reason":"..."}` stdout shape is a Stop-hook-shaped pattern and is rejected here.
- **Block reason message:** name the gated entity, the active mode, and (when registry is available per U8) the modes where the entity IS mounted: e.g., "Subagent `ce-adversarial-reviewer` is unmounted in mode `discovery`. Modes that mount it: `delivery`, `polish`. Switch with `/mode:set <other>`."
- **Audit log (always-on, out-of-band visibility):** every block event is appended to `~/.claude/modes/.audit.log` (created with `(umask 077 && touch ...)`; `0600` permissions; append-only via `>>`). Line format: `YYYY-MM-DDTHH:MM:SSZ\tmode=<mode>\ttool=<Task|Skill>\tentity=<name>\treason=<truncated>`. This is the V1 answer to the deterministic-V1 adoption bar (`feedback_deterministic_over_probabilistic_v1`) on the visibility side: even if Claude doesn't relay the in-session `systemMessage`, the user can `tail -f ~/.claude/modes/.audit.log` and see every block event. Log rotates manually (V1); auto-rotation deferred to V2.

**Patterns to follow:**
- `~/.claude/plugins/cache/claude-plugins-official/plugin-dev/.../skills/hook-development/examples/validate-bash.sh` — canonical PreToolUse output shape (stderr + exit 2 + `hookSpecificOutput`).
- `~/.claude/plugins/cache/claude-plugins-official/plugin-dev/.../skills/hook-development/examples/validate-write.sh` — same.
- `~/.claude/plugins/cache/claude-plugins-official/skill-creator/.../scripts/run_eval.py` — confirms `tool_name == "Skill"` and `tool_input.skill` field name.
- `~/.cc-cmux/handler.cjs:1184-1188` — earlier (Stop-hook-shaped) pattern; cited as evidence that blocking is mechanically possible, NOT as the canonical contract.

**Test scenarios:**
- Happy path (`Covers AE5`): mode active with `ce-adversarial-reviewer` unmounted; Claude attempts `Task(subagent_type=ce-adversarial-reviewer)`; hook emits canonical block JSON to stderr with exit 2; block reason names the subagent and the mode; **audit log records the block event with timestamp/mode/tool/entity**. CE plugin files are not touched.
- Happy path (audit log isolation): repeated blocks accumulate to `~/.claude/modes/.audit.log` in append-only fashion; file permissions remain `0600`; line format matches the documented shape.
- Happy path (audit log observability): `tail -f ~/.claude/modes/.audit.log` running in another terminal shows block events as they occur — independent of whether Claude relays the in-session message.
- Happy path: mode active with `ce-resolve-pr-feedback` unmounted (skills.unmount); `Skill` invocation blocked with appropriate message via canonical block JSON.
- Happy path: mode active with agent *in mount* list (or not in unmount); call passes through (exit 0, no JSON emitted).
- Edge case: fully-qualified subagent name (`compound-engineering:ce-adversarial-reviewer`) matches bare entry in unmount list. Also tested in reverse — bare name in tool_input matches fully-qualified entry in unmount list.
- Edge case: legacy `Agent` tool name still produces a block (defensive matching) and emits a stderr warning so the regression is observable.
- Edge case: no active mode → all calls pass through (mode is opt-in).
- Edge case: mode active but `delegation` section empty → all calls pass through.
- Edge case: `tool_input` JSON malformed or missing `subagent_type` → hook exits 0 (don't break valid tool calls because of unknown input shape).
- **Empirical verification step (NOT a test — run at start of U7 implementation):** install a minimal trace-only PreToolUse hook, invoke (a) a nested Task dispatch from a parent agent, (b) a Skill loaded via `ToolSearch` mid-session, and (c) parallel Task calls in the same turn. Record observed firing behavior. If the hook does NOT fire on any of these cases, the deterministic-gating guarantee leaks at that boundary and R13/R14 must be amended. The bullets below are written as if these behaviors are confirmed; if verification fails, rewrite to acknowledge the leak as a known V1 gap.
- Edge case (pending empirical verification): nested `Task` calls (subagent dispatches another subagent) — hook fires on every level and uses the same active mode.
- Edge case: parallel `Task` calls in the same turn — each invocation independently evaluated; no shared-state corruption (no fixed-name temp files).
- Edge case (pending empirical verification): deferred `Skill` tool loaded via `ToolSearch` mid-session — hook fires on the loaded Skill, same as Skills available at session start.
- Edge case: competing PreToolUse hook installed (e.g., cc-cmux at `~/.claude/settings.json`) — hooks run in parallel with no defined ordering; any deny among parallel hooks should result in the tool being blocked. Verified with a fixture pass-through hook registered alongside.
- Integration scenario: full path — `/mode:set discovery` (with ce-adversarial-reviewer in unmount list) → user invokes `/ce-code-review` → CE attempts to dispatch ce-adversarial-reviewer internally → blocked → Claude relays reason → user switches to delivery → re-invokes `/ce-code-review` → passes.
- Integration scenario (`Covers AE5 + R19`): blocking happens without modifying any CE plugin files. Verified against `tests/fixtures/fake-ce-plugin/` (small CE-shaped fixture tree) via pre/post hash to avoid host-coupling and CE version drift; opt-in real-CE smoke test hashes only canary files (`agents/ce-adversarial-reviewer.md`, `skills/ce-resolve-pr-feedback/SKILL.md`, `AGENTS.md`).

**Verification:**
- The block message appears in Claude's session output naming the specific gated entity and active mode. CE plugin files remain unchanged across blocked invocations (R19 verification). The hook never breaks pass-through behavior when no mode is active.

---

- U8. **Registry data model and scan**

**Goal:** Implement the registry that tracks (command × mode) bindings with provenance (authored / inferred / uncovered), and the command-surface scan that enumerates available commands/agents/skills across installed plugins.

**Requirements:** R8, R9 (provenance), R20 (derivable + rebuild), R22 (new plugins surface as uncovered).

**Dependencies:** U2.

**Files:**
- Create: `lib/registry-scan.sh` (scan `~/.claude/plugins/cache/`, enumerate slash commands, agents, skills)
- Create: `lib/registry-read.sh` (load `~/.claude/modes/registry.json`)
- Create: `lib/registry-write.sh` (atomic-rename writes; rebuild from YAML + scan)
- Create: `tests/unit/registry-scan.test.sh`
- Create: `tests/unit/registry-read-write.test.sh`

**Approach:**
- Scan walks `~/.claude/plugins/cache/*/{commands,skills,agents}/` recursively using `find -P` (physical paths only, **does NOT follow symlinks**). For each `.md` file under `commands/<ns>/<verb>.md`, derive the slash command (`/<ns>:<verb>`); for top-level `commands/<verb>.md`, derive `/<verb>`. Skill dirs become skill names. Agent files (or frontmatter) become agent names. The `-P` flag prevents a malicious plugin from injecting attacker-controlled command names via symlinks pointing outside the cache directory.
- Registry schema (JSON):
  ```json
  {
    "version": 1,
    "scanned_at": "2026-05-15T12:00:00Z",
    "commands": [
      { "name": "/ce-code-review", "source": "compound-engineering", "type": "skill" },
      ...
    ],
    "modes": [
      { "name": "delivery", "source": "~/.claude/modes/delivery.yaml", "scanned_at": "..." }
    ],
    "bindings": [
      { "command": "/ce-code-review", "mode": "delivery", "provenance": "authored" },
      { "command": "/ce-debug", "mode": "delivery", "provenance": "inferred" }
    ]
  }
  ```
- Atomic write: create the temp file **in the same directory as the target** AND with restrictive permissions: `(umask 077 && mktemp ~/.claude/modes/registry.json.XXXXXX)`. The umask wrapper forces 0600 file creation; the same-directory placement keeps `mv` on one filesystem so the rename is atomic. Without the umask, default `mktemp` respects the process umask (often `022` → `0644` world-readable), exposing the registry contents to other local users during the create→rename window. `mv` across filesystems is copy-then-unlink, NOT atomic — a crash mid-copy leaves a partial `registry.json`. Verified via tests asserting (a) the temp file's filesystem matches the target's before rename, and (b) the temp file's mode is `0600` before any write completes.
- `--rebuild` flag (invoked via `/mode:registry --rebuild`): truncates registry, re-scans, re-reads all mode YAML, regenerates bindings (authored from YAML `command-heuristics`, inferred is tracked at runtime so rebuild sets all non-authored bindings back to "uncovered" — inferred caches are not regenerated; they fill in as the user invokes commands).

**Test scenarios:**
- Happy path: scan a fixture plugin tree with 3 commands across 2 namespaces; registry contains all 3 commands with correct namespacing.
- Happy path: registry round-trip — write JSON, read back, structures match.
- Happy path (`Covers AE8`): rebuild after adding a new plugin to the fixture tree; registry now contains the new plugin's commands as `uncovered` in every existing mode.
- Edge case: concurrent registry writes don't corrupt the file (atomic-rename test: simulate two writes; final file is valid JSON).
- Edge case (atomic-rename correctness): assert that the temp file used for atomic write is on the same filesystem as the target file before `mv` runs.
- Edge case: missing `~/.claude/modes/registry.json` is *not* an error — first-invocation behavior is to create it on the first registry-write call.
- Error path: `/mode:registry --rebuild` after the file is intentionally corrupted regenerates a valid registry.

**Verification:**
- The full command surface in Shawn's actual installation can be scanned and counted (sanity-check against agent 2's spot-check: ~1k commands, ~785 skills, ~272 agents). The registry survives a rebuild.

---

- U9. **`/mode:registry` interactive editor: status, coverage, promotion**

**Goal:** Implement the `/mode:registry` slash command, which routes to several subcommands: bare (show registry status), `coverage` (list uncovered commands frequently invoked), `promote <command> <mode>` (turn an inferred binding into authored), `--rebuild`.

**Requirements:** R15 (primary authoring surface), R16 (promotion), R17 (slash command set), R21 (coverage view).

**Dependencies:** U2, U7, U8.

**Files:**
- Create: `.claude/commands/mode/registry.md`
- Create: `.claude/skills/mode-author/SKILL.md` (the interactive authoring conversation invoked by `/mode:registry` and from U10)
- Create: `lib/registry-status.sh`
- Create: `lib/registry-coverage.sh`
- Create: `lib/registry-promote.sh`
- Create: `tests/unit/registry-promote.test.sh`
- Create: `tests/integration/registry-editor.test.sh`

**Approach:**
- `/mode:registry` with no args: routes through the `mode-author` skill (conversational). The skill reads the registry, summarizes mode count and coverage, and offers next-step options (author new mode, refine existing, review inferred bindings).
- `/mode:registry coverage`: prints commands that exist in the scan but have no authored binding in the active mode (R21). V1 lists all uncovered; V2 adds usage-frequency weighting.
- `/mode:registry promote <command> <mode>`: opens an authoring conversation for `<command>` × `<mode>` using the registry as context (current mode definition, what's already authored, what's uncovered) and writes the resulting binding to the mode YAML as an authored binding. **V1 does NOT cache inferred heuristics** — the "last-known inferred heuristic" surfacing was dropped per Risk row "Inferred-binding cache underspecified"; V2 may add caching. R16 is delivered via fresh conversation, not via inferred-cache replay. (This means AE7's test scenario — see below — was updated to reflect the fresh-conversation flow.)
- `/mode:registry --rebuild`: invokes U8's rebuild.
- The skill (`mode-author/SKILL.md`) is the long-running conversational surface. It contains the prompts and routing for "describe your mode in conversation → Claude proposes a YAML definition → user accepts/refines → writes file".

**Patterns to follow:**
- `~/projects/Slate/plugins/slate-roadmap/.claude/skills/` — conversational skill shape with phased prompts.

**Test scenarios:**
- Happy path: `/mode:registry` with no args reports "X modes defined, Y commands in registry, Z bindings (A authored, B inferred, C uncovered)".
- Happy path (`Covers AE7`): `/mode:registry promote /ce-debug delivery` opens an authoring conversation seeded with the active mode's definition and `/ce-debug`'s registry entry; on completion, the mode YAML is updated with the new authored binding for that command. (V1 promote does not require any prior inference to have fired — promotion is fresh authoring scoped to a specific command × mode pair.)
- Happy path: `/mode:registry coverage` while in delivery mode lists all commands without authored bindings.
- Edge case: `/mode:registry promote <command> <mode>` with an already-authored binding for that pair prompts confirmation before overwriting.
- Edge case: `/mode:registry --rebuild` reports the rebuilt counts ("X commands scanned, Y modes loaded, registry rebuilt").
- Integration scenario: full coverage-then-promote workflow — invoke a command in inference-mode, run promote, observe the binding move from inferred to authored in the registry.

**Verification:**
- The promote workflow round-trips: invoke an unbound command, observe inference; promote; re-invoke; observe authored injection instead. The registry's binding-count summary updates correctly across operations.

---

- U10. **First-mode authoring flow + zero-mode UX**

**Goal:** Ship the first-run experience for *authoring* a non-example mode. The default install also seeds two example modes (`example-discovery`, `example-delivery`) which give the user a working reference and a zero-stall path to first value (see R3 + U1). When the user invokes any `/mode:*` command and zero modes are defined (either fresh install where the user skipped the example-install step, or they deleted the examples), route through interactive authoring — the same conversational flow that handles *every* new-mode authoring whether or not examples are present.

**Requirements:** R3 (examples + interactive authoring), R15 (interactive editor is primary for non-example modes), R26 (mode name validation), and AE1.

**Dependencies:** U2, U9.

**Files:**
- Modify: `.claude/skills/mode-author/SKILL.md` (add zero-mode-state entry path)
- Modify: `.claude/commands/mode/set.md`, `status.md`, `clear.md`, `registry.md` (each checks for zero modes; if so, route to `mode-author`)
- Create: `tests/integration/first-mode-authoring.test.sh`

**Approach:**
- **Cross-unit reconciliation:** When invoked from `/mode:set <name>` with zero modes, `<name>` is pre-filled as the proposed mode name. When invoked from `/mode:status`, `/mode:clear`, or `/mode:registry` with zero modes, no name is pre-filled (user supplies during intent capture). All four `/mode:*` commands route to `mode-author` on zero-mode state — this is a property of the plugin state, not of any single command.
- `mode-author` skill is the conversation host. Phased flow:
  1. **Intent capture:** "What kind of work is this mode for? Modes can be **workflow-stage** (like the shipped `example-discovery`/`example-delivery` modes) OR **modality** (e.g., design-mode, pm-mode, writing-mode — recomposing Claude's agent/skill stack for a different kind of work). Describe its philosophy — what should Claude optimize for? What should it tolerate? What should it reject?" If the user can't articulate (responses are vague or empty), point them at the installed example modes: "Take a look at `~/.claude/modes/example-discovery.yaml` and `example-delivery.yaml` for working reference shapes — adapt one of those structures, or describe your own and I'll help you compose it."
  2. **Definition synthesis:** Claude proposes a mode definition (name, description, philosophy, scope, lens, constraints) and shows it for confirmation.
  3. **Initial bindings (optional):** "Want to author a heuristic for any specific commands now? Or set them up over time as you use them?" (Both paths are valid — V1 supports either.)
  4. **Delegation defaults (optional):** "Should this mode mount or unmount any agents/skills? Examples: discovery mode often unmounts adversarial reviewers; delivery mode often mounts them."
  5. **Validation:** validate name via `lib/validate-mode-name.sh` (filesystem-safe slug, not a reserved token, not colliding with existing mode names). If invalid, prompt for a different name.
  6. **Write file:** mode YAML is written to `~/.claude/modes/<name>.yaml` with `schema_version: 1`. Registry is updated.
  7. **Offer atomic set:** ask "Set `<name>` as the active mode on your current branch now? [Y/n]" (default Y). On Y, invoke `lib/set-mode.sh`. On n, fall back to "Mode `<name>` authored. Set it on this branch with `/mode:set <name>`." When invoked from a non-git directory (`/mode:set` would error), skip the offer and surface a note that the user can set later from a git context.

**Patterns to follow:**
- `~/.claude/plugins/cache/every-marketplace/compound-engineering/.../skills/ce-brainstorm/SKILL.md` — phased conversational skill pattern.

**Test scenarios:**
- Happy path (`Covers AE1`): fresh install with zero modes; user invokes `/mode:registry`; the editor reports zero modes and prompts the user to author their first mode. After conversation completes, the YAML exists at `~/.claude/modes/<name>.yaml` with `schema_version: 1`.
- Happy path: skipping optional steps (no initial bindings, no delegation) produces a valid minimal mode YAML.
- Happy path: providing all optional steps produces a fully-fleshed mode YAML.
- Happy path (zero-mode entry via `/mode:set`): `/mode:set delivery` with zero modes routes to authoring with `delivery` pre-filled; on completion, mode `delivery` exists.
- Happy path (zero-mode entry via `/mode:status`): `/mode:status` with zero modes reports "no modes defined" and offers the authoring entry path; does not error or no-op.
- Happy path (zero-mode entry via `/mode:clear`): `/mode:clear` with zero modes reports "no modes defined and no active mode" and does not error.
- Happy path (atomic set offer): user authors mode and accepts the "set now?" prompt; mode is written AND set on the current branch in one flow.
- Happy path (atomic set declined): user authors and declines the "set now?" prompt; mode written but not set; fallback message tells user how to set later.
- Edge case: user aborts mid-conversation → no partial YAML is written; no draft persisted (V1 is lossy on abort; draft persistence is Open Question for V2).
- Edge case: user picks a name colliding with a reserved token (`set`, `status`, `clear`, `registry`, `default`, `none`); validation rejects and prompts for a different name.
- Edge case: user picks a filesystem-unsafe name (whitespace, slash, leading dot, parent-directory traversal); validation rejects and prompts for a different name.
- Edge case: user picks a name colliding with an existing mode; validation rejects and offers either a different name or explicit overwrite confirmation.
- Edge case: user provides minimal/empty philosophy through all phases; depends on Open Question — either skill rejects (requires minimum content) or accepts and writes a valid-but-minimal YAML.
- Edge case: user authors from a non-git directory; atomic-set step is skipped with a note.
- Integration scenario: end-to-end first-run — install plugin, invoke any `/mode:*` command, author the first mode, accept atomic-set, invoke a slash command, observe mode-shaped behavior with first-injection announcement.
- Integration scenario (zero-cost on idle install): plugin installed but no modes authored for an extended session; hook overhead is bounded (defers to U11 perf test); no nudges or prompts surface.
- Integration scenario (second-mode authoring): with one mode existing, user invokes `/mode:registry`; skill surfaces existing mode count and offers next-step options including "author new mode"; second mode authored same way as first (with the registry summary as additional context).

**Verification:**
- AE1 passes: a fresh install with zero modes prompts the user through authoring rather than failing or no-op'ing.

---

- U11. **Integration test harness + smoke tests**

**Goal:** Provide a test runner and a small but meaningful integration test suite that exercises the full plugin end-to-end against a fixture plugin tree.

**Requirements:** none directly — this is execution-time quality infrastructure.

**Dependencies:** U1–U10 (tests exercise all units).

**Files:**
- Create: `tests/run.sh` (test runner; subcommands `[unit|integration|smoke|perf|all]`, `--verbose` flag; iterates per-subdir)
- Create: `tests/helpers/test-helpers.sh` (shared scaffolding; **documents the P0 `$HOME` isolation contract in its header**)
- Create: `tests/integration/full-lifecycle.test.sh`
- Create: `tests/integration/mode-switch-inflight.test.sh`
- Create: `tests/integration/error-recovery.test.sh`
- Create: `tests/integration/delegation-gating.test.sh`
- Create: `tests/integration/worktree.test.sh`
- Create: `tests/integration/perf.test.sh`
- Create: `tests/fixtures/` (sample mode YAMLs; sample plugin cache tree; `fake-ce-plugin/` for R19 hash-check)
- Create: `tests/SMOKE_CHECKLIST.md` (manual smoke artifact; PR-checkable)
- Create: `tests/perf-baseline.txt` (recorded median ms for no-mode hook path)

**Approach:**
- **Framework decision (Open Question, see Deferred to Implementation):** the closest precedent is `~/projects/Slate/plugins/slate-calls/tests/` which uses a hybrid (plain-sh `run-tests.sh` orchestrator + bats for actual test files + per-test `$HOME` isolation). The earlier plan claim that crex and slate-roadmap were precedents is corrected — crex has no tests; slate-roadmap uses bats predominantly. Recommend adopting the slate-calls hybrid; confirm in U11.
- **`$HOME` isolation is P0**, not optional. Every test sets `export HOME=$(mktemp -d)` in setup and cleans in teardown. Post-run hash of `$HOME_ORIGINAL/.claude/modes/` must equal pre-run hash — proves no test clobbered real authored modes.
- **Testability boundary:** hook → emitted JSON is shell-testable; everything after (model attends, harness honors block decision, behavior shifts) is smoke-only and tracked in `tests/SMOKE_CHECKLIST.md`. This boundary is also noted in System-Wide Impact.
- Integration tests use fixture data, not the real `~/.claude/plugins/cache/` (isolation).
- CI: none in V1 (no remote yet). Tests are run manually before declaring done.

**Test scenarios** (cross-layer integration; named with brief sketches — full assertions specified at implementation time):
- `set→read→inject` (basic happy path) — `/mode:set` writes branch state; subsequent `on-prompt-submit.sh` invocation with a fixture stdin event produces injection JSON whose injected content contains the mode's compiled prose. Covers the full automated half of the pipeline.
- `mode switch in-flight` — write mode A, run hook (assert A's prose); write mode B, run hook (assert B's prose appears, A's does not). Asserts branch-detection follows the switch with no caching staleness.
- `set on branch with existing mode → confirmation path` — `.mode` file already exists; `/mode:set <new>` prompts confirmation; respects user response.
- `registry rebuild while mode active` — active mode bound to a skill; `/mode:registry --rebuild` runs to completion; next hook fire still injects correctly. Asserts no live-write race.
- `worktree compatibility` — two fixture worktree dirs, each with a different branch+`.mode` file, sharing the same `$HOME` plugin install. Hook invoked from each produces correct per-branch injection.
- `malformed YAML does not block` — invalid mode YAML; hook exits 0, emits diagnostic to stderr, emits no injected content. Asserts the explicit error-propagation invariant from System-Wide Impact.
- `PreToolUse block-decision JSON shape` — mode disallows agent X; hook fired with fixture `Task`-tool event for X emits canonical block JSON on stderr with exit 2. Tests the JSON contract per R13 (harness honoring is smoke-only).
- `first-injection announcement appears once per session` — first hook fire writes session marker and includes announcement; second fire in same session omits announcement. Asserts R18.
- `branch slug collision warning` — two `.mode` files matching the same slug pattern; `/mode:status` exits 0 with stderr warning.
- `hook overhead with no active mode` — run `on-prompt-submit.sh` ≥50 times with no `.mode` file present; assert median wall time under threshold recorded in `tests/perf-baseline.txt`. Host-sensitive (don't gate strictly; fail loud on regressions). Converts the System-Wide Impact "<10ms" claim into an observable test per `feedback_predicted_bugs_need_tests_not_conventions`.
- `R19 parasitic-invariant lint` — grep `lib/*.sh scripts/*.sh` for any write operation (`>`, `>>`, `tee` without `-a`, `mv` destination, `cp` destination, `rm`, `sed -i`) whose path expression resolves under `~/.claude/plugins/`. Fail-loud on any match. This converts R19's "architectural invariant" claim from "we don't currently do this" (discipline) to "we cannot do this without the test failing" (actual structural enforcement). Closes the gap between the R19 claim and the fixture-tree hash-check verification.

**Smoke checklist artifact** (`tests/SMOKE_CHECKLIST.md`):
- Install plugin into a fresh `~/.claude/plugins/` symlink; `/mode:*` commands appear in `/help`
- `/mode:set <name>` then send a real prompt → Claude's response references the injected mode bindings
- PreToolUse block actually prevents agent dispatch (observable from chat, not just hook stdout JSON); block reason is relayed
- First-injection announcement is visible in chat output the first time after `/mode:set`
- Switch modes mid-session → next response shows the new mode's shaping
- Same plugin install + two worktrees on different branches with different active modes → each worktree's session sees its own mode

**Verification (observable bars, not "tests pass"):**
- `bash tests/run.sh` exits 0 with no shell errors on stderr.
- Every U-ID with implementation (U2–U10) has at least one named test scenario invoked by the runner.
- `tests/SMOKE_CHECKLIST.md` exists and is checked off in the PR description before declaring U11 done.
- `tests/perf-baseline.txt` recorded with date + median ms for the no-active-mode hook path.
- Post-run hash of `$HOME_ORIGINAL/.claude/modes/` equals pre-run hash (proves isolation contract was respected).

---

- U12. **README and developer-facing documentation**

**Goal:** Write the README and the in-repo docs needed for someone (Shawn, future contributor, or third party) to install, configure, use, and modify this plugin.

**Requirements:** none directly — documentation quality.

**Dependencies:** U1–U10.

**Files:**
- Modify: `README.md` (full rewrite from U1 stub)
- Create: `docs/architecture.md` (one-page summary: mechanism overview, file layout, hook flow diagrams)

**Approach:**
- README sections: Overview → Concepts (mode, registry, authored vs inferred, delegation gating) → Prerequisites → Install (symlink) → Configure → Slash Commands (table) → File Layout → Development → V1 Limitations & V2 Roadmap.
  - **Verify-on-harness-update note:** Include an explicit "If you've updated Claude Code, verify the PreToolUse hook contract still matches" callout in the V1 Limitations section, naming the contract shape (`hookSpecificOutput` + `systemMessage` sibling, stderr, exit 2) and pointing at `architecture.md` for the canonical reference. This is the V1 mitigation for the hook-contract-change risk (replaces the originally-planned U13/U14 runtime self-test).
  - **Trust boundary callout:** README explicitly flags that repo-local mode YAMLs in cloned repos are a prompt-injection surface (the heuristic-injection path system-reminder content). V1 ships without per-repo allowlisting; user accepts the risk for a single-user personal dev tool.
- `docs/architecture.md` is the "how it works" doc: the sequence diagrams from this plan's High-Level Technical Design section, distilled, plus the file-layout tree. Documents the canonical PreToolUse contract (stderr + exit 2 + `hookSpecificOutput` + `systemMessage` sibling) so future contributors know which precedent is authoritative.
- SessionStart hook prints one log line at startup naming the assumed hook-contract version (e.g., "claude-modes v1: assumes PreToolUse hookSpecificOutput shape per Claude Code ≥0.X"). This is the manual-verification anchor — if a future harness ships a contract change, the line is the discoverable reference point.
- Both docs reference the requirements doc and this plan as origin artifacts.

**Test scenarios:**
- Test expectation: none — documentation. Acceptance is whether someone reading the README can install + use the plugin without asking questions.

**Verification:**
- A first-time reader (or a `/ce-doc-review` pass over the README) finds no critical gaps. README + architecture.md together cover all V1 capabilities.

---

*(U13 and U14 were removed in post-doc-review revision — see Deferred for later → "PreToolUse contract self-test infrastructure (U13/U14)". The U-IDs U13 and U14 are RESERVED and will not be reused, per the U-ID stability rule.)*

---

## System-Wide Impact

- **Interaction graph:** UserPromptSubmit and PreToolUse hooks fire on *every* prompt/tool call across *every* repo where Claude Code runs. When no mode is active (default), they exit cleanly with no output. The cost-of-being-installed has two layers:
  1. **Cheapest possible early-exit when `~/.claude/modes/` is absent:** the *very first* check in every hook shim is `[ -d ~/.claude/modes ] || exit 0` — no `git rev-parse`, no `yq`, no subprocess work before that gate. Enforced by U11 test.
  2. **Cheap-but-nonzero path when modes are installed but no `.mode` file for the current branch:** read branch via `git rev-parse`, check for `.mode` file, exit. Budget: <50ms p95 per hook fire (originally <10ms; revised upward to account for bash startup overhead empirically observed on macOS). Recorded baseline in `tests/perf-baseline.txt`; regression test in U11.

- **Error propagation:** If any mode-related script errors (malformed YAML, missing file, bad command), the user-visible behavior must be: emit a clear error to stderr, do *not* block the prompt/tool call. Mode failures are recoverable; blocking a valid prompt because of a broken mode YAML would be worse than the missing mode shaping. (Exception: PreToolUse's block decision is *intentional* blocking, distinct from script error.)

- **State lifecycle risks:** Four durable state surfaces — `~/.claude/modes/*.yaml`, `~/.claude/modes/registry.json`, `~/.claude/modes/.audit.log` (append-only block-event log, `0600`), `<repo>/.claude/modes/<branch>.mode`. Plus an ephemeral surface: `~/.claude/modes/.sessions/<session_id>` (first-injection marker, pruned >7d on SessionStart). Registry can be rebuilt (R20). Mode YAML is user-authored — lost = user reauthor. Branch `.mode` files are tiny pointers; losing them just resets the branch to no-mode. Audit log is append-only; loss is acceptable (it's a visibility surface, not a source of truth). **Atomic-rename correctness:** all `mktemp` calls used for atomic writes create the temp file in the *same directory* as the target with `(umask 077 && mktemp ...)` so the subsequent `mv` stays on one filesystem AND the temp file is `0600` from creation. The original "atomic-rename" claim assumed cross-filesystem `mv` was safe (it is not — copy-then-unlink) and default-umask permissions (which would expose the registry during the create→rename window on systems with permissive umasks).

- **API surface parity:** None — this plugin doesn't expose APIs to other plugins. Its surface is slash commands and harness hooks.

- **Testability boundary:** Hook → emitted JSON is shell-testable. Everything after (model attends to injected context, harness honors block decision, behavior shifts in the model's response) is **smoke-only** and tracked in `tests/SMOKE_CHECKLIST.md`. Unit + integration tests cannot prove the model-side half of the pipeline; the smoke checklist exists to make that half a deliberate, PR-checkable artifact rather than an assumption.

- **Integration coverage:** End-to-end tests in U11 exercise the automated half of the cross-layer behaviors. Unit tests alone cannot prove the hook→YAML→prose→emitted JSON portion; integration tests cover it. The smoke checklist covers the rest.

- **Unchanged invariants:** Third-party plugin files (CE, slate-plugins, etc.) are *never* modified by this plugin. R19 is enforced architecturally: hooks observe and augment; nothing in this plugin writes to other plugins' directories. This is verifiable via a fixture CE-shaped tree (`tests/fixtures/fake-ce-plugin/`) hash-checked before/after the blocked call — see U7 test scenarios.

---

## Alternative Approaches Considered

- **Single Node.js dispatcher (cc-cmux pattern)** instead of separate shell scripts per hook. *Rejected for V1:* adds a Node dependency the shell-only approach avoids; the `feedback_slash_command_arg_substitution` rule is more naturally addressed with shell + `lib/*.sh` split; slate-devs precedent is shell-first. Architecturally cleaner but not worth the extra dependency at V1 scope.

- **Write-time YAML→prose compilation with caching** instead of hook-time compile. *Rejected:* cache invalidation problems (external YAML edits → stale cache → "Claude behaves slightly wrong") incompatible with the deterministic-V1 adoption bar. Hook-time compile is ~5-20ms — well below the felt latency threshold.

- **SQLite registry storage** instead of JSON. *Rejected:* overkill at the spot-checked ~2k entry surface; adds binary dependency and migration concerns. JSON is sufficient and inspectable with `jq`.

- **Zero pre-defined modes** instead of shipping examples. *Originally selected during brainstorm; reversed during post-deepening doc-review (2026-05-16).* Original rationale was identity-protection ("don't bake discovery/delivery in as the 'right' modes"). The reversal honors the same identity concern via **explicit labeling**: the shipped modes are named `example-discovery` and `example-delivery` (with a clear `description` field stating they are examples to adapt or delete), so they cannot be mistaken for the system's canonical defaults. The honest reason for the reversal: V1 has one user with one known mode pair (your own discovery/delivery workflow per `idea_discovery_delivery_pr_workflow`); rejecting them as defaults to protect against a hypothetical external audience that does not exist in V1 cost real adoption value (time-to-first-value gauntlet, no working reference to study) without buying real identity protection. If V1 develops external users, the example-labels keep the abstraction recognizably user-extensible rather than canonized.
- **Empty-start authoring without example modes (V1 dogfood)** instead of shipping examples. *Originally selected; reversed for the same reason above.* The dogfood goal — proving the authoring path works for users without seed material — is still tested: new (non-example) modes are still authored via U10's conversational flow. The examples don't substitute for the path; they reduce the cliff at first use.

- **Compositional modes (stacking)** instead of mutually exclusive. *Rejected during brainstorm:* runtime composition introduces conflict resolution as a first-class problem; V1 keeps the simpler invariant and reserves *mode inheritance* (named overlays) as a V2 escape valve. (See origin Key Decisions.)

- **Hide commands per mode** in addition to gating delegation. *Rejected during brainstorm:* commands are the user's interface; hiding them fights muscle memory. Only delegation surfaces (agents/skills) are gated. (R23.)

- **Direct workflow slash commands (`/discovery-start`, `/track-switch`, `/carve-delivery`) instead of mode abstraction.** *Considered during post-deepening doc-review (2026-05-16); rejected — abstraction earns its keep.* The origin idea memory (`idea_discovery_delivery_pr_workflow`) proposed a much smaller V1: three slash commands + ambient skill in `~/.claude/{commands,skills}/`. The product-lens reviewer surfaced this as the framing alternative the plan should weigh explicitly.

  **Why modes-as-infrastructure wins over the 3-command direct version:**
  1. **Cross-command work sequences.** The user named the load-bearing example: `/ce-work → /ce-code-review` chains differently per mode. A discovery-mode `/ce-code-review` skips adversarial reviewers; a delivery-mode `/ce-code-review` runs them. This is cross-command coherence that single-purpose slash commands cannot deliver — each command can only know about its own behavior, but mode state is read by every command independently.
  2. **Modality modes (not just workflow modes).** The user named additional mode pairs beyond discovery/delivery: `design-mode`, `pm-mode`, `writing-mode`. These are not project-stage modes; they're modality modes that recompose Claude's agent/skill stack for a different kind of work. The 3-command alternative is workflow-stage-specific by construction; modes-as-infrastructure is modality-general.
  3. **Deterministic delegation gating** is V1's load-bearing feature for adoption (`feedback_deterministic_over_probabilistic_v1`). Direct slash commands could ergonomically wrap the discovery/delivery workflow, but they couldn't deliver hard refusal of `Task(ce-adversarial-reviewer)` when the user invokes any other plugin's review skill — only a centralized mode-aware PreToolUse hook can.
  4. **Command-namespace explosion is the failure mode the 3-command alternative AVOIDS, not creates.** Per the user: "trying to learn x /commands × n modes would be crazy." Modes keep the command namespace flat (singular commands) while shaping behavior per mode — this is *why* the brainstorm rejected mode-flavored command grammar (`/ce-code-review:discovery` etc.) and *why* the 3-command alternative would scale poorly past one mode pair.
  5. **Multi-opinionated-system support.** The user's stated goal: "I love working with opinionated flows like compound engineering and I want to be able to use and develop multiple systems which harness the harness based on my needs at a given time." Direct slash commands embed *one* opinionated workflow (discovery/delivery). Modes let the user install and develop multiple opinionated systems (CE-style pipelines, dual-track agile, design-system flows, PM-mobility setups) where each system is its own mode rather than each erasing the others. The 3-command alternative cannot host this.
  6. **Solves the harness-bloat problem `/doctor` flags.** Today the harness has a flat descriptor surface: every plugin's agents/skills/commands compete for the same context budget all the time. With 278 agents installed across plugins, the descriptor surface truncates. Modes turn this from a scale problem into a contextualization problem — only the agents/skills/commands relevant to the active mode are mounted; the rest are silent until the user switches modes. Direct slash commands don't address this at all.

  **Acceptance criterion (30-day check):** if at 30 days post-V1 install the user has reached for `/mode:set` on at least one project — i.e., modes are actively used rather than installed-and-forgotten — V1 was worth building. If at 30 days modes are dormant, that's the signal to reconsider whether to retire claude-modes and ship the direct alternative. Falsifiable, observable, no telemetry needed.

---

## Risks & Dependencies

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| **PreToolUse hook contract change** — V1's R13 mechanism uses the canonical `hookSpecificOutput` + `systemMessage` shape, but the hook contract is harness-controlled, not an API contract Anthropic ships with stability guarantees. | Low | High (loss of deterministic gating = loss of adoption per `feedback_deterministic_over_probabilistic_v1`) | V1 mitigation is **documentation-only** (canonical contract documented in `architecture.md`; SessionStart log line names the contract version assumed; README has a "verify-on-harness-update" note). Defensive `Task\|Agent` matcher detects legacy tool-name regressions. Runtime self-test infrastructure was considered (originally U13/U14) and deferred to V2 — self-attestation by the system being attested cannot detect hook-not-loaded states, and the footprint was disproportionate to a Low-likelihood risk. Re-evaluate if observed adoption shows the documentation-only mitigation is insufficient. |
| **Heuristic injection is probabilistic** — model may not consistently attend to injected mode context across sessions. | Medium | Medium (manifests as "Claude behaves slightly wrong" in some session, not catastrophic failure) | Named heuristics + structured prose compilation are more reliable than freeform "be more lenient" prompts. First-injection announcement (R18) builds trust by making the mechanism visible. Promote frequently-used inferred bindings to authored (deterministic) to reduce variance over time. |
| **In-session block-reason relay is probabilistic** — the block itself is deterministic (tool doesn't run, audit log records the event), but the in-session reason reaches Claude via stderr `systemMessage` and depends on Claude relaying it to the user. | Medium | Low (V1 ships `~/.claude/modes/.audit.log` as out-of-band channel — even if Claude doesn't relay, the user can `tail -f` and see every block event) | **V1 ships dual-channel visibility:** in-session relay via `systemMessage` (best-effort, Claude attends to most messages) + always-on audit log (deterministic, observable via tail). This converts the original probabilistic-relay risk from "user might miss block events" to "user sees every block event in the audit log; in-session relay is bonus". V2 candidates: cmux notification on block events; audit log auto-rotation; `/mode:status` shows block count since last status check. |
| **YAML parsing dependency (`yq`) may not be available on all installs.** | Low | Medium (plugin install errors) | Fall back to `python3 -c "import yaml..."` if `yq` is absent. Detect at install time (in README's Prerequisites) and surface clearly. |
| **Registry can drift from reality** if plugin cache is rearranged externally without `--rebuild`. | Medium | Low (coverage view shows stale data; no functional impact on injection or gating) | `/mode:registry --rebuild` is a single keystroke recovery. SessionStart hook may opportunistically refresh registry mtime if older than 24h (V2 enhancement; V1 ships rebuild as manual). |
| **Mode YAML schema evolution after V1 ships** — users will author modes in V1's schema, and a V2 schema change would force migration. | Medium | Medium (one-time migration cost) | **V1 mode YAML ships `schema_version: 1` field** (R25, U2) — V2 migration script keyed on this field; unknown versions error visibly rather than silently misinterpreting. New optional fields are additive; renaming or removing requires bump + migration. |
| **Slash command argument substitution edge cases** in command `.md` files. | Medium | Low (caught at U3 implementation) | **U11 ships a test that scans `commands/**/*.md` for `$`-bearing bash outside backticked code blocks** — converts convention to observable lint, per `feedback_predicted_bugs_need_tests_not_conventions`. CI gate when CI lands. |
| **Branch name slugification ambiguity** (e.g., `feature/foo` and `feature-foo` collapse to the same slug). | Low | Low (rare; user would have to actively create both) | Document slugification rule; surface a warning on `/mode:status` if multiple `.mode` files match the current branch's slug pattern. |
| **Atomic-rename across filesystems** — `mktemp` without `-p` resolves to `$TMPDIR`, frequently a different volume than `~/.claude/`; `mv` across filesystems is copy-then-unlink (not atomic), so a crash mid-copy leaves a partial `registry.json`. | Medium | Medium (silent registry corruption) | **Create temp file in the same directory as target** (e.g., `mktemp ~/.claude/modes/registry.json.XXXXXX`); U8 test asserts temp file's filesystem matches target's before `mv`. System-Wide Impact's "no partial-write hazards" claim depends on this fix. |
| **Hook startup cost on every prompt/tool call** — bash startup alone on macOS runs 20–50ms before any logic; with two hooks firing per prompt across every repo, per-keystroke latency adds up. | Medium | Medium (felt latency) | Benchmark unit in U11 (`tests/integration/perf.test.sh`) records baseline median ms to `tests/perf-baseline.txt`; budget revised to <50ms p95 per hook fire. Early-exit guard before any subprocess work when `~/.claude/modes/` is absent. |
| **Cost-of-being-installed > 0 when no modes authored** — hook shims may spawn subprocesses (git, yq, python3) before discovering no modes exist. | High (in pre-author state) | Low–Medium (cumulative latency during the period before first mode authored) | **First line of every hook shim: `[ -d ~/.claude/modes ] || exit 0`** — before any other subprocess work. U11 integration test asserts zero subprocess cost in this state by mocking `git`/`yq`/`python3` and asserting they are not invoked. |
| **Block message doesn't surface valid alternative modes** — "switch to another mode" is too abstract when 5+ modes are authored. | Medium | Low (UX friction; user has to look up which modes mount the entity) | U7's block message includes "Modes that mount `<entity>`: a, b, c" derived from the registry — names the remediation explicitly. |
| **Detached HEAD / no-branch produces `HEAD.mode` slug** — `git rev-parse --abbrev-ref HEAD` returns the literal `HEAD` in detached state, producing a valid-looking slug that collides across detached checkouts. | Low | Low (file collision in rare state) | U3 detects `HEAD` literal and treats as no-branch-context; does not write a `.mode` file. Errors visibly on `/mode:set` with "no branch context (detached HEAD)". |
| **mode-author skill writes from unvalidated user input** — user-supplied mode name flows to filesystem path; typos like `my mode`, `prod/v2`, or `../escape` produce unreadable files or writes outside `~/.claude/modes/`. | Low | Medium (path traversal / unreadable filenames) | **U10 validates via `lib/validate-mode-name.sh`** — filesystem-safe slug, length cap, reserved-token rejection (R26). Test scenarios cover space/slash/dot/traversal cases. |
| **Inferred-binding cache underspecified** — U9's `/mode:registry promote` references "last-known inferred heuristic" but U4 doesn't define cache location/keying/invalidation. | Medium | Low (feature gap in V1 promote, not failure) | V1 resolution: drop "last-known inference" surfacing; promote starts a fresh conversation with the registry as input. Cache design deferred to V2. Update U9 approach accordingly. |
| **First-injection marker file leaks** — `/tmp/claude-modes-announced-${session_id}` accumulates per session over a working day. | Low | Low (stale file accumulation) | Relocated to `~/.claude/modes/.sessions/<session_id>` with `0700` parent dir and `0600` files; prune mtime >7d on SessionStart. |
| **Repo-local mode YAML is a trust boundary crossing** — R2's repo-local override mechanism means any cloned repo can ship `.claude/modes/<name>.yaml` that fully replaces the user's global mode. A malicious or accidentally-misconfigured mode YAML can inject arbitrary prose into the user's Claude session via the UserPromptSubmit hook's system-reminder injection (heuristic injection path), and can affect delegation behavior via the unmount lists. This is a prompt-injection surface the original plan did not name. | Medium (cloning untrusted repos is routine) | Medium (system-reminder injection is a real influence vector on Claude; not catastrophic but real) | V1 ships with documentation only (README explicitly flags the trust boundary; user accepts the risk for personal single-user dev tool). V2 candidates: per-repo opt-in allowlist before repo-local override activates; prose-field sanitization (strip markdown headers/code fences/XML tags before injection). Tracked as Open Question. |

---

## Documentation / Operational Notes

- **Install path**: symlink `~/projects/claude-modes` into `~/.claude/plugins/`. The README's Install section documents this; crex's README is the precedent.
- **First-run experience**: documented in README under "Getting Started" — invoke any `/mode:*` command; if no modes exist, you'll be walked through authoring your first.
- **No CI in V1**: tests run manually via `bash tests/run.sh`. Add CI when the plugin gets a remote.
- **No release process in V1**: this is personal infra. Add release process if/when publishing.
- **Worktree compatibility**: per `~/.claude/CLAUDE.md`, worktrees inherit branch context. Mode state is per-branch, so each worktree gets its own active mode automatically. Tested in U11 integration scenario `worktree compatibility`.
- **`/remote-control` reminder for execution**: V1 implementation is significant CE-pipeline work; open `/remote-control` at the start of `/ce-work` per `feedback_remote_control_significant_tasks`.

---

## Sources & References

- **Origin document:** `docs/brainstorms/2026-05-15-modes-as-infrastructure-requirements.md`
- **Related plugins:**
  - `~/projects/crex/` — closest precedent; mirror layout
  - `~/projects/Slate/plugins/slate-devs/` — `lib/*.sh` pattern
  - `~/.claude/plugins/cache/every-marketplace/compound-engineering/` — skill pattern reference
- **Hook mechanics reference:** `~/.claude/plugins/cache/claude-plugins-official/plugin-dev/.../skills/hook-development/SKILL.md`
- **Proven PreToolUse blocking pattern:** `~/.cc-cmux/handler.cjs:1184-1188`
- **Relevant memories:**
  - `~/.claude/projects/-Users-shawnroos/memory/feedback_deterministic_over_probabilistic_v1.md` (load-bearing for V1 adoption bar)
  - `~/.claude/projects/-Users-shawnroos/memory/feedback_slash_command_arg_substitution.md` (shapes U3, U9 implementation)
  - `~/.claude/projects/-Users-shawnroos/memory/project_claude_modes_plugin.md` (plugin project record)
  - `~/.claude/projects/-Users-shawnroos/memory/idea_discovery_delivery_pr_workflow.md` (origin idea)
