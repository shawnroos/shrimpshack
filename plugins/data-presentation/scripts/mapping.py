"""Turn a source result into x and series the same way every run, and fingerprint its structure.

A result that cannot be read the way the template expects is a stop, never a gap.
"""

import datetime
import hashlib
import json
import math
import re

import changes
import constants
from canon import canonical_json

ADAPTERS = ("amplitude-segmentation", "paths", "identity")

_KEYS = {"adapter", "chart", "paths", "series", "aliases"}
_SEGMENT = re.compile(r"^(\*|\d+|[A-Za-z_][A-Za-z0-9_]*)$")

_AMP_X = ["data", "jsonResponse", "xValuesForTimeSeries", "*"]
_AMP_NAMES = ["data", "jsonResponse", "seriesLabels", "*", "1"]
_AMP_VALUES = ["data", "jsonResponse", "timeSeries", "*", "*", "value"]
_AMP_PARAMS = ["definition", "params"]

_IDENTITY_X = ["x", "*"]
_IDENTITY_NAMES = ["series", "names", "*"]
_IDENTITY_VALUES = ["series", "values", "*", "*"]

# A name from a result is data, and it lands in a message the agent relays. Capped so a
# long or hostile name cannot dominate the message.
_NAME_CHARS = 40


class MappingError(Exception):
    def __init__(self, kind, message):
        super().__init__(message)
        self.kind = kind


def _invalid(message):
    return MappingError("invalid", message)


def _drift(message):
    return MappingError("drift", message)


def _source_error(message):
    return MappingError("source_error", message)


def _name(text):
    text = str(text)
    return repr(text if len(text) <= _NAME_CHARS else text[: _NAME_CHARS - 1] + "…")


def _type(value):
    if isinstance(value, bool):
        return "bool"
    # int, float and null are one type: a gap or a fractional week must not read as drift.
    if value is None or isinstance(value, (int, float)):
        return "number"
    if isinstance(value, str):
        return "str"
    if isinstance(value, list):
        return "list"
    if isinstance(value, dict):
        return "dict"
    return type(value).__name__


def _parse_path(text, field):
    if not isinstance(text, str) or not text:
        raise _invalid(f"{field} must be a dotted path such as data.rows.*.value.")
    segments = text.split(".")
    for segment in segments:
        if not _SEGMENT.match(segment):
            raise _invalid(
                f"{field} has the segment {_name(segment)}; each segment must be a key, "
                "a whole-number index, or *."
            )
    return segments


def _path_spec(paths):
    if not isinstance(paths, dict) or set(paths) != {"x", "names", "values"}:
        raise _invalid("paths must be an object with exactly x, names and values.")
    x = _parse_path(paths["x"], "paths.x")
    names = _parse_path(paths["names"], "paths.names")
    values = _parse_path(paths["values"], "paths.values")
    if x.count("*") > 1:
        raise _invalid("paths.x may hold at most one *; it reads one list of x values.")
    if names.count("*") != 1:
        raise _invalid("paths.names must hold exactly one *, one per series.")
    if values.count("*") != 2:
        raise _invalid("paths.values must hold exactly two *: the series, then the x positions.")
    if "*" not in x:
        x = x + ["*"]
    return x, names, values


def validate_mapping(mapping):
    if not isinstance(mapping, dict):
        raise _invalid("The mapping must be an object.")
    unknown = sorted(set(mapping) - _KEYS)
    if unknown:
        raise _invalid(f"The mapping has the unknown field {_name(unknown[0])}.")
    adapter = mapping.get("adapter")
    if adapter not in ADAPTERS:
        raise _invalid(f"The mapping's adapter must be one of {', '.join(ADAPTERS)}.")

    if adapter == "amplitude-segmentation":
        chart = mapping.get("chart")
        if not isinstance(chart, str) or not chart:
            raise _invalid("An amplitude-segmentation mapping needs chart, the chart id to read.")
    elif "chart" in mapping:
        raise _invalid("chart belongs only to an amplitude-segmentation mapping.")

    if adapter == "paths":
        if "paths" not in mapping:
            raise _invalid("A paths mapping needs paths with x, names and values.")
        _path_spec(mapping["paths"])
    elif "paths" in mapping:
        raise _invalid("paths belongs only to a paths mapping.")

    series = mapping.get("series", "all")
    if series != "all":
        if not isinstance(series, list) or not series:
            raise _invalid('series must be "all" or a non-empty list of series names.')
        if not all(isinstance(s, str) and s for s in series):
            raise _invalid("Every name in series must be non-empty text.")
        if len(set(series)) != len(series):
            raise _invalid("series lists the same name twice.")
        if len(series) > constants.MAX_SERIES:
            raise _invalid(f"series lists {len(series)} names; at most {constants.MAX_SERIES} can be shown.")

    aliases = mapping.get("aliases", {})
    if not isinstance(aliases, dict):
        raise _invalid("aliases must be an object of source name to displayed name.")
    targets = {}
    for source, target in aliases.items():
        if not isinstance(target, str) or not target:
            raise _invalid(f"The alias for {_name(source)} must be non-empty text.")
        if target in targets:
            raise _invalid(
                f"The aliases for {_name(targets[target])} and {_name(source)} both show as "
                f"{_name(target)}; two displayed series never share a name."
            )
        targets[target] = source


def _parse(result):
    if isinstance(result, (bytes, bytearray)):
        result = result.decode("utf-8", errors="replace")
    if isinstance(result, str):
        try:
            return json.loads(result)
        except ValueError:
            raise _source_error(
                "The source replied with text that is not JSON, which is treated as an error "
                "from the source. The text is not repeated here."
            ) from None
    return result


def _refuse_error_shape(result, expected):
    if isinstance(result, dict) and ("error" in result or "errors" in result):
        if not any(key in result for key in expected):
            key = "error" if "error" in result else "errors"
            raise _source_error(
                f"The source replied with an error (a top-level {key} field) instead of data. "
                "Its content is not repeated here."
            )


def _record(types, path, value, at):
    key = ".".join(path)
    kind = _type(value)
    if types.setdefault(key, kind) != kind:
        where = ".".join(at)
        named = f" ({where} is a {kind})" if where != key else ""
        raise _drift(f"{key} holds mixed types ({types[key]} and {kind}){named}.")


def _read(node, segments, done, types, at=None):
    # `done` is the pattern (with *) that types are recorded under; `at` is the concrete
    # path, so a message can say which element broke.
    at = list(done) if at is None else at
    if done:
        _record(types, done, node, at)
    if not segments:
        return node
    segment, rest = segments[0], segments[1:]
    here = ".".join(at) or "The result"
    if segment == "*" or segment.isdigit():
        if not isinstance(node, list):
            raise _drift(f"{here} should be a list but is a {_type(node)}.")
        if segment == "*":
            if not node:
                raise _drift(f"{here} is an empty list.")
            return [_read(item, rest, done + ["*"], types, at + [str(i)]) for i, item in enumerate(node)]
        index = int(segment)
        if index >= len(node):
            raise _drift(f"{here} has no element {index}.")
        return _read(node[index], rest, done + [segment], types, at + [segment])
    if not isinstance(node, dict):
        raise _drift(f"{here} should be an object but is a {_type(node)}.")
    if segment not in node:
        raise _drift(f"{'.'.join(at + [segment])} is missing from the result.")
    return _read(node[segment], rest, done + [segment], types, at + [segment])


def _amplitude_entry(result, chart):
    if not isinstance(result, dict):
        raise _drift("The result should be an object but is a " + _type(result) + ".")
    for key in ("success", "failedCount", "results"):
        if key not in result:
            raise _drift(f"{key} is missing from the result.")
    if result["success"] is not True:
        raise _source_error("The source reported the request failed (success is not true).")
    failed = result["failedCount"]
    if _type(failed) != "number" or failed is None:
        raise _drift("failedCount should be a number.")
    if failed != 0:
        raise _source_error(f"The source reported {failed} failed chart(s) in this reply (failedCount {failed}).")
    if not isinstance(result["results"], list):
        raise _drift("results should be a list.")
    matches = [r for r in result["results"] if isinstance(r, dict) and r.get("chartId") == chart]
    if not matches:
        raise _source_error(f"The source returned no result for chart {_name(chart)}.")
    if len(matches) > 1:
        raise _drift(f"results holds chart {_name(chart)} more than once.")
    entry = matches[0]
    if "success" not in entry:
        raise _drift(f"results[{chart}].success is missing from the result.")
    if entry["success"] is not True:
        raise _source_error(f"The source reported chart {_name(chart)} failed.")
    return entry


def _check_shape(x, names, values, x_key, names_key, values_key):
    for value in x:
        if isinstance(value, bool) or not isinstance(value, (str, int, float)):
            raise _drift(f"{x_key} should hold text or numbers, but holds a {_type(value)}.")
    for name in names:
        if not isinstance(name, str):
            raise _drift(f"{names_key} should hold text names, but holds a {_type(name)}.")
    if len(names) != len(values):
        raise _drift(f"{names_key} has {len(names)} names but {values_key} has {len(values)} series.")
    for i, row in enumerate(values):
        if not isinstance(row, list):
            raise _drift(f"{values_key} series {i + 1} should be a list but is a {_type(row)}.")
        if len(row) != len(x):
            raise _drift(f"{values_key} series {i + 1} has {len(row)} values but {x_key} has {len(x)}.")
        for j, value in enumerate(row):
            if value is None:
                continue
            if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
                raise _drift(
                    f"{values_key} series {i + 1}, position {j + 1} holds a {_type(value)}; "
                    "each value must be a number or null."
                )


def _identity_root(result):
    if not isinstance(result, dict):
        raise _drift(f"The result should be an object with x and series but is a {_type(result)}.")
    for key, kind in (("x", "list"), ("series", "dict")):
        if key not in result:
            raise _drift(f"{key} is missing from the result.")
        if _type(result[key]) != kind:
            raise _drift(f"{key} should be a {kind} but is a {_type(result[key])}.")
    series = result["series"]
    return {"x": result["x"], "series": {"names": list(series), "values": list(series.values())}}


def _latest(row):
    for value in reversed(row):
        if value is not None:
            return value
    return -math.inf


class Reading:
    def __init__(self, mapping, x, names, values, types, definition):
        # Before anything can quote a name: mapped()'s collision message repeats the raw names
        # it was given, so a credential-looking name has to stop the run here.
        changes.screen_source(x, names)
        self._mapping = mapping
        self._x, self._names, self._values = x, names, values
        self._types = types
        self._definition = definition

    def fingerprint(self):
        out = {"paths": dict(sorted(self._types.items())), "x": _x_kind(self._x)}
        if self._definition is not None:
            out["definition"] = self._definition
        return out

    def check(self, saved):
        if not isinstance(saved, dict) or not isinstance(saved.get("paths"), dict) or not isinstance(saved.get("x"), dict):
            raise _invalid("The saved fingerprint must be an object with paths and x.")
        current = self.fingerprint()

        if saved.get("definition") != current.get("definition"):
            raise _drift(
                f"Chart {_name(self._mapping.get('chart', ''))} was edited in the source since this template "
                "was saved: its definition no longer matches."
            )
        for path, kind in saved["paths"].items():
            if path not in current["paths"]:
                raise _drift(f"{path} is no longer in the result.")
            if current["paths"][path] != kind:
                raise _drift(f"{path} held a {kind} when the template was saved and now holds a {current['paths'][path]}.")
        for path in current["paths"]:
            if path not in saved["paths"]:
                raise _drift(f"{path} is read now but was not in the saved fingerprint.")

        was, now = saved["x"], current["x"]
        if was.get("kind") != now["kind"]:
            raise _drift(f"The x values were {was.get('kind')}s when the template was saved and are now {now['kind']}s.")
        if now["kind"] == "date":
            before, after = was.get("step_days"), now["step_days"]
            # One x value shows no step, and counts never decide drift.
            if before is not None and after is not None and before != after:
                raise _drift(
                    f"The x values were {before} days apart when the template was saved and are now "
                    f"{after} day(s) apart."
                )

    def mapped(self):
        names, values = self._names, self._values
        aliases = self._mapping.get("aliases", {})

        shown_by = {}
        display = []
        for raw in names:
            shown = aliases.get(raw, raw)
            if shown in shown_by:
                first = shown_by[shown]

                def said(n):
                    return f"{_name(n)} (renamed by an alias)" if n in aliases else _name(n)

                raise _invalid(
                    f"Two series would both show as {_name(shown)}: {said(first)} and {said(raw)}. "
                    "Two displayed series never share a name; change or remove the alias."
                )
            shown_by[shown] = raw
            display.append(shown)
        rows = dict(zip(display, values))

        wanted = self._mapping.get("series", "all")
        if wanted == "all":
            order = list(display)
            if len(order) > constants.MAX_SERIES:
                ranked = sorted(range(len(display)), key=lambda i: (-_latest(values[i]), i))
                keep = set(ranked[: constants.MAX_SERIES])
                order = [display[i] for i in range(len(display)) if i in keep]
        else:
            gone = [n for n in wanted if n not in rows]
            if gone:
                raise _drift(f"The template shows the series {_name(gone[0])}, but the result no longer returns it.")
            order = list(wanted)
        kept = set(order)
        return {
            "x": list(self._x),
            "series": {n: list(rows[n]) for n in order},
            "not_shown": [n for n in display if n not in kept],
        }


def read(result, mapping):
    validate_mapping(mapping)
    result = _parse(result)
    adapter = mapping["adapter"]
    types = {}
    definition = None

    if adapter == "amplitude-segmentation":
        _refuse_error_shape(result, ("results", "success"))
        chart = mapping["chart"]
        root = _amplitude_entry(result, chart)
        base = [f"results[{chart}]"]
        params = _read(root, _AMP_PARAMS, base, types)
        if not isinstance(params, dict):
            raise _drift(f"{'.'.join(base + _AMP_PARAMS)} should be an object.")
        definition = "sha256:" + hashlib.sha256(canonical_json(params).encode("utf-8")).hexdigest()
        x_path, names_path, values_path = _AMP_X, _AMP_NAMES, _AMP_VALUES
    elif adapter == "paths":
        x_path, names_path, values_path = _path_spec(mapping["paths"])
        head = x_path[0]
        _refuse_error_shape(result, (head,) if head != "*" and not head.isdigit() else ())
        root, base = result, []
    else:
        _refuse_error_shape(result, ("x", "series"))
        root, base = _identity_root(result), []
        x_path, names_path, values_path = _IDENTITY_X, _IDENTITY_NAMES, _IDENTITY_VALUES

    x = _read(root, x_path, base, types)
    names = _read(root, names_path, base, types)
    values = _read(root, values_path, base, types)
    series_depth = values_path.index("*") + 1
    _check_shape(
        x,
        names,
        values,
        ".".join(base + x_path),
        ".".join(base + names_path),
        ".".join(base + values_path[:series_depth]),
    )
    return Reading(mapping, x, names, values, types, definition)


def fingerprint(result, mapping):
    return read(result, mapping).fingerprint()


def _as_datetime(value):
    # One parser for both layers: a value changes.open_x reads as a date must also carry a
    # date label and a date x kind, or the caveat and the fingerprint disagree.
    return changes.parse_time(value)


def _x_kind(x):
    stamps = [_as_datetime(v) for v in x]
    if not stamps or any(s is None for s in stamps):
        return {"kind": "label"}
    if len(stamps) < 2:
        return {"kind": "date", "step_days": None}
    gaps = {(b - a).total_seconds() / 86400 for a, b in zip(stamps, stamps[1:])}
    if len(gaps) == 1:
        step = gaps.pop()
        step = int(step) if step == int(step) else round(step, 6)
    # Calendar months, quarters and years vary in length, so their gaps fold to one step.
    elif all(28 <= g <= 31 for g in gaps):
        step = 30
    elif all(89 <= g <= 92 for g in gaps):
        step = 91
    elif all(365 <= g <= 366 for g in gaps):
        step = 365
    else:
        step = "irregular"
    return {"kind": "date", "step_days": step}


def display_x(raw_x):
    stamps = [_as_datetime(v) for v in raw_x]
    if not stamps or any(s is None for s in stamps):
        return [str(v) for v in raw_x]
    fmt = "%b %d"
    if any(s.time() != datetime.time() for s in stamps):
        fmt += " %H:%M"
    labels = [s.strftime(fmt) for s in stamps]
    if len(set(labels)) < len(set(stamps)):
        labels = [s.strftime(fmt + " %Y") for s in stamps]
    return labels
