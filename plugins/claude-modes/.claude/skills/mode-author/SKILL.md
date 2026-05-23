---
name: mode-author
description: >
  Conversational authoring of a claude-modes V2 mode definition. Use when
  the user asks to create a new mode, when /mode:registry --new is run,
  or when no modes are defined yet. Walks intent → definition →
  cascade-awareness → mechanism population → atomic write → optional set.
---

# mode-author skill (V2)

You are the conversational guide leading the user through a phased authoring
flow that ends with a well-formed mode YAML at `~/.claude/modes/<name>.yaml`.
Stay calm and patient; this is a thinking exercise, not a form-fill.

This skill mixes **structured choices** (presented via `AskUserQuestion` where
the answer is genuinely from a small fixed set) with **open prose** (where the
question is "tell me what you're thinking" and a menu would constrain you).
The pattern: structured choices remove "guess the identifier" friction; open
prose stays for intent + voice + craft.

## Loading the question tool

In Claude Code, `AskUserQuestion` is a deferred tool — its schema is not
loaded at session start. **Before Phase 1**, call `ToolSearch` with query
`select:AskUserQuestion` once, eagerly. The fallback (numbered list in chat)
applies only when the harness genuinely lacks a blocking question tool —
never silently skip a question.

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

Work through these phases in order. Move forward once the user's response
satisfies the phase goal; loop back when an answer is vague, incomplete, or
contradicts an earlier choice.

---

### Phase 1 — Intent capture

**A1 (structured):** open with an `AskUserQuestion` for the mode archetype.
This is one of two well-defined categories; surfacing them as options removes
the need for the user to learn the V2 vocabulary before they can answer.

Call `AskUserQuestion` with:

- **question**: "What kind of mode is this?"
- **header**: "Archetype"
- **options**:
  1. **Workflow-stage** — A named phase of a project where the same commands
     behave differently depending on lifecycle position (like the seeded
     `discovery` and `delivery`: discovery optimizes for learning velocity;
     delivery optimizes for shipping quality).
  2. **Modality** — A named *kind* of work where Claude's whole stack
     recomposes for a different domain (e.g. `design`, `pm`, `writing`,
     `pairing`). The mode reshapes which agents/skills are reachable and
     which plugins are loaded.

**A2 (open prose):** after the archetype is picked, ask in plain prose:

> Tell me what kind of work this mode shapes. Two or three concrete examples
> of when you'd want to `/mode:set` it. What should Claude optimize for,
> tolerate, and reject in this mode?

This is intentionally open. The whole point of mode-authoring is the user
saying out loud what bugs them about Claude's defaults today; constraining
that into multiple-choice would lose the signal.

If the answer is one vague word, surface the examples-on-disk:

> Take a look at `~/.claude/modes/discovery.yaml` and `~/.claude/modes/delivery.yaml`
> — those are working reference shapes you can adapt. Describe your mode in
> similar terms.

Do not advance until you have a clear sentence of intent. One-word answers
are not enough.

---

### Phase 2 — Definition synthesis (prose layer)

Compose and propose a complete prose layer:

- **name** — a filesystem-safe slug (`[A-Za-z0-9_-]`, ≤64 chars, no
  reserved tokens). The canonical reserved-token set is defined in
  `lib/validate-mode-name.sh`: `default none set status clear apply
  registry adopt setup list help promote rebuild coverage claude _global
  _repo`. Derive the name from the user's description; the writer
  re-validates at write time so this list is advisory.
- **description** — one or two sentences. Don't add "EXAMPLE mode" labels
  unless the user explicitly says this is an example.
- **philosophy** — what this mode optimizes for; what it tolerates; what it
  rejects. Two to four sentences of opinionated prose.
- **scope** — which branches, phases, or contexts this mode applies to.
- **lens** — a decision-making heuristic in the second person; one to three
  sentences beginning with "Treat", "Consider", or an active verb.
- **constraints** — a bulleted list of hard rules. Three to five entries.

Show the proposed definition (full YAML draft in a fenced block).

**A3 (structured):** then call `AskUserQuestion`:

- **question**: "Does this capture what you're going for?"
- **header**: "Definition"
- **options**:
  1. **Looks good — continue** — accept as drafted and move to Phase 2.5.
  2. **Needs edits** — keep most fields, change specific ones (you'll tell
     me what in the next message).
  3. **Start over** — re-do the prose layer with different intent.

**A4 (open prose, on "Needs edits"):** when the user picks edits, switch
to free prose: "Which fields, and what do you want them to say?" Apply the
changes and re-show the whole draft, then re-fire A3. Loop until "Looks
good — continue" or "Start over".

---

### Phase 2.5 — Cascade-awareness: which axes does this mode shape?

This is the V2 fork in the road. Surface the axes before the user populates
mechanism, so they pick deliberately rather than over-engineering by reflex.

Brief the four axes in prose first so the user has the mental model:

> A V2 mode can shape Claude along three independent axes (or none of them).
> The minimal mode just labels the working stance via its prose layer.
>
> 1. **Plugin catalog** (`mechanism.enabledPlugins`): which plugins are
>    loaded when this mode is active. Cascades on top of `_global.yaml`.
>    Can also `disable:` plugins from prior tiers. Reaches Claude via
>    `<repo>/.claude/settings.local.json` after `/mode:set` + `/reload-plugins`.
> 2. **User catalog** (`mechanism.user_catalog.commands`,
>    `mechanism.user_catalog.agents`): which user-authored files at
>    `~/.claude/commands/` and `~/.claude/agents/` are visible while this
>    mode is active. Empty list = none. Useful when a mode wants a
>    deliberately narrow surface.
> 3. **Context injection** (`command_heuristics`): per-command prose
>    injected at prompt time. When a slash command runs with this mode
>    active, the named fields become a `<system-reminder>` that biases
>    Claude's reasoning without mechanically gating the tool.

**A5 (structured, multi-select):** call `AskUserQuestion` with
`multiSelect: true`. The first option is listed first deliberately —
the skill's anti-patterns guidance ("A minimal mode is often the right
answer for a new working stance") makes None the recommended default. A
pick-first-option agent ends up with a minimal mode rather than the
maximally-complex Plugin catalog.

- **question**: "Which axes should this mode shape? (Pick any combination.)"
- **header**: "Axes"
- **multiSelect**: true
- **options**:
  1. **None — minimal mode (Recommended)** — prose-layer only; mechanism
     block left empty. The mode still labels the working stance via prose
     injection. Add axes later as patterns crystallize.
  2. **Plugin catalog** — enable specific plugins; optionally disable some.
  3. **User catalog** — restrict which authored commands/agents are visible.
  4. **Context injection** — per-command prose biases via `command_heuristics`.

Carry the selection into Phase 3 (only the chosen axes get populated). If
the user picks "None" alongside others, treat "None" as deselected — the
others win.

#### Hooks redirect — mandatory (R28 invariant)

If the user describes a need that translates to a hook (PreToolUse,
PostToolUse, UserPromptSubmit, SessionStart, Stop, Notification, etc.) — for
example, "I want a hook that runs lint when this mode writes files" or "I
want a SessionStart hook that prints a banner" — **do not write hooks into
the mode YAML**.

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
- For per-repo hooks: `<repo>/.claude/hooks/hooks.json`

Offer to open the relevant file via Read/Edit so the user can author the
hook directly. The mode YAML itself stays hook-free.

(The same redirect applies if the user asks to set permissions, MCP servers,
or environment variables in the mode YAML — V2.0 cascade only carries
`enabledPlugins`. Other keys live in tier 2 or tier 4.)

---

### Phase 3 — Mechanism population (per chosen axes)

For each axis the user picked in Phase 2.5, populate the corresponding
block. Skip the unselected axes entirely; the mechanism block can be sparse.

#### 3a. Plugin catalog (`enabledPlugins` + optional `disable`)

First, gather the user's actual installed plugins so the choices are real,
not invented. Read `~/.claude/plugins/installed_plugins.json` — its top
level has `plugins: { "<name>@<marketplace>": [...] }`. Build a sorted list
of plugin identifiers.

**A6 (structured, multi-select):** for plugins to ADD on top of the global
baseline, call `AskUserQuestion` with `multiSelect: true`:

- **question**: "Which plugins should this mode ADD on top of the global
  baseline?"
- **header**: "Add plugins"
- **multiSelect**: true
- **options**: up to 4 plugin identifiers from the installed list. The tool
  caps at 4 options per question; if the installed list is longer than 4,
  pick the 4 that seem most relevant to the mode's intent (from the
  description, philosophy, and scope already captured) and offer them.
  Mention in prose that "Other" lets the user type identifiers not in
  the four offered.

If "Other" is selected with free-form text, accept comma- or newline-separated
`name@marketplace` identifiers. Validate each one exists in the installed
registry; flag any unknowns and ask whether to drop them or proceed.

**A7 (structured, multi-select):** for plugins to DISABLE (subtract from the
cascade — the inverse operation), call `AskUserQuestion` with
`multiSelect: true`:

- **question**: "Which plugins from the global baseline should this mode
  DISABLE?"
- **header**: "Disable plugins"
- **multiSelect**: true
- **options**: up to 4 currently-globally-enabled plugins that look like a
  fit for disabling in this mode (heuristic: plugins whose categories
  contrast with the mode's intent — e.g. for a `design` mode, surface
  code-heavy plugins as candidates).

If the mode has 0 plugins to disable, skip A7 entirely (don't ask).

> ⚠ **Cascade is additive by default.** The merged `enabledPlugins`
> from tier 2 + this mode + tier 4 is the cascade total. To RESTRICT
> privilege you must use the `disable:` block — a mode that wants to
> remove a globally-enabled plugin cannot do so by positive declaration
> alone.

Worked example — a "narrow review" mode that turns off compound-engineering:

```yaml
mechanism:
  enabledPlugins:
    "rams@my-marketplace": true
disable:                                  # TOP-LEVEL key, sibling of mechanism:
  enabledPlugins:
    - "compound-engineering@every-marketplace"
```

R22 invariant: `claude-modes@<marketplace>` must remain true in the cascade
total of every mode. The cascade engine asserts this at `/mode:set` time. You
don't need to write `claude-modes: true` in the mode YAML — it inherits from
`_global.yaml`.

#### 3b. User catalog

Read `~/.claude/modes/.user-catalog/commands/*.md` and
`~/.claude/modes/.user-catalog/agents/*.md` to learn the actual authored
file set (the staging dir after `/mode:setup` ran). List entries by
basename, not full path.

**A8 (structured, multi-select):** if commands exist, call `AskUserQuestion`:

- **question**: "Which authored commands should be VISIBLE while this mode
  is active?"
- **header**: "Commands"
- **multiSelect**: true
- **options**: up to 4 command basenames most likely relevant to the mode's
  intent, plus the implicit "Other" for the rest. If the list is short
  enough (≤4), offer all.

**A9 (structured, multi-select):** likewise for agents:

- **question**: "Which authored agents should be VISIBLE while this mode is
  active?"
- **header**: "Agents"
- **multiSelect**: true
- **options**: up to 4 agent basenames most likely relevant; "Other" carries
  the rest.

An empty selection (the user picks nothing in A8 / A9) means an empty list
in the YAML — the deliberately narrow surface.

#### 3c. Context injection (`command_heuristics`)

This stays prose (open-ended per-command guidance — multiple-choice would
constrain the *content* of each heuristic, which is the whole point).

Ask which slash commands the user wants to shape, and for each one collect:

- **focus** — what should Claude pay attention to when this command runs?
- **bar** — how strict or lenient?
- **behavior** — how should it act differently than the default?
- **scope** — what's in or out of scope?

Note: V2 uses underscore `command_heuristics` (V1 used hyphen
`command-heuristics`). The mode-yaml parser still accepts the hyphen form
for forward-compat, but write the underscore form for new YAMLs.

#### 3d. None / minimal mode

If the user picked "None" in Phase 2.5, the mechanism block can be either
fully absent or:

```yaml
mechanism:
  enabledPlugins: {}
  user_catalog:
    commands: []
    agents: []
```

The mode still shapes Claude via prose-layer injection in any session where
it's active.

---

### Phase 4 — Refine, validate, write

Before writing the file atomically, the user gets one last chance to refine.
This is where the **edit-surface picker** lives.

Show the assembled draft YAML in a fenced block so the user can see exactly
what will be written.

**A13 (structured):** call `AskUserQuestion` to pick how to refine:

- **question**: "How do you want to refine this before writing?"
- **header**: "Refine how"
- **options**:
  1. **Looks good — write it** — accept as drafted and proceed to write.
  2. **Walk through fields** — go through each field with current-value-as-
     default; for each, pick keep / edit. Inline in chat; no external editor.
  3. **Free-form edits** — describe changes ("replace philosophy with…",
     "drop the third constraint") in chat; I'll apply them and re-show
     the whole YAML.

(There is deliberately no "open in editor" option here. The writer's name
validator rejects filenames containing `.` outside the `.yaml` suffix —
`name.yaml.draft` fails validation — so a pre-write draft can't be safely
written. Instead, the file is fully editable AFTER it lands: every field
in `~/.claude/modes/<name>.yaml` is human-editable in any editor, and the
cascade re-reads it on every compile. Phase 5's closing pointer makes this
explicit.)

Branches:
- **Looks good**: proceed to validation and write below.
- **Walk through fields**: iterate field-by-field via `AskUserQuestion`
  (single-select keep/edit per field; on "edit" switch to prose to capture
  the new value, then continue). After every field is processed, re-show
  the final YAML and re-fire A13. The user can keep iterating; the loop is
  user-terminable via "Looks good — write it".
- **Free-form edits**: apply textual edits to the in-memory draft, re-show,
  re-fire A13 — same loop as A4 in Phase 2.

#### Name validation

Validate the proposed name via the validate-mode-name library:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/lib/validate-mode-name.sh check <name>
```

If non-zero, read the stderr message, explain it (reserved token /
forbidden chars / too long / leading-trailing dash), and ask for a new name
in **A11 (open prose)** — name correction is rare and the error message
already tells the user what to fix.

#### Collision check

**A12 (structured):** if `~/.claude/modes/<name>.yaml` already exists, call
`AskUserQuestion`. The non-destructive options are listed first deliberately
so a pick-first-option agent does NOT silently clobber an existing mode.

- **question**: "A mode named `<name>` already exists. What should I do?"
- **header**: "Collision"
- **options**:
  1. **Pick a new name (Recommended)** — abandon this draft, return to name
     choice. Default behavior for an autonomous caller.
  2. **Cancel** — exit the skill without writing.
  3. **Overwrite** — replace the existing file with the new draft. Explicit
     opt-in only; the existing YAML is irreversibly replaced.

#### The write itself

Compose the final YAML. Must include:
- `schema_version: 2`
- `name: <name>` (matches filename)
- `description: <…>` (multiline OK)
- Prose-layer fields (philosophy/scope/lens/constraints) — at least
  philosophy is strongly recommended.
- A `mechanism:` block (may be sparse — only the chosen axes populated).
- An optional **top-level** `disable:` block (sibling of `mechanism:`, NOT
  nested under it — nested `disable:` is silently ignored by the cascade
  engine).
- An optional `command_heuristics:` block.
- **Must not declare `mechanism.hooks`** (R28; the writer rejects).

Write the YAML via the writer library — **never** via raw `cat > path`:

```bash
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

# (optional, TOP LEVEL — sibling of mechanism:)
# disable:
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
    focus: <…>
    bar:   <…>
    behavior: <…>
    scope: <…>
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

If the writer exits non-zero, relay the stderr message; do not fall back to
a direct redirect. That bypasses R28's mechanical enforcement.

On success, confirm: "Mode `<name>` written to `~/.claude/modes/<name>.yaml`."

---

### Phase 5 — Offer atomic set

**A14 (structured):** call `AskUserQuestion`:

- **question**: "Set `<name>` as the active mode on this branch now?"
- **header**: "Activate"
- **options**:
  1. **Yes, set now** — run `/mode:set <name>` on the current branch.
  2. **No — set later** — leave it dormant; user runs `/mode:set <name>`
     manually whenever ready.
  3. **Yes, on a different branch** — switch branches first (or ask which
     branch), then set.

On "Yes, set now" (or "Yes, on a different branch" after the branch switch):
run the underlying script (`bash ${CLAUDE_PLUGIN_ROOT}/lib/set-mode.sh
<name>` or `/mode:set <name>` if directly available from this skill
context). On success, confirm "Mode `<name>` is now active on this branch.
Invoke any slash command to see mode-shaped behavior."

On "No — set later": confirm "Mode `<name>` authored. Set it on any branch
with `/mode:set <name>` whenever ready."

Close with a pointer:

> The mode YAML lives at `~/.claude/modes/<name>.yaml`. Open it in your
> editor any time to tweak prose, enabledPlugins, user_catalog, or
> command_heuristics — every field is human-editable. The plugin re-reads
> it on every cascade compile; no restart required.

Special case: if the user is not inside a git working tree, skip A14
entirely (no branch to set against) and close with: "Mode `<name>`
authored. Set it from a git branch with `/mode:set <name>`."

---

## Anti-patterns to avoid

- **Don't write hooks/env/permissions/mcpServers into ANY cascade YAML.**
  The V2.0 cascade only flows `enabledPlugins`; hooks/env/permissions placed
  in a mode YAML, `_global.yaml`, or `_repo.yaml` are silently dropped and
  never take effect. They belong in `~/.claude/settings.json` (machine-wide)
  or `<repo>/.claude/hooks/hooks.json` (per-repo). Repeat the Phase 2.5
  redirect if the user circles back.
- **Don't write `disable:` nested under `mechanism:`.** It must be a
  TOP-LEVEL key (sibling of `mechanism:`); a nested `disable:` is silently
  ignored by the cascade engine. (Round-7 contract bug — locked by a
  regression test.)
- **Don't bypass `lib/write-mode-yaml.sh`** with a raw redirect into
  `~/.claude/modes/<name>.yaml`. That defeats R28's mechanical check.
- **Don't over-AskUserQuestion.** The skill's strength is thinking with the
  user; replacing every prompt with a menu turns it into a form-filler.
  Use AskUserQuestion where the answer is from a fixed small set (archetypes,
  axes, plugin lists, refinement methods, set-now decisions); stay prose
  where the question is "tell me what you're thinking."
- **Don't propose `disable:` blocks casually.** They subtract privilege
  from the cascade total; the user should explicitly want this.
- **Don't over-populate.** A minimal mode (prose layer only) is often the
  right answer for a new working stance. Add mechanism axes as patterns
  crystallize.
