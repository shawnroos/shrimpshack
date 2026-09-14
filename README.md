# The Shrimp Shack

Tasty crustacey morsels for Claude by [@shawnroos](https://github.com/shawnroos).

## Plugins

| Plugin | Version | What it does |
|--------|---------|--------------|
| [auto](plugins/auto/) | 0.14.1 | Runs a plan-and-work loop as a state machine. The loop stops on a deterministic exit test, not on a claim of completion. |
| [claude-modes](plugins/claude-modes/) | 0.3.1 | Names a working stance and gives it a plugin catalog. Each mode turns a different set of tools on. |
| [clawcrush](plugins/clawcrush/) | 0.2.0 | Finds and stops zombie processes and leftover files from Claude Code sessions. It selects by owner and liveness, never by age. |
| [comment-cut](plugins/comment-cut/) | 0.4.0 | Removes comment bloat from a branch and keeps the comments that carry a reason. It proves that only comments changed. |
| [lint-router](plugins/lint-router/) | 0.2.0 | Picks the linters to run from who the work is for. It matches on the git origin or on marker files. |
| [multi-slice-review](plugins/multi-slice-review/) | 0.1.0 | Reviews a change too large for one reviewer. It cuts the change into slices and gives each slice its own lens. |
| [nerd](plugins/nerd/) | 0.1.2 | Researches a codebase without supervision. It finds tunable values, runs experiments in worktrees, and reports what to keep or change. |
| [reflect](plugins/reflect/) | 0.6.1 | Stores memories and documents, and searches them with QMD. It keeps the index small enough to load every session. |
| [spawn](plugins/spawn/) | 0.5.0 | Runs Claude on any model the local Superagent Gateway serves, across five surfaces. A second model reads new material best. |
| [spinoff](plugins/spinoff/) | 0.10.3 | Moves the topic just discussed into its own worktree and its own briefed session. The handoff links back to the source session. |
| [stackup](plugins/stackup/) | 0.1.0 | Asks whether work ships as a stack of dependent pull requests. It asks twice, while the answer is still cheap to act on. |
| [token-bridge](plugins/token-bridge/) | 2.0.0 | Connects the CSS design tokens of one codebase to one Paper file. A config file states the mapping. |
| [work](plugins/work/) | 0.2.0 | Binds a git worktree to a Linear issue. The plugin resolves every fact it derives, and asks when the answer is a choice. |

## Install

```bash
claude plugin add-marketplace https://github.com/shawnroos/shrimpshack.git
claude plugin install work
```

Replace `work` with the name of any plugin in the table. The marketplace file
omits `stackup`, so that one installs from the repository only.

## What these have in common

Each plugin holds one opinion, and each opinion came from a failure.

- A check that never ran looks exactly like a check that found nothing. Several
  of these plugins verify their own completion before they report a pass.
- A green test proves something about the test, not about the code. To prove an
  assertion, break the code and watch the test go red.
- A gate that lists what it permits is incomplete on the day somebody adds a
  file. Prefer a rule that enrols new files by itself.
- Context is the expensive thing to lose. A handoff carries the decisions and
  the dead ends, not only the branch name.
