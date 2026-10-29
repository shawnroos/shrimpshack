#!/usr/bin/env bash
# auto unit test: no herdr, rex or osascript command is called outside a host module (R1, R5).
#
# Scans auto's own lib/, .claude/hooks/ and commands/ (not plugins/spinoff, not mods/*.ts) for
# an invocation of a host binary anywhere except lib/host_*.py:
#   .py  an ast scan: subprocess/os/shutil calls and argv list literals that name the binary,
#        and the send-guard's binary tokens. A bare "herdr" string (a source name, a prose
#        message) is not an invocation.
#   .sh  a non-comment line with the binary in command position.
#   .md  a backticked `herdr <verb>` the agent is told to run.
# ALLOW lists a file only while it still holds a hit, so a stale entry fails too.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PY="${CLAUDE_AUTO_PYTHON3:-/usr/bin/python3}"

# path (relative to the scanned root) : why it may name a host binary
ALLOW=(
  # Agent instructions for the PM in prose; U8 rewrites them host-neutral.
  "commands/programme-resume.md:prose instructions for the agent"
)

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
CURRENT="anonymous"
it()   { CURRENT="${1:-anonymous}"; }
pass() { PASS=$((PASS + 1)); printf "  \033[32m✓\033[0m %s\n" "$CURRENT"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[31m✗\033[0m %s\n" "$CURRENT"; [ -n "${1:-}" ] && printf "      %s\n" "$1"; return 0; }
has() { case "$2" in *"$1"*) pass ;; *) fail "expected to find [$1] in [$2]" ;; esac; }
check_eq() { if [ "$1" = "$2" ]; then pass; else fail "expected [$1] got [$2]"; fi; }

# scan <root> [allow-file]: prints "SEEN <n>" then "HIT <relpath>:<line>: <text>" per violation
# and "STALE <relpath>" per allow-list entry with no hit.
scan() {
  "$PY" -I - "$1" "${2:-}" <<'PYEOF'
import ast, os, re, sys
root, allow_file = sys.argv[1], sys.argv[2]
allow = set(open(allow_file).read().split()) if allow_file else set()
NAMES = {"herdr", "rex", "osascript"}
CALLS = {"run", "Popen", "call", "check_output", "check_call", "which", "system", "popen", "bounded",
         "execv", "execvp", "execvpe", "execl", "execlp", "spawn"}
SH_CMD = re.compile(r'(?:^|[;&|(]|\$\(|\bthen\b|\bdo\b|\bexec\b|\bcommand -v\b|\bwhich\b|\btimeout [0-9.]+)\s*"?\$?\{?(herdr|rex|osascript|HERDR_BIN_PATH)\b')
MD_CMD = re.compile(r'`\s*(?:herdr|rex|osascript)\s+[a-z-]+')

def const(node):
    return node.value if isinstance(node, ast.Constant) and isinstance(node.value, str) else None

def py_hits(path):
    try:
        tree = ast.parse(open(path).read())
    except SyntaxError as exc:
        return [(exc.lineno or 0, "unparseable")]
    out = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Call):
            fn = node.func.attr if isinstance(node.func, ast.Attribute) else getattr(node.func, "id", "")
            if fn in CALLS:
                for sub in ast.walk(node):
                    c = const(sub)
                    if c and (c in NAMES or c.split(" ")[0] in NAMES and " " in c):
                        out.append((node.lineno, f"{fn}(... {c!r})"))
                        break
        elif isinstance(node, ast.List) and len(node.elts) >= 2 and const(node.elts[0]) in NAMES:
            out.append((node.lineno, f"argv list starting {const(node.elts[0])!r}"))
        elif isinstance(node, ast.Constant) and isinstance(node.value, str) and re.fullmatch(r"\$\{?HERDR_BIN_PATH\}?", node.value):
            out.append((node.lineno, f"binary token {node.value!r}"))
        elif isinstance(node, ast.Compare) and isinstance(node.left, ast.Call) \
                and getattr(node.left.func, "attr", "") == "basename" \
                and any(const(c) in NAMES for c in node.comparators):
            out.append((node.lineno, "basename compared with a host binary"))
    return out

def text_hits(path, pattern, strip_comments):
    out = []
    for n, line in enumerate(open(path, errors="replace"), 1):
        body = line.split(" #")[0] if strip_comments and not line.lstrip().startswith("#") else line
        if strip_comments and line.lstrip().startswith("#"):
            continue
        if pattern.search(body):
            out.append((n, line.strip()[:100]))
    return out

seen, hits, used = 0, [], set()
for top in ("lib", ".claude/hooks", "commands"):
    for dirpath, dirs, files in os.walk(os.path.join(root, top)):
        dirs[:] = [d for d in dirs if d != "__pycache__"]
        for name in sorted(files):
            rel = os.path.relpath(os.path.join(dirpath, name), root)
            if name.startswith("host_") and name.endswith(".py"):
                continue
            path = os.path.join(root, rel)
            if name.endswith(".py"):
                found = py_hits(path)
            elif name.endswith(".sh"):
                found = text_hits(path, SH_CMD, True)
            elif name.endswith(".md"):
                found = text_hits(path, MD_CMD, False)
            else:
                continue
            seen += 1
            for n, text in found:
                if rel in allow:
                    used.add(rel)
                else:
                    hits.append(f"HIT {rel}:{n}: {text}")
print(f"SEEN {seen}")
print("\n".join(hits))
for rel in sorted(allow - used):
    print(f"STALE {rel}")
PYEOF
}

ALLOW_FILE="$WORK/allow.txt"
for entry in "${ALLOW[@]}"; do printf '%s\n' "${entry%%:*}"; done > "$ALLOW_FILE"

echo "terminal-host-boundary: auto's own tree"
OUT="$(scan "$AUTO_ROOT" "$ALLOW_FILE")"
SEEN="$(printf '%s\n' "$OUT" | sed -n 's/^SEEN //p')"
it "anti-vacuity: the scan saw at least 50 files"
if [ "${SEEN:-0}" -ge 50 ]; then pass; else fail "saw ${SEEN:-0}"; fi
it "no host command outside a host module"
BAD="$(printf '%s\n' "$OUT" | grep -E '^(HIT|STALE) ' || true)"
if [ -z "$BAD" ]; then pass; else fail "$BAD"; fi
it "plugins/spinoff and mods/ are outside the scan"
case "$OUT" in *spinoff*|*mods/*) fail "$OUT" ;; *) pass ;; esac

echo "terminal-host-boundary: the scanner can fail (synthetic trees)"
T="$WORK/tree"
mkdir -p "$T/lib" "$T/.claude/hooks" "$T/commands"
cat > "$T/lib/clean.py" <<'PYEOF'
SOURCES = ("herdr", "tracker")
def explain():
    return "herdr is unavailable, so the owner pane cannot be seen"
PYEOF
printf '# herdr pane list is mentioned in a comment\necho "herdr is down"\n' > "$T/.claude/hooks/clean.sh"
printf 'Run Claude from a herdr pane.\n' > "$T/commands/clean.md"
cat > "$T/lib/host_fake.py" <<'PYEOF'
import subprocess
subprocess.run(["rex", "send", "x"])
PYEOF
it "a host module file may call its host, and prose mentions are not hits"
check_eq "" "$(scan "$T" | grep -E '^(HIT|STALE)' || true)"

it "a stray subprocess rex call in lib names the file"
cat > "$T/lib/stray.py" <<'PYEOF'
import subprocess
def go():
    subprocess.run(["rex", "send", "hello"], check=False)
PYEOF
has "HIT lib/stray.py:3" "$(scan "$T")"

it "shutil.which of a host binary is a hit"
printf 'import shutil\nBIN = shutil.which("herdr")\n' > "$T/lib/which.py"
has "HIT lib/which.py:2" "$(scan "$T")"

it "an osascript call through an argv variable is a hit"
printf 'ARGV = ["osascript", "-e", "tell application x"]\n' > "$T/lib/osa.py"
has "HIT lib/osa.py:1" "$(scan "$T")"

it "a shell hook calling herdr in command position is a hit"
printf 'if [ -n "$X" ]; then\n  herdr pane list\nfi\n' > "$T/.claude/hooks/call.sh"
has "HIT .claude/hooks/call.sh:2" "$(scan "$T")"

it "a shell pipeline into rex is a hit"
printf 'echo hi | rex send\n' > "$T/.claude/hooks/pipe.sh"
has "HIT .claude/hooks/pipe.sh:1" "$(scan "$T")"

it "a backticked herdr verb in a command doc is a hit"
printf 'Read the pane: `herdr pane read %%s`\n' > "$T/commands/run.md"
has "HIT commands/run.md:1" "$(scan "$T")"

it "an allow-list entry with no hit is stale"
printf 'lib/clean.py\n' > "$WORK/stale.txt"
has "STALE lib/clean.py" "$(scan "$T" "$WORK/stale.txt")"

it "an allow-listed file stops being a hit"
printf 'lib/stray.py\n' > "$WORK/ok.txt"
case "$(scan "$T" "$WORK/ok.txt")" in *"HIT lib/stray.py"*) fail "still a hit" ;; *) pass ;; esac

it "anti-vacuity: an empty tree is reported as zero files seen"
mkdir -p "$WORK/empty"
check_eq "SEEN 0" "$(scan "$WORK/empty" | head -1)"

echo "terminal-host-boundary: a running programme reaches the host only through the host module"
SPY="${AUTO_ROOT}/tests/helpers/host-spy.py"
. "${AUTO_ROOT}/tests/helpers/host-fakes.sh"
host_fake_install herdr "$WORK/bin"
RUNENV=(env "PATH=${WORK}/bin:${PATH}" "CLAUDE_AUTO_DATA_DIR=${WORK}/data" "CLAUDE_AUTO_PERSONAL_PROTOCOL=${WORK}/p.json"
        "CLAUDE_AUTO_MACHINE=studio" "CLAUDE_AUTO_SECRETS_FILE=${WORK}/secrets" "CLAUDE_CODE_SESSION_ID=sess-pm"
        "CLAUDE_AUTO_TEST_HARNESS=1" "HERDR_PANE_ID=w2:p10" "SPY_LOG=${WORK}/spy.log")
: > "$WORK/secrets"
: > "$WORK/spy.log"
it "programme.py start succeeds from a pane under the spy"
OUT="$("${RUNENV[@]}" "$PY" "$SPY" "$WORK/spy.log" "${AUTO_ROOT}/lib/programme.py" start 2>&1)"
has '"kind": "programme_started"' "$OUT"
for verb in status sweep reconcile-leases; do
  "${RUNENV[@]}" "$PY" "$SPY" "$WORK/spy.log" "${AUTO_ROOT}/lib/programme.py" "$verb" >/dev/null 2>&1
done
it "anti-vacuity: the spy recorded herdr spawns from the programme verbs"
N=$(grep -c '^run herdr' "$WORK/spy.log" || true)
if [ "$N" -ge 2 ]; then pass; else fail "recorded ${N}: $(cat "$WORK/spy.log")"; fi
it "every recorded spawn went through a host module frame"
D="$(grep ' direct$' "$WORK/spy.log" || true)"
if [ -z "$D" ]; then pass; else fail "direct spawns: $D"; fi
it "control: a direct herdr spawn outside a host module is recorded as direct"
printf 'import subprocess\nsubprocess.run(["herdr", "status", "server"])\n' > "$WORK/stray_call.py"
: > "$WORK/spy2.log"
"${RUNENV[@]}" "$PY" "$SPY" "$WORK/spy2.log" "$WORK/stray_call.py" >/dev/null 2>&1
has "run herdr direct" "$(cat "$WORK/spy2.log")"

echo ""
echo "terminal-host-boundary.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
