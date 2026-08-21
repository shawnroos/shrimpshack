#!/usr/bin/env python3
"""Flag mechanically-detectable comment bloat in changed JS/TS files.

Only the unambiguous cases from the why-only bar (CLAUDE.md "Code Comments",
memory `comment-essential-only`). A linter cannot judge whether a comment is
load-bearing, so this deliberately does NOT try: it reports only comments that
are noise regardless of context, and stays silent on everything else.

  banner        // ===== HELPERS =====
  restates      /** Gets the user. */  above  function getUser()
  narrates      // loop over items     above  for (const i of items)
  commented-out  // const x = foo();
  changelog     // added for WEB-1234 / Claude: refactored this

Usage:
  check.py                 # git diff vs HEAD (staged + unstaged), changed files only
  check.py --all           # every tracked JS/TS file under cwd
  check.py <file>...       # specific files
  check.py --self-test     # run built-in fixtures, exit 1 if detection breaks
"""
import re
import subprocess
import sys
from pathlib import Path

CODE_EXT = {'.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs'}
SKIP_DIRS = {'node_modules', 'dist', 'build', 'out', '.next', 'coverage', 'vendor', '.git'}

# includes unicode box-drawing (─ ━ ═) — Slate's ai-tools uses those for section rules
BAR = r'[=*\-~#_─-╿]'
BANNER = re.compile(rf'^\s*//\s*{BAR}{{3,}}|^\s*//.*{BAR}{{4,}}\s*$')
CHANGELOG = re.compile(
    r'^\s*(?://|\*)\s*(?:'
    r'added?\s+(?:for|in|by)\b|'
    r'(?:claude|ai|gpt|copilot)\s*:|'
    r'(?:updated?|changed?|modified|refactored)\s+(?:for|by|in)\b|'
    r'\b(?:WEB|BRA|MEDIA|PLAT|QA|FRG|VID|GRO|SEC|IOS|PRD)-\d+\s*[:\-]?\s*(?:added|fix|update|change)'
    r')', re.I)
# Commented-out code: a // line whose body parses as a statement, not prose.
# Deliberately strict. Measured on 60 real ai-tools files: a loose `word (` clause
# matched ordinary prose ("Lifecycle (cleanup-on-item-removal) is owned by...") and
# produced 4 false positives out of 7 findings. A statement must therefore end like
# one — `;` or `{` or `)` — not merely contain a paren.
CODE_TELL = re.compile(
    r'^\s*//\s*(?:'
    r'(?:const|let|var|function|class|import|export|return|await|throw)\s+[^\s].*[;{]\s*$'
    r'|(?:if|for|while|switch|catch)\s*\('
    r'|[\w.$\[\]]+\s*=[^=]'                      # assignment
    r'|[\w.$]+\([^)]*\)\s*[;{]'                  # call ending in ; or {
    r')')
# A `//` line directly under another `//` line is a wrapped continuation of one prose
# comment — judging it on its own is what produced the false positives above.
CONT = re.compile(r'^\s*//')
# a // line that is prose ending in a colon is a label, not code
PROSE_TELL = re.compile(r'[.:!?]\s*$|\b(?:because|so that|note|why|todo|fixme|hack|see|per|don\'t|must)\b', re.I)

# Ticket / plan-ID used as a LABEL on a sentence: "WEB-2932 U4: <sentence>", "(WEB-2845)".
# The fix is to strip the ref and KEEP the sentence: deleting the line destroys the constraint
# it carries. Measured on the ai-tools comment cut (2026-08-20): of 466 comment lines matching
# WEB-\d+, the large majority were a real invariant wearing a ticket prefix, not history.
TICKET = r'(?:WEB|BRA|MEDIA|PLAT|QA|FRG|VID|GRO|SEC|IOS|PRD)-\d+'
PLANID = r'(?:U\d+|R\d+|AE\d+|F\d+|FD\d+|KTD\d+)'
TICKET_LABEL = re.compile(
    r'^\s*(?://|\*)\s*(?:'
    # (a) opens the comment as a label: "WEB-2932 U4: <sentence>",
    #     "R2 (Logo Removal v2, WEB-2845) / FD5 (WEB-2896, U5): <sentence>"
    rf'(?:{TICKET}|{PLANID})(?:\s*\([^)]*\))?(?:[\s,/+&-]*(?:{TICKET}|{PLANID}|\#\d{{3,5}})(?:\s*\([^)]*\))?)*\s*[:\-\u2013\u2014]\s+\S'
    # (b) trailing citation at the very end: "...that track a MEDIA layer (WEB-2957)."
    #     A parenthetical MID-sentence is referential (it documents an upstream defect the
    #     prose depends on) and is deliberately NOT matched -- see the Replicate keeper.
    rf'|.+\((?:{TICKET}|\#\d{{3,5}})(?:[\s,/]+(?:{TICKET}|{PLANID}))*\)\s*\.?\s*$'
    r')')

# ...unless the ref is REFERENTIAL: the ticket IS the record, so the whole line stays.
TICKET_REFERENTIAL = re.compile(
    rf'\b(?:see|tracked as|tracked in|per|filed as|reported in|regression from|blocked on)\s*[:,]?\s*(?:{TICKET}|\#\d{{3,5}})',
    re.I)

STOP = {'a','an','the','to','of','for','and','or','in','on','with','from','this','that','it','its','is','are','be'}


def stem(w):
    """Crude stem so `gets`/`get` and `items`/`item` compare equal."""
    for suf in ('ies', 'es', 's'):
        if len(w) > 3 and w.endswith(suf):
            return w[:-len(suf)] + ('y' if suf == 'ies' else '')
    return w


def words(s):
    return [stem(w) for w in
            re.findall(r'[a-z]+', re.sub(r'([a-z])([A-Z])', r'\1 \2', s).lower())
            if w not in STOP]


def restates(comment_text, code_line):
    """True when every word of the comment already appears in the next code line."""
    cw, kw = words(comment_text), words(code_line)
    if not cw or not kw or len(cw) > 8:
        return False
    return all(w in kw for w in cw)


# Verbs whose meaning is already carried by the syntax on the next line.
NARRATION_VERB = re.compile(
    r'^\s*(?:loop|iterate|iterating|looping)\b|'
    r'^\s*(?:check|checks|checking)\s+(?:if|whether)\b|'
    r'^\s*(?:set|sets|setting|assign|assigns|declare|declares)\b|'
    r'^\s*(?:call|calls|calling|invoke|invokes)\b|'
    r'^\s*(?:return|returns|returning)\b|'
    r'^\s*(?:create|creates|creating|build|builds)\b|'
    r'^\s*(?:import|imports|export|exports)\b', re.I)


def narrates(body, code_line):
    """A short comment that names what the syntax already says, sharing a noun with it."""
    if len(body.split()) > 6 or not NARRATION_VERB.match(body):
        return False
    cw, kw = set(words(body)), set(words(code_line))
    return bool(cw & kw)   # shares a real noun with the code it sits above


def scan(path):
    try:
        lines = Path(path).read_text(encoding='utf-8', errors='replace').splitlines()
    except OSError:
        return []
    out = []
    i = 0
    while i < len(lines):
        raw = lines[i]
        s = raw.strip()

        if TICKET_LABEL.search(raw) and not TICKET_REFERENTIAL.search(raw):
            out.append((i + 1, 'ticket-label', s[:70]))
            i += 1
            continue
        if BANNER.match(raw):
            out.append((i + 1, 'banner', s[:70]))
            i += 1
            continue
        if CHANGELOG.match(raw):
            out.append((i + 1, 'changelog', s[:70]))
            i += 1
            continue

        # block comment: collect it, compare against the next code line
        if s.startswith('/*'):
            start, body = i, []
            while i < len(lines) and '*/' not in lines[i]:
                body.append(lines[i]); i += 1
            if i < len(lines):
                body.append(lines[i]); i += 1
            nxt = next((l for l in lines[i:i + 3] if l.strip()), '')
            text = ' '.join(re.sub(r'^\s*[/*]+|\*+/\s*$', ' ', b) for b in body)
            # only flag single-purpose docblocks with no @-tag content worth keeping
            if '@' not in text and restates(text, nxt):
                out.append((start + 1, 'restates', text.strip()[:70]))
            continue

        if s.startswith('//'):
            body = s[2:].strip()
            nxt = next((l for l in lines[i + 1:i + 2] if l.strip()), '')
            prev = lines[i - 1] if i else ''
            if CONT.match(prev):          # wrapped continuation of the comment above
                i += 1
                continue
            if body and not PROSE_TELL.search(body) and CODE_TELL.match(s):
                out.append((i + 1, 'commented-out', s[:70]))
            elif body and nxt and (narrates(body, nxt) or restates(body, nxt)):
                out.append((i + 1, 'narrates', s[:70]))
        i += 1
    return out


def changed_files():
    try:
        r = subprocess.run(['git', 'diff', '--name-only', 'HEAD'],
                           capture_output=True, text=True, timeout=30)
        u = subprocess.run(['git', 'ls-files', '--others', '--exclude-standard'],
                           capture_output=True, text=True, timeout=30)
        names = r.stdout.split() + u.stdout.split()
    except Exception:
        return []
    return [f for f in names if Path(f).suffix in CODE_EXT and Path(f).exists()]


def all_files():
    try:
        r = subprocess.run(['git', 'ls-files'], capture_output=True, text=True, timeout=60)
        names = r.stdout.split()
    except Exception:
        names = [str(p) for p in Path('.').rglob('*')]
    return [f for f in names
            if Path(f).suffix in CODE_EXT
            and not SKIP_DIRS & set(Path(f).parts)
            and Path(f).exists()]


FIXTURES = [
    ('// ===== HELPERS =====\ncode();',                              'banner'),
    ('// loop over items\nfor (const i of items) {}',                'narrates'),
    ('/** Gets the user. */\nfunction getUser() {}',                 'restates'),
    ('// const x = foo();\nreal();',                                 'commented-out'),
    ('// added for WEB-1234\ncode();',                               'changelog'),
]
KEEPERS = [
    "const MUSH = 0.60; // measured floor of the destroyed case; don't lower",
    '// must run before flush() because the buffer is reused\ndoThing();',
    '/** Returns null when the layer has no mask. @param l layer */\nexport function getMask(l) {}',
    '// swallow: upstream 404s are expected here, see WEB-2988\n} catch {}',
    # the four false positives measured on 60 real ai-tools files, 2026-08-14 —
    # wrapped prose continuations and `Noun (parenthetical)` read as code without these guards
    '// Lifecycle (cleanup-on-item-removal) is owned by ImageAnalysisService\ncode();',
    '// the centre offset is\n// reliable (rotation and a sign-only scale both fix it). Works\ncode();',
    '// we disarm on tool\n// switch. Keyed on the RESOLVED store identity, not activeTool()\ncode();',
    '// three\n// paths (ESC, drawer-state change, re-selecting the same tool) disarm\ncode();',
]


# --- learned on the Slate ai-tools comment cut, 2026-08-20 ---
FIXTURES = FIXTURES + [
    ("// WEB-2932 U4: single owner of the Remove-Logo region domain\ncode();", 'ticket-label'),
    ("// R2 (Logo Removal v2, WEB-2845) / FD5 (WEB-2896, U5): the box-crosshair\ncode();", 'ticket-label'),
    ("// Pure geometry for the canvas overlays that track a MEDIA layer (WEB-2957).\ncode();", 'ticket-label'),
]
KEEPERS = KEEPERS + [
    '// problem tracked as WEB-2626; do not "fix" this spec by adding verify()\ncode();',
    '// intermittently never schedules on Replicate (WEB-2729); making it a\n// long-poll instead\ncode();',
    '// return the in-flight promise without re-snapshotting.\ncode();',
    '// await later, when the local is long out of scope, so\n// the trace id is already gone\ncode();',
]


def self_test():
    import tempfile, os
    ok = True
    for src, want in FIXTURES:
        with tempfile.NamedTemporaryFile('w', suffix='.ts', delete=False) as f:
            f.write(src); p = f.name
        kinds = [k for _, k, _ in scan(p)]
        os.unlink(p)
        hit = want in kinds
        ok &= hit
        print(f"  {'PASS' if hit else 'FAIL'}  detect {want:14} got={kinds}")
    for src in KEEPERS:
        with tempfile.NamedTemporaryFile('w', suffix='.ts', delete=False) as f:
            f.write(src); p = f.name
        found = scan(p)
        os.unlink(p)
        clean = not found
        ok &= clean
        print(f"  {'PASS' if clean else 'FAIL'}  keep   {src.splitlines()[0][:44]:44} got={[k for _,k,_ in found]}")
    print('\nself-test:', 'OK' if ok else 'BROKEN')
    return 0 if ok else 1


def main():
    args = sys.argv[1:]
    if '--self-test' in args:
        return self_test()
    if '--all' in args:
        files = all_files()
    elif args:
        files = [a for a in args if not a.startswith('-')]
    else:
        files = changed_files()

    if not files:
        print('comment-bloat: no JS/TS files to check')
        return 0

    total = 0
    for f in files:
        hits = scan(f)
        if not hits:
            continue
        print(f'\n{f}')
        for ln, kind, text in hits:
            print(f'  {ln:5}  {kind:14} {text}')
        total += len(hits)

    print(f'\ncomment-bloat: {total} finding(s) across {len(files)} file(s)')
    if total:
        print('Bar: keep only measured constants, ordering constraints, silent-failure '
              'footguns, deliberate deviations. See CLAUDE.md "Code Comments".')
    return 0  # advisory: never blocks a commit


if __name__ == '__main__':
    sys.exit(main())
