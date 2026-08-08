---
title: "A command and a skill sharing a name means the skill never loads"
date: 2026-08-07
module: plugins
problem_type: architecture_pattern
component: tooling
severity: high
category: architecture-patterns
tags:
  - claude-code
  - plugins
  - skills
  - commands
  - naming
applies_when:
  - "authoring a Claude Code plugin that ships both commands/ and skills/"
  - "a command body tells the caller to invoke a skill"
  - "a plugin's always-on token cost looks higher than what it actually delivers"
---

## Context

A plugin in this repo shipped three commands (`lens`, `launch`, `status`) and three
skills with **the same three names**. Every capability worked, so nothing looked
wrong. It was only when the surfaces were invoked for the first time — after the
scripts had already been verified by running them directly — that the fault
appeared: the `SKILL.md` files had never loaded, in any invocation.

## Guidance

**Do not give a command and a skill the same name.** When they collide, the
command wins and the skill is unreachable by that name.

The proof is mechanical rather than inferential: invoking `Skill(<plugin>:lens)`
returned text with the invocation's own arguments appended at the bottom. That is
`$ARGUMENTS` expansion — a **command-only** feature. The returned body also matched
the command file verbatim (then `plugins/spawn/commands/lens.md`, deleted by this
very fix — see the rename below). Two sessions, in two worktrees, reached the same
result independently.

The second-order failure is worse than the first. Each command body said:

> Use the Skill tool to invoke: `<plugin>:lens`

which resolves back to the command. An agent following that instruction literally
goes in a circle. It only *appeared* to work because each command also named the
script path, and that was enough to finish the job — so the richer guidance was
skipped silently, with no error and no missing-file warning.

Two shapes avoid this:

- **Different names.** Name commands for the verb and the skill for the thing —
  `start-session` / `start-split` / `start-workspace` as commands, `spinoff` as the
  skill. A sibling plugin in this repo already did this deliberately.
- **One layer.** Ship commands whose bodies carry their own instructions, or ship
  skills only. A command that exists solely to redirect costs ~50 always-on tokens
  to point at something it shadows.

If both layers are kept, the skill needs a guard in its `description` saying it is
invoked by name only and should not self-trigger from conversational phrasing —
otherwise the two surfaces compete for the same intent.

## Why This Matters

The cost is invisible in exactly the way that matters. Measured on a real install
of the affected plugin: **~561 always-on tokens per session**, of which ~420 were
the three skills — paying, every session, to advertise guidance that could not be
reached. The skills carried the exit-code table, the untrusted-output rules and the
spill handling; all of it was bypassed.

It bit concretely. One command body said "say what a gateway-pointed session does
not have — the skill lists those." That list lived in the skill, under a heading of
exactly that name, and was never in context when the command ran.

The failure mode generalises past this repo: **a redirect between two surfaces is
only as good as the name resolution underneath it,** and name resolution is not
something a plugin author can see failing. There is no error. The plugin behaves
plausibly. The only way this was found was invoking every surface and checking what
actually came back.

## When to Apply

- Before shipping any plugin that has both a `commands/` and a `skills/` directory
- When auditing a plugin's always-on token cost — check that what is advertised is
  reachable
- When a command body redirects anywhere, ask what happens if that name resolves to
  the command itself

## Examples

**The collision, as shipped** (paths relative to a plugin root, e.g.
`plugins/<name>/`):

```
commands/lens.md      <- wins
skills/lens/SKILL.md  <- never loads
```

```markdown
<!-- commands/lens.md -->
Use the Skill tool to invoke: `<plugin>:lens`
The skill owns the details: it runs ${CLAUDE_PLUGIN_ROOT}/lib/lens.sh ...
$ARGUMENTS
```

**How to tell it is happening.** Invoke the skill by name and look at what comes
back. If the text ends with your own invocation arguments, you got the command —
`$ARGUMENTS` does not exist in skills.

**The fix applied here** (PR #32) — rename the commands, keep the skills, and make
each command body self-sufficient rather than a redirect. Under the plugin root:

```
commands/agent.md  bg-agent.md  session.md  report.md   <- no name collides
skills/lens/  launch/  status/                          <- still reachable by name
```

with a guard added to each skill's description:

```yaml
description: >
  Invoked by name only (via the Skill tool, or by a person naming this skill) —
  do NOT trigger this skill from conversational phrasing on your own;
  `/<plugin>:agent` is the conversational front door and carries its own instructions.
```

A test pins it so the collision cannot return:

```bash
# no command filename may match any skill directory name
# (enumerated dynamically, with a floor assertion so two empty globs
#  cannot pass the check vacuously)
```

**Note on scope:** this was verified for explicit invocation by name. Autonomous,
description-matched skill selection is a separate path and was not tested here.
