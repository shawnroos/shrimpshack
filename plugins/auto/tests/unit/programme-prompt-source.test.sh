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
sys.path.insert(0, str(root / 'tests/fixtures'))
from _bootstrap import load_lib_module
from programme_prompts import fixture

passed = failed = 0

def check(name, actual, expected):
    global passed, failed
    if actual == expected:
        passed += 1
        print('  PASS ' + name)
    else:
        failed += 1
        print('  FAIL {}: expected {!r}, got {!r}'.format(name, expected, actual))

with tempfile.TemporaryDirectory(prefix='auto-prompt-source-') as work:
    for key in list(os.environ):
        if key.startswith('HERDR_'):
            del os.environ[key]
    os.environ.update(CLAUDE_AUTO_DATA_DIR=work + '/data', CLAUDE_AUTO_TEST_HARNESS='1',
                      CLAUDE_AUTO_SECRETS_FILE=work + '/no-secrets',
                      CLAUDE_AUTO_PERSONAL_PROTOCOL=work + '/no-protocol')
    source_module = load_lib_module('programme_prompt_source')
    pj = load_lib_module('programme_journal')
    ph = load_lib_module('programme_home')
    host = load_lib_module('programme')
    lifecycle = load_lib_module('programme_lifecycle')
    run = ph.create_programme(['source-fixture'], 'source-pm')['run']
    payload, source, path, human = fixture('accept agreement', 'source-pm')
    row = pj.append_prompt(run, 'source-pm', payload['prompt'], 'unknown', source=source)
    check('source row absent at hook time is not authority', pj.prompt_origin(row), 'unknown')
    path.write_text(json.dumps(human) + '\n')
    check('delayed source resolves typed', pj.prompt_origin(row), 'typed')
    check('persisted adoption lookup verifies source', host.prompt_lookup(run, row['prompt_id'])['origin'], 'typed')

    legacy = pj.append_prompt(run, 'source-pm', 'accept agreement', 'typed')
    check('legacy typed labels cannot authorize', pj.prompt_origin(legacy), 'unknown')
    check('persisted legacy adoption lookup is unverified', host.prompt_lookup(run, legacy['prompt_id'])['origin'], 'unknown')

    for name, changes in [
        ('different source session', {'session_id': 'someone-else'}),
        ('different runtime prompt', {'prompt_id': 'another-prompt'}),
        ('different raw text', {'text_hash': 'wrong'}),
        ('different prefix', {'prefix_hash': 'wrong'}),
        ('negative offset', {'offset': -1}),
        ('boolean offset', {'offset': True}),
        ('offset after end', {'offset': 1000000}),
        ('unsupported version', {'version': 2}),
        ('boolean version', {'version': True}),
        ('relative path', {'path': 'source-pm.jsonl'}),
        ('wrong session filename', {'path': str(path.with_name('another-session.jsonl'))}),
    ]:
        altered = copy.deepcopy(row)
        altered['payload']['source'].update(changes)
        check(name + ' refuses', pj.prompt_origin(altered), 'unknown')

    for name, changes in [
        ('wrong source session row', {'sessionId': 'someone-else'}),
        ('missing origin', {'origin': None}),
        ('malformed origin', {'origin': []}),
        ('wrong turn origin', {'turnOrigin': 'sdk'}),
        ('missing typed source', {'promptSource': None}),
        ('SDK source', {'promptSource': 'sdk'}),
        ('tool result', {'message': {'role': 'user', 'content': [{'type': 'tool_result', 'content': 'accept agreement'}]}}),
        ('assistant role', {'message': {'role': 'assistant', 'content': 'accept agreement'}}),
        ('malformed message', {'message': []}),
        ('summary', {'isCompactSummary': True}),
    ]:
        path.write_text(json.dumps(dict(human, **changes)) + '\n')
        check(name + ' refuses', pj.prompt_origin(row), 'unknown')

    path.write_text('{not-json}\n')
    check('malformed transcript refuses', pj.prompt_origin(row), 'unknown')
    path.write_text(json.dumps(human))
    check('partial source row refuses', pj.prompt_origin(row), 'unknown')
    path.write_text(json.dumps(human) + '\n')
    request = pj.append(run, 'takeover_request', 'source-pm',
                        {'origin': 'unknown', 'source': source, 'driving': False})
    check('non-driving request verifies its own source', len(lifecycle._requests(run, 'takeover', 'source-pm')), 1)
    path.unlink()
    check('removed transcript refuses historical authority', pj.prompt_origin(row), 'unknown')
    check('removed transcript invalidates persisted adoption lookup', host.prompt_lookup(run, row['prompt_id'])['origin'], 'unknown')
    check('non-driving request cannot fall back to its label', len(lifecycle._requests(run, 'takeover', 'source-pm')), 0)

    for data in ({}, {'session_id': 'source-pm', 'prompt': 'accept agreement'},
                 dict(payload, transcript_path='relative.jsonl'), dict(payload, prompt_id=None)):
        check('malformed capture cannot invent authority', source_module.capture(data), None)

    ph.end_programme(run, 'isolated source fixture complete')

print('programme-prompt-source.test.sh: {} passed, {} failed'.format(passed, failed))
sys.exit(1 if failed else 0)
PY
