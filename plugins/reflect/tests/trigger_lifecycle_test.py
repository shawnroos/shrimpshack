#!/usr/bin/env python3
"""trigger_lifecycle_test.py — the trigger field stays honest (plan U6).

`triggers:` is only worth having if it is maintained: written where use history
earns it, and pruned where it misfires. This file covers the three lifecycle
properties that make that true rather than aspirational:

* the backfill report names exactly the memories with real use history — and
  unions use days per BODY, so two spellings of one memory's name in the use log
  are one memory used twice, not two memories used once;
* a trigger that keeps firing and is never applied is flagged, on a
  **session_id** join and never a date join — session A's nudge must not be
  credited to session B's unrelated application the same day (KTD9b);
* **the writer leaves `st_mtime` alone** (KTD14) while still letting the manifest
  see the edit. Activation reads mtime as "last reinforcement", so a backfill
  that touched ~200 mtimes would spike ~200 activations, reshuffle the index's
  hot/cold cut and lower those memories' recall floors — surfacing them more for
  no reason but the write. That assertion is this file's load-bearing one.

Needs no qmd and no network, and never touches the live store — every fixture is
a tempdir. Run: `python3 tests/trigger_lifecycle_test.py`.
"""
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)                       # plugins/reflect

# The harness EXPORTS `SEEDED_RECALL_*` and may export `MEMORY_DIR`, and both
# leak into every child. `MEMORY_TRIGGER_*` sets this unit's thresholds at import
# time, so an inherited one would silently move the thing under test — a run that
# read `MIN_USE_DAYS=1` from the environment would pass while asserting nothing.
# Cleared BEFORE the import, and before any subprocess inherits this env.
for _leaked in list(os.environ):
    if (_leaked.startswith(("MEMORY_TRIGGER_", "SEEDED_RECALL_"))
            or _leaked == "MEMORY_DIR"):
        os.environ.pop(_leaked, None)

sys.path.insert(0, os.path.join(REPO, "scripts"))
sys.path.insert(0, os.path.join(REPO, "scripts", "scoped-memory"))
import triggers as tg  # noqa: E402

COMPILE = os.path.join(REPO, "scripts", "compile-triggers.py")

#: Fixture bodies are backdated so "mtime unchanged" is a real assertion and not
#: an artifact of everything happening in the same second.
OLD_MTIME = time.time() - 45 * 86400

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


def write(path, text, mtime=OLD_MTIME):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.chmod(path, 0o644)
    os.utime(path, (mtime, mtime))


def memory(name, description="A memory.", triggers_block="", pin=False,
           body="Some body text.\n"):
    return (
        "---\n"
        f"name: {name}\n"
        f"description: {description}\n"
        + ("pin: true\n" if pin else "")
        + "metadata:\n"
        "  type: reference\n"
        + triggers_block
        + "---\n\n"
        + body
    )


def store_with(bodies, use_lines=(), recall_lines=(), index=None):
    """A fixture store. Returns its path; the caller cleans it up."""
    root = tempfile.mkdtemp(prefix="trigger-lifecycle-")
    for relpath, text in bodies.items():
        write(os.path.join(root, relpath), text)
    if use_lines:
        write(os.path.join(root, "MEMORY_USE.log"), "\n".join(use_lines) + "\n")
    if recall_lines:
        write(os.path.join(root, "RECALL.log"), "\n".join(recall_lines) + "\n")
    if index is not None:
        write(os.path.join(root, "MEMORY.md"), index)
    return root


# ------------------------------------------------------- backfill candidates

def test_backfill_candidates():
    print("== backfill candidates (KTD10) ==")
    root = store_with(
        {
            "feedback_alpha.md": memory("alpha"),
            "feedback_beta.md": memory("beta"),
            "feedback_gamma.md": memory("gamma"),
        },
        use_lines=[
            # alpha: two distinct days, spelled three different ways. The live
            # log really carries all three shapes for one body — the filename
            # stem, the same with dashes, and the bare slug with the `feedback_`
            # type prefix dropped (`squash_on_pr_landing` for
            # `feedback_squash_on_pr_landing.md`). Resolve first, union days
            # second: two spellings used one day each are ONE memory used twice.
            "2026-08-01T09:00:00 feedback-alpha applied [session:s1]",
            "2026-08-02T09:00:00 alpha applied [session:s2]",
            "2026-08-02T10:00:00 no_such_memory applied [session:s2]",
            # beta: two distinct days, one spelling.
            "2026-08-01T09:00:00 feedback_beta applied [session:s1]",
            "2026-08-03T09:00:00 feedback_beta applied [session:s3]",
            # gamma: used repeatedly, but all on ONE day.
            "2026-08-01T09:00:00 feedback_gamma applied [session:s1]",
            "2026-08-01T11:00:00 feedback_gamma applied [session:s1]",
            "2026-08-01T12:00:00 feedback_gamma applied [session:s1]",
        ],
    )
    try:
        rows = tg.backfill_candidates(root)
        names = sorted(r["memory"] for r in rows)
        check("exactly the two multi-day memories are candidates",
              names == ["feedback_alpha", "feedback_beta"])
        check("the single-day memory is not a candidate",
              "feedback_gamma" not in names)

        by = {r["memory"]: r for r in rows}
        check("use days union per BODY across name spellings "
              "(`feedback-alpha` and the bare slug `alpha` are one memory)",
              by.get("feedback_alpha", {}).get("use_days") == 2)
        check("candidates carry the `used` reason",
              by.get("feedback_beta", {}).get("reasons") == ["used"])

        # `written` is a machine token: saving a memory must not earn it a
        # backfill any more than it earns it activation (KTD9a).
        write(os.path.join(root, "MEMORY_USE.log"),
              "2026-08-01T09:00:00 feedback_gamma written [session:s1]\n"
              "2026-08-04T09:00:00 feedback_gamma written [session:s4]\n")
        names = sorted(r["memory"] for r in tg.backfill_candidates(root))
        check("`written` lines do not earn a backfill candidacy",
              "feedback_gamma" not in names)
    finally:
        shutil.rmtree(root, ignore_errors=True)


def test_backfill_tiers_and_filtering():
    print("== backfill: pinned / hot tier, declared filtered out ==")
    declared = "triggers:\n  - literal: gh pr view\n"
    root = store_with(
        {
            "feedback_pinned.md": memory("pinned", pin=True),
            "feedback_hot.md": memory("hot"),
            "feedback_declared.md": memory("declared", triggers_block=declared),
            "feedback_cold.md": memory("cold"),
        },
        use_lines=[
            "2026-08-01T09:00:00 feedback_declared applied [session:s1]",
            "2026-08-02T09:00:00 feedback_declared applied [session:s2]",
        ],
        index="# Memory Index\n\n- [Hot](feedback_hot.md) — a hook\n",
    )
    try:
        rows = {r["memory"]: r for r in tg.backfill_candidates(root)}
        check("a pinned memory is a candidate with no use history",
              "pinned" in rows.get("feedback_pinned", {}).get("reasons", []))
        check("a memory in the rendered MEMORY.md hot tier is a candidate",
              "hot" in rows.get("feedback_hot", {}).get("reasons", []))
        check("a memory with neither use history nor tier is not a candidate",
              "feedback_cold" not in rows)
        check("a memory that already declares triggers is filtered out "
              "(the report stays re-runnable after a backfill)",
              "feedback_declared" not in rows)

        all_rows = {r["memory"]: r
                    for r in tg.backfill_candidates(root, include_declared=True)}
        check("--include-declared surfaces it, marked has_triggers",
              all_rows.get("feedback_declared", {}).get("has_triggers") is True)
    finally:
        shutil.rmtree(root, ignore_errors=True)


# ------------------------------------------------------ never-acted-on triggers

def test_misfire_report():
    print("== never-acted-on triggers (KTD9b session join) ==")
    root = store_with(
        {"feedback_noisy.md": memory("noisy"),
         "feedback_useful.md": memory("useful")},
        recall_lines=[
            "2026-08-01T09:0%d:00 sA nudge feedback_noisy trigger" % i
            for i in range(5)
        ] + [
            "2026-08-01T09:00:00 sA nudge feedback_useful trigger",
            "2026-08-01T09:01:00 sA nudge feedback_useful trigger",
            "2026-08-01T09:02:00 sA nudge feedback_useful trigger",
        ],
        use_lines=[
            "2026-08-01T10:00:00 feedback_useful applied [session:sA]",
        ],
    )
    try:
        rows = {r["memory"]: r for r in tg.never_acted_on(root)}
        check("five nudges with no application at all are flagged",
              rows.get("feedback_noisy", {}).get("nudges") == 5)
        check("nudges followed by a SAME-session application are not flagged",
              "feedback_useful" not in rows)
    finally:
        shutil.rmtree(root, ignore_errors=True)


def test_misfire_cross_session_not_credited():
    print("== the join is on session_id, not on date ==")
    root = store_with(
        {"feedback_x.md": memory("x")},
        recall_lines=[
            "2026-08-01T09:0%d:00 sessionA nudge feedback_x trigger" % i
            for i in range(3)
        ],
        use_lines=[
            # Same DAY, different SESSION. A date join would credit session A's
            # nudges to session B's unrelated application and report success
            # while both logs stay perfectly well-formed.
            "2026-08-01T09:30:00 feedback_x applied [session:sessionB]",
        ],
    )
    try:
        rows = {r["memory"]: r for r in tg.never_acted_on(root)}
        check("session B's same-day application does NOT credit session A's "
              "nudge — the trigger is still flagged",
              rows.get("feedback_x", {}).get("nudges") == 3)
    finally:
        shutil.rmtree(root, ignore_errors=True)


def test_misfire_threshold_and_empty():
    print("== misfire report: threshold and empty store ==")
    root = store_with(
        {"feedback_quiet.md": memory("quiet")},
        recall_lines=[
            "2026-08-01T09:00:00 sA nudge feedback_quiet trigger",
            "2026-08-01T09:01:00 sA nudge feedback_quiet trigger",
        ],
    )
    try:
        check("under the nudge threshold, nothing is flagged",
              tg.never_acted_on(root) == [])
        check("a store with no RECALL.log reports nothing, and does not raise",
              tg.never_acted_on(tempfile.mkdtemp(prefix="empty-store-")) == [])
    finally:
        shutil.rmtree(root, ignore_errors=True)


# ------------------------------------------------------------- the writer

def test_writer_preserves_mtime():
    print("== the writer preserves st_mtime (KTD14) ==")
    root = store_with({"feedback_target.md": memory("target")})
    path = os.path.join(root, "feedback_target.md")
    try:
        before = os.stat(path)
        time.sleep(0.02)
        ok, reason = tg.add_triggers(path, [("literal", "gh pr view --json")])
        after = os.stat(path)
        check("the write succeeds", ok and reason is None)
        check("st_mtime is UNCHANGED — a backfill must not read to activation "
              "as reinforcement (KTD14)",
              after.st_mtime == before.st_mtime)
        check("st_mode is unchanged too (mkstemp creates 0600)",
              stat.S_IMODE(after.st_mode) == stat.S_IMODE(before.st_mode))

        text = open(path, encoding="utf-8").read()
        check("the pattern is in the file",
              "- literal: gh pr view --json" in text)
        check("the rest of the frontmatter survives verbatim",
              "name: target" in text and "  type: reference" in text)
        check("the body survives verbatim", "Some body text." in text)
        check("the parser reads back what was written",
              tg.parse_triggers(tg.frontmatter_lines(text))
              == [("literal", "gh pr view --json")])
    finally:
        shutil.rmtree(root, ignore_errors=True)


def test_writer_refuses_bad_input():
    print("== the writer validates before it writes ==")
    root = store_with({
        "feedback_target.md": memory("target"),
        "feedback_declared.md": memory(
            "declared", triggers_block="triggers:\n  - literal: old pattern\n"),
        "feedback_bare.md": "no frontmatter here\n",
    })
    target = os.path.join(root, "feedback_target.md")
    declared = os.path.join(root, "feedback_declared.md")
    try:
        original = open(target, encoding="utf-8").read()
        ok, reason = tg.add_triggers(target, [("regex", "a(")])
        check("an invalid regex is refused", not ok and "invalid regex" in reason)
        check("...and the file is untouched",
              open(target, encoding="utf-8").read() == original)

        ok, reason = tg.add_triggers(target, [("literal", "ok"), ("bare", "x")])
        check("an untyped entry aborts the whole write (half a trigger set is "
              "worse than none)",
              not ok and open(target, encoding="utf-8").read() == original)

        ok, reason = tg.add_triggers(target, [])
        check("no patterns is refused", not ok)

        ok, reason = tg.add_triggers(os.path.join(root, "feedback_bare.md"),
                                     [("literal", "x")])
        check("a body with no frontmatter is refused, not corrupted",
              not ok and "frontmatter" in reason)

        ok, reason = tg.add_triggers(declared, [("literal", "new pattern")])
        check("an existing triggers block is not silently overwritten",
              not ok and "--replace" in reason)

        ok, _ = tg.add_triggers(declared, [("literal", "new pattern")],
                                replace=True)
        text = open(declared, encoding="utf-8").read()
        check("--replace swaps the block and leaves exactly one",
              ok and "new pattern" in text and "old pattern" not in text
              and text.count("triggers:") == 1)
        check("--replace keeps the frontmatter fences intact",
              tg.parse_triggers(tg.frontmatter_lines(text))
              == [("literal", "new pattern")])
    finally:
        shutil.rmtree(root, ignore_errors=True)


def test_write_reaches_the_manifest():
    print("== a preserved mtime still reaches the manifest (freshness) ==")
    root = store_with({"feedback_target.md": memory("target")})
    path = os.path.join(root, "feedback_target.md")
    try:
        first = subprocess.run([sys.executable, COMPILE, root],
                               capture_output=True, text=True)
        check("the first compile succeeds", first.returncode == 0)

        skipped = subprocess.run([sys.executable, COMPILE, root],
                                 capture_output=True, text=True)
        check("an unchanged store skips the recompile (the freshness path this "
              "test has to exercise)", "is current" in skipped.stdout)

        time.sleep(0.02)
        ok, _ = tg.add_triggers(path, [("literal", "mergeable=CONFLICTING")])
        check("triggers written", ok)

        again = subprocess.run([sys.executable, COMPILE, root],
                               capture_output=True, text=True)
        check("the freshness test SEES the write even though the file's mtime "
              "was restored (os.replace bumps the directory)",
              "is current" not in again.stdout)

        manifest = json.load(open(os.path.join(root, tg.MANIFEST_NAME)))
        patterns = [p["re"] for e in manifest["entries"] for p in e["patterns"]]
        check("the new pattern appears in the recompiled manifest",
              any("CONFLICTING" in p for p in patterns))

        hits, _ = tg.match(manifest, "gh pr view 29 shows mergeable=CONFLICTING",
                           cwd=root)
        check("and the compiled pattern actually matches its situation",
              [h["memory"] for h in hits] == ["feedback_target"])
    finally:
        shutil.rmtree(root, ignore_errors=True)


def test_scoped_body_is_writable():
    print("== scoped bodies participate in the lifecycle ==")
    root = store_with(
        {"_scope/-Users-x-projects-y/feedback_scoped.md": memory("scoped")},
        use_lines=[
            "2026-08-01T09:00:00 feedback_scoped applied [session:s1]",
            "2026-08-02T09:00:00 feedback_scoped applied [session:s2]",
        ],
    )
    rel = os.path.join("_scope", "-Users-x-projects-y", "feedback_scoped.md")
    path = os.path.join(root, rel)
    try:
        rows = tg.backfill_candidates(root)
        check("a scoped body can be a backfill candidate (the enumeration is "
              "corpus.iter_bodies, not a flat listdir)",
              [r["path"] for r in rows] == [rel])
        before = os.stat(path).st_mtime
        ok, _ = tg.add_triggers(path, [("literal", "ng lint")])
        check("and the writer reaches it, mtime preserved",
              ok and os.stat(path).st_mtime == before)
    finally:
        shutil.rmtree(root, ignore_errors=True)


# ------------------------------------------------------------------- the CLI

def test_cli():
    print("== the report / add CLI ==")
    root = store_with(
        {"feedback_alpha.md": memory("alpha", description="Alpha hook.")},
        use_lines=[
            "2026-08-01T09:00:00 feedback_alpha applied [session:s1]",
            "2026-08-02T09:00:00 feedback_alpha applied [session:s2]",
        ],
        recall_lines=[
            "2026-08-01T09:0%d:00 sA nudge feedback_alpha trigger" % i
            for i in range(4)
        ],
    )
    try:
        run = subprocess.run(
            [sys.executable, tg.__file__, "report", "--store", root, "--json"],
            capture_output=True, text=True)
        check("report --json exits 0", run.returncode == 0)
        payload = json.loads(run.stdout)
        check("report --json carries both sections",
              set(payload) == {"backfill", "misfire"})
        check("the candidate is reported",
              [r["memory"] for r in payload["backfill"]] == ["feedback_alpha"])
        check("the misfiring trigger is reported",
              [r["memory"] for r in payload["misfire"]] == ["feedback_alpha"])

        plain = subprocess.run(
            [sys.executable, tg.__file__, "report", "--store", root,
             "--backfill"], capture_output=True, text=True)
        check("report --backfill prints only the backfill section",
              "backfill candidates: 1" in plain.stdout
              and "never-acted-on" not in plain.stdout)

        add = subprocess.run(
            [sys.executable, tg.__file__, "add", "--store", root,
             "--memory", "feedback_alpha.md", "--literal", "gh pr view",
             "--regex", r"mergeable\s*=\s*CONFLICTING"],
            capture_output=True, text=True)
        check("add exits 0 and reports the preserved mtime",
              add.returncode == 0 and "mtime preserved" in add.stdout)
        check("add compiles the manifest by default",
              os.path.exists(os.path.join(root, tg.MANIFEST_NAME)))

        bad = subprocess.run(
            [sys.executable, tg.__file__, "add", "--store", root,
             "--memory", "feedback_alpha.md", "--literal", "x"],
            capture_output=True, text=True)
        check("add refuses to clobber an existing block, and says why",
              bad.returncode == 1 and "--replace" in bad.stderr)

        after = subprocess.run(
            [sys.executable, tg.__file__, "report", "--store", root, "--json"],
            capture_output=True, text=True)
        check("the now-declared memory drops off the backfill list",
              json.loads(after.stdout)["backfill"] == [])
    finally:
        shutil.rmtree(root, ignore_errors=True)


def test_skill_doc_parity():
    print("== SKILL.md teaches commands that exist and patterns that fire ==")
    doc = open(os.path.join(REPO, "skills", "reflect", "SKILL.md"),
               encoding="utf-8").read()
    source = open(tg.__file__, encoding="utf-8").read()
    flags = [f for f in ("report", "add", "--memory", "--literal", "--regex",
                         "--replace") if '"%s"' % f not in source]
    check("every CLI token SKILL.md documents exists in triggers.py", not flags)
    check("SKILL.md documents the lifecycle report", "triggers.py report" in doc)
    check("SKILL.md documents the mtime-preserving writer",
          "triggers.py add" in doc and "preserves the file's mtime" in doc)

    # The example the doc teaches must fire on the motivating Case 1 command.
    # An earlier draft taught `literal: gh pr view --json`, which does NOT match
    # `gh pr view 29 --json` — the PR number sits between the words.
    root = store_with({"feedback_case1.md": memory("case1")})
    try:
        ok, _ = tg.add_triggers(os.path.join(root, "feedback_case1.md"),
                                [("regex", r"gh\s+pr\s+view\b"),
                                 ("regex", r"mergeable\s*=\s*CONFLICTING")])
        manifest, _ = tg.compile_manifest(root)
        hits, _ = tg.match(manifest, "gh pr view 29 --json statusCheckRollup",
                           cwd=root)
        check("the doc's example trigger fires on the Case 1 command",
              ok and [h["memory"] for h in hits] == ["feedback_case1"])
        check("...and the contiguity gotcha it warns about is real",
              tg.add_triggers(os.path.join(root, "feedback_case1.md"),
                              [("literal", "gh pr view --json")],
                              replace=True)[0]
              and not tg.match(tg.compile_manifest(root)[0],
                               "gh pr view 29 --json", cwd=root)[0])
    finally:
        shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    test_backfill_candidates()
    test_backfill_tiers_and_filtering()
    test_misfire_report()
    test_misfire_cross_session_not_credited()
    test_misfire_threshold_and_empty()
    test_writer_preserves_mtime()
    test_writer_refuses_bad_input()
    test_write_reaches_the_manifest()
    test_scoped_body_is_writable()
    test_cli()
    test_skill_doc_parity()
    print(f"trigger_lifecycle_test: {PASS} passed, {FAIL} failed")
    sys.exit(1 if FAIL else 0)
