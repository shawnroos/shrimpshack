#!/usr/bin/env python3
"""Run `offer` for the commands, answer the printed picker the way Shawn would, and print the pick's prompt id.

offer_pick.py <run> [--option <n>] [--other <text>] [--decline] <command>...
"""

import json
import os
import pathlib
import subprocess
import sys
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'lib'))
from _bootstrap import load_lib_module  # noqa: E402
sys.path.insert(0, str(ROOT / 'tests' / 'fixtures'))
from registered_transcript import transcript  # noqa: E402


def answer_picker(run, sid, questions, answer):
    tool_use_id = 'toolu_' + uuid.uuid4().hex[:12]
    path = transcript(sid)
    answers = {questions[0]['question']: answer}
    ask = {'type': 'assistant', 'uuid': 'a-' + tool_use_id, 'sessionId': sid, 'isSidechain': False,
           'message': {'role': 'assistant', 'content': [
               {'type': 'tool_use', 'id': tool_use_id, 'name': 'AskUserQuestion', 'input': {'questions': questions}}]}}
    result = {'type': 'user', 'uuid': 'u-' + tool_use_id, 'sessionId': sid, 'isSidechain': False,
              'sourceToolAssistantUUID': 'a-' + tool_use_id,
              'permissionDecision': {'decision': 'accept', 'source': 'user_temporary'},
              'toolUseResult': {'questions': questions, 'answers': answers, 'annotations': {}},
              'message': {'role': 'user', 'content': [{'type': 'tool_result', 'tool_use_id': tool_use_id,
                                                       'content': 'answered'}]}}
    with path.open('a') as stream:
        stream.write(json.dumps(ask) + '\n' + json.dumps(result) + '\n')
    source = load_lib_module('programme_pick_source')
    data = {'session_id': sid, 'transcript_path': str(path), 'tool_name': 'AskUserQuestion',
            'tool_use_id': tool_use_id, 'tool_input': {'questions': questions},
            'tool_response': {'answers': answers, 'questions': questions}, 'hook_event_name': 'PostToolUse'}
    return load_lib_module('programme_journal').append_prompt(
        run, sid, source.summary(answers), 'unknown', source=source.capture(data), driving=True)['prompt_id']


def main(argv):
    run, rest = argv[0], argv[1:]
    index, other, decline, commands = 0, None, False, []
    while rest:
        arg = rest.pop(0)
        if arg == '--option':
            index = int(rest.pop(0))
        elif arg == '--other':
            other = rest.pop(0)
        elif arg == '--decline':
            decline = True
        else:
            commands.append(arg)
    args = [sys.executable, str(ROOT / 'lib/programme.py'), 'offer', 'pick']
    for command in commands:
        args += ['--command', command]
    offered = subprocess.run(args + ['--run', run], text=True, capture_output=True)
    if offered.returncode != 0:
        sys.stderr.write(offered.stdout + offered.stderr)
        return 1
    printed = json.loads(offered.stdout)
    questions = printed['input']['questions']
    labels = [o['label'] for o in questions[0]['options'] if o['label'] != printed['decline']]
    answer = other if other is not None else printed['decline'] if decline else labels[index]
    print(answer_picker(run, os.environ['CLAUDE_CODE_SESSION_ID'], questions, answer))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
