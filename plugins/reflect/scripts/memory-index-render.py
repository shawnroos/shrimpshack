#!/usr/bin/env python3
"""memory-index-render.py — render MEMORY.md as the activation-ranked, budget-
truncated projection of the memory store (U5).

This supersedes the one-time `migrate-memory-index.py` as the ongoing render. The
index is no longer "every memory, hooks shrunk to fit" — it is "the highest-
activation memories that fit the load budget." Memories below the cut stay on
disk and in QMD (cold); they are never deleted and re-enter the index when their
activation rises (use bumps last_used / use_count -> next render includes them).

Render algorithm:
  1. Score every body file (memory_activation.score_dir) -> activation order.
     Pinned memories sort first (infinite activation).
  2. Carry forward each memory's existing index hook (so curated hooks survive);
     a newly-promoted body with no prior hook gets a best-effort orphan hook.
  3. Emit lines in activation order, stopping before the byte/line budget is
     exceeded. The remainder are cold (omitted from the index, kept on disk).
  4. Pinned memories are always emitted even if they'd fall past the cut.

Backs up to <index>.pre-render.bak before the first write. Idempotent: re-running
on an unchanged store reproduces the same index.

Usage: memory-index-render.py [INDEX_PATH]
  env: MEMORY_DIR (default dirname of index), MAX_BYTES=17408, MAX_LINES=200,
       plus MEMORY_ACT_* activation-parameter overrides (see memory_activation).
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "scoped-memory"))
import memory_activation as ma
import corpus

_proj_slug = "-" + os.path.expanduser("~").lstrip("/").replace("/", "-")
INDEX = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser(
    f"~/.claude/projects/{_proj_slug}/memory/MEMORY.md")
DIR = os.environ.get("MEMORY_DIR") or os.path.dirname(INDEX)
MAX_BYTES = int(os.environ.get("MAX_BYTES", "17408"))
MAX_LINES = int(os.environ.get("MAX_LINES", "200"))
HOOK_CAP = int(os.environ.get("MEMORY_INDEX_HOOK_CAP", "150"))

TYPE_PREFIXES = ("feedback", "project", "reference", "idea", "user")
BULLET_RE = re.compile(r"^\s*-\s+(?:See\s+)?\[[^\]]*\]\(([^)]+\.md)\)\s*(?:[—-]+\s*(.*))?$")


def clean(s):
    return re.sub(r"\s+", " ", (s or "").strip())


def title_from_filename(fn):
    # `fn` may be a store-relative path (`_scope/<slug>/x.md`) since the corpus
    # enumeration went recursive — the title comes from the file, never the
    # scope directory, or every scoped entry would be titled after the repo.
    fn = os.path.basename(fn)
    stem = fn[:-3] if fn.endswith(".md") else fn
    parts = stem.split("_")
    if parts and parts[0] in TYPE_PREFIXES:
        parts = parts[1:]
    return " ".join(parts).strip() or stem


def existing_hooks(index_path):
    """target -> hook from the current index (first occurrence wins), so curated
    hooks survive a re-render."""
    hooks = {}
    try:
        lines = open(index_path, encoding="utf-8").read().splitlines()
    except Exception:
        return hooks
    for ln in lines:
        m = BULLET_RE.match(ln)
        if m and m.group(1) not in hooks:
            hooks[m.group(1)] = clean(m.group(2))
    return hooks


def orphan_hook(path):
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except Exception:
        return ""
    for l in lines[:20]:
        m = re.match(r"\s*description\s*:\s*(.+)", l)
        if m:
            return clean(m.group(1)).strip("\"'")
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
    return ""


def line_for(target, hook):
    h = clean(hook)
    if HOOK_CAP and len(h) > HOOK_CAP:
        h = h[:HOOK_CAP].rsplit(" ", 1)[0].rstrip(" ,;:—-") + "…"
    return f"- [{title_from_filename(target)}]({target})" + (f" — {h}" if h else "")


def main():
    # Shared recursive enumeration (KTD16) — the same corpus the scorer sees, so
    # the abort guard below can never disagree with the ranking it guards.
    bodies = set(corpus.body_paths(DIR))
    if not bodies:
        print(f"render: ABORT — no body files in MEMORY_DIR={DIR}; refusing to "
              f"render an empty index", file=sys.stderr)
        return 1

    ranked = ma.score_dir(DIR)            # [(fn, score)] activation desc
    hooks = existing_hooks(INDEX)

    header = "# Memory Index\n\n"
    out_lines = []
    nbytes = len(header.encode("utf-8"))
    nlines = 2                            # header line + blank
    hot, cold = [], []

    for fn, score in ranked:
        hook = hooks.get(fn) or orphan_hook(os.path.join(DIR, fn))
        line = line_for(fn, hook)
        pinned = score == float("inf")
        add_bytes = len(line.encode("utf-8")) + 1
        fits = (nbytes + add_bytes < MAX_BYTES) and (nlines + 1 <= MAX_LINES)
        # Pinned memories are always hot, even past the budget cut.
        if fits or pinned:
            out_lines.append(line)
            nbytes += add_bytes
            nlines += 1
            hot.append(fn)
        else:
            cold.append(fn)

    body = header + "\n".join(out_lines) + "\n"
    final_bytes = len(body.encode("utf-8"))
    final_lines = body.count("\n")

    # Skip the write when the index is already correct — keeps the render a true
    # no-op on an unchanged store (idempotent) and makes it safe to fire from a
    # save-time hook without churning the file or looping on its own write event.
    try:
        current = open(INDEX, encoding="utf-8").read()
    except Exception:
        current = None
    if current == body:
        print(f"render: {len(hot)} hot / {len(cold)} cold — already current "
              f"({final_bytes} bytes, {final_lines} lines), no write")
        return 0

    backup = INDEX + ".pre-render.bak"
    if os.path.exists(INDEX) and not os.path.exists(backup):
        import shutil
        shutil.copy2(INDEX, backup)
    tmp = INDEX + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(body)
    os.replace(tmp, INDEX)

    print(f"render: {len(hot)} hot / {len(cold)} cold — {final_bytes} bytes, "
          f"{final_lines} lines (budget {MAX_BYTES}B/{MAX_LINES}L)")
    if final_bytes >= MAX_BYTES or final_lines > MAX_LINES:
        # Pinned overflow is the only way to exceed budget; surface it.
        print(f"render: WARN — index exceeds budget (likely many pinned memories)",
              file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
