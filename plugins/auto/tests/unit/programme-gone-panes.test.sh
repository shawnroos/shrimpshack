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

echo "programme-gone-panes.test.sh"

WORK="$(mktemp -d -t auto-programme-gone.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export AUTO_TEST_HOST=stub
export AUTO_TEST_STUB_CLOSE_LOG="$WORK/closed.log"

run_py() {
  AUTO_LIB="${AUTO_ROOT}/lib" "$PY" -I -c "
import os, sys
sys.path.insert(0, os.environ['AUTO_LIB'])
from _bootstrap import load_lib_module
g = load_lib_module('programme_gone_panes')
th = load_lib_module('terminal_host')
merged_gates = lambda ref, repos: {'result': 'not_ready', 'gates': ['already merged'], 'pr': ref, 'ended': True}
closed_gates = lambda ref, repos: {'result': 'not_ready', 'gates': ['PR is CLOSED'], 'pr': ref, 'ended': True}
unknown = lambda ref, repos: {'result': 'unknown', 'gates': [], 'pr': ref, 'note': 'gh failed'}
def prog(result='pending', ref='o/r#7'):
    return {'items': {'issue:A': {'state': 'open', 'owner': {'pane': 'w2:pR'},
                                  'deliverables': {'merged': {'ref': ref, 'result': result}}}}}
def entry(status='idle', item='issue:A'):
    return {'pane': 'w2:pR', 'item': item, 'agent_status': status, 'why': 'folder_gone'}
$1
"
}

it "folder gone, merged PR on GitHub, idle agent: the pane is closed once"
: > "$WORK/closed.log"
check "closed $(printf 'w2:pR')" "$(run_py "
out = g.close_if_eligible({'programme': prog()}, entry(), check=merged_gates)
print(out['status'], open(os.environ['AUTO_TEST_STUB_CLOSE_LOG']).read().strip())")"

it "a done agent counts as idle"
check "closed" "$(run_py "
print(g.close_if_eligible({'programme': prog()}, entry('done'), check=merged_gates)['status'])")"

it "a working agent is reported and nothing is closed"
: > "$WORK/closed.log"
check "reported 0" "$(run_py "
out = g.close_if_eligible({'programme': prog()}, entry('working'), check=merged_gates)
print(out['status'], len(open(os.environ['AUTO_TEST_STUB_CLOSE_LOG']).read().split()))")"

it "an unknown agent state is reported, not closed"
check "reported" "$(run_py "
print(g.close_if_eligible({'programme': prog()}, entry('unknown'), check=merged_gates)['status'])")"

it "a pane that no item owns is reported, not closed"
check "reported" "$(run_py "
print(g.close_if_eligible({'programme': prog()}, entry(item=None), check=merged_gates)['status'])")"

it "a CLOSED but unmerged PR does not count as merged"
check "reported" "$(run_py "
print(g.close_if_eligible({'programme': prog()}, entry(), check=closed_gates)['status'])")"

it "an unreadable PR is reported, not closed"
check "reported" "$(run_py "
print(g.close_if_eligible({'programme': prog()}, entry(), check=unknown)['status'])")"

it "a confirmed merged deliverable needs no GitHub read"
check "closed" "$(run_py "
p = prog('confirmed'); p['items']['issue:A']['deliverables']['merged']['confirmed_at'] = '2026-10-30T00:00:00Z'
print(g.close_if_eligible({'programme': p}, entry(), check=unknown)['status'])")"

it "a host that refuses to close reports with the host's fix line"
check "reported True" "$(AUTO_TEST_STUB_CLOSE_LOG= run_py "
os.environ.pop('AUTO_TEST_STUB_CLOSE_LOG', None)
out = g.close_if_eligible({'programme': prog()}, entry(), check=merged_gates)
print(out['status'], bool(out.get('fix')))")"

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
