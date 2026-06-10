---
name: cmux-spinoff
description: >-
  Command-invoked only (via the /start slash command) — do NOT trigger this skill
  from conversational phrasing on your own. It forks the current thread of work into
  its own place: takes the topic/plan/idea just discussed and moves it into a fresh
  git worktree with a new, already-briefed Claude session in a new cmux tab, so this
  session stays focused and the new one picks up the context. Branches a worktree
  (from current HEAD or develop), writes a handoff doc linking back to this session's
  transcript, carries over recent plan/brainstorm docs, opens a new tab on the
  left-hand agent surface of the current cmux workspace, and boots a briefed Claude
  there. Only run when the user explicitly invokes /start — if they merely describe
  wanting to fork work without running the command, suggest /start rather than acting.
---

# cmux Spinoff

**Invoked only via `/start`.** This skill has real side effects (creates a
worktree, opens a tab, launches a Claude session) so it runs only on the explicit
`/start` command — never auto-triggered from how the user happens to phrase
something. If the user describes wanting to fork work but hasn't run `/start`,
point them to it rather than doing the spinoff.

Turn "what we just figured out" into its own parallel workstream: a fresh
worktree + a fresh Claude session in a new cmux tab, with a handoff doc that lets
the new session pick up exactly where this one left off.

This exists because the most expensive thing lost between sessions is *context* —
the why, the dead-ends, the decisions. A spinoff that just makes a branch loses
all of that. So the heart of this skill is writing a genuinely useful handoff,
not the mechanical git/cmux plumbing (which the bundled script handles).

## The workflow at a glance

1. **Synthesize the handoff** (you do this — it's the part only you can do well).
2. **Confirm the branch base** with Shawn (one quick question).
3. **Run the script** — it creates the worktree, writes the handoff + carries
   docs, opens the cmux tab, and launches+briefs Claude.
4. **Confirm** what was created and where.

## Step 1 — Synthesize the handoff (do this first, before any commands)

The new Claude wakes up blind. Your job is to brief it like you'd brief a
teammate taking over: what we're doing, why, what's decided, what's still open,
and where to look. Write this to a temp file you'll pass to the script.

Draft a markdown handoff with these sections (skip any that genuinely don't
apply — don't pad):

```markdown
# Spinoff: <short title of this workstream>

## Goal
<1–3 sentences: what this batch of work is meant to achieve.>

## Why now / context
<What in the current conversation prompted spinning this off. The motivating
problem, not just the task.>

## Key decisions already made
<Bulleted. Each decision + the one-line reason. This is the highest-value
section — it's what's most expensive to rediscover.>

## Open questions / not yet decided
<What the new session will need to resolve. Be honest about unknowns.>

## Starting point
<Where to look first: files, tickets, the carried-over docs. Concrete paths.>

## Source session
<The script fills this in — leave a placeholder line `<!-- SESSION -->`.>
```

Write it to `/tmp/cmux-spinoff-handoff.md`. Keep it tight and real — a handoff
that reads like genuine working notes beats a padded template every time.

## Step 2 — Confirm the branch base

Ask Shawn where the new worktree should branch from. **Recommend branching off
the current HEAD** (carries the in-progress context that motivated the spinoff),
but offer `develop` for a genuinely clean start. One question, then proceed —
don't belabor it.

Resolve his answer to a concrete base ref:
- "current" / current HEAD → use the current branch name (the script defaults to this)
- "develop" / clean → pass `--base origin/develop` (the script fetches it fresh)

## Step 3 — Run the spinoff script

The script does everything mechanical and is safe to read first if you want to
see exactly what it'll do: it lives at
`${CLAUDE_PLUGIN_ROOT}/skills/cmux-spinoff/scripts/spinoff.sh`.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/cmux-spinoff/scripts/spinoff.sh" \
  --name "<kebab-feature-name>" \
  --handoff /tmp/cmux-spinoff-handoff.md \
  [--base origin/develop] \
  [--branch-prefix feature]      # default: feature/
```

Pick `--name` from the workstream's topic (kebab-case, e.g. `crop-snapping`,
`ai-audio-defaults`). It becomes both the worktree dir name and the branch
suffix.

What the script does, in order (it prints each step):
1. Resolves the repo root, the current session transcript, and the worktree path
   (`<repo>/worktrees/<name>` — this repo's nested convention).
2. Creates the worktree on a new branch (`<prefix>/<name>`) from the chosen base.
3. Runs an optional per-repo bootstrap if `SPINOFF_BOOTSTRAP_CMD` is set in the
   environment (e.g. `pnpm build-config:stage` for a repo that needs a generated
   env file in a fresh worktree). Non-fatal; skipped if the var is unset.
4. Writes the handoff to `<worktree>/docs/handoff.md`, substituting the real
   session transcript path + a `claude -r <uuid>` resume one-liner into the
   `<!-- SESSION -->` placeholder.
5. Copies recent `docs/` plan/brainstorm/notes files (modified in the last ~6h,
   matching `*plan*`, `*brainstorm*`, `*requirements*`, `*notes*`) into the new
   worktree's `docs/` so the new session has the supporting material.
6. Finds the **left-hand agent pane** of the current cmux workspace (the pane
   holding terminal surfaces, not the markdown/browser pane), opens a **new
   terminal surface** there titled with the feature name, `cd`s into the
   worktree, and launches `claude`.
7. Sends a kickoff message to the new Claude: read `docs/handoff.md` and get
   oriented.

The script prints the worktree path, branch, new surface ref, and transcript
link on success. Relay those to Shawn.

## Step 4 — Confirm

Tell Shawn concisely: branch name, worktree path, that a new briefed Claude tab
is open on the left surface, and that the handoff links back to this session. He
then continues in the new tab.

## When the script can't do something

- **Not inside cmux** (`CMUX_WORKSPACE_ID` unset): the script still creates the
  worktree + handoff and prints the manual `cd <worktree> && claude` command, so
  the spinoff isn't lost — only the tab automation is skipped. Tell Shawn.
- **Not in a git repo / dirty index blocks worktree add**: the script reports the
  git error verbatim. Don't paper over it — surface it.
- **Ambiguous left pane** (e.g. a single-pane workspace): the script falls back to
  adding the surface to the focused pane and notes it. That's usually fine.

## Notes on conventions (why the script does what it does)

- Worktree path `<repo>/worktrees/<name>` matches how this repo already nests
  worktrees; don't relocate to `~/projects/<repo>/worktrees` for repos that nest.
- Branch prefixes follow Shawn's convention: `feature/` (default), `task/`,
  `bugfix/`, `hotfix/`. Pass `--branch-prefix` to override.
- The session link is a **local transcript path + resume one-liner**, never an
  upload — recoverable offline, and the resume command is cwd-relative so it's
  given as an absolute `cd … && claude -r <uuid>`.
- Don't `git add -A` anywhere; the script never stages broadly.
