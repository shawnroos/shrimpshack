#!/usr/bin/env python3
"""U3: the presentation selection rule. Fixed thresholds, not taste."""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts"))

import constants
from selection import choose
from validate import validate

passed = failed = 0


def check(name, condition, detail=""):
    global passed, failed
    if condition:
        passed += 1
        print(f"  ok   - {name}")
    else:
        failed += 1
        print(f"  FAIL - {name}{(': ' + detail) if detail else ''}", file=sys.stderr)


def pick(series, points=None, form="auto"):
    """Validate then choose, so selection only ever sees normalized input."""
    n = points if points is not None else len(next(iter(series.values())))
    request = {
        "title": "T",
        "x": [f"p{i}" for i in range(n)],
        "series": series,
        "type": form,
    }
    return choose(validate(request))


def rising(n, start=1.0, step=1.0):
    return [start + step * i for i in range(n)]


def main():
    # --- the thresholds are pinned by literal, so moving one turns these red ---
    check("minimum chart points is pinned at 8", constants.MIN_CHART_POINTS == 8, repr(constants.MIN_CHART_POINTS))
    check("maximum stacked charts is pinned at 3", constants.MAX_STACKED_CHARTS == 3)

    # --- point count (R1, R2) ---
    result = pick({"S": rising(7)}, form="chart")
    check("seven points select a table even when a chart was asked for", result["form"] == "table", result["form"])
    check(
        "the reason names the point count",
        any("point" in r.lower() for r in result["reasons"]),
        repr(result["reasons"]),
    )

    result = pick({"S": rising(8)})
    check("eight varying points select a chart", result["form"] == "charts", result["form"])

    # --- flatness is max == min, not a percentage floor (AE1) ---
    result = pick({"S": [7.0] * 9}, form="chart")
    check("an identical-valued series selects a table", result["form"] == "table", result["form"])
    check(
        "the reason names the absent variation",
        any("variation" in r.lower() or "same" in r.lower() for r in result["reasons"]),
        repr(result["reasons"]),
    )

    values = [7.0] * 9
    values[4] = 7.5
    result = pick({"S": values})
    check("changing one value makes the same series chartable", result["form"] == "charts", result["form"])

    # The decision this rule turns on: a half-percent range is NOT flat. The renderer
    # scales to the observed range, so it draws at full height with visible shape.
    result = pick({"S": [100.0, 100.1, 100.4, 100.2, 100.5, 100.3, 100.45, 100.15, 100.05]})
    check("a half-percent range still selects a chart", result["form"] == "charts", result["form"])

    # --- shapes that break a ratio-based flatness test ---
    result = pick({"S": [-5.0, -2.0, 0.0, 3.0, 5.0, 2.0, -1.0, 4.0]})
    check("a series crossing zero selects a chart", result["form"] == "charts", result["form"])

    result = pick({"S": [-102.0, -101.0, -100.0, -103.0, -99.0, -101.5, -100.5, -102.5]})
    check("an all-negative series selects a chart", result["form"] == "charts", result["form"])

    result = pick({"S": [0.0] * 9})
    check("an all-zero series selects a table", result["form"] == "table", result["form"])

    # --- one series per chart (R10), several become stacked charts --- AE2
    result = pick({"A": rising(9), "B": rising(9, start=100.0)})
    check("two series select charts", result["form"] == "charts", result["form"])
    check("two series produce two charts", len(result["chart_series"]) == 2, repr(result["chart_series"]))
    # isinstance(str) was tautological - it passed whatever the rule did. Tie the
    # charted set to the actual input series instead.
    check(
        "each charted series appears exactly once and is one of the inputs",
        sorted(result["chart_series"]) == ["A", "B"]
        and len(result["chart_series"]) == len(set(result["chart_series"])),
        repr(result["chart_series"]),
    )

    result = pick({"A": rising(9), "B": rising(9), "C": rising(9), "D": rising(9)})
    check("four series select a table", result["form"] == "table", result["form"])
    check(
        "the reason names the series count",
        any("series" in r.lower() for r in result["reasons"]),
        repr(result["reasons"]),
    )

    # --- flatness is per series, so one flat series does not demote the rest ---
    result = pick({"Varies": rising(9), "Flat": [3.0] * 9})
    check("a mixed set still charts the varying series", result["form"] == "charts", result["form"])
    check("only the varying series is charted", result["chart_series"] == ["Varies"], repr(result["chart_series"]))
    check("the flat series is kept in a table", result["table_series"] == ["Flat"], repr(result["table_series"]))
    check(
        "the reason names the demoted series",
        any("Flat" in r for r in result["reasons"]),
        repr(result["reasons"]),
    )

    # --- explicit request (R3) ---
    result = pick({"S": rising(9)}, form="table")
    check("an explicit table request is honoured", result["form"] == "table", result["form"])

    result = pick({"S": rising(7)}, form="chart")
    check(
        "an overridden request names both the requested and the used form",
        any("chart" in r.lower() and "table" in r.lower() for r in result["reasons"]),
        repr(result["reasons"]),
    )

    # --- the point count is of plottable points, not of gaps ---
    request = {
        "title": "T",
        "x": [f"p{i}" for i in range(9)],
        "series": {"S": [1.0, None, None, None, 5.0, None, 7.0, None, 9.0]},
    }
    result = choose(validate(request))
    check(
        "a nine-point series with five gaps has too few plottable points for a chart",
        result["form"] == "table",
        f"{result['form']} {result['reasons']}",
    )

    print(f"selection_test: {passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
