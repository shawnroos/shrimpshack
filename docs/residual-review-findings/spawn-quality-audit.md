# spawn — thermo-nuclear quality audit, and what was applied

Audit run against `origin/main` (`f25f62e`) after PRs #30/#31/#32 landed.
Verdict: **does not clear the bar.** No behaviour bugs found — the correctness
engineering is strong — but the structure is accreting in the direction the
code's own comments warn against.

Work branch: `refactor/spawn-decomposition`.

## Applied and verified

| Finding | What | Evidence |
|---|---|---|
| **F4** | The models.json grammar normalizer (`safeobj` / `safe_families` / `safe_chain_policy`) was byte-identical in `spawnctl table_json`, `lens emit_describe`, `launch emit_describe`. Now `SPAWN_MODELS_GRAMMAR_JQ_DEF` in `common.sh`, which already hosted the alias half of the same job. Only the three defs are shared; each caller keeps its own projection, which genuinely varies. | `--describe` byte-identical to `origin/main` on all three surfaces (6859 / 6511 / 6710 bytes). 45 lines deleted. |
| **F5** | `BIN_CANDIDATES` + `find_binary_in` duplicated between `setup.sh` and `spawnctl.sh`, with a bats test asserting the two array lines stayed byte-identical. Both now `SPAWN_BIN_CANDIDATES` / `find_binary_in` in `common.sh`. | Code bodies were already identical (only comments differed). The byte-identity test was deleted with the duplication it guarded. |
| **F6** | The preflight-rewrap object shape was near-duplicated in `lens.sh` / `launch.sh` and **had already drifted once** (one emitted prose under `.detail`, the other under `.error`, breaking callers switching on `.error` — both files' comments narrate the incident). Now `spawn::preflight_jq <tier> '<null-fields>'`. | Preflight failure objects byte-identical to `origin/main` across four paths (lens/launch × unknown-alias/unreachable). |

The in-code rationale for F5 said the copy was safe because "sourcing
spawnctl.sh is not available". True, and beside the point — both files already
source `common.sh`, so the reason never applied to the place the code belonged.
**A test whose job is keeping two copies in sync is the module boundary telling
you it is in the wrong place.**

## NOT applied — needs a decision

- **F2 — `setup.sh` does not use the plugin's own response envelope.** Zero uses
  of `spawn::envelope_jq` / `enum_for_code` / `remedy_for`; it emits prose in
  `error`, with no `schema`, `detail`, `remedy` or `content_trust`, and
  hand-writes the JSON `spawn::envelope_bash` exists to own. `common.sh` says the
  envelope covers "every response from every script", and that prose-in-`error`
  is precisely what "broke every fan-out caller's `.error` switch at once". The
  newest and largest surface — whose consent flow (exit 8) most needs
  machine-branchable failures — skipped it.
  **Why it is not applied: it changes the emitted JSON shape.** It is the only
  non-behaviour-preserving item in the audit. Right call, but a contract
  decision.

- **F3 — the split: APPLIED on this branch.** `setup.sh` went from 2,937 to
  **831 lines**, split along the seams that already existed (`run_sub` was
  already re-invoking `setup.sh <verb>` as a child process, so the process
  boundary was there and only the file boundary was missing):
  `setup-supervisor.sh` (584), `setup-wire.sh` (579), `setup-lib.sh` (442),
  `setup-acquire.sh` (404), `setup-gw.sh` (257). Dispatch is now an `exec` per
  verb. No CLI surface changed and no test changed shape. Suite green
  throughout.

- **F1 — the `spawnctl run` verb: STILL OPEN.** `launcher_body` still generates
  ~150 lines that reimplement the control layer a third time: Keychain read,
  delivery-file rm/umask/chmod dance, pidfile claim, signal forwarding, reap.
  The tell remains: `write_launcher` **greps its own generated output** for
  load-bearing lines, because an unset variable can silently gut a heredoc. A
  generator that lints its own output is admitting the approach is wrong.
  **This is a live drift vector, not a style point** — and it has now bitten
  once for real. The 2026-08-10 P1 (`spawnctl start` overwriting the launcher's
  pidfile claim) is exactly the failure this duplication predicts: the launcher
  had the correct claim guard, `spawnctl` did not, because the same logic lives
  in two places. That P1 is fixed on both sides, but the divergence that
  produced it is still there.
  Proposed fix unchanged: a `spawnctl run` verb (foreground supervision, argv
  passthrough) so the launcher becomes a few baked lines ending in
  `exec … spawnctl run --`, the same shape `gw` already has.
  **Note the tension:** that verb ADDS lines to `spawnctl.sh`, which is already
  the one file over the 1,000 bar (see below). Decide the two together.

- **F7** — `/anthropic` route knowledge is trimmed by consumers (`setup.sh` twice)
  instead of served by its owner. Fix: `ensure`/`start` report `root_url`
  alongside `base_url`; both trims and both explanatory paragraphs vanish.

- **F8** — the test suite has no shared helper file: every bats file opens with a
  40-92-line `setup()`, `seed_keychain()` is redefined in 8 files,
  `SPAWN_SECURITY_BIN` wired in 10. **This is a safety issue, not tidiness** —
  those per-file blocks are the rails that stop tests writing the operator's real
  `~/.gateway.pid` (setup-supervisor.bats documents a "FOURTH RAIL" added for
  exactly that). A new bats file that forgets one touches the real machine.
  Fix: `tests/helpers/sandbox.bash` owning `spawn_sandbox`, `seed_keychain`,
  `wire_fake_security`, `wire_fake_launchd`, `make_install`.

## CORRECTED: the suite is deterministic; the flake was mine

An earlier version of this document recorded `tests/unit/setup-supervisor.bats`
as intermittently failing in full-suite runs and called it a blocker. **That was
wrong, and the cause was my own overlapping suite runs.**

Evidence for the correction, on the split tree (`e66b23a`), machine verified
idle before each run (`bats`/`run-tests.sh`/`fake-gateway` all zero, stale
`gateway-tests.*` TMPDIRs cleared):

    run 1: 370 passing, 0 failing
    run 2: 370 passing, 0 failing
    run 3: 370 passing, 0 failing

All three included the full 34-test setup-supervisor.bats — the suite that was
supposedly flaky. The two earlier failing runs both overlapped other suite
activity, and they failed DIFFERENT tests each time (13/18/28/34, then 22),
which is what contention looks like, not a deterministic defect.

A related hypothesis was also tested and eliminated: that a bats suite was
leaking past its `SPAWN_STATE_HOME` rail and writing the operator's real
`~/.gateway.pid`. Four suites carry no rail (fixtures, secrets, setup-wiring,
surfaces) but none of them executes the gateway — setup-wiring's spawnctl
reference is a comment, surfaces' two are static string checks on command files.
The rails hold. Consolidating them (F8) is still worth doing for maintainability,
but it is not fixing a live leak.

**Do not use "the known flake" to wave through a red supervisor run.** There is
no known flake. A failure there is a real failure — check for a concurrent suite
run first, then treat it as a defect.

## DECIDED: `spawnctl.sh` stays one file, for now

`spawnctl.sh` is **1767 lines total — but 925 lines of code**, with 743 lines
of comment and 99 blank. (These are CHECKED by tests/unit/surfaces.bats on every suite run — if
the file changes and the doc does not, the suite goes red and names both
numbers. They drifted three times by hand before that gate existed. They moved
during the 2026-08-10
review round, from 1,683/902, as guards were added for a P1 and four P2s. If
they have drifted again, recount rather than trusting this line.)

That distinction is not special pleading; it is **the audit's own yardstick**.
When this document called `setup.sh` a size problem it said so explicitly:
"2,912 lines, ~2.9x the bar **on code lines alone**; comment density does not
explain it away." Applied honestly in the other direction, `spawnctl.sh` is
under the bar on the measure this audit chose before it knew the answer.

**The margin is now thinner, and that matters.** At 926 code lines it is
within 75 of the bar it is being argued past. This decision should be
re-taken, not re-quoted, the next time this file grows — and F1's `spawnctl run`
verb would grow it.

The comments are not padding. They are the incident record — why the pidfile
carries a `.bin` sibling, why the probe keys on PROBE_LISTENING rather than
EX_OK, why the token is delivered through a mode-0600 file instead of the
environment, why `stop` refuses when a launchd job supervises the process.
Deleting them to make a line count look better would destroy the most valuable
thing in the file.

**The seam that does exist, named so the next reader does not have to find it.**
The file divides where the verb dispatch begins: primitives above (config and
install resolution, probe, lock, pid identity, token resolution, secret
delivery, start), verbs below (dispatch, and the envelope each verb emits).

It is NOT cut today because, unlike `setup.sh`, there is no process boundary
already there: `run_sub` had setup re-invoking itself as a child, so that split
only had to follow a seam the code was already using. Splitting here would be
inventing one, and inventing a boundary through shared mutable state (PROBE_*,
SPAWN_TOKEN_*, STARTED, the lock) is how the next drift gets introduced rather
than prevented.

## Decisions on the remaining audit findings

* **F1 (`spawnctl run` verb) — OPEN, deliberately.** It is the right fix and it
  is not small: it removes the third copy of the control layer, and the P1 this
  session proves the duplication is live rather than theoretical. It also
  changes what the launchd launcher execs on a machine that is currently
  adopted and working. Doing it in the same session that just changed `stop`,
  `start` and the supervisor step would stack four behaviour changes on the one
  path that is hardest to verify without a reboot.
* **F2 (envelope adoption in `setup.sh`) — OPEN, needs a call that is not
  mine.** It changes the emitted JSON shape. Every other item in this audit is
  behaviour-preserving; this one is a contract change, and the plugin's callers
  include commands and skills that switch on these fields.
* **F7 (`root_url` from its owner) — OPEN, small.** Cosmetic-adjacent: two
  trims and two explanatory paragraphs vanish. No correctness impact.
* **F8 (shared test sandbox helper) — OPEN, and downgraded.** The audit called
  it a safety issue on the belief that an unrailed suite could write the
  operator's real `~/.gateway.pid`. That belief was tested and is FALSE (see the
  correction above): the four unrailed suites never execute the gateway. It is
  now a maintainability item, which is a different priority.

## Recommended order

1. **F1 + the `spawnctl.sh` size question, together** — the `run` verb removes
   the third copy of the control layer but grows the one file already over the
   bar. Taking them as one decision is the only way either answer is coherent.
2. **F2** — envelope adoption, once the shape change is agreed. It is the only
   non-behaviour-preserving item here.
3. **F7** — `root_url` from its owner.
4. **F8** — the shared test sandbox helper. Worth doing for maintainability;
   note it is NOT fixing a live rail leak (see the correction above).

## Credit where due

The audit called out, and I agree: the security discipline (no credential in
argv, xtrace guards, chokepoint sanitization, ownership-checked locks and
pidfiles), the frozen exit-code contract, and the envelope/enum work in
`common.sh` are genuinely strong. The fixture layer (`fake-security.sh`,
`fake-gateway.py`) reproduces real tool traps including exit 44/45 and ships
planted defects. The problems above are structural, not correctness.
