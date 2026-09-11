"""Rendering. Tables and charts, both fed by one number formatter.

The chart library is vendored and does three things the caller must work around:
it has no width option, it defaults its height to the data's numeric interval, and
its `format` option is a str.format template rather than a callable.
"""

import math
import os
import sys

import constants
from validate import present_values, truncate_escaped

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "vendor"))
import asciichartpy  # noqa: E402

MISSING_CELL = "—"


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
    point_budget = max(2, constants.COLUMN_BUDGET - gutter)
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
    header = f"{series_name}  {format_number(full_min)} to {format_number(full_max)}"
    if request.get("units"):
        header += f" {request['units']}"
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

    # Trim labels so the assembled row cannot blow the column budget on its own.
    per_column = max(6, (constants.COLUMN_BUDGET - 4) // (len(names) + 1) - 3)

    def cell(text):
        # The text arrives escaped from validate. Cutting it here must not split an
        # escape pair, so the cut goes through the one escape-aware truncator.
        return truncate_escaped(str(text), per_column)

    head = "| " + " | ".join([cell("")] + [cell(n) for n in names]) + " |"
    rule = "| " + " | ".join(["---"] * (len(names) + 1)) + " |"
    rows = []
    for i in keep:
        cells = [cell(x[i])]
        for name in names:
            cells.append(cell(format_number(request["series"][name][i])))
        rows.append("| " + " | ".join(cells) + " |")

    block = "\n".join([head, rule] + rows)
    return block, {"rendered": len(keep), "omitted": omitted}


def table(request, series_names=None):
    return table_with_meta(request, series_names)[0]
