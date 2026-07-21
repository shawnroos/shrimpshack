#!/usr/bin/env bash
# Test runner for multi-slice-review (U3).
# Usage: ./run-tests.sh [unit|all|self-check|smoke] [--verbose]
#
# self-check (U3, §5/§8): proves the harness itself has teeth — it runs a
# deliberately-failing assertion and asserts the runner surfaces it as a
# non-zero exit. A runner that swallowed failures would report false-green;
# this catches that before U4+ trust the suite.

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
    if ! command -v node &> /dev/null; then
        echo -e "${RED}Error: node is not installed (needed for loop.js tests)${NC}"
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

# --self-check: prove the harness can actually fail. Write a bats file with a
# deliberately-false assertion, run it, and require bats to exit non-zero.
# If bats reports success on a false assertion, the harness is false-green.
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

# --smoke wire-up (U10): version sync + deterministic pre-pass→rubric pipeline + plugin validate.
wire_smoke() {
    echo -e "${YELLOW}Wire-up smoke...${NC}"
    local plugin_root repo_root rc=0
    plugin_root="$(cd "$SCRIPT_DIR/.." && pwd)"
    repo_root="$(cd "$plugin_root/../.." && pwd)"

    local pv mv
    pv="$(node -e "console.log(require('$plugin_root/.claude-plugin/plugin.json').version)" 2>/dev/null)"
    mv="$(node -e "const d=require('$repo_root/.claude-plugin/marketplace.json');const e=d.plugins.find(p=>p.name==='multi-slice-review');console.log(e?e.version:'MISSING')" 2>/dev/null)"
    if [ -n "$pv" ] && [ "$pv" = "$mv" ]; then
        echo -e "  ${GREEN}version sync${NC}: plugin.json ($pv) == marketplace ($mv)"
    else
        echo -e "  ${RED}version sync FAIL${NC}: plugin.json=$pv marketplace=$mv"; rc=1
    fi

    local tmp; tmp="$(mktemp -d)"
    if (
        cd "$tmp" && git init -q && git config user.email t@t.t && git config user.name t \
        && printf 'seed\n' > s.txt && git add -A && git commit -qm base && base="$(git rev-parse HEAD)" \
        && mkdir -p a/b c/d && printf 'x\n' > a/b/f.py && printf 'y\n' > c/d/g.py \
        && git add -A && git commit -qm change \
        && sig="$(bash "$plugin_root/skills/multi-slice-review/scripts/prepass.sh" "$base")" \
        && plan="$(printf '%s\n' "$sig" | bash "$plugin_root/skills/multi-slice-review/scripts/rubric.sh" --cores 10)" \
        && proj="$(printf '%s' "$plan" | grep '^PROJECTED_AGENTS=' | cut -d= -f2)" \
        && maxr="$(printf '%s' "$plan" | grep '^MAX_REVIEWERS=' | cut -d= -f2)" \
        && [ -n "$proj" ] && [ "$proj" -le "$maxr" ]
    ); then
        echo -e "  ${GREEN}pre-pass→rubric${NC}: produced a capped plan (agents ≤ MAX_REVIEWERS)"
    else
        echo -e "  ${RED}pipeline FAIL${NC}"; rc=1
    fi
    rm -rf "$tmp"

    # Note: `claude plugin validate` wants the PATH to the plugin, and returns exit 0
    # even on failure — so grep the output, don't trust the exit code.
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
    echo "multi-slice-review — Test Suite"
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
