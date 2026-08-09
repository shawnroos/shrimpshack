#!/usr/bin/env python3
"""local_index_test.py — tests for the qmd-free ranked index + confidence gate (U1).

The unit makes four claims. Each one names the mutation that must turn it red:

  1. THE FLOOR IS CALIBRATED AND LOAD-BEARING (KTD12). A flat-scoring query is
     silenced BY THE FLOOR — the same fixture's separation is 5.10 and would sail
     through the ratio condition, so nothing else can be doing the work. Reverting
     the floor to the qmd `recall_floor` band (0.45-0.60) surfaces that same
     rubbish, which is asserted directly here. Mutation: point `floor_min()` at
     `memory_activation.recall_floor`, or normalize scores by top1.
  2. THE GATE RUNS BEFORE `select_scoped` (KTD15). Proved with a current-repo body
     that clears the floor but ranks third: the verdict must come from the two
     ancestors' ratio, not from the scope-boosted position-1 entry. Mutation: swap
     steps 3 and 4 in `search`.
  3. SIBLINGS ARE GONE BEFORE ANY SCORE IS READ. Proved with a sibling scoring
     ABOVE the survivors such that including it flips the verdict from hits to
     below-gate. Mutation: drop the `classify(...) != "sibling"` filter.
  4. SINGLETON AND ZERO-SCORE BEHAVIOR IS SPECIFIED, NOT DEFAULTED. One candidate
     over the floor passes on the floor ALONE (no ratio); nothing over the floor
     returns the explicit below-gate result and never a best-effort top hit.

Two fixture regimes, on purpose. Score-scale behavior (claims 1 and 4) runs against
REAL FILES so the shipped default floor is the thing being exercised. Order-of-
operations behavior (claims 2 and 3) runs against a stub index, because those
assertions are about exact score positions and a fixture that reaches them by
accident of tokenization is not a test.

Nothing here shells qmd, and nothing reads the live store.
Run: `python3 tests/local_index_test.py`.
"""
import os
import random
import subprocess
import sys
import tempfile
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.join(REPO, "scripts")
sys.path.insert(0, SCRIPTS)
sys.path.insert(0, os.path.join(SCRIPTS, "scoped-memory"))
import corpus                      # noqa: E402
import local_index as li           # noqa: E402
import memory_activation as ma     # noqa: E402
import scope                       # noqa: E402

PASS = 0
FAIL = 0


def check(name, cond):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  ok   - {name}")
    else:
        FAIL += 1
        print(f"  FAIL - {name}", file=sys.stderr)


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def git_repo(parent, name):
    """A real git repo, because `scope.resolve_repo_slug` shells git and a faked
    slug would test the fake."""
    d = os.path.join(parent, name)
    os.makedirs(d, exist_ok=True)
    subprocess.run(["git", "init", "-q", d], capture_output=True)
    return d


# --------------------------------------------------------------- fixtures

FILLER = {
    "feedback_squash_on_pr_landing":
        "Shawn prefers a squash merge when a pull request lands.",
    "reference_cp_is_interactive_in_shell":
        "cp and mv are aliased -i in this shell and prompt before overwrite.",
    "feedback_worktrees_automatic":
        "Worktrees are created automatically on fan-out and never surfaced.",
    "reference_macos_cpu_triage":
        "Load average lies on this box; sort by accumulated TIME instead of percent CPU.",
    "project_brand_foundry_ports":
        "The brand foundry backend consolidated port happens after end to end verification.",
    "feedback_prefer_cli_over_mcp":
        "Prefer a CLI over an MCP tool; verify existence on first failure not pre-flight.",
    "reference_agent_browser_click_coords":
        "agent-browser clicks in CSS pixels while screenshots are DPR scaled.",
    "feedback_save_aggressively":
        "Default to saving memories; memory is cheap and missing context is expensive.",
    "reference_ldcli_flag_toggle":
        "Toggle a LaunchDarkly flag per environment with a JSON patch not a semantic patch.",
    "project_logo_grouping_masked_by_dedup":
        "Cross instance logo grouping never worked because duplicate detections disguised it.",
    "feedback_pgrep_ps_env_leak":
        "Never run pgrep -fl on a secret bearing process; it dumps the environment.",
    "reference_slate_datadog_only_prod":
        "Datadog initializes only on production and stage so preview logging vanishes.",
    "feedback_deterministic_over_probabilistic":
        "Do not ship a probabilistic first version when a deterministic one exists.",
    "reference_qmd_collections":
        "The qmd collections are claude-memory, claude-handoffs and slate-calls.",
    "project_memory_recall_plan":
        "Mid session memory recall layers declared triggers, vector search and a local index.",
    "feedback_round2_review":
        "A round two review catches regressions introduced by round one fixes.",
    "reference_gh_run_watch_false_green":
        "gh run watch follows one workflow and can exit zero while the pull request is red.",
    "feedback_check_pr_base_branch":
        "A pull request base branch is not always the repository default; read it before merging.",
    "project_telemetry_split":
        "Split the recall telemetry from the use log so each answers its own question.",
    "reference_zsh_no_wordsplit":
        "zsh does not word split an unquoted variable so a flag string arrives as one argument.",
}

CASE2 = """---
name: reference_e2e_flake_vs_regression_triage
description: triage a red E2E shard as flake or regression
---
Deciding whether a red E2E shard blocks a merge. A DIFFERENT test failing on each
re-run is environment flake. The SAME test failing every re-run is a regression that
belongs to us. Six failing shards is not by itself a regression signal: re-run the
shards, compare which test failed, and only then judge flake versus regression.
"""

RUNNER_UP = """---
name: project_ci_shard_layout
description: how the CI pipeline splits E2E specs into shards and re-runs them
---
The CI pipeline splits the E2E specs into shards so a run finishes faster. A shard
that goes red is re-run once before it reports failing, and a shard failing on
re-run is reported differently from a shard failing once.
"""

TWIN = """---
name: project_ci_shard_retry_policy
description: the retry policy for a failing E2E shard on re-run
---
The retry policy for the E2E shards: a shard failing once is re-run, and a shard
still failing on re-run is reported. Different shards retry independently.
"""

# Case 1 shape: the memory that actually covers the situation shares almost no
# vocabulary with the observed output. Its incidental match is what BM25 finds.
WEAK = """---
name: reference_gh_pr_thin_status_output
description: gh pr view returned thin status output
---
A pull request whose checks look absent may simply be unbuildable. Read the
mergeable field before diagnosing missing continuous integration.
"""

CASE2_Q = "six failing E2E shards different test on each re-run flake or regression"
FLAT_Q = "statusCheckRollup returned thin output no checks reported"
SINGLETON_Q = "pgrep secret bearing process dumps the environment"
NOTHING_Q = "squash"


def case_store(parent, case2_at=None, name="store"):
    """The fixture store. `case2_at` relocates the covering memory to a store-
    relative path (used to put it under `_scope/<slug>/`) instead of the flat root
    — RELOCATED, not copied, because two near-identical bodies would sit at ratio
    ~1.0 and the separation condition, not scope, would decide the verdict."""
    d = os.path.join(parent, name)
    for n, t in FILLER.items():
        write(os.path.join(d, n + ".md"), "---\nname: %s\n---\n%s\n" % (n, t))
    write(os.path.join(d, case2_at or "reference_e2e_flake_vs_regression_triage.md"),
          CASE2)
    write(os.path.join(d, "project_ci_shard_layout.md"), RUNNER_UP)
    write(os.path.join(d, "project_ci_shard_retry_policy.md"), TWIN)
    write(os.path.join(d, "reference_gh_pr_thin_status_output.md"), WEAK)
    return d


class StubIndex:
    """An index with hand-set scores. Used only where the assertion is about score
    POSITIONS surviving the pipeline — a real fixture that happens to tokenize into
    the right order is testing tokenization, not order of operations."""

    def __init__(self, ranked):
        self.ranked = sorted(ranked, key=lambda p: (-p[1], p[0]))

    def __len__(self):
        return len(self.ranked)

    def score_all(self, query):
        return list(self.ranked)


# ------------------------------------------- 1. Case 2 ranks first + clears gate
print("== Case 2: the covered query clears the gate ==")
with tempfile.TemporaryDirectory() as tmp:
    d = case_store(tmp)
    idx = li.build(d)
    ranked = idx.score_all(CASE2_Q)

    check("the covering memory ranks first",
          ranked[0][0] == "reference_e2e_flake_vs_regression_triage.md")
    print("  info - top3: " + ", ".join("%s=%.2f" % (r, s) for r, s in ranked[:3]))

    res = li.search(d, CASE2_Q, cwd=tmp)
    check("verdict is hits", res.status == li.HITS)
    check("the covering memory is returned",
          any(h["file"] == "reference_e2e_flake_vs_regression_triage.md"
              for h in res.hits))
    check("top score cleared the shipped floor", res.top_score >= li.DEFAULT_FLOOR_MIN)
    check("separation was evaluated and cleared",
          res.ratio is not None and res.ratio >= li.DEFAULT_FLOOR_RATIO)
    check("the reason states which conditions were met",
          "floor" in res.reason and "separation" in res.reason)

# --------------------------- 2. the flat query is silenced BY THE FLOOR (KTD12)
print()
print("== the calibrated floor is load-bearing (KTD12) ==")
with tempfile.TemporaryDirectory() as tmp:
    d = case_store(tmp)
    idx = li.build(d)
    flat = idx.score_all(FLAT_Q)
    flat_top, flat_second = flat[0][1], flat[1][1]

    res = li.search(d, FLAT_Q, cwd=tmp, index=idx)
    check("verdict is below_gate", res.status == li.BELOW_GATE)
    check("no hits are returned", res.hits == [])
    check("the reason names the floor", "floor" in res.reason)

    # The point of this fixture: separation is NOT what silences it. If it were,
    # reverting the floor would prove nothing.
    check("separation alone would have PASSED this query (%.2f >= %.2f)"
          % (flat_top / flat_second, li.DEFAULT_FLOOR_RATIO),
          flat_top / flat_second >= li.DEFAULT_FLOOR_RATIO)

    # Reverted to the qmd floor — the arithmetic KTD12 describes, run for real.
    qmd_floor = ma.recall_floor(1.3)          # a fresh memory: the LOWEST qmd floor
    qmd_floor_faded = ma.recall_floor(0.0)    # a faded one: the HIGHEST
    reverted = li.search(d, FLAT_Q, cwd=tmp, index=idx, min_score=qmd_floor)
    reverted_faded = li.search(d, FLAT_Q, cwd=tmp, index=idx, min_score=qmd_floor_faded)
    check("with the qmd floor (%.2f) the same rubbish SURFACES" % qmd_floor,
          reverted.status == li.HITS)
    check("even the qmd floor's faded end (%.2f) lets it through" % qmd_floor_faded,
          reverted_faded.status == li.HITS)
    check("the shipped floor is orders above the whole qmd floor band",
          li.DEFAULT_FLOOR_MIN > 10 * qmd_floor_faded)
    print("  info - flat query top=%.2f second=%.2f; shipped floor=%.2f; qmd band=%.2f-%.2f"
          % (flat_top, flat_second, li.DEFAULT_FLOOR_MIN, qmd_floor, qmd_floor_faded))

    # And not top1-relative, which would make top1 exactly 1.0 for every result set.
    check("scores returned are RAW, not normalized to a top1 of 1.0",
          li.search(d, CASE2_Q, cwd=tmp, index=idx).top_score > 1.5)

# ------------------------------------------------ 3. singleton / zero behavior
print()
print("== singleton and zero-score behavior ==")
with tempfile.TemporaryDirectory() as tmp:
    d = case_store(tmp)
    idx = li.build(d)

    above = [(r, s) for r, s in idx.score_all(SINGLETON_Q) if s >= li.DEFAULT_FLOOR_MIN]
    check("fixture really does yield exactly one floor-clearing candidate",
          len(above) == 1)
    res = li.search(d, SINGLETON_Q, cwd=tmp, index=idx)
    check("a singleton passes on the floor alone", res.status == li.HITS)
    check("separation is NOT evaluated for a singleton", res.ratio is None)
    check("its runner-up is not reported as a gate input", res.runner_up is None)
    check("the singleton is the returned hit",
          [h["file"] for h in res.hits] == ["feedback_pgrep_ps_env_leak.md"])

    res = li.search(d, NOTHING_Q, cwd=tmp, index=idx)
    check("nothing clears the floor -> below_gate", res.status == li.BELOW_GATE)
    check("no best-effort top hit is returned", res.hits == [])
    check("the top score is still reported so a caller can say how close it was",
          res.top_score is not None and res.top_score < li.DEFAULT_FLOOR_MIN)

# ---------------------------- 4. the gate runs BEFORE select_scoped (KTD15)
print()
print("== gate order: score-ordered, before the K+1 boost (KTD15) ==")
with tempfile.TemporaryDirectory() as tmp:
    repo = git_repo(tmp, "myrepo")
    slug = scope.resolve_repo_slug(repo)
    cur = os.path.join("_scope", slug, "project_current.md")

    # Two ancestors at 30.0 / 18.0 (ratio 1.67, clears 1.4) and a current-repo body
    # at 14.0 — over the floor, third by score. select_scoped puts it FIRST. Run the
    # gate after that and it compares 14.0/30.0 = 0.47 and rejects the query.
    stub = StubIndex([("reference_anc_top.md", 30.0),
                      ("reference_anc_second.md", 18.0),
                      (cur, 14.0)])
    res = li.search(tmp, "q", cwd=repo, index=stub)

    check("verdict is hits (the ancestors' ratio decided it)", res.status == li.HITS)
    check("the gate read the ANCESTORS' top score, not the boosted entry",
          res.top_score == 30.0)
    check("the gate read the ANCESTORS' runner-up", res.runner_up == 18.0)
    check("the evaluated ratio is 30/18, not 14/30",
          abs(res.ratio - 30.0 / 18.0) < 1e-9)
    check("the K+1 boost still applies to PRESENTATION: current repo is first",
          res.hits[0]["file"] == cur)
    check("the ancestors follow it in score order",
          [h["file"] for h in res.hits[1:]]
          == ["reference_anc_top.md", "reference_anc_second.md"])

    # A current-repo body BELOW the floor must not be resurrected into position 1.
    stub = StubIndex([("reference_anc_top.md", 30.0),
                      ("reference_anc_second.md", 18.0),
                      (cur, 3.0)])
    res = li.search(tmp, "q", cwd=repo, index=stub)
    check("a below-floor current-repo body is not boosted back in",
          all(h["file"] != cur for h in res.hits))

# ------------------------- 5. siblings are dropped before any score is read
print()
print("== siblings leave before the gate does arithmetic ==")
with tempfile.TemporaryDirectory() as tmp:
    repo = git_repo(tmp, "myrepo")
    other = git_repo(tmp, "otherrepo")
    sib = os.path.join("_scope", scope.resolve_repo_slug(other), "project_sibling.md")

    # Sibling 32.0 above ancestors 30.0 / 18.0. Survivors ratio 1.67 -> PASS.
    # Counting the sibling gives 32/30 = 1.07 -> BELOW GATE. The verdict itself
    # flips, so this cannot go green with the sibling filter removed.
    stub = StubIndex([(sib, 32.0),
                      ("reference_anc_top.md", 30.0),
                      ("reference_anc_second.md", 18.0)])
    res = li.search(tmp, "q", cwd=repo, index=stub)

    check("verdict is hits (survivors only)", res.status == li.HITS)
    check("separation was computed over survivors, not the discarded sibling",
          res.top_score == 30.0 and res.runner_up == 18.0)
    check("the sibling appears nowhere in the hits",
          all(h["file"] != sib for h in res.hits))

    # Every match a sibling -> nothing to rank at all, and it says so.
    res = li.search(tmp, "q", cwd=repo, index=StubIndex([(sib, 90.0)]))
    check("a store of nothing but siblings returns empty, not below_gate",
          res.status == li.EMPTY)
    check("the reason names the scope suppression", "repo" in res.reason)

# ------------------- 6. a real _scope/<other-repo>/ body, queried from elsewhere
print()
print("== real scoped body suppressed from an unrelated cwd ==")
with tempfile.TemporaryDirectory() as tmp:
    here = git_repo(tmp, "here")
    there = git_repo(tmp, "there")
    there_slug = scope.resolve_repo_slug(there)
    scoped_rel = os.path.join("_scope", there_slug,
                              "reference_e2e_flake_vs_regression_triage.md")
    d = case_store(tmp, case2_at=scoped_rel)

    idx = li.build(d)
    check("the scoped body IS in the corpus", scoped_rel in idx.docs)
    ranked = dict(idx.score_all(CASE2_Q))
    check("and it does score highly on the query",
          ranked.get(scoped_rel, 0) >= li.DEFAULT_FLOOR_MIN)

    res = li.search(d, CASE2_Q, cwd=here, index=idx)
    check("queried from an unrelated repo it is suppressed",
          all(h["file"] != scoped_rel for h in res.hits))

    res_there = li.search(d, CASE2_Q, cwd=there, index=idx)
    check("queried from its own repo it comes back, boosted to first",
          res_there.hits and res_there.hits[0]["file"] == scoped_rel)
    check("its scope slug is reported alongside it",
          res_there.hits[0]["scope"] == there_slug)

# -------------------------------------------------- 7. fail-open degenerate cases
print()
print("== fail-open on degenerate input ==")
with tempfile.TemporaryDirectory() as tmp:
    missing = os.path.join(tmp, "does-not-exist")
    res = li.search(missing, CASE2_Q, cwd=tmp)
    check("a missing store returns empty without raising", res.status == li.EMPTY)
    check("and reports zero corpus", res.n_corpus == 0)

    bare = os.path.join(tmp, "bare")
    os.makedirs(bare)
    check("an empty store dir returns empty",
          li.search(bare, CASE2_Q, cwd=tmp).status == li.EMPTY)

    excluded_only = os.path.join(tmp, "excluded")
    write(os.path.join(excluded_only, "MEMORY.md"), "# Memory Index\n")
    write(os.path.join(excluded_only, "RECALL.log"), "2026-08-09 x local\n")
    check("a store of nothing but excluded files returns empty",
          li.search(excluded_only, CASE2_Q, cwd=tmp).status == li.EMPTY)

    d = case_store(tmp)
    check("a query with no usable terms returns empty",
          li.search(d, "the and of", cwd=tmp).status == li.EMPTY)
    check("an entirely empty query returns empty",
          li.search(d, "", cwd=tmp).status == li.EMPTY)
    check("a query matching nothing in the corpus returns empty",
          li.search(d, "zzzqqxx unrelatedtoken", cwd=tmp).status == li.EMPTY)

    # A body that is not decodable UTF-8 must cost one body, not the whole build.
    with open(os.path.join(d, "reference_binary_junk.md"), "wb") as f:
        f.write(b"\xff\xfe\x00\x01 binary junk\n")
    check("an undecodable body does not take the build down",
          len(li.build(d)) == len(corpus.body_paths(d)))

    # A store dir that exists but cannot be read. The walk swallows it; the caller
    # gets an empty result, not an exception, because every consumer is fail-open.
    locked = os.path.join(tmp, "locked")
    write(os.path.join(locked, "feedback_x.md"), "---\nname: x\n---\nshard flake\n")
    os.chmod(locked, 0o000)
    try:
        check("an unreadable store dir returns empty rather than raising",
              li.search(locked, CASE2_Q, cwd=tmp).status == li.EMPTY)
    finally:
        os.chmod(locked, 0o700)

    # Unparseable env tunables must not take the retrieval path down either. The
    # try/finally matters: a failing check here would otherwise leak a floor
    # override into every test below it.
    try:
        os.environ["MEMORY_LOCAL_FLOOR_MIN"] = "not-a-number"
        check("a garbage floor env var falls back to the default",
              li.floor_min() == li.DEFAULT_FLOOR_MIN)
        os.environ["MEMORY_LOCAL_FLOOR_MIN"] = "99999"
        check("a valid floor env var IS honoured",
              li.search(d, CASE2_Q, cwd=tmp).status == li.BELOW_GATE)
    finally:
        os.environ.pop("MEMORY_LOCAL_FLOOR_MIN", None)
    try:
        os.environ["MEMORY_LOCAL_FLOOR_RATIO"] = "99"
        check("a valid ratio env var IS honoured",
              li.search(d, CASE2_Q, cwd=tmp).status == li.BELOW_GATE)
    finally:
        os.environ.pop("MEMORY_LOCAL_FLOOR_RATIO", None)

# ---------------------------------------------- 8. live-sized corpus timing
print()
print("== live-shaped fixture (886 bodies, nested scope dirs) ==")
with tempfile.TemporaryDirectory() as tmp:
    d = os.path.join(tmp, "store")
    N_FLAT, N_SCOPED = 599, 287
    SLUGS = ["-Users-x-projects-repo%02d" % i for i in range(13)]
    rnd = random.Random(7)
    words = ["agent", "session", "branch", "deploy", "cache", "render", "token",
             "review", "commit", "hook", "plugin", "fixture", "budget", "worktree",
             "preview", "bundle", "schema", "queue", "probe", "harness", "runner",
             "stamp", "cooldown", "vector", "scope", "ancestor", "sibling",
             "manifest", "trigger", "telemetry", "shard", "spec", "pipeline"]

    def filler(name):
        # ~370 tokens, matching the live store's measured average document length.
        return ("---\nname: %s\ndescription: hook for %s\n---\n%s\n"
                % (name, name, " ".join(rnd.choice(words) for _ in range(370))))

    for i in range(N_FLAT):
        write(os.path.join(d, "feedback_flat_%04d.md" % i),
              filler("feedback_flat_%04d" % i))
    for i in range(N_SCOPED):
        write(os.path.join(d, "_scope", SLUGS[i % len(SLUGS)],
                           "project_scoped_%04d.md" % i),
              filler("project_scoped_%04d" % i))

    check("fixture enumerates all 886 bodies", len(corpus.body_paths(d)) == 886)

    t0 = time.time()
    idx = li.build(d)
    build_ms = (time.time() - t0) * 1000
    check("every body is indexed, scoped subtree included", len(idx) == 886)
    check("scoped bodies really are in the index",
          any(r.startswith("_scope" + os.sep) for r in idx.docs))

    t0 = time.time()
    idx.score_all("shard pipeline cooldown telemetry stamp vector")
    query_ms = (time.time() - t0) * 1000

    # Loose bounds on purpose: a regression tripwire against an accidental per-body
    # re-read or a per-query rebuild, not a benchmark. The build is the cost KTD6
    # accepted in exchange for killing the staleness class.
    check("live-shaped build within budget (%.0fms < 4000ms)" % build_ms,
          build_ms < 4000)
    check("live-shaped query within budget (%.1fms < 250ms)" % query_ms,
          query_ms < 250)
    print("  info - 886-body build %.0fms, query %.1fms, avgdl %.0f, vocab %d"
          % (build_ms, query_ms, idx.avgdl, len(idx.df)))

# ------------------------------------------------- 9. the constants themselves
print()
print("== shipped tunables ==")
# A BAND, not an equality: recalibrating the floor as the corpus grows is expected
# and must not break a test. What must never happen is the floor drifting back into
# qmd's [0,1] vector-score range, where it filters nothing.
check("the floor default is a raw-BM25 value, an order of magnitude above the qmd band",
      li.DEFAULT_FLOOR_MIN >= 10 * ma.recall_floor(0.0))
check("the separation default sits on the measured boundary",
      1.3 <= li.DEFAULT_FLOOR_RATIO <= 1.6)
check("floor and separation are two independent conditions, not one",
      li.floor_min() != li.floor_ratio())

print()
print(f"local_index_test: {PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
