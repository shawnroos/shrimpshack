# Spinoff: Couple herdr's layout to Linear's object model

> This handoff is directional — author intent and a starting point, not a spec.
> The code and tests are the source of truth; validate against them and refine.

## Goal
Build a plugin that makes a herdr layout and a Linear workspace the same object
graph, so an agent knows what it is working on from *where* it is sitting, and so
Linear stays an accurate record of the work without anyone remembering to update it.

Shawn's mapping, in his words:

| herdr | Linear |
| --- | --- |
| session | account / workspace |
| space (herdr calls it a **workspace**) | project |
| tab | issue |
| split column | sub-issue (several sessions on one issue) |
| horizontal split inside a column | belongs to that column's sub-issue |

Two directions, both required:

1. **Read** — a new session in `projectX / issueY / subissueZ` immediately pulls its
   Linear context and grounds itself. No "what am I working on?" preamble.
2. **Write** — position gives the agent a path of action. It creates projects,
   issues and sub-issues, and moves status, so Linear reflects the truth at all
   times rather than at commit time.

## Why now / context
Shawn raised this as its own batch of work while running in herdr. Today an agent
in a fresh tab knows its cwd and nothing about the work item; and Linear drifts
because updating it is a manual step at the end. The layout already encodes the
work breakdown — this makes that encoding load-bearing instead of decorative.

## Key decisions already made
- **Plugin home: `shrimpshack/plugins/herdr-linear/`** (Shawn chose shrimpshack over
  a new standalone repo). Sits beside `spinoff`, `auto`, `reflect`, so it gets the
  marketplace wiring for free.
- **herdr has no local source repo** — it is a Homebrew install
  (`/opt/homebrew/bin/herdr`). So this is a **Claude Code plugin** built on herdr's
  public CLI. If it turns out a herdr-side change is genuinely needed, that is an
  upstream ask to raise, not work to do here.
- **No Linear ticket yet.** Deliberate — the first real dogfood of this plugin is it
  creating its own project and issues once scope is clear.
- **Vocabulary:** Shawn's "space" is herdr's **workspace**. Use herdr's own nouns
  (workspace / tab / pane) in code and docs, and keep the Linear nouns
  (project / issue / sub-issue) on the other side of the mapping. Don't invent a
  third vocabulary.

## What the herdr CLI actually gives you (probed this session, `herdr 0.x` on PATH)
Verified by running the command groups — not from docs:

- **Read the whole topology:** `herdr api snapshot`. Also `herdr api schema --json`.
  This is the primitive for "where am I".
- **Env injection at creation:** both `herdr workspace create` and `herdr tab create`
  accept `--env KEY=VALUE` (plus `--cwd`, `--label`, `--focus`). This is the strongest
  grounding candidate — stamp `LINEAR_PROJECT_ID` / `LINEAR_ISSUE_ID` into the pane's
  env when the surface is made, and have a Claude Code `SessionStart` hook read them
  and fetch context. Much sturdier than parsing tab labels.
- **Caller context already in env:** `HERDR_ENV`, `HERDR_WORKSPACE_ID`,
  `HERDR_PANE_ID` are present in every herdr-spawned pane. Note
  `HERDR_ENV=1` records *launch ancestry, not reachability* — probe
  `herdr status server` before trusting it (memory:
  `reference_herdr_env_is_ancestry_not_reachability`).
- **Write-back into herdr chrome:** `herdr workspace report-metadata <ws_id>
  --source ID --token NAME=VALUE [--ttl-ms N]`. Workspace-level only —
  `herdr tab` exposes only `list/create/get/focus/rename/close`, **no metadata verb**.
  So per-issue status in the herdr UI may only be reachable via `tab rename`.
- **Agent lifecycle:** `herdr agent` classifies a pane's agent as
  `idle | working | blocked | done | unknown`. A status signal worth mapping to Linear
  issue state — but `unknown` does **not** mean finished, and `done` is just idle
  after unseen background work.

## Open questions / not yet decided
1. **Does the pane tree actually distinguish columns from rows?** I did not probe
   `herdr pane`. The whole "column = sub-issue, horizontal split = belongs to that
   column" mapping depends on `api snapshot` exposing that nesting. **Verify this
   first** — if it doesn't, the mapping needs rethinking before anything is built.
2. **`herdr integration install claude` already exists.** Find out what it installs
   into `~/.claude` — that is the *existing* coupling surface between herdr and Claude
   Code. Inspect and extend it rather than building a parallel one.
3. **Linear write path.** CLAUDE.md prefers CLI over MCP precisely because MCP tokens
   expire mid-task, and "Linear reflects truth at all times" is the requirement that
   breaks first on an expired token. Is there a usable Linear CLI, or does this need a
   thin script against the Linear GraphQL API with a durable key? Decide before
   designing the write side.
4. **Enforcement model — the material fork.** Is "agents update Linear consistently"
   (a) skill instructions the agent is asked to follow, or (b) a hook (`Stop` /
   `PostToolUse`) that detects drift and blocks or nags? (a) is cheap and unreliable;
   (b) is real but intrusive. Shawn's phrasing ("agents are *made* to") leans (b).
5. **Does this need a herdr-side plugin at all?** Shawn said "may or may not require a
   combination". Answer it explicitly once you know what the CLI can and cannot do —
   don't leave it implicit.
6. **Conflict handling.** Two panes on one sub-issue both moving status; a tab renamed
   by hand; an issue closed in Linear while a pane is still working it. Which side wins?

## Starting point
- `plugins/spinoff/skills/spinoff/scripts/spinoff.sh` — **the prior art**. It already
  drives herdr from a plugin script: backend detection, absolute binary resolution
  (`HERDR_BIN`), workspace/tab/pane creation, agent readiness waits. Read its herdr
  backend before writing any herdr calls of your own.
- `plugins/auto/`, `plugins/reflect/` — plugin layout conventions in this repo.
- `~/.agents/skills/herdr/SKILL.md` — the herdr control skill.
- `herdr api schema --json` — the socket API surface.
- Memory: `reference_herdr_env_is_ancestry_not_reachability`,
  `feedback_prefer_cli_over_mcp`, `feedback_consume_extend_dont_rebuild`.

## Recommended next step
`/ce-brainstorm`. Two things are genuinely unresolved — whether the pane tree supports
the column/row mapping at all (Q1), and whether enforcement is instructions or hooks
(Q4) — and each sends the design somewhere different. Probe `herdr pane` and
`herdr integration install claude` first so the brainstorm argues from facts, then
move to `/ce-plan` once the mapping is confirmed and the enforcement model is picked.

## Source session
Transcript: `/Users/shawnroos/.claude/projects/-Users-shawnroos/2572ef78-e84c-4439-8c69-b4eb1927f976.jsonl`
Resume:     `cd /Users/shawnroos && claude -r 2572ef78-e84c-4439-8c69-b4eb1927f976`
