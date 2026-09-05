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

run_suite() {
    local failed=0 f
    for f in "$PLUGIN_ROOT"/tests/unit/*.bats; do
        [ -e "$f" ] || continue
        printf '%s%s%s\n' "$YELLOW" "$(basename "$f")" "$NC"
        bats "$f" || failed=1
    done
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

wire_smoke() {
    printf '%sWire smoke...%s\n' "$YELLOW" "$NC"
    local rc=0
    assertion_lint || rc=1
    version_sync_check || rc=1
    validate_check || rc=1
    secret_scan || rc=1
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
