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
import re
import subprocess
import sys
import tempfile

root = pathlib.Path(sys.argv[1])
sys.path.insert(0, str(root / 'lib'))
from _bootstrap import load_lib_module

FIXTURE = [json.loads(line) for line in (root / 'tests/fixtures/askuser_transcript.jsonl').read_text().splitlines()]
PICK, RESULT, PREFILLED, PREFILLED_RESULT = FIXTURE
QUESTION = 'Cadence: how often should the PM sweep?'
ANSWERS = {QUESTION: 'fixed every 15 min'}

passed = failed = 0
with tempfile.TemporaryDirectory(prefix='auto-pick-origin-') as work:
    work = pathlib.Path(work)
    for key in list(os.environ):
        if key.startswith('HERDR_') or key.startswith('CLAUDE_AUTO_'):
            del os.environ[key]
    os.environ.update(CLAUDE_AUTO_DATA_DIR=str(work / 'data'),
                      CLAUDE_AUTO_TEST_HARNESS='1', CLAUDE_CODE_SESSION_ID='pick-pm',
                      CLAUDE_PLUGIN_ROOT=str(root), CLAUDE_AUTO_SECRETS_FILE=str(work / 'no-secrets'),
                      CLAUDE_AUTO_PERSONAL_PROTOCOL=str(work / 'no-protocol'))
    ph = load_lib_module('programme_home')
    pj = load_lib_module('programme_journal')
    plain = work / 'plain'
    plain.mkdir()

    def check(name, condition, detail):
        global passed, failed
        if condition:
            passed += 1
            print('  PASS ' + name)
        else:
            failed += 1
            print('  FAIL ' + name + ': ' + str(detail))

    def programme(sid):
        os.environ['CLAUDE_CODE_SESSION_ID'] = sid
        return ph.create_programme(['pick-' + sid], sid)['run']

    def transcript(sid, rows):
        path = work / (sid + '.jsonl')
        path.write_text(''.join(json.dumps(dict(row, sessionId=sid)) + '\n' for row in rows))
        return path

    def hook(name, payload, env=None):
        return subprocess.run(['bash', str(root / '.claude/hooks' / name)], input=json.dumps(payload),
                              text=True, capture_output=True, cwd=str(plain), env=env)

    def post(sid, path, tool_use_id='toolu_pick', tool_input=None, env=None):
        payload = {'session_id': sid, 'transcript_path': str(path), 'cwd': str(plain),
                   'hook_event_name': 'PostToolUse', 'tool_name': 'AskUserQuestion',
                   'tool_use_id': tool_use_id,
                   'tool_input': tool_input or PICK['message']['content'][0]['input'],
                   'tool_response': {'questions': [{'question': QUESTION}], 'answers': ANSWERS, 'annotations': {}}}
        return hook('on-posttooluse-askuser.sh', payload, env)

    def pre(sid, tool_input):
        payload = {'session_id': sid, 'cwd': str(plain), 'hook_event_name': 'PreToolUse',
                   'tool_name': 'AskUserQuestion', 'tool_input': tool_input}
        return hook('on-pretooluse-askuser.sh', payload)

    def pick_id(result):
        context = json.loads(result.stdout)['hookSpecificOutput']['additionalContext']
        return json.loads(re.search(r'(\{.*\})\n</auto-data>', context).group(1))['prompt_id']

    def prompt_rows(run):
        return [r for r in pj.read(run) if r.get('kind') == 'prompt']

    check('the working folder has no .claude/auto above it',
          not any((p / '.claude' / 'auto').is_dir() for p in [plain, *plain.parents]), plain)

    run = programme('pick-pm')
    path = transcript('pick-pm', [PICK])
    result = post('pick-pm', path)
    context = json.loads(result.stdout)['hookSpecificOutput'] if result.stdout else {}
    data = re.search(r'<auto-data>\n.*\n(\{.*\})\n</auto-data>', context.get('additionalContext', ''), re.S)
    prompt_id = json.loads(data.group(1))['prompt_id'] if data else None
    check('the PostToolUse hook returns the pick prompt id', context.get('hookEventName') == 'PostToolUse' and bool(prompt_id),
          result.stdout + result.stderr)
    row = pj.find_prompt(run, prompt_id)
    check('the pick row is stored unknown with a pick source',
          bool(row) and row['payload']['origin'] == 'unknown' and row['payload']['source']['kind'] == 'pick', row)
    check('the pick is unverified before its result row lands', pj.prompt_origin(row) == 'unknown', row)
    with path.open('a') as stream:
        stream.write(json.dumps(dict(RESULT, sessionId='pick-pm')) + '\n')
    check('AE1: the journaled human pick resolves picked', pj.prompt_origin(row) == 'picked', row)
    lookup = load_lib_module('programme').prompt_lookup(run, prompt_id)
    check('the PM prompt lookup reads the pick as picked', (lookup or {}).get('origin') == 'picked', lookup)

    prefilled_path = transcript('pick-pm', [PREFILLED, PREFILLED_RESULT])
    result = post('pick-pm', prefilled_path, 'toolu_prefilled', PREFILLED['message']['content'][0]['input'])
    prefilled_id = pick_id(result)
    check('a pre-filled pick journaled by the hook resolves unknown',
          pj.prompt_origin(pj.find_prompt(run, prefilled_id)) == 'unknown', prefilled_id)

    before = len(prompt_rows(run))
    stranger = transcript('stranger', [PICK, RESULT])
    result = post('stranger', stranger)
    check('a pick from a session that drives no programme is not journaled',
          result.returncode == 0 and result.stdout == '' and len(prompt_rows(run)) == before,
          (result.returncode, result.stdout, len(prompt_rows(run))))
    payload = {'session_id': 'stranger', 'transcript_path': str(stranger), 'tool_name': 'AskUserQuestion',
               'tool_use_id': 'toolu_pick', 'tool_response': {'answers': ANSWERS}}
    result = subprocess.run([sys.executable, str(root / 'lib/on-posttooluse-askuser.py')], input=json.dumps(payload),
                            text=True, capture_output=True, cwd=str(plain))
    check('past the shell gate, a non-driving pick is still not journaled',
          result.returncode == 0 and result.stdout == '' and len(prompt_rows(run)) == before,
          (result.returncode, result.stdout, len(prompt_rows(run))))

    asked = PICK['message']['content'][0]['input']
    result = pre('pick-pm', dict(asked, answers=ANSWERS))
    out = json.loads(result.stdout or '{}').get('hookSpecificOutput') or {}
    check('PreToolUse denies a driving-session picker that pre-fills answers',
          result.returncode == 0 and out.get('permissionDecision') == 'deny', result.stdout + result.stderr)
    result = pre('pick-pm', asked)
    check('PreToolUse allows a driving-session picker without answers',
          result.returncode == 0 and result.stdout == '', result.stdout + result.stderr)
    before = len(prompt_rows(run))
    result = pre('stranger', dict(asked, answers=ANSWERS))
    check('a session that drives no programme gets no denial and no row',
          result.returncode == 0 and result.stdout == '' and len(prompt_rows(run)) == before,
          (result.returncode, result.stdout))

    def raw_hook(name, first_sid, last_key, last_sid, body):
        text = ('{"session_id": "' + first_sid + '", ' + json.dumps(body)[1:-1]
                + ', "' + last_key + '": "' + last_sid + '"}')
        return subprocess.run(['bash', str(root / '.claude/hooks' / name)], input=text,
                              text=True, capture_output=True, cwd=str(plain))

    def denied(result):
        return result.returncode == 0 and (json.loads(result.stdout or '{}').get('hookSpecificOutput') or {}).get(
            'permissionDecision') == 'deny'

    pre_body = {'cwd': str(plain), 'hook_event_name': 'PreToolUse', 'tool_name': 'AskUserQuestion',
                'tool_input': dict(asked, answers=ANSWERS)}
    for label, last_key, last_sid in (('a second session_id key', 'session_id', 'pick-pm'),
                                      ('a \\u escape in a session_id key', 'session\\u005fid', 'pick-pm')):
        result = raw_hook('on-pretooluse-askuser.sh', 'stranger', last_key, last_sid, pre_body)
        check(f'PreToolUse still denies a pre-filled picker when the stdin carries {label}', denied(result),
              (result.returncode, result.stdout, result.stderr))

    def post_body(tool_use_id):
        (work / tool_use_id).mkdir()
        path = work / tool_use_id / 'pick-pm.jsonl'
        pick = copy.deepcopy(PICK)
        pick['message']['content'][0]['id'] = tool_use_id
        path.write_text(json.dumps(dict(pick, sessionId='pick-pm')) + '\n')
        return {'transcript_path': str(path), 'cwd': str(plain), 'hook_event_name': 'PostToolUse',
                'tool_name': 'AskUserQuestion', 'tool_use_id': tool_use_id,
                'tool_input': PICK['message']['content'][0]['input'],
                'tool_response': {'questions': [{'question': QUESTION}], 'answers': ANSWERS, 'annotations': {}}}

    for label, last_key, tool_use_id in (('a second session_id key', 'session_id', 'toolu_dup'),
                                         ('a \\u escape in a session_id key', 'session\\u005fid', 'toolu_esc')):
        result = raw_hook('on-posttooluse-askuser.sh', 'stranger', last_key, 'pick-pm', post_body(tool_use_id))
        rows = [r for r in prompt_rows(run) if ((r.get('payload') or {}).get('source') or {}).get('tool_use_id') == tool_use_id]
        check(f'PostToolUse still journals the driving pick when the stdin carries {label}',
              result.returncode == 0 and len(rows) == 1 and rows[0].get('session_id') == 'pick-pm',
              (result.returncode, result.stdout, rows))

    marker = pathlib.Path(ph.home_path(run)) / load_lib_module('programme_authority').IMPORT_MARKER
    marker.write_text('')
    held = load_lib_module('on-user-prompt')._driving_run('pick-pm')
    result = pre('pick-pm', dict(asked, answers=ANSWERS))
    check('PreToolUse denies a pre-filled picker while the lease is held',
          held[0] is None and held[3] is not None and denied(result), (held, result.stdout, result.stderr))
    marker.unlink()

    hatches =sorted(set(re.findall(r'CLAUDE_AUTO_[A-Z0-9_]*[A-Z0-9]',
                                    subprocess.run(['grep', '-rhoE', 'CLAUDE_AUTO_[A-Z0-9_]+', str(root / 'lib'),
                                                    str(root / '.claude/hooks')],
                                                   text=True, capture_output=True).stdout)))
    keep = {'CLAUDE_AUTO_DATA_DIR', 'CLAUDE_AUTO_SECRETS_FILE', 'CLAUDE_AUTO_PERSONAL_PROTOCOL', 'CLAUDE_AUTO_PYTHON3'}
    open_env = dict(os.environ, **{name: '1' for name in hatches if name not in keep})
    check('the hatch list is not empty', len(hatches) > 10, hatches)

    forged_path = transcript('pick-pm', [PICK])
    result = post('pick-pm', forged_path, env=open_env)
    forged_id = pick_id(result)
    forged = copy.deepcopy(pj.find_prompt(run, forged_id))
    labelled = pj.entry('prompt', 'pick-pm', {'text': 'fixed every 15 min', 'origin': 'picked',
                                              'source': dict(forged['payload']['source'])}, prompt_id='pforged')
    pj.append_row(run, labelled)
    probe = subprocess.run([sys.executable, '-c', '''
import json, sys
sys.path.insert(0, sys.argv[1] + "/lib")
from _bootstrap import load_lib_module
pj = load_lib_module("programme_journal")
host = load_lib_module("programme")
print(json.dumps([[pj.prompt_origin(pj.find_prompt(sys.argv[2], p)), (host.prompt_lookup(sys.argv[2], p) or {}).get("origin")]
                  for p in sys.argv[3:]]))
''', str(root), run, forged_id, 'pforged', prefilled_id], text=True, capture_output=True, env=open_env)
    check('every CLAUDE_AUTO_* hatch set still leaves forged picks unverified',
          probe.returncode == 0 and json.loads(probe.stdout) == [['unknown', 'unknown']] * 3,
          probe.stdout + probe.stderr)

    ph.end_programme(run, 'isolated pick fixture complete')

print('programme-pick-origin.test.sh: {} passed, {} failed'.format(passed, failed))
sys.exit(1 if failed else 0)
PY
