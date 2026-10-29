#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

echo "programme-sweep-inputs.test.sh"
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


lib = os.path.join(root, 'lib')
with tempfile.TemporaryDirectory(prefix='auto-sweep-inputs-') as work:
    env = dict(os.environ, CLAUDE_AUTO_DATA_DIR=work + '/data', CLAUDE_AUTO_PERSONAL_PROTOCOL=work + '/p/protocol.json',
               CLAUDE_AUTO_MACHINE='studio', CLAUDE_AUTO_TEST_HARNESS='1', CLAUDE_CODE_SESSION_ID='sess-pm')
    for key in list(env):
        if key.startswith('HERDR_') or key == 'CLAUDE_AUTO_REPO':
            del env[key]
    run = subprocess.run(['/usr/bin/python3', '-c',
                          'import sys; sys.path.insert(0, sys.argv[1]); from _bootstrap import load_lib_module; '
                          'print(load_lib_module("programme_home").create_programme(["w2"], "sess-pm")["run"])', lib],
                         capture_output=True, text=True, env=env).stdout.strip()
    home = os.path.join(work, 'data', 'programmes', run)

    def verb(*args):
        out = subprocess.run(['bash', os.path.join(lib, 'programme.sh'), *args, '--run', run],
                             capture_output=True, text=True, env=env)
        return out.returncode, out.stdout

    def inputs(*flags):
        code, out = verb('sweep-inputs', *flags)
        return code, (json.loads(out) if out.strip().startswith('{') else {})

    def journal_lines():
        return sum(1 for _ in open(os.path.join(home, 'journal.jsonl')))

    code, fresh = inputs()
    check('a fresh programme reads changed: no sweep has completed', (code, fresh['verdict'], 'no_prior_sweep' in fresh['why']),
          (0, 'changed', True))
    check('a fresh programme reports both wake-ups as not armed',
          sorted(w for w in fresh['why'] if w.startswith('watcher_missing')), ['watcher_missing:cron', 'watcher_missing:remit'])
    check('the inputs never name a source it did not read: last_sweep is null before the first working_now',
          fresh['last_sweep'], None)

    verb('watcher-beat', 'remit', '--task-id', 't1', '--kind', 'monitor')
    code, only_stamped = inputs()
    check('a remit Monitor only the PM stamped (no watcher process beat) does not count as armed',
          'watcher_missing:remit' in only_stamped['why'], True)
    verb('watcher-beat', 'remit', '--process-id', str(os.getpid()))
    verb('watcher-beat', 'cron', '--task-id', 'c1', '--kind', 'cron', '--prompt', 'sweep')
    verb('set-now', 'idle')
    code, quiet = inputs()
    check('with both wake-ups armed and a completed sweep, a quiet programme reads unchanged',
          (quiet['verdict'], quiet['why']), ('unchanged', []))
    check('last_sweep names the working_now row it compares against', quiet['last_sweep']['line'] > 0, True)

    for step in (['validate'], ['propose-permission'], ['settle-permissions']):
        verb(*step)
    subprocess.run(['/usr/bin/python3', os.path.join(lib, 'programme_journal.py'), 'prune', '--run', run],
                   capture_output=True, text=True, env=env)
    code, after_chain = inputs()
    check('the bookkeeping verbs a quiet sweep chains do not make the next sweep read changed',
          (after_chain['verdict'], after_chain['why']), ('unchanged', []))

    before = journal_lines()
    code, saved = inputs('--save')
    check('--save prints the verdict and where it saved the inputs', (code, saved['verdict'], os.path.basename(saved['inputs'])),
          (0, 'unchanged', 'sweep-inputs.json'))
    check('--save writes the file in the programme home', os.path.exists(os.path.join(home, 'sweep-inputs.json')), True)
    check('the saved file holds the full inputs, not the summary', 'journal_since' in json.load(open(saved['inputs'])), True)
    check('reading and saving the inputs journals nothing', journal_lines(), before)

    code, reasons = inputs('--reasons')
    check('--reasons prints only the actionable reasons', sorted(reasons), ['actionable_reasons', 'ok', 'run'])

    verb('add-item', 'test:one', '--title', 'A new piece of work')
    code, moved = inputs()
    check('a new item reads changed', moved['verdict'], 'changed')
    check('the change names the item and the journal rows it caused',
          ('items_changed' in moved['why'], 'journal_rows' in moved['why'], 'actionable_reasons' in moved['why']),
          (True, True, True))
    check('the moved item is listed by id', [m['item'] for m in moved['items_changed']][:1], ['test:one'])

    verb('set-now', 'working on test:one')
    code, again = inputs()
    check('a new working_now row resets the comparison point for journal rows and item history',
          ('journal_rows' in again['why'], 'items_changed' in again['why']), (False, False))

    digest = os.path.join(home, 'sweep-digest.md')
    open(digest, 'w').write('# stale digest')
    code, resaved = inputs('--save')
    check('--save removes the digest of an earlier sweep and writes fresh inputs',
          (code, os.path.exists(digest), os.path.exists(os.path.join(home, 'sweep-inputs.json'))), (0, False, True))
    code, again_saved = inputs('--save')
    check('--save with no digest present still succeeds', code, 0)
    os.mkdir(digest)
    code, over_dir = inputs('--save')
    check('--save does not fail when something other than a file sits at the digest path', code, 0)
    os.rmdir(digest)

    bare = subprocess.run(['/usr/bin/python3', os.path.join(lib, 'programme_journal.py'), 'prune'],
                          capture_output=True, text=True, env=env)
    check('prune finds the run from the session lease when --run is omitted', (bare.returncode, bare.stdout.strip()[:11]), (0, '{"removed":'))
    other = subprocess.run(['/usr/bin/python3', os.path.join(lib, 'programme_journal.py'), 'prune'],
                           capture_output=True, text=True, env=dict(env, CLAUDE_CODE_SESSION_ID='sess-nobody'))
    check('prune with no --run and a session that drives nothing refuses', other.returncode != 0, True)

    junk = subprocess.run(['bash', os.path.join(lib, 'programme.sh'), 'sweep-inputs', 'extra', '--run', run],
                          capture_output=True, text=True, env=env)
    check('a stray positional argument is refused', junk.returncode != 0, True)

    # In-process cases that need a fake GitHub or herdr.
    os.environ.update({k: v for k, v in env.items() if k.startswith('CLAUDE_')})
    sys.path.insert(0, lib)
    from _bootstrap import load_lib_module
    host = load_lib_module('programme')
    psi = load_lib_module('programme_sweep_inputs')
    sources = load_lib_module('programme_sources')
    run_id, home_dir, record = host._locate({'run': run})
    programme = record['programme']

    def build_with(refs, readiness):
        keep = psi._open_prs, psi._readiness
        psi._open_prs = lambda _p: refs
        psi._readiness = lambda _p, _r: readiness[:psi.PR_CAP] if len(readiness) > psi.PR_CAP else readiness
        try:
            return psi.build(host, run_id, home_dir, record)
        finally:
            psi._open_prs, psi._readiness = keep

    def pr(result, ends=False):
        return {'item': 'test:one', 'deliverable': 'merged', 'pr': 'o/r#1', 'result': result, 'ends': ends, 'note': ''}

    codes = lambda built: sorted(w for w in built['why'] if w.startswith('pr_'))
    check('a PR that is ready to merge is a change', codes(build_with([('k', 'd', 'o/r#1')], [pr('ready')])), ['pr_ready'])
    check('a PR that is merged or closed is a change',
          codes(build_with([('k', 'd', 'o/r#1')], [pr('not_ready', ends=True)])), ['pr_closed_or_merged'])
    check('a PR the verb cannot read is a change, never unchanged',
          codes(build_with([('k', 'd', 'o/r#1')], [pr('unknown')])), ['pr_unknown'])
    check('a PR that is open and not ready is not a change',
          codes(build_with([('k', 'd', 'o/r#1')], [pr('not_ready')])), [])
    nine = [('k', 'd', 'o/r#%d' % n) for n in range(9)]
    over = build_with(nine, [pr('not_ready')] * 9)
    check('a ninth open PR is a change: the verb checks eight', ('pr_over_cap' in over['why'], len(over['prs_unchecked'])), (True, 1))

    calls = []
    keep_read = sources.read_herdr
    sources.read_herdr = lambda: calls.append(1) or (None, 'down')
    check('no herdr read when no item waits on a worker', (psi._stalled(programme), calls), ([], []))

    def waiting_programme(pane):
        item = {'state': 'waiting', 'waiting_on': {'who': 'worker', 'reporter': 'worker'}, 'owner': {'pane': pane}, 'history': []}
        return {'items': {'w:1': item}, 'remit': {}}

    check('a worker item with herdr unreadable is stalled as unknown',
          psi._stalled(waiting_programme('w2:p1')), [{'item': 'w:1', 'pane': 'w2:p1', 'agent_status': 'unknown'}])
    sources.read_herdr = lambda: ({}, None)
    keep_views, keep_remit = sources.pane_views, sources.remit
    sources.remit = lambda _p: {}
    for status, expected in (('working', []), ('idle', [{'item': 'w:1', 'pane': 'w2:p1', 'agent_status': 'idle'}])):
        sources.pane_views = lambda _s, _scope, status=status: [{'pane_id': 'w2:p1', 'agent_status': status}]
        check('a worker pane that is ' + status + (' is not stalled' if status == 'working' else ' is stalled'),
              psi._stalled(waiting_programme('w2:p1')), expected)
    sources.pane_views = lambda _s, _scope: []
    check('a worker pane herdr no longer lists is stalled as unknown',
          psi._stalled(waiting_programme('w2:p1')), [{'item': 'w:1', 'pane': 'w2:p1', 'agent_status': 'unknown'}])
    sources.read_herdr, sources.pane_views, sources.remit = keep_read, keep_views, keep_remit

    for kind, payload, quiet in (('stop_quiet', {}, True), ('prompts_pruned', {}, True), ('working_now', {}, True),
                                 ('validate_pass', {'refuted': []}, True), ('validate_pass', {'refuted': [{'item': 'x'}]}, False),
                                 ('permission_proposed', {'proposals': []}, True),
                                 ('permission_proposed', {'proposals': [{'id': 'perm-1'}]}, False),
                                 ('effects_recorded', {'notify': {}}, True), ('effects_recorded', {'notify': {'a': 1}}, False),
                                 ('source_changed', {}, False), ('prompt', {}, False)):
        check('journal row %s %s is %s' % (kind, json.dumps(payload), 'quiet' if quiet else 'a change'),
              psi._quiet_row({'kind': kind, 'payload': payload}), quiet)

    readiness = load_lib_module('programme_readiness')
    resume = load_lib_module('programme_resume')

    def why_with(rows=None, claims=None, asks=None, stalled=None, claim_offset=0):
        keep = (psi.programme_journal.read, resume.claims_state, host.build_view, psi._stalled)
        base_rows = [{'kind': 'working_now', 'at': '2026-10-29T10:00:00Z', 'payload': {}}]
        psi.programme_journal.read = lambda _r: base_rows + (rows or [])
        if claims is not None:
            resume.claims_state = lambda _r, _h, _rec=None: (claims, claim_offset, None)
        real_view = host.build_view
        if asks is not None:
            host.build_view = lambda *a, **k: dict(real_view(*a, **k), asks=asks)
        if stalled is not None:
            psi._stalled = lambda _p: stalled
        try:
            return psi.build(host, run_id, home_dir, record)
        finally:
            psi.programme_journal.read, resume.claims_state, host.build_view, psi._stalled = keep

    claim = {'item': 'test:one', 'deliverable': 'merged', 'ref': 'o/r#1', 'text': 'done'}
    built = why_with(claims=[claim])
    check('an unread claim is a change and the verb reports where mark-read should go',
          ('unread_claims' in built['why'], built['claims']), (True, {'unread': 1, 'next_offset': 1}))
    two = [claim, dict(claim, ref='o/r#2')]
    half = why_with(claims=two, claim_offset=1)
    check('claims the PM already marked read are not unread: the offset slices them off',
          (half['claims'], [c['index'] for c in half['unread_claims']]), ({'unread': 1, 'next_offset': 2}, [1]))
    caught_up = why_with(claims=two, claim_offset=2)
    check('with every claim marked read there is no unread claim and no change from claims',
          ('unread_claims' in caught_up['why'], caught_up['claims']['unread']), (False, 0))
    check('an open ask that was never shown is a change',
          'ask_not_shown' in why_with(asks=[{'item': 'k', 'status': 'open', 'shown_current': False, 'fingerprint': 'f1'}])['why'], True)
    check('an open ask that was shown is not a change',
          'ask_not_shown' in why_with(asks=[{'item': 'k', 'status': 'open', 'shown_current': True, 'fingerprint': 'f1'}])['why'], False)
    check('an answered ask not yet relayed is a change',
          'ask_answered_unrelayed' in why_with(asks=[{'item': 'k', 'status': 'answered', 'shown_current': True}])['why'], True)
    check('the ask fingerprint reaches the inputs, the PM needs it to mark an ask shown',
          why_with(asks=[{'item': 'k', 'status': 'open', 'shown_current': True, 'fingerprint': 'f1'}])['asks'][0]['fingerprint'], 'f1')
    reread = [{'kind': 'rules_acked', 'at': '2026-10-29T10:01:00Z', 'payload': {}},
              {'kind': 'reread_requested', 'at': '2026-10-29T10:02:00Z', 'payload': {}}]
    check('a re-read request newer than the last acknowledgement is a change',
          'rules_reread_requested' in why_with(rows=reread)['why'], True)
    check('a re-read request already acknowledged is not a change',
          'rules_reread_requested' in why_with(rows=list(reversed(reread)))['why'], False)
    many = [{'kind': 'stop_quiet', 'at': '2026-10-29T10:03:00Z', 'payload': {}}] * (psi.ROW_CAP + 1)
    check('more than 300 quiet rows since the last sweep is a change: the list is cut, the verdict is not blind',
          'journal_overflow' in why_with(rows=many)['why'], True)
    check('a worker-owned item whose pane is not working is a change',
          'worker_not_working' in why_with(stalled=[{'item': 'w:1', 'pane': 'w2:p1', 'agent_status': 'idle'}])['why'], True)
    cron = {'kind': 'prompt', 'at': '2026-10-29T10:04:00Z', 'payload': {'origin': 'cron'}}
    typed = {'kind': 'prompt', 'at': '2026-10-29T10:04:00Z', 'payload': {'origin': 'typed'}}
    check('the cron fallback prompt is a quiet row, a cron wake can be quiet', psi._quiet_row(cron), True)
    check('a typed prompt is a change, Shawn said something', psi._quiet_row(typed), False)
    check('a focus note, written after working_now every sweep, is a quiet row',
          psi._quiet_row({'kind': 'focus_noted', 'payload': {'subagents': 2}}), True)

    def pr_facts(state):
        return {'state': state, 'isDraft': False, 'mergeable': 'UNKNOWN', 'mergeStateStatus': 'UNKNOWN', 'headRefOid': 'abc',
                'reviewThreads': {'totalCount': 0, 'nodes': []},
                'commits': {'nodes': [{'commit': {'oid': 'abc', 'statusCheckRollup': {'contexts': {'totalCount': 0, 'nodes': []}}}}]}}

    keep_cm = psi.programme_readiness.check_mergeable
    refs = [('k', 'd', 'o/r#1')]
    psi.programme_readiness.check_mergeable = lambda _r, _repos=None: {'result': 'not_ready', 'gates': ['already merged'], 'ended': True}
    check('the verb reads the ended flag from a merge-readiness verdict', psi._readiness({'remit': {}}, refs)[0]['ends'], True)
    psi.programme_readiness.check_mergeable = lambda _r, _repos=None: {'result': 'not_ready', 'gates': ['already merged']}
    check('wording alone no longer marks a PR ended: only the flag does', psi._readiness({'remit': {}}, refs)[0]['ends'], False)
    psi.programme_readiness.check_mergeable = keep_cm

    check('merge readiness marks a merged PR as ended', readiness._bar(pr_facts('MERGED')).get('ended'), True)
    check('merge readiness marks a closed PR as ended', readiness._bar(pr_facts('CLOSED')).get('ended'), True)

    quiet_facts = {'last': 3, 'since': [(4, {'kind': 'stop_quiet', 'payload': {}})], 'reasons': [{'kind': 'never_stop'}],
                   'asks': [{'status': 'open', 'shown_current': True}], 'claims': [], 'moved': [], 'refs': [], 'prs': [],
                   'stalled': [], 'armed': {'remit': True, 'cron': True}, 'reread_requested': False}
    check('a quiet table of facts has no reason to sweep: a stop-rule reason alone is not one', psi._verdict(quiet_facts), [])
    for name, change, code in (
            ('no completed sweep', {'last': None}, 'no_prior_sweep'),
            ('a real actionable reason', {'reasons': [{'kind': 'unread_claim'}]}, 'actionable_reasons'),
            ('an unread claim', {'claims': [{'index': 0}]}, 'unread_claims'),
            ('a moved item', {'moved': [{'item': 'k'}]}, 'items_changed'),
            ('a loud journal row', {'since': [(4, {'kind': 'item_added', 'payload': {}})]}, 'journal_rows'),
            ('a PR that is ready', {'prs': [{'result': 'ready', 'ends': False}]}, 'pr_ready'),
            ('a PR that is unreadable', {'prs': [{'result': 'unknown', 'ends': False}]}, 'pr_unknown'),
            ('a PR that ended', {'prs': [{'result': 'not_ready', 'ends': True}]}, 'pr_closed_or_merged'),
            ('nine PRs', {'refs': [None] * 9}, 'pr_over_cap'),
            ('a dead remit watcher', {'armed': {'remit': False, 'cron': True}}, 'watcher_missing:remit'),
            ('a missing cron', {'armed': {'remit': True, 'cron': False}}, 'watcher_missing:cron')):
        check('the verdict names ' + name, psi._verdict(dict(quiet_facts, **change)), [code])

print('programme-sweep-inputs.test.sh: {} passed, {} failed'.format(passed, failed))
sys.exit(1 if failed else 0)
EOF
