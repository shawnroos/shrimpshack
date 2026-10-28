#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
"$PY" - "$AUTO_ROOT" <<'PY'
import json
import os
import subprocess
import sys
import tempfile

root = sys.argv[1]
WRAPPER = os.path.join(root, 'lib', 'token-cost.sh')
passed = failed = 0


def check(name, actual, expected):
    global passed, failed
    if actual == expected:
        passed += 1
        print('  PASS ' + name)
    else:
        failed += 1
        print('  FAIL {}: expected {!r}, got {!r}'.format(name, expected, actual))


def run(*args):
    env = dict(os.environ, TZ='UTC')
    proc = subprocess.run(['bash', WRAPPER, *args], capture_output=True, text=True, env=env)
    return proc.returncode, proc.stdout, proc.stderr


def assistant(mid, ts, usage, blocks=None):
    return json.dumps({'type': 'assistant', 'uuid': 'u-' + mid, 'timestamp': ts,
                       'message': {'id': mid, 'role': 'assistant', 'usage': usage,
                                   'content': blocks or [{'type': 'text', 'text': 'x'}]}})


def tool_result(tool_use_id, content):
    return json.dumps({'type': 'user', 'uuid': 'r-' + tool_use_id, 'timestamp': '2026-10-20T10:00:01Z',
                       'message': {'role': 'user',
                                   'content': [{'type': 'tool_result', 'tool_use_id': tool_use_id, 'content': content}]}})


def usage(inp=0, cc=0, cr=0, out=0):
    return {'input_tokens': inp, 'cache_creation_input_tokens': cc, 'cache_read_input_tokens': cr,
            'output_tokens': out}


def skill(tool_id, name):
    return {'type': 'tool_use', 'id': tool_id, 'name': 'Skill', 'input': {'skill': name}}


with tempfile.TemporaryDirectory(prefix='token-cost-') as work:
    session = os.path.join(work, 'pm.jsonl')
    sub_dir = os.path.join(work, 'pm', 'subagents')
    os.makedirs(sub_dir)
    lines = []
    # one message id seen three times (streaming chunks): must count once
    for _ in range(3):
        lines.append(assistant('m1', '2026-10-20T10:00:00Z', usage(100, 1000, 0, 10)))
    lines.append(assistant('m2', '2026-10-20T10:05:00Z', usage(10, 0, 10000, 20), [
        skill('t1', 'programme-sweep'),
        {'type': 'tool_use', 'id': 't2', 'name': 'Bash', 'input': {'command': 'bash lib/programme.sh status --json'}}]))
    lines.append(tool_result('t2', 'z' * 5000))
    # exactly 20 minutes after m2: counts as an idle wake
    lines.append(assistant('m3', '2026-10-20T10:25:00Z', usage(10, 0, 20000, 0), [
        skill('t3', 'auto:programme-sweep'),
        {'type': 'tool_use', 'id': 't4', 'name': 'Read', 'input': {'file_path': '/x/a.md'}}]))
    # streaming repeats the line that carries the Skill call: still one activation
    lines.append(assistant('m3', '2026-10-20T10:25:00Z', usage(10, 0, 20000, 0), [skill('t3', 'auto:programme-sweep')]))
    lines.append(tool_result('t4', [{'type': 'text', 'text': 'y' * 3000}]))
    lines.append('{not json')
    # a synthetic placeholder line (all-zero usage) is not a turn
    lines.append(assistant('zero', '2026-10-20T10:26:00Z', usage()))
    lines.append(json.dumps({'type': 'assistant', 'uuid': 'nousage', 'timestamp': '2026-10-20T11:00:00Z',
                             'message': {'id': 'nu', 'role': 'assistant', 'content': [
                                 {'type': 'tool_use', 'id': 't5', 'name': 'Glob', 'input': {}}]}}))
    lines.append(tool_result('t5', 'g' * 100))
    lines.append(assistant('m4', '2026-10-20T23:50:00Z', usage(0, 0, 30000, 0)))
    # crosses midnight, exactly 20 minutes after m4
    lines.append(assistant('m5', '2026-10-21T00:10:00Z', usage(0, 0, 40000, 10)))
    with open(session, 'w') as handle:
        handle.write('\n'.join(lines) + '\n')
    with open(os.path.join(sub_dir, 'agent-a.jsonl'), 'w') as handle:
        handle.write('\n'.join([
            assistant('sa1', '2026-10-20T10:10:00Z', usage(1000, 0, 0, 100)),
            assistant('sa1', '2026-10-20T10:10:00Z', usage(1000, 0, 0, 100)),
            assistant('sa2', '2026-10-21T00:00:00Z', usage(500, 0, 0, 0))]) + '\n')

    code, out, err = run('--json', session)
    check('a fixture transcript reports without error', code, 0)
    report = json.loads(out)
    total, days = report['total'], report['days']
    check('duplicate message ids count once: parent cost', total['parent_cost'], 11570.0)
    check('subagent cost is summed into the parent report', total['subagent_cost'], 2000.0)
    check('total cost is parent plus subagents', total['cost'], 13570.0)
    check('parent turns exclude duplicates and rows without usage', total['turns'], 5)
    check('subagent turns are counted apart from parent turns', total['subagent_turns'], 2)
    check('both programme-sweep spellings count as sweep activations', total['sweeps'], 2)
    check('peak context is the largest cache-create + cache-read per turn', total['peak_context'], 40000)
    check('average context over parent turns', total['avg_context'], 20200)
    check('a gap of exactly 20 minutes (and longer) counts as an idle wake', total['idle_turns'], 3)
    check('idle-wake share of parent cost', round(total['idle_cost_share'], 4), round(9060 / 11570, 4))
    check('a malformed line is skipped and counted', report['skipped_lines'], 1)
    check('a session spanning midnight splits into two days', sorted(days), ['2026-10-20', '2026-10-21'])
    check('day one parent cost', days['2026-10-20']['parent_cost'], 7520.0)
    check('day two parent cost', days['2026-10-21']['parent_cost'], 4050.0)
    check('subagent cost lands on the subagent message day: day one', days['2026-10-20']['subagent_cost'], 1500.0)
    check('subagent cost lands on the subagent message day: day two', days['2026-10-21']['subagent_cost'], 500.0)
    check('day one turns', days['2026-10-20']['turns'], 4)
    check('day one sweeps', days['2026-10-20']['sweeps'], 2)

    code, out, err = run('--json', '--idle-minutes', '21', session)
    check('a longer idle threshold drops the exactly-20-minute wakes', json.loads(out)['total']['idle_turns'], 1)

    code, out, err = run('--json', '--sources', session)
    sources = json.loads(out)['sources']
    check('sources rank tool-result bytes, largest first, mapping tool calls from lines without usage',
          [(row['key'], row['chars']) for row in sources],
          [('Bash:programme.sh', 5000), ('Read:/x/a.md', 3000), ('Glob', 100)])

    code, out, err = run(session)
    check('text output names the cost per day', '2026-10-20' in out and '2026-10-21' in out, True)

    ce = os.path.join(work, 'ce.jsonl')
    with open(ce, 'w') as handle:
        handle.write('\n'.join([
            assistant('c0', '2026-10-20T10:00:00Z', usage(100)),
            assistant('c1', '2026-10-20T10:01:00Z', usage(200), [skill('s1', 'compound-engineering:ce-plan')]),
            assistant('c2', '2026-10-20T10:02:00Z', usage(300)),
            assistant('c3', '2026-10-20T10:03:00Z', usage(400), [skill('s2', 'ce-doc-review')]),
            assistant('c4', '2026-10-20T10:04:00Z', usage(500)),
            # a later non-CE skill ends the CE window: later turns are not CE work
            assistant('c5', '2026-10-20T10:05:00Z', usage(600), [skill('s3', 'auto:programme-sweep')]),
            assistant('c6', '2026-10-20T10:06:00Z', usage(700))]) + '\n')
    os.makedirs(os.path.join(work, 'ce', 'subagents'))
    with open(os.path.join(work, 'ce', 'subagents', 'agent-a.jsonl'), 'w') as handle:
        handle.write('\n'.join([
            assistant('ca1', '2026-10-20T10:02:30Z', usage(1000)),
            assistant('ca2', '2026-10-20T10:05:30Z', usage(2000))]) + '\n')
    code, out, err = run('--json', '--ce', ce)
    groups = json.loads(out)['ce']
    check('--ce charges a subagent turn to the CE skill active when it ran, apart from the parent cost',
          {k: v['subagent_cost'] for k, v in groups.items()},
          {'(none)': 2000.0, 'ce-plan': 1000.0, 'ce-doc-review': 0.0})
    check('--ce groups cost by the CE skill active when the turn ran, until any other skill starts',
          {k: v['cost'] for k, v in groups.items()},
          {'(none)': 1400.0, 'ce-plan': 500.0, 'ce-doc-review': 900.0})
    check('--ce counts invocations', {k: v['invocations'] for k, v in groups.items()},
          {'(none)': 0, 'ce-plan': 1, 'ce-doc-review': 1})

    missing = os.path.join(work, 'nope.jsonl')
    code, out, err = run('--json', missing)
    check('a missing transcript exits non-zero, never a zero-cost report', (code != 0, out.strip()), (True, ''))
    check('the missing-transcript error names the path', missing in err, True)

    empty = os.path.join(work, 'empty.jsonl')
    open(empty, 'w').close()
    code, out, err = run('--json', empty)
    check('an empty transcript exits non-zero with a message', (code != 0, bool(err.strip())), (True, True))

print('token-cost.test.sh: {} passed, {} failed'.format(passed, failed))
sys.exit(1 if failed else 0)
PY
