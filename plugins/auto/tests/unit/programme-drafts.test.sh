#!/usr/bin/env bash
# Rulings and remit drafts: one picker shows the draft, and the record says whose wording it is.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

echo "programme-drafts.test.sh"

"$PY" - "$AUTO_ROOT" <<'PY'
import json
import os
import pathlib
import shlex
import subprocess
import sys
import tempfile

root = pathlib.Path(sys.argv[1])
sys.path.insert(0, str(root / 'lib'))
sys.path.insert(0, str(root / 'tests' / 'fixtures'))
from _bootstrap import load_lib_module

PROG = str(root / 'lib/programme.py')
passed = failed = 0
with tempfile.TemporaryDirectory(prefix='auto-programme-drafts-') as work:
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
    psrc = load_lib_module('programme_prompt_source')
    pc = load_lib_module('programme_context')
    pv = load_lib_module('programme_view_agreement')
    carry = load_lib_module('programme_carryover')
    core = load_lib_module('run_record_core')
    transcripts = work / 'transcripts'
    transcripts.mkdir()
    counter = [0]
    SID = 'draft-pm'
    os.environ['CLAUDE_CODE_SESSION_ID'] = SID
    RUN = ph.create_programme(['drafts'], SID)['run']
    path = transcripts / (SID + '.jsonl')

    def check(name, condition, detail=''):
        global passed, failed
        if condition:
            passed += 1
            print('  PASS ' + name)
        else:
            failed += 1
            print('  FAIL ' + name + ': ' + str(detail)[:1200])

    def verb(*args, stdin=None):
        return subprocess.run([sys.executable, PROG, *args, '--run', RUN], text=True, capture_output=True,
                              env=dict(os.environ, CLAUDE_CODE_SESSION_ID=SID), input=stdin if stdin is not None else '')

    def said(result):
        return result.stdout + result.stderr

    def ok(result):
        return result.returncode == 0

    def refused(result, text):
        return result.returncode != 0 and text in said(result)

    def offer(key, *commands, stdin=None):
        args = ['offer', key]
        for command in commands:
            args += ['--command', command]
        result = verb(*args, stdin=stdin)
        assert ok(result), said(result)
        return json.loads(result.stdout)

    def offer_argv(key, argv, stdin=None):
        return offer(key, shlex.join(argv), stdin=stdin)

    def options(printed):
        return printed['input']['questions'][0]['options']

    def label_of(printed):
        return next(o['label'] for o in options(printed) if o['label'] != printed['decline'])

    def text_of(printed):
        return next(o['description'] for o in options(printed) if o['label'] != printed['decline'])

    def authority(printed):
        return options(printed)[0]['label'] == printed['decline']

    def write(row):
        with path.open('a') as stream:
            stream.write(json.dumps(row) + '\n')

    def pick(printed, answer=None, annotations=None, hook=False, questions=None):
        counter[0] += 1
        tool_use_id = f'toolu_{counter[0]}'
        questions = questions or printed['input']['questions']
        answer = label_of(printed) if answer is None else answer
        answers = {questions[0]['question']: answer}
        write({'type': 'assistant', 'uuid': 'a-' + tool_use_id, 'sessionId': SID, 'isSidechain': False,
               'message': {'role': 'assistant', 'content': [
                   {'type': 'tool_use', 'id': tool_use_id, 'name': 'AskUserQuestion',
                    'input': {'questions': questions}}]}})
        data = {'session_id': SID, 'transcript_path': str(path), 'tool_name': 'AskUserQuestion',
                'tool_use_id': tool_use_id, 'tool_input': {'questions': questions},
                'tool_response': {'answers': answers, 'questions': questions}, 'hook_event_name': 'PostToolUse'}
        result = {'type': 'user', 'uuid': 'u-' + tool_use_id, 'sessionId': SID, 'isSidechain': False,
                  'sourceToolAssistantUUID': 'a-' + tool_use_id,
                  'permissionDecision': {'decision': 'accept', 'source': 'user_temporary'},
                  'toolUseResult': {'questions': questions, 'answers': answers, 'annotations': annotations or {}},
                  'message': {'role': 'user', 'content': [{'type': 'tool_result', 'tool_use_id': tool_use_id,
                                                           'content': 'answered'}]}}
        if hook:
            out = subprocess.run(['bash', str(root / '.claude/hooks/on-posttooluse-askuser.sh')], text=True,
                                 capture_output=True, input=json.dumps(data),
                                 env=dict(os.environ, CLAUDE_CODE_SESSION_ID=SID))
            write(result)
            return json.loads(json.loads(out.stdout)['hookSpecificOutput']['additionalContext'].split('\n')[-2])
        write(result)
        return pj.append_prompt(RUN, SID, ps.summary(answers), 'unknown', source=ps.capture(data))['prompt_id']

    def asked(printed):
        counter[0] += 1
        write({'type': 'assistant', 'uuid': f'a-open-{counter[0]}', 'sessionId': SID, 'isSidechain': False,
               'message': {'role': 'assistant', 'content': [
                   {'type': 'tool_use', 'id': f'toolu_open_{counter[0]}', 'name': 'AskUserQuestion',
                    'input': {'questions': printed['input']['questions']}}]}})

    def typed(text, prompt_source='typed'):
        counter[0] += 1
        turn = f'turn-{counter[0]}'
        source = psrc.capture({'session_id': SID, 'prompt': text, 'prompt_id': turn, 'transcript_path': str(path)})
        entry = pj.append_prompt(RUN, SID, text, 'typed', source=source)
        write({'type': 'user', 'sessionId': SID, 'promptId': turn, 'promptSource': prompt_source, 'turnOrigin': 'human',
               'origin': {'kind': 'human'}, 'entrypoint': 'cli', 'isSidechain': False,
               'message': {'role': 'user', 'content': text}})
        return entry['prompt_id']

    def said_after(printed, text):
        asked(printed)
        return typed(text)

    def programme():
        return ph.normalize_programme(core.read_run_record(ph.home_path(RUN), RUN)['programme'])

    def edit(fn):
        core._with_locked_run_record(ph.home_path(RUN), RUN, fn)

    def revisions(rid):
        return pc.block(programme())['decisions'].get(rid) or []

    def last(rid):
        found = revisions(rid)
        return found[-1] if found else {}

    def last_row(kind):
        return next((r for r in reversed(pj.read(RUN)) if r['kind'] == kind), {})

    def ruling(rid, *more, effect='decided', kind='work_sequencing', scope='keep the draft short'):
        return ['record-ruling', rid, '--effect', effect, '--kind', kind, '--scope', scope, *more]

    def cites(argv, prompt_id, *more):
        return verb(*argv, '--prompt', prompt_id, *more)

    def reads(printed):
        return ('--reads-as', label_of(printed))

    def shown_row(rid):
        return next(r for r in pv.rulings(programme()) if r['id'] == rid)

    # ---- Draft picked: the Ruling binds and the record says the PM wrote it ----
    argv = ruling('d-picked')
    printed = offer_argv('draft', argv)
    check('a draft Ruling shows its text on the picker', 'keep the draft short' in text_of(printed), printed['input'])
    check('a draft Ruling is not an authority move: the command comes first', not authority(printed), printed['input'])
    result = cites(argv, pick(printed))
    check('a picked draft binds the Ruling', ok(result) and last('d-picked').get('state') == 'accepted', said(result))
    check('a picked draft is marked pm_draft', last('d-picked').get('wording') == 'pm_draft', last('d-picked'))
    check('the quote of a picked draft is the draft', last('d-picked').get('quote') == 'keep the draft short', last('d-picked'))
    check('the journal row says pm_draft', last_row('ruling_recorded').get('payload', {}).get('wording') == 'pm_draft',
          last_row('ruling_recorded'))
    offered = last_row('approval_offered').get('payload', {}).get('offer_id')
    check('the record keeps an approval reference to the offer',
          (last('d-picked').get('approved') or {}).get('offer_id') == offered and offered, last('d-picked'))
    label = pv.ruling_label(shown_row('d-picked'))
    check('the view does not quote a draft as his words', '"keep the draft short"' not in label and 'PM' in label, label)
    in_force = next((line for line in said(verb('rules')).splitlines() if 'ruling d-picked:' in line), '')
    check("the rules a PM reads say the wording is the PM's",
          "the PM's wording" in in_force and '"keep the draft short"' not in in_force, in_force)

    # ---- Other on a draft: his text is the content ----
    argv = ruling('d-other')
    printed = offer_argv('draft', argv)
    words = 'only touch the docs folder'
    prompt_id = pick(printed, words)
    result = cites(argv, prompt_id)
    check('Other on a draft with no reading is refused, so a decline never becomes content',
          refused(result, '--reads-as') and not revisions('d-other'), said(result))
    result = cites(argv, prompt_id, *reads(printed))
    check('Other on a draft binds with no second picker', ok(result) and last('d-other').get('state') == 'accepted', said(result))
    check('Other on a draft makes his text the scope', last('d-other').get('scope') == words, last('d-other'))
    check('Other on a draft is marked shawn', last('d-other').get('wording') == 'shawn', last('d-other'))
    check('his text is the quote', last('d-other').get('quote') == words, last('d-other'))
    check('the view shows his words as his', f'"{words}"' in pv.ruling_label(shown_row('d-other')), shown_row('d-other'))
    check('the read-back says his words became the text', 'your words' in said(result).lower(), said(result))

    argv = ruling('d-chat')
    printed = offer_argv('draft', argv)
    words = 'only the changelog'
    result = cites(argv, said_after(printed, words), *reads(printed))
    check('his chat words on a draft become the content',
          ok(result) and last('d-chat').get('scope') == words and last('d-chat').get('wording') == 'shawn',
          said(result) + str(last('d-chat')))

    argv = ruling('d-note')
    printed = offer_argv('draft', argv)
    question = printed['input']['questions'][0]['question']
    result = cites(argv, pick(printed, annotations={question: {'notes': 'but only on Fridays'}}), *reads(printed))
    check('a pick with a note counts as his words on a draft',
          ok(result) and last('d-note').get('scope') == 'but only on Fridays' and last('d-note').get('wording') == 'shawn',
          said(result) + str(last('d-note')))

    # ---- Long text is never cut ----
    argv = ruling('d-long')
    printed = offer_argv('draft', argv)
    result = cites(argv, pick(printed, 'x ' * 300), *reads(printed))
    check('long Other text is refused, not silently cut', refused(result, '500') and not revisions('d-long'), said(result))
    argv = ruling('d-fits')
    printed = offer_argv('draft', argv)
    result = cites(argv, pick(printed, 'y' * 500), *reads(printed))
    check('Other text at the cap is kept whole', ok(result) and last('d-fits').get('scope') == 'y' * 500, said(result))
    printed = offer_argv('draft', ruling('d-wide', scope='z' * 500))
    check('a draft at the cap shows whole on the picker', 'z' * 500 in text_of(printed), text_of(printed))
    result = verb('offer', 'draft', '--command', shlex.join(ruling('d-over', scope='z' * 501)))
    check('a draft over the cap cannot be offered', refused(result, '500'), said(result))

    # ---- Legacy rows ----
    def legacy(rec):
        rec['programme']['context']['decisions']['d-legacy'] = [
            {'rev': 1, 'state': 'accepted', 'at': '2026-01-01T00:00:00Z', 'kind': 'work_sequencing', 'effect': 'decided',
             'scope': 's', 'reason': None, 'limits': [], 'requirements': [], 'applies_to': ['programme'], 'until': None,
             'quote': 'his old words', 'replies_to': None, 'baseline': None, 'delta': None, 'supersedes': None,
             'superseded_by': None, 'source': {'class': 'human_input', 'prompt_id': 'p0', 'origin_label': 'typed',
                                               'origin_verified': True},
             'accepted': {'at': '2026-01-01T00:00:00Z', 'prompt_id': 'p0', 'origin_verified': True}}]
    edit(legacy)
    check('a legacy row with no wording reads as shawn', shown_row('d-legacy')['wording'] == 'shawn', shown_row('d-legacy'))
    check('a legacy row still shows as his words', '"his old words"' in pv.ruling_label(shown_row('d-legacy')),
          pv.ruling_label(shown_row('d-legacy')))
    old_change = {'at': 't', 'kind': 'k', 'term': 't1', 'text': 'x', 'source': 's', 'quote': 'old'}
    check('a legacy change row still credits Shawn', 'Shawn:' in pv._change_row(old_change)['text'], old_change)
    check('a draft change row does not', 'Shawn:' not in pv._change_row(dict(old_change, wording='pm_draft'))['text'], '')

    # ---- The unchanged compare ignores the new fields ----
    argv = ruling('d-picked')
    printed = offer_argv('draft', argv)
    result = cites(argv, pick(printed))
    check('the new fields do not make an unchanged Ruling look changed',
          ok(result) and json.loads(result.stdout).get('unchanged') is True and len(revisions('d-picked')) == 1, said(result))

    # ---- Authority: a new or wider grant takes a pick, and says it widens ----
    argv = ruling('g-new', effect='grant', scope='the PM picks the order')
    printed = offer_argv('grant', argv)
    check('a new grant is an authority move', authority(printed), printed['input'])
    check('a new grant says it widens', 'iden' in label_of(printed), label_of(printed))
    for how, answer in (('Other', pick), ('chat', said_after)):
        result = cites(argv, answer(printed, 'fine, go on'), *reads(printed))
        check(f'a grant by {how} is refused, and the fix says relay and ask again',
              refused(result, 'relay') and not revisions('g-new'), said(result))
        printed = offer_argv('grant', argv)
    result = cites(argv, pick(printed))
    check('a grant by pick binds at once', ok(result) and last('g-new').get('state') == 'accepted', said(result))
    check('a grant by pick records its baseline', last('g-new').get('baseline') is not None, last('g-new'))

    assert ok(verb('add-item', 'mem:a', '--title', 'First'))
    narrow = ruling('g-limited', '--limit', 'no merges', '--applies-to', 'mem:a', effect='grant')
    assert ok(cites(narrow, pick(offer_argv('grant', narrow))))
    argv = ruling('g-limited', '--applies-to', 'programme', '--applies-to', 'mem:a', effect='grant')
    printed = offer_argv('wider', argv)
    check('a wider grant is an authority move', authority(printed), printed['input'])
    check('a wider grant says what it drops and adds', 'no merges' in text_of(printed) and 'programme' in text_of(printed),
          text_of(printed))
    for how, answer in (('Other', pick), ('chat', said_after)):
        result = cites(argv, answer(printed, 'yes widen it'), *reads(printed))
        check(f'a widening grant by {how} is refused', refused(result, 'relay') and len(revisions('g-limited')) == 1,
              said(result))
        printed = offer_argv('wider', argv)
    result = cites(argv, pick(printed))
    current = pc.in_force(revisions('g-limited')) or {}
    check('a widening grant by pick is in force at once', ok(result) and current.get('rev') == 2 and current.get('limits') == [],
          said(result))

    # ---- accept-context on a pending Ruling takes one picker ----
    assert ok(verb(*ruling('d-pending', scope='a pending draft')))
    printed = offer('accept', 'accept-context d-pending')
    result = cites(['accept-context', 'd-pending'], pick(printed))
    check('accept-context binds a pending Ruling by pick', ok(result) and last('d-pending').get('state') == 'accepted', said(result))
    check('accepting by pick marks the draft',
          last('d-pending').get('wording') == 'pm_draft' and last('d-pending').get('quote') == 'a pending draft',
          last('d-pending'))
    assert ok(verb(*ruling('g-pending', effect='grant', scope='a pending grant')))
    printed = offer('accept', 'accept-context g-pending')
    check('accepting a new pending grant is an authority move', authority(printed), printed['input'])
    result = cites(['accept-context', 'g-pending'], said_after(printed, 'ok'), *reads(printed))
    check('a pending grant by chat is refused', refused(result, 'relay'), said(result))
    printed = offer('accept', 'accept-context g-pending')
    assert ok(cites(['accept-context', 'g-pending'], pick(printed)))
    check('a pending grant by pick binds with a baseline', last('g-pending').get('baseline') is not None, last('g-pending'))
    assert ok(verb(*ruling('d-word', scope='a second pending draft')))
    printed = offer('accept', 'accept-context d-word')
    result = cites(['accept-context', 'd-word'], said_after(printed, 'yes that one'), *reads(printed))
    check('accepting a non-widening Ruling in his words carries a reading, and the draft stays',
          ok(result) and json.loads(result.stdout).get('read_as') == label_of(printed)
          and last('d-word').get('scope') == 'a second pending draft' and last('d-word').get('wording') == 'shawn', said(result))

    long_scope = 'w' * 500
    assert ok(verb(*ruling('d-long-pending', scope=long_scope)))
    printed = offer('accept', 'accept-context d-long-pending')
    check('accepting a long pending draft shows all of it', long_scope in text_of(printed), text_of(printed))

    # ---- Paths with no offer stay closed ----
    argv = ruling('d-nooffer')
    printed = offer_argv('draft', argv)
    reworded = [dict(printed['input']['questions'][0], question='Reworded?')]
    result = cites(argv, pick(printed, questions=reworded))
    check('a picker Auto did not print approves no Ruling', result.returncode != 0 and not revisions('d-nooffer'), said(result))
    check('approval-label does not exist for a draft verb', verb('approval-label', 'record-ruling', 'x').returncode != 0, '')
    label_said = said(verb('approval-label', 'set-remit'))
    check('approval-label on set-remit points to offer', 'offer' in label_said and 'typed' not in label_said, label_said)
    old_label = [{'question': 'Old?', 'header': 'old', 'multiSelect': False,
                  'options': [{'label': 'Approve ' + shlex.join(argv), 'description': ''}, {'label': 'No', 'description': ''}]}]
    result = cites(argv, pick(printed, 'Approve ' + shlex.join(argv), questions=old_label))
    check('a pick of the old exact label binds no Ruling', refused(result, 'approves no record-ruling')
          and not revisions('d-nooffer'), said(result))
    naming = typed('record d-nooffer work_sequencing programme', 'suggestion_accepted')
    result = cites(argv, naming)
    check('an accepted suggestion that names everything binds no Ruling', refused(result, 'approves no record-ruling')
          and not revisions('d-nooffer'), said(result))
    assert ok(verb(*ruling('d-gap', scope='waits for an offer')))
    result = cites(['close-ruling', 'd-gap', '--as', 'withdrawn'], typed('an unrelated remark'))
    check('a typed message that answers no offer closes no Ruling', result.returncode != 0 and last('d-gap').get('state') != 'closed',
          said(result))
    check('its fix says to offer, not to type', 'offer' in said(result) and 'to type' not in said(result), said(result))
    result = cites(ruling('d-gap2'), typed('another unrelated remark'))
    check('a typed message that answers no offer binds no Ruling', result.returncode != 0 and not revisions('d-gap2'), said(result))
    check('its fix also says to offer', 'offer' in said(result) and 'to type' not in said(result), said(result))

    # ---- close-ruling ----
    argv = ['close-ruling', 'd-other', '--as', 'withdrawn', '--why', 'the docs work ended']
    printed = offer_argv('close', argv)
    check('closing a decided Ruling shows the draft reason', 'the docs work ended' in text_of(printed), text_of(printed))
    check('closing a decided Ruling takes his words', not authority(printed), printed['input'])
    result = cites(argv, pick(printed))
    closed = last('d-other').get('closed') or {}
    check('close-ruling binds by pick', ok(result) and closed.get('why') == 'the docs work ended'
          and closed.get('wording') == 'pm_draft', said(result) + str(closed))
    argv = ['close-ruling', 'd-chat', '--as', 'withdrawn', '--why', 'a draft reason']
    printed = offer_argv('close', argv)
    result = cites(argv, pick(printed, 'he changed his mind'), *reads(printed))
    closed = last('d-chat').get('closed') or {}
    check('Other on a close makes his text the reason', ok(result) and closed.get('why') == 'he changed his mind'
          and closed.get('wording') == 'shawn', said(result) + str(closed))
    assert ok(verb(*ruling('r-limit', effect='restrict', scope='Shawn decides order')))
    argv = ['close-ruling', 'r-limit', '--as', 'withdrawn']
    printed = offer_argv('close', argv)
    check('closing a restrict is an authority move that says it widens',
          authority(printed) and 'iden' in label_of(printed), printed['input'])
    result = cites(argv, said_after(printed, 'yes close it'), *reads(printed))
    check('closing a restrict in his words is refused', refused(result, 'relay'), said(result))
    printed = offer_argv('close', argv)
    result = cites(argv, pick(printed))
    check('closing a restrict by pick binds', ok(result) and pc.in_force(revisions('r-limit')) is None, said(result))

    # ---- A correction: the notice does not say he said a draft ----
    assert ok(verb('add-item', 'mem:ask', '--title', 'Asked'))
    handed = verb('hand-item', 'mem:ask', '--question', 'Which crop?', '--kind', 'technical_approach')
    assert ok(handed), said(handed)
    anchor = json.loads(handed.stdout)['ask']
    argv = ['record-ruling', 'r-fix', '--replies-to', anchor, '--effect', 'restrict', '--scope', 'Shawn picks crop']
    result = cites(argv, pick(offer_argv('fix', argv)))
    notice = json.loads(result.stdout).get('notice', '') if ok(result) else ''
    check('a picked correction binds', ok(result) and last('r-fix').get('wording') == 'pm_draft', said(result))
    check('its notice does not say Shawn said the draft', notice and 'Shawn said' not in notice, notice)
    argv = ['record-ruling', 'r-fix2', '--replies-to', anchor, '--effect', 'grant', '--scope', 'PM picks crop']
    check('a granting correction is an authority move', authority(offer_argv('fix', argv)), '')

    # ---- edit-project-term ----
    assert ok(verb('propose-agreement', '--project-term', 'naming=use kebab case', '--source', 'brief'))

    def term():
        return programme()['agreement']['project_terms'][0]

    def accept(rec):
        rec['programme']['agreement']['accepted'] = {'at': '2026-01-01T00:00:00Z', 'prompt_id': 'p0', 'quote': 'ok'}
    edit(accept)
    term_id = term()['id']
    argv = ['edit-project-term', term_id, 'use snake case']
    printed = offer_argv('term', argv)
    check('a term edit shows old and new text', 'use snake case' in text_of(printed) and 'use kebab case' in text_of(printed),
          text_of(printed))
    result = cites(argv, pick(printed))
    check('a picked term edit binds as a draft',
          ok(result) and term().get('value') == 'use snake case' and term().get('wording') == 'pm_draft',
          said(result) + str(term()))
    change = pv._changes([last_row('project_term_amended')])[0]
    check('the change row does not credit a draft to Shawn', 'Shawn:' not in pv._change_row(change)['text'], change)
    argv = ['edit-project-term', term_id, 'use camel case']
    printed = offer_argv('term', argv)
    result = cites(argv, pick(printed, 'use whatever the file uses'), *reads(printed))
    check('Other on a term edit makes his text the term',
          ok(result) and term().get('value') == 'use whatever the file uses' and term().get('wording') == 'shawn',
          said(result) + str(term()))
    change = pv._changes([last_row('project_term_amended')])[0]
    check('the change row credits his words to Shawn', 'Shawn:' in pv._change_row(change)['text'], change)
    argv = ['edit-project-term', term_id, 'a third text']
    printed = offer_argv('term', argv)
    result = cites(argv, pick(printed, 'deploy to production freely'), *reads(printed))
    check('his words still meet the protected-area check',
          refused(result, 'protected') and term().get('value') == 'use whatever the file uses', said(result))

    # ---- define-requirement ----
    assert ok(verb('add-item', 'mem:req', '--title', 'Req'))

    def oblige(rec):
        rec['programme']['items']['mem:req']['deliverables'] = {'verified': {}}
    edit(oblige)

    def requirement(rid):
        return pc.block(programme())['requirements'].get(rid) or []
    argv = ['define-requirement', 'req-draft', '--text', 'the flow passes', '--check', 'mem:req=verified']
    printed = offer_argv('req', argv)
    check('a requirement shows its text on the picker', 'the flow passes' in text_of(printed), text_of(printed))
    result = cites(argv, pick(printed))
    check('define-requirement binds by pick', ok(result) and requirement('req-draft')[-1].get('state') == 'accepted', said(result))
    argv = ['define-requirement', 'req-words', '--text', 'the flow still passes', '--check', 'mem:req=verified']
    printed = offer_argv('req', argv)
    result = cites(argv, said_after(printed, 'yes keep that'), *reads(printed))
    check('define-requirement in his words carries a reading',
          ok(result) and json.loads(result.stdout).get('read_as') == label_of(printed)
          and requirement('req-words')[-1].get('text') == 'the flow still passes', said(result))

    # ---- set-remit ----
    def seed_remit(rec):
        rec['programme']['remit']['tracker']['teams'] = [{'key': 'AI', 'name': 'AI Labs', 'id': 'team-1'},
                                                         {'key': 'WEB', 'name': 'Web', 'id': 'team-2'}]
    edit(seed_remit)
    remit = programme()['remit']
    only_ai = [{'key': 'AI', 'name': 'AI Labs', 'id': 'team-1'}]
    raw = json.dumps({'spaces': remit['spaces'], 'repos': remit['repos'], 'tracker': dict(remit['tracker'], teams=only_ai)})
    printed = offer('narrow', 'set-remit', stdin=raw)
    check('a remit offer shows the changes, not the document',
          'removed' in text_of(printed) and 'WEB' in text_of(printed) + 'WEB' and '{' not in text_of(printed), text_of(printed))
    check('a narrowing is not an authority move', not authority(printed), printed['input'])
    result = verb('set-remit', '--prompt', said_after(printed, 'yes that is fine'), *reads(printed), stdin=raw)
    check('a remit narrowing by own words is approved with a reading',
          ok(result) and json.loads(result.stdout).get('read_as') == label_of(printed)
          and len(programme()['remit']['tracker']['teams']) == 1, said(result))
    check('his reply is marked as his', programme()['agreement']['terms']['remit'].get('wording') == 'shawn',
          programme()['agreement']['terms']['remit'])

    with_ops = [*only_ai, {'key': 'OPS', 'name': 'Ops', 'id': 'team-3'}]
    raw = json.dumps({'spaces': remit['spaces'], 'repos': remit['repos'], 'tracker': dict(remit['tracker'], teams=with_ops)})
    printed = offer('widen', 'set-remit', stdin=raw)
    check('a remit widening says it widens and takes a pick', authority(printed) and 'iden' in label_of(printed), printed['input'])
    result = verb('set-remit', '--prompt', said_after(printed, 'yes add ops'), *reads(printed), stdin=raw)
    check('a remit widening by own words is refused',
          refused(result, 'relay') and len(programme()['remit']['tracker']['teams']) == 1, said(result))
    printed = offer('widen', 'set-remit', stdin=raw)
    result = verb('set-remit', '--prompt', pick(printed), stdin=raw)
    check('a remit widening by pick applies and is marked as a draft',
          ok(result) and len(programme()['remit']['tracker']['teams']) == 2
          and programme()['agreement']['terms']['remit'].get('wording') == 'pm_draft', said(result))

    # ---- A pick's why uses the option text ----
    assert ok(verb('add-item', 'mem:h', '--title', 'Handed'))
    assert ok(verb('hand-item', 'mem:h', '--question', 'Ship it?', '--kind', 'product_call'))
    argv = ['answer-handed', 'mem:h', '--choice', 'ship', '--kind', 'evals_or_docs']
    printed = offer_argv('handed', argv)
    result = cites(argv, pick(printed))
    decision = next((d for d in reversed(programme().get('decisions') or []) if d.get('item') == 'mem:h'), {})
    check("a pick's why is the option text, not the summary", ok(result) and decision.get('why') == label_of(printed)
          and 'picked:' not in str(decision.get('why')), said(result) + str(decision))
    check('the decision says whose wording it is', decision.get('wording') == 'pm_draft', decision)

    # ---- Other on an authority picker is never recorded as content ----
    argv = ['adopt-autonomy', 'flip_terms_change_stage', 'act', '--widening']
    printed = offer_argv('wide', argv)
    result = cites(argv, pick(printed, 'make it act please'), *reads(printed))
    check('Other on adopt-autonomy --widening is relayed', refused(result, 'relay'), said(result))
    check('Other on a widening is never recorded', 'make it act please' not in json.dumps(programme()), '')

    # ---- Carried Rulings keep the mark ----
    source = {'kind': 'work_sequencing', 'effect': 'decided', 'scope': 's', 'reason': None, 'limits': [], 'until': None,
              'quote': 'q', 'wording': 'pm_draft'}
    entry = carry.entry_for('d-picked', source, 'owner/repo', {'run_id': RUN})
    check('a carried entry keeps the wording mark', entry.get('wording') == 'pm_draft', entry)

    ctx = {'decisions': {}, 'requirements': {}}
    arrived, why = carry._arrive(ctx, dict(entry, ruling='c-mark'), 'owner/repo')
    check('a carried Ruling arrives with the wording mark',
          why is None and ctx['decisions']['c-mark'][-1]['carried'].get('wording') == 'pm_draft', str(why) + str(ctx))

    # ---- The hook hint ----
    printed = offer('hint', shlex.join(ruling('d-hint')))
    hint = pick(printed, 'my own text', hook=True)
    check('the hook tells the PM his words become the text', 'become' in hint.get('offer', {}).get('note', ''), hint)

print(f'programme-drafts.test.sh: {passed} passed, {failed} failed')
sys.exit(1 if failed else 0)
PY
