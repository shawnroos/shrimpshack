#!/usr/bin/env python3
"""U4: run record and changes. A revision must never read as "no changes"."""

import os
import sys

SCRIPTS = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts")
sys.path.insert(0, SCRIPTS)

import changes  # noqa: E402

passed = failed = 0


def check(name, condition, detail=""):
    global passed, failed
    if condition:
        passed += 1
        print(f"  ok   - {name}")
    else:
        failed += 1
        print(f"  FAIL - {name}{(': ' + detail) if detail else ''}", file=sys.stderr)


WEEKS = ["2026-08-17T00:00:00", "2026-08-24T00:00:00", "2026-08-31T00:00:00"]


def short(x):
    months = {"08": "Aug", "09": "Sep"}
    return f"{months[x[5:7]]} {int(x[8:10])}"


def block(x, series, open_x=None):
    return {"x": list(x), "series": series, "replied_at": "2026-09-01T09:00:00Z", "open_x": open_x}


def kinds(found):
    return [c["kind"] for c in found]


# AE1: a revision opens the list, worded as old and new.
prev = block(WEEKS, {"tool-alpha": [3, 7, 4]})
cur = {"x": WEEKS, "series": {"tool-alpha": [3, 9, 4]}}
found = changes.compare(prev, cur)
check("AE1 one change", kinds(found) == ["revised"], str(found))
check(
    "AE1 fields",
    found and found[0]["x"] == WEEKS[1] and found[0]["series"] == "tool-alpha"
    and found[0]["old"] == 7 and found[0]["new"] == 9,
    str(found),
)
lines = changes.render_lines(found, 48, display_x=short)
check(
    "AE1 first line reads revised",
    lines and lines[0] == "Aug 24 tool-alpha: 9, was 7 (revised)",
    repr(lines),
)

# A new week at the end, with the oldest week rolled off the start.
prev = block(WEEKS, {"tool-alpha": [3, 7, 4]})
cur = {"x": WEEKS[1:] + ["2026-09-07T00:00:00"], "series": {"tool-alpha": [7, 4, 6]}}
found = changes.compare(prev, cur)
check("new week listed as new_x", kinds(found) == ["new_x"], str(found))
check("new week names its x", found and found[0]["x"] == "2026-09-07T00:00:00", str(found))
check("rolled-off week not listed", all(c["x"] != WEEKS[0] for c in found), str(found))
lines = changes.render_lines(found, 48, display_x=short)
check("new week wording", lines == ["Sep 7: new"], repr(lines))

# Rolled-off rule on non-date x falls back to the previous record's order.
prev = block(["a", "b", "c"], {"tool-alpha": [1, 2, 3]})
cur = {"x": ["b", "c"], "series": {"tool-alpha": [2, 3]}}
check("rolled-off non-date x not listed", changes.compare(prev, cur) == [])

# An x dropped from the middle did not roll off; its values are now missing.
prev = block(WEEKS, {"tool-alpha": [3, 7, 4]})
cur = {"x": [WEEKS[0], WEEKS[2]], "series": {"tool-alpha": [3, 4]}}
found = changes.compare(prev, cur)
check(
    "middle x dropped is now missing",
    kinds(found) == ["now_missing"] and found[0]["x"] == WEEKS[1] and found[0]["old"] == 7,
    str(found),
)

# A value that was 5 and is now null.
prev = block(WEEKS, {"tool-alpha": [3, 5, 4]})
cur = {"x": WEEKS, "series": {"tool-alpha": [3, None, 4]}}
found = changes.compare(prev, cur)
check("null now is now_missing", kinds(found) == ["now_missing"], str(found))
lines = changes.render_lines(found, 48, display_x=short)
check("now missing wording", lines == ["Aug 24 tool-alpha: now missing, was 5"], repr(lines))

# AE4: first run, and a record written under a different template hash.
found = changes.compare(None, cur, "no earlier run")
check("first run is one no_baseline", kinds(found) == ["no_baseline"], str(found))
lines = changes.render_lines(found, 48)
check("first run wording", lines == ["No earlier run to compare: no earlier run."], repr(lines))
check("no baseline never reads as no changes", "No changes" not in " ".join(lines))
check("reason defaults to no earlier run", changes.compare(None, cur)[0].get("reason") == "no earlier run")
found = changes.compare(None, cur, "the template changed since the last run")
lines = changes.render_lines(found, 80)
check(
    "template-changed wording",
    lines == ["No earlier run to compare: the template changed since the last run."],
    repr(lines),
)
lines = changes.render_lines(found, 48)
check("template-changed line wraps within 48", all(len(l) <= 48 for l in lines), repr(lines))
check(
    "template-changed wrap keeps every word",
    " ".join(" ".join(lines).split()) == "No earlier run to compare: the template changed since the last run.",
    repr(lines),
)

# Empty comparison.
check("no changes wording", changes.render_lines([], 48) == ["No changes since the last run."])

# 30 revisions: 12 lines plus a line naming the rest.
xs = [f"2026-08-{d:02d}T00:00:00" for d in range(1, 31)]
prev = block(xs, {"tool-alpha": list(range(30))})
cur = {"x": xs, "series": {"tool-alpha": [v + 100 for v in range(30)]}}
found = changes.compare(prev, cur)
check("30 revisions found", len(found) == 30 and set(kinds(found)) == {"revised"}, str(len(found)))
lines = changes.render_lines(found, 48, display_x=short)
check("cap is 12", changes.MAX_CHANGE_LINES == 12)
check("30 revisions render 13 lines", len(lines) == 13, str(len(lines)))
check("tail line names 18 more", lines and lines[-1] == "... and 18 more changes", repr(lines[-1:]))
check("first 12 are the earliest", lines and lines[0].startswith("Aug 1 ") and lines[11].startswith("Aug 12 "), repr(lines))
lines = changes.render_lines(found[:12], 48, display_x=short)
check("exactly 12 has no tail line", len(lines) == 12 and not lines[-1].startswith("..."), repr(lines[-1:]))
lines = changes.render_lines(found[:13], 48, display_x=short)
check("13 says one more change", lines[-1] == "... and 1 more change", repr(lines[-1:]))

# Values that format identically are not revisions.
prev = block(WEEKS, {"tool-alpha": [3, 1234.56, 4], "tool-beta": [12341, 1, 1]})
cur = {"x": WEEKS, "series": {"tool-alpha": [3, 1234.57, 4], "tool-beta": [12342, 1, 1]}}
check("1234.56 vs 1234.57 not revised", changes.compare(prev, cur) == [], str(changes.compare(prev, cur)))
prev = block(WEEKS, {"tool-alpha": [3, 7, 4]})
cur = {"x": WEEKS, "series": {"tool-alpha": [3.0, 7.0, 4.0]}}
check("int vs equal float not revised", changes.compare(prev, cur) == [])

# A possibly-open week that filled in is not a revision.
prev = block(WEEKS, {"tool-alpha": [3, 7, 40]}, open_x=WEEKS[2])
cur = {"x": WEEKS, "series": {"tool-alpha": [3, 7, 70]}}
found = changes.compare(prev, cur)
check("open week 40 to 70 is filled_in", kinds(found) == ["filled_in"], str(found))
lines = changes.render_lines(found, 48, display_x=short)
check(
    "filled in wording, series name on its own line",
    lines == ["tool-alpha", "  Aug 31: 70, was 40 while the interval was open"],
    repr(lines),
)
check("filled in fits unwrapped when wide", changes.render_lines(found, 80, display_x=short)
      == ["Aug 31 tool-alpha: 70, was 40 while the interval was open"])
check("filled in within 48", all(len(l) <= 48 for l in lines), repr(lines))
prev = block(WEEKS, {"tool-alpha": [3, 7, 40]}, open_x=None)
check("same change without open_x is revised", kinds(changes.compare(prev, cur)) == ["revised"])

# Series wording.
prev = block(WEEKS, {"tool-alpha": [1, 2, 3], "tool-gamma": [1, 1, 1]})
cur = {"x": WEEKS, "series": {"tool-alpha": [1, 2, 3], "tool-beta": [5, 5, 5]}}
found = changes.compare(prev, cur)
check("series changes", kinds(found) == ["newly_returned", "no_longer_returned"], str(found))
lines = changes.render_lines(found, 48)
check("newly returned wording", lines and lines[0] == "tool-beta: newly returned", repr(lines))
check("no longer returned wording", lines[1:] == ["tool-gamma: no longer returned"], repr(lines))

# Ordering across every kind in one comparison, regardless of input order.
prev = block(
    WEEKS,
    {"tool-gamma": [1, 1, 1], "tool-alpha": [3, 7, 40], "tool-delta": [5, 5, 5]},
    open_x=WEEKS[2],
)
cur = {
    "x": WEEKS + ["2026-09-07T00:00:00"],
    "series": {"tool-beta": [2, 2, 2, 2], "tool-delta": [5, None, 5, 5], "tool-alpha": [3, 9, 70, 8]},
}
found = changes.compare(prev, cur)
check(
    "ordering across all kinds",
    kinds(found) == ["revised", "filled_in", "new_x", "now_missing", "newly_returned", "no_longer_returned"],
    str(kinds(found)),
)
lines = changes.render_lines(found, 48, display_x=short)
check("rendered ordering starts with the revision", lines and lines[0].endswith("(revised)"), repr(lines))

# Compare by raw x, never position: a shifted range with the same values is not revised.
prev = block(WEEKS, {"tool-alpha": [3, 7, 4]})
cur = {"x": ["2026-08-10T00:00:00"] + WEEKS, "series": {"tool-alpha": [1, 3, 7, 4]}}
check("shifted range compares by x", kinds(changes.compare(prev, cur)) == ["new_x"], str(changes.compare(prev, cur)))

# Width: long series name, raw ISO x, and 1e15-scale numbers at the minimum width.
long_name = "tool-alpha-with-a-series-name-far-longer-than-the-width"
prev = block(WEEKS, {long_name: [1, 1234000000000000.0, 1]})
cur = {"x": WEEKS, "series": {long_name: [1, 1235000000000000.0, 1]}}
found = changes.compare(prev, cur)
lines = changes.render_lines(found, 48)
check("wide revision renders", len(lines) >= 2, repr(lines))
check("every line <= 48 on the wide revision", all(len(l) <= 48 for l in lines), repr(lines))
joined = " ".join(lines)
check("numbers are never cut", "1.235e+15" in joined and "1.234e+15" in joined, repr(lines))
check("x is kept whole", "2026-08-24T00:00:00" in joined, repr(lines))
check("series name is never cut", long_name in "".join(lines), repr(lines))

# Every rendered line <= 48 across the all-kinds case with raw x and long names.
prev = block(WEEKS, {long_name: [3, 7, 40], "tool-gamma-" + "g" * 50: [1, 1, 1]}, open_x=WEEKS[2])
cur = {
    "x": WEEKS + ["2026-09-07T00:00:00"],
    "series": {long_name: [3, 99999.5, 70123.25, None], "tool-beta-" + "b" * 60: [1, 1, 1, 1]},
}
found = changes.compare(prev, cur)
lines = changes.render_lines(found, 48)
check("all kinds rendered at 48 stay within 48", all(len(l) <= 48 for l in lines), repr(lines))

# Cleaning: a fence or a control character in a series name never reaches the block.
bad = "tool-``` alpha‮\x07x|y"
prev = block(WEEKS, {bad: [1, 2, 3]})
cur = {"x": WEEKS, "series": {bad: [1, 5, 3]}}
lines = changes.render_lines(changes.compare(prev, cur), 48, display_x=short)
joined = "\n".join(lines)
check("fence collapsed", "```" not in joined, repr(lines))
check("control characters removed", "‮" not in joined and "\x07" not in joined, repr(lines))
check("pipe escaped as the gate does", "x\\|y" in joined, repr(lines))
lines = changes.render_lines([{"kind": "newly_returned", "x": None, "series": bad, "old": None, "new": None}], 48)
check("fence cleaned on series-level lines", "```" not in "\n".join(lines), repr(lines))
lines = changes.render_lines(
    [{"kind": "new_x", "x": "2026-09-07```\x07", "series": None, "old": None, "new": None}], 48
)
check("x display cleaned too", "```" not in lines[0] and "\x07" not in lines[0], repr(lines))

# open_x: weekly x, last week starts 2026-08-31, so it ends 2026-09-07 local.
# UTC+14 end is 2026-09-06T10:00Z; UTC-12 end is 2026-09-07T12:00Z.
check("open between the UTC+14 and UTC-12 ends", changes.open_x(WEEKS, "2026-09-07T06:00:00Z") == WEEKS[2])
check("open just before UTC-12 end", changes.open_x(WEEKS, "2026-09-07T11:59:00Z") == WEEKS[2])
check("closed exactly at UTC-12 end", changes.open_x(WEEKS, "2026-09-07T12:00:00Z") is None)
check("closed after UTC-12 end", changes.open_x(WEEKS, "2026-09-08T00:00:00Z") is None)
check("offset reply time converted to UTC", changes.open_x(WEEKS, "2026-09-07T13:30:00+02:00") == WEEKS[2])
check("naive reply time is UTC", changes.open_x(WEEKS, "2026-09-07T12:00:00") is None)
days = ["2026-09-01", "2026-09-02", "2026-09-03"]
check("daily step, date-only x", changes.open_x(days, "2026-09-04T11:00:00Z") == "2026-09-03")
check("daily step closed", changes.open_x(days, "2026-09-04T12:00:00Z") is None)
check("non-date x is None", changes.open_x(["a", "b", "c"], "2026-09-07T06:00:00Z") is None)
check("irregular step is None", changes.open_x(["2026-09-01", "2026-09-02", "2026-09-05"], "2026-09-05T01:00:00Z") is None)
check("single x is None", changes.open_x(["2026-09-01"], "2026-09-01T01:00:00Z") is None)
check("bad reply time is None", changes.open_x(WEEKS, "not a time") is None)

# record_block carries the mapped numbers and its open x.
mapped = {"x": WEEKS, "series": {"tool-alpha": [3, 7, None]}}
rec = changes.record_block(mapped, "2026-09-07T06:00:00Z")
check(
    "record_block shape",
    rec == {"x": WEEKS, "series": {"tool-alpha": [3, 7, None]}, "replied_at": "2026-09-07T06:00:00Z", "open_x": WEEKS[2]},
    str(rec),
)
rec["series"]["tool-alpha"][0] = 99
check("record_block copies its input", mapped["series"]["tool-alpha"][0] == 3)
rec = changes.record_block(mapped, "2026-09-09T00:00:00Z")
check("record_block closed week has no open_x", rec["open_x"] is None)

# topn_line.
args = {"query": {"definition": {"params": {"groupByLimit": 25}}}}
check(
    "topn nested dict",
    changes.topn_line(args)
    == "Series may be newly returned or no longer returned because the source shows only its top 25.",
    repr(changes.topn_line(args)),
)
check("topn inside a list", "top 10." in (changes.topn_line({"events": [{"x": 1}, {"groupByLimit": 10}]}) or ""))
check("no topn is None", changes.topn_line({"query": {"limit": 5}}) is None)
check("topn on non-dict is None", changes.topn_line(None) is None)

print(f"changes_test: {passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
