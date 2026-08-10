#!/usr/bin/env python3
"""recall_cli_test.py — tests for the one-call recall CLI (plan U2, KTD8).

`reflect_cli.py recall` is the single mid-session recall call. It made four claims
that were previously documented and not true, and each one names the mutation in
`scripts/scoped-memory/reflect_cli.py` that must turn it red:

  1. IT RUNS THE LAYERS, IN ORDER. Declared triggers first and marked as such, then
     qmd `vsearch` (never `search`), then the local BM25 index when qmd did not
     answer. Mutations: drop the trigger-layer call; skip the local layer.
  2. AN ARMED COOLDOWN SKIPS QMD RATHER THAN RE-PAYING THE HANG. With a wedged qmd
     on PATH and the shared stamp armed, the call still returns — from the local
     index — in well under the budget, and SAYS the cooldown is why. Mutation: pass
     `force=True` into the retrieval Config so the gate is bypassed.
  3. IT RETURNS BODIES AND ALWAYS ENDS WITH A STATUS LINE, INCLUDING WHEN NOTHING
     MATCHED — and exits 0 either way (fail-open). Mutation: `return 1` on the
     no-match branch.
  4. `--here` AND `--deliberate` ARE REAL. `--here` is consumed as a flag (the query
     after it is still the query), scopes to the current repo resolved from `--cwd`,
     and shows no sibling repo's memory. `--deliberate` returns results the default
     gate rejects. Mutations: stop passing `cwd=` to the local layer; drop the
     deliberate `min_score`/`min_ratio` overrides.

Nothing here needs a healthy qmd — one scenario uses a stub that answers instantly,
one uses a stub that would hang if it were ever invoked (it must not be), and the
rest run with no qmd on PATH at all. Nothing here reads or writes the live store:
every run is pointed at a fixture store via `--store`, which is also where its
`RECALL.log` lands.

The environment is CONSTRUCTED, never inherited: the harness exports `SEEDED_RECALL_*`
vars (and the live settings pin `SEEDED_RECALL_TIMEOUT=0.05`, which makes every qmd
call return instantly-empty), so a test that inherits its environment fails for a
reason that looks like a bug in the code under test.

Run: `python3 tests/recall_cli_test.py`.
"""
import json
import os
import subprocess
import sys
import tempfile
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCOPED = os.path.join(REPO, "scripts", "scoped-memory")
CLI = os.path.join(SCOPED, "reflect_cli.py")
sys.path.insert(0, SCOPED)
import scope        # noqa: E402
import triggers     # noqa: E402

PASS = 0
FAIL = 0


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  ok   - {name}")
    else:
        FAIL += 1
        print(f"  FAIL - {name}", file=sys.stderr)
        if detail:
            print("         " + detail.replace("\n", "\n         "),
                  file=sys.stderr)


# --------------------------------------------------------------- environment

#: Prefixes stripped from the inherited environment before every run. The harness
#: exports several of these and they redirect stamp paths, store paths and budgets
#: into whatever the PARENT was testing.
_STRIP_PREFIXES = ("SEEDED_RECALL_", "MEMORY_TRIGGER_", "MEMORY_LOCAL_", "MEMORY_ACT_")
_STRIP_NAMES = ("REFLECT_MEMORY_DIR", "MEMORY_DIR", "CLAUDE_SESSION_ID")


def env_for(bindir, flagdir, budget="5"):
    """A constructed environment: nothing about retrieval is inherited."""
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(_STRIP_PREFIXES) and k not in _STRIP_NAMES}
    env["PATH"] = (bindir + ":" if bindir else "") + "/usr/bin:/bin"
    env["SEEDED_RECALL_FLAG_DIR"] = flagdir
    env["SEEDED_RECALL_TIMEOUT"] = budget
    return env


def run_recall(store, env, *args, cwd=None):
    """`(stdout+stderr, exit_code, elapsed_seconds)` for one recall invocation."""
    cmd = [sys.executable, CLI, "recall", "--store", store] + list(args)
    t0 = time.monotonic()
    p = subprocess.run(cmd, capture_output=True, text=True, env=env,
                       cwd=cwd or store)
    return p.stdout + p.stderr, p.returncode, time.monotonic() - t0


# ------------------------------------------------------------------ fixtures

ROOT = tempfile.mkdtemp(prefix="recall-cli-test-")
STORE = os.path.join(ROOT, "store")
BIN_HEALTHY = os.path.join(ROOT, "bin-healthy")
BIN_WEDGED = os.path.join(ROOT, "bin-wedged")
NEUTRAL = os.path.join(ROOT, "neutral")          # a cwd that is not a git repo
for d in (STORE, BIN_HEALTHY, BIN_WEDGED, NEUTRAL):
    os.makedirs(d, exist_ok=True)


def write(relpath, text):
    path = os.path.join(STORE, relpath)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    return path


# A git-repo fixture, so `--here` has a real repo to resolve. Its slug is what the
# current-repo body is scoped to; the sibling body gets a slug that is nobody's.
HEREREPO = os.path.join(ROOT, "hererepo")
os.makedirs(HEREREPO, exist_ok=True)
subprocess.run(["git", "init", "-q", HEREREPO], capture_output=True)
HERE_SLUG = scope.resolve_repo_slug(HEREREPO)
SIBLING_SLUG = "-Users-nobody-projects-someoneelse"

# Filler bodies: BM25's idf is a property of the corpus, so a two-document store
# would make every term look rare and every score meaningless. These give the
# scored fixtures a corpus to stand out from.
for i in range(30):
    write("filler_%02d.md" % i,
          "---\nname: filler_%02d\n---\nRoutine note %02d about ordinary daily "
          "repository work, builds, notes and chores.\n" % (i, i))

# Case-2 shaped: the query "is this failing e2e shard a flake or a regression"
# should land decisively on this one.
write("reference_e2e_flake_triage.md", """---
name: reference_e2e_flake_triage
description: Deciding whether a red E2E shard blocks a merge — flake vs regression.
---
A DIFFERENT e2e test failing on each re-run is environment flake; the SAME e2e
test failing every re-run is a regression. Re-run the shard twice before calling
a failing e2e shard someone else's problem. E2E flake triage: shard, re-run,
compare the failing test names.
""")

# Declared trigger, deliberately WEAK on BM25 for the trigger query below: the
# point of layer 1 is that a memory whose author declared the situation surfaces
# whatever a ranker thinks of it.
write("reference_gh_conflicting.md", """---
name: reference_gh_conflicting
description: A CONFLICTING PR runs zero workflows, so no red checks is not green.
triggers:
  - literal: statusCheckRollup
---
Check gh pr view --json mergeable before diagnosing missing CI.
""")

# Scope fixtures for `--here`. The SIBLING carries the same rare terms MORE times,
# so it outranks the current-repo body: its absence from the output is then a
# suppression that happened, not a body that never scored.
HERE_Q = "quixotic dirigible rotation"
write(os.path.join("_scope", HERE_SLUG, "project_here_note.md"),
      "---\nname: project_here_note\n---\nHERETOKEN "
      + (HERE_Q + " ") * 6 + "\n")
write(os.path.join("_scope", SIBLING_SLUG, "project_sibling_note.md"),
      "---\nname: project_sibling_note\n---\nSIBLINGTOKEN "
      + (HERE_Q + " ") * 12 + "\n")

# Gate fixtures. FLATQ scores two near-identical bodies so the default separation
# gate rejects the pair; DELIBQ is the same shape with enough raw score to clear
# the relaxed floor. Both are junk-by-construction: the point is the gate, not the
# content.
# Junk under the CURRENT gate means LOW COVERAGE — a body that shares only part of
# the query's vocabulary. The previous pair contained the flat query verbatim, six
# and five times over, which made them junk only in the sense that their SCORES were
# close: under a coverage gate a body containing your entire query is a perfect
# match, not junk. Each carries one of the three query terms and nothing else, so the
# best any of them covers is 1/3.
write("gate_alpha.md", "---\nname: gate_alpha\n---\n"
      + "zorkmid " * 6 + "unrelated docker networking notes\n")
write("gate_beta.md", "---\nname: gate_beta\n---\n"
      + "zorkmid " * 5 + "unrelated postgres vacuum notes\n")
# And a pair that DOES fully cover a query, to exercise the thin-margin path: both
# answer it, so the gate must return them flagged rather than pick one or go silent.
write("ambig_one.md", "---\nname: ambig_one\n---\n"
      + "widget calibration procedure " * 4 + "\n")
write("ambig_two.md", "---\nname: ambig_two\n---\n"
      + "widget calibration procedure " * 3 + "\n")

manifest, problems = triggers.compile_manifest(STORE)
triggers.write_manifest(STORE, manifest)

# Stub qmds. Healthy: instant valid vsearch JSON, a body, an empty status.
with open(os.path.join(BIN_HEALTHY, "qmd"), "w") as fh:
    fh.write("""#!/usr/bin/env bash
case "$1" in
  vsearch) printf '[{"file":"qmd_stub_body.md","title":"Qmd Stub","score":0.9}]' ;;
  get)     printf 'QMDSTUBTOKEN body content from the vector layer\\n' ;;
  status)  printf 'QMD Status\\nPending: 0 need embedding\\n' ;;
  *)       exit 0 ;;
esac
""")
os.chmod(os.path.join(BIN_HEALTHY, "qmd"), 0o755)

# Wedged: it must never be invoked in the cooldown scenario. If it ever is, the
# call blocks for the whole budget and the elapsed assertion catches it.
with open(os.path.join(BIN_WEDGED, "qmd"), "w") as fh:
    fh.write("#!/usr/bin/env bash\nsleep 300\n")
os.chmod(os.path.join(BIN_WEDGED, "qmd"), 0o755)

RECALL_LOG = os.path.join(STORE, "RECALL.log")
CASE2_Q = "is this failing e2e shard a flake or a regression"
FLAT_Q = "zorkmid quibble frobnitz"

print("== fixtures ==")
check("trigger manifest compiled with the declared memory",
      manifest["count"] >= 1 and any(e["memory"] == "reference_gh_conflicting"
                                     for e in manifest["entries"]),
      json.dumps(manifest)[:400])
check("no trigger validation problems in the fixture", not problems, str(problems))
check("the here-repo fixture resolved to a real repo slug",
      HERE_SLUG != scope.GLOBAL, HERE_SLUG)

# ------------------------------------------------- 1. healthy qmd answers (layer 2)
print()
print("== layer 2: healthy qmd ==")
F = os.path.join(ROOT, "flags-healthy"); os.makedirs(F, exist_ok=True)
out, rc, _el = run_recall(STORE, env_for(BIN_HEALTHY, F), "--query", CASE2_Q,
                          cwd=NEUTRAL)
check("healthy qmd: the stub body text is in the output",
      "QMDSTUBTOKEN" in out, out)
check("healthy qmd: the source line names the qmd layer",
      "[via: qmd]" in out, out)
check("healthy qmd: the status line says qmd answered",
      "qmd vsearch answered" in out, out)
check("healthy qmd: exit 0", rc == 0, "rc=%d" % rc)
log = open(RECALL_LOG).read() if os.path.exists(RECALL_LOG) else ""
check("healthy qmd: a RECALL.log line was written with source `cli`",
      any(r.split()[2:5] == ["cli", "qmd_stub_body", "qmd"]
          for r in log.splitlines() if len(r.split()) >= 5), log)

# ------------------------------------- 2. armed cooldown skips a wedged qmd (KTD8)
print()
print("== layer 2 skipped: armed cooldown ==")
FC = os.path.join(ROOT, "flags-cooldown"); os.makedirs(FC, exist_ok=True)
with open(os.path.join(FC, "qmd-failure-stamp"), "w") as fh:
    json.dump({"count": 2, "ts": time.time(), "budget": 6.0, "source": "seeded"}, fh)
out, rc, el = run_recall(STORE, env_for(BIN_WEDGED, FC), "--query", CASE2_Q,
                         cwd=NEUTRAL)
check("armed cooldown: the wedged qmd was never probed (returned fast)",
      el < 3.0, "elapsed=%.2fs" % el)
check("armed cooldown: the output names the cooldown as the reason",
      "cooldown is armed" in out, out)
check("armed cooldown: local-index results came back anyway",
      "reference_e2e_flake_triage" in out and "[via: local-fallback]" in out, out)
check("armed cooldown: exit 0", rc == 0, "rc=%d" % rc)

# ------------------------------------------- 3. no qmd on PATH: the local fallback
print()
print("== layer 3: local index, no qmd on PATH ==")
FL = os.path.join(ROOT, "flags-local"); os.makedirs(FL, exist_ok=True)
out, rc, _el = run_recall(STORE, env_for(None, FL), "--query", CASE2_Q, cwd=NEUTRAL)
check("no qmd: the local index answered", "[via: local-fallback]" in out, out)
check("no qmd: the BODY is printed, not just the title",
      "A DIFFERENT e2e test failing on each re-run" in out, out)
check("no qmd: the status line names the local layer and its verdict",
      "local index: hits" in out, out)
check("no qmd: exit 0", rc == 0, "rc=%d" % rc)

# ------------------------------------- 4. flat query: explicit silence, still exit 0
print()
print("== the silence path ==")
FF = os.path.join(ROOT, "flags-flat"); os.makedirs(FF, exist_ok=True)
out, rc, _el = run_recall(STORE, env_for(None, FF), "--query", FLAT_Q, cwd=NEUTRAL)
check("flat query: says `no confident match` rather than guessing",
      "no confident match" in out, out)
check("flat query: the status line explains WHY the local layer was silent",
      "below" in out, out)
check("flat query: gives a next step", "--deliberate" in out, out)
check("flat query: EXIT 0 — fail-open, a help never fails its caller",
      rc == 0, "rc=%d" % rc)

# --------------------------------------------------- 5. deliberate relaxes the gate
print()
print("== deliberate mode ==")
FD = os.path.join(ROOT, "flags-delib"); os.makedirs(FD, exist_ok=True)
outd, rcd, _el = run_recall(STORE, env_for(None, FD), "--deliberate",
                            "--query", FLAT_Q, cwd=NEUTRAL)
check("deliberate: returns what the DEFAULT gate rejected",
      "gate_alpha" in outd and "no confident match" not in outd, outd)
check("deliberate: the status line declares the relaxed mode",
      "deliberate mode" in outd, outd)
check("deliberate: exit 0", rcd == 0, "rc=%d" % rcd)

# ------------------------------------------------------------------- 6. `--here`
print()
print("== --here ==")
FH = os.path.join(ROOT, "flags-here"); os.makedirs(FH, exist_ok=True)
# The query text follows `--here` positionally: if the flag were consumed as a
# value-taking flag, the query would be eaten and nothing would match.
out, rc, _el = run_recall(STORE, env_for(None, FH), "--here", "--cwd", HEREREPO,
                          HERE_Q, cwd=NEUTRAL)
check("--here: this repo's own memory surfaces",
      "HERETOKEN" in out, out)
check("--here: a sibling repo's memory does NOT surface",
      "SIBLINGTOKEN" not in out, out)
check("--here: the status line names the repo scope",
      "repo-scoped to %s" % HERE_SLUG in out, out)
check("--here: is consumed as a flag — the query after it is still the query",
      "--here" not in out.split("recall:")[0], out)
check("--here: exit 0", rc == 0, "rc=%d" % rc)

# --------------------------------- 7. layer 1: a declared trigger outranks the ranker
print()
print("== layer 1: declared triggers ==")
FT = os.path.join(ROOT, "flags-trigger"); os.makedirs(FT, exist_ok=True)
# The query must do two jobs: fire the declared trigger AND leave the ranker with a
# real top hit, so the ordering assertion below is not comparing against nothing.
# The previous phrasing spanned two topics and, under a coverage gate, no single body
# covered enough of it — the ranker went silent and the "is it FIRST" check had
# nothing to be first OF. Phrased in the e2e body's own vocabulary, the ranker
# answers confidently while `statusCheckRollup` still fires the trigger.
TRIG_Q = ("statusCheckRollup — the failing e2e shard, flake or regression, "
          "re-run the shard and compare the failing test names")
out, rc, _el = run_recall(STORE, env_for(None, FT), "--query", TRIG_Q, cwd=NEUTRAL)
check("trigger: the declared memory surfaced", "reference_gh_conflicting" in out, out)
check("trigger: it is MARKED as a trigger match",
      "[via: declared trigger]" in out, out)
check("trigger: it is FIRST, ahead of the higher-BM25 body",
      0 <= out.find("reference_gh_conflicting") < out.find("reference_e2e_flake_triage"),
      out)
check("trigger: the ranker's own top hit is what it was ahead OF (test is live)",
      "reference_e2e_flake_triage" in out, out)
check("trigger: the status line counts the declared match",
      "declared trigger match" in out, out)
check("trigger: exit 0", rc == 0, "rc=%d" % rc)

# ------------------------------------------------------- 8. the drift this unit ends
print()
print("== KTD8: one retrieval regime ==")
src = open(CLI, encoding="utf-8").read()
check("the CLI no longer shells `qmd search` (BM25) behind the hook's back",
      '"search"' not in src and "'search'" not in src, "")
check("the CLI goes through the shared retrieval module, not its own subprocess",
      "import retrieval" in src and "import subprocess" not in src, "")
check("the CLI never stamps qmd health itself (one signal, retrieval's)",
      "note_failure" not in src, "")

print()
print(f"recall_cli_test: {PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
