# cmux-spinoff

Fork the current thread of work into its own place.

When a topic, plan, or idea you've been discussing turns out to be its own batch
of work, `/start` moves it into a **fresh git worktree** with a **new,
already-briefed Claude session** in a **new cmux tab** — so the current session
stays focused and the new one picks up exactly where this one left off.

## Install

```
/plugin marketplace add shawnroos/shrimpshack
/plugin install cmux-spinoff@shrimpshack
```

## Use

It's **command-invoked only** — it never fires on its own from how you phrase
something. Run:

```
/start                      # uses the current conversation's topic
/start crop snapping        # seeds the feature name + handoff focus
```

What happens:
1. Claude synthesizes a **handoff** from the conversation (goal, key decisions,
   open questions, starting point).
2. You're asked the **branch base** — current HEAD (carries context, recommended)
   or `develop` (clean-room).
3. The bundled script:
   - creates the worktree at `<repo>/worktrees/<name>` on `<prefix>/<name>`,
   - writes `docs/handoff.md` with a link back to the originating session
     (transcript path + `claude -r <uuid>` resume one-liner),
   - carries over recent `docs/` plan/brainstorm files,
   - opens a new tab on the **left-hand agent surface** of the current cmux
     workspace, launches Claude there, and sends a "read the handoff" kickoff.
4. You continue in the new tab.

## Requirements

- [cmux](https://cmux.io) (for the tab automation; without it the script still
  creates the worktree + handoff and prints the manual `cd … && claude` command).
- A git repo. Worktrees nest under `<repo>/worktrees/`.

## Optional: per-repo bootstrap

If a fresh worktree needs one-time setup before it can build (generate an env
file, etc.), set `SPINOFF_BOOTSTRAP_CMD` and the script runs it in the new
worktree. Example:

```
export SPINOFF_BOOTSTRAP_CMD='pnpm build-config:stage'
```

## Conventions

- Branch prefixes: `feature/` (default), `task/`, `bugfix/`, `hotfix/` — override
  with `--branch-prefix`.
- The session link is a local transcript path + resume one-liner, never uploaded.
- The script never `git add -A`; it stages nothing broadly.
