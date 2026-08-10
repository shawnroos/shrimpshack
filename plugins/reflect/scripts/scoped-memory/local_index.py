#!/usr/bin/env python3
"""local_index.py — the qmd-free retrieval primitive (plan U1).

A BM25 index over the memory store, built in-process per query, returning either
CONFIDENT hits or an EXPLICIT below-gate result.

One honest caveat on that, raised by a cross-model reviewer: the SINGLETON path
below passes on the absolute floor alone, because with one candidate there is no
ratio to compute. A lone lexical match clearing the floor IS a flat guess, so the
blanket claim "never returns a flat guess" holds for the ranked path and NOT for
that one. Either require more of a singleton, or read the claim as scoped to the
multi-candidate case — it is scoped that way here deliberately, since refusing every
singleton would make a sparse or heavily-filtered corpus permanently silent.

Why build per query (KTD6): the corpus is small (866-ish bodies, ~2.9 MB) and the
build costs a few hundred milliseconds. A persisted index would buy that back and
pay for it with an entire staleness class — a memory saved ten seconds ago must be
findable now, which is the one thing this layer has over qmd's embedding lag — plus
a second write path to keep honest. If the corpus grows an order of magnitude, an
mtime-keyed cache is the escape hatch. Not built now.

Enumeration is `corpus.iter_bodies` (KTD16). Never `os.listdir`, never a second
walk: a third of the store lives under `_scope/<slug>/` and a flat walk searches
two thirds of the corpus while reporting success.

THE ORDER OF THE PIPELINE IS THE WHOLE UNIT (KTD15). In `search()`:

  1. drop siblings         — `scope.classify(...) == "sibling"`, applied to the
                             RANKED list: `score_all()` scores every matching body
                             first, siblings included, and they are filtered
                             immediately after. No verdict differs — a sibling never
                             reaches `above` or the ratio — but the ordering below is
                             about which scores the GATE reads, not about which
                             bodies get scored. Said plainly because the two readings
                             diverge the moment scoring gains a side effect or
                             classification becomes score-dependent.
  2. absolute floor        — MEMORY_LOCAL_FLOOR_MIN, a CALIBRATED RAW score
  3. separation            — top1/top2 over the score-ordered survivors
  4. K+1 presentation      — `scope.select_scoped`, AFTER the gate has decided

Step 4 is last because `scope.select_scoped` (scope.py:150-174) deliberately
PREPENDS the best current-repo body ahead of higher-scoring ancestors — plan 003's
K+1 boost, working as designed. Run the gate after it and a position-based top1/top2
comparison reads a list whose positions no longer track score: a current-repo 0.50
with ancestors 0.95 and 0.62 presents as [0.50, 0.95, 0.62], so the gate compares
0.50/0.95 and rejects a query whose real top pair is 0.95/0.62 = 1.53 and should
have passed. The inverse manufactures a false positive just as easily.

THE FLOOR IS NOT THE QMD FLOOR (KTD12). `memory_activation.recall_floor` returns
`base + span*(1-norm)` — 0.45 to 0.60 with shipped defaults — and was calibrated for
qmd VECTOR scores in [0,1]. Raw BM25 scores on this corpus run in the tens. That
floor applied here filters nothing, ever, silently. Nor is the floor top1-relative
(`score / top1`): that pins top1 at exactly 1.0 for every non-empty result set, so
the strongest hit clears any 0.45-0.60 floor unconditionally whether its raw score
was 38 or 0.08 — dead code promoted to rubber stamp, which is worse because it
looks like it is working. So: a calibrated RAW-score floor, env-overridable in the
`SEEDED_RECALL_*` / `MEMORY_ACT_*` tradition. Separation is a SECOND, INDEPENDENT
condition on top of it (KTD11) — never a substitute.

Two behaviors that are specified here rather than left to chance, because either
default would ship silently:

  * SINGLETON — exactly one candidate clears the floor, so no top1/top2 ratio
    exists. It passes on the ABSOLUTE FLOOR ALONE; separation is not evaluated.
  * NOTHING CLEARS THE FLOOR — the explicit below-gate result. Never a best-effort
    top hit.

This module shells nothing and imports no qmd. It works with qmd absent from PATH,
which is the point of it.
"""
import math
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import corpus  # noqa: E402
import scope   # noqa: E402

# ---------------------------------------------------------------- tunables

#: Okapi BM25 saturation and length-normalization. Standard values; the corpus is
#: short-document and homogeneous, so nothing here wanted special treatment.
DEFAULT_K1 = 1.5
DEFAULT_B = 0.75

#: The calibrated absolute floor, in RAW BM25 score units (KTD12). Calibrated by
#: running THIS implementation read-only over the live store (886 bodies: 599 flat
#: + 287 scoped, avgdl 369 tokens, 20,448-term vocabulary) on 2026-08-09:
#:
#:   true-hit top scores   14.87  18.45  27.28  53.16   (queries whose answer is
#:                                                       on disk; lowest is the
#:                                                       terse "is this failing
#:                                                       test a flake")
#:   no-answer top scores   6.16 … 9.51, and 12.11 / 16.39 for two junk queries
#:                                                       that brush real topics
#:
#: 12.0 sits above every no-true-answer probe that separation does NOT already
#: reject, and below every measured true-hit top. It does not have to separate the
#: two populations on its own — the ratio condition is the other half, and the two
#: overlapping bands above are exactly why one condition would not be enough.
#: A floor is a property OF A CORPUS: BM25 is unnormalized and corpus-dependent, so
#: this must be recalibrated as the store grows. The ratio half (below) need not be.
#: The gate's RELEVANCE condition: how much of the query's own vocabulary the top hit
#: actually contains. Scale-free — the same rule at 3 bodies and at 8,860.
#: Measured on the live store (889 bodies):
#:   true hits  1.00  1.00  0.75  0.67
#:   junk       0.50  0.25  0.25  0.00
#: 0.60 sits in that gap, measured over DISCRIMINATING terms (see `coverage`). Eight points is thin and RECALL.log should refine it, but it
#: beats the three points the previous threshold rested on — and unlike that one,
#: being slightly off does not get WORSE as the store grows.
#: A query term appearing in more than this share of the corpus carries no signal
#: about WHICH body is wanted, so coverage ignores it. Without this, a longer question
#: scores lower than a short one for the same answer.
COMMON_TERM_FRACTION = 0.05

#: ...but never treat a term as common on the strength of a handful of documents.
#: Without this floor the fraction collapses to 1 on a small store and discards terms
#: that are doing all the discriminating.
COMMON_TERM_MIN_DF = 3

DEFAULT_MIN_COVERAGE = 0.60

#: Kept for callers that pin an explicit absolute floor (tests do, to exercise gate
#: LOGIC against a known number). No longer the shipped relevance condition.
DEFAULT_FLOOR_MIN = 12.0

#: The corpus the floor above was measured against, and the hard guard the scaled
#: floor may never fall below. See `floor_for_corpus`.
FLOOR_CALIBRATION_N = 886
DEFAULT_FLOOR_GUARD = 2.0

#: Separation (KTD11): top1 must beat top2 by this factor. Measured basis is thin —
#: the plan's true hit ratio'd 1.51 and both known misses were flat; the live probes
#: above put true hits at 1.30–1.94 and junk at 1.02–1.49 — so the default starts on
#: that boundary and tuning waits for RECALL.log telemetry, the same posture plan
#: 003 took for SEEDED_RECALL_REPO_MIN_SCORE. Where the bands overlap this errs
#: toward silence, which is the chosen failure mode: a wrong memory costs more than
#: no memory.
DEFAULT_FLOOR_RATIO = 1.4

#: How many global/ancestor bodies `select_scoped` keeps (the current-repo boost
#: rides on top as a K+1th).
DEFAULT_K = 3

#: Query-side noise. BM25's idf already de-weights corpus-common words; this exists
#: so a query phrased as a sentence doesn't drag length normalization around.
STOPWORDS = frozenset("""
a an and are as at be but by for from had has have how i if in into is it its of
on or that the their then there these they this to was were what when where which
who why will with you your do does did not no than
""".split())

#: `sprout.spec.ts` -> sprout, spec, ts. Underscores are kept because memory names
#: are `feedback_foo_bar` and the name line is part of the indexed text.
_TOKEN_RE = re.compile(r"[a-z0-9_]+")

#: Statuses. `hits` = gate cleared. `below_gate` = candidates existed, none of them
#: confident. `empty` = nothing to rank at all (empty store, unreadable dir, query
#: with no usable terms, every candidate a sibling).
HITS = "hits"
BELOW_GATE = "below_gate"
EMPTY = "empty"


def _envf(name, default):
    """Float from the environment, falling back on anything unparseable. A typo'd
    tunable must not take the retrieval path down with it — this whole module is on
    a fail-open path."""
    try:
        return float(os.environ[name])
    except (KeyError, ValueError, TypeError):
        return default


def floor_min():
    """The calibrated absolute BM25 floor. NOT `memory_activation.recall_floor`."""
    return _envf("MEMORY_LOCAL_FLOOR_MIN", DEFAULT_FLOOR_MIN)


def floor_guard():
    """The hard minimum the scaled floor may never fall below."""
    return _envf("MEMORY_LOCAL_FLOOR_GUARD", DEFAULT_FLOOR_GUARD)


def floor_for_corpus(n_corpus, base=None):
    """Scale the calibrated floor to the corpus actually in hand.

    The 12.0 above is a property OF AN 886-BODY CORPUS. BM25 sums IDF terms and IDF
    grows with log(N), so that constant does not transfer downward. Measured against
    real fixture stores: a true hit tops out at 5.50 on a 3-body store and 8.52 on an
    8-body one, both refused outright by a floor of 12.0. Below roughly 20 memories
    the whole layer returns nothing however good the match — which is every fresh
    install, the one case with no telemetry to notice.

    So the floor scales by log1p(N)/log1p(886), which keeps the calibration EXACTLY
    where it was measured (N>=886 → 12.0, untouched) and never scales UP, because
    inventing a higher bar from a formula would suppress true hits with nothing
    behind it. A hard guard stops it collapsing toward zero on a near-empty store.

    BE HONEST ABOUT WHAT THIS DOES NOT FIX. On a small corpus the true and junk score
    bands OVERLAP — measured at N=8, a true hit scored 8.52 while the best junk query
    reached 7.84; at N=20, 11.39 against 10.84. No absolute floor separates those,
    and the ratio does not rescue it either. Small-store recall is therefore WEAKER,
    not merely rescaled: it answers where it used to be mute, and it will sometimes
    answer wrongly. That is a deliberate trade the store owner chose over silence,
    not a claim that the gate works as well down there.

    The guard is provisional. It was picked from synthetic fixtures because no real
    small store exists to measure — and synthetic junk is not representative junk.
    RECALL.log now records every surfacing with its scores, so the first real
    small-store telemetry should replace this number.
    """
    base = floor_min() if base is None else base
    if os.environ.get("MEMORY_LOCAL_FLOOR_MIN"):
        return base          # an explicit override is a decision; do not second-guess it
    try:
        n = int(n_corpus)
    except (TypeError, ValueError):
        return base
    if n >= FLOOR_CALIBRATION_N or n <= 0:
        return base
    scaled = base * (math.log1p(n) / math.log1p(FLOOR_CALIBRATION_N))
    return max(floor_guard(), scaled)


def floor_ratio():
    """The separation threshold — top1/top2 over floor-clearing survivors."""
    return _envf("MEMORY_LOCAL_FLOOR_RATIO", DEFAULT_FLOOR_RATIO)


def tokenize(text):
    """Lowercase alphanumeric-underscore runs, stopwords and 1-char noise dropped."""
    return [t for t in _TOKEN_RE.findall(text.lower())
            if len(t) > 1 and t not in STOPWORDS]


# ------------------------------------------------------------------ index

class Index:
    """A BM25 index over one store. Built per query; hold it only if you are about
    to issue several queries in one process (`/memories` does)."""

    def __init__(self, docs, tfs, lengths, df, avgdl, k1=DEFAULT_K1, b=DEFAULT_B):
        self.docs = docs          # [relpath, ...] — body identity is the relpath
        self._doc_pos = {r: i for i, r in enumerate(docs)}
        self.tfs = tfs            # [{term: count}, ...] parallel to docs
        self.lengths = lengths    # [int, ...] parallel to docs
        self.df = df              # {term: document frequency}
        self.avgdl = avgdl or 1.0
        self.k1 = k1
        self.b = b

    def __len__(self):
        return len(self.docs)

    def _idf(self, term):
        """Robertson/Sparck-Jones idf with the +1 that keeps it non-negative, so a
        corpus-common word can never DRAG a document down with a negative score.

        A term present in EVERY document contributes log(1 + 0.5/(N+0.5)), which
        approaches zero as the corpus grows but is not zero on a small one — about
        0.288 at a single body. Worth stating precisely rather than as "~0": it is
        part of why raw scores from a small store are not comparable with the
        thresholds calibrated against this one (see X8 in the residuals record)."""
        n = self.df.get(term, 0)
        if not n:
            return 0.0
        return math.log(1.0 + (len(self.docs) - n + 0.5) / (n + 0.5))

    def coverage(self, relpath, query):
        """Fraction of the query's own meaningful terms this body contains.

        Scale-free ON PURPOSE, unlike a raw BM25 floor. BM25 sums IDF terms and IDF
        grows with log(N), so a raw-score threshold is a property of ONE corpus and
        silently wrong for any other. Coverage is measured against the QUERY, so it
        means the same at 3 bodies and at 8,860 and never needs recalibrating.
        """
        terms = set(tokenize(query))
        if not terms or relpath not in self._doc_pos:
            return 0.0

        # Measure against the terms that DISCRIMINATE, not every term. A word present
        # in a large share of the corpus says nothing about WHICH body you want, and
        # counting it punishes the user for adding context: measured, one memory was
        # found by both a short and a long form of the same question, and scored 0.71
        # (returned) against 0.58 (refused). More context made recall worse, which is
        # backwards. Dropping corpus-common terms fixes that and widens the gap at the
        # same time — junk fell from 0.67/0.40 to 0.50/0.25 while true hits held or
        # rose.
        # The floor of 3 matters more than the fraction. On a small store
        # `0.05 * N` rounds to 1, so a term appearing in TWO bodies would count as
        # corpus-common and be discarded — on an 8-body fixture that threw away every
        # term and scored a real match at 0%. A term has to appear in a handful of
        # places before its presence stops telling you which body you want, and that
        # "handful" does not shrink just because the store is small.
        cut = max(COMMON_TERM_MIN_DF, int(COMMON_TERM_FRACTION * len(self.docs)))
        disc = {t for t in terms if self.df.get(t, 0) <= cut}
        if not disc:                      # every term is corpus-common: fall back
            disc = terms                  # rather than divide by zero
        tf = self.tfs[self._doc_pos[relpath]]
        return sum(1 for t in disc if tf.get(t)) / float(len(disc))

    def score_all(self, query):
        """`[(relpath, score), ...]` score-descending, for every doc matching at
        least one query term. Ties break on relpath so the order is deterministic
        (a fixture whose gate verdict flips with dict ordering is not a test)."""
        terms = set(tokenize(query))
        if not terms:
            return []
        out = []
        for i, rel in enumerate(self.docs):
            tf = self.tfs[i]
            hit = [t for t in terms if t in tf]
            if not hit:
                continue
            norm = self.k1 * (1.0 - self.b + self.b * self.lengths[i] / self.avgdl)
            s = 0.0
            for t in hit:
                f = tf[t]
                s += self._idf(t) * f * (self.k1 + 1.0) / (f + norm)
            if s > 0:
                out.append((rel, s))
        out.sort(key=lambda p: (-p[1], p[0]))
        return out


def build(store_dir, k1=DEFAULT_K1, b=DEFAULT_B):
    """Read and index every body under `store_dir`. Fail-open: a missing store, an
    unreadable body, or a binary file yields a smaller index, never an exception.

    `k1` and `b` are clamped to the ranges BM25 is defined over. The shipped defaults
    are fine; the guard is for the public surface, where `k1 <= 0` or a `b` outside
    [0, 1] can drive the saturation denominator to zero or negative and turn scores
    into nonsense that still looks like a number. Clamping keeps the fail-open
    posture of everything else here — a bad tunable must not take retrieval down.
    """
    try:
        k1 = max(0.001, float(k1))
    except (TypeError, ValueError):
        k1 = DEFAULT_K1
    try:
        b = min(1.0, max(0.0, float(b)))
    except (TypeError, ValueError):
        b = DEFAULT_B
    docs, tfs, lengths, df = [], [], [], {}
    total = 0
    for rel, _slug in corpus.iter_bodies(store_dir):
        try:
            with open(os.path.join(store_dir, rel), encoding="utf-8",
                      errors="replace") as f:
                text = f.read()
        except OSError:
            continue
        toks = tokenize(text)
        tf = {}
        for t in toks:
            tf[t] = tf.get(t, 0) + 1
        docs.append(rel)
        tfs.append(tf)
        lengths.append(len(toks))
        total += len(toks)
        for t in tf:
            df[t] = df.get(t, 0) + 1
    return Index(docs, tfs, lengths, df, (total / len(docs)) if docs else 0.0,
                 k1=k1, b=b)


# ------------------------------------------------------------------ result

class Result:
    """What `search` returns. Carries enough for a caller to distinguish "hits",
    "below gate" and "nothing to rank", and to SAY WHY in a status line — a silent
    layer that can't explain its silence is the failure mode this plan exists to
    remove."""

    def __init__(self, status, hits=(), reason="", top_score=None,
                 runner_up=None, ratio=None, n_candidates=0, n_corpus=0):
        self.status = status
        self.hits = list(hits)          # [{"file","score","scope"}, ...]
        self.reason = reason
        self.top_score = top_score
        self.runner_up = runner_up
        self.ratio = ratio
        self.n_candidates = n_candidates
        self.n_corpus = n_corpus

    @property
    def ok(self):
        return self.status == HITS

    def as_dict(self):
        return {"status": self.status, "hits": self.hits, "reason": self.reason,
                "top_score": self.top_score, "runner_up": self.runner_up,
                "ratio": self.ratio, "n_candidates": self.n_candidates,
                "n_corpus": self.n_corpus}

    def __repr__(self):
        return "<Result %s hits=%d reason=%r>" % (
            self.status, len(self.hits), self.reason)


# ------------------------------------------------------------------ search

def search(store_dir, query, cwd=None, k=DEFAULT_K, index=None,
           min_score=None, min_ratio=None):
    """Rank `query` over the store and return a gated `Result`.

    `cwd` (default the process cwd) decides the current repo, hence which bodies
    are siblings and which body earns the K+1 boost. It is a parameter and not an
    implicit `os.getcwd()` so a caller — or a test asking "what does this look like
    from an unrelated repo?" — can just pass a path.

    The four steps run in the order the module docstring fixes them in. Changing
    that order changes the verdicts, which is why it is stated twice.
    """
    idx = index if index is not None else build(store_dir)
    cur_slug = scope.resolve_repo_slug(cwd or os.getcwd())
    # Scaled to the corpus in hand (floor_for_corpus). An explicit caller min_score
    # is honored as given and never scaled.
    fcover = _envf("MEMORY_LOCAL_MIN_COVERAGE", DEFAULT_MIN_COVERAGE)
    fratio = floor_ratio() if min_ratio is None else min_ratio

    ranked = idx.score_all(query)
    if not ranked:
        return Result(EMPTY, reason="no body matched any query term",
                      n_corpus=len(idx))

    # 1. siblings out — before anything reads a score, so no gate arithmetic ever
    #    involves a body that was never eligible to be returned.
    survivors = [(rel, s) for rel, s in ranked
                 if scope.classify(rel, cur_slug) != "sibling"]
    if not survivors:
        return Result(EMPTY, reason="every match belongs to another repo's scope",
                      n_corpus=len(idx))

    # 2. RELEVANCE — coverage, not a raw-score floor.
    #
    #    A raw floor is a property of ONE corpus: the shipped 12.0 refused true hits
    #    on any store under ~20 bodies, and rescaling by log(N) only relocated the
    #    arbitrary constant. Coverage asks something whose answer does not drift with
    #    corpus size — how much of what you asked for does this body contain.
    #
    #    `min_score` still pins an absolute floor for callers that want to exercise
    #    gate logic against a known number.
    top = survivors[0][1]
    cov = idx.coverage(survivors[0][0], query)
    if min_score is not None:
        above = [(rel, sc) for rel, sc in survivors if sc >= min_score]
        if not above:
            return Result(BELOW_GATE,
                          reason="top score %.2f below pinned floor %.2f" % (top, min_score),
                          top_score=top,
                          runner_up=survivors[1][1] if len(survivors) > 1 else None,
                          n_candidates=len(survivors), n_corpus=len(idx))
    elif cov < fcover:
        return Result(BELOW_GATE,
                      reason="top hit covers %.0f%% of the query (needs %.0f%%)"
                             % (cov * 100, fcover * 100),
                      top_score=top,
                      runner_up=survivors[1][1] if len(survivors) > 1 else None,
                      n_candidates=len(survivors), n_corpus=len(idx))
    else:
        above = survivors

    # 3. AMBIGUITY — a thin margin returns BOTH candidates, never nothing.
    #
    #    The previous gate rejected when top1/top2 fell below 1.4 and, measured
    #    against four queries whose answers are on disk, refused TWO of them (1.07
    #    and 1.13) — the exact failure this plugin exists to remove. Its threshold
    #    rested on three data points, as the plan stated at the definition site.
    #
    #    Two bodies that both cover the query are not grounds for silence; they are an
    #    ambiguous question with two honest answers. Showing both costs a line.
    top1 = above[0][1]
    top2 = above[1][1] if len(above) > 1 else None
    ratio = (top1 / top2) if (top2 and top2 > 0) else None
    ambiguous = ratio is not None and ratio < fratio

    # 4. ONLY NOW the K+1 current-repo presentation boost. It reorders by scope, not
    #    by score, so nothing after this point may make a score-order judgement.
    #    `repo_floor=None` on purpose: every input already cleared step 2, and a
    #    second floor here would double-gate the current-repo slot silently.
    rows = [{"file": rel, "score": s,
             "scope": corpus.scope_of_relpath(rel) or scope.GLOBAL}
            for rel, s in above]
    selected = scope.select_scoped(rows, cur_slug, k, repo_floor=None)

    return Result(HITS, hits=selected,
                  reason="top hit covers %.0f%% of the query%s" % (
                      cov * 100, "" if not ambiguous else
                      "; margin thin (%.2f) — close runners-up shown too" % ratio),
                  top_score=top1, runner_up=top2, ratio=ratio,
                  n_candidates=len(above), n_corpus=len(idx))


def default_store():
    """reflect's store path, derived the same way the rest of the plugin derives
    it: `~/.claude/projects/<$HOME-slug>/memory`."""
    home = os.path.expanduser("~")
    return os.path.join(home, ".claude", "projects", scope.slugify(home), "memory")


# --------------------------------------------------------------------- CLI

def main(argv):
    import argparse
    import json
    import time
    p = argparse.ArgumentParser(description="Local BM25 recall over the memory store")
    p.add_argument("query", nargs="+")
    p.add_argument("--store", default=None)
    p.add_argument("--cwd", default=None)
    p.add_argument("-k", type=int, default=DEFAULT_K)
    p.add_argument("--json", action="store_true")
    a = p.parse_args(argv)

    store = a.store or default_store()
    t0 = time.time()
    idx = build(store)
    t_build = time.time() - t0
    t0 = time.time()
    res = search(store, " ".join(a.query), cwd=a.cwd, k=a.k, index=idx)
    t_query = time.time() - t0

    if a.json:
        d = res.as_dict()
        d["build_ms"] = round(t_build * 1000, 1)
        d["query_ms"] = round(t_query * 1000, 2)
        print(json.dumps(d, indent=2))
        return 0
    print("status: %s (%s)" % (res.status, res.reason))
    for h in res.hits:
        print("  %8.2f  %s" % (h["score"], h["file"]))
    print("%d bodies, build %.0fms, query %.2fms"
          % (res.n_corpus, t_build * 1000, t_query * 1000))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
