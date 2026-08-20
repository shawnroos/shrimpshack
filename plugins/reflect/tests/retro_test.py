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
import shutil
import json
import subprocess
import sys
import tempfile
import time

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
    # The vent pass composes items from transcripts nobody reviewed, so birth
    # state is an attack surface: an item born `fixed`, or born carrying its own
    # probe approval, would bypass both writer invariants before any reader sees
    # it. Every one of these must be refused AND leave no file behind.
    def birth_refused(**kw):
        try:
            retro.write_item(store, name="retro_bad", description="Birth state.",
                             surface="plugin", thing="x", symptom="y", **kw)
        except retro.RetroError:
            return True
        except Exception:
            return False
        return False

    check("write_item refuses a caller-supplied disposition",
          birth_refused(disposition="fixed"))
    check("...including the one it would have written anyway",
          birth_refused(disposition="open"))
    check("...and a fifth disposition value is refused the same way",
          birth_refused(disposition="deferred"))
    check("...and refuses a caller-supplied probe approval",
          birth_refused(probe_approved="2026-08-20"))
    check("...and a caller-supplied probe hash",
          birth_refused(probe_hash="deadbeef"))
    check("...and none of the refused items was written",
          not os.path.exists(os.path.join(retro.retro_dir(store), "retro_bad.md")))

with tempfile.TemporaryDirectory() as store:
    retro.write_item(store, name="retro_born", description="Born open.",
                     surface="plugin", thing="x", symptom="y", probe=PROBE_TEXT)
    fm = retro.read_item(store, "retro_born")["frontmatter"]
    check("an item is born open", fm.get("disposition") == "open")
    check("...and born with no probe approval on it",
          "probe_approved" not in fm and "probe_hash" not in fm)
    check("...and record_probe_approval is what puts one there",
          retro.record_probe_approval(store, "retro_born",
                                      retro.probe_hash(PROBE_TEXT))
          and retro.read_item(store, "retro_born")["frontmatter"].get("probe_hash")
          == retro.probe_hash(PROBE_TEXT))

with tempfile.TemporaryDirectory() as store:
    def name_refused(name):
        try:
            retro.write_item(store, name=name, description="Escape.",
                             surface="plugin", thing="x", symptom="y")
        except retro.RetroError:
            return True
        except Exception:
            return False
        return False

    check("a name that climbs out of .retro/ is refused", name_refused("../escaped"))
    check("...and wrote nothing into the store proper",
          not os.path.exists(os.path.join(store, "escaped.md")))
    check("...a name with a path separator is refused", name_refused("sub/item"))
    check("...an absolute name is refused", name_refused("/tmp/retro_abs"))
    check("...a dot-leading name is refused", name_refused(".hidden"))
    check("...a bare `..` is refused", name_refused(".."))
    check("...an empty name is refused", name_refused(""))

    def read_refused(name):
        try:
            retro.read_item(store, name)
        except retro.RetroError:
            return True
        except Exception:
            return False
        return False

    plant(store, "retro_present", "---\nname: retro_present\n---\n\nb\n")
    check("...and the same guard covers the reader, which still reads a real item",
          read_refused("../../etc/passwd") and read_refused("sub/item")
          and not read_refused("retro_present"))

with tempfile.TemporaryDirectory() as store:
    # A newline in any single-line field closes the frontmatter block early: the
    # keys below the injected `---` stop parsing, and the item silently drops out
    # of every `disposition="open"` view that is supposed to work it.
    retro.write_item(store, name="retro_flat",
                     description="desc\n---\nx: 1", surface="plugin",
                     thing="thing\nmore", symptom="sym", sessions=["a\nb"],
                     capture="live\nx", cost="2h\n---")
    fm = retro.read_item(store, "retro_flat")["frontmatter"]
    check("a newline in a field cannot truncate the frontmatter block",
          fm.get("disposition") == "open" and fm.get("surface") == "plugin")
    check("...and the item is still visible to the open view",
          [i["name"] for i in retro.list_items(store, disposition="open")]
          == ["retro_flat"])
    check("...and the field itself is collapsed to one line",
          fm.get("description") == "desc --- x: 1")

with tempfile.TemporaryDirectory() as store:
    retro.write_item(store, name="retro_flat_proof", description="Proof.",
                     surface="plugin", thing="x", symptom="y")
    retro.set_disposition(store, "retro_flat_proof", "wontfix",
                          proof="operator: no\n---\ndisposition: fixed")
    fm = retro.read_item(store, "retro_flat_proof")["frontmatter"]
    check("a newline in a proof cannot forge a second disposition line",
          fm.get("disposition") == "wontfix")

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


def drained_uuids(out, session=None):
    """Candidate uuids of the first drained session, or [] when nothing drained.

    A missing drain is the exact failure several of these tests are looking for,
    so it must read as an empty list rather than abort the file and hide every
    assertion after it.
    """
    rows = [r for r in out["drained"]
            if session is None or r["session_id"] == session]
    return [c["uuid"] for c in rows[0]["candidates"]] if rows else []


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
    # Dropping the record here would make the remainder unreachable: nothing
    # else remembers the session, so the capped tail would be lost outright.
    kept = queue_lines(q)
    check("...and the capped record survives with its cursor on the last one seen",
          len(kept) == 1
          and retro.parse_queue_line(kept[0])["cursor_uuid"] == "u5")
    second = retro.drain(queue=q, live_session_id="live-session", now=NOW,
                         max_candidates=2)
    check("...so the next drain returns the remainder rather than losing it",
          drained_uuids(second) == ["u7"]
          and second["drained"][0]["candidates_dropped"] == 0)
    check("...and the queue is empty once the whole transcript is spent",
          queue_lines(q) == [])

with tempfile.TemporaryDirectory() as d:
    q = write_queue(d, qline(DRAINED_SESSION, DRAINED))
    out = retro.drain(queue=q, live_session_id="live-session", now=NOW,
                      max_excerpt_chars=40)
    r = out["drained"][0]
    check("an over-long excerpt is truncated to the ceiling",
          all(len(c["excerpt"]) <= 40 + len("[redacted]") for c in r["candidates"]))
    check("...and the truncation is reported, not silent",
          r["excerpts_truncated"] >= 1)


print("== redaction ==")

FAKE_KEY_BODY = "MIIEowIBAAKCAQEAx" + "Q" * 60
FAKE_KEY = ("-----BEGIN RSA PRIVATE KEY-----\n" + FAKE_KEY_BODY
            + "\n-----END RSA PRIVATE KEY-----")
FAKE_JWT = ("eyJhbGciOiJIUzI1NiJ9." + "A" * 40 + "." + "B" * 43)

check("a private key block is redacted body and all, not just its header line",
      FAKE_KEY_BODY not in retro.redact("before " + FAKE_KEY + " after"))
check("...and an unterminated key block is redacted too, since truncation eats END",
      FAKE_KEY_BODY not in retro.redact(
          "-----BEGIN RSA PRIVATE KEY-----\n" + FAKE_KEY_BODY))
check("...and the surrounding text survives",
      retro.redact("before " + FAKE_KEY + " after").startswith("before ")
      and retro.redact("before " + FAKE_KEY + " after").endswith(" after"))
check("an underscore-form provider key is redacted",
      "sk_live_" not in retro.redact("key sk_live_0123456789abcdefghij"))
check("...and the hyphen form still is",
      "sk-" not in retro.redact("key sk-0123456789abcdefghij"))
check("an aws_secret= assignment is redacted despite the underscore prefix",
      "wJalrXUtnFEMI" not in retro.redact(
          "aws_secret=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"))
check("a Google API key is redacted",
      "AIza" not in retro.redact("AIzaSyA" + "b" * 32))
check("credentials embedded in a URL are redacted",
      "hunter2" not in retro.redact("postgres://admin:hunter2@db.example.com/app"))
check("...and the host is still readable so the failure remains diagnosable",
      "db.example.com" in retro.redact(
          "postgres://admin:hunter2@db.example.com/app"))


print("== redaction reaches the item writers ==")

with tempfile.TemporaryDirectory() as store:
    retro.write_item(store, name="retro_secretish",
                     description="deploy failed with " + FAKE_JWT,
                     surface="harness", thing="deploy.sh token=" + FAKE_JWT,
                     symptom="server said sk_live_0123456789abcdefghij",
                     cost="1h chasing " + FAKE_JWT)
    text = open(os.path.join(retro.retro_dir(store), "retro_secretish.md"),
                encoding="utf-8").read()
    check("a credential in a composed description never lands in the item",
          "eyJhbGciOiJIUzI1NiJ9" not in text)
    check("...nor in the thing, the symptom or the cost",
          "sk_live_" not in text and text.count("[redacted]") >= 3)
    retro.set_disposition(store, "retro_secretish", "wontfix",
                          proof="operator: rotated sk_live_0123456789abcdefghij")
    check("...nor in a proof recorded on the way out",
          "sk_live_" not in open(
              os.path.join(retro.retro_dir(store), "retro_secretish.md"),
              encoding="utf-8").read())

with tempfile.TemporaryDirectory() as store:
    # Redaction must not touch the probe: the approval hash covers those exact
    # bytes, and rewriting them would break working shell as well as the hash.
    keyish = 'echo "token=abc123" && echo "RETRO-FIXED $RETRO_NONCE"'
    retro.write_item(store, name="retro_probe_bytes", description="Probe bytes.",
                     surface="plugin", thing="x", symptom="y", probe=keyish)
    check("the probe is stored byte-identically, never redacted",
          retro.read_item(store, "retro_probe_bytes")["probe"] == keyish)


print("== the excerpt is redacted before it is truncated ==")

with tempfile.TemporaryDirectory() as d:
    tpath = os.path.join(d, "jwt.jsonl")
    with open(tpath, "w", encoding="utf-8") as fh:
        fh.write(json.dumps({
            "uuid": "j1", "type": "assistant", "timestamp": "2026-08-18T09:00:00Z",
            "message": {"content": [
                {"type": "tool_use", "id": "t1", "name": "Bash"}]}}) + "\n")
        fh.write(json.dumps({
            "uuid": "j2", "type": "user", "timestamp": "2026-08-18T09:00:01Z",
            "message": {"content": [
                {"type": "tool_result", "tool_use_id": "t1", "is_error": True,
                 "content": "auth rejected: Bearer " + FAKE_JWT
                            + " " + "tail padding " * 20}]}}) + "\n")
    q = write_queue(d, qline("jwt-session", tpath, ts="2026-08-19T09:00:00Z"))
    # Cut inside the payload, so the surviving text is no longer JWT-shaped:
    # after truncation the pattern cannot match it at all.
    cut = len("auth rejected: Bearer eyJhbGciOiJIUzI1NiJ9.") + 20
    out = retro.drain(queue=q, live_session_id="live", now=NOW,
                      max_excerpt_chars=cut)
    excerpt = out["drained"][0]["candidates"][0]["excerpt"]
    check("a JWT cut in half by the excerpt ceiling is still redacted",
          "eyJhbGciOiJIUzI1NiJ9" not in excerpt)
    check("...and the failure text around it survives",
          "auth rejected" in excerpt)


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
    # A PreCompact record exists because the agent is about to lose its view of
    # what just failed. Advancing this session's cursor past that span would make
    # the failures unreachable to every later drain as well — the record would
    # then have cost a queue line and yielded nothing, ever.
    q = write_queue(d, qline(DRAINED_SESSION, DRAINED, event="PreCompact:auto"))
    out = retro.drain(queue=q, live_session_id=DRAINED_SESSION, now=NOW)
    check("the live session is never drained — the live vent pass owns it",
          out["drained"] == [] and out["kept"] == 1)
    kept = retro.parse_queue_line(queue_lines(q)[0])
    check("...and a compacted live session keeps its cursor behind the lost span",
          kept["cursor_uuid"] == "" and out["held"] == 1 and out["stamped"] == 0)
    again = retro.drain(queue=q, live_session_id=DRAINED_SESSION, now=NOW)
    check("...and a second drain in the same session changes nothing",
          again["held"] == 1 and again["drained"] == []
          and retro.parse_queue_line(queue_lines(q)[0])["cursor_uuid"] == "")
    later = retro.drain(queue=q, live_session_id="someone-else", now=NOW)
    check("...so once the session ends the pre-compaction failures still drain",
          drained_uuids(later) == ["u3", "u5", "u7"])

with tempfile.TemporaryDirectory() as d:
    q = write_queue(d, qline(DRAINED_SESSION, DRAINED, cursor="u3",
                             event="PreCompact:auto"))
    out = retro.drain(queue=q, live_session_id=DRAINED_SESSION, now=NOW)
    check("a held cursor is held where it was, not reset",
          retro.parse_queue_line(queue_lines(q)[0])["cursor_uuid"] == "u3"
          and out["held"] == 1)
    later = retro.drain(queue=q, live_session_id="someone-else", now=NOW)
    check("...and the next drain resumes from it",
          drained_uuids(later) == ["u5", "u7"])

with tempfile.TemporaryDirectory() as d:
    # No compaction, so nothing was lost from the agent's view: the live vent
    # pass really has seen this material and the cursor may advance past it.
    q = write_queue(d, qline(DRAINED_SESSION, DRAINED, event="SessionEnd:clear"))
    out = retro.drain(queue=q, live_session_id=DRAINED_SESSION, now=NOW)
    check("an uncompacted live session still stamps its cursor to the tail",
          retro.parse_queue_line(queue_lines(q)[0])["cursor_uuid"] == "u7"
          and out["stamped"] == 1 and out["held"] == 0)

with tempfile.TemporaryDirectory() as d:
    q = write_queue(d, qline(DRAINED_SESSION, DRAINED, event="SessionEnd:clear",
                             ts="2026-08-18T09:30:00Z"),
                    qline(DRAINED_SESSION, DRAINED, event="PreCompact:auto",
                          ts="2026-08-18T11:00:00Z"))
    out = retro.drain(queue=q, live_session_id=DRAINED_SESSION, now=NOW)
    check("one PreCompact among the collapsed records holds the whole group",
          out["held"] == 1 and out["stamped"] == 0
          and retro.parse_queue_line(queue_lines(q)[0])["cursor_uuid"] == "")

with tempfile.TemporaryDirectory() as d:
    q = write_queue(d,
                    qline(DRAINED_SESSION, DRAINED, ts="2026-08-18T09:30:00Z"),
                    qline(DRAINED_SESSION, DRAINED, ts="2026-08-18T11:00:00Z"))
    out = retro.drain(queue=q, live_session_id=DRAINED_SESSION, now=NOW)
    check("a session that compacts twice collapses to one kept record",
          len(queue_lines(q)) == 1 and out["collapsed"] == 1 and out["kept"] == 1)

with tempfile.TemporaryDirectory() as d:
    q = write_queue(d, qline("old-live", DRAINED, ts="2026-07-01T09:00:00Z"))
    out = retro.drain(queue=q, live_session_id="old-live", now=NOW, expiry_days=14)
    check("the live session's record is never expired out from under it",
          out["kept"] == 1 and out["dropped_expired"] == [])

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


# ------------------------------------------------------------- the probe runner
#
# Every assertion here is on disposition ON DISK, on a sentinel file the probe
# would have created, or on a live pid — never on a return code. The runner's own
# report is a convenience; the item file is the truth.
print("== the probe runner (default-deny) ==")

BASH = "/bin/bash"                       # VC6: pin the binary these probes get.


def probe_item(store, name, probe, approve=True):
    retro.write_item(store, name=name, description=name, surface="plugin",
                     thing="x", symptom="y", probe=probe)
    if approve:
        retro.record_probe_approval(store, name, retro.probe_hash(probe))
    return name


def disposition(store, name):
    return retro.read_item(store, name)["frontmatter"].get("disposition")


def run_one(store, name, probe, approve=True, budget=30):
    probe_item(store, name, probe, approve=approve)
    return retro.run_probe(store, name, budget=budget)


CLOSING = 'echo before\necho "RETRO-FIXED $RETRO_NONCE"\necho after'

with tempfile.TemporaryDirectory() as store:
    run_one(store, "retro_closes", CLOSING)
    check("a whole line equal to RETRO-FIXED <nonce> among other output closes the item",
          disposition(store, "retro_closes") == "fixed")
    check("...and the close carries a recorded proof",
          bool(retro.read_item(store, "retro_closes")["frontmatter"].get("proof")))

with tempfile.TemporaryDirectory() as store:
    run_one(store, "retro_exit1", 'echo "RETRO-FIXED $RETRO_NONCE"\nexit 1')
    check("the right line with a non-zero exit leaves the item open",
          disposition(store, "retro_exit1") == "open")

with tempfile.TemporaryDirectory() as store:
    run_one(store, "retro_silent", "exit 0")
    check("no output and exit 0 leaves the item open",
          disposition(store, "retro_silent") == "open")

with tempfile.TemporaryDirectory() as store:
    # The `timeout`-does-not-exist trap: the token is an argument to a binary
    # that is not there, so nothing prints and the shell exits 127.
    run_one(store, "retro_nobinary",
            'retro-no-such-binary-xyzzy "RETRO-FIXED $RETRO_NONCE"')
    check("a probe invoking a non-existent binary leaves the item open",
          disposition(store, "retro_nobinary") == "open")

with tempfile.TemporaryDirectory() as store:
    run_one(store, "retro_stderr", 'echo "RETRO-FIXED $RETRO_NONCE" >&2')
    check("the right line on stderr leaves the item open",
          disposition(store, "retro_stderr") == "open")

with tempfile.TemporaryDirectory() as store:
    # The forged-token case: a probe re-runs the broken tool and forwards its
    # output, and that output is shaped by material the operator never wrote.
    run_one(store, "retro_forged", '%s -c "echo RETRO-FIXED"' % BASH)
    check("forwarded output carrying a bare RETRO-FIXED line leaves the item open",
          disposition(store, "retro_forged") == "open")

with tempfile.TemporaryDirectory() as store:
    run_one(store, "retro_substring",
            'echo "prefix RETRO-FIXED $RETRO_NONCE suffix"')
    check("the token as a substring of a longer line leaves the item open",
          disposition(store, "retro_substring") == "open")

with tempfile.TemporaryDirectory() as store:
    saved = os.path.join(store, "seen-nonce")
    stale = ('if [ -s "%s" ]; then echo "RETRO-FIXED $(cat %s)"; '
             'else printf %%s "$RETRO_NONCE" > "%s"; fi' % (saved, saved, saved))
    probe_item(store, "retro_stale", stale)
    retro.run_probe(store, "retro_stale", budget=30)
    check("a probe that only stores the nonce closes nothing",
          disposition(store, "retro_stale") == "open")
    retro.run_probe(store, "retro_stale", budget=30)
    check("...and replaying that nonce on the next execution still leaves it open",
          disposition(store, "retro_stale") == "open")

with tempfile.TemporaryDirectory() as store:
    sentinel = os.path.join(store, "it-ran")
    body = 'touch "%s"\necho "RETRO-FIXED $RETRO_NONCE"' % sentinel
    probe_item(store, "retro_unapproved", body, approve=False)
    retro.run_probe(store, "retro_unapproved", budget=30)
    check("an unapproved probe is never executed",
          not os.path.exists(sentinel))
    check("...and its item stays open",
          disposition(store, "retro_unapproved") == "open")
    check("...and the refusal is recorded on the item",
          retro.read_item(store, "retro_unapproved")["frontmatter"]
          .get("probe_result") == "unapproved")

with tempfile.TemporaryDirectory() as store:
    sentinel = os.path.join(store, "it-ran")
    body = 'touch "%s"\necho "RETRO-FIXED $RETRO_NONCE"' % sentinel
    retro.write_item(store, name="retro_edited", description="edited",
                     surface="plugin", thing="x", symptom="y", probe=body)
    retro.record_probe_approval(store, "retro_edited",
                                retro.probe_hash("a different probe"))
    retro.run_probe(store, "retro_edited", budget=30)
    check("a probe whose recorded hash no longer matches is never executed",
          not os.path.exists(sentinel))
    check("...and its item stays open",
          disposition(store, "retro_edited") == "open")
    retro.record_probe_approval(store, "retro_edited", retro.probe_hash(body))
    retro.run_probe(store, "retro_edited", budget=30)
    check("...until it is approved again, after which it runs and can close",
          os.path.exists(sentinel) and disposition(store, "retro_edited") == "fixed")

with tempfile.TemporaryDirectory() as store:
    pidfile = os.path.join(store, "grandchild.pid")
    slow = ('( sleep 45 ) &\n'
            'echo $! > "%s"\n'
            'sleep 45\n'
            'echo "RETRO-FIXED $RETRO_NONCE"' % pidfile)
    probe_item(store, "retro_slow", slow)
    retro.run_probe(store, "retro_slow", budget=2)
    check("a probe that sleeps past the budget leaves its item open",
          disposition(store, "retro_slow") == "open")
    gone = False
    if os.path.exists(pidfile):
        gpid = int(open(pidfile).read().strip() or 0)
        for _ in range(40):
            try:
                os.kill(gpid, 0)
            except ProcessLookupError:
                gone = True
                break
            except PermissionError:
                break
            time.sleep(0.1)
    check("...and the grandchild in its process group is killed with it", gone)

with tempfile.TemporaryDirectory() as store:
    retro.write_item(store, name="retro_bare", description="no probe",
                     surface="harness", thing="x", symptom="y")
    probe_item(store, "retro_proves", CLOSING)
    out = retro.run_probes(store, budget=30)
    check("a whole-backlog run never closes an item that carries no probe",
          disposition(store, "retro_bare") == "open")
    check("...while the item whose probe proved fixed is closed",
          disposition(store, "retro_proves") == "fixed")
    check("...and the run reports what it attempted",
          out["attempted"] == 1 and out["closed"] == 1)
    closed = [i for i in retro.list_items(store)
              if i["frontmatter"].get("disposition") != "open"]
    check("no item is closed without a recorded proof (invariant, not a field check)",
          all(i["frontmatter"].get("proof") for i in closed))

with tempfile.TemporaryDirectory() as store:
    run_one(store, "retro_recorded", 'echo hello\nexit 3')
    fm = retro.read_item(store, "retro_recorded")["frontmatter"]
    check("a run that proves nothing still records what ran and what it printed",
          bool(fm.get("probe_ran")) and "hello" in (fm.get("probe_detail") or "")
          and fm.get("probe_result") == "unproven")


# ------------------------------------------------------------- the capture window
#
# `counts` reads the previous REFLECT.log stamp and counts items touched since.
# The stamp is LOCAL time carrying its own offset, so the arithmetic is where the
# whole tally lives or dies: a `since` pushed into the future reports zero
# forever, which reads exactly like a reflect run that captured nothing.
print("== the capture window ==")

from datetime import datetime, timedelta, timezone  # noqa: E402

with tempfile.TemporaryDirectory() as store:
    retro.write_item(store, name="retro_touched", description="Touched.",
                     surface="plugin", thing="x", symptom="y")
    log = os.path.join(store, "REFLECT.log")
    # An explicit non-UTC offset, built from epoch arithmetic: the stamp means
    # one hour ago on any box, whatever this machine's own zone is.
    stamp = datetime.fromtimestamp(time.time() - 3600,
                                   timezone(timedelta(hours=2))).isoformat()
    with open(log, "w", encoding="utf-8") as fh:
        fh.write("2026-01-01T00:00:00+02:00 boot retro_captured=0\n")
        fh.write(stamp + " t1 updated=0 retro_captured=0\n")
    captured, opened = retro.counts(store)
    check("an item touched since the last reflect line counts as captured",
          captured == 1)
    check("...and it counts as open", opened == 1)
    old = time.time() - 7200
    os.utime(retro.item_path(store, "retro_touched"), (old, old))
    check("...while an item older than that line does not",
          retro.counts(store) == (0, 1))

with tempfile.TemporaryDirectory() as store:
    retro.write_item(store, name="retro_nolog", description="No log.",
                     surface="plugin", thing="x", symptom="y")
    check("with no REFLECT.log every item counts as captured",
          retro.counts(store) == (1, 1))

with tempfile.TemporaryDirectory() as store:
    retro.write_item(store, name="retro_badstamp", description="Bad stamp.",
                     surface="plugin", thing="x", symptom="y")
    with open(os.path.join(store, "REFLECT.log"), "w", encoding="utf-8") as fh:
        fh.write("not-a-timestamp t1 retro_captured=0\n")
    check("an unparseable stamp counts everything rather than silently nothing",
          retro.counts(store) == (1, 1))


# ------------------------------------------------- KTD9: the execution boundary
#
# The check that keeps probes attended is itself a shipped script, so this test
# runs the SAME expression the harness runs rather than a restatement of it.
print("== the execution boundary (KTD9) ==")

BOUNDARY = os.path.join(HERE, "probe_boundary_check.sh")

with tempfile.TemporaryDirectory() as tmp:
    clean = subprocess.run([BASH, BOUNDARY, REPO], capture_output=True, text=True)
    check("the boundary check passes against the plugin as it ships",
          clean.returncode == 0)

    copy = os.path.join(tmp, "reflect")
    os.makedirs(copy)
    shutil.copytree(os.path.join(REPO, "hooks"), os.path.join(copy, "hooks"))
    os.makedirs(os.path.join(copy, "scripts"))
    shutil.copy(os.path.join(REPO, "scripts", "reflect-run.sh"),
                os.path.join(copy, "scripts", "reflect-run.sh"))
    hook = os.path.join(copy, "hooks", "retro-queue.sh")
    with open(hook, "a", encoding="utf-8") as fh:
        fh.write('\npython3 "$D/retro.py" probe "$STORE" || true\n')
    wired = subprocess.run([BASH, BOUNDARY, copy], capture_output=True, text=True)
    check("...and fails when a hook is made to reference the probe entry point",
          wired.returncode != 0)

    missing = subprocess.run([BASH, BOUNDARY, os.path.join(tmp, "not-a-plugin")],
                             capture_output=True, text=True)
    check("...and fails rather than passing green when its search targets are gone",
          missing.returncode != 0)


print()
print(f"retro_test: {PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
