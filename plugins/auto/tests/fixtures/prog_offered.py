#!/usr/bin/env python3
"""A test's `programme.py`: a citation of Shawn's typed words on an approval verb goes through a real `offer` and pick.

Tests that set up state cite a typed prompt, and a typed message with no open offer approves nothing. This runs the
real `offer`, answers the printed picker in a transcript the transcript check reads, and runs the verb on that pick.
A verb's own refusal stays that verb's refusal. An `offer` that fails exits EXIT_OFFER_FAILED, which no verb returns, so
a broken renderer cannot pass as a refusal in a test that only asserts non-zero. Tests of what typed words do call
lib/programme.py directly.
"""

import json
import os
import pathlib
import shlex
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
REAL = str(ROOT / 'lib/programme.py')
sys.path.insert(0, str(ROOT / 'lib'))
sys.path.insert(0, str(ROOT / 'tests/fixtures'))
EXIT_OFFER_FAILED = 97


def passthrough():
    os.execv(sys.executable, [sys.executable, REAL, *sys.argv[1:]])


def _value(argv, flag):
    return argv[argv.index(flag) + 1] if flag in argv and argv.index(flag) + 1 < len(argv) else None


def _typed_with_no_offer(argv, offers):
    from _bootstrap import load_lib_module
    bound = offers.bound_argv(argv)
    prompt_id = _value(argv, '--prompt')
    if not prompt_id or not bound or bound[0] not in offers.RENDERERS or '--reads-as' in argv \
            or not os.environ.get('CLAUDE_AUTO_DATA_DIR'):
        return None
    programme = load_lib_module('programme')
    try:
        run = programme._locate({'run': _value(argv, '--run')})[0]
    except programme._ERRORS:
        return None
    journal = load_lib_module('programme_journal')
    rows = journal.read(run)
    row = journal.find_prompt(run, prompt_id, rows)
    if row is None or journal.prompt_origin(row) != 'typed' or (row.get('payload') or {}).get('driving') is False \
            or row.get('provenance') is not None or row.get('session_id') != os.environ.get('CLAUDE_CODE_SESSION_ID'):
        return None
    return None if offers._open_offer(rows, row) is not None else run


def main():
    from _bootstrap import load_lib_module
    argv = sys.argv[1:]
    offers = load_lib_module('programme_offers')
    run = _typed_with_no_offer(argv, offers)
    if run is None:
        passthrough()
    import offer_pick
    bound = offers.bound_argv(argv)
    reads_stdin = bound[0] in offers._CONTENT_VERBS and not sys.stdin.isatty()
    stdin = sys.stdin.read() if reads_stdin else ''
    offered = subprocess.run([sys.executable, REAL, 'offer', 'pick', '--command', shlex.join(bound), '--run', run],
                             input=stdin, text=True, capture_output=True)
    if offered.returncode != 0:
        sys.stderr.write(f'prog_offered: offer failed for {shlex.join(bound)}:\n{offered.stdout}{offered.stderr}')
        return EXIT_OFFER_FAILED
    printed = json.loads(offered.stdout)
    questions = printed['input']['questions']
    answer = next(o['label'] for o in questions[0]['options'] if o['label'] != printed['decline'])
    pick = offer_pick.answer_picker(run, os.environ['CLAUDE_CODE_SESSION_ID'], questions, answer)
    swapped = [pick if a == _value(argv, '--prompt') and argv[i - 1] == '--prompt' else a for i, a in enumerate(argv)]
    return subprocess.run([sys.executable, REAL, *swapped], input=stdin, text=True).returncode


if __name__ == '__main__':
    sys.exit(main())
