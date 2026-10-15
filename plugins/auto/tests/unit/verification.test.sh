#!/usr/bin/env bash
# auto U3 unit test: lib/verification.py
#   evaluate_programmatic (run + check + bounded binary-safe evidence) and the
#   pure aggregate (decision / pending_judges, KTD-6).
#
# SELF-CONTAINED inline harness (same style as workflows.test.sh / run-record.test.sh).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() {
  FAIL=$((FAIL + 1))
  printf "  \033[31m✗\033[0m %s\n" "$CURRENT"
  [ -n "${1:-}" ] && printf "      %s\n" "$1"
  return 0
}
assert_eq() { [ "$1" = "$2" ] && pass || fail "expected '$1' got '$2'"; }

# Driver: load verification via _bootstrap, run a scenario, print a terse result.
vf() {
  "$PY" - "$AUTO_ROOT" "$@" <<'PYEOF'
import sys, os, json
auto_root = sys.argv[1]
sys.path.insert(0, os.path.join(auto_root, "lib"))
from _bootstrap import load_lib_module
v = load_lib_module("verification")
op = sys.argv[2]

def ep(crit):
    return v.evaluate_programmatic(crit)["status"]

if op == "exit-zero-true":
    print(ep({"id": "c", "type": "programmatic", "argv": ["true"], "check": "exit_zero"}))
elif op == "exit-zero-false":
    print(ep({"id": "c", "type": "programmatic", "argv": ["false"], "check": "exit_zero"}))
elif op == "contains-hit":
    print(ep({"id": "c", "type": "programmatic", "argv": ["printf", "hello world"],
              "check": {"stdout_contains": "world"}}))
elif op == "contains-miss":
    print(ep({"id": "c", "type": "programmatic", "argv": ["printf", "hello"],
              "check": {"stdout_contains": "world"}}))
elif op == "equals-exact":
    print(ep({"id": "c", "type": "programmatic", "argv": ["printf", "ok"],
              "check": {"stdout_equals": "ok"}}))
elif op == "equals-mismatch":
    print(ep({"id": "c", "type": "programmatic", "argv": ["printf", "nope"],
              "check": {"stdout_equals": "ok"}}))
elif op == "timeout":
    print(ep({"id": "c", "type": "programmatic", "argv": ["sleep", "5"],
              "check": "exit_zero", "timeout_sec": 1}))
elif op == "nonexistent-argv":
    print(ep({"id": "c", "type": "programmatic", "argv": ["this-binary-does-not-exist-xyz"],
              "check": "exit_zero"}))
elif op == "binary-no-crash":
    # 200k of /dev/urandom via head -c; must not crash and evidence must be capped.
    r = v.evaluate_programmatic({"id": "c", "type": "programmatic",
        "argv": ["sh", "-c", "head -c 200000 /dev/urandom"], "check": "exit_zero"})
    # Cap is on RAW captured bytes (≤8192); decoded with errors='replace' that is
    # ≤8192 code points, plus the short truncation note. Measure chars, not
    # re-encoded bytes (each binary byte → a 3-byte U+FFFD on re-encode).
    ok = isinstance(r["evidence"], str) and len(r["evidence"]) <= 8192 + 64
    print("ok" if (r["status"] == "pass" and ok) else "bad")
elif op == "agg-all-pass":
    crits = [{"id": "a", "type": "programmatic"}, {"id": "b", "type": "programmatic"}]
    print(v.aggregate(crits, {"a": "pass", "b": "pass"}, {})["signal"])
elif op == "agg-one-fail":
    crits = [{"id": "a", "type": "programmatic"}, {"id": "b", "type": "programmatic"}]
    print(v.aggregate(crits, {"a": "pass", "b": "fail"}, {})["signal"])
elif op == "agg-pending":
    crits = [{"id": "a", "type": "programmatic"}, {"id": "j", "type": "advisor_judge"}]
    r = v.aggregate(crits, {"a": "pass"}, {})
    print(f"{r['signal']}|{','.join(r['pending_judges'])}")
elif op == "agg-injected-advisor":
    crits = [{"id": "a", "type": "programmatic"}, {"id": "j", "type": "advisor_judge"}]
    print(v.aggregate(crits, {"a": "pass"}, {"j": "pass"})["signal"])
elif op == "ep-evidence-strings":
    t = v.evaluate_programmatic({"id": "c", "argv": ["sleep", "5"], "check": "exit_zero", "timeout_sec": 1})
    m = v.evaluate_programmatic({"id": "c", "argv": ["this-binary-does-not-exist-xyz"], "check": "exit_zero"})
    e = v.evaluate_programmatic({"id": "c", "argv": [], "check": "exit_zero"})
    print("|".join([t["evidence"], m["evidence"].split(":")[0], e["evidence"]]))
elif op == "rc-ran":
    r = v.run_capped(["sh", "-c", "printf out; printf err >&2; exit 3"])
    print(r["ran"], r["exit_code"], r["stdout"], r["stderr"], r["truncated"], r["timed_out"])
elif op == "rc-timeout":
    r = v.run_capped(["sleep", "5"], timeout=1)
    print(r["ran"], r["timed_out"], r["exit_code"])
elif op == "rc-missing":
    r = v.run_capped(["this-binary-does-not-exist-xyz"])
    print(r["ran"], r["missing"], r["exit_code"])
elif op == "rc-truncated":
    r = v.run_capped(["sh", "-c", "printf 0123456789"], cap=4)
    print(r["ran"], r["truncated"], r["stdout"])
elif op == "rc-env-cwd":
    r = v.run_capped(["/bin/sh", "-c", 'printf "%s|%s|%s" "$ONLY" "${HOME-unset}" "$(pwd -P)"'],
                     cwd="/", env={"ONLY": "x", "PATH": "/usr/bin:/bin"})
    print(r["stdout"].decode())
elif op == "rc-env-path-lookup":
    r = v.run_capped(["true"], env={"PATH": "/nonexistent"})
    print(r["ran"], r["missing"])
elif op == "rc-empty":
    r = v.run_capped([])
    print(r["ran"], r["error"])
else:
    print("UNKNOWN_OP")
PYEOF
}

echo "verification.test.sh"

it "programmatic exit_zero: pass on true"
assert_eq "pass" "$(vf exit-zero-true)"

it "programmatic exit_zero: fail on false"
assert_eq "fail" "$(vf exit-zero-false)"

it "programmatic stdout_contains: hit"
assert_eq "pass" "$(vf contains-hit)"

it "programmatic stdout_contains: miss"
assert_eq "fail" "$(vf contains-miss)"

it "programmatic stdout_equals: exact"
assert_eq "pass" "$(vf equals-exact)"

it "programmatic stdout_equals: mismatch"
assert_eq "fail" "$(vf equals-mismatch)"

it "programmatic timeout → fail (no hang)"
assert_eq "fail" "$(vf timeout)"

it "programmatic nonexistent argv → fail (no crash)"
assert_eq "fail" "$(vf nonexistent-argv)"

it "binary stdout → no crash + evidence within 8KB cap"
assert_eq "ok" "$(vf binary-no-crash)"

it "aggregate: all programmatic pass → advance"
assert_eq "advance" "$(vf agg-all-pass)"

it "aggregate: one programmatic fail → iterate"
assert_eq "iterate" "$(vf agg-one-fail)"

it "aggregate: advisor_judge with no verdict → pending, decision None"
assert_eq "None|j" "$(vf agg-pending)"

it "aggregate: programmatic pass + injected advisor pass → advance"
assert_eq "advance" "$(vf agg-injected-advisor)"

it "evaluate_programmatic evidence text is unchanged for timeout, missing binary and empty argv"
assert_eq "timed out after 1s: sleep 5|could not run ['this-binary-does-not-exist-xyz']|empty argv (nothing to run)" "$(vf ep-evidence-strings)"

it "run_capped: ran, exit code, both streams"
assert_eq "True 3 b'out' b'err' False False" "$(vf rc-ran)"

it "run_capped: timeout is not a run"
assert_eq "False True None" "$(vf rc-timeout)"

it "run_capped: missing binary is not a run and says so"
assert_eq "False True None" "$(vf rc-missing)"

it "run_capped: output past the cap sets truncated"
assert_eq "True True b'0123'" "$(vf rc-truncated)"

it "run_capped: the child gets exactly the given env and cwd"
assert_eq "x|unset|/" "$(vf rc-env-cwd)"

it "run_capped: the binary is looked up on the given env's PATH"
assert_eq "False True" "$(vf rc-env-path-lookup)"

it "run_capped: empty argv is not a run"
assert_eq "False empty argv (nothing to run)" "$(vf rc-empty)"

echo ""
echo "verification.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
