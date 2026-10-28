#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

echo "programme-sweep-noop-chain.test.sh"
"$PY" - "$AUTO_ROOT" <<'EOF'
import json
import os
import re
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


agent = open(os.path.join(root, 'agents', 'programme-sweep-packager.md')).read()
rule = next(line for line in agent.splitlines() if line.startswith('- the journal since line `L`'))
named = set(re.findall(r'`([a-z_]+)`', rule)) - {'L'}

with tempfile.TemporaryDirectory(prefix='auto-noop-chain-') as work:
    env = dict(os.environ, CLAUDE_AUTO_DATA_DIR=work + '/data', CLAUDE_AUTO_PERSONAL_PROTOCOL=work + '/p/protocol.json',
               CLAUDE_AUTO_MACHINE='studio', CLAUDE_AUTO_TEST_HARNESS='1', CLAUDE_CODE_SESSION_ID='sess-pm')
    for key in list(env):
        if key.startswith('HERDR_') or key == 'CLAUDE_AUTO_REPO':
            del env[key]
    lib = os.path.join(root, 'lib')
    run = subprocess.run([sys.executable if False else '/usr/bin/python3', '-c',
                          'import sys; sys.path.insert(0, sys.argv[1]); from _bootstrap import load_lib_module; '
                          'print(load_lib_module("programme_home").create_programme(["w2"], "sess-pm")["run"])', lib],
                         capture_output=True, text=True, env=env).stdout.strip()
    journal = os.path.join(work, 'data', 'programmes', run, 'journal.jsonl')

    def chain():
        verbs = [['validate'], ['sweep', '--record-sources'], ['propose-permission'], ['settle-permissions']]
        for verb in verbs:
            out = subprocess.run(['bash', os.path.join(lib, 'programme.sh'), *verb, '--run', run],
                                 capture_output=True, text=True, env=env)
            check('chained verb ' + verb[0] + ' exits 0 on a quiet programme', out.returncode, 0)
        subprocess.run(['/usr/bin/python3', os.path.join(lib, 'programme_journal.py'), 'prune', '--run', run],
                       capture_output=True, text=True, env=env)

    def rows():
        return [json.loads(line) for line in open(journal)]

    chain()
    seen = len(rows())
    chain()
    second = rows()[seen:]
    check('a quiet second pass journals something to compare against', len(second) > 0, True)
    check('every kind a quiet pass journals is named in the packager unchanged rule',
          sorted({row['kind'] for row in second} - named), [])
    payloads = {row['kind']: row.get('payload') or {} for row in second}
    check('validate_pass on a quiet pass has nothing refuted', payloads.get('validate_pass', {}).get('refuted'), [])
    check('permission_proposed on a quiet pass has no proposals', payloads.get('permission_proposed', {}).get('proposals'), [])
    check('the packager rule says when validate_pass and permission_proposed count as quiet',
          'refuted' in rule and 'proposals' in rule, True)

print('programme-sweep-noop-chain.test.sh: {} passed, {} failed'.format(passed, failed))
sys.exit(1 if failed else 0)
EOF
