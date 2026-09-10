"""Which form the data earns.

Named `selection` rather than `select`: a module called `select.py` on sys.path shadows
the standard library's, which `selectors` imports, and `subprocess.run(capture_output=True)`
then dies with `module 'select' has no attribute 'select'`. Reproduced, not theoretical.

The rule is fixed thresholds from `constants`, so it is testable. Taste is not.
"""

import math

import constants


def _present(values):
    return [v for v in values if not math.isnan(v)]


def _is_flat(values):
    """Flat means the renderer would draw a straight line: max == min.

    Not a percentage floor. The renderer scales to the observed range, so a series
    varying half a percent still draws at full height with visible shape. A floor
    would refuse conversion rate, latency, and uptime, which people genuinely chart.
    """
    present = _present(values)
    if not present:
        return True
    return max(present) == min(present)


def choose(request):
    """Return the chosen form, which series go where, and why.

    Keys: `form` is `table` or `charts`; `chart_series` and `table_series` name the
    series in each; `reasons` explains anything the caller did not get.
    """
    series = request["series"]
    requested = request.get("requested_form", "auto")
    reasons = []

    def as_table(reason):
        if reason:
            reasons.append(reason)
        return {
            "form": "table",
            "chart_series": [],
            "table_series": list(series),
            "reasons": reasons,
        }

    if requested == "table":
        return as_table(None)

    # Count what would actually plot. A gap is not a point.
    plottable = min(len(_present(values)) for values in series.values())
    if plottable < constants.MIN_CHART_POINTS:
        return as_table(
            f"A chart needs at least {constants.MIN_CHART_POINTS} plottable points and this "
            f"has {plottable}, so a table is shown instead"
            + (" of the chart that was requested." if requested == "chart" else ".")
        )

    if len(series) > constants.MAX_STACKED_CHARTS:
        return as_table(
            f"{len(series)} series is more than the {constants.MAX_STACKED_CHARTS} separate "
            "charts worth stacking, so a table compares them instead"
            + (" of the chart that was requested." if requested == "chart" else ".")
        )

    # Flatness is judged per series, so one flat series does not demote the others.
    varying = [name for name, values in series.items() if not _is_flat(values)]
    flat = [name for name in series if name not in varying]

    if not varying:
        return as_table(
            "Every series has the same value at every point, so there is no variation to "
            "plot and a table shows it exactly"
            + (", rather than the chart that was requested." if requested == "chart" else ".")
        )

    if flat:
        reasons.append(
            "These series have no variation to plot and are shown in a table instead: "
            + ", ".join(flat)
            + "."
        )

    # One series per chart. The renderer reads its glyph set once, outside the per-series
    # loop, and varies only colour per series - and colour is unusable inside a fence.
    return {
        "form": "charts",
        "chart_series": varying,
        "table_series": flat,
        "reasons": reasons,
    }
