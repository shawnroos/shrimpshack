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

echo "programme-journal.test.sh"

WORK="$(mktemp -d -t auto-journal.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
cat > "$CLAUDE_AUTO_SECRETS_FILE" <<'EOF'
# fixture
export FIXTURE_TOKEN="fixture-value-9f8e7d"
SHORT=ab
PLAIN_KEY=another-secret-3c2b1a
EOF

run_py() {
  "$PY" - "$AUTO_ROOT" "$@" <<PYEOF 2>&1
import json, os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
from _bootstrap import load_lib_module
ph = load_lib_module("programme_home")
pj = load_lib_module("programme_journal")
args = sys.argv[2:]
$(cat)
PYEOF
}

RUN="$(run_py <<'EOF'
print(ph.create_programme(["w2"], "sess-pm")["run"])
EOF
)"
HOME_DIR="${CLAUDE_AUTO_DATA_DIR}/programmes/${RUN}"

it "an appended entry carries kind, at, session_id and payload"
OUT="$(run_py "$RUN" <<'EOF'
e = pj.append(args[0], "blocked_driver_send", "sess-w", {"target": "w2:p1"})
rows = pj.read(args[0])
r = rows[-1]
print(r["kind"], r["session_id"], r["payload"]["target"], bool(r["at"]))
EOF
)"
check "blocked_driver_send sess-w w2:p1 True" "$OUT"

it "an unknown journal kind is refused"
OUT="$(run_py "$RUN" <<'EOF'
try:
    pj.append(args[0], "made_up_kind", "s", {})
    print("ACCEPTED")
except pj.JournalError:
    print("REFUSED")
EOF
)"
check "REFUSED" "$OUT"

it "a captured prompt gets a fresh id and can be found by it"
OUT="$(run_py "$RUN" <<'EOF'
a = pj.append_prompt(args[0], "sess-pm", "first", "typed")
b = pj.append_prompt(args[0], "sess-pm", "second", "typed")
found = pj.find_prompt(args[0], b["prompt_id"])
print(a["prompt_id"] != b["prompt_id"], found["payload"]["text"], found["payload"]["origin"])
EOF
)"
check "True second typed" "$OUT"

it "the journal file is 0600 inside a 0700 folder"
OUT="$(stat -f '%Lp' "${HOME_DIR}/journal.jsonl") $(stat -f '%Lp' "$HOME_DIR")"
check "600 700" "$OUT"

it "journal lines carry no run_id, loop or loop phase keys"
OUT="$(run_py "$RUN" <<'EOF'
bad = [k for r in pj.read(args[0]) for k in ("run_id", "loop", "loop_" + "phase") if k in r]
print(bad)
EOF
)"
check "[]" "$OUT"

it "two concurrent appends both land as whole lines"
run_py "$RUN" <<'EOF' >/dev/null
import subprocess
code = ("import os,sys;sys.path.insert(0,os.path.join(sys.argv[1],'lib'));"
        "from _bootstrap import load_lib_module;pj=load_lib_module('programme_journal');"
        "[pj.append(sys.argv[2],'blocked_driver_send','s'+sys.argv[3],{'n':i,'pad':'x'*4000}) for i in range(40)]")
procs = [subprocess.Popen([sys.executable, "-c", code, sys.argv[1], args[0], str(n)]) for n in range(2)]
for p in procs:
    p.wait()
EOF
OUT="$(run_py "$RUN" <<'EOF'
path = os.path.join(ph.home_path(args[0]), "journal.jsonl")
good = bad = 0
with open(path) as fh:
    for line in fh:
        try:
            json.loads(line)
            good += 1
        except ValueError:
            bad += 1
heavy = sum(1 for r in pj.read(args[0]) if r["payload"].get("pad"))
print(heavy, bad)
EOF
)"
check "80 0" "$OUT"

it "redaction replaces a value from the secrets file"
OUT="$(run_py <<'EOF'
print(pj.redact("use fixture-value-9f8e7d and another-secret-3c2b1a now"))
EOF
)"
check "use [redacted] and [redacted] now" "$OUT"

it "redaction leaves short secrets-file values alone"
OUT="$(run_py <<'EOF'
print(pj.redact("ab cd"))
EOF
)"
check "ab cd" "$OUT"

it "redaction replaces common token shapes"
OUT="$(run_py <<'EOF'
samples = [
    "ghp_" + "a" * 36,
    "github_pat_" + "B" * 30,
    "xoxb-" + "1234567890-abcdef",
    "sk-ant-" + "c" * 30,
    "AKIA" + "ABCDEFGHIJKLMNOP",
    "lin_api_" + "d" * 30,
    "npm_" + "e" * 30,
    "Bearer " + "f" * 30,
    "API_KEY=" + "g" * 12,
]
print(all("[redacted]" in pj.redact("x " + s + " y") and s not in pj.redact("x " + s + " y") for s in samples))
EOF
)"
check "True" "$OUT"

it "a missing secrets file still redacts token shapes"
OUT="$(CLAUDE_AUTO_SECRETS_FILE="${WORK}/absent" run_py <<'EOF'
print(pj.redact("ghp_" + "a" * 36 + " fixture-value-9f8e7d"))
EOF
)"
check "[redacted] fixture-value-9f8e7d" "$OUT"

it "the redaction output never carries the secrets file path"
OUT="$(run_py <<'EOF'
print(pj.redact("nothing secret"))
EOF
)"
case "$OUT" in *"$WORK"*) fail "path leaked: $OUT" ;; *) check "nothing secret" "$OUT" ;; esac

it "pruning drops uncited prompts older than 7 days and keeps cited and recent ones"
OUT="$(run_py "$RUN" <<'EOF'
import datetime
run = args[0]
old = datetime.datetime(2020, 1, 1, tzinfo=datetime.timezone.utc)
stale = pj.append_prompt(run, "sess-pm", "stale", "typed", now=old)
cited = pj.append_prompt(run, "sess-pm", "cited", "typed", now=old)
pj.append(run, "handover_request", "sess-pm", {"verb": "handover"}, cites=[cited["prompt_id"]], now=old)
fresh = pj.append_prompt(run, "sess-pm", "fresh", "typed")
removed = pj.prune_uncited_prompts(run)
ids = {r.get("prompt_id") for r in pj.read(run)}
print(removed >= 1, stale["prompt_id"] in ids, cited["prompt_id"] in ids, fresh["prompt_id"] in ids)
EOF
)"
check "True False True True" "$OUT"

it "pruning keeps the file 0600"
OUT="$(stat -f '%Lp' "${HOME_DIR}/journal.jsonl")"
check "600" "$OUT"

it "reading a run with no journal returns an empty list"
OUT="$(run_py <<'EOF'
r = ph.create_programme(["w9"], "sess-other")["run"]
print(pj.read(r))
EOF
)"
check "[]" "$OUT"

echo ""
echo "programme-journal.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
