#!/usr/bin/env bash
# work test harness.
#
# There is no CI in this repo, so this harness is the whole automated
# verification contract. It is source-safe on purpose: `wire_smoke` and
# `secret_scan` carry real rules, and a rule nothing can test in isolation is a
# rule that rots. Sourcing this file defines the functions and runs nothing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'

# Prove the harness can fail. A suite is trusted only after it has been seen to
# report a deliberately-false assertion as failing; without this, a runner that
# silently swallows bats' exit code reports green forever.
self_check() {
    printf '%sHarness self-check (deliberate-fail)...%s\n' "$YELLOW" "$NC"
    local tmp; tmp="$(mktemp -d)"
    cat > "$tmp/deliberate_fail.bats" <<'EOF'
@test "deliberate failure — the harness MUST report this as failing" {
    [ "1" = "2" ]
}
EOF
    if bats "$tmp/deliberate_fail.bats" >/dev/null 2>&1; then
        rm -rf "$tmp"
        printf '%sself-check FAILED%s — the runner called a false assertion green.\n' "$RED" "$NC"
        return 1
    fi
    rm -rf "$tmp"
    printf '%sself-check passed%s\n' "$GREEN" "$NC"
}

# The count of suite files committed alongside this guard (2026-09-05). Bump it
# up whenever a suite file is added; if it is ever lowered, say why in the
# commit — this number is what turns "the tests directory got renamed" into a
# failure instead of a smaller, silently-green run.
HERDR_LINEAR_MIN_SUITES="${HERDR_LINEAR_MIN_SUITES:-17}"

run_suite() {
    local failed=0 f count=0 dir="${1:-$PLUGIN_ROOT/tests/unit}"
    for f in "$dir"/*.bats; do
        [ -e "$f" ] || continue
        count=$((count + 1))
        printf '%s%s%s\n' "$YELLOW" "$(basename "$f")" "$NC"
        bats "$f" || failed=1
    done
    # A loop that never ran is a loop that never failed. Refuse the silent
    # green rather than let a moved directory or a broken glob report PASS.
    if [ "$count" -eq 0 ]; then
        printf '%srun_suite FAILED%s — zero .bats files found under %s; nothing ran.\n' "$RED" "$NC" "$dir"
        return 1
    fi
    if [ "$count" -lt "$HERDR_LINEAR_MIN_SUITES" ]; then
        printf '%srun_suite FAILED%s — %d suite file(s) found under %s, expected at least %d.\n' \
            "$RED" "$NC" "$count" "$dir" "$HERDR_LINEAR_MIN_SUITES"
        failed=1
    fi
    return "$failed"
}

# The two version fields must agree. Nothing enforces this repo-wide, so each
# plugin that wants the check writes its own.
version_sync_check() {
    local manifest="${1:-$PLUGIN_ROOT/.claude-plugin/plugin.json}"
    local marketplace="${2:-$REPO_ROOT/.claude-plugin/marketplace.json}"
    python3 - "$manifest" "$marketplace" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
mk = json.load(open(sys.argv[2]))
entry = next((p for p in mk.get("plugins", []) if p.get("name") == m["name"]), None)
if entry is None:
    print("plugin %r is not registered in the marketplace" % m["name"]); sys.exit(1)
if entry.get("version") != m.get("version"):
    print("version drift: plugin.json %s, marketplace %s" % (m.get("version"), entry.get("version"))); sys.exit(1)
PY
}

# `claude plugin validate` exits 0 even when it reports problems, so its output
# is what decides, not its status.
validate_check() {
    # A gate that cannot run is not a gate that passed. Opt out by name when
    # that is deliberate; silence here would let `all` go green on a machine
    # that never validated the manifest at all.
    if ! command -v claude >/dev/null 2>&1; then
        if [ -n "${HERDR_LINEAR_SKIP_VALIDATE:-}" ]; then
            printf 'claude absent; validate skipped by HERDR_LINEAR_SKIP_VALIDATE\n'; return 0
        fi
        printf '%sclaude is not on PATH, so the manifest was never validated%s\n' "$RED" "$NC"; return 1
    fi
    local out; out="$(claude plugin validate "$PLUGIN_ROOT" 2>&1 || true)"
    printf '%s\n' "$out"
    if printf '%s' "$out" | grep -qiE 'error|invalid|failed'; then return 1; fi
}

# Credential shapes that must never appear in the tree. spawn's set covers
# sk-ant-, sk-, AKIA, gh[pousr]_, xox and PEM headers; a Linear key is lin_api_
# and matches none of them, which is the shape this plugin actually handles.
SECRET_PATTERNS='lin_api_[A-Za-z0-9]{16,}|lin_oauth_[A-Za-z0-9]{16,}|sk-ant-[A-Za-z0-9_-]{16,}|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY-----'

# scan_paths <path>... -> non-zero when any path carries a credential shape.
scan_paths() {
    local hit=0 p
    for p in "$@"; do
        # -l, never -n: printing the matching LINE copies a live credential into
        # the terminal, the transcript and any log of the run, so the detector
        # would spread the very thing it found. Name the file instead.
        if grep -rIlE "$SECRET_PATTERNS" "$p" 2>/dev/null; then hit=1; fi
    done
    return "$hit"
}

secret_scan() {
    printf '%sSecret scan...%s\n' "$YELLOW" "$NC"
    if scan_paths "$PLUGIN_ROOT"; then
        printf '%sno credential shapes found%s\n' "$GREEN" "$NC"
    else
        printf '%ssecret scan FAILED%s — a credential shape is present in the tree.\n' "$RED" "$NC"
        return 1
    fi
}

# A `!`-negated command is exempt from errexit, so `! grep -q X` in a bats test
# detects the defect and lets the test pass. Two sanitiser tests and a Keychain
# guard were inert this way. The suite refuses the shape rather than trusting
# the next author to remember.
assertion_lint() {
    printf '%sAssertion lint...%s\n' "$YELLOW" "$NC"
    local hits
    hits="$(grep -rnE '^[[:space:]]*![[:space:]]' "$PLUGIN_ROOT"/tests/unit/*.bats 2>/dev/null || true)"
    if [ -n "$hits" ]; then
        printf '%s\n' "$hits"
        printf '%sassertion lint FAILED%s — a `!`-negated assertion cannot fail its test; use refute_match.\n' "$RED" "$NC"
        return 1
    fi
    printf '%sno negated assertions%s\n' "$GREEN" "$NC"
}

# Each SKILL.md hand-copies its own subset of `source lib/*.sh` lines, and
# nothing else checks that the subset is actually enough. This computes the
# real dependency closure from the lib files themselves (which function calls
# which, defined where) and fails a skill whose declared sourcing is short of
# what the functions it calls transitively need -- the "undefined function at
# the worst moment" failure the copy-pasted lists cannot see coming.
#
# owned_skills is scoped to the skills this plugin's `work` maintainer for this
# file owns; other skills under skills/ are out of scope here.
skill_lib_sync_check() {
    printf '%sSkill lib-sourcing check...%s\n' "$YELLOW" "$NC"
    local root="${1:-$PLUGIN_ROOT}" out
    out="$(python3 - "$root" <<'PY'
import re, sys, glob, os

plugin_root = sys.argv[1]
owned_skills = ["describe", "new", "new-sub-issue", "bind", "layout"]

lib_names = sorted(os.path.basename(f)[:-3] for f in glob.glob(os.path.join(plugin_root, "lib", "*.sh")))

defs = {}
for name in lib_names:
    text = open(os.path.join(plugin_root, "lib", name + ".sh")).read()
    for m in re.finditer(r'^herdr_linear::([A-Za-z0-9_]+)\s*\(\)', text, re.M):
        defs[m.group(1)] = name

file_deps = {}
for name in lib_names:
    text = open(os.path.join(plugin_root, "lib", name + ".sh")).read()
    used = set()
    for m in re.finditer(r'herdr_linear::([A-Za-z0-9_]+)', text):
        fn = m.group(1)
        if fn in defs and defs[fn] != name:
            used.add(defs[fn])
    file_deps[name] = used

def closure(start_names):
    seen, stack = set(), list(start_names)
    while stack:
        n = stack.pop()
        if n in seen:
            continue
        seen.add(n)
        stack.extend(file_deps.get(n, ()))
    return seen

def sourced_names(fence_text):
    names = set(re.findall(r'lib/([a-zA-Z][a-zA-Z-]*)\.sh', fence_text))
    m = re.search(r'for\s+f\s+in\s+([a-zA-Z0-9_ \-]+?)\s*;\s*do', fence_text)
    if m:
        names.update(m.group(1).split())
    return names

rc = 0
for skill in owned_skills:
    path = os.path.join(plugin_root, "skills", skill, "SKILL.md")
    if not os.path.isfile(path):
        print("MISSING SKILL.md: %s" % path); rc = 1; continue
    text = open(path).read()
    fence_text = "\n".join(re.findall(r'```bash\n(.*?)```', text, re.S))
    declared = sourced_names(fence_text)
    called = set(re.findall(r'herdr_linear::([A-Za-z0-9_]+)', fence_text))

    unknown = sorted(fn for fn in called if fn not in defs)
    if unknown:
        print("%s: calls undefined function(s): %s" % (path, ", ".join(unknown))); rc = 1

    required = closure({defs[fn] for fn in called if fn in defs})
    missing = sorted(required - declared)
    if missing:
        print("%s: sources %s, missing %s (needed transitively by what it calls)"
              % (path, sorted(declared), missing)); rc = 1

    bogus = sorted(n for n in declared if n not in lib_names)
    if bogus:
        print("%s: sources nonexistent lib file(s): %s" % (path, bogus)); rc = 1

sys.exit(rc)
PY
)" || true
    if [ -n "$out" ]; then
        printf '%s\n' "$out"
        printf '%sskill lib-sourcing check FAILED%s\n' "$RED" "$NC"
        return 1
    fi
    printf '%severy owned skill sources what it calls%s\n' "$GREEN" "$NC"
}

wire_smoke() {
    printf '%sWire smoke...%s\n' "$YELLOW" "$NC"
    local rc=0
    assertion_lint || rc=1
    version_sync_check || rc=1
    validate_check || rc=1
    secret_scan || rc=1
    skill_lib_sync_check || rc=1
    return "$rc"
}

main() {
    local what="${1:-all}" rc=0
    case "$what" in
        self-check) self_check || rc=1 ;;
        unit) self_check || rc=1; run_suite || rc=1 ;;
        smoke) wire_smoke || rc=1 ;;
        all) self_check || rc=1; run_suite || rc=1; wire_smoke || rc=1 ;;
        *) printf 'usage: run-tests.sh [all|unit|self-check|smoke]\n' >&2; return 2 ;;
    esac
    if [ "$rc" -eq 0 ]; then printf '%sPASS%s\n' "$GREEN" "$NC"; else printf '%sFAIL%s\n' "$RED" "$NC"; fi
    return "$rc"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then main "$@"; fi
