#!/usr/bin/env python3
"""corpus.py — the ONE enumeration of the memory store (plan U10 / KTD16).

Every path that reads the store — activation scoring, index rendering, local
retrieval, trigger compilation — calls `iter_bodies()` here. Nothing calls
`os.listdir` on the store any more.

Why this module exists: `os.listdir` is flat, and roughly a third of the corpus
lives one level down under `_scope/<slug>/`. Enumerated flat, those bodies carry
no activation data, never reach the hot index, and are invisible to any local
retrieval built on the same call. Fixing that in one consumer and not the others
is WORSE than uniform blindness — the corpus a reader sees would then depend on
which reader it is. So the walk lives here, once.

The scope slug is parsed from the path segment, not read from frontmatter: it is
already encoded in `_scope/<slug>/` (plan 003 KTD1), so it is free here where a
frontmatter read would cost one open per body.

Body identity is the STORE-RELATIVE PATH, not the bare filename:

    reference_foo.md                    (global / flat)
    _scope/-Users-x-projects-y/bar.md   (repo-scoped)

That is what makes a scoped body addressable as an index link target and as a
dict key alongside flat ones. Callers that want a display name or a use-log
lookup key must take `os.path.basename` first — the use log records a name slug
or filename stem, never a path.
"""
import os

#: The scope subtree. `_scope/<slug>/<body>.md` — slug is the repo path-slug from
#: `scope.slugify` (leading dash, `/` -> `-`).
SCOPE_DIR = "_scope"

#: The compiled trigger manifest (plan U3). It lives in the store, is not a
#: memory, and is excluded here so no consumer has to know its name. Named
#: explicitly rather than covered by the `.md`-only rule, because a future
#: manifest format change must not silently start feeding it to scorers.
TRIGGER_MANIFEST = "TRIGGERS.json"

#: Store files that are not memory bodies. `MEMORY.md` is the rendered index
#: (a projection OF the corpus, never a member of it).
EXCLUDED_NAMES = frozenset({"MEMORY.md", TRIGGER_MANIFEST})

#: Suffixes that are never a body. `.log` covers MEMORY_USE.log and RECALL.log;
#: `.bak` covers MEMORY.md.pre-render.bak and any hand-made backup.
EXCLUDED_SUFFIXES = (".log", ".bak")


def _excluded(name):
    """Is this basename a non-body? Dotfiles, the index, logs, backups, manifest."""
    if name.startswith("."):
        return True
    if name in EXCLUDED_NAMES:
        return True
    if name.endswith(EXCLUDED_SUFFIXES):
        return True
    return not name.endswith(".md")


def scope_of_relpath(relpath):
    """Scope slug encoded in a store-relative path, or None for a global body.

    `_scope/<slug>/x.md` -> `<slug>`. Anything else -> None, INCLUDING a bare
    `_scope/x.md` with no slug directory (one exists in the live store) — there
    is no slug to report, so it reads as global rather than as a body scoped to
    a repo named after itself.

    The slug is taken as one whole path segment. It is never split further: repo
    slugs contain `-` by construction (`-Users-x-projects-y`) and may contain any
    character a directory name may, so any parse cleverer than "the segment" is
    a truncation waiting to happen.
    """
    parts = relpath.split(os.sep)
    if len(parts) >= 3 and parts[0] == SCOPE_DIR:
        return parts[1]
    return None


def iter_bodies(store_dir):
    """Yield `(relpath, scope_slug)` for every memory body under `store_dir`.

    * `relpath` is store-relative and is the body's identity everywhere.
    * `scope_slug` is the `_scope/<slug>/` segment, or None for a global body.
    * Order is deterministic: sorted, directories walked depth-first by name.
    * A missing or unreadable store yields nothing rather than raising — every
      consumer of this is on a fail-open path.

    Dot-directories are pruned, so a `.git` or `.trash` inside the store costs
    nothing to skip and can never contribute a body.
    """
    for root, dirs, files in os.walk(store_dir, onerror=lambda e: None):
        dirs[:] = sorted(d for d in dirs if not d.startswith("."))
        for fn in sorted(files):
            if _excluded(fn):
                continue
            relpath = os.path.relpath(os.path.join(root, fn), store_dir)
            yield relpath, scope_of_relpath(relpath)


def body_paths(store_dir):
    """`iter_bodies` reduced to store-relative paths, for callers with no use for
    the slug."""
    return [rel for rel, _slug in iter_bodies(store_dir)]


if __name__ == "__main__":
    import sys
    d = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser(
        "~/.claude/projects/-" + os.path.expanduser("~").lstrip("/").replace("/", "-")
        + "/memory")
    n = scoped = 0
    for rel, slug in iter_bodies(d):
        n += 1
        if slug:
            scoped += 1
        print(f"{slug or '-':40s}  {rel}")
    print(f"\n{n} bodies ({scoped} scoped, {n - scoped} global) in {d}",
          file=sys.stderr)
