---
name: setup-interactive
description: >
  Interactive walkthrough of /mode:setup with confirmation gates at each
  consequential step. Use when the user asks to install claude-modes
  interactively, when they want to preview what setup will move/seed
  before it commits, or when /claude-modes:setup-interactive is invoked.
  Wraps scripts/setup.sh's step functions; does not duplicate shell logic.
---

# setup-interactive skill

You orchestrate `claude-modes` first-time setup with **AskUserQuestion gates
between steps**, so the user previews what each step will do (especially
moves, seeds, and identifier choices) before it commits. The underlying
shell script (`scripts/setup.sh`) is unchanged — this skill sources it and
calls the individual step functions one at a time with confirmation in
between.

The non-interactive path (`/claude-modes:setup`, runs all 10 steps without
questions) stays the default for users who already know what setup does.
This skill is the **discoverable** path for first-time installs.

## Loading the question tool

In Claude Code, `AskUserQuestion` is a deferred tool — its schema is not
loaded at session start. **Before Phase 0**, call `ToolSearch` with query
`select:AskUserQuestion` once, eagerly. The fallback (numbered list in chat)
applies only when the harness genuinely lacks a blocking question tool —
never silently skip a question.

## Architecture

`scripts/setup.sh` carries a `BASH_SOURCE == $0` guard around its `main "$@"`
invocation (the same pattern `lib/cascade-engine.sh` uses for
`cascade_compile`). When the script is **sourced**, the guard is false and
`main` does NOT run — only the function definitions and top-level variable
assignments execute. This skill exploits that: source setup.sh once, then
call each `step_*` function explicitly with `AskUserQuestion` gates between
them.

```bash
PR="${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/claude-modes}"
SETUP="$PR/scripts/setup.sh"

# Define a helper that sources setup.sh in a sub-shell and runs ONE step
# function by name. Each sub-shell re-sources the script (so global
# variables like MODES_DIR, SENTINEL, PRISTINE, SKIP_LIST are fresh and
# read from the current environment), then dispatches to the named function.
# The `|| true` swallows source-time errors so the skill can report them
# explicitly rather than crashing.
__run_step() {
  bash -c "source '$SETUP' >/dev/null 2>&1 || { echo 'setup-interactive: could not source setup.sh at $SETUP' >&2; exit 1; }; $1"
}

# Example:
__run_step "step_presence_check"
__run_step "step_write_sentinel"
__run_step "step_pristine_capture"
# … etc, with AskUserQuestion calls between each as the phases below describe.
```

**Contract:** each `step_*` function from setup.sh is idempotent and
self-contained — calling them individually preserves the same atomic
guarantees as running `main()` end-to-end. The step function names this
skill invokes are: `step_presence_check`, `step_write_sentinel`,
`step_pristine_capture`, `step_generate_global`, `step_move_user_catalog`,
`step_seed_examples`, `step_archive_v1_modes`, `step_create_registry`,
`step_initial_symlink_rebuild`, `step_finalize`. If any of these are
renamed in setup.sh, this skill's `__run_step` calls silently no-op
(the bash -c exits non-zero, caught only by inspection of the next phase's
expected side effects). Future maintainers: keep the names stable, or
update both files together.

## Phased interactive flow

---

### Phase 0 — presence check

Check whether claude-modes is already installed (the same check
`step_presence_check` does):

```bash
[ -f "$HOME/.claude/modes/_global.yaml" ] && \
[ -f "$HOME/.claude/settings.json.pristine" ]
```

If both exist AND no `.setup.in-progress` sentinel:

**S1 (structured):** call `AskUserQuestion`:

- **question**: "claude-modes is already installed on this machine. What
  should the interactive setup do?"
- **header**: "Already installed"
- **options**:
  1. **Cancel — leave as-is** — exit without changes. (Recommended)
  2. **Show status only** — print `/mode:status` and exit.
  3. **Force reinstall (advanced)** — surface a warning that this requires
     manual cleanup first (remove `~/.claude/modes/` + the pristine + restore
     catalog from staging), then stop and tell the user the recovery steps.

Default to **Cancel** if the user picks anything ambiguous. Do not attempt
to force-reinstall from inside this skill — the cleanup is risky enough that
it should be a deliberate manual step (the user has done this before during
the V2 install journey; the procedure is documented in the memory at
`feedback_setup_reinstall_requires_manual_cleanup`, or the user can ask).

If a `.setup.in-progress` sentinel exists (a previous setup crashed mid-
flight), proceed to resume: `setup.sh` is idempotent, so just continue
through the phases — `step_*` functions skip work that's already done.

If NOT installed yet, proceed to Phase 1.

---

### Phase 1 — pristine capture preview

`step_pristine_capture` reads `~/.claude/settings.json`, filters it through
a small allowlist (`enabledPlugins`, `theme`, `statusLine`), and writes a
forensic snapshot to `~/.claude/settings.json.pristine`. The pristine
becomes the baseline `_global.yaml` enabledPlugins.

**S2 (structured):** call `AskUserQuestion`:

- **question**: "How should setup capture your current settings.json as the
  baseline?"
- **header**: "Pristine"
- **options**:
  1. **Use defaults (Recommended)** — capture `enabledPlugins`, `theme`,
     `statusLine` only. This is what setup does today; almost everyone wants
     this.
  2. **Show me what will be captured first** — display the filtered JSON
     before writing it; ask again after the preview.
  3. **Customize the allowlist** — type which keys to capture. Advanced;
     wrong choices can omit settings the cascade needs.

On **Show me**: read `~/.claude/settings.json`, apply the allowlist filter
(Python one-liner), print the result, re-fire S2. On **Customize**: collect
the keys via prose, validate they're real top-level keys in the source
settings.json, then proceed.

Then call:
```bash
__run_step "step_write_sentinel"     # crash-safety marker
__run_step "step_pristine_capture"   # actually write the pristine
```

---

### Phase 2 — plugin baseline preview

`step_generate_global` reads the pristine's `enabledPlugins`, resolves the
current plugin's own identifier (via `resolve_self_identifier`), and writes
`_global.yaml` with the baseline plugin list.

Before calling the step function, build a preview:

```bash
SELF_ID=$(bash -c "source '$PR/lib/cascade-engine.sh' >/dev/null 2>&1; __claude_modes::resolve_self_identifier")
PLUGIN_COUNT=$(python3 -c "
import json
ep = json.load(open('$HOME/.claude/settings.json.pristine')).get('enabledPlugins',{})
print(len(ep))
")
```

**S3 (structured):** call `AskUserQuestion`:

- **question**: "About to generate `_global.yaml` with N plugins (resolved
  claude-modes identifier: `<SELF_ID>`). Proceed?"
- **header**: "Baseline"
- **options**:
  1. **Looks good — generate** — proceed with the resolved identifier and
     full pristine plugin set.
  2. **Show the full plugin list first** — print the N enabledPlugins keys
     and re-ask.
  3. **Override identifier (advanced)** — let the user pick a different
     `claude-modes@<marketplace>` identifier (only useful for testing or
     unusual installs).

The resolver bug we fixed in 0.2.1/0.2.2 made S3's identifier confirmation
much less important in practice (the resolver now reliably returns the real
marketplace id), but keep it surfaced — if the install ever lands somewhere
the resolver can't find the registry entry, the user sees `local-dev` and
can flag it before it bakes into `_global.yaml`.

Then call:
```bash
__run_step "step_generate_global"
```

---

### Phase 3 — user catalog move plan (the most valuable confirmation gate)

`step_move_user_catalog` is the **destructive-ish** step: it physically
moves every `*.md` file in `~/.claude/commands/` and `~/.claude/agents/` to
the user-catalog staging dir, then replaces each with a symlink. Reversible
in principle (via `scripts/unmodes.sh`), but worth previewing before it
commits.

Build a preview:

```bash
COMMANDS=$(find -P "$HOME/.claude/commands" -maxdepth 1 -name '*.md' -type f 2>/dev/null | sort)
AGENTS=$(find -P "$HOME/.claude/agents" -maxdepth 1 -name '*.md' -type f 2>/dev/null | sort)
COMMAND_COUNT=$(printf '%s\n' "$COMMANDS" | grep -c '\.md$' || echo 0)
AGENT_COUNT=$(printf '%s\n' "$AGENTS" | grep -c '\.md$' || echo 0)
```

Print the preview (full lists of basenames, not full paths) so the user
sees exactly what will be moved.

**S5 (structured):** call `AskUserQuestion`:

- **question**: "About to move M commands and N agents into managed staging
  (each gets a symlink back at its original path). Proceed?"
- **header**: "Move catalog"
- **options**:
  1. **Move all (Recommended)** — proceed with the full move. This is the
     normal flow; the symlinks are transparent.
  2. **Pick which to move** — open a multi-select to choose only some files.
     Useful if you have a sensitive file (e.g. `secrets.md`) you don't want
     in managed staging.
  3. **Skip the move** — leave commands/agents in place. The mode user-
     catalog feature won't work until you re-run setup or move files
     manually. Use only if you understand the consequence.
  4. **Cancel setup** — abort the whole install before any move happens.

If **Pick which to move**: present a multi-select `AskUserQuestion` per
category (commands and agents), capped at 4 options per question. For
catalogs >4 items, surface the most-likely-relevant 4 plus "Other" for
free-form additional basenames. Write the picked list to a temp skip-file
that `step_move_user_catalog` reads (it already supports a skip-list at
`~/.claude/modes/.setup-skip-list`).

If **Skip the move**: write all current files to the skip-list so the move
becomes a no-op.

If **Move all**:
```bash
__run_step "step_move_user_catalog"
```

If **Cancel**: print "Setup canceled — no changes made." and exit. The
sentinel from Phase 1 is still in place; offer to clean it up so a future
`/mode:setup` doesn't see a phantom in-progress state.

---

### Phase 4 — seed examples

`step_seed_examples` copies `examples/discovery.yaml` and
`examples/delivery.yaml` into `~/.claude/modes/`. They're the seeded
workflow-stage modes; users can `/mode:set discovery` or `/mode:set
delivery` immediately after setup, or skip them and author their own with
`mode-author`.

**S6 (structured, multi-select):** call `AskUserQuestion`:

- **question**: "Which example modes should setup seed into `~/.claude/modes/`?"
- **header**: "Seed examples"
- **multiSelect**: true
- **options**:
  1. **discovery** — workflow-stage mode for exploration / learning velocity.
  2. **delivery** — workflow-stage mode for shipping quality.
  3. **Skip — I'll author my own** — seeds neither. Use `mode-author` later.

The default `step_seed_examples` seeds both. If the user picks a subset,
write their choice to a skip-list the step honors (or just call the step
and then remove the unwanted seeded files — simpler and idempotent). The
"Skip" option means call no seeding at all.

Then call (whichever subset chosen):
```bash
__run_step "step_seed_examples"
# then optionally rm the ones the user excluded
```

---

### Phase 5 — V1 archive (only if V1 detected)

`step_archive_v1_modes` looks for V1-schema mode YAMLs in `~/.claude/modes/`
and, if found, archives them to `~/.claude/modes/.v1-archive/`. If no V1
modes exist, this step is a no-op.

Check first:
```bash
V1_FOUND=$(ls "$HOME/.claude/modes/" 2>/dev/null | grep -v '^_' | grep '\.yaml$' | while read f; do
  python3 -c "import yaml; d=yaml.safe_load(open('$HOME/.claude/modes/$f')); exit(0 if d.get('schema_version')==1 else 1)" 2>/dev/null && echo "$f"
done)
```

If V1_FOUND is empty: skip Phase 5 silently, proceed to Phase 6.

If V1 files exist:

**S7 (structured):** call `AskUserQuestion`:

- **question**: "Detected N V1-schema modes (incompatible with V2 cascade).
  What should setup do?"
- **header**: "V1 archive"
- **options**:
  1. **Archive — move to `.v1-archive/`** (Recommended) — preserves them
     for reference but takes them out of the active mode set.
  2. **Keep alongside — they'll be invisible to /mode:set** — the cascade
     refuses V1; they'll just sit there unused.
  3. **Cancel setup** — exit; clean up the in-progress sentinel.

Then call (if Archive):
```bash
__run_step "step_archive_v1_modes"
```

---

### Phase 6 — registry + initial symlink topology (no questions)

These two steps are mechanical bookkeeping with no user-facing decisions:

```bash
__run_step "step_create_registry"            # ~/.claude/modes/.installed-repos.txt
__run_step "step_initial_symlink_rebuild"    # initial topology
__run_step "step_finalize"                   # clear the in-progress sentinel
```

Print a short summary: "Setup complete (M commands, N agents staged,
K modes seeded)."

---

### Phase 7 — set a mode now?

The mode-author skill closes with the same question (A14). This skill
mirrors it for the post-setup case.

**S8 (structured):** call `AskUserQuestion`:

- **question**: "Set an active mode on this branch now?"
- **header**: "Activate"
- **options** (the first two only appear if seeded in Phase 4):
  1. **Set `discovery`** — for exploration / learning velocity work.
  2. **Set `delivery`** — for shipping-quality work.
  3. **Skip — stay in Claude Mode** — no active mode; defaults.
  4. **Author a new mode** — switch to the `mode-author` skill.

On **Set discovery/delivery**:
```bash
bash "$PR/lib/set-mode.sh" discovery   # or delivery
```

On **Author a new mode**: tell the user "Switching to mode-author. Type
your intent and I'll walk you through it." Then load the `mode-author`
skill (the harness will pick it up if its trigger phrase is detected).

Close with:

> claude-modes is installed. `/mode:status` shows the active mode and
> compiled cascade; `/mode:registry` lists all available modes;
> `/mode:set <name>` activates one on the current branch.

---

## Anti-patterns to avoid

- **Don't duplicate shell logic.** The step functions in `setup.sh` are the
  source of truth. This skill calls them; it does not reimplement them.
- **Don't skip the move-plan preview (Phase 3).** It's the most consequential
  step and the one users are most surprised by. Even if the user picked
  "Move all (Recommended)", they should see what will be moved first.
- **Don't write to `~/.claude/modes/` directly.** Use the step functions
  (they're atomic + R28-safe); raw redirects bypass the writer's invariants.
- **Don't force-reinstall from inside this skill.** If S1 surfaces an
  already-installed state, default to Cancel and let the user do the manual
  cleanup deliberately. The procedure is risky and irreversible if done wrong
  (the cascade staging holds your real command/agent files).
