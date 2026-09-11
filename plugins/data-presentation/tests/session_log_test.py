#!/usr/bin/env python3
"""U1: the session log reader. Finds a tool call and its result in the current session log, exactly and only there."""

import glob
import hashlib
import json
import os
import re
import shutil
import signal
import sys
import tempfile

TESTS = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.path.join(TESTS, "fixtures")
SCRIPTS = os.path.join(os.path.dirname(TESTS), "scripts")
sys.path.insert(0, SCRIPTS)

import session_log  # noqa: E402
from session_log import LogError  # noqa: E402

SID = "00000000-0000-4000-8000-000000000001"
MARKER = "dp-fixture-marker-0001"
AMP = "mcp__plugin_amplitude_amplitude__query_amplitude_data"

# Hashes, not literals, so the real values this guard exists to keep out never enter the public repo.
FORBIDDEN_SHA256 = {
    8: "6dba4b006cd64ffdc496602f37a51279376d96f037827cead1117de3e70403e1",
    36: "46d9e5c834f0b27b44c95a0f300cbc4df9906aa2320e6002e886f1c8b61023c6",
}
FAKE_UUID = re.compile(r"00000000-0000-4000-8000-\d{12}")
ANY_UUID = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")

passed = failed = 0


def check(name, condition, detail=""):
    global passed, failed
    if condition:
        passed += 1
        print(f"  ok   - {name}")
    else:
        failed += 1
        print(f"  FAIL - {name}{(': ' + detail) if detail else ''}", file=sys.stderr)


def fixture_leaks(text, forbidden=FORBIDDEN_SHA256):
    hits = []
    if "/Users/" in text:
        hits.append("/Users/ path")
    for size, digest in forbidden.items():
        for i in range(len(text) - size + 1):
            if hashlib.sha256(text[i : i + size].encode()).hexdigest() == digest:
                hits.append(f"a forbidden {size}-character value at offset {i}")
                break
    for found in ANY_UUID.findall(text):
        if not FAKE_UUID.fullmatch(found):
            hits.append(f"a uuid that is not an obvious fake: {found[:8]}...")
    return hits


def raises(fn, kind):
    try:
        fn()
    except LogError as e:
        return e.kind == kind, e
    except Exception as e:  # noqa: BLE001
        return False, e
    return False, None


class Timeout(Exception):
    pass


def within(seconds, fn):
    def on_alarm(signum, frame):
        raise Timeout()

    old = signal.signal(signal.SIGALRM, on_alarm)
    signal.alarm(seconds)
    try:
        return fn(), None
    except Timeout:
        return None, "timed out"
    except Exception as e:  # noqa: BLE001
        return None, repr(e)
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, old)


def uid(n):
    return f"00000000-0000-4000-8000-{n:012d}"


def line(n, parent, typ, content=None, **extra):
    d = {"parentUuid": parent, "isSidechain": False, "type": typ, "uuid": uid(n), "timestamp": f"2000-01-01T00:01:{n:02d}.000Z"}
    if content is not None:
        d["message"] = {"role": "assistant" if typ == "assistant" else "user", "content": content}
    d.update(extra)
    return d


def use(n, parent, tid, name="Bash", inp=None):
    return line(n, parent, "assistant", [{"type": "tool_use", "id": tid, "name": name, "input": inp or {"command": "true"}}])


def res(n, parent, tid, content, is_error=False):
    return line(n, parent, "user", [{"type": "tool_result", "tool_use_id": tid, "content": content, "is_error": is_error}])


class Project:
    def __init__(self, root):
        self.root = root
        self.projects = os.path.join(root, "projects")
        self.folder = os.path.join(self.projects, "-tmp-fixture-project")
        os.makedirs(self.folder)
        self.path = os.path.join(self.folder, SID + ".jsonl")
        self.session_dir = self.path[: -len(".jsonl")]
        self.results_dir = os.path.join(self.session_dir, "tool-results")
        os.makedirs(self.results_dir)

    def write(self, lines, tail=""):
        with open(self.path, "w") as f:
            for item in lines:
                f.write(item if isinstance(item, str) else json.dumps(item) + "\n")
            f.write(tail)
        return self.path

    def write_main_fixture(self):
        with open(os.path.join(FIXTURES, "session_main.jsonl")) as f:
            text = f.read().replace("@SESSION_DIR@", self.session_dir)
        with open(self.path, "w") as f:
            f.write(text)
        shutil.copy(os.path.join(FIXTURES, "session_spill.txt"), os.path.join(self.results_dir, "toolu_fixture_spill.txt"))
        return self.path

    def write_subagent(self, lines):
        sub = os.path.join(self.session_dir, "subagents")
        os.makedirs(sub, exist_ok=True)
        with open(os.path.join(sub, "agent-fixture0001.jsonl"), "w") as f:
            for item in lines:
                f.write(json.dumps(item) + "\n")


def spilled(project, n, target):
    notice = (
        "<persisted-output>\nOutput too large (40.0KB). Full output saved to: "
        f"{target}\n\nPreview (first 2KB):\nfixture preview\n</persisted-output>"
    )
    return [
        use(1, None, "toolu_s", "Bash", {"command": "cat fixture-big"}),
        res(2, uid(1), "toolu_s", notice),
        use(3, uid(2), "toolu_fin", "Bash", {"command": f"finish {MARKER}-{n}"}),
    ]


def text_of_spill(project, n, target):
    log = session_log.load(project.write(spilled(project, n, target)))
    entry = log.find_invocation(f"{MARKER}-{n}")
    return log.calls(log.branch(entry))


def test_fixture_guard():
    files = sorted(glob.glob(os.path.join(FIXTURES, "session_*")))
    check("the fixture guard has fixture files to scan", len(files) >= 2, repr(files))
    for path in files:
        with open(path, encoding="utf-8") as f:
            hits = fixture_leaks(f.read())
        check(f"{os.path.basename(path)} carries no real value", not hits, "; ".join(hits))
    check("the fixture guard catches a /Users/ path", fixture_leaks('{"cwd": "/Users/someone/x"}'))
    check("the fixture guard catches a uuid that is not an obvious fake", fixture_leaks("12345678-1234-4234-8234-123456789abc"))
    probe = {5: hashlib.sha256(b"zq7x9").hexdigest()}
    check("the fixture guard's hash match fires on a planted value", fixture_leaks("..zq7x9..", probe))
    check("the fixture guard's hash match stays quiet without it", not fixture_leaks("..zq7x8..", probe))


def test_find_log(tmp):
    project = Project(os.path.join(tmp, "find"))
    project.write([use(1, None, "toolu_a")])
    elsewhere = os.path.join(tmp, "elsewhere")
    launch_sub = os.path.join(tmp, "fixture-project", "sub", "dir")
    os.makedirs(elsewhere)
    os.makedirs(launch_sub)
    saved_cwd = os.getcwd()
    saved_env = os.environ.get("CLAUDE_CODE_SESSION_ID")
    try:
        os.chdir(elsewhere)
        os.environ["CLAUDE_CODE_SESSION_ID"] = SID
        found = session_log.find_log(projects_root=project.projects)
        check("the log is found by id alone from an unrelated directory", found == project.path, repr(found))
        os.chdir(launch_sub)
        found = session_log.find_log(projects_root=project.projects)
        check("the log is found from a subdirectory of the launch directory", found == project.path, repr(found))
        os.environ["CLAUDE_CODE_SESSION_ID"] = "00000000-0000-4000-8000-000000000999"
        check(
            "an explicit session id wins over the variable",
            session_log.find_log(SID, project.projects) == project.path,
        )

        os.environ.pop("CLAUDE_CODE_SESSION_ID")
        ok, e = raises(lambda: session_log.find_log(projects_root=project.projects), "no_session")
        check("an unset session variable stops as no_session", ok, repr(e))
        check("the no_session message names the variable", e is not None and "CLAUDE_CODE_SESSION_ID" in str(e), str(e))
        os.environ["CLAUDE_CODE_SESSION_ID"] = ""
        ok, e = raises(lambda: session_log.find_log(projects_root=project.projects), "no_session")
        check("an empty session variable stops as no_session", ok, repr(e))

        ok, e = raises(lambda: session_log.find_log("00000000-0000-4000-8000-000000000999", project.projects), "not_found")
        check("no matching log stops as not_found", ok, repr(e))
        ok, e = raises(lambda: session_log.find_log("*", project.projects), "not_found")
        check("a glob pattern as the id matches nothing", ok, repr(e))

        other = os.path.join(project.projects, "-tmp-other-project")
        os.makedirs(other)
        shutil.copy(project.path, os.path.join(other, SID + ".jsonl"))
        ok, e = raises(lambda: session_log.find_log(SID, project.projects), "ambiguous")
        check("two logs with one id stop as ambiguous", ok, repr(e))
    finally:
        os.chdir(saved_cwd)
        if saved_env is None:
            os.environ.pop("CLAUDE_CODE_SESSION_ID", None)
        else:
            os.environ["CLAUDE_CODE_SESSION_ID"] = saved_env


def test_main_fixture(tmp):
    project = Project(os.path.join(tmp, "main"))
    log = session_log.load(project.write_main_fixture())
    entry = log.find_invocation(MARKER)
    check("the finish call is found by its marker", entry and entry["uuid"] == uid(19), repr(entry and entry.get("uuid")))
    branch = log.branch(entry)
    ids = [e.get("uuid") for e in branch]
    check("the branch is oldest-first", ids[0] == uid(1) and ids[-1] == uid(19), repr(ids[:1] + ids[-1:]))
    check("the branch crosses the compaction boundary", uid(12) in ids and uid(5) in ids, repr(ids))
    check("the branch passes through line types other than user and assistant", uid(6) in ids and uid(11) in ids, repr(ids))
    check("the abandoned branch is not on the branch", uid(7) not in ids and uid(8) not in ids, repr(ids))

    calls = log.calls(branch, after_text=MARKER)
    got = [c["id"] for c in calls]
    check(
        "only calls after prepare, on the current branch, are returned",
        got == ["toolu_fixture_amp", "toolu_fixture_spill", "toolu_fixture_err", "toolu_fixture_pending"],
        repr(got),
    )
    check("a call made before prepare is not returned", "toolu_fixture_early" not in got, repr(got))
    check("the prepare call itself is not returned", "toolu_fixture_prep" not in got, repr(got))
    check("a call on the abandoned branch is not returned", "toolu_fixture_abandoned" not in got, repr(got))
    check("the invoking call is not returned", "toolu_fixture_finish" not in got, repr(got))

    unbounded = [c["id"] for c in log.calls(branch)]
    check(
        "without a bound every branch call but the invoking one is returned",
        unbounded
        == ["toolu_fixture_early", "toolu_fixture_prep", "toolu_fixture_amp", "toolu_fixture_spill", "toolu_fixture_err", "toolu_fixture_pending"],
        repr(unbounded),
    )

    by_id = {c["id"]: c for c in calls}
    amp = by_id.get("toolu_fixture_amp", {})
    with open(project.path) as f:
        raw = [json.loads(x) for x in f]
    fixture_use = raw[9]["message"]["content"][0]
    fixture_result = raw[10]["message"]["content"][0]
    inner = json.loads(fixture_result["content"])["content"][0]["text"]
    check("the Amplitude call is found by tool name", amp.get("tool") == AMP, repr(amp.get("tool")))
    check("its arguments equal the fixture's", amp.get("input") == fixture_use["input"], repr(amp.get("input")))
    check("its result text is the innermost text of the MCP envelope", amp.get("text") == inner, repr(amp.get("text"))[:200])
    check("the innermost text is the result JSON", json.loads(amp.get("text", "{}")).get("success") is True)
    check("the reply time is the result line's timestamp", amp.get("timestamp") == raw[10]["timestamp"], repr(amp.get("timestamp")))
    check("a returned call has its result", amp.get("has_result") is True and amp.get("is_error") is False, repr(amp))

    spill = by_id.get("toolu_fixture_spill", {})
    with open(os.path.join(FIXTURES, "session_spill.txt")) as f:
        spill_text = f.read()
    check("a spilled result returns the full file text", spill.get("text") == spill_text, repr(spill.get("text"))[:200])
    check("a spilled result does not return the notice", "<persisted-output>" not in (spill.get("text") or ""))

    err = by_id.get("toolu_fixture_err", {})
    check("an is_error result returns the error flag set", err.get("is_error") is True, repr(err))
    check("an error result's text is kept", err.get("text") == "Error: fixture source failed", repr(err.get("text")))

    pending = by_id.get("toolu_fixture_pending", {})
    check("a call with no result yet has has_result False", pending.get("has_result") is False, repr(pending))
    check("a call with no result yet has no timestamp", pending.get("timestamp") is None, repr(pending))

    prep = log.calls(branch)[1]
    check("a plain Bash result is returned as is", prep["text"].startswith(f"MARKER {MARKER}"), repr(prep["text"]))


def test_loops(tmp):
    project = Project(os.path.join(tmp, "loop"))
    # The shape seen in a real log: the boundary's logical parent is its own descendant.
    lines = [
        line(1, None, "system", subtype="compact_boundary", logicalParentUuid=uid(3)),
        line(2, uid(1), "user", "fixture summary", isCompactSummary=True),
        line(3, uid(2), "attachment", attachment={"type": "fixture"}),
        use(4, uid(3), "toolu_a"),
        res(5, uid(4), "toolu_a", "fixture a"),
        use(6, uid(5), "toolu_fin", "Bash", {"command": f"finish {MARKER}"}),
    ]
    log = session_log.load(project.write(lines))
    entry = log.find_invocation(MARKER)
    branch, problem = within(3, lambda: log.branch(entry))
    check("a compaction link back to a descendant terminates", problem is None, problem or "")
    if branch is not None:
        check("the looped walk keeps each line once", len(branch) == len({e["uuid"] for e in branch}) == 6, repr(len(branch)))
        check("the looped walk still yields the calls", [c["id"] for c in log.calls(branch)] == ["toolu_a"])

    cycle = [
        line(1, uid(2), "user", "fixture a"),
        line(2, uid(1), "user", "fixture b"),
        use(3, uid(2), "toolu_fin", "Bash", {"command": f"finish {MARKER}"}),
    ]
    log = session_log.load(project.write(cycle))
    branch, problem = within(3, lambda: log.branch(log.find_invocation(MARKER)))
    check("a plain parent cycle terminates", problem is None and branch is not None and len(branch) == 3, problem or repr(branch and len(branch)))

    dangling = [use(1, uid(77), "toolu_fin", "Bash", {"command": f"finish {MARKER}"})]
    log = session_log.load(project.write(dangling))
    branch = log.branch(log.find_invocation(MARKER))
    check("a parent that is not in the log ends the walk", [e["uuid"] for e in branch] == [uid(1)])


def test_invocation_lookup(tmp):
    project = Project(os.path.join(tmp, "sub"))
    main = [line(1, None, "user", "fixture prompt"), use(2, uid(1), "toolu_other", "Bash", {"command": "echo fixture"})]
    project.write(main)
    project.write_subagent(
        [
            line(1, None, "user", "fixture subagent prompt", isSidechain=True),
            use(2, uid(1), "toolu_sub_fin", "Bash", {"command": f"finish {MARKER}"}),
        ]
    )
    log = session_log.load(project.path)
    ok, e = raises(lambda: log.find_invocation(MARKER), "subagent")
    check("a marker found only under subagents/ returns the subagent stop", ok, repr(e))
    check("the subagent message says reports only run in the main session", e is not None and "main session" in str(e), str(e))
    ok, e = raises(lambda: log.find_invocation("dp-fixture-marker-absent"), "no_invocation")
    check("a marker found nowhere stops as no_invocation", ok, repr(e))

    project.write(
        main
        + [
            use(3, uid(2), "toolu_first_fin", "Bash", {"command": f"finish {MARKER}"}),
            res(4, uid(3), "toolu_first_fin", "fixture first run"),
            use(5, uid(4), "toolu_second_fin", "Bash", {"command": f"finish {MARKER}"}),
        ]
    )
    project.write_subagent(
        [
            use(1, None, "toolu_sub_call", AMP, {"chartId": "chart-dddd"}),
            res(2, uid(1), "toolu_sub_call", "fixture subagent result"),
            use(3, uid(2), "toolu_sub_fin", "Bash", {"command": f"finish {MARKER}"}),
        ]
    )
    log = session_log.load(project.path)
    entry = log.find_invocation(MARKER)
    check("the latest matching Bash call wins", entry["uuid"] == uid(5), repr(entry.get("uuid")))
    got = [c["id"] for c in log.calls(log.branch(entry))]
    check("a call under subagents/ is never returned", "toolu_sub_call" not in got, repr(got))
    check("the main log's calls are returned", got == ["toolu_other", "toolu_first_fin"], repr(got))

    project.write([use(1, None, "toolu_read", "Read", {"file_path": f"/tmp/{MARKER}"})])
    ok, e = raises(lambda: session_log.load(project.path).find_invocation(MARKER), "subagent")
    check("only a Bash command counts as the invocation", ok, repr(e))


def test_persisted_output(tmp):
    project = Project(os.path.join(tmp, "spill"))
    inside = os.path.join(project.results_dir, "toolu_s.txt")
    with open(inside, "w") as f:
        f.write("fixture full text\n")
    calls = text_of_spill(project, 1, inside)
    check("a notice inside tool-results/ is followed", calls[0]["text"] == "fixture full text\n", repr(calls[0]["text"]))

    envelope_file = os.path.join(project.results_dir, "toolu_env.txt")
    with open(envelope_file, "w") as f:
        f.write(json.dumps({"content": [{"type": "text", "text": '{"fixture": 1}'}]}))
    calls = text_of_spill(project, 2, envelope_file)
    check("a spilled MCP envelope is unwrapped too", calls[0]["text"] == '{"fixture": 1}', repr(calls[0]["text"]))

    outside = os.path.join(tmp, "outside.txt")
    with open(outside, "w") as f:
        f.write("fixture outside text\n")
    ok, e = raises(lambda: text_of_spill(project, 3, outside), "unreadable")
    check("a notice pointing outside the session directory is refused", ok, repr(e))

    beside = os.path.join(project.session_dir, "beside.txt")
    shutil.copy(outside, beside)
    ok, e = raises(lambda: text_of_spill(project, 4, beside), "unreadable")
    check("a notice pointing into the session directory but not tool-results/ is refused", ok, repr(e))

    link = os.path.join(project.results_dir, "toolu_link.txt")
    os.symlink(outside, link)
    ok, e = raises(lambda: text_of_spill(project, 5, link), "unreadable")
    check("a symlink inside tool-results/ that leads outside is refused", ok, repr(e))

    ok, e = raises(lambda: text_of_spill(project, 6, os.path.join(project.results_dir, "..", "beside.txt")), "unreadable")
    check("a dotdot path out of tool-results/ is refused", ok, repr(e))

    sub_dir = os.path.join(project.session_dir, "subagents")
    os.makedirs(sub_dir, exist_ok=True)
    sub_file = os.path.join(sub_dir, "agent-fixture.txt")
    shutil.copy(outside, sub_file)
    ok, e = raises(lambda: text_of_spill(project, 7, sub_file), "unreadable")
    check("a path under subagents/ is never read", ok, repr(e))

    ok, e = raises(lambda: text_of_spill(project, 8, os.path.join(project.results_dir, "missing.txt")), "unreadable")
    check("a notice whose file is missing stops as unreadable", ok, repr(e))

    quoted = "grep output that mentions <persisted-output> in passing"
    log = session_log.load(
        project.write(
            [
                use(1, None, "toolu_q", "Bash", {"command": "grep fixture"}),
                res(2, uid(1), "toolu_q", quoted),
                use(3, uid(2), "toolu_fin", "Bash", {"command": f"finish {MARKER}"}),
            ]
        )
    )
    calls = log.calls(log.branch(log.find_invocation(MARKER)))
    check("a result that only mentions the tag is not treated as a notice", calls[0]["text"] == quoted, repr(calls[0]["text"]))


def test_load(tmp):
    project = Project(os.path.join(tmp, "load"))
    good = [line(1, None, "user", "fixture prompt"), use(2, uid(1), "toolu_fin", "Bash", {"command": f"finish {MARKER}"})]
    partial = json.dumps(res(3, uid(2), "toolu_fin", "fixture"))[:40]
    try:
        log, problem = session_log.load(project.write(good, tail=partial)), None
    except LogError as e:
        log, problem = None, repr(e)
    check("a partial last line still being written is ignored", log is not None and len(log.entries) == 2, problem or "")
    check("the log still reads after a partial last line", log is not None and log.find_invocation(MARKER)["uuid"] == uid(2))

    log = session_log.load(project.write(good, tail=json.dumps(res(3, uid(2), "toolu_fin", "fixture"))))
    check("a complete last line without a newline is kept", len(log.entries) == 3, repr(len(log.entries)))

    ok, e = raises(lambda: session_log.load(project.write([good[0], "{not json\n", good[1]])), "unreadable")
    check("a broken line in the middle stops as unreadable", ok, repr(e))
    ok, e = raises(lambda: session_log.load(project.write(good + ["{not json\n"])), "unreadable")
    check("a finished last line that is not JSON stops as unreadable", ok, repr(e))

    blank = session_log.load(project.write([good[0], "\n", good[1]]))
    check("a blank line is skipped", len(blank.entries) == 2, repr(len(blank.entries)))

    unknown = [
        good[0],
        {"type": "fixture-unknown-type", "uuid": uid(5), "parentUuid": uid(1), "message": {"content": [{"type": "tool_use"}]}},
        use(6, uid(5), "toolu_fin", "Bash", {"command": f"finish {MARKER}"}),
    ]
    log = session_log.load(project.write(unknown))
    entry = log.find_invocation(MARKER)
    branch = log.branch(entry)
    check("a line of an unknown type is skipped for calls", log.calls(branch) == [], repr(log.calls(branch)))
    check("a line of an unknown type still links the branch", [e["uuid"] for e in branch] == [uid(1), uid(5), uid(6)])

    broken_use = [line(1, None, "assistant", [{"type": "tool_use", "id": "toolu_x", "input": {}}]), good[1]]
    ok, e = raises(lambda: session_log.load(project.write(broken_use)).find_invocation(MARKER), "unreadable")
    check("a tool_use block without a name stops as unreadable", ok, repr(e))
    check("the unreadable message says it cannot read this session log", e is not None and "cannot read this session log" in str(e), str(e))
    check("the unreadable stop is not a call-not-found stop", e is not None and getattr(e, "kind", None) != "no_invocation", repr(e))

    broken_result = [good[0], good[1], line(3, uid(2), "user", [{"type": "tool_result", "tool_use_id": "toolu_fin", "content": 7}])]
    ok, e = raises(lambda: session_log.load(project.write(broken_result)), "unreadable")
    check("a tool_result block with unparseable content stops as unreadable", ok, repr(e))

    no_message = [good[0], {"type": "assistant", "uuid": uid(4), "parentUuid": uid(1)}, good[1]]
    ok, e = raises(lambda: session_log.load(project.write(no_message)), "unreadable")
    check("an assistant line without a message stops as unreadable", ok, repr(e))

    bad_envelope = [
        use(1, None, "toolu_m", AMP, {"chartId": "chart-eeee"}),
        res(2, uid(1), "toolu_m", '{"content": [{"type": "text", "text": "not json inside"}]}'),
        use(3, uid(2), "toolu_n", AMP, {"chartId": "chart-ffff"}),
        res(4, uid(3), "toolu_n", '{"results": [1, 2]}'),
        use(5, uid(4), "toolu_fin", "Bash", {"command": f"finish {MARKER}"}),
    ]
    log = session_log.load(project.write(bad_envelope))
    calls = log.calls(log.branch(log.find_invocation(MARKER)))
    check("an envelope's inner text is returned even when it is not JSON", calls[0]["text"] == "not json inside", repr(calls[0]["text"]))
    check("a JSON result that is not an envelope is returned as is", calls[1]["text"] == '{"results": [1, 2]}', repr(calls[1]["text"]))

    filler = "fixture filler line\n" * 1500
    long_bash = [
        use(1, None, "toolu_long", "Bash", {"command": "fixture long output"}),
        res(2, uid(1), "toolu_long", filler),
        use(3, uid(2), "toolu_fin", "Bash", {"command": f"finish {MARKER}"}),
    ]
    log = session_log.load(project.write(long_bash))
    calls = log.calls(log.branch(log.find_invocation(MARKER)))
    check("a long Bash result is returned whole", calls[0]["text"] == filler, repr(len(calls[0]["text"])))


def test_log_error():
    e = LogError("not_found", "no session log matched")
    check("LogError carries its kind", e.kind == "not_found")
    check("LogError carries its message", str(e) == "no session log matched", str(e))
    check("LogError is an Exception", isinstance(e, Exception))


def main():
    tmp = os.path.realpath(tempfile.mkdtemp(prefix="session-log-test-"))
    try:
        test_fixture_guard()
        test_log_error()
        test_find_log(tmp)
        test_main_fixture(tmp)
        test_loops(tmp)
        test_invocation_lookup(tmp)
        test_persisted_output(tmp)
        test_load(tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print(f"session_log_test: {passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
