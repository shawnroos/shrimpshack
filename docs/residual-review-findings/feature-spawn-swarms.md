# Residual review findings — feature/spawn-swarms

Run context: the spawn `team` surface (plan
`docs/plans/2026-08-14-001-feat-spawn-swarms-plan.md`), 26 commits, release gate
725 declared / 725 passing / 2 gated skips. Reviewed by a code-review roster
(correctness, security), a three-lens simplification pass (reuse, quality,
efficiency), and a thermo-nuclear maintainability review on Fable.

Everything below is either **not fixed** or **fixed but worth carrying**. Findings
that were fixed and closed are in the commit messages, not here.

---

## Not fixed — decided, with reasons

### A shared `atomic_replace` between `team-record.sh` and `jobs.sh`
Both do write-to-temp-then-`mv`-with-cleanup. The shared part is **one line**;
the surrounding failure handling genuinely differs (`jobs.sh` returns a bare 1,
`team-record.sh` sets `SPAWN_TEAM_ERROR` and emits a diagnostic). A helper
wrapping one builtin would put indirection between the write chokepoint and its
own error reporting, and would pull `jobs.sh` — outside this plan — into the
diff. The reviewer rated it "small, real, not urgent."

### `team.sh --describe` declares `exit_codes` with no `origin` field
Its siblings declare `origin: own|propagated`. Nothing is wrong today because
`team.sh` propagates nothing — but **the first code it inherits from `bg-agent`
will be indistinguishable from one it raises itself**, and whoever adds it will
not be told. Contract shape, not a defect.

### The `roster` verb has no production caller
Verified: no command, skill, hook or script invokes `team.sh roster` — only test
fixtures. It is nonetheless a fully declared verb in `--describe`, and it carries
its own member-declaration grammar (`--member`/`--alias`/`--contract`, ~50 lines)
that duplicates the team file's JSON grammar. **Two ways to state a member, one
consumed by nobody.** Options in preference order: (a) make it take
`--team-file`, deleting the CLI grammar; (b) keep it and say plainly it is a
fixture/debugging verb; (c) drop it from `--describe` so it is not contract.
Shipping it silently as first-class contract is the one wrong option — this
record is that disclosure.

### `J1` — multi-field member write (the deepest complexity deletion available)
`team_launch_member` makes **four sequential single-field record writes** per
member; `team_probe_member` adds up to three more per member per advance. Each is
a full read → recompute of the entire derived block → atomic write. The code then
spends **three separate comments** defending the ORDER between those writes —
each documenting a torn-record window that exists only because the writes are
torn.

Making `spawn::team_member_set` take field/value PAIRS applied in one write is
constraint-compatible (still one chokepoint, still recomputed immediately before
the one write) and **deletes the windows instead of documenting them**: "a reader
must never see `dispatched` with no handle" becomes structurally impossible.
Seam to cut: change the signature to accept pairs, keep single-pair calls
working, collapse the call sites, then delete the three ordering comments — they
are the tell that the job is done. Deferred because it touches the record layer
with a PR imminent.

---

## Fixed, but the reason is worth keeping

### U10 shipped with an incomplete mutation pass — the only unit that did
Its worker hit a spend limit partway through. Its 18 assertions are green but
were never each driven red. On a branch where the mutation pass found **eight**
real defects, that is not a formality. Three of the 18 were later proven
load-bearing incidentally, when an optimisation broke them. The rest are
unproven. Follow-up: run a pass over `team-view.bats`, specifically the plan's
named check — switch the state source to a direct `status.json` read and confirm
the dead-pid and marker-mismatch scenarios turn red.

### Two `team-view.sh` footguns, found by a consumer rather than its own tests
1. `SPAWN_TEAM_VIEW_LIMIT` is read **at source time**. A consumer setting it
   after sourcing gets an inert assignment and the default of 10 — a team of
   11-12 renders silently truncated and reads as a *smaller* team. Shipped once
   and found by mutation, not by reading.
2. `team_epoch_of` lives in `team.sh`, not `team-view.sh`, so a standalone
   consumer gets a null `elapsed_seconds` on every row and no error.

Neither is reachable from `team-view.bats` as written — all 18 of its assertions
run through `team.sh`, where both gaps are masked.

---

## Environment / suite health, not this plan

### Four load-sensitive flakes, all in process-lifecycle tests
Green in isolation, red only under concurrent load:
- `supervisor.bats` — "KTD5: the job survives a TERM aimed at the launcher's process group"
- `setup-supervisor.bats` — "G3 self-test: a launcher that BAKES the token…"
- `setup-supervisor.bats` — "G3 self-test: a reload that skips the unload…"
- `setup-supervisor.bats` — "KTD1: the delivered key does NOT outlive startup"
- `setup-supervisor.bats` — "R28: a re-run is idempotent…"
- `lens.bats` — "timeout: the slow fixture past a short --timeout is code 6"

All are launchd bookkeeping or signal delivery. Direct-run bats cannot faithfully
reproduce launchd process bookkeeping, which is also why these are the tests most
sensitive to a loaded box. **A test that only fails when the machine is busy is
one people learn to re-run rather than trust**, and there are now six of them in
two suites.

### The bidi gap in `clean()` was fixed here, but the class is worth stating
`hooks/job-report.sh` stripped C0 control bytes with `tr` and stopped there, so a
Unicode bidi override (U+202E) survived into the user's prompt context. The file
carried its own weaker copy of a sanitiser while its comment already claimed the
shared chokepoint was the answer. Fixed by composing on `spawn::sanitize_for_display`.
The general form: **a byte-range strip is not a sanitiser**, and a private copy
of a shared chokepoint drifts below it silently.

---

## Gate enrolment — the pattern, and what remains

Every gate in this repo that **globs** auto-enrolled the new code and caught real
defects. Every gate that **enumerates** was silently incomplete at least once.
Fixed in this branch: the no-spend lint now globs `lib/team*.sh` (named, it
missed `team-view.sh` — 326 lines added in the same branch); `describe.bats` and
`envelope.bats` gained `team.sh`; the duplicate-body scan now walks `hooks/` as
well as `lib/`; `surfaces.bats`' "four declared verbs" test was renamed and
corrected to six (it was stale *before* this branch — `setup.md` had been the
fifth for a while).

Still enumerated, still worth converting:
- `describe.bats:65` `SCRIPTS=("$LENS" "$LAUNCH" "$CTL")` — every R10 / exit-code /
  remedy-source loop runs over those three only. `team.sh` and `bg-agent.sh` are
  each asserted separately instead.
- `surfaces.bats:91` — the six command names ARE the contract, so this one is
  correctly enumerated. Left as-is deliberately: **enumerate when the list is the
  claim, glob when the list is only a way of reaching things.**

## Two claims in shipped comments that were false, and are now measured

Recorded because both survived review as prose that read like measurement:
- `repo-bounded.settings.json` said "the deny list is the enforcement, the allow
  list is not." **Measured false**: removing a tool from `deny` leaves it
  not-allowed and still refused. Corrected, with the three-arm measurement in the
  comment.
- `ceilings.bats`' provenance said its live arm had been run and proved the shell
  channel closed. The run happened; the assertion was fabricable (a fixed
  sentinel a refused child can write with `Write`). Both arms now run green with
  an unfabricable nonce.
