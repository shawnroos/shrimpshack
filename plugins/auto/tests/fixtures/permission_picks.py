import json
import sys
import uuid


def pick(run, sid, transcript, questions, answer, annotations=None):
    from _bootstrap import load_lib_module
    from registered_transcript import register
    register(sid, transcript)
    ps = load_lib_module('programme_pick_source')
    pj = load_lib_module('programme_journal')
    tool_use_id = 'toolu_' + uuid.uuid4().hex[:12]
    answers = {questions[0]['question']: answer}
    ask = {'type': 'assistant', 'uuid': 'a-' + tool_use_id, 'sessionId': sid, 'isSidechain': False,
           'message': {'role': 'assistant', 'content': [
               {'type': 'tool_use', 'id': tool_use_id, 'name': 'AskUserQuestion', 'input': {'questions': questions}}]}}
    result = {'type': 'user', 'uuid': 'u-' + tool_use_id, 'sessionId': sid, 'isSidechain': False,
              'sourceToolAssistantUUID': 'a-' + tool_use_id,
              'permissionDecision': {'decision': 'accept', 'source': 'user_temporary'},
              'toolUseResult': {'questions': questions, 'answers': answers, 'annotations': annotations or {}},
              'message': {'role': 'user', 'content': [{'type': 'tool_result', 'tool_use_id': tool_use_id,
                                                       'content': 'answered'}]}}
    with open(transcript, 'a') as stream:
        stream.write(json.dumps(ask) + '\n' + json.dumps(result) + '\n')
    source = ps.capture({'session_id': sid, 'transcript_path': transcript, 'tool_name': 'AskUserQuestion',
                         'tool_use_id': tool_use_id, 'tool_input': {'questions': questions},
                         'tool_response': {'answers': answers, 'questions': questions},
                         'hook_event_name': 'PostToolUse'})
    return pj.append_prompt(run, sid, ps.summary(answers), 'unknown', source=source, driving=True)['prompt_id']


# The last argument chooses the answer: "command" picks the offer's command, "decline" its decline, "text:<words>" is
# Other, and "note:<words>" picks the command with a note. The offer's printed JSON arrives on stdin.
def main(argv):
    root, run, sid, transcript, which = argv
    sys.path.insert(0, root + '/lib')
    printed = json.loads(sys.stdin.read().strip().splitlines()[-1])
    questions = printed['input']['questions']
    labels = [o['label'] for o in questions[0]['options'] if o['label'] != printed['decline']]
    annotations = None
    if which == 'command':
        answer = labels[0]
    elif which == 'decline':
        answer = printed['decline']
    elif which.startswith('text:'):
        answer = which[len('text:'):]
    else:
        answer = labels[0]
        annotations = {questions[0]['question']: {'notes': which[len('note:'):]}}
    print(pick(run, sid, transcript, questions, answer, annotations))


if __name__ == '__main__':
    main(sys.argv[1:])
