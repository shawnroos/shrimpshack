#!/usr/bin/env python3
"""migrate-memory-index.py — one-time migration of MEMORY.md to the tightened,
budgeted pointer-index format (U1).

Transformation:
  * Drop the sectioned `## heading` + blank-line overhead.
  * Emit one compact line per memory: `- [Title](file.md) — short hook`.
    The verbose hook is truncated (its full detail lives in the body file, which
    QMD indexes — that relocation is the whole point).
  * Fix entry<->body parity: drop index links whose body file no longer exists
    (dead pointers — already unrecoverable), and add entries for body files that
    had no index entry (orphans).
  * Enforce the load budget (< MAX_BYTES and <= MAX_LINES) by shrinking the hook
    cap until it fits.

Backs up the original to <index>.pre-qmd-migration.bak before writing. Idempotent
in effect: re-running on an already-tightened index reproduces it.

Usage: migrate-memory-index.py [INDEX_PATH]
  env: MEMORY_DIR (default dirname of index), MAX_BYTES=25600, MAX_LINES=200
"""
import os, re, sys

# Derive the project-store slug from $HOME (e.g. /Users/jane -> -Users-jane) so
# the default isn't pinned to one user's path.
_proj_slug = "-" + os.path.expanduser("~").lstrip("/").replace("/", "-")
INDEX = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser(
    f"~/.claude/projects/{_proj_slug}/memory/MEMORY.md")
DIR = os.environ.get("MEMORY_DIR") or os.path.dirname(INDEX)
MAX_BYTES = int(os.environ.get("MAX_BYTES", "25600"))
MAX_LINES = int(os.environ.get("MAX_LINES", "200"))

TYPE_PREFIXES = ("feedback", "project", "reference", "idea", "user")
LINK_RE = re.compile(r"\]\(([^)]+\.md)\)")
BULLET_RE = re.compile(r"^\s*-\s+(?:See\s+)?\[[^\]]*\]\(([^)]+\.md)\)\s*(?:[—-]+\s*(.*))?$")


def title_from_filename(fn):
    stem = fn[:-3] if fn.endswith(".md") else fn
    parts = stem.split("_")
    if parts and parts[0] in TYPE_PREFIXES:
        parts = parts[1:]
    return " ".join(parts).strip() or stem


def clean(s):
    return re.sub(r"\s+", " ", (s or "").strip())


def orphan_hook(path):
    """Best-effort short hook for a body file with no index entry."""
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except Exception:
        return ""
    # frontmatter description:
    for l in lines[:20]:
        m = re.match(r"\s*description\s*:\s*(.+)", l)
        if m:
            return clean(m.group(1)).strip("\"'")
    # first non-frontmatter, non-heading, non-blank line
    in_fm = False
    for i, l in enumerate(lines):
        s = l.strip()
        if i == 0 and s == "---":
            in_fm = True
            continue
        if in_fm:
            if s == "---":
                in_fm = False
            continue
        if s and not s.startswith("#"):
            return clean(s)
    # fall back to first heading text
    for l in lines:
        if l.startswith("#"):
            return clean(l.lstrip("# "))
    return ""


def parse_existing():
    """Return ordered list of (target, hook) for every bullet, de-duped on target
    (first occurrence wins)."""
    seen = {}
    order = []
    for line in open(INDEX, encoding="utf-8").read().splitlines():
        m = BULLET_RE.match(line)
        if not m:
            continue
        target, hook = m.group(1), clean(m.group(2))
        if target not in seen:
            seen[target] = hook
            order.append(target)
        elif hook and not seen[target]:
            seen[target] = hook
    return [(t, seen[t]) for t in order]


def main():
    existing = parse_existing()
    bodies = {f for f in os.listdir(DIR) if f.endswith(".md") and f != "MEMORY.md"}

    # Safety: if the index has entries but the memory dir has no body files, the
    # dir is almost certainly wrong/empty — every entry would be dropped as "dead"
    # and the index gutted to just its header. Refuse to write.
    if existing and not bodies:
        print(f"migrate: ABORT — index has {len(existing)} entries but no body files "
              f"found in MEMORY_DIR={DIR}; refusing to gut the index", file=sys.stderr)
        return 1

    entries = []          # (target, title, hook)
    dropped_dead = []
    indexed = set()
    for target, hook in existing:
        if target not in bodies:
            dropped_dead.append(target)
            continue
        entries.append((target, title_from_filename(target), hook))
        indexed.add(target)

    orphans = sorted(bodies - indexed)
    for fn in orphans:
        entries.append((fn, title_from_filename(fn), orphan_hook(os.path.join(DIR, fn))))

    # Safety: if every existing entry resolved as dead and there were no orphans to
    # add, we'd write an empty index — refuse (almost certainly a MEMORY_DIR mismatch).
    if existing and not entries:
        print(f"migrate: ABORT — all {len(existing)} index entries resolved as dead "
              f"(MEMORY_DIR mismatch?); refusing to write an empty index", file=sys.stderr)
        return 1

    # Render, shrinking the hook cap until the budget is met.
    def render(cap):
        out = ["# Memory Index", ""]
        for target, title, hook in entries:
            h = clean(hook)
            if cap and len(h) > cap:
                h = h[:cap].rsplit(" ", 1)[0].rstrip(" ,;:—-") + "…"
            line = f"- [{title}]({target})" + (f" — {h}" if h else "")
            out.append(line)
        return "\n".join(out) + "\n"

    cap = 200
    body = render(cap)
    while (len(body.encode("utf-8")) >= MAX_BYTES or body.count("\n") > MAX_LINES) and cap > 30:
        cap -= 10
        body = render(cap)

    nbytes = len(body.encode("utf-8"))
    nlines = body.count("\n")
    if nbytes >= MAX_BYTES or nlines > MAX_LINES:
        print(f"migrate: ABORT — cannot fit budget (got {nbytes}B/{nlines}L at cap {cap})",
              file=sys.stderr)
        return 1

    backup = INDEX + ".pre-qmd-migration.bak"
    if not os.path.exists(backup):
        import shutil
        shutil.copy2(INDEX, backup)
    tmp = INDEX + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(body)
    os.replace(tmp, INDEX)

    print(f"migrate: wrote {len(entries)} entries — {nbytes} bytes, {nlines} lines (hook cap {cap})")
    print(f"migrate: backup at {backup}")
    if dropped_dead:
        print(f"migrate: dropped {len(dropped_dead)} dead pointer(s) (no body file): {dropped_dead}")
    if orphans:
        print(f"migrate: added {len(orphans)} previously-unindexed body file(s): {orphans}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
