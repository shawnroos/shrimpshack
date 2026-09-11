#!/usr/bin/env python3
"""Bars, columns, sparkline rows, and the caller's width, at the renderer."""

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


# Six tools over thirteen weeks of real usage. Two of them are a single event each,
# which is the shape per-row scaling draws as a full-height spike.
WEEKS = ["Jun 08", "Jun 15", "Jun 22", "Jun 29", "Jul 06", "Jul 13", "Jul 20",
         "Jul 27", "Aug 03", "Aug 10", "Aug 17", "Aug 24", "Aug 31"]
TOOLS = {
    "remove-background": [0, 0, 0, 0, 7, 6, 1, 5, 3, 5, 1, 2, 13],
    "studio-lighting": [0, 0, 0, 0, 1, 2, 0, 1, 0, 0, 0, 0, 9],
    "relight": [0, 0, 0, 0, 2, 0, 0, 1, 0, 0, 0, 0, 8],
    "godrays": [0, 0, 0, 0, 5, 2, 0, 1, 0, 0, 1, 0, 7],
    "detach-foreground": [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1],
    "remove-logo": [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1],
}


def tools(width=None, **series_over):
    request = {"title": "t", "x": WEEKS, "series": dict(TOOLS, **series_over)}
    if width is not None:
        request["width"] = width
    return validate(request)


def level(glyph):
    return render.SPARK_LEVELS.index(glyph)


def main():
    check("the column width cap is pinned at 12", constants.MAX_COLUMN_WIDTH == 12,
          repr(constants.MAX_COLUMN_WIDTH))
    check("the column height is pinned at 8 rows", constants.COLUMN_ROWS == 8,
          repr(constants.COLUMN_ROWS))

    # --- sparkline rows share ONE scale ---
    block, meta = render.sparkline_with_meta(tools())
    marks = dict(zip(TOOLS, meta["marks"]))
    # The assertion that matters most. Each row carrying glyphs is not enough: the
    # per-row version has glyphs too. What must hold is that a single event is drawn
    # far below a series whose peak is thirteen.
    # Mutation: compute low and high per row inside the loop - this goes red, because
    # detach-foreground's lone 1 is then its own maximum and draws as a full block.
    check("a single event never reaches the height of a peak of thirteen",
          max(level(c) for c in marks["detach-foreground"]) == 1
          and max(level(c) for c in marks["remove-background"]) == 7,
          f"{marks['detach-foreground']!r} vs {marks['remove-background']!r}")
    check("the latest week draws 1 and 13 at different heights",
          marks["detach-foreground"][-1] != marks["remove-background"][-1],
          f"{marks['detach-foreground'][-1]!r} {marks['remove-background'][-1]!r}")
    # The same scale also places the middle series in order of their peaks.
    check("nine draws above one on the shared scale",
          level(marks["studio-lighting"][-1]) > level(marks["remove-logo"][-1]),
          f"{marks['studio-lighting']!r} {marks['remove-logo']!r}")

    rows = block.split("\n")[:6]
    check("every row starts with its full series name",
          all(row.startswith(name + "  ") for row, name in zip(rows, TOOLS)), repr(rows))
    check("the latest value closes each row",
          rows[0].endswith("  13") and rows[4].endswith("   1"), repr([rows[0], rows[4]]))
    # Mutation: drop the footer - this goes red. A reader cannot tell the rows share a
    # scale unless the block says so.
    check("the block states the shared scale", "one scale for every row: 0 to 13" in block, block)
    check("the block states the x range", "Jun 08 to Aug 31" in block, block)

    # A gap is a space, never the lowest glyph: a zero and a gap must not look alike.
    # Mutation: have glyph() return SPARK_LEVELS[0] for NaN - this goes red.
    gapped = list(TOOLS["godrays"])
    gapped[5] = None
    _, gmeta = render.sparkline_with_meta(tools(godrays=gapped))
    godrays_marks = gmeta["marks"][list(TOOLS).index("godrays")]
    check("a missing week is drawn as a space", godrays_marks[5] == " ", repr(godrays_marks))
    check("a zero week beside it is still drawn", godrays_marks[6] == "▁", repr(godrays_marks))

    # A spike the width dropped still sets the scale. The stride keeps index 1 and then
    # every seventh point, so index 2 is not drawn; the footer must still say 999.
    # Mutation: take low and high from the kept points only - this goes red.
    spiky = [float(i % 5) for i in range(400)]
    spiky[2] = 999.0
    long_request = validate({"title": "t", "x": [f"p{i}" for i in range(400)],
                             "series": {"spiky": spiky, "calm": [1.0] * 400,
                                        "other": [2.0] * 400, "more": [3.0] * 400}})
    sblock, smeta = render.sparkline_with_meta(long_request)
    check("the dropped spike was really dropped", "█" not in "".join(smeta["marks"]), repr(smeta["marks"][0][:20]))
    check("the scale still spans the dropped spike", "0 to 999" in sblock, sblock.split("\n")[-1])
    check("a 400-point sparkline fits the default width", widest(sblock) <= 72, f"width={widest(sblock)}")
    check("the omitted points are counted", smeta["omitted"] > 0, repr(smeta["omitted"]))

    # Width is read, not assumed. Mutation: use COLUMN_BUDGET for the room - red.
    _, wide_meta = render.sparkline_with_meta(validate(dict(
        {"title": "t", "x": [f"p{i}" for i in range(400)], "series": {"spiky": spiky, "calm": [1.0] * 400}},
        width=120)))
    _, base_meta = render.sparkline_with_meta(validate(
        {"title": "t", "x": [f"p{i}" for i in range(400)], "series": {"spiky": spiky, "calm": [1.0] * 400}}))
    check("a wider width keeps more points", wide_meta["rendered"] > base_meta["rendered"],
          f"{wide_meta['rendered']} vs {base_meta['rendered']}")
    narrow = render.sparkline(tools(width=48))
    check("the tools sparkline fits width 48", widest(narrow) <= 48, f"width={widest(narrow)}")

    # --- bars: ranked, zero-based, one scale, labels whole ---
    shuffled = [("remove-logo", 1.0), ("godrays", 7.0), ("remove-background", 13.0),
                ("detach-foreground", 1.0), ("relight", 8.0), ("studio-lighting", 9.0)]
    bars_block, bars_meta = render.bars_with_meta(tools(), shuffled)
    lines = bars_block.split("\n")
    # Mutation: drop the sort in _rank - this goes red. The input is deliberately out of
    # order; the tools data arrives already ranked and could not catch it.
    check("bars are ranked largest first, ties in the caller's order",
          lines[0::2] == ["remove-background", "studio-lighting", "relight", "godrays",
                          "remove-logo", "detach-foreground"], repr(lines[0::2]))
    # Mutation: scale each bar to its own value - every bar becomes 67 blocks, red.
    # Mutation: scale from the smallest value instead of zero - the 1s vanish, red.
    check("the largest bar fills the room left by the value", bars_meta["marks"][0] == "█" * 67,
          repr(bars_meta["marks"][0]))
    check("a 1 against 13 is drawn at a thirteenth of that length",
          bars_meta["marks"][4] == "█████▏", repr(bars_meta["marks"][4]))
    check("each bar ends with its own value",
          lines[1].endswith(" 13") and lines[9].endswith(" 1"), repr([lines[1], lines[9]]))
    # Mutation: size the bar from COLUMN_BUDGET - the width-48 check goes red.
    check("the top bar line is exactly the default width", len(lines[1]) == 72, f"len={len(lines[1])}")
    narrow_bars = render.bars(tools(width=48), shuffled).split("\n")
    check("the top bar line is exactly width 48 when asked", len(narrow_bars[1]) == 48,
          f"len={len(narrow_bars[1])}")
    check("at width 48 every label is still printed whole and distinct",
          sorted(narrow_bars[0::2]) == sorted(TOOLS), repr(narrow_bars[0::2]))

    with_gap = render.bars(tools(), [("a", 3.0), ("b", float("nan")), ("c", 1.0)]).split("\n")
    check("a missing value ranks last and draws no bar",
          with_gap[4:] == ["b", "  —"], repr(with_gap))

    # --- columns ---
    slots = [("slot 0", 82.0), ("slot 1", 14.0), ("slot 2", 17.0), ("slot 3", 10.0)]
    col_block = render.columns(tools(), slots)
    col_lines = col_block.split("\n")
    # Four slots in 72 leave 16 each; the cap holds them at 12.
    # Mutation: drop the MAX_COLUMN_WIDTH cap - the baseline widens to 16, red.
    check("a column is capped at 12 wide", col_lines[-2].split("  ")[0] == "─" * 12, repr(col_lines[-2]))
    check("columns are ranked largest first",
          col_lines[-1].split() == ["slot", "0", "slot", "2", "slot", "1", "slot", "3"], repr(col_lines[-1]))
    plot = col_lines[1:1 + constants.COLUMN_ROWS]
    tallest = sum(1 for row in plot if row[:12] == "█" * 12)
    smallest = sum(1 for row in plot if len(row) >= 54 and row[42:54].strip())
    check("the largest column fills all eight rows", tallest == 8, repr(plot))
    check("10 against 82 stands one row high", smallest == 1, repr(plot))
    check("values sit above their columns", col_lines[0].split() == ["82", "17", "14", "10"], repr(col_lines[0]))
    check("columns at width 48 fit", widest(render.columns(tools(width=48), slots)) <= 48)

    # Mutation: delete the slot > available check - this goes red, and six tool names
    # are drawn into ten-character slots.
    try:
        render.columns(tools(), [(name, float(v[-1])) for name, v in TOOLS.items()])
        raised = False
    except render.DoesNotFit:
        raised = True
    check("six tool names that cannot fit their columns raise DoesNotFit", raised)

    missing_col = render.columns(tools(), [("a", 4.0), ("b", float("nan"))]).split("\n")
    check("a missing column has no baseline", missing_col[-2].rstrip() == "─" * 12, repr(missing_col[-2]))

    # --- width reaches the forms that existed before it ---
    long_chart = validate({"title": "t", "x": [f"p{i}" for i in range(400)],
                           "series": {"S": [float(i % 97) for i in range(400)]}})
    _, at_72 = render.chart_with_meta(long_chart, "S")
    _, at_120 = render.chart_with_meta(dict(long_chart, width=120), "S")
    # Mutation: use COLUMN_BUDGET for the chart's point budget - this goes red.
    check("a wider width gives a chart more points", at_120["rendered"] > at_72["rendered"],
          f"{at_120['rendered']} vs {at_72['rendered']}")

    # Mutation: drop the header wrap - the 48 check goes red at 69 characters.
    long_name = validate({"title": "t", "x": [f"p{i}" for i in range(9)],
                          "series": {"n" * 24: [-916700.0 + i for i in range(9)]},
                          "units": "u" * 24, "width": 48})
    narrow_chart = render.chart(long_name, "n" * 24)
    check("a chart with a long name and units fits width 48", widest(narrow_chart) <= 48,
          f"width={widest(narrow_chart)}")

    dates = {"title": "t", "x": ["2026-09-01", "2026-09-02"],
             "series": {f"tool-{i}": [-916700.0, -123456.0] for i in range(6)}}
    # Refused at 72 by the table test; at 80 the same table fits whole.
    # Mutation: compare against COLUMN_BUDGET in table_with_meta - this goes red.
    wide_table = render.table(validate(dict(dates, width=80)))
    check("a table that needs 74 renders at width 80",
          "2026-09-01" in wide_table and "2026-09-02" in wide_table, wide_table)

    # The legend packs to the stated width, not the default.
    # Mutation: pack the legend to COLUMN_BUDGET - three entries share a 54-character
    # line and this goes red.
    legend_table = render.table(validate({"title": "t", "x": ["a", "b"], "width": 48,
                                          "series": {f"remove-thing-{i}": [1.0, 2.0] for i in range(6)}}))
    check("a legend at width 48 stays inside 48", widest(legend_table) <= 48, legend_table)
    check("that table really is keyed", legend_table.startswith("A remove-thing-0"), legend_table)

    # Eight one-character values: the data rows need 37 columns, but the rule row's
    # "---" cells need 55. A width predicted from the data rows passed this table at 48
    # and rendered it at 55. Mutation: measure only the data rows - this goes red.
    try:
        overflow = render.table(validate({"title": "t", "x": ["a", "b"], "width": 48,
                                          "series": {f"s{i}": [1.0, 2.0] for i in range(8)}}))
        rule_refused = None
    except render.DoesNotFit as exc:
        overflow, rule_refused = None, str(exc)
    check("a table whose rule row outgrows width 48 is refused", rule_refused is not None,
          repr(overflow and widest(overflow)))
    check("that refusal names the 55 columns the table needed",
          rule_refused is not None and "55" in rule_refused, repr(rule_refused))


    # --- a value above zero is never drawn identically to zero ---
    # Mutation: drop the `if value > 0: eighths = max(1, eighths)` floor in bars - this
    # goes red. 0.01 beside 13 rounded to no bar at all, the same as the zero beside it.
    snap = validate({"title": "t", "x": ["now"], "series": {"big": [13], "tiny": [0.01], "zero": [0]}})
    _, bmeta = render.bars_with_meta(snap, [("big", 13.0), ("tiny", 0.01), ("zero", 0.0)])
    bar_block = render.bars(snap, [("big", 13.0), ("tiny", 0.01), ("zero", 0.0)])
    tiny_line = bar_block.split("\n")[bar_block.split("\n").index("tiny") + 1]
    zero_line = bar_block.split("\n")[bar_block.split("\n").index("zero") + 1]
    check("a tiny bar draws a visible mark", any(g in tiny_line for g in render.FULL_BLOCK + render.LEFT_EIGHTHS),
          repr(tiny_line))
    check("a tiny bar does not draw the same as zero", tiny_line.split()[0] != zero_line.split()[0],
          f"tiny={tiny_line!r} zero={zero_line!r}")

    # Mutation: drop the `1 if v > 0` floor in columns - this goes red. 1 beside 10000
    # rounded to height 0 and left the same empty slot as the zero.
    col = validate({"title": "t", "width": 48, "x": ["only"],
                    "series": {"large": [10000], "small": [1], "zero": [0]}})
    col_block = render.columns(col, [("large", 10000.0), ("small", 1.0), ("zero", 0.0)])
    col_rows = col_block.split("\n")[1:-2]          # drawn rows: no value line, baseline, labels
    slot = (48 - 2 * 2) // 3
    def column(i):
        return "".join(r[i * (slot + 2): i * (slot + 2) + slot] for r in col_rows if len(r) > i * (slot + 2))
    check("a small column draws a visible mark", column(1).strip() != "", repr(column(1)))
    check("zero still draws no column", column(2).strip() == "", repr(column(2)))

    # Mutation: drop the `if value > low: level = max(1, level)` floor in the sparkline -
    # this goes red. 1 and 9 against 1000 drew the same bottom glyph as 0, so three
    # different series read as one flat line.
    spark = validate({"title": "t", "x": WEEKS[:9],
                      "series": {"big": [0, 1000, 0, 500, 0, 1000, 0, 0, 1000],
                                 "one": [1] * 9, "zero": [0] * 9, "nine": [9] * 9}})
    _, smeta = render.sparkline_with_meta(spark, ["big", "one", "zero", "nine"])
    drawn = dict(zip(["big", "one", "zero", "nine"], smeta["marks"]))
    check("a sparkline row of ones does not draw the same as a row of zeros",
          drawn["one"] != drawn["zero"], f"one={drawn['one']!r} zero={drawn['zero']!r}")
    check("a sparkline row of nines does not draw the same as a row of zeros",
          drawn["nine"] != drawn["zero"], f"nine={drawn['nine']!r} zero={drawn['zero']!r}")
    check("the shared scale still draws zero at the floor", set(drawn["zero"]) == {render.SPARK_LEVELS[0]},
          repr(drawn["zero"]))

    print(f"forms_test: {passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
