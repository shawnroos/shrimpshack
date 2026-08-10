#!/usr/bin/env bash
# Test runner for the spawn plugin.
# Usage: ./run-tests.sh [unit|all|self-check|smoke] [--verbose]
#
# There is no CI in this repo, so this harness is the entire automated
# verification contract (plan, Verification Contract):
#   all         the release gate — self-check, every unit suite, wire smoke
#   unit        per-unit iteration during U2-U6
#   self-check  proves the harness can fail; a suite is trusted only after it
#               has been seen to fail
#   smoke       version sync, the agent-consumer invocation, the R12 secret
#               scan, and `claude plugin validate`
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
#
# It also owns the two release-gate checks that are not about any one unit:
# agent_consumer_smoke (the plugin is actually consumable by the caller it was
# built for) and secret_scan (R12 — merging publishes this tree).
wire_smoke() {
    echo -e "${YELLOW}Wire-up smoke...${NC}"
    local plugin_root repo_root rc=0
    plugin_root="$(cd "$SCRIPT_DIR/.." && pwd)"
    repo_root="$(cd "$plugin_root/../.." && pwd)"

    local pv mv
    pv="$(jq -r '.version // empty' "$plugin_root/.claude-plugin/plugin.json" 2>/dev/null)"
    # Derived from plugin.json, never hardcoded: a hardcoded name silently
    # reports MISSING after a rename and reads like a broken manifest rather
    # than a stale check. (It did exactly that on the gateway -> spawn rename;
    # the gate was right to fire, but it named the wrong cause.)
    local pn
    pn="$(jq -r '.name // empty' "$plugin_root/.claude-plugin/plugin.json" 2>/dev/null)"
    mv="$(jq -r --arg n "$pn" '(.plugins[] | select(.name == $n) | .version) // "MISSING"' \
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

    agent_consumer_smoke "$plugin_root" || rc=1
    secret_scan "$plugin_root" "$repo_root" || rc=1

    return $rc
}

# The parity check that actually matters. The lens's primary consumer is a skill
# holding `allowed-tools: Bash, Read` — it cannot invoke a slash command or a
# skill, so the ONLY thing that proves the plugin is consumable is driving the
# script the way that consumer drives it: Bash invocation, prompt on stdin,
# stdout captured, no terminal and no interaction anywhere in the path.
#
# A passing human-path test proves nothing about this. That is the whole reason
# it lives here rather than being assumed from the unit suite.
#
# Entirely fixture-backed. The live gateway on port 4000 is never in this path —
# a smoke that reached it would fight a running process and spend real money.
agent_consumer_smoke() {
    local plugin_root="$1"
    local work rc=0
    work="$(mktemp -d "${TMPDIR:-/tmp}/gw-smoke.XXXXXX")"
    work="$(cd "$work" && pwd -P)"

    # NOTE: no RETURN trap here. A RETURN trap set inside a function is not
    # cleared when that function returns — it stays armed in the caller's scope
    # and fires again on the CALLER's return, where the local it references no
    # longer exists ("work: unbound variable" under set -u). Observed, not
    # theorised. Cleanup is explicit below instead.
    (
        # Subshell so these exports cannot leak into the secret scan or into a
        # later smoke step, and so nothing here can reach ~/.gateway.pid,
        # ~/.gateway.log, ~/.gateway.lock or discover the real ~/gateway-*.
        # Same redirections lens.bats setup() uses.
        export SPAWN_STATE_HOME="$work"
        export SPAWN_SEARCH_ROOT="$work/searchroot"
        export TMPDIR="$work/tmp"
        mkdir -p "$SPAWN_SEARCH_ROOT" "$TMPDIR"
        export SPAWN_CONNECT_TIMEOUT=2
        export SPAWN_PROBE_TIMEOUT=5
        unset SPAWN_INSTALL_DIR SPAWN_MODELS_JSON
        unset SPAWN_LENS_TIMEOUT SPAWN_SPILL_BYTES SPAWN_LENS_MAX_TOKENS

        local token="smoke-tok-a1b2c3" portfile="$work/port" port
        rm -f "$portfile"
        python3 "$SCRIPT_DIR/fixtures/fake-gateway.py" \
            --token "$token" --aliases smoke-alias --scenario healthy \
            --port-file "$portfile" >"$work/gw.out" 2>"$work/gw.err" &
        local gw_pid=$!
        # The fixture is a child of THIS subshell, so its cleanup belongs here.
        # An outer-function trap would never see this pid and would leave an
        # orphaned python server bound to a port after every smoke run.
        # NO `wait` in this trap. `wait` on a job we just TERMed makes the
        # SUBSHELL exit 143 no matter what follows it — a trailing `true` does
        # not clear it — so a passing smoke reported red. Observed on bash 5.3
        # here, and reduced to a one-liner before being believed. Reap with a
        # bounded kill -0 poll instead.
        trap 'kill "$gw_pid" 2>/dev/null; for _r in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$gw_pid" 2>/dev/null || break; sleep 0.05; done; true' EXIT

        # BOUNDED wait. An unbounded until-loop is one of this box's documented
        # false-green shapes: it hangs forever instead of failing.
        local i
        for i in $(seq 1 100); do
            [ -s "$portfile" ] && break
            sleep 0.05
        done
        port="$(cat "$portfile" 2>/dev/null || true)"
        if [ -z "$port" ]; then
            echo -e "  ${RED}agent-consumer smoke FAIL${NC}: the fake gateway never reported a port"
            exit 1
        fi
        export SPAWN_BASE_URL="http://127.0.0.1:$port/anthropic"

        # Minimal gateway.yaml: the control layer reads the token from it.
        {
            printf 'server:\n'
            printf '  bind: "127.0.0.1:4000"\n'
            printf '  token: %s\n' "$token"
            printf '\nmodels:\n'
            printf '  smoke-alias:\n'
            printf '    model: up/smoke-alias\n'
        } > "$work/gateway.yaml"
        export SPAWN_CONFIG="$work/gateway.yaml"

        # THE INVOCATION UNDER TEST. Nothing clever: this is the literal shape a
        # tool-restricted subagent's Bash call takes. stderr is dropped, exactly
        # as a consumer capturing stdout would drop it — so a diagnostic that
        # leaked onto stdout breaks the parse rather than hiding.
        local out code=0
        out="$(printf '%s' 'Summarize this diff in one line.' \
            | bash "$plugin_root/lib/lens.sh" --alias smoke-alias 2>/dev/null)" || code=$?

        if [ "$code" -ne 0 ]; then
            echo -e "  ${RED}agent-consumer smoke FAIL${NC}: exit $code (expected 0)"
            printf '%s\n' "$out" | head -5
            exit 1
        fi
        # ONE JSON object, parseable whole — not "some JSON somewhere in the
        # stream". jq -e fails on a trailing diagnostic or a second object.
        if ! printf '%s' "$out" | jq -e '.ok == true and .alias == "smoke-alias" and (.text | type) == "string" and (.text | length) > 0' >/dev/null 2>&1; then
            echo -e "  ${RED}agent-consumer smoke FAIL${NC}: stdout was not one parseable JSON object carrying the answer"
            printf '%s\n' "$out" | head -5
            exit 1
        fi
        # Exactly one line on stdout is the structural half of "exactly one
        # object": a second object would parse individually but not as a whole.
        if [ "$(printf '%s\n' "$out" | grep -c .)" -ne 1 ]; then
            echo -e "  ${RED}agent-consumer smoke FAIL${NC}: stdout carried more than one line"
            exit 1
        fi
        exit 0
    ) || rc=1
    rm -rf "$work"

    if [ $rc -eq 0 ]; then
        echo -e "  ${GREEN}agent-consumer smoke${NC}: stdin prompt via Bash returned exit 0 and one parseable JSON answer"
    fi
    return $rc
}

# R12: no file the plugin SHIPS contains the gateway token or a credential.
# Merging to main publishes this tree, and models.json is seeded from the very
# config that holds the token — so this is the enforcement point, not a nicety.
#
# Two layers, because one is not enough:
#   1. the EXACT token, resolved the way the plugin resolves it. The real token
#      on this box is a low-entropy word-shaped string; no entropy heuristic
#      would ever flag it.
#   2. known credential PREFIXES, not an entropy score. An entropy heuristic
#      false-positives on the fixture tokens that legitimately live in
#      tests/unit/*.bats — shipped files, and correct as they stand.
#
# On a hit this prints the FILENAME ONLY. A scan that echoes the matched bytes
# into a transcript is itself the leak it was written to prevent.
secret_scan() {
    # scan_root is the PUBLISH boundary, not the plugin directory. Merging to
    # main publishes the whole repository (this one is public), and a
    # spawn-related change routinely writes outside plugins/spawn — the
    # implementation plan under docs/plans/ is authored from the very
    # gateway.yaml that holds the token. Scanning only the plugin dir meant the
    # gate did not look where the exposure is.
    local plugin_root="$1" scan_root="${2:-$1}" rc=0 warned=0

    # Layer 1 — exact token.
    local cfg="" token=""
    if [ -n "${SPAWN_CONFIG:-}" ] && [ -f "${SPAWN_CONFIG}" ]; then
        cfg="$SPAWN_CONFIG"
    else
        # Newest ~/gateway-*/gateway.yaml, matching the control layer's
        # resolution order (KTD4). Absent on a clean checkout — see below.
        # A bash glob, not `ls`: `ls` emits OSC-8 hyperlink escapes on this box
        # that corrupt any path captured from it.
        local d
        local -a cand=()
        for d in "$HOME"/gateway-*/; do
            [ -f "$d/gateway.yaml" ] && cand+=("$d/gateway.yaml")
        done
        if [ "${#cand[@]}" -gt 0 ]; then
            cfg="$(printf '%s\n' "${cand[@]}" | sort -V | tail -1)"
        fi
    fi
    if [ -n "$cfg" ]; then
        # Resolve the token the way the PLUGIN resolves it, not with a second
        # parser. The previous bare sed was wrong twice over, and both ways made
        # this layer scan a string that is not the credential while still
        # printing ACTIVE:
        #   1. section-blind + `head -1` — it took the first `token:` key
        #      anywhere in the file, so a config with an `upstreams:` block above
        #      `server:` scanned a decoy.
        #   2. no ${VAR} expansion — a `token: ${SPAWN_TOKEN}` config made the
        #      scan grep the tree for the literal text "${SPAWN_TOKEN}", which
        #      can never match, while the real credential went unscanned.
        # Both are sourced from the plugin's own code now, so they cannot drift.
        # shellcheck source=../lib/common.sh
        . "$plugin_root/lib/common.sh"
        token="$(expand_env_refs "$(awk '
            function trim(v) { sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v); return v }
            function decomment(v) { sub(/[ \t]+#.*$/, "", v); return trim(v) }
            function unquote(v) { gsub(/^["'"'"']|["'"'"']$/, "", v); return v }
            /^[A-Za-z_][A-Za-z0-9_-]*:/ { sec = $0; sub(/:.*$/, "", sec); next }
            sec == "server" && /^[ \t]+token:/ {
                v = $0; sub(/^[ \t]*token:[ \t]*/, "", v)
                print unquote(decomment(v)); exit
            }
        ' "$cfg" 2>/dev/null)")"
        # An unexpanded reference means the env var was not set in THIS shell, so
        # there is no value to scan for. That is a skip, not an active layer —
        # announcing ACTIVE here is worse than the silent version it replaced,
        # because the notice that exists to make a dark layer visible would be
        # reporting the layer as live.
        case "$token" in
            *'${'*'}'*)
                echo -e "  ${YELLOW}secret scan${NC}: exact-token layer SKIPPED (server.token is an unresolved \${VAR} reference; set it in this shell to scan for the real value)"
                token="" ;;
        esac
    fi

    # KEYCHAIN FALLBACK — the config is no longer where the token lives.
    #
    # Once setup migrated the credential into the Keychain and dropped
    # `server.token`, this layer went dark: it printed SKIPPED "no gateway
    # config resolved" on a box that has both a gateway AND a stored token, so
    # the ONLY layer that has ever caught a real credential in this repo
    # (docs/handoff.md — 15 chars, word-shaped, invisible to the prefix layer)
    # stopped running at exactly the moment the storage changed.
    #
    # This is the same bug secrets.sh:290-299 already narrates: "R27 added the
    # Keychain step to spawnctl's probe and left lens.sh and launch.sh reading
    # the config alone... One chain, one place, is the enforcement." The scan
    # was the fourth consumer reading the config alone. So it now resolves
    # through spawn::token_fallback — the same chain, not a fifth copy of it.
    #
    # token_fallback ASSIGNS (a $(...) capture would run it in a subshell and
    # drop the source). No value is ever printed — only which chain produced it.
    #
    # EVERY distinct value is scanned, not just the one the plugin would USE.
    # token_fallback's precedence (env before Keychain) is right for AUTH and
    # wrong for a SCAN: with a stale GATEWAY_TOKEN exported, taking only the
    # winner greps for a string that is not the live credential while printing
    # ACTIVE — the precise false-green this layer exists to prevent. Collecting
    # both removes the precedence question from the gate entirely.
    local -a tokens=() sources=()
    [ -n "$token" ] && { tokens+=("$token"); sources+=("config"); }

    # shellcheck source=../lib/secrets.sh
    . "$plugin_root/lib/secrets.sh"
    local kc_service="${SPAWN_KEYCHAIN_SERVICE:-spawn-gateway}"
    local kc_account="${SPAWN_KEYCHAIN_ACCOUNT_TOKEN:-gateway-token}"
    local cand src seen t
    # env, then Keychain, each resolved through the shared chain — the Keychain
    # pass masks GATEWAY_TOKEN so the chain's own precedence cannot hide the
    # stored value behind an exported one. Neither lookup is reimplemented here.
    for src in env keychain; do
        SPAWN_TOKEN_VALUE=""; SPAWN_TOKEN_SOURCE=""
        if [ "$src" = env ]; then
            [ -n "${GATEWAY_TOKEN:-}" ] || continue
            spawn::token_fallback "$kc_service" "$kc_account" || continue
        else
            GATEWAY_TOKEN="" spawn::token_fallback "$kc_service" "$kc_account" || continue
        fi
        cand="$SPAWN_TOKEN_VALUE"
        SPAWN_TOKEN_VALUE=""
        [ -n "$cand" ] || continue
        seen=0
        if [ "${#tokens[@]}" -gt 0 ]; then
            for t in "${tokens[@]}"; do [ "$t" = "$cand" ] && seen=1; done
        fi
        [ "$seen" -eq 1 ] && continue
        tokens+=("$cand"); sources+=("$src")
    done
    cand=""

    if [ "${#tokens[@]}" -gt 0 ]; then
        # FALSE-GREEN GUARD. "the token never appears" is vacuously true when
        # the token resolved to an empty string — that exact shape has already
        # passed green over leaking code in this repo. Assert the secret EXISTS
        # before asserting it is absent, and say which mode this run is in.
        local joined; joined="$(IFS=,; printf '%s' "${sources[*]}")"
        echo -e "  ${GREEN}secret scan${NC}: exact-token layer ACTIVE (${#tokens[@]} distinct token(s) resolved from: $joined)"
        local i hits
        for i in "${!tokens[@]}"; do
            token="${tokens[$i]}"
            # -F: the token is a literal, not a pattern.
            hits="$(grep -rlF --exclude-dir=.git -- "$token" "$scan_root" 2>/dev/null || true)"
            [ -n "$hits" ] || continue
            # What a merge publishes is COMMITTED content, so a hit is triaged
            # rather than lumped: a token reachable from HEAD or already staged
            # fails the gate, while one that exists only as an uncommitted
            # working-tree edit is a loud warning — real, worth fixing, but not
            # publishable by merging this branch. Collapsing the two would either
            # block every run on someone's local scratch file or, far worse,
            # tempt a future edit to soften the whole layer back to green.
            local f rel staged_hit head_hit
            while IFS= read -r f; do
                [ -n "$f" ] || continue
                rel="$(cd "$scan_root" && realpath --relative-to=. "$f" 2>/dev/null || printf '%s' "${f#"$scan_root"/}")"
                staged_hit=0; head_hit=0
                git -C "$scan_root" show ":$rel" 2>/dev/null | grep -qF -- "$token" && staged_hit=1
                git -C "$scan_root" show "HEAD:$rel" 2>/dev/null | grep -qF -- "$token" && head_hit=1
                if [ "$staged_hit" -eq 1 ] || [ "$head_hit" -eq 1 ]; then
                    echo -e "  ${RED}secret scan FAIL${NC}: the gateway token (${sources[$i]}) is COMMITTED or STAGED in: $rel"
                    rc=1
                else
                    echo -e "  ${YELLOW}secret scan WARNING${NC}: the gateway token (${sources[$i]}) is in your working copy of $rel (uncommitted, so merging cannot publish it — but committing that file would). Scrub or rotate before you stage it."
                    warned=1
                fi
            done <<< "$hits"
        done
        token=""
        tokens=()
    else
        # R11: the suite must pass from a clean checkout with no gateway
        # installed. Skip WITH NOTICE — a silent skip is how this layer would
        # quietly stop running.
        #
        # The reason is reported SEPARATELY for the two states this used to
        # collapse into "no gateway config resolved". That single message was
        # actively misleading on this machine: a config WAS resolved, it simply
        # no longer carries the token, and the notice sent whoever read it
        # looking for a missing install instead of a missing credential.
        if [ -n "$cfg" ]; then
            echo -e "  ${YELLOW}secret scan${NC}: exact-token layer SKIPPED (config $cfg declares no server.token, and no token is stored in the Keychain or exported here)"
        else
            echo -e "  ${YELLOW}secret scan${NC}: exact-token layer SKIPPED (no gateway config resolved on this box)"
        fi
    fi

    # Layer 2 — credential-shaped strings, by known prefix.
    local pat='sk-ant-[A-Za-z0-9_-]{16,}|sk-or-v1-[A-Za-z0-9]{16,}|sk-[A-Za-z0-9]{32,}|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{30,}|xox[baprs]-[A-Za-z0-9-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY-----'
    local phits
    phits="$(grep -rlE --exclude-dir=.git -- "$pat" "$scan_root" 2>/dev/null || true)"
    if [ -n "$phits" ]; then
        echo -e "  ${RED}secret scan FAIL${NC}: credential-shaped string in shipped file(s):"
        printf '%s\n' "$phits" | sed 's/^/      /'
        rc=1
    fi

    # Only claim a clean tree when nothing fired. A "no token anywhere" line
    # printed directly under a warning about a token is how a real hit gets read
    # as noise.
    if [ $rc -eq 0 ] && [ $warned -eq 0 ]; then
        echo -e "  ${GREEN}secret scan${NC}: no token and no credential-shaped string in the shipped tree"
    elif [ $rc -eq 0 ]; then
        echo -e "  ${YELLOW}secret scan${NC}: nothing committed or staged holds a credential, but see the warning above"
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
