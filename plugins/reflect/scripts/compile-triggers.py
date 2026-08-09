#!/usr/bin/env python3
"""compile-triggers.py — compile the store's declared triggers into TRIGGERS.json.

Its OWN script with its OWN hook entry and its OWN timeout, invoked ALONGSIDE
`memory-index-render.py` at SessionStart — deliberately NOT inside it (KTD18).
Inside the renderer there are only two places to put it and both are wrong:

  * behind the renderer's byte-identical early return — the common case, and the
    reason the render is cheap enough for SessionStart — where compilation would
    never run on an unchanged store; or
  * ahead of that return, where it adds a frontmatter read of ~866 files to every
    single session start.

So it lives here, with its own freshness test.

Freshness (the mtime skip): recompile only when something in the store is newer
than the manifest. "Something" includes DIRECTORY mtimes, not just body mtimes —
deleting a memory leaves every surviving body older than the manifest, so a
body-only comparison would let a deleted memory's trigger nudge forever. A
deletion bumps the containing directory's mtime, so folding in directories closes
that hole for the price of a few extra `stat` calls.

Exit status is honest, because a caller (and a test) has to be able to tell a
skipped compile from a failed one:

    0  compiled, or up to date
    1  the manifest could not be written

The hook entry appends `|| true`, so a failure is loud to a human reading stderr
and free to the session.

Usage: compile-triggers.py [STORE_DIR] [--force] [--quiet]
  env: MEMORY_DIR overrides the store; default is the same
       `~/.claude/projects/<home-slug>/memory` the renderer uses.
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "scoped-memory"))
import triggers  # noqa: E402


def newest_mtime(store_dir):
    """Newest mtime of any body OR directory under `store_dir`, or None.

    Directories are included so a DELETED memory invalidates the manifest — the
    hole a body-only scan leaves open. Costs a stat per entry and no `open`.
    """
    newest = None
    for root, dirs, files in os.walk(store_dir, onerror=lambda e: None):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        for path in [root] + [os.path.join(root, f) for f in files
                              if f.endswith(".md") and not f.startswith(".")]:
            try:
                mtime = os.stat(path).st_mtime
            except OSError:
                continue
            if newest is None or mtime > newest:
                newest = mtime
    return newest


def is_current(store_dir):
    """True when the manifest is at least as new as everything in the store."""
    try:
        manifest_mtime = os.stat(
            os.path.join(store_dir, triggers.MANIFEST_NAME)).st_mtime
    except OSError:
        return False
    newest = newest_mtime(store_dir)
    return newest is not None and manifest_mtime >= newest


def main(argv):
    force = "--force" in argv
    quiet = "--quiet" in argv
    positional = [a for a in argv if not a.startswith("--")]
    store = (positional[0] if positional else
             os.environ.get("MEMORY_DIR") or triggers.default_store())

    if not os.path.isdir(store):
        if not quiet:
            print("compile-triggers: no store at %s — nothing to do" % store)
        return 0

    if not force and is_current(store):
        if not quiet:
            print("compile-triggers: %s is current, no recompile"
                  % triggers.MANIFEST_NAME)
        return 0

    manifest, problems = triggers.compile_manifest(store)
    for relpath, value, reason in problems:
        # The memory is NAMED. A skipped pattern that reported only "a pattern was
        # bad somewhere in 866 files" is a bug report nobody can act on.
        print("compile-triggers: %s: skipped trigger %r — %s"
              % (relpath, value, reason), file=sys.stderr)

    if not triggers.write_manifest(store, manifest):
        print("compile-triggers: FAILED to write %s in %s"
              % (triggers.MANIFEST_NAME, store), file=sys.stderr)
        return 1

    if not quiet:
        print("compile-triggers: %d memories declare triggers (%d patterns "
              "skipped) -> %s" % (manifest["count"], len(problems),
                                  triggers.MANIFEST_NAME))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
