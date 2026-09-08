#!/usr/bin/env python3
"""Collapse duplicated `last_used` fields in memory bodies.

Why this exists: a writer that matched only an unindented `^last_used:` appended
a NEW top-level field to memories whose real field sits indented inside the
`metadata:` block. `memory_activation.py` reads the FIRST whitespace-tolerant
match, so it kept resolving the stale indented date while the file looked
freshly bumped to anyone reading the bottom of the frontmatter. Every such bump
ran, exited 0, and changed no activation.

The repair keeps the NEWEST date found among the duplicates and writes it to the
FIRST field position — the one the reader resolves — then deletes the rest.

Two things it deliberately does not do:

  * It never touches a file with a single field, whatever its date. A stale date
    is a memory that has not been used; that is real signal, not damage.
  * It never rewrites the body. Only frontmatter `last_used` lines are removed.

Preserves st_mtime. mtime is a reinforcement signal in the activation function
(weight 0.3, 60-day half-life), so rewriting hundreds of files without restoring
it would spike every touched memory's activation and reshuffle the hot/cold cut
of the rendered index — a repair that changes rankings is not a repair.

Usage:
    repair-duplicate-last-used.py [--dir D] [--apply] [--backup-dir B]

Reports by default and writes nothing. `--apply` writes, and takes a full backup
of every file it is about to change first (override the location with
--backup-dir). Exit 0 when clean or repaired, 1 on a write failure.
"""

import argparse
import os
import re
import shutil
import sys
import time
from pathlib import Path

# Identical to memory_activation.py's _DATE_RE anchor. Kept in this shape on
# purpose: the bug being repaired was a writer whose pattern was NARROWER than
# the reader's, so a narrower pattern here would not see the damage either.
FIELD = re.compile(r'^([ \t]*)last_used[ \t]*:[ \t]*(\d{4}-\d{2}-\d{2})[ \t]*$', re.M)


def default_memory_dir() -> Path:
    home = Path.home()
    slug = '-' + str(home).lstrip('/').replace('/', '-')
    return Path(os.environ.get('CLAUDE_HOME', home / '.claude')) / 'projects' / slug / 'memory'


def frontmatter_end(text: str) -> int:
    """Index just past the frontmatter's closing fence, or 0 if there is none."""
    if not text.startswith('---'):
        return 0
    m = re.search(r'^---[ \t]*$', text[3:], re.M)
    return 3 + m.end() if m else 0


def analyze(path: Path):
    """Return (matches, winning_date) for a file with 2+ fields, else None."""
    text = path.read_text(encoding='utf-8', errors='replace')
    end = frontmatter_end(text)
    if not end:
        return None
    # Only frontmatter counts. A `last_used` mentioned in prose (this repo's own
    # docs do it) is not a field and must never be deleted.
    matches = [m for m in FIELD.finditer(text) if m.end() <= end]
    if len(matches) < 2:
        return None
    return text, matches, max(m.group(2) for m in matches)


def repair(text: str, matches, winner: str) -> str:
    """Write the winning date into the first field; drop the rest."""
    out, prev = [], 0
    for i, m in enumerate(matches):
        out.append(text[prev:m.start()])
        if i == 0:
            out.append(f'{m.group(1)}last_used: {winner}')
            prev = m.end()
        else:
            # Swallow the trailing newline too, so removal leaves no blank line
            # mid-frontmatter.
            prev = m.end() + 1 if text[m.end():m.end() + 1] == '\n' else m.end()
    out.append(text[prev:])
    return ''.join(out)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--dir', type=Path, default=None)
    ap.add_argument('--apply', action='store_true', help='write changes (default: report only)')
    ap.add_argument('--backup-dir', type=Path, default=None)
    args = ap.parse_args()

    mem = args.dir or default_memory_dir()
    if not mem.is_dir():
        print(f'repair: memory dir not found: {mem}', file=sys.stderr)
        return 1

    findings = []
    for path in sorted(mem.rglob('*.md')):
        got = analyze(path)
        if got:
            text, matches, winner = got
            findings.append((path, text, matches, winner))

    if not findings:
        print(f'repair: no duplicated last_used fields under {mem}')
        return 0

    print(f'repair: {len(findings)} file(s) carry more than one last_used field\n')
    for path, _text, matches, winner in findings:
        dates = ', '.join(f'{m.group(2)}{" (indented)" if m.group(1) else " (top-level)"}'
                          for m in matches)
        reader_sees = matches[0].group(2)
        drift = '' if reader_sees == winner else f'  <-- reader sees {reader_sees}, newest is {winner}'
        print(f'  {path.relative_to(mem)}')
        print(f'    fields: {dates}{drift}')

    if not args.apply:
        print('\nrepair: report only. Re-run with --apply to write (a backup is taken first).')
        return 0

    backup = args.backup_dir or mem.parent / f'memory-backup-{time.strftime("%Y%m%d-%H%M%S")}'
    backup.mkdir(parents=True, exist_ok=True)
    failed = 0
    for path, text, matches, winner in findings:
        rel = path.relative_to(mem)
        dest = backup / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        try:
            shutil.copy2(path, dest)
            st = path.stat()
            path.write_text(repair(text, matches, winner), encoding='utf-8')
            os.utime(path, (st.st_atime, st.st_mtime))
        except OSError as exc:
            print(f'repair: FAILED {rel}: {exc}', file=sys.stderr)
            failed += 1

    print(f'\nrepair: rewrote {len(findings) - failed} file(s); backup at {backup}')
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
