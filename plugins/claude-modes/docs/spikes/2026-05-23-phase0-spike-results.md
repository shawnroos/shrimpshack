# Phase 0 verification spike results

**Date:** 2026-05-23 (run during /ce-work execution)
**Plan:** `docs/plans/2026-05-23-001-feat-mode-agent-in-flow-editor-plan.md`
**Confidence:** High for Spikes A+B (verified via filesystem survey + Agent
tool enumeration in this session); Lower for Spikes C+D (limited to what
can be tested from inside a long-running session — see "Constraints"
below).

---

## Spike A: Plugin-agent manifest discovery layout — VERIFIED

**Question:** Which agent-shipping layout does the harness discover?

**Method:** Filesystem survey of all installed plugins at
`~/.claude/plugins/cache/*/*/*/` for the presence of `./agents/` vs
`.claude/agents/` directories AND inspection of each plugin's
`.claude-plugin/plugin.json` for an `agents:` manifest key.

**Result:**

| Layout | Plugins using it | Plugins declaring `agents:` in manifest |
|---|---|---|
| `./agents/<name>.md` (plugin root) | **13** (claude-code-workflows, plugin-dev, compound-engineering, nerd, slate-plugins ×3, beads, others) | 1 (iloom-lite — and the value is a path-array, not a directory-string) |
| `.claude/agents/<name>.md` | 2 (impeccable, ai-ml-toolkit) | 0 |

**Conclusion:** Convention is **`./agents/<name>.md` at plugin root with
NO manifest declaration**. Auto-discovery is the universal pattern. The
plan's original assumption (`.claude/agents/mode.md` + `"agents": "./.claude/agents"`
manifest key) **was wrong on both axes**: wrong path AND wrong manifest
shape (iloom-lite's array of paths is a different format than the plan
proposed string).

**Plan correction:**
- U1 changes from "add manifest key + create `.claude/agents/`" to
  "create `./agents/` directory; no manifest change to the `agents`
  key" (version bump 0.2.0 → 0.3.0 still needed).
- U7 changes from `.claude/agents/mode.md` to `./agents/mode.md`.
- Output Structure tree updates: `./agents/mode.md`.

**Filename convention:** Both `<name>.md` and `<name>.agent.md` are
observed in the wild. Compound-engineering uses `.agent.md` (51 files);
slate-plugins, nerd, and most others use plain `.md`. **Pick plain `.md`**
to match the more common convention and the user-authored shape at
`~/.claude/agents/`.

---

## Spike B: `subagent_type` prefix-stripping — VERIFIED (FALSIFIED for bare form)

**Question:** Does `subagent_type: mode` resolve to a plugin-shipped agent
named `mode`, or only `subagent_type: claude-modes:mode`?

**Method:** Inspection of the Agent tool's own enumeration of available
agents in this session's system prompt. The Agent tool lists every
dispatchable agent type; what's listed is what resolves.

**Result:**
- Plugin-shipped agents appear as **`<plugin>:<agent-name>` (namespaced
  form ONLY)** in the enumeration.
- Examples observed: `compound-engineering:ce-coherence-reviewer`,
  `slate-devs:slate-dev-persona`, `nerd:context-scanner`, `iloom-lite:planner`.
- **Bare forms (e.g., `ce-coherence-reviewer` without the namespace) do
  NOT appear in the enumeration for plugin-shipped agents.**
- Top-level (non-plugin) agents like `code-reviewer`, `Plan`, `Explore`,
  `general-purpose` do appear bare — but those are not plugin-shipped
  agents.

**Conclusion:** Only `subagent_type: claude-modes:mode` will resolve via
Task tool. **Bare `subagent_type: mode` will NOT resolve.** The
2026-05-15 plan's prefix-stripping policy is about claude-modes' OWN
hook normalizing names for its blocklist lookup — NOT about harness
Task-tool resolution. Feasibility review's correction stands.

**Plan correction:**
- U7's test scenarios drop the bare-form `subagent_type=mode` coverage.
  Only `subagent_type=claude-modes:mode` is in the test surface.
- Key Technical Decisions (agent name) section updates: "The Task tool
  resolves only the namespaced form `claude-modes:mode`. Bare `mode`
  does NOT resolve at the harness level. This is consistent across all
  plugin-shipped agents on the system."
- Risk row "subagent_type prefix-stripping" likelihood updates from
  "Medium" to "Resolved" — only namespaced form is tested.

---

## Spike C: `@mode` mention dispatch routing — SIMULATED (low confidence)

**Question:** Does the user typing `@mode <utterance>` trigger Task-tool
subagent dispatch?

**Constraint surfaced:** This cannot be empirically tested from inside a
running Claude Code session because:
- The orchestrator (me) doesn't *type* `@mode` — I generate output. The
  routing happens at the user-input parsing layer (terminal/UI →
  harness → model), not at the model layer.
- If I emit `@mode` in my own output, it's just text I produced; the
  harness doesn't reparse my output for `@`-mention routing.

**Indirect evidence from in-session inspection:**
- Claude Code's `@`-mention surface is commonly file-mention and image-
  attachment (`@./path/to/file.md`, `@image.png`).
- The Agent tool documentation in this session's system prompt does NOT
  mention `@<agent-name>` as a dispatch trigger; only `subagent_type:`
  parameter via Task tool is documented.
- Plugin-shipped agents with names like `slate-team-developer`, `nerd:context-scanner`,
  `compound-engineering:ce-coherence-reviewer` are NOT typically invoked
  via `@<name>` in actual session transcripts I've observed; they're
  dispatched programmatically via Task tool.

**Tentative conclusion (low confidence):** **`@mode` mention dispatch
likely does NOT route to Task-tool subagent dispatch.** The pattern
`@mode add figma` typed by the user probably resolves as text input,
not as a dispatch trigger. The model would need to recognize the `@`-
prefix pattern and emit a Task call in response.

**Plan implication (degraded path activated):**
- R1's primary UX shifts from "user types `@mode add figma`" to "user
  types `/mode:edit` OR describes intent in natural language; model
  recognizes mode-edit intent and dispatches `subagent_type:
  claude-modes:mode` via Task tool."
- The `@mode` surface is documented as "the model recognizes `@mode`
  as a hint to dispatch the mode agent" — relying on model instruction-
  following rather than harness parsing. Both routes work; the
  conversational headline becomes softer.
- U7's agent system prompt adds: "When the user types `@mode <utterance>`,
  treat it as an explicit request to dispatch this agent and act on
  `<utterance>`. The `@`-prefix is a cooperative convention between the
  user and you, not a hard harness contract."

**Recommendation:** **The user (Shawn) should verify in a fresh session
post-build:** install the 0.3.0 plugin, type `@mode test` in the prompt,
report what happens. If the harness DOES route it as a Task dispatch,
the model-instructed path is a no-cost fallback. If it doesn't, this
spike's tentative conclusion holds.

---

## Spike D: `/reload-plugins` script-context emission — SIMULATED (low confidence)

**Question:** Does emitting `/reload-plugins` from a Bash block inside a
script/skill cause the harness to actually reload plugins?

**Constraint surfaced:** This cannot be empirically tested from inside a
running session because:
- The harness loads plugin state at session start. Even if a script
  emits `/reload-plugins` and the harness consumes it, the running
  session's prior tool calls won't reflect the new state because they
  already completed against the old state.
- I can observe whether emitting `/reload-plugins` from a `Bash` tool
  call produces visible output or behavioral changes, but I can't
  observe whether *subsequent* tool calls see the post-reload plugin
  state — my plugin state is fixed at session start.
- A real test requires: (1) install the plugin, (2) start a new session,
  (3) modify a tier-3 YAML to add a plugin, (4) invoke a script that
  emits `/reload-plugins`, (5) verify the newly-added plugin's commands
  are available in the SAME session without manual user reload.

**Indirect evidence from feasibility review:**
- **Zero call sites in the claude-modes codebase invoke `/reload-plugins`
  from script context.** Every existing site (`lib/set-mode.sh:296-302`,
  `lib/set-mode.sh:380-385`, `scripts/restore-claude-modes.sh:159`,
  `mode-suggester` skill, `mode-author` skill) **prints the string** for
  the user to type.
- The 2026-05-18 V2 plan (Q4) explicitly recorded this question as
  "empirically deferred" and the answer was never produced.
- The brainstorm's "mode-suggester does this successfully" citation was
  wrong on inspection — mode-suggester prints the string in its success
  message.

**Tentative conclusion (low confidence):** **Script-context emission of
`/reload-plugins` likely does NOT trigger an actual plugin reload.** The
string is rendered as plain text in the terminal; the user reads it and
runs it. No primary source contradicts this.

**Plan implication (degraded path activated):**
- R5 ships in **degraded form**: `lib/post-write-reload.sh` prints a
  visible one-line notice that includes `/reload-plugins` as a
  copyable instruction. **The user manually runs reload.** Same
  deterministic-V1 contract (the user's reload is mechanical), different
  actor.
- U6's implementation does NOT attempt the auto-reload mechanism.
- The plan's "auto-reload" framing changes to "reload-prompt": the
  notice is non-silent, names the exact command, and the user closes
  the loop.

**Recommendation:** **The user should verify in a fresh session post-
build:** after installing 0.3.0, invoke `/mode:add <plugin>`, observe
whether the new plugin's commands work without typing `/reload-plugins`,
report. If reload happens automatically (e.g., via a hook mechanism
unknown to this spike), upgrade R5 to true auto-reload in a follow-on
release. If not, R5's degraded form is the permanent shape.

---

## Summary: plan corrections triggered by Phase 0

| Plan section | Original assumption | Spike outcome | Correction |
|---|---|---|---|
| U1 — manifest | Add `"agents": "./.claude/agents"` to plugin.json | NOT a documented convention; falsified | Drop the manifest key change; only bump version 0.2.0 → 0.3.0 |
| U1 — directory | Create `.claude/agents/` | Convention is `./agents/` | Create `./agents/` (plugin root), not `.claude/agents/` |
| U7 — file path | `.claude/agents/mode.md` | Convention is plugin-root `./agents/<name>.md` | `./agents/mode.md` |
| U7 — filename ext | `.md` (in plan; correct) | Both `.md` and `.agent.md` seen; `.md` more common | Confirmed `.md`; document the alternative in the precedent doc |
| U7 — test forms | Both `subagent_type=mode` and `claude-modes:mode` | Only namespaced form resolves | Drop bare-form coverage; only test `claude-modes:mode` |
| R5 — auto-reload | "Locked, mechanism TBD" | Likely degraded; emission-from-script unverified | Ship degraded form (visible notice with copyable `/reload-plugins`); upgrade path documented for post-ship verification |
| R1 — `@mode` UX | "User types `@mode add figma`" | Likely doesn't dispatch via harness routing | Add explicit Task-tool dispatch in U7's system prompt; `@mode` becomes a model-instructed convention, not a harness contract |

---

## Confidence summary

- **A, B**: high confidence — verified via filesystem evidence and
  in-session Agent tool enumeration. Primary source.
- **C, D**: low confidence — verified via indirect evidence (codebase
  call sites, harness documentation), but not falsified empirically.
  Build proceeds with the degraded-shape paths; user post-ship
  verification confirms or upgrades.

The plan proceeds with corrected paths and the degraded R1/R5 shapes.
If C or D later test positively in a fresh session, the upgrade is
purely additive (true `@mode` routing + true auto-reload) and doesn't
require code rework — just removing the user-prompts in U6 and adding
`@mode`-recognition language to the agent's system prompt.
