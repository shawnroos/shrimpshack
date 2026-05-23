---
name: mode-suggester
description: >
  Propose a mode switch when the work being asked for mismatches the active
  mode's intent. Use when the model notices a domain mismatch (e.g., a user
  in design mode asks for debugging, or a user in Claude Mode asks for
  visual UI work and a better-fit mode exists). Also use when the user
  explicitly says "should I switch modes?" or invokes /mode-suggester.
  Surfaces 2-3 candidate modes via AskUserQuestion and runs /mode:set on
  accept.
---

# mode-suggester skill

You propose a mode switch when the current task doesn't fit the active mode.
This complements the mode-author skill (which creates new modes) — this
skill *picks among existing modes* and switches to the best fit.

The pattern: the active mode's prose layer (philosophy / scope / constraints
already injected via `<system-reminder>` on every prompt) explicitly tells
you when work falls outside scope. For example, `design.yaml`'s constraints
include: "If the task is genuinely not design (debugging, refactoring,
infra), surface that and ask whether to switch modes." This skill is the
mechanical surface for that surfacing — turning a soft "you should switch"
prompt into a concrete `AskUserQuestion` the user can click to accept.

## Loading the question tool

In Claude Code, `AskUserQuestion` is a deferred tool — its schema is not
loaded at session start. Before firing any question, call `ToolSearch` with
query `select:AskUserQuestion` once, eagerly. The fallback (numbered list
in chat) applies only when the harness genuinely lacks a blocking question
tool — never silently skip the suggestion.

## When to invoke this skill

Three triggers:

1. **The active mode's constraints say so.** The `<system-reminder>` you see
   every prompt contains the active mode's constraints. If any constraint
   has language like "surface a mode-switch if X" or "ask whether to switch
   modes when Y", and the current task matches that condition, invoke this
   skill. The mode is asking you to.

2. **You notice a domain mismatch.** The user's request is plainly outside
   the active mode's scope. Examples:
   - Active mode is `design`; user asks for `compound-engineering`-style
     code review.
   - Active mode is `delivery`; user asks for exploratory spike work that
     belongs in `discovery`.
   - Active mode is Claude Mode (none); user is doing repeated visual /
     interface work and a `design` mode exists.

3. **The user asks directly.** Phrases: "should I switch modes?", "is
   there a better mode for this?", "what modes are available?", or an
   explicit `/mode-suggester` invocation.

When NONE of these triggers fires, do NOT invoke this skill. The active
mode is the user's stated working stance; don't second-guess it because the
work feels slightly off the philosophy. The bar is *mismatch with the
mode's stated scope*, not "I think a different mode would be marginally
better."

## Flow

### Step 1 — enumerate available modes

Read the registry of mode YAMLs at `~/.claude/modes/*.yaml`. Skip framework
files (`_global.yaml`, `_repo.yaml`). For each mode, capture the name and
the description (and optionally philosophy/scope for richer prompting).

```bash
for f in ~/.claude/modes/*.yaml; do
  base=$(basename "$f" .yaml)
  case "$base" in
    _global|_repo) continue ;;
  esac
  # Use the helper: bash lib/mode-yaml.sh field <path> description
  echo "$base|$(bash ${CLAUDE_PLUGIN_ROOT}/lib/mode-yaml.sh field "$f" description 2>/dev/null | head -1)"
done
```

Also note the **currently active** mode via the canonical resolver:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/lib/active-mode.sh name
```

This returns the per-branch override (`<repo>/.claude/modes/<branch>.mode`)
when inside a git repo, falling back to the user-global pointer
(`~/.claude/modes/.last-active-mode`) only when no per-branch state exists.
Do NOT read `.last-active-mode` directly — that bypasses the per-branch
override and produces the wrong "current" mode in any repo where the user
set a different mode per branch (the primary multi-mode use case the plugin
is designed around). Empty output means Claude Mode (no active mode).

Exclude the resolved active mode from the suggestion candidates — no point
suggesting "switch to the mode you're already in."

### Step 2 — pick 2-3 candidates

From the available modes (excluding the active one), pick the 2-3 best
fits for the current task. Use the descriptions you read in Step 1 plus
the task signal from the user's prompt or the work-in-progress context.

If only one or two modes exist beyond the active one, surface those plus
"stay in current mode" / "no mode (Claude Mode)" as the other options.
The AskUserQuestion tool requires 2-4 options.

### Step 3 — surface the suggestion

Call `AskUserQuestion`:

- **question**: "The current work looks more like `<best-fit-mode>` than the
  active `<active-mode>`. Switch?" — or, when triggered by the user's
  direct ask: "Which mode fits this work best?"
- **header**: "Switch mode"
- **options**: 2-4 entries. Always include one "Stay in current mode"
  option so accepting isn't the only path. Lead with the best-fit candidate
  *only if* the mismatch signal is strong; otherwise lead with "Stay in
  current mode" (Recommended) so a pick-first-option agent doesn't switch
  modes against the user's intent.

Example for "user in design mode asks for code refactoring":

- 1. **Switch to `delivery`** — A workflow-stage mode for shipping-quality
  code work. Reopens compound-engineering, code-refactoring, the LSPs.
- 2. **Switch to `discovery`** — A workflow-stage mode for exploratory
  work. Lighter rigor than delivery; same code-friendly catalog.
- 3. **Stay in `design` mode (Recommended on uncertainty)** — keep going;
  treat this as a brief detour rather than a context switch.

### Step 4 — execute the switch

On a switch choice, run the underlying set-mode script:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/lib/set-mode.sh <selected-mode>
```

The script handles the cascade compile, the per-branch `.mode` write, and
the audit log. After it returns success, tell the user:

> Switched to `<new-mode>`. Run `/reload-plugins` to apply the new
> catalog (this drops the previous mode's plugins and loads the new
> mode's set). The `<system-reminder>` on your next prompt will carry
> the new mode's philosophy, scope, and lens.

On "Stay in current mode", confirm briefly:

> Staying in `<active-mode>`. Continue.

### Step 5 — handle the "no mode currently active" case

If the active mode is empty (Claude Mode), the suggestion is about
*entering* a mode rather than switching between modes. The flow is
otherwise identical; the AskUserQuestion stem becomes: "Enter a mode for
this work?" with the candidates as options plus "Stay in Claude Mode" as
the recommended-default.

## Anti-patterns to avoid

- **Don't suggest the active mode as one of the switch candidates.** It's
  the baseline; the user is already there. Always exclude it from the
  options.
- **Don't over-trigger.** A mismatch with the philosophy is a real signal
  but not a hard rule; surface a suggestion only when the work *clearly*
  falls outside the mode's scope (the constraints language is your guide).
  Over-suggesting trains the user to ignore mode-suggester output.
- **Don't switch silently.** Even when the user types something that looks
  unambiguous ("switch to delivery"), still fire the `AskUserQuestion` —
  the user might have meant something else, and the click-to-confirm is a
  trivial cost that prevents wrong switches.
- **Don't propose creating a new mode here.** That's mode-author's job. If
  none of the existing modes fit, say so and point at the mode-author
  skill: "No existing mode fits cleanly. Want to author a new one? Run
  mode-author (say 'create a new mode')."
