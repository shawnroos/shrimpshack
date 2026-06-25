# reflect

A QMD-backed **memory + document store** for Claude Code.

Claude's memory lives in `MEMORY.md`, which the harness loads into every session — and silently truncates past ~25KB / 200 lines. As memory grows, the tail goes invisible. Separately, the documents agentic work generates (brainstorms, handoffs, solutions) scatter across repos and vanish when worktrees are cleaned up.

`reflect` fixes both by changing the model: **files on disk are the source of truth, a local search engine (QMD) is the retrieval layer, and the loaded index is just a budgeted table of contents.**

## What it does

- **Budgeted pointer index** — `MEMORY.md` becomes one concise line per memory, always under the load limit. The verbose detail moves into the body files, where QMD can search it. No more silent truncation.
- **Proactive recall** — once per session, on your first prompt, a hook surfaces the most relevant memory bodies via fast lexical search (`qmd search`, ~0.25s). Fail-safe: it never blocks the prompt and exits cleanly on any error.
- **Document store** — `/reflect` captures durable docs into a type-segmented `~/.claude/doc-store/`, indexed by per-type QMD collections, **before** worktrees are cleaned up.
- **Graceful degradation** — with no `qmd` installed, nothing breaks: the budgeted index still loads and bodies are read by file pointer. Only search-based recall is dormant, and it lights up on its own once `qmd` is installed.

## Install

From the `shrimpshack` marketplace:

```
/plugin marketplace add shawnroos/shrimpshack
/plugin install reflect@shrimpshack
```

Enabling the plugin wires its hooks automatically (seeded recall + the reflect triggers). Hooks are additive and fail-safe.

## Opt-in setup

The hooks turn on automatically, but the **invasive one-time edits are opt-in** — the plugin won't rewrite your personal files behind your back. When you're ready:

```
/reflect-setup
```

That migrates an existing `MEMORY.md` to the budgeted format (backing it up first), patches the `## Memory Protocol` section of your `~/.claude/CLAUDE.md` (conservatively — backs up, skips on ambiguous structure), scaffolds the doc-store, and creates the `claude-*` QMD collections. It's idempotent and safe to re-run.

## How `/reflect` works

`/reflect` runs a silent, 10-pass hygiene sweep (manual, or auto-triggered on PR events / ExitPlanMode / all-todos-done): update + merge + prune memories, capture durable docs, keep the index under budget, refresh the QMD collections — all before it cleans up merged worktrees. It logs one line per run to `REFLECT.log` and only ever interrupts you for genuine exceptions.

## Requirements

- [QMD](https://github.com/) (`qmd`) for search-based recall — optional; the plugin degrades gracefully without it.
- `python3` and `bash` (standard on macOS / Linux).

## Tests

```
bash tests/harness.sh
```

Runs entirely against isolated config (temp qmd index + isolated `CLAUDE_HOME`); never touches your live setup.
