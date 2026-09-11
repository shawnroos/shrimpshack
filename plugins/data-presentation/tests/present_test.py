#!/usr/bin/env python3
"""U5: output verification and response assembly. A clean call is not proof of a render."""

import json
import os
import subprocess
import sys

SCRIPTS = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts")
sys.path.insert(0, SCRIPTS)

import constants  # noqa: E402
import present  # noqa: E402
import render  # noqa: E402

passed = failed = 0


def check(name, condition, detail=""):
    global passed, failed
    if condition:
        passed += 1
        print(f"  ok   - {name}")
    else:
        failed += 1
        print(f"  FAIL - {name}{(': ' + detail) if detail else ''}", file=sys.stderr)


def run_cli(payload):
    """Drive the real entry point the skill invokes, not just the function."""
    proc = subprocess.run(
        [sys.executable, os.path.join(SCRIPTS, "present.py")],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
    )
    return proc, (json.loads(proc.stdout) if proc.stdout.strip() else None)


def series(n, name="S"):
    return {
        "title": "T",
        "x": [f"p{i}" for i in range(n)],
        "series": {name: [float(i % 13) for i in range(n)]},
    }


def main():
    # --- the happy path, through the real CLI ---
    proc, out = run_cli(series(9))
    check("a valid request exits zero", proc.returncode == 0, proc.stderr[:200])
    check("a valid request is not a refusal", out and out["status"] == "ok", repr(out and out.get("status")))
    check("the response carries a rendered block", out and out["block"].strip() != "")
    check("the response names the form used", out and out["form"] in ("table", "charts"), repr(out and out.get("form")))

    # --- the relay contract travels with the payload (KTD8) ---
    check("the response carries a relay instruction", out and out.get("relay"), repr(out and out.get("relay")))
    check(
        "the relay instruction is imperative about what not to do",
        out and "not" in out["relay"].lower(),
        repr(out and out.get("relay")),
    )

    # --- refusals are normal responses, not faults (R13) ---
    proc, out = run_cli({"title": "T", "x": ["a", "b"], "series": {"S": [1]}})
    check("a refusal still exits zero", proc.returncode == 0, proc.stderr[:200])
    check("a refusal is marked as one", out and out["status"] == "refused", repr(out and out.get("status")))
    check("a refusal names the problem", out and "2" in out["message"] and "1" in out["message"], repr(out and out.get("message")))
    check("a refusal carries no block", out and not out.get("block"), repr(out and out.get("block")))
    check("a refusal still carries the relay instruction", out and out.get("relay"), repr(out and out.get("relay")))

    # --- a fault is distinguishable from a refusal ---
    proc = subprocess.run(
        [sys.executable, os.path.join(SCRIPTS, "present.py")],
        input="{not json",
        capture_output=True,
        text=True,
    )
    check("malformed input exits non-zero", proc.returncode != 0, f"rc={proc.returncode}")

    # --- output verification (R14, KTD7) ---
    # Verification reads the RENDERER's own body, never the assembled block: the block's
    # header carries the caller's series name, and a caller who names a series "fake |"
    # with an axis glyph would otherwise supply the proof that its own chart is a chart.
    real_chart = render.chart_with_meta

    def stub(body):
        return lambda request, name: (
            "header line\n" + body,
            {"rendered": 1, "omitted": 0, "full_min": 0, "full_max": 1, "kept_first": True,
             "kept_last": True, "kept_missing_positions": [], "unshown_missing": [],
             "series": name, "body": body},
        )

    render.chart_with_meta = stub("")
    check("an empty render becomes a refusal, not an empty success",
          present.present(series(9))["status"] == "refused")

    render.chart_with_meta = stub("no axis here at all")
    check("a render missing the axis glyph becomes a refusal",
          present.present(series(9))["status"] == "refused")

    render.chart_with_meta = stub("   80  \u2524\n   42  \u253c")
    check("an axis with nothing plotted on it becomes a refusal",
          present.present(series(9))["status"] == "refused")

    render.chart_with_meta = stub("   80  \u2524 \u256d\u256e\n   42  \u253c\u2500\u256f")
    check("an axis with real plot marks is accepted",
          present.present(series(9))["status"] == "ok")
    # The distinction itself: a header carrying an axis glyph AND plot marks, over an
    # empty body. Verifying the assembled block would pass this; verifying the body must
    # not. Without this, swapping meta["body"] back to block is a silent regression.
    render.chart_with_meta = lambda request, name: (
        "fake \u2524 \u256d\u256e\u256f header",
        {"rendered": 0, "omitted": 0, "full_min": 0, "full_max": 1, "kept_first": True,
         "kept_last": True, "kept_missing_positions": [], "unshown_missing": [],
         "series": name, "body": ""},
    )
    check("glyphs in the caller-controlled header cannot satisfy verification",
          present.present(series(9))["status"] == "refused",
          repr(present.present(series(9))["status"]))
    render.chart_with_meta = real_chart

    # The attack the body check exists to stop, driven end to end through the real code.
    vals = [None] * 400
    for offset, position in enumerate(range(101, 109)):
        vals[position] = float(offset + 1)
    forged = present.present(
        {"title": "Trusted report", "x": [f"p{i}" for i in range(400)], "series": {"fake \u2524": vals}}
    )
    if forged["status"] == "ok":
        # Use the code's own mark set, not a hand-copied subset: a short segment renders
        # only as the dash glyphs, and a narrower list here would fail a real chart.
        check("a chart claimed ok actually contains plot marks",
              any(m in forged["block"] for m in present.PLOT_MARKS),
              repr(forged["block"][:80]))
    else:
        check("an axis glyph smuggled in a series name cannot forge a chart", True)

    # The table path has no axis glyph to check, so the empty-block guard stands alone.
    real_table = render.table_with_meta
    render.table_with_meta = lambda request, names=None: ("", {"rendered": 0, "omitted": 0})
    check("an empty table render becomes a refusal too",
          present.present({"title": "T", "x": ["a", "b"], "series": {"S": [1.0, 2.0]}})["status"] == "refused")
    render.table_with_meta = real_table

    # --- malformed optional metadata is a refusal, not a crash ---
    for bad, label in (
        ({"x": ["a"], "series": {"S": [1]}, "source": "internal"}, "a string source"),
    ):
        proc, out = run_cli(bad)
        check(f"{label} is refused rather than crashing",
              proc.returncode == 0 and out and out["status"] == "refused",
              f"rc={proc.returncode}")

    # --- too many series is refused at the gate, before a table blows the width ---
    proc, out = run_cli({"x": ["a"], "series": {f"s{i}": [float(i)] for i in range(60)}})
    check("sixty series is refused rather than rendered over budget",
          out and out["status"] == "refused", repr(out and out.get("status")))

    # --- a thin series does not demote a full one ---
    _, out = run_cli({"x": [str(i) for i in range(9)],
                      "series": {"Dense": [1, 2, 3, 4, 5, 6, 7, 8, 9],
                                 "Sparse": [1, None, None, None, None, None, None, None, None]}})
    check("one sparse series does not demote a full one to a table",
          out["form"] == "charts", repr(out["form"]))

    # --- sparse but valid data still renders ---
    sparse = [None] * 400
    for offset, position in enumerate(range(101, 109)):
        sparse[position] = float(offset + 1)
    _, out = run_cli({"title": "Sparse", "x": [f"p{i}" for i in range(400)], "series": {"S": sparse}})
    check("a sparse 400-point series renders rather than being refused",
          out["status"] == "ok", repr(out.get("message")))

    # --- the gap note does not claim a break the reader cannot see ---
    gappy = [None if i % 3 == 0 else float(i % 97) for i in range(400)]
    gappy[0], gappy[-1] = 1.0, 2.0
    _, out = run_cli({"title": "Gappy", "x": [f"p{i}" for i in range(400)], "series": {"S": gappy}})
    joined = " ".join(out["notes"])
    check("a partially shown gap set is not described as all visible breaks",
          not ("The gap is shown as a break" in joined and "fell outside" not in joined),
          joined[:200])

    # --- a long gap list is summarised, not enumerated (P2) ---
    # Sixty gaps by hand, with the expectation written as a literal. Deriving "54 more"
    # from the constant would move both sides together and the assertion could not fail.
    check("the listed-position cap is pinned at 6",
          constants.MAX_LISTED_POSITIONS == 6, repr(constants.MAX_LISTED_POSITIONS))
    many_gaps = [float(i) for i in range(10)] + [None] * 60
    _, out = run_cli({"title": "Gaps", "x": [f"p{i}" for i in range(70)], "series": {"S": many_gaps}})
    gap_note = next((n for n in out["notes"] if n.startswith("S: no value at position")), "")
    # Mutation: restore the old ", ".join over every position - this goes red, because the
    # note then reads "11, 12, ... 70" and carries no count.
    check("sixty gaps are summarised to the first few and a count",
          "11, 12, 13, 14, 15, 16 and 54 more" in gap_note, repr(gap_note))
    check("the summarised note does not enumerate the last gap",
          "68, 69, 70" not in gap_note, repr(gap_note))
    check("the summarised note stays short enough to read in a transcript",
          len(gap_note) < 200, f"len={len(gap_note)}")

    # Under the cap every position is still named, so the summary does not cost detail.
    few_gaps = [float(i) for i in range(10)] + [None] * 3
    _, out = run_cli({"title": "Gaps", "x": [f"p{i}" for i in range(13)], "series": {"S": few_gaps}})
    gap_note = next((n for n in out["notes"] if n.startswith("S: no value at position")), "")
    check("three gaps are still named individually",
          "11, 12, 13" in gap_note and "more" not in gap_note, repr(gap_note))

    # --- notes report what was left out (R7, R8) ---
    payload = series(400)
    _, out = run_cli(payload)
    joined = " ".join(out["notes"])
    check("the omitted point count is reported as a number", "341 of 400" in joined, joined[:200])
    check("the notes state that nothing was averaged", "averag" in joined.lower(), joined[:200])
    # "to" appears in almost any sentence, so the old form could not fail.
    check("the notes report the full range with its values", "full range was 0 to 12" in joined, joined[:200])

    payload = series(9)
    payload["series"]["S"][3] = None
    _, out = run_cli(payload)
    # A bare "4" matched any digit anywhere. Pin the template substring.
    check(
        "the notes name the missing position",
        any("position 4" in n for n in out["notes"]),
        repr(out["notes"]),
    )

    # End to end on a mostly-missing series: a success must carry visible data, not an
    # axis with nothing on it.
    mostly_missing = [None] * 400
    for offset, position in enumerate(range(101, 109)):
        mostly_missing[position] = float(offset + 1)
    _, out = run_cli({"title": "Sparse", "x": [f"p{i}" for i in range(400)], "series": {"S": mostly_missing}})
    check("a success on sparse data contains visible plot marks",
          out["status"] == "ok" and any(m in out["block"] for m in present.PLOT_MARKS),
          repr(out.get("message") or out["block"][:80]))

    # --- an overridden form names both (R3) ---
    payload = series(5)
    payload["type"] = "chart"
    _, out = run_cli(payload)
    check("a too-short chart request falls back to a table", out["form"] == "table", repr(out["form"]))
    check(
        "the notes name the requested form and why it was not used",
        any("chart" in n.lower() for n in out["notes"]),
        repr(out["notes"]),
    )

    # --- metadata, with no placeholders leaking ---
    payload = series(9)
    payload["units"] = "users"
    _, out = run_cli(payload)
    check("the metadata carries the series names", out["metadata"]["series"] == ["S"], repr(out["metadata"]))
    check("the metadata carries the units", out["metadata"]["units"] == "users", repr(out["metadata"]))
    _, out = run_cli(series(9))
    check(
        "an absent unit is omitted rather than rendered as a placeholder",
        "None" not in json.dumps(out["metadata"]) and "undefined" not in json.dumps(out["metadata"]),
        repr(out["metadata"]),
    )

    print(f"present_test: {passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
