#!/usr/bin/env python3
"""recall-eval.py — Phase B spike (U3). Measure cold-tier recall quality and
latency across candidate retrieval mechanisms, to decide how seeded-recall must
surface a faded (cold) memory from a realistic, paraphrased prompt.

Mechanisms compared (all against the live `claude-memory` QMD collection):
  - bm25_full   : today's behavior — full prompt -> `qmd search` (BM25).
  - vsearch     : full prompt -> `qmd vsearch` (vector similarity).
  - keyword_bm25: strip the prompt to content terms -> `qmd search` (BM25).

Metrics: recall@1, recall@3 (the K seeded-recall injects), and per-query wall
latency (mean / p50 / max). A hit = the expected memory slug appears in the
result file path at that rank.

This is a measurement harness — its deliverable is the comparison table and a
recommendation, not shipped behavior. Run: `python3 scripts/spikes/recall-eval.py`.

The daemon option (`qmd mcp --http --daemon`) is characterized in the writeup
rather than benchmarked here: it would yield vsearch-quality recall at warm
(sub-second) latency by keeping the embedding model loaded, at the cost of a
managed background process. This harness measures the no-daemon candidates.
"""
import json
import os
import subprocess
import sys
import time

COLLECTION = os.environ.get("RECALL_EVAL_COLLECTION", "claude-memory")
K = 3
HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURE = os.path.join(HERE, "recall-fixture.jsonl")

# Minimal English stopword set for keyword extraction — deterministic, no deps.
STOP = set("""a an the of to in on at for with and or but is are was were be been
being this that these those it its as by from into about over under i my me we
our you your he she they them his her their if then else so not no do does did
how what when where why which who whom whose can could should would will shall
may might must me again still seems seem some any all more most other another
actually just like mid right left thing things stuff somehow into onto off out
up down again does doing get got make made keep kept run runs running""".split())


def run(args, timeout=30):
    t0 = time.monotonic()
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        dt = time.monotonic() - t0
        if r.returncode != 0:
            return None, dt
        return r.stdout, dt
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
        return None, time.monotonic() - t0


def results(stdout):
    try:
        d = json.loads(stdout or "[]")
        return [r.get("file", "") for r in d if isinstance(r, dict)]
    except Exception:
        return []


def keywords(prompt):
    toks = []
    for w in prompt.lower().replace("'", "").split():
        w = "".join(c for c in w if c.isalnum())
        if len(w) >= 3 and w not in STOP:
            toks.append(w)
    # keep order, dedupe, cap to a handful of content terms
    seen, out = set(), []
    for w in toks:
        if w not in seen:
            seen.add(w)
            out.append(w)
    return " ".join(out[:6])


MECHANISMS = {
    "bm25_full":    lambda p: run(["qmd", "search", "-c", COLLECTION, "--format", "json", "--", p]),
    "vsearch":      lambda p: run(["qmd", "vsearch", "-c", COLLECTION, "--format", "json", "--", p]),
    "keyword_bm25": lambda p: run(["qmd", "search", "-c", COLLECTION, "--format", "json", "--", keywords(p)]),
}


def rank_of(files, expect):
    for i, f in enumerate(files):
        if expect in f:
            return i
    return None


def main():
    cases = [json.loads(l) for l in open(FIXTURE) if l.strip()]
    print(f"recall-eval: {len(cases)} cases, collection={COLLECTION}, K={K}\n")
    summary = {}
    for name, fn in MECHANISMS.items():
        hit1 = hit3 = 0
        lats = []
        misses = []
        for c in cases:
            out, dt = fn(c["prompt"])
            lats.append(dt)
            files = results(out)
            rank = rank_of(files, c["expect"])
            if rank == 0:
                hit1 += 1
            if rank is not None and rank < K:
                hit3 += 1
            else:
                misses.append(c["expect"])
        lats.sort()
        n = len(cases)
        summary[name] = {
            "recall@1": hit1 / n,
            "recall@3": hit3 / n,
            "lat_mean": sum(lats) / n,
            "lat_p50": lats[n // 2],
            "lat_max": lats[-1],
            "misses": misses,
        }

    print(f"{'mechanism':<14} {'recall@1':>9} {'recall@3':>9} {'lat_mean':>9} {'lat_p50':>8} {'lat_max':>8}")
    print("-" * 62)
    for name, s in summary.items():
        print(f"{name:<14} {s['recall@1']:>9.2f} {s['recall@3']:>9.2f} "
              f"{s['lat_mean']:>8.2f}s {s['lat_p50']:>7.2f}s {s['lat_max']:>7.2f}s")
    print()
    for name, s in summary.items():
        if s["misses"]:
            print(f"{name} missed@{K}: {sorted(set(s['misses']))}")
    return summary


if __name__ == "__main__":
    main()
