# Residual Review Findings

Branch `bugfix/launcher-path-guard`, reviewed against `origin/main` (`f0b5d35`).
Plan: `docs/plans/2026-08-03-002-fix-launcher-path-resolution-plan.md`.

Reviewers: correctness, adversarial (in-process fallback — no cross-provider peer CLI
is installed, so the adversarial lens did not run cross-model), plus ce-simplify-code's
reuse/quality/efficiency pass. Applied fixes landed in `89cfb35`. No tracker is
configured for this repo, so this file is the durable record.

## Not applied — scope

- **P2 · `spinoff.sh` (summary tail) · Announced-unresolvable herdr plus a
  dead-but-present cmux exits 3 with "not briefed" wording though nothing launched.**
  `_cmux_probe` only checks the binary is executable, so a present cmux with a dead
  server resolves, `BRIEF_ATTEMPTED=1`, no surface materializes, and the run reports
  the unbriefed-session message. Held out because exit 3 for a surface-creation failure
  is pre-existing intended behavior (see the `BRIEF_ATTEMPTED` comment) — changing it
  reshapes a contract this plan did not scope. The retained `LOUD_BIN` record also goes
  unmentioned on that path.

- **P3 · `spinoff.sh:_herdr_probe` · `grep -qi running` still rides PATH.** The probe
  pipes through `grep`, so a fully scrubbed PATH makes a live herdr read as dead and
  lands in the silent branch. Partially addressed: the header comment no longer claims
  every tool resolves absolutely. The pipe itself is untouched because the settled
  blast-radius decision scopes this change to the three launcher binaries. A `case`
  test on the captured output would remove the last dependency.

- **P3 · `cli-drift.test.sh` · The gate can verify a different herdr than a run
  resolves.** It finds its own binary rather than asking `resolve_bin`, so it can
  certify verbs on one install while the script drives another. Sourcing `spinoff.sh`
  under `SPINOFF_TEST_SOURCE=1` and calling `resolve_bin` would close the gap.

- **P3 · `spinoff.sh:_record_loud` · First-announcement-wins can name the wrong
  backend's fix.** With both backends announced and both unresolvable for different
  reasons (one missing, one a rejected override), only herdr is reported, so the user
  may get the less actionable of two diagnoses. Needs a call on printing all records
  versus preferring the one with a concrete fix.

## Not applied — from the plan's doc review

- **Have the skill resolve the launcher in the main session and pass `HERDR_BIN` into
  the background agent.** Strictly better than a candidate list: the dispatching session
  *does* have a working PATH, so this turns a guess into a fact and covers cargo, nix,
  `~/bin`, and dev builds that the three hardcoded directories miss. Held out because it
  expands the blast radius to `SKILL.md`'s dispatch block, which the settled
  launcher-binaries-only decision excludes. Worth revisiting as its own change.

- **Print the resolved path and how it was found on the success line**
  (`launcher: herdr (/opt/homebrew/bin/herdr — known location, not on PATH)`). The
  candidate list can now select a different binary than the caller's own PATH would, and
  nothing in the output says so. Additive scope; not applied.

## Testing gaps recorded, not closed

- The ghostty backend has no end-to-end or sourced coverage. The
  `command -v osascript` → `"${OSASCRIPT:-}"` switch inside `_ghostty_run` is unpinned,
  including the probe gate that keeps an empty-string exec unreachable.
- No test announces both backends with both unresolvable, so `_record_loud`'s
  first-wins precedence is unpinned (mutation-confirmed: deleting the guard leaves the
  suite green).
- No test covers a resolvable-but-wrong-binary override — the shape the warning's own
  remedy invites.
- No full-run test with a set, valid `*_BIN` override; that path is covered only at the
  resolver level.
- `cli-drift.test.sh`'s new override branch has no test of its own.
