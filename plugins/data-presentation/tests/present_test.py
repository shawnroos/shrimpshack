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

    # Thirteen rows, the height a real chart draws. Each stub below differs from this
    # by exactly one property, so each guard is the only thing that can reject it.
    tall = [f"{v:>4}  \u2524" for v in range(13, 0, -1)]
    tall_valid = list(tall)
    tall_valid[5] += " \u256d\u256e"
    tall_valid[6] += " \u2502\u2570"

    render.chart_with_meta = stub("")
    check("an empty render becomes a refusal, not an empty success",
          present.present(series(9))["status"] == "refused")

    # Mutation: delete the axis check in _verify - this goes red. Full height and
    # carrying marks, so neither the row check nor the marks check can stand in for it.
    render.chart_with_meta = stub("\n".join(f"{v:>4}   \u256d\u256e\u2502" for v in range(13, 0, -1)))
    check("a render missing the axis glyph becomes a refusal",
          present.present(series(9))["status"] == "refused")

    # Mutation: delete the plot-marks check in _verify - this goes red. Full height with
    # an axis on every row, so only the marks check can reject it.
    render.chart_with_meta = stub("\n".join(tall))
    check("an axis with nothing plotted on it becomes a refusal",
          present.present(series(9))["status"] == "refused")

    # Mutation: delete the row check in _verify - this goes red. An overflowing scale
    # collapses every point onto one row; that row has an axis and a flat mark, so the
    # axis and marks checks both pass it.
    render.chart_with_meta = stub("   0  \u253c\u2500\u2500\u2500\u2500\u2500\u2500\u2500")
    check("a chart collapsed onto one line becomes a refusal",
          present.present(series(9))["status"] == "refused")

    render.chart_with_meta = stub("\n".join(tall_valid))
    check("a full-height chart with real plot marks is accepted",
          present.present(series(9))["status"] == "ok")

    # Mutation: delete the _verify_width call in present - this goes red. A valid chart
    # whose header line runs past the width is the one case every form budgets for and
    # this backstop exists to catch when a form gets its sums wrong.
    wide_header = "x" * 90
    render.chart_with_meta = lambda request, name: (
        wide_header + "\n" + "\n".join(tall_valid),
        {"rendered": 1, "omitted": 0, "full_min": 0, "full_max": 1, "kept_first": True,
         "kept_last": True, "kept_missing_positions": [], "unshown_missing": [],
         "series": name, "body": "\n".join(tall_valid)},
    )
    check("a drawn line wider than the width becomes a refusal",
          present.present(series(9))["status"] == "refused")
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

    # --- the review's three cases, end to end through the real CLI ---
    # A range that overflows collapsed the chart onto one line and came back ok.
    proc, out = run_cli({"type": "chart", "width": 48, "units": "abcdefghijklmnopqrstuvwx",
                         "x": [1, 2, 3, 4, 5, 6, 7, 8],
                         "series": {"A": [-1.79769e308, -1e308, -5e307, 0, 5e307, 1e308, 1.5e308, 1.79769e308]}})
    check("values whose range overflows are refused, not drawn as one line",
          out and out["status"] == "refused", repr(out and out.get("block")))

    # A refused table must not leave behind the note that promised it.
    _, out = run_cli({"type": "bars", "width": 48, "x": ["only"],
                      "series": {"A": [-1], "B": [2], "C": [3], "D": [4],
                                 "E": [5], "F": [6], "G": [7], "H": [8]}})
    check("a refusal carries no note claiming something was shown",
          out["status"] == "refused" and not any("is shown" in n or "are shown" in n for n in out["notes"]),
          repr(out["notes"]))
    check("a refusal still says why the requested form was declined",
          any(n.startswith("Bars were requested") for n in out["notes"]), repr(out["notes"]))

    # --- malformed optional metadata is a refusal, not a crash ---
    for bad, label in (
        ({"x": ["a"], "series": {"S": [1]}, "source": "internal"}, "a string source"),
    ):
        proc, out = run_cli(bad)
        check(f"{label} is refused rather than crashing",
              proc.returncode == 0 and out and out["status"] == "refused",
              f"rc={proc.returncode}")

    # --- two row labels stay different end to end, or nothing is shown (P1) ---
    # Mutation: cut the row label to the width that is left instead of refusing - this
    # goes red, because the CLI then returns ok with both rows reading "2026-09…".
    dates = {"title": "t", "x": ["2026-09-01", "2026-09-02"],
             "series": {f"tool-{i}": [-916700.0, -123456.0] for i in range(6)}}
    proc, out = run_cli(dates)
    check("dates that cannot both fit are refused through the CLI",
          proc.returncode == 0 and out and out["status"] == "refused",
          f"rc={proc.returncode} {repr(out and out.get('block'))[:120]}")

    dates["series"] = {f"tool-{i}": [1, 2] for i in range(6)}
    _, out = run_cli(dates)
    row_labels = [line.split("|")[1].strip() for line in out["block"].split("\n")
                  if line.startswith("|")][2:]
    check("the same six series with narrow values still render both dates",
          row_labels == ["2026-09-01", "2026-09-02"], repr(row_labels))

    # --- the reported shape, end to end: six tools, two of them sharing a prefix ---
    # Mutation: return truncated names instead of keys in render._headers - this goes
    # red, because remove-background and remove-logo both come back as "remov…".
    _, out = run_cli({"title": "t", "x": ["a", "b"],
                      "series": {name: [1, 2] for name in
                                 ("remove-background", "studio-lighting", "relight",
                                  "godrays", "detach-foreground", "remove-logo")}})
    header_row = next(line for line in out["block"].split("\n") if line.startswith("|  |"))
    header_cells = [c.strip() for c in header_row.split("|")[2:-1]]
    check("six tool columns come back individually identifiable",
          len(set(header_cells)) == 6, repr(header_cells))
    check("the block names remove-background in full", "remove-background" in out["block"])
    check("the block names remove-logo in full", "remove-logo" in out["block"])

    # --- a renderer refusal reaches the caller as a refusal, not a crash (P1) ---
    # Eight nine-character values cannot fit 72 columns, and cutting one would falsify
    # it. Mutation: remove the `except Refusal` around the render calls in present() -
    # this goes red, because the CLI then dies with a traceback and no JSON at all.
    proc, out = run_cli({"title": "t", "x": ["aa", "bb"],
                         "series": {f"s{i}": [-0.001234, -0.005678] for i in range(8)}})
    check("numbers too wide for the budget are refused through the CLI",
          proc.returncode == 0 and out and out["status"] == "refused",
          f"rc={proc.returncode} {proc.stderr[:120]}")
    check("the width refusal names the series count",
          out and "8" in out.get("message", ""), repr(out and out.get("message")))

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

    # --- the new forms, end to end through the CLI, on the real tools data ---
    weeks = ["Jun 08", "Jun 15", "Jun 22", "Jun 29", "Jul 06", "Jul 13", "Jul 20",
             "Jul 27", "Aug 03", "Aug 10", "Aug 17", "Aug 24", "Aug 31"]
    tools = {
        "remove-background": [0, 0, 0, 0, 7, 6, 1, 5, 3, 5, 1, 2, 13],
        "studio-lighting": [0, 0, 0, 0, 1, 2, 0, 1, 0, 0, 0, 0, 9],
        "relight": [0, 0, 0, 0, 2, 0, 0, 1, 0, 0, 0, 0, 8],
        "godrays": [0, 0, 0, 0, 5, 2, 0, 1, 0, 0, 1, 0, 7],
        "detach-foreground": [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1],
        "remove-logo": [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1],
    }
    _, out = run_cli({"title": "t", "x": weeks, "series": tools})
    check("six tools over thirteen weeks come back as sparkline rows",
          out["form"] == "sparkline", repr(out["form"]))
    spark_rows = {line.split("  ")[0]: line for line in out["block"].split("\n")[1:7]}
    check("each tool has its own row under its full name",
          sorted(spark_rows) == sorted(tools), repr(sorted(spark_rows)))
    # Mutation: per-row scaling in sparkline_with_meta - this goes red end to end.
    check("the single-event tool ends low while the peak of thirteen ends full",
          spark_rows["detach-foreground"].endswith("\u2582   1")
          and spark_rows["remove-background"].endswith("\u2588  13"),
          repr([spark_rows.get("detach-foreground"), spark_rows.get("remove-background")]))

    latest = {name: [values[-1]] for name, values in tools.items()}
    _, out = run_cli({"title": "t", "x": ["Aug 31"], "series": latest})
    check("the latest week alone comes back as bars", out["form"] == "bars", repr(out["form"]))
    bar_lines = out["block"].split("\n")[1:]
    check("the bars lead with the largest tool", bar_lines[0] == "remove-background", repr(bar_lines[:2]))

    # Columns cannot hold six tool names whole, so they give way to bars and say so.
    # Mutation: re-raise DoesNotFit for columns in present - this goes red as a refusal.
    _, out = run_cli({"title": "t", "x": ["Aug 31"], "series": latest, "type": "columns"})
    check("columns that would cut a tool name fall back to bars",
          out["status"] == "ok" and out["form"] == "bars", repr((out["status"], out["form"])))
    check("the fallback says why and what was shown",
          any("would cut" in n and "Bars are shown instead" in n for n in out["notes"]),
          repr(out["notes"]))
    _, out = run_cli({"title": "t", "x": ["now"], "type": "columns",
                      "series": {"slot 0": [82], "slot 1": [14], "slot 2": [17], "slot 3": [10]}})
    check("short labels get the columns that were asked for", out["form"] == "columns", repr(out["form"]))

    # Every form at the narrowest width, through the CLI. The caption is prose and is
    # left out of the measurement; the title here is one character so it cannot matter.
    narrow_cases = {
        "sparkline": {"x": weeks, "series": tools},
        "bars": {"x": ["Aug 31"], "series": latest},
        "columns": {"x": ["now"], "type": "columns",
                    "series": {"slot 0": [82], "slot 1": [14], "slot 2": [17], "slot 3": [10]}},
        "charts": {"x": weeks, "series": {"Applies": [0, 0, 0, 0, 37, 25, 1, 14, 24, 10, 5, 3, 127]}},
        "table": {"x": ["a", "b"], "series": {"s0": [1, 2], "s1": [3, 4]}},
    }
    for expected, payload in narrow_cases.items():
        _, out = run_cli(dict(payload, title="t", width=48))
        widest_line = max(len(line) for line in out["block"].split("\n")[1:]) if out["block"] else -1
        check(f"{expected} at width 48 renders as {expected} inside 48 columns",
              out["form"] == expected and 0 < widest_line <= 48,
              f"form={out['form']} width={widest_line} {out.get('message', '')}")

    # --- verification reads the drawn marks, never the labels beside them ---
    real_spark, real_bars = render.sparkline_with_meta, render.bars_with_meta
    render.sparkline_with_meta = lambda request, names=None: (
        "\u2588 forged \u2582", {"rendered": 1, "omitted": 0, "marks": [], "unshown_missing": {}})
    check("a sparkline with glyphs only in its labels is refused",
          present.present({"title": "t", "x": weeks, "series": tools})["status"] == "refused")
    render.bars_with_meta = lambda request, categories: (
        "\u2588\u2588\u2588 label\n  ", {"rendered": 1, "omitted": 0, "marks": [""]})
    # Mutation: disable the check in _verify_marks - both of these go red.
    check("bars whose only blocks are in a label are refused",
          present.present({"title": "t", "x": ["Aug 31"], "series": latest})["status"] == "refused")
    render.sparkline_with_meta, render.bars_with_meta = real_spark, real_bars

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
