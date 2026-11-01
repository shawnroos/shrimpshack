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
def entry(status='idle'):
    return {'pane': 'w9:p1', 'item': 'issue:A', 'agent_status': status, 'why': 'folder_gone'}
$1
"
}
calls() { if [ -f "$FAKE_HERDR_LOG" ]; then cat "$FAKE_HERDR_LOG"; fi; }

it "close_pane runs exactly 'pane close <pane>' and returns ok"
: > "$FAKE_HERDR_LOG"
check "True w9:p1|pane close w9:p1" "$(run_py "r = host.close_pane('w9:p1'); print(r.ok, r.value['closed'], end='')")|$(calls)"

it "a failing herdr refuses with its failure text and claims nothing closed"
: > "$FAKE_HERDR_LOG"
check "False True" "$(FAKE_HERDR_FAIL=1 run_py "r = host.close_pane('w9:p1'); print(r.ok, 'herdr pane close' in r.why)")"

for bad in "-x" "" "a b" "w1:p1;rm" '$(x)'; do
  it "pane id [$bad] is refused and herdr is never called"
  : > "$FAKE_HERDR_LOG"
  check "False|" "$(PANE_ARG="$bad" run_py "r = host.close_pane(os.environ['PANE_ARG']); print(r.ok, end='')")|$(calls)"
done

it "send_class and is_host_command class 'pane close <pane>' as a send aimed at that pane"
check "('send', ['w1:pV']) ('pane close', 'w1:pV')" "$(run_py "
print(host.send_class(['herdr','pane','close','w1:pV']), host.is_host_command(['herdr','pane','close','w1:pV']))")"

it "pane close --help is not read as a target"
check "('send', None)" "$(run_py "print(host.send_class(['herdr','pane','close','--help']), end='')")"

it "close-gone-pane path: eligible pane is closed through the herdr host, journal status is gone_pane_closed"
: > "$FAKE_HERDR_LOG"
check "closed gone_pane_closed|pane close w9:p1" "$(run_py "
out = g.close_if_eligible({'programme': prog()}, entry(), check=merged_gates, host=host)
print(out['status'], 'gone_pane_' + out['status'], end='')")|$(calls)"

it "a working agent is reported and herdr is not called"
: > "$FAKE_HERDR_LOG"
check "reported|" "$(run_py "print(g.close_if_eligible({'programme': prog()}, entry('working'), check=merged_gates, host=host)['status'], end='')")|$(calls)"

it "an unmerged PR is reported and herdr is not called"
: > "$FAKE_HERDR_LOG"
check "reported|" "$(run_py "print(g.close_if_eligible({'programme': prog()}, entry(), check=unmerged, host=host)['status'], end='')")|$(calls)"

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
