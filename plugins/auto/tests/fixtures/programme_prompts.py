import json
import os
import pathlib
import subprocess
import sys
import tempfile
import uuid


def fixture(text, sid, prompt_source='typed'):
    from _bootstrap import load_lib_module
    parent = pathlib.Path(os.environ['CLAUDE_AUTO_DATA_DIR']).parent / 'prompt-fixtures'
    parent.mkdir(parents=True, exist_ok=True)
    path = pathlib.Path(tempfile.mkdtemp(dir=parent)) / (sid + '.jsonl')
    path.write_text('')
    payload = {'session_id': sid, 'prompt': text, 'prompt_id': str(uuid.uuid4()),
               'transcript_path': str(path), 'hook_event_name': 'UserPromptSubmit'}
    source = load_lib_module('programme_prompt_source').capture(payload)
    row = {'type': 'user', 'sessionId': sid, 'promptId': payload['prompt_id'],
           'promptSource': prompt_source, 'turnOrigin': 'human', 'origin': {'kind': 'human'},
           'entrypoint': 'cli', 'message': {'role': 'user', 'content': text}}
    return payload, source, path, row


def append_prompt(run, sid, text, origin='typed', now=None, prompt_source='typed'):
    from _bootstrap import load_lib_module
    pj = load_lib_module('programme_journal')
    if origin != 'typed':
        return pj.append_prompt(run, sid, text, origin, now=now)
    _, source, path, row = fixture(text, sid, prompt_source)
    result = pj.append_prompt(run, sid, text, origin, now=now, source=source)
    path.write_text(json.dumps(row) + '\n')
    return result


if __name__ == '__main__':
    root, sid, text = sys.argv[1:]
    sys.path.insert(0, str(pathlib.Path(root) / 'lib'))
    payload, _, path, row = fixture(text, sid)
    result = subprocess.run(['bash', str(pathlib.Path(root) / '.claude/hooks/on-user-prompt.sh')],
                            input=json.dumps(payload), text=True, capture_output=True)
    path.write_text(json.dumps(row) + '\n')
    sys.stdout.write(result.stdout)
    sys.stderr.write(result.stderr)
    sys.exit(result.returncode)
