"""The validation gate. Nothing reaches a renderer without passing through validate().

The gate asserts the shape it requires rather than excluding shapes it knows are bad.
An exclusion list silently accepts the next malformed shape nobody enumerated.
"""

import math
import re

import constants


def present_values(values):
    """The values that are actually there. A gap is held as NaN by this module's
    convention, so every consumer filters the same way through this one helper."""
    return [v for v in values if not math.isnan(v)]


class Refusal(Exception):
    """Input the skill will not render. The message names the specific problem."""


_FENCE = re.compile(r"`{3,}")

FORMS = ("auto", "table", "chart", "bars", "columns", "sparkline")


def truncate_escaped(text, limit):
    """Cut already-escaped text to `limit` characters without splitting an escape.

    The escape has to run BEFORE this cut: escaping after a cut can push the result back
    over the limit, and a cut landing between a backslash and the character it escapes
    strands the backslash. Neither failure is visible in the output, which is why the
    ordering lives in one function rather than at the call site.
    """
    if len(text) <= limit:
        return text
    cut = text[: limit - 1].rstrip()
    if (len(cut) - len(cut.rstrip("\\"))) % 2:
        cut = cut[:-1]
    return cut + "…"


def _clean(text, limit, notes, what):
    """Make caller text safe to place inside a Markdown table and a fenced block."""
    original = "" if text is None else str(text)
    # Default-deny. A blocklist of ASCII control codes left bidi overrides (U+202E)
    # and zero-width characters through, which can make a label read as something
    # other than what it is. isprintable() closes the whole class and keeps the
    # em dash, ellipsis, CJK and emoji the output actually uses.
    safe = "".join(c if c.isprintable() else " " for c in original)
    # Escape the backslash first. Otherwise a caller's own "\\|" becomes "\\\\|", which
    # Markdown reads as a literal backslash followed by a live column delimiter.
    safe = safe.replace("\\", "\\\\").replace("|", "\\|")
    # Collapse any run of three or more backticks in ONE pass. A plain replace is not
    # idempotent: four backticks become "``" + "`", which is three again - a fence.
    safe = _FENCE.sub("``", safe)
    safe = " ".join(safe.split())
    if len(safe) > limit:
        safe = truncate_escaped(safe, limit)
        notes.append(f"{what} was truncated to {limit} characters.")
    return safe


def _to_number(value, series_name, position):
    """Coerce one cell, or refuse. Returns NaN for a declared-missing value."""
    if value is None:
        return float("nan")
    if isinstance(value, bool):
        raise Refusal(
            f"The {series_name} series has a true/false value at position {position + 1}. "
            "The chart needs numbers."
        )
    if isinstance(value, (int, float)):
        number = float(value)
    else:
        text = str(value).strip()
        if text == "":
            return float("nan")
        try:
            number = float(text)
        except ValueError:
            raise Refusal(
                f"The {series_name} series has the value "
                f"'{_clean(text, constants.MAX_LABEL_CHARS, [], 'A value')}' at "
                f"position {position + 1}, which is not a number."
            )
    if not math.isfinite(number):
        # nan/inf pass float() happily and then poison the spread test and the axis.
        raise Refusal(
            f"The {series_name} series has a value at position {position + 1} that is "
            "not a finite number."
        )
    return number


def validate(request):
    """Return a normalized request, or raise Refusal naming the specific problem."""
    if not isinstance(request, dict):
        raise Refusal("The request must be an object with an x axis and at least one series.")

    notes = []

    raw_x = request.get("x")
    if not isinstance(raw_x, list) or len(raw_x) == 0:
        raise Refusal("The chart needs at least one x-axis value.")

    raw_series = request.get("series")
    if not isinstance(raw_series, dict) or len(raw_series) == 0:
        raise Refusal("The chart needs at least one named series of numbers.")

    raw_source = request.get("source") or {}
    if not isinstance(raw_source, dict):
        raise Refusal("source must be an object of name/value pairs.")
    if len(raw_source) > constants.MAX_SOURCE_FIELDS:
        raise Refusal(
            f"source carries {len(raw_source)} fields; at most "
            f"{constants.MAX_SOURCE_FIELDS} fit in a caption."
        )

    if len(raw_series) > constants.MAX_SERIES:
        raise Refusal(
            f"{len(raw_series)} series is more than the {constants.MAX_SERIES} this can show "
            "without the table growing past a readable width."
        )

    x_labels = [_clean(label, constants.MAX_LABEL_CHARS, notes, "An x-axis label") for label in raw_x]
    # Labels that arrive different and leave the same are rows the reader cannot tell
    # apart. Genuinely repeated labels are fine and stay accepted: the comparison is
    # against the distinct labels that came in, not against the row count.
    if len(set(x_labels)) < len({str(label) for label in raw_x}):
        raise Refusal(
            "Two x-axis labels become the same once they are shortened, so two rows "
            f"would be indistinguishable. Keep them under {constants.MAX_LABEL_CHARS} "
            "characters, or put the difference earlier in the label."
        )

    series = {}
    missing = {}
    for raw_name, values in raw_series.items():
        name = _clean(raw_name, constants.MAX_LABEL_CHARS, notes, "A series name")
        if not isinstance(values, list):
            raise Refusal(f"The {name} series must be a list of numbers.")
        if len(values) != len(raw_x):
            raise Refusal(
                f"The {name} series has {len(values)} values, but the x axis has "
                f"{len(raw_x)} labels."
            )
        numbers, gaps = [], []
        for index, value in enumerate(values):
            number = _to_number(value, name, index)
            numbers.append(number)
            if math.isnan(number):
                gaps.append(index)
        if len(gaps) == len(numbers):
            raise Refusal(f"The {name} series has no values to show; every point is missing.")
        series[name] = numbers
        missing[name] = gaps

    if len(series) != len(raw_series):
        raise Refusal("Two series share a name once their labels are cleaned up.")

    # Every value can be finite while the distance between them is not: -1.8e308 and
    # 1.8e308 subtract to infinity, the renderer's scale collapses, and a chart comes
    # back as a single line. The widest range any form draws is across every series.
    everything = [v for values in series.values() for v in present_values(values)]
    if not math.isfinite(max(everything) - min(everything)):
        raise Refusal(
            "The values span a range too large to draw, so no form can show them "
            "honestly. Split them into separate requests or rescale them first."
        )

    width = request.get("width")
    if width is None:
        width = constants.COLUMN_BUDGET
    # bool is an int subclass, so True would otherwise pass as a width of 1.
    if isinstance(width, bool) or not isinstance(width, int):
        raise Refusal("width must be a whole number of columns.")
    if not constants.MIN_WIDTH <= width <= constants.MAX_WIDTH:
        raise Refusal(
            f"width {width} is outside the {constants.MIN_WIDTH} to {constants.MAX_WIDTH} "
            "columns this can render into."
        )

    requested = request.get("type") or request.get("form") or "auto"
    if requested not in FORMS:
        notes.append(
            f"The requested form "
            f"'{_clean(requested, constants.MAX_LABEL_CHARS, [], 'A form name')}' is "
            "not one this version provides; the form was chosen from the data instead."
        )
        requested = "auto"

    return {
        "title": _clean(request.get("title"), constants.MAX_TITLE_CHARS, notes, "The title"),
        "requested_form": requested,
        "width": width,
        "x": x_labels,
        "series": series,
        "missing": missing,
        "units": _clean(request.get("units"), constants.MAX_LABEL_CHARS, notes, "The units"),
        "source": {
            _clean(k, constants.MAX_LABEL_CHARS, notes, "A source field"):
            _clean(v, constants.MAX_LABEL_CHARS, notes, "A source value")
            for k, v in raw_source.items()
        },
        "notes": notes,
    }
