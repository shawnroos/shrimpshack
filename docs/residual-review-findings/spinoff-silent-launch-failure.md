# Residual review findings — spinoff silent launch failure

Branch `fix/spinoff-silent-launch-failure`. Reviewed by three independently
dispatched lenses (correctness, adversarial, testing) against base `5cd4dc0`.
Everything actionable was applied except the items below.

## Open — needs a decision

### The forced `--launcher` route into the same defect class

**Both the correctness and the adversarial reviewer found this independently.**

The gate closes the *environment-announcement* route into "asked to launch,
launched nothing, reported success". It leaves the *explicit-flag* route open.

`--launcher herdr` in a session where no env var announced anything: the probe
fails, the run prints `⚠ … falling back to auto-detection`, nothing launches, and
the summary block says `✓ Spinoff complete` and `no multiplexer announced this
session` — which is false on its face given the flag the user just passed — at
exit 0. A background agent relaying that run reports done.

This is the same defect class the change exists to close, and closing only the env
route is itself the enumeration the design argues against. It was excluded because
the confirmed scope was env announcements, and because that path does print a
visible warning — but the warning scrolls past while the relayed summary claims
success.

**Both reviewers proposed the same fix:** capture the flag before
`resolve_launcher` overwrites `$LAUNCHER`, and record a non-`auto` value through
`_record_loud` so it flows through the same gate.

**Why it wasn't just done:** it changes `--launcher X` in an unannounced session
from exit 0 to exit 5, which is real user-visible blast radius beyond the
confirmed scope. That is a scope call, not a code call.

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
- **The non-herdr exit-5 branch is unreachable today.** Reaching it needs a backend
  that is announced, resolves, and fails a probe; `_cmux_probe` is binary-only, so a
  resolved cmux always launches. The generic wording exists for the next backend and
  has never executed. Noted rather than deleted — deleting it would re-narrow the
  gate to herdr.
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
