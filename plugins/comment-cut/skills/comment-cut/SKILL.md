---
name: comment-cut
description: Cut comment bloat out of a branch without losing the comments that matter. Scopes the diff against a base ref, sweeps the mechanical classes, then works area by area doing the judgement cut, proving at every step that only comments changed. Use when a branch or PR has been flagged for comment bloat, when an AI-generated subtree has grown a high comment-to-code ratio, or when asked to apply a why-only comment bar to existing code. Not for writing new comments, and not a linter.
---

# comment-cut

Cut the comments that say nothing. Keep the ones that say what the code cannot.

Two failure modes, and the second is the sneaky one. Over-cutting destroys knowledge
silently — the gates below make that detectable. **Over-keeping hides behind the gates**:
every keep-rule that can be invoked loosely will be, and "tighten" quietly converts deletes
into rewrites. Measured on one real subtree: a pass with broad keep-rules removed 3,564
comment lines but re-added 3,132 as tightened rewrites — 88% of the deleted volume came
back in rewritten form. The keep side of this skill is therefore deliberately narrow:
few rules, each with a test that is hard to invoke loosely.

Version 0.2.0's tests were still too loose, and two independent model reviews found the same
hole: "without this, X happens and nothing tells you" admits almost anything, because almost
every defect is silent *to the compiler*. Each rule below now needs a failure nothing reports
**and** a tempting edit that would cause it.

## Before anything: resolve the bar

The keep/cut bar lives in the **target repo**, never in this plugin. Resolve in order:

1. an explicit `--bar <path>` argument
2. `.rulesync/rules/comment-essential-only.md`
3. `.claude/rules/comment-essential-only.md`

Error out if none resolve. Do not fall back to an embedded copy.

> Order matters. In repos using rulesync, `.claude/` is **generated output and gitignored** —
> the tracked source is `.rulesync/`. Defaulting to `.claude/` makes the skill abort on a fresh
> clone of the very repo it was built for.

**Precedence on extraction:** if the resolved bar contains an "extract rationale to docs/
then link" clause, this skill overrides it — see "No pointers" below. Everything else in the
resolved bar stands.

## Phase 1 — scope and measure

```bash
BASE=<merge-base or explicit ref>      # pin this; see the warning below
SCOPE=<path under which to cut>
git diff --name-only $BASE..HEAD -- $SCOPE
```

Count added comment lines per file and per area. Rank areas by total, not by ratio.

**Pin the endpoint.** If the branch will sync with a moving upstream during the pass, define the
cut set as `$BASE..<the commit you measured>`, not `$BASE..HEAD`. Otherwise every sync silently
enlarges the job with comments teammates just wrote, and "all mechanical classes are gone" can
never be honestly signed off.

**Ratio finds files. It does not set the cut — in either direction.** Never tell a worker to
expect a particular cut ratio, high or low. "Expect a lower ratio in load-bearing files" was
given as a brief instruction once; those areas then cut at half the rate of the rest
(34% and 31% vs 66%), costing an estimated 2,300–4,600 lines. The workers heard a target
and hit it. Load-bearing files are protected by the invariant-signal scan, not by a
pre-lowered expectation.

## Phase 2 — establish gates BEFORE cutting

Nothing below is optional. Each catches a class the others miss.

**a. Comments-only proof (the primary gate).** For every changed `.ts`/`.js` file, compare
minified output before and after:

```bash
esbuild --loader=ts --minify < before > a; esbuild --loader=ts --minify < after > b
```

Identical output proves no code, logic, **or string literal** changed. This is the only gate that
catches a worker quietly rewriting `describe()`/`it()` titles to strip ticket refs out of them —
which happened, 51 titles in one slice, and every other check passed clean. Test titles are
strings, and if the repo syncs them to a test-management tool, renaming one orphans its id.

For `.scss`/`.html`, strip comments from both versions and compare the remainder.

**b. Typecheck, re-baselined per slice.** Record the error set _after_ each upstream sync and
_before_ editing, then diff **sorted error lines**, not counts. A count comparison hides a swap
where a new error coincides with an old one disappearing. Check the exit code directly — never
pipe the compiler through `tail`, which replaces its exit status with the pager's.

Verify which project actually covers what. An app tsconfig frequently excludes specs; if specs are
in scope, they need their own run.

**c. Invariant-signal scan (the only gate for over-compression).** After each judgement slice,
grep the slice's **removed** comment lines for invariant language:

```
must | never | always | order | before | after | race | stale | guard
silent | invisible | otherwise | coordinate | space | threshold | measured
```

Every hit must be either preserved in a surviving comment or consciously justified.
**Verify semantically, not by string matching** — a reworded survivor is a pass, and grepping for
the original phrasing reports it as a loss. In one real slice this scan flagged 100 lines: most
were legitimate, one was instrumented field data (captured byte sizes and three measured reload
timings) deleted outright. Nothing else caught it.

A hit does NOT mean the line had to be kept — "must" in a sentence restating a type constraint
is still a restatement. The scan exists to make each loss a decision, not to veto deletion.

## Phase 3 — mechanical sweep

Deletions and ref-strips only. No judgement, no rewording. Run the bundled detector scoped to the
diff — **never repo-wide**, which reports pre-existing hits outside scope and can never reach zero:

```bash
git diff --name-only $BASE..HEAD -- $SCOPE | grep '\.ts$' | xargs tools/comment-cut/run.sh
```

The detector covers `.ts`-family extensions only; stylesheets and templates need explicit greps
covering `/* */` and `<!-- -->`, not just `//`.

**The ticket-ref position test — mechanical pass only.** In THIS pass, classify by position so
the dumb sweep never deletes a constraint riding on a ref:

| Shape                                                                     | Action                               |
| ------------------------------------------------------------------------- | ------------------------------------ |
| Opens the comment as a label — `WEB-2932 U4: <sentence>`                  | strip the ref, **keep the sentence** |
| Trailing citation — `...tracks a MEDIA layer (WEB-2957).`                 | strip the ref, keep the sentence     |
| Mid-sentence — `never schedules on Replicate (WEB-2729); so we long-poll` | **leave for phase 4**                |
| Referential — `see WEB-2988`, `tracked as WEB-2626`                       | **leave for phase 4**                |
| Nothing but history once the ref is gone                                  | delete the line                      |

The last two shapes are deferred, not kept: position is a safe classifier for a sweep, but it is
also the loophole — any writer can embed a ref mid-sentence ("the WEB-3008 fix", "per WEB-2932
review"). Phase 4 applies the real test.

Same for banner rules: strip the `──` decoration, keep any text it wrapped. Then **collapse the
double blank lines** the deletion leaves behind — otherwise the diff carries formatting noise the
repo did not have before.

## Phase 4 — judgement slices, area by area

One area per slice, gated and committed before the next.

**Calibrate first.** Cut one small high-ratio file, show the before/after, and get agreement on
depth before spending the rest. A worked example is worth more than any instruction.

**The default action is DELETE, not tighten.** Tightening is the single biggest retention
driver: it turns every 8-line essay into a 1–2-line survivor, and a one-liner on every
declaration is still JSDoc-per-declaration density. Tighten **only** when the surviving clause
passes a keep-rule below on its own. A clause that names a design choice, a gating
relationship, or what the code does is a restatement wearing a haircut — delete the block.

### Keep-rules. Four. Each has a test.

1. **Silent local footgun.** Two conditions, both required. **(a) Nothing reports it:**
   breaking this turns no test red, throws nothing, fails no compile, and no user or QA sees
   a wrong result. *A visible bug is not a silent failure — write the test instead.*
   **(b) There is a tempting edit:** name the locally plausible change that would cause it.
   The comment sits at that exact statement. *Test: if you cannot name the edit someone would
   reasonably make, there is no trap to warn about — delete it.* Almost every UI defect is
   silent to the compiler, which is why (a) alone admitted essays; (b) is what closes it.
2. **Measured evidence at a named constant.** The constant already carries the clearest
   domain name available, and the comment adds what a name cannot: the measured population or
   incident, the observed failure boundary, the unit or coordinate space when ambiguous, and
   the unsafe direction of change. *Test: strip the comment — does the name alone lose
   evidence, or only lose English?* A comment that restates the name in prose, narrates the
   formula, or asserts an adjective like "usable" is a restatement. Delete it.
   `BRUSH_SIZE_AT_1X = 0.08` with "zoom becomes the size control" is the archetype: the name
   already says it and no measurement is recorded.
3. **Specific external incompatibility.** A named upstream defect, undocumented behaviour,
   or version-sensitive quirk that makes the local code look unnecessary or wrong — name the
   browser, endpoint, library, runner or version, and the behaviour observed. *Test: does the
   code look like it could be simplified until you know this?* External provenance is
   necessary but not sufficient: "standalone components default to `display: inline`" is
   ordinary platform behaviour next to a `display: block` declaration that already says so.
   Teaching the framework is not a keep.
4. **External caller obligation.** On a symbol exported and used outside its owning
   subtree, and only where a caller must honour behaviour the type cannot express, and misuse
   is caught by neither compilation nor an existing test. *Test: name the consumer file AND
   the obligation it would violate.* Naming a consumer proves reach, not necessity — measured
   on one contract file, 2 of 41 JSDoc blocks passed the consumer test and neither passed
   this one. Prefer a stronger type over prose. A dictionary definition of a string-literal
   union, a default expressible in code, or a "read by X" pointer is not an obligation.

Everything else goes: restating the declaration or the language, narration of the next line,
design/rationale essays, alternative-history ("we tried X and removed it" compresses to the
one do-not-reintroduce clause **only if** it passes rule 1 or 3), banner headers,
commented-out code, changelog and attribution notes, **framework tutorials** (how Angular,
RxJS or the test runner works), **find-usages pointers** ("read by X", "fires on Y"),
**dictionary definitions of string-literal unions**, **file-header essays** cataloguing what a
file covers, and **design or review transcripts** — round labels, mutation records,
old-fixture histories, layout tours.

### Ticket ids and plan ids

An id survives phase 4 **only when it tracks skipped or disabled work** — `xit`'d specs under
an open ticket, "restore when WEB-XXXX lands". There the ticket IS the record of a live gap.
Everywhere else, strip the id and keep the sentence if the sentence passes a keep-rule bare.
"Sole pointer to a constraint recorded nowhere else" is not an exception — if the constraint
is real, state it in the comment; then the id adds nothing.

### Spec files — default zero

Specs were 56% of survivors on the measured subtree. The rule that gets them there is one
sentence, and it is the sharpest thing two independent reviews produced:

> **A red test is not a silent failure.**

If breaking the production code turns this test red, a comment explaining that invariant is
redundant *with the test itself*. Behaviour goes in the `it()` title, intent goes in fixture and
helper names, and a branch guarantee goes in an executable precondition assertion. Measured
example: a five-line comment explained a threshold relationship two lines above
`expect(boxAreaFrac(oversized)).toBeGreaterThan(DEFAULT_MAX_BOX_FRAC)` — the assertion was
already stronger than the prose, and cannot drift out of date.

**The only two spec keeps:**

- An **open ticket on disabled work** — an `xit` under a named ticket, "restore when X lands".
- A **specific runner or platform incompatibility** that cannot be encoded in the harness —
  e.g. "Karma's Linux headless Chrome rejects `fetch` of blob: and data: URLs, so real mask
  URLs cannot be used here." Without it the stub looks pointlessly complicated.

**Everything else in a spec goes**, including the tempting ones: setup and assertion narration,
regression history, "how the production code fails" (that is what the red test says), mock-shape
descriptions, and framework gotchas.

**Zero arithmetic in specs.** Replace a derivation with named operands, a helper, a matcher, or
a precondition assertion. A comments-only pass deletes the prose and reports the refactor the
file needs — it does not grandfather the prose because the refactor is out of scope.

### No pointers. To anything.

Do not extract a comment's content to a `docs/` file and leave a link, and delete such
pointers where found. Verified on the real subtree: of the surviving `docs/` pointers, three
targets **did not exist even on the author's machine** and the fourth was gitignored
(`/docs` is engineer-local by policy) — a pointer into `docs/` is a comment that dereferences
to nothing for every other developer, and the doc rots even where it exists. The same goes
for design-node ids (`per 37R-0`, ``Pen `EbGeJ` ``) — keep the measured value, delete the
node ref — and for rule-links used as keep justification. A comment either states the thing
or it goes; it never forwards the reader.

## Phase 5 — land

Open the PR against the branch the work actually merges into, not whatever the default is. CI on
_that_ PR is the only place stylesheet and template edits get verified — no local gate reads them.

**Report the retention, not just the cut.** Lines removed is half the number; lines
*re-added as tightened survivors* is the other half. A pass that deletes 3,500 and re-adds
3,100 has cut 400. Both numbers go in the report, per area.

## Delegation

Fanning out works, but only behind the gates above. Observed failure modes, all real:

- A worker given a whole directory **delegates instead of working** and returns before its
  children finish, reporting success with zero files changed. Give explicit file lists and state
  plainly that it must do the work itself.
- Worker self-reports do not match the tree. One reported "no logic/assertion/string-literal
  changes" while having rewritten 51 test titles. **Verify by effect, never by report.**
- Orphaned children keep writing after their parent returns. Re-dispatching over the same scope
  then races them. Check what actually changed on disk before assigning work.
- Briefs shape retention as much as rules do. Never seed a worker with an expected ratio
  (see Phase 1), and require the report to justify each KEEP against a numbered keep-rule —
  a keep that names no rule is a finding.

## Self-test

`tools/comment-cut/run.sh --self-test` must prove **both** directions: every mechanical class
still fires, and every keeper stays silent. A detector that only proves it fires can ship green
while shredding load-bearing comments.

The keeper suite is not decoration. It has caught, on real code, a rule that flagged prose
beginning with a code keyword, and a rule that flagged a mid-sentence ticket reference documenting
an upstream defect. Before trusting a change to the detector, mutate it and watch the suite go
red — a mutation that stays green means nothing is checking that rule.
