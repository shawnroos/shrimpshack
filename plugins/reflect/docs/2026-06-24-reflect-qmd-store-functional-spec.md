# Functional Spec — Reflect as a QMD-backed memory + document store

Behavioral specification. Describes observable behavior — triggers, inputs,
outputs, states, error handling — independent of implementation. Companion to
the requirements doc (`docs/brainstorms/2026-06-23-reflect-qmd-store-requirements.md`)
and the implementation plan (`docs/plans/2026-06-24-001-feat-reflect-qmd-store-plan.md`).

---

## 1. Purpose

Make memory and the documents agentic coding generates **reliably retrievable**
without overflowing the session context. The loaded memory index stays small and
complete; full memory bodies and durable documents are searchable through QMD;
and `/reflect` keeps the search layer fresh and captures documents before their
worktrees are deleted.

---

## 2. Components and roles

| Component | Role |
|---|---|
| `MEMORY.md` (pointer index) | The only memory artifact auto-loaded each session. One line per memory: title + ≤1-line hook + pointer to its body file. Always under the load budget. |
| Memory body files | One `.md` per memory in the memory dir. The durable source of truth. Indexed by QMD. |
| `doc-store/` | Type-segmented central store of durable documents (`brainstorms/`, `handoffs/`, `solutions/`, …). Git-tracked. |
| QMD | Local search index over the memory bodies and doc-store. The retrieval layer — never the only copy. |
| Collection reconciler | Ensures one QMD collection per doc-type plus a memory collection, all correctly pointed and embedded. |
| Seeded-recall hook | On the first prompt of a session, injects the most relevant memory bodies into context. |
| `/reflect` pass | The write-side engine: index hygiene, document capture, embedding, then worktree cleanup. |

**Source-of-truth rule (applies throughout):** memory bodies and captured
documents are git-tracked files. QMD is a retrieval accelerator. A stale,
slow, or unavailable QMD degrades recall quality but never loses content.

---

## 3. Functional requirements

### FR-1 — Budgeted pointer index

- **What:** `MEMORY.md` presents one concise line per memory (`- [Title](file.md)
  — ≤1-line hook`) and never exceeds the load budget (**< 25 KB and ≤ 200 lines**).
- **Why both limits:** the platform truncates the loaded index at ~25 KB *and*
  ~200 lines; entry growth can hit the line cap before the byte cap.
- **Behavior:** every memory has exactly one index entry; every entry points to an
  existing body file; no entry duplicates the full body (the verbose detail lives
  in the body, where QMD can search it).
- **Guardrail:** a lint check fails when the index exceeds either limit or when
  index entries and body files fall out of parity.

### FR-2 — Proactive seeded recall (once per session)

- **Trigger:** the first user prompt of a session (`UserPromptSubmit`).
- **Inputs:** the prompt text and session id (read from the hook's stdin), plus the
  current git branch.
- **Behavior:** performs a **fast lexical search** (`qmd search`) over the memory
  collection seeded by prompt + branch, selects the top-K results above a score
  floor, fetches each full body, and injects them into the session context as
  added context. Bounding (top-K, score floor) is enforced by the hook itself, not
  assumed from search flags.
- **Latency contract:** the search path must not stall the prompt — it runs under a
  hard timeout (target sub-second; the heavy semantic path is explicitly not used
  here).
- **Once-per-session:** a second prompt in the same session does not re-run recall.
- **Staleness signal:** if the memory collection has pending (un-embedded) memories,
  the injected context notes that recall may be incomplete.
- **Failure mode:** if QMD is missing, errors, or times out, the hook emits nothing
  and the session proceeds normally (no error surfaced).

### FR-3 — On-demand recall and fallback

- **What:** at any point the agent can retrieve a memory body — by searching QMD, or
  by reading the body file named in its index pointer.
- **Degradation:** when QMD is unavailable, the index pointer (a real file path)
  remains a working manual path to every memory.

### FR-4 — Programmatic collection reconciliation

- **What:** an idempotent operation that ensures the Claude-owned QMD collections
  exist, are correctly pointed, and are embedded.
- **Collections:** `claude-memory` → the memory dir; one `claude-<type>` per
  `doc-store/<type>/` subdirectory.
- **Naming:** collection names are `claude-`-prefixed (ownership marker).
- **Ownership safety:** the reconciler only reads/writes collections whose name
  starts with `claude-`; it never modifies foreign collections (openclaw, Slate,
  global). Config writes are atomic.
- **Idempotent:** running it when collections already match changes nothing and
  creates no duplicates.
- **Extensible:** adding a new `doc-store/<newtype>/` and re-running creates exactly
  one new `claude-<newtype>` collection — no manual config editing.

### FR-5 — Durable document capture

- **Trigger:** a `/reflect` pass.
- **Classification:** reflect decides durable vs ephemeral by heuristic — brainstorms,
  handoffs, and `docs/solutions/` are durable; scratch plans, working notes, and
  review logs are ephemeral. No author marker is required.
- **Behavior:** durable documents are copied into the matching `doc-store/<type>/`
  subdirectory; ephemeral documents are left in place.
- **Ordering guarantee:** capture (and embedding) happen **before** reflect removes
  any merged worktree, so a durable document authored inside a worktree survives the
  worktree's deletion.

### FR-6 — Freshness / embedding

- **Trigger:** end of each `/reflect` pass.
- **Behavior:** reflect re-embeds only the affected Claude-owned collections
  (collection-scoped), so newly saved memories and newly captured documents become
  searchable in the next session.
- **Boundary:** the global QMD backlog and foreign collections are never embedded by
  this process.

### FR-7 — Memory save protocol

- **What:** saving a memory means writing its body file, then adding (or updating) a
  one-line pointer entry in the index. The verbose recall signal lives in the body,
  not the index.
- **Documentation:** `CLAUDE.md`'s Memory Protocol describes this discipline so the
  save convention agents follow stays correct; memory types are unchanged.

### FR-8 — Automatic activation

- **What:** the live-config changes that can't be applied from an unmerged branch
  (wiring the seeded-recall hook into `settings.json`; applying the Memory Protocol
  update to `CLAUDE.md`) self-apply after install/update — no manual step.
- **Trigger:** reflect Pass 0 runs an idempotent, version-marker-guarded setup on its
  first run after install/update, and self-wires a `SessionStart` hook so activation
  stays applied automatically thereafter. Collections are created/embedded by Pass 8
  (FR-4 + FR-6).
- **Behavior:** every step is independently idempotent and an instant no-op once
  applied; a partial failure is recovered by running again (the marker is written
  only on full success). The `CLAUDE.md` patch is conservative — backs up first and
  skips (leaving manual application) if the file's section structure is ambiguous.

---

## 4. Behavioral scenarios

- **BS-1 — QMD down mid-session.** *Given* QMD is unavailable, *when* the agent needs
  a memory body, *then* it reads the file named by the index pointer; nothing is
  reported missing. (FR-3)
- **BS-2 — Durable doc survives worktree cleanup.** *Given* a brainstorm authored in a
  worktree whose PR just merged, *when* reflect runs, *then* the doc is copied to
  `doc-store/brainstorms/` before the worktree is removed and remains searchable
  afterward. (FR-5)
- **BS-3 — Ephemeral doc not captured.** *Given* a scratch working note in that
  worktree, *when* reflect runs, *then* it is not copied and disappears with the
  worktree. (FR-5)
- **BS-4 — Saved memory recalled next session.** *Given* a memory saved this session,
  *when* reflect embeds the memory collection at end of pass, *then* next session's
  seeded recall can surface it. (FR-2, FR-6)
- **BS-5 — First-prompt recall is fast.** *Given* a new session, *when* the first
  prompt arrives, *then* seeded recall completes under its timeout and injects ≤ K
  relevant bodies without a perceptible stall. (FR-2)
- **BS-6 — New doc-type auto-registers.** *Given* a new `doc-store/<newtype>/`
  directory, *when* the reconciler runs, *then* a `claude-<newtype>` collection is
  created and embedded, foreign collections untouched. (FR-4)
- **BS-7 — Index stays in budget.** *Given* the migrated index, *when* the lint runs,
  *then* it is under 25 KB and ≤ 200 lines with full entry/body parity; an
  over-budget index fails the lint. (FR-1)

---

## 5. Data and formats

- **Index line:** `- [Title](relative/body.md) — ≤1-line hook`. No per-entry heading.
- **Doc-store layout:** `doc-store/{brainstorms,handoffs,solutions,…}/`, one
  subdirectory per doc-type, each git-tracked.
- **Collection naming:** `claude-memory`, `claude-<type>` (e.g. `claude-brainstorms`).
- **Reflect log:** the existing single-line tally is extended additively with
  `captured=` and `embedded=` counts (a schema change any log parser must track).

---

## 6. Non-functional behavior

- **Latency:** seeded recall is on the synchronous first-prompt path and must stay
  fast (lexical search + hard timeout); the slow semantic path is excluded there.
- **Durability:** all memory bodies and captured docs are git-tracked → every capture
  and the index migration are reversible.
- **Isolation:** reconciler tests and the pre-merge harness run against a throwaway
  QMD config, never the operator's live `~/.config/qmd/index.yml`.
- **Fail-safe:** every QMD interaction degrades silently to the file-on-disk path on
  error/timeout/absence.
- **Silence:** reflect's added behavior preserves its silent, log-only operation.

---

## 7. Out of scope

- The global QMD embedding backlog and the existing openclaw collections — untouched.
- Semantic (model-loading) recall on the blocking first-prompt path.
- Changes to the memory-type taxonomy or reflect's prune/merge rules.
- Live, cross-session runtime validation in-worktree — the edited skill and hooks
  only take effect after merge to `main`; pre-merge verification is via the U7 test
  harness against an isolated config.
- Capturing doc-types beyond brainstorms / handoffs / solutions (additive later — the
  reconciler auto-registers any new subdirectory).
```
