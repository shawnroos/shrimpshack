#!/usr/bin/env bash
# auto unit test: registry rows and leases are keyed by terminal host (KTD5, R3, R8, R9, R19).
#
# Uses the test-only stub host (AUTO_TEST_HOST=stub) to exercise host-qualified state without Rex or Ghostty.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
PROG="${AUTO_ROOT}/lib/programme.py"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
check() { if [ "$1" = "$2" ]; then pass; else fail "expected [$1] got [$2]"; fi; }
has() { case "$2" in *"$1"*) pass ;; *) fail "expected to find [$1] in [$2]" ;; esac; }
lacks() { case "$2" in *"$1"*) fail "did not expect [$1] in [$2]" ;; *) pass ;; esac; }

echo "host-keyed-registry.test.sh"

WORK="$(mktemp -d -t auto-host-keyed.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

for v in $(env | grep -oE '^(HERDR|REX|AUTO_TEST)_[A-Z_]*'); do unset "$v"; done
unset CMUX_WORKSPACE_ID TERM_PROGRAM CLAUDE_CODE_SESSION_ID CLAUDE_CODE_ENTRYPOINT CLAUDE_AUTO_REPO 2>/dev/null || true
export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_TEST_HARNESS=1
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
: > "$CLAUDE_AUTO_SECRETS_FILE"
LEASES="${CLAUDE_AUTO_DATA_DIR}/programmes/leases"
SESSIONS="${CLAUDE_AUTO_DATA_DIR}/sessions"

py() { "$PY" - "$AUTO_ROOT" "$@" 2>&1; }
HEAD_PY='import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
ph = load_lib_module("programme_home")
sr = load_lib_module("session_registry")
args = sys.argv[2:]
'

# record <sid> <pane> <server> <workspace> <tab> <tty>: a stub-host SessionStart, then prints the row's key facts.
record() {
  AUTO_TEST_HOST=stub AUTO_TEST_STUB_PANE="$2" AUTO_TEST_STUB_SERVER="$3" AUTO_TEST_STUB_WORKSPACE="$4" \
    AUTO_TEST_STUB_TAB="$5" py "$1" "$6" <<PYEOF
$HEAD_PY
row = sr.record_session({"session_id": args[0], "source": "startup", "cwd": "/tmp"}, dict(os.environ), args[1] or None)
print(json.dumps({k: row.get(k) for k in ("host", "tty", "tab_space_name", "resolved", "server", "workspace")}, sort_keys=True))
PYEOF
}

echo "host-keyed-registry: a stub-host session"
OUT="$(record sess-a pane-a srv win-1 Work /dev/ttys003)"
it "the row carries host, tty, tab space name and resolved = the host"
check '{"host": "stub", "resolved": "stub", "server": "srv", "tab_space_name": "Work", "tty": "/dev/ttys003", "workspace": "win-1"}' "$OUT"
it "the registry file is host-qualified and no tty path reaches a file name"
check "stub--srv--win-1.jsonl" "$(ls "$SESSIONS" | grep -v '^\.')"

it "a session with no tty gets no tty field, never an empty one"
OUT="$(record sess-b pane-b srv win-2 Work "")"
check '{"host": "stub", "resolved": "stub", "server": "srv", "tab_space_name": "Work", "tty": null, "workspace": "win-2"}' "$OUT"

it "a host id with a slash or dot is refused rather than written into a file name"
OUT="$(py <<PYEOF
$HEAD_PY
for bad in ("/dev/ttys003", "a.b", "a--b", ""):
    try:
        ph.space_key(bad, "w", "rex")
        print("ACCEPTED", bad)
    except ph.ProgrammeHomeError:
        pass
print("done")
PYEOF
)"
check "done" "$OUT"

it "an unknown host is refused"
OUT="$(py <<PYEOF
$HEAD_PY
try:
    ph.space_key("a", "b", "nosuchhost")
    print("ACCEPTED")
except ph.ProgrammeHomeError:
    print("refused")
PYEOF
)"
check "refused" "$OUT"

it "the stub host cannot key a space unless AUTO_TEST_HOST selects it"
OUT="$(py <<PYEOF
$HEAD_PY
try:
    ph.space_key("a", "b", "stub")
    print("ACCEPTED")
except ph.ProgrammeHomeError:
    print("refused")
PYEOF
)"
check "refused" "$OUT"

echo "host-keyed-registry: leases"
it "a stub-host programme writes a host-qualified lease that records its host"
OUT="$(AUTO_TEST_HOST=stub py <<PYEOF
$HEAD_PY
made = ph.create_programme([("srv", "win-1", "stub")], "pm-stub")
print(made["leases"])
lease = json.load(open(os.path.join(ph.leases_dir(), "stub--srv--win-1.json")))
print(lease.get("host"), lease["server"], lease["workspace"])
PYEOF
)"
check "['stub--srv--win-1']
stub srv win-1" "$OUT"

it "a herdr programme keeps its lease file name and writes no host field"
OUT="$(py <<PYEOF
$HEAD_PY
made = ph.create_programme(["w1"], "pm-herdr")
print(made["leases"])
lease = json.load(open(os.path.join(ph.leases_dir(), "default.w1.json")))
print("host" in lease)
PYEOF
)"
check "['default.w1']
False" "$OUT"

it "a herdr registry file keeps its name and a herdr row has no key a downgrade could not read"
OUT="$(py <<PYEOF
$HEAD_PY
print(os.path.basename(sr.registry_path("default", "w1")), os.path.basename(sr.registry_path("default", "w1", "herdr")))
PYEOF
)"
check "default.w1.jsonl default.w1.jsonl" "$OUT"

it "the lease listing keeps the two hosts apart"
check "default.w1.json stub--srv--win-1.json" "$(ls "$LEASES" | grep -v '^\.' | tr '\n' ' ' | sed 's/ $//')"

it "a remit entry for a non-herdr space carries its host; a herdr entry does not"
OUT="$(py <<PYEOF
$HEAD_PY
print(json.dumps([ph.remit_entry("w9"), ph.remit_entry("rex--s1--w1")], sort_keys=True))
PYEOF
)"
check '[{"server": "default", "workspace": "w9"}, {"host": "rex", "server": "s1", "workspace": "w1"}]' "$OUT"

echo "host-keyed-registry: old records read as herdr"
mkdir -p "$SESSIONS"
printf '%s\n' '{"at":"2026-01-01T00:00:00Z","session_id":"sess-old","pane_id":"w3:p1","server":"default","workspace":"w3","interactive":true,"resolved":"herdr"}' > "${SESSIONS}/default.w3.jsonl"
it "a row with no host reads as herdr and resolves to a two-part space"
OUT="$(py <<PYEOF
$HEAD_PY
row = sr.lookup("sess-old")
print(sr.host_of_row(row), sr.space_of_session("sess-old"))
PYEOF
)"
check "herdr ('default', 'w3')" "$OUT"

it "a lease with no host reads as herdr"
OUT="$(py <<PYEOF
$HEAD_PY
print(ph.space_parts({"server": "default", "workspace": "w1"}), ph.lease_path_of({"server": "default", "workspace": "w1"}).endswith("/default.w1.json"))
PYEOF
)"
check "('default', 'w1', 'herdr') True" "$OUT"

it "an item id with a host prefix is not issue-backed; a tracker id is"
OUT="$(py <<PYEOF
$HEAD_PY
rec = load_lib_module("programme_record")
print([rec._issue_backed(i) for i in ("herdr:w1/p1", "rex:s/b", "ghostty:w/t", "linear:WEB-1")], sorted(rec.ISSUELESS_SOURCES))
PYEOF
)"
check "[False, False, False, True] ['ghostty', 'herdr', 'rex']" "$OUT"

echo "host-keyed-registry: space identity (R9)"
record sess-t1 pane-t1 srv win-t1 Shared /dev/ttys010 >/dev/null
record sess-t2 pane-t2 srv win-t2 Shared /dev/ttys011 >/dev/null
it "two sessions sharing a tab space name on different tty are two spaces"
OUT="$(py <<PYEOF
$HEAD_PY
a, b = sr.space_of_session("sess-t1"), sr.space_of_session("sess-t2")
print(a, b, a != b)
PYEOF
)"
check "('srv', 'win-t1', 'stub') ('srv', 'win-t2', 'stub') True" "$OUT"
it "each of them has its own registry file"
check "2" "$(ls "$SESSIONS" | grep -c 'stub--srv--win-t')"

AUTO_TEST_HOST=stub py <<PYEOF >/dev/null
$HEAD_PY
ph.create_programme([("srv", "win-lease", "stub")], "pm-lease")
PYEOF
RUN="$(AUTO_TEST_HOST=stub py <<PYEOF
$HEAD_PY
print([l["run"] for k, l in ph.iter_leases() if k == "stub--srv--win-lease"][0])
PYEOF
)"
record sess-label pane-l srv win-other win-lease /dev/ttys020 >/dev/null
it "a session whose tab space name equals the leased space's id is not in that space"
OUT="$(AUTO_TEST_HOST=stub py "$RUN" <<PYEOF
$HEAD_PY
life = load_lib_module("programme_lifecycle")
print(life._in_space(args[0], "sess-label"))
PYEOF
)"
check "False" "$OUT"
record sess-member pane-m srv win-lease Other /dev/ttys021 >/dev/null
it "a session whose registry row sits in the leased space is in it (anti-vacuity)"
OUT="$(AUTO_TEST_HOST=stub py "$RUN" <<PYEOF
$HEAD_PY
life = load_lib_module("programme_lifecycle")
print(life._in_space(args[0], "sess-member"))
PYEOF
)"
check "True" "$OUT"
it "a session with no row and only the tab name in its environment has no space"
OUT="$(py <<PYEOF
$HEAD_PY
print(sr.space_of_session("sess-nobody"))
PYEOF
)"
check "None" "$OUT"

echo "host-keyed-registry: one host per space (R3, AE5)"
REXRUN="$(py <<PYEOF
$HEAD_PY
print(ph.create_programme([("rexsess", "rexwin", "rex")], "pm-rex")["run"])
PYEOF
)"
it "the rex lease is host-qualified"
check "rex--rexsess--rexwin.json" "$(ls "$LEASES" | grep '^rex')"
py <<PYEOF >/dev/null
$HEAD_PY
sr._append(sr.registry_path("gsrv", "gwin", "ghostty"), {"at": load_lib_module("run_record_core").now_iso(),
    "session_id": "sess-ghostty", "pane_id": "t1", "server": "gsrv", "workspace": "gwin", "interactive": True,
    "host": "ghostty", "resolved": "ghostty"})
PYEOF
as() { local sid="$1"; shift; OUT="$(CLAUDE_CODE_SESSION_ID="$sid" "$PY" "$PROG" "$@" 2>&1)"; CODE=$?; }
as sess-ghostty start --space rex--rexsess--rexwin
it "a Ghostty session starting a worker in the Rex space is refused"
if [ "$CODE" -ne 0 ]; then pass; else fail "exit $CODE: $OUT"; fi
it "the refusal says why and carries a fix line"
case "$OUT" in *"runs in ghostty"*"rex space"*fix*) pass ;; *) fail "$OUT" ;; esac
it "the refused start changed nothing: no ghostty lease and the rex lease is intact"
check "rex--rexsess--rexwin.json" "$(ls "$LEASES" | grep -E '^(rex|ghostty)')"
as sess-ghostty takeover --run "$REXRUN"
it "a Ghostty session taking over the Rex programme is refused with a fix line"
case "$OUT" in *"runs in ghostty"*fix*) pass ;; *) fail "exit $CODE: $OUT" ;; esac
as sess-ghostty become-pm
it "a Ghostty session with no space of its own cannot become-pm in a rex space"
if [ "$CODE" -ne 0 ] || [ -z "$(ls "$LEASES" | grep ghostty)" ]; then pass; else fail "$OUT"; fi

echo "host-keyed-registry: start refuses when the environment announces two multiplexers"
as() { local sid="$1"; shift; OUT="$(CLAUDE_CODE_SESSION_ID="$sid" HERDR_PANE_ID=w5:p1 HERDR_WORKSPACE_ID=w5 REX_SESSION=abc "$PY" "$PROG" "$@" 2>&1)"; CODE=$?; }
BEFORE="$(ls "$LEASES" | tr '\n' ' ')"
as sess-new-two start
it "start with both herdr and Rex announced refuses with a fix line"
case "$OUT" in *"both herdr and Rex"*"one multiplexer only"*) pass ;; *) fail "exit $CODE: $OUT" ;; esac
it "and writes no lease"
check "$BEFORE" "$(ls "$LEASES" | tr '\n' ' ')"
as() { local sid="$1"; shift; OUT="$(CLAUDE_CODE_SESSION_ID="$sid" CMUX_WORKSPACE_ID=ws1 "$PY" "$PROG" "$@" 2>&1)"; CODE=$?; }
as sess-cmux start
it "start under cmux is refused as unsupported"
case "$OUT" in *"cmux is not supported"*) pass ;; *) fail "exit $CODE: $OUT" ;; esac

echo
echo "host-keyed-registry.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
