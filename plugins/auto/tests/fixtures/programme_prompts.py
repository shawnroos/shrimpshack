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


def pick_rows(sid, tool_use_id, questions, answers, annotations=None, result_extra=None):
    # Field for field what Claude Code 2.1.318 wrote for a live picker; only the values change.
    shown = [{'question': question, 'header': question[:12], 'multiSelect': False,
              'options': [{'label': label, 'description': 'Choose ' + label} for label in labels]}
             for question, labels in questions.items()]
    asking = 'a-' + tool_use_id
    ask = {'parentUuid': None, 'isSidechain': False, 'type': 'assistant', 'uuid': asking, 'sessionId': sid,
           'session_id': sid, 'version': '2.1.318', 'entrypoint': 'cli',
           'message': {'role': 'assistant', 'content': [
               {'type': 'tool_use', 'id': tool_use_id, 'name': 'AskUserQuestion', 'input': {'questions': shown}}]}}
    result = {'questions': shown, 'answers': answers, 'annotations': annotations or {}}
    if annotations is False:
        del result['annotations']
    result.update(result_extra or {})
    said = ', '.join(f'"{q}"="{a}"' for q, a in answers.items())
    answer = {'parentUuid': asking, 'isSidechain': False, 'type': 'user', 'uuid': 'u-' + tool_use_id, 'sessionId': sid,
              'session_id': sid, 'version': '2.1.318', 'entrypoint': 'cli', 'sourceToolAssistantUUID': asking,
              'permissionDecision': {'decision': 'accept', 'source': 'user_temporary', 'grantScope': 'once',
                                     'reasonCode': 'unknown'},
              'toolUseResult': result,
              'message': {'role': 'user', 'content': [
                  {'type': 'tool_result', 'tool_use_id': tool_use_id,
                   'content': f'Your questions have been answered: {said}.'}]}}
    return ask, answer


def queued_user_row(sid, text, prompt_id='later-turn', prompt_source='queued'):
    # The row's promptId is its own; the hook that journaled the words carried the id of the turn then running.
    return {'type': 'user', 'sessionId': sid, 'promptId': prompt_id, 'promptSource': prompt_source,
            'turnOrigin': 'human', 'origin': {'kind': 'human'}, 'entrypoint': 'cli', 'isSidechain': False,
            'message': {'role': 'user', 'content': text}}


def queued_attachment_row(sid, text, kind='human', human_turn=True, command_mode='prompt'):
    attachment = {'type': 'queued_command', 'prompt': text, 'source_uuid': 'src-1', 'delivery_id': 'del-1',
                  'commandMode': command_mode, 'origin': {'kind': kind}, 'timestamp': '2026-11-04T20:13:58.873Z'}
    if human_turn is not None:
        attachment['humanTurn'] = human_turn
    return {'type': 'attachment', 'sessionId': sid, 'session_id': sid, 'isSidechain': False, 'uuid': 'att-1',
            'attachment': attachment}


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
