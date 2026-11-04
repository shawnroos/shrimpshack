#!/usr/bin/env bash
# auto unit test: runs 680 generated commands, plus 22 written by hand, through real /bin/bash with a logging herdr shim.
# The 680 are the cases of a 27 prefix x 9 spelling x 14 wrapper cross (3402) whose index sum divides by 5, so every pair
# of prefix, spelling and wrapper appears. A literal send that bash runs must be refused; no false allow is tolerated.
# A false refusal of a known class counts against FALSE_REFUSAL_BOUND instead of failing one by one.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"
EXPECTED_CASES=702

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
check() { if [ "$1" = "$2" ]; then pass; else fail "expected [$1] got [$2]"; fi; }

echo "send-guard-bash-oracle.test.sh"

WORK="$(mktemp -d -t auto-send-oracle.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

for v in $(env | grep -oE '^(HERDR|REX|GHOSTTY|AUTO_TEST)_[A-Z_]*'); do unset "$v"; done
export CLAUDE_AUTO_DATA_DIR="${WORK}/data"

ORACLE_PY="${WORK}/oracle.py"
cat > "$ORACLE_PY" <<'PYEOF'
import itertools, json, os, subprocess, sys, time
from concurrent.futures import ThreadPoolExecutor

auto_root, root = sys.argv[1:3]
sys.path.insert(0, os.path.join(auto_root, "lib"))
from _bootstrap import load_lib_module
guard = load_lib_module("send_guard")

PANE = "w2:p9T"
SEND = f"herdr pane run {PANE} ls"
FALSE_REFUSAL_BOUND = 12
SPELLINGS = [
    SEND, f"h''erdr pane run {PANE} ls", f"her\\dr pane run {PANE} ls", f'"herdr" pane run {PANE} ls',
    f"$'herdr' pane run {PANE} ls", f"herdr pane \\\n run {PANE} ls", f"herdr pane run >/dev/null {PANE} ls",
    f"{SEND} 2>&1", f'herdr pane run "{PANE}" ls',
]
PREFIXES = [
    ("", ""), ("true; ", ""), ("true && ", ""), ("false || ", ""), ("echo a | ", ""), ("{ ", "; }"), ("( ", ")"),
    ("if true; then ", "; fi"), ("while false; do :; done; ", ""), ("for i in 1; do ", "; done"), ("FOO=1 ", ""),
    (">/dev/null ", ""), ("command ", ""), ("exec ", ""), ("! ", ""), ("echo ", ""), ("echo a # ", ""), ("# ", ""),
    ("echo 'q' ", ""), ("printf x ", ""), ("echo '>' ; ", ""), ("echo \"it's\"; ", ""), ("echo ')' ; ", ""),
    ("f() { ", "; }; f"), ("case x in x) ", ";; esac"), ("A=$(echo b) ", ""), ("x=$(echo ')'); ", ""),
]
WRAPPERS = [
    lambda s, sq: s,
    lambda s, sq: f"bash -c '{sq}'",
    lambda s, sq: f"eval '{sq}'",
    lambda s, sq: f"echo $({s})",
    lambda s, sq: f'echo "$({s})"',
    lambda s, sq: f"echo `{s}`",
    lambda s, sq: f"bash <<EOF\n{s}\nEOF",
    lambda s, sq: f"cat <<'EOF' | bash\n{s}\nEOF",
    lambda s, sq: f"cat <<'EOF'\n{s}\nEOF",
    lambda s, sq: f"cat <<EOF\n{s}\nEOF",
    lambda s, sq: f"cat <<EOF\n$({s})\nEOF",
    lambda s, sq: f"bash <<< '{sq}'",
    lambda s, sq: f"{s} # don't",
    lambda s, sq: f"# don't\n{s}",
]
HAND = [
    ("deny", f'echo ">"; {SEND}'),
    ("deny", f'echo ">"; herdr pane run >/dev/null {PANE} ls'),
    ("deny", f'cat <<E"O"F\nbody\nEOF\n{SEND}'),
    ("deny", f"cat <<EOF\n$({SEND})\nEOF"),
    ("deny", f"cat <<EOF\n`{SEND}`\nEOF"),
    ("deny", f"""echo "$(echo ')'; {SEND})\""""),
    ("deny", f'''echo "$(echo ")"; {SEND})"'''),
    ("allow", f"cat <<'E O F'\n{SEND}\nE O F"),
    ("allow", f"cat <<A <<B\nx\nA\n{SEND}\nB"),
    ("allow", f"cat <<EOF\n  EOF\n{SEND}\nEOF"),
    ("deny", f'h$""erdr pane run {PANE} ls'),
    ("deny", f"((x << 2))\n{SEND}"),
    ("deny", f"echo $[1<<2]\n{SEND}"),
    ("deny", f"echo `echo \\`{SEND}\\``"),
    ("deny", f"a=(x # don't\n y); {SEND} 'z'"),
    ("deny", f"a[0]=1 {SEND}"),
    ("allow", f"echo }} {SEND}"),
    ("allow", f"echo {{ {SEND}"),
    ("deny", f"cat <<EOF; {SEND}\nbody\nEOF"),
    ("allow", f"a=({SEND}); echo ok"),
    ("deny", f"echo \\#x; {SEND}"),
    ("allow", f"cat <<'EOF'\n$({SEND})\nEOF"),
]


def generated():
    picked = []
    for (pi, (before, after)), (si, send), (wi, wrap) in itertools.product(enumerate(PREFIXES), enumerate(SPELLINGS), enumerate(WRAPPERS)):
        if (pi + si + wi) % 5:
            continue
        body = wrap(send, send.replace("'", "'\\''"))
        command = before + body + ("\n" + after.lstrip("; ") if after and "\n" in body else after)
        picked.append((pi, si, wi, command))
    return picked


def bash_env(case_dir):
    return {"PATH": case_dir + ":/usr/bin:/bin"}


def truth(job):
    i, command = job
    case_dir = os.path.join(root, str(i))
    os.mkdir(case_dir)
    log, shim = os.path.join(case_dir, "ran"), os.path.join(case_dir, "herdr")
    with open(shim, "w") as fh:
        fh.write(f"#!/bin/bash\necho ran >> '{log}'\n")
    os.chmod(shim, 0o755)
    env = bash_env(case_dir)
    if subprocess.run(["/bin/bash", "-n", "-c", command], env=env, capture_output=True, stdin=subprocess.DEVNULL).returncode:
        return "syntax"
    try:
        subprocess.run(["/bin/bash", "-c", command], cwd=case_dir, env=env, stdin=subprocess.DEVNULL, capture_output=True, timeout=10)
    except subprocess.TimeoutExpired:
        return "timeout"
    return "deny" if os.path.exists(log) else "allow"


def real_guard(command):
    driver = {"pane_id": PANE, "ids": [PANE], "terminal_id": None}
    return "deny" if any(guard._targets_pane(hit[2], driver, "w2") for hit in guard.host_sends(command, [PANE])) else "allow"


def score(rows, verdict):
    false_allows, false_refusals = [], []
    for command, want in rows:
        got = verdict(command)
        if want == "deny" and got == "allow":
            false_allows.append(command)
        elif want == "allow" and got == "deny":
            false_refusals.append(command)
    return false_allows, false_refusals


started = time.time()
cases = generated()
commands = [c[3] for c in cases] + [command for _want, command in HAND]
os.makedirs(root, exist_ok=True)
with ThreadPoolExecutor(4) as pool:
    truths = list(pool.map(truth, enumerate(commands)))
shim_found = subprocess.run(["/bin/bash", "-c", "command -v herdr"], env=bash_env(os.path.join(root, "0")), capture_output=True, text=True).stdout.strip()
scored = [(c, t) for c, t in zip(commands, truths) if t in ("deny", "allow")]
false_allows, false_refusals = score(scored, real_guard)
allow_all = score(scored, lambda c: "allow")
deny_all = score(scored, lambda c: "deny")
real_program = guard._program
guard._program = lambda words: None
blind = score(scored, real_guard)
guard._program = real_program
print(json.dumps({
    "cases": len(commands),
    "prefixes": len({c[0] for c in cases}), "spellings": len({c[1] for c in cases}), "wrappers": len({c[2] for c in cases}),
    "scored": len(scored), "syntax": truths.count("syntax"), "timeout": truths.count("timeout"),
    "deny": truths.count("deny"), "allow": truths.count("allow"),
    "hand_wrong": [command for (want, command), got in zip(HAND, truths[len(cases):]) if want != got],
    "shim_on_path": shim_found == os.path.join(root, "0", "herdr"),
    "false_allows": false_allows[:10], "false_allow_count": len(false_allows),
    "false_refusal_count": len(false_refusals), "false_refusals": false_refusals[:10], "bound": FALSE_REFUSAL_BOUND,
    "allow_all_false_allows": len(allow_all[0]), "deny_all_false_refusals": len(deny_all[1]),
    "blind_false_allows": len(blind[0]), "seconds": round(time.time() - started),
}))
PYEOF

OUT="$("$PY" "$ORACLE_PY" "$AUTO_ROOT" "${WORK}/cases")"
field() { "$PY" -c 'import json,sys; v=json.load(sys.stdin)[sys.argv[1]]; print(json.dumps(v) if isinstance(v,(list,dict)) else v)' "$1" <<< "$OUT"; }

it "the oracle ran the stated number of cases"
check "$EXPECTED_CASES" "$(field cases)"
it "every prefix, spelling and wrapper is represented"
check "27 9 14" "$(field prefixes) $(field spellings) $(field wrappers)"
it "herdr resolves to the logging shim, never a real herdr"
check "True" "$(field shim_on_path)"
it "no case hung"
check "0" "$(field timeout)"
it "real bash both ran sends and did not"
check "both" "$([ "$(field deny)" -gt 0 ] && [ "$(field allow)" -gt 0 ] && echo both)"
it "the oracle can fail: a guard that allows everything has one false allow per send bash ran"
check "$(field deny)" "$(field allow_all_false_allows)"
it "the oracle can fail: a guard that refuses everything goes over the false refusal bound"
check "over" "$([ "$(field deny_all_false_refusals)" -gt "$(field bound)" ] && echo over)"
it "the oracle can fail: the real guard with its program reader broken has false allows"
check "some" "$([ "$(field blind_false_allows)" -gt 0 ] && echo some)"
it "real bash runs or skips each hand case as it says"
check "[]" "$(field hand_wrong)"
it "no false allow: every literal send bash runs is refused"
if [ "$(field false_allow_count)" = 0 ]; then pass; else fail "$(field false_allow_count) false allows, first: $(field false_allows)"; fi
it "false refusals stay at or under the bound (a heredoc piped to a shell whose reader output goes elsewhere, exec eval, exec FOO=1)"
if [ "$(field false_refusal_count)" -le "$(field bound)" ]; then pass; else fail "$(field false_refusal_count) over $(field bound), first: $(field false_refusals)"; fi
echo "  oracle: $(field cases) cases, $(field syntax) fail bash -n, $(field scored) scored, $(field deny) sends, $(field false_allow_count) false allows, $(field false_refusal_count) false refusals, $(field seconds) s"

echo ""
echo "send-guard-bash-oracle.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
