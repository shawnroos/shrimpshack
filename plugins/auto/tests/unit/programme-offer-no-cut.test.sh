#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

echo "programme-offer-no-cut.test.sh"

"$PY" - "$AUTO_ROOT" <<'PY'
import json
import os
import pathlib
import shlex
import subprocess
import sys
import tempfile

root = pathlib.Path(sys.argv[1])
sys.path[:0] = [str(root / 'lib'), str(root / 'tests' / 'fixtures')]
from _bootstrap import load_lib_module
from registered_transcript import register
import offer_pick

PROG = str(root / 'lib/programme.py')
passed = failed = 0


def check(name, condition, detail=''):
    global passed, failed
    if condition:
        passed += 1
        print('  PASS ' + name)
    else:
        failed += 1
        print(f'  FAIL {name}: {detail}')


def text(words):
    return ' '.join(f'word{i:03d}' for i in range(words))


FITS = text(55)
OVER_RECORD = text(90)
OVER_OPTION = text(120)
assert len(FITS) < 500 < len(OVER_RECORD) < 900 < len(OVER_OPTION)

with tempfile.TemporaryDirectory(prefix='auto-offer-no-cut-') as work:
    work = pathlib.Path(work)
    for key in list(os.environ):
        if key.startswith(('HERDR_', 'REX_', 'CLAUDE_AUTO_')):
            del os.environ[key]
    (work / 'secrets').write_text('')
    fakes = work / 'fakes'
    fakes.mkdir()
    for tool in ('board', 'herdr'):
        (fakes / tool).write_text('#!/bin/sh\nexit 0\n')
        (fakes / tool).chmod(0o755)
    os.environ.update(CLAUDE_AUTO_DATA_DIR=str(work / 'data'), CLAUDE_AUTO_TASKS_DIR=str(work / 'tasks'),
                      CLAUDE_AUTO_TEST_HARNESS='1', CLAUDE_AUTO_MACHINE='studio', CLAUDE_PLUGIN_ROOT=str(root),
                      CLAUDE_AUTO_SECRETS_FILE=str(work / 'secrets'),
                      CLAUDE_AUTO_PERSONAL_PROTOCOL=str(work / 'personal' / 'protocol.json'),
                      PATH=str(fakes) + os.pathsep + os.environ['PATH'], CLAUDE_CODE_SESSION_ID='sid-cut')
    ph = load_lib_module('programme_home')
    core = load_lib_module('run_record_core')
    pj = load_lib_module('programme_journal')
    register('sid-cut', work / 'sid-cut.jsonl')
    run = ph.create_programme(['s.w'], 'sid-cut')['run']

    def verb(*argv):
        return subprocess.run([sys.executable, PROG, *argv, '--run', run], text=True, capture_output=True)

    def programme():
        return core.read_run_record(ph.home_path(run), run)['programme']

    def offered(argv):
        return verb('offer', 'k', '--command', shlex.join(argv))

    def run_picked(argv):
        out = offered(argv)
        if out.returncode:
            return None, out.stdout + out.stderr
        printed = json.loads(out.stdout)
        questions = printed['input']['questions']
        option = next(o for o in questions[0]['options'] if o['label'] != printed['decline'])
        prompt = offer_pick.answer_picker(run, 'sid-cut', questions, option['label'])
        return option, verb(*argv, '--prompt', prompt)

    for key in ('mem:long', 'mem:fits', 'mem:why'):
        assert verb('add-item', key, '--title', 'T').returncode == 0

    def ruling(ident, **flags):
        args = {'effect': 'restrict', 'scope': 's', 'kind': 'file_issue', **flags}
        return ['record-ruling', ident] + [part for name, value in args.items() for part in (f'--{name}', value)]

    def repeats(name, value):
        return ['record-ritual', '--when', 'w', '--trigger', 'quiet', f'--{name}', value]

    refused = [
        ('drop-item --reason', ['drop-item', 'mem:long', '--reason', OVER_RECORD]),
        ('record-ruling --reason', ruling('r-long', reason=OVER_RECORD)),
        ('record-ruling --limit', ruling('r-long', limit=OVER_RECORD)),
        ('record-ruling --scope', ruling('r-long', scope=OVER_RECORD)),
        ('record-behaviour --when', ['record-behaviour', '--when', OVER_RECORD, '--do', 'x']),
        ('record-behaviour --do', ['record-behaviour', '--when', 'w', '--do', OVER_RECORD]),
        ('record-ritual --step', repeats('step', OVER_RECORD)),
    ]
    for name, argv in refused:
        out = offered(argv)
        check(f'{name}: text the record would cut is refused at offer', out.returncode != 0
              and 'the record holds 500' in out.stdout + out.stderr, out.stdout + out.stderr)

    # The other direction: the same flags with text that fits reach the record whole, so only length refused them.
    whole = [
        ('drop-item --reason', ['drop-item', 'mem:fits', '--reason', FITS + ' dropmark'], 'dropmark'),
        ('record-ruling --reason', ruling('r-fits', reason=FITS + ' rulingmark'), 'rulingmark'),
        ('record-behaviour --do', ['record-behaviour', '--when', 'w', '--do', FITS + ' behaviourmark'], 'behaviourmark'),
        ('record-ritual --step', repeats('step', FITS + ' ritualmark'), 'ritualmark'),
    ]
    for name, argv, mark in whole:
        option, done = run_picked(argv)
        check(f'{name}: text that fits is shown whole', option is not None and mark in option['description'], done)
        check(f'{name}: text that fits is recorded whole', option is not None and done.returncode == 0
              and mark in json.dumps(programme()), getattr(done, 'stderr', done))

    # What the verb would refuse after his pick is refused before he is asked.
    for name, argv, said in [
        ('an unknown --kind', ruling('r-kind', kind='merge'), 'unknown decision kind'),
        ('an --until that is not a time', ruling('r-until', until='next week'), '--until must be an ISO time'),
    ]:
        out = offered(argv)
        check(f'record-ruling with {name} is refused at offer', out.returncode != 0 and said in out.stdout + out.stderr,
              out.stdout + out.stderr)
    out = offered(ruling('r-good', until='2030-01-01T00:00:00Z'))
    check('record-ruling with a known kind and an ISO --until is offered', out.returncode == 0, out.stdout + out.stderr)

    # These two verbs store --why as given, so a reason over the record cap is not cut and stays allowed.
    last_word = 'word089'
    option, done = run_picked(['amend-term', 'cadence', 'on_change', '--why', OVER_RECORD])
    check('amend-term --why over 500 is shown whole', option is not None and last_word in option['description'], done)
    check('amend-term --why over 500 is stored whole', option is not None and done.returncode == 0
          and programme()['agreement']['terms']['cadence'].get('why') == OVER_RECORD, getattr(done, 'stderr', done))
    out = offered(['amend-term', 'cadence', 'fixed', '--seconds', '900', '--why', OVER_OPTION])
    check('amend-term --why over what an option shows is refused, never cut', out.returncode != 0
          and 'never cut' in out.stdout + out.stderr, out.stdout + out.stderr)
    out = offered(['end', '--why', OVER_OPTION])
    check('end --why over what an option shows is refused, never cut', out.returncode != 0
          and 'never cut' in out.stdout + out.stderr, out.stdout + out.stderr)
    option, done = run_picked(['end', '--why', OVER_RECORD])
    check('end --why over 500 is shown whole', option is not None and last_word in option['description'], done)
    ended = [r for r in pj.read(run) if r.get('kind') == 'programme_ended']
    check('end --why over 500 is stored whole', option is not None and done.returncode == 0 and ended
          and ended[-1]['payload'].get('why') == OVER_RECORD, getattr(done, 'stderr', done))

print(f'programme-offer-no-cut.test.sh: {passed} passed, {failed} failed')
sys.exit(1 if failed else 0)
PY
