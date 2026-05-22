---
name: mode-author
description: >
  Conversational authoring of a claude-modes V2 mode definition. Use when
  the user asks to create a new mode, when /mode:registry --new is run,
  or when no modes are defined yet. Walks intent → definition →
  cascade-awareness → mechanism population → atomic write → optional set.
---

# mode-author skill (V2)

You are the conversational guide leading the user through a phased
authoring flow that ends with a well-formed mode YAML at
`~/.claude/modes/<name>.yaml`. Stay calm and patient; this is a thinking
exercise, not a form-fill.

## What changed from V1

V2's mechanism is **cascade-based**. A mode YAML (tier 3) contributes
`mechanism.enabledPlugins` and `mechanism.user_catalog` to a compile-time
cascade that produces `<repo>/.claude/settings.local.json`. Other
infrastructure (hooks, env, permissions, mcpServers) belongs in
`~/.claude/settings.json` (machine-wide) or `<repo>/.claude/hooks/hooks.json`
(per-repo) — NOT in any cascade YAML. The V2.0 cascade only flows
`enabledPlugins`; hooks/env/permissions placed in `_global.yaml` or
`_repo.yaml` are silently dropped (they never reach settings.local.json).
A tier-3 mode YAML is additionally rejected at write time if it declares
`mechanism.hooks` (R28 invariant).

The schema is `schema_version: 2`. V1 YAMLs (`schema_version: 1`) are not
migrated; if the user has V1 modes, point them at the archive at
`~/.claude/modes/.v1-archive/` and re-author here.

---

## Phased authoring flow

Work through these phases in order. Move forward once the user's
response satisfies the phase goal; loop back when an answer is vague,
incomplete, or contradicts an earlier choice.

---

### Phase 1 — Intent capture

Open by asking what kind of work this mode shapes. Surface the two
mode archetypes before they answer:

- **Workflow-stage modes** are named phases of a project where the same
  commands behave differently depending on lifecycle position. The
  installed `example-discovery` and `example-delivery` are canonical
  examples — discovery optimizes for learning velocity; delivery
  optimizes for shipping quality.
- **Modality modes** are named kinds of work where Claude's whole
  stack recomposes for a different domain. Examples: `design-mode`,
  `pm-mode`, `writing-mode`. The mode reshapes which agents/skills are
  reachable and which plugins are loaded.

Ask: what should Claude optimize for, tolerate, and reject in this mode?
Give 2-3 concrete example uses (e.g., "when I open a draft PR", "when
I'm reviewing a spec doc", "when I'm pairing on a bug").

If the answer is one vague word, surface the examples-on-disk:

> Take a look at `~/.claude/modes/example-discovery.yaml` and
> `~/.claude/modes/example-delivery.yaml` — those are working reference
> shapes you can adapt. Describe your mode in similar terms.

Do not advance until you have enough signal to propose a meaningful
definition. One clear sentence of intent is sufficient; one-word
answers are not.

---

### Phase 2 — Definition synthesis (prose layer)

Compose and propose a complete prose layer:

- **name** — a filesystem-safe slug (`[A-Za-z0-9_-]`, ≤64 chars, no
  reserved tokens like `set`, `clear`, `status`, `registry`, `setup`,
  `apply`, `adopt`, `statusline`, `_global`, `_repo`, `default`,
  `none`). Derive from the user's description.
- **description** — one or two sentences. Don't add "EXAMPLE mode" labels
  unless the user explicitly says this is an example.
- **philosophy** — what this mode optimizes for; what it tolerates; what
  it rejects. Two to four sentences of opinionated prose.
- **scope** — which branches, phases, or contexts this mode applies to.
- **lens** — a decision-making heuristic in the second person; one to
  three sentences beginning with "Treat", "Consider", or an active verb.
- **constraints** — a bulleted list of hard rules. Three to five entries.

Show the proposed definition. Ask: "Does this capture what you're going
for? Adjust any fields before we continue." Loop on refinement until
confirmed; accept partial confirmation ("yes but change X") — apply
the change and re-confirm the whole.

---

### Phase 2.5 — Cascade-awareness: which axes does this mode shape?

This is the **V2 fork in the road.** Before populating the mechanism
block, surface the axes a mode can shape so the user picks deliberately
rather than over-engineering by reflex.

Open with:

> A V2 mode can shape Claude along three independent axes. Pick the
> ones that fit; skip the ones that don't.
>
> 1. **Plugin catalog** (`mechanism.enabledPlugins`): which plugins
>    are loaded when this mode is active. Cascades on top of
>    `_global.yaml`. Can also `disable:` plugins from prior tiers.
>    Reaches Claude via `<repo>/.claude/settings.local.json` after
>    `/mode:set` + `/reload-plugins`.
>
> 2. **User catalog** (`mechanism.user_catalog.commands`,
>    `mechanism.user_catalog.agents`): which user-authored files at
>    `~/.claude/commands/` and `~/.claude/agents/` are visible while
>    this mode is active. Empty list = none of your user-authored
>    commands/agents show up. Useful when a mode wants a deliberately
>    narrow surface.
>
> 3. **Context injection** (`command_heuristics`): per-command prose
>    injected at prompt time. When a slash command runs with this mode
>    active, the named fields (focus / bar / behavior / scope) become a
>    `<system-reminder>` that biases Claude's reasoning without
>    mechanically gating the tool.
>
> Or pick **None**: a minimal mode that doesn't change the harness,
> just labels the working stance. The prose layer still injects via
> UserPromptSubmit so the model still "knows" what mode it's in.
>
> Which of these fits this mode?

Carry the user's selection into Phase 3 (only the chosen axes get
populated).

#### Hooks redirect — mandatory

If the user describes a need that translates to a hook (PreToolUse,
PostToolUse, UserPromptSubmit, SessionStart, Stop, Notification, etc.) —
for example, "I want a hook that runs lint when this mode writes
files" or "I want a SessionStart hook that prints a banner" — **do not
write hooks into the mode YAML**.

Say the following (literal opener — there is a test that greps for the
phrase "hooks live in"):

> In V2.0, hooks live in `~/.claude/settings.json` (machine-wide) or
> `<repo>/.claude/hooks/hooks.json` (per-repo) — NOT in any cascade YAML.
> The cascade only flows `enabledPlugins`; hooks placed in `_global.yaml`
> or `_repo.yaml` are silently dropped and never take effect. A tier-3
> mode YAML is additionally rejected at write time if it declares
> `mechanism.hooks` (`lib/write-mode-yaml.sh`, R28 invariant).

Then provide the actionable next step:

- For machine-wide hooks: `~/.claude/settings.json`
- For per-repo hooks: `<repo>/.claude/hooks/hooks.json` (note: this
  file lives in source control if committed, so anyone who can read
  the repo sees the hook commands — the user is responsible for what
  they commit).

Offer to open the relevant file via Read/Edit so the user can author
the hook directly. The mode YAML itself stays hook-free.

(The same redirect applies if the user asks to set permissions, MCP
servers, or environment variables in the mode YAML — V2.0 cascade
only carries `enabledPlugins`. Other keys live in tier 2 or tier 4.)

---

### Phase 3 — Mechanism population (per chosen axes)

For each axis the user picked in Phase 2.5, populate the corresponding
block. Skip the unselected axes entirely; the mechanism block can be
sparse.

#### 3a. Plugin catalog

Ask which plugins this mode adds to the baseline. The user can list
`<name>@<marketplace>` identifiers; if they're unsure, point them at
`~/.claude/plugins/installed_plugins.json` for the canonical list of
what's installed.

Also ask: are there plugins that `_global.yaml` enables that you want
to **disable** in this mode? (e.g., a strict reviewer plugin you want
turned off while in discovery mode). If yes, collect those into a
`disable.enabledPlugins` list.

> ⚠ **Cascade is additive by default.** The merged `enabledPlugins`
> from tier 2 + this mode + tier 4 is the cascade total. To RESTRICT
> privilege you must use the `disable:` block — a mode that wants to
> remove a globally-enabled plugin cannot do so by positive
> declaration alone. (Worked example below.)

Worked example — a "narrow review" mode that turns off compound-engineering:

```yaml
mechanism:
  enabledPlugins:
    "rams@my-marketplace": true
disable:
  enabledPlugins:
    - "compound-engineering@every-marketplace"
```

R22 invariant: `claude-modes@<marketplace>` must remain true in the
cascade total of every mode. The cascade engine asserts this at
`/mode:set` time. You don't need to write `claude-modes: true` in the
mode YAML — it inherits from `_global.yaml`.

#### 3b. User catalog

Ask which `~/.claude/commands/*.md` and `~/.claude/agents/*.md` should
be visible in this mode. List user-authored entries by basename
(`my-tool.md`, not full paths). An empty list means none.

If the user wants "the default set" (whatever's installed), suggest a
day-zero manifest: list every file currently at `~/.claude/commands/`
and `~/.claude/agents/`. The user-catalog block then drifts only when
new files are explicitly adopted.

#### 3c. Context injection (command_heuristics)

Ask which slash commands the user wants to shape, and for each one
collect:

- **focus** — what should Claude pay attention to when this command runs?
- **bar** — how strict or lenient?
- **behavior** — how should it act differently than the default?
- **scope** — what's in or out of scope?

Note: V2 uses underscore `command_heuristics` (V1 used hyphen
`command-heuristics`). The mode-yaml parser still accepts the hyphen
form for forward-compat, but write the underscore form for new YAMLs.

#### 3d. None / minimal mode

If the user picked "None" in Phase 2.5, the mechanism block can be
either fully absent or:

```yaml
mechanism:
  enabledPlugins: {}
  user_catalog:
    commands: []
    agents: []
```

The mode still shapes Claude via prose-layer injection in any session
where it's active.

---

### Phase 4 — Validate name + write file atomically

Validate the proposed name via the validate-mode-name library:

```
bash ${CLAUDE_PLUGIN_ROOT}/lib/validate-mode-name.sh check <name>
```

If non-zero, read the stderr message, explain it (reserved token /
forbidden chars / too long / leading-trailing dash), ask for a new
name, and re-validate.

Check for collision: if `~/.claude/modes/<name>.yaml` already exists,
ask the user to confirm overwrite before writing.

Compose the final YAML. Must include:
- `schema_version: 2`
- `name: <name>` (matches filename)
- `description: <...>` (multiline OK)
- Prose-layer fields (philosophy/scope/lens/constraints) — at least
  philosophy is strongly recommended.
- A `mechanism:` block (may be sparse — only the chosen axes populated).
- An optional `disable:` block.
- An optional `command_heuristics:` block.
- **Must not declare `mechanism.hooks`** (R28; the writer rejects).

Write the YAML via the writer library — **never** via raw `cat > path`:

```
cat <<'YAML' | bash ${CLAUDE_PLUGIN_ROOT}/lib/write-mode-yaml.sh ~/.claude/modes/<name>.yaml
schema_version: 2
name: <name>
description: |
  <description>

mechanism:
  enabledPlugins:
    "<plugin-id>@<marketplace>": true
  user_catalog:
    commands: []
    agents: []

# (optional) disable:
#   enabledPlugins:
#     - "<plugin-to-subtract>@<marketplace>"

philosophy: |
  <philosophy>

scope: |
  <scope>

lens: |
  <lens>

constraints:
  - <constraint 1>
  - <constraint 2>

# (optional)
command_heuristics:
  "/some-command":
    focus: <...>
    bar:   <...>
    behavior: <...>
    scope: <...>
YAML
```

The writer:

1. Validates the target path is under `~/.claude/modes/` or
   `<repo>/.claude/modes/` (refuses arbitrary paths).
2. Re-validates the name from the filename.
3. Parses with `yaml.safe_load`; aborts on parse error.
4. Asserts `schema_version: 2`.
5. For tier-3 mode YAMLs: asserts `mechanism.hooks` is absent (R28).
6. Atomic `mktemp + mv` with `umask 077` → file born at 0600.

If the writer exits non-zero, relay the stderr message; do not fall
back to a direct redirect. That bypasses R28's mechanical enforcement.

On success, confirm: "Mode `<name>` written to
`~/.claude/modes/<name>.yaml`."

---

### Phase 5 — Offer atomic set

Ask: "Set `<name>` as the active mode on your current branch now?
[Y/n]" (default Y).

On Y (or empty input): run `/mode:set <name>` (or the underlying
script if /mode:set isn't directly available from this skill context).
On success, confirm "Mode `<name>` is now active on this branch.
Invoke any slash command to see mode-shaped behavior."

On n: confirm "Mode `<name>` authored. Set it on any branch with
`/mode:set <name>` whenever ready."

Close with a pointer:

> The mode YAML lives at `~/.claude/modes/<name>.yaml`. Open it in
> your editor any time to tweak prose, enabledPlugins, user_catalog,
> or command_heuristics — every field is human-editable. The plugin
> re-reads it on every cascade compile; no restart required.

Special case: if the user is not inside a git working tree, skip the
offer entirely and close with: "Mode `<name>` authored. Set it from
a git branch with `/mode:set <name>`."

---

## Anti-patterns to avoid

- **Don't write hooks/env/permissions/mcpServers into ANY cascade YAML.**
  The V2.0 cascade only flows `enabledPlugins`; hooks/env/permissions placed
  in a mode YAML, `_global.yaml`, or `_repo.yaml` are silently dropped and
  never take effect. They belong in `~/.claude/settings.json` (machine-wide)
  or `<repo>/.claude/hooks/hooks.json` (per-repo). Repeat the Phase 2.5
  redirect if the user circles back.
- **Don't bypass `lib/write-mode-yaml.sh`** with a raw redirect into
  `~/.claude/modes/<name>.yaml`. That defeats R28's mechanical check.
- **Don't propose `disable:` blocks casually.** They subtract privilege
  from the cascade total; the user should explicitly want this.
- **Don't over-populate.** A minimal mode (prose layer only) is often
  the right answer for a new working stance. Add mechanism axes as
  patterns crystallize.
