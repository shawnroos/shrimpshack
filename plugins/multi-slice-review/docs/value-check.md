# Early comparative value-check gate (U7)

**Status: protocol pre-registered; result PENDING (runs at the live boundary, before U8).**

The gate proves the premise — seam-review beats a whole-diff review — *before* the loop/escalation
machinery is built. It is a go/no-go smell test, not a statistical proof (N=3 is low-powered by
design). Pre-registered so a positive and a null result are both interpretable.

## The three definitions (fixed before running)

1. **Diff set — N=3.** Three diverse, genuinely multi-subsystem diffs (real changes, not toys).
2. **Sound slicing.** For each diff, an **independent agent** (not the one drawing the cut) confirms
   the slicing is sound against the rule: *every slice states one checkable invariant*. A diff whose
   slicing can't be confirmed sound is replaced — the gate tests the method, not a bad cut.
3. **Grader — blind + neutral.** For each diff, run this plugin's single-round seam review AND a
   single whole-diff review of the same change. A **grader agent scores every finding blind to
   provenance** (both sets stripped of origin labels, uniform formatting — it cannot tell which set is
   the plugin's) on a **neutral severity rubric**: a finding is P0/P1 if it names a concrete wrong
   outcome someone hits, else P2/P3. The rubric is deliberately **not** the KTD4 defect-category
   taxonomy — grading the baseline on the method's own ontology would tilt the result.

## Pass condition

**PASS** = the seam/mutation set's findings land in the P0/P1 tier on a **majority** (≥2 of 3 diffs).

**FAIL** = they do not, with slicing granted sound. That is the disconfirming result — **stop**, do
not build U8; report it. It is not automatically "the slicing was wrong" (the soundness check already
cleared that).

## Result (fill in when the gate runs)

| Diff | Sound? (grader) | Plugin seam/mutation in P0/P1? | Whole-diff top tier? |
|------|-----------------|--------------------------------|----------------------|
| 1    | —               | —                              | —                    |
| 2    | —               | —                              | —                    |
| 3    | —               | —                              | —                    |

**Verdict:** PENDING.
