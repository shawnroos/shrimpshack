# Consolidated review — reflect embed-index plan

Reviewed: `docs/plans/2026-08-14-001-fix-reflect-embed-index-new-memories-plan.md`
Date: 2026-08-14

**Verdict: yes with fixes.** The plan's fix site, ordering decision, and release path are
right. Its verification is not yet sufficient: as written it proves the *script calls
`qmd update` before `qmd embed`*, not that *a new memory becomes findable*. Four findings
below; F1 is the one that decides whether this plan closes the bug or just closes the diff.

## Provenance of these findings

| Lens | Model | Independent? |
|---|---|---|
| Plan author + self-review | GPT-5.6 Sol (`gpt-sol`) | dispatched, isolated context |
| Outside review | Gemini 3.1 Pro (`gemini-pro`) | dispatched, isolated context |
| Coherence | Opus 5 subagent | yes — isolated context, delivered late after two idle cycles |
| Feasibility | Opus 5 subagent | yes — isolated context, delivered late; ran shell verifications |
| Traceability + tally-contradiction spot checks | Opus 5, in-thread | no |

Scope-guardian was not dispatched. Coverage gap, stated rather than implied.

Authorship was withheld from both dispatched reviewers. Gemini's review is retained for the
record but 2 of its 5 findings are fabricated (see the end of this file).

---

## F1 — P0. The test's discriminating power comes from the same change that supplies the fix

**Anchor:** plan KTD4 (`:93`), U1 (`:176-199`), Verification Contract items 2-4 (`:257-259`)

The reconciler block tests against a **stub** qmd, written inline at
`plugins/reflect/tests/harness.sh:83-112` and on `PATH` from `:118` to `:163`. Today that
stub models `embed) exit 0` unconditionally and has no `update` case at all — anything
unmodelled falls to `*) exit 1` (`:110`, `:112`). It is structurally incapable of
distinguishing indexed from unindexed documents.

U1 therefore has to *author* the semantics the assertion depends on: an indexed ledger, an
embedded ledger, and the rule that `update` rescans registered paths while `embed -c` moves
only already-indexed files. That rule is the plan's own theory of how real qmd behaves. The
test then confirms the production script matches it.

**What this does and does not prove.** It does prove something real: with those semantics,
unchanged production calls `embed -c` with no preceding `update`, the second file is absent
from the indexed ledger, the membership assertion is false, `check` increments `FAIL`
(`:27`), and the harness exits 1 (`:1163-1164`). Adding the production `update` turns it
green; removing it turns it red again. So the mutation proof is genuine **against the
script**.

It does not prove that `qmd update` is what real qmd requires. The stub encodes that belief
rather than testing it. If the premise is wrong or shifts in a future qmd, the suite stays
green while memories stay unfindable — the exact shape of the defect being fixed, relocated
from the counter into the test.

**Live evidence, added 2026-08-14 from a concurrent session.** Another agent's `/reflect` run
hit this bug again in the wild. The declared trigger on
`reference_reflect_embed_pass_never_indexes_new_memories` fired, that agent ran `qmd update`
before `qmd embed`, and then **verified by effect** — searching a distinctive phrase from each
new memory returned it at 96% and 97% similarity. It reports that without the update the
reconcile line "would have read `embedded=5 failed=0` while all five stayed unfindable."

This changes F1's risk profile in two ways, and neither removes the finding:

- The premise the stub encodes is **no longer unproven**. Real qmd does require `update`
  before `embed` for a new file, confirmed against the live index by an independent run. That
  retires most of spike S1/S2's premise risk and tells the implementer exactly what the
  real-qmd assertion should assert, and that it can pass.
- It is the **second** occurrence in one day, both caught by a human-or-agent noticing rather
  than by a test. That is precisely the "caught by luck" the handoff objected to, and it
  raises rather than lowers the case for an end-to-end guard in the suite.

That run is also a working example of what U3's documentation change should require of the
model: it reported `compounded=0` with a stated reason rather than claiming success, and it
proved the embed by search result rather than by exit code.

**Required change.** Keep the stub test as the regression guard on call order, and add one
real-qmd assertion that a memory file created *after* collection registration is retrievable
after the production reconciler runs. The seeded-recall block already uses real qmd, real
files and real search (`harness.sh:217-229`), so a home for it exists; that block's own
setup-side `qmd update` at `:226` must not be what satisfies it. Without an end-to-end
assertion somewhere, the plan's Definition of Done is met by a script that calls a command,
not by a memory that can be found.

---

## F2 — P1. First-run collections sit outside the hoisted update

**Source:** Sol. **Anchor:** plan KTD1 (`:90`), U1 scenarios (`:190-198`), Risks (`:273`)

The global `qmd update` runs before traversal, but `reconcile_one` creates a missing
collection *later*, immediately before its embed
(`plugins/reflect/scripts/qmd-reconcile-collections.sh:80-102`). A brand-new collection's
initial files therefore depend entirely on `qmd collection add` indexing at add time — which
the plan never establishes. KTD4 compounds it by letting the stub assume `collection add`
"may seed its current files", so the test model may assume the very behavior that needs
proof.

**Downgraded from P1 to P2 — the premise is already proven by a passing test.** The
seeded-recall block does `qmd collection add ./mem` at `harness.sh:177` and then embeds and
recalls with **no intervening `qmd update`** — against real qmd — and those assertions pass
today. So real `collection add` does index the files present at add time, and the first-run
path is safe. What remains is that the plan never states this and no reconciler-level
assertion covers it.

**Required change.** Record add-time indexing as an established fact (citing
`harness.sh:177-194`) rather than a spike question, and add the U1 first-run scenario so a
future qmd change cannot break it silently.

---

## F3 — P1. R6 and U2 contradict each other, and the contradiction is the false-`0` bug

**Source:** Sol (as a design gap) + coherence pass (as a textual contradiction).
**Anchor:** R6 (`:50`) vs U2 step 4 (`:211`)

- R6: "when **every embed** reports the established no-work line ... it may report the
  observed count `embedded=0`"
- U2 step 4: "aggregate `embedded=0` only when every **successful** embed emits the exact
  no-work status"

They diverge on exactly one case: a run containing a failed embed. R6 forbids `0` there;
U2 permits it. So a collection can embed documents, exit non-zero, contribute nothing, while
every other collection reports no-work — and the summary prints `embedded=0`. That is a
fresh false-precision claim inside the fix for false-precision claims.

R6 is the correct side, which makes this mechanical rather than a judgment call.

**Required change.** Amend U2 step 4 to R6's rule: any embed failure without a proven count
forces `embedded=unknown`, with the existing per-collection warning and traversal preserved.
Add a combined failure-plus-no-op assertion to U1.

---

## F4 — P2. A content-hash count is not a document count

**Source:** Sol. **Anchor:** Spike S2 (`:148`), U2 tally contract (`:211`)

R5 defines `embedded` as documents, but S2 accepts an integer tied to "documents/content
hashes embedded". If one document yields several hashes or chunks, summing them and
publishing `embedded=N` overstates documents embedded, leaving the tally misleading in a new
way.

**This is now settled, not hypothetical — promote to P1.** Prior verified observations of
qmd's actual output (recorded in the memory
`reference_reflect_embed_pass_never_indexes_new_memories`) show the only countable field is a
**hash** count: `update` prints `"21 unique hashes need vectors"` and `embed` prints
`✓ All content hashes already have embeddings.` when idle. There is no document-count field
to parse, and one document can carry several content hashes.

**Required change.** Delete U2 step 4's parse-and-sum branch and Spike S2's
"documents/content hashes" wording. The tally has exactly two honest values: `0` for the
proven no-work line, `unknown` otherwise. That also dissolves F6 (no count-field branch left
to contradict R6) and collapses the Goal Capsule stop condition in F8. S1/S2 remain worth
running to confirm the output strings have not changed, but they can no longer change the
tally design.

---

## F5 — P1. Every shell-file citation is one line low; three ranges miss their target

**Source:** coherence pass (dispatched). **Verified independently.**

The offset is uniform `-1` across all three shell files, and in three cases the cited range
does not contain the target at all:

| Plan cites | Actually at |
|---|---|
| `qmd-reconcile-collections.sh:25` (`set -euo pipefail`) | `:26` |
| `qmd-reconcile-collections.sh:62` (`embedded=$((embedded + 1))`) | `:63` |
| `qmd-reconcile-collections.sh:124` (summary echo) | `:125` |
| `qmd-reconcile-collections.sh:14-17` (`QMD_RECONCILE_NO_EMBED` doc) | `:18` — outside the range |
| `qmd-reconcile-collections.sh:125-127` (creation-failure exit) | `:128` — outside the range |
| `harness.sh:24-26` (`check` helper) | `:27` — outside the range |
| `check-version-bumped.sh:16-18` / `:20-24` (both-files contract) | `:17-19` |

The `SKILL.md`, `plugin.json` and `marketplace.json` citations are correct; the drift is
confined to the shell files.

Promoted from the reviewer's P3 to P1: this plan's value is precise anchors an implementer
patches against, and three of them point at the wrong statement entirely. A plan whose
citations misdirect edits is worse than one that omits them, because the reader trusts them.

**Required change.** Add 1 to every line number citing
`plugins/reflect/scripts/qmd-reconcile-collections.sh`, `plugins/reflect/tests/harness.sh`,
and `scripts/check-version-bumped.sh`. Leave `SKILL.md`, `plugin.json`, and
`marketplace.json` citations alone.

---

## F6 — P1. The count-field branch contradicts the all-no-op-equals-zero rule

**Source:** coherence pass. **Anchor:** U2 step 4 (`:211`) vs R6 (`:50`) and U1 scenario 4 (`:194`)

Distinct from F3 — here *every* embed succeeds. If spike S2 does find a stable
document-count field, U2 step 4 says to "parse only that field" and keep `unknown` for
"any successful output that lacks the field". The no-work line lacks the field. So an
all-no-op run reports `unknown` under U2, while R6 and U1 scenario 4 both require `0`.
U1 scenario 4 fails against a literal implementation of U2's own count-field branch.

**Required change.** State one rule in U2 step 4: the exact no-work line *is* an observed
count of 0 and is summed alongside any parsed per-collection counts; `unknown` applies only
to successful output that is neither the no-work line nor a parsed count.

---

## F7 — P2. The objective promises removed-file indexing that nothing covers

**Source:** coherence pass. **Anchor:** Goal Capsule (`:16`) vs R1-R11, Spike S3 (`:160`)

The Objective says Pass 8 will "index new **and removed** files", but no requirement, no
unit, and no Definition of Done item covers deletion — and S3 explicitly defers it ("Do not
expand the implementation if deletion remains a qmd defect; record that as follow-up work").
A reader cannot tell whether the objective overstates the deliverable or a requirement is
missing. This matters because a retired memory still surfacing in recall is its own live bug.

**Required change.** Narrow the objective to indexing files added since registration, and
note removed-file handling as an S3 discovery recorded as follow-up.

---

## F9 — P1. The fix breaks the script's own foreign-safety invariant, and no test notices

**Source:** feasibility pass (dispatched). **Verified independently.**

`qmd update` takes no collection flag — it re-indexes **every** collection in the resolved
config. But the script's own header promises the opposite, verbatim at
`qmd-reconcile-collections.sh:3-7`:

> Only ever touches `claude-`-prefixed collections, so foreign collections (openclaw, Slate,
> global) are never modified.

`SKILL.md:236` makes the matching claim about the ~24.8k-doc global backlog. The plan changes
the behavior and updates neither statement. The harness's foreign-safety assertion only
checks that the foreign collection's *name* still exists, so nothing fails.

Two consequences. A reader of the shipped script believes an invariant it no longer holds —
which is the same species of defect as the false tally, in the documentation. And every
auto-triggered Pass 8 now pays a full global re-index; `setup.sh:60-62` invokes the reconciler
with embedding enabled, so `/reflect-setup` on a machine with a large global index pays it on
first run.

**Required change.** Add the script's header block to U3's file list and restate both it and
`SKILL.md:236`: the run performs one global re-index pass that necessarily covers every
collection in the resolved config, while **embedding and collection creation** remain
restricted to `claude-`-prefixed collections. This is a scope change the plan currently makes
silently, so it needs stating, not just fixing.

---

## F10 — P1. Two shell traps that would make the honest tally kill the run

**Source:** feasibility pass. **Both verified by execution on this box.**

- **Mixed-type accumulator is fatal under `set -u`.** `embedded=unknown` followed by any
  `$((embedded + n))` exits 1 with `unknown: unbound variable`. The script dies before the
  summary prints and before the remaining doc-store collections are traversed — producing
  exactly the starvation R3 forbids, from the feature meant to make reporting honest.
- **The capture form decides everything.** A bare `out="$(qmd embed -c "$1" 2>&1)"` as its own
  statement returns the command's status and **aborts the whole script** under `set -e`
  (verified: the following line never runs, rc=1). `local out="$(...)"` returns `local`'s
  status and **silently masks the failure**, so the warning and failed-tally branches never
  fire (verified: rc=0). Only `if out="$(...)"; then` is correct. The plan says "capture
  output and exit status" without naming the form, and its only `set -e` guidance targets the
  global update.

**Required change.** In U2, mandate two variables — a numeric `embedded_docs=0` that is the
only thing arithmetic ever touches, and a boolean `embedded_unknown=0` — rendered once at the
summary. And mandate the `if out="$(...)"; then` form explicitly, naming both wrong forms so
neither gets used.

---

## F11 — P1. U4 cannot install `0.5.1` before the bump is merged and pushed

**Source:** feasibility pass. **Anchor:** U4 (`:232-250`), Definition of Done (`:288`)

The reflect cache is versioned per published release and populated by a marketplace refresh
from the pushed `shawnroos/shrimpshack` clone, so a `0.5.1` cache directory cannot exist until
the bump is on main. U4 is written as an ordinary implementation unit whose cache proof is a
Definition-of-Done gate, so an implementer working the units in order hits an impossible step
and will either hand-copy files into the cache — invalidating the proof — or declare done
without it.

**Required change.** Split U4: the version bump and `check-version-bumped.sh` are pre-merge;
the install, source-to-cache comparison and cache-path harness run only after merge and a
marketplace refresh. For pre-merge confidence, run the harness once from a clean
`git archive HEAD` export of `plugins/reflect` at a path outside the worktree.

---

## F12 — P2. Nothing can catch drift in the parsed no-work literal

**Source:** feasibility pass. **Anchor:** KTD3 (`:92`), U1 scenarios 4-5

The `embedded=0` branch hinges on one exact string, and every automated test for it runs
against a stub the plan authors to emit that string — green by construction whether or not
real qmd still prints it. If the wording shifts by a character, production reports
`embedded=unknown` forever while the suite stays green. Spike S2 is a one-time manual
observation that no gate re-checks.

**Required change.** Extend U4's real-qmd smoke to run the cached reconciler twice against the
isolated fixture and assert the second run's summary contains `embedded=0`. That is the only
place the parser's literal meets real qmd output, so it must be an assertion, not a note.

---

## F8 — P3 cluster (mechanical, from the coherence pass)

- **Stop condition fires on a case the plan already resolved.** The Goal Capsule says stop
  if spikes "show a reliable document-count output", but U2 step 4 and the Risks mitigation
  both prescribe exactly what to do in that case. Drop the first clause.
- **U2 lists `harness.sh` in its Files but never edits it.** None of U2's five steps touch
  the harness, KTD4 and S4 assign all stub work to U1, and U2's mutation proof requires the
  test unchanged. Remove it from U2's Files list.
- **R4 scopes `QMD_RECONCILE_NO_EMBED` to embedding only**, while U1 scenario 8 and U2 step 1
  both gate the update on it too. R2 itself distinguishes update (indexing) from embed
  (vectorising), so a literal R4 leaves the update running and scenario 8 fails. Extend R4
  to name the update.
- **R9/AE5 ownership splits across units.** U1 claims R9 and AE5, but the post-fix mutation
  runs in U2, whose requirement list stops at R7. Credit U2 with R9's mutation half.

---

## Checked and found sound

- **Requirement traceability.** R1-R11 all covered (U1: R1,R2,R5-R9; U2: R1-R7; U3: R10;
  U4: R11). No orphans, no unit citing a requirement that does not exist. AE1-AE5 claimed
  by U1.
- **Release gates.** Reflect is `0.5.0` in both `plugins/reflect/.claude-plugin/plugin.json`
  and `.claude-plugin/marketplace.json`; `scripts/check-version-bumped.sh` requires the two
  to move together. The plan's KTD5 and U4 name both. Verified by reading.
- **SKILL.md citations.** `:233-239` is Pass 8 with `Tally: embedded=N` at `:239`; Pass 2
  opens at `:117`. These resolve. The plan's *shell-file* citations do not — see F5.
- **Shell viability of the tally.** `if out="$(qmd embed -c "$name" 2>&1)"; then ... else
  ... fi` is safe under the production script's `set -euo pipefail`
  (`qmd-reconcile-collections.sh:25`) and preserves the exit status for branching. A string
  `unknown` is safe provided no arithmetic touches the variable — the plan's removal of
  `embedded=$((embedded + 1))` (`:210`) is what makes that true, so the two changes must
  land together.
- **Masking trap.** U1 forbids test-side `qmd update` and requires a call ledger. The stub
  leaves `PATH` at `harness.sh:163`, before the real-qmd block, so the later setup-side
  update at `:226` cannot satisfy the earlier assertion.

## Note on the Gemini review

Retained at `docs/reviews/2026-08-14-plan-review-geminipro.md`. Two of its five findings do
not survive checking: its P0 that `scripts/check-version-bumped.sh` and
`.claude-plugin/marketplace.json` "do not exist" (both exist), and its P1 that the plan's
`SKILL.md` citations are hallucinated (its own body confirms four of six are correct, and its
one specific claim — that `:233-239` does not exist — is wrong). Its remaining findings
restate F2 more weakly or misread KTD4, which does specify stub rescan semantics.
