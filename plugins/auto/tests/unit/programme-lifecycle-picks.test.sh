#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

echo "programme-lifecycle-picks.test.sh"

"$PY" - "$AUTO_ROOT" <<'PY'
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile

root = pathlib.Path(sys.argv[1])
sys.path.insert(0, str(root / 'lib'))
sys.path.insert(0, str(root / 'tests' / 'fixtures'))
from _bootstrap import load_lib_module
from programme_prompts import append_prompt as typed_prompt

PROG = str(root / 'lib/programme.py')
passed = failed = 0
with tempfile.TemporaryDirectory(prefix='auto-lifecycle-picks-') as work:
    work = pathlib.Path(work)
    for key in list(os.environ):
        if key.startswith('HERDR_') or key.startswith('REX_') or key.startswith('CLAUDE_AUTO_'):
            del os.environ[key]
    (work / 'secrets').write_text('')
    fakes = work / 'fakes'
    fakes.mkdir()
    for tool in ('board', 'herdr'):
        (fakes / tool).write_text('#!/bin/sh\nexit 0\n')
        (fakes / tool).chmod(0o755)
    os.environ.update(CLAUDE_AUTO_DATA_DIR=str(work / 'data'), CLAUDE_AUTO_TASKS_DIR=str(work / 'tasks'),
                      CLAUDE_AUTO_TEST_HARNESS='1', CLAUDE_AUTO_MACHINE='studio',
                      CLAUDE_PLUGIN_ROOT=str(root), CLAUDE_AUTO_SECRETS_FILE=str(work / 'secrets'),
                      CLAUDE_AUTO_PERSONAL_PROTOCOL=str(work / 'personal' / 'protocol.json'),
                      PATH=str(fakes) + os.pathsep + os.environ['PATH'])
    ph = load_lib_module('programme_home')
    pj = load_lib_module('programme_journal')
    ps = load_lib_module('programme_pick_source')
    prompt_source = load_lib_module('programme_prompt_source')
    fixes = load_lib_module('programme_fixes')
    core = load_lib_module('run_record_core')
    transcripts = work / 'transcripts'
    transcripts.mkdir()
    counter = [0]

    def check(name, condition, detail=''):
        global passed, failed
        if condition:
            passed += 1
            print('  PASS ' + name)
        else:
            failed += 1
            print('  FAIL ' + name + ': ' + str(detail)[-900:])

    def programme(sid, space):
        os.environ['CLAUDE_CODE_SESSION_ID'] = sid
        return ph.create_programme([space], sid)['run']

    def verb(sid, run, *args):
        env = dict(os.environ, CLAUDE_CODE_SESSION_ID=sid)
        return subprocess.run([sys.executable, PROG, *args, '--run', run], text=True, capture_output=True,
                              env=env, input='')

    def said(result):
        return result.stdout + result.stderr

    def ok(result):
        return result.returncode == 0

    def refused(result, text):
        return result.returncode != 0 and text in said(result)

    def driver(run):
        return core.read_run_record(ph.home_path(run), run).get('driving_session_id')

    def ended(run):
        return any(r['kind'] == 'programme_ended' for r in pj.read(run))

    def last(run, kind):
        return ([r for r in pj.read(run) if r['kind'] == kind] or [None])[-1]

    def offer(sid, run, key, command):
        result = verb(sid, run, 'offer', key, '--command', command)
        assert ok(result), said(result)
        return json.loads(result.stdout)

    def options(printed):
        return printed['input']['questions'][0]['options']

    def label_of(printed):
        return next(o['label'] for o in options(printed) if o['label'] != printed['decline'])

    def ask_row(sid, tool_use_id, questions):
        return {'type': 'assistant', 'uuid': 'a-' + tool_use_id, 'sessionId': sid, 'isSidechain': False,
                'message': {'role': 'assistant', 'content': [
                    {'type': 'tool_use', 'id': tool_use_id, 'name': 'AskUserQuestion',
                     'input': {'questions': questions}}]}}

    def pick(sid, run, questions, answer, annotations=None):
        counter[0] += 1
        tool_use_id = f'toolu_{counter[0]}'
        path = transcripts / (sid + '.jsonl')
        answers = {questions[0]['question']: answer}
        result = {'type': 'user', 'uuid': 'u-' + tool_use_id, 'sessionId': sid, 'isSidechain': False,
                  'sourceToolAssistantUUID': 'a-' + tool_use_id,
                  'permissionDecision': {'decision': 'accept', 'source': 'user_temporary'},
                  'toolUseResult': {'questions': questions, 'answers': answers, 'annotations': annotations or {}},
                  'message': {'role': 'user', 'content': [{'type': 'tool_result', 'tool_use_id': tool_use_id,
                                                           'content': 'answered'}]}}
        with path.open('a') as stream:
            stream.write(json.dumps(ask_row(sid, tool_use_id, questions)) + '\n')
            stream.write(json.dumps(result) + '\n')
        source = ps.capture({'session_id': sid, 'transcript_path': str(path), 'tool_name': 'AskUserQuestion',
                             'tool_use_id': tool_use_id, 'tool_input': {'questions': questions},
                             'tool_response': {'answers': answers, 'questions': questions},
                             'hook_event_name': 'PostToolUse'})
        return pj.append_prompt(run, sid, ps.summary(answers), 'unknown', source=source)['prompt_id']

    def picked(sid, run, printed, **kwargs):
        return pick(sid, run, printed['input']['questions'], label_of(printed), **kwargs)

    # Esc or "Chat about this" writes no pick row, so the picker stays the question just asked.
    def asked(sid, printed):
        counter[0] += 1
        with (transcripts / (sid + '.jsonl')).open('a') as stream:
            stream.write(json.dumps(ask_row(sid, f'toolu_open_{counter[0]}', printed['input']['questions'])) + '\n')

    def words(sid, run, text, source_name='typed'):
        counter[0] += 1
        path = transcripts / (sid + '.jsonl')
        prompt_row = f'turn-{counter[0]}'
        source = prompt_source.capture({'session_id': sid, 'prompt': text, 'prompt_id': prompt_row,
                                        'transcript_path': str(path)})
        entry = pj.append_prompt(run, sid, text, 'typed', source=source)
        with path.open('a') as stream:
            stream.write(json.dumps({'type': 'user', 'sessionId': sid, 'promptId': prompt_row,
                                     'promptSource': source_name, 'turnOrigin': 'human', 'origin': {'kind': 'human'},
                                     'entrypoint': 'cli', 'isSidechain': False,
                                     'message': {'role': 'user', 'content': text}}) + '\n')
        return entry['prompt_id']

    def typed_request(sid, run, verb_name, text):
        prompt_id = typed_prompt(run, sid, text)['prompt_id']
        source = pj.find_prompt(run, prompt_id)['payload']['source']
        pj.append(run, f'{verb_name}_request', sid, {'verb': verb_name, 'text': text, 'origin': 'typed',
                                                     'driving': True, 'lease_status': 'live', 'source': source},
                  cites=[prompt_id])

    # ---- End ----
    sid = 'end-pm'
    run = programme(sid, 'end-a')
    assert ok(verb(sid, run, 'add-item', 'mem:open', '--title', 'Still open'))
    printed = offer(sid, run, 'end-programme', 'end --why "nothing left"')
    label = label_of(printed)
    check('the end picker says it ends the programme', 'End' in label and '--' not in label, label)
    shown = next(o for o in options(printed) if o['label'] == label)['description']
    check('the end picker names the unfinished items', 'mem:open' in shown, shown)
    check('the end picker shows the reason', 'nothing left' in shown, shown)
    check('the end picker asks with the command first and the decline last',
          options(printed)[-1]['label'] == printed['decline'], options(printed))

    result = verb(sid, run, 'end', '--why', 'nothing left', '--prompt', pick(sid, run, printed['input']['questions'], printed['decline']))
    check('a pick of the decline ends nothing', result.returncode != 0 and not ended(run), said(result))
    check('a refused end keeps the driver', driver(run) == sid, driver(run))

    old = printed['input']['questions'][0]['options']
    reworded = [dict(printed['input']['questions'][0], question='Shall we wrap up?')]
    result = verb(sid, run, 'end', '--why', 'nothing left', '--prompt', pick(sid, run, reworded, label))
    check('a pick on a picker Auto did not print ends nothing', result.returncode != 0 and not ended(run), said(result))
    check('and its refusal names the end picker, not typing or the old label', 'offer' in said(result) and 'to type' not in said(result) and 'approval-label' not in said(result), said(result))

    plain = [{'question': 'End it?', 'header': 'End', 'multiSelect': False,
              'options': [{'label': 'Approve end', 'description': 'x'}, {'label': 'No', 'description': 'y'}]}]
    result = verb(sid, run, 'end', '--prompt', pick(sid, run, plain, 'Approve end'))
    check('the old label form does not end a programme', result.returncode != 0 and not ended(run), said(result))

    result = verb(sid, run, 'end', '--prompt', typed_prompt(run, sid, 'please fix the tests')['prompt_id'])
    check('a typed message that answers no offer ends nothing', result.returncode != 0 and not ended(run), said(result))

    result = verb(sid, run, 'end', '--prompt', words(sid, run, 'end it', 'suggestion_accepted'))
    check('an accepted suggestion ends nothing', result.returncode != 0 and not ended(run), said(result))

    other = pick(sid, run, printed['input']['questions'], label)
    result = verb('end-worker', run, 'end', '--why', 'nothing left', '--prompt', other)
    check("another session citing the PM's pick ends nothing", result.returncode != 0 and not ended(run), said(result))

    result = verb(sid, run, 'end', '--why', 'something else', '--prompt', other)
    check('a pick of the offered end does not approve another reason', refused(result, 'different command') and not ended(run), said(result))

    result = verb(sid, run, 'end', '--why', 'nothing left', '--without-rituals', '--prompt', other)
    check('a pick of the offered end does not approve skipping the rituals', refused(result, 'different command') and not ended(run), said(result))

    result = verb(sid, run, 'end', '--why', 'nothing left', '--prompt', other)
    check('a pick of the offered end ends the programme', ok(result) and ended(run), said(result))
    row = last(run, 'programme_ended')
    check('the end row cites the pick', other in (row.get('cites') or []), row)
    check('the end row says Shawn ended it, by a pick, with no request',
          row['payload'].get('reason') == 'ended_by_shawn' and row['payload'].get('request') is None
          and row['payload'].get('approval', {}).get('origin') == 'picked', row['payload'])
    check('the end verb still prints its clean-up', 'release-resources' in said(result), said(result))
    result = verb(sid, run, 'check-archive')
    check('a picked end counts as ended for the archive', 'the programme has not ended' not in said(result), said(result))

    sid2 = 'end-pm2'
    run2 = programme(sid2, 'end-b')
    printed = offer(sid2, run2, 'end-programme', 'end --without-rituals')
    check('skipping the rituals shows on the option', 'ritual' in label_of(printed), label_of(printed))
    result = verb(sid2, run2, 'end', '--prompt', picked(sid2, run2, printed))
    check('a pick that skips the rituals does not approve keeping them', refused(result, 'different command'), said(result))
    result = verb(sid2, run2, 'end', '--without-rituals', '--prompt', picked(sid2, run2, printed))
    check('the offered flag ends the programme', ok(result) and ended(run2), said(result))

    sid3 = 'end-pm3'
    run3 = programme(sid3, 'end-c')
    printed = offer(sid3, run3, 'end-programme', 'end')
    asked(sid3, printed)
    result = verb(sid3, run3, 'end', '--prompt', words(sid3, run3, 'yes, wrap it up'))
    check('own words with no reading end nothing, and the fix names --reads-as',
          refused(result, '--reads-as') and not ended(run3), said(result))
    asked(sid3, printed)
    said_id = words(sid3, run3, 'yes, wrap it up')
    result = verb(sid3, run3, 'end', '--prompt', said_id, '--reads-as', label_of(printed))
    check('own words with the reading end the programme', ok(result) and ended(run3), said(result))
    payload = last(run3, 'programme_ended')['payload']
    check('the end row records the reading and the quote',
          payload.get('read_as') == label_of(printed) and payload.get('read_by') == 'pm'
          and payload.get('quote') == 'yes, wrap it up', payload)
    check('the end verb prints the read-back', 'read_back' in result.stdout and label_of(printed) in result.stdout, said(result))

    sid4 = 'end-pm4'
    run4 = programme(sid4, 'end-d')
    typed_request(sid4, run4, 'end', '/auto:programme-end')
    result = verb(sid4, run4, 'end')
    check('a typed /auto:programme-end still ends the programme', ok(result) and ended(run4), said(result))
    payload = last(run4, 'programme_ended')['payload']
    check('a typed end still names its request', bool(payload.get('request')) and 'approval' not in payload, payload)

    # ---- Handover ----
    sid5 = 'hand-pm'
    run5 = programme(sid5, 'hand-a')
    printed = offer(sid5, run5, 'hand-pm', 'handover hand-next')
    label = label_of(printed)
    check('the handover picker names the target', 'hand-next' in label and '--' not in label, label)
    long_id = 'a' * 36
    long_label = label_of(offer(sid5, run5, 'hand-pm', f'handover {long_id} --without-rituals'))
    check('a full session id and the skipped rituals both fit the label', long_id in long_label and long_label.endswith('rituals'), long_label)
    printed = offer(sid5, run5, 'hand-pm', 'handover hand-next')
    check('the handover picker lists the decline after the command', options(printed)[-1]['label'] == printed['decline'], options(printed))

    pid = picked(sid5, run5, printed)
    result = verb(sid5, run5, 'handover', 'hand-wrong', '--prompt', pid)
    check('a pick naming one target does not hand over to another',
          refused(result, 'different command') and driver(run5) == sid5, said(result))
    result = verb(sid5, run5, 'handover', 'hand-next', '--prompt', typed_prompt(run5, sid5, 'hand it over please')['prompt_id'])
    check('a typed message that answers no offer hands nothing over', result.returncode != 0 and driver(run5) == sid5, said(result))
    result = verb('hand-worker', run5, 'handover', 'hand-next', '--prompt', pid)
    check("another session citing the PM's pick hands nothing over", result.returncode != 0 and driver(run5) == sid5, said(result))
    result = verb(sid5, run5, 'handover', 'hand-next', '--prompt', pid)
    check('a pick of the named target hands over', ok(result) and driver(run5) == 'hand-next', said(result))
    row = last(run5, 'handed_over')
    check('the handover row cites the pick and carries the approval, with no request',
          pid in (row.get('cites') or []) and row['payload'].get('request') is None
          and row['payload'].get('approval', {}).get('origin') == 'picked', row)
    result = verb('hand-next', run5, 'handover', sid5, '--prompt', pid)
    check('the same pick approves nothing for the new PM', result.returncode != 0 and driver(run5) == 'hand-next', said(result))

    sid6 = 'hand-pm2'
    run6 = programme(sid6, 'hand-b')
    printed = offer(sid6, run6, 'hand-pm', 'handover hand-next2')
    stale = picked(sid6, run6, printed)
    typed_request(sid6, run6, 'handover', '/auto:programme-handover hand-away')
    result = verb(sid6, run6, 'handover', 'hand-away')
    check('a typed /auto:programme-handover still hands over', ok(result) and driver(run6) == 'hand-away', said(result))
    typed_request('hand-away', run6, 'handover', f'/auto:programme-handover {sid6}')
    assert ok(verb('hand-away', run6, 'handover', sid6)), 'typed handback'
    result = verb(sid6, run6, 'handover', 'hand-next2', '--prompt', stale)
    check('a pick from before the PM last changed hands nothing over',
          result.returncode != 0 and driver(run6) == sid6, said(result))

    sid7 = 'hand-pm3'
    run7 = programme(sid7, 'hand-c')
    printed = offer(sid7, run7, 'hand-pm', 'handover hand-next3')
    asked(sid7, printed)
    said_id = words(sid7, run7, 'yes, move it there')
    result = verb(sid7, run7, 'handover', 'hand-other', '--prompt', said_id, '--reads-as', label_of(printed))
    check('own words approve only the target the picker named', result.returncode != 0 and driver(run7) == sid7, said(result))
    result = verb(sid7, run7, 'handover', 'hand-next3', '--prompt', said_id, '--reads-as', label_of(printed))
    check('own words with the reading hand over', ok(result) and driver(run7) == 'hand-next3', said(result))
    payload = last(run7, 'handed_over')['payload']
    check('the handover row records the reading', payload.get('read_as') == label_of(printed)
          and payload.get('quote') == 'yes, move it there', payload)
    check('the handover prints the read-back', 'read_back' in result.stdout, said(result))

    # ---- No line tells Shawn to type a command ----
    check('the end fix line points at the picker', 'offer' in fixes.fix_for('end') and 'type' not in fixes.fix_for('end'), fixes.fix_for('end'))
    check('the handover fix line points at the picker', 'offer' in fixes.fix_for('handover') and 'type' not in fixes.fix_for('handover'), fixes.fix_for('handover'))
    sid8 = 'hand-pm4'
    run8 = programme(sid8, 'hand-d')
    for name, args in (('end', ['end']), ('handover', ['handover', 'hand-x'])):
        result = verb(sid8, run8, *args)
        check(f'{name} with no request is refused with the picker as its fix',
              refused(result, 'fix:') and 'offer' in said(result), said(result))
        check(f'{name} refusal does not ask anyone to type', not re.search(r'\btype\b|\btypes\b', said(result).replace('no typed', '')), said(result))
    result = verb(sid8, run8, 'check-archive')
    check('the archive check does not ask anyone to type the end',
          'type /auto:programme-end' not in said(result) and 'offer' in said(result), said(result))
    banned = re.compile(r'(?:\btype:? |\btypes |to type )/auto:programme-(?:end|handover|takeover)')
    for name in ('programme_lifecycle.py', 'programme_archive.py', 'programme_fixes.py'):
        hits = banned.findall((root / 'lib' / name).read_text())
        check(f'{name} tells nobody to type a programme command', not hits, hits)

print(f'programme-lifecycle-picks.test.sh: {passed} passed, {failed} failed')
sys.exit(1 if failed else 0)
PY
