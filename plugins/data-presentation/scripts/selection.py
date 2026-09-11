"""Which form the data earns.

Named `selection` rather than `select`: a module called `select.py` on sys.path shadows
the standard library's, which `selectors` imports, and `subprocess.run(capture_output=True)`
then dies with `module 'select' has no attribute 'select'`. Reproduced, not theoretical.

The rule is fixed thresholds from `constants`, so it is testable. Taste is not.
"""

import math

import constants
from validate import present_values


def _is_flat(present):
    """Flat means the renderer would draw a straight line: max == min.

    Not a percentage floor. The renderer scales to the observed range, so a series
    varying half a percent still draws at full height with visible shape. A floor
    would refuse conversion rate, latency, and uptime, which people genuinely chart.
    """
    if not present:
        return True
    return max(present) == min(present)


def _categories(request, allow_series_over_x):
    """The (label, value) pairs bars and columns would draw, or the reason they cannot.

    Two shapes carry one value per category: a snapshot, one x value across several
    series, and one series across several x values. Auto only ever reads the snapshot;
    a single series over x is as likely to be a time series, so it is bars only on
    request.
    """
    series, x = request["series"], request["x"]
    if len(x) == 1 and len(series) >= 2:
        pairs = [(name, values[0]) for name, values in series.items()]
    elif allow_series_over_x and len(series) == 1 and len(x) >= 2:
        values = next(iter(series.values()))
        pairs = list(zip(x, values))
    else:
        return None, (
            f"bars need one value per category, and this data has {len(series)} series "
            f"over {len(x)} x values"
        )
    if len(pairs) > constants.MAX_BAR_CATEGORIES:
        return None, (
            f"there are {len(pairs)} categories and a ranked list stays readable to "
            f"{constants.MAX_BAR_CATEGORIES}"
        )
    negative = next((label for label, v in pairs if not math.isnan(v) and v < 0), None)
    if negative is not None:
        return None, f"bars are drawn from zero and {negative} is negative"
    if not any(not math.isnan(v) and v > 0 for _, v in pairs):
        return None, "every category is zero, so there is nothing to draw"
    return pairs, None


def choose(request):
    """Return the chosen form, which series go where, and why.

    Keys: `form` is `table`, `charts`, `bars`, `columns` or `sparkline`; `chart_series`
    and `table_series` name the series in each; `categories` carries the pairs bars and
    columns draw; `reasons` explains anything the caller did not get.
    """
    series = request["series"]
    requested = request.get("requested_form", "auto")
    reasons = []

    def decision(form, **parts):
        return {
            "form": form,
            "chart_series": parts.get("chart_series", []),
            "table_series": parts.get("table_series", []),
            "categories": parts.get("categories", []),
            "reasons": reasons,
        }

    def as_table(reason):
        if reason:
            reasons.append(reason)
        return decision("table", table_series=list(series))

    if requested == "table":
        return as_table(None)

    if requested in ("bars", "columns"):
        pairs, why_not = _categories(request, allow_series_over_x=True)
        if pairs:
            return decision(requested, categories=pairs)
        reasons.append(f"{requested.capitalize()} were requested, but {why_not}; the form was chosen from the data instead.")
        requested = "auto"

    # Count what would actually plot. A gap is not a point.
    presents = {name: present_values(values) for name, values in series.items()}
    thin = {n: len(v) for n, v in presents.items() if len(v) < constants.MIN_CHART_POINTS}
    varying = [
        name for name, values in presents.items()
        if not _is_flat(values) and name not in thin
    ]

    if requested == "sparkline":
        if len(thin) == len(series):
            reasons.append(
                f"A sparkline was requested, but it needs at least "
                f"{constants.MIN_CHART_POINTS} plottable points and the fullest series has "
                f"{min(thin.values())}; the form was chosen from the data instead."
            )
        elif not varying:
            reasons.append(
                "A sparkline was requested, but every series holds one value throughout, "
                "so there is no shape to draw; the form was chosen from the data instead."
            )
        else:
            return decision("sparkline", table_series=list(series))
        requested = "auto"

    # A snapshot is a category comparison whatever was asked for, so it is ranked bars.
    # Auto never picks columns: they show the same pairs as bars, and choosing between
    # them on label length would flip the form when a label gains one character.
    pairs, why_not = _categories(request, allow_series_over_x=False)
    if pairs:
        if requested == "chart":
            reasons.append(
                "A chart was requested, but there is one x value, so the series are "
                "compared as ranked bars instead."
            )
        return decision("bars", categories=pairs)
    snapshot_blocked = len(request["x"]) == 1 and len(series) >= 2

    if len(thin) == len(series):
        if snapshot_blocked:
            return as_table(f"There is one x value, but {why_not}, so a table is shown.")
        fewest = min(thin.values())
        return as_table(
            f"A chart needs at least {constants.MIN_CHART_POINTS} plottable points and the "
            f"fullest series has {fewest}, so a table is shown instead"
            + (" of the chart that was requested." if requested == "chart" else ".")
        )

    if not varying:
        return as_table(
            "Every series has the same value at every point, so there is no variation to "
            "plot and a table shows the value directly"
            + (", rather than the chart that was requested." if requested == "chart" else ".")
        )

    if len(series) > constants.MAX_STACKED_CHARTS:
        reasons.append(
            f"{len(series)} series is more than the {constants.MAX_STACKED_CHARTS} separate "
            "charts worth stacking, so each is drawn as a sparkline row on one shared scale"
            + (" instead of the chart that was requested." if requested == "chart" else ".")
        )
        return decision("sparkline", table_series=list(series))

    # Flatness and thinness are judged per series, so one flat or thin series falls to
    # the table beside the charts rather than demoting every other series with it.
    flat = [name for name in series if name not in varying]
    if flat:
        reasons.append(
            "These series have too few points or no variation to plot and are shown in a "
            "table instead: "
            + ", ".join(flat)
            + "."
        )

    # One series per chart. The renderer reads its glyph set once, outside the per-series
    # loop, and varies only colour per series - and colour is unusable inside a fence.
    return decision("charts", chart_series=varying, table_series=flat)
