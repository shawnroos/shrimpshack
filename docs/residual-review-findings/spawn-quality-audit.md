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

- **F1 + F3 — the flagship.** `launcher_body` (`setup.sh:1239-1391`) generates
  ~150 lines that reimplement the control layer a **third** time: Keychain read,
  delivery-file rm/umask/chmod dance, pidfile claim, signal forwarding, reap.
  `setup.sh:844`'s own header says reimplementing control logic "would be a
  fourth copy of control logic in a plugin that already carries the scar of three
  copies of one parser" — and then it does exactly that. The tell: `write_launcher`
  **greps its own generated output** for load-bearing lines, because an unset
  variable can silently gut a heredoc. A generator that lints its own output is
  admitting the approach is wrong.
  **This is a live drift vector, not a style point:** a fix to `deliver_secrets`
  does not reach launchd-started gateways until the operator re-runs setup,
  because the logic is frozen into a file on disk.
  Proposed: a `spawnctl run` verb (foreground supervision, argv passthrough), so
  the launcher becomes a few baked lines ending in `exec … spawnctl run --`, the
  same shape `gw` already has. Then split `setup.sh` along the seams that
  **already exist** — `run_sub` re-invokes `setup.sh <verb>` as a child process,
  so the process boundary is there and only the file boundary is missing:
  `setup.sh` (dispatcher/orchestrator), `setup-acquire.sh`, `setup-gw.sh`,
  `setup-supervisor.sh`, `setup-wire.sh`, `setup-lib.sh`. Changes no CLI surface
  and no test. Deletes the `ORCHESTRATING` mode switch and the dual-personality
  `die()` rather than relocating them.

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

## Blocker for the remaining work: the suite is non-deterministic

`tests/unit/setup-supervisor.bats` passes **34/34 in isolation** and
intermittently fails inside full-suite runs.

Observed twice:
- Run A (unmodified `main`, before any refactor): 4 failures — tests 13, 18, 28, 34
- Run B (after F6): 1 failure — test 22

**Every failure is the same assertion**: `[ "$RC" -eq 0 ]`, i.e. `run_supervisor`
returning non-zero. Different tests each time. Never in isolation. Present on
unmodified main, so it is not caused by the refactor.

Likely timing/resource sensitivity: the supervisor path probes and waits, and the
launcher carries a TTL cleanup (`sleep "$DELIVERY_TTL"`, `setup.sh:1349`; the
comment at :1305 describes a forked `( sleep N; rm )`).

**This should be fixed before the F1/F3 decomposition, not after.** The suite is
the release gate and the only arbiter for a behaviour-preserving refactor. A gate
that intermittently reports failures you did not cause is how a real regression
gets waved through as "probably the flaky one". F8 may well be the fix rather
than merely tidiness — if the rails are 17 separate disciplines, a cross-suite
shared-state collision is exactly this shape.

Also worth noting: the full suite now takes **over 10 minutes**. A gate that slow
stops being run.

## Recommended order

1. **Suite determinism** — reproduce the `run_supervisor` non-zero under load,
   fix it, ideally via F8's shared sandbox helper.
2. **F1 + F3** — `spawnctl run` verb, then split `setup.sh`. This is the only
   thing that fixes the size blocker (`setup.sh` is 2,912 lines, ~2.9x the bar
   on code lines alone; comment density does not explain it away).
3. **F2** — envelope adoption, once the shape change is agreed.
4. **F7** — `root_url` from its owner.

## Credit where due

The audit called out, and I agree: the security discipline (no credential in
argv, xtrace guards, chokepoint sanitization, ownership-checked locks and
pidfiles), the frozen exit-code contract, and the envelope/enum work in
`common.sh` are genuinely strong. The fixture layer (`fake-security.sh`,
`fake-gateway.py`) reproduces real tool traps including exit 44/45 and ships
planted defects. The problems above are structural, not correctness.
