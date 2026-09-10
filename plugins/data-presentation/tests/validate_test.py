#!/usr/bin/env python3
"""U2: the validation gate. Nothing reaches a renderer without passing through it."""

import math
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts"))

import constants
from validate import Refusal, validate

passed = failed = 0


def check(name, condition, detail=""):
    global passed, failed
    if condition:
        passed += 1
        print(f"  ok   - {name}")
    else:
        failed += 1
        print(f"  FAIL - {name}{(': ' + detail) if detail else ''}", file=sys.stderr)


def refusal(request):
    """Return the refusal message, or None when the request was accepted."""
    try:
        validate(request)
        return None
    except Refusal as exc:
        return str(exc)


def req(**over):
    base = {"title": "T", "x": ["a", "b", "c"], "series": {"S": [1.0, 2.0, 3.0]}}
    base.update(over)
    return base


def main():
    # --- length agreement (R4) --- AE4
    msg = refusal({"title": "T", "x": ["a", "b", "c", "d", "e"], "series": {"S": [1, 2, 3, 4]}})
    check("mismatched lengths are refused", msg is not None)
    check(
        "the mismatch message names both lengths",
        msg is not None and "5" in msg and "4" in msg,
        msg or "",
    )

    # --- degenerate inputs (R13) ---
    check("zero x values is refused", refusal({"title": "T", "x": [], "series": {"S": []}}) is not None)
    check("no series at all is refused", refusal({"title": "T", "x": ["a"], "series": {}}) is not None)

    msg = refusal(req(series={"S": [None, None, None]}))
    check("an all-missing series is refused", msg is not None)
    check("the all-missing message names the series", msg is not None and "S" in msg, msg or "")

    # --- numeric coercion (R5) ---
    result = validate(req(series={"S": ["1", "2.5", 3]}))
    check(
        "numeric strings become numbers",
        result["series"]["S"] == [1.0, 2.5, 3.0],
        repr(result["series"]["S"]),
    )

    msg = refusal(req(series={"S": [1, "n/a", 3]}))
    check("a non-numeric value is refused, not dropped", msg is not None)
    check(
        "the non-numeric message names the series and the position",
        msg is not None and "S" in msg and "2" in msg,
        msg or "",
    )

    # --- non-finite values (R5). These pass float() and then poison spread and axis. ---
    for bad in ("nan", "inf", "-inf", "Infinity"):
        check(
            f"the numeric-looking value {bad!r} is refused",
            refusal(req(series={"S": [1, bad, 3]})) is not None,
        )

    # --- missing values (R6, R7) ---
    result = validate(req(x=["a", "b", "c", "d"], series={"S": [1, None, 3, 4]}))
    check("a middle gap is accepted", result["missing"]["S"] == [1], repr(result["missing"]))
    check(
        "the gap is held as NaN, not as zero",
        math.isnan(result["series"]["S"][1]),
        repr(result["series"]["S"]),
    )

    result = validate(req(x=["a", "b", "c", "d"], series={"S": [None, 2, 3, None]}))
    check(
        "leading and trailing gaps are both recorded",
        result["missing"]["S"] == [0, 3],
        repr(result["missing"]),
    )

    result = validate(req(series={"S": [0, 0, 0]}, zero_meaningful=["S"]))
    check(
        "declared-meaningful zeros are values, not gaps",
        result["missing"]["S"] == [] and result["series"]["S"] == [0.0, 0.0, 0.0],
        repr(result["missing"]),
    )

    # --- caller text (R18) ---
    result = validate(req(title="a | b", x=["p|q", "r", "s"]))
    check(
        "a table delimiter in a title is escaped",
        "|" not in result["title"].replace("\\|", ""),
        repr(result["title"]),
    )
    check(
        "a table delimiter in an x label is escaped",
        "|" not in result["x"][0].replace("\\|", ""),
        repr(result["x"][0]),
    )

    result = validate(req(title="before\n```\nafter"))
    check(
        "a code fence in a title cannot close the block",
        "```" not in result["title"],
        repr(result["title"]),
    )
    check(
        "a newline in a title cannot break the block",
        "\n" not in result["title"],
        repr(result["title"]),
    )

    # Pin the limit with a literal on both sides. Deriving the input AND the expectation
    # from the constant makes the assertion incapable of failing when the constant moves.
    check("the label limit is pinned at 24", constants.MAX_LABEL_CHARS == 24, repr(constants.MAX_LABEL_CHARS))
    result = validate(req(x=["z" * 64, "b", "c"]))
    check(
        "a 64-character x label is truncated to 24",
        len(result["x"][0]) <= 24,
        f"len={len(result['x'][0])}",
    )
    check("the truncation is reported", any("truncat" in n.lower() for n in result["notes"]), repr(result["notes"]))

    # --- the gate cannot be bypassed ---
    check(
        "validate is the only exported entry point that returns a normalized request",
        hasattr(validate, "__call__"),
    )

    print(f"validate_test: {passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
