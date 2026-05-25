# In-flow mode editor (mode-agent) — requirements

**Date:** 2026-05-23
**Status:** Brainstorm complete, ready for `/ce-plan`
**Plugin:** claude-modes
**Target release:** 0.3.0 (minor bump — new agent + new commands; no schema change)

---

## Problem

Modes today are **author-once structures**. The user creates one via
`mode-author`, sets it via `/mode:set`, and from that point on the mode
is fixed unless the user leaves their work, opens
`~/.claude/modes/<name>.yaml` in an editor, edits it by hand, saves, and
runs `/reload-plugins`. That round-trip is high enough that the user
hits friction every time they use a mode and does not act on it.

The observed friction has two shapes, both at point-of-use:

1. **"I want this skill in the mode."** The user notices a skill,
   plugin, or agent they want loaded by `<mode>` going forward — not
   only this session. Adding it requires leaving the task, finding the
   right `user_catalog` or `enabledPlugins` entry, writing it, and
   reloading.

2. **"This mode has an edge."** The user bumps into a constraint or
   missing capability that the mode shouldn't have here — a disabled
   plugin, a command_heuristic that's too strict, an agent the
   user_catalog excludes. They want to **widen the room they're in**,
   not switch modes or author a new one.

Both shapes are the same operation: **apply a delta to the active mode,
in-flow, persisted atomically.**

Quoting the user verbatim (2026-05-23):

> The problem with anything where you have to create structure outside
> of the context of using it results in oddities and right now there's
> no way to smooth the edges or "knock out a wall and extend a room"
> when using a mode.

This is the friction the 0.3.0 release solves.

---

## What we are building

A **single agent named `mode`** that acts as the conversational handle
on the active mode, plus a small set of slash commands that wrap the
same delta-application mechanism for no-conversation cases.

### Surfaces

| Surface | Shape | Use |
|---|---|---|
| `@mode <utterance>` | Agent dispatch (Task tool, `subagent_type: mode`) | Conversational tuning. "Add figma to this mode." "Why is typescript-lsp disabled?" "Loosen the constraint about no-debugging." |
| `/mode:add <plugin-or-skill>` | Slash command, one-shot | Add a plugin/skill/agent to the active mode's catalog. Mechanical. |
| `/mode:drop <plugin-or-skill>` | Slash command, one-shot | Add an entry to the active mode's `disable:` block. Mechanical. |
| `/mode:edit` | Slash command, opens conversational flow | Equivalent to `@mode` with no utterance — invites the user to describe what they want changed. |

All four routes terminate at the same atomic writer
(`lib/write-mode-yaml.sh`) and the same reload trigger
(`/reload-plugins`). There is one delta-application mechanism with four
ergonomics.

### What the `mode` agent does

When dispatched, the agent has its own context window (per the user's
L11 framing: an agent so the analysis doesn't pollute the main
conversation). Its bounded responsibilities are:

- **Read** the active mode's YAML, the audit log (existing
  `~/.claude/modes/.audit.log` — session-level events, no shape change
  in 0.3.0), and the current session's tool history available in its
  dispatch context.
- **Resolve candidates** for "add X" requests by searching
  `~/.claude/plugins/installed_plugins.json`, cached SKILL.md
  frontmatter under `~/.claude/plugins/cache/`, and
  `~/.claude/plugins/marketplaces/*/.claude-plugin/marketplace.json`.
  Marketplace search includes installed-but-not-yet-cached entries; it
  does **not** fetch remote marketplaces in 0.3.0 (deferred).
- **Propose a delta** in concrete terms: "add `figma@every-marketplace`
  to `mechanism.enabledPlugins`" or "remove `typescript-lsp@...` from
  the cascade-inherited disable block by ADDING `typescript-lsp:` true
  in this mode's `mechanism.enabledPlugins`." The agent shows the
  user the exact YAML change before any write.
- **Confirm via AskUserQuestion** when the delta is ready. The agent
  does NOT write silently; user accept is the gate.
- **Write atomically** via `lib/write-mode-yaml.sh` on accept.
- **Trigger reload** on writer success (see "Auto-reload behavior"
  below).
- **Explain** when asked: what's enabled in this mode, what's
  disabled, what the lens says, why a plugin isn't here.
- **Defer mode-switching to mode-suggester**: if the user asks "should
  I switch modes?" the agent points at `/mode:suggester` (or invokes
  it directly) rather than handling the switch itself.

### What the `mode` agent does NOT do

- It does **not** create new modes — that's `mode-author`'s job. If
  the user says "I want a new mode for X," the agent points at
  `mode-author`.
- It does **not** modify hooks, env vars, permissions, or MCP servers.
  Per R28, the cascade YAML doesn't carry those keys; the agent
  respects the same invariant and redirects the user to
  `~/.claude/settings.json` or `<repo>/.claude/hooks/hooks.json`.
- It does **not** auto-suggest unprompted. The agent is summoned, not
  ambient. (See "Trigger policy" below.)

### Slash command behavior

`/mode:add <identifier>` and `/mode:drop <identifier>` are
thin wrappers:

1. Identify the active mode via `lib/active-mode.sh name`.
2. Resolve `<identifier>` to a fully-qualified plugin/skill/agent name
   via the same candidate resolver the agent uses.
3. Build the delta.
4. If exactly one candidate matches, write atomically.
   If multiple candidates match, fall through to `AskUserQuestion` to
   disambiguate.
   If zero candidates match, error with the candidate list of
   "near-misses."
5. On write success, trigger reload (see below).

`/mode:edit` with no arguments is equivalent to dispatching the agent
with the user's next message as the utterance — convenience
discoverable from `/mode:registry`.

### Auto-reload behavior

On successful writer return, the slash command or agent fires
`/reload-plugins` automatically with a one-line console notice:

> Reloading plugins for mode `<name>` (added `<X>` to catalog).

**Never silent.** The user always sees that a reload happened. This
respects the user's `feedback_deterministic_over_probabilistic_v1`
memory — the load-bearing piece (catalog change → harness sees it) is
mechanically enforced, not left to the user to remember.

**Failure-mode handling is a planning question, not a brainstorm
decision.** If `/reload-plugins` fails after a successful YAML write
(rare; possible if the new catalog references a broken plugin), the
options are: (a) revert the YAML write, (b) leave the YAML as-is and
surface the reload error to the user. Both have tradeoffs. `/ce-plan`
to resolve.

### Trigger policy: invocation-only, never ambient

The agent is **summoned**, not **ambient**. There is no PostToolUse
hook that watches for "user reached for a disabled plugin" and fires
the agent. There is no PreCompact hook that auto-reflects on the
session. The only paths into the agent are:

- User invokes `@mode <utterance>`
- User runs a `/mode:*` slash command
- (Future, not in 0.3.0:) An ambient-friction-detection layer

This is a deliberate scope decision driven by two facts:

1. The friction the user actually described is **discovery-moment**
   ("I'm reaching for X now, the mode doesn't have it"), not
   **session-end-moment** ("looking back at this session, the mode
   should have been different"). Auto-surfacing solves a session-end
   problem the user did not name.
2. The `mode-suggester` skill from 0.2.4 already covers the
   complementary "should I switch modes entirely?" question. The
   ambient-suggestion surface is filled; the gap is on-demand
   refinement.

---

## Scope boundaries

### In scope for 0.3.0

- `mode` agent at `.claude/agents/mode.md` with the responsibilities above.
- `/mode:add` and `/mode:drop` slash commands.
- `/mode:edit` slash command (conversational entry without an
  utterance).
- Candidate resolver library (`lib/resolve-catalog-candidate.sh` or
  similar — naming is a planning concern). Searches local sources
  only: `installed_plugins.json`, cached SKILL.md frontmatter,
  installed marketplaces.
- Auto-reload on writer success with a non-silent notice.
- Tests for: agent dispatch from `@mode`-style invocations, slash
  command happy paths, candidate-resolution disambiguation, writer
  failure → no reload, reload failure → surface error.

### Deferred for later (named revisit conditions)

- **Per-tool-call telemetry (was Layer A).** Revisit when: the user
  reports that "the agent didn't know I had been reaching for X four
  times this session" is a real friction. Until then, the session's
  recent tool history available in the agent's dispatch context is
  sufficient signal for in-session "reached for" candidate ranking.
- **PreCompact auto-reflection (was Layer D).** Revisit when: the user
  reports that "I notice the friction only in retrospect, not in the
  moment" is a real friction. Today's evidence (every-mode-use,
  point-of-use) says it's not.
- **Remote marketplace fetch.** Revisit when: the user wants to add a
  not-yet-installed plugin and the candidate resolver returns nothing
  useful. 0.3.0 will surface "no candidates found — install via
  `/plugin install`" as a polite fallback.

### Outside this plugin's identity

- The `mode` agent does not become a general-purpose plugin manager.
  It only edits the active mode. Cross-mode operations
  ("disable typescript-lsp in all my modes") would belong to a
  different surface — explicitly out of scope.
- The agent does not write hooks, env, permissions, or mcpServers.
  R28 is preserved.

---

## Success criteria

A 0.3.0 release is successful when:

1. The user can add a plugin/skill/agent to the active mode in a
   single conversational turn (`@mode add figma`) or a single slash
   invocation (`/mode:add figma`), and see the catalog reload
   complete before they take their next action.
2. The user can remove or disable a plugin in the active mode by the
   same mechanism, and the disable is correctly written to the YAML's
   `disable:` block per the cascade-subtraction rules.
3. The agent surfaces the candidate list when an identifier is
   ambiguous — never silently picks one.
4. The agent never writes the YAML without an explicit accept.
5. Auto-reload fires on every successful write with a visible notice.
6. Suite passes (current baseline: 530/0 on feat/modes-v2). New tests
   added for each surface and for the documented failure modes.
7. The user reports the "knock out a wall" friction is meaningfully
   reduced after living with 0.3.0 for at least one week.

The seventh criterion is the qualitative load-bearing one. The first
six are quantitative gates.

---

## Dependencies and assumptions

### Verified against the repo (2026-05-23, feat/modes-v2)

- `lib/write-mode-yaml.sh` exists and provides atomic write with R28
  enforcement. The agent will not bypass it.
- `lib/active-mode.sh` provides the canonical active-mode resolver
  (per-branch override → user-global fallback). Both the agent and the
  slash commands MUST use it; reading `.last-active-mode` directly
  produces wrong answers in multi-mode-per-repo setups.
- `~/.claude/modes/.audit.log` is the existing TSV audit log. 0.3.0
  does NOT change its shape — events for `mode_edit_accept` and
  `mode_edit_reject` use the same `event=<name>\tfield=value` shape.
- `.claude/hooks/hooks.json` wires `UserPromptSubmit`, `PostToolUse`
  (matcher=Write), and `SessionStart` only. 0.3.0 adds NO new hook
  events.
- The plugin currently ships zero agents (`.claude/agents/` is
  absent). `mode.md` will be the first.

### Unverified assumptions (flag for /ce-plan)

- That `subagent_type: mode` works cleanly when the agent is shipped
  by a plugin (not a user-authored `~/.claude/agents/` file). Plugin
  agents appear in the Task tool's agent list — verified by inspection
  of the current dispatch tool description — but the exact
  routing-by-name behavior should be re-confirmed during planning.
- That `/reload-plugins` is safely invocable from inside a skill's
  bash block. The existing `mode-suggester` skill does this
  successfully, so the assumption is strong but not formally
  documented.
- That candidate resolution from cached SKILL.md frontmatter is
  reliable — i.e., the cache structure is stable. Worth a planning
  spike before committing the candidate resolver's design.

---

## Privacy and safety

- **No remote network access** in 0.3.0. Candidate resolution is
  local-only. The "fetch GitHub-hosted marketplace.json" idea is
  explicitly deferred.
- **No new telemetry.** The existing audit log records the
  edit-accept/edit-reject events at the session level — same privacy
  posture as the existing `prose_inject` and `session_reconcile`
  events. Nothing leaves the user's machine.
- **R28 (no hooks/env/permissions/mcpServers in cascade YAML)
  preserved.** The agent rejects any delta that would write those keys
  into the YAML, matching the writer's own enforcement.
- **R22 (claude-modes self-presence) preserved.** The agent rejects
  any delta that would remove `claude-modes@<marketplace>` from the
  cascade total.
- **Atomicity preserved.** Every write goes through
  `lib/write-mode-yaml.sh` — atomic mktemp+mv, born at 0600. The
  agent cannot bypass.

---

## Test surface

To be filled in by `/ce-plan`. The brainstorm-level expectation is:

- Agent dispatch tests (using the same harness pattern as
  `mode-suggester` tests).
- Slash command tests for `/mode:add`, `/mode:drop`, `/mode:edit` —
  happy path, ambiguous identifier, no-match identifier, write
  failure, reload failure.
- Integration test: end-to-end "user says `@mode add figma`, agent
  proposes, user accepts, YAML written, reload fires, plugin loads"
  with a fixture plugin to avoid touching the real installed_plugins.
- Existing 530/0 suite stays green.

---

## Open questions for `/ce-plan`

1. **Naming.** Is `mode` the right agent name, or does it collide with
   conceptual cognitive load (the user types `@mode` to talk to "the
   mode itself" — felicitous, but is it confusing in transcripts)?
   Alternatives: `mode-tutor`, `mode-editor`, `mode-room` (matching
   the "knock out a wall" metaphor).
2. **Reload failure handling.** Revert the YAML write, or leave the
   partial state with a clear error surface? (See "Auto-reload
   behavior" above.)
3. **Cross-tier writes.** The agent edits **tier 3** mode YAMLs by
   default. Should it ever be able to edit `_global.yaml` (tier 2) or
   `_repo.yaml` (tier 4)? Probably not in 0.3.0, but the boundary
   should be named.
4. **Delta confirmation UX.** Show the diff as a unified-diff snippet,
   or as a before/after YAML block, or as natural-language summary?
   The AskUserQuestion `preview` field supports rendered code — worth
   a deliberate UX call during planning.
5. **`mode-suggester` ↔ `mode` agent boundary.** Both are reachable
   via the user's voice. mode-suggester switches between modes;
   mode-agent edits the active mode. The agents' system prompts must
   make this distinction sharp so the user (and the harness) routes
   correctly. Planning should specify the exact disambiguation rule.

---

## Origin trace

This brainstorm replaces an earlier four-layer mode-tutor proposal
sketched during the L11 session (mode-suggester + subagent-lens
propagation). The four-layer framing was:

- A: per-mode tool-call telemetry
- B: skill/marketplace discovery helper
- C: on-demand hybrid mode-tutor (skill + agent)
- D: PreCompact auto-reflection

The attachment-gap probe during the 2026-05-23 brainstorm collapsed
that framing. The friction the user reported is point-of-use, not
session-end; the right surface is conversational and summoned, not
ambient. Layer C became the whole product (as `@mode`). Layer B folded
in as the agent's candidate-resolution capability. Layers A and D are
"Deferred for later" with named revisit conditions above.

The reframe is documented here so `/ce-plan` doesn't reconstruct the
discarded layers from first principles.
