#!/usr/bin/env python3
"""Backfill scope onto untagged memories (plan 003 U3).

Native auto-memory writes land flat in the store with no scope (Claude Code exposes
no memory-write hook — confirmed in the U1 pre-flight), so go-forward tagging is a
best-effort `/reflect`-pass backfill, keyed on each file's `originSessionId` -> its
session transcript `<projects>/<cwd-slug>/<session>.jsonl` -> the session cwd.

CONSERVATIVE BY DESIGN (so it can never corrupt the live store):
  - It tags a memory only when the session cwd reconstructs to an on-disk path that
    `resolve_repo_slug` confirms is the EXACT repo root (slug unchanged). A worktree
    or subdirectory session folds to a different slug, so it is NOT tagged — it
    stays flat/global (the safe floor) rather than being mis-tagged into a scope no
    recall session will ever match. Repos whose name contains '-' may also stay
    global (slug reconstruction is lossy); that's an accepted under-tag, never a
    mis-tag. Use `reflect_cli save --scope` for exact go-forward scoping.
  - It NEVER moves a memory referenced by MEMORY.md (an always-loaded, curated
    body): moving it would demote it and leave a dead pointer (plan 003 U3).
  - Moves are atomic (tmp + os.replace) and skip on destination collision — never
    clobber an existing scoped body. Idempotent; archive/transcripts untouched.
  - Untagged ⇒ flat/global is signal-safe (recall still finds it everywhere).

Usage: backfill.py <store_dir> [<projects_dir>] [--apply] [--home-slug <slug>]
Dry run without --apply. Always exits 0 (fail-open).
"""
import glob
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scope as _scope  # noqa: E402

SID_RE = re.compile(r'originSessionId:\s*([0-9a-fA-F-]{36})')
# pointer line in MEMORY.md, mirrors scripts/memory-index-lint.sh
POINTER_RE = re.compile(r'^\s*-\s+(?:See\s+)?\[[^\]]*\]\(([^)]+\.md)\)', re.M)


def session_slug_index(projects_dir):
    """session-id -> the transcript's parent-dir slug (the session's cwd-slug)."""
    idx = {}
    for j in glob.glob(os.path.join(projects_dir, "*", "*.jsonl")):
        idx[os.path.splitext(os.path.basename(j))[0]] = os.path.basename(os.path.dirname(j))
    return idx


def memory_pointers(store_dir):
    """Basenames of bodies referenced by MEMORY.md (must never be moved)."""
    p = os.path.join(store_dir, "MEMORY.md")
    try:
        txt = open(p, encoding="utf-8", errors="replace").read()
    except OSError:
        return set()
    return {os.path.basename(m) for m in POINTER_RE.findall(txt)}


def has_scope(text):
    if text.startswith("---\n"):
        end = text.find("\n---\n", 4)
        if end != -1:
            return any(l.startswith("scope:") for l in text[4:end].splitlines())
    return False


def _path_from_slug(slug):
    """Best-effort reverse of slugify: -Users-x-foo -> /Users/x/foo. Lossy (a '-' in
    a path component is indistinguishable from a separator) — callers must confirm
    via resolve_repo_slug, so a wrong reconstruction simply fails to confirm."""
    if not slug.startswith("-"):
        return None
    return "/" + slug[1:].replace("-", "/")


def _confirmed_repo_slug(cwd_slug):
    """Return cwd_slug iff it reconstructs to an on-disk path whose resolved repo
    slug equals it (an exact repo root). Else None — fold/lossy/gone -> stay global."""
    path = _path_from_slug(cwd_slug)
    if not path or not os.path.isdir(path):
        return None
    return cwd_slug if _scope.resolve_repo_slug(path) == cwd_slug else None


def plan(store_dir, projects_dir, home_slug=None):
    """Return [(src, dest_slug_or_None, reason)] for flat, unscoped memories."""
    actions = []
    idx = session_slug_index(projects_dir) if os.path.isdir(projects_dir) else {}
    pointers = memory_pointers(store_dir)
    home_slug = home_slug or (_scope.slugify(os.environ["HOME"]) if os.environ.get("HOME") else None)
    for fn in sorted(os.listdir(store_dir)):
        if not fn.endswith(".md") or fn == "MEMORY.md":
            continue
        src = os.path.join(store_dir, fn)               # flat-root files only
        if not os.path.isfile(src):
            continue
        if fn in pointers:
            actions.append((src, None, "stay-global:in-index")); continue
        try:
            text = open(src, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        if has_scope(text):
            actions.append((src, None, "skip:already-scoped")); continue
        m = SID_RE.search(text)
        if not m:
            actions.append((src, None, "stay-global:no-origin")); continue
        cwd_slug = idx.get(m.group(1))
        if not cwd_slug:
            actions.append((src, None, "stay-global:transcript-gone")); continue
        if home_slug and cwd_slug == home_slug:
            actions.append((src, None, "stay-global:home-session")); continue
        repo_slug = _confirmed_repo_slug(cwd_slug)
        if not repo_slug:
            actions.append((src, None, "stay-global:not-exact-repo-root")); continue
        actions.append((src, repo_slug, "tag:repo:" + repo_slug))
    return actions


def apply(store_dir, actions):
    tagged = stayed = skipped = 0
    for src, slug, reason in actions:
        if reason.startswith("skip"):
            skipped += 1; continue
        if reason.startswith("stay-global"):
            stayed += 1; continue
        try:
            text = _scope.set_scope(open(src, encoding="utf-8", errors="replace").read(),
                                    "repo:" + slug)
            dest = os.path.join(store_dir, "_scope", slug, os.path.basename(src))
            if os.path.exists(dest):                    # never clobber an existing body
                stayed += 1; continue
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            tmp = dest + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                f.write(text)
            os.replace(tmp, dest)
            os.remove(src)
            tagged += 1
        except OSError as e:
            sys.stderr.write("backfill: could not tag %s (%s)\n" % (src, e))
            stayed += 1
    return tagged, stayed, skipped


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    do_apply = "--apply" in sys.argv
    home_slug = None
    if "--home-slug" in sys.argv:
        i = sys.argv.index("--home-slug")
        home_slug = sys.argv[i + 1] if i + 1 < len(sys.argv) else None
    if not args:
        sys.stderr.write("usage: backfill.py <store_dir> [<projects_dir>] [--apply] [--home-slug S]\n")
        return 0
    store = args[0]
    projects = args[1] if len(args) > 1 else os.path.expanduser("~/.claude/projects")
    actions = plan(store, projects, home_slug)
    tag = sum(1 for _, _, r in actions if r.startswith("tag"))
    stay = sum(1 for _, _, r in actions if r.startswith("stay"))
    skip = sum(1 for _, _, r in actions if r.startswith("skip"))
    if not do_apply:
        sys.stdout.write("DRY RUN: %d flat files | tag-to-repo=%d stay-global=%d already-scoped=%d\n"
                         % (len(actions), tag, stay, skip))
        return 0
    t, s, k = apply(store, actions)
    sys.stdout.write("tagged=%d stayed-global=%d skipped=%d\n" % (t, s, k))
    return 0


if __name__ == "__main__":
    sys.exit(main())
