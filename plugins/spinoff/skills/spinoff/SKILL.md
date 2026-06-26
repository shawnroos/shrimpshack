---
name: spinoff
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

# Spinoff

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

## Recommended next step
<Your read on where this work should enter the compound-engineering flow:
`/ce-brainstorm` if scope/approach is still ambiguous, `/ce-plan` if it's clear
enough to plan, or a more specific CE command if one fits — with a one-line
reason grounded in the goal + open questions above. The new session validates
this against what it reads rather than taking it on faith; it's a strong starting
suggestion, not a directive.>

## Source session
<The script fills this in — leave a placeholder line `<!-- SESSION -->`.>
```

Write it to `/tmp/spinoff-handoff.md`. Keep it tight and real — a handoff
that reads like genuine working notes beats a padded template every time.

## How decisions get made in this skill (engaged agent, escalate on low confidence)

You resolve the spinoff's three knobs — **which repo**, **which base**, **which
workspace** — from a rubric, acting autonomously when you're confident and only
asking Shawn (`AskUserQuestion`) when you genuinely can't tell. The script keeps
deterministic backstops (a helpful failure when no repo resolves, a stale-base
warning), but those are the safety net, not the decision-maker. **All resolution
and any question must happen here, in the main session** — the background agent
that runs the script can't prompt, so a decision deferred to it is a decision lost.

## Step 2 — Resolve the repo and the base

**Repo** — the script roots the worktree in a git repo. The originating `/start`
session's cwd is often *not* inside the target repo (e.g. you're in `~`), so
resolve the intended repo and pass it as `--repo <path>`:
- *Repo rubric:* derive it from the work under discussion / the carried-over
  plan-brainstorm docs / `--session-cwd` when that cwd is itself a git repo. If
  one repo is clearly the subject, pass `--repo` for it. If it's genuinely
  ambiguous, ask (`AskUserQuestion`). When the originating cwd already *is* the
  target repo, `--repo` is optional (the script falls back to cwd).

**Base** — **default to a fresh `origin` base**, not local HEAD. A stale local
`main` silently reproduces old state (this is a real failure mode), so prefer
`--base origin/<default-branch>` (the script fetches it fresh):
- *Base rubric:* resolve the default branch with
  `git -C "$REPO" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@'`
  (fall back to `main`), and pass `--base origin/<that>`. Deviate only with a clear
  reason — e.g. Shawn explicitly wants the in-progress local HEAD carried in, in
  which case omit `--base` (the script defaults to current HEAD). If unsure which
  base is intended, ask.

One light confirmation is fine; don't belabor it. The script's stale-base warning
backstops a local base that turns out to be behind its remote.

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
the script. If you can't resolve a transcript *and you're not passing `--repo`*,
omitting the flags is acceptable — the script falls back to its own discovery;
just note the link may be approximate.

**When you pass `--repo`, these flags are load-bearing — always pass them
(absolute).** Under `--repo` the script's own discovery looks inside the *target*
repo, but the originating session lives outside it, so the fallback would point
the resume link at the wrong project. Resolve the transcript + cwd here and pass
them explicitly whenever `--repo` is set.

## Step 3.5 — Confirm the target workspace (when it differs)

A `--target tab` spinoff opens in the **current** cmux workspace. Usually that's
right — but if the workspace you're in is anchored on a *different* repo than the
one you're forking (`--repo`), the new tab would land somewhere surprising. Catch
that here, before dispatch (the background agent can't ask):

- Determine the current workspace's anchor repo and compare it to the resolved
  `--repo`. **Same repo → proceed silently.** **Different repo, or you can't
  determine it → confirm with Shawn (`AskUserQuestion`)** before launching — this
  is the low-confidence case, so don't proceed silently.
- *How to read the current workspace's repo (execution-time detail):* the current
  workspace is `CMUX_WORKSPACE_ID`; read its primary terminal surface's cwd and run
  `git -C <cwd> rev-parse --show-toplevel`. cmux's `tree` exposes surface/pane refs
  but not cwds directly, so if no clean way to get the cwd exists, treat the repo as
  *undetectable* → confirm (the fail-safe above). Don't block the common
  same-workspace path on a perfect query.
- This is moot for `--target workspace` (a brand-new workspace is the intent).

## Step 4 — Dispatch a background agent to run the script

Pick `--name` from the workstream's topic (kebab-case, e.g. `crop-snapping`,
`ai-audio-defaults`). It becomes both the worktree dir name and the branch
suffix. Pick `--target` from the command: `tab` for `/start-session` (or
`/start`), `workspace` for `/start-workspace`.

Also pass `--label` — the **short display name** for the cmux tab/workspace.
It should capture both the **workspace** (where this forked from) and the **work**,
at a glance, e.g. `slate·crop-snap` or `auto·recipes`. Keep it short (~24 chars):
a short workspace token (usually the repo, abbreviated if long) + a `·`/`/`/`:`
separator + a tight form of the work. If you omit `--label`, the script defaults
to `<repo-basename>/<name>`, which is correct but often longer than ideal — prefer
passing a curated short one.

Dispatch a **background agent** (`Agent` with `run_in_background: true`) whose
entire job is to run the one command below and report back. The agent must NOT
re-synthesize anything or do extra work — it runs the script, waits, and returns
the summary fields.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/spinoff/scripts/spinoff.sh" \
  --name "<kebab-feature-name>" \
  --label "<short workspace·work label>" \
  --handoff /tmp/spinoff-handoff.md \
  --target <tab|workspace> \
  --session-transcript "<resolved transcript path>" \
  --session-cwd "<resolved cwd>" \
  --repo "<resolved target repo path>" \      # when the originating cwd isn't inside it
  --base "origin/<default-branch>" \           # fresh base (Step 2); omit only to carry local HEAD
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
   (read `docs/handoff.md`, get oriented, **then recommend the next
   compound-engineering step** — `/ce-brainstorm` vs `/ce-plan` vs a more
   specific CE command — and wait for direction) and verifies it submitted. The
   tab/workspace is named with `--label`, not the bare `--name`.

## Step 5 — Relay

Once the background agent reports back, tell Shawn concisely: branch name,
worktree path, whether a tab or a new workspace was opened, that a briefed Claude
is running there, and that the handoff links back to this session. He then
continues in the new tab/workspace.

## When the script can't do something

- **Not inside cmux** (`CMUX_WORKSPACE_ID` unset): the script still creates the
  worktree + handoff and prints the manual `cd <worktree> && claude` command, so
  the spinoff isn't lost — only the tab/workspace automation is skipped. Tell Shawn.
- **No repo resolves**: if neither `--repo` nor the cwd lands in a git repo, the
  script fails with a message naming `--repo` — resolve the target repo (Step 2)
  and pass it, don't paper over it.
- **Dirty index blocks worktree add**: the script reports the git error verbatim.
  Surface it.
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
