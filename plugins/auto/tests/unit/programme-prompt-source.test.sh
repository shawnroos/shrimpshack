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
        ('different window', {'window_hash': 'wrong'}),
        ('window starting after the offset', {'window_start': 1000000}),
        ('negative window start', {'window_start': -1}),
        ('negative offset', {'offset': -1}),
        ('boolean offset', {'offset': True}),
        ('offset after end', {'offset': 1000000}),
        ('unsupported version', {'version': 3}),
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
        ('unlisted source', {'promptSource': 'queued'}),
        ('tool result', {'message': {'role': 'user', 'content': [{'type': 'tool_result', 'content': 'accept agreement'}]}}),
        ('assistant role', {'message': {'role': 'assistant', 'content': 'accept agreement'}}),
        ('malformed message', {'message': []}),
        ('summary', {'isCompactSummary': True}),
    ]:
        path.write_text(json.dumps(dict(human, **changes)) + '\n')
        check(name + ' refuses', pj.prompt_origin(row), 'unknown')

    path.write_text(json.dumps(dict(human, promptSource='suggestion_accepted')) + '\n')
    check('accepted suggestion verifies as suggested', pj.prompt_origin(row), 'suggested')

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

    for name, text, content, expected in [
        ('bare slash command resolves typed', '/auto:programme-takeover',
         '<command-message>auto:programme-takeover</command-message>\n'
         '<command-name>/auto:programme-takeover</command-name>', 'typed'),
        ('slash command with args resolves typed', '/auto:programme-takeover now',
         '<command-message>auto:programme-takeover</command-message>\n'
         '<command-name>/auto:programme-takeover</command-name>\n'
         '<command-args>now</command-args>', 'typed'),
        ('slash command whose name and message differ refuses', '/auto:programme-takeover',
         '<command-message>auto:programme-end</command-message>\n'
         '<command-name>/auto:programme-takeover</command-name>', 'unknown'),
    ]:
        cmd_payload, cmd_source, cmd_path, cmd_human = fixture(text, 'source-pm')
        cmd_row = pj.append_prompt(run, 'source-pm', text, 'unknown', source=cmd_source)
        cmd_human = dict(cmd_human, promptSource=None, message={'role': 'user', 'content': content})
        cmd_path.write_text(json.dumps(cmd_human) + '\n')
        check(name, pj.prompt_origin(cmd_row), expected)

    # An empty window proves nothing about the transcript before it; only an empty or missing file may have one.
    pad = b'{"type":"system"}\n'
    empty_payload, _, empty_path, empty_human = fixture('accept agreement', 'source-pm')
    empty_path.write_bytes(pad + (json.dumps(empty_human) + '\n').encode())
    empty_source = {'version': 2, 'path': str(empty_path), 'session_id': 'source-pm',
                    'prompt_id': empty_payload['prompt_id'], 'offset': len(pad), 'window_start': len(pad),
                    'window_hash': source_module._hash(b''), 'text_hash': source_module._hash(b'accept agreement')}
    empty_row = pj.append_prompt(run, 'source-pm', 'accept agreement', 'unknown', source=empty_source)
    check('an empty window at a nonzero offset resolves unknown', pj.prompt_origin(empty_row), 'unknown')
    empty_source.update(offset=0, window_start=0)
    empty_path.write_bytes((json.dumps(empty_human) + '\n').encode())
    empty_row = pj.append_prompt(run, 'source-pm', 'accept agreement', 'unknown', source=empty_source)
    check('an empty window at offset 0 still resolves typed', pj.prompt_origin(empty_row), 'typed')

    # A long-lived PM's transcript passed the old 64 MB whole-file limit (72 MB on the Studio), and from then on
    # every prompt journaled as unverified.
    big_payload, _, big_path, big_human = fixture('accept agreement', 'source-pm')
    big_path.write_bytes((json.dumps({'type': 'system', 'sessionId': 'source-pm', 'pad': 'x' * 4000}) + '\n').encode() * 17500)
    check('the transcript is over the old 64 MB limit', big_path.stat().st_size > 64 * 1024 * 1024, True)
    big_source = source_module.capture(big_payload)
    check('a prompt on a transcript over 64 MB captures', isinstance(big_source, dict), True)
    check('the source records a window at the end, not the whole file', big_source['window_start'] > 60 * 1024 * 1024, True)
    big_row = pj.append_prompt(run, 'source-pm', 'accept agreement', 'unknown', source=big_source)
    with big_path.open('a') as stream:
        stream.write(json.dumps(big_human) + '\n')
    check('a prompt on a transcript over 64 MB resolves typed', pj.prompt_origin(big_row), 'typed')
    check('a persisted adoption lookup on it resolves typed', host.prompt_lookup(run, big_row['prompt_id'])['origin'], 'typed')
    flipped = bytearray(big_path.read_bytes())
    flipped[big_source['window_start'] + 10] ^= 1
    big_path.write_bytes(bytes(flipped))
    check('a change inside the window resolves unknown', pj.prompt_origin(big_row), 'unknown')
    big_path.unlink()

    old_payload, _, old_path, old_human = fixture('accept agreement', 'source-pm')
    old_path.write_bytes(b'{"type":"system"}\n' * 50)
    prefix = old_path.read_bytes()
    old_source = {'version': 1, 'path': str(old_path), 'session_id': 'source-pm', 'prompt_id': old_payload['prompt_id'],
                  'offset': len(prefix), 'prefix_hash': source_module._hash(prefix),
                  'text_hash': source_module._hash(b'accept agreement')}
    old_row = pj.append_prompt(run, 'source-pm', 'accept agreement', 'unknown', source=old_source)
    with old_path.open('a') as stream:
        stream.write(json.dumps(old_human) + '\n')
    check('a version 1 source journaled before this change still resolves typed', pj.prompt_origin(old_row), 'typed')

    ph.end_programme(run, 'isolated source fixture complete')

print('programme-prompt-source.test.sh: {} passed, {} failed'.format(passed, failed))
sys.exit(1 if failed else 0)
PY
