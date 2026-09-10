#!/usr/bin/env python3
"""U5: output verification and response assembly. A clean call is not proof of a render."""

import json
import os
import subprocess
import sys

SCRIPTS = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts")
sys.path.insert(0, SCRIPTS)

import present  # noqa: E402
import render  # noqa: E402

passed = failed = 0


def check(name, condition, detail=""):
    global passed, failed
    if condition:
        passed += 1
        print(f"  ok   - {name}")
    else:
        failed += 1
        print(f"  FAIL - {name}{(': ' + detail) if detail else ''}", file=sys.stderr)


def run_cli(payload):
    """Drive the real entry point the skill invokes, not just the function."""
    proc = subprocess.run(
        [sys.executable, os.path.join(SCRIPTS, "present.py")],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
    )
    return proc, (json.loads(proc.stdout) if proc.stdout.strip() else None)


def series(n, name="S"):
    return {
        "title": "T",
        "x": [f"p{i}" for i in range(n)],
        "series": {name: [float(i % 13) for i in range(n)]},
    }


def main():
    # --- the happy path, through the real CLI ---
    proc, out = run_cli(series(9))
    check("a valid request exits zero", proc.returncode == 0, proc.stderr[:200])
    check("a valid request is not a refusal", out and out["status"] == "ok", repr(out and out.get("status")))
    check("the response carries a rendered block", out and out["block"].strip() != "")
    check("the response names the form used", out and out["form"] in ("table", "charts"), repr(out and out.get("form")))

    # --- the relay contract travels with the payload (KTD8) ---
    check("the response carries a relay instruction", out and out.get("relay"), repr(out and out.get("relay")))
    check(
        "the relay instruction is imperative about what not to do",
        out and "not" in out["relay"].lower(),
        repr(out and out.get("relay")),
    )

    # --- refusals are normal responses, not faults (R13) ---
    proc, out = run_cli({"title": "T", "x": ["a", "b"], "series": {"S": [1]}})
    check("a refusal still exits zero", proc.returncode == 0, proc.stderr[:200])
    check("a refusal is marked as one", out and out["status"] == "refused", repr(out and out.get("status")))
    check("a refusal names the problem", out and "2" in out["message"] and "1" in out["message"], repr(out and out.get("message")))
    check("a refusal carries no block", out and not out.get("block"), repr(out and out.get("block")))
    check("a refusal still carries the relay instruction", out and out.get("relay"), repr(out and out.get("relay")))

    # --- a fault is distinguishable from a refusal ---
    proc = subprocess.run(
        [sys.executable, os.path.join(SCRIPTS, "present.py")],
        input="{not json",
        capture_output=True,
        text=True,
    )
    check("malformed input exits non-zero", proc.returncode != 0, f"rc={proc.returncode}")

    # --- output verification (R14, KTD7): an empty render must become a refusal ---
    real_chart = render.chart_with_meta

    render.chart_with_meta = lambda request, name: ("", {"rendered": 0, "omitted": 0, "full_min": 0, "full_max": 0,
                                                        "kept_first": True, "kept_last": True,
                                                        "kept_missing_positions": [], "series": name})
    result = present.present(series(9))
    check(
        "an empty render becomes a refusal, not an empty success",
        result["status"] == "refused",
        repr(result.get("status")),
    )

    render.chart_with_meta = lambda request, name: ("no axis here at all", {"rendered": 1, "omitted": 0,
                                                                           "full_min": 0, "full_max": 1,
                                                                           "kept_first": True, "kept_last": True,
                                                                           "kept_missing_positions": [], "series": name})
    result = present.present(series(9))
    check(
        "a render missing the axis glyph becomes a refusal",
        result["status"] == "refused",
        repr(result.get("status")),
    )
    render.chart_with_meta = real_chart

    # The table path has no axis glyph to check, so the empty-block guard is the only
    # thing standing there. Without this the guard is dead code the chart check covers.
    real_table = render.table_with_meta
    render.table_with_meta = lambda request, names=None: ("", {"rendered": 0, "omitted": 0})
    result = present.present({"title": "T", "x": ["a", "b"], "series": {"S": [1.0, 2.0]}})
    check(
        "an empty table render becomes a refusal too",
        result["status"] == "refused",
        repr(result.get("status")),
    )
    render.table_with_meta = real_table

    # --- notes report what was left out (R7, R8) ---
    payload = series(400)
    _, out = run_cli(payload)
    joined = " ".join(out["notes"])
    check("the omitted point count is reported", "omitted" in joined.lower() or "left out" in joined.lower(), joined[:200])
    check("the notes state that nothing was averaged", "averag" in joined.lower(), joined[:200])
    check("the notes report the full range", "range" in joined.lower() or "to" in joined.lower(), joined[:200])

    payload = series(9)
    payload["series"]["S"][3] = None
    _, out = run_cli(payload)
    check(
        "the notes name the missing position",
        any("4" in n for n in out["notes"]),
        repr(out["notes"]),
    )

    # --- an overridden form names both (R3) ---
    payload = series(5)
    payload["type"] = "chart"
    _, out = run_cli(payload)
    check("a too-short chart request falls back to a table", out["form"] == "table", repr(out["form"]))
    check(
        "the notes name the requested form and why it was not used",
        any("chart" in n.lower() for n in out["notes"]),
        repr(out["notes"]),
    )

    # --- metadata, with no placeholders leaking ---
    payload = series(9)
    payload["units"] = "users"
    _, out = run_cli(payload)
    check("the metadata carries the series names", out["metadata"]["series"] == ["S"], repr(out["metadata"]))
    check("the metadata carries the units", out["metadata"]["units"] == "users", repr(out["metadata"]))
    _, out = run_cli(series(9))
    check(
        "an absent unit is omitted rather than rendered as a placeholder",
        "None" not in json.dumps(out["metadata"]) and "undefined" not in json.dumps(out["metadata"]),
        repr(out["metadata"]),
    )

    print(f"present_test: {passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
