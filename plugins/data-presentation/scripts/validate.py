"""The validation gate. Nothing reaches a renderer without passing through validate().

The gate asserts the shape it requires rather than excluding shapes it knows are bad.
An exclusion list silently accepts the next malformed shape nobody enumerated.
"""

import math
import re

import constants


class Refusal(Exception):
    """Input the skill will not render. The message names the specific problem."""


_CONTROL = re.compile(r"[\x00-\x1f\x7f]")


def _clean(text, limit, notes, what):
    """Make caller text safe to place inside a Markdown table and a fenced block."""
    original = "" if text is None else str(text)
    safe = _CONTROL.sub(" ", original)
    safe = safe.replace("|", "\\|")
    # Three backticks would close the fence the caller is told to wrap this in.
    safe = safe.replace("```", "``")
    safe = " ".join(safe.split())
    if len(safe) > limit:
        safe = safe[: limit - 1].rstrip() + "…"
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
                f"The {series_name} series has the value {value!r} at position "
                f"{position + 1}, which is not a number."
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

    zero_meaningful = set(request.get("zero_meaningful") or [])

    x_labels = [_clean(label, constants.MAX_LABEL_CHARS, notes, "An x-axis label") for label in raw_x]

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
        numbers = [_to_number(value, name, index) for index, value in enumerate(values)]
        gaps = [index for index, number in enumerate(numbers) if math.isnan(number)]
        if len(gaps) == len(numbers):
            raise Refusal(f"The {name} series has no values to show; every point is missing.")
        series[name] = numbers
        missing[name] = gaps

    if len(series) != len(raw_series):
        raise Refusal("Two series share a name once their labels are cleaned up.")

    requested = request.get("type") or request.get("form") or "auto"
    if requested not in ("auto", "table", "chart"):
        notes.append(
            f"The requested form {requested!r} is not one this version provides; "
            "the form was chosen from the data instead."
        )
        requested = "auto"

    return {
        "title": _clean(request.get("title"), constants.MAX_TITLE_CHARS, notes, "The title"),
        "requested_form": requested,
        "x": x_labels,
        "series": series,
        "missing": missing,
        "zero_meaningful": zero_meaningful,
        "units": _clean(request.get("units"), constants.MAX_LABEL_CHARS, notes, "The units"),
        "source": {
            _clean(k, constants.MAX_LABEL_CHARS, notes, "A source field"):
            _clean(v, constants.MAX_LABEL_CHARS, notes, "A source value")
            for k, v in (request.get("source") or {}).items()
        },
        "notes": notes,
    }
