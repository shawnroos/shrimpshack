#!/usr/bin/env bash
# Test runner for token-bridge
# Usage: ./run-tests.sh [unit|integration|all] [--verbose]

set -euo pipefail

# Give this run its own TMPDIR, so BATS_TMPDIR is per-run rather than
# machine-global. The suite writes fixed filenames into it (emit_da, cli_guard,
# d1 …), so two concurrent runs — parallel CI shards, or a mutation-testing
# harness running copies side by side — silently overwrite each other's
# fixtures. That surfaced as nonsense-correlated failures during a mutation
# pass: a colour-classification mutation "killing" a source.ref test. A
# contaminated run reports failures that have nothing to do with the change,
# which is worse than a red suite because it looks like signal.
TB_RUN_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/token-bridge-tests.XXXXXX")"
# Resolve to the PHYSICAL path. On macOS /tmp is a symlink to /private/tmp, so
# bash would hold the symlinked path while python reports the real one, and any
# assertion comparing a path from one against the other fails for a reason that
# has nothing to do with the code.
TB_RUN_TMPDIR="$(cd "$TB_RUN_TMPDIR" && pwd -P)"
export TMPDIR="$TB_RUN_TMPDIR"
trap 'rm -rf "$TB_RUN_TMPDIR"' EXIT

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
        echo -e "${RED}Error: python3 is not installed${NC}"
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

main() {
    echo "========================================"
    echo "token-bridge — Test Suite"
    echo "========================================"
    echo ""
    check_dependencies
    local exit_code=0
    case "$TEST_TYPE" in
        unit)
            run_suite unit "unit" || exit_code=1
            ;;
        integration)
            run_suite integration "integration" || exit_code=1
            ;;
        all)
            run_suite unit "unit" || exit_code=1
            echo ""
            run_suite integration "integration" || exit_code=1
            ;;
        *)
            echo "Usage: $0 [unit|integration|all] [--verbose]"
            exit 1
            ;;
    esac
    echo ""
    echo "========================================"
    if [[ $exit_code -eq 0 ]]; then
        echo -e "${GREEN}All tests passed!${NC}"
    else
        echo -e "${RED}Some tests failed!${NC}"
    fi
    echo "========================================"
    exit $exit_code
}

main
