#!/usr/bin/env python3
"""Pairing: which logged call answers which source, in both modes."""

import os
import sys

TESTS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(TESTS), "scripts"))

import pairing  # noqa: E402
import sources  # noqa: E402
from sources import Stop  # noqa: E402

AMP = "mcp__fake_Amplitude__get_charts"
OTHER = "mcp__fake_rows__get_rows"

passed = failed = 0
ids = 0


def check(name, condition, detail=""):
    global passed, failed
    if condition:
        passed += 1
        print(f"  ok   - {name}")
    else:
        failed += 1
        print(f"  FAIL - {name}{(': ' + str(detail)[:600]) if detail else ''}", file=sys.stderr)


def call(tool, inp):
    global ids
    ids += 1
    return {"id": f"toolu_fake_{ids:04d}", "tool": tool, "input": inp, "timestamp": "2026-09-07T06:00:00.000Z",
            "has_result": True, "is_error": False, "text": "{}"}


def built(*specs):
    return sources.for_run({"blocks": [{"source": spec} for spec in specs]}, "rows", "dp-0000000000000000")


def tool(args, name=OTHER):
    return {"kind": "tool", "tool": name, "args": args}


def stop_of(found, calls, exact=True, verb="finish"):
    try:
        pairing.pair(found, calls, exact, verb)
    except Stop as stop:
        return stop
    return None


def test_ignore_lists():
    print("ignore lists")
    base = {"command": "fake-fetch"}
    noisy = dict(base, description="d", timeout=5, run_in_background=False, dangerouslyDisableSandbox=True)
    check("Bash ignores its four presentation keys", pairing._same("Bash", base, call("Bash", noisy)))
    check("Bash does not ignore any other key", not pairing._same("Bash", base, call("Bash", dict(base, cwd="/x"))))
    check("another tool keeps description", not pairing._same(OTHER, {"a": 1}, call(OTHER, {"a": 1, "description": "d"})))
    check("any Amplitude tool, in any case, ignores rationale",
          pairing._same(AMP, {"a": 1, "rationale": "x"}, call(AMP, {"a": 1, "rationale": "y"})))
    check("rationale counts for a tool that is not Amplitude",
          not pairing._same(OTHER, {"a": 1, "rationale": "x"}, call(OTHER, {"a": 1, "rationale": "y"})))
    check("a call to another tool is never the same", not pairing._same(OTHER, {"a": 1}, call(AMP, {"a": 1})))
    check("key order does not matter", pairing._same(OTHER, {"a": 1, "b": 2}, call(OTHER, {"b": 2, "a": 1})))


def test_diff():
    print("difference paths")
    found = pairing._diff({"a": {"b": 1}, "c": 1, "d": [1]}, {"a": {"b": 2}, "e": 1, "d": [2]})
    check("nested, removed, added and changed paths are named",
          found == [("changed", "a.b"), ("removed", "c"), ("changed", "d"), ("added", "e")], found)
    saved = {f"k{i}": i for i in range(9)}
    found_src = built(tool(saved))
    stop = stop_of(found_src, [call(OTHER, {})])
    check("more than six differences are counted, not listed", stop and "3 more" in str(stop) and "k6" not in str(stop), stop)
    check("the difference names paths, never values", stop and "removed k0" in str(stop), stop)


def test_exact():
    print("exact pairing")
    found = built(tool({"t": "a"}))
    older, newer = call(OTHER, {"t": "a"}), call(OTHER, {"t": "a"})
    check("an exact pair is found", stop_of(found, [older, call(OTHER, {"t": "b"}), newer]) is None)
    check("the latest equal call is used", found[0].call is newer)

    found = built(tool({"t": "a"}), tool({"t": "b"}))
    stop = stop_of(found, [call(OTHER, {"t": "a"})])
    check("a call used by one block is not a rival for another", stop and "Block 2" in str(stop) and "was not made" in str(stop), stop)

    found = built(tool({"t": "a"}))
    stop = stop_of(found, [call(OTHER, {"t": "b"}), call(OTHER, {"t": "c"})])
    check("two unequal candidates name no difference", stop and "was not made" in str(stop) and "changed" not in str(stop), stop)

    found = built({"kind": "command", "command": "fake-fetch --out {output}"})
    command = found[0].args["command"]
    equal, other = call("Bash", {"command": command}), call("Bash", {"command": command + " --extra"})
    stop = stop_of(found, [equal, other])
    check("a command pairs with the last call that writes its path, not the last equal one",
          stop and "not the saved call" in str(stop) and stop.next == "make_calls", stop)
    check("a changed command is not echoed", stop and "--extra" not in str(stop), stop)

    found = built({"kind": "file", "path": "/fake/data.json"})
    check("a file source needs no call", stop_of(found, []) is None and found[0].call is None)


def test_save_wording():
    print("save wording")
    found = built(tool({"t": "a"}))
    stop = stop_of(found, [], verb="save")
    check("no candidate keeps save's compaction wording", stop and "compacted or cleared" in str(stop), stop)
    found = built(tool({"t": "a"}))
    stop = stop_of(found, [call(OTHER, {"t": "b"})], verb="save")
    check("one candidate names the difference for save", stop and "changed t" in str(stop) and "run save again" in str(stop), stop)
    check("save's difference never mentions finish or prepare", stop and "finish" not in str(stop) and "prepare" not in str(stop), stop)


def test_loose():
    print("loose pairing")
    found = built(tool({"t": "a", "r": 1}), tool({"t": "b", "r": 1}))
    a, b = call(OTHER, {"t": "a", "r": 2}), call(OTHER, {"t": "b", "r": 2})
    check("reverse-order calls pair by closeness", stop_of(found, [b, a], exact=False) is None)
    check("each source gets its own closest call", found[0].call is a and found[1].call is b)

    found = built(tool({"t": "a", "r": 1}), tool({"t": "b", "r": 1}))
    stop = stop_of(found, [call(OTHER, {"t": "b", "r": 1}), call(OTHER, {"t": "a", "r": 2}), call(OTHER, {"t": "a", "r": 3})],
                   exact=False)
    check("two calls equally close stop", stop and stop.next == "make_calls" and "Block 1" in str(stop), stop)

    found = built(tool({"t": "a"}))
    retry_one, retry_two = call(OTHER, {"t": "z"}), call(OTHER, {"t": "z"})
    check("a single source takes the latest call to its tool", stop_of(found, [retry_one, retry_two], exact=False) is None
          and found[0].call is retry_two)

    found = built(tool({"t": "a"}), tool({"t": "b"}))
    stop = stop_of(found, [call(OTHER, {"t": "q"})], exact=False)
    check("fewer calls than sources names the unpaired block", stop and "Block 2" in str(stop) and "was not made" in str(stop), stop)

    found = built({"kind": "command", "command": "fake-fetch --out {output}"})
    changed = call("Bash", {"command": found[0].args["command"] + " --extra"})
    check("a variation's command may differ from the saved one", stop_of(found, [changed], exact=False) is None
          and found[0].call is changed)


def main():
    for test in (test_ignore_lists, test_diff, test_exact, test_save_wording, test_loose):
        try:
            test()
        except Exception as exc:  # noqa: BLE001
            import traceback
            traceback.print_exc()
            check(f"{test.__name__} ran to the end", False, repr(exc))
    print(f"pairing_test: {passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
