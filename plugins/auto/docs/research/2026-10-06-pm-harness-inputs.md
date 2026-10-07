# PM harness: design inputs (2026-10-06)

Inputs for a `/ce-brainstorm` on evolving `auto` into a PM-agent harness. Written by the "PM skills fork" session, forked from the "PM: AI Editor" session that ran the Slate reframe and shot-kinds work in herdr workspace w2 on 5–6 Oct 2026.

## Decisions already made (Shawn)
- **Evolve auto in place:** a new `pm` run kind beside today's single-run loop, sharing the run record, the code-computed exit predicate, the Stop hook and the destructive-action backstop. Improvements to the shared core must help both loops. No fork, and no shared-core extraction unless the two diverge.
- **Remit is the herdr space** (workspace), unless stated otherwise. A remit override is one line at the top of the goal doc, for example `remit: w2, tabs Reframing + Cue jobs`.
- **Structure:** protocol (rules of engagement), plus deliverables (evidence-backed definitions of done), plus skills (one recipe per deliverable), tied together by a goal doc and a loop.
- **Deliverable state lives in the PM's own ledger file for now**, not the board's SQLite. `/work` and the board are being reworked separately; the PM talks to them through a thin adapter that falls back to reading herdr and Linear directly.

## What went wrong that this must fix
- The goal doc was prose, bound with native `/goal`, a stateless model judge that reread about 9.8k characters on every stop. Its evidence lived in external systems and was lost to compaction. Its scope grew ("any defect found today"), and the only exit was `/goal clear`. It re-prompted "goal not met" for hours.
- The hourly loop checked one tab, not the remit. Sessions in other tabs (AI-671, AI-593, AI-295) were checked only when Shawn asked.
- Watchers reported false greens three times: CLEAN while the build was CANCELLED; a grep predicate that passed while a duplicate import was still there; "a shard passed" read as recovery when that shard never ran the failing test.
- Blockers were waited on instead of debugged. A shared denoise E2E failure held 9 PRs overnight; Shawn proved in minutes, by hand on stage, that the feature worked.
- Cross-session messages went to the wrong session because a fork inherited the PM's session name.

## Protocol candidates (rules of engagement), all from Shawn's corrections or practice
- **Decision rights:** the PM decides technical calls. Shawn decides product scope, prod deploys, GA releases, spend over a cap, eval waivers, and anything touching another team's code.
- **Hard limits:** never merge around a gate; never fix another team's break (diagnose, ping the owner once, file a ticket for them); never echo secrets; prod flags stay off; never work around a classifier denial.
- **Blockers:** debug a shared blocker at runtime straight away (`/slate-editor-testing` on stage); never wait overnight on an owner.
- **Talking to Shawn:** plain language, tables where they help, one "Next:" line, no repeated asks once he has decided, and every ticket or PR named by its title.
- **Talking to sessions:** one message shape (decision, conditions, next step, ticket). "Go" approvals under Shawn's standing OK. Relay misrouted messages.
- **Accounts:** the stage test login is a superuser. Switch accounts with the in-app switcher, never by URL. OFFFIL is an app key, not an account.

## Deliverables (evidence a sweep can check)
| Deliverable | Evidence | Checker |
|---|---|---|
| merged | merge SHA; head pinned with `--match-head-commit`; mergeStateStatus CLEAN; 0 unresolved threads; a build that actually ran | gh |
| verified | trace or job ID from a stage or preview check, posted on the ticket; the deployed sha contains the merge | version.json + git merge-base, Linear |
| flagged | per-env served value: prod off, stage and dev on | ldcli read-back |
| released | version, dist-tag, registry shasum equal to the tested tarball, announcement link, eval experiment or a named waiver | npm view, Slack, bt |
| recorded | ticket state, root-cause comment, session ran /reflect | Linear API |
| decision-handed | a decision record (options, recommendation) shown to Shawn; terminal state | ledger |

## Patterns to borrow
- **auto:** the atomic run record with its predicate recomputed on every write; the Stop-hook carve-outs (a manual pause and a stale chain are valid stops; allow on re-fire; nag dedupe); programmatic verification criteria; "the model classifies, code decides"; the batch sidecar.
- **compound-engineering:**
  - kernel SKILL.md files (Outcome, Done, boundaries, stop classes) with references loaded per phase;
  - authority granted per run, with delegates able to narrow but never broaden;
  - snapshot-only truth;
  - a single-writer state script under a lease;
  - a token-free watcher that wakes the agent on change;
  - `validate` at sweep start downgrades under-evidenced items;
  - the needs-human decision record with frozen sources and an explicit answer mark;
  - budgets and backstops;
  - trajectory facts for non-convergence;
  - a circuit breaker before batch side effects.
- **work + board:**
  - the space↔project binding as the remit;
  - `board linear snapshot --json` (issues, bindings, panes, pane_status) as the sweep's input;
  - `mark needs_you` / `notify` / `ask_to_show` for escalation;
  - the ground.sh pattern (strip control characters, frame as data) for anything read from other panes.

## Gaps to design
- A worker registry (pane → session → ticket → item), and PM-to-worker messaging (the board refuses send-keys by design; herdr `agent prompt` works).
- A herdr adapter to replace auto's cmux spawner: list, read, prompt, spawn, rename.
- Intake of items found mid-run, with a cut-off; a stop rule for a long-lived lead session.
- Pacing merges so stage can deploy (each develop merge cancels the stage run in flight).
- What the loop may do on its own versus ask: proposed default is merges, prod-off flags, eval-backed prereleases, tickets and session approvals on its own; prod deploys, GA, spend, waivers and product calls go to Shawn.

## Source research
- auto: run record, Stop hook, goal authoring (`plugins/auto/lib/on-stop.py`, `run_record_predicate.py`, `skills/auto-author-goal`).
- compound-engineering 3.29.0: `ce-babysit-pr` (tick, watch-loop, settle, report), `ce-sweep` (state schema, run), `ce-work` (receipts, return-to-caller), `lfg`.
- work 0.6.0 + herdr-linear-board: `docs/board-owns-the-store.md`; snapshot schema in `crates/board-core/src/protocol.rs`.
