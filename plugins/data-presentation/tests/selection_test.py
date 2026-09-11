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

    # Deliberate reversal: four series used to fall to a squeezed table. Sparkline rows
    # give every series a full-name line on one shared scale instead.
    # Mutation: return as_table in the MAX_STACKED_CHARTS branch - this goes red.
    result = pick({"A": rising(9), "B": rising(9), "C": rising(9), "D": rising(9)})
    check("four series select sparkline rows", result["form"] == "sparkline", result["form"])
    check(
        "the reason names the series count and the shared scale",
        any("4 series" in r and "shared scale" in r for r in result["reasons"]),
        repr(result["reasons"]),
    )
    result = pick({"A": rising(9), "B": rising(9), "C": rising(9)})
    check("three series still select stacked line charts", result["form"] == "charts", result["form"])

    # Every series flat is still a table: sparkline rows of one repeated glyph have no
    # shape to show. Mutation: move the flat check after the sparkline branch - red.
    result = pick({f"F{i}": [float(i)] * 9 for i in range(5)})
    check("five flat series select a table, not sparklines", result["form"] == "table", result["form"])

    # --- snapshot comparisons are ranked bars ---
    check("the bar category cap is pinned at 20", constants.MAX_BAR_CATEGORIES == 20,
          repr(constants.MAX_BAR_CATEGORIES))
    snapshot = {"remove-background": [13.0], "studio-lighting": [9.0], "relight": [8.0],
                "godrays": [7.0], "detach-foreground": [1.0], "remove-logo": [1.0]}
    # Mutation: delete the snapshot branch in choose - this goes red, back to a table.
    result = pick(snapshot, points=1)
    check("one x value across six series selects bars", result["form"] == "bars", result["form"])
    check("the bars carry one pair per series, labelled by series name",
          [label for label, _ in result["categories"]] == list(snapshot), repr(result["categories"]))

    # Auto never picks columns, even where they would fit. The pairs are identical to
    # the bars', and choosing between them on label length would flip the form when one
    # label gained a character.
    result = pick({"a": [3.0], "b": [2.0], "c": [1.0]}, points=1)
    check("three short snapshot labels still select bars, not columns",
          result["form"] == "bars", result["form"])

    # Mutation: delete the negative check in _categories - this goes red.
    result = pick({"gain": [4.0], "loss": [-2.0], "flat": [0.0]}, points=1)
    check("a snapshot with a negative value falls to a table", result["form"] == "table", result["form"])
    check("the reason names the negative category",
          any("loss" in r and "negative" in r for r in result["reasons"]), repr(result["reasons"]))

    # Mutation: delete the all-zero check in _categories - this goes red.
    result = pick({"a": [0.0], "b": [0.0]}, points=1)
    check("an all-zero snapshot falls to a table", result["form"] == "table", result["form"])

    result = pick(snapshot, points=1, form="chart")
    check("a chart request on a snapshot becomes bars", result["form"] == "bars", result["form"])
    check("the reason says the chart was not used and why",
          any("chart was requested" in r and "one x value" in r for r in result["reasons"]),
          repr(result["reasons"]))

    # --- explicit bars and columns ---
    result = pick({"kept": [82.0, 14.0, 17.0, 10.0]}, form="bars")
    check("bars on request draw one series across its x values", result["form"] == "bars", result["form"])
    check("those bars are labelled by x value",
          [label for label, _ in result["categories"]] == ["p0", "p1", "p2", "p3"],
          repr(result["categories"]))
    # Mutation: pass allow_series_over_x=True from the auto path - this goes red, and a
    # nine-point time series is drawn as ranked bars with its order destroyed.
    result = pick({"S": rising(9)})
    check("auto never draws a single series over x as bars", result["form"] == "charts", result["form"])

    result = pick({"kept": [float(i + 1) for i in range(20)]}, form="bars")
    check("twenty categories are still bars", result["form"] == "bars", result["form"])
    # Mutation: delete the category-cap check - this goes red.
    result = pick({"kept": [float(i + 1) for i in range(21)]}, form="bars")
    check("twenty-one categories are not bars", result["form"] != "bars", result["form"])
    check("the reason names the category count and the cap",
          any("21 categories" in r and "20" in r for r in result["reasons"]), repr(result["reasons"]))

    result = pick({"A": rising(9), "B": rising(9)}, form="bars")
    check("bars requested on two series over nine points fall back", result["form"] == "charts", result["form"])
    check("the fallback names the requested form",
          any(r.startswith("Bars were requested") for r in result["reasons"]), repr(result["reasons"]))

    result = pick({"a": [3.0], "b": [2.0]}, points=1, form="columns")
    check("an explicit columns request is honoured", result["form"] == "columns", result["form"])

    # --- explicit sparkline ---
    result = pick({"A": rising(9), "B": rising(9)}, form="sparkline")
    check("an explicit sparkline request on two series is honoured",
          result["form"] == "sparkline", result["form"])
    result = pick({"A": rising(5), "B": rising(5)}, form="sparkline")
    check("a sparkline request on five points falls back to a table", result["form"] == "table", result["form"])
    check("that fallback names the sparkline and the point count",
          any("sparkline was requested" in r and "8" in r for r in result["reasons"]), repr(result["reasons"]))
    result = pick({"A": [2.0] * 9, "B": [3.0] * 9}, form="sparkline")
    check("a sparkline request on flat series falls back to a table", result["form"] == "table", result["form"])

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
