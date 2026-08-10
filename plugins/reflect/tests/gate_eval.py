#!/usr/bin/env python3
"""gate_eval.py — score a confidence-gate design against labelled queries.

WHY THIS EXISTS. The gate was redesigned three times, and each attempt was judged
against whichever fixture happened to be at hand: one full harness run per idea,
~90s each, and an inconclusive answer at the end because a failing fixture might be
a real regression OR a stale premise recorded when the previous gate shipped. Two of
those "flaws" turned out to be the latter — an assertion demanding silence for
`squash`, whose right answer (`feedback_squash_on_pr_landing.md`) was sitting in the
store the whole time.

So: label the queries once, against the LIVE store, and score any candidate in
seconds. A design is then comparable to another design instead of to a memory of how
the last run went.

    python3 gate_eval.py                 # score the shipped gate
    python3 gate_eval.py --verbose       # per-query detail

The labels are the contract. Each is a claim about what the store contains, checked
by `--audit`, not an opinion about what the gate should score.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "..", "scripts", "scoped-memory"))
import local_index as li  # noqa: E402

STORE = os.path.expanduser("~/.claude/projects/-Users-shawnroos/memory")

#: (query, expected_relpath_or_None, why)
#:
#: expected=None means NO body in the store answers this — silence is correct.
#: expected="x.md" means that body answers it and MUST come back; the name is the
#: label's evidence, and `--audit` re-checks that the file still exists.
LABELLED = [
    # --- should return, and which body ------------------------------------------
    ("failing E2E shard sprout spec flake or real regression",
     "reference_e2e_flake_vs_regression_triage.md",
     "Case 2 from the plan — the 14h46m miss"),
    ("PR conflicting stopped running CI mergeable merge ref",
     "reference_gh_conflicting_blocks_ci_silently.md",
     "Case 1 from the plan — the 56min miss"),
    ("seeded recall hook taxes every prompt when qmd hangs",
     "reference_seeded_recall_hook_taxes_every_prompt_on_qmd_hang.md",
     "refused by the shipped gate at ratio 1.07"),
    ("agent browser cannot send modifier keys",
     "reference_agent_browser_cannot_send_modifier_keys.md",
     "refused by the shipped gate at ratio 1.13"),
    ("squash",
     "feedback_squash_on_pr_landing.md",
     "one word, and it HAS an answer — the old floor scored it 3.46 and refused"),
    ("worktree main already checked out blocks gh pr merge",
     "feedback_gh_pr_merge_worktree_main_checkout.md",
     "multi-term, distinctive vocabulary"),
    ("cp is interactive and silently fails to overwrite",
     "reference_cp_is_interactive_in_shell.md",
     "a machine constraint that bit this very session"),

    # --- should stay silent ------------------------------------------------------
    ("completely unrelated gardening tulips bulbs", None,
     "no gardening memory exists"),
    ("capital city of france population", None,
     "general knowledge, not a memory"),
    ("xyzzy plugh frobnitz quux", None,
     "nonsense tokens — nothing can match"),
    ("statusCheckRollup CodeRabbit SUCCESS", None,
     "the measured WRONG top hit: brushes real topics, answers nothing"),
    ("zorkmid quibble frobnitz", None,
     "nonsense, and the CLI fixture's flat query"),
]


def audit():
    """Check every label still describes the store. A label naming a body that no
    longer exists is a broken ruler, and a scorer with a broken ruler is worse than
    no scorer."""
    bad = 0
    for q, expected, why in LABELLED:
        if expected and not os.path.exists(os.path.join(STORE, expected)):
            print("  MISSING BODY  %-46s -> %s" % (q[:46], expected))
            bad += 1
    print("  audit: %d label(s) broken" % bad)
    return bad == 0


def score(verbose=False, **search_kw):
    idx = li.build(STORE)
    tp = fp = tn = fn = 0
    rows = []
    for q, expected, why in LABELLED:
        r = li.search(STORE, q, cwd="/tmp", index=idx, **search_kw)
        returned = r.status == li.HITS
        files = [h["file"] for h in r.hits] if returned else []
        if expected is None:
            ok = not returned
            tn += ok
            fp += (not ok)
            verdict = "silent" if ok else "FALSE POSITIVE"
        else:
            ok = returned and expected in files
            tp += ok
            fn += (not ok)
            verdict = "found" if ok else ("WRONG BODY" if returned else "FALSE NEGATIVE")
        rows.append((ok, verdict, q, r, files, expected))

    if verbose:
        for ok, verdict, q, r, files, expected in rows:
            print("  %s %-15s %-44s %s" % ("ok  " if ok else "FAIL", verdict, q[:44],
                                           (getattr(r, "reason", "") or "")[:44]))
            if not ok and expected:
                print("        wanted %s, got %s" % (expected, files or "nothing"))

    total = len(LABELLED)
    correct = tp + tn
    print("  score %d/%d   true-hits %d/%d found   junk %d/%d refused"
          % (correct, total, tp, tp + fn, tn, tn + fp))
    if fn:
        print("  %d FALSE NEGATIVE(s) — a memory that exists and was not surfaced,"
              " which is the failure this plugin exists to remove" % fn)
    if fp:
        print("  %d FALSE POSITIVE(s) — a wrong memory returned, which costs more"
              " than no memory" % fp)
    return correct, total


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--audit", action="store_true", help="only check the labels")
    a = ap.parse_args()
    if not audit():
        sys.exit(2)
    if a.audit:
        sys.exit(0)
    correct, total = score(verbose=a.verbose)
    sys.exit(0 if correct == total else 1)
