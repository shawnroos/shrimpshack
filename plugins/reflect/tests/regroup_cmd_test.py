#!/usr/bin/env python3
"""regroup_cmd_test.py — tests for `/reflect regroup`, the grounding interrupt (plan U11).

The command is mostly instructions to an agent, and instructions cannot be unit
tested. Two things about it CAN be, and they are the two that have historically
broken:

  1. THE INVOCATION IN THE DOC ACTUALLY RUNS. `recall --here` was documented in
     this plugin's own SKILL.md for months and never implemented. So this test
     does not paraphrase the command's retrieval step — it EXTRACTS the fenced
     block from `commands/reflect-regroup.md` and runs it verbatim against a
     fixture store, and fails if it does not return bodies. Mutation: change any
     flag in the doc's block to one the CLI does not take.
  2. THE DOC'S FLAGS ARE LOAD-BEARING, NOT DECORATION. The same query is run
     twice against the same fixture: plain `recall` (default gate) rejects it,
     and the doc's block returns it. That is the doc's `--deliberate` doing work.
     Mutations: strip `--deliberate` from the doc's block, or drop the deliberate
     floor/ratio overrides in `reflect_cli.cmd_recall`.

Plus assertions on the doc's own text, because the properties that make this
command what it is live in prose and a later edit could soften them silently: it
takes NO argument, its first step is to STOP, and it is explicitly not a fix for
application failure (plan Open Question 1, decided).

DELIBERATELY NOT TESTED: the derivation and reporting steps. Whether an agent
extracts good situations from its own context, and whether it reports forward
instead of summarizing, is agent behavior — measured through telemetry
(`applied` lines annotated `regroup` in MEMORY_USE.log), not asserted here. A
unit test of that would be a hollow assertion about a string in a markdown file.

Nothing here needs qmd: every run has an empty PATH prefix and no qmd binary, so
the local BM25 layer answers. Nothing here reads or writes the live store — the
fixture store is passed via `REFLECT_MEMORY_DIR`, which is the env var the CLI's
own docstring documents, and which is also how the doc's block (which carries no
`--store`, because a real agent must hit the real store) can be run as written.

Run: `python3 tests/regroup_cmd_test.py`.
"""
import json
import os
import re
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # plugins/reflect
MARKET = os.path.join(os.path.dirname(os.path.dirname(REPO)),
                      ".claude-plugin", "marketplace.json")
DOC = os.path.join(REPO, "commands", "reflect-regroup.md")
CLI = os.path.join(REPO, "scripts", "scoped-memory", "reflect_cli.py")

PASS = 0
FAIL = 0


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print("  ok   - %s" % name)
    else:
        FAIL += 1
        print("  FAIL - %s" % name, file=sys.stderr)
        if detail:
            print("         " + str(detail).replace("\n", "\n         "),
                  file=sys.stderr)


DOC_TEXT = ""
if os.path.exists(DOC):
    with open(DOC, encoding="utf-8") as fh:
        DOC_TEXT = fh.read()
LOW = DOC_TEXT.lower()


# ------------------------------------------------------- 1. packaging / frontmatter
print("== packaging ==")
check("the command file exists at commands/reflect-regroup.md", bool(DOC_TEXT), DOC)
check("it opens with YAML frontmatter", DOC_TEXT.startswith("---\n"),
      DOC_TEXT[:40])
_fm = DOC_TEXT.split("---\n", 2)
check("the frontmatter closes", len(_fm) >= 3, "unterminated frontmatter")
check("the frontmatter carries a description (the convention reflect-setup.md follows)",
      len(_fm) >= 3 and re.search(r"^description:\s*\S", _fm[1], re.M) is not None,
      _fm[1] if len(_fm) >= 3 else "")
check("the body is not empty after the frontmatter",
      len(_fm) >= 3 and len(_fm[2].strip()) > 200)

# The packaging check the marketplace actually performs: the manifest parses, and
# the reflect entry's `source` resolves to the directory this command lives in.
_market_ok = False
try:
    with open(MARKET, encoding="utf-8") as fh:
        _plugins = json.load(fh)["plugins"]
    _src = [p["source"] for p in _plugins if p["name"] == "reflect"][0]
    _root = os.path.normpath(os.path.join(os.path.dirname(os.path.dirname(MARKET)),
                                          _src))
    _market_ok = os.path.isfile(os.path.join(_root, "commands", "reflect-regroup.md"))
except Exception as exc:                                  # pragma: no cover
    _market_ok = False
    print("         marketplace read failed: %r" % (exc,), file=sys.stderr)
check("the marketplace manifest parses and its reflect source ships this command",
      _market_ok, MARKET)


# ---------------------------------------------------- 2. the properties, in prose
print()
print("== the properties that define the command ==")
check("it says it takes NO argument",
      "no argument" in LOW or "no topic" in LOW, DOC_TEXT[:600])
_first_step = DOC_TEXT.split("## 1.", 1)[-1].split("## 2.", 1)[0].lower()
check("step 1 is to STOP", "## 1. stop" in LOW, "no `## 1. Stop` heading")
check("step 1 says to abandon the in-flight action, not finish it",
      "abandon" in _first_step and "do not finish" in _first_step, _first_step[:300])
check("it states the scope split from /memories",
      "/memories" in DOC_TEXT, "no reference to /memories")
check("it disclaims being a fix for application failure (Open Question 1, decided)",
      "never looked" in LOW and "out of scope" in LOW, DOC_TEXT[:1500])
check("it tells the agent to read bodies, not titles",
      "not the titles" in LOW or "not titles" in LOW, "")
check("it tells the agent to record `applied` only for memories that changed course",
      "applied" in DOC_TEXT and "merely read" in LOW, "")


# ------------------------------------------------- 3. extract the doc's invocation
print()
print("== the documented invocation ==")
_blocks = re.findall(r"```(?:bash|sh)?\n(.*?)```", DOC_TEXT, re.S)
_recall_blocks = [b for b in _blocks if "reflect_cli.py" in b and "recall" in b]
check("exactly ONE fenced block documents the recall invocation",
      len(_recall_blocks) == 1, "found %d" % len(_recall_blocks))
INVOCATION = _recall_blocks[0].strip() if len(_recall_blocks) == 1 else ""
check("the documented invocation asks for deliberate mode",
      "--deliberate" in INVOCATION, INVOCATION)
check("the documented invocation carries no --store (a real agent must hit the real store)",
      "--store" not in INVOCATION, INVOCATION)

# The drift this plugin actually shipped once: a flag documented for months that
# the CLI never took. A bad flag does NOT necessarily fail at runtime — the arg
# parser treats an unknown `--flag`'s value as a positional, so `--topic Q` still
# searches for Q by accident. So check the flags against the CLI's own help.
_help = subprocess.run([sys.executable, CLI, "--help"], capture_output=True,
                       text=True)
_help_text = _help.stdout + _help.stderr
_doc_flags = sorted(set(re.findall(r"(?<![\w-])--[a-z][a-z0-9-]*", INVOCATION)))
_unknown = [f for f in _doc_flags if f not in _help_text]
check("every flag in the documented invocation is one the CLI documents",
      bool(_doc_flags) and not _unknown,
      "flags=%s unknown=%s" % (_doc_flags, _unknown))


# ------------------------------------------------------------------ 4. fixtures
ROOT = tempfile.mkdtemp(prefix="regroup-cmd-test-")
STORE = os.path.join(ROOT, "store")
FLAGS = os.path.join(ROOT, "flags")
NEUTRAL = os.path.join(ROOT, "neutral")          # a cwd that is not a git repo
for d in (STORE, FLAGS, NEUTRAL):
    os.makedirs(d, exist_ok=True)


def write(relpath, text):
    path = os.path.join(STORE, relpath)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


# BM25's idf is a property of the corpus: a two-document store makes every term
# look rare and every score meaningless. The filler gives the scored fixtures a
# corpus to stand out from.
for i in range(30):
    write("filler_%02d.md" % i,
          "---\nname: filler_%02d\n---\nRoutine note %02d about ordinary daily "
          "repository work, builds, notes and chores.\n" % (i, i))

# A Case-2-shaped memory: this is what a derived situation should reach.
write("reference_e2e_flake_triage.md", """---
name: reference_e2e_flake_triage
description: Deciding whether a red E2E shard blocks a merge — flake vs regression.
---
REGROUPBODYTOKEN. A DIFFERENT e2e test failing on each re-run is environment
flake; the SAME e2e test failing every re-run is a regression. Re-run the shard
twice before calling a failing e2e shard someone else's problem.
""")

# Gate fixtures: two near-identical bodies, so the DEFAULT separation gate rejects
# the pair and only a relaxed gate returns them. Junk by construction — the point
# is the gate, not the content.
write("gate_alpha.md", "---\nname: gate_alpha\n---\n"
      + "zorkmid quibble frobnitz " * 6 + "\n")
write("gate_beta.md", "---\nname: gate_beta\n---\n"
      + "zorkmid quibble frobnitz " * 5 + "\n")

SITUATION_Q = "is this failing e2e shard a flake or a regression"
FLAT_Q = "zorkmid quibble frobnitz"

#: The harness exports SEEDED_RECALL_* and the live settings pin
#: SEEDED_RECALL_TIMEOUT=0.05 — inheriting either makes this test fail for a
#: reason that looks like a bug in the code under test. The environment is
#: constructed, never inherited.
_STRIP_PREFIXES = ("SEEDED_RECALL_", "MEMORY_TRIGGER_", "MEMORY_LOCAL_", "MEMORY_ACT_")
_STRIP_NAMES = ("REFLECT_MEMORY_DIR", "MEMORY_DIR", "CLAUDE_SESSION_ID")


def env_for(situation, plugin_root=REPO, store=STORE):
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(_STRIP_PREFIXES) and k not in _STRIP_NAMES}
    env["PATH"] = "/usr/bin:/bin"                 # no qmd anywhere on it
    env["SEEDED_RECALL_FLAG_DIR"] = FLAGS
    env["SEEDED_RECALL_TIMEOUT"] = "5"
    env["REFLECT_MEMORY_DIR"] = store
    env["CLAUDE_PLUGIN_ROOT"] = plugin_root
    env["SITUATION"] = situation
    return env


def run_documented(situation, plugin_root=REPO, invocation=None, store=STORE):
    """Run the doc's own block, verbatim, through bash."""
    p = subprocess.run(["bash", "-c", invocation or INVOCATION],
                       capture_output=True, text=True,
                       env=env_for(situation, plugin_root, store), cwd=NEUTRAL)
    return p.stdout + p.stderr, p.returncode


def run_plain(query, store=STORE):
    """The same recall WITHOUT the doc's flags — the contrast case."""
    p = subprocess.run([sys.executable, CLI, "recall", "--cwd", NEUTRAL,
                        "--query", query],
                       capture_output=True, text=True,
                       env=env_for(query, store=store), cwd=NEUTRAL)
    return p.stdout + p.stderr, p.returncode


# --------------------------------------- 5. the doc-versus-CLI drift guard
print()
print("== the documented invocation runs and returns bodies ==")
if INVOCATION:
    out, rc = run_documented(SITUATION_Q)
    check("the block from the doc runs as written — exit 0", rc == 0,
          "rc=%d\n%s" % (rc, out))
    check("it returns a BODY, not just a title", "REGROUPBODYTOKEN" in out, out)
    check("it reaches the memory covering the derived situation",
          "reference_e2e_flake_triage" in out, out)
    check("it ends with the status line naming which layer answered",
          "recall:" in out and "local index" in out, out)
    check("no CLI usage/arg error leaked (a documented flag the CLI rejects)",
          "unrecognized" not in out and "usage:" not in out.lower()
          and "needs a query" not in out, out)
else:
    check("the block from the doc runs as written", False, "no invocation extracted")


# ------------------------------- 6. the doc's flags are load-bearing, not decoration
print()
print("== the doc's flags do real work ==")
out_plain, rc_plain = run_plain(FLAT_Q)
check("baseline: the DEFAULT gate rejects this query",
      "no confident match" in out_plain, out_plain)
check("baseline: rejecting is still exit 0 (fail-open)", rc_plain == 0,
      "rc=%d" % rc_plain)

if INVOCATION:
    out_doc, rc_doc = run_documented(FLAT_Q)
    check("the DOCUMENTED invocation returns what the default gate rejected",
          "gate_alpha" in out_doc and "no confident match" not in out_doc, out_doc)
    check("its status line declares the relaxed mode",
          "deliberate mode" in out_doc, out_doc)
    check("exit 0", rc_doc == 0, "rc=%d" % rc_doc)



# ----------------------------------------- 7. the recording snippet is runnable too
# Step 6 is the only other executable thing in the doc, and it is the whole basis
# for measuring whether regroup helped. Same drift guard, same reason.
print()
print("== the documented `applied` recording ==")
_rec = [b for b in _blocks if "append_applied" in b]
check("exactly ONE fenced block documents the `applied` recording", len(_rec) == 1,
      "found %d" % len(_rec))
if len(_rec) == 1:
    env = env_for("unused")
    env["CLAUDE_SESSION_ID"] = "sess-regroup-1"
    p = subprocess.run(["bash", "-c", _rec[0].strip()], capture_output=True,
                       text=True, env=env, cwd=NEUTRAL)
    log = os.path.join(STORE, "MEMORY_USE.log")
    line = ""
    if os.path.exists(log):
        with open(log, encoding="utf-8") as fh:
            lines = fh.read().strip().splitlines()
        line = lines[-1] if lines else ""
    check("the recording block runs as written — exit 0", p.returncode == 0,
          p.stdout + p.stderr)
    check("it wrote an `applied` line", " applied " in line, line)
    check("the line carries the session id (an id-less line cannot be joined)",
          "[session:sess-regroup-1]" in line, line)
    check("the line is annotated `regroup`, so its source is measurable",
          "[regroup]" in line, line)


print()
print("regroup_cmd_test: %d passed, %d failed" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
