#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
check() { if [ "$1" = "$2" ]; then pass; else fail "expected [$1] got [$2]"; fi; }

echo "programme-domain-state.test.sh"

run_py() {
  AUTO_LIB="${AUTO_ROOT}/lib" "$PY" -I -c "
import os, sys
sys.path.insert(0, os.environ['AUTO_LIB'])
from _bootstrap import load_lib_module
s = load_lib_module('programme_domain_state')
def rec(pane, ws='w3'):
    return {'pane': pane, 'workspace_id': ws, 'reason': 'x', 'agent': 'claude', 'agent_status': 'idle', 'title': None, 'cwd': None}
def scan(outside=(), remit=('w2:p1',), gone=()):
    return {'domain': [rec(p) for p in outside], 'folder_gone': [{'pane': g} for g in gone],
            'panes': [{'pane_id': p, 'agent': 'claude'} for p in remit]}
ENTRY = {'id': 'b1', 'layer': 'personal', 'state': 'active', 'applies_to': 'pm',
         'when': {'text': 'the domain changed', 'trigger': 'domain', 'checks': []}, 'adoption': {}}
STORE = {'repos': {}, 'personal': [ENTRY], 'rejected': [], 'notices': [], 'held': []}
$1
"
}

it "the first scan with an outside session is not yet shown"
check "1 False True" "$(run_py "
p = {}
s.record_scan(p, scan(['w3:p1']), '2026-10-31T10:00:00Z')
r = s.recommendations(p)
print(len(r['set']), r['shown_current'], s.unshown(p))")"

it "a host that could not be read leaves the stored state alone"
check "1" "$(run_py "
p = {}
s.record_scan(p, scan(['w3:p1']), '2026-10-31T10:00:00Z')
s.record_scan(p, {'domain': None}, '2026-10-31T10:05:00Z')
print(len(s.recommendations(p)['set']))")"

it "after the set is marked shown, the same set stays shown"
check "True False" "$(run_py "
p = {}
s.record_scan(p, scan(['w3:p1']), '2026-10-31T10:00:00Z')
box = p['domain']['recommendations']
box['shown'] = {'at': 'x', 'fingerprint': box['fingerprint']}
s.record_scan(p, scan(['w3:p1']), '2026-10-31T10:10:00Z')
print(s.recommendations(p)['shown_current'], s.unshown(p))")"

it "a changed set is not shown again until marked"
check "False True" "$(run_py "
p = {}
s.record_scan(p, scan(['w3:p1']), '2026-10-31T10:00:00Z')
box = p['domain']['recommendations']
box['shown'] = {'at': 'x', 'fingerprint': box['fingerprint']}
s.record_scan(p, scan(['w3:p1', 'w3:p2']), '2026-10-31T10:10:00Z')
print(s.recommendations(p)['shown_current'], s.unshown(p))")"

it "no outside sessions means nothing to show"
check "False" "$(run_py "
p = {}
s.record_scan(p, scan([]), '2026-10-31T10:00:00Z')
print(s.unshown(p))")"

it "agent status changes do not move the domain fingerprint"
check "True" "$(run_py "
a = scan(['w3:p1']); b = scan(['w3:p1']); b['domain'][0]['agent_status'] = 'working'
print(s.domain_fingerprint(a) == s.domain_fingerprint(b))")"

it "a gone-folder pane moves the domain fingerprint"
check "False" "$(run_py "
print(s.domain_fingerprint(scan()) == s.domain_fingerprint(scan(gone=['w2:pR'])))")"

it "a pm behaviour with trigger domain is due once the domain has changed"
check "1" "$(run_py "
p = {}
s.record_scan(p, scan(['w3:p1']), '2026-10-31T10:00:00Z')
print(s.domain_due({'programme': p}, store=STORE)['total'])")"

it "answering it clears it until the domain changes again"
check "0 1" "$(run_py "
p = {}
s.record_scan(p, scan(['w3:p1']), '2026-10-31T10:00:00Z')
p['domain']['behaviour_deliveries'] = [{'id': 'b1', 'reason': 'applied_by_pm', 'at': '2026-10-31T10:01:00Z'}]
first = s.domain_due({'programme': p}, store=STORE)['total']
s.record_scan(p, scan(['w3:p1', 'w3:p2']), '2026-10-31T10:30:00Z')
print(first, s.domain_due({'programme': p}, store=STORE)['total'])")"

it "a workers-only behaviour is never due on the domain"
check "0" "$(run_py "
p = {}
s.record_scan(p, scan(['w3:p1']), '2026-10-31T10:00:00Z')
w = dict(ENTRY, applies_to='workers')
print(s.domain_due({'programme': p}, store=dict(STORE, personal=[w]))['total'])")"

it "with no scan recorded nothing is due"
check "0" "$(run_py "
print(s.domain_due({'programme': {}}, store=STORE)['total'])")"

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
