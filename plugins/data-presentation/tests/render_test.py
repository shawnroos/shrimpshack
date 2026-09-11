#!/usr/bin/env python3
"""U4: the table and chart renderers, the shared number formatter, and the budgets."""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts"))

import constants
import render
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


def widest(block):
    return max((len(line) for line in block.split("\n")), default=0)


def norm(values, x=None, **over):
    n = len(values)
    request = {"title": "T", "x": x or [f"p{i}" for i in range(n)], "series": {"S": values}}
    request.update(over)
    return validate(request)


def main():
    # --- budgets are pinned by literal ---
    check("column budget is pinned at 72", constants.COLUMN_BUDGET == 72, repr(constants.COLUMN_BUDGET))
    check("chart row budget is pinned at 12", constants.CHART_ROW_BUDGET == 12, repr(constants.CHART_ROW_BUDGET))
    check("table row budget is pinned at 40", constants.TABLE_ROW_BUDGET == 40, repr(constants.TABLE_ROW_BUDGET))

    # --- the shared number formatter (R12) ---
    check("small values keep their difference", render.format_number(0.001) != render.format_number(0.002))
    check("0.001 does not collapse to zero", render.format_number(0.001) not in ("0.00", "0"), render.format_number(0.001))
    check("large values are abbreviated", render.format_number(1200000).endswith("M"), render.format_number(1200000))
    check("the abbreviation threshold is pinned at 10000", constants.ABBREVIATE_ABOVE == 10000)
    check("just below the threshold is not abbreviated", not render.format_number(9999).endswith(("k", "M")), render.format_number(9999))
    check("at the threshold it is abbreviated", render.format_number(10000).endswith("k"), render.format_number(10000))

    # --- charts keep real magnitude (R9) ---
    req = norm([42.0, 57.0, 51.0, 74.0, 68.0, 71.0, 80.0, 77.0])
    chart = render.chart(req, "S")
    check("the axis shows the real maximum", "80" in chart, chart.split("\n")[0])
    check("the axis shows the real minimum", "42" in chart, chart.split("\n")[-2])
    check("the chart is labelled with its series name", "S" in chart)

    # --- the chart height is bounded (P0: the renderer defaults it to the numeric range) ---
    big = render.chart(norm([0.0, 25000.0, 50000.0, 75000.0, 100000.0, 60000.0, 30000.0, 10000.0]), "S")
    check(
        "a chart spanning 0 to 100000 stays within the row budget",
        len(big.split("\n")) <= constants.CHART_ROW_BUDGET + 4,
        f"{len(big.split(chr(10)))} lines",
    )

    # The library's format option is a template, not a callable, so the shared formatter
    # has to be applied to the axis after the call. Without this the axis shows raw
    # scientific notation and the label column misaligns - and nothing else here caught it.
    axis = [l.split("┤")[0].split("┼")[0].strip() for l in big.split("\n")[1:] if ("┤" in l or "┼" in l)]
    check("axis labels use the shared formatter, not scientific notation",
          all("e+" not in a and "e-" not in a for a in axis), repr(axis[:4]))
    check("axis labels are abbreviated like table cells",
          any(a.endswith("k") for a in axis), repr(axis[:4]))
    widths = {len(l.split("┤")[0].split("┼")[0]) for l in big.split("\n")[1:] if ("┤" in l or "┼" in l)}
    check("the axis label column is aligned to one width", len(widths) == 1, repr(widths))

    # --- negatives are not clipped ---
    neg = render.chart(norm([-5.0, 3.0, -2.0, 8.0, -7.0, 4.0, 0.0, 6.0]), "S")
    check("a negative minimum appears on the axis", "-7" in neg, neg)

    # --- gaps render as gaps (R6) --- AE3
    gap = render.chart(norm([1.0, 2.0, None, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0]), "S")
    check("a chart still renders with a middle gap", gap.strip() != "")
    edge = render.chart(norm([None, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, None]), "S")
    check("leading and trailing gaps still render", edge.strip() != "")

    # --- width budget and reduction (R8, R12) --- AE5
    long_series = [float(i % 97) for i in range(400)]
    req = norm(long_series)
    block, meta = render.chart_with_meta(req, "S")
    check("a 400-point chart fits the column budget", widest(block) <= constants.COLUMN_BUDGET, f"width={widest(block)}")
    check(
        "the omitted count plus the rendered count equals the original",
        meta["omitted"] + meta["rendered"] == 400,
        repr(meta),
    )
    check("reduction keeps the first point", meta["kept_first"], repr(meta))
    check("reduction keeps the last point", meta["kept_last"], repr(meta))
    check(
        "the full-series range is reported so a dropped spike is not hidden",
        meta["full_min"] == min(long_series) and meta["full_max"] == max(long_series),
        repr(meta),
    )

    spiky = [1.0] * 200
    spiky[137] = 999.0
    _, meta = render.chart_with_meta(norm(spiky), "S")
    check(
        "a spike outside the kept points is still reported in the range",
        meta["full_max"] == 999.0,
        repr(meta),
    )

    # --- reduction retains missing positions so a reported gap is a visible gap (R7) ---
    values = [float(i) for i in range(400)]
    values[201] = None
    req = norm(values)
    _, meta = render.chart_with_meta(req, "S")
    check("a missing position survives reduction", 201 in meta["kept_missing_positions"], repr(meta["kept_missing_positions"]))

    # A gap-heavy long series is where retaining every missing position fights the width
    # promise. Retention used to win and render 138 columns against a promised 72.
    gappy = [None if i % 3 == 0 else float(i % 97) for i in range(400)]
    gappy[0], gappy[-1] = 1.0, 2.0
    block, meta = render.chart_with_meta(norm(gappy), "S")
    check(
        "a gap-heavy 400-point series still fits the column budget",
        widest(block) <= constants.COLUMN_BUDGET,
        f"width={widest(block)}",
    )
    check(
        "gaps that could not be shown are reported rather than dropped silently",
        len(meta["unshown_missing"]) > 0 and meta["unshown_missing"] == sorted(meta["unshown_missing"]),
        repr(meta["unshown_missing"][:5]),
    )

    # A reduced chart that keeps no measured point is not a chart. The gap-heavy test
    # above checks width and unshown gaps only, so this case passed green without it.
    _, gmeta = render.chart_with_meta(norm(gappy), "S")
    kept_real = [i for i in range(400) if i not in set(gmeta["kept_missing_positions"])]
    check("a reduced chart still retains measured points", gmeta["rendered"] > len(gmeta["kept_missing_positions"]),
          f"rendered={gmeta['rendered']} gaps kept={len(gmeta['kept_missing_positions'])}")

    # Axis fidelity below the renderer's own two-decimal default. Its tick text is parsed
    # back to a float, so without a lossless format every one of these rows reads "0".
    tiny = render.chart(norm([0.001, 0.002, 0.003, 0.004, 0.005, 0.004, 0.003, 0.002, 0.001]), "S")
    tiny_axis = [l.split("┤")[0].split("┼")[0].strip() for l in tiny.split("\n")[1:] if ("┤" in l or "┼" in l)]
    check("small values are not flattened to zero on the axis",
          len({a for a in tiny_axis}) > 2 and tiny_axis.count("0") == 0, repr(tiny_axis[:5]))

    # Ranges whose intermediate ticks are wider than either endpoint.
    # 300 points spanning 0 to 0.001 is the shape that overflows when the gutter is sized
    # from the endpoints alone: "0" and "0.001" are narrow, but "0.0008333" is not.
    for low, high, count in ((0.0, 1e6, 9), (0.0, 1e-3, 9), (0.0, 1e-3, 300),
                             (0.0, 2e-6, 300), (1e-6, 3e-6, 60), (-1e9, 1e9, 400)):
        span = [low + (high - low) * i / (count - 1) for i in range(count)]
        wide_block = render.chart(norm(span), "S")
        check(f"a {low} to {high} chart fits the column budget",
              widest(wide_block) <= constants.COLUMN_BUDGET, f"width={widest(wide_block)}")

    # --- no ANSI anywhere (R11) ---
    table = render.table(norm([1.0, 2.0, 3.0]))
    check("no escape character in a chart", "\x1b" not in chart)
    check("no escape character in a table", "\x1b" not in table)

    # --- tables (R6, R12, R17) ---
    t = render.table(norm([1.0, None, 3.0]))
    check("a missing table cell is an explicit marker, not a blank", "—" in t or "-" in t, t)
    check("a missing table cell is not rendered as zero", " 0 " not in t, t)

    t0 = render.table(norm([0.0, 0.0, 0.0]))
    check("a zero renders as 0, never as the missing marker", "0" in t0 and render.MISSING_CELL not in t0, t0)

    # --- a truncated cell cannot open a column the table did not declare (P3) ---
    # Four series, so per_column is narrow enough that a 24-character label actually
    # reaches the cut. With one series it never does and the assertion cannot fail.
    delimited = validate({
        "title": "T",
        "x": ["a|b|c|d|e|f|g" for _ in range(4)],
        "series": {f"n|{i}|long|name": [float(i)] * 4 for i in range(4)},
    })
    block = render.table(delimited)

    def columns(row):
        """Split on the delimiters the renderer left live, skipping escaped ones."""
        cells, cell, i = [], "", 0
        while i < len(row):
            if row[i] == "\\" and i + 1 < len(row):
                cell += row[i:i + 2]
                i += 2
            elif row[i] == "|":
                cells.append(cell)
                cell = ""
                i += 1
            else:
                cell += row[i]
                i += 1
        cells.append(cell)
        return cells

    # Mutation: delete `.replace("|", "\\|")` from _clean. This goes red - the labels
    # arrive carrying live delimiters and every row parses as more columns than declared.
    check(
        "every row of a pipe-laden table parses as five columns",
        all(len(columns(line)) == 7 for line in block.split("\n")),
        repr([len(columns(line)) for line in block.split("\n")]),
    )
    check("the pipe-laden labels were actually cut", "…" in block, block.split("\n")[0])
    check(
        "the pipe-laden table still fits the column budget",
        widest(block) <= constants.COLUMN_BUDGET,
        f"width={widest(block)}",
    )

    wide = render.table(norm([1.0, 2.0, 3.0], x=["x" * 60, "b", "c"]))
    check("a table with long labels fits the column budget", widest(wide) <= constants.COLUMN_BUDGET, f"width={widest(wide)}")

    multi = validate({"title": "T", "x": [f"p{i}" for i in range(5)],
                      "series": {f"series number {i}": [float(i)] * 5 for i in range(6)}})
    check("a six-series table fits the column budget",
          widest(render.table(multi)) <= constants.COLUMN_BUDGET,
          f"width={widest(render.table(multi))}")

    tall_values = [float(i) for i in range(200)]
    block, meta = render.table_with_meta(norm(tall_values))
    check(
        "a 200-row table is reduced to the row budget",
        len(block.split("\n")) <= constants.TABLE_ROW_BUDGET + 4,
        f"{len(block.split(chr(10)))} lines",
    )
    check("the omitted rows are reported", meta["omitted"] > 0, repr(meta))

    # --- the caption is built once and assembled by present, for every form (R19) ---
    req = norm([1.0, 2.0, 3.0], title="Weekly signups", units="users", source={"Period": "Aug"})
    cap = render.caption(req)
    check("the caption carries the title", "Weekly signups" in cap, cap)
    check("the caption carries the units", "users" in cap, cap)
    check("the caption carries the source metadata", "Aug" in cap, cap)

    bare = render.caption(norm([1.0, 2.0, 3.0], title="Bare"))
    check("an absent unit leaves no placeholder", "None" not in bare and "undefined" not in bare, bare)
    check("a table body carries no duplicate caption", "Weekly signups" not in render.table(req), render.table(req))

    print(f"render_test: {passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
