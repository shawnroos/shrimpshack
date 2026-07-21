# multi-slice-review

Review a change **too large for one reviewer** — many files, several subsystems, or work built
incrementally by different authors/agents. Reviewing large work as a whole misses boundary defects
(each side looks correct in isolation); reviewing it as isolated units misses them for the same
reason. This slices the diff by invariant, **staffs the seams between slices**, proves load-bearing
assertions by mutation, and loops to an empty round.

Companion to `/ce-code-review` and `/code-review`, not a replacement — it **reviews, it does not
auto-fix** (fixing is the caller's job between rounds).

## When to reach for it

When the pre-pass size signals are large — many files (`F`), several subsystems (`D`) — and the risk
is a **boundary defect** rather than a local bug. Rule of thumb: a whole-diff review would be too big
to hold in one reviewer's head. For a small, single-concern change, use `/ce-code-review`.

## Usage

```
/multi-slice-review <base-ref> [--review-plan]
```

- Runs a deterministic **pre-pass** on `git diff <base-ref>` → signals `F` (files), `D` (subsystems),
  `L` (lines), `RS` (risk surfaces).
- A **rubric** turns the signals into a tier, a soft slice target, the risk lenses to add, and a
  fan-out budget (`WAVE_CAP` = `min(16, cores-2)`, total capped at `MAX_REVIEWERS`).
- The agent draws slices by invariant, enumerates seams, assigns lenses, and **prints the plan + the
  signals that drove it** — then proceeds unless you stop it or passed `--review-plan` (a hard
  approve/edit gate before any reviewer spawns).
- The across-rounds loop runs via Claude's native **`/loop /multi-slice-review-round <base>`**: each
  round reviews, you apply fixes (by slice; seams last), the next round re-reviews primed with what
  changed, until an **empty round** — or a **3-rounds-same-class escalation** proposes a structural
  fix instead of a fourth guard.

The signals are reproducible; the slice count you draw is judgment, so it is not.

## How it's built

- **Deterministic core** (`scripts/prepass.sh`, `scripts/rubric.sh`) — fixed signals + sizing, bats-tested.
- **One round** (`workflows/review.js`) — a native `Workflow`: slices→lens reviewers (parallel),
  seam reviewers (parallel), mutation proof per slice on an **isolated worktree**, synthesis.
- **Crisp decisions** (`workflows/predicates.js`) — empty-round / escalation / dedup, tested and
  **mutation-proven**.
- **The loop** — `/loop` re-invokes the round command across turns (a single Workflow run can't pause
  for the caller's between-round fixes); `docs/round-state.json` carries state.
- **Substrate verdict** (`docs/workflow-contract.md`) — confirms the live Workflow contract; falls
  back to native subagent dispatch if unavailable.
- **Value gate** (`docs/value-check.md`) — proves seam-review beats a whole-diff review, blind-graded,
  before the loop is built.

## Tests

```
bash tests/run-tests.sh all
```

Self-check (proves the harness can fail) + pre-pass + rubric + predicates, each mutation-proven where
load-bearing.

## Publishing

Bump `version` in both `.claude-plugin/plugin.json` and the `multi-slice-review` entry in the root
`.claude-plugin/marketplace.json`, then push — the marketplace auto-updates.
