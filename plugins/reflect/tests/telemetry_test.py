#!/usr/bin/env python3
"""telemetry_test.py — the measurement split (U7).

Covers the properties that make the split real rather than decorative:
RECALL.log stays out of activation, only `applied` raises activation, the
historical bracketed-annotation rule is asserted rather than assumed, concurrent
appends don't corrupt a line, an unwritable log costs the caller nothing, and the
surfaced->applied join refuses to credit one session's nudge to another session's
application. Needs no qmd and no network. Run: `python3 tests/telemetry_test.py`.
"""
import os
import subprocess
import sys
import tempfile
from datetime import date, timedelta

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "scripts"))
sys.path.insert(0, os.path.join(HERE, "..", "scripts", "scoped-memory"))
import memory_activation as ma  # noqa: E402
import telemetry as tel  # noqa: E402

PASS = 0
FAIL = 0
TODAY = date(2026, 8, 9)


def check(name, cond):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  ok   - {name}")
    else:
        FAIL += 1
        print(f"  FAIL - {name}", file=sys.stderr)


def write(path, text):
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


# --------------------------------------------------------- RECALL.log shape
with tempfile.TemporaryDirectory() as d:
    rlog = os.path.join(d, tel.RECALL_LOG_NAME)
    check("append_recall reports success on a writable log",
          tel.append_recall(rlog, "reference_e2e_flake", "nudge", "trigger",
                            session_id="sessA", score=0.71, floor=0.45) is True)
    recs = tel.parse_recall(rlog)
    check("a surfacing record round-trips through parse_recall",
          len(recs) == 1 and recs[0]["memory"] == "reference_e2e_flake"
          and recs[0]["source"] == "nudge" and recs[0]["layer"] == "trigger"
          and recs[0]["session_id"] == "sessA")
    check("gate/score data survives as parsed key=value extras",
          recs[0]["extra"].get("score") == "0.71"
          and recs[0]["extra"].get("floor") == "0.45")
    check("every declared source is accepted and read back",
          all(tel.append_recall(rlog, "m_x", src, "local", session_id="s")
              for src in tel.SOURCES))

    # mixed-source counting
    mixed = os.path.join(d, "mixed.log")
    for src, mem in (("seeded", "m_a"), ("seeded", "m_b"), ("nudge", "m_a"),
                     ("cli", "m_a"), ("regroup", "m_c"), ("memories-cmd", "m_b")):
        tel.append_recall(mixed, mem, src, "qmd", session_id="s1")
    mrecs = tel.parse_recall(mixed)
    check("mixed-source log yields correct per-source counts",
          tel.counts_by(mrecs, "source") == {"seeded": 2, "nudge": 1, "cli": 1,
                                             "regroup": 1, "memories-cmd": 1})
    check("mixed-source log yields correct per-memory counts",
          tel.counts_by(mrecs, "memory") == {"m_a": 3, "m_b": 2, "m_c": 1})

    # a writer with genuinely no session id records the absence explicitly
    os.environ.pop("CLAUDE_SESSION_ID", None)
    nolog = os.path.join(d, "nosession.log")
    tel.append_recall(nolog, "m_a", "nudge", "local")
    check("a writer with no session id records the absence explicitly",
          tel.parse_recall(nolog)[0]["session_id"] == tel.NO_SESSION)

    # a multi-word field can never shift the fields after it
    weird = os.path.join(d, "weird.log")
    tel.append_recall(weird, "mem with spaces\nand a newline", "cli", "local",
                      session_id="s 1")
    wrecs = tel.parse_recall(weird)
    check("whitespace in a field cannot split a line or shift later fields",
          len(wrecs) == 1 and wrecs[0]["source"] == "cli"
          and wrecs[0]["layer"] == "local")

# ------------------------------------------------------------- fail-open
with tempfile.TemporaryDirectory() as d:
    ro = os.path.join(d, "readonly")
    os.mkdir(ro)
    os.chmod(ro, 0o500)
    dead = os.path.join(ro, "RECALL.log")
    try:
        wrote = tel.append_recall(dead, "m_a", "nudge", "local", session_id="s")
        recall_still_worked = True
    except Exception:
        wrote = None
        recall_still_worked = False
    os.chmod(ro, 0o700)
    check("an unwritable log raises nothing — the recall path survives it",
          recall_still_worked)
    check("an unwritable log reports failure rather than faking success",
          wrote is False)
    check("an unreadable/missing RECALL.log parses to no records, not an error",
          tel.parse_recall(os.path.join(d, "does-not-exist.log")) == [])

# ------------------------------------------------- concurrent append safety
with tempfile.TemporaryDirectory() as d:
    clog = os.path.join(d, "concurrent.log")
    writer = os.path.join(d, "writer.py")
    write(writer, (
        "import sys\n"
        "sys.path.insert(0, %r)\n"
        "import telemetry as tel\n"
        "tag = sys.argv[2]\n"
        "for i in range(400):\n"
        "    tel.append_recall(sys.argv[1], 'memory_%%s_%%04d' %% (tag, i),\n"
        "                      'nudge', 'local', session_id='sess'+tag,\n"
        "                      score=0.5, floor=0.45)\n"
    ) % os.path.join(HERE, "..", "scripts", "scoped-memory"))
    procs = [subprocess.Popen([sys.executable, writer, clog, tag])
             for tag in ("A", "B")]
    for p in procs:
        p.wait()
    lines = open(clog, encoding="utf-8").read().splitlines()
    check("concurrent writers lose no line (800 written, 800 present)",
          len(lines) == 800)
    check("no line is interleaved or truncated by a concurrent writer",
          all(len(ln.split()) == 7 and ln.split()[3].startswith("memory_")
              and ln.split()[2] == "nudge" for ln in lines))
    check("both writers' records are individually intact",
          tel.counts_by(tel.parse_recall(clog), "session_id")
          == {"sessA": 400, "sessB": 400})

# ---------------------------------------- the token rule (KTD9a) — stated
check("use_line_counts: a bare line with no token counts (historical)",
      ma.use_line_counts("2026-01-02 mem_a".split()) is True)
check("use_line_counts: field 3 starting with '[' is annotation, and counts",
      ma.use_line_counts("2026-01-02 mem_a [some note]".split()) is True)
check("use_line_counts: field 3 starting with '(' is annotation, and counts",
      ma.use_line_counts("2026-01-02 mem_a (some note)".split()) is True)
check("use_line_counts: 'applied' counts",
      ma.use_line_counts("2026-01-02 mem_a applied".split()) is True)
check("use_line_counts: 'written' does not count",
      ma.use_line_counts("2026-01-02 mem_a written".split()) is False)
check("use_line_counts: 'reflect' does not count",
      ma.use_line_counts("2026-01-02 mem_a reflect".split()) is False)
check("use_line_counts: an unreserved bare token is a historical context tag, and counts",
      ma.use_line_counts("2026-01-02 mem_a web2991-session".split()) is True)
check("use_line_counts: exclusion is by exact token, never by prefix",
      ma.use_line_counts("2026-01-02 mem_a reflect-manual".split()) is True)
check("the reserved non-application set is exactly {written, reflect}",
      set(ma.NON_APPLICATION_TOKENS) == {"written", "reflect"})
check("use_line_counts: a line with no memory name is not a record",
      ma.use_line_counts("2026-01-02".split()) is False)
check("use_line_counts: a full T-timestamp line still counts under the name",
      ma.use_line_counts("2026-08-09T14:03:11 mem_a applied [session:x]".split()) is True)

# --------------------------- only 'applied' moves activation (KTD9a, for real)
with tempfile.TemporaryDirectory() as d:
    # a mid-pack memory: at full freshness activation already sits at the floor's
    # reference point, so the floor could not move and the assertion below would
    # pass vacuously.
    body = "---\nlast_used: %s\n---\nbody\n" % (TODAY - timedelta(days=45))
    write(os.path.join(d, "mem_a.md"), body)
    ulog = os.path.join(d, "MEMORY_USE.log")

    write(ulog, "")
    base = dict(ma.score_dir(d, today=TODAY))["mem_a.md"]

    write(ulog, "2026-08-09 mem_a written\n2026-08-09 mem_a reflect\n"
                "2026-08-09 mem_a written\n")
    non_applied = dict(ma.score_dir(d, today=TODAY))["mem_a.md"]
    check("written/reflect lines leave activation UNCHANGED",
          abs(non_applied - base) < 1e-12)
    check("written/reflect lines contribute zero use count",
          ma.use_counts(ulog).get("mem_a", 0) == 0)

    write(ulog, "2026-08-09T09:00:00 mem_a applied [session:s1]\n")
    applied = dict(ma.score_dir(d, today=TODAY))["mem_a.md"]
    check("an 'applied' line MOVES activation upward",
          applied > base + 1e-9)
    check("an 'applied' line with a full timestamp counts under the memory name",
          ma.use_counts(ulog).get("mem_a", 0) == 1)

    # historical bracketed lines keep counting — the stated rule, end to end
    write(ulog, "2026-06-20 mem_a [gh pr view returned thin output]\n")
    historical = dict(ma.score_dir(d, today=TODAY))["mem_a.md"]
    check("a historical bracket-annotated line still raises activation",
          abs(historical - applied) < 1e-12 and historical > base)

    # a written line must not lower the memory's recall floor
    check("written/reflect lines do not lower the recall floor",
          ma.recall_floor(non_applied) == ma.recall_floor(base))
    check("an applied line does lower the recall floor",
          ma.recall_floor(applied) < ma.recall_floor(base))

# ----------------------- isolation: RECALL.log never reaches use_counts (KTD9)
with tempfile.TemporaryDirectory() as d:
    write(os.path.join(d, "mem_a.md"), "---\nlast_used: 2026-08-09\n---\nbody\n")
    write(os.path.join(d, "mem_b.md"), "---\nlast_used: 2026-08-09\n---\nbody\n")
    ulog = os.path.join(d, tel.USE_LOG_NAME)
    write(ulog, "2026-08-01 mem_a [note]\n")
    before_counts = ma.use_counts(ulog)
    before_scores = dict(ma.score_dir(d, today=TODAY))

    rlog = os.path.join(d, tel.RECALL_LOG_NAME)
    for i in range(50):
        tel.append_recall(rlog, "mem_a", "nudge", "local", session_id="s1",
                          score=0.9)
        tel.append_recall(rlog, "mem_b", "seeded", "qmd", session_id="s1",
                          score=0.9)

    check("50 surfacing events per memory leave use_counts untouched",
          ma.use_counts(ulog) == before_counts)
    check("50 surfacing events leave every activation score untouched",
          dict(ma.score_dir(d, today=TODAY)) == before_scores)
    check("RECALL.log is not itself scored as a memory body",
          tel.RECALL_LOG_NAME not in before_scores)

# ------------------------------- the two-concurrent-session join (KTD9b)
with tempfile.TemporaryDirectory() as d:
    rlog = os.path.join(d, tel.RECALL_LOG_NAME)
    ulog = os.path.join(d, tel.USE_LOG_NAME)
    # Session A surfaces X at 09:00; session B applies X at 10:00 the SAME DAY.
    tel.append_recall(rlog, "mem_x", "nudge", "local", session_id="sessA",
                      ts="2026-08-09T09:00:00")
    write(ulog, tel.format_applied("mem_x", session_id="sessB",
                                   ts="2026-08-09T10:00:00") + "\n")
    joined = tel.join_surfaced_applied(tel.parse_recall(rlog), tel.parse_use(ulog))
    check("session A's nudge is NOT credited to session B's application",
          len(joined) == 1 and joined[0]["credited"] is False)
    check("an uncredited surfacing yields a zero credited fraction",
          tel.credited_fraction(joined) == 0.0)

    # same session, later application -> credited
    write(ulog, tel.format_applied("mem_x", session_id="sessA",
                                   ts="2026-08-09T10:00:00") + "\n")
    joined = tel.join_surfaced_applied(tel.parse_recall(rlog), tel.parse_use(ulog))
    check("the SAME session's later application IS credited",
          joined[0]["credited"] is True
          and joined[0]["applied"]["session_id"] == "sessA")

    # an application that predates the surfacing is not evidence the nudge worked
    write(ulog, tel.format_applied("mem_x", session_id="sessA",
                                   ts="2026-08-09T08:00:00") + "\n")
    joined = tel.join_surfaced_applied(tel.parse_recall(rlog), tel.parse_use(ulog))
    check("an application BEFORE the surfacing is not credited to it",
          joined[0]["credited"] is False)

    # absence never joins to absence
    write(ulog, tel.format_applied("mem_x", session_id=None,
                                   ts="2026-08-09T10:00:00") + "\n")
    rlog2 = os.path.join(d, "nosession-recall.log")
    tel.append_recall(rlog2, "mem_x", "nudge", "local", session_id=None,
                      ts="2026-08-09T09:00:00")
    joined = tel.join_surfaced_applied(tel.parse_recall(rlog2), tel.parse_use(ulog))
    check("two records that both recorded NO session id do not join",
          joined[0]["credited"] is False)
    check("same_session refuses the absence sentinel on both sides",
          tel.same_session(tel.NO_SESSION, tel.NO_SESSION) is False)
    # The sentinel is spelled exactly as the Memory Protocol's `[session:unknown]`,
    # so a writer following the doc gets refuse-to-join rather than join-everything.
    check("the literal the docs tell agents to write IS the absence sentinel",
          tel.NO_SESSION == "unknown"
          and tel.same_session("unknown", "unknown") is False)
    write(ulog, "2026-08-09T10:00:00 mem_x applied [session:unknown]\n")
    rlog3 = os.path.join(d, "doc-literal-recall.log")
    tel.append_recall(rlog3, "mem_x", "nudge", "local", session_id="unknown",
                      ts="2026-08-09T09:00:00")
    joined = tel.join_surfaced_applied(tel.parse_recall(rlog3), tel.parse_use(ulog))
    check("two records both written as [session:unknown] do not join",
          joined[0]["credited"] is False)

    # a 'written' line is not an application and cannot credit a nudge
    write(ulog, "2026-08-09T10:00:00 mem_x written [session:sessA]\n")
    joined = tel.join_surfaced_applied(tel.parse_recall(rlog), tel.parse_use(ulog))
    check("a same-session 'written' line does not credit a nudge",
          joined[0]["credited"] is False)

# ------------------------------------------------- applied-line round trip
line = tel.format_applied("mem_a", session_id="s1", annotation="used in triage")
rec = tel.parse_use_line(line)
check("format_applied round-trips through parse_use_line",
      rec["memory"] == "mem_a" and rec["token"] == "applied"
      and rec["session_id"] == "s1" and rec["counts"] is True)
check("an applied line keeps the memory name in field 2 for legacy readers",
      line.split()[1] == "mem_a")
check("parse_use_line reads a historical bracketed line as a counting record",
      tel.parse_use_line("2026-06-20 mem_a [note here]")["counts"] is True)
check("parse_use_line reads a 'written' line as non-counting",
      tel.parse_use_line("2026-08-09 mem_a written")["counts"] is False)
check("a historical line reports NO session id rather than inventing one",
      tel.parse_use_line("2026-06-20 mem_a [note]")["session_id"] == tel.NO_SESSION)

# an annotation can never inject a session id or extra fields
sneaky = tel.format_applied("mem_a", session_id="s1",
                            annotation="[session:evil] and\nmore")
check("an annotation cannot inject a second session token",
      tel.parse_use_line(sneaky)["session_id"] == "s1")

print()
print(f"telemetry_test: {PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
