#!/usr/bin/env python3
"""The entry point. Reads a JSON request on stdin, writes a JSON response on stdout.

A refusal is a normal response and exits zero. Only an internal fault exits non-zero,
so a caller can tell "I will not render this" from "I broke".
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import render
from selection import choose
from validate import Refusal, validate

AXIS_GLYPHS = ("┼", "┤")

RELAY = (
    "Reproduce the block below verbatim inside a plain triple-backtick fence with no "
    "language tag. Do not retype it, do not summarise it, and do not describe it in "
    "place of showing it."
)


def _refuse(message, notes=None):
    return {
        "status": "refused",
        "message": message,
        "block": "",
        "form": None,
        "metadata": {},
        "notes": notes or [],
        "relay": RELAY,
    }


def _verify(block, expect_axis):
    """The library returns '' and raises nothing on two inputs, so check the string.

    A completed call is not proof anything was drawn - the repo has a written rule
    about exactly this, from a tally that counted work an exited-zero command never did.
    """
    if not block or not block.strip():
        return "The chart came back empty, so there is nothing to show."
    if expect_axis and not any(glyph in block for glyph in AXIS_GLYPHS):
        return "The chart came back without an axis, so it is not a chart."
    return None


def present(request):
    try:
        normalized = validate(request)
    except Refusal as exc:
        return _refuse(str(exc))

    decision = choose(normalized)
    notes = list(normalized["notes"]) + list(decision["reasons"])

    blocks = []
    if decision["form"] == "charts":
        for name in decision["chart_series"]:
            block, meta = render.chart_with_meta(normalized, name)
            problem = _verify(block, expect_axis=True)
            if problem:
                return _refuse(problem, notes)
            blocks.append(block)
            if meta["omitted"]:
                notes.append(
                    f"{name}: {meta['omitted']} of {meta['omitted'] + meta['rendered']} points "
                    "were omitted to fit the width. No values were averaged, and the full "
                    f"range was {render.format_number(meta['full_min'])} to "
                    f"{render.format_number(meta['full_max'])}."
                )
        if decision["table_series"]:
            block, meta = render.table_with_meta(normalized, decision["table_series"])
            problem = _verify(block, expect_axis=False)
            if problem:
                return _refuse(problem, notes)
            blocks.append(block)
    else:
        block, meta = render.table_with_meta(normalized, decision["table_series"])
        problem = _verify(block, expect_axis=False)
        if problem:
            return _refuse(problem, notes)
        blocks.append(block)
        if meta["omitted"]:
            notes.append(
                f"{meta['omitted']} of {meta['omitted'] + meta['rendered']} rows were omitted "
                "to keep the table readable. No values were averaged."
            )

    for name, positions in normalized["missing"].items():
        if positions:
            human = ", ".join(str(p + 1) for p in positions)
            notes.append(
                f"{name}: no value at position {human}. The gap is shown as a break, not as a zero."
            )

    metadata = {
        "title": normalized["title"],
        "series": list(normalized["series"]),
        "x_count": len(normalized["x"]),
    }
    if normalized["units"]:
        metadata["units"] = normalized["units"]
    if normalized["source"]:
        metadata["source"] = normalized["source"]

    # R19: the caption rides inside the block, once, for every form. Only the block
    # can be expected to survive relay, so anything qualifying the numbers goes in it.
    head = render.caption(normalized)
    body = "\n\n".join(blocks)
    return {
        "status": "ok",
        "message": "",
        "block": (head + "\n" + body) if head else body,
        "form": decision["form"],
        "metadata": metadata,
        "notes": notes,
        "relay": RELAY,
    }


def main():
    try:
        request = json.load(sys.stdin)
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        # A fault, not a refusal: the caller sent something that is not a request.
        print(f"data-presentation: could not read the request as JSON: {exc}", file=sys.stderr)
        return 2
    print(json.dumps(present(request), ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
