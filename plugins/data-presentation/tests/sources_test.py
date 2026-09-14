#!/usr/bin/env python3
"""Sources: built once per template, and each reads only data this run can vouch for."""

import datetime
import os
import shutil
import sys
import tempfile

TESTS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(TESTS), "scripts"))

import sources  # noqa: E402
from sources import CommandSource, FileSource, Stop, ToolSource  # noqa: E402

UTC = datetime.timezone.utc
RESULT_AT = datetime.datetime(2026, 9, 7, 6, 0, tzinfo=UTC)
STARTED_AT = datetime.datetime(2026, 9, 7, 5, 58, tzinfo=UTC)
PREPARED_AT = datetime.datetime(2026, 9, 7, 5, 0, tzinfo=UTC)
COMMAND = {"kind": "command", "command": "fake-fetch --out {output}"}

passed = failed = 0


def check(name, condition, detail=""):
    global passed, failed
    if condition:
        passed += 1
        print(f"  ok   - {name}")
    else:
        failed += 1
        print(f"  FAIL - {name}{(': ' + str(detail)[:600]) if detail else ''}", file=sys.stderr)


def stamp(at):
    return at.strftime("%Y-%m-%dT%H:%M:%S.000Z") if at else None


def result(tool="Bash", inp=None, is_error=False, at=RESULT_AT, started=STARTED_AT):
    return {"id": "toolu_fake_0001", "tool": tool, "input": inp if inp is not None else {}, "has_result": True,
            "is_error": is_error, "text": "fake reply", "started_at": stamp(started), "timestamp": stamp(at)}


def write(path, text="fake rows", at=None):
    with open(path, "w") as f:
        f.write(text)
    if at is not None:
        os.utime(path, (at.timestamp(), at.timestamp()), follow_symlinks=False)


def stop_of(source, *args, **kwargs):
    try:
        source.read(*args, **kwargs)
    except Stop as stop:
        return stop
    return None


def open_fds():
    return len(os.listdir("/dev/fd"))


def command_at(path, call=None):
    source = CommandSource(COMMAND, 1, path)
    source.blocks = [1]
    source.call = call or result()
    return source


def test_build(home):
    print("building sources")
    os.environ["HOME"] = home
    tool = {"kind": "tool", "tool": "mcp__fake_rows__get_rows", "args": {"t": "a"}}
    template = {"blocks": [{"source": tool}, {"source": COMMAND}, {"source": dict(tool)},
                           {"source": {"kind": "file", "path": "/fake/data.json"}}]}
    found = sources.for_run(template, "rows", "dp-0123456789abcdef")
    check("one source per distinct source, in first-use order",
          [type(s) for s in found] == [ToolSource, CommandSource, FileSource], found)
    check("a shared source serves every block that uses it", found[0].blocks == [1, 3], found[0].blocks)
    check("the two-block source is named in the plural", found[0].which() == "Blocks 1 and 3", found[0].which())
    check("the index counts sources, not blocks", [s.index for s in found] == [1, 2, 3])
    out = os.path.join(home, ".claude", "data-presentation", "out", "rows-dp-0123456789abcdef-2.json")
    check("a run's command output is named from the name, marker and source index", found[1].output == out, found[1].output)
    check("prepare lists each source's call", [s.listed_call() for s in found] == [
        {"tool": tool["tool"], "args": {"t": "a"}},
        {"command": f"fake-fetch --out {out}"},
        {"file": "/fake/data.json"},
    ], [s.listed_call() for s in found])
    check("a file source expects no call", found[2].expected() is None)

    spaced = os.path.join(home, "fake dir", "out.json")
    draft = {"blocks": [{"source": tool}, {"source": COMMAND}, {"source": COMMAND}]}
    found = sources.for_draft(draft, [None, spaced, "/fake/ignored.json"])
    check("a draft's command output is the first block's output", found[1].output == spaced and found[1].blocks == [2, 3])
    check("the output path is shell-quoted in the command", found[1].args["command"] == f"fake-fetch --out '{spaced}'",
          found[1].args)
    command = found[1].args["command"]
    check("a command claims a Bash call naming its quoted output", found[1].claims(result(inp={"command": command + " -x"})))
    check("a command never claims a call without its output",
          not found[1].claims(result(inp={"command": f"fake-fetch --out {spaced}"})))
    check("a command never claims another tool's call", not found[1].claims(result(tool="Other", inp={"command": command})))
    check("a command never claims a call whose input is not an object", not found[1].claims(result(inp=[command])))


def test_file_source(home):
    print("file source")
    path = os.path.join(home, "fake-data.json")
    moment = datetime.datetime(2026, 9, 7, 4, 30, tzinfo=UTC)
    write(path, at=moment)
    source = FileSource({"kind": "file", "path": path}, 1, path)
    source.blocks = [1]
    check("a file written before prepare is read even with the age check on",
          stop_of(source, PREPARED_AT, check_age=True) is None and source.text == "fake rows")
    check("a file's reply time is its modification time", source.replied_at == "2026-09-07T04:30:00Z", source.replied_at)

    link = os.path.join(home, "fake-link.json")
    os.symlink(path, link)
    linked = FileSource({"kind": "file", "path": link}, 1, link)
    linked.blocks = [1]
    check("a file source follows a symlink", stop_of(linked) is None and linked.text == "fake rows")

    fifo = os.path.join(home, "fake-pipe.json")
    os.mkfifo(fifo)
    piped = FileSource({"kind": "file", "path": fifo}, 1, fifo)
    piped.blocks = [1]
    stop = stop_of(piped)
    check("a pipe at a file source's path is not a regular file", stop and "not a regular file" in str(stop), stop)

    gone = FileSource({"kind": "file", "path": path + ".gone"}, 1, path + ".gone")
    gone.blocks = [1]
    stop = stop_of(gone)
    check("a missing file cannot be read", stop and "cannot be read" in str(stop) and stop.next == "none", stop)

    folder = os.path.join(home, "fake-folder.json")
    os.mkdir(folder)
    at_folder = FileSource({"kind": "file", "path": folder}, 1, folder)
    at_folder.blocks = [1]
    try:
        stop = stop_of(at_folder)
    except Exception as exc:  # noqa: BLE001
        stop = exc
    check("a directory at a file source's path is a stop, not an error",
          isinstance(stop, Stop) and "not a regular file" in str(stop) and stop.next == "none", repr(stop))

    before = open_fds()
    for reader in (source, piped, at_folder, command_at(fifo), command_at(path)):
        try:
            stop_of(reader)
        except Exception:  # noqa: BLE001
            pass
    check("no read leaves a file descriptor open, on any path", open_fds() == before, (before, open_fds()))


def test_command_source(home):
    print("command source")
    path = os.path.join(home, "out-1.json")
    write(path, at=RESULT_AT - datetime.timedelta(minutes=1))
    source = command_at(path)
    check("a fresh output is read", stop_of(source, PREPARED_AT, check_age=True) is None and source.text == "fake rows")
    check("the reply time is the command's result time", source.replied_at == result()["timestamp"])

    write(path, at=PREPARED_AT - datetime.timedelta(seconds=1))
    stop = stop_of(command_at(path), PREPARED_AT, check_age=True)
    check("an output older than prepare stops", stop and "older than this run's prepare" in str(stop), stop)
    stop = stop_of(command_at(path), None, check_age=True)
    check("an unknown prepare time stops the age check", stop and "older than this run's prepare" in str(stop), stop)

    write(path, at=STARTED_AT - datetime.timedelta(seconds=1))
    for verb, args in (("finish", (PREPARED_AT, True)), ("save", (None, False))):
        stop = stop_of(command_at(path), *args)
        check(f"{verb}: an output written before the command started stops",
              stop and "older than the command" in str(stop), stop)
    write(path, at=STARTED_AT + datetime.timedelta(seconds=1))
    for verb, args in (("finish", (PREPARED_AT, True)), ("save", (None, False))):
        check(f"{verb}: an output written during the command is read", stop_of(command_at(path), *args) is None)
    stop = stop_of(command_at(path, result(started=None)))
    check("a call with no start time stops", stop and "older than the command" in str(stop), stop)

    check("the write slack is two seconds", sources.WRITE_SLACK_SECONDS == 2, sources.WRITE_SLACK_SECONDS)
    write(path, at=RESULT_AT + datetime.timedelta(seconds=2))
    check("an output written two seconds after the result is read", stop_of(command_at(path)) is None)
    write(path, at=RESULT_AT + datetime.timedelta(seconds=3))
    stop = stop_of(command_at(path))
    check("an output written three seconds after the result stops", stop and "after the command's result" in str(stop), stop)
    stop = stop_of(command_at(path, result(at=None)))
    check("a result with no time stops", stop and "after the command's result" in str(stop), stop)

    stop = stop_of(command_at(path, result(is_error=True)))
    check("a failed command stops before its output is read", stop and "returned an error" in str(stop), stop)

    elsewhere = os.path.join(home, "elsewhere.json")
    write(elsewhere, at=RESULT_AT)
    link = os.path.join(home, "out-2.json")
    os.symlink(elsewhere, link)
    stop = stop_of(command_at(link))
    check("a symlinked output is not a regular file", stop and "not a regular file" in str(stop), stop)

    pipe = os.path.join(home, "out-3.json")
    os.mkfifo(pipe)
    stop = stop_of(command_at(pipe))
    check("a pipe at the output path stops without hanging", stop and "not a regular file" in str(stop), stop)

    stop = stop_of(command_at(os.path.join(home, "out-4.json")))
    check("a missing output names the command", stop and "wrote no output file" in str(stop), stop)

    source = command_at(path)
    source.remove_output()
    check("remove_output deletes the output", not os.path.exists(path))
    source.remove_output()
    check("remove_output on a missing output is quiet", not os.path.exists(path))
    command_at(link).remove_output()
    check("remove_output removes a symlink, never its target", not os.path.lexists(link) and os.path.exists(elsewhere))


def test_tool_source():
    print("tool source")
    source = ToolSource({"kind": "tool", "tool": "fake", "args": {}}, 1)
    source.blocks = [2]
    source.call = result(tool="fake")
    check("a tool source reads the call's text and time",
          stop_of(source) is None and source.text == "fake reply" and source.replied_at == result()["timestamp"])
    source.call = result(tool="fake", is_error=True)
    stop = stop_of(source)
    check("a tool error stops without repeating it", stop and "Block 2" in str(stop) and "fake reply" not in str(stop), stop)


def main():
    home = tempfile.mkdtemp(prefix="sources_test_")
    try:
        for test in (lambda: test_build(home), lambda: test_file_source(home), lambda: test_command_source(home),
                     test_tool_source):
            try:
                test()
            except Exception as exc:  # noqa: BLE001
                import traceback
                traceback.print_exc()
                check("a test ran to the end", False, repr(exc))
    finally:
        shutil.rmtree(home, ignore_errors=True)
    print(f"sources_test: {passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
