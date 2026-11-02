#!/usr/bin/env bash
# auto unit test: a session that announces both herdr and Rex keeps a host when its herdr pane id is stale or missing.
#
# Ladder under test: live proof, then exactly one announced host installed, then this session's registry row, then refuse.

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
has() { case "$2" in *"$1"*) pass ;; *) fail "expected to find [$1] in [$2]" ;; esac; }

echo "host-stale-pane.test.sh"

WORK="$(mktemp -d -t auto-host-stale.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export AUTO_ROOT
. "${AUTO_ROOT}/tests/helpers/host-fakes.sh"

BOTH_BIN="${WORK}/both-bin"; HERDRONLY_BIN="${WORK}/herdronly-bin"; CALLS_LOG="${WORK}/calls.log"
host_fake_install herdr "$BOTH_BIN"; host_fake_install rex "$BOTH_BIN"; host_fake_install herdr "$HERDRONLY_BIN"
SID=session:01a18693-5b41-787b-af33-87750812e31e
BID=block:01a18693-5b44-7cdc-a847-3bcbb92a53ab
MINE=11111111-2222-3333-4444-555555555555
STRANGER=99999999-0000-0000-0000-000000000000
H_STALE=(HERDR_PANE_ID=w9:p9 HERDR_ENV=1)
H_ENVONLY=(HERDR_ENV=1)
R_DEAD=(REX_SESSION=session:00000000-0000-0000-0000-000000000000 REX_BLOCK=$BID)
R_LIVE=(REX_SESSION=$SID REX_BLOCK=$BID)

# both <bin-dir> <KEY=VALUE>...: "<name> | <why> | <fix>"
both() {
  local bin="$1"; shift
  env -i PATH="${bin}:/usr/bin:/bin" CALLS="$CALLS_LOG" CLAUDE_AUTO_DATA_DIR="$CLAUDE_AUTO_DATA_DIR" "$@" "$PY" - "$AUTO_ROOT" <<'PYEOF' 2>&1
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
th = load_lib_module("terminal_host")
d = th.detect(dict(os.environ))
print(f"{d.name} | {d.why} | {d.fix}")
PYEOF
}
row() { # row <session id> <host> <interactive true|false> [env pane]: a herdr row keeps the stale env pane id, a rex row its block id
  local pane="w2:pCM" env_pane="${4:-w9:p9}"
  [ "$2" = rex ] && { pane="$BID"; env_pane="$BID"; }
  mkdir -p "${CLAUDE_AUTO_DATA_DIR}/sessions"
  printf '{"at":"2026-11-02T16:09:40Z","session_id":"%s","pane_id":"%s","env_pane":"%s","terminal_id":"term_x","server":"default","workspace":"w2","interactive":%s,"resolved":"%s","host":"%s"}\n' \
    "$1" "$pane" "$env_pane" "$3" "$2" "$2" >> "${CLAUDE_AUTO_DATA_DIR}/sessions/default.w2.jsonl"
}
name() { printf '%s' "$1" | cut -d' ' -f1; }

it "stale herdr pane id plus Rex settings, no rex command: herdr"
check "herdr" "$(name "$(both "$HERDRONLY_BIN" "${H_STALE[@]}" "${R_LIVE[@]}")")"
it "HERDR_ENV alone plus Rex settings, no rex command: herdr"
check "herdr" "$(name "$(both "$HERDRONLY_BIN" "${H_ENVONLY[@]}" "${R_LIVE[@]}")")"
it "both commands installed and no registry row: refused, and the text says what was missing"
OUT="$(both "$BOTH_BIN" "${H_STALE[@]}" "${R_DEAD[@]}" CLAUDE_CODE_SESSION_ID=$MINE)"
has "None | " "$OUT"; has "registry" "$OUT"

row "$MINE" herdr true
it "both installed, stale pane, this session's row says herdr: herdr"
check "herdr" "$(name "$(both "$BOTH_BIN" "${H_STALE[@]}" "${R_DEAD[@]}" CLAUDE_CODE_SESSION_ID=$MINE)")"
it "both installed, HERDR_ENV only, this session's row says herdr: herdr"
check "herdr" "$(name "$(both "$BOTH_BIN" "${H_ENVONLY[@]}" "${R_DEAD[@]}" CLAUDE_CODE_SESSION_ID=$MINE)")"
it "a row for another session does not decide"
has "None | " "$(both "$BOTH_BIN" "${H_STALE[@]}" "${R_DEAD[@]}" CLAUDE_CODE_SESSION_ID=$STRANGER)"
it "no session id in the environment does not decide"
has "None | " "$(both "$BOTH_BIN" "${H_STALE[@]}" "${R_DEAD[@]}")"

HEADLESS=22222222-3333-4444-5555-666666666666
row "$HEADLESS" herdr false
it "a headless row does not decide"
has "None | " "$(both "$BOTH_BIN" "${H_STALE[@]}" "${R_DEAD[@]}" CLAUDE_CODE_SESSION_ID=$HEADLESS)"

REXROW=33333333-4444-5555-6666-777777777777
row "$REXROW" rex true
it "a row that names rex selects rex"
check "rex" "$(name "$(both "$BOTH_BIN" "${H_STALE[@]}" "${R_DEAD[@]}" CLAUDE_CODE_SESSION_ID=$REXROW)")"

it "a row naming a host whose command is not installed loses to the installed one"
check "herdr" "$(name "$(both "$HERDRONLY_BIN" "${H_STALE[@]}" "${R_DEAD[@]}" CLAUDE_CODE_SESSION_ID=$REXROW)")"

RESUMED=44444444-5555-6666-7777-888888888888
row "$RESUMED" herdr true w1:p1
it "a resumed session whose row was written under a different pane variable does not decide"
has "None | " "$(both "$BOTH_BIN" "${H_STALE[@]}" "${R_DEAD[@]}" CLAUDE_CODE_SESSION_ID=$RESUMED)"

# fallback_py <KEY=VALUE>...: runs detect with lookup replaced by one that raises, then record_session on a fallback pick
fallback_py() {
  env -i PATH="${HERDRONLY_BIN}:/usr/bin:/bin" CLAUDE_AUTO_DATA_DIR="$CLAUDE_AUTO_DATA_DIR" "$@" "$PY" - "$AUTO_ROOT" <<'PYEOF' 2>&1
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
th = load_lib_module("terminal_host")
sr = load_lib_module("session_registry")
found = th.detect(dict(os.environ))
print("picked", found.name, found.rung)
print("recorded", sr.record_session({"session_id": "55555555-0000-0000-0000-000000000000"}, dict(os.environ)))
PYEOF
}
it "a host picked by a fallback records no registry row, so a stale pane id is never stored"
OUT="$(fallback_py "${H_STALE[@]}" "${R_LIVE[@]}")"
has "picked herdr only announced host installed" "$OUT"; has "recorded None" "$OUT"
it "and the registry file has no row for that session"
check "0" "$(grep -c 55555555 "${CLAUDE_AUTO_DATA_DIR}"/sessions/*.jsonl | awk -F: '{s+=$2} END {print s+0}')"

it "a registry lookup that raises falls through to refuse"
OUT="$(env -i PATH="${BOTH_BIN}:/usr/bin:/bin" CLAUDE_AUTO_DATA_DIR="$CLAUDE_AUTO_DATA_DIR" "${H_STALE[@]}" "${R_DEAD[@]}" CLAUDE_CODE_SESSION_ID=$MINE "$PY" - "$AUTO_ROOT" <<'PYEOF' 2>&1
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
sr = load_lib_module("session_registry")
sr.lookup = lambda *a, **k: (_ for _ in ()).throw(RuntimeError("boom"))
th = load_lib_module("terminal_host")
print(th.detect(dict(os.environ)).name)
PYEOF
)"
check "None" "$OUT"

it "a corrupt registry file falls through to refuse and does not raise"
printf 'not json\n{"session_id":\n' > "${CLAUDE_AUTO_DATA_DIR}/sessions/default.w3.jsonl"
has "None | " "$(both "$BOTH_BIN" "${H_STALE[@]}" "${R_DEAD[@]}" CLAUDE_CODE_SESSION_ID=$STRANGER)"

it "a live proof outranks the fallbacks: live herdr pane, dead Rex, row says rex"
check "herdr" "$(name "$(both "$BOTH_BIN" HERDR_PANE_ID=w2:p10 "${R_DEAD[@]}" CLAUDE_CODE_SESSION_ID=$REXROW)")"
it "both hosts prove live: refused even with a row"
has "both herdr and Rex prove" "$(both "$BOTH_BIN" HERDR_PANE_ID=w2:p10 "${R_LIVE[@]}" CLAUDE_CODE_SESSION_ID=$MINE)"

it "one announced host makes no call to either fake"
: > "$CALLS_LOG"
both "$BOTH_BIN" HERDR_PANE_ID=w2:p10 >/dev/null; both "$BOTH_BIN" "${R_LIVE[@]}" >/dev/null
check "0" "$(wc -l < "$CALLS_LOG" | tr -d ' ')"

verb() { # verb <bin-dir> <KEY=VALUE>...: the `host` verb's JSON line
  local bin="$1"; shift
  env -i PATH="${bin}:/usr/bin:/bin" CALLS="$CALLS_LOG" CLAUDE_AUTO_DATA_DIR="$CLAUDE_AUTO_DATA_DIR" "$@" \
    bash "${AUTO_ROOT}/lib/programme.sh" host 2>&1
}
SNAP="$(cd "$CLAUDE_AUTO_DATA_DIR" && find . -type f | sort | xargs cat | cksum)"
it "the host verb names the rung that decided: only announced host installed"
has '"decided_by": "only announced host installed"' "$(verb "$HERDRONLY_BIN" "${H_STALE[@]}" "${R_LIVE[@]}")"
it "the host verb names the rung that decided: this session's registry row"
has "registry row" "$(verb "$BOTH_BIN" "${H_STALE[@]}" "${R_DEAD[@]}" CLAUDE_CODE_SESSION_ID=$MINE)"
it "the host verb on a refused session says what was missing"
has "no interactive row" "$(verb "$BOTH_BIN" "${H_STALE[@]}" "${R_DEAD[@]}" CLAUDE_CODE_SESSION_ID=$STRANGER)"
it "the host verb writes nothing"
check "$SNAP" "$(cd "$CLAUDE_AUTO_DATA_DIR" && find . -type f | sort | xargs cat | cksum)"

echo
echo "host-stale-pane.test.sh:${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
