#!/usr/bin/env python3
"""Re-import archived memory stores into the canonical store, scope-tagged (plan 003 U6).

Reads `<archive_root>/<repo-slug>/memory/*.md` and writes each kept body into the
canonical store under `_scope/<repo-slug>/` — so it surfaces (when relevant) in that
repo and stays quiet elsewhere. Cross-cutting memories go to the flat root (global)
instead, so a genuinely general learning isn't locked to one repo.

Reuses plan 002's import discipline:
  - prune-protected: stamps a fresh `last_used` and `pin: true`
  - idempotent: skips when `(origin, origin_hash)` is already present
  - non-destructive: never touches the archive
  - schema-preserving: line-inserts the new top-level keys, no parse-reemit

Scope here is the ARCHIVE DIRECTORY NAME — no provenance lookup needed (the bulk,
~100%-taggable path from the U1 pre-flight). Imports are qmd-recall-only: they are
NOT added to MEMORY.md, and `_scope/**` is outside the non-recursive lint's view, so
the index budget and parity stay clean.

Usage:
  reimport.py <archive_root> <store_dir> [--apply]
Without --apply it's a dry run (prints what it would do, writes nothing).
Always exits 0 (fail-open); per-file problems are reported and skipped.
"""
import hashlib
import os
import sys

GLOBAL = "global"
PIN_LINE = "pin: true"


def _err(msg):
    sys.stderr.write("reimport: %s\n" % msg)


def split_frontmatter(text):
    """Return (frontmatter_lines, body_text). Empty frontmatter list if none."""
    if text.startswith("---\n"):
        end = text.find("\n---\n", 4)
        if end != -1:
            fm = text[4:end].splitlines()
            body = text[end + len("\n---\n"):]
            return fm, body
    return [], text


def body_hash(text):
    """Hash over the frontmatter-STRIPPED body (idempotency key, plan 002 KTD6)."""
    _, body = split_frontmatter(text)
    return hashlib.sha256(body.encode("utf-8", "replace")).hexdigest()[:16]


def is_cross_cutting(text):
    """Light cross-project-positive test (plan 002 R5): does the memory read as
    generally useful rather than repo-specific? Conservative heuristic — the
    operator can re-scope via the CLI. Here: a memory whose type is a general
    preference/feedback with no repo-specific nouns leans global."""
    fm, body = split_frontmatter(text)
    blob = (" ".join(fm) + " " + body).lower()
    # explicit signal wins
    if "scope: global" in blob or "cross-project" in blob or "cross-repo" in blob:
        return True
    return False


def is_cruft(text):
    """Light triage: drop empty/trivial bodies."""
    _, body = split_frontmatter(text)
    return len(body.strip()) < 20


def already_imported(store_dir, origin, h):
    """True if a body carrying this (origin, origin_hash) is already in the store.

    Matches whole frontmatter LINES (not substrings) so a prefix slug like
    `origin: -Users-x-pro` can't false-positive against `origin: -Users-x-proj`.
    """
    want_origin = "origin: " + origin
    want_hash = "origin_hash: " + h
    for root, _dirs, files in os.walk(store_dir):
        for fn in files:
            if not fn.endswith(".md"):
                continue
            try:
                t = open(os.path.join(root, fn), encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            lines = set(t.splitlines())
            if want_origin in lines and want_hash in lines:
                return True
    return False


def _unique_dest(dest, slug):
    """Disambiguate a destination filename on collision so two same-named bodies
    from different origins never clobber each other (e.g. two `feedback.md`)."""
    if not os.path.exists(dest):
        return dest
    base, ext = os.path.splitext(dest)
    suffixed = "%s__%s%s" % (base, slug.lstrip("-"), ext)
    return suffixed if not os.path.exists(suffixed) else None


def inject_frontmatter(text, extra_lines):
    """Line-insert top-level keys right after the opening `---` (no parse-reemit, so
    the body bytes — and the hash — are untouched; plan 002 KTD7)."""
    if text.startswith("---\n"):
        return "---\n" + "\n".join(extra_lines) + "\n" + text[4:]
    return "---\n" + "\n".join(extra_lines) + "\n---\n" + text


def plan(archive_root, store_dir, today="1970-01-01"):
    """Return a list of (src_path, dest_path, action) without writing anything."""
    actions = []
    if not os.path.isdir(archive_root):
        _err("archive root not found: %s" % archive_root)
        return actions
    for slug in sorted(os.listdir(archive_root)):
        memdir = os.path.join(archive_root, slug, "memory")
        if not os.path.isdir(memdir):
            continue
        for fn in sorted(os.listdir(memdir)):
            if not fn.endswith(".md") or fn == "MEMORY.md":
                continue
            src = os.path.join(memdir, fn)
            try:
                text = open(src, encoding="utf-8", errors="replace").read()
            except OSError as e:
                actions.append((src, None, "skip:unreadable(%s)" % e))
                continue
            if is_cruft(text):
                actions.append((src, None, "drop:cruft"))
                continue
            h = body_hash(text)
            if already_imported(store_dir, slug, h):
                actions.append((src, None, "skip:already-imported"))
                continue
            if is_cross_cutting(text):
                dest = os.path.join(store_dir, fn)          # flat root = global
                scope_val = GLOBAL
            else:
                dest = os.path.join(store_dir, "_scope", slug, fn)
                scope_val = "repo:" + slug
            actions.append((src, dest, "import:" + scope_val))
    return actions


def apply(actions, today):
    imported = dropped = skipped = 0
    for src, dest, action in actions:
        if action.startswith("drop"):
            dropped += 1
            continue
        if action.startswith("skip"):
            skipped += 1
            continue
        # import
        try:
            origin = os.path.basename(os.path.dirname(os.path.dirname(src)))
            target = _unique_dest(dest, origin)         # never clobber on basename collision
            if target is None:
                _err("dest collision (kept existing): %s" % dest)
                skipped += 1
                continue
            text = open(src, encoding="utf-8", errors="replace").read()
            scope_val = action.split("import:", 1)[1]
            extra = ["scope: " + scope_val, "origin: " + origin,
                     "origin_hash: " + body_hash(text), "last_used: " + today, PIN_LINE]
            out = inject_frontmatter(text, extra)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            tmp = target + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                f.write(out)
            os.replace(tmp, target)
            imported += 1
        except OSError as e:
            _err("could not import %s (%s)" % (src, e))
            skipped += 1
    return imported, dropped, skipped


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    do_apply = "--apply" in sys.argv
    if len(args) < 2:
        _err("usage: reimport.py <archive_root> <store_dir> [--apply]")
        return 0
    archive_root, store_dir = args[0], args[1]
    today = os.environ.get("REIMPORT_TODAY", "1970-01-01")  # injected for determinism in tests
    actions = plan(archive_root, store_dir, today)
    imp = sum(1 for _, _, a in actions if a.startswith("import"))
    drp = sum(1 for _, _, a in actions if a.startswith("drop"))
    skp = sum(1 for _, _, a in actions if a.startswith("skip"))
    total = len(actions)
    if not do_apply:
        sys.stdout.write("DRY RUN: %d files | import=%d drop=%d skip=%d (reconciles=%s)\n"
                         % (total, imp, drp, skp, imp + drp + skp == total))
        for src, dest, a in actions[:10]:
            sys.stdout.write("  %-26s %s\n" % (a, os.path.basename(src)))
        return 0
    i, d, s = apply(actions, today)
    sys.stdout.write("imported=%d dropped=%d skipped=%d (total=%d, reconciles=%s)\n"
                     % (i, d, s, total, i + d + s == total))
    return 0


if __name__ == "__main__":
    sys.exit(main())
