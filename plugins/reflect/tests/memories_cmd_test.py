#!/usr/bin/env python3
"""memories_cmd_test.py — the `/memories <topic>` command file (plan U5).

This plan exists because a documented CLI call was never a real CLI call:
`recall --here` was written up in SKILL.md and had no branch in the CLI. So the
assertion that matters here is not "the doc says something reasonable" — it is
**the invocation printed in `commands/memories.md` is EXTRACTED FROM THE DOC and
executed**. Nothing in this file retypes the command; if the doc drifts from the
CLI, these tests go red on the doc, which is the only place drift can start.

Four claims, each with the mutation that must turn it red:

  1. THE COMMAND FILE FOLLOWS THE PLUGIN'S COMMAND CONVENTIONS — frontmatter that
     parses, a `description:`, an `argument-hint:`, and `$ARGUMENTS` in the body so
     the topic actually reaches the agent. Mutation: delete `argument-hint:` from
     `commands/memories.md`.
  2. IT NAMES ITS COUNTERPART. `/memories` and `/reflect-regroup` are a scope split
     (topic vs no-topic; stops nothing vs stops first), and a command file that
     doesn't say so leaves the agent to guess. Mutation: drop the `reflect-regroup`
     mention.
  3. THE DOCUMENTED INVOCATION RETURNS BODIES AND A STATUS LINE, exit 0, with no qmd
     anywhere on PATH. Mutation: in `reflect_cli.py`, make `add()` store `""` for the
     body (the pre-U2 titles-only behavior this plan removed).
  4. THE FLAGS THE DOC PROMISES ARE REAL — `--deliberate` is in the documented call
     and reports itself; `--here`, which the doc tells the agent to add, scopes the
     result to the current repo and says so. Mutations: drop the deliberate note;
     `here = False` in `cmd_recall`.

No test here needs qmd: PATH is constructed without it, so layer 2 is a clean miss
and the local BM25 index answers. No test here reads the live store — every run is
pointed at a fixture store via `--store`.

There is deliberately NO assertion on the prose guidance (the "when to recall" cues,
the record-honestly step). It is agent-behavioral: its effect shows up in RECALL.log /
MEMORY_USE.log telemetry over weeks, not in a unit test. A test asserting the words
are present would only prove the words are present.

Run: `python3 tests/memories_cmd_test.py`.
"""
import os
import re
import shlex
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CMD_DOC = os.path.join(REPO, "commands", "memories.md")

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


# --------------------------------------------------------------- the doc itself

DOC = ""
if os.path.exists(CMD_DOC):
    with open(CMD_DOC, encoding="utf-8") as fh:
        DOC = fh.read()


def frontmatter(text):
    """The command file's YAML-ish frontmatter as a flat dict, or None if absent."""
    m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    if not m:
        return None
    out = {}
    for line in m.group(1).splitlines():
        if ":" in line and not line.startswith((" ", "\t", "#")):
            k, v = line.split(":", 1)
            out[k.strip()] = v.strip().strip('"').strip("'")
    return out


def documented_invocation(text, script="reflect_cli.py"):
    """A command AS PRINTED IN THE DOC — the whole point of this file.

    Returns the raw command string from the first fenced block that runs
    `script`. Line continuations are folded so a wrapped command still reads as
    one. Returns None when the doc has no such block at all, which is itself a
    failure the caller reports.
    """
    for block in re.findall(r"```(?:bash|sh)?\n(.*?)```", text, re.S):
        if script in block:
            return re.sub(r"\\\n\s*", " ", block).strip()
    return None


print("== command file conventions ==")
check("commands/memories.md exists", bool(DOC), CMD_DOC)

FM = frontmatter(DOC) if DOC else None
check("frontmatter parses", FM is not None,
      "no leading --- ... --- block")
check("declares a description", bool((FM or {}).get("description")))
check("declares an argument-hint (it takes a topic)",
      bool((FM or {}).get("argument-hint")),
      "keys seen: %s" % sorted((FM or {}).keys()))
check("body substitutes the topic via $ARGUMENTS", "$ARGUMENTS" in DOC)
check("names its counterpart command (the scope split)",
      "reflect-regroup" in DOC or "reflect regroup" in DOC)


# ------------------------------------------------------------------ fixtures

ROOT = tempfile.mkdtemp(prefix="memories-cmd-test-")
STORE = os.path.join(ROOT, "store")
NOQMD = os.path.join(ROOT, "bin-empty")          # an empty dir: qmd is not on PATH
os.makedirs(STORE, exist_ok=True)
os.makedirs(NOQMD, exist_ok=True)

_STRIP_PREFIXES = ("SEEDED_RECALL_", "MEMORY_TRIGGER_", "MEMORY_LOCAL_", "MEMORY_ACT_")
_STRIP_NAMES = ("REFLECT_MEMORY_DIR", "MEMORY_DIR", "CLAUDE_SESSION_ID")
ENV = {k: v for k, v in os.environ.items()
       if not k.startswith(_STRIP_PREFIXES) and k not in _STRIP_NAMES}
ENV["PATH"] = NOQMD + ":/usr/bin:/bin"
ENV["SEEDED_RECALL_FLAG_DIR"] = os.path.join(ROOT, "flags")
ENV["SEEDED_RECALL_TIMEOUT"] = "5"


def write(relpath, text):
    path = os.path.join(STORE, relpath)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


# BM25's idf is a corpus property: a two-file store makes every term look rare and
# every score meaningless. Filler gives the target something to stand out from.
for i in range(30):
    write("filler_%02d.md" % i,
          "---\nname: filler_%02d\n---\nRoutine note %02d about ordinary daily "
          "repository work, builds, notes and chores.\n" % (i, i))

BODY_TOKEN = "MEMORIESCMDBODYTOKEN"
TOPIC = "e2e shard flake or regression triage"
write("reference_e2e_flake_triage.md", """---
name: reference_e2e_flake_triage
description: Deciding whether a red E2E shard blocks a merge — flake vs regression.
---
%s — a DIFFERENT e2e test failing on each re-run is environment flake; the SAME
e2e test failing every re-run is a regression. Re-run the shard twice before
calling a failing e2e shard someone else's problem. E2E flake triage: shard,
re-run, compare failing test names.
""" % BODY_TOKEN)

# A git repo to be "here", with one memory scoped to it, so the --here the doc
# tells the agent to add has a real scope to resolve and report.
HEREREPO = os.path.join(ROOT, "hererepo")
os.makedirs(HEREREPO, exist_ok=True)
subprocess.run(["git", "init", "-q", HEREREPO], capture_output=True)
sys.path.insert(0, os.path.join(REPO, "scripts", "scoped-memory"))
import scope        # noqa: E402
HERE_SLUG = scope.resolve_repo_slug(HEREREPO)
write(os.path.join("_scope", HERE_SLUG, "project_here_e2e.md"),
      "---\nname: project_here_e2e\n---\nHERE_E2E %s e2e shard flake regression "
      "triage notes for this repository.\n" % BODY_TOKEN)


def run_documented(topic, extra=(), cwd=None):
    """Run THE DOC'S command, with only the topic and the store bound.

    `${CLAUDE_PLUGIN_ROOT}` and `$ARGUMENTS` are the two placeholders the harness
    fills at invocation time; `--store` points the run at the fixture. Everything
    else — subcommand, flags, ordering — comes from the doc verbatim.
    """
    raw = documented_invocation(DOC)
    if raw is None:
        return "", 127
    raw = raw.replace("${CLAUDE_PLUGIN_ROOT}", REPO).replace(
        "$CLAUDE_PLUGIN_ROOT", REPO).replace("$ARGUMENTS", topic)
    argv = shlex.split(raw)
    if argv and argv[0] in ("python3", "python"):
        argv[0] = sys.executable
    argv += ["--store", STORE] + list(extra)
    p = subprocess.run(argv, capture_output=True, text=True, env=ENV,
                       cwd=cwd or STORE)
    return p.stdout + p.stderr, p.returncode


print("== the documented invocation is a real invocation ==")
RAW = documented_invocation(DOC) if DOC else None
check("the doc contains a runnable recall invocation", RAW is not None,
      "no fenced block mentioning reflect_cli.py")
check("the documented call is the recall subcommand",
      bool(RAW) and re.search(r"reflect_cli\.py[\"']?\s+recall\b", RAW),
      RAW or "")
check("the documented call uses deliberate mode (a human asked)",
      bool(RAW) and "--deliberate" in RAW, RAW or "")

OUT, RC = run_documented(TOPIC)
check("the documented invocation exits 0 (fail-open)", RC == 0,
      "rc=%s\n%s" % (RC, OUT))
check("no usage/unknown-flag error — every documented flag is real",
      "usage" not in OUT.lower() and "unrecognized" not in OUT.lower()
      and "unknown" not in OUT.lower(), OUT)
check("it returns BODIES, not just titles", BODY_TOKEN in OUT, OUT)
check("it surfaced the topic's memory", "reference_e2e_flake_triage" in OUT, OUT)
check("it always ends with a status line naming the answering layer",
      bool(re.search(r"^recall: .*(surfaced|no confident match)", OUT, re.M)), OUT)
check("deliberate mode reports itself in the status line",
      "deliberate mode" in OUT, OUT)

print("== the flags the doc tells the agent to add ==")
HOUT, HRC = run_documented(TOPIC, extra=["--here"], cwd=HEREREPO)
check("--here exits 0", HRC == 0, "rc=%s\n%s" % (HRC, HOUT))
check("--here scopes to the resolved repo and says so",
      ("repo-scoped to %s" % HERE_SLUG) in HOUT, HOUT)
check("--here still returns bodies", BODY_TOKEN in HOUT, HOUT)

print("== the trigger-proposing step's command is real too ==")
# The doc's step 5 is a second invocation, of a second script — it can drift on its
# own, so it gets its own parity run rather than a reader's trust.
TRAW = documented_invocation(DOC, script="triggers.py") if DOC else None
check("the doc contains a runnable triggers invocation", TRAW is not None,
      "no fenced block mentioning triggers.py")
TOUT, TRC = "", 127
if TRAW:
    traw = TRAW.replace("${CLAUDE_PLUGIN_ROOT}", REPO).replace(
        "$CLAUDE_PLUGIN_ROOT", REPO).replace(
        "<file.md>", "reference_e2e_flake_triage.md")
    targv = shlex.split(traw)
    if targv and targv[0] in ("python3", "python"):
        targv[0] = sys.executable
    targv += ["--store", STORE]
    tp = subprocess.run(targv, capture_output=True, text=True, env=ENV, cwd=STORE)
    TOUT, TRC = tp.stdout + tp.stderr, tp.returncode
check("the documented triggers command succeeds", TRC == 0,
      "rc=%s\n%s" % (TRC, TOUT))
check("it actually wrote the triggers block",
      "triggers:" in open(os.path.join(STORE, "reference_e2e_flake_triage.md"),
                          encoding="utf-8").read(), TOUT)

print()
print("memories_cmd_test: %d passed, %d failed" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
