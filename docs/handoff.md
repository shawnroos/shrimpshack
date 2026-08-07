# Spinoff: gateway plugin command & skill surfaces (AX/UX)

> This handoff is directional — author intent and a starting point, not a spec.
> The code and tests are the source of truth; validate against them and refine.

## Goal

Make the gateway plugin's six surfaces — three commands (`/gateway:lens`,
`/gateway:launch`, `/gateway:status`) and three skills (`lens`, `launch`,
`status`) — genuinely good to use, for both the humans who type a slash command
and the agents that shell out to `lib/*.sh`. The plumbing underneath is verified
and solid; this is about the layer people actually touch.

## Why now / context

The plugin (PR #30, `feature/gateway-plugin`) has been through six reviewers,
seventeen fixes and a full manual verification against the real gateway. Every
capability works. But the verification pass ended on an uncomfortable fact:

**None of the six surfaces has ever been invoked.** Everything was exercised by
running `lib/*.sh` directly by absolute path. The plugin was finally installed at
the end of that session, and `Skill(gateway:status)` returned `Unknown skill` —
plugins load at session start, so a mid-session install can't be tested. The
scripts are proven; the surfaces are not.

So this workstream starts from a real gap, not a polish impulse. **First
concrete task: get the plugin loaded (fresh session or `/reload-plugins`) and
actually drive all six.** Everything below is a hypothesis until that happens.

## Key decisions already made

Carry these; ids refer to `docs/plans/2026-08-06-001-feat-gateway-plugin-plan.md`.

- **The script IS the agent surface, not the skill (KTD1 / R-design).**
  `skills/lens/SKILL.md` says so in its own text: the primary consumer runs with
  `allowed-tools: Bash, Read` and *cannot invoke a skill or a slash command at
  all*. This is the central tension of this workstream — if the main consumer
  can't load the skill, what is the skill for, and what has to live elsewhere?
- **The answer that worked: put the contract IN THE DATA.** The untrusted-output
  rule lived only in SKILL.md, unreachable by the very consumer that needed it.
  The fix added constant `content_trust` / `content_notice` fields to the lens's
  JSON. Verified: a Bash-only subagent, unable to read SKILL.md, correctly
  derived the whole trust boundary from the JSON alone and explained which field
  told it. **Treat that as the template** — for any affordance, ask whether it
  belongs in-band rather than in a document.
- **The exit enum is contract-frozen (KTD2):** 0, 2, 3, 4, 5, 6, 7. New failure
  classes go in the `error` field, never a new code. Precedent: `rate_limited`,
  `context_overflow`, and the two added this session, `no_text_truncated` /
  `no_text_in_response`.
- **Error messages should name the remedy.** `no_text_truncated` says "raise
  --max-tokens and retry"; the two values are split precisely because the remedy
  differs. Extend that standard, don't regress it.
- **KD2/R7: no spend logic, and a lint enforces it.** The lens source may not
  contain `spend|budget|cost|quota|dollar|usd|price`. It caught a message that
  said "token budget" — the wording changed, not the lint. Any new copy has to
  respect that vocabulary.
- **KD3: launch prints a handle, not a terminal.** Verified byte-exact: the
  printed attach command re-reads the token from config at attach time and never
  carries its value.

## Measured facts worth designing against

Real numbers from `claude plugin details gateway` on a verified install:

- **~561 tokens always-on, added to every session.** Skills ~140 each, commands
  ~50 each.
- **On-invoke:** lens ~2.4k, launch ~2.2k, status ~1.7k.
- `plugin details` counts commands and skills together under "Skills" — the
  `Skills (6)` line for three skills is a display convention, **not** duplicate
  registration (spinoff shows 5 = 4 commands + 1 skill). Don't "fix" it.
- **Installed path is `~/.claude/plugins/cache/<mkt>/gateway/<version>/…`** —
  note the version component; `~/.claude/plugins/marketplaces/<mkt>/` was empty.

## Open questions / not yet decided

1. **Is ~561 always-on tokens the right price** for three skills and three
   commands? Descriptions are the lever. What would a tighter surface cost, and
   what discoverability would it give up?
2. **Commands and skills share names** (`lens`/`lens`, etc.), and each command is
   a thin wrapper whose body says "Use the Skill tool to invoke: gateway:lens".
   Spinoff deliberately does the opposite — commands `start-session`/`start-split`
   /`start-workspace`, skill `spinoff`. Is the collision good (one obvious name)
   or confusing (two things, one name, ~50 tokens for a redirect)?
3. **Should `lens.sh` expose `--describe`?** Open P3 from the agent-native
   reviewer: `--help` prints usage to *stderr* and exits **2** with
   `detail: "help requested"`, so a caller branching on exit code reads help as a
   failure. A `--describe` emitting flags, the exit enum and response fields at
   exit 0 would let a consumer reconcile at runtime instead of hard-coding.
4. **The allowlist is the only silent failure in the plugin.** A wrong rule
   doesn't error — the fan-out parks on a permission prompt forever. The path is
   version-pinned, so it also breaks silently on upgrade. Is there a better shape
   (a stable wrapper script, a symlink, documented convention)? This is squarely
   AX work and arguably the highest-value item here.
5. **Prompt assembly is undocumented.** A toolless lens can't fetch anything, so
   the caller's single user message is the model's entire world. Nothing tells a
   consumer that, or what a good assembled prompt looks like. (Open P3.)
6. **Foreign-plugin consumers.** `${CLAUDE_PLUGIN_ROOT}` resolves to the *calling*
   plugin's root, so the documented invocation doesn't work from another plugin.
   R9 added a resolution recipe; the ergonomics are still poor.
7. **What does `/gateway:status` show a human?** It currently returns the same
   JSON an agent gets. A human reading 18 aliases and a drift block as raw JSON
   is not obviously the right experience.

## Scope boundary — read this

A **separate spinoff is already running** on `feature/gateway-setup`: install
flow, secure OpenRouter token capture, and per-harness config for Claude Code,
Codex and opencode. **A `/gateway:setup` command belongs to that workstream, not
this one.** This one is about the surfaces that already exist. Coordinate rather
than duplicate — check that branch before designing anything install-shaped.

## Starting point

- `plugins/gateway/commands/{lens,launch,status}.md` — the human front doors
- `plugins/gateway/skills/{lens,launch,status}/SKILL.md` — the loaded guidance
- `plugins/gateway/README.md` — source × sink matrix, allowlist section (rewritten
  this session after the documented path turned out not to exist)
- `plugins/gateway/lib/lens.sh` — the real agent surface; see the emit sites for
  the `content_trust` precedent
- `docs/residual-review-findings/feature-gateway-plugin.md` — open P3s, including
  `--describe` and prompt assembly, plus the reviewer-independence caveat
- Comparison: `plugins/spinoff/` and `plugins/multi-slice-review/` — sibling
  plugins in this repo with different command/skill naming conventions

## Base and concurrency

Branched from **`feature/gateway-plugin` @ 5c9f0d0** — `origin/main` has **zero**
`plugins/gateway/` files, so there would be no surfaces to improve. That base is
unmerged (PR #30 open); rebase when it lands.

## Recommended next step

**First, load the plugin and drive all six surfaces** — that is the missing input,
and several questions above will answer themselves once you have. Then
`/ce-brainstorm`: the goal here is a quality bar rather than a defined change,
questions 1–4 are genuinely open with real trade-offs, and the token-cost and
naming decisions shape everything downstream. Planning before using the surfaces
would be planning blind.

## Source session

Transcript: `/Users/shawnroos/.claude/projects/-Users-shawnroos-projects-shrimpshack-worktrees-gateway-plugin/a518d741-a626-447a-9b77-dbef6ce6c59d.jsonl`
Resume:     `cd /Users/shawnroos/projects/shrimpshack/worktrees/gateway-plugin && claude -r a518d741-a626-447a-9b77-dbef6ce6c59d`
