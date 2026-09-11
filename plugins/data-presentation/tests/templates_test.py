#!/usr/bin/env python3
"""U2: the template store and its save gates. Every test runs under a temporary HOME."""

import copy
import json
import os
import pwd
import stat
import sys
import tempfile

SCRIPTS = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts")
sys.path.insert(0, SCRIPTS)

REAL_HOME = pwd.getpwuid(os.getuid()).pw_dir
os.environ["HOME"] = tempfile.mkdtemp(prefix="templates-test-home-")

import mapping  # noqa: E402
import templates  # noqa: E402

passed = failed = 0


def check(name, condition, detail=""):
    global passed, failed
    if condition:
        passed += 1
        print(f"  ok   - {name}")
    else:
        failed += 1
        print(f"  FAIL - {name}{(': ' + detail) if detail else ''}", file=sys.stderr)


def fresh_home():
    return tempfile.mkdtemp(prefix="templates-test-")


def refusal(fn, *args, **kwargs):
    try:
        fn(*args, **kwargs)
    except templates.TemplateError as err:
        return err
    return None


def kind_of(err):
    return err.kind if err is not None else None


def tool_block(args=None):
    return {
        "source": {
            "kind": "tool",
            "tool": "mcp__fake_analytics__get_charts",
            "args": args if args is not None else {"chartIds": ["abc1def2"], "include": "data"},
        },
        "mapping": {"adapter": "amplitude-segmentation", "chart": "abc1def2", "series": "all"},
        "present": {"title": "Weekly people using each tool", "units": "people", "type": "auto"},
        "fingerprint": {"paths": {"data.series": "list"}, "x": {"kind": "date", "step_days": 7}},
    }


def command_block(command):
    return {
        "source": {"kind": "command", "command": command},
        "mapping": {"adapter": "identity"},
        "present": {"title": "Fake command report"},
        "fingerprint": {},
    }


def file_block(path="/tmp/fake-report.json"):
    return {
        "source": {"kind": "file", "path": path},
        "mapping": {"adapter": "paths", "x": "rows.*.day"},
        "present": {"title": "Fake file report", "width": 80},
        "fingerprint": {},
    }


def template(name="fake-report", blocks=None):
    return {
        "name": name,
        "purpose": "A fake weekly report for tests",
        "caveats": ["Fake data only"],
        "blocks": blocks if blocks is not None else [tool_block()],
        "created_at": "2026-01-01T00:00:00Z",
    }


GOOD_CURL = 'curl -fsS -H "Authorization: Bearer $FAKE_TOKEN" "https://api.example.test/v1/x" -o {output}'


def main():
    # --- the root never lands in the real home ---
    check("root() follows the patched HOME", templates.root().startswith(os.environ["HOME"]), templates.root())
    check(
        "root() is not under the real home",
        not templates.root().startswith(os.path.join(REAL_HOME, ".claude")),
        templates.root(),
    )
    check(
        "root(home) is <home>/.claude/data-presentation",
        templates.root("/x/y") == "/x/y/.claude/data-presentation",
        templates.root("/x/y"),
    )
    check("the name pattern is the pinned one", templates.NAME_PATTERN == r"^[a-z0-9][a-z0-9-]{0,23}$")
    check("the source kinds are closed", templates.SOURCE_KINDS == ("tool", "command", "file"))
    check("templates takes its adapters from mapping", templates.ADAPTERS is mapping.ADAPTERS)

    # --- names ---
    for bad in ("a/b", "a.b", "Upper", "a" * 25, "", "-lead", "../x", "a b", "abc\n", None, 7):
        check(f"name {bad!r} is refused", kind_of(refusal(templates.check_name, bad)) == "invalid")
    for good in ("a", "ai-tools", "a" * 24, "0-report"):
        check(f"name {good!r} is accepted", refusal(templates.check_name, good) is None)
    err = refusal(templates.check_name, "a" * 25)
    check("a long name's refusal says why", err is not None and "24" in str(err), str(err))

    # --- validate: a valid template of every source kind passes ---
    ok_template = template(blocks=[tool_block(), command_block(GOOD_CURL), file_block()])
    check("a valid template validates", refusal(templates.validate, ok_template) is None,
          str(refusal(templates.validate, ok_template)))
    minimal = {"name": "m", "purpose": "p", "blocks": [tool_block()]}
    check("caveats and created_at are optional", refusal(templates.validate, minimal) is None)

    # --- validate: unknown keys at every level, naming the key ---
    t = template()
    t["hook"] = "x"
    err = refusal(templates.validate, t)
    check("an unknown top-level key is refused", kind_of(err) == "invalid")
    check("the refusal names the top-level key", err is not None and "hook" in str(err), str(err))

    for level, mutate in (
        ("block", lambda b: b.update({"extra_block": 1})),
        ("source", lambda b: b["source"].update({"extra_source": 1})),
        ("present", lambda b: b["present"].update({"extra_present": 1})),
    ):
        t = template()
        mutate(t["blocks"][0])
        err = refusal(templates.validate, t)
        key = f"extra_{level}"
        check(f"an unknown {level} key is refused", kind_of(err) == "invalid")
        check(f"the refusal names the {level} key", err is not None and key in str(err), str(err))

    for label, cmd_src in (
        ("command", {"kind": "command", "command": GOOD_CURL, "shell": "zsh"}),
        ("file", {"kind": "file", "path": "/tmp/x.json", "follow": True}),
    ):
        t = template(blocks=[command_block(GOOD_CURL)])
        t["blocks"][0]["source"] = cmd_src
        check(f"an unknown key on a {label} source is refused",
              kind_of(refusal(templates.validate, t)) == "invalid")

    for missing in ("name", "purpose", "blocks"):
        t = template()
        del t[missing]
        check(f"a template without {missing} is refused", kind_of(refusal(templates.validate, t)) == "invalid")
    for missing in ("source", "mapping", "present", "fingerprint"):
        t = template()
        del t["blocks"][0][missing]
        check(f"a block without {missing} is refused", kind_of(refusal(templates.validate, t)) == "invalid")

    def refused(label, change):
        t = template()
        change(t)
        check(label, kind_of(refusal(templates.validate, t)) == "invalid")

    check("a non-dict template is refused", kind_of(refusal(templates.validate, [])) == "invalid")
    refused("an empty block list is refused", lambda t: t.update({"blocks": []}))
    refused("caveats that are not strings are refused", lambda t: t.update({"caveats": [1]}))
    refused("an empty purpose is refused", lambda t: t.update({"purpose": ""}))
    refused("a bad name inside the template is refused", lambda t: t.update({"name": "Bad.Name"}))
    refused("an unknown source kind is refused", lambda t: t["blocks"][0]["source"].update({"kind": "http"}))
    refused("an unknown adapter is refused", lambda t: t["blocks"][0]["mapping"].update({"adapter": "eval"}))
    refused("a mapping without an adapter is refused", lambda t: t["blocks"][0]["mapping"].pop("adapter"))
    refused("tool args that are not a dict are refused", lambda t: t["blocks"][0]["source"].update({"args": []}))
    refused("a tool source without a tool name is refused", lambda t: t["blocks"][0]["source"].pop("tool"))
    refused("a fingerprint that is not a dict is refused", lambda t: t["blocks"][0].update({"fingerprint": []}))
    refused("an unknown present type is refused", lambda t: t["blocks"][0]["present"].update({"type": "pie"}))
    refused("a width outside the range is refused", lambda t: t["blocks"][0]["present"].update({"width": 10}))
    refused("a true/false width is refused", lambda t: t["blocks"][0]["present"].update({"width": True}))

    for label, cmd in (
        ("a command without {output} is refused", "curl -f https://api.example.test/v1/x"),
        ("a command with two {output} is refused", "curl -f https://api.example.test -o {output} > {output}"),
    ):
        t = template(blocks=[command_block(cmd)])
        check(label, kind_of(refusal(templates.validate, t)) == "invalid")
    t = template(blocks=[file_block("relative/path.json")])
    check("a relative file path is refused", kind_of(refusal(templates.validate, t)) == "invalid")

    # --- save's scan keeps the store's TemplateError contract ---
    for label, source, kind in (
        ("a literal header", {"kind": "command", "command": 'curl -f -H "X-Api-Key: fakeabc" https://api.example.test -o {output}'},
         "secret"),
        ("a curl without -f", {"kind": "command", "command": "curl https://api.example.test -o {output}"}, "invalid"),
        ("a Bash tool source", {"kind": "tool", "tool": "Bash", "args": {}}, "invalid"),
        ("an unbalanced quote", {"kind": "command", "command": 'curl -f "https://x {output}'}, "invalid"),
    ):
        block = dict(tool_block(), source=source)
        err = refusal(templates.save, template(blocks=[block]), home=fresh_home())
        check(f"templates.save raises TemplateError {kind!r} for {label}", kind_of(err) == kind, repr(err))
    check("templates.save accepts a clean source", refusal(templates.save, template(), home=fresh_home()) is None)
    check("templates re-exports neither the scan nor env_names",
          not hasattr(templates, "secret_scan") and not hasattr(templates, "env_names"))

    # --- absolute dates (R4) ---
    found = templates.absolute_dates({"date_range": {"start": 1788393600, "end": 1789119554}})
    check("epoch seconds are flagged with both paths", found == ["date_range.start", "date_range.end"], repr(found))
    found = templates.absolute_dates({"range": {"start": 1788393600000}})
    check("epoch milliseconds are flagged", found == ["range.start"], repr(found))
    found = templates.absolute_dates({"windows": [{"from": "2026-01-01"}, {"from": "2026-01-01T10:00:00Z"}]})
    check("ISO dates are flagged with list indexes", found == ["windows.0.from", "windows.1.from"], repr(found))
    check("a relative phrase is not flagged", templates.absolute_dates({"relative": "Last 90 Days"}) == [])
    check("a relative key's subtree is not flagged",
          templates.absolute_dates({"relative": {"start": 1788393600}}) == [])
    check("a small integer is not flagged", templates.absolute_dates({"limit": 1000, "days": 90}) == [])
    check("true is not flagged as a number", templates.absolute_dates({"flag": True}) == [])
    check("an ordinary string is not flagged", templates.absolute_dates({"include": "data"}) == [])
    check("a number just past the range is not flagged", templates.absolute_dates({"n": 4102444801}) == [])
    err = templates.TemplateError("absolute_dates", "fixed dates", paths=["a.b"])
    check("an absolute_dates error carries its paths", err.kind == "absolute_dates" and err.paths == ["a.b"])

    # --- template_hash ---
    a = template()
    b = copy.deepcopy(a)
    b["created_at"] = "2030-05-05T00:00:00Z"
    check("template_hash ignores created_at", templates.template_hash(a) == templates.template_hash(b))
    c = copy.deepcopy(a)
    c["purpose"] = "Something else"
    check("template_hash changes with the body", templates.template_hash(a) != templates.template_hash(c))
    d = json.loads(json.dumps(a, sort_keys=True))
    check("template_hash ignores key order", templates.template_hash(a) == templates.template_hash(d))
    check("template_hash does not mutate its input", "created_at" in a)
    e = copy.deepcopy(a)
    e["name"] = "another-name"
    check("template_hash ignores name, so a renamed template keeps its baseline",
          templates.template_hash(a) == templates.template_hash(e))
    check("template_hash is bare sha256 hex", len(templates.template_hash(a)) == 64)

    # --- the store ---
    loose = fresh_home()
    os.makedirs(os.path.join(templates.root(loose), "templates"), mode=0o755)
    os.chmod(templates.root(loose), 0o755)
    os.chmod(os.path.join(templates.root(loose), "templates"), 0o755)
    templates.save(template(), home=loose)
    for sub in ("", "templates"):
        mode = stat.S_IMODE(os.stat(os.path.join(templates.root(loose), sub)).st_mode)
        check(f"a pre-existing loose {sub or 'root'} directory is tightened to 0o700", mode == 0o700, oct(mode))

    home = fresh_home()
    check("list on a fresh home is empty", templates.list_templates(home=home) == [])
    check("reads do not create the store", not os.path.exists(os.path.join(home, ".claude")))
    check("load_run of a never-run name is None", templates.load_run("fake-report", home=home) is None)
    check("loading a missing template is refused as missing",
          kind_of(refusal(templates.load, "fake-report", home=home)) == "missing")

    original = template(blocks=[tool_block(), command_block(GOOD_CURL), file_block()])
    templates.save(original, home=home)
    check("a valid template round-trips", templates.load("fake-report", home=home) == original)
    base = templates.root(home)
    path = os.path.join(base, "templates", "fake-report.json")
    check("the template file is 0o600", stat.S_IMODE(os.stat(path).st_mode) == 0o600,
          oct(stat.S_IMODE(os.stat(path).st_mode)))
    for sub in ("", "templates", "runs", "out"):
        mode = stat.S_IMODE(os.stat(os.path.join(base, sub)).st_mode)
        check(f"the {sub or 'root'} directory is 0o700", mode == 0o700, oct(mode))

    changed = copy.deepcopy(original)
    changed["purpose"] = "A changed fake report"
    check("saving over a name without replace is refused as exists",
          kind_of(refusal(templates.save, changed, home=home)) == "exists")
    check("a refused overwrite leaves the old file", templates.load("fake-report", home=home) == original)
    templates.save(changed, replace=True, home=home)
    check("saving with replace succeeds", templates.load("fake-report", home=home) == changed)

    bad = template(name="secret-report", blocks=[command_block(
        'curl -f -H "X-Api-Key: abc123" https://api.example.test -o {output}')])
    check("save refuses a template holding a secret",
          kind_of(refusal(templates.save, bad, home=home)) == "secret")
    check("a refused secret writes nothing",
          not os.path.exists(os.path.join(base, "templates", "secret-report.json")))
    unknown = template(name="unknown-report")
    unknown["hook"] = 1
    check("save refuses an unknown key", kind_of(refusal(templates.save, unknown, home=home)) == "invalid")

    # --- run records ---
    record = {"template_hash": templates.template_hash(changed), "blocks": [{"x": ["w1"], "series": {"S": [1]}}]}
    templates.write_run("fake-report", record, home=home)
    check("a run record round-trips", templates.load_run("fake-report", home=home) == record)
    run_path = os.path.join(base, "runs", "fake-report.json")
    check("the run record file is 0o600", stat.S_IMODE(os.stat(run_path).st_mode) == 0o600)
    check("the runs directory is 0o700", stat.S_IMODE(os.stat(os.path.join(base, "runs")).st_mode) == 0o700)
    check("write_run refuses a bad name", kind_of(refusal(templates.write_run, "Bad/Name", {}, home=home)) == "invalid")

    # --- atomic write under a forced failure ---
    real_dump = templates.json.dump

    def boom(*_a, **_k):
        raise OSError("forced failure")

    before = open(path, "rb").read()
    templates.json.dump = boom
    try:
        err = None
        try:
            templates.save(original, replace=True, home=home)
        except OSError as caught:
            err = caught
        raised = err is not None
        err = None
        try:
            templates.write_run("fake-report", {"new": 1}, home=home)
        except OSError as caught:
            err = caught
        run_raised = err is not None
    finally:
        templates.json.dump = real_dump
    check("a failed write surfaces its error", raised and run_raised)
    leftovers = [n for n in os.listdir(os.path.join(base, "templates")) + os.listdir(os.path.join(base, "runs"))
                 if n not in ("fake-report.json",)]
    check("a failed write leaves no temp file", leftovers == [], repr(leftovers))
    check("a failed write leaves the old template byte-identical", open(path, "rb").read() == before)
    check("a failed write leaves the old run record", templates.load_run("fake-report", home=home) == record)

    # --- create is atomic: a name that appears after the exists check is not overwritten ---
    race = fresh_home()
    first = template(name="raced-report")
    templates.save(first, home=race)
    raced_path = os.path.join(templates.root(race), "templates", "raced-report.json")
    first_bytes = open(raced_path, "rb").read()
    second = copy.deepcopy(first)
    second["purpose"] = "The second session's report"
    real_exists = templates.exists
    templates.exists = lambda *_a, **_k: False
    try:
        err = refusal(templates.save, second, home=race)
    finally:
        templates.exists = real_exists
    check("a save that loses the create race is refused as exists", kind_of(err) == "exists", repr(err))
    check("the save that won the race is intact", open(raced_path, "rb").read() == first_bytes)
    check("a lost create race leaves no temp file",
          os.listdir(os.path.join(templates.root(race), "templates")) == ["raced-report.json"],
          repr(os.listdir(os.path.join(templates.root(race), "templates"))))

    templates.save(template(name="mover"), home=race)
    mover_bytes = open(os.path.join(templates.root(race), "templates", "mover.json"), "rb").read()
    templates.exists = lambda *_a, **_k: False
    try:
        err = refusal(templates.rename, "mover", "raced-report", home=race)
    finally:
        templates.exists = real_exists
    check("a rename that loses the create race is refused as exists", kind_of(err) == "exists", repr(err))
    check("the rename's target is intact", open(raced_path, "rb").read() == first_bytes)
    check("the refused rename keeps its source",
          open(os.path.join(templates.root(race), "templates", "mover.json"), "rb").read() == mover_bytes)
    check("a lost rename race leaves no temp file",
          sorted(os.listdir(os.path.join(templates.root(race), "templates"))) == ["mover.json", "raced-report.json"])

    # --- list ---
    open(os.path.join(base, "templates", "Bad.Name.json"), "w").write("{}")
    open(os.path.join(base, "templates", "notes.txt"), "w").write("x")
    listed = templates.list_templates(home=home)
    check("list returns (name, purpose) and ignores a bad file name",
          listed == [("fake-report", "A changed fake report")], repr(listed))

    # --- hand edits are refused on read ---
    templates.save(template(name="hand-edited"), home=home)
    hand = os.path.join(base, "templates", "hand-edited.json")
    body = json.load(open(hand))
    body["blocks"][0]["source"]["exec"] = "rm -rf /"
    json.dump(body, open(hand, "w"))
    check("load refuses a hand edit with an unknown key",
          kind_of(refusal(templates.load, "hand-edited", home=home)) == "invalid")

    # --- rename ---
    templates.rename("fake-report", "renamed-report", home=home)
    check("rename moves the template", kind_of(refusal(templates.load, "fake-report", home=home)) == "missing")
    moved = templates.load("renamed-report", home=home)
    check("rename updates the name field", moved["name"] == "renamed-report", repr(moved.get("name")))
    check("rename carries the run record", templates.load_run("renamed-report", home=home) == record)
    check("rename leaves no old run record", templates.load_run("fake-report", home=home) is None)
    check("the renamed file is 0o600",
          stat.S_IMODE(os.stat(os.path.join(base, "templates", "renamed-report.json")).st_mode) == 0o600)
    templates.save(template(name="other-report"), home=home)
    check("rename onto an existing name is refused as exists",
          kind_of(refusal(templates.rename, "other-report", "renamed-report", home=home)) == "exists")
    check("rename of a missing template is refused as missing",
          kind_of(refusal(templates.rename, "no-such", "fresh-name", home=home)) == "missing")
    check("rename refuses a bad new name",
          kind_of(refusal(templates.rename, "other-report", "Bad/Name", home=home)) == "invalid")

    # --- delete ---
    templates.delete("renamed-report", home=home)
    check("delete removes the template",
          not os.path.exists(os.path.join(base, "templates", "renamed-report.json")))
    check("delete removes the run record", not os.path.exists(os.path.join(base, "runs", "renamed-report.json")))
    check("delete of a missing template is refused as missing",
          kind_of(refusal(templates.delete, "renamed-report", home=home)) == "missing")

    # --- an invalid name never reaches a path ---
    untouched = fresh_home()
    for label, call in (
        ("delete", lambda: templates.delete("../../etc", home=untouched)),
        ("rename (old)", lambda: templates.rename("Bad/Name", "fine", home=untouched)),
        ("rename (new)", lambda: templates.rename("fine", "a" * 25, home=untouched)),
        ("load", lambda: templates.load("a.b", home=untouched)),
        ("load_run", lambda: templates.load_run("a.b", home=untouched)),
    ):
        check(f"{label} refuses an invalid name", kind_of(refusal(call)) == "invalid")
    check("no invalid-name call touched the home", os.listdir(untouched) == [], repr(os.listdir(untouched)))

    print(f"templates_test: {passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
