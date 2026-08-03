# spinoff

Fork the current thread of work into its own place.

When a topic, plan, or idea you've been discussing turns out to be its own batch
of work, spin it into a **fresh git worktree** with a **new, already-briefed
Claude session** — so the current session stays focused and the new one picks up
exactly where this one left off.

Three flavours:

- **`/start-session`** (and the `/start` alias) — a new **tab** where you are now.
- **`/start-split`** — a **split beside the pane you're in**, in the same tab.
- **`/start-workspace`** — a **brand-new workspace**, two panes: briefed Claude on
  the left, the handoff rendered on the right.

It launches through whichever terminal you're actually in — **herdr**, **cmux** or
**ghostty**, auto-detected, no flag needed.

The mechanical work (worktree, handoff, the launch, readiness polling) runs in a
**background agent**, so it doesn't eat the context of the session you ran it from.

## Install

```
/plugin marketplace add shawnroos/shrimpshack
/plugin install spinoff@shrimpshack
```

## Use

It's **command-invoked only** — it never fires on its own from how you phrase
something. Run:

```
/start-session              # new tab where you are (alias: /start)
/start-split                # split beside the current pane
/start-split left           # …on the left instead
/start-workspace            # brand-new two-pane workspace
/start-session crop snapping  # seeds the feature name + handoff focus
```

What happens:
1. Claude synthesizes a **handoff** from the conversation (goal, key decisions,
   open questions, starting point).
2. You're asked the **branch base** — current HEAD (carries context, recommended)
   or `develop` (clean-room). This is the one question, and it's asked before the
   work is backgrounded.
3. Claude resolves this session's transcript + cwd, then **dispatches a background
   agent** to run the bundled script, which:
   - creates the worktree at `<repo>/worktrees/<name>` on `<prefix>/<name>`,
   - writes `docs/handoff.md` with a link back to the originating session
     (transcript path + `claude -r <uuid>` resume one-liner),
   - carries over recent `docs/` plan/brainstorm files,
   - **launches Claude with the brief already attached** — as its opening prompt on
     the launch command, so the new session is briefed the moment it exists. It
     lands in a new tab (`/start-session`), a split beside your pane
     (`/start-split`), or a new two-pane workspace with the handoff alongside
     (`/start-workspace`).
4. Claude relays the summary; you continue in the new tab, split or workspace.

## Requirements

- A terminal it can drive: [herdr](https://herdr.dev), [cmux](https://cmux.io), or
  [Ghostty](https://ghostty.org) on macOS. Without one the script still creates the
  worktree + handoff and prints the manual `cd … && claude` command.
- A git repo. Worktrees nest under `<repo>/worktrees/`.

Two things to know about the Ghostty path specifically, since it's driven by
AppleScript rather than a CLI:

- **macOS will ask for Automation permission** the first time. If you deny it, grant
  it in System Settings → Privacy & Security → Automation before trying again — macOS
  remembers a denial, so the script won't retry into it.
- **Claude's startup prompts aren't auto-answered.** A fresh worktree path makes
  Claude ask things like "N new MCP servers found in this project"; herdr and cmux read
  the screen and answer them, Ghostty has no way to read a surface at all, so the new
  session waits on the prompt and may start without its MCP servers. The brief itself
  is unaffected.

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
