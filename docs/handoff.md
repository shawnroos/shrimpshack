# Spinoff: one agreement with four sections, plus one log

> This handoff is directional — author intent and a starting point, not a spec.
> The code and tests are the source of truth; validate against them and refine.

## Goal
Consolidate the concepts that shape the Programme PM's behaviour into **one agreement with four sections (Scope, Authority, Done standards, Rulings), plus one log**, before Shawn dogfoods Programme and accepts agreements under the current model.

## Why now / context
Shawn asked "What concepts do we currently have in auto that define behaviour, actions, methods" and then "Should we have that many?". The answer was no. Six concepts currently shape PM behaviour and overlap:

| Concept | Question it answers |
|---|---|
| Agreement terms (remit, stop rule, autonomy, cadence/budget, tools of record) | scope, when to stop, cadence, how much autonomy |
| Project terms (#111) | who decides an area, preferred tool |
| Protocol rules (3 layers: plugin, personal, project) | what counts as done for a change kind (deliverables, evidence bar) + autonomy level |
| Instructions | standing order with scope and end date |
| Decision records (#113, `record-decision`) | scoped ruling workers follow; binds on typed acceptance |
| Corrections (#111, switched off, CORRECTIONS_ON=False) | change to who decides a decision kind |
| Decision log (#111, `log-decision`) | record of calls — approves nothing |

"Who decides" is answered in four places (agreement autonomy, project terms, protocol autonomy levels, corrections); scoped/dated orders in two (instructions, decision records). The PM must reconcile several sources with different approval rules — plausibly a cause of the gating and rabbit-holing Shawn has seen.

Timing: PR #111 just shipped these, corrections are off, and no agreement Shawn accepted carries the contract stamp yet. After dogfooding, consolidation means migrating live records. The source session recommended holding the auto 0.16.0 release until this is decided.

## Proposed model (from the source session — validate, don't execute literally)

| Section | Holds | Replaces |
|---|---|---|
| **Scope** | what the programme covers, stop rule, cadence and budget | remit, stop rule, cadence terms |
| **Authority** | who decides each decision kind (protected list fixed in code, never editable) | autonomy term, who-decides part of project terms, protocol autonomy levels, corrections |
| **Done standards** | deliverables and evidence bar for each kind of change | protocol rules |
| **Rulings** | dated, scoped orders and decisions, each with Shawn's words | instructions, decision records |
| **Log** (outside the agreement) | every call and who made it; approves nothing | decision log (unchanged) |

Kept separate on purpose:
- The log stays apart from anything that approves (that is why a model claiming "accepted" cannot make it so — seen live in today's runtime test).
- Protected escalations (production deploys, releases, spend over cap, merging around a gate, refused permissions, risk/cost limits, settled human decisions) stay in code.
- Layered defaults (plugin, personal, project) only pre-fill the agreement at start; at runtime there is one place to read.
- Tools of record: decide where they live (Scope? Authority's "preferred tool"?). The PM operating-contract work wanted preferred tools per job (e.g. Amplitude, Datadog for prioritization).

## Key decisions already made (by Shawn)
- Only a prompt Shawn types approves (PR #110). Taken suggestions, SDK prompts, notifications, peer messages never approve.
- Reporting rules for AUTO: name every ID, restate prior state, contract checklist, decisions with options/costs/do-nothing/recommendation right there.
- Contract view (PR #112): every term shows its active setting, options with descriptions; anything a command can do is reachable from the UI; approvals fill the reply Shawn types; some terms take custom options (remit add space, cadence custom interval, tools of record add tool).

## Open questions / not yet decided
- Is the four-section split right? What distinction does each current concept carry that the proposal would lose? Trace actual code paths — the source session reasoned from glossaries and PR summaries, not every code path.
- How per-change-kind autonomy (protocol) and per-decision-kind authority (#111) reconcile into one Authority table.
- Migration: existing records (agreement terms, project_terms, protocol personal file, instructions, context.decisions, decision log) and the read-compat guarantee in `plugins/auto/CONCEPTS.md`.
- Impact on the contract view (#112 term editors), sweep skill, `/auto:programme-status terms`, recover packet (#113), permission proposals (#114).
- Whether to hold the 0.16.0 release (source session recommended holding).

## Related work in flight
- Tab "Programme setup in the mod" (branch feature/programme-setup-in-mod): moves /auto:programme output into the mod and uses chat to walk Shawn through setup — setup walks exactly these agreement sections, so coordinate.
- A fix PR for runtime-test findings is in progress on bugfix/auto-runtime-findings (settings guard fail-open, `end --why` truncation, repeated stop reasons, `end` help text).

## Starting point
- `plugins/auto/CONCEPTS.md` and repo `CONCEPTS.md` (Programme, Decision record, Decision log, Project terms, Correction, Permission proposal, Clause, Tools of record).
- Code: `plugins/auto/lib/programme_home.py` (default_terms), `programme_terms.py`, `programme_decisions.py`, `programme_protocol.py`, `programme.py` (instructions, agreement verbs), context/decision-record modules from #113, `programme_view*.py`.
- Plans: `docs/plans/2026-10-06-1551-feat-auto-programme-runs-plan.md`, `docs/plans/2026-10-19-0854-feat-pm-operating-contract-plan.md`, `docs/plans/2026-10-18-1731-feat-programme-durability-recovery-plan.md`.
- Overview: `plugins/auto/docs/programme-overview.md`.

## Recommended next step
`/ce-brainstorm` — the model is a proposal with real open questions (what each concept's distinction carries, migration, view impact); validate it against the code before any planning.

## Source session
Transcript: `/Users/shawnroos/.claude/projects/-Users-shawnroos-projects-shrimpshack/2ca65608-d053-402f-b0e6-ceb6ffeb0b9b.jsonl`
Resume:     `cd /Users/shawnroos/projects/shrimpshack && claude -r 2ca65608-d053-402f-b0e6-ceb6ffeb0b9b`
