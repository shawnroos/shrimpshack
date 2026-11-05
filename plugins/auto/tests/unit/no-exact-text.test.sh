#!/usr/bin/env bash
# Auto never asks Shawn for exact words again: scans by glob, so a new instruction file enrols itself.
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

echo "no-exact-text.test.sh"

WORK="$(mktemp -d -t auto-no-exact-text.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export CLAUDE_AUTO_DATA_DIR="${WORK}/data"
export CLAUDE_AUTO_TASKS_DIR="${WORK}/tasks"
export CLAUDE_AUTO_PERSONAL_PROTOCOL="${WORK}/personal/protocol.json"
export CLAUDE_AUTO_SECRETS_FILE="${WORK}/secrets"
export CLAUDE_AUTO_MACHINE="studio"
export CLAUDE_CODE_SESSION_ID="sess-pm"
mkdir -p "${WORK}/shipped" "${WORK}/behaviours"
export CLAUDE_AUTO_SHIPPED_BEHAVIOURS_DIR="${WORK}/shipped"
export CLAUDE_AUTO_BEHAVIOURS_DIR="${WORK}/behaviours"
: > "$CLAUDE_AUTO_SECRETS_FILE"
unset HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_BIN_PATH CLAUDE_AUTO_REPO REX_SESSION 2>/dev/null || true

SCAN="${WORK}/scan.py"
cat > "$SCAN" <<'PYEOF'
import glob, os, re, sys

os.chdir(sys.argv[1])
GLOBS = ("skills/**/*.md", "commands/*.md", "agents/*.md", "CONCEPTS.md", "README.md", "docs/programme-overview.md",
         "docs/concepts/programme/*.md", "docs/contracts/programme-*.md", "docs/contracts/agent-tool-surface.md",
         "lib/programme*.py", "lib/on-*.py", "mods/programme-view/*.ts", "mods/programme-view/*.tsx")
# These skills use "typed" for typed criteria and fields of a run, not for anything Shawn enters.
SKIP = ("skills/auto-design/", "skills/auto-launch/", "skills/auto-driver/", "skills/auto-author-")
FORBIDDEN = re.compile(
    r"type this|exact text to type|exact reply|\bto type\b|ask shawn to type|\bhe types\b|shawn types"
    r"|typed (prompt|line|reply|answer|approval|words|message|confirmation|adoption|pick|text)"
    r"|needs typed|needs_typed|\btype (applied|it\b|one\b|the approval|/auto)|approval-label|approval_label"
    r"|must name|names? the id|carries the (content )?hash|\"reply\"|word for word", re.I)
ALLOWED = (
    ("skills/programme-sweep/SKILL.md", "reuse its stored title word for word", "stored title, PM to tracker"),
    ("lib/programme_import.py", "conflicting_approval_label", "a gap kind already stored in imported journals"),
    ("lib/on-session-start.py", "the block must name the latest one", "the rules block's revision, not Shawn's words"),
    ("lib/programme_recovery.py", "it must name a known admission", "a receipt's fields, not Shawn's words"),
    ("docs/contracts/agent-tool-surface.md", "decision id must name a decision-log entry", "a flag's value, not Shawn's words"),
    ("docs/contracts/programme-protocol-format.md", "Each target must name an existing item", "a flag's value, not Shawn's words"),
    ("lib/programme_sources.py", "a blind resend would type it twice", "text resent to a worker's pane"),
)
hits = []
for pattern in GLOBS:
    for path in sorted(glob.glob(pattern, recursive=True)):
        if path.startswith(SKIP) or path.endswith(".test.ts"):
            continue
        with open(path, errors="replace") as stream:
            for number, line in enumerate(stream, 1):
                if FORBIDDEN.search(line) and not any(path == a[0] and a[1] in line for a in ALLOWED):
                    hits.append(f"{path}:{number}: {line.strip()[:160]}")
print("\n".join(hits))
sys.exit(1 if hits else 0)
PYEOF

it "no instruction, fix line or pane text asks for exact words"
OUT="$("$PY" "$SCAN" "$AUTO_ROOT" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then pass; else fail "$OUT"; fi

it "the scan fails on a forbidden line seeded into a copy, by glob, in a new file"
COPY="${WORK}/copy"
mkdir -p "$COPY"
(cd "$AUTO_ROOT" && tar cf - skills commands agents CONCEPTS.md README.md docs/programme-overview.md docs/concepts docs/contracts lib/programme*.py lib/on-*.py mods/programme-view 2>/dev/null) | tar xf - -C "$COPY"
"$PY" "$SCAN" "$COPY" >/dev/null 2>&1; BEFORE=$?
printf 'Tell Shawn the exact text to type.\n' > "${COPY}/commands/programme-seeded.md"
OUT="$("$PY" "$SCAN" "$COPY" 2>&1)"; AFTER=$?
if [ "$BEFORE" -eq 0 ] && [ "$AFTER" -ne 0 ] && [[ "$OUT" == *programme-seeded.md* ]]; then pass; else fail "before=$BEFORE after=$AFTER: $OUT"; fi

it "the sweep skill carries the rule, and stays in the PM's every-activation text"
if grep -qiF 'never ask shawn for exact words' "${AUTO_ROOT}/skills/programme-sweep/SKILL.md"; then pass; else fail "the rule is gone from SKILL.md"; fi

RESULTS="$("$PY" - "$AUTO_ROOT" "$SCAN" <<'PYEOF'
import glob, json, os, re, subprocess, sys
root = sys.argv[1]
sys.path.insert(0, os.path.join(root, "lib"))
sys.path.insert(0, os.path.join(root, "tests", "fixtures"))
from _bootstrap import load_lib_module
scan = open(sys.argv[2]).read()
FORBIDDEN = eval(re.search(r"FORBIDDEN = (re\.compile\(.*?re\.I\))", scan, re.S).group(1))
prog = load_lib_module("programme")
fixes = load_lib_module("programme_fixes")
offers = load_lib_module("programme_offers")
approval = load_lib_module("programme_approval")

bad = {v: fixes.fix_for(v) for v in prog._VERBS if FORBIDDEN.search(fixes.fix_for(v))}
print("FIXES", json.dumps(bad))
print("LABEL_VERB", json.dumps("approval-label" in prog._VERBS))

# Takes --prompt but approves nothing Shawn is asked: takeover has become-pm's picker; watcher-beat's --prompt is cron text.
NOT_OFFERED = {"takeover", "watcher-beat"}
source = "".join(open(p).read() for p in glob.glob(os.path.join(root, "lib", "programme*.py")))
taking = {name for name, verb in prog._VERBS.items() if "--prompt" in (verb.args or "")}
print("UNRENDERED", json.dumps(sorted(taking - set(offers.RENDERERS) - NOT_OFFERED)))
print("PICK_DIFF", json.dumps(sorted(set(offers.RENDERERS) ^ set(approval.PICK_VERBS))))
print("TAKING_COUNT", len(taking))

PYEOF
)"
it "every verb's fix line holds no forbidden phrase"
LINE="$(printf '%s\n' "$RESULTS" | sed -n 's/^FIXES //p')"
if [ "$LINE" = "{}" ]; then pass; else fail "$LINE"; fi
it "the approval-label verb is gone"
LINE="$(printf '%s\n' "$RESULTS" | sed -n 's/^LABEL_VERB //p')"
if [ "$LINE" = "false" ]; then pass; else fail "$LINE"; fi
it "every verb taking --prompt has a renderer, so a new one fails here"
LINE="$(printf '%s\n' "$RESULTS" | sed -n 's/^UNRENDERED //p')"
if [ "$LINE" = "[]" ]; then pass; else fail "$LINE"; fi
it "the check of verbs taking --prompt saw them (anti-vacuity)"
LINE="$(printf '%s\n' "$RESULTS" | sed -n 's/^TAKING_COUNT //p')"
if [ "${LINE:-0}" -ge 38 ]; then pass; else fail "saw ${LINE:-none}"; fi
it "approval verbs and renderers are one set"
LINE="$(printf '%s\n' "$RESULTS" | sed -n 's/^PICK_DIFF //p')"
if [ "$LINE" = "[]" ]; then pass; else fail "$LINE"; fi

STATE="$("$PY" - "$AUTO_ROOT" <<'PYEOF' 2>&1
import json, os, re, subprocess, sys
root = sys.argv[1]
prog = os.path.join(root, "lib", "programme.py")
sys.path.insert(0, os.path.join(root, "lib"))
from _bootstrap import load_lib_module
def run(*args, stdin=""):
    return subprocess.run([sys.executable, prog, *args], input=stdin, text=True, capture_output=True)
run_id = load_lib_module("programme_home").create_programme(["w-no-exact"], "sess-pm")["run"]
status = run("status", "--json", "--run", run_id)
def keys(value):
    if isinstance(value, dict):
        for key, inner in value.items():
            yield key
            yield from keys(inner)
    elif isinstance(value, list):
        for inner in value:
            yield from keys(inner)
view = json.loads(status.stdout)
found = set(keys(view)) & {"reply", "replies", "needs_typed"}
print("KEYS", json.dumps(sorted(found)), "SAW", len(view.get("setup", {}).get("steps") or []))
offers = load_lib_module("programme_offers")
programme = load_lib_module("programme_home").normalize_programme(
    load_lib_module("run_record_core").read_run_record(load_lib_module("programme_home").home_path(run_id), run_id).get("programme") or {})
rendered = {}
SAMPLES = [["accept-agreement"], ["adopt-autonomy", "eval_waiver", "act_and_tell", "--widening"],
           ["record-ruling", "g1", "--effect", "grant", "--kind", "tool_choice", "--scope", "use X"],
           ["carry-rulings"], ["record-behaviour", "--when", "a job", "--do", "a thing"],
           ["amend-term", "stop_rule", "never_stop"], ["handover", "sess-b"], ["end"]]
bad, rendered_count = [], 0
for argv in SAMPLES:
    try:
        out = offers.render(argv, programme)
    except Exception:
        continue
    rendered_count += 1
    if out["label"].startswith("Approve ") or "--" in out["label"] or re.search(r"<[^<>]+>", out["label"]):
        bad.append(out["label"])
print("LABELS", json.dumps(bad), "RENDERED", rendered_count)
PYEOF
)"
it "status holds no reply, replies or needs_typed key"
case "$STATE" in *'KEYS []'*) pass ;; *) fail "$STATE" ;; esac
it "the status it read holds the setup view (anti-vacuity)"
SAW="$(printf '%s\n' "$STATE" | sed -n 's/.*SAW \([0-9]*\).*/\1/p')"
if [ "${SAW:-0}" -ge 1 ]; then pass; else fail "$STATE"; fi
it "every rendered option holds no flag, placeholder or old label"
case "$STATE" in *'LABELS []'*) pass ;; *) fail "$STATE" ;; esac
it "the option check rendered options (anti-vacuity)"
COUNT="$(printf '%s\n' "$STATE" | sed -n 's/.*RENDERED \([0-9]*\).*/\1/p')"
if [ "${COUNT:-0}" -ge 5 ]; then pass; else fail "$STATE"; fi

echo "no-exact-text.test.sh: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
