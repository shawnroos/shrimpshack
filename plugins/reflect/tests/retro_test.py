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


import calendar  # noqa: E402

# ------------------------------------------------------------------ the drain
print("== the queue record ==")

DRAINED = os.path.join(FIXTURES, "transcript_drained.jsonl")
QUIET = os.path.join(FIXTURES, "transcript_quiet.jsonl")
DRAINED_SESSION = "sess-drained-0001"
TOKEN = "ghp_ZZZZfakefakefakefakefakefake0123456"
NOW = calendar.timegm((2026, 8, 20, 12, 0, 0, 0, 0, 0))  # two days after the fixture.


def qline(session, path, cursor="", event="PreCompact:auto", ts="2026-08-18T09:30:00Z"):
    return "\t".join([session, path, cursor, event, ts])


def write_queue(d, *lines):
    path = os.path.join(d, ".retro-queue")
    with open(path, "w", encoding="utf-8") as fh:
        for ln in lines:
            fh.write(ln + "\n")
    return path


def queue_lines(path):
    return [ln for ln in open(path, encoding="utf-8").read().splitlines() if ln.strip()]


check("a five-field queue line parses into the five named fields",
      retro.parse_queue_line(qline("s1", "/t.jsonl")) ==
      {"session_id": "s1", "transcript_path": "/t.jsonl", "cursor_uuid": "",
       "event": "PreCompact:auto", "ts": "2026-08-18T09:30:00Z"})
check("a four-field line is not a record",
      retro.parse_queue_line("s1\t/t.jsonl\t\tPreCompact") is None)
check("a line with an empty transcript path is not a record",
      retro.parse_queue_line("s1\t\t\tPreCompact\t2026-08-18T09:30:00Z") is None)
check("a record round-trips through format and parse",
      retro.parse_queue_line(retro.format_queue_line(
          retro.parse_queue_line(qline("s1", "/t.jsonl", cursor="u9"))))["cursor_uuid"]
      == "u9")

check("the queue rewrite keeps a line appended after the first read",
      retro.merge_queue_lines(["a", "b"], ["b"], ["a", "b", "c"]) == ["b", "c"])
check("...and keeps it even when the file was rewritten under us",
      retro.merge_queue_lines(["a", "b"], ["b"], ["b", "c"]) == ["b", "c"])
check("...and never duplicates a survivor that is also in the tail",
      retro.merge_queue_lines(["a"], ["a"], ["a", "a"]) == ["a"])


print("== the drain ==")

with tempfile.TemporaryDirectory() as d:
    q = write_queue(d, qline(DRAINED_SESSION, DRAINED), qline("other", QUIET))
    out = retro.drain(queue=q, live_session_id="live-session", now=NOW)
    by_session = {r["session_id"]: r for r in out["drained"]}
    check("a record pointing at a transcript yields candidate material",
          by_session[DRAINED_SESSION]["candidates_returned"] >= 3)
    check("...every candidate is failure-shaped, never an ordinary turn",
          all(c["kind"] in ("tool_error", "hook_error", "system_error")
              for c in by_session[DRAINED_SESSION]["candidates"]))
    check("...and names the tool that failed",
          any(c["tool"] == "Bash" for c in by_session[DRAINED_SESSION]["candidates"]))
    check("...and carries the session's cwd and branch instead of its prompts",
          by_session[DRAINED_SESSION]["cwd"] == "/Users/example/projects/demo"
          and by_session[DRAINED_SESSION]["git_branch"] == "feature/demo")
    check("...and marks the material as drained provenance",
          by_session[DRAINED_SESSION]["capture"] == "drained")
    check("a transcript with no failures returns zero candidates",
          by_session["other"]["candidates_returned"] == 0)
    check("...and is drained and dropped all the same",
          "other" in by_session)
    check("after a drain the queue file is empty", queue_lines(q) == [])

with tempfile.TemporaryDirectory() as d:
    q = write_queue(d, qline(DRAINED_SESSION, DRAINED))
    out = retro.drain(queue=q, live_session_id="live-session", now=NOW)
    material = repr(out)
    check("a token-shaped string in the transcript never reaches the material",
          TOKEN not in material and "ghp_" not in material)
    check("...and the surrounding failure is still reported",
          any("auth rejected" in c["excerpt"] for c in out["drained"][0]["candidates"]))
    item = retro.write_item(
        d, name="retro_from_drain", description="deploy.sh auth step.",
        surface="harness", thing="deploy.sh",
        symptom=out["drained"][0]["candidates"][1]["excerpt"], capture="drained")
    check("...so an item written from that candidate does not contain it",
          TOKEN not in open(item, encoding="utf-8").read())
    check("...and the item records drained provenance",
          retro.read_item(d, "retro_from_drain")["frontmatter"]["capture"] == "drained")

with tempfile.TemporaryDirectory() as d:
    q = write_queue(d, qline(DRAINED_SESSION, DRAINED))
    out = retro.drain(queue=q, live_session_id="live-session", now=NOW,
                      max_candidates=2)
    r = out["drained"][0]
    check("a drain over the cap reports how many candidates it dropped",
          r["candidates_returned"] == 2 and r["candidates_found"] == 3
          and r["candidates_dropped"] == 1)
    check("...so a truncated drain is distinguishable from a quiet session",
          r["candidates_dropped"] > 0)

with tempfile.TemporaryDirectory() as d:
    q = write_queue(d, qline(DRAINED_SESSION, DRAINED))
    out = retro.drain(queue=q, live_session_id="live-session", now=NOW,
                      max_excerpt_chars=40)
    r = out["drained"][0]
    check("an over-long excerpt is truncated to the ceiling",
          all(len(c["excerpt"]) <= 40 + len("[redacted]") for c in r["candidates"]))
    check("...and the truncation is reported, not silent",
          r["excerpts_truncated"] >= 1)


print("== queue hygiene ==")

with tempfile.TemporaryDirectory() as d:
    survivor = qline("keep-me", os.path.join(d, "still-here.jsonl"),
                     ts="2026-08-19T09:00:00Z")
    open(os.path.join(d, "still-here.jsonl"), "w").write("")
    q = write_queue(d, qline("gone", os.path.join(d, "no-such.jsonl")), survivor)
    out = retro.drain(queue=q, live_session_id="live-session", now=NOW)
    check("a record pointing at a missing transcript is dropped, not raised",
          [x["session_id"] for x in out["dropped_missing"]] == ["gone"])
    check("...and yields no candidate material to write an item from",
          "gone" not in [r["session_id"] for r in out["drained"]])
    check("...and the other record was drained, not left behind",
          queue_lines(q) == [])

with tempfile.TemporaryDirectory() as d:
    q = write_queue(d, qline(DRAINED_SESSION, DRAINED, event="PreCompact:auto",
                             ts="2026-08-18T09:30:00Z"),
                    qline(DRAINED_SESSION, DRAINED, event="PreCompact:manual",
                          ts="2026-08-18T11:00:00Z"))
    out = retro.drain(queue=q, live_session_id="live-session", now=NOW)
    check("two records for one session collapse to one drain, not two",
          len(out["drained"]) == 1 and out["collapsed"] == 1)
    check("...and the one drain names both events it collapsed",
          out["drained"][0]["records_collapsed"] == 2)

with tempfile.TemporaryDirectory() as d:
    q = write_queue(d,
                    qline("old", DRAINED, ts="2026-07-01T09:00:00Z"),
                    qline(DRAINED_SESSION, DRAINED, ts="2026-08-18T09:30:00Z"))
    out = retro.drain(queue=q, live_session_id="live-session", now=NOW,
                      expiry_days=14)
    check("a record past the expiry bound is dropped",
          [x["session_id"] for x in out["dropped_expired"]] == ["old"])
    check("...without reading its transcript for material",
          [r["session_id"] for r in out["drained"]] == [DRAINED_SESSION])

with tempfile.TemporaryDirectory() as d:
    q = write_queue(d, qline(DRAINED_SESSION, DRAINED))
    first = retro.drain(queue=q, live_session_id="live-session", now=NOW)
    second = retro.drain(queue=q, live_session_id="live-session", now=NOW)
    check("draining twice is idempotent — the second run finds nothing",
          first["drained"] and second["drained"] == []
          and second["records_seen"] == 0)

with tempfile.TemporaryDirectory() as d:
    q = write_queue(d, qline(DRAINED_SESSION, DRAINED))
    late = qline("appended-mid-drain", QUIET, ts="2026-08-19T09:00:00Z")
    real_scan = retro.scan_transcript

    def scan_then_append(*a, **kw):
        with open(q, "a", encoding="utf-8") as fh:
            fh.write(late + "\n")
        retro.scan_transcript = real_scan
        return real_scan(*a, **kw)

    retro.scan_transcript = scan_then_append
    try:
        retro.drain(queue=q, live_session_id="live-session", now=NOW)
    finally:
        retro.scan_transcript = real_scan
    check("a record appended while the drain was reading survives the rewrite",
          queue_lines(q) == [late])

with tempfile.TemporaryDirectory() as d:
    q = write_queue(d, "not\ta\tqueue\tline", qline(DRAINED_SESSION, DRAINED))
    out = retro.drain(queue=q, live_session_id="live-session", now=NOW)
    check("an unparseable line is counted and dropped, never drained",
          out["dropped_malformed"] == 1 and len(out["drained"]) == 1)


print("== the live session's record ==")

with tempfile.TemporaryDirectory() as d:
    q = write_queue(d, qline(DRAINED_SESSION, DRAINED))
    out = retro.drain(queue=q, live_session_id=DRAINED_SESSION, now=NOW)
    check("the live session is never drained — the live vent pass owns it",
          out["drained"] == [] and out["stamped"] == 1)
    kept = retro.parse_queue_line(queue_lines(q)[0])
    check("...its record survives with the cursor stamped to the transcript tail",
          kept["cursor_uuid"] == "u7")
    again = retro.drain(queue=q, live_session_id=DRAINED_SESSION, now=NOW)
    check("...and a second drain in the same session changes nothing",
          again["stamped"] == 1 and again["drained"] == []
          and retro.parse_queue_line(queue_lines(q)[0])["cursor_uuid"] == "u7")

with tempfile.TemporaryDirectory() as d:
    q = write_queue(d,
                    qline(DRAINED_SESSION, DRAINED, ts="2026-08-18T09:30:00Z"),
                    qline(DRAINED_SESSION, DRAINED, ts="2026-08-18T11:00:00Z"))
    out = retro.drain(queue=q, live_session_id=DRAINED_SESSION, now=NOW)
    check("a session that compacts twice collapses to one stamped record",
          len(queue_lines(q)) == 1 and out["collapsed"] == 1)

with tempfile.TemporaryDirectory() as d:
    q = write_queue(d, qline("old-live", DRAINED, ts="2026-07-01T09:00:00Z"))
    out = retro.drain(queue=q, live_session_id="old-live", now=NOW, expiry_days=14)
    check("the live session's record is never expired out from under it",
          out["stamped"] == 1 and out["dropped_expired"] == [])

with tempfile.TemporaryDirectory() as d:
    q = write_queue(d, qline(DRAINED_SESSION, DRAINED))
    out = retro.drain(queue=q, live_session_id=None, now=NOW)
    check("an unknown live session drains everything and says so",
          out["live_session_known"] is False and len(out["drained"]) == 1)


print("== the cursor ==")

with tempfile.TemporaryDirectory() as d:
    q = write_queue(d, qline(DRAINED_SESSION, DRAINED, cursor="u3"))
    out = retro.drain(queue=q, live_session_id="live", now=NOW)
    r = out["drained"][0]
    check("a cursor resumes after the record it names",
          r["cursor_found"] is True
          and [c["uuid"] for c in r["candidates"]] == ["u5", "u7"])

with tempfile.TemporaryDirectory() as d:
    q = write_queue(d, qline(DRAINED_SESSION, DRAINED, cursor="not-in-this-file"))
    out = retro.drain(queue=q, live_session_id="live", now=NOW)
    r = out["drained"][0]
    check("a cursor that is not in the transcript falls back to the whole file",
          r["candidates_returned"] == 3)
    check("...and flags the fallback rather than reading as a quiet session",
          r["cursor_found"] is False)

with tempfile.TemporaryDirectory() as d:
    q = write_queue(d, qline(DRAINED_SESSION, DRAINED, cursor="u7"))
    out = retro.drain(queue=q, live_session_id="live", now=NOW)
    check("a cursor at the tail returns nothing and reports nothing dropped",
          out["drained"][0]["candidates_returned"] == 0
          and out["drained"][0]["candidates_dropped"] == 0
          and out["drained"][0]["cursor_found"] is True)

print()
print(f"retro_test: {PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
