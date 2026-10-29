#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

echo "programme-sweep-noop-chain.test.sh"
"$PY" - "$AUTO_ROOT" <<'EOF'
import json
import os
import subprocess
import sys
import tempfile

root = sys.argv[1]
passed = failed = 0


def check(name, actual, expected):
    global passed, failed
    if actual == expected:
        passed += 1
        print('  PASS ' + name)
    else:
        failed += 1
        print('  FAIL {}: expected {!r}, got {!r}'.format(name, expected, actual))


with tempfile.TemporaryDirectory(prefix='auto-noop-chain-') as work:
    env = dict(os.environ, CLAUDE_AUTO_DATA_DIR=work + '/data', CLAUDE_AUTO_PERSONAL_PROTOCOL=work + '/p/protocol.json',
               CLAUDE_AUTO_MACHINE='studio', CLAUDE_AUTO_TEST_HARNESS='1', CLAUDE_CODE_SESSION_ID='sess-pm')
    for key in list(env):
        if key.startswith('HERDR_') or key == 'CLAUDE_AUTO_REPO':
            del env[key]
    lib = os.path.join(root, 'lib')
    run = subprocess.run(['/usr/bin/python3', '-c',
                          'import sys; sys.path.insert(0, sys.argv[1]); from _bootstrap import load_lib_module; '
                          'print(load_lib_module("programme_home").create_programme(["w2"], "sess-pm")["run"])', lib],
                         capture_output=True, text=True, env=env).stdout.strip()

    def verb(*args):
        return subprocess.run(['bash', os.path.join(lib, 'programme.sh'), *args, '--run', run],
                              capture_output=True, text=True, env=env)

    def chain():
        for step in (['validate'], ['sweep', '--record-sources'], ['propose-permission'], ['settle-permissions']):
            check('chained verb ' + step[0] + ' exits 0 on a quiet programme', verb(*step).returncode, 0)
        subprocess.run(['/usr/bin/python3', os.path.join(lib, 'programme_journal.py'), 'prune', '--run', run],
                       capture_output=True, text=True, env=env)

    verb('watcher-beat', 'remit', '--task-id', 't1', '--kind', 'monitor')
    verb('watcher-beat', 'cron', '--task-id', 'c1', '--kind', 'cron', '--prompt', 'sweep')
    chain()
    first = json.loads(verb('sweep-inputs').stdout)
    check('the first pass records the sources, so a sweep that records a source change is not quiet',
          first['verdict'], 'changed')
    verb('set-now', 'idle')
    verb('focus-note', '--agents', '0')
    subprocess.run(['bash', os.path.join(lib, 'programme.sh'), 'record-trajectories', '--run', run], input='[]',
                   capture_output=True, text=True, env=env)
    chain()
    subprocess.run(['/usr/bin/python3', '-c',
                    'import sys; sys.path.insert(0, sys.argv[2]); from _bootstrap import load_lib_module; '
                    'load_lib_module("programme_journal").append_prompt(sys.argv[1], "sess-pm", "Run the programme sweep", "cron")',
                    run, lib], capture_output=True, text=True, env=env)
    second = json.loads(verb('sweep-inputs').stdout)
    check('a second chained pass on a quiet programme, in the order the skill prescribes and after a cron wake, reads unchanged',
          (second['verdict'], second['why']), ('unchanged', []))
    rows = [r for r in second['journal_since'] if not r['quiet']]
    check('every row that pass wrote is one the verb classes as bookkeeping', rows, [])
    check('the pass did write bookkeeping rows, so the check above had something to judge',
          len(second['journal_since']) > 0, True)

print('programme-sweep-noop-chain.test.sh: {} passed, {} failed'.format(passed, failed))
sys.exit(1 if failed else 0)
EOF
