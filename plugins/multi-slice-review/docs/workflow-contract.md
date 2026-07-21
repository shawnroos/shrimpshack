# Workflow-contract preflight (U1) — recorded evidence

Status: **PASSED — documented contract confirmed AND proven by execution.**

Live wiring check (2026-07-21, run wf_5b842e77-e51): a tiny 2-slice/1-seam inline
Workflow (`export const meta` + `pipeline`→`parallel`→`agent` + per-agent `schema`
+ synthesis) ran with 5 agents, 0 errors, and returned exactly the expected shape:
`{ slicesProcessed: 2, sliceFindings: 4, seamFindings: 1, schemaValidated: true }`.
So hand-authored `.js` is accepted, the primitives work, and schema-validated
structured returns work. GO on the Workflow substrate — no KTD8 fallback needed.
Cost note: 5 *trivial* agents burned ~203k tokens (~40k/agent just to spawn a
reviewer) — reprices U6/U7 fan-outs significantly.

## Step 1 — Availability probe

The native `Workflow` tool is **present** in this runtime as a top-level, always-loaded tool.

Note: `ToolSearch select:Workflow` returns "no matching deferred tools" — this is **not** evidence
of absence. ToolSearch enumerates only *deferred* tools; `Workflow` is top-level, so a miss there is
expected and says nothing about availability. (This misread cost a reviewer a false "tool absent"
conclusion during planning.)

→ **Availability: PASS.** No fallback to KTD8 needed on availability grounds.

## Step 2 — Contract confirmation (from the tool's documented spec)

| Contract element | Documented value | Verdict |
|---|---|---|
| Script entry | `export const meta = {...}` required at top of script | ✅ matches KTD1 |
| Invocation | inline `script`, or `scriptPath` to a `.js` file on disk, with `args` | ✅ hand-authored `.js` accepted via `scriptPath` |
| Primitives | `agent()`, `parallel()`, `pipeline()`, `phase()`, `log()` | ✅ matches the fan-out design |
| Structured returns | per-agent `schema` (JSON Schema) → validated object | ✅ matches KTD5 |
| Mutating-agent isolation | `isolation: 'worktree'` per agent (fresh git worktree, auto-cleaned) | ✅ matches KTD7 |
| Concurrency | capped at `min(16, cores-2)` concurrent agents | ✅ matches KTD3 (8 on this 10-core box) |
| Lifetime backstop | 1000 agents total per workflow | ✅ matches KTD3 |
| Opt-in gate | required; satisfied by "a skill or slash command whose instructions tell you to call Workflow" | ✅ `/multi-slice-review` command satisfies it |
| Resume | `runId` + `resumeFromRunId`; scripts persisted to session dir | ✅ (not load-bearing for v1) |

**Module-load question (KTD4 import-safety):** the documented script body runs at top level (it is the
Workflow *entry*), so `review.js` must reference native primitives only inside engine-invoked functions,
and the pure per-round predicates live in a separate native-primitive-free `predicates.js` (imported
cleanly under bare node for tests) — confirmed as the required shape, already encoded in the plan
(KTD4, U8). Note: `review.js` runs **one** round; the across-rounds loop is Claude's native `/loop`
re-invoking the round command across turns (a single Workflow run cannot pause for between-round fixes).

→ **Contract shape: CONFIRMED as hand-authored `.js` (not a compiled-recipe model).** No U6 re-scope
needed. KTD8 fallback stays a contingency, not the path.

## Step 3 — Wiring check by execution (tiny 2-slice / 1-seam fan-out)

**PENDING.** Per U1's "prove by execution, not by reading docs" note, the contract above is confirmed
from documentation; a live tiny fan-out still must run to prove the wiring end-to-end (a real
`Workflow({script, args})` invocation that spawns real agents). This requires the operator's explicit
multi-agent opt-in.

→ **Overall U1 verdict: GO on the Workflow substrate (documented contract holds), with the live wiring
test outstanding.** Recorded here so U5's cap assertions and U6's build can proceed against a confirmed
contract; the live fan-out closes the "prove by execution" requirement before the U6/U8 live runs.
