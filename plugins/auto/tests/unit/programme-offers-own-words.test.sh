#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

echo "programme-offers-own-words.test.sh"

"$PY" - "$AUTO_ROOT" <<'PY'
import copy
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
from registered_transcript import register
from programme_prompts import append_prompt as typed_prompt, queued_attachment_row, queued_user_row

PROG = str(root / 'lib/programme.py')
PROG_OFFERED = str(root / 'tests/fixtures/prog_offered.py')
DECLINE_FREE = ('--', 'Approve ', '<', ', ')

passed = failed = 0
with tempfile.TemporaryDirectory(prefix='auto-programme-offers-') as work:
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
    pa = load_lib_module('programme_approval')
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
            print('  FAIL ' + name + ': ' + str(detail)[:1200])

    def programme(sid, space):
        os.environ['CLAUDE_CODE_SESSION_ID'] = sid
        return ph.create_programme([space], sid)['run']

    def record(run):
        return core.read_run_record(ph.home_path(run), run)

    def edit(run, fn):
        core._with_locked_run_record(ph.home_path(run), run, fn)

    def verb(sid, run, *args, stdin=None):
        env = dict(os.environ, CLAUDE_CODE_SESSION_ID=sid)
        return subprocess.run([sys.executable, PROG, *args, '--run', run], text=True, capture_output=True,
                              env=env, input=stdin if stdin is not None else '')

    def offered_verb(sid, run, *args):
        return subprocess.run([sys.executable, PROG_OFFERED, *args, '--run', run], text=True, capture_output=True,
                              env=dict(os.environ, CLAUDE_CODE_SESSION_ID=sid), input='')

    def said(result):
        return result.stdout + result.stderr

    def ok(result):
        return result.returncode == 0

    def refused(result, text):
        return result.returncode != 0 and text in said(result)

    def offer(sid, run, key, *commands, stdin=None):
        args = ['offer', key]
        for command in commands:
            args += ['--command', command]
        result = verb(sid, run, *args, stdin=stdin)
        assert ok(result), said(result)
        return json.loads(result.stdout)

    def options(printed):
        return printed['input']['questions'][0]['options']

    def command_label(printed, index=0):
        return [o['label'] for o in options(printed) if o['label'] != printed['decline']][index]

    # What a PM's AskUserQuestion puts in the transcript, whatever the questions hold.
    def pick(sid, run, questions, answer, annotations=None, hook=False, driving=True):
        counter[0] += 1
        tool_use_id = f'toolu_{counter[0]}'
        path = register(sid, transcripts / (sid + '.jsonl'))
        question = questions[0]['question']
        answers = {question: answer}
        ask = {'type': 'assistant', 'uuid': 'a-' + tool_use_id, 'sessionId': sid, 'isSidechain': False,
               'message': {'role': 'assistant', 'content': [
                   {'type': 'tool_use', 'id': tool_use_id, 'name': 'AskUserQuestion',
                    'input': {'questions': questions}}]}}
        result = {'type': 'user', 'uuid': 'u-' + tool_use_id, 'sessionId': sid, 'isSidechain': False,
                  'sourceToolAssistantUUID': 'a-' + tool_use_id,
                  'permissionDecision': {'decision': 'accept', 'source': 'user_temporary'},
                  'toolUseResult': {'questions': questions, 'answers': answers, 'annotations': annotations or {}},
                  'message': {'role': 'user', 'content': [{'type': 'tool_result', 'tool_use_id': tool_use_id,
                                                           'content': 'answered'}]}}
        data = {'session_id': sid, 'transcript_path': str(path), 'tool_name': 'AskUserQuestion',
                'tool_use_id': tool_use_id, 'tool_input': {'questions': questions},
                'tool_response': {'answers': answers, 'questions': questions}, 'hook_event_name': 'PostToolUse'}
        with path.open('a') as stream:
            stream.write(json.dumps(ask) + '\n')
        if hook:
            out = subprocess.run(['bash', str(root / '.claude/hooks/on-posttooluse-askuser.sh')], text=True,
                                 capture_output=True, input=json.dumps(data),
                                 env=dict(os.environ, CLAUDE_CODE_SESSION_ID=sid))
            with path.open('a') as stream:
                stream.write(json.dumps(result) + '\n')
            context = json.loads(out.stdout)['hookSpecificOutput']['additionalContext']
            return json.loads(context.split('\n')[-2])
        with path.open('a') as stream:
            stream.write(json.dumps(result) + '\n')
        source = ps.capture(data)
        return pj.append_prompt(run, sid, ps.summary(answers), 'unknown', source=source, driving=driving)['prompt_id']

    def picked(sid, run, printed, index=0, **kwargs):
        return pick(sid, run, printed['input']['questions'], command_label(printed, index), **kwargs)

    def declined(sid, run, printed, **kwargs):
        return pick(sid, run, printed['input']['questions'], printed['decline'], **kwargs)

    def add_item(sid, run, key, title='A title'):
        result = verb(sid, run, 'add-item', key, '--title', title)
        assert ok(result), said(result)

    def state(run, key):
        return record(run)['programme']['items'][key]['state']

    def propose_rule(sid, run, rule_id, why='docs need a merge'):
        rule = {'id': rule_id, 'applies_when': {'change_kinds': ['evals_or_docs']}, 'requires': ['merged'],
                'evidence_bar': {'merged': 'merged at the gate'}, 'caveat': '', 'autonomy': 'act_and_tell',
                'added_by': 'pm', 'added_at': '2026-10-26T10:00:00Z', 'why': why}
        result = verb(sid, run, 'propose-rule', json.dumps(rule))
        assert ok(result), said(result)

    offers = load_lib_module('programme_offers')

    class Refused(Exception):
        pass

    c_sid = 'offer-c'
    allow_repo = pathlib.Path(os.path.realpath(work)) / 'allow-repo'
    (allow_repo / '.git').mkdir(parents=True)
    allow_file = allow_repo / '.claude' / 'settings.local.json'

    # ---- Own words: Shawn's message answers the question just asked ----
    w_sid = 'offer-words'
    w_run = programme(w_sid, 'offer-words')
    prompt_source = load_lib_module('programme_prompt_source')
    w_transcript = register(w_sid, transcripts / (w_sid + '.jsonl'))

    def wrote(row):
        with w_transcript.open('a') as stream:
            stream.write(json.dumps(row) + '\n')

    # The picker Auto printed is on the screen, and Shawn left it with Esc or "Chat about this": no pick row exists.
    def asked(printed):
        counter[0] += 1
        wrote({'type': 'assistant', 'uuid': f'a-open-{counter[0]}', 'sessionId': w_sid, 'isSidechain': False,
               'message': {'role': 'assistant', 'content': [
                   {'type': 'tool_use', 'id': f'toolu_open_{counter[0]}', 'name': 'AskUserQuestion',
                    'input': {'questions': printed['input']['questions']}}]}})

    # UserPromptSubmit fires at send time, so the row it journals holds the enqueue position; delivery lands later.
    def enqueued(text):
        wrote({'type': 'queue-operation', 'operation': 'enqueue', 'sessionId': w_sid, 'content': text})
        source = prompt_source.capture({'session_id': w_sid, 'prompt': text, 'prompt_id': 'running-turn',
                                        'transcript_path': str(w_transcript)})
        return pj.append_prompt(w_run, w_sid, text, 'typed', source=source)['prompt_id']

    def delivered(text):
        wrote(queued_attachment_row(w_sid, text))

    def said_to(text, prompt_source_name='typed'):
        counter[0] += 1
        prompt_row = f'turn-{counter[0]}'
        source = prompt_source.capture({'session_id': w_sid, 'prompt': text, 'prompt_id': prompt_row,
                                        'transcript_path': str(w_transcript)})
        entry = pj.append_prompt(w_run, w_sid, text, 'typed', source=source)
        wrote({'type': 'user', 'sessionId': w_sid, 'promptId': prompt_row, 'promptSource': prompt_source_name,
               'turnOrigin': 'human', 'origin': {'kind': 'human'}, 'entrypoint': 'cli', 'isSidechain': False,
               'message': {'role': 'user', 'content': text}})
        return entry['prompt_id']

    def drop_offer(key):
        add_item(w_sid, w_run, key)
        return offer(w_sid, w_run, 'drop', f'drop-item {key} --reason gone')

    def drop(key, prompt_id, *reads):
        return verb(w_sid, w_run, 'drop-item', key, '--reason', 'gone', '--prompt', prompt_id, *reads)

    def reads_as(printed, index=0):
        return ('--reads-as', command_label(printed, index))

    def still_open(key):
        return state(w_run, key) == 'open'

    def journal_row(kind, prompt_id):
        return next((r for r in pj.read(w_run) if r['kind'] == kind and prompt_id in (r.get('cites') or [])), None)

    # AE3: "yes drop it" names no item, reads as the drop option, and is recorded and shown.
    printed = drop_offer('mem:w1')
    asked(printed)
    words = said_to('yes drop it')
    result = drop('mem:w1', words, *reads_as(printed))
    check('own words with --reads-as the option approve, with no named-word check',
          ok(result) and state(w_run, 'mem:w1') == 'dropped', said(result))
    row = journal_row('item_dropped', words)
    payload = (row or {}).get('payload', {})
    stored = [r for r in pj.read(w_run) if r['kind'] == 'approval_offered'][-1]['payload']
    check('the journal records the reading, who read it, the offer and the quote',
          payload.get('read_as') == command_label(printed) and payload.get('read_by') == 'pm'
          and payload.get('offer_id') == stored['offer_id'] and payload.get('quote') == 'yes drop it', payload)
    shown = json.loads(result.stdout).get('read_back', '') if ok(result) else ''
    check('the verb prints the one-line read-back for Shawn',
          command_label(printed) in shown and 'wrong' in shown and '\n' not in shown, said(result))
    result = drop('mem:w1', words, *reads_as(printed))
    check('a second run on the same message approves nothing', result.returncode != 0, said(result))

    printed = drop_offer('mem:w2')
    asked(printed)
    words = said_to('yes drop it')
    result = drop('mem:w2', words)
    check('own words on an open offer without a reading are refused, and the fix names --reads-as',
          refused(result, '--reads-as') and still_open('mem:w2'), said(result))
    result = drop('mem:w2', words, '--reads-as', printed['decline'])
    check('a reading that is the decline approves nothing', result.returncode != 0 and still_open('mem:w2'), said(result))
    result = drop('mem:w2', words, '--reads-as', 'Something else')
    check('a reading that is no option of this command approves nothing',
          refused(result, '--reads-as') and still_open('mem:w2'), said(result))
    result = drop('mem:w2', words, *reads_as(printed))
    check('the same message still binds with the right reading after those refusals', ok(result), said(result))

    d_sid, d_new = 'words-driver', 'words-new-driver'
    d_run = programme(d_sid, 'words-driver')
    add_item(d_sid, d_run, 'mem:driver-words')
    printed = offer(d_sid, d_run, 'driver', 'drop-item mem:driver-words --reason gone')

    def hand_to_new_driver(rec):
        rec['driving_session_id'] = d_new
    edit(d_run, hand_to_new_driver)
    answered = pick(d_new, d_run, printed['input']['questions'], 'yes drop that one')
    result = verb(d_new, d_run, 'drop-item', 'mem:driver-words', '--reason', 'gone', '--prompt', answered,
                  *reads_as(printed))
    check('a new driver asks the old driver\'s picker, and his own words are refused',
          refused(result, 'another PM') and state(d_run, 'mem:driver-words') == 'open', said(result))

    # One message, one approval.
    add_item(w_sid, w_run, 'mem:w3')
    add_item(w_sid, w_run, 'mem:w4')
    many = offer(w_sid, w_run, 'many', 'drop-item mem:w3 --reason gone', 'drop-item mem:w4 --reason gone')
    asked(many)
    words = said_to('yes both')
    assert ok(drop('mem:w3', words, *reads_as(many, 0))), 'first of two'
    result = drop('mem:w4', words, *reads_as(many, 1))
    check('one message approves one command', result.returncode != 0 and still_open('mem:w4'), said(result))

    # ---- Other, and a pick with a note ----
    printed = drop_offer('mem:w5')
    other = pick(w_sid, w_run, printed['input']['questions'], 'yes drop it')
    result = drop('mem:w5', other)
    check('Other text without a reading approves nothing', result.returncode != 0 and still_open('mem:w5'), said(result))
    result = drop('mem:w5', other, *reads_as(printed))
    check('Other text "yes drop it" on a drop-item picker approves through the pick row',
          ok(result) and state(w_run, 'mem:w5') == 'dropped', said(result))
    check('Other text is the recorded quote and the pick is spent',
          (journal_row('item_dropped', other) or {}).get('payload', {}).get('quote') == 'yes drop it', other)
    printed_again = drop_offer('mem:w6')
    result = drop('mem:w6', other, *reads_as(printed_again))
    check('a spent Other answer approves nothing else', result.returncode != 0 and still_open('mem:w6'), said(result))
    question = printed_again['input']['questions'][0]['question']
    noted = pick(w_sid, w_run, printed_again['input']['questions'], command_label(printed_again),
                 annotations={question: {'notes': 'yes, it is finished'}})
    result = drop('mem:w6', noted)
    check('a noted pick without a reading approves nothing', refused(result, 'note') and still_open('mem:w6'), said(result))
    result = drop('mem:w6', noted, *reads_as(printed_again))
    check('a pick with a note is treated the same way as Other',
          ok(result) and state(w_run, 'mem:w6') == 'dropped', said(result))
    check('the note is the recorded quote',
          'yes, it is finished' in (journal_row('item_dropped', noted) or {}).get('payload', {}).get('quote', ''), noted)
    printed = drop_offer('mem:w7')
    question = printed['input']['questions'][0]['question']
    only_note = pick(w_sid, w_run, printed['input']['questions'], ps.NOTES_ONLY,
                     annotations={question: {'notes': 'drop it please'}})
    result = drop('mem:w7', only_note, *reads_as(printed))
    check('a notes-only answer binds like Other', ok(result) and state(w_run, 'mem:w7') == 'dropped', said(result))
    printed = drop_offer('mem:w8')
    question = printed['input']['questions'][0]['question']
    noted_no = pick(w_sid, w_run, printed['input']['questions'], printed['decline'],
                    annotations={question: {'notes': 'yes but later'}})
    result = drop('mem:w8', noted_no, *reads_as(printed))
    check('a decline with a note stays a decline', result.returncode != 0 and still_open('mem:w8'), said(result))
    other_hint = pick(w_sid, w_run, printed['input']['questions'], 'keep it for now', hook=True)
    check('the hook tells the PM that an Other answer is his own words and names no command to run',
          other_hint.get('offer', {}).get('own_words') is True and 'runs' not in other_hint.get('offer', {}), other_hint)

    # ---- Authority moves: a pick only (AE4) ----
    def authority_refused(name, printed, argv, label_index=0):
        text = 'ask the PM about repos'
        asked(printed)
        for how, prompt_id, reads in (
                ('Other text', pick(w_sid, w_run, printed['input']['questions'], text), True),
                ('Other text with no reading', pick(w_sid, w_run, printed['input']['questions'], text), False),
                ('a typed message', None, True),
                ('a typed message with no reading', None, False)):
            if prompt_id is None:
                asked(printed)
                prompt_id = said_to(text)
            extra = reads_as(printed, label_index) if reads else ()
            result = verb(w_sid, w_run, *argv, '--prompt', prompt_id, *extra)
            check(f'{name}: {how} is refused, and the fix says relay and ask again',
                  refused(result, 'relay') and 'ask' in said(result).lower(), said(result))

    add_item(w_sid, w_run, 'mem:perm')

    def seed_words(rec):
        rec['programme']['remit']['repos'] = [{'path': str(allow_repo), 'github': None}]
        rec['programme']['items']['mem:perm']['repo'] = str(allow_repo)
        rec['programme']['permission_proposals'] = [
            {'id': 'perm-w', 'state': 'open', 'operations': ['pr_checks'], 'rules': ['Bash(gh pr checks *)'],
             'settings_file': str(allow_file), 'items': ['mem:perm'], 'answers': [],
             'changed_at': '2026-01-01T00:00:00Z'},
            {'id': 'perm-x', 'state': 'open', 'rules': ['Bash(ls:*)'], 'settings_file': str(work / 'settings.json'),
             'items': [], 'answers': [], 'changed_at': '2026-01-01T00:00:00Z'}]
    edit(w_run, seed_words)
    authority_refused('widening', offer(w_sid, w_run, 'widen', 'adopt-autonomy flip_terms_change_stage act --widening'),
                      ['adopt-autonomy', 'flip_terms_change_stage', 'act', '--widening'])
    authority_refused('permission allow', offer(w_sid, w_run, 'allow', 'answer-permission perm-w allow'),
                      ['answer-permission', 'perm-w', 'allow'])
    check('own words on allow wrote no settings file', not allow_file.exists(), allow_file)
    assert ok(verb(w_sid, w_run, 'propose-agreement', '--project-term', 'naming=use kebab case', '--source', 'brief'))
    accept = offer(w_sid, w_run, 'accept', 'accept-agreement')
    authority_refused('accept', accept, ['accept-agreement'])
    check('AE4: no acceptance happened', not record(w_run)['programme']['agreement'].get('accepted'),
          record(w_run)['programme']['agreement'].get('accepted'))

    # ---- An accepted suggestion never binds an offer ----
    printed = drop_offer('mem:s1')
    asked(printed)
    suggested = said_to('yes drop it', 'suggestion_accepted')
    result = drop('mem:s1', suggested, *reads_as(printed))
    check('an accepted suggestion with a reading on an open offer approves nothing',
          refused(result, 'suggestion') and still_open('mem:s1'), said(result))
    result = drop('mem:s1', suggested)
    check('an accepted suggestion with no reading on an open offer approves nothing',
          refused(result, 'suggestion') and still_open('mem:s1'), said(result))
    add_item(w_sid, w_run, 'mem:s2')
    suggested = said_to('drop item mem:s2', 'suggestion_accepted')
    printed = offer(w_sid, w_run, 'later', 'drop-item mem:s2 --reason gone')
    asked(printed)
    result = drop('mem:s2', suggested)
    check('an accepted suggestion before an offer of that command approves nothing',
          refused(result, 'before') and still_open('mem:s2'), said(result))

    # ---- Own words on a behaviour, ritual or carry-over offer ----
    made = verb(w_sid, w_run, 'record-behaviour', '--when', 'on own words', '--do', 'read the board', '--prompt', picked(
        w_sid, w_run, offer(w_sid, w_run, 'made', "record-behaviour --when 'on own words' --do 'read the board'")))
    check('fixture: a behaviour in the own-words programme', ok(made), said(made))
    bid = json.loads(made.stdout)['behaviour']
    printed = offer(w_sid, w_run, 'retire-own', f'retire-behaviour {bid} --as retired')
    asked(printed)
    words = said_to('yes retire that')
    result = verb(w_sid, w_run, 'retire-behaviour', bid, '--as', 'retired', '--prompt', words, *reads_as(printed))
    check('own words approve retire-behaviour, with the reading on the row', ok(result)
          and journal_row('behaviour_retired', words)['payload'].get('read_as') == command_label(printed), said(result))
    made = verb(w_sid, w_run, 'record-ritual', '--when', 'on own words', '--trigger', 'end', '--step', 'read the board', '--prompt', picked(
        w_sid, w_run, offer(w_sid, w_run, 'made', "record-ritual --when 'on own words' --trigger end --step 'read the board'")))
    check('fixture: a ritual in the own-words programme', ok(made), said(made))
    rid = json.loads(made.stdout)['ritual']
    printed = offer(w_sid, w_run, 'skip-own', f'skip-ritual {rid} --why later')
    asked(printed)
    words = said_to('skip it this time')
    result = verb(w_sid, w_run, 'skip-ritual', rid, '--why', 'later', '--prompt', words, *reads_as(printed))
    check('own words approve skip-ritual, with the reading on the row', ok(result)
          and journal_row('ritual_skipped', words)['payload'].get('read_as') == command_label(printed), said(result))
    made = verb(w_sid, w_run, 'propose-behaviour', '--when', 'on proposals', '--do', 'read the proposal')
    assert ok(made), said(made)
    draft = json.loads(made.stdout)['behaviour']
    printed = offer(w_sid, w_run, 'apply-own', f'record-behaviour --from-proposal {draft}')
    asked(printed)
    words = said_to('yes but keep it short')
    result = verb(w_sid, w_run, 'record-behaviour', '--from-proposal', draft, '--prompt', words, *reads_as(printed))
    source = next(b for b in record(w_run)['programme']['behaviours'] if b['id'] == draft).get('source', {})
    check('own words on a behaviour draft record his words as his', ok(result)
          and source.get('wording') == 'shawn' and source.get('quote') == 'yes but keep it short', said(result) + str(source))

    add_item(w_sid, w_run, 'mem:cx')
    made = verb(w_sid, w_run, 'record-ruling', 'cx', '--kind', 'tool_choice', '--effect', 'grant', '--scope', 'pick tools',
                '--applies-to', 'mem:cx', '--prompt', picked(w_sid, w_run, offer(
                    w_sid, w_run, 'made', "record-ruling cx --kind tool_choice --effect grant --scope 'pick tools' --applies-to mem:cx")))
    check('fixture: a Ruling in the own-words programme', ok(made), said(made))

    def own_remit(rec):
        rec['programme']['remit'] = dict(rec['programme'].get('remit') or {},
                                         repos=[{'github': 'shawn/own', 'path': str(work / 'own')}])
    edit(w_run, own_remit)
    listed = verb(w_sid, w_run, 'carry-rulings')
    check('fixture: the carry-over offer is made', ok(listed), said(listed))
    printed = offer(w_sid, w_run, 'carry-own', 'carry-rulings cx')
    asked(printed)
    words = said_to('yes keep that for next time')
    result = verb(w_sid, w_run, 'carry-rulings', 'cx', '--prompt', words, *reads_as(printed))
    carried = next((r for r in pj.read(w_run) if r['kind'] == 'rulings_carried'), {})
    check('own words carry a Ruling: its row writes outside the common writer and still holds and prints the reading',
          ok(result) and carried.get('payload', {}).get('read_as') == command_label(printed)
          and 'read_back' in result.stdout, said(result))

    # ---- No open offer ----
    add_item(w_sid, w_run, 'mem:n1')
    words = said_to('yes drop it')
    result = drop('mem:n1', words, '--reads-as', 'Drop item mem:n1')
    check('a message with no open offer approves nothing', refused(result, 'no open offer') and still_open('mem:n1'), said(result))
    printed = offer(w_sid, w_run, 'unasked', 'drop-item mem:n1 --reason gone')
    words = said_to('yes drop it')
    result = drop('mem:n1', words, *reads_as(printed))
    check('an offer the PM never asked approves nothing', refused(result, 'no open offer') and still_open('mem:n1'), said(result))
    asked(printed)
    pick(w_sid, w_run, printed['input']['questions'], printed['decline'], hook=True)
    words = said_to('actually yes drop it')
    result = drop('mem:n1', words, *reads_as(printed))
    check('after a pick answered the question, a message does not reopen it',
          refused(result, 'no open offer') and still_open('mem:n1'), said(result))
    printed = offer(w_sid, w_run, 'second', 'drop-item mem:n1 --reason gone')
    asked(printed)
    add_item(w_sid, w_run, 'mem:n2')
    other_offer = offer(w_sid, w_run, 'other', 'drop-item mem:n2 --reason gone')
    asked(other_offer)
    words = said_to('yes drop it')
    result = drop('mem:n1', words, *reads_as(printed))
    check('only the question just asked binds, never an older offer',
          result.returncode != 0 and still_open('mem:n1'), said(result))
    result = drop('mem:n2', words, *reads_as(other_offer))
    check('the question just asked binds', ok(result), said(result))
    words = said_to('yes drop it')
    printed = drop_offer('mem:n3')
    asked(printed)
    result = drop('mem:n3', words, *reads_as(printed))
    check('a message typed before the offer approves nothing', result.returncode != 0 and still_open('mem:n3'), said(result))
    result = drop('mem:n3', words)
    check('a message typed before the offer approves nothing with no reading either',
          refused(result, 'before') and still_open('mem:n3'), said(result))
    words = said_to('yes drop it')
    said_to('wait, no')
    result = drop('mem:n3', words, *reads_as(printed))
    check('a later message Shawn has not had answered voids the earlier one',
          refused(result, 'newest') and still_open('mem:n3'), said(result))
    printed = drop_offer('mem:n4')
    asked(printed)
    words = said_to('yes drop it')
    def rename_n4(rec):
        rec['programme']['items']['mem:n4']['title'] = 'Another title'
    edit(w_run, rename_n4)
    result = drop('mem:n4', words, *reads_as(printed))
    check('the subject changing since the offer refuses own words',
          refused(result, 'changed since') and still_open('mem:n4'), said(result))

    # ---- Queued words: only the position they were enqueued at counts ----
    printed = drop_offer('mem:q1')
    asked(printed)
    words = enqueued('yes drop it')
    delivered('yes drop it')
    result = drop('mem:q1', words, *reads_as(printed))
    check('a message that came through as a queued attachment binds', ok(result), said(result))
    printed = drop_offer('mem:q2')
    asked(printed)
    words = enqueued('turn end yes')
    wrote(queued_user_row(w_sid, 'turn end yes'))
    result = drop('mem:q2', words, *reads_as(printed))
    check('a message that came through as a queued user row binds', ok(result), said(result))
    add_item(w_sid, w_run, 'mem:q3')
    words = enqueued('early yes drop mem:q3')
    printed = offer(w_sid, w_run, 'q3', 'drop-item mem:q3 --reason gone')
    asked(printed)
    delivered('early yes drop mem:q3')
    check('the early message still resolves as Shawn typing',
          pj.prompt_origin(pj.find_prompt(w_run, words)) == 'typed', words)
    result = drop('mem:q3', words, *reads_as(printed))
    check('enqueued before the offer and delivered after: does not bind',
          result.returncode != 0 and still_open('mem:q3'), said(result))
    result = drop('mem:q3', words)
    check('enqueued before the offer and delivered after: the old named-word path does not take it either',
          refused(result, 'before') and still_open('mem:q3'), said(result))
    add_item(w_sid, w_run, 'mem:q4')
    printed = offer(w_sid, w_run, 'q4', 'drop-item mem:q4 --reason gone')
    words = enqueued('between yes')
    asked(printed)
    delivered('between yes')
    result = drop('mem:q4', words, *reads_as(printed))
    check('enqueued after the offer row but before its asking row: does not bind',
          refused(result, 'no open offer') and still_open('mem:q4'), said(result))

    # Own words reach the other approval verbs through the same route.
    add_item(w_sid, w_run, 'mem:v1')
    assert ok(verb(w_sid, w_run, 'drop-item', 'mem:v1', '--reason', 'first'))
    printed = offer(w_sid, w_run, 'reopen', 'reopen-item mem:v1')
    asked(printed)
    result = verb(w_sid, w_run, 'reopen-item', 'mem:v1', '--prompt', said_to('yes bring it back'), *reads_as(printed))
    check('reopen-item binds on own words', ok(result), said(result))
    add_item(w_sid, w_run, 'mem:v2')
    assert ok(verb(w_sid, w_run, 'hand-item', 'mem:v2', '--question', 'Ship it?', '--kind', 'product_call'))
    printed = offer(w_sid, w_run, 'handed', 'answer-handed mem:v2 --choice decline')
    asked(printed)
    result = verb(w_sid, w_run, 'answer-handed', 'mem:v2', '--choice', 'decline', '--prompt', said_to('no thanks'), *reads_as(printed))
    check('answer-handed binds on own words', ok(result), said(result))
    assert ok(verb(w_sid, w_run, 'pause', 'pause-w', '--risk', 'safety', '--reason', 'hold'))
    printed = offer(w_sid, w_run, 'lift', 'lift-pause pause-w')
    asked(printed)
    result = verb(w_sid, w_run, 'lift-pause', 'pause-w', '--prompt', said_to('go ahead'), *reads_as(printed))
    check('lift-pause binds on own words', ok(result), said(result))
    printed = offer(w_sid, w_run, 'later', 'answer-permission perm-x not-now')
    asked(printed)
    result = verb(w_sid, w_run, 'answer-permission', 'perm-x', 'not-now', '--prompt', said_to('later please'),
                  *reads_as(printed))
    check('answer-permission not-now binds on own words, and the row keeps the reading',
          ok(result) and json.loads(result.stdout).get('read_as') == command_label(printed), said(result))

    add_item(w_sid, w_run, 'mem:v3')
    add_item(w_sid, w_run, 'mem:v4')
    printed = offer(w_sid, w_run, 'swap', 'swap-item mem:v3 mem:v4')
    asked(printed)
    result = verb(w_sid, w_run, 'swap-item', 'mem:v3', 'mem:v4', '--prompt', said_to('yes swap them'), *reads_as(printed))
    check('swap-item takes own words past the approval: only the worker count stops it here',
          not ok(result) and 'swap refused' in said(result) and 'exact label' not in said(result), said(result))

    def seed_hold(rec):
        rec['programme']['items']['mem:v3']['held'] = {'at': '2026-11-04T00:00:00Z', 'reason': 'focus'}
    edit(w_run, seed_hold)
    printed = offer(w_sid, w_run, 'override', 'override-focus mem:v3')
    asked(printed)
    words = said_to('yes let it start')
    result = verb(w_sid, w_run, 'override-focus', 'mem:v3', '--prompt', words, *reads_as(printed))
    check('override-focus binds on own words',
          ok(result) and record(w_run)['programme']['items']['mem:v3']['focus_override']['prompt_id'] == words, said(result))
    asked(printed)
    result = verb(w_sid, w_run, 'drop-item', 'mem:v4', '--reason', 'gone', '--prompt', said_to('drop item mem:v4'))
    check('words naming the item, on another command\'s open offer, approve nothing',
          refused(result, 'no open offer') and state(w_run, 'mem:v4') == 'open', said(result))
    result = verb(w_sid, w_run, 'drop-item', 'mem:v4', '--reason', 'gone', '--prompt', said_to('drop item mem:v4', 'suggestion_accepted'))
    check('an accepted suggestion naming the item, with no offer of it, approves nothing',
          refused(result, 'is an accepted suggestion') and state(w_run, 'mem:v4') == 'open', said(result))
    assert ok(verb(w_sid, w_run, 'hand-item', 'mem:v4', '--question', 'Ship it?', '--kind', 'product_call'))
    label_pick = pick(w_sid, w_run, [{'question': 'Ship?', 'header': 'Ship', 'multiSelect': False,
                                      'options': [{'label': 'Approve answer-handed mem:v4 --choice ship', 'description': ''},
                                                  {'label': 'No', 'description': ''}]}],
                      'Approve answer-handed mem:v4 --choice ship')
    result = verb(w_sid, w_run, 'answer-handed', 'mem:v4', '--choice', 'ship', '--prompt', label_pick)
    check('answer-handed has no old-label alias: its label names no facts',
          refused(result, 'answers a picker no offer printed') and state(w_run, 'mem:v4') == 'handed', said(result))

    def seed_disposal(rec):
        rec['programme'].setdefault(load_lib_module('programme_recovery').OPS_KEY, {})['op-w'] = {'state': 'uncertain', 'verb': 'start-worker'}
    edit(w_run, seed_disposal)
    printed = offer(w_sid, w_run, 'dispose', 'dispose-action --attempt op-w --as abandoned_unknown')
    asked(printed)
    result = verb(w_sid, w_run, 'dispose-action', '--attempt', 'op-w', '--as', 'abandoned_unknown',
                  '--prompt', said_to('yes abandon that'), *reads_as(printed))
    check('dispose-action binds on own words and prints the read-back',
          ok(result) and json.loads(result.stdout).get('read_as') == command_label(printed)
          and 'read_back' in json.loads(result.stdout), said(result))

    # ---- Takeover stays a pick of its option ----
    t2_sid = 'offer-t2'
    t2_run = programme(t2_sid, 'offer-t2')
    t2_take = offers.takeover_input('sess-driver')
    other_id = pick(c_sid, t2_run, t2_take['questions'], 'yes take over', driving=False)
    rows = pj.read(t2_run)
    try:
        taken = pa.takeover_pick(rows, pj.find_prompt(t2_run, other_id, rows), other_id, c_sid, 'sess-driver', Refused)
    except Refused as exc:
        taken = str(exc)
    check('takeover by Other text is refused', isinstance(taken, str), taken)
    typed_id = pj.append_prompt(t2_run, c_sid, 'yes take over', 'typed')['prompt_id']
    rows = pj.read(t2_run)
    try:
        taken = pa.takeover_pick(rows, pj.find_prompt(t2_run, typed_id, rows), typed_id, c_sid, 'sess-driver', Refused)
    except Refused as exc:
        taken = str(exc)
    check('takeover by a typed message is refused', isinstance(taken, str), taken)

    # ---- Every pick test in the focus file goes through offer ----
    focus_runs = [subprocess.run(['bash', str(root / 'tests/unit' / name)], text=True, capture_output=True)
                  for name in ('programme-focus.test.sh', 'programme-focus-queue.test.sh')]
    tails = [run.stdout.strip().splitlines()[-1] if run.stdout.strip() else run.stderr[-400:] for run in focus_runs]
    focus_lines = [line for run in focus_runs for line in run.stdout.splitlines()]
    check('programme-focus passes with its picks through offer',
          all(run.returncode == 0 and ' 0 failed' in tail for run, tail in zip(focus_runs, tails)),
          '\n'.join(tails) + '\n' + '\n'.join(line for line in focus_lines if '✗' in line)[:900])
    counts = [re.search(r'through offer: (\d+) offered, (\d+) refused', run.stdout) for run in focus_runs]
    check('the focus run really offered, and no offer was refused',
          all(found is not None and int(found.group(1)) > 0 and found.group(2) == '0' for found in counts),
          '\n'.join(line for line in focus_lines if line.startswith(('through offer', 'refused')))[:900])
    print('  focus ' + '; '.join(found.group(0) if found else 'printed no offer count' for found in counts))

print(f'programme-offers-own-words.test.sh: {passed} passed, {failed} failed')
sys.exit(1 if failed else 0)
PY
