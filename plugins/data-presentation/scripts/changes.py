"""The run record, and what changed since the last successful run of a template, in plain lines."""

import math
import textwrap
from datetime import datetime, timedelta, timezone

import credentials
import render
import validate

MAX_CHANGE_LINES = 12

NO_RUN = "no earlier run"
BAD_RECORD = "the last run's record cannot be read"
TEMPLATE_CHANGED = "the template changed since the last run"

ORDER = (
    "revised", "filled_in", "new_x", "now_missing",
    "newly_returned", "no_longer_returned", "now_shown", "now_not_shown",
)

SERIES_WORDING = {
    "newly_returned": "newly returned",
    "no_longer_returned": "no longer returned",
    "now_shown": "now shown",
    "now_not_shown": "now not shown, still returned",
}

# Amplitude x values carry no zone. The latest zone on Earth is UTC-12, so an interval
# is closed everywhere only once its end has passed there; ending earlier can miss an
# open interval, which is the one error the caveat must never make.
LATEST_ZONE_OFFSET = timedelta(hours=12)


def _parse(text):
    if not isinstance(text, str):
        return None
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        return datetime.fromisoformat(text)
    except ValueError:
        return None


def parse_time(text):
    moment = _parse(text)
    if moment is None or moment.tzinfo:
        return moment
    return moment.replace(tzinfo=timezone.utc)


def _as_utc(moment):
    if moment.tzinfo is None:
        return moment.replace(tzinfo=timezone.utc)
    return moment.astimezone(timezone.utc)


def _next_month(moment):
    year, month = (moment.year + 1, 1) if moment.month == 12 else (moment.year, moment.month + 1)
    try:
        return moment.replace(year=year, month=month)
    except ValueError:
        # Jan 31 has no Feb 31: roll forward to the first of the month after, never
        # clamp back to Feb 28, because a later end is the side that cannot miss.
        year, month = (year + 1, 1) if month == 12 else (year, month + 1)
        return moment.replace(year=year, month=month, day=1)


def _month_like(step):
    return not step % timedelta(days=1) and 28 <= step.days <= 31


def open_x(block_x, replied_at):
    moments = [_parse(x) for x in block_x or []]
    reply = _parse(replied_at)
    if not moments or reply is None or any(m is None for m in moments):
        return None
    latest = max(range(len(moments)), key=lambda i: (_as_utc(moments[i]), i))
    last = moments[latest]
    ordered = sorted(_as_utc(m) for m in moments)
    steps = [b - a for a, b in zip(ordered, ordered[1:]) if b > a]
    if steps and all(_month_like(s) for s in steps):
        end = _next_month(last)
    else:
        end = last + max(steps, default=timedelta(days=1))
    if last.tzinfo is None:
        end = (end + LATEST_ZONE_OFFSET).replace(tzinfo=timezone.utc)
    return block_x[latest] if _as_utc(reply) < _as_utc(end) else None


def screen(number, block):
    named = [("an x label", x) for x in block["x"]]
    named += [("a series name", name) for name in [*block["series"], *(block.get("not_shown") or [])]]
    for where, value in named:
        if isinstance(value, str) and credentials.looks_secret(value):
            raise credentials.CredentialError(
                "secret",
                f"Block {number}: {where} from the source looks like a credential, so it was not shown "
                "or stored. The value is not repeated here.",
            )


def record_block(mapped, replied_at):
    return {
        "x": list(mapped["x"]),
        "series": {name: list(values) for name, values in mapped["series"].items()},
        "not_shown": list(mapped.get("not_shown") or []),
        "replied_at": replied_at,
        "open_x": open_x(mapped["x"], replied_at),
    }


def run_record(template_hash, blocks, marker=None):
    for number, block in enumerate(blocks, start=1):
        screen(number, block)
    record = {"template_hash": template_hash, "blocks": blocks}
    if marker is not None:
        record["marker"] = marker
    return record


def finished_by(record, marker):
    return isinstance(record, dict) and record.get("marker") == marker


def _number(value):
    return not isinstance(value, bool) and isinstance(value, (int, float))


def _block_ok(block):
    # not_shown and open_x are not checked: an older record has neither, and compare
    # reads a malformed not_shown as empty.
    if not isinstance(block, dict):
        return False
    x, series = block.get("x"), block.get("series")
    if not isinstance(x, list) or not isinstance(series, dict):
        return False
    if not all(isinstance(v, str) or _number(v) for v in x):
        return False
    for values in series.values():
        if not isinstance(values, list) or len(values) != len(x):
            return False
        if not all(v is None or _number(v) for v in values):
            return False
    return block.get("replied_at") is None or isinstance(block["replied_at"], str)


def baseline(record, template_hash, count):
    if record is None:
        return None, NO_RUN
    if not isinstance(record, dict):
        return None, BAD_RECORD
    if record.get("template_hash") != template_hash:
        return None, TEMPLATE_CHANGED
    blocks = record.get("blocks")
    if not isinstance(blocks, list) or len(blocks) != count or not all(map(_block_ok, blocks)):
        return None, BAD_RECORD
    return blocks, None


def _change(kind, x=None, series=None, old=None, new=None):
    return {"kind": kind, "x": x, "series": series, "old": old, "new": new}


def _shown(value):
    return None if value is None else render.format_number(value)


def _not_shown(block):
    # An older record has no not_shown, and a record read from disk may hold anything
    # there; both read as empty, which falls back to reporting by shown series alone.
    names = block.get("not_shown")
    return [n for n in names if isinstance(n, str)] if isinstance(names, list) else []


def _rolled_off(x, prev_x, cur_x):
    first = _parse(cur_x[0]) if cur_x else None
    this = _parse(x)
    if first is not None and this is not None:
        try:
            return this < first
        except TypeError:
            pass
    shared = [prev_x.index(c) for c in cur_x if c in prev_x]
    return not shared or prev_x.index(x) < min(shared)


def compare(previous, current, reason_if_none=None):
    if previous is None:
        found = _change("no_baseline")
        found["reason"] = reason_if_none or NO_RUN
        return [found]

    prev_x, cur_x = list(previous["x"]), list(current["x"])
    prev_series, cur_series = previous["series"], current["series"]
    prev_at = {x: i for i, x in enumerate(prev_x)}
    cur_at = {x: i for i, x in enumerate(cur_x)}
    both = [name for name in cur_series if name in prev_series]
    was_open = previous.get("open_x")
    kinds = {kind: [] for kind in ORDER}

    for x in cur_x:
        if x not in prev_at:
            kinds["new_x"].append(_change("new_x", x=x))
            continue
        for name in both:
            old = prev_series[name][prev_at[x]]
            new = cur_series[name][cur_at[x]]
            if old is not None and new is None:
                kinds["now_missing"].append(_change("now_missing", x, name, old, new))
            elif _shown(old) != _shown(new):
                kind = "filled_in" if x == was_open else "revised"
                kinds[kind].append(_change(kind, x, name, old, new))

    for x in prev_x:
        if x in cur_at or _rolled_off(x, prev_x, cur_x):
            continue
        for name in both:
            old = prev_series[name][prev_at[x]]
            if old is not None:
                kinds["now_missing"].append(_change("now_missing", x, name, old, None))

    prev_hidden, cur_hidden = _not_shown(previous), _not_shown(current)
    prev_returned = set(prev_series) | set(prev_hidden)
    cur_returned = set(cur_series) | set(cur_hidden)
    for n in dict.fromkeys([*cur_series, *cur_hidden]):
        if n not in prev_returned:
            kinds["newly_returned"].append(_change("newly_returned", series=n))
    for n in dict.fromkeys([*prev_series, *prev_hidden]):
        if n not in cur_returned:
            kinds["no_longer_returned"].append(_change("no_longer_returned", series=n))
    kinds["now_shown"] = [_change("now_shown", series=n) for n in cur_series if n in prev_hidden]
    kinds["now_not_shown"] = [_change("now_not_shown", series=n) for n in prev_series if n in cur_hidden]
    return [found for kind in ORDER for found in kinds[kind]]


def _clean(text):
    return validate.clean_text(text, math.inf, [], "a changes line")


def _wrap(text, width, indent="", more="  "):
    # Numbers never exceed the minimum width, so break_long_words only ever splits a
    # series name or an x label, never a number.
    return textwrap.wrap(
        text, width, initial_indent=indent, subsequent_indent=more,
        break_long_words=True, break_on_hyphens=False,
    )


def _value(value):
    return "missing" if value is None else render.format_number(value)


def _lines(change, width, display_x):
    kind = change["kind"]
    if kind == "no_baseline":
        return _wrap(f"No earlier run to compare: {_clean(change.get('reason'))}.", width)
    x = _clean(display_x(change["x"])) if change["x"] is not None else None
    if kind == "new_x":
        return _wrap(f"{x}: new", width)
    series = _clean(change["series"])
    if kind in SERIES_WORDING:
        rest = SERIES_WORDING[kind]
        if len(series) + len(rest) + 2 <= width:
            return [f"{series}: {rest}"]
        return _wrap(series, width, more="") + _wrap(rest, width, indent="  ")
    old, new = _value(change["old"]), _value(change["new"])
    rest = {
        "revised": f"{new}, was {old} (revised)",
        "filled_in": f"{new}, was {old} while the interval was open",
        "now_missing": f"now missing, was {old}",
    }[kind]
    full = f"{x} {series}: {rest}"
    if len(full) <= width:
        return [full]
    return _wrap(series, width, more="") + _wrap(f"{x}: {rest}", width, indent="  ")


def render_lines(changes, width, display_x=str):
    if not changes:
        return ["No changes since the last run."]
    lines = []
    for change in changes[:MAX_CHANGE_LINES]:
        lines.extend(_lines(change, width, display_x))
    more = len(changes) - MAX_CHANGE_LINES
    if more > 0:
        lines.append(f"... and {more} more change{'' if more == 1 else 's'}")
    return lines


def topn_line(args):
    limit = _find_limit(args)
    if limit is None:
        return None
    return f"Series may be newly returned or no longer returned because the source shows only its top {limit}."


def _find_limit(node):
    if isinstance(node, dict):
        if node.get("groupByLimit") is not None:
            return node["groupByLimit"]
        children = node.values()
    elif isinstance(node, list):
        children = node
    else:
        return None
    for child in children:
        found = _find_limit(child)
        if found is not None:
            return found
    return None
