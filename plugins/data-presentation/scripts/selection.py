"""Which form the data earns.

Named `selection` rather than `select`: a module called `select.py` on sys.path shadows
the standard library's, which `selectors` imports, and `subprocess.run(capture_output=True)`
then dies with `module 'select' has no attribute 'select'`. Reproduced, not theoretical.

The rule is fixed thresholds from `constants`, so it is testable. Taste is not.
"""

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
    presents = {name: present_values(values) for name, values in series.items()}
    thin = {n: len(v) for n, v in presents.items() if len(v) < constants.MIN_CHART_POINTS}
    if len(thin) == len(series):
        fewest = min(thin.values())
        return as_table(
            f"A chart needs at least {constants.MIN_CHART_POINTS} plottable points and the "
            f"fullest series has {fewest}, so a table is shown instead"
            + (" of the chart that was requested." if requested == "chart" else ".")
        )

    if len(series) > constants.MAX_STACKED_CHARTS:
        return as_table(
            f"{len(series)} series is more than the {constants.MAX_STACKED_CHARTS} separate "
            "charts worth stacking, so a table compares them instead"
            + (" of the chart that was requested." if requested == "chart" else ".")
        )

    # Flatness is judged per series, so one flat series does not demote the others.
    # Both tests are per series: a thin or flat series falls to the table beside the
    # charts rather than demoting every other series with it.
    varying = [
        name for name, values in presents.items()
        if not _is_flat(values) and name not in thin
    ]
    flat = [name for name in series if name not in varying]

    if not varying:
        return as_table(
            "Every series has the same value at every point, so there is no variation to "
            "plot and a table shows the value directly"
            + (", rather than the chart that was requested." if requested == "chart" else ".")
        )

    if flat:
        reasons.append(
            "These series have too few points or no variation to plot and are shown in a "
            "table instead: "
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
