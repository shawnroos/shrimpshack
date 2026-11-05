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
from programme_prompts import fixture, pick_rows, queued_attachment_row, queued_user_row

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

    forged_copy = pathlib.Path(work) / 'forged' / 'source-pm.jsonl'
    forged_copy.parent.mkdir()
    forged_copy.write_bytes(path.read_bytes())
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
        ('a copy in a folder the registry does not name', {'path': str(forged_copy)}),
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
        ('unlisted source', {'promptSource': 'bridge'}),
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

    # Picker rows and mid-turn messages, as Claude Code 2.1.318 writes them.
    pick_source = load_lib_module('programme_pick_source')
    approval = load_lib_module('programme_approval')
    rulings = load_lib_module('programme_rulings')
    pick_seq = [0]
    ONE = {'Drop it?': ['Approve drop-item i1', 'Keep it']}

    def pick_row(questions, answers, annotations=None, extra=None, sid='source-pm', driving=True):
        pick_seq[0] += 1
        tool_use_id = 'toolu_{:04d}'.format(pick_seq[0])
        _, _, pick_path, _ = fixture('unused', sid)
        rows = pick_rows(sid, tool_use_id, questions, answers, annotations, extra)
        pick_path.write_text(''.join(json.dumps(r) + '\n' for r in rows))
        pick_row_source = pick_source.capture({'transcript_path': str(pick_path), 'session_id': sid,
                                               'tool_use_id': tool_use_id, 'tool_response': {'answers': answers}})
        return pj.append_prompt(run, sid, pick_source.summary(answers), 'unknown', source=pick_row_source,
                                driving=driving)

    def refusal(call):
        try:
            call()
        except ValueError as exc:
            return str(exc)
        return None

    def pick_answer_of(row):
        return pj.checked_pick(pj.read(run), row)['answer']

    plain = pick_row(ONE, {'Drop it?': 'Approve drop-item i1'})
    check('a plain pick verifies', pj.prompt_origin(plain), 'picked')
    check('a plain pick gives its answer', pick_answer_of(plain), 'Approve drop-item i1')
    preview = pick_row(ONE, {'Drop it?': 'Approve drop-item i1'}, {'Drop it?': {'preview': 'a sketch'}})
    check('a preview with no note is still a plain pick', pick_answer_of(preview), 'Approve drop-item i1')
    unannotated = pick_row(ONE, {'Drop it?': 'Approve drop-item i1'}, False)
    check('a row with no annotations key is a plain pick', pick_answer_of(unannotated), 'Approve drop-item i1')

    afk = pick_row(ONE, {'Drop it?': 'Approve drop-item i1'}, extra={'afkTimeoutMs': 60000})
    check('a pick left by idle timeout resolves unknown', pj.prompt_origin(afk), 'unknown')

    noted = pick_row(ONE, {'Drop it?': 'Approve drop-item i1'}, {'Drop it?': {'notes': 'but not on Fridays'}})
    check('a pick with a note stays a verified pick', pj.prompt_origin(noted), 'picked')
    check('a pick with a note approves no label', 'own words' in (refusal(lambda: pick_answer_of(noted)) or ''), True)
    notes_only = pick_row(ONE, {'Drop it?': '(notes only)'}, {'Drop it?': {'notes': 'not yet'}})
    check('a notes-only pick stays a verified pick', pj.prompt_origin(notes_only), 'picked')
    check('a notes-only pick approves no label', 'own words' in (refusal(lambda: pick_answer_of(notes_only)) or ''), True)
    bare_notes = pick_row(ONE, {'Drop it?': '(notes only)'})
    check('the literal (notes only) counts with no annotation',
          'own words' in (refusal(lambda: pick_answer_of(bare_notes)) or ''), True)

    TWO = {'Drop it?': ['Approve drop-item i1', 'Keep it'], 'And the plan?': ['Yes', 'No']}
    partial = pick_row(TWO, {'Drop it?': 'Approve drop-item i1'})
    check('one answer of two questions stays a verified pick', pj.prompt_origin(partial), 'picked')
    check('one answer of two questions approves nothing', refusal(lambda: pick_answer_of(partial)) is not None, True)
    both = pick_row(TWO, {'Drop it?': 'Approve drop-item i1', 'And the plan?': 'Yes'})
    check('two answers of two questions approve no label', refusal(lambda: pick_answer_of(both)) is not None, True)
    check('a complete two-question pick has no approval gap', pick_source.approval_gap(both), None)

    secret_label = 'Approve adopt-rule password=hunter2hunter2'
    masked = pick_row({'Adopt?': [secret_label, 'No']}, {'Adopt?': secret_label})
    check('the journal holds the masked answer', secret_label in json.dumps(masked['payload']['source']['answers']), False)
    check('the pick is read raw from the transcript', pick_answer_of(masked), secret_label)
    check('its masked form differs, and is what an approval stores', pj.redact(secret_label) != secret_label, True)

    def queued_prompt(text, *later, hook_prompt_id=None, sid='source-pm'):
        queued_payload, _, queued_path, _ = fixture(text, sid)
        if hook_prompt_id:
            queued_payload['prompt_id'] = hook_prompt_id
        queued_source = source_module.capture(queued_payload)
        queued = pj.append_prompt(run, sid, text, 'unknown', source=queued_source)
        queued_path.write_text(''.join(json.dumps(r) + '\n' for r in later))
        return queued

    WORDS = 'yes drop it'
    check('a queued row with human origin and matching text resolves typed',
          pj.prompt_origin(queued_prompt(WORDS, queued_user_row('source-pm', WORDS))), 'typed')
    check('a message absorbed mid-turn resolves typed',
          pj.prompt_origin(queued_prompt(WORDS, queued_attachment_row('source-pm', WORDS))), 'typed')
    running_turn_result = {'type': 'user', 'sessionId': 'source-pm', 'promptId': 'running-turn', 'isSidechain': False,
                           'message': {'role': 'user', 'content': [{'type': 'tool_result', 'content': 'done'}]}}
    check("the running turn's tool result under the hook's prompt id does not hide the queued row",
          pj.prompt_origin(queued_prompt(WORDS, running_turn_result, queued_attachment_row('source-pm', WORDS),
                                         hook_prompt_id='running-turn')), 'typed')
    for name, later in [
        ('a queued row with other text', queued_user_row('source-pm', 'keep it')),
        ('an absorbed message with other text', queued_attachment_row('source-pm', 'keep it')),
        ('a queued row from another session', queued_user_row('someone-else', WORDS)),
        ('a system row', queued_user_row('source-pm', WORDS, prompt_source='system')),
        ('an sdk row', queued_user_row('source-pm', WORDS, prompt_source='sdk')),
        ('a queued row with peer origin', dict(queued_user_row('source-pm', WORDS), origin={'kind': 'peer'})),
        ('a queued row with a scheduled turn', dict(queued_user_row('source-pm', WORDS), turnOrigin='scheduled')),
        ('a queued sidechain row', dict(queued_user_row('source-pm', WORDS), isSidechain=True)),
        ('a peer message absorbed mid-turn', queued_attachment_row('source-pm', WORDS, kind='peer', human_turn=None)),
        ('a task notification absorbed mid-turn',
         queued_attachment_row('source-pm', WORDS, kind='task-notification', human_turn=None,
                               command_mode='task-notification')),
        ('an auto-continuation absorbed mid-turn',
         queued_attachment_row('source-pm', WORDS, kind='auto-continuation', human_turn=None)),
        ('a human origin not marked as a human turn', queued_attachment_row('source-pm', WORDS, human_turn=None)),
        ('an absorbed message from another session', queued_attachment_row('someone-else', WORDS)),
    ]:
        check(name + ' resolves unknown', pj.prompt_origin(queued_prompt(WORDS, later)), 'unknown')
    before_payload, _, before_path, _ = fixture(WORDS, 'source-pm')
    before_path.write_text(json.dumps(queued_user_row('source-pm', WORDS)) + '\n')
    before = pj.append_prompt(run, 'source-pm', WORDS, 'unknown', source=source_module.capture(before_payload))
    check('a queued row older than the capture cannot authorize it', pj.prompt_origin(before), 'unknown')

    def voids(older):
        try:
            rulings.check_newest(pj.read(run), older['prompt_id'])
        except rulings.RulingError as exc:
            return str(exc)
        return None

    def typed_prompt():
        typed_payload, _, typed_path, typed_human = fixture('adopt it', 'source-pm')
        typed = pj.append_prompt(run, 'source-pm', 'adopt it', 'unknown', source=source_module.capture(typed_payload))
        typed_path.write_text(json.dumps(typed_human) + '\n')
        return typed

    older = typed_prompt()
    check('with nothing later the prompt is the newest', voids(older), None)
    later_pick = pick_row(ONE, {'Drop it?': 'Keep it'})
    check('a later pick voids an older prompt', 'newest' in (voids(older) or ''), True)
    pj.append(run, 'item_dropped', 'source-pm', {'prompt_id': later_pick['prompt_id']})
    check('a later pick that something cited does not', voids(older), None)
    older = typed_prompt()
    queued_prompt(WORDS, queued_attachment_row('source-pm', WORDS))
    check('a later queued message voids an older prompt', 'newest' in (voids(older) or ''), True)
    older = typed_prompt()
    pick_row(ONE, {'Drop it?': 'Keep it'}, {'Drop it?': {'notes': 'no'}})
    check('a later pick with a note voids an older prompt', 'newest' in (voids(older) or ''), True)
    older = typed_prompt()
    pick_row(ONE, {'Drop it?': 'Keep it'}, extra={'afkTimeoutMs': 60000})
    check('a later idle timeout does not', voids(older), None)
    pick_row(ONE, {'Drop it?': 'Keep it'}, sid='a-bystander', driving=False)
    check('a pick from a session that does not drive does not', voids(older), None)
    spent = pick_row(ONE, {'Drop it?': 'Keep it'})
    pj.append(run, 'agreement_proposed', 'source-pm',
              {'path': spent['payload']['source']['path'], 'tool_use_id': spent['payload']['source']['tool_use_id']})
    check('a pick a setup verb spent does not', voids(older), None)

    gone = pick_row(ONE, {'Drop it?': 'Approve drop-item i1'})
    pathlib.Path(gone['payload']['source']['path']).unlink()
    check('a pick with a deleted transcript resolves unknown', pj.prompt_origin(gone), 'unknown')
    check('its adoption reads as unverified with no crash', host.prompt_lookup(run, gone['prompt_id'])['origin'], 'unknown')
    check('its answer refuses with no crash', refusal(lambda: pick_answer_of(gone)) is not None, True)

    ph.end_programme(run, 'isolated source fixture complete')

print('programme-prompt-source.test.sh: {} passed, {} failed'.format(passed, failed))
sys.exit(1 if failed else 0)
PY
