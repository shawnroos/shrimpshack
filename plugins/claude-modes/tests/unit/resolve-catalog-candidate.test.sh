#!/usr/bin/env bash
# U2 unit test: lib/resolve-catalog-candidate.sh (catalog candidate resolver).
#
# All fixtures are seeded under the isolated $HOME sandbox — the resolver reads
# ~/.claude/plugins/{cache,installed_plugins.json,marketplaces}, all of which
# live inside the test HOME, so no scenario touches the real user cache.
#
# Scenarios (mirrors the plan's U2 test list):
#   Happy:  single installed plugin → source=installed installed=Y
#   Happy:  single cached skill at Anthropic-layout (.../.claude/skills/X/)
#   Happy:  single cached skill at convention-layout (.../skills/X/, NO .claude/)
#   Edge:   query matches BOTH a skill and a plugin → both returned (no ranking)
#   Edge:   empty query → exit 0, no output
#   Edge:   shell-metacharacter query → no injection, no spurious match
#   Edge:   skill at multiple version dirs → ONE record (highest semver)
#   Edge:   installed_plugins.json LIST-of-records (real shape) → finds entry
#   Edge:   probe glob — drop SKILL.md at documented path → match; move up → none
#   Error:  installed_plugins.json missing → continues, no crash
#   Error:  installed_plugins.json unparseable → stderr source=missing row
#   Error:  cache / marketplaces dir missing → graceful continuation
#
# Output format expected by tests/run.sh:
#   <basename>: N passed, M failed

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/tests/helpers/test-helpers.sh"

claude_modes_test::setup
# shellcheck disable=SC1091
. "${PLUGIN_ROOT}/lib/resolve-catalog-candidate.sh"

RESOLVER="${PLUGIN_ROOT}/lib/resolve-catalog-candidate.sh"

# ──────────────────────────────────────────────────────────────────────────
# Fixture builders. Everything roots under $HOME (the sandbox).

CACHE_ROOT="${HOME}/.claude/plugins/cache"
MARKET_ROOT="${HOME}/.claude/plugins/marketplaces"
REGISTRY="${HOME}/.claude/plugins/installed_plugins.json"

# Wipe all plugin state between scenarios so cross-scenario fixtures don't bleed.
__reset_plugins_state() {
  rm -rf "${HOME}/.claude/plugins"
  mkdir -p "${HOME}/.claude/plugins"
}

# Seed a cached skill at the ANTHROPIC layout:
#   cache/<market>/<plugin>/<version>/.claude/skills/<skill>/SKILL.md
# with `name: <skill-name>` frontmatter.
__seed_skill_anthropic() {
  local market="$1" plugin="$2" version="$3" skill="$4" name="${5:-$4}"
  local dir="${CACHE_ROOT}/${market}/${plugin}/${version}/.claude/skills/${skill}"
  mkdir -p "$dir"
  printf -- '---\nname: %s\ndescription: fixture\n---\nbody\n' "$name" > "${dir}/SKILL.md"
}

# Seed a cached skill at the CONVENTION layout (NO .claude/ infix):
#   cache/<market>/<plugin>/<version>/skills/<skill>/SKILL.md
__seed_skill_convention() {
  local market="$1" plugin="$2" version="$3" skill="$4" name="${5:-$4}"
  local dir="${CACHE_ROOT}/${market}/${plugin}/${version}/skills/${skill}"
  mkdir -p "$dir"
  printf -- '---\nname: %s\ndescription: fixture\n---\nbody\n' "$name" > "${dir}/SKILL.md"
}

# Seed installed_plugins.json with a single LIST-of-records entry (real shape).
__seed_installed_list() {
  local fqn="$1" installpath="${2:-/tmp/whatever}"
  "$CLAUDE_MODES_PYTHON3" - "$REGISTRY" "$fqn" "$installpath" <<'PYEOF'
import sys, json
out, fqn, ip = sys.argv[1], sys.argv[2], sys.argv[3]
data = {"version": 1,
        "plugins": {fqn: [{"scope": "user", "installPath": ip, "version": "1.0.0"}]}}
with open(out, "w") as f:
    json.dump(data, f)
PYEOF
}

# Seed installed_plugins.json with a DICT-shaped entry (the WRONG shape that
# the list-awareness must NOT match). Used by the deliberate-fail.
__seed_installed_dict() {
  local fqn="$1" installpath="${2:-/tmp/whatever}"
  "$CLAUDE_MODES_PYTHON3" - "$REGISTRY" "$fqn" "$installpath" <<'PYEOF'
import sys, json
out, fqn, ip = sys.argv[1], sys.argv[2], sys.argv[3]
# Value is a bare record DICT, not a list-of-records. A list-aware reader
# wraps it as [dict] and still matches; this fixture exists only to prove the
# POSITIVE list case is doing work via the deliberate-fail flip in the impl.
data = {"version": 1,
        "plugins": {fqn: {"scope": "user", "installPath": ip, "version": "1.0.0"}}}
with open(out, "w") as f:
    json.dump(data, f)
PYEOF
}

# Seed a marketplace.json with one installable plugin entry.
__seed_marketplace() {
  local market_dir="$1" market_name="$2" plugin_name="$3"
  local dir="${MARKET_ROOT}/${market_dir}/.claude-plugin"
  mkdir -p "$dir"
  "$CLAUDE_MODES_PYTHON3" - "${dir}/marketplace.json" "$market_name" "$plugin_name" <<'PYEOF'
import sys, json
out, mname, pname = sys.argv[1], sys.argv[2], sys.argv[3]
data = {"name": mname, "owner": "test",
        "plugins": [{"name": pname, "description": "fixture", "source": "."}]}
with open(out, "w") as f:
    json.dump(data, f)
PYEOF
}

# ──────────────────────────────────────────────────────────────────────────
# Happy: single installed plugin match → source=installed installed=Y
# ──────────────────────────────────────────────────────────────────────────
__reset_plugins_state
__seed_installed_list "figma@every-marketplace"
claude_modes_test::it "installed plugin match → one record source=installed installed=Y"
out=$(claude_modes::resolve_candidate "figma" 2>/dev/null)
claude_modes_test::assert_eq \
  "kind=plugin	id=figma@every-marketplace	source=installed	installed=Y" \
  "$out"

# ──────────────────────────────────────────────────────────────────────────
# Happy: single cached skill at ANTHROPIC layout
# ──────────────────────────────────────────────────────────────────────────
__reset_plugins_state
__seed_skill_anthropic "mkt" "impeccable" "2.0.7" "animate"
claude_modes_test::it "cached skill at Anthropic-layout → kind=skill source=cache"
out=$(claude_modes::resolve_candidate "animate" 2>/dev/null)
claude_modes_test::assert_eq \
  "kind=skill	id=impeccable:animate	source=cache	installed=Y	parent_plugin=" \
  "$out"

# ──────────────────────────────────────────────────────────────────────────
# Happy: single cached skill at CONVENTION layout (NO .claude/ infix).
# THE EMPIRICALLY-VERIFIED CASE THE OLD SINGLE-LAYOUT GLOB MISSED.
# ──────────────────────────────────────────────────────────────────────────
__reset_plugins_state
__seed_skill_convention "anthropic-agent-skills" "document-skills" "690f15cac7f7" "pdf"
claude_modes_test::it "cached skill at convention-layout (NO .claude/ infix) → kind=skill source=cache"
out=$(claude_modes::resolve_candidate "pdf" 2>/dev/null)
claude_modes_test::assert_eq \
  "kind=skill	id=document-skills:pdf	source=cache	installed=Y	parent_plugin=" \
  "$out"

# ──────────────────────────────────────────────────────────────────────────
# Batch-4 fix: a cached skill whose PARENT PLUGIN is installed carries the
# parent's FQN in the parent_plugin= field (so the orchestrator can enable the
# plugin rather than write a dangling colon-FQN into user_catalog.agents).
# ──────────────────────────────────────────────────────────────────────────
__reset_plugins_state
__seed_skill_anthropic "mkt" "iloom-lite" "1.0.0" "planr"
__seed_installed_list "iloom-lite@every-marketplace"
claude_modes_test::it "cached skill with INSTALLED parent → parent_plugin=<plugin>@<market>"
out=$(claude_modes::resolve_candidate "planr" 2>/dev/null)
claude_modes_test::assert_eq \
  "kind=skill	id=iloom-lite:planr	source=cache	installed=Y	parent_plugin=iloom-lite@every-marketplace" \
  "$out"

# ──────────────────────────────────────────────────────────────────────────
# Edge: query matches BOTH a skill and a plugin → both returned (no ranking).
# ──────────────────────────────────────────────────────────────────────────
__reset_plugins_state
__seed_skill_anthropic "mkt" "someplugin" "1.0.0" "rams"
__seed_installed_list "rams@some-marketplace"
claude_modes_test::it "query matches both skill and plugin → both returned, skill first"
out=$(claude_modes::resolve_candidate "rams" 2>/dev/null)
# Skills source runs first (specificity order); installed second.
nlines=$(printf '%s\n' "$out" | grep -c .)
claude_modes_test::assert_eq "2" "$nlines"
claude_modes_test::it "  ... both contain kind=skill"
claude_modes_test::assert_contains "$out" "kind=skill	id=someplugin:rams	source=cache	installed=Y	parent_plugin="
claude_modes_test::it "  ... both contain kind=plugin"
claude_modes_test::assert_contains "$out" "kind=plugin	id=rams@some-marketplace	source=installed	installed=Y"

# ──────────────────────────────────────────────────────────────────────────
# Edge: empty query → exit 0, no output.
# ──────────────────────────────────────────────────────────────────────────
__reset_plugins_state
__seed_installed_list "figma@every-marketplace"
claude_modes_test::it "empty query → no output"
out=$(claude_modes::resolve_candidate "" 2>/dev/null)
claude_modes_test::assert_eq "" "$out"
claude_modes_test::it "empty query → exit 0"
claude_modes::resolve_candidate "" >/dev/null 2>&1
claude_modes_test::assert_eq "0" "$?"

# ──────────────────────────────────────────────────────────────────────────
# Edge: shell-metacharacter query → no injection, no spurious match.
# ──────────────────────────────────────────────────────────────────────────
__reset_plugins_state
__seed_installed_list "figma@every-marketplace"
__seed_skill_anthropic "mkt" "p" "1.0.0" "safe"
# A canary the injection would create if the query reached a shell.
CANARY="${HOME}/INJECTION_CANARY"
rm -f "$CANARY"
claude_modes_test::it "metacharacter query is not executed (no canary file created)"
claude_modes::resolve_candidate "'; touch ${CANARY}; echo '" >/dev/null 2>&1 || true
claude_modes_test::assert_file_absent "$CANARY"
claude_modes_test::it "metacharacter query matches nothing real → empty output"
out=$(claude_modes::resolve_candidate "'; rm -rf /" 2>/dev/null)
claude_modes_test::assert_eq "" "$out"

# ──────────────────────────────────────────────────────────────────────────
# Edge: same skill at MULTIPLE version dirs → ONE record (highest semver).
# ──────────────────────────────────────────────────────────────────────────
__reset_plugins_state
__seed_skill_anthropic "mkt" "claude-modes" "0.2.0" "mode-author"
__seed_skill_anthropic "mkt" "claude-modes" "0.2.1" "mode-author"
__seed_skill_anthropic "mkt" "claude-modes" "0.2.4" "mode-author"
claude_modes_test::it "skill at 3 version dirs → exactly ONE record"
out=$(claude_modes::resolve_candidate "mode-author" 2>/dev/null)
nlines=$(printf '%s\n' "$out" | grep -c .)
claude_modes_test::assert_eq "1" "$nlines"
claude_modes_test::it "  ... the surviving record is well-formed (highest semver kept)"
claude_modes_test::assert_eq \
  "kind=skill	id=claude-modes:mode-author	source=cache	installed=Y	parent_plugin=" \
  "$out"

# ──────────────────────────────────────────────────────────────────────────
# Edge: installed_plugins.json is LIST-of-records (real shape) → finds entry.
# DELIBERATE-FAIL companion: the impl's list-awareness is flipped to dict-only
# via Edit at author time to confirm THIS test fails when the list-handling
# branch is removed. (Flip-via-Edit, not in-script, per the deliberate-fail
# discipline; this committed case asserts the POSITIVE list shape.)
# ──────────────────────────────────────────────────────────────────────────
__reset_plugins_state
__seed_installed_list "delivery-pack@mkt"
claude_modes_test::it "installed_plugins.json LIST-of-records shape → entry found"
out=$(claude_modes::resolve_candidate "delivery-pack" 2>/dev/null)
claude_modes_test::assert_eq \
  "kind=plugin	id=delivery-pack@mkt	source=installed	installed=Y" \
  "$out"

# Companion sanity: the DICT shape is ALSO matched by the list-aware reader
# (it wraps a bare dict as [dict]). This documents that the deliberate-fail
# proves the LIST branch is load-bearing — not that dict is rejected by design.
__reset_plugins_state
__seed_installed_dict "dictshape@mkt"
claude_modes_test::it "installed_plugins.json bare-DICT shape is still handled (wrapped as list)"
out=$(claude_modes::resolve_candidate "dictshape" 2>/dev/null)
claude_modes_test::assert_eq \
  "kind=plugin	id=dictshape@mkt	source=installed	installed=Y" \
  "$out"

# ──────────────────────────────────────────────────────────────────────────
# Edge: marketplace installable-but-not-installed → installed=N.
# ──────────────────────────────────────────────────────────────────────────
__reset_plugins_state
__seed_marketplace "shrimpshack-dir" "shrimpshack" "newtool"
claude_modes_test::it "marketplace installable entry → kind=plugin source=marketplace installed=N"
out=$(claude_modes::resolve_candidate "newtool" 2>/dev/null)
claude_modes_test::assert_eq \
  "kind=plugin	id=newtool@shrimpshack	source=marketplace	installed=N" \
  "$out"

# Already-installed plugins are suppressed from the marketplace source.
__reset_plugins_state
__seed_marketplace "shrimpshack-dir" "shrimpshack" "alreadyhere"
__seed_installed_list "alreadyhere@shrimpshack"
claude_modes_test::it "installed plugin is NOT duplicated by the marketplace source"
out=$(claude_modes::resolve_candidate "alreadyhere" 2>/dev/null)
nlines=$(printf '%s\n' "$out" | grep -c .)
claude_modes_test::assert_eq "1" "$nlines"
claude_modes_test::it "  ... the single record is the installed one"
claude_modes_test::assert_contains "$out" "source=installed	installed=Y"

# ──────────────────────────────────────────────────────────────────────────
# Edge: probe glob — drop a SKILL.md at the documented Anthropic path, confirm
# match; move it ONE DIR UP (out of skills/<skill>/), confirm zero matches.
# Proves the glob is doing work, not vacuously passing.
# ──────────────────────────────────────────────────────────────────────────
__reset_plugins_state
__seed_skill_anthropic "mkt" "probeplugin" "1.0.0" "__probe"
claude_modes_test::it "probe: SKILL.md at documented path → match"
out=$(claude_modes::resolve_candidate "__probe" 2>/dev/null)
claude_modes_test::assert_eq \
  "kind=skill	id=probeplugin:__probe	source=cache	installed=Y	parent_plugin=" \
  "$out"
# Move the SKILL.md one directory up (into skills/ itself, not skills/<skill>/).
PROBE_DIR="${CACHE_ROOT}/mkt/probeplugin/1.0.0/.claude/skills/__probe"
mv "${PROBE_DIR}/SKILL.md" "$(dirname "$PROBE_DIR")/SKILL.md"
claude_modes_test::it "probe: SKILL.md moved one dir up → zero matches"
out=$(claude_modes::resolve_candidate "__probe" 2>/dev/null)
claude_modes_test::assert_eq "" "$out"

# ──────────────────────────────────────────────────────────────────────────
# Error: installed_plugins.json MISSING → continues sources 1+3, no crash,
# no stderr 'missing' row (absence is an expected state, not a parse failure).
# ──────────────────────────────────────────────────────────────────────────
__reset_plugins_state
__seed_skill_anthropic "mkt" "p" "1.0.0" "stillworks"
# No registry file at all.
claude_modes_test::it "registry MISSING → source 1 still resolves, no crash"
out=$(claude_modes::resolve_candidate "stillworks" 2>/dev/null)
# Registry absent → parent_plugin is empty (the skill's plugin isn't installed).
claude_modes_test::assert_eq \
  "kind=skill	id=p:stillworks	source=cache	installed=Y	parent_plugin=" \
  "$out"
claude_modes_test::it "registry MISSING → no stderr 'source=missing' row (absence is not a parse failure)"
err=$(claude_modes::resolve_candidate "stillworks" 2>&1 >/dev/null)
case "$err" in
  *"source=missing"*) claude_modes_test::fail "unexpected source=missing for an ABSENT registry: $err" ;;
  *) claude_modes_test::pass ;;
esac

# ──────────────────────────────────────────────────────────────────────────
# Error: installed_plugins.json EXISTS but UNPARSEABLE → graceful continuation
# + stderr source=missing row.
# ──────────────────────────────────────────────────────────────────────────
__reset_plugins_state
__seed_skill_anthropic "mkt" "p" "1.0.0" "resilient"
printf 'this is not valid json {{{' > "$REGISTRY"
claude_modes_test::it "registry UNPARSEABLE → source 1 still resolves (graceful continuation)"
out=$(claude_modes::resolve_candidate "resilient" 2>/dev/null)
# Unparseable registry → parent_plugin empty (map build best-effort returns {}).
claude_modes_test::assert_eq \
  "kind=skill	id=p:resilient	source=cache	installed=Y	parent_plugin=" \
  "$out"
claude_modes_test::it "registry UNPARSEABLE → stderr emits source=missing row"
err=$(claude_modes::resolve_candidate "resilient" 2>&1 >/dev/null)
claude_modes_test::assert_contains "$err" "source=missing"

# ──────────────────────────────────────────────────────────────────────────
# Error: cache dir MISSING → graceful continuation (no crash, sources 2+3 run).
# ──────────────────────────────────────────────────────────────────────────
__reset_plugins_state
__seed_installed_list "fromregistry@mkt"
# No cache dir at all (only the registry exists).
claude_modes_test::it "cache dir MISSING → source 2 still resolves, no crash"
out=$(claude_modes::resolve_candidate "fromregistry" 2>/dev/null)
claude_modes_test::assert_eq \
  "kind=plugin	id=fromregistry@mkt	source=installed	installed=Y" \
  "$out"

# ──────────────────────────────────────────────────────────────────────────
# Error: marketplaces dir MISSING → graceful continuation.
# ──────────────────────────────────────────────────────────────────────────
__reset_plugins_state
__seed_installed_list "alsoworks@mkt"
# No marketplaces dir.
claude_modes_test::it "marketplaces dir MISSING → no crash, sources 1+2 run"
out=$(claude_modes::resolve_candidate "alsoworks" 2>/dev/null)
claude_modes_test::assert_eq \
  "kind=plugin	id=alsoworks@mkt	source=installed	installed=Y" \
  "$out"

# ──────────────────────────────────────────────────────────────────────────
# Error: marketplace.json UNPARSEABLE → stderr source=missing row.
# ──────────────────────────────────────────────────────────────────────────
__reset_plugins_state
mkdir -p "${MARKET_ROOT}/broken/.claude-plugin"
printf 'not json {{{' > "${MARKET_ROOT}/broken/.claude-plugin/marketplace.json"
claude_modes_test::it "marketplace.json UNPARSEABLE → stderr emits source=missing row"
err=$(claude_modes::resolve_candidate "anything" 2>&1 >/dev/null)
claude_modes_test::assert_contains "$err" "source=missing"

# ──────────────────────────────────────────────────────────────────────────
# Sanitization: a skill name carrying a control byte (ESC) is stripped in the
# emitted FQN (R7 — terminal-escape class).
# ──────────────────────────────────────────────────────────────────────────
__reset_plugins_state
ESC=$(printf '\033')
__seed_skill_anthropic "mkt" "p" "1.0.0" "ev1l" "ev${ESC}1l"
claude_modes_test::it "skill name with an ESC byte → ESC stripped in emitted FQN"
out=$(claude_modes::resolve_candidate "ev${ESC}1l" 2>/dev/null)
case "$out" in
  *"$ESC"*) claude_modes_test::fail "ESC byte leaked into output: $(printf '%q' "$out")" ;;
  "kind=skill	id=p:ev1l	source=cache	installed=Y	parent_plugin=") claude_modes_test::pass ;;
  *) claude_modes_test::fail "unexpected output: $(printf '%q' "$out")" ;;
esac

# ──────────────────────────────────────────────────────────────────────────
# Security (transport-boundary): a hostile cache PLUGIN-DIR NAME carrying an
# embedded newline must NOT forge phantom TSV rows. The python helper strips
# Cc/Cf (incl. \n, \t) INSIDE the heredoc BEFORE the record/field separator, so
# one on-disk skill emits EXACTLY ONE row — not N. (Adversarial reviewer:
# pre-fix this produced 4 rows from 1 skill.)
# DELIBERATE-FAIL: removing the python `_sd()` strip at the write site makes
# this assert >1 row. Flip via Edit (not in-script) to confirm it fails first.
# ──────────────────────────────────────────────────────────────────────────
__reset_plugins_state
# Plugin dir name = $'real\nphantom' (embedded newline). Valid SKILL.md with
# PROPER frontmatter fences so the parser accepts it.
__evil_plugin=$'real\nphantom'
__evil_dir="${CACHE_ROOT}/mkt/${__evil_plugin}/1.0.0/.claude/skills/planner"
mkdir -p "$__evil_dir"
printf -- '---\nname: planner\ndescription: x\n---\nbody\n' > "${__evil_dir}/SKILL.md"
claude_modes_test::it "hostile newline in cache plugin-dir name → EXACTLY ONE TSV row (no phantom rows)"
out=$(claude_modes::resolve_candidate "planner" 2>/dev/null)
nrows=$(printf '%s\n' "$out" | grep -c 'kind=')
claude_modes_test::assert_eq "1" "$nrows"
claude_modes_test::it "  ... and no raw newline survives inside the emitted FQN field"
# The plugin component should be 'realphantom' (newline stripped), so the FQN is
# realphantom:planner on a single line.
claude_modes_test::assert_contains "$out" "id=realphantom:planner"

# ──────────────────────────────────────────────────────────────────────────
# Runnable form: invoking the file directly resolves too (BASH_SOURCE guard).
# ──────────────────────────────────────────────────────────────────────────
__reset_plugins_state
__seed_installed_list "viaexec@mkt"
claude_modes_test::it "direct invocation (bash <file> <query>) resolves"
out=$(HOME="$HOME" bash "$RESOLVER" "viaexec" 2>/dev/null)
claude_modes_test::assert_eq \
  "kind=plugin	id=viaexec@mkt	source=installed	installed=Y" \
  "$out"

# ──────────────────────────────────────────────────────────────────────────
# CLI guard: a ZERO-ARG (or empty-query) CLI invocation is a usage error
# (exit 2, usage message on stderr) — NOT a clean no-match. The FUNCTION stays
# silent-on-empty (asserted above); only the CLI surface distinguishes the
# missing-query case. Mirrors lib/audit.sh's CLI guard.
# DELIBERATE-FAIL: removing the guard makes zero-arg exit 0 with empty stdout →
# this asserts exit 2; flip via Edit to confirm it fails first.
# ──────────────────────────────────────────────────────────────────────────
__reset_plugins_state
claude_modes_test::it "CLI zero-arg invocation → exit 2 (usage error, not clean no-match)"
HOME="$HOME" bash "$RESOLVER" >/dev/null 2>&1
claude_modes_test::assert_eq "2" "$?"
claude_modes_test::it "CLI zero-arg invocation → usage message on stderr"
err=$(HOME="$HOME" bash "$RESOLVER" 2>&1 >/dev/null)
claude_modes_test::assert_contains "$err" "Usage:"
claude_modes_test::it "CLI empty-string query → also exit 2 (treated as missing query)"
HOME="$HOME" bash "$RESOLVER" "" >/dev/null 2>&1
claude_modes_test::assert_eq "2" "$?"

claude_modes_test::teardown

printf '%s: %d passed, %d failed\n' \
  "$(basename "$0")" \
  "$CLAUDE_MODES_TEST_PASS_COUNT" \
  "$CLAUDE_MODES_TEST_FAIL_COUNT"
[ "$CLAUDE_MODES_TEST_FAIL_COUNT" -eq 0 ]
