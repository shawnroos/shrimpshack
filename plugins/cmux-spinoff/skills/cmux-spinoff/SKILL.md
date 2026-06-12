---
name: cmux-spinoff
description: >-
  Command-invoked only (via /start-session, /start-workspace, or the /start alias)
  — do NOT trigger this skill from conversational phrasing on your own. It forks the
  current thread of work into its own place: takes the topic/plan/idea just discussed
  and moves it into a fresh git worktree with a new, already-briefed Claude session,
  so this session stays focused and the new one picks up the context. Branches a
  worktree (from current HEAD or develop), writes a handoff doc linking back to this
  session's transcript, carries over recent plan/brainstorm docs, and boots a briefed
  Claude — either in a new tab on the current cmux workspace (/start-session) or in a
  brand-new two-pane workspace with the handoff alongside (/start-workspace). The
  mechanical work runs in a background agent so it doesn't consume this session's
  context. Only run when the user explicitly invokes one of the commands — if they
  merely describe wanting to fork work, suggest the command rather than acting.
---

# cmux Spinoff

**Invoked only via `/start-session`, `/start-workspace`, or the `/start` alias.**
This skill has real side effects (creates a worktree, opens a tab or workspace,
launches a Claude session) so it runs only on those explicit commands — never
auto-triggered from how the user happens to phrase something. If the user
describes wanting to fork work but hasn't run a command, point them to one rather
than doing the spinoff.

Turn "what we just figured out" into its own parallel workstream: a fresh
worktree + a fresh Claude session, with a handoff doc that lets the new session
pick up exactly where this one left off.

This exists because the most expensive thing lost between sessions is *context* —
the why, the dead-ends, the decisions. A spinoff that just makes a branch loses
all of that. So the heart of this skill is writing a genuinely useful handoff,
not the mechanical git/cmux plumbing (which the bundled script handles).

## Two commands, one skill

| Command | Where the new Claude lands |
| --- | --- |
| `/start-session` (and the `/start` alias) | A new **tab** on the current cmux workspace's left agent pane — `--target tab`. |
| `/start-workspace` | A **brand-new cmux workspace**: briefed Claude on the left, the handoff markdown rendered in a live-reload viewer on the right — `--target workspace`. |

Both run the same `spinoff.sh`; they differ only in the `--target` they pass.

## The context model: synthesis here, mechanics in the background

Only **handoff synthesis** needs this conversation, so it stays in the main
session. Everything mechanical — running the script, watching ~40 lines of step
output, polling cmux until the new Claude's prompt is ready, verifying the
kickoff submitted — is noise the main session never needs to keep. So after you
synthesize the handoff and get the branch base, you **dispatch a background agent
to run the script** and report back a short summary. The verbose output lives in
the background agent's context; the main session stays light.

## The workflow at a glance

1. **Synthesize the handoff** (you do this in the main session — it's the part
   only you can do well).
2. **Confirm the branch base** with Shawn (one quick question — must happen here,
   in the main session, because the background agent can't prompt him).
3. **Resolve this session's transcript + cwd** so the resume link is correct.
4. **Dispatch a background agent** to run `spinoff.sh` with the resolved args.
5. **Relay** the agent's summary (branch, worktree, tab/workspace, link).

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
don't belabor it. This question stays in the main session: the background agent
that runs the script has no way to ask it.

Resolve his answer to a concrete base ref:
- "current" / current HEAD → use the current branch name (the script defaults to this)
- "develop" / clean → pass `--base origin/develop` (the script fetches it fresh)

## Step 3 — Resolve this session's transcript + cwd

The handoff's "resume where you left off" link must point at **this** session.
The script can auto-discover it, but auto-discovery from inside a background
agent can resolve to the *agent's own* transcript and silently break the link —
so resolve it here in the main session and pass it explicitly.

```bash
# Newest transcript for this session's project dir (project key = cwd, / -> -):
SESSION_CWD="$(pwd)"
PROJ_KEY="$(echo "$SESSION_CWD" | sed 's#/#-#g')"
TRANSCRIPT="$(ls -t "$HOME/.claude/projects/$PROJ_KEY"/*.jsonl 2>/dev/null | head -1)"
```

Prefer `CLAUDE_TRANSCRIPT_PATH` / `CLAUDE_SESSION_ID` when they're set. You'll
pass `--session-transcript "$TRANSCRIPT"` and `--session-cwd "$SESSION_CWD"` to
the script. (If you can't resolve a transcript, omit the flags — the script falls
back to its own discovery; just note the link may be approximate.)

## Step 4 — Dispatch a background agent to run the script

Pick `--name` from the workstream's topic (kebab-case, e.g. `crop-snapping`,
`ai-audio-defaults`). It becomes both the worktree dir name and the branch
suffix. Pick `--target` from the command: `tab` for `/start-session` (or
`/start`), `workspace` for `/start-workspace`.

Dispatch a **background agent** (`Agent` with `run_in_background: true`) whose
entire job is to run the one command below and report back. The agent must NOT
re-synthesize anything or do extra work — it runs the script, waits, and returns
the summary fields.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/cmux-spinoff/scripts/spinoff.sh" \
  --name "<kebab-feature-name>" \
  --handoff /tmp/cmux-spinoff-handoff.md \
  --target <tab|workspace> \
  --session-transcript "<resolved transcript path>" \
  --session-cwd "<resolved cwd>" \
  [--base origin/develop] \
  [--branch-prefix feature]      # default: feature/
```

Tell the background agent to return: the branch, the worktree path, the cmux
tab/workspace + agent surface ref, and the source-session resume line — i.e. the
contents of the script's `✓ Spinoff complete` summary block, plus any `⚠` lines.

The script is safe to read top-to-bottom; it prints each step. What it does, in
order:
1. Resolves the repo root and the worktree path (`<repo>/worktrees/<name>` —
   this repo's nested convention).
2. Creates the worktree on a new branch (`<prefix>/<name>`) from the chosen base.
3. Runs an optional per-repo bootstrap if `SPINOFF_BOOTSTRAP_CMD` is set
   (e.g. `pnpm build-config:stage`). Non-fatal; skipped if unset.
4. Writes the handoff to `<worktree>/docs/handoff.md`, substituting the resolved
   session transcript + `claude -r <uuid>` resume one-liner into `<!-- SESSION -->`.
5. Copies recent `docs/` plan/brainstorm/notes files (modified in the last ~6h)
   into the new worktree's `docs/`.
6. **Launches a briefed Claude**, per `--target`:
   - `tab` — finds the left agent pane of the current workspace, opens a new
     terminal surface there, `cd`s into the worktree, launches `claude`.
   - `workspace` — creates a new cmux workspace (`new-workspace --cwd <worktree>`),
     launches `claude` in its terminal surface, then splits a right pane and opens
     `docs/handoff.md` in cmux's markdown viewer alongside.
7. Waits for the new Claude's input prompt to be ready, then sends the kickoff
   ("read docs/handoff.md and get oriented") and verifies it submitted.

## Step 5 — Relay

Once the background agent reports back, tell Shawn concisely: branch name,
worktree path, whether a tab or a new workspace was opened, that a briefed Claude
is running there, and that the handoff links back to this session. He then
continues in the new tab/workspace.

## When the script can't do something

- **Not inside cmux** (`CMUX_WORKSPACE_ID` unset): the script still creates the
  worktree + handoff and prints the manual `cd <worktree> && claude` command, so
  the spinoff isn't lost — only the tab/workspace automation is skipped. Tell Shawn.
- **Not in a git repo / dirty index blocks worktree add**: the script reports the
  git error verbatim. Don't paper over it — surface it.
- **Ambiguous left pane** (tab target, e.g. a single-pane workspace): the script
  falls back to adding the surface to the focused pane and notes it. Usually fine.
- **Can't parse the new workspace/surface ref** (workspace target): the script
  prints the raw cmux output and degrades gracefully — the worktree + handoff
  still exist. Surface the warning and the manual launch command.
- **Right-pane handoff viewer fails** (workspace target): the briefed Claude is
  still launched on the left; only the markdown viewer is missing. Non-fatal.

## Notes on conventions (why the script does what it does)

- Worktree path `<repo>/worktrees/<name>` matches how this repo already nests
  worktrees; don't relocate to `~/projects/<repo>/worktrees` for repos that nest.
- Branch prefixes follow Shawn's convention: `feature/` (default), `task/`,
  `bugfix/`, `hotfix/`. Pass `--branch-prefix` to override.
- The session link is a **local transcript path + resume one-liner**, never an
  upload — recoverable offline, and the resume command is given as an absolute
  `cd … && claude -r <uuid>`.
- Don't `git add -A` anywhere; the script never stages broadly.
