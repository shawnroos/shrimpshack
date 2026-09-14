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


def block(x, series, open_x=None, not_shown=None):
    found = {"x": list(x), "series": series, "replied_at": "2026-09-01T09:00:00Z", "open_x": open_x}
    if not_shown is not None:
        found["not_shown"] = list(not_shown)
    return found


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

# With series "all" and more than eight series, a rank reshuffle moves a name between
# shown and not shown; both runs returned it, so it is neither newly nor no longer returned.
nine = [f"tool-{i}" for i in range(9)]
prev = block(WEEKS, {n: [1, 1, 1] for n in nine[:8]}, not_shown=[nine[8]])
cur = {
    "x": WEEKS,
    "series": {n: [1, 1, 1] for n in nine[:7] + [nine[8]]},
    "not_shown": [nine[7]],
}
found = changes.compare(prev, cur)
check("reshuffle is now_shown then now_not_shown", kinds(found) == ["now_shown", "now_not_shown"], str(found))
check(
    "reshuffle names the right series",
    [c["series"] for c in found] == ["tool-8", "tool-7"],
    str(found),
)
lines = changes.render_lines(found, 48)
check(
    "now shown and now not shown wording",
    lines == ["tool-8: now shown", "tool-7: now not shown, still returned"],
    repr(lines),
)
long_hidden = "tool-hidden-with-a-series-name-longer-than-the-width"
lines = changes.render_lines([{"kind": "now_not_shown", "x": None, "series": long_hidden, "old": None, "new": None}], 48)
check(
    "long now not shown wraps within 48 keeping every word",
    all(len(l) <= 48 for l in lines) and long_hidden in "".join(lines) and "still returned" in " ".join(lines),
    repr(lines),
)

# A name that only moved into not_shown is still returned in the current run.
prev = block(WEEKS, {"tool-alpha": [1, 1, 1], "tool-beta": [2, 2, 2]}, not_shown=[])
cur = {"x": WEEKS, "series": {"tool-alpha": [1, 1, 1]}, "not_shown": ["tool-beta"]}
check("shown to not shown is not no_longer_returned", kinds(changes.compare(prev, cur)) == ["now_not_shown"])

# A name absent from both series and not_shown on one side is newly or no longer returned.
prev = block(WEEKS, {"tool-alpha": [1, 1, 1]}, not_shown=["tool-gone"])
cur = {"x": WEEKS, "series": {"tool-alpha": [1, 1, 1]}, "not_shown": ["tool-new"]}
found = changes.compare(prev, cur)
check(
    "not-shown names that come and go are newly and no longer returned",
    [(c["kind"], c["series"]) for c in found] == [("newly_returned", "tool-new"), ("no_longer_returned", "tool-gone")],
    str(found),
)

# An older record carries no not_shown: it reads as empty.
prev = block(WEEKS, {"tool-alpha": [1, 1, 1], "tool-beta": [2, 2, 2]})
cur = {"x": WEEKS, "series": {"tool-alpha": [1, 1, 1]}, "not_shown": ["tool-beta"]}
check("older record without not_shown: moved to not shown", kinds(changes.compare(prev, cur)) == ["now_not_shown"])
cur = {"x": WEEKS, "series": {"tool-alpha": [1, 1, 1]}, "not_shown": []}
check("older record without not_shown: gone is no longer returned", kinds(changes.compare(prev, cur)) == ["no_longer_returned"])
prev["not_shown"] = 5
try:
    found = kinds(changes.compare(prev, cur))
except TypeError as e:
    found = repr(e)
check("a not_shown number reads as empty", found == ["no_longer_returned"], str(found))
prev = block(WEEKS, {"tool-alpha": [1, 1, 1], "tool-beta": [2, 2, 2]})
cur = {"x": WEEKS, "series": {"tool-alpha": [1, 1, 1]}, "not_shown": {"tool-beta": 1}}
check("a not_shown object reads as empty", kinds(changes.compare(prev, cur)) == ["no_longer_returned"])
prev = block(WEEKS, {"tool-alpha": [1, 1, 1]}, not_shown=[{"n": 1}, "tool-beta"])
cur = {"x": WEEKS, "series": {"tool-alpha": [1, 1, 1], "tool-beta": [2, 2, 2]}, "not_shown": []}
try:
    found = kinds(changes.compare(prev, cur))
except TypeError as e:
    found = repr(e)
check("a non-text entry in not_shown is skipped", found == ["now_shown"], str(found))

# Ordering across every kind in one comparison, regardless of input order.
prev = block(
    WEEKS,
    {"tool-hide": [4, 4, 4], "tool-gamma": [1, 1, 1], "tool-alpha": [3, 7, 40], "tool-delta": [5, 5, 5]},
    open_x=WEEKS[2],
    not_shown=["tool-show"],
)
cur = {
    "x": WEEKS + ["2026-09-07T00:00:00"],
    "series": {
        "tool-show": [6, 6, 6, 6],
        "tool-beta": [2, 2, 2, 2],
        "tool-delta": [5, None, 5, 5],
        "tool-alpha": [3, 9, 70, 8],
    },
    "not_shown": ["tool-hide"],
}
found = changes.compare(prev, cur)
check(
    "ordering across all kinds",
    kinds(found) == [
        "revised", "filled_in", "new_x", "now_missing",
        "newly_returned", "no_longer_returned", "now_shown", "now_not_shown",
    ],
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
check("numeric x is None", changes.open_x([1, 2, 3], "2026-09-07T06:00:00Z") is None)
check("bad reply time is None", changes.open_x(WEEKS, "not a time") is None)
check("aware weekly x has no zone offset", changes.open_x(["2026-08-24T00:00:00Z", "2026-08-31T00:00:00Z"], "2026-09-06T23:59:00Z") == "2026-08-31T00:00:00Z")
check("aware weekly x closed at its end", changes.open_x(["2026-08-24T00:00:00Z", "2026-08-31T00:00:00Z"], "2026-09-07T00:00:00Z") is None)

# Fail safe: when the step is irregular, not whole days, or unknown, the last x stays
# possibly open until the largest observed step (1 day for one point) plus 12 hours.
irregular = ["2026-09-01", "2026-09-02", "2026-09-05"]
check("irregular step: open before last + largest step + 12h", changes.open_x(irregular, "2026-09-08T11:59:00Z") == "2026-09-05")
check("irregular step: closed at last + largest step + 12h", changes.open_x(irregular, "2026-09-08T12:00:00Z") is None)
check("single x: open before last + 1 day + 12h", changes.open_x(["2026-09-01"], "2026-09-02T11:59:00Z") == "2026-09-01")
check("single x: closed at last + 1 day + 12h", changes.open_x(["2026-09-01"], "2026-09-02T12:00:00Z") is None)
hours = ["2026-09-01T10:00:00", "2026-09-01T11:00:00", "2026-09-01T12:00:00"]
check("hourly x: open before last + 1h + 12h", changes.open_x(hours, "2026-09-02T00:59:00Z") == hours[2])
check("hourly x: closed at last + 1h + 12h", changes.open_x(hours, "2026-09-02T01:00:00Z") is None)
halves = ["2026-09-01T00:00:00", "2026-09-02T12:00:00", "2026-09-04T00:00:00"]
check("36-hour step: open before last + 36h + 12h", changes.open_x(halves, "2026-09-05T23:59:00Z") == halves[2])
check("36-hour step: closed at last + 36h + 12h", changes.open_x(halves, "2026-09-06T00:00:00Z") is None)
unsorted = ["2026-09-05", "2026-09-01", "2026-09-02"]
check("unsorted x: the latest x is the open one", changes.open_x(unsorted, "2026-09-08T11:59:00Z") == "2026-09-05")
check("unsorted x: closed after the latest x's end", changes.open_x(unsorted, "2026-09-08T12:00:00Z") is None)

# Month-like steps (all 28 to 31 days) end at the same day next month.
months = ["2026-06-01T00:00:00", "2026-07-01T00:00:00", "2026-08-01T00:00:00"]
check("monthly: open before next month + 12h", changes.open_x(months, "2026-09-01T11:59:00Z") == months[2])
check("monthly: closed at next month + 12h", changes.open_x(months, "2026-09-01T12:00:00Z") is None)
check("two points 30 days apart are monthly", changes.open_x(["2026-04-01", "2026-05-01"], "2026-06-01T11:59:00Z") == "2026-05-01")
check("two points 30 days apart close at next month", changes.open_x(["2026-04-01", "2026-05-01"], "2026-06-01T12:00:00Z") is None)
check("28-day step to March ends April 1", changes.open_x(["2026-02-01", "2026-03-01"], "2026-03-30T00:00:00Z") == "2026-03-01")
check("31-day step to February ends March 1", changes.open_x(["2026-01-01", "2026-02-01"], "2026-03-02T00:00:00Z") is None)
check("Jan 31 rolls to March 1, never a clamped Feb 28", changes.open_x(["2025-12-31", "2026-01-31"], "2026-03-01T11:59:00Z") == "2026-01-31")
check("Jan 31 closed at March 1 + 12h", changes.open_x(["2025-12-31", "2026-01-31"], "2026-03-01T12:00:00Z") is None)
fractional = ["2026-06-01T00:00:00", "2026-06-30T12:00:00"]
check("a 29.5-day step is not monthly: closed after last + step + 12h", changes.open_x(fractional, "2026-07-30T18:00:00Z") is None)
check("a 29.5-day step is open before last + step + 12h", changes.open_x(fractional, "2026-07-30T11:59:00Z") == fractional[1])
check("December rolls into January",changes.open_x(["2026-11-01", "2026-12-01"], "2027-01-01T11:59:00Z") == "2026-12-01")

# record_block carries the mapped numbers and its open x.
mapped = {"x": WEEKS, "series": {"tool-alpha": [3, 7, None]}, "not_shown": ["tool-omega"]}
rec = changes.record_block(mapped, "2026-09-07T06:00:00Z")
check(
    "record_block shape",
    rec == {
        "x": WEEKS, "series": {"tool-alpha": [3, 7, None]}, "not_shown": ["tool-omega"],
        "replied_at": "2026-09-07T06:00:00Z", "open_x": WEEKS[2],
    },
    str(rec),
)
rec["series"]["tool-alpha"][0] = 99
rec["not_shown"].append("tool-extra")
check("record_block copies its input", mapped["series"]["tool-alpha"][0] == 3 and mapped["not_shown"] == ["tool-omega"])
check("record_block without not_shown stores an empty list", changes.record_block({"x": WEEKS, "series": {}}, None)["not_shown"] == [])
rec = changes.record_block(mapped, "2026-09-09T00:00:00Z")
check("record_block closed week has no open_x", rec["open_x"] is None)

# run_record builds the whole record; save's has no marker.
good = changes.record_block(mapped, "2026-09-07T06:00:00Z")
built = changes.run_record("fake-hash", [good], "dp-0000000000000000")
check("run_record shape with a marker", built == {"template_hash": "fake-hash", "blocks": [good], "marker": "dp-0000000000000000"}, str(built))
check("run_record without a marker stores no marker key", "marker" not in changes.run_record("fake-hash", [good]))
check("finished_by matches the stored marker", changes.finished_by(built, "dp-0000000000000000"))
check("finished_by refuses another marker", not changes.finished_by(built, "dp-1111111111111111"))
check("finished_by of no record or a non-object is False",
      not changes.finished_by(None, "dp-0000000000000000") and not changes.finished_by(["dp-0000000000000000"], "dp-0000000000000000"))


def refused_secret(fn, *args):
    try:
        fn(*args)
    except changes.credentials.CredentialError as err:
        return err
    return None


SECRETISH = "tok3nABCDEFGH1234567890"
for label, position, bad in (
    ("a shown series name", "a series name", {"x": WEEKS, "series": {SECRETISH: [1, 2, 3]}}),
    ("a series name not shown", "a series name", {"x": WEEKS, "series": {}, "not_shown": [SECRETISH]}),
    ("an x label", "an x label", {"x": ["fake-a", SECRETISH], "series": {"fake": [1, 2]}}),
):
    err = refused_secret(changes.run_record, "fake-hash", [good, changes.record_block(bad, None)])
    check(f"run_record refuses {label} that looks like a credential",
          err is not None and err.kind == "secret" and f"Block 2: {position} from the source" in str(err), repr(err))
    check(f"run_record's refusal of {label} never repeats the value", err is not None and SECRETISH not in str(err))
    err = refused_secret(changes.screen, 3, bad)
    check(f"screen refuses {label} before anything is shown", err is not None and "Block 3" in str(err), repr(err))
plain = {"x": ["blurry-background-regional"], "series": {"blurry-background-regional": [1]},
         "not_shown": ["another-long-plain-series-name"]}
check("an ordinary long name with no digits passes the screen", refused_secret(changes.screen, 1, plain) is None)
check("a number x is never screened", refused_secret(changes.screen, 1, {"x": [12345678901234567890123], "series": {}}) is None)

# The screen stays strict, and the stop names a way forward that the screen itself allows.
for label, value in (("40-character hex", "a" * 20 + "1" * 20), ("64-character hex", "b" * 32 + "2" * 32)):
    err = refused_secret(changes.screen, 1, {"x": WEEKS, "series": {value: [1, 2, 3]}})
    check(f"a {label} series name is still refused", err is not None and err.kind == "secret", repr(err))
    check(f"a {label} name is never repeated", err is not None and value not in str(err))
series_err = refused_secret(changes.screen, 1, {"x": WEEKS, "series": {SECRETISH: [1, 2, 3]}})
check("the series stop says it was not shown or stored",
      series_err is not None and "not shown or stored" in str(series_err), repr(series_err))
check("the series stop says an alias cannot rename it and what to change instead",
      series_err is not None and "alias cannot rename it" in str(series_err)
      and "change the call or the source" in str(series_err), repr(series_err))
label_err = refused_secret(changes.screen, 1, {"x": ["fake-a", SECRETISH], "series": {}})
check("the x-label stop names changing the call or the source",
      label_err is not None and "Change the call or the source" in str(label_err), repr(label_err))
check("the x-label stop offers no alias, which cannot rename an x label",
      label_err is not None and "alias" not in str(label_err), repr(label_err))

# screen_source is the same message without a block number; at_block adds one.
bare = refused_secret(changes.screen_source, [], [SECRETISH])
check("screen_source refuses a raw source name", bare is not None and bare.kind == "secret", repr(bare))
check("screen_source names no block and no value",
      bare is not None and not str(bare).startswith("Block") and SECRETISH not in str(bare), repr(bare))
check("screen_source passes ordinary names", refused_secret(changes.screen_source, ["fake-a"], ["fake-rows"]) is None)
check("screen_source refuses a raw x label",
      "an x label" in str(refused_secret(changes.screen_source, [SECRETISH], ["fake-rows"])))
numbered = changes.at_block(4, bare)
check("at_block prefixes the block and keeps the kind",
      str(numbered) == f"Block 4: {bare}" and numbered.kind == "secret", str(numbered))

# baseline: the three reasons, and the shape a loaded record must have.
check("no record is no earlier run", changes.baseline(None, "fake-hash", 1) == (None, "no earlier run"))
check("a record from another template says the template changed",
      changes.baseline(built, "other-hash", 1) == (None, "the template changed since the last run"))
check("a matching record returns its blocks", changes.baseline(built, "fake-hash", 1) == ([good], None))
bad_reason = (None, "the last run's record cannot be read")
check("a record that is not an object cannot be read", changes.baseline(["fake"], "fake-hash", 1) == bad_reason)
older = {k: v for k, v in good.items() if k not in ("not_shown", "open_x")}
check("a block with no not_shown or open_x is still read", changes.baseline(dict(built, blocks=[older]), "fake-hash", 1) == ([older], None))
odd = dict(good, not_shown="not a list")
check("a block with a malformed not_shown is still read", changes.baseline(dict(built, blocks=[odd]), "fake-hash", 1) == ([odd], None))
for label, blocks in (
    ("blocks not a list", {"0": good}),
    ("a block count unlike the template's", [good, good]),
    ("a block that is not an object", ["fake"]),
    ("x not a list", [dict(good, x="fake")]),
    ("series not an object", [dict(good, series=[1, 2, 3])]),
    ("an x value that is true", [dict(good, x=[True, WEEKS[1], WEEKS[2]])]),
    ("an x value that is an object", [dict(good, x=[{}, WEEKS[1], WEEKS[2]])]),
    ("a series shorter than x", [dict(good, series={"tool-alpha": [3, 7]})]),
    ("a series that is not a list", [dict(good, series={"tool-alpha": "3,7,40"})]),
    ("a value that is text", [dict(good, series={"tool-alpha": [3, "7", 40]})]),
    ("a value that is false", [dict(good, series={"tool-alpha": [3, False, 40]})]),
    ("a reply time that is a number", [dict(good, replied_at=1788393600)]),
):
    check(f"a record with {label} cannot be read", changes.baseline(dict(built, blocks=blocks), "fake-hash", 1) == bad_reason,
          repr(changes.baseline(dict(built, blocks=blocks), "fake-hash", 1)))

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
