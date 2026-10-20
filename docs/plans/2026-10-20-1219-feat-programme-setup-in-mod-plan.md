---
title: Programme Setup in the Mod - Plan
type: feat
date: 2026-10-20
topic: programme-setup-in-mod
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-brainstorm
execution: code
---

# Programme Setup in the Mod - Plan

## Goal Capsule

- **Objective:** Shawn can get an auto programme running with little effort, sees plainly what the programme covers and what it leaves out, and is only asked to act in chat when something needs his reply.
- **Means:** the chat walks setup one step at a time while the Programme pane mirrors the draft agreement; after setup, status and sweep output live in the pane and band, not the chat.
- **Product authority:** Shawn. Two neighbouring pieces of work own adjacent rules and are not active scope here: the agreement's sections belong to `docs/plans/2026-10-20-1200-refactor-agreement-consolidation-plan.md` (branch `feature/agreement-consolidation`), and the pending-asks data, the reporting rules and the sweep's chat rules belong to the "Programme noise fixes" work (branch `feature/programme-noise-fixes`).
- **Open blockers:** none for planning. The walkthrough is defined against whatever sections the agreement exposes (R2), so it does not wait on the consolidation landing.
- **Stop conditions:** stop and ask Shawn if planning or a live probe shows a picker answer cannot be told apart from text the model wrote (R8); if `bugfix/auto-runtime-findings` cannot be rebased under this work without changing its behaviour; or if the consolidation changes the single typed accept (R7).

---

## Product Contract

### Summary

Running `/auto:programme` opens the Programme pane and turns the chat into a step-by-step setup guide: one question per step, the PM's recommendation first, the pane filling in as Shawn answers, ending on one accept he types. After setup the chat goes quiet: status and sweep results show in the pane and band, and the chat speaks only when Shawn must reply, when something stops the PM, or when he asks.

### Problem Frame

Today `/auto:programme` prints one large setup screen into the chat (remit, rules, sources, items to adopt, project terms) and waits for a typed reply (`plugins/auto/commands/programme.md`, step 4). The PM does nothing to move setup forward; Shawn has to read the block, work out what to change, and phrase it himself. `/auto:programme-status` also prints its full report into the chat. Shawn juggles a dozen things, so a block that scrolls away is lost, and he cannot tell at a glance what a programme covers and what it leaves out.

The Programme mod already has the pieces for a better split. PR #112 added a band above the prompt, a work tree in the side pane and an interactive contract view that shows each term's options, proposals and the exact reply to type (`plugins/auto/mods/programme-view/contract.tsx`). But the pane opens only when Shawn types `/programme-view` (`register.tsx`), and before acceptance it offers no setup view.

The agreement itself is being reshaped in parallel. The consolidation plan settles on two per-programme sections (Scope and Rulings) plus who-decides-what and done standards set once and shared by every programme (its R16 covers setup). That shape is not on `main` yet, which today carries five agreement terms.

### Key Decisions

- **Setup and reports ship together in one plan.** Governs R1–R16. (session-settled: user-directed — chosen over setup first or reports first: one release that makes the PM both guide and quiet)
- **Chat leads, pane mirrors.** The chat asks one question per step and the pane shows the whole draft. Governs R2–R6, R12. (session-settled: user-directed — chosen over a pane form with a chat coach, and over one pane card per step, after comparing all three in a TUI sketch: the session must move setup forward)
- **Picker answers approve this programme's setup choices before acceptance.** Governs R8–R11. (session-settled: user-directed — chosen over typing every step and over picks that only propose with one typed accept: fewer steps, and the loosening ends at acceptance)
- **The final accept stays typed.** Governs R7, R9. (session-settled: user-approved — the moment the PM gains authority is always something Shawn typed; picks cover only the steps before it)
- **Settings shared across programmes stay typed, even during setup.** Governs R9. (session-settled: user-approved — they change every running programme, so a click in one setup must not change the rules for others)
- **The pane opens on its own.** Governs R1. (session-settled: user-directed — chosen over the chat asking first and over Shawn typing `/programme-view`)
- **A quiet sweep says nothing in chat.** Governs R13. (session-settled: user-directed — chosen over a one-line heartbeat and over a line only when something changed)
- **A fast path takes every recommendation.** Governs R4. (session-settled: user-approved — "really easy to get going" was Shawn's first success signal)
- **Scope shows what is out as well as what is in.** Governs R6. (session-settled: user-approved — "clarity about what's in/out" was Shawn's second success signal)
- **`/auto:programme-status` opens the pane instead of printing.** Governs R15. (session-settled: user-approved — reports belong in the mod)
- **Build now, driven by the section list the agreement exposes, rather than waiting for the consolidation to land.** Governs R2. Waiting would hold this work behind a refactor that has no implementation yet; a section-agnostic walkthrough survives a rename or merge of sections.
- **Data for pending asks comes from the Programme noise fixes work; this work renders it.** Governs R14, R16. Agreed with that session on 2026-10-20 so the two branches do not build the same list twice.

### Actors

- A1. Shawn: starts the programme, answers setup questions, types the accept and any reply a decision needs.
- A2. The PM (the driving session): runs the walkthrough, records choices, sweeps, and decides what reaches the chat.
- A3. The Programme mod: the side pane and band; displays only, never submits or fills a prompt.

### Requirements

**Setup walkthrough**

- R1. Running `/auto:programme` opens the Programme pane on its own, showing a setup view of the draft agreement; if the pane cannot open, the chat's first line names the one command that opens it.
- R2. The chat walks setup one step per agreement section, in the order the agreement defines, then items to adopt, then accept; a setting shared across programmes is walked only when it is unset, and is otherwise shown as one line saying the existing settings are in use.
- R3. Each step asks one question in a picker, with the PM's recommendation first and the source of every proposed default shown beside it.
- R4. The first question offers "take all recommendations", which applies every recommended per-programme choice and moves straight to the accept.
- R5. The pane lists every setup step as done, current or upcoming, with the values chosen so far and what the current step proposes, and updates as each answer lands.
- R6. The scope step and the top of the pane list what the programme leaves out (herdr spaces, repos and tracker work not covered) as well as what it covers.
- R7. Setup ends on one accept that Shawn types; the chat and the pane show the exact line to type.

**Approval during setup**

- R8. Before acceptance, a picker answer given in the driving session approves the per-programme setup choice it answers, and only when the programme can verify the answer came from Shawn rather than from text the model wrote.
- R9. A picker answer never approves the final accept, a setting shared across programmes, a reserved area, or anything the agreement says binds only on a typed prompt (rulings); those steps show the reply to type instead.
- R10. After acceptance only a typed prompt approves anything, unchanged from PR #110.
- R11. Every choice a picker answer approves is recorded with its question, the answer and its origin, so the record shows it was a pick and not a typed prompt.

**Reports after setup**

- R12. After setup, status, sweep results and one-line notices show in the pane and band, not in the chat.
- R13. A sweep that needs nothing from Shawn writes nothing in the chat.
- R14. The chat speaks only when a decision needs Shawn's typed reply, when an error stops the PM, or when Shawn asks; a decision request carries the details the reporting rules require.
- R15. `/auto:programme-status` opens or focuses the pane instead of printing, and prints in the chat only for another programme's run or when no pane is available.
- R16. The pane shows pending decisions and the exact reply to type for each, using the data the view provides rather than composing replies itself.

### Visualization

The agreed layout (option A from the TUI sketch), during setup. Directional: wording and glyphs are not settled.

```text
 chat                                         │ side pane
 PM                                           │ Programme setup        draft, not accepted
 Step 2: what the PM watches.                 │ ✓ Scope · where
 Remit done: AI-Editor · 2 repos · Linear WEB │     in:  AI-Editor · shrimpshack, ai-chat-backend
                                              │     out: Infra tab · ai-editor-backend
 Which sources should I watch?                │ ▸ Scope · sources          ← current
   ◉ All three (Recommended)                  │     tracker  Linear (answered)
   ○ Tracker + tasks, no plans                │     tasks    3 sessions with lists
   ○ Tracker only                             │     plans    4 recent
                                              │ ○ Rulings
                                              │ ○ Shared settings   using existing
                                              │ ○ Items to adopt    3 proposed
                                              │ ○ Accept            type: accept the agreement
 ─────────────────────────────────────────────────────────────────────────────
 band: Setup 2/6 · sources ▸ rulings ▸ shared ▸ items ▸ accept
```

### Key Flows

- F1. First setup
  - **Trigger:** Shawn types `/auto:programme` in a herdr space with no programme.
  - **Actors:** A1, A2, A3
  - **Steps:** the PM takes the lease and the pane opens; the chat asks the fast-path question; Shawn walks each step in a picker; the pane marks each step done as answers land; the shared-settings step is skipped when already set; the PM proposes items to adopt; the chat shows the accept line and Shawn types it; the PM arms its wake-ups.
  - **Outcome:** an accepted programme, with no setup block left in the chat.
  - **Covered by:** R1–R8, R11
- F2. Fast path
  - **Trigger:** Shawn picks "take all recommendations" at the first question.
  - **Actors:** A1, A2
  - **Steps:** the PM applies every recommended per-programme choice; steps that need a typed reply (R9) still show their reply; the chat shows the accept line.
  - **Outcome:** setup reaches the accept in one pick plus the typed lines R9 requires.
  - **Covered by:** R4, R7, R9
- F3. A sweep after setup
  - **Trigger:** a watcher line or the cron wakes the PM.
  - **Actors:** A2, A3, A1
  - **Steps:** the PM sweeps and updates the view; the pane and band redraw; if a new decision needs Shawn, the chat shows it with its details and reply; otherwise the chat stays empty.
  - **Outcome:** Shawn sees state in the pane and is interrupted only to act.
  - **Covered by:** R12–R14, R16

### Acceptance Examples

- AE1. **Covers R8, R11.** Given the agreement is not yet accepted, when Shawn picks "fixed, every 15 min" for the cadence in the setup picker, then the cadence is set and the record shows the change came from a pick.
- AE2. **Covers R9.** Given setup is at the shared-settings step and the settings are unset, when the PM asks about done standards, then the chat and pane show the reply to type, and a picker answer alone changes nothing.
- AE3. **Covers R10.** Given the agreement is accepted, when the PM asks a question in a picker and Shawn answers it, then the answer approves nothing and any change it implies waits for a typed reply.
- AE4. **Covers R13, R12.** Given an accepted programme, when a sweep finds nothing that needs Shawn, then the pane and band update and the chat shows nothing from that sweep.
- AE5. **Covers R1.** Given the pane cannot open in this session, when Shawn runs `/auto:programme`, then the chat's first line names the command that opens it and setup continues in the chat.
- AE6. **Covers R15.** Given an accepted programme driven by this session, when Shawn types `/auto:programme-status`, then the pane opens or takes focus and the chat shows no report.

### Scope Boundaries

- The agreement's sections, their contents and who decides what: owned by the consolidation plan. This work walks whatever sections the agreement exposes.
- The pending-asks data, the reporting rules (names beside every ID, restated prior state, decision details) and the sweep skill's rules on what goes to chat: owned by Programme noise fixes. This work renders their data.
- The decision log view: owned by the consolidation plan.
- Watching a programme from a session other than the driving one.
- Bumping the plugin version or cutting auto 0.16.0; that release is on hold until the consolidation is decided.

### Dependencies / Assumptions

- `bugfix/auto-runtime-findings` changes `plugins/auto/lib/programme_view.py`, which this work extends; this work builds on it once merged, or rebases onto it.
- No hook records picker answers today (`plugins/auto/lib/on-pretooluse-askuser.py` only gates the call), so R8 needs a new path that the harness, not the model, feeds.
- The mod is forbidden from submitting, suggesting or filling a prompt (`plugins/auto/mods/programme-view/no-prompt.test.ts`); nothing here changes that.

### Outstanding Questions

**Deferred to Planning**

- How the programme verifies a picker answer came from Shawn (R8). The likely path is a hook on the picker's result; a live probe must show the harness delivers the answer text to that hook, with the same session check, named-term check and redaction the typed path applies.
- Which tests assert typed-only approval and need a counterpart for the pre-acceptance picker path (R8–R10).
- How the mod opens the pane without a typed command (R1), and where setup progress is stored so the pane can draw it (R5).
- Whether the band can take keyboard focus during setup; PR #112 found it takes keys only after a click.

### Sources / Research

- `plugins/auto/commands/programme.md`: today's setup flow; step 4 prints the setup screen and waits for a typed reply.
- `plugins/auto/commands/programme-status.md`: prints its output into the chat.
- `plugins/auto/skills/programme-sweep/SKILL.md`: works from the store, "not from this chat"; chat output is limited to one-line notices.
- `plugins/auto/lib/programme.py` (`_typed_prompt`): approval requires a journaled prompt with origin `typed` from the driving session.
- `plugins/auto/mods/programme-view/`: `register.tsx` (pane opens only on `/programme-view`), `contract.tsx` and `actions.ts` (term options, proposals, "Type this:" replies).
- `docs/plans/2026-10-19-1205-feat-programme-sessions-contract-plan.md`: PR #112's display decisions this work keeps.
- `docs/plans/2026-10-19-0854-feat-pm-operating-contract-plan.md`: "Deferred to Follow-Up Work" records the reporting rules now owned by Programme noise fixes.
- `docs/plans/2026-10-20-1200-refactor-agreement-consolidation-plan.md` (branch `feature/agreement-consolidation`), R16: setup walks Scope and Rulings per programme and sets shared settings once.
