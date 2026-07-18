#!/usr/bin/env bash
# Test runner for token-bridge
# Usage: ./run-tests.sh [unit|integration|all] [--verbose]

set -euo pipefail

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
