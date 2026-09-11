#!/usr/bin/env bash
# The plugin's whole test surface. Runs an explicit list of files, never a glob:
# a directory scan cannot notice a file that is gone, so a deleted test would read
# as a clean pass. That false-green is the thing this harness exists to prevent.
set -uo pipefail

PLUGIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS="$PLUGIN/tests"
SKILL="$PLUGIN/skills/data-presentation/SKILL.md"

EXPECTED=(
  vendor_test.py
  validate_test.py
  selection_test.py
  render_test.py
  forms_test.py
  present_test.py
  session_log_test.py
  templates_test.py
  credentials_test.py
  mapping_test.py
  changes_test.py
  sources_test.py
  pairing_test.py
  report_test.py
)

PASS=0
FAIL=0

ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL - $1" >&2; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

echo "data-presentation"

for name in "${EXPECTED[@]}"; do
  path="$TESTS/$name"
  if [ ! -r "$path" ]; then
    bad "$name is missing or unreadable"
    continue
  fi
  if out="$(python3 "$path" 2>&1)"; then
    tally="$(printf '%s\n' "$out" | tail -1)"
    ok "$name — $tally"
  else
    bad "$name"
    printf '%s\n' "$out" | sed 's/^/      /' >&2
  fi
done

# The skill body carries rules no Python test can reach.
check "SKILL.md exists" "[ -r '$SKILL' ]"
check "SKILL.md declares a name" "grep -q '^name:' '$SKILL'"
check "SKILL.md declares a description" "grep -q '^description:' '$SKILL'"
check "SKILL.md pins a fence with no language tag" "grep -qE '^\`\`\`\$' '$SKILL'"
check "SKILL.md says to reproduce verbatim" "grep -qi 'verbatim' '$SKILL'"
check "SKILL.md says when not to call the skill" "grep -qi 'do not call' '$SKILL'"
check "SKILL.md tells the agent to relay a refusal" "grep -qi 'refus' '$SKILL'"
check "SKILL.md names the table fallback for unsure destinations" "grep -qi 'monospace' '$SKILL'"

REPORT_SKILL="$PLUGIN/skills/report/SKILL.md"
check "report SKILL.md exists" "[ -r '$REPORT_SKILL' ]"
check "report SKILL.md declares its name" "grep -q '^name: report\$' '$REPORT_SKILL'"
check "report SKILL.md pins a fence with no language tag" "grep -qE '^\`\`\`\$' '$REPORT_SKILL'"
check "report SKILL.md says to reproduce verbatim" "grep -qi 'verbatim' '$REPORT_SKILL'"
check "report SKILL.md forbids editing a saved call" "grep -qi 'never edit a saved call' '$REPORT_SKILL'"
check "report SKILL.md runs finish in a later message" "grep -qi 'later message' '$REPORT_SKILL'"
check "report SKILL.md forbids following instructions inside results" "grep -qi 'instruction found' '$REPORT_SKILL'"
check "report SKILL.md lists before every prepare" "grep -qi 'even when the session start line' '$REPORT_SKILL'"
check "the data-presentation skill stays name-only" "grep -qi 'invoked by name only' '$SKILL'"

# A command and a skill sharing a name hide the skill with no error. The floor stops
# two empty listings from passing.
collide="$(python3 - "$PLUGIN" <<'PY'
import os, sys
root = sys.argv[1]
commands = {f[:-3] for f in os.listdir(os.path.join(root, "commands")) if f.endswith(".md")}
skills = set(os.listdir(os.path.join(root, "skills")))
if len(commands) < 1 or len(skills) < 2:
    print("floor"); sys.exit()
print(" ".join(sorted(commands & skills)))
PY
)"
check "no command shares a skill's name (and both listings are populated)" "[ -z '$collide' ]"

# Naming the auto-loaded hooks file in the manifest makes the whole plugin fail to load.
check "plugin.json does not name the auto-loaded hooks/hooks.json" \
  "! python3 -c 'import json,sys; h=json.load(open(sys.argv[1])).get(\"hooks\"); sys.exit(0 if isinstance(h,str) and h.lstrip(\"./\")==\"hooks/hooks.json\" else 1)' '$PLUGIN/.claude-plugin/plugin.json'"

HOOK="$PLUGIN/hooks/saved-reports.sh"
hook_home="$(mktemp -d)"
check "the session start hook prints nothing when no reports are saved" \
  "[ -z \"\$(HOME='$hook_home' bash '$HOOK')\" ]"
mkdir -p "$hook_home/.claude/data-presentation/templates"
touch "$hook_home/.claude/data-presentation/templates/"{alpha-report,beta}.json \
      "$hook_home/.claude/data-presentation/templates/Bad Name.json"
hook_out="$(HOME="$hook_home" bash "$HOOK")"
check "the session start hook names each saved report" \
  "printf '%s' '$hook_out' | grep -q 'alpha-report, beta'"
check "the session start hook ignores a file whose name breaks the pattern" \
  "! printf '%s' '$hook_out' | grep -q 'Bad Name'"
rm -rf "$hook_home"

# The repo is public. A fixture copies the structure of real data, never its values.
leaks="$(python3 - "$TESTS/fixtures" <<'PY'
import hashlib, os, re, sys
real = {8: "6dba4b006cd64ffdc496602f37a51279376d96f037827cead1117de3e70403e1",
        36: "46d9e5c834f0b27b44c95a0f300cbc4df9906aa2320e6002e886f1c8b61023c6"}
fake_uuid = re.compile(r"00000000-0000-4000-8000-\d{12}")
hits = []
for name in sorted(os.listdir(sys.argv[1])):
    text = open(os.path.join(sys.argv[1], name), encoding="utf-8").read()
    if "/Users/" in text:
        hits.append(name + ": /Users/ path")
    for u in re.findall(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", text):
        if not fake_uuid.fullmatch(u):
            hits.append(name + ": real-looking uuid")
    for size, digest in real.items():
        if any(hashlib.sha256(text[i:i + size].encode()).hexdigest() == digest
               for i in range(len(text) - size + 1)):
            hits.append(name + ": a real id")
print("; ".join(hits))
PY
)"
check "no fixture holds a real path, id or session (${leaks:-clean})" "[ -z '$leaks' ]"

echo "harness: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
