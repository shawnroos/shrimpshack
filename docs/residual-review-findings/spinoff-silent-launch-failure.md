# Residual review findings — spinoff silent launch failure

Branch `fix/spinoff-silent-launch-failure`, reviewed twice against base `5cd4dc0`.

Round 1 (correctness, adversarial, testing) covered the original gate change.
Round 2 (correctness, adversarial; the testing lens timed out and returned nothing)
covered the forced-`--launcher` change, which round 1 never saw. Everything
actionable from both rounds was applied.

Round 2 earned its keep: the forced-flag change had introduced a regression on the
skill's own documented recovery, caught at confidence 100 by both lenses. Making the
flag win announcement precedence meant `--launcher ghostty` — which the skill tells
you to use when herdr's server is dead — replaced herdr's actionable diagnosis with
a ghostty message that had no remedy, at the same exit code. Fixed in `1a7e253`: a
forced backend that can name a binary is still recorded first, anything else defers
and only announces when nothing already has.

Two message defects came with it and are also fixed: exit 5 told every failed
`--launcher ghostty` that "the binary resolved fine" when ghostty's probe fails only
because something did *not* resolve, and the skill's exit table still described the
pre-flag contract.

Recurring lesson across both rounds, worth stating plainly: **four separate
assertions in these tests passed against the implementation they claimed to pin.**
Three matched strings the script prints for unrelated reasons (a worktree path in
the summary block, a flag name in the fall-back warning), one asserted the harmless
half of a sentence whose other half was false. Assert the text the change itself
emits, not a substring that happens to appear.

## Raised by review, now resolved

### ~~The forced `--launcher` route into the same defect class~~ — CLOSED

Both reviewers found this independently; it is now fixed rather than deferred.

`--launcher <backend>` is recorded as an announcement, ahead of the env vars so the
diagnosis names the flag the user typed rather than a variable they never set. The
flag route now lands on the same gate: exit 4 when the forced backend's binary is
missing, exit 5 when it resolved and refused. Previously `--launcher herdr` in an
unannounced session printed `no multiplexer announced this session` and a tick at
exit 0.

This also settles the KTD-9 note left at the ghostty resolution: ghostty's *env vars*
stay excluded (they are set for every Ghostty window and announce nothing), but the
*flag* is a deliberate request and enters the loud path. That makes the previously
unreachable non-herdr exit-5 branch reachable, so its wording is now exercised by a
test instead of being dead code.

### The probe's output string is now load-bearing

`_herdr_probe` greps `herdr status server` for `running`. It used to be a fallback
selector — a false negative cost a silent exit 0. It is now the sole determinant of
a hard exit 5. If herdr's wording changes, every spinoff from a healthy session
fails at exit 5. `cli-drift.test.sh` pins that the subcommand exists, not its
output.

Partly mitigated: both exit-5 messages now state what was *observed* ("did not
answer this process") rather than asserting a diagnosis. The adversarial reviewer
additionally suggested preferring the CLI's exit status over prose matching, or
widening the match. Not done — changing the probe is a behaviour change outside
this fix.

## Accepted, recorded, not fixed

- **`HERDR_ENV=1` is inherited by every child of a herdr session**, so any detached
  process that outlives the herdr server now hard-fails at exit 5 where it used to
  produce a worktree at exit 0. This is the change's intent, and it is the concrete
  thing users will feel.
- ~~**The non-herdr exit-5 branch is unreachable today.**~~ Fixed as a side effect of
  closing the flag route: `--launcher ghostty` with no usable ghostty now reaches it,
  so the generic wording is exercised by a test instead of being dead code. Still true
  for **cmux specifically** — `_cmux_probe` is binary-only, so a resolved cmux always
  launches and can never be the announced-and-refused backend.
- **A forced `--launcher herdr` whose probe fails runs `herdr status server`
  twice** (once in the forced case, once in detection). No correctness consequence.
- **Exit 5 is never asserted disjoint from exit 3.** The claim holds by
  construction (`BRIEF_ATTEMPTED` requires `LAUNCHER != none`); it is a
  documentation-vs-test gap, not a defect.

## Verified clean (traced, no finding)

- `ANNOUNCED_UNLAUNCHED` and `BRIEF_ATTEMPTED` cannot both be 1 — `$LAUNCHER` is
  assigned only inside `resolve_launcher` and during arg parsing, both strictly
  before the gate, and nothing in the launch region reassigns it.
- Exits 4 and 5 cannot both fire — the exit-4 block returns first and the selector
  partitions one variable.
- In the mixed-announcement run the exit-4 diagnostic names cmux while
  `ANNOUNCED_BIN` is herdr. Correct: fixing `CMUX_BIN` does restore a launch, and
  every string in the loud path reads `$LOUD_*`. Now pinned by a test.
- No consumer outside `SKILL.md`'s relay contract branches on this script's exit
  code. (Grep-based; a consumer expressed in prose would not appear.)
