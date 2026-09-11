"""Rendering. Tables, line charts, bars, columns and sparklines, all fed by one number
formatter and all drawn into the caller's stated width.

The chart library is vendored and does three things the caller must work around:
it has no width option, it defaults its height to the data's numeric interval, and
its `format` option is a str.format template rather than a callable.
"""

import math
import os
import string
import sys

import constants
from validate import Refusal, present_values

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "vendor"))
import asciichartpy  # noqa: E402

MISSING_CELL = "—"

# Eighth blocks, left-growing for bars and bottom-growing for columns and sparklines.
LEFT_EIGHTHS = "▏▎▍▌▋▊▉"
LOWER_EIGHTHS = "▁▂▃▄▅▆▇"
FULL_BLOCK = "█"
SPARK_LEVELS = LOWER_EIGHTHS + FULL_BLOCK


class DoesNotFit(Refusal):
    """A form that cannot hold its labels and values whole inside the width. The caller
    falls back to a form that can, and says why; nothing is cut to make this one fit."""


def format_number(value):
    """One formatter. Table cells and chart axis labels both come through here.

    Significant digits, not fixed decimals: two decimals renders 0.001, 0.002 and
    0.003 as three identical cells reading 0.00, which is silent falsification.
    """
    # The None arm is defensive only: validate() turns a gap into NaN, never None, so
    # nothing upstream produces it today. It guards a future non-validated caller.
    if value is None or (isinstance(value, float) and math.isnan(value)):
        return MISSING_CELL
    magnitude = abs(value)
    if magnitude >= constants.ABBREVIATE_ABOVE:
        for limit, suffix in ((1e12, "T"), (1e9, "B"), (1e6, "M"), (1e3, "k")):
            if magnitude >= limit:
                scaled = value / limit
                text = f"{scaled:.{constants.SIGNIFICANT_DIGITS}g}"
                return text + suffix
    if value == int(value) and magnitude < 1e15:
        return str(int(value))
    return f"{value:.{constants.SIGNIFICANT_DIGITS}g}"


def caption(request):
    """The line that travels inside the block, because only the block survives relay."""
    bits = []
    if request.get("title"):
        bits.append(request["title"])
    if request.get("units"):
        bits.append(f"({request['units']})")
    head = " ".join(bits)
    extra = " · ".join(f"{k}: {v}" for k, v in (request.get("source") or {}).items() if v)
    if extra:
        head = f"{head} · {extra}" if head else extra
    return head


def _stride_keep(count, budget, must_keep):
    """Indices to keep: first, last, every k-th, and every position in must_keep.

    Omits points; never derives new ones. A bucket mean is a value nobody measured.
    """
    if count <= budget:
        return list(range(count))
    keep = {0, count - 1}
    # Sample the whole span FIRST. Spending the budget on missing positions before
    # measured ones can retain nothing that plots: a sparse 400-point series then
    # renders an empty chart and a valid request comes back as a refusal.
    room = budget - len(keep)
    if room > 0:
        step = max(2, (count - 2) // room + 1)
        for i in range(1, count - 1, step):
            if len(keep) >= budget:
                break
            keep.add(i)
    # Gaps are retained with whatever room is left, so a reported gap is a visible gap
    # where it fits. What does not fit is reported as unshown rather than implied.
    for index in sorted(must_keep):
        if len(keep) >= budget:
            break
        if 0 <= index < count:
            keep.add(index)
    return sorted(keep)


AXIS_GLYPHS = "┼┤"


def _relabel_axis(body):
    """Put the shared formatter on the axis labels, and re-align the column.

    The library's `format` option is a str.format template, not a callable, so the
    formatter cannot be handed to it. Rewrite the label column after the call instead;
    otherwise the two call sites drift and the axis shows things like 9.167e+04.
    """
    lines = body.split("\n")
    labels, rests = [], []
    for line in lines:
        found = [i for i in (line.find(g) for g in AXIS_GLYPHS) if i != -1]
        cut = min(found, default=-1)
        if cut == -1:
            labels.append(None)
            rests.append(line)
            continue
        try:
            labels.append(format_number(float(line[:cut].strip())))
        except ValueError:
            labels.append(None)
        rests.append(line[cut:])

    width = max((len(l) for l in labels if l is not None), default=0)
    out = []
    for label, rest in zip(labels, rests):
        out.append(rest if label is None else f"{label:>{width}}  {rest}")
    return "\n".join(out)


def _axis_width(low, high):
    """The widest tick label that will be drawn, which is what the gutter costs.

    Measuring only the endpoints understates it: 0 to 1000000 has endpoints "0" and
    "1M" but an intermediate tick of "916.7k", three times wider.
    """
    rows = constants.CHART_ROW_BUDGET
    span = high - low
    return max(
        len(format_number(high - span * step / rows)) for step in range(rows + 1)
    )


def chart_with_meta(request, series_name):
    """Render one series as one chart. Returns the block and what was left out."""
    values = request["series"][series_name]
    missing = set(request["missing"].get(series_name, []))
    present = present_values(values)
    full_min, full_max = min(present), max(present)

    gutter = _axis_width(full_min, full_max) + 5
    point_budget = max(2, request["width"] - gutter)
    keep = _stride_keep(len(values), point_budget, missing)
    plotted = [values[i] for i in keep]

    body = asciichartpy.plot(
        plotted,
        {
            # Never omit height: the library defaults it to the numeric interval, so a
            # series spanning 0 to 100000 would render 100001 lines.
            "height": constants.CHART_ROW_BUDGET,
            "min": full_min,
            "max": full_max,
            # Lossless tick text. The default template is two decimals, and _relabel_axis
            # parses that text back to a float - so a series of 0.001..0.005 would arrive
            # already rounded and every axis row would read 0. Reformatting cannot undo a
            # rounding that happened before it.
            "format": "{:.17g} ",
        },
    )
    body = _relabel_axis(body)

    omitted = len(values) - len(keep)
    span = f"{format_number(full_min)} to {format_number(full_max)}"
    if request.get("units"):
        span += f" {request['units']}"
    header = f"{series_name}  {span}"
    if len(header) > request["width"]:
        header = f"{series_name}\n{span}"
    block = header + "\n" + body

    meta = {
        "series": series_name,
        "rendered": len(keep),
        "omitted": omitted,
        "kept_first": keep[0] == 0,
        "kept_last": keep[-1] == len(values) - 1,
        "full_min": full_min,
        "full_max": full_max,
        # The renderer's own output, kept apart from the header so verification never
        # inspects a string the caller can put glyphs into.
        "body": body,
        "kept_missing_positions": sorted(i for i in keep if i in missing),
        "unshown_missing": sorted(i for i in missing if i not in keep),
    }
    return block, meta


def chart(request, series_name):
    return chart_with_meta(request, series_name)[0]


LEGEND_JOIN = " · "


def _pack(entries, width):
    """Join entries on the separator into lines no wider than `width`, never splitting
    an entry: a legend key wrapped away from its name is the ambiguity the key exists to
    remove. Every entry is shorter than MIN_WIDTH by construction, so none overflows."""
    lines, line = [], ""
    for entry in entries:
        if line and len(line) + len(LEGEND_JOIN) + len(entry) > width:
            lines.append(line)
            line = entry
        else:
            line = entry if not line else line + LEGEND_JOIN + entry
    lines.append(line)
    return lines


def _headers(names, budget, width):
    """Column headers that cannot be read as each other.

    A name that fits is printed whole. Once any name has to be cut, every header
    becomes a letter key and the names move to a legend above the table: at the six to
    nine characters a crowded table leaves, a fragment is not an identifier, and
    remove-background and remove-logo both read as "remov…". Letters, not digits, so a
    header is never mistaken for data.
    """
    if all(len(name) <= budget for name in names):
        return names, []
    letters = string.ascii_uppercase
    keys = [letters[i] if i < len(letters) else f"S{i + 1}" for i in range(len(names))]
    return keys, _pack([f"{key} {name}" for key, name in zip(keys, names)], width)


def table_with_meta(request, series_names=None):
    """Render a Markdown table. Returns the block and what was left out."""
    names = list(series_names if series_names is not None else request["series"])
    x = request["x"]
    missing_by_series = request["missing"]

    must_keep = set()
    for name in names:
        must_keep.update(missing_by_series.get(name, []))
    keep = _stride_keep(len(x), constants.TABLE_ROW_BUDGET, must_keep)
    omitted = len(x) - len(keep)

    # Numbers are formatted first and never cut. One truncator over cells of every kind
    # rendered -916.7k as "-916.…", which is a falsified value, not a narrow one.
    numbers = {
        name: [format_number(request["series"][name][i]) for i in keep] for name in names
    }
    width = request["width"]
    # "| a | b |" costs three characters per gap plus the two ends. The header row
    # carries no numbers, so its names are bounded on their own.
    separators = 3 * len(names) + 4
    headers, legend = _headers(names, max(1, (width - separators) // len(names)), width)
    header = "| " + " | ".join([""] + headers) + " |"
    rule = "| " + " | ".join(["---"] * (len(names) + 1)) + " |"
    rows = []
    for row, i in enumerate(keep):
        cells = [str(x[i])]
        cells.extend(numbers[name][row] for name in names)
        rows.append("| " + " | ".join(cells) + " |")

    # Nothing in a table is cut to make it fit, so the lines are built whole and then
    # measured. Predicting the width from the data rows missed the rule row, whose
    # "---" cells outgrow one-character values at a narrow width. Only rows that survive
    # reduction are measured, so a label the reader never sees cannot refuse the table.
    needed = max(len(line) for line in [header, rule] + rows)
    if needed > width:
        raise DoesNotFit(
            f"{len(names)} series with values and row labels this long needs {needed} "
            f"columns and the width is {width}. Nothing here can be shortened without "
            "cutting a value or a label, so ask for fewer series or a wider width."
        )

    block = "\n".join(legend + [header, rule] + rows)
    return block, {"rendered": len(keep), "omitted": omitted}


def table(request, series_names=None):
    return table_with_meta(request, series_names)[0]


def _rank(categories):
    """Largest first, a missing value last, ties in the caller's order. sorted() is
    stable, which is what keeps the ties where the caller put them."""
    return sorted(categories, key=lambda c: (math.isnan(c[1]), -c[1] if not math.isnan(c[1]) else 0))


def _scale_top(ranked):
    present = [v for _, v in ranked if not math.isnan(v)]
    return max(present, default=0.0)


def bars_with_meta(request, categories):
    """Ranked horizontal bars on one zero-based scale.

    Each label sits on its own line, so no label is ever cut however narrow the width,
    and the bar starts on the next line with the value directly after it.
    """
    width = request["width"]
    ranked = _rank(categories)
    texts = [format_number(v) for _, v in ranked]
    value_width = max(len(t) for t in texts)
    # "  " indent, the bar, one space, the value.
    room = width - 2 - 1 - value_width
    top = _scale_top(ranked)
    eighths_per_unit = room * 8 / top if top > 0 else 0.0

    lines, marks = [], []
    for (label, value), text in zip(ranked, texts):
        lines.append(label)
        if math.isnan(value):
            lines.append(f"  {MISSING_CELL}")
            continue
        full, part = divmod(int(value * eighths_per_unit + 0.5), 8)
        bar = FULL_BLOCK * full + (LEFT_EIGHTHS[part - 1] if part else "")
        marks.append(bar)
        lines.append(f"  {bar} {text}")
    return "\n".join(lines), {"rendered": len(ranked), "omitted": 0, "marks": marks}


def bars(request, categories):
    return bars_with_meta(request, categories)[0]


COLUMN_GAP = 2


def columns_with_meta(request, categories):
    """Ranked vertical columns on one zero-based scale, with the value above each column
    and the label below it. Raises DoesNotFit rather than cut a label to its slot."""
    width = request["width"]
    ranked = _rank(categories)
    count = len(ranked)
    texts = [format_number(v) for _, v in ranked]
    available = (width - COLUMN_GAP * (count - 1)) // count
    needed = max(max(len(label) for label, _ in ranked), max(len(t) for t in texts))
    slot = max(needed, min(available, constants.MAX_COLUMN_WIDTH))
    if slot > available:
        raise DoesNotFit(
            f"{count} columns in {width} characters leave {available} for each, and the "
            f"longest label or value needs {needed}, so the columns would cut it."
        )

    top = _scale_top(ranked)
    steps = constants.COLUMN_ROWS * 8
    heights = [
        None if math.isnan(v) else (int(v / top * steps + 0.5) if top > 0 else 0)
        for _, v in ranked
    ]

    def row(cells):
        return (" " * COLUMN_GAP).join(cells).rstrip()

    lines = [row(t.center(slot) for t in texts)]
    marks = []
    for level in range(constants.COLUMN_ROWS - 1, -1, -1):
        cells = []
        for height in heights:
            filled = 0 if height is None else height - level * 8
            if filled >= 8:
                cell = FULL_BLOCK * slot
            elif filled > 0:
                cell = LOWER_EIGHTHS[filled - 1] * slot
            else:
                cell = " " * slot
            cells.append(cell)
            if cell.strip():
                marks.append(cell)
        lines.append(row(cells))
    # A missing category gets no baseline: absence is not a column of height zero.
    lines.append(row((" " * slot if h is None else "─" * slot) for h in heights))
    lines.append(row(label.center(slot) for label, _ in ranked))
    return "\n".join(lines), {"rendered": count, "omitted": 0, "marks": marks}


def columns(request, categories):
    return columns_with_meta(request, categories)[0]


def sparkline_with_meta(request, names=None):
    """One line per series, every row drawn against ONE shared range.

    Scaling each row to its own maximum draws a series of a single event as the same
    full-height spike as a series of thirteen - the exact dishonesty this skill exists
    to refuse. There is deliberately no per-row option.
    """
    width = request["width"]
    names = list(names if names is not None else request["series"])
    x = request["x"]
    series = request["series"]

    latest = {name: format_number(series[name][-1]) for name in names}
    label_width = max(len(name) for name in names)
    value_width = max(len(t) for t in latest.values())
    room = width - label_width - 2 - 2 - value_width

    must_keep = set()
    for name in names:
        must_keep.update(request["missing"].get(name, []))
    keep = _stride_keep(len(x), room, must_keep)

    # The range comes from every value, not only the kept ones, so a spike the width
    # dropped still sets the scale and the footer states the true range.
    everything = [v for name in names for v in present_values(series[name])]
    low, high = min(everything), max(everything)
    levels = len(SPARK_LEVELS) - 1

    def glyph(value):
        if math.isnan(value):
            return " "
        if high == low:
            return SPARK_LEVELS[0]
        return SPARK_LEVELS[int((value - low) / (high - low) * levels + 0.5)]

    lines, marks = [], []
    for name in names:
        drawn = "".join(glyph(series[name][i]) for i in keep)
        marks.append(drawn)
        lines.append(f"{name:<{label_width}}  {drawn}  {latest[name]:>{value_width}}")

    span = f"{x[0]} to {x[-1]}"
    footer = [span] if len(span) <= width else [f"{x[0]} to", x[-1]]
    footer.append(f"one scale for every row: {format_number(low)} to {format_number(high)}")
    lines.extend(_pack(footer, width))

    unshown = {
        name: sorted(i for i in request["missing"].get(name, []) if i not in set(keep))
        for name in names
    }
    return "\n".join(lines), {
        "rendered": len(keep),
        "omitted": len(x) - len(keep),
        "marks": marks,
        "low": low,
        "high": high,
        "unshown_missing": unshown,
    }


def sparkline(request, names=None):
    return sparkline_with_meta(request, names)[0]
