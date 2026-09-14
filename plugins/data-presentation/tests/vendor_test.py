#!/usr/bin/env python3
"""U1: the vendored renderer is the upstream file, and it needs nothing installed."""

import hashlib
import json
import os
import subprocess
import sys

PLUGIN = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VENDOR = os.path.join(PLUGIN, "scripts", "vendor", "asciichartpy.py")

# sha256 of the asciichartpy 1.5.25 sdist/wheel __init__.py, recorded 2026-09-10.
# Source: https://pypi.org/project/asciichartpy/1.5.25/
# Mutation-verified: changing one byte of the vendored file turns this red.
UPSTREAM_SHA256 = "1d24a0a01f8559fdeea83e654f187796eab5898c77511b5d67ef864d6e4a1990"

passed = failed = 0


def check(name, condition, detail=""):
    global passed, failed
    if condition:
        passed += 1
        print(f"  ok   - {name}")
    else:
        failed += 1
        print(f"  FAIL - {name}{(': ' + detail) if detail else ''}", file=sys.stderr)


def main():
    check("vendored renderer is present", os.path.isfile(VENDOR), VENDOR)

    if os.path.isfile(VENDOR):
        with open(VENDOR, "rb") as fh:
            digest = hashlib.sha256(fh.read()).hexdigest()
        check(
            "vendored renderer matches the upstream 1.5.25 digest",
            digest == UPSTREAM_SHA256,
            f"got {digest}",
        )

    # The claim R15 actually makes: this runs with nothing installed. Import the
    # vendored module in a child interpreter whose sys.path carries no
    # site-packages, so a stray real asciichartpy on the host cannot answer for it.
    probe = (
        "import sys; sys.path.insert(0, %r); "
        "import asciichartpy; "
        "print(asciichartpy.plot([1.0, 2.0, 3.0], {'height': 2}))"
    ) % os.path.dirname(VENDOR)
    result = subprocess.run(
        [sys.executable, "-S", "-c", probe],
        capture_output=True,
        text=True,
    )
    check(
        "vendored renderer imports and plots with no site-packages",
        result.returncode == 0 and "┤" in result.stdout,
        (result.stderr or result.stdout).strip()[:200],
    )

    manifest = os.path.join(PLUGIN, ".claude-plugin", "plugin.json")
    check("plugin.json is present", os.path.isfile(manifest), manifest)
    if os.path.isfile(manifest):
        try:
            with open(manifest) as fh:
                data = json.load(fh)
            check("plugin.json parses", True)
            for key in ("name", "description", "version", "author", "skills"):
                check(f"plugin.json declares {key}", key in data)
        except json.JSONDecodeError as exc:
            check("plugin.json parses", False, str(exc))

    # Deliberately NOT tested here: the repo-root marketplace registry. A test that
    # reads above the plugin directory cannot pass from an installed copy, so it
    # would fail on packaging and read as a regression. That check is the publish
    # step's, matching plugins/comment-cut/tests/surfaces_test.sh.

    print(f"vendor_test: {passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
