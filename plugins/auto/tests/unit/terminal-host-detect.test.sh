#!/usr/bin/env bash
# auto unit test: terminal host detection (KTD2), the SessionStart gate, and the process-chain tty (KTD12).
#
# detect() only SELECTS a host module from the environment; AUTO_TEST_HOST=stub is the one test-only
# selector and nothing in production sets it.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
HOOK="${AUTO_ROOT}/.claude/hooks/on-session-start.sh"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
check() { if [ "$1" = "$2" ]; then pass; else fail "expected [$1] got [$2]"; fi; }
has() { case "$2" in *"$1"*) pass ;; *) fail "expected to find [$1] in [$2]" ;; esac; }

echo "terminal-host-detect.test.sh"

WORK="$(mktemp -d -t auto-host-detect.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
EMPTY_BIN="${WORK}/empty-bin"
mkdir -p "$EMPTY_BIN"

# detect <KEY=VALUE>...: prints "<name> <announced>" or "REFUSED <fix>". No herdr on PATH unless the test adds one.
detect() {
  env -i PATH="${DETECT_PATH:-/usr/bin:/bin}" "$@" "$PY" - "$AUTO_ROOT" <<'PYEOF' 2>&1
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
th = load_lib_module("terminal_host")
d = th.detect(dict(os.environ))
print(f"REFUSED {d.fix}" if d.name is None else f"{d.name} {d.announced}")
PYEOF
}

it "HERDR_PANE_ID selects herdr"
check "herdr True" "$(detect HERDR_PANE_ID=w1:p1)"
it "HERDR_ENV alone selects herdr"
check "herdr True" "$(detect HERDR_ENV=1)"
it "REX_SESSION selects rex"
check "rex True" "$(detect REX_SESSION=abc)"
it "Ghostty is chosen when no multiplexer announced itself"
check "ghostty True" "$(detect TERM_PROGRAM=ghostty)"
it "Rex inside Ghostty resolves to Rex"
check "rex True" "$(detect TERM_PROGRAM=ghostty REX_SESSION=abc)"
it "herdr inside Ghostty resolves to herdr"
check "herdr True" "$(detect TERM_PROGRAM=ghostty HERDR_PANE_ID=w1:p1)"
it "a plain terminal announces nothing and falls back to herdr"
check "herdr False" "$(detect TERM_PROGRAM=Apple_Terminal)"

it "cmux is refused as unsupported, with a fix line"
has "cmux is not supported" "$(detect CMUX_WORKSPACE_ID=ws1)"
it "cmux with a herdr pane resolves to herdr (spinoff order: herdr first)"
check "herdr True" "$(detect CMUX_WORKSPACE_ID=ws1 HERDR_PANE_ID=w1:p1)"
it "cmux inside Ghostty is still refused"
has "REFUSED" "$(detect CMUX_WORKSPACE_ID=ws1 TERM_PROGRAM=ghostty)"

it "AUTO_TEST_HOST=stub selects the stub host"
check "stub True" "$(detect AUTO_TEST_HOST=stub)"
it "any other AUTO_TEST_HOST value selects nothing"
check "herdr False" "$(detect AUTO_TEST_HOST=rex)"

FAKE="${WORK}/fake-herdr"
mkdir -p "$FAKE"
printf '#!/bin/bash\n[ "$1 $2" = "status server" ] && { echo "status: running"; exit 0; }\nexit 1\n' > "${FAKE}/herdr"
chmod +x "${FAKE}/herdr"
it "Ghostty with a live herdr server and no HERDR_ENV resolves to herdr (same as spinoff)"
check "herdr True" "$(DETECT_PATH="${FAKE}:/usr/bin:/bin" detect TERM_PROGRAM=ghostty)"
printf '#!/bin/bash\necho "status: stopped"\n' > "${FAKE}/herdr"
it "Ghostty with the herdr server stopped stays Ghostty"
check "ghostty True" "$(DETECT_PATH="${FAKE}:/usr/bin:/bin" detect TERM_PROGRAM=ghostty)"

echo "terminal-host-detect: two announced hosts are told apart by proof (KTD1)"
export AUTO_ROOT
. "${AUTO_ROOT}/tests/helpers/host-fakes.sh"
BOTH_BIN="${WORK}/both-bin"; REXONLY_BIN="${WORK}/rexonly-bin"; CALLS_LOG="${WORK}/calls.log"
host_fake_install herdr "$BOTH_BIN"; host_fake_install rex "$BOTH_BIN"; host_fake_install rex "$REXONLY_BIN"
SID=session:01a18693-5b41-787b-af33-87750812e31e
BID=block:01a18693-5b44-7cdc-a847-3bcbb92a53ab
DEADSID=session:00000000-0000-0000-0000-000000000000
# both <bin-dir> <KEY=VALUE>...: "<name> | <why> | <fix>" for a session that announces two hosts.
both() {
  local bin="$1"; shift
  env -i PATH="${bin}:/usr/bin:/bin" CALLS="$CALLS_LOG" "$@" "$PY" - "$AUTO_ROOT" <<'PYEOF' 2>&1
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
th = load_lib_module("terminal_host")
d = th.detect(dict(os.environ))
print(f"{d.name} | {d.why} | {d.fix}")
PYEOF
}
H_LIVE=(HERDR_PANE_ID=w2:p10)
H_DEAD=(HERDR_PANE_ID=w9:p9)
R_LIVE=(REX_SESSION=$SID REX_BLOCK=$BID)
R_DEAD=(REX_SESSION=$DEADSID REX_BLOCK=$BID)

it "both announced, the herdr pane answers and Rex has no such session: herdr"
check "herdr" "$(both "$BOTH_BIN" "${H_LIVE[@]}" "${R_DEAD[@]}" | cut -d' ' -f1)"
it "both announced, Rex lists the block and the herdr pane is unknown: rex"
check "rex" "$(both "$BOTH_BIN" "${H_DEAD[@]}" "${R_LIVE[@]}" | cut -d' ' -f1)"
it "both announced inside Ghostty is decided by proof, not by the Ghostty rule"
check "herdr" "$(both "$BOTH_BIN" "${H_LIVE[@]}" "${R_DEAD[@]}" TERM_PROGRAM=ghostty | cut -d' ' -f1)"
it "both announced and no herdr command on PATH: Rex proves, so rex"
check "rex" "$(both "$REXONLY_BIN" "${H_LIVE[@]}" "${R_LIVE[@]}" | cut -d' ' -f1)"
it "an answer that fell back to the environment pane id is not proof"
OUT="$(both "$BOTH_BIN" "${H_DEAD[@]}" "${R_DEAD[@]}")"
has "None | " "$OUT"
it "neither proving says so and gives an env -u command that works from inside the session"
has "neither herdr nor Rex" "$OUT"; has "env -u" "$OUT"
it "both proving says both hold a pane and gives an env -u command"
OUT="$(both "$BOTH_BIN" "${H_LIVE[@]}" "${R_LIVE[@]}")"
has "None | " "$OUT"; has "both herdr and Rex prove" "$OUT"; has "env -u" "$OUT"
it "one announced host, or none, makes no call to either fake (R7)"
: > "$CALLS_LOG"
both "$BOTH_BIN" "${H_LIVE[@]}" >/dev/null; both "$BOTH_BIN" "${R_LIVE[@]}" >/dev/null; both "$BOTH_BIN" TERM_PROGRAM=Apple_Terminal >/dev/null
check "0" "$(wc -l < "$CALLS_LOG" | tr -d ' ')"
it "two detect calls in one process with a resolved host probe each host once"
: > "$CALLS_LOG"
OUT="$(env -i PATH="${BOTH_BIN}:/usr/bin:/bin" CALLS="$CALLS_LOG" "${H_LIVE[@]}" "${R_DEAD[@]}" "$PY" - "$AUTO_ROOT" <<'PYEOF' 2>&1
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
th = load_lib_module("terminal_host")
env = dict(os.environ)
print(th.detect(env).name, th.detect(env).name)
PYEOF
)"
check "herdr herdr" "$OUT"
check "2" "$(wc -l < "$CALLS_LOG" | tr -d ' ')"
it "a refusal is not memoised: a failing probe is retried and can then resolve"
OUT="$(env -i PATH="${BOTH_BIN}:/usr/bin:/bin" CALLS="$CALLS_LOG" "${H_LIVE[@]}" "${R_DEAD[@]}" HOST_FAKE_FORCE=pane-get-missing "$PY" - "$AUTO_ROOT" <<'PYEOF' 2>&1
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
th = load_lib_module("terminal_host")
env = dict(os.environ)
first = th.detect(env).name
os.environ.pop("HOST_FAKE_FORCE")
print(first, th.detect(env).name)
PYEOF
)"
check "None herdr" "$OUT"

echo "terminal-host-detect: a host that cannot run refuses with its capability-table fix line"
it "rex with no rex on PATH answers refuse for list_panes with the capability table fix"
OUT="$(env -i PATH=/usr/bin:/bin REX_SESSION=abc "$PY" - "$AUTO_ROOT" <<'PYEOF' 2>&1
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
th = load_lib_module("terminal_host")
r = th.current(dict(os.environ)).list_panes()
cell = th.capability_table()["list_panes"]["rex"]
print(r.status, r.fix == cell["fix"], "install Rex" in r.fix)
PYEOF
)"
check "refuse True True" "$OUT"
it "a refused detection makes every capability refuse with the detection's fix line"
OUT="$(env -i PATH=/usr/bin:/bin "$PY" - "$AUTO_ROOT" <<'PYEOF' 2>&1
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
th = load_lib_module("terminal_host")
r = th.current({"CMUX_WORKSPACE_ID": "x"}).send_prompt("p", "t")
print(r.status, "|", r.fix)
PYEOF
)"
has "refuse | run Claude from a herdr pane" "$OUT"

echo "terminal-host-detect: the SessionStart hook gate"
hook() { # hook <KEY=VALUE>... : the real hook from a dir with no repo and no lease
  ( cd "$WORK" && env -i PATH="${EMPTY_BIN}:/usr/bin:/bin" HOME="$WORK" CLAUDE_AUTO_PYTHON3="$PY" \
      CLAUDE_AUTO_TEST_HARNESS=1 CLAUDE_AUTO_DATA_DIR="$CLAUDE_AUTO_DATA_DIR" "$@" \
      bash "$HOOK" <<< '{"session_id":"s-hook","source":"startup","cwd":"/tmp"}' ) >/dev/null 2>&1
}
rows() { cat "${CLAUDE_AUTO_DATA_DIR}"/sessions/*.jsonl 2>/dev/null; }

rm -rf "${CLAUDE_AUTO_DATA_DIR}"
hook AUTO_TEST_HOST=stub AUTO_TEST_STUB_PANE=p1 AUTO_TEST_STUB_SERVER=srv AUTO_TEST_STUB_WORKSPACE=win AUTO_TEST_STUB_TAB=Work
it "a stub-host session start records a row with its host and tab space name"
ROW="$(rows)"
case "$ROW" in *'"host": "stub"'*'"tab_space_name": "Work"'*) pass ;; *) fail "$ROW" ;; esac
it "the stub row sits in a host-qualified file"
check "stub--srv--win.jsonl" "$(ls "${CLAUDE_AUTO_DATA_DIR}/sessions" | grep -v '^\.')"

rm -rf "${CLAUDE_AUTO_DATA_DIR}"
hook HERDR_PANE_ID=w1:p1 REX_SESSION=abc
it "two multiplexers announced: the hook records nothing"
if [ -z "$(rows)" ]; then pass; else fail "$(rows)"; fi

rm -rf "${CLAUDE_AUTO_DATA_DIR}"; : > "$CALLS_LOG"
hook PATH="${BOTH_BIN}:/usr/bin:/bin" CALLS="$CALLS_LOG" "${H_LIVE[@]}" "${R_DEAD[@]}"
it "both announced and only herdr proves: the hook records a herdr row"
case "$(rows)" in *'"pane_id": "w2:p10"'*) pass ;; *) fail "$(rows)" ;; esac
it "and asks herdr for the pane once, so the hook stays inside its timeout"
check "1" "$(grep -c '^herdr pane get' "$CALLS_LOG" | tr -d ' ')"

rm -rf "${CLAUDE_AUTO_DATA_DIR}"
hook PATH="${BOTH_BIN}:/usr/bin:/bin" "${H_LIVE[@]}" "${R_LIVE[@]}"
it "both announced and both prove: the hook records nothing"
if [ -z "$(rows)" ]; then pass; else fail "$(rows)"; fi

hook CMUX_WORKSPACE_ID=ws1
it "cmux: the hook records nothing"
if [ -z "$(rows)" ]; then pass; else fail "$(rows)"; fi

hook REX_SESSION=abc
it "rex has no host module yet: the hook records nothing and does not fail"
if [ -z "$(rows)" ]; then pass; else fail "$(rows)"; fi

echo "terminal-host-detect: the process-chain tty"
FAKEPS="${WORK}/ps-bin"
PSDIR="${WORK}/ps-rows"
mkdir -p "$FAKEPS" "$PSDIR"
cat > "${FAKEPS}/ps" <<'PSEOF'
#!/bin/bash
pid="${@: -1}"
[ -f "$PSDIR/$pid" ] || exit 1
cat "$PSDIR/$pid"
PSEOF
chmod +x "${FAKEPS}/ps"
tty_of() { # tty_of <start pid>
  PSDIR="$PSDIR" PATH="${FAKEPS}:/usr/bin:/bin" "$PY" - "$AUTO_ROOT" "$1" <<'PYEOF' 2>&1
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
print(load_lib_module("session_registry").process_tty(int(sys.argv[2])))
PYEOF
}
printf '3000 ?? /bin/sh\n'     > "$PSDIR/2000"
printf '1000 ttys042 claude\n' > "$PSDIR/3000"
it "the hook's own tty is ?? but the claude ancestor's tty is found"
check "/dev/ttys042" "$(tty_of 2000)"
printf '1000 ?? claude\n' > "$PSDIR/3000"
it "claude itself reading ?? is None, never a claimed tty"
check "None" "$(tty_of 2000)"
printf '1 ttys042 -zsh\n' > "$PSDIR/3000"
it "a chain with no claude process is None even if an ancestor has a tty"
check "None" "$(tty_of 2000)"
rm -f "$PSDIR/3000"
it "a chain ps cannot read is None"
check "None" "$(tty_of 2000)"
it "a missing ps is None"
check "None" "$(PATH="${EMPTY_BIN}" "$PY" - "$AUTO_ROOT" <<'PYEOF' 2>&1
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
print(load_lib_module("session_registry").process_tty(1234))
PYEOF
)"
it "the real chain from this shell reaches a tty path or None, never ??"
REAL="$("$PY" - "$AUTO_ROOT" <<'PYEOF' 2>&1
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
print(load_lib_module("session_registry").process_tty())
PYEOF
)"
case "$REAL" in None|/dev/*) pass ;; *) fail "got [$REAL]" ;; esac

echo
echo "terminal-host-detect.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
