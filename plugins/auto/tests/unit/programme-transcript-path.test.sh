#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

echo "programme-transcript-path.test.sh"

"$PY" - "$AUTO_ROOT" <<'PY'
import copy
import json
import os
import pathlib
import sys
import tempfile

root = pathlib.Path(sys.argv[1])
sys.path[:0] = [str(root / 'lib'), str(root / 'tests' / 'fixtures')]
from _bootstrap import load_lib_module

passed = failed = 0


def check(name, actual, expected):
    global passed, failed
    if actual == expected:
        passed += 1
        print('  PASS ' + name)
    else:
        failed += 1
        print(f'  FAIL {name}: expected {expected!r}, got {actual!r}')


FIXTURE = [json.loads(line) for line in (root / 'tests/fixtures/askuser_transcript.jsonl').read_text().splitlines()]
PICK, RESULT = FIXTURE[:2]
QUESTION = 'Cadence: how often should the PM sweep?'
ALL_PASS = {'capture': True, 'pick': 'picked', 'words': 'typed', 'question': True}
ALL_REFUSE = {'capture': False, 'pick': 'unknown', 'words': 'unknown', 'question': False}

with tempfile.TemporaryDirectory(prefix='auto-transcript-path-') as work:
    work = pathlib.Path(work)
    for key in list(os.environ):
        if key.startswith(('HERDR_', 'REX_')):
            del os.environ[key]
    os.environ.update(CLAUDE_AUTO_DATA_DIR=str(work / 'data'), CLAUDE_AUTO_TEST_HARNESS='1',
                      CLAUDE_AUTO_SECRETS_FILE=str(work / 'no-secrets'),
                      CLAUDE_AUTO_PERSONAL_PROTOCOL=str(work / 'no-protocol'))
    pj = load_lib_module('programme_journal')
    ph = load_lib_module('programme_home')
    picks = load_lib_module('programme_pick_source')
    words = load_lib_module('programme_prompt_source')
    sr = load_lib_module('session_registry')
    run = ph.create_programme(['path-fixture'], 'path-pm')['run']
    count = [0]

    def registry_row(sid, path, at='2026-01-01T00:00:00Z', pane='pane-a'):
        row = {'at': at, 'session_id': sid, 'pane_id': pane, 'server': 'default', 'workspace': 'paths',
               'interactive': True, 'host': 'herdr'}
        if path is not None:
            row['transcript_path'] = str(path)
        sr._append(sr.registry_path('default', 'paths'), row)

    def transcript_at(sid, name=None):
        count[0] += 1
        folder = work / ('t' + str(count[0]))
        folder.mkdir()
        return folder / (name or sid + '.jsonl')

    def own(row, sid):
        return dict(row, sessionId=sid)

    def hook_data(sid, path):
        return {'session_id': sid, 'transcript_path': str(path), 'tool_name': 'AskUserQuestion',
                'tool_use_id': 'toolu_pick', 'tool_input': PICK['message']['content'][0]['input'],
                'tool_response': {'questions': [{'question': QUESTION}], 'answers': {QUESTION: 'fixed every 15 min'}}}

    def forge(row, path):
        changed = copy.deepcopy(row)
        changed['payload'].setdefault('source', {})['path'] = str(path)
        return changed

    def journaled(sid, path):
        """One pick and one typed message at `path`, captured while the registry holds nothing for `sid`."""
        path.write_text(json.dumps(own(PICK, sid)) + '\n')
        pick = pj.append_prompt(run, sid, 'picked', 'unknown', source=picks.capture(hook_data(sid, path)))
        prompt_payload = {'session_id': sid, 'prompt': 'yes', 'prompt_id': 'prompt-' + sid, 'transcript_path': str(path)}
        said = pj.append_prompt(run, sid, 'yes', 'unknown', source=words.capture(prompt_payload))
        with path.open('a') as stream:
            stream.write(json.dumps(own(RESULT, sid)) + '\n')
            stream.write(json.dumps({'type': 'user', 'sessionId': sid, 'promptId': 'prompt-' + sid, 'promptSource': 'typed',
                                     'turnOrigin': 'human', 'origin': {'kind': 'human'}, 'entrypoint': 'cli',
                                     'message': {'role': 'user', 'content': 'yes'}}) + '\n')
        return pick, said

    def surfaces(sid, path, pick, said):
        return {'capture': picks.capture(hook_data(sid, path)) is not None,
                'pick': pj.prompt_origin(forge(pick, path)),
                'words': pj.prompt_origin(forge(said, path)),
                'question': picks.question_before(forge(said, path)) is not None}

    # Registry rows for a session a test named: a row with no path is what record_proven_pane leaves.
    states = {
        'no row': lambda sid, held: None,
        'a row with no path': lambda sid, held: registry_row(sid, None),
        'a row evicted past the per-pane cap': lambda sid, held: (
            registry_row(sid, held, pane='evict-' + sid),
            [registry_row('other-' + sid, None, pane='evict-' + sid) for _ in range(sr.LINES_PER_PANE)]),
    }
    for state, arrange in states.items():
        sid = 'sid-' + state.replace(' ', '-')
        path = transcript_at(sid)
        arrange(sid, path)
        check(f'{state}: the registry holds no path', sr.transcript_path(sid), None)
        pick, said = journaled(sid, path)
        check(f'{state}: an absolute path named for the session verifies', surfaces(sid, path, pick, said), ALL_PASS)
        elsewhere = transcript_at(sid)
        elsewhere.write_bytes(path.read_bytes())
        check(f'{state}: the same file name in another folder verifies, since nothing names a folder',
              surfaces(sid, elsewhere, pick, said), ALL_PASS)
        other_name = path.with_name('someone-else.jsonl')
        other_name.write_bytes(path.read_bytes())
        check(f'{state}: a file named for another session refuses', surfaces(sid, other_name, pick, said), ALL_REFUSE)
        check(f'{state}: a relative path refuses', surfaces(sid, pathlib.Path(sid + '.jsonl'), pick, said), ALL_REFUSE)

    sid = 'sid-held'
    path = transcript_at(sid)
    pick, said = journaled(sid, path)
    registry_row(sid, path)
    check('a row with the same path verifies', surfaces(sid, path, pick, said), ALL_PASS)
    copied = transcript_at(sid)
    copied.write_bytes(path.read_bytes())
    check('a row with another path refuses a copy named for the session', surfaces(sid, copied, pick, said), ALL_REFUSE)

    # Past approvals: the fall-back read covers every case above, and still needs the file named for the session.
    sid = 'sid-past'
    path = transcript_at(sid)
    pick, said = journaled(sid, path)
    check('an older approval with no row verifies', (pj.adopted_origin(pick), pj.adopted_origin(said)), ('picked', 'typed'))
    registry_row(sid, transcript_at(sid))
    check('an older approval stays verified after the session moved', (pj.adopted_origin(pick), pj.adopted_origin(said)),
          ('picked', 'typed'))
    wrong = path.with_name('someone-else.jsonl')
    wrong.write_bytes(path.read_bytes())
    check('an older approval in a file named for another session refuses',
          (pj.adopted_origin(forge(pick, wrong)), pj.adopted_origin(forge(said, wrong))), ('unknown', 'unknown'))

    # A new SessionStart row moves the session: the newest row is the one that counts, also within one second.
    sid = 'sid-moved'
    first = transcript_at(sid)
    pick, said = journaled(sid, first)
    registry_row(sid, first, at='2026-01-01T00:00:00Z')
    check('before the move the first path verifies', surfaces(sid, first, pick, said), ALL_PASS)
    second = transcript_at(sid)
    second.write_bytes(first.read_bytes())
    registry_row(sid, second, at='2026-01-01T00:00:05Z')
    check('after the move the new path verifies', surfaces(sid, second, pick, said), ALL_PASS)
    check('after the move the first path refuses', surfaces(sid, first, pick, said), ALL_REFUSE)
    third = transcript_at(sid)
    third.write_bytes(first.read_bytes())
    registry_row(sid, third, at='2026-01-01T00:00:05Z')
    check('a second move in the same second uses the later row', surfaces(sid, third, pick, said), ALL_PASS)
    check('and refuses the row before it', surfaces(sid, second, pick, said), ALL_REFUSE)
    registry_row(sid, None, at='2026-01-01T00:00:09Z')
    check('a newer row with no path does not hide the path the session holds', surfaces(sid, third, pick, said), ALL_PASS)
    check('and a mismatch still refuses under it', surfaces(sid, first, pick, said), ALL_REFUSE)

    ph.end_programme(run, 'isolated path fixture complete')

print(f'programme-transcript-path.test.sh: {passed} passed, {failed} failed')
sys.exit(1 if failed else 0)
PY
