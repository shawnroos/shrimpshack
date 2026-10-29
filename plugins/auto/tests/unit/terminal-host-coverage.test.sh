#!/usr/bin/env bash
# auto unit test: every terminal host answers every capability, and every host fake has a fixture.
#
# Fails on: an empty or missing capability cell, a degraded cell with no "how", a refuse cell
# with no fix line, an interface method with no capability row, a row no method serves, a host
# in the HOSTS enum missing from terminal_host_capabilities.json, and a host fake with no
# recorded fixture behind it (KTD10).
#
# Host-module-internal methods carry no row: is_host_command (its per-host test is required in
# the send-guard test), installed and report_session (herdr's SessionStart plumbing).
# The validator runs on synthetic tables too, so a green result proves it can fail.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
TABLE="${AUTO_ROOT}/lib/terminal_host_capabilities.json"
EXEMPT="is_host_command installed report_session"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
has() { case "$2" in *"$1"*) pass ;; *) fail "expected to find [$1] in [$2]" ;; esac; }

# validate <table.json> [extra-host...]: prints one line per defect, nothing when clean.
validate() {
  "$PY" - "$AUTO_ROOT/lib" "$1" "$EXEMPT" "${@:2}" <<'PYEOF'
import inspect, json, sys
lib, table_path, exempt = sys.argv[1], sys.argv[2], set(sys.argv[3].split())
sys.path.insert(0, lib)
from _bootstrap import load_lib_module
th = load_lib_module("terminal_host")
hosts = list(th.HOSTS) + sys.argv[4:]
doc = json.load(open(table_path))
caps = doc.get("capabilities") or {}
problems = []
for host in hosts:
    if host not in (doc.get("hosts") or []):
        problems.append(f"host {host}: missing from the hosts list in the capability table")
for cap, row in caps.items():
    for host in hosts:
        cell = row.get(host)
        if not isinstance(cell, dict) or not cell:
            problems.append(f"host {host}, capability {cap}: empty or missing cell")
            continue
        status = cell.get("status")
        if status not in th.STATUSES:
            problems.append(f"host {host}, capability {cap}: status {status!r} is not native, degraded or refuse")
        elif status in ("native", "degraded") and not str(cell.get("how") or "").strip():
            problems.append(f"host {host}, capability {cap}: {status} cell has no how")
        elif status == "refuse" and not str(cell.get("fix") or "").strip():
            problems.append(f"host {host}, capability {cap}: refuse cell has no fix line")
served = set()
classes = [th.TerminalHost]
for mod_name in sorted(n[:-3] for n in __import__("os").listdir(lib) if n.startswith("host_") and n.endswith(".py")):
    mod = load_lib_module(mod_name)
    classes += [c for _, c in inspect.getmembers(mod, inspect.isclass) if issubclass(c, th.TerminalHost) and c is not th.TerminalHost]
for cls in classes:
    for name, fn in inspect.getmembers(cls, inspect.isfunction):
        if name.startswith("_") or name in exempt:
            continue
        row = th.CAPABILITY_OF.get(name)
        if row is None:
            problems.append(f"method {cls.__name__}.{name}: no capability row (map it in CAPABILITY_OF or exempt it)")
        elif row not in caps:
            problems.append(f"method {cls.__name__}.{name}: capability row {row} is not in the table")
        else:
            served.add(row)
for cap in caps:
    if cap not in served:
        problems.append(f"capability {cap}: no interface method serves this row")
print("\n".join(problems))
PYEOF
}

mutate() { # mutate <out> <python statement over d>
  "$PY" - "$TABLE" "$1" "$2" <<'PYEOF'
import json, sys
src, out, stmt = sys.argv[1:4]
d = json.load(open(src))
exec(stmt)
json.dump(d, open(out, "w"))
PYEOF
}

echo "terminal-host-coverage: the shipped table"
it "the shipped table has no defect"
OUT="$(validate "$TABLE")"
if [ -z "$OUT" ]; then pass; else fail "$OUT"; fi

it "anti-vacuity: the table has at least 8 capabilities and 3 hosts"
COUNTS="$("$PY" -c 'import json,sys; d=json.load(open(sys.argv[1])); print(len(d["capabilities"]), len(d["hosts"]))' "$TABLE")"
if [ "${COUNTS% *}" -ge 8 ] && [ "${COUNTS#* }" -ge 3 ]; then pass; else fail "saw [$COUNTS]"; fi

echo "terminal-host-coverage: the validator can fail (synthetic tables)"
it "an empty cell names the host and the capability"
mutate "$WORK/t1.json" 'del d["capabilities"]["notify"]["rex"]'
has "host rex, capability notify: empty or missing cell" "$(validate "$WORK/t1.json")"

it "an empty object cell is empty too"
mutate "$WORK/t1b.json" 'd["capabilities"]["notify"]["ghostty"] = {}'
has "host ghostty, capability notify: empty or missing cell" "$(validate "$WORK/t1b.json")"

it "a degraded cell without how fails"
mutate "$WORK/t2.json" 'd["capabilities"]["presence"]["ghostty"] = {"status": "degraded"}'
has "host ghostty, capability presence: degraded cell has no how" "$(validate "$WORK/t2.json")"

it "a refuse cell without a fix line fails"
mutate "$WORK/t3.json" 'd["capabilities"]["send_prompt"]["rex"] = {"status": "refuse", "why": "x"}'
has "host rex, capability send_prompt: refuse cell has no fix line" "$(validate "$WORK/t3.json")"

it "an unknown status fails"
mutate "$WORK/t3b.json" 'd["capabilities"]["send_prompt"]["rex"] = {"status": "maybe", "how": "x"}'
has "host rex, capability send_prompt: status 'maybe'" "$(validate "$WORK/t3b.json")"

it "a host in the HOSTS enum but absent from the table fails"
has "host zed: missing from the hosts list" "$(validate "$TABLE" zed)"

it "a new host has an empty cell in every row"
has "host zed, capability find_own_pane: empty or missing cell" "$(validate "$TABLE" zed)"

it "a capability row with no interface method fails"
mutate "$WORK/t4.json" 'd["capabilities"]["teleport"] = {h: {"status": "native", "how": "x"} for h in d["hosts"]}'
has "capability teleport: no interface method serves this row" "$(validate "$WORK/t4.json")"

it "a row that CAPABILITY_OF points at but the table lacks fails"
mutate "$WORK/t5.json" 'del d["capabilities"]["list_panes"]'
has "capability row list_panes is not in the table" "$(validate "$WORK/t5.json")"

echo "terminal-host-coverage: every host has a fake backed by recorded output"
. "${AUTO_ROOT}/tests/helpers/host-fakes.sh"
HOSTS_LIST="$("$PY" -c 'import sys; sys.path.insert(0, sys.argv[1]); from _bootstrap import load_lib_module; print(*load_lib_module("terminal_host").HOSTS)' "$AUTO_ROOT/lib")"

fake_defects() { # fake_defects <fixture-root> <host>...: one line per defect
  local root="$1" host bin scen d
  shift
  for host in "$@"; do
    bin="$(HOST_FAKE_ROOT="$root" host_fake_binary "$host")" || { echo "host ${host}: no fake registered in host-fakes.sh"; continue; }
    if [ -z "$(HOST_FAKE_ROOT="$root" host_fake_scenarios "$host" 2>/dev/null)" ]; then
      echo "host ${host}: fake ${bin} has no fixture under ${root}/${host}"
      continue
    fi
    for d in "${root}/${host}"/*/; do
      for f in match rc stdout stderr; do
        [ -f "${d}${f}" ] || echo "host ${host}: fixture $(basename "$d") lacks ${f}"
      done
    done
  done
}

it "every HOSTS entry plus the stub host has a fake with fixtures"
OUT="$(fake_defects "$HOST_FAKE_ROOT" $HOSTS_LIST stub)"
if [ -z "$OUT" ]; then pass; else fail "$OUT"; fi

it "anti-vacuity: the fixture tree holds at least 12 scenarios"
N=$(find "$HOST_FAKE_ROOT" -name match | wc -l | tr -d ' ')
if [ "$N" -ge 12 ]; then pass; else fail "saw ${N}"; fi

it "a fake with no backing fixture fails (KTD10 control)"
mkdir -p "$WORK/fx/herdr/one" "$WORK/fx/rex"
for f in match rc stdout stderr; do : > "$WORK/fx/herdr/one/$f"; done
has "host rex: fake rex has no fixture" "$(fake_defects "$WORK/fx" herdr rex)"

it "a host with no fake registered fails"
has "host zed: no fake registered" "$(fake_defects "$HOST_FAKE_ROOT" zed)"

it "a fixture missing a file fails"
rm "$WORK/fx/herdr/one/rc"
has "fixture one lacks rc" "$(fake_defects "$WORK/fx" herdr)"

echo "terminal-host-coverage: each fake replays its recorded output"
BIN="$WORK/bin"
for host in $HOSTS_LIST stub; do
  host_fake_install "$host" "$BIN" || fail "cannot install the ${host} fake"
done
it "herdr fake replays status server stdout"
check_eq() { if [ "$1" = "$2" ]; then pass; else fail "expected [$1] got [$2]"; fi; }
check_eq "$(cat "$HOST_FAKE_ROOT/herdr/status-server-running/stdout")" "$("$BIN/herdr" status server)"
it "herdr fake replays the server-down refusal when forced"
OUT="$(HOST_FAKE_FORCE=server-down "$BIN/herdr" status server 2>&1)"; RC=$?
check_eq "1:herdr: server not running" "${RC}:${OUT}"
it "rex fake replays the longest matching prefix (session ls --json)"
check_eq "$(cat "$HOST_FAKE_ROOT/rex/session-ls-json-empty/stdout")" "$("$BIN/rex" session ls --json)"
it "rex fake replays a refusal exit code"
"$BIN/rex" session inspect nosuch >/dev/null 2>&1; check_eq "3" "$?"
it "ghostty fake (osascript) replays the Automation denial"
OUT="$(HOST_FAKE_FORCE=automation-denied "$BIN/osascript" -e 'tell application "Ghostty" to get id of every terminal' 2>&1)"
has "Not authorized to send Apple events to Ghostty. (-1743)" "$OUT"
it "an unmatched call fails loudly with exit 99"
"$BIN/stubhost" nonsense >/dev/null 2>&1; check_eq "99" "$?"
it "the stub fake answers ping"
check_eq "pong" "$("$BIN/stubhost" ping)"

echo ""
echo "terminal-host-coverage.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
