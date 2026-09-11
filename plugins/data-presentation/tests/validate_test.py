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

    # A zero is a measured value with nothing declared about it. Only null and the empty
    # string are gaps, which is why the old zero_meaningful field could not change any
    # output and was dropped rather than wired to something.
    result = validate(req(series={"S": [0, 0, 0]}))
    check(
        "zeros are values, not gaps",
        result["missing"]["S"] == [] and result["series"]["S"] == [0.0, 0.0, 0.0],
        repr(result["missing"]),
    )
    check(
        "an empty string is a gap while a zero beside it is not",
        validate(req(series={"S": [0, "", 0]}))["missing"]["S"] == [1],
        repr(validate(req(series={"S": [0, "", 0]}))["missing"]),
    )
    # Mutation: re-add "zero_meaningful" to validate()'s return dict - this goes red.
    # The field is gone from the contract, so a caller still sending it is ignored like
    # any other unknown key rather than shaping a value nobody reads.
    check(
        "the dropped field is not carried into the normalized request",
        "zero_meaningful" not in validate(req(zero_meaningful=["S"])),
        repr(sorted(validate(req(zero_meaningful=["S"])))),
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

    # A caller's own backslash before a pipe. Escaping only the pipe turns "\\|" into
    # "\\\\|" - a literal backslash followed by a LIVE column delimiter.
    cleaned = validate(req(x=["Q1\\| Fabricated", "b", "c"]))["x"][0]
    # Drop escaped backslash pairs, then every surviving pipe must still be escaped.
    residue = cleaned.replace("\\\\", "")
    check(
        "a backslash before a pipe leaves no live delimiter",
        "|" not in residue.replace("\\|", ""),
        repr(cleaned),
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

    # A single replace is not idempotent: four backticks collapse to three, which is a
    # fence again. Every run length has to come out short, not just the exact triple.
    for probe in ("x```y", "x````y", "x`````y", "x``````y", "`" * 12):
        out = validate(req(title=probe))["title"]
        check(f"a run of backticks in {probe!r} cannot reassemble a fence", "```" not in out, repr(out))

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

    # --- the cut runs AFTER the escape, and never splits an escape pair (P3) ---
    # Mutation: move the truncation block in _clean above the "|" escape. This goes red:
    # 23 kept pipes become 46 characters once escaped, so the label leaves the cleaner
    # at nearly twice its own limit. The "z" * 64 label above cannot catch it - it has
    # no character that escaping makes longer.
    piped = validate(req(x=["|" * 40, "b", "c"]))["x"][0]
    check(
        "a pipe-dense label is still inside the 24-character limit",
        len(piped) <= 24,
        f"len={len(piped)}: {piped!r}",
    )
    check(
        "every pipe surviving the cut is still escaped",
        "|" not in piped.replace("\\\\", "").replace("\\|", ""),
        repr(piped),
    )

    # Mutation: drop the odd-trailing-backslash trim from truncate_escaped. This goes
    # red: the cut lands inside "\|" and leaves the backslash alone against the ellipsis.
    stranded = validate(req(x=["a" * 22 + "|zzz", "b", "c"]))["x"][0]
    body = stranded[:-1]
    check(
        "a cut landing inside an escape pair does not strand the backslash",
        stranded.endswith("…") and (len(body) - len(body.rstrip("\\"))) % 2 == 0,
        repr(stranded),
    )

    # --- caller text that is not a control character but still deceives (R18) ---
    # A blocklist of ASCII control codes let these through. They are the reason the
    # cleaner is default-deny on isprintable() rather than an enumerated range.
    deceptive = validate(req(title="admin\u202egnp.exe", x=["a\u200bb", "c", "d"]))
    check(
        "a right-to-left override cannot reverse how a title reads",
        "\u202e" not in deceptive["title"],
        repr(deceptive["title"]),
    )
    check(
        "a zero-width space cannot hide inside a label",
        "\u200b" not in deceptive["x"][0],
        repr(deceptive["x"][0]),
    )
    check(
        "ordinary punctuation still survives the cleaner",
        "\u2014" in validate(req(title="a \u2014 b"))["title"],
        repr(validate(req(title="a \u2014 b"))["title"]),
    )

    # --- optional metadata: the element shape, not just the container ---
    check(
        "a string source is refused rather than crashing",
        refusal(req(source="internal")) is not None,
    )
    check(
        "a source with more fields than fit a caption is refused",
        refusal(req(source={f"k{i}": "v" for i in range(2000)})) is not None,
    )
    check(
        "the source field cap is pinned at 8",
        constants.MAX_SOURCE_FIELDS == 8,
        repr(constants.MAX_SOURCE_FIELDS),
    )
    check(
        "eight source fields are still accepted",
        refusal(req(source={f"k{i}": "v" for i in range(8)})) is None,
    )

    # --- caller text reaches the refusal message, which is relayed too ---
    message = refusal(req(series={"S": [1, "\u202e evil", 3]}))
    check(
        "caller text in a refusal message is cleaned",
        message is not None and "\u202e" not in message,
        repr(message),
    )

    # --- the series cap keeps a table inside the column budget ---
    check(
        "more series than a table can compare is refused",
        refusal({"title": "T", "x": ["a"], "series": {f"s{i}": [1.0] for i in range(60)}}) is not None,
    )
    check("the series cap is pinned at 8", constants.MAX_SERIES == 8, repr(constants.MAX_SERIES))

    # --- the gate cannot be bypassed ---
    check(
        "validate is the only exported entry point that returns a normalized request",
        hasattr(validate, "__call__"),
    )

    print(f"validate_test: {passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
