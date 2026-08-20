#!/usr/bin/env python3
"""retro.py — the retro backlog: item format, the single writer, the only reader (U1).

A retro item records tool friction: the surface it belongs to, the specific thing,
a one-line symptom, the sessions that hit it, and a disposition. Items live in
`<memory-dir>/.retro/<slug>.md`.

WHY A DOT-DIRECTORY (KTD2)
--------------------------
`corpus.iter_bodies()` prunes dot-directories, and corpus is the single
enumeration of the store — activation scoring, index rendering, local BM25 and
trigger compilation all read it. qmd skips dot-directories too (verified against
the live binary). So one directory name buys index exclusion, recall exclusion
and trigger exclusion with no code change in any consumer (R5).

The consequence is the reason `list_items` exists: NO search surface over the
backlog exists at all. Every read of the backlog goes through this file.

WHY THE PROBE LIVES IN THE BODY (KTD3)
--------------------------------------
`memory_activation.parse_last_used` and `parse_pinned` scan the head of a file
with line-anchored regexes rather than parsing YAML. A multi-line `probe:` in
frontmatter holding a line that looks like `last_used:` or `pin: true` would be
read as that key. Retro items are outside the corpus so activation never scores
them, but the hazard is structural — the body is free of it. The parser here
reads the top fence block and nothing else, which is what keeps a `last_used:`
line inside the probe fence out of the item's frontmatter.

WHY ONE WRITER
--------------
`set_disposition` is the only way an item leaves `open`, and it requires a proof
argument naming what closed it. That makes "no item is closed without a recorded
proof" an invariant testable at the writer, rather than a convention two callers
happen to follow. `append_session` and `record_probe_approval` cover every
non-disposition update. Nothing else edits an item file.
"""
import hashlib
import os
import re
import sys
import tempfile
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "scoped-memory"))
from triggers import frontmatter_lines, _unquote  # noqa: E402

RETRO_DIRNAME = ".retro"

#: R2. An item leaves the backlog only by moving out of `open`.
DISPOSITIONS = ("open", "fixed", "culled", "wontfix")

SURFACES = ("plugin", "skill", "harness", "codebase")

PROBE_HEADING = "## Probe"

_FENCE_OPEN = "```bash"
_FENCE_CLOSE = "```"


class RetroError(ValueError):
    """A write this module refuses: an unknown disposition, a move with no proof."""


def retro_dir(store_dir):
    return os.path.join(store_dir, RETRO_DIRNAME)


def item_path(store_dir, name):
    return os.path.join(retro_dir(store_dir), name + ".md")


def probe_hash(text):
    return hashlib.sha256((text or "").encode("utf-8")).hexdigest()


def _ensure_dir(store_dir):
    d = retro_dir(store_dir)
    os.makedirs(d, exist_ok=True)
    # chmod, not makedirs(mode=): the mode argument is masked by the umask, and
    # under the default umask this directory holds probe shell world-readable.
    os.chmod(d, 0o700)
    return d


def _read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except Exception:
        return ""


def _write_atomic(path, text):
    d = os.path.dirname(path)
    # A unique temp name, never a fixed `.tmp`: two sessions writing at once
    # would otherwise open the same name and the survivor is a file assembled
    # from both runs.
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".retro-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def parse_frontmatter(text):
    """Frontmatter as a flat dict; nested keys join with a dot (`metadata.type`).

    Fail-open throughout: an unterminated fence reads as absent frontmatter
    (`frontmatter_lines` already returns [] for it), so a malformed item degrades
    to no metadata rather than raising in a list walk.
    """
    out = {}
    parent = None
    for line in frontmatter_lines(text):
        m = re.match(r"^(\s*)([A-Za-z_][\w.-]*)\s*:\s*(.*)$", line)
        if not m:
            continue
        indent, key, value = len(m.group(1)), m.group(2), m.group(3)
        if indent == 0:
            parent = key if not value.strip() else None
            if value.strip():
                out[key] = _unquote(value)
        elif parent:
            out[f"{parent}.{key}"] = _unquote(value)
    return out


def parse_probe(text):
    """The probe's shell, byte-identical, or None when the item carries no probe.

    Absent and empty are different states (R3/R4): a probe that is present and
    empty proves nothing, and so does an absent one, but only the second is a
    normal item.
    """
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if line.strip() != PROBE_HEADING:
            continue
        for j in range(i + 1, len(lines)):
            if not lines[j].strip():
                continue
            if lines[j].strip() != _FENCE_OPEN:
                break
            for k in range(j + 1, len(lines)):
                if lines[k].strip() == _FENCE_CLOSE:
                    return "\n".join(lines[j + 1:k])
            break
    return None


def read_item(store_dir, name):
    path = item_path(store_dir, name)
    if not os.path.exists(path):
        raise RetroError(f"no retro item named {name!r} in {retro_dir(store_dir)}")
    text = _read(path)
    return {
        "name": name,
        "path": path,
        "frontmatter": parse_frontmatter(text),
        "probe": parse_probe(text),
        "text": text,
    }


def list_items(store_dir, disposition=None, surface=None):
    """Every item in the backlog, optionally filtered. The ONLY view of it.

    Returns `[{name, path, frontmatter}]` sorted by name. An absent or empty
    `.retro/` lists empty rather than raising — every caller is on a review-time
    path where a missing backlog means "nothing to work", not an error.
    """
    d = retro_dir(store_dir)
    try:
        names = sorted(fn for fn in os.listdir(d) if fn.endswith(".md"))
    except OSError:
        return []
    out = []
    for fn in names:
        path = os.path.join(d, fn)
        fm = parse_frontmatter(_read(path))
        if disposition is not None and fm.get("disposition") != disposition:
            continue
        if surface is not None and fm.get("surface") != surface:
            continue
        out.append({"name": fn[:-3], "path": path, "frontmatter": fm})
    return out


def _splice(text, key, value):
    """Set one top-level frontmatter key, leaving every other byte alone.

    Reserialising a parsed item instead would rewrite bytes no caller asked to
    change, which is how a field ends up placed three different ways by three
    different writers.
    """
    lines = text.splitlines(keepends=True)
    if not lines or lines[0].strip() != "---":
        raise RetroError("item has no frontmatter block to write into")
    close = None
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            close = i
            break
    if close is None:
        raise RetroError("item has an unterminated frontmatter fence")
    new = f"{key}: {value}\n"
    for i in range(1, close):
        if re.match(rf"^{re.escape(key)}\s*:", lines[i]):
            lines[i] = new
            return "".join(lines)
    lines.insert(close, new)
    return "".join(lines)


def write_item(store_dir, name, description, surface, thing, symptom,
               probe=None, sessions=(), capture="live", disposition="open",
               opened=None, links=(), cost=None):
    if disposition not in DISPOSITIONS:
        raise RetroError(
            f"disposition {disposition!r} is not one of {', '.join(DISPOSITIONS)}")
    if surface not in SURFACES:
        raise RetroError(f"surface {surface!r} is not one of {', '.join(SURFACES)}")
    d = _ensure_dir(store_dir)
    head = [
        "---",
        f"name: {name}",
        f"description: {description}",
        f"disposition: {disposition}",
        f"surface: {surface}",
        f"thing: {thing}",
        f"opened: {opened or time.strftime('%Y-%m-%d')}",
        f"sessions: {', '.join(sessions)}",
        f"capture: {capture}",
        "metadata:",
        "  type: retro",
        "---",
        "",
        symptom,
        "",
    ]
    if cost:
        head += [f"Cost so far: {cost}", ""]
    if links:
        head += ["Related: " + " ".join(f"[[{l}]]" for l in links), ""]
    if probe is not None:
        head += [PROBE_HEADING, "", _FENCE_OPEN, probe, _FENCE_CLOSE, ""]
    path = os.path.join(d, name + ".md")
    _write_atomic(path, "\n".join(head))
    return path


def set_disposition(store_dir, name, disposition, proof):
    """Move an item between dispositions. The proof is not optional (R4).

    Order matters: both arguments are validated before anything is written, so a
    refused move leaves the file byte-identical rather than half-updated.
    """
    if disposition not in DISPOSITIONS:
        raise RetroError(
            f"disposition {disposition!r} is not one of {', '.join(DISPOSITIONS)}")
    if not (proof or "").strip():
        raise RetroError(
            f"moving {name!r} to {disposition!r} needs a proof naming what closed it")
    item = read_item(store_dir, name)
    text = _splice(item["text"], "disposition", disposition)
    text = _splice(text, "proof", " ".join(proof.split()))
    _write_atomic(item["path"], text)
    return item["path"]


def append_session(store_dir, name, session_id):
    item = read_item(store_dir, name)
    current = [s for s in
               (p.strip() for p in item["frontmatter"].get("sessions", "").split(","))
               if s]
    if session_id in current:
        return item["path"]
    current.append(session_id)
    _write_atomic(item["path"],
                  _splice(item["text"], "sessions", ", ".join(current)))
    return item["path"]


def record_probe_approval(store_dir, name, digest, approved=None):
    item = read_item(store_dir, name)
    text = _splice(item["text"], "probe_approved",
                   approved or time.strftime("%Y-%m-%d"))
    text = _splice(text, "probe_hash", digest)
    _write_atomic(item["path"], text)
    return item["path"]


if __name__ == "__main__":
    store = (sys.argv[1] if len(sys.argv) > 1
             else os.environ.get("MEMORY_DIR") or os.path.expanduser(
                 "~/.claude/projects/-"
                 + os.path.expanduser("~").lstrip("/").replace("/", "-") + "/memory"))
    rows = list_items(store, disposition="open")
    for row in rows:
        fm = row["frontmatter"]
        print(f"{fm.get('surface', '-'):9s}  {row['name']:40s}  "
              f"{fm.get('description', '')}")
    print(f"\n{len(rows)} open retro items in {retro_dir(store)}", file=sys.stderr)
