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

echo "programme-domain.test.sh"

WORK="$(mktemp -d -t auto-programme-domain.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/live"

run_py() {
  AUTO_LIB="${AUTO_ROOT}/lib" LIVE="$WORK/live" GONE="$WORK/gone-folder" "$PY" -I -c "
import os, sys, json
sys.path.insert(0, os.environ['AUTO_LIB'])
from _bootstrap import load_lib_module
d = load_lib_module('programme_domain')
live, gone = os.environ['LIVE'], os.environ['GONE']
$1
"
}

it "a pane whose cwd was deleted is folder_gone, a live cwd and a missing cwd are not"
check "True False False" "$(run_py "
print(d.folder_gone({'cwd': gone}), d.folder_gone({'cwd': live}), d.folder_gone({'cwd': None}))")"

it "waiting on Shawn sorts before working"
check "p1 p2" "$(run_py "
prog = {'items': {'issue:A': {'state': 'waiting', 'waiting_on': {'who': 'shawn'}, 'owner': {'pane': 'p1'}},
                  'issue:B': {'state': 'open', 'owner': {'pane': 'p2'}}}}
panes = [{'pane_id': 'p2', 'agent_status': 'working'}, {'pane_id': 'p1', 'agent_status': 'working'}]
print(' '.join(r['pane'] for r in d.order(prog, panes)))")"

it "unknown state sorts before working and a blocked agent sorts first"
check "p3 p2 p1" "$(run_py "
panes = [{'pane_id': 'p1', 'agent_status': 'working'}, {'pane_id': 'p2', 'agent_status': 'unknown'},
         {'pane_id': 'p3', 'agent_status': 'blocked'}]
print(' '.join(r['pane'] for r in d.order({'items': {}}, panes)))")"

it "a claimed merge sorts before idle, and idle before working"
check "p2 p3 p1" "$(run_py "
prog = {'items': {'issue:A': {'state': 'open', 'owner': {'pane': 'p2'},
                              'deliverables': {'merged': {'ref': 'o/r#1', 'result': 'pending'}}}}}
panes = [{'pane_id': 'p1', 'agent_status': 'working'}, {'pane_id': 'p2', 'agent_status': 'idle'},
         {'pane_id': 'p3', 'agent_status': 'idle'}]
print(' '.join(r['pane'] for r in d.order(prog, panes)))")"

it "a gone-folder pane that owns an item keeps that item in its entry"
check "issue:A folder_gone" "$(run_py "
prog = {'items': {'issue:A': {'state': 'open', 'owner': {'pane': 'p1'}}}}
e = d.gone_entry(prog, {'pane_id': 'p1', 'cwd': gone})
print(e['item'], e['why'])")"

it "a done agent ranks as idle, not working"
check "p2 p1" "$(run_py "
panes = [{'pane_id': 'p1', 'agent_status': 'working'}, {'pane_id': 'p2', 'agent_status': 'done'}]
print(' '.join(r['pane'] for r in d.order({'items': {}}, panes)))")"

SNAP_PY="
snap = {'panes': [
  {'pane_id': 'w2:p1', 'workspace_id': 'w2', 'tab_id': 't1', 'agent': 'claude', 'terminal_title': 'in remit'},
  {'pane_id': 'w3:p1', 'workspace_id': 'w3', 'tab_id': 't9', 'agent': 'claude', 'terminal_title': 'Peek tabs'},
  {'pane_id': 'w3:p2', 'workspace_id': 'w3', 'tab_id': 't9', 'terminal_title': 'plain shell'},
  {'pane_id': 'w3:p3', 'workspace_id': 'w3', 'tab_id': 't9', 'agent': 'claude', 'label': 'pm'}], 'agents': []}
scope = {'workspaces': ['w2'], 'tabs': None}
owner = lambda row, agent: {'session_id': None, 'source': None, 'name': None}
role = lambda pane: 'pm' if pane['label'] == 'pm' else 'worker'
"

it "an agent pane in another workspace is outside; remit, shell and PM panes are not"
check "w3:p1" "$(run_py "$SNAP_PY
print(' '.join(p['pane_id'] for p in d.outside_views(snap, scope, owner, role)))")"

it "a recommendation carries a one-line reason from the title"
check "Peek tabs" "$(run_py "$SNAP_PY
print(d.recommendation(d.outside_views(snap, scope, owner, role)[0])['reason'])")"

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
