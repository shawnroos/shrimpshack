#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
"$PY" - "$AUTO_ROOT" <<'PY'
import copy
import json
import os
import pathlib
import sys
import tempfile

root = pathlib.Path(sys.argv[1])
sys.path.insert(0, str(root / 'lib'))
from _bootstrap import load_lib_module

passed = failed = 0

def check(name, actual, expected):
    global passed, failed
    if actual == expected:
        passed += 1
        print('  PASS ' + name)
    else:
        failed += 1
        print('  FAIL {}: expected {!r}, got {!r}'.format(name, expected, actual))

FIXTURE = [json.loads(line) for line in (root / 'tests/fixtures/askuser_transcript.jsonl').read_text().splitlines()]
PICK, RESULT, PREFILLED, PREFILLED_RESULT = FIXTURE
QUESTION = 'Cadence: how often should the PM sweep?'

with tempfile.TemporaryDirectory(prefix='auto-pick-source-') as work:
    work = pathlib.Path(work)
    for key in list(os.environ):
        if key.startswith('HERDR_'):
            del os.environ[key]
    os.environ.update(CLAUDE_AUTO_DATA_DIR=str(work / 'data'), CLAUDE_AUTO_TEST_HARNESS='1',
                      CLAUDE_AUTO_SECRETS_FILE=str(work / 'no-secrets'),
                      CLAUDE_AUTO_PERSONAL_PROTOCOL=str(work / 'no-protocol'))
    pj = load_lib_module('programme_journal')
    ph = load_lib_module('programme_home')
    picks = load_lib_module('programme_pick_source')
    run = ph.create_programme(['pick-fixture'], 'pick-pm')['run']
    count = [0]

    def journaled(before, after, tool_use_id='toolu_pick', answers=None, sid='pick-pm'):
        count[0] += 1
        folder = work / ('t' + str(count[0]))
        folder.mkdir()
        path = folder / (sid + '.jsonl')
        def own(row):
            return dict(row, sessionId=sid) if row.get('sessionId') == 'S' else row
        path.write_text(''.join(json.dumps(own(row)) + '\n' for row in before))
        data = {'session_id': sid, 'transcript_path': str(path), 'tool_name': 'AskUserQuestion',
                'tool_use_id': tool_use_id, 'tool_input': PICK['message']['content'][0]['input'],
                'tool_response': {'questions': [{'question': QUESTION}],
                                  'answers': answers or {QUESTION: 'fixed every 15 min'}}}
        source = picks.capture(data)
        with path.open('a') as stream:
            for row in after:
                stream.write(json.dumps(own(row)) + '\n')
        row = pj.append_prompt(run, sid, picks.summary(data['tool_response']['answers']), 'unknown', source=source)
        return row, path

    def changed(row, **fields):
        return dict(row, **fields)

    def result_with(**fields):
        return dict(copy.deepcopy(RESULT), **fields)

    row, path = journaled([PICK], [RESULT])
    check('AE1: a human pick resolves picked', pj.prompt_origin(row), 'picked')
    check('the source record stores the redacted question and answer',
          row['payload']['source']['answers'], {QUESTION: 'fixed every 15 min'})
    row, _ = journaled([PICK, RESULT], [])
    check('a result row before the captured offset still verifies', pj.prompt_origin(row), 'picked')

    forged = pj.entry('prompt', 'pick-pm', {'text': 'fixed every 15 min', 'origin': 'picked'}, prompt_id='pforged')
    check('a stored picked label without a source resolves unknown', pj.prompt_origin(forged), 'unknown')
    row, _ = journaled([PICK], [])
    labelled = copy.deepcopy(row)
    labelled['payload']['origin'] = 'picked'
    check('a stored picked label with no matching result row resolves unknown', pj.prompt_origin(labelled), 'unknown')
    try:
        pj.append_prompt(run, 'pick-pm', 'fixed', 'picked')
        check('append_prompt refuses a picked label', 'stored', 'refused')
    except pj.JournalError:
        check('append_prompt refuses a picked label', 'refused', 'refused')

    row, _ = journaled([PREFILLED], [PREFILLED_RESULT], tool_use_id='toolu_prefilled')
    check('a pick whose tool_use input carried answers resolves unknown', pj.prompt_origin(row), 'unknown')
    row, _ = journaled([PICK], [RESULT], answers={QUESTION: 'on change (Recommended)'})
    check('answers that differ from the captured hash resolve unknown', pj.prompt_origin(row), 'unknown')
    row, path = journaled([PICK], [RESULT])
    path.write_text(path.read_text().replace('Cadence', 'Kadence', 1))
    check('a changed prefix resolves unknown', pj.prompt_origin(row), 'unknown')
    row, _ = journaled([PICK], [result_with(isSidechain=True)])
    check('a sidechain result row resolves unknown', pj.prompt_origin(row), 'unknown')
    row, _ = journaled([PICK], [result_with(isMeta=True)])
    check('a meta result row resolves unknown', pj.prompt_origin(row), 'unknown')
    row, _ = journaled([PICK], [result_with(permissionDecision={'decision': 'accept', 'source': 'hook'})])
    check('a non-user permission source resolves unknown', pj.prompt_origin(row), 'unknown')
    row, _ = journaled([PICK], [result_with(permissionDecision=None)])
    check('a missing permission source resolves unknown', pj.prompt_origin(row), 'unknown')
    row, _ = journaled([PICK], [result_with(sourceToolAssistantUUID='a-other')])
    check('a result row linked to another assistant row resolves unknown', pj.prompt_origin(row), 'unknown')
    row, _ = journaled([dict(PICK, isSidechain=True)], [RESULT])
    check('a sidechain assistant row resolves unknown', pj.prompt_origin(row), 'unknown')
    renamed = copy.deepcopy(PICK)
    renamed['message']['content'][0]['name'] = 'Bash'
    row, _ = journaled([renamed], [RESULT])
    check('a tool_use that is not AskUserQuestion resolves unknown', pj.prompt_origin(row), 'unknown')
    row, _ = journaled([PICK, PICK], [RESULT])
    check('a duplicated tool_use id resolves unknown', pj.prompt_origin(row), 'unknown')
    row, _ = journaled([PICK], [RESULT, RESULT])
    check('a duplicated result row resolves unknown', pj.prompt_origin(row), 'unknown')
    row, _ = journaled([PICK], [changed(RESULT, sessionId='someone-else')])
    check('a result row from another session resolves unknown', pj.prompt_origin(row), 'unknown')

    row, _ = journaled([PICK], [RESULT])
    for name, changes in [
        ('different source session', {'session_id': 'someone-else'}),
        ('different tool use id', {'tool_use_id': 'toolu_prefilled'}),
        ('different answers hash', {'answers_hash': 'wrong'}),
        ('different stored answer text', {'answers': {QUESTION: 'on change (Recommended)'}}),
        ('different stored question text', {'answers': {'Autonomy: may the PM merge?': 'fixed every 15 min'}}),
        ('different window hash', {'window_hash': 'wrong'}),
        ('window starting after the offset', {'window_start': 1000000}),
        ('empty window at a nonzero offset', {'window_start': row['payload']['source']['offset'], 'window_hash': picks._hash(b'')}),
        ('negative window start', {'window_start': -1}),
        ('boolean window start', {'window_start': True}),
        ('offset after end', {'offset': 1000000}),
        ('boolean offset', {'offset': True}),
        ('unsupported version', {'version': 3}),
        ('unknown kind', {'kind': 'typed'}),
        ('relative path', {'path': 'pick-pm.jsonl'}),
        ('wrong session filename', {'path': str(path.with_name('other.jsonl'))}),
    ]:
        altered = copy.deepcopy(row)
        altered['payload']['source'].update(changes)
        check(name + ' resolves unknown', pj.prompt_origin(altered), 'unknown')
    altered = copy.deepcopy(row)
    altered['session_id'] = 'someone-else'
    check('a row from another session resolves unknown', pj.prompt_origin(altered), 'unknown')
    check('the verifier alone agrees', picks.verify(row), 'picked')

    for data in ({}, {'session_id': 'pick-pm', 'transcript_path': 'relative.jsonl', 'tool_use_id': 'x',
                      'tool_response': {'answers': {}}},
                 {'session_id': 'pick-pm', 'transcript_path': str(path), 'tool_use_id': 'x',
                  'tool_response': {'answers': 'not a map'}},
                 {'session_id': 'pick-pm', 'transcript_path': str(path), 'tool_response': {'answers': {}}}):
        check('malformed capture records nothing', picks.capture(data), None)

    for odd_id in ('toolu_"x', 'a/b', 'toolu x', 'toolu\\x', 'tóolu'):
        data = {'session_id': 'pick-pm', 'transcript_path': str(path), 'tool_use_id': odd_id,
                'tool_response': {'answers': {QUESTION: 'fixed every 15 min'}}}
        check('a tool_use_id outside [A-Za-z0-9_-] records nothing: ' + odd_id, picks.capture(data), None)
    plain = work / 'plain'
    plain.mkdir()
    (plain / 'pick-pm.jsonl').write_text(json.dumps(PICK).replace('toolu_pick', 'toolu_01-Ab_9') + '\n')
    data = {'session_id': 'pick-pm', 'transcript_path': str(plain / 'pick-pm.jsonl'), 'tool_use_id': 'toolu_01-Ab_9',
            'tool_response': {'answers': {QUESTION: 'fixed every 15 min'}}}
    check('a plain tool_use_id still captures', isinstance(picks.capture(data), dict), True)
    data['transcript_path'] = str(path)
    check('a tool_use_id with no asking row in the transcript records nothing', picks.capture(data), None)
    missing = dict(data, transcript_path=str(work / 'absent' / 'pick-pm.jsonl'))
    check('a pick on a missing transcript records nothing', picks.capture(missing), None)

    # A long-lived PM's transcript passed the old 64 MB whole-file limit (72 MB on the Studio), and from then on
    # every prompt and pick journaled as unverified.
    def big_pick(name, before_rows, after_asking_rows):
        folder = work / name
        folder.mkdir()
        big_path = folder / 'pick-pm.jsonl'
        pad = json.dumps({'type': 'system', 'sessionId': 'pick-pm', 'pad': 'x' * 4000}) + '\n'
        with big_path.open('w') as stream:
            for _ in range(before_rows):
                stream.write(pad)
            stream.write(json.dumps(dict(PICK, sessionId='pick-pm')) + '\n')
            for _ in range(after_asking_rows):
                stream.write(pad)
        data = {'session_id': 'pick-pm', 'transcript_path': str(big_path), 'tool_name': 'AskUserQuestion',
                'tool_use_id': 'toolu_pick', 'tool_input': PICK['message']['content'][0]['input'],
                'tool_response': {'answers': {QUESTION: 'fixed every 15 min'}}}
        return data, big_path

    data, big_path = big_pick('big-near', 17500, 50)
    check('the transcript is over the old 64 MB limit', big_path.stat().st_size > 64 * 1024 * 1024, True)
    source = picks.capture(data)
    check('a pick on a transcript over 64 MB captures', isinstance(source, dict), True)
    with big_path.open('a') as stream:
        stream.write(json.dumps(dict(RESULT, sessionId='pick-pm')) + '\n')
    row = pj.append_prompt(run, 'pick-pm', picks.summary(data['tool_response']['answers']), 'unknown', source=source)
    check('a pick on a transcript over 64 MB resolves picked', pj.prompt_origin(row), 'picked')
    check('the source records the window, not the whole file', source['window_start'] > 60 * 1024 * 1024, True)
    flipped = big_path.read_bytes().replace(b'Cadence', b'Kadence', 1)
    big_path.write_bytes(flipped)
    check('a change inside the window resolves unknown', pj.prompt_origin(row), 'unknown')

    data, far_path = big_pick('big-far', 9000, 9000)
    check('an asking row farther back than the lookback records nothing', picks.capture(data), None)
    data, _ = big_pick('big-edge', 200, 50)
    check('an asking row well inside the lookback captures', isinstance(picks.capture(data), dict), True)

    legacy = work / 'legacy'
    legacy.mkdir()
    legacy_path = legacy / 'pick-pm.jsonl'
    legacy_path.write_text(json.dumps(dict(PICK, sessionId='pick-pm')) + '\n')
    prefix = legacy_path.read_bytes()
    legacy_source = {'version': 1, 'kind': 'pick', 'path': str(legacy_path), 'session_id': 'pick-pm',
                     'tool_use_id': 'toolu_pick', 'offset': len(prefix), 'prefix_hash': picks._hash(prefix),
                     'answers_hash': picks.answers_hash({QUESTION: 'fixed every 15 min'}),
                     'answers': {QUESTION: 'fixed every 15 min'}}
    with legacy_path.open('a') as stream:
        stream.write(json.dumps(dict(RESULT, sessionId='pick-pm')) + '\n')
    row = pj.append_prompt(run, 'pick-pm', 'picked: legacy', 'unknown', source=legacy_source)
    check('a version 1 source journaled before this change still resolves picked', pj.prompt_origin(row), 'picked')

    ph.end_programme(run, 'isolated pick fixture complete')

print('programme-pick-source.test.sh: {} passed, {} failed'.format(passed, failed))
sys.exit(1 if failed else 0)
PY
