# Nerd Plugin Feedback

Append-only collection of feedback from agents that used (or considered using) the nerd plugin. The point is **pattern recognition over time**, not isolated bug reports.

## How to add an entry

One file per signal — not per session. A single session post-mortem often contains multiple distinct signals (sequencing mistakes, surface gaps, overlap with other tools); splitting them by signal lets us aggregate later. Multiple files can share the same `session_id:` when they come from one transcript.

Filename: `YYYY-MM-DD-short-slug.md`

## Frontmatter schema

```yaml
---
date: YYYY-MM-DD
source_agent: claude | codex | cursor | other
session_id: <uuid if available>          # Claude Code session UUID, lets us re-read the transcript
signal_type: <one of the types below>
idea_tag: <improvement-slug | new-pattern>   # optional — which proposed improvement this signal supports/refutes/extends
tags: [free-form, kebab-case]
related_commands: [/nerd:nerd, /nerd-this, ...]
outcome: invoked | not-invoked | partial | abandoned
---
```

`idea_tag:` links a signal to a candidate improvement so the dir can be re-tallied by lever during ideation passes. Use an existing improvement slug, or `new-pattern` when the signal fits none. It's optional — only add it when a signal clearly bears on a known proposal. Current slugs in use: `reposition-execute-any-falsifiable-experiment`, `harness-aware-experimentable-predicate`, `instrument-inversion`, `hypothesis-brief-sweep-of-one`, `parallel-routing-nudge`.

## Signal types

Use exactly one per entry. Add new types here as patterns emerge — don't invent ad-hoc ones in individual files.

- **sequencing-mistake** — agent recognized nerd was the right tool but routed elsewhere due to goal-sequencing or upstream work
- **prereq-blocked** — agent wanted to invoke nerd but a dependency (harness, data, instrument) was not ready
- **surface-gap** — nerd's existing surface doesn't cover a use case that fits its shape (e.g. missing mode, missing predicate, missing input format)
- **tool-overlap** — nerd's role overlaps with another command (e.g. `/ce-debug`) and the agent had to pick one, dropping the other
- **positioning** — nerd's docs/description framed it in a way that caused the agent to not consider it
- **invocation-friction** — nerd was the right tool but the cost of dispatching it was higher than the cost of doing the work directly
- **execution-defect** — nerd was invoked and produced a wrong/inconclusive/broken result

## Body structure

Keep it minimal. Two sections:

```markdown
## What happened
[agent's words, verbatim — don't paraphrase, paraphrase loses signal]

## What would have helped
[agent's suggestion if given, verbatim. If none given, leave blank.]
```

Resist adding synthesis or counter-arguments in individual entries. Patterns emerge from raw signal across many entries, not from interpretation of any one.

## When to read this

- Before making changes to nerd's invocation surface, agents, or routing logic
- During `/ce-brainstorm` on nerd improvements
- When deciding whether a one-off complaint is worth acting on (search for related entries first)

## Using session_id for deeper context

The `session_id:` in frontmatter is the stable handle back to the full conversation that produced the feedback. When an entry summarizes the agent's point but you need the surrounding technical context — what files it had open, what errors it saw, what failed approaches preceded the insight — pull the transcript by ID rather than trying to reconstruct from the summary.

Two ways to read a session by ID:

- **`@ce-session-historian`** (compound-engineering plugin) — searches Claude Code / Codex / Cursor history. Useful when you only know roughly when or what the session was about.
- **Direct file read** — Claude Code sessions live as JSONL under `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`. Direct read is faster when you already have the UUID (which is exactly what the frontmatter gives you).

### Quick header from a UUID

`scripts/session-header.py <uuid>` prints the technical context an entry should reference: repo cwd, git branch, event count, time span, top-referenced repos and files. Run it before writing a new entry to ground the frontmatter in evidence rather than memory.

```sh
./scripts/session-header.py 4435cee2-d532-4ea0-b2d4-e1e90d4c3007
```

The `top_repos` and `top_files` fields are the most useful for "where was the agent actually working" — `cwd:` and `gitBranch:` are often empty or stale on the session header row, but path-reference counts across the full transcript are reliable.

Treat each `session_id:` as a citation: the entry is the claim, the session is the evidence. If a pattern starts to emerge across multiple entries, walk the cited sessions before deciding it's real — the summary always loses some signal the transcript still has.
