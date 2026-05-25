#!/usr/bin/env bash
# U3 unit test: lib/apply-delta.sh (delta application + R22 PRIMARY enforcement).
#
# All fixtures are seeded under the isolated $HOME sandbox. Mode YAMLs live at
# ~/.claude/modes/<name>.yaml (tier 3) so the writer's path-safety check accepts
# them; parent tiers (_global.yaml = tier 2, _repo.yaml = tier 4) are seeded for
# the un-disable scenarios.
#
# Scenarios (mirrors the plan's U3 test list):
#   Happy:  add-plugin on fresh mode → mechanism.enabledPlugins.<id>: true
#   Happy:  drop-plugin → disable.enabledPlugins gets the id, mechanism untouched
#   Happy:  add-user-catalog commands rams.md → list appended
#   Edge:   add-plugin already present → idempotent no-op (exit 11)
#   Edge:   drop-plugin already in disable → idempotent no-op (exit 11)
#   Edge:   add-plugin of id in disable, PARENT enables → removed from disable only
#   Edge:   add-plugin of id in disable, NO parent enables → un-disable + add
#   Error:  drop-plugin claude-modes@<resolved-id> → R22 refusal, exit 1, unchanged
#   Error:  drop-plugin claude-modes@stale-marketplace → still refused (glob)
#   Error:  mechanism.enabledPlugins.claude-modes@<id>: false → refused
#   Edge:   CLAUDE_MODES_CANONICAL_ID override + delta on OTHER id → R22 still fires
#   Error:  mode YAML doesn't exist → exit 1 "no such mode"
#   Error:  delta producing mechanism.hooks → exit 1 from write-mode-yaml R28
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
. "${PLUGIN_ROOT}/lib/apply-delta.sh"

PY="$CLAUDE_MODES_PYTHON3"
MODES_DIR="${HOME}/.claude/modes"

# ──────────────────────────────────────────────────────────────────────────
# Fixture helpers.

# Write a tier-3 mode YAML with the given lines (each arg is one line).
__write_mode() {
  local path="$1"; shift
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$@" > "$path"
}

# Query a YAML path expression. Echoes Python-evaluated <expr> over `data`.
__yq() {
  local path="$1" expr="$2"
  "$PY" - "$path" "$expr" <<'PYEOF'
import sys, yaml
data = yaml.safe_load(open(sys.argv[1])) or {}
print(eval(sys.argv[2]))
PYEOF
}

# Reset the modes dir between scenarios.
__reset_modes() {
  rm -rf "$MODES_DIR"
  mkdir -p "$MODES_DIR"
}

# ──────────────────────────────────────────────────────────────────────────
# Happy: add-plugin on a fresh mode → mechanism.enabledPlugins.<id>: true
# ──────────────────────────────────────────────────────────────────────────
__reset_modes
M="${MODES_DIR}/design.yaml"
__write_mode "$M" 'schema_version: 2' 'mechanism:' '  enabledPlugins:' \
  '    claude-modes@local-dev: true'
claude_modes_test::it "add-plugin on fresh mode → enabledPlugins.<id>: true; exit 0"
claude_modes::apply_delta "$M" add-plugin "figma@every-marketplace" >/dev/null 2>&1
claude_modes_test::assert_eq "0" "$?"
claude_modes_test::it "  ... the plugin is now enabled (True)"
got=$(__yq "$M" "data['mechanism']['enabledPlugins'].get('figma@every-marketplace')")
claude_modes_test::assert_eq "True" "$got"

# ──────────────────────────────────────────────────────────────────────────
# Happy: drop-plugin → disable.enabledPlugins gets the id, mechanism untouched.
# ──────────────────────────────────────────────────────────────────────────
__reset_modes
M="${MODES_DIR}/design.yaml"
__write_mode "$M" 'schema_version: 2' 'mechanism:' '  enabledPlugins:' \
  '    claude-modes@local-dev: true'
claude_modes_test::it "drop-plugin → exit 0"
claude_modes::apply_delta "$M" drop-plugin "typescript-lsp@every-marketplace" >/dev/null 2>&1
claude_modes_test::assert_eq "0" "$?"
claude_modes_test::it "  ... id is in disable.enabledPlugins"
got=$(__yq "$M" "'typescript-lsp@every-marketplace' in (data.get('disable') or {}).get('enabledPlugins', [])")
claude_modes_test::assert_eq "True" "$got"
claude_modes_test::it "  ... mechanism.enabledPlugins untouched (no false key added)"
got=$(__yq "$M" "'typescript-lsp@every-marketplace' in data['mechanism']['enabledPlugins']")
claude_modes_test::assert_eq "False" "$got"

# ──────────────────────────────────────────────────────────────────────────
# Happy: add-user-catalog commands rams.md → list appended.
# ──────────────────────────────────────────────────────────────────────────
__reset_modes
M="${MODES_DIR}/design.yaml"
__write_mode "$M" 'schema_version: 2' 'mechanism:' '  enabledPlugins:' \
  '    claude-modes@local-dev: true'
claude_modes_test::it "add-user-catalog commands rams.md → exit 0"
claude_modes::apply_delta "$M" add-user-catalog commands "rams.md" >/dev/null 2>&1
claude_modes_test::assert_eq "0" "$?"
claude_modes_test::it "  ... rams.md is in mechanism.user_catalog.commands"
got=$(__yq "$M" "'rams.md' in data['mechanism']['user_catalog']['commands']")
claude_modes_test::assert_eq "True" "$got"

claude_modes_test::it "add-user-catalog agents code-reviewer.md → appended to agents list"
claude_modes::apply_delta "$M" add-user-catalog agents "code-reviewer.md" >/dev/null 2>&1
got=$(__yq "$M" "'code-reviewer.md' in data['mechanism']['user_catalog']['agents']")
claude_modes_test::assert_eq "True" "$got"

claude_modes_test::it "drop-user-catalog commands rams.md → removed from list"
claude_modes::apply_delta "$M" drop-user-catalog commands "rams.md" >/dev/null 2>&1
got=$(__yq "$M" "'rams.md' in data['mechanism']['user_catalog']['commands']")
claude_modes_test::assert_eq "False" "$got"

# Bad category is a usage error.
claude_modes_test::it "add-user-catalog with bad category → exit 1"
claude_modes::apply_delta "$M" add-user-catalog skills "x.md" >/dev/null 2>&1
claude_modes_test::assert_ne "0" "$?"

# ──────────────────────────────────────────────────────────────────────────
# Edge: add-plugin already present → idempotent no-op (exit 11, unchanged).
# ──────────────────────────────────────────────────────────────────────────
__reset_modes
M="${MODES_DIR}/design.yaml"
__write_mode "$M" 'schema_version: 2' 'mechanism:' '  enabledPlugins:' \
  '    claude-modes@local-dev: true' \
  '    figma@every-marketplace: true'
before_hash=$(md5 -q "$M" 2>/dev/null || md5sum "$M" | cut -d' ' -f1)
# Batch-4 Finding 4: a no-op now returns exit 11 (DISTINCT from a real write's
# 0) so the orchestrator can skip the reload prompt + emit a no_change audit.
claude_modes_test::it "add-plugin already present → exit 11 (idempotent no-op, distinct from write)"
claude_modes::apply_delta "$M" add-plugin "figma@every-marketplace" >/dev/null 2>&1
claude_modes_test::assert_eq "11" "$?"
after_hash=$(md5 -q "$M" 2>/dev/null || md5sum "$M" | cut -d' ' -f1)
claude_modes_test::it "  ... file unchanged (no write)"
claude_modes_test::assert_eq "$before_hash" "$after_hash"

# ──────────────────────────────────────────────────────────────────────────
# Edge: drop-plugin already in disable → idempotent (exit 11, unchanged).
# ──────────────────────────────────────────────────────────────────────────
__reset_modes
M="${MODES_DIR}/design.yaml"
__write_mode "$M" 'schema_version: 2' 'mechanism:' '  enabledPlugins:' \
  '    claude-modes@local-dev: true' \
  'disable:' '  enabledPlugins:' '    - typescript-lsp@every-marketplace'
before_hash=$(md5 -q "$M" 2>/dev/null || md5sum "$M" | cut -d' ' -f1)
# Batch-4 Finding 4: idempotent no-op → exit 11 (distinct from a real write).
claude_modes_test::it "drop-plugin already in disable → exit 11 (idempotent no-op)"
claude_modes::apply_delta "$M" drop-plugin "typescript-lsp@every-marketplace" >/dev/null 2>&1
claude_modes_test::assert_eq "11" "$?"
after_hash=$(md5 -q "$M" 2>/dev/null || md5sum "$M" | cut -d' ' -f1)
claude_modes_test::it "  ... file unchanged (no write)"
claude_modes_test::assert_eq "$before_hash" "$after_hash"

# ──────────────────────────────────────────────────────────────────────────
# Edge: add-plugin of id in disable, PARENT (_global.yaml) enables it →
# removed from disable ONLY (no positive add — keeps YAML quiet).
# ──────────────────────────────────────────────────────────────────────────
__reset_modes
# Tier 2 (_global.yaml) enables the plugin.
__write_mode "${MODES_DIR}/_global.yaml" 'schema_version: 2' 'mechanism:' \
  '  enabledPlugins:' '    claude-modes@local-dev: true' \
  '    ldlens@every-marketplace: true'
M="${MODES_DIR}/design.yaml"
__write_mode "$M" 'schema_version: 2' 'mechanism:' '  enabledPlugins:' \
  '    claude-modes@local-dev: true' \
  'disable:' '  enabledPlugins:' '    - ldlens@every-marketplace'
claude_modes_test::it "add-plugin of disabled id WITH parent-enable → exit 0"
claude_modes::apply_delta "$M" add-plugin "ldlens@every-marketplace" >/dev/null 2>&1
claude_modes_test::assert_eq "0" "$?"
claude_modes_test::it "  ... removed from disable.enabledPlugins"
got=$(__yq "$M" "'ldlens@every-marketplace' in (data.get('disable') or {}).get('enabledPlugins', [])")
claude_modes_test::assert_eq "False" "$got"
claude_modes_test::it "  ... NO positive add to mechanism.enabledPlugins (parent provides it)"
got=$(__yq "$M" "'ldlens@every-marketplace' in data['mechanism']['enabledPlugins']")
claude_modes_test::assert_eq "False" "$got"

# ──────────────────────────────────────────────────────────────────────────
# Edge: add-plugin of id in disable, NO parent enables it →
# removed from disable AND added to mechanism.enabledPlugins.
# ──────────────────────────────────────────────────────────────────────────
__reset_modes
# Tier 2 exists but does NOT enable the plugin.
__write_mode "${MODES_DIR}/_global.yaml" 'schema_version: 2' 'mechanism:' \
  '  enabledPlugins:' '    claude-modes@local-dev: true'
M="${MODES_DIR}/design.yaml"
__write_mode "$M" 'schema_version: 2' 'mechanism:' '  enabledPlugins:' \
  '    claude-modes@local-dev: true' \
  'disable:' '  enabledPlugins:' '    - solo@every-marketplace'
claude_modes_test::it "add-plugin of disabled id with NO parent-enable → exit 0"
claude_modes::apply_delta "$M" add-plugin "solo@every-marketplace" >/dev/null 2>&1
claude_modes_test::assert_eq "0" "$?"
claude_modes_test::it "  ... removed from disable.enabledPlugins"
got=$(__yq "$M" "'solo@every-marketplace' in (data.get('disable') or {}).get('enabledPlugins', [])")
claude_modes_test::assert_eq "False" "$got"
claude_modes_test::it "  ... ADDED to mechanism.enabledPlugins (no parent provides it)"
got=$(__yq "$M" "data['mechanism']['enabledPlugins'].get('solo@every-marketplace')")
claude_modes_test::assert_eq "True" "$got"

# ──────────────────────────────────────────────────────────────────────────
# Error: drop-plugin claude-modes@<resolved-id> → R22 refusal, exit 1,
# stderr message, YAML unchanged.
# ──────────────────────────────────────────────────────────────────────────
__reset_modes
M="${MODES_DIR}/design.yaml"
__write_mode "$M" 'schema_version: 2' 'mechanism:' '  enabledPlugins:' \
  '    claude-modes@local-dev: true'
before_hash=$(md5 -q "$M" 2>/dev/null || md5sum "$M" | cut -d' ' -f1)
RESOLVED_ID=$(__claude_modes::resolve_self_identifier)
claude_modes_test::it "drop-plugin <resolved claude-modes id> → exit 1 (R22)"
err=$(claude_modes::apply_delta "$M" drop-plugin "$RESOLVED_ID" 2>&1 >/dev/null)
rc_seen=$?
claude_modes_test::assert_eq "1" "$rc_seen"
claude_modes_test::it "  ... stderr names R22"
claude_modes_test::assert_contains "$err" "R22"
claude_modes_test::it "  ... stderr says required and cannot be disabled"
claude_modes_test::assert_contains "$err" "is required and cannot be disabled at the mode tier"
claude_modes_test::it "  ... YAML unchanged"
after_hash=$(md5 -q "$M" 2>/dev/null || md5sum "$M" | cut -d' ' -f1)
claude_modes_test::assert_eq "$before_hash" "$after_hash"

# ──────────────────────────────────────────────────────────────────────────
# Error: drop-plugin claude-modes@stale-marketplace → STILL refused
# (defense-in-depth glob over claude-modes@*, even though it's not the live id).
# ──────────────────────────────────────────────────────────────────────────
__reset_modes
M="${MODES_DIR}/design.yaml"
__write_mode "$M" 'schema_version: 2' 'mechanism:' '  enabledPlugins:' \
  '    claude-modes@local-dev: true'
before_hash=$(md5 -q "$M" 2>/dev/null || md5sum "$M" | cut -d' ' -f1)
claude_modes_test::it "drop-plugin claude-modes@stale-marketplace → exit 1 (glob)"
claude_modes::apply_delta "$M" drop-plugin "claude-modes@stale-marketplace" >/dev/null 2>&1
claude_modes_test::assert_eq "1" "$?"
claude_modes_test::it "  ... YAML unchanged"
after_hash=$(md5 -q "$M" 2>/dev/null || md5sum "$M" | cut -d' ' -f1)
claude_modes_test::assert_eq "$before_hash" "$after_hash"

# ──────────────────────────────────────────────────────────────────────────
# Error: a delta setting mechanism.enabledPlugins.claude-modes@<id>: false
# is refused. We can't get there via add-plugin (which sets true), so seed a
# mode whose mechanism already enables claude-modes, then drive the false-set
# through the un-disable path is not it either. Instead: the R22 check must
# refuse ANY post-delta YAML with claude-modes@*: false. We exercise the check
# directly by seeding such a key and applying an UNRELATED valid delta — the
# R22 simulation scans the WHOLE post-delta dict, so it fires.
# ──────────────────────────────────────────────────────────────────────────
__reset_modes
M="${MODES_DIR}/design.yaml"
__write_mode "$M" 'schema_version: 2' 'mechanism:' '  enabledPlugins:' \
  '    claude-modes@local-dev: false'
before_hash=$(md5 -q "$M" 2>/dev/null || md5sum "$M" | cut -d' ' -f1)
claude_modes_test::it "post-delta YAML with claude-modes@*: false → refused, exit 1"
claude_modes::apply_delta "$M" add-plugin "figma@every-marketplace" >/dev/null 2>&1
claude_modes_test::assert_eq "1" "$?"
claude_modes_test::it "  ... YAML unchanged"
after_hash=$(md5 -q "$M" 2>/dev/null || md5sum "$M" | cut -d' ' -f1)
claude_modes_test::assert_eq "$before_hash" "$after_hash"

# ──────────────────────────────────────────────────────────────────────────
# Edge: CLAUDE_MODES_CANONICAL_ID override set to claude-modes@local-dev,
# delta targets the OTHER id (claude-modes@shrimpshack) → R22 STILL fires
# (the glob over claude-modes@* catches the non-resolved id too).
# ──────────────────────────────────────────────────────────────────────────
__reset_modes
M="${MODES_DIR}/design.yaml"
__write_mode "$M" 'schema_version: 2' 'mechanism:' '  enabledPlugins:' \
  '    claude-modes@local-dev: true'
before_hash=$(md5 -q "$M" 2>/dev/null || md5sum "$M" | cut -d' ' -f1)
claude_modes_test::it "CANONICAL_ID=local-dev, drop OTHER claude-modes id → R22 fires (glob)"
CLAUDE_MODES_CANONICAL_ID="claude-modes@local-dev" \
  claude_modes::apply_delta "$M" drop-plugin "claude-modes@shrimpshack" >/dev/null 2>&1
claude_modes_test::assert_eq "1" "$?"
claude_modes_test::it "  ... message names the RESOLVED id (override), not the targeted one"
err=$(CLAUDE_MODES_CANONICAL_ID="claude-modes@local-dev" \
  claude_modes::apply_delta "$M" drop-plugin "claude-modes@shrimpshack" 2>&1 >/dev/null)
claude_modes_test::assert_contains "$err" "claude-modes@local-dev"
claude_modes_test::it "  ... YAML unchanged"
after_hash=$(md5 -q "$M" 2>/dev/null || md5sum "$M" | cut -d' ' -f1)
claude_modes_test::assert_eq "$before_hash" "$after_hash"

# ──────────────────────────────────────────────────────────────────────────
# R22 uses resolve_self_identifier (NOT a hardcoded string): with a custom
# override, dropping THAT exact id is refused and the message echoes it.
# ──────────────────────────────────────────────────────────────────────────
__reset_modes
M="${MODES_DIR}/design.yaml"
__write_mode "$M" 'schema_version: 2' 'mechanism:' '  enabledPlugins:' \
  '    claude-modes@my-fork: true'
claude_modes_test::it "override id is honored by R22 (message echoes resolved id)"
err=$(CLAUDE_MODES_CANONICAL_ID="claude-modes@my-fork" \
  claude_modes::apply_delta "$M" drop-plugin "claude-modes@my-fork" 2>&1 >/dev/null)
claude_modes_test::assert_contains "$err" "claude-modes@my-fork"

# ──────────────────────────────────────────────────────────────────────────
# Error: mode YAML doesn't exist → exit 1 "no such mode".
# ──────────────────────────────────────────────────────────────────────────
__reset_modes
claude_modes_test::it "missing mode YAML → exit 1"
err=$(claude_modes::apply_delta "${MODES_DIR}/ghost.yaml" add-plugin "x@m" 2>&1 >/dev/null)
rc_seen=$?
claude_modes_test::assert_eq "1" "$rc_seen"
claude_modes_test::it "  ... stderr says no such mode"
claude_modes_test::assert_contains "$err" "no such mode"

# ──────────────────────────────────────────────────────────────────────────
# Error: a delta producing mechanism.hooks → exit 1 from write-mode-yaml's R28
# enforcement (the writer rejects it; apply-delta does NOT duplicate R28). We
# seed a mode that ALREADY declares mechanism.hooks (the writer rejects on the
# post-delta serialized content), then apply a valid delta; the writer refuses.
# ──────────────────────────────────────────────────────────────────────────
__reset_modes
M="${MODES_DIR}/design.yaml"
__write_mode "$M" 'schema_version: 2' 'mechanism:' '  enabledPlugins:' \
  '    claude-modes@local-dev: true' \
  '  hooks:' '    PostToolUse: []'
claude_modes_test::it "delta over a YAML carrying mechanism.hooks → exit 1 (writer R28)"
err=$(claude_modes::apply_delta "$M" add-plugin "figma@every-marketplace" 2>&1 >/dev/null)
rc_seen=$?
claude_modes_test::assert_eq "1" "$rc_seen"
claude_modes_test::it "  ... stderr names R28"
claude_modes_test::assert_contains "$err" "R28"

# ──────────────────────────────────────────────────────────────────────────
# Runnable form: invoking the file directly applies a delta (BASH_SOURCE guard).
# ──────────────────────────────────────────────────────────────────────────
__reset_modes
M="${MODES_DIR}/design.yaml"
__write_mode "$M" 'schema_version: 2' 'mechanism:' '  enabledPlugins:' \
  '    claude-modes@local-dev: true'
claude_modes_test::it "direct invocation (bash <file> <path> add-plugin <id>) applies"
HOME="$HOME" bash "${PLUGIN_ROOT}/lib/apply-delta.sh" "$M" add-plugin "viaexec@mkt" >/dev/null 2>&1
got=$(__yq "$M" "data['mechanism']['enabledPlugins'].get('viaexec@mkt')")
claude_modes_test::assert_eq "True" "$got"

# ──────────────────────────────────────────────────────────────────────────
# Audit: a successful accept records mode_edit_accept outcome=ok.
# ──────────────────────────────────────────────────────────────────────────
__reset_modes
M="${MODES_DIR}/design.yaml"
__write_mode "$M" 'schema_version: 2' 'mechanism:' '  enabledPlugins:' \
  '    claude-modes@local-dev: true'
claude_modes::apply_delta "$M" add-plugin "figma@every-marketplace" >/dev/null 2>&1
claude_modes_test::it "successful accept → audit log has mode_edit_accept outcome=ok"
last=$(tail -n 1 "${MODES_DIR}/.audit.log")
claude_modes_test::assert_contains "$last" "event=mode_edit_accept"
claude_modes_test::it "  ... audit outcome=ok"
claude_modes_test::assert_contains "$last" "outcome=ok"

# ──────────────────────────────────────────────────────────────────────────
# Audit: an R22 refusal records outcome=fail step=r22.
# ──────────────────────────────────────────────────────────────────────────
__reset_modes
M="${MODES_DIR}/design.yaml"
__write_mode "$M" 'schema_version: 2' 'mechanism:' '  enabledPlugins:' \
  '    claude-modes@local-dev: true'
claude_modes::apply_delta "$M" drop-plugin "claude-modes@local-dev" >/dev/null 2>&1
claude_modes_test::it "R22 refusal → audit log has outcome=fail step=r22"
last=$(tail -n 1 "${MODES_DIR}/.audit.log")
claude_modes_test::assert_contains "$last" "step=r22"

# ──────────────────────────────────────────────────────────────────────────
# Prose-layer survival: apply-delta reserializes the whole YAML (yaml.safe_dump
# with sort_keys=True canonicalizes key order). A realistic mode always carries
# a prose layer (philosophy / scope / lens / constraints / description); this
# test guards that the reserialization preserves every prose field intact while
# the delta lands. Without this, a future serialization change could silently
# drop or mangle the prose layer and every other (mechanism-only) test would
# stay green.
# ──────────────────────────────────────────────────────────────────────────
__reset_modes
M="${MODES_DIR}/design.yaml"
__write_mode "$M" \
  'schema_version: 2' \
  'name: design' \
  'description: |' \
  '  Visual and UI work mode.' \
  'philosophy: |' \
  '  Optimize for design tools and visual output.' \
  'scope: |' \
  '  When creating interfaces or shaping presentation.' \
  'lens: |' \
  '  Treat every task as a design problem first.' \
  'constraints:' \
  '  - Avoid analytical or code work outside design scope.' \
  'mechanism:' \
  '  enabledPlugins:' \
  '    claude-modes@local-dev: true' \
  '    figma@every-marketplace: true' \
  '  user_catalog:' \
  '    commands: []' \
  '    agents: []'
claude_modes_test::it "prose-layer mode: add-plugin lands cleanly → exit 0"
claude_modes::apply_delta "$M" add-plugin "slack@every-marketplace" >/dev/null 2>&1
claude_modes_test::assert_eq "0" "$?"
claude_modes_test::it "  ... new plugin present in mechanism.enabledPlugins"
got=$(__yq "$M" "'slack@every-marketplace' in data['mechanism']['enabledPlugins']")
claude_modes_test::assert_eq "True" "$got"
claude_modes_test::it "  ... philosophy survived the reserialization"
got=$(__yq "$M" "'design tools' in (data.get('philosophy') or '')")
claude_modes_test::assert_eq "True" "$got"
claude_modes_test::it "  ... lens survived"
got=$(__yq "$M" "'design problem first' in (data.get('lens') or '')")
claude_modes_test::assert_eq "True" "$got"
claude_modes_test::it "  ... scope survived"
got=$(__yq "$M" "'shaping presentation' in (data.get('scope') or '')")
claude_modes_test::assert_eq "True" "$got"
claude_modes_test::it "  ... constraints list survived"
got=$(__yq "$M" "len(data.get('constraints') or []) == 1")
claude_modes_test::assert_eq "True" "$got"
claude_modes_test::it "  ... description survived"
got=$(__yq "$M" "'Visual and UI' in (data.get('description') or '')")
claude_modes_test::assert_eq "True" "$got"
claude_modes_test::it "  ... schema_version + name preserved"
got=$(__yq "$M" "data.get('schema_version') == 2 and data.get('name') == 'design'")
claude_modes_test::assert_eq "True" "$got"

claude_modes_test::teardown

printf '%s: %d passed, %d failed\n' \
  "$(basename "$0")" \
  "$CLAUDE_MODES_TEST_PASS_COUNT" \
  "$CLAUDE_MODES_TEST_FAIL_COUNT"
[ "$CLAUDE_MODES_TEST_FAIL_COUNT" -eq 0 ]
