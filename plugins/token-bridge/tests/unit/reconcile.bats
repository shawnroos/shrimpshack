#!/usr/bin/env bats
# Unit tests for lib/sync_tokens.py — the idempotent token reconcile.
#
# The DIFF ENGINE (diff_tokens) and desired-set builder (build_desired) are PURE
# functions with no git and no daemon, exercised here through the `build-desired`,
# `diff`, and `simulate-apply` subcommands against fixtures. The top-level `run`
# refuse guard is exercised through a config fixture with an empty fileId — it
# must short-circuit BEFORE any daemon call.
#
# The desired set is regenerated from the SCSS fixtures in setup() (via the real
# parse -> classify -> build pipeline) so these tests always track the pipeline
# rather than a frozen copy.

setup() {
    SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    LIB="$SCRIPT_DIR/lib/sync_tokens.py"
    FIXTURE_DIR="$SCRIPT_DIR/tests/fixtures"
    TOKENS="$FIXTURE_DIR/tokens_sample.scss"
    GENERAL="$FIXTURE_DIR/general_sample.scss"
    LIVE="$FIXTURE_DIR/paper_state_before.json"

    # Regenerate the desired set from source (the {desired, declined} envelope).
    DESIRED="$BATS_TMPDIR/desired.json"
    python3 "$LIB" build-desired --token-file "$TOKENS" --general-file "$GENERAL" > "$DESIRED"
}

# helper: the diff (creates/updates/deletes/recreates) of desired vs the given live file
diff_vs() { # <live-file>
    python3 "$LIB" diff --desired "$DESIRED" --live "$1"
}

# ============================================================================
# AE5 — idempotency: desired == live yields an empty diff, zero writes
# ============================================================================

@test "reconcile: AE5 idempotent — desired vs identical live is an empty diff" {
    # Use the desired set itself as the live state (a synced file).
    jq '.desired' "$DESIRED" > "$BATS_TMPDIR/live_synced.json"
    run diff_vs "$BATS_TMPDIR/live_synced.json"
    [ "$status" -eq 0 ]
    for bucket in creates updates deletes recreates; do
        n=$(echo "$output" | jq --arg b "$bucket" '.[$b] | length')
        [ "$n" -eq 0 ]
    done
}

# ============================================================================
# AE1 — a token in live but absent from desired is a delete
# ============================================================================

@test "reconcile: AE1 — a live token absent from desired becomes a delete" {
    run diff_vs "$LIVE"
    [ "$status" -eq 0 ]
    names=$(echo "$output" | jq -r '.deletes[].name')
    [[ "$names" == *"--wcs-legacy-panel"* ]]
    # exactly one delete in this fixture
    [ "$(echo "$output" | jq '.deletes | length')" -eq 1 ]
}

# ============================================================================
# AE2 — a token whose Paper type changed is delete+recreate, NOT an update
# ============================================================================

@test "reconcile: AE2 — a retyped token is a recreate, never an update" {
    # In the live fixture --wcs-space-2 is type=radius; desired is type=spacing.
    run diff_vs "$LIVE"
    [ "$status" -eq 0 ]
    recreated=$(echo "$output" | jq -r '.recreates[].name')
    [[ "$recreated" == *"--wcs-space-2"* ]]
    # and it must NOT appear as an update
    updated=$(echo "$output" | jq -r '.updates[].name')
    [[ "$updated" != *"--wcs-space-2"* ]]
}

# ============================================================================
# A changed hex value is a single update (same name + type)
# ============================================================================

@test "reconcile: a changed hex value is a single update" {
    # In the live fixture --wcs-green-500 is #111111; desired is #37D895.
    run diff_vs "$LIVE"
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq '.updates | length')" -eq 1 ]
    [ "$(echo "$output" | jq -r '.updates[0].name')" = "--wcs-green-500" ]
    [ "$(echo "$output" | jq -r '.updates[0].value')" = "#37D895" ]
}

# ============================================================================
# A new theme-varying token creates in BOTH the light and dark set
# ============================================================================

@test "reconcile: a new theme-varying token creates both light and dark twins" {
    # The live fixture omits --wcs-lasso-fill and its -dark twin entirely.
    run diff_vs "$LIVE"
    [ "$status" -eq 0 ]
    names=$(echo "$output" | jq -r '.creates[].name')
    [[ "$names" == *"--wcs-lasso-fill"* ]]
    [[ "$names" == *"--wcs-lasso-fill-dark"* ]]
    # the dark twin carries the dark literal, the light twin the light literal
    [ "$(echo "$output" | jq -r '.creates[] | select(.name=="--wcs-lasso-fill").value')" = "rgba(55, 216, 149, 0.18)" ]
    [ "$(echo "$output" | jq -r '.creates[] | select(.name=="--wcs-lasso-fill-dark").value')" = "rgba(136, 200, 46, 0.16)" ]
}

# ============================================================================
# R2 — a Tier-2 alias token's desired write value is the var(--wcs-*) reference
# ============================================================================

@test "reconcile: R2 — an alias token is written as var(--wcs-*), not resolved hex" {
    # --wcs-nav-item-active-fg aliases --wcs-accent in light.
    light=$(jq -r '.desired[] | select(.name=="--wcs-nav-item-active-fg").value' "$DESIRED")
    [ "$light" = "var(--wcs-accent)" ]
    [[ "$light" != *"#"* ]]

    # R3: the dark twin references the DARK counterpart (--wcs-accent-dark),
    # not the light name.
    dark=$(jq -r '.desired[] | select(.name=="--wcs-nav-item-active-fg-dark").value' "$DESIRED")
    [ "$dark" = "var(--wcs-accent-dark)" ]
}

# ============================================================================
# R6 — the --font-family token is in the desired set at type fontFamily
# ============================================================================

@test "reconcile: R6 — --font-family is written at type fontFamily" {
    type=$(jq -r '.desired[] | select(.name=="--font-family").type' "$DESIRED")
    [ "$type" = "fontFamily" ]
    value=$(jq -r '.desired[] | select(.name=="--font-family").value' "$DESIRED")
    [[ "$value" == *"Inter"* ]]
}

# ============================================================================
# A declined (shadow) token is in the declined list, never in the write set
# ============================================================================

@test "reconcile: a declined shadow token is reported, never written" {
    # --wcs-panel-shadow is a multi-part box-shadow: no Paper type.
    declined=$(jq -r '.declined[].name' "$DESIRED")
    [[ "$declined" == *"--wcs-panel-shadow"* ]]

    # It must never appear in the desired write set (neither twin).
    hits=$(jq -r '.desired[].name' "$DESIRED" | grep -c 'panel-shadow' || true)
    [ "$hits" -eq 0 ]

    # And therefore never in any diff bucket against the live fixture.
    run diff_vs "$LIVE"
    [ "$status" -eq 0 ]
    [[ "$(echo "$output" | jq -r '[.creates,.updates,.recreates] | flatten | .[].name')" != *"panel-shadow"* ]]
    [[ "$(echo "$output" | jq -r '.deletes[].name')" != *"panel-shadow"* ]]
}

# ============================================================================
# Safety — empty fileId: the command refuses and calls no daemon
# ============================================================================

@test "reconcile: refuses when fileId is empty, writing nothing" {
    cat > "$BATS_TMPDIR/empty_cfg.json" <<'JSON'
{ "fileId": "", "paperDaemonUrl": "http://127.0.0.1:1/mcp" }
JSON
    # Diagnostics go to stderr; drop it so $output is the pure JSON report.
    run bash -c "python3 '$LIB' run --config '$BATS_TMPDIR/empty_cfg.json' \
        --token-file '$TOKENS' --general-file '$GENERAL' 2>/dev/null"
    # non-zero, distinct refuse code
    [ "$status" -eq 2 ]

    refused=$(echo "$output" | jq -r '.refused')
    [ "$refused" = "true" ]

    # actionable message names the config key to set
    err=$(echo "$output" | jq -r '.error')
    [[ "$err" == *"fileId"* ]]
    [[ "$err" == *"wcs-paper.config.json"* ]]

    # PROOF no daemon call happened: had it reached get_tokens against the dead
    # port it would report a daemon/get_tokens error, not a refusal.
    [ "$(echo "$output" | jq -r '.ok')" = "false" ]
    [[ "$err" != *"get_tokens"* ]]
    [[ "$err" != *"daemon"* ]]
}

@test "reconcile: a whitespace-only fileId still refuses (strip guard)" {
    # A hand-pasted config with a trailing newline/spaces must NOT slip past the
    # refuse guard and target a nonexistent file — the fileId is stripped.
    cat > "$BATS_TMPDIR/ws_cfg.json" <<'JSON'
{ "fileId": "   ", "paperDaemonUrl": "http://127.0.0.1:1/mcp" }
JSON
    run bash -c "python3 '$LIB' run --config '$BATS_TMPDIR/ws_cfg.json' \
        --token-file '$TOKENS' --general-file '$GENERAL' 2>/dev/null"
    [ "$status" -eq 2 ]
    [ "$(echo "$output" | jq -r '.refused')" = "true" ]
    # never reached the daemon
    err=$(echo "$output" | jq -r '.error')
    [[ "$err" != *"daemon"* ]]
}

# ============================================================================
# Idempotency round-trip — apply a diff to the live state, re-diff is empty
# ============================================================================

@test "reconcile: round-trip — apply diff to live then re-diff yields empty" {
    python3 "$LIB" diff --desired "$DESIRED" --live "$LIVE" > "$BATS_TMPDIR/d1.json"
    # sanity: the first diff is non-empty
    [ "$(jq '[.creates,.updates,.deletes,.recreates] | flatten | length' "$BATS_TMPDIR/d1.json")" -gt 0 ]

    python3 "$LIB" simulate-apply --live "$LIVE" --diff "$BATS_TMPDIR/d1.json" > "$BATS_TMPDIR/live2.json"

    run python3 "$LIB" diff --desired "$DESIRED" --live "$BATS_TMPDIR/live2.json"
    [ "$status" -eq 0 ]
    for bucket in creates updates deletes recreates; do
        n=$(echo "$output" | jq --arg b "$bucket" '.[$b] | length')
        [ "$n" -eq 0 ]
    done
}

# ============================================================================
# Create ordering — a var() alias must be created AFTER its referent, else
# Paper (which creates in array order) silently drops the alias. Regression
# for the live bug where alphabetical ordering dropped --wcs-accent
# (var(--wcs-green-500)) and every alias chaining through it.
# ============================================================================

@test "order_for_create: referents precede the aliases that point at them" {
    run python3 -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR/lib')
import sync_tokens
# alphabetical order puts the alias BEFORE its referent; a chain too.
toks = [
  {'name':'--wcs-accent','type':'color','value':'var(--wcs-green-500)'},
  {'name':'--wcs-green-500','type':'color','value':'#37D895'},
  {'name':'--wcs-nav-fg','type':'color','value':'var(--wcs-accent)'},
]
ordered = [t['name'] for t in sync_tokens.order_for_create(toks)]
# each referent index < its alias index
assert ordered.index('--wcs-green-500') < ordered.index('--wcs-accent'), ordered
assert ordered.index('--wcs-accent') < ordered.index('--wcs-nav-fg'), ordered
print('OK', ordered)
"
    [ "$status" -eq 0 ]
    [[ "$output" == OK* ]]
}

# ============================================================================
# Serialization idempotency — Paper REWRITES values on store (transparent ->
# #00000000, rgba(r,g,b,a) -> rgb(r g b / a%), 0 -> 0px). The diff must treat
# those as unchanged, else the same tokens churn on every sync (R7). Regression
# for the live bug where 9 tokens re-updated forever.
# ============================================================================

@test "reconcile: Paper's re-serialized values are NOT seen as changes" {
    run python3 -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR/lib')
import sync_tokens
desired = [
  {'name':'--wcs-transparent','type':'color','value':'transparent'},
  {'name':'--wcs-lasso-fill','type':'color','value':'rgba(55, 216, 149, 0.18)'},
  {'name':'--wcs-space-0','type':'spacing','value':'0'},
  {'name':'--wcs-accent','type':'color','value':'var(--wcs-green-500)'},
]
# what Paper echoes back after storing them
live = [
  {'name':'--wcs-transparent','type':'color','value':'#00000000'},
  {'name':'--wcs-lasso-fill','type':'color','value':'rgb(55 216 149 / 18%)'},
  {'name':'--wcs-space-0','type':'spacing','value':'0px'},
  {'name':'--wcs-accent','type':'color','value':'var(--wcs-green-500)'},
]
diff = sync_tokens.diff_tokens(desired, live)
assert sync_tokens.is_empty_diff(diff), diff
# but a genuine change is still caught
live2 = [dict(live[1], value='rgb(1 2 3 / 50%)')] + live[:1] + live[2:]
diff2 = sync_tokens.diff_tokens(desired, live2)
assert any(u['name']=='--wcs-lasso-fill' for u in diff2['updates']), diff2
print('OK')
"
    [ "$status" -eq 0 ]
    [[ "$output" == OK* ]]
}
