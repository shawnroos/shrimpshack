#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

echo "programme-offers.test.sh"

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
from programme_prompts import append_prompt as typed_prompt, queued_attachment_row, queued_user_row
from registered_transcript import register

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

    sid = 'offer-a'
    run = programme(sid, 'offer-a')

    # ---- the verb and the picker it prints ----
    add_item(sid, run, 'mem:one')
    one = offer(sid, run, 'drop-one', "drop-item mem:one --reason 'not needed'")
    check('offer journals approval_offered and answers with its kind',
          one['kind'] == 'approval_offered' and any(r['kind'] == 'approval_offered' for r in pj.read(run)), one)
    check('a one-command offer prints one question with 2 options',
          len(one['input']['questions']) == 1 and len(options(one)) == 2, one['input'])
    check('the picker holds only the fields AskUserQuestion takes',
          set(one['input']) == {'questions'}
          and set(one['input']['questions'][0]) == {'question', 'header', 'multiSelect', 'options'}
          and one['input']['questions'][0]['multiSelect'] is False
          and len(one['input']['questions'][0]['header']) <= 12
          and all(set(o) == {'label', 'description'} for o in options(one)), one['input'])
    row = [r for r in pj.read(run) if r['kind'] == 'approval_offered'][-1]['payload']
    check('the decline option stores no command',
          [o for o in row['options'] if 'argv_hash' not in o] == [o for o in row['options'] if o['label'] == one['decline']]
          and len(row['options']) == 2, row['options'])
    check('every option but the decline stores its command hash',
          all(o.get('argv_hash', '').startswith('sha256:') for o in row['options'] if o['label'] != one['decline']),
          row['options'])
    check('the row stores a hash of the whole questions array', row['asked_hash'].startswith('sha256:'), row)
    check('on an ordinary command the decline comes last', options(one)[-1]['label'] == one['decline'], options(one))

    # ---- Pick of an offered option running its command ----
    prompt = picked(sid, run, one)
    result = verb(sid, run, 'drop-item', 'mem:one', '--reason', 'not needed', '--prompt', prompt)
    check('a pick of an offered option running its command approves it',
          ok(result) and state(run, 'mem:one') == 'dropped', said(result))

    # ---- the PM changes what Auto printed ----
    add_item(sid, run, 'mem:two')
    printed = offer(sid, run, 'drop-two', "drop-item mem:two --reason gone")
    label = command_label(printed)
    for name, change in (('description', lambda q: q['options'][0].update(description='Keeps the item safe')),
                         ('question', lambda q: q.update(question='Keep this item?')),
                         ('label', lambda q: q['options'][0].update(label='Keep the item'))):
        changed = copy.deepcopy(printed['input']['questions'])
        change(changed[0])
        answer = changed[0]['options'][0]['label']
        result = verb(sid, run, 'drop-item', 'mem:two', '--reason', 'gone', '--prompt', pick(sid, run, changed, answer))
        check(f'the PM changing the {name} Auto printed is refused',
              result.returncode != 0 and state(run, 'mem:two') == 'open', said(result))
    other = pick(sid, run, printed['input']['questions'], 'Keep it, I changed my mind')
    result = verb(sid, run, 'drop-item', 'mem:two', '--reason', 'gone', '--prompt', other)
    check('an Other answer on an offered picker approves nothing',
          refused(result, 'not one of the options') and state(run, 'mem:two') == 'open', said(result))
    noted = picked(sid, run, printed, annotations={printed['input']['questions'][0]['question']: {'notes': 'but wait'}})
    result = verb(sid, run, 'drop-item', 'mem:two', '--reason', 'gone', '--prompt', noted)
    check('a noted pick of an offered option approves nothing',
          refused(result, 'carries a note') and state(run, 'mem:two') == 'open', said(result))

    # ---- The PM offers one command and runs another ----
    add_item(sid, run, 'mem:three')
    result = verb(sid, run, 'drop-item', 'mem:three', '--reason', 'gone', '--prompt', picked(sid, run, printed))
    check('offering drop-item of one item and running it on another is refused',
          refused(result, 'approved a different command') and state(run, 'mem:three') == 'open', said(result))
    result = verb(sid, run, 'drop-item', 'mem:two', '--reason', 'other words', '--prompt', picked(sid, run, printed))
    check('a changed argument on the same verb and item is refused',
          refused(result, 'approved a different command') and state(run, 'mem:two') == 'open', said(result))
    result = verb(sid, run, 'reopen-item', 'mem:two', '--prompt', picked(sid, run, printed))
    check('a different verb is refused', refused(result, 'approved a different command'), said(result))

    # ---- A pick spent once ----
    spent = picked(sid, run, printed)
    first = verb(sid, run, 'drop-item', 'mem:two', '--reason', 'gone', '--prompt', spent)
    result = verb(sid, run, 'reopen-item', 'mem:two', '--prompt', spent)
    check('a pick spent once, then cited again, is refused',
          ok(first) and refused(result, 'already used') and state(run, 'mem:two') == 'dropped', said(first) + said(result))

    # ---- One transcript read on the pick path: a tampered row still approves nothing ----
    class Refused(Exception):
        def __init__(self, reason, fix=None):
            super().__init__(reason)

    def bind_row(prompt_id, tamper=None):
        rows = pj.read(run)
        row = pj.find_prompt(run, prompt_id, rows)
        if tamper:
            at = rows.index(row)
            row = rows[at] = copy.deepcopy(row)
            tamper(row['payload']['source'])
        argv = ['drop-item', 'mem:tamper', '--reason', 'gone']
        try:
            return pa._picked(rows, row, record(run), pa.Asked(argv[0], argv), prompt_id, Refused)
        except Refused as exc:
            return str(exc)

    add_item(sid, run, 'mem:tamper')
    printed = offer(sid, run, 'tamper', 'drop-item mem:tamper --reason gone')
    prompt = picked(sid, run, printed)
    reads = []
    read_pick = ps.read_pick
    ps.read_pick = lambda row: reads.append(row) or read_pick(row)
    bound = bind_row(prompt)
    ps.read_pick = read_pick
    check('an untampered pick binds with one transcript read', isinstance(bound, dict) and len(reads) == 1, (bound, len(reads)))
    for name, tamper in (('answer hash', lambda s: s.update(answers_hash='0' * 64)),
                         ('recorded answers', lambda s: s.update(answers={'Other?': 'Other'})),
                         ('window hash', lambda s: s.update(window_hash='0' * 64)),
                         ('tool use id', lambda s: s.update(tool_use_id='toolu_forged'))):
        check(f'a row with a changed {name} approves nothing',
              'no offer printed' in str(bind_row(prompt, tamper)), bind_row(prompt, tamper))
    rows = pj.read(run)
    try:
        pj.judged_pick(rows, pj.find_prompt(run, prompt, rows), None)
        unverified = None
    except ValueError as exc:
        unverified = str(exc)
    check('a pick that did not verify is refused however it reached the check',
          'does not verify against the transcript' in str(unverified), unverified)
    transcript = transcripts / (sid + '.jsonl')
    original = transcript.read_text()
    assert 'Drop item mem:tamper' in original
    transcript.write_text(original.replace('Drop item mem:tamper', 'Drop item mem:tamperX'))
    result = verb(sid, run, 'drop-item', 'mem:tamper', '--reason', 'gone', '--prompt', prompt)
    transcript.write_text(original)
    check('a transcript rewritten after the pick approves nothing, end to end',
          result.returncode != 0 and state(run, 'mem:tamper') != 'dropped', said(result))

    # ---- Facts changed since the offer ----
    add_item(sid, run, 'mem:renamed', 'Old name')
    printed = offer(sid, run, 'rename', 'drop-item mem:renamed --reason gone')
    prompt = picked(sid, run, printed)

    def rename(rec):
        rec['programme']['items']['mem:renamed']['title'] = 'New name'
    edit(run, rename)
    result = verb(sid, run, 'drop-item', 'mem:renamed', '--reason', 'gone', '--prompt', prompt)
    check('an item renamed since the offer is refused, and the refusal names a new offer',
          refused(result, 'changed since') and 'programme.sh offer' in said(result)
          and state(run, 'mem:renamed') == 'open', said(result))
    propose_rule(sid, run, 'rule-changes', 'first reason')
    printed = offer(sid, run, 'rule', 'adopt-rule rule-changes')
    prompt = picked(sid, run, printed)

    def change_rule(rec):
        next(r for r in rec['programme']['proposed_rules'] if r['id'] == 'rule-changes')['why'] = 'a different reason'
    edit(run, change_rule)
    result = verb(sid, run, 'adopt-rule', 'rule-changes', '--prompt', prompt)
    check('a proposal changed since the offer is refused', refused(result, 'changed since'), said(result))

    # ---- Stored content: stdin ----
    extra = work / 'remit-extra'
    subprocess.run(['git', 'init', '-q', str(extra)], check=True)
    other_repo = work / 'remit-other'
    subprocess.run(['git', 'init', '-q', str(other_repo)], check=True)
    remit = copy.deepcopy(record(run)['programme'].get('remit') or {})
    wide = copy.deepcopy(remit)
    wide.setdefault('repos', []).append({'path': str(extra)})
    wrong = copy.deepcopy(remit)
    wrong.setdefault('repos', []).append({'path': str(other_repo)})
    printed = offer(sid, run, 'remit', 'set-remit', stdin=json.dumps(wide))
    check('a remit widening says it widens', 'iden' in command_label(printed), printed['input'])
    check('a remit widening puts the decline first', options(printed)[0]['label'] == printed['decline'], options(printed))
    row = [r for r in pj.read(run) if r['kind'] == 'approval_offered'][-1]['payload']
    check('the offer stores a content hash', any(str(o.get('content_hash', '')).startswith('sha256:') for o in row['options']),
          row['options'])
    prompt = picked(sid, run, printed)
    result = verb(sid, run, 'set-remit', '--prompt', prompt, stdin=json.dumps(wrong))
    check('stdin that differs from the offered remit change is refused',
          refused(result, 'differs') and str(other_repo) not in json.dumps(record(run)['programme']['remit']), said(result))
    result = verb(sid, run, 'set-remit', '--prompt', prompt, stdin=json.dumps(wide))
    check('stdin that matches the offered remit change is approved',
          ok(result) and str(extra) in json.dumps(record(run)['programme']['remit']), said(result))
    def another_repo(rec):
        rec['programme']['remit']['repos'].append({'path': str(other_repo), 'github': None})
    edit(run, another_repo)
    narrow = copy.deepcopy(record(run)['programme']['remit'])
    narrow['repos'] = [r for r in narrow['repos'] if r['path'] != str(extra)]
    printed = offer(sid, run, 'remit-less', 'set-remit', stdin=json.dumps(narrow))
    check('a remit narrowing does not claim to widen, and the decline comes last',
          'iden' not in command_label(printed) and options(printed)[-1]['label'] == printed['decline'], printed['input'])

    # ---- The wrapper: an offer that fails is not a refusal ----
    add_item(sid, run, 'mem:wrapped')
    typed = typed_prompt(run, sid, 'drop it')['prompt_id']
    result = offered_verb(sid, run, 'drop-item', 'mem:wrapped', '--reason', 'one', '--reason', 'two', '--prompt', typed)
    check('prog_offered exits 97 with the offer failure when the offer fails',
          result.returncode == 97 and 'offer failed' in result.stderr and '--reason' in result.stderr
          and state(run, 'mem:wrapped') == 'open', (result.returncode, said(result)))

    # ---- Session restart and new driver ----
    add_item(sid, run, 'mem:restart')
    printed = offer(sid, run, 'restart', 'drop-item mem:restart --reason gone')
    prompt = picked(sid, run, printed)
    os.environ.pop('CLAUDE_CODE_SESSION_ID', None)
    result = verb(sid, run, 'drop-item', 'mem:restart', '--reason', 'gone', '--prompt', prompt)
    check('a new process with the same session id still binds the pick', ok(result), said(result))
    r_sid, n_sid = 'offer-r', 'offer-n'
    r_run = programme(r_sid, 'offer-r')
    add_item(r_sid, r_run, 'mem:driver')
    printed = offer(r_sid, r_run, 'driver', 'drop-item mem:driver --reason gone')
    old_pick = picked(r_sid, r_run, printed)

    def new_driver(rec):
        rec['driving_session_id'] = n_sid
    edit(r_run, new_driver)
    result = verb(n_sid, r_run, 'drop-item', 'mem:driver', '--reason', 'gone', '--prompt', old_pick)
    check('a new driver cannot use the last driver\'s pick', result.returncode != 0 and state(r_run, 'mem:driver') == 'open', said(result))
    new_pick = picked(n_sid, r_run, printed)
    result = verb(n_sid, r_run, 'drop-item', 'mem:driver', '--reason', 'gone', '--prompt', new_pick)
    check('a new driver cannot use the last driver\'s offer',
          refused(result, 'another PM') and state(r_run, 'mem:driver') == 'open', said(result))
    printed = offer(n_sid, r_run, 'driver', 'drop-item mem:driver --reason gone')
    result = verb(n_sid, r_run, 'drop-item', 'mem:driver', '--reason', 'gone', '--prompt', picked(n_sid, r_run, printed))
    check('a new driver\'s own offer binds', ok(result), said(result))
    result = verb('stranger', run, 'offer', 'nope', '--command', 'reopen-item mem:one')
    check('a session that does not drive cannot offer', refused(result, 'only the programme\'s driving session'), said(result))

    # ---- The decline ----
    add_item(sid, run, 'mem:decline')
    printed = offer(sid, run, 'decline', 'drop-item mem:decline --reason gone')
    context = declined(sid, run, printed, hook=True)
    check('the hook tells the PM a decline runs nothing', context.get('offer', {}).get('declined') is True, context)
    rows = pj.read(run)
    check('a decline journals approval_declined citing the pick',
          [r for r in rows if r['kind'] == 'approval_declined'][-1]['cites'] == [context['prompt_id']], rows[-1])
    result = verb(sid, run, 'drop-item', 'mem:decline', '--reason', 'gone', '--prompt', context['prompt_id'])
    check('a pick of the decline runs nothing and spends the pick',
          refused(result, 'already used') and state(run, 'mem:decline') == 'open', said(result))
    plain_decline = declined(sid, run, printed)
    result = verb(sid, run, 'drop-item', 'mem:decline', '--reason', 'gone', '--prompt', plain_decline)
    check('a decline the hook did not journal still approves nothing',
          refused(result, 'declined') and state(run, 'mem:decline') == 'open', said(result))
    context = picked(sid, run, printed, hook=True)
    check('the hook names the command an offered option runs, as a hint',
          'drop-item mem:decline' in context.get('offer', {}).get('runs', ''), context)
    result = verb(sid, run, 'drop-item', 'mem:decline', '--reason', 'gone', '--prompt', context['prompt_id'])
    check('a pick journaled by the real hook approves', ok(result), said(result))
    free = pick(sid, run, [{'question': 'Which view?', 'header': 'View', 'multiSelect': False,
                            'options': [{'label': 'Left', 'description': ''}, {'label': 'Right', 'description': ''}]}],
                'Left', hook=True)
    check('a steering picker with no offer gets no offer hint', 'offer' not in free, free)

    # ---- Several commands, one picker ----
    add_item(sid, run, 'mem:a')
    add_item(sid, run, 'mem:b')
    add_item(sid, run, 'mem:c')
    add_item(sid, run, 'mem:d')
    many = offer(sid, run, 'many', 'drop-item mem:a --reason x', 'drop-item mem:b --reason x', 'drop-item mem:c --reason x')
    check('three commands make 4 options', len(options(many)) == 4, options(many))
    result = verb(sid, run, 'drop-item', 'mem:a', '--reason', 'x', '--prompt', picked(sid, run, many, index=1))
    check('a pick binds to its own option only', refused(result, 'approved a different command'), said(result))
    result = verb(sid, run, 'drop-item', 'mem:b', '--reason', 'x', '--prompt', picked(sid, run, many, index=1))
    check('the same pick runs the command its option names', ok(result) and state(run, 'mem:b') == 'dropped', said(result))
    result = verb(sid, run, 'offer', 'over', '--command', 'drop-item mem:a --reason x', '--command',
                  'drop-item mem:c --reason x', '--command', 'reopen-item mem:b', '--command', 'drop-item mem:d --reason x')
    check('four commands are refused: a question holds 4 options and one is the decline',
          result.returncode != 0 and 'at most 3' in said(result), said(result))
    result = verb(sid, run, 'offer', 'dup', '--command', 'drop-item mem:a --reason x', '--command', 'drop-item mem:a --reason x')
    check('two options with one label are refused', result.returncode != 0 and 'same text' in said(result), said(result))

    # ---- default-deny and the label rules ----
    for command, needle in (('focus-note --agents 3', 'takes no approval'),
                            ('takeover --replace x', 'become-pm'),
                            ('drop-item <item> --reason x', 'placeholder'),
                            ('answer-handed mem:a --choice maybe', '--choice ship|decline'),
                            ('move-ritual r1 --to nowhere', '--to programme|repo|personal'),
                            ('retire-ritual r1 --as gone', '--as retired|undone')):
        result = verb(sid, run, 'offer', 'deny', '--command', command)
        check(f'offer refuses {command!r}', result.returncode != 0 and needle in said(result), said(result))
    result = verb(sid, run, 'offer', 'Bad Key!', '--command', 'reopen-item mem:a')
    check('offer refuses a question key that is not a short slug', result.returncode != 0, said(result))
    result = verb(sid, run, 'offer', 'none')
    check('offer needs a command', result.returncode != 0, said(result))

    add_item(sid, run, 'mem:comma', 'One, two, three')
    offers = load_lib_module('programme_offers')
    result = verb(sid, run, 'offer', 'op', '--command', 'drop-item mem:comma --reason x --op abc --prompt p1 --run r1')
    stored = [r for r in pj.read(run) if r['kind'] == 'approval_offered'][-1]['payload']['options']
    check('the offer binds a command without --op, --prompt and --run, as the verb sees it',
          ok(result) and any(o.get('argv_hash') == offers.argv_hash(['drop-item', 'mem:comma', '--reason', 'x']) for o in stored),
          said(result))

    # ---- The verbs ----
    def seed(rec):
        prog = rec['programme']
        prog['permission_proposals'] = [
            {'id': p, 'state': 'open', 'rules': ['Bash(ls:*)'], 'settings_file': str(work / 'settings.json'),
             'items': [], 'answers': [], 'changed_at': '2026-01-01T00:00:00Z'} for p in ('perm-ok', 'perm-no', 'perm-later')]
    edit(run, seed)
    add_item(sid, run, 'mem:handed')
    add_item(sid, run, 'mem:reopen')
    assert ok(verb(sid, run, 'drop-item', 'mem:reopen', '--reason', 'first'))
    handed = verb(sid, run, 'hand-item', 'mem:handed', '--question', 'Ship it?', '--kind', 'product_call')
    assert ok(handed), said(handed)
    assert ok(verb(sid, run, 'pause', 'pause-1', '--risk', 'safety', '--reason', 'hold'))
    propose_rule(sid, run, 'rule-ok')
    behaviour = typed_prompt(run, sid, 'record behaviour on picks: use small steps')['prompt_id']
    ritual = typed_prompt(run, sid, 'record a ritual')['prompt_id']
    recorded = offered_verb(sid, run, 'record-behaviour', '--prompt', behaviour, '--when', 'on picks', '--do', 'use small steps')
    behaviour_id = json.loads(recorded.stdout).get('behaviour') if ok(recorded) else None
    check('fixture: a behaviour is recorded', behaviour_id, said(recorded))
    recorded = offered_verb(sid, run, 'record-ritual', '--prompt', ritual, '--when', 'at start', '--trigger', 'start',
                    '--step', 'read the handover')
    ritual_id = json.loads(recorded.stdout).get('ritual') if ok(recorded) else None
    check('fixture: a ritual is recorded', ritual_id, said(recorded))

    def behaviour_named(words):
        typed = typed_prompt(run, sid, 'record behaviour ' + words)['prompt_id']
        made = offered_verb(sid, run, 'record-behaviour', '--prompt', typed, '--when', words, '--do', 'use small steps')
        assert ok(made), said(made)
        return json.loads(made.stdout)['behaviour']

    def ritual_named(words):
        typed = typed_prompt(run, sid, 'record a ritual ' + words)['prompt_id']
        made = offered_verb(sid, run, 'record-ritual', '--prompt', typed, '--when', words, '--trigger', 'start',
                    '--step', 'read ' + words)
        assert ok(made), said(made)
        return json.loads(made.stdout)['ritual']

    keep_behaviour = behaviour_named('on keeps')
    second_ritual = ritual_named('at the second start')
    keep_ritual = ritual_named('at the third start')
    def seed_requirement(rec):
        context = load_lib_module('programme_context')
        rec['programme'].setdefault(context.CONTEXT_KEY, {}).setdefault('requirements', {})['req-1'] = [
            {'rev': 1, 'state': 'pending_acceptance', 'at': '2026-01-01T00:00:00Z', 'text': 'it works', 'checks': [],
             'source': {}, 'delta': {}, 'supersedes': None, 'superseded_by': None, 'accepted': None}]
    edit(run, seed_requirement)

    def seed_operation(rec):
        rec['programme'].setdefault(load_lib_module('programme_recovery').OPS_KEY, {})['op-1'] = {'state': 'uncertain', 'verb': 'start-worker'}
    edit(run, seed_operation)
    add_item(sid, run, 'mem:swap-out', 'Going out')
    add_item(sid, run, 'mem:swap-in', 'Coming in')

    # Each runs end to end: offer, pick, the real verb, with every named-word check still in force.
    flows = (
        ('adopt-rule', ['adopt-rule', 'rule-ok']),
        ('adopt-autonomy', ['adopt-autonomy', 'flip_terms_change_stage', 'propose']),
        ('adopt-check', ['adopt-check', 'owner/repo', 'verified.lookup', '["git", "status"]']),
        ('amend-term', ['amend-term', 'cadence', 'on_change', '--why', 'quieter']),
        ('record-ruling', ['record-ruling', 'flow-ruling', '--effect', 'decided', '--kind', 'work_sequencing', '--scope', 'a draft']),
        ('close-ruling', ['close-ruling', 'flow-ruling', '--as', 'withdrawn']),
        ('drop-item', ['drop-item', 'mem:comma', '--reason', 'one, two']),
        ('reopen-item', ['reopen-item', 'mem:reopen']),
        ('answer-handed', ['answer-handed', 'mem:handed', '--choice', 'ship', '--kind', 'evals_or_docs']),
        ('lift-pause', ['lift-pause', 'pause-1']),
        ('answer-permission no', ['answer-permission', 'perm-no', 'no']),
        ('answer-permission not-now', ['answer-permission', 'perm-later', 'not-now']),
        ('move-behaviour', ['move-behaviour', behaviour_id, '--to', 'personal']),
        ('keep-behaviours', ['keep-behaviours', keep_behaviour, '--to', 'personal']),
        ('record-behaviour', ['record-behaviour', '--when', 'on offers', '--do', 'use small steps']),
        ('retire-behaviour', ['retire-behaviour', behaviour_named('on retiring'), '--as', 'retired']),
        ('record-ritual', ['record-ritual', '--when', 'at offers', '--trigger', 'end', '--step', 'read the board']),
        ('move-ritual', ['move-ritual', second_ritual, '--to', 'personal']),
        ('keep-rituals', ['keep-rituals', keep_ritual, '--to', 'personal']),
        ('accept-context', ['accept-context', 'req-1']),
        ('dispose-action', ['dispose-action', '--attempt', 'op-1', '--as', 'abandoned_unknown']),
        ('start-ritual', ['start-ritual', ritual_id]),
        ('run-ritual', ['run-ritual', ritual_id, '--outcome', 'it ran']),
        ('skip-ritual', ['skip-ritual', ritual_id, '--why', 'not today']),
        ('retire-ritual', ['retire-ritual', ritual_id, '--as', 'retired']),
    )
    import shlex
    for name, argv in flows:
        printed = offer(sid, run, 'flow', shlex.join(argv))
        label = command_label(printed)
        check(f'{name}: the label is plain text', not any(bad in label for bad in DECLINE_FREE), label)
        result = verb(sid, run, *argv, '--prompt', picked(sid, run, printed))
        check(f'{name}: approved through offer', ok(result), said(result))

    # ---- Authority moves ----
    def authority(printed):
        return options(printed)[0]['label'] == printed['decline']

    printed = offer(sid, run, 'widen', 'adopt-autonomy flip_terms_change_stage act --widening')
    check('a widening says it widens', 'iden' in command_label(printed) and not any(b in command_label(printed) for b in DECLINE_FREE), printed['input'])
    check('adopt-autonomy --widening puts the decline first', authority(printed), options(printed))
    result = verb(sid, run, 'adopt-autonomy', 'flip_terms_change_stage', 'act', '--widening', '--prompt', picked(sid, run, printed))
    check('adopt-autonomy --widening is approved through offer, with the widen check in force', ok(result), said(result))
    allow_repo = pathlib.Path(os.path.realpath(work)) / 'allow-repo'
    (allow_repo / '.git').mkdir(parents=True)
    allow_file = allow_repo / '.claude' / 'settings.local.json'

    def seed_allow(rec):
        prog = rec['programme']
        prog['remit']['repos'] = [{'path': str(allow_repo), 'github': None}]
        prog['items']['mem:comma']['repo'] = str(allow_repo)
        prog['permission_proposals'].append(
            {'id': 'perm-allow', 'state': 'open', 'operations': ['pr_checks'], 'rules': ['Bash(gh pr checks *)'],
             'settings_file': str(allow_file), 'items': ['mem:comma'], 'answers': [],
             'changed_at': '2026-01-01T00:00:00Z'})
    edit(run, seed_allow)
    printed = offer(sid, run, 'allow', 'answer-permission perm-allow allow')
    check('allowing a permission puts the decline first', authority(printed), options(printed))
    printed = offer(sid, run, 'mixed', 'reopen-item mem:comma', 'answer-permission perm-allow allow')
    check('one authority move in a picker puts the decline first', authority(printed), options(printed))
    printed = offer(sid, run, 'hand', 'answer-permission perm-ok applied')
    check('applied writes nothing, so it is no authority move', not authority(printed), options(printed))

    # ---- accept: the terms digest is the offer's subject ----
    a_sid = 'offer-accept'
    a_run = programme(a_sid, 'offer-accept')
    assert ok(verb(a_sid, a_run, 'propose-agreement', '--project-term', 'naming=use kebab case', '--source', 'brief'))
    printed = offer(a_sid, a_run, 'accept', 'accept-agreement')
    digest = pa.terms_digest(ph.normalize_programme(record(a_run)['programme']))
    check('the accept option names the terms digest', digest in command_label(printed), printed['input'])
    check('accept-agreement puts the decline first', authority(printed), options(printed))
    stale = picked(a_sid, a_run, printed)

    def change_terms(rec):
        rec['programme']['agreement']['terms']['stop_rule']['value'] = 'never_stop'
    edit(a_run, change_terms)
    result = verb(a_sid, a_run, 'accept-agreement', '--prompt', stale)
    check('terms changed since the offer refuses the accept',
          refused(result, 'changed since') and not record(a_run)['programme']['agreement']['accepted'], said(result))
    printed = offer(a_sid, a_run, 'accept', 'accept-agreement')
    result = verb(a_sid, a_run, 'accept-agreement', '--prompt', picked(a_sid, a_run, printed))
    check('a pick of the accept offer needs no --terms flag and accepts',
          ok(result) and record(a_run)['programme']['agreement']['accepted'], said(result))

    # ---- A focus swap and a focus override ----
    printed = offer(sid, run, 'swap', 'swap-item mem:swap-out mem:swap-in')
    label = command_label(printed)
    check('swap-item: the label is plain text and tells the items apart',
          not any(bad in label for bad in DECLINE_FREE) and 'mem:swap-out' in label and 'mem:swap-in' in label, label)
    printed = offer(sid, run, 'over', 'override-focus mem:swap-in')
    check('override-focus: the label is plain text', not any(bad in command_label(printed) for bad in DECLINE_FREE),
          printed['input'])

    # ---- The old label approves nothing ----
    add_item(sid, run, 'mem:alias')
    label_text = 'Approve reopen-item mem:alias'
    check('approval-label is gone', verb(sid, run, 'approval-label', 'reopen-item', 'mem:alias').returncode == 2)
    assert ok(verb(sid, run, 'drop-item', 'mem:alias', '--reason', 'first'))
    free_form = [{'question': 'Reopen?', 'header': 'Reopen', 'multiSelect': False,
                  'options': [{'label': label_text, 'description': ''}, {'label': 'No', 'description': ''}]}]
    result = verb(sid, run, 'reopen-item', 'mem:alias', '--prompt', pick(sid, run, free_form, label_text))
    check('a pick of the old label with no offer approves nothing',
          refused(result, 'answers a picker no offer printed'), said(result))
    assert ok(verb(sid, run, 'reopen-item', 'mem:alias', '--prompt', picked(sid, run, offer(sid, run, 'again', 'reopen-item mem:alias'))))
    bound = offer(sid, run, 'old', 'drop-item mem:alias --reason second')
    result = verb(sid, run, 'drop-item', 'mem:alias', '--reason', 'second', '--prompt',
                  pick(sid, run, bound['input']['questions'], 'Approve drop-item mem:alias --reason second'))
    check('on an offered picker the old label is not an option, so it approves nothing',
          refused(result, 'not one of the options'), said(result))

    # ---- Takeover: a pure renderer, compared on session id ----
    take = offers.takeover_input('sess-driver')
    question = take['questions'][0]
    labels = [o['label'] for o in question['options']]
    check('the takeover picker prints 2 options with the decline first', len(labels) == 2 and labels[0] == offers.DECLINE, labels)
    check('the takeover option is plain text naming the session id',
          'sess-driver' in labels[1] and '--' not in labels[1] and 'Approve ' not in labels[1], labels)
    check('the takeover option is a pure function of the driver',
          offers.takeover_input('sess-driver') == take and offers.takeover_input('sess-other') != take, take)

    class Refused(Exception):
        pass

    t_sid, c_sid = 'offer-t', 'offer-c'
    t_run = programme(t_sid, 'offer-t')

    def takeover_row(questions, answer):
        prompt_id = pick(c_sid, t_run, questions, answer, driving=False)
        rows = pj.read(t_run)
        return rows, pj.find_prompt(t_run, prompt_id, rows), prompt_id

    def takeover(rows, row, prompt_id, driver):
        try:
            return pa.takeover_pick(rows, row, prompt_id, c_sid, driver, Refused)
        except Refused as exc:
            return str(exc)

    rows, row, prompt_id = takeover_row(take['questions'], labels[1])
    check('a pick of the plain option approves the takeover of that session',
          takeover(rows, row, prompt_id, 'sess-driver') == {'origin': 'picked', 'answer': labels[1]},
          takeover(rows, row, prompt_id, 'sess-driver'))
    check('the same pick refuses once another session drives',
          isinstance(takeover(rows, row, prompt_id, 'sess-other'), str), 'approved')
    rows, row, prompt_id = takeover_row(take['questions'], offers.DECLINE)
    check('a pick of the takeover decline approves nothing', isinstance(takeover(rows, row, prompt_id, 'sess-driver'), str), 'approved')
    reworded = copy.deepcopy(take['questions'])
    reworded[0]['options'][1]['description'] = 'Nothing much'
    rows, row, prompt_id = takeover_row(reworded, labels[1])
    check('a reworded takeover picker approves nothing', isinstance(takeover(rows, row, prompt_id, 'sess-driver'), str), 'approved')
    source = (root / 'lib/programme_lifecycle.py').read_text()
    check('the takeover comparison stays inside the cited route, under the leases lock',
          '_with_leases_lock' in source and 'presence["session_id"]' in source, 'lifecycle moved')

print(f'programme-offers.test.sh: {passed} passed, {failed} failed')
sys.exit(1 if failed else 0)
PY
