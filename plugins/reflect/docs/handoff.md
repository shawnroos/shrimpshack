# Spinoff: reflect — a wedged qmd taxes EVERY prompt 8s (retry-forever guard)

> This handoff is directional — author intent and a starting point, not a spec.
> The code and tests are the source of truth; validate against them and refine.

## Goal
Make reflect's seeded-recall hook **degrade instead of taxing every prompt** when
qmd is unavailable. Today a wedged qmd costs Shawn ~8 seconds on *every single
prompt, for the life of the session*. Recall is a nice-to-have; it must never sit
in the critical path of typing.

Scope is the **reflect plugin only**. Fixing qmd itself is a separate, independent
job — don't chase it here beyond what's needed to test.

## Why now / context
Diagnosed live today. Shawn thought his Enter key was broken.

- `qmd --help` works (1.28s) — the binary loads fine.
- `qmd --version`, `qmd status` **hang forever** — anything touching the store wedges.
- `seeded-recall.sh` therefore burns its whole budget and gets killed at the 8s
  hook timeout. Every prompt. ~8s of nothing.

Note this is NOT the known node-native-module breakage (memory
`reference_qmd_breaks_on_node_upgrade_native_module`) — that **errors**, this
**hangs**. Different failure, different fix. Node is v26.4.0; qmd installed Jul 7.

## Key decisions already made / grounded diagnosis (verified in code)
- **The bug is the once-per-session guard arming only on success.** In
  `hooks/seeded-recall.sh`: the flag is *checked* at ~L99–103 but only *written* at
  ~L278–283, deliberately — the comment (~L96–98) says:
  > "The flag is checked here but WRITTEN only after we successfully build output —
  > so a cold/timed-out/empty first prompt does not disable recall for the rest of
  > the session; it simply retries on the next prompt."
  That's a sound design against a **transient** failure. Against a **permanently
  wedged** qmd it never arms, so retry-forever converts a one-time cost into a
  per-prompt tax. **The design isn't wrong — its failure taxonomy is incomplete:
  it has no notion of a persistent failure.** That's the thing to fix.
- **Timeouts are the symptom, not the cause.** `SEEDED_RECALL_TIMEOUT` defaults to
  **7** (`seeded-recall.sh` ~L24, ~L78) and the hook registration in
  `.claude/hooks/hooks.json` (UserPromptSubmit, ~L15–24) sets `"timeout": 8` — the
  script is *supposed* to self-bound under the hook ceiling. Measured 8.15s, i.e. it
  overran its own 7s budget and was killed by the harness. Worth understanding why
  the internal budget didn't hold (a `run()` call not drawing from the remaining
  budget? qmd ignoring SIGTERM on a wedged store?) before just lowering numbers.
- **Repo:** `/Users/shawnroos/projects/reflect`, currently `0.3.0`, published via the
  shrimpshack vendored monorepo (version-gated — bump `plugin.json` **and** the
  marketplace entry, keep them in sync, or the store won't pull it).

## Open questions / not yet decided
- **What's the right failure taxonomy?** Options, roughly escalating:
  (a) arm the guard on *persistent* failure too (e.g. after N consecutive failures,
      or on a failure that isn't "cold start"), so it self-disables for the session;
  (b) a circuit breaker with a short cross-session cooldown (a stamp file), so a
      wedged qmd doesn't re-probe every session either;
  (c) a fast liveness pre-check (a ~300ms `qmd` probe) before committing to the
      real query — cheap, and it's exactly the "is the store openable" question.
  (a) is the minimum; (c) is probably what makes it feel instant. Prefer
  deterministic over clever.
- **Why did the internal 7s budget not hold** (measured 8.15s)? Fix that too, or the
  script keeps getting harness-killed rather than exiting cleanly. Suspect the wedged
  qmd ignores the timeout signal — may need a hard kill.
- **Should recall ever block the prompt at all?** Worth asking whether this belongs
  on UserPromptSubmit synchronously. A ~1s ceiling might be the real answer.
- Shawn was offered "cap SEEDED_RECALL_TIMEOUT below 8s / disable the hook" as a
  stop-the-bleeding step and hasn't chosen — **check with him before touching global
  settings.** The durable fix lives in the plugin, not in his settings.json.

## Starting point
- `hooks/seeded-recall.sh` — the guard check (~L99–103), the deliberate comment
  (~L96–98), the flag write (~L278–283), the budget (~L70–80), `run()` (~L108+).
- `.claude/hooks/hooks.json` — UserPromptSubmit registration, `"timeout": 8`.
- Env knobs already present: `SEEDED_RECALL_TIMEOUT` (default 7),
  `SEEDED_RECALL_FLAG_DIR`, `SEEDED_RECALL_FORCE=1` (bypass guard — useful for tests).
- **Reproduce before fixing** — qmd is wedged *right now*, so the failure is live and
  free to observe. Also simulate it (a stub `qmd` on PATH that `sleep`s forever)
  so the test doesn't depend on a broken machine.
- See a new test fail once before it passes (Shawn's standing rule).
- Memories: `reference_qmd_breaks_on_node_upgrade_native_module` (the *other*,
  error-not-hang qmd failure), `feedback_reproduce_before_you_plan`,
  `feedback_deterministic_over_probabilistic_v1`,
  `feedback_new_tests_need_deliberate_fail_smoke_check`.

## Recommended next step
`/ce-plan`. The diagnosis is nailed and the fix space is small and well-bounded —
the only real fork is the failure-taxonomy choice above, which is a plan decision,
not a brainstorm. Plan it as: reproduce with a stub-wedged qmd → make the guard
handle persistent failure → make the budget actually hold → test both the wedged and
healthy paths → bump + publish.

## Source session
Transcript: `/Users/shawnroos/.claude/projects/-Users-shawnroos/d7fba74d-4df6-426b-aeea-a7f3c587a64a.jsonl`
Resume:     `cd /Users/shawnroos && claude -r d7fba74d-4df6-426b-aeea-a7f3c587a64a`
