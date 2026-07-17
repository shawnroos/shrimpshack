---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
origin: docs/handoff.md
title: "fix: seeded-recall must degrade, not tax every prompt, when qmd is slow/wedged"
created: 2026-07-17
plan_type: fix
depth: standard
---

# fix: seeded-recall must degrade, not tax every prompt, when qmd is slow/wedged

## Product Contract

### Summary

Make the reflect plugin's seeded-recall hook cost a failing qmd **once per cooldown
window**, not once per prompt. Give the guard a notion of *failure* (today it only
remembers *success*), kill qmd's whole process group on timeout so nothing is
orphaned, and lower the default wall budget so the script exits cleanly under the 8s
hook ceiling instead of being harness-killed. Scope is the plugin; fixing qmd's own
slowness (24,859 pending embeddings) is out.

### Problem Frame

Diagnosed live on 2026-07-17. Shawn thought his Enter key was broken — every prompt
stalled ~8s. Root cause: `hooks/seeded-recall.sh` runs a `qmd vsearch` on the first
prompt of a session, and against the current index that call takes ~23s (measured),
far over its budget. The hook is killed at the 8s registration ceiling.

The once-per-session guard is the aggravator. The flag that says "recall already ran
this session" is *checked* at `seeded-recall.sh:100-104` but only *written* at
`seeded-recall.sh:278-283`, after output is successfully built. This is deliberate
(comment at `seeded-recall.sh:95-98`): a cold/timed-out first prompt should not
disable recall for the whole session — it should retry next prompt. That reasoning is
sound against a **transient** failure. Against a **persistently** slow/wedged qmd it
never arms, so "retry next prompt" becomes a per-prompt tax for the life of the
session — and, because nothing is remembered across sessions, for every future session
too.

Two findings from live reproduction (stub `qmd` that sleeps forever, placed on PATH)
refine the handoff's diagnosis:

1. **The internal budget mostly holds.** With `SEEDED_RECALL_TIMEOUT=7` the hook exits
   at 7.08s; with `=2`, at 2.09s. So `run()` does bound total wall time. The measured
   8.15s overrun is the thin 1s margin between the default budget (7) and the hook
   ceiling (8): any kill latency or tail call breaches 8 and the harness kills it.
   The fix is headroom, not a budget-accounting bug.
2. **qmd children are orphaned on timeout.** `subprocess.run(timeout=)` SIGKILLs only
   the direct child, not its process group. A wedged qmd that spawned model-loader
   subprocesses leaves them running after the hook exits — reproduced as 2 orphaned
   processes per invocation. They accumulate.

Recall is a nice-to-have. It must never sit in the critical path of typing.

### Requirements

- **R1** — A slow/absent/wedged qmd must not cost more than a small bounded number of
  probes (default 2 consecutive failures) per cooldown window. Once the cooldown is
  armed, repeated prompts in the same session, and new sessions during the cooldown,
  must return instantly with no qmd call.
- **R2** — The guard must self-heal: when qmd recovers, recall must resume
  automatically once the cooldown lapses, with no manual reset.
- **R3** — The hook must exit on its own terms under the 8s registration ceiling — no
  harness kill — with comfortable headroom, not a 1s margin.
- **R4** — No qmd child (or grandchild) may outlive the hook. Timeout must terminate
  the whole process group.
- **R5** — The healthy path is unchanged: when qmd is responsive, recall fires exactly
  as it does today (once per session, same bodies, same wrapper), and the existing
  harness assertions still pass.
- **R6** — Every fail-open guarantee is preserved: any error, missing binary, timeout,
  or unreadable stamp exits 0 with no output and never blocks the prompt.
- **R7** — Ship it: bump `.claude-plugin/plugin.json` and the shrimpshack marketplace
  entry in sync so the store pulls the new version.

### Scope Boundaries

**In scope**
- The failure-memory guard (cooldown stamp), process-group kill, and budget headroom
  in `hooks/seeded-recall.sh`.
- Test coverage for the wedged path (stub qmd) and preservation of the healthy path.
- Version bump + marketplace sync.

**Out of scope**
- Fixing qmd itself — the pending embeddings, the 23s vsearch, the 1.9 GB index. That
  is a separate job. This plan makes recall *degrade gracefully* while qmd is slow; it
  does not make recall *work well* on this machine.
- Making recall asynchronous / off the UserPromptSubmit critical path. A real option
  (see Open Questions) but a larger redesign, deferred.
- Touching Shawn's global `settings.json` (the stop-the-bleeding timeout cap / hook
  disable). The durable fix lives in the plugin.

#### Deferred to Follow-Up Work
- Warm-daemon qmd upgrade to remove the per-process cold model load (already noted in
  `scripts/spikes/RESULTS.md`).

---

## Planning Contract

### Key Technical Decisions

**KTD1 — Cross-session failure stamp with a TTL cooldown (subsumes session-only
arming).** On a qmd *health* failure, record it in a single stamp file carrying the
failure time and a consecutive-failure count. At hook entry, before any qmd call, if a
*fresh* stamp exists (age < TTL) **and** its count has reached the arming threshold,
exit immediately. This one mechanism covers both the per-prompt tax (later prompts in a
session see the armed stamp) and the per-session tax (a new session sees it too), and
self-heals when the stamp ages out and recall re-probes. Chosen over session-only
arming (which pays one full probe per new session) because it is the only option that
makes typing feel instant on a persistently-wedged machine, and it is deterministic —
no probabilistic liveness guessing. Confirmed with Shawn on 2026-07-17.

- **Arm on the second consecutive failure, not the first (threshold 2).** The original
  retry-next-prompt design was explicitly sound against a *transient* failure (a
  one-off busy qmd, a load spike, a `qmd embed` running in the background). A stamp
  armed on the *first* failure would reverse that: one blip would black out recall for
  the whole TTL across every session. So the first failure records count=1 and does
  **not** suppress — the next prompt still probes; only a second consecutive failure
  (count≥2) arms the cooldown. This preserves transient tolerance while still capping a
  persistently-wedged qmd at 2 probes, then silence. A success resets the count. This
  is why R1 says "a small bounded number of probes," not "exactly one." Threshold
  tunable via `SEEDED_RECALL_FAIL_THRESHOLD` (default 2).
- **Only a genuine qmd-health signal counts as a failure.** The vsearch-level failure —
  `run()` returning `None` at `seeded-recall.sh:130-131` (missing binary, timeout,
  non-zero exit, unparseable JSON) — increments the count. A legitimate empty result
  (score floor / scope filter drops everything, `seeded-recall.sh:149`/`:244`), and the
  downstream get-loop producing no blocks (`seeded-recall.sh:264-265`), do **not** —
  those are "qmd answered, nothing matched / bodies unavailable," not "qmd is
  unhealthy." Stamping them would let a partial-budget fetch or a genuine no-match poison
  the cooldown on a healthy machine.
- Default TTL: **600s (10 min)** — long enough to spare a session from re-probing a
  still-wedged qmd, short enough that recovery is picked up within minutes. Tunable via
  `SEEDED_RECALL_COOLDOWN`.
- Stamp lives alongside the existing session flags, under `SEEDED_RECALL_FLAG_DIR`
  (default `$TMPDIR/claude-seeded-recall`), at a fixed non-session-keyed name so it is
  shared across sessions. Both read and write are best-effort: an unreadable or
  unwritable stamp fails open to today's behavior (R6).
- `SEEDED_RECALL_FORCE=1` bypasses the cooldown as well as the session flag, so tests
  and manual runs are unaffected.

**KTD2 — Reject the liveness pre-check (handoff option c).** A `qmd --version`/`status`
probe returns in ~0.3s on this machine while the real `vsearch` burns ~23s — the probe
passes and predicts nothing. It would add latency and catch nothing. The cooldown
stamp is the correct "is qmd worth trying" signal because it is grounded in the last
*real* query's outcome, not a cheap proxy.

**KTD3 — Run qmd in its own process group; kill the group on timeout.** Start each qmd
subprocess in a new session/process group (`start_new_session=True`) and, on
`TimeoutExpired`, send the terminating signal to the whole group before failing open.
This closes the orphan leak (R4). Prefer a brief `SIGTERM`→short-wait→`SIGKILL`
escalation so a qmd that respects signals can exit cleanly, with `SIGKILL` as the
backstop for a truly wedged one.

**KTD4 — Get sub-ceiling headroom from the process-group kill, not from cutting the
budget.** The 8.15s breach was *kill latency* — `subprocess.run` waiting on a wedged
child — which KTD3's near-instant process-group teardown removes. So the clean-exit fix
lives in U2, not in a lower budget. Do **not** drop the budget to 4: the hook header
records healthy `vsearch` at **p50 ~4s**, and the budget is the *total* wall across
vsearch + K `qmd get`s + `qmd status`. A 4s budget would starve the median query on a
healthy qmd — recall produces nothing (violating R5), and via KTD1 that timeout would
count toward arming the cooldown and silently suppress recall for the TTL. Set the
default to **6**: above the healthy vsearch p50 (leaving room for the follow-on gets),
and comfortably under the 8s ceiling even after the bounded SIGTERM→SIGKILL escalation
(worst case ≈ budget + a fixed sub-second wait). The env override is unchanged, and the
harness's own `SEEDED_RECALL_TIMEOUT=60` for the healthy tests is unaffected. The
registration ceiling in `.claude/hooks/hooks.json` stays at 8.

- **Validate the number against measured healthy latency, not the wedged 23s.** 6 is a
  reasoned default from the header's p50; the honest input is the healthy *full-path*
  (vsearch + K gets + status) p50/p90 on a working qmd, which isn't measured yet. Treat
  6 as a starting default and confirm/adjust it during implementation from a real
  healthy measurement (execution note in U3). The 23.7s figure is the wedged-index
  pathology and must not set this number.

### Assumptions

- The stamp being in `$TMPDIR` (cleared on reboot) is acceptable — a reboot is a fine
  moment to re-probe qmd afresh; the cooldown is a short-lived circuit breaker, not
  durable config.
- A single global stamp (not per-collection) is right: the hook targets one collection
  (`claude-memory`) by default, and a wedged store wedges all of it.

---

## Implementation Units

### U1. Failure-memory guard: cooldown stamp with TTL

**Goal:** Give the guard a memory of failure so a slow/wedged qmd costs one probe per
cooldown window, not one per prompt — and self-heals on recovery. (R1, R2, R6)

**Dependencies:** none.

**Files:** `hooks/seeded-recall.sh`, `tests/harness.sh`.

**Approach:**
- Add `SEEDED_RECALL_COOLDOWN` (default 600) and `SEEDED_RECALL_FAIL_THRESHOLD`
  (default 2) parsing alongside the existing env knobs (near `seeded-recall.sh:65-93`),
  with the same fail-safe int/float coercion the other knobs use.
- Define a fixed stamp path under `flag_dir` (non-session-keyed, e.g. a constant
  basename) so it is shared across sessions. The stamp carries a failure count and the
  last-failure time — simplest form is a tiny JSON/text payload (`count`, `ts`); read is
  fail-open (any parse problem → treat as no stamp).
- **Entry check** (after the session-flag check at `seeded-recall.sh:100-104`, still
  before `deadline`/`run()`): if `not force` and a fresh stamp exists
  (`now - ts < cooldown`) **and** `count >= threshold`, `out_nothing()`. A fresh stamp
  with `count == 1` does **not** suppress — the probe proceeds (transient tolerance).
  Any exception → treat as no stamp (fail open).
- **Failure increment:** only the vsearch-level qmd-health failure — the `if not raw`
  after the `vsearch` call (`seeded-recall.sh:130-131`), reached when `run()` returned
  `None` (missing binary, timeout, non-zero exit, unparseable JSON) — increments the
  stamp count before `out_nothing()`. Centralize as a small `note_failure()` helper
  (best-effort: read current count, write count+1 and now). Do **not** increment on:
  empty prompt, guard already armed, a legitimate empty/filtered result set
  (`seeded-recall.sh:149`/`:244`), or the get-loop producing no blocks
  (`seeded-recall.sh:264-265`) — those are "qmd answered" states, not health failures
  (see KTD1). This is the sharp edge: stamping `:264` would let a partial-budget fetch
  suppress recall on a healthy machine.
- **Success clears the stamp:** when output is successfully built (the flag-write block
  at `seeded-recall.sh:278-283`), remove the stamp entirely, best-effort, so a recovered
  qmd resets the failure count and doesn't sit under a lingering cooldown.
- `SEEDED_RECALL_FORCE=1` bypasses the cooldown check (mirror the existing `force`
  handling for the session flag).

**Patterns to follow:** the existing best-effort `os.makedirs`/`open(flag,"w").close()`
flag write (`seeded-recall.sh:278-283`) and the `try/except → out_nothing()` fail-open
idiom used throughout.

**Execution note:** Add the wedged-path harness test first and watch it fail (it will:
today the second stub-wedged call still re-probes), then implement until it passes.

**Test scenarios** (in `tests/harness.sh`, new `== seeded-recall cooldown ==` block;
uses a **stub qmd** on PATH that `sleep`s, so it runs even without real qmd installed —
place it outside the `command -v qmd` gate):
- Wedged-qmd first prompt: stub qmd sleeps > budget; hook exits 0, no output, within
  budget+margin; stamp count is now 1. (R1, R6)
- **First failure does NOT suppress (transient tolerance):** a second call (different
  session_id) against the sleeping stub still *probes* — it does not short-circuit
  instantly. Distinguishes the threshold-2 design from arm-on-first. (R1, transient)
- **Cooldown arms on the second failure and suppresses (the core fix):** after two
  wedged calls, a third call with a *different* session_id and a would-sleep stub
  returns effectively instantly (well under the budget) with no output — proving no qmd
  call was made. Assert on small elapsed time. (R1)
- Cooldown honors `SEEDED_RECALL_FORCE=1`: a forced call still attempts qmd despite an
  armed stamp.
- Self-heal via success reset: after the stamp is armed, a call against a *healthy* fast
  stub qmd fires recall AND clears the stamp; a subsequent wedged call starts the count
  from zero again (not instantly suppressed). (R2)
- Self-heal via TTL: with `SEEDED_RECALL_COOLDOWN=0` (or tiny value + brief sleep), an
  armed stamp is treated as expired and the hook re-probes. (R2)
- Fail-open on unreadable stamp: point `SEEDED_RECALL_FLAG_DIR` at a path where the
  stamp can't be read/created; hook still behaves as today (exit 0, no crash). (R6)

**Verification:** the new cooldown block passes; the third-call elapsed-time assertion
is a small fraction of the first, and the second-call assertion confirms the probe
still ran (no premature suppression).

---

### U2. Process-group kill: no orphaned qmd children on timeout

**Goal:** Ensure a timed-out qmd leaves nothing running. (R4)

**Dependencies:** none (independent of U1; can land in either order).

**Files:** `hooks/seeded-recall.sh`, `tests/harness.sh`.

**Approach:**
- In `run()` (`seeded-recall.sh:108-120`), start the subprocess in a new process group
  (`start_new_session=True` on `subprocess.Popen`, or the `subprocess.run` equivalent).
  Because `subprocess.run`'s own timeout only kills the direct child, switch to a
  `Popen` + `communicate(timeout=...)` shape, and on `TimeoutExpired` signal the
  process **group** (`os.killpg(os.getpgid(child.pid), ...)`) rather than the child
  alone.
- Escalate: `SIGTERM` to the group, brief wait, then `SIGKILL` to the group as a
  backstop for a wedged qmd that ignores `SIGTERM`. Keep the escalation wait tiny so it
  doesn't eat the wall budget.
- Preserve `run()`'s contract exactly: returns stdout on success, `None` on any failure
  (missing binary, non-zero exit, timeout, budget spent). All existing callers are
  unchanged.

**Patterns to follow:** the current `try/except (FileNotFoundError,
subprocess.TimeoutExpired, OSError) → return None` block — keep the same exception
surface and return semantics; only the kill mechanics change.

**Execution note:** Add the orphan-count test first and watch it fail against the
current code (reproduced: 2 orphaned children), then implement the process-group kill.

**Test scenarios** (in `tests/harness.sh`, alongside U1's block — stub qmd that spawns
a background grandchild then sleeps):
- No orphans after timeout: after a wedged-stub call times out, assert zero surviving
  stub descendants (grep the process table for a unique stub marker; expect none). (R4)
- Clean exit code preserved: the timed-out call still exits 0 with no output. (R6)
- Healthy call unaffected: a fast stub qmd that returns output still yields stdout
  through the new `Popen` path (guards against the refactor breaking the success path).

**Verification:** the orphan assertion passes (0 survivors) where it failed before the
change.

---

### U3. Budget default: headroom without starving the healthy path

**Goal:** Keep the script exiting cleanly below the 8s ceiling (achieved by U2's fast
kill) while setting a default budget that does not regress recall on a healthy qmd. (R3,
R5)

**Dependencies:** U2 (the process-group kill is what buys the ceiling headroom; this
unit only sets the number).

**Files:** `hooks/seeded-recall.sh` (and its header comments).

**Approach:**
- Set the `SEEDED_RECALL_TIMEOUT` default to **6**, changing **both** encodings of the
  default: the `os.environ.get("SEEDED_RECALL_TIMEOUT", "7")` literal at
  `seeded-recall.sh:78` **and** the `budget = 7.0` `ValueError` fallback at
  `seeded-recall.sh:80` — otherwise a malformed env value silently falls back to the old
  7. Update the header/inline comments that cite 7 (`seeded-recall.sh:24`, `:70-80`) to
  state the rationale: headroom comes from U2's fast kill, and the budget must sit above
  healthy vsearch latency, not be minimized.
- Leave `.claude/hooks/hooks.json`'s `"timeout": 8` as-is.

**Execution note:** Before committing to 6, take one healthy-qmd measurement of the
full path (vsearch + K gets + status) p50/p90 and set the default just above p90 but
under `8 − escalation`. 6 is the reasoned starting point from the header's ~4s vsearch
p50; the measured full-path number governs. Do **not** derive it from the wedged 23.7s
figure.

**Test scenarios:** covered jointly by U1 (wedged path exits within budget+margin) and
U4 (the new unset-default healthy case). `Test expectation: none unique to the constant
— exercised by U1/U4 timing and behavior assertions.`

**Verification:** wedged-path test exits well under 8s; the U4 unset-default healthy
case fires recall and writes no failure stamp.

---

### U4. Preserve the healthy path (regression guard)

**Goal:** Prove the responsive-qmd behavior is byte-for-byte unchanged. (R5, R6)

**Dependencies:** U1, U2, U3.

**Files:** `tests/harness.sh` (existing `== seeded-recall hook ==` block — verify, do
not rewrite).

**Approach:** No production change. Run the existing harness recall assertions
(`tests/harness.sh:82-146`) against the modified hook and confirm they all still pass:
recall injects the relevant body, emits the wrapper, once-per-session suppression,
new-session re-fire, fail-safe when qmd absent, budget-exhausted no-output, no-output
first prompt does not burn the session, and the U6 activation-floor engage/filter
pair. The cooldown-stamp-clear-on-success (U1) must not break the once-per-session
assertion, and the `Popen` refactor (U2) must not change stdout on the success path.

**Test scenarios:**
- All existing `== seeded-recall hook ==` checks pass unchanged. (R5)
- Specifically re-confirm "once-per-session: same session_id re-fires nothing" — the
  new success-path stamp-clear must not disturb the session flag.
- Specifically re-confirm "no-output first prompt does not burn the session (retry
  fires)" — a *legitimate* no-match (score floor filters all results) must NOT
  increment the failure count; only genuine qmd-health failures do. This is the sharp
  edge of U1.
- **New — shipped-default is exercised (not just the harness's 60):** one healthy-path
  case that leaves `SEEDED_RECALL_TIMEOUT` **unset** (so the real default from U3
  applies) against a fast stub/real qmd whose full path completes within the default;
  assert recall fires AND no failure stamp is written. Without this, every existing
  healthy assertion pins `=60` and the default budget ships untested — the exact gap
  that let the budget=4 regression through in review. (R5)

**Verification:** `bash tests/harness.sh` is green end to end on a machine with a
healthy qmd, including the unset-default case.

---

### U5. Ship: version bump + marketplace sync

**Goal:** Publish the fix so the store pulls it. (R7)

**Dependencies:** U1–U4 landed and green.

**Files:** `.claude-plugin/plugin.json` (version), plus the shrimpshack vendored
marketplace entry for `reflect` (outside this repo — the monorepo's marketplace
manifest).

**Approach:** Bump `.claude-plugin/plugin.json` from `0.3.0` to the next version
(patch/minor per the nature of the change — a behavioral fix with a new env knob leans
minor: **0.4.0**) and update the marketplace entry to the same version in the same
change so they stay in sync (a mismatch means the store won't pull it — see memory
`project_shrimpshack_marketplace_publish_workflow`).

**Execution note:** version-gated publish; confirm both numbers match before release.
This is a release step, gated on the review loop being clean — not part of the code
diff under review.

**Test scenarios:** `Test expectation: none — release/config step.` Manual check: the
two version strings are identical.

**Verification:** the marketplace serves the bumped version; a fresh pull picks it up.

---

## Verification Contract

- `bash tests/harness.sh` passes end to end on a machine with a healthy qmd (U4).
- New cooldown + orphan tests, driven by a stub qmd, pass **without** requiring real
  qmd installed (they live outside the `command -v qmd` gate).
- Manual wedged-path check: with a `sleep`-forever `qmd` stub on PATH, the first two
  prompts exit 0 within ~budget (arming the cooldown on the second), the third prompt
  (any session) returns effectively instantly, and `pgrep` for the stub shows zero
  survivors.
- Self-heal check: after the cooldown lapses (or with `SEEDED_RECALL_COOLDOWN=0`), the
  hook probes qmd again.

## Definition of Done

- R1–R6 demonstrated by the harness (wedged path degrades to a bounded 2 probes then
  cooldown, tolerates a single transient failure, self-heals, no orphans, exits under
  the ceiling, healthy path unchanged including the shipped-default case, fail-open
  preserved).
- The new tests were each seen to fail once before passing (Shawn's standing rule).
- U5 released only after the review loop is clean: `.claude-plugin/plugin.json` and the
  marketplace entry bumped in sync.

---

## Open Questions

- **Should recall be on the synchronous UserPromptSubmit path at all?** Even with this
  fix, the first uncooled prompt of a session pays up to the budget. Making recall
  async (fire-and-forget, inject on a later turn) removes it from the typing critical
  path entirely — but it's a larger redesign. Deferred; revisit if the per-session
  first-prompt cost still annoys after this lands.
- **Stop-the-bleeding now?** Shawn was offered a global cap on `SEEDED_RECALL_TIMEOUT`
  or disabling the hook in `settings.json` while the durable fix lands. Not chosen, not
  touched here (out of scope by decision). Available on request.
- **Flat cooldown vs. back-off.** The TTL is a flat 600s: on a *persistently* wedged
  qmd, whichever prompt crosses each 10-minute boundary pays a full 2-probe stall,
  indefinitely, until qmd is fixed. A back-off (grow the TTL on repeated arming) would
  make a long-lived wedge cost less over time. Deferred as a tuning refinement — the
  flat cooldown already removes the per-prompt tax, which is the bug. Revisit if the
  10-minute re-probe stall itself becomes annoying.

## Sources & Research

- `docs/handoff.md` — origin diagnosis (directional; budget premise corrected here).
- Live reproduction 2026-07-17 (stub qmd on PATH): budget holds to ~budget+0.08s;
  orphaned children reproduced (2 per invocation); real `qmd vsearch` measured 23.7s
  against the current index while `qmd status`/`--version` return in <1.5s.
- `hooks/seeded-recall.sh` — guard check `:100-104`, deliberate-comment `:95-98`, flag
  write `:278-283`, budget `:70-80`/`:78`, `run()` `:108-120`, vsearch call
  `:129-131`.
- `.claude/hooks/hooks.json` — UserPromptSubmit registration, `"timeout": 8`.
- `tests/harness.sh` — isolated-config harness; existing recall block `:82-146`.
- Memories: `reference_qmd_breaks_on_node_upgrade_native_module` (the *other*,
  error-not-hang qmd failure — distinct from this), `feedback_reproduce_before_you_plan`,
  `feedback_deterministic_over_probabilistic_v1`,
  `feedback_new_tests_need_deliberate_fail_smoke_check`,
  `project_shrimpshack_marketplace_publish_workflow`.
