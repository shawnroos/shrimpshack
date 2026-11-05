#!/usr/bin/env python3
"""A test's `programme.py`: a citation of Shawn's typed words on an approval verb goes through a real `offer` and pick.

Tests that set up state cite a typed prompt, and a typed message with no open offer approves nothing. This runs the
real `offer`, answers the printed picker in a transcript the transcript check reads, and runs the verb on that pick.
Anything else goes to programme.py unchanged, so a refusal stays that verb's refusal. Tests of what typed words do
call lib/programme.py directly. It lives in tests/ and reads no setting: no PM can reach it.
"""

import json
import os
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
REAL = str(ROOT / 'lib/programme.py')
sys.path.insert(0, str(ROOT / 'lib'))
sys.path.insert(0, str(ROOT / 'tests/fixtures'))


def passthrough():
    os.execv(sys.executable, [sys.executable, REAL, *sys.argv[1:]])


def _value(argv, flag):
    return argv[argv.index(flag) + 1] if flag in argv and argv.index(flag) + 1 < len(argv) else None


def _without(argv, *flags):
    out, args = [], list(argv)
    while args:
        arg = args.pop(0)
        if arg in flags:
            args = args[1:]
        else:
            out.append(arg)
    return out


def _typed_with_no_offer(argv):
    from _bootstrap import load_lib_module
    verb = _without(argv, '--op')[0] if _without(argv, '--op') else None
    prompt_id = _value(argv, '--prompt')
    offers = load_lib_module('programme_offers')
    if not prompt_id or verb not in offers.RENDERERS or '--reads-as' in argv or not os.environ.get('CLAUDE_AUTO_DATA_DIR'):
        return None
    programme = load_lib_module('programme')
    try:
        run = programme._locate({'run': _value(argv, '--run')})[0]
    except Exception:
        return None
    journal = load_lib_module('programme_journal')
    rows = journal.read(run)
    row = journal.find_prompt(run, prompt_id, rows)
    if row is None or journal.prompt_origin(row) != 'typed' or (row.get('payload') or {}).get('driving') is False \
            or row.get('provenance') is not None or row.get('session_id') != os.environ.get('CLAUDE_CODE_SESSION_ID'):
        return None
    return None if offers._open_offer(rows, row) is not None else run


def main():
    argv = sys.argv[1:]
    try:
        run = _typed_with_no_offer(argv)
    except Exception:
        run = None
    if run is None:
        passthrough()
    import shlex
    import offer_pick
    command = shlex.join(_without(argv, '--op', '--prompt', '--run'))
    stdin = sys.stdin.read() if not sys.stdin.isatty() and command.split()[0] == 'set-remit' else ''
    offered = subprocess.run([sys.executable, REAL, 'offer', 'pick', '--command', command, '--run', run],
                             input=stdin, text=True, capture_output=True)
    if offered.returncode != 0:
        result = subprocess.run([sys.executable, REAL, *argv], input=stdin, text=True, capture_output=True)
        sys.stdout.write(result.stdout)
        sys.stderr.write(result.stderr)
        return result.returncode
    printed = json.loads(offered.stdout)
    questions = printed['input']['questions']
    answer = next(o['label'] for o in questions[0]['options'] if o['label'] != printed['decline'])
    pick = offer_pick.answer_picker(run, os.environ['CLAUDE_CODE_SESSION_ID'], questions, answer)
    swapped = [pick if a == _value(argv, '--prompt') and argv[i - 1] == '--prompt' else a for i, a in enumerate(argv)]
    return subprocess.run([sys.executable, REAL, *swapped], input=stdin, text=True).returncode


if __name__ == '__main__':
    sys.exit(main())
