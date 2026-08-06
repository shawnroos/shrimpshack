#!/usr/bin/env bash
# Test runner for the gateway plugin.
# Usage: ./run-tests.sh [unit|all|self-check|smoke] [--verbose]
#
# There is no CI in this repo, so this harness is the entire automated
# verification contract (plan, Verification Contract):
#   all         the release gate — self-check, every unit suite, wire smoke
#   unit        per-unit iteration during U2-U6
#   self-check  proves the harness can fail; a suite is trusted only after it
#               has been seen to fail
#   smoke       version sync + `claude plugin validate`
#
# Dependencies are bats, jq and python3 — deliberately NOT node. R11 says the
# plugin installs and runs from a clean checkout with no other shrimpshack
# plugin present, and a harness that silently needs a fourth interpreter makes
# that claim false the first time someone runs it on a box without it.

set -euo pipefail

# Give this run its own TMPDIR so fixture state (recorded argv, port files,
# spill files) is per-run rather than machine-global. Two concurrent runs
# writing the same fixed filenames overwrite each other's fixtures and produce
# failures unrelated to the change — worse than a red suite, because it looks
# like signal.
GW_RUN_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/gateway-tests.XXXXXX")"
# Resolve to the PHYSICAL path. On macOS /tmp is a symlink to /private/tmp, so
# bash would hold the symlinked path while python reports the real one, and any
# assertion comparing a path from one against the other fails for a reason that
# has nothing to do with the code.
GW_RUN_TMPDIR="$(cd "$GW_RUN_TMPDIR" && pwd -P)"
export TMPDIR="$GW_RUN_TMPDIR"
trap 'rm -rf "$GW_RUN_TMPDIR"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TEST_TYPE="${1:-all}"
VERBOSE=""
if [[ "${2:-}" == "--verbose" ]] || [[ "${2:-}" == "-v" ]]; then
    VERBOSE="--tap"
fi

check_dependencies() {
    if ! command -v bats &> /dev/null; then
        echo -e "${RED}Error: bats is not installed${NC}"
        echo "Install with: brew install bats-core"
        exit 1
    fi
    if ! command -v jq &> /dev/null; then
        echo -e "${RED}Error: jq is not installed${NC}"
        echo "Install with: brew install jq"
        exit 1
    fi
    if ! command -v python3 &> /dev/null; then
        echo -e "${RED}Error: python3 is not installed (the gateway fixture is a stdlib HTTP server)${NC}"
        exit 1
    fi
}

run_suite() {
    local dir="$1" label="$2"
    echo -e "${YELLOW}Running ${label} tests...${NC}"
    echo "========================================"
    local failed=0 found=0
    if [[ -d "$SCRIPT_DIR/$dir" ]]; then
        for test_file in "$SCRIPT_DIR/$dir"/*.bats; do
            if [[ -f "$test_file" ]]; then
                found=1
                echo -e "\n${GREEN}Testing: $(basename "$test_file")${NC}"
                if bats $VERBOSE "$test_file"; then
                    echo -e "${GREEN}PASSED${NC}"
                else
                    echo -e "${RED}FAILED${NC}"
                    failed=1
                fi
            fi
        done
    fi
    if [[ $found -eq 0 ]]; then
        echo -e "${YELLOW}(no ${label} tests found)${NC}"
    fi
    return $failed
}

# self-check: prove the harness can actually fail. Write a bats file with a
# deliberately-false assertion, run it, and require bats to exit non-zero. A
# runner that swallowed failures would report false-green for every later unit.
self_check() {
    echo -e "${YELLOW}Harness self-check (deliberate-fail)...${NC}"
    echo "========================================"
    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN
    cat > "$tmp/deliberate_fail.bats" <<'EOF'
@test "deliberate failure — the harness MUST report this as failing" {
    [ "1" = "2" ]
}
EOF
    set +e
    bats "$tmp/deliberate_fail.bats" >/dev/null 2>&1
    local rc=$?
    set -e
    if [[ $rc -ne 0 ]]; then
        echo -e "${GREEN}self-check PASSED${NC} — the runner surfaced a false assertion as a non-zero exit."
        return 0
    else
        echo -e "${RED}self-check FAILED${NC} — the runner reported success on a deliberately-false assertion (false-green harness)."
        return 1
    fi
}

# Wire-up smoke: the plugin is only installable if plugin.json and the
# marketplace entry agree on a version, so assert that here rather than
# discovering it after a merge (merging to main is publishing).
wire_smoke() {
    echo -e "${YELLOW}Wire-up smoke...${NC}"
    local plugin_root repo_root rc=0
    plugin_root="$(cd "$SCRIPT_DIR/.." && pwd)"
    repo_root="$(cd "$plugin_root/../.." && pwd)"

    local pv mv
    pv="$(jq -r '.version // empty' "$plugin_root/.claude-plugin/plugin.json" 2>/dev/null)"
    mv="$(jq -r '(.plugins[] | select(.name == "gateway") | .version) // "MISSING"' \
        "$repo_root/.claude-plugin/marketplace.json" 2>/dev/null)"
    if [ -n "$pv" ] && [ "$pv" = "$mv" ]; then
        echo -e "  ${GREEN}version sync${NC}: plugin.json ($pv) == marketplace ($mv)"
    else
        echo -e "  ${RED}version sync FAIL${NC}: plugin.json=${pv:-EMPTY} marketplace=${mv:-EMPTY}"; rc=1
    fi

    # `claude plugin validate` wants the PATH to the plugin, and returns exit 0
    # even when validation fails — so grep the output, never trust the code.
    if command -v claude >/dev/null 2>&1; then
        if claude plugin validate "$plugin_root" 2>&1 | grep -q 'Validation passed'; then
            echo -e "  ${GREEN}claude plugin validate${NC}: passed"
        else
            echo -e "  ${RED}claude plugin validate FAIL${NC}"; rc=1
        fi
    else
        echo -e "  ${YELLOW}(claude CLI not on PATH — skipping plugin validate)${NC}"
    fi
    return $rc
}

main() {
    echo "========================================"
    echo "gateway — Test Suite"
    echo "========================================"
    echo ""
    check_dependencies
    local exit_code=0
    case "$TEST_TYPE" in
        unit)
            run_suite unit "unit" || exit_code=1
            ;;
        self-check)
            self_check || exit_code=1
            ;;
        all)
            self_check || exit_code=1
            echo ""
            run_suite unit "unit" || exit_code=1
            echo ""
            wire_smoke || exit_code=1
            ;;
        smoke)
            wire_smoke || exit_code=1
            ;;
        *)
            echo "Usage: $0 [unit|all|self-check|smoke] [--verbose]"
            exit 1
            ;;
    esac
    echo ""
    echo "========================================"
    if [[ $exit_code -eq 0 ]]; then
        echo -e "${GREEN}All checks passed!${NC}"
    else
        echo -e "${RED}Some checks failed!${NC}"
    fi
    echo "========================================"
    exit $exit_code
}

main
