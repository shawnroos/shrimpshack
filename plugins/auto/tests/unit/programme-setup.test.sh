#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

echo "programme-setup.test.sh"

"$PY" - "$AUTO_ROOT" <<'PY'
import copy
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import time

root = pathlib.Path(sys.argv[1])
sys.path.insert(0, str(root / 'lib'))
sys.path.insert(0, str(root / 'tests' / 'fixtures'))
from _bootstrap import load_lib_module
from programme_prompts import append_prompt as typed_prompt

FIXTURE = [json.loads(line) for line in (root / 'tests/fixtures/askuser_transcript.jsonl').read_text().splitlines()]
ASK, ANSWER = FIXTURE[0], FIXTURE[1]
PROG = str(root / 'lib/programme.py')

passed = failed = 0
with tempfile.TemporaryDirectory(prefix='auto-programme-setup-') as work:
    work = pathlib.Path(work)
    for key in list(os.environ):
        if key.startswith('HERDR_') or key.startswith('CLAUDE_AUTO_'):
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
    pick_source = load_lib_module('programme_pick_source')
    core = load_lib_module('run_record_core')
    transcripts = work / 'transcripts'
    transcripts.mkdir()
    counter = [0]
    refresh_failures = []

    def check(name, condition, detail=''):
        global passed, failed
        if condition:
            passed += 1
            print('  PASS ' + name)
        else:
            failed += 1
            print('  FAIL ' + name + ': ' + str(detail)[:1500])

    def programme(sid, space):
        os.environ['CLAUDE_CODE_SESSION_ID'] = sid
        return ph.create_programme([space], sid)['run']

    def record(run):
        return core.read_run_record(ph.home_path(run), run)

    def terms(run):
        return record(run)['programme']['agreement']['terms']

    def kinds(run, kind):
        return [r for r in pj.read(run) if r.get('kind') == kind]

    def view(run):
        return json.loads((pathlib.Path(load_lib_module('programme_view').view_path(ph.home_path(run)))).read_text())

    def verb(sid, run, *args, stdin=None):
        env = dict(os.environ, CLAUDE_CODE_SESSION_ID=sid)
        result = subprocess.run([sys.executable, PROG, *args, '--run', run], text=True, capture_output=True,
                                env=env, input=stdin)
        if 'refresh failed' in result.stderr:
            refresh_failures.append((args, result.stderr))
        return result

    def pick(sid, run, answers, tool_use_id=None, answered=True):
        if tool_use_id is None:
            counter[0] += 1
            tool_use_id = f'toolu_{counter[0]}'
        path = transcripts / (sid + '.jsonl')
        ask = copy.deepcopy(ASK)
        ask.update(uuid='a-' + tool_use_id, sessionId=sid)
        ask['message']['content'][0].update(id=tool_use_id, input={'questions': [
            {'question': q, 'header': 'Setup', 'multiSelect': False,
             'options': [{'label': answers[q], 'description': ''}, {'label': 'other', 'description': ''}]}
            for q in answers]})
        result = copy.deepcopy(ANSWER)
        result.update(uuid='u-' + tool_use_id, sessionId=sid, sourceToolAssistantUUID='a-' + tool_use_id,
                      toolUseResult={'questions': [{'question': q} for q in answers], 'answers': answers,
                                     'annotations': {}})
        result['message']['content'][0].update(tool_use_id=tool_use_id)
        rows = [ask, result] if answered else [ask]
        if not (path.exists() and f'"id": "{tool_use_id}"' in path.read_text()):
            with path.open('a') as stream:
                stream.write(''.join(json.dumps(r) + '\n' for r in rows))
        source = pick_source.capture({'transcript_path': str(path), 'session_id': sid, 'tool_use_id': tool_use_id,
                                      'tool_response': {'answers': answers}})
        row = pj.append_prompt(run, sid, pick_source.summary(answers), 'unknown', source=source)
        return row['prompt_id']

    def origin(run, prompt_id):
        return pj.prompt_origin(pj.find_prompt(run, prompt_id))

    def refused(result, text):
        return result.returncode != 0 and text in (result.stderr + result.stdout)

    # Run A: pick-term, accept ordering, after-acceptance refusal and typed-gate twins.
    a_sid = 'setup-a'
    run = programme(a_sid, 'setup-a')
    proposed = verb(a_sid, run, 'propose-agreement', '--project-term', 'naming=use kebab case',
                    '--reserved-term', 'deploys=only Shawn deploys', '--source', 'test brief')
    check('propose-agreement adds a ruling and a reserved area', proposed.returncode == 0, proposed.stderr)
    entries = record(run)['programme']['agreement']['project_terms']
    ruling = next(e['id'] for e in entries if not e['reserved'])
    reserved = next(e['id'] for e in entries if e['reserved'])
    early_accept = typed_prompt(run, a_sid, 'accept the agreement')['prompt_id']

    cadence_q = 'Cadence: how often should the PM sweep?'
    cadence_pick = pick(a_sid, run, {cadence_q: 'fixed every 15 min'})
    check('the test pick verifies as picked', origin(run, cadence_pick) == 'picked', origin(run, cadence_pick))

    result = verb(a_sid, run, 'pick-term', 'stop_rule', 'never_stop', '--pick', cadence_pick)
    check('pick-term refuses a pick that answered another term\'s question',
          refused(result, 'does not answer') and terms(run)['stop_rule']['set_by'] == 'default',
          result.stdout + result.stderr)
    result = verb(a_sid, run, 'pick-term', 'cadence', 'on_change', '--pick', cadence_pick)
    check('pick-term refuses a pick whose answer names a different value',
          refused(result, 'does not name') and terms(run)['cadence']['value'] == 'on_change'
          and terms(run)['cadence']['set_by'] == 'default', result.stdout + result.stderr)

    result = verb(a_sid, run, 'pick-term', 'cadence', 'fixed', '--seconds', '900', '--pick', cadence_pick)
    cadence = terms(run)['cadence']
    check('AE1: pick-term sets the term with set_by shawn and origin picked',
          result.returncode == 0 and cadence['value'] == 'fixed' and cadence['set_by'] == 'shawn'
          and cadence.get('origin') == 'picked' and cadence.get('prompt_id') == cadence_pick
          and cadence.get('seconds') == 900, (result.stdout + result.stderr, cadence))
    row = (kinds(run, 'term_picked') or [{}])[-1]
    payload = row.get('payload') or {}
    check('R11: the journal records the question, the answer and origin picked',
          payload.get('origin') == 'picked' and payload.get('question') == cadence_q
          and payload.get('answer') == 'fixed every 15 min' and payload.get('prompt_id') == cadence_pick
          and payload.get('tool_use_id'), row)

    result = verb(a_sid, run, 'pick-term', 'cadence', 'fixed', '--pick', cadence_pick)
    check('a used pick refuses a second pick-term', refused(result, 'already'), result.stdout + result.stderr)
    tool_use_id = pj.find_prompt(run, cadence_pick)['payload']['source']['tool_use_id']
    twin = pick(a_sid, run, {cadence_q: 'fixed every 15 min'}, tool_use_id=tool_use_id)
    check('a second prompt row on the same tool use still verifies', origin(run, twin) == 'picked',
          origin(run, twin))
    result = verb(a_sid, run, 'pick-term', 'cadence', 'fixed', '--pick', twin)
    check('a used pick refuses even via a different prompt row', refused(result, 'already'),
          result.stdout + result.stderr)

    unknown = pj.append_prompt(run, a_sid, 'picked: Cadence: how often? -> fixed', 'unknown')['prompt_id']
    result = verb(a_sid, run, 'pick-term', 'cadence', 'fixed', '--pick', unknown)
    check('pick-term refuses an unverified prompt', refused(result, 'not a verified pick'),
          result.stdout + result.stderr)
    typed = typed_prompt(run, a_sid, 'cadence fixed')['prompt_id']
    result = verb(a_sid, run, 'pick-term', 'cadence', 'fixed', '--pick', typed)
    check('pick-term refuses a typed prompt (picks only)', refused(result, 'not a verified pick'),
          result.stdout + result.stderr)
    lone = pick(a_sid, run, {'Stop rule: when should the PM stop?': 'never stop'}, answered=False)
    result = verb(a_sid, run, 'pick-term', 'stop_rule', 'never_stop', '--pick', lone)
    check('pick-term refuses a pick with no human result row', refused(result, 'not a verified pick'),
          result.stdout + result.stderr)

    stranger = pick('intruder', run, {cadence_q: 'fixed every 15 min'})
    result = verb(a_sid, run, 'pick-term', 'cadence', 'fixed', '--pick', stranger)
    check('pick-term refuses a pick answered in another session',
          origin(run, stranger) == 'picked' and refused(result, 'not answered in the driving session'),
          result.stdout + result.stderr)
    vague = pick(a_sid, run, {'How should the PM work?': 'never stop'})
    result = verb(a_sid, run, 'pick-term', 'stop_rule', 'never_stop', '--pick', vague)
    check('pick-term refuses a question that names no term', refused(result, 'does not answer'),
          result.stdout + result.stderr)
    both = pick(a_sid, run, {'Cadence and stop rule: which?': 'fixed'})
    result = verb(a_sid, run, 'pick-term', 'cadence', 'fixed', '--pick', both)
    check('pick-term refuses a question that names two terms', refused(result, 'does not answer'),
          result.stdout + result.stderr)

    for target, value, label in((reserved, 'x', 'a reserved area'), (ruling, 'x', 'a ruling'),
                                 ('autonomy', 'protocol', 'the shared autonomy setting'),
                                 ('done_standards', 'strict', 'a shared protocol setting'),
                                 ('rulings', 'x', 'the rulings step')):
        shared_pick = pick(a_sid, run, {f'{target}: which?': value})
        result = verb(a_sid, run, 'pick-term', target, value, '--pick', shared_pick)
        check(f'AE2: pick-term refuses {label}', result.returncode != 0 and 'stays typed' in result.stderr,
              result.stdout + result.stderr)

    tools_q = 'Tools of record: which sources stay on?'
    result = verb(a_sid, run, 'pick-term', 'tools_of_record', 'tracker,tasks', '--pick',
                  pick(a_sid, run, {tools_q: 'tracker, tasks, plans'}))
    check('pick-term on a list refuses a value that drops a source the answer names',
          refused(result, 'plans') and terms(run)['tools_of_record']['set_by'] == 'default',
          result.stdout + result.stderr)
    result = verb(a_sid, run, 'pick-term', 'tools_of_record', 'tracker,tasks', '--pick',
                  pick(a_sid, run, {tools_q: 'tracker, tasks'}))
    check('pick-term on a list accepts an answer naming exactly the value',
          result.returncode == 0 and terms(run)['tools_of_record']['value'] == ['tracker', 'tasks'],
          (result.stdout + result.stderr, terms(run)['tools_of_record']))

    result = verb(a_sid, run, 'accept-agreement', '--prompt', early_accept)
    check('accept-agreement citing a typed prompt older than the last pick refuses',
          refused(result, 'older than') and not record(run)['programme']['agreement']['accepted'],
          result.stdout + result.stderr)
    result = verb(a_sid, run, 'accept-agreement', '--prompt', twin)
    check('accept-agreement refuses a picked prompt id', refused(result, "is not typed (origin 'picked'"),
          result.stdout + result.stderr)

    gate_pick = pick(a_sid, run, {'Cadence: on change?': 'on change'})
    for args, label in ((('amend-term', 'cadence', 'on_change'), 'amend-term'),
                        (('record-instruction',), 'record-instruction'),
                        (('adopt-rule', 'r1'), 'adopt-rule'),
                        (('accept-context', 'd1'), 'accept-context'),
                        (('dispose-action', '--attempt', 'o1', '--as', 'abandoned_unknown'), 'dispose-action (archive)')):
        result = verb(a_sid, run, *args, '--prompt', gate_pick)
        check(f'{label} refuses a picked prompt id', refused(result, "is not typed (origin 'picked'"),
              result.stdout + result.stderr)

    lifecycle = load_lib_module('programme_lifecycle')
    typed_end = typed_prompt(run, a_sid, '/auto:programme-end')['prompt_id']
    typed_row = pj.find_prompt(run, typed_end)
    for cite, label in ((typed_end, 'typed'), (gate_pick, 'picked')):
        pj.append(run, 'end_request', a_sid, {'verb': 'end', 'text': '/auto:programme-end', 'origin': 'typed',
                                               'space': 'x', 'lease_status': 'live', 'driving': True,
                                               'source': typed_row['payload']['source']}, cites=[cite])
    requests = lifecycle._requests(run, 'end', a_sid)
    cited = {r['cites'][0]: lifecycle._cited_typed(run, r, a_sid) for r in requests}
    check('a lifecycle request citing a typed prompt counts (control)', cited.get(typed_end) is True, cited)
    check('a lifecycle request citing a picked prompt does not count', cited.get(gate_pick) is False, cited)
    pick_row = pj.find_prompt(run, gate_pick)
    pj.append(run, 'end_request', a_sid, {'verb': 'end', 'text': '/auto:programme-end', 'origin': 'unknown',
                                           'space': 'x', 'lease_status': 'live', 'driving': True,
                                           'source': pick_row['payload']['source']}, cites=[gate_pick])
    check('a lifecycle request carrying a pick source is not a typed request',
          len(lifecycle._requests(run, 'end', a_sid)) == len(requests), lifecycle._requests(run, 'end', a_sid))

    protocol = load_lib_module('programme_protocol')
    programme_mod = load_lib_module('programme')

    def adoption_reject(prompt_id):
        entry = {'id': 'r-test', 'when': 'x', 'autonomy': 'ask'}
        lookup = programme_mod.prompt_lookup(run, prompt_id)
        entry['adoption'] = {'machine': protocol.machine_name(), 'run_id': run, 'prompt_id': prompt_id,
                             'quote': 'q', 'prompt_hash': lookup['text_hash'], 'hash': protocol.content_hash(entry)}
        try:
            protocol._verify_adoption(entry, programme_mod.prompt_lookup, 'rule:r-test')
        except protocol._Reject as exc:
            return exc.detail
        return None
    check('the protocol adoption check refuses a picked prompt', adoption_reject(gate_pick) == 'prompt not typed',
          adoption_reject(gate_pick))
    check('the protocol adoption check passes the typed step for a typed prompt (control)',
          adoption_reject(typed_end) == 'no approval', adoption_reject(typed_end))

    accept = typed_prompt(run, a_sid, 'accept the agreement')['prompt_id']
    result = verb(a_sid, run, 'accept-agreement', '--prompt', accept)
    check('a typed accept after the last pick is accepted', result.returncode == 0, result.stdout + result.stderr)

    late = pick(a_sid, run, {'Stop rule: when should the PM stop?': 'never stop'})
    before_terms, before_refusals = json.dumps(terms(run), sort_keys=True), len(kinds(run, 'approval_refused'))
    result = verb(a_sid, run, 'pick-term', 'stop_rule', 'never_stop', '--pick', late)
    check('AE3: pick-term after acceptance refuses with the record unchanged',
          refused(result, 'accepted') and json.dumps(terms(run), sort_keys=True) == before_terms,
          result.stdout + result.stderr)
    check('AE3: exactly one approval_refused is added',
          len(kinds(run, 'approval_refused')) == before_refusals + 1, len(kinds(run, 'approval_refused')))
    result = verb(a_sid, run, 'take-recommendations', '--pick',
                  pick(a_sid, run, {'Setup: how to start?': 'Take all recommendations'}))
    check('take-recommendations after acceptance refuses', refused(result, 'accepted'), result.stdout + result.stderr)

    # Run B: take-recommendations.
    b_sid = 'setup-b'
    run = programme(b_sid, 'setup-b')
    verb(b_sid, run, 'propose-agreement', '--project-term', 'naming=use kebab case', '--source', 'brief',
         '--term', 'cadence=fixed', '--seconds', '600')
    verb(b_sid, run, 'propose-term', 'stop_rule', 'only_when_done')
    personal = pathlib.Path(os.environ['CLAUDE_AUTO_PERSONAL_PROTOCOL'])
    stale_accept = typed_prompt(run, b_sid, 'accept the agreement')['prompt_id']
    result = verb(b_sid, run, 'take-recommendations', '--pick',
                  pick(b_sid, run, {'Setup: how to start?': 'Go step by step'}))
    check('take-recommendations refuses a pick that is not the take-all option',
          refused(result, 'take all recommendations') and terms(run)['stop_rule']['set_by'] == 'default',
          result.stdout + result.stderr)
    result = verb(b_sid, run, 'take-recommendations', '--pick',
                  pick(b_sid, run, {'Setup: how to start?': "don't take all recommendations, walk each step"}))
    check('take-recommendations refuses a negated take-all answer',
          refused(result, 'take all recommendations') and terms(run)['stop_rule']['set_by'] == 'default',
          result.stdout + result.stderr)
    take = pick(b_sid, run, {'Setup: how to start?': 'Take all recommendations (Recommended)'})
    result = verb(b_sid, run, 'take-recommendations', '--pick', take)
    after = terms(run)
    per_programme = ('remit', 'stop_rule', 'cadence', 'tools_of_record')
    check('take-recommendations sets every per-programme term from its recommendation',
          result.returncode == 0 and after['stop_rule']['value'] == 'only_when_done'
          and all(after[k]['set_by'] == 'shawn' and after[k].get('origin') == 'picked' for k in per_programme)
          and after['cadence']['value'] == 'fixed' and after['cadence']['seconds'] == 600
          and after['stop_rule']['proposal']['state'] == 'accepted', (result.stdout + result.stderr, after))
    check('take-recommendations leaves the shared, ruling and protocol settings alone',
          after['autonomy']['set_by'] == 'default'
          and all(e['set_by'] == 'proposal' for e in record(run)['programme']['agreement']['project_terms'])
          and not personal.exists(), after['autonomy'])
    check('take-recommendations journals one row citing the pick',
          [r['payload'].get('prompt_id') for r in kinds(run, 'recommendations_taken')] == [take],
          kinds(run, 'recommendations_taken'))
    result = verb(b_sid, run, 'accept-agreement', '--prompt', stale_accept)
    check('accept-agreement citing a typed prompt older than take-recommendations refuses',
          refused(result, 'older than') and not record(run)['programme']['agreement']['accepted'],
          result.stdout + result.stderr)
    d_sid = 'setup-d'
    d_run = programme(d_sid, 'setup-d')
    verb(d_sid, d_run, 'propose-agreement', '--term', 'stop_rule=until_time', '--until', '2030-01-01T00:00:00Z')
    widen = verb(d_sid, d_run, 'propose-term', 'remit', '--add', 'default.setup-d-extra')
    remit_before = terms(d_run)['remit']
    result = verb(d_sid, d_run, 'take-recommendations', '--pick',
                  pick(d_sid, d_run, {'Setup: how to start?': 'Take all recommendations'}))
    check('take-recommendations keeps a proposed stop time',
          result.returncode == 0 and terms(d_run)['stop_rule']['value'] == 'until_time'
          and terms(d_run)['stop_rule']['until'] == '2030-01-01T00:00:00Z', (result.stderr, terms(d_run)['stop_rule']))
    remit = terms(d_run)['remit']
    check('take-recommendations leaves a proposed new remit space pending and the remit value unchanged',
          widen.returncode == 0 and remit_before['proposal']['extras'].get('add')
          and remit['value'] == remit_before['value'] and remit['proposal']['state'] == 'pending'
          and not any(s.get('workspace') == 'setup-d-extra' for s in record(d_run)['programme']['remit']['spaces']),
          (widen.stdout + widen.stderr, remit))
    result = verb(b_sid, run, 'take-recommendations', '--pick', take)
    check('take-recommendations refuses a used pick', refused(result, 'already'), result.stdout + result.stderr)
    later =pick(b_sid, run, {'Cadence: how often?': 'on change'})
    verb(b_sid, run, 'pick-term', 'cadence', 'on_change', '--pick', later)
    accept = typed_prompt(run, b_sid, 'accept the agreement')['prompt_id']
    result = verb(b_sid, run, 'accept-agreement', '--prompt', accept)
    check('a typed accept after take-recommendations and picks is accepted', result.returncode == 0,
          result.stdout + result.stderr)

    # Run C: setup-step, setup-seen and setup-keep.
    c_sid = 'setup-c'
    run = programme(c_sid, 'setup-c')
    result = verb(c_sid, run, 'setup-step', 'bogus')
    check('setup-step refuses an unknown step name', refused(result, 'unknown setup step'),
          result.stdout + result.stderr)
    result = verb(c_sid, run, 'setup-step', 'stop_rule')
    check('setup-step moves the view\'s current step',
          result.returncode == 0 and view(run)['setup']['current'] == 'stop_rule', result.stdout + result.stderr)
    seen = {'tabs': ['t1'], 'repos': ['other-repo'], 'tracker': ['ENG'],
            'items': [{'item': 'gh:x#1', 'title': 'Fix it', 'pane': 'p1', 'session': None}]}
    result = verb(c_sid, run, 'setup-seen', '--json', '-', stdin=json.dumps(seen))
    setup = view(run)['setup']
    check('setup-seen stores what the probe saw and the view\'s out list reflects it',
          result.returncode == 0 and 'ENG' in setup['scope']['out']['tracker']
          and record(run)['programme']['setup']['seen']['repos'] == ['other-repo']
          and [i['item'] for s in setup['steps'] if s['key'] == 'items' for i in s['items']] == ['gh:x#1'],
          (result.stdout + result.stderr, setup))
    seen_file = work / 'seen.json'
    seen_file.write_text(json.dumps({'tabs': [1]}))
    result = verb(c_sid, run, 'setup-seen', '--json', str(seen_file))
    check('setup-seen refuses a list holding a non-string', refused(result, 'tabs'), result.stdout + result.stderr)
    seen_file.write_text(json.dumps({'items': [{'title': 'no item key'}]}))
    result = verb(c_sid, run, 'setup-seen', '--json', str(seen_file))
    check('setup-seen refuses an item without a string item id', refused(result, 'item'),
          result.stdout + result.stderr)
    seen_file.write_text(json.dumps({'tabs': [], 'repos': [], 'tracker': []}))
    result = verb(c_sid, run, 'setup-seen', '--json', str(seen_file))
    check('setup-seen refuses JSON with no items list', refused(result, 'items')
          and record(run)['programme']['setup']['seen']['items'] == [{'item': 'gh:x#1', 'title': 'Fix it', 'pane': 'p1', 'session': None}],
          result.stdout + result.stderr)
    state = lambda: {s['key']: s['state'] for s in view(run)['setup']['steps']}
    check('the rulings step starts unfinished', state()['rulings'] != 'done', state())
    result = verb(c_sid, run, 'setup-keep', 'rulings')
    check('setup-keep marks a typed-reply step done', result.returncode == 0 and state()['rulings'] == 'done',
          (result.stdout + result.stderr, state()))
    result = verb(c_sid, run, 'setup-keep', 'accept')
    check('setup-keep accept refuses', refused(result, 'accept'), result.stdout + result.stderr)
    result = verb(c_sid, run, 'setup-keep', 'bogus')
    check('setup-keep refuses an unknown step', refused(result, 'unknown setup step'), result.stdout + result.stderr)
    flag = pathlib.Path(ph.home_path(run)) / ph.COMPACT_FLAG
    flag.touch()
    result = verb(c_sid, run, 'pick-term', 'cadence', 'fixed', '--seconds', '900', '--pick',
                  pick(c_sid, run, {'Cadence: how often?': 'fixed'}))
    check('a pick-term refuses while the compact flag is set (control)', refused(result, 'compacted'),
          result.stdout + result.stderr)
    beat_before = record(run).get('loop', {}).get('last_beat_at')
    time.sleep(1.1)
    results = [verb(c_sid, run, 'setup-step', 'cadence'),
               verb(c_sid, run, 'setup-seen', '--json', '-', stdin=json.dumps(dict(seen, items=[]))),
               verb(c_sid, run, 'setup-keep', 'shared')]
    check('setup-step, setup-seen and setup-keep run while the compact flag is set',
          all(r.returncode == 0 for r in results), [r.stdout + r.stderr for r in results])
    check('setup-step, setup-seen and setup-keep never count as a beat',
          record(run).get('loop', {}).get('last_beat_at') == beat_before,
          (beat_before, record(run).get('loop')))
    flag.unlink()
    check('no verb left the view stale', not refresh_failures, refresh_failures)
    check('setup writes are not approvals', not kinds(run, 'approval_refused'), kinds(run, 'approval_refused'))

print(f'programme-setup.test.sh: {passed} passed, {failed} failed')
sys.exit(1 if failed else 0)
PY
