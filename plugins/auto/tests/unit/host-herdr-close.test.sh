#!/usr/bin/env bash
# auto unit test: the herdr host closes a pane with `herdr pane close <pane>` and never reads a pane id as an option.
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

echo "host-herdr-close.test.sh"

WORK="$(mktemp -d -t auto-herdr-close.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
for v in $(env | grep -oE '^(HERDR|REX|GHOSTTY|AUTO_TEST)_[A-Z_]*'); do unset "$v"; done

FAKES="${WORK}/fakes"
mkdir -p "$FAKES"
export FAKE_HERDR_LOG="${WORK}/calls.log"
cat > "${FAKES}/herdr" <<'EOF'
#!/bin/bash
echo "$*" >> "$FAKE_HERDR_LOG"
[ -n "${FAKE_HERDR_FAIL:-}" ] && { echo "no such pane" >&2; exit 1; }
[ -n "${FAKE_HERDR_SLEEP:-}" ] && sleep "$FAKE_HERDR_SLEEP"
exit 0
EOF
chmod +x "${FAKES}/herdr"
export PATH="${FAKES}:${PATH}"

run_py() {
  AUTO_LIB="${AUTO_ROOT}/lib" "$PY" -I -c "
import os, sys
sys.path.insert(0, os.environ['AUTO_LIB'])
from _bootstrap import load_lib_module
hh = load_lib_module('host_herdr')
g = load_lib_module('programme_gone_panes')
host = hh.HerdrHost()
merged_gates = lambda ref, repos: {'result': 'not_ready', 'gates': ['already merged'], 'pr': ref, 'ended': True}
unmerged = lambda ref, repos: {'result': 'ready', 'gates': [], 'pr': ref}
def prog():
    return {'items': {'issue:A': {'state': 'open', 'owner': {'pane': 'w9:p1'},
                                  'deliverables': {'merged': {'ref': 'o/r#7', 'result': 'pending'}}}}}
def entry(status='idle', item='issue:A'):
    return {'pane': 'w9:p1', 'item': item, 'agent_status': status, 'terminal_id': 'T1', 'why': 'folder_gone'}
live = lambda pane_id: {'pane_id': pane_id, 'agent_status': 'idle', 'terminal_id': 'T1', 'cwd': '/nonexistent/gone'}
_close = g.close_if_eligible
g.close_if_eligible = lambda rec, ent, **kw: _close(rec, ent, **{'live': live, **kw})
$1
"
}
calls() { if [ -f "$FAKE_HERDR_LOG" ]; then cat "$FAKE_HERDR_LOG"; fi; }

it "close_pane runs exactly 'pane close <pane>' and returns ok"
: > "$FAKE_HERDR_LOG"
check "True w9:p1|pane close w9:p1" "$(run_py "r = host.close_pane('w9:p1'); print(r.ok, r.value['closed'], end='')")|$(calls)"

it "a failing herdr refuses with its failure text and claims nothing closed"
: > "$FAKE_HERDR_LOG"
check "False True False" "$(FAKE_HERDR_FAIL=1 run_py "r = host.close_pane('w9:p1'); print(r.ok, 'herdr pane close' in r.why, 'may have happened' in r.why)")"

it "a close that outlives the bound says it may have happened and to run P sweep"
: > "$FAKE_HERDR_LOG"
check "False True True" "$(FAKE_HERDR_SLEEP=3 CLAUDE_AUTO_SOURCE_TIMEOUT=1 run_py "
r = host.close_pane('w9:p1'); print(r.ok, 'the close may have happened' in r.why, 'run P sweep to confirm' in r.why)")"

for bad in "-x" "" "a b" "w1:p1;rm" '$(x)' $'w9:p1\n' "w９:p1" "." ".."; do
  it "pane id [$bad] is refused and herdr is never called"
  : > "$FAKE_HERDR_LOG"
  check "False|" "$(PANE_ARG="$bad" run_py "r = host.close_pane(os.environ['PANE_ARG']); print(r.ok, end='')")|$(calls)"
done

it "send_class gives 'pane close <pane>' no target, so a worker session is denied; is_host_command still names the pane"
check "('send', None) ('pane close', 'w9:p4')" "$(run_py "
print(host.send_class(['herdr','pane','close','w9:p4']), host.is_host_command(['herdr','pane','close','w9:p4']))")"

it "pane close --help is not read as a target"
check "('send', None)" "$(run_py "print(host.send_class(['herdr','pane','close','--help']), end='')")"

it "an eligible pane is closed through the herdr host"
: > "$FAKE_HERDR_LOG"
check "closed|pane close w9:p1" "$(run_py "
out = g.close_if_eligible({'programme': prog()}, entry(), check=merged_gates, host=host)
print(out['status'], end='')")|$(calls)"

it "a working agent is reported and herdr is not called"
: > "$FAKE_HERDR_LOG"
check "reported|" "$(run_py "print(g.close_if_eligible({'programme': prog()}, entry('working'), check=merged_gates, host=host)['status'], end='')")|$(calls)"

for status in None unknown Idle; do
  it "agent_status [$status] is reported and herdr is not called"
  : > "$FAKE_HERDR_LOG"
  check "reported|" "$(ST="$status" run_py "
st = None if os.environ['ST'] == 'None' else os.environ['ST']
print(g.close_if_eligible({'programme': prog()}, entry(st), check=merged_gates, host=host)['status'], end='')")|$(calls)"
done

it "an unmerged PR is reported and herdr is not called"
: > "$FAKE_HERDR_LOG"
check "reported|" "$(run_py "print(g.close_if_eligible({'programme': prog()}, entry(), check=unmerged, host=host)['status'], end='')")|$(calls)"

it "an entry with no item is reported and herdr is not called"
: > "$FAKE_HERDR_LOG"
check "reported|" "$(run_py "print(g.close_if_eligible({'programme': prog()}, entry(item=None), check=merged_gates, host=host)['status'], end='')")|$(calls)"

it "a host that refuses the close is reported with the reason and its fix"
: > "$FAKE_HERDR_LOG"
check "reported True True" "$(run_py "
class Refusing:
    def close_pane(self, pane):
        return load_lib_module('terminal_host').refuse('no close here', fix='close it by hand')
out = g.close_if_eligible({'programme': prog()}, entry(), check=merged_gates, host=Refusing())
print(out['status'], 'cannot close it: no close here' in out['why'], out.get('fix') == 'close it by hand', end='')")"

for case in "'working', 'T1', '/nonexistent/gone'" "'idle', 'T2', '/nonexistent/gone'" "'idle', 'T1', '/tmp'"; do
  it "a pane that is now [$case] is reported as changed and herdr is not called"
  : > "$FAKE_HERDR_LOG"
  check "reported|pane changed since the sweep|" "$(run_py "
st, term, cwd = ($case)
fresh = lambda pane_id: {'pane_id': pane_id, 'agent_status': st, 'terminal_id': term, 'cwd': cwd}
out = g.close_if_eligible({'programme': prog()}, entry(), check=merged_gates, host=host, live=fresh)
print(out['status'], out['why'], sep='|', end='')")|$(calls)"
done

it "a pane that is no longer listed is reported as changed and herdr is not called"
: > "$FAKE_HERDR_LOG"
check "reported|" "$(run_py "print(g.close_if_eligible({'programme': prog()}, entry(), check=merged_gates, host=host, live=lambda p: None)['status'], end='')")|$(calls)"

it "an entry recorded with no terminal id is reported, never closed"
: > "$FAKE_HERDR_LOG"
check "reported|" "$(run_py "
e = entry(); e['terminal_id'] = None
print(g.close_if_eligible({'programme': prog()}, e, check=merged_gates, host=host)['status'], end='')")|$(calls)"

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
