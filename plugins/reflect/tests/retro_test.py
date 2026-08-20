#!/usr/bin/env python3
"""retro_test.py — retro item format, the single writer, and the list entry point (U1).

Covers the properties that make the backlog trustworthy: an item is invisible to
every existing consumer of the store, a probe round-trips byte-identically, the
four dispositions are a closed set, and no item leaves `open` without a recorded
proof.

Needs no qmd and no network, and never touches the live store — every fixture is
a tempdir. Run: `python3 tests/retro_test.py`.
"""
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)                       # plugins/reflect
sys.path.insert(0, os.path.join(REPO, "scripts"))
sys.path.insert(0, os.path.join(REPO, "scripts", "scoped-memory"))
import corpus  # noqa: E402
import retro  # noqa: E402

FIXTURES = os.path.join(HERE, "fixtures", "retro")
RENDER = os.path.join(REPO, "scripts", "memory-index-render.py")

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


def fixture(name):
    with open(os.path.join(FIXTURES, name), encoding="utf-8") as fh:
        return fh.read()


def plant(store, name, text):
    """Drop a raw item file into `<store>/.retro/`, bypassing the writer."""
    d = retro.retro_dir(store)
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, name + ".md")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    return path


def visible_body(store, name="reference_visible.md"):
    with open(os.path.join(store, name), "w", encoding="utf-8") as fh:
        fh.write("---\nname: reference_visible\ndescription: A normal memory.\n"
                 "metadata:\n  type: reference\n---\n\nBody.\n")


PROBE_TEXT = (
    'last_used: 2020-01-01\n'
    'pin: true\n'
    'python3 -c \'print("RETRO-FIXED " + __import__("os").environ["RETRO_NONCE"])\''
)


# ------------------------------------------------- format: parse + round-trip
print("== retro item format ==")

with tempfile.TemporaryDirectory() as store:
    plant(store, "retro_probe_item", fixture("retro_probe_item.md"))
    item = retro.read_item(store, "retro_probe_item")
    check("a fixture item reads back its frontmatter",
          item["frontmatter"].get("disposition") == "open"
          and item["frontmatter"].get("surface") == "plugin")
    check("the probe text round-trips byte-identically",
          item["probe"] == PROBE_TEXT)
    check("a `last_used:` line inside the probe fence is not the item's last_used",
          "last_used" not in item["frontmatter"])
    check("...and a `pin: true` line inside the fence is not the item's pin",
          "pin" not in item["frontmatter"])

with tempfile.TemporaryDirectory() as store:
    retro.write_item(store, name="retro_no_probe", description="No probe here.",
                     surface="harness", thing="tests/harness.sh",
                     symptom="The tally line never printed.")
    item = retro.read_item(store, "retro_no_probe")
    check("an item with no `## Probe` block reads back probe absent, not empty",
          item["probe"] is None)

with tempfile.TemporaryDirectory() as store:
    retro.write_item(store, name="retro_written", description="Written by the writer.",
                     surface="plugin", thing="plugins/reflect/scripts/retro.py",
                     symptom="It did not exist.", probe=PROBE_TEXT)
    item = retro.read_item(store, "retro_written")
    check("a written item round-trips its probe byte-identically",
          item["probe"] == PROBE_TEXT)
    check("...and carries metadata.type: retro",
          item["frontmatter"].get("metadata.type") == "retro")

with tempfile.TemporaryDirectory() as store:
    plant(store, "retro_torn", "---\nname: retro_torn\ndisposition: open\n\nBody.\n")
    item = retro.read_item(store, "retro_torn")
    check("an unterminated `---` fence reads as absent frontmatter, not an error",
          item["frontmatter"] == {})

with tempfile.TemporaryDirectory() as store:
    d = retro.retro_dir(store)
    retro.write_item(store, name="retro_mode", description="Mode check.",
                     surface="codebase", thing="x", symptom="y")
    check(".retro/ is created mode 0700",
          (os.stat(d).st_mode & 0o777) == 0o700)


# ------------------------------------------------------------ writer invariants
print("== the single writer ==")

with tempfile.TemporaryDirectory() as store:
    err = None
    try:
        retro.write_item(store, name="retro_bad", description="Fifth value.",
                         surface="plugin", thing="x", symptom="y",
                         disposition="deferred")
    except retro.RetroError as exc:
        err = str(exc)
    check("a fifth disposition value is rejected at write time",
          err is not None and "deferred" in err)
    check("...and the rejected item was never written",
          not os.path.exists(os.path.join(retro.retro_dir(store), "retro_bad.md")))

with tempfile.TemporaryDirectory() as store:
    retro.write_item(store, name="retro_move", description="Move me.",
                     surface="plugin", thing="x", symptom="y", probe=PROBE_TEXT)
    path = os.path.join(retro.retro_dir(store), "retro_move.md")
    before = open(path, encoding="utf-8").read()

    def move_refused(proof):
        try:
            retro.set_disposition(store, "retro_move", "fixed", proof=proof)
        except retro.RetroError:
            return True
        except Exception:
            return False
        return False

    check("a disposition move with proof=None raises at the writer",
          move_refused(None))
    check("a disposition move with a blank proof raises at the writer",
          move_refused("   "))
    check("...and leaves the file byte-identical",
          open(path, encoding="utf-8").read() == before)

    err = None
    try:
        retro.set_disposition(store, "retro_move", "deferred", proof="whatever")
    except retro.RetroError as exc:
        err = str(exc)
    check("a fifth disposition value is rejected on a move too", err is not None)

    retro.set_disposition(store, "retro_move", "fixed",
                          proof="probe printed RETRO-FIXED with the run nonce")
    after = open(path, encoding="utf-8").read()
    item = retro.read_item(store, "retro_move")
    check("a move records the disposition",
          item["frontmatter"]["disposition"] == "fixed")
    check("...and records the proof on the item",
          "RETRO-FIXED" in item["frontmatter"].get("proof", ""))
    # Byte-identity of everything else is what makes a second writer unnecessary:
    # drop the two lines the move owns and the file must be unchanged.
    def strip_owned(text):
        return "\n".join(ln for ln in text.splitlines()
                         if not ln.startswith("disposition:")
                         and not ln.startswith("proof:"))
    check("...and leaves the rest of the file byte-identical",
          strip_owned(after) == strip_owned(before))
    check("...and does not disturb the probe", item["probe"] == PROBE_TEXT)

with tempfile.TemporaryDirectory() as store:
    retro.write_item(store, name="retro_sessions", description="Sessions.",
                     surface="skill", thing="x", symptom="y", sessions=["sessA"])
    retro.set_disposition(store, "retro_sessions", "wontfix", proof="operator: not worth it")
    retro.append_session(store, "retro_sessions", "sessB")
    item = retro.read_item(store, "retro_sessions")
    check("appending a session records it",
          item["frontmatter"]["sessions"] == "sessA, sessB")
    check("...and leaves disposition untouched",
          item["frontmatter"]["disposition"] == "wontfix")
    check("...and leaves the proof untouched",
          item["frontmatter"]["proof"] == "operator: not worth it")
    retro.append_session(store, "retro_sessions", "sessB")
    check("...and appending the same session twice does not duplicate it",
          retro.read_item(store, "retro_sessions")["frontmatter"]["sessions"]
          == "sessA, sessB")

with tempfile.TemporaryDirectory() as store:
    retro.write_item(store, name="retro_appr", description="Approval.",
                     surface="plugin", thing="x", symptom="y", probe=PROBE_TEXT)
    retro.record_probe_approval(store, "retro_appr", retro.probe_hash(PROBE_TEXT))
    item = retro.read_item(store, "retro_appr")
    check("a probe approval records the hash of the probe text",
          item["frontmatter"]["probe_hash"] == retro.probe_hash(PROBE_TEXT))
    check("...and the recorded hash matches the probe still on the item",
          retro.probe_hash(item["probe"]) == item["frontmatter"]["probe_hash"])
    check("...and an edited probe no longer matches the recorded hash",
          retro.probe_hash(PROBE_TEXT + "\necho edited")
          != item["frontmatter"]["probe_hash"])
    check("...and the approval left the disposition open",
          item["frontmatter"]["disposition"] == "open")


# ----------------------------------------------------------- the list entry point
print("== the list entry point ==")

with tempfile.TemporaryDirectory() as store:
    check("an absent .retro/ lists empty rather than raising",
          retro.list_items(store) == [])
    os.makedirs(retro.retro_dir(store), exist_ok=True)
    check("an empty .retro/ lists empty rather than raising",
          retro.list_items(store) == [])

with tempfile.TemporaryDirectory() as store:
    retro.write_item(store, name="retro_a", description="A.", surface="plugin",
                     thing="x", symptom="y")
    retro.write_item(store, name="retro_b", description="B.", surface="skill",
                     thing="x", symptom="y")
    retro.write_item(store, name="retro_c", description="C.", surface="plugin",
                     thing="x", symptom="y")
    retro.set_disposition(store, "retro_c", "culled", proof="operator: skill deleted")
    names = [i["name"] for i in retro.list_items(store)]
    check("the list entry point returns every item unfiltered",
          names == ["retro_a", "retro_b", "retro_c"])
    check("...filtered by disposition it returns only open items",
          [i["name"] for i in retro.list_items(store, disposition="open")]
          == ["retro_a", "retro_b"])
    check("...filtered by surface it returns only matching items",
          [i["name"] for i in retro.list_items(store, surface="plugin")]
          == ["retro_a", "retro_c"])
    check("...both filters compose",
          [i["name"] for i in retro.list_items(store, disposition="open",
                                               surface="plugin")] == ["retro_a"])
    check("a listed item carries its frontmatter",
          retro.list_items(store, surface="skill")[0]["frontmatter"]["description"] == "B.")

with tempfile.TemporaryDirectory() as store:
    plant(store, "retro_torn", "---\nname: retro_torn\n\nBody.\n")
    retro.write_item(store, name="retro_ok", description="OK.", surface="plugin",
                     thing="x", symptom="y")
    check("an item with unreadable frontmatter never filters as open",
          [i["name"] for i in retro.list_items(store, disposition="open")] == ["retro_ok"])


# --------------------------------------------------- invisibility to the store
print("== invisible to every existing consumer ==")

with tempfile.TemporaryDirectory() as store:
    visible_body(store)
    plant(store, "retro_probe_item", fixture("retro_probe_item.md"))
    rels = [rel for rel, _slug in corpus.iter_bodies(store)]
    check("a real corpus walk sees the visible body",
          "reference_visible.md" in rels)
    check("...and no path under .retro/ at all",
          not any(".retro" in r for r in rels))

with tempfile.TemporaryDirectory() as store:
    visible_body(store)
    plant(store, "retro_probe_item", fixture("retro_probe_item.md"))
    index = os.path.join(store, "MEMORY.md")
    env = dict(os.environ)
    env["MEMORY_DIR"] = store
    subprocess.run([sys.executable, RENDER, index], env=env,
                   capture_output=True, text=True)
    rendered = open(index, encoding="utf-8").read() if os.path.exists(index) else ""
    check("the renderer wrote an index naming the visible body",
          "reference_visible.md" in rendered)
    check("...and the retro item appears nowhere in it",
          "retro_probe_item" not in rendered and ".retro" not in rendered)


print()
print(f"retro_test: {PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
